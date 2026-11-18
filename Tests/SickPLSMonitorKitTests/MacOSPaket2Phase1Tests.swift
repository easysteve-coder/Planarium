import XCTest
import SickPLSControlCore
import SickPLSCore
@testable import SickPLSMonitorKit

/// macOS-Paket 2, Phase 1: Vertragstests für den zustandsbehafteten
/// Belegungs-Inspector. Die Naht ist in Phase 1 absichtlich noch nicht im
/// Produkt vorhanden; jeder Test ruft sie trotzdem über die geplante API auf.
@MainActor final class MacOSPaket2Phase1Tests: XCTestCase {
    private let target = SpatialRoutingTarget.midiNote(channel: 0)

    func testSingleNoteApplyUndoCellOverrideAndLayerTransition() throws {
        let state = CanvasDocumentFixture()
        let a = PolarMetricGridCell(ring: 4, angularIndex: 10)
        let b = PolarMetricGridCell(ring: 5, angularIndex: 10)
        state.updateWorkspace { $0.updateSelectedLayer {
            $0.polarCells = [a, b]
            $0.routings = [.init(target: target, program: .constant(0))]
        } }
        let before = state.workspace
        let draft = SpatialAssignmentDraft(target: target, kind: .singleNote, rootMIDINote: 73,
                                            transition: .toggle, velocity: 81)
        XCTAssertTrue(state.applyAssignment(draft))
        XCTAssertEqual(SpatialAssignmentDraft.current(in: state.presentation), draft)
        XCTAssertEqual(SpatialCellNoteDraft.current(cell: a, in: state.presentation)?.notes, [73])
        XCTAssertEqual(SpatialCellNoteDraft.current(cell: b, in: state.presentation)?.velocity, 81)
        state.updateWorkspace { $0.setNoteTransition(.holdUntilNext) }
        XCTAssertEqual(state.workspace.selectedNoteTransition, .holdUntilNext)
        XCTAssertEqual(SpatialCellNoteDraft.current(cell: a, in: state.presentation)?.notes, [73])
        state.undo()
        state.undo()
        XCTAssertEqual(state.workspace.layers, before.layers)
    }

    func testScaleAndRandomCannotAcquireToggleThroughLayerOrAssignmentEdits() {
        for kind: SpatialAssignmentKind in [.scale, .randomScale] {
            var state = MetricCanvasInteractionState()
            state.updateWorkspace { $0.updateSelectedLayer {
                $0.routings = [.init(target: target, program: .constant(0))]
            } }
            let draft = SpatialAssignmentDraft(target: target, kind: kind, transition: .toggle)
            XCTAssertTrue(state.applyAssignment(draft))
            XCTAssertEqual(state.workspace.selectedNoteTransition, .retrigger)
            state.updateWorkspace { $0.setNoteTransition(.toggle) }
            XCTAssertEqual(state.workspace.selectedNoteTransition, .retrigger)
        }
    }

    func testW1LayerSwitchLoadsTheSelectedLayerDraft() {
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let programA = SpatialValueProgram.scale(
            rootMIDINote: 48, lowestMIDINote: 36, highestMIDINote: 72,
            scale: .major, directionDegrees: 15, ascending: true,
            transition: .legato
        )
        let programB = SpatialValueProgram.continuous(
            minimum: 0.2, maximum: 0.8, directionDegrees: 275, curve: .easeOut
        )
        let workspace = SpatialInstrumentWorkspace(layers: [
            layer(id: first, routing: SpatialRouting(target: target, program: programA)),
            layer(id: second, routing: SpatialRouting(target: target, program: programB))
        ])
        let state = canvasState(workspace)

        XCTAssertEqual(SpatialAssignmentDraft.current(in: state.presentation),
                       SpatialAssignmentDraft.from(program: programA, target: target))
        state.updateWorkspace { $0.selectLayer(second) }
        XCTAssertEqual(SpatialAssignmentDraft.current(in: state.presentation),
                       SpatialAssignmentDraft.from(program: programB, target: target))
        state.updateWorkspace { $0.selectLayer(first) }
        XCTAssertEqual(SpatialAssignmentDraft.current(in: state.presentation),
                       SpatialAssignmentDraft.from(program: programA, target: target))
    }

    func testN4PendingDraftSurvivesLayerSwitchButInvalidatesAfterDocumentChange() {
        let first = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let second = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let programA = SpatialValueProgram.scale(
            rootMIDINote: 48, lowestMIDINote: 36, highestMIDINote: 72,
            scale: .major, directionDegrees: 15, ascending: true,
            transition: .legato
        )
        let programB = SpatialValueProgram.constant(0.25)
        let state = canvasState(SpatialInstrumentWorkspace(layers: [
            layer(id: first, routing: SpatialRouting(target: target, program: programA)),
            layer(id: second, routing: SpatialRouting(target: target, program: programB))
        ]))
        let baseline = SpatialAssignmentDraft.current(in: state.presentation)
        var editedDraft = baseline
        editedDraft.rootMIDINote = 67
        let pending = SpatialPendingAssignment(draft: editedDraft, baseline: baseline)

        // Supervisor-Entscheidung: Ein Draft bleibt erhalten, solange seine
        // Baseline wieder dem Dokument entspricht. Erst eine echte
        // Dokumentänderung invalidiert ihn.
        XCTAssertEqual(SpatialPendingAssignment.visibleDraft(pending: pending, in: state.presentation), editedDraft)
        state.updateWorkspace { $0.selectLayer(second) }
        state.updateWorkspace { $0.selectLayer(first) }
        XCTAssertEqual(SpatialPendingAssignment.visibleDraft(pending: pending, in: state.presentation), editedDraft)

        state.updateWorkspace { workspace in
            workspace.updateSelectedLayer { layer in
                layer.routings[0].program = programB
            }
        }
        XCTAssertEqual(SpatialPendingAssignment.visibleDraft(pending: pending, in: state.presentation),
                       SpatialAssignmentDraft.current(in: state.presentation))
    }

    func testW2DraftRoundTripPreservesEveryDisplayedAndHiddenProgramField() {
        let programs: [SpatialValueProgram] = [
            .scale(rootMIDINote: 61, lowestMIDINote: 41, highestMIDINote: 91,
                    scale: .naturalMinor, directionDegrees: 123, ascending: false,
                    transition: .overlap(milliseconds: 37.5)),
            .randomScale(rootMIDINote: 52, lowestMIDINote: 40, highestMIDINote: 88,
                         scale: .minorPentatonic, seed: 0xDEADBEEF, transition: .holdUntilNext),
            .continuous(minimum: -0.25, maximum: 0.73, directionDegrees: 211, curve: .easeIn),
            .chord(notes: [48, 55, 60, 64], velocity: 93, transition: .legato),
            .constant(0.375)
        ]

        for program in programs {
            let draft = SpatialAssignmentDraft.from(program: program, target: target)
            XCTAssertEqual(SpatialAssignmentDraft.program(from: draft), program)
        }
    }

    func testW3ApplyingAnUnchangedDraftDoesNotChangeDocumentOrUndoDepth() {
        let program = SpatialValueProgram.constant(0.5)
        let workspace = SpatialInstrumentWorkspace(layers: [
            layer(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                  routing: SpatialRouting(target: target, program: program))
        ])
        let state = canvasState(workspace)
        let before = state.workspace
        let undoDepth = state.undoDepth
        let unchangedDraft = SpatialAssignmentDraft.current(in: state.presentation)
        XCTAssertFalse(state.applyAssignment(unchangedDraft))
        XCTAssertEqual(state.workspace, before)
        XCTAssertEqual(state.undoDepth, undoDepth)
    }

    func testW4ChangingOnlyRootNotePreservesOtherFieldsAndCreatesOneUndoEntry() {
        let original = SpatialValueProgram.randomScale(
            rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84,
            scale: .major, seed: 1234, transition: .overlap(milliseconds: 12)
        )
        let state = canvasState(SpatialInstrumentWorkspace(layers: [
            layer(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                  routing: SpatialRouting(target: target, program: original))
        ]))
        var changedDraft = SpatialAssignmentDraft.current(in: state.presentation)
        changedDraft.rootMIDINote = 67
        let expected = SpatialValueProgram.randomScale(
            rootMIDINote: 67, lowestMIDINote: 48, highestMIDINote: 84,
            scale: .major, seed: 1234, transition: .overlap(milliseconds: 12)
        )

        XCTAssertTrue(state.applyAssignment(changedDraft))
        XCTAssertEqual(state.undoDepth, 1)
        XCTAssertEqual(state.undoActionName, "Change assignment")
        XCTAssertEqual(state.workspace.selectedLayer.routings[0].program, expected)
    }

    func testW5RerollChangesOnlySeedAndOwnsItsUndoTransaction() {
        let original = SpatialValueProgram.randomScale(
            rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84,
            scale: .major, seed: 1234, transition: .legato
        )
        let state = canvasState(SpatialInstrumentWorkspace(layers: [
            layer(id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                  routing: SpatialRouting(target: target, program: original))
        ]))
        XCTAssertTrue(state.rerollAssignmentSeed())
        XCTAssertEqual(state.undoDepth, 1)
        XCTAssertEqual(state.undoActionName, "Randomize again")
        let rerolled = SpatialAssignmentDraft.current(in: state.presentation)
        XCTAssertNotEqual(rerolled.seed, 1234)

        var changedDraft = rerolled
        changedDraft.rootMIDINote = 67
        XCTAssertTrue(state.applyAssignment(changedDraft))
        XCTAssertEqual(state.undoDepth, 2)
        let afterApply = SpatialAssignmentDraft.current(in: state.presentation)
        XCTAssertEqual(afterApply.seed, rerolled.seed)
        XCTAssertEqual(afterApply.lowestMIDINote, 48)
        XCTAssertEqual(afterApply.highestMIDINote, 84)
        XCTAssertEqual(afterApply.scale, .major)
        XCTAssertEqual(afterApply.transition, .legato)
    }

    func testW6PresetChangeReloadsTheLoadedAssignmentIntoTheDraft() {
        let initial = SpatialValueProgram.constant(0.1)
        let loaded = SpatialValueProgram.chord(
            notes: [50, 57, 62], velocity: 111, transition: .holdUntilNext
        )
        let state = canvasState(SpatialInstrumentWorkspace(layers: [
            layer(id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
                  routing: SpatialRouting(target: target, program: initial))
        ]))

        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [
            layer(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                  routing: SpatialRouting(target: target, program: loaded))
        ]))
        XCTAssertEqual(SpatialAssignmentDraft.current(in: state.presentation),
                       SpatialAssignmentDraft.from(program: loaded, target: target))
        XCTAssertEqual(state.workspace.selectedLayer.routings[0].program, loaded)
    }

    func testW7ChangingCCNumberChangesTheRealTargetAndCompatibleOverride() {
        let cell = PolarMetricGridCell(ring: 2, angularIndex: 5)
        let oldTarget = SpatialRoutingTarget.midiCC(channel: 3, controller: 74)
        let oldOverride = SpatialCellAction(target: oldTarget, value: .scalar(0.75))
        let routing = SpatialRouting(target: oldTarget, program: .constant(0.5))
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let state = canvasState(SpatialInstrumentWorkspace(layers: [
            SpatialInstrumentLayer(id: id, name: "CC", color: .blue,
                                   polarCells: [cell], routings: [routing],
                                   polarCellOverrides: [cell: [oldOverride]])
        ]))

        XCTAssertTrue(state.setAssignmentCCNumber(20))
        XCTAssertEqual(state.undoDepth, 1)
        XCTAssertEqual(state.undoActionName, "Change CC number")
        XCTAssertEqual(state.workspace.selectedLayer.routings[0].target,
                       .midiCC(channel: 3, controller: 20))
        XCTAssertEqual(state.workspace.selectedLayer.polarCellOverrides[cell]?.first?.target,
                       .midiCC(channel: 3, controller: 20))
    }

    func testW8LockedLayerDoesNotAllowApplyingTheDraft() {
        let id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let locked = SpatialInstrumentLayer(
            id: id, name: "Gesperrt", color: .orange, isLocked: true,
            routings: [SpatialRouting(target: target, program: .constant(0.5))]
        )
        let state = canvasState(SpatialInstrumentWorkspace(layers: [locked]))
        let draft = SpatialAssignmentDraft.current(in: state.presentation)

        XCTAssertEqual(state.presentation.assignmentApplyDecision(for: draft), .notAllowed)
        XCTAssertFalse(state.applyAssignment(draft))
        XCTAssertEqual(state.undoDepth, 0)
    }

    func testW9ChordDraftDerivesRootAndPresetWithoutLosingCustomChords() {
        let major = SpatialAssignmentDraft.from(
            program: .chord(notes: [50, 54, 57], velocity: 111, transition: .legato),
            target: target
        )
        XCTAssertEqual(major.rootMIDINote, 50)
        XCTAssertEqual(major.chordPreset, .major)

        let custom = SpatialAssignmentDraft.from(
            program: .chord(notes: [50, 57, 62], velocity: 111, transition: .legato),
            target: target
        )
        XCTAssertEqual(custom.rootMIDINote, 50)
        XCTAssertNil(custom.chordPreset)

        var changed = major
        changed.setChordPreset(.minor)
        XCTAssertEqual(changed.chordNotes, [50, 53, 57])
    }

    func testW10RootChangeTransposesPresetAndCustomChordsButNotScales() {
        var presetChord = SpatialAssignmentDraft.from(
            program: .chord(notes: [50, 54, 57], velocity: 100, transition: .legato),
            target: target
        )
        presetChord.setRootMIDINote(52)
        XCTAssertEqual(presetChord.chordNotes, [52, 56, 59])

        var customChord = SpatialAssignmentDraft.from(
            program: .chord(notes: [50, 57, 62], velocity: 100, transition: .legato),
            target: target
        )
        customChord.setRootMIDINote(48)
        XCTAssertEqual(customChord.chordNotes, [48, 55, 60])

        var scale = SpatialAssignmentDraft.from(
            program: .scale(rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84,
                            scale: .major, directionDegrees: 90, ascending: true,
                            transition: .legato),
            target: target
        )
        scale.setRootMIDINote(67)
        XCTAssertEqual(scale.rootMIDINote, 67)
        XCTAssertEqual(scale.lowestMIDINote, 48)
        XCTAssertEqual(scale.highestMIDINote, 84)
    }

    func testW11LockedChordRejectsApplyAfterRootChange() {
        let id = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let locked = SpatialInstrumentLayer(
            id: id, name: "Gesperrter Akkord", color: .purple, isLocked: true,
            routings: [SpatialRouting(
                target: target,
                program: .chord(notes: [50, 54, 57], velocity: 100, transition: .legato)
            )]
        )
        let state = canvasState(SpatialInstrumentWorkspace(layers: [locked]))
        var draft = SpatialAssignmentDraft.current(in: state.presentation)
        draft.setRootMIDINote(52)

        XCTAssertEqual(state.presentation.assignmentApplyDecision(for: draft), .notAllowed)
        XCTAssertFalse(state.applyAssignment(draft))
        XCTAssertEqual(state.undoDepth, 0)
    }

    func testN10InspectorProjectionReflectsCurrentLockWithoutASnapshotWrite() throws {
        let state = CanvasDocumentFixture()
        let owner = state.session
        _ = owner.renameSelectedLayer("Current")
        XCTAssertEqual(owner.inspector.presentation.workspace.selectedLayer.name, "Current")
        owner.updateWorkspace { $0.updateSelectedLayer { $0.isLocked = true } }
        XCTAssertTrue(owner.inspector.presentation.workspace.selectedLayer.isLocked)
        let before = state.document
        XCTAssertFalse(owner.renameSelectedLayer("Stale intention"))
        XCTAssertEqual(state.document, before)
        XCTAssertTrue(owner.inspector.presentation.workspace.selectedLayer.isLocked)
    }

    private func layer(id: UUID, routing: SpatialRouting) -> SpatialInstrumentLayer {
        SpatialInstrumentLayer(id: id, name: id.uuidString, color: .blue, routings: [routing])
    }

    private func canvasState(_ workspace: SpatialInstrumentWorkspace) -> CanvasDocumentFixture {
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(workspace)
        return state
    }

}
