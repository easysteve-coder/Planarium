import Foundation

/// Offline editor-to-field calculation. Checks the entire cell union for
/// radial holes, including between device rays, then samples its exterior
/// at N+1 rays. The returned centimeter contour approximates curved editor
/// edges between rays; it makes no field/output or hardware-orientation claim.
public enum ScannerFieldRepresentation {
    public enum Reason: Error, Equatable, Sendable {
        case emptyArea
        case invalidCell
        case outsideForwardSemicircle
        case doesNotReachScanner
        case ringOrRadialGap
        case radiusOutside13Bits
        case angularDetailBelowSegmentResolution
    }
    public static func contour(cells: [PolarMetricGridCell], grid: MetricSquareGrid,
                               segments: ScannerFieldContour.SegmentCount = .threeSixty) -> Result<ScannerFieldContour, Reason> {
        contour(area: cells.map { PolarMetricCellSegment(cell: $0, grid: grid) }, segments: segments)
    }
    public static func contour(area: [PolarMetricCellSegment],
                               segments: ScannerFieldContour.SegmentCount = .threeSixty) -> Result<ScannerFieldContour, Reason> {
        guard !area.isEmpty else { return .failure(.emptyArea) }
        let epsilon = 1e-8
        for cell in area {
            guard [cell.innerRadiusMeters, cell.outerRadiusMeters, cell.startBearingDegrees, cell.endBearingDegrees].allSatisfy(\.isFinite),
                  cell.innerRadiusMeters >= 0, cell.innerRadiusMeters < cell.outerRadiusMeters,
                  cell.startBearingDegrees < cell.endBearingDegrees else { return .failure(.invalidCell) }
            guard cell.startBearingDegrees >= -90, cell.endBearingDegrees <= 90 else { return .failure(.outsideForwardSemicircle) }
            guard cell.outerRadiusMeters <= 81.91 else { return .failure(.radiusOutside13Bits) }
        }
        let step = 180 / Double(segments.rawValue)
        let rays = (0...segments.rawValue).map { -90 + Double($0) * step }
        let boundaries = Set(area.flatMap { [$0.startBearingDegrees, $0.endBearingDegrees] } + rays).sorted()
        func exterior(_ bearing: Double, inclusive: Bool) -> Result<Double, Reason> {
            let intervals = area.filter {
                inclusive ? bearing >= $0.startBearingDegrees - epsilon && bearing <= $0.endBearingDegrees + epsilon
                    : bearing > $0.startBearingDegrees && bearing < $0.endBearingDegrees
            }.sorted { $0.innerRadiusMeters < $1.innerRadiusMeters }
            guard let first = intervals.first else { return .success(0) }
            guard first.innerRadiusMeters <= epsilon else { return .failure(.doesNotReachScanner) }
            var outer = first.outerRadiusMeters
            for interval in intervals.dropFirst() {
                guard interval.innerRadiusMeters <= outer + epsilon else { return .failure(.ringOrRadialGap) }
                outer = max(outer, interval.outerRadiusMeters)
            }
            return .success(outer)
        }
        // Every open angular slab is checked, so a thin island/ring cannot
        // escape merely by lying between two device sample rays.
        for index in 0..<(boundaries.count - 1) {
            if case .failure(let reason) = exterior((boundaries[index] + boundaries[index + 1]) / 2, inclusive: false) { return .failure(reason) }
        }
        // A discontinuity inside a device segment cannot be represented by
        // its two endpoint radii. Reject it rather than silently filling it.
        for boundary in boundaries where boundary > -90 && boundary < 90 {
            if abs((boundary + 90) / step - ((boundary + 90) / step).rounded()) > epsilon,
               case .success(let left) = exterior(boundary - epsilon, inclusive: false),
               case .success(let right) = exterior(boundary + epsilon, inclusive: false), abs(left - right) > epsilon {
                return .failure(.angularDetailBelowSegmentResolution)
            }
        }
        var radii: [UInt16] = []
        for bearing in rays {
            switch exterior(bearing, inclusive: true) {
            case .success(let radius): radii.append(UInt16((radius * 100).rounded()))
            case .failure(let reason): return .failure(reason)
            }
        }
        do { return .success(try .build(segments: segments, radiiCentimeters: radii,
                                       statusBits: Array(repeating: 0, count: radii.count))) }
        catch { return .failure(.radiusOutside13Bits) }
    }
}
