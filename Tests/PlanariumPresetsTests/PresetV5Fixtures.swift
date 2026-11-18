import Foundation
import AppKit
import AVFoundation
import PlanariumApplication
import PlanariumAudio
import PlanariumDomain
import PlanariumMIDI
import PlanariumRuntime
import PlanariumInput
import SickPLSMacTransport
import SickPLSControlCore
@testable import PlanariumPresets

func v5Document() throws -> InstrumentDocument {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let a = PolarDeviceLattice(ring: 21, sector: 181)!
    let b = PolarDeviceLattice(ring: 22, sector: 180)!
    let dormant = PolarDeviceLattice(ring: 23, sector: 182)!
    let layer = SpatialDocumentLayer(id: id, name: "Fine lattice", color: .orange,
        isVisible: true, isActive: true, isLocked: false, isSoloed: true,
        cells: [a, b], routings: [
            .init(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!, target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), program: .chord(notes: [60, 64, 67], velocity: 100, transition: .legato)),
            .init(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!, target: .audioUnitNote(channel: 1, stripID: InstrumentChannel.legacyID), program: .constant(64))
        ], cellOverrides: [a: [], b: [.init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), value: .note(number: 72, velocity: 88))], dormant: []], toggleGuardSeconds: 0)
    let identity = SpatialAudioUnitIdentity(componentType: 0x61756D75, componentSubType: 1, componentManufacturer: 2)
    let effect = SpatialAudioUnitIdentity(componentType: 0x61756678, componentSubType: 3, componentManufacturer: 2)
    // This fixture is a frozen pre-MMK/edge/core byte oracle. New-document
    // defaults are covered independently by the domain and factory contracts.
    let detection = DetectionConfiguration(temporalSmoothing: .median(window: 3), groupingMinimumPoints: 2, representative: .median,
        cellSelection: .init(boundaryMarginCentimeters: 2, confirmationProfiles: 3), continuousBacklashCentimeters: 3,
        virtualMMKMode: .raw, edgePoints: 0, coreWidthCentimeters: 0)
    return .init(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id), detection: detection,
        channel: .init(instrument: .init(identity: identity, state: Data([9, 10])), inserts: [
            .init(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!, plugin: .init(identity: effect, state: Data([11])), bypassed: true),
            .init(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!, plugin: .init(identity: effect, state: Data([12])))
        ], levelDecibels: -4.25, midiTarget: .init(uniqueID: 123456), pan: -0.375, muted: true, soloed: true),
        revision: .init(session: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!, counter: 97),
        editorGrid: .quarterMeter, channelName: "Channel", channelColor: .blue)
}

final class V5Schedule: AUScheduleBoundary, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var sends: Int { lock.lock(); defer { lock.unlock() }; return count }
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { lock.lock(); count += 1; lock.unlock(); return .sent }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
}
@MainActor final class V5Unit: PluginUnit {
    var audioNode: AVAudioUnit? { nil }
    var state = Data([101])
    var musicalStateFingerprint: Data?
    var applied: [Data] = []
    var bypass: [Bool] = []
    var readFails = false
    var volatileReads = false
    var stateReads = 0
    var editorRequests = 0
    var editorToReturn: (any PluginEditor)?
    let schedule = V5Schedule()
    func readState() throws -> Data { if readFails { throw PluginLoadError("INVENTED-STATE-ERROR") }; stateReads += 1; return volatileReads ? state + Data(String(stateReads).utf8) : state }
    func setState(_ state: Data) throws { self.state = state; applied.append(state) }
    func setBypass(_ bypassed: Bool) { bypass.append(bypassed) }
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary { schedule }
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void) { editorRequests += 1; if let editorToReturn { completion(editorToReturn) } }
}
@MainActor final class V5Source: PluginComponentSource {
    var units: [V5Unit] = []
    var identities: [SpatialAudioUnitIdentity] = []
    var deferred = false
    private var pending: [@MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void] = []
    func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        identities.append(identity)
        if deferred { pending.append(completion) }
        else { let unit = V5Unit(); units.append(unit); completion(.success(unit)) }
    }
    func finishNext() { let unit = V5Unit(); units.append(unit); pending.removeFirst()(.success(unit)) }
}
@MainActor final class V5Graph: AudioGraphBoundary {
    func fade(silent: Bool) -> UInt32 { 0 }
    func fadeReached(_ token: UInt32) -> Bool { true }
    func setMuted(_ muted: Bool) {}
    func installMeter(_ holder: PeakHolder) {}
    func removeMeter() {}
    var starts = 0
    var connections: [UUID] = []
    func configure(_ configuration: AudioHostConfiguration) throws {}
    func attach(_ instance: PluginInstance, instrument: Bool) throws {}
    func remove(_ instance: PluginInstance) {}
    @discardableResult func connect(instrument: PluginInstance?, inserts: [PluginInstance]) -> AudioGraphConnectionResult {
        connections = inserts.map(\.id); return .init()
    }
    func setLevel(decibels: Double) {}
    func start() throws { starts += 1 }
    func stop() {}
}
@MainActor final class V5Editor: PluginEditor {
    var controller: NSViewController? { nil }
    var initialSize: NSSize { .init(width: 400, height: 200) }
    func observeSize(_ handler: @escaping @MainActor (NSSize) -> Void) {}
    func stopObserving() {}
}
@MainActor final class V5Window: PluginWindow {
    var contentSize = NSSize(width: 1, height: 1)
    func install(_ editor: any PluginEditor) {}
    func resize(_ size: NSSize) { contentSize = size }
    func show(offscreen: Bool) {}
    func close() {}
    func clearEditor() {}
}
@MainActor final class V5Windows: PluginWindowFactory {
    var makes = 0
    func make(title: String, size: NSSize) -> any PluginWindow { makes += 1; return V5Window() }
}
@MainActor final class V5Harness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("P6-\(UUID().uuidString)")
    let source = V5Source()
    let graph = V5Graph()
    let windows = V5Windows()
    let scanner = V5Scanner()
    let root: PlanariumComposition
    let store: PresetFileStore
    let presets: PresetControlModel
    init(factoryPresets: FactoryPresetLibrary = .empty) throws {
        root = try .init(scanner: scanner, midi: PresetFakeMIDI(), components: source, configuration: .init(offline: true), graph: graph, windows: windows)
        store = .init(directory: directory)
        presets = .init(store: store, documentOwner: root.document, factoryPresets: factoryPresets)
    }
    func write(_ preset: InstrumentPresetV5) throws { try store.save(PresetV5Codec.encode(preset), as: preset.name) }
    func settle() async {
        for _ in 0..<100 {
            await Task.yield()
            if root.audio.status.values.allSatisfy({ $0 == .loaded || $0 == .bypass }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    func finish() async {
        await withCheckedContinuation { continuation in root.terminate { continuation.resume() } }
        try? FileManager.default.removeItem(at: directory)
    }
}
final class V5Descriptor: SerialPortFileDescriptor, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        lock.lock(); let done = closed; lock.unlock()
        Thread.sleep(forTimeInterval: 0.001)
        return done ? .closed : .timeout
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
}
final class V5Scanner: SerialPortOpener, ScanByteStreamOpening, Sendable {
    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> any SerialPortFileDescriptor { V5Descriptor() }
    func openStream() throws -> any SerialPortFileDescriptor { V5Descriptor() }
}
