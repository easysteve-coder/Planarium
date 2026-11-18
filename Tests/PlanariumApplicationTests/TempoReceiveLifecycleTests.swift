import XCTest
import Combine
import Dispatch
import Foundation
import PlanariumApplication
import PlanariumDomain
import PlanariumRuntime
import PlanariumMIDI

private final class ReceiveLifecyclePort: MIDIClockSource, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    let receive: @Sendable (MIDIClockPacket) -> Void
    init(_ receive: @escaping @Sendable (MIDIClockPacket) -> Void) { self.receive = receive }
    func close() { lock.lock(); closed = true; lock.unlock() }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}
private final class ReceiveLifecycleFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [ReceiveLifecyclePort] = []
    private var available = true
    func setAvailable(_ available: Bool) { lock.lock(); self.available = available; lock.unlock() }
    func open(_ id: Int32, _ receive: @escaping @Sendable (MIDIClockPacket) -> Void, _ lost: @escaping @Sendable () -> Void) -> (any MIDIClockSource)? {
        lock.lock(); defer { lock.unlock() }
        guard available else { return nil }
        let port = ReceiveLifecyclePort(receive); ports.append(port); return port
    }
    var all: [ReceiveLifecyclePort] { lock.lock(); defer { lock.unlock() }; return ports }
}
private final class ReceiveStopSink: MIDIClockSink, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [UInt8] = []
    func send(_ byte: UInt8, at time: Double) -> PortSendResult { lock.lock(); log.append(byte); lock.unlock(); return .sent }
    func flush() -> PortSendResult { .sent }
    func close() {}
    var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return log }
}
@MainActor final class TempoReceiveLifecycleTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(predicate())
    }
    private func finish(_ fixture: RootFixture) { var done = false; fixture.root.terminate { done = true }; wait { done } }
    private func ack(_ fixture: RootFixture) {
        let sem = DispatchSemaphore(value: 0)
        fixture.root.clockReceiver.acknowledge { sem.signal() }
        XCTAssertEqual(sem.wait(timeout: .now() + 3), .success)
    }
    func testReceiveNeverChangesPresetRevisionHistoryOrSoundingNotesAndOffRestoresBPM() throws {
        let source = ReceiveLifecycleFactory(), fixture = try RootFixture(clockSourceFactory: { source.open($0, $1, $2) })
        defer { finish(fixture) }
        try fixture.install()
        let owner = fixture.root.document
        owner.setBeatsPerMinute(93)
        let document = owner.document, undo = owner.undoMenuTitle
        // Fake scanner enters a real installed note cell before external transport.
        let session = UUID()
        fixture.root.runtime.sessionBegan(session)
        fixture.root.runtime.frame(.init(sessionID: session, sequence: 1, time: ProcessInfo.processInfo.systemUptime, measurements: [
            try XCTUnwrap(DeviceTickMeasurement(order: 0, ticks: .point(180)!, rawCentimeters: 100))
        ]))
        wait { fixture.midi.sends.first?.sent.contains { $0.first == 0x90 } == true }
        let before = fixture.midi.sends.flatMap(\.sent)
        owner.configureClock(direction: .receive, targets: [], sourceID: 1, sourceName: "MainStage")
        wait { source.all.count == 1 }
        let port = try XCTUnwrap(source.all.first)
        port.receive(.init(bytes: [0xfa], timestamp: 10, arrival: 10))
        for i in 0...24 { port.receive(.init(bytes: [0xf8], timestamp: 10 + Double(i) / 48, arrival: ProcessInfo.processInfo.systemUptime)) }
        wait { fixture.root.clockReceiver.snapshot.tickCount == 25 && owner.clockTransportPlaying }
        XCTAssertEqual(owner.displayedBeatsPerMinute, 120)
        XCTAssertTrue(owner.clockTransportPlaying)
        XCTAssertEqual(fixture.root.audio.hostMusicalClock.snapshot.tempo, 120)
        XCTAssertEqual(fixture.root.audio.hostMusicalClock.snapshot.moving, 1)
        XCTAssertEqual(fixture.root.audio.hostMusicalClock.snapshot.beat, 25.0 / 24)
        port.receive(.init(bytes: [0xfc], timestamp: 10.6, arrival: 10.6))
        wait { !owner.clockTransportPlaying }
        XCTAssertEqual(fixture.root.audio.hostMusicalClock.snapshot.moving, 0)
        owner.setBeatsPerMinute(75); owner.tapTempo(); owner.startClockTransport(); owner.stopClockTransport()
        XCTAssertEqual(owner.document, document); XCTAssertEqual(owner.undoMenuTitle, undo)
        XCTAssertEqual(fixture.midi.sends.flatMap(\.sent), before, "External Start/Stop and local disabled actions never release or retrigger notes")
        owner.configureClock(direction: .off, targets: [], sourceID: 1)
        ack(fixture); XCTAssertTrue(port.isClosed)
        XCTAssertEqual(owner.displayedBeatsPerMinute, 93)
        XCTAssertEqual(fixture.root.audio.hostMusicalClock.snapshot.tempo, 93)
        XCTAssertEqual(fixture.root.audio.hostMusicalClock.snapshot.moving, 0)
        XCTAssertEqual(owner.document.revision, document.revision)
    }
    func testDirectionMatrixStopsEverySendAndClosesEveryReceiveAndPerformRejectsChanges() throws {
        let source = ReceiveLifecycleFactory(), sink = ReceiveStopSink()
        let fixture = try RootFixture(clockSinkFactory: { _ in sink }, clockSourceFactory: { source.open($0, $1, $2) })
        defer { finish(fixture) }
        let owner = fixture.root.document
        for first in ClockDirection.allCases {
            for next in ClockDirection.allCases where first != next {
                owner.configureClock(direction: first, targets: [1, 2], sourceID: 1)
                if first == .send {
                    owner.startClockTransport()
                    wait { sink.bytes.last == 0xf8 }
                }
                if first == .receive { wait { !source.all.isEmpty && source.all.last?.isClosed == false } }
                let stops = sink.bytes.filter { $0 == 0xfc }.count
                let lastPort = first == .receive ? source.all.last : nil
                owner.configureClock(direction: next, targets: [1, 2], sourceID: 1)
                if first == .send { wait { sink.bytes.filter { $0 == 0xfc }.count == stops + 2 } }
                if let lastPort { wait { lastPort.isClosed } }
                if next == .receive { wait { source.all.last?.isClosed == false } }
                XCTAssertEqual(owner.clockDirection, next)
                owner.configureClock(direction: .off, targets: [], sourceID: nil)
                ack(fixture)
            }
        }
        owner.configureClock(direction: .receive, targets: [1], sourceID: 1)
        wait { source.all.last?.isClosed == false }
        let count = source.all.count
        owner.canvas.setPerformanceLocked(true)
        owner.configureClock(direction: .send, targets: [2], sourceID: 2)
        owner.configureClock(direction: .receive, targets: [2], sourceID: 2)
        ack(fixture)
        XCTAssertEqual(owner.clockDirection, .receive); XCTAssertEqual(source.all.count, count)
        XCTAssertFalse(source.all.last!.isClosed)
    }
    func testReceiveOpensAfterSenderStopAcknowledgement() throws {
        let source = ReceiveLifecycleFactory(), sink = ReceiveStopSink()
        let fixture = try RootFixture(clockSinkFactory: { _ in sink }, clockSourceFactory: { id, receive, lost in
            XCTAssertEqual(sink.bytes.filter { $0 == 0xfc }.count, 2, "Both destinations stopped before input port construction")
            return source.open(id, receive, lost)
        })
        defer { finish(fixture) }
        fixture.root.document.configureClock(direction: .send, targets: [1, 2], sourceID: nil)
        fixture.root.document.startClockTransport()
        wait { sink.bytes.contains(0xfa) }
        fixture.root.document.configureClock(direction: .receive, targets: [1, 2], sourceID: 1)
        wait { source.all.count == 1 }
        XCTAssertFalse(fixture.root.document.clockTransportPlaying)
    }
    func testSleepWakeTerminationAndRapidSwitchNeverReopenStaleSource() throws {
        let source = ReceiveLifecycleFactory(), fixture = try RootFixture(clockSourceFactory: { source.open($0, $1, $2) })
        let owner = fixture.root.document
        owner.configureClock(direction: .receive, targets: [], sourceID: 1)
        owner.configureClock(direction: .off, targets: [], sourceID: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03)); ack(fixture)
        XCTAssertTrue(source.all.isEmpty)
        owner.configureClock(direction: .receive, targets: [], sourceID: 1)
        wait { source.all.count == 1 }
        fixture.root.sleep(); ack(fixture); XCTAssertTrue(source.all[0].isClosed)
        fixture.root.wake(); ack(fixture); XCTAssertEqual(source.all.count, 2)
        // Both orderings: switching first, then sleeping before activation.
        owner.configureClock(direction: .receive, targets: [], sourceID: 2)
        fixture.root.sleep(); ack(fixture)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertTrue(source.all.allSatisfy(\.isClosed))
        fixture.root.wake(); ack(fixture); XCTAssertEqual(source.all.count, 3)
        finish(fixture)
        XCTAssertTrue(source.all.allSatisfy(\.isClosed))
        owner.configureClock(direction: .receive, targets: [], sourceID: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03)); ack(fixture)
        XCTAssertEqual(source.all.count, 3)
    }
}


extension TempoReceiveLifecycleTests {
    func testHundredActualReceiverSnapshotsPublishOnlyVisibleClockChangesAndNeverDocument() throws {
        let clock = ReceivePresentationClock(), source = ReceiveLifecycleFactory()
        let fixture = try RootFixture(clock: clock, clockSourceFactory: { source.open($0, $1, $2) })
        defer { finish(fixture) }
        let owner = fixture.root.document
        owner.configureClock(direction: .receive, targets: [], sourceID: 1)
        wait { source.all.count == 1 && owner.externalClock.isSourceAvailable }
        let port = try XCTUnwrap(source.all.first)
        var documents = 0, displays = 0
        let docToken = owner.objectWillChange.sink { documents += 1 }
        let displayToken = owner.clockDisplay.objectWillChange.sink { displays += 1 }
        defer { docToken.cancel(); displayToken.cancel() }
        port.receive(.init(bytes: [0xfa], timestamp: 10, arrival: 10))
        for i in 1...100 {
            let now = 10 + Double(i) / 8
            for tick in ((i-1)*6+1)...(i*6) {
                port.receive(.init(bytes: [0xf8], timestamp: 10 + Double(tick) / 48, arrival: now))
            }
            ack(fixture); clock.advance(to: now); ack(fixture)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        XCTAssertEqual(documents, 0)
        XCTAssertEqual(displays, 1, "Only stopped → playing changes the visible 120.0 BPM snapshot")
        XCTAssertEqual(fixture.root.clockReceiver.snapshot.tickCount, 600)
        XCTAssertEqual(fixture.root.audio.hostMusicalClock.snapshot.beat, 25,
                       "Host beat advanced on Q while Main only observed display values")
        XCTAssertEqual(owner.externalClock.beatsPerMinute, 120)
    }
    func testWakeWithoutClockRefreshesUnavailableDisplayAfterIgnoredSuspendSnapshot() throws {
        let source = ReceiveLifecycleFactory(), fixture = try RootFixture(clockSourceFactory: { source.open($0, $1, $2) })
        defer { finish(fixture) }
        let owner = fixture.root.document
        func turn() {
            let wake = DispatchWorkItem {}
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.003, execute: wake)
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.003))
            wake.cancel()
        }
        func expect(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !predicate(), Date() < deadline { turn() }
            XCTAssertTrue(predicate())
        }
        owner.configureClock(direction: .receive, targets: [], sourceID: 1)
        expect { source.all.count == 1 && owner.externalClock.isSourceAvailable }
        let port = try XCTUnwrap(source.all.last)
        port.receive(.init(bytes: [0xfa], timestamp: 10, arrival: ProcessInfo.processInfo.systemUptime))
        for i in 0...24 { port.receive(.init(bytes: [0xf8], timestamp: 10 + Double(i) / 48, arrival: ProcessInfo.processInfo.systemUptime)) }
        expect { owner.clockTransportPlaying }
        fixture.root.sleep(); ack(fixture)
        for _ in 0..<6 { turn() }
        XCTAssertTrue(port.isClosed)
        XCTAssertTrue(fixture.root.clockReceiver.snapshot.isLost)
        XCTAssertFalse(owner.externalClock.isLost, "Main ignored the suspended receiver snapshot")
        var documents = 0
        let token = owner.objectWillChange.sink { documents += 1 }
        defer { token.cancel() }
        source.setAvailable(false)
        fixture.root.wake(); ack(fixture)
        expect { owner.externalClock.isLost && !owner.externalClock.isSourceAvailable }
        XCTAssertFalse(owner.clockTransportPlaying)
        source.setAvailable(true); fixture.root.clockReceiver.sourcesChanged(); ack(fixture)
        expect { source.all.count == 2 && owner.externalClock.isSourceAvailable }
        XCTAssertTrue(owner.externalClock.isLost, "Returning silent endpoint still has no clock ticks")
        XCTAssertEqual(documents, 0)
    }
    func testSwitchingIdenticalSilentSourcesRestoresAvailabilityAfterDisplayReset() throws {
        let source = ReceiveLifecycleFactory(), fixture = try RootFixture(clockSourceFactory: { source.open($0, $1, $2) })
        defer { finish(fixture) }
        let owner = fixture.root.document
        for id: Int32 in [1, 2, 3] {
            owner.configureClock(direction: .receive, targets: [], sourceID: id)
            wait { source.all.count == Int(id) && owner.externalClock.isSourceAvailable }
            XCTAssertFalse(owner.externalClock.isLost)
        }
    }
    func testDisplayRoundingAndRepeatedPerformanceNoticesNeverRepublishDocument() throws {
        let fixture = try RootFixture(), owner = fixture.root.document
        defer { finish(fixture) }
        var documents = 0, displays = 0, notices = 0
        let a = owner.objectWillChange.sink { documents += 1 }
        let b = owner.clockDisplay.objectWillChange.sink { displays += 1 }
        let c = owner.notices.objectWillChange.sink { notices += 1 }
        defer { a.cancel(); b.cancel(); c.cancel() }
        for i in 0..<100 {
            var raw = ExternalClockState(); raw.tickCount = UInt64(i)
            raw.beatsPerMinute = 120 + Double(i % 5) / 1000
            owner.clockDisplay.observe(.init(raw))
        }
        XCTAssertEqual(documents, 0); XCTAssertEqual(displays, 0)
        var raw = ExternalClockState(); raw.beatsPerMinute = 120.06
        owner.clockDisplay.observe(.init(raw)); XCTAssertEqual(displays, 1)
        owner.canvas.setPerformanceLocked(true)
        for _ in 0..<100 { XCTAssertFalse(owner.authorize(.edit)) }
        XCTAssertEqual(documents, 0); XCTAssertEqual(notices, 1)
        owner.canvas.setPerformanceLocked(false)
        XCTAssertEqual(notices, 2); XCTAssertNil(owner.notice)
    }
}
private final class ReceivePresentationClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = 10.0
    private var tasks: [UUID: (Double, DispatchQueue, @Sendable () -> Void)] = [:]
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        let id = UUID(); lock.lock(); tasks[id] = (deadline, queue, action); lock.unlock()
        return .init { [self] in lock.lock(); tasks[id] = nil; lock.unlock() }
    }
    func advance(to value: Double) {
        lock.lock(); time = value
        let due = tasks.filter { $0.value.0 <= value }; due.keys.forEach { tasks[$0] = nil }; lock.unlock()
        due.values.forEach { $0.1.async(execute: $0.2) }
    }
}
