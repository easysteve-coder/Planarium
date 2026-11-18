@testable import LegacyPresetTestSupport
import PlanariumDomain
import Foundation
import XCTest
import SickPLSControlCore
import SickPLSMonitorKit
@testable import PlanariumPresets

final class PresetV4Tests: XCTestCase {
    func testR1HandWrittenFixtureCarriesAllRecordAndSpatialValues() throws {
        let preset = try PresetDocumentCodec.readCurrent(Data(FrozenPresetV4Fixtures.record.utf8))
        XCTAssertEqual(preset.name, "V4 / Hand fixture")
        XCTAssertEqual(preset.zones.count, 1)
        XCTAssertEqual(preset.layers.first?.targetKind, "discrete")
        XCTAssertEqual(preset.assignment.pitch?.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(preset.midi.channel, 3)
        XCTAssertEqual(preset.viewport.halfExtent, 0.4)
        let document = try XCTUnwrap(preset.spatialDocument)
        XCTAssertEqual(document.layers.map(\.name), ["First", "Second"])
        XCTAssertEqual(document.selectedLayerID, document.layers[1].id)
        XCTAssertEqual(document.layers[0].cells, [try XCTUnwrap(PolarDeviceLattice(ring: 100, sector: 180))])
        XCTAssertEqual(document.layers[0].routings.count, 1)
        XCTAssertEqual(document.layers[1].cellOverrides.count, 1)
        XCTAssertEqual(document.layers[1].cellOverrides.values.first?.count, 1)
    }

    func testR2BitStableRoundTripAndInsertionOrder() throws {
        let fixture = Data(FrozenPresetV4Fixtures.record.utf8)
        let decoded = try PresetDocumentCodec.readCurrent(fixture)
        XCTAssertEqual(try PresetDocumentCodec.encode(decoded), try PresetDocumentCodec.encode(decoded))

        let layerID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let first = try XCTUnwrap(PolarDeviceLattice(ring: 100, sector: 180))
        let second = try XCTUnwrap(PolarDeviceLattice(ring: 149, sector: 224))
        let action = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 60, velocity: 100))
        let layerA = SpatialDocumentLayer(id: layerID, name: "A", color: .orange,
                                          isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                                          cells: [first, second], routings: [],
                                          cellOverrides: [second: [action], first: [action]])
        let layerB = SpatialDocumentLayer(id: layerID, name: "A", color: .orange,
                                          isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                                          cells: [second, first], routings: [],
                                          cellOverrides: [first: [action], second: [action]])
        let docA = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layerA], selectedLayerID: layerID)
        let docB = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layerB], selectedLayerID: layerID)
        let base = PresetCodecTests.samplePreset()
        let a = InstrumentPresetV4(settingsOf: base, spatialDocument: docA)
        let b = InstrumentPresetV4(settingsOf: base, spatialDocument: docB)
        XCTAssertEqual(try PresetDocumentCodec.encode(a), try PresetDocumentCodec.encode(b))
    }

    func testR3WriterUsesOnlyV4SpatialFieldAndOmitsAbsentSpace() throws {
        let noSpace = InstrumentPresetV4(settingsOf: PresetCodecTests.samplePreset(), spatialDocument: nil)
        let noSpaceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetDocumentCodec.encode(noSpace)) as? [String: Any])
        XCTAssertNil(noSpaceObject["spatialDocument"])
        let withSpace = try PresetDocumentCodec.readCurrent(Data(FrozenPresetV4Fixtures.record.utf8))
        let text = String(decoding: try PresetDocumentCodec.encode(withSpace), as: UTF8.self)
        XCTAssertTrue(text.contains("\"formatVersion\" : 4"))
        for forbidden in ["spatialWorkspace", "grid", "coordinateMode", "polarCells", "angularIndex", "cellSizeMeters"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testR4VersionsAndRootShapeAreNamed() throws {
        XCTAssertEqual(try PresetDocumentCodec.readCurrent(Data(FrozenPresetV4Fixtures.record.utf8)).name, "V4 / Hand fixture")
        for (value, expected) in [("5", PresetDocumentReadError.newerThanSupported(5)),
                                   ("0", .unsupportedVersion(0)),
                                   ("\"4\"", .malformedFormatVersion),
                                   ("4.5", .malformedFormatVersion),
                                   ("1e30", .malformedFormatVersion),
                                   ("-1e30", .malformedFormatVersion),
                                   ("true", .malformedFormatVersion),
                                   ("false", .malformedFormatVersion),
                                   ("null", .malformedFormatVersion)] as [(String, PresetDocumentReadError)] {
            XCTAssertEqual(error(for: value), expected)
        }
        var missing = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(FrozenPresetV4Fixtures.record.utf8)) as? [String: Any])
        missing.removeValue(forKey: "formatVersion")
        XCTAssertEqual(error(for: missing), .missingFormatVersion)
        XCTAssertEqual(error(for: ["formatVersion": 4]), .decodingFailed("decodingFailed"))
        XCTAssertEqual(error(for: ["formatVersion": 4], asArray: true), .notAJSONObject)
    }

    func testA2SpatialDocumentNullAndWrongTypesAreNotAbsence() throws {
        for value in [NSNull(), "x", [1]] as [Any] {
            var root = try fixtureObject()
            root["spatialDocument"] = value
            XCTAssertEqual(error(for: root), .decodingFailed("decodingFailed"))
        }
    }

    func testR5LatticePriorityAndMarkerFreeUnknownError() throws {
        var root = try fixtureObject()
        var document = try XCTUnwrap(root["spatialDocument"] as? [String: Any])
        document["latticeVersion"] = "polarDeviceV1"
        root["spatialDocument"] = document
        XCTAssertEqual(error(for: root), .unsupportedLatticeVersion(.polarDeviceV1))
        document["latticeVersion"] = "MARKER-M2C-4711"
        root["spatialDocument"] = document
        let error = error(for: root)
        XCTAssertEqual(error, .unknownLatticeVersion)
        XCTAssertFalse(String(describing: error).contains("MARKER-M2C-4711"))
    }

    func testMangel5NestedRoutingMarkerIsRedacted() throws {
        var root = try fixtureObject()
        var document = try XCTUnwrap(root["spatialDocument"] as? [String: Any])
        var layers = try XCTUnwrap(document["layers"] as? [[String: Any]])
        var routings = try XCTUnwrap(layers[0]["routings"] as? [[String: Any]])
        var routing = routings[0]
        var program = try XCTUnwrap(routing["program"] as? [String: Any])
        var chord = try XCTUnwrap(program["chord"] as? [String: Any])
        chord["transition"] = ["MARKER-M2C-4711": [:]]
        program["chord"] = chord
        routing["program"] = program
        routings[0] = routing
        layers[0]["routings"] = routings
        document["layers"] = layers
        root["spatialDocument"] = document
        let error = error(for: root)
        XCTAssertEqual(error, .decodingFailed("decodingFailed"))
        XCTAssertFalse(String(describing: error).contains("MARKER-M2C-4711"))
    }

    func testR6LegacySpatialFieldIsRejectedIncludingNull() throws {
        var root = try fixtureObject()
        root["spatialWorkspace"] = NSNull()
        XCTAssertEqual(error(for: root), .legacySpatialField)
    }

    func testB1AndB2InputByteBoundaries() throws {
        let invalid = Data("not-json".utf8)
        XCTAssertEqual(error(for: invalid, limit: invalid.count), .notAJSONObject)
        XCTAssertEqual(error(for: invalid, limit: invalid.count - 1), .budgetExceeded(.inputBytes))
        let preset = InstrumentPresetV4(settingsOf: PresetCodecTests.samplePreset(), spatialDocument: nil)
        let data = try PresetDocumentCodec.encode(preset)
        XCTAssertNoThrow(try PresetDocumentCodec.encode(preset, inputByteLimit: data.count))
        XCTAssertThrowsError(try PresetDocumentCodec.encode(preset, inputByteLimit: data.count - 1)) { error in
            XCTAssertEqual(error as? PresetDocumentReadError, .budgetExceeded(.inputBytes))
        }
    }

    func testB3LayerBudgetWinsOverPoisoned257thLayer() throws {
        var root = try fixtureObject()
        var document = try XCTUnwrap(root["spatialDocument"] as? [String: Any])
        let layers = (0..<257).map { index -> [String: Any] in
            ["id": UUID().uuidString, "name": "L\(index)", "color": ["red": 1, "green": 0, "blue": 0, "alpha": 1],
             "isVisible": true, "isActive": true, "isLocked": false, "isSoloed": false,
             "cells": index == 256 ? [["ring": -1, "sector": 0]] : [], "routings": [], "cellOverrides": []]
        }
        document["layers"] = layers
        document["selectedLayerID"] = (layers[0]["id"] as! String)
        root["spatialDocument"] = document
        XCTAssertEqual(error(for: root), .budgetExceeded(.layers))
    }

    func testS1ProductionReadsThroughReaderAndWritesOnlyV6() throws {
        let model = try String(contentsOfFile: "Sources/PlanariumPresets/PresetControlModel.swift")
        XCTAssertTrue(model.contains("PresetDocumentWriter.encode"))
        XCTAssertFalse(model.contains("PresetV6Codec.encode"))
        XCTAssertFalse(model.contains("PresetCodec.encode"))
        XCTAssertTrue(model.contains("PresetDocumentReader.read"))
        XCTAssertFalse(model.contains("InstrumentPresetV4"))
        let monitorFiles = try FileManager.default.subpathsOfDirectory(atPath: "Sources/SickPLSMonitor")
        for file in monitorFiles where file.hasSuffix(".swift") {
            let text = try String(contentsOfFile: "Sources/SickPLSMonitor/\(file)")
            XCTAssertFalse(text.contains("InstrumentPresetV4"))
            XCTAssertFalse(text.contains("PresetDocumentCodec"))
            XCTAssertFalse(text.contains("LegacyPresetDocumentReader"))
        }
    }

    func testWriterRejectsValidV1Document() throws {
        let id = UUID()
        let layer = SpatialDocumentLayer(id: id, name: "v1", color: .orange, isVisible: true,
                                         isActive: true, isLocked: false, isSoloed: false,
                                         cells: [], routings: [], cellOverrides: [:])
        let v1 = try SpatialDocument(latticeVersion: .polarDeviceV1, layers: [layer], selectedLayerID: id)
        let preset = InstrumentPresetV4(settingsOf: PresetCodecTests.samplePreset(), spatialDocument: v1)
        XCTAssertThrowsError(try PresetDocumentCodec.encode(preset)) { error in
            XCTAssertEqual(error as? PresetDocumentReadError, .unsupportedLatticeVersion(.polarDeviceV1))
        }
    }

    private func fixtureObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(FrozenPresetV4Fixtures.record.utf8)) as? [String: Any])
    }

    private func error(for version: String) -> PresetDocumentReadError {
        var root = (try? fixtureObject()) ?? [:]
        root["formatVersion"] = try! JSONSerialization.jsonObject(with: Data(version.utf8), options: [.fragmentsAllowed])
        return error(for: root)
    }

    private func error(for root: [String: Any], asArray: Bool = false) -> PresetDocumentReadError {
        let value: Any = asArray ? [root] : root
        let data = try! JSONSerialization.data(withJSONObject: value)
        do { _ = try PresetDocumentCodec.readCurrent(data); return .decodingFailed("noError") }
        catch let error as PresetDocumentReadError { return error }
        catch { return .decodingFailed("unexpected") }
    }

    private func error(for data: Data, limit: Int) -> PresetDocumentReadError {
        do { _ = try PresetDocumentCodec.readCurrent(data, inputByteLimit: limit); return .decodingFailed("noError") }
        catch let error as PresetDocumentReadError { return error }
        catch { return .decodingFailed("unexpected") }
    }
}
