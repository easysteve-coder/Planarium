import Foundation
import XCTest
import PlanariumDomain
@testable import PlanariumPresets

final class PresetSummaryTests: XCTestCase {
    func testAllFactoryDescriptionsAreVerbatimTableBWithSceneRenumbering() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Tests/PlanariumPresetsTests/Fixtures/harmonie-presets-teil2.md"), encoding: .utf8)
        let table = try XCTUnwrap(source.components(separatedBy: "## Tabelle B:").last?.components(separatedBy: "## Hinweise").first)
        var expected: [Int: String] = [:]
        for line in table.components(separatedBy: "\n") {
            let columns = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if columns.count >= 5, let number = Int(columns[1]) {
                expected[number >= 27 ? number + 1 : number] = columns[3]
            }
        }
        XCTAssertEqual(expected.count, 29)
        for name in FactoryPresetLibrary.standard.names {
            let number = Int(name.split(separator: " ")[1])
            let reading = try PresetDocumentReader.read(XCTUnwrap(FactoryPresetLibrary.standard.data(named: name))).get()
            XCTAssertEqual(reading.summary, name.hasPrefix("Factory") ? "" : expected[number ?? -1] ?? "", name)
        }
    }
    func testRoundTripKeepsVerbatimUnicodeSummaryAndMissingFieldMeansEmpty() throws {
        let summary = "A♭–B♭–C. Source: INVENTED-BUNDLE-MARKER, p. 1"
        let preset = InstrumentPresetV5(name: "Summary", document: try FactoryPresetDocument.empty(), summary: summary)
        let data = try PresetV5Codec.encode(preset)
        XCTAssertEqual(try PresetDocumentReader.read(data).get().summary, summary)
        XCTAssertEqual(try JSONDecoder().decode(InstrumentPresetV5.self, from: data), preset)
        var empty = preset; empty.summary = ""
        let bytes = try PresetV5Codec.encode(empty)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\"summary\""))
        XCTAssertEqual(try PresetDocumentReader.read(bytes).get().summary, "")
        for fixture in [FrozenPresetFixtures.polarVersion3, FrozenPresetV4Fixtures.record] {
            XCTAssertEqual(try PresetDocumentReader.read(Data(fixture.utf8)).get().summary, "")
        }
    }
    func testExactly1000CharactersAcceptedAnd1001RejectedOnAllWirePathsWithoutEcho() throws {
        var preset = InstrumentPresetV5(name: "Limit", document: try FactoryPresetDocument.empty(), summary: String(repeating: "👩‍🎤", count: 1000))
        let good = try PresetV5Codec.encode(preset)
        XCTAssertEqual(try PresetDocumentReader.read(good).get().summary.count, 1000)
        preset.summary += "x"
        XCTAssertThrowsError(try PresetV5Codec.encode(preset)) { XCTAssertEqual($0 as? PresetDocumentReadError, .summaryTooLong) }
        XCTAssertThrowsError(try JSONEncoder().encode(preset))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        root["summary"] = String(repeating: "INVENTED-BUNDLE-MARKER", count: 100)
        guard case .failure(let error) = PresetDocumentReader.read(try JSONSerialization.data(withJSONObject: root)) else { return XCTFail("accepted overlength") }
        XCTAssertEqual(error, .summaryTooLong)
        XCTAssertFalse(String(describing: error).contains("INVENTED-BUNDLE-MARKER"))
    }
    func testPresentationTooltipIsVerbatimSourceSeparateAndEmptyHidden() {
        let text = "Reach outward. Source: Example, p. 3–4"
        let value = PresetSummaryPresentation(text)
        XCTAssertEqual(value.tooltip, text)
        XCTAssertEqual(value.body, "Reach outward.")
        XCTAssertEqual(value.source, "Source: Example, p. 3–4")
        XCTAssertTrue(value.isVisible)
        XCTAssertFalse(PresetSummaryPresentation("").isVisible)
        XCTAssertEqual(PresetSummaryPresentation("No source").body, "No source")
    }
    func testFactoryV6WithoutSummaryIsCanonicalMigrationOfFrozenFactoryPlusApprovedDefaults() throws {
        let library = FactoryPresetLibrary.standard
        XCTAssertEqual(library.names.count, 32)
        for name in library.names {
            var preset = try JSONDecoder().decode(InstrumentPresetV6.self, from: XCTUnwrap(library.data(named: name)))
            preset.summary = ""
            let bytes = try PresetV6Codec.encode(preset)
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/TargetBoundary/Factory/\(name).sickpreset.json")
            var frozen = try Data(contentsOf: url)
            // Fixture text files have a final LF; canonical wire documents do not.
            if frozen.last == 10 { frozen.removeLast() }
            let reading = try PresetDocumentReader.read(frozen).get()
            // The V5 boundary fixture remains the immutable raw-ray oracle.
            // Factory V6 resources deliberately add the Owner-approved start
            // settings on top of that migration: adaptive, 2 cm, 45 %, and
            // 0.5 s Toggle protection, Edge 1, Core 3 cm and immediate
            // scene controls (dwell 0). Historical
            // fixtures stay fieldless.
            var expectedDocument = try reading.replacing(FactoryPresetDocument.empty())
            expectedDocument.editorGrid = MetricSquareGrid.CellSize.fiveCentimeter.grid
            expectedDocument.detection.virtualMMKMode = .adaptive
            expectedDocument.detection.virtualMMKTargetWidthCentimeters = 2
            expectedDocument.detection.virtualMMKSoftness = 45
            expectedDocument.detection.edgePoints = 1
            expectedDocument.detection.coreWidthCentimeters = 3
            expectedDocument.spatial = try .init(latticeVersion: expectedDocument.spatial.latticeVersion,
                layers: expectedDocument.spatial.layers.map { layer in
                    .init(id: layer.id, name: layer.name, color: layer.color, isVisible: layer.isVisible,
                          isActive: layer.isActive, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
                          cells: layer.cells, routings: layer.routings.map { routing in
                              var current = routing
                              if case .sceneSwitch(let action, _) = current.target {
                                  current.target = .sceneSwitch(action: action, dwellSeconds: 0)
                              }
                              return current
                          }, cellOverrides: layer.cellOverrides,
                          toggleGuardSeconds: SpatialInstrumentLayer.defaultToggleGuardSeconds)
                }, selectedLayerID: expectedDocument.spatial.selectedLayerID)
            let expected = InstrumentPresetV6(name: reading.name,
                document: expectedDocument, includesChannel: reading.includesChannel)
            XCTAssertEqual(bytes, try PresetV6Codec.encode(expected), name)
            let description = try PresetDocumentReader.read(XCTUnwrap(library.data(named: name))).get().summary
            if name.hasPrefix("Factory") || name == "Harmony 27 Harmony Codex" { XCTAssertEqual(description, "") }
            else { XCTAssertTrue(description.contains("Source: "), name) }
        }
    }
}

@MainActor final class PresetSummaryStateTests: XCTestCase {
    func testSaveImportLoadExportAndRejectedSavePreserveSummaryAndLoadedIdentity() throws {
        let h = PresetHarness(); defer { h.removeDirectory() }
        h.presets.draftName = "Described"; h.presets.draftSummary = "One. Source: Example"
        XCTAssertTrue(h.presets.save())
        XCTAssertNotNil(h.presets.load("Described"))
        XCTAssertEqual(h.presets.loadedSummary, "One. Source: Example")
        XCTAssertEqual(h.presets.menuSummaries["Described"], "One. Source: Example")
        h.presets.draftSummary = "Changed"
        XCTAssertTrue(h.presets.isDirty)
        XCTAssertNil(h.presets.load("Missing", decision: .discard))
        XCTAssertEqual(h.presets.loadedSummary, "One. Source: Example")
        XCTAssertEqual(h.presets.draftSummary, "Changed")
        h.presets.draftSummary = String(repeating: "x", count: 1001)
        XCTAssertFalse(h.presets.save())
        XCTAssertTrue(h.presets.notice?.contains("1000") == true)
        XCTAssertEqual(try PresetDocumentReader.read(h.store.load("Described")).get().summary, "One. Source: Example")
        h.presets.draftSummary = "One. Source: Example"
        let export = h.directory.appendingPathComponent("export.json")
        h.presets.export(to: export)
        XCTAssertEqual(try PresetDocumentReader.read(Data(contentsOf: export)).get().summary, "One. Source: Example")
        XCTAssertEqual(try PresetDocumentReader.read(Data(contentsOf: export)).get().replacing(FactoryPresetDocument.empty()), try h.root.document.snapshotPresetDocument())
        h.presets.importFiles([export])
        XCTAssertEqual(try PresetDocumentReader.read(h.store.load("export")).get().summary, "One. Source: Example")
        XCTAssertNotNil(h.presets.load("export", decision: .discard))
        XCTAssertEqual(h.presets.loadedSummary, "One. Source: Example")
    }
}
