import XCTest
@testable import SickPLSMonitorKit

final class PanDisplayTests: XCTestCase {
    func testLabelShowsCenterAndPercentPerSide() {
        XCTAssertEqual(PanDisplay.label(0), "C")
        XCTAssertEqual(PanDisplay.label(0.004), "C")
        XCTAssertEqual(PanDisplay.label(-0.37), "L37")
        XCTAssertEqual(PanDisplay.label(0.5), "R50")
        XCTAssertEqual(PanDisplay.label(-3), "L100")
    }

    func testDragUpTurnsRightAndClampsAtBothEnds() {
        XCTAssertEqual(PanDisplay.dragged(startPan: 0, translationY: -30), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PanDisplay.dragged(startPan: 0, translationY: 30), -0.5, accuracy: 1e-9)
        XCTAssertEqual(PanDisplay.dragged(startPan: 0.9, translationY: -200), 1)
        XCTAssertEqual(PanDisplay.dragged(startPan: -0.9, translationY: 200), -1)
        XCTAssertEqual(PanDisplay.dragged(startPan: 0.2, translationY: .nan), 0.2)
    }

    func testIndicatorAngleSpansTwoHundredSeventyDegrees() {
        XCTAssertEqual(PanDisplay.indicatorAngle(-1), -135)
        XCTAssertEqual(PanDisplay.indicatorAngle(0), 0)
        XCTAssertEqual(PanDisplay.indicatorAngle(1), 135)
    }
}
