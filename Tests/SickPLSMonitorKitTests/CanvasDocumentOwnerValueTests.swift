import XCTest
import Combine
import SickPLSMonitorKit
import PlanariumDomain
import SickPLSControlCore

@MainActor final class CanvasDocumentOwnerValueTests: XCTestCase {
    func testPresentationCacheInvalidatesForIntentsAndDocumentProjectionButSkipsRepeatedFiltering() {
        let cell = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let layer = SpatialInstrumentLayer(name: "A", color: .blue, polarCells: [cell])
        let workspace = SpatialInstrumentWorkspace(layers: [layer])
        let editor = CanvasSession(); editor.projectWorkspace(workspace)
        let probe = CanvasTimingProbe(); CanvasTimingProbe.current = probe
        defer { CanvasTimingProbe.current = nil }
        for _ in 0..<50 { XCTAssertEqual(editor.presentation.workspace, workspace) }
        XCTAssertEqual(probe.counts["field.projection", default: 0], 1)
        _ = editor.selectLayers([layer.id], active: layer.id)
        let selected = editor.presentation
        XCTAssertEqual(selected.selectedCells.count, 1)
        editor.projectWorkspace(editor.workspace)
        XCTAssertEqual(editor.presentation, selected)
        XCTAssertEqual(probe.counts["session.filterSelection", default: 0], 0)
        editor.setPerformanceLocked(true)
        XCTAssertTrue(editor.presentation.isPerformanceLocked)
        XCTAssertEqual(editor.presentation.selection, selected.selection)
        editor.setPerformanceLocked(false)
        editor.holdHand(true)
        XCTAssertTrue(editor.presentation.isHandHeld)
        let synchronousReader = editor.objectWillChange.sink { _ = editor.presentation }
        defer { synchronousReader.cancel() }
        var metadata = editor.workspace
        metadata.updateLayer(layer.id) { $0.name = "Changed" }
        editor.projectWorkspace(metadata)
        XCTAssertEqual(editor.presentation.workspace.selectedLayer.name, "Changed")
        XCTAssertEqual(probe.counts["session.filterSelection", default: 0], 0)
        metadata.updateLayer(layer.id) { $0.isVisible = false }
        editor.projectWorkspace(metadata)
        XCTAssertTrue(editor.presentation.selection.cells.isEmpty)
        XCTAssertEqual(probe.counts["session.filterSelection", default: 0], 1)
        let planProbe = CanvasTimingProbe(); CanvasTimingProbe.current = planProbe
        let plan = SpatialFieldPlan(workspace: workspace)
        XCTAssertEqual(planProbe.counts["plan.labelOwners", default: 0], 1)
        XCTAssertEqual(planProbe.counts["plan.prepareLabels", default: 0], 2)
        for _ in 0..<50 { _ = plan.labels(selectedLayerID: layer.id) }
        XCTAssertEqual(planProbe.counts["plan.labelOwners", default: 0], 1)
        XCTAssertEqual(planProbe.counts["plan.prepareLabels", default: 0], 2)
    }

    func testArmedPanWithoutMotionPreservesAnchorAndNeverAuthors() {
        let editor = CanvasSession(), size = CGSize(width: 800, height: 800)
        _ = editor.followCanvasSize(size)
        let view = editor.viewportOwner.state
        var commands = 0
        editor.onCommand = { _ in commands += 1; return true }
        editor.send(.armPan(.init(x: 100, y: 100)), canvasSize: size)
        editor.send(.release(.init(x: 100, y: 100)), canvasSize: size)
        XCTAssertEqual(editor.viewportOwner.state, view)
        XCTAssertEqual(editor.gesture.phase, .idle)
        XCTAssertEqual(commands, 0)
        editor.send(.armPan(.init(x: 100, y: 100)), canvasSize: size)
        editor.send(.drag(.init(x: 140, y: 120)), canvasSize: size)
        editor.send(.release(.init(x: 100, y: 100)), canvasSize: size)
        XCTAssertEqual(editor.viewport, view.viewport, "Returning to the original pointer position must undo the previewed translation")
        XCTAssertEqual(commands, 0)
    }
    func testIndependentDocumentEditCancelsPreviewAndLateMouseUpCannotResurrectIt() throws {
        let state = CanvasDocumentFixture(), editor = state.session
        let cell = PolarMetricGridCell(ring: 2, angularIndex: 8), size = CGSize(width: 800, height: 800)
        state.replaceWorkspace(.init(layers: [.init(name: "Source", color: .orange, polarCells: [cell])]))
        let current = state.session
        _ = current.perform(.selectAll)
        let segment = PolarMetricCellSegment(cell: cell, grid: current.workspace.grid)
        let geometry = current.displayGeometry(canvasSize: size)
        let point = geometry.screenPoint(for: segment.point(radiusMeters: segment.midpoint.radiusMeters, bearingDegrees: segment.midpoint.bearingDegrees))
        current.send(.arm(point, modifiers: [], brush: false), canvasSize: size)
        current.send(.drag(.init(x: point.x, y: point.y - 25)), canvasSize: size)
        XCTAssertTrue(current.isDragging)
        XCTAssertTrue(current.renameSelectedLayer("Renamed"))
        XCTAssertFalse(current.isDragging)
        let document = state.document
        current.send(.release(.init(x: point.x, y: point.y - 25)), canvasSize: size)
        XCTAssertEqual(state.document, document)
        XCTAssertEqual(current.workspace.selectedLayer.polarCells, [cell])
        _ = editor // original owner's lifetime must not control the replacement
    }
    func testChannelNameAndColorAreDocumentValuesAndUndoable() throws {
        let state = CanvasDocumentFixture()
        state.updateWorkspace(named: "Kanal umbenennen") { $0.setChannelName("THEREMIN") }
        state.updateWorkspace(named: "Kanalfarbe ändern") { $0.setChannelColor(.purple) }
        XCTAssertEqual(state.workspace.channelName, "THEREMIN")
        XCTAssertEqual(state.workspace.channelColor, .purple)
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace.channelColor, .blue)
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace.channelName, "PLANARIUM")

        let restored = try JSONDecoder().decode(
            SpatialInstrumentWorkspace.self,
            from: JSONEncoder().encode(state.workspace)
        )
        XCTAssertEqual(restored.channelName, "PLANARIUM")
        XCTAssertEqual(restored.channelColor, .blue)
    }

    func testLayerContextMenuActionsUseDocumentHistoryAndRespectLockedLayers() {
        let layerID = UUID()
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let routing = SpatialRouting(target: target, program: .constant(0.5))
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [
            SpatialInstrumentLayer(id: layerID, name: "Alt", color: .orange, routings: [routing])
        ]))

        XCTAssertTrue(state.renameSelectedLayer("Neu"))
        XCTAssertTrue(state.setSelectedLayerColor(.purple))
        XCTAssertTrue(state.setSelectedLayerTarget(.midiCC(channel: 0, controller: 74), program: routing.program))
        XCTAssertTrue(state.setSelectedLayerMIDIChannel(4))
        XCTAssertEqual(state.workspace.selectedLayer.name, "Neu")
        XCTAssertEqual(state.workspace.selectedLayer.color, .purple)
        XCTAssertEqual(state.workspace.selectedLayer.routings.first?.target, .midiCC(channel: 4, controller: 74))

        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace.selectedLayer.routings.first?.target, .midiCC(channel: 0, controller: 74))
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace.selectedLayer.routings.first?.target, target)
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace.selectedLayer.color, .orange)
        XCTAssertTrue(state.undo())
        XCTAssertEqual(state.workspace.selectedLayer.name, "Alt")

        state.updateWorkspace { $0.updateSelectedLayer { $0.isLocked = true } }
        let locked = state.workspace
        XCTAssertFalse(state.renameSelectedLayer("Verboten"))
        XCTAssertFalse(state.setSelectedLayerColor(.green))
        XCTAssertFalse(state.setSelectedLayerTarget(.midiPitchBend(channel: 0)))
        XCTAssertFalse(state.setSelectedLayerMIDIChannel(8))
        XCTAssertEqual(state.workspace, locked)
    }

    func testInspectorPreparesOnceAndOnlyChangedLayerDecorationsPublishAcrossSelectionAndReplacement() {
        let cells = (0..<3).map { PolarMetricGridCell(ring: 2, angularIndex: 8 + $0) }
        let layers = (0..<3).map { SpatialInstrumentLayer(name: "Layer \($0)", color: .blue, polarCells: [cells[$0]]) }
        var state = MetricCanvasInteractionState()
        state.replaceWorkspace(.init(layers: layers))
        let editor = CanvasSession(state: state), inspector = editor.inspector
        let rows = layers.map { inspector.layerSelection(for: $0.id) }
        var changes = [0, 0, 0], listChanges = 0
        let listSubscription = inspector.layerList.objectWillChange.sink { listChanges += 1 }
        defer { listSubscription.cancel() }
        let subscriptions = rows.enumerated().map { index, row in
            row.objectWillChange.sink { changes[index] += 1 }
        }
        defer { subscriptions.forEach { $0.cancel() } }
        let timing = CanvasTimingProbe(); CanvasTimingProbe.current = timing
        defer { CanvasTimingProbe.current = nil }
        _ = editor.selectLayers([layers[1].id], active: layers[1].id)
        XCTAssertFalse(rows[0].selected); XCTAssertFalse(rows[0].active)
        XCTAssertTrue(rows[1].selected); XCTAssertTrue(rows[1].active)
        XCTAssertFalse(rows[2].selected); XCTAssertFalse(rows[2].active)
        XCTAssertEqual(changes[2], 0)
        XCTAssertEqual(timing.counts["inspector.prepare"], 1)
        XCTAssertEqual(inspector.interaction, inspector.presentation.interaction)
        changes = [0, 0, 0]
        _ = editor.selectLayers([layers[0].id, layers[1].id], active: layers[1].id)
        XCTAssertTrue(rows[0].selected); XCTAssertFalse(rows[0].active)
        XCTAssertEqual(changes, [1, 0, 0], "Multi-selection changes the newly included row only")
        _ = editor.selectLayers([layers[1].id], active: layers[1].id)
        XCTAssertFalse(rows[0].selected)
        let count = timing.counts["inspector.prepare"]
        changes = [0, 0, 0]
        _ = editor.selectLayers([layers[1].id], active: layers[1].id)
        XCTAssertEqual(changes, [0, 0, 0])
        XCTAssertEqual(timing.counts["inspector.prepare"], count, "Repeated selection must reuse the prepared input")
        editor.setPerformanceLocked(true)
        XCTAssertTrue(inspector.interaction.isPerformanceLocked)
        editor.setPerformanceLocked(false)
        XCTAssertFalse(inspector.interaction.isPerformanceLocked)
        XCTAssertEqual(listChanges, 0, "Selection and lock changes must not reconstruct the layer list input")
        // An empty selection still marks the active layer. Replacing all
        // layers retires old row outputs; recreating an ID gets current state.
        editor.projectWorkspace(.init(layers: [layers[2]]), selection: .init())
        XCTAssertTrue(rows[2].selected); XCTAssertTrue(rows[2].active)
        XCTAssertEqual(listChanges, 1)
        XCTAssertEqual(inspector.layerList.presentation.layers.map(\.id), [layers[2].id])
        XCTAssertFalse(rows[1].selected); XCTAssertFalse(rows[1].active)
        XCTAssertEqual(inspector.interaction, inspector.presentation.interaction)
        let retired = inspector.layerSelection(for: layers[1].id)
        XCTAssertFalse(retired === rows[1])
        XCTAssertFalse(retired.selected); XCTAssertFalse(retired.active)
        editor.projectWorkspace(.init(layers: [layers[1], layers[2]]), selection: .init())
        XCTAssertTrue(retired.selected); XCTAssertTrue(retired.active)
        XCTAssertTrue(inspector.layerSelection(for: layers[2].id) === rows[2])
        let beforeScene = listChanges
        editor.updateWorkspace(named: "Scene metadata") { _ = $0.addScene(name: "Current scene") }
        XCTAssertEqual(listChanges, beforeScene + 1)
        XCTAssertEqual(inspector.layerList.presentation.scenes.map(\.name), ["Current scene"])
    }

}
