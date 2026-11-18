import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class SpatialStaleWatchTests: XCTestCase {
    func testDefaultUsesStaleWatchConfigurationBoundary() {
        XCTAssertEqual(
            SpatialStaleWatch().staleTimeoutSeconds,
            0.35
        )
    }

    func testBoundaryIsInclusiveAndFiresExactlyOnce() {
        var watch = SpatialStaleWatch(staleTimeoutSeconds: 0.35)
        watch.noteProfile(at: 10.0)

        XCTAssertFalse(watch.check(at: 10.35))
        XCTAssertTrue(watch.check(at: 10.350_001))
        XCTAssertFalse(watch.check(at: 11.0))
    }

    func testProfileAfterStaleStartsFreshEntry() {
        var watch = SpatialStaleWatch(staleTimeoutSeconds: 0.35)
        watch.noteProfile(at: 0)

        XCTAssertTrue(watch.check(at: 0.36))
        watch.noteProfile(at: 0.40)
        XCTAssertFalse(watch.check(at: 0.75))
        XCTAssertTrue(watch.check(at: 0.751))
    }

    func testRegularFortyMillisecondProfilesNeverBecomeStale() {
        var watch = SpatialStaleWatch(staleTimeoutSeconds: 0.35)

        for index in 0...250 {
            let time = Double(index) * 0.04
            watch.noteProfile(at: time)
            XCTAssertFalse(watch.check(at: time + 0.039))
        }
    }

    func testResetRemovesOldProfileHistory() {
        var watch = SpatialStaleWatch(staleTimeoutSeconds: 0.35)
        watch.noteProfile(at: 1.0)
        watch.reset()

        XCTAssertFalse(watch.check(at: 10.0))
        watch.noteProfile(at: 10.0)
        XCTAssertTrue(watch.check(at: 10.36))
    }
}
