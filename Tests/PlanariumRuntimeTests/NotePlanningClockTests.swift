import Dispatch
import Foundation
import XCTest
@testable import PlanariumRuntime

private final class DeadlineMeasurement: @unchecked Sendable {
    let clock: any RuntimeClock
    let queue = DispatchQueue(label: "note-deadline-measurement")
    let done: XCTestExpectation
    var samples: [Double] = [] // queue-owned, read after completion
    var token: RuntimeCancellation?
    var deadline: Double
    init(clock: any RuntimeClock, done: XCTestExpectation) {
        self.clock = clock; self.done = done; deadline = clock.now + 0.01
        samples.reserveCapacity(200)
    }
    func next() {
        token = clock.schedule(at: deadline, on: queue) { [self] in
            samples.append((clock.now - deadline) * 1_000_000)
            if samples.count == 200 { done.fulfill() }
            else { deadline += 0.005; next() }
        }
    }
}
final class NotePlanningClockTests: XCTestCase {
    func testEmptyClockStaysBlockedAndSingleDeadlineWakesOnce() {
        let clock = NotePlanningClock(), q = DispatchQueue(label: "idle-clock")
        let done = expectation(description: "single deadline")
        let token = clock.schedule(at: clock.now + 0.2, on: q) { done.fulfill() }
        wait(for: [done], timeout: 3)
        let count = clock.wakeCount
        XCTAssertEqual(count, 1)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(clock.wakeCount, count, "empty timer must not poll")
        withExtendedLifetime(token) {}
    }
    func testEarlierDeadlineInterruptsWaitAndBlockedQDoesNotBlockTimer() {
        let clock = NotePlanningClock(), blocked = DispatchQueue(label: "blocked-clock-Q")
        let gate = DispatchSemaphore(value: 0)
        blocked.async { gate.wait() }
        defer { gate.signal() }
        let done = expectation(description: "later deadline passes blocked Q")
        let late = clock.schedule(at: clock.now + 0.3, on: DispatchQueue(label: "free-clock-Q")) { done.fulfill() }
        Thread.sleep(forTimeInterval: 0.03)
        let early = clock.schedule(at: clock.now + 0.05, on: blocked) {}
        wait(for: [done], timeout: 2)
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(clock.wakeCount, 3, "one interruption and two deadlines, including while Q is blocked")
        let count = clock.wakeCount
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(clock.wakeCount, count)
        withExtendedLifetime((early, late)) {}
    }
    func testFullTableRejectsWithoutCrashAndCancellationRestoresCapacity() {
        let clock = NotePlanningClock(), q = DispatchQueue(label: "full-clock")
        var tokens: [RuntimeCancellation] = []
        for _ in 0..<16 {
            let token = clock.trySchedule(at: clock.now + 60, on: q) { XCTFail("cancelled job fired") }
            XCTAssertNotNil(token)
            if let token { tokens.append(token) }
        }
        XCTAssertNil(clock.trySchedule(at: clock.now + 60, on: q) {})
        tokens.removeLast().cancel()
        let done = expectation(description: "capacity restored")
        let replacement = clock.trySchedule(at: clock.now + 0.02, on: q) { done.fulfill() }
        XCTAssertNotNil(replacement)
        wait(for: [done], timeout: 2)
        tokens.forEach { $0.cancel() }
    }
    func testDedicatedDeadlineThreadDeliversTwoHundredCallbacksWithoutProfiles() {
        let done = expectation(description: "200 deadline wakes")
        let measurement = DeadlineMeasurement(clock: NotePlanningClock(), done: done)
        measurement.queue.sync { measurement.next() }
        wait(for: [done], timeout: 10)
        measurement.queue.sync {
            let samples = measurement.samples.sorted()
            XCTAssertEqual(samples.count, 200)
            XCTAssertEqual((measurement.clock as? NotePlanningClock)?.sourceCreationCount, 1)
            guard samples.count == 200 else { return }
            print("NOTE-DEADLINE-POLICY result=\((measurement.clock as? NotePlanningClock)?.policyResult as Any)")
            print("NOTE-DEADLINE-JITTER us median=\(samples[100]) p99=\(samples[197]) max=\(samples[199])")
            XCTAssertGreaterThanOrEqual(samples[0], 0)
            measurement.token?.cancel(); measurement.token = nil
        }
    }
}
