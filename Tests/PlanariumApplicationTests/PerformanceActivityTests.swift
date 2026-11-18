import Foundation
import XCTest
@testable import PlanariumApplication

@MainActor final class PerformanceActivityTests: XCTestCase {
    func testAudioScannerDuplicateEventsAndTerminationOwnExactlyOneActivity() {
        let boundary = ActivityFake(), activity = PerformanceActivity(boundary: boundary)
        activity.update(audio: false, scanner: false); XCTAssertEqual(boundary.begins, 0)
        activity.update(audio: true, scanner: false)
        activity.update(audio: true, scanner: false)
        activity.update(audio: true, scanner: true); XCTAssertEqual(boundary.begins, 1)
        activity.update(audio: false, scanner: true); XCTAssertEqual(boundary.ends, 0)
        activity.update(audio: false, scanner: false); XCTAssertEqual(boundary.ends, 1)
        activity.update(audio: false, scanner: true); XCTAssertEqual(boundary.begins, 2)
        activity.terminate(); activity.terminate(); XCTAssertEqual(boundary.ends, 2)
        activity.update(audio: true, scanner: true); XCTAssertEqual(boundary.begins, 2)
    }
}
@MainActor private final class ActivityFake: PerformanceActivityBoundary {
    var begins = 0, ends = 0
    private var active: NSObjectProtocol?
    func begin() -> NSObjectProtocol { begins += 1; let token = NSObject(); active = token; return token }
    func end(_ token: NSObjectProtocol) { XCTAssertTrue(active === token); active = nil; ends += 1 }
}
