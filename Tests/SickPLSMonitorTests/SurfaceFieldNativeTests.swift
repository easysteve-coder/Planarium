import AppKit
import SwiftUI
import XCTest
@testable import PlanariumApplication
@testable import PlanariumDomain
import PlanariumRuntime
import SickPLSMonitorKit
@testable import SickPLSMonitor

/// FLÄCHENEDITOR-UI-1 at the native boundary: the real field view is hosted, and the pointer, key and focus events
/// reach the surface editor through the very closures the app uses.
@MainActor final class SurfaceFieldNativeTests: XCTestCase {
    @MainActor struct Rig {
        let fixture: MonitorRootFixture
        let owner: SpatialInstrumentRuntimeModel
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let pointer: ScanFieldPointerEvents.PointerView
        var editor: SurfaceEditorModel { owner.surfaceEditor }
        var geometry: MetricCanvasGeometry { owner.canvas.displayGeometry(canvasSize: pointer.bounds.size) }
        var space: SurfaceCanvasSpace { SurfaceCanvasSpace(geometry) }
        func local(_ x: Double, _ y: Double) -> CGPoint { space.screen(.init(x: x, y: y)) }
        func event(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: pointer.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
        }
        func key(_ code: UInt16, _ characters: String = "", type: NSEvent.EventType = .keyDown, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        @discardableResult func send(_ e: NSEvent) -> NSEvent? { pointer.handle(e) }
        func drag(_ a: (Double, Double), _ b: (Double, Double), flags: NSEvent.ModifierFlags = [], release: Bool = true) throws {
            send(try event(.leftMouseDown, local(a.0, a.1), flags: flags))
            send(try event(.leftMouseDragged, local((a.0 + b.0) / 2, (a.1 + b.1) / 2), flags: flags))
            send(try event(.leftMouseDragged, local(b.0, b.1), flags: flags))
            if release { send(try event(.leftMouseUp, local(b.0, b.1), flags: flags)) }
        }
        func click(_ p: (Double, Double), flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws {
            send(try event(.leftMouseDown, local(p.0, p.1), flags: flags, clicks: clicks))
            send(try event(.leftMouseUp, local(p.0, p.1), flags: flags, clicks: clicks))
        }
        var surfaces: [SpatialSurface] { owner.document.spatial.layers.flatMap(\.surfaces) }
        func tearDown() { pointer.stopListening(); window.contentView = nil; fixture.root.terminate {} }
    }

    static func findPointer(in view: NSView) -> ScanFieldPointerEvents.PointerView? {
        if let found = view as? ScanFieldPointerEvents.PointerView { return found }
        for sub in view.subviews { if let found = findPointer(in: sub) { return found } }
        return nil
    }
    private func rig(width: CGFloat = 1000, height: CGFloat = 800) throws -> Rig { try Self.makeRig(width: width, height: height) }
    static func makeRig(width: CGFloat = 1000, height: CGFloat = 800) throws -> Rig {
        _ = NSApplication.shared
        let fixture = try MonitorRootFixture(surfaceEditor: true), owner = fixture.root.document
        let cells = SpatialActiveCellDisplayModel()
        let view = CartesianScanFieldView(editor: owner.canvas, profile: nil, activeCellDisplay: cells, spatialInstrument: owner,
                                          simulationBadge: AnyView(EmptyView()))
        let host = NSHostingView(rootView: AnyView(view.preferredColorScheme(.dark)))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded()
        let pointer = try XCTUnwrap(findPointer(in: host), "the field hosts its pointer view")
        XCTAssertTrue(window.makeFirstResponder(pointer))
        XCTAssertEqual(owner.surfaceEditor.mode, .surfaces)
        return Rig(fixture: fixture, owner: owner, window: window, host: host, pointer: pointer)
    }

    // MARK: Native events

    func testDrawSelectMoveAndDeleteThroughNativeMouseAndKeyEvents() throws {
        let r = try rig(); defer { r.tearDown() }
        let depth = r.owner.historyDepth
        XCTAssertNil(r.send(try r.key(15, "r")), "R chooses the rectangle tool")
        XCTAssertEqual(r.editor.tool, .rectangle)
        try r.drag((-30, 80), (30, 120))
        XCTAssertEqual(r.surfaces.count, 1)
        XCTAssertEqual(r.owner.historyDepth, depth + 1)
        XCTAssertNil(r.send(try r.key(9, "v")), "V chooses the selection tool")
        try r.drag((0, 100), (20, 100))
        guard case .shape(_, let t)? = r.surfaces.first?.form else { return XCTFail() }
        XCTAssertEqual(t.xCm, 20, accuracy: 0.3)
        XCTAssertEqual(r.owner.historyDepth, depth + 2)
        XCTAssertNil(r.send(try r.key(2, "d", flags: .command)), "command-D duplicates")
        XCTAssertEqual(r.surfaces.count, 2)
        XCTAssertNil(r.send(try r.key(51)), "Delete removes the chosen surface")
        XCTAssertEqual(r.surfaces.count, 1)
        XCTAssertTrue(r.owner.undo()); XCTAssertEqual(r.surfaces.count, 2)
    }

    func testCommandXThenCommandVBringsTheCutSurfaceBackThroughNativeKeys() throws {
        let r = try rig(); defer { r.tearDown() }
        SurfaceEditorModel.resetClipboard()
        r.editor.select(tool: .rectangle); try r.drag((-30, 80), (30, 120)); r.editor.select(tool: .select)
        let original = try XCTUnwrap(r.surfaces.first)
        XCTAssertNil(r.send(try r.key(7, "x", flags: .command)), "command-X is the editor's")
        XCTAssertTrue(r.surfaces.isEmpty)
        XCTAssertNil(r.send(try r.key(9, "v", flags: .command)), "command-V pastes")
        XCTAssertEqual(r.surfaces.count, 1)
        XCTAssertEqual(r.surfaces.first?.placedShape, original.placedShape)
        XCTAssertNotEqual(r.surfaces.first?.id, original.id)
        XCTAssertEqual(r.editor.selectedSurfaceIDs, Set(r.surfaces.map(\.id)))
    }

    func testGrabbingAGroupCornerOffCentreAndDraggingScalesByTheMovementOnly() throws {
        let r = try rig(); defer { r.tearDown() }
        r.editor.select(tool: .rectangle)
        try r.drag((-30, 70), (-10, 90)); try r.drag((10, 70), (30, 90))
        r.editor.select(tool: .select)
        XCTAssertTrue(r.editor.select(Set(r.surfaces.map(\.id))))
        let corner = try XCTUnwrap(r.editor.handleLayout(geometry: r.geometry).handles.first { $0.kind == .frameCorner(sx: 1, sy: 1) })
        // Press a few points off the handle's middle, inside its grab area, and pull 12 cm to the right and up.
        let press = CGPoint(x: corner.center.x + 3, y: corner.center.y + 2)
        r.send(try r.event(.leftMouseDown, press))
        XCTAssertNotNil(r.editor.gesture)
        let unmoved = r.editor.gesture?.evaluate()
        for surface in r.surfaces { XCTAssertEqual(unmoved?.placements[surface.id]?.shape, surface.placedShape?.shape, "a press alone changes nothing") }
        let target = CGPoint(x: press.x + 20, y: press.y - 20)
        r.send(try r.event(.leftMouseDragged, CGPoint(x: press.x + 10, y: press.y - 10)))
        r.send(try r.event(.leftMouseDragged, target))
        r.send(try r.event(.leftMouseUp, target))
        var widths: [Double] = []
        for surface in r.surfaces { if case .rectangle(let w, _)? = surface.placedShape?.shape { widths.append(w) } }
        XCTAssertEqual(widths.count, 2)
        for w in widths { XCTAssertGreaterThan(w, 20); XCTAssertLessThan(w, 30, "scaled by the pointer's movement, not by the distance of the handle") }
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.11)
    }

    func testPaintAndEraseKeysAreRefusedOutLoudInTheSurfaceModeAndTouchNoCell() throws {
        let r = try rig(); defer { r.tearDown() }
        let old = SpatialDocumentLayer(id: UUID(), name: "Old", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: Set((0..<6).flatMap { ring in (0..<6).map { PolarDeviceLattice(ring: 40 + ring, sector: 170 + $0)! } }),
            routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .retrigger))], cellOverrides: [:])
        try r.owner.edit { $0.spatial = try! SpatialDocument(latticeVersion: .polarDeviceV2, layers: [old], selectedLayerID: old.id) }
        let document = r.owner.document, depth = r.owner.historyDepth
        let tool = r.owner.canvas.presentation.tool
        for (code, letter) in [(UInt16(11), "b"), (UInt16(14), "e")] {
            XCTAssertNil(r.send(try r.key(code, letter)), "\(letter) is taken, not passed on to the cell tools")
            XCTAssertEqual(r.owner.canvas.presentation.tool, tool, "no hidden Paint or Erase tool")
            XCTAssertEqual(r.editor.hint, "Paint and Erase work on cells; use the cell editor (advanced), or draw a surface")
            r.editor.refuse("")
            try r.drag((-5, 45), (5, 50))
            XCTAssertEqual(r.owner.document.spatial.layers[0].cells, old.cells, "a drag after the key paints nothing")
        }
        XCTAssertEqual(r.owner.document, document); XCTAssertEqual(r.owner.historyDepth, depth)
    }

    func testEscapeAndFocusLossAbandonADragWithoutACommit() throws {
        let r = try rig(); defer { r.tearDown() }
        r.editor.select(tool: .rectangle)
        try r.drag((-30, 80), (30, 120), release: false)
        XCTAssertNotNil(r.editor.gesture)
        let before = r.owner.document
        XCTAssertNil(r.send(try r.key(53)), "Escape is taken by the editor")
        XCTAssertNil(r.editor.gesture)
        r.send(try r.event(.leftMouseUp, r.local(30, 120)))
        XCTAssertEqual(r.owner.document, before)
        // Focus loss while dragging.
        try r.drag((-30, 80), (30, 120), release: false)
        XCTAssertNotNil(r.editor.gesture)
        r.pointer.stopListening()
        XCTAssertNil(r.editor.gesture, "the drag is dropped when the field loses focus")
        XCTAssertEqual(r.owner.document, before)
    }

    func testHandsOffToolsPanAndAuditionNeverEditSurfaces() throws {
        let r = try rig(); defer { r.tearDown() }
        r.editor.select(tool: .rectangle); try r.drag((-30, 80), (30, 120))
        r.owner.canvas.select(tool: .pan)
        let before = r.owner.document
        try r.drag((0, 100), (40, 100))
        XCTAssertEqual(r.owner.document, before, "the hand tool pans, it does not move the surface")
        r.owner.canvas.select(tool: .audition)
        try r.drag((0, 100), (40, 100))
        XCTAssertEqual(r.owner.document, before, "auditioning plays nothing into the document")
        r.owner.audition(nil)
    }

    func testEdgeHandlesStayGrabbableAfterZoomAndPan() throws {
        let r = try rig(); defer { r.tearDown() }
        r.editor.select(tool: .rectangle); try r.drag((-30, 80), (30, 120))
        r.editor.select(tool: .select)
        _ = r.owner.canvas.zoom(byFactor: 3, atScreenPoint: r.local(0, 100), canvasSize: r.pointer.bounds.size)
        _ = r.owner.canvas.panViewport(byScreenX: 40, screenY: -20)
        let layout = r.editor.handleLayout(geometry: r.geometry)
        let corner = try XCTUnwrap(layout.handles.first { $0.kind == .rectCorner(sx: 1, sy: 1) })
        XCTAssertEqual(layout.size, 16)
        XCTAssertTrue(r.geometry.canvasRect.contains(corner.center))
        // Grab the corner handle (not the surface) and drag it outward.
        let start = corner.center
        r.send(try r.event(.leftMouseDown, start))
        r.send(try r.event(.leftMouseDragged, CGPoint(x: start.x + 20, y: start.y - 20)))
        r.send(try r.event(.leftMouseUp, CGPoint(x: start.x + 20, y: start.y - 20)))
        guard case .shape(.rectangle(let w, let h), _)? = r.surfaces.first?.form else { return XCTFail() }
        XCTAssertGreaterThan(w, 60); XCTAssertGreaterThan(h, 40)
        XCTAssertEqual(r.owner.document.spatial.layers.flatMap(\.surfaces).count, 1, "the press took the handle and did not draw or move")
    }

    func testPolygonIsClosedByDoubleClickAndByEnterAndDiscardedByEscape() throws {
        let r = try rig(); defer { r.tearDown() }
        r.editor.select(tool: .polygon)
        for p in [(-40.0, 80.0), (40, 80), (40, 130)] { try r.click(p) }
        XCTAssertEqual(r.editor.polygon?.points.count, 3)
        send2(r, (-40, 130))
        XCTAssertEqual(r.surfaces.count, 1, "double-click closes the polygon")
        XCTAssertNil(r.editor.polygon)
        for p in [(60.0, 80.0), (100, 80), (100, 130)] { try r.click(p) }
        XCTAssertNil(r.send(try r.key(36)), "Enter closes")
        XCTAssertEqual(r.surfaces.count, 2)
        for p in [(-100.0, 80.0), (-60, 80), (-60, 130)] { try r.click(p) }
        XCTAssertNil(r.send(try r.key(53)), "Escape discards the draft")
        XCTAssertNil(r.editor.polygon); XCTAssertEqual(r.surfaces.count, 2)
    }
    private func send2(_ r: Rig, _ p: (Double, Double)) {
        // The second press of a double-click reaches the field's own double-click handler.
        r.send(try! r.event(.leftMouseDown, r.local(p.0, p.1), clicks: 2))
        r.send(try! r.event(.leftMouseUp, r.local(p.0, p.1), clicks: 2))
    }

    func testArrowKeysNudgeOneBurstPerKeyPressAndTheMixerStaysSeparate() throws {
        let r = try rig(); defer { r.tearDown() }
        r.editor.select(tool: .rectangle); try r.drag((-30, 80), (30, 120))
        let depth = r.owner.historyDepth
        for _ in 0..<4 { XCTAssertNil(r.send(try r.key(124))) }
        r.send(try r.key(124, type: .keyUp))
        XCTAssertEqual(r.owner.historyDepth, depth + 1)
        guard case .shape(_, let t)? = r.surfaces.first?.form else { return XCTFail() }
        XCTAssertEqual(t.xCm, 4, accuracy: 0.001)
        // A mixer drag after the burst is its own step.
        r.owner.beginContinuousEdit(); r.owner.updateMasterLevel(-4); r.owner.endContinuousEdit()
        XCTAssertEqual(r.owner.historyDepth, depth + 2)
    }

    func testPerformanceLockHidesTheEditorAndRefusesEveryEditingPath() throws {
        let r = try rig(); defer { r.tearDown() }
        r.editor.select(tool: .rectangle); try r.drag((-30, 80), (30, 120))
        r.owner.canvas.setPerformanceLocked(true)
        let before = r.owner.document
        r.editor.select(tool: .rectangle)
        try r.drag((60, 80), (100, 120))
        r.send(try r.key(51))
        XCTAssertEqual(r.owner.document, before)
        XCTAssertTrue(r.editor.handleLayout(geometry: r.geometry).handles.allSatisfy { !$0.isEnabled })
    }

    // MARK: B5

    private func twoHandRig() throws -> (SpatialActiveCellDisplayModel, SpatialInstrumentWorkspace, UUID, [PolarMetricGridCell]) {
        let owner = UUID(), a = UUID(), b = UUID()
        var layer = SpatialInstrumentLayer(id: owner, name: "Pad", color: .orange, routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .retrigger))])
        let left = PolarDeviceLattice(ring: 90, sector: 140)!, right = PolarDeviceLattice(ring: 140, sector: 240)!
        let grid = MetricSquareGrid.fiveCentimeter
        layer.polarCells = [SpatialActiveCellDisplayModel.tile(left, grid: grid)!, SpatialActiveCellDisplayModel.tile(right, grid: grid)!]
        layer.polarCellOverrides[SpatialActiveCellDisplayModel.tile(right, grid: grid)!] = [.init(target: .midiNote(channel: 0), value: .note(number: 67, velocity: 90))]
        let workspace = SpatialInstrumentWorkspace(grid: grid, layers: [layer])
        let display = SpatialActiveCellDisplayModel()
        let rev = SpatialDocumentRevision(session: UUID(), counter: 1)
        let frame = DisplayFrame(selection: .init(activeHandles: [a: CompiledActiveCell(layerID: a, cell: left, revision: rev),
                                                                    b: CompiledActiveCell(layerID: b, cell: right, revision: rev)], candidateDistancesCentimeters: [:]),
                                 partitionOwners: [a: owner, b: owner])
        display.update(frame, workspace: workspace)
        let tiles = [SpatialActiveCellDisplayModel.tile(left, grid: workspace.grid)!, SpatialActiveCellDisplayModel.tile(right, grid: workspace.grid)!]
        return (display, workspace, owner, tiles)
    }

    func testTwoHandsOnTwoSurfacesOfOneLayerAreBothHighlightedAndNamed() throws {
        let (display, workspace, owner, tiles) = try twoHandRig()
        XCTAssertEqual(display.activeCellSets[owner], Set(tiles), "both hands are kept")
        XCTAssertEqual(PerformanceCellNames.titles(workspace: workspace, hands: display.activeCellSets).count, 2)
        // The picture lights both cells.
        let geometry = MetricCanvasGeometry(size: CGSize(width: 800, height: 600),
                                            viewport: try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 0.9, metersPerPoint: 0.0035))
        let view = SpatialInstrumentActiveLayer(cells: display, workspace: workspace, geometry: geometry).background(StageTheme.canvas).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = .init(x: 0, y: 0, width: 800, height: 600); host.wantsLayer = true
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        for tile in tiles {
            let segment = PolarMetricCellSegment(cell: tile, grid: workspace.grid)
            let p = geometry.screenPoint(for: segment.point(radiusMeters: segment.midpoint.radiusMeters, bearingDegrees: segment.midpoint.bearingDegrees))
            let scale = Double(bitmap.pixelsWide) / 800
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(Double(p.x) * scale), y: Int(Double(p.y) * scale))?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(color.redComponent, 0.8, "the hand at \(tile) is lit in the layer colour")
            XCTAssertLessThan(color.blueComponent, 0.5)
        }
    }

    func testHoldDecorationAndHandsOfDifferentRoutingsAreAllShown() throws {
        let owner = UUID(), a = UUID(), b = UUID()
        let hold = SpatialRouting(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .holdUntilNext))
        let plain = SpatialRouting(target: .midiNote(channel: 1), program: .singleNote(note: 64, velocity: 100, transition: .retrigger))
        let rev = SpatialDocumentRevision(session: UUID(), counter: 1)
        let cells = [PolarDeviceLattice(ring: 90, sector: 140)!, PolarDeviceLattice(ring: 140, sector: 240)!, PolarDeviceLattice(ring: 180, sector: 300)!]
        func frame(held: Bool) -> DisplayFrame {
            DisplayFrame(selection: .init(activeHandles: [a: CompiledActiveCell(layerID: a, cell: cells[0], revision: rev),
                                                          b: CompiledActiveCell(layerID: b, cell: cells[1], revision: rev)], candidateDistancesCentimeters: [:]),
                         heldCells: held ? [CompiledActiveCell(layerID: a, cell: cells[2], revision: rev)] : [], partitionOwners: [a: owner, b: owner])
        }
        // A layer with a plain and a hold routing: hands are shown, and so is the hold decoration when something sounds.
        var layer = SpatialInstrumentLayer(id: owner, name: "Mixed", color: .orange, routings: [hold, plain])
        layer.polarCells = []
        let workspace = SpatialInstrumentWorkspace(grid: .fiveCentimeter, layers: [layer])
        let display = SpatialActiveCellDisplayModel()
        display.update(frame(held: true), workspace: workspace)
        XCTAssertEqual(display.activeCellSets[owner]?.count, 2)
        XCTAssertEqual(display.frame.heldCells[owner]?.count, 1)
        // A layer made only of hold routings shows its hands only while a hold sounds.
        var holdOnly = layer; holdOnly = SpatialInstrumentLayer(id: owner, name: "Hold", color: .orange, routings: [hold])
        let workspace2 = SpatialInstrumentWorkspace(grid: .fiveCentimeter, layers: [holdOnly])
        display.update(frame(held: false), workspace: workspace2)
        XCTAssertNil(display.activeCellSets[owner], "a geometric candidate must not look like a sounding hold")
        display.update(frame(held: true), workspace: workspace2)
        XCTAssertEqual(display.activeCellSets[owner]?.count, 2)
    }
}
