import XCTest
import PlanariumDomain
@testable import SickPLSMonitorKit

@MainActor final class CanvasEditingTests: XCTestCase {
    let size = CGSize(width: 800, height: 800)
    let cell = PolarMetricGridCell(ring: 2, angularIndex: 8)

    func fixture() -> CanvasDocumentFixture {
        let a = SpatialInstrumentLayer(name: "A", color: .orange)
        let b = SpatialInstrumentLayer(name: "B", color: .blue, polarCells: [cell],
            polarCellOverrides: [cell: [.init(target: .midiNote(channel: 0), value: .note(number: 64, velocity: 90))]])
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(.init(grid: .quarterMeter, layers: [a, b]))
        return state
    }

    func point(_ cell: PolarMetricGridCell, _ state: CanvasDocumentFixture) -> CGPoint {
        let segment = PolarMetricCellSegment(cell: cell, grid: state.workspace.grid)
        return MetricCanvasGeometry(size: size, viewport: state.viewport).screenPoint(for:
            segment.point(radiusMeters: segment.midpoint.radiusMeters, bearingDegrees: segment.midpoint.bearingDegrees))
    }

    func testOwnerRectangleDeletesBWithAActiveThroughContextAndKeyboard() {
        for keyboard in [false, true] {
            let state = fixture()
            let a = state.workspace.layers[0], center = point(cell, state)
            XCTAssertEqual(state.workspace.selectedLayerID, a.id)
            XCTAssertTrue(state.beginDrag(at: .init(x: center.x - 12, y: center.y - 12), canvasSize: size))
            XCTAssertTrue(state.updateDrag(to: .init(x: center.x + 12, y: center.y + 12), canvasSize: size))
            state.endDrag(canvasSize: size)
            if keyboard { XCTAssertTrue(state.perform(.delete)) }
            else { XCTAssertEqual(state.applyToSelection(.erase), .success(.applied(changedCells: 1))) }
            XCTAssertEqual(state.workspace.layers[0], a)
            XCTAssertTrue(state.workspace.layers[1].polarCells.isEmpty)
            XCTAssertTrue(state.workspace.layers[1].polarCellOverrides.isEmpty)
        }
    }

    func testOwnerRightClickThenDeleteUsesHitLayer() {
        let state = fixture()
        let a = state.workspace.layers[0]
        XCTAssertTrue(state.contextMenuSelection(at: point(cell, state), canvasSize: size))
        XCTAssertTrue(state.perform(.delete))
        XCTAssertEqual(state.workspace.layers[0], a)
        XCTAssertTrue(state.workspace.layers[1].polarCells.isEmpty)
        XCTAssertTrue(state.workspace.layers[1].polarCellOverrides.isEmpty)
    }

    func layered() -> CanvasDocumentFixture {
        let a = SpatialInstrumentLayer(name: "A", color: .orange, polarCells: [cell],
            routings: [.init(target: .midiNote(channel: 0), program: .constant(1))],
            polarCellOverrides: [cell: [.init(target: .midiNote(channel: 0), value: .note(number: 60, velocity: 80))]])
        let b = SpatialInstrumentLayer(name: "B", color: .blue, polarCells: [cell, .init(ring: 3, angularIndex: 16)],
            routings: [.init(target: .midiNote(channel: 1), program: .constant(1))],
            polarCellOverrides: [cell: [.init(target: .midiNote(channel: 1), value: .chord(notes: [64, 67], velocity: 90))]])
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(.init(grid: .quarterMeter, layers: [a, b]))
        return state
    }

    func testTopmostHitActivatesItsLayerAndCommandTogglesOnlyItsPair() {
        let state = layered()
        let top = state.workspace.layers[1], p = point(cell, state)
        _ = state.selectCell(atScreenPoint: p, canvasSize: size)
        XCTAssertEqual(state.selectedCells, [.init(layerID: top.id, cell: cell)])
        XCTAssertEqual(state.workspace.selectedLayerID, top.id)
        _ = state.selectCell(atScreenPoint: p, canvasSize: size, modifiers: .command)
        XCTAssertTrue(state.selectedCells.isEmpty)
        _ = state.selectCell(atScreenPoint: .zero, canvasSize: size)
        XCTAssertTrue(state.selectedCells.isEmpty, "Empty positions cannot be selected")
        XCTAssertEqual(state.statusMessage, "Nothing selected")
    }

    func testRectangleSelectsPaintedPairsOnBothLayersAndAssignmentUsesTheirOwnTargets() {
        let state = layered()
        let p = point(cell, state)
        _ = state.beginDrag(at: .init(x: p.x - 15, y: p.y - 15), canvasSize: size)
        _ = state.updateDrag(to: .init(x: p.x + 15, y: p.y + 15), canvasSize: size)
        state.endDrag(canvasSize: size)
        XCTAssertEqual(state.selectedCells.count, 2)
        XCTAssertEqual(state.selectedPolarCells.count, 1, "Overlapping addresses retain separate owners")
        XCTAssertEqual(state.applyToSelection(.setAction(.init(target: .midiNote(channel: 0), value: .note(number: 72, velocity: 100)))),
            .success(.applied(changedCells: 2)))
        for (index, layer) in state.workspace.layers.enumerated() {
            XCTAssertEqual(layer.polarCellOverrides[cell], [.init(target: .midiNote(channel: UInt8(index)), value: .note(number: 72, velocity: 100))])
        }
    }

    func testLockedAndHiddenCellsCannotEnterAnySelectionPathAndReportWhy() {
        for locked in [true, false] {
            let state = fixture()
            state.updateWorkspace { $0.updateLayer($0.layers[1].id) { $0.isLocked = locked; $0.isVisible = locked } }
            let p = point(cell, state)
            _ = state.selectCell(atScreenPoint: p, canvasSize: size)
            XCTAssertTrue(state.selectedCells.isEmpty)
            XCTAssertTrue(state.statusMessage?.contains(locked ? "locked" : "hidden") == true)
            _ = state.contextMenuSelection(at: p, canvasSize: size)
            XCTAssertTrue(state.selectedCells.isEmpty)
            _ = state.perform(.selectAll)
            XCTAssertTrue(state.selectedCells.isEmpty)
            _ = state.selectLayers([state.workspace.layers[1].id])
            XCTAssertTrue(state.selectedCells.isEmpty)
            _ = state.beginDrag(at: .init(x: p.x - 12, y: p.y - 12), canvasSize: size)
            _ = state.updateDrag(to: .init(x: p.x + 12, y: p.y + 12), canvasSize: size)
            state.endDrag(canvasSize: size)
            XCTAssertTrue(state.selectedCells.isEmpty)
        }
    }

    func testLayerListSelectionIsVisibleAndSelectAllIncludesEveryEligibleLayer() {
        let state = layered()
        _ = state.selectLayers([state.workspace.layers[0].id], active: state.workspace.layers[0].id)
        XCTAssertEqual(state.selectedCells.count, 1)
        _ = state.perform(.selectAll)
        XCTAssertEqual(state.selectedCells.count, 3)
        XCTAssertEqual(Set(state.selectedCells.map(\.layerID)), Set(state.workspace.layers.map(\.id)))
        _ = state.selectZone(at: point(cell, state), canvasSize: size)
        XCTAssertEqual(state.selectedCells.count, 1, "Own chord content separates this cell from the layer default")
        XCTAssertEqual(Set(state.selectedCells.map(\.layerID)), [state.workspace.layers[1].id])
    }

    func testShiftClickExtendsRangeAndOptionDragCopiesRatherThanBrushes() {
        let state = layered()
        _ = state.selectCell(atScreenPoint: point(cell, state), canvasSize: size)
        let second = PolarMetricGridCell(ring: 3, angularIndex: 16)
        _ = state.selectCell(atScreenPoint: point(second, state), canvasSize: size, modifiers: .shift)
        XCTAssertEqual(state.selectedCells.count, 3)
        let before = state.workspace, depth = state.undoDepth, start = point(second, state)
        _ = state.beginDrag(at: start, canvasSize: size, modifiers: .option)
        _ = state.updateDrag(to: .init(x: start.x, y: start.y - 50), canvasSize: size)
        state.endDrag(canvasSize: size)
        XCTAssertNotEqual(state.workspace, before)
        XCTAssertEqual(state.undoDepth, depth + 1)
        for (old, new) in zip(before.layers, state.workspace.layers) { XCTAssertTrue(old.polarCells.isSubset(of: new.polarCells)) }
    }

    func testMoveBothLayersKeepsEachOverrideAndUndoRedoBytes() throws {
        let state = layered()
        _ = state.perform(.selectAll)
        let before = state.workspace
        let beforeDocument = state.document.spatial
        _ = state.handleKey(.up)
        let after = state.workspace
        let afterDocument = state.document.spatial
        XCTAssertNotEqual(after, before)
        for (old, new) in zip(before.layers, after.layers) {
            for actions in new.polarCellOverrides.values { XCTAssertTrue(old.polarCellOverrides.values.contains(actions)) }
            for actions in old.polarCellOverrides.values { XCTAssertTrue(new.polarCellOverrides.values.contains(actions)) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertTrue(state.undo()); XCTAssertEqual(state.workspace, before)
        XCTAssertEqual(try encoder.encode(state.document.spatial), try encoder.encode(beforeDocument))
        XCTAssertTrue(state.redo()); XCTAssertEqual(state.workspace, after)
        XCTAssertEqual(try encoder.encode(state.document.spatial), try encoder.encode(afterDocument))
    }

    func testClickSelectedCellReducesOnlyAtReleaseAndEscapeRestoresSelection() {
        let state = layered()
        _ = state.perform(.selectAll)
        let selected = state.selectedCells, p = point(cell, state)
        _ = state.beginDrag(at: p, canvasSize: size)
        XCTAssertEqual(state.selectedCells, selected)
        _ = state.updateDrag(to: .init(x: p.x, y: p.y - 60), canvasSize: size)
        _ = state.handleKey(.escape)
        state.endDrag(canvasSize: size)
        XCTAssertEqual(state.selectedCells, selected)
        _ = state.beginDrag(at: p, canvasSize: size); state.endDrag(canvasSize: size)
        XCTAssertEqual(state.selectedCells, [.init(layerID: state.workspace.layers[1].id, cell: cell)])
    }

    func testPaintAndEraseUseActiveLayerOnlyOneUndoEachAndEscapeCancels() {
        let state = layered()
        let before = state.workspace, p = point(.init(ring: 4, angularIndex: 16), state)
        state.select(tool: .paint)
        let depth = state.undoDepth
        _ = state.beginDrag(at: p, canvasSize: size)
        _ = state.updateDrag(to: .init(x: p.x + 20, y: p.y - 20), canvasSize: size)
        state.endDrag(canvasSize: size)
        let painted = state.workspace
        XCTAssertNotEqual(painted.layers[0], before.layers[0]); XCTAssertEqual(painted.layers[1], before.layers[1])
        XCTAssertEqual(state.undoDepth, depth + 1)
        state.select(tool: .erase)
        _ = state.beginDrag(at: p, canvasSize: size); state.endDrag(canvasSize: size)
        XCTAssertEqual(state.undoDepth, depth + 2)
        let erased = state.workspace
        state.select(tool: .paint)
        _ = state.beginDrag(at: p, canvasSize: size)
        _ = state.handleKey(.escape); state.endDrag(canvasSize: size)
        XCTAssertEqual(state.workspace, erased)
        XCTAssertTrue(state.undo()); XCTAssertEqual(state.workspace, painted)
        XCTAssertTrue(state.undo()); XCTAssertEqual(state.workspace, before)
    }

    func testPaintingHiddenOrLockedActiveLayerAndUnchangedActionHaveMessages() {
        for hidden in [false, true] {
            let state = layered()
            state.updateWorkspace { $0.updateSelectedLayer { $0.isVisible = !hidden; $0.isLocked = !hidden } }
            state.select(tool: .paint)
            let before = state.workspace
            XCTAssertFalse(state.beginDrag(at: point(cell, state), canvasSize: size))
            XCTAssertEqual(state.workspace, before)
            XCTAssertTrue(state.statusMessage?.contains(hidden ? "hidden" : "locked") == true)
        }
        let state = layered()
        XCTAssertEqual(state.applyToSelection(.erase), .failure(.emptySelection))
        XCTAssertEqual(state.statusMessage, "Nothing selected")
        _ = state.perform(.selectAll)
        XCTAssertEqual(state.applyToSelection(.paint), .success(.unchanged))
        XCTAssertEqual(state.statusMessage, "No cells changed")
    }

    func testCopyCutPasteRestoresBothOwnersAndFallbackUsesActiveLayer() throws {
        let state = layered()
        _ = state.perform(.selectAll)
        let before = state.workspace
        _ = state.handleKey(.commandX, modifiers: .command)
        XCTAssertTrue(state.workspace.layers.allSatisfy { $0.polarCells.isEmpty && $0.polarCellOverrides.isEmpty })
        XCTAssertEqual(state.clipboard.count, 3)
        XCTAssertTrue(state.pasteSelection())
        XCTAssertEqual(state.workspace, before)
        XCTAssertEqual(state.selectedCells.count, 3)
        let encoded = try JSONEncoder().encode(state.clipboard)
        state.importClipboard(try JSONDecoder().decode([CanvasCellCopy].self, from: encoded))
        let removedID = state.workspace.layers[1].id
        state.updateWorkspace { $0.selectLayer(removedID); $0.deleteSelectedLayer() }
        XCTAssertTrue(state.pasteSelection())
        XCTAssertEqual(state.workspace.layers.count, 1)
        XCTAssertTrue(state.workspace.selectedLayer.polarCells.contains(.init(ring: 3, angularIndex: 16)))
        XCTAssertEqual(Set(state.selectedCells.map(\.layerID)), [state.workspace.selectedLayerID])
        XCTAssertEqual(state.workspace.selectedLayer.polarCellOverrides[cell],
            [.init(target: .midiNote(channel: 0), value: .chord(notes: [64, 67], velocity: 90))])
    }

    func testPasteToLockedDestinationAndMixedAssignmentRejectAtomically() {
        var state = layered()
        _ = state.perform(.selectAll); XCTAssertTrue(state.copySelection())
        state.updateWorkspace { $0.updateLayer($0.layers[1].id) { $0.isLocked = true } }
        let before = state.workspace
        XCTAssertFalse(state.pasteSelection()); XCTAssertEqual(state.workspace, before)
        XCTAssertTrue(state.statusMessage?.contains("locked") == true)
        state = layered(); _ = state.perform(.selectAll)
        state.updateWorkspace { $0.updateLayer($0.layers[1].id) { $0.routings = [] } }
        state.confirmOutputChange()
        let beforeAssign = state.workspace
        if case .success = state.applyToSelection(.setAction(.init(target: .midiNote(channel: 0), value: .note(number: 72, velocity: 90)))) { XCTFail() }
        XCTAssertEqual(state.workspace, beforeAssign)
        XCTAssertTrue(state.statusMessage?.contains("compatible output") == true)
    }

    func testRemoveOwnValuesDeactivateAndMoveToLayerOperateOnPairs() {
        let state = layered(); _ = state.perform(.selectAll)
        let before = state.workspace
        XCTAssertEqual(state.applyToSelection(.removeOwnValues), .success(.applied(changedCells: 2)))
        XCTAssertTrue(state.workspace.layers.allSatisfy { $0.polarCellOverrides.isEmpty })
        XCTAssertTrue(state.undo()); XCTAssertEqual(state.workspace, before)
        _ = state.perform(.selectAll)
        XCTAssertEqual(state.applyToSelection(.deactivate), .success(.applied(changedCells: 3)))
        XCTAssertTrue(state.workspace.layers.allSatisfy { $0.polarCells.isEmpty })
        XCTAssertFalse(state.workspace.layers[0].polarCellOverrides.isEmpty)
        XCTAssertTrue(state.undo()); _ = state.selectLayers([state.workspace.layers[1].id])
        XCTAssertTrue(state.moveSelection(toLayer: state.workspace.layers[0].id))
        XCTAssertTrue(state.workspace.layers[1].polarCells.isEmpty)
        XCTAssertEqual(state.workspace.layers[0].polarCells.count, 2)
        XCTAssertEqual(state.workspace.layers[0].polarCellOverrides[cell],
            [.init(target: .midiNote(channel: 0), value: .chord(notes: [64, 67], velocity: 90))])
        XCTAssertTrue(state.undo()); XCTAssertEqual(state.workspace, before)
    }

    func testAllEightFrameHandlesTransformBothLayersAndUndoAsOneEdit() throws {
        for handle in CanvasSelectionHandle.allCases {
            let state = layered(); _ = state.perform(.selectAll)
            let bounds = try XCTUnwrap(state.selectionBounds), geometry = MetricCanvasGeometry(size: size, viewport: state.viewport)
            let start = geometry.screenPoint(for: handle.point(in: bounds))
            XCTAssertEqual(state.selectionHandle(at: start, canvasSize: size), handle)
            let before = state.workspace, depth = state.undoDepth
            let handlePoint = handle.point(in: bounds)
            let target = bounds.point(radiusMeters: hypot(handlePoint.xMeters, handlePoint.yMeters) + 0.35,
                bearingDegrees: atan2(handle.point(in: bounds).xMeters, handle.point(in: bounds).yMeters) * 180 / .pi + 22.5)
            _ = state.beginDrag(at: start, canvasSize: size)
            _ = state.updateDrag(to: geometry.screenPoint(for: target), canvasSize: size)
            let preview = state.movePreviewCells
            state.endDrag(canvasSize: size)
            XCTAssertNotEqual(state.workspace, before, "\(handle)")
            XCTAssertEqual(state.selectedPolarCells, preview)
            XCTAssertEqual(state.undoDepth, depth + 1)
            XCTAssertEqual(Set(state.selectedCells.map(\.layerID)), Set(before.layers.map(\.id)))
            XCTAssertTrue(state.undo()); XCTAssertEqual(state.workspace, before)
        }
    }

    func testShiftArrowAcceptsTenStepsAndClampsAtFieldBoundary() {
        let state = layered(); _ = state.perform(.selectAll)
        _ = state.handleKey(.up, modifiers: .shift)
        XCTAssertTrue(state.moveHitBoundary)
        XCTAssertEqual(state.workspace.layers.flatMap { $0.polarCells }.map(\.ring).max(), 7)
        XCTAssertTrue(state.statusMessage?.contains("field edge") == true)
    }

    func testToolKeysAndTemporaryHandLeaveDocumentUnchangedAndPerformanceBlocksEveryEdit() {
        var state = layered(), before = state.workspace
        for (key, tool) in [(MetricCanvasKey.paintTool, MetricCanvasTool.paint), (.eraseTool, .erase), (.handTool, .pan), (.selectTool, .select)] {
            _ = state.handleKey(key); XCTAssertEqual(state.tool, tool)
        }
        state.holdHand(true); XCTAssertEqual(state.effectiveTool, .pan)
        _ = state.beginDrag(at: point(cell, state), canvasSize: size)
        _ = state.updateDrag(to: .init(x: 410, y: 350), canvasSize: size); state.endDrag(canvasSize: size)
        state.holdHand(false); XCTAssertEqual(state.effectiveTool, .select)
        XCTAssertEqual(state.workspace, before)
        _ = state.perform(.selectAll); state.setPerformanceLocked(true); before = state.workspace
        _ = state.handleKey(.up); _ = state.perform(.delete); _ = state.pasteSelection(); _ = state.duplicateSelection()
        XCTAssertEqual(state.workspace, before)
        XCTAssertFalse(state.undo())
    }

    func testContextMenuOffersPaintingOnEmptyPositionAndSelectionActionsOnPaintedCells() {
        let state = layered()
        _ = state.contextMenuSelection(at: point(.init(ring: 4, angularIndex: 16), state), canvasSize: size)
        XCTAssertEqual(SpatialCellBulkMenu.items(in: state.presentation).map(\.kind), [.paintHere])
        XCTAssertTrue(state.paintContextCell())
        _ = state.contextMenuSelection(at: point(cell, state), canvasSize: size)
        XCTAssertTrue(SpatialCellBulkMenu.items(in: state.presentation).contains { $0.kind == .duplicate && $0.isEnabled })
    }

    func testFramePreviewForThreeHundredCellsAcrossThreeLayers() throws {
        let grid = MetricSquareGrid.fiveCentimeter
        var cells: Set<PolarMetricGridCell> = []
        for ring in 8..<18 {
            for bearing in stride(from: -30.0, through: 30, by: 3) {
                let radius = (Double(ring) + 0.5) * grid.cellSizeMeters
                cells.insert(.init(point: .init(xMeters: sin(bearing * .pi / 180) * radius,
                    yMeters: cos(bearing * .pi / 180) * radius), grid: grid))
            }
        }
        cells = Set(cells.sorted { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }.prefix(100))
        XCTAssertEqual(cells.count, 100)
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(.init(grid: grid, layers: (0..<3).map { .init(name: "L\($0)", color: .orange, polarCells: cells) }))
        _ = state.perform(.selectAll)
        XCTAssertEqual(state.selectedCells.count, 300)
        let bounds = try XCTUnwrap(state.selectionBounds), geometry = MetricCanvasGeometry(size: size, viewport: state.viewport)
        let start = try XCTUnwrap(state.presentation.selectionHandleCenter(.outerEnd, canvasSize: size))
        _ = state.beginDrag(at: start, canvasSize: size)
        let began = Date()
        for index in 0..<30 {
            XCTAssertTrue(state.updateDrag(to: .init(x: start.x + CGFloat(index), y: start.y - CGFloat(index)), canvasSize: size))
        }
        let milliseconds = Date().timeIntervalSince(began) * 1000 / 30
        print("BEDIENUNG frame preview 300 cells / 3 layers: \(milliseconds) ms per update")
        XCTAssertFalse(state.movePreviewCells.isEmpty)
        let before = state.workspace
        state.endDrag(canvasSize: size)
        XCTAssertNotEqual(state.workspace, before)
        XCTAssertEqual(Set(state.selectedCells.map(\.layerID)).count, 3)
    }

    func testEscapeCancelsHandGestureInEditAndPerformAndClipboardSurvivesInspectorProjection() {
        for locked in [false, true] {
            let state = layered()
            state.setPerformanceLocked(locked)
            state.holdHand(true)
            let before = state.viewport
            _ = state.beginDrag(at: .init(x: 400, y: 600), canvasSize: size)
            _ = state.updateDrag(to: .init(x: 430, y: 620), canvasSize: size)
            XCTAssertNotEqual(state.viewport, before)
            _ = state.handleKey(.escape)
            XCTAssertEqual(state.viewport, before)
            XCTAssertFalse(state.isDragging)
        }
        let latest = layered(), inspector = latest
        _ = latest.perform(.selectAll); XCTAssertTrue(latest.copySelection())
        inspector.updateWorkspace { $0.updateSelectedLayer { $0.name = "Renamed" } }
        XCTAssertEqual(latest.clipboard, latest.clipboard)
    }

    func testToolSwitchCancelsUncommittedMoveAndPaintPreviews() {
        for tool in [MetricCanvasTool.select, .paint] {
            let state = layered(); _ = state.perform(.selectAll)
            state.select(tool: tool)
            let before = state.workspace, start = point(cell, state)
            _ = state.beginDrag(at: start, canvasSize: size)
            _ = state.updateDrag(to: .init(x: start.x, y: start.y - 40), canvasSize: size)
            XCTAssertFalse(state.movePreviewCells.isEmpty)
            state.select(tool: .pan)
            XCTAssertFalse(state.isDragging); XCTAssertTrue(state.movePreviewCells.isEmpty)
            state.endDrag(canvasSize: size)
            XCTAssertEqual(state.workspace, before)
        }
    }

    func testScalarAssignmentMapsToEachSelectedLayersScalarOutput() {
        let state = layered()
        let targets: [SpatialRoutingTarget] = [.midiCC(channel: 0, controller: 7), .midiPitchBend(channel: 1)]
        state.updateWorkspace { workspace in
            for (index, id) in workspace.layers.map(\.id).enumerated() {
                workspace.updateLayer(id) { $0.routings = [.init(target: targets[index], program: .constant(0))] }
            }
        }
        state.confirmOutputChange()
        _ = state.perform(.selectAll)
        XCTAssertTrue(SpatialCellBulkMenu.items(in: state.presentation).contains { $0.kind == .assignScalar && $0.isEnabled })
        XCTAssertEqual(state.applyToSelection(.setAction(.init(target: targets[0], value: .scalar(0.8)))),
            .success(.applied(changedCells: 3)))
        for (index, layer) in state.workspace.layers.enumerated() {
            for cell in layer.polarCells {
                XCTAssertTrue(layer.polarCellOverrides[cell]?.contains(.init(target: targets[index], value: .scalar(0.8))) == true)
            }
        }
    }

    func testGridViewportAndSelectionChangesCancelPreviewAndLateMouseUpIsInert() {
        let cancellations: [(String, (inout CanvasDocumentFixture) -> Void)] = [
            ("grid request", { _ = $0.requestGridChange(to: .fiftyCentimeter) }),
            ("grid confirm", { _ = $0.confirmGridChange(to: .tenCentimeter) }),
            ("preset viewport", { $0.applyPresetViewport($0.viewport) }),
            ("reset", { $0.resetViewport() }),
            ("sized reset", { _ = $0.resetViewport(canvasSize: self.size) }),
            ("clear selection", { $0.clearSelection() })
        ]
        for (name, cancel) in cancellations {
            var state = layered(); _ = state.perform(.selectAll)
            let start = point(cell, state)
            _ = state.beginDrag(at: start, canvasSize: size)
            _ = state.updateDrag(to: .init(x: start.x, y: start.y - 40), canvasSize: size)
            XCTAssertFalse(state.movePreviewCells.isEmpty)
            cancel(&state)
            XCTAssertFalse(state.isDragging, name); XCTAssertTrue(state.movePreviewCells.isEmpty, name)
            XCTAssertNil(state.selectionRectangle, name)
            let after = state.workspace
            state.endDrag(canvasSize: size)
            XCTAssertEqual(state.workspace, after, "Late mouse-up must not commit a cancelled gesture: \(name)")
        }
    }
}
