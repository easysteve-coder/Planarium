import AppKit
import AVFoundation
import PlanariumDomain
import PlanariumRuntime

public struct PluginLoadError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    static let graphConstructionTimedOut = PluginLoadError("Audio setup timed out. Please try again.")
}

/// Every mutable AU/UI/graph value is Main-owned. Only the immutable
/// schedule boundary crosses to Q; it never consults a live AU tree there.
@MainActor public protocol PluginUnit: AnyObject {
    var audioNode: AVAudioUnit? { get }
    var parameterDescriptors: [AudioUnitParameterDescriptor] { get }
    /// Musical controls/preset identity, excluding editor geometry and meters.
    /// nil preserves exact opaque-state comparison for unsupported components.
    var musicalStateFingerprint: Data? { get }
    func readState() throws -> Data
    func setState(_ state: Data) throws
    func setBypass(_ bypassed: Bool)
    /// Callback may arrive on any thread. nil synchronously unregisters it.
    func observeBypass(_ changed: (@Sendable (Bool) -> Void)?)
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void)
}

@MainActor public protocol PluginComponentSource {
    func load(_ identity: SpatialAudioUnitIdentity,
              completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void)
}

@MainActor public protocol PluginEditor: AnyObject {
    var controller: NSViewController? { get }
    var initialSize: NSSize { get }
    /// Preferred-size and view-frame events supply THEIR size, not a cached
    /// preferred size. This lets frame-only plug-ins shrink as well as grow.
    func observeSize(_ handler: @escaping @MainActor (NSSize) -> Void)
    func stopObserving()
}

@MainActor public protocol PluginWindow: AnyObject {
    var contentSize: NSSize { get }
    func install(_ editor: any PluginEditor)
    func resize(_ size: NSSize)
    func show(offscreen: Bool)
    func close()
    func clearEditor()
    func observeClose(_ handler: @escaping @MainActor @Sendable () -> Void)
}

@MainActor public protocol PluginWindowFactory {
    func make(title: String, size: NSSize) -> any PluginWindow
}

public struct AudioHostConfiguration: Equatable, Sendable {
    /// nil = current system device. Manual rendering never opens a device.
    public var deviceID: UInt32?
    public var sampleRate: Double
    public var offline: Bool
    public init(deviceID: UInt32? = nil, sampleRate: Double = 48_000, offline: Bool = false) {
        self.deviceID = deviceID; self.sampleRate = sampleRate; self.offline = offline
    }
}

public struct AudioGraphConnectionResult: Sendable {
    public var rejected: [UUID: PluginLoadError] = [:]
    public var failure: PluginLoadError?
    public init() {}
}

@MainActor public protocol AudioGraphBoundary: AnyObject {
    func setHostMusicalClock(_ clock: HostMusicalClock)
    /// nil unregisters immediately. A rebuilt engine has exactly one observer;
    /// notifications from retired/foreign engines never cross this boundary.
    func observeConfigurationChange(_ handler: (@MainActor @Sendable () -> Void)?)
    func configure(_ configuration: AudioHostConfiguration) throws
    func attach(_ instance: PluginInstance, instrument: Bool) throws
    func remove(_ instance: PluginInstance)
    @discardableResult func connect(instrument: PluginInstance?, inserts: [PluginInstance]) -> AudioGraphConnectionResult
    func setPan(_ pan: Double)
    func setLevel(decibels: Double)
    /// Serial render acknowledgement, independent of wall-clock assumptions.
    @discardableResult func fade(silent: Bool) -> UInt32
    func fadeReached(_ token: UInt32) -> Bool
    /// Capture a lifetime-owned atomic receipt on Main; poll it off Main.
    /// The probe must never consult graph/AU objects or acquire render locks.
    func fadeCompletionProbe(_ token: UInt32) -> @Sendable () -> Bool
    /// Native engine availability, invalidated at notification ingress before
    /// Main handles the graph rebuild. No native object reads on Q.
    func scheduleAvailabilityProbe() -> @Sendable () -> Bool
    func setMuted(_ muted: Bool)
    func start() throws
    func stop()
    /// After retire/fade acknowledgement; releases only this branch's nodes.
    func close()
    func installMeter(_ holder: PeakHolder) throws
    func removeMeter()
}

@MainActor public protocol AudioRuntimeBoundary: AnyObject {
    func attach(id: UUID, schedule: any AUScheduleBoundary)
    func attach(id: UUID, stripID: UUID, schedule: any AUScheduleBoundary)
    func attach(id: UUID, stripID: UUID, schedule: any AUScheduleBoundary, resetOnBind: Bool)
    func retire(id: UUID, ack: @escaping @MainActor @Sendable () -> Void)
    func releaseForConfigurationChange()
}

/// Production adapter, asynchronous in both directions. No Main/Q waits.
@MainActor public final class PerformanceAudioPort: AudioRuntimeBoundary {
    private let runtime: PerformanceRuntime
    public init(runtime: PerformanceRuntime) { self.runtime = runtime }
    public func attach(id: UUID, schedule: any AUScheduleBoundary) {
        runtime.attach(RuntimePorts.audioUnit(id: id, boundary: schedule))
    }
    public func attach(id: UUID, stripID: UUID, schedule: any AUScheduleBoundary) {
        runtime.attach(RuntimePorts.audioUnit(id: id, stripID: stripID, boundary: schedule))
    }
    public func attach(id: UUID, stripID: UUID, schedule: any AUScheduleBoundary, resetOnBind: Bool) {
        runtime.attach(RuntimePorts.audioUnit(id: id, stripID: stripID, boundary: schedule, resetOnBind: resetOnBind))
    }
    public func retire(id: UUID, ack: @escaping @MainActor @Sendable () -> Void) {
        runtime.retire(id) { Task { @MainActor in ack() } }
    }
    public func releaseForConfigurationChange() { runtime.releaseAudioForConfigurationChange() }
}

public extension AudioRuntimeBoundary {
    func attach(id: UUID, stripID: UUID, schedule: any AUScheduleBoundary, resetOnBind: Bool) {
        attach(id: id, stripID: stripID, schedule: schedule)
    }
    func releaseForConfigurationChange() {}
    func attach(id: UUID, stripID: UUID, schedule: any AUScheduleBoundary) { attach(id: id, schedule: schedule) }
}

@MainActor public protocol MixerGraphBoundary: AudioGraphBoundary {
    func makeChannelGraph() -> any AudioGraphBoundary
    func setMasterLevel(decibels: Double)
    func installMasterMeter(_ holder: PeakHolder) throws
    func removeMasterMeter()
}

public extension PluginUnit {
    var parameterDescriptors: [AudioUnitParameterDescriptor] { [] }
    var musicalStateFingerprint: Data? { nil }
    func observeBypass(_ changed: (@Sendable (Bool) -> Void)?) {}
}
public extension PluginWindow {
    func observeClose(_ handler: @escaping @MainActor @Sendable () -> Void) {}
}
public extension AudioGraphBoundary {
    func setHostMusicalClock(_ clock: HostMusicalClock) {}
    func scheduleAvailabilityProbe() -> @Sendable () -> Bool { { true } }
    func fadeCompletionProbe(_ token: UInt32) -> @Sendable () -> Bool { { false } }
    func close() {}
    func setPan(_ pan: Double) {}
    func observeConfigurationChange(_ handler: (@MainActor @Sendable () -> Void)?) {}
}

/// Native callbacks publish one scalar. At most one Main delivery is queued;
/// cancellation rejects both queued and late native callbacks.
final class PluginBypassMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Bool?
    private var queued = false
    private var handler: (@MainActor @Sendable (Bool) -> Void)?
    init(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) { self.handler = handler }
    func send(_ value: Bool) {
        lock.lock()
        guard handler != nil else { lock.unlock(); return }
        pending = value
        let enqueue = !queued; queued = true
        lock.unlock()
        if enqueue { Task { @MainActor [weak self] in self?.deliver() } }
    }
    @MainActor private func deliver() {
        lock.lock()
        let value = pending, callback = handler
        pending = nil; queued = false
        lock.unlock()
        if let value { callback?(value) }
    }
    func cancel() {
        lock.lock(); handler = nil; pending = nil; lock.unlock()
    }
}
