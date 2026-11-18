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
}
/// Q appends bounded numeric samples, readers copy under one lock. This
/// recorder never waits for Main or retains a profile, port, or error text.
package final class RuntimeTimingRecorder: @unchecked Sendable {
    package init() {}
    private let lock = NSLock()
    private var profiles: [RuntimeTimingSample] = []
    private var panics: [RuntimeTimingSample] = []
    private var profileIndex = 0
    private var panicIndex = 0
    private var profileCount: UInt64 = 0
    private var panicCount: UInt64 = 0
    package static let capacity = 2_048
    package func record(_ sample: RuntimeTimingSample, panic: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let recorded = RuntimeTimingSample(requestedAt: sample.requestedAt, completedAt: sample.completedAt,
            queueMilliseconds: sample.queueMilliseconds, totalMilliseconds: sample.totalMilliseconds,
            ordinal: (panic ? panicCount : profileCount) &+ 1)
        if panic {
            if panics.count < Self.capacity { panics.append(recorded) }
            else { panics[panicIndex] = recorded }
            panicIndex = (panicIndex + 1) % Self.capacity; panicCount &+= 1
        } else {
            if profiles.count < Self.capacity { profiles.append(recorded) }
            else { profiles[profileIndex] = recorded }
            profileIndex = (profileIndex + 1) % Self.capacity; profileCount &+= 1
        }
    }
    package func snapshot(processed: UInt64, discarded: UInt64, overflow: UInt64) -> RuntimeDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return .init(processedProfiles: processed, discardedProfiles: discarded, overflowProfiles: overflow,
            profileTimings: profiles, panicTimings: panics, profileTimingCount: profileCount, panicTimingCount: panicCount)
    }
}
