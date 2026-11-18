import XCTest
import SickPLSControlCore
@testable import SickPLSMonitorKit

final class MetricCanvasGeometryTests: XCTestCase {
    func testMetricScreenRoundTripIsExactAcrossViewport() throws {
        let viewport = try MetricCanvasViewport.build(
            centerXMeters: -1.25,
            centerYMeters: 3.5,
            metersPerPoint: 0.02
        )
        let geometry = MetricCanvasGeometry(size: CGSize(width: 900, height: 600), viewport: viewport)

        for point in [
            MetricScanPoint(xMeters: -1.25, yMeters: 3.5),
            MetricScanPoint(xMeters: -4, yMeters: 0),
            MetricScanPoint(xMeters: 2.75, yMeters: 7.25)
        ] {
            let screen = geometry.screenPoint(for: point)
            let roundTrip = try XCTUnwrap(geometry.metricPoint(forScreenPoint: screen))
            XCTAssertEqual(roundTrip.xMeters, point.xMeters, accuracy: 1e-12)
            XCTAssertEqual(roundTrip.yMeters, point.yMeters, accuracy: 1e-12)
        }
    }

    func testHorizontalMirrorFlipsDisplayAndMouseMappingButNotWorldCoordinates() throws {
        let viewport = try MetricCanvasViewport.build(
            centerXMeters: 0.5,
            centerYMeters: 3,
            metersPerPoint: 0.01
        )
        let normal = MetricCanvasGeometry(
            size: CGSize(width: 800, height: 600), viewport: viewport
        )
        let mirrored = MetricCanvasGeometry(
            size: CGSize(width: 800, height: 600), viewport: viewport,
            isHorizontallyMirrored: true
        )
        let point = MetricScanPoint(xMeters: 1.25, yMeters: 4.5)

        let normalScreen = normal.screenPoint(for: point)
        let mirroredScreen = mirrored.screenPoint(for: point)
        XCTAssertEqual(mirroredScreen.x, 800 - normalScreen.x, accuracy: 1e-12)
        XCTAssertEqual(mirroredScreen.y, normalScreen.y, accuracy: 1e-12)

        let roundTrip = try XCTUnwrap(mirrored.metricPoint(forScreenPoint: mirroredScreen))
        XCTAssertEqual(roundTrip.xMeters, point.xMeters, accuracy: 1e-12)
        XCTAssertEqual(roundTrip.yMeters, point.yMeters, accuracy: 1e-12)
    }

    func testDefaultPlacesScannerOriginAtBottomForEightHundredPoints() {
        let geometry = MetricCanvasGeometry(
            size: CGSize(width: 1000, height: 800),
            viewport: .instrumentDefault
        )
        let origin = geometry.screenPoint(for: MetricScanPoint(xMeters: 0, yMeters: 0))

        XCTAssertEqual(origin.x, 500, accuracy: 1e-12)
        XCTAssertEqual(origin.y, 800, accuracy: 1e-12)
        XCTAssertEqual(geometry.canvasBaselineY, 799, accuracy: 0)
    }

    func testZoomKeepsAnchorAtTheSameScreenPoint() throws {
        let before = try MetricCanvasViewport.build(
            centerXMeters: 1,
            centerYMeters: 4,
            metersPerPoint: 0.02
        )
        let anchor = MetricScanPoint(xMeters: -2, yMeters: 6)
        let beforeGeometry = MetricCanvasGeometry(size: CGSize(width: 800, height: 500), viewport: before)
        let screenBefore = beforeGeometry.screenPoint(for: anchor)

        let after = try XCTUnwrap(before.zoomed(byFactor: 2.5, anchor: anchor))
        let afterGeometry = MetricCanvasGeometry(size: CGSize(width: 800, height: 500), viewport: after)
        let screenAfter = afterGeometry.screenPoint(for: anchor)

        XCTAssertEqual(screenAfter.x, screenBefore.x, accuracy: 1e-10)
        XCTAssertEqual(screenAfter.y, screenBefore.y, accuracy: 1e-10)
        XCTAssertEqual(after.metersPerPoint, 0.008, accuracy: 1e-12)
    }

    func testPanUsesScreenDirectionButPreservesScale() throws {
        let before = MetricCanvasViewport.instrumentDefault
        let geometry = MetricCanvasGeometry(size: CGSize(width: 800, height: 600), viewport: before)
        let after = try XCTUnwrap(geometry.panned(byScreenX: 100, screenY: -50))

        XCTAssertEqual(after.centerXMeters, -1, accuracy: 1e-12)
        XCTAssertEqual(after.centerYMeters, 3.5, accuracy: 1e-12)
        XCTAssertEqual(after.metersPerPoint, before.metersPerPoint, accuracy: 0)
    }

    func testMirroredPanReversesOnlyTheHorizontalCenterOffset() throws {
        let viewport = try MetricCanvasViewport.build(
            centerXMeters: 1.5,
            centerYMeters: 2.25,
            metersPerPoint: 0.02
        )
        let normal = MetricCanvasGeometry(size: CGSize(width: 900, height: 600), viewport: viewport)
        let mirrored = MetricCanvasGeometry(
            size: CGSize(width: 900, height: 600),
            viewport: viewport,
            isHorizontallyMirrored: true
        )

        let normalPanned = try XCTUnwrap(normal.panned(byScreenX: 25, screenY: -10))
        let mirroredPanned = try XCTUnwrap(mirrored.panned(byScreenX: 25, screenY: -10))

        XCTAssertEqual(normalPanned.centerXMeters, 1.0, accuracy: 1e-12)
        XCTAssertEqual(mirroredPanned.centerXMeters, 2.0, accuracy: 1e-12)
        XCTAssertEqual(normalPanned.centerYMeters, 2.05, accuracy: 1e-12)
        XCTAssertEqual(mirroredPanned.centerYMeters, normalPanned.centerYMeters, accuracy: 1e-12)
    }

    func testMirroredPanMovesThePointUnderTheFingerByTheScreenDelta() throws {
        let viewport = try MetricCanvasViewport.build(
            centerXMeters: -0.75,
            centerYMeters: 3.5,
            metersPerPoint: 0.01
        )
        let before = MetricCanvasGeometry(
            size: CGSize(width: 800, height: 600),
            viewport: viewport,
            isHorizontallyMirrored: true
        )
        let point = MetricScanPoint(xMeters: 1.25, yMeters: 4.75)
        let screenBefore = before.screenPoint(for: point)
        let delta = CGPoint(x: 37, y: -22)
        let afterViewport = try XCTUnwrap(before.panned(byScreenX: delta.x, screenY: delta.y))
        let after = MetricCanvasGeometry(
            size: CGSize(width: 800, height: 600),
            viewport: afterViewport,
            isHorizontallyMirrored: true
        )
        let screenAfter = after.screenPoint(for: point)

        XCTAssertEqual(screenAfter.x, screenBefore.x + delta.x, accuracy: 1e-10)
        XCTAssertEqual(screenAfter.y, screenBefore.y + delta.y, accuracy: 1e-10)
        let recovered = try XCTUnwrap(after.metricPoint(forScreenPoint: screenAfter))
        XCTAssertEqual(recovered.xMeters, point.xMeters, accuracy: 1e-12)
        XCTAssertEqual(recovered.yMeters, point.yMeters, accuracy: 1e-12)
    }

    func testBoundedInputStopsAtVisibleCanvas() throws {
        let geometry = MetricCanvasGeometry(
            size: CGSize(width: 200, height: 100),
            viewport: .instrumentDefault
        )
        let outside = try XCTUnwrap(geometry.boundedMetricPoint(forScreenPoint: CGPoint(x: -500, y: 900)))
        let edge = try XCTUnwrap(geometry.metricPoint(forScreenPoint: CGPoint(x: 0, y: 100)))

        XCTAssertEqual(outside.xMeters, edge.xMeters, accuracy: 0)
        XCTAssertEqual(outside.yMeters, edge.yMeters, accuracy: 0)
    }

    func testViewportRejectsInvalidNumbersAndZoom() {
        XCTAssertThrowsError(try MetricCanvasViewport.build(centerXMeters: .nan, centerYMeters: 0, metersPerPoint: 0.01))
        XCTAssertThrowsError(try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 0, metersPerPoint: 0))
        XCTAssertThrowsError(try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 0, metersPerPoint: 0.0001))
        XCTAssertThrowsError(try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 0, metersPerPoint: 1))
        let geometry = MetricCanvasGeometry(
            size: CGSize(width: 1, height: 1),
            viewport: MetricCanvasViewport.instrumentDefault
        )
        XCTAssertNil(geometry.panned(byScreenX: .infinity, screenY: 0))
        XCTAssertNil(MetricCanvasViewport.instrumentDefault.zoomed(
            byFactor: -1,
            anchor: MetricScanPoint(xMeters: 0, yMeters: 0)
        ))
    }
}
