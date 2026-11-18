// AU-Instanziierung verwendet den Systemstandard. Die Optionsflags sind
// nur Anfragen; insbesondere AUv3 bietet keine zugesicherte Fehlerisolation.
// Es gibt keine Behauptung über den tatsächlichen Prozessmodus einer AU.
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit
import PlanariumDomain
import PlanariumRuntime
import PlanariumHostClockDSP

@MainActor public struct SystemPluginSource: PluginComponentSource {
    /// [] ist der Systemstandard; Optionen sind nur Anfragen.
    public static let instantiationOptions: AudioComponentInstantiationOptions = []
    public init() {}
    public func load(_ identity: SpatialAudioUnitIdentity,
                     completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        guard AudioUnitEffectCatalog.isUserComponent(manufacturer: identity.componentManufacturer) else {
            completion(.failure(.init("Unavailable insert"))); return
        }
        let description = AudioComponentDescription(componentType: identity.componentType,
            componentSubType: identity.componentSubType, componentManufacturer: identity.componentManufacturer,
            componentFlags: 0, componentFlagsMask: 0)
        guard !AVAudioUnitComponentManager.shared().components(matching: description).isEmpty else {
            completion(.failure(.init("Audio Unit component unavailable"))); return
        }
        // System default, as in SystemAudioUnitInstantiation. No promise of
        // process isolation. No constructor blocks Main waiting for an AU.
        AVAudioUnit.instantiate(with: description, options: Self.instantiationOptions) { unit, error in
            let delivery = UnitDelivery(unit: unit, error: error?.localizedDescription)
            Task { @MainActor in
                if let unit = delivery.unit { completion(.success(SystemPluginUnit(unit: unit))) }
                else { completion(.failure(.init(delivery.error ?? "Audio Unit instantiation failed"))) }
            }
        }
    }
}

/// Single transfer from Apple's callback thread to Main. No use off Main.
private struct UnitDelivery: @unchecked Sendable { let unit: AVAudioUnit?; let error: String? }
private struct EditorDelivery: @unchecked Sendable { let controller: NSViewController? }

@MainActor final class SystemPluginUnit: PluginUnit {
    let node: AVAudioUnit
    private var noteState: SystemNoteScheduleState?
    private var bypassObservation: NSKeyValueObservation?
    var audioNode: AVAudioUnit? { node }
    init(unit: AVAudioUnit) { node = unit }
    var parameterDescriptors: [AudioUnitParameterDescriptor] {
        let identity = node.audioComponentDescription
        return (node.auAudioUnit.parameterTree?.allParameters ?? []).filter {
            $0.flags.contains(.flag_IsWritable)
        }.map {
            .init(componentType: identity.componentType, componentSubType: identity.componentSubType,
                  componentManufacturer: identity.componentManufacturer, address: $0.address,
                  identifier: $0.identifier, displayName: $0.displayName,
                  minimumValue: $0.minValue, maximumValue: $0.maxValue, unitName: $0.unitName)
        }
    }
    private struct MusicalFingerprint: Encodable {
        struct Parameter: Encodable { let address: UInt64; let identifier: String; let value: Float }
        let parameters: [Parameter]
        let presetNumber: Int?
        let presetName: String?
    }
    /// Explicit save/load/termination probes only. Writable control values and
    /// preset identity exclude transient editor geometry and read-only meters.
    /// Units without readable controls retain exact opaque-state comparison.
    var musicalStateFingerprint: Data? {
        let parameters = (node.auAudioUnit.parameterTree?.allParameters ?? []).filter {
            $0.flags.contains(.flag_IsReadable) && $0.flags.contains(.flag_IsWritable)
        }.sorted { $0.address < $1.address }.map {
            MusicalFingerprint.Parameter(address: $0.address, identifier: $0.identifier, value: $0.value)
        }
        guard !parameters.isEmpty, parameters.allSatisfy({ $0.value.isFinite }) else { return nil }
        let preset = node.auAudioUnit.currentPreset
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(MusicalFingerprint(parameters: parameters, presetNumber: preset?.number, presetName: preset?.name))
    }
    func observeBypass(_ changed: (@Sendable (Bool) -> Void)?) {
        bypassObservation?.invalidate(); bypassObservation = nil
        guard let changed else { return }
        // The AUAudioUnit API is documented as bridged to the v2 bypass property.
        // Snapshot only the scalar on the posting thread; PluginInstance owns
        // coalescing, Main delivery and cancellation of queued callbacks.
        bypassObservation = node.auAudioUnit.observe(\.shouldBypassEffect, options: [.initial, .new]) { _, change in
            if let value = change.newValue { changed(value) }
        }
    }
    func readState() throws -> Data {
        guard let state = node.auAudioUnit.fullState else { return Data() }
        return try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }
    func setState(_ state: Data) throws {
        guard let values = try PropertyListSerialization.propertyList(from: state, options: [], format: nil) as? [String: Any] else {
            throw PluginLoadError("Invalid Audio Unit state")
        }
        node.auAudioUnit.fullState = values
    }
    func setBypass(_ bypassed: Bool) { node.auAudioUnit.shouldBypassEffect = bypassed }
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary {
        let state: SystemNoteScheduleState
        if let noteState { state = noteState }
        else {
            state = SystemNoteScheduleState(binding: PlanariumNoteRenderBinding(unit: node.auAudioUnit, owner: node))
            noteState = state
        }
        state.binding?.configureSampleRate(node.auAudioUnit.outputBusses.count > 0 ? node.auAudioUnit.outputBusses[0].format.sampleRate : 0)
        // fullState can replace parameter ranges and native schedule blocks.
        // Recapture those exactly as before; only the note observer/barrier
        // survives an instance's retire/rebind cycle.
        return SystemAUSchedule(unit: node.auAudioUnit, identity: identity, state: state)
    }
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void) {
        // No second render-resource allocation: the graph owns preparation.
        node.auAudioUnit.requestViewController { [self] controller in
            let delivery = EditorDelivery(controller: controller)
            Task { @MainActor in
                let controller = delivery.controller ?? Self.legacyOrGenericController(node)
                completion(AppKitPluginEditor(controller: controller))
            }
        }
    }
    // Ported from the existing SystemAudioUnitInstantiation fallback. AUv2
    // manufacturer editors are not obtainable through requestViewController.
    private static func legacyOrGenericController(_ node: AVAudioUnit) -> NSViewController {
        let controller = NSViewController()
        controller.view = legacyView(node.audioUnit) ?? AUGenericView(audioUnit: node.audioUnit)
        let size = controller.view.frame.size
        if size.width > 1 && size.height > 1 { controller.preferredContentSize = size }
        return controller
    }
    private static func legacyView(_ unit: AudioUnit) -> NSView? {
        var bytes: UInt32 = 0
        var writable = DarwinBoolean(false)
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0,
                                       &bytes, &writable) == noErr,
              bytes >= MemoryLayout<AudioUnitCocoaViewInfo>.size else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { storage.deallocate() }
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, storage, &bytes) == noErr else { return nil }
        let info = storage.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee
        let url = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let name = info.mCocoaAUViewClass.takeRetainedValue() as String
        guard let bundle = Bundle(url: url), bundle.load(),
              let factoryType = NSClassFromString(name) as? NSObject.Type,
              let factory = factoryType.init() as? PluginCocoaViewFactory else { return nil }
        return factory.uiView(forAudioUnit: unit, with: .zero)
    }
}

@objc private protocol PluginCocoaViewFactory {
    @objc(uiViewForAudioUnit:withSize:)
    func uiView(forAudioUnit unit: AudioUnit, with size: NSSize) -> NSView?
}

fileprivate final class SystemNoteScheduleState: @unchecked Sendable {
    let binding: PlanariumNoteRenderBinding?
    let testRing: OpaquePointer?
    // One instance's Q-owned state survives schedule-block recapture. No
    // dictionary is read or written by the native render observer.
    var offsets: [UInt16: Int64] = [:]
    var sampleReceipts: [UInt16: Double] = [:]
    var sampleVoices: [UInt16: UInt64] = [:]
    var sampleSerial: UInt64 = 0
    var sampleEpoch: NoteRenderAnchor?
    enum Barrier { case samples(start: Double, end: Double, offset: Int64), awaitingRender(Int64) }
    var barriers: [UInt16: Barrier] = [:]
    init(binding: PlanariumNoteRenderBinding?, testRing: OpaquePointer? = nil) { self.binding = binding; self.testRing = testRing }
}

/// Main captures fresh native blocks/ranges for each port binding. Q alone
/// updates the instance's shared note receipts/barriers; the native observer
/// consumes the C sample ring and never touches these Swift dictionaries.
final class SystemAUSchedule: AUScheduleBoundary, PlannedNoteBoundary, SampleNoteBoundary, @unchecked Sendable {
    private let unit: AUAudioUnit? // lifetime only, never read on Q
    private let identity: SpatialAudioUnitIdentity
    private let noteState: SystemNoteScheduleState
    private var renderBinding: PlanariumNoteRenderBinding? { noteState.binding }
    private var sampleRing: OpaquePointer? { renderBinding?.sampleNotes() ?? noteState.testRing }
    private let testAnchor: (@Sendable () -> NoteRenderAnchor)?
    private let planningNow: @Sendable () -> Double
    private typealias Barrier = SystemNoteScheduleState.Barrier
    private let midi: AUScheduleMIDIEventBlock?
    private let parameter: AUScheduleParameterBlock?
    private struct Range { let identifier: String; let minimum: Float; let maximum: Float }
    private let ranges: [UInt64: Range]
    @MainActor fileprivate init(unit: AUAudioUnit, identity: SpatialAudioUnitIdentity, state: SystemNoteScheduleState) {
        self.unit = unit; self.identity = identity
        testAnchor = nil
        planningNow = { ProcessInfo.processInfo.systemUptime }
        noteState = state
        midi = unit.scheduleMIDIEventBlock; parameter = unit.scheduleParameterBlock
        ranges = Dictionary(uniqueKeysWithValues: (unit.parameterTree?.allParameters ?? []).filter {
            $0.flags.contains(.flag_IsWritable) && $0.minValue.isFinite && $0.maxValue.isFinite && $0.maxValue > $0.minValue
        }.map { ($0.address, Range(identifier: $0.identifier, minimum: $0.minValue, maximum: $0.maxValue)) })
    }
    // Offline native-block seam: the production constructor above always
    // obtains its mailbox from the installed instrument render observer.
    init(identity: SpatialAudioUnitIdentity, midi: @escaping AUScheduleMIDIEventBlock,
         anchor: @escaping @Sendable () -> NoteRenderAnchor, now: @escaping @Sendable () -> Double, sampleRing: OpaquePointer? = nil) {
        unit = nil; self.identity = identity; self.midi = midi
        parameter = nil; ranges = [:]; noteState = SystemNoteScheduleState(binding: nil, testRing: sampleRing)
        testAnchor = anchor; planningNow = now
    }
    private func anchor() -> NoteRenderAnchor {
        if let testAnchor { return testAnchor() }
        guard let value = renderBinding?.readAnchor(), value.valid != 0 else {
            return .init(seconds: 0, sample: 0, rate: 0, frames: 0)
        }
        return .init(seconds: value.seconds, sample: value.sample, rate: value.rate, frames: value.frames)
    }
    private func observation() -> NoteRenderAnchor {
        if let testAnchor { return testAnchor() }
        guard let value = renderBinding?.readAnchor() else { return .init(seconds: 0, sample: .nan, rate: 0, frames: 0) }
        return .init(seconds: value.seconds, sample: value.sample, rate: value.rate, frames: value.frames)
    }
    private func releaseBarrier(_ observation: NoteRenderAnchor, offset: Int64) -> Barrier {
        guard observation.sample.isFinite, observation.frames > 0 else { return .awaitingRender(offset) }
        return .samples(start: observation.sample,
            end: observation.sample + Double(observation.frames) + Double(offset) + 1, offset: offset)
    }
    var planningLead: Double { anchor().lead(at: planningNow()) }
    func permitsNoteOn(bytes: [UInt8], now: Double) -> Bool {
        guard bytes.count == 3 else { return false }
        let key = UInt16(bytes[0] & 15) * 128 + UInt16(bytes[1])
        guard let barrier = noteState.barriers[key] else { return true }
        let observed = observation()
        switch barrier {
        case .samples(let start, let end, let offset):
            guard observed.sample.isFinite, observed.frames > 0 else { return false }
            // Engine/sample epochs can reset over Stop/reconfiguration. A
            // wall-clock timeout cannot acknowledge consumption of an AU Off.
            if observed.sample < start { noteState.barriers[key] = releaseBarrier(observed, offset: offset) }
            else if observed.sample >= end { noteState.barriers.removeValue(forKey: key); return true }
        case .awaitingRender(let offset):
            noteState.barriers[key] = releaseBarrier(observed, offset: offset)
        }
        return false
    }
    func sendPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult {
        guard let midi, bytes.count == 3,
              let offset = anchor().offset(deadline: deadline, now: now) else { return .unbound }
        if bytes[0] & 0xf0 == 0x90 && !permitsNoteOn(bytes: bytes, now: now) { return .faulted }
        let key = UInt16(bytes[0] & 15) * 128 + UInt16(bytes[1])
        bytes.withUnsafeBufferPointer { midi(AUEventSampleTimeImmediate + offset, 0, $0.count, $0.baseAddress!) }
        if bytes[0] & 0xf0 == 0x90 { noteState.offsets[key] = offset }
        return .sent
    }
    func cancelPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult {
        guard let midi, bytes.count == 3 else { return .unbound }
        let key = UInt16(bytes[0] & 15) * 128 + UInt16(bytes[1])
        let offset = noteState.offsets.removeValue(forKey: key) ?? 0
        noteState.barriers[key] = releaseBarrier(observation(), offset: offset)
        bytes.withUnsafeBufferPointer {
            midi(AUEventSampleTimeImmediate, 0, $0.count, $0.baseAddress!)
            midi(AUEventSampleTimeImmediate + offset + 1, 0, $0.count, $0.baseAddress!)
        }
        return .sent
    }
    var sampleNotesAvailable: Bool { midi != nil && sampleRing != nil }
    func enqueueSampleNote(bytes: [UInt8], deadline: Double, immediate: Bool) -> PortSendResult {
        guard midi != nil, let ring = sampleRing, bytes.count == 3, deadline.isFinite else { return .unbound }
        if bytes[0] & 0xf0 == 0x90 && !permitsNoteOn(bytes: bytes, now: planningNow()) { return .unbound }
        let observed = anchor()
        let valid = observed.rate > 0 && observed.sample.isFinite && observed.frames > 0
        guard immediate || valid else { return .unbound }
        if let epoch = noteState.sampleEpoch, valid, observed.rate != epoch.rate || observed.sample < epoch.sample {
            invalidateSampleNotes(); return .faulted
        }
        if noteState.sampleEpoch == nil && valid { noteState.sampleEpoch = observed }
        // Freeze the host-to-sample epoch for this generation. Choosing a
        // different render mailbox because Q ran later must not round a
        // half-sample deadline differently (notably 1/16 at 44.1 kHz).
        let a = noteState.sampleEpoch ?? observed
        let sample = immediate ? -Double.greatestFiniteMagnitude : (a.sample + (deadline - a.seconds) * a.rate).rounded()
        let key = UInt16(bytes[0] & 15) * 128 + UInt16(bytes[1])
        let isOn = bytes[0] & 0xf0 == 0x90 && bytes[2] > 0
        let nextSerial = noteState.sampleSerial == .max ? 1 : noteState.sampleSerial + 1
        let voice = isOn ? nextSerial : (noteState.sampleVoices[key] ?? 0)
        let n = PlanariumSampleNote(sample: sample, generation: planarium_note_ring_generation(ring),
                                   status: bytes[0], note: bytes[1], velocity: bytes[2], voice: voice)
        guard planarium_note_ring_push(ring, n) != 0 else { invalidateSampleNotes(); return .faulted }
        if isOn {
            noteState.sampleSerial = nextSerial; noteState.sampleVoices[key] = voice
            noteState.sampleReceipts[key] = max(noteState.sampleReceipts[key] ?? deadline, deadline)
        }
        return .sent
    }
    func invalidateSampleNotes() {
        if let ring = sampleRing { _ = planarium_note_ring_invalidate(ring) }
        // A stopped engine cannot consume the ring/off-book. Keep B1's
        // immediate + beyond-latest-On release as an independent Q path.
        let a = observation()
        for (key, _) in noteState.sampleReceipts {
            let bytes: [UInt8] = [0x80 | UInt8(key / 128), UInt8(key % 128), 0]
            let offset = Int64(a.frames)
            noteState.barriers[key] = releaseBarrier(a, offset: offset)
            bytes.withUnsafeBufferPointer {
                midi?(AUEventSampleTimeImmediate, 0, 3, $0.baseAddress!)
                midi?(AUEventSampleTimeImmediate + offset + 1, 0, 3, $0.baseAddress!)
            }
        }
        noteState.sampleReceipts.removeAll(keepingCapacity: true)
        noteState.sampleEpoch = nil
        noteState.sampleVoices.removeAll(keepingCapacity: true)
    }
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult {
        guard let midi, !bytes.isEmpty else { return .unbound }
        bytes.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { midi(AUEventSampleTimeImmediate, 0, bytes.count, base) }
        }
        return .sent
    }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult {
        guard target.component == identity, normalizedValue.isFinite,
              let parameter, let range = ranges[target.address], range.identifier == target.identifier else { return .unbound }
        let value = range.minimum + Float(min(max(normalizedValue, 0), 1)) * (range.maximum - range.minimum)
        parameter(AUEventSampleTimeImmediate, 0, target.address, value)
        return .sent
    }
}
