import AppKit
import SwiftUI
import XCTest
import PlanariumApplication
import PlanariumDomain
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class CanvasEditingUITests: XCTestCase {
    let size = CGSize(width: 800, height: 800)
    let cell = PolarMetricGridCell(ring: 2, angularIndex: 8)

    func install(_ owner: SpatialInstrumentRuntimeModel) {
        let a = SpatialInstrumentLayer(name: "A", color: .orange,
            routings: [.init(target: .midiNote(channel: 0), program: .constant(1))])
        let b = SpatialInstrumentLayer(name: "B", color: .blue, polarCells: [cell],
            routings: [.init(target: .midiNote(channel: 1), program: .constant(1))],
            polarCellOverrides: [cell: [.init(target: .midiNote(channel: 1), value: .note(number: 64, velocity: 90))]])
        owner.canvas.replaceWorkspace(.init(grid: .quarterMeter, layers: [a, b]))
    }

    func field(_ owner: SpatialInstrumentRuntimeModel) -> CartesianScanFieldView {
        .init(editor: owner.canvas, profile: nil,
            activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner,
            simulationBadge: AnyView(Text("Offline")), detectionInitiallyExpanded: true)
    }

    func point(_ owner: SpatialInstrumentRuntimeModel) -> CGPoint {
        let segment = PolarMetricCellSegment(cell: cell, grid: owner.canvas.workspace.grid)
        return MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for:
            segment.point(radiusMeters: segment.midpoint.radiusMeters, bearingDegrees: segment.midpoint.bearingDegrees))
    }

    func key(_ code: UInt16, window: NSWindow, characters: String = "", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testOwnerRectangleContextAndNativeBackspaceDeleteBWithAUnchanged() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        for path in ["menu", "rectangle-key", "right-key"] {
            install(owner)
            let originalA = owner.canvas.workspace.layers[0], bID = owner.canvas.workspace.layers[1].id, center = point(owner)
            if path == "right-key" { _ = owner.canvas.contextMenuSelection(at: center, canvasSize: size) }
            else {
                _ = owner.canvas.beginDrag(at: .init(x: center.x - 12, y: center.y - 12), canvasSize: size)
                _ = owner.canvas.updateDrag(to: .init(x: center.x + 12, y: center.y + 12), canvasSize: size)
                owner.canvas.endDrag(canvasSize: size)
            }
            let view = field(owner)
            if path == "menu" { view.performContextAction(.erase) }
            else {
                let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                let pointer = ScanFieldPointerEvents.PointerView(frame: .init(origin: .zero, size: size))
                pointer.onKeyCommand = { view.handleCanvasKey($0, canvasSize: self.size) }
                window.contentView = pointer
                XCTAssertTrue(window.makeFirstResponder(pointer))
                XCTAssertNil(pointer.handle(try key(51, window: window)))
                pointer.stopListening(); window.contentView = nil
            }
            XCTAssertEqual(owner.canvas.workspace.layers[0], originalA)
            XCTAssertTrue(owner.canvas.workspace.layers[1].polarCells.isEmpty)
            XCTAssertTrue(owner.canvas.workspace.layers[1].polarCellOverrides.isEmpty)
            XCTAssertTrue(owner.undo())
            XCTAssertEqual(owner.canvas.workspace.layers.first { $0.id == bID }?.polarCells.contains(cell), true)
        }
    }

    func testRightMouseFocusAndTextResponderGuardThroughNativePointer() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        install(owner)
        let view = field(owner)
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let pointer = ScanFieldPointerEvents.PointerView(frame: .init(origin: .zero, size: size))
        window.contentView = pointer
        pointer.onKeyCommand = { view.handleCanvasKey($0, canvasSize: self.size) }
        pointer.onSecondaryClick = { _ = owner.canvas.contextMenuSelection(at: $0, canvasSize: self.size) }
        let center = point(owner), location = pointer.convert(center, to: nil)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            _ = pointer.handle(event)
        }
        XCTAssertTrue(window.firstResponder === pointer)
        XCTAssertEqual(owner.canvas.selectedCells.count, 1)
        let editor = NSTextView(frame: .init(x: 10, y: 10, width: 80, height: 20))
        pointer.addSubview(editor); XCTAssertTrue(window.makeFirstResponder(editor))
        let event = try key(51, window: window)
        XCTAssertNotNil(pointer.handle(event)); XCTAssertTrue(owner.canvas.workspace.layers[1].polarCells.contains(cell))
        pointer.stopListening(); window.contentView = nil
    }

    func testLayerListDeleteUsesMarkedCellsAndCommandDStillDuplicatesLayer() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        install(owner)
        let view = LayerInspectorView(editor: owner.canvas,
            audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()), midiOutput: fixture.root.midi,
            spatialInstrument: owner, evaluationCounter: nil)
        view.selectLayerForInspection(owner.canvas.workspace.layers[1].id)
        XCTAssertEqual(owner.canvas.selectedCells.count, 1)
        XCTAssertEqual(view.effectiveSelectedLayerIDs, [owner.canvas.workspace.layers[1].id])
        owner.canvas.updateWorkspace { $0.updateLayer($0.layers[0].id) { $0.polarCells = [self.cell] } }
        _ = owner.canvas.perform(.selectAll)
        XCTAssertEqual(view.effectiveSelectedLayerIDs.count, 2)
        _ = owner.canvas.selectCell(atScreenPoint: point(owner), canvasSize: size)
        XCTAssertEqual(view.effectiveSelectedLayerIDs, [owner.canvas.workspace.layers[1].id], "List and field share one selection")
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let pointer = ScanFieldPointerEvents.PointerView(frame: .init(origin: .zero, size: size))
        pointer.onKeyCommand = { view.handleLayerSelectionKey($0) }
        window.contentView = pointer; XCTAssertTrue(window.makeFirstResponder(pointer))
        let beforeMove = owner.canvas.workspace
        XCTAssertNil(pointer.handle(try key(126, window: window)))
        XCTAssertNotEqual(owner.canvas.workspace, beforeMove, "List-selected cells must be movable without a reducing field click")
        XCTAssertTrue(owner.undo())
        _ = owner.canvas.selectLayers([owner.canvas.workspace.layers[1].id])
        XCTAssertNil(pointer.handle(try key(51, window: window)))
        XCTAssertTrue(owner.canvas.workspace.layers[1].polarCells.isEmpty)
        XCTAssertTrue(owner.undo())
        XCTAssertNil(pointer.handle(try key(2, window: window, characters: "d", flags: .command)))
        XCTAssertEqual(owner.canvas.workspace.layers.count, 3)
        pointer.stopListening(); window.contentView = nil
    }

    func testCanvasToolShortcutsShiftArrowsSpaceAndNativeDuplicateUseProductionHandler() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        install(owner); _ = owner.canvas.perform(.selectAll)
        let view = field(owner), window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertTrue(view.handleCanvasKey(try key(11, window: window, characters: "b"), canvasSize: size))
        XCTAssertEqual(owner.canvas.tool, .paint)
        XCTAssertTrue(view.handleCanvasKey(try key(49, window: window, characters: " "), canvasSize: size))
        XCTAssertEqual(owner.canvas.effectiveTool, .pan)
        owner.canvas.holdHand(false)
        XCTAssertEqual(owner.canvas.effectiveTool, .paint)
        XCTAssertTrue(view.handleCanvasKey(try key(126, window: window, flags: .shift), canvasSize: size))
        XCTAssertTrue(owner.canvas.moveHitBoundary)
        XCTAssertEqual(owner.canvas.workspace.layers[1].polarCells.map(\.ring).max(), 7)
    }

    func testNativeCellClipboardCutPasteDuplicateUndoAndForeignContentUseProductionKeys() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        install(owner); _ = owner.canvas.perform(.selectAll)
        let before = owner.canvas.workspace
        var view = field(owner)
        let board = NSPasteboard(name: .init("de.planarium.canvas-test.\(UUID().uuidString)"))
        view.cellPasteboard = board
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        for characters in ["c", "x", "v"] {
            XCTAssertTrue(view.handleCanvasKey(try key(8, window: window, characters: characters, flags: .command), canvasSize: size))
            if characters == "c" {
                let data = try XCTUnwrap(board.data(forType: .init("de.planarium.cells")))
                let copies = try JSONDecoder().decode([CanvasCellCopy].self, from: data)
                XCTAssertEqual(copies.count, 1)
                XCTAssertEqual(copies[0].layerID, before.layers[1].id)
                XCTAssertEqual(copies[0].actions, before.layers[1].polarCellOverrides[cell])
            } else if characters == "x" { XCTAssertTrue(owner.canvas.workspace.layers[1].polarCells.isEmpty) }
        }
        XCTAssertEqual(owner.canvas.workspace, before)
        XCTAssertTrue(view.handleCanvasKey(try key(2, window: window, characters: "d", flags: .command), canvasSize: size))
        XCTAssertEqual(owner.canvas.workspace.layers.count, 2)
        XCTAssertGreaterThan(owner.canvas.workspace.layers[1].polarCells.count, 1)
        XCTAssertTrue(view.handleCanvasKey(try key(6, window: window, characters: "z", flags: .command), canvasSize: size))
        XCTAssertEqual(owner.canvas.workspace, before)
        board.clearContents(); board.setString("Foreign", forType: .string)
        XCTAssertTrue(view.handleCanvasKey(try key(9, window: window, characters: "v", flags: .command), canvasSize: size))
        XCTAssertEqual(owner.canvas.workspace, before)
        XCTAssertEqual(owner.canvas.statusMessage, "No cells in clipboard")
    }

    func testEmptyUndoAndRedoExplainNoEffectThroughProductionKeyboard() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        XCTAssertFalse(owner.canUndo); XCTAssertFalse(owner.canRedo)
        let before = owner.canvas.workspace, view = field(owner)
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertTrue(view.handleCanvasKey(try key(6, window: window, characters: "z", flags: .command), canvasSize: size))
        XCTAssertEqual(owner.canvas.statusMessage, "Nothing to undo")
        XCTAssertTrue(view.handleCanvasKey(try key(6, window: window, characters: "z", flags: [.command, .shift]), canvasSize: size))
        XCTAssertEqual(owner.canvas.statusMessage, "Nothing to redo")
        XCTAssertEqual(owner.canvas.workspace, before)
    }

    func testEveryToolSelectionStatusAndMenuWideNarrowOfflineImages() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        install(owner)
        owner.canvas.updateWorkspace { workspace in
            workspace.updateLayer(workspace.layers[0].id) { $0.polarCells = [.init(ring: 3, angularIndex: 16)] }
        }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = owner.canvas.workspace
        for phase in ["select", "paint", "erase", "hand", "two-layers", "status", "menu"] {
            owner.canvas.replaceWorkspace(base)
            owner.canvas.select(tool: phase == "paint" ? .paint : phase == "erase" ? .erase : phase == "hand" ? .pan : .select)
            if phase == "two-layers" || phase == "menu" { _ = owner.canvas.perform(.selectAll) }
            if phase == "status" {
                owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.isLocked = true } }
                owner.canvas.select(tool: .paint)
                _ = owner.canvas.beginDrag(at: point(owner), canvasSize: size)
                XCTAssertTrue(owner.canvas.statusMessage?.contains("locked") == true)
            }
            for width in [1120, 420] {
                let view = field(owner).overlay(alignment: .trailing) {
                    if phase == "menu" { CanvasMenuImage(state: owner.canvas.presentation).padding(20) }
                }
                let host = NSHostingView(rootView: view.preferredColorScheme(.dark).padding(10).background(StageTheme.workspace))
                host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
                host.frame = .init(x: 0, y: 0, width: width, height: width == 420 ? 1400 : 1000)
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.08)); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    directory.appendingPathComponent("canvas-\(phase)-\(width).png"))
            }
        }
        XCTAssertEqual(graph.starts, 0)
    }

    // Native UI behavior is covered by CanvasWindowContractTests.
}

/// Offline menu image uses the exact same titles and enablement as NSMenu.
private struct CanvasMenuImage: View {
    let state: MetricCanvasInteractionState
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(SpatialCellBulkMenu.items(in: state).enumerated()), id: \.offset) { entry in
                if case .moveToLayer = entry.element.kind {
                    Text("Move to layer ▸ \(SpatialCellBulkMenu.title(entry.element.kind, in: state))")
                } else {
                    Text(SpatialCellBulkMenu.title(entry.element.kind, in: state))
                        .foregroundColor(entry.element.isEnabled ? .white : .gray)
                }
            }
        }.font(.system(size: 13)).padding(12).background(StageTheme.workspace)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray)).cornerRadius(6)
    }
}
