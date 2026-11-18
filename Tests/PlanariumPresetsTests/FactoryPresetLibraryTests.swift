import XCTest
import PlanariumDomain
import SickPLSControlCore
@testable import PlanariumPresets

@MainActor final class FactoryPresetLibraryTests: XCTestCase {
    func testProgramChangeLayerTargetAndCellSelectionRoundTripWhileOldPresetsOmitThem() throws {
        XCTAssertEqual(try JSONDecoder().decode(SpatialProgramChange.self, from: Data("{}".utf8)), .init())
        for invalid in ["{\"program\":128}", "{\"bankMSB\":128}", "{\"bankLSB\":255}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(SpatialProgramChange.self, from: Data(invalid.utf8)))
        }
        let selection = SpatialProgramChange(program: 127, countsFromOne: false, bankMSB: 0, bankLSB: 127)
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!, id = UUID()
        let route = SpatialRouting(target: .midiProgramChange(channel: 15), program: .programChange(selection))
        let layer = SpatialDocumentLayer(id: id, name: "Generic effect", color: .blue, isVisible: true, isActive: true, isLocked: false,
            isSoloed: false, cells: [cell], routings: [route],
            cellOverrides: [cell: [.init(target: route.target, value: .programChange(.init(program: 3, bankLSB: 4)))]],
            midiTarget: .init(uniqueID: 12345))
        var document = try FactoryPresetDocument.empty()
        document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
        for includesChannel in [false, true] {
            let preset = InstrumentPresetV6(name: "Programs", document: document, includesChannel: includesChannel)
            let bytes = try PresetV6Codec.encode(preset)
            let decoded = try PresetV6Codec.decode(bytes)
            XCTAssertEqual(decoded.document.spatial, document.spatial)
            let replaced = try PresetDocumentReader.read(bytes).get().replacing(document)
            XCTAssertEqual(replaced.spatial, document.spatial)
            _ = try InstrumentCompiler.compile(replaced)
        }
        for name in FactoryPresetLibrary.standard.names {
            let preset = try PresetV6Codec.decode(XCTUnwrap(FactoryPresetLibrary.standard.data(named: name)))
            XCTAssertTrue(preset.document.spatial.layers.allSatisfy { $0.midiTarget == nil })
            let data = try PresetV6Codec.encode(preset)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("programChange"))
        }
    }
    func testEveryFactoryPresetUsesNewEdgeAndCoreDefaults() throws {
        for name in FactoryPresetLibrary.standard.names {
            let preset = try PresetV6Codec.decode(XCTUnwrap(FactoryPresetLibrary.standard.data(named: name)))
            XCTAssertEqual(preset.document.editorGrid.cellSizeMeters, 0.05, name)
            XCTAssertEqual(preset.document.detection.roomContour.toleranceCentimeters, 5, name)
            XCTAssertEqual(preset.document.detection.edgePoints, 1, name)
            XCTAssertEqual(preset.document.detection.coreWidthCentimeters, 3, name)
        }
    }
    func testTempoDefaultKeepsEveryFactoryPresetByteIdenticalAndCustomTempoRoundTrips() throws {
        let factory = FactoryPresetLibrary.standard
        for name in factory.names {
            let original = try XCTUnwrap(factory.data(named: name))
            let preset = try PresetV6Codec.decode(original)
            XCTAssertEqual(preset.document.beatsPerMinute, 120, name)
            let defaultEncoding = try PresetV6Codec.encode(preset)
            XCTAssertFalse(String(decoding: defaultEncoding, as: UTF8.self).contains("beatsPerMinute"))
            if let directory = ProcessInfo.processInfo.environment["TEMPO_BASELINE_PRESETS"] {
                XCTAssertEqual(defaultEncoding, try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name + ".json")), name)
            }
            var backToDefault = preset; backToDefault.document.beatsPerMinute = 144; backToDefault.document.beatsPerMinute = 120
            XCTAssertEqual(try PresetV6Codec.encode(backToDefault), defaultEncoding)
            for includesChannel in [true, false] {
                var changed = InstrumentPresetV6(name: name, document: preset.document, includesChannel: includesChannel)
                changed.document.beatsPerMinute = 137.5
                let saved = try PresetV6Codec.encode(changed)
                let loaded = try PresetDocumentReader.read(saved).get().replacing(preset.document)
                XCTAssertEqual(loaded.beatsPerMinute, 137.5, name)
                changed.document.beatsPerMinute = 120
                XCTAssertFalse(String(decoding: try PresetV6Codec.encode(changed), as: UTF8.self).contains("beatsPerMinute"))
                for bpm in [29.0, 301, .nan, .infinity] {
                    changed.document.beatsPerMinute = bpm
                    XCTAssertThrowsError(try PresetV6Codec.encode(changed))
                }
            }
        }
    }
    func testToggleGuardFactoryDefaultsAndBackwardCompatiblePresetRoundTrip() throws {
        XCTAssertEqual(SpatialInstrumentLayer(name: "New", color: .orange).toggleGuardSeconds, 0.5)
        var workspace = SpatialInstrumentWorkspace()
        workspace.addLayer(name: "New layer")
        XCTAssertEqual(workspace.selectedLayer.toggleGuardSeconds, 0.5)
        let factory = FactoryPresetLibrary.standard
        XCTAssertFalse(factory.names.isEmpty)
        let fresh = try FactoryPresetDocument.empty()
        let v5 = try PresetDocumentReader.read(PresetV5Codec.encode(.init(name: "Guard", document: fresh))).get().replacing(fresh)
        XCTAssertEqual(v5.spatial.layers[0].toggleGuardSeconds, 0.5, "V5 channel migration preserves an explicit guard")
        for name in factory.names {
            let preset = try PresetV6Codec.decode(XCTUnwrap(factory.data(named: name)))
            XCTAssertTrue(preset.document.spatial.layers.allSatisfy { $0.toggleGuardSeconds == 0.5 }, name)
            // Recreate a historical fieldless file through the public reader.
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetV6Codec.encode(preset)) as? [String: Any])
            var document = try XCTUnwrap(root["document"] as? [String: Any])
            var spatial = try XCTUnwrap(document["spatial"] as? [String: Any])
            var layers = try XCTUnwrap(spatial["layers"] as? [[String: Any]])
            for index in layers.indices { layers[index].removeValue(forKey: "toggleGuardSeconds") }
            spatial["layers"] = layers; document["spatial"] = spatial; root["document"] = document
            let legacy = try PresetDocumentReader.read(JSONSerialization.data(withJSONObject: root)).get().replacing(preset.document)
            XCTAssertTrue(legacy.spatial.layers.allSatisfy { $0.toggleGuardSeconds == 0 }, name)
            let roundTrip = try PresetV6Codec.decode(PresetV6Codec.encode(.init(name: name, document: legacy)))
            XCTAssertTrue(roundTrip.document.spatial.layers.allSatisfy { $0.toggleGuardSeconds == 0 }, "Saved legacy remains unguarded")
        }
    }
    func testDefaultModelListsAndLoadsFactoryPresetsWithoutStartingOutputs() throws {
        let harness = PresetHarness()
        defer { harness.removeDirectory() }
        let model = PresetControlModel(
            store: harness.store, documentOwner: harness.root.document,
            factoryPresets: try .init(presets: [try harness.presets.capture(name: "Fixture")])
        )

        XCTAssertEqual(model.names, ["Fixture"])
        XCTAssertNotNil(model.load("Fixture"))
        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertFalse(harness.root.audio.isRunning)
    }

    func testFactoryPresetCannotBeDeletedOrShadowedBySaving() throws {
        let harness = PresetHarness()
        defer { harness.removeDirectory() }
        let model = PresetControlModel(
            store: harness.store, documentOwner: harness.root.document,
            factoryPresets: try .init(presets: [try harness.presets.capture(name: "Fixture")])
        )
        let name = "Fixture"

        model.delete(name)
        XCTAssertTrue(model.notice?.contains("cannot be deleted") == true)
        model.draftName = name
        model.save()
        XCTAssertTrue(model.notice?.contains("read-only") == true)
        XCTAssertEqual(try! harness.store.list(), [])
    }
}
