import Foundation

public enum ClockDirection: String, Codable, CaseIterable, Sendable {
    case off, send, receive
}

/// External musical time, independent of document history and note transport.
public struct ExternalClockState: Equatable, Sendable {
    public var beatsPerMinute: Double = 120
    public var isPlaying = false
    public var tickCount: UInt64 = 0
    public var isLost = false
    public var isSourceAvailable = false
    public init() {}
}

public enum Tempo {
    public static let range = 30.0...300.0
    public static func isValid(_ bpm: Double) -> Bool { bpm.isFinite && range.contains(bpm) }
}

/// Monotonic tap history; no timer or UI clock determines the tempo.
public struct TapTempo: Sendable {
    private var previous: Double?
    private var intervals: [Double] = []
    public init() {}
    public mutating func reset() { previous = nil; intervals.removeAll() }
    public mutating func tap(at time: Double) -> Double? {
        guard time.isFinite else { return nil }
        defer { previous = time }
        guard let previous, time > previous, time - previous <= 2 else {
            intervals.removeAll(); return nil
        }
        intervals.append(time - previous)
        if intervals.count > 4 { intervals.removeFirst() }
        return min(Tempo.range.upperBound, max(Tempo.range.lowerBound, 60 / (intervals.reduce(0, +) / Double(intervals.count))))
    }
}
