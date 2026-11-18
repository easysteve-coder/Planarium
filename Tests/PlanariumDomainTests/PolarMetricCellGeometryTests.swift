import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class PolarMetricCellGeometryTests: XCTestCase {
    func testSegmentKeepsTheSquareEdgeAsRadialDepth() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.5)
        let segment = PolarMetricCellSegment(cell: MetricGridCell(column: 1, row: 3), grid: grid)

        XCTAssertEqual(segment.outerRadiusMeters - segment.innerRadiusMeters, 0.5, accuracy: 1e-12)
        XCTAssertLessThan(segment.startBearingDegrees, segment.endBearingDegrees)
    }

    func testOriginalCellCenterFallsInsideItsSnappedPolarGridCell() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.25)
        let cell = MetricGridCell(column: -3, row: 5)
        let bounds = grid.bounds(of: cell)
        let segment = PolarMetricCellSegment(cell: cell, grid: grid)
        let centerX = (bounds.minXMeters + bounds.maxXMeters) / 2
        let centerY = (bounds.minYMeters + bounds.maxYMeters) / 2
        let radius = hypot(centerX, centerY)
        let bearing = atan2(centerX, centerY) * 180 / .pi

        XCTAssertGreaterThanOrEqual(radius, segment.innerRadiusMeters)
        XCTAssertLessThan(radius, segment.outerRadiusMeters)
        XCTAssertGreaterThanOrEqual(bearing, segment.startBearingDegrees)
        XCTAssertLessThan(bearing, segment.endBearingDegrees)
        XCTAssertLessThanOrEqual(
            segment.outerArcWidthMeters,
            segment.radialHeightMeters * 1.5 + 1e-12
        )
    }

    func testSnappedSegmentUsesExactlyTheAdaptiveGridBoundaries() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.25)
        let segment = PolarMetricCellSegment(
            cell: MetricGridCell(column: 10, row: 20),
            grid: grid
        )
        let expectedStep = PolarMetricCellSegment.angularStepDegrees(
            outerRadiusMeters: segment.outerRadiusMeters,
            radialHeightMeters: 0.25
        )

        XCTAssertEqual(segment.endBearingDegrees - segment.startBearingDegrees, expectedStep, accuracy: 1e-12)
        XCTAssertEqual(segment.innerRadiusMeters.truncatingRemainder(dividingBy: 0.25), 0, accuracy: 1e-12)
    }

    func testCoordinateModeNamesTheTwoStoredCellTopologies() {
        XCTAssertEqual(Set(MetricViewportCoordinateMode.allCases), [.cartesian, .polar])
    }

    func testWideRingSectorIsSplitUntilEveryPartObeysOnePointFiveToOneLimit() {
        let segment = PolarMetricCellSegment(
            innerRadiusMeters: 9.5,
            outerRadiusMeters: 10,
            startBearingDegrees: -10,
            endBearingDegrees: 10
        )

        let parts = segment.subdivided(maximumWidthToRadialHeightRatio: 1.5)

        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts.first?.startBearingDegrees, -10)
        XCTAssertEqual(parts.last?.endBearingDegrees, 10)
        XCTAssertTrue(parts.allSatisfy {
            $0.outerArcWidthMeters <= $0.radialHeightMeters * 1.5 + 1e-12
        })
    }

    func testNarrowRingSectorRemainsOneCell() {
        let segment = PolarMetricCellSegment(
            innerRadiusMeters: 1.5,
            outerRadiusMeters: 2,
            startBearingDegrees: 0,
            endBearingDegrees: 10
        )

        XCTAssertEqual(segment.subdivided().count, 1)
    }

    func testEveryPolarSectorRoundTripsThroughItsCenter() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.25)
        for ring in 1...40 {
            let outerRadius = Double(ring) * grid.cellSizeMeters
            let step = PolarMetricCellSegment.angularStepDegrees(
                outerRadiusMeters: outerRadius,
                radialHeightMeters: grid.cellSizeMeters
            )
            for bearing in stride(from: -90.0, to: 90.0, by: step) {
                let target = PolarMetricCellSegment(
                    innerRadiusMeters: outerRadius - grid.cellSizeMeters,
                    outerRadiusMeters: outerRadius,
                    startBearingDegrees: bearing,
                    endBearingDegrees: bearing + step
                )
                let point = target.point(
                    radiusMeters: outerRadius - grid.cellSizeMeters / 2,
                    bearingDegrees: bearing + step / 2
                )
                let address = PolarMetricGridCell(point: point, grid: grid)
                let roundTrip = PolarMetricCellSegment(cell: address, grid: grid)
                XCTAssertEqual(roundTrip.innerRadiusMeters, target.innerRadiusMeters, accuracy: 1e-12)
                XCTAssertEqual(roundTrip.outerRadiusMeters, target.outerRadiusMeters, accuracy: 1e-12)
                XCTAssertEqual(roundTrip.startBearingDegrees, target.startBearingDegrees, accuracy: 1e-10)
                XCTAssertEqual(roundTrip.endBearingDegrees, target.endBearingDegrees, accuracy: 1e-10)
            }
        }
    }
}
