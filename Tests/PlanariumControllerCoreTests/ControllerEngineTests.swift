import XCTest
import PlanariumMusicCore
@testable import PlanariumControllerCore

final class ControllerEngineTests: XCTestCase {
    private let strip = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
    private let session = UUID(uuidString: "C0000000-0000-0000-0000-0000000000AA")!

    private func note(_ element: ControllerElement, _ number: Int, transition: SpatialNoteTransition = .retrigger,
                      zone: ControllerZone = .whole, channel: UInt8 = 0) -> ControllerAssignment {
        .init(name: element.displayName, color: .blue, element: element, zone: zone,
              routing: .init(target: .audioUnitNote(channel: channel, stripID: strip),
                             program: .singleNote(note: number, velocity: 90, transition: transition)))
    }

    private func engine(_ assignments: [ControllerAssignment], established: [OutputClaim] = []) throws -> ControllerEngine {
        var engine = ControllerEngine()
        let compiled = try CompiledControllerLayout(.init(assignments: assignments), source: .controller(0), sumEndpoint: nil, established: established)
        _ = engine.install(compiled, at: 0)
        _ = engine.apply(.connected(session: session, name: "DualSense"))
        // The connection's first report: nothing held.
        _ = engine.apply(.state(session: session, sequence: 0x8000_0000, time: 0, .neutral))
        return engine
    }

    private var sequence: UInt64 = 0x8000_0000
    private func report(_ engine: inout ControllerEngine, _ state: ControllerState, at time: Double) -> [MusicEvent] {
        sequence += 1
        return engine.apply(.state(session: session, sequence: sequence, time: time, state))
    }

    private func ons(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case let .noteOn(_, _, note) = $0 { return note.number }; return nil }
    }
    private func offs(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case let .noteOff(_, _, note) = $0 { return note.number }; return nil }
    }

    func testPressAndReleaseIsOneNoteOnAndOneNoteOff() throws {
        var engine = try engine([note(.cross, 36)])
        let down = report(&engine, .init(pressed: [.cross]), at: 1)
        XCTAssertEqual(ons(down), [36])
        XCTAssertEqual(engine.soundingNoteCount, 1)
        XCTAssertEqual(report(&engine, .init(pressed: [.cross]), at: 1.1), [], "an unchanged report is no new entry")
        let up = report(&engine, .neutral, at: 1.2)
        XCTAssertEqual(offs(up), [36])
        XCTAssertEqual(engine.soundingNoteCount, 0)
    }

    func testShortTapBetweenTwoReportsKeepsBothEdges() throws {
        var engine = try engine([note(.square, 38)])
        // Down and up arrive as two reports within one millisecond; both edges sound.
        let events = report(&engine, .init(pressed: [.square]), at: 2) + report(&engine, .neutral, at: 2.001)
        XCTAssertEqual(ons(events), [38])
        XCTAssertEqual(offs(events), [38])
    }

    func testStaleAndForeignReportsAreIgnored() throws {
        var engine = try engine([note(.cross, 36)])
        XCTAssertEqual(ons(engine.apply(.state(session: session, sequence: 0x8000_0005, time: 1, .init(pressed: [.cross])))), [36])
        XCTAssertEqual(engine.apply(.state(session: session, sequence: 0x8000_0004, time: 1.1, .neutral)), [], "older sequence")
        XCTAssertEqual(engine.apply(.state(session: UUID(), sequence: 9, time: 1.2, .neutral)), [], "foreign session")
        XCTAssertEqual(engine.soundingNoteCount, 1)
    }

    func testLongHeldButtonIsNoInputLoss() throws {
        var engine = try engine([note(.triangle, 60)])
        _ = report(&engine, .init(pressed: [.triangle]), at: 0)
        // Ten seconds without a report: time advances, nothing is released.
        XCTAssertEqual(engine.advance(to: 10), [])
        XCTAssertEqual(engine.soundingNoteCount, 1)
    }

    func testDisconnectReleasesOnlyThisSourceAndLateDisconnectIsIgnored() throws {
        var engine = try engine([note(.cross, 36)])
        _ = report(&engine, .init(pressed: [.cross]), at: 0)
        let old = session
        let fresh = UUID()
        // Reconnect with a new session: the old notes end, the new session starts neutral.
        let reconnect = engine.apply(.connected(session: fresh, name: "DualSense"))
        XCTAssertEqual(offs(reconnect), [36])
        XCTAssertEqual(engine.apply(.disconnected(session: old)), [], "a late disconnect of the old session is ignored")
        XCTAssertEqual(engine.apply(.state(session: fresh, sequence: 1, time: 1, .init(pressed: [.cross]))), [],
                       "held in the first report of a connection: silent until released")
        _ = engine.apply(.state(session: fresh, sequence: 2, time: 1.1, .neutral))
        XCTAssertEqual(ons(engine.apply(.state(session: fresh, sequence: 3, time: 1.2, .init(pressed: [.cross])))), [36])
        XCTAssertEqual(offs(engine.apply(.disconnected(session: fresh))), [36])
        XCTAssertEqual(engine.soundingNoteCount, 0)
    }

    func testPanicBlocksHeldElementUntilReleased() throws {
        var engine = try engine([note(.circle, 40)])
        _ = report(&engine, .init(pressed: [.circle]), at: 0)
        XCTAssertEqual(offs(engine.panic()), [40])
        XCTAssertEqual(report(&engine, .init(pressed: [.circle]), at: 0.5), [], "still held after panic: silent")
        _ = report(&engine, .neutral, at: 0.6)
        XCTAssertEqual(ons(report(&engine, .init(pressed: [.circle]), at: 0.7)), [40], "a new press plays again")
    }

    func testHoldUntilNextKeepsChordAfterReleaseAndNextEntryReplacesIt() throws {
        var engine = try engine([note(.cross, 48, transition: .holdUntilNext), note(.circle, 52, transition: .holdUntilNext)])
        XCTAssertEqual(ons(report(&engine, .init(pressed: [.cross]), at: 0)), [48])
        XCTAssertEqual(report(&engine, .neutral, at: 0.2), [], "held until the next entry")
        let next = report(&engine, .init(pressed: [.circle]), at: 0.4)
        XCTAssertEqual(ons(next), [52])
        XCTAssertEqual(offs(next), [48])
    }

    func testToggleLatchesOnFirstPressAndReleasesOnSecond() throws {
        var engine = try engine([note(.r1, 64, transition: .toggle)])
        XCTAssertEqual(ons(report(&engine, .init(pressed: [.r1]), at: 0)), [64])
        _ = report(&engine, .neutral, at: 0.2)
        XCTAssertEqual(engine.soundingNoteCount, 1)
        XCTAssertEqual(offs(report(&engine, .init(pressed: [.r1]), at: 1)), [64])
    }

    func testStickSectorsHaveHysteresis() throws {
        let up = note(.leftStick, 60, zone: .sector(index: 0, count: 4))
        let right = note(.leftStick, 62, zone: .sector(index: 1, count: 4))
        var engine = try engine([up, right])
        func stick(_ bearing: Double, _ magnitude: Double = 0.9) -> ControllerState {
            let r = bearing * .pi / 180
            return .init(positions: [.leftStick: .init(x: sin(r) * magnitude, y: cos(r) * magnitude)])
        }
        XCTAssertEqual(ons(report(&engine, stick(10), at: 0)), [60])
        XCTAssertEqual(report(&engine, stick(50), at: 0.1), [], "5° past the border stays in the up sector")
        let moved = report(&engine, stick(60), at: 0.2)
        XCTAssertEqual(ons(moved), [62]); XCTAssertEqual(offs(moved), [60])
        XCTAssertEqual(offs(report(&engine, stick(60, 0.1), at: 0.3)), [62], "back to the rest zone releases")
    }

    func testTriggerAsContinuousControlSendsItsTravel() throws {
        let filter = ControllerAssignment(name: "Filter", color: .orange, element: .r2,
            routing: .init(target: .audioUnitCC(channel: 0, controller: 74, stripID: strip), program: .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear)))
        var engine = try engine([filter])
        let events = report(&engine, .init(values: [.r2: 0.5]), at: 0)
        XCTAssertEqual(events, [.scalar(routingID: filter.routing.id, target: filter.routing.target, value: 0.5)])
    }

    func testDisconnectResetsOnlyOwnSustain() throws {
        let sustain = ControllerAssignment(name: "Sustain", color: .green, element: .l1,
            routing: .init(target: .midiCC(channel: 0, controller: 64), program: .constant(1)))
        var engine = try engine([sustain])
        _ = report(&engine, .init(pressed: [.l1]), at: 0)
        let released = engine.apply(.disconnected(session: session))
        XCTAssertTrue(released.contains(.midiValue(destination: .midi, target: .midiCC(channel: 0, controller: 64), value: 0)))
        XCTAssertFalse(released.contains { if case .allNotesOff = $0 { return true }; return false }, "no channel-wide reset")
    }

    func testScannerOwnedTargetIsRejectedPerClass() throws {
        let scannerNotes = OutputClaim(source: .scanner, target: .audioUnit(stripID: strip), outputClass: .notes)
        let notes = note(.cross, 36)
        let cc = ControllerAssignment(name: "Filter", color: .orange, element: .r2,
            routing: .init(target: .audioUnitCC(channel: 0, controller: 74, stripID: strip), program: .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear)))
        let bank = ControllerAssignment(name: "Bank", color: .orange, element: .l2,
            routing: .init(target: .audioUnitCC(channel: 0, controller: 0, stripID: strip), program: .constant(1)))
        let allOff = ControllerAssignment(name: "Off", color: .orange, element: .home,
            routing: .init(target: .audioUnitCC(channel: 0, controller: 123, stripID: strip), program: .constant(0)))
        let compiled = try CompiledControllerLayout(.init(assignments: [notes, cc, bank, allOff]), source: .controller(0),
                                                    sumEndpoint: nil, established: [scannerNotes])
        XCTAssertEqual(Set(compiled.playable.map { $0.id }), [cc.id], "the scanner plays the notes; the pad may only send controls")
        XCTAssertEqual(Set(compiled.conflicts.keys), [notes.id, bank.id, allOff.id])
        XCTAssertEqual(compiled.ownedTargets[.controls], Set([OutputTargetKey.audioUnit(stripID: strip)]))
    }

    func testMIDIAliasOfTheSumOutputIsTheSameTarget() throws {
        let scanner = OutputClaim(source: .scanner, target: .midi(endpoint: 77, channel: 0), outputClass: .notes)
        var explicit = note(.cross, 36)
        explicit.routing.target = .midiNote(channel: 0)
        explicit.midiEndpointID = 77
        var sum = note(.circle, 38)
        sum.routing.target = .midiNote(channel: 0)
        let compiled = try CompiledControllerLayout(.init(assignments: [explicit, sum]), source: .controller(0),
                                                    sumEndpoint: 77, established: [scanner])
        XCTAssertTrue(compiled.playable.isEmpty, "the explicit sum endpoint and the sum output are one target")
    }

    func testSimulationPlaysThroughTheSamePath() throws {
        var engine = try engine([note(.cross, 36)])
        XCTAssertEqual(ons(engine.simulate(.init(pressed: [.cross]), at: 0)), [36])
        XCTAssertEqual(offs(engine.simulate(.neutral, at: 0.2)), [36])
    }

    func testScaleAroundTheStickChangesNoteByPosition() throws {
        let scale = ControllerAssignment(name: "Scale", color: .purple, element: .rightStick,
            routing: .init(target: .audioUnitNote(channel: 0, stripID: strip),
                           program: .scale(rootMIDINote: 60, lowestMIDINote: 60, highestMIDINote: 71, scale: .major,
                                           directionDegrees: 90, ascending: true, transition: .legato)))
        var engine = try engine([scale])
        func stick(_ bearing: Double) -> ControllerState {
            let r = bearing * .pi / 180
            return .init(positions: [.rightStick: .init(x: sin(r), y: cos(r))])
        }
        XCTAssertEqual(ons(report(&engine, stick(5), at: 0)), [60], "straight up starts at the lowest note")
        let later = report(&engine, stick(180), at: 0.1)
        XCTAssertEqual(ons(later), [65], "half way around: index 3 of the seven C-major notes C4…B4 (F4)")
    }
}
