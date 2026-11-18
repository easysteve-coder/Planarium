import PlanariumInput
import XCTest
import SickPLSControlCore
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// **Pflichtnachweis 2** aus `.agent_handoff/task-sick-032c3b.md`:
/// erschöpfende Abdeckung aller Zustände der Learn-Karte mit den
/// jeweils richtigen Bedienhandlungen.
///
/// `ZoneLearningPhase` kennt sieben von einem Entwurf tatsächlich
/// erreichbare Fälle (``ZoneLearningPhase/idle`` entsteht für einen
/// Entwurf strukturell nie, siehe ``LearnDraftPresentation/stepTitle``-
/// Kommentar): Warten, Grundprofil, Bewegung, Vorschlag und die drei
/// gebündelten Endlagen Verweigerung/Abbruch/Fehlschlag, insgesamt
/// dreizehn benannte Werte (5 Verweigerungsgründe, 5 Abbruchgründe,
/// 2 Fehlschlagsgründe). Für **jeden** wird hier geprüft, dass genau die
/// richtige Kombination aus `canStart`/`canFinish`/`canCancel`/
/// `canApply`/`canDiscard` erscheint — nie eine Handlung, die für diesen
/// Zustand nichts bewirken würde oder fehlt.
@MainActor final class LearnDraftPresentationExhaustiveTests: XCTestCase {

    private let zone = try! Zone.build(
        indexLowerBound: 0.1, indexUpperBound: 0.5, valueLowerBound: 200, valueUpperBound: 900, role: .pitch
    )

    private func presentation(_ state: ZoneLearningState) -> LearnDraftPresentation {
        LearnDraftPresentation(role: .pitch, state: state, block: nil, focusArea: nil)
    }

    private struct Expected {
        let canStart: Bool
        let canFinish: Bool
        let canCancel: Bool
        let canApply: Bool
        let canDiscard: Bool
    }

    private func assertActions(
        _ shown: LearnDraftPresentation, _ expected: Expected, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(shown.canStart, expected.canStart, "canStart", file: file, line: line)
        XCTAssertEqual(shown.canFinish, expected.canFinish, "canFinish", file: file, line: line)
        XCTAssertEqual(shown.canCancel, expected.canCancel, "canCancel", file: file, line: line)
        XCTAssertEqual(shown.canApply, expected.canApply, "canApply", file: file, line: line)
        XCTAssertEqual(shown.canDiscard, expected.canDiscard, "canDiscard", file: file, line: line)
    }

    // MARK: - Sammelnde Schritte: nur Beenden und Abbrechen ergeben Sinn

    private let collecting = Expected(
        canStart: false, canFinish: true, canCancel: true, canApply: false, canDiscard: false
    )

    func testWaitingForProfilesOffersOnlyFinishAndCancel() {
        assertActions(presentation(.arming), collecting)
        XCTAssertEqual(presentation(.arming).progressLabel, "Waiting for measurements")
        XCTAssertNil(presentation(.arming).candidateBoundsLabel)
    }

    func testCollectingBaselineOffersOnlyFinishAndCancel() {
        assertActions(presentation(.collectingBaseline(profilesSeen: 2, required: 5)), collecting)
    }

    func testCollectingMovementOffersOnlyFinishAndCancel() {
        assertActions(
            presentation(.collectingMovement(profilesSeen: 6, changedIndexCount: 3, persistentIndexCount: 3)),
            collecting
        )
    }

    // MARK: - Vorschlag: Übernehmen oder Verwerfen, kein (Neu-)Start nötig

    func testCandidateOffersApplyDiscardAndAllowsARestart() {
        let shown = presentation(.candidate(zone))
        assertActions(
            shown,
            Expected(canStart: true, canFinish: false, canCancel: false, canApply: true, canDiscard: true)
        )
        XCTAssertEqual(shown.candidateBoundsLabel, ZoneBoundsText.label(for: zone))
    }

    // MARK: - Drei Endlagen ohne Vorschlag: nur (Neu-)Start oder Wegräumen

    private let terminalWithoutCandidate = Expected(
        canStart: true, canFinish: false, canCancel: false, canApply: false, canDiscard: true
    )

    func testEveryRefusalReasonOffersOnlyRestartAndDiscard() {
        let refusals: [ZoneLearningRefusal] = [
            .baselineIncomplete(seen: 1, required: 5),
            .insufficientMotion(largestClusterPoints: 1, required: 4),
            .ambiguousCandidates(strongestHits: 4, runnerUpHits: 4),
            .backgroundInsideZone,
            .candidateNotBuildable
        ]
        for refusal in refusals {
            let shown = presentation(.refused(refusal))
            assertActions(shown, terminalWithoutCandidate)
            XCTAssertNil(shown.candidateBoundsLabel)
            XCTAssertFalse(shown.instruction.isEmpty)
        }
    }

    func testEveryCancellationReasonOffersOnlyRestartAndDiscard() {
        let reasons: [ZoneLearningCancellation] = [
            .operatorCancelled, .zoneRemoved, .zoneRoleChanged, .zoneActivationChanged, .disconnected
        ]
        for reason in reasons {
            let shown = presentation(.cancelled(reason))
            assertActions(shown, terminalWithoutCandidate)
            XCTAssertNil(shown.candidateBoundsLabel)
            XCTAssertFalse(shown.instruction.isEmpty)
        }
    }

    /// Die beiden Abbruchgründe, die für einen Entwurf tatsächlich
    /// entstehen (kein „Zone entfernt"/„Rolle geändert"/„Ein-/
    /// Ausschalten" — die gehören zum Lernen einer bereits vorhandenen
    /// Zone), bekommen ihren **eigenen** Wortlaut statt des geteilten
    /// Zonentexts.
    func testTheTwoReachableCancellationReasonsHaveTheirOwnDraftWording() {
        XCTAssertEqual(
            presentation(.cancelled(.operatorCancelled)).instruction,
            "The draft was cancelled. No zone was created."
        )
        XCTAssertEqual(
            presentation(.cancelled(.disconnected)).instruction,
            "The scanner connection ended. Without real measurements, learning cannot continue."
        )
    }

    func testEveryFailureReasonOffersOnlyRestartAndDiscard() {
        let failures: [ZoneLearningFailure] = [
            .pointCountChanged(expected: 90, received: 45), .emptyProfile
        ]
        for failure in failures {
            let shown = presentation(.failed(failure))
            assertActions(shown, terminalWithoutCandidate)
            XCTAssertNil(shown.candidateBoundsLabel)
            XCTAssertFalse(shown.instruction.isEmpty)
        }
    }

    // MARK: - Der Sperrgrund überschreibt nur canStart, nie die übrigen Handlungen

    func testABlockDisablesOnlyStartAndLeavesEveryOtherActionAsPhaseDictates() {
        let block = LearnDraftBlock.zoneLearningIsCollecting(zoneID: EditableZone.ID())

        let onCandidate = LearnDraftPresentation(role: .pitch, state: .candidate(zone), block: block, focusArea: nil)
        XCTAssertFalse(onCandidate.canStart)
        XCTAssertTrue(onCandidate.canApply, "Übernehmen bleibt möglich -- der Sperrgrund betrifft nur den Start")
        XCTAssertTrue(onCandidate.canDiscard)

        let onRefusal = LearnDraftPresentation(
            role: .pitch, state: .refused(.candidateNotBuildable), block: block, focusArea: nil
        )
        XCTAssertFalse(onRefusal.canStart)
        XCTAssertTrue(onRefusal.canDiscard)
    }
}
