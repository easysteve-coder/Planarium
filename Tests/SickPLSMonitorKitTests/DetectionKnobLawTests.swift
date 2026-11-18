import XCTest
import PlanariumDomain
@testable import SickPLSMonitorKit

final class DetectionKnobLawTests: XCTestCase {
    func testDragStepsUpIncreaseAndClampToRange() {
        XCTAssertEqual(DetectionKnobLaw.index(start: 3, translationY: 0, count: 7), 3)
        XCTAssertEqual(DetectionKnobLaw.index(start: 3, translationY: -5.9, count: 7), 3, "Less than one step does not move")
        XCTAssertEqual(DetectionKnobLaw.index(start: 3, translationY: -6, count: 7), 4)
        XCTAssertEqual(DetectionKnobLaw.index(start: 3, translationY: 12, count: 7), 1)
        XCTAssertEqual(DetectionKnobLaw.index(start: 3, translationY: -600, count: 7), 6)
        XCTAssertEqual(DetectionKnobLaw.index(start: 3, translationY: 600, count: 7), 0)
        XCTAssertEqual(DetectionKnobLaw.index(start: 3, translationY: .nan, count: 7), 3)
        XCTAssertEqual(DetectionKnobLaw.index(start: 0, translationY: -60, count: 0), 0)
    }

    func testStoredOffGridValueMapsToNearestDetentWithoutRewriting() {
        let angles = Array(stride(from: 0, through: 90, by: 5))
        XCTAssertEqual(angles[DetectionKnobLaw.nearestIndex(of: 20, in: angles)], 20)
        XCTAssertEqual(angles[DetectionKnobLaw.nearestIndex(of: 17, in: angles)], 15)
        XCTAssertEqual(angles[DetectionKnobLaw.nearestIndex(of: 18, in: angles)], 20)
        XCTAssertEqual(angles[DetectionKnobLaw.nearestIndex(of: 999, in: angles)], 90)
        XCTAssertEqual(DetectionKnobLaw.angle(index: 0, count: 4), -135)
        XCTAssertEqual(DetectionKnobLaw.angle(index: 3, count: 4), 135)
    }

    func testSmoothingSwitchReadsEveryStoredState() {
        var configuration = DetectionConfiguration(temporalSmoothing: .off)
        XCTAssertEqual(SmoothingSwitchPosition(configuration), .off)
        configuration.temporalSmoothing = .median(window: 6)
        XCTAssertEqual(SmoothingSwitchPosition(configuration), .median)
        configuration.smoothingEnabled = false
        XCTAssertEqual(SmoothingSwitchPosition(configuration), .off, "Disabled shows OFF whatever is stored")
        configuration.smoothingEnabled = true; configuration.temporalSmoothing = .exponential(alpha: 0.3)
        XCTAssertEqual(SmoothingSwitchPosition(configuration), .exponential)
        configuration.temporalSmoothing = .mean(window: 3)
        XCTAssertEqual(SmoothingSwitchPosition(configuration), .mean)
        XCTAssertEqual(SmoothingSwitchPosition.allCases.map(\.label), ["OFF", "MEAN", "MEDIAN", "EXP"])
    }

    func testSwitchingOffKeepsWindowAndTurningBackRestoresIt() {
        let median6 = DetectionConfiguration(temporalSmoothing: .median(window: 6))
        let off = SmoothingSwitchPosition.off.applied(to: median6)
        XCTAssertFalse(off.smoothingEnabled)
        XCTAssertEqual(off.effective.temporalSmoothing, .off, "OFF really removes smoothing from detection")
        XCTAssertEqual(off.temporalSmoothing, .median(window: 6))
        let back = SmoothingSwitchPosition.median.applied(to: off)
        XCTAssertTrue(back.smoothingEnabled)
        XCTAssertEqual(back.temporalSmoothing, .median(window: 6))
        XCTAssertEqual(SmoothingSwitchPosition.mean.applied(to: back).temporalSmoothing, .mean(window: 6))
    }

    func testExponentialKeepsStoredAlphaAndOthersStartFromDefaults() {
        let exp = DetectionConfiguration(temporalSmoothing: .exponential(alpha: 0.3))
        XCTAssertEqual(SmoothingSwitchPosition.exponential.applied(to: exp).temporalSmoothing, .exponential(alpha: 0.3))
        XCTAssertEqual(SmoothingSwitchPosition.mean.applied(to: exp).temporalSmoothing, .mean(window: 4))
        let none = DetectionConfiguration(temporalSmoothing: .off)
        XCTAssertEqual(SmoothingSwitchPosition.exponential.applied(to: none).temporalSmoothing, .exponential(alpha: 0.5))
        XCTAssertEqual(SmoothingSwitchPosition.median.applied(to: none).temporalSmoothing, .median(window: 4))
        for position in SmoothingSwitchPosition.allCases {
            XCTAssertEqual(SmoothingSwitchPosition(position.applied(to: none)), position, "Every position is reached by a real transition")
        }
    }
}
