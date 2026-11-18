import PlanariumDomain
import Foundation
import SickPLSCore
import SickPLSControlCore

/// Profile-synchronous recorder used by the normal profile ingress. It keeps
/// no UI state and can therefore be cancelled by simply ending the capture.
public final class SpatialRoomContourRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [[UInt16?]] = []
    private var expectedPointCount: Int?
    private var startedAt: Date?
    private var sourceIdentifier = "scanner:default"
    private var targetProfileCount = SpatialRoomContourRecorder.defaultTargetProfileCount

    /// Capture length when no duration is chosen: two seconds at 25 Hz.
    public static let defaultTargetProfileCount = 50

    public init() {}

    public func begin(sourceIdentifier: String = "scanner:default",
                      targetProfileCount: Int = SpatialRoomContourRecorder.defaultTargetProfileCount) {
        lock.lock()
        profiles.removeAll()
        expectedPointCount = nil
        startedAt = Date()
        self.sourceIdentifier = sourceIdentifier
        self.targetProfileCount = max(1, targetProfileCount)
        lock.unlock()
    }

    @discardableResult
    public func append(_ profile: B0ScanProfile) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard startedAt != nil else { return 0 }
        if expectedPointCount == nil { expectedPointCount = profile.measurements.count }
        guard expectedPointCount == profile.measurements.count else { return progressLocked() }
        profiles.append(profile.measurements.map { UsableRawDistance.contains($0.value) ? $0.distanceCentimeters : nil })
        return progressLocked()
    }

    public func cancel() {
        lock.lock(); profiles.removeAll(); startedAt = nil; expectedPointCount = nil; lock.unlock()
    }

    public func finish() -> SpatialRoomContour? {
        lock.lock(); defer { lock.unlock() }
        guard let startedAt, let count = expectedPointCount, !profiles.isEmpty else { return nil }
        self.startedAt = nil
        let geometry = SpatialRoomContour.Geometry(
            pointCount: count,
            angleResolutionDegrees: count > 1 ? 180 / Double(count - 1) : 180,
            startAngleDegrees: -90,
            sourceIdentifier: sourceIdentifier
        )
        return SpatialRoomContour.measured(profiles: profiles, capturedAt: startedAt, geometry: geometry)
    }

    private func progressLocked() -> Double {
        min(1, Double(profiles.count) / Double(targetProfileCount))
    }
}
