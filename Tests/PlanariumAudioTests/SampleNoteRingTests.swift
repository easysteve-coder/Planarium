import XCTest
import AudioToolbox
import PlanariumHostClockDSP
import PlanariumDomain
import PlanariumRuntime
@testable import PlanariumAudio

private extension PlanariumSampleNote {
    init(sample: Double, generation: UInt64, status: UInt8, note: UInt8, velocity: UInt8) {
        self.init(sample: sample, generation: generation, status: status, note: note, velocity: velocity, voice: 1)
    }
}

private final class SampleAnchorState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NoteRenderAnchor(seconds: 10, sample: 441_000, rate: 44_100, frames: 256)
    func read() -> NoteRenderAnchor { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ anchor: NoteRenderAnchor) { lock.lock(); value = anchor; lock.unlock() }
}

private final class SampleRingHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

final class SampleNoteRingTests: XCTestCase {
    struct Receipt: Equatable { let sample: Double; let bytes: [UInt8] }
    private func trace(rate: Double, delayed: Bool) throws -> [Receipt] {
        let ring = try XCTUnwrap(planarium_note_ring_create())
        defer { planarium_note_ring_destroy(ring) }
        var result: [Receipt] = [], pending: [(Double, [UInt8])] = []
        for step in 0..<40 {
            let sample = Double(step) * rate / 8
            pending.append((sample, [0x90, UInt8(60 + step % 3), 100]))
            pending.append((sample + rate / 16, [0x80, UInt8(60 + step % 3), 0]))
        }
        var cursor = 0, random: UInt64 = 27, nextQ = 0.0
        for start in stride(from: 0, to: Int(rate * 5.1), by: 256) {
            let now = Double(start)
            if now >= nextQ {
                while cursor < pending.count && pending[cursor].0 <= now + rate * 0.05 {
                    let event = pending[cursor]
                    XCTAssertEqual(planarium_note_ring_push(ring, .init(sample: event.0.rounded(), generation: planarium_note_ring_generation(ring), status: event.1[0], note: event.1[1], velocity: event.1[2])), 1)
                    cursor += 1
                }
                random = random &* 6364136223846793005 &+ 1
                nextQ = now + (delayed ? Double((random >> 32) % 1441) * rate / 48_000 : 256)
            }
            planarium_note_ring_render(ring, now, 256) { offset, _, count, bytes in
                result.append(.init(sample: now + Double(offset - AUEventSampleTimeImmediate), bytes: Array(UnsafeBufferPointer(start: bytes, count: count))))
            }
        }
        return result
    }
    func testAbsoluteSamplesSurviveQuantumBoundariesAndThirtyMillisecondQDelay() throws {
        for count in [90, 361] {
            for rate in [48_000.0, 44_100] {
                let normal = try trace(rate: rate, delayed: false), delayed = try trace(rate: rate, delayed: true)
                XCTAssertEqual(normal, delayed, "profile \(count), rate \(rate)")
                let ons = normal.filter { $0.bytes[0] == 0x90 }
                XCTAssertEqual(ons.count, 40)
                for (index, on) in ons.enumerated() { XCTAssertEqual(on.sample, (Double(index) * rate / 8).rounded()) }
                if rate == 48_000 {
                    for pair in zip(ons, ons.dropFirst()) { XCTAssertEqual(pair.1.sample - pair.0.sample, 6000) }
                }
            }
        }
    }
    func testGenerationCancelsPendingOnsAndSynchronouslyReleasesFreshRenderOns() throws {
        for reason in ["hand away", "PANIC", "stop", "scene", "preset", "chain", "bypass", "sleep", "terminate", "engine stop"] {
            let ring = try XCTUnwrap(planarium_note_ring_create())
            defer { planarium_note_ring_destroy(ring) }
            let generation = planarium_note_ring_generation(ring)
            for sample in [0.0, 6000] {
                XCTAssertEqual(planarium_note_ring_push(ring, .init(sample: sample, generation: generation, status: 0x92, note: 60, velocity: 100)), 1)
            }
            var log: [[UInt8]] = []
            let midi: AUScheduleMIDIEventBlock = { _, _, count, bytes in log.append(Array(UnsafeBufferPointer(start: bytes, count: count))) }
            planarium_note_ring_render(ring, 0, 256, midi)
            XCTAssertEqual(log, [[0x92, 60, 100]], reason)
            _ = planarium_note_ring_invalidate(ring)
            planarium_note_ring_render(ring, 256, 256, midi)
            planarium_note_ring_render(ring, 6000, 256, midi)
            XCTAssertEqual(log, [[0x92, 60, 100], [0x82, 60, 0]], reason)
            XCTAssertEqual(planarium_note_ring_push(ring, .init(sample: 8000, generation: generation, status: 0x90, note: 60, velocity: 100)), 0)
        }
    }
    func testNativeSampleMappingIsIndependentOfObservedAnchorAndHostTickRounding() throws {
        func trace(changingAnchor: Bool) throws -> [Receipt] {
            let ring = try XCTUnwrap(planarium_note_ring_create()), anchor = SampleAnchorState()
            defer { planarium_note_ring_destroy(ring) }
            let identity = SpatialAudioUnitIdentity(componentType: 0, componentSubType: 0, componentManufacturer: 0)
            var log: [Receipt] = []
            let schedule = SystemAUSchedule(identity: identity, midi: { _, _, _, _ in }, anchor: { anchor.read() }, now: { 10 }, sampleRing: ring)
            for index in 0..<40 {
                if changingAnchor && index > 0 {
                    let delta = Double(index * 256)
                    anchor.set(.init(seconds: 10 + delta / 44_100 + (index % 2 == 0 ? -1e-8 : 1e-8), sample: 441_000 + delta, rate: 44_100, frames: 256))
                }
                XCTAssertEqual(schedule.enqueueSampleNote(bytes: [0x90, UInt8(60 + index % 3), 90], deadline: 10 + Double(index) / 8, immediate: false), .sent)
            }
            for sample in stride(from: 441_000, to: 670_000, by: 256) {
                planarium_note_ring_render(ring, Double(sample), 256) { offset, _, count, bytes in
                    log.append(.init(sample: Double(sample) + Double(offset - AUEventSampleTimeImmediate), bytes: Array(UnsafeBufferPointer(start: bytes, count: count))))
                }
            }
            return log
        }
        XCTAssertEqual(try trace(changingAnchor: true), try trace(changingAnchor: false))
    }
    func testSingleProducerAndRenderConsumerPublishConcurrently() throws {
        let ring = try XCTUnwrap(planarium_note_ring_create()), handle = SampleRingHandle(ring)
        defer { planarium_note_ring_destroy(ring) }
        func event(_ index: Int) -> PlanariumSampleNote {
            .init(sample: Double(index), generation: 1, status: index % 2 == 0 ? 0x90 : 0x80, note: UInt8(index / 2), velocity: index % 2 == 0 ? 90 : 0)
        }
        for index in 0..<128 { XCTAssertEqual(planarium_note_ring_push(ring, event(index)), 1) }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "sample-ring-producer").async {
            for index in 128..<256 {
                let value = PlanariumSampleNote(sample: Double(index), generation: 1, status: index % 2 == 0 ? 0x90 : 0x80, note: UInt8(index / 2), velocity: index % 2 == 0 ? 90 : 0)
                XCTAssertEqual(planarium_note_ring_push(handle.pointer, value), 1)
            }
            done.signal()
        }
        var log: [[UInt8]] = []
        let midi: AUScheduleMIDIEventBlock = { _, _, count, bytes in log.append(Array(UnsafeBufferPointer(start: bytes, count: count))) }
        planarium_note_ring_render(ring, 0, 256, midi)
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        planarium_note_ring_render(ring, 256, 256, midi)
        XCTAssertEqual(log.count, 256)
        for (index, bytes) in log.enumerated() {
            XCTAssertEqual(bytes, [index % 2 == 0 ? 0x90 : 0x80, UInt8(index / 2), index % 2 == 0 ? 90 : 0])
        }
    }
    func testProductionNativeBoundaryConvertsDeadlinesAndReleasesStoppedEngineWithBarrier() throws {
        let ring = try XCTUnwrap(planarium_note_ring_create())
        defer { planarium_note_ring_destroy(ring) }
        let identity = SpatialAudioUnitIdentity(componentType: 0, componentSubType: 0, componentManufacturer: 0)
        var log: [Receipt] = []
        let midi: AUScheduleMIDIEventBlock = { offset, _, count, bytes in
            log.append(.init(sample: Double(offset - AUEventSampleTimeImmediate), bytes: Array(UnsafeBufferPointer(start: bytes, count: count))))
        }
        let schedule = SystemAUSchedule(identity: identity, midi: midi,
            anchor: { .init(seconds: 10, sample: 480_000, rate: 48_000, frames: 256) }, now: { 10 }, sampleRing: ring)
        XCTAssertEqual(schedule.enqueueSampleNote(bytes: [0x90, 60, 90], deadline: 10.125, immediate: false), .sent)
        XCTAssertTrue(log.isEmpty)
        planarium_note_ring_render(ring, 485_888, 256, midi)
        XCTAssertEqual(log, [.init(sample: 112, bytes: [0x90, 60, 90])])
        schedule.invalidateSampleNotes() // No further render is needed for Q's two Offs.
        XCTAssertEqual(log.suffix(2).map(\.bytes), [[0x80, 60, 0], [0x80, 60, 0]])
        XCTAssertEqual(log.suffix(2).map(\.sample), [0, 257])
        XCTAssertEqual(schedule.enqueueSampleNote(bytes: [0x90, 60, 90], deadline: 10.2, immediate: false), .unbound)
        planarium_note_ring_render(ring, 486_144, 256, midi)
        XCTAssertEqual(log.last?.bytes, [0x80, 60, 0])
        XCTAssertEqual(log.filter { $0.bytes[0] == 0x90 }.count, 1)
    }
    func testEarlierRetriggerPassesLongFutureGateAndOldOffCannotCutNewVoice() throws {
        let ring = try XCTUnwrap(planarium_note_ring_create())
        defer { planarium_note_ring_destroy(ring) }
        for (sample, status, voice) in [(0.0, UInt8(0x90), UInt64(1)), (48_000, 0x80, 1),
                                       (6000, 0x90, 2), (12_000, 0x80, 2), (18_000, 0x90, 3), (54_000, 0x80, 3)] {
            XCTAssertEqual(planarium_note_ring_push(ring, .init(sample: sample, generation: 1, status: status, note: 60, velocity: status == 0x90 ? 90 : 0, voice: voice)), 1)
        }
        var log: [Receipt] = []
        for start in stride(from: 0, to: 48_640, by: 256) {
            planarium_note_ring_render(ring, Double(start), 256) { offset, _, count, bytes in
                log.append(.init(sample: Double(start) + Double(offset - AUEventSampleTimeImmediate), bytes: Array(UnsafeBufferPointer(start: bytes, count: count))))
            }
        }
        XCTAssertEqual(log.filter { $0.bytes[0] == 0x90 }.map(\.sample), [0, 6000, 18_000])
        XCTAssertEqual(log.filter { $0.bytes[0] == 0x80 }.map(\.sample), [6000, 12_000])
        _ = planarium_note_ring_invalidate(ring)
        planarium_note_ring_render(ring, 48_640, 256) { offset, _, count, bytes in
            log.append(.init(sample: 48_640 + Double(offset - AUEventSampleTimeImmediate), bytes: Array(UnsafeBufferPointer(start: bytes, count: count))))
        }
        XCTAssertEqual(log.last, .init(sample: 48_640, bytes: [0x80, 60, 0]))
    }
    func testAbortDuringRenderDoesNotPutOffBeforeAlreadyScheduledFutureOn() throws {
        let ring = try XCTUnwrap(planarium_note_ring_create())
        defer { planarium_note_ring_destroy(ring) }
        for (sample, note) in [(200.0, UInt8(60)), (210.0, 64)] {
            XCTAssertEqual(planarium_note_ring_push(ring, .init(sample: sample, generation: 1, status: 0x90, note: note, velocity: 90)), 1)
        }
        var first: [Receipt] = []
        planarium_note_ring_render(ring, 0, 256) { offset, _, count, bytes in
            first.append(.init(sample: Double(offset - AUEventSampleTimeImmediate), bytes: Array(UnsafeBufferPointer(start: bytes, count: count))))
            if bytes[0] == 0x90 { _ = planarium_note_ring_invalidate(ring) }
        }
        XCTAssertEqual(first, [.init(sample: 200, bytes: [0x90, 60, 90])])
        var next: [Receipt] = []
        planarium_note_ring_render(ring, 256, 256) { offset, _, count, bytes in
            next.append(.init(sample: 256 + Double(offset - AUEventSampleTimeImmediate), bytes: Array(UnsafeBufferPointer(start: bytes, count: count))))
        }
        XCTAssertEqual(next, [.init(sample: 256, bytes: [0x80, 60, 0])])
    }
    func testFullRingRejectsWithoutOverwritingAndNewGenerationSurvivesOldEntries() throws {
        let ring = try XCTUnwrap(planarium_note_ring_create())
        defer { planarium_note_ring_destroy(ring) }
        for _ in 0..<256 {
            XCTAssertEqual(planarium_note_ring_push(ring, .init(sample: 1000, generation: 1, status: 0x90, note: 60, velocity: 100)), 1)
        }
        XCTAssertEqual(planarium_note_ring_push(ring, .init(sample: 1000, generation: 1, status: 0x90, note: 61, velocity: 100)), 0)
        planarium_note_ring_render(ring, 0, 256) { _, _, _, _ in XCTFail("Future event emitted early") }
        XCTAssertEqual(planarium_note_ring_push(ring, .init(sample: 1000, generation: 1, status: 0x90, note: 61, velocity: 100)), 0)
        let generation = planarium_note_ring_invalidate(ring)
        var log: [[UInt8]] = []
        let midi: AUScheduleMIDIEventBlock = { _, _, count, bytes in log.append(Array(UnsafeBufferPointer(start: bytes, count: count))) }
        planarium_note_ring_render(ring, 0, 256, midi)
        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(planarium_note_ring_push(ring, .init(sample: -1, generation: generation, status: 0x90, note: 61, velocity: 90)), 1)
        planarium_note_ring_render(ring, 256, 256, midi)
        XCTAssertEqual(log, [[0x90, 61, 90]])
    }
}
