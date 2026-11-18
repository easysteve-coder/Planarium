import Foundation
import PLSDeviceValues

/// Session-only angular drawing. No document encoder or profile-path geometry.
public struct SpatialDrawnContour: Equatable, Sendable {
    public private(set) var geometry: SpatialRoomContour.Geometry
    public private(set) var distances: [UInt16?]
    public init(geometry: SpatialRoomContour.Geometry) {
        self.geometry = geometry
        distances = Array(repeating: nil, count: geometry.pointCount)
    }
    public mutating func resample(to target: SpatialRoomContour.Geometry) {
        guard geometry != target else { return }
        distances = (0..<target.pointCount).map { index in
            let angle = target.startAngleDegrees + Double(index) * target.angleResolutionDegrees
            let source = Int(((angle - geometry.startAngleDegrees) / geometry.angleResolutionDegrees).rounded())
            return distances.indices.contains(source) ? distances[source] : nil
        }
        geometry = target
    }
    /// Exact ray/segment intersection fills every crossed angular bin, even
    /// when the pointer skips hundreds of rays between input events.
    public mutating func stroke(from a: MetricScanPoint, to b: MetricScanPoint, erasing: Bool = false) {
        let ax = a.xMeters, ay = a.yMeters, dx = b.xMeters - ax, dy = b.yMeters - ay
        guard [ax, ay, dx, dy].allSatisfy(\.isFinite) else { return }
        func cross(_ x: Double, _ y: Double, _ u: Double, _ v: Double) -> Double { x*v-y*u }
        for index in distances.indices {
            let angle = (geometry.startAngleDegrees + Double(index) * geometry.angleResolutionDegrees) * .pi / 180
            let x = sin(angle), y = cos(angle), denominator = cross(x,y,dx,dy)
            guard abs(denominator) > 1e-10 else { continue }
            let radius = cross(ax,ay,dx,dy) / denominator
            let fraction = cross(ax,ay,x,y) / denominator
            if radius > 0, fraction >= -1e-9, fraction <= 1+1e-9 {
                distances[index] = erasing ? nil : UInt16(clamping: Int(min(65535, radius*100).rounded()))
            }
        }
        // The first click and narrow strokes still address their nearest bin.
        for point in [a,b] {
            let angle = atan2(point.xMeters, point.yMeters)*180 / .pi
            let index = Int(((angle-geometry.startAngleDegrees)/geometry.angleResolutionDegrees).rounded())
            let radius = hypot(point.xMeters, point.yMeters)*100
            if distances.indices.contains(index), radius > 0 {
                distances[index] = erasing ? nil : UInt16(clamping: Int(min(65535, radius).rounded()))
            }
        }
    }
    public func effective(measured: SpatialRoomContour?) -> SpatialRoomContour? {
        guard distances.contains(where: { $0 != nil }) else { return measured }
        let compatible = measured?.compatibility(with: geometry) == true
        var walls = distances
        var spread = Array<UInt16?>(repeating: nil, count: geometry.pointCount)
        var hardBounds = Array<UInt16?>(repeating: nil, count: geometry.pointCount)
        for index in distances.indices {
            let angle = geometry.startAngleDegrees + Double(index)*geometry.angleResolutionDegrees
            var wall: UInt16?
            if compatible, let measured {
                // Keep the captured contour's conservative angular-span rule.
                // Only the drawn evidence is resampled by nearest ray.
                let step = measured.geometry.angleResolutionDegrees
                let half = max(step, geometry.angleResolutionDegrees) / 2
                let lower = max(0, Int(ceil((angle-half-measured.geometry.startAngleDegrees)/step-1e-9)))
                let upper = min(measured.nearestDistancesCentimeters.count-1,
                    Int(floor((angle+half-measured.geometry.startAngleDegrees)/step+1e-9)))
                if lower <= upper {
                    for source in lower...upper {
                        if let value = measured.nearestDistancesCentimeters[source] { wall = min(wall ?? value, value) }
                        if measured.spreadCentimeters.indices.contains(source), let value = measured.spreadCentimeters[source] {
                            spread[index] = max(spread[index] ?? value, value)
                        }
                    }
                }
            }
            if let drawn = distances[index], Int(drawn) < (wall.map(Int.init) ?? 65536) { hardBounds[index] = drawn }
            if let drawn = distances[index], let wall { walls[index] = min(drawn,wall) }
            else { walls[index] = distances[index] ?? wall }
        }
        if let measured, measured.geometry == geometry, walls == measured.nearestDistancesCentimeters {
            return measured
        }
        return .init(capturedAt: measured?.capturedAt ?? Date(timeIntervalSince1970: 0), geometry: geometry,
                     nearestDistancesCentimeters: walls, spreadCentimeters: spread, drawnDistancesCentimeters: hardBounds)
    }
}
