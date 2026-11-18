import AppKit
import SwiftUI
import XCTest
import PlanariumDomain
import PlanariumPresets
import PlanariumRuntime
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class HaltenToggleRenderingTests: XCTestCase {
    func testOwnerAmCRecordingReplaysSoundingOwnershipAndHeldDisplay() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".agent_handoff/runs/hold-am-c")
        let full = ProcessInfo.processInfo.environment["SICK_OWNER_AM_C_FULL_REPLAY"] == "1"
        let fixtures = root.appendingPathComponent("Tests/PlanariumPresetsTests/Fixtures/HoldAmC")
        let input = full ? directory.appendingPathComponent("aufnahme-am-c.json") : fixtures.appendingPathComponent("recording-excerpt.json")
        let recording = try JSONDecoder().decode(ProfileRecording.self, from: Data(contentsOf: input))
        var document = try PresetDocumentReader.read(Data(contentsOf: fixtures.appendingPathComponent("owner-preset.json"))).get().replacing(FactoryPresetDocument.empty())
        document.detection = recording.detection
        let compiled = try InstrumentCompiler.compile(document)
        var state = PlayEngine.step(PlayState(), .install(compiled)).0
        state = PlayEngine.step(state, .roomContour(recording.contour)).0
        state = PlayEngine.step(state, .sessionBegan(recording.scans[0].sessionID)).0
        let names = Dictionary(uniqueKeysWithValues: document.spatial.layers.map { ($0.id, $0.name) })
        let cID = try XCTUnwrap(document.spatial.layers.first { $0.name == "C" }?.id)
        let amID = try XCTUnwrap(document.spatial.layers.first { $0.name == "Am" }?.id)
        let fixture = try MonitorRootFixture(), display = SpatialActiveCellDisplayModel()
        defer { fixture.root.terminate {} }
        try fixture.root.document.applyPresetDocument(document)
        var falseHoldHighlights = 0
        var rows = "sequence\ttime\tobjects (source:representative layers)\tselected\tsounding owners\theld display\thighlighted owners\tcommands\n"
        var cOwners = 0, mismatchedDisplays = 0, cRepresentativeFrames = 0, strandedAmFrames = 0
        for scan in recording.scans {
            let frame = try scan.frame()
            let step = PlayEngine.step(state, .frame(frame)); state = step.0
            let objects = state.selection.objects.map { object -> String in
                let rep = object.representative
                let hits = compiled.hits(tick: Int(((rep.bearingDegrees + 90) * 2).rounded()), raw: Int(rep.distanceCentimeters.rounded()))
                if hits.contains(where: { $0.layerID == cID }) { cRepresentativeFrames += 1 }
                return "\(String(describing: object.sourceOrder)):" + hits.compactMap { names[$0.layerID] }.joined(separator: ",")
            }.joined(separator: ";")
            let owners = Set(state.soundingNoteOwners.filter(\.latched).map(\.layerID))
            let held = Set(state.heldCells.map(\.layerID))
            display.update(.init(profile: frame, selection: state.selection, heldCells: state.heldCells), workspace: fixture.root.document.canvas.workspace)
            let highlighted = Set(display.activeCells.keys).union(display.frame.heldCells.keys)
            if highlighted != owners { falseHoldHighlights += 1 }
            if Set(state.selection.activeHandles.keys) == [cID], owners != [cID] { strandedAmFrames += 1 }
            if owners.contains(cID) { cOwners += 1 }
            if owners != held { mismatchedDisplays += 1 }
            let selected = state.selection.activeHandles.values.sorted { $0.layerID.uuidString < $1.layerID.uuidString }.map { "\(names[$0.layerID] ?? "?"):\($0.cell.ring)/\($0.cell.sector)" }.joined(separator: ";")
            let heldText = state.heldCells.map { "\(names[$0.layerID] ?? "?"):\($0.cell.ring)/\($0.cell.sector)" }.joined(separator: ";")
            rows += "\(scan.sequence)\t\(scan.time)\t\(objects)\t\(selected)\t\(owners.compactMap { names[$0] }.sorted().joined(separator: ","))\t\(heldText)\t\(highlighted.compactMap { names[$0] }.sorted().joined(separator: ","))\t\(step.1)\n"
            if full && [61072, 61074].contains(scan.sequence) {
                _ = NSApplication.shared
                let workspace = fixture.root.document.canvas.workspace
                for width in [1024, 380] {
                    let height = width == 380 ? 280 : 620
                    let viewport = try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 0.55, metersPerPoint: 1.8 / Double(width))
                    let geometry = MetricCanvasGeometry(size: CGSize(width: width, height: height), viewport: viewport)
                    let view = ZStack {
                        SpatialInstrumentStaticLayer(plan: fixture.root.document.fieldPlan, labels: fixture.root.document.fieldLabels,
                            selectedLayerID: workspace.selectedLayerID, mergeZones: true, geometry: geometry)
                        SpatialInstrumentActiveLayer(cells: display, workspace: workspace, geometry: geometry)
                    }.background(StageTheme.canvas).environment(\.colorScheme, .dark)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    host.frame = .init(x: 0, y: 0, width: width, height: height); host.wantsLayer = true
                    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("owner-replay-\(scan.sequence)-\(width).png"))
                }
            }
            XCTAssertLessThanOrEqual(owners.count, 1, "One held chord per channel")
        }
        let output = full ? directory : TestImageDirectory.make()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try rows.write(to: output.appendingPathComponent(full ? "replay-after.tsv" : "replay-excerpt.tsv"), atomically: true, encoding: .utf8)
        print("OWNER-AM-C frames=\(recording.scans.count) cRepresentativeFrames=\(cRepresentativeFrames) cOwners=\(cOwners) mismatchedDisplays=\(mismatchedDisplays) Am=\(amID)")
        XCTAssertGreaterThan(cOwners, 0, "Recorded C entry must replace held Am")
        XCTAssertEqual(strandedAmFrames, 0, "A measured exit from Am into remaining C must not leave Am stranded")
        XCTAssertEqual(mismatchedDisplays, 0, "Held display must name sounding owners")
        XCTAssertEqual(falseHoldHighlights, 0, "Only actually sounding Hold ownership may light up")
    }

    func testToggleGuardAuthoringPersistenceUndoPerformLockAndWideNarrowOffline() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph)
        let owner = fixture.root.document, catalog = AudioCatalogModel(document: fixture.root.document, source: EmptyCatalog())
        let cell = PolarMetricGridCell(ring: 4, angularIndex: 10)
        owner.canvas.updateWorkspace { $0 = .init(layers: [
            .init(name: "Toggle", color: .orange, polarCells: [cell], routings: [
                .init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .toggle))])
        ]) }
        func inspector() -> SpatialLayerInspectorView {
            .init(editor: owner.canvas, audioUnits: catalog, midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
        }
        XCTAssertTrue(inspector().toggleGuardEnabled)
        inspector().toggleGuardBinding.wrappedValue = 1.25
        XCTAssertEqual(owner.document.spatial.layers[0].toggleGuardSeconds, 1.25)
        XCTAssertEqual(owner.compiledInstrument.layers[0].routings[0].toggleGuardSeconds, 1.25)
        owner.undo(); XCTAssertEqual(owner.document.spatial.layers[0].toggleGuardSeconds, 0.5)
        owner.redo(); XCTAssertEqual(inspector().toggleGuardBinding.wrappedValue, 1.25)
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in ["toggle", "other", "perform", "locked"] {
            owner.canvas.setPerformanceLocked(false)
            owner.canvas.updateWorkspace {
                $0.updateSelectedLayer { $0.isLocked = false }
                $0.setNoteTransition(state == "other" ? .legato : .toggle)
            }
            if state == "perform" { owner.canvas.setPerformanceLocked(true) }
            if state == "locked" { owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.isLocked = true } } }
            XCTAssertEqual(inspector().toggleGuardEnabled, state == "toggle")
            if state != "toggle" {
                inspector().toggleGuardBinding.wrappedValue = 0
                XCTAssertEqual(owner.document.spatial.layers[0].toggleGuardSeconds, 1.25)
                XCTAssertTrue(inspector().toggleGuardHelp.contains(state == "perform" ? "Perform" : state == "other" ? "Select Toggle" : "Unlock"))
            }
            for width in [560, 260] {
                try render(inspector(), width: width, height: 840, name: "toggle-guard-\(state)-\(width).png", directory: directory)
            }
        }
        XCTAssertEqual(graph.starts, 0)
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }
    func testSnapDetectionControlsWideNarrowOffline() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph)
        let owner = fixture.root.document, display = SpatialActiveCellDisplayModel()
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for snap: UInt16 in [0, 5, 10] {
            var config = owner.canvas.workspace.detectionConfiguration
            config.cellSelection = .init(boundaryMarginCentimeters: snap)
            owner.updateDetectionConfiguration(config)
            XCTAssertEqual(owner.document.detection.cellSelection.boundaryMarginCentimeters, snap)
            for width in [1120, 420] {
                try render(CartesianScanFieldView(editor: owner.canvas, profile: nil, activeCellDisplay: display,
                    spatialInstrument: owner, simulationBadge: AnyView(Text("Offline")), detectionInitiallyExpanded: true),
                    width: width, height: 950, name: "zell-snap-\(snap)-\(width).png", directory: directory)
            }
        }
        XCTAssertEqual(graph.starts, 0)
        var done = false; fixture.root.terminate { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }
    func testSingleNoteAndScaleInspectorStatesWideAndNarrowOffline() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph)
        let owner = fixture.root.document
        let catalog = AudioCatalogModel(document: owner, source: EmptyCatalog())
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cell = PolarMetricGridCell(ring: 4, angularIndex: 10)
        let programs: [(String, SpatialValueProgram)] = [
            ("single", .singleNote(note: 61, velocity: 83, transition: .toggle)),
            ("scale", .scale(rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84,
                             scale: .major, directionDegrees: 90, ascending: true, transition: .retrigger)),
            ("random", .randomScale(rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84,
                                    scale: .major, seed: 1, transition: .retrigger))
        ]
        for (name, program) in programs {
            owner.canvas.updateWorkspace { $0 = .init(grid: .quarterMeter, layers: [
                .init(name: name, color: .orange, polarCells: [cell],
                      routings: [.init(target: .midiNote(channel: 0), program: program)])
            ]) }
            let inspector = SpatialLayerInspectorView(editor: owner.canvas, audioUnits: catalog,
                midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
            XCTAssertEqual(inspector.canChooseToggle, name == "single")
            for width in [560, 260] {
                try render(inspector, width: width, height: 840,
                           name: "single-note-\(name)-\(width).png", directory: directory)
            }
            if name == "single" {
                let keyboard = inspector.assignmentKeyboard
                XCTAssertEqual(keyboard.model.selectedNotes, [61])
            }
        }
    }

    func testToggleInspectorReleaseCellAndReleaseFieldWideAndNarrowOffline() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph)
        let root = fixture.root, owner = root.document
        let cell = PolarMetricGridCell(ring: 4, angularIndex: 10)
        let releaseCell = PolarMetricGridCell(ring: 6, angularIndex: 18)
        let note = SpatialInstrumentLayer(name: "Am", color: .orange, polarCells: [cell],
            routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [57, 60, 64], velocity: 100, transition: .toggle))])
        let release = SpatialInstrumentLayer(name: "Release", color: .blue, polarCells: [releaseCell],
            routings: [.init(target: .releaseLayer(layerID: note.id), program: .constant(1))])
        owner.canvas.updateWorkspace { $0 = .init(grid: .quarterMeter, layers: [note, release]) }
        XCTAssertEqual(owner.canvas.workspace.layers.count, 2)
        let catalog = AudioCatalogModel(document: owner, source: EmptyCatalog())
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [560, 260] {
            try render(SpatialLayerInspectorView(editor: owner.canvas,
                audioUnits: catalog, midiOutput: root.midi, spatialInstrument: owner, evaluationCounter: nil),
                width: width, height: 840, name: "halten-toggle-inspector-\(width).png", directory: directory)
        }
        owner.canvas.updateWorkspace { $0.selectLayer(release.id) }
        XCTAssertTrue(owner.canvas.perform(.selectAll))
        XCTAssertNotNil(owner.canvas.selectedPolarCell)
        XCTAssertEqual(SpatialReleaseLayerPresentation.selectionTitle(in: owner.canvas.presentation), "Am")
        XCTAssertEqual(owner.fieldPlan.regions.first { $0.layerID == release.id }?.label, "Release Am")
        for width in [560, 260] {
            try render(CellInspectorView(editor: owner.canvas),
                width: width, height: 420, name: "halten-release-cell-\(width).png", directory: directory)
        }
        let display = SpatialActiveCellDisplayModel()
        for width in [1120, 420] {
            try render(CartesianScanFieldView(editor: owner.canvas,
                profile: nil, activeCellDisplay: display, spatialInstrument: owner, simulationBadge: AnyView(Text("Offline"))),
                width: width, height: 950, name: "halten-release-field-\(width).png", directory: directory)
        }
        let regions = owner.fieldPlan.regions
        owner.canvas.updateWorkspace { $0.updateLayer(note.id) { $0.name = "Renamed" } }
        XCTAssertEqual(owner.fieldPlan.regions.first { $0.layerID == release.id }?.label, "Release Renamed")
        XCTAssertNotEqual(regions.first { $0.layerID == release.id }?.label, "Release Renamed")
        owner.canvas.updateWorkspace { $0.selectLayer(note.id); $0.deleteSelectedLayer(); $0.selectLayer(release.id) }
        XCTAssertEqual(SpatialReleaseLayerPresentation.selectionTitle(in: owner.canvas.presentation), "missing layer")
        XCTAssertEqual(owner.fieldPlan.regions.first { $0.layerID == release.id }?.label, "Release missing layer")
        XCTAssertEqual(graph.starts, 0)
        var done = false; root.terminate { done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }
    func testReleaseAuthoringCellDefaultMissingAndSceneExclusion() throws {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 10)
        var state = MetricCanvasInteractionState()
        let noteID = state.workspace.selectedLayerID
        state.updateWorkspace { $0.addLayer(name: "Release"); $0.updateSelectedLayer { $0.polarCells = [cell] } }
        let releaseID = state.workspace.selectedLayerID
        XCTAssertTrue(state.setSelectedLayerTarget(.releaseLayer(layerID: noteID), program: .constant(1)))
        state.updateWorkspace { _ = $0.addScene(name: "Scene") }
        XCTAssertTrue(state.workspace.controlLayerIDs.contains(releaseID))
        XCTAssertFalse(state.workspace.scenes[0].activeLayerIDs.contains(releaseID))
        XCTAssertTrue(state.perform(.selectAll))
        let missing = UUID()
        XCTAssertTrue(state.setReleaseLayerTarget(missing))
        XCTAssertEqual(SpatialReleaseLayerPresentation.selectionTitle(in: state), "missing layer")
        XCTAssertTrue(state.resetSelectedCellsToLayer())
        XCTAssertEqual(SpatialReleaseLayerPresentation.selectionTitle(in: state), state.workspace.layers.first { $0.id == noteID }?.name)
    }
    private func render<Content: View>(_ view: Content, width: Int, height: Int, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark).padding(10).background(StageTheme.workspace))
        host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.08)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}
