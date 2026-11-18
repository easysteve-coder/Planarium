import XCTest
import AVFoundation
import PlanariumDomain
import PlanariumRuntime
@testable import PlanariumAudio

final class DeviceResetContractTests: XCTestCase {
    @MainActor func testMissingGraphConstructionCallbackHasBoundedMainWait() {
        let construction = FadeConstruction()
        let began = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try construction.take()) { error in
            XCTAssertEqual((error as? PluginLoadError)?.message, "Audio setup timed out. Please try again.")
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        XCTAssertLessThan(elapsed, 0.1, "Missing callback must not hang Main for seconds")
        print("BÜHNE-FEST-D graph construction Main wait: \(elapsed)s")
        construction.complete(nil, PluginLoadError("late obsolete result"))
        XCTAssertThrowsError(try construction.take()) { error in
            XCTAssertEqual(error as? PluginLoadError, .graphConstructionTimedOut)
        }
    }
    @MainActor func testGraphTimeoutIsVisibleAtInitialConstructionAndRetryRecovers() throws {
        let trace = Trace(), graph = FakeGraph(trace: trace)
        graph.configurationError = .graphConstructionTimedOut
        let host = try AudioHost(components: FakeComponents(), graph: graph, runtime: FakeRuntime(trace: trace),
                                 windows: FakeWindows(trace: trace))
        defer { host.shutdown() }
        let display = AudioOutputDeviceControlModel(host: host)
        XCTAssertEqual(display.notice, PluginLoadError.graphConstructionTimedOut.message)
        XCTAssertThrowsError(try host.start()); XCTAssertFalse(host.isRunning)
        graph.configurationError = nil
        host.configure(host.configuration)
        try host.start()
        XCTAssertTrue(host.isRunning); XCTAssertNil(display.notice)
    }
    @MainActor func testP8NativeGraphRecreatesEngineOnlyForExplicitDeviceToSystem() throws {
        var engines: [AVAudioEngine] = [], devices: [UInt32] = []
        var fail = false
        let graph = AVAudioGraph(makeEngine: { let engine = AVAudioEngine(); engines.append(engine); return engine },
            selectDevice: { _, id in if fail { throw PluginLoadError("Synthetic device failure") }; devices.append(id) })
        try graph.configure(.init(deviceID: 7))
        let first = try XCTUnwrap(engines.last)
        let persistentNodes = first.attachedNodes.subtracting([first.mainMixerNode, first.outputNode])
        XCTAssertEqual(persistentNodes.count, 5, "Converter, strip mixer/gain, sum gain and fade are attached")
        let trace = Trace(), windows = FakeWindows(trace: Trace())
        let sourceUnit = ResetNodeUnit(trace: trace), insertUnit = ResetNodeUnit(trace: trace)
        let source = PluginInstance(identity: plugin().identity, unit: sourceUnit, windows: windows)
        let insert = PluginInstance(identity: plugin(3, instrument: false).identity, unit: insertUnit, windows: windows)
        func attachAndConnect() throws {
            try graph.attach(source, instrument: true); try graph.attach(insert, instrument: false)
            graph.connect(instrument: source, inserts: [insert]); graph.setLevel(decibels: -6); graph.setPan(0.5)
            XCTAssertTrue(engines.last?.attachedNodes.contains(sourceUnit.node) == true)
            XCTAssertTrue(engines.last?.attachedNodes.contains(insertUnit.node) == true)
        }
        try attachAndConnect()
        try graph.configure(.init(deviceID: 8))
        XCTAssertTrue(engines.last === first); XCTAssertEqual(devices, [7, 8])
        try attachAndConnect()
        try graph.configure(.init())
        XCTAssertEqual(engines.count, 2); XCTAssertFalse(engines.last === first)
        XCTAssertTrue(first.attachedNodes.isDisjoint(with: persistentNodes.union([sourceUnit.node, insertUnit.node])), "Old graph releases all custom nodes")
        let current = try XCTUnwrap(engines.last)
        XCTAssertEqual(current.attachedNodes.subtracting([current.mainMixerNode, current.outputNode]).count, 5)
        try attachAndConnect()
        try graph.configure(.init(sampleRate: 44_100))
        XCTAssertEqual(engines.count, 2, "System to System preserves the engine")
        fail = true
        XCTAssertThrowsError(try graph.configure(.init(deviceID: 9)))
        fail = false
        try graph.configure(.init())
        XCTAssertEqual(engines.count, 3, "A failed device application must still be reset before returning to System")
    }
}

@MainActor private final class ResetNodeUnit: PluginUnit {
    let node = AVAudioUnitEQ(numberOfBands: 0)
    var audioNode: AVAudioUnit? { node }
    let trace: Trace
    init(trace: Trace) { self.trace = trace }
    func readState() throws -> Data { Data() }
    func setState(_ state: Data) throws {}
    func setBypass(_ bypassed: Bool) {}
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary { FakeSchedule() }
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void) { completion(FakeEditor(trace: trace)) }
}
