import XCTest
@testable import SickPLSControlCore

/// Bereichsvalidierung (SICK-013-Auftrag): eine ``Zone`` mit ungültigen
/// oder entarteten (nicht ausgedehnten) Bereichen lässt sich nicht
/// erzeugen.
final class ZoneBuildTests: XCTestCase {

    func testBuildSucceedsForValidRanges() throws {
        let zone = try Zone.build(
            indexLowerBound: 0.2,
            indexUpperBound: 0.8,
            valueLowerBound: 100,
            valueUpperBound: 2000,
            role: .pitch
        )

        XCTAssertEqual(zone.indexRange, 0.2...0.8)
        XCTAssertEqual(zone.valueRange, 100...2000)
        XCTAssertEqual(zone.role, .pitch)
    }

    func testBuildSucceedsForTheFullRange() throws {
        _ = try Zone.build(
            indexLowerBound: 0,
            indexUpperBound: 1,
            valueLowerBound: 0,
            valueUpperBound: Zone.maxRawMeasurementValue,
            role: .volume
        )
    }

    func testBuildRejectsIndexLowerBoundBelowZero() {
        XCTAssertThrowsError(try Zone.build(
            indexLowerBound: -0.1,
            indexUpperBound: 0.5,
            valueLowerBound: 0,
            valueUpperBound: 100,
            role: .gate
        )) { error in
            XCTAssertEqual(error as? Zone.BuildError, .indexBoundOutOfRange(-0.1))
        }
    }

    func testBuildRejectsIndexUpperBoundAboveOne() {
        XCTAssertThrowsError(try Zone.build(
            indexLowerBound: 0.5,
            indexUpperBound: 1.1,
            valueLowerBound: 0,
            valueUpperBound: 100,
            role: .gate
        )) { error in
            XCTAssertEqual(error as? Zone.BuildError, .indexBoundOutOfRange(1.1))
        }
    }

    func testBuildRejectsNonIncreasingIndexRange() {
        XCTAssertThrowsError(try Zone.build(
            indexLowerBound: 0.5,
            indexUpperBound: 0.5,
            valueLowerBound: 0,
            valueUpperBound: 100,
            role: .filter
        )) { error in
            XCTAssertEqual(error as? Zone.BuildError, .indexRangeNotIncreasing(lower: 0.5, upper: 0.5))
        }
    }

    func testBuildRejectsValueUpperBoundAboveThirteenBits() {
        let tooLarge = Zone.maxRawMeasurementValue + 1
        XCTAssertThrowsError(try Zone.build(
            indexLowerBound: 0,
            indexUpperBound: 1,
            valueLowerBound: 0,
            valueUpperBound: tooLarge,
            role: .effectSend
        )) { error in
            XCTAssertEqual(error as? Zone.BuildError, .valueBoundOutOfRange(tooLarge))
        }
    }

    func testBuildRejectsNonIncreasingValueRange() {
        XCTAssertThrowsError(try Zone.build(
            indexLowerBound: 0,
            indexUpperBound: 1,
            valueLowerBound: 500,
            valueUpperBound: 500,
            role: .pitch
        )) { error in
            XCTAssertEqual(error as? Zone.BuildError, .valueRangeNotIncreasing(lower: 500, upper: 500))
        }
    }
}
