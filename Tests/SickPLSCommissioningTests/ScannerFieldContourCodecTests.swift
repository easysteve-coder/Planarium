import XCTest
import PLSDeviceValues
import SickPLSCommissioning

final class ScannerFieldContourCodecTests: XCTestCase {
    /// Constructed from the documented layout, with all eight status values,
    /// asymmetric LE radii, zero and the maximum; no captured device bytes.
    func testBothDocumentedWireFormsRoundTripBitForBit() throws {
        for (segments, code, size) in [(ScannerFieldContour.SegmentCount.ninety, UInt8(0x5A), 184), (.threeSixty, 0xFE, 724)] {
            var bytes: [UInt8] = [0x43, code], radii: [UInt16] = [], status: [UInt8] = []
            for index in 0...segments.rawValue {
                let radius = index == 0 ? UInt16(0) : index == segments.rawValue ? UInt16(8191) : UInt16(257 + index * 13)
                let bits = UInt8(index % 8), word = radius | UInt16(bits) << 13
                radii.append(radius); status.append(bits)
                bytes += [UInt8(word & 255), UInt8(word >> 8)]
            }
            XCTAssertEqual(bytes.count, size)
            let decoded = try ScannerFieldContourCodec.decode(bytes)
            XCTAssertEqual(decoded.segments, segments)
            XCTAssertEqual(decoded.radiiCentimeters, radii)
            XCTAssertEqual(decoded.statusBits, status)
            XCTAssertEqual(try ScannerFieldContourCodec.encode(decoded), bytes)
        }
    }
    func testUnknownCodesAndWrongLengthsAreNamedAnd180HasNoInventedWireCode() throws {
        XCTAssertThrowsError(try ScannerFieldContourCodec.decode([])) { XCTAssertEqual($0 as? ScannerFieldContourCodec.CodecError, .missingHeader) }
        XCTAssertThrowsError(try ScannerFieldContourCodec.decode([0xC3, 0x5A])) { XCTAssertEqual($0 as? ScannerFieldContourCodec.CodecError, .unexpectedCommand(0xC3)) }
        for code in [UInt8(0), 0xB4, 0xFF] {
            XCTAssertThrowsError(try ScannerFieldContourCodec.decode([0x43, code])) { XCTAssertEqual($0 as? ScannerFieldContourCodec.CodecError, .unknownSegmentCode(code)) }
        }
        for size in [183, 185, 182, 724] {
            let bytes = [UInt8(0x43), 0x5A] + Array(repeating: UInt8(0), count: size - 2)
            XCTAssertThrowsError(try ScannerFieldContourCodec.decode(bytes)) { XCTAssertEqual($0 as? ScannerFieldContourCodec.CodecError, .wrongLength(expected: 184, actual: size)) }
        }
        let unsupported = try ScannerFieldContour.build(segments: .oneEighty, radiiCentimeters: Array(repeating: 100, count: 181), statusBits: Array(repeating: 0, count: 181))
        XCTAssertThrowsError(try ScannerFieldContourCodec.encode(unsupported)) { XCTAssertEqual($0 as? ScannerFieldContourCodec.CodecError, .unsupportedWireSegmentCount(180)) }
    }
    func testValueInvariantsNeverClampRadiusOrStatusBits() throws {
        var radii = Array(repeating: UInt16(100), count: 91), status = Array(repeating: UInt8(0), count: 91)
        radii[7] = 8192
        XCTAssertThrowsError(try ScannerFieldContour.build(segments: .ninety, radiiCentimeters: radii, statusBits: status)) { XCTAssertEqual($0 as? ScannerFieldContour.BuildError, .radiusOutside13Bits(index: 7)) }
        radii[7] = 100; status[8] = 8
        XCTAssertThrowsError(try ScannerFieldContour.build(segments: .ninety, radiiCentimeters: radii, statusBits: status)) { XCTAssertEqual($0 as? ScannerFieldContour.BuildError, .statusOutside3Bits(index: 8)) }
        XCTAssertThrowsError(try ScannerFieldContour.build(segments: .ninety, radiiCentimeters: [], statusBits: [])) { XCTAssertEqual($0 as? ScannerFieldContour.BuildError, .wrongPointCount(expected: 91, radii: 0, statusBits: 0)) }
    }
    func testPolygonHasMeterScaleForwardHalfCircleAndRectangle() throws {
        let circle = try ScannerFieldContour.build(segments: .threeSixty, radiiCentimeters: Array(repeating: 100, count: 361), statusBits: Array(repeating: 7, count: 361))
        let polygon = circle.polygonMeters
        XCTAssertEqual(polygon.count, 363)
        XCTAssertEqual(polygon.first, polygon.last)
        XCTAssertEqual(polygon[1].xMeters, -1, accuracy: 1e-10)
        XCTAssertEqual(polygon[181].yMeters, 1, accuracy: 1e-10)
        for point in polygon.dropFirst().dropLast() { XCTAssertEqual(point.xMeters * point.xMeters + point.yMeters * point.yMeters, 1, accuracy: 1e-10) }
        let radii = (0...360).map { index -> UInt16 in
            let a = (-90 + Double(index) / 2) * Double.pi / 180
            return UInt16((min(1 / max(1e-12, abs(sin(a))), 1 / max(1e-12, cos(a))) * 100).rounded())
        }
        let rectangle = try ScannerFieldContour.build(segments: .threeSixty, radiiCentimeters: radii, statusBits: Array(repeating: 0, count: 361))
        for point in rectangle.polygonMeters.dropFirst().dropLast() {
            XCTAssertEqual(max(abs(point.xMeters), point.yMeters), 1, accuracy: 0.0051)
        }
    }
}
