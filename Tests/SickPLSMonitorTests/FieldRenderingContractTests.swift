import XCTest
import Combine
import AppKit
import SwiftUI
import PlanariumApplication
import PlanariumAudio
import PlanariumDomain
import PlanariumPresets
import PlanariumRuntime
import SickPLSCore
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class FieldRenderingContractTests: XCTestCase {
    func testRundeGAllScenesOriginalAndShrunkHaveActiveLabelsAndReusePaths() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmony 30 Mode Wheel"))
        let original = try PresetDocumentReader.read(data).get().replacing(owner.document)
        for shrunk in [false, true] {
            try owner.applyPresetDocument(original)
            if shrunk {
                let room = SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5,
                    startAngleDegrees: -90, sourceIdentifier: "test"),
                    nearestDistancesCentimeters: Array(repeating: 130, count: 361),
                    spreadCentimeters: Array(repeating: 0, count: 361))
                XCTAssertNotNil(owner.canvas.fitToRoom(room))
            }
            _ = owner.canvas.selectLayers([owner.canvas.workspace.selectedLayerID])
            owner.canvas.setPerformanceLocked(true)
            XCTAssertFalse(owner.showInactiveSceneLayers)
            let identity = owner.fieldPlan.identity
            for scene in owner.document.scenes {
                owner.selectScene(scene.id)
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                let workspace = owner.canvas.workspace
                let audible = SpatialLayerAudibility.audibleIDs(workspace.layers.map { ($0.id, $0.isActive, $0.isSoloed) })
                XCTAssertEqual(Set(owner.fieldPlan.paintOrder(selectedLayerID: workspace.selectedLayerID).map(\.id)), audible)
                let labels = owner.fieldLabels.map { owner.fieldPlan.regions[$0.regionIndex] }
                for id in audible {
                    XCTAssertEqual(labels.filter { $0.layerID == id }.count, 1,
                        "\(scene.name) \(workspace.layers.first { $0.id == id }!.name) shrunk=\(shrunk)")
                }
                XCTAssertTrue(labels.allSatisfy { audible.contains($0.layerID) })
                let selectionInk = SpatialInstrumentSelectionLayer(state: owner.canvas.presentation,
                    geometry: owner.canvas.displayGeometry(canvasSize: .init(width: 900, height: 1100)), plan: owner.fieldPlan)
                XCTAssertEqual(selectionInk.displayedLayerIDs, audible)
                XCTAssertEqual(owner.fieldPlan.identity, identity)
                for width in [900, 360] {
                    let extent = owner.fieldPlan.regions.reduce(0.0) { result, region in
                        max(result, Double(abs(region.bounds.minX)), Double(abs(region.bounds.maxX)), Double(region.bounds.maxY))
                    }
                    owner.canvas.applyPresetViewport(try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 0.65,
                        metersPerPoint: max(1, extent * 2.1) / Double(width)), canvasSize: .init(width: width, height: 1100))
                    let host = NSHostingView(rootView: Harness(instrument: owner, cells: SpatialActiveCellDisplayModel())
                        .environment(\.colorScheme, .dark).preferredColorScheme(.dark))
                    host.appearance = NSAppearance(named: .darkAqua)
                    host.frame = .init(x: 0, y: 0, width: width, height: 1100)
                    host.layoutSubtreeIfNeeded()
                    func canvasSize(_ view: NSView) -> CGSize? {
                        if let pointer = view as? ScanFieldPointerEvents.PointerView, !pointer.isKeyboardOnly { return pointer.bounds.size }
                        return view.subviews.compactMap(canvasSize).first
                    }
                    let geometry = owner.canvas.displayGeometry(canvasSize: try XCTUnwrap(canvasSize(host)))
                    for label in owner.fieldLabels {
                        XCTAssertNotNil(SpatialInstrumentStaticLayer.labelFontSize(label, plan: owner.fieldPlan, geometry: geometry))
                        let region = owner.fieldPlan.regions[label.regionIndex]
                        if region.label == "Fm" {
                            let cramped = MetricCanvasGeometry(size: .init(width: width, height: 700),
                                viewport: try .build(centerXMeters: Double(label.center.x), centerYMeters: Double(label.center.y),
                                    metersPerPoint: Double(min(region.bounds.width, region.bounds.height)) / 20))
                            XCTAssertEqual(SpatialInstrumentStaticLayer.labelFontSize(label, plan: owner.fieldPlan, geometry: cramped), 10,
                                "Fm must remain at the minimum font in a 20-point surface")
                        }
                    }
                    try capture(host, width: width, height: 1100, name: "runde-g-\(scene.name)-\(shrunk)-\(width)")
                }
            }
            owner.canvas.setPerformanceLocked(false)
            XCTAssertTrue(owner.showInactiveSceneLayers)
            let planIdentity = owner.fieldPlan.identity
            owner.showInactiveSceneLayers = false
            let filtered = SpatialInstrumentSelectionLayer(state: owner.canvas.presentation,
                geometry: owner.canvas.displayGeometry(canvasSize: .init(width: 900, height: 1100)), plan: owner.fieldPlan)
            XCTAssertNotNil(filtered.displayedLayerIDs, "Edit's visibility switch also hides inactive selection ink")
            owner.showInactiveSceneLayers = true
            XCTAssertEqual(owner.fieldPlan.identity, planIdentity)
        }
    }

    func testEditorLargeSelectionFiftyProfilesReusesProjectionAndPathsWideNarrow() throws {
        for width in [900, 360] {
            let fixture = try MonitorRootFixture(), owner = fixture.root.document
            defer { fixture.root.terminate {}; CanvasTimingProbe.current = nil; ViewEvaluationProbe.current = nil }
            let grid = MetricSquareGrid.CellSize.twoCentimeter.grid
            let cells = Set((2..<100).flatMap { ring -> [PolarMetricGridCell] in
                let step = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: Double(ring + 1) * grid.cellSizeMeters,
                                                                   radialHeightMeters: grid.cellSizeMeters)
                return (Int(ceil(90 / step))..<Int(floor(270 / step))).map { .init(ring: ring, angularIndex: $0) }
            }.prefix(3000))
            XCTAssertEqual(cells.count, 3000)
            owner.canvas.updateWorkspace { $0.requestGridChange(to: .twoCentimeter) }
            owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.polarCells = cells } }
            let selectedID = owner.canvas.workspace.selectedLayerID
            XCTAssertTrue(owner.canvas.selectLayers([selectedID], active: selectedID))
            XCTAssertEqual(owner.canvas.selection.cells.count, 3000)
            let display = SpatialActiveCellDisplayModel()
            // Each width has its own session and viewport.
            let host = NSHostingView(rootView: Harness(instrument: owner, cells: display))
            host.frame = .init(x: 0, y: 0, width: width, height: 1100); host.wantsLayer = true
            let window = PresentingTestWindow(hosting: host, size: .init(width: width, height: 1100))
            defer { window.tearDown() }
            let hosts = [host]
            func flush() {
                hosts.forEach { $0.layoutSubtreeIfNeeded(); $0.displayIfNeeded() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                hosts.forEach { $0.layoutSubtreeIfNeeded(); $0.displayIfNeeded() }
            }
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<90).map { _ in try .build(value: 100, fieldFlags: 0) })
            display.update(profile: raw, activeCells: [:]); flush(); flush()
            let session = UUID(), selection = owner.canvas.selection
            for locked in [false, true, false] {
                owner.canvas.setPerformanceLocked(locked)
                flush(); flush()
                let timing = CanvasTimingProbe(), probe = ViewEvaluationProbe()
                CanvasTimingProbe.current = timing; ViewEvaluationProbe.current = probe
                for sequence in 1...50 {
                    let frame = ProfileFrame(sessionID: session, sequence: UInt64(sequence), time: Double(sequence) / 25,
                        measurements: try FullScanProfileAdapter.measurements(from: raw),
                        geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
                    display.update(profileFrame: frame, activeCells: [:]); flush()
                }
                XCTAssertGreaterThan(probe.counts["canvas", default: 0], 40, "Positive control: the production live Canvas must receive profiles")
                XCTAssertLessThanOrEqual(timing.counts["field.projection", default: 0], 1)
                XCTAssertEqual(timing.counts["field.prepareSelection", default: 0], 0)
                XCTAssertEqual(probe.counts["field.selectionCell", default: 0], 0)
                XCTAssertEqual(probe.counts["field.activeBody", default: 0], 0)
                XCTAssertEqual(timing.counts["session.filterSelection", default: 0], 0)
                XCTAssertEqual(owner.canvas.selection, selection, "Perform freezes the editor selection")
                print("EDITOR-LAST selection=3000 locked=\(locked) counts=\(timing.counts) live=\(probe.counts["canvas", default: 0])")
                CanvasTimingProbe.current = nil; ViewEvaluationProbe.current = nil
            }
            // Changed selection and geometry must cross the retained layer boundary.
            let before = SpatialInstrumentSelectionLayer(state: owner.canvas.presentation,
                geometry: owner.canvas.displayGeometry(canvasSize: .init(width: 900, height: 1100)))
            owner.canvas.clearSelection()
            let after = SpatialInstrumentSelectionLayer(state: owner.canvas.presentation, geometry: before.geometry)
            XCTAssertFalse(before == after)
            let zoomed = SpatialInstrumentSelectionLayer(state: owner.canvas.presentation,
                geometry: owner.canvas.displayGeometry(canvasSize: .init(width: 360, height: 1100)))
            XCTAssertFalse(after == zoomed)
            XCTAssertTrue(owner.canvas.selectLayers([selectedID], active: selectedID))
        }
    }

    func testInputBacklogNoticeWideAndNarrowAndCheckedProjection() throws {
        XCTAssertNil(InputBacklogStatus.ready.message)
        XCTAssertEqual(InputBacklogStatus.recovered.message, "Input caught up · ready for new measurements.")
        let cell = try XCTUnwrap(PolarDeviceLattice(ring: 100, sector: 180))
        XCTAssertNil(SpatialActiveCellDisplayModel.tile(cell, grid: try .build(cellSizeMeters: 0.07)))
        XCTAssertNil(SpatialActiveCellDisplayModel.tile(cell, grid: try .build(cellSizeMeters: 1e100)))
        XCTAssertEqual(SpatialActiveCellDisplayModel.tile(cell, grid: .quarterMeter),
                       try LegacyLatticeMigration.project(cell, in: .quarterMeter))
        for width in [380, 900] {
            for (name, status) in [("overloaded", InputBacklogStatus.overloaded), ("recovered", .recovered)] {
                try render(InputBacklogNotice(status: status).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black), width: width, height: 40, name: "backlog-\(name)-\(width)")
            }
        }
    }
    private struct Harness: View {
        @ObservedObject var instrument: SpatialInstrumentRuntimeModel
        @ObservedObject var cells: SpatialActiveCellDisplayModel
        var body: some View {
            CartesianScanFieldView(editor: instrument.canvas, profile: cells.latestProfile,
                activeCellDisplay: cells, spatialInstrument: instrument, simulationBadge: AnyView(EmptyView()))
        }
    }
    private struct InspectorHarness: View {
        @ObservedObject var owner: SpatialInstrumentRuntimeModel
        let catalog: AudioCatalogModel
        let fixture: MonitorRootFixture
        let counter: InspectorEvaluationCounter
        var body: some View {
            StableSpatialLayerInspectorView(editor: owner.canvas,
                audioUnits: catalog,midiOutput: fixture.root.midi,spatialInstrument: owner,evaluationCounter: counter).equatable()
        }
    }
    func testPanAndZoomDoNotRebuildInspectorAndItsBindingKeepsCurrentViewport() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        let catalog = AudioCatalogModel(document: owner,source: EmptyCatalog()), counter = InspectorEvaluationCounter()
        let host = NSHostingView(rootView: InspectorHarness(owner: owner,catalog: catalog,fixture: fixture,counter: counter))
        host.frame = .init(x: 0,y: 0,width: 400,height: 900); host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let before = counter.count
        for _ in 0..<10 {
            _ = owner.canvas.panViewport(byScreenX: 2,screenY: 1)
            _ = owner.canvas.zoom(byFactor: 1.01,atScreenPoint: .init(x: 200,y: 300),canvasSize: .init(width: 400,height: 600))
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        XCTAssertGreaterThan(before,0); XCTAssertEqual(counter.count,before)
        let viewport = owner.canvas.viewport
        func inspector(in view: NSView) -> NSHostingView<InspectorHostedRoot>? {
            if let found = view as? NSHostingView<InspectorHostedRoot> { return found }
            return view.subviews.compactMap { inspector(in: $0) }.first
        }
        let nested = try XCTUnwrap(inspector(in: host))
        nested.rootView.inspector.editor.updateWorkspace { $0.updateSelectedLayer { $0.name = "Current binding" } }
        XCTAssertEqual(owner.canvas.workspace.selectedLayer.name,"Current binding")
        XCTAssertEqual(owner.canvas.viewport,viewport)
        var done = false; fixture.root.terminate { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }
    private func render<V: View>(_ view: V, width: Int, height: Int, name: String) throws {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme,.dark).preferredColorScheme(.dark)))
        defer {
            // Tear down subscriptions before the next size shares this session.
            host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = .init(x: 0,y: 0,width: width,height: height); host.wantsLayer = true
        try capture(host, width: width, height: height, name: name)
    }
    private func capture(_ host: NSView, width: Int, height: Int, name: String) throws {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: width,pixelsHigh: height,
            bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,bytesPerRow: 0,bitsPerPixel: 0))
        host.cacheDisplay(in: host.bounds,to: bitmap)
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png,properties: [:])).write(to: directory.appendingPathComponent(name+".png"))
    }
    func testMergedCellSelectionAndPlayingStatesWideNarrowFor90And361() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmonie 01 Ruhe und Spannung"))
        try owner.applyPresetDocument(try PresetDocumentReader.read(data).get().replacing(owner.document))
        let cells = SpatialActiveCellDisplayModel()
        let before = try PresetV5Codec.encode(.init(name: "View invariant",document: owner.document))
        let history = owner.undoMenuTitle
        owner.canvas.mergeZones = false
        XCTAssertEqual(try PresetV5Codec.encode(.init(name: "View invariant",document: owner.document)),before)
        XCTAssertEqual(owner.undoMenuTitle, history)
        for count in [90,361] {
            let hands = [(count/3-2)...(count/3+2),(2*count/3-2)...(2*count/3+2)]
            let raw = try B0ScanProfile.build(partialScanIndex: 0,measurements: (0..<count).map { index in
                try .build(value: hands.contains { $0.contains(index) } ? 90 : 200,fieldFlags: 0)
            })
            let geometry = try FullScanProfileAdapter.geometry(from: raw)
            let profile = ProfileFrame(sessionID: UUID(),sequence: 1,time: 0,
                measurements: try FullScanProfileAdapter.measurements(from: raw),geometry: geometry,rawProfile: raw)
            let room = SpatialRoomContour(geometry: .init(pointCount: count,angleResolutionDegrees: 180/Double(count-1),startAngleDegrees: -90,sourceIdentifier: profile.sourceIdentifier),
                nearestDistancesCentimeters: Array(repeating: 200,count: count),spreadCentimeters: Array(repeating: 14,count: count))
            var config = owner.document.detection; config.roomContour = .init(isEnabled: true); config.temporalSmoothing = .off
            owner.updateDetectionConfiguration(config)
            var detector = SpatialDetectionPipeline()
            let selection = detector.select(frame: profile,instrument: try InstrumentCompiler.compile(owner.document),contour: room)
            XCTAssertEqual(selection.objects.count,2)
            owner.noteDisplay(.init(profile: profile,contour: room,selection: selection))
            for state in ["merged","cells","selection-merged","selection-cells","playing-merged","playing-cells"] {
                owner.canvas.mergeZones = state.hasSuffix("merged")
                owner.canvas.clearSelection()
                let layer = owner.canvas.workspace.selectedLayer
                let cell = try XCTUnwrap(layer.polarCells.sorted {
                    $0.ring == $1.ring ? $0.angularIndex < $1.angularIndex : $0.ring < $1.ring
                }.first)
                if state.hasPrefix("selection") {
                    let center = SpatialFieldPlan.center(.init(cell: cell,grid: owner.canvas.workspace.grid))
                    let size = CGSize(width: 800,height: 700)
                    // The view resets its viewport from its real field height. Reset this
                    // test viewport for the selection canvas too, rather than projecting
                    // through a stale 800×700 assumption after the layout changes height.
                    XCTAssertTrue(owner.canvas.resetViewport(canvasSize: size))
                    let point = MetricCanvasGeometry(size: size,viewport: owner.canvas.viewport).screenPoint(for: .init(xMeters: center.x,yMeters: center.y))
                    _ = owner.canvas.selectCell(atScreenPoint: point,canvasSize: size)
                    XCTAssertEqual(owner.canvas.selectedPolarCells,[cell])
                }
                cells.update(profileFrame: profile,activeCells: state.hasPrefix("playing") ? [layer.id:cell] : [:])
                for width in [900,360] {
                    try render(Harness(instrument: owner,cells: cells),width: width,height: 1100,
                        name: "field-\(state)-\(count)-\(width)")
                }
            }
        }
        var done = false; fixture.root.terminate { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }

    func testMovePreviewAndCommittedCellsRenderWideAndNarrow() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        let cells = SpatialActiveCellDisplayModel(), size = CGSize(width: 900, height: 700)
        XCTAssertTrue(owner.canvas.resetViewport(canvasSize: size))
        let source = CGPoint(x: 450, y: 560)
        let geometry = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport)
        let painted = PolarMetricGridCell(point: try XCTUnwrap(geometry.metricPoint(forScreenPoint: source)), grid: owner.canvas.workspace.grid)
        owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.polarCells = [painted] } }
        XCTAssertTrue(owner.canvas.beginDrag(at: source, canvasSize: size))
        owner.canvas.endDrag(canvasSize: size)
        let selected = try XCTUnwrap(owner.canvas.selectedPolarCell)
        owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.polarCells = [selected] } }
        XCTAssertTrue(owner.canvas.beginDrag(at: source, canvasSize: size))
        XCTAssertTrue(owner.canvas.updateDrag(to: CGPoint(x: 450, y: 500), canvasSize: size))
        XCTAssertFalse(owner.canvas.movePreviewCells.isEmpty)
        for width in [900, 360] { try render(Harness(instrument: owner, cells: cells), width: width, height: 900, name: "move-preview-\(width)") }
        owner.canvas.endDrag(canvasSize: size)
        XCTAssertTrue(owner.canvas.movePreviewCells.isEmpty)
        for width in [900, 360] { try render(Harness(instrument: owner, cells: cells), width: width, height: 900, name: "move-result-\(width)") }
        var done = false; fixture.root.terminate { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }

    func testOwner0910BBoundaryNoticeRendersWideAndNarrow() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        let cells = SpatialActiveCellDisplayModel()
        let source = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let outer = PolarMetricGridCell(ring: 7, angularIndex: 8)
        let layer = SpatialInstrumentLayer(name: "Boundary proof", color: .orange, polarCells: [source, outer])
        owner.canvas.replaceWorkspace(SpatialInstrumentWorkspace(layers: [layer]))
        // Square geometry gives the outward gesture the same radial direction
        // used by the interaction regression, rather than changing bearing
        // with a non-square snapshot frame.
        let size = CGSize(width: 800, height: 800)
        let geometry = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport)
        let segment = PolarMetricCellSegment(cell: source, grid: owner.canvas.workspace.grid)
        let start = geometry.screenPoint(for: .init(
            xMeters: sin(segment.midpoint.bearingDegrees * .pi / 180) * segment.midpoint.radiusMeters,
            yMeters: cos(segment.midpoint.bearingDegrees * .pi / 180) * segment.midpoint.radiusMeters
        ))
        XCTAssertTrue(owner.canvas.beginDrag(at: start, canvasSize: size))
        owner.canvas.endDrag(canvasSize: size)
        XCTAssertEqual(owner.canvas.selectedPolarCells, [source])
        // First take the ordinary cell-only path. This mirrors the owner
        // report: a cell remains movable after inspecting its layer.
        let outward = CGPoint(x: start.x, y: start.y - 100)
        XCTAssertTrue(owner.canvas.beginDrag(at: start, canvasSize: size))
        XCTAssertTrue(owner.canvas.updateDrag(to: outward, canvasSize: size))
        owner.canvas.endDrag(canvasSize: size)
        let moved = try XCTUnwrap(owner.canvas.selectedPolarCell)
        let movedSegment = PolarMetricCellSegment(cell: moved, grid: owner.canvas.workspace.grid)
        let movedStart = geometry.screenPoint(for: .init(
            xMeters: sin(movedSegment.midpoint.bearingDegrees * .pi / 180) * movedSegment.midpoint.radiusMeters,
            yMeters: cos(movedSegment.midpoint.bearingDegrees * .pi / 180) * movedSegment.midpoint.radiusMeters
        ))
        XCTAssertTrue(owner.canvas.beginDrag(at: movedStart, canvasSize: size))
        XCTAssertTrue(owner.canvas.updateDrag(to: CGPoint(x: movedStart.x, y: movedStart.y - 100), canvasSize: size))
        XCTAssertTrue(owner.canvas.moveHitBoundary)
        for width in [900, 360] {
            try render(Harness(instrument: owner, cells: cells), width: width, height: 900,
                       name: "owner-0910b-field-boundary-\(width)")
        }
        var done = false; fixture.root.terminate { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }
    func testChannelStripAtZeroAndPlusSixAt108Points() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        let catalog = AudioCatalogModel(document: owner,source: EmptyCatalog())
        for db in [0.0,6] {
            var channel = owner.document.channel; channel.levelDecibels = db; owner.updateChannel(channel)
            // Render the product's strip alongside its inspector, then keep
            // the actual 108-pt strip crop as the review artifact.
            let view = ChannelStripView(spatialInstrument: owner,audioUnits: catalog,host: fixture.root.audio,
                midiOutput: fixture.root.midi,audioDevices: .init(host: fixture.root.audio))
            let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme,.dark).preferredColorScheme(.dark)))
        defer {
            // Tear down subscriptions before the next size shares this session.
            host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = .init(x: 0,y: 0,width: ChannelStripDesignTokens.inspectorWidth + ChannelStripDesignTokens.sidePanelSpacing + ChannelStripDesignTokens.stripWidth,height: 900)
            host.wantsLayer = true; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 108,pixelsHigh: 900,
                bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,
                bitmapFormat: .alphaFirst,bytesPerRow: 0,bitsPerPixel: 0))
            host.cacheDisplay(in: .init(x: host.bounds.maxX-108,y: 0,width: 108,height: 900),to: bitmap)
            let directory = TestImageDirectory.make(); try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png,properties: [:])).write(to: directory.appendingPathComponent("strip-\(Int(db))dB-108.png"))
        }
        var done = false; fixture.root.terminate { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }
    func testRuntimeSceneFieldWideAndNarrow() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        layout.view.presets.load("Harmony 30 Mode Wheel")
        let owner = fixture.root.document, cells = SpatialActiveCellDisplayModel()
        let identity = owner.fieldPlan.identity
        let hosts = [900, 360].map { width in
            let host = NSHostingView(rootView: Harness(instrument: owner, cells: cells).environment(\.colorScheme, .dark).preferredColorScheme(.dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = .init(x: 0, y: 0, width: width, height: 1100); host.wantsLayer = true
            host.layoutSubtreeIfNeeded()
            return host
        }
        for index in [1, 0] {
            let geometry = owner.canvas.displayGeometry(canvasSize: .init(width: 900, height: 1100))
            let before = SpatialInstrumentStaticLayer(plan: owner.fieldPlan, labels: owner.fieldLabels,
                selectedLayerID: owner.canvas.workspace.selectedLayerID, mergeZones: true, geometry: geometry)
            owner.selectScene(owner.document.scenes[index].id)
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            let after = SpatialInstrumentStaticLayer(plan: owner.fieldPlan, labels: owner.fieldLabels,
                selectedLayerID: owner.canvas.workspace.selectedLayerID, mergeZones: true, geometry: geometry)
            XCTAssertFalse(before == after, "Audibility invalidates the retained static surface")
            for (width, host) in zip([900, 360], hosts) {
                try capture(host, width: width, height: 1100, name: "runtime-scene-\(index)-\(width)")
            }
            let audible = SpatialLayerAudibility.audibleIDs(owner.canvas.workspace.layers.map { ($0.id, $0.isActive, $0.isSoloed) })
            for layer in owner.fieldPlan.layers {
                XCTAssertEqual(owner.fieldPlan.audibilityOpacity[layer.id], audible.contains(layer.id) ? 1 : 0.3, layer.name)
            }
            XCTAssertEqual(owner.fieldPlan.identity, identity)
        }
    }
    func testMutedAndSoloStatesRemainVisibleWideNarrowInBothZoneModes() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmonie 01 Ruhe und Spannung"))
        try owner.applyPresetDocument(try PresetDocumentReader.read(data).get().replacing(owner.document))
        let cells = SpatialActiveCellDisplayModel(), selected = owner.canvas.workspace.selectedLayerID
        let other = try XCTUnwrap(owner.canvas.workspace.layers.first { $0.id != selected }?.id)
        for state in ["muted","other-solo","own-solo","unmuted"] {
            owner.canvas.updateWorkspace { workspace in
                for layer in workspace.layers { workspace.updateLayer(layer.id) { $0.isActive = true; $0.isSoloed = false } }
                workspace.updateLayer(selected) { $0.isActive = state != "muted"; $0.isSoloed = state == "own-solo" }
                workspace.updateLayer(other) { $0.isSoloed = state == "other-solo" }
            }
            XCTAssertEqual(owner.fieldPlan.audibilityOpacity[selected],state == "muted" || state == "other-solo" ? 0.3 : 1)
            let bytes = try PresetV5Codec.encode(.init(name: "Audibility",document: owner.document))
            for merged in [true,false] {
                owner.canvas.mergeZones = merged
                for width in [900,360] {
                    try render(Harness(instrument: owner,cells: cells),width: width,height: 1100,
                               name: "field-audibility-\(state)-\(merged ? "merged" : "cells")-\(width)")
                }
                XCTAssertEqual(try PresetV5Codec.encode(.init(name: "Audibility",document: owner.document)),bytes)
            }
        }
        var done = false; fixture.root.terminate { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }
    func testThirteenLayerPlanIsStableDuringGesturesAndMeasuresSeparatePreparationPhases() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        let source = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmonie 10 Tritonus-Bruecke"))
        let preset = try PresetDocumentReader.read(source).get().replacing(owner.document)
        try owner.applyPresetDocument(preset)
        let allCells = Set(owner.canvas.workspace.layers.flatMap { $0.polarCells })
        owner.canvas.updateWorkspace { workspace in
            while workspace.layers.count < 13 { _ = workspace.addLayer() }
            for layer in workspace.layers {
                workspace.updateLayer(layer.id) {
                    $0.polarCells = allCells
                    $0.routings = [.init(target: .midiNote(channel: 0),program: .chord(notes: [60,64,67],velocity: 100,transition: .legato))]
                }
            }
        }
        let layer = owner.canvas.workspace.selectedLayer
        XCTAssertEqual(owner.canvas.workspace.layers.count,13)
        XCTAssertGreaterThan(allCells.count,100)
        let raw = try B0ScanProfile.build(partialScanIndex: 0,measurements: (0..<90).map {
            try .build(value: abs($0-30)<3 || abs($0-60)<3 ? 100 : 200,fieldFlags: 0)
        })
        let frame = ProfileFrame(sessionID: UUID(),sequence: 1,time: 0,
            measurements: try FullScanProfileAdapter.measurements(from: raw),geometry: try FullScanProfileAdapter.geometry(from: raw),rawProfile: raw)
        let room = SpatialRoomContour(geometry: .init(pointCount: 90,angleResolutionDegrees: 180.0/89,startAngleDegrees: -90,sourceIdentifier: frame.sourceIdentifier),
            nearestDistancesCentimeters: Array(repeating: 200,count: 90),spreadCentimeters: Array(repeating: 0,count: 90))
        var config = owner.document.detection; config.roomContour = .init(isEnabled: true); config.temporalSmoothing = .off
        owner.updateDetectionConfiguration(config)
        var detector = SpatialDetectionPipeline()
        let evidence = detector.select(frame: frame,instrument: try InstrumentCompiler.compile(owner.document),contour: room)
        XCTAssertEqual(evidence.objects.count,2)
        let plan = owner.fieldPlan.identity
        let size = CGSize(width: 900,height: 700)
        var prepTimes: [Double] = [], transformedTimes: [Double] = [], hitTimes: [Double] = [], labelTimes: [Double] = []
        var stateTimes: [Double] = [], overlayTimes: [Double] = []
        for _ in 0..<30 {
            var start = DispatchTime.now().uptimeNanoseconds
            let rebuilt = SpatialFieldPlan(workspace: owner.canvas.workspace)
            prepTimes.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
            start = DispatchTime.now().uptimeNanoseconds
            _ = owner.canvas.panViewport(byScreenX: 1,screenY: 1)
            _ = owner.canvas.zoom(byFactor: 1.001,atScreenPoint: .init(x: 450,y: 350),canvasSize: size)
            stateTimes.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
            start = DispatchTime.now().uptimeNanoseconds
            let geometry = MetricCanvasGeometry(size: size,viewport: owner.canvas.viewport)
            let origin = geometry.screenPoint(for: .init(xMeters: 0,yMeters: 0)), scale = 1/owner.canvas.viewport.metersPerPoint
            var transform = CGAffineTransform(a: scale,b: 0,c: 0,d: -scale,tx: origin.x,ty: origin.y)
            for region in owner.fieldPlan.regions { _ = region.fill.copy(using: &transform); _ = region.outline.copy(using: &transform) }
            transformedTimes.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
            XCTAssertEqual(owner.fieldPlan.identity,plan)
            start = DispatchTime.now().uptimeNanoseconds
            _ = geometry.boundedMetricPoint(forScreenPoint: .init(x: 450,y: 350))
            hitTimes.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
            start = DispatchTime.now().uptimeNanoseconds
            _ = rebuilt.labels(selectedLayerID: layer.id)
            labelTimes.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
            start = DispatchTime.now().uptimeNanoseconds
            let overlay = ScanFieldPresentation(contour: room,matches: true,configuration: config.roomContour,
                showRawScan: false,objects: evidence.objects)
            let contourPath = CGMutablePath()
            for point in overlay.contour.compactMap({ $0 }) { contourPath.addLine(to: geometry.screenPoint(for: point)) }
            for object in overlay.objects {
                let center = geometry.screenPoint(for: object.center), diameter = object.diameterMeters/owner.canvas.viewport.metersPerPoint
                contourPath.addEllipse(in: .init(x: center.x-diameter/2,y: center.y-diameter/2,width: diameter,height: diameter))
            }
            overlayTimes.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
        }
        print("Field 13 layers preparation ms=\(prepTimes.reduce(0,+)/30) transformed paths ms=\(transformedTimes.reduce(0,+)/30) state ms=\(stateTimes.reduce(0,+)/30) contour+object projection ms=\(overlayTimes.reduce(0,+)/30) hit geometry ms=\(hitTimes.reduce(0,+)/30) label-plan ms=\(labelTimes.reduce(0,+)/30) (CPU phases; SwiftUI layout/display measured by FieldPanRenderingTests; GPU excluded)")
        var done = false; fixture.root.terminate { done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }
}


extension FieldRenderingContractTests {
    func testDisplayIdentityUsesSessionAndSequenceAndKeepsCommandCellChanges() throws {
        let cells = SpatialActiveCellDisplayModel(), session = UUID()
        var publications = 0
        let token = cells.objectWillChange.sink { publications += 1 }
        defer { token.cancel() }
        func frame(_ sequence: UInt64, sessionID: UUID? = nil, raw: UInt16 = 100) throws -> ProfileFrame {
            .init(sessionID: sessionID ?? session, sequence: sequence, time: Double(sequence), measurements: [
                try XCTUnwrap(DeviceTickMeasurement(order: 0, ticks: .point(180)!, rawCentimeters: raw))
            ])
        }
        let first = try frame(1)
        cells.update(profileFrame: first, activeCells: [:])
        XCTAssertEqual(publications, 1)
        // The acquisition contract makes identity immutable; poison a duplicate
        // payload to prove presentation does not scan/compare its large arrays.
        for _ in 0..<100 { cells.update(profileFrame: try frame(1, raw: 200), activeCells: [:]) }
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(cells.frame.sourceFrame, first)
        cells.update(profileFrame: try frame(2), activeCells: [:])
        cells.update(profileFrame: try frame(2, sessionID: UUID()), activeCells: [:])
        XCTAssertEqual(publications, 3, "Equal payload in a new sequence/session is fresh input")
        let tile = try XCTUnwrap(SpatialActiveCellDisplayModel.tile(.init(tick: 180, rawCentimeters: 100)!, grid: .quarterMeter))
        let profile = cells.frame.sourceFrame, layer = UUID()
        cells.update(profileFrame: profile, activeCells: [layer: tile])
        cells.update(profileFrame: profile, activeCells: [:])
        XCTAssertEqual(publications, 5, "A same-profile Stop/PANIC cell transition is retained")
        cells.update(profileFrame: nil, activeCells: [:])
        cells.update(profileFrame: nil, activeCells: [:])
        XCTAssertEqual(publications, 6); XCTAssertNil(cells.frame.sourceFrame)
    }
}

extension FieldRenderingContractTests {
    func testFieldLabelIdentitySurvivesOcclusionWithoutRebuildingUnchangedText() throws {
        let left = PolarMetricGridCell(ring: 3, angularIndex: 9)
        let right = PolarMetricGridCell(ring: 3, angularIndex: 10)
        func layer(_ name: String, cells: Set<PolarMetricGridCell>, notes: [Int]) -> SpatialInstrumentLayer {
            .init(name: name, color: .blue, polarCells: cells,
                  routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: notes, velocity: 100, transition: .legato))])
        }
        let a = layer("C", cells: [left, right], notes: [60, 64, 67])
        let b = layer("Cm", cells: [left], notes: [60, 63, 67])
        let c = layer("G", cells: [.init(ring: 3, angularIndex: 13)], notes: [67, 71, 74])
        let plan = SpatialFieldPlan(workspace: .init(layers: [a, b, c]))
        let viewport = try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 1, metersPerPoint: 0.005)
        let geometry = MetricCanvasGeometry(size: .init(width: 900, height: 700), viewport: viewport)
        @MainActor func view(_ selected: UUID) -> some View {
            SpatialInstrumentStaticLayer(plan: plan, labels: plan.labels(selectedLayerID: selected),
                selectedLayerID: selected, mergeZones: true, geometry: geometry)
                .equatable().preferredColorScheme(.dark)
        }
        let host = NSHostingView(rootView: view(a.id))
        host.frame = .init(x: 0, y: 0, width: 900, height: 700)
        @MainActor func flush() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        flush()
        XCTAssertEqual(plan.labels(selectedLayerID: a.id).count, 2)
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        host.rootView = view(b.id); flush()
        XCTAssertEqual(plan.labels(selectedLayerID: b.id).count, 3)
        XCTAssertEqual(probe.counts["field.labelText", default: 0], 1,
                       "Only the newly exposed Cm label needs text; the existing G must retain its region identity")
        probe.reset()
        host.rootView = view(a.id); flush()
        XCTAssertEqual(probe.counts["field.labelText", default: 0], 0,
                       "Hiding Cm must preserve both existing labels, even though array offsets change")
    }
}
