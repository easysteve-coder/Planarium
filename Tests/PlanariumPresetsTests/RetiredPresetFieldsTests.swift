@testable import LegacyPresetTestSupport
import PlanariumDomain
import Foundation
import XCTest
@testable import PlanariumPresets

@MainActor final class RetiredPresetFieldsTests: XCTestCase {
    func testLegacyMusicalFieldsRemainReadableAndInert() throws {
        let harness = PresetHarness()
        defer { harness.removeDirectory() }
        let expected = try harness.presets.capture(name: "Retired fixture")
        var record = harness.legacyRecord(name: expected.name)
        // Former musical fields are valid legacy records but no longer
        // validate a live mapping, assignment or synthesizer.
        record.assignment.pitch = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        record.gate.threshold = -99
        record.mapping.pitchLowestHz = -77
        record.timbre.morph = 42
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetCodec.encode(record)) as? [String: Any])
        json["thereminParameters"] = ["marker": "P1-INVENTED-RETIRED-FIELD", "frequencyHz": -1]
        json["synthVoice"] = ["unknownTimbre": "P1-INVENTED-RETIRED-FIELD"]
        json["futureUnknownField"] = [1, 2, 3]
        try harness.store.save(try JSONSerialization.data(withJSONObject: json), as: expected.name)
        harness.presets.refresh()

        let loaded = try XCTUnwrap(harness.presets.load(expected.name))
        XCTAssertEqual(loaded.name, expected.name)
        let after = try harness.presets.capture(name: expected.name)
        XCTAssertEqual(after.document.spatial, expected.document.spatial)
        XCTAssertEqual(after.document.channel, expected.document.channel)
        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertFalse(harness.root.midi.isRunning)
        XCTAssertEqual(harness.source.loads, 0)
    }
}
