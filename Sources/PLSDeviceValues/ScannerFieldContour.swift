import Foundation

/// Offline segmented field value. Status bits remain uninterpreted.
/// The angular convention is the product's forward semicircle, not a
/// hardware-verified orientation or a field/output identity.
public struct ScannerFieldContour: Equatable, Sendable {
    public enum SegmentCount: Int, Codable, CaseIterable, Sendable { case ninety = 90, oneEighty = 180, threeSixty = 360 }
    public enum BuildError: Error, Equatable, Sendable {
        case wrongPointCount(expected: Int, radii: Int, statusBits: Int)
        case radiusOutside13Bits(index: Int)
        case statusOutside3Bits(index: Int)
    }
    public let segments: SegmentCount
    public let radiiCentimeters: [UInt16]
    public let statusBits: [UInt8]
    private init(segments: SegmentCount, radiiCentimeters: [UInt16], statusBits: [UInt8]) {
        self.segments = segments; self.radiiCentimeters = radiiCentimeters; self.statusBits = statusBits
    }
    public static func build(segments: SegmentCount, radiiCentimeters: [UInt16], statusBits: [UInt8]) throws -> Self {
        let count = segments.rawValue + 1
        guard radiiCentimeters.count == count, statusBits.count == count else {
            throw BuildError.wrongPointCount(expected: count, radii: radiiCentimeters.count, statusBits: statusBits.count)
        }
        for (index, radius) in radiiCentimeters.enumerated() where radius > 0x1FFF { throw BuildError.radiusOutside13Bits(index: index) }
        for (index, bits) in statusBits.enumerated() where bits > 7 { throw BuildError.statusOutside3Bits(index: index) }
        return .init(segments: segments, radiiCentimeters: radiiCentimeters, statusBits: statusBits)
    }
    /// Closed polygon, including the scanner origin and both edge rays.
    /// Connecting the sampled radii is a display approximation between rays.
    public var polygonMeters: [MetricScanPoint] {
        let origin = MetricScanPoint(xMeters: 0, yMeters: 0)
        return [origin] + radiiCentimeters.enumerated().map { index, radius in
            let angle = (-90 + Double(index) * 180 / Double(segments.rawValue)) * .pi / 180
            return .init(xMeters: sin(angle) * Double(radius) / 100, yMeters: cos(angle) * Double(radius) / 100)
        } + [origin]
    }
}
