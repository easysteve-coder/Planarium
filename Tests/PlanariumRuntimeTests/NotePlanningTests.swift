import XCTest
import Foundation
import Dispatch
import PlanariumDomain
@testable import PlanariumRuntime

final class PlannedBoundaryFake: MIDISendBoundary, AUScheduleBoundary, PlannedNoteBoundary, @unchecked Sendable {
    struct Receipt: Equatable { let bytes: [UInt8]; let time: Double; let cancel: Bool }
    private let lock = NSLock()
    private var log: [Receipt] = []
    private var status: PortSendResult = .sent
    let planningLead: Double
    init(lead: Double = 0) { planningLead = lead }
    var receipts: [Receipt] { lock.lock(); defer { lock.unlock() }; return log }
    func fail(_ value: PortSendResult) { lock.lock(); status = value; lock.unlock() }
    func send(bytes: [UInt8]) -> PortSendResult { append(bytes, 0, false) }
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { send(bytes: bytes) }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
    func sendPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult { append(bytes, max(deadline, now), false) }
    func cancelPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult {
        let result = append(bytes, now, true)
        if result == .sent && planningLead > 0 { return append(bytes, max(deadline, now) + 1 / 48_000, true) }
        return result
    }
    private func append(_ bytes: [UInt8], _ time: Double, _ cancel: Bool) -> PortSendResult {
        lock.lock(); defer { lock.unlock() }
        if status == .sent { log.append(.init(bytes: bytes, time: time, cancel: cancel)) }
        return status
    }
}
final class NotePlanningTests: RuntimeTestCase {
    private let on = MusicEvent.noteOn(destination: .midi, channel: 0, note: .init(number: 60, velocity: 100))
    private let off = MusicEvent.noteOff(destination: .midi, channel: 0, note: .init(number: 60, velocity: 100))
    private func scannerProfile(count: Int, sequence: UInt64 = 1, time: Double = 10, empty: Bool = false) -> ProfileFrame {
        let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "segmentMinimum" : "fullScan",
            pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
        return .init(sessionID: session, sequence: sequence, time: time,
            measurements: empty ? [] : (0..<count).map { index in
                DeviceTickMeasurement(order: index, ticks: geometry.tickSpan(at: index)!,
                    rawCentimeters: (count == 90 ? 42...46 : 170...189).contains(index) ? 100 : 300)!
            }, geometry: geometry)
    }
    private func sceneInstrument(destination: UUID) throws -> CompiledInstrument {
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let layer = SpatialDocumentLayer(id: UUID(), name: "Scene source", color: .orange,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [cell],
            routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .legato))], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        let playing = SpatialScene(name: "Playing", activeLayerIDs: [layer.id])
        let empty = SpatialScene(id: destination, name: "Empty", activeLayerIDs: [])
        return try InstrumentCompiler.compile(.init(spatial: spatial, detection: .allStagesOff,
            revision: .init(session: session, counter: 1), scenes: [playing, empty], currentSceneID: playing.id))
    }
    func testDeadlineNotProfileRateAndCancellationOnBothSidesOfHandoff() {
        for after in [false, true] {
            var router = OutputRouter(); let output = PlannedBoundaryFake()
            router.attach(RuntimePorts.midi(boundary: output))
            let token = router.beginNotePlan(owner: UUID(), now: 10)
            XCTAssertEqual(router.plan(.init(deadline: 10.007, event: on, token: token)), .accepted)
            router.advanceNotePlans(now: 10.006)
            XCTAssertTrue(output.receipts.isEmpty)
            if after { router.advanceNotePlans(now: 10.007) }
            router.cancelNotePlans(now: after ? 10.007 : 10.006)
            router.advanceNotePlans(now: 11)
            XCTAssertEqual(output.receipts.filter { $0.bytes[0] == 0x90 }.count, after ? 1 : 0)
            XCTAssertEqual(output.receipts.last?.bytes[0], after ? 0x80 : nil)
        }
    }
    func testStaleGenerationCannotScheduleOrSurviveReplacementAndFullQueueIsBounded() {
        var router = OutputRouter(); let output = PlannedBoundaryFake(), owner = UUID()
        router.attach(RuntimePorts.midi(boundary: output))
        let old = router.beginNotePlan(owner: owner, now: 10)
        XCTAssertEqual(router.plan(.init(deadline: 11, event: on, token: old)), .accepted)
        let current = router.beginNotePlan(owner: owner, now: 10)
        XCTAssertEqual(router.plan(.init(deadline: 11, event: on, token: old)), .stale)
        router.advanceNotePlans(now: 11)
        XCTAssertTrue(output.receipts.isEmpty)
        for i in 0..<256 {
            XCTAssertEqual(router.plan(.init(deadline: 12 + Double(i), event: on, token: current)), .accepted)
        }
        XCTAssertEqual(router.plan(.init(deadline: 12, event: off, token: current)), .full)
        router.cancelNotePlans(now: 11)
        XCTAssertNil(router.nextPlannedDeadline)
    }
    func testLateOnDiscardedLateOffImmediateAndFailedReleaseReallyRetries() {
        var router = OutputRouter(); let output = PlannedBoundaryFake()
        router.attach(RuntimePorts.midi(boundary: output))
        let token = router.beginNotePlan(owner: UUID(), now: 10)
        _ = router.plan(.init(deadline: 11, event: on, token: token))
        router.advanceNotePlans(now: 12)
        XCTAssertTrue(output.receipts.isEmpty)
        _ = router.plan(.init(deadline: 13, event: on, token: token))
        router.advanceNotePlans(now: 13)
        output.fail(.faulted)
        _ = router.plan(.init(deadline: 14, event: off, token: token))
        router.advanceNotePlans(now: 15)
        XCTAssertEqual(router.display.first?.soundingNotes, 1)
        XCTAssertNotNil(router.nextPlannedDeadline)
        output.fail(.sent)
        router.advanceNotePlans(now: 15.001)
        XCTAssertEqual(output.receipts.last?.bytes, [0x80, 60, 0])
        XCTAssertEqual(router.display.first?.soundingNotes, 0)
    }
    func testAUOnlyHandsOneQuantumAheadAndCancellationHasDeferredOff() {
        var router = OutputRouter(); let output = PlannedBoundaryFake(lead: 0.01), id = UUID()
        router.attach(RuntimePorts.audioUnit(stripID: id, boundary: output))
        let token = router.beginNotePlan(owner: UUID(), now: 10)
        let event = MusicEvent.noteOn(destination: .audioUnit(stripID: id), channel: 2, note: .init(number: 67, velocity: 80))
        _ = router.plan(.init(deadline: 11, event: event, token: token))
        router.advanceNotePlans(now: 10.989)
        XCTAssertTrue(output.receipts.isEmpty)
        router.advanceNotePlans(now: 10.991)
        XCTAssertEqual(output.receipts.first?.time, 11)
        router.cancelNotePlans(now: 10.992)
        XCTAssertEqual(output.receipts.suffix(2).map(\.bytes), [[0x82, 67, 0], [0x82, 67, 0]])
        XCTAssertGreaterThan(output.receipts.last!.time, 11)
        router.advanceNotePlans(now: 12)
        XCTAssertEqual(output.receipts.filter { $0.bytes[0] == 0x92 }.count, 1)
    }
    func testImmediateCellOutputWireBytesUnchangedWithIdlePlanner90And361() throws {
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let layer = SpatialDocumentLayer(id: UUID(), name: "Wire regression", color: .orange,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [cell],
            routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .legato))], cellOverrides: [:])
        let document = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        let instrument = try InstrumentCompiler.compile(.init(spatial: document, detection: .allStagesOff, revision: .init(session: session, counter: 1)))
        for count in [90, 361] {
            let clock = FakeClock(), output = FakeBoundary(), mailbox = DisplayFrameMailbox()
            let runtime = PerformanceRuntime(clock: clock, mailbox: mailbox, noteClock: clock)
            runtime.attach(RuntimePorts.midi(boundary: output)); runtime.install(instrument)
            runtime.sessionBegan(session); runtime.frame(scannerProfile(count: count)); flush(runtime)
            runtime.stop(); flush(runtime)
            XCTAssertEqual(output.receipts.map(\.bytes), [[0x90, 60, 100], [0x80, 60, 0]])
            XCTAssertTrue(output.sounding.isEmpty)
        }
    }
    func testClockAdmissionFailureInvalidatesOwnerAndReleasesHandedNote() throws {
        let clock = NotePlanningClock(), output = PlannedBoundaryFake(lead: 1), strip = UUID()
        let runtime = PerformanceRuntime(clock: FakeClock(), mailbox: .init(), noteClock: clock)
        runtime.attach(RuntimePorts.audioUnit(stripID: strip, boundary: output))
        runtime.install(try compiled()); runtime.sessionBegan(session); runtime.frame(profile()); flush(runtime)
        let source = try XCTUnwrap(runtime.mailbox.read()?.activeCells.first)
        let ready = expectation(description: "owner")
        let owner = UUID()
        runtime.beginNotePlan(owner: owner, source: source) { token in
            guard let token else { XCTFail("source"); ready.fulfill(); return }
            runtime.planNote(.init(deadline: clock.now + 0.5,
                event: .noteOn(destination: .audioUnit(stripID: strip), channel: 0, note: .init(number: 79, velocity: 90)), token: token))
            ready.fulfill()
        }
        wait(for: [ready], timeout: 2); flush(runtime)
        Thread.sleep(forTimeInterval: 0.05); flush(runtime)
        XCTAssertTrue(output.receipts.contains { $0.bytes == [0x90, 79, 90] })
        let q = DispatchQueue(label: "saturate-note-clock")
        let tokens = (0..<16).compactMap { _ in clock.trySchedule(at: clock.now + 60, on: q) {} }
        XCTAssertEqual(tokens.count, 16)
        let invalidated = expectation(description: "overflow invalidates owner")
        runtime.beginNotePlan(owner: UUID(), source: source) { token in
            guard let token else { XCTFail("source"); invalidated.fulfill(); return }
            let note = PlannedNote(deadline: clock.now + 2,
                event: .noteOn(destination: .audioUnit(stripID: strip), channel: 0, note: .init(number: 81, velocity: 90)), token: token)
            runtime.planNote(note) { result in
                XCTAssertEqual(result, .accepted)
                runtime.planNote(note) { result in
                    XCTAssertEqual(result, .stale)
                    invalidated.fulfill()
                }
            }
        }
        wait(for: [invalidated], timeout: 2); flush(runtime)
        XCTAssertTrue(output.receipts.contains { $0.bytes == [0x80, 79, 0] && $0.cancel })
        XCTAssertFalse(output.receipts.contains { $0.bytes == [0x90, 81, 90] })
        tokens.forEach { $0.cancel() }
    }
    func testRuntimeTimerRunsWithoutProfilesAndStopInvalidatesOldToken() throws {
        let clock = FakeClock(), output = PlannedBoundaryFake(), runtime = PerformanceRuntime(clock: FakeClock(), mailbox: .init(), noteClock: clock)
        runtime.attach(RuntimePorts.midi(boundary: output))
        let instrument = try compiled()
        runtime.install(instrument); runtime.sessionBegan(session); runtime.frame(profile()); flush(runtime)
        let source = try XCTUnwrap(runtime.mailbox.read()?.activeCells.first)
        let event = MusicEvent.noteOn(destination: .midi, channel: 0, note: .init(number: 79, velocity: 90))
        let ready = expectation(description: "token")
        runtime.beginNotePlan(owner: UUID(), source: source) { token in
            guard let token else { XCTFail("Active source refused"); ready.fulfill(); return }
            runtime.planNote(.init(deadline: 10.007, event: event, token: token))
            ready.fulfill()
        }
        wait(for: [ready], timeout: 2); flush(runtime)
        runtime.sessionEnded(other) // obsolete end must not cancel the live plan
        runtime.selectScene(UUID()) // nonexistent scene makes no transition
        runtime.install(instrument) // identical installation is not a change
        runtime.releaseAudioChannel(UUID())
        runtime.releaseAudioForConfigurationChange() // MIDI remains independent
        flush(runtime)
        clock.advance(10.007); flush(runtime)
        XCTAssertEqual(output.receipts.first(where: { $0.bytes[1] == 79 })?.time, 10.007)
        runtime.stop(); flush(runtime)
        clock.advance(11); flush(runtime)
        XCTAssertEqual(output.receipts.last?.bytes[0], 0x80)
    }
    func testSharedPitchRetainsOtherOwnerAndOverflowReleasesSoundingOwner() {
        var router = OutputRouter(); let output = PlannedBoundaryFake()
        router.attach(RuntimePorts.midi(boundary: output))
        let a = router.beginNotePlan(owner: UUID(), now: 10), b = router.beginNotePlan(owner: UUID(), now: 10)
        _ = router.plan(.init(deadline: 11, event: on, token: a))
        _ = router.plan(.init(deadline: 11, event: on, token: b))
        router.advanceNotePlans(now: 11)
        XCTAssertEqual(output.receipts.count, 1)
        router.cancelNotePlans(owner: a.owner, now: 11)
        XCTAssertEqual(output.receipts.count, 1)
        for i in 0..<256 { _ = router.plan(.init(deadline: 12 + Double(i), event: on, token: b)) }
        XCTAssertEqual(router.plan(.init(deadline: 12, event: off, token: b)), .full)
        XCTAssertEqual(output.receipts.last?.bytes, [0x80, 60, 0])
        XCTAssertNil(router.nextPlannedDeadline)
    }
    func testRetireAndReplaceCannotReuseOldTokenAndProtectUnrelatedChannel() {
        var router = OutputRouter(); let output = PlannedBoundaryFake(), id = UUID()
        router.attach(RuntimePorts.midi(id: id, boundary: output))
        let token = router.beginNotePlan(owner: UUID(), now: 10)
        _ = router.plan(.init(deadline: 11, event: on, token: token))
        let unrelated = MusicEvent.noteOn(destination: .midi, channel: 3, note: .init(number: 61, velocity: 90))
        router.route([unrelated], sounding: [unrelated], allowOn: true)
        router.advanceNotePlans(now: 11)
        router.cancelNotePlans(owner: token.owner, now: 11)
        XCTAssertFalse(output.receipts.contains { $0.bytes == [0x83, 61, 0] })
        XCTAssertFalse(output.receipts.contains { $0.bytes[0] & 0xf0 == 0xb0 })
        let replacementToken = router.beginNotePlan(owner: UUID(), now: 11)
        _ = router.plan(.init(deadline: 12, event: on, token: replacementToken))
        _ = router.retire(id, now: 11)
        router.attach(RuntimePorts.midi(boundary: output))
        XCTAssertEqual(router.plan(.init(deadline: 12, event: on, token: replacementToken)), .stale)
        let before = output.receipts.count
        router.advanceNotePlans(now: 12)
        XCTAssertEqual(output.receipts.count, before)
    }
    func testOffBeforeOnAtSameDeadlineForBothInsertionOrders() {
        for reverse in [false, true] {
            var router = OutputRouter(); let output = PlannedBoundaryFake()
            router.attach(RuntimePorts.midi(boundary: output))
            let token = router.beginNotePlan(owner: UUID(), now: 10)
            _ = router.plan(.init(deadline: 11, event: on, token: token))
            router.advanceNotePlans(now: 11)
            for event in reverse ? [on, off] : [off, on] { _ = router.plan(.init(deadline: 12, event: event, token: token)) }
            router.advanceNotePlans(now: 12)
            XCTAssertEqual(output.receipts.map(\.bytes), [[0x90, 60, 100], [0x80, 60, 0], [0x90, 60, 100]])
        }
    }
    func testEveryRuntimeReleaseEdgeInvalidatesPlanningBeforeAndAfterHandoff() throws {
        let sceneID = UUID()
        let actions: [(String, (PerformanceRuntime) throws -> Void)] = [
            ("panic", { $0.panic() }), ("stop", { $0.stop() }), ("sleep", { $0.sleep() }),
            ("wake", { $0.wake() }), ("terminate", { $0.terminate(ack: {}) }),
            ("scene", { $0.selectScene(sceneID) }), ("preset", { $0.install(try self.compiled(2)) }),
            ("audio configuration", { $0.releaseAudioForConfigurationChange() }),
            ("channel", { $0.releaseAudioChannel(InstrumentChannel.legacyID) }),
            ("session", { $0.sessionEnded(self.session) })
        ]
        for (label, action) in actions {
            for after in [false, true] {
                let clock = FakeClock(), output = PlannedBoundaryFake()
                let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock)
                let instrument = try label == "scene" ? sceneInstrument(destination: sceneID) : compiled()
                runtime.attach(RuntimePorts.midi(boundary: output))
                runtime.attach(RuntimePorts.audioUnit(boundary: output))
                runtime.install(instrument)
                runtime.sessionBegan(session); runtime.frame(profile()); flush(runtime)
                let source = try XCTUnwrap(runtime.mailbox.read()?.activeCells.first)
                let destination: SpatialOutputDestination = ["audio configuration", "channel"].contains(label)
                    ? .audioUnit(stripID: InstrumentChannel.legacyID) : .midi
                let event = MusicEvent.noteOn(destination: destination, channel: 1, note: .init(number: 79, velocity: 90))
                let ready = expectation(description: label)
                runtime.beginNotePlan(owner: UUID(), source: source) { token in
                    guard let token else { XCTFail("Source"); ready.fulfill(); return }
                    runtime.planNote(.init(deadline: 10.007, event: event, token: token))
                    ready.fulfill()
                }
                wait(for: [ready], timeout: 2); flush(runtime)
                if after { clock.advance(10.007); flush(runtime) }
                try action(runtime); flush(runtime)
                if label == "scene" { XCTAssertEqual(runtime.mailbox.read()?.scene?.currentSceneID, sceneID) }
                let before = output.receipts.filter { $0.bytes == [0x91, 79, 90] }.count
                clock.advance(11); flush(runtime)
                XCTAssertEqual(output.receipts.filter { $0.bytes == [0x91, 79, 90] }.count, before, label)
                XCTAssertEqual(before, after ? 1 : 0, label)
                if after { XCTAssertTrue(output.receipts.contains { $0.bytes == [0x81, 79, 0] }, label) }
            }
        }
    }

    func testGateExitCancelsWhileHeldAndToggledPlansSurviveInputLoss90And361() throws {
        for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
            for count in [90, 361] {
                let clock = FakeClock(), output = PlannedBoundaryFake()
                let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock)
                let instrument = try compiled(transition: transition)
                runtime.attach(RuntimePorts.midi(boundary: output)); runtime.install(instrument)
                runtime.sessionBegan(session); runtime.frame(scannerProfile(count: count)); flush(runtime)
                let source = try XCTUnwrap(runtime.mailbox.read()?.activeCells.first)
                let event = MusicEvent.noteOn(destination: .midi, channel: 1, note: .init(number: 79, velocity: 90))
                let ready = expectation(description: "gate")
                runtime.beginNotePlan(owner: UUID(), source: source) { token in
                    guard let token else { XCTFail("source"); ready.fulfill(); return }
                    runtime.planNote(.init(deadline: 10.007, event: event, token: token)); ready.fulfill()
                }
                wait(for: [ready], timeout: 2); flush(runtime)
                runtime.frame(scannerProfile(count: count, sequence: 2, time: 10.001, empty: true)); flush(runtime)
                runtime.sessionEnded(session, reason: .failure); flush(runtime)
                runtime.sessionBegan(other); flush(runtime) // automatic recovery preserves held owners
                clock.advance(10.007); flush(runtime)
                XCTAssertEqual(output.receipts.contains { $0.bytes == [0x91, 79, 90] }, transition != .legato)
                runtime.panic(); flush(runtime)
                if transition != .legato { XCTAssertTrue(output.receipts.contains { $0.bytes == [0x81, 79, 0] }) }
            }
        }
    }

    func testStaleProducerAfterStopCannotReintroduceLateOn() throws {
        let clock = FakeClock(), output = PlannedBoundaryFake()
        let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock)
        let instrument = try compiled()
        runtime.attach(RuntimePorts.midi(boundary: output)); runtime.install(instrument)
        runtime.sessionBegan(session); runtime.frame(profile()); flush(runtime)
        let source = try XCTUnwrap(runtime.mailbox.read()?.activeCells.first)
        let ready = expectation(description: "stale producer rejected")
        runtime.beginNotePlan(owner: UUID(), source: source) { token in
            guard let token else { XCTFail("source"); ready.fulfill(); return }
            runtime.stop()
            runtime.planNote(.init(deadline: 10.007,
                event: .noteOn(destination: .midi, channel: 2, note: .init(number: 79, velocity: 90)), token: token)) { result in
                XCTAssertEqual(result, .stale)
                ready.fulfill()
            }
        }
        wait(for: [ready], timeout: 2); flush(runtime)
        clock.advance(10.007); flush(runtime)
        XCTAssertFalse(output.receipts.contains { $0.bytes == [0x92, 79, 90] })
    }

    func testPanicAndToggledOffCellCannotMintNewTokenWithoutPlayableInput() throws {
        for transition in [SpatialNoteTransition.legato, .toggle] {
            let clock = FakeClock(), runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock)
            let output = PlannedBoundaryFake(), instrument = try compiled(transition: transition)
            runtime.attach(RuntimePorts.midi(boundary: output)); runtime.install(instrument)
            runtime.sessionBegan(session); runtime.frame(profile()); flush(runtime)
            let source = try XCTUnwrap(runtime.mailbox.read()?.activeCells.first)
            if transition == .toggle {
                runtime.frame(profile(2, empty: true, time: 10.1)); flush(runtime)
                runtime.frame(profile(3, time: 11)); flush(runtime)
            } else { runtime.panic(); flush(runtime) }
            let rejected = expectation(description: "released source blocks new token")
            runtime.beginNotePlan(owner: UUID(), source: source) { token in
                XCTAssertNil(token); rejected.fulfill()
            }
            wait(for: [rejected], timeout: 2)
        }
    }

    func testAnotherHeldCellCannotAuthorizeAnInactiveSelectedToggleCell() throws {
        let a = PolarDeviceLattice(ring: 100, sector: 180)!, b = PolarDeviceLattice(ring: 120, sector: 180)!
        let layer = SpatialDocumentLayer(id: UUID(), name: "Independent toggles", color: .orange,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [a, b],
            routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .toggle))],
            cellOverrides: [b: [.init(target: .midiNote(channel: 0), value: .note(number: 64, velocity: 100))]], toggleGuardSeconds: 0)
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        let instrument = try InstrumentCompiler.compile(.init(spatial: spatial, detection: .allStagesOff, revision: .init(session: session, counter: 1)))
        let clock = FakeClock(), runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock)
        runtime.install(instrument); runtime.sessionBegan(session)
        runtime.frame(profile()); flush(runtime)
        runtime.frame(profile(2, empty: true, time: 10.04)); flush(runtime)
        runtime.frame(profile(3, ring: 120, time: 10.08)); flush(runtime)
        runtime.frame(profile(4, empty: true, time: 10.12)); flush(runtime)
        runtime.frame(profile(5, ring: 120, time: 10.16)); flush(runtime)
        XCTAssertEqual(Set(runtime.mailbox.read()!.heldCells.map(\.cell)), [a])
        let source = try XCTUnwrap(runtime.mailbox.read()?.activeCells.first)
        XCTAssertEqual(source.cell, b)
        let done = expectation(description: "Other held cell grants no token")
        runtime.beginNotePlan(owner: UUID(), source: source) { token in
            XCTAssertNil(token); done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testLaterFutureOwnerCannotPreserveEarlierOnAfterItsOwnerCancels() {
        var router = OutputRouter(); let output = PlannedBoundaryFake(lead: 0.01), strip = UUID()
        router.attach(RuntimePorts.audioUnit(stripID: strip, boundary: output))
        let a = router.beginNotePlan(owner: UUID(), now: 10), b = router.beginNotePlan(owner: UUID(), now: 10)
        let event = MusicEvent.noteOn(destination: .audioUnit(stripID: strip), channel: 0, note: .init(number: 60, velocity: 100))
        _ = router.plan(.init(deadline: 11, event: event, token: a))
        _ = router.plan(.init(deadline: 11.005, event: event, token: b))
        router.advanceNotePlans(now: 10.996)
        XCTAssertEqual(output.receipts.count, 1)
        router.cancelNotePlans(owner: a.owner, now: 10.997)
        XCTAssertEqual(output.receipts.filter(\.cancel).count, 2, "Later B does not own A's earlier future start")
        XCTAssertEqual(router.nextPlannedDeadline, 11.005)
    }

    func testSharedOwnerDoesNotExpireAtEarlyOffHandoffAndReplansWhenOtherOwnerEnds() {
        var router = OutputRouter(); let output = PlannedBoundaryFake(lead: 0.01), strip = UUID()
        router.attach(RuntimePorts.audioUnit(stripID: strip, boundary: output))
        let a = router.beginNotePlan(owner: UUID(), now: 10), b = router.beginNotePlan(owner: UUID(), now: 10)
        let note = SpatialPlayedNote(number: 60, velocity: 100)
        let on = MusicEvent.noteOn(destination: .audioUnit(stripID: strip), channel: 0, note: note)
        let off = MusicEvent.noteOff(destination: .audioUnit(stripID: strip), channel: 0, note: note)
        _ = router.plan(.init(deadline: 11, event: on, token: a))
        _ = router.plan(.init(deadline: 11, event: on, token: b))
        router.advanceNotePlans(now: 10.991)
        _ = router.plan(.init(deadline: 11.005, event: off, token: a))
        router.advanceNotePlans(now: 10.996)
        router.cancelNotePlans(owner: b.owner, now: 10.997)
        XCTAssertEqual(output.receipts.filter(\.cancel).count, 0)
        router.advanceNotePlans(now: 10.997)
        XCTAssertEqual(output.receipts.last?.bytes, [0x80, 60, 0])
        XCTAssertEqual(output.receipts.last?.time, 11.005)
    }

    func testAudioOnlyCancellationPreservesMIDIAndOtherStripOwners() {
        var router = OutputRouter(); let midi = PlannedBoundaryFake(), a = PlannedBoundaryFake(), b = PlannedBoundaryFake()
        let first = UUID(), second = UUID()
        router.attach(RuntimePorts.midi(boundary: midi))
        router.attach(RuntimePorts.audioUnit(stripID: first, boundary: a))
        router.attach(RuntimePorts.audioUnit(stripID: second, boundary: b))
        let m = router.beginNotePlan(owner: UUID(), now: 10), x = router.beginNotePlan(owner: UUID(), now: 10), y = router.beginNotePlan(owner: UUID(), now: 10)
        _ = router.plan(.init(deadline: 11, event: on, token: m))
        for (strip, token) in [(first, x), (second, y)] {
            _ = router.plan(.init(deadline: 11, event: .noteOn(destination: .audioUnit(stripID: strip), channel: 0, note: .init(number: 60, velocity: 100)), token: token))
        }
        router.advanceNotePlans(now: 11)
        router.cancelAudioNotePlans(stripID: first, now: 11.001)
        XCTAssertEqual(a.receipts.last?.bytes, [0x80, 60, 0])
        XCTAssertEqual(midi.receipts.count, 1); XCTAssertEqual(b.receipts.count, 1)
        router.panic(audioOnly: true, now: 11.002)
        XCTAssertEqual(midi.receipts.count, 1)
        XCTAssertEqual(router.plan(.init(deadline: 12, event: off, token: m)), .accepted)
        router.advanceNotePlans(now: 12)
        XCTAssertEqual(midi.receipts.last?.bytes, [0x80, 60, 0])
    }
    func testRetireInvalidatesIdleRegisteredOwnerAndOwnerCannotCrossOutputs() {
        var router = OutputRouter(); let output = PlannedBoundaryFake(), id = UUID()
        router.attach(RuntimePorts.midi(id: id, boundary: output))
        let token = router.beginNotePlan(owner: UUID(), now: 10)
        _ = router.plan(.init(deadline: 11, event: on, token: token)); router.advanceNotePlans(now: 11)
        let foreign = MusicEvent.noteOn(destination: .audioUnit(stripID: UUID()), channel: 0, note: .init(number: 60, velocity: 100))
        XCTAssertEqual(router.plan(.init(deadline: 12, event: foreign, token: token)), .invalid)
        _ = router.plan(.init(deadline: 12, event: off, token: token)); router.advanceNotePlans(now: 12)
        XCTAssertNil(router.nextPlannedDeadline)
        _ = router.retire(id, now: 12)
        router.attach(RuntimePorts.midi(boundary: output))
        XCTAssertEqual(router.plan(.init(deadline: 13, event: on, token: token)), .stale)
    }

}
