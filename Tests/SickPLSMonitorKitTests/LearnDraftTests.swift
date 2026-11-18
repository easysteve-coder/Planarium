import XCTest
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// SICK-032c3a: der **vorzonale** Lernentwurf für eine neue Zone --
/// `LearnDraft`, `LearnFocusState`-Einbettung und die fünf
/// `ZoneEditorState`-Methoden, die ihn bedienen.
///
/// Dieselbe Testgrundlage wie `ZoneLearningSessionTests` (Grundfenster
/// drei Profile, Bewegung fünf Profile auf den Indizes 10-12) -- der
/// Accumulator ist unverändert derselbe.
final class LearnDraftTests: XCTestCase {

    private let pointCount = 24
    private let background: UInt16 = 3000

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

    /// Führt einen vollständigen, erfolgreichen Lauf durch den **Entwurf**.
    private func feedSuccessfulRun(_ state: inout ZoneEditorState) throws {
        for _ in 0..<3 { state.ingestLearningProfile(try scene()) }
        for _ in 0..<5 { state.ingestLearningProfile(try scene([10: 500, 11: 500, 12: 500])) }
        state.finishLearnDraft()
    }

    // MARK: - Anlegen erzeugt keine Zone (Pflichtnachweis 1)

    func testStartingADraftCreatesNoZoneAndNoSlotOrAudioEffect() throws {
        var state = ZoneEditorState()
        let before = state.zones.count

        XCTAssertEqual(state.startLearnDraft(role: .filter, configuration: try configuration()), .started)

        XCTAssertEqual(state.zones.count, before, "Anlegen erzeugt keine EditableZone")
        XCTAssertTrue(state.zones.isEmpty)
        XCTAssertEqual(state.learnDraft?.role, .filter)
        XCTAssertEqual(state.learnDraft?.state, .arming)
        XCTAssertNil(state.selectedZoneID, "Es gibt nichts, das ausgewählt sein könnte")
        XCTAssertNil(state.draft, "Kein Kartenentwurf ohne Zone")
    }

    /// Insbesondere nicht die alten erfundenen Grenzen `1000...4000`
    /// (`NewZoneDefaults`, ersatzlos entfernt) -- es gibt schlicht noch
    /// keine `Zone`, an der sich ein solcher Wert prüfen ließe.
    func testStartingADraftNeverProducesTheOldDefaultBounds() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .pitch, configuration: try configuration())
        XCTAssertNil(state.learnDraft?.candidate)
        XCTAssertTrue(state.zones.isEmpty)
    }

    func testASecondStartWhileCollectingIsRefusedAndLeavesTheRunningDraftUntouched() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        let outcome = state.startLearnDraft(role: .gate, configuration: try configuration())

        XCTAssertEqual(outcome, .alreadyDrafting)
        XCTAssertEqual(state.learnDraft?.role, .filter, "Der laufende Entwurf bleibt unverändert")
    }

    /// „Neu starten" heißt: ein **beendeter** Entwurf wird stillschweigend
    /// durch einen frischen ersetzt.
    func testStartingAgainAfterAFinishedDraftReplacesItWithAFreshOne() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        state.finishLearnDraft() // sofort beendet -> Verweigerung (kein Grundfenster)
        guard case .refused = state.learnDraft?.state else {
            return XCTFail("Testvoraussetzung: der erste Entwurf ist beendet")
        }

        XCTAssertEqual(state.startLearnDraft(role: .volume, configuration: try configuration()), .started)
        XCTAssertEqual(state.learnDraft?.role, .volume)
        XCTAssertEqual(state.learnDraft?.state, .arming, "Kein altes Ergebnis wirkt weiter")
    }

    // MARK: - Ohne Profil / nur unbrauchbare Werte (Pflichtnachweis 2)

    func testWithoutAnyIngestedProfileFinishRefusesAndApplyProducesNothing() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        state.finishLearnDraft()

        guard case .refused(.baselineIncomplete) = state.learnDraft?.state else {
            return XCTFail("Erwartet: Verweigerung wegen fehlendem Grundfenster, war \(String(describing: state.learnDraft?.state))")
        }
        XCTAssertEqual(state.applyLearnDraftCandidate(), .noCandidate(.refused(.baselineIncomplete(seen: 0, required: 3))))
        XCTAssertTrue(state.zones.isEmpty)
    }

    /// Ein Grundfenster aus ausschließlich `0`/`8191` liefert keine
    /// Hüllkurve an keinem Index -- Bewegung kann dort nie gezählt
    /// werden, der Vorgang landet in einer Verweigerung, nie in einer
    /// Zone.
    func testAllUnusableValuesNeverProduceACandidate() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .gate, configuration: try configuration())

        let sentinelProfile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: try Array(repeating: UInt16(0), count: pointCount).enumerated().map {
                try B0ScanProfile.Measurement.build(value: $0.offset.isMultiple(of: 2) ? 0 : 8_191, fieldFlags: 0)
            }
        )
        for _ in 0..<3 { state.ingestLearningProfile(sentinelProfile) }
        for _ in 0..<5 { state.ingestLearningProfile(sentinelProfile) }
        state.finishLearnDraft()

        guard case .refused(.insufficientMotion(let largest, _)) = state.learnDraft?.state else {
            return XCTFail("Erwartet: Verweigerung wegen fehlender Bewegung, war \(String(describing: state.learnDraft?.state))")
        }
        XCTAssertEqual(largest, 0)
        XCTAssertTrue(state.zones.isEmpty)
    }

    // MARK: - Übernahme (Pflichtnachweis 4)

    func testFinishPlusApplyOfAValidCandidateProducesExactlyOneSelectedDisabledZoneWithTheDraftsRole() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .volume, configuration: try configuration())
        try feedSuccessfulRun(&state)

        guard case .candidate(let candidate) = state.learnDraft?.state else {
            return XCTFail("Testvoraussetzung: ein Kandidat liegt vor, war \(String(describing: state.learnDraft?.state))")
        }

        let outcome = state.applyLearnDraftCandidate()
        guard case .applied(let id, let appliedZone) = outcome else {
            return XCTFail("Erwartet: erfolgreiche Übernahme, war \(outcome)")
        }
        XCTAssertEqual(appliedZone, candidate)
        XCTAssertEqual(state.zones.count, 1)
        let inserted = try XCTUnwrap(state.zones.first { $0.id == id })
        XCTAssertEqual(inserted.zone, candidate)
        XCTAssertEqual(inserted.zone.role, .volume)
        XCTAssertFalse(inserted.isEnabled, "Auflage D2: weiterhin ausgeschaltet")
        XCTAssertEqual(state.selectedZoneID, id, "Sofort ausgewählt, wie beim bestehenden addZone(_:)")
    }

    func testASecondApplyAfterASuccessfulOneProducesNothing() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        try feedSuccessfulRun(&state)
        let first = state.applyLearnDraftCandidate()
        guard case .applied = first else { return XCTFail("Testvoraussetzung: die erste Übernahme gelingt") }
        let countAfterFirst = state.zones.count

        XCTAssertEqual(state.applyLearnDraftCandidate(), .notDrafting)
        XCTAssertEqual(state.zones.count, countAfterFirst, "Kein zweiter Zonenübertrag")
    }

    func testApplyWithoutAnyDraftProducesNothing() {
        var state = ZoneEditorState()
        XCTAssertEqual(state.applyLearnDraftCandidate(), .notDrafting)
        XCTAssertTrue(state.zones.isEmpty)
    }

    func testApplyWhileStillCollectingProducesNothing() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        XCTAssertEqual(state.applyLearnDraftCandidate(), .noCandidate(.collectingBaseline(profilesSeen: 1, required: 3)))
        XCTAssertTrue(state.zones.isEmpty)
        XCTAssertNotNil(state.learnDraft, "Ein noch sammelnder Entwurf bleibt erhalten")
    }

    /// Jede der drei Endlagen, die **kein** Vorschlag sind, erzeugt beim
    /// Übernehmen nichts.
    func testEveryNonCandidateEndStateProducesNothingOnApply() throws {
        // Verweigert.
        do {
            var state = ZoneEditorState()
            state.startLearnDraft(role: .filter, configuration: try configuration())
            state.finishLearnDraft()
            guard case .noCandidate(.refused) = state.applyLearnDraftCandidate() else {
                return XCTFail("Verweigerung sollte .noCandidate ergeben")
            }
            XCTAssertTrue(state.zones.isEmpty)
        }
        // Abgebrochen.
        do {
            var state = ZoneEditorState()
            state.startLearnDraft(role: .filter, configuration: try configuration())
            state.cancelLearnDraft(.operatorCancelled)
            guard case .noCandidate(.cancelled(.operatorCancelled)) = state.applyLearnDraftCandidate() else {
                return XCTFail("Abbruch sollte .noCandidate ergeben")
            }
            XCTAssertTrue(state.zones.isEmpty)
        }
        // Fehlgeschlagen (leeres Profil).
        do {
            var state = ZoneEditorState()
            state.startLearnDraft(role: .filter, configuration: try configuration())
            let empty = try B0ScanProfile.build(partialScanIndex: 0, measurements: [])
            state.ingestLearningProfile(empty)
            guard case .noCandidate(.failed(.emptyProfile)) = state.applyLearnDraftCandidate() else {
                return XCTFail("Fehlschlag sollte .noCandidate ergeben")
            }
            XCTAssertTrue(state.zones.isEmpty)
        }
    }

    // MARK: - Abbruch, Löschen, Neustart, Trennung (Pflichtnachweis 5)

    func testCancelEndsACollectingDraftWithTheGivenReason() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        state.cancelLearnDraft(.operatorCancelled)

        XCTAssertEqual(state.learnDraft?.state, .cancelled(.operatorCancelled))
        XCTAssertTrue(state.zones.isEmpty)
    }

    func testCancelNeverOverwritesAnAlreadyFallenResult() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        try feedSuccessfulRun(&state)
        guard case .candidate = state.learnDraft?.state else {
            return XCTFail("Testvoraussetzung: ein Kandidat liegt vor")
        }

        state.cancelLearnDraft(.operatorCancelled)

        guard case .candidate = state.learnDraft?.state else {
            return XCTFail("Ein bereits gefallenes Ergebnis darf nicht überschrieben werden")
        }
    }

    func testDiscardClearsTheDraftEntirely() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        state.discardLearnDraft()

        XCTAssertNil(state.learnDraft)
    }

    /// **Der explizite `.disconnected`-Fall** (auf Koordinatorebene wird
    /// er beim tatsächlichen Verbindungsende ausgelöst, siehe
    /// `CoordinatorLearnDraftTests`) -- hier direkt am Modell geprüft.
    func testDisconnectedCancellationEndsACollectingDraftButNotAnAlreadyFinishedOne() throws {
        var collecting = ZoneEditorState()
        collecting.startLearnDraft(role: .filter, configuration: try configuration())
        collecting.ingestLearningProfile(try scene())
        collecting.cancelLearnDraft(.disconnected)
        XCTAssertEqual(collecting.learnDraft?.state, .cancelled(.disconnected))

        var finished = ZoneEditorState()
        finished.startLearnDraft(role: .filter, configuration: try configuration())
        finished.finishLearnDraft()
        guard case .refused = finished.learnDraft?.state else {
            return XCTFail("Testvoraussetzung: bereits beendet")
        }
        finished.cancelLearnDraft(.disconnected)
        guard case .refused = finished.learnDraft?.state else {
            return XCTFail("Ein bereits gefallenes Ergebnis bleibt auch bei .disconnected stehen")
        }
    }

    /// **Kein alter Profilstand fließt in einen Neustart ein:** Ein
    /// bereits weit fortgeschrittener, dann verworfener Entwurf lässt
    /// den nächsten wieder bei `.arming` beginnen.
    func testAfterDiscardingAFarAdvancedDraftAFreshOneStartsAtTheBeginning() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        for _ in 0..<3 { state.ingestLearningProfile(try scene()) }
        guard case .collectingMovement = state.learnDraft?.state else {
            return XCTFail("Testvoraussetzung: das Grundfenster ist voll")
        }
        state.discardLearnDraft()

        state.startLearnDraft(role: .filter, configuration: try configuration())
        XCTAssertEqual(state.learnDraft?.state, .arming)
    }

    // MARK: - Exklusivität gegen das zonengebundene Lernen (K1, Pflichtnachweis 2)
    //
    // **Ersetzt `testTheDraftAndTheZoneBasedLearningSessionCoexistIndependently`**
    // (SICK-032c3a-K1, Abnahmeblocker 2, `review-sick-032c3a.md`): Der
    // entfernte Test erklärte gleichzeitiges Sammeln zum Soll -- das
    // widersprach der bereits dokumentierten Begründung des bestehenden
    // Lernvertrags (höchstens ein sammelnder Vorgang, weil zwei sich
    // denselben Profilstrom teilten). Getrennte **Instanzen** bleiben es
    // weiterhin, siehe unten.

    /// **Sammelndes zonengebundenes Learn blockiert den Draftstart,
    /// benannt.**
    func testStartingADraftIsBlockedWhileAZoneIsLearningAndLeavesItUntouched() throws {
        var state = ZoneEditorState()
        let zoneID = state.addZone(try Zone.build(
            indexLowerBound: 0.2, indexUpperBound: 0.6,
            valueLowerBound: 1_000, valueUpperBound: 4_000, role: .gate
        ))
        state.armLearn(zoneID: zoneID, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        let outcome = state.startLearnDraft(role: .pitch, configuration: try configuration())

        XCTAssertEqual(outcome, .blockedByZoneLearning(zoneID: zoneID))
        XCTAssertNil(state.learnDraft, "Es wurde kein Entwurf angelegt")
        XCTAssertEqual(
            state.learning?.state, .collectingBaseline(profilesSeen: 1, required: 3),
            "Der sammelnde zonengebundene Lernvorgang bleibt unangetastet"
        )
    }

    /// Ein bereits **beendetes** zonengebundenes Ergebnis blockiert
    /// nichts -- es geht um aktive Sammlung, nicht um ein sichtbares
    /// Endergebnis.
    func testStartingADraftIsAllowedAfterTheZoneLearningSessionHasFinished() throws {
        var state = ZoneEditorState()
        let zoneID = state.addZone(try Zone.build(
            indexLowerBound: 0.2, indexUpperBound: 0.6,
            valueLowerBound: 1_000, valueUpperBound: 4_000, role: .gate
        ))
        state.armLearn(zoneID: zoneID, configuration: try configuration())
        state.cancelLearn(.operatorCancelled)
        guard case .cancelled = state.learning?.state else {
            return XCTFail("Testvoraussetzung: der zonengebundene Vorgang ist bereits beendet")
        }

        XCTAssertEqual(state.startLearnDraft(role: .pitch, configuration: try configuration()), .started)
        XCTAssertEqual(state.learnDraft?.role, .pitch)
    }

    /// **Pflichtnachweis 3:** Kein Profil schreibt jemals zwei
    /// Accumulatoren gleichzeitig fort -- hier von der Entwurfsseite:
    /// Ein sammelnder Entwurf bleibt unverändert, während eine daneben
    /// (nach deren Ende) armierte Zone dieselben Profile bekommt.
    func testAProfileNeverAdvancesTheZoneLearningSessionWhileTheDraftIsCollecting() throws {
        var state = ZoneEditorState()
        let zoneID = state.addZone(try Zone.build(
            indexLowerBound: 0.2, indexUpperBound: 0.6,
            valueLowerBound: 1_000, valueUpperBound: 4_000, role: .gate
        ))
        state.armLearn(zoneID: zoneID, configuration: try configuration())
        state.cancelLearn(.operatorCancelled)
        let learningBefore = state.learning
        state.startLearnDraft(role: .pitch, configuration: try configuration())

        state.ingestLearningProfile(try scene())

        XCTAssertEqual(state.learnDraft?.state, .collectingBaseline(profilesSeen: 1, required: 3))
        XCTAssertEqual(state.learning, learningBefore, "Der beendete zonengebundene Vorgang ändert sich nicht mit")
    }

    /// Zwei getrennte **Instanzen** bleiben weiterhin möglich -- nur
    /// gleichzeitig **sammeln** dürfen sie nie: Nach dem Ende des einen
    /// Pfads bleibt der jeweils andere unabhängig bestehen.
    func testTheDraftAndAFinishedZoneBasedSessionRemainIndependentInstances() throws {
        var state = ZoneEditorState()
        let zoneID = state.addZone(try Zone.build(
            indexLowerBound: 0.2, indexUpperBound: 0.6,
            valueLowerBound: 1_000, valueUpperBound: 4_000, role: .gate
        ))
        state.armLearn(zoneID: zoneID, configuration: try configuration())
        state.cancelLearn(.operatorCancelled)
        state.startLearnDraft(role: .pitch, configuration: try configuration())
        state.ingestLearningProfile(try scene())

        state.cancelLearnDraft(.operatorCancelled)

        XCTAssertEqual(state.learnDraft?.state, .cancelled(.operatorCancelled))
        XCTAssertEqual(
            state.learning?.state, .cancelled(.operatorCancelled),
            "Der längst beendete zonengebundene Vorgang bleibt, wie er war"
        )
    }

    /// Pflichtnachweis 7: Der Entwurf erreicht ``zones`` nur über die
    /// ausdrückliche Übernahme -- niemals durch bloßes Ingestieren.
    func testIngestingProfilesIntoACollectingDraftNeverTouchesTheZoneList() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        let before = state.zones
        for _ in 0..<3 { state.ingestLearningProfile(try scene()) }
        for _ in 0..<5 { state.ingestLearningProfile(try scene([10: 500, 11: 500, 12: 500])) }
        XCTAssertEqual(state.zones, before)
    }

    // MARK: - Fokuszustand-Weiterleitung

    func testANewDraftHasAFreshPendingFocusState() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        XCTAssertTrue(state.learnDraft?.focus.isAutomaticFocusStillPending == true)
    }

    func testApplyLearnDraftFocusInputForwardsToTheRunningDraft() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())

        XCTAssertEqual(state.applyLearnDraftFocusInput(.measurementAvailable), .focusNow)
        XCTAssertFalse(state.learnDraft?.focus.isAutomaticFocusStillPending == true)
        XCTAssertEqual(state.applyLearnDraftFocusInput(.measurementAvailable), .doNothing)
    }

    func testApplyLearnDraftFocusInputWithoutADraftDoesNothing() {
        var state = ZoneEditorState()
        XCTAssertEqual(state.applyLearnDraftFocusInput(.measurementAvailable), .doNothing)
    }

    /// **Kein alter Entwurf wirkt nach einem Neustart unbemerkt weiter:**
    /// Ein Entwurf, der seinen automatischen Fokus bereits verbraucht
    /// hat, wird durch einen frischen, wieder ausstehenden ersetzt.
    func testRestartingGivesAFreshFocusStateEvenIfThePreviousOneHadAlreadyFocused() throws {
        var state = ZoneEditorState()
        state.startLearnDraft(role: .filter, configuration: try configuration())
        state.applyLearnDraftFocusInput(.measurementAvailable)
        state.finishLearnDraft()
        guard case .refused = state.learnDraft?.state else {
            return XCTFail("Testvoraussetzung: der erste Entwurf ist beendet")
        }

        state.startLearnDraft(role: .filter, configuration: try configuration())

        XCTAssertTrue(state.learnDraft?.focus.isAutomaticFocusStillPending == true)
    }
}
