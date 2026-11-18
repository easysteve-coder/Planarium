import AppKit
import SwiftUI
import XCTest
import PlanariumPresets
import PlanariumDomain
import SickPLSMonitorKit
@testable import SickPLSMonitor

/// Offline visual evidence for the exchange controls.  It hosts SwiftUI only;
/// no application, device, MIDI, or audio run is involved.
@MainActor final class PresetExchangeRenderingTests: XCTestCase {
    func testPresetButtonsOccupySecondRowAndSelectionKeepsFullWidthInEditAndPerform() throws {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph)
        defer { fixture.root.terminate {} }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = PresetControlModel(store: .init(directory: directory.appendingPathComponent("preset-buttons-store")),
                                       documentOwner: fixture.root.document, factoryPresets: .empty)
        let name = "Evening Ensemble - Bass Chords and a Singing Lead"
        model.draftName = name
        XCTAssertTrue(model.save())
        XCTAssertNotNil(model.load(name))
        fixture.root.document.canvas.renameSelectedLayer("Unsaved layer")
        XCTAssertTrue(model.presentationIsDirty)
        let labels = ["Save preset (⌘S)", "Save preset as (⌘⇧S)", "Edit description",
                      "Import presets (⌘⇧I)", "Export preset (⌘⇧E)", "Delete preset"]
        for perform in [false, true] {
            fixture.root.document.canvas.setPerformanceLocked(perform)
            for width in [560, 280] {
                let host = NSHostingView(rootView: PresetBarView(model: model, performanceOnly: perform)
                    .preferredColorScheme(.dark).padding(8).background(StageTheme.workspace)
                    .frame(width: CGFloat(width), height: 180, alignment: .topLeading))
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 180),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                host.frame = .init(x: 0, y: 0, width: width, height: 180)
                host.appearance = NSAppearance(named: .darkAqua)
                host.wantsLayer = true
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                host.layoutSubtreeIfNeeded()
                let elements = accessibilityElements(window)
                func control(_ label: String) throws -> CGRect {
                    let element = try XCTUnwrap(elements.first { accessibilityLabel($0) == label },
                        "Missing \(label): \(elements.map { accessibilityLabel($0) ?? String(describing: type(of: $0)) })")
                    return (element as? NSAccessibilityProtocol)?.accessibilityFrame()
                        ?? (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                }
                let picker = try control("Preset")
                XCTAssertGreaterThan(picker.width, CGFloat(width - (perform ? 40 : 80)))
                if perform {
                    for label in labels + ["Refresh preset list"] {
                        XCTAssertFalse(elements.contains { accessibilityLabel($0) == label }, label)
                    }
                } else {
                    let refresh = try control("Refresh preset list")
                    XCTAssertEqual(picker.midY, refresh.midY, accuracy: 2)
                    XCTAssertLessThanOrEqual(picker.maxX, refresh.minX)
                    let buttons = try labels.map { try control($0) }
                    for button in buttons {
                        XCTAssertLessThan(button.maxY, picker.minY, "Actions belong below the selection")
                        XCTAssertEqual(button.midY, buttons[0].midY, accuracy: 2)
                        XCTAssertGreaterThanOrEqual(button.minX, 0)
                        XCTAssertLessThanOrEqual(button.maxX, CGFloat(width))
                    }
                    for index in 1..<buttons.count {
                        XCTAssertLessThanOrEqual(buttons[index - 1].maxX, buttons[index].minX)
                    }
                }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    directory.appendingPathComponent("preset-buttons-\(perform ? "perform" : "edit")-\(width).png"))
            }
        }
        let before = fixture.root.document.document
        model.requestSave()
        XCTAssertEqual(model.notice, InstrumentAction.performanceLockReason)
        XCTAssertEqual(fixture.root.document.document, before)
        XCTAssertNotNil(model.load(name, decision: .discard))
        XCTAssertTrue(fixture.root.document.canvas.isPerformanceLocked)
        XCTAssertEqual(graph.starts, 0)
    }

    private func accessibilityLabel(_ element: NSObject) -> String? {
        (element as? NSAccessibilityProtocol)?.accessibilityLabel()
            ?? (element.responds(to: NSSelectorFromString("accessibilityLabel"))
                ? element.value(forKey: "accessibilityLabel") as? String : nil)
            ?? element.accessibilityAttributeValue(.description) as? String
            ?? element.accessibilityAttributeValue(.title) as? String
    }

    private func accessibilityElements(_ value: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 30, let element = value as? NSObject else { return [] }
        let accessible = element as? any NSAccessibilityProtocol
        let children = accessible?.accessibilityChildren()
            ?? (element.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? element.value(forKey: "accessibilityChildren") as? [Any] : nil)
            ?? element.accessibilityAttributeValue(.children) as? [Any] ?? []
        return [element] + children.flatMap { accessibilityElements($0, depth: depth + 1) }
    }

    func testPresetDialogStatesRenderWideAndNarrow() throws {
        let fixture = try MonitorRootFixture()
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = PresetControlModel(store: .init(directory: directory.appendingPathComponent("presets")),
                                       documentOwner: fixture.root.document, factoryPresets: .standard)
        for width in [560, 280] {
            try render(PresetBarView(model: model), width: CGFloat(width), height: 220,
                       name: "preset-none-\(width).png", directory: directory)
        }
        model.draftName = "Own"; XCTAssertTrue(model.save()); XCTAssertNotNil(model.load("Own"))
        fixture.root.document.canvas.renameSelectedLayer("Unsaved")
        XCTAssertTrue(model.isDirty)
        for width in [560, 280] {
            try render(PresetBarView(model: model), width: CGFloat(width), height: 220,
                       name: "preset-own-dirty-\(width).png", directory: directory)
        }
        XCTAssertNotNil(model.load("Factory 00 Blank Channel", decision: .discard))
        for width in [560, 280] {
            try render(PresetBarView(model: model), width: CGFloat(width), height: 220,
                       name: "preset-factory-\(width).png", directory: directory)
        }
        model.beginSaveAs()
        for width in [560, 280] {
            try render(PresetSaveSheet(model: model), width: CGFloat(width), height: 300,
                       name: "preset-save-as-\(width).png", directory: directory)
        }
    }
    func testPresetExchangeAndLayerInspectorRenderWideAndNarrow() throws {
        let fixture = try MonitorRootFixture()
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let presets = PresetControlModel(
            store: .init(directory: directory.appendingPathComponent("presets")),
            documentOwner: fixture.root.document,
            factoryPresets: .empty
        )
        presets.draftName = "Exchange"
        let presetView = PresetBarView(model: presets).preferredColorScheme(.dark)
        try render(presetView, width: 560, height: 250, name: "austausch-preset-wide.png", directory: directory)
        try render(presetView, width: 280, height: 300, name: "austausch-preset-narrow.png", directory: directory)

        let inspector = SpatialLayerInspectorView(editor: fixture.root.document.canvas, audioUnits: .init(document: fixture.root.document, source: EmptyCatalog()),
                                                   midiOutput: fixture.root.midi, spatialInstrument: fixture.root.document, evaluationCounter: nil)
            .preferredColorScheme(.dark)
        try render(inspector, width: 560, height: 480, name: "austausch-layers-wide.png", directory: directory)
        try render(inspector, width: 280, height: 560, name: "austausch-layers-narrow.png", directory: directory)
    }

    /// Offline proof for OWNER-LAUF-0910B: the actual six-scene factory
    /// document must keep a muted selected row legible, and the layer
    /// inspector must remain layer-oriented when a switch cell is selected.
    func testOwner0910BPreset30LayerAndSwitchInspectorImagesWideAndNarrow() throws {
        let fixture = try MonitorRootFixture()
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = fixture.root.document
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmony 30 Mode Wheel"))
        try owner.applyPresetDocument(try PresetDocumentReader.read(data).get().replacing(owner.document))
        XCTAssertEqual(owner.canvas.workspace.scenes.count, 6)
        let catalog = AudioCatalogModel(document: owner, source: EmptyCatalog())

        // The row below makes truncation visible in the same actual preset:
        // its six scene points must still begin in the common scene column.
        let longNamedLayer = try XCTUnwrap(owner.canvas.workspace.layers.last)
        owner.canvas.updateWorkspace {
            $0.updateLayer(longNamedLayer.id) { $0.name = "A deliberately long layer name for scene-column proof" }
        }
        XCTAssertEqual(owner.canvas.workspace.layers.last?.name, "A deliberately long layer name for scene-column proof")

        let muted = try XCTUnwrap(owner.canvas.workspace.layers.first(where: { !$0.isActive }))
        owner.canvas.updateWorkspace { $0.selectLayer(muted.id) }
        XCTAssertEqual(owner.canvas.workspace.selectedLayerID, muted.id)
        XCTAssertFalse(owner.canvas.workspace.selectedLayer.isActive)
        let mutedInspector = SpatialLayerInspectorView(editor: owner.canvas, audioUnits: catalog,
            midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
            .preferredColorScheme(.dark)
        try render(mutedInspector, width: 840, height: 900,
                   name: "owner-0910b-preset30-muted-scenes-wide.png", directory: directory)
        try render(mutedInspector, width: 360, height: 900,
                   name: "owner-0910b-preset30-muted-scenes-narrow.png", directory: directory)

        let switchLayer = try XCTUnwrap(owner.canvas.workspace.layers.first { layer in
            layer.routings.contains { if case .sceneSwitch = $0.target { return true }; return false }
        })
        owner.canvas.updateWorkspace { $0.selectLayer(switchLayer.id) }
        let cell = try XCTUnwrap(owner.canvas.workspace.selectedLayer.polarCells.first)
        let size = CGSize(width: 840, height: 900)
        let center = SpatialFieldPlan.center(.init(cell: cell, grid: owner.canvas.workspace.grid))
        let point = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport)
            .screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
        _ = owner.canvas.selectCell(atScreenPoint: point, canvasSize: size)
        XCTAssertEqual(owner.canvas.selectedPolarCell, cell)
        let switchInspector = SpatialLayerInspectorView(editor: owner.canvas, audioUnits: catalog,
            midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
            .preferredColorScheme(.dark)
        try render(switchInspector, width: 840, height: 900,
                   name: "owner-0910b-layer-inspector-switch-cell-wide.png", directory: directory)
        try render(switchInspector, width: 360, height: 900,
                   name: "owner-0910b-layer-inspector-switch-cell-narrow.png", directory: directory)
    }

    private func render<Content: View>(_ view: Content, width: CGFloat, height: CGFloat, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: view.background(Color(red: 0.115, green: 0.118, blue: 0.130)))
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "PresetExchange", code: 1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "PresetExchange", code: 2) }
        try data.write(to: directory.appendingPathComponent(name))
    }
}
