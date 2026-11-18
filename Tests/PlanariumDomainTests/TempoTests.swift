import XCTest
@testable import PlanariumDomain

final class TempoTests: XCTestCase {
    func testTapAveragesLastFourIntervalsAndRestartsAfterPause() {
        var tap = TapTempo()
        XCTAssertNil(tap.tap(at: 0))
        XCTAssertEqual(tap.tap(at: 0.5), 120)
        XCTAssertEqual(tap.tap(at: 1), 120)
        XCTAssertEqual(tap.tap(at: 1.75), 60 / (1.75 / 3))
        XCTAssertEqual(tap.tap(at: 2), 120)
        XCTAssertEqual(tap.tap(at: 3), 60 / (2.5 / 4))
        XCTAssertNil(tap.tap(at: 5.01))
        XCTAssertEqual(tap.tap(at: 6.01), 60)
        XCTAssertNil(tap.tap(at: 6.01))
        XCTAssertEqual(tap.tap(at: 6.11)!, 300)
        XCTAssertNil(tap.tap(at: .nan))
        tap.reset(); XCTAssertNil(tap.tap(at: 7))
    }
    func testTempoLimitsAreFiniteAndInclusive() {
        for bpm in [30.0, 120, 300] { XCTAssertTrue(Tempo.isValid(bpm)) }
        for bpm in [29.9, 300.1, .nan, .infinity, -.infinity] { XCTAssertFalse(Tempo.isValid(bpm)) }
        XCTAssertTrue(InstrumentAction.tempo.allowedInPerformance)
    }
}
