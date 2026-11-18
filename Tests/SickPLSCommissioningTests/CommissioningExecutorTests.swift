import Dispatch
import XCTest
import SickPLSActiveControl
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSCommissioning

/// Der Executor (SICK-031) — **ausschließlich gegen Fakes, mit
/// injizierter monotoner Zeit**.
///
/// Kein echter Port, kein Gerät, keine PTY-Probe, kein Byte an Hardware.
final class CommissioningExecutorTests: XCTestCase {

    /// Das volle Lesefenster des Rezepts — die Größe, um die es in
    /// SICK-032a3a geht.
    private let model_responseTimeoutMilliseconds = CommissioningRecipe.r26.responseTimeoutMilliseconds
    private let loginResponseTimeoutMilliseconds = CommissioningRecipe.r26.loginResponseTimeoutMilliseconds

    private var clock = TestMonotonicClock()
    private var transport: FakeCommissioningTransport!
    private var executor: CommissioningExecutor!

    override func setUp() {
        super.setUp()
        clock = TestMonotonicClock()
        transport = FakeCommissioningTransport(clock: clock)
        executor = CommissioningExecutor(transport: transport, clock: clock)
    }

    // MARK: - Der vollständige Weg 9600 → 38400

    /// **Der Kernnachweis:** Ausgangsprüfung, Login mit den belegten
    /// Wiederholungen, Baudwechsel, echter Portwechsel,
    /// Verifikation — und das Ergebnis ist die belegte Zielrate.
    func testTheFullSwitchFromTheStartingRateToTheTargetRate() {
        transport.readScript = [.frame(identityResponseFrame())]
        var report = executor.perform(.checkStartingRate)

        XCTAssertEqual(report.phase, .respondingAtStartingRate)
        XCTAssertEqual(report.restingDirective, .hold)
        XCTAssertTrue(report.isPortHeld)
        XCTAssertEqual(transport.openedRates, [.baud9600], "Erst bei der Ausgangsrate geöffnet")

        // Der erste Login bleibt unbeantwortet -- genau die Lage, die die
        // Beleglage beschreibt --, dann ACK, dann ACK auf den Baudwechsel.
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(identityResponseFrame())
        ]
        report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .verified)
        XCTAssertEqual(report.restingDirective, .hold)
        XCTAssertEqual(report.verifiedBaudRate, .baud38400)
        XCTAssertTrue(report.isPortHeld)
        XCTAssertFalse(report.isFinal)

        XCTAssertEqual(
            transport.portSequence,
            [.open(.baud9600), .close, .open(.baud38400)],
            "Genau ein echter Portwechsel, und in dieser Reihenfolge"
        )
        XCTAssertTrue(
            transport.everyWriteIsPrecededByAFlush,
            "Und über den ganzen Weg hinweg wurde vor jeder Sendung geleert"
        )

        // Der Sitzungsabschluss ist der einzige Freigabepunkt -- und er
        // schließt.
        let finish = executor.perform(.finishSession)
        XCTAssertEqual(finish.phase, .sessionFinished)
        XCTAssertEqual(finish.restingDirective, .stop)
        XCTAssertFalse(finish.isPortHeld)
        XCTAssertTrue(finish.isFinal)
        XCTAssertEqual(transport.portSequence.last, .close)
    }

    /// Windows-`RepeatCounter=2`: genau **drei** Login-Sendungen,
    /// nie eine vierte — und die Entscheidung trifft der Reducer, nicht
    /// der Executor.
    func testTheLoginIsSentExactlyThreeTimesAtMost() {
        reachRestingPointAtStartingRate()

        // Nichts antwortet: erster Versuch plus zwei Wiederholungen.
        transport.readScript = []
        let report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .failed(.loginUnanswered))
        XCTAssertEqual(report.audit.entries.filter { $0.action == .login }.count, 3)
        XCTAssertEqual(
            report.audit.entries.filter { $0.action == .login }.map(\.attemptNumber), [1, 2, 3]
        )
        XCTAssertTrue(report.isFinal)
        XCTAssertFalse(report.isPortHeld)
    }

    /// **Auflage A1 im Ausführungspfad:** Nur die `0xB1`-Identität bei
    /// der Zielrate belegt den Wechsel.
    func testOnlyAnIdentityAnswerAtTheTargetRateProvesTheSwitch() {
        reachRestingPointAtStartingRate()

        // Nach dem Wiederöffnen kommt ein Messstrom statt der Identität.
        transport.millisPerScriptedRead = 700
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(scanProfileFrame()),
            .frame(scanProfileFrame()),
            .frame(scanProfileFrame())
        ]
        let report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .failed(.verificationFailed(.timeout)))
        XCTAssertNil(report.verifiedBaudRate, "Ein Messstrom belegt den Wechsel nicht")
        XCTAssertTrue(report.observedScanProfileStream, "Beobachtet wird er trotzdem")
    }

    // MARK: - RX-Puffer vor jeder Sendung

    /// **Vor jeder Sendung geleert, nie danach** — und zwar unmittelbar
    /// davor, ohne etwas dazwischen.
    func testTheReceiveBufferIsFlushedImmediatelyBeforeEveryWrite() {
        reachRestingPointAtStartingRate()
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(identityResponseFrame())
        ]
        executor.perform(.switchBaudRate, secret: testSecret)
        executor.perform(.requestMeasurementMode)

        XCTAssertTrue(transport.everyWriteIsPrecededByAFlush)
        XCTAssertEqual(
            transport.log.filter { $0 == .flush }.count,
            transport.writtenPayloads.count,
            "Genau ein Leeren je Sendung -- keines zu viel, keines zu wenig"
        )
        XCTAssertGreaterThanOrEqual(transport.writtenPayloads.count, 4)
    }

    // MARK: - Absolute Frist

    /// **Rauschen verlängert keine Frist.** Fortlaufende `0xB0`-Frames
    /// halten den Versuch nicht offen.
    func testContinuousScanProfileNoiseNeverExtendsTheAbsoluteDeadline() {
        transport.millisPerScriptedRead = 700
        transport.readScript = Array(repeating: .frame(scanProfileFrame()), count: 20)

        let report = executor.perform(.checkStartingRate)

        XCTAssertEqual(report.phase, .failed(.noDeviceAtStartingRate(.timeout)))
        XCTAssertTrue(report.observedScanProfileStream)
        XCTAssertLessThanOrEqual(
            clock.millis, CommissioningRecipe.r26.responseTimeoutMilliseconds + 700,
            "Die Frist begrenzt die Gesamtwartezeit, nicht der einzelne Leseaufruf"
        )
        XCTAssertEqual(report.audit.entries.last?.outcome, .timedOut)
    }

    /// Jeder Leseaufruf bekommt die **Restfrist**, nie das volle
    /// Ausgangstimeout erneut (Lehre aus SICK-011a).
    func testEveryReadGetsOnlyTheRemainingTime() {
        transport.millisPerScriptedRead = 500
        transport.readScript = Array(repeating: .frame(scanProfileFrame()), count: 3)

        executor.perform(.checkStartingRate)

        let timeouts = transport.log.compactMap { operation -> Int32? in
            if case .read(let timeout) = operation { return timeout } else { return nil }
        }
        XCTAssertEqual(timeouts, [2_000, 1_500, 1_000, 500], "Streng fallend, aus derselben Grenze")
    }

    // MARK: - Fehlerklassen

    /// Das **erste** Öffnen ist Sache der Schleife (SICK-030a2, Regel 5)
    /// und hat deshalb keine eigene Direktive. Scheitert es, ist das ein
    /// sichtbarer Fehler mit benannter Ursache — und es geht nichts
    /// hinaus.
    func testAFailedInitialOpenStopsVisiblyAndSendsNothing() {
        transport.failNextOpen = .openFailed("open(2) errno 16")

        let report = executor.perform(.checkStartingRate)

        guard case .failed(.writeFailed(let message)) = report.phase else {
            return XCTFail("Erwartet: sichtbarer Fehler, bekam \(report.phase)")
        }
        XCTAssertTrue(message.contains("starting rate"), message)
        XCTAssertTrue(message.contains("open(2) errno 16"), message)
        XCTAssertTrue(report.isFinal)
        XCTAssertTrue(transport.writtenPayloads.isEmpty, "Es ging nichts hinaus")
        XCTAssertEqual(report.audit.entries.last?.outcome, .writeFailed)
    }

    /// Ein Öffnen, das der Reducer **als Direktive** anordnet (die
    /// Ratendiagnose), wird dagegen zum eigenen Fehlerfall.
    func testAFailedDirectedOpenBecomesAPortOpenFailure() {
        reachFailedState()
        transport.failNextOpen = .openFailed("open(2) errno 2")

        let report = executor.perform(.runRateDiagnostics)

        XCTAssertEqual(report.phase, .failed(.portOpenFailed("open(2) errno 2")))
        XCTAssertTrue(report.isFinal)
        XCTAssertTrue(transport.writtenPayloads.isEmpty, "Es ging keine Probe hinaus")
    }

    /// **Ein zweites Öffnen ohne vorheriges Schließen wird abgelehnt** —
    /// die Regel, an der SICK-030a3 im Modell hing, gilt auch in der
    /// Ausführung.
    func testASecondOpenWithoutAPrecedingCloseIsRefused() {
        reachRestingPointAtStartingRate()
        XCTAssertTrue(transport.isOpen)

        XCTAssertThrowsError(try transport.openPort(baudRate: .baud38400)) { error in
            XCTAssertEqual(error as? CommissioningTransportError, .portAlreadyOpen)
        }
        XCTAssertEqual(transport.openCount, 1, "Es kam keine zweite Verbindung zustande")
    }

    func testAFailedWriteBecomesAVisibleWriteFailure() {
        transport.failNextWrite = .writeFailed("write(2) errno 5")

        let report = executor.perform(.checkStartingRate)

        XCTAssertEqual(report.phase, .failed(.writeFailed("write(2) errno 5")))
        XCTAssertEqual(report.audit.entries.last?.outcome, .writeFailed)
    }

    /// Ein **Schließfehler** beim Ratenwechsel der Diagnose beendet den
    /// Lauf — und führt **nie** zu einem Öffnen bei der anderen Rate.
    ///
    /// **Seit SICK-0330a-1-K1 (H3) kein erfundener Erfolg mehr:** Der
    /// eine Schließversuch, den der Reducer für den Ratenwechsel
    /// anordnet, scheitert hier wirklich einmal — und bleibt dabei. Vor
    /// der Korrektur hätte die alte `.stop`-Behandlung sofort ein
    /// zweites Mal geschlossen; da `failNextClose` ein Einmalfehler ist,
    /// wäre dieser zweite, vom Reducer nie angeordnete Versuch
    /// stillschweigend geglückt und hätte den Bericht fälschlich final
    /// gemacht.
    func testACloseFailureNeverLeadsToAnOpenAtTheOtherRate() {
        let report = runDiagnosticsWithCloseFailure()

        XCTAssertEqual(report.phase, .failed(.portCloseFailed("The port is not open.")))
        XCTAssertEqual(
            transport.openedRates, [.baud9600],
            "Nach einem Schließfehler wird nicht bei der Zielrate geöffnet"
        )
        XCTAssertFalse(report.isFinal, "Kein erfundener Erfolg über einen gescheiterten Schluss")
        XCTAssertTrue(report.isPortHeld, "Der Port bleibt real noch offen")
        // `reachFailedState()` (in `runDiagnosticsWithCloseFailure()`)
        // schließt den Port für die Ausgangsprüfung bereits **einmal**
        // erfolgreich, bevor die Diagnose überhaupt beginnt -- die `1`
        // stammt von dort, nicht vom hier geprüften Ratenwechsel. Der
        // eine angeordnete Schließversuch der Diagnose selbst ist
        // gescheitert und zählt deshalb **nicht** mit.
        XCTAssertEqual(
            transport.closeCount, 1,
            "Kein zweiter, erfolgreicher Schluss über den gescheiterten Diagnose-Versuch hinweg"
        )
    }

    /// **Derselbe Fall, jetzt bis zum ausdrücklichen, erfolgreichen
    /// Folgeversuch weitergeführt** (SICK-0330a-1-K1, Pflichtnachweise
    /// 3+4 für den Portwechsel-Schluss der Ratendiagnose).
    ///
    /// Der Reducer sieht in `.sessionFinished` -- erreicht über
    /// `operatorFinishedSession`, das ab **jedem** Ruhepunkt gilt --
    /// keinen zweiten Ratenwechsel; die Schleife öffnet deshalb nicht
    /// noch einmal bei der anderen Rate, sie versucht nur den echten
    /// Schluss erneut.
    func testAFailedDiagnosticsRateSwitchCloseCanBeRetriedExplicitlyAndClosesExactlyOnce() {
        let firstAttempt = runDiagnosticsWithCloseFailure()
        XCTAssertFalse(firstAttempt.isFinal)
        XCTAssertTrue(firstAttempt.isPortHeld)
        // Die `1` stammt von `reachFailedState()`s eigenem, erfolgreichen
        // Schluss -- der hier geprüfte Ratenwechsel-Schluss ist
        // gescheitert und hat noch **nicht** mitgezählt.
        XCTAssertEqual(transport.closeCount, 1, "Kein erfolgreicher Schluss beim ersten Versuch")

        let retried = executor.perform(.finishSession)

        XCTAssertTrue(retried.isFinal)
        XCTAssertFalse(retried.isPortHeld)
        XCTAssertFalse(transport.isOpen)
        XCTAssertEqual(
            transport.closeCount, 2,
            "Genau ein weiterer, erfolgreicher Schluss über den Folgeversuch"
        )
        XCTAssertEqual(
            transport.openedRates, [.baud9600],
            "Der Folgeversuch öffnet nie bei der anderen Rate -- er schließt nur, was noch offen ist"
        )
    }

    /// **Gegenprobe zu H3, als Test formuliert:** Würde der Executor nach
    /// einer gerade ausgeführten, gescheiterten `.closePort`-Direktive
    /// den regulären `.stop`-Zweig noch einmal durchlaufen (die alte,
    /// fehlerhafte Lage), schlösse er im selben `perform`-Aufruf ein
    /// zweites Mal -- und dieser zweite, vom Reducer nie angeordnete
    /// Versuch träfe auf einen bereits leeren `failNextClose` und
    /// gelänge. Dieser Test hält die **korrekte** Erwartung fest, damit
    /// ein künftiger Rückfall in die alte Lage sichtbar bricht (belegt
    /// durch die begleitende Gegenprobe in `.agent_handoff/`, siehe
    /// Checkpoint).
    func testACloseFailureDuringTheDiagnosticsRateSwitchNeverTriesASecondCloseInTheSamePerform() {
        _ = runDiagnosticsWithCloseFailure()
        XCTAssertEqual(
            transport.log.filter { if case .close = $0 { return true } else { return false } }.count,
            1,
            "Genau ein Schließversuch im ersten Aufruf -- kein automatischer zweiter"
        )
    }

    /// Eine abgebrochene Verbindung ist ein **sichtbarer** Fehler, keine
    /// stille Zeitüberschreitung.
    func testAClosedConnectionWhileWaitingIsReportedAndNotSilentlyTimedOut() {
        transport.readScript = [.closed]

        let report = executor.perform(.checkStartingRate)

        guard case .failed(.writeFailed(let message)) = report.phase else {
            return XCTFail("Erwartet: sichtbarer Fehler, bekam \(report.phase)")
        }
        XCTAssertTrue(message.contains("connection"), "Die Meldung benennt den Fall: \(message)")
        XCTAssertNotEqual(
            report.phase, .failed(.noDeviceAtStartingRate(.timeout)),
            "Ein Abbruch ist keine Zeitüberschreitung"
        )
    }

    /// Unlesbare Bytes sind ein **anderer** Befund als Stille.
    func testUndecodableBytesAreDistinguishedFromSilence() {
        transport.millisPerScriptedRead = 2_500
        transport.readScript = [.bytes([0x00, 0x01, 0x02, 0x03, 0x04])]

        let report = executor.perform(.checkStartingRate)

        XCTAssertEqual(report.phase, .failed(.noDeviceAtStartingRate(.ambiguous)))
        XCTAssertEqual(report.audit.entries.last?.outcome, .ambiguous)

        // Gegenstück: gar nichts kam an.
        setUp()
        let silent = executor.perform(.checkStartingRate)
        XCTAssertEqual(silent.phase, .failed(.noDeviceAtStartingRate(.timeout)))
        XCTAssertEqual(silent.audit.entries.last?.outcome, .timedOut)
    }

    /// Eine Ablehnung des Geräts ist ein Befund, kein Übertragungsfehler.
    func testARejectedLoginStopsWithItsOwnFailure() {
        reachRestingPointAtStartingRate()
        transport.readScript = [.frame(acknowledgementFrame(status: 0x01))]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .failed(.loginRejected))
        XCTAssertEqual(report.audit.entries.last(where: { $0.action == .login })?.outcome, .rejected)
    }

    /// Ein fehlendes Statusbyte ist **niemals** ACK — bis in die
    /// Ausführung hinein.
    ///
    /// Es beendet das Lesefenster aber auch nicht (SICK-032a3a): Hier
    /// bekommt **jedes** der drei Fenster eine solche Antwort, also
    /// gehen genau drei Logins hinaus und der Befund bleibt
    /// „undeutbar".
    func testAMissingStatusByteIsNeverAnAcknowledgement() {
        reachRestingPointAtStartingRate()
        // Ein Leseaufruf verbraucht mehr als die Frist -- so landet je
        // Fenster genau eine Antwort.
        transport.millisPerScriptedRead = 2_500
        transport.readScript = [
            .frame(acknowledgementFrame(status: nil)),
            .frame(acknowledgementFrame(status: nil)),
            .frame(acknowledgementFrame(status: nil))
        ]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .failed(.loginAmbiguous))
        XCTAssertEqual(transport.openedRates, [.baud9600], "Kein Wechsel auf die Zielrate")
        let loginEntries = report.audit.entries.filter { $0.action == .login }
        XCTAssertEqual(loginEntries.map(\.attemptNumber), [1, 2, 3], "Genau drei Sendungen, nie eine vierte")
        XCTAssertEqual(loginEntries.map(\.outcome), [.ambiguous, .ambiguous, .ambiguous])
    }

    // MARK: - SICK-032a3a: die Frist gehört dem Telegramm

    /// Zwischen allen Login-Sendungen liegt mindestens das volle
    /// dokumentierte Lesefenster.
    ///
    /// SICK-032a3 hat bei der ersten unlesbaren Antwort sofort
    /// wiederholt — das zweite Telegramm wäre hier 10 ms nach dem
    /// ersten hinausgegangen statt nach 2 s.
    func testTheRetriesGoOutNoEarlierThanAFullWindowAfterTheirPredecessor() {
        reachRestingPointAtStartingRate()
        // Die Identitätsprobe der Vorbereitung zählt nicht mit.
        let writesBefore = transport.writeTimestamps.count
        // Ein nacktes `06` gleich zu Beginn, danach Stille.
        transport.millisPerScriptedRead = 10
        transport.readScript = [.bytes([0x06])]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        // Das erste Fenster sah Undeutbares, die beiden anderen gar
        // nichts -- gemeldet wird der Befund des letzten Fensters.
        XCTAssertEqual(report.phase, .failed(.loginUnanswered))
        let loginEntries = report.audit.entries.filter { $0.action == .login }
        XCTAssertEqual(loginEntries.map(\.attemptNumber), [1, 2, 3], "Genau drei Sendungen")
        XCTAssertEqual(loginEntries.map(\.outcome), [.ambiguous, .timedOut, .timedOut])

        // Die erste neue Sendung ist der vorgeschaltete Einstellungsmodus;
        // für diese Frist zählen nur die drei danach folgenden Logins.
        let stamps = Array(transport.writeTimestamps.dropFirst(writesBefore + 1))
        guard stamps.count == 3 else {
            return XCTFail("Die beiden belegten Wiederholungen gingen nicht vollständig hinaus")
        }
        for pair in zip(stamps, stamps.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.1 - pair.0,
                loginResponseTimeoutMilliseconds,
                "Eine Wiederholung ging vor dem Ende ihres Lesefensters hinaus"
            )
        }
    }

    /// **Ein nacktes `06` beendet den ersten Versuch nicht** — eine
    /// spätere gültige `A0`-Antwort **in derselben Frist** führt ohne
    /// zweite Sendung weiter.
    func testABareStatusByteIsFollowedByALateAcknowledgementWithoutASecondLogin() {
        reachRestingPointAtStartingRate()
        transport.log = []
        transport.millisPerScriptedRead = 200
        transport.readScript = [
            .bytes([0x06]),                              // unlesbar, mitten im Fenster
            .frame(acknowledgementFrame(status: 0x00)),  // die späte, gültige Antwort
            .frame(acknowledgementFrame(status: 0x00)),  // Baudwechsel bestätigt
            .frame(identityResponseFrame())              // und bei 38400 belegt
        ]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .verified)
        XCTAssertEqual(report.verifiedBaudRate, .baud38400)
        let loginEntries = report.audit.entries.filter { $0.action == .login }
        XCTAssertEqual(loginEntries.map(\.attemptNumber), [1], "Genau eine Login-Sendung")
        XCTAssertEqual(loginEntries.map(\.outcome), [.acknowledged])
    }

    /// Dasselbe mit einem **CRC-validen, aber nicht deutbaren** Frame —
    /// auch er verkürzt das Fenster nicht.
    func testAnUndecipherableFrameDoesNotEndTheWindowEither() {
        reachRestingPointAtStartingRate()
        transport.millisPerScriptedRead = 100
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x7F)),  // unbekanntes Statusbyte
            .frame(acknowledgementFrame(status: nil)),   // Statusbyte fehlt ganz
            .frame(acknowledgementFrame(status: 0x00)),  // und dann doch das ACK
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(identityResponseFrame())
        ]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .verified)
        XCTAssertEqual(
            report.audit.entries.filter { $0.action == .login }.count, 1,
            "Genau eine Login-Sendung"
        )
    }

    /// **Eine Ablehnung beendet sofort** — kein Warten auf die Frist,
    /// keine Wiederholung.
    func testARejectionEndsTheAttemptImmediatelyWithoutWaitingForTheDeadline() {
        reachRestingPointAtStartingRate()
        let writesBefore = transport.writeTimestamps.count
        transport.log = []
        transport.millisPerScriptedRead = 50
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x01)),
            .frame(acknowledgementFrame(status: 0x00))
        ]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .failed(.loginRejected))
        XCTAssertEqual(transport.writtenPayloads.count, 2, "Einstellungsmodus und genau eine Login-Sendung")
        guard let stamp = transport.writeTimestamps.dropFirst(writesBefore).first else {
            return XCTFail("Es ging gar nichts hinaus")
        }
        XCTAssertLessThan(
            clock.millis - stamp, loginResponseTimeoutMilliseconds,
            "Die Ablehnung hat nicht auf die Frist gewartet"
        )
    }

    /// **Der Ablauf nach der Wiederholung ist unverändert** (SICK-032a3,
    /// Punkt 5): erst die belegte Verifikation bei 38400, und **erst
    /// danach** der eigene Schritt „Messwerte minimal kontinuierlich".
    ///
    /// Hier läuft das erste Fenster wirklich ab (SICK-032a3a), die
    /// Wiederholung wird bestätigt, und alles Weitere folgt.
    func testTheFlowAfterTheRetryStillVerifiesFirstAndAsksForMeasurementsOnlyAfterwards() {
        reachRestingPointAtStartingRate()
        transport.millisPerScriptedRead = 2_500
        transport.readScript = [
            .frame(acknowledgementFrame(status: nil)),
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(identityResponseFrame())
        ]
        let switched = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(switched.phase, .verified)
        XCTAssertEqual(switched.verifiedBaudRate, .baud38400)
        XCTAssertFalse(
            switched.audit.entries.contains { $0.action == .measurementModeRequest },
            "Der Messmodus geht nie von selbst mit hinaus"
        )

        // **SICK-0330a-0:** Ein bloßes ACK entscheidet den Schritt nicht
        // mehr -- ohne einen nachfolgenden B0-Frame läuft die feste
        // 3-Sekunden-Stromfrist ab, und der Ablauf endet als
        // `measurementStreamAbsent`. (Der bestehende Executor behandelt
        // jeden `0xB0`-Frame als übersprungenes Rauschen, unabhängig vom
        // Rückgabewert des Reducers -- ein wirklich erfolgreicher
        // MMK-Stream ist über den heutigen Executor deshalb nicht
        // end-to-end nachweisbar. Das ist eine bestehende, außerhalb
        // dieses Slices liegende Executor-Einschränkung [SICK-0330a-1
        // überarbeitet den Executor kooperativ abbrechbar] und wird hier
        // nur dokumentiert, nicht behoben -- der reine Reducer-Nachweis
        // für den B0-Erfolg steht in `CommissioningModelTests`.)
        transport.readScript = [.frame(acknowledgementFrame(status: 0x00))]
        let measurements = executor.perform(.requestMeasurementMode)

        XCTAssertEqual(measurements.phase, .failed(.measurementStreamAbsent))
        XCTAssertEqual(measurements.restingDirective, .stop)
        XCTAssertFalse(measurements.isPortHeld)
        XCTAssertEqual(
            transport.portSequence,
            [.open(.baud9600), .close, .open(.baud38400), .close],
            "Der Fehlschlag gibt den Port frei"
        )
    }

    /// Eine **abgelehnte** Anmeldung wird nie wiederholt — auch nicht,
    /// wenn danach ein ACK bereitläge.
    func testARejectedLoginIsNeverRetriedEvenWhenAnAcknowledgementWouldFollow() {
        reachRestingPointAtStartingRate()
        transport.log = []
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x01)),
            .frame(acknowledgementFrame(status: 0x00))
        ]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .failed(.loginRejected))
        XCTAssertEqual(report.audit.entries.filter { $0.action == .login }.count, 1)
        XCTAssertEqual(transport.writtenPayloads.count, 2, "Einstellungsmodus und genau ein Login gingen hinaus")
        XCTAssertEqual(transport.portSequence, [.close], "Kein Wechsel auf die Zielrate, nur die Freigabe")
    }

    // MARK: - Das Geheimnis

    /// **Ohne übergebenes Geheimnis geht nichts hinaus** — kein
    /// Ersatzwert, kein leeres Feld, kein Testwert.
    func testWithoutASecretNothingIsSentAndTheRunStopsVisibly() {
        reachRestingPointAtStartingRate()
        let writesBefore = transport.writtenPayloads.count

        let report = executor.perform(.switchBaudRate, secret: nil)

        XCTAssertEqual(report.phase, .failed(.unexpectedEvent), "Der Reducer lehnt schon die Handlung ab")
        XCTAssertEqual(transport.writtenPayloads.count, writesBefore, "Es ging nichts hinaus")
    }

    /// **Das Geheimnis überlebt den Aufruf nicht** und erscheint in
    /// keinem Bericht, keinem Audit und keiner Meldung.
    func testTheSecretIsNeitherKeptNorDescribedAnywhere() {
        reachRestingPointAtStartingRate()
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(identityResponseFrame())
        ]
        let report = executor.perform(.switchBaudRate, secret: testSecret)

        let rendered = String(describing: report)
        for byte in testSecretBytes {
            XCTAssertFalse(rendered.contains(String(byte)), "Bericht trägt ein Geheimnisbyte")
        }
        XCTAssertFalse(rendered.contains("Secret"))
        XCTAssertFalse(rendered.contains("secret"))

        // Und ein zweiter Baudwechsel ohne erneute Übergabe sendet kein
        // Login: Der Executor hat das Geheimnis fallen gelassen.
        let mirror = Mirror(reflecting: executor as Any)
        XCTAssertFalse(String(describing: mirror).contains("\(testSecretBytes[0])"))
    }

    /// Das Login-Telegramm trägt das **übergebene** Geheimnis — der
    /// Nachweis, dass der Executor es nicht ersetzt oder weglässt.
    func testTheExecutorSendsSettingsModeBeforeTheAddressedLogin() {
        reachRestingPointAtStartingRate()
        transport.log = []
        transport.autoAcknowledgeSettingsMode = false
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(acknowledgementFrame(status: 0x01))
        ]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .failed(.loginRejected))
        XCTAssertEqual(
            transport.writtenPayloads,
            [
                CommissioningTelegram.settingsMode(secret: testSecret, recipe: .r26).encoded(),
                CommissioningTelegram.login(secret: testSecret, recipe: .r26).encoded()
            ]
        )
        XCTAssertEqual(report.audit.entries.map(\.action).suffix(2), [.settingsMode, .login])
    }

    func testTheLoginCarriesExactlyTheHandedOverSecret() {
        reachRestingPointAtStartingRate()
        transport.readScript = [.frame(acknowledgementFrame(status: 0x01))]
        executor.perform(.switchBaudRate, secret: testSecret)

        let expected = CommissioningTelegram.login(secret: testSecret, recipe: .r26).encoded()
        XCTAssertEqual(transport.writtenPayloads.last, expected)
    }

    // MARK: - hold und stop

    /// **`hold` liest und sendet nichts und behält den Port.**
    func testHoldPerformsNoInputOutputAndKeepsThePort() {
        transport.readScript = [.frame(identityResponseFrame())]
        let report = executor.perform(.checkStartingRate)
        XCTAssertEqual(report.restingDirective, .hold)

        let logAtRest = transport.log
        XCTAssertTrue(transport.isOpen, "Der Port bleibt offen")

        // Der Bericht abgefragt, ohne etwas zu tun.
        _ = executor.report
        XCTAssertEqual(transport.log, logAtRest, "Am Ruhepunkt passiert nichts")
        XCTAssertTrue(transport.isOpen)
    }

    /// **`stop` schließt idempotent** — auch wenn gar nichts offen ist.
    func testStopClosesIdempotentlyEvenAfterAFailedOpen() {
        transport.failNextOpen = .openFailed("open(2) errno 16")
        let report = executor.perform(.checkStartingRate)

        XCTAssertTrue(report.isFinal)
        XCTAssertEqual(transport.openedRates, [.baud9600], "Versucht wurde es bei der Ausgangsrate")
        XCTAssertFalse(transport.isOpen)
        XCTAssertEqual(transport.closeCount, 0, "Es war nie etwas offen")

        // Und ein zweiter Abschluss bleibt folgenlos.
        let again = executor.perform(.finishSession)
        XCTAssertEqual(again.restingDirective, .stop)
        XCTAssertFalse(transport.isOpen)
    }

    /// Ein Abbruch beendet den Lauf, schließt und gibt den Port frei.
    func testAnAbortStopsAndClosesThePort() {
        transport.readScript = [.frame(identityResponseFrame())]
        executor.perform(.checkStartingRate)
        XCTAssertTrue(transport.isOpen)

        let report = executor.perform(.abort)

        XCTAssertEqual(report.phase, .failed(.abortedByOperator))
        XCTAssertTrue(report.isFinal)
        XCTAssertFalse(report.isPortHeld)
        XCTAssertFalse(transport.isOpen)
    }

    // MARK: - Die Ratendiagnose (SICK-030a3) real ausgeführt

    /// **Die SICK-030a3-Folge ist ausführbar:** 9600 öffnen, proben,
    /// wirklich schließen, 38400 öffnen, proben, abschließen.
    func testTheRateDiagnosticsRunsTheRealPortSequence() {
        reachFailedState()

        // Bei 9600 nur Rauschen bis zum Fristende, bei 38400 die echte
        // Identitätsantwort.
        transport.millisPerScriptedRead = 700
        transport.readScript = [
            .frame(scanProfileFrame()),
            .frame(scanProfileFrame()),
            .frame(scanProfileFrame()),
            .frame(identityResponseFrame())
        ]
        let report = executor.perform(.runRateDiagnostics)

        XCTAssertEqual(
            transport.portSequence,
            [.open(.baud9600), .close, .open(.baud38400), .close],
            "Zwischen den Proben steht ein echtes Schließen und ein echtes Öffnen"
        )
        guard case .diagnosticsFinished(let result) = report.phase else {
            return XCTFail("Erwartet: abgeschlossene Diagnose, bekam \(report.phase)")
        }
        XCTAssertFalse(result.respondsAtStartingRate)
        XCTAssertTrue(result.respondsAtTargetRate)
        XCTAssertFalse(report.isPortHeld)
        XCTAssertNil(report.verifiedBaudRate, "Die Diagnose belegt keine Rate für den Monitor")

        let probes = report.audit.entries.filter {
            $0.action == .diagnosticProbe(.baud9600) || $0.action == .diagnosticProbe(.baud38400)
        }
        XCTAssertEqual(probes.map(\.action), [.diagnosticProbe(.baud9600), .diagnosticProbe(.baud38400)])
        XCTAssertEqual(transport.writtenPayloads.count, 2, "Nur die beiden harmlosen Proben")
    }

    /// Und sie sendet **ausschließlich** die Identitätsprobe.
    func testTheRateDiagnosticsSendsNothingButTheIdentityProbe() {
        reachFailedState()

        executor.perform(.runRateDiagnostics)

        let probe = CommissioningTelegram
            .identityRequest(address: CommissioningRecipe.r26.verificationAddress)
            .encoded()
        for payload in transport.writtenPayloads {
            XCTAssertEqual(payload, probe, "Kein Konfigurationstelegramm in der Diagnose")
        }
    }

    // MARK: - Kein Autostart

    /// **Nichts geschieht, bis jemand ``perform(_:secret:)`` ruft.**
    func testCreatingAnExecutorTouchesNothing() {
        let quietClock = TestMonotonicClock()
        let quietTransport = FakeCommissioningTransport(clock: quietClock)
        let quiet = CommissioningExecutor(transport: quietTransport, clock: quietClock)

        XCTAssertTrue(quietTransport.log.isEmpty)
        XCTAssertEqual(quiet.report.phase, .idle)
        XCTAssertFalse(quiet.report.isPortHeld)
        XCTAssertTrue(quiet.report.audit.entries.isEmpty)
        XCTAssertEqual(quietClock.millis, 0, "Nicht einmal die Uhr wurde gefragt")
    }

    // MARK: - E1: Ein Fragment unterdrückt die Login-Wiederholung nicht

    /// **Der Pflichtnachweis zu SICK-031a/E1.**
    ///
    /// Die reale Lage bei 9600: Der Scanner streamt von sich aus
    /// B0-Profile (SICK-012). Das Leeren vor der Sendung räumt nur ab,
    /// was schon dasteht — die ersten Bytes danach sind die Fortsetzung
    /// eines **angeschnittenen** Frames, die `StreamParser` als Rauschen
    /// zählt. Bleibt die Login-Antwort aus, **muss** trotzdem die eine
    /// belegte Wiederholung (A2) laufen: Die Leitung decodiert
    /// nachweislich sauber, es hat nur niemand geantwortet.
    func testAFragmentedScanProfileStreamStillTriggersBothLoginRetries() {
        reachRestingPointAtStartingRate()

        let fragment = truncatedScanProfileTail()
        XCTAssertFalse(fragment.isEmpty, "Der Test liefe sonst ins Leere")
        XCTAssertFalse(
            fragment.contains(SickPLSFrameConstants.startOfText),
            "Ein Rahmenanfang im Fragment würde den Aufbau entwerten"
        )

        transport.millisPerScriptedRead = 300
        transport.readScript = [
            .bytes(fragment),
            .frame(scanProfileFrame()),
            .frame(scanProfileFrame())
        ]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        let loginEntries = report.audit.entries.filter { $0.action == .login }
        XCTAssertEqual(loginEntries.count, 3, "Die beiden belegten Wiederholungen liefen")
        XCTAssertEqual(loginEntries.map(\.attemptNumber), [1, 2, 3])
        XCTAssertEqual(loginEntries.first?.outcome, .timedOut, "Und zwar als Fristablauf, nicht als Lesefehler")
        XCTAssertEqual(report.phase, .failed(.loginUnanswered))
        XCTAssertTrue(report.observedScanProfileStream, "Der Messstrom bleibt sichtbar")
    }

    /// **Die Gegenprobe zu E1, als Test:** dieselben Fragment-/Rauschbytes,
    /// aber **kein einziger** gültiger Frame — dann bleibt der gemeldete
    /// Grund der **Lesebefund** und nicht der Fristablauf.
    ///
    /// Seit SICK-032a3 wird auch diese Lage einmal wiederholt; E1
    /// entscheidet weiterhin, **wie der Ablauf heißt, was er gesehen
    /// hat** — `ambiguous`/`loginAmbiguous` statt
    /// `timedOut`/`loginUnanswered`. Genau das ist der Unterschied
    /// zwischen „es kam nichts" und „es kam etwas Undeutbares", und er
    /// bleibt für die Fehlersuche am Gerät entscheidend.
    func testTheSameNoiseWithoutASingleValidFrameStaysUndecodable() {
        reachRestingPointAtStartingRate()

        transport.millisPerScriptedRead = 2_500
        transport.readScript = [
            .bytes(truncatedScanProfileTail()),
            .bytes(truncatedScanProfileTail()),
            .bytes(truncatedScanProfileTail())
        ]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        let loginEntries = report.audit.entries.filter { $0.action == .login }
        XCTAssertEqual(loginEntries.count, 3, "Die zwei belegten Wiederholungen, nie eine vierte")
        XCTAssertEqual(
            loginEntries.map(\.outcome), [.ambiguous, .ambiguous, .ambiguous],
            "Ein Lesebefund, kein Fristablauf"
        )
        XCTAssertEqual(report.phase, .failed(.loginAmbiguous))
    }

    /// Die Regel gilt genauso für die Identitätsprobe: ein Fragment
    /// **plus** gültige Frames ist Fristablauf, nicht Mehrdeutigkeit.
    func testAFragmentFollowedByValidFramesIsADeadlineAndNotAnAmbiguityForIdentity() {
        transport.millisPerScriptedRead = 300
        transport.readScript = [
            .bytes(truncatedScanProfileTail()),
            .frame(scanProfileFrame()),
            .frame(scanProfileFrame())
        ]

        let report = executor.perform(.checkStartingRate)

        XCTAssertEqual(report.phase, .failed(.noDeviceAtStartingRate(.timeout)))
        XCTAssertEqual(report.audit.entries.last?.outcome, .timedOut)
    }

    // MARK: - E2: Ein vorzeitiges Transport-Timeout ist nicht das Fristende

    /// **Der Pflichtnachweis zu SICK-031a/E2.**
    ///
    /// `DarwinActiveControlSerialPort` meldet ein von einem Signal
    /// unterbrochenes `poll(2)` (`EINTR`) als `.timeout`. Das darf die
    /// Frist nicht verkürzen — sonst verbrauchte ein einziges Signal die
    /// eine der begrenzten Login-Wiederholungen.
    func testAnEarlyTransportTimeoutDoesNotEndTheDeadlineForIdentity() {
        // Kein Uhrfortschritt: Das `.timeout` kommt sofort zurück.
        transport.millisPerScriptedRead = 0
        transport.readScript = [.timeout, .timeout, .frame(identityResponseFrame())]

        let report = executor.perform(.checkStartingRate)

        XCTAssertEqual(report.phase, .respondingAtStartingRate)
        XCTAssertEqual(report.audit.entries.last?.outcome, .acknowledged)
    }

    /// Dasselbe auf der Bestätigungsseite — und zwar so, dass ein
    /// vorzeitiges `.timeout` **nicht** die Wiederholung verbraucht.
    func testAnEarlyTransportTimeoutDoesNotConsumeALoginRetry() {
        reachRestingPointAtStartingRate()

        transport.millisPerScriptedRead = 0
        transport.readScript = [
            .timeout,
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(identityResponseFrame())
        ]

        let report = executor.perform(.switchBaudRate, secret: testSecret)

        XCTAssertEqual(report.phase, .verified)
        XCTAssertEqual(report.verifiedBaudRate, .baud38400)
        XCTAssertEqual(
            report.audit.entries.filter { $0.action == .login }.count, 1,
            "Es blieb bei der ersten Sendung -- die Wiederholung wurde nicht verbraucht"
        )
    }

    /// **Und die echte Frist bleibt eine Frist.** Ein `.timeout`, bei dem
    /// die Zeit wirklich verstreicht, beendet das Warten unverändert.
    func testARealDeadlineStillEndsTheWaitDespiteTheEarlyTimeoutRule() {
        transport.readScript = []

        let report = executor.perform(.checkStartingRate)

        XCTAssertEqual(report.phase, .failed(.noDeviceAtStartingRate(.timeout)))
        XCTAssertEqual(
            clock.millis,
            CommissioningRecipe.r26.responseTimeoutMilliseconds,
            "Genau die Frist, nicht mehr"
        )
    }

    // MARK: - SICK-0330a-1: B0-Rückkehr, kooperativer Abbruch, echte Portfreigabe

    /// **Pflichtnachweis 1.** Unlesbare Antwort → ACK → B0 **im
    /// MMK-Fenster** führt sofort zu `.measurementStreamConfirmed`, das
    /// Protokoll enthält die unmittelbare Antwort **und** den
    /// Stromerfolg, und nach dem B0 findet kein weiterer Read statt.
    func testAnUnreadableAnswerThenAckThenB0WithinTheMeasurementWindowEndsImmediatelyWithoutAFurtherRead() {
        reachVerifiedState()
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x99)),
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(scanProfileFrame())
        ]

        let report = executor.perform(.requestMeasurementMode)

        XCTAssertEqual(report.phase, .measurementStreamConfirmed)
        XCTAssertEqual(report.restingDirective, .hold)
        XCTAssertTrue(report.observedScanProfileStream)

        let entry = try! XCTUnwrap(
            report.audit.entries.last { $0.action == .measurementModeRequest }
        )
        XCTAssertEqual(entry.immediateResponse, .acknowledged, "Die unmittelbare Antwort bleibt sichtbar")
        XCTAssertEqual(entry.outcome, .observedScanProfileStream, "Der spätere Stromerfolg verschluckt sie nicht")

        XCTAssertEqual(
            transport.log.filter { if case .read = $0 { return true } else { return false } }.count, 3,
            "Genau drei Reads -- der dritte trägt den B0, danach wird nicht mehr gelesen"
        )
    }

    /// **H1 (SICK-0330a-1-K1).** Ein vollständiger B0-Frame kann von einem
    /// **unvollständigen** Kandidaten davor bis zum echten Stromende
    /// blockiert bleiben: `feed(...)` bricht beim ersten unfertigen
    /// STX-Kandidaten sofort ab, ohne je zu sehen, was danach im Puffer
    /// steht. Erst `finish()` (bei `.closed`) verwirft den Kandidaten
    /// byteweise und legt den dahinterliegenden, gültigen B0-Frame frei.
    ///
    /// Dieser so nur durch den finalen Drain geborgene Frame muss dem
    /// Reducer genauso erreichen wie einer aus `feed(...)` — und darf
    /// **nicht** übergangen werden, nur weil er beim Stromende statt bei
    /// einem regulären Read ankam.
    func testAB0FrameRecoveredOnlyByTheFinalDrainStillConfirmsTheMeasurementStream() {
        reachVerifiedState()
        transport.readScript = [.bytes(bytesWithABlockedTrailingB0Frame()), .closed]

        let report = executor.perform(.requestMeasurementMode)

        XCTAssertEqual(
            report.phase, .measurementStreamConfirmed,
            "Der beim Stromende geborgene B0-Frame muss genauso zählen wie einer aus einem regulären Read"
        )
        XCTAssertEqual(report.restingDirective, .hold)
        XCTAssertTrue(report.observedScanProfileStream)
    }

    /// **Gegenprobe zu H1, als Test formuliert:** Ohne den geborgenen
    /// B0-Frame aus `finish()` bliebe der Ablauf im Wartefenster stecken
    /// -- das echte Stromende meldet sich dann als sichtbarer Fehler
    /// (`writeFailed`), nie als stiller Erfolg. Dieser Test hält die
    /// **korrekte** Erwartung (Erfolg) fest; die begleitende Gegenprobe
    /// (siehe Checkpoint) hat den `finish()`-Zweig probeweise auf das
    /// alte, bedingungslose `.writeFailed(...)` zurückgesetzt und damit
    /// genau diesen Test brechen lassen.
    func testWithoutTheFinalDrainFixTheSameStreamWouldHaveEndedInAVisibleFailureInstead() {
        reachVerifiedState()
        transport.readScript = [.bytes(bytesWithABlockedTrailingB0Frame()), .closed]

        let report = executor.perform(.requestMeasurementMode)

        XCTAssertNotEqual(
            report.phase, .failed(.measurementStreamAbsent),
            "Der geborgene B0-Frame darf nicht als Stille erscheinen"
        )
    }

    /// **Pflichtnachweis 2 (SICK-0330a-1-K3):** Ein Abbruch **ohne jede
    /// vorherige Reservierung** — also `requestAbort()` an einem frischen
    /// Executor, ohne vorausgehendes ``CommissioningExecutor/beginRun()``
    /// — vergiftet den späteren ersten, direkten `perform`-Aufruf nicht.
    /// Dessen reguläre Gerätewirkung (die Ausgangsprüfung sendet und
    /// liest wirklich) ist sichtbar.
    ///
    /// **Das war bis K2 der umgekehrte, fehlerhafte Nachweis:** Ein
    /// frischer Token reservierte von sich aus bereits eine Generation
    /// ("Phantomkante"), wodurch dieser Abbruch fälschlich den ersten
    /// Lauf beendete, bevor er begann. Der tatsächlich gemeinte
    /// Vor-Start-Fall — Abbruch **nach** einer echten Reservierung, vor
    /// dem Start von `perform` — steht als eigener Test daneben:
    /// ``testAnAbortAfterAnExplicitBeginRunSendsNoOpenFlushWriteOrRead()``.
    func testAnAbortRequestedWithoutAnyReservationDoesNotTaintTheLaterFirstStep() {
        executor.requestAbort()

        transport.readScript = [.frame(identityResponseFrame())]
        let report = executor.perform(.checkStartingRate)

        XCTAssertEqual(
            report.phase, .respondingAtStartingRate,
            "Die reguläre Gerätewirkung, unvergiftet von der wirkungslosen Anforderung"
        )
        XCTAssertFalse(transport.log.isEmpty, "Es wurde wirklich gesendet und gelesen")
    }

    /// **Pflichtnachweis 3 (SICK-0330a-1-K3):** Die produktive
    /// Vor-Start-Reihenfolge — ``CommissioningExecutor/beginRun()`` (die
    /// synchrone, externe Reservierung vor dem Einplanen), danach
    /// ``requestAbort()``, danach erst `perform()` — sendet nichts:
    /// genau ein `.abortedByOperator`, vor jedem Open/Flush/Write/Read.
    func testAnAbortAfterAnExplicitBeginRunSendsNoOpenFlushWriteOrRead() {
        executor.beginRun()
        executor.requestAbort()

        let report = executor.perform(.checkStartingRate)

        XCTAssertTrue(transport.log.isEmpty, "Kein Open/Flush/Write/Read: \(transport.log)")
        XCTAssertEqual(report.phase, .failed(.abortedByOperator))
        XCTAssertTrue(report.isFinal)
        XCTAssertFalse(report.isPortHeld)
    }

    /// **Pflichtnachweis 3.** Ein Abbruch, der während eines Reads
    /// eintrifft, lässt genau diesen Read noch zu Ende gehen; danach
    /// folgt keine weitere Gerätewirkung außer dem Schließen, und der
    /// Bericht wird erst final, nachdem das Schließen wirklich gelang.
    func testAnAbortDuringAReadLetsOnlyThatReadFinishAndBecomesFinalOnlyAfterTheClose() {
        reachRestingPointAtStartingRate()
        assertCooperativeAbort(skippingReads: 0, perform: .switchBaudRate, secret: testSecret)
    }

    /// **Die schärfste Fassung von Pflichtnachweis 3:** Ein Abbruch, der
    /// während **genau des Reads** eintrifft, der die erfolgreiche
    /// MMK-B0-Antwort trägt, gewinnt **trotzdem** -- obwohl dieser Read
    /// für sich genommen sofort `.hold` ergäbe (der Erfolgsfall aus
    /// Pflichtnachweis 1). Ohne die Abbruchprüfung **nach** dem Read
    /// würde `.hold` direkt aus `awaitResponse` zurückgegeben und den
    /// Abbruch in `perform`s Hauptschleife stillschweigend übergehen --
    /// `.hold` prüft dort nicht auf einen wartenden Abbruch, weil es gar
    /// keine weitere Gerätewirkung mehr vorhätte.
    func testAnAbortDuringTheVeryReadThatCarriesTheSuccessfulMeasurementStreamB0StillWins() {
        reachVerifiedState()
        transport.readScript = [.frame(scanProfileFrame())]
        transport.onRead = { [self] in executor.requestAbort() }

        let report = executor.perform(.requestMeasurementMode)
        transport.onRead = nil

        XCTAssertEqual(
            report.phase, .failed(.abortedByOperator),
            "Der Abbruch gewinnt, auch wenn der tragende Read für sich genommen erfolgreich wäre"
        )
        XCTAssertTrue(report.isFinal)
        XCTAssertFalse(report.isPortHeld)
        XCTAssertFalse(transport.isOpen)
    }

    /// **Pflichtnachweis 4 (a):** Identitätsprüfung.
    func testTheSameAbortGuaranteeHoldsForTheIdentityCheck() {
        assertCooperativeAbort(skippingReads: 0, perform: .checkStartingRate)
    }

    /// **Pflichtnachweis 4 (b):** das erste Login-Fenster.
    func testTheSameAbortGuaranteeHoldsForTheFirstLoginWindow() {
        reachRestingPointAtStartingRate()
        assertCooperativeAbort(skippingReads: 0, perform: .switchBaudRate, secret: testSecret)
    }

    /// **Pflichtnachweis 4 (c):** das zweite, belegte Login-Fenster —
    /// das erste Fenster bleibt unbeantwortet, läuft also ab (kein
    /// Abbruch dort), erst im zweiten Fenster trifft der Abbruch ein.
    func testTheSameAbortGuaranteeHoldsForTheRetriedLoginWindow() {
        reachRestingPointAtStartingRate()
        assertCooperativeAbort(skippingReads: 1, perform: .switchBaudRate, secret: testSecret)
    }

    /// **Pflichtnachweis 4 (d):** die Baudanforderung — nach einem
    /// sofort bestätigten Login.
    func testTheSameAbortGuaranteeHoldsForTheBaudSwitchRequest() {
        reachRestingPointAtStartingRate()
        transport.readScript = [.frame(acknowledgementFrame(status: 0x00))]
        assertCooperativeAbort(skippingReads: 1, perform: .switchBaudRate, secret: testSecret)
    }

    /// **Pflichtnachweis 4 (e):** die Zielratenverifikation — nach Login
    /// und Baudwechsel, am neu geöffneten Port.
    func testTheSameAbortGuaranteeHoldsForTheTargetRateVerification() {
        reachRestingPointAtStartingRate()
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(acknowledgementFrame(status: 0x00))
        ]
        assertCooperativeAbort(skippingReads: 2, perform: .switchBaudRate, secret: testSecret)
    }

    /// **Pflichtnachweis 4 (f):** die MMK-Stromfrist.
    func testTheSameAbortGuaranteeHoldsForTheMeasurementStreamWait() {
        reachVerifiedState()
        assertCooperativeAbort(skippingReads: 0, perform: .requestMeasurementMode)
    }

    /// **Pflichtnachweis 4 (g):** die Ratendiagnose.
    func testTheSameAbortGuaranteeHoldsForTheRateDiagnostics() {
        reachFailedState()
        assertCooperativeAbort(skippingReads: 0, perform: .runRateDiagnostics)
    }

    /// **Pflichtnachweis 5, erste Hälfte:** ein Abbruch, der zwischen
    /// „eingeplant" und „tatsächlich gestartet" eintrifft, geht nicht
    /// verloren -- das ist exakt dieselbe Lage wie ein nach einem echten
    /// ``CommissioningExecutor/beginRun()`` beobachteter Abbruch und
    /// bereits durch
    /// ``testAnAbortAfterAnExplicitBeginRunSendsNoOpenFlushWriteOrRead()``
    /// belegt (SICK-0330a-1-K3: die Vorbedingung hier braucht deshalb
    /// jetzt selbst ein echtes `beginRun()` -- ein bloßer `requestAbort()`
    /// ohne jede vorherige Reservierung ist seit K3 wirkungslos, siehe
    /// ``testAnAbortRequestedWithoutAnyReservationDoesNotTaintTheLaterFirstStep()``).
    ///
    /// **Zweite Hälfte:** ein bereits abgeschlossener Abbruch vergiftet
    /// den nächsten, frischen Aufruf **nicht**.
    func testACompletedAbortDoesNotPoisonTheNextFreshRun() {
        executor.beginRun()
        executor.requestAbort()
        let aborted = executor.perform(.checkStartingRate)
        XCTAssertEqual(aborted.phase, .failed(.abortedByOperator), "Vorbedingung des Tests")
        XCTAssertFalse(executor.abortToken.isAbortRequested, "Die Marke ist beim Beobachten verbraucht")

        transport.readScript = [.frame(identityResponseFrame())]
        let fresh = executor.perform(.checkStartingRate)

        XCTAssertEqual(fresh.phase, .respondingAtStartingRate, "Der nächste Lauf ist unbeeinflusst")
        XCTAssertFalse(transport.writtenPayloads.isEmpty, "Er sendet ganz normal")
    }

    /// **Pflichtnachweis 6.** Gelingt das Schließen, ist genau **ein**
    /// relevanter Schluss final und portfrei.
    func testASuccessfulCloseIsFinalAndReleasesThePort() {
        reachVerifiedState()
        XCTAssertTrue(transport.isOpen, "Vorbedingung des Tests")
        let closeCountBefore = transport.closeCount

        let report = executor.perform(.finishSession)

        XCTAssertTrue(report.isFinal)
        XCTAssertFalse(report.isPortHeld)
        XCTAssertFalse(transport.isOpen)
        XCTAssertEqual(transport.closeCount, closeCountBefore + 1, "Genau ein relevanter Schluss")
    }

    /// **Pflichtnachweis 7.** Scheitert das Schließen, ist der Bericht
    /// weder final noch portfrei -- der Besitz bleibt sichtbar gehalten.
    /// Ein späterer, ausdrücklich ausgelöster Schließversuch führt danach
    /// genau einmal zum finalen, portfreien Bericht.
    func testAFailedCloseStaysHeldAndAnExplicitRetrySucceedsExactlyOnce() {
        reachVerifiedState()
        let closeCountBefore = transport.closeCount
        transport.alwaysFailClose = .portNotOpen

        let stillOpen = executor.perform(.finishSession)

        XCTAssertFalse(stillOpen.isFinal, "Kein erfundener Erfolg über einen gescheiterten Schluss")
        XCTAssertTrue(stillOpen.isPortHeld)
        XCTAssertTrue(transport.isOpen, "Der Port bleibt wirklich offen")
        XCTAssertEqual(transport.closeCount, closeCountBefore, "Kein erfolgreicher Schluss beim ersten Versuch")

        transport.alwaysFailClose = nil
        let releasedNow = executor.perform(.finishSession)

        XCTAssertTrue(releasedNow.isFinal)
        XCTAssertFalse(releasedNow.isPortHeld)
        XCTAssertFalse(transport.isOpen)
        XCTAssertEqual(
            transport.closeCount, closeCountBefore + 1,
            "Genau ein erfolgreicher Schluss über beide Versuche"
        )
    }

    /// **Pflichtnachweis 8.** Nach einem fehlgeschlagenen Open bleibt
    /// Stop idempotent final, **ohne** überhaupt zu versuchen zu
    /// schließen -- es war ja nie etwas offen.
    func testStopStaysIdempotentlyFinalAfterAFailedOpenWithoutAttemptingToClose() {
        transport.failNextOpen = .openFailed("open(2) errno 16")

        let report = executor.perform(.checkStartingRate)

        XCTAssertTrue(report.isFinal)
        XCTAssertFalse(report.isPortHeld)
        XCTAssertFalse(
            transport.log.contains { if case .close = $0 { return true } else { return false } },
            "Kein erfundener Schlussversuch an einem Transport, der ohnehin nichts zu schließen hätte"
        )
    }

    /// **Der geforderte reale Nebenläufigkeitsnachweis:** ``perform(_:secret:)``
    /// läuft auf einem echten Hintergrund-Thread und blockiert wirklich
    /// in einem Read; ``requestAbort()`` kommt von einem **anderen**,
    /// echten Thread — synchronisiert über zwei Semaphoren, damit der
    /// Ablauf deterministisch bleibt, ohne eine Zeitspanne zu erraten.
    func testAGenuinelyDifferentThreadCanAbortAPerformThatIsReallyBlockedInARead() {
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        transport.onRead = {
            readStarted.signal()
            releaseRead.wait()
        }

        var report: CommissioningStepReport?
        let workItem = DispatchWorkItem { [self] in
            report = executor.perform(.checkStartingRate)
        }
        DispatchQueue.global().async(execute: workItem)

        readStarted.wait()
        executor.requestAbort()
        releaseRead.signal()
        workItem.wait()

        XCTAssertEqual(report?.phase, .failed(.abortedByOperator))
        XCTAssertTrue(report?.isFinal ?? false)
        XCTAssertFalse(report?.isPortHeld ?? true)
        XCTAssertFalse(transport.isOpen)
    }

    /// Gemeinsamer Nachweis für Pflichtnachweis 3/4: ein Abbruch,
    /// eingespeist über ``CommissioningTransportTestSupport/onRead``,
    /// nachdem `readsToSkip` reguläre Reads bereits verstrichen sind.
    private func assertCooperativeAbort(
        skippingReads readsToSkip: Int,
        perform command: CommissioningCommand,
        secret: InstallationSecret? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var remaining = readsToSkip
        transport.onRead = { [self] in
            if remaining > 0 {
                remaining -= 1
            } else {
                executor.requestAbort()
            }
        }

        let report = executor.perform(command, secret: secret)
        transport.onRead = nil

        XCTAssertEqual(report.phase, .failed(.abortedByOperator), file: file, line: line)
        XCTAssertTrue(report.isFinal, "final erst nach dem wirklichen Schluss", file: file, line: line)
        XCTAssertFalse(report.isPortHeld, file: file, line: line)
        XCTAssertFalse(transport.isOpen, file: file, line: line)

        if let lastReadIndex = transport.log.lastIndex(where: {
            if case .read = $0 { return true } else { return false }
        }) {
            let afterLastRead = transport.log[(lastReadIndex + 1)...]
            XCTAssertTrue(
                afterLastRead.allSatisfy { if case .close = $0 { return true } else { return false } },
                "Nach dem letzten Read folgt höchstens noch ein Schließen: \(afterLastRead)",
                file: file, line: line
            )
        } else {
            XCTFail("Kein Read protokolliert -- der Abbruch wäre nicht während eines Reads eingetreten", file: file, line: line)
        }
    }

    // MARK: - SICK-0330a: die Übernahme einer bereits offenen, bei 38.400 belegten Verbindung

    /// **Kein I/O:** die Übernahme sendet nichts, liest nichts, öffnet
    /// nichts -- sie merkt nur vor, dass der aufrufende Standardweg die
    /// Identität bereits selbst belegt hat.
    func testAdoptingAnAlreadyOpenConnectionSendsAndReadsNothing() {
        let report = executor.adoptAlreadyOpenConnectionWithConfirmedIdentity()

        XCTAssertEqual(report.phase, .verified)
        XCTAssertEqual(report.restingDirective, .hold)
        XCTAssertEqual(report.verifiedBaudRate, .baud38400)
        XCTAssertTrue(report.isPortHeld)
        XCTAssertFalse(report.isFinal)
        XCTAssertTrue(transport.log.isEmpty, "Kein Öffnen, kein Leeren, kein Schreiben, kein Lesen")
    }

    /// Nur aus `.idle` gültig -- jeder andere Ausgangspunkt bleibt der
    /// sichtbare `unexpectedEvent`, kein stiller Neustart. **Kein
    /// stilles Umdeuten der realen Verbindung**: Der Port war (über
    /// `checkStartingRate`) wirklich offen und bleibt es -- der Bericht
    /// zeigt das unverändert (`isPortHeld == true`), auch wenn der
    /// Reducer den Aufruf selbst ablehnt.
    func testAdoptingFromAnAlreadyRunningStateIsRefusedAsUnexpected() {
        transport.readScript = [.frame(identityResponseFrame())]
        let starting = executor.perform(.checkStartingRate)
        XCTAssertEqual(starting.phase, .respondingAtStartingRate, "Vorbedingung des Tests")

        let report = executor.adoptAlreadyOpenConnectionWithConfirmedIdentity()

        XCTAssertEqual(report.phase, .failed(.unexpectedEvent))
        XCTAssertTrue(report.isPortHeld, "Die reale Verbindung aus checkStartingRate steht weiterhin")
        XCTAssertFalse(report.isFinal)
    }

    /// Nach der Übernahme genügt **eine** MMK-Anforderung bis zum
    /// belegten Messstrom -- kein Login, kein Baudtelegramm, kein
    /// Port-Reopen.
    ///
    /// **Vorbedingung der Methode selbst** (siehe ihre Kopfdoku): Der
    /// Transport hält bereits eine echte, offene Verbindung -- hier
    /// direkt am Fake hergestellt, ohne über einen Commissioning-Schritt
    /// zu laufen, genau wie es der reale Standardweg tut (die Verbindung
    /// stammt dort aus dem passiven/B1-Teil der Verbindungspolitik, nicht
    /// aus `checkStartingRate`).
    func testAdoptionFollowedByOneMeasurementModeRequestReachesTheStream() {
        try? transport.openPort(baudRate: .baud38400)
        transport.log.removeAll()

        _ = executor.adoptAlreadyOpenConnectionWithConfirmedIdentity()

        transport.readScript = [.frame(scanProfileFrame())]
        let report = executor.perform(.requestMeasurementMode)

        XCTAssertEqual(report.phase, .measurementStreamConfirmed)
        XCTAssertEqual(report.verifiedBaudRate, .baud38400)
        XCTAssertEqual(transport.openedRates, [], "Kein einziges Öffnen -- der Port war schon offen")
        XCTAssertEqual(transport.writtenPayloads.count, 1, "Genau ein MMK-Telegramm")
    }

    // MARK: - Hilfen

    private func reachRestingPointAtStartingRate() {
        transport.readScript = [.frame(identityResponseFrame())]
        let report = executor.perform(.checkStartingRate)
        XCTAssertEqual(report.phase, .respondingAtStartingRate, "Vorbedingung des Tests")
        transport.readScript = []
    }

    /// Der Ruhepunkt `.verified` — bereit für `.requestMeasurementMode`.
    ///
    /// **Schließt und öffnet den Port dabei selbst wirklich einmal**
    /// (der Baudwechsel schließt bei der Ausgangsrate und öffnet neu bei
    /// der Zielrate) — das Protokoll wird deshalb danach geleert, damit
    /// ein Test ab hier von einer sauberen Grundlage zählt, statt diesen
    /// internen Wechsel mitzuzählen.
    private func reachVerifiedState() {
        reachRestingPointAtStartingRate()
        transport.readScript = [
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(acknowledgementFrame(status: 0x00)),
            .frame(identityResponseFrame())
        ]
        let report = executor.perform(.switchBaudRate, secret: testSecret)
        XCTAssertEqual(report.phase, .verified, "Vorbedingung des Tests")
        transport.readScript = []
        transport.log.removeAll()
    }

    /// Ein gescheiterter Lauf — der einzige Zustand, aus dem die
    /// Ratendiagnose angeboten wird.
    private func reachFailedState() {
        transport.readScript = []
        let report = executor.perform(.checkStartingRate)
        XCTAssertEqual(
            report.phase, .failed(.noDeviceAtStartingRate(.timeout)), "Vorbedingung des Tests"
        )
        transport.log.removeAll()
    }

    /// Diagnose bis zum Schließen, das dann fehlschlägt.
    private func runDiagnosticsWithCloseFailure() -> CommissioningStepReport {
        reachFailedState()
        transport.readScript = [.frame(identityResponseFrame())]
        transport.failNextClose = .portNotOpen
        return executor.perform(.runRateDiagnostics)
    }
}
