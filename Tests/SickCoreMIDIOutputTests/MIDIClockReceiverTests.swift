import XCTest
import Dispatch
import Foundation
import PlanariumDomain
import PlanariumRuntime
import CoreMIDI
@testable import PlanariumMIDI

final class ReceiverTestClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 10
    private var tasks: [UUID: (Double, DispatchQueue, @Sendable () -> Void)] = [:]
    private var wakes = 0
    var wakeCount: Int { lock.lock(); defer { lock.unlock() }; return wakes }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return tasks.count }
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        let id = UUID(); lock.lock(); tasks[id] = (deadline, queue, action); lock.unlock()
        return .init { [weak self] in self?.cancel(id) }
    }
    private func cancel(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
    func advance(to value: Double) {
        lock.lock(); time = value
        let due = tasks.filter { $0.value.0 <= value }
        due.keys.forEach { tasks[$0] = nil }; wakes += due.count; lock.unlock()
        due.values.forEach { $0.1.async(execute: $0.2) }
    }
}
final class ReceiverTestSource: MIDIClockSource, @unchecked Sendable {
    private let lock = NSLock()
    private var closes = 0
    let receive: @Sendable (MIDIClockPacket) -> Void
    let lost: @Sendable () -> Void
    init(_ receive: @escaping @Sendable (MIDIClockPacket) -> Void, _ lost: @escaping @Sendable () -> Void) {
        self.receive = receive; self.lost = lost
    }
    func close() { lock.lock(); closes += 1; lock.unlock() }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
}
final class ReceiverTestFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    private var bindings: [(Int32, ReceiverTestSource)] = []
    func open(_ id: Int32, _ receive: @escaping @Sendable (MIDIClockPacket) -> Void, _ lost: @escaping @Sendable () -> Void) -> (any MIDIClockSource)? {
        lock.lock(); defer { lock.unlock() }
        guard available else { return nil }
        let value = ReceiverTestSource(receive, lost); bindings.append((id, value)); return value
    }
    func setAvailable(_ value: Bool) { lock.lock(); available = value; lock.unlock() }
    var sources: [(Int32, ReceiverTestSource)] { lock.lock(); defer { lock.unlock() }; return bindings }
}
private final class ReceiverUpdateCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
final class MIDIClockReceiverTests: XCTestCase {
    func testRealPacketListAdapterWalksVariableLengthPacketsAndFiltersOnlyRealtimeClockBytes() throws {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 2048, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(list)
        var bytes = [UInt8](repeating: 0x30, count: 600)
        bytes[0] = 0xfa; bytes[599] = 0xf8
        packet = try XCTUnwrap(bytes.withUnsafeBufferPointer { MIDIPacketListAdd(list, 2048, packet, 24_000_000, $0.count, $0.baseAddress!) })
        bytes = [0x90, 60, 100, 0xfe, 0xfb, 0xfc]
        _ = try XCTUnwrap(bytes.withUnsafeBufferPointer { MIDIPacketListAdd(list, 2048, packet, 0, $0.count, $0.baseAddress!) })
        var received: [MIDIClockPacket] = []
        CoreMIDIClockSource.read(UnsafePointer(list), arrival: 5, secondsPerTick: 1 / 24_000_000) { received.append($0) }
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].bytes, [0xfa, 0xf8]); XCTAssertEqual(received[0].timestamp, 1)
        XCTAssertEqual(received[1].bytes, [0xfb, 0xfc]); XCTAssertEqual(received[1].timestamp, 0)
        XCTAssertEqual(received.map(\.arrival), [5, 5])
    }
    private func tick(_ estimator: inout MIDIClockEstimator, _ time: Double, arrival: Double? = nil) {
        estimator.accept(.init(bytes: [0xf8], timestamp: time, arrival: arrival ?? time))
    }
    private func ack(_ receiver: MIDIClockReceiver) {
        let sem = DispatchSemaphore(value: 0); receiver.acknowledge { sem.signal() }
        XCTAssertEqual(sem.wait(timeout: .now() + 5), .success)
    }
    func testPacketTimeRejectsArrivalJitterAndSingleOutlierAndZeroFallsBackToArrival() {
        var estimator = MIDIClockEstimator()
        for i in 0...96 {
            let time = 10 + Double(i) / 48
            // Deliberately nonlinear callback batching; timestamps stay exact.
            tick(&estimator, time + (i == 44 ? 0.09 : 0), arrival: time + Double(i % 7) * 0.013)
            if i >= 24 { XCTAssertEqual(estimator.state.beatsPerMinute, 120, accuracy: 0.1, "tick \(i)") }
        }
        var fallback = MIDIClockEstimator()
        for i in 0...24 { tick(&fallback, 0, arrival: 10 + Double(i) / 48) }
        XCTAssertEqual(fallback.state.beatsPerMinute, 120, accuracy: 0.1)
    }
    func testTimestampJitterPlusMinusTwoMillisecondsStaysWithinHalfBPM() {
        var estimator = MIDIClockEstimator(), seed: UInt64 = 7
        for i in 0...960 {
            seed = seed &* 6364136223846793005 &+ 1
            let jitter = (Double(seed >> 32) / Double(UInt32.max) * 2 - 1) * 0.002
            tick(&estimator, 10 + Double(i) / 48 + jitter)
            if i >= 24 { XCTAssertEqual(estimator.state.beatsPerMinute, 120, accuracy: 0.5, "tick \(i)") }
        }
    }
    func testRampAndStepReachNewTempoWithinOneQuarter() {
        var estimator = MIDIClockEstimator(), time = 10.0
        for i in 0...480 {
            let bpm = 90 + min(50, Double(i) / 8)
            time += 60 / (bpm * 24); tick(&estimator, time)
            if i > 24 { XCTAssertEqual(estimator.state.beatsPerMinute, bpm, accuracy: 2) }
        }
        for i in 1...24 {
            time += 60 / (90 * 24); tick(&estimator, time)
            if i == 24 { XCTAssertEqual(estimator.state.beatsPerMinute, 90, accuracy: 0.1) }
        }
    }
    func testNonDefaultTemposAreMeasuredAfterOneQuarter() {
        for bpm in [30.0, 75, 140, 300] {
            var estimator = MIDIClockEstimator()
            for i in 0...24 { tick(&estimator, 10 + Double(i) * 60 / (bpm * 24)) }
            XCTAssertEqual(estimator.state.beatsPerMinute, bpm, accuracy: 0.1)
        }
    }
    func testStartStopContinueLossAndRecoveryPreserveMusicalPosition() {
        var estimator = MIDIClockEstimator()
        estimator.accept(.init(bytes: [0xfa, 0x90, 60, 100], timestamp: 10, arrival: 10))
        for i in 0...24 { tick(&estimator, 10 + Double(i) / 48) }
        XCTAssertTrue(estimator.state.isPlaying); XCTAssertEqual(estimator.state.tickCount, 25)
        estimator.accept(.init(bytes: [0xfc, 0xf8], timestamp: 10.6, arrival: 10.6))
        XCTAssertFalse(estimator.state.isPlaying); XCTAssertEqual(estimator.state.tickCount, 25)
        estimator.accept(.init(bytes: [0xfb, 0xf8], timestamp: 10.7, arrival: 10.7))
        XCTAssertTrue(estimator.state.isPlaying); XCTAssertEqual(estimator.state.tickCount, 26)
        estimator.checkLoss(at: 11.7, since: 10)
        XCTAssertFalse(estimator.state.isLost, "strictly more than two quarters")
        estimator.checkLoss(at: 11.71, since: 10)
        XCTAssertTrue(estimator.state.isLost); XCTAssertFalse(estimator.state.isPlaying)
        tick(&estimator, 12)
        XCTAssertFalse(estimator.state.isLost); XCTAssertTrue(estimator.state.isPlaying)
        XCTAssertEqual(estimator.state.tickCount, 27)
        estimator.accept(.init(bytes: [0xfa], timestamp: 12.1, arrival: 12.1))
        XCTAssertEqual(estimator.state.tickCount, 0)
    }
    func testLossTimeoutUsesMeasuredTempoWithHalfSecondMinimumAndKeepsLastTempo() {
        for bpm in [30.0, 120, 300, 400] {
            var estimator = MIDIClockEstimator()
            for i in 0...24 { tick(&estimator, 10 + Double(i) * 60 / (bpm * 24)) }
            let end = 10 + 60 / bpm, timeout = max(0.5, 120 / bpm)
            estimator.checkLoss(at: end + timeout - 0.001, since: 10); XCTAssertFalse(estimator.state.isLost)
            estimator.checkLoss(at: end + timeout + 0.001, since: 10); XCTAssertTrue(estimator.state.isLost)
            XCTAssertEqual(estimator.state.beatsPerMinute, bpm, accuracy: 0.1)
        }
    }
    func testSourceDisappearsReturnsSwitchesSleepsAndRejectsStaleCallbacks() throws {
        let clock = ReceiverTestClock(), factory = ReceiverTestFactory()
        let receiver = MIDIClockReceiver(clock: clock, factory: { factory.open($0, $1, $2) })
        receiver.configure(sourceID: 1); ack(receiver)
        let first = try XCTUnwrap(factory.sources.last?.1)
        first.receive(.init(bytes: [0xfa, 0xf8], timestamp: 10, arrival: 10)); ack(receiver)
        XCTAssertEqual(receiver.snapshot.tickCount, 1)
        factory.setAvailable(false); first.lost(); ack(receiver)
        XCTAssertEqual(first.closeCount, 1); XCTAssertTrue(receiver.snapshot.isLost)
        XCTAssertFalse(receiver.snapshot.isSourceAvailable)
        clock.advance(to: 10.2); ack(receiver); XCTAssertEqual(factory.sources.count, 1)
        factory.setAvailable(true); clock.advance(to: 10.4); receiver.sourcesChanged(); ack(receiver)
        let returned = try XCTUnwrap(factory.sources.last?.1)
        XCTAssertEqual(factory.sources.count, 2)
        XCTAssertTrue(receiver.snapshot.isSourceAvailable)
        returned.receive(.init(bytes: [0xf8], timestamp: 10.4, arrival: 10.4)); ack(receiver)
        XCTAssertTrue(receiver.snapshot.isPlaying); XCTAssertFalse(receiver.snapshot.isLost)
        receiver.configure(sourceID: 2); ack(receiver)
        XCTAssertEqual(returned.closeCount, 1)
        first.receive(.init(bytes: [0xfa, 0xf8], timestamp: 11, arrival: 11)); first.lost(); ack(receiver)
        XCTAssertEqual(receiver.snapshot.tickCount, 0); XCTAssertFalse(receiver.snapshot.isLost)
        let second = try XCTUnwrap(factory.sources.last?.1)
        receiver.suspend(); ack(receiver); XCTAssertEqual(second.closeCount, 1)
        clock.advance(to: 12); ack(receiver); XCTAssertEqual(factory.sources.count, 3)
        receiver.resume(); ack(receiver); XCTAssertEqual(factory.sources.count, 4)
        receiver.configure(sourceID: nil); ack(receiver)
        XCTAssertEqual(factory.sources.last?.1.closeCount, 1)
        receiver.configure(sourceID: 1); ack(receiver)
        let done = DispatchSemaphore(value: 0); receiver.shutdown { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        receiver.resume(); receiver.configure(sourceID: 2); ack(receiver)
        XCTAssertEqual(factory.sources.count, 5); XCTAssertEqual(factory.sources.last?.1.closeCount, 1)
    }
    func testBlockedMainLosesNoTicksAndCoalescesUIUpdates() throws {
        let factory = ReceiverTestFactory(), receiver = MIDIClockReceiver(factory: { factory.open($0, $1, $2) })
        let updates = ReceiverUpdateCount()
        receiver.setUpdateHandler { _ in updates.increment() }
        receiver.configure(sourceID: 1); ack(receiver)
        let source = try XCTUnwrap(factory.sources.last?.1)
        let sent = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            source.receive(.init(bytes: [0xfa], timestamp: 10, arrival: 10))
            for i in 0..<96 { source.receive(.init(bytes: [0xf8], timestamp: 10 + Double(i) / 48, arrival: 10 + Double(i) / 48 + Double(i % 5) * 0.01)) }
            receiver.acknowledge { sent.signal() }
        }
        // This test is executed on Main by XCTest: no RunLoop pumping.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(updates.value, 0)
        XCTAssertEqual(sent.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(receiver.snapshot.tickCount, 96)
        XCTAssertEqual(receiver.snapshot.beatsPerMinute, 120, accuracy: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(updates.value, 1, "All pending publications collapse to one current snapshot")
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        XCTAssertLessThanOrEqual(updates.value, 4, "UI updates run at 10 Hz, not the tick rate")
        receiver.shutdown {}
    }
}

extension MIDIClockReceiverTests {
    func testDeinitDropsPreparedDisplayWithoutExplicitShutdown() {
        let factory = ReceiverTestFactory(), updates = ReceiverUpdateCount(), clock = ReceiverTestClock()
        var receiver: MIDIClockReceiver? = MIDIClockReceiver(clock: clock, factory: { factory.open($0, $1, $2) })
        let retired = { [weak receiver] in receiver }
        receiver?.setUpdateHandler { _ in updates.increment() }
        receiver?.configure(sourceID: 1)
        ack(receiver!) // Main has not consumed the prepared notification.
        XCTAssertEqual(updates.value, 0)
        receiver = nil
        XCTAssertNil(retired(), "The queued display must not retain its receiver")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(updates.value, 0, "No callback outlives receiver retirement")
        XCTAssertEqual(factory.sources.first?.1.closeCount, 1)
    }

    func testPreparedDisplayDeliversWhileReceiverQueueIsBlockedAndShutdownDropsPendingValue() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let opens = ReceiverUpdateCount(), deliveries = ReceiverUpdateCount(), released = ReceiverUpdateCount()
        let receiver = MIDIClockReceiver(factory: { _, receive, lost in
            opens.increment()
            if opens.value == 2 { entered.signal(); release.wait() }
            return ReceiverTestSource(receive, lost)
        })
        receiver.setUpdateHandler { snapshot in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(snapshot.isSourceAvailable)
            XCTAssertEqual(released.value, 0, "Display delivery must not wait behind Q")
            deliveries.increment()
        }
        receiver.configure(sourceID: 1); ack(receiver) // prepared notification, Main has not run
        receiver.configure(sourceID: 2) // occupy Q after preparing the first value
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        // Bound a regression's q.sync wait; the assertion above then turns red.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            released.increment(); release.signal()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(deliveries.value, 1)
        XCTAssertEqual(released.value, 0)
        // Retire on Q after the gate opens, then drain Main: no stale update.
        let stopped = DispatchSemaphore(value: 0)
        receiver.shutdown { stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(deliveries.value, 1)
    }

    func testSilentSourceStopsEveryWakeAfterLossAndFirstNewTickRearmsDetection() throws {
        let clock = ReceiverTestClock(), factory = ReceiverTestFactory()
        let receiver = MIDIClockReceiver(clock: clock, factory: { factory.open($0, $1, $2) })
        defer { receiver.shutdown {} }
        receiver.configure(sourceID: 1); ack(receiver)
        XCTAssertEqual(clock.pendingCount, 1)
        for i in 1...20 { clock.advance(to: 10 + Double(i) * 0.11); ack(receiver) }
        XCTAssertTrue(receiver.snapshot.isLost)
        XCTAssertEqual(clock.pendingCount, 0)
        let settled = clock.wakeCount
        for i in 1...100 { clock.advance(to: 13 + Double(i)); ack(receiver) }
        XCTAssertEqual(clock.wakeCount, settled, "A selected silent source has zero permanent polling")
        let source = try XCTUnwrap(factory.sources.last?.1)
        source.receive(.init(bytes: [0xfa, 0xf8], timestamp: 113, arrival: 113)); ack(receiver)
        XCTAssertFalse(receiver.snapshot.isLost); XCTAssertTrue(receiver.snapshot.isPlaying)
        XCTAssertEqual(clock.pendingCount, 1, "Receipt, not a timer, wakes the stopped receiver")
        clock.advance(to: 114.2); ack(receiver)
        XCTAssertTrue(receiver.snapshot.isLost); XCTAssertEqual(clock.pendingCount, 0)
        receiver.disconnect(); ack(receiver)
        source.receive(.init(bytes: [0xf8], timestamp: 115, arrival: 115)); ack(receiver)
        XCTAssertEqual(clock.pendingCount, 0, "Retired callbacks cannot rearm")
    }
    func testStartAndContinueAfterLossWithoutTicksStopHostAgainAndReturnToZeroWakes() throws {
        let clock = ReceiverTestClock(), factory = ReceiverTestFactory(), host = HostMusicalClock()
        host.configure(.receive, documentTempo: 120, at: clock.now)
        let receiver = MIDIClockReceiver(clock: clock, factory: { factory.open($0, $1, $2) }, hostClock: host)
        defer { receiver.shutdown {} }
        receiver.configure(sourceID: 1); ack(receiver)
        clock.advance(to: 12); ack(receiver)
        XCTAssertTrue(receiver.snapshot.isLost); XCTAssertEqual(clock.pendingCount, 0)
        let source = try XCTUnwrap(factory.sources.last?.1)
        for byte: UInt8 in [0xfa, 0xfb] {
            source.receive(.init(bytes: [byte], timestamp: clock.now, arrival: clock.now)); ack(receiver)
            XCTAssertEqual(host.snapshot.moving, 1, "Transport receipt still reaches musical host time immediately on Q")
            XCTAssertEqual(clock.pendingCount, 1, "Transport after loss needs one loss check even before any F8")
            clock.advance(to: clock.now + 0.2); ack(receiver)
            XCTAssertEqual(host.snapshot.moving, 0, "Missing ticks must stop the host again, independently of Main")
            XCTAssertFalse(receiver.snapshot.isPlaying); XCTAssertTrue(receiver.snapshot.isLost)
            XCTAssertEqual(clock.pendingCount, 0)
            let wakes = clock.wakeCount
            clock.advance(to: clock.now + 10); ack(receiver)
            XCTAssertEqual(clock.wakeCount, wakes)
        }
    }
    func testTransportWithoutTicksAfterWakeAndEndpointReturnUsesOriginalLossDeadline() throws {
        for wake in [false, true] {
            for byte: UInt8 in [0xfa, 0xfb] {
                let clock = ReceiverTestClock(), factory = ReceiverTestFactory(), host = HostMusicalClock()
                host.configure(.receive, documentTempo: 120, at: clock.now)
                let receiver = MIDIClockReceiver(clock: clock, factory: { factory.open($0, $1, $2) }, hostClock: host)
                defer { receiver.shutdown {} }
                receiver.configure(sourceID: 1); ack(receiver)
                clock.advance(to: 12); ack(receiver)
                XCTAssertTrue(receiver.snapshot.isLost)
                if wake {
                    receiver.suspend(); ack(receiver); receiver.resume(); ack(receiver)
                } else {
                    factory.setAvailable(false); try XCTUnwrap(factory.sources.last?.1).lost(); ack(receiver)
                    factory.setAvailable(true); receiver.sourcesChanged(); ack(receiver)
                }
                let source = try XCTUnwrap(factory.sources.last?.1)
                source.receive(.init(bytes: [byte], timestamp: clock.now, arrival: clock.now)); ack(receiver)
                XCTAssertEqual(host.snapshot.moving, 1)
                clock.advance(to: 12.2); ack(receiver)
                XCTAssertEqual(host.snapshot.moving, wake ? 1 : 0,
                               "Wake restarts the selection grace; endpoint return keeps the original expired deadline")
                XCTAssertEqual(clock.pendingCount, wake ? 1 : 0,
                               "A still-lost but moving host needs checks until the fresh wake deadline expires")
                clock.advance(to: 13.2); ack(receiver)
                XCTAssertEqual(host.snapshot.moving, 0); XCTAssertFalse(receiver.snapshot.isPlaying)
                XCTAssertEqual(clock.pendingCount, 0)
                let wakes = clock.wakeCount
                clock.advance(to: 100); ack(receiver); XCTAssertEqual(clock.wakeCount, wakes)
            }
        }
    }
    func testSourceReturnBeforeQueuedRemovalAlsoReconnectsWithoutPolling() throws {
        let clock = ReceiverTestClock(), factory = ReceiverTestFactory(), events = ReceiverSourceEvents()
        let receiver = MIDIClockReceiver(clock: clock, factory: { factory.open($0, $1, $2) },
                                         sourceChanges: { events.observe($0) })
        defer { receiver.shutdown {} }
        receiver.configure(sourceID: 1); ack(receiver)
        let first = try XCTUnwrap(factory.sources.last?.1)
        events.fire(); ack(receiver) // add was delivered while old port still existed
        XCTAssertEqual(factory.sources.count, 1)
        first.lost(); ack(receiver) // by now the same ID already exists again
        XCTAssertEqual(factory.sources.count, 2)
        XCTAssertTrue(receiver.snapshot.isSourceAvailable); XCTAssertTrue(receiver.snapshot.isLost)
        XCTAssertEqual(clock.pendingCount, 0)
        let current = try XCTUnwrap(factory.sources.last?.1)
        current.receive(.init(bytes: [0xfa, 0xf8], timestamp: 10, arrival: 10)); ack(receiver)
        XCTAssertEqual(receiver.snapshot.tickCount, 1); XCTAssertEqual(clock.pendingCount, 1)
        first.lost(); events.fireIncludingRetired(); ack(receiver)
        XCTAssertEqual(factory.sources.count, 2, "Late endpoint/removal callbacks cannot retire the new port")
    }
    func testAbsentSourceUsesEndpointEventsWithoutPollingAndCancelsAcrossSleepAndShutdown() {
        let clock = ReceiverTestClock(), factory = ReceiverTestFactory(), events = ReceiverSourceEvents()
        factory.setAvailable(false)
        let receiver = MIDIClockReceiver(clock: clock, factory: { factory.open($0, $1, $2) },
                                         sourceChanges: { events.observe($0) })
        receiver.configure(sourceID: 1); ack(receiver)
        XCTAssertEqual(events.activeCount, 1); XCTAssertEqual(clock.pendingCount, 0)
        for i in 1...100 { clock.advance(to: 10 + Double(i)); ack(receiver) }
        XCTAssertEqual(clock.wakeCount, 0); XCTAssertTrue(receiver.snapshot.isLost)
        factory.setAvailable(true); events.fire(); ack(receiver)
        XCTAssertEqual(factory.sources.count, 1); XCTAssertTrue(receiver.snapshot.isSourceAvailable)
        receiver.suspend(); ack(receiver)
        XCTAssertEqual(events.activeCount, 0); events.fireIncludingRetired(); ack(receiver)
        XCTAssertEqual(factory.sources.count, 1)
        receiver.resume(); ack(receiver)
        XCTAssertEqual(events.activeCount, 1); XCTAssertEqual(factory.sources.count, 2)
        let done = DispatchSemaphore(value: 0); receiver.shutdown { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(events.activeCount, 0)
        events.fireIncludingRetired(); receiver.resume(); ack(receiver)
        XCTAssertEqual(factory.sources.count, 2); XCTAssertEqual(clock.pendingCount, 0)
    }
}
private final class ReceiverSourceEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private var retired: [@Sendable () -> Void] = []
    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return callbacks.count }
    func observe(_ changed: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        let id = UUID(); lock.lock(); callbacks[id] = changed; lock.unlock()
        return .init { [self] in
            lock.lock(); if let old = callbacks.removeValue(forKey: id) { retired.append(old) }; lock.unlock()
        }
    }
    func fire() { lock.lock(); let values = Array(callbacks.values); lock.unlock(); values.forEach { $0() } }
    func fireIncludingRetired() { lock.lock(); let values = retired; lock.unlock(); values.forEach { $0() } }
}
