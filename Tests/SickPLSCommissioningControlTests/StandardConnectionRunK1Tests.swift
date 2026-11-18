import Dispatch
import SickPLSActiveControl
import SickPLSCore
import SickPLSMacTransport
import XCTest
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl

/// Die Pflichtnachweise von **SICK-0330a-K1**: Batchvorrang, laufweite
/// Abbruchkante, Schlussdominanz, geschlossener Bericht und beobachtbarer
/// Fortschritt.
///
/// **Kein echter Port, kein Gerät, kein TX/RX, keine PTY.** Alles läuft
/// gegen ``ScriptedStandardConnectionTransport`` mit injizierter monotoner
/// Zeit; echt sind ``ConnectionPolicyModel`` und ``CommissioningExecutor``
/// -- beide unverändert wiederverwendet, nicht nachgebaut.
final class StandardConnectionRunK1Tests: XCTestCase {

    private let portPath = "/dev/cu.usbserial-TEST"

    /// Frei erfundene Markertexte, die **nirgends** an der öffentlichen
    /// Grenze auftauchen dürfen (K1-4). Bewusst so gewählt, dass sie in
    /// keinem echten Satz vorkommen können.
    private static let openMarker = "OEFFNEN-MARKER-4711"
    private static let writeMarker = "SENDEN-MARKER-4712"
    private static let closeMarker = "SCHLIESSEN-MARKER-4713"

    private func makeRun(
        passwordStore: TrackingScannerPasswordStore = TrackingScannerPasswordStore(),
        abortToken: CommissioningAbortToken = CommissioningAbortToken(),
        onProgress: StandardConnectionProgressHandler? = nil
    ) -> (StandardConnectionRun, ScriptedStandardConnectionTransport, TrackingScannerPasswordStore) {
        let clock = TestMonotonicClock()
        let transport = ScriptedStandardConnectionTransport(clock: clock)
        let run = StandardConnectionRun(
            transport: transport,
            passwordStore: passwordStore,
            clock: clock,
            abortToken: abortToken,
            onProgress: onProgress
        )
        return (run, transport, passwordStore)
    }

    /// Reicht Antworten **gestaffelt** ein -- siehe die ausführliche
    /// Begründung an ``StandardConnectionRunTests``: Der allererste
    /// Lesevorgang ist immer der passive Fast Path und verbraucht jeden
    /// dort bereitstehenden Frame.
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

    private var fallbackFrames: [SerialPortReadOutcome] {
        [
            .standardFrame(standardIdentityResponseFrame()),   // B1 @ 9600
            .standardFrame(standardAcknowledgementFrame()),    // Login-ACK
            .standardFrame(standardAcknowledgementFrame()),    // Baud-ACK
            .standardFrame(standardIdentityResponseFrame()),   // B1 @ 38400
            .standardFrame(standardScanProfileFrame())         // MMK-B0
        ]
    }

    // MARK: - Pflichtnachweis 1: B0 gewinnt den **ganzen** Batch (K1-1)

    /// Ein einziger Lesevorgang liefert mehrere Frames; irgendwo darin
    /// steht ein B0. Egal an welcher Stelle: Der Messstrom ist belegt,
    /// und **keine** weitere Gerätewirkung folgt.
    private func assertScanProfileWinsTheWholeBatch(
        _ frames: [Frame],
        _ label: String,
        line: UInt = #line
    ) {
        let (run, transport, passwordStore) = makeRun()
        let combined = frames.reduce(into: [UInt8]()) { $0 += $1.encoded() }
        // Lesevorgang 1 ist der passive Fast Path -- er läuft leer ab,
        // damit erst die eine B1-Probe (Lesevorgang 2) den Batch bekommt.
        stageReads(transport, [(at: 2, frames: [.bytes(combined)])])

        let report = run.connect(portPath: portPath)

        XCTAssertEqual(
            report.phase, .ready(.scanProfileDuringIdentityProbe),
            "\(label): B0 im Batch belegt den Messstrom", line: line
        )
        XCTAssertTrue(report.isPortHeld, "\(label)", line: line)
        XCTAssertFalse(report.isFinal, "\(label)", line: line)
        XCTAssertEqual(
            transport.writtenPayloads.count, 1,
            "\(label): **null weitere Sendungen** nach dem bereits enthaltenen B0 -- nur die eine B1-Probe",
            line: line
        )
        XCTAssertEqual(
            transport.openedRates, [.baud38400],
            "\(label): kein Port-Reopen, kein 9600-Fallback", line: line
        )
        XCTAssertEqual(
            passwordStore.loadCount, 0,
            "\(label): kein Passwortzugriff", line: line
        )
        XCTAssertNil(
            report.audit.commissioning,
            "\(label): kein Login, kein Baudtelegramm, kein MMK -- der delegierte Teil begann nie",
            line: line
        )
    }

    func testScanProfileWinsWhenItStandsFirstInTheBatch() throws {
        assertScanProfileWinsTheWholeBatch(
            [standardScanProfileFrame(), standardIdentityResponseFrame()], "[B0, B1]"
        )
    }

    /// **Der Kernfall von K1-1.** Vor der Korrektur gewann hier B1 und
    /// löste die aktive Fortsetzung samt MMK aus.
    func testScanProfileWinsEvenWhenTheIdentityAnswerStandsFirst() throws {
        assertScanProfileWinsTheWholeBatch(
            [standardIdentityResponseFrame(), standardScanProfileFrame()], "[B1, B0]"
        )
    }

    /// Vor der Korrektur entschied hier die unerwartete Antwort sofort --
    /// und der Lauf ging in den vollständigen 9600-Fallback, obwohl im
    /// selben Batch bereits ein Messstrom stand.
    func testScanProfileWinsEvenWhenAnUnexpectedAnswerStandsFirst() throws {
        assertScanProfileWinsTheWholeBatch(
            [standardUnexpectedResponseFrame(commandByte: 0x99), standardScanProfileFrame()],
            "[unerwartet, B0]"
        )
    }

    /// Ein anderer valider Frame (hier eine Bestätigungsantwort) vor dem
    /// B0 -- auch er darf den Messstrom nicht überstimmen.
    func testScanProfileWinsEvenBehindAnotherValidFrame() throws {
        assertScanProfileWinsTheWholeBatch(
            [standardAcknowledgementFrame(), standardScanProfileFrame()],
            "[anderer valider Frame, B0]"
        )
    }

    /// Enthält der Batch **kein** B0, entscheidet unverändert die erste
    /// relevante Antwort -- die Vorrangregel weicht die Klassifikation
    /// nicht auf.
    func testWithoutAnyScanProfileTheFirstRelevantAnswerStillDecides() throws {
        let (run, transport, _) = makeRun()
        let combined = standardIdentityResponseFrame().encoded()
            + standardUnexpectedResponseFrame(commandByte: 0x99).encoded()
        stageReads(transport, [
            (at: 2, frames: [.bytes(combined)]),
            // Nach der belegten B1-Antwort folgt die aktive Fortsetzung;
            // ihr MMK-Fenster bleibt hier bewusst ohne B0.
            (at: 3, frames: [])
        ])

        let report = run.connect(portPath: portPath)

        XCTAssertEqual(
            report.phase, .failed(.measurementStreamAbsent),
            "B1 entschied -- die aktive Fortsetzung lief, ihr MMK-Fenster blieb ohne Messstrom"
        )
    }

    // MARK: - Pflichtnachweis 2: Die drei Lücken der einen Laufkante (K1-2)

    // Alle drei Lückennachweise folgen demselben deterministischen
    // Muster: Der Lauf läuft auf einem zweiten Thread; ein Haltepunkt
    // **innerhalb** der Lücke signalisiert `reachedGap`, wartet auf
    // `abortRequested` und läuft erst dann weiter. Der Abbruch steht
    // damit nachweislich, **bevor** die nächste Wirkung beginnen kann --
    // ohne geratene Zeitspanne und ohne `sleep`.

    /// **Lücke 1: zwischen `checkStartingRate` und dem Passwort-Lesen.**
    ///
    /// Der Haltepunkt ist die Fortschrittsmeldung unmittelbar nach der
    /// bestätigten Ausgangsprüfung -- sie liegt nachweislich **nach** dem
    /// Rückkehren des Executors und **vor** dem Passwort-Lesen. Vor K1
    /// war in genau diesem Augenblick keine Generation reserviert: Der
    /// Abbruch verpuffte, das Passwort wurde gelesen und das Login ging
    /// hinaus.
    func testAnAbortBetweenTheStartingRateCheckAndThePasswordReadStopsTheRun() throws {
        let reachedGap = DispatchSemaphore(value: 0)
        let abortRequested = DispatchSemaphore(value: 0)
        let passwordStore = TrackingScannerPasswordStore()

        var run: StandardConnectionRun!
        let (createdRun, transport, _) = makeRun(passwordStore: passwordStore) { report in
            guard case .runningCommissioning(.respondingAtStartingRate, _) = report.phase else { return }
            reachedGap.signal()
            abortRequested.wait()
        }
        run = createdRun
        stageReads(transport, [(at: 3, frames: fallbackFrames)])

        var report: StandardConnectionReport?
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            report = run.connect(portPath: self.portPath)
            finished.signal()
        }

        XCTAssertEqual(reachedGap.wait(timeout: .now() + 5), .success, "Die Lücke wurde nie erreicht")
        run.requestAbort()
        abortRequested.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "Der Lauf kehrte nicht zurück")

        let finalReport = try XCTUnwrap(report)
        XCTAssertEqual(finalReport.phase, .failed(.aborted))
        XCTAssertEqual(
            passwordStore.loadCount, 0,
            "Der Abbruch traf die Lücke **vor** dem Passwort-Lesen"
        )
        XCTAssertEqual(
            transport.writtenPayloads.count, 2,
            "Genau die B1-Probe bei 38.400 und die eine bei 9600 -- kein Login, kein Baudtelegramm, kein MMK"
        )
    }

    /// **Lücke 2: zwischen dem Passwort-Lesen und `switchBaudRate`.**
    ///
    /// Haltepunkt ist der Lesezugriff selbst: Er ist bereits erfolgt
    /// (`loadCount == 1`), das Login darf danach aber nicht mehr
    /// hinausgehen.
    func testAnAbortBetweenThePasswordReadAndTheBaudSwitchStopsTheRun() throws {
        let reachedGap = DispatchSemaphore(value: 0)
        let abortRequested = DispatchSemaphore(value: 0)
        let passwordStore = TrackingScannerPasswordStore()
        passwordStore.onLoad = {
            reachedGap.signal()
            abortRequested.wait()
        }

        let (run, transport, _) = makeRun(passwordStore: passwordStore)
        stageReads(transport, [(at: 3, frames: fallbackFrames)])

        var report: StandardConnectionReport?
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            report = run.connect(portPath: self.portPath)
            finished.signal()
        }

        XCTAssertEqual(reachedGap.wait(timeout: .now() + 5), .success, "Die Lücke wurde nie erreicht")
        run.requestAbort()
        abortRequested.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "Der Lauf kehrte nicht zurück")

        let finalReport = try XCTUnwrap(report)
        XCTAssertEqual(finalReport.phase, .failed(.aborted))
        XCTAssertEqual(passwordStore.loadCount, 1, "Das Passwort war bereits gelesen -- das ist Lücke 2")
        XCTAssertEqual(
            transport.writtenPayloads.count, 2,
            "Kein Login, kein Baudtelegramm, kein MMK nach dem Abbruch"
        )
    }

    /// **Lücke 3: zwischen dem erfolgreichen Wechsel und der
    /// MMK-Anforderung.**
    ///
    /// Haltepunkt ist die Fortschrittsmeldung nach belegter
    /// Zielverifikation -- der Wechsel ist vollständig, die MMK-Sendung
    /// steht unmittelbar bevor.
    func testAnAbortBetweenTheVerifiedSwitchAndTheMeasurementRequestStopsTheRun() throws {
        let reachedGap = DispatchSemaphore(value: 0)
        let abortRequested = DispatchSemaphore(value: 0)

        var run: StandardConnectionRun!
        let (createdRun, transport, passwordStore) = makeRun { report in
            guard case .runningCommissioning(.verifiedAtTargetRate, .fallbackFromStartingRate) = report.phase
            else { return }
            reachedGap.signal()
            abortRequested.wait()
        }
        run = createdRun
        stageReads(transport, [(at: 3, frames: fallbackFrames)])

        var report: StandardConnectionReport?
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            report = run.connect(portPath: self.portPath)
            finished.signal()
        }

        XCTAssertEqual(reachedGap.wait(timeout: .now() + 5), .success, "Die Lücke wurde nie erreicht")
        run.requestAbort()
        abortRequested.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "Der Lauf kehrte nicht zurück")

        let finalReport = try XCTUnwrap(report)
        XCTAssertEqual(finalReport.phase, .failed(.aborted))
        XCTAssertEqual(passwordStore.loadCount, 1)
        XCTAssertEqual(
            transport.writtenPayloads.count, 6,
            "B1@38400, B1@9600, Einstellungsmodus, Login, Baudwechsel, B1-Zielverifikation -- **kein** MMK-Telegramm mehr"
        )
    }

    // MARK: - Pflichtnachweis 3: Die Kante ist an der Rückkehr geschlossen

    /// Nach **jedem** Ende ist keine Generation mehr reserviert: Ein
    /// danach angeforderter Abbruch verpufft wirkungslos
    /// (``CommissioningAbortToken``, SICK-0330a-1-K3) -- er trifft weder
    /// einen späteren ``StandardConnectionRun/retryClose()`` noch einen
    /// neuen Lauf mit demselben injizierten Token.
    private func assertEdgeIsClosed(
        after report: StandardConnectionReport,
        token: CommissioningAbortToken,
        _ label: String,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            token.isAbortRequested, "\(label): keine offene Anforderung", line: line
        )
        token.requestAbort()
        XCTAssertFalse(
            token.isAbortRequested,
            "\(label): eine nach der Rückkehr eingegangene Anforderung verpufft -- die Kante ist geschlossen",
            line: line
        )
    }

    func testThePassiveSuccessLeavesNoReservedEdge() throws {
        let token = CommissioningAbortToken()
        let (run, transport, _) = makeRun(abortToken: token)
        transport.readScript = [.standardFrame(standardScanProfileFrame())]
        let report = run.connect(portPath: portPath)
        XCTAssertEqual(report.phase, .ready(.passiveScanProfile))
        assertEdgeIsClosed(after: report, token: token, "passiver Erfolg")
    }

    func testTheInvalidPortEndLeavesNoReservedEdge() throws {
        let token = CommissioningAbortToken()
        let (run, _, _) = makeRun(abortToken: token)
        let report = run.connect(portPath: "kein-gueltiger-anschluss")
        guard case .failed(.invalidPort) = report.phase else {
            return XCTFail("Erwartet: .failed(.invalidPort), war: \(report.phase)")
        }
        assertEdgeIsClosed(after: report, token: token, "ungültiger Port")
    }

    func testAPolicyFailureLeavesNoReservedEdge() throws {
        let token = CommissioningAbortToken()
        let (run, transport, _) = makeRun(abortToken: token)
        transport.failNextOpen = .openFailed(Self.openMarker)
        let report = run.connect(portPath: portPath)
        XCTAssertEqual(report.phase, .failed(.portOpenFailed))
        assertEdgeIsClosed(after: report, token: token, "Policy-Fehler")
    }

    func testTheActiveSuccessLeavesNoReservedEdge() throws {
        let token = CommissioningAbortToken()
        let (run, transport, _) = makeRun(abortToken: token)
        stageReads(transport, [
            (at: 2, frames: [
                .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardScanProfileFrame())
            ])
        ])
        let report = run.connect(portPath: portPath)
        XCTAssertEqual(report.phase, .ready(.activeContinuationMeasurementStream))
        assertEdgeIsClosed(after: report, token: token, "aktiver Erfolg")
    }

    /// Ein **spät** angeforderter Abbruch beeinflusst den ausdrücklichen
    /// Schluss-Retry nicht: Er wurde nie einer Kante zugeordnet und kann
    /// den eigenen, frischen Retry-Lauf deshalb nicht beenden.
    func testALateAbortDoesNotAffectAnExplicitRetryClose() throws {
        let token = CommissioningAbortToken()
        let (run, transport, _) = makeRun(abortToken: token)
        transport.alwaysFailClose = .openFailed(Self.closeMarker)
        transport.onRead = { [weak run] in run?.requestAbort() }

        let report = run.connect(portPath: portPath)
        XCTAssertEqual(report.phase, .failed(.portCloseFailed))
        XCTAssertTrue(report.isPortHeld)

        // **Nach** der Rückkehr angefordert -- wirkungslos.
        token.requestAbort()
        transport.alwaysFailClose = nil
        let retried = run.retryClose()

        XCTAssertFalse(retried.isPortHeld, "Der Retry lief und gab wirklich frei")
        XCTAssertTrue(retried.isFinal)
        XCTAssertEqual(retried.phase, .failed(.aborted), "Der ursprüngliche Anlass bleibt der Ausgang")
    }

    /// Derselbe injizierte Token, ein **neuer** Lauf: Eine zwischen den
    /// Läufen eingegangene Anforderung vergiftet ihn nicht.
    func testALateAbortDoesNotPoisonALaterRunSharingTheSameToken() throws {
        let token = CommissioningAbortToken()
        let (first, firstTransport, _) = makeRun(abortToken: token)
        firstTransport.readScript = [.standardFrame(standardScanProfileFrame())]
        XCTAssertEqual(first.connect(portPath: portPath).phase, .ready(.passiveScanProfile))

        token.requestAbort()

        let clock = TestMonotonicClock()
        let secondTransport = ScriptedStandardConnectionTransport(clock: clock)
        let second = StandardConnectionRun(
            transport: secondTransport,
            passwordStore: TrackingScannerPasswordStore(),
            clock: clock,
            abortToken: token
        )
        secondTransport.readScript = [.standardFrame(standardScanProfileFrame())]

        XCTAssertEqual(
            second.connect(portPath: portPath).phase, .ready(.passiveScanProfile),
            "Unvergiftet -- die Anforderung fand keine reservierte Kante vor"
        )
    }

    // MARK: - Pflichtnachweis 4: Der manuelle Executor-Vertrag bleibt

    /// Ein direkter ``CommissioningExecutor/perform(_:secret:)``
    /// verwaltet **weiterhin seine eigene** Kante (SICK-0330a-1-K2/K3):
    /// Er schließt sie an seiner Rückkehr, und ein danach angeforderter
    /// Abbruch trifft den nächsten Aufruf nicht.
    func testTheManualPerformStillManagesItsOwnEdge() throws {
        let clock = TestMonotonicClock()
        let transport = ScriptedStandardConnectionTransport(clock: clock)
        let token = CommissioningAbortToken()
        let executor = CommissioningExecutor(transport: transport, clock: clock, abortToken: token)

        transport.readScript = [.standardFrame(standardIdentityResponseFrame())]
        let first = executor.perform(.checkStartingRate)
        XCTAssertEqual(first.phase, .respondingAtStartingRate)

        // Die Kante des Aufrufs ist geschlossen -- eine jetzt eingehende
        // Anforderung verpufft.
        token.requestAbort()
        XCTAssertFalse(token.isAbortRequested)

        transport.readScript = [.standardFrame(standardAcknowledgementFrame())]
        let second = executor.perform(.finishSession)
        XCTAssertEqual(second.phase, .sessionFinished, "Der Folgeaufruf lief unvergiftet")
    }

    /// Die geliehene Kante ist die Gegenprobe dazu: Sie wird vom
    /// Aufrufer verwaltet und bleibt nach dem Teilschritt **reserviert**.
    func testTheLoanedEdgeStaysReservedAcrossDelegatedSteps() throws {
        let clock = TestMonotonicClock()
        let transport = ScriptedStandardConnectionTransport(clock: clock)
        let token = CommissioningAbortToken()
        let executor = CommissioningExecutor(transport: transport, clock: clock, abortToken: token)
        let edge = token.beginRunIfNeeded()

        transport.readScript = [.standardFrame(standardIdentityResponseFrame())]
        let stepOutcome = executor.performUsingLoanedEdge(.checkStartingRate, edge: edge)
        XCTAssertEqual(stepOutcome.phase, .respondingAtStartingRate)

        token.requestAbort()
        XCTAssertTrue(
            token.isAbortRequested,
            "Die geliehene Kante ist nach dem Teilschritt weiterhin reserviert -- genau das schließt die Lücken"
        )
        token.endRun(edge)
    }

    // MARK: - Pflichtnachweis 5: Schlussdominanz und genau ein Retry (K1-3)

    /// **Schließfehler nach einem Abbruch im eigenen Politik-Teil**: Der
    /// eigene, echte Schließversuch scheitert. Öffentlich zählt der
    /// Schluss, nicht der Abbruch.
    func testACloseFailureAfterAnAbortIsDominantAndExactlyOneRetryReleases() throws {
        let (run, transport, _) = makeRun()
        transport.onRead = { [weak run] in run?.requestAbort() }
        transport.alwaysFailClose = .openFailed(Self.closeMarker)

        let report = run.connect(portPath: portPath)

        XCTAssertEqual(report.phase, .failed(.portCloseFailed), "Der Schluss ist dominant, nicht der Abbruch")
        XCTAssertTrue(report.isPortHeld)
        XCTAssertFalse(report.isFinal)
        XCTAssertNil(report.audit.commissioning, "Der delegierte Teil wurde nie erreicht")

        let closesBefore = transport.log.filter { $0 == .close }.count
        transport.alwaysFailClose = nil
        let retried = run.retryClose()

        XCTAssertEqual(
            transport.log.filter { $0 == .close }.count, closesBefore + 1,
            "**Genau ein** realer Schließversuch je Retry"
        )
        XCTAssertFalse(retried.isPortHeld)
        XCTAssertTrue(retried.isFinal)
        XCTAssertEqual(retried.phase, .failed(.aborted), "Der ursprüngliche Anlass kehrt zurück")
    }

    /// **Der exakte B1→MMK-Schlussnachweis** (Supervisor-Korrektur H3,
    /// Pflichtnachweis 5).
    ///
    /// Der Haltepunkt ist die Fortschrittsmeldung
    /// ``StandardConnectionCommissioningStage/adoptingConfirmedIdentity``
    /// -- sie liegt nachweislich **nach** der belegten B1-Antwort und
    /// **vor** der Übernahme durch den ``CommissioningExecutor``. Genau
    /// hier wechselt der Eigentümer des Ports: Noch führt ihn die eigene
    /// Politik-Buchführung, gleich der Executor. Ein Abbruch in diesem
    /// Augenblick lässt den Lauf den Port **selbst** schließen -- und
    /// ein dabei scheiterndes `closePort()` ist öffentlich dominant.
    ///
    /// Kein künstlicher Test-Hook: Der Haltepunkt ist dieselbe
    /// Fortschrittsmeldung, die H2 ohnehin verlangt.
    func testACloseFailureAtTheConfirmedIdentityHandoffIsDominantAndExactlyOneRetryReleases() throws {
        let reachedHandoff = DispatchSemaphore(value: 0)
        let abortRequested = DispatchSemaphore(value: 0)

        var run: StandardConnectionRun!
        let (createdRun, transport, passwordStore) = makeRun { report in
            guard case .runningCommissioning(
                .adoptingConfirmedIdentity, .activeContinuationFromConfirmedIdentity
            ) = report.phase else { return }
            XCTAssertTrue(
                report.isPortHeld,
                "Am Eigentümerwechsel ist der 38.400-Port wahr gehalten -- noch von der eigenen Buchführung"
            )
            XCTAssertFalse(report.isFinal)
            reachedHandoff.signal()
            abortRequested.wait()
        }
        run = createdRun
        // Lesevorgang 1 ist der passive Fast Path (läuft leer ab),
        // Lesevorgang 2 liefert die belegte B1-Antwort.
        stageReads(transport, [(at: 2, frames: [.standardFrame(standardIdentityResponseFrame())])])

        var report: StandardConnectionReport?
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            report = run.connect(portPath: self.portPath)
            finished.signal()
        }

        XCTAssertEqual(reachedHandoff.wait(timeout: .now() + 5), .success, "Die Übergabe wurde nie erreicht")
        transport.alwaysFailClose = .openFailed(Self.closeMarker)
        run.requestAbort()
        abortRequested.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "Der Lauf kehrte nicht zurück")

        let finalReport = try XCTUnwrap(report)
        XCTAssertEqual(
            finalReport.phase, .failed(.portCloseFailed),
            "Am B1→MMK-Handoff ist der gescheiterte Schluss dominant, nicht der Abbruch"
        )
        XCTAssertTrue(finalReport.isPortHeld, "Der Port bleibt sichtbar belegt")
        XCTAssertFalse(finalReport.isFinal, "Ein gescheiterter Schluss ist nie final")
        XCTAssertNil(finalReport.audit.commissioning, "Der delegierte Teil begann nie -- die Übernahme blieb aus")
        XCTAssertEqual(
            transport.writtenPayloads.count, 1,
            "Nur die eine B1-Probe -- kein MMK-Telegramm, kein Login, kein Baudtelegramm"
        )
        XCTAssertEqual(passwordStore.loadCount, 0, "Kein Passwortzugriff")
        assertNoMarkerLeaks(finalReport, "Schließen am B1→MMK-Handoff")

        let closesBefore = transport.log.filter { $0 == .close }.count
        transport.alwaysFailClose = nil
        let retried = run.retryClose()

        XCTAssertEqual(
            transport.log.filter { $0 == .close }.count, closesBefore + 1,
            "**Genau ein** realer Schließversuch je Retry"
        )
        XCTAssertFalse(retried.isPortHeld, "Der eine Retry gibt wirklich frei")
        XCTAssertTrue(retried.isFinal)
        XCTAssertEqual(retried.phase, .failed(.aborted), "Der ursprüngliche Anlass kehrt zurück")
    }

    /// Ein **erneut** fehlschlagender Retry bleibt ehrlich offen.
    func testARepeatedlyFailingRetryStaysHonestlyOpen() throws {
        let (run, transport, _) = makeRun()
        transport.onRead = { [weak run] in run?.requestAbort() }
        transport.alwaysFailClose = .openFailed(Self.closeMarker)

        XCTAssertEqual(run.connect(portPath: portPath).phase, .failed(.portCloseFailed))

        let firstRetry = run.retryClose()
        XCTAssertEqual(firstRetry.phase, .failed(.portCloseFailed))
        XCTAssertTrue(firstRetry.isPortHeld)
        XCTAssertFalse(firstRetry.isFinal)

        let secondRetry = run.retryClose()
        XCTAssertEqual(secondRetry.phase, .failed(.portCloseFailed))
        XCTAssertTrue(secondRetry.isPortHeld, "Der Port bleibt sichtbar belegt")
        XCTAssertFalse(secondRetry.isFinal)

        transport.alwaysFailClose = nil
        let thirdRetry = run.retryClose()
        XCTAssertFalse(thirdRetry.isPortHeld, "Erst der gelungene Versuch gibt frei")
        XCTAssertTrue(thirdRetry.isFinal)
    }

    /// **Schließfehler während eines delegierten Abbruchs**: Der Abbruch
    /// trifft den Executor mitten im 9600-Fallback; sein abschließendes
    /// `closePort()` scheitert. Auch hier zählt öffentlich der Schluss.
    func testACloseFailureDuringADelegatedAbortIsDominantAndRetryable() throws {
        let (run, transport, _) = makeRun()
        var readCount = 0
        transport.onRead = { [weak run] in
            readCount += 1
            if readCount == 3 {
                transport.readScript = self.fallbackFrames
            } else if readCount == 4 {
                // Mitten im delegierten Login-/Baudwechsel-Warten.
                run?.requestAbort()
                transport.alwaysFailClose = .openFailed(Self.closeMarker)
            }
        }

        let report = run.connect(portPath: portPath)

        XCTAssertEqual(report.phase, .failed(.portCloseFailed))
        XCTAssertTrue(report.isPortHeld)
        XCTAssertFalse(report.isFinal)
        XCTAssertNotNil(report.audit.commissioning, "Der delegierte Teil war beteiligt")

        transport.alwaysFailClose = nil
        let retried = run.retryClose()
        XCTAssertFalse(retried.isPortHeld, "Der ausdrückliche Retry gibt wirklich frei")
        XCTAssertTrue(retried.isFinal)
        XCTAssertEqual(retried.phase, .failed(.aborted), "Der ursprüngliche Anlass kehrt zurück")
    }

    // MARK: - Pflichtnachweis 6: Redaktion der öffentlichen Grenze (K1-4)

    /// Ein unbekanntes Kommandobyte bei **B1@9600** erreicht die
    /// öffentliche Grenze nicht -- zwei verschiedene Bytes ergeben
    /// denselben Wert.
    func testTwoDifferentUnknownBytesAtNineSixHundredYieldTheSamePublicFailure() throws {
        func failure(commandByte: UInt8) -> StandardConnectionPhase {
            let (run, transport, _) = makeRun()
            stageReads(transport, [
                (at: 3, frames: [.standardFrame(standardUnexpectedResponseFrame(commandByte: commandByte))])
            ])
            return run.connect(portPath: portPath).phase
        }

        let first = failure(commandByte: 0x11)
        let second = failure(commandByte: 0x99)

        XCTAssertEqual(first, .failed(.startingRateUnexpectedResponse))
        XCTAssertEqual(first, second)
        XCTAssertFalse(String(describing: first).contains("11"))
        XCTAssertFalse(String(describing: second).contains("99"))
    }

    /// Dasselbe bei der **Zielverifikation** nach dem Baudwechsel.
    func testTwoDifferentUnknownBytesAtTheTargetVerificationYieldTheSamePublicFailure() throws {
        func failure(commandByte: UInt8) -> StandardConnectionPhase {
            let (run, transport, _) = makeRun()
            stageReads(transport, [(at: 3, frames: [
                .standardFrame(standardIdentityResponseFrame()),   // B1 @ 9600
                .standardFrame(standardAcknowledgementFrame()),    // Login-ACK
                .standardFrame(standardAcknowledgementFrame()),    // Baud-ACK
                .standardFrame(standardUnexpectedResponseFrame(commandByte: commandByte))
            ])])
            return run.connect(portPath: portPath).phase
        }

        let first = failure(commandByte: 0x11)
        let second = failure(commandByte: 0x99)

        XCTAssertEqual(first, .failed(.targetRateUnexpectedResponse))
        XCTAssertEqual(first, second)
        XCTAssertFalse(String(describing: first).contains("11"))
        XCTAssertFalse(String(describing: second).contains("99"))
    }

    /// Fachlich verschiedene Gründe bleiben trotz Redaktion
    /// **unterscheidbar** -- „still" ist nicht dasselbe wie „unerwartet"
    /// oder „unlesbar".
    func testSilentUnexpectedAndAmbiguousStayDistinguishable() throws {
        XCTAssertNotEqual(
            StandardConnectionFailure.startingRateSilent,
            StandardConnectionFailure.startingRateUnexpectedResponse
        )
        XCTAssertNotEqual(
            StandardConnectionFailure.startingRateUnexpectedResponse,
            StandardConnectionFailure.startingRateAmbiguousResponse
        )
        XCTAssertNotEqual(
            StandardConnectionFailure.startingRateSilent,
            StandardConnectionFailure.targetRateSilent
        )
    }

    /// Sucht `marker` rekursiv in jedem Kind eines Wertes -- bis
    /// `depth` Ebenen tief (Supervisor-Korrektur, Nachweis 2).
    ///
    /// **Warum zusätzlich zu `String(describing:)`:** Eine
    /// Textdarstellung könnte einen eingebetteten Rohwert theoretisch
    /// verkürzen oder auslassen; der Spiegel geht an jedem Kindknoten
    /// vorbei an der Darstellung direkt auf den gespeicherten Wert.
    private func mirrorContains(_ marker: String, in value: Any, depth: Int) -> Bool {
        if let text = value as? String, text.contains(marker) { return true }
        if String(describing: value).contains(marker) { return true }
        guard depth > 0 else { return false }
        for child in Mirror(reflecting: value).children {
            if let label = child.label, label.contains(marker) { return true }
            if mirrorContains(marker, in: child.value, depth: depth - 1) { return true }
        }
        return false
    }

    /// **Kein markierter Fremdtext erreicht Phase, Bericht, Audit,
    /// Nutzertext, `String(describing:)`, `String(reflecting:)` oder
    /// einen rekursiven `Mirror` bis Tiefe 5.**
    private func assertNoMarkerLeaks(
        _ report: StandardConnectionReport, _ label: String, line: UInt = #line
    ) {
        let surfaces: [(String, String)] = [
            ("Bericht (describing)", String(describing: report)),
            ("Bericht (reflecting)", String(reflecting: report)),
            ("Phase (describing)", String(describing: report.phase)),
            ("Phase (reflecting)", String(reflecting: report.phase)),
            ("Audit (describing)", String(describing: report.audit)),
            ("Audit (reflecting)", String(reflecting: report.audit))
        ]
        for marker in [Self.openMarker, Self.writeMarker, Self.closeMarker] {
            for (surface, rendered) in surfaces {
                XCTAssertFalse(rendered.contains(marker), "\(label): \(marker) in \(surface)", line: line)
            }
            XCTAssertFalse(
                mirrorContains(marker, in: report, depth: 5),
                "\(label): \(marker) im rekursiven Mirror des Berichts", line: line
            )
        }
        guard case .failed(let failure) = report.phase else { return }
        for marker in [Self.openMarker, Self.writeMarker, Self.closeMarker] {
            XCTAssertFalse(
                failure.operatorSummary.contains(marker), "\(label): \(marker) im Nutzertext", line: line
            )
        }
        XCTAssertFalse(failure.operatorSummary.isEmpty, "\(label): jeder Fall hat einen Satz", line: line)
    }

    /// **Der Test belegt zuerst, dass sein Marker im unteren Rohwert
    /// tatsächlich vorhanden ist** (Supervisor-Korrektur, Nachweis 2) --
    /// ohne diesen positiven Gegenbeweis liefe jede Abwesenheitsprüfung
    /// oben möglicherweise ins Leere.
    ///
    /// Zugleich ist das der exakte Wert, den
    /// ``StandardConnectionPhase/runningCommissioning(_:origin:)`` vor
    /// der Korrektur als Assoziativwert **tragen konnte**: Er ist
    /// weiterhin frei konstruierbar, erreicht die öffentliche
    /// Standardgrenze aber nicht mehr, weil sie ihn typseitig nicht mehr
    /// kennt.
    func testTheMarkerIsReallyPresentInTheLowerRawValue() throws {
        let rawLowerPhase = CommissioningPhase.failed(.writeFailed(Self.writeMarker))

        XCTAssertTrue(
            String(describing: rawLowerPhase).contains(Self.writeMarker),
            "Der Marker steht im unteren Rohwert -- sonst prüfte die Redaktion nichts"
        )
        XCTAssertTrue(
            String(reflecting: rawLowerPhase).contains(Self.writeMarker),
            "Auch `String(reflecting:)` zeigt ihn"
        )
        XCTAssertTrue(
            mirrorContains(Self.writeMarker, in: rawLowerPhase, depth: 5),
            "Auch der rekursive Mirror findet ihn"
        )
    }

    /// Gegenrichtung zur Typgrenze: Der **eigene**, datenfreie
    /// Fortschrittstyp kann einen Fremdtext gar nicht führen -- er hat
    /// keinen einzigen Assoziativwert.
    func testTheOwnCommissioningStageCarriesNoPayloadAtAll() throws {
        let everyStage: [StandardConnectionCommissioningStage] = [
            .adoptingConfirmedIdentity, .checkingStartingRate, .respondingAtStartingRate,
            .loggingInAndSwitchingBaudRate, .verifiedAtTargetRate, .awaitingMeasurementStream,
            .runningRateDiagnostics, .rateDiagnosticsFinished, .sessionFinished
        ]
        for stage in everyStage {
            XCTAssertTrue(
                Mirror(reflecting: stage).children.isEmpty,
                "\(stage) trägt einen Assoziativwert -- der Fortschrittstyp bleibt datenfrei"
            )
            let phase = StandardConnectionPhase.runningCommissioning(
                stage, origin: .fallbackFromStartingRate
            )
            for marker in [Self.openMarker, Self.writeMarker, Self.closeMarker] {
                XCTAssertFalse(mirrorContains(marker, in: phase, depth: 5))
            }
        }
    }

    func testAMarkedOpenFailureTextNeverReachesThePublicBoundary() throws {
        let (run, transport, _) = makeRun()
        transport.failNextOpen = .openFailed(Self.openMarker)
        let report = run.connect(portPath: portPath)
        XCTAssertEqual(report.phase, .failed(.portOpenFailed))
        assertNoMarkerLeaks(report, "Öffnen")
    }

    func testAMarkedWriteFailureTextNeverReachesThePublicBoundary() throws {
        let (run, transport, _) = makeRun()
        transport.failNextWrite = .writeFailed(Self.writeMarker)
        let report = run.connect(portPath: portPath)
        XCTAssertEqual(report.phase, .failed(.portWriteFailed))
        assertNoMarkerLeaks(report, "Senden")
    }

    func testAMarkedCloseFailureTextNeverReachesThePublicBoundary() throws {
        let (run, transport, _) = makeRun()
        transport.alwaysFailClose = .openFailed(Self.closeMarker)
        transport.onRead = { [weak run] in run?.requestAbort() }
        let report = run.connect(portPath: portPath)
        XCTAssertEqual(report.phase, .failed(.portCloseFailed))
        assertNoMarkerLeaks(report, "Schließen")
    }

    /// Auch ein Fremdtext **innerhalb** des delegierten Teils bleibt
    /// draußen -- dort entsteht er in `CommissioningFailure.writeFailed`.
    func testAMarkedWriteFailureInsideTheDelegatedPartAlsoStaysOut() throws {
        let (run, transport, _) = makeRun()
        var readCount = 0
        transport.onRead = {
            readCount += 1
            if readCount == 3 {
                transport.readScript = [.standardFrame(standardIdentityResponseFrame())]
                transport.failNextWrite = .writeFailed(Self.writeMarker)
            }
        }
        let report = run.connect(portPath: portPath)
        XCTAssertEqual(report.phase, .failed(.portWriteFailed))
        assertNoMarkerLeaks(report, "Senden im delegierten Teil")
    }

    /// Jeder öffentliche Fall trägt einen festen, nicht interpolierten
    /// Satz (K1-4, letzte Regel).
    func testEveryPublicFailureHasAFixedOperatorText() throws {
        let everyFailure: [StandardConnectionFailure] = [
            .aborted, .invalidPort(.empty), .invalidPort(.pathNotAllowed("/dev/tty.irgendwas")),
            .portOpenFailed, .portReadFailed, .portWriteFailed, .portCloseFailed,
            .missingOrUnusablePassword, .unexpectedEvent,
            .startingRateSilent, .startingRateUnexpectedResponse, .startingRateAmbiguousResponse,
            .loginRejected, .loginUnanswered, .loginAmbiguous,
            .baudSwitchRejected, .baudSwitchUnanswered, .baudSwitchAmbiguous,
            .targetRateSilent, .targetRateUnexpectedResponse, .targetRateAmbiguousResponse,
            .measurementModeRejected, .measurementStreamAbsent
        ]
        for failure in everyFailure {
            XCTAssertFalse(failure.operatorSummary.isEmpty, "\(failure) ohne Satz")
            XCTAssertFalse(
                failure.operatorSummary.contains("/dev/"),
                "\(failure): kein Pfad im Nutzertext -- nichts wird interpoliert"
            )
        }
    }

    // MARK: - Pflichtnachweis 7: Die beobachtbare Fortschrittsfolge (K1-5)

    private func recordingRun(
        passwordStore: TrackingScannerPasswordStore = TrackingScannerPasswordStore()
    ) -> (StandardConnectionRun, ScriptedStandardConnectionTransport, Recorder) {
        let recorder = Recorder()
        let clock = TestMonotonicClock()
        let transport = ScriptedStandardConnectionTransport(clock: clock)
        let run = StandardConnectionRun(
            transport: transport,
            passwordStore: passwordStore,
            clock: clock,
            onProgress: { recorder.reports.append($0) }
        )
        return (run, transport, recorder)
    }

    final class Recorder {
        var reports: [StandardConnectionReport] = []
        var phases: [StandardConnectionPhase] { reports.map(\.phase) }
    }

    func testThePassivePathReportsObservingThenTheFinalReadyState() throws {
        let (run, transport, recorder) = recordingRun()
        transport.readScript = [.standardFrame(standardScanProfileFrame())]

        let report = run.connect(portPath: portPath)

        XCTAssertEqual(recorder.phases, [.observingPassively, .ready(.passiveScanProfile)])
        XCTAssertEqual(recorder.reports.last, report, "Der letzte Fortschritt **ist** der Endbericht")
        XCTAssertTrue(recorder.reports[0].isPortHeld, "Beim passiven Beobachten ist der Port wirklich offen")
        XCTAssertFalse(recorder.reports[0].isFinal)
    }

    func testTheActiveContinuationReportsEveryNamedPhaseInOrder() throws {
        let (run, transport, recorder) = recordingRun()
        stageReads(transport, [
            (at: 2, frames: [
                .standardFrame(standardIdentityResponseFrame()),
                .standardFrame(standardScanProfileFrame())
            ])
        ])

        _ = run.connect(portPath: portPath)

        XCTAssertEqual(recorder.phases, [
            .observingPassively,
            .checkingIdentityAtTargetRate,
            .runningCommissioning(.adoptingConfirmedIdentity, origin: .activeContinuationFromConfirmedIdentity),
            .runningCommissioning(.verifiedAtTargetRate, origin: .activeContinuationFromConfirmedIdentity),
            .runningCommissioning(.awaitingMeasurementStream, origin: .activeContinuationFromConfirmedIdentity),
            .ready(.activeContinuationMeasurementStream)
        ])
        for (index, report) in recorder.reports.enumerated() {
            XCTAssertTrue(report.isPortHeld, "Schritt \(index): der Port ist durchgehend wirklich gehalten")
        }
    }

    func testTheNineSixHundredFallbackReportsEveryNamedPhaseInOrder() throws {
        let (run, transport, recorder) = recordingRun()
        stageReads(transport, [(at: 3, frames: fallbackFrames)])

        _ = run.connect(portPath: portPath)

        XCTAssertEqual(recorder.phases, [
            .observingPassively,
            .checkingIdentityAtTargetRate,
            .runningCommissioning(.checkingStartingRate, origin: .fallbackFromStartingRate),
            .runningCommissioning(.respondingAtStartingRate, origin: .fallbackFromStartingRate),
            .runningCommissioning(.loggingInAndSwitchingBaudRate, origin: .fallbackFromStartingRate),
            .runningCommissioning(.verifiedAtTargetRate, origin: .fallbackFromStartingRate),
            .runningCommissioning(.awaitingMeasurementStream, origin: .fallbackFromStartingRate),
            .ready(.commissioningFallbackMeasurementStream)
        ])
        // **Erst die Länge, dann der Index** -- sonst stürzt der
        // Testprozess bei einer fehlenden Meldung ab, statt lesbar
        // fehlzuschlagen, und eine Gegenprobe belegte nichts
        // (dieselbe Lehre wie SICK-032a3).
        try XCTSkipIf(recorder.reports.count != 8, "Die Fortschrittsfolge ist bereits oben belegt")

        XCTAssertFalse(
            recorder.reports[2].isPortHeld,
            "Beim Eintritt in die Ausgangsprüfung ist der 38.400-Port wirklich geschlossen"
        )
        XCTAssertTrue(
            recorder.reports[3].isPortHeld,
            "Nach der bestätigten Ausgangsprüfung hält der delegierte Teil den Port wirklich"
        )
        XCTAssertTrue(
            recorder.reports[4].isPortHeld,
            "Vor Login/Baudwechsel/Zielverifikation ist der 9600-Port wahr gehalten"
        )
        XCTAssertTrue(recorder.reports[5].isPortHeld)
        XCTAssertTrue(
            recorder.reports[6].isPortHeld,
            "Vor der MMK-Stromwartephase ist der 38.400-Port wahr gehalten"
        )
        for (index, report) in recorder.reports.dropLast().enumerated() {
            XCTAssertFalse(report.isFinal, "Schritt \(index): ein Zwischenzustand ist nie final")
        }
    }

    /// **Supervisor-Korrektur H2, ausdrücklich benannt:** Die drei
    /// blockierenden Commissioning-Abschnitte werden **vor ihrer Wirkung**
    /// gemeldet -- nicht als anders benannte Stellvertreterphase.
    ///
    /// Geprüft wird nicht nur, *dass* die Namen vorkommen, sondern dass
    /// jeder vor der Gerätewirkung steht, zu der er gehört: Der
    /// Transport zählt mit, wie viele Sendungen zum Zeitpunkt der
    /// Meldung bereits hinausgegangen waren.
    func testTheThreeBlockingCommissioningSectionsAreNamedBeforeTheirEffect() throws {
        let recorder = Recorder()
        var writesWhenReported: [StandardConnectionCommissioningStage: Int] = [:]
        let clock = TestMonotonicClock()
        let transport = ScriptedStandardConnectionTransport(clock: clock)
        let run = StandardConnectionRun(
            transport: transport,
            passwordStore: TrackingScannerPasswordStore(),
            clock: clock,
            onProgress: { report in
                recorder.reports.append(report)
                if case .runningCommissioning(let stage, _) = report.phase {
                    writesWhenReported[stage] = transport.writtenPayloads.count
                }
            }
        )
        stageReads(transport, [(at: 3, frames: fallbackFrames)])

        _ = run.connect(portPath: portPath)

        // Vor der Ausgangsprüfung: nur die eine B1-Probe bei 38.400.
        XCTAssertEqual(
            writesWhenReported[.checkingStartingRate], 1,
            "Die Ausgangsprüfung wird gemeldet, **bevor** die B1-Probe bei 9600 hinausgeht"
        )
        // Vor Login/Baudwechsel: B1@38400 und B1@9600, sonst nichts.
        XCTAssertEqual(
            writesWhenReported[.loggingInAndSwitchingBaudRate], 2,
            "Login/Baudwechsel/Zielverifikation wird gemeldet, **bevor** das Login hinausgeht"
        )
        // Vor der MMK-Stromwartephase: zusätzlich Einstellungsmodus,
        // Login, Baudtelegramm und B1-Zielverifikation -- das
        // MMK-Telegramm noch nicht.
        XCTAssertEqual(
            writesWhenReported[.awaitingMeasurementStream], 6,
            "Die MMK-Stromwartephase wird gemeldet, **bevor** das MMK-Telegramm hinausgeht"
        )
        XCTAssertEqual(
            transport.writtenPayloads.count, 7,
            "Insgesamt sieben Sendungen -- die MMK-Anforderung kam erst nach ihrer Meldung"
        )
    }

    func testEveryFailureClassIsReportedAsAFinalProgressEntry() throws {
        let cases: [(String, (ScriptedStandardConnectionTransport, StandardConnectionRun) -> Void, StandardConnectionPhase)] = [
            ("Öffnen", { transport, _ in transport.failNextOpen = .openFailed(Self.openMarker) },
             .failed(.portOpenFailed)),
            ("Lesen", { transport, _ in transport.readScript = [.closed] },
             .failed(.portReadFailed)),
            ("Senden", { transport, _ in transport.failNextWrite = .writeFailed(Self.writeMarker) },
             .failed(.portWriteFailed)),
            ("Abbruch", { transport, run in transport.onRead = { [weak run] in run?.requestAbort() } },
             .failed(.aborted))
        ]
        for (label, arrange, expected) in cases {
            let (run, transport, recorder) = recordingRun()
            arrange(transport, run)
            let report = run.connect(portPath: portPath)
            XCTAssertEqual(report.phase, expected, label)
            XCTAssertEqual(recorder.reports.last, report, "\(label): der Endbericht wird gemeldet")
        }
    }

    func testTheInvalidPortEndIsAlsoReportedAsAFinalProgressEntry() throws {
        let (run, _, recorder) = recordingRun()
        let report = run.connect(portPath: "kein-gueltiger-anschluss")
        XCTAssertEqual(recorder.reports.count, 1)
        XCTAssertEqual(recorder.reports.last, report)
    }

    func testEachCloseRetryIsItsOwnFinalProgressEntry() throws {
        let (run, transport, recorder) = recordingRun()
        transport.alwaysFailClose = .openFailed(Self.closeMarker)
        transport.onRead = { [weak run] in run?.requestAbort() }

        _ = run.connect(portPath: portPath)
        let afterConnect = recorder.reports.count
        _ = run.retryClose()
        _ = run.retryClose()
        transport.alwaysFailClose = nil
        let released = run.retryClose()

        XCTAssertEqual(
            recorder.reports.count, afterConnect + 3,
            "Jeder ausdrückliche Retry meldet seinen eigenen Endbericht -- auch der wiederholt gescheiterte"
        )
        XCTAssertEqual(recorder.reports.last, released)
        XCTAssertTrue(released.isFinal)
    }

    /// **Reine Zustandsbeobachtung erzeugt null zusätzliche
    /// Transportoperationen** (K1-5): Derselbe Lauf mit und ohne
    /// Fortschrittsgrenze berührt den Transport identisch.
    func testObservingProgressCausesNoAdditionalTransportOperations() throws {
        let (silentRun, silentTransport, _) = makeRun()
        stageReads(silentTransport, [(at: 3, frames: fallbackFrames)])
        _ = silentRun.connect(portPath: portPath)

        let (observedRun, observedTransport, recorder) = recordingRun()
        stageReads(observedTransport, [(at: 3, frames: fallbackFrames)])
        _ = observedRun.connect(portPath: portPath)

        XCTAssertFalse(recorder.reports.isEmpty, "Die Prüfung liefe ins Leere ohne Fortschrittsmeldungen")
        XCTAssertEqual(
            observedTransport.log, silentTransport.log,
            "Der Fortschrittssink löst keine einzige weitere Gerätewirkung aus"
        )
    }
}
