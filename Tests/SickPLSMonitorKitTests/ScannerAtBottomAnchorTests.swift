import XCTest
import CoreGraphics
import SickPLSControlCore
import SickPLSCore
@testable import SickPLSMonitorKit

/// Owner 07.10.2026: Das Messfeld darf nach Größenänderung oder Preset-Laden
/// nicht „nach oben verrutschen“. Der Scannerursprung sitzt an der
/// Unterkante, bis der Nutzer selbst verschiebt, zoomt oder einpasst.
final class ScannerAtBottomAnchorTests: XCTestCase {
    private func scannerScreenY(_ state: MetricCanvasInteractionState, _ size: CGSize) -> Double {
        Double(MetricCanvasGeometry(size: size, viewport: state.viewport).screenPoint(for: .init(xMeters: 0, yMeters: 0)).y)
    }

    func testAnchoredViewportFollowsEveryCanvasHeight() {
        var state = MetricCanvasInteractionState()
        XCTAssertTrue(state.resetViewport(canvasSize: CGSize(width: 900, height: 500)))
        XCTAssertEqual(scannerScreenY(state, CGSize(width: 900, height: 500)), 500, accuracy: 1e-9)
        for height in [1230.0, 870, 300, 1230] {
            let size = CGSize(width: 1190, height: height)
            state.followCanvasSize(size)
            XCTAssertEqual(scannerScreenY(state, size), height, accuracy: 1e-9, "height \(height)")
        }
    }

    func testUserPanZoomAndFitReleaseTheAnchorAndResetRestoresIt() throws {
        let size = CGSize(width: 800, height: 600)
        var state = MetricCanvasInteractionState()
        state.resetViewport(canvasSize: size)
        XCTAssertTrue(state.panViewport(byScreenX: 0, screenY: 40))
        XCTAssertFalse(state.keepsScannerAtBottom)
        let panned = state.viewport
        XCTAssertFalse(state.followCanvasSize(CGSize(width: 800, height: 900)), "A deliberate pan stays where the user put it")
        XCTAssertEqual(state.viewport, panned)

        XCTAssertTrue(state.perform(.resetView, canvasSize: size, profile: nil))
        XCTAssertTrue(state.keepsScannerAtBottom)
        XCTAssertEqual(scannerScreenY(state, size), 600, accuracy: 1e-9)

        XCTAssertTrue(state.zoom(byFactor: 1.4, atScreenPoint: CGPoint(x: 400, y: 300), canvasSize: size))
        XCTAssertFalse(state.keepsScannerAtBottom)

        state.resetViewport(canvasSize: size)
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<90).map { _ in try .build(value: 120, fieldFlags: 0) })
        XCTAssertTrue(state.fitViewport(toMeasurementsOf: profile, canvasSize: size))
        XCTAssertFalse(state.keepsScannerAtBottom)
    }

    func testPresetKeepsItsScaleAndSideButNotItsOldHeight() throws {
        let size = CGSize(width: 1190, height: 1230)
        var state = MetricCanvasInteractionState()
        state.panViewport(byScreenX: 10, screenY: 10)
        // Gespeichert in einem kleineren Fenster: Ursprung läge heute mitten im Feld.
        let saved = try MetricCanvasViewport.build(centerXMeters: 0.3, centerYMeters: 2.5, metersPerPoint: 0.005)
        state.applyPresetViewport(saved, canvasSize: size)
        XCTAssertTrue(state.keepsScannerAtBottom)
        XCTAssertEqual(state.viewport.metersPerPoint, 0.005)
        XCTAssertEqual(state.viewport.centerXMeters, 0.3)
        XCTAssertEqual(scannerScreenY(state, size), 1230, accuracy: 1e-9)

        // Ohne bekannte Größe greift die Verankerung bei der nächsten Größe.
        var later = MetricCanvasInteractionState()
        later.applyPresetViewport(saved)
        XCTAssertEqual(later.viewport, saved)
        later.followCanvasSize(size)
        XCTAssertEqual(scannerScreenY(later, size), 1230, accuracy: 1e-9)
    }
}
