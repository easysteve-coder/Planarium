import Dispatch
import XCTest
@testable import SickPLSCommissioning

/// Der atomare Abbruch-Lebenszyklus (SICK-0330a-1-K2) — **direkt gegen
/// die Primitive**, unabhängig vom Executor.
///
/// Beide Zwei-Seiten-Gegenproben laufen über echte, unterschiedliche
/// Threads (`DispatchQueue.global()`), deren Reihenfolge über echte
/// Semaphoren erzwungen wird — kein `sleep`, keine geratene Zeitspanne,
/// kein tatsächliches Datenrennen (das Ergebnis ist in beiden
/// Reihenfolgen deterministisch dasselbe), aber ein echter, über zwei
/// Kerne laufender Lock-Zugriff (dasselbe Muster wie
/// `CommissioningExecutorTests.testAGenuinelyDifferentThreadCanAbortAPerformThatIsReallyBlockedInARead`).
final class CommissioningAbortTokenTests: XCTestCase {

    // MARK: - Grundvertrag

    func testAFreshTokenHasNoAbortRequestedForItsFirstEdge() {
        let token = CommissioningAbortToken()
        let edge = token.beginRunIfNeeded()
        XCTAssertFalse(token.isAbortRequested)
        XCTAssertFalse(token.consumeIfRequested(for: edge))
    }

    /// **Pflichtnachweis 1 (SICK-0330a-1-K3):** ``requestAbort()`` **ohne
    /// jede vorherige Reservierung** -- also an einem frischen Token, vor
    /// dem allerersten ``beginRunIfNeeded()``-Aufruf -- ist wirkungslos.
    /// Die danach **erstmals** reservierte Kante ist nicht abgebrochen.
    ///
    /// **Das war bis K2 der umgekehrte, fehlerhafte Nachweis:** Ein
    /// frischer Token reservierte von sich aus bereits Generation `0`
    /// ("Phantomkante"), wodurch diese Anforderung fälschlich beobachtet
    /// wurde. Der eigentlich gemeinte Vor-Start-Fall -- eine Anforderung
    /// zwischen dem synchronen, externen Reservieren
    /// (``CommissioningExecutor/beginRun()``) und dem tatsächlichen Start
    /// von `perform` -- steht jetzt als eigener Test daneben:
    /// ``testARequestAfterAnExplicitBeginRunIsStillObservedByTheReusedEdge()``.
    func testARequestBeforeAnyReservationIsWirkungslosAndDoesNotTaintTheFirstEdge() {
        let token = CommissioningAbortToken()

        token.requestAbort()
        XCTAssertFalse(
            token.isAbortRequested,
            "Ohne reservierte Kante gibt es nichts zu beobachten"
        )

        let edge = token.beginRunIfNeeded()

        XCTAssertFalse(
            token.consumeIfRequested(for: edge),
            "Die erstmals reservierte Kante darf die frühere, wirkungslose Anforderung nicht tragen"
        )
    }

    /// **Der tatsächlich gemeinte Vor-Start-Fall:** eine Anforderung, die
    /// **nach** einer echten, externen Reservierung
    /// (``CommissioningExecutor/beginRun()``), aber **vor** dem
    /// tatsächlichen Start von `perform` eintrifft. `beginRunIfNeeded()`
    /// reserviert dort dieselbe, schon bestehende Kante erneut, statt sie
    /// zu ersetzen -- die Anforderung bleibt deshalb erhalten.
    func testARequestAfterAnExplicitBeginRunIsStillObservedByTheReusedEdge() {
        let token = CommissioningAbortToken()

        let reservedEdge = token.beginRunIfNeeded()
        token.requestAbort()
        let reusedEdge = token.beginRunIfNeeded()

        XCTAssertEqual(reservedEdge, reusedEdge, "Dieselbe Kante, kein Ersatz")
        XCTAssertTrue(token.consumeIfRequested(for: reusedEdge))
        XCTAssertFalse(token.consumeIfRequested(for: reusedEdge), "Nur einmal beobachtbar")
    }

    /// **Pflichtnachweis 3:** Mehrere Anforderungen für dieselbe Laufkante
    /// sind idempotent -- nach der ersten Beobachtung ist nichts mehr
    /// übrig, egal wie oft zuvor angefordert wurde.
    func testMultipleRequestsForTheSameEdgeAreIdempotent() {
        let token = CommissioningAbortToken()
        let edge = token.beginRunIfNeeded()

        token.requestAbort()
        token.requestAbort()
        token.requestAbort()

        XCTAssertTrue(token.consumeIfRequested(for: edge))
        XCTAssertFalse(token.consumeIfRequested(for: edge))
    }

    /// **Pflichtnachweis 7:** Ein frischer Folgeaufruf erbt weder eine
    /// Anforderung noch einen Bereinigungszustand des Vorgängers.
    func testAFreshEdgeAfterACompletedRunInheritsNothing() {
        let token = CommissioningAbortToken()
        let firstEdge = token.beginRunIfNeeded()
        token.requestAbort()
        XCTAssertTrue(token.consumeIfRequested(for: firstEdge))
        token.endRun(firstEdge)

        let secondEdge = token.beginRunIfNeeded()

        XCTAssertNotEqual(firstEdge, secondEdge, "Eine neue Generation")
        XCTAssertFalse(token.isAbortRequested)
        XCTAssertFalse(token.consumeIfRequested(for: secondEdge))
    }

    /// Eine veraltete Kante (aus einem bereits beendeten Lauf) löst gar
    /// nichts mehr aus -- weder beim Schließen noch beim Beobachten.
    func testAStaleEdgeChangesNothing() {
        let token = CommissioningAbortToken()
        let firstEdge = token.beginRunIfNeeded()
        token.endRun(firstEdge)
        let secondEdge = token.beginRunIfNeeded()
        token.requestAbort()

        token.endRun(firstEdge)

        XCTAssertTrue(
            token.consumeIfRequested(for: secondEdge),
            "Der veraltete `endRun`-Aufruf hat die echte, aktuelle Anforderung nicht gelöscht"
        )
    }

    // MARK: - Deterministische Zwei-Seiten-Gegenprobe (Pflichtnachweise 4/5)

    /// **Pflichtnachweis 4:** Eine Anforderung, die -- über einen echten,
    /// anderen Thread -- unmittelbar **vor** der atomaren Abschlusskante
    /// eintrifft, gehört höchstens zum endenden Lauf und bleibt danach
    /// nicht stehen: Der Folgelauf sieht nichts davon.
    func testARequestFromAnotherThreadRightBeforeEndRunNeverSurvivesIntoTheNextRun() {
        let token = CommissioningAbortToken()
        let edge = token.beginRunIfNeeded()

        let requestLanded = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            token.requestAbort()
            requestLanded.signal()
        }
        requestLanded.wait()

        // An dieser Stelle ist die Anforderung nachweislich schon
        // angekommen -- die Abschlusskante wird erst jetzt gezogen.
        token.endRun(edge)

        let nextEdge = token.beginRunIfNeeded()
        XCTAssertNotEqual(edge, nextEdge)
        XCTAssertFalse(
            token.consumeIfRequested(for: nextEdge),
            "Die Anforderung des endenden Laufs darf den Folgelauf nicht treffen"
        )
    }

    /// **Pflichtnachweis 5 — die umgekehrte Reihenfolge:** Die
    /// Abschlusskante wird zuerst gezogen; **danach** (über einen echten,
    /// anderen Thread) trifft die Anforderung ein. Auch das hinterlässt
    /// nichts für den nächsten Lauf -- die Anforderung findet keine
    /// reservierte Laufkante mehr vor.
    ///
    /// **Das ist genau die vom Review benannte Lücke der alten,
    /// best-effort-Fassung** (`discardStaleRequest()`, einmaliges Löschen
    /// bei der späteren Main-Thread-Zustellung): Dort blieb eine in dieser
    /// Reihenfolge eintreffende Anforderung bis zur nächsten Zustellung
    /// stehen und konnte den nächsten, gänzlich anderen Lauf vergiften.
    func testARequestFromAnotherThreadRightAfterEndRunAlsoNeverSurvivesIntoTheNextRun() {
        let token = CommissioningAbortToken()
        let edge = token.beginRunIfNeeded()

        token.endRun(edge)

        let requestLanded = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            token.requestAbort()
            requestLanded.signal()
        }
        requestLanded.wait()

        XCTAssertFalse(
            token.isAbortRequested,
            "Keine reservierte Laufkante mehr vorhanden -- die Anforderung ist wirkungslos verpufft"
        )

        let nextEdge = token.beginRunIfNeeded()
        XCTAssertNotEqual(edge, nextEdge)
        XCTAssertFalse(token.consumeIfRequested(for: nextEdge))
    }

    /// **Pflichtnachweis 8 — Gegenprobe gegen die alte, best-effort-
    /// Fassung:** Ein einmaliges Löschen bei später Zustellung (statt der
    /// atomaren Laufkante) hätte in **genau** der Reihenfolge von
    /// Pflichtnachweis 5 die Anforderung bis zur nächsten Zustellung
    /// stehen lassen. Dieser Test bildet jene alte Semantik lokal nach
    /// und zeigt, dass sie an dieser Reihenfolge tatsächlich scheitert --
    /// die neue, oben geprüfte Primitive nicht.
    func testTheOldBestEffortSemanticsWouldHaveLeakedInExactlyThisOrdering() {
        final class OldBestEffortToken {
            private var isRequested = false
            func requestAbort() { isRequested = true }
            func discardStaleRequestAtDelivery() { isRequested = false }
            var isAbortRequestedForWhateverRunComesNext: Bool { isRequested }
        }

        let oldToken = OldBestEffortToken()

        // Ein Lauf endet ("perform kehrt zurück") -- die alte Fassung
        // räumt dabei **nichts** auf, das passiert laut ihrem eigenen
        // Vertrag erst irgendwann später, bei der Berichtszustellung.
        // Bis dahin trifft eine Anforderung auf eine ungeschützte Lücke.
        oldToken.requestAbort()

        // Der nächste, bereits eingeplante Lauf hat zu diesem Zeitpunkt
        // noch gar nicht geprüft -- er sähe die Marke beim ersten Blick.
        XCTAssertTrue(
            oldToken.isAbortRequestedForWhateverRunComesNext,
            "Die alte Semantik lässt die Anforderung bis zur Zustellung offen stehen -- der Beleg für H4"
        )

        // Erst hier, bei der (in diesem Szenario zu spät kommenden)
        // Main-Thread-Zustellung des **vorigen** Berichts, würde
        // aufgeräumt -- nachdem der neue Lauf sie längst hätte sehen
        // können.
        oldToken.discardStaleRequestAtDelivery()
    }
}
