import XCTest

// Geometry and dormant-address bulk tests use the reference-field editor’s
// explicit area-selection mode. Instrument ownership is covered by CanvasEditingTests.
import SickPLSControlCore
import SickPLSCore
@testable import SickPLSMonitorKit

final class SpatialCellBulkEditTests: XCTestCase {
    private let layerID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let target = SpatialRoutingTarget.midiNote(channel: 1)

    private var action: SpatialCellAction {
        SpatialCellAction(target: target, value: .note(number: 60, velocity: 100))
    }

    private func workspace(locked: Bool = false, cells: Set<PolarMetricGridCell> = [], overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]) -> SpatialInstrumentWorkspace {
        SpatialInstrumentWorkspace(layers: [SpatialInstrumentLayer(id: layerID, name: "x", color: .orange,
            isVisible: true, isActive: true, isLocked: locked, isSoloed: false,
            polarCells: cells, routings: [SpatialRouting(target: target, program: .constant(1))], polarCellOverrides: overrides)])
    }

    func testBulkOperationsPreserveDormantAssignmentAndEraseIt() {
        let a = PolarMetricGridCell(ring: 1, angularIndex: 1)
        let b = PolarMetricGridCell(ring: 1, angularIndex: 2)
        var cells: Set<PolarMetricGridCell> = [a]
        var overrides = [b: [action]]
        let result = SpatialCellBulkEdit.apply(.setAction(action), to: [a, b], isLocked: false, layerID: layerID,
                                               routings: [SpatialRouting(target: target, program: .constant(1))], cells: &cells, overrides: &overrides, addressBudget: 10)
        XCTAssertEqual(result, .success(.applied(changedCells: 1)))
        XCTAssertEqual(cells, [a]); XCTAssertEqual(overrides[a], [action]); XCTAssertEqual(overrides[b], [action])
        XCTAssertEqual(SpatialCellBulkEdit.apply(.paint, to: [b], isLocked: false, layerID: layerID,
                                                 routings: [], cells: &cells, overrides: &overrides, addressBudget: 10), .success(.applied(changedCells: 1)))
        XCTAssertTrue(cells.contains(b))
        XCTAssertEqual(SpatialCellBulkEdit.apply(.erase, to: [b], isLocked: false, layerID: layerID,
                                                 routings: [], cells: &cells, overrides: &overrides, addressBudget: 10), .success(.applied(changedCells: 1)))
        XCTAssertNil(overrides[b])
    }

    func testLockedAndEmptySelectionsAreNoMutation() {
        let c = PolarMetricGridCell(ring: 1, angularIndex: 1)
        var cells: Set<PolarMetricGridCell> = [c]; var overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
        XCTAssertEqual(SpatialCellBulkEdit.apply(.paint, to: [], isLocked: true, layerID: layerID, routings: [], cells: &cells, overrides: &overrides, addressBudget: 1), .failure(.emptySelection))
        XCTAssertEqual(SpatialCellBulkEdit.apply(.paint, to: [c], isLocked: true, layerID: layerID, routings: [], cells: &cells, overrides: &overrides, addressBudget: 1), .failure(.layerLocked(layerID: layerID)))
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50); state.replaceWorkspace(workspace(locked: true, cells: [c]))
        XCTAssertTrue(state.beginDrag(at: CGPoint(x: 400, y: 700), canvasSize: CGSize(width: 800, height: 800)))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 400, y: 700), canvasSize: CGSize(width: 800, height: 800)))
        state.endDrag(canvasSize: CGSize(width: 800, height: 800))
        XCTAssertFalse(state.selectedPolarCells.isEmpty)
        let before = state.workspace
        let lockedResults = [SpatialCellBulkOperation.paint, .erase, .setAction(action), .removeActions(target: target)].map { state.applyToSelection($0) }
        XCTAssertTrue(lockedResults.allSatisfy { $0 == .failure(.layerLocked(layerID: layerID)) })
        XCTAssertEqual(state.workspace, before)
    }

    func testSetActionValidationReplacementAndRemove() {
        let c = PolarMetricGridCell(ring: 1, angularIndex: 1)
        var cells: Set<PolarMetricGridCell> = []; var overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
        let scalar = SpatialCellAction(target: target, value: .scalar(0.5))
        XCTAssertEqual(SpatialCellBulkEdit.apply(.setAction(scalar), to: [c], isLocked: false, layerID: layerID, routings: [SpatialRouting(target: target, program: .constant(1))], cells: &cells, overrides: &overrides, addressBudget: 10), .failure(.valueDoesNotFitTarget))
        XCTAssertEqual(SpatialCellBulkEdit.apply(.setAction(action), to: [c], isLocked: false, layerID: layerID, routings: [], cells: &cells, overrides: &overrides, addressBudget: 10), .failure(.targetNotRouted(target)))
        let bad = SpatialCellAction(target: target, value: .note(number: 128, velocity: 100))
        XCTAssertEqual(SpatialCellBulkEdit.apply(.setAction(bad), to: [c], isLocked: false, layerID: layerID, routings: [SpatialRouting(target: target, program: .constant(1))], cells: &cells, overrides: &overrides, addressBudget: 10), .failure(.valueOutOfRange))
        var existing = [c: [action, SpatialCellAction(target: .midiCC(channel: 1, controller: 1), value: .scalar(0.2))]]
        let routings = [SpatialRouting(target: target, program: .constant(1)), SpatialRouting(target: .midiCC(channel: 1, controller: 1), program: .constant(1))]
        XCTAssertEqual(SpatialCellBulkEdit.apply(.setAction(action), to: [c], isLocked: false, layerID: layerID, routings: routings, cells: &cells, overrides: &existing, addressBudget: 10), .success(.applied(changedCells: 1)))
        XCTAssertEqual(SpatialCellBulkEdit.apply(.removeActions(target: target), to: [c], isLocked: false, layerID: layerID, routings: routings, cells: &cells, overrides: &existing, addressBudget: 10), .success(.applied(changedCells: 1)))
        XCTAssertFalse(existing[c]!.contains { $0.target == target })
    }

    func testBudgetAndLayerSelection() {
        let a = PolarMetricGridCell(ring: 1, angularIndex: 1); let b = PolarMetricGridCell(ring: 1, angularIndex: 2)
        var cells: Set<PolarMetricGridCell> = [a]; var overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
        let before = (cells, overrides)
        XCTAssertEqual(SpatialCellBulkEdit.apply(.paint, to: [b], isLocked: false, layerID: layerID, routings: [], cells: &cells, overrides: &overrides, addressBudget: 1), .failure(.addressBudgetExceeded(limit: 1)))
        XCTAssertEqual(cells, before.0); XCTAssertEqual(overrides, before.1)
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50); let secondID = UUID(); state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [SpatialInstrumentLayer(id: layerID, name: "a", color: .orange), SpatialInstrumentLayer(id: secondID, name: "b", color: .blue)])); state.updateWorkspace { $0.selectLayer(secondID) }
        let point = CGPoint(x: 400, y: 700)
        let geometry = MetricCanvasGeometry(size: CGSize(width: 800, height: 800), viewport: state.viewport)
        let targetCell = PolarMetricGridCell(point: try! XCTUnwrap(geometry.boundedMetricPoint(forScreenPoint: point)), grid: state.workspace.grid)
        XCTAssertTrue(state.beginDrag(at: point, canvasSize: CGSize(width: 800, height: 800))); state.endDrag(canvasSize: CGSize(width: 800, height: 800))
        XCTAssertEqual(state.selectedPolarCells, [targetCell]); _ = state.applyToSelection(.paint)
        XCTAssertTrue(state.workspace.selectedLayerID == secondID); XCTAssertTrue(state.workspace.layers[1].polarCells.contains(targetCell)); XCTAssertFalse(state.workspace.layers[0].polarCells.contains(targetCell))
    }

    func testSecondaryGestureHysteresisAndCancellation() {
        var gesture = SecondaryPointerGesture(); XCTAssertEqual(gesture.down(at: CGPoint(x: 10, y: 10), inside: true), .none)
        XCTAssertEqual(gesture.dragged(to: CGPoint(x: 13, y: 10)), .none)
        XCTAssertEqual(gesture.up(at: CGPoint(x: 13, y: 10), inside: true), .openContextMenu(at: CGPoint(x: 13, y: 10)))
        XCTAssertEqual(gesture.down(at: CGPoint(x: 0, y: 0), inside: true), .none)
        XCTAssertEqual(gesture.dragged(to: CGPoint(x: 4, y: 0)), .pan(CGSize(width: 4, height: 0)))
        XCTAssertEqual(gesture.dragged(to: CGPoint(x: 2, y: 0)), .pan(CGSize(width: -2, height: 0)))
        XCTAssertEqual(gesture.up(at: CGPoint(x: 0, y: 0), inside: true), .none)
        XCTAssertEqual(gesture.down(at: CGPoint(x: 1, y: 1), inside: true), .none); gesture.cancel(); XCTAssertEqual(gesture.up(at: CGPoint(x: 1, y: 1), inside: true), .none)
        XCTAssertEqual(gesture.down(at: CGPoint(x: 1, y: 1), inside: false), .none); XCTAssertEqual(gesture.up(at: CGPoint(x: 1, y: 1), inside: true), .none)
        var jitter = SecondaryPointerGesture(); _ = jitter.down(at: .zero, inside: true); XCTAssertEqual(jitter.dragged(to: CGPoint(x: 3.9, y: 0)), .none); XCTAssertEqual(jitter.up(at: CGPoint(x: 3.9, y: 0), inside: true), .openContextMenu(at: CGPoint(x: 3.9, y: 0)))
        var sum = SecondaryPointerGesture(); _ = sum.down(at: CGPoint(x: 2, y: 2), inside: true); let first = sum.dragged(to: CGPoint(x: 7, y: 4)); let second = sum.dragged(to: CGPoint(x: 10, y: 1)); XCTAssertEqual(first, .pan(CGSize(width: 5, height: 2))); XCTAssertEqual(second, .pan(CGSize(width: 3, height: -3))); XCTAssertEqual(sum.up(at: CGPoint(x: 10, y: 1), inside: true), .none)
        var returnTrip = SecondaryPointerGesture(); _ = returnTrip.down(at: .zero, inside: true); _ = returnTrip.dragged(to: CGPoint(x: 10, y: 0)); _ = returnTrip.dragged(to: .zero); XCTAssertEqual(returnTrip.up(at: .zero, inside: true), .none)
        var outsideUp = SecondaryPointerGesture(); _ = outsideUp.down(at: .zero, inside: true); XCTAssertEqual(outsideUp.up(at: .zero, inside: false), .none)
        var secondDown = SecondaryPointerGesture(); _ = secondDown.down(at: .zero, inside: true); _ = secondDown.down(at: CGPoint(x: 5, y: 5), inside: true); XCTAssertEqual(secondDown.up(at: CGPoint(x: 5, y: 5), inside: true), .openContextMenu(at: CGPoint(x: 5, y: 5)))
        var nonfinite = SecondaryPointerGesture(); XCTAssertEqual(nonfinite.down(at: CGPoint(x: CGFloat.infinity, y: 0), inside: true), .none); XCTAssertEqual(nonfinite.up(at: .zero, inside: true), .none)
    }

    func testContextMenuSelectionFollowsToolAndSelection() {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        let size = CGSize(width: 800, height: 800); let point = CGPoint(x: 400, y: 700); let other = CGPoint(x: 500, y: 700)
        XCTAssertTrue(state.contextMenuSelection(at: point, canvasSize: size)); XCTAssertEqual(state.selectedPolarCells.count, 1)
        let selected = state.selectedPolarCells
        XCTAssertTrue(state.contextMenuSelection(at: other, canvasSize: size)); XCTAssertEqual(state.selectedPolarCells.count, 1); XCTAssertNotEqual(state.selectedPolarCells, selected)
        state.extendSelection(toScreenPoint: point, canvasSize: size); let multiple = state.selectedPolarCells
        XCTAssertTrue(state.contextMenuSelection(at: point, canvasSize: size)); XCTAssertEqual(state.selectedPolarCells, multiple)
        let beforeEmpty = state.selectedPolarCells
        XCTAssertFalse(state.contextMenuSelection(at: CGPoint(x: CGFloat.infinity, y: 0), canvasSize: size)); XCTAssertEqual(state.selectedPolarCells, beforeEmpty)
        state.select(tool: .pan); XCTAssertTrue(state.contextMenuSelection(at: point, canvasSize: size))
    }

    func testEveryBulkOperationUsesRealMixedSelectionStatePath() {
        let points = [CGPoint(x: 400, y: 700), CGPoint(x: 450, y: 700), CGPoint(x: 500, y: 700)]
        func selectedState() -> MetricCanvasInteractionState {
            var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
            let geometry = MetricCanvasGeometry(size: CGSize(width: 800, height: 800), viewport: state.viewport)
            let cells = points.compactMap { geometry.boundedMetricPoint(forScreenPoint: $0).map { PolarMetricGridCell(point: $0, grid: state.workspace.grid) } }
            let layer = SpatialInstrumentLayer(id: layerID, name: "x", color: .orange, polarCells: [cells[0]], routings: [SpatialRouting(target: target, program: .constant(1))], polarCellOverrides: [cells[2]: [action]])
            state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [layer]))
            for (index, point) in points.enumerated() {
                _ = state.beginDrag(at: point, canvasSize: CGSize(width: 800, height: 800), modifiers: index == 0 ? [] : [.command])
                state.endDrag(canvasSize: CGSize(width: 800, height: 800))
            }
            return state
        }
        for operation in [SpatialCellBulkOperation.paint, .erase, .setAction(action), .removeActions(target: target)] {
            var state = selectedState(); XCTAssertEqual(state.selectedPolarCells.count, 3)
            XCTAssertNotEqual(state.applyToSelection(operation), .failure(.layerLocked(layerID: layerID)))
        }
    }

    func testDormantAssignmentIsSilentUntilPaintAndSurvivesJSONRoundTrip() throws {
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try .build(value: 100, fieldFlags: 0)])
        let point = try XCTUnwrap(MetricScanProjection().project(profile).first?.point)
        let cell = PolarMetricGridCell(point: point, grid: .halfMeter)
        let layer = SpatialInstrumentLayer(id: layerID, name: "x", color: .orange, polarCells: [], routings: [SpatialRouting(target: target, program: .constant(1))], polarCellOverrides: [cell: [action]])
        var workspace = SpatialInstrumentWorkspace(grid: .halfMeter, layers: [layer])
        let evaluator = SpatialInstrumentEvaluator(); XCTAssertEqual(evaluator.evaluate(activeCells: workspace.selectedLayer.polarCells.contains(cell) ? [layerID: cell] : [:], workspace: workspace).first?.value, .inactive)
        workspace = try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(evaluator.evaluate(activeCells: workspace.selectedLayer.polarCells.contains(cell) ? [layerID: cell] : [:], workspace: workspace).first?.value, .inactive)
        _ = workspace.applyBulk(.paint, to: [cell], addressBudget: SpatialDocumentBudget.production.addressesPerLayer)
        XCTAssertEqual(evaluator.evaluate(activeCells: workspace.selectedLayer.polarCells.contains(cell) ? [layerID: cell] : [:], workspace: workspace).first?.value, .notes([.init(number: 60, velocity: 100)], transition: .retrigger))
    }

    func testMenuHasSixItemsIncludingDeactivateAndNamedReasons() {
        let layer = SpatialInstrumentLayer(id: layerID, name: "x", color: .orange)
        let empty = SpatialCellBulkMenu.items(layer: layer, selectionCount: 0)
        XCTAssertEqual(empty.count, 6); XCTAssertTrue(empty.allSatisfy { !$0.isEnabled && $0.disabledReason == .emptySelection })
        let locked = SpatialInstrumentLayer(id: layerID, name: "x", color: .orange, isLocked: true)
        XCTAssertTrue(SpatialCellBulkMenu.items(layer: locked, selectionCount: 1).allSatisfy { $0.disabledReason == .layerLocked })
        let noteLayer = SpatialInstrumentLayer(id: layerID, name: "x", color: .orange, routings: [SpatialRouting(target: target, program: .constant(1))])
        let noteItems = SpatialCellBulkMenu.items(layer: noteLayer, selectionCount: 1)
        XCTAssertTrue(noteItems[0].isEnabled); XCTAssertTrue(noteItems[1].isEnabled)
        XCTAssertFalse(noteItems[2].isEnabled); XCTAssertEqual(noteItems[2].disabledReason, .valueDoesNotFitTarget)
        XCTAssertEqual(noteItems.map(\.kind), [.activate, .assignNote, .assignScalar, .removeActions, .deactivate, .erase])
    }

    func testAssignAndActivateUsesRealSelectionAndMakesDormantNotePlayable() throws {
        let points = [CGPoint(x: 400, y: 700), CGPoint(x: 450, y: 700)]
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50)
        let size = CGSize(width: 800, height: 800)
        let geometry = MetricCanvasGeometry(size: size, viewport: state.viewport)
        let cells = points.compactMap { geometry.boundedMetricPoint(forScreenPoint: $0).map { PolarMetricGridCell(point: $0, grid: state.workspace.grid) } }
        let layer = SpatialInstrumentLayer(id: layerID, name: "x", color: .orange,
                                           routings: [SpatialRouting(target: target, program: .constant(1))])
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [layer]))
        for (index, point) in points.enumerated() {
            XCTAssertTrue(state.beginDrag(at: point, canvasSize: size, modifiers: index == 0 ? [] : [.command]))
            state.endDrag(canvasSize: size)
        }
        XCTAssertEqual(state.selectedPolarCells, Set(cells))
        let assignment = SpatialCellAction(target: target, value: .note(number: 60, velocity: 100))
        XCTAssertEqual(state.applyToSelection(.assignAndActivate(assignment)), .success(.applied(changedCells: 2)))
        XCTAssertEqual(state.workspace.selectedLayer.polarCells, Set(cells))
        XCTAssertEqual(SpatialInstrumentEvaluator().evaluate(activeCells: [layerID: cells[0]], workspace: state.workspace).first?.value,
                       .notes([.init(number: 60, velocity: 100)], transition: .retrigger))
    }

    func testAssignAndActivateLockedSelectionIsAtomic() {
        var state = selectedStateForBulkTests(locked: true)
        let before = state.workspace
        XCTAssertEqual(state.applyToSelection(.assignAndActivate(action)), .failure(.layerLocked(layerID: layerID)))
        XCTAssertEqual(state.workspace, before)
    }

    func testAssignAndActivateWrongTypeIsAtomic() {
        var state = selectedStateForBulkTests()
        let before = state.workspace
        let wrong = SpatialCellAction(target: target, value: .scalar(0.5))
        XCTAssertEqual(state.applyToSelection(.assignAndActivate(wrong)), .failure(.valueDoesNotFitTarget))
        XCTAssertEqual(state.workspace, before)
    }

    func testAssignAndActivateBudgetRejectionDoesNotPaint() {
        let cell = PolarMetricGridCell(ring: 1, angularIndex: 1)
        var cells: Set<PolarMetricGridCell> = []; var overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
        let before = (cells, overrides)
        let result = SpatialCellBulkEdit.apply(.assignAndActivate(action), to: [cell], isLocked: false,
                                               layerID: layerID,
                                               routings: [SpatialRouting(target: target, program: .constant(1))],
                                               cells: &cells, overrides: &overrides, addressBudget: 0)
        XCTAssertEqual(result, .failure(.addressBudgetExceeded(limit: 0)))
        XCTAssertEqual(cells, before.0); XCTAssertEqual(overrides, before.1)
    }
    func testPaintMixedSelectionChangesOnlyUnpaintedCells() {
        var state = selectedStateForBulkTests()
        XCTAssertEqual(state.applyToSelection(.paint), .success(.applied(changedCells: 2)))
        XCTAssertEqual(state.workspace.selectedLayer.polarCells.count, 3)
    }

    func testEraseMixedSelectionRemovesCellsAndOverrides() {
        var state = selectedStateForBulkTests()
        XCTAssertEqual(state.applyToSelection(.erase), .success(.applied(changedCells: 2)))
        XCTAssertTrue(state.workspace.selectedLayer.polarCells.isEmpty)
        XCTAssertTrue(state.workspace.selectedLayer.polarCellOverrides.isEmpty)
    }

    func testSetActionMixedSelectionLeavesPaintStateUntouched() {
        var state = selectedStateForBulkTests(); let before = state.workspace.selectedLayer.polarCells
        XCTAssertEqual(state.applyToSelection(.setAction(action)), .success(.applied(changedCells: 2)))
        XCTAssertEqual(state.workspace.selectedLayer.polarCells, before)
    }

    func testRemoveActionsMixedSelectionRemovesOnlyTarget() {
        var state = selectedStateForBulkTests()
        XCTAssertEqual(state.applyToSelection(.removeActions(target: target)), .success(.applied(changedCells: 1)))
        XCTAssertTrue(state.workspace.selectedLayer.polarCellOverrides.isEmpty)
    }

    func testLockedPaintUsesSelectedStatePath() { assertLocked(.paint) }
    func testLockedEraseUsesSelectedStatePath() { assertLocked(.erase) }
    func testLockedSetActionUsesSelectedStatePath() { assertLocked(.setAction(action)) }
    func testLockedRemoveActionsUsesSelectedStatePath() { assertLocked(.removeActions(target: target)) }

    func testEmptySelectionOnUnlockedLayerIsRejected() {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50); state.replaceWorkspace(workspace())
        XCTAssertEqual(state.applyToSelection(.paint), .failure(.emptySelection))
    }

    func testEmptySelectionOnLockedLayerIsRejected() {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50); state.replaceWorkspace(workspace(locked: true))
        XCTAssertEqual(state.applyToSelection(.paint), .failure(.emptySelection))
    }

    func testRemoveActionsDeletesLastTargetKey() {
        let cell = PolarMetricGridCell(ring: 1, angularIndex: 1); var cells: Set<PolarMetricGridCell> = []; var overrides = [cell: [action]]
        XCTAssertEqual(SpatialCellBulkEdit.apply(.removeActions(target: target), to: [cell], isLocked: false, layerID: layerID, routings: [], cells: &cells, overrides: &overrides, addressBudget: 10), .success(.applied(changedCells: 1)))
        XCTAssertNil(overrides[cell])
    }

    func testSetActionKeepsForeignTarget() {
        let cell = PolarMetricGridCell(ring: 1, angularIndex: 1); let foreign = SpatialCellAction(target: .midiCC(channel: 1, controller: 1), value: .scalar(0.2))
        var cells: Set<PolarMetricGridCell> = []; var overrides = [cell: [foreign]]
        let routings = [SpatialRouting(target: target, program: .constant(1)), SpatialRouting(target: foreign.target, program: .constant(1))]
        XCTAssertEqual(SpatialCellBulkEdit.apply(.setAction(action), to: [cell], isLocked: false, layerID: layerID, routings: routings, cells: &cells, overrides: &overrides, addressBudget: 10), .success(.applied(changedCells: 1)))
        XCTAssertEqual(overrides[cell]?.map(\.target), [foreign.target, target])
    }

    func testBudgetAcceptsExactBoundary() {
        let cell = PolarMetricGridCell(ring: 1, angularIndex: 1); var cells: Set<PolarMetricGridCell> = [cell]; var overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
        XCTAssertEqual(SpatialCellBulkEdit.apply(.paint, to: [cell], isLocked: false, layerID: layerID, routings: [], cells: &cells, overrides: &overrides, addressBudget: 1), .success(.unchanged))
    }

    func testBudgetRejectsBoundaryPlusOne() {
        let a = PolarMetricGridCell(ring: 1, angularIndex: 1); let b = PolarMetricGridCell(ring: 1, angularIndex: 2); var cells: Set<PolarMetricGridCell> = [a]; var overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
        XCTAssertEqual(SpatialCellBulkEdit.apply(.paint, to: [b], isLocked: false, layerID: layerID, routings: [], cells: &cells, overrides: &overrides, addressBudget: 1), .failure(.addressBudgetExceeded(limit: 1)))
    }

    func testScalarOnNoteIsRejected() {
        assertRejected(.scalar(0.5), as: .valueDoesNotFitTarget)
    }

    func testUnroutedTargetIsRejected() {
        let c = PolarMetricGridCell(ring: 1, angularIndex: 1); var cells: Set<PolarMetricGridCell> = []; var overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
        XCTAssertEqual(SpatialCellBulkEdit.apply(.setAction(action), to: [c], isLocked: false, layerID: layerID, routings: [], cells: &cells, overrides: &overrides, addressBudget: 10), .failure(.targetNotRouted(target)))
    }

    func testNoteAbove127IsRejected() { assertRejected(.note(number: 128, velocity: 100), as: .valueOutOfRange) }

    func testGestureClickOpensMenu() {
        var gesture = SecondaryPointerGesture(); _ = gesture.down(at: .zero, inside: true)
        XCTAssertEqual(gesture.up(at: CGPoint(x: 1, y: 1), inside: true), .openContextMenu(at: CGPoint(x: 1, y: 1)))
    }

    func testGestureThirtyNinePointJitterDoesNotPan() {
        var gesture = SecondaryPointerGesture(); _ = gesture.down(at: .zero, inside: true)
        XCTAssertEqual(gesture.dragged(to: CGPoint(x: 3.9, y: 0)), .none)
    }

    func testGesturePanDeltasSumToNetMovement() {
        var gesture = SecondaryPointerGesture(); _ = gesture.down(at: CGPoint(x: 2, y: 2), inside: true)
        XCTAssertEqual(gesture.dragged(to: CGPoint(x: 7, y: 4)), .pan(CGSize(width: 5, height: 2)))
        XCTAssertEqual(gesture.dragged(to: CGPoint(x: 10, y: 1)), .pan(CGSize(width: 3, height: -3)))
    }

    func testGestureReturnToOriginDoesNotOpenMenu() {
        var gesture = SecondaryPointerGesture(); _ = gesture.down(at: .zero, inside: true); _ = gesture.dragged(to: CGPoint(x: 10, y: 0)); _ = gesture.dragged(to: .zero)
        XCTAssertEqual(gesture.up(at: .zero, inside: true), .none)
    }

    func testGestureUpOutsideDoesNotOpenMenu() {
        var gesture = SecondaryPointerGesture(); _ = gesture.down(at: .zero, inside: true)
        XCTAssertEqual(gesture.up(at: .zero, inside: false), .none)
    }

    func testGestureCancelSuppressesFollowingUp() {
        var gesture = SecondaryPointerGesture(); _ = gesture.down(at: .zero, inside: true); gesture.cancel()
        XCTAssertEqual(gesture.up(at: .zero, inside: true), .none)
    }

    func testGestureOutsideDownCannotOpenInsideUp() {
        var gesture = SecondaryPointerGesture(); _ = gesture.down(at: .zero, inside: false)
        XCTAssertEqual(gesture.up(at: .zero, inside: true), .none)
    }

    func testGestureSecondDownReplacesFirst() {
        var gesture = SecondaryPointerGesture(); _ = gesture.down(at: .zero, inside: true); _ = gesture.down(at: CGPoint(x: 5, y: 5), inside: true)
        XCTAssertEqual(gesture.up(at: CGPoint(x: 5, y: 5), inside: true), .openContextMenu(at: CGPoint(x: 5, y: 5)))
    }

    func testGestureNonFinitePointAborts() {
        var gesture = SecondaryPointerGesture(); _ = gesture.down(at: CGPoint(x: CGFloat.infinity, y: 0), inside: true)
        XCTAssertEqual(gesture.up(at: .zero, inside: true), .none)
    }

    func testContextMenuSelectedCellKeepsMultipleSelection() {
        var state = stateWithTwoSelectedCells(); let before = state.selectedPolarCells
        XCTAssertTrue(state.contextMenuSelection(at: CGPoint(x: 400, y: 700), canvasSize: CGSize(width: 800, height: 800)))
        XCTAssertEqual(state.selectedPolarCells, before)
    }

    func testContextMenuUnselectedCellReplacesSelection() {
        var state = stateWithTwoSelectedCells()
        XCTAssertTrue(state.contextMenuSelection(at: CGPoint(x: 500, y: 700), canvasSize: CGSize(width: 800, height: 800)))
        XCTAssertEqual(state.selectedPolarCells.count, 1)
    }

    func testContextMenuEmptyCanvasPointKeepsSelection() {
        var state = stateWithTwoSelectedCells(); let before = state.selectedPolarCells
        XCTAssertFalse(state.contextMenuSelection(at: CGPoint(x: 2000, y: 2000), canvasSize: CGSize(width: 800, height: 800)))
        XCTAssertEqual(state.selectedPolarCells, before)
    }

    func testContextMenuPaintToolIsRejected() {
        var state = stateWithTwoSelectedCells(); state.select(tool: .pan)
        XCTAssertTrue(state.contextMenuSelection(at: CGPoint(x: 400, y: 700), canvasSize: CGSize(width: 800, height: 800)))
    }

    func testMenuNoRoutingNamesReasonForAssignments() {
        let layer = SpatialInstrumentLayer(id: layerID, name: "x", color: .orange)
        let items = SpatialCellBulkMenu.items(layer: layer, selectionCount: 1)
        XCTAssertEqual(items[2].disabledReason, .noRouting); XCTAssertEqual(items[3].disabledReason, .noRouting)
    }

    private func assertLocked(_ operation: SpatialCellBulkOperation) {
        var state = selectedStateForBulkTests(locked: true); let before = state.workspace
        XCTAssertEqual(state.applyToSelection(operation), .failure(.layerLocked(layerID: layerID))); XCTAssertEqual(state.workspace, before)
    }

    private func assertRejected(_ value: SpatialCellValue, as rejection: SpatialCellBulkRejection) {
        let c = PolarMetricGridCell(ring: 1, angularIndex: 1); var cells: Set<PolarMetricGridCell> = []; var overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
        let result = SpatialCellBulkEdit.apply(.setAction(.init(target: target, value: value)), to: [c], isLocked: false, layerID: layerID, routings: [SpatialRouting(target: target, program: .constant(1))], cells: &cells, overrides: &overrides, addressBudget: 10)
        XCTAssertEqual(result, .failure(rejection))
    }

    private func selectedStateForBulkTests(locked: Bool = false) -> MetricCanvasInteractionState {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50); let size = CGSize(width: 800, height: 800)
        let points = [CGPoint(x: 400, y: 700), CGPoint(x: 450, y: 700), CGPoint(x: 500, y: 700)]
        let geometry = MetricCanvasGeometry(size: size, viewport: state.viewport)
        let cells = points.compactMap { geometry.boundedMetricPoint(forScreenPoint: $0).map { PolarMetricGridCell(point: $0, grid: state.workspace.grid) } }
        let layer = SpatialInstrumentLayer(id: layerID, name: "x", color: .orange, isLocked: locked, polarCells: [cells[0]], routings: [SpatialRouting(target: target, program: .constant(1))], polarCellOverrides: [cells[2]: [action]])
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [layer]))
        for (index, point) in points.enumerated() {
            XCTAssertTrue(state.beginDrag(at: point, canvasSize: size, modifiers: index == 0 ? [] : [.command]))
            state.endDrag(canvasSize: size)
        }
        return state
    }

    private func stateWithTwoSelectedCells() -> MetricCanvasInteractionState {
        var state = MetricCanvasInteractionState(tool: .select, selectionMaximumRadiusMeters: 50); let size = CGSize(width: 800, height: 800)
        for (index, point) in [CGPoint(x: 400, y: 700), CGPoint(x: 450, y: 700)].enumerated() {
            XCTAssertTrue(state.beginDrag(at: point, canvasSize: size, modifiers: index == 0 ? [] : [.command]))
            state.endDrag(canvasSize: size)
        }
        return state
    }
}

extension SpatialCellBulkEditTests {
    func testPitchInversionDirectionThreeRoundtripNonNotesAndOverflowAreAtomicValues() throws {
        let original = SpatialCellValue.chord(notes: [60, 64, 67], velocity: 100)
        XCTAssertEqual(try SpatialPitchOperation.invertDown.applying(to: original), .chord(notes: [55, 60, 64], velocity: 100))
        XCTAssertEqual(try SpatialPitchOperation.invertUp.applying(to: original), .chord(notes: [64, 67, 72], velocity: 100))
        var result = original
        for _ in 0..<3 { result = try SpatialPitchOperation.invertDown.applying(to: result) }
        for _ in 0..<3 { result = try SpatialPitchOperation.invertUp.applying(to: result) }
        XCTAssertEqual(result, original)
        for value in [SpatialCellValue.scalar(0.5), .programChange(.init(program: 90)), .boolean(true)] {
            XCTAssertEqual(try SpatialPitchOperation.transpose(12).applying(to: value), value)
        }
        XCTAssertEqual(try SpatialPitchOperation.invertDown.applying(to: SpatialCellValue.note(number: 60, velocity: 100)), .note(number: 60, velocity: 100))
        XCTAssertThrowsError(try SpatialPitchOperation.transpose(-1).applying(to: SpatialCellValue.chord(notes: [Int.min], velocity: 100)))
        XCTAssertThrowsError(try SpatialPitchOperation.invertUp.applying(to: SpatialCellValue.chord(notes: [Int.max], velocity: 100)))
    }
}


extension SpatialCellBulkEditTests {
    func testInheritedPitchValuesRejectInvalidProgramsAtPublicBoundary() {
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let layer = SpatialDocumentLayer(id: UUID(), name: "Invalid", color: .blue, isVisible: true,
            isActive: false, isLocked: false, isSoloed: false, cells: [cell],
            routings: [.init(target: .midiNote(channel: 0), program: .scale(rootMIDINote: Int.max, lowestMIDINote: 0,
                highestMIDINote: 127, scale: .major, directionDegrees: 0, ascending: true, transition: .legato))], cellOverrides: [:])
        XCTAssertThrowsError(try SpatialInstrumentCompiler.inheritedValues(in: layer, cells: [cell]))
    }
}
