import XCTest
@testable import PlanariumDomain

final class SpatialNoteLedgerTests: XCTestCase {
    private let midi = SpatialRoutingTarget.midiNote(channel: 2)
    private let audio = SpatialRoutingTarget.audioUnitNote(channel: 3, stripID: InstrumentChannel.legacyID)

    private func notes(_ target: SpatialRoutingTarget, _ values: [UInt8],
                       transition: SpatialNoteTransition = .retrigger,
                       id: UUID = UUID()) -> SpatialRoutingEvaluation {
        SpatialRoutingEvaluation(
            routingID: id, target: target,
            value: .notes(Set(values.map { SpatialPlayedNote(number: $0, velocity: 100) }), transition: transition)
        )
    }

    func testApplyAndReleaseAllCoversMIDIAndAudioUnit() {
        var ledger = SpatialNoteLedger()
        _ = ledger.apply([notes(midi, [60]), notes(audio, [64])])

        let commands = ledger.releaseAll()
        XCTAssertEqual(ledger.heldNoteCount, 0)
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.contains { if case .noteOff(.midi, 2, .init(number: 60, velocity: 100)) = $0 { return true }; return false })
        XCTAssertTrue(commands.contains { if case .noteOff(.audioUnit, 3, .init(number: 64, velocity: 100)) = $0 { return true }; return false })
    }

    func testTransitionsHaveDocumentedCommandOrder() {
        var ledger = SpatialNoteLedger()
        let id = UUID()
        XCTAssertEqual(ledger.apply([notes(midi, [60], id: id)]).count, 1)

        let retrigger = ledger.apply([notes(midi, [62], id: id)])
        if case .noteOff = retrigger[0] {} else { XCTFail("retrigger muss zuerst Note-Off liefern") }
        if case .noteOn = retrigger[1] {} else { XCTFail("retrigger muss danach Note-On liefern") }

        _ = ledger.apply([notes(midi, [64], transition: .legato, id: id)])
        let overlap = ledger.apply([notes(midi, [65], transition: .overlap(milliseconds: 25), id: id)])
        XCTAssertTrue(overlap.contains { if case .scheduleOff = $0 { return true }; return false })
    }

    func testScheduledOverlapOffIsGenerationCheckedAndReleaseCancelsIt() {
        var ledger = SpatialNoteLedger()
        let id = UUID()
        _ = ledger.apply([notes(midi, [60], id: id)])
        let scheduled = ledger.apply([notes(midi, [62], transition: .overlap(milliseconds: 25), id: id)])
        let command = scheduled.first { if case .scheduleOff = $0 { return true }; return false }!
        XCTAssertNotNil(ledger.completeScheduledOff(command))
        XCTAssertTrue(ledger.releaseAll().contains {
            if case .noteOff(.midi, 2, .init(number: 62, velocity: 100)) = $0 { return true }
            return false
        })

        _ = ledger.apply([notes(midi, [60], id: id)])
        let pending = ledger.apply([notes(midi, [62], transition: .overlap(milliseconds: 25), id: id)])
        let pendingCommand = pending.first { if case .scheduleOff = $0 { return true }; return false }!
        let released = ledger.releaseAll()
        XCTAssertTrue(released.contains { if case .noteOff(.midi, 2, .init(number: 60, velocity: 100)) = $0 { return true }; return false })
        XCTAssertNil(ledger.completeScheduledOff(pendingCommand))
    }

    func testHoldUntilNextDoesNotReleaseOnEmptyButReplacesOnNextNote() {
        var ledger = SpatialNoteLedger()
        let id = UUID()
        _ = ledger.apply([notes(midi, [60], transition: .holdUntilNext, id: id)])
        XCTAssertTrue(ledger.apply([.init(routingID: id, target: midi, value: .inactive)]).isEmpty)
        let replacement = ledger.apply([notes(midi, [62], transition: .holdUntilNext, id: id)])
        XCTAssertEqual(replacement.count, 2)
    }

    func testSameChordAcrossAdjacentLayerCellsCharacterizesLegatoOffOnAndNoDoubleHold() {
        var ledger = SpatialNoteLedger()
        let first = UUID()
        let second = UUID()
        let chord: [UInt8] = [60, 64, 67]
        _ = ledger.apply([notes(midi, chord, transition: .legato, id: first)])

        let commands = ledger.apply([
            .init(routingID: first, target: midi, value: .inactive),
            notes(midi, chord, transition: .legato, id: second)
        ])

        XCTAssertEqual(ledger.heldNoteCount, chord.count)
        XCTAssertEqual(commands.filter { if case .noteOff = $0 { return true }; return false }.count, chord.count)
        XCTAssertEqual(commands.filter { if case .noteOn = $0 { return true }; return false }.count, chord.count)
        XCTAssertFalse(commands.isEmpty, "Charakterisierung: gleicher Akkord wird aktuell bei Routingwechsel neu angesetzt")
    }

    func testPresetApplyCharacterizesSameChordWithoutDoubleHeldState() {
        var ledger = SpatialNoteLedger()
        let beforeApply = UUID()
        let afterApply = UUID()
        let chord: [UInt8] = [60, 64, 67]
        _ = ledger.apply([notes(midi, chord, transition: .legato, id: beforeApply)])

        let commandsAfterApply = ledger.apply([
            notes(midi, chord, transition: .legato, id: afterApply)
        ])

        XCTAssertEqual(ledger.heldNoteCount, chord.count, "Nach Preset-apply darf kein Doppelbestand gehalten werden")
        XCTAssertEqual(commandsAfterApply.filter { if case .noteOff = $0 { return true }; return false }.count, chord.count)
        XCTAssertEqual(commandsAfterApply.filter { if case .noteOn = $0 { return true }; return false }.count, chord.count)
        XCTAssertEqual(Set(commandsAfterApply.compactMap { command -> SpatialPlayedNote? in
            if case .noteOn(_, _, let note) = command { return note }
            return nil
        }).count, chord.count)
    }
}
