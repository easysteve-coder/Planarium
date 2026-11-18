@testable import LegacyPresetTestSupport
import XCTest
import Foundation
import SickPLSControlCore
import SickPLSMonitorKit
import PlanariumDomain
@testable import PlanariumPresets

/// SICK-037a/b: Format ↔ Domäne verlustfrei; jede ungültige Stelle
/// benannt; nichts wird angewandt, bevor alles aufgelöst ist.
final class PresetResolverTests: XCTestCase {
    func testRecordAndResolveAreInverse() throws {
        let preset = PresetCodecTests.samplePreset()
        let resolved = try PresetResolver.resolve(preset)
        XCTAssertEqual(PresetResolver.record(from: resolved).spatialWorkspace, preset.spatialWorkspace)
        XCTAssertEqual(try PresetResolver.resolve(PresetResolver.record(from: resolved)), resolved)
        XCTAssertEqual(resolved.bypassed.count, 1)
        guard case .grid(let cells) = resolved.zones[0].shape else { return XCTFail("Raster erwartet") }
        XCTAssertEqual(cells.columns, 2)
    }

    func testEveryShapeKindRoundTrips() throws {
        let key = try KeyCells.build(scale: .major, octaves: 2, rootOffset: 3, spanSemitones: 36)
        let fan = try FanCells.build(values: [0, 2, 4], range: 5)
        for shape in [FieldShape.strip, .key(key), .fan(fan)] {
            XCTAssertEqual(try PresetResolver.shape(from: PresetResolver.record(from: shape), index: 0), shape)
        }
    }

    func testUnknownRoleShapeAndEnumValuesAreNamed() {
        var preset = PresetCodecTests.samplePreset()
        preset.zones[0].role = "colour"
        XCTAssertThrowsError(try PresetResolver.resolve(preset)) { XCTAssertEqual($0 as? PresetResolutionError, .unknownRole("colour")) }

        preset = PresetCodecTests.samplePreset()
        preset.zones[0].shape.kind = "spiral"
        XCTAssertThrowsError(try PresetResolver.resolve(preset)) { XCTAssertEqual($0 as? PresetResolutionError, .unknownShapeKind("spiral")) }

        preset = PresetCodecTests.samplePreset()
        preset.reverb.character = "cathedral-of-doom"
        XCTAssertThrowsError(try PresetResolver.resolve(preset)) {
            XCTAssertEqual($0 as? PresetResolutionError, .unknownEnumValue(field: "reverb.character", value: "cathedral-of-doom"))
        }
    }

    /// Ein Gate ist stets ein Streifen -- auch wenn eine Datei etwas
    /// anderes behauptet.
    func testAGateWithANonStripShapeIsRejected() {
        var preset = PresetCodecTests.samplePreset()
        preset.zones[1].shape = .init(kind: "fan", values: [0, 1], range: 2)
        XCTAssertThrowsError(try PresetResolver.resolve(preset)) {
            guard case .invalidShape(index: 1, _)? = $0 as? PresetResolutionError else { return XCTFail("\($0)") }
        }
    }

    func testOutOfRangeSectionsAreNamedBySection() {
        var preset = PresetCodecTests.samplePreset()
        preset.midi.channel = 17
        XCTAssertThrowsError(try PresetResolver.resolve(preset)) {
            guard case .invalidMIDI? = $0 as? PresetResolutionError else { return XCTFail("\($0)") }
        }
        preset = PresetCodecTests.samplePreset()
        preset.viewport.halfExtent = -1
        XCTAssertThrowsError(try PresetResolver.resolve(preset)) {
            guard case .invalidViewport? = $0 as? PresetResolutionError else { return XCTFail("\($0)") }
        }
        preset = PresetCodecTests.samplePreset()
        preset.zones[0].indexUpperBound = -3
        XCTAssertThrowsError(try PresetResolver.resolve(preset)) {
            guard case .invalidZone(index: 0, _)? = $0 as? PresetResolutionError else { return XCTFail("\($0)") }
        }
    }
}
