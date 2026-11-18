import XCTest
@testable import PlanariumDomain

final class NoteOwnershipTests: XCTestCase {
    func testSharedPhysicalNoteHasOneOnAndOffOnlyAfterLastCarrierLeaves() {
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        let a = UUID(), b = UUID()
        func evaluation(_ id: UUID) -> SpatialRoutingEvaluation {
            .init(routingID: id, target: .midiNote(channel: 2),
                  value: .notes([.init(number: 60, velocity: 100)], transition: .legato))
        }
        let first = ledger.apply([evaluation(a), evaluation(b)])
        XCTAssertEqual(first, [.noteOn(destination: .midi, channel: 2, note: .init(number: 60, velocity: 100))])
        XCTAssertTrue(ledger.apply([evaluation(b)]).isEmpty)
        XCTAssertEqual(ledger.soundingNoteCount, 1)
        XCTAssertEqual(ledger.apply([]), [.noteOff(destination: .midi, channel: 2, note: .init(number: 60, velocity: 100))])
        XCTAssertEqual(ledger.soundingNoteCount, 0)
    }

    func testInstallTransfersCarrierIdentityWithoutRetriggeringPhysicalNote() {
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        let a = UUID(), b = UUID()
        func evaluation(_ id: UUID) -> SpatialRoutingEvaluation {
            .init(routingID: id, target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID),
                  value: .notes([.init(number: 64, velocity: 80)], transition: .legato))
        }
        _ = ledger.apply([evaluation(a)])
        XCTAssertTrue(ledger.retainSupported(by: [evaluation(b)]).isEmpty)
        XCTAssertTrue(ledger.apply([evaluation(b)]).isEmpty)
        XCTAssertEqual(ledger.releaseAll(), [.noteOff(destination: .audioUnit(stripID: InstrumentChannel.legacyID), channel: 0, note: .init(number: 64, velocity: 80))])
    }

    func testOverlapReturnCancelsOldDeadlineWithoutDuplicateNoteOn() {
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        let id = UUID()
        func evaluation(_ n: UInt8) -> SpatialRoutingEvaluation {
            .init(routingID: id, target: .midiNote(channel: 0),
                  value: .notes([.init(number: n, velocity: 100)], transition: .overlap(milliseconds: 25)))
        }
        _ = ledger.apply([evaluation(60)])
        let changed = ledger.apply([evaluation(62)])
        let oldOff = changed.first { if case .scheduleOff = $0 { return true }; return false }!
        let returned = ledger.apply([evaluation(60)])
        XCTAssertFalse(returned.contains { if case .noteOn = $0 { return true }; return false })
        XCTAssertNil(ledger.completeScheduledOff(oldOff))
        XCTAssertEqual(ledger.releaseAll().count, 2)
    }
    func testAllNotesOffRoutingReleasesItsChannelInTheLedgerAndOtherChannelContinues() {
        let note = SpatialRoutingEvaluation(routingID: UUID(), target: .midiNote(channel: 2),
                                           value: .notes([.init(number: 60, velocity: 100)], transition: .legato))
        let other = SpatialRoutingEvaluation(routingID: UUID(), target: .audioUnitNote(channel: 2, stripID: InstrumentChannel.legacyID),
                                            value: .notes([.init(number: 64, velocity: 100)], transition: .legato))
        let panic = SpatialRoutingEvaluation(routingID: UUID(), target: .midiAllNotesOff(channel: 2), value: .boolean(true))
        for batch in [[note, other, panic], [panic, note, other], [other, panic, note]] {
            var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
            _ = ledger.apply([note, other])
            XCTAssertEqual(ledger.apply(batch), [.noteOff(destination: .midi, channel: 2, note: .init(number: 60, velocity: 100)),
                                                .allNotesOff(destination: .midi, channel: 2)])
            XCTAssertEqual(ledger.soundingNoteCount, 1)
            XCTAssertEqual(ledger.releaseAll(), [.noteOff(destination: .audioUnit(stripID: InstrumentChannel.legacyID), channel: 2, note: .init(number: 64, velocity: 100))])
        }
    }

    func testVelocityIsNotASecondOwnerOfTheSamePhysicalNote() {
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        let a = UUID(), b = UUID()
        func evaluation(_ id: UUID, _ velocities: [UInt8]) -> SpatialRoutingEvaluation {
            .init(routingID: id, target: .midiNote(channel: 0),
                  value: .notes(Set(velocities.map { .init(number: 60, velocity: $0) }), transition: .legato))
        }
        XCTAssertEqual(ledger.apply([evaluation(a, [80, 100])]),
                       [.noteOn(destination: .midi, channel: 0, note: .init(number: 60, velocity: 100))])
        XCTAssertTrue(ledger.apply([evaluation(a, [80]), evaluation(b, [110])]).isEmpty)
        XCTAssertEqual(ledger.soundingNoteCount, 1)
        XCTAssertTrue(ledger.apply([evaluation(b, [110])]).isEmpty)
        XCTAssertEqual(ledger.releaseAll(), [.noteOff(destination: .midi, channel: 0, note: .init(number: 60, velocity: 100))])
    }

}
