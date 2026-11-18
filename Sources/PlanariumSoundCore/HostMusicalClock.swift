import Foundation
import PlanariumMusicCore
import PlanariumHostClockDSP

/// Single control-side musical timeline. The control lock serializes Send,
/// Receive and direction changes; AU render never calls any Swift method.
public final class HostMusicalClock: @unchecked Sendable {
    @_spi(AudioHost) public let storage: OpaquePointer
    private let lock = NSLock()
    private var tempoWakes: [UUID: DispatchSourceUserDataAdd] = [:]
    private var direction: ClockDirection = .off
    private var value = PlanariumHostClockSnapshot(tempo: 120, beat: 0, seconds: 0, previousTempo: 120, generation: 0, transport: 0, moving: 0)
    public init() {
        guard let storage = planarium_host_clock_create() else {
            preconditionFailure("Host musical clock allocation failed")
        }
        guard planarium_host_clock_lock_free(storage) != 0 else {
            planarium_host_clock_destroy(storage)
            preconditionFailure("Lock-free host musical clock unavailable")
        }
        self.storage = storage
    }
    deinit { planarium_host_clock_destroy(storage) }
    // Registration and removal are control-side. The source is allocated once;
    // tempo publication only adds data, with no per-tick callback allocation.
    package func addTempoWake(_ source: DispatchSourceUserDataAdd) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); tempoWakes[id] = source; return id
    }
    package func removeTempoWake(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; tempoWakes.removeValue(forKey: id)
    }
    private func wakeTempoReaders() { for source in tempoWakes.values { source.add(data: 1) } }
    public var snapshot: PlanariumHostClockSnapshot { lock.lock(); defer { lock.unlock() }; return value }
    private func position(at time: Double) -> Double {
        max(0, value.beat + (value.moving != 0 ? (time - value.seconds) * (time < value.seconds ? value.previousTempo : value.tempo) / 60 : 0))
    }
    public func configure(_ direction: ClockDirection, documentTempo: Double, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        guard self.direction != direction else { return }
        value.beat = position(at: time); value.seconds = time
        if value.moving != 0 { value.transport &+= 1 }
        value.moving = 0; value.generation &+= 1; self.direction = direction
        value.tempo = direction == .receive ? 120 : documentTempo
        value.previousTempo = value.tempo
        planarium_host_clock_publish(storage, value)
        wakeTempoReaders()
    }
    public func updateInternal(tempo: Double, at time: Double, playing: Bool? = nil, reset: Bool = false, observedAt: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard direction != .receive else { return }
        let tempoChanged = value.tempo != tempo
        let previousTempo = (observedAt ?? time) < value.seconds ? value.previousTempo : value.tempo
        value.beat = reset ? 0 : position(at: time); value.seconds = time
        value.previousTempo = previousTempo; value.tempo = tempo
        let moving = direction == .send && (playing ?? (value.moving != 0))
        if moving != (value.moving != 0) { value.transport &+= 1 }
        value.moving = moving ? 1 : 0; value.generation &+= 1
        planarium_host_clock_publish(storage, value)
        if tempoChanged { wakeTempoReaders() }
    }
    public func updateExternal(tempo: Double, beat: Double, at time: Double, playing: Bool, resetPosition: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard direction == .receive else { return }
        let tempoChanged = value.tempo != tempo
        value.tempo = tempo; value.previousTempo = tempo; value.beat = beat; value.seconds = time
        if playing != (value.moving != 0) || resetPosition { value.transport &+= 1 }
        value.moving = playing ? 1 : 0; value.generation &+= 1
        planarium_host_clock_publish(storage, value)
        if tempoChanged { wakeTempoReaders() }
    }
}
