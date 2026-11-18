import XCTest
@testable import SickPLSSimulationLink

final class AutoSweepPathTests: XCTestCase {
    func testHandsStayInsideThePlayingAreaAndOnTheirOwnSide() {
        for step in 0..<6000 { // 10 min at 10 Hz
            let hands = AutoSweepPath.hands(at: Double(step) / 10)
            XCTAssertEqual(hands.count, 2)
            for hand in hands {
                let r = (hand.center.x * hand.center.x + hand.center.y * hand.center.y).squareRoot()
                XCTAssertGreaterThanOrEqual(r, 29.99); XCTAssertLessThanOrEqual(r, 150.01)
                let angle = atan2(hand.center.x, hand.center.y) * 180 / .pi
                XCTAssertLessThanOrEqual(abs(angle), 40.0001)
                XCTAssertLessThanOrEqual(abs(hand.center.x), 100, "inside the 2 m room width")
            }
            XCTAssertLessThan(hands[0].center.x, 0); XCTAssertGreaterThan(hands[1].center.x, 0)
        }
    }
    func testPathIsReproducibleAndMoves() {
        XCTAssertEqual(AutoSweepPath.hands(at: 12.3), AutoSweepPath.hands(at: 12.3))
        XCTAssertNotEqual(AutoSweepPath.hands(at: 0), AutoSweepPath.hands(at: 1))
        XCTAssertNotEqual(AutoSweepPath.hands(at: 1), AutoSweepPath.hands(at: 2))
    }
}
