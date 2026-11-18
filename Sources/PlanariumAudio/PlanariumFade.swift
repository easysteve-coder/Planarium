import AudioToolbox
import AVFoundation
import Foundation
import PlanariumFadeDSP

/// AU owns preallocated C storage. Its render closure captures only the
/// pointer; engine stop/detach precedes releasing the AU and that storage.
final class PlanariumFade: AUAudioUnit {
    private var ins: AUAudioUnitBusArray!
    private var outs: AUAudioUnitBusArray!
    private let state: OpaquePointer
    private let storage: FadeStorage
    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        guard let state = planarium_fade_create() else { throw PluginLoadError("Fade allocation failed") }
        self.state = state
        storage = FadeStorage(state) // also releases storage if super.init throws
        try super.init(componentDescription: componentDescription, options: options)
        guard planarium_fade_lock_free(state) != 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw PluginLoadError("Lock-free stereo fade unavailable")
        }
        ins = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
    }
    override var inputBusses: AUAudioUnitBusArray { ins }
    override var outputBusses: AUAudioUnitBusArray { outs }
    override var internalRenderBlock: AUInternalRenderBlock {
        let state = state
        return { flags, timestamp, frames, outputBus, outputData, events, pullInput in
            guard let pullInput else { return kAudioUnitErr_NoConnection }
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInput(&pullFlags, timestamp, frames, 0, outputData)
            guard status == noErr else { return status }
            planarium_fade_render(state, outputData, frames)
            return noErr
        }
    }
    func reset(sampleRate: Double, silent: Bool) { planarium_fade_reset(state, sampleRate, silent ? 1 : 0) }
    func request(silent: Bool) -> UInt32 { planarium_fade_request(state, silent ? 1 : 0) }
    func reached(_ token: UInt32) -> Bool { planarium_fade_reached(state, token) != 0 }
    func completionProbe(_ token: UInt32) -> @Sendable () -> Bool {
        { [storage] in storage.reached(token) }
    }

    /// In-process instantiation only. The callback never needs Main; the
    /// lock belongs solely to construction, never to a render callback.
    @MainActor static func makeNode() throws -> AVAudioUnit {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
            componentSubType: 0x50666465, componentManufacturer: 0x506c6e6d,
            componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.registerSubclass(PlanariumFade.self, as: desc, name: "Planarium: Fade", version: 1)
        let result = FadeConstruction()
        AVAudioUnit.instantiate(with: desc, options: []) { unit, error in result.complete(unit, error) }
        return try result.take()
    }
}
private final class FadeStorage: @unchecked Sendable {
    private let state: OpaquePointer
    init(_ state: OpaquePointer) { self.state = state }
    // The C receipt is atomic. Holding storage keeps it alive through cancellation.
    func reached(_ token: UInt32) -> Bool { planarium_fade_reached(state, token) != 0 }
    deinit { planarium_fade_destroy(state) }
}
final class FadeConstruction: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var unit: AVAudioUnit?
    private var error: Error?
    private var expired = false
    func complete(_ unit: AVAudioUnit?, _ error: Error?) {
        lock.lock()
        guard !expired else { lock.unlock(); return }
        self.unit = unit; self.error = error; lock.unlock(); ready.signal()
    }
    func take() throws -> AVAudioUnit {
        lock.lock(); let abandoned = expired; lock.unlock()
        guard !abandoned else { throw PluginLoadError.graphConstructionTimedOut }
        // This is only our own in-process fade AU, never a third-party load.
        // Bound the callback wait on Main; a late result is discarded and an
        // explicit retry uses a fresh construction/generation.
        guard ready.wait(timeout: .now() + .milliseconds(50)) == .success else {
            lock.lock(); expired = true; unit = nil; error = nil; lock.unlock()
            throw PluginLoadError.graphConstructionTimedOut
        }
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        guard let unit else { throw PluginLoadError("Fade construction failed") }
        return unit
    }
}
