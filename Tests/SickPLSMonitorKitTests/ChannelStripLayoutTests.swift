import XCTest
@testable import SickPLSMonitorKit

/// Maße, Kontrast und Taxonomie des Kanalzugs (SICK-033a-0, SICK-033c)
/// -- ohne gerenderte Ansicht.
final class ChannelStripLayoutTests: XCTestCase {

    func testTheReferenceRowIsSixteenPointsButTheHitAreaMeetsMacOSMinimum() {
        XCTAssertEqual(ChannelStripLayout.rowVisualHeight, 16)
        XCTAssertGreaterThanOrEqual(ChannelStripLayout.rowHitHeight, 22)
        XCTAssertGreaterThanOrEqual(ChannelStripLayout.minimumHitTarget, 22)
        XCTAssertGreaterThan(ChannelStripLayout.rowHitHeight, ChannelStripLayout.rowVisualHeight)
    }

    func testTheIndependentStripKeepsItsReferenceWidth() {
        XCTAssertEqual(ChannelStripLayout.stripWidth, WorkspaceLayout.channelStripWidth)
        XCTAssertEqual(ChannelStripLayout.stripWidth, 72, "Der Kanalzug ist ein Drittel schmaler als die frühere 108-pt-Variante")
        XCTAssertEqual(ChannelStripLayout.inspectorWidth, 220, "Der Inspector bleibt über Ausgabevarianten hinweg fest")
        XCTAssertGreaterThan(ChannelStripLayout.cardHeight, 0)
        XCTAssertGreaterThanOrEqual(ChannelStripLayout.cardHeight, 700, "Fader und Inspectorsektionen dürfen nicht gestaucht werden")
    }

    func testAcceptanceB2StripIsExactlyOneThirdNarrower() {
        XCTAssertEqual(ChannelStripLayout.stripWidth, 108 * 2 / 3, accuracy: 0.001)
    }

    func testTextContrastMeetsWCAGAA() {
        let background = ChannelStripLayout.rowBackground
        XCTAssertGreaterThanOrEqual(ChannelStripLayout.primaryText.contrastRatio(against: background), 4.5)
        XCTAssertGreaterThanOrEqual(ChannelStripLayout.secondaryText.contrastRatio(against: background), 4.5)
        XCTAssertGreaterThanOrEqual(ChannelStripLayout.accent.contrastRatio(against: ChannelStripLayout.panelBackground), 3.0)
        XCTAssertGreaterThanOrEqual(
            ChannelStripLayout.primaryText.contrastRatio(against: ChannelStripLayout.rowSelectedBackground), 4.5
        )
    }

    func testEveryEntryIsExactlyOneKindAndHasATitle() {
        var targets = 0, processors = 0, outputs = 0, readouts = 0
        for entry in ChannelStripEntry.allCases {
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertTrue(entry.accessibilityIdentifier.hasPrefix("strip.row."))
            switch entry.kind {
            case .controlTarget: targets += 1
            case .processor: processors += 1
            case .output: outputs += 1
            case .readout: readouts += 1
            }
        }
        XCTAssertEqual(targets, 5, "Pitch, Volume, Filter, Gate, Effekt-Send")
        XCTAssertEqual(processors, 4, "Synth, Delay, Hall, Audio Units")
        XCTAssertEqual(outputs, 2, "Audio, MIDI")
        XCTAssertEqual(readouts, 1)
    }

    func testTheReferenceSceneNamesOnlyExistingEntries() {
        let scene = ChannelStripLayout.ReferenceScene.standard
        XCTAssertTrue(scene.enabledEntries.isSuperset(of: scene.activeEntries))
        XCTAssertEqual(scene.selectedEntry, .gate)
    }

    func testContrastRatioIsSymmetricAndBounded() {
        let black = StripColor(red: 0, green: 0, blue: 0)
        let white = StripColor(red: 1, green: 1, blue: 1)
        XCTAssertEqual(white.contrastRatio(against: black), 21, accuracy: 0.001)
        XCTAssertEqual(black.contrastRatio(against: white), 21, accuracy: 0.001)
        XCTAssertEqual(white.contrastRatio(against: white), 1, accuracy: 0.001)
    }
}
