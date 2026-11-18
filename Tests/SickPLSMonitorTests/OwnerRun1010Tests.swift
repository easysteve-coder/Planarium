import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PlanariumApplication
import PlanariumDomain
import PlanariumPresets
import PlanariumRuntime
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class OwnerRun1010Tests: XCTestCase {
    private let imageDirectory = TestImageDirectory.make().appendingPathComponent("owner-lauf-1010")
    func testRoomContourStatusPresentsZeroOneAndSeveralRestlessBeams() {
        let geometry = SpatialRoomContour.Geometry(pointCount: 3, angleResolutionDegrees: 1, startAngleDegrees: -1, sourceIdentifier: "test")
        func contour(_ spreads: [UInt16?]) -> SpatialRoomContour {
            .init(geometry: geometry, nearestDistancesCentimeters: [100, 100, 100], spreadCentimeters: spreads)
        }
        XCTAssertEqual(RoomContourCaptureStatus.contourMessage(contour([0, 16, nil])), "Contour steady")
        XCTAssertEqual(RoomContourCaptureStatus.contourMessage(contour([17, 0, nil])), "Contour steady · 1 restless beam")
        XCTAssertEqual(RoomContourCaptureStatus.contourMessage(contour([17, 19, 0])), "Contour steady · 2 restless beams")
    }
    private struct LiveLayerInspector: View {
        @ObservedObject var owner: SpatialInstrumentRuntimeModel
        let audio: AudioCatalogModel
        let fixture: MonitorRootFixture
        var body: some View {
            SpatialLayerInspectorView(editor: owner.canvas, audioUnits: audio, midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
        }
    }
    private func presets(_ fixture: MonitorRootFixture) -> PresetControlModel {
        PresetControlModel(store: .init(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), documentOwner: fixture.root.document)
    }
    func testFactory29And30RadialDragMovesSelectedInteriorCellsByOneRing() throws {
        for name in ["Harmony 29 Picardy Switch", "Harmony 30 Mode Wheel"] {
            let fixture = try MonitorRootFixture(), owner = fixture.root.document, library = presets(fixture)
            defer { fixture.root.terminate {} }
            XCTAssertNotNil(library.load(name, decision: .discard))
            let size = CGSize(width: 800, height: 800)
            _ = owner.canvas.resetViewport(canvasSize: size)
            let chosen = owner.canvas.workspace.layers.compactMap { layer -> CanvasCellSelection? in
                // Historical test picked an interior point at 0.25–1.25 m.
                // Keep that physical range after the approved 5-cm default.
                guard let cell = layer.polarCells.sorted(by: { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }).first(where: {
                    let radius = Double($0.ring) * owner.canvas.workspace.grid.cellSizeMeters
                    return (0.25...1.0).contains(radius)
                }) else { return nil }
                return .init(layerID: layer.id, cell: cell)
            }
            XCTAssertGreaterThan(chosen.count, 0)
            owner.canvas.perform { $0.selection = .init(cells: Set(chosen)) }
            let selectedCell = try XCTUnwrap(chosen.last?.cell)
            let bounds = PolarMetricCellSegment(cell: selectedCell, grid: owner.canvas.workspace.grid)
            let geometry = owner.canvas.displayGeometry(canvasSize: size)
            let start = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters,
                                                               bearingDegrees: bounds.midpoint.bearingDegrees))
            let end = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters + owner.canvas.workspace.grid.cellSizeMeters,
                                                             bearingDegrees: bounds.midpoint.bearingDegrees))
            let expected = PolarCellMove.applying(radialSteps: 1, angularSteps: 0,
                cellsByLayer: Dictionary(grouping: chosen, by: \.layerID).mapValues { Set($0.map(\.cell)) }, to: owner.canvas.workspace)
            owner.canvas.send(.arm(start, modifiers: [], brush: false), canvasSize: size)
            owner.canvas.send(.drag(end), canvasSize: size)
            XCTAssertEqual(owner.canvas.gesture.phase, .moving, "Factory selection must arm a move, not replace selection")
            owner.canvas.send(.release(end), canvasSize: size)
            XCTAssertEqual(owner.canvas.workspace, expected.workspace)
            XCTAssertEqual(Dictionary(grouping: Array(owner.canvas.selectedCells), by: \.layerID).mapValues { Set($0.map(\.cell)) }, expected.cellsByLayer)
            XCTAssertFalse(owner.canvas.isDragging)
        }
    }
    func testFactory29ExportImportAndOldV5ExportPreserveScenes() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document, library = presets(fixture)
        defer { fixture.root.terminate {} }
        let name = "Harmony 29 Picardy Switch"
        XCTAssertNotNil(library.load(name, decision: .discard))
        let expected = owner.document.spatial, scenes = owner.document.scenes
        XCTAssertFalse(scenes.isEmpty)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID()).json")
        library.export(to: file)
        XCTAssertTrue(library.notice?.hasPrefix("Exported:") == true)
        library.importFiles([file])
        let exportedName = file.deletingPathExtension().lastPathComponent
        XCTAssertEqual(library.notice, "Imported: \(exportedName)")
        XCTAssertNotNil(library.load(exportedName, decision: .discard))
        XCTAssertEqual(owner.document.spatial, expected); XCTAssertEqual(owner.document.scenes, scenes)
        let v5 = try PresetV5Codec.encode(.init(name: "Old Picardy", document: owner.document, summary: "Legacy scene export"))
        try v5.write(to: file)
        library.importFiles([file]); XCTAssertEqual(library.notice, "Imported: Old Picardy")
        XCTAssertNotNil(library.load("Old Picardy", decision: .discard))
        XCTAssertEqual(owner.document.spatial, expected); XCTAssertEqual(owner.document.scenes, scenes)
        let frozen = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/PlanariumPresetsTests/Fixtures/TargetBoundary/Factory/Harmony 29 Picardy Switch.sickpreset.json")
        XCTAssertEqual(try PresetDocumentReader.read(Data(contentsOf: frozen)).get().sourceVersion, 5)
        library.importFiles([frozen]); XCTAssertEqual(library.notice, "Imported: \(name) 2")
        XCTAssertNotNil(library.load(name + " 2", decision: .discard))
        let fieldlessExpected = try SpatialDocument(latticeVersion: expected.latticeVersion, layers: expected.layers.map { layer in
            .init(id: layer.id, name: layer.name, color: layer.color, isVisible: layer.isVisible,
                  isActive: layer.isActive, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
                  cells: layer.cells, routings: layer.routings.map { routing in
                      // The frozen V5 export predates the immediate scene-switch default.
                      var legacy = routing
                      if case .sceneSwitch(let action, _) = legacy.target {
                          legacy.target = .sceneSwitch(action: action, dwellSeconds: 0.2)
                      }
                      return legacy
                  }, cellOverrides: layer.cellOverrides, toggleGuardSeconds: 0)
        }, selectedLayerID: expected.selectedLayerID)
        XCTAssertEqual(owner.document.spatial, fieldlessExpected); XCTAssertEqual(owner.document.scenes, scenes)
    }
    func testOriginalOwnerV5ExportImportsThroughLibraryWithoutLoggingItsContents() throws {
        guard let path = ProcessInfo.processInfo.environment["OWNER_IMPORT_FIXTURE"] else {
            throw XCTSkip("Original owner export supplied outside the repository")
        }
        let fixture = try MonitorRootFixture(), owner = fixture.root.document, library = presets(fixture)
        defer { fixture.root.terminate {} }
        library.importFiles([URL(fileURLWithPath: path)])
        XCTAssertEqual(library.notice, "Imported: Harmony 29 Picardy Switch 2")
        guard library.notice == "Imported: Harmony 29 Picardy Switch 2" else { return }
        XCTAssertNotNil(library.load("Harmony 29 Picardy Switch 2", decision: .discard))
        XCTAssertEqual(owner.document.spatial.layers.count, 13)
        XCTAssertEqual(owner.document.scenes.count, 2)
        XCTAssertNotNil(owner.document.currentSceneID)
        XCTAssertNoThrow(try InstrumentCompiler.compile(owner.document))
    }
    func testImportReportsActualFailedBoundaryWithoutEchoingParserContents() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent("rejected-\(UUID()).json")
        try Data("not-json-parser-content".utf8).write(to: invalid)
        let library = presets(fixture)
        library.importFiles([invalid])
        XCTAssertEqual(library.notice, "Not imported: \(invalid.lastPathComponent) (preset validation)")
        let valid = try PresetV6Codec.encode(library.capture(name: "Import diagnostic"))
        try valid.write(to: invalid)
        let blockedStore = PresetControlModel(store: .init(directory: invalid), documentOwner: fixture.root.document)
        blockedStore.importFiles([invalid])
        XCTAssertEqual(blockedStore.notice, "Not imported: \(invalid.lastPathComponent) (library write)")
        XCTAssertFalse(blockedStore.notice?.contains("not-json-parser-content") == true)
    }
    func testRenameEntryFocusSelectsCompleteLayerAndChannelName() throws {
        for name in ["Layer G7", "Lead channel"] {
            let host = NSHostingView(rootView: RenameEntryField(text: .constant(name)))
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 280, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            host.frame = .init(x: 0, y: 0, width: 280, height: 90)
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            XCTAssertEqual(editor.string, name)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: name.utf16.count))
        }
    }
    func testCapturedContourFiltersBothAngularResolutionsThroughRuntimeAndPresetSwitch() throws {
        for captureCount in [90, 361] {
            let fixture = try MonitorRootFixture(), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            let contour = SpatialRoomContour(geometry: .init(pointCount: captureCount, angleResolutionDegrees: 180 / Double(captureCount - 1), startAngleDegrees: -90, sourceIdentifier: "scanner:default"),
                nearestDistancesCentimeters: Array(repeating: 200, count: captureCount), spreadCentimeters: Array(repeating: 0, count: captureCount))
            fixture.root.runtime.roomContour(contour)
            var configuration = owner.document.detection; configuration.roomContour = .init(isEnabled: true, toleranceCentimeters: 9)
            owner.updateDetectionConfiguration(configuration)
            let session = UUID(); fixture.root.runtime.sessionBegan(session)
            for count in [90, 361] {
                let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { try .build(value: $0 == count / 2 ? 100 : 200, fieldFlags: 0) })
                let frame = ProfileFrame(sessionID: session, sequence: count == 90 ? 1 : 2, time: MonotonicRuntimeClock().now,
                    measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
                fixture.root.runtime.frame(frame)
                let done = expectation(description: "Angular contour"); fixture.root.runtime.acknowledge { done.fulfill() }; wait(for: [done], timeout: 5)
                let display = try XCTUnwrap(fixture.root.runtime.mailbox.read())
                XCTAssertTrue(display.selection.contourMatches)
                XCTAssertEqual(display.selection.filteredOrders.count, count - 1)
                XCTAssertFalse(display.selection.filteredOrders.contains(count / 2))
            }
        }
    }
    func testCapturedDuplicateCommandUsesCurrentRowSelectionAndCellKeyboardUsesCurrentOverride() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let a = PolarMetricGridCell(ring: 2, angularIndex: 8), b = PolarMetricGridCell(ring: 3, angularIndex: 8)
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let first = SpatialInstrumentLayer(name: "First", color: .blue, polarCells: [a], routings: [.init(target: target, program: .chord(notes: [62, 65, 69], velocity: 100, transition: .legato))])
        let second = SpatialInstrumentLayer(name: "Second", color: .orange, polarCells: [b], routings: [.init(target: target, program: .chord(notes: [60, 64, 67], velocity: 100, transition: .legato))],
            polarCellOverrides: [b: [.init(target: target, value: .chord(notes: [59, 62, 65], velocity: 90))]])
        owner.canvas.replaceWorkspace(.init(layers: [first, second]))
        func inspector() -> SpatialLayerInspectorView {
            .init(editor: owner.canvas, audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()), midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
        }
        let capturedCommand = inspector().duplicateLayerCommand
        inspector().selectLayerForInspection(second.id)
        capturedCommand()
        XCTAssertEqual(owner.canvas.workspace.selectedLayer.name, "Second copy")
        XCTAssertEqual(owner.canvas.workspace.selectedLayer.polarCellOverrides[b]?.first?.value, .chord(notes: [59, 62, 65], velocity: 90))
        let size = CGSize(width: 800, height: 800), center = SpatialFieldPlan.center(.init(cell: b, grid: owner.canvas.workspace.grid))
        let point = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
        _ = owner.canvas.selectCell(atScreenPoint: point, canvasSize: size)
        XCTAssertEqual(SpatialCellNoteDraft.current(cell: b, in: owner.canvas.presentation)?.notes, [59, 62, 65])
        let cellView = CellInspectorView(editor: owner.canvas)
        XCTAssertEqual(cellView.noteKeyboard(cell: b, document: try XCTUnwrap(SpatialCellNoteDraft.current(cell: b, in: owner.canvas.presentation))).model.selectedNotes, [59, 62, 65])
        for width in [400, 220] { try render(cellView, width: width, height: 720, name: "cell-\(width)") }
        inspector().selectLayerForInspection(second.id)
        XCTAssertEqual(SpatialAssignmentDraft.current(in: owner.canvas.presentation).chordNotes, [60, 64, 67])
        XCTAssertEqual(inspector().assignmentKeyboard.model.selectedNotes, [60, 64, 67])
        for width in [420, 300] { try render(inspector(), width: width, height: 950, name: "layer-\(width)") }
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        inspector().selectLayerForInspection(first.id)
        let host = NSHostingView(rootView: LiveLayerInspector(owner: owner, audio: AudioCatalogModel(document: owner, source: EmptyCatalog()), fixture: fixture))
        host.frame = .init(x: 0, y: 0, width: 420, height: 950)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThan(probe.counts["piano.selected.62", default: 0], 0)
        probe.reset()
        inspector().selectLayerForInspection(second.id) // actual row action; same displayed octave
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for note in [60, 64, 67] { XCTAssertGreaterThan(probe.counts["piano.selected.\(note)", default: 0], 0, "The shared Canvas renderer must receive the new layer after its equatable boundary") }
        XCTAssertEqual(probe.counts["piano.selected.62", default: 0], 0)
    }
    func testCaptureLengthIsFixedToFiveSecondsAndIgnoresLegacyValues() throws {
        let clock = ShortcutTempoClock()
        let fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document
        defer { fixture.root.display.stop(); fixture.root.terminate {} }
        XCTAssertEqual(owner.contourCapture.durationSeconds, 5)
        XCTAssertEqual(owner.contourCapture.targetProfileCount, 125)
        owner.setRoomContourCaptureDuration(seconds: 27)
        XCTAssertEqual(owner.contourCapture.durationSeconds, 5)
        let session = UUID()
        fixture.root.runtime.sessionBegan(session)
        let count = 361
        let geometry = ProfileGeometryIdentity(operatingMode: "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
        var payload: [UInt8] = [0xb0, UInt8(count & 255), UInt8(count >> 8)]
        for _ in 0..<count { payload += [100, 0] }; payload += [0]
        let raw = try B0ScanProfile.decode(from: payload).get()
        owner.setRoomContourCaptureDuration(seconds: 2)
        RoomContourCaptureButton(capture: owner.contourCapture, instrument: owner).toggleCapture()
        clock.set(clock.now + 3)
        owner.setRoomContourCaptureDuration(seconds: 60) // ignored while recording
        XCTAssertEqual(owner.contourCapture.durationSeconds, 5)
        for sequence in 1...125 {
            let profile = ProfileFrame(sessionID: session, sequence: UInt64(sequence), time: clock.now,
                measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: geometry, rawProfile: raw)
            fixture.root.runtime.frame(profile)
            let acknowledged = expectation(description: "Display frame installed")
            fixture.root.runtime.acknowledge { acknowledged.fulfill() }; wait(for: [acknowledged], timeout: 5)
            owner.roomCapture.receive(.frame(profile))
            waitCapture(owner)
            XCTAssertEqual(owner.isCapturingRoomContour, sequence < 125)
        }
        XCTAssertNotNil(owner.roomContour)
        RoomContourCaptureButton(capture: owner.contourCapture, instrument: owner).toggleCapture()
        clock.set(clock.now + 3)
        for sequence in 126...250 {
            let profile = ProfileFrame(sessionID: session, sequence: UInt64(sequence), time: clock.now,
                measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: geometry, rawProfile: raw)
            fixture.root.runtime.frame(profile)
            let acknowledged = expectation(description: "Display frame installed")
            fixture.root.runtime.acknowledge { acknowledged.fulfill() }; wait(for: [acknowledged], timeout: 5)
            owner.roomCapture.receive(.frame(profile))
            waitCapture(owner)
            XCTAssertEqual(owner.roomContourCaptureProgress, Double((sequence - 125) * 100 / 125) / 100, accuracy: 1e-9)
        }
        XCTAssertFalse(owner.isCapturingRoomContour)
    }
    func testCaptureTwiceProgressPublishesAndSettingsSurviveEveryFactoryPreset90And361() throws {
        for count in [90, 361] {
            let clock = ShortcutTempoClock()
            let fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document, library = presets(fixture)
            let layout = try LayoutWorkspaceFixture(fixture: fixture)
            defer { layout.cleanDefaults(); fixture.root.display.stop(); fixture.root.terminate {} }
            // The actual ContentView owns the display subscription. Frames go
            // runtime → mailbox → display reader → production onReceive.
            let host = NSHostingView(rootView: layout.view)
            host.frame = .init(x: 0, y: 0, width: 1728, height: 1000)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let session = UUID()
            fixture.root.runtime.sessionBegan(session)
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "segmentMinimum" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            var payload: [UInt8] = [0xb0, UInt8(count & 255), UInt8(count >> 8)]
            for _ in 0..<count { payload += [100, 0] }; payload += [0]
            let raw = try B0ScanProfile.decode(from: payload).get()
            var deliveries = 0
            let observation = owner.contourCapture.$progress.sink { _ in deliveries += 1 }
            var inspectorPublications = 0
            let inspectorObservation = owner.objectWillChange.sink { inspectorPublications += 1 }
            // Capture is fixed to 5 s / 125 profiles; legacy values cannot
            // alter the product acquisition contract.
            owner.setRoomContourCaptureDuration(seconds: 2)
            XCTAssertEqual(owner.contourCapture.targetProfileCount, 125)
            for capture in 0..<2 {
                let beforeProgress = deliveries
                RoomContourCaptureButton(capture: owner.contourCapture, instrument: owner).toggleCapture()
                clock.set(clock.now + 3)
                for sequence in 1...125 {
                    let profile = ProfileFrame(sessionID: session, sequence: UInt64(sequence + capture * 125), time: clock.now,
                        measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: geometry, rawProfile: raw)
                    fixture.root.runtime.frame(profile)
                    owner.roomCapture.receive(.frame(profile))
                    waitCapture(owner)
                    let acknowledged = expectation(description: "Display frame installed")
                    fixture.root.runtime.acknowledge { acknowledged.fulfill() }; wait(for: [acknowledged], timeout: 5)
                    fixture.root.display.read()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.003))
                    // Acquisition has its own ingress branch; the visible
                    // progress is quantized to whole percentages.
                    XCTAssertEqual(owner.roomContourCaptureProgress, Double(sequence * 100 / 125) / 100, accuracy: 1e-9)
                    XCTAssertLessThanOrEqual(owner.roomContourCaptureProgress, 1)
                    if capture == 1 && [1, 63, 125].contains(sequence) {
                        for width in [740, 380] {
                            let cells = SpatialActiveCellDisplayModel()
                            let view = CartesianScanFieldView(editor: owner.canvas, profile: raw,
                                activeCellDisplay: cells, spatialInstrument: owner, simulationBadge: AnyView(EmptyView()), detectionInitiallyExpanded: true)
                            try render(view, width: width, height: 950, name: "contour-\(count)-\(sequence)-\(width)")
                        }
                    }
                }
                XCTAssertFalse(owner.isCapturingRoomContour); XCTAssertNotNil(owner.roomContour)
                XCTAssertEqual(owner.contourCapture.notice, "Room contour captured · wall spread ±\(try XCTUnwrap(owner.roomContour).measuredScatterCentimeters) cm")
                XCTAssertEqual(deliveries - beforeProgress, 101, "One initial reset plus at most 100 acquisition progress updates")
            }
            XCTAssertEqual(deliveries, 203); withExtendedLifetime(observation) {}
            XCTAssertLessThanOrEqual(inspectorPublications, 4, "Capture ticks must not republish the inspector owner")
            withExtendedLifetime(inspectorObservation) {}
            var detection = owner.document.detection; detection.roomContour.toleranceCentimeters = 9
            owner.updateDetectionConfiguration(detection)
            for name in library.names {
                XCTAssertNotNil(library.load(name, decision: .discard))
                XCTAssertTrue(owner.document.detection.roomContour.isEnabled)
                XCTAssertEqual(owner.document.detection.roomContour.toleranceCentimeters, 9)
                XCTAssertNotNil(owner.roomContour)
            }
            let data = try PresetV6Codec.encode(library.capture(name: "Roomless"))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("roomFilter"))
        }
    }
    func testBuildNumberAndGlobalMIDIChoiceRenderInProductionWorkspaceWideAndNarrow() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop(); fixture.root.terminate {} }
        for width in [1728, 1024] { try render(layout.view, width: width, height: 1000, name: "workspace-build-midi-\(width)") }
    }
    func testActualBuildAndScannerFlagTextDeclareVersionAndUnfilteredEvidence() throws {
        XCTAssertEqual(WorkspaceStatusView.buildLabel, "Build \(PlanariumBuildIdentity.current.buildNumber)")
        XCTAssertTrue(ScannerFlagLegendView.title.contains("unfiltered raw scan"))
        let model = SpatialActiveCellDisplayModel()
        for width in [740, 380] { try render(ScannerFlagLegendView(model: model), width: width, height: 160, name: "flag-legend-\(width)") }
    }
    func testCaptureDiscardAndCancellationReasonsThroughActualMeasurementPane() throws {
        let clock = ShortcutTempoClock()
        let fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document, layout = try LayoutWorkspaceFixture(fixture: fixture)
        owner.setRoomContourCaptureDuration(seconds: 2) // ignored; capture stays at 125 profiles
        defer { layout.cleanDefaults(); fixture.root.display.stop(); fixture.root.terminate {} }
        let host = NSHostingView(rootView: MeasurementPane(display: fixture.root.display, instrument: owner, simulation: layout.view.simulation, workspace: layout.workspace))
        host.frame = .init(x: 0, y: 0, width: 740, height: 950); host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        var session = UUID(); fixture.root.runtime.sessionBegan(session)
        func deliver(_ count: Int, sequence: UInt64, distance: UInt16 = 100, mismatchedGeometry: Bool = false) throws {
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { _ in try .build(value: distance, fieldFlags: 0) })
            let geometry = mismatchedGeometry ? ProfileGeometryIdentity(operatingMode: "fullScan", pointCount: 361, startAngleDegrees: -90, endAngleDegrees: 90) : try FullScanProfileAdapter.geometry(from: raw)
            clock.set(clock.now + 3)
            let profile = ProfileFrame(sessionID: session, sequence: sequence, time: clock.now,
                measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: geometry, rawProfile: raw)
            fixture.root.runtime.frame(profile)
            owner.roomCapture.receive(.frame(profile)); waitCapture(owner)
            let done = expectation(description: "Capture display"); fixture.root.runtime.acknowledge { done.fulfill() }; wait(for: [done], timeout: 5)
            fixture.root.display.read(); host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.003))
        }
        let button = RoomContourCaptureButton(capture: owner.contourCapture, instrument: owner)
        button.toggleCapture(); try deliver(90, sequence: 1); try deliver(90, sequence: 1)
        XCTAssertEqual(owner.contourCapture.progress, 0); XCTAssertTrue(owner.contourCapture.isCapturing)
        XCTAssertNil(owner.contourCapture.notice)
        session = UUID(); fixture.root.runtime.sessionBegan(session); try deliver(90, sequence: 1)
        XCTAssertEqual(owner.contourCapture.notice, "Capture cancelled: scanner session changed"); XCTAssertFalse(owner.contourCapture.isCapturing)
        button.toggleCapture(); try deliver(90, sequence: 2); try deliver(361, sequence: 3)
        XCTAssertEqual(owner.contourCapture.notice, "Capture cancelled: scanner geometry changed"); XCTAssertFalse(owner.contourCapture.isCapturing)
        button.toggleCapture(); try deliver(90, sequence: 4, mismatchedGeometry: true)
        XCTAssertEqual(owner.contourCapture.notice, "Capture cancelled: invalid scanner geometry"); XCTAssertFalse(owner.contourCapture.isCapturing)
        button.toggleCapture()
        for sequence in 5...129 { try deliver(361, sequence: UInt64(sequence), distance: 8191) }
        XCTAssertEqual(owner.contourCapture.notice, "Capture cancelled: no usable wall measurements")
        XCTAssertFalse(owner.contourCapture.isCapturing); XCTAssertEqual(owner.contourCapture.progress, 0); XCTAssertNil(owner.roomContour)
        button.toggleCapture(); button.toggleCapture()
        XCTAssertEqual(owner.contourCapture.notice, "Capture cancelled by user"); XCTAssertFalse(owner.contourCapture.isCapturing)
    }
    func testContourPenSessionLifecyclePreviewAndOfflineImages() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document, library = presets(fixture)
        defer { fixture.root.terminate {} }
        XCTAssertNil(owner.drawnContour)
        owner.beginContourStroke(at: .init(xMeters: -3,yMeters: 1.8), straight: true, erasing: false)
        owner.updateContourStroke(to: .init(xMeters: 3,yMeters: 1.8))
        let preview = try XCTUnwrap(owner.roomContour)
        XCTAssertEqual(preview.nearestDistancesCentimeters[180], 180)
        for active in [true,false] { for width in [380,1000] { for labels in [false,true] {
            XCTAssertNotNil(owner.roomFit.fittingContour)
            XCTAssertTrue(owner.roomContourMatches)
            XCTAssertTrue(owner.canvas.workspace.detectionConfiguration.roomContour.isEnabled)
            let view = CartesianScanFieldView(editor: owner.canvas, contourPenActive: active, profile: nil,
                activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner, simulationBadge: AnyView(EmptyView()),
                toolbarLabels: .constant(labels))
            try render(view, width: width, height: 850, name: "konturstift-\(active ? "drawing" : "inactive")-\(width)" + (labels ? "-labels" : ""))
        } } }
        owner.endContourStroke()
        let session = UUID(); fixture.root.runtime.sessionBegan(session)
        for count in [361,90,361] {
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { _ in try .build(value: 220, fieldFlags: 0) })
            let frame = ProfileFrame(sessionID: session, sequence: UInt64(count), time: MonotonicRuntimeClock().now,
                measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
            fixture.root.runtime.frame(frame)
            let done = expectation(description: "Contour installed")
            fixture.root.runtime.acknowledge { done.fulfill() }; wait(for: [done], timeout: 5)
            let display = try XCTUnwrap(fixture.root.runtime.mailbox.read())
            owner.noteDisplay(display)
            XCTAssertEqual(owner.drawnContour?.geometry.pointCount, count)
            let revision = owner.drawnContourRevision
            for _ in 0..<100 { owner.noteDisplay(display) }
            XCTAssertEqual(owner.drawnContourRevision, revision, "Profiles never rebuild the angular drawing")
        }
        let drawing = owner.drawnContour
        owner.canvas.setPerformanceLocked(true)
        owner.clearDrawnContour()
        owner.beginContourStroke(at: .init(xMeters: 0,yMeters: 0.5), straight: false, erasing: false)
        XCTAssertEqual(owner.drawnContour, drawing)
        owner.canvas.setPerformanceLocked(false)
        XCTAssertNotNil(library.load(library.names[0], decision: .discard))
        XCTAssertEqual(owner.drawnContour, drawing)
        let data = try PresetV6Codec.encode(library.capture(name: "No drawing"))
        XCTAssertFalse(String(decoding: data,as: UTF8.self).contains("drawnDistances"))
        let fresh = try MonitorRootFixture()
        defer { fresh.root.terminate {} }
        XCTAssertNil(fresh.root.document.drawnContour); XCTAssertNil(fresh.root.document.roomContour)
        owner.beginContourStroke(at: .init(xMeters: -3,yMeters: 1.8), straight: false, erasing: true)
        owner.updateContourStroke(to: .init(xMeters: 3,yMeters: 1.8)); owner.endContourStroke()
        XCTAssertNil(owner.roomContour)
        owner.clearDrawnContour(); XCTAssertNil(owner.drawnContour)
    }
    private func render<V: View>(_ view: V, width: Int, height: Int, name: String) throws {
        let directory = imageDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark).foregroundColor(.white).background(StageTheme.workspace)))
        defer { host.rootView = AnyView(EmptyView()); host.removeFromSuperview() }
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.wantsLayer = true; host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}

@MainActor private func waitCapture(_ owner: SpatialInstrumentRuntimeModel) {
    let done = DispatchSemaphore(value: 0)
    owner.roomCapture.acknowledge { done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}
