import XCTest
import CoreGraphics
import SickPLSControlCore
import SickPLSCore
@testable import SickPLSMonitorKit

/// macOS-Paket 1b: Die Tests beschreiben die freigegebene Undo-/Redo-Naht.
/// Die Produktions-API für den Verlauf folgt erst nach Phase 1.
@MainActor final class MacOSPaket1Phase1UndoTests: XCTestCase {
    private let canvasSize = CGSize(width: 800, height: 800)
    private let layerID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let target = SpatialRoutingTarget.midiNote(channel: 1)

    private var action: SpatialCellAction {
        SpatialCellAction(target: target, value: .note(number: 60, velocity: 100))
    }

    func testU1EraseUndoRestoresMaskAndOverridesThenRedoReappliesBoth() throws {
        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let state = state(with: [cell], overrides: [cell: [action]])
        let before = state.workspace
        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertEqual(state.applyToSelection(.erase), .success(.applied(changedCells: 1)))

        XCTAssertTrue(state.canUndo)
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace, before)
        XCTAssertTrue(state.canRedo)
        XCTAssertTrue(state.redo())
        XCTAssertEqual(state.workspace.selectedLayer.polarCells, [])
        XCTAssertNil(state.workspace.selectedLayer.polarCellOverrides[cell])
    }

    func testU2PopoverTransitionAndAssignmentAreOneUndoEntry() throws {
        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let state = state(with: [cell])
        let before = state.workspace
        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))

        state.performEdit(named: "Ton zuweisen") { state in
            state.updateWorkspace { $0.setNoteTransition(.holdUntilNext) }
            XCTAssertEqual(state.applyToSelection(.setAction(action)), .success(.applied(changedCells: 1)))
            return true
        }
        XCTAssertEqual(state.undoDepth, 1)

        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace, before)
        XCTAssertEqual(state.workspace.selectedNoteTransition, .retrigger)

        let split = self.state(with: [cell])
        XCTAssertTrue(split.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        split.updateWorkspace { $0.setNoteTransition(.holdUntilNext) }
        XCTAssertEqual(split.applyToSelection(.setAction(action)), .success(.applied(changedCells: 1)))
        XCTAssertEqual(split.undoDepth, 2)
    }

    func testU3ViewChangesAndRejectedEraseDoNotCreateHistoryEntries() throws {
        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let state = state(with: [cell])
        let initialDepth = state.undoDepth

        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertTrue(state.zoom(byFactor: 1.1, atScreenPoint: CGPoint(x: 400, y: 400), canvasSize: canvasSize))
        XCTAssertTrue(state.panViewport(byScreenX: 20, screenY: -10))
        state.clearSelection()
        XCTAssertEqual(state.applyToSelection(.erase), .failure(.emptySelection))

        XCTAssertEqual(state.undoDepth, initialDepth)
        XCTAssertFalse(state.canUndo)
    }

    func testU4NewEditAfterUndoClearsRedo() throws {
        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let otherCell = try XCTUnwrap(self.cell(at: CGPoint(x: 500, y: 750)))
        let state = state(with: [cell])
        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertEqual(state.applyToSelection(.erase), .success(.applied(changedCells: 1)))
        XCTAssertTrue(state.undo())
        XCTAssertTrue(state.canRedo)

        state.clearSelection()
        state.select(tool: .paint)
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 500, y: 750), canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertTrue(state.workspace.selectedLayer.polarCells.contains(otherCell))
        XCTAssertFalse(state.canRedo)
        XCTAssertFalse(state.redo())
    }

    func testU8UnchangedWorkspaceUpdateDoesNotCreateHistoryEntry() throws {
        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let state = state(with: [cell])
        let initialDepth = state.undoDepth
        state.updateWorkspace { $0.setNoteTransition(.retrigger) }
        XCTAssertEqual(state.undoDepth, initialDepth)
        XCTAssertFalse(state.canUndo)
    }

    func testTransitionChangesEverySelectedLayerInOneUndoStepWithoutCells() throws {
        let secondID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let thirdID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let state = CanvasDocumentFixture(tool: .select)
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [
            layer(id: layerID), layer(id: secondID), layer(id: thirdID)
        ]))

        state.updateWorkspace(named: "Change transition") {
            $0.setNoteTransition(.holdUntilNext, for: [layerID, secondID, thirdID])
        }

        for layer in state.workspace.layers {
            XCTAssertEqual(layer.routings.first?.program,
                           .chord(notes: [60], velocity: 100, transition: .holdUntilNext))
        }
        XCTAssertEqual(state.undoDepth, 1)
        XCTAssertTrue(state.undo())
        for layer in state.workspace.layers {
            XCTAssertEqual(layer.routings.first?.program,
                           .chord(notes: [60], velocity: 100, transition: .retrigger))
        }
    }

    func testU9UnchangedEditAfterUndoPreservesRedo() throws {
        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let state = state(with: [cell])
        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertEqual(state.applyToSelection(.erase), .success(.applied(changedCells: 1)))
        XCTAssertTrue(state.undo())
        XCTAssertTrue(state.canRedo)
        _ = state.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize)
        XCTAssertEqual(state.applyToSelection(.paint), .success(.unchanged))
        XCTAssertTrue(state.canRedo)
    }

    func testU10LayerSelectionDoesNotCreateHistoryButRealEditRestoresSelection() throws {
        let secondID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let state = CanvasDocumentFixture(tool: .select)
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [
            SpatialInstrumentLayer(id: layerID, name: "Erste", color: .orange),
            SpatialInstrumentLayer(id: secondID, name: "Zweite", color: .blue)
        ]))
        XCTAssertEqual(state.workspace.selectedLayerID, layerID)

        state.updateWorkspace { $0.selectLayer(secondID) }
        XCTAssertEqual(state.workspace.selectedLayerID, secondID)
        XCTAssertEqual(state.undoDepth, 0)

        state.updateWorkspace(named: "Ebene umbenennen", coalescingKey: "layer:\(secondID):name") {
            $0.updateSelectedLayer { $0.name = "Zweite neu" }
        }
        XCTAssertEqual(state.undoDepth, 1)
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace.selectedLayerID, secondID)
        XCTAssertEqual(state.workspace.selectedLayer.name, "Zweite")
    }

    func testU11ConsecutiveNameEditsCoalesceAndUndoOriginalName() {
        let state = state(with: [])
        let key = "layer:\(layerID):name"
        for name in ["E", "Eb", "Ebe", "Eben", "Ebene"] {
            state.updateWorkspace(named: "Ebene umbenennen", coalescingKey: key) {
                $0.updateSelectedLayer { $0.name = name }
            }
        }
        XCTAssertEqual(state.undoDepth, 1)
        XCTAssertEqual(state.workspace.selectedLayer.name, "Ebene")
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace.selectedLayer.name, "Undo-Testebene")
    }

    func testU12NameThenColorAreSeparateCoalescingEntries() {
        let state = state(with: [])
        state.updateWorkspace(named: "Ebene umbenennen", coalescingKey: "layer:\(layerID):name") {
            $0.updateSelectedLayer { $0.name = "Neu" }
        }
        state.updateWorkspace(named: "Farbe ändern", coalescingKey: "layer:\(layerID):color") {
            $0.updateSelectedLayer { $0.color = .purple }
        }
        XCTAssertEqual(state.undoDepth, 2)
        XCTAssertEqual(state.undoActionName, "Farbe ändern")
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace.selectedLayer.name, "Neu")
        XCTAssertEqual(state.workspace.selectedLayer.color, .orange)
    }

    func testU13AbortedPerformEditRestoresWorkspaceWithoutHistory() {
        let state = state(with: [])
        let before = state.workspace
        let accepted = state.performEdit(named: "Ton zuweisen") { canvas in
            canvas.updateWorkspace { $0.setNoteTransition(.holdUntilNext) }
            return false
        }
        XCTAssertFalse(accepted)
        XCTAssertEqual(state.workspace, before)
        XCTAssertEqual(state.undoDepth, 0)
    }

    func testU5PresetReplacementClearsUndoAndRedoHistory() throws {
        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let interactionState = state(with: [cell])
        XCTAssertTrue(interactionState.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertEqual(interactionState.applyToSelection(.erase), .success(.applied(changedCells: 1)))
        XCTAssertTrue(interactionState.undo())
        XCTAssertTrue(interactionState.canRedo)

        interactionState.replaceWorkspace(self.state(with: []).workspace)
        XCTAssertFalse(interactionState.canUndo)
        XCTAssertFalse(interactionState.canRedo)
    }

    func testU6HistoryDepthIsBoundedAtOneHundredEntries() throws {
        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let state = state(with: [cell])
        for index in 0...100 {
            state.updateWorkspace {
                $0.setNoteTransition(index.isMultiple(of: 2) ? .holdUntilNext : .retrigger)
            }
        }

        XCTAssertEqual(state.undoDepth, 100)
        for _ in 0..<100 { XCTAssertTrue(state.undo()) }
        XCTAssertFalse(state.undo())
    }

    func testU7UndoNamesDescribeEraseAndAssignment() throws {
        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let state = state(with: [cell])
        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))

        XCTAssertEqual(state.applyToSelection(.erase), .success(.applied(changedCells: 1)))
        XCTAssertEqual(state.undoActionName, "Delete cells")
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.redoActionName, "Delete cells")
        XCTAssertTrue(state.redo())

        XCTAssertTrue(state.undo())
        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertEqual(state.applyToSelection(.setAction(action)), .success(.applied(changedCells: 1)))
        XCTAssertEqual(state.undoActionName, "Assign note")
    }

    private func state(
        with cells: Set<PolarMetricGridCell>,
        overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
    ) -> CanvasDocumentFixture {
        let state = CanvasDocumentFixture(tool: .select)
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [
            SpatialInstrumentLayer(
                id: layerID, name: "Undo-Testebene", color: .orange,
                polarCells: cells,
                routings: [SpatialRouting(
                    target: target,
                    program: .chord(notes: [60], velocity: 100, transition: .retrigger)
                )],
                polarCellOverrides: overrides
            )
        ]))
        return state
    }

    private func layer(id: UUID) -> SpatialInstrumentLayer {
        SpatialInstrumentLayer(
            id: id, name: "Transition layer", color: .orange,
            routings: [SpatialRouting(
                target: target,
                program: .chord(notes: [60], velocity: 100, transition: .retrigger)
            )]
        )
    }

    private func cell(at point: CGPoint) -> PolarMetricGridCell? {
        let geometry = MetricCanvasGeometry(
            size: canvasSize, viewport: CanvasDocumentFixture().viewport
        )
        guard let metric = geometry.boundedMetricPoint(forScreenPoint: point) else { return nil }
        return PolarMetricGridCell(point: metric, grid: .quarterMeter)
    }
}
