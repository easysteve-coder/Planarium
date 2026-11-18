@testable import LegacyPresetTestSupport
import PlanariumDomain
import Foundation
import XCTest
import SickPLSControlCore
import SickPLSMonitorKit
@testable import PlanariumPresets

final class LegacyPresetDocumentReaderTests: XCTestCase {
    func testI1PolarV3UsesEveryPhysicalAddressAndPreservesAction() throws {
        let reading = try read(FrozenPresetFixtures.polarVersion3)
        XCTAssertEqual(reading.source, .imported(fromVersion: 3))
        XCTAssertEqual(reading.findings, [])
        let document = try XCTUnwrap(reading.record.spatialDocument)
        XCTAssertEqual(document.layers.map(\.name), ["Noten"])
        XCTAssertEqual(document.selectedLayerID, document.layers[0].id)
        XCTAssertEqual(document.layers[0].cells.count, 2_250)
        let firstAddress = try XCTUnwrap(PolarDeviceLattice(ring: 100, sector: 180))
        let secondAddress = try XCTUnwrap(PolarDeviceLattice(ring: 149, sector: 224))
        XCTAssertTrue(document.layers[0].cells.contains(firstAddress)
                      && document.layers[0].cells.contains(secondAddress))
        for address in [
            PolarDeviceLattice(ring: 100, sector: 180),
            PolarDeviceLattice(ring: 149, sector: 224)
        ].compactMap({ $0 }) {
            XCTAssertEqual(document.layers[0].cellOverrides[address], [
                SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 60, velocity: 100))
            ])
        }
        XCTAssertFalse(document.layers[0].cells.contains(try XCTUnwrap(PolarDeviceLattice(ring: 120, sector: 179))))
        XCTAssertFalse(document.layers[0].cells.contains(try XCTUnwrap(PolarDeviceLattice(ring: 120, sector: 225))))
        XCTAssertFalse(document.layers[0].cells.contains(try XCTUnwrap(PolarDeviceLattice(ring: 99, sector: 200))))
        XCTAssertFalse(document.layers[0].cells.contains(try XCTUnwrap(PolarDeviceLattice(ring: 150, sector: 200))))
    }

    func testI2CartesianV3ImportsAllAddressesAndActions() throws {
        let reading = try read(FrozenPresetFixtures.cartesianVersion3)
        let document = try XCTUnwrap(reading.record.spatialDocument)
        XCTAssertEqual(document.layers.count, 1)
        XCTAssertEqual(document.layers[0].cells.count, 2_250)
        XCTAssertEqual(document.layers[0].cellOverrides.count, 2_250)
        XCTAssertTrue(document.layers[0].cellOverrides.values.allSatisfy {
            $0 == [SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 60, velocity: 100))]
        })
    }

    func testI3FindingsAreExactlyTheTwoImporterFindings() throws {
        for fixture in [FrozenPresetFixtures.polarVersion3, FrozenPresetFixtures.cartesianVersion3] {
            let data = Data(fixture.utf8)
            let reading = try read(data)
            let compatibility = try CompatibilityImporter.read(data).get()
            let imported = try SpatialDocumentImporter.document(from: compatibility).get()
            XCTAssertEqual(reading.findings, imported.findings)
        }

        var root = try rootObject(FrozenPresetFixtures.polarVersion3)
        var workspace = try XCTUnwrap(root["spatialWorkspace"] as? [String: Any])
        var layers = try XCTUnwrap(workspace["layers"] as? [[String: Any]])
        var layer = layers[0]
        var polarCells = try XCTUnwrap(layer["polarCells"] as? [[String: Any]])
        polarCells.append(["ring": PolarDeviceLattice.maxRing, "angularIndex": 1])
        layer["polarCells"] = polarCells
        layers[0] = layer
        workspace["layers"] = layers
        root["spatialWorkspace"] = workspace
        let lossyData = try JSONSerialization.data(withJSONObject: root)
        let lossyReading = try XCTUnwrap(LegacyPresetDocumentReader.read(lossyData).successValue)
        let lossyCompatibility = try CompatibilityImporter.read(lossyData).get()
        let lossyImported = try SpatialDocumentImporter.document(from: lossyCompatibility).get()
        XCTAssertFalse(lossyReading.findings.isEmpty)
        XCTAssertEqual(lossyReading.findings, lossyImported.findings)
        XCTAssertTrue(lossyReading.findings.contains {
            if case .fullyLost = $0 { return true }
            return false
        })
    }

    func testI4LegacySettingsMatchIndependentFrozenStacksAndPresetCodec() throws {
        let expectedRoles = ["pitch", "volume", "filter", "effectSend", "gate"]
        let expectedTargets = ["discrete", "continuous", "discrete", "continuous", "gate"]
        let expectedZones = [
            [UUID(uuidString: "11111111-1111-1111-1111-111111111111")!],
            [UUID(uuidString: "22222222-2222-2222-2222-222222222222")!],
            [UUID(uuidString: "33333333-3333-3333-3333-333333333333")!],
            [],
            [UUID(uuidString: "44444444-4444-4444-4444-444444444444")!]
        ]
        let fixtures: [(String, [String], [String], [[UUID]])] = [
            (FrozenPresetFixtures.historicalVersion1, expectedRoles, expectedTargets, expectedZones),
            (FrozenPresetFixtures.historicalVersion2, expectedRoles, expectedTargets, expectedZones),
            (FrozenPresetFixtures.polarVersion3,
             ["pitch", "volume", "filter", "gate", "effectSend"],
             ["discrete", "continuous", "continuous", "gate", "continuous"],
             [[UUID(uuidString: "D17C138E-7C87-40C7-BFAF-51CAEE911BC8")!], [], [],
              [UUID(uuidString: "98465FC8-882E-4D0C-9BBA-CBC2C9AA9626")!], []])
        ]
        for (fixture, roles, targets, zones) in fixtures {
            let data = Data(fixture.utf8)
            let reading = try read(data)
            let old = try PresetCodec.decode(data)
            XCTAssertEqual(reading.record.name, old.name)
            XCTAssertEqual(reading.record.zones, old.zones)
            XCTAssertEqual(reading.record.assignment, old.assignment)
            XCTAssertEqual(reading.record.gate, old.gate)
            XCTAssertEqual(reading.record.mapping, old.mapping)
            XCTAssertEqual(reading.record.timbre, old.timbre)
            XCTAssertEqual(reading.record.masterGain, old.masterGain)
            XCTAssertEqual(reading.record.delay, old.delay)
            XCTAssertEqual(reading.record.reverb, old.reverb)
            XCTAssertEqual(reading.record.prediction, old.prediction)
            XCTAssertEqual(reading.record.audioUnits, old.audioUnits)
            XCTAssertEqual(reading.record.midi, old.midi)
            XCTAssertEqual(reading.record.viewport, old.viewport)
            XCTAssertEqual(reading.record.layers.map { $0.role }, roles)
            XCTAssertEqual(reading.record.layers.map { $0.targetKind }, targets)
            XCTAssertEqual(reading.record.layers.map { $0.zoneIDs }, zones)
            XCTAssertEqual(reading.record.layers.map { $0.mixRule }, Array(repeating: "firstActive", count: 5))
        }
    }

    func testI5ImportedRecordResavesOnlyAsV4AndReadsCurrent() throws {
        let imported = try read(FrozenPresetFixtures.polarVersion3)
        let data = try PresetDocumentCodec.encode(imported.record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 4)
        XCTAssertNil(object["spatialWorkspace"])
        XCTAssertNotNil(object["spatialDocument"])
        let current = try read(data)
        XCTAssertEqual(current.source, .current)
        XCTAssertEqual(current.findings, [])
        XCTAssertEqual(current.record, imported.record)
    }

    func testI6PaintedOutsideOverrideIsNamedSpatialImportRejection() throws {
        var root = try rootObject(FrozenPresetFixtures.polarVersion3)
        var workspace = try XCTUnwrap(root["spatialWorkspace"] as? [String: Any])
        var layers = try XCTUnwrap(workspace["layers"] as? [[String: Any]])
        var layer = layers[0]
        var polarCells = try XCTUnwrap(layer["polarCells"] as? [[String: Any]])
        polarCells.append(["ring": PolarDeviceLattice.maxRing, "angularIndex": 0])
        layer["polarCells"] = polarCells
        var overrides = try XCTUnwrap(layer["polarCellOverrides"] as? [Any])
        overrides.append(["ring": PolarDeviceLattice.maxRing, "angularIndex": 0])
        overrides.append([[
            "target": ["midiNote": ["channel": 0]],
            "value": ["note": ["number": 60, "velocity": 100]]
        ]])
        layer["polarCellOverrides"] = overrides
        layers[0] = layer
        workspace["layers"] = layers
        root["spatialWorkspace"] = workspace
        let result = LegacyPresetDocumentReader.read(try JSONSerialization.data(withJSONObject: root))
        guard case .failure(.spatialImport(.unplaceableOverrides)) = result else {
            return XCTFail("Erwartet spatialImport(.unplaceableOverrides), erhalten \(result)")
        }
    }

    func testI7WorkspaceShapeFailurePrecedesTypedSettingsDecode() throws {
        var root = try rootObject(FrozenPresetFixtures.polarVersion3)
        root["spatialWorkspace"] = ["layers": 5]
        let result = LegacyPresetDocumentReader.read(try JSONSerialization.data(withJSONObject: root))
        guard case .failure(.compatibility(.malformedSpatialWorkspace)) = result else {
            return XCTFail("Erwartet malformedSpatialWorkspace, erhalten \(result)")
        }
    }

    func testB1LegacyLayerBoundaryAndReaderByteBoundary() throws {
        let fixture = try rootObject(FrozenPresetFixtures.polarVersion3)
        var workspace = try XCTUnwrap(fixture["spatialWorkspace"] as? [String: Any])
        let original = try XCTUnwrap(workspace["layers"] as? [[String: Any]]).first!
        let layers = (0..<256).map { index -> [String: Any] in
            var layer = original
            layer["id"] = UUID().uuidString
            layer["name"] = "L\(index)"
            layer["polarCells"] = []
            layer["polarCellOverrides"] = []
            return layer
        }
        workspace["layers"] = layers
        workspace["selectedLayerID"] = layers[0]["id"]
        var exactRoot = fixture
        exactRoot["spatialWorkspace"] = workspace
        let exactData = try JSONSerialization.data(withJSONObject: exactRoot)
        XCTAssertNotNil(LegacyPresetDocumentReader.read(exactData).successValue)

        var overRoot = exactRoot
        var overWorkspace = workspace
        var overLayers = layers
        var extra = original
        extra["id"] = UUID().uuidString
        extra["name"] = "L256"
        extra["polarCells"] = []
        extra["polarCellOverrides"] = []
        overLayers.append(extra)
        overWorkspace["layers"] = overLayers
        overRoot["spatialWorkspace"] = overWorkspace
        let overResult = LegacyPresetDocumentReader.read(try JSONSerialization.data(withJSONObject: overRoot))
        XCTAssertEqual(overResult.failureValue, .budgetExceeded(.layers))

        XCTAssertEqual(LegacyPresetDocumentReader.read(exactData, inputByteLimit: exactData.count - 1).failureValue,
                       .budgetExceeded(.inputBytes))
    }

    func testV1AndV2WorkspacePresenceAndAbsenceUseTheSameImportPath() throws {
        for fixture in [FrozenPresetFixtures.historicalVersion1, FrozenPresetFixtures.historicalVersion2] {
            let result = LegacyPresetDocumentReader.read(Data(fixture.utf8))
            let reading = try XCTUnwrap(result.successValue)
            let root = try rootObject(fixture)
            let version = try XCTUnwrap(root["formatVersion"] as? Int)
            XCTAssertEqual(reading.source, .imported(fromVersion: version))
            XCTAssertNil(reading.record.spatialDocument)
            XCTAssertEqual(reading.findings, [.noSpatialInventory])
        }

        for version in [1, 2] {
            var valid = try rootObject(FrozenPresetFixtures.polarVersion3)
            valid["formatVersion"] = version
            let validReading = try XCTUnwrap(LegacyPresetDocumentReader.read(
                JSONSerialization.data(withJSONObject: valid)
            ).successValue)
            XCTAssertEqual(validReading.source, .imported(fromVersion: version))
            XCTAssertNotNil(validReading.record.spatialDocument)

            var malformed = valid
            malformed["spatialWorkspace"] = ["layers": 5]
            let malformedResult = LegacyPresetDocumentReader.read(
                try JSONSerialization.data(withJSONObject: malformed)
            )
            guard case .failure(.compatibility(.malformedSpatialWorkspace)) = malformedResult else {
                return XCTFail("v\(version): erwartete Workspace-Ablehnung, erhalten \(malformedResult)")
            }
        }
    }

    func testReaderVersionGateRejectsBoolFractionAndOutOfIntValues() throws {
        for value in ["true", "false", "null", "4.5", "1e30", "-1e30"] {
            var root = try rootObject(FrozenPresetV4Fixtures.record)
            root["formatVersion"] = try JSONSerialization.jsonObject(
                with: Data(value.utf8), options: [.fragmentsAllowed]
            )
            let result = LegacyPresetDocumentReader.read(try JSONSerialization.data(withJSONObject: root))
            XCTAssertEqual(result.failureValue, .malformedFormatVersion, value)
        }
    }

    func testS1ReaderIsAdditiveAndUsesBothImportBoundaries() throws {
        let reader = try String(contentsOfFile: "Sources/PlanariumPresets/PresetDocumentReader.swift")
        XCTAssertTrue(reader.contains("CompatibilityImporter.read"))
        XCTAssertTrue(reader.contains("SpatialDocumentImporter.document"))
        XCTAssertFalse(reader.contains("PresetCodec.decode"))
        let model = try String(contentsOfFile: "Sources/PlanariumPresets/PresetControlModel.swift")
        XCTAssertTrue(model.contains("PresetDocumentReader.read"))
    }

    func testF1V3BoundaryUsesOriginalBytesBeforeLegacyImport() throws {
        let data = Data(FrozenPresetFixtures.polarVersion3.utf8)
        XCTAssertEqual(
            LegacyPresetDocumentReader.read(data, inputByteLimit: data.count - 1).failureValue,
            .budgetExceeded(.inputBytes)
        )
        let source = try String(contentsOfFile: "Sources/PlanariumPresets/PresetDocumentReader.swift")
        XCTAssertTrue(source.contains("if version == Self.legacyNormalizationTarget"))
        XCTAssertTrue(source.contains("data,\n                root: root"))
    }

    func testF2LegacyNormalizationTargetIsFixedAtThree() throws {
        let source = try String(contentsOfFile: "Sources/PlanariumPresets/PresetDocumentReader.swift")
        XCTAssertTrue(source.contains("legacyNormalizationTarget = 3"))
        XCTAssertFalse(source.contains("InstrumentPreset.currentFormatVersion"))
    }

    func testF3MigrationFailureNamesTheBrokenSourceStep() throws {
        let migrations = PresetMigrations(
            steps: [1: { object in object }],
            earliestSupportedVersion: 1
        )
        let result = LegacyPresetDocumentReader.read(
            Data(FrozenPresetFixtures.historicalVersion1.utf8),
            inputByteLimit: SpatialDocumentBudget.production.inputBytes,
            migrations: migrations
        )
        XCTAssertEqual(result.failureValue, .migrationFailed(fromVersion: 1))
    }

    private func read(_ fixture: String) throws -> LegacyPresetDocumentReading {
        try XCTUnwrap(LegacyPresetDocumentReader.read(Data(fixture.utf8)).successValue)
    }

    private func read(_ data: Data) throws -> LegacyPresetDocumentReading {
        try XCTUnwrap(LegacyPresetDocumentReader.read(data).successValue)
    }

    private func rootObject(_ fixture: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    var failureValue: Failure? {
        guard case .failure(let value) = self else { return nil }
        return value
    }
}
