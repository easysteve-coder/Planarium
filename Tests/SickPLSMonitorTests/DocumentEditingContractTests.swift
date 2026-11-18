import XCTest
import PlanariumApplication
import PlanariumDomain
import PlanariumPresets
import PlanariumRuntime
import SickPLSCore
import SickPLSControlCore
import SickPLSMonitorKit

final class DocumentEditingContractTests: XCTestCase {
    @MainActor func testRejectedCanvasEditsPreserveDocumentSelectionEntireHistoryInstalledRuntimeAndLiveOutputs() throws {
        for scenario in ["invalid", "pending", "cancel", "expired"] {
            let root = try MonitorRootFixture(clock: EditingContractClock()).root
            let owner = root.document
            func drain() {
                let done = expectation(description: "Runtime barrier")
                root.runtime.acknowledge { done.fulfill() }; wait(for: [done], timeout: 5)
            }
            defer {
                let done = expectation(description: "Offline termination")
                root.terminate { done.fulfill() }; wait(for: [done], timeout: 5)
            }
            func semantic(_ document: InstrumentDocument) -> InstrumentDocument {
                var value = document
                value.revision = .init(session: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, counter: 0)
                return value
            }
            let initial = owner.document
            let cell = PolarDeviceLattice(ring: 100, sector: 180)!
            let layerID = initial.spatial.layers[0].id
            let targets: [SpatialRoutingTarget] = [.midiNote(channel: 0), .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)]
            let layers = targets.enumerated().map { index, target in
                SpatialDocumentLayer(id: index == 0 ? layerID : UUID(), name: "Live \(index)", color: .orange,
                    isVisible: true, isActive: true, isLocked: index != 0, isSoloed: false, cells: [cell],
                    routings: [.init(target: target, program: .singleNote(note: 60 + index, velocity: 100, transition: .legato))],
                    cellOverrides: [cell: [.init(target: target, value: .note(number: 70 + index, velocity: 88))]])
            }
            try owner.edit(name: "Seed") {
                $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layerID)
                $0.detection = .init(temporalSmoothing: .off, groupingMinimumPoints: 1,
                                    virtualMMKMode: .raw, edgePoints: 0, coreWidthCentimeters: 0)
            }
            let seeded = owner.document
            let size = CGSize(width: 800, height: 800)
            let point = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for: .init(xMeters: 0, yMeters: 1))
            XCTAssertTrue(owner.canvas.perform { $0.selectCell(atScreenPoint: point, canvasSize: size) })
            XCTAssertFalse(owner.canvas.selection.cells.isEmpty)
            try owner.edit(name: "Redo sentinel") { $0.channelName = "Redo sentinel" }
            var expectedRedo = owner.document
            XCTAssertTrue(owner.undo())
            if scenario == "expired" {
                var next = owner.canvas.presentation
                _ = next.setSelectedLayerTarget(.midiCC(channel: 0, controller: 74))
                owner.canvas.perform { $0 = next }
                XCTAssertGreaterThan(owner.outputChangeLossCount, 0)
                try owner.edit(name: "Newer sentinel") { $0.channelName = "Newer sentinel" }
                expectedRedo = owner.document
                XCTAssertTrue(owner.undo()) // same contents, newer revision, nonempty redo
            }
            let output = EditingContractOutput()
            root.runtime.attach(.init(destination: .midi, send: output.send))
            root.runtime.attach(.init(destination: .audioUnit(stripID: InstrumentChannel.legacyID), send: output.send))
            let session = UUID(); root.runtime.sessionBegan(session)
            let raw = try B0ScanProfile.build(partialScanIndex: 0,
                measurements: (0..<361).map { try .build(value: $0 == 180 ? 100 : 190, fieldFlags: 0) })
            let geometry = try FullScanProfileAdapter.geometry(from: raw)
            func frame(_ sequence: UInt64) throws {
                root.runtime.frame(.init(sessionID: session, sequence: sequence, time: 0,
                    measurements: try FullScanProfileAdapter.measurements(from: raw, geometry: geometry), geometry: geometry, rawProfile: raw))
                drain()
            }
            try frame(1)
            let before = owner.document, selection = owner.canvas.selection, compiled = owner.compiledInstrument
            let installed = try XCTUnwrap(root.runtime.mailbox.read())
            XCTAssertEqual(installed.revision, before.revision)
            XCTAssertEqual(installed.selection.activeHandles.count, 2)
            XCTAssertEqual(installed.ports.map(\.soundingNotes).reduce(0, +), 2)
            let sent = output.events
            XCTAssertEqual(sent.filter { if case .noteOn = $0 { return true }; return false }.count, 2)
            XCTAssertTrue(owner.canUndo); XCTAssertTrue(owner.canRedo)
            let undoTitle = owner.undoMenuTitle, redoTitle = owner.redoMenuTitle
            if scenario == "invalid" {
                var next = owner.canvas.presentation
                next.clearSelection()
                next.updateWorkspace(named: "Invalid command") {
                    $0.updateSelectedLayer { $0.routings[0].program = .constant(.infinity) }
                }
                owner.canvas.perform { $0 = next }
                XCTAssertEqual(owner.notice, "Document edit rejected") // actual catch, not permission denial
                XCTAssertEqual(owner.canvas.feedback.status, "Document edit rejected")
            } else if scenario == "expired" {
                owner.confirmOutputChange()
                XCTAssertEqual(owner.notice, "Output change expired; choose again")
                XCTAssertEqual(owner.outputChangeLossCount, 0)
            } else {
                var next = owner.canvas.presentation
                next.clearSelection()
                _ = next.setSelectedLayerTarget(.midiCC(channel: 0, controller: 74))
                owner.canvas.perform { $0 = next }
                XCTAssertGreaterThan(owner.outputChangeLossCount, 0)
                if scenario == "cancel" { owner.cancelOutputChange(); XCTAssertEqual(owner.outputChangeLossCount, 0) }
            }
            drain()
            XCTAssertEqual(owner.document, before, scenario)
            XCTAssertEqual(owner.canvas.selection, selection, scenario)
            XCTAssertEqual(owner.canvas.workspace.selectedLayerID, layerID)
            XCTAssertEqual(owner.compiledInstrument, compiled, scenario)
            XCTAssertEqual(root.runtime.mailbox.read(), installed, scenario)
            XCTAssertEqual(output.events, sent, scenario)
            XCTAssertEqual(owner.undoMenuTitle, undoTitle); XCTAssertEqual(owner.redoMenuTitle, redoTitle)
            XCTAssertTrue(owner.canUndo); XCTAssertTrue(owner.canRedo)
            try frame(2) // a subsequent real pipeline input still uses the installed revision and held notes
            let after = try XCTUnwrap(root.runtime.mailbox.read())
            XCTAssertEqual(after.revision, installed.revision)
            XCTAssertEqual(after.selection.activeHandles, installed.selection.activeHandles)
            XCTAssertEqual(after.ports, installed.ports)
            XCTAssertEqual(output.events, sent)
            // Walk every history entry in both directions; menu flags alone
            // would miss a replaced payload or an extra hidden undo entry.
            owner.cancelOutputChange()
            XCTAssertTrue(owner.redo()); XCTAssertEqual(semantic(owner.document), semantic(expectedRedo))
            XCTAssertEqual(owner.canvas.selection, selection)
            XCTAssertFalse(owner.canRedo)
            XCTAssertTrue(owner.undo()); XCTAssertEqual(semantic(owner.document), semantic(seeded))
            XCTAssertEqual(owner.canvas.selection, selection)
            XCTAssertTrue(owner.undo()); XCTAssertEqual(semantic(owner.document), semantic(initial))
            XCTAssertTrue(owner.canvas.selection.cells.isEmpty)
            XCTAssertFalse(owner.canUndo)
            XCTAssertTrue(owner.redo()); XCTAssertEqual(semantic(owner.document), semantic(seeded))
            XCTAssertTrue(owner.canvas.selection.cells.isEmpty)
            XCTAssertTrue(owner.redo()); XCTAssertEqual(semantic(owner.document), semantic(expectedRedo))
            XCTAssertTrue(owner.canvas.selection.cells.isEmpty)
            XCTAssertFalse(owner.canRedo)
        }
    }

    @MainActor func testChannelChangeKeepsDistinctFineAndDormantValuesAndExpiredConfirmationCannotOverwriteNewEdit() throws {
        let owner = try MonitorRootFixture().root.document
        let layer = owner.document.spatial.layers[0]
        let a = PolarDeviceLattice(ring: 51, sector: 180)!
        let b = PolarDeviceLattice(ring: 52, sector: 180)!
        let dormant = PolarDeviceLattice(ring: 53, sector: 180)!
        let values: [PolarDeviceLattice: [SpatialCellAction]] = [
            a: [.init(target: .midiNote(channel: 0), value: .note(number: 70, velocity: 88))],
            b: [.init(target: .midiNote(channel: 0), value: .note(number: 72, velocity: 91))],
            dormant: [.init(target: .midiNote(channel: 0), value: .chord(notes: [71, 74], velocity: 90))]]
        try owner.edit { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [
            .init(id: layer.id, name: layer.name, color: layer.color, isVisible: true, isActive: true,
                isLocked: false, isSoloed: false, cells: [a, b], routings: [.init(target: .midiNote(channel: 0), program: .constant(60))],
                cellOverrides: values)], selectedLayerID: layer.id) }
        let before = owner.document.spatial
        var next = owner.canvas.presentation
        _ = next.setSelectedLayerMIDIChannel(9); owner.canvas.perform { $0 = next }
        XCTAssertEqual(owner.outputChangeLossCount, 0)
        XCTAssertEqual(owner.document.spatial.layers[0].cells, [a, b])
        XCTAssertEqual(owner.document.spatial.layers[0].cellOverrides,
            values.mapValues { $0.map { .init(target: .midiNote(channel: 9), value: $0.value) } })
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, before)
        XCTAssertTrue(owner.redo())
        let changed = owner.document.spatial
        next = owner.canvas.presentation; _ = next.setSelectedLayerTarget(.midiCC(channel: 9, controller: 74)); owner.canvas.perform { $0 = next }
        XCTAssertEqual(owner.outputChangeLossCount, 3)
        XCTAssertEqual(owner.document.spatial, changed)
        var detection = owner.document.detection; detection.temporalSmoothing = .median(window: 5)
        owner.updateDetectionConfiguration(detection)
        owner.confirmOutputChange()
        XCTAssertEqual(owner.document.spatial, changed)
        XCTAssertEqual(owner.document.detection, detection)
        XCTAssertEqual(owner.outputChangeLossCount, 0)
        XCTAssertEqual(owner.notice, "Output change expired; choose again")
    }

    @MainActor func testIncompatibleOutputDoesNotCommitBeforeConfirmation() throws {
        let owner = try MonitorRootFixture().root.document
        let layer = owner.document.spatial.layers[0]
        let cell = PolarDeviceLattice(ring: 51, sector: 180)!
        try owner.edit { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [
            .init(id: layer.id, name: layer.name, color: layer.color, isVisible: true, isActive: true,
                isLocked: false, isSoloed: false, cells: [cell], routings: [.init(target: .midiNote(channel: 0), program: .constant(60))],
                cellOverrides: [cell: [.init(target: .midiNote(channel: 0), value: .note(number: 70, velocity: 88))]])], selectedLayerID: layer.id) }
        let before = owner.document
        var next = owner.canvas.presentation
        _ = next.setSelectedLayerTarget(.midiCC(channel: 0, controller: 74))
        owner.canvas.perform { $0 = next }
        XCTAssertEqual(owner.document, before)
        XCTAssertEqual(owner.outputChangeLossCount, 1)
        owner.cancelOutputChange()
        XCTAssertEqual(owner.document, before)
        next = owner.canvas.presentation; _ = next.setSelectedLayerTarget(.midiCC(channel: 0, controller: 74)); owner.canvas.perform { $0 = next }
        owner.confirmOutputChange()
        XCTAssertEqual(owner.outputChangeLossCount, 0)
        XCTAssertNil(owner.document.spatial.layers[0].cellOverrides[cell])
        XCTAssertTrue(owner.undo())
        XCTAssertEqual(owner.document.spatial, before.spatial)
        next = owner.canvas.presentation; _ = next.setSelectedLayerTarget(.audioUnitNote(channel: 2, stripID: InstrumentChannel.legacyID), program: .constant(60)); owner.canvas.perform { $0 = next }
        XCTAssertEqual(owner.outputChangeLossCount, 0)
        XCTAssertEqual(owner.document.spatial.layers[0].cellOverrides[cell], [.init(target: .audioUnitNote(channel: 2, stripID: InstrumentChannel.legacyID), value: .note(number: 70, velocity: 88))])
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, before.spatial)
    }

    @MainActor func testDeactivateKeepsOwnValuesAndUndoRestoresExactFineCoverage() throws {
        let owner = try MonitorRootFixture().root.document
        let original = owner.document.spatial.layers[0]
        let cell = PolarDeviceLattice(ring: 51, sector: 180)!
        let actions = [SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 70, velocity: 88))]
        try owner.edit { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [
            .init(id: original.id, name: original.name, color: original.color, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                  cells: [cell], routings: [.init(target: .midiNote(channel: 0), program: .constant(60))], cellOverrides: [cell: actions])], selectedLayerID: original.id) }
        let before = owner.document.spatial
        var next = owner.canvas.presentation
        let size = CGSize(width: 800, height: 800)
        let point = MetricCanvasGeometry(size: size, viewport: next.viewport).screenPoint(for: .init(xMeters: 0, yMeters: 0.51))
        XCTAssertTrue(next.selectCell(atScreenPoint: point, canvasSize: size))
        _ = next.applyToSelection(.deactivate); owner.canvas.perform { $0 = next }
        XCTAssertTrue(owner.document.spatial.layers[0].cells.isEmpty)
        XCTAssertEqual(owner.document.spatial.layers[0].cellOverrides[cell], actions)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, before)
        XCTAssertTrue(owner.redo()); XCTAssertTrue(owner.document.spatial.layers[0].cells.isEmpty)
        XCTAssertEqual(owner.document.spatial.layers[0].cellOverrides[cell], actions)
    }
    func testDeactivateIsOfferedAndOwnValueIsVisiblyMarkedAndMoveHintIsAbsent() throws {
        let cell = PolarMetricGridCell(point: .init(xMeters: 0, yMeters: 0.5), grid: .quarterMeter)
        let dormant = PolarMetricGridCell(point: .init(xMeters: 0, yMeters: 0.8), grid: .quarterMeter)
        let layer = SpatialInstrumentLayer(name: "Test", color: .orange, polarCells: [cell],
            polarCellOverrides: [cell: [.init(target: .midiNote(channel: 0), value: .note(number: 60, velocity: 90))], dormant: []])
        XCTAssertTrue(SpatialCellLabel.hasOwnValue(cell: cell, layer: layer))
        XCTAssertFalse(SpatialCellLabel.hasOwnValue(cell: dormant, layer: layer))
        XCTAssertEqual(SpatialCellBulkMenu.items(layer: layer, selectionCount: 1).count, 6)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let field = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/CartesianScanFieldView.swift"))
        XCTAssertFalse(field.contains("drag and hold: move"))
        XCTAssertTrue(field.contains("region.hasOwnValue"))
        XCTAssertTrue(field.contains("Smoothing method"))
        XCTAssertTrue(field.contains("Minimum gap"))
        XCTAssertTrue(field.contains("Minimum points"))
        XCTAssertTrue(field.contains("Offset"))
    }
    @MainActor func testLayerSelectionNeverBecomesUndoAndTypingColorCoalesceInProductHistory() throws {
        let owner = try MonitorRootFixture().root.document
        var next = owner.canvas.presentation
        next.updateWorkspace(named: "Add layer") { _ = $0.addLayer() }
        owner.canvas.perform { $0 = next }
        let layer = owner.canvas.workspace.layers[0].id
        let revisionBeforeSelection = owner.document.revision
        next = owner.canvas.presentation; next.updateWorkspace { $0.selectLayer(layer) }; owner.canvas.perform { $0 = next }
        XCTAssertEqual(owner.document.revision, revisionBeforeSelection)
        XCTAssertEqual(owner.undoMenuTitle, "Undo: Add layer")
        XCTAssertTrue(owner.undo())
        XCTAssertEqual(owner.document.spatial.layers.count, 1)
        XCTAssertTrue(owner.redo())
        XCTAssertEqual(owner.document.spatial.layers.count, 2)
        XCTAssertEqual(owner.document.spatial.selectedLayerID, layer)
        next = owner.canvas.presentation; _ = next.renameSelectedLayer("A"); owner.canvas.perform { $0 = next }
        next = owner.canvas.presentation; _ = next.renameSelectedLayer("AB"); owner.canvas.perform { $0 = next }
        XCTAssertEqual(owner.undoMenuTitle, "Undo: Rename layer")
        XCTAssertTrue(owner.undo())
        XCTAssertEqual(owner.document.spatial.layers.first { $0.id == layer }?.name, "Layer 1")
        XCTAssertTrue(owner.redo())
        XCTAssertEqual(owner.document.spatial.layers.first { $0.id == layer }?.name, "AB")
        next = owner.canvas.presentation; _ = next.setSelectedLayerColor(.blue); owner.canvas.perform { $0 = next }
        next = owner.canvas.presentation; _ = next.setSelectedLayerColor(.green); owner.canvas.perform { $0 = next }
        XCTAssertTrue(owner.undo())
        XCTAssertEqual(owner.document.spatial.layers.first { $0.id == layer }?.color, .orange)
    }

    @MainActor func testDuplicatingLayerIsOneProductUndoStep() throws {
        let owner = try MonitorRootFixture().root.document
        let before = owner.document.spatial
        var next = owner.canvas.presentation
        next.updateWorkspace(named: "Duplicate layer") { _ = $0.duplicateSelectedLayer() }
        owner.canvas.perform { $0 = next }

        XCTAssertEqual(owner.document.spatial.layers.count, before.layers.count + 1)
        XCTAssertEqual(owner.undoMenuTitle, "Undo: Duplicate layer")
        XCTAssertTrue(owner.undo())
        XCTAssertEqual(owner.document.spatial, before)
        XCTAssertFalse(owner.canUndo)
    }

    @MainActor func testGridChangePreservesExactFineCellsAndDormantOwnValues() throws {
        let owner = try MonitorRootFixture().root.document
        let layer = owner.document.spatial.layers[0]
        let cell = PolarDeviceLattice(ring: 51, sector: 180)!
        let dormant = PolarDeviceLattice(ring: 8190, sector: 360)!
        let value = [SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 70, velocity: 88))]
        try owner.edit { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [
            .init(id: layer.id, name: layer.name, color: layer.color, isVisible: true, isActive: true,
                  isLocked: false, isSoloed: false, cells: [cell], routings: [.init(target: .midiNote(channel: 0), program: .constant(60))],
                  cellOverrides: [cell: value, dormant: []])], selectedLayerID: layer.id) }
        let fine = owner.document.spatial
        for size in MetricSquareGrid.CellSize.allCases {
            var next = owner.canvas.presentation
            _ = next.confirmGridChange(to: size); owner.canvas.perform { $0 = next }
            XCTAssertEqual(owner.document.spatial, fine, size.displayName)
            XCTAssertEqual(owner.document.editorGrid, size.grid)
        }
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, fine)
    }

    func testCommandASelectsOnlyPlayableCells() {
        let a = PolarMetricGridCell(point: .init(xMeters: 0, yMeters: 0.5), grid: .quarterMeter)
        let dormant = PolarMetricGridCell(point: .init(xMeters: 0, yMeters: 0.8), grid: .quarterMeter)
        var state = MetricCanvasInteractionState()
        state.updateWorkspace { $0.updateSelectedLayer { $0.polarCells = [a]; $0.polarCellOverrides = [dormant: []] } }
        XCTAssertTrue(state.perform(.selectAll))
        XCTAssertEqual(state.selectedPolarCells, [a])
    }
}

private struct EditingContractClock: RuntimeClock {
    let now: Double = 0
    func schedule(at deadline: Double, on queue: DispatchQueue, _ fire: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        RuntimeCancellation {}
    }
}
private final class EditingContractOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MusicEvent] = []
    var events: [MusicEvent] { lock.lock(); defer { lock.unlock() }; return storage }
    @Sendable func send(_ event: MusicEvent) -> PortSendResult {
        lock.lock(); defer { lock.unlock() }; storage.append(event); return .sent
    }
}

extension DocumentEditingContractTests {
    @MainActor func testPitchWholeLayerFineOverridesUndoRangeAndProductionEvaluation() throws {
        let root = try MonitorRootFixture().root, owner = root.document
        defer { root.terminate {} }
        let id = owner.document.spatial.layers[0].id
        let a = PolarDeviceLattice(ring: 100, sector: 180)!, b = PolarDeviceLattice(ring: 101, sector: 180)!
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let cc = SpatialRoutingTarget.midiCC(channel: 0, controller: 74)
        let layer = SpatialDocumentLayer(id: id, name: "Pitch", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: [a, b],
            routings: [.init(target: target, program: .chord(notes: [60, 64, 67], velocity: 100, transition: .legato)),
                       .init(target: cc, program: .constant(0.2))],
            cellOverrides: [a: [.init(target: target, value: .chord(notes: [60, 64, 67], velocity: 90))],
                            b: [.init(target: target, value: .note(number: 61, velocity: 80)), .init(target: cc, value: .scalar(0.8))]])
        try owner.edit { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id) }
        let original = owner.document
        XCTAssertTrue(owner.applyPitchOperation(.transpose(12)))
        let changed = owner.document.spatial.layers[0]
        XCTAssertEqual(changed.routings[0].program, .chord(notes: [72, 76, 79], velocity: 100, transition: .legato))
        XCTAssertEqual(changed.cellOverrides[a]?.first?.value, .chord(notes: [72, 76, 79], velocity: 90))
        XCTAssertEqual(changed.cellOverrides[b]?.first?.value, .note(number: 73, velocity: 80))
        XCTAssertEqual(changed.cellOverrides[b]?.last?.value, .scalar(0.8))
        XCTAssertFalse(InstrumentCompiler.canReuseIndex(from: original, for: owner.document))
        let compiled = owner.compiledInstrument
        let hits = compiled.hits(tick: 180, raw: 100)
        XCTAssertFalse(hits.isEmpty)
        let values = try compiled.evaluate(active: Dictionary(uniqueKeysWithValues: hits.map { ($0.layerID, $0) }))
        XCTAssertTrue(values.contains { evaluation in
            if case .notes(let notes, _) = evaluation.value { return Set(notes.map { Int($0.number) }) == [72, 76, 79] }; return false
        })
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, original.spatial)
        XCTAssertTrue(owner.redo()); XCTAssertEqual(owner.document.spatial.layers, [changed])
        XCTAssertTrue(owner.applyPitchOperation(.transpose(48))) // top note is exactly 127
        let before = owner.document
        XCTAssertFalse(owner.applyPitchOperation(.transpose(1)))
        XCTAssertEqual(owner.document, before)
        XCTAssertTrue(owner.undo())
        XCTAssertTrue(owner.canvas.selectLayers([id]))
        // Clear cell selection so the following operation addresses the complete layer.
        owner.canvas.perform { $0.clearSelection() }
        XCTAssertTrue(owner.applyPitchOperation(.invertDown))
        XCTAssertEqual(owner.document.spatial.layers[0].routings[0].program, .chord(notes: [67, 72, 76], velocity: 100, transition: .legato))
        XCTAssertEqual(SpatialAssignmentDraft.current(in: owner.canvas.presentation).rootMIDINote, 72)
        XCTAssertEqual(SpatialAssignmentDraft.current(in: owner.canvas.presentation).chordPreset, .major)
        XCTAssertEqual(try JSONDecoder().decode(InstrumentDocument.self, from: JSONEncoder().encode(owner.document)).spatial.layers[0].routings[0].chordRootMIDINote, 72)
        XCTAssertTrue(owner.applyPitchOperation(.invertUp))
        XCTAssertEqual(owner.document.spatial.layers[0].routings, changed.routings)
    }
}

extension DocumentEditingContractTests {
    @MainActor func testChannelPresetLoadAndLayerImportUseSingleUndoAndKeepOtherChannelsScenes() throws {
        let root = try MonitorRootFixture().root, owner = root.document
        defer { root.terminate {} }
        let original = owner.document
        let id = original.channels[0].id
        var channel = original.channels[0]; channel.levelDecibels = -9; channel.pan = 0.5
        let preset = ChannelPreset(name: "Channel test", channel: channel)
        XCTAssertTrue(try owner.loadChannelPreset(preset, into: id))
        XCTAssertEqual(owner.document.channels[0].levelDecibels, -9)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.channels, original.channels)
        XCTAssertTrue(owner.redo()); XCTAssertEqual(owner.document.channels[0].pan, 0.5)
        let beforeImport = owner.document
        for mode in ["explicit", "name", "missing"] {
            var source = original
            let sourceStrip = UUID(), sourceLayerID = UUID()
            source.channels[0].id = sourceStrip
            source.channels[0].name = mode == "missing" ? "Other source channel" : beforeImport.channels[0].name
            let cell = PolarDeviceLattice(ring: 100, sector: 180)!
            let dormant = PolarDeviceLattice(ring: 8100, sector: 180)!
            let target = SpatialRoutingTarget.audioUnitNote(channel: 2, stripID: sourceStrip)
            let sourceLayer = SpatialDocumentLayer(id: sourceLayerID, name: "Imported notes", color: .purple,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [cell],
                routings: [.init(target: target, program: .chord(notes: [60, 64, 67], velocity: 100, transition: .legato))],
                cellOverrides: [cell: [.init(target: target, value: .note(number: 62, velocity: 90))],
                    dormant: [.init(target: target, value: .note(number: 70, velocity: 80))]])
            source.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [sourceLayer], selectedLayerID: sourceLayerID)
            source.scenes = [.init(name: "Source scene", activeLayerIDs: [sourceLayerID])]
            XCTAssertTrue(try owner.importPresetLayers(source, ids: [sourceLayerID], channelID: mode == "explicit" ? id : nil))
            XCTAssertEqual(owner.document.spatial.layers.count, beforeImport.spatial.layers.count + 1)
            let copied = try XCTUnwrap(owner.document.spatial.layers.last)
            let expected = target.withStripID(mode == "missing" ? SpatialRoutingTarget.missingStripID : id)
            XCTAssertNotEqual(copied.id, sourceLayerID); XCTAssertEqual(copied.cells, sourceLayer.cells)
            XCTAssertEqual(copied.routings[0].program, sourceLayer.routings[0].program)
            XCTAssertEqual(copied.routings[0].target, expected)
            XCTAssertEqual(copied.cellOverrides[cell], [.init(target: expected, value: .note(number: 62, velocity: 90))])
            XCTAssertEqual(copied.cellOverrides[dormant], [.init(target: expected, value: .note(number: 70, velocity: 80))])
            XCTAssertEqual(owner.document.scenes, beforeImport.scenes)
            XCTAssertEqual(owner.document.channels, beforeImport.channels)
            XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, beforeImport.spatial)
            XCTAssertTrue(owner.redo()); XCTAssertEqual(owner.document.spatial.layers.last?.cells, sourceLayer.cells)
            XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, beforeImport.spatial)
            print("RUNDE-D import \(mode): painted+dormant values and target verified")
        }
    }
}

extension DocumentEditingContractTests {
    @MainActor func testThreeLayerRetargetOneUndoLockedSkippedAndGroupSelectionBudget() throws {
        let root = try MonitorRootFixture().root, owner = root.document
        defer { root.terminate {} }
        let target = SpatialRoutingTarget.audioUnitNote(channel: 0, stripID: owner.document.channels[0].id)
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let layers = (0..<8).map { index in
            SpatialDocumentLayer(id: UUID(), name: "Layer \(index)", color: .blue, isVisible: true,
                isActive: true, isLocked: index == 3, isSoloed: false, cells: index == 7 ? [] : [cell],
                routings: [.init(target: target, program: .singleNote(note: 60 + index, velocity: 100, transition: .holdUntilNext))],
                cellOverrides: [cell: [.init(target: target, value: .note(number: 70 + index, velocity: 90))]])
        }
        try owner.edit { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id) }
        let before = owner.document
        let ids = Set(layers.map(\.id))
        let begin = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(owner.canvas.selectLayers(ids, active: layers[0].id))
        XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - begin) * 1000, 50)
        XCTAssertEqual(owner.canvas.selection.layerIDs, ids)
        let subset = Set(layers.prefix(4).map(\.id))
        XCTAssertEqual(owner.canvas.applyToLayers(subset, named: "Retarget layers") { layer in
            SpatialCellBulkEdit.retarget(&layer, to: .midiNote(channel: 0), fallbackProgram: .singleNote(note: 99, velocity: 100, transition: .legato))
        }, 1)
        for index in 0..<3 {
            XCTAssertEqual(owner.document.spatial.layers[index].routings[0].target, .midiNote(channel: 0))
            XCTAssertEqual(owner.document.spatial.layers[index].routings[0].program, before.spatial.layers[index].routings[0].program)
            XCTAssertEqual(owner.document.spatial.layers[index].cellOverrides[cell]?.first?.target, .midiNote(channel: 0))
            XCTAssertEqual(owner.document.spatial.layers[index].cellOverrides[cell]?.first?.value, .note(number: 70 + index, velocity: 90))
        }
        XCTAssertEqual(owner.document.spatial.layers[3], before.spatial.layers[3])
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, before.spatial)
        XCTAssertTrue(owner.redo())
        let beforeLockedPitch = owner.document.spatial
        XCTAssertTrue(owner.applyPitchOperation(.transpose(12)))
        XCTAssertEqual(owner.document.spatial.layers[3], beforeLockedPitch.layers[3])
        for index in [0, 1, 2, 4, 5, 6, 7] {
            XCTAssertEqual(owner.document.spatial.layers[index].routings[0].program,
                .singleNote(note: 72 + index, velocity: 100, transition: .holdUntilNext))
        }
        XCTAssertTrue(owner.notice?.contains("1 locked") == true)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, beforeLockedPitch)
        let beforeUnlock = owner.document.spatial
        owner.canvas.setLayerLocks(ids, locked: false)
        XCTAssertTrue(owner.document.spatial.layers.allSatisfy { !$0.isLocked })
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, beforeUnlock)
    }
}

extension DocumentEditingContractTests {
    @MainActor func testChannelPresetLoadAndLayerRetargetReleaseSoundingNotesThroughProductionOwner() throws {
        for retarget in [false, true] {
        for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
            let root = try MonitorRootFixture(clock: EditingContractClock()).root, owner = root.document
            defer { root.terminate {} }
            let id = owner.document.spatial.layers[0].id, strip = owner.document.channels[0].id
            let cell = PolarDeviceLattice(ring: 100, sector: 180)!
            let target = SpatialRoutingTarget.audioUnitNote(channel: 0, stripID: strip)
            let layer = SpatialDocumentLayer(id: id, name: "Sound", color: .blue, isVisible: true,
                isActive: true, isLocked: false, isSoloed: false, cells: [cell],
                routings: [.init(target: target, program: .singleNote(note: 60, velocity: 100, transition: transition))], cellOverrides: [:])
            let layers = transition == .legato ? (0..<3).map { index in
                SpatialDocumentLayer(id: index == 0 ? id : UUID(), name: "Batch \(index)", color: .blue,
                    isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [cell],
                    routings: [.init(target: target, program: .singleNote(note: 60 + index, velocity: 100, transition: transition))], cellOverrides: [:])
            } : [layer]
            try owner.edit {
                $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: id)
                $0.detection = .allStagesOff
            }
            let output = EditingContractOutput()
            root.runtime.attach(.init(destination: .audioUnit(stripID: strip), send: output.send))
            func drain() { let done = expectation(description: "Queue barrier"); root.runtime.acknowledge { done.fulfill() }; wait(for: [done], timeout: 5) }
            let session = UUID(); root.runtime.sessionBegan(session)
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<361).map { try .build(value: $0 == 180 ? 100 : 300, fieldFlags: 0) })
            let geometry = try FullScanProfileAdapter.geometry(from: raw)
            root.runtime.frame(.init(sessionID: session, sequence: 1, time: 0,
                measurements: try FullScanProfileAdapter.measurements(from: raw, geometry: geometry), geometry: geometry, rawProfile: raw))
            drain()
            XCTAssertTrue(output.events.contains { if case .noteOn = $0 { return true }; return false })
            let count = output.events.count
            let preset = ChannelPreset(name: "Same channel", channel: owner.document.channels[0])
            if retarget {
                owner.canvas.applyToLayers(Set(layers.map(\.id)), named: "Retarget") { $0.routings[0].target = .midiNote(channel: 0) }
            } else { XCTAssertTrue(try owner.loadChannelPreset(preset, into: strip)) }
            drain()
            XCTAssertEqual(output.events.dropFirst(count).filter { if case .noteOff = $0 { return true }; return false }.count, layers.count)
            XCTAssertEqual(root.runtime.mailbox.read()?.ports.map(\.soundingNotes).reduce(0, +), 0)
        }
    }
}
}

extension DocumentEditingContractTests {
    @MainActor func testPitchSelectedFineCellsUsesInheritedNotesWithMissingOutputAndPerformGuard() throws {
        let root = try MonitorRootFixture().root, owner = root.document
        defer { root.terminate {} }
        let id = owner.document.spatial.layers[0].id
        let a = PolarDeviceLattice(ring: 100, sector: 180)!, b = PolarDeviceLattice(ring: 101, sector: 180)!, outside = PolarDeviceLattice(ring: 150, sector: 180)!
        let target = SpatialRoutingTarget.audioUnitNote(channel: 0, stripID: UUID())
        let cc = SpatialRoutingTarget.midiCC(channel: 0, controller: 74)
        let layer = SpatialDocumentLayer(id: id, name: "Missing output", color: .blue, isVisible: true,
            isActive: false, isLocked: false, isSoloed: false, cells: [a, b, outside],
            routings: [.init(target: target, program: .singleNote(note: 64, velocity: 100, transition: .legato)), .init(target: cc, program: .constant(0.2))],
            cellOverrides: [a: [.init(target: cc, value: .scalar(0.3))]])
        try owner.edit { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id) }
        let size = CGSize(width: 800, height: 800)
        let point = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for: .init(xMeters: 0, yMeters: 1))
        XCTAssertTrue(owner.canvas.perform { $0.selectCell(atScreenPoint: point, canvasSize: size) })
        XCTAssertFalse(owner.canvas.selectedCells.isEmpty)
        let before = owner.document
        XCTAssertFalse(owner.applyPitchOperation(.invertDown)); XCTAssertEqual(owner.document, before)
        XCTAssertTrue(owner.applyPitchOperation(.transpose(12)))
        XCTAssertEqual(owner.document.spatial.layers[0].routings, layer.routings)
        XCTAssertEqual(owner.document.spatial.layers[0].cellOverrides[a]?.first(where: { $0.target == target })?.value, .note(number: 76, velocity: 100))
        XCTAssertEqual(owner.document.spatial.layers[0].cellOverrides[b]?.first?.value, .note(number: 76, velocity: 100))
        XCTAssertEqual(owner.document.spatial.layers[0].cellOverrides[a]?.first(where: { $0.target == cc })?.value, .scalar(0.3))
        XCTAssertNil(owner.document.spatial.layers[0].cellOverrides[outside])
        let edited = owner.document
        owner.canvas.setPerformanceLocked(true)
        XCTAssertFalse(owner.applyPitchOperation(.transpose(12))); XCTAssertEqual(owner.document, edited)
    }
}


extension DocumentEditingContractTests {
    @MainActor func testRetargetIncompatibleControlConfirmsLossAndUsesFallbackWithOneUndo() throws {
        let root = try MonitorRootFixture().root, owner = root.document
        defer { root.terminate {} }
        let id = owner.document.spatial.layers[0].id
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let old = SpatialRoutingTarget.sceneSwitch(action: .next, dwellSeconds: 0.2)
        let layer = SpatialDocumentLayer(id: id, name: "Control", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: [cell],
            routings: [.init(target: old, program: .constant(1))],
            cellOverrides: [cell: [.init(target: old, value: .sceneSwitch(action: .next))]])
        try owner.edit(name: "Seed control") { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id) }
        let before = owner.document
        let target = old.retargeted(to: .midi, stripID: SpatialRoutingTarget.missingStripID)
        let fallback = SpatialValueProgram.singleNote(note: 64, velocity: 100, transition: .legato)
        func change() {
            owner.canvas.applyToLayers([id], named: "Change output") { SpatialCellBulkEdit.retarget(&$0, to: target, fallbackProgram: fallback) }
        }
        change()
        XCTAssertEqual(owner.outputChangeLossCount, 1); XCTAssertEqual(owner.document, before)
        XCTAssertEqual(owner.undoMenuTitle, "Undo: Seed control")
        owner.cancelOutputChange(); XCTAssertEqual(owner.document, before)
        change(); owner.confirmOutputChange()
        XCTAssertEqual(owner.outputChangeLossCount, 0)
        XCTAssertEqual(owner.document.spatial.layers[0].routings[0].program, fallback)
        XCTAssertEqual(owner.document.spatial.layers[0].routings[0].target, .midiNote(channel: 0))
        XCTAssertNil(owner.document.spatial.layers[0].cellOverrides[cell])
        XCTAssertEqual(owner.undoMenuTitle, "Undo: Change output")
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, before.spatial)
    }
}


extension DocumentEditingContractTests {
    @MainActor func testTargetGroupsSelectEightLayersRetargetAddAndFlagsUseProductionUndo() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let strip = owner.document.channels[0].id
        let layers = (0..<10).map { index in
            SpatialDocumentLayer(id: UUID(), name: "Group \(index)", color: .blue,
                isVisible: true, isActive: true, isLocked: index == 7, isSoloed: false, cells: [],
                routings: [.init(target: index < 8 ? .audioUnitNote(channel: 0, stripID: strip) : .midiNote(channel: 2),
                    program: .chord(notes: [60,64,67], velocity: 100, transition: .holdUntilNext))], cellOverrides: [:],
                midiTarget: index == 9 ? .init(uniqueID: 0) : nil)
        }
        try owner.edit(name: "Groups seed") {
            $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id)
        }
        let groups = SpatialLayerGroup.groups(workspace: owner.canvas.workspace, document: owner.document)
        XCTAssertEqual(groups.map { $0.layers.count }, [8, 2])
        XCTAssertEqual(groups[0].name, owner.document.channels[0].name)
        let start = Date()
        XCTAssertTrue(owner.canvas.selectLayers(groups[0].layerIDs, active: layers[7].id))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
        XCTAssertEqual(owner.canvas.selection.layerIDs.count, 8)
        XCTAssertEqual(owner.canvas.workspace.selectedLayerID, layers[7].id)
        let seeded = owner.document.spatial
        owner.canvas.applyToLayers(groups[0].layerIDs, named: "Group mute") { $0.isActive = false }
        XCTAssertEqual(owner.document.spatial.layers.filter { !$0.isActive }.count, 7)
        XCTAssertTrue(owner.document.spatial.layers[7].isActive)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial.layers, seeded.layers)
        owner.canvas.applyToLayers([layers[0].id], named: "Move layer to group") { groups[1].retarget(&$0) }
        XCTAssertEqual(owner.document.spatial.layers[0].routings.first?.target, .midiNote(channel: 2))
        XCTAssertEqual(owner.document.spatial.layers[0].routings.first?.program, layers[0].routings[0].program)
        XCTAssertEqual(SpatialLayerGroup.groups(workspace: owner.canvas.workspace, document: owner.document).map { $0.layers.count }, [7,3])
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial.layers, seeded.layers)
        owner.canvas.updateWorkspace(named: "Add layer to group") { workspace in
            let id = workspace.addLayer()
            workspace.updateLayer(id) { groups[1].retarget(&$0) }
        }
        XCTAssertEqual(owner.document.spatial.layers.last?.routings.first?.target, .midiNote(channel: 2))
        XCTAssertEqual(owner.document.spatial.layers.count, 11)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial.layers, seeded.layers)
        owner.canvas.setLayerLocks(groups[0].layerIDs, locked: false)
        XCTAssertFalse(owner.document.spatial.layers.contains { $0.isLocked })
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial.layers, seeded.layers)
        owner.canvas.setPerformanceLocked(true)
        owner.canvas.applyToLayers(groups[0].layerIDs, named: "Forbidden group edit") { $0.isVisible = false }
        XCTAssertEqual(owner.document.spatial.layers, seeded.layers)
    }
}

extension DocumentEditingContractTests {
    @MainActor func testMixerAndWindowVisibilityEnableTablesOnlyForDiagnosticInBothOrders() throws {
        let fixture = try MonitorRootFixture(), root = fixture.root
        defer { root.terminate {} }
        root.runtime.attach(.init(destination: .midi, send: { _ in .sent }))
        func drain() {
            let done = expectation(description: "Monitor barrier")
            root.runtime.acknowledge { done.fulfill() }; wait(for: [done], timeout: 5)
        }
        for mixerFirst in [false,true] {
            root.display.setOutputMonitorVisible(!mixerFirst)
            root.display.setMixerMonitorVisible(mixerFirst)
            drain()
            XCTAssertEqual(root.runtime.mailbox.read()?.outputMonitor.isEmpty, mixerFirst)
            root.display.setOutputMonitorVisible(true); root.display.setMixerMonitorVisible(true)
            if mixerFirst { root.display.setMixerMonitorVisible(false) }
            else { root.display.setOutputMonitorVisible(false) }
            drain()
            XCTAssertEqual(root.runtime.mailbox.read()?.outputMonitor.isEmpty, !mixerFirst)
            root.display.setOutputMonitorVisible(false); root.display.setMixerMonitorVisible(false)
            drain()
            XCTAssertTrue(root.runtime.mailbox.read()?.outputMonitor.isEmpty ?? false)
        }
    }
}
