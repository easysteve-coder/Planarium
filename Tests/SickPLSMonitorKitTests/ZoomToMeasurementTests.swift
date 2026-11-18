import XCTest
import SickPLSControlCore
import SickPLSCore
@testable import SickPLSMonitorKit

final class ZoomToMeasurementTests: XCTestCase {
    private func profile(_ values: [UInt16]) throws -> B0ScanProfile {
        try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: try values.map { try .build(value: $0, fieldFlags: 0) }
        )
    }

    private func points(_ profile: B0ScanProfile) -> [MetricScanPoint] {
        MetricScanProjection().project(profile).map(\.point)
    }

    func testFitCentersOnMeasurementAndUsesTheTighterAxis() throws {
        let scan = try profile([150, 200, 150, 120])
        let projected = points(scan)
        let minX = projected.map(\.xMeters).min()!, maxX = projected.map(\.xMeters).max()!
        let minY = projected.map(\.yMeters).min()!, maxY = projected.map(\.yMeters).max()!
        let width = (maxX - minX) + 2 * max(0.10, (maxX - minX) * 0.10)
        let height = (maxY - minY) + 2 * max(0.10, (maxY - minY) * 0.10)

        for size in [CGSize(width: 800, height: 400), CGSize(width: 400, height: 800)] {
            var state = MetricCanvasInteractionState()
            XCTAssertTrue(state.fitViewport(toMeasurementsOf: scan, canvasSize: size))
            XCTAssertEqual(state.viewport.centerXMeters, (minX + maxX) / 2, accuracy: 1e-9)
            XCTAssertEqual(state.viewport.centerYMeters, (minY + maxY) / 2, accuracy: 1e-9)
            let expected = max(width / Double(size.width), height / Double(size.height))
            XCTAssertEqual(state.viewport.metersPerPoint, expected, accuracy: 1e-12)
            let geometry = MetricCanvasGeometry(size: size, viewport: state.viewport)
            for point in projected {
                XCTAssertTrue(geometry.canvasRect.contains(geometry.screenPoint(for: point)))
            }
        }
    }

    func testMinimumMarginIsTenCentimetres() throws {
        // Ein einzelner Punkt: Ausdehnung 0, Rand je Seite 10 cm -> 0,2 m.
        let scan = try profile([300])
        var state = MetricCanvasInteractionState()
        XCTAssertTrue(state.fitViewport(toMeasurementsOf: scan, canvasSize: CGSize(width: 100, height: 100)))
        XCTAssertEqual(state.viewport.metersPerPoint, 0.2 / 100, accuracy: 1e-12)
    }

    func testFarValuesAreIgnored() throws {
        let scan = try profile([150, 8191, 150])
        var state = MetricCanvasInteractionState()
        XCTAssertTrue(state.fitViewport(toMeasurementsOf: scan, canvasSize: CGSize(width: 800, height: 800)))
        XCTAssertLessThan(state.viewport.metersPerPoint, 0.01,
                          "ein Fernwert (81,9 m) darf den Ausschnitt nicht aufblähen")
    }

    func testNoValidPointLeavesViewportUnchanged() throws {
        let scan = try profile([8191, 8191])
        var state = MetricCanvasInteractionState()
        let before = state.viewport
        XCTAssertFalse(state.fitViewport(toMeasurementsOf: scan, canvasSize: CGSize(width: 800, height: 800)))
        XCTAssertEqual(state.viewport, before)
    }
}
