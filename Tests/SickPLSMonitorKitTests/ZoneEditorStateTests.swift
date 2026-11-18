import XCTest
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

final class ZoneEditorStateTests: XCTestCase {

    private func zone(
        index: ClosedRange<Double> = 0.2...0.6,
        value: ClosedRange<UInt16> = 1000...4000,
        role: ZoneRole = .pitch
    ) throws -> Zone {
        try Zone.build(
            indexLowerBound: index.lowerBound, indexUpperBound: index.upperBound,
            valueLowerBound: value.lowerBound, valueUpperBound: value.upperBound,
            role: role
        )
    }

    private func measurement(_ value: UInt16) throws -> B0ScanProfile.Measurement {
        try B0ScanProfile.Measurement.build(value: value, fieldFlags: 0)
    }

    // MARK: - Leerer Zustand bleibt ruhig und eindeutig

    func testEmptyStateHasNoZonesNoSelectionAndNoDraft() {
        let state = ZoneEditorState()

        XCTAssertTrue(state.zones.isEmpty)
        XCTAssertNil(state.selectedZoneID)
        XCTAssertNil(state.draft)
        XCTAssertNil(state.selectedZone)
    }

    func testEmptyStateEvaluatesToAnEmptyDictionaryEvenWithAProfile() throws {
        let state = ZoneEditorState()
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(100)])

        XCTAssertTrue(state.evaluations(against: profile).isEmpty)
    }

    // MARK: - Hinzufügen wählt sofort aus

    func testAddZoneAppendsAndSelectsIt() throws {
        var state = ZoneEditorState()
        let newZone = try zone()

        let id = state.addZone(newZone)

        XCTAssertEqual(state.zones.map(\.zone), [newZone])
        XCTAssertEqual(state.selectedZoneID, id)
        XCTAssertEqual(state.selectedZone?.zone, newZone)
        XCTAssertEqual(state.draft, ZoneDraft(zone: newZone))
    }

    func testAddingASecondZoneSelectsTheNewOneNotTheFirst() throws {
        var state = ZoneEditorState()
        let first = state.addZone(try zone(role: .pitch))
        let secondZone = try zone(index: 0.7...0.9, role: .gate)

        let second = state.addZone(secondZone)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(state.selectedZoneID, second)
        XCTAssertEqual(state.selectedZone?.zone, secondZone)
    }

    // MARK: - Auswahl

    func testSelectSetsDraftFromTheSelectedZonesCurrentValues() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone())
        state.select(nil)

        state.select(id)

        XCTAssertEqual(state.selectedZoneID, id)
        XCTAssertEqual(state.draft, ZoneDraft(zone: try zone()))
    }

    func testSelectingNilClearsSelectionAndDraft() throws {
        var state = ZoneEditorState()
        state.addZone(try zone())

        state.select(nil)

        XCTAssertNil(state.selectedZoneID)
        XCTAssertNil(state.draft)
        XCTAssertNil(state.selectedZone)
    }

    // MARK: - Löschen

    func testRemoveSelectedZoneDeletesItAndClearsSelectionAndDraft() throws {
        var state = ZoneEditorState()
        state.addZone(try zone())

        state.removeSelectedZone()

        XCTAssertTrue(state.zones.isEmpty)
        XCTAssertNil(state.selectedZoneID)
        XCTAssertNil(state.draft)
    }

    func testRemoveSelectedZoneWithoutASelectionIsANoOp() throws {
        var state = ZoneEditorState()
        let untouched = try zone()
        state.addZone(untouched)
        state.select(nil)

        state.removeSelectedZone()

        XCTAssertEqual(state.zones.map(\.zone), [untouched])
    }

    func testRemovingOneZoneLeavesOtherZonesUntouched() throws {
        var state = ZoneEditorState()
        let keep = state.addZone(try zone(role: .pitch))
        state.addZone(try zone(index: 0.7...0.9, role: .gate))

        state.removeSelectedZone()

        XCTAssertEqual(state.zones.map(\.id), [keep])
    }

    // MARK: - Entwurf bearbeiten, ohne das Modell zu berühren

    func testUpdateDraftWithoutASelectionIsANoOp() {
        var state = ZoneEditorState()

        state.updateDraft(ZoneDraft(indexLowerBound: 0, indexUpperBound: 1, valueLowerBound: 0, valueUpperBound: 100, role: .pitch))

        XCTAssertNil(state.draft)
    }

    func testUpdateDraftReplacesTheDraftButNeverTouchesZonesUntilCommit() throws {
        var state = ZoneEditorState()
        let original = try zone()
        state.addZone(original)

        var draft = state.draft!
        draft.indexLowerBound = 0.0 // vorübergehend ungültig relativ zu einer noch nicht geklammerten Obergrenze
        draft.role = .gate
        state.updateDraft(draft)

        XCTAssertEqual(state.draft?.role, .gate)
        XCTAssertEqual(state.zones.first?.zone, original, "das Modell darf sich vor commitDraft() nicht ändern")
    }

    // MARK: - Übernahme validiert vor der Übernahme ins Modell

    func testCommitDraftWritesAValidatedZoneBackIntoTheModel() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone())

        var draft = state.draft!
        draft.role = .volume
        draft.valueLowerBound = 2000
        draft.valueUpperBound = 3000
        state.updateDraft(draft)

        let success = state.commitDraft()

        XCTAssertTrue(success)
        XCTAssertEqual(state.zones.first(where: { $0.id == id })?.zone.role, .volume)
        XCTAssertEqual(state.zones.first(where: { $0.id == id })?.zone.valueRange, 2000...3000)
    }

    func testCommitDraftClampsBeforeWritingSoTheModelNeverReceivesInvalidValues() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone())

        var draft = state.draft!
        draft.indexLowerBound = 0.5
        draft.indexUpperBound = 0.5 // ungültig ohne Klammerung
        state.updateDraft(draft)

        let success = state.commitDraft()

        XCTAssertTrue(success)
        let committed = state.zones.first(where: { $0.id == id })?.zone
        XCTAssertNotNil(committed)
        XCTAssertLessThan(committed!.indexRange.lowerBound, committed!.indexRange.upperBound)
    }

    func testCommitDraftWithoutASelectionReturnsFalse() {
        var state = ZoneEditorState()

        XCTAssertFalse(state.commitDraft())
    }

    // MARK: - Live-Bewertung: immer aus dem zuletzt übergebenen echten Profil, nie veraltet

    func testEvaluationsReflectTheCurrentZonesAgainstTheGivenProfile() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone(index: 0.0...1.0, value: 0...200))
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(50)])

        let result = state.evaluations(against: profile)[id]

        guard case .controlValue(let value)? = result else {
            return XCTFail("erwartete .controlValue, bekam \(String(describing: result))")
        }
        XCTAssertEqual(value, 50.0 / 200.0, accuracy: 1e-9)
    }

    func testEvaluationsYieldInactiveWhenNoMeasurementFallsInsideTheZone() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone(index: 0.0...1.0, value: 5000...8191))
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(50)])

        XCTAssertEqual(state.evaluations(against: profile)[id], .inactive)
    }

    func testEvaluationsForTwoOverlappingZonesWithDifferentRolesAreIndependent() throws {
        var state = ZoneEditorState()
        let lowID = state.addZone(try zone(index: 0.0...1.0, value: 0...100, role: .pitch))
        let highID = state.addZone(try zone(index: 0.0...1.0, value: 4000...8191, role: .volume))
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(50)])

        let results = state.evaluations(against: profile)

        guard case .controlValue = results[lowID] else {
            return XCTFail("erwartete aktive niedrige Zone")
        }
        XCTAssertEqual(results[highID], .inactive)
    }

    func testEvaluationsNeverCarryAStaleValueFromAnEarlierProfile() throws {
        // Beweis gegen Prognose/Zwischenspeicherung: dieselbe Zone
        // gegen zwei verschiedene, tatsächlich übergebene Profile
        // bewertet, muss beide Male aus dem jeweils *aktuell*
        // übergebenen Profil neu berechnen -- nie das erste Ergebnis
        // weiterreichen.
        var state = ZoneEditorState()
        let id = state.addZone(try zone(index: 0.0...1.0, value: 0...8191))
        let firstProfile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(10)])
        let secondProfile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(8000)])

        let firstResult = state.evaluations(against: firstProfile)[id]
        let secondResult = state.evaluations(against: secondProfile)[id]

        guard case .controlValue(let firstValue)? = firstResult, case .controlValue(let secondValue)? = secondResult else {
            return XCTFail("erwartete zwei aktive, unterschiedliche Ergebnisse")
        }
        XCTAssertNotEqual(firstValue, secondValue)
    }
}
