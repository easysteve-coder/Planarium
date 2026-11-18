import Dispatch
import Foundation
import PlanariumMusicCore
import PlanariumSoundCore

/// A separate, timestamped clock port. Only the driver's serial queue may use
/// or dispose it; no note routing or UI lifetime crosses this boundary.
public protocol MIDIClockSink: Sendable {
    func send(_ byte: UInt8, at time: Double) -> PortSendResult
    func flush() -> PortSendResult
    func close()
}
public typealias MIDIClockSinkFactory = @Sendable (Int32) -> (any MIDIClockSink)?

/// Every segment is origin + integer tick * interval, never accumulated time.
struct MIDIClockTimeline: Sendable {
    private(set) var origin: Double
    private(set) var interval: Double
    private(set) var index: UInt64 = 1
    private var minimumIndex: Double = 1
    var next: Double { origin + Double(index) * interval }
    init(start: Double, bpm: Double) { origin = start; interval = 60 / (bpm * 24) }
    mutating func take() -> Double { let time = next; index += 1; return time }
    /// Flush/replan begins at the next old-grid tick. It keeps phase at the
    /// boundary, then uses the new interval without a duplicate/missing tick.
    mutating func changeTempo(_ bpm: Double, after time: Double) {
        var first = max(minimumIndex, floor((time - origin) / interval) + 1)
        var boundary = origin + first * interval
        if boundary <= time { first += 1; boundary = origin + first * interval }
        interval = 60 / (bpm * 24)
        origin = boundary; index = 0; minimumIndex = 0
    }
}

/// All mutable fields are confined to q. Public commands enqueue; the injected
/// clock enqueues timers there too. A slow Main/scanner cannot delay planning.
public final class MIDIClockDriver: @unchecked Sendable {
    public static let lookAhead = 0.1
    private let q = DispatchQueue(label: "de.planarium.midi-clock", qos: .userInteractive)
    private let clock: any RuntimeClock
    private let factory: MIDIClockSinkFactory
    private var enabled = false
    private var playing = false
    private var closed = false
    private var targets = Set<Int32>()
    private var sinks: [Int32: any MIDIClockSink] = [:]
    private var bpm: Double = 120
    private var timeline: MIDIClockTimeline?
    private var timer: RuntimeCancellation?
    private var lastStart: Double?
    private var report: (@Sendable (String) -> Void)?
    private let hostClock: HostMusicalClock?
    public init(clock: any RuntimeClock = MonotonicRuntimeClock(), factory: @escaping MIDIClockSinkFactory = { _ in nil }, hostClock: HostMusicalClock? = nil) {
        self.hostClock = hostClock
        self.clock = clock; self.factory = factory
    }
    public func setNoticeHandler(_ handler: @escaping @Sendable (String) -> Void) { q.async { [self] in report = handler } }
    public func configure(enabled: Bool, targets: Set<Int32>) {
        q.async { [self] in
            guard !closed else { return }
            let removed = Set(sinks.keys).subtracting(targets)
            for id in removed { retire(id) }
            self.targets = targets; self.enabled = enabled
            if !enabled { stopOutputs() }
            // Enabling/selecting/returning endpoints never joins midway.
            // These destinations participate at the next transport start.
        }
    }
    public func setTempo(_ value: Double) {
        guard Tempo.isValid(value) else { return }
        q.async { [self] in
            guard !closed, bpm != value else { return }
            bpm = value
            guard var next = timeline else { hostClock?.updateInternal(tempo: value, at: clock.now); return }
            // A pending Start must survive the endpoint-wide flush too.
            for id in Array(sinks.keys) {
                guard let sink = sinks[id] else { continue }
                guard sink.flush() == .sent else { report?("Clock destination \(id) unavailable · restart transport to retry"); retire(id); continue }
                if let lastStart, lastStart > clock.now, sink.send(0xfa, at: lastStart) != .sent { retire(id) }
            }
            next.changeTempo(value, after: max(clock.now, lastStart ?? clock.now))
            hostClock?.updateInternal(tempo: value, at: next.next, observedAt: clock.now)
            timeline = next; plan()
        }
    }
    public func start() {
        q.async { [self] in
            guard !closed, !playing else { return }
            playing = true
            guard enabled else { return }
            let start = clock.now + 0.05
            lastStart = start
            hostClock?.updateInternal(tempo: bpm, at: start, playing: true, reset: true)
            for id in targets.sorted() {
                guard let sink = factory(id) else { report?("Clock destination \(id) unavailable · restart transport to retry"); continue }
                sinks[id] = sink
                if sink.send(0xfa, at: start) != .sent { retire(id) }
            }
            timeline = MIDIClockTimeline(start: start, bpm: bpm); plan()
        }
    }
    public func stop() { q.async { [self] in playing = false; stopOutputs() } }
    public func shutdown(_ completion: @escaping @Sendable () -> Void) {
        q.async { [self] in closed = true; playing = false; stopOutputs(); completion() }
    }
    public func acknowledge(_ completion: @escaping @Sendable () -> Void) { q.async(execute: completion) }
    private func retire(_ id: Int32) {
        guard let sink = sinks.removeValue(forKey: id) else { return }
        // Flush scheduled ticks/Start first, then Stop, then close. Even an
        // unsuccessful flush/send cannot leave a live resource or retry loop.
        let flushed = sink.flush()
        let stopped = sink.send(0xfc, at: clock.now)
        if flushed != .sent || stopped != .sent { report?("MIDI Clock Stop not confirmed at destination \(id)") }
        sink.close()
    }
    private func stopOutputs() {
        hostClock?.updateInternal(tempo: bpm, at: clock.now, playing: false)
        timer?.cancel(); timer = nil; timeline = nil; lastStart = nil
        for id in Array(sinks.keys) { retire(id) }
    }
    private func plan() {
        timer?.cancel(); timer = nil
        guard playing, enabled, var next = timeline, !sinks.isEmpty else { return }
        let horizon = clock.now + Self.lookAhead
        while next.next <= horizon {
            let timestamp = next.take()
            // Missed deadlines are a planner failure, never a burst of stale
            // clocks. Stop the affected run and require a new transport start.
            guard timestamp > clock.now else { report?("MIDI Clock planning deadline missed · restart transport"); stopOutputs(); return }
            for id in Array(sinks.keys) {
                if sinks[id]?.send(0xf8, at: timestamp) != .sent {
                    report?("Clock destination \(id) unavailable · restart transport to retry"); retire(id)
                }
            }
        }
        timeline = next
        guard !sinks.isEmpty else { return }
        timer = clock.schedule(at: clock.now + 0.025, on: q) { [weak self] in self?.plan() }
    }
    deinit {
        timer?.cancel()
        let remaining = Array(sinks.values), now = clock.now
        q.async { for sink in remaining { _ = sink.flush(); _ = sink.send(0xfc, at: now); sink.close() } }
    }
}
