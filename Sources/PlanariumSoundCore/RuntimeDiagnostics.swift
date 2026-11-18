import Foundation

public struct RuntimeTimingSample: Equatable, Sendable {
    public let ordinal: UInt64
    public let requestedAt: Double
    public let completedAt: Double
    public let queueMilliseconds: Double
    public let totalMilliseconds: Double
    package init(requestedAt: Double, completedAt: Double, queueMilliseconds: Double,
         totalMilliseconds: Double, ordinal: UInt64 = 0) {
        self.ordinal = ordinal; self.requestedAt = requestedAt; self.completedAt = completedAt
        self.queueMilliseconds = queueMilliseconds; self.totalMilliseconds = totalMilliseconds
    }
}
public struct RuntimeDiagnostics: Equatable, Sendable {
    public let processedProfiles: UInt64
    public let discardedProfiles: UInt64
    public let overflowProfiles: UInt64
    public let profileTimings: [RuntimeTimingSample]
    public let panicTimings: [RuntimeTimingSample]
    public let profileTimingCount: UInt64
    public let panicTimingCount: UInt64
    /// Game-controller device reports: callback time → router return on Q.
    /// The callback time is when Planarium received the report, not when the
    /// pad sent it; Bluetooth and driver latency before it are not included.
    public let controllerTimings: [RuntimeTimingSample]
    public let controllerTimingCount: UInt64
    /// Every processed device report since start, never evicted: a measurement
    /// window subtracts two snapshots and covers its whole duration.
    public let controllerAggregate: ControllerReportAggregate
}

/// Monotonic counters and fixed-bin histograms of controller reports. Two
/// snapshots give exact counts and quantiles to one bin for any window length,
/// unlike the bounded sample ring. Latencies: 0.1 ms bins up to 50 ms;
/// report intervals: 1 ms bins up to 5 s. The last bin of each holds the rest.
public struct ControllerReportAggregate: Equatable, Sendable {
    public static let latencyBinMilliseconds = 0.1, intervalBinMilliseconds = 1.0
    public static let latencyBins = 501, intervalBins = 5_001
    public internal(set) var processed: UInt64 = 0
    /// Reports refused before Q (controller backlog overload).
    public internal(set) var refused: UInt64 = 0
    public internal(set) var latency = [UInt64](repeating: 0, count: latencyBins)
    public internal(set) var queueWait = [UInt64](repeating: 0, count: latencyBins)
    public internal(set) var interval = [UInt64](repeating: 0, count: intervalBins)
    public init() {}

    static func bin(_ milliseconds: Double, width: Double, count: Int) -> Int {
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        return min(count - 1, Int(milliseconds / width))
    }
    mutating func record(latency total: Double, queue: Double, interval gap: Double?) {
        processed &+= 1
        latency[Self.bin(total, width: Self.latencyBinMilliseconds, count: Self.latencyBins)] &+= 1
        queueWait[Self.bin(queue, width: Self.latencyBinMilliseconds, count: Self.latencyBins)] &+= 1
        if let gap { interval[Self.bin(gap, width: Self.intervalBinMilliseconds, count: Self.intervalBins)] &+= 1 }
    }
    public struct Quantiles: Equatable, Sendable {
        /// Upper bin edges in ms; `openEnded` when the value lies in the last bin.
        public let p50, p95, p99, max: Double
        public let count: UInt64
        public let openEnded: Bool
    }
    /// Quantiles of a histogram to one bin; nil without samples.
    public static func quantiles(_ bins: [UInt64], width: Double) -> Quantiles? {
        let total = bins.reduce(0, +)
        guard total > 0 else { return nil }
        func index(_ q: Double) -> Int {
            let target = Swift.max(1, UInt64((Double(total) * q).rounded(.up)))
            var seen: UInt64 = 0
            for (i, n) in bins.enumerated() { seen += n; if seen >= target { return i } }
            return bins.count - 1
        }
        let highest = bins.lastIndex { $0 > 0 } ?? 0
        func edge(_ i: Int) -> Double { Double(i + (i == bins.count - 1 ? 0 : 1)) * width }
        return .init(p50: edge(index(0.5)), p95: edge(index(0.95)), p99: edge(index(0.99)), max: edge(highest),
                     count: total, openEnded: highest == bins.count - 1)
    }
    /// Counts of this snapshot minus an earlier one (same process).
    public func since(_ earlier: ControllerReportAggregate) -> ControllerReportAggregate {
        var result = ControllerReportAggregate()
        result.processed = processed &- earlier.processed
        result.refused = refused &- earlier.refused
        result.latency = zip(latency, earlier.latency).map { $0 &- $1 }
        result.queueWait = zip(queueWait, earlier.queueWait).map { $0 &- $1 }
        result.interval = zip(interval, earlier.interval).map { $0 &- $1 }
        return result
    }
}
/// Q appends bounded numeric samples, readers copy under one lock. This
/// recorder never waits for Main or retains a profile, port, or error text.
package final class RuntimeTimingRecorder: @unchecked Sendable {
    package enum Kind { case profile, panic, controller }
    private struct Ring {
        var samples: [RuntimeTimingSample] = []
        var index = 0
        var count: UInt64 = 0
        mutating func append(_ sample: RuntimeTimingSample) {
            count &+= 1
            let recorded = RuntimeTimingSample(requestedAt: sample.requestedAt, completedAt: sample.completedAt,
                queueMilliseconds: sample.queueMilliseconds, totalMilliseconds: sample.totalMilliseconds, ordinal: count)
            if samples.count < RuntimeTimingRecorder.capacity { samples.append(recorded) } else { samples[index] = recorded }
            index = (index + 1) % RuntimeTimingRecorder.capacity
        }
    }
    package init() {}
    private let lock = NSLock()
    private var profiles = Ring(), panics = Ring(), controllers = Ring()
    private var aggregate = ControllerReportAggregate()
    private var lastReport: (session: UUID, received: Double)?
    /// Q: one processed device report, into ring and window aggregate. The
    /// interval is measured between reports of the same connection.
    package func recordControllerReport(session: UUID, received: Double, began: Double, completed: Double) {
        let total = max(0, completed - received) * 1_000, queue = max(0, began - received) * 1_000
        lock.lock(); defer { lock.unlock() }
        controllers.append(.init(requestedAt: received, completedAt: completed, queueMilliseconds: queue, totalMilliseconds: total))
        let gap = lastReport.flatMap { $0.session == session ? max(0, received - $0.received) * 1_000 : nil }
        aggregate.record(latency: total, queue: queue, interval: gap)
        lastReport = (session, received)
    }
    /// Ingress: a device report refused by the controller backlog limit.
    package func recordRefusedControllerReport() {
        lock.lock(); aggregate.refused &+= 1; lock.unlock()
    }
    package static let capacity = 2_048
    package func record(_ sample: RuntimeTimingSample, panic: Bool = false) {
        record(sample, kind: panic ? .panic : .profile)
    }
    package func record(_ sample: RuntimeTimingSample, kind: Kind) {
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case .profile: profiles.append(sample)
        case .panic: panics.append(sample)
        case .controller: controllers.append(sample)
        }
    }
    package func snapshot(processed: UInt64, discarded: UInt64, overflow: UInt64) -> RuntimeDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return .init(processedProfiles: processed, discardedProfiles: discarded, overflowProfiles: overflow,
            profileTimings: profiles.samples, panicTimings: panics.samples, profileTimingCount: profiles.count,
            panicTimingCount: panics.count, controllerTimings: controllers.samples, controllerTimingCount: controllers.count,
            controllerAggregate: aggregate)
    }
}
