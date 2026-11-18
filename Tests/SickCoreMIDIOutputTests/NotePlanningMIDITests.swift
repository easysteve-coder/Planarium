import XCTest
@testable import PlanariumMIDI

final class NotePlanningMIDITests: XCTestCase {
    func testDeadlineTimestampUsesHostTimebaseAndRejectsFutureHandoff() {
        XCTAssertEqual(CoreMIDISendBoundary.plannedTimestamp(deadline: 10, now: 10, ticksPerSecond: 24_000_000), 240_000_000)
        XCTAssertEqual(CoreMIDISendBoundary.plannedTimestamp(deadline: 10, now: 10.00001, ticksPerSecond: 24_000_000), 0)
        XCTAssertNil(CoreMIDISendBoundary.plannedTimestamp(deadline: 10.001, now: 10, ticksPerSecond: 24_000_000))
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertNil(CoreMIDISendBoundary.plannedTimestamp(deadline: invalid, now: 10, ticksPerSecond: 24_000_000))
        }
        XCTAssertNil(CoreMIDISendBoundary.plannedTimestamp(deadline: 1, now: .nan, ticksPerSecond: 1))
        XCTAssertNil(CoreMIDISendBoundary.plannedTimestamp(deadline: 1, now: 1, ticksPerSecond: .infinity))
        XCTAssertNil(CoreMIDISendBoundary.plannedTimestamp(deadline: Double.greatestFiniteMagnitude, now: Double.greatestFiniteMagnitude, ticksPerSecond: 24_000_000))
    }
}
