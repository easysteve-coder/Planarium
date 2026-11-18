import AppKit
import SwiftUI
import XCTest
import PlanariumApplication
import PlanariumDomain
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class CellInspectorHostingTests: XCTestCase {
    private struct Harness: View {
        @ObservedObject var owner: SpatialInstrumentRuntimeModel
        var body: some View {
            StableCellInspectorView(editor: owner.canvas).equatable()
        }
    }
    func testViewportTicksDoNotRebuildCellButWritesKeepCurrentViewportAndSelectionUpdates() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        let a = PolarMetricGridCell(point: .init(xMeters: 0.2, yMeters: 1), grid: owner.canvas.workspace.grid)
        let b = PolarMetricGridCell(point: .init(xMeters: 0.3, yMeters: 1.5), grid: owner.canvas.workspace.grid)
        owner.canvas.updateWorkspace { $0.updateSelectedLayer {
            $0.polarCells = [a, b]
            $0.routings = [.init(target: .midiNote(channel: 0), program: .chord(notes: [60, 64, 67], velocity: 100, transition: .legato))]
        } }
        let size = CGSize(width: 400, height: 800)
        _ = owner.canvas.resetViewport(canvasSize: size)
        func select(_ cell: PolarMetricGridCell) {
            let center = SpatialFieldPlan.center(.init(cell: cell, grid: owner.canvas.workspace.grid))
            let point = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
            _ = owner.canvas.selectCell(atScreenPoint: point, canvasSize: size)
        }
        select(a); XCTAssertEqual(owner.canvas.selectedPolarCell, a)
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        let host = NSHostingView(rootView: Harness(owner: owner))
        host.frame = .init(x: 0, y: 0, width: 220, height: 800)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertGreaterThan(probe.counts["cell", default: 0], 0)
        let count = probe.counts["cell"]
        for _ in 0..<10 {
            _ = owner.canvas.panViewport(byScreenX: 1, screenY: 1)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        XCTAssertEqual(probe.counts["cell"], count)
        func nested(_ view: NSView) -> NSHostingView<CellInspectorView>? {
            if let found = view as? NSHostingView<CellInspectorView> { return found }
            return view.subviews.compactMap(nested).first
        }
        let inspector = try XCTUnwrap(nested(host))
        let viewport = owner.canvas.viewport
        inspector.rootView.editor.updateWorkspace { $0.updateSelectedLayer { $0.name = "Cell binding" } }
        XCTAssertEqual(owner.canvas.workspace.selectedLayer.name, "Cell binding")
        XCTAssertEqual(owner.canvas.viewport, viewport)
        select(b)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(inspector.rootView.editor.selectedPolarCell, b)
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }

    func testControlFormsStartOnlyForControlsAndTrackResize() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let cell = PolarMetricGridCell(point: .init(xMeters: 0.2, yMeters: 1), grid: owner.canvas.workspace.grid)
        owner.canvas.updateWorkspace { workspace in
            for id in workspace.layers.map(\.id) {
                workspace.updateLayer(id) { $0.routings = [.init(target: .midiNote(channel: 0),
                    program: .chord(notes: [60, 64, 67], velocity: 100, transition: .legato))] }
            }
        }
        owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.polarCells = [cell] } }
        let size = CGSize(width: 400, height: 800)
        _ = owner.canvas.resetViewport(canvasSize: size)
        let center = SpatialFieldPlan.center(.init(cell: cell, grid: owner.canvas.workspace.grid))
        let point = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
        _ = owner.canvas.selectCell(atScreenPoint: point, canvasSize: size)
        XCTAssertEqual(owner.canvas.selectedPolarCell, cell)
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        let host = NSHostingView(rootView: CellInspectorView(editor: owner.canvas))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 220, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func flush() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
        flush()
        XCTAssertEqual(probe.counts["inspector.controlSurfaceInput", default: 0], 0,
            "A music-only document must not construct dormant control-form state")
        owner.canvas.updateWorkspace { $0.updateSelectedLayer {
            $0.routings = [.init(target: .midiCC(channel: 0, controller: 74), program: .constant(0.5))]
        } }
        flush()
        func controlHost(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "inspector.retained.cellValue" { return view }
            return view.subviews.compactMap(controlHost).first
        }
        let native = try XCTUnwrap(controlHost(host))
        let width = native.bounds.width
        XCTAssertGreaterThan(width, 0, "The first control form must receive a real width")
        XCTAssertGreaterThan(probe.counts["inspector.controlSurfaceInput", default: 0], 0)
        window.setContentSize(.init(width: 400, height: 800)); flush()
        XCTAssertTrue(controlHost(host) === native, "A resize preserves the native form")
        XCTAssertGreaterThan(native.bounds.width, width,
            "The native sizing contract must receive actual window resizes")
    }

    func testLayerSelectionProjectionTracksEmptyFallbackAndBothSelectedLayers() {
        let first = UUID(), second = UUID(), cell = PolarMetricGridCell(ring: 3, angularIndex: 8)
        let cache = InspectorLayerSelectionCache()
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        XCTAssertEqual(cache.read(selection: .init(), activeLayerID: first), [first])
        XCTAssertEqual(cache.read(selection: .init(), activeLayerID: first), [first])
        XCTAssertEqual(probe.counts["inspector.effectiveLayerSelection"], 1)
        XCTAssertEqual(cache.read(selection: .init(), activeLayerID: second), [second])
        let selection = CanvasSelection(cells: [.init(layerID: first, cell: cell), .init(layerID: second, cell: cell)])
        XCTAssertEqual(cache.read(selection: selection, activeLayerID: second), [first, second])
        XCTAssertEqual(cache.read(selection: selection, activeLayerID: second), [first, second])
        XCTAssertEqual(probe.counts["inspector.effectiveLayerSelection"], 3)
    }

    func testCurrentCellPresentationTracksValueTargetAndNameWithoutRepeatedProjection() throws {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 8)
        let layer = SpatialInstrumentLayer(name: "Control", color: .blue, polarCells: [cell],
            routings: [.init(target: .midiCC(channel: 0, controller: 74), program: .constant(0.5))])
        var state = MetricCanvasInteractionState()
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [layer]))
        let size = CGSize(width: 800, height: 800)
        let center = SpatialFieldPlan.center(.init(cell: cell, grid: state.workspace.grid))
        let point = MetricCanvasGeometry(size: size, viewport: state.viewport)
            .screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
        _ = state.selectCell(atScreenPoint: point, canvasSize: size)
        let cache = InspectorCellPresentationCache()
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        cache.update(state); cache.update(state)
        XCTAssertEqual(cache.cell, cell)
        XCTAssertEqual(cache.info?.value, .scalar(0.5))
        XCTAssertEqual(probe.counts["inspector.cellInfo"], 1)
        state.updateWorkspace { $0.updateSelectedLayer { $0.routings[0].program = .constant(0.8) } }
        cache.update(state)
        XCTAssertEqual(cache.info?.value, .scalar(0.8))
        state.updateWorkspace { $0.updateSelectedLayer {
            $0.name = "Programs"
            $0.routings = [.init(target: .midiProgramChange(channel: 0), program: .programChange(.init(program: 9)))]
        } }
        cache.update(state)
        XCTAssertEqual(cache.info?.layerName, "Programs")
        XCTAssertEqual(cache.info?.value, .programChange(.init(program: 9)))
        XCTAssertEqual(probe.counts["inspector.cellInfo"], 3)
    }

    func testControlPreparationUsesDocumentChangesAndFindsCellsAfterEmptyLayers() throws {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 8)
        let empty = SpatialInstrumentLayer(name: "Empty program layer", color: .orange, polarCells: [],
            routings: [.init(target: .midiProgramChange(channel: 0), program: .programChange(.init(program: 1)))])
        let program = SpatialInstrumentLayer(name: "Program cells", color: .blue, polarCells: [cell],
            routings: [.init(target: .midiProgramChange(channel: 0), program: .programChange(.init(program: 9, bankMSB: 2, bankLSB: 3)))])
        var workspace = SpatialInstrumentWorkspace(layers: [empty, program])
        let preparation = InspectorControlPreparation()
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        preparation.update(workspace)
        XCTAssertEqual(preparation.program?.program, 9)
        XCTAssertEqual(preparation.programCell?.info.layerID, program.id)
        XCTAssertTrue(preparation.midiAvailable)
        workspace.selectLayer(program.id)
        preparation.update(workspace)
        XCTAssertEqual(probe.counts["inspector.controlPreparation"], 1, "Selection cannot repeat document preparation")
        workspace.updateLayer(program.id) {
            $0.routings = [.init(target: .midiCC(channel: 0, controller: 74), program: .constant(0.5))]
        }
        preparation.update(workspace)
        XCTAssertEqual(probe.counts["inspector.controlPreparation"], 2)
        XCTAssertNil(preparation.programCell)
        XCTAssertEqual(preparation.program?.program, 1)
        XCTAssertEqual(try XCTUnwrap(preparation.controlCell).info.value, .scalar(0.5))
        workspace.updateLayer(empty.id) { $0.routings = [] }
        preparation.update(workspace)
        XCTAssertNil(preparation.program)
        XCTAssertEqual(preparation.controlCell?.info.layerID, program.id)
    }

    func testSwitchChordSwitchSelectionRebuildsTheCellInspectorDraft() throws {
        let switchCell = PolarMetricGridCell(ring: 2, angularIndex: 4)
        let chordCell = PolarMetricGridCell(ring: 3, angularIndex: 8)
        let switchLayer = SpatialInstrumentLayer(name: "Switch", color: .orange, polarCells: [switchCell],
            routings: [.init(target: .sceneSwitch(action: .next, dwellSeconds: 0.2), program: .constant(1))])
        let chordLayer = SpatialInstrumentLayer(name: "Chord", color: .blue, polarCells: [chordCell],
            routings: [.init(target: .midiNote(channel: 0),
                             program: .chord(notes: [60, 64, 67], velocity: 100, transition: .retrigger))])
        var state = MetricCanvasInteractionState()
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [switchLayer, chordLayer]))
        let size = CGSize(width: 800, height: 800)
        func select(_ layer: SpatialInstrumentLayer, cell: PolarMetricGridCell) throws -> SpatialCellInfo {
            state.updateWorkspace { $0.selectLayer(layer.id) }
            let center = SpatialFieldPlan.center(.init(cell: cell, grid: state.workspace.grid))
            let point = MetricCanvasGeometry(size: size, viewport: state.viewport)
                .screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
            _ = state.selectCell(atScreenPoint: point, canvasSize: size)
            return try XCTUnwrap(SpatialCellInfo.make(cell: cell, layerID: layer.id, workspace: state.workspace))
        }

        let firstSwitch = try select(switchLayer, cell: switchCell)
        if case .sceneSwitch? = firstSwitch.target {} else { XCTFail("First selected cell must show its switch action"); return }
        let switchRouting = try XCTUnwrap(switchLayer.routings.first?.id)
        let chordRouting = try XCTUnwrap(chordLayer.routings.first?.id)
        var draft = CellInspectorDraft(selectedRoutingID: switchRouting)

        // Switch → chord: the remembered switch routing must be discarded
        // before the chord layer chooses its own first routing.
        draft.rebuildForNewSelection()
        XCTAssertNil(draft.selectedRoutingID,
                     "Counterprobe: removing selectedRoutingID = nil leaks the old switch choice")
        let chord = try select(chordLayer, cell: chordCell)
        if case .midiNote? = chord.target {} else { XCTFail("Chord selection must show the chord cell, not switch 'On'"); return }
        XCTAssertEqual(draft.routingID(availableRoutingIDs: [chordRouting]), chordRouting)

        // Chord → switch repeats the same transition; neither direction may
        // retain an editor choice from the previous cell type.
        draft.selectedRoutingID = chordRouting
        draft.rebuildForNewSelection()
        XCTAssertNil(draft.selectedRoutingID)
        let finalSwitch = try select(switchLayer, cell: switchCell)
        if case .sceneSwitch? = finalSwitch.target {} else { XCTFail("Returning must show the selected switch cell"); return }
        XCTAssertEqual(draft.routingID(availableRoutingIDs: [switchRouting]), switchRouting)
    }
}
