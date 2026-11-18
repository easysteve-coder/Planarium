@testable import LegacyPresetTestSupport
import PlanariumDomain
import XCTest
import Foundation
@testable import PlanariumPresets

/// SICK-037a: versioniertes Format, Migration in Versionsreihenfolge,
/// jede Ablehnung benannt.
final class PresetCodecTests: XCTestCase {

    static func samplePreset(name: String = "Probe") -> InstrumentPreset {
        let pitch = UUID(), gate = UUID()
        return InstrumentPreset(
            name: name,
            zones: [
                .init(id: pitch, indexLowerBound: 0, indexUpperBound: 0.5, valueLowerBound: 100, valueUpperBound: 4000, role: "pitch", isEnabled: true,
                      shape: .init(kind: "grid", columns: 2, rows: 2, values: [0, 1, 2, 3], range: 4)),
                .init(id: gate, indexLowerBound: 0.5, indexUpperBound: 1, valueLowerBound: 100, valueUpperBound: 4000, role: "gate", isEnabled: true, shape: .strip)
            ],
            assignment: .init(pitch: pitch, gate: gate),
            layers: [
                .init(role: "pitch", targetKind: "discrete", zoneIDs: [pitch], mixRule: "firstActive"),
                .init(role: "volume", targetKind: "continuous", zoneIDs: [], mixRule: "firstActive"),
                .init(role: "filter", targetKind: "continuous", zoneIDs: [], mixRule: "firstActive"),
                .init(role: "gate", targetKind: "gate", zoneIDs: [gate], mixRule: "firstActive"),
                .init(role: "effectSend", targetKind: "continuous", zoneIDs: [], mixRule: "firstActive")
            ],
            gate: .init(threshold: 0.5, polarity: "aboveThreshold"),
            mapping: .init(pitchLowestHz: 110, pitchHighestHz: 880, pitchPolarity: "normal", filterLowestHz: 200, filterHighestHz: 8000, filterPolarity: "normal",
                           maximumAmplitude: 0.8, volumeCurve: "linear", volumePolarity: "normal", effectSendPolarity: "normal"),
            timbre: .init(morph: 0.5, filterResonance: 1.5, attackSeconds: 0.01, decaySeconds: 0.1, sustainLevel: 0.8, releaseSeconds: 0.2),
            masterGain: 0.7,
            delay: .init(isEnabled: true, sendLevel: 0.3, timeSeconds: 0.25, feedbackPercent: 30),
            reverb: .init(isEnabled: false, sendLevel: 0.2, character: "smallRoom"),
            prediction: .init(alpha: 0.5, beta: 0.1, predictionHorizonSeconds: 0.05, staleTimeoutSeconds: 0.5, outlierThreshold: 0.3),
            audioUnits: .init(entries: [.init(componentType: 0x61756678, componentSubType: 1, componentManufacturer: 2, isBypassed: true)]),
            midi: .init(channel: 3, bendRangeSemitones: 12, rootNote: 33, spanSemitones: 60, pitchInverted: false, volumeController: 7, filterController: 74, effectSendController: 91),
            viewport: .init(centerX: 0.1, centerY: 0.2, halfExtent: 0.4)
        )
    }

    func testRoundTripIsLossless() throws {
        let preset = Self.samplePreset()
        let data = try PresetCodec.encode(preset)
        XCTAssertEqual(try PresetCodec.decode(data), preset)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"formatVersion\" : 3"))
    }

    func testVersionOneAssignmentsMigrateToTypedSingleLayers() throws {
        let current = try PresetCodec.encode(Self.samplePreset())
        var json = try JSONSerialization.jsonObject(with: current) as! [String: Any]
        json["formatVersion"] = 1
        json.removeValue(forKey: "layers")
        let migrated = try PresetCodec.decode(try JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(migrated.formatVersion, 3)
        XCTAssertEqual(migrated.layers.first { $0.role == "pitch" }?.targetKind, "discrete")
        XCTAssertEqual(migrated.layers.first { $0.role == "pitch" }?.zoneIDs, [migrated.assignment.pitch!])
        XCTAssertEqual(migrated.layers.first { $0.role == "gate" }?.targetKind, "gate")
    }

    func testNonObjectAndMissingVersionAreNamed() {
        XCTAssertThrowsError(try PresetCodec.decode(Data("[1,2]".utf8))) { XCTAssertEqual($0 as? PresetFormatError, .notAJSONObject) }
        XCTAssertThrowsError(try PresetCodec.decode(Data("{\"name\":\"x\"}".utf8))) { XCTAssertEqual($0 as? PresetFormatError, .missingFormatVersion) }
    }

    func testNewerAndOlderVersionsAreRejected() {
        XCTAssertThrowsError(try PresetCodec.decode(Data("{\"formatVersion\":4}".utf8))) { XCTAssertEqual($0 as? PresetFormatError, .newerThanSupported(4)) }
        XCTAssertThrowsError(try PresetCodec.decode(Data("{\"formatVersion\":0}".utf8))) { XCTAssertEqual($0 as? PresetFormatError, .unsupportedVersion(0)) }
    }

    /// Das Gerüst mit einer synthetischen Stufe 0 → 1 (Umbenennung
    /// `title` → `name`): Die Stufe läuft, das Ergebnis decodiert.
    func testASyntheticMigrationStepRunsInOrder() throws {
        var json = try JSONSerialization.jsonObject(with: try PresetCodec.encode(Self.samplePreset(name: "Alt"))) as! [String: Any]
        json["formatVersion"] = 0
        json["title"] = json.removeValue(forKey: "name")
        let legacy = try JSONSerialization.data(withJSONObject: json)

        let migrations = PresetMigrations(steps: [0: { object in
            var next = object
            next["name"] = next.removeValue(forKey: "title")
            next["formatVersion"] = 1
            return next
        }, 1: PresetMigrations.production.steps[1]!, 2: PresetMigrations.production.steps[2]!], earliestSupportedVersion: 0)

        XCTAssertEqual(try PresetCodec.decode(legacy, migrations: migrations).name, "Alt")
        // Dieselbe Datei ohne Stufe: benannt abgelehnt, nicht geraten.
        XCTAssertThrowsError(try PresetCodec.decode(legacy)) { XCTAssertEqual($0 as? PresetFormatError, .unsupportedVersion(0)) }
    }

    /// Eine Stufe, die die Version nicht anhebt, wird als Fehler
    /// erkannt -- kein stilles Endlos- oder Fehlformat.
    func testAMigrationStepThatDoesNotBumpTheVersionIsRejected() throws {
        var json = try JSONSerialization.jsonObject(with: try PresetCodec.encode(Self.samplePreset())) as! [String: Any]
        json["formatVersion"] = 0
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let broken = PresetMigrations(steps: [0: { $0 }], earliestSupportedVersion: 0)
        XCTAssertThrowsError(try PresetCodec.decode(legacy, migrations: broken)) {
            XCTAssertEqual($0 as? PresetFormatError, .migrationProducedInvalidObject(fromVersion: 0))
        }
    }

    func testAStructurallyWrongDocumentIsADecodingFailure() {
        XCTAssertThrowsError(try PresetCodec.decode(Data("{\"formatVersion\":1,\"name\":3}".utf8))) { error in
            guard case .decodingFailed? = error as? PresetFormatError else { return XCTFail("\(error)") }
        }
    }
}
