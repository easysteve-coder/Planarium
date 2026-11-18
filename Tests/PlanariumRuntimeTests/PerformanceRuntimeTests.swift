import XCTest
import Dispatch
import Foundation
import PlanariumDomain
import PlanariumRuntime

final class ProgramChangeRuntimeTests: RuntimeTestCase {
    override func flush(_ runtime: PerformanceRuntime, file: StaticString = #filePath, line: UInt = #line) {
        // A barrier must not reconcile ports: that could heal a missing Panic
        // release before the assertion and turn a broken release path green.
        let done = expectation(description: "Pure queue acknowledgement")
        runtime.acknowledge {
            XCTAssertTrue(Thread.isMainThread, file: file, line: line)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
    private func instrument(_ selection: SpatialProgramChange = .init(program: 10), channel: UInt8 = 0,
                            target: Int32? = nil, revision: UInt64 = 1,
                            detection: DetectionConfiguration = .allStagesOff) throws -> CompiledInstrument {
        let a = PolarDeviceLattice(ring: 100, sector: 180)!, b = PolarDeviceLattice(ring: 120, sector: 180)!
        let route = SpatialRouting(target: .midiProgramChange(channel: channel), program: .programChange(selection))
        let layer = SpatialDocumentLayer(id: other, name: "Programs", color: .blue, isVisible: true, isActive: true,
            isLocked: false, isSoloed: false, cells: [a, b], routings: [route],
            cellOverrides: [b: [.init(target: route.target, value: .programChange(.init(program: 11, bankMSB: 3, bankLSB: 4)))]],
            midiTarget: target.map { .init(uniqueID: $0) })
        return try InstrumentCompiler.compile(.init(spatial: .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id),
            detection: detection, revision: .init(session: session, counter: revision)))
    }
    func testProgramBytesDisplayOriginsBanksAndExtremeChannels() throws {
        for origin in [false, true] {
            for channel: UInt8 in [0, 15] {
                for banks: (UInt8?, UInt8?) in [(nil, nil), (2, nil), (nil, 3), (2, 3)] {
                    for program: UInt8 in [0, 127] {
                        let selection = SpatialProgramChange(program: program, countsFromOne: origin, bankMSB: banks.0, bankLSB: banks.1)
                        XCTAssertEqual(selection.displayedProgram, Int(program) + (origin ? 1 : 0))
                        let sink = FakeBoundary(), c = composition(midi: sink)
                        try start(c, instrument: instrument(selection, channel: channel))
                        var expected: [[UInt8]] = []
                        if let msb = banks.0 { expected.append([0xB0 | channel, 0, msb]) }
                        if let lsb = banks.1 { expected.append([0xB0 | channel, 32, lsb]) }
                        expected.append([0xC0 | channel, program])
                        XCTAssertEqual(sink.receipts.map(\.bytes), expected, "Bank must precede PC")
                        c.runtime.stop(); flush(c.runtime)
                    }
                }
            }
        }
    }
    func testEntryExitReentryDifferentCellAndDisplayOnlyChangeDoNotReload() throws {
        let sink = FakeBoundary(), c = composition(midi: sink)
        try start(c, instrument: instrument())
        c.runtime.frame(profile(2)); c.runtime.frame(profile(3, empty: true)); c.runtime.frame(profile(4)); flush(c.runtime)
        XCTAssertEqual(sink.receipts.map(\.bytes), [[0xC0, 10]])
        c.runtime.frame(profile(5, ring: 120)); flush(c.runtime)
        XCTAssertEqual(sink.receipts.map(\.bytes), [[0xC0, 10], [0xB0, 0, 3], [0xB0, 32, 4], [0xC0, 11]])
        c.runtime.frame(profile(6)); flush(c.runtime)
        XCTAssertEqual(sink.receipts.last?.bytes, [0xC0, 10])
        let count = sink.receipts.count
        c.runtime.install(try instrument(.init(program: 10, countsFromOne: false), revision: 2))
        c.runtime.frame(profile(7)); flush(c.runtime)
        XCTAssertEqual(sink.receipts.count, count, "Counting is not a wire change")
    }
    func testStopPanicSleepAndPresetResetMemoryWithoutSendingProgramOrBankOnRelease() throws {
        for edge in [PlayInput.stop, .panic, .sleep, .terminate, .inputLost] {
            let sink = FakeBoundary(), port = RuntimePorts.midi(boundary: sink)
            let c = PerformanceRuntimeFactory.make(clock: FakeClock(), ports: [port])
            try start(c, instrument: instrument(.init(program: 6, bankMSB: 2, bankLSB: 3)))
            let before = sink.receipts.count
            switch edge {
            case .stop: c.runtime.stop()
            case .panic: c.runtime.panic()
            case .sleep: c.runtime.sleep()
            case .terminate: c.runtime.terminate {}
            default: c.runtime.sessionEnded(session, reason: .failure)
            }
            flush(c.runtime)
            XCTAssertTrue(sink.receipts.dropFirst(before).allSatisfy { $0.bytes.count == 3 && $0.bytes[1] == 123 })
            if case .terminate = edge { continue }
            if case .sleep = edge { c.runtime.wake() }
            if case .inputLost = edge { c.runtime.sessionBegan(session) }
            c.runtime.frame(profile(2, empty: true)); c.runtime.frame(profile(3)); flush(c.runtime)
            let pcs = sink.receipts.filter { $0.bytes.first == 0xC0 }.count
            if case .inputLost = edge { XCTAssertEqual(pcs, 1, "Loss has no reset or release PC") }
            else { XCTAssertEqual(pcs, 2, "Explicit release resets program memory") }
        }
        let sink = FakeBoundary(), c = composition(midi: sink)
        try start(c, instrument: instrument())
        c.runtime.stop(); c.runtime.install(try instrument(revision: 2)); c.runtime.frame(profile(2)); flush(c.runtime)
        XCTAssertEqual(sink.receipts.filter { $0.bytes.first == 0xC0 }.count, 2)
    }
    func testUnavailableSendIsNotRememberedAndEndpointsAndChannelsAreIndependent() {
        let one = FakeBoundary(), two = FakeBoundary()
        var router = OutputRouter()
        router.attach(RuntimePorts.midi(boundary: one, destination: .midiEndpoint(uniqueID: 1)))
        router.attach(RuntimePorts.midi(boundary: two, destination: .midiEndpoint(uniqueID: 2)))
        func event(_ target: Int32, _ channel: UInt8) -> MusicEvent {
            .programChange(destination: .midiEndpoint(uniqueID: target), channel: channel, selection: .init(program: 5, bankLSB: 127))
        }
        one.result = .unbound
        router.route([event(1, 0), event(2, 0)], sounding: [], allowOn: false)
        XCTAssertTrue(one.receipts.isEmpty); XCTAssertEqual(two.receipts.count, 2)
        one.result = .sent
        router.route([event(1, 0), event(2, 0), event(1, 15)], sounding: [], allowOn: false)
        XCTAssertEqual(one.receipts.map(\.bytes), [[0xB0, 32, 127], [0xC0, 5], [0xBF, 32, 127], [0xCF, 5]])
        XCTAssertEqual(two.receipts.count, 2)
    }
    func testProgramChangeWaitsForTheSameConfirmedCellSwitchAsNotes() throws {
        let sink = FakeBoundary(), clock = FakeClock(), c = composition(clock: clock, midi: sink)
        try start(c, instrument: instrument(detection: .allStagesOff.replacingCellSelection(.init(confirmationProfiles: 2))))
        XCTAssertEqual(sink.receipts.map(\.bytes), [[0xC0, 10]])
        c.runtime.frame(profile(2, ring: 120)); flush(c.runtime)
        XCTAssertEqual(sink.receipts.count, 1, "Unconfirmed candidate cannot send PC")
        c.runtime.frame(profile(3, ring: 120)); flush(c.runtime)
        XCTAssertEqual(sink.receipts.last?.bytes, [0xC0, 11])
        let count = sink.receipts.count
        clock.advance(11); flush(c.runtime); flush(c.runtime)
        XCTAssertEqual(sink.receipts.count, count, "No release/prognosis PC")
    }
    func testPerLayerCCAndNotesReachOnlyTheirEndpointAndPanicReleasesNotes() throws {
        let sum = FakeBoundary(), layerSink = FakeBoundary(), clock = FakeClock()
        let c = PerformanceRuntimeFactory.make(clock: clock, ports: [RuntimePorts.midi(boundary: sum),
            RuntimePorts.midi(boundary: layerSink, destination: .midiEndpoint(uniqueID: 9))])
        let layer = SpatialDocumentLayer(id: other, name: "CC and note", color: .blue, isVisible: true, isActive: true,
            isLocked: false, isSoloed: false, cells: [PolarDeviceLattice(ring: 100, sector: 180)!],
            routings: [.init(target: .midiCC(channel: 15, controller: 74), program: .constant(0.5)),
                       .init(target: .midiNote(channel: 15), program: .singleNote(note: 60, velocity: 100, transition: .legato))],
            cellOverrides: [:], midiTarget: .init(uniqueID: 9))
        let document = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id), detection: .allStagesOff, revision: .init(session: session, counter: 1))
        try start(c, instrument: InstrumentCompiler.compile(document))
        XCTAssertTrue(sum.receipts.isEmpty)
        XCTAssertTrue(layerSink.receipts.contains { $0.bytes == [0xBF, 74, 64] })
        XCTAssertEqual(layerSink.sounding.count, 1)
        c.runtime.panic(); flush(c.runtime)
        XCTAssertTrue(layerSink.sounding.isEmpty)
    }
}

final class PerformanceRuntimeTests: RuntimeTestCase {
    func testAudioConfigurationRemovesAudioOverlapDeadlineButRetainsMIDITail() throws {
        for audioOnly in [false, true] {
            let clock = FakeClock(), midi = FakeBoundary(), au = FakeBoundary(), c = composition(clock: clock, midi: midi, au: au)
            let a = PolarDeviceLattice(ring: 100, sector: 180)!, b = PolarDeviceLattice(ring: 120, sector: 180)!
            let targets: [SpatialRoutingTarget] = audioOnly ? [.audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)] :
                [.midiNote(channel: 0), .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)]
            let layer = SpatialDocumentLayer(id: UUID(), name: "Overlap", color: .blue, isVisible: true,
                isActive: true, isLocked: false, isSoloed: false, cells: [a, b],
                routings: targets.map { .init(target: $0, program: .singleNote(note: 60, velocity: 100, transition: .overlap(milliseconds: 20))) },
                cellOverrides: [b: targets.map { .init(target: $0, value: .note(number: 64, velocity: 100)) }])
            let document = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id),
                detection: .allStagesOff, revision: .init(session: session, counter: 1))
            try start(c, instrument: InstrumentCompiler.compile(document))
            c.runtime.frame(profile(2, ring: 120, time: 10.01)); flush(c.runtime)
            XCTAssertEqual(au.sounding.count, 2)
            XCTAssertTrue(clock.deadlines.contains { abs($0 - 10.03) < 1e-8 })
            c.runtime.releaseAudioForConfigurationChange(); flush(c.runtime)
            XCTAssertTrue(au.sounding.isEmpty)
            XCTAssertEqual(clock.deadlines.contains { abs($0 - 10.03) < 1e-8 }, !audioOnly)
            let before = midi.receipts.count
            clock.advance(10.04); flush(c.runtime); flush(c.runtime)
            if !audioOnly {
                XCTAssertEqual(midi.sounding.count, 1)
                XCTAssertEqual(midi.receipts.count, before + 1)
                XCTAssertEqual(midi.receipts.last?.bytes[0], 0x80)
            }
        }
    }
    func testAudioConfigurationReleasePreservesMIDIForGateHoldAndToggle() throws {
        for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
            let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
            try start(c, instrument: compiled(transition: transition))
            let before = midi.receipts.map(\.bytes)
            XCTAssertFalse(au.sounding.isEmpty)
            c.runtime.releaseAudioForConfigurationChange(); flush(c.runtime)
            XCTAssertTrue(au.sounding.isEmpty)
            XCTAssertFalse(midi.sounding.isEmpty)
            XCTAssertEqual(midi.receipts.map(\.bytes), before)
            XCTAssertEqual(c.mailbox.read()?.ports.first { $0.id == auID }?.soundingNotes, 0)
            c.runtime.stop(); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty)
        }
    }
    func testRecoveryRemembersCompletedPhaseAndRefusedBendCannotBeHiddenByLaterSuccess() {
        let sink = FakeBoundary()
        sink.setHook { bytes in if bytes == [0xB0, 64, 0] { sink.result = .faulted } }
        var port = RuntimePorts.midi(boundary: sink, resetOnBind: true)
        let note = MusicEvent.noteOn(destination: .midi, channel: 3, note: .init(number: 60, velocity: 100))
        XCTAssertEqual(port.send(note), .faulted)
        XCTAssertEqual(sink.receipts.map(\.bytes), [[0xB0, 64, 0]])
        XCTAssertEqual(port.display.soundingNotes, 0)
        sink.setHook(nil); sink.result = .sent
        XCTAssertEqual(port.send(note), .sent)
        XCTAssertEqual(sink.receipts.map(\.bytes), (UInt8(0)...15).flatMap { MusicEventMIDIEncoding.releaseMessages(channel: $0) } + [[0x93, 60, 100]])
    }

    func testFailedMIDIRecoveryResetBlocksOnAndRetriesBeforeOn() {
        let midi = FakeBoundary()
        midi.result = .unbound
        var port = RuntimePorts.midi(boundary: midi, resetOnBind: true)
        let note = SpatialPlayedNote(number: 60, velocity: 100)
        XCTAssertEqual(port.send(.noteOn(destination: .midi, channel: 3, note: note)), .unbound)
        XCTAssertTrue(midi.receipts.isEmpty); XCTAssertEqual(port.display.soundingNotes, 0)
        midi.result = .sent
        XCTAssertEqual(port.send(.noteOn(destination: .midi, channel: 3, note: note)), .sent)
        XCTAssertEqual(midi.receipts.map(\.bytes), (UInt8(0)...15).flatMap { MusicEventMIDIEncoding.releaseMessages(channel: $0) } + [[0x93, 60, 100]])
    }
    func testSimulated90And361ModeSwitchReleasesBothSinksAndKeepsCellLocation() throws {
        for counts in [[90, 361, 90], [361, 90, 361]] {
            let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
            let instrument = try compiled(); c.runtime.install(instrument)
            var previousSession: UUID?, previousCells: Set<PolarDeviceLattice>?
            for (index, count) in counts.enumerated() {
                if let previousSession {
                    c.runtime.sessionEnded(previousSession); flush(c.runtime)
                    XCTAssertTrue(midi.sounding.isEmpty, "Mode switch releases MIDI")
                    XCTAssertTrue(au.sounding.isEmpty, "Mode switch releases AU")
                }
                let id = UUID(); c.runtime.sessionBegan(id)
                let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "segmentMinimum" : "fullScan",
                    pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
                let points = (0..<count).map { order in
                    DeviceTickMeasurement(order: order, ticks: geometry.tickSpan(at: order)!, rawCentimeters: order == count / 2 ? 100 : 300)!
                }
                c.runtime.frame(.init(sessionID: id, sequence: UInt64(index + 1), time: 10, measurements: points, geometry: geometry)); flush(c.runtime)
                XCTAssertFalse(midi.sounding.isEmpty); XCTAssertFalse(au.sounding.isEmpty)
                let cells = Set(try XCTUnwrap(c.mailbox.read()).activeCells.map(\.cell))
                XCTAssertFalse(cells.isEmpty)
                if let previousCells { XCTAssertEqual(cells, previousCells, "Spatial addresses remain stable across measurement modes") }
                previousCells = cells; previousSession = id
            }
            c.runtime.sessionEnded(previousSession!); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
        }
    }
    func testFactoryUsesSourceAndBothBoundariesAndPublishesCompleteSnapshot() throws {
        let source = FakeProfileSource(), midi = FakeBoundary(), au = FakeBoundary()
        let c = composition(midi: midi, au: au, source: source)
        c.runtime.install(try compiled())
        source.deliver(.began(session)); source.deliver(.frame(profile(42)))
        flush(c.runtime)
        let display = try XCTUnwrap(c.mailbox.read())
        XCTAssertEqual(display.profile?.sequence, 42)
        XCTAssertEqual(display.activeCells.count, 1)
        XCTAssertEqual(display.revision?.counter, 1)
        XCTAssertEqual(display.ports.map(\.soundingNotes), [1, 1])
        XCTAssertEqual(display.ports.map(\.counts.sent), [1, 1])
        XCTAssertEqual(midi.sounding.count, 1); XCTAssertEqual(au.sounding.count, 1)
        source.deliver(.ended(session)); flush(c.runtime)
        XCTAssertNil(c.mailbox.read()?.profile)
        XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
    }
    func testProfilesRequireBeganAndRejectLateFramesAcrossEndAndNewSession() throws {
        let midi = FakeBoundary(), c = composition(midi: midi)
        c.runtime.install(try compiled()); c.runtime.frame(profile()); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty)
        try start(c)
        c.runtime.sessionEnded(session); c.runtime.frame(profile(2)); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty)
        c.runtime.sessionBegan(other); c.runtime.frame(profile(3)); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty)
        c.runtime.frame(profile(4, session: other)); flush(c.runtime)
        XCTAssertEqual(midi.sounding.count, 1)
        XCTAssertEqual(c.mailbox.read()?.discardedProfiles, 3)
    }
    func testEveryWaitingProfileWithinBudgetRunsInArrivalOrderBeforeCommandsAndSessionBoundary() throws {
        let midi = FakeBoundary(), c = composition(midi: midi)
        let entered = expectation(description: "Q held in fake send")
        let gate = DispatchSemaphore(value: 0)
        midi.setHook { bytes in
            if bytes[0] & 0xF0 == 0x90 { entered.fulfill(); gate.wait() }
        }
        c.runtime.install(try compiled()); c.runtime.sessionBegan(session); c.runtime.frame(profile())
        wait(for: [entered], timeout: 10)
        midi.setHook(nil)
        let startTime = DispatchTime.now().uptimeNanoseconds
        for i in 2...41 { c.runtime.frame(profile(UInt64(i), ring: i % 2 == 0 ? 120 : 100)) }
        c.runtime.sessionEnded(session)
        c.runtime.install(try compiled(2)); c.runtime.panic()
        c.runtime.frame(profile(42)) // arrives AFTER end: never bypass end
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1e6, 100)
        gate.signal(); flush(c.runtime)
        XCTAssertEqual(c.mailbox.read()?.processedProfiles, 41)
        XCTAssertEqual(c.mailbox.read()?.revision?.counter, 2)
        XCTAssertEqual(c.mailbox.read()?.discardedProfiles, 1)
        XCTAssertEqual(midi.receipts.filter { $0.bytes[0] & 0xF0 == 0x90 }.count, 41)
        let notes = midi.receipts.filter { $0.bytes[0] & 0xF0 == 0x90 }.map { $0.bytes[1] }
        XCTAssertEqual(notes, (1...41).map { UInt8($0 % 2 == 0 ? 72 : 60) })
        XCTAssertEqual(c.mailbox.read()?.overflowProfiles, 0)
        XCTAssertTrue(midi.sounding.isEmpty)
        XCTAssertEqual(midi.receipts.filter { $0.bytes[0] & 0xF0 == 0xB0 && $0.bytes[1] == 123 }.count, 16)
    }
    func testAttachWhileHeldStartsOnlyAtNextProfileAndDuplicateAttachDoesNotReplace() throws {
        let midi = FakeBoundary(), c = composition(midi: midi)
        try start(c)
        let extra = FakeBoundary(), id = UUID()
        c.runtime.attach(RuntimePorts.midi(id: id, boundary: extra)); flush(c.runtime)
        XCTAssertTrue(extra.receipts.isEmpty)
        c.runtime.attach(RuntimePorts.midi(id: id, boundary: FakeBoundary())); flush(c.runtime)
        c.runtime.frame(profile(2)); flush(c.runtime)
        XCTAssertEqual(extra.sounding.count, 1)
        XCTAssertEqual(midi.receipts.count, 1)
        XCTAssertEqual(c.mailbox.read()?.ports.count, 3)
    }
    func testRetireOffPrecedesAckAndOtherPortKeepsPlaying() throws {
        let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
        try start(c)
        let done = expectation(description: "retired")
        c.runtime.retire(auID) {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(au.sounding.isEmpty)
            XCTAssertEqual(au.receipts.last?.bytes[0], 0x80)
            XCTAssertEqual(midi.sounding.count, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(c.mailbox.read()?.ports.count, 1)
        c.runtime.frame(profile(2, ring: 120)); flush(c.runtime)
        XCTAssertEqual(au.receipts.count, 2)
        XCTAssertEqual(midi.sounding.count, 1)
    }
    func testRetireBeforeAndAfterAttachAndTerminateBeforeAndAfterProfile() throws {
        for retireFirst in [false, true] {
            let midi = FakeBoundary(), c = PerformanceRuntimeFactory.make(clock: FakeClock())
            let done = expectation(description: "retire in either order")
            if retireFirst { c.runtime.retire(midiID) { done.fulfill() } }
            c.runtime.attach(RuntimePorts.midi(id: midiID, boundary: midi))
            try start(c)
            if !retireFirst { c.runtime.retire(midiID) { done.fulfill() } }
            wait(for: [done], timeout: 10)
            if retireFirst { XCTAssertEqual(midi.sounding.count, 1) }
            else { XCTAssertTrue(midi.sounding.isEmpty) }
            let ended = expectation(description: "terminate ack")
            c.runtime.terminate { XCTAssertTrue(midi.sounding.isEmpty); ended.fulfill() }
            wait(for: [ended], timeout: 10)
            c.runtime.frame(profile(2)); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty)
            c.runtime.sessionBegan(other); c.runtime.frame(profile(3, session: other)); flush(c.runtime)
            XCTAssertEqual(midi.sounding.count, retireFirst ? 1 : 0)
            c.runtime.stop(); flush(c.runtime)
        }
    }
    func testUnboundAndFaultedPortAreLocalAndRecoverOnActualProfile() throws {
        let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
        midi.result = .unbound
        try start(c)
        XCTAssertEqual(au.sounding.count, 1)
        XCTAssertEqual(c.mailbox.read()?.ports[0].counts.unbound, 1)
        XCTAssertEqual(c.mailbox.read()?.ports[0].result, .unbound)
        midi.result = .faulted; c.runtime.frame(profile(2)); flush(c.runtime)
        XCTAssertEqual(c.mailbox.read()?.ports[0].counts.faulted, 1)
        XCTAssertEqual(au.receipts.count, 1)
        midi.result = .sent; c.runtime.frame(profile(3)); flush(c.runtime)
        XCTAssertEqual(midi.sounding.count, 1)
        XCTAssertEqual(c.mailbox.read()?.ports[0].counts.sent, 1)
        c.runtime.panic(); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
        c.runtime.frame(profile(4)); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
        c.runtime.frame(profile(5, empty: true)); flush(c.runtime)
        c.runtime.frame(profile(6)); flush(c.runtime)
        XCTAssertEqual(midi.sounding.count, 1); XCTAssertEqual(au.sounding.count, 1)
    }
    func testFailedOffRemainsInPortBookAndRetriesWithoutBlockingOtherPort() throws {
        let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
        try start(c)
        midi.result = .faulted; c.runtime.stop(); flush(c.runtime)
        XCTAssertTrue(au.sounding.isEmpty)
        XCTAssertEqual(c.mailbox.read()?.ports[0].soundingNotes, 1)
        midi.result = .sent; c.runtime.wake(); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty)
        XCTAssertEqual(c.mailbox.read()?.ports[0].soundingNotes, 0)
        c.runtime.frame(profile(2)); flush(c.runtime)
        XCTAssertEqual(midi.sounding.count, 1)
    }
    func testOverlapThenStaleDeadlineWithoutAnyFurtherProfileAndNoPermanentTimer() throws {
        let clock = FakeClock(), midi = FakeBoundary(), c = composition(clock: clock, midi: midi)
        XCTAssertTrue(clock.deadlines.isEmpty)
        try start(c, instrument: compiled(transition: .overlap(milliseconds: 20)))
        c.runtime.frame(profile(2, ring: 120, time: 10.01)); flush(c.runtime)
        XCTAssertEqual(midi.sounding.count, 2)
        XCTAssertEqual(clock.deadlines.count, 1)
        clock.advance(10.04)
        // fake fires on Q; its callback enqueues, so two flushes cover arrival.
        flush(c.runtime); flush(c.runtime)
        XCTAssertEqual(midi.sounding.count, 1)
        XCTAssertEqual(clock.deadlines.count, 1)
        clock.advance(try XCTUnwrap(clock.deadlines.first) + 0.01)
        flush(c.runtime); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty)
        XCTAssertTrue(clock.deadlines.isEmpty)
    }
    func testCanceledDeadlineCannotReleaseNewerProfileOrRearmAfterStop() throws {
        let clock = FakeClock(), midi = FakeBoundary(), c = composition(clock: clock, midi: midi)
        try start(c)
        let old = try XCTUnwrap(clock.deadlines.first)
        c.runtime.frame(profile(2, time: 10.1)); flush(c.runtime)
        clock.advance(old); flush(c.runtime); flush(c.runtime)
        XCTAssertEqual(midi.sounding.count, 1)
        c.runtime.stop(); flush(c.runtime)
        XCTAssertTrue(clock.deadlines.isEmpty)
        clock.advance(100); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty)
    }
    func testCommandsWithoutInstrumentAreTotalAndReturnThroughInstall() throws {
        let c = composition()
        c.runtime.panic(); c.runtime.stop(); c.runtime.sleep(); c.runtime.wake()
        c.runtime.sessionEnded(session); c.runtime.roomContour(nil)
        c.runtime.detectionChanged(try compiled(notes: false)); flush(c.runtime)
        try start(c, instrument: compiled(2))
        XCTAssertEqual(c.mailbox.read()?.ports.map(\.soundingNotes), [1, 1])
    }
    func testPortAdaptersEncodeChannelCCPitchPressurePanicAndAUParameter() throws {
        let id = UUID()
        XCTAssertEqual(MusicEventMIDIEncoding.bytes(.scalar(routingID: id, target: .midiCC(channel: 31, controller: 255), value: 0.5)), [0xBF, 127, 64])
        XCTAssertEqual(MusicEventMIDIEncoding.bytes(.scalar(routingID: id, target: .midiPitchBend(channel: 0), value: 0.5)), [0xE0, 0, 64])
        XCTAssertEqual(MusicEventMIDIEncoding.bytes(.scalar(routingID: id, target: .midiChannelPressure(channel: 2), value: 2)), [0xD2, 127])
        XCTAssertNil(MusicEventMIDIEncoding.bytes(.scalar(routingID: id, target: .midiPitchBend(channel: 0), value: .nan)))
        let target = SpatialAudioUnitParameterTarget(component: .init(componentType: 1, componentSubType: 2, componentManufacturer: 3), address: 42, identifier: "gain", displayName: "Gain", stripID: InstrumentChannel.legacyID)
        let boundary = FakeBoundary()
        var port = RuntimePorts.audioUnit(boundary: boundary)
        XCTAssertEqual(port.send(.scalar(routingID: id, target: .audioUnitParameter(target), value: 0.7)), .sent)
        XCTAssertEqual(boundary.parameters.first?.0, target)
        XCTAssertEqual(boundary.parameters.first?.1, 0.7)
    }
}

extension PerformanceRuntimeTests {
    func testBacklogKeepsPanicRetireAndSessionCommandsInBothOrdersAndRejectsForeignFlood() throws {
        for commandsFirst in [false, true] {
            let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
            let entered = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
            midi.setHook { bytes in if bytes[0] & 0xf0 == 0x90 {
                entered.signal(); _ = gate.wait(timeout: .now() + 10)
            } }
            defer { gate.signal() }
            c.runtime.install(try compiled()); c.runtime.sessionBegan(session); c.runtime.frame(profile())
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success); midi.setHook(nil)
            let retired = expectation(description: "Retire retained through backlog")
            func commands() {
                c.runtime.panic()
                c.runtime.retire(auID) { XCTAssertTrue(au.sounding.isEmpty); retired.fulfill() }
                c.runtime.sessionEnded(session, reason: .failure)
                c.runtime.sessionBegan(other)
            }
            if commandsFirst { commands() }
            for sequence in 2...52 { c.runtime.frame(profile(UInt64(sequence), session: commandsFirst ? other : session)) }
            if !commandsFirst { commands() }
            XCTAssertEqual(c.runtime.inputBacklogStatus, .overloaded)
            gate.signal(); wait(for: [retired], timeout: 10); flush(c.runtime); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
            XCTAssertEqual(c.mailbox.read()?.sessionID, other)
            XCTAssertEqual(c.mailbox.read()?.ports.count, 1)
            XCTAssertEqual(midi.receipts.filter { $0.bytes[0] & 0xf0 == 0xb0 && $0.bytes[1] == 123 }.count, 16)
            let overflow = c.runtime.diagnostics.overflowProfiles
            for sequence in 100...200 { c.runtime.frame(profile(UInt64(sequence))) }
            c.runtime.frame(profile(201, session: other)); flush(c.runtime)
            XCTAssertEqual(c.runtime.diagnostics.overflowProfiles, overflow, "Old-session flood cannot overload or purge new input")
            XCTAssertEqual(midi.sounding.count, 1); XCTAssertTrue(au.sounding.isEmpty)
            c.runtime.stop(); flush(c.runtime)
        }
    }
    func testBoundedFIFOOverflowIsVisibleAndDiscardsBacklogBeforeRelease() throws {
        let midi = FakeBoundary(), mailbox = DisplayFrameMailbox()
        let runtime = PerformanceRuntime(clock: FakeClock(), mailbox: mailbox, profileCapacity: 2)
        runtime.attach(RuntimePorts.midi(boundary: midi))
        let entered = expectation(description: "Q held"), gate = DispatchSemaphore(value: 0)
        midi.setHook { bytes in if bytes[0] & 0xf0 == 0x90 { entered.fulfill(); gate.wait() } }
        runtime.install(try compiled()); runtime.sessionBegan(session); runtime.frame(profile())
        wait(for: [entered], timeout: 5); midi.setHook(nil)
        for i in 2...5 { runtime.frame(profile(UInt64(i))) }
        gate.signal(); flush(runtime)
        XCTAssertEqual(mailbox.read()?.processedProfiles, 1)
        XCTAssertEqual(mailbox.read()?.overflowProfiles, 2)
        XCTAssertEqual(mailbox.read()?.discardedProfiles, 4)
        XCTAssertTrue(midi.sounding.isEmpty)
    }
}

extension RuntimeModelTests {
    func testRetireAckCannotOvertakeBlockedNoteOff() throws {
        let au = FakeBoundary(), c = composition(au: au)
        try start(c)
        let entered = expectation(description: "retire Off entered boundary")
        let done = expectation(description: "retire acknowledged")
        let gate = DispatchSemaphore(value: 0), returned = TestFlag(), acknowledged = TestFlag()
        au.setHook { bytes in
            if bytes[0] & 0xF0 == 0x80 {
                entered.fulfill()
                gate.wait()
                returned.set()
            }
        }
        c.runtime.retire(auID) {
            acknowledged.set()
            XCTAssertTrue(returned.value, "Ack must follow the completed Off send")
            done.fulfill()
        }
        wait(for: [entered], timeout: 10)
        // Give Main a turn while Q is held INSIDE the fake Off send. A wrongly
        // scheduled early ack becomes visible deterministically under TSan too.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        XCTAssertFalse(acknowledged.value, "Main must not free the instance during Off")
        gate.signal()
        wait(for: [done], timeout: 10)
    }
}

extension PerformanceRuntimeTests {
    func testProductionClockSchedulesStaleOnceWithoutPolling() throws {
        let midi = FakeBoundary(), off = expectation(description: "one-shot stale Off")
        let clock = MonotonicRuntimeClock()
        let c = PerformanceRuntimeFactory.make(clock: clock, ports: [RuntimePorts.midi(boundary: midi)])
        midi.setHook { bytes in if bytes[0] & 0xF0 == 0x80 { off.fulfill() } }
        c.runtime.install(try compiled()); c.runtime.sessionBegan(session)
        c.runtime.frame(profile(time: clock.now)); flush(c.runtime)
        wait(for: [off], timeout: 3)
        flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty)
    }
}
// Test-only synchronized flags used to observe callback ordering across Q/Main.
private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}

extension PerformanceRuntimeTests {
    func testEmptyProfileSnapshotRetainsActualInputAndClearsSelection() throws {
        let c = composition()
        try start(c)
        c.runtime.frame(profile(99, empty: true)); flush(c.runtime)
        XCTAssertEqual(c.mailbox.read()?.profile?.sequence, 99)
        XCTAssertEqual(c.mailbox.read()?.profile?.measurements, [])
        XCTAssertEqual(c.mailbox.read()?.activeCells.count, 0)
        XCTAssertEqual(c.mailbox.read()?.ports.map(\.soundingNotes), [0, 0])
    }
    func testRetireIncludesOverlapTailsAndPublishesFinalFaultReceipt() throws {
        let clock = FakeClock(), midi = FakeBoundary(), au = FakeBoundary()
        let c = composition(clock: clock, midi: midi, au: au)
        try start(c, instrument: compiled(transition: .overlap(milliseconds: 20)))
        c.runtime.frame(profile(2, ring: 120, time: 10.01)); flush(c.runtime)
        XCTAssertEqual(au.sounding.count, 2)
        let retired = expectation(description: "overlap tails retired")
        c.runtime.retire(auID) { XCTAssertTrue(au.sounding.isEmpty); retired.fulfill() }
        wait(for: [retired], timeout: 10)
        XCTAssertEqual(c.mailbox.read()?.retiredPort?.counts.sent, 4)
        XCTAssertEqual(midi.sounding.count, 2)
        midi.result = .faulted
        let failed = expectation(description: "failed Off is still acknowledged after attempt")
        c.runtime.retire(midiID) { failed.fulfill() }
        wait(for: [failed], timeout: 10)
        let receipt = try XCTUnwrap(c.mailbox.read()?.retiredPort)
        XCTAssertEqual(receipt.id, midiID)
        XCTAssertEqual(receipt.counts.faulted, 2)
        XCTAssertEqual(receipt.soundingNotes, 2)
        XCTAssertEqual(receipt.result, .faulted)
        XCTAssertEqual(c.mailbox.read()?.ports.count, 0)
    }
    func testFaultedAUPortIsLocalAndRecoversOnNextMeasuredProfile() throws {
        let au = FakeBoundary(), midi = FakeBoundary(), c = composition(midi: midi, au: au)
        au.result = .faulted
        try start(c)
        XCTAssertEqual(midi.sounding.count, 1)
        XCTAssertTrue(au.sounding.isEmpty)
        XCTAssertEqual(c.mailbox.read()?.ports[1].counts.faulted, 1)
        au.result = .sent
        c.runtime.frame(profile(2)); flush(c.runtime)
        XCTAssertEqual(au.sounding.count, 1)
        XCTAssertEqual(midi.receipts.count, 1)
        c.runtime.stop(); flush(c.runtime)
        XCTAssertTrue(au.sounding.isEmpty); XCTAssertTrue(midi.sounding.isEmpty)
    }
}

extension PerformanceRuntimeTests {
    func testConsumedAttachDoesNotRetainBoundaryPastRetireAckBehindBacklog() throws {
        let midi = FakeBoundary(), c = composition(midi: midi)
        let entered = expectation(description: "initial Q hold"), gate = DispatchSemaphore(value: 0)
        midi.setHook { bytes in if bytes[0] & 0xF0 == 0x90 { entered.fulfill(); gate.wait() } }
        c.runtime.install(try compiled()); c.runtime.sessionBegan(session); c.runtime.frame(profile())
        wait(for: [entered], timeout: 10)
        let stoppedInsideOff = expectation(description: "Q still behind commands")
        let offGate = DispatchSemaphore(value: 0)
        midi.setHook { bytes in if bytes[0] & 0xF0 == 0x80 { stoppedInsideOff.fulfill(); offGate.wait() } }
        let destroyed = expectation(description: "boundary released at retire")
        var witness: BoundaryLifetimeWitness? = .init { destroyed.fulfill() }
        weak var observed: BoundaryLifetimeWitness?
        observed = witness
        let au = FakeBoundary(), newID = UUID()
        var port: OutputPort? = .init(id: newID, destination: .audioUnit(stripID: InstrumentChannel.legacyID)) { [held = witness!] event in
            held.keepAlive()
            return au.scheduleMIDI(bytes: MusicEventMIDIEncoding.bytes(event)!)
        }
        c.runtime.attach(port!); port = nil; witness = nil
        c.runtime.frame(profile(2))
        let retired = expectation(description: "retired with later commands pending")
        c.runtime.retire(newID) { retired.fulfill() }
        c.runtime.panic(); c.runtime.stop()
        gate.signal()
        wait(for: [retired, stoppedInsideOff], timeout: 10)
        XCTAssertNil(observed, "The consumed attach must not retain the retired capability")
        // Unblock Q even if an assertion failed; then verify destruction too.
        offGate.signal()
        wait(for: [destroyed], timeout: 10)
        flush(c.runtime)
    }
}
private final class BoundaryLifetimeWitness: Sendable {
    private let destroyed: @Sendable () -> Void
    init(_ destroyed: @escaping @Sendable () -> Void) { self.destroyed = destroyed }
    func keepAlive() {}
    deinit { destroyed() }
}


extension PerformanceRuntimeTests {
    private func p8GeometryFrame(count: Int, sequence: UInt64, ring: UInt16) -> ProfileFrame {
        let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "segmentMinimum" : "fullScan",
            pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
        let order = count == 90 ? 45 : 180
        return .init(sessionID: session, sequence: sequence, time: 10,
            measurements: [DeviceTickMeasurement(order: order, ticks: geometry.tickSpan(at: order)!, rawCentimeters: ring)!], geometry: geometry)
    }
    func testP8LatencyFixtureActuallyRunsEveryDetectionMethodFor90And361() throws {
        for count in [90, 361] {
            for (configuration, expected) in [(DetectionConfiguration.ownerDefaults, 112.0),
                (.ownerDefaults.replacingTemporalSmoothing(.mean(window: 4)), 104.0),
                (.ownerDefaults.replacingTemporalSmoothing(.median(window: 4)), 100.0),
                (.ownerDefaults.replacingTemporalSmoothing(.exponential(alpha: 0.5)), 106.0)] {
                let c = composition()
                let instrument = try compiled(detection: configuration)
                XCTAssertEqual(instrument.detection, configuration)
                c.runtime.install(instrument); c.runtime.sessionBegan(session)
                for (i, distance) in [UInt16(100), 100, 112].enumerated() {
                    c.runtime.frame(p8GeometryFrame(count: count, sequence: UInt64(i + 1), ring: distance)); flush(c.runtime)
                }
                let display = try XCTUnwrap(c.mailbox.read())
                XCTAssertEqual(display.profile?.geometry.pointCount, count)
                XCTAssertEqual(display.processedProfiles, 3)
                XCTAssertEqual(display.selection.objects.count, 1)
                XCTAssertEqual(try XCTUnwrap(display.selection.representative).distanceCentimeters, expected, accuracy: 1e-9)
                c.runtime.stop(); flush(c.runtime)
            }
        }
    }
    func testP8EveryTransitionLeavesAreaAndHoldSurvivesOnlyUnintentionalStaleFor90And361() throws {
        for count in [90, 361] {
            for mode in [SpatialNoteTransition.retrigger, .legato, .overlap(milliseconds: 100), .holdUntilNext] {
                for edge in 0..<8 {
                    let clock = FakeClock(), midi = FakeBoundary(), au = FakeBoundary(), source = FakeProfileSource()
                    let c = composition(clock: clock, midi: midi, au: au, source: source)
                    c.runtime.install(try compiled(transition: mode)); source.deliver(.began(session))
                    source.deliver(.frame(p8GeometryFrame(count: count, sequence: 1, ring: 100))); flush(c.runtime)
                    XCTAssertEqual(midi.sounding.count, 1); XCTAssertEqual(au.sounding.count, 1)
                    source.deliver(.frame(p8GeometryFrame(count: count, sequence: 2, ring: 120))); flush(c.runtime)
                    source.deliver(.frame(p8GeometryFrame(count: count, sequence: 3, ring: 150))); flush(c.runtime)
                    XCTAssertEqual(midi.sounding.count, mode == .holdUntilNext ? 1 : 0, "mode \(mode), rays \(count)")
                    XCTAssertEqual(au.sounding.count, mode == .holdUntilNext ? 1 : 0)
                    switch edge {
                    case 0: c.runtime.stop()
                    case 1: c.runtime.panic()
                    case 2: source.deliver(.ended(session))
                    case 3: c.runtime.terminate(ack: {})
                    case 4: clock.advance(10.5)
                    case 5: c.runtime.install(try compiled(2, notes: false)) // layer/route loss
                    case 6: c.runtime.retire(midiID) {}; c.runtime.retire(auID) {} // target loss
                    case 7: c.runtime.sleep()
                    default: fatalError("exhaustive release edges")
                    }
                    flush(c.runtime); flush(c.runtime)
                    let remaining = mode == .holdUntilNext && edge == 4 ? 1 : 0
                    XCTAssertEqual(midi.sounding.count, remaining, "mode \(mode), edge \(edge), rays \(count)")
                    XCTAssertEqual(au.sounding.count, remaining)
                    c.runtime.stop(); flush(c.runtime)
                }
            }
        }
    }
}

extension PerformanceRuntimeTests {
    func testChannelPresetReleasePreservesMIDIForGateHoldAndToggle() throws {
        for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
            let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
            c.runtime.releaseAudioChannel(InstrumentChannel.legacyID); flush(c.runtime)
            try start(c, instrument: compiled(transition: transition))
            let before = midi.receipts.map(\.bytes)
            XCTAssertFalse(au.sounding.isEmpty)
            c.runtime.releaseAudioChannel(InstrumentChannel.legacyID); flush(c.runtime)
            XCTAssertTrue(au.sounding.isEmpty)
            XCTAssertFalse(midi.sounding.isEmpty)
            XCTAssertEqual(midi.receipts.map(\.bytes), before)
            c.runtime.stop(); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty)
        }
    }
}
