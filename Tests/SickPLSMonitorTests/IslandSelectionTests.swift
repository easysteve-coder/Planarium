import AppKit
import SickPLSCore
import SwiftUI
import XCTest
@testable import PlanariumApplication
@testable import PlanariumDomain
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class IslandSelectionTests: XCTestCase {
    private let target = SpatialRoutingTarget.midiNote(channel: 0)
    private func cell(_ ring: Int, _ index: Int) -> PolarMetricGridCell { .init(ring: ring, angularIndex: index) }
    private func layer(_ cells: Set<PolarMetricGridCell>, overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]) -> SpatialInstrumentLayer {
        .init(name: "Islands", color: .orange, polarCells: cells,
              routings: [.init(target: target, program: .singleNote(note: 60, velocity: 90, transition: .toggle))],
              polarCellOverrides: overrides)
    }
    private func point(_ cell: PolarMetricGridCell, canvas: CanvasSession, size: CGSize) -> CGPoint {
        let area = PolarMetricCellSegment(cell: cell, grid: canvas.workspace.grid)
        return canvas.displayGeometry(canvasSize: size).screenPoint(for:
            area.point(radiusMeters: area.midpoint.radiusMeters, bearingDegrees: area.midpoint.bearingDegrees))
    }
    private func doubleClick(_ cell: PolarMetricGridCell, flags: NSEvent.ModifierFlags = [],
                             native: ScanFieldPointerEvents.PointerView, host: NSView, canvas: CanvasSession) throws {
        let position = point(cell, canvas: canvas, size: native.bounds.size)
        XCTAssertTrue(native.bounds.contains(position))
        for clicks in [1, 2] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: native.convert(position, to: nil),
                    modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: try XCTUnwrap(native.window).windowNumber, context: nil,
                    eventNumber: clicks, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
                XCTAssertNil(native.handle(event))
                pump(host)
            }
        }
    }
    private func pump(_ host: NSView) {
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)); host.layoutSubtreeIfNeeded()
    }
    private func hosted(_ layers: [SpatialInstrumentLayer], width: Int = 900, profile: B0ScanProfile? = nil,
                        run: (ScanFieldPointerEvents.PointerView, NSHostingView<CartesianScanFieldView>, SpatialInstrumentRuntimeModel) throws -> Void) throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        owner.canvas.replaceWorkspace(.init(grid: .quarterMeter, layers: layers, preserveLayerStructure: true))
        owner.canvas.select(tool: .select)
        let host = NSHostingView(rootView: CartesianScanFieldView(editor: owner.canvas, profile: profile,
            activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner, simulationBadge: AnyView(Text("Offline"))))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 1000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.frame = .init(x: 0, y: 0, width: width, height: 1000)
        host.appearance = NSAppearance(named: .darkAqua); pump(host)
        func pointer(_ view: NSView) -> ScanFieldPointerEvents.PointerView? {
            if let p = view as? ScanFieldPointerEvents.PointerView, !p.isKeyboardOnly { return p }
            return view.subviews.compactMap(pointer).first
        }
        let native = try XCTUnwrap(pointer(host))
        defer { native.stopListening(); window.contentView = nil }
        try run(native, host, owner)
    }

    func testNativeDoubleClickSelectsOnlyClickedIslandAndOverrideSplitsBridge() throws {
        let seed = cell(2, 8), next = cell(2, 9), rest = cell(2, 10), far = cell(6, 18)
        let fixtures: [(String, SpatialInstrumentLayer, Set<PolarMetricGridCell>)] = [
            ("separate", layer([seed, next, far, cell(6, 19)]), [seed, next]),
            ("override", layer([seed, next, rest, cell(2, 11)], overrides:
                [next: [.init(target: target, value: .note(number: 72, velocity: 90))]]), [seed])
        ]
        for (name, patch, expected) in fixtures {
            for width in [900, 420] {
                try hosted([patch], width: width) { native, host, owner in
                    let document = owner.document, depth = owner.historyDepth
                    let revision = owner.document.revision
                    try doubleClick(seed, native: native, host: host, canvas: owner.canvas)
                    XCTAssertEqual(owner.canvas.selectedPolarCells, expected)
                    XCTAssertEqual(owner.document, document); XCTAssertEqual(owner.historyDepth, depth)
                    XCTAssertEqual(owner.document.revision, revision, "Selection must not compile an instrument")
                    try render(host, name: "island-\(name)-\(width).png")
                    if name == "override" {
                        try doubleClick(next, native: native, host: host, canvas: owner.canvas)
                        XCTAssertEqual(owner.canvas.selectedPolarCells, [next])
                        try render(host, name: "island-own-value-\(width).png")
                    }
                }
            }
        }
    }

    func testNativeDoubleClickCrossesUnequalRingDivisionButNotCorner() throws {
        let seed = cell(2, 8), overlap = cell(3, 16), corner = cell(3, 18)
        for width in [900, 420] {
            try hosted([layer([seed, overlap, corner])], width: width) { native, host, owner in
                try doubleClick(seed, native: native, host: host, canvas: owner.canvas)
                XCTAssertEqual(owner.canvas.selectedPolarCells, [seed, overlap])
                XCTAssertFalse(owner.canvas.selectedPolarCells.contains(corner))
                try render(host, name: "island-ring-change-\(width).png")
                try doubleClick(corner, native: native, host: host, canvas: owner.canvas)
                XCTAssertEqual(owner.canvas.selectedPolarCells, [corner])
            }
        }
    }

    func testNativeShiftAddsAndCommandTogglesWholeIslandWithoutFirstClickResidue() throws {
        let a = cell(2, 8), b = cell(2, 9), c = cell(6, 18), d = cell(6, 19)
        for width in [900, 420] {
            try hosted([layer([a, b, c, d])], width: width) { native, host, owner in
                try doubleClick(a, native: native, host: host, canvas: owner.canvas)
                try doubleClick(c, flags: .shift, native: native, host: host, canvas: owner.canvas)
                XCTAssertEqual(owner.canvas.selectedPolarCells, [a, b, c, d], "Shift's preliminary range must not survive")
                try render(host, name: "island-extended-\(width).png")
                try doubleClick(a, flags: .command, native: native, host: host, canvas: owner.canvas)
                XCTAssertEqual(owner.canvas.selectedPolarCells, [c, d])
                try render(host, name: "island-toggled-\(width).png")
                try doubleClick(a, flags: .command, native: native, host: host, canvas: owner.canvas)
                XCTAssertEqual(owner.canvas.selectedPolarCells, [a, b, c, d])
                try doubleClick(c, flags: [.command, .shift], native: native, host: host, canvas: owner.canvas)
                XCTAssertEqual(owner.canvas.selectedPolarCells, [a, b], "Command takes precedence over Shift")
            }
        }
    }

    func testSameFixturePartitionsSelectionAndToggleIncludingEqualOverridesAndMultipleRoutings() throws {
        let a = cell(2, 8), b = cell(2, 9), c = cell(2, 10), d = cell(3, 16), e = cell(6, 18)
        let cc = SpatialRoutingTarget.midiCC(channel: 0, controller: 1)
        var patch = layer([a, b, c, d, e], overrides: [
            b: [.init(target: target, value: .chord(notes: [60, 60], velocity: 90))],
            c: [.init(target: target, value: .note(number: 60, velocity: 91))],
            d: [.init(target: cc, value: .scalar(0.75))]
        ])
        patch.routings.append(.init(target: cc, program: .constant(0.5)))
        try hosted([patch]) { native, host, owner in
            let compiled = try SpatialInstrumentCompiler.compile(owner.document.spatial, revision: .newSession(), snapGrid: .quarterMeter)
            let routing = try XCTUnwrap(compiled.layers.first?.routings.first)
            XCTAssertEqual(compiled.layers.first?.snapRegionByCell, routing.toggleRegionByCell)
            for seed in patch.polarCells {
                try doubleClick(seed, native: native, host: host, canvas: owner.canvas)
                let fineSeed = try XCTUnwrap(try LegacyLatticeMigration.migrate(seed, in: .quarterMeter).cells.first)
                let anchor = try XCTUnwrap(routing.toggleRegionByCell[fineSeed])
                let toggleCells = Set(try routing.toggleRegionByCell.filter { $0.value == anchor }.keys.map {
                    try LegacyLatticeMigration.project($0, in: .quarterMeter)
                })
                XCTAssertEqual(owner.canvas.selectedPolarCells, toggleCells, "seed=\(seed)")
            }
            try doubleClick(a, native: native, host: host, canvas: owner.canvas)
            XCTAssertEqual(owner.canvas.selectedPolarCells, [a, b], "Explicit identical note/chord and layer default belong together")
        }
    }

    func testIslandFlowsThroughInspectorMoveHandleDeleteAndContextSelectLayer() throws {
        let a = cell(2, 8), b = cell(2, 9), far = cell(6, 18)
        let patch = layer([a, b, far])
        try hosted([patch]) { native, host, owner in
            let canvas = owner.canvas
            try doubleClick(a, native: native, host: host, canvas: canvas)
            XCTAssertEqual(canvas.applyToSelection(.setAction(.init(target: target, value: .note(number: 72, velocity: 87)))),
                           .success(.applied(changedCells: 2)))
            XCTAssertEqual(canvas.workspace.selectedLayer.polarCellOverrides.keys.sorted { $0.angularIndex < $1.angularIndex }, [a, b])
            XCTAssertNil(canvas.workspace.selectedLayer.polarCellOverrides[far])
            let original = canvas.workspace
            _ = canvas.handleKey(.up)
            XCTAssertNotEqual(canvas.workspace, original)
            XCTAssertTrue(canvas.workspace.selectedLayer.polarCells.contains(far))
            XCTAssertTrue(owner.undo()); XCTAssertEqual(canvas.workspace, original)
            pump(host)
            let bounds = try XCTUnwrap(canvas.selectionBounds)
            let from = canvas.displayGeometry(canvasSize: native.bounds.size).screenPoint(for: CanvasSelectionHandle.outer.point(in: bounds))
            XCTAssertTrue(canvas.beginDrag(at: from, canvasSize: native.bounds.size))
            XCTAssertEqual(canvas.draggedSelectionHandle, .outer)
            XCTAssertTrue(canvas.updateDrag(to: .init(x: from.x, y: from.y - 35), canvasSize: native.bounds.size))
            canvas.endDrag(canvasSize: native.bounds.size)
            XCTAssertTrue(canvas.workspace.selectedLayer.polarCells.contains(far))
            XCTAssertTrue(owner.undo()); pump(host)
            XCTAssertTrue(canvas.perform(.delete))
            XCTAssertEqual(canvas.workspace.selectedLayer.polarCells, [far])
            XCTAssertTrue(owner.undo()); pump(host)
            XCTAssertTrue(canvas.contextMenuSelection(at: point(a, canvas: canvas, size: native.bounds.size), canvasSize: native.bounds.size))
            XCTAssertTrue(SpatialCellBulkMenu.items(in: canvas.presentation).contains { $0.kind == .selectLayer && $0.isEnabled })
            XCTAssertEqual(SpatialCellBulkMenu.title(.selectLayer, in: canvas.presentation), "Select layer")
            host.rootView.performContextAction(.selectLayer)
            XCTAssertEqual(canvas.selectedPolarCells, [a, b, far])
        }
    }

    func testNativeIslandUsesTopmostEligibleLayerAndPerformKeepsSelection() throws {
        let a = cell(2, 8), b = cell(2, 9)
        let bottom = layer([a, b])
        var top = layer([a]); top.name = "Top"
        for unavailable in ["visible", "hidden", "locked"] {
            top.isVisible = unavailable != "hidden"; top.isLocked = unavailable == "locked"
            try hosted([bottom, top]) { native, host, owner in
                try doubleClick(a, native: native, host: host, canvas: owner.canvas)
                let expectedID = unavailable == "visible" ? top.id : bottom.id
                XCTAssertEqual(Set(owner.canvas.selectedCells.map(\.layerID)), [expectedID])
                XCTAssertEqual(owner.canvas.selectedPolarCells, unavailable == "visible" ? [a] : [a, b])
                let selected = owner.canvas.selectedCells
                owner.canvas.setPerformanceLocked(true); pump(host)
                try doubleClick(b, native: native, host: host, canvas: owner.canvas)
                XCTAssertEqual(owner.canvas.selectedCells, selected)
                XCTAssertFalse(SpatialCellBulkMenu.items(in: owner.canvas.presentation).contains { $0.kind == .selectLayer && $0.isEnabled })
            }
        }
    }

    func testIslandTraversalCannotUseExcludedCellsAsBridge() {
        let a = cell(2, 8), bridge = cell(2, 9), c = cell(2, 10)
        let patch = layer([a, bridge, c])
        XCTAssertEqual(SpatialCellContent.island(containing: a, layer: patch, grid: .quarterMeter), [a, bridge, c])
        XCTAssertEqual(SpatialCellContent.island(containing: a, layer: patch, grid: .quarterMeter, within: [a, c]), [a])
    }

    private func render(_ host: NSView, name: String) throws {
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}

extension IslandSelectionTests {
    func testAreaClickModifiersDoubleClickAndSwitchPreservesSelection() throws {
        for resolution in [90, 361] {
            let a = cell(2, 8), b = cell(2, 9), c = cell(6, 18), d = cell(6, 19)
            let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<resolution).map { _ in try .build(value: 200, fieldFlags: 0) })
            try hosted([layer([a,b,c,d])], profile: profile) { native, host, owner in
                let canvas = owner.canvas
                canvas.perform { $0.clickSelectsArea = true }
                let size = native.bounds.size
                @MainActor func click(_ cell: PolarMetricGridCell, _ modifiers: NSEvent.ModifierFlags = []) throws {
                    let position = point(cell, canvas: canvas, size: size)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: native.convert(position, to: nil), modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: try XCTUnwrap(native.window).windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
                        XCTAssertNil(native.handle(event)); pump(host)
                    }
                }
                try click(a); XCTAssertEqual(canvas.selectedPolarCells, [a,b], "resolution \(resolution)")
                try click(c, .shift); XCTAssertEqual(canvas.selectedPolarCells, [a,b,c,d])
                try click(a, .command); XCTAssertEqual(canvas.selectedPolarCells, [c,d])
                canvas.perform { $0.clickSelectsArea = false }
                XCTAssertEqual(canvas.selectedPolarCells, [c,d])
                canvas.perform { $0.clickSelectsArea = true }
                try doubleClick(a, native: native, host: host, canvas: canvas)
                XCTAssertEqual(canvas.selectedPolarCells, [a])
                canvas.perform { $0.clickSelectsArea = false }
                try click(c); XCTAssertEqual(canvas.selectedPolarCells, [c])
            }
        }
    }
}
