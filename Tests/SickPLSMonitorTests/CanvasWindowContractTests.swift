import AppKit
import SwiftUI
import Combine
import XCTest
import PlanariumApplication
import PlanariumDomain
import PlanariumRuntime
import SickPLSCore
@testable import SickPLSMonitorKit
@testable import SickPLSMonitor

/// Acceptance input always travels through NSWindow and the hit/responder
/// chain of the actual ContentView. No direct pointer-adapter dispatch.
@MainActor final class CanvasWindowContractTests: XCTestCase {
    private final class Window: NSWindow {
        var pointerPosition = NSPoint.zero
        override var mouseLocationOutsideOfEventStream: NSPoint { pointerPosition }
    }
    private final class RoutedZoomEvent: NSEvent {
        let target: NSWindow
        let targetNumber: Int
        let point: NSPoint
        let kind: NSEvent.EventType
        let backing: NSEvent
        init(window: NSWindow, point: NSPoint, kind: NSEvent.EventType = .scrollWheel) {
            target = window; targetNumber = MainActor.assumeIsolated { window.windowNumber }; self.point = point; self.kind = kind
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0)!
            backing = NSEvent(cgEvent: cg)!
            super.init()
        }
        required init?(coder: NSCoder) { fatalError("Unused test event decoder") }
        override var type: NSEvent.EventType { kind }
        override var window: NSWindow? { target }
        override var windowNumber: Int { targetNumber }
        override var locationInWindow: NSPoint { point }
        override var timestamp: TimeInterval { backing.timestamp }
        override var modifierFlags: NSEvent.ModifierFlags { [] }
        override var cgEvent: CGEvent? { backing.cgEvent }
        override var deltaX: CGFloat { 0 }
        override var deltaY: CGFloat { -20 }
        override var scrollingDeltaX: CGFloat { 0 }
        override var scrollingDeltaY: CGFloat { -20 }
        override var hasPreciseScrollingDeltas: Bool { true }
        override var isDirectionInvertedFromDevice: Bool { false }
        override var phase: NSEvent.Phase { [] }
        override var momentumPhase: NSEvent.Phase { [] }
        override var magnification: CGFloat { 0.2 }
    }
    private final class ScrollWitness: NSResponder {
        var scrollCount = 0
        var magnifyCount = 0
        var keyCount = 0
        override func scrollWheel(with event: NSEvent) { scrollCount += 1; super.scrollWheel(with: event) }
        override func magnify(with event: NSEvent) { magnifyCount += 1; super.magnify(with: event) }
        override func keyDown(with event: NSEvent) { keyCount += 1; super.keyDown(with: event) }
    }
    @MainActor private struct Harness {
        let fixture: MonitorRootFixture
        let layout: LayoutWorkspaceFixture
        let host: NSHostingView<ContentView>
        let window: Window
        let board: NSPasteboard
        var owner: SpatialInstrumentRuntimeModel { fixture.root.document }
        init() throws {
            _ = NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
            NSApplication.shared.finishLaunching()
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            fixture = try MonitorRootFixture()
            board = NSPasteboard(name: .init("canvas-window-\(UUID().uuidString)"))
            layout = try LayoutWorkspaceFixture(fixture: fixture, pasteboard: board)
            host = NSHostingView(rootView: layout.view)
            window = Window(contentRect: .init(x: 30, y: 30, width: 2160, height: 1200),
                            styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = .init(x: 0, y: 0, width: 2160, height: 1200)
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            let keyWindow = window
            var attempts = 0
            // Real activation can lag under TSan. Retry the setup, not the
            // behavioral assertions; invalidate even if AppKit run exits early.
            repeat {
                let activationTimer = Timer(timeInterval: 0.05, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        attempts += 1
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                        keyWindow.makeKeyAndOrderFront(nil)
                        if keyWindow.isKeyWindow || attempts >= 200 {
                            timer.invalidate()
                            NSApplication.shared.stop(nil)
                            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                                NSApplication.shared.postEvent(wake, atStart: false)
                            }
                        }
                    }
                }
                RunLoop.main.add(activationTimer, forMode: .common)
                NSApplication.shared.run()
                activationTimer.invalidate()
            } while !window.isKeyWindow && attempts < 200
            XCTAssertTrue(window.isKeyWindow, "Acceptance fixture must own a real AppKit key window; appActive=\(NSApplication.shared.isActive), key=\(String(describing: NSApplication.shared.keyWindow?.windowNumber)), target=\(window.windowNumber), visible=\(window.isVisible)")
            window.setFrameOrigin(.init(x: -10000, y: -10000))
            settle()
            fixture.root.display.stop()
        }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            host.layoutSubtreeIfNeeded()
        }
        func close() { fixture.root.display.stop(); window.close(); board.releaseGlobally(); layout.cleanDefaults(); fixture.root.terminate {} }
        func elements() -> [NSObject] {
            func collect(_ value: Any, depth: Int) -> [NSObject] {
                guard depth < 30, let element = value as? NSObject else { return [] }
                let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren()
                    ?? (element.responds(to: NSSelectorFromString("accessibilityChildren")) ? element.value(forKey: "accessibilityChildren") as? [Any] : nil)
                    ?? element.accessibilityAttributeValue(.children) as? [Any] ?? []
                return [element] + children.flatMap { collect($0, depth: depth + 1) }
            }
            return collect(window, depth: 0)
        }
        func click(label: String) throws {
            let element = try XCTUnwrap(elements().first { axLabel($0) == label }, "Missing control \(label)")
            let position = (element.accessibilityAttributeValue(.position) as? NSValue)?.pointValue ?? .zero
            let size = (element.accessibilityAttributeValue(.size) as? NSValue)?.sizeValue ?? .zero
            let frame = (element as? NSAccessibilityProtocol)?.accessibilityFrame()
                ?? (element.responds(to: NSSelectorFromString("accessibilityFrame")) ? (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue : nil)
                ?? CGRect(origin: position, size: size)
            let point = window.convertPoint(fromScreen: .init(x: frame.midX, y: frame.midY))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: true)
            try mouse(.leftMouseDown, atWindow: point)
            window.sendEvent(up)
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
            settle()
        }
        func axLabel(_ element: NSObject) -> String? {
            (element as? NSAccessibilityProtocol)?.accessibilityLabel()
                ?? (element.responds(to: NSSelectorFromString("accessibilityLabel")) ? element.value(forKey: "accessibilityLabel") as? String : nil)
                ?? element.accessibilityAttributeValue(.description) as? String
                ?? element.accessibilityAttributeValue(.title) as? String
        }
        func pointer(keyboardOnly: Bool = false) throws -> ScanFieldPointerEvents.PointerView {
            func find(_ view: NSView) -> ScanFieldPointerEvents.PointerView? {
                if let value = view as? ScanFieldPointerEvents.PointerView, value.isKeyboardOnly == keyboardOnly { return value }
                return view.subviews.compactMap(find).first
            }
            return try XCTUnwrap(find(host))
        }
        func mouse(_ type: NSEvent.EventType, at local: CGPoint, in view: NSView, flags: NSEvent.ModifierFlags = []) throws {
            let location = view.convert(local, to: nil)
            try mouse(type, atWindow: location, flags: flags)
        }
        func mouse(_ type: NSEvent.EventType, atWindow location: CGPoint, flags: NSEvent.ModifierFlags = []) throws {
            window.pointerPosition = location
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event); settle()
        }
        func key(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            window.sendEvent(event); settle()
        }
        func installPatch() {
            let layer = SpatialInstrumentLayer(name: "Patch", color: .orange,
                polarCells: [.init(ring: 2, angularIndex: 11), .init(ring: 2, angularIndex: 12),
                             .init(ring: 3, angularIndex: 15), .init(ring: 3, angularIndex: 16)],
                routings: [.init(target: .midiNote(channel: 0), program: .constant(60))])
            owner.canvas.replaceWorkspace(.init(grid: .quarterMeter, layers: [layer]))
            _ = owner.canvas.perform(.selectAll)
            settle()
        }
    }

    func testB4RadialWindowDragAndS5UndoRestoreDocumentButNeverViewportOrGesture() throws {
        let h = try Harness(); defer { h.close() }; h.installPatch()
        let native = try h.pointer(), size = native.bounds.size
        let bounds = try XCTUnwrap(h.owner.canvas.selectionBounds)
        let geometry = MetricCanvasGeometry(size: size, viewport: h.owner.canvas.viewport)
        let start = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters,
                                                         bearingDegrees: bounds.midpoint.bearingDegrees))
        let end = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters + 0.25,
                                                       bearingDegrees: bounds.midpoint.bearingDegrees))
        let before = h.owner.document.spatial
        let endWindow = native.convert(end, to: nil)
        try h.mouse(.leftMouseDown, at: start, in: native)
        // Live feedback used to add a footer row and change the geometry
        // between down and drag: a 25 cm radial step became the wrong step.
        XCTAssertTrue(h.owner.canvas.copySelection()); h.settle()
        h.window.setContentSize(.init(width: 2160, height: 1360)); h.settle()
        try h.mouse(.leftMouseDragged, atWindow: endWindow)
        try h.mouse(.leftMouseUp, atWindow: endWindow)
        XCTAssertEqual(try XCTUnwrap(h.owner.canvas.selectionBounds).innerRadiusMeters, bounds.innerRadiusMeters + 0.25, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(h.owner.canvas.selectionBounds).outerRadiusMeters, bounds.outerRadiusMeters + 0.25, accuracy: 0.000001)
        _ = h.owner.canvas.zoom(byFactor: 1.4, atScreenPoint: start, canvasSize: size)
        _ = h.owner.canvas.panViewport(byScreenX: 17, screenY: 11)
        let viewport = h.owner.canvas.viewport
        try h.key(6, "z", flags: .command)
        XCTAssertEqual(h.owner.document.spatial, before)
        XCTAssertEqual(h.owner.canvas.viewport, viewport)
        XCTAssertFalse(h.owner.canvas.isDragging)
        XCTAssertTrue(h.owner.canRedo)
    }

    func testB3DeviceFieldRemountAndS4LayerUndoCannotWriteSnapshotOverHistory() throws {
        let h = try Harness(); defer { h.close() }; h.installPatch()
        let native = try h.pointer(), size = native.bounds.size
        _ = h.owner.canvas.zoom(byFactor: 1.5, atScreenPoint: .init(x: 100, y: 100), canvasSize: size)
        _ = h.owner.canvas.panViewport(byScreenX: 12, screenY: 4)
        let viewport = h.owner.canvas.viewport
        h.layout.workspace.editsDeviceFields = true; h.settle()
        h.layout.workspace.editsDeviceFields = false; h.settle()
        XCTAssertEqual(h.owner.canvas.viewport, viewport)
        let name = h.owner.canvas.workspace.selectedLayer.name
        _ = h.owner.canvas.renameSelectedLayer("Changed")
        h.settle()
        let list = try h.pointer(keyboardOnly: true)
        try h.mouse(.leftMouseDown, at: .init(x: 70, y: 15), in: list)
        try h.mouse(.leftMouseUp, at: .init(x: 70, y: 15), in: list)
        XCTAssertTrue(h.window.firstResponder === list)
        try h.key(6, "z", flags: .command)
        XCTAssertEqual(h.owner.canvas.workspace.selectedLayer.name, name)
        XCTAssertEqual(h.owner.canvas.viewport, viewport)
        XCTAssertTrue(h.owner.canRedo)
    }

    func testEscapeAfterSingleLayerListClickStopsBeforeWindowResponder() throws {
        let h = try Harness(); defer { h.close() }; h.installPatch()
        // Esc after a real layer-list click is consumed before reaching the
        // window responder (which would otherwise handle full-screen exit).
        // A separate window avoids accidentally double-clicking into Rename
        // when this scenario follows the Undo scenario.
        let escapeList = try h.pointer(keyboardOnly: true)
        try h.mouse(.leftMouseDown, at: .init(x: 70, y: 15), in: escapeList)
        try h.mouse(.leftMouseUp, at: .init(x: 70, y: 15), in: escapeList)
        XCTAssertTrue(h.window.firstResponder === escapeList)
        let witness = ScrollWitness(), next = escapeList.nextResponder
        witness.nextResponder = next; escapeList.nextResponder = witness
        defer { escapeList.nextResponder = next }
        let viewport = h.owner.canvas.viewport
        XCTAssertFalse(h.owner.canvas.selectedCells.isEmpty)
        try h.key(53, "\u{1b}")
        XCTAssertTrue(h.owner.canvas.selectedCells.isEmpty)
        XCTAssertEqual(witness.keyCount, 0)
        XCTAssertEqual(h.owner.canvas.viewport, viewport)
    }

    func testB2WindowZoomIsConsumedBeforeAncestorResponderAndScrollView() throws {
        let h = try Harness(); defer { h.close() }
        h.window.setContentSize(.init(width: 1080, height: 1200)); h.settle()
        let native = try h.pointer(), witness = ScrollWitness()
        let scroll = try XCTUnwrap(native.enclosingScrollView)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height)
        let scrollOrigin = scroll.contentView.bounds.origin
        witness.nextResponder = native.nextResponder
        native.nextResponder = witness
        defer { native.nextResponder = witness.nextResponder }
        for kind in [NSEvent.EventType.scrollWheel] {
            let point = native.convert(.init(x: 250, y: 250), to: nil)
            h.window.pointerPosition = point
            h.window.makeFirstResponder(native)
            let before = h.owner.canvas.viewport
            h.window.sendEvent(RoutedZoomEvent(window: h.window, point: point, kind: kind)); h.settle()
            XCTAssertNotEqual(h.owner.canvas.viewport.metersPerPoint, before.metersPerPoint)
            XCTAssertEqual(scroll.contentView.bounds.origin, scrollOrigin, "Zoom cannot also scroll the containing document")
        }
        XCTAssertEqual(witness.scrollCount, 0)
        XCTAssertEqual(witness.magnifyCount, 0)
    }

    func testB1ToolKeyRefreshesStationaryCursorAfterLayoutAndB3PreservesViewport() throws {
        let h = try Harness(); defer { h.close() }
        let native = try h.pointer()
        h.window.pointerPosition = native.convert(.init(x: 150, y: 150), to: nil)
        h.window.makeFirstResponder(native)
        _ = h.owner.canvas.zoom(byFactor: 1.5, atScreenPoint: .init(x: 150, y: 150), canvasSize: native.bounds.size)
        let viewport = h.owner.canvas.viewport
        for (code, text, tool) in [(UInt16(11), "b", MetricCanvasTool.paint), (UInt16(14), "e", .erase), (UInt16(4), "h", .pan), (UInt16(9), "v", .select)] {
            try h.key(code, text)
            XCTAssertEqual(h.owner.canvas.tool, tool)
            XCTAssertEqual(h.owner.canvas.viewport, viewport)
            h.host.needsLayout = true; h.settle()
            let local = native.convert(h.window.pointerPosition, from: nil)
            let expected = try XCTUnwrap(native.cursorAtPoint?(local) ?? native.cursor)
            XCTAssertEqual(NSCursor.current.image.tiffRepresentation, expected.image.tiffRepresentation)
            XCTAssertEqual(NSCursor.current.hotSpot, expected.hotSpot)
        }
        try h.key(53, "\u{1b}")
        XCTAssertFalse(h.owner.canvas.isDragging)
    }

    func testB5OffCenterOuterHandleHasFixedScreenHitSizeAtEveryZoom() throws {
        let h = try Harness(); defer { h.close() }
        for factor in [0.6, 1.0, 1.8] {
            h.installPatch()
            let native = try h.pointer(), size = native.bounds.size
            _ = h.owner.canvas.resetViewport(canvasSize: size)
            _ = h.owner.canvas.zoom(byFactor: factor, atScreenPoint: .init(x: size.width / 2, y: size.height), canvasSize: size)
            h.settle()
            let bounds = try XCTUnwrap(h.owner.canvas.selectionBounds)
            let geometry = h.owner.canvas.displayGeometry(canvasSize: size)
            let center = geometry.screenPoint(for: CanvasSelectionHandle.outer.point(in: bounds))
            let start = CGPoint(x: center.x + 6, y: center.y + 5)
            XCTAssertEqual(h.owner.canvas.selectionHandle(at: start, canvasSize: size), .outer)
            try h.mouse(.leftMouseDown, at: start, in: native)
            let radians = bounds.midpoint.bearingDegrees * .pi / 180
            let end = CGPoint(x: start.x + sin(radians) * 0.25 / geometry.viewport.metersPerPoint,
                              y: start.y - cos(radians) * 0.25 / geometry.viewport.metersPerPoint)
            try h.mouse(.leftMouseDragged, at: end, in: native)
            XCTAssertEqual(h.owner.canvas.gesture.phase, .resizing(.outer))
            try h.mouse(.leftMouseUp, at: end, in: native)
            XCTAssertGreaterThan(try XCTUnwrap(h.owner.canvas.selectionBounds).outerRadiusMeters, bounds.outerRadiusMeters)
            XCTAssertEqual(h.owner.undoMenuTitle, "Undo: Resize cells")
        }
    }

    func testB6LayoutAndStatusChangesDuringDragUseFrozenGeometryAndOneCommand() throws {
        let h = try Harness(); defer { h.close() }; h.installPatch()
        let native = try h.pointer(), size = native.bounds.size
        let bounds = try XCTUnwrap(h.owner.canvas.selectionBounds)
        let geometry = h.owner.canvas.displayGeometry(canvasSize: size)
        let start = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters, bearingDegrees: bounds.midpoint.bearingDegrees))
        let end = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters + 0.25, bearingDegrees: bounds.midpoint.bearingDegrees))
        let startWindow = native.convert(start, to: nil), endWindow = native.convert(end, to: nil)
        let before = h.owner.document.spatial
        try h.mouse(.leftMouseDown, atWindow: startWindow)
        h.owner.canvas.perform { $0.statusMessage = String(repeating: "Boundary feedback ", count: 30) }
        h.window.setContentSize(.init(width: 2160, height: 1360)); h.settle()
        XCTAssertEqual(h.owner.canvas.displayGeometry(canvasSize: native.bounds.size), geometry)
        try h.mouse(.leftMouseDragged, atWindow: endWindow)
        XCTAssertEqual(h.owner.document.spatial, before, "Preview must not author document")
        let preview = h.owner.canvas.movePreviewCells, viewport = h.owner.canvas.viewport
        XCTAssertFalse(preview.isEmpty)
        let session = UUID()
        for tick in 1...25 {
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<90).map { _ in
                try .build(value: UInt16(100 + tick), fieldFlags: 0)
            })
            let frame = ProfileFrame(sessionID: session, sequence: UInt64(tick), time: ProcessInfo.processInfo.systemUptime,
                measurements: try FullScanProfileAdapter.measurements(from: raw),
                geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
            h.fixture.root.runtime.mailbox.write(.init(profile: frame, contour: nil,
                selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]),
                revision: h.owner.document.revision, sessionID: session, processedProfiles: UInt64(tick)))
            h.fixture.root.display.read(); h.settle() // production read and 25 Hz UI pacing
            XCTAssertEqual(h.owner.canvas.movePreviewCells, preview)
            XCTAssertEqual(h.owner.canvas.viewport, viewport)
            XCTAssertEqual(h.owner.document.spatial, before)
            XCTAssertEqual(h.owner.canvas.displayGeometry(canvasSize: native.bounds.size), geometry)
        }
        try h.mouse(.leftMouseUp, atWindow: endWindow)
        XCTAssertEqual(h.owner.canvas.selectedPolarCells, preview)
        XCTAssertEqual(try XCTUnwrap(h.owner.canvas.selectionBounds).innerRadiusMeters, bounds.innerRadiusMeters + 0.25, accuracy: 0.000001)
        XCTAssertEqual(h.owner.undoMenuTitle, "Undo: Move cells")
        XCTAssertEqual(h.owner.canvas.viewportOwner.state.canvasSize, native.bounds.size)
        XCTAssertNil(h.owner.canvas.viewportOwner.state.deferredSize)
    }

    func testB7InnerHandleAcrossSideBoundaryAndBehindScannerNeverReflects() throws {
        let h = try Harness(); defer { h.close() }; h.installPatch()
        let native = try h.pointer(), size = native.bounds.size
        let bounds = try XCTUnwrap(h.owner.canvas.selectionBounds)
        let geometry = h.owner.canvas.displayGeometry(canvasSize: size)
        let start = geometry.screenPoint(for: CanvasSelectionHandle.inner.point(in: bounds))
        try h.mouse(.leftMouseDown, at: start, in: native)
        let above = geometry.screenPoint(for: .init(xMeters: 0.5, yMeters: 0.00001))
        let below = geometry.screenPoint(for: .init(xMeters: 0.5, yMeters: -0.8))
        try h.mouse(.leftMouseDragged, at: above, in: native)
        let preview = h.owner.canvas.movePreviewCells
        try h.mouse(.leftMouseDragged, at: below, in: native)
        XCTAssertEqual(h.owner.canvas.movePreviewCells, preview, "Side clamp must remain continuous and cannot inflate radius behind scanner")
        let rear = geometry.screenPoint(for: .init(xMeters: 0, yMeters: -0.8))
        try h.mouse(.leftMouseDragged, at: rear, in: native)
        try h.mouse(.leftMouseUp, at: rear, in: native)
        XCTAssertEqual(try XCTUnwrap(h.owner.canvas.selectionBounds).innerRadiusMeters, 0, accuracy: 0.000001)
        XCTAssertFalse(h.owner.canvas.workspace.selectedLayer.polarCells.isEmpty)
        XCTAssertFalse(h.owner.canvas.isDragging)
    }

    func testToolbarClicksReachControlsAndPrivatePasteboardRoundTripUsesFocusedCommands() throws {
        let h = try Harness(); defer { h.close() }; h.installPatch()
        let before = h.owner.document.spatial
        let cells = h.owner.canvas.workspace.selectedLayer.polarCells
        let native = try h.pointer()
        let viewport = h.owner.canvas.viewport
        try h.click(label: "Paint (B)")
        XCTAssertEqual(h.owner.canvas.tool, .paint)
        XCTAssertFalse(h.owner.canvas.isDragging)
        XCTAssertEqual(h.owner.document.spatial, before)
        XCTAssertEqual(h.owner.canvas.viewport, viewport)
        try h.click(label: "Select (V)")
        h.window.makeFirstResponder(native)
        try h.key(8, "c", flags: .command)
        XCTAssertNotNil(h.board.data(forType: .init("de.planarium.cells")))
        try h.key(51, "\u{8}")
        XCTAssertTrue(h.owner.canvas.workspace.selectedLayer.polarCells.isEmpty)
        try h.key(9, "v", flags: .command)
        XCTAssertEqual(h.owner.canvas.workspace.selectedLayer.polarCells, cells)
        XCTAssertEqual(h.owner.canvas.viewport, viewport)
        XCTAssertEqual(h.elements().filter { h.axLabel($0) == "PANIC" }.count, 1)
        XCTAssertEqual(h.elements().filter { h.axLabel($0) == "Layer color" }.count, 1)
    }

    func testPointerPreviewDoesNotPublishDocumentAndEscapeOrFocusLossCancelsExactly() throws {
        let h = try Harness(); defer { h.close() }; h.installPatch()
        let native = try h.pointer(), size = native.bounds.size
        let bounds = try XCTUnwrap(h.owner.canvas.selectionBounds)
        let geometry = h.owner.canvas.displayGeometry(canvasSize: size)
        let start = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters, bearingDegrees: bounds.midpoint.bearingDegrees))
        let end = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters + 0.25, bearingDegrees: bounds.midpoint.bearingDegrees))
        let document = h.owner.document, selection = h.owner.canvas.selection, viewport = h.owner.canvas.viewport
        var publications = 0
        let observation = h.owner.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for cancelWithFocus in [false, true] {
            try h.mouse(.leftMouseDown, at: start, in: native)
            for _ in 0..<10 { try h.mouse(.leftMouseDragged, at: end, in: native) }
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(h.owner.document, document)
            if cancelWithFocus { h.window.makeFirstResponder(h.host); h.settle() }
            else { try h.key(53, "\u{1b}") }
            XCTAssertEqual(h.owner.canvas.selection, selection)
            XCTAssertEqual(h.owner.canvas.viewport, viewport)
            XCTAssertEqual(h.owner.document, document)
            XCTAssertEqual(h.owner.canvas.gesture.phase, .idle)
            try h.mouse(.leftMouseUp, at: end, in: native)
            XCTAssertEqual(h.owner.document, document)
        }
    }

    func testAcceptanceImagesAllToolsTwoLayerFrameStatusAndDeviceEditorWideAndNarrow() throws {
        let h = try Harness(); defer { h.close() }; h.installPatch()
        let original = h.owner.canvas.workspace.selectedLayer
        h.owner.canvas.updateWorkspace { _ = $0.insertCopiedLayers([.init(name: "Second", color: .blue, polarCells: original.polarCells)]) }
        _ = h.owner.canvas.perform(.selectAll)
        let directory = TestImageDirectory.make().appendingPathComponent("canvas-architektur")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [2160, 1080, 640] {
            h.window.setContentSize(.init(width: width, height: 1200)); h.settle()
            for tool in MetricCanvasTool.allCases {
                h.owner.canvas.select(tool: tool)
                h.owner.canvas.perform { $0.statusMessage = "Selection stopped at the field edge · 2 layers" }; h.settle()
                try capture(h.host, to: directory.appendingPathComponent("\(tool.rawValue)-\(width).png"))
            }
            h.layout.workspace.editsDeviceFields = true; h.settle()
            try capture(h.host, to: directory.appendingPathComponent("device-\(width).png"))
            h.layout.workspace.editsDeviceFields = false; h.settle()
        }
    }
    func testReferenceEditorUsesSameWindowRouteAndMirrorAtItsOwnRadius() throws {
        let h = try Harness(); defer { h.close() }
        let document = h.owner.document
        h.layout.workspace.editsDeviceFields = true; h.settle()
        let native = try h.pointer(), canvas = h.layout.workspace.deviceFields.canvas
        let metric = MetricScanPoint(xMeters: 1, yMeters: 3)
        let expected = PolarMetricGridCell(point: metric, grid: canvas.workspace.grid)
        XCTAssertEqual(canvas.selectionMaximumRadiusMeters, 50)
        for mirrored in [false, true] {
            if canvas.isHorizontallyMirrored != mirrored { canvas.toggleHorizontalMirror(); h.settle() }
            let point = canvas.displayGeometry(canvasSize: native.bounds.size).screenPoint(for: metric)
            try h.mouse(.leftMouseDown, at: point, in: native)
            try h.mouse(.leftMouseUp, at: point, in: native)
            XCTAssertEqual(canvas.selectedPolarCells, [expected])
            XCTAssertFalse(canvas.isDragging)
            XCTAssertEqual(h.owner.document, document)
        }
    }
    private func capture(_ view: NSView, to url: URL) throws {
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
