import AppKit
import SwiftUI
import XCTest
@testable import PlanariumApplication
@testable import PlanariumDomain
import SickPLSMonitorKit
@testable import SickPLSMonitor

/// FLÄCHENEDITOR-UI-1 offline images of the real field view, wide and narrow, for every state that looks different.
/// Set SICK_TEST_ARTIFACT_DIR to keep the PNGs; the checks below hold without looking at them.
@MainActor final class SurfaceFieldImageTests: XCTestCase {
    typealias Rig = SurfaceFieldNativeTests.Rig
    private let sizes: [(name: String, width: CGFloat, height: CGFloat)] = [("wide", 1180, 820), ("narrow", 420, 900)]

    private func output() throws -> URL {
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func snapshot(_ host: NSView, _ name: String, in directory: URL) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
        return bitmap
    }
    /// About one metre of table in front of the scanner: the scanner stays visible at the bottom and the 10 cm scale reads.
    private func tableView(_ r: Rig) {
        _ = r.owner.canvas.resetViewport(canvasSize: r.pointer.bounds.size)
        let size = r.pointer.bounds.size
        _ = r.owner.canvas.zoom(byFactor: 3.0, atScreenPoint: r.local(0, 0), canvasSize: size)
    }
    private func onScreen(_ r: Rig, _ x: Double, _ y: Double) -> Bool { r.pointer.bounds.insetBy(dx: 4, dy: 4).contains(r.local(x, y)) }
    private func strip(_ r: Rig) -> UUID { r.owner.document.channels[0].id }

    private func scene(_ name: String, build: (Rig) throws -> Void, check: (Rig, NSBitmapImageRep) throws -> Void) throws {
        let directory = try output()
        for (label, width, height) in sizes {
            let r = try SurfaceFieldNativeTests.makeRig(width: width, height: height)
            defer { r.tearDown() }
            tableView(r)
            try build(r)
            let bitmap = try snapshot(r.host, "surface-\(name)-\(label).png", in: directory)
            try check(r, bitmap)
        }
    }
    private func pixel(_ bitmap: NSBitmapImageRep, _ r: Rig, _ x: Double, _ y: Double) throws -> NSColor {
        let host = r.host.bounds.width, scale = Double(bitmap.pixelsWide) / Double(host)
        let p = r.pointer.convert(r.local(x, y), to: r.host)
        // The pointer view and the host share their origin handling of the offline image: y counts from the top.
        let top = Double(r.host.bounds.height) - Double(p.y)
        let flipped = r.host.isFlipped ? Double(p.y) : top
        return try XCTUnwrap(bitmap.colorAt(x: Int(Double(p.x) * scale), y: Int(flipped * scale))?.usingColorSpace(.sRGB))
    }
    private func background(_ c: NSColor) -> Bool { c.redComponent < 0.2 && c.greenComponent < 0.2 && c.blueComponent < 0.2 }

    func testSelectedRectangleWithHandles() throws {
        try scene("rect-selected", build: { r in
            let id = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 44, heightCm: 26), transform: .init(xCm: 0, yCm: 60), toLayer: r.owner.document.spatial.selectedLayerID))
            XCTAssertEqual(r.editor.selectedSurfaceIDs, [id])
        }, check: { r, bitmap in
            XCTAssertFalse(background(try pixel(bitmap, r, 0, 60)), "the surface is filled")
            XCTAssertGreaterThanOrEqual(r.editor.handleLayout(geometry: r.geometry).handles.count, 5, "corners and the turning handle, edges when there is room")
            XCTAssertTrue(background(try pixel(bitmap, r, 40, 100)), "outside stays the empty field: no cell mesh unless asked for")
        })
    }

    func testSeveralSurfacesOfOneLayerAndAMultipleSelection() throws {
        try scene("multi", build: { r in
            let layer = r.owner.document.spatial.selectedLayerID
            let a = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 30, heightCm: 20), transform: .init(xCm: -30, yCm: 50), toLayer: layer))
            let b = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 30, heightCm: 20), transform: .init(xCm: 30, yCm: 50), toLayer: layer))
            _ = try XCTUnwrap(r.editor.addSurface(shape: .circle(radiusCm: 14), transform: .init(xCm: 0, yCm: 90), toLayer: layer))
            XCTAssertEqual(r.owner.document.spatial.layers.flatMap(\.surfaces).count, 3, "three surfaces live in one layer")
            XCTAssertEqual(r.owner.document.spatial.layers.count, 1)
            XCTAssertTrue(r.editor.select([a, b]))
        }, check: { r, bitmap in
            XCTAssertEqual(r.editor.selectedSurfaceIDs.count, 2)
            XCTAssertFalse(background(try pixel(bitmap, r, -30, 50))); XCTAssertFalse(background(try pixel(bitmap, r, 0, 90)))
            XCTAssertFalse(r.editor.handleLayout(geometry: r.geometry).handles.isEmpty)
        })
    }

    func testCircleAndPolygonAndRingSector() throws {
        try scene("circle-polygon", build: { r in
            let layer = r.owner.document.spatial.selectedLayerID
            _ = try XCTUnwrap(r.editor.addSurface(shape: .circle(radiusCm: 18), transform: .init(xCm: -32, yCm: 70), toLayer: layer))
            _ = try XCTUnwrap(r.editor.addSurface(shape: .ringSector(fromCm: 100, toCm: 130, fromDegrees: -30, toDegrees: 30), transform: .identity, toLayer: layer))
            _ = try XCTUnwrap(r.editor.addSurface(shape: .polygon(pointsCm: [.init(x: -20, y: -15), .init(x: 22, y: -12), .init(x: 28, y: 16), .init(x: 0, y: 26), .init(x: -26, y: 12)]),
                                                   transform: .init(xCm: 30, yCm: 60), toLayer: layer))
        }, check: { r, bitmap in
            XCTAssertFalse(background(try pixel(bitmap, r, -32, 70)), "circle")
            XCTAssertFalse(background(try pixel(bitmap, r, 30, 60)), "polygon")
            XCTAssertEqual(r.editor.handleLayout(geometry: r.geometry).handles.filter { if case .polygonPoint = $0.kind { return true }; return false }.count, 5)
        })
    }

    func testInvalidPolygonDraftIsNamedInRed() throws {
        try scene("polygon-invalid", build: { r in
            r.editor.select(tool: .polygon)
            for p in [(-30.0, 40.0), (30, 90), (30, 40), (-30, 90)] { try r.click(p) }
            XCTAssertNotNil(r.editor.polygon?.message)
            XCTAssertFalse(r.editor.polygon?.canClose ?? true)
        }, check: { r, _ in
            XCTAssertEqual(r.owner.document.spatial.layers.flatMap(\.surfaces).count, 0, "an invalid draft never reaches the document")
            XCTAssertNotNil(r.editor.polygon)
        })
    }

    func testControllerCourseAsGradientWithArrowAndLegend() throws {
        try scene("cc-gradient", build: { r in
            let id = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 70, heightCm: 30), transform: .init(xCm: 0, yCm: 60), toLayer: r.owner.document.spatial.selectedLayerID))
            let routing = try XCTUnwrap(r.surface(id)?.routings.first?.id)
            XCTAssertTrue(r.editor.setPlays(routing, .controller))
            XCTAssertTrue(r.editor.setValueColors([.init(red: 0.1, green: 0.2, blue: 0.9), .init(red: 1, green: 0.2, blue: 0.1)]))
        }, check: { r, bitmap in
            let surface = try XCTUnwrap(r.surfaces.first)
            let coding = try XCTUnwrap(SurfaceValueCoding(surface: surface, routingID: surface.routings[0].id))
            XCTAssertEqual(coding.legend, "CC74 · 0 → 127")
            let low = try pixel(bitmap, r, 25, 49), high = try pixel(bitmap, r, 25, 71)
            XCTAssertGreaterThan(high.redComponent, low.redComponent + 0.15, "the gradient runs from blue to red along the arrow")
            XCTAssertGreaterThan(low.blueComponent, high.blueComponent + 0.1)
        })
    }

    /// Two controller assignments with different arrows on one surface: the picture follows the assignment the inspector has chosen.
    private func twoCourses(_ r: Rig, choose second: Bool) throws {
        let id = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 70, heightCm: 30), transform: .init(xCm: 0, yCm: 60), toLayer: r.owner.document.spatial.selectedLayerID))
        let first = try XCTUnwrap(r.surface(id)?.routings.first?.id)
        XCTAssertTrue(r.editor.setPlays(first, .controller))
        XCTAssertTrue(r.editor.setValueColors([.init(red: 0.1, green: 0.2, blue: 0.9), .init(red: 1, green: 0.2, blue: 0.1)]))
        XCTAssertTrue(r.editor.setArrow(first, bearingDegrees: 90))
        XCTAssertTrue(r.editor.addRouting(copying: first))
        let copy = try XCTUnwrap(r.surface(id)?.routings.last?.id)
        XCTAssertTrue(r.editor.updateRouting(copy) { $0.target = $0.target.withControllerNumber(21); $0.ccNumber = 21 })
        XCTAssertTrue(r.editor.setArrow(copy, bearingDegrees: 0))
        XCTAssertTrue(r.editor.setValueRange(copy, from: 10, to: 100))
        r.editor.selectRouting(second ? copy : first)
    }
    private func red(_ c: NSColor) -> CGFloat { c.redComponent - c.blueComponent }

    func testTheChosenAssignmentDecidesWhichCourseTheSurfaceShows() throws {
        for second in [false, true] {
            try scene(second ? "two-courses-second" : "two-courses-first", build: { r in try self.twoCourses(r, choose: second) }, check: { r, bitmap in
                let surface = try XCTUnwrap(r.surfaces.first)
                let chosen = try XCTUnwrap(r.editor.axisRoutingID)
                XCTAssertEqual(chosen, surface.routings[second ? 1 : 0].id)
                let drawn = SurfacePreparedCache().prepare(r.owner.document, chosen: (surface.id, chosen))
                XCTAssertEqual(drawn.first?.routingID, chosen, "prepared for the chosen assignment")
                XCTAssertEqual(drawn.first?.coding?.legend, second ? "CC21 · 10 → 100" : "CC74 · 0 → 127")
                let left = try pixel(bitmap, r, -25, 54), right = try pixel(bitmap, r, 25, 54)
                let top = try pixel(bitmap, r, -14, 70), bottom = try pixel(bitmap, r, -14, 50)
                if second {
                    XCTAssertGreaterThan(red(top), red(bottom) + 0.15, "the second course rises toward the front")
                    XCTAssertEqual(red(left), red(right), accuracy: 0.12, "and not along the first one's arrow")
                } else {
                    XCTAssertGreaterThan(red(right), red(left) + 0.15, "the first course rises to the right")
                    XCTAssertEqual(red(top), red(bottom), accuracy: 0.12)
                }
                // The handle that belongs to the chosen assignment sits at the end of the chosen arrow.
                let tip = try XCTUnwrap(r.editor.handleLayout(geometry: r.geometry).handles.first { $0.kind.isAxis })
                XCTAssertEqual(tip.kind, .axisTip(routingID: chosen))
            })
        }
        // The cache rebuilds a surface when only the chosen assignment changes.
        let r = try SurfaceFieldNativeTests.makeRig(); defer { r.tearDown() }
        try twoCourses(r, choose: false)
        let surface = try XCTUnwrap(r.surfaces.first)
        let cache = SurfacePreparedCache()
        let one = cache.prepare(r.owner.document, chosen: (surface.id, surface.routings[0].id)).first
        let two = cache.prepare(r.owner.document, chosen: (surface.id, surface.routings[1].id)).first
        XCTAssertTrue(one !== two); XCTAssertEqual(one?.routingID, surface.routings[0].id); XCTAssertEqual(two?.routingID, surface.routings[1].id)
        XCTAssertTrue(two === cache.prepare(r.owner.document, chosen: (surface.id, surface.routings[1].id)).first, "unchanged input keeps the prepared shape")
    }

    /// The surface layer (scale bar, scanner cross, play area, exact shapes) belongs to the surface mode only: the advanced
    /// cell editor of the older presets keeps its own picture and is not drawn over.
    func testTheCellEditorModeIsNotDrawnOverBySurfaceOverlays() throws {
        let directory = try output()
        func brightPixels(_ r: Rig, _ bitmap: NSBitmapImageRep) -> Int {
            let scale = Double(bitmap.pixelsWide) / Double(r.host.bounds.width)
            let rect = r.geometry.canvasRect
            // The strip of the scale bar at the lower left corner of the canvas.
            let y = Int((Double(r.pointer.convert(CGPoint(x: 0, y: rect.maxY - 14), to: r.host).y)) * scale)
            var count = 0
            for dy in -3...3 { for x in Int((rect.minX + 14) * scale)..<Int((rect.minX + 74) * scale) {
                if let c = bitmap.colorAt(x: x, y: max(0, y + dy))?.usingColorSpace(.sRGB), c.redComponent > 0.6, c.greenComponent > 0.6, c.blueComponent > 0.6 { count += 1 }
            } }
            return count
        }
        var result: [String: [Int]] = [:]
        for (label, width, height) in sizes {
            for cells in [false, true] {
                let r = try SurfaceFieldNativeTests.makeRig(width: width, height: height)
                defer { r.tearDown() }
                tableView(r)
                _ = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 44, heightCm: 26), transform: .init(xCm: 0, yCm: 60), toLayer: r.owner.document.spatial.selectedLayerID))
                if cells { r.editor.setMode(.cells) }
                let bitmap = try snapshot(r.host, "surface-\(cells ? "cells-mode" : "surface-mode")-\(label).png", in: directory)
                result["\(label)-\(cells)", default: []].append(brightPixels(r, bitmap))
            }
            XCTAssertGreaterThan(result["\(label)-false"]?.first ?? 0, 20, "the surface mode draws the scale bar")
            XCTAssertEqual(result["\(label)-true"]?.first ?? 99, 0, "the cell editor mode draws no surface overlay")
        }
    }

    func testTurningTheArrowShowsADraftOfTheNewDirectionAndCommitsNothingUntilLetGo() throws {
        let r = try SurfaceFieldNativeTests.makeRig(width: 1180, height: 820); defer { r.tearDown() }
        tableView(r)
        let id = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 70, heightCm: 30), transform: .init(xCm: 0, yCm: 60), toLayer: r.owner.document.spatial.selectedLayerID))
        XCTAssertTrue(r.editor.setPlays(try XCTUnwrap(r.surface(id)?.routings.first?.id), .controller))
        r.editor.select(tool: .select)
        let before = try snapshot(r.host, "surface-arrow-before.png", in: try output())
        let tip = try XCTUnwrap(r.editor.handleLayout(geometry: r.geometry).handles.first { $0.kind.isAxis }).center
        let document = r.owner.document, depth = r.owner.historyDepth
        r.send(try r.event(.leftMouseDown, tip))
        let up = r.local(60, 60)
        r.send(try r.event(.leftMouseDragged, CGPoint(x: (tip.x + up.x) / 2, y: (tip.y + up.y) / 2)))
        r.send(try r.event(.leftMouseDragged, up))
        let preview = try XCTUnwrap(r.editor.preview?.arrow, "the sketch carries the new arrow")
        XCTAssertEqual(preview.degrees, 0, accuracy: 15)
        XCTAssertEqual(r.owner.document, document, "nothing is committed while dragging"); XCTAssertEqual(r.owner.historyDepth, depth)
        let during = try snapshot(r.host, "surface-arrow-during.png", in: try output())
        var changed = 0
        for x in 0..<min(before.pixelsWide, during.pixelsWide) { for y in 0..<min(before.pixelsHigh, during.pixelsHigh) {
            guard let a = before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let b = during.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.3 { changed += 1 }
        } }
        XCTAssertGreaterThan(changed, 30, "the dashed arrow is drawn while the arrow is turned")
        r.send(try r.event(.leftMouseUp, up))
        XCTAssertNotEqual(r.owner.document, document); XCTAssertEqual(r.owner.historyDepth, depth + 1)
    }

    func testScaleStepsWithNoteNames() throws {
        try scene("scale-steps", build: { r in
            let id = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 84, heightCm: 30), transform: .init(xCm: 0, yCm: 60), toLayer: r.owner.document.spatial.selectedLayerID))
            let routing = try XCTUnwrap(r.surface(id)?.routings.first?.id)
            XCTAssertTrue(r.editor.setPlays(routing, .scale))
            XCTAssertTrue(r.editor.updateRouting(routing) { $0.scale = .minorPentatonic; $0.rootMIDINote = 57; $0.lowestMIDINote = 57; $0.highestMIDINote = 69 })
        }, check: { r, bitmap in
            let surface = try XCTUnwrap(r.surfaces.first)
            let coding = try XCTUnwrap(SurfaceValueCoding(surface: surface, routingID: surface.routings[0].id))
            XCTAssertEqual(coding.steps.map(\.name), ["A3", "C4", "D4", "E4", "G4", "A4"])
            let left = try pixel(bitmap, r, -35, 52), right = try pixel(bitmap, r, 35, 52)
            XCTAssertFalse(background(left)); XCTAssertFalse(background(right))
        })
    }

    func testAnExactAreaOfAnOlderPresetShowsDisabledHandlesWithReason() throws {
        try scene("legacy-area", build: { r in
            let cells = Set((0..<14).flatMap { ring in (0..<20).map { PolarDeviceLattice(ring: 50 + ring, sector: 170 + $0)! } })
            let old = SpatialDocumentLayer(id: UUID(), name: "Old", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: cells, routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [60, 64, 67], velocity: 100, transition: .retrigger))], cellOverrides: [:])
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [old], selectedLayerID: old.id)
            try r.owner.edit { $0.spatial = spatial }
            let before = r.owner.document
            // Looking at the area and choosing it changes nothing in the document.
            r.editor.select(tool: .select)
            try r.click((0, 56))
            XCTAssertEqual(r.owner.document, before)
            XCTAssertEqual(r.editor.legacyLayer?.id, old.id)
            XCTAssertTrue(r.owner.applySurfaceEdit(.promoteLayer(layerID: old.id)))
            XCTAssertTrue(r.editor.select([old.id]))
        }, check: { r, _ in
            let layout = r.editor.handleLayout(geometry: r.geometry)
            XCTAssertFalse(layout.handles.isEmpty)
            XCTAssertTrue(layout.handles.allSatisfy { !$0.isEnabled && $0.disabledReason?.isEmpty == false })
        })
    }

    func testInspectorOfAControllerSurfaceNarrowAndWide() throws {
        let directory = try output()
        for (label, width, height) in [("wide", CGFloat(360), CGFloat(980)), ("narrow", CGFloat(250), CGFloat(980))] {
            let r = try SurfaceFieldNativeTests.makeRig(width: 900, height: 700)
            defer { r.tearDown() }
            let id = try XCTUnwrap(r.editor.addSurface(shape: .rectangle(widthCm: 70, heightCm: 30), transform: .init(xCm: 0, yCm: 60), toLayer: r.owner.document.spatial.selectedLayerID))
            let routing = try XCTUnwrap(r.surface(id)?.routings.first?.id)
            XCTAssertTrue(r.editor.setPlays(routing, .controller))
            let view = SurfaceInspectorView(model: r.editor).padding(8).frame(width: width, alignment: .leading)
                .background(Color(red: 0.115, green: 0.118, blue: 0.130)).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.frame = .init(x: 0, y: 0, width: width, height: height); host.wantsLayer = true
            _ = try snapshot(host, "surface-inspector-cc-\(label).png", in: directory)
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1, "the inspector fits its column at \(label)")
        }
    }
}

extension SurfaceFieldNativeTests.Rig {
    func surface(_ id: UUID) -> SpatialSurface? { surfaces.first { $0.id == id } }
}
