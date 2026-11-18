import Foundation
import SickPLSActiveControl
import SickPLSMacTransport
import XCTest
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl

/// Eine injizierte monotone Uhr. **Keine Systemzeit, kein `sleep`.**
final class TestMonotonicClock: MonotonicClock {
    private var millis: Int64 = 0
    func nowMilliseconds() -> Int64 { millis }
    func advance(by delta: Int64) { millis += delta }
}

/// Ein Transport, der **nichts** antwortet und die injizierte Uhr um die
/// verlangte Frist vorstellt.
///
/// Er modelliert die Grenze richtig: Ein Leseaufruf, der Zeit
/// beansprucht, ohne dass Zeit vergeht, ist kein Modell (Lehre aus
/// SICK-031a). **Es wird kein echter Port geöffnet und kein Byte
/// gesendet** — alles bleibt im Speicher.
final class SilentFakeTransport: CommissioningTransport {
    let clock: TestMonotonicClock
    private(set) var openedRates: [SerialPortBaudRate] = []
    private(set) var closeCount = 0
    private(set) var flushCount = 0
    private(set) var writeCount = 0
    private var isOpen = false

    init(clock: TestMonotonicClock) {
        self.clock = clock
    }

    func openPort(baudRate: SerialPortBaudRate) throws {
        guard !isOpen else { throw CommissioningTransportError.portAlreadyOpen }
        isOpen = true
        openedRates.append(baudRate)
    }

    func closePort() throws {
        if isOpen { closeCount += 1 }
        isOpen = false
    }

    func flushReceiveBuffer() {
        flushCount += 1
    }

    func write(_ bytes: [UInt8]) throws {
        guard isOpen else { throw CommissioningTransportError.portNotOpen }
        writeCount += 1
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        clock.advance(by: Int64(max(timeoutMilliseconds, 1)))
        return .timeout
    }
}

/// Stellt einen **echten** ``CommissioningExecutor`` über den stillen
/// Fake-Transport bereit.
final class RealExecutorProvider: CommissioningRunProviding {
    let clock = TestMonotonicClock()
    private(set) var transport: SilentFakeTransport?
    /// Der zuletzt hergestellte **echte** Executor — für Nachweise, die
    /// von außen ``CommissioningExecutor/requestAbort()`` auf genau
    /// diesem Lauf auslösen müssen (SICK-0330a-1-K1).
    private(set) var executor: CommissioningExecutor?

    func makeRun(portPath: String) throws -> CommissioningRunning & CommissioningAborting {
        let transport = SilentFakeTransport(clock: clock)
        self.transport = transport
        let executor = CommissioningExecutor(transport: transport, recipe: .r26, clock: clock)
        self.executor = executor
        return executor
    }
}

/// Der Nachweis, dass die Bedienung an einem **wirklichen** Lauf hängt
/// und nicht an nachgebauten Berichten (SICK-032a).
///
/// **Kein echter Port, kein TX, keine Hardware, keine PTY.** Der
/// Transport ist ein Fake; echt sind Reducer, Executor, Telegrammbau,
/// Fristen und der ganze Berichtsweg.
final class CommissioningRealRunTests: XCTestCase {

    private func makeModel() -> (CommissioningControlModel, SpyPortCoordinator, RealExecutorProvider, ManualCommissioningDispatcher) {
        let coordinator = SpyPortCoordinator()
        let provider = RealExecutorProvider()
        let dispatcher = ManualCommissioningDispatcher()
        let model = CommissioningControlModel(
            coordinator: coordinator,
            runProvider: provider,
            dispatcher: dispatcher,
            portListing: FakeSerialPortListing()
        )
        model.selectPort("/dev/cu.usbserial-TEST")
        return (model, coordinator, provider, dispatcher)
    }

    /// Ein stummes Gerät bei der Ausgangsrate ergibt einen **echten**
    /// Fehlschlagsbericht — und der schließt den Lauf genau einmal ab.
    func testASilentDeviceProducesARealFailureReportAndReleasesOnce() throws {
        let (model, coordinator, provider, dispatcher) = makeModel()
        model.requestAccess()
        model.requestStep(.checkStartingRate)
        XCTAssertEqual(model.confirmPendingStep(), .started(.checkStartingRate))
        dispatcher.runToCompletion()

        XCTAssertEqual(model.phase, .failed(.noDeviceAtStartingRate(.timeout)))
        XCTAssertNil(model.verifiedBaudRate, "Ohne Beleg gibt es keine Rate")
        XCTAssertEqual(coordinator.completionReports.count, 1)
        XCTAssertEqual(model.releasedRunCount, 1)

        // Der Ablauf hat wirklich bei der Ausgangsrate geöffnet, genau
        // einmal gesendet und den Empfangspuffer **vorher** geleert.
        let transport = try XCTUnwrap(provider.transport)
        XCTAssertEqual(transport.openedRates, [.baud9600])
        XCTAssertEqual(transport.writeCount, 1)
        XCTAssertEqual(transport.flushCount, 1)
    }

    /// Das Protokoll stammt aus dem echten Lauf — eine benannte
    /// Handlung, **ohne Bytes**.
    func testTheAuditShownComesFromTheRealRun() {
        let (model, _, _, dispatcher) = makeModel()
        model.requestAccess()
        model.requestStep(.checkStartingRate)
        model.confirmPendingStep()
        dispatcher.runToCompletion()

        XCTAssertEqual(model.auditEntries.count, 1)
        XCTAssertEqual(model.auditEntries.first?.action, .identityCheck(.baud9600))
        XCTAssertEqual(model.auditEntries.first?.outcome, .timedOut)
        XCTAssertEqual(model.auditEntries.first?.attemptNumber, 1)
    }

    /// **Die Ratendiagnose ist von hier aus erreichbar** und sendet je
    /// Rate genau eine harmlose Probe — auf einer Verbindung, die
    /// wirklich so geöffnet wurde (SICK-030a3).
    func testTheRateDiagnosticsRunForRealAfterAFailure() throws {
        let (model, _, provider, dispatcher) = makeModel()
        model.requestAccess()
        model.requestStep(.checkStartingRate)
        model.confirmPendingStep()
        dispatcher.runToCompletion()
        XCTAssertEqual(model.allowedSteps, [.runRateDiagnostics, .finishSession])

        model.requestAccess()
        model.requestStep(.runRateDiagnostics)
        XCTAssertEqual(model.confirmPendingStep(), .started(.runRateDiagnostics))
        dispatcher.runToCompletion()

        let transport = try XCTUnwrap(provider.transport)
        XCTAssertEqual(
            transport.openedRates,
            [.baud9600, .baud9600, .baud38400],
            "Zwischen den Proben muss wirklich geschlossen und neu geöffnet werden"
        )
        XCTAssertEqual(transport.writeCount, 3, "Ausgangsprüfung plus je Rate genau eine Probe")
        XCTAssertNil(model.verifiedBaudRate, "Eine Diagnose belegt keine Rate")
        guard case .diagnosticsFinished = model.phase else {
            return XCTFail("Unerwartete Phase: \(String(describing: model.phase))")
        }
    }

    /// **Der Abschluss kommt nie aus dem Executor selbst.**
    ///
    /// `CommissioningExecutor.report` ist bei `.idle` `isFinal` — ein
    /// Abschluss daraus gäbe den Port frei, ohne dass je ein Lauf
    /// stattfand (Review-Befund N2). Hier wird belegt, dass es genau
    /// diesen Wert gibt und die Bedienung ihn trotzdem nie benutzt.
    func testTheNeverStartedExecutorsReportWouldBeFinalButIsNeverUsed() throws {
        let provider = RealExecutorProvider()
        let executor = try provider.makeRun(portPath: "/dev/cu.usbserial-TEST")
        let raw = try XCTUnwrap(executor as? CommissioningExecutor)
        XCTAssertEqual(raw.report.phase, .idle)
        XCTAssertEqual(raw.report.isFinal, true, "Die Falle existiert wirklich")

        let (model, coordinator, _, _) = makeModel()
        model.requestAccess()
        model.refreshReadiness()
        XCTAssertEqual(coordinator.completionReports.count, 0, "Ohne Lauf wird nie abgeschlossen")
        XCTAssertEqual(model.releasedRunCount, 0)
    }

    /// **PN6 (SICK-0330a-1-K1, H4):** Zwei Abbruchanforderungen für
    /// **denselben** noch nicht abgearbeiteten Lauf ergeben -- am echten
    /// Executor -- **genau einen** Reducer-Abbruch (die Marke ist
    /// idempotent, Pflichtnachweis am `CommissioningAbortToken`), und der
    /// danach angebotene, unabhängige Folgeschritt läuft **unvergiftet**
    /// mit echter Gerätewirkung durch, statt selbst sofort abzubrechen.
    func testTwoAbortRequestsForTheSameRunYieldExactlyOneReducerAbortAndDoNotPoisonTheNextStep() throws {
        let (model, _, provider, dispatcher) = makeModel()
        model.requestAccess()
        model.requestStep(.checkStartingRate)
        XCTAssertEqual(model.confirmPendingStep(), .started(.checkStartingRate))

        // Der Lauf liegt in der seriellen Warteschlange, aber noch nicht
        // abgearbeitet -- genau die Lage, in der zwei Mal „Abbrechen"
        // getippt werden könnte.
        XCTAssertEqual(model.performStep(.abort), .started(.abort))
        XCTAssertEqual(model.performStep(.abort), .started(.abort))

        dispatcher.runToCompletion()

        XCTAssertEqual(model.phase, .failed(.abortedByOperator))
        let transport = try XCTUnwrap(provider.transport)
        XCTAssertLessThanOrEqual(
            transport.writeCount, 1,
            "Höchstens die eine Identitätsprobe vor dem beobachteten Abbruch -- kein zweiter Abbruchlauf"
        )

        // Der nächste, unabhängige Schritt darf nicht vergiftet sein.
        // (Ein Fehlschlag gibt den Portbesitz frei -- vor dem nächsten
        // Schritt braucht es deshalb erneut ausdrücklichen Zugang, genau
        // wie bei jedem anderen Fehlschlag auch.)
        model.requestAccess()
        XCTAssertTrue(model.allowedSteps.contains(.runRateDiagnostics))
        model.requestStep(.runRateDiagnostics)
        XCTAssertEqual(model.confirmPendingStep(), .started(.runRateDiagnostics))
        dispatcher.runToCompletion()

        guard case .diagnosticsFinished = model.phase else {
            return XCTFail("Der Folgeschritt lief nicht regulär durch, sondern: \(String(describing: model.phase))")
        }
        XCTAssertGreaterThan(
            transport.writeCount, 1,
            "Der Folgeschritt sendet wirklich -- kein vergifteter Sofortabbruch"
        )
    }

    /// **PN6 (SICK-0330a-1-K2) — der Nachweis hängt nicht an der
    /// Main-Thread-Zustellung:** Ein Abbruch, der zwischen dem
    /// tatsächlichen Rückkehren von `perform` und der Zustellung des
    /// Berichts auf dem Main Thread eintrifft, betrifft **keinen**
    /// späteren Lauf -- und zwar bereits in dem Moment, in dem `perform`
    /// zurückkehrt, nicht erst, wenn die Zustellung irgendwann
    /// nachträglich aufräumt. Über den manuellen Dispatcher
    /// deterministisch nachgestellt -- keine geratene Zeitspanne, kein
    /// `sleep`, kein Rennen.
    ///
    /// **Der Unterschied zu SICK-0330a-1-K1 ist der ganze Punkt:** Vorher
    /// stand die Marke bis zur späteren Zustellung sichtbar an
    /// (`isAbortRequested == true`) und wurde dort erst gelöscht. Jetzt
    /// ist die Laufkante bereits beim Rückkehren von `perform` selbst
    /// geschlossen (``CommissioningAbortToken/endRun(_:)``, innerhalb von
    /// `perform` über `defer`) -- eine Anforderung in der Lücke findet
    /// **von Anfang an** keine reservierte Laufkante mehr vor und wird
    /// nie überhaupt gesetzt.
    func testAnAbortInTheSchedulingGapAfterPerformReturnsButBeforeMainThreadDeliveryPoisonsNoLaterRun() throws {
        let (model, _, provider, dispatcher) = makeModel()
        model.requestAccess()
        model.requestStep(.checkStartingRate)
        XCTAssertEqual(model.confirmPendingStep(), .started(.checkStartingRate))

        // `perform` läuft wirklich (stiller Transport, Fristablauf) und
        // legt seinen Bericht in die Zustellungs-Warteschlange -- ohne
        // dass je ein Abbruch stand.
        XCTAssertTrue(dispatcher.runNextBackground())
        XCTAssertTrue(model.isRunning, "Vorbedingung: noch nicht zugestellt")

        // Genau die Lücke: der Hintergrundaufruf ist bereits
        // zurückgekehrt (und hat damit seine Laufkante über `endRun`
        // schon geschlossen), der Bericht liegt noch nicht auf dem Main
        // Thread -- ein hier eintreffender Abbruch findet keine
        // reservierte Laufkante mehr vor.
        let executor = try XCTUnwrap(provider.executor)
        executor.requestAbort()
        XCTAssertFalse(
            executor.abortToken.isAbortRequested,
            "Die Anforderung heftet sich an keine reservierte Laufkante mehr -- sie verpufft sofort"
        )

        XCTAssertTrue(dispatcher.deliverNextMain())

        XCTAssertFalse(executor.abortToken.isAbortRequested)
        XCTAssertEqual(
            model.phase, .failed(.noDeviceAtStartingRate(.timeout)),
            "Der erste Lauf war ohnehin nie abgebrochen -- die Marke kam zu spät für ihn"
        )

        // Ein frischer, unabhängiger Folgelauf -- unbeeinflusst von der
        // wirkungslos verpufften Anforderung. (Ein Fehlschlag gibt den
        // Portbesitz frei -- erneuter Zugang ist der reguläre nächste
        // Handgriff.)
        model.requestAccess()
        model.requestStep(.runRateDiagnostics)
        XCTAssertEqual(model.confirmPendingStep(), .started(.runRateDiagnostics))
        dispatcher.runToCompletion()

        guard case .diagnosticsFinished = model.phase else {
            return XCTFail(
                "Der Folgelauf wurde von der liegen gebliebenen Marke getroffen: \(String(describing: model.phase))"
            )
        }
    }

    /// **PN7 (SICK-0330a-1-K2), zusätzlich direkt am Modell für den
    /// unmittelbar nächsten Schritt (nicht erst nach einem Umweg über die
    /// Ratendiagnose):** Ein frischer Folgeaufruf nach einer bereits
    /// verpufften, veralteten Anforderung führt seine reguläre
    /// Gerätewirkung aus und endet **nicht** `.abortedByOperator` --
    /// derselbe erlaubte Folgeschritt wie in
    /// ``testTwoAbortRequestsForTheSameRunYieldExactlyOneReducerAbortAndDoNotPoisonTheNextStep``,
    /// hier aber mit der Anforderung exakt in der Main-Thread-Zustellungs-
    /// Lücke statt während des laufenden Reads.
    func testAFreshRunAfterAStaleAbortRunsItsOwnRegularDeviceEffectInstead() throws {
        let (model, _, provider, dispatcher) = makeModel()
        model.requestAccess()
        model.requestStep(.checkStartingRate)
        XCTAssertEqual(model.confirmPendingStep(), .started(.checkStartingRate))
        XCTAssertTrue(dispatcher.runNextBackground())

        let executor = try XCTUnwrap(provider.executor)
        executor.requestAbort()
        XCTAssertTrue(dispatcher.deliverNextMain())
        XCTAssertEqual(model.phase, .failed(.noDeviceAtStartingRate(.timeout)))

        model.requestAccess()
        model.requestStep(.runRateDiagnostics)
        XCTAssertEqual(model.confirmPendingStep(), .started(.runRateDiagnostics))
        dispatcher.runToCompletion()

        guard case .diagnosticsFinished = model.phase else {
            return XCTFail(
                "Regulär am stillen Gerät durchgelaufen erwartet, nie am Abbruch: \(String(describing: model.phase))"
            )
        }
        let transport = try XCTUnwrap(provider.transport)
        XCTAssertGreaterThan(transport.writeCount, 1, "Beide Läufe haben wirklich gesendet")
    }
}
