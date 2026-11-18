import XCTest
import CoreGraphics
@testable import SickPLSMonitorKit

/// KLAVIATUR-1: Layout und Halteübergänge über die Produktionsnähte.
final class KlaviaturPhase1Tests: XCTestCase {
    func testTwoOctaveLayoutPlacesBlackKeysOverTheCorrectWhiteGaps() throws {
        let model = PianoKeyboardModel(octave: 4)
        let keys = PianoKeyboardLayout.layout(
            for: model.visibleNotes, width: 560, height: 96
        )

        let whiteKeys = keys.filter { !$0.isBlack }.sorted { $0.frame.minX < $1.frame.minX }
        let blackKeys = keys.filter(\.isBlack)
        XCTAssertEqual(whiteKeys.count, 14)
        XCTAssertEqual(blackKeys.count, 10)
        for (index, key) in whiteKeys.enumerated() {
            XCTAssertEqual(key.frame.minX, CGFloat(index * 40), accuracy: 0.0001)
            XCTAssertEqual(key.frame.width, 40, accuracy: 0.0001)
            XCTAssertEqual(key.frame.minY, 0, accuracy: 0.0001)
            XCTAssertEqual(key.frame.height, 96, accuracy: 0.0001)
        }

        let expectedBlackCenters: [Int: CGFloat] = [
            61: 36.8, 63: 83.2, 66: 156.8, 68: 200, 70: 243.2,
            73: 316.8, 75: 363.2, 78: 436.8, 80: 480, 82: 523.2
        ]
        for (note, center) in expectedBlackCenters {
            let key = try XCTUnwrap(blackKeys.first { $0.note == note })
            XCTAssertEqual(key.frame.midX, center, accuracy: 0.0001)
            XCTAssertLessThan(key.frame.width, 40)
            XCTAssertLessThan(key.frame.height, 96)
        }
        XCTAssertNil(blackKeys.first { $0.note == 64 })
        XCTAssertNil(blackKeys.first { $0.note == 71 })

        XCTAssertEqual(PianoKeyboardLayout.hitTest(keys: keys, point: CGPoint(x: 40, y: 8)), 61)
        let lowerHit = try XCTUnwrap(
            PianoKeyboardLayout.hitTest(keys: keys, point: CGPoint(x: 40, y: 92))
        )
        XCTAssertTrue([60, 62].contains(lowerHit))
    }

    func testKeyboardSelectionTogglesCegAndKeepsTheMIDIValues() {
        var model = PianoKeyboardModel(octave: 4)
        model.toggle(note: 60)
        model.toggle(note: 64)
        model.toggle(note: 67)

        XCTAssertEqual(model.selectedNotes, Set([60, 64, 67]))
        XCTAssertEqual(model.selectedNoteNames, "C4 E4 G4")
        model.toggle(note: 64)
        XCTAssertEqual(model.selectedNotes, Set([60, 67]))
    }

    func testEveryWhiteAndBlackKeyCenterHitsItsOwnNote() throws {
        let model = PianoKeyboardModel(octave: 4)
        let keys = PianoKeyboardLayout.layout(for: model.visibleNotes, width: 280, height: 96)
        for key in keys {
            let y = key.isBlack ? key.frame.midY : key.frame.maxY - 4
            XCTAssertEqual(
                PianoKeyboardLayout.hitTest(keys: keys, point: CGPoint(x: key.frame.midX, y: y)),
                key.note,
                "Treffer fehlt für \(key.note)"
            )
        }
    }

    func testHoldModeKeepsNotesOnHandExitAndReplacesOnNextCell() {
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let routingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var ledger = SpatialNoteLedger()
        let first = SpatialRoutingEvaluation(
            routingID: routingID,
            target: target,
            value: .notes([.init(number: 60, velocity: 100)], transition: .holdUntilNext)
        )
        let empty = SpatialRoutingEvaluation(
            routingID: routingID, target: target, value: .inactive
        )
        let next = SpatialRoutingEvaluation(
            routingID: routingID,
            target: target,
            value: .notes([.init(number: 64, velocity: 100)], transition: .holdUntilNext)
        )

        XCTAssertEqual(ledger.apply([first]), [
            .noteOn(destination: .midi, channel: 0, note: .init(number: 60, velocity: 100))
        ])
        XCTAssertTrue(ledger.apply([empty]).isEmpty)
        XCTAssertEqual(ledger.apply([next]), [
            .noteOff(destination: .midi, channel: 0, note: .init(number: 60, velocity: 100)),
            .noteOn(destination: .midi, channel: 0, note: .init(number: 64, velocity: 100))
        ])
    }

    func testReleaseStopsHeldChordWithoutChangingTheSelectedTransition() {
        let target = SpatialRoutingTarget.midiNote(channel: 2)
        let routingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var ledger = SpatialNoteLedger()
        _ = ledger.apply([SpatialRoutingEvaluation(
            routingID: routingID,
            target: target,
            value: .notes([
                .init(number: 60, velocity: 90),
                .init(number: 64, velocity: 90),
                .init(number: 67, velocity: 90)
            ], transition: .holdUntilNext)
        )])

        let releases = ledger.releaseAll()
        XCTAssertEqual(releases.count, 3)
        XCTAssertTrue(releases.allSatisfy { command in
            guard case .noteOff(.midi, 2, _) = command else { return false }
            return true
        })
        XCTAssertEqual(ledger.heldNoteCount, 0)
    }

    func testPopoverHoldModeChangesLayerRoutingAndOverrideEvaluation() throws {
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let cell = PolarMetricGridCell(ring: 2, angularIndex: 3)
        let layerID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let routing = SpatialRouting(
            target: target,
            program: .chord(notes: [60], velocity: 100, transition: .retrigger)
        )
        let action = SpatialCellAction(target: target, value: .note(number: 64, velocity: 100))
        var workspace = SpatialInstrumentWorkspace(
            grid: .halfMeter,
            layers: [SpatialInstrumentLayer(
                id: layerID, name: "Ebene", color: .orange,
                polarCells: [cell], routings: [routing], polarCellOverrides: [cell: [action]]
            )]
        )

        XCTAssertTrue(workspace.supportsNoteTransition)
        workspace.setNoteTransition(.holdUntilNext)
        XCTAssertEqual(
            workspace.selectedLayer.routings.first?.program,
            .chord(notes: [60], velocity: 100, transition: .holdUntilNext)
        )
        let evaluation = try XCTUnwrap(
            SpatialInstrumentEvaluator().evaluate(
                activeCells: [layerID: cell], workspace: workspace
            ).first?.value
        )
        XCTAssertEqual(
            evaluation,
            .notes([.init(number: 64, velocity: 100)], transition: .holdUntilNext)
        )

        workspace.setNoteTransition(.retrigger)
        XCTAssertEqual(workspace.selectedNoteTransition, .retrigger)
        let retriggered = try XCTUnwrap(
            SpatialInstrumentEvaluator().evaluate(
                activeCells: [layerID: cell], workspace: workspace
            ).first?.value
        )
        XCTAssertEqual(
            retriggered,
            .notes([.init(number: 64, velocity: 100)], transition: .retrigger)
        )
    }

    func testPopoverHidingHoldChoiceForConstantAndContinuousPrograms() {
        let target = SpatialRoutingTarget.midiCC(channel: 0, controller: 74)
        let constant = SpatialInstrumentWorkspace(
            layers: [SpatialInstrumentLayer(
                name: "Constant", color: .orange,
                routings: [SpatialRouting(target: target, program: .constant(0.5))]
            )]
        )
        let continuous = SpatialInstrumentWorkspace(
            layers: [SpatialInstrumentLayer(
                name: "Continuous", color: .orange,
                routings: [SpatialRouting(
                    target: target,
                    program: .continuous(
                        minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear
                    )
                )]
            )]
        )

        XCTAssertFalse(constant.supportsNoteTransition)
        XCTAssertFalse(continuous.supportsNoteTransition)
    }

    func testPopoverStartValueComesFromDocumentIncludingCustomOverlap() {
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let workspace = SpatialInstrumentWorkspace(layers: [SpatialInstrumentLayer(
            name: "Dokument", color: .orange,
            routings: [SpatialRouting(
                target: target,
                program: .chord(notes: [60], velocity: 100, transition: .overlap(milliseconds: 50))
            )]
        )])

        XCTAssertEqual(
            workspace.popoverNoteTransitionStartValue(),
            .overlap(milliseconds: 50)
        )
        XCTAssertEqual(
            SpatialInstrumentWorkspace(layers: [SpatialInstrumentLayer(
                name: "Fallback", color: .orange,
                routings: [SpatialRouting(target: target, program: .constant(0.5))]
            )]).popoverNoteTransitionStartValue(),
            .retrigger
        )
    }
}
