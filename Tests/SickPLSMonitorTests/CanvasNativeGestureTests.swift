import AppKit
import SwiftUI
import XCTest
import PlanariumApplication
import PlanariumDomain
import SickPLSMonitorKit
import SickPLSCore
@testable import SickPLSMonitor

@MainActor final class CanvasNativeGestureTests: XCTestCase {
    private final class PointerWindow: NSWindow {
        var testPointer = NSPoint.zero
        override var mouseLocationOutsideOfEventStream: NSPoint { testPointer }
    }
    /// Public NSEvent factories cannot construct a magnify event. This native
    /// event fixture supplies exactly the properties read by the adapter.
    private final class ZoomEvent: NSEvent {
        let kind: NSEvent.EventType
        let position: NSPoint
        let ownerWindow: NSWindow
        init(kind: NSEvent.EventType, position: NSPoint, window: NSWindow) {
            self.kind = kind; self.position = position; ownerWindow = window
            super.init()
        }
        required init?(coder: NSCoder) { fatalError("Unused event fixture") }
        override var type: NSEvent.EventType { kind }
        override var locationInWindow: NSPoint { position }
        override var window: NSWindow? { ownerWindow }
        override var modifierFlags: NSEvent.ModifierFlags { [] }
        override var scrollingDeltaY: CGFloat { 20 }
        override var hasPreciseScrollingDeltas: Bool { true }
        override var isDirectionInvertedFromDevice: Bool { false }
        override var magnification: CGFloat { 0.2 }
    }
    private struct Field: View {
        @ObservedObject var owner: SpatialInstrumentRuntimeModel
        @ObservedObject var cells: SpatialActiveCellDisplayModel
        var body: some View {
            CartesianScanFieldView(editor: owner.canvas, profile: cells.latestProfile,
                activeCellDisplay: cells, spatialInstrument: owner, simulationBadge: AnyView(EmptyView()))
        }
    }
    func pump(_ host: NSView, seconds: Double = 0.03) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }
    func pointer(in view: NSView) -> ScanFieldPointerEvents.PointerView? {
        if let pointer = view as? ScanFieldPointerEvents.PointerView, !pointer.isKeyboardOnly { return pointer }
        return view.subviews.compactMap { pointer(in: $0) }.first
    }
    func send(_ type: NSEvent.EventType, at point: CGPoint, pointer: ScanFieldPointerEvents.PointerView,
              window: NSWindow, host: NSView) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: pointer.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        if let forwarded = pointer.handle(event) { NSApplication.shared.sendEvent(forwarded) }
        pump(host)
    }
    func testHostedSwiftUIMouseSequencePaintSelectMoveAndHandlesWithRebuilds() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document, cells = SpatialActiveCellDisplayModel()
        defer { fixture.root.terminate {} }
        owner.canvas.replaceWorkspace(.init(grid: .quarterMeter, layers: owner.canvas.workspace.layers))
        let host = NSHostingView(rootView: Field(owner: owner, cells: cells))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 1000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.frame = .init(x: 0, y: 0, width: 900, height: 1000)
        window.makeKeyAndOrderFront(nil); pump(host)
        defer { pointer(in: host)?.stopListening(); window.orderOut(nil); window.contentView = nil }
        let native = try XCTUnwrap(pointer(in: host)), size = native.bounds.size
        func screen(_ cell: PolarMetricGridCell) -> CGPoint {
            let area = PolarMetricCellSegment(cell: cell, grid: owner.canvas.workspace.grid)
            return MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for:
                area.point(radiusMeters: area.midpoint.radiusMeters, bearingDegrees: area.midpoint.bearingDegrees))
        }
        owner.canvas.select(tool: .paint); pump(host)
        let start = screen(.init(ring: 2, angularIndex: 8)), end = screen(.init(ring: 3, angularIndex: 12))
        try send(.leftMouseDown, at: start, pointer: native, window: window, host: host)
        try send(.leftMouseDragged, at: end, pointer: native, window: window, host: host)
        XCTAssertTrue(owner.canvas.isDragging, "Native down/drag must reach the production field callback")
        try send(.leftMouseUp, at: end, pointer: native, window: window, host: host)
        XCTAssertGreaterThan(owner.canvas.workspace.selectedLayer.polarCells.count, 1)
        owner.canvas.select(tool: .select); _ = owner.canvas.perform(.selectAll); pump(host)
        _ = owner.canvas.zoom(byFactor: 1.3, atScreenPoint: start, canvasSize: size)
        _ = owner.canvas.panViewport(byScreenX: 23, screenY: 17); pump(host)
        let viewport = owner.canvas.viewport
        let source = try XCTUnwrap(owner.canvas.selectedPolarCells.first)
        let center = screen(source), moved = CGPoint(x: center.x + 35, y: center.y - 45)
        try send(.leftMouseDown, at: center, pointer: native, window: window, host: host)
        XCTAssertTrue(owner.canvas.isDragging)
        try send(.leftMouseDragged, at: moved, pointer: native, window: window, host: host)
        let preview = owner.canvas.movePreviewCells
        XCTAssertFalse(preview.isEmpty); XCTAssertEqual(owner.canvas.viewport, viewport)
        for tick in 0..<25 {
            let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<90).map { _ in
                try .build(value: UInt16(100 + tick), fieldFlags: 0)
            })
            cells.update(profile: profile, activeCells: [:]); pump(host, seconds: 0.04)
            XCTAssertTrue(owner.canvas.isDragging)
            XCTAssertEqual(owner.canvas.movePreviewCells, preview)
            XCTAssertEqual(owner.canvas.viewport, viewport)
        }
        try send(.leftMouseUp, at: moved, pointer: native, window: window, host: host)
        XCTAssertEqual(owner.canvas.selectedPolarCells, preview)
        XCTAssertFalse(owner.canvas.workspace.selectedLayer.polarCells.isEmpty)
        XCTAssertEqual(owner.canvas.viewport, viewport)
        let movedWorkspace = owner.canvas.workspace
        for handle in CanvasSelectionHandle.allCases {
            owner.canvas.replaceWorkspace(movedWorkspace); _ = owner.canvas.perform(.selectAll); pump(host)
            let bounds = try XCTUnwrap(owner.canvas.selectionBounds)
            let from = MetricCanvasGeometry(size: size, viewport: viewport).screenPoint(for: handle.point(in: bounds))
            XCTAssertEqual(owner.canvas.selectionHandle(at: from, canvasSize: size), handle)
            let to = CGPoint(x: from.x + 28, y: from.y - 32)
            try send(.leftMouseDown, at: from, pointer: native, window: window, host: host)
            XCTAssertTrue(owner.canvas.isDragging, "\(handle)")
            try send(.leftMouseDragged, at: to, pointer: native, window: window, host: host)
            let resized = owner.canvas.movePreviewCells
            XCTAssertFalse(resized.isEmpty, "\(handle)")
            try send(.leftMouseUp, at: to, pointer: native, window: window, host: host)
            XCTAssertEqual(owner.canvas.selectedPolarCells, resized, "\(handle)")
            XCTAssertEqual(owner.canvas.viewport, viewport, "\(handle)")
        }
    }

    func testGeometryAndWindowAnchorStayFrozenDuringNativeDragAndRemountKeepsViewport() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document, cells = SpatialActiveCellDisplayModel()
        defer { fixture.root.terminate {} }
        let painted: Set<PolarMetricGridCell> = [.init(ring: 2, angularIndex: 8), .init(ring: 2, angularIndex: 9),
                                               .init(ring: 3, angularIndex: 11), .init(ring: 3, angularIndex: 12)]
        owner.canvas.replaceWorkspace(.init(grid: .quarterMeter, layers: [.init(name: "Patch", color: .blue, polarCells: painted)]))
        let host = NSHostingView(rootView: Field(owner: owner, cells: cells))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 1000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.frame = .init(x: 0, y: 0, width: 900, height: 1000); pump(host)
        defer { pointer(in: host)?.stopListening(); window.contentView = nil }
        let native = try XCTUnwrap(pointer(in: host)), size = native.bounds.size
        _ = owner.canvas.perform(.selectAll)
        let bounds = try XCTUnwrap(owner.canvas.selectionBounds)
        let geometry = owner.canvas.displayGeometry(canvasSize: size)
        let start = geometry.screenPoint(for: CanvasSelectionHandle.outer.point(in: bounds))
        _ = owner.canvas.zoom(byFactor: 1.5, atScreenPoint: start, canvasSize: size)
        _ = owner.canvas.panViewport(byScreenX: 7, screenY: -4); pump(host)
        let before = owner.canvas.viewport
        let frozen = owner.canvas.displayGeometry(canvasSize: size)
        let down = frozen.screenPoint(for: CanvasSelectionHandle.outer.point(in: bounds))
        let downInWindow = native.convert(down, to: nil)
        try send(.leftMouseDown, at: down, pointer: native, window: window, host: host)
        XCTAssertEqual(owner.canvas.draggedSelectionHandle, .outer)
        let motion = CGPoint(x: down.x, y: down.y - 45)
        try send(.leftMouseDragged, at: motion, pointer: native, window: window, host: host)
        let preview = owner.canvas.movePreviewCells
        host.frame.size = .init(width: 1100, height: 1200); pump(host)
        XCTAssertEqual(owner.canvas.displayGeometry(canvasSize: native.bounds.size), frozen)
        let still = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged,
            location: .init(x: downInWindow.x, y: downInWindow.y + 45), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        XCTAssertNil(native.handle(still)); pump(host)
        XCTAssertEqual(owner.canvas.movePreviewCells, preview, "A layout change cannot reinterpret the same window point")
        XCTAssertEqual(owner.canvas.viewport, before)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: still.locationInWindow,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0))
        XCTAssertNil(native.handle(up)); pump(host)
        XCTAssertEqual(owner.canvas.selectedPolarCells, preview)
        window.contentView = nil
        let replacement = NSHostingView(rootView: Field(owner: owner, cells: cells))
        window.contentView = replacement; replacement.frame = .init(x: 0, y: 0, width: 900, height: 1000); pump(replacement)
        XCTAssertEqual(owner.canvas.viewport, before, "A new field's onAppear must not reset the user's viewport")
        pointer(in: replacement)?.stopListening()
    }

    func testInnerHandleBeyondScannerHasMonotoneClampedResultThroughNativeEvents() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document, cells = SpatialActiveCellDisplayModel()
        defer { fixture.root.terminate {} }
        owner.canvas.replaceWorkspace(.init(grid: .quarterMeter, layers: [.init(name: "Patch", color: .blue,
            polarCells: [.init(ring: 2, angularIndex: 11), .init(ring: 3, angularIndex: 15)])]))
        let host = NSHostingView(rootView: Field(owner: owner, cells: cells))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.frame = .init(x: 0, y: 0, width: 900, height: 1000); pump(host)
        defer { pointer(in: host)?.stopListening(); window.contentView = nil }
        let native = try XCTUnwrap(pointer(in: host)), size = native.bounds.size
        _ = owner.canvas.panViewport(byScreenX: 0, screenY: -200); _ = owner.canvas.perform(.selectAll); pump(host)
        let bounds = try XCTUnwrap(owner.canvas.selectionBounds), geometry = owner.canvas.displayGeometry(canvasSize: size)
        let from = geometry.screenPoint(for: CanvasSelectionHandle.inner.point(in: bounds))
        try send(.leftMouseDown, at: from, pointer: native, window: window, host: host)
        XCTAssertEqual(owner.canvas.draggedSelectionHandle, .inner)
        let origin = geometry.screenPoint(for: .init(xMeters: 0, yMeters: 0))
        try send(.leftMouseDragged, at: origin, pointer: native, window: window, host: host)
        let atOrigin = owner.canvas.movePreviewCells
        for distance in [20.0, 60.0, 120.0] {
            try send(.leftMouseDragged, at: .init(x: origin.x, y: origin.y + distance), pointer: native, window: window, host: host)
            XCTAssertEqual(owner.canvas.movePreviewCells, atOrigin)
        }
        try send(.leftMouseUp, at: .init(x: origin.x, y: origin.y + 120), pointer: native, window: window, host: host)
        XCTAssertEqual(owner.canvas.selectedPolarCells, atOrigin)
        XCTAssertEqual(PolarCellTransform.bounds(cells: atOrigin, grid: owner.canvas.workspace.grid)?.innerRadiusMeters, 0)
    }

    func testToolKeysAndSpaceKeepCursorAfterLayoutWithoutMouseMovement() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document, cells = SpatialActiveCellDisplayModel()
        defer { fixture.root.terminate {}; NSCursor.arrow.set() }
        let host = NSHostingView(rootView: Field(owner: owner, cells: cells))
        let window = PointerWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.frame = .init(x: 0, y: 0, width: 900, height: 1000); pump(host)
        defer { pointer(in: host)?.stopListening(); window.contentView = nil }
        let native = try XCTUnwrap(pointer(in: host))
        window.testPointer = native.convert(.init(x: 250, y: 300), to: nil)
        XCTAssertTrue(window.makeFirstResponder(native))
        _ = owner.canvas.zoom(byFactor: 1.4, atScreenPoint: .init(x: 250, y: 300), canvasSize: native.bounds.size)
        _ = owner.canvas.panViewport(byScreenX: 20, screenY: 10)
        let viewport = owner.canvas.viewport
        for (code, character, tool) in [(UInt16(11), "b", MetricCanvasTool.paint), (14, "e", .erase), (4, "h", .pan), (9, "v", .select)] {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code))
            XCTAssertNil(native.handle(key)); pump(host)
            XCTAssertEqual(owner.canvas.tool, tool); XCTAssertEqual(owner.canvas.viewport, viewport)
            let expected = NSCursor.current.image.tiffRepresentation
            NSCursor.arrow.set()
            native.needsLayout = true; native.layoutSubtreeIfNeeded(); pump(host)
            XCTAssertEqual(NSCursor.current.image.tiffRepresentation, expected, "\(character): post-layout refresh must restore the tool cursor")
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49))
            XCTAssertNil(native.handle(key)); pump(host)
            XCTAssertEqual(owner.canvas.effectiveTool, type == .keyDown ? .pan : .select)
            XCTAssertEqual(owner.canvas.viewport, viewport)
        }
    }

    func testNativeScrollMagnifyConsumeInsideOnlyAndEscapeStopsBeforeFullscreenResponder() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 800, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let native = ScanFieldPointerEvents.PointerView(frame: .init(x: 0, y: 0, width: 400, height: 400))
        let container = NSView(frame: .init(x: 0, y: 0, width: 800, height: 800)); container.addSubview(native); window.contentView = container
        defer { native.stopListening(); window.contentView = nil }
        var scrolls = 0, magnifications = 0
        native.onScroll = { _, _ in scrolls += 1 }; native.onMagnify = { _, _ in magnifications += 1 }
        for type in [NSEvent.EventType.scrollWheel, .magnify] {
            for inside in [true, false] {
                let event = ZoomEvent(kind: type,
                    position: native.convert(.init(x: inside ? 100 : 600, y: 100), to: nil), window: window)
                if inside { XCTAssertNil(native.handle(event)) }
                else { XCTAssertTrue(native.handle(event) === event) }
            }
        }
        XCTAssertEqual(scrolls, 1); XCTAssertEqual(magnifications, 1)
        let layer = SpatialInstrumentLayer(name: "Patch", color: .blue, polarCells: [.init(ring: 2, angularIndex: 8)])
        owner.canvas.replaceWorkspace(.init(grid: .quarterMeter, layers: [layer]))
        let field = CartesianScanFieldView(editor: owner.canvas, profile: nil,
            activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner, simulationBadge: AnyView(EmptyView()))
        let list = LayerInspectorView(editor: owner.canvas,
            audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()), midiOutput: fixture.root.midi,
            spatialInstrument: owner, evaluationCounter: nil)
        for inList in [false, true] { for gesture in [false, true] {
            _ = owner.canvas.perform(.selectAll)
            if gesture { _ = owner.canvas.beginViewportDrag(at: .init(x: 100, y: 100), canvasSize: native.bounds.size) }
            native.onKeyCommand = { inList ? list.handleLayerSelectionKey($0) : field.handleCanvasKey($0, canvasSize: native.bounds.size) }
            XCTAssertTrue(window.makeFirstResponder(native))
            let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            XCTAssertNil(native.handle(esc), "Consumed Esc never reaches NSWindow's fullscreen handling")
            XCTAssertFalse(owner.canvas.isDragging)
            if !gesture { XCTAssertTrue(owner.canvas.selectedCells.isEmpty) }
        } }
    }
}
