import XCTest
@testable import SickPLSMonitorKit

/// SICK-039: Die Hilfe deckt jeden Bedienweg und nennt die festen
/// Grenzen; reine Textprüfung, ohne gerenderte Ansicht.
final class HelpTopicsTests: XCTestCase {

    func testEveryTopicHasUniqueIDTitleAndBody() {
        let ids = HelpTopics.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for topic in HelpTopics.all {
            XCTAssertFalse(topic.title.isEmpty, topic.id)
            XCTAssertGreaterThan(topic.body.count, 80, topic.id)
        }
    }

    func testTheHelpCoversEveryOperatingPathInPlayingOrder() {
        XCTAssertEqual(
            HelpTopics.all.map(\.id),
            ["verbinden", "device-fields", "workspace", "scenes", "zonen", "move-cells", "felder", "kanalzug", "audiounits", "midi", "presets", "toggle", "release-layer", "loesen", "grenzen"]
        )
    }

    /// Die Sätze, an denen die Sicherheitsgrenzen hängen, stehen wörtlich
    /// in der Hilfe.
    func testTheHelpStatesTheHardBoundaries() throws {
        let release = try XCTUnwrap(HelpTopics.topic(id: "loesen")).body
        XCTAssertTrue(release.contains("never come from prediction"))
        XCTAssertTrue(release.contains("it resumes after wake; new notes need a fresh profile"))
        XCTAssertTrue(release.contains("Unexpected input loss releases ordinary notes; held and toggled notes keep playing"))
        XCTAssertTrue(release.contains("deliberate disconnect, input change, sleep and termination release everything"))
        let limits = try XCTUnwrap(HelpTopics.topic(id: "grenzen")).body
        XCTAssertTrue(limits.contains("makes no claim about a safety function or certification"))
        XCTAssertTrue(limits.contains("musical inputs"))
        XCTAssertTrue(limits.contains("explicit support action"))
        let midi = try XCTUnwrap(HelpTopics.topic(id: "midi")).body
        XCTAssertTrue(midi.contains("Panic"))
        XCTAssertNil(HelpTopics.topic(id: "gibt-es-nicht"))
    }

    func testHelpExplainsPresetExchangeAndLayerSceneRules() throws {
        let presets = try XCTUnwrap(HelpTopics.topic(id: "presets")).body
        let layers = try XCTUnwrap(HelpTopics.topic(id: "zonen")).body
        XCTAssertTrue(presets.contains("Import Preset…"))
        XCTAssertTrue(presets.contains("Export Preset…"))
        XCTAssertTrue(layers.contains("⌘D"))
        XCTAssertTrue(layers.contains("⌘C/⌘V"))
        XCTAssertTrue(layers.contains("active scene"))
        XCTAssertTrue(layers.contains("every scene membership"))
    }

    func testHelpExplainsFullScanConnectionAndOfflineFieldBoundaries() throws {
        let connection = try XCTUnwrap(HelpTopics.topic(id: "verbinden")).body
        XCTAssertTrue(connection.contains("Full scan 361 only"))
        XCTAssertTrue(connection.contains("old saved mode choices are ignored"))
        XCTAssertTrue(connection.contains("Three new 361 profiles confirm success"))
        XCTAssertTrue(connection.contains("25 Hz for full scan at 500000 baud"))
        let fields = try XCTUnwrap(HelpTopics.topic(id: "device-fields")).body
        for boundary in ["4 m, OSSD 1/2", "50 m, WEAK SIGNAL", "only to a file", "never enter a preset", "never play", "no safety function claim"] {
            XCTAssertTrue(fields.contains(boundary), boundary)
        }
    }

    func testHelpExplainsIndependentToggleAndTargetedRelease() throws {
        let toggle = try XCTUnwrap(HelpTopics.topic(id: "toggle")).body
        XCTAssertTrue(toggle.contains("Toggle: on / next entry off"))
        XCTAssertTrue(toggle.contains("separate surfaces switch independently"))
        XCTAssertTrue(toggle.contains("movement inside it"))
        XCTAssertTrue(toggle.contains("Single note uses one piano key and velocity"))
        XCTAssertTrue(toggle.contains("Cell overrides inherit the layer transition"))
        XCTAssertTrue(toggle.contains("Scale and Random scale do not offer Toggle"))
        XCTAssertTrue(toggle.contains("after leaving"))
        let release = try XCTUnwrap(HelpTopics.topic(id: "release-layer")).body
        XCTAssertTrue(release.contains("only that target layer's held and toggled notes"))
        XCTAssertTrue(release.contains("A missing layer does nothing"))
        XCTAssertTrue(release.contains("Control layers stay outside scenes"))
    }
}
