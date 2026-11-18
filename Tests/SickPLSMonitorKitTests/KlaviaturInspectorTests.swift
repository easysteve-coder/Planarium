import XCTest
import SickPLSControlCore
@testable import SickPLSMonitorKit

@MainActor final class KlaviaturInspectorTests: XCTestCase {
    private let layerID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    private let routingID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private let cell = PolarMetricGridCell(ring: 2, angularIndex: 4)

    private func workspace(
        program: SpatialValueProgram,
        target: SpatialRoutingTarget = .midiNote(channel: 0),
        cells: Set<PolarMetricGridCell> = [PolarMetricGridCell(ring: 2, angularIndex: 4)],
        overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:],
        isLocked: Bool = false
    ) -> SpatialInstrumentWorkspace {
        SpatialInstrumentWorkspace(
            grid: .halfMeter,
            layers: [
                SpatialInstrumentLayer(
                    id: layerID,
                    name: "Klaviatur-Inspector",
                    color: .orange,
                    isLocked: isLocked,
                    polarCells: cells,
                    routings: [SpatialRouting(id: routingID, target: target, program: program)],
                    polarCellOverrides: overrides
                )
            ]
        )
    }

    func testK1CellOverrideProvidesNotesVelocityAndSource() throws {
        let document = workspace(
            program: .constant(0.5),
            overrides: [
                cell: [
                    SpatialCellAction(
                        target: .midiNote(channel: 0),
                        value: .note(number: 64, velocity: 90)
                    )
                ]
            ]
        )
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(document)

        let draft = try XCTUnwrap(SpatialCellNoteDraft.current(cell: cell, in: state.presentation))

        XCTAssertEqual(draft.notes, [64])
        XCTAssertEqual(draft.velocity, 90)
        XCTAssertEqual(draft.source, .cellOverride)
    }

    func testK2LayerValueUsesHandCalculatedEndNote() throws {
        let cells = [
            PolarMetricGridCell(ring: 2, angularIndex: 2),
            PolarMetricGridCell(ring: 2, angularIndex: 3),
            cell
        ]
        let document = workspace(
            program: .scale(
                rootMIDINote: 60,
                lowestMIDINote: 60,
                highestMIDINote: 72,
                scale: .major,
                directionDegrees: 0,
                ascending: true,
                transition: .retrigger
            ),
            cells: Set(cells)
        )
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(document)

        let draft = try XCTUnwrap(SpatialCellNoteDraft.current(cell: cell, in: state.presentation))

        XCTAssertEqual(draft.notes, [72])
        XCTAssertEqual(draft.source, .layerValue)
    }

    func testK3ApplyCellNotesCreatesNoteOrChordAndCoalescesUnchanged() throws {
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(workspace(program: .constant(0.5)))
        _ = state.selectLayers([state.workspace.selectedLayerID])

        let chord = SpatialCellNoteDraft(notes: [60, 64, 67], velocity: 100, source: .layerValue)
        XCTAssertTrue(state.applyCellNotes(chord, cell: cell))
        XCTAssertEqual(
            state.workspace.selectedLayer.polarCellOverrides[cell]?.first?.value,
            .chord(notes: [60, 64, 67], velocity: 100)
        )
        XCTAssertEqual(state.undoDepth, 1)

        let note = SpatialCellNoteDraft(notes: [62], velocity: 100, source: .cellOverride)
        XCTAssertTrue(state.applyCellNotes(note, cell: cell))
        XCTAssertEqual(
            state.workspace.selectedLayer.polarCellOverrides[cell]?.first?.value,
            .note(number: 62, velocity: 100)
        )
        XCTAssertEqual(state.undoDepth, 2)

        XCTAssertFalse(state.applyCellNotes(note, cell: cell))
        XCTAssertEqual(state.undoDepth, 2)
    }

    func testK4LockedLayerRejectsCellNotesWithoutDocumentChange() {
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(workspace(program: .constant(0.5), isLocked: true))
        let before = state.workspace
        let draft = SpatialCellNoteDraft(notes: [60, 64], velocity: 100, source: .layerValue)

        XCTAssertFalse(state.applyCellNotes(draft, cell: cell))
        XCTAssertEqual(state.workspace, before)
    }

    func testK5NonNoteTargetHasNoCellNoteDraft() {
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(
            workspace(
                program: .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear),
                target: .midiCC(channel: 0, controller: 74)
            )
        )

        XCTAssertNil(SpatialCellNoteDraft.current(cell: cell, in: state.presentation))
    }

    func testK6SetChordNotesSortsDeduplicatesAndRecognizesPreset() {
        var draft = SpatialAssignmentDraft.from(
            program: .chord(notes: [48, 52, 55], velocity: 100, transition: .retrigger),
            target: .midiNote(channel: 0)
        )
        XCTAssertTrue(draft.setChordNotes([67, 60, 64, 64]))
        XCTAssertEqual(draft.chordNotes, [60, 64, 67])
        XCTAssertEqual(draft.rootMIDINote, 60)
        XCTAssertEqual(draft.chordPreset, .major)

        let before = draft
        XCTAssertFalse(draft.setChordNotes([]))
        XCTAssertEqual(draft, before)
    }

    func testK7ChangingCellDoesNotCarryOverrideDraftToNextCell() throws {
        let otherCell = PolarMetricGridCell(ring: 2, angularIndex: 3)
        let document = workspace(
            program: .scale(
                rootMIDINote: 60,
                lowestMIDINote: 60,
                highestMIDINote: 72,
                scale: .major,
                directionDegrees: 0,
                ascending: true,
                transition: .retrigger
            ),
            cells: [cell, otherCell],
            overrides: [
                cell: [
                    SpatialCellAction(
                        target: .midiNote(channel: 0),
                        value: .note(number: 64, velocity: 90)
                    )
                ]
            ]
        )
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(document)

        let cellA = try XCTUnwrap(SpatialCellNoteDraft.current(cell: cell, in: state.presentation))
        let cellB = try XCTUnwrap(SpatialCellNoteDraft.current(cell: otherCell, in: state.presentation))

        XCTAssertEqual(cellA.source, .cellOverride)
        XCTAssertEqual(cellB.source, .layerValue)
        XCTAssertEqual(cellB.notes, [60])
    }
}
