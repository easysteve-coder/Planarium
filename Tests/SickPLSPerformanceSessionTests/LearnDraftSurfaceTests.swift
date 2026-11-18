import PlanariumInput
import XCTest
import SickPLSControlCore
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// SICK-032c3b-K1, Abnahmeblocker 1: ``LearnDraftSurface`` ist der **eine**
/// testbare Darstellungsvertrag, der entscheidet, ob ein
/// ``ZoneLearningNotice`` in die Draftkarte oder in einen Fallback-Host
/// gehört -- unabhängig davon, wie die Oberfläche ihn am Ende zeichnet.
///
/// Reine Wertetests ohne Ansicht, ohne Koordinator, ohne Gerät und ohne
/// Scanner -- die produktive Zusammensetzung aus
/// ``ScannerWorkspaceModel/learnDraftSurface`` prüft
/// `CoordinatorLearnDraftSurfaceTests` am echten Weg.
@MainActor final class LearnDraftSurfaceTests: XCTestCase {

    private func presentation() -> LearnDraftPresentation {
        LearnDraftPresentation(role: .pitch, state: .arming, focusArea: nil)
    }

    private func notice(isSuccess: Bool = true) -> ZoneLearningNotice {
        ZoneLearningNotice("irgendein Text", isSuccess: isSuccess)
    }

    // MARK: - Ohne Draft: der Hinweis geht in den Fallback-Host

    func testWithoutADraftANoticeIsHostedNotInTheCard() {
        let surface = LearnDraftSurface(presentation: nil, notice: notice(isSuccess: false))

        XCTAssertNil(surface.presentation)
        XCTAssertNil(surface.cardNotice, "Es gibt keine Karte, die ihn zeigen könnte")
        XCTAssertEqual(surface.hostedNotice, notice(isSuccess: false))
    }

    func testWithoutADraftAndWithoutANoticeBothSlotsAreEmpty() {
        let surface = LearnDraftSurface(presentation: nil, notice: nil)

        XCTAssertNil(surface.cardNotice)
        XCTAssertNil(surface.hostedNotice)
    }

    // MARK: - Mit Draft: der Hinweis geht in die Karte, nie in den Host

    func testWithADraftANoticeIsInTheCardNotInTheHost() {
        let surface = LearnDraftSurface(presentation: presentation(), notice: notice(isSuccess: true))

        XCTAssertNotNil(surface.presentation)
        XCTAssertEqual(surface.cardNotice, notice(isSuccess: true))
        XCTAssertNil(surface.hostedNotice, "Mit bestehendem Draft bleibt der Fallback-Host leer")
    }

    func testWithADraftAndWithoutANoticeBothSlotsAreEmpty() {
        let surface = LearnDraftSurface(presentation: presentation(), notice: nil)

        XCTAssertNil(surface.cardNotice)
        XCTAssertNil(surface.hostedNotice)
    }

    // MARK: - Strukturelle Exklusivität (Pflichtnachweis 1, dritter Fall)

    /// Für jede Kombination gilt: Höchstens einer der beiden Slots trägt
    /// den Hinweis, nie beide -- die Ansicht kann ihn damit nicht doppelt
    /// zeigen, egal wie sie beide Werte liest.
    func testTheTwoSlotsAreMutuallyExclusiveForEveryCombination() {
        for hasDraft in [false, true] {
            for hasNotice in [false, true] {
                let surface = LearnDraftSurface(
                    presentation: hasDraft ? presentation() : nil,
                    notice: hasNotice ? notice() : nil
                )
                XCTAssertTrue(
                    surface.cardNotice == nil || surface.hostedNotice == nil,
                    "hasDraft=\(hasDraft) hasNotice=\(hasNotice): beide Slots dürfen nie gleichzeitig gefüllt sein"
                )
                if hasNotice {
                    XCTAssertTrue(
                        surface.cardNotice != nil || surface.hostedNotice != nil,
                        "hasDraft=\(hasDraft): ein vorhandener Hinweis darf nie spurlos verschwinden"
                    )
                } else {
                    XCTAssertNil(surface.cardNotice)
                    XCTAssertNil(surface.hostedNotice)
                }
            }
        }
    }

    // MARK: - Equatable spiegelt beide Bestandteile

    func testEqualityComparesBothPresentationAndNotice() {
        XCTAssertEqual(
            LearnDraftSurface(presentation: nil, notice: notice()),
            LearnDraftSurface(presentation: nil, notice: notice())
        )
        XCTAssertNotEqual(
            LearnDraftSurface(presentation: nil, notice: notice(isSuccess: true)),
            LearnDraftSurface(presentation: nil, notice: notice(isSuccess: false))
        )
        XCTAssertNotEqual(
            LearnDraftSurface(presentation: nil, notice: nil),
            LearnDraftSurface(presentation: presentation(), notice: nil)
        )
    }
}
