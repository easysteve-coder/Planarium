import AppKit
import AVFoundation
import PlanariumDomain
import PlanariumRuntime
import XCTest
@testable import PlanariumAudio

func identity(_ sub: UInt32 = 1, instrument: Bool = true) -> SpatialAudioUnitIdentity {
    .init(componentType: instrument ? 0x61756D75 : 0x61756678, componentSubType: sub, componentManufacturer: 2)
}
func plugin(_ sub: UInt32 = 1, instrument: Bool = true, state: UInt8? = nil) -> InstrumentPlugin {
    .init(identity: identity(sub, instrument: instrument), state: state.map { Data([$0]) } ?? Data())
}
@MainActor final class Trace { var events: [String] = [] }
final class FakeSchedule: AUScheduleBoundary, @unchecked Sendable {
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { .sent }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
}
@MainActor final class FakeEditor: PluginEditor {
    var controller: NSViewController? { nil }
    var initialSize: NSSize
    var handler: (@MainActor (NSSize) -> Void)?
    let trace: Trace
    init(size: NSSize = .init(width: 400, height: 200), trace: Trace) { initialSize = size; self.trace = trace }
    func observeSize(_ handler: @escaping @MainActor (NSSize) -> Void) { self.handler = handler }
    func stopObserving() { trace.events.append("editor-release"); handler = nil }
    func resize(_ size: NSSize) { initialSize = size; handler?(size) }
}
@MainActor final class FakeUnit: PluginUnit {
    var audioNode: AVAudioUnit? { nil }
    var state = Data()
    var musicalStateFingerprint: Data?
    var states: [Data] = []
    var bypasses: [Bool] = []
    var bypassObservation: (@Sendable (Bool) -> Void)?
    var bypassUnregistrations = 0
    func observeBypass(_ changed: (@Sendable (Bool) -> Void)?) {
        bypassObservation = changed
        if changed == nil { bypassUnregistrations += 1 }
    }
    var editorRequests = 0
    var stateFails = false
    var stateReads = 0
    var schedule: any AUScheduleBoundary = FakeSchedule()
    var deferEditor = false
    var editorCompletion: (@MainActor @Sendable (any PluginEditor) -> Void)?
    var editorFactory: (@MainActor () -> any PluginEditor)?
    let editor: any PluginEditor
    let trace: Trace
    init(trace: Trace, editor: (any PluginEditor)? = nil) { self.trace = trace; self.editor = editor ?? FakeEditor(trace: trace) }
    func readState() throws -> Data { stateReads += 1; return state }
    func setState(_ state: Data) throws {
        if stateFails { throw PluginLoadError("bad state") }
        states.append(state); self.state = state
    }
    func setBypass(_ bypassed: Bool) { bypasses.append(bypassed) }
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary { schedule }
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void) {
        editorRequests += 1
        if deferEditor { editorCompletion = completion } else { completion(editorFactory?() ?? editor) }
    }
}
@MainActor final class FakeComponents: PluginComponentSource {
    struct Request { let identity: SpatialAudioUnitIdentity; let complete: @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void }
    var requests: [Request] = []
    func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        requests.append(.init(identity: identity, complete: completion))
    }
    func succeed(_ index: Int, _ unit: FakeUnit) { requests[index].complete(.success(unit)) }
    func fail(_ index: Int) { requests[index].complete(.failure(.init("unavailable"))) }
}
@MainActor final class FakeWindow: PluginWindow {
    var contentSize: NSSize
    var editor: (any PluginEditor)?
    var resizeCount = 0
    var showCount = 0
    var feedback = false
    let trace: Trace
    init(size: NSSize, trace: Trace) { contentSize = size; self.trace = trace }
    // Model NSWindow's synchronous ownership of its content-view frame.
    // Host installs the editor in the same production container used by AppKit.
    private var content: NSView?
    private var contentController: NSViewController?
    private var contentObserver: NSObjectProtocol?
    func install(_ editor: any PluginEditor) {
        self.editor = editor
        contentController = PluginEditorContent.make(editor, size: contentSize)
        content = contentController?.view
        content?.setFrameSize(contentSize)
        if let content {
            contentObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.content, view.frame.size != self.contentSize else { return }
                    view.setFrameSize(self.contentSize)
                }
            }
        }
    }
    func resize(_ size: NSSize) {
        resizeCount += 1; contentSize = size
        content?.setFrameSize(size)
        content?.subviews.first?.setFrameSize(size)
        if feedback { (editor as? FakeEditor)?.resize(size) }
    }
    func show(offscreen: Bool) { showCount += 1 }
    func close() { trace.events.append("window-close") }
    func clearEditor() {
        trace.events.append("window-clear")
        if let contentObserver { NotificationCenter.default.removeObserver(contentObserver) }
        if let contentController { PluginEditorContent.clear(contentController) }
        contentObserver = nil; editor = nil; content = nil; contentController = nil
    }
}
@MainActor final class FakeWindows: PluginWindowFactory {
    let trace: Trace
    var windows: [FakeWindow] = []
    init(trace: Trace) { self.trace = trace }
    func make(title: String, size: NSSize) -> any PluginWindow {
        let window = FakeWindow(size: size, trace: trace); windows.append(window); return window
    }
}
@MainActor final class FakeGraph: MixerGraphBoundary {
    var branches: [FakeGraph] = []
    var masterLevels: [Double] = []
    func makeChannelGraph() -> any AudioGraphBoundary { let child = FakeGraph(trace: trace); branches.append(child); return child }
    func setMasterLevel(decibels: Double) { masterLevels.append(decibels) }
    func installMasterMeter(_ holder: PeakHolder) {}
    func removeMasterMeter() {}
    let trace: Trace
    var attached: Set<UUID> = []
    var ordered: [UUID] = []
    var source: UUID?
    var rendered: [UUID: Int] = [:]
    func render() { for id in ordered { rendered[id, default: 0] += 1 } }
    var configurations: [AudioHostConfiguration] = []
    var levels: [Double] = []
    var failingIdentities: Set<SpatialAudioUnitIdentity> = []
    var starts = 0
    var meter: PeakHolder?
    var meterInstalls = 0
    var meterRemovals = 0
    func installMeter(_ holder: PeakHolder) throws {
        if meterFails { throw PluginLoadError("Synthetic tap rejection") }
        meter = holder; meterInstalls += 1
    }
    func removeMeter() { meter = nil; meterRemovals += 1 }
    var configurationFails = false
    var configurationError: PluginLoadError?
    var startFails = false
    var running = false
    var muted = false
    var transitionSilent = false
    var fadeToken: UInt32 = 0
    var reachedToken: UInt32 = 0
    var mainFadeQueries = 0
    private let fadeReceipt = FakeFadeReceipt()
    var fadeRequests: [Bool] = []
    var connections = 0
    var configurationHandler: (@MainActor @Sendable () -> Void)?
    var connectionFailures: [SpatialAudioUnitIdentity: PluginLoadError] = [:]
    var meterFails = false
    var unavailableDevices: Set<UInt32> = []
    func observeConfigurationChange(_ handler: (@MainActor @Sendable () -> Void)?) { configurationHandler = handler }
    func reportConfigurationChange() { running = false; configurationHandler?() }
    func fade(silent: Bool) -> UInt32 {
        transitionSilent = silent; fadeToken &+= 1
        fadeRequests.append(silent); trace.events.append(silent ? "fade-0" : "fade-1")
        return fadeToken
    }
    func fadeReached(_ token: UInt32) -> Bool { mainFadeQueries += 1; return reachedToken == token }
    func fadeCompletionProbe(_ token: UInt32) -> @Sendable () -> Bool { { [fadeReceipt] in fadeReceipt.reached(token) } }
    func reportFadeReached() { reachedToken = fadeToken; fadeReceipt.set(fadeToken); trace.events.append("fade-reached") }
    func setMuted(_ muted: Bool) { self.muted = muted }
    init(trace: Trace) { self.trace = trace }
    func configure(_ configuration: AudioHostConfiguration) throws {
        stop(); attached.removeAll(); ordered.removeAll(); source = nil
        setMasterLevel(decibels: 0)
        configurations.append(configuration)
        if let configurationError { throw configurationError }
        if configurationFails || configuration.deviceID.map({ unavailableDevices.contains($0) }) == true { throw PluginLoadError("configuration refused") }
    }
    func attach(_ instance: PluginInstance, instrument: Bool) throws {
        if failingIdentities.contains(instance.identity) { throw PluginLoadError("format refused") }
        trace.events.append("graph-attach"); attached.insert(instance.id)
    }
    func remove(_ instance: PluginInstance) {
        trace.events.append("graph-remove"); attached.remove(instance.id)
        ordered.removeAll { $0 == instance.id }; if source == instance.id { source = nil }
    }
    @discardableResult func connect(instrument: PluginInstance?, inserts: [PluginInstance]) -> AudioGraphConnectionResult {
        var result = AudioGraphConnectionResult()
        for instance in inserts + [instrument].compactMap({ $0 }) {
            if let error = connectionFailures[instance.identity] { result.rejected[instance.id] = error }
        }
        source = instrument.flatMap { result.rejected[$0.id] == nil ? $0.id : nil }
        ordered = inserts.filter { result.rejected[$0.id] == nil }.map(\.id); connections += 1
        if !fadeRequests.isEmpty { trace.events.append("graph-connect") }
        return result
    }
    func setLevel(decibels: Double) { levels.append(decibels) }
    func start() throws { starts += 1; if startFails { throw PluginLoadError("start refused") }; running = true }
    func stop() {
        trace.events.append("graph-stop"); if meter != nil { removeMeter() }
        running = false; transitionSilent = false; reachedToken = fadeToken
        fadeReceipt.set(fadeToken)
    }
}
private final class FakeFadeReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UInt32 = 0
    func set(_ value: UInt32) { lock.lock(); token = value; lock.unlock() }
    func reached(_ value: UInt32) -> Bool { lock.lock(); defer { lock.unlock() }; return token == value }
}
@MainActor final class FakeRuntime: AudioRuntimeBoundary {
    let trace: Trace
    var attachments: [UUID] = []
    var schedules: [UUID: any AUScheduleBoundary] = [:]
    var stripIDs: [UUID: UUID] = [:]
    var acknowledgements: [@MainActor @Sendable () -> Void] = []
    var retirements: [UUID] = []
    init(trace: Trace) { self.trace = trace }
    func attach(id: UUID, schedule: any AUScheduleBoundary) {
        trace.events.append("runtime-attach"); attachments.append(id); schedules[id] = schedule
    }
    func attach(id: UUID, stripID: UUID, schedule: any AUScheduleBoundary) {
        stripIDs[id] = stripID; attach(id: id, schedule: schedule)
    }
    func retire(id: UUID, ack: @escaping @MainActor @Sendable () -> Void) {
        trace.events.append("retire"); retirements.append(id); acknowledgements.append(ack)
    }
    func ack(_ index: Int = 0) {
        guard retirements.indices.contains(index), acknowledgements.indices.contains(index) else {
            XCTFail("Missing expected runtime retire acknowledgement at \(index)"); return
        }
        trace.events.append("ack"); schedules[retirements[index]] = nil
        let callback = acknowledgements[index]
        acknowledgements[index] = {}
        callback()
    }
}
@MainActor struct Harness {
    let trace = Trace()
    let components = FakeComponents()
    let graph: FakeGraph
    let runtime: FakeRuntime
    let windows: FakeWindows
    let host: AudioHost
    init() throws {
        graph = FakeGraph(trace: trace); runtime = FakeRuntime(trace: trace); windows = FakeWindows(trace: trace)
        host = try AudioHost(components: components, graph: graph, runtime: runtime, windows: windows)
    }
    func unit(editor: (any PluginEditor)? = nil) -> FakeUnit { FakeUnit(trace: trace, editor: editor) }
    func finish() { host.shutdown(); if host.instrument != nil { runtime.ack(runtime.acknowledgements.count - 1) } }
}

/// Real retire acknowledgement and a separately supplied render acknowledgement.
/// Used where the contract now includes both boundaries before detach/rebuild.
@MainActor func acknowledgeRetireAndFade(_ h: Harness) async throws {
    h.runtime.ack(h.runtime.acknowledgements.count - 1)
    if h.graph.transitionSilent {
        h.graph.reportFadeReached()
        for _ in 0..<200 {
            if !h.graph.transitionSilent { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(h.graph.transitionSilent)
    }
}

@MainActor final class FakeOutputCatalog: AudioOutputCatalog {
    var devices: [AudioOutputDevice] = [
        .init(id: 0, name: "Built-in Output", isSystemOutput: true),
        .init(id: 1, name: "Built-in Output", isSystemOutput: false, uid: "builtin"),
        .init(id: 2, name: "AudioBox iTwo", isSystemOutput: false, uid: "audiobox")]
    var changed: (@MainActor @Sendable () -> Void)?
    var observations = 0
    func outputs() -> [AudioOutputDevice] { devices }
    func rates(for device: AudioOutputDevice) -> [Double] { [44_100, 48_000] }
    func observe(_ changed: (@MainActor @Sendable () -> Void)?) { self.changed = changed; if changed != nil { observations += 1 } }
}
@MainActor final class FakeOutputPreferences: AudioOutputPreferences {
    var deviceUID: String?
    var deviceName: String?
    var audioEnabled = false
}
