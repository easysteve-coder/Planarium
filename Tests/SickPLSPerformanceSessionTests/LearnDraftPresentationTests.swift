import PlanariumInput
import XCTest
import SickPLSControlCore
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// SICK-032c3a-K1: der neue Sperrgrund (``LearnDraftBlock``) von
/// ``LearnDraftPresentation`` -- eine sammelnde, bereits vorhandene Zone
/// sperrt den (Neu-)Start eines Entwurfs, genau spiegelbildlich zu
/// ``ZoneLearningPresentation``s ``ZoneLearningBlock/learnDraftIsCollecting``.
///
/// Reine Texttests ohne Ansicht, ohne Gerät, ohne Scanner und ohne Uhr.
@MainActor final class LearnDraftPresentationTests: XCTestCase {

    private let zoneID = EditableZone.ID()

    private func presentation(
        state: ZoneLearningState = .arming, block: LearnDraftBlock? = nil
    ) -> LearnDraftPresentation {
        LearnDraftPresentation(role: .pitch, state: state, block: block, focusArea: nil)
    }

    /// Ohne Sperrgrund lässt sich ein beendeter Entwurf neu starten --
    /// unverändertes Verhalten aus SICK-032c3a.
    func testWithoutABlockAFinishedDraftCanBeRestarted() {
        let shown = presentation(state: .refused(.baselineIncomplete(seen: 0, required: 3)))
        XCTAssertNil(shown.block)
        XCTAssertNil(shown.blockMessage)
        XCTAssertTrue(shown.canStart)
    }

    /// **Der neue Fall (K1):** Eine sammelnde, bereits vorhandene Zone
    /// sperrt den (Neu-)Start eines bereits beendeten Entwurfs -- sein
    /// Ergebnis bleibt trotzdem lesbar.
    func testACollectingZoneLearningSessionBlocksRestartButLeavesTheResultReadable() {
        let candidate = try! Zone.build(
            indexLowerBound: 0.2, indexUpperBound: 0.4,
            valueLowerBound: 300, valueUpperBound: 900, role: .pitch
        )
        let shown = presentation(
            state: .candidate(candidate), block: .zoneLearningIsCollecting(zoneID: zoneID)
        )
        XCTAssertEqual(shown.block, .zoneLearningIsCollecting(zoneID: zoneID))
        XCTAssertEqual(
            shown.blockMessage,
            "A learning process is running on a zone. Finish or cancel it first."
        )
        XCTAssertFalse(shown.canStart)
        XCTAssertEqual(shown.candidateBoundsLabel, ZoneBoundsText.label(for: candidate), "Der Vorschlag bleibt lesbar")
        XCTAssertTrue(shown.canApply, "Übernehmen kennt keine D2-Bedingung und ist von der Sperre unberührt")
    }

    /// Ein noch **sammelnder** Entwurf ist über `phase.isCollecting`
    /// bereits gesperrt -- ``block`` muss dafür nicht gesetzt sein
    /// (spiegelt die produktive Ableitung im Koordinator, die `block`
    /// nur aus der jeweils **anderen** Zone berechnet).
    func testACollectingDraftIsAlreadyBlockedByItsOwnPhaseWithoutAnExplicitBlock() {
        let shown = presentation(state: .collectingBaseline(profilesSeen: 1, required: 3), block: nil)
        XCTAssertNil(shown.block)
        XCTAssertFalse(shown.canStart, "Der Schritt selbst sammelt bereits")
    }
}
