import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PlanariumApplication
@testable import PlanariumDomain
@testable import PlanariumPresets
import PlanariumRuntime
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class PresetFitTests: XCTestCase {
    private let size = CGSize(width: 800, height: 800)

    private func point(_ cell: PolarMetricGridCell, state: MetricCanvasInteractionState) -> CGPoint {
        let segment = PolarMetricCellSegment(cell: cell, grid: state.workspace.grid)
        return MetricCanvasGeometry(size: size, viewport: state.viewport).screenPoint(for:
            segment.point(radiusMeters: segment.midpoint.radiusMeters, bearingDegrees: segment.midpoint.bearingDegrees))
    }

    private func room(count: Int = 361, wall: UInt16? = 110) -> SpatialRoomContour {
        .init(geometry: .init(pointCount: count, angleResolutionDegrees: 180 / Double(count - 1), startAngleDegrees: -90, sourceIdentifier: "offline"),
            nearestDistancesCentimeters: Array(repeating: wall, count: count), spreadCentimeters: [])
    }

    func testFitButtonUsesAllLayersOneDocumentUndoAndLeavesScenesOutputsAndSavedOriginalUntouched() throws {
        for count in [90, 361] {
            let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            let name = "Harmony 29 Picardy Switch", originalData = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: name))
            try owner.applyPresetDocument(try PresetDocumentReader.read(originalData).get().replacing(owner.document))
            let controls = RoomFitControls(instrument: owner)
            XCTAssertFalse(owner.canFitToRoom)
            let noRoom = owner.document
            controls.fit(); XCTAssertEqual(owner.document, noRoom)
            owner.noteDisplay(.init(contour: room(count: count), selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:])))
            XCTAssertTrue(owner.canFitToRoom); XCTAssertEqual(owner.roomFitMarginCentimeters, 10)
            let before = owner.document, beforeCanvas = owner.canvas.workspace
            let expected = SpatialRoomFit.applying(to: beforeCanvas, contour: room(count: count))
            XCTAssertEqual(expected.factor, 0.5, accuracy: 1e-12)
            controls.fit()
            let after = owner.document
            XCTAssertTrue(owner.roomFitNotice?.contains("fitted to room shape") == true)
            XCTAssertTrue(owner.roomFitNotice?.contains("cells merged at 1 cm resolution") == true)
            XCTAssertNotEqual(after.spatial, before.spatial)
            XCTAssertEqual(owner.undoMenuTitle, "Undo: Fit to room")
            XCTAssertEqual(after.scenes, before.scenes)
            XCTAssertEqual(after.currentSceneID, before.currentSceneID)
            XCTAssertEqual(after.channels, before.channels)
            XCTAssertEqual(after.midiTarget, before.midiTarget)
            XCTAssertEqual(after.spatial.layers.map(\.id), before.spatial.layers.map(\.id))
            XCTAssertEqual(after.spatial.layers.map(\.routings), before.spatial.layers.map(\.routings))
            XCTAssertEqual(after.detection, before.detection)
            XCTAssertEqual(FactoryPresetLibrary.standard.data(named: name), originalData)
            XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, before.spatial)
            XCTAssertEqual(owner.canvas.workspace, beforeCanvas)
            var restored = owner.document; restored.revision = before.revision
            XCTAssertEqual(restored, before, "All document bits except the advancing revision are restored")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(restored), try encoder.encode(before))
            XCTAssertTrue(owner.redo()); XCTAssertEqual(owner.document.spatial, after.spatial)
            restored = owner.document; restored.revision = after.revision
            XCTAssertEqual(restored, after)
            XCTAssertEqual(try encoder.encode(restored), try encoder.encode(after))
            XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, before.spatial, "One undo restores the entire preset")
            XCTAssertEqual(graph.starts, 0)
        }
    }

    func testFitButtonAlreadyFitsMissingRaysMarginChangesAndPerformanceLock() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        owner.canvas.updateWorkspace { $0 = .init(grid: .quarterMeter, layers: [
            .init(name: "Zone", color: .orange, polarCells: [.init(ring: 3, angularIndex: 16)])]) }
        let controls = RoomFitControls(instrument: owner)
        owner.noteDisplay(.init(contour: room(wall: nil), selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:])))
        let before = owner.document
        controls.fit(); XCTAssertEqual(owner.document, before)
        XCTAssertEqual(owner.roomFitNotice, "Preset already fits the room")
        owner.noteDisplay(.init(contour: room(wall: 100), selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:])))
        owner.setRoomFitMargin(centimeters: 0)
        controls.fit(); XCTAssertEqual(owner.document, before)
        owner.canvas.setPerformanceLocked(true)
        XCTAssertTrue(owner.canFitToRoom)
        controls.fit(); XCTAssertEqual(owner.document, before)
        owner.setRoomFitMargin(centimeters: 50)
        controls.fit(); XCTAssertNotEqual(owner.document.spatial, before.spatial)
        XCTAssertTrue(owner.canvas.isPerformanceLocked)
        XCTAssertFalse(owner.undo())
        owner.canvas.setPerformanceLocked(false)
        XCTAssertEqual(owner.roomFitMarginCentimeters, 50)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, before.spatial)
        XCTAssertEqual(owner.roomFitMarginCentimeters, 50)
    }

    func testFitLeavesSavedPresetByteIdenticalAndDirtyUntilOwnerSavesUnderNewName() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let store = PresetFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("FitOriginal-\(UUID())"))
        let original = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmony 29 Picardy Switch"))
        try store.save(original, as: "Original")
        let library = PresetControlModel(store: store, documentOwner: owner)
        XCTAssertNotNil(library.load("Original", decision: .discard))
        XCTAssertFalse(library.isDirty)
        owner.noteDisplay(.init(contour: room(), selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:])))
        RoomFitControls(instrument: owner).fit()
        XCTAssertTrue(library.isDirty)
        XCTAssertEqual(try store.load("Original"), original)
        XCTAssertEqual(try store.list(), ["Original"], "No automatic new file is created")
        XCTAssertTrue(owner.undo()); XCTAssertFalse(library.isDirty)
        XCTAssertEqual(try store.load("Original"), original)
        XCTAssertTrue(owner.redo()); XCTAssertTrue(library.isDirty)
        XCTAssertEqual(try store.load("Original"), original)
    }

    func testRoomEvidenceMarginAndFitStatusPublishOnlyToFitUIAndNotToInspectorOwner() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        var ownerChanges = 0, fitChanges = 0
        let ownerObservation = owner.objectWillChange.sink { ownerChanges += 1 }
        let fitObservation = owner.roomFit.objectWillChange.sink { fitChanges += 1 }
        let frame = DisplayFrame(contour: room(), selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]))
        owner.noteDisplay(frame)
        XCTAssertEqual(fitChanges, 1); XCTAssertTrue(owner.roomFit.hasContour)
        for _ in 0..<100 { owner.noteDisplay(frame) }
        XCTAssertEqual(fitChanges, 1)
        owner.setRoomFitMargin(centimeters: 20)
        XCTAssertEqual(fitChanges, 2)
        RoomFitControls(instrument: owner).fit()
        XCTAssertEqual(fitChanges, 3)
        XCTAssertEqual(owner.roomFitNotice, "Preset already fits the room")
        XCTAssertEqual(ownerChanges, 0, "No document owner publication for session UI or repeated room evidence")
        withExtendedLifetime([ownerObservation, fitObservation]) {}
    }

    func testResidualWarningsMarkOuterEdgeAndNameThinLayersWithoutBlockingFit() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let cell = PolarMetricGridCell(ring: 100, angularIndex: 256)
        let value = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 64, velocity: 90))
        _ = owner.canvas.confirmGridChange(to: .oneCentimeter)
        owner.canvas.updateWorkspace { $0 = .init(grid: .oneCentimeter, layers: [
            .init(name: "Thin lead", color: .orange, polarCells: [cell],
                routings: [.init(target: .midiNote(channel: 0), program: .constant(0.5))], polarCellOverrides: [cell: [value]])]) }
        XCTAssertFalse(owner.document.spatial.layers[0].cells.isEmpty)
        owner.noteDisplay(.init(contour: room(wall: 1), selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:])))
        RoomFitControls(instrument: owner).fit()
        XCTAssertEqual(owner.roomFitWarnings.narrowLayerNames, ["Thin lead"])
        XCTAssertFalse(owner.roomFitWarnings.outsideCells.isEmpty)
        XCTAssertTrue(owner.roomFitWarnings.messages.contains { $0.contains("beyond") })
        XCTAssertTrue(owner.canvas.workspace.selectedLayer.polarCellOverrides.values.allSatisfy { $0 == [value] })
        XCTAssertFalse(owner.document.spatial.layers[0].cells.isEmpty)
        XCTAssertFalse(owner.document.spatial.layers[0].cellOverrides.isEmpty)
        XCTAssertTrue(owner.canUndo)
    }

    func testFitControlsAndFieldDisabledEnabledAndResidualWarningsWideAndNarrowOffline() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let display = SpatialActiveCellDisplayModel(), directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        owner.canvas.updateWorkspace { $0 = .init(grid: .quarterMeter, layers: [
            .init(name: "Em", color: .orange, polarCells: [.init(ring: 5, angularIndex: 14), .init(ring: 6, angularIndex: 14)],
                routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [52, 55, 59], velocity: 90, transition: .retrigger))]),
            .init(name: "G", color: .blue, polarCells: [.init(ring: 7, angularIndex: 34)],
                routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [55, 59, 62], velocity: 90, transition: .retrigger))])]) }
        XCTAssertEqual(owner.canvas.workspace.layers.flatMap(\.polarCells).count, 3)
        for phase in ["disabled", "enabled", "fitted-warning"] {
            if phase == "enabled" {
                owner.noteDisplay(.init(contour: room(wall: 18), selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:])))
                var detection = owner.document.detection; detection.roomContour.isEnabled = true
                owner.updateDetectionConfiguration(detection)
                XCTAssertTrue(owner.canFitToRoom)
            } else if phase == "fitted-warning" {
                RoomFitControls(instrument: owner).fit()
                XCTAssertFalse(owner.roomFitWarnings.outsideCells.isEmpty)
                XCTAssertFalse(owner.roomFitWarnings.narrowLayerNames.isEmpty)
            } else { XCTAssertFalse(owner.canFitToRoom) }
            for width in [1120, 420] {
                let view = CartesianScanFieldView(editor: owner.canvas,
                    profile: nil, activeCellDisplay: display, spatialInstrument: owner, simulationBadge: AnyView(Text("Offline")), detectionInitiallyExpanded: true)
                let host = NSHostingView(rootView: view.preferredColorScheme(.dark).padding(10).background(StageTheme.workspace))
                host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
                host.frame = .init(x: 0, y: 0, width: width, height: width == 420 ? 1300 : 1000)
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.08)); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("fit-\(phase)-\(width).png"))
            }
        }
        XCTAssertEqual(graph.starts, 0)
    }

    func testPartADragReproductionFactory29Factory30AndTwoMeterZone() throws {
        for name in ["Harmony 29 Picardy Switch", "Harmony 30 Mode Wheel", "Two meter zone"] {
            let fixture = try MonitorRootFixture(), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            if name == "Two meter zone" {
                owner.canvas.updateWorkspace { $0 = .init(grid: .quarterMeter, layers: [
                    .init(name: "Edge", color: .orange, polarCells: [.init(ring: 7, angularIndex: 32)]),
                    .init(name: "Inside", color: .blue, polarCells: [.init(ring: 3, angularIndex: 16)])]) }
            } else {
                let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: name))
                var coarseReproduction = try PresetDocumentReader.read(data).get().replacing(owner.document)
                coarseReproduction.editorGrid = .quarterMeter
                try owner.applyPresetDocument(coarseReproduction)
            }
            var initial = owner.canvas.presentation
            _ = initial.resetViewport(canvasSize: size)
            let cell = try XCTUnwrap(initial.workspace.selectedLayer.polarCells.sorted { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }.last)
            let start = point(cell, state: initial)
            for scope in ["selected", "empty", "multiple", "multiple-empty"] {
                var state = initial
                if !scope.contains("empty") { XCTAssertTrue(state.selectCell(atScreenPoint: start, canvasSize: size)) }
                if scope.hasPrefix("multiple") && !scope.contains("empty") {
                    _ = state.selectLayers(Set(state.workspace.layers.map(\.id)))
                }
                let before = state.workspace
                let bounds = try XCTUnwrap(PolarCellTransform.bounds(cells: state.selectedPolarCells.isEmpty ? [cell] : state.selectedPolarCells, grid: state.workspace.grid))
                XCTAssertTrue(state.beginDrag(at: start, canvasSize: size))
                let end = CGPoint(x: start.x * 2 - size.width / 2, y: start.y - 2000)
                XCTAssertTrue(state.updateDrag(to: end, canvasSize: size))
                let preview = state.movePreviewCells.count, boundary = state.moveHitBoundary
                state.endDrag(canvasSize: size)
                print("PART A \(name) · \(scope): changed=\(state.workspace != before) boundary=\(boundary) preview=\(preview) selected=\(state.selectedCells.count) radius=\(bounds.innerRadiusMeters)...\(bounds.outerRadiusMeters) bearing=\(bounds.startBearingDegrees)...\(bounds.endBearingDegrees)")
                if scope.contains("empty") {
                    XCTAssertEqual(state.workspace, before)
                    XCTAssertFalse(boundary)
                    XCTAssertEqual(preview, 0, "Unselected drag selects; it cannot move a zone")
                } else {
                    XCTAssertTrue(boundary)
                    if scope == "multiple" || name == "Two meter zone" { XCTAssertEqual(state.workspace, before) }
                    else { XCTAssertNotEqual(state.workspace, before) }
                }
            }
        }
    }
}

extension PresetFitTests {
    private func shapeRoom(_ shape: String, count: Int = 361) -> SpatialRoomContour {
        let distances: [UInt16?] = (0..<count).map { i in
            let angle = -90 + Double(i) * 180 / Double(count - 1)
            let radians = angle * .pi / 180
            if shape == "rectangle" {
                return UInt16((100 * min(1 / max(1e-9, abs(sin(radians))), 3 / max(1e-9, cos(radians)))).rounded(.down))
            }
            if (24...30).contains(angle) { return nil } // doorway/no echo
            if abs(angle + 20) < 0.3 { return 60 } // Keller's near spike
            return UInt16((100 * (angle < -35 ? 1.2 : 3)).rounded())
        }
        return .init(geometry: .init(pointCount: count, angleResolutionDegrees: 180 / Double(count - 1), startAngleDegrees: -90, sourceIdentifier: "synthetic-keller"), nearestDistancesCentimeters: distances, spreadCentimeters: [])
    }

    func testNewInstrumentUsesFiveCentimetersAndSavedQuarterMeterGridSurvives() throws {
        let fixture = try MonitorRootFixture(usesProductionGrid: true)
        defer { fixture.root.terminate {} }
        XCTAssertEqual(fixture.root.document.document.editorGrid.cellSizeMeters, 0.05)
        XCTAssertEqual(fixture.root.document.canvas.workspace.grid.cellSizeMeters, 0.05)
        var saved = fixture.root.document.document
        saved.editorGrid = .quarterMeter
        let bytes = try PresetV6Codec.encode(.init(name: "Owner saved", document: saved))
        let loaded = try PresetDocumentReader.read(bytes).get().replacing(saved)
        try fixture.root.document.applyPresetDocument(loaded)
        XCTAssertEqual(fixture.root.document.document.editorGrid.cellSizeMeters, 0.25)
        XCTAssertEqual(fixture.root.document.canvas.workspace.grid.cellSizeMeters, 0.25)
    }

    func testRoomShapeKellerAndRectangleRespectWallsPreserveMusicAndFillDeeperDirections() throws {
        for shape in ["keller", "rectangle"] {
            for count in [90, 361] {
                let source = try PresetV6Codec.decode(XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Factory 01 MIDI Scale"))).document
                let contour = shapeRoom(shape, count: count)
                let fit = try SpatialRoomFit.applying(to: source, contour: contour)
                XCTAssertGreaterThan(fit.maximumFactor, fit.minimumFactor + 0.2)
                XCTAssertEqual(fit.document.editorGrid, source.editorGrid)
                XCTAssertEqual(fit.document.scenes, source.scenes)
                XCTAssertEqual(fit.document.channels, source.channels)
                for (before, after) in zip(source.spatial.layers, fit.document.spatial.layers) {
                    XCTAssertEqual(before.id, after.id)
                    XCTAssertEqual(before.routings, after.routings)
                    XCTAssertEqual(before.commonNotes, after.commonNotes)
                    XCTAssertEqual(before.midiTarget, after.midiTarget)
                    XCTAssertFalse(after.cells.isEmpty)
                    XCTAssertEqual(Set(before.cells.map(\.sector)), Set(after.cells.map(\.sector)))
                    for cell in after.cells {
                        let index = Int((Double(cell.sector) * Double(count - 1) / 360).rounded())
                        if let captured = contour.nearestDistancesCentimeters[index] {
                            // Independent synthetic-room oracle: only the
                            // single 60-cm spike belongs to the 3-m wall.
                            let wall = shape == "keller" && captured == 60 ? 300 : Int(captured)
                            if count == 361 { XCTAssertLessThanOrEqual(cell.ring + 1, max(2, wall - 10)) }
                        }
                    }
                }
            }
        }
    }

    func testRoomShapeSmoothsSingleSpikeAndBridgesDoorWithoutOvershooting() throws {
        let cells = Set((0...360).map { PolarDeviceLattice(ring: 100, sector: $0)! })
        let layer = SpatialDocumentLayer(id: UUID(), name: "Ring", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: cells, routings: [], cellOverrides: [:])
        var source = try FactoryPresetDocument.empty()
        source.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        let contour = shapeRoom("keller")
        let fit = try SpatialRoomFit.applying(to: source, contour: contour)
        let rings = Dictionary(grouping: fit.document.spatial.layers[0].cells, by: \.sector).mapValues { $0.map(\.ring).max()! }
        XCTAssertEqual(SpatialRoomFit.fittingContour(contour).nearestDistancesCentimeters[140], 300)
        XCTAssertGreaterThan(rings[140]!, 150, "A sub-hand-width dip must not empty the centre")
        XCTAssertLessThan(abs(rings[139]! - rings[140]!), 4, "Without smoothing the isolated spike jumps by >100 cm")
        for tick in 228...240 { XCTAssertLessThanOrEqual(abs(rings[tick]! - rings[tick - 1]!), 3, "Door gap must not create a spike") }
        XCTAssertGreaterThan(rings[300]!, rings[20]! + 50)
        XCTAssertLessThanOrEqual(Set(rings.values).count, 8, "Use circular bands, not a per-ray sawtooth")
        var broad = contour.nearestDistancesCentimeters
        for index in 130...150 { broad[index] = 60 }
        let wide = SpatialRoomContour(geometry: contour.geometry, nearestDistancesCentimeters: broad, spreadCentimeters: [])
        XCTAssertEqual(SpatialRoomFit.fittingContour(wide).nearestDistancesCentimeters[140], 60, "A real wall wider than a hand remains binding")
        let wideFit = try SpatialRoomFit.applying(to: source, contour: wide)
        XCTAssertTrue(wideFit.document.spatial.layers[0].cells.filter { $0.sector == 140 }.allSatisfy { $0.ring + 1 <= 50 })
    }

    func testRoomShapeRectangleUsesFewCircularBandsInsteadOfPerBearingSawtooth() throws {
        let cells = Set((0...360).map { PolarDeviceLattice(ring: 100, sector: $0)! })
        let layer = SpatialDocumentLayer(id: UUID(), name: "Ring", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: cells, routings: [], cellOverrides: [:])
        var source = try FactoryPresetDocument.empty()
        source.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        let contour = shapeRoom("rectangle")
        let fit = try SpatialRoomFit.applying(to: source, contour: contour)
        let edges = Dictionary(grouping: fit.document.spatial.layers[0].cells, by: \.sector).mapValues { $0.map(\.ring).max()! }
        XCTAssertLessThanOrEqual(Set(edges.values).count, 8, "A zone needs a few circular bands, not dozens of per-ray steps")
        for (tick, ring) in edges {
            XCTAssertLessThanOrEqual(ring + 1, Int(try XCTUnwrap(contour.nearestDistancesCentimeters[tick])) - 10)
        }
    }

    func testRoomShapeRoundRoomExpansionAndFineOverridesStayOnTheirBearing() throws {
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let actions = [SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 67, velocity: 91))]
        let layer = SpatialDocumentLayer(id: UUID(), name: "Override", color: .orange, isVisible: false, isActive: true, isLocked: true, isSoloed: false,
            cells: [cell], routings: [], cellOverrides: [cell: actions], midiTarget: .init(uniqueID: 123))
        var source = try FactoryPresetDocument.empty()
        source.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        let fit = try SpatialRoomFit.applying(to: source, contour: room(wall: 200))
        XCTAssertGreaterThan(fit.minimumFactor, 1)
        XCTAssertEqual(fit.minimumFactor, fit.maximumFactor)
        XCTAssertEqual(Set(fit.document.spatial.layers[0].cells.map(\.sector)), [180])
        XCTAssertTrue(fit.document.spatial.layers[0].cellOverrides.values.allSatisfy { $0 == actions })
        XCTAssertEqual(fit.document.spatial.layers[0].cellOverrides.count, fit.document.spatial.layers[0].cells.count)
        XCTAssertEqual(fit.document.spatial.layers[0].midiTarget, layer.midiTarget)
        XCTAssertTrue(fit.document.spatial.layers[0].isLocked)
        XCTAssertFalse(fit.document.spatial.layers[0].isVisible)
        XCTAssertEqual(try SpatialRoomFit.applying(to: source, contour: room(wall: nil)).document, source)
    }

    func testRoomShapeReportsCollisionsAndKeepsRadialOrder() throws {
        let inner = PolarDeviceLattice(ring: 20, sector: 180)!
        let outer = PolarDeviceLattice(ring: 100, sector: 180)!
        let near = SpatialDocumentLayer(id: UUID(), name: "Near", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [inner], routings: [], cellOverrides: [:])
        let far = SpatialDocumentLayer(id: UUID(), name: "Far", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [outer], routings: [], cellOverrides: [:])
        var source = try FactoryPresetDocument.empty()
        source.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [near, far], selectedLayerID: near.id)
        let expanded = try SpatialRoomFit.applying(to: source, contour: room(wall: 200))
        XCTAssertLessThan(try XCTUnwrap(expanded.document.spatial.layers[0].cells.map(\.ring).max()),
            try XCTUnwrap(expanded.document.spatial.layers[1].cells.map(\.ring).min()))
        let a = PolarDeviceLattice(ring: 1, sector: 180)!, b = PolarDeviceLattice(ring: 2, sector: 180)!
        let actions = [SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 67, velocity: 91))]
        let dense = SpatialDocumentLayer(id: near.id, name: near.name, color: near.color, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [a, b], routings: [], cellOverrides: [a: actions, b: []])
        source.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [dense], selectedLayerID: dense.id)
        for _ in 0..<10 {
            let compressed = try SpatialRoomFit.applying(to: source, contour: room(wall: 11))
            XCTAssertEqual(compressed.mergedCells, 1)
            XCTAssertEqual(compressed.document.spatial.layers[0].cells, [a])
            XCTAssertEqual(compressed.document.spatial.layers[0].cellOverrides[a], actions, "Nearest source wins deterministically")
        }
    }

    func testRoomShapePreservesDormantOverridesAndRejectsTheirSilentActivation() throws {
        let active = PolarDeviceLattice(ring: 100, sector: 180)!
        let dormant = PolarDeviceLattice(ring: 200, sector: 180)!
        let collision = PolarDeviceLattice(ring: 188, sector: 180)!
        let action = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 67, velocity: 91))
        var document = try FactoryPresetDocument.empty()
        func replacing(_ key: PolarDeviceLattice) throws -> InstrumentDocument {
            let layer = SpatialDocumentLayer(id: UUID(), name: "Dormant", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: [active], routings: [], cellOverrides: [key: [action]])
            var copy = document
            copy.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
            return copy
        }
        document = try replacing(dormant)
        let fit = try SpatialRoomFit.applying(to: document, contour: room(wall: 200))
        XCTAssertEqual(fit.document.spatial.layers[0].cellOverrides[dormant], [action])
        XCTAssertFalse(fit.document.spatial.layers[0].cells.contains(dormant))
        XCTAssertThrowsError(try SpatialRoomFit.applying(to: replacing(collision), contour: room(wall: 200)))
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        try owner.applyPresetDocument(replacing(collision))
        owner.noteDisplay(.init(contour: room(wall: 200), selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:])))
        let before = owner.document
        owner.fitToRoom()
        XCTAssertEqual(owner.document, before)
        XCTAssertEqual(owner.roomFitNotice, "Fit limited: a dormant cell override would become active")
    }

    /// B7: a document of surfaces is not changed by fitting, and the notice says so.
    func testFitToRoomNamesTheReasonForALayerOfSurfaces() throws {
        let surface = try SpatialSurface(presentation: .init(name: "Rect", color: .orange),
            form: .shape(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 0, yCm: 100)),
            routings: [SpatialRouting(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .retrigger))])
        let layer = SpatialDocumentLayer(id: UUID(), name: "Surfaces", color: .orange, isVisible: true, isActive: true, isLocked: false,
            isSoloed: false, cells: [], routings: [], cellOverrides: [:], surfaces: [surface])
        var document = try FactoryPresetDocument.empty()
        document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        try owner.applyPresetDocument(document)
        owner.noteDisplay(.init(contour: room(wall: 200), selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:])))
        let before = owner.document
        owner.fitToRoom()
        XCTAssertEqual(owner.document, before)
        XCTAssertEqual(owner.roomFitNotice, "Surface layers are not changed by fitting; move or resize their shapes instead")
        XCTAssertNotEqual(owner.roomFitNotice, "Fit to room rejected")
    }

    func testRoomShapeOfflineEvidenceAndPresetGridCounts() throws {
        guard ProcessInfo.processInfo.environment["FIT_ROOM_EVIDENCE"] == "1" else { throw XCTSkip("Opt-in offline evidence") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent_handoff/runs/fit-raumform")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report = "preset\t25cm cells\t5cm cells\t25cm compile ms\t5cm compile ms\t25cm fit ms\t5cm fit ms\t25cm selection us\t5cm selection us\t25cm static draw ms\t5cm static draw ms\n"
        for name in FactoryPresetLibrary.standard.names {
            let document = try PresetV6Codec.decode(XCTUnwrap(FactoryPresetLibrary.standard.data(named: name))).document
            XCTAssertEqual(document.editorGrid.cellSizeMeters, 0.05)
            var counts: [Int] = [], compileTimes: [Double] = [], fitTimes: [Double] = [], selectionTimes: [Double] = [], drawingTimes: [Double] = []
            for grid in [MetricSquareGrid.quarterMeter, MetricSquareGrid.CellSize.fiveCentimeter.grid] {
                var variant = document; variant.editorGrid = grid
                let masks = try variant.spatial.layers.map { layer in
                    Set(try layer.cells.map { try LegacyLatticeMigration.project($0, in: grid) })
                }
                counts.append(masks.reduce(0) { $0 + $1.count })
                var elapsed = 0.0
                for _ in 0..<3 {
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = try InstrumentCompiler.compile(variant)
                    elapsed += ProcessInfo.processInfo.systemUptime - start
                }
                compileTimes.append(elapsed * 1000 / 3)
                elapsed = 0
                for _ in 0..<3 {
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = try SpatialRoomFit.applying(to: variant, contour: shapeRoom("keller"))
                    elapsed += ProcessInfo.processInfo.systemUptime - start
                }
                fitTimes.append(elapsed * 1000 / 3)
                let layers = zip(variant.spatial.layers, masks).map { layer, cells in
                    SpatialInstrumentLayer(id: layer.id, name: layer.name, color: layer.color, polarCells: cells)
                }
                var state = MetricCanvasInteractionState()
                state.updateWorkspace { $0 = .init(grid: grid, layers: layers) }
                let geometry = MetricCanvasGeometry(size: size, viewport: state.viewport)
                let point = geometry.screenPoint(for: .init(xMeters: 0.1, yMeters: 1))
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<100 { _ = state.selectCell(atScreenPoint: point, canvasSize: size) }
                selectionTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1_000_000 / 100)
                let workspace = CanvasDocumentProjection.workspace(variant)
                let plan = SpatialFieldPlan(workspace: workspace)
                let view = SpatialInstrumentStaticLayer(plan: plan, labels: plan.labels(selectedLayerID: workspace.selectedLayerID),
                    selectedLayerID: workspace.selectedLayerID, mergeZones: true, geometry: geometry)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 800, height: 800),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.frame = .init(origin: .zero, size: size); host.wantsLayer = true
                let timing = CanvasTimingProbe(); CanvasTimingProbe.current = timing
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                CanvasTimingProbe.current = nil
                let draws = max(1, timing.counts["field.staticDraw", default: 0])
                let grids = max(1, timing.counts["field.gridDraw", default: 0])
                XCTAssertGreaterThan(timing.counts["field.staticDraw", default: 0], 0)
                drawingTimes.append(timing.milliseconds["field.staticDraw", default: 0] / Double(draws)
                    + timing.milliseconds["field.gridDraw", default: 0] / Double(grids))
            }
            report += "\(name)\t\(counts[0])\t\(counts[1])\t\(compileTimes[0])\t\(compileTimes[1])\t\(fitTimes[0])\t\(fitTimes[1])\t\(selectionTimes[0])\t\(selectionTimes[1])\t\(drawingTimes[0])\t\(drawingTimes[1])\n"
        }
        try report.write(to: directory.appendingPathComponent("presets.tsv"), atomically: true, encoding: .utf8)
        var areas = "shape\tpreset\told fit area %\tnew fit area %\n"
        for shape in ["keller", "rectangle"] {
            let contour = shapeRoom(shape)
            for name in ["Factory 01 MIDI Scale", "Harmony 29 Picardy Switch"] {
                let fixture = try MonitorRootFixture(), owner = fixture.root.document
                defer { fixture.root.terminate {} }
                let source = try PresetV6Codec.decode(XCTUnwrap(FactoryPresetLibrary.standard.data(named: name))).document
                var coarseSource = source; coarseSource.editorGrid = .quarterMeter
                let workspace = CanvasDocumentProjection.workspace(coarseSource)
                var globalFactor = 1.0
                for cell in workspace.layers.flatMap(\.polarCells) {
                    let segment = PolarMetricCellSegment(cell: cell, grid: workspace.grid)
                    if let wall = SpatialRoomFit.wallMeters(over: segment, contour: contour) {
                        globalFactor = min(globalFactor, max(0, wall - 0.1) / segment.outerRadiusMeters)
                    }
                }
                let global = PolarCellTransform.rasterizing(.init(radialScale: max(1e-12, globalFactor)), cells: [],
                    layerIDs: Set(workspace.layers.map(\.id)), to: workspace, didHitBoundary: false)
                let oldFit = try CanvasDocumentProjection.applying(global.workspace, before: workspace, to: coarseSource)
                let newFit = try SpatialRoomFit.applying(to: source, contour: contour).document
                func area(_ document: InstrumentDocument) -> Double {
                    Set(document.spatial.layers.flatMap(\.cells)).reduce(0) { total, cell in
                        let width = (cell.sector == 0 || cell.sector == 360) ? 0.25 : 0.5
                        return total + (pow(Double(cell.ring + 1) / 100, 2) - pow(Double(cell.ring) / 100, 2)) * width * .pi / 360
                    }
                }
                let roomArea = contour.nearestDistancesCentimeters.enumerated().reduce(0.0) { sum, ray in
                    let width = ray.offset == 0 || ray.offset == contour.nearestDistancesCentimeters.count - 1 ? 0.25 : 0.5
                    return sum + pow(min(2, Double(ray.element ?? 300) / 100), 2) * width * .pi / 360
                }
                areas += "\(shape)\t\(name)\t\(100 * area(oldFit) / roomArea)\t\(100 * area(newFit) / roomArea)\n"
                XCTAssertGreaterThan(area(newFit), area(oldFit) * 1.5)
                for (label, document) in [("before", source), ("old-fit", oldFit), ("after", newFit)] {
                    try owner.applyPresetDocument(document)
                    var configuration = owner.document.detection
                    configuration.roomContour.isEnabled = true
                    owner.updateDetectionConfiguration(configuration)
                    owner.noteDisplay(.init(contour: contour, selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:])))
                    for width in [1024, 380] {
                        let height = width == 380 ? 560 : 800
                        try owner.canvas.applyPresetViewport(.build(centerXMeters: 0, centerYMeters: 1.5,
                            metersPerPoint: max(6.4 / Double(width), 3.4 / Double(height - 240))))
                        let view = CartesianScanFieldView(editor: owner.canvas, profile: nil,
                            activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner, simulationBadge: AnyView(EmptyView()))
                        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).foregroundColor(.white).background(StageTheme.workspace))
                        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.contentView = host
                        defer { window.contentView = nil; window.close() }
                        host.appearance = NSAppearance(named: .darkAqua)
                        host.frame = .init(x: 0, y: 0, width: width, height: height)
                        host.wantsLayer = true; host.layoutSubtreeIfNeeded()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(shape)-\(name)-\(label)-\(width).png"))
                        host.removeFromSuperview()
                    }
                }
            }
        }
        try areas.write(to: directory.appendingPathComponent("areas.tsv"), atomically: true, encoding: .utf8)
    }
}
