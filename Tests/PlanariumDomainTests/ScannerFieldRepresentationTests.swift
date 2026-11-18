import XCTest
import PlanariumDomain

final class ScannerFieldRepresentationTests: XCTestCase {
    func testHalfCircleFromRealEditorCellsReachesScannerAndReturns100cm() throws {
        let cells = (2...5).map { PolarMetricGridCell(ring: 0, angularIndex: $0) }
        let grid = try MetricSquareGrid.build(cellSizeMeters: 1)
        let contour = try ScannerFieldRepresentation.contour(cells: cells, grid: grid).get()
        XCTAssertEqual(contour.radiiCentimeters, Array(repeating: 100, count: 361))
        XCTAssertEqual(contour.statusBits, Array(repeating: 0, count: 361))
    }
    func testRectanglePolarCellsSampleExpectedExterior() throws {
        let area = (0..<360).map { index -> PolarMetricCellSegment in
            let mid = (-90 + (Double(index) + 0.5) / 2) * Double.pi / 180
            let radius = min(1 / max(1e-12, abs(sin(mid))), 1 / max(1e-12, cos(mid)))
            return .init(innerRadiusMeters: 0, outerRadiusMeters: radius, startBearingDegrees: -90 + Double(index) / 2, endBearingDegrees: -90 + Double(index + 1) / 2)
        }
        let contour = try ScannerFieldRepresentation.contour(area: area).get()
        for point in contour.polygonMeters.dropFirst().dropLast() {
            XCTAssertEqual(max(abs(point.xMeters), point.yMeters), 1, accuracy: 0.01)
        }
    }
    func testIslandRingAndGapBetweenDeviceRaysRejectWithNamedReason() {
        let island = PolarMetricCellSegment(innerRadiusMeters: 1, outerRadiusMeters: 2, startBearingDegrees: -45, endBearingDegrees: 45)
        XCTAssertEqual(ScannerFieldRepresentation.contour(area: [island]), .failure(.doesNotReachScanner))
        let base = PolarMetricCellSegment(innerRadiusMeters: 0, outerRadiusMeters: 0.5, startBearingDegrees: -90, endBearingDegrees: 90)
        let ring = PolarMetricCellSegment(innerRadiusMeters: 1, outerRadiusMeters: 2, startBearingDegrees: -90, endBearingDegrees: 90)
        XCTAssertEqual(ScannerFieldRepresentation.contour(area: [ring]), .failure(.doesNotReachScanner))
        XCTAssertEqual(ScannerFieldRepresentation.contour(area: [base, ring]), .failure(.ringOrRadialGap))
        let thin = PolarMetricCellSegment(innerRadiusMeters: 1, outerRadiusMeters: 2, startBearingDegrees: 0.1, endBearingDegrees: 0.2)
        XCTAssertEqual(ScannerFieldRepresentation.contour(area: [base, thin]), .failure(.ringOrRadialGap))
        XCTAssertEqual(ScannerFieldRepresentation.contour(area: []), .failure(.emptyArea))
        let tooFine = PolarMetricCellSegment(innerRadiusMeters: 0, outerRadiusMeters: 1, startBearingDegrees: 0.1, endBearingDegrees: 0.2)
        XCTAssertEqual(ScannerFieldRepresentation.contour(area: [tooFine]), .failure(.angularDetailBelowSegmentResolution))
    }
    func testUnsupportedGeometryAndTooLargeRadiusReject() {
        for (cell, reason) in [
            (PolarMetricCellSegment(innerRadiusMeters: -1, outerRadiusMeters: 1, startBearingDegrees: 0, endBearingDegrees: 1), ScannerFieldRepresentation.Reason.invalidCell),
            (.init(innerRadiusMeters: 0, outerRadiusMeters: 1, startBearingDegrees: -91, endBearingDegrees: 0), .outsideForwardSemicircle),
            (.init(innerRadiusMeters: 0, outerRadiusMeters: 81.92, startBearingDegrees: -90, endBearingDegrees: 90), .radiusOutside13Bits)
        ] { XCTAssertEqual(ScannerFieldRepresentation.contour(area: [cell]), .failure(reason)) }
    }
}
