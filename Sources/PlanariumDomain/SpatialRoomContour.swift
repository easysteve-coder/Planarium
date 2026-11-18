import Foundation
import SickPLSCore
import PLSDeviceValues

/// Session room evidence, separate from the editable document and presets.
/// Capture time is supplied; this value never reads a clock.
public struct SpatialRoomContour: Codable, Equatable, Sendable {
    public struct Geometry: Codable, Equatable, Sendable {
        public let pointCount: Int
        public let angleResolutionDegrees: Double
        public let startAngleDegrees: Double
        public let sourceIdentifier: String

        public init(pointCount: Int, angleResolutionDegrees: Double, startAngleDegrees: Double, sourceIdentifier: String) {
            self.pointCount = pointCount
            self.angleResolutionDegrees = angleResolutionDegrees
            self.startAngleDegrees = startAngleDegrees
            self.sourceIdentifier = sourceIdentifier
        }
    }

    public let capturedAt: Date
    public let geometry: Geometry
    public let nearestDistancesCentimeters: [UInt16?]
    public let spreadCentimeters: [UInt16?]
    /// Hard inward edits must survive the fit-only closing of measured dips.
    public let drawnDistancesCentimeters: [UInt16?]?

    public init(
        capturedAt: Date = Date(timeIntervalSince1970: 0),
        geometry: Geometry,
        nearestDistancesCentimeters: [UInt16?],
        spreadCentimeters: [UInt16?],
        drawnDistancesCentimeters: [UInt16?]? = nil
    ) {
        self.capturedAt = capturedAt
        self.geometry = geometry
        self.nearestDistancesCentimeters = nearestDistancesCentimeters
        self.spreadCentimeters = spreadCentimeters
        self.drawnDistancesCentimeters = drawnDistancesCentimeters
    }

    /// Pure reduction of captured samples. The recorder supplies capture time
    /// and source geometry and remains responsible for synchronization.
    public static func measured(profiles: [[UInt16?]], capturedAt: Date, geometry: Geometry) -> Self? {
        guard !profiles.isEmpty, geometry.pointCount >= 0 else { return nil }
        let nearest = (0..<geometry.pointCount).map { index -> UInt16? in
            let values = profiles.compactMap { $0.indices.contains(index) ? $0[index] : nil }.sorted()
            // Discard exactly one inward outlier; two samples are required.
            // Recorder collects a full acquisition window per ray.
            guard values.count > 1 else { return nil }
            return values[1]
        }
        let spread = (0..<geometry.pointCount).map { index -> UInt16? in
            let values = profiles.compactMap { $0.indices.contains(index) ? $0[index] : nil }.sorted()
            guard values.count > 1 else { return nil }
            return UInt16(clamping: Int(values.last! - values.first!))
        }
        return Self(capturedAt: capturedAt, geometry: geometry,
                    nearestDistancesCentimeters: nearest, spreadCentimeters: spread)
    }

    public var measuredSpreadCentimeters: UInt16 {
        spreadCentimeters.compactMap { $0 }.max() ?? 0
    }

    /// Capture stores peak-to-peak spread; ± scatter is half that span,
    /// rounded up to whole centimeters for the detection recommendation.
    public var measuredScatterCentimeters: UInt16 {
        UInt16((Int(measuredSpreadCentimeters)+1)/2)
    }

    /// A single ray is marked restless when its half peak-to-peak capture
    /// range exceeds 8 cm.  Five seconds normally makes the robust nearest
    /// contour stable; this deliberately highlights only rays whose local
    /// movement exceeds that normal capture scatter, not the one worst ray.
    public static let restlessBeamScatterThresholdCentimeters: UInt16 = 8
    public var restlessBeamIndexes: [Int] {
        spreadCentimeters.enumerated().compactMap { index, spread in
            guard let spread else { return nil }
            let scatter = UInt16((Int(spread) + 1) / 2)
            return scatter > Self.restlessBeamScatterThresholdCentimeters ? index : nil
        }
    }
    public var restlessBeamCount: Int { restlessBeamIndexes.count }

    public func compatibility(with geometry: Geometry) -> Bool {
        guard self.geometry.sourceIdentifier == geometry.sourceIdentifier,
              self.geometry.pointCount > 0, geometry.pointCount > 0,
              self.geometry.angleResolutionDegrees > 0, geometry.angleResolutionDegrees > 0 else { return false }
        let end = self.geometry.startAngleDegrees + Double(self.geometry.pointCount - 1) * self.geometry.angleResolutionDegrees
        let otherEnd = geometry.startAngleDegrees + Double(geometry.pointCount - 1) * geometry.angleResolutionDegrees
        return abs(self.geometry.startAngleDegrees - geometry.startAngleDegrees) < 1e-6 && abs(end - otherEnd) < 1e-6
    }

    /// The exact strict cut used by both detection and the visible contour.
    public func effectiveBoundaryCentimeters(at index: Int, toleranceCentimeters: UInt16) -> Int? {
        guard nearestDistancesCentimeters.indices.contains(index), let wall = nearestDistancesCentimeters[index] else { return nil }
        return max(0, Int(wall) - Int(toleranceCentimeters))
    }

    public func filters(distanceCentimeters: UInt16, at index: Int, toleranceCentimeters: UInt16) -> Bool {
        guard let boundary = effectiveBoundaryCentimeters(at: index, toleranceCentimeters: toleranceCentimeters) else {
            return true
        }
        return Int(distanceCentimeters) < boundary
    }
    /// Map the measured ray span onto captured angular bins. Coarser rays use
    /// the nearest wall in their span; this never invents an outward boundary.
    public func filters(distanceCentimeters: UInt16, bearingDegrees: Double, spanDegrees: Double,
                        toleranceCentimeters: UInt16) -> Bool {
        let step = geometry.angleResolutionDegrees
        guard step > 0, geometry.pointCount > 0 else { return true }
        let half = max(step, spanDegrees) / 2
        let lower = max(0, Int(ceil((bearingDegrees - half - geometry.startAngleDegrees) / step - 1e-9)))
        let upper = min(nearestDistancesCentimeters.count - 1, Int(floor((bearingDegrees + half - geometry.startAngleDegrees) / step + 1e-9)))
        guard lower <= upper else { return true }
        let boundary = (lower...upper).compactMap { effectiveBoundaryCentimeters(at: $0, toleranceCentimeters: toleranceCentimeters) }.min()
        guard let boundary else { return true }
        return Int(distanceCentimeters) < boundary
    }
}

public struct SpatialRoomContourConfiguration: Codable, Equatable, Sendable {
    public static let defaultToleranceCentimeters: UInt16 = 5
    public var isEnabled: Bool
    public var toleranceCentimeters: UInt16

    public init(isEnabled: Bool = false, toleranceCentimeters: UInt16 = Self.defaultToleranceCentimeters) {
        self.isEnabled = isEnabled
        self.toleranceCentimeters = min(max(toleranceCentimeters, 1), 30)
    }
}
