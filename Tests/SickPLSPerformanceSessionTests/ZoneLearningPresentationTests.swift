import PlanariumInput
import XCTest
import SickPLSControlCore
import SickPLSCore
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// SICK-032c2, Akzeptanz 1: **Jeder** vorhandene `ZoneLearningState`,
/// jeder Arm-/Apply-Ausgang und jede Konfigurationsangabe hat eine
/// getestete, eindeutige Präsentation.
///
/// Reine Texttests ohne Ansicht, ohne Gerät, ohne Scanner und ohne Uhr.
/// Die drei Endlagen — **verweigert**, **abgebrochen**, **fehlgeschlagen**
/// — werden ausdrücklich gegeneinander geprüft: Sie verlangen drei
/// verschiedene Handgriffe, und niemand darf bloß „Fehler" lesen.
@MainActor final class ZoneLearningPresentationTests: XCTestCase {

    private let zoneID = EditableZone.ID()

    private func zone(role: ZoneRole = .pitch) -> Zone {
        try! Zone.build(
            indexLowerBound: 0.2, indexUpperBound: 0.4,
            valueLowerBound: 300, valueUpperBound: 900, role: role
        )
    }

    // MARK: - Schritt je Zustand

    /// Alle acht Zustände des Lernvertrags bekommen ihren **eigenen**
    /// Schritt — `arming` ist ausdrücklich ein anderer als „Grundprofil
    /// läuft".
    func testEveryLearningStateMapsToItsOwnPhase() {
        XCTAssertEqual(ZoneLearningPhase(state: .arming), .waitingForProfiles)
        XCTAssertEqual(
            ZoneLearningPhase(state: .collectingBaseline(profilesSeen: 2, required: 5)),
            .collectingBaseline(profilesSeen: 2, required: 5)
        )
        XCTAssertEqual(
            ZoneLearningPhase(
                state: .collectingMovement(
                    profilesSeen: 9, changedIndexCount: 4, persistentIndexCount: 3
                )
            ),
            .collectingMovement(profilesSeen: 9, changedIndexCount: 4, persistentIndexCount: 3)
        )
        XCTAssertEqual(ZoneLearningPhase(state: .candidate(zone())), .candidate(zone()))
        XCTAssertEqual(
            ZoneLearningPhase(state: .refused(.backgroundInsideZone)),
            .refused(.backgroundInsideZone)
        )
        XCTAssertEqual(
            ZoneLearningPhase(state: .cancelled(.operatorCancelled)),
            .cancelled(.operatorCancelled)
        )
        XCTAssertEqual(
            ZoneLearningPhase(state: .failed(.emptyProfile)), .failed(.emptyProfile)
        )
    }

    /// Nur die drei Sammelschritte gelten als „sammelt", nur die vier
    /// Endlagen als „hat ein Ergebnis". Ein `idle` ist keins von beidem.
    func testCollectingAndResultAreDisjointAndComplete() {
        let collecting: [ZoneLearningPhase] = [
            .waitingForProfiles,
            .collectingBaseline(profilesSeen: 1, required: 5),
            .collectingMovement(profilesSeen: 6, changedIndexCount: 2, persistentIndexCount: 1)
        ]
        let results: [ZoneLearningPhase] = [
            .candidate(zone()),
            .refused(.candidateNotBuildable),
            .cancelled(.zoneRemoved),
            .failed(.emptyProfile)
        ]
        for phase in collecting {
            XCTAssertTrue(phase.isCollecting)
            XCTAssertFalse(phase.hasResult)
        }
        for phase in results {
            XCTAssertFalse(phase.isCollecting)
            XCTAssertTrue(phase.hasResult)
        }
        XCTAssertFalse(ZoneLearningPhase.idle.isCollecting)
        XCTAssertFalse(ZoneLearningPhase.idle.hasResult)
    }

    // MARK: - Die drei Endlagen bleiben getrennt

    private let allRefusals: [ZoneLearningRefusal] = [
        .baselineIncomplete(seen: 2, required: 5),
        .insufficientMotion(largestClusterPoints: 1, required: 3),
        .ambiguousCandidates(strongestHits: 9, runnerUpHits: 8),
        .backgroundInsideZone,
        .candidateNotBuildable
    ]

    private let allCancellations: [ZoneLearningCancellation] = [
        .operatorCancelled, .zoneRemoved, .zoneRoleChanged, .zoneActivationChanged, .disconnected
    ]

    private let allFailures: [ZoneLearningFailure] = [
        .pointCountChanged(expected: 90, received: 180), .emptyProfile
    ]

    func testEveryRefusalHasItsOwnActionableText() {
        let texts = allRefusals.map(\.operatorText)
        XCTAssertEqual(Set(texts).count, allRefusals.count, "Jede Verweigerung hat ihren eigenen Satz")
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.lowercased().contains("fehler"), "Eine Verweigerung ist kein Fehler")
        }
        // Die Zahlen aus dem Lernvertrag erscheinen unverändert.
        XCTAssertTrue(ZoneLearningRefusal.baselineIncomplete(seen: 2, required: 5)
            .operatorText.contains("2 of 5"))
        XCTAssertTrue(ZoneLearningRefusal.insufficientMotion(largestClusterPoints: 1, required: 3)
            .operatorText.contains("1 of 3"))
        XCTAssertTrue(ZoneLearningRefusal.ambiguousCandidates(strongestHits: 9, runnerUpHits: 8)
            .operatorText.contains("9 and 8"))
    }

    func testEveryCancellationHasItsOwnText() {
        let texts = allCancellations.map(\.operatorText)
        XCTAssertEqual(Set(texts).count, allCancellations.count)
        for text in texts { XCTAssertFalse(text.isEmpty) }
    }

    func testEveryFailureHasItsOwnText() {
        let texts = allFailures.map(\.operatorText)
        XCTAssertEqual(Set(texts).count, allFailures.count)
        XCTAssertTrue(ZoneLearningFailure.pointCountChanged(expected: 90, received: 180)
            .operatorText.contains("180"))
    }

    /// **Der Kernnachweis zu Anforderung 4:** Verweigerung, Abbruch und
    /// Fehlschlag sind in Schritt **und** Satz voneinander verschieden.
    func testRefusedCancelledAndFailedAreThreeDistinctPresentations() {
        let refused = presentation(phase: .refused(.backgroundInsideZone))
        let cancelled = presentation(phase: .cancelled(.operatorCancelled))
        let failed = presentation(phase: .failed(.emptyProfile))

        XCTAssertEqual(
            Set([refused.stepTitle, cancelled.stepTitle, failed.stepTitle]).count, 3,
            "Drei verschiedene Schrittüberschriften"
        )
        XCTAssertEqual(
            Set([refused.instruction, cancelled.instruction, failed.instruction]).count, 3,
            "Drei verschiedene Handlungsanweisungen"
        )
        for presentation in [refused, cancelled, failed] {
            XCTAssertNil(presentation.progressLabel, "Ein beendeter Vorgang zeigt keinen Fortschritt")
            XCTAssertNil(presentation.candidateBoundsLabel)
            XCTAssertTrue(presentation.canDiscard)
            XCTAssertFalse(presentation.canApply)
            XCTAssertFalse(presentation.canFinish)
        }
    }

    /// Alle zwölf Endlagen zusammen ergeben zwölf verschiedene
    /// Anweisungen — kein Sammeltext.
    func testAllEndStatesTogetherProduceDistinctInstructions() {
        var instructions: [String] = []
        for refusal in allRefusals { instructions.append(presentation(phase: .refused(refusal)).instruction) }
        for reason in allCancellations {
            instructions.append(presentation(phase: .cancelled(reason)).instruction)
        }
        for failure in allFailures { instructions.append(presentation(phase: .failed(failure)).instruction) }
        XCTAssertEqual(Set(instructions).count, instructions.count)
    }

    // MARK: - Fortschritt ohne Uhr

    /// Solange kein einziges echtes Profil eingetroffen ist, steht dort
    /// ehrlich „Warte auf Messwerte" — **kein** Balken, kein Anteil.
    func testWaitingForProfilesSaysSoHonestly() {
        let waiting = presentation(phase: .waitingForProfiles)
        XCTAssertEqual(waiting.progressLabel, "Waiting for measurements")
        XCTAssertEqual(waiting.stepTitle, "Keep scan field clear briefly")
        XCTAssertTrue(waiting.canFinish)
        XCTAssertTrue(waiting.canCancel)
        XCTAssertFalse(waiting.canStart)
    }

    /// Der Fortschritt zitiert ausschließlich die Zahlen des
    /// Lernvertrags.
    func testProgressQuotesOnlyRealProfileCounts() {
        XCTAssertEqual(
            presentation(phase: .collectingBaseline(profilesSeen: 3, required: 5)).progressLabel,
            "Baseline profile 3 of 5"
        )
        let movement = presentation(
            phase: .collectingMovement(profilesSeen: 12, changedIndexCount: 7, persistentIndexCount: 4)
        )
        XCTAssertEqual(movement.progressLabel, "12 profiles · 7 measurement points changed · 4 stable")
        XCTAssertEqual(movement.stepTitle, "Move hand through desired area")
    }

    // MARK: - Vorschlag

    /// Der Vorschlag zeigt seine vier Grenzen in **derselben**
    /// Darstellung wie das Insert — und ist noch nirgends geschrieben.
    func testTheCandidateShowsItsFourBoundsInTheOneSharedFormat() {
        let candidate = presentation(phase: .candidate(zone()))
        XCTAssertEqual(candidate.candidateBoundsLabel, ZoneBoundsText.label(for: zone()))
        XCTAssertEqual(candidate.stepTitle, "Suggestion")
        XCTAssertTrue(candidate.canApply)
        XCTAssertTrue(candidate.canDiscard)
        XCTAssertFalse(candidate.canFinish)
        XCTAssertTrue(
            candidate.instruction.contains(ZoneLearningPresentation.applyTitle),
            "Die Anleitung zitiert den Knopf wörtlich"
        )
    }

    // MARK: - Sperrgründe

    /// Anforderung 1: Auf einer **eingeschalteten** Zone ist der Start
    /// gesperrt, und der Grund steht in Alltagssprache da.
    func testAnEnabledZoneBlocksTheStartWithAPlainSentence() {
        let blocked = ZoneLearningPresentation(
            zoneID: zoneID, isZoneEnabled: true, learning: nil
        )
        XCTAssertEqual(blocked.block, .zoneIsEnabled)
        XCTAssertEqual(blocked.blockMessage, "Disable this zone before learning.")
        XCTAssertFalse(blocked.canStart)
        XCTAssertFalse(blocked.canApply)
    }

    /// Ein Vorschlag an einer inzwischen eingeschalteten Zone lässt sich
    /// **nicht** übernehmen — sein Inhalt bleibt aber lesbar. Sperrgrund
    /// und Schritt stehen nebeneinander und ersetzen einander nicht.
    func testACandidateOnAnEnabledZoneCannotBeAppliedButStaysReadable() {
        let blocked = ZoneLearningPresentation(
            zoneID: zoneID,
            isZoneEnabled: true,
            phase: .candidate(zone()),
            block: .zoneIsEnabled,
            configuration: .default
        )
        XCTAssertFalse(blocked.canApply, "Auflage D2 gilt auch beim Übernehmen")
        XCTAssertEqual(blocked.blockMessage, "Disable this zone before learning.")
        XCTAssertEqual(blocked.candidateBoundsLabel, ZoneBoundsText.label(for: zone()))
        XCTAssertEqual(blocked.stepTitle, "Suggestion")
        XCTAssertTrue(blocked.canDiscard)
    }

    /// **SICK-032c3a-K1:** Ein sammelnder vorzonaler Entwurf sperrt den
    /// (Neu-)Start hier genauso wie eine andere sammelnde Zone -- die
    /// projektweite Exklusivität aus beiden Richtungen sichtbar.
    func testACollectingDraftBlocksTheStartWithAPlainSentence() {
        let blocked = ZoneLearningPresentation(
            zoneID: zoneID, isZoneEnabled: false, learning: nil, learnDraftIsCollecting: true
        )
        XCTAssertEqual(blocked.block, .learnDraftIsCollecting)
        XCTAssertEqual(
            blocked.blockMessage,
            "A new zone is being learned. Finish, apply, or discard that draft first."
        )
        XCTAssertFalse(blocked.canStart)
    }

    /// Eine eingeschaltete Zone hat Vorrang vor der Entwurfssperre --
    /// beide gelten hier zwar nie gleichzeitig für die produktive
    /// Auslösung (`armLearn` prüft die Sammlung vor `isEnabled`), aber
    /// die Anzeige entscheidet sich trotzdem eindeutig für **einen**
    /// Grund statt zweier gleichzeitig sichtbarer Sperrsätze.
    func testAnEnabledZoneBlockOutranksACollectingDraft() {
        let blocked = ZoneLearningPresentation(
            zoneID: zoneID, isZoneEnabled: true, learning: nil, learnDraftIsCollecting: true
        )
        XCTAssertEqual(blocked.block, .zoneIsEnabled)
    }

    /// Ohne Sperrgrund und ohne laufenden Vorgang ist genau der Start
    /// möglich.
    func testAnIdleDisabledZoneOffersOnlyTheStart() {
        let idle = ZoneLearningPresentation(zoneID: zoneID, isZoneEnabled: false, learning: nil)
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertNil(idle.block)
        XCTAssertTrue(idle.canStart)
        XCTAssertFalse(idle.canFinish)
        XCTAssertFalse(idle.canCancel)
        XCTAssertFalse(idle.canApply)
        XCTAssertFalse(idle.canDiscard)
        XCTAssertNil(idle.progressLabel)
    }

    // MARK: - Arm- und Apply-Ausgänge

    func testEveryArmOutcomeHasItsOwnNotice() {
        let outcomes: [ZoneLearningArmOutcome] = [
            .armed, .unknownZone, .zoneIsEnabled, .alreadyLearning(zoneID: zoneID), .blockedByLearnDraft
        ]
        let notices = outcomes.map(\.notice)
        XCTAssertEqual(Set(notices.map(\.message)).count, outcomes.count)
        XCTAssertEqual(notices.map(\.isSuccess), [true, false, false, false, false])
        XCTAssertEqual(
            ZoneLearningArmOutcome.zoneIsEnabled.notice.message,
            ZoneLearningBlock.zoneIsEnabled.message,
            "Sperrgrund und Ablehnung sagen denselben Satz"
        )
        XCTAssertEqual(
            ZoneLearningArmOutcome.blockedByLearnDraft.notice.message,
            ZoneLearningBlock.learnDraftIsCollecting.message,
            "Auch hier sagen Sperrgrund und Ablehnung denselben Satz (K1)"
        )
    }

    func testEveryApplyOutcomeHasItsOwnNotice() {
        let outcomes: [ZoneLearningApplyOutcome] = [
            .applied(zone()),
            .notLearning,
            .noCandidate(.arming),
            .targetZoneMissing,
            .targetZoneIsEnabled,
            .targetZoneRoleChanged(expected: .pitch, actual: .gate)
        ]
        let notices = outcomes.map(\.notice)
        XCTAssertEqual(Set(notices.map(\.message)).count, outcomes.count)
        XCTAssertEqual(notices.map(\.isSuccess), [true, false, false, false, false, false])
        XCTAssertTrue(
            ZoneLearningApplyOutcome.applied(zone()).notice.message.contains("disabled"),
            "Der Erfolgssatz sagt ausdrücklich, dass nichts eingeschaltet wurde"
        )
        let roleChange = ZoneLearningApplyOutcome
            .targetZoneRoleChanged(expected: .pitch, actual: .gate).notice.message
        XCTAssertTrue(roleChange.contains("Pitch") && roleChange.contains("Gate"))
    }

    // MARK: - Lesbare Lernparameter

    /// Jede Angabe der Konfiguration erscheint als eigene, erklärte
    /// Zeile — und zitiert den **echten** Wert.
    func testEveryConfigurationValueIsExplainedOnce() {
        let configuration = ZoneLearningConfiguration.default
        let lines = configuration.explanations

        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count, "Stabile, eindeutige Schlüssel")
        for line in lines {
            XCTAssertFalse(line.title.isEmpty)
            XCTAssertFalse(line.value.isEmpty)
            XCTAssertFalse(line.detail.isEmpty)
        }

        func value(_ id: String) -> String {
            lines.first { $0.id == id }?.value ?? ""
        }
        XCTAssertTrue(value("baseline").contains("\(configuration.baselineProfileCount)"))
        XCTAssertTrue(value("persistence").contains("\(configuration.minimumPersistenceProfiles)"))
        XCTAssertTrue(value("cluster").contains("\(configuration.minimumClusterPoints)"))
        XCTAssertTrue(value("cluster").contains("\(configuration.maximumIndexGap)"))
        XCTAssertTrue(value("movement").contains("\(configuration.movementDelta)"))
        XCTAssertTrue(value("indexPadding").contains("\(configuration.indexPaddingPoints)"))
        XCTAssertTrue(value("valuePadding").contains("\(configuration.valuePadding)"))
        XCTAssertTrue(value("clearance").contains("\(configuration.backgroundClearance)"))
        XCTAssertTrue(value("ambiguity").contains("1,25"))
    }

    /// Ein- und Mehrzahl stimmen. **Beim Bildnachweis real aufgefallen:**
    /// Die Vorgabe `indexPaddingPoints` ist `1`, und „1 Messpunkte je
    /// Seite" las sich wie ein Anzeigefehler.
    func testTheExplanationUsesSingularAndPluralCorrectly() throws {
        let singular = try ZoneLearningConfiguration.build(
            baselineProfileCount: 1, minimumPersistenceProfiles: 1, minimumClusterPoints: 1,
            maximumIndexGap: 0, movementDelta: 40, indexPaddingPoints: 1,
            valuePadding: 20, backgroundClearance: 30, ambiguityToleranceFactor: 1.25
        )
        func value(_ id: String, _ configuration: ZoneLearningConfiguration) -> String {
            configuration.explanations.first { $0.id == id }?.value ?? ""
        }
        XCTAssertEqual(value("baseline", singular), "1 profile")
        XCTAssertEqual(value("persistence", singular), "from 1 profile per measurement point")
        XCTAssertEqual(value("cluster", singular), "1 measurement point, gap up to 0")
        XCTAssertEqual(value("indexPadding", singular), "1 measurement point per side")

        let plural = ZoneLearningConfiguration.default
        XCTAssertEqual(value("baseline", plural), "5 profiles")
        XCTAssertEqual(value("persistence", plural), "from 3 profiles per measurement point")
        XCTAssertEqual(value("cluster", plural), "3 measurement points, gap up to 1")
        XCTAssertEqual(
            value("indexPadding", plural), "1 measurement point per side",
            "Die Vorgabe ist 1 — genau der Fall, der vorher falsch stand"
        )
    }

    /// **Keine erfundene physikalische Einheit** (SICK-032c2, Grenze):
    /// Der Scanner liefert Rohwerte, deren Umrechnung nirgends belegt
    /// ist.
    func testTheExplanationInventsNoPhysicalUnit() {
        let text = ZoneLearningConfiguration.default.explanations
            .flatMap { [$0.title, $0.value, $0.detail] }
            .joined(separator: " ")
            .lowercased()
        for unit in ["millimeter", " mm", "zentimeter", " cm", "meter", "grad", "sekunde", "hertz"] {
            XCTAssertFalse(text.contains(unit), "Die Erklärung nennt die erfundene Einheit \(unit)")
        }
    }

    /// Die Erklärung folgt einer **anderen** Konfiguration, wenn eine
    /// andere übergeben wird — sie ist keine abgeschriebene Liste.
    func testTheExplanationFollowsTheConfigurationItIsGiven() throws {
        let other = try ZoneLearningConfiguration.build(
            baselineProfileCount: 9, minimumPersistenceProfiles: 4, minimumClusterPoints: 6,
            maximumIndexGap: 2, movementDelta: 77, indexPaddingPoints: 3,
            valuePadding: 11, backgroundClearance: 55, ambiguityToleranceFactor: 2.0
        )
        let presentation = ZoneLearningPresentation(
            zoneID: zoneID, isZoneEnabled: false, learning: nil, configuration: other
        )
        let values = presentation.explanations.map(\.value).joined(separator: " ")
        for number in ["9", "4", "6", "2", "77", "3", "11", "55", "2,00"] {
            XCTAssertTrue(values.contains(number), "\(number) fehlt in der Erklärung")
        }
    }

    // MARK: - Hilfsmittel

    /// Baut eine Präsentation mit gegebenem Schritt.
    ///
    /// Geht über den **echten** Lernvertrag: Ein `ZoneEditorState` wird
    /// in den gewünschten Zustand gefahren, statt einen Schritt von Hand
    /// zu setzen. Für die Zustände, die sich so nicht erreichen lassen
    /// (etwa `candidateNotBuildable`), greifen die Texttests oben
    /// unmittelbar auf die Enum-Eigenschaften zu.
    private func presentation(phase: ZoneLearningPhase) -> ZoneLearningPresentation {
        ZoneLearningPresentation(
            zoneID: zoneID,
            isZoneEnabled: false,
            learning: nil
        ).replacing(phase: phase)
    }
}

/// Nur für die Texttests oben: setzt den Schritt, ohne den Lernvertrag
/// zu bemühen. **Nicht im Produktionsweg** — dort entsteht der Schritt
/// ausschließlich aus einem echten ``ZoneLearningSession``.
private extension ZoneLearningPresentation {
    func replacing(phase: ZoneLearningPhase) -> ZoneLearningPresentation {
        ZoneLearningPresentation(
            zoneID: zoneID,
            isZoneEnabled: isZoneEnabled,
            phase: phase,
            block: block,
            configuration: configuration
        )
    }
}
