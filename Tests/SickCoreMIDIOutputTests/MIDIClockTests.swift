import XCTest
import Foundation
import Dispatch
import PlanariumDomain
import PlanariumRuntime
@testable import PlanariumMIDI

private final class ClockTestTime: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 10
    private var tasks: [UUID: (Double, DispatchQueue, @Sendable () -> Void)] = [:]
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    func schedule(at deadline: Double, on queue: DispatchQueue, _ fire: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        let id = UUID(); lock.lock(); tasks[id] = (deadline, queue, fire); lock.unlock()
        return .init { [weak self] in self?.cancel(id) }
    }
    private func cancel(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
    func advance(to value: Double) {
        lock.lock(); time = value
        let due = tasks.filter { $0.value.0 <= value }
        for id in due.keys { tasks[id] = nil }
        lock.unlock()
        for task in due.values { task.1.async(execute: task.2) }
    }
}
private final class ClockTestSink: MIDIClockSink, @unchecked Sendable {
    struct Event: Equatable { let byte: UInt8; let time: Double; let submitted: Double }
    private let lock = NSLock()
    private let now: @Sendable () -> Double
    private var log: [Event] = []
    private var scheduled: [Event] = []
    private var operations: [String] = []
    private var available = true
    private var disposed = false
    init(now: @escaping @Sendable () -> Double) { self.now = now }
    func send(_ byte: UInt8, at time: Double) -> PortSendResult {
        lock.lock(); defer { lock.unlock() }
        guard available, !disposed else { return .unbound }
        let event = Event(byte: byte, time: time, submitted: now())
        log.append(event); scheduled.append(event); operations.append(String(format: "%02x", byte)); return .sent
    }
    func flush() -> PortSendResult {
        lock.lock(); defer { lock.unlock() }
        operations.append("flush")
        scheduled.removeAll { $0.time > now() }
        return available && !disposed ? .sent : .unbound
    }
    func close() { lock.lock(); disposed = true; operations.append("close"); lock.unlock() }
    func disappear() { lock.lock(); available = false; lock.unlock() }
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return log }
    var retained: [Event] { lock.lock(); defer { lock.unlock() }; return scheduled }
    var order: [String] { lock.lock(); defer { lock.unlock() }; return operations }
}
private final class ClockTestFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Double
    private var endpoints: [Int32: [ClockTestSink]] = [:]
    init(now: @escaping @Sendable () -> Double) { self.now = now }
    func open(_ id: Int32) -> (any MIDIClockSink)? {
        lock.lock(); defer { lock.unlock() }
        let sink = ClockTestSink(now: now); endpoints[id, default: []].append(sink); return sink
    }
    func sinks(_ id: Int32) -> [ClockTestSink] { lock.lock(); defer { lock.unlock() }; return endpoints[id] ?? [] }
}
/// A fake 361-ray scanner feeds the actual performance queue at 25 Hz.
private final class ClockTestScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private let session = UUID()
    private let runtime: PerformanceRuntime
    private let measurements: [DeviceTickMeasurement]
    private let clock: any RuntimeClock
    init(runtime: PerformanceRuntime, clock: any RuntimeClock) throws {
        self.runtime = runtime; self.clock = clock
        measurements = try (0...360).map { index in
            try XCTUnwrap(DeviceTickMeasurement(order: index, ticks: .point(index)!, rawCentimeters: 100))
        }
        let layer = SpatialDocumentLayer(id: UUID(), name: "Scanner load", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        runtime.install(try InstrumentCompiler.compile(.init(spatial: spatial, revision: .newSession())))
        runtime.sessionBegan(session)
    }
    func emit() {
        lock.lock(); sequence += 1; let next = sequence; lock.unlock()
        runtime.frame(.init(sessionID: session, sequence: next, time: clock.now, measurements: measurements))
    }
}
final class MIDIClockTests: XCTestCase {
    func testHostTimestampConversionForTenMinutesAndOverflowIsExact() {
        for index in 1...28_800 {
            let seconds = 10.05 + Double(index) / 48
            XCTAssertEqual(CoreMIDIClockSink.timestamp(for: seconds, ticksPerSecond: 24_000_000), 241_200_000 + UInt64(index) * 500_000)
            XCTAssertEqual(CoreMIDIClockSink.timestamp(for: seconds, ticksPerSecond: 1_000_000_000), UInt64((seconds * 1_000_000_000).rounded()))
        }
        for seconds in [-1.0, .nan, .infinity, Double(UInt64.max)] {
            XCTAssertNil(CoreMIDIClockSink.timestamp(for: seconds, ticksPerSecond: 1_000_000_000))
        }
    }
    private func ack(_ driver: MIDIClockDriver) {
        let done = DispatchSemaphore(value: 0); driver.acknowledge { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }
    func testTenMinutesAt120UseExactOriginAndIntegerIndexAtTwoIndependentTargets() throws {
        let clock = ClockTestTime(), factory = ClockTestFactory(now: { clock.now })
        let driver = MIDIClockDriver(clock: clock, factory: { factory.open($0) })
        driver.configure(enabled: true, targets: [1, 2]); driver.start(); ack(driver)
        let start = try XCTUnwrap(factory.sinks(1).first?.events.first?.time)
        for step in 1...24_004 { clock.advance(to: 10 + Double(step) * 0.025); ack(driver) }
        let first = try XCTUnwrap(factory.sinks(1).first), second = try XCTUnwrap(factory.sinks(2).first)
        let ticks = first.events.filter { $0.byte == 0xf8 && $0.time <= start + 600 }
        XCTAssertEqual(ticks.count, 28_800)
        for (index, tick) in ticks.enumerated() {
            XCTAssertEqual(tick.time, start + Double(index + 1) * (60 / (120 * 24)))
            XCTAssertGreaterThan(tick.time, tick.submitted)
        }
        XCTAssertEqual(first.events, second.events)
        driver.stop(); ack(driver)
        XCTAssertEqual(Array(first.order.suffix(3)), ["flush", "fc", "close"])
        XCTAssertFalse(first.retained.contains { $0.byte == 0xf8 && $0.time > clock.now })
    }
    func testTenMinutesWithTempoChangesAndIrregularPlanningHaveZeroGridDrift() throws {
        let clock = ClockTestTime(), factory = ClockTestFactory(now: { clock.now })
        let driver = MIDIClockDriver(clock: clock, factory: { factory.open($0) })
        driver.configure(enabled: true, targets: [1]); driver.start(); ack(driver)
        let sink = try XCTUnwrap(factory.sinks(1).first)
        var segmentOrigin = 10.05, segmentInterval = 60.0 / (120 * 24)
        var nextIndex = 1
        var expected: [Double] = []
        let tempos = [30.0, 300, 89.5, 137, 120]
        var currentBPM = 120.0
        for step in 1...12_000 {
            let time = 10 + Double(step) * 0.05
            // 50-ms planner jitter stays within the 100-ms look-ahead.
            while segmentOrigin + Double(nextIndex) * segmentInterval <= time {
                expected.append(segmentOrigin + Double(nextIndex) * segmentInterval); nextIndex += 1
            }
            clock.advance(to: time); ack(driver)
            if step % 1200 == 0 {
                let bpm = tempos[(step / 1200 - 1) % tempos.count]
                if bpm != currentBPM {
                    segmentOrigin += Double(nextIndex) * segmentInterval
                    segmentInterval = 60 / (bpm * 24); nextIndex = 0
                }
                currentBPM = bpm
                driver.setTempo(bpm); ack(driver)
            }
        }
        driver.stop(); ack(driver)
        let delivered = sink.retained.filter { $0.byte == 0xf8 }.map(\.time)
        XCTAssertEqual(delivered, expected)
        XCTAssertEqual(sink.events.filter { $0.byte == 0xfa }.count, 1)
        XCTAssertEqual(sink.events.filter { $0.byte == 0xfc }.count, 1)
    }
    func testRapidTempoChangesBeforeStartPreserveStartAndFirstTick() throws {
        let clock = ClockTestTime(), factory = ClockTestFactory(now: { clock.now })
        let driver = MIDIClockDriver(clock: clock, factory: { factory.open($0) })
        driver.configure(enabled: true, targets: [1]); driver.start(); driver.setTempo(60); driver.setTempo(180); ack(driver)
        let pending = try XCTUnwrap(factory.sinks(1).first).retained
        XCTAssertEqual(pending.filter { $0.byte == 0xfa }.map(\.time), [10.05])
        XCTAssertEqual(pending.first { $0.byte == 0xf8 }?.time, 10.05 + 60 / (120 * 24))
        driver.stop(); ack(driver)
    }
    func testOffDeselectLostReturnAndShutdownNeverJoinMidTransport() throws {
        let clock = ClockTestTime(), factory = ClockTestFactory(now: { clock.now })
        let driver = MIDIClockDriver(clock: clock, factory: { factory.open($0) })
        driver.configure(enabled: false, targets: [1]); driver.start(); ack(driver)
        XCTAssertTrue(factory.sinks(1).isEmpty)
        driver.configure(enabled: true, targets: [1]); ack(driver)
        XCTAssertTrue(factory.sinks(1).isEmpty)
        driver.stop(); driver.start(); ack(driver)
        let one = try XCTUnwrap(factory.sinks(1).first)
        driver.configure(enabled: true, targets: [2]); ack(driver)
        XCTAssertEqual(Array(one.order.suffix(3)), ["flush", "fc", "close"])
        XCTAssertTrue(factory.sinks(2).isEmpty)
        driver.stop(); driver.start(); ack(driver)
        let two = try XCTUnwrap(factory.sinks(2).first)
        two.disappear(); clock.advance(to: 10.025); ack(driver)
        XCTAssertEqual(two.order.last, "close")
        for step in 2...10 { clock.advance(to: 10 + Double(step) * 0.025); ack(driver) }
        XCTAssertEqual(factory.sinks(2).count, 1)
        driver.configure(enabled: true, targets: [2]); ack(driver)
        XCTAssertEqual(factory.sinks(2).count, 1)
        driver.stop(); driver.start(); ack(driver)
        XCTAssertEqual(factory.sinks(2).count, 2)
        let shutdown = expectation(description: "clock closed")
        driver.shutdown { shutdown.fulfill() }; wait(for: [shutdown], timeout: 5)
        let returned = try XCTUnwrap(factory.sinks(2).last)
        XCTAssertEqual(Array(returned.order.suffix(3)), ["flush", "fc", "close"])
        driver.start(); ack(driver); XCTAssertEqual(factory.sinks(2).count, 2)
    }
    @MainActor func testBlockedMainAnd25HzScannerDoNotLeaveTimestampGaps() throws {
        let clock = MonotonicRuntimeClock(), factory = ClockTestFactory(now: { clock.now })
        let driver = MIDIClockDriver(clock: clock, factory: { factory.open($0) })
        let runtime = PerformanceRuntime(clock: clock, mailbox: .init())
        let source = try ClockTestScanner(runtime: runtime, clock: clock)
        let scanner = DispatchQueue(label: "tempo.fake-scanner")
        let load = DispatchSource.makeTimerSource(queue: scanner)
        load.schedule(deadline: .now(), repeating: .milliseconds(40))
        load.setEventHandler { source.emit() }
        load.resume(); defer { load.cancel() }
        driver.configure(enabled: true, targets: [1]); driver.start(); ack(driver)
        Thread.sleep(forTimeInterval: 0.2) // Actual Main blockage, not a fake UI timer.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        driver.stop(); ack(driver)
        load.cancel()
        let scanned = expectation(description: "scanner profiles processed")
        runtime.acknowledge { scanned.fulfill() }
        wait(for: [scanned], timeout: 5) // Runtime acknowledgements are delivered on Main.
        XCTAssertGreaterThanOrEqual(runtime.diagnostics.processedProfiles, 8, "Actual 25-Hz profiles must reach PerformanceRuntime during Main blockage")
        let closed = expectation(description: "scanner runtime closed")
        runtime.terminate { closed.fulfill() }; wait(for: [closed], timeout: 5)
        let sink = try XCTUnwrap(factory.sinks(1).first)
        let start = try XCTUnwrap(sink.events.first?.time)
        let ticks = sink.retained.filter { $0.byte == 0xf8 }
        XCTAssertGreaterThan(ticks.count, 15)
        for (index, tick) in ticks.enumerated() {
            XCTAssertEqual(tick.time, start + Double(index + 1) * (60 / (120 * 24)))
            XCTAssertGreaterThan(tick.time, tick.submitted)
        }
        let leads = sink.events.filter { $0.byte == 0xf8 }.map { $0.time - $0.submitted }
        print("TEMPO load: profiles=\(runtime.diagnostics.processedProfiles), ticks=\(ticks.count), minLead=\(leads.min() ?? 0), maxLead=\(leads.max() ?? 0), drift=0")
    }
}
