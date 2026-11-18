import XCTest
import Foundation
import PlanariumApplication
import PlanariumDomain
import SickPLSControlCore
import SickPLSMonitorKit
@testable import PlanariumPresets

final class PresetV5Tests: XCTestCase {
    func testAbsentV5ChannelPreservesButPresentEmptyChannelReplacesTheLiveChannel() throws {
        let live = try v5Document()
        let template = InstrumentPresetV5(name: "Template", document: live, includesChannel: false)
        let bytes = try PresetV5Codec.encode(template)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil((object["document"] as? [String: Any])?["channel"])
        let reading = try PresetDocumentReader.read(bytes).get()
        XCTAssertFalse(reading.includesChannel)
        XCTAssertEqual(try reading.replacing(live).channel, live.channel)
        var empty = live; empty.channel = .init()
        let cleared = try PresetDocumentReader.read(PresetV5Codec.encode(.init(name: "Clear", document: empty))).get()
        XCTAssertTrue(cleared.includesChannel)
        XCTAssertEqual(try cleared.replacing(live).channel, .init())
    }
    /// Factory resources are the current golden documents. Unlike the frozen
    /// V3/V4/V5 migration oracles, they deliberately carry the approved MMK
    /// start setting and must continue to reencode byte-for-byte.
    func testEveryVersionedFactoryResourceReencodesWithApprovedVirtualMMKDefaults() throws {
        let library = FactoryPresetLibrary.standard
        // 32 frozen factory files plus the controller preset added on 18.11.2026.
        XCTAssertEqual(library.names.count, 33)
        for name in library.names {
            let versionedBytes = try XCTUnwrap(library.data(named: name))
            let reading = try PresetDocumentReader.read(versionedBytes).get()
            let document = try reading.replacing(FactoryPresetDocument.empty())
            XCTAssertEqual(document.detection.virtualMMKMode, .adaptive, name)
            XCTAssertEqual(document.detection.virtualMMKTargetWidthCentimeters, 2, name)
            XCTAssertEqual(document.detection.virtualMMKSoftness, 45, name)
            let encoded = try PresetV6Codec.encode(.init(name: reading.name, document: document, viewport: reading.viewport, includesChannel: reading.includesChannel, summary: reading.summary))
            var expected = try omittingLegacyRoomSetting(versionedBytes)
            if name == "Factory 01 MIDI Scale" {
                // This immutable factory alone stored an explicit virtual
                // destination on Ch 1. Promote exactly that field to Sum;
                // retain every other historical byte as the independent oracle.
                let text = String(decoding: expected, as: UTF8.self)
                    .replacingOccurrences(of: ",\"midiTarget\":{\"uniqueID\":0}", with: "")
                    .replacingOccurrences(of: "\"masterLevelDecibels\":0,", with: "\"masterLevelDecibels\":0,\"midiTarget\":{\"uniqueID\":0},")
                expected = Data(text.utf8)
                XCTAssertEqual(document.midiTarget, .init(uniqueID: 0))
                XCTAssertTrue(document.channels.allSatisfy { $0.midiTarget == nil })
            }
            XCTAssertEqual(encoded, expected, name)
        }
    }
    func testFieldlessFactoryDocumentUsesLegacyRawInsteadOfAdaptive() throws {
        let library = FactoryPresetLibrary.standard
        let name = try XCTUnwrap(library.names.first)
        let bytes = try XCTUnwrap(library.data(named: name))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var document = try XCTUnwrap(root["document"] as? [String: Any])
        var detection = try XCTUnwrap(document["detection"] as? [String: Any])
        detection.removeValue(forKey: "virtualMMKMode")
        detection.removeValue(forKey: "virtualMMKTargetWidthCentimeters")
        detection.removeValue(forKey: "virtualMMKSoftness")
        document["detection"] = detection
        root["document"] = document

        let fieldless = try PresetDocumentReader.read(JSONSerialization.data(withJSONObject: root)).get()
            .replacing(FactoryPresetDocument.empty())
        XCTAssertEqual(fieldless.detection.virtualMMKMode, .raw,
                       "Counterprobe: treating a fieldless document as adaptive must turn this test red")
        XCTAssertNotEqual(fieldless.detection.virtualMMKMode, .adaptive)
    }
    /// A frozen, independently stored oracle; this test never updates it.
    func testCodeBuiltWholeChannelMatchesGoldenV5Bytes() throws {
        let preset = InstrumentPresetV5(name: "Full channel", document: try v5Document(),
            viewport: .init(try .build(centerXMeters: 1.375, centerYMeters: -0.625, metersPerPoint: 0.003)))
        let fixture = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/v5-channel.golden.json")
        let frozen = try Data(contentsOf: fixture)
        XCTAssertEqual(try PresetV5Codec.encode(preset), try omittingLegacyRoomSetting(frozen))
        let decoded = try PresetDocumentReader.read(frozen).get()
        XCTAssertEqual(try decoded.replacing(FactoryPresetDocument.empty()).detection.roomContour, .init(), "Old runtime settings are read but ignored")
    }
    func testCompleteDocumentRoundTripIsExactIncludingMultipleRoutingsAndDormantEmptyOverrides() throws {
        let original = InstrumentPresetV5(name: "Full channel", document: try v5Document(),
            viewport: .init(try .build(centerXMeters: 1.375, centerYMeters: -0.625, metersPerPoint: 0.003)))
        let data = try PresetV5Codec.encode(original)
        let reading = try PresetDocumentReader.read(data).get()
        XCTAssertEqual(reading.sourceVersion, 5)
        XCTAssertEqual(try reading.replacing(FactoryPresetDocument.empty()), try LegacyChannelMigration.applying(to: original.document))
        XCTAssertEqual(reading.viewport, original.viewport)
        XCTAssertEqual(try JSONDecoder().decode(InstrumentPresetV5.self, from: data), original)
        XCTAssertEqual(try PresetV5Codec.encode(original), data)
        XCTAssertEqual(try PresetV5Codec.encode(JSONDecoder().decode(InstrumentPresetV5.self, from: data)), data)
    }
    func testInsertionOrderDoesNotChangeV5Bytes() throws {
        let a = try v5Document()
        var b = a
        let layer = a.spatial.layers[0]
        var overrides: [PolarDeviceLattice: [SpatialCellAction]] = [:]
        for (key, value) in layer.cellOverrides.sorted(by: { $0.key.sector > $1.key.sector }) { overrides[key] = value }
        let reversed = SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color, isVisible: layer.isVisible,
            isActive: layer.isActive, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
            cells: Set(layer.cells.reversed()), routings: layer.routings, cellOverrides: overrides, toggleGuardSeconds: layer.toggleGuardSeconds)
        b.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [reversed], selectedLayerID: layer.id)
        XCTAssertEqual(try PresetV5Codec.encode(.init(name: "Stable", document: a)), try PresetV5Codec.encode(.init(name: "Stable", document: b)))
    }
    func testV5HasOnlyChannelDocumentPresentationAndOpaqueStateFields() throws {
        let data = try PresetV5Codec.encode(.init(name: "Fields", document: v5Document()))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["formatVersion", "name", "document"])
        let document = try XCTUnwrap(root["document"] as? [String: Any])
        let channel = try XCTUnwrap(document["channel"] as? [String: Any])
        let instrument = try XCTUnwrap(channel["instrument"] as? [String: Any])
        XCTAssertEqual(instrument["state"] as? String, Data([9, 10]).base64EncodedString())
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["spatialWorkspace", "serialNumber", "deviceID", "deviceName", "username", "filePath", "distancesCentimeters"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }
    func testUnknownFieldsAreIgnoredAndMalformedDocumentIsRejectedWithoutEchoingMarker() throws {
        let data = try PresetV5Codec.encode(.init(name: "Future", document: v5Document()))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["futureField"] = ["INVENTED-P6-MARKER"]
        XCTAssertEqual(try PresetDocumentReader.read(JSONSerialization.data(withJSONObject: root)).get().replacing(FactoryPresetDocument.empty()), try LegacyChannelMigration.applying(to: v5Document()))
        root["document"] = ["INVENTED-P6-MARKER": "invalid"]
        guard case .failure(let error) = PresetDocumentReader.read(try JSONSerialization.data(withJSONObject: root)) else { return XCTFail("must reject") }
        XCTAssertFalse(String(describing: error).contains("INVENTED-P6-MARKER"))
    }
    func testPresentBrokenChannelIsNotAbsenceAndDuplicateInsertsAreRejected() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetV5Codec.encode(.init(name: "Broken", document: v5Document()))) as? [String: Any])
        var document = try XCTUnwrap(root["document"] as? [String: Any])
        for broken in [NSNull(), [], "bad"] as [Any] {
            document["channel"] = broken; root["document"] = document
            if case .success = PresetDocumentReader.read(try JSONSerialization.data(withJSONObject: root)) { XCTFail("broken channel accepted") }
        }
        var value = try v5Document(); value.channel.inserts.append(value.channel.inserts[0])
        XCTAssertThrowsError(try PresetV5Codec.encode(.init(name: "Duplicate", document: value)))
    }
    func testVersionGateAndByteBudget() throws {
        for version in ["true", "5.5", "null", "\"5\"", "1e30"] {
            XCTAssertEqual(PresetDocumentReader.read(Data("{\"formatVersion\":\(version)}".utf8)).failureValue, .malformedFormatVersion)
        }
        XCTAssertEqual(PresetDocumentReader.read(Data("{\"formatVersion\":8}".utf8)).failureValue, .newerThanSupported(8))
        XCTAssertEqual(PresetDocumentReader.read(Data(repeating: 32, count: SpatialDocumentBudget.production.inputBytes + 1)).failureValue, .budgetExceeded(.inputBytes))
    }
    func testEveryNeutralizedOwnerFixtureAndEveryFrozenLegacyVersionImports() throws {
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Owner")
        let fixtures = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(fixtures.count, 28)
        for url in fixtures {
            let reading = try PresetDocumentReader.read(Data(contentsOf: url)).get()
            XCTAssertEqual(reading.sourceVersion, 3)
            let value = try reading.replacing(FactoryPresetDocument.empty())
            XCTAssertFalse(value.spatial.layers.isEmpty)
            let resaved = try PresetV5Codec.encode(.init(name: reading.name, document: value))
            XCTAssertEqual(try PresetDocumentReader.read(resaved).get().replacing(FactoryPresetDocument.empty()), value)
        }
        for (version, fixture) in [(1, FrozenPresetFixtures.historicalVersion1), (2, FrozenPresetFixtures.historicalVersion2),
                                  (3, FrozenPresetFixtures.polarVersion3), (3, FrozenPresetFixtures.cartesianVersion3), (4, FrozenPresetV4Fixtures.record)] {
            let reading = try PresetDocumentReader.read(Data(fixture.utf8)).get()
            XCTAssertEqual(reading.sourceVersion, version)
            _ = try reading.replacing(FactoryPresetDocument.empty())
        }
    }
    func testEveryGeneratedFactoryAndHarmonyFileIsV5AndRoundTripsLosslessly() throws {
        let library = FactoryPresetLibrary.standard
        // 32 frozen factory files plus the controller preset added on 18.11.2026.
        XCTAssertEqual(library.names.count, 33)
        for name in library.names {
            let data = try XCTUnwrap(library.data(named: name))
            let reading = try PresetDocumentReader.read(data).get()
            XCTAssertEqual(reading.sourceVersion, 6, name)
            XCTAssertEqual(reading.name, name)
            let value = try reading.replacing(FactoryPresetDocument.empty())
            let saved = try PresetV6Codec.encode(.init(name: name, document: value))
            XCTAssertEqual(try PresetDocumentReader.read(saved).get().replacing(FactoryPresetDocument.empty()), value, name)
            if name.contains("Harmony") || name.contains("Harmonie") {
                XCTAssertGreaterThan(value.spatial.layers.reduce(0) { $0 + $1.cells.count }, 0, name)
            }
        }
    }

    func testScenesRoundTripAndOlderPresetWithoutScenesKeepsLayerActivity() throws {
        var document = try v5Document()
        let first = UUID(), second = UUID()
        let ids = document.spatial.layers.map(\.id)
        document.scenes = [.init(id: first, name: "Verse", activeLayerIDs: [ids[0]]),
                           .init(id: second, name: "Chorus", activeLayerIDs: Set(ids))]
        document.currentSceneID = second
        let data = try PresetV5Codec.encode(.init(name: "Scenes", document: document))
        XCTAssertEqual(try PresetDocumentReader.read(data).get().replacing(FactoryPresetDocument.empty()), try LegacyChannelMigration.applying(to: document))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var encodedDocument = try XCTUnwrap(object["document"] as? [String: Any])
        encodedDocument.removeValue(forKey: "scenes")
        encodedDocument.removeValue(forKey: "currentSceneID")
        object["document"] = encodedDocument
        let old = try PresetDocumentReader.read(JSONSerialization.data(withJSONObject: object)).get()
            .replacing(FactoryPresetDocument.empty())
        XCTAssertTrue(old.scenes.isEmpty)
        XCTAssertNil(old.currentSceneID)
        XCTAssertEqual(old.spatial.layers.map(\.isActive), document.spatial.layers.map(\.isActive))
    }
}
/// Preserve the immutable historical oracle; exactly one retired runtime-only
/// field is excluded from the new writer contract, nothing musical is masked.
func omittingLegacyRoomSetting(_ data: Data) throws -> Data {
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var document = try XCTUnwrap(root["document"] as? [String: Any])
    document.removeValue(forKey: "roomFilter"); root["document"] = document
    // Do not reserialize NSNumber: Foundation and JSONEncoder choose different
    // decimal spellings. Keep every other frozen byte unchanged.
    let text = String(decoding: data, as: UTF8.self)
    let stripped = Data(text.replacingOccurrences(of: ",\"roomFilter\":\\{[^}]*\\}", with: "", options: .regularExpression).utf8)
    let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: stripped) as? NSDictionary)
    XCTAssertTrue(actual.isEqual(to: root), "Exactly the retired field, not another value, may change")
    return stripped
}
private extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { return error }; return nil }
}
