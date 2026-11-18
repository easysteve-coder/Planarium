import XCTest
import Foundation
import Dispatch
import PlanariumApplication
import PlanariumDomain
import PlanariumMIDI
import PlanariumRuntime

final class TempoManualClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double
    init(_ value: Double = 10) { time = value }
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    func set(_ value: Double) { lock.lock(); time = value; lock.unlock() }
    func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation { .init {} }
}
private final class LifecycleClockSink: MIDIClockSink, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [UInt8] = []
    private var bindings: [Int32] = []
    func bind(_ id: Int32) -> LifecycleClockSink { lock.lock(); bindings.append(id); lock.unlock(); return self }
    var targetIDs: [Int32] { lock.lock(); defer { lock.unlock() }; return bindings }
    func send(_ byte: UInt8, at time: Double) -> PortSendResult { lock.lock(); operations.append(byte); lock.unlock(); return .sent }
    func flush() -> PortSendResult { .sent }
    func close() {}
    var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return operations }
}
@MainActor final class TempoLifecycleTests: XCTestCase {
    private func ack(_ driver: MIDIClockDriver) {
        let done = DispatchSemaphore(value: 0); driver.acknowledge { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }
    private func terminate(_ root: PlanariumComposition) {
        var done = false; root.terminate { done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(done)
    }
    func testEveryProductionStopRouteSendsStopAndClosesClockIncludingRepeatedEdges() throws {
        for route in ["stop", "panic", "documentPanic", "spatialStop", "audioStop", "audioStartStop", "sleep", "terminate"] {
            let sink = LifecycleClockSink(), f = try RootFixture(clock: TempoManualClock(), clockSinkFactory: { _ in sink })
            let owner = f.root.document
            owner.configureClock(enabled: true, targets: [1, 2])
            if route == "audioStartStop" { owner.startSpatialAudio() } else { owner.startClockTransport() }
            ack(f.root.midiClock)
            XCTAssertTrue(owner.clockTransportPlaying, route)
            XCTAssertEqual(f.root.audio.hostMusicalClock.snapshot.moving, 1, route)
            XCTAssertEqual(sink.bytes.filter { $0 == 0xfa }.count, 2, route)
            func stop() {
                switch route {
                case "stop": f.root.stop()
                case "panic": f.root.panic()
                case "documentPanic": owner.panicAll()
                case "spatialStop": owner.stopSpatialMode()
                case "audioStop", "audioStartStop": owner.stopSpatialAudio()
                case "sleep": f.root.sleep()
                case "terminate": terminate(f.root)
                default: XCTFail("Uncovered stop")
                }
            }
            stop(); ack(f.root.midiClock)
            XCTAssertFalse(owner.clockTransportPlaying, route)
            XCTAssertEqual(f.root.audio.hostMusicalClock.snapshot.moving, 0, route)
            XCTAssertEqual(sink.bytes.filter { $0 == 0xfc }.count, 2, route)
            stop(); ack(f.root.midiClock)
            XCTAssertEqual(sink.bytes.filter { $0 == 0xfc }.count, 2, "Repeat is idempotent: \(route)")
            if route == "sleep" {
                f.root.wake(); ack(f.root.midiClock)
                XCTAssertEqual(sink.bytes.filter { $0 == 0xfa }.count, 2, "Wake does not silently restart Clock")
            }
            terminate(f.root)
        }
    }
    func testTempoAndTapUseOwnerPermissionHistoryAndPresetReplacementKeepsClockRunning() throws {
        let clock = TempoManualClock(), sink = LifecycleClockSink()
        let f = try RootFixture(clock: clock, clockSinkFactory: { _ in sink }), owner = f.root.document
        defer { terminate(f.root) }
        owner.configureClock(enabled: true, targets: [2]); owner.startClockTransport(); ack(f.root.midiClock)
        owner.setBeatsPerMinute(133); XCTAssertEqual(owner.document.beatsPerMinute, 133)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.beatsPerMinute, 120)
        XCTAssertTrue(owner.redo()); XCTAssertEqual(owner.document.beatsPerMinute, 133)
        owner.tapTempo()
        // Owner mutations enqueue replanning on Q. Drain them before moving
        // the manual clock; otherwise an earlier command sees a later time
        // and correctly stops on a missed planning deadline.
        ack(f.root.midiClock)
        clock.set(10.5); owner.tapTempo(); XCTAssertEqual(owner.document.beatsPerMinute, 120)
        let before = owner.document
        owner.canvas.setPerformanceLocked(true)
        owner.setBeatsPerMinute(75)
        XCTAssertEqual(owner.document.beatsPerMinute, 75)
        ack(f.root.midiClock)
        clock.set(11); owner.tapTempo()
        XCTAssertEqual(owner.document.beatsPerMinute, 120)
        XCTAssertNotEqual(owner.document, before)
        XCTAssertNil(owner.notice)
        owner.canvas.setPerformanceLocked(false)
        let afterPerform = owner.document
        owner.setBeatsPerMinute(301); XCTAssertEqual(owner.document, afterPerform)
        var next = afterPerform; next.beatsPerMinute = 90
        try owner.applyPresetDocument(next); ack(f.root.midiClock)
        XCTAssertEqual(owner.document.beatsPerMinute, 90)
        XCTAssertTrue(owner.clockTransportPlaying)
        XCTAssertEqual(f.root.audio.hostMusicalClock.snapshot.tempo, 90)
        XCTAssertEqual(f.root.audio.hostMusicalClock.snapshot.moving, 1)
        XCTAssertFalse(sink.bytes.contains(0xfc), "Preset replaces BPM, not Clock transport")
        clock.set(11.5); owner.tapTempo()
        XCTAssertEqual(owner.document.beatsPerMinute, 90, "Preset resets tap history")
        XCTAssertEqual(f.midi.opens, [], "Clock targets never open the note destination")
    }

    func testPerformAllowsTempoButKeepsClockDirectionAndTargetsLocked() throws {
        let clock = TempoManualClock(), sink = LifecycleClockSink()
        let f = try RootFixture(clock: clock, clockSinkFactory: { sink.bind($0) }), owner = f.root.document
        defer { terminate(f.root) }
        owner.configureClock(enabled: true, targets: [2]); owner.startClockTransport(); ack(f.root.midiClock)
        owner.canvas.setPerformanceLocked(true)
        owner.configureClock(enabled: false, targets: [])
        owner.configureClock(enabled: true, targets: [1])
        ack(f.root.midiClock)
        XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason)
        XCTAssertTrue(owner.clockTransportPlaying)
        XCTAssertFalse(sink.bytes.contains(0xfc))
        owner.stopClockTransport(); owner.startClockTransport(); ack(f.root.midiClock)
        XCTAssertEqual(sink.targetIDs, [2, 2], "Blocked changes must not disable Clock or replace its destinations")
        XCTAssertEqual(sink.bytes.filter { $0 == 0xfa }.count, 2)
    }
}
