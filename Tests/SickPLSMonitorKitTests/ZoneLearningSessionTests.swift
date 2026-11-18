import XCTest
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// SICK-030c, Editorvertrag (Auftragspunkt 7): Armieren nur auf
/// deaktivierten Zonen, sichtbare Abbruchgründe, und ein Kandidat, der
/// **nichts** von selbst tut.
final class ZoneLearningSessionTests: XCTestCase {

    private let pointCount = 24
    private let background: UInt16 = 3000

    // MARK: - Aufbau

    private func zone(
        index: ClosedRange<Double> = 0.2...0.6,
        value: ClosedRange<UInt16> = 1000...4000,
        role: ZoneRole = .gate
    ) throws -> Zone {
        try Zone.build(
            indexLowerBound: index.lowerBound, indexUpperBound: index.upperBound,
            valueLowerBound: value.lowerBound, valueUpperBound: value.upperBound,
            role: role
        )
    }

    private func scene(_ overrides: [Int: UInt16] = [:], count: Int? = nil) throws -> B0ScanProfile {
        let n = count ?? pointCount
        var values = Array(repeating: background, count: n)
        for (index, value) in overrides { values[index] = value }
        return try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: try values.map { try B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0) }
        )
    }

    private func configuration() throws -> ZoneLearningConfiguration {
        try ZoneLearningConfiguration.build(
            baselineProfileCount: 3, minimumPersistenceProfiles: 2, minimumClusterPoints: 3,
            maximumIndexGap: 1, movementDelta: 40, indexPaddingPoints: 1,
            valuePadding: 20, backgroundClearance: 30, ambiguityToleranceFactor: 1.25
        )
    }

    /// Ein Editorzustand mit genau einer deaktivierten Zone.
    private func state(role: ZoneRole = .gate) throws -> (ZoneEditorState, EditableZone.ID) {
        var state = ZoneEditorState()
        let id = state.addZone(try zone(role: role))
        return (state, id)
    }

    /// Führt einen vollständigen, erfolgreichen Lauf durch.
    private func feedSuccessfulRun(_ state: inout ZoneEditorState) throws {
        for _ in 0..<3 { state.ingestLearningProfile(try scene()) }
        for _ in 0..<5 { state.ingestLearningProfile(try scene([10: 500, 11: 500, 12: 500])) }
        state.finishLearn()
    }

    // MARK: - Armieren (Auflage D2)

    func testArmingADisabledZoneWorksAndRecordsIDAndRole() throws {
        var (state, id) = try state(role: .volume)

        XCTAssertEqual(state.armLearn(zoneID: id, configuration: try configuration()), .armed)
        XCTAssertEqual(state.learning?.zoneID, id)
        XCTAssertEqual(state.learning?.role, .volume)
        XCTAssertEqual(state.learning?.state, .arming)
    }

    func testArmingAnEnabledZoneIsRefused() throws {
        var (state, id) = try state()
        state.setZone(id, isEnabled: true)

        XCTAssertEqual(state.armLearn(zoneID: id, configuration: try configuration()), .zoneIsEnabled)
        XCTAssertNil(state.learning, "Es wurde nichts armiert")
    }

    func testArmingAnUnknownZoneIsRefused() throws {
        var (state, _) = try state()

        XCTAssertEqual(state.armLearn(zoneID: UUID(), configuration: try configuration()), .unknownZone)
        XCTAssertNil(state.learning)
    }

    /// Ein laufender Vorgang wird nicht verdrängt — dasselbe Muster wie
    /// ein zweiter `start()` am Audiodienst.
    func testASecondArmDoesNotDisplaceARunningSession() throws {
        var state = ZoneEditorState()
        let first = state.addZone(try zone())
        let second = state.addZone(try zone(index: 0.7...0.9, role: .pitch))
        state.armLearn(zoneID: first, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        let outcome = state.armLearn(zoneID: second, configuration: try configuration())

        XCTAssertEqual(outcome, .alreadyLearning(zoneID: first))
        XCTAssertEqual(state.learning?.zoneID, first, "Der laufende Vorgang bleibt")
    }

    // MARK: - Exklusivität gegen den vorzonalen Entwurf (K1, Pflichtnachweis 2)

    /// **Sammelndes vorzonales Lernen blockiert den zonengebundenen
    /// Start, benannt.** Höchstens ein Lernvorgang insgesamt sammelt
    /// gleichzeitig -- sonst führte ``ZoneEditorState/ingestLearningProfile(_:)``
    /// dasselbe Profil in zwei Accumulatoren gleichzeitig fort.
    func testArmingIsBlockedWhileADraftIsCollectingAndLeavesTheDraftUntouched() throws {
        var (state, id) = try state()
        state.startLearnDraft(role: .pitch, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        let outcome = state.armLearn(zoneID: id, configuration: try configuration())

        XCTAssertEqual(outcome, .blockedByLearnDraft)
        XCTAssertNil(state.learning, "Es wurde nichts armiert")
        XCTAssertEqual(
            state.learnDraft?.state, .collectingBaseline(profilesSeen: 1, required: 3),
            "Der sammelnde Entwurf bleibt unangetastet"
        )
    }

    /// Ein bereits **beendetes** Entwurfsergebnis blockiert nichts --
    /// es geht um aktive Sammlung, nicht um ein sichtbares Endergebnis.
    func testArmingIsAllowedAfterTheDraftHasFinished() throws {
        var (state, id) = try state()
        state.startLearnDraft(role: .pitch, configuration: try configuration())
        state.cancelLearnDraft(.operatorCancelled)
        guard case .cancelled = state.learnDraft?.state else {
            return XCTFail("Testvoraussetzung: der Entwurf ist bereits beendet")
        }

        XCTAssertEqual(state.armLearn(zoneID: id, configuration: try configuration()), .armed)
        XCTAssertEqual(state.learning?.zoneID, id)
    }

    /// **Pflichtnachweis 3:** Ein beendeter Entwurf bleibt beendet, auch
    /// während die inzwischen armierte Zone Profile bekommt -- kein
    /// Profil schreibt jemals zwei Accumulatoren gleichzeitig fort.
    func testAProfileNeverAdvancesTheFinishedDraftWhileTheZoneIsCollecting() throws {
        var (state, id) = try state()
        state.startLearnDraft(role: .pitch, configuration: try configuration())
        state.cancelLearnDraft(.operatorCancelled)
        let draftBefore = state.learnDraft
        state.armLearn(zoneID: id, configuration: try configuration())

        state.ingestLearningProfile(try scene())

        XCTAssertEqual(state.learning?.state, .collectingBaseline(profilesSeen: 1, required: 3))
        XCTAssertEqual(state.learnDraft, draftBefore, "Der beendete Entwurf ändert sich nicht mit")
    }

    /// Ein **beendeter** Vorgang darf ersetzt werden.
    func testArmingAfterAFinishedSessionStartsFresh() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        state.cancelLearn()

        XCTAssertEqual(state.armLearn(zoneID: id, configuration: try configuration()), .armed)
        XCTAssertEqual(state.learning?.state, .arming)
    }

    // MARK: - Profile hineinreichen

    func testProfilesOnlyReachAnArmedSession() throws {
        var (state, id) = try state()

        state.ingestLearningProfile(try scene())
        XCTAssertNil(state.learning, "Ohne Armierung entsteht kein Vorgang")

        state.armLearn(zoneID: id, configuration: try configuration())
        state.ingestLearningProfile(try scene())
        XCTAssertEqual(state.learning?.state, .collectingBaseline(profilesSeen: 1, required: 3))
    }

    func testAFullRunProducesACandidateWithTheArmedRole() throws {
        var (state, id) = try state(role: .pitch)
        state.armLearn(zoneID: id, configuration: try configuration())

        try feedSuccessfulRun(&state)

        guard case .candidate(let candidate) = state.learning?.state else {
            return XCTFail("Erwartet: Kandidat, bekommen: \(String(describing: state.learning?.state))")
        }
        XCTAssertEqual(candidate.role, .pitch)
    }

    // MARK: - Der Kandidat tut nichts von selbst

    func testACandidateChangesNeitherTheZoneNorItsActivation() throws {
        var (state, id) = try state()
        let original = try XCTUnwrap(state.zones.first?.zone)
        state.armLearn(zoneID: id, configuration: try configuration())

        try feedSuccessfulRun(&state)

        XCTAssertNotNil(state.learning?.candidate, "Testvoraussetzung: es gibt einen Kandidaten")
        XCTAssertEqual(state.zones.first?.zone, original, "Die Zone ist unverändert")
        XCTAssertFalse(try XCTUnwrap(state.zones.first).isEnabled, "Und weiterhin deaktiviert")
    }

    func testApplyingWritesTheCandidateAndLeavesActivationUntouched() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        try feedSuccessfulRun(&state)
        let candidate = try XCTUnwrap(state.learning?.candidate)

        let outcome = state.applyLearnCandidate()

        XCTAssertEqual(outcome, .applied(candidate))
        XCTAssertEqual(state.zones.first?.zone, candidate)
        XCTAssertFalse(
            try XCTUnwrap(state.zones.first).isEnabled,
            "**Kein automatisches Einschalten** — das bleibt ein eigener Handgriff"
        )
        XCTAssertEqual(state.zones.first?.id, id, "Dieselbe Zone, nicht eine neue")
    }

    /// Auflage **D3**: Nach dem Übernehmen zeigt der Entwurf die neue Zone.
    func testApplyingRederivesTheDraftFromTheNewZone() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        try feedSuccessfulRun(&state)
        var typed = try XCTUnwrap(state.draft)
        typed.valueUpperBound = 7777
        state.updateDraft(typed)

        state.applyLearnCandidate()

        let stored = try XCTUnwrap(state.zones.first?.zone)
        XCTAssertEqual(state.draft, ZoneDraft(zone: stored))
        XCTAssertNotEqual(state.draft?.valueUpperBound, 7777, "Der ungespeicherte Tippwert verfällt")
    }

    // MARK: - Übernehmen nur an dieselbe, deaktivierte Zone

    func testApplyingWithoutASessionIsRefused() {
        var state = ZoneEditorState()
        XCTAssertEqual(state.applyLearnCandidate(), .notLearning)
    }

    func testApplyingWithoutACandidateIsRefusedAndNamesTheState() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        XCTAssertEqual(
            state.applyLearnCandidate(),
            .noCandidate(.collectingBaseline(profilesSeen: 1, required: 3))
        )
    }

    func testApplyingToARemovedZoneIsRefused() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        try feedSuccessfulRun(&state)
        state.removeZone(id)

        XCTAssertEqual(state.applyLearnCandidate(), .targetZoneMissing)
        XCTAssertTrue(state.zones.isEmpty)
    }

    func testApplyingToAZoneThatHasBeenEnabledMeanwhileIsRefused() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        try feedSuccessfulRun(&state)
        let stored = try XCTUnwrap(state.zones.first?.zone)
        state.setZone(id, isEnabled: true)

        XCTAssertEqual(state.applyLearnCandidate(), .targetZoneIsEnabled)
        XCTAssertEqual(state.zones.first?.zone, stored, "Die spielende Zone bleibt unverändert")
    }

    func testApplyingAfterARoleChangeIsRefused() throws {
        var (state, id) = try state(role: .gate)
        state.armLearn(zoneID: id, configuration: try configuration())
        try feedSuccessfulRun(&state)
        var draft = try XCTUnwrap(state.draft)
        draft.role = .pitch
        state.updateDraft(draft)
        state.commitDraft()

        XCTAssertEqual(
            state.applyLearnCandidate(), .targetZoneRoleChanged(expected: .gate, actual: .pitch)
        )
    }

    // MARK: - Der Lebenszyklus beendet die Sitzung sichtbar

    func testRemovingTheTargetZoneCancelsTheSession() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        state.removeZone(id)

        XCTAssertEqual(state.learning?.state, .cancelled(.zoneRemoved))
    }

    func testEnablingTheTargetZoneCancelsTheSession() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        state.setZone(id, isEnabled: true)

        XCTAssertEqual(state.learning?.state, .cancelled(.zoneActivationChanged))
    }

    /// Denselben Wert noch einmal zu setzen ist **keine** Änderung und
    /// beendet deshalb nichts.
    func testSettingTheSameActivationValueDoesNotCancelTheSession() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        state.setZone(id, isEnabled: false)

        XCTAssertTrue(state.learning?.isCollecting == true)
    }

    func testChangingTheTargetZoneRoleCancelsTheSession() throws {
        var (state, id) = try state(role: .gate)
        state.armLearn(zoneID: id, configuration: try configuration())
        state.ingestLearningProfile(try scene())
        var draft = try XCTUnwrap(state.draft)
        draft.role = .filter
        state.updateDraft(draft)

        state.commitDraft()

        XCTAssertEqual(state.learning?.state, .cancelled(.zoneRoleChanged))
    }

    /// Eine reine Grenzenänderung beendet nichts — sie ist genau das, was
    /// das Lernen gleich überschreiben soll.
    func testChangingOnlyTheBoundsDoesNotCancelTheSession() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        state.ingestLearningProfile(try scene())
        var draft = try XCTUnwrap(state.draft)
        draft.valueUpperBound = 5000
        state.updateDraft(draft)

        state.commitDraft()

        XCTAssertTrue(state.learning?.isCollecting == true)
    }

    func testChangesToOtherZonesLeaveTheSessionAlone() throws {
        var state = ZoneEditorState()
        let target = state.addZone(try zone())
        let other = state.addZone(try zone(index: 0.7...0.9, role: .pitch))
        state.armLearn(zoneID: target, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        state.setZone(other, isEnabled: true)
        state.removeZone(other)

        XCTAssertTrue(state.learning?.isCollecting == true, "Eine fremde Zone geht das Lernen nichts an")
    }

    func testAPointCountChangeEndsTheSessionVisibly() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())
        state.ingestLearningProfile(try scene(count: 24))

        state.ingestLearningProfile(try scene(count: 36))

        XCTAssertEqual(state.learning?.state, .failed(.pointCountChanged(expected: 24, received: 36)))
        XCTAssertFalse(state.learning?.isCollecting == true)
    }

    func testCancelAndDiscardAreDifferentThings() throws {
        var (state, id) = try state()
        state.armLearn(zoneID: id, configuration: try configuration())

        state.cancelLearn(.disconnected)
        XCTAssertEqual(
            state.learning?.state, .cancelled(.disconnected),
            "Der Grund bleibt sichtbar, damit die Oberfläche ihn zeigen kann"
        )

        state.discardLearn()
        XCTAssertNil(state.learning)
    }
}
