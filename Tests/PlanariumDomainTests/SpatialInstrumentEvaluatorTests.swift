@testable import SickPLSMonitorKit
import XCTest
import SickPLSControlCore
import SickPLSCore
@testable import PlanariumDomain

final class SpatialInstrumentEvaluatorTests: XCTestCase {
    private func profile(_ centimeters: [UInt16]) throws -> B0ScanProfile {
        try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: try centimeters.map { try B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0) }
        )
    }

    func testTenCentimeterDepthFromOnePointFiveToTwoMetersHasFiveRings() {
        let rings = Set((150..<200).map { Int(floor(Double($0) / 10.0)) })
        XCTAssertEqual(rings, Set(15...19))
    }

    func testCellLabelPipelineTimingForLargeVisiblePlane() throws {
        let grid = MetricSquareGrid.oneCentimeter
        let ringCount = Int(2.0 / grid.cellSizeMeters)
        let cells = Set((0..<ringCount).flatMap { ring in
            let outerRadius = Double(ring + 1) * grid.cellSizeMeters
            let angularStep = PolarMetricCellSegment.angularStepDegrees(
                outerRadiusMeters: outerRadius,
                radialHeightMeters: grid.cellSizeMeters
            )
            let sectorCount = Int(ceil(180.0 / angularStep))
            return (0..<sectorCount).map { sector in
                PolarMetricGridCell(ring: ring, angularIndex: sector)
            }
        })
        let layerID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let target = SpatialRoutingTarget.midiCC(channel: 0, controller: 74)
        let layer = SpatialInstrumentLayer(
            id: layerID,
            name: "P3",
            color: .orange,
            polarCells: cells,
            routings: [SpatialRouting(target: target, program: .constant(0.5))]
        )
        let workspace = SpatialInstrumentWorkspace(grid: grid, layers: [layer])
        let viewport = try MetricCanvasViewport.build(
            centerXMeters: 0, centerYMeters: 1, metersPerPoint: 0.0005
        )
        let geometry = MetricCanvasGeometry(
            size: CGSize(width: 1_400, height: 1_000), viewport: viewport
        )

        let start = ContinuousClock.now
        let visibleCells = cells.filter { cell in
            let segment = PolarMetricCellSegment(cell: cell, grid: grid)
            guard SpatialCellLabel.isVisible(
                segment: segment, metersPerPoint: viewport.metersPerPoint
            ) else { return false }
            let bearing = (segment.startBearingDegrees + segment.endBearingDegrees) / 2
            let point = geometry.screenPoint(for: segment.point(
                radiusMeters: (segment.innerRadiusMeters + segment.outerRadiusMeters) / 2,
                bearingDegrees: bearing
            ))
            return geometry.canvasRect.contains(point)
        }
        let values = SpatialInstrumentEvaluator().cellValues(
            layerID: layerID, cells: Array(visibleCells), workspace: workspace
        )
        let labels: [String] = visibleCells.compactMap { cell in
            guard let value = values[cell] else { return nil }
            return SpatialCellLabel.text(for: value, target: target)
        }
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
            + Double(elapsed.components.seconds) * 1_000
        print("ZELLINFO-P3 cells=\(cells.count) labeled=\(labels.count) pipeline_ms=\(milliseconds)")
        XCTAssertEqual(cells.count, 60_820)
        XCTAssertEqual(labels.count, visibleCells.count)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
            + Double(duration.components.seconds) * 1_000
    }

    func testInvalidGridCannotEnterThroughJSON() throws {
        let data = Data(#"{"cellSizeMeters":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MetricSquareGrid.self, from: data))
    }

}
