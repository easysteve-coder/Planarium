import Combine
import XCTest
import PlanariumDomain
import PlanariumRuntime
import PlanariumInput
@testable import PlanariumApplication

@MainActor final class PerformancePumpTests: XCTestCase {
    private func turn() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    private func frame(_ sequence: UInt64) -> DisplayFrame {
        .init(selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]), processedProfiles: sequence)
    }
    func testMixerDoesNotEnableTablesAndDiagnosticMonitorStillDoes() {
        let mailbox = DisplayFrameMailbox(), runtime = PerformanceRuntime(clock: PumpClock(), mailbox: DisplayFrameMailbox())
        let model = PerformanceDisplayModel(mailbox: mailbox, runtime: runtime)
        runtime.attach(.init(destination: .midi) { _ in .sent })
        func ack() {
            let done = expectation(description: "Monitor visibility acknowledged")
            runtime.acknowledge { done.fulfill() }; wait(for: [done], timeout: 5)
        }
        ack()
        model.setMixerMonitorVisible(true); ack()
        XCTAssertTrue(runtime.mailbox.read()?.outputMonitor.isEmpty == true)
        model.setOutputMonitorVisible(true); ack()
        XCTAssertEqual(runtime.mailbox.read()?.outputMonitor.count, 1)
        model.setOutputMonitorVisible(false); ack()
        XCTAssertTrue(runtime.mailbox.read()?.outputMonitor.isEmpty == true)
        model.setMixerMonitorVisible(false)
    }

    func testMixerOnlyVisibilityPumpsWithoutOutputMonitorTablesInBothOrders() throws {
        for hideFirst in [false, true] {
            let mailbox = DisplayFrameMailbox(), runtime = PerformanceRuntime(clock: PumpClock(), mailbox: DisplayFrameMailbox())
            let model = PerformanceDisplayModel(mailbox: mailbox, runtime: runtime)
            model.setMixerMonitorVisible(true); mailbox.write(frame(1)); turn()
            XCTAssertEqual(model.deliveryCount, 1)
            if hideFirst { model.setVisible(false) }
            mailbox.write(frame(2))
            if !hideFirst { model.setVisible(false) }
            turn(); XCTAssertEqual(model.deliveryCount, 1)
            model.setVisible(true); turn()
            XCTAssertEqual(model.frame?.processedProfiles, 2)
            model.setMixerMonitorVisible(false); mailbox.write(frame(3)); turn()
            XCTAssertEqual(model.frame?.processedProfiles, 2)
            model.setMixerMonitorVisible(true); turn()
            XCTAssertEqual(model.frame?.processedProfiles, 3)
            model.setMixerMonitorVisible(false)
        }
    }

    func testOneDeliveryPerWriteCoalescesBacklogAndHasNoIdleClock() throws {
        let mailbox = DisplayFrameMailbox(), clock = PumpClock()
        let runtime = PerformanceRuntime(clock: clock, mailbox: mailbox)
        // Empty source has no timer and schedules no work, even as a fake clock
        // moves through ten seconds. A returned polling timer fails this count.
        let empty = PerformanceDisplayModel(mailbox: mailbox, runtime: runtime)
        empty.start()
        for time in 0...10 { clock.time = Double(time); turn() }
        XCTAssertEqual(empty.pumpPassCount, 0); XCTAssertEqual(empty.deliveryCount, 0); XCTAssertEqual(clock.schedules, 0)
        for n: UInt64 in 1...50 {
            mailbox.write(frame(n)); turn()
            XCTAssertEqual(empty.deliveryCount, Int(n)); XCTAssertEqual(empty.pumpPassCount, Int(n))
        }
        for n: UInt64 in 51...100 { mailbox.write(frame(n)) }
        turn()
        XCTAssertEqual(empty.deliveryCount, 51); XCTAssertEqual(empty.pumpPassCount, 51)
        XCTAssertEqual(empty.frame?.processedProfiles, 100)
        for _ in 0..<10 { turn() }
        XCTAssertEqual(empty.deliveryCount, 51); XCTAssertEqual(empty.pumpPassCount, 51)
        empty.stop()
        // The same count at the actual R → runtime Q → mailbox → Main path.
        for points in [90, 361] {
            let f = try RootFixture(clock: PumpClock())
            defer { f.root.display.stop(); f.root.terminate {} }
            _ = f.root.input.connectDevelopment(portPath: "/dev/cu.offline", baudRate: .baud500000)
            f.root.display.start()
            for _ in 0..<4 { turn() }
            let baseline = f.root.display.pumpPassCount
            for n: UInt64 in 1...50 {
                f.scanner.descriptors[0].append(.bytes(try f.bytes(pointCount: points)))
                let deadline = Date().addingTimeInterval(5)
                while f.root.runtime.mailbox.read()?.profile?.sequence != n, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                turn()
                XCTAssertEqual(f.root.display.frame?.profile?.sequence, n)
                XCTAssertEqual(f.root.display.pumpPassCount - baseline, Int(n))
            }
        }
    }
    func testHideAndWriteInBothOrdersAndStopIgnoreQueuedSignalWithOneCatchup() {
        for hideFirst in [false, true] {
            let mailbox = DisplayFrameMailbox(), model = PerformanceDisplayModel(mailbox: mailbox)
            model.start(); mailbox.write(frame(1)); turn()
            XCTAssertEqual(model.deliveryCount, 1)
            if hideFirst { model.setVisible(false) }
            mailbox.write(frame(2))
            if !hideFirst { model.setVisible(false) }
            for n: UInt64 in 3...50 { mailbox.write(frame(n)); turn() }
            XCTAssertEqual(model.deliveryCount, 1); XCTAssertEqual(model.pumpPassCount, 1)
            XCTAssertEqual(model.frame?.processedProfiles, 1)
            model.setVisible(true); turn()
            XCTAssertEqual(model.deliveryCount, 2); XCTAssertEqual(model.frame?.processedProfiles, 50)
            mailbox.write(frame(51)); model.stop(); turn()
            XCTAssertEqual(model.deliveryCount, 2)
            model.start(); turn(); XCTAssertEqual(model.deliveryCount, 3)
            model.stop(); model.setVisible(false); mailbox.write(frame(52))
            model.setVisible(true); turn(); XCTAssertEqual(model.deliveryCount, 3)
        }
    }
}
private final class PumpClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    private var count = 0
    var time: Double {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
    var schedules: Int { lock.lock(); defer { lock.unlock() }; return count }
    var now: Double { time }
    func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        lock.lock(); count += 1; lock.unlock(); return .init {}
    }
}
