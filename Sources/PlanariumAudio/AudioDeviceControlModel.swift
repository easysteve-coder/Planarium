import Combine
import CoreAudio
import Foundation

public struct AudioOutputDevice: Equatable, Identifiable, Sendable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let isSystemOutput: Bool
    public let sampleRate: Double?
    public init(id: UInt32, name: String, isSystemOutput: Bool, uid: String = "", sampleRate: Double? = nil) {
        self.id = id; self.uid = uid; self.name = name; self.isSystemOutput = isSystemOutput; self.sampleRate = sampleRate
    }
}

@MainActor public protocol AudioOutputCatalog: AnyObject {
    func outputs() -> [AudioOutputDevice]
    func rates(for device: AudioOutputDevice) -> [Double]
    func observe(_ changed: (@MainActor @Sendable () -> Void)?)
    var observationNotice: String? { get }
}
public extension AudioOutputCatalog { var observationNotice: String? { nil } }
@MainActor public protocol AudioOutputPreferences: AnyObject {
    var deviceUID: String? { get set }
    var deviceName: String? { get set }
    var audioEnabled: Bool { get set }
}
@MainActor public final class UserDefaultsAudioOutputPreferences: AudioOutputPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var deviceUID: String? {
        get { defaults.string(forKey: "audio.outputUID") }
        set { defaults.set(newValue, forKey: "audio.outputUID") }
    }
    public var deviceName: String? {
        get { defaults.string(forKey: "audio.outputName") }
        set { defaults.set(newValue, forKey: "audio.outputName") }
    }
    public var audioEnabled: Bool {
        get { defaults.bool(forKey: "audio.enabled") }
        set { defaults.set(newValue, forKey: "audio.enabled") }
    }
}

@MainActor public final class AudioOutputDeviceControlModel: ObservableObject {
    @Published public private(set) var devices: [AudioOutputDevice] = []
    @Published public private(set) var selectedDevice = AudioOutputDevice(id: 0, name: "System Output", isSystemOutput: true)
    @Published public private(set) var desiredDevice = AudioOutputDevice(id: 0, name: "System Output", isSystemOutput: true)
    @Published public private(set) var currentSampleRate: Double
    @Published public private(set) var availableSampleRates: [Double] = []
    @Published public private(set) var notice: String?
    @Published public private(set) var canRestoreDevice = false
    @Published public private(set) var audioIsRunning = false
    @Published public private(set) var pendingDeviceAlert: String?
    private var lastAnnouncedDeviceEvent: String?
    private let host: AudioHost
    private let catalog: any AudioOutputCatalog
    private let preferences: (any AudioOutputPreferences)?
    private let startAction: (@MainActor () -> Void)?
    private var active = true
    private var observations: [AnyCancellable] = []
    private var fallback = false
    private var refreshing = false
    private var restored = false
    private var configurationNotice: String?
    private var graphNotice: String?
    private var slotNotice: String?
    public init(host: AudioHost, catalog: (any AudioOutputCatalog)? = nil,
                preferences: (any AudioOutputPreferences)? = nil, startAudio: (@MainActor () -> Void)? = nil) {
        self.host = host; self.catalog = catalog ?? SystemAudioOutputCatalog(); self.preferences = preferences; self.startAction = startAudio
        currentSampleRate = host.configuration.sampleRate
        if let uid = preferences?.deviceUID {
            desiredDevice = .init(id: 0, name: preferences?.deviceName ?? "Saved output", isSystemOutput: false, uid: uid)
        } else if let id = host.configuration.deviceID {
            desiredDevice = .init(id: id, name: "Output \(id)", isSystemOutput: false)
        }
        selectedDevice = desiredDevice
        observations = [host.$configuration.dropFirst().sink { [weak self] value in
            self?.currentSampleRate = value.sampleRate
            self?.slotNotice = nil
            Task { @MainActor [weak self] in self?.refresh() }
        }, host.$configurationNotice.sink { [weak self] value in
            self?.configurationNotice = value; self?.updateNotice()
        }, host.$graphFailure.sink { [weak self] value in
            self?.graphNotice = value; self?.updateNotice()
        },
        host.$unavailableDeviceID.sink { [weak self] id in
            guard let self, let id, !self.desiredDevice.isSystemOutput, self.desiredDevice.id == id else { return }
            self.fallback = true; self.updateNotice()
        }, host.$status.sink { [weak self] values in
            let failure = values.values.compactMap { value -> String? in
                if case .failed(let message) = value, message.hasPrefix("Audio configuration:") { return message }
                return nil
            }.sorted().first
            if let failure { self?.slotNotice = failure }
            self?.updateNotice()
        }, host.$isRunning.sink { [weak self] running in
            self?.audioIsRunning = running; self?.updateNotice()
        }, host.$audioEnabled.dropFirst().sink { [weak self] enabled in
            self?.preferences?.audioEnabled = enabled
        }]
        // Install once; shutdown detaches the native listener before the host.
        self.catalog.observe { [weak self] in self?.refresh() }
        updateNotice()
    }
    /// App startup only. Tests and secondary presentations never start audio.
    public func restoreAtStartup() {
        guard !restored else { return }
        restored = true
        let enabled = preferences?.audioEnabled == true
        refresh()
        if enabled, !fallback, !devices.isEmpty {
            // Startup restoration is independent of the current Edit/Perform
            // permission. Click-to-start still uses the explicit UI action.
            do { try host.start() } catch { updateNotice() }
        }
        else if enabled { updateNotice() }
    }
    public func shutdown() { active = false; catalog.observe(nil); observations.removeAll() }
    public var outputSampleRate: Double { selectedDevice.sampleRate ?? currentSampleRate }
    public var outputSummary: String {
        let device = selectedDevice.name + (selectedDevice.isSystemOutput ? " (System)" : "")
        return "\(device) · \(String(format: "%g", outputSampleRate / 1000)) kHz"
    }
    public var stripSummary: String { audioIsRunning ? outputSummary : "Audio off – click to start" }
    public var stripNoticeSummary: String? { notice == nil ? nil : canRestoreDevice ? "Output returned" : fallback ? "Output missing" : "Audio error" }
    public func acknowledgeDeviceAlert() { pendingDeviceAlert = nil }
    public func startAudio() {
        guard active else { return }
        if let startAction { startAction(); return }
        do { try host.start() } catch { updateNotice() }
    }
    public func refresh() {
        guard active, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        devices = catalog.outputs()
        let system = devices.first(where: \.isSystemOutput) ?? .init(id: 0, name: "No output", isSystemOutput: true)
        let remembered = desiredDevice.isSystemOutput ? system : devices.first {
            !$0.isSystemOutput && (desiredDevice.uid.isEmpty ? $0.id == desiredDevice.id : $0.uid == desiredDevice.uid)
        }
        if !desiredDevice.isSystemOutput, remembered == nil { fallback = true }
        canRestoreDevice = fallback && remembered != nil
        let target = fallback ? system : (remembered ?? system)
        if !fallback { desiredDevice = target }
        var config = host.configuration
        config.deviceID = target.isSystemOutput ? nil : target.id
        // configure compares against its pending intent as well as confirmed
        // configuration, so choosing the original route cancels a pending one.
        host.configure(config)
        // Report the confirmed route while the existing retire barrier works.
        selectedDevice = host.configuration.deviceID.flatMap { id in devices.first { !$0.isSystemOutput && $0.id == id } } ?? system
        if let id = host.configuration.deviceID, selectedDevice.isSystemOutput {
            selectedDevice = .init(id: id, name: "Output \(id) (unavailable)", isSystemOutput: false)
        }
        availableSampleRates = catalog.rates(for: selectedDevice)
        if !availableSampleRates.contains(currentSampleRate) { availableSampleRates.append(currentSampleRate); availableSampleRates.sort() }
        updateNotice()
    }
    public func selectDevice(_ device: AudioOutputDevice) {
        guard device.isSystemOutput || !device.uid.isEmpty else { notice = "Device UID unavailable; choose System Output"; return }
        desiredDevice = device; fallback = false
        preferences?.deviceUID = device.isSystemOutput ? nil : device.uid
        preferences?.deviceName = device.isSystemOutput ? nil : device.name
        refresh()
    }
    public func restoreDesiredDevice() {
        fallback = false; refresh()
        if !fallback, (preferences?.audioEnabled ?? host.audioEnabled), !host.playbackRequested {
            do { try host.start() } catch { updateNotice() }
        }
    }
    public func setSampleRate(_ rate: Double) {
        guard availableSampleRates.contains(rate) else { notice = "Sample rate unavailable"; return }
        var config = host.configuration; config.sampleRate = rate
        host.configure(config)
    }
    private func updateNotice() {
        if fallback {
            if canRestoreDevice { notice = "\(desiredDevice.name) is available again – restore output?" }
            else {
                let systemName = devices.first(where: \.isSystemOutput)?.name ?? "No output"
                let outcome = audioIsRunning ? "fallback: \(systemName)" : "no sound · fallback: \(systemName)"
                notice = "\(desiredDevice.name) not found – \(outcome)"
            }
        } else if devices.isEmpty, restored { notice = "No audio output available – no sound" }
        else { notice = configurationNotice ?? slotNotice ?? graphNotice ?? catalog.observationNotice }
        if fallback {
            let event = "\(desiredDevice.uid):\(desiredDevice.name):\(canRestoreDevice ? "returned" : "missing")"
            if event != lastAnnouncedDeviceEvent { lastAnnouncedDeviceEvent = event; pendingDeviceAlert = notice }
        } else { lastAnnouncedDeviceEvent = nil }
    }
}

@MainActor final class SystemAudioOutputCatalog: AudioOutputCatalog {
    private var observation: AudioCatalogObservation?
    var observationNotice: String? { observation?.notice }
    func outputs() -> [AudioOutputDevice] { AudioDeviceCatalog.outputDevices() }
    func rates(for device: AudioOutputDevice) -> [Double] { AudioDeviceCatalog.rates(for: device) }
    func observe(_ changed: (@MainActor @Sendable () -> Void)?) {
        observation?.remove(); observation = nil
        if let changed { observation = AudioCatalogObservation(changed: changed) }
    }
}

/// The native registration owns its exact callback blocks. Queued/late events
/// retain only the cancelled scalar mailbox, never a model or device handle.
final class AudioCatalogObservation {
    typealias Registration = (UInt32, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    private var listeners: [(UInt32, AudioObjectPropertyListenerBlock)] = []
    private let unregister: Registration
    private let mailbox: PluginBypassMailbox
    private(set) var notice: String?
    init(changed: @escaping @MainActor @Sendable () -> Void,
         register: Registration = AudioCatalogObservation.add,
         unregister: @escaping Registration = AudioCatalogObservation.remove) {
        self.unregister = unregister
        mailbox = PluginBypassMailbox { _ in changed() }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            let mailbox = mailbox
            let block: AudioObjectPropertyListenerBlock = { _, _ in mailbox.send(true) }
            let result = register(selector, block)
            if result == noErr { listeners.append((selector, block)) }
            else { notice = "Audio device notifications unavailable (\(result)); refresh output settings" }
        }
    }
    func remove() {
        mailbox.cancel()
        for (selector, block) in listeners { _ = unregister(selector, block) }
        listeners.removeAll()
    }
    deinit { remove() }
    private static func address(_ selector: UInt32) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func add(_ selector: UInt32, _ block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        var address = address(selector)
        return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
    private static func remove(_ selector: UInt32, _ block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        var address = address(selector)
        return AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
}
public enum AudioDeviceCatalog {
    public static func rates(for device: AudioOutputDevice) -> [Double] {
        availableSampleRates(deviceID: device.isSystemOutput ? defaultOutputDeviceID() : device.id)
    }
    public static func outputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        let physical: [AudioOutputDevice] = ids.compactMap { id in
            guard Self.hasOutputStream(id) else { return nil }
            return AudioOutputDevice(id: id, name: Self.deviceName(id), isSystemOutput: false,
                                     uid: Self.deviceUID(id) ?? "", sampleRate: Self.nominalSampleRate(id))
        }
        guard !physical.isEmpty else { return [] }
        let system = defaultOutputDeviceID()
        return [AudioOutputDevice(id: 0, name: Self.deviceName(system), isSystemOutput: true,
                                  sampleRate: Self.nominalSampleRate(system))] + physical
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func hasOutputStream(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self).pointee
        return list.mNumberBuffers > 0 && list.mBuffers.mNumberChannels > 0
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Double(0), size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr,
              rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr,
              let value = uid?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeUnretainedValue() else { return "Unknown Device" }
        return value as String
    }

    private static func availableSampleRates(deviceID: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.stride
        var ranges = Array(repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.flatMap { range in
            if abs(range.mMinimum - range.mMaximum) < 0.5 { return [range.mMinimum] }
            return [range.mMinimum, range.mMaximum]
        }
    }

}
