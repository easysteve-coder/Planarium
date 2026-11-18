import AppKit
import Combine
import SwiftUI
import XCTest
@testable import SickPLSMonitor

/// LIVE-NATIV: the stage path (shape layers via `updateLayer`) and the snapshot
/// path (`draw(_:)` replay) show the same drawing, top-left origin, scoped clip,
/// per-stroke dash and no SwiftUI involvement.
@MainActor final class LiveLayerViewTests: XCTestCase {
    private let size = CGSize(width: 120, height: 80)

    private func mounted(_ paint: @escaping (inout LiveCanvas) -> Void) -> (LiveLayerView, PresentingTestWindow) {
        let view = LiveLayerView(frame: .init(origin: .zero, size: size))
        view.paint = paint
        let container = NSView(frame: view.frame); container.wantsLayer = true; container.addSubview(view)
        let window = PresentingTestWindow(hosting: container, size: size)
        window.displayIfNeeded(); CATransaction.flush()
        return (view, window)
    }

    /// Stage path: the layer tree as Core Animation composes it.
    private func layerPixels(_ view: LiveLayerView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        // Bitmap origin is bottom-left; a flipped layer tree renders top-down.
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        try XCTUnwrap(view.layer).render(in: context)
        return rep
    }

    /// Snapshot path: `cacheDisplay`, as the offline pictures use it.
    private func snapshotPixels(_ view: LiveLayerView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Pixel at view coordinates (top-left origin) for either representation.
    private func color(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, flippedRows: Bool) -> NSColor {
        let sx = CGFloat(rep.pixelsWide) / size.width, sy = CGFloat(rep.pixelsHigh) / size.height
        let row = flippedRows ? Int((size.height - y) * sy) : Int(y * sy)
        return rep.colorAt(x: Int(x * sx), y: min(rep.pixelsHigh - 1, max(0, row)))?.usingColorSpace(.deviceRGB) ?? .clear
    }

    func testStageAndSnapshotShowTheSameTopLeftDrawing() throws {
        let (view, window) = mounted { canvas in
            canvas.fill(Path(CGRect(x: 0, y: 0, width: 30, height: 20)), with: .color(.red))
        }
        defer { window.tearDown() }
        XCTAssertEqual(view.visibleShapeCount, 1)
        for (rep, flipped) in [(try layerPixels(view), false), (try snapshotPixels(view), false)] {
            let inside = color(rep, x: 10, y: 8, flippedRows: flipped), below = color(rep, x: 10, y: 70, flippedRows: flipped)
            XCTAssertGreaterThan(inside.redComponent, 0.8, "Top-left fill is visible at the top")
            XCTAssertLessThan(below.alphaComponent, 0.1, "Bottom stays transparent")
        }
    }

    /// Codex review: a copy-and-clip GraphicsContext must not leak its clip.
    /// Fills after the clip scope are unclipped; a leaking clip hides the second disc.
    func testClipEndsWithItsScope() throws {
        let (view, window) = mounted { canvas in
            canvas.withClip(Path(CGRect(x: 0, y: 0, width: 40, height: 80))) {
                $0.fill(Path(ellipseIn: CGRect(x: 20, y: 20, width: 40, height: 40)), with: .color(.green))
            }
            canvas.fill(Path(ellipseIn: CGRect(x: 80, y: 30, width: 20, height: 20)), with: .color(.green))
            canvas.fill(Path(ellipseIn: CGRect(x: 80, y: 55, width: 20, height: 20)), with: .color(.green))
        }
        defer { window.tearDown() }
        XCTAssertEqual(view.visibleShapeCount, 3, "One shape per call, in call order")
        for rep in [try layerPixels(view), try snapshotPixels(view)] {
            XCTAssertGreaterThan(color(rep, x: 30, y: 40, flippedRows: false).greenComponent, 0.4, "Inside clip")
            XCTAssertLessThan(color(rep, x: 50, y: 40, flippedRows: false).alphaComponent, 0.1, "Clipped half is hidden")
            XCTAssertGreaterThan(color(rep, x: 90, y: 40, flippedRows: false).greenComponent, 0.4, "Fill after the scope is unclipped")
            XCTAssertGreaterThan(color(rep, x: 90, y: 65, flippedRows: false).greenComponent, 0.4)
        }
    }

    func testDashBelongsToItsStrokeAndTextIsDrawnFromItsBox() throws {
        let (view, window) = mounted { canvas in
            var dashed = Path(); dashed.move(to: .init(x: 0, y: 10)); dashed.addLine(to: .init(x: 120, y: 10))
            canvas.stroke(dashed, with: .color(.white), style: StrokeStyle(lineWidth: 4, dash: [4, 4]))
            var solid = Path(); solid.move(to: .init(x: 0, y: 30)); solid.addLine(to: .init(x: 120, y: 30))
            canvas.stroke(solid, with: .color(.white), lineWidth: 4)
            canvas.draw(text: "MMMM", font: .system(size: 20, weight: .bold), color: .yellow, at: .init(x: 4, y: 50), anchor: .topLeading)
        }
        defer { window.tearDown() }
        for rep in [try layerPixels(view), try snapshotPixels(view)] {
            let dashedLit = (0..<120).filter { color(rep, x: CGFloat($0), y: 10, flippedRows: false).alphaComponent > 0.5 }.count
            let solidLit = (0..<120).filter { color(rep, x: CGFloat($0), y: 30, flippedRows: false).alphaComponent > 0.5 }.count
            XCTAssertLessThan(dashedLit, 80, "Dashed stroke leaves gaps")
            XCTAssertGreaterThan(solidLit, 110, "The next stroke does not inherit the dash")
            let text = (50..<75).flatMap { y in (4..<60).map { (CGFloat($0), CGFloat(y)) } }
                .filter { color(rep, x: $0.0, y: $0.1, flippedRows: false).alphaComponent > 0.5 }.count
            let above = (35..<48).flatMap { y in (4..<60).map { (CGFloat($0), CGFloat(y)) } }
                .filter { color(rep, x: $0.0, y: $0.1, flippedRows: false).alphaComponent > 0.5 }.count
            XCTAssertGreaterThan(text, 60, "Glyphs below the top-leading anchor")
            XCTAssertEqual(above, 0, "Nothing above the anchor")
        }
    }

    func testHiddenPresentationShowsNothingAndClearsOldShapes() throws {
        let (view, window) = mounted { canvas in
            canvas.fill(Path(CGRect(x: 0, y: 0, width: 120, height: 80)), with: .color(.red))
        }
        defer { window.tearDown() }
        XCTAssertEqual(view.visibleShapeCount, 1)
        func settle() { window.displayIfNeeded(); CATransaction.flush(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        view.isPresenting = false; settle()
        XCTAssertEqual(view.visibleShapeCount, 0)
        XCTAssertLessThan(color(try layerPixels(view), x: 60, y: 40, flippedRows: false).alphaComponent, 0.1)
        view.isPresenting = true; settle()
        XCTAssertEqual(view.visibleShapeCount, 1, "Becoming visible draws the current state without a new input")
    }

    /// Codex review: merging same-colored translucent fills changes source-over
    /// composition. Overlap of two 0.5 fills must reach 0.75 on stage and in snapshots.
    func testTranslucentOverlapComposesLikeTwoFills() throws {
        let (view, window) = mounted { canvas in
            canvas.fill(Path(CGRect(x: 0, y: 0, width: 60, height: 80)), with: .color(.white.opacity(0.5)))
            canvas.fill(Path(CGRect(x: 40, y: 0, width: 60, height: 80)), with: .color(.white.opacity(0.5)))
        }
        defer { window.tearDown() }
        for rep in [try layerPixels(view), try snapshotPixels(view)] {
            XCTAssertEqual(color(rep, x: 20, y: 40, flippedRows: false).alphaComponent, 0.5, accuracy: 0.03)
            XCTAssertEqual(color(rep, x: 50, y: 40, flippedRows: false).alphaComponent, 0.75, accuracy: 0.03, "Overlap composes twice")
        }
    }

    /// Shape slots are reused across updates: clipped → unclipped, stroke → fill,
    /// fewer → more operations; no mask, dash or stroke survives in a reused slot.
    func testReusedShapeSlotsCarryNoStateBetweenUpdates() throws {
        var step = 0
        let (view, window) = mounted { canvas in
            switch step {
            case 0:
                canvas.withClip(Path(CGRect(x: 0, y: 0, width: 10, height: 80))) {
                    $0.fill(Path(CGRect(x: 0, y: 0, width: 120, height: 80)), with: .color(.red))
                }
                var line = Path(); line.move(to: .init(x: 0, y: 70)); line.addLine(to: .init(x: 120, y: 70))
                canvas.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 6, dash: [2, 10]))
            case 1:
                canvas.fill(Path(CGRect(x: 0, y: 0, width: 120, height: 40)), with: .color(.red))
            default:
                canvas.fill(Path(CGRect(x: 0, y: 0, width: 120, height: 40)), with: .color(.red))
                canvas.fill(Path(CGRect(x: 0, y: 50, width: 120, height: 30)), with: .color(.green))
                canvas.fill(Path(CGRect(x: 100, y: 0, width: 20, height: 80)), with: .color(.blue))
            }
        }
        defer { window.tearDown() }
        func settle() { view.needsDisplay = true; window.displayIfNeeded(); CATransaction.flush(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        step = 1; settle()
        XCTAssertEqual(view.visibleShapeCount, 1)
        var rep = try layerPixels(view)
        XCTAssertGreaterThan(color(rep, x: 60, y: 20, flippedRows: false).redComponent, 0.8, "The former clip mask is gone")
        XCTAssertLessThan(color(rep, x: 60, y: 70, flippedRows: false).alphaComponent, 0.1, "The former dashed stroke is gone")
        step = 2; settle()
        XCTAssertEqual(view.visibleShapeCount, 3)
        rep = try layerPixels(view)
        let green = color(rep, x: 30, y: 65, flippedRows: false)
        XCTAssertGreaterThan(green.greenComponent, 0.6); XCTAssertLessThan(green.blueComponent, 0.6, "Reused stroke slot is a plain green fill, not the blue stroke")
        let solid = (0..<100).filter { color(rep, x: CGFloat($0), y: 65, flippedRows: false).alphaComponent > 0.5 }.count
        XCTAssertGreaterThan(solid, 95, "No dash inherited")
    }

    /// Color glyphs have no outline; they fall back to a bitmap instead of vanishing.
    func testColorEmojiTextIsVisible() throws {
        let (view, window) = mounted { canvas in
            canvas.draw(text: "🎹", font: .system(size: 24), color: .white, at: .init(x: 10, y: 10), anchor: .topLeading)
        }
        defer { window.tearDown() }
        for rep in [try layerPixels(view), try snapshotPixels(view)] {
            let lit = (10..<40).flatMap { y in (10..<40).map { (CGFloat($0), CGFloat(y)) } }
                .filter { color(rep, x: $0.0, y: $0.1, flippedRows: false).alphaComponent > 0.5 }.count
            XCTAssertGreaterThan(lit, 50)
        }
    }

    /// A replaced source no longer drives the layer; the new one does.
    func testSubscriptionsFollowTheCurrentSource() {
        final class Source: ObservableObject { @Published var value = 0 }
        let view = LiveLayerView(frame: .init(origin: .zero, size: size))
        let window = PresentingTestWindow(hosting: view, size: size)
        defer { window.tearDown() }
        let subscriptions = LiveLayerSubscriptions(), a = Source(), b = Source()
        view.paint = { _ in }
        func draws(after change: () -> Void) -> Int {
            func settle() { window.displayIfNeeded(); CATransaction.flush(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            settle(); let before = view.drawCount; change(); settle(); return view.drawCount - before
        }
        subscriptions.redraw(view, on: [a.objectWillChange.eraseToAnyPublisher()], sources: [a])
        XCTAssertEqual(draws { a.value = 1 }, 1)
        subscriptions.redraw(view, on: [b.objectWillChange.eraseToAnyPublisher()], sources: [b])
        XCTAssertEqual(draws { a.value = 2 }, 0, "Old source is unsubscribed")
        XCTAssertEqual(draws { b.value = 1 }, 1)
        subscriptions.cancel()
        XCTAssertEqual(draws { b.value = 2 }, 0, "Dismantle releases every subscription")
    }

    /// Codex review: `.onSetNeedsDisplay` does not redraw on resize. A constant
    /// level must be redrawn for the new bounds without a new publication.
    func testMeterBarsRedrawOnResizeWithoutNewLevel() throws {
        let meter = MeterBarsView(frame: .init(x: 0, y: 0, width: 13, height: 100))
        let container = NSView(frame: .init(x: 0, y: 0, width: 40, height: 200)); container.wantsLayer = true; container.addSubview(meter)
        let window = PresentingTestWindow(hosting: container, size: .init(width: 40, height: 200))
        defer { window.tearDown() }
        func settle() { window.displayIfNeeded(); CATransaction.flush(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        meter.peaks = .init(left: 0.5, right: 0.5); settle()
        let drawn = meter.drawCount
        settle()
        XCTAssertEqual(meter.drawCount, drawn, "No redraw without a change")
        meter.setFrameSize(.init(width: 20, height: 180)); settle()
        XCTAssertGreaterThan(meter.drawCount, drawn, "Resize redraws the bars for the new bounds")
    }

    func testPointerEventsPassThrough() {
        let view = LiveLayerView(frame: .init(origin: .zero, size: size))
        XCTAssertNil(view.hitTest(.init(x: 10, y: 10)))
    }
}
