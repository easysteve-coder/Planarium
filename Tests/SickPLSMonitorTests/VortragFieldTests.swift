import AppKit
import SwiftUI
import XCTest
import PlanariumDomain
import PlanariumPresets
import PlanariumApplication
@testable import SickPLSMonitor

@MainActor final class VortragFieldTests: XCTestCase {
    func testEverySceneFieldImage() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".agent_handoff/runs/vortrag-preset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let presetFile = root.appendingPathComponent("Tests/SickPLSMonitorTests/Fixtures/Harmony 30 Vortrag.sickpreset.json")
        let reading = try PresetDocumentReader.read(Data(contentsOf: presetFile)).get()
        let fixture = try MonitorRootFixture(usesProductionGrid: true)
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        try owner.applyPresetDocument(reading.replacing(owner.document), restoringPluginStates: false)
        if let viewport = reading.viewport { owner.applyPresetViewport(viewport) }
        for scene in owner.document.scenes {
            owner.selectScene(scene.id)
            let view = CartesianScanFieldView(editor: owner.canvas, profile: nil, activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner, simulationBadge: AnyView(EmptyView()))
            let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .dark).foregroundColor(.white).background(StageTheme.workspace)))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = .init(x: 0, y: 0, width: 1500, height: 950)
            host.wantsLayer = true; host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("field-\(scene.name).png"))
            host.rootView = AnyView(EmptyView())
        }
    }
}
