import AVFoundation
import XCTest
import PlanariumDomain
import PlanariumRuntime
@testable import PlanariumAudio

@MainActor final class NativeGraphExceptionTests: XCTestCase {
    private func property<T>(_ name: String, of graph: AVAudioGraph, as type: T.Type) throws -> T {
        try XCTUnwrap(Mirror(reflecting: graph).children.first { $0.label == name }?.value as? T)
    }

    func testRealConnectExceptionBecomesFailedInsertAndRestRendersOffline() throws {
        let engine = AVAudioEngine(), graph = AVAudioGraph(makeEngine: { engine }, selectDevice: { _, _ in })
        let trace = Trace(), components = NativeExceptionComponents()
        let runtime = FakeRuntime(trace: trace)
        let host = try AudioHost(components: components, graph: graph, runtime: runtime,
            windows: FakeWindows(trace: trace), configuration: .init(offline: true))
        defer { host.shutdown() }
        let bad = InstrumentInsert(id: UUID(), plugin: plugin(3, instrument: false))
        let good = InstrumentInsert(id: UUID(), plugin: plugin(4, instrument: false))
        components.badIdentity = bad.plugin.identity
        host.apply(.init(inserts: [bad, good]))
        var channel = host.channel
        channel.inserts[0].bypassed = true; host.apply(channel)
        channel.inserts[0].bypassed = false; host.apply(channel)
        // Bypass itself no longer rewires.  A true chain change must still
        // surface the detached AU as a local failed insert.
        channel.inserts.reverse(); host.apply(channel)
        guard case .failed(let message) = host.status[.insert(bad.id)] else { return XCTFail("Native exception must reach failed") }
        XCTAssertTrue(message.contains("required condition is false"), message)
        XCTAssertTrue(message.contains("com.apple.coreaudio.avfaudio"), message)
        XCTAssertNil(host.inserts[bad.id]); XCTAssertEqual(host.status[.insert(good.id)], .loaded)
        XCTAssertEqual(engine.attachedNodes.subtracting([engine.mainMixerNode, engine.outputNode]).count, 6, "Failed insert is absent; converter, strip mixer/gain, sum gain, fade and good insert remain")
        let converter = try property("converter", of: graph, as: AVAudioMixerNode.self)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = AVAudioSourceNode(format: format) { _, _, frames, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(frames) { data[i] = 0.25 }
            }
            return noErr
        }
        engine.attach(source); engine.connect(source, to: converter, format: format)
        try host.start()
        let rendered = try graph.renderOffline()
        let data = try XCTUnwrap(rendered.floatChannelData)
        XCTAssertEqual(data[0][Int(rendered.frameLength) - 1], 0.25, accuracy: 1e-6)
        XCTAssertTrue(host.isRunning); XCTAssertNil(host.graphFailure)
        host.apply(host.channel); XCTAssertEqual(components.loads, 2, "No hidden reload of rejected insert")
        print("AUDIO-HOST-1 real connect caught: \(message); remaining chain offline peak=0.25")
    }

    func testRealAttachExceptionDoesNotStealForeignNodeOrLeavePartialAttachment() throws {
        let engine = AVAudioEngine(), foreign = AVAudioEngine()
        let graph = AVAudioGraph(makeEngine: { engine }, selectDevice: { _, _ in })
        try graph.configure(.init(offline: true)); defer { graph.stop() }
        let originalNodes = engine.attachedNodes
        let unit = NativeExceptionUnit(detachOnBypass: false)
        foreign.attach(unit.node)
        defer { foreign.detach(unit.node) }
        let instance = PluginInstance(identity: plugin().identity, unit: unit, windows: FakeWindows(trace: Trace()))
        XCTAssertThrowsError(try graph.attach(instance, instrument: true)) { error in
            XCTAssertTrue((error as? PluginLoadError)?.message.contains("required condition is false") == true)
        }
        XCTAssertTrue(unit.node.engine === foreign)
        XCTAssertEqual(engine.attachedNodes, originalNodes)
        graph.remove(instance)
        XCTAssertTrue(unit.node.engine === foreign)
    }

    func testRealTapExceptionIsCaughtAndTapCanBeInstalledAfterRepair() throws {
        let graph = AVAudioGraph(); try graph.configure(.init(offline: true))
        graph.connect(instrument: nil, inserts: []); try graph.start()
        defer { graph.stop() }
        let meterNode = try XCTUnwrap(property("fadeNode", of: graph, as: Optional<AVAudioUnit>.self))
        meterNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
        XCTAssertThrowsError(try graph.installMeter(PeakHolder())) { error in
            XCTAssertTrue(error is PluginLoadError)
        }
        XCTAssertFalse(try property("meterInstalled", of: graph, as: Bool.self))
        meterNode.removeTap(onBus: 0)
        try graph.installMeter(PeakHolder())
        XCTAssertTrue(try property("meterInstalled", of: graph, as: Bool.self))
        graph.removeMeter()
        XCTAssertFalse(try property("meterInstalled", of: graph, as: Bool.self))
    }

    func testPersistentEdgeExceptionBecomesGraphFailureAndExplicitRebuildRecovers() throws {
        let engine = AVAudioEngine(), graph = AVAudioGraph(makeEngine: { engine }, selectDevice: { _, _ in })
        let trace = Trace()
        let host = try AudioHost(components: FakeComponents(), graph: graph, runtime: FakeRuntime(trace: trace),
            windows: FakeWindows(trace: trace), configuration: .init(offline: true))
        defer { host.shutdown() }
        let gain = try property("gain", of: graph, as: AVAudioUnitEQ.self)
        engine.detach(gain)
        host.apply(host.channel)
        XCTAssertTrue(host.graphFailure?.contains("required condition is false") == true)
        XCTAssertFalse(host.isRunning)
        XCTAssertThrowsError(try host.start())
        host.configure(host.configuration)
        try host.start()
        XCTAssertNil(host.graphFailure); XCTAssertTrue(host.isRunning)
        _ = try graph.renderOffline()
    }
}

@MainActor private final class NativeExceptionComponents: PluginComponentSource {
    var badIdentity: SpatialAudioUnitIdentity?
    var loads = 0
    func load(_ identity: SpatialAudioUnitIdentity,
              completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        loads += 1
        completion(.success(NativeExceptionUnit(detachOnBypass: identity == badIdentity)))
    }
}

/// A bypass transition detaches this node. The next unbypass reconnect then
/// produces an actual AVAudioEngine exception,
/// without a fake throwing closure or a physical device start.
@MainActor private final class NativeExceptionUnit: PluginUnit {
    let node = AVAudioUnitEQ(numberOfBands: 0)
    let detachOnBypass: Bool
    init(detachOnBypass: Bool) { self.detachOnBypass = detachOnBypass }
    var audioNode: AVAudioUnit? { node }
    func readState() throws -> Data { Data() }
    func setState(_ state: Data) throws {}
    func setBypass(_ bypassed: Bool) {
        if detachOnBypass, bypassed, let engine = node.engine { engine.detach(node) }
    }
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary { FakeSchedule() }
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void) {
        completion(FakeEditor(trace: Trace()))
    }
}
