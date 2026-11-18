import XCTest
import Combine
import AppKit
import SwiftUI
import SickPLSCore
import PlanariumDomain
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class SceneAuthoringTests: XCTestCase {
    func testPerformanceNamesDeduplicateEqualLayerAndChordNamesInStableDocumentOrder() {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 9)
        func layer(_ name: String, _ notes: [Int]) -> SpatialInstrumentLayer {
            .init(name: name, color: .orange, polarCells: [cell], routings: [
                .init(target: .midiNote(channel: 0), program: .chord(notes: notes, velocity: 100, transition: .legato))])
        }
        let c = layer("C", [60,64,67]), duplicate = layer("C", [60,64,67]), f = layer("F", [57,60,65])
        var workspace = SpatialInstrumentWorkspace(grid: .quarterMeter, layers: [c,duplicate,f])
        let measured = Dictionary(uniqueKeysWithValues: workspace.layers.map { ($0.id, cell) })
        XCTAssertEqual(PerformanceCellNames.titles(workspace: workspace, activeCells: measured), ["C", "F"])
        XCTAssertTrue(PerformanceCellNames.titles(workspace: workspace, activeCells: [:]).isEmpty)
        workspace.updateLayer(c.id) { $0.isActive = false }
        XCTAssertEqual(PerformanceCellNames.titles(workspace: workspace, activeCells: measured), ["C", "F"])
        workspace.updateLayer(f.id) { $0.isSoloed = true }
        XCTAssertEqual(PerformanceCellNames.titles(workspace: workspace, activeCells: measured), ["F"])
    }
    func testFiftyMeasuredProfilesKeepNamesQuietAndCellWorkspaceAudibilityChangesRefresh() throws {
        let cell = PolarMetricGridCell(ring: 30, angularIndex: 20)
        let painted = Set((20..<120).flatMap { ring in (0..<30).map { PolarMetricGridCell(ring: ring, angularIndex: $0) } })
        let a = SpatialInstrumentLayer(name: "C", color: .orange, polarCells: painted, routings: [
            .init(target: .midiNote(channel: 0), program: .chord(notes: [60,64,67], velocity: 100, transition: .legato))])
        let b = SpatialInstrumentLayer(name: "F", color: .orange, polarCells: painted, routings: [
            .init(target: .midiNote(channel: 1), program: .chord(notes: [57,60,65], velocity: 100, transition: .legato))])
        var workspace = SpatialInstrumentWorkspace(grid: .quarterMeter, layers: [a,b])
        let cells = SpatialActiveCellDisplayModel()
        var active = [a.id: cell, b.id: cell]
        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<361).map { _ in try .build(value: 100, fieldFlags: 0) })
        let geometry = try FullScanProfileAdapter.geometry(from: raw)
        let measurements = try FullScanProfileAdapter.measurements(from: raw)
        let session = UUID()
        func update(_ sequence: UInt64) {
            cells.update(profileFrame: .init(sessionID: session, sequence: sequence, time: Double(sequence) / 25,
                measurements: measurements, geometry: geometry, rawProfile: raw), activeCells: active)
        }
        update(0)
        let host = NSHostingView(rootView: PerformanceCellNamesView(cells: cells, workspace: workspace))
        host.frame = .init(x: 0, y: 0, width: 900, height: 500)
        func flush() {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.003))
        }
        for _ in 0..<4 { flush() }
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        for sequence: UInt64 in 1...50 { update(sequence); flush() }
        XCTAssertLessThanOrEqual(probe.counts["performance.names", default: 0], 1)
        func changed(_ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
            for _ in 0..<4 { flush() }
            XCTAssertGreaterThan(probe.counts["performance.names", default: 0], 0, file: file, line: line)
            XCTAssertEqual(PerformanceCellNames.titles(workspace: workspace, activeCells: cells.activeCells), expected, file: file, line: line)
            probe.reset()
        }
        probe.reset()
        active.removeValue(forKey: b.id); update(51); changed(["C"])
        active = [a.id: cell, b.id: cell]; update(52); changed(["C", "F"])
        workspace.updateLayer(a.id) { $0.name = "Piano" }
        host.rootView = PerformanceCellNamesView(cells: cells, workspace: workspace)
        changed(["Piano · C", "F"])
        workspace.updateLayer(b.id) { $0.isSoloed = true }
        host.rootView = PerformanceCellNamesView(cells: cells, workspace: workspace)
        changed(["F"])
        workspace.updateLayer(b.id) { $0.isSoloed = false }
        host.rootView = PerformanceCellNamesView(cells: cells, workspace: workspace)
        changed(["Piano · C", "F"])
        active = [:]; update(53); changed([])
        update(54); flush()
        XCTAssertEqual(probe.counts["performance.names", default: 0], 0)
    }
    func testSceneRenameRefreshesProductionFieldPlanWithoutLayerChange() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults() }
        layout.view.presets.load("Harmony 29 Picardy Switch")
        let owner = fixture.root.document
        let id = owner.canvas.workspace.scenes[0].id
        let control = owner.canvas.workspace.layers.first { $0.routings.contains { if case .sceneSwitch = $0.target { return true }; return false } }!
        owner.canvas.updateWorkspace { $0.selectLayer(control.id) }
        XCTAssertTrue(owner.canvas.selectLayers([control.id]))
        XCTAssertTrue(owner.canvas.setSceneAction(.scene(id)))
        XCTAssertTrue(owner.fieldPlan.regions.filter { $0.layerID == control.id }.allSatisfy { $0.label == "Day" })
        let layers = owner.canvas.workspace.layers, plan = owner.fieldPlan.identity
        owner.canvas.updateWorkspace { $0.renameScene(id, to: "Morning") }
        XCTAssertEqual(owner.canvas.workspace.layers, layers)
        XCTAssertNotEqual(owner.fieldPlan.identity, plan)
        XCTAssertTrue(owner.fieldPlan.regions.filter { $0.layerID == control.id }.allSatisfy { $0.label == "Morning" })
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }
    func testProductionSceneClickMirrorsRuntimeWithoutDocumentRevisionOrUndoChange() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults() }
        layout.view.presets.load("Harmony 30 Mode Wheel")
        let owner = fixture.root.document, before = owner.document
        let destination = before.scenes[1].id
        let undo = owner.canUndo
        let geometryID = owner.fieldPlan.identity
        let paths = owner.fieldPlan.regions.map(\.fill)
        var publications = 0, invalidations = 0
        let token = owner.$document.dropFirst().sink { _ in publications += 1 }
        let invalidation = owner.objectWillChange.sink { invalidations += 1 }
        defer { token.cancel(); invalidation.cancel() }
        owner.selectScene(destination)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(owner.document.currentSceneID, destination)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(owner.fieldPlan.identity, geometryID)
        for (region, path) in zip(owner.fieldPlan.regions, paths) { XCTAssertTrue(region.fill === path) }
        let audible = SpatialLayerAudibility.audibleIDs(owner.canvas.workspace.layers.map { ($0.id, $0.isActive, $0.isSoloed) })
        for layer in owner.fieldPlan.layers {
            XCTAssertEqual(owner.fieldPlan.audibilityOpacity[layer.id], audible.contains(layer.id) ? 1 : 0.3, layer.name)
        }
        let expected = SpatialFieldPlan(workspace: owner.canvas.workspace).labels(selectedLayerID: owner.canvas.workspace.selectedLayerID)
        XCTAssertEqual(owner.fieldLabels.map(\.regionIndex), expected.map(\.regionIndex))
        XCTAssertEqual(owner.fieldLabels.map(\.opacity), expected.map(\.opacity))
        XCTAssertEqual(owner.document.revision, before.revision)
        XCTAssertEqual(owner.canUndo, undo)
        XCTAssertEqual(owner.document.spatial.layers.map(\.cells), before.spatial.layers.map(\.cells))
        XCTAssertEqual(owner.document.spatial.layers.map(\.cellOverrides), before.spatial.layers.map(\.cellOverrides))
        XCTAssertEqual(Set(owner.document.spatial.layers.filter(\.isActive).map(\.id)),
            before.scenes[1].activeLayerIDs.union(owner.canvas.workspace.controlLayerIDs))
        layout.view.presets.load("Harmony 29 Picardy Switch", decision: .discard)
        owner.selectScene(owner.document.scenes[1].id)
        layout.view.presets.load("Harmony 30 Mode Wheel", decision: .discard)
        let replacement = owner.document
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(owner.document.currentSceneID, replacement.currentSceneID)
        XCTAssertEqual(owner.document.scenes, replacement.scenes)
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }
    func testSceneContextActionsAndMembershipUseCurrentMuteSettings() {
        var workspace = SpatialInstrumentWorkspace()
        let layer = workspace.selectedLayerID
        SceneAuthoringAction.add.apply(to: &workspace)
        let first = workspace.scenes[0].id
        XCTAssertTrue(workspace.scenes[0].activeLayerIDs.contains(layer))
        SceneAuthoringAction.rename(first, "Day").apply(to: &workspace)
        XCTAssertEqual(workspace.scenes[0].name, "Day")
        workspace.updateSelectedLayer { $0.isActive = false }
        SceneAuthoringAction.update(first).apply(to: &workspace)
        XCTAssertFalse(workspace.scenes[0].activeLayerIDs.contains(layer))
        SceneAuthoringAction.membership(scene: first, layer: layer).apply(to: &workspace)
        XCTAssertTrue(workspace.scenes[0].activeLayerIDs.contains(layer))
        XCTAssertFalse(workspace.selectedLayer.isActive)
        SceneAuthoringAction.add.apply(to: &workspace)
        let second = workspace.scenes[1].id
        SceneAuthoringAction.move(second, -1).apply(to: &workspace)
        XCTAssertEqual(workspace.scenes.map(\.id), [second, first])
        SceneAuthoringAction.move(second, 1).apply(to: &workspace)
        XCTAssertEqual(workspace.scenes.map(\.id), [first, second])
        SceneAuthoringAction.delete(first).apply(to: &workspace)
        XCTAssertEqual(workspace.scenes.map(\.id), [second])
    }
    func testOutputPresentationAndSceneChoiceApplyThroughProductionState() {
        XCTAssertEqual(SpatialScenePresentation.outputTitles, ["No output", "AU instrument", "MIDI", "Scene switch", "Release layer"])
        var state = MetricCanvasInteractionState()
        XCTAssertTrue(state.setSelectedLayerTarget(.sceneSwitch(action: .next, dwellSeconds: 0.2)))
        state.updateWorkspace { _ = $0.addScene(name: "Night") }
        for choice in SpatialScenePresentation.choices(in: state) {
            _ = state.setSceneAction(choice.action)
            XCTAssertEqual(SpatialScenePresentation.choices(in: state).filter(\.isSelected).map(\.action), [choice.action])
        }
    }
}
