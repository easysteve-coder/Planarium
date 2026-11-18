import XCTest
import PlanariumDomain
@testable import SickPLSMonitorKit

final class PerformanceInteractionTests: XCTestCase {
    private func prepared() -> (MetricCanvasInteractionState, CGPoint, CGSize) {
        var state = MetricCanvasInteractionState()
        let cell = PolarMetricGridCell(ring: 4, angularIndex: 10)
        state.updateWorkspace { workspace in
            workspace.updateSelectedLayer { layer in
                layer.polarCells = [cell]
                layer.routings = [.init(target: .sceneSwitch(action: .next, dwellSeconds: 0.2), program: .constant(1))]
            }
            _ = workspace.addScene(name: "Day"); _ = workspace.addScene(name: "Night")
        }
        let size = CGSize(width: 900, height: 600)
        _ = state.resetViewport(canvasSize: size)
        let center = SpatialFieldPlan.center(.init(cell: cell, grid: state.workspace.grid))
        let point = MetricCanvasGeometry(size: size, viewport: state.viewport).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
        _ = state.selectCell(atScreenPoint: point, canvasSize: size)
        return (state, point, size)
    }
    func testEveryAuthoringEntryAndKeyIsLockedButViewCommandsRemainAllowed() {
        let (original, point, size) = prepared()
        XCTAssertFalse(original.selectedPolarCells.isEmpty)
        var locked = original; locked.setPerformanceLocked(true)
        XCTAssertFalse(locked.renameSelectedLayer("Stale edit"))
        let operations: [(String, (inout MetricCanvasInteractionState) -> Void)] = [
            ("update", { $0.updateWorkspace { $0.deleteSelectedLayer() } }),
            ("transaction", { _ = $0.performEdit(named: "Rejected") { $0.updateWorkspace { $0.deleteSelectedLayer() }; return true } }),
            ("replace", { $0.replaceWorkspace(.init()) }),
            ("grid request", { _ = $0.requestGridChange(to: .fiftyCentimeter) }),
            ("grid confirm", { _ = $0.confirmGridChange(to: .fiftyCentimeter) }),
            ("tool", { $0.select(tool: .pan) }),
            ("layer selection", { _ = $0.selectLayers([UUID()]) }),
            ("rename", { _ = $0.renameSelectedLayer("Bad") }),
            ("color", { _ = $0.setSelectedLayerColor(.green) }),
            ("target", { _ = $0.setSelectedLayerTarget(.midiNote(channel: 0)) }),
            ("clear target", { _ = $0.clearSelectedLayerTarget() }),
            ("channel", { _ = $0.setSelectedLayerMIDIChannel(4) }),
            ("cell select", { _ = $0.selectCell(atScreenPoint: .zero, canvasSize: size) }),
            ("cell toggle", { _ = $0.toggleCellSelection(atScreenPoint: point, canvasSize: size) }),
            ("cell extend", { _ = $0.extendSelection(toScreenPoint: point, canvasSize: size) }),
            ("clear selection", { $0.clearSelection() }),
            ("context", { _ = $0.contextMenuSelection(at: point, canvasSize: size) }),
            ("scene action", { _ = $0.setSceneAction(.previous) }),
            ("reset", { _ = $0.resetSelectedCellsToLayer() })
        ]
        for (name, operation) in operations {
            var state = locked; operation(&state)
            XCTAssertTrue(state.hasSameInspectorPresentation(as: locked), name)
            XCTAssertEqual(state.viewport, locked.viewport); XCTAssertEqual(state.selectedCells, locked.selectedCells)
        }
        for key: MetricCanvasKey in [.commandA, .escape, .delete, .left, .right, .up, .down] {
            var state = locked; _ = state.handleKey(key, modifiers: .command)
            XCTAssertEqual(state, locked, "key \(key)")
        }
        let target = locked.workspace.selectedLayer.routings[0].target
        for operation: SpatialCellBulkOperation in [.paint, .erase, .deactivate, .setAction(.init(target: target, value: .sceneSwitch(action: .previous))),
            .assignAndActivate(.init(target: target, value: .sceneSwitch(action: .previous))), .removeActions(target: target)] {
            var state = locked; _ = state.applyToSelection(operation)
            XCTAssertTrue(state.hasSameInspectorPresentation(as: locked), "bulk \(operation)")
            XCTAssertEqual(state.selectedCells, locked.selectedCells)
        }
        for command: MetricCanvasCommand in [.delete, .selectAll] {
            var state = locked
            XCTAssertFalse(state.isEnabled(command, canvasSize: size))
            XCTAssertFalse(state.perform(command, canvasSize: size)); XCTAssertTrue(state.hasSameInspectorPresentation(as: locked))
        }
        var state = locked
        XCTAssertTrue(state.perform(.zoomIn, canvasSize: size))
        XCTAssertTrue(state.perform(.zoomOut, canvasSize: size))
        XCTAssertTrue(state.panViewport(byScreenX: 20, screenY: 10))
        XCTAssertEqual(state.workspace, locked.workspace); XCTAssertEqual(state.selectedPolarCells, locked.selectedPolarCells)
    }
    func testAllToolsAndModifiersPanWithoutEditingAndEnteringCancelsMovePreview() {
        let (original, point, size) = prepared()
        for tool in MetricCanvasTool.allCases {
            for brush in [false, true] {
                for modifiers: SelectionModifiers in [[], .command, .shift, .option] {
                    var state = original; state.select(tool: tool); state.setPerformanceLocked(true)
                    let document = state.workspace, selection = state.selectedPolarCells
                    XCTAssertTrue(state.beginDrag(at: point, canvasSize: size, modifiers: modifiers, brush: brush))
                    _ = state.updateDrag(to: .init(x: point.x + 30, y: point.y + 20), canvasSize: size)
                    state.endDrag(canvasSize: size)
                    XCTAssertEqual(state.workspace, document); XCTAssertEqual(state.selectedPolarCells, selection)
                    XCTAssertNotEqual(state.viewport, original.viewport)
                }
            }
        }
        var state = original
        _ = state.beginDrag(at: point, canvasSize: size)
        _ = state.updateDrag(to: .init(x: point.x + 30, y: point.y + 20), canvasSize: size)
        state.setPerformanceLocked(true); state.endDrag(canvasSize: size)
        XCTAssertEqual(state.workspace, original.workspace)
        XCTAssertFalse(state.isDragging); XCTAssertTrue(state.movePreviewCells.isEmpty)
        state.setPerformanceLocked(false)
        XCTAssertTrue(state.perform(.delete, canvasSize: size))
        XCTAssertTrue(state.workspace.selectedLayer.polarCells.isEmpty)
    }
    func testSceneChoicesMultiSelectionResetAndMissingScenePresentation() {
        var (state, _, _) = prepared()
        let second = PolarMetricGridCell(ring: 4, angularIndex: 11)
        state.updateWorkspace { $0.updateSelectedLayer { $0.polarCells.insert(second) } }
        XCTAssertTrue(state.perform(.selectAll))
        XCTAssertEqual(state.selectedPolarCells.count, 2)
        let day = state.workspace.scenes[0].id
        XCTAssertTrue(state.setSceneAction(.scene(day)))
        XCTAssertEqual(state.selectedPolarCells.compactMap { SpatialScenePresentation.action(cell: $0, in: state) }, [.scene(day), .scene(day)])
        XCTAssertTrue(state.setSceneAction(.previous, layerOnly: true))
        XCTAssertEqual(SpatialScenePresentation.choices(in: state, layerOnly: true).filter(\.isSelected).map(\.title), ["Previous"])
        XCTAssertEqual(SpatialScenePresentation.selectionTitle(in: state), "Day")
        XCTAssertTrue(state.setSelectedLayerTarget(.sceneSwitch(action: .previous, dwellSeconds: 0.4), program: .constant(1)))
        XCTAssertEqual(SpatialScenePresentation.selectionTitle(in: state), "Day")
        XCTAssertEqual(SpatialScenePresentation.choices(in: state).filter(\.isSelected).map(\.title), ["Day"])
        XCTAssertEqual(SpatialCellInfo.make(cell: state.selectedPolarCell!, layerID: state.workspace.selectedLayerID, workspace: state.workspace)?.origin, .cellOverride)
        state.updateWorkspace { $0.deleteScene(day) }
        XCTAssertEqual(SpatialScenePresentation.name(.scene(day), scenes: state.workspace.scenes), "missing scene")
        XCTAssertTrue(state.resetSelectedCellsToLayer())
        XCTAssertTrue(state.workspace.selectedLayer.polarCellOverrides.isEmpty)
        XCTAssertEqual(SpatialScenePresentation.choices(in: state).filter(\.isSelected).map(\.title), ["Previous"])
        state.clearSelection(); XCTAssertTrue(state.setSceneAction(.next))
        XCTAssertEqual(SpatialScenePresentation.choices(in: state).filter(\.isSelected).map(\.title), ["Next"])
    }
}
