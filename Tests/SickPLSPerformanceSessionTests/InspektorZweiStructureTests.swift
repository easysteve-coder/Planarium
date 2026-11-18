import XCTest
import Foundation

/// OWNER-LAUF-1010: MIDI-Zielwahl gehört global zur Summe, nicht je Zug.
/// Reine Textprüfung am Quelltext — dasselbe Muster wie
/// `WorkspaceStructureTests`, aber eigenständig.
@MainActor final class InspektorZweiStructureTests: XCTestCase {

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ name: String) throws -> String {
        let url = Self.packageRoot
            .appendingPathComponent("Sources/SickPLSMonitor/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSumContainsGlobalMIDIDestinationMenu() throws {
        let sum = try source("MixerView.swift")
        XCTAssertTrue(sum.contains("mixer.sum.midi"))
        XCTAssertTrue(sum.contains("instrument.selectMIDITarget"))
        XCTAssertTrue(sum.contains("midi.refresh()"))
    }
    func testRetiredOutputEditorAndImplicitLegacyCatalogAccessorsAreAbsent() throws {
        let inspector = try source("SpatialLayerInspectorView.swift")
        for retired in ["private var outputButtons", "private func outputButton", "selectedAUStripID"] {
            XCTAssertFalse(inspector.contains(retired), retired)
        }
        let catalog = try source("AudioCatalogModel.swift")
        XCTAssertFalse(catalog.contains("var selectedInstrument"))
        XCTAssertFalse(catalog.contains("var availableParameters"))
        XCTAssertTrue(inspector.contains("audioUnits.parameters(for:"))
    }

    func testChannelStripDoesNotOfferAPerStripDestination() throws {
        let strip = try source("ChannelStripView.swift")
        XCTAssertTrue(
            strip.contains("midiDestinations: nil"),
            "Züge bieten keine wirkungslose eigene MIDI-Gerätewahl"
        )
    }

    func testInspectorNoLongerHostsMIDIDestinationControls() throws {
        let inspector = try source("SpatialLayerInspectorView.swift")
        XCTAssertFalse(
            inspector.contains("midiDestinationControls"),
            "Die globale MIDI-Geräteauswahl gehört zur Summe"
        )
        XCTAssertFalse(
            inspector.contains("exclamationmark.octagon.fill"),
            "Global panic belongs at Sum, not the Inspector header"
        )
        let strip = try source("HelmutChannelSurface.swift")
        XCTAssertFalse(strip.contains("channel.strip.panic"))
        XCTAssertTrue(try source("MixerView.swift").contains("mixer.sum.panic"))
    }
}
