import AppKit
import SwiftUI
import XCTest
import PlanariumDomain
import PlanariumPresets
import SickPLSCore
import SickPLSMonitorKit
@testable import SickPLSMonitor

/// Hosts actual product views with pure profiles and fake output boundaries.
@MainActor final class Bundle1010RenderingTests: XCTestCase {
    func testActualPresetMenuCarriesVerbatimTooltipAndLoadsViaItsAction() {
        var selected: String?
        let target = PresetMenuTarget { selected = $0 }
        let prose = "A♭–B♭–C. Source: Example, p. 2"
        let menu = PresetSelectionMenu.make(names: ["Described", "Empty"], summaries: ["Described": prose], selected: "Empty", target: target)
        XCTAssertEqual(menu.items[0].toolTip, prose)
        XCTAssertNil(menu.items[1].toolTip)
        XCTAssertEqual(menu.items[1].state, .on)
        target.choose(menu.items[0])
        XCTAssertEqual(selected, "Described")
    }
    func testDescriptionsLoadedCollapsedExpandedAndEditorWideNarrow() throws {
        let fixture = try MonitorRootFixture()
        let directory = TestImageDirectory.make()
        let model = PresetControlModel(store: .init(directory: directory.appendingPathComponent("presets")),
                                       documentOwner: fixture.root.document)
        XCTAssertNotNil(model.load("Harmonie 03 Episch", decision: .discard))
        XCTAssertTrue(model.loadedSummary.contains("Source: Lizzio"))
        for width in [560, 280] {
            for expanded in [false, true] {
                try render(PresetBarView(model: model, aboutInitiallyExpanded: expanded),
                           width: CGFloat(width), height: expanded ? 430 : 290,
                           name: "preset-about-\(expanded ? "open" : "closed")-\(width).png", directory: directory)
            }
        }
        model.draftName = "Epic copy"
        for width in [560, 280] {
            try render(PresetBarView(model: model, summaryEditorInitiallyExpanded: true),
                       width: CGFloat(width), height: 450,
                       name: "preset-editor-\(width).png", directory: directory)
        }
        model.draftSummary = String(repeating: "x", count: 1001)
        XCTAssertFalse(model.save())
        for width in [560, 280] {
            try render(PresetBarView(model: model, summaryEditorInitiallyExpanded: true),
                       width: CGFloat(width), height: 450,
                       name: "preset-summary-too-long-\(width).png", directory: directory)
        }
        XCTAssertNotNil(model.load("Factory 00 Blank Channel", decision: .discard))
        XCTAssertTrue(model.loadedSummary.isEmpty)
        for width in [560, 280] {
            try render(PresetBarView(model: model), width: CGFloat(width), height: 260,
                       name: "preset-empty-\(width).png", directory: directory)
        }
    }
    func testMixed90FlagsRenderOnOffWideNarrowAndToggleLeavesDocumentUnchanged() throws {
        let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph)
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<90).map {
            try .build(value: UInt16(120 + 25 * sin(Double($0) / 8)), fieldFlags: UInt8($0 % 8))
        })
        let model = SpatialActiveCellDisplayModel(); model.update(profile: profile, activeCells: [:])
        XCTAssertEqual(model.frame.projectedMeasurements.count, 90)
        XCTAssertEqual(ScannerFlagPresentation(profile: model.latestProfile).counts.reduce(0, +), 90)
        let directory = TestImageDirectory.make(), owner = fixture.root.document
        let before = owner.document
        let suite = "BundleFlagsUI-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = WorkspaceControlModel(defaults: defaults)
        XCTAssertFalse(workspace.preferences.scannerFlagBits)
        for flags in [true, false] {
            workspace.setScannerFlagBits(flags)
            XCTAssertEqual(WorkspaceControlModel(defaults: defaults).preferences.scannerFlagBits, flags)
            XCTAssertEqual(owner.document, before)
            for width in [1000, 420] {
                let view = CartesianScanFieldView(editor: owner.canvas,
                    profile: profile, activeCellDisplay: model, spatialInstrument: owner,
                    simulationBadge: AnyView(Text("Offline 90")),
                    scannerFlagBits: Binding(get: { workspace.preferences.scannerFlagBits }, set: { workspace.setScannerFlagBits($0) }))
                try render(view, width: CGFloat(width), height: 950, name: "scanner-flags-\(flags ? "on" : "off")-\(width).png", directory: directory)
            }
        }
        XCTAssertEqual(graph.starts, 0)
        XCTAssertFalse(String(decoding: try PresetV5Codec.encode(.init(name: "No flags", document: before)), as: UTF8.self).contains("scannerFlag"))
    }
    private func render<Content: View>(_ view: Content, width: CGFloat, height: CGFloat, name: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark)
            .padding(10).background(Color(red: 0.115, green: 0.118, blue: 0.130)))
        host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}
