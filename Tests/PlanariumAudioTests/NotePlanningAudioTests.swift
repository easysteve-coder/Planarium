import AudioToolbox
import Foundation
import XCTest
import PlanariumDomain
import PlanariumRuntime
@testable import PlanariumAudio

private final class PlannedAURecorder: @unchecked Sendable {
    struct Event: Equatable { let time: AUEventSampleTime; let bytes: [UInt8] }
    private let lock = NSLock()
    private var events: [Event] = []
    var log: [Event] { lock.lock(); defer { lock.unlock() }; return events }
    func record(_ time: AUEventSampleTime, _ count: Int, _ bytes: UnsafePointer<UInt8>) {
        lock.lock(); events.append(.init(time: time, bytes: Array(UnsafeBufferPointer(start: bytes, count: count)))); lock.unlock()
    }
}
private final class PlannedAnchorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = NoteRenderAnchor(seconds: 0, sample: 0, rate: 0, frames: 0)
    func read() -> NoteRenderAnchor { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: NoteRenderAnchor) { lock.lock(); stored = value; lock.unlock() }
}

final class NotePlanningAudioTests: XCTestCase {
    private let identity = SpatialAudioUnitIdentity(componentType: 0, componentSubType: 0, componentManufacturer: 0)
    func testNativeAdapterUsesRenderSamplesAndDoubleOffBeyondHandedOn() {
        let recorder = PlannedAURecorder()
        let schedule = SystemAUSchedule(identity: identity, midi: { time, _, count, bytes in recorder.record(time, count, bytes) },
            anchor: { .init(seconds: 10, sample: 480_000, rate: 48_000, frames: 480) }, now: { 10.005 })
        XCTAssertEqual(schedule.planningLead, 0.01)
        XCTAssertEqual(schedule.sendPlanned(bytes: [0x90, 60, 100], deadline: 10.015, now: 10.005), .sent)
        XCTAssertEqual(recorder.log.first?.time, AUEventSampleTimeImmediate + 240)
        XCTAssertEqual(schedule.cancelPlanned(bytes: [0x80, 60, 0], deadline: 10.015, now: 10.006), .sent)
        XCTAssertEqual(recorder.log.suffix(2).map(\.time), [AUEventSampleTimeImmediate, AUEventSampleTimeImmediate + 241])
        // A future On can last at most the one sample between On and deferred
        // Off in the AU's queue. The test does not claim the On was recalled.
        let relativeTimes = recorder.log.map { $0.time - AUEventSampleTimeImmediate }
        XCTAssertEqual(relativeTimes, [240, 0, 241])
    }
    func testUnknownStaleAndChangingQuantumNeverInventLookaheadAndLateOffIsImmediate() {
        for frames: UInt32 in [0, 64, 512] {
            let recorder = PlannedAURecorder()
            let schedule = SystemAUSchedule(identity: identity, midi: { time, _, count, bytes in recorder.record(time, count, bytes) },
                anchor: { .init(seconds: 10 - Double(frames) / 48_000, sample: 0, rate: 48_000, frames: frames) }, now: { 10 })
            let result = schedule.sendPlanned(bytes: [0x90, 60, 100], deadline: 10 + 128 / 48_000, now: 10)
            XCTAssertEqual(result, frames == 512 ? .sent : .unbound)
            XCTAssertEqual(schedule.sendPlanned(bytes: [0x80, 60, 0], deadline: 9, now: 10), .sent)
            XCTAssertEqual(recorder.log.last?.time, AUEventSampleTimeImmediate)
        }
        let anchor = NoteRenderAnchor(seconds: 10, sample: 0, rate: 48_000, frames: 480)
        XCTAssertEqual(anchor.lead(at: 11), 0)
        XCTAssertNil(anchor.offset(deadline: 11.001, now: 11))
    }
    func testImmediateNativeSchedulingBytesAndSampleTimeAreUnchanged() {
        let recorder = PlannedAURecorder()
        let schedule = SystemAUSchedule(identity: identity, midi: { time, _, count, bytes in recorder.record(time, count, bytes) },
            anchor: { .init(seconds: 10, sample: 0, rate: 48_000, frames: 480) }, now: { 10 })
        let bytes: [[UInt8]] = [[0x90, 60, 100], [0x80, 60, 0], [0xb0, 123, 0]]
        for message in bytes { XCTAssertEqual(schedule.scheduleMIDI(bytes: message), .sent) }
        XCTAssertEqual(recorder.log.map(\.bytes), bytes)
        XCTAssertEqual(recorder.log.map(\.time), Array(repeating: AUEventSampleTimeImmediate, count: 3))
    }
    func testCancellationBlocksSamePitchUntilDeferredOffPassesIncludingUnknownAnchor() {
        let recorder = PlannedAURecorder(), box = PlannedAnchorBox()
        let schedule = SystemAUSchedule(identity: identity, midi: { time, _, count, bytes in recorder.record(time, count, bytes) },
            anchor: { box.read() }, now: { 10 })
        XCTAssertEqual(schedule.sendPlanned(bytes: [0x90, 60, 100], deadline: 10, now: 10), .sent)
        XCTAssertEqual(schedule.cancelPlanned(bytes: [0x80, 60, 0], deadline: 10, now: 10), .sent)
        XCTAssertFalse(schedule.permitsNoteOn(bytes: [0x90, 60, 100], now: 10.001))
        XCTAssertTrue(schedule.permitsNoteOn(bytes: [0x91, 60, 100], now: 10.001), "Other channels are independent")
        box.set(.init(seconds: 10.01, sample: 480, rate: 48_000, frames: 480))
        XCTAssertFalse(schedule.permitsNoteOn(bytes: [0x90, 60, 100], now: 10.011))
        XCTAssertFalse(schedule.permitsNoteOn(bytes: [0x90, 60, 100], now: 10.02))
        XCTAssertFalse(schedule.permitsNoteOn(bytes: [0x90, 60, 100], now: 100), "Stopped render cannot be acknowledged by elapsed wall time")
        box.set(.init(seconds: 10.04, sample: 1920, rate: 48_000, frames: 480))
        XCTAssertTrue(schedule.permitsNoteOn(bytes: [0x90, 60, 100], now: 10.04))
        XCTAssertEqual(schedule.cancelPlanned(bytes: [0x80, 60, 0], deadline: 10.04, now: 10.04), .sent)
        box.set(.init(seconds: 11, sample: 0, rate: 48_000, frames: 128))
        XCTAssertFalse(schedule.permitsNoteOn(bytes: [0x90, 60, 100], now: 11))
        box.set(.init(seconds: 11.01, sample: 512, rate: 48_000, frames: 128))
        XCTAssertTrue(schedule.permitsNoteOn(bytes: [0x90, 60, 100], now: 11.01))
    }

    @MainActor func testRetainedPortCancelsQueuedNotesAfterHostStopWhileNewOnsAreBlocked() throws {
        let h = try Harness(); defer { h.finish() }
        let recorder = PlannedAURecorder()
        let native = SystemAUSchedule(identity: identity, midi: { time, _, count, bytes in recorder.record(time, count, bytes) },
            anchor: { .init(seconds: 10, sample: 0, rate: 48_000, frames: 480) }, now: { 10.005 })
        h.host.apply(.init(instrument: plugin()))
        let unit = h.unit(); unit.schedule = native; h.components.succeed(0, unit)
        try h.host.start()
        let port = try XCTUnwrap(h.runtime.schedules.values.first as? any PlannedNoteBoundary)
        XCTAssertEqual(port.sendPlanned(bytes: [0x90, 60, 100], deadline: 10.015, now: 10.005), .sent)
        h.host.stop()
        XCTAssertEqual(port.sendPlanned(bytes: [0x90, 61, 100], deadline: 10.016, now: 10.006), .unbound)
        XCTAssertEqual(port.cancelPlanned(bytes: [0x80, 60, 0], deadline: 10.015, now: 10.006), .sent)
        XCTAssertEqual(recorder.log.suffix(2).map(\.time), [AUEventSampleTimeImmediate, AUEventSampleTimeImmediate + 241])
    }

    func testSameOwnerRetriggersWithinOneAUQuantumAndCancellationFollowsLatestOn() {
        let recorder = PlannedAURecorder(), strip = UUID()
        let schedule = SystemAUSchedule(identity: identity, midi: { time, _, count, bytes in recorder.record(time, count, bytes) },
            anchor: { .init(seconds: 10, sample: 0, rate: 48_000, frames: 480) }, now: { 10.005 })
        var router = OutputRouter()
        router.attach(RuntimePorts.audioUnit(stripID: strip, boundary: schedule))
        let token = router.beginNotePlan(owner: UUID(), now: 10)
        let note = SpatialPlayedNote(number: 60, velocity: 100)
        let on = MusicEvent.noteOn(destination: .audioUnit(stripID: strip), channel: 0, note: note)
        let off = MusicEvent.noteOff(destination: .audioUnit(stripID: strip), channel: 0, note: note)
        _ = router.plan(.init(deadline: 10.01, event: on, token: token))
        router.advanceNotePlans(now: 10.005)
        _ = router.plan(.init(deadline: 10.015, event: on, token: token))
        _ = router.plan(.init(deadline: 10.015, event: off, token: token))
        router.advanceNotePlans(now: 10.006)
        router.cancelNotePlans(now: 10.006)
        XCTAssertEqual(recorder.log.map { $0.time - AUEventSampleTimeImmediate }, [0, 240, 240, 0, 241])
        XCTAssertEqual(recorder.log.map { $0.bytes[0] }, [0x90, 0x80, 0x90, 0x80, 0x80])
    }

}
