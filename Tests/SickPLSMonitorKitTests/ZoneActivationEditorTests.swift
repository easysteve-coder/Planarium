import XCTest
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// SICK-030b1: Zonen entstehen **deaktiviert**, lassen sich gezielt
/// ein- und ausschalten und gezielt entfernen — und jede dieser direkten
/// Änderungen leitet den Entwurf neu aus der gespeicherten Zone ab
/// (Auflage **D3**).
final class ZoneActivationEditorTests: XCTestCase {

    private func zone(
        _ role: ZoneRole = .pitch, _ lower: Double = 0, _ upper: Double = 0.4
    ) throws -> Zone {
        try Zone.build(
            indexLowerBound: lower, indexUpperBound: upper,
            valueLowerBound: 0, valueUpperBound: 1000, role: role
        )
    }

    // MARK: - Vorgabewerte

    func testANewlyAddedZoneIsDisabled() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone())

        XCTAssertEqual(
            state.zones.first(where: { $0.id == id })?.isEnabled, false,
            "Eine frisch gezogene Zone darf beim Einrichten nichts auslösen"
        )
    }

    func testEveryAddedZoneStartsDisabledIndependently() throws {
        var state = ZoneEditorState()
        state.addZone(try zone(.pitch, 0, 0.3))
        state.addZone(try zone(.gate, 0.4, 1))

        XCTAssertEqual(state.zones.map(\.isEnabled), [false, false])
    }

    // MARK: - Ein- und Ausschalten

    func testSwitchingAZoneOnAndOffChangesOnlyThatFlag() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone())
        let before = try XCTUnwrap(state.zones.first)

        XCTAssertTrue(state.setZone(id, isEnabled: true))
        let afterOn = try XCTUnwrap(state.zones.first)
        XCTAssertTrue(afterOn.isEnabled)
        XCTAssertEqual(afterOn.zone, before.zone, "Die fachlichen Werte bleiben unangetastet")
        XCTAssertEqual(afterOn.id, before.id)

        XCTAssertTrue(state.setZone(id, isEnabled: false))
        XCTAssertEqual(state.zones.first?.isEnabled, false)
        XCTAssertEqual(state.zones.first?.zone, before.zone)
    }

    func testSwitchingOneZoneLeavesEveryOtherZoneAlone() throws {
        var state = ZoneEditorState()
        let first = state.addZone(try zone(.pitch, 0, 0.3))
        let second = state.addZone(try zone(.volume, 0.3, 0.6))
        let third = state.addZone(try zone(.gate, 0.6, 1))
        state.setZone(first, isEnabled: true)
        state.setZone(second, isEnabled: true)
        state.setZone(third, isEnabled: true)

        state.setZone(second, isEnabled: false)

        XCTAssertEqual(state.zones.map(\.isEnabled), [true, false, true])
        XCTAssertEqual(state.zones.map(\.id), [first, second, third], "Reihenfolge unverändert")
    }

    func testSwitchingAnUnknownZoneIsRefusedAndChangesNothing() throws {
        var state = ZoneEditorState()
        state.addZone(try zone())
        let before = state

        XCTAssertFalse(state.setZone(EditableZone.ID(), isEnabled: true))
        XCTAssertEqual(state, before)
    }

    // MARK: - Gezieltes Entfernen

    func testRemovingByIDRemovesExactlyThatZone() throws {
        var state = ZoneEditorState()
        let first = state.addZone(try zone(.pitch, 0, 0.3))
        let second = state.addZone(try zone(.volume, 0.3, 0.6))

        XCTAssertTrue(state.removeZone(first))

        XCTAssertEqual(state.zones.map(\.id), [second])
    }

    func testRemovingAnUnknownZoneIsRefusedAndChangesNothing() throws {
        var state = ZoneEditorState()
        state.addZone(try zone())
        let before = state

        XCTAssertFalse(state.removeZone(EditableZone.ID()))
        XCTAssertEqual(state, before)
    }

    func testRemovingTheSelectedZoneClearsSelectionAndDraft() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone())
        XCTAssertNotNil(state.draft, "Testvoraussetzung: Hinzufügen wählt aus")

        state.removeZone(id)

        XCTAssertNil(state.selectedZoneID)
        XCTAssertNil(state.draft)
    }

    func testRemovingAnUnselectedZoneKeepsTheSelection() throws {
        var state = ZoneEditorState()
        let first = state.addZone(try zone(.pitch, 0, 0.3))
        let second = state.addZone(try zone(.volume, 0.3, 0.6))
        XCTAssertEqual(state.selectedZoneID, second)

        state.removeZone(first)

        XCTAssertEqual(state.selectedZoneID, second)
        XCTAssertNotNil(state.draft)
    }

    func testRemoveSelectedZoneStillWorksAndGoesThroughTheSamePath() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone())

        state.removeSelectedZone()

        XCTAssertTrue(state.zones.isEmpty)
        XCTAssertNil(state.selectedZoneID)
        XCTAssertNil(state.draft)
        XCTAssertNotEqual(state.zones.first?.id, id)
    }

    // MARK: - Auflage D3: eine Wahrheit, kein Zusammenführen

    func testSwitchingAZoneRederivesTheDraftFromTheStoredZone() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone(.pitch, 0, 0.4))
        var typed = try XCTUnwrap(state.draft)
        typed.indexUpperBound = 0.9
        state.updateDraft(typed)
        XCTAssertEqual(state.draft?.indexUpperBound, 0.9, "Testvoraussetzung: der Entwurf weicht ab")

        state.setZone(id, isEnabled: true)

        XCTAssertEqual(
            state.draft?.indexUpperBound, 0.4,
            "Der ungespeicherte Eingabewert verfällt; das Feld zeigt den Zonenwert"
        )
        XCTAssertEqual(state.zones.first?.zone.indexRange.upperBound, 0.4, "Und das Modell erst recht")
    }

    func testRemovingAnotherZoneAlsoRederivesTheDraft() throws {
        var state = ZoneEditorState()
        let other = state.addZone(try zone(.volume, 0.5, 0.6))
        state.addZone(try zone(.pitch, 0, 0.4))
        var typed = try XCTUnwrap(state.draft)
        typed.valueUpperBound = 7777
        state.updateDraft(typed)

        state.removeZone(other)

        XCTAssertEqual(state.draft?.valueUpperBound, 1000)
    }

    func testAnUnchangedZoneKeepsItsCommittedValuesAcrossSwitching() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone(.pitch, 0, 0.4))
        var typed = try XCTUnwrap(state.draft)
        typed.indexUpperBound = 0.8
        state.updateDraft(typed)
        XCTAssertTrue(state.commitDraft())

        state.setZone(id, isEnabled: true)
        state.setZone(id, isEnabled: false)

        XCTAssertEqual(
            state.zones.first?.zone.indexRange.upperBound, 0.8,
            "Ein übernommener Wert überlebt jedes Schalten"
        )
    }

    // MARK: - Die Live-Anzeige bleibt vollständig

    func testDisabledZonesAreStillEvaluatedForDisplay() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone(.pitch, 0, 1))
        XCTAssertEqual(state.zones.first?.isEnabled, false)

        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: try (0..<4).map { _ in
                try B0ScanProfile.Measurement.build(value: 500, fieldFlags: 0)
            },
            trailingBytes: [0]
        )

        let evaluations = state.evaluations(against: profile)

        XCTAssertEqual(
            evaluations[id], .controlValue(0.5),
            "Wer eine Zone einrichtet, soll sehen, was sie täte, bevor er sie einschaltet"
        )
    }
}
