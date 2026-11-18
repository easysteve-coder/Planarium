import Foundation
import XCTest
import PlanariumDomain
@testable import PlanariumPresets

@MainActor final class PresetExchangeTests: XCTestCase {
    func testExportThenImportKeepsCanonicalV6Bytes() throws {
        let source = PresetHarness()
        defer { source.removeDirectory() }
        source.presets.draftName = "Exchange"
        XCTAssertTrue(source.presets.save())
        let expected = try source.store.load("Exchange")
        let export = source.directory.appendingPathComponent("outside.sickpreset.json")
        source.presets.export(to: export)
        XCTAssertNotEqual(try Data(contentsOf: export), expected)
        XCTAssertEqual(try PresetDocumentReader.read(Data(contentsOf: export)).get().name, "outside")

        let destination = PresetHarness()
        defer { destination.removeDirectory() }
        destination.presets.importFiles([export])
        XCTAssertEqual(try destination.store.load("outside"), try Data(contentsOf: export))
        XCTAssertNil(destination.presets.lastLoadedName)
    }

    func testImportDisambiguatesNameAndAcceptsGoodNeighbourOfBadFile() throws {
        let h = PresetHarness()
        defer { h.removeDirectory() }
        h.presets.draftName = "Name"
        XCTAssertTrue(h.presets.save())
        let good = h.directory.appendingPathComponent("good.json")
        try PresetV6Codec.encode(.init(name: "Name", document: try h.root.document.snapshotPresetDocument())).write(to: good)
        let bad = h.directory.appendingPathComponent("bad.json")
        try Data("not a preset".utf8).write(to: bad)

        h.presets.importFiles([bad, good])

        XCTAssertEqual(try h.store.load("Name 2"), try PresetV6Codec.encode(.init(name: "Name 2", document: try h.root.document.snapshotPresetDocument())))
        XCTAssertTrue(h.presets.notice?.contains("Not imported: bad.json (preset validation)") == true)
        XCTAssertEqual(h.presets.lastLoadedName, nil)
    }

    func testLegacyImportIsCanonicalRegardlessOfLiveDocument() throws {
        let first = PresetHarness(), second = PresetHarness()
        defer { first.removeDirectory(); second.removeDirectory() }
        var legacy = first.legacyRecord(name: "Legacy")
        var workspace = first.root.document.canvas.workspace
        workspace.updateSelectedLayer { $0.name = "Legacy layer" }
        legacy.spatialWorkspace = workspace
        legacy.instrumentChannel = nil
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: source) }
        try PresetCodec.encode(legacy).write(to: source)

        second.root.document.canvas.renameSelectedLayer("Different live layer")
        var detection = second.root.document.document.detection
        detection.groupingEnabled.toggle()
        second.root.document.updateDetectionConfiguration(detection)
        first.presets.importFiles([source])
        second.presets.importFiles([source])

        XCTAssertEqual(try first.store.load("Legacy"), try second.store.load("Legacy"))
        let imported = try PresetDocumentReader.read(first.store.load("Legacy")).get()
        XCTAssertEqual(imported.sourceVersion, 6)
        XCTAssertFalse(imported.includesChannel)
    }
}
