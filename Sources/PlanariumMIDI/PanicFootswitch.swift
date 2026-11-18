import Combine
import Foundation
import PlanariumRuntime

public struct PanicFootswitchTrigger: Codable, Equatable, Sendable {
    public let status: UInt8
    public let number: UInt8
    public init?(status: UInt8, number: UInt8, value: UInt8) {
        guard number < 128, value < 128,
              (status & 0xf0 == 0x90 && value > 0) || (status & 0xf0 == 0xb0 && value >= 64) else { return nil }
        self.status = status; self.number = number
    }
}

/// Callback-owned parser and match state. Neither matching nor PANIC visits Main.
/// Running status and messages split across CoreMIDI packets are retained.
public final class PanicFootswitchInput: @unchecked Sendable {
    private let lock = NSLock()
    private let panic: @Sendable () -> Void
    private let changed: @Sendable (PanicFootswitchTrigger?, Bool) -> Void
    private var trigger: PanicFootswitchTrigger?
    private var learning = false
    private var enabled = false
    private var epoch: UInt64 = 0
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    public init(panic: @escaping @Sendable () -> Void,
                changed: @escaping @Sendable (PanicFootswitchTrigger?, Bool) -> Void) {
        self.panic = panic; self.changed = changed
    }
    public func configure(trigger: PanicFootswitchTrigger?, learning: Bool, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.trigger = trigger; self.learning = learning; self.enabled = enabled
        status = 0; data.removeAll(keepingCapacity: true)
    }
    @discardableResult public func invalidate(expected: UInt64? = nil) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if expected == nil || epoch == expected { epoch &+= 1; enabled = false }
        return epoch
    }
    public func isCurrent(_ value: PanicFootswitchTrigger?) -> Bool {
        lock.lock(); defer { lock.unlock() }; return trigger == value && !learning
    }
    public func receive(_ bytes: [UInt8], epoch expected: UInt64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, expected == nil || expected == epoch else { return }
        for byte in bytes {
            if byte >= 0xf8 { continue }
            if byte >= 0x80 {
                status = byte < 0xf0 ? byte : 0; data.removeAll(keepingCapacity: true); continue
            }
            guard status != 0 else { continue }
            data.append(byte)
            let count = status & 0xf0 == 0xc0 || status & 0xf0 == 0xd0 ? 1 : 2
            guard data.count == count else { continue }
            defer { data.removeAll(keepingCapacity: true) }
            guard count == 2, let candidate = PanicFootswitchTrigger(status: status, number: data[0], value: data[1]) else { continue }
            if learning {
                trigger = candidate; learning = false; changed(candidate, false)
            } else if candidate == trigger {
                panic(); changed(trigger, true)
            }
        }
    }
}

@MainActor public final class PanicFootswitchModel: ObservableObject {
    @Published public private(set) var sourceID: Int32
    @Published public private(set) var trigger: PanicFootswitchTrigger?
    @Published public private(set) var learning = false
    @Published public private(set) var available = false
    public var status: String {
        guard sourceID != 0 else { return "not set" }
        return !available ? "source missing" : learning ? "waiting…" : trigger == nil ? "not set" : "ready"
    }
    private let defaults: UserDefaults
    private let factory: MIDIClockSourceFactory
    private var source: (any MIDIClockSource)?
    private var observation: RuntimeCancellation?
    private let input: PanicFootswitchInput
    private var generation: UInt64 = 0
    private var closed = false
    public init(defaults: UserDefaults = .standard, factory: @escaping MIDIClockSourceFactory,
                sourceChanges: MIDIClockSourceChanges? = nil,
                panic: @escaping @Sendable () -> Void,
                notification: @escaping @MainActor () -> Void = {}) {
        self.defaults = defaults; self.factory = factory
        sourceID = Int32(exactly: defaults.integer(forKey: "panicFootswitch.source")) ?? 0
        trigger = defaults.data(forKey: "panicFootswitch.trigger").flatMap { try? JSONDecoder().decode(PanicFootswitchTrigger.self, from: $0) }
        // Relay binds after initialization; no callback captures Main-owned state.
        let relay = FootswitchRelay()
        input = PanicFootswitchInput(panic: panic) { trigger, fired in
            Task { @MainActor in relay.action?(trigger, fired) }
        }
        relay.action = { [weak self] trigger, fired in
            guard let self, !self.closed else { return }
            if fired { notification() }
            else {
                guard self.input.isCurrent(trigger) else { return }
                self.trigger = trigger; self.learning = false
                self.defaults.set(try? JSONEncoder().encode(trigger), forKey: "panicFootswitch.trigger")
            }
        }
        observation = sourceChanges? { [weak self] in Task { @MainActor in self?.reconnect() } }
        reconnect()
    }
    public func selectSource(_ id: Int32) {
        sourceID = id; defaults.set(Int(id), forKey: "panicFootswitch.source"); reconnect()
    }
    public func learn() { guard sourceID != 0, !closed else { return }; learning = true; configureInput() }
    public func clear() {
        trigger = nil; learning = false; defaults.removeObject(forKey: "panicFootswitch.trigger"); configureInput()
    }
    private func configureInput() { input.configure(trigger: trigger, learning: learning, enabled: available) }
    private func reconnect() {
        guard !closed else { return }
        generation &+= 1
        let generation = generation
        let epoch = input.invalidate()
        source?.close(); source = nil; available = false
        guard sourceID != 0 else { return }
        let input = input
        source = factory(sourceID, { packet in input.receive(packet.bytes, epoch: epoch) }, { [weak self] in
            input.invalidate(expected: epoch)
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.source?.close(); self.source = nil; self.available = false
            }
        })
        available = source != nil; configureInput()
    }
    public func shutdown() {
        closed = true
        generation &+= 1; observation?.cancel(); observation = nil
        input.invalidate()
        source?.close(); source = nil; available = false
    }
    deinit { input.invalidate(); source?.close(); observation?.cancel() }
}

@MainActor private final class FootswitchRelay { var action: ((PanicFootswitchTrigger?, Bool) -> Void)? }
