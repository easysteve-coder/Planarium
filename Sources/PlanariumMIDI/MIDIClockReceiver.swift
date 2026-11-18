import Dispatch
import Foundation
import PlanariumMusicCore
import PlanariumSoundCore

public struct MIDIClockPacket: Sendable {
    public let bytes: [UInt8]
    public let timestamp: Double
    public let arrival: Double
    public init(bytes: [UInt8], timestamp: Double, arrival: Double) {
        self.bytes = bytes; self.timestamp = timestamp; self.arrival = arrival
    }
}
public protocol MIDIClockSource: Sendable { func close() }
public typealias MIDIClockSourceChanges = @Sendable (@escaping @Sendable () -> Void) -> RuntimeCancellation
public typealias MIDIClockSourceFactory = @Sendable (Int32, @escaping @Sendable (MIDIClockPacket) -> Void,
                                                    @escaping @Sendable () -> Void) -> (any MIDIClockSource)?

/// Only visible values cross the presentation boundary; musical position stays on Q.
public struct MIDIClockDisplaySnapshot: Equatable, Sendable {
    public let beatsPerMinute: Double
    public var isPlaying: Bool
    public var isLost: Bool
    public var isSourceAvailable: Bool
    public init(_ state: ExternalClockState = .init()) {
        beatsPerMinute = (state.beatsPerMinute * 10).rounded() / 10
        isPlaying = state.isPlaying; isLost = state.isLost
        isSourceAvailable = state.isSourceAvailable
    }
}

/// Pure estimator. Pairwise median slopes over 25 timestamps (24 intervals)
/// reject a single bad timestamp without adding a second smoothing window.
struct MIDIClockEstimator {
    var state = ExternalClockState()
    private var times: [Double] = []
    private var requestedPlaying = false
    private var lastTickArrival: Double?
    private(set) var positionTime: Double = 0
    private(set) var startCount: UInt64 = 0
    mutating func accept(_ packet: MIDIClockPacket) {
        let time = packet.timestamp == 0 ? packet.arrival : packet.timestamp
        guard time.isFinite, packet.arrival.isFinite else { return }
        for byte in packet.bytes {
            switch byte {
            case 0xfa:
                startCount &+= 1
                requestedPlaying = true; state.isPlaying = true; state.tickCount = 0
                positionTime = time
            case 0xfb: requestedPlaying = true; state.isPlaying = true; positionTime = time
            case 0xfc: requestedPlaying = false; state.isPlaying = false; positionTime = time
            case 0xf8:
                lastTickArrival = packet.arrival
                state.isLost = false; state.isPlaying = requestedPlaying
                if requestedPlaying { state.tickCount &+= 1; positionTime = time }
                times.append(time)
                if times.count > 25 { times.removeFirst() }
                if times.count == 25 {
                    var slopes: [Double] = []
                    for i in 0..<(times.count - 1) {
                        for j in (i + 1)..<times.count {
                            let slope = (times[j] - times[i]) / Double(j - i)
                            if slope > 0 { slopes.append(slope) }
                        }
                    }
                    slopes.sort()
                    if !slopes.isEmpty {
                        let middle = slopes.count / 2
                        var interval = slopes.count.isMultiple(of: 2) ? (slopes[middle - 1] + slopes[middle]) / 2 : slopes[middle]
                        // A ±2 ms timestamp envelope constrains the period more
                        // tightly than a line fit alone. First reject isolated
                        // residuals using the robust fit; ramps use that fit
                        // whenever no constant period satisfies the envelope.
                        let intercepts = times.enumerated().map { $0.element - Double($0.offset) * interval }.sorted()
                        let intercept = intercepts[intercepts.count / 2]
                        let inliers = times.indices.filter { abs(times[$0] - (intercept + Double($0) * interval)) <= 0.006 }
                        var lower = 0.0, upper = Double.infinity
                        for (position, i) in inliers.enumerated() {
                            for j in inliers.dropFirst(position + 1) {
                                let distance = Double(j - i), delta = times[j] - times[i]
                                lower = max(lower, (delta - 0.004) / distance)
                                upper = min(upper, (delta + 0.004) / distance)
                            }
                        }
                        if inliers.count >= 20, lower > 0, lower <= upper { interval = (lower + upper) / 2 }
                        let bpm = 60 / (24 * interval)
                        if bpm.isFinite, bpm > 0 { state.beatsPerMinute = bpm }
                    }
                }
            default: break // no note routing, thru, song position or other input
            }
        }
    }
    mutating func checkLoss(at now: Double, since selectedAt: Double) {
        if now - (lastTickArrival ?? selectedAt) > max(0.5, 120 / state.beatsPerMinute) { lose() }
    }
    mutating func lose() {
        state.isLost = true; state.isPlaying = false; times.removeAll()
    }
}

/// Input handles, estimation, endpoint observation and the loss timer belong to q.
/// Main receives at most one pending notification, only for visible changes.
public final class MIDIClockReceiver: @unchecked Sendable {
    private let q = DispatchQueue(label: "de.planarium.midi-clock-input", qos: .userInteractive)
    private let clock: any RuntimeClock
    private let factory: MIDIClockSourceFactory
    private let sourceChanges: MIDIClockSourceChanges?
    private var sourceObservation: RuntimeCancellation?
    private var source: (any MIDIClockSource)?
    private var sourceID: Int32?
    private var generation: UInt64 = 0
    private var estimator = MIDIClockEstimator()
    private var selectedAt: Double = 0
    private var timer: RuntimeCancellation?
    private var suspended = false
    private var closed = false
    private var update: (@Sendable (MIDIClockDisplaySnapshot) -> Void)?
    private let displayDelivery = DisplayDelivery()
    private var lastDisplay: MIDIClockDisplaySnapshot?
    private let hostClock: HostMusicalClock?
    private var lastPublishedStartCount: UInt64 = 0
    public init(clock: any RuntimeClock = MonotonicRuntimeClock(), factory: @escaping MIDIClockSourceFactory = { _, _, _ in nil }, hostClock: HostMusicalClock? = nil, sourceChanges: MIDIClockSourceChanges? = nil) {
        self.sourceChanges = sourceChanges
        self.hostClock = hostClock
        self.clock = clock; self.factory = factory
    }
    public var snapshot: ExternalClockState {
        q.sync { var state = estimator.state; state.isSourceAvailable = source != nil; return state }
    }
    public func setUpdateHandler(_ handler: @escaping @Sendable (MIDIClockDisplaySnapshot) -> Void) { q.async { [self] in update = handler } }
    public func configure(sourceID: Int32?) {
        q.async { [self] in
            guard !closed, self.sourceID != sourceID else { return }
            retire(); self.sourceID = sourceID; estimator = MIDIClockEstimator(); selectedAt = clock.now; lastDisplay = nil
            if !suspended { watchSources(); open(); schedule() }
            notify()
        }
    }
    /// Control-side acknowledgement: a new output transport may start only
    /// after this returns. Never called by an input callback or from q.
    public func disconnect() {
        q.sync { retire(); sourceID = nil; estimator = MIDIClockEstimator(); lastDisplay = nil; notify() }
    }
    public func suspend() { q.async { [self] in suspended = true; retire(); estimator.lose(); notify() } }
    public func resume() {
        q.async { [self] in
            guard !closed else { return }
            suspended = false; selectedAt = clock.now
            // Main deliberately ignored suspend snapshots. Re-deliver current
            // availability/loss even when the silent source needs no timer.
            lastDisplay = nil
            watchSources(); open(); schedule(); notify()
        }
    }
    public func shutdown(_ completion: @escaping @Sendable () -> Void) {
        q.async { [self] in closed = true; retire(); sourceID = nil; estimator = MIDIClockEstimator(); publishHostClock(); update = nil; displayDelivery.cancel(); completion() }
    }
    public func acknowledge(_ completion: @escaping @Sendable () -> Void) { q.async(execute: completion) }
    private func retire() {
        generation &+= 1; timer?.cancel(); timer = nil; source?.close(); source = nil
        sourceObservation?.cancel(); sourceObservation = nil
    }
    /// Endpoint notifications replace permanent reconnect polling. A late
    /// global notification merely rechecks the current selection on Q.
    public func sourcesChanged() {
        q.async { [self] in
            guard !closed, !suspended, sourceID != nil, source == nil else { return }
            // Reappearing endpoints retain the original selection deadline;
            // only configure/resume begin a fresh selection grace period.
            open(); schedule(); notify()
        }
    }
    private func watchSources() {
        guard sourceObservation == nil, sourceID != nil, !closed, !suspended else { return }
        sourceObservation = sourceChanges? { [weak self] in self?.sourcesChanged() }
    }
    private func open() {
        guard source == nil, let sourceID, !closed, !suspended else { return }
        generation &+= 1
        let current = generation
        source = factory(sourceID, { [weak self] packet in
            guard let self else { return }
            self.q.async { [self] in
                guard self.generation == current, !self.closed, !self.suspended else { return }
                self.estimator.accept(packet)
                self.publishHostClock()
                if self.timer == nil { self.schedule() }
            }
        }, { [weak self] in
            guard let self else { return }
            self.q.async { [self] in
                guard self.generation == current, !self.closed, !self.suspended else { return }
                self.retire(); self.estimator.lose(); self.watchSources()
                // The add notification may have arrived before this queued
                // removal. Try once now; future attempts need endpoint events.
                self.open(); self.notify()
            }
        })
        if source == nil { estimator.lose() }
    }
    private func schedule() {
        timer?.cancel(); timer = nil
        // FA/FB can restart the musical host while the estimator is already
        // lost. Even without F8, keep checking until its loss deadline.
        guard sourceID != nil, source != nil,
              (!estimator.state.isLost || estimator.state.isPlaying), !suspended, !closed else { return }
        let current = generation
        timer = clock.schedule(at: clock.now + 0.1, on: q) { [weak self] in
            guard let self, self.generation == current, !self.closed, !self.suspended else { return }
            self.estimator.checkLoss(at: self.clock.now, since: self.selectedAt)
            self.notify()
            // One end condition in schedule() also covers lost + playing
            // during a freshly restarted wake grace period.
            self.schedule()
        }
    }
    private var displaySnapshot: MIDIClockDisplaySnapshot {
        var state = estimator.state; state.isSourceAvailable = source != nil
        return MIDIClockDisplaySnapshot(state)
    }
    private func notify() {
        publishHostClock()
        let display = displaySnapshot
        guard display != lastDisplay, let update, !closed else { return }
        lastDisplay = display
        displayDelivery.submit(display) { [weak self] snapshot in
            guard let self else { return }
            withExtendedLifetime(self) { update(snapshot) }
        }
    }

    /// One latest-value slot; Main takes a prepared value without waiting on Q.
    /// No callback runs while holding the lock. Shutdown/deinit drop pending delivery.
    private final class DisplayDelivery: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false
        private var value: (MIDIClockDisplaySnapshot, @Sendable (MIDIClockDisplaySnapshot) -> Void)?
        func submit(_ snapshot: MIDIClockDisplaySnapshot, update: @escaping @Sendable (MIDIClockDisplaySnapshot) -> Void) {
            lock.lock()
            value = (snapshot, update)
            guard !pending else { lock.unlock(); return }
            pending = true; lock.unlock()
            DispatchQueue.main.async { [self] in
                lock.lock(); let delivery = value; value = nil; pending = false; lock.unlock()
                if let delivery { delivery.1(delivery.0) }
            }
        }
        func cancel() { lock.lock(); value = nil; lock.unlock() }
    }

    deinit { displayDelivery.cancel(); timer?.cancel(); source?.close(); sourceObservation?.cancel() }
    private func publishHostClock() {
        let state = estimator.state
        let resetPosition = lastPublishedStartCount != estimator.startCount
        lastPublishedStartCount = estimator.startCount
        hostClock?.updateExternal(tempo: state.beatsPerMinute, beat: Double(state.tickCount) / 24,
                                 at: estimator.positionTime == 0 ? clock.now : estimator.positionTime, playing: state.isPlaying,
                                 resetPosition: resetPosition)
    }
}
