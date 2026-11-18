import SickPLSActiveControl
import SickPLSCore
import SickPLSMacTransport
import XCTest
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl

/// Der testbare Standardverbindungslauf (SICK-0330a).
///
/// **Kein echter Port, kein Gerät, kein TX/RX, keine PTY.** Alles läuft
/// gegen ``ScriptedStandardConnectionTransport`` mit injizierter
/// monotoner Zeit; echt sind ``ConnectionPolicyModel`` und
/// ``CommissioningExecutor`` -- beide unverändert wiederverwendet, nicht
/// nachgebaut.
final class StandardConnectionRunTests: XCTestCase {
    func testWrongCountDominatesTheWholeMeasurementBatchInBothOrders() {
        for mode in ScannerMeasurementMode.allCases {
            for goodFirst in [true, false] {
                let clock = TestMonotonicClock()
                let scripted = ScriptedStandardConnectionTransport(clock: clock)
                scripted.millisPerScriptedRead = StandardConnectionRun.passiveObservationTimeoutMilliseconds
                let good = standardScanProfileFrame(pointCount: mode.pointCount).encoded()
                let bad = standardScanProfileFrame(pointCount: mode == .mmk ? 361 : 90).encoded()
                scripted.readScript = [.timeout, .standardFrame(standardIdentityResponseFrame()), .bytes(goodFirst ? good + bad : bad + good)]
                let run = StandardConnectionRun(transport: scripted, passwordStore: TrackingScannerPasswordStore(initial: ""), measurementMode: mode, clock: clock)
                XCTAssertEqual(run.connect(portPath: "/dev/cu.test").phase, .failed(.measurementPointCountMismatch))
                XCTAssertFalse(scripted.isOpen)
            }
        }
    }
    func testTypedModesRejectWrongCountsAndUseTheirOwnTelegram() {
        for mode in ScannerMeasurementMode.allCases {
            let clock = TestMonotonicClock()
            let transport = ScriptedStandardConnectionTransport(clock: clock)
            transport.millisPerScriptedRead = StandardConnectionRun.passiveObservationTimeoutMilliseconds
            transport.readScript = [.timeout, .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardScanProfileFrame(pointCount: mode.pointCount))]
            let run = StandardConnectionRun(transport: transport, passwordStore: TrackingScannerPasswordStore(initial: ""), measurementMode: mode, clock: clock)
            XCTAssertEqual(run.connect(portPath: "/dev/cu.test").phase, .ready(.activeContinuationMeasurementStream))
            XCTAssertTrue(transport.writtenPayloads.contains(mode.telegram(address: CommissioningRecipe.r26.configurationAddress).encoded()))
            _ = run.releasePortForMeasurement(); XCTAssertFalse(transport.isOpen)

            let wrong = ScriptedStandardConnectionTransport(clock: clock)
            wrong.millisPerScriptedRead = StandardConnectionRun.passiveObservationTimeoutMilliseconds
            wrong.readScript = [.timeout, .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardScanProfileFrame(pointCount: mode == .mmk ? 361 : 90))]
            let rejected = StandardConnectionRun(transport: wrong, passwordStore: TrackingScannerPasswordStore(initial: ""), measurementMode: mode, clock: clock)
            XCTAssertEqual(rejected.connect(portPath: "/dev/cu.test").phase, .failed(.measurementPointCountMismatch))
            XCTAssertFalse(wrong.isOpen)
        }
    }

    private func makeRun(
        transport: ScriptedStandardConnectionTransport? = nil,
        clock: TestMonotonicClock = TestMonotonicClock(),
        passwordStore: TrackingScannerPasswordStore = TrackingScannerPasswordStore(),
        allowsAutomaticCommissioning: Bool = true
    ) -> (StandardConnectionRun, ScriptedStandardConnectionTransport, TestMonotonicClock, TrackingScannerPasswordStore) {
        let clock = clock
        let transport = transport ?? ScriptedStandardConnectionTransport(clock: clock)
        let run = StandardConnectionRun(
            transport: transport, passwordStore: passwordStore, clock: clock,
            allowsAutomaticCommissioning: allowsAutomaticCommissioning
        )
        return (run, transport, clock, passwordStore)
    }

    /// Reicht Antworten **gestaffelt** ein: Erst wenn der reale
    /// Lesezähler den in `at` genannten Wert erreicht, wird `frames` als
    /// neues, alleiniges `readScript` gesetzt. **Ein einfaches Vorab-
    /// Setzen von `readScript` reicht nicht** -- der allererste Lesevorgang
    /// ist immer der passive Fast Path (SICK-0330r Abschnitt 1), der
    /// jeden dort bereitstehenden Frame sofort verbraucht, egal für
    /// welche spätere Phase er eigentlich gedacht war. `at`-Werte sind
    /// exakt gegen den tatsächlichen Leseverlauf nachgezählt (siehe
    /// Kommentare an den Aufrufstellen), nicht geraten.
    private func stageReads(
        _ transport: ScriptedStandardConnectionTransport,
        _ stages: [(at: Int, frames: [SerialPortReadOutcome])]
    ) {
        var readCount = 0
        var remaining = stages
        transport.onRead = {
            readCount += 1
            if let next = remaining.first, next.at == readCount {
                transport.readScript = next.frames
                remaining.removeFirst()
            }
        }
    }

    // MARK: - Pflichtnachweis 1: Passiver Erfolg

    func testPassiveSuccessSkipsFlushWriteAndPasswordAndCommissioning() throws {
        let (run, transport, _, passwordStore) = makeRun()
        transport.readScript = [.standardFrame(standardScanProfileFrame())]

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .ready(.passiveScanProfile))
        XCTAssertTrue(report.isPortHeld)
        XCTAssertFalse(report.isFinal)
        XCTAssertEqual(transport.openedRates, [.baud38400])
        XCTAssertEqual(transport.flushCount, 0, "Der passive Weg leert nie")
        XCTAssertTrue(transport.writtenPayloads.isEmpty, "Der passive Weg schreibt nie")
        XCTAssertEqual(passwordStore.loadCount, 0, "Der passive Weg liest das Passwort nie")
        XCTAssertNil(report.audit.commissioning, "Kein Commissioning-Teil beteiligt")
    }

    func testManualOnlyModeStopsAfterPassiveObservationWithoutAnyTX() throws {
        let (run, transport, _, passwordStore) = makeRun(allowsAutomaticCommissioning: false)

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .failed(.manualPreparationRequired))
        XCTAssertFalse(report.isPortHeld)
        XCTAssertTrue(report.isFinal)
        XCTAssertEqual(transport.openedRates, [.baud38400])
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(transport.flushCount, 0)
        XCTAssertTrue(transport.writtenPayloads.isEmpty)
        XCTAssertEqual(passwordStore.loadCount, 0)
    }

    // MARK: - Pflichtnachweis 2: B0 gewinnt die B1-Race

    func testScanProfileWinsTheIdentityProbeRace() throws {
        let (run, transport, _, passwordStore) = makeRun()
        // Lesevorgang 1 ist der passive Fast Path -- er muss LEER
        // ausgehen (natürliches Timeout), sonst verbraucht er den
        // B0-Frame selbst. Erst Lesevorgang 2 (die eine B1-Probe)
        // bekommt ihn.
        stageReads(transport, [(at: 2, frames: [.standardFrame(standardScanProfileFrame())])])

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .ready(.scanProfileDuringIdentityProbe))
        XCTAssertTrue(report.isPortHeld)
        XCTAssertFalse(report.isFinal)
        XCTAssertEqual(transport.writtenPayloads.count, 1, "Genau eine B1-Sendung insgesamt")
        XCTAssertEqual(transport.flushCount, 1)
        XCTAssertNil(report.audit.commissioning, "Keine aktive Fortsetzung -- B0 gewann vorher")
        XCTAssertEqual(passwordStore.loadCount, 0)
    }

    // MARK: - Pflichtnachweis 3: B1 bei 38.400 -> aktive Fortsetzung -> MMK

    func testConfirmedIdentityAtTargetRateLeadsToActiveContinuationAndMeasurementStream() throws {
        let (run, transport, _, passwordStore) = makeRun()
        // Lesevorgang 1 (passiv) läuft leer ab; Lesevorgang 2 (B1-Probe)
        // liefert B1; Lesevorgang 3 (MMK-Wartefenster der aktiven
        // Fortsetzung) liefert danach B0 -- beide bereits ab Lesevorgang 2
        // im selben Skript, FIFO über die Lesevorgänge 2 und 3 verteilt.
        stageReads(transport, [
            (at: 2, frames: [
                .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardScanProfileFrame())
            ])
        ])

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .ready(.activeContinuationMeasurementStream))
        XCTAssertTrue(report.isPortHeld)
        XCTAssertFalse(report.isFinal)
        XCTAssertEqual(transport.openedRates, [.baud38400], "Kein Port-Reopen")
        XCTAssertEqual(transport.writtenPayloads.count, 2, "Eine B1-Probe, ein MMK-Telegramm -- kein Login, kein Baudwechsel")
        XCTAssertEqual(passwordStore.loadCount, 0, "Die aktive Fortsetzung braucht kein Passwort")
        XCTAssertNotNil(report.audit.commissioning, "Der delegierte Teil ist jetzt beteiligt")
    }

    // MARK: - Pflichtnachweis 4: Fallback ab 9600 für jede der drei Identitätslücken

    /// Treibt den Lauf durch die passive und die B1-Phase (beide
    /// natürlich per Zeitablauf, kein Frame), skriptiert dann -- über
    /// ``ScriptedStandardConnectionTransport/onRead`` ausgelöst, sobald
    /// der dritte reale Lesevorgang beginnt -- die vollständige
    /// 9600-Fallback-Folge: B1@9600, Login-ACK, Baud-ACK, B1@38400,
    /// MMK-B0.
    private func runFullFallback(
        transport: ScriptedStandardConnectionTransport, run: StandardConnectionRun
    ) -> StandardConnectionReport {
        var readCount = 0
        transport.onRead = {
            readCount += 1
            if readCount == 3 {
                transport.readScript = [
                    .standardFrame(standardIdentityResponseFrame()),
                    .standardFrame(standardAcknowledgementFrame()),
                    .standardFrame(standardAcknowledgementFrame()),
                    .standardFrame(standardIdentityResponseFrame()),
                    .standardFrame(standardScanProfileFrame())
                ]
            }
        }
        return run.connect(portPath: "/dev/cu.usbserial-TEST")
    }

    func testTimeoutIdentityGapFallsBackToTheFullNineSixHundredSequence() throws {
        let (run, transport, _, passwordStore) = makeRun()
        // Beide natürlichen Fristen (passiv, B1) laufen leer ab -- kein
        // Skript, bis der Fallback beginnt.
        let report = runFullFallback(transport: transport, run: run)

        XCTAssertEqual(report.phase, .ready(.commissioningFallbackMeasurementStream))
        XCTAssertTrue(report.isPortHeld)
        XCTAssertFalse(report.isFinal)
        XCTAssertEqual(
            transport.openedRates, [.baud38400, .baud9600, .baud38400],
            "Erst die eigene 38.400-Öffnung, dann bestätigt geschlossen, 9600 geöffnet, zuletzt zurück auf 38.400"
        )
        XCTAssertEqual(passwordStore.loadCount, 1, "Erst nach bestätigter 9600-Identität, direkt vor dem Login")
        XCTAssertNotNil(report.audit.commissioning)
    }

    func testUnexpectedResponseIdentityGapAlsoFallsBackSuccessfully() throws {
        let (run, transport, _, _) = makeRun()
        // Lesevorgang 1 (passiv) läuft leer ab. Lesevorgang 2 -- die eine
        // B1-Probe -- bekommt eine Antwort mit einem anderen Kommandobyte
        // und entscheidet sich damit **sofort** (kein zweiter Lesevorgang
        // für dieselbe Probe nötig); Lesevorgang 3 ist folglich bereits
        // der erste des 9600-Fallbacks.
        let fallbackFrames: [SerialPortReadOutcome] = [
            .standardFrame(standardIdentityResponseFrame()),
            .standardFrame(standardAcknowledgementFrame()),
            .standardFrame(standardAcknowledgementFrame()),
            .standardFrame(standardIdentityResponseFrame()),
            .standardFrame(standardScanProfileFrame())
        ]
        stageReads(transport, [
            (at: 2, frames: [.standardFrame(standardUnexpectedResponseFrame(commandByte: 0x99))]),
            (at: 3, frames: fallbackFrames)
        ])
        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .ready(.commissioningFallbackMeasurementStream))
    }

    func testAmbiguousIdentityGapAlsoFallsBackSuccessfully() throws {
        let (run, transport, _, _) = makeRun()
        // Lesevorgang 1 (passiv) läuft leer ab. Lesevorgang 2 der B1-Probe
        // liefert reines Rauschen (unlesbar, entscheidet noch nicht);
        // Lesevorgang 3 läuft danach natürlich bis zur Frist leer --
        // **das** entscheidet erst auf `.ambiguous` (SICK-031a Auflage
        // E1: unlesbar, nicht still). Der 9600-Fallback beginnt deshalb
        // erst mit Lesevorgang 4.
        let fallbackFrames: [SerialPortReadOutcome] = [
            .standardFrame(standardIdentityResponseFrame()),
            .standardFrame(standardAcknowledgementFrame()),
            .standardFrame(standardAcknowledgementFrame()),
            .standardFrame(standardIdentityResponseFrame()),
            .standardFrame(standardScanProfileFrame())
        ]
        stageReads(transport, [
            (at: 2, frames: [.bytes([0xFF, 0xFF, 0xFF])]),
            (at: 4, frames: fallbackFrames)
        ])
        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .ready(.commissioningFallbackMeasurementStream))
    }

    /// Belegt die genaue Klassifikation, nicht nur den Endzustand: reines
    /// Rauschen ohne je einen gültigen Frame ist ``ConnectionPolicyIdentityGap/ambiguous``,
    /// echte Stille ``ConnectionPolicyIdentityGap/timeout`` (SICK-031a,
    /// Auflage E1 -- dieselbe, wiederverwendete Regel, hier am eigenen
    /// Audit-Eintrag belegt statt nur am Endzustand).
    func testAmbiguousAndTimeoutAreDistinguishedInTheAudit() throws {
        let (ambiguousRun, ambiguousTransport, _, _) = makeRun()
        var ambiguousReadCount = 0
        ambiguousTransport.onRead = {
            ambiguousReadCount += 1
            if ambiguousReadCount == 2 {
                // Nur Rauschen, nie ein vollständiger Frame -- „unlesbar",
                // nicht „still".
                ambiguousTransport.readScript = [.bytes([0xFF, 0xFF, 0xFF])]
            } else if ambiguousReadCount == 3 {
                ambiguousTransport.failNextOpen = .openFailed("gestoppt nach der Klassifikation")
            }
        }
        let ambiguousReport = ambiguousRun.connect(portPath: "/dev/cu.usbserial-TEST")
        let ambiguousEntry = try XCTUnwrap(
            ambiguousReport.audit.entries.last { if case .identityProbeAtTargetRate = $0.action { return true }; return false }
        )
        XCTAssertEqual(ambiguousEntry.outcome, .identityGap(.ambiguous))

        let (timeoutRun, timeoutTransport, _, _) = makeRun()
        var timeoutReadCount = 0
        timeoutTransport.onRead = {
            timeoutReadCount += 1
            if timeoutReadCount == 2 {
                timeoutTransport.failNextOpen = .openFailed("gestoppt nach der Klassifikation")
            }
        }
        let timeoutReport = timeoutRun.connect(portPath: "/dev/cu.usbserial-TEST")
        let timeoutEntry = try XCTUnwrap(
            timeoutReport.audit.entries.last { if case .identityProbeAtTargetRate = $0.action { return true }; return false }
        )
        XCTAssertEqual(timeoutEntry.outcome, .identityGap(.timeout))
    }

    // MARK: - Pflichtnachweis 5: Kein brauchbares Passwort

    func testMissingPasswordReportsFailureAndClosesThePort() throws {
        let (run, transport, _, passwordStore) = makeRun(passwordStore: TrackingScannerPasswordStore(initial: ""))
        let report = runFullFallback(transport: transport, run: run)

        XCTAssertEqual(report.phase, .failed(.missingOrUnusablePassword))
        XCTAssertTrue(report.isFinal)
        XCTAssertFalse(report.isPortHeld)
        XCTAssertEqual(passwordStore.loadCount, 1)
        // Kein Login-, Baud- oder MMK-Telegramm nach der Ausgangsprüfung
        // (deren eine B1-Probe bei 9600 bereits gesendet wurde).
        XCTAssertEqual(transport.writtenPayloads.count, 1 /* B1@38400 */ + 1 /* B1@9600 */)
    }

    func testUnusablePasswordOfWrongLengthAlsoStops() throws {
        let (run, transport, _, passwordStore) = makeRun(passwordStore: TrackingScannerPasswordStore(initial: "kurz"))
        let report = runFullFallback(transport: transport, run: run)

        XCTAssertEqual(report.phase, .failed(.missingOrUnusablePassword))
        XCTAssertEqual(passwordStore.loadCount, 1)
    }

    // MARK: - Pflichtnachweis 6: MMK-Wahrheit (über die aktive Fortsetzung)

    func testAcknowledgementAloneIsNotMeasurementSuccessAndEventuallyTimesOut() throws {
        let (run, transport, _, _) = makeRun()
        // Lesevorgang 1 (passiv) läuft leer ab; ab Lesevorgang 2 liefert
        // die B1-Probe die Identität, danach (Lesevorgang 3, MMK-Fenster)
        // nur ein bloßes ACK -- das reicht laut Wahrheitstabelle nicht.
        stageReads(transport, [
            (at: 2, frames: [
                .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardAcknowledgementFrame())
            ])
        ])

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        // K1-4: **abgebildet, nicht eingebettet** -- der öffentliche
        // Ausgang ist der eigene, geschlossene Fall, nicht der rohe
        // `CommissioningFailure`.
        XCTAssertEqual(report.phase, .failed(.measurementStreamAbsent))
        XCTAssertTrue(report.isFinal)
    }

    func testAScanProfileBeforeTheDeadlineIsSuccess() throws {
        let (run, transport, _, _) = makeRun()
        stageReads(transport, [
            (at: 2, frames: [
                .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardScanProfileFrame())
            ])
        ])

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .ready(.activeContinuationMeasurementStream))
    }

    func testARejectionDuringMeasurementModeIsItsOwnImmediateFailure() throws {
        let (run, transport, _, _) = makeRun()
        stageReads(transport, [
            (at: 2, frames: [
                .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardAcknowledgementFrame(status: AcknowledgementClassifier.rejectedStatusByte))
            ])
        ])

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .failed(.measurementModeRejected))
        XCTAssertTrue(report.isFinal)
    }

    /// Die unmittelbare Antwort und die spätere Stromwirkung bleiben im
    /// eingebetteten Commissioning-Audit getrennt (SICK-0330a-0-K1) --
    /// hier nur belegt, dass das eingebettete Audit diese Information
    /// überhaupt trägt, nicht seine interne Struktur neu geprüft.
    func testTheAuditKeepsTheImmediateResponseAndTheStreamEffectSeparate() throws {
        let (run, transport, _, _) = makeRun()
        stageReads(transport, [
            (at: 2, frames: [
                .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardScanProfileFrame())
            ])
        ])

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")
        let commissioningAudit = try XCTUnwrap(report.audit.commissioning)
        XCTAssertFalse(commissioningAudit.entries.isEmpty)
    }

    // MARK: - Pflichtnachweis 7: Portfehler unterscheidbar, Schluss-Retry

    func testOpenFailureIsReportedDistinctly() throws {
        let (run, transport, _, _) = makeRun()
        transport.failNextOpen = .openFailed("simuliert")

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .failed(.portOpenFailed))
        XCTAssertTrue(report.isFinal)
        XCTAssertFalse(report.isPortHeld)
    }

    func testReadFailureDuringPassiveObservationIsReportedAsAReadFailure() throws {
        let (run, transport, _, _) = makeRun()
        transport.readScript = [.closed]

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .failed(.portReadFailed))
        XCTAssertTrue(report.isFinal)
    }

    func testWriteFailureDuringTheIdentityProbeIsReportedAsAWriteFailure() throws {
        let (run, transport, _, _) = makeRun()
        transport.failNextWrite = .writeFailed("simuliert")

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .failed(.portWriteFailed))
        XCTAssertTrue(report.isFinal)
    }

    func testCloseFailureIsNotFinalAndAnExplicitRetryReallyReleases() throws {
        let (run, transport, _, _) = makeRun()
        // Der Port wird zuerst wirklich geöffnet (passiver Fast Path);
        // ein Abbruch trifft während des laufenden passiven Reads ein --
        // ein echter Schließversuch folgt, der hier bewusst fehlschlägt.
        transport.alwaysFailClose = .openFailed("Schluss schlägt zunächst fehl")
        transport.onRead = { [weak run] in
            run?.requestAbort()
        }

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        // Der Abbruch selbst gelang (Pflichtnachweis 8), aber der
        // anschließende echte Schließversuch schlug fehl -- ein
        // fehlgeschlagener Schluss ist dominant gegenüber dem Abbruch als
        // Ursache (dieselbe Lehre wie SICK-0330r-K1, H1/H2): der Bericht
        // zeigt `.portCloseFailed`, nicht `.aborted`.
        XCTAssertEqual(report.phase, .failed(.portCloseFailed))
        XCTAssertTrue(report.isPortHeld, "Der Schluss schlug fehl -- nicht final")
        XCTAssertFalse(report.isFinal)

        transport.alwaysFailClose = nil
        let retried = run.retryClose()
        XCTAssertFalse(retried.isPortHeld, "Der ausdrückliche Retry gibt wirklich frei")
        XCTAssertTrue(retried.isFinal)
    }

    func testRetryCloseIsHarmlessWhenNothingIsOpen() throws {
        let (run, transport, _, _) = makeRun()
        transport.failNextOpen = .openFailed("simuliert")
        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")
        XCTAssertTrue(report.isFinal)

        let retried = run.retryClose()
        XCTAssertEqual(retried, report, "Wirkungslos -- kein Port ist mehr offen")
    }

    // MARK: - Pflichtnachweis 8: Abbruchmatrix

    func testAbortBeforeAnyEffectStopsImmediatelyWithoutOpeningAnything() throws {
        let (run, transport, _, _) = makeRun()
        // `requestAbort()` wirkt nur auf eine bereits reservierte
        // Laufkante (`CommissioningAbortToken`, SICK-0330a-1-K3) -- ohne
        // vorheriges `beginRun()` verpufft ein Abbruch vor dem ersten
        // `connect()`-Aufruf wirkungslos, genau wie bei
        // `CommissioningExecutor`.
        run.beginRun()
        run.requestAbort()

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .failed(.aborted))
        XCTAssertTrue(report.isFinal)
        XCTAssertFalse(report.isPortHeld)
        XCTAssertEqual(transport.openCount, 0, "Es wurde nie geöffnet")
    }

    func testAbortDuringThePassiveReadEndsAbortedAndReallyCloses() throws {
        let (run, transport, _, _) = makeRun()
        transport.onRead = { [weak run] in run?.requestAbort() }

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .failed(.aborted))
        XCTAssertFalse(report.isPortHeld)
        XCTAssertTrue(report.isFinal)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testAbortDuringTheIdentityProbeReadEndsAbortedAndReallyCloses() throws {
        let (run, transport, _, _) = makeRun()
        var readCount = 0
        transport.onRead = { [weak run] in
            readCount += 1
            if readCount == 2 { run?.requestAbort() }
        }

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .failed(.aborted))
        XCTAssertFalse(report.isPortHeld)
        XCTAssertTrue(report.isFinal)
    }

    /// Abbruch **zwischen** zwei Teilabschnitten -- nach der bestätigten
    /// B1-Identität, aber bevor an den delegierten Commissioning-Teil
    /// übergeben wird.
    func testAbortBetweenSectionsAtTheActiveContinuationHandoffStopsThere() throws {
        let (run, transport, _, _) = makeRun()
        transport.readScript = [.standardFrame(standardIdentityResponseFrame())]
        var readCount = 0
        transport.onRead = { [weak run] in
            readCount += 1
            if readCount == 2 { run?.requestAbort() }
        }

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .failed(.aborted))
        XCTAssertNil(report.audit.commissioning, "Der Commissioning-Teil wurde nie erreicht")
    }

    /// Abbruch während einer laufenden Commissioning-Restfrist wirkt
    /// **innerhalb** des delegierten Executors -- über dieselbe,
    /// geteilte Laufkante.
    func testAbortDuringACommissioningWaitAlsoEndsAborted() throws {
        let (run, transport, _, _) = makeRun()
        // `runFullFallback` kann hier nicht wiederverwendet werden -- es
        // überschreibt `transport.onRead` selbst. Der Fallback wird
        // deshalb hier eigenständig gestaffelt (Lesevorgang 3), und der
        // Abbruch trifft direkt danach (Lesevorgang 4, mitten im
        // delegierten Login-/Baudwechsel-Warten desselben, geteilten
        // Abbruchtokens).
        let fallbackFrames: [SerialPortReadOutcome] = [
            .standardFrame(standardIdentityResponseFrame()),
            .standardFrame(standardAcknowledgementFrame()),
            .standardFrame(standardAcknowledgementFrame()),
            .standardFrame(standardIdentityResponseFrame()),
            .standardFrame(standardScanProfileFrame())
        ]
        var readCount = 0
        transport.onRead = { [weak run] in
            readCount += 1
            if readCount == 3 {
                transport.readScript = fallbackFrames
            } else if readCount == 4 {
                run?.requestAbort()
            }
        }
        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .failed(.aborted))
    }

    /// Zwei Abbruchanforderungen für denselben, noch laufenden Lauf
    /// vergiften keinen unabhängigen Folgelauf (dieselbe Laufkanten-
    /// disziplin wie ``CommissioningAbortToken``, SICK-0330a-1-K2/K3).
    func testAnAbortDoesNotPoisonALaterIndependentRun() throws {
        let (run, _, _, _) = makeRun()
        run.beginRun()
        run.requestAbort()
        let firstReport = run.connect(portPath: "/dev/cu.usbserial-TEST")
        XCTAssertEqual(firstReport.phase, .failed(.aborted))

        let (secondRun, secondTransport, _, _) = makeRun()
        secondTransport.readScript = [.standardFrame(standardScanProfileFrame())]
        let secondReport = secondRun.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(secondReport.phase, .ready(.passiveScanProfile), "Unabhängig und unvergiftet")
    }

    // MARK: - Pflichtnachweis 9: Geschlossene Zustandsmatrix

    /// Jede hier erreichte Phase entstand über einen echten, typisierten
    /// Übergang -- kein Testhaken schreibt eine Phase hinein. Die
    /// Erschöpfung selbst ist strukturell (kein `switch` in
    /// `StandardConnectionRun.swift`/`ConnectionPolicy.swift`/
    /// `CommissioningState.swift` über diese Typen trägt ein `default`,
    /// siehe ``StandardConnectionSwitchExhaustivenessTests``); dieser
    /// Test belegt zusätzlich, dass jede benannte Lage wirklich
    /// erreichbar ist.
    func testEveryDistinguishedPhaseIsReallyReachable() throws {
        // .idle ist der Ausgangszustand von `ConnectionPolicyModel()`
        // selbst -- erschöpfend dort bereits geprüft (`ConnectionPolicyTests`).
        //
        // .ready(.passiveScanProfile) -- Pflichtnachweis 1
        // .ready(.scanProfileDuringIdentityProbe) -- Pflichtnachweis 2
        // .ready(.activeContinuationMeasurementStream) -- Pflichtnachweis 3
        // .ready(.commissioningFallbackMeasurementStream) -- Pflichtnachweis 4
        // .failed(.aborted) -- Pflichtnachweis 8
        // .failed(.invalidPort) -- unten
        // .failed(.portOpenFailed/.portReadFailed/.portWriteFailed/.portCloseFailed) -- Pflichtnachweis 7
        // .failed(.missingOrUnusablePassword) -- Pflichtnachweis 5
        // .failed(.commissioning(_)) -- Pflichtnachweis 6
        // .closingPort -- unten, über einen fehlschlagenden Schluss ohne Abbruch
        // Alle bereits oben real erreicht; hier zusätzlich .invalidPort:
        let (invalidRun, invalidTransport, _, _) = makeRun()
        let invalidReport = invalidRun.connect(portPath: "not-a-real-port")
        guard case .failed(.invalidPort) = invalidReport.phase else {
            return XCTFail("Erwartet: .failed(.invalidPort), war: \(invalidReport.phase)")
        }
        XCTAssertEqual(invalidTransport.openCount, 0)
    }

    // MARK: - Pflichtnachweis 10: Redaktion

    func testTheReportNeverCarriesTheRawUnexpectedResponseByte() throws {
        let (run, transport, _, _) = makeRun()
        // Lesevorgang 1 (passiv) läuft leer ab; Lesevorgang 2 (B1-Probe)
        // liefert die unerwartete Antwort und entscheidet sofort; der
        // Fallback beginnt deshalb mit Lesevorgang 3.
        stageReads(transport, [
            (at: 2, frames: [.standardFrame(standardUnexpectedResponseFrame(commandByte: 0x77))]),
            (at: 3, frames: [
                .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardAcknowledgementFrame()),
                .standardFrame(standardAcknowledgementFrame()),
                .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardScanProfileFrame())
            ])
        ])
        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")
        XCTAssertEqual(report.phase, .ready(.commissioningFallbackMeasurementStream))

        // Der Bericht selbst ist geschlossen redigiert -- eine
        // textuelle Beschreibung trägt nirgends `0x77`.
        XCTAssertFalse(String(describing: report).contains("77"))
    }

    func testTwoDifferentUnexpectedBytesYieldTheSameRedactedCategory() throws {
        func gapKind(commandByte: UInt8) throws -> StandardConnectionPhase {
            let (run, transport, _, _) = makeRun()
            // Lesevorgang 1 (passiv) muss leer ausgehen, sonst verbraucht
            // er den Frame selbst, statt ihn der B1-Probe (Lesevorgang 2)
            // zu überlassen.
            var readCount = 0
            transport.onRead = {
                readCount += 1
                if readCount == 2 {
                    transport.readScript = [.standardFrame(standardUnexpectedResponseFrame(commandByte: commandByte))]
                } else if readCount == 3 {
                    // Nach der belegten Klassifikation genügt ein
                    // fehlschlagendes Öffnen, um den Fallback früh und
                    // deterministisch zu beenden -- der Vergleichspunkt
                    // ist die **Klassifikation**, nicht der weitere Lauf.
                    transport.failNextOpen = .openFailed("gestoppt nach der Klassifikation")
                }
            }
            return run.connect(portPath: "/dev/cu.usbserial-TEST").phase
        }

        let first = try gapKind(commandByte: 0x11)
        let second = try gapKind(commandByte: 0x99)
        // Beide enden am selben, redigierten Fehschlagspunkt --
        // Kommissionierung scheiterte an derselben nachfolgenden
        // Öffnung, unabhängig vom ursprünglichen Bytewert.
        XCTAssertEqual(first, second)
    }

    // MARK: - Pflichtnachweis 11: Kompositionsgrenze

    func testNoSecondCommissioningExecutorExistsBeforeTheFallbackBegins() throws {
        let (run, transport, _, _) = makeRun()
        transport.readScript = [.standardFrame(standardScanProfileFrame())]
        _ = run.connect(portPath: "/dev/cu.usbserial-TEST")
        // Der passive Weg erreicht `.ready`, ohne je einen
        // `CommissioningExecutor` zu bauen -- siehe Pflichtnachweis 1
        // (`report.audit.commissioning == nil`). Zusätzliche strukturelle
        // Absicherung: `CommissioningControlBoundaryTests
        // .testOnlyTheFactoryBuildsARealRun`.
    }

    // MARK: - Pflichtnachweis 12: Gegenproben

    /// Gegenprobe (a): Ohne die B0-vor-B1-Vorrangregel in
    /// ``ConnectionPolicyModel/applyWhileCheckingIdentity`` (SICK-0330r,
    /// bereits abgenommen und hier unverändert wiederverwendet) würde ein
    /// während der B1-Antwortwartezeit eintreffendes B0 stattdessen die
    /// aktive Fortsetzung samt MMK auslösen. Da dieser Slice die Regel
    /// nicht selbst implementiert, sondern nur komponiert, steht die
    /// Gegenprobe stellvertretend am **eigenen** Aufrufpfad: Wird
    /// ``StandardConnectionRun/performIdentityProbe(baudRate:edge:)``s
    /// Vorrangprüfung in ``classifyIdentityFrames(_:)`` umgangen (B1 vor
    /// B0 geprüft statt in Empfangsreihenfolge), bricht dieser Test.
    func testCounterProofScanProfileMustWinOverALaterIdentityFrameInTheSameBatch() throws {
        let (run, transport, _, _) = makeRun()
        // Lesevorgang 1 (passiv) läuft leer ab; Lesevorgang 2 (die eine
        // B1-Probe) bekommt beide Frames **im selben Lesevorgang**, B0
        // zuerst.
        let combined = standardScanProfileFrame().encoded() + standardIdentityResponseFrame().encoded()
        stageReads(transport, [(at: 2, frames: [.bytes(combined)])])

        let report = run.connect(portPath: "/dev/cu.usbserial-TEST")

        XCTAssertEqual(report.phase, .ready(.scanProfileDuringIdentityProbe))
        XCTAssertNil(report.audit.commissioning, "B0 gewann -- keine aktive Fortsetzung wurde begonnen")
    }

    /// Gegenprobe (b): Das Passwort wird ausschließlich innerhalb von
    /// ``StandardConnectionRun/beginCommissioningFallback(gap:baudRate:)``
    /// gelesen, direkt vor ``CommissioningCommand/switchBaudRate`` --
    /// belegt über den Lesezähler an zwei Stellen, an denen es **nicht**
    /// gelesen werden darf.
    func testCounterProofThePasswordIsNeverReadOnThePassiveOrActiveContinuationPath() throws {
        let (passiveRun, passiveTransport, _, passivePasswordStore) = makeRun()
        passiveTransport.readScript = [.standardFrame(standardScanProfileFrame())]
        _ = passiveRun.connect(portPath: "/dev/cu.usbserial-TEST")
        XCTAssertEqual(passivePasswordStore.loadCount, 0)

        let (activeRun, activeTransport, _, activePasswordStore) = makeRun()
        stageReads(activeTransport, [
            (at: 2, frames: [
                .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardScanProfileFrame())
            ])
        ])
        _ = activeRun.connect(portPath: "/dev/cu.usbserial-TEST")
        XCTAssertEqual(activePasswordStore.loadCount, 0)
    }
}
