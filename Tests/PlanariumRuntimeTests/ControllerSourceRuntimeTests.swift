import XCTest
import PlanariumDomain
@testable import PlanariumRuntime

/// Scanner and game controller play in one runtime, each with its own
/// exclusively owned targets (Owner 18.11.2026). A loss releases only the
/// lost source; Panic, a user stop and quit release both.
final class ControllerSourceRuntimeTests: RuntimeTestCase {
    private let pad = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    private func layout(_ assignments: [ControllerAssignment], scanner: CompiledInstrument) throws -> CompiledControllerLayout {
        try CompiledControllerLayout(.init(assignments: assignments), source: .controller(0),
                                     sumEndpoint: scanner.sumMIDIEndpoint, established: scanner.outputClaims())
    }
    private func sustain(channel: UInt8) -> ControllerAssignment {
        .init(name: "Sustain", color: .green, element: .l1,
              routing: .init(target: .midiCC(channel: channel, controller: 64), program: .constant(1)))
    }
    private func padNote(channel: UInt8, note: Int) -> ControllerAssignment {
        .init(name: "Pad", color: .purple, element: .cross,
              routing: .init(target: .midiNote(channel: channel), program: .singleNote(note: note, velocity: 90, transition: .retrigger)))
    }
    private func bytes(_ boundary: FakeBoundary) -> [[UInt8]] { boundary.receipts.map(\.bytes) }

    func testScannerLossKeepsTheControllersSustainAndControllerLossKeepsTheScannersNotes() throws {
        let midi = FakeBoundary(), clock = FakeClock()
        let c = composition(clock: clock, midi: midi)
        let scanner = try compiled()
        try start(c, instrument: scanner)
        XCTAssertTrue(bytes(midi).contains { $0[0] == 0x90 }, "the scanner plays its note on MIDI channel 1")
        c.runtime.installController(try layout([sustain(channel: 0)], scanner: scanner))
        c.runtime.controller(.connected(session: pad, name: "DualSense"))
        c.runtime.controller(.state(session: pad, sequence: 1, time: clock.now, .neutral)) // first report: nothing held
        c.runtime.controller(.state(session: pad, sequence: 1_000, time: clock.now, .init(pressed: [.l1])))
        flush(c.runtime)
        XCTAssertTrue(bytes(midi).contains([0xB0, 64, 127]), "the pad owns the controls of channel 1")

        let before = bytes(midi).count
        c.runtime.sessionEnded(session, reason: .failure)
        flush(c.runtime)
        let afterScannerLoss = Array(bytes(midi)[before...])
        XCTAssertTrue(afterScannerLoss.contains { $0[0] == 0x80 }, "the scanner's own note ends")
        XCTAssertFalse(afterScannerLoss.contains([0xB0, 64, 0]), "the pad's sustain is not reset by the scanner's loss")

        c.runtime.controller(.disconnected(session: pad))
        flush(c.runtime)
        XCTAssertEqual(bytes(midi).last, [0xB0, 64, 0], "the pad's own loss resets its sustain")
    }

    func testControllerLossLeavesScannerNotesSounding() throws {
        let midi = FakeBoundary(), clock = FakeClock()
        let c = composition(clock: clock, midi: midi)
        let scanner = try compiled()
        try start(c, instrument: scanner)
        let scannerNotes = midi.sounding
        XCTAssertFalse(scannerNotes.isEmpty)
        c.runtime.installController(try layout([padNote(channel: 2, note: 50)], scanner: scanner))
        c.runtime.controller(.connected(session: pad, name: "DualSense"))
        c.runtime.controller(.state(session: pad, sequence: 1, time: clock.now, .neutral)) // first report: nothing held
        c.runtime.controller(.state(session: pad, sequence: 1_000, time: clock.now, .init(pressed: [.cross])))
        flush(c.runtime)
        XCTAssertEqual(midi.sounding, scannerNotes.union([2 * 128 + 50]))
        // A later scanner frame reconciles the port against both sources' notes.
        c.runtime.frame(profile(2, time: 10.04))
        flush(c.runtime)
        XCTAssertTrue(midi.sounding.contains(2 * 128 + 50), "a scanner frame does not turn the pad's note off")
        c.runtime.controller(.disconnected(session: pad))
        flush(c.runtime)
        XCTAssertEqual(midi.sounding, scannerNotes, "only the pad's note ended")
        XCTAssertEqual(midi.duplicateOns, 0)
    }

    func testPanicReleasesBothSourcesAndHeldPadStaysSilent() throws {
        let midi = FakeBoundary(), clock = FakeClock()
        let c = composition(clock: clock, midi: midi)
        let scanner = try compiled()
        try start(c, instrument: scanner)
        c.runtime.installController(try layout([padNote(channel: 2, note: 50)], scanner: scanner))
        c.runtime.controller(.connected(session: pad, name: "DualSense"))
        c.runtime.controller(.state(session: pad, sequence: 1, time: clock.now, .neutral)) // first report: nothing held
        c.runtime.controller(.state(session: pad, sequence: 1_000, time: clock.now, .init(pressed: [.cross])))
        c.runtime.panic()
        c.runtime.controller(.state(session: pad, sequence: 1_002, time: clock.now, .init(pressed: [.cross])))
        flush(c.runtime)
        XCTAssertFalse(midi.sounding.contains(2 * 128 + 50), "the still held pad button stays silent after Panic")
        c.runtime.controller(.state(session: pad, sequence: 1_003, time: clock.now, .neutral))
        c.runtime.controller(.state(session: pad, sequence: 1_004, time: clock.now, .init(pressed: [.cross])))
        flush(c.runtime)
        XCTAssertTrue(midi.sounding.contains(2 * 128 + 50), "a fresh press plays again")
    }

    /// Codex review 18.11. (6): an Audio Unit release reaches the pad's ledger;
    /// its MIDI note stays, and the held pad does not replay the AU note.
    func testAudioChannelReleaseEndsThePadsAudioUnitNoteOnly() throws {
        let midi = FakeBoundary(), au = FakeBoundary(), clock = FakeClock()
        let c = composition(clock: clock, midi: midi, au: au)
        let scanner = try compiled(notes: false)
        try start(c, instrument: scanner)
        let auNote = ControllerAssignment(name: "AU", color: .blue, element: .cross,
            routing: .init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), program: .singleNote(note: 40, velocity: 90, transition: .retrigger)))
        c.runtime.installController(try layout([auNote, padNote(channel: 2, note: 50)], scanner: scanner))
        c.runtime.simulateController(.init(pressed: [.cross]))
        flush(c.runtime)
        XCTAssertEqual(au.sounding, [40]); XCTAssertEqual(midi.sounding, [2 * 128 + 50])
        c.runtime.releaseAudioChannel(InstrumentChannel.legacyID)
        c.runtime.frame(profile(2, time: 10.04))
        flush(c.runtime)
        XCTAssertEqual(au.sounding, [], "the pad's AU note ended with the strip")
        XCTAssertEqual(midi.sounding, [2 * 128 + 50], "its MIDI note stays")
        XCTAssertEqual(au.duplicateOns, 0)
    }

    /// Codex follow-up A: queued reports are never thinned. With Q held, every
    /// accepted press/release edge sounds in order; beyond the limit one
    /// source-local release follows and the held element stays silent.
    func testControllerBacklogKeepsEveryAcceptedEdgeThenReleasesOnce() throws {
        let midi = FakeBoundary(), clock = FakeClock()
        let c = composition(clock: clock, midi: midi)
        let scanner = try compiled(notes: false)
        try start(c, instrument: scanner)
        c.runtime.installController(try layout([padNote(channel: 2, note: 50)], scanner: scanner))
        c.runtime.controller(.connected(session: pad, name: "DualSense"))
        c.runtime.controller(.state(session: pad, sequence: 1, time: clock.now, .neutral))
        flush(c.runtime)
        let gate = DispatchSemaphore(value: 0), held = DispatchSemaphore(value: 0)
        let once = NSLock(); var blocked = false
        midi.setHook { _ in
            once.lock(); let first = !blocked; blocked = true; once.unlock()
            if first { held.signal(); gate.wait() }
        }
        // The first press blocks Q inside its send; everything after queues.
        c.runtime.controller(.state(session: pad, sequence: 2, time: clock.now, .init(pressed: [.cross])))
        held.wait()
        let limit = PerformanceRuntime.controllerBacklogLimit
        for index in 0..<(limit + 40) {
            let pressed: Set<ControllerElement> = index % 2 == 0 ? [] : [.cross]
            c.runtime.controller(.state(session: pad, sequence: UInt64(3 + index), time: clock.now, .init(pressed: pressed)))
        }
        gate.signal()
        flush(c.runtime)
        midi.setHook(nil)
        let ons = bytes(midi).filter { $0 == [0x92, 50, 90] }.count
        // Accepted: the blocking press + `limit` queued reports (alternating up, down …).
        XCTAssertEqual(ons, 1 + limit / 2, "every accepted press sounds; nothing is thinned")
        XCTAssertEqual(midi.duplicateOns, 0)
        XCTAssertTrue(midi.sounding.isEmpty, "the overload release leaves nothing sounding")
        c.runtime.controller(.state(session: pad, sequence: 10_000, time: clock.now, .init(pressed: [.cross])))
        flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty, "held through the overload: silent until released")
        c.runtime.controller(.state(session: pad, sequence: 10_001, time: clock.now, .neutral))
        c.runtime.controller(.state(session: pad, sequence: 10_002, time: clock.now, .init(pressed: [.cross])))
        flush(c.runtime)
        XCTAssertEqual(midi.sounding, [2 * 128 + 50])
    }

    /// Codex follow-up C: when the scanner newly claims a target the pad holds,
    /// scanner plan and pad plan change in ONE command: the pad's note ends
    /// before anything of the new scanner plan, and the pad never plays it again.
    func testOwnershipChangeIsOneCommandPadOffBeforeScannerOn() throws {
        let au = FakeBoundary(), clock = FakeClock()
        let c = composition(clock: clock, au: au)
        let old = try compiled(notes: false)
        try start(c, instrument: old)
        let auPad = ControllerAssignment(name: "AU", color: .blue, element: .cross,
            routing: .init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), program: .singleNote(note: 40, velocity: 90, transition: .retrigger)))
        c.runtime.installController(try layout([auPad], scanner: old))
        c.runtime.simulateController(.init(pressed: [.cross]))
        flush(c.runtime)
        XCTAssertEqual(au.sounding, [40])
        let new = try compiled(2, notes: true)
        let before = au.receipts.count
        c.runtime.install(new, controller: try layout([auPad], scanner: new))
        c.runtime.frame(profile(2, time: 10.04))
        c.runtime.simulateController(.init(pressed: [.cross, .circle]))
        flush(c.runtime)
        let after = Array(au.receipts[before...].map(\.bytes))
        let padOff = try XCTUnwrap(after.firstIndex(of: [0x80, 40, 0]), "the pad's note ends")
        let scannerOn = try XCTUnwrap(after.firstIndex { $0[0] == 0x90 }, "the scanner plays its new target")
        XCTAssertLessThan(padOff, scannerOn, "old owner off before the new owner's first on")
        XCTAssertFalse(after.contains([0x90, 40, 90]), "the refused pad never plays the target again")
        XCTAssertFalse(au.sounding.contains(40))
        XCTAssertEqual(au.duplicateOns, 0)
    }

    func testScannerOwnedNotesAreRefusedToThePad() throws {
        let scanner = try compiled()
        let compiled = try layout([padNote(channel: 0, note: 50), sustain(channel: 0)], scanner: scanner)
        XCTAssertEqual(compiled.playable.map(\.name), ["Sustain"], "the scanner plays channel 1's notes; the pad may only add controls")
        XCTAssertEqual(compiled.conflicts.values.first?.owner, .scanner)
    }

    func testSimulationPlaysWithoutADeviceAndDisplaysThePlayingAssignment() throws {
        let midi = FakeBoundary(), clock = FakeClock()
        let c = composition(clock: clock, midi: midi)
        let scanner = try compiled()
        try start(c, instrument: scanner)
        let note = padNote(channel: 3, note: 45)
        c.runtime.installController(try layout([note], scanner: scanner))
        c.runtime.simulateController(.init(pressed: [.cross]))
        flush(c.runtime)
        XCTAssertTrue(midi.sounding.contains(3 * 128 + 45))
        XCTAssertEqual(c.mailbox.read()?.controller.playingAssignmentIDs, [note.id])
        c.runtime.simulateController(.neutral)
        flush(c.runtime)
        XCTAssertFalse(midi.sounding.contains(3 * 128 + 45))
    }
}
