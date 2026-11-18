import Foundation
import XCTest
@testable import SickPLSMonitorKit

final class WorkspacePreferencesTests: XCTestCase {
    func testReceiveSourceRoundTripsAndLegacySendMigratesWithoutLosingTargets() throws {
        var value = WorkspacePreferences()
        value.collapsedLayerGroups = ["instrument-A": ["midi:default:0", "control"], "instrument-B": ["none"]]
        value.clockDirection = .receive; value.clockSourceID = 812; value.clockSourceName = "MainStage"
        value.clockTargetIDs = [1, 2]
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(value)), value)
        value.clockSourceID = nil; value.clockSourceName = nil
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(value)), value)
        let legacy = Data(#"{"setup":true,"layers":true,"cell":true,"channelStrip":true,"selectedTab":"layers","clockSendEnabled":true,"clockTargetIDs":[1,2]}"#.utf8)
        let restored = try JSONDecoder().decode(WorkspacePreferences.self, from: legacy)
        XCTAssertEqual(restored.clockDirection, .send); XCTAssertEqual(restored.clockTargetIDs, [1, 2])
        XCTAssertNil(restored.clockSourceID)
    }
    func testRoundTripAndMissingValuesUseIsolatedSuite() throws {
        let name = "Layout1-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(WorkspacePreferenceStore.load(from: defaults), .init())
        var value = WorkspacePreferences()
        value.setup = false; value.layers = false; value.channelStrip = false; value.selectedTab = "cell"
        value.clockSendEnabled = true; value.clockTargetIDs = [1, 2, 99]; value.fieldToolbarLabels = true
        WorkspacePreferenceStore.save(value, to: defaults)
        XCTAssertEqual(WorkspacePreferenceStore.load(from: defaults), value)
        XCTAssertEqual(WorkspacePreferenceStore.load(from: try XCTUnwrap(UserDefaults(suiteName: name))), value)
        let legacy = Data(#"{"setup":true,"layers":true,"cell":true,"channelStrip":true,"selectedTab":"layers"}"#.utf8)
        defaults.set(legacy, forKey: WorkspacePreferenceStore.key)
        XCTAssertEqual(WorkspacePreferenceStore.load(from: defaults), .init())
    }
    func testCorruptIncompleteWrongTypeAndUnknownTabFallBackToDefaults() throws {
        let name = "Layout1-corrupt-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for data in [Data("broken".utf8), Data("{}".utf8),
            Data(#"{"setup":1,"layers":true,"cell":true,"channelStrip":true,"selectedTab":"cell"}"#.utf8)] {
            defaults.set(data, forKey: WorkspacePreferenceStore.key)
            XCTAssertEqual(WorkspacePreferenceStore.load(from: defaults), .init())
        }
        defaults.set("wrong storage type", forKey: WorkspacePreferenceStore.key)
        XCTAssertEqual(WorkspacePreferenceStore.load(from: defaults), .init())
        var invalid = WorkspacePreferences(); invalid.selectedTab = "future"
        WorkspacePreferenceStore.save(invalid, to: defaults)
        XCTAssertEqual(WorkspacePreferenceStore.load(from: defaults), .init())
    }
}
