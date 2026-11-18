import AppKit
import SwiftUI
import XCTest
import PlanariumDomain
import PlanariumAudio
import PlanariumRuntime
@testable import PlanariumApplication
import PlanariumPresets
import AVFoundation
import SickPLSMonitorKit
import SickPLSCore
@testable import SickPLSMonitor

@MainActor final class ChannelMixerRenderingTests: XCTestCase {
    func testEveryStripOutputClickOpensMasterCardIncludingNewChannel() throws {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        let catalog = AudioCatalogModel(document: owner, source: EmptyCatalog())
        defer { fixture.root.terminate {} }
        try owner.addChannel()
        var startRequests = 0
        let devices = AudioOutputDeviceControlModel(host: fixture.root.audio, startAudio: { startRequests += 1 })
        func elements(_ value: Any, depth: Int = 0) -> [NSObject] {
            guard depth < 40, let element = value as? NSObject else { return [] }
            let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren()
                ?? (element.responds(to: NSSelectorFromString("accessibilityChildren")) ? element.value(forKey: "accessibilityChildren") as? [Any] : nil)
                ?? element.accessibilityAttributeValue(.children) as? [Any] ?? []
            return [element] + children.flatMap { elements($0, depth: depth + 1) }
        }
        var expectedStarts = 0
        for entry in [(false, false, false), (false, false, true), (false, true, false), (false, true, true),
                      (true, false, false), (true, false, true), (true, true, false), (true, true, true)] {
            let (newlyAdded, compact, performing) = entry
            owner.canvas.setPerformanceLocked(false)
            if newlyAdded && !compact && !performing { try owner.addChannel() }
            owner.canvas.setPerformanceLocked(performing)
            let strip = owner.document.channels.last!
            let width = 72 * (owner.document.channels.count + 1)
            let host = NSHostingView(rootView: MixerView(instrument: owner, audioUnits: catalog, host: fixture.root.audio,
                midi: fixture.root.midi, devices: devices, compact: compact)
                .environment(\.colorScheme, .dark).preferredColorScheme(.dark))
            host.frame = .init(x: 0, y: 0, width: width, height: 900)
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 900),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
            defer { window.close() }
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let buttons = elements(window).filter {
                ($0 as? NSAccessibilityProtocol)?.accessibilityLabel() == "Audio output: Master"
                    || ($0.responds(to: NSSelectorFromString("accessibilityLabel")) && $0.value(forKey: "accessibilityLabel") as? String == "Audio output: Master")
            }
            XCTAssertEqual(buttons.count, owner.document.channels.count)
            let channelIndex = try XCTUnwrap(owner.document.channels.firstIndex { $0.id == strip.id })
            let button = try XCTUnwrap(buttons.indices.contains(channelIndex) ? buttons[channelIndex] : nil)
            XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("accessibilityPerformPress"), to: button, from: nil))
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            if !performing { expectedStarts += 1 }
            XCTAssertEqual(startRequests, expectedStarts)
            let cards = NSApp.windows.filter(\.isVisible).flatMap { elements($0) }.filter { ($0 as? NSAccessibilityProtocol)?.accessibilityIdentifier() == "strip.audioOutput" }
            XCTAssertFalse(cards.isEmpty, "The very first click must show the shared device card even with stopped audio")
            let directory = TestImageDirectory.make(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("runde-g-mixer-\(newlyAdded)-\(compact)-\(performing).png"))
            try render(ChannelStripView(spatialInstrument: owner, audioUnits: catalog,
                host: try XCTUnwrap(fixture.root.audio.host(for: strip.id)), midiOutput: fixture.root.midi,
                audioDevices: devices, compact: compact, stripID: strip.id), width: 72, height: 900,
                name: "runde-g-output-\(newlyAdded)-\(compact)-\(performing).png", directory: directory)
        }
    }

    func testPerformanceMixerEditsKeepTheInstalledInstrumentInstance() throws {
        let components = MenuPlugins(), graph = MonitorGraph()
        let f = try MonitorRootFixture(components: components, graph: graph), owner = f.root.document
        defer { f.root.terminate {} }
        var document = owner.document; document.channel.instrument = .init(identity: MenuPlugins.identity)
        try owner.applyPresetDocument(document)
        let host = try XCTUnwrap(f.root.audio.host(for: owner.document.channel.id))
        let instance = try XCTUnwrap(host.instrument), loads = components.loads
        owner.canvas.setPerformanceLocked(true)
        for index in 0..<4 {
            var channel = owner.document.channel
            switch index {
            case 0: channel.levelDecibels = -12
            case 1: channel.pan = 0.6
            case 2: channel.muted = true
            case 3: channel.soloed = true
            default: XCTFail("Missing mixer transition")
            }
            owner.updateChannel(channel)
            XCTAssertEqual(owner.document.channel, channel)
            XCTAssertTrue(host.instrument === instance)
            XCTAssertEqual(components.loads, loads)
        }
        owner.updateMasterLevel(-9)
        XCTAssertTrue(host.instrument === instance); XCTAssertEqual(components.loads, loads)
        owner.setBeatsPerMinute(91); owner.tapTempo()
        XCTAssertEqual(owner.document.beatsPerMinute, 91)
        XCTAssertTrue(host.instrument === instance); XCTAssertEqual(components.loads, loads)
        XCTAssertNil(owner.notice)
        XCTAssertEqual(graph.starts, 0)
    }
    func testPerformanceOwnerMutatorLockMatrixAndMixedChannelChanges() throws {
        let identity = SpatialAudioUnitIdentity(componentType: 1, componentSubType: 2, componentManufacturer: 3)
        let rows: [(String, (SpatialInstrumentRuntimeModel) throws -> Void)] = [
            ("edit", { try $0.edit { $0.channelName = "Changed" } }),
            ("updateChannel.name", { var c = $0.document.channel; c.name = "Changed"; $0.updateChannel(c) }),
            ("updateChannel.color", { var c = $0.document.channel; c.color = .orange; $0.updateChannel(c) }),
            ("updateChannel.instrument+level", { var c = $0.document.channel; c.instrument = .init(identity: identity); c.levelDecibels = -9; $0.updateChannel(c) }),
            ("updateChannel.inserts", { var c = $0.document.channel; c.inserts = [.init(id: UUID(), plugin: .init(identity: identity))]; $0.updateChannel(c) }),
            ("updateChannel.midiTarget", { var c = $0.document.channel; c.midiTarget = .init(uniqueID: 7); $0.updateChannel(c) }),
            ("selectMIDITarget", { $0.selectMIDITarget(.init(uniqueID: 7)) }),
            ("configureClock.off", { $0.configureClock(enabled: false, targets: []) }),
            ("configureClock.destinations", { $0.configureClock(enabled: true, targets: [7]) }),
            ("selectInstrument", { $0.selectInstrument(identity) }),
            ("selectInstrument.same", { $0.selectInstrument(nil) }),
            ("addChannel", { try $0.addChannel() }),
            ("duplicateChannel", { try $0.duplicateChannel($0.document.channel.id) }),
            ("deleteChannel", { try $0.deleteChannel($0.document.channel.id) }),
            ("duplicateLayer", { $0.duplicateLayer() }),
            ("updateDetectionConfiguration", { var d = $0.document.detection; d.groupingMinimumPoints = 2; $0.updateDetectionConfiguration(d) }),
            ("setSwitchConfirmationProfiles", { $0.setSwitchConfirmationProfiles(4) }),
            ("undo", { _ = $0.undo() }), ("redo", { _ = $0.redo() }),
            ("confirmOutputChange", { $0.confirmOutputChange() }),
            ("perform.delete", { _ = $0.perform(.delete) }),
            ("perform.selectAll", { _ = $0.perform(.selectAll) }),
            ("startSpatialAudio", { $0.startSpatialAudio() })
        ]
        for (name, action) in rows {
            let graph = MonitorGraph(), f = try MonitorRootFixture(graph: graph), owner = f.root.document
            // Give undo and redo real history. Every denied path must preserve it.
            try owner.edit { $0.channelName = "Seed" }
            XCTAssertTrue(owner.undo())
            if name == "undo" { XCTAssertTrue(owner.redo()) }
            let before = owner.document, workspace = owner.canvas.workspace
            let undo = owner.canUndo, redo = owner.canRedo
            owner.canvas.setPerformanceLocked(true)
            try action(owner)
            XCTAssertEqual(owner.document, before, name)
            XCTAssertEqual(owner.canvas.workspace, workspace, name)
            XCTAssertEqual(owner.canUndo, undo, name); XCTAssertEqual(owner.canRedo, redo, name)
            XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason, name)
            XCTAssertEqual(graph.starts, 0, name)
            f.root.terminate {}
        }
        // Pure mixer writes reach the document in Perform; adding an authoring
        // field to the same request above rejects the complete request.
        for property in ["level", "pan", "mute", "solo"] {
            let f = try MonitorRootFixture(), owner = f.root.document
            owner.canvas.setPerformanceLocked(true)
            let before = owner.document
            var channel = before.channel
            switch property {
            case "level": channel.levelDecibels = -9
            case "pan": channel.pan = 0.6
            case "mute": channel.muted = true
            case "solo": channel.soloed = true
            default: XCTFail("Missing mixer case")
            }
            owner.updateChannel(channel)
            XCTAssertEqual(owner.document.channel, channel, property)
            XCTAssertGreaterThan(owner.document.revision.counter, before.revision.counter, property)
            f.root.terminate {}
        }
    }

    func testPerformanceAllowedOwnerMutatorsCaptureFitLoadSceneAndRelease() throws {
        let graph = MonitorGraph(), f = try MonitorRootFixture(graph: graph), owner = f.root.document
        defer { f.root.terminate {} }
        owner.canvas.updateWorkspace { workspace in
            workspace.updateSelectedLayer { $0.polarCells = [.init(ring: 10, angularIndex: 32)] }
            _ = workspace.addScene()
        }
        let scene = try XCTUnwrap(owner.document.scenes.first)
        owner.canvas.setPerformanceLocked(true)
        for action in InstrumentAction.allCases {
            XCTAssertEqual(owner.authorize(action), action != .edit)
        }
        owner.beginContinuousEdit(); owner.updateMasterLevel(-12); owner.endContinuousEdit()
        XCTAssertEqual(owner.document.masterLevelDecibels, -12)
        owner.selectScene(scene.id)
        let sceneDeadline = Date().addingTimeInterval(2)
        while owner.document.currentSceneID != scene.id, Date() < sceneDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertEqual(owner.document.currentSceneID, scene.id)
        owner.setRoomContourCaptureDuration(seconds: 2) // legacy value is ignored
        XCTAssertEqual(owner.contourCapture.durationSeconds, 5)
        owner.beginRoomContourCapture(); XCTAssertTrue(owner.isCapturingRoomContour)
        let session = UUID()
        let captureTime = MonotonicRuntimeClock().now + 3
        for sequence in 1...125 {
            let profile = try B0ScanProfile.build(partialScanIndex: 0,
                measurements: Array(repeating: try .build(value: 100, fieldFlags: 0), count: 90))
            let value = ProfileFrame(sessionID: session, sequence: UInt64(sequence), time: captureTime + Double(sequence - 1) / 25,
                measurements: try FullScanProfileAdapter.measurements(from: profile),
                geometry: try FullScanProfileAdapter.geometry(from: profile), rawProfile: profile)
            owner.roomCapture.receive(.frame(value))
            waitCapture(owner)
        }
        XCTAssertFalse(owner.isCapturingRoomContour); XCTAssertNotNil(owner.roomContour)
        XCTAssertTrue(owner.document.detection.roomContour.isEnabled)
        owner.setRoomFitMargin(centimeters: 5); XCTAssertEqual(owner.roomFitMarginCentimeters, 5)
        XCTAssertTrue(owner.canFitToRoom)
        let before = owner.document.spatial
        owner.fitToRoom(); XCTAssertNotEqual(owner.document.spatial, before)
        XCTAssertTrue(owner.canvas.isPerformanceLocked)
        owner.beginRoomContourCapture(); owner.cancelRoomContourCapture()
        XCTAssertFalse(owner.isCapturingRoomContour)
        owner.cancelOutputChange(); XCTAssertEqual(owner.outputChangeLossCount, 0)
        let frame = DisplayFrame(contour: owner.roomContour, selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]))
        owner.noteDisplay(frame); XCTAssertTrue(owner.roomFit.hasContour)
        owner.updateCanvasCommandContext(size: .init(width: 800, height: 600), profile: nil)
        XCTAssertTrue(owner.isEnabled(.zoomIn)); XCTAssertFalse(owner.isEnabled(.delete))
        XCTAssertGreaterThanOrEqual(owner.layersUsingChannel(owner.document.channel.id), 0)
        XCTAssertTrue(owner.perform(.zoomIn))
        owner.applyLegacyPresetViewport(.fullField)
        owner.applyPresetViewport(.init(owner.canvas.viewport))
        let snapshot = try owner.snapshotPresetDocument()
        try owner.applyPresetDocument(snapshot)
        XCTAssertTrue(owner.canvas.isPerformanceLocked)
        owner.panicAll(); owner.stopSpatialMode(); owner.stopSpatialAudio()
        XCTAssertEqual(graph.starts, 0)
    }

    func testPerformancePresetMenuKeyboardAndAlreadyOpenSheetsCannotWrite() throws {
        // NSMenu dispatch needs an application instance when this test runs
        // alone; earlier AppKit rendering tests used to initialize it for us.
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perform-presets-\(UUID().uuidString)")
        let rows: [(String, (PresetControlModel, InstrumentMenuController, URL) -> Void)] = [
            ("Save menu / ⌘S", { _, c, _ in c.save() }),
            ("Save As menu / ⌘⇧S", { _, c, _ in c.saveAs() }),
            ("Save As sheet / Return", { p, _, _ in p.commitSaveAs() }),
            ("Replace sheet", { p, _, _ in p.resolvePendingSave(confirmed: true) }),
            ("Description button", { p, _, _ in p.editDescription() }),
            ("Description editor already open", { p, _, _ in p.draftSummary = "Forbidden" }),
            ("Save As name already open", { p, _, _ in p.draftName = "Forbidden" }),
            ("Save As direct presentation", { p, _, _ in p.isSaveAsPresented = true }),
            ("Description direct presentation", { p, _, _ in p.isDescriptionEditorPresented = true }),
            ("Delete button", { p, _, _ in p.requestDelete("Own") }),
            ("Delete confirmation", { p, _, _ in p.resolvePendingDelete(confirmed: true) }),
            ("Delete direct", { p, _, _ in p.delete("Own") }),
            ("Export / ⌘⇧E", { p, _, url in p.export(to: url) }),
            ("Import / ⌘⇧I", { p, _, url in p.importFiles([url]) }),
            ("Save before loading", { p, _, _ in _ = p.load("Factory 00 Blank Channel", decision: .save) }),
            ("Save before quitting", { p, _, _ in _ = p.resolveTermination(.save) })
        ]
        for (index, row) in rows.enumerated() {
            let f = try MonitorRootFixture(), owner = f.root.document
            let store = PresetFileStore(directory: directory.appendingPathComponent("\(index)"))
            let presets = PresetControlModel(store: store, documentOwner: owner)
            presets.draftName = "Own"; XCTAssertTrue(presets.save())
            XCTAssertNotNil(presets.load("Own"))
            presets.beginSaveAs(); presets.editDescription()
            presets.requestDelete("Own")
            // Make the overwrite dialog pending while still in Edit.
            presets.draftName = "Other"; XCTAssertTrue(presets.save())
            presets.commitSaveAs()
            owner.canvas.renameSelectedLayer("Unsaved")
            let data = try store.load("Own"), before = owner.document
            let names = try store.list(), summary = presets.draftSummary, draft = presets.draftName
            let path = directory.appendingPathComponent("export-\(index).sickpreset.json")
            owner.canvas.setPerformanceLocked(true)
            row.1(presets, .init(instrument: owner, presets: presets), path)
            XCTAssertEqual(owner.document, before, row.0)
            XCTAssertEqual(try store.load("Own"), data, row.0)
            XCTAssertEqual(try store.list(), names, row.0)
            XCTAssertEqual(presets.draftSummary, summary, row.0)
            XCTAssertEqual(presets.draftName, draft, row.0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), row.0)
            XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason, row.0)
            f.root.terminate {}
        }
        let f = try MonitorRootFixture(), owner = f.root.document
        defer { f.root.terminate {} }
        let presets = PresetControlModel(store: .init(directory: directory.appendingPathComponent("load")), documentOwner: owner)
        owner.canvas.setPerformanceLocked(true)
        let target = PresetMenuTarget { _ = presets.load($0) }
        let menu = PresetSelectionMenu.make(names: presets.names, summaries: presets.menuSummaries,
            selected: presets.lastLoadedName, target: target)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Harmonie 01 Ruhe und Spannung" }))
        XCTAssertEqual(presets.lastLoadedName, "Harmonie 01 Ruhe und Spannung")
        XCTAssertTrue(owner.canvas.isPerformanceLocked)
        let command = InstrumentMenuController(instrument: owner, presets: presets)
        for route in ["Settings / ⌘,", "Import panel", "Export panel", "View / ⌘1–4"] {
            var invoked = false
            command.authoring { invoked = true }
            XCTAssertFalse(invoked, route)
            XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason, route)
        }
        var textUndo = 0, textRedo = 0
        command.undo(textResponder: { textUndo += 1 }); command.redo(textResponder: { textRedo += 1 })
        command.duplicateLayer(nil)
        command.duplicateLayer { textUndo += 1 }
        XCTAssertEqual(textUndo, 0); XCTAssertEqual(textRedo, 0)
        XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason)
        owner.canvas.setPerformanceLocked(false)
        command.undo(textResponder: { textUndo += 1 }); command.redo(textResponder: { textRedo += 1 })
        XCTAssertEqual(textUndo, 1); XCTAssertEqual(textRedo, 1)
    }

    func testPerformanceCanvasLayerKeyboardContextAndAssignmentMatrix() throws {
        let keys: [(UInt16, String, NSEvent.ModifierFlags)] = [
            (0, "a", .command), (0, "z", .command), (0, "z", [.command, .shift]),
            (0, "d", .command), (0, "c", .command), (0, "x", .command), (0, "v", .command),
            (51, "", []), (117, "", []), (123, "", []), (124, "", []), (125, "", []), (126, "", []),
            (0, "v", []), (0, "b", []), (0, "e", [])
        ]
        for layerList in [false, true] { for (code, text, modifiers) in keys {
            let f = try MonitorRootFixture(), owner = f.root.document
            let board = NSPasteboard.withUniqueName()
            board.setString("Keep clipboard", forType: .string)
            let field = CartesianScanFieldView(editor: owner.canvas, profile: nil,
                activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner,
                simulationBadge: AnyView(EmptyView()), cellPasteboard: board)
            let inspector = SpatialLayerInspectorView(editor: owner.canvas,
                audioUnits: .init(document: owner, source: EmptyCatalog()), midiOutput: f.root.midi,
                spatialInstrument: owner, evaluationCounter: nil)
            owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.polarCells = [.init(ring: 4, angularIndex: 32)] } }
            _ = owner.canvas.selectLayers([owner.canvas.workspace.selectedLayerID])
            let before = owner.document, selection = owner.canvas.selection
            owner.canvas.setPerformanceLocked(true)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            let handled = layerList ? inspector.handleLayerSelectionKey(event)
                : field.handleCanvasKey(event, canvasSize: .init(width: 800, height: 600))
            XCTAssertTrue(handled, "\(layerList) \(code) \(text)")
            XCTAssertEqual(owner.document, before); XCTAssertEqual(owner.canvas.selection, selection)
            XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason)
            XCTAssertEqual(board.string(forType: .string), "Keep clipboard")
            f.root.terminate {}
        } }
        let kinds: [SpatialCellBulkMenuItem.Kind] = [.selectLayer, .activate, .assignNote, .assignScalar,
            .removeActions, .deactivate, .erase, .duplicate, .paintHere, .moveToLayer(UUID())]
        for kind in kinds {
            let f = try MonitorRootFixture(), owner = f.root.document
            owner.canvas.setPerformanceLocked(true)
            let field = CartesianScanFieldView(editor: owner.canvas, profile: nil,
                activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner, simulationBadge: AnyView(EmptyView()))
            field.performContextAction(kind)
            XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason)
            XCTAssertTrue(SpatialCellBulkMenu.items(in: owner.canvas.presentation).isEmpty)
            XCTAssertFalse(owner.canvas.selectZone(at: .zero, canvasSize: .init(width: 800, height: 600)))
            XCTAssertFalse(owner.canvas.selectLayers([owner.canvas.workspace.selectedLayerID]))
            let before = owner.document
            var draft = SpatialAssignmentDraft.current(in: owner.canvas.presentation)
            draft.kind = .singleNote; draft.rootMIDINote = 67; draft.transition = .toggle
            XCTAssertFalse(owner.canvas.applyAssignment(draft))
            owner.canvas.updateWorkspace(named: "Snap") {
                var configuration = $0.detectionConfiguration
                configuration.cellSelection.boundaryMarginCentimeters = 5
                $0.setDetectionConfiguration(configuration)
            }
            XCTAssertEqual(owner.document, before)
            XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason)
            f.root.terminate {}
        }
    }

    func testPerformanceStaleCanvasCommandCannotBypassDocumentOwner() throws {
        let f = try MonitorRootFixture(), owner = f.root.document
        defer { f.root.terminate {} }
        let passiveSnapshot = owner.canvas.presentation
        var pending = owner.canvas.presentation
        pending.renameSelectedLayer("Prepared before Perform")
        let before = owner.document
        owner.canvas.setPerformanceLocked(true)
        owner.canvas.perform { $0 = pending }
        XCTAssertEqual(owner.document, before)
        XCTAssertTrue(owner.canvas.isPerformanceLocked)
        XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason)
        owner.canvas.perform { $0 = passiveSnapshot }
        XCTAssertTrue(owner.canvas.isPerformanceLocked, "A snapshot without a document command cannot restore Edit mode either")
        try owner.addChannel()
        XCTAssertEqual(owner.document, before)
    }

    func testPerformancePendingOutputConfirmationRemainsBlockedUntilEditReturns() throws {
        let f = try MonitorRootFixture(), owner = f.root.document
        defer { f.root.terminate {} }
        let layer = owner.document.spatial.layers[0], cell = PolarDeviceLattice(ring: 51, sector: 180)!
        try owner.edit { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [
            .init(id: layer.id, name: layer.name, color: layer.color, isVisible: true, isActive: true,
                isLocked: false, isSoloed: false, cells: [cell], routings: [.init(target: .midiNote(channel: 0), program: .constant(60))],
                cellOverrides: [cell: [.init(target: .midiNote(channel: 0), value: .note(number: 70, velocity: 88))]])], selectedLayerID: layer.id) }
        owner.canvas.setSelectedLayerTarget(.midiCC(channel: 0, controller: 74))
        XCTAssertEqual(owner.outputChangeLossCount, 1)
        let before = owner.document
        owner.canvas.setPerformanceLocked(true); owner.confirmOutputChange()
        XCTAssertEqual(owner.document, before); XCTAssertEqual(owner.outputChangeLossCount, 1)
        XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason)
        owner.canvas.setPerformanceLocked(false); owner.confirmOutputChange()
        XCTAssertNil(owner.notice)
        XCTAssertNotEqual(owner.document, before); XCTAssertEqual(owner.outputChangeLossCount, 0)
    }

    func testPerformanceNativeContextMenusOmitEveryAuthoringEntryAndStaleActionsAreGuarded() throws {
        for route in ["Layer", "Channel", "Scene"] {
            let f = try MonitorRootFixture(), owner = f.root.document
            owner.canvas.updateWorkspace {
                $0.updateSelectedLayer { $0.routings = [.init(target: .midiNote(channel: 0), program: .constant(60))] }
                _ = $0.addScene()
            }
            let sceneBar = SceneBarView(instrument: owner)
            let scene = try XCTUnwrap(owner.document.scenes.first)
            let catalog = AudioCatalogModel(document: owner, source: EmptyCatalog())
            let mixer = MixerView(instrument: owner, audioUnits: catalog, host: f.root.audio, midi: f.root.midi,
                devices: .init(host: f.root.audio))
            let inspector = SpatialLayerInspectorView(editor: owner.canvas, audioUnits: catalog,
                midiOutput: f.root.midi, spatialInstrument: owner, evaluationCounter: nil)
            let title = route
            func content() -> AnyView {
                if route == "Channel" { return AnyView(mixer.channelContextMenu(owner.document.channel)) }
                if route == "Scene" { return AnyView(sceneBar.sceneContextMenu(scene)) }
                return AnyView(inspector.layerContextMenu(owner.canvas.workspace.selectedLayer))
            }
            let host = NSHostingView(rootView: Menu(title) { content() }.menuStyle(.borderlessButton))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
            defer { window.close(); f.root.terminate {} }
            host.frame = .init(x: 0, y: 0, width: 300, height: 50)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            func popup(_ view: NSView) -> NSPopUpButton? {
                if let button = view as? NSPopUpButton { return button }
                return view.subviews.compactMap(popup).first
            }
            let button = try XCTUnwrap(popup(host)), menu = try XCTUnwrap(button.menu)
            let timer = Timer.scheduledTimer(timeInterval: 0.05, target: menu, selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .eventTracking); button.performClick(nil); timer.invalidate()
            menu.delegate?.menuWillOpen?(menu); menu.delegate?.menuNeedsUpdate?(menu); menu.update()
            let actions = menu.items.filter { $0.action != nil || $0.submenu != nil }
            XCTAssertFalse(actions.isEmpty, title)
            let before = owner.document
            owner.canvas.setPerformanceLocked(true)
            // Native menu targets retained from before the mode switch still
            // run the production closures, so each must check at invocation.
            func invoke(_ menu: NSMenu) {
                for index in menu.items.indices {
                    if let sub = menu.items[index].submenu {
                        sub.delegate?.menuWillOpen?(sub); sub.delegate?.menuNeedsUpdate?(sub); sub.update()
                        invoke(sub)
                    } else if menu.items[index].action != nil, menu.items[index].isEnabled, !menu.items[index].title.isEmpty {
                        owner.canvas.setPerformanceLocked(false); owner.canvas.setPerformanceLocked(true)
                        XCTAssertNil(owner.notice)
                        menu.performActionForItem(at: index)
                        XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason, "\(title): \(menu.items[index].title)")
                        XCTAssertEqual(owner.document, before, "\(title): \(menu.items[index].title)")
                    }
                }
            }
            invoke(menu)
            XCTAssertEqual(owner.document, before, title)
            XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason, title)
            host.rootView = Menu(title) { content() }.menuStyle(.borderlessButton)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            let lockedButton = try XCTUnwrap(popup(host)), locked = try XCTUnwrap(lockedButton.menu)
            let lockedTimer = Timer.scheduledTimer(timeInterval: 0.05, target: locked, selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
            RunLoop.main.add(lockedTimer, forMode: .eventTracking); lockedButton.performClick(nil); lockedTimer.invalidate()
            locked.delegate?.menuWillOpen?(locked); locked.delegate?.menuNeedsUpdate?(locked); locked.update()
            print("Perform \(title) menu: \(locked.items.map(\.title))")
            // SwiftUI inserts an empty native placeholder for EmptyView.
            XCTAssertTrue(locked.items.filter { !$0.title.isEmpty && ($0.action != nil || $0.submenu != nil) }.isEmpty, title)
            let field = CartesianScanFieldView(editor: owner.canvas, profile: nil,
                activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner, simulationBadge: AnyView(EmptyView()))
            XCTAssertTrue(field.handlePrimaryDoubleClick(at: .zero, canvasSize: .init(width: 800, height: 600), flags: []))
            inspector.beginLayerRename(owner.canvas.workspace.selectedLayerID)
            mixer.beginChannelRename(owner.document.channel)
            sceneBar.rename(scene)
            for action: SceneAuthoringAction in [.add, .update(scene.id), .rename(scene.id, "Forbidden"),
                .move(scene.id, -1), .move(scene.id, 1), .delete(scene.id),
                .membership(scene: scene.id, layer: owner.canvas.workspace.selectedLayerID)] {
                sceneBar.editScene(action)
            }
            XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason)
            XCTAssertEqual(owner.document, before)
        }
    }

    func testPerformanceLockAndAllowedControlsRenderWideAndNarrowOffline() throws {
        let graph = MonitorGraph(), f = try MonitorRootFixture(graph: graph)
        let layout = try LayoutWorkspaceFixture(fixture: f)
        defer { layout.cleanDefaults(); f.root.display.stop(); f.root.terminate {} }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for locked in [false, true] {
            if locked { layout.workspace.togglePerformance(canvas: f.root.document.canvas); try f.root.document.addChannel() }
            for width in [1728, 720] {
                try render(layout.view, width: width, height: 900,
                    name: "perform-lock-\(locked)-\(width).png", directory: directory)
            }
        }
        XCTAssertEqual(graph.starts, 0)
    }
    func testMuteButtonReleasesSceneLatchedOwnershipOnlyForItsLayerAt90And361() throws {
        for count in [90, 361] { for strip in [InstrumentChannel.legacyID, UUID()] { for transition: SpatialNoteTransition in [.toggle, .holdUntilNext] {
            let fixture = try MonitorRootFixture(), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            let cell = PolarDeviceLattice(ring: 100, sector: 180)!, a = UUID(), b = UUID(), session = UUID()
            func layer(_ id: UUID) -> SpatialDocumentLayer {
                .init(id: id, name: id == a ? "Mute me" : "Co-owner", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [cell],
                    routings: [.init(target: .audioUnitNote(channel: 0, stripID: strip), program: .chord(notes: [60], velocity: 100, transition: transition))], cellOverrides: [:])
            }
            var document = owner.document
            document.channels = [.init(), .init(id: strip == InstrumentChannel.legacyID ? UUID() : strip)]
            document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer(a), layer(b)], selectedLayerID: a)
            document.detection = .allStagesOff
            document.scenes = [.init(id: UUID(), name: "Scene", activeLayerIDs: [a, b]), .init(id: UUID(), name: "Silent scene", activeLayerIDs: [])]
            document.currentSceneID = document.scenes[0].id
            try owner.applyPresetDocument(document)
            fixture.root.runtime.attach(OutputPort(destination: .audioUnit(stripID: strip)) { _ in .sent })
            fixture.root.runtime.sessionBegan(session)
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            fixture.root.runtime.frame(.init(sessionID: session, sequence: 1, time: MonotonicRuntimeClock().now,
                measurements: [DeviceTickMeasurement(order: count / 2, ticks: geometry.tickSpan(at: count / 2)!, rawCentimeters: 100)!], geometry: geometry))
            func drain() { let e = expectation(description: "Runtime"); fixture.root.runtime.acknowledge { e.fulfill() }; wait(for: [e], timeout: 5) }
            drain(); XCTAssertEqual(fixture.root.runtime.mailbox.read()?.ports.first?.soundingNotes, 1)
            owner.selectScene(document.scenes[1].id); drain()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            owner.canvas.renameSelectedLayer("Name after scene switch")
            drain(); XCTAssertEqual(fixture.root.runtime.mailbox.read()?.ports.first?.soundingNotes, 1, "A scene change and unrelated edit preserve latched ownership")
            owner.selectScene(document.scenes[0].id); drain()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let inspector = SpatialLayerInspectorView(editor: owner.canvas,
                audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()), midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
            inspector.muteButton(try XCTUnwrap(owner.canvas.workspace.layers.first { $0.id == a })).action()
            drain(); XCTAssertEqual(fixture.root.runtime.mailbox.read()?.ports.first?.soundingNotes, transition == .toggle ? 1 : 0, "Toggle co-owner remains; Hold has only the muted winner and cannot resurrect the displaced owner")
            inspector.muteButton(try XCTUnwrap(owner.canvas.workspace.layers.first { $0.id == b })).action()
            drain(); XCTAssertEqual(fixture.root.runtime.mailbox.read()?.ports.first?.soundingNotes, 0, "Both explicit M buttons release")
            XCTAssertTrue(owner.document.spatial.layers.allSatisfy { !$0.isActive })
        } } }
    }
    func testActualInspectorMenuKeepsSecondStrip() throws {
        let graph = MonitorGraph()
        let fixture = try MonitorRootFixture(components: MenuPlugins(), graph: graph)
        let owner = fixture.root.document
        defer { fixture.root.terminate {} }
        var document = owner.document
        let second = UUID()
        document.channels.append(.init(instrument: .init(identity: MenuPlugins.identity), id: second, name: "Lead"))
        try owner.applyPresetDocument(document)
        owner.canvas.updateWorkspace { $0.updateSelectedLayer {
            $0.routings = [.init(target: .audioUnitNote(channel: 0, stripID: second), program: .constant(60))]
        } }
        let catalog = AudioCatalogModel(document: owner, source: EmptyCatalog())
        let deadline = Date().addingTimeInterval(5)
        while catalog.parameters(for: second).isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertEqual(catalog.parameters(for: second).map(\.displayName), ["Lead cutoff"])
        for removeFirst in [false, true] {
            if removeFirst { try owner.deleteChannel(InstrumentChannel.legacyID) }
            for path in [["Controls", "All Notes Off"], ["Controls", "Notes"], ["Controls", "CC 74"],
                         ["Controls", "Program Change"], ["Controls", "Pitch Bend"], ["Controls", "Pressure"],
                         ["Controls", "AU-Parameter", "Lead cutoff"], ["Output", "AU instrument"]] {
                let inspector = SpatialLayerInspectorView(editor: owner.canvas,
                    audioUnits: catalog, midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
                // This is the production row context-menu builder and action,
                // hosted as a native menu without opening the application.
                let host = NSHostingView(rootView: Menu("Layer") { inspector.layerContextMenu(owner.canvas.workspace.selectedLayer) }.menuStyle(.borderlessButton))
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
                host.frame = .init(x: 0, y: 0, width: 300, height: 50)
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)); host.displayIfNeeded()
                func popup(_ view: NSView) -> NSPopUpButton? {
                    if let button = view as? NSPopUpButton { return button }
                    return view.subviews.compactMap(popup).first
                }
                let button = try XCTUnwrap(popup(host))
                var menu = try XCTUnwrap(button.menu)
                let timer = Timer.scheduledTimer(timeInterval: 0.05, target: menu, selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
                RunLoop.main.add(timer, forMode: .eventTracking)
                button.performClick(nil)
                timer.invalidate()
                menu.delegate?.menuWillOpen?(menu)
                menu.delegate?.menuNeedsUpdate?(menu); menu.update()
                for title in path.dropLast() {
                    menu = try XCTUnwrap(menu.items.first { $0.title == title }?.submenu)
                    menu.delegate?.menuWillOpen?(menu)
                    menu.delegate?.menuNeedsUpdate?(menu); menu.update()
                }
                let index = try XCTUnwrap(menu.items.firstIndex { $0.title == path.last })
                XCTAssertTrue(menu.items[index].isEnabled)
                menu.performActionForItem(at: index)
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                XCTAssertEqual(owner.canvas.workspace.selectedLayer.routings.first?.target.stripID, second, "\(path), Ch 1 removed=\(removeFirst)")
                XCTAssertEqual(owner.document.spatial.layers.first?.routings.first?.target.stripID, second)
                print("Native row menu \(path.joined(separator: " → ")): Ch 2 retained, Ch 1 removed=\(removeFirst)")
                let target = try XCTUnwrap(owner.canvas.workspace.selectedLayer.routings.first?.target)
                switch path.last {
                case "All Notes Off": XCTAssertEqual(target, .audioUnitAllNotesOff(channel: 0, stripID: second))
                case "CC 74": XCTAssertEqual(target, .audioUnitCC(channel: 0, controller: 74, stripID: second))
                case "Program Change":
                    XCTAssertEqual(target, .audioUnitProgramChange(channel: 0, stripID: second))
                    guard case .programChange = owner.document.spatial.layers.first?.routings.first?.program else {
                        XCTFail("The actual Program Change menu action must install a program selection"); continue
                    }
                case "Pitch Bend": XCTAssertEqual(target, .audioUnitPitchBend(channel: 0, stripID: second))
                case "Pressure": XCTAssertEqual(target, .audioUnitChannelPressure(channel: 0, stripID: second))
                case "Lead cutoff", "AU instrument": XCTAssertEqual(target, .audioUnitParameter(.init(component: MenuPlugins.identity, address: 42, identifier: "cutoff", displayName: "Lead cutoff", stripID: second)))
                default: if case .audioUnitNote = target {} else { XCTFail("Native menu action did not select Notes") }
                }
            }
        }
        XCTAssertEqual(graph.starts, 0)
    }
    func testMixerZeroOneTwoEightWideNarrowOutputMissingAndPerformanceThreeOffline() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph)
        let owner = fixture.root.document
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop(); fixture.root.terminate {} }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for count in [0, 1, 2, 8] {
            var document = owner.document
            document.channels = (0..<count).map { index in
                .init(id: index == 0 ? InstrumentChannel.legacyID : UUID(),
                      name: index == 0 ? "Pads" : index == 1 ? "Lead" : "Ch \(index + 1)",
                      color: index.isMultiple(of: 2) ? .blue : .orange)
            }
            let firstID = document.channels.first?.id ?? SpatialRoutingTarget.missingStripID
            try owner.applyPresetDocument(document)
            owner.canvas.updateWorkspace { workspace in
                workspace.updateSelectedLayer {
                    $0.routings = [.init(target: .audioUnitNote(channel: 0, stripID: firstID), program: .constant(60))]
                }
            }
            for width in [2160, 900] {
                try render(layout.view, width: width, height: 1050,
                           name: "mixer-\(count)-\(width).png", directory: directory)
            }
            for width in [72 * (count + 1), min(216, 72 * (count + 1))] {
                try render(MixerView(instrument: owner, audioUnits: layout.view.audioUnits, host: fixture.root.audio,
                    midi: fixture.root.midi, devices: layout.view.audioDevices), width: width, height: 760,
                    name: "mixer-detail-\(count)-\(width).png", directory: directory)
            }
            try render(MixerView(instrument: owner, audioUnits: layout.view.audioUnits, host: fixture.root.audio,
                midi: fixture.root.midi, devices: layout.view.audioDevices), width: min(216, 72 * (count + 1)), height: 760,
                name: "mixer-detail-\(count)-narrow-sum.png", directory: directory)
        }
        let catalog = AudioCatalogModel(document: owner, source: EmptyCatalog())
        for missing in [false, true] {
            let id = missing ? UUID() : owner.document.channels[1].id
            owner.canvas.updateWorkspace { workspace in
                workspace.updateSelectedLayer {
                    $0.routings = [.init(target: .audioUnitNote(channel: 0, stripID: id), program: .constant(64))]
                }
            }
            try render(SpatialLayerInspectorView(editor: owner.canvas,
                audioUnits: catalog, midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil),
                width: 300, height: 1000, name: "output-\(missing ? "missing" : "chosen").png", directory: directory)
        }
        var document = owner.document; document.channels = Array(document.channels.prefix(3))
        try owner.applyPresetDocument(document)
        layout.workspace.togglePerformance(canvas: owner.canvas)
        try render(layout.view, width: 1120, height: 900, name: "performance-3.png", directory: directory)
        try render(layout.view, width: 720, height: 900, name: "performance-3-narrow-sum.png", directory: directory)
        XCTAssertEqual(graph.starts, 0)
    }
    /// Owner 12.10.2026: nach Löschen eines Kanalzugs blieb das Mischpult
    /// breit, bis es zu- und aufgeklappt wurde. Ein bestehendes Fenster muss
    /// danach genauso aussehen wie ein frisch aufgebautes.
    func testLiveWindowMixerFollowsDeletedChannelsLikeAFreshWindow() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph)
        let owner = fixture.root.document
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop(); fixture.root.terminate {} }
        var document = owner.document
        document.channels = (0..<4).map { index in
            .init(id: index == 0 ? InstrumentChannel.legacyID : UUID(), name: "Ch \(index + 1)", color: .blue)
        }
        try owner.applyPresetDocument(document)
        let live = Self.host(layout.view)
        _ = try Self.snapshot(live)
        try owner.deleteChannel(owner.document.channels[3].id)
        try owner.deleteChannel(owner.document.channels[2].id)
        let afterDelete = try Self.snapshot(live)
        let fresh = try Self.snapshot(Self.host(layout.view))
        XCTAssertEqual(afterDelete.pixelsWide, fresh.pixelsWide)
        var differing = 0
        for y in stride(from: 0, to: fresh.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: fresh.pixelsWide, by: 2) where afterDelete.colorAt(x: x, y: y) != fresh.colorAt(x: x, y: y) {
                differing += 1
            }
        }
        // Breites Restmischpult verschiebt ganze Bereiche (> 10 % der Fläche);
        // erlaubt sind nur Kleinstunterschiede wie Einfügemarke oder Pegel.
        XCTAssertLessThan(Double(differing) / Double(fresh.pixelsWide * fresh.pixelsHigh / 4), 0.01)
        XCTAssertEqual(graph.starts, 0)
    }
    private static func host<V: View>(_ view: V) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark).background(StageTheme.workspace))
        host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
        host.frame = .init(x: 0, y: 0, width: 2160, height: 1050)
        return host
    }
    private static func snapshot(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
    private func haltenPreset(_ fixture: MonitorRootFixture) throws -> InstrumentDocument {
        let owner = fixture.root.document
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmony 16 Third Chain"))
        try owner.applyPresetDocument(try PresetDocumentReader.read(data).get().replacing(owner.document))
        let catalog = AudioCatalogModel(document: owner, source: EmptyCatalog())
        for layer in owner.document.spatial.layers {
            owner.canvas.selectLayers([layer.id], active: layer.id)
            let inspector = SpatialLayerInspectorView(editor: owner.canvas, audioUnits: catalog,
                midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
            inspector.transitionBinding.wrappedValue = 3
        }
        let document = owner.document
        for layer in document.spatial.layers {
            guard case .chord(_, _, .holdUntilNext) = layer.routings[0].program else { XCTFail("Inspector transition was not applied"); continue }
        }
        return document
    }
    func testHaltenWechselPresetInspectorProfilesAndRouter90And361() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph)
        defer { fixture.root.terminate {} }
        var document = try haltenPreset(fixture)
        document.detection = .allStagesOff
        let instrument = try InstrumentCompiler.compile(document), layers = document.spatial.layers
        let chords: [[UInt8]] = [[62, 65, 69], [60, 65, 69], [60, 64, 69], [60, 64, 67], [59, 64, 67], [59, 62, 67], [59, 62, 66]]
        for count in [90, 361] {
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            let orders = try layers.map { layer in
                let sectors = layer.cells.filter { $0.ring == 100 }.map(\.sector)
                let middle = ((sectors.min() ?? 0) + (sectors.max() ?? 0)) / 2
                return try XCTUnwrap((0..<count).sorted { a, b in
                    return abs(geometry.tickSpan(at: a)!.lower - middle) < abs(geometry.tickSpan(at: b)!.lower - middle)
                }.first { order in
                    let tick = geometry.tickSpan(at: order)!
                    return layer.cells.contains(PolarDeviceLattice(ring: 100, sector: (tick.lower + tick.upper) / 2)!)
                })
            }
            let session = UUID()
            func frame(_ active: Set<Int>, _ n: UInt64) -> ProfileFrame {
                .init(sessionID: session, sequence: n, time: Double(n) / 25,
                    measurements: active.sorted().map { DeviceTickMeasurement(order: orders[$0], ticks: geometry.tickSpan(at: orders[$0])!, rawCentimeters: 100)! }, geometry: geometry)
            }
            func start() -> PlayState { PlayEngine.step(PlayEngine.step(.init(), .install(instrument)).0, .sessionBegan(session)).0 }
            for pair in [(4, 3), (2, 3), (3, 4), (0, 5), (0, 3)] { for slow in [false, true] {
                var state = start(), router = OutputRouter()
                let receipt = HaltenReceipt()
                router.attach(OutputPort(destination: .audioUnit(stripID: document.channel.id)) { receipt.send($0) })
                let sequence: [Set<Int>] = [[pair.0], slow ? [pair.0, pair.1] : [], [pair.1], [], []]
                for (index, active) in sequence.enumerated() {
                    let result = PlayEngine.step(state, .frame(frame(active, UInt64(index + 1)))); state = result.0
                    router.route(result.1, sounding: state.soundingEvents, allowOn: true)
                    let winner = index == 0 || (!slow && index == 1) ? pair.0 : pair.1
                    XCTAssertEqual(receipt.sounding, Set(chords[winner]), "\(count), \(pair), slow \(slow), frame \(index)")
                    XCTAssertEqual(router.display.first?.soundingNotes, 3)
                    if !active.isEmpty {
                        XCTAssertEqual(Set(state.selection.sceneControlHandles.map(\.layerID)), Set(active.map { layers[$0].id }))
                        XCTAssertEqual(Set(state.selection.measuredEntryHandles.map(\.layerID)), Set(active.map { layers[$0].id }))
                    }
                }
            } }
            // One MMK span can straddle Am/C; 361 uses the two adjacent
            // measured rays. Both are a real measured boundary transition.
            let amTicks = layers[2].cells.filter { $0.ring == 100 }.map(\.sector)
            let cTicks = layers[3].cells.filter { $0.ring == 100 }.map(\.sector)
            let boundary = try XCTUnwrap(cTicks.min())
            let edgeOrders: [Int]
            if count == 90 {
                edgeOrders = [try XCTUnwrap((0..<count).first { order in
                    let span = geometry.tickSpan(at: order)!
                    return span.lower < boundary && span.upper >= boundary
                })]
            } else { edgeOrders = [try XCTUnwrap(amTicks.max()), boundary] }
            var boundaryState = PlayEngine.step(start(), .frame(frame([2], 1))).0
            let edge = ProfileFrame(sessionID: session, sequence: 2, time: 0.08,
                measurements: edgeOrders.map { DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: 100)! }, geometry: geometry)
            boundaryState = PlayEngine.step(boundaryState, .frame(edge)).0
            XCTAssertEqual(Set(boundaryState.selection.sceneControlHandles.map(\.layerID)), [layers[2].id, layers[3].id])
            XCTAssertEqual(Set(boundaryState.soundingEvents.compactMap { event -> UInt8? in
                if case .noteOn(_, _, let note) = event { return note.number }; return nil
            }), Set(chords[3]))
            var state = start(), previous: Set<Int> = [], winner: Int?, random: UInt64 = 0xC0FFEE
            for n in 1...400 {
                random = random &* 6364136223846793005 &+ 1
                let active = Set(layers.indices.filter { (random >> 32) & (1 << $0) != 0 })
                if let fresh = active.subtracting(previous).min() { winner = fresh }
                state = PlayEngine.step(state, .frame(frame(active, UInt64(n)))).0
                let notes = Set(state.soundingEvents.compactMap { event -> UInt8? in if case .noteOn(_, _, let note) = event { return note.number }; return nil })
                XCTAssertEqual(notes, winner.map { Set(chords[$0]) } ?? [], "Random frame \(n), \(count)")
                previous = active
            }
        }
        XCTAssertEqual(graph.starts, 0)
    }
    func testHaltenWechselInspectorEditsReachInstalledRuntimeAndOutputRouter() throws {
        for count in [90, 361] {
            let clock = ShortcutTempoClock(); clock.set(10)
            let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph, clock: clock)
            defer { fixture.root.terminate {} }
            let owner = fixture.root.document
            let document = try haltenPreset(fixture)
            owner.updateDetectionConfiguration(.allStagesOff)
            let receipt = HaltenReceipt()
            fixture.root.runtime.attach(OutputPort(destination: .audioUnit(stripID: document.channel.id)) { receipt.send($0) })
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            let orders = document.spatial.layers.map { layer -> Int in
                let sectors = layer.cells.filter { $0.ring == 100 }.map(\.sector)
                let middle = (sectors.min()! + sectors.max()!) / 2
                return (0..<count).min { abs(geometry.tickSpan(at: $0)!.lower - middle) < abs(geometry.tickSpan(at: $1)!.lower - middle) }!
            }
            let chords: [[UInt8]] = [[62, 65, 69], [60, 65, 69], [60, 64, 69], [60, 64, 67], [59, 64, 67], [59, 62, 67], [59, 62, 66]]
            func drain() {
                let done = expectation(description: "Installed runtime")
                fixture.root.runtime.acknowledge { done.fulfill() }
                wait(for: [done], timeout: 10)
            }
            // No manual compile/install: these are the plans installed by
            // the real inspector edit path, including its reuse decision.
            for pair in [(4, 3), (2, 3), (3, 4), (0, 5), (0, 3)] { for slow in [false, true] {
                let session = UUID()
                fixture.root.runtime.sessionBegan(session)
                let sequence: [Set<Int>] = [[pair.0], slow ? [pair.0, pair.1] : [], [pair.1], []]
                for (index, active) in sequence.enumerated() {
                    fixture.root.runtime.frame(.init(sessionID: session, sequence: UInt64(index + 1), time: 10 + Double(index) / 25,
                        measurements: active.sorted().map { DeviceTickMeasurement(order: orders[$0], ticks: geometry.tickSpan(at: orders[$0])!, rawCentimeters: 100)! }, geometry: geometry))
                    drain()
                    let winner = index == 0 || (!slow && index == 1) ? pair.0 : pair.1
                    XCTAssertEqual(receipt.sounding, Set(chords[winner]), "Installed path, \(count), \(pair), slow \(slow), frame \(index)")
                }
                fixture.root.runtime.sessionEnded(session); drain()
                XCTAssertTrue(receipt.sounding.isEmpty)
            } }
            XCTAssertEqual(graph.starts, 0)
        }
    }
    func testHaltenWechselOwnerRecordingReplayThroughOutputRouter() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(".agent_handoff/runs/halten-wechsel/aufnahme-em-c.json")
        let preset = root.appendingPathComponent(".agent_handoff/runs/halten-wechsel/Harmony 16 Third Chain Keller.sickpreset.json")
        guard FileManager.default.fileExists(atPath: path.path), FileManager.default.fileExists(atPath: preset.path) else {
            throw XCTSkip("External Owner recording and edited Keller preset must be supplied together")
        }
        let recording = try JSONDecoder().decode(ProfileRecording.self, from: Data(contentsOf: path))
        XCTAssertEqual(recording.scans.count, 251)
        var document = try PresetDocumentReader.read(Data(contentsOf: preset)).get().replacing(fixture.root.document.document)
        XCTAssertEqual(document.spatial.layers.count, 8)
        XCTAssertEqual(document.editorGrid.cellSizeMeters, 0.05)
        // Use capture-time detection/room settings with the saved spatial masks.
        document.detection = recording.detection
        let instrument = try InstrumentCompiler.compile(document), receipt = HaltenReceipt()
        var state = PlayEngine.step(.init(), .install(instrument)).0, router = OutputRouter(), rows = ["frame\tactive\tsounding\tcommands"]
        router.attach(OutputPort(destination: .audioUnit(stripID: document.channel.id)) { receipt.send($0) })
        state = PlayEngine.step(state, .roomContour(recording.contour)).0
        state = PlayEngine.step(state, .sessionBegan(try XCTUnwrap(recording.scans.first).sessionID)).0
        var sawEm = false, sawC = false
        for scan in recording.scans {
            let result = PlayEngine.step(state, .frame(try scan.frame())); state = result.0
            router.route(result.1, sounding: state.soundingEvents, allowOn: true)
            let sounding = receipt.sounding
            if sounding == [59, 64, 67] { sawEm = true }
            if sawEm && sounding == [60, 64, 67] { sawC = true }
            XCTAssertLessThanOrEqual(sounding.count, 3, "Frame \(scan.sequence)")
            do {
                let controls = document.spatial.layers.filter { layer in state.selection.sceneControlHandles.contains { $0.layerID == layer.id } }.map(\.name).joined(separator: ",")
                let active = document.spatial.layers.filter { state.selection.activeHandles[$0.id] != nil }.map(\.name).joined(separator: ",")
                rows.append("\(scan.sequence)\t\(active) controls=\(controls)\t\(sounding.sorted())\t\(result.1)")
            }
        }
        XCTAssertTrue(sawEm, "Owner geometry must produce Em")
        XCTAssertTrue(sawC, "A later measured entry must replace Em with C")
        XCTAssertEqual(receipt.sounding, [60, 64, 67], "Recording ends with C alone")
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rows.joined(separator: "\n").write(to: directory.appendingPathComponent("halten-replay.tsv"), atomically: true, encoding: .utf8)
    }
    func testCommonNotesInspectorPersistenceUndoAndOfflineImages() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        _ = try haltenPreset(fixture)
        let catalog = AudioCatalogModel(document: owner, source: EmptyCatalog())
        let inspector = SpatialLayerInspectorView(editor: owner.canvas, audioUnits: catalog,
            midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for policy in SpatialCommonNotes.allCases {
            let before = owner.document
            inspector.setCommonNotes(policy)
            if policy == .retrigger { XCTAssertFalse(InstrumentCompiler.canReuseIndex(from: before, for: owner.document)) }
            XCTAssertEqual(owner.document.spatial.layers.first { $0.id == owner.canvas.workspace.selectedLayerID }?.commonNotes, policy)
            let compiled = try InstrumentCompiler.compile(owner.document)
            XCTAssertEqual(compiled.layers.first { $0.id == owner.canvas.workspace.selectedLayerID }?.routings.first?.commonNotes, policy)
            for width in [280, 420] {
                try render(inspector, width: width, height: 1000, name: "common-\(policy)-\(width).png", directory: directory)
            }
        }
        let saved = try JSONEncoder().encode(InstrumentPresetV6(name: "Common", document: owner.document))
        let restored = try PresetDocumentReader.read(saved).get().replacing(owner.document)
        XCTAssertEqual(restored.spatial.layers.first { $0.id == owner.canvas.workspace.selectedLayerID }?.commonNotes, .retrigger)
        owner.undo()
        XCTAssertEqual(owner.canvas.workspace.selectedLayer.commonNotes, .keep)
        owner.redo()
        XCTAssertEqual(owner.canvas.workspace.selectedLayer.commonNotes, .retrigger)
        owner.canvas.setPerformanceLocked(true)
        inspector.setCommonNotes(.keep)
        XCTAssertEqual(owner.canvas.workspace.selectedLayer.commonNotes, .retrigger)
        for width in [280, 420] {
            try render(inspector, width: width, height: 1000, name: "common-perform-\(width).png", directory: directory)
        }
        XCTAssertTrue(inspector.commonNotesHelp.contains("Note-Off then Note-On"))
        XCTAssertEqual(graph.starts, 0)
    }

    private func render<V: View>(_ view: V, width: Int, height: Int, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark).background(StageTheme.workspace))
        host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: directory.appendingPathComponent(name))
    }
}

@MainActor private final class MenuPlugins: PluginComponentSource {
    static let identity = SpatialAudioUnitIdentity(componentType: 0x61756D75, componentSubType: 2, componentManufacturer: 3)
    private(set) var loads = 0
    func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        loads += 1; completion(.success(MenuUnit()))
    }
}
@MainActor private final class MenuUnit: PluginUnit {
    var audioNode: AVAudioUnit? { nil }
    var parameterDescriptors: [AudioUnitParameterDescriptor] {
        [.init(componentType: MenuPlugins.identity.componentType, componentSubType: 2, componentManufacturer: 3, address: 42,
               identifier: "cutoff", displayName: "Lead cutoff", minimumValue: 0, maximumValue: 1, unitName: nil)]
    }
    func readState() throws -> Data { Data() }
    func setState(_ state: Data) throws {}
    func setBypass(_ bypassed: Bool) {}
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary { MenuSchedule() }
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void) { XCTFail("No real editor in offline menu test") }
}
private struct MenuSchedule: AUScheduleBoundary {
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { .sent }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
}

@MainActor private func waitCapture(_ owner: SpatialInstrumentRuntimeModel) {
    let done = DispatchSemaphore(value: 0)
    owner.roomCapture.acknowledge { done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}

private final class HaltenReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: Set<UInt8> = []
    var sounding: Set<UInt8> { lock.lock(); defer { lock.unlock() }; return notes }
    func send(_ event: MusicEvent) -> PortSendResult {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .noteOn(_, _, let note): notes.insert(note.number)
        case .noteOff(_, _, let note): notes.remove(note.number)
        case .allNotesOff: notes.removeAll()
        default: break
        }
        return .sent
    }
}
