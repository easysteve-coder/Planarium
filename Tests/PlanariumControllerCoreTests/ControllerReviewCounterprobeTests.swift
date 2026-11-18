import XCTest
import PlanariumMusicCore
@testable import PlanariumControllerCore

/// Counter-probes for the Codex diff review of 18.11.2026 (findings 2, 3, 4, 7, 8, 10).
final class ControllerReviewCounterprobeTests: XCTestCase {
    private let strip = UUID(uuidString: "C0000000-0000-0000-0000-0000000000B1")!
    private let session = UUID(uuidString: "C0000000-0000-0000-0000-0000000000B2")!
    private var sequence: UInt64 = 0

    private func compiled(_ assignments: [ControllerAssignment], sum: Int32? = nil, established: [OutputClaim] = []) throws -> CompiledControllerLayout {
        try CompiledControllerLayout(.init(assignments: assignments), source: .controller(0), sumEndpoint: sum, established: established)
    }
    private func connected(_ layout: CompiledControllerLayout) -> ControllerEngine {
        var engine = ControllerEngine()
        _ = engine.install(layout, at: 0)
        _ = engine.apply(.connected(session: session, name: "Pad"))
        _ = report(&engine, .neutral, at: 0)
        return engine
    }
    private func report(_ engine: inout ControllerEngine, _ state: ControllerState, at time: Double) -> [MusicEvent] {
        sequence += 1
        return engine.apply(.state(session: session, sequence: sequence, time: time, state))
    }
    private func note(_ element: ControllerElement, _ number: Int, velocity: UInt8 = 90, transition: SpatialNoteTransition = .retrigger,
                      target: SpatialRoutingTarget? = nil) -> ControllerAssignment {
        .init(name: element.displayName, color: .blue, element: element,
              routing: .init(target: target ?? .audioUnitNote(channel: 0, stripID: strip), program: .singleNote(note: number, velocity: velocity, transition: transition)))
    }
    private func sustain(endpoint: Int32? = nil, element: ControllerElement = .l1) -> ControllerAssignment {
        .init(name: "Sustain", color: .green, element: element, routing: .init(target: .midiCC(channel: 0, controller: 64), program: .constant(1)),
              midiEndpointID: endpoint)
    }
    private func noteNumbers(_ events: [MusicEvent], on: Bool) -> [UInt8] {
        events.compactMap {
            switch $0 {
            case let .noteOn(_, _, n) where on: return n.number
            case let .noteOff(_, _, n) where !on: return n.number
            default: return nil
            }
        }
    }

    // 2 · The class of the target is the class of what is sent.
    func testProgramChangeOnAControllerTargetAndAliasedControllerNumbersAreRefused() {
        let pc = ControllerAssignment(name: "PC", color: .blue, element: .cross,
                                      routing: .init(target: .midiCC(channel: 0, controller: 74), program: .programChange(.init(program: 5))))
        XCTAssertThrowsError(try compiled([pc])) { XCTAssertEqual($0 as? ControllerLayoutError, .unsupportedTarget(assignmentID: pc.id)) }
        let alias = ControllerAssignment(name: "128", color: .blue, element: .cross,
                                         routing: .init(target: .midiCC(channel: 0, controller: 128), program: .constant(1)))
        XCTAssertThrowsError(try compiled([alias])) { XCTAssertEqual($0 as? ControllerLayoutError, .invalidNumber(assignmentID: alias.id)) }
        let channel = ControllerAssignment(name: "Ch17", color: .blue, element: .cross,
                                           routing: .init(target: .midiNote(channel: 16), program: .singleNote(note: 60, velocity: 90, transition: .retrigger)))
        XCTAssertThrowsError(try compiled([channel]))
        let layerControl = ControllerAssignment(name: "Release", color: .blue, element: .cross,
                                                routing: .init(target: .releaseLayer(layerID: UUID()), program: .constant(1)))
        XCTAssertThrowsError(try compiled([layerControl]), "layer controls are not playable from a controller")
    }

    // 3 · A latched toggle that becomes refused ends at its old target, before anything new.
    func testRelayoutReleasesARemovedToggleAndARefusedOneAtTheOldTarget() throws {
        let toggle = note(.r1, 64, transition: .toggle)
        let other = note(.cross, 36)
        var engine = connected(try compiled([toggle, other]))
        XCTAssertEqual(noteNumbers(report(&engine, .init(pressed: [.r1]), at: 0.1), on: true), [64])
        _ = report(&engine, .neutral, at: 0.2)
        XCTAssertEqual(engine.soundingNoteCount, 1, "the toggle is latched")
        let scannerNow = OutputClaim(source: .scanner, target: .audioUnit(stripID: strip), outputClass: .notes)
        let events = engine.install(try compiled([toggle, other], established: [scannerNow]), at: 1)
        XCTAssertEqual(noteNumbers(events, on: false), [64], "refused toggle ends at its old target")
        XCTAssertEqual(noteNumbers(events, on: true), [])
        XCTAssertEqual(engine.soundingNoteCount, 0)
        XCTAssertEqual(report(&engine, .init(pressed: [.r1]), at: 2), [], "refused: no new on")
    }

    func testRelayoutResetsARemovedSustainAtItsOldEndpointAndNeverStrikesAHeldNewAssignment() throws {
        var engine = connected(try compiled([sustain(endpoint: 11)]))
        _ = report(&engine, .init(pressed: [.l1, .cross]), at: 0.1)
        let events = engine.install(try compiled([note(.cross, 40)]), at: 0.5)
        XCTAssertTrue(events.contains(.midiValue(destination: .midiEndpoint(uniqueID: 11), target: .midiCC(channel: 0, controller: 64), value: 0)),
                      "the removed sustain returns at endpoint 11")
        XCTAssertEqual(noteNumbers(events, on: true), [], "cross is already held: the new note waits for a new press")
        _ = report(&engine, .neutral, at: 0.6)
        XCTAssertEqual(noteNumbers(report(&engine, .init(pressed: [.cross]), at: 0.7), on: true), [40])
    }

    func testUnchangedAssignmentKeepsSoundingThroughARelayout() throws {
        let held = note(.cross, 36)
        var engine = connected(try compiled([held]))
        _ = report(&engine, .init(pressed: [.cross]), at: 0.1)
        let events = engine.install(try compiled([held, note(.circle, 38)]), at: 0.2)
        XCTAssertEqual(events, [], "the unchanged note neither stops nor strikes again")
        XCTAssertEqual(engine.soundingNoteCount, 1)
    }

    // 4 · Sustain up on release.
    func testSustainButtonSendsDownAndUp() throws {
        var engine = connected(try compiled([sustain()]))
        XCTAssertEqual(report(&engine, .init(pressed: [.l1]), at: 0.1), [.midiValue(destination: .midi, target: .midiCC(channel: 0, controller: 64), value: 1)])
        XCTAssertEqual(report(&engine, .neutral, at: 0.2), [.midiValue(destination: .midi, target: .midiCC(channel: 0, controller: 64), value: 0)])
        XCTAssertFalse(engine.apply(.disconnected(session: session)).contains { if case .midiValue = $0 { return true }; return false },
                       "already released: no second reset")
    }

    func testTriggerReturnsToItsMinimumAndAStickBendToTheCentre() throws {
        let filter = ControllerAssignment(name: "Filter", color: .orange, element: .r2,
            routing: .init(target: .midiCC(channel: 0, controller: 74), program: .continuous(minimum: 0.2, maximum: 1, directionDegrees: 0, curve: .linear)))
        let bend = ControllerAssignment(name: "Bend", color: .purple, element: .leftStick,
            routing: .init(target: .midiPitchBend(channel: 1), program: .continuous(minimum: 0, maximum: 1, directionDegrees: 90, curve: .linear)))
        var engine = connected(try compiled([filter, bend]))
        _ = report(&engine, .init(values: [.r2: 0.9], positions: [.leftStick: .init(x: 0, y: 0.9)]), at: 0.1)
        let back = report(&engine, .neutral, at: 0.2)
        XCTAssertTrue(back.contains(.midiValue(destination: .midi, target: filter.routing.target, value: 0.2)))
        XCTAssertTrue(back.contains(.midiValue(destination: .midi, target: bend.routing.target, value: 0.5)))
    }

    // 7 · Shared notes: two pads on C4 sound it once, it ends with the last one.
    func testTwoPadsOnOneNoteEndOnlyWithTheLast() throws {
        var engine = connected(try compiled([note(.cross, 60, velocity: 80), note(.circle, 60, velocity: 120)]))
        XCTAssertEqual(noteNumbers(report(&engine, .init(pressed: [.cross]), at: 0.1), on: true), [60])
        _ = report(&engine, .init(pressed: [.cross, .circle]), at: 0.2)
        XCTAssertEqual(noteNumbers(report(&engine, .init(pressed: [.circle]), at: 0.3), on: false), [], "circle still holds C4")
        XCTAssertEqual(engine.soundingNoteCount, 1)
        XCTAssertEqual(noteNumbers(report(&engine, .neutral, at: 0.4), on: false), [60])
    }

    // 8 · Receipts keep their endpoint: two sustains on two outputs both reset.
    func testSustainOnTwoEndpointsResetsBoth() throws {
        var engine = connected(try compiled([sustain(endpoint: 11), sustain(endpoint: 22, element: .r1)]))
        _ = report(&engine, .init(pressed: [.l1, .r1]), at: 0.1)
        let released = engine.apply(.disconnected(session: session))
        for endpoint: Int32 in [11, 22] {
            XCTAssertTrue(released.contains(.midiValue(destination: .midiEndpoint(uniqueID: endpoint), target: .midiCC(channel: 0, controller: 64), value: 0)),
                          "endpoint \(endpoint)")
        }
    }

    // 6 (engine half) · An audio release ends AU notes only; MIDI stays; no replay.
    func testAudioReleaseEndsOnlyAudioUnitNotesAndBlocksReplay() throws {
        var engine = connected(try compiled([note(.cross, 36), note(.circle, 50, target: .midiNote(channel: 3))]))
        _ = report(&engine, .init(pressed: [.cross, .circle]), at: 0.1)
        let released = engine.releaseAudio(stripID: strip)
        XCTAssertEqual(noteNumbers(released, on: false), [36])
        XCTAssertEqual(engine.soundingNoteCount, 1, "the MIDI note stays")
        XCTAssertEqual(noteNumbers(report(&engine, .init(pressed: [.cross, .circle]), at: 0.2), on: true), [], "no replay of the old ownership")
        _ = report(&engine, .init(pressed: [.circle]), at: 0.3)
        XCTAssertEqual(noteNumbers(report(&engine, .init(pressed: [.cross, .circle]), at: 0.4), on: true), [36], "a new press plays")
    }

    // Follow-up B · an overlap tail alone on the strip ends with the release, once.
    func testAudioReleaseEndsAnOverlapTailOnceAndNeverReplaysIt() throws {
        var engine = connected(try compiled([note(.cross, 36, transition: .overlap(milliseconds: 500))]))
        _ = report(&engine, .init(pressed: [.cross]), at: 0.1)
        XCTAssertEqual(noteNumbers(report(&engine, .neutral, at: 0.2), on: false), [], "released: the tail sounds on")
        XCTAssertEqual(engine.soundingNoteCount, 1)
        XCTAssertNotNil(engine.nextDeadline)
        XCTAssertEqual(noteNumbers(engine.releaseAudio(stripID: strip), on: false), [36], "the tail ends with the strip")
        XCTAssertEqual(engine.soundingNoteCount, 0)
        XCTAssertNil(engine.nextDeadline)
        XCTAssertEqual(engine.advance(to: 2), [], "no late off, no replay")
        XCTAssertTrue(engine.soundingEvents.isEmpty)
    }

    func testAudioReleaseReturnsThePadsControlsOnThatStrip() throws {
        let pressure = ControllerAssignment(name: "Pressure", color: .orange, element: .r2,
            routing: .init(target: .audioUnitChannelPressure(channel: 0, stripID: strip), program: .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear)))
        var engine = connected(try compiled([pressure]))
        _ = report(&engine, .init(values: [.r2: 0.8]), at: 0.1)
        let released = engine.releaseAudio(stripID: strip)
        XCTAssertTrue(released.contains(.scalar(routingID: pressure.routing.id, target: pressure.routing.target, value: 0)), "pressure returns at the strip")
    }

    // Follow-up P2 · after an overload the first reports are baselines again.
    func testAfterOverloadAnElementPressedInTheRefusedPartStaysSilent() throws {
        var engine = connected(try compiled([note(.cross, 36), note(.circle, 38)]))
        _ = report(&engine, .init(pressed: [.cross]), at: 0.1)
        _ = engine.overload()
        // Circle was pressed in a refused report; the next accepted one holds it.
        XCTAssertEqual(noteNumbers(report(&engine, .init(pressed: [.circle]), at: 0.2), on: true), [], "device baseline")
        XCTAssertEqual(noteNumbers(engine.simulate(.init(pressed: [.cross]), at: 0.3), on: true), [], "simulation baseline")
        _ = report(&engine, .neutral, at: 0.4); _ = engine.simulate(.neutral, at: 0.4)
        XCTAssertEqual(noteNumbers(report(&engine, .init(pressed: [.circle]), at: 0.5), on: true), [38], "a new press plays")
    }
}
