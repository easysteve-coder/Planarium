import AppKit
import SwiftUI
import XCTest
@testable import PlanariumDomain
import PlanariumApplication
import SickPLSMonitorKit
@testable import SickPLSMonitor

/// EDITOR-ANFASSER: Die echte Feldansicht (breit und schmal) mit markierter
/// Mehrfachauswahl auf dem 5-cm-Raster. Der Griff wird mit nativen
/// Mausereignissen durch den Produktionsresponder gegriffen; die Bilder
/// zeichnen gezeichneten Griff (weiß) und Trefferfläche (gelb) ein.
@MainActor final class EditorHandleHitTests: XCTestCase {
    /// Wie in `SelectionTempoTests`: headless bleibt `NSEvent.window` leer.
    private final class RoutedMouseEvent: NSEvent {
        let target: NSWindow
        let backing: NSEvent
        init(window: NSWindow, backing: NSEvent) { target = window; self.backing = backing; super.init() }
        required init?(coder: NSCoder) { fatalError("Unused test event decoder") }
        override var window: NSWindow? { target }
        override var windowNumber: Int { backing.windowNumber }
        override var type: NSEvent.EventType { backing.type }
        override var locationInWindow: NSPoint { backing.locationInWindow }
        override var modifierFlags: NSEvent.ModifierFlags { backing.modifierFlags }
        override var clickCount: Int { backing.clickCount }
    }

    private func pointer(in view: NSView) -> ScanFieldPointerEvents.PointerView? {
        if let p = view as? ScanFieldPointerEvents.PointerView, !p.isKeyboardOnly { return p }
        return view.subviews.compactMap(pointer).first
    }

    private func send(_ type: NSEvent.EventType, clicks: Int = 1, at location: CGPoint,
                      pointer: ScanFieldPointerEvents.PointerView, window: NSWindow) throws {
        let content = try XCTUnwrap(window.contentView)
        let hitPoint = content.superview?.convert(location, from: pointer) ?? content.convert(location, from: pointer)
        XCTAssertTrue(content.hitTest(hitPoint) === pointer, "AppKit hit test must reach the production responder")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: pointer.convert(location, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
        XCTAssertNil(pointer.handle(RoutedMouseEvent(window: window, backing: event)), "Production responder must consume the event")
    }

    private func flush(_ host: NSView) {
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    }

    @MainActor private struct Rig {
        let fixture: MonitorRootFixture
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let pointer: ScanFieldPointerEvents.PointerView
        var owner: SpatialInstrumentRuntimeModel { fixture.root.document }
        var canvasSize: CGSize { pointer.bounds.size }
    }

    private func rig(width: CGFloat) throws -> Rig {
        let fixture = try MonitorRootFixture(usesProductionGrid: true)
        let owner = fixture.root.document
        fixture.root.display.stop()
        // Zwei Ebenen mit demselben 10-Ringe-Block (≈ 50 cm × 68 cm) auf dem 5-cm-Raster.
        let grid = MetricSquareGrid.fiveCentimeter
        var cells: Set<PolarMetricGridCell> = []
        for ring in 8..<18 {
            for bearing in stride(from: -30.0, through: 30, by: 3) {
                let radius = (Double(ring) + 0.5) * grid.cellSizeMeters
                cells.insert(.init(point: .init(xMeters: sin(bearing * .pi / 180) * radius,
                    yMeters: cos(bearing * .pi / 180) * radius), grid: grid))
            }
        }
        owner.canvas.updateWorkspace(named: "Test block") {
            $0 = SpatialInstrumentWorkspace(grid: grid, layers: [
                .init(name: "A", color: .orange, polarCells: cells),
                .init(name: "B", color: .blue, polarCells: cells)])
        }
        let host = NSHostingView(rootView: AnyView(CartesianScanFieldView(editor: owner.canvas, profile: nil,
            activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner,
            simulationBadge: AnyView(EmptyView())).preferredColorScheme(.dark)))
        host.frame = .init(x: 0, y: 0, width: width, height: 900); host.wantsLayer = true
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFrontRegardless()
        flush(host)
        let found = try XCTUnwrap(pointer(in: host))
        XCTAssertTrue(owner.canvas.perform(.selectAll))
        flush(host)
        return Rig(fixture: fixture, host: host, window: window, pointer: found)
    }

    private func close(_ rig: Rig) {
        rig.pointer.stopListening(); rig.window.contentView = nil; rig.window.close(); rig.fixture.root.terminate {}
    }

    private func handlePoint(_ handle: CanvasSelectionHandle, _ rig: Rig) throws -> CGPoint {
        try XCTUnwrap(rig.owner.canvas.presentation.selectionHandleCenter(handle, canvasSize: rig.canvasSize))
    }

    func testNativeMouseGrabsHandleNextToItAndResizesWholeSelectionWideAndNarrow() throws {
        for width: CGFloat in [1260, 700] {
            let rig = try rig(width: width); defer { close(rig) }
            let canvas = rig.owner.canvas
            XCTAssertEqual(canvas.workspace.grid.cellSizeMeters, 0.05, accuracy: 1e-9)
            XCTAssertGreaterThan(canvas.presentation.selectedCells.count, 4)
            let size = rig.canvasSize
            let hit = canvas.presentation.selectionHandleHitRadius(canvasSize: size)
            XCTAssertGreaterThan(hit, 1.25, "old hit radius for 5 cm cells at 0.01 m/pt")
            try snapshot(rig, name: "mehrfachauswahl-\(Int(width))")
            for handle in [CanvasSelectionHandle.outerEnd, .outer, .innerStart] {
                let before = canvas.workspace, selection = canvas.presentation.selectedCells
                let center = try handlePoint(handle, rig)
                let offset = min(hit * 0.7, hit - 0.5)
                let drawnHalf = canvas.presentation.selectionHandleSize(canvasSize: size) / 2 - 0.5
                XCTAssertEqual(canvas.selectionHandle(at: .init(x: center.x + drawnHalf, y: center.y + drawnHalf), canvasSize: size), handle, "\(handle) \(width) sichtbare Quadratecke")
                let down = CGPoint(x: center.x + offset, y: center.y - offset)
                XCTAssertEqual(canvas.selectionHandle(at: down, canvasSize: size), handle, "\(handle) \(width)")
                let outwards: CGPoint = handle == .innerStart ? CGPoint(x: -14, y: 6) : CGPoint(x: 14, y: -14)
                try send(.leftMouseDown, at: down, pointer: rig.pointer, window: rig.window)
                try send(.leftMouseDragged, at: .init(x: down.x + outwards.x, y: down.y + outwards.y), pointer: rig.pointer, window: rig.window)
                XCTAssertEqual(canvas.presentation.gesture.phase, .resizing(handle), "\(handle) \(width)")
                try send(.leftMouseDragged, at: .init(x: down.x + 2 * outwards.x, y: down.y + 2 * outwards.y), pointer: rig.pointer, window: rig.window)
                try send(.leftMouseUp, at: .init(x: down.x + 2 * outwards.x, y: down.y + 2 * outwards.y), pointer: rig.pointer, window: rig.window)
                XCTAssertNotEqual(canvas.workspace, before, "\(handle) \(width): Auswahl wurde nicht verändert")
                XCTAssertTrue(canvas.presentation.selectedCells.count != selection.count || canvas.presentation.selectedCells != selection)
                XCTAssertEqual(canvas.presentation.gesture.phase, .idle)
                XCTAssertTrue(rig.owner.undo(), "genau ein Undo-Schritt")
                XCTAssertEqual(canvas.workspace, before, "\(handle) \(width)")
            }
        }
    }

    func testNativeDoubleClickOnHandleResizesInsteadOfReplacingSelection() throws {
        let rig = try rig(width: 1260); defer { close(rig) }
        let canvas = rig.owner.canvas
        let before = canvas.workspace, selection = canvas.presentation.selectedCells
        let down = try handlePoint(.outerEnd, rig)
        try send(.leftMouseDown, at: down, pointer: rig.pointer, window: rig.window)
        try send(.leftMouseUp, at: down, pointer: rig.pointer, window: rig.window)
        try send(.leftMouseDown, clicks: 2, at: down, pointer: rig.pointer, window: rig.window)
        XCTAssertEqual(canvas.presentation.selectedCells, selection)
        try send(.leftMouseDragged, at: .init(x: down.x + 15, y: down.y - 15), pointer: rig.pointer, window: rig.window)
        XCTAssertEqual(canvas.presentation.gesture.phase, .resizing(.outerEnd))
        try send(.leftMouseUp, clicks: 2, at: .init(x: down.x + 15, y: down.y - 15), pointer: rig.pointer, window: rig.window)
        XCTAssertNotEqual(canvas.workspace, before)
        XCTAssertTrue(rig.owner.undo()); XCTAssertEqual(canvas.workspace, before)
    }

    /// Bild: gezeichneter Griff (weiß) und Trefferfläche (gelb) je Griff.
    private func snapshot(_ rig: Rig, name: String) throws {
        let canvas = rig.owner.canvas
        let bitmap = try XCTUnwrap(rig.host.bitmapImageRepForCachingDisplay(in: rig.host.bounds))
        rig.host.cacheDisplay(in: rig.host.bounds, to: bitmap)
        let image = NSImage(size: rig.host.bounds.size); image.addRepresentation(bitmap)
        let origin = rig.pointer.convert(CGPoint.zero, to: rig.host)
        let hit = canvas.presentation.selectionHandleHitRadius(canvasSize: rig.canvasSize)
        let drawn = canvas.presentation.selectionHandleSize(canvasSize: rig.canvasSize)
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        // Gelb = tatsächliche Produktions-Trefferfläche: jeder Pixel wird durch
        // `selectionHandle(at:)` geprüft, nichts nachgebaut.
        NSColor.yellow.withAlphaComponent(0.45).setFill()
        for handle in CanvasSelectionHandle.allCases {
            let p = try handlePoint(handle, rig)
            let reach = Int(ceil(max(hit, drawn / 2 * 1.5))) + 2
            for dy in -reach...reach { for dx in -reach...reach {
                let q = CGPoint(x: p.x + CGFloat(dx), y: p.y + CGFloat(dy))
                guard canvas.selectionHandle(at: q, canvasSize: rig.canvasSize) == handle else { continue }
                // Host and pointer view are both flipped relative to the bitmap's bottom-left origin.
                NSBezierPath(rect: .init(x: origin.x + q.x - 0.5, y: rig.host.bounds.height - (origin.y + q.y) - 0.5, width: 1, height: 1)).fill()
            } }
            NSColor.white.setStroke()
            let x = origin.x + p.x, y = rig.host.bounds.height - (origin.y + p.y)
            let rect = NSBezierPath(rect: .init(x: x - drawn / 2, y: y - drawn / 2, width: drawn, height: drawn)); rect.lineWidth = 1; rect.stroke()
        }
        out.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(out.tiffRepresentation)))
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent_handoff/runs/editor-anfasser")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
