import Foundation
import XCTest
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl
import SickPLSMacTransport

/// Die Bediennachweise von SICK-032a.
///
/// **Alle Nachweise laufen gegen Fakes und Spione** — kein echter Port,
/// kein TX, keine Hardware, keine PTY, kein Capture und kein echter
/// Geheimniswert.
final class CommissioningControlModelTests: XCTestCase {

    // MARK: - Bedienvertrag 1: Vorabinformation

    func testTheBriefingNamesPortStartTargetEffectAndTheOnlyKnownWayBack() {
        let harness = ControlHarness(portPath: "/dev/cu.usbserial-TEST")
        let briefing = harness.model.briefing

        XCTAssertEqual(briefing.portPath, "/dev/cu.usbserial-TEST")
        XCTAssertEqual(briefing.startingBaudRate, .baud9600)
        XCTAssertEqual(briefing.targetBaudRate, .baud38400)

        let text = briefing.lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("/dev/cu.usbserial-TEST"))
        XCTAssertTrue(text.contains("9600"))
        XCTAssertTrue(text.contains("38400"))
        XCTAssertTrue(text.contains("8E1"))
        XCTAssertTrue(text.contains("actively configures the scanner"))
        XCTAssertTrue(text.contains("restart"), "Der einzige bekannte Rückweg fehlt")
    }

    /// Der Rückweg-Hinweis wird **übernommen, nicht neu erfunden**.
    func testTheRecoveryHintIsTakenVerbatimFromTheModel() {
        let harness = ControlHarness()
        XCTAssertEqual(
            harness.model.briefing.recoveryHint,
            CommissioningFailure.abortedByOperator.recoveryHint
        )
    }

    /// **Kein freier Wähler**: Die Vorabinformation kennt genau die zwei
    /// Raten des Rezepts und bietet nichts Drittes an.
    func testTheBriefingOffersNoThirdRate() {
        let harness = ControlHarness()
        let rates = Set([harness.model.briefing.startingBaudRate, harness.model.briefing.targetBaudRate])
        XCTAssertEqual(rates, [.baud9600, .baud38400])
    }

    // MARK: - Bedienvertrag 2: kein Autostart

    func testCreatingTheModelSendsNothing() {
        let harness = ControlHarness()
        XCTAssertEqual(harness.provider.run.performCount, 0)
        XCTAssertEqual(harness.provider.requestedPaths, [])
        XCTAssertEqual(harness.coordinator.accessRequests, 0)
        XCTAssertFalse(harness.model.isRunning)
        XCTAssertNil(harness.model.phase)
    }

    func testRefreshingPortsAndReadinessSendsNothing() {
        let harness = ControlHarness()
        harness.listing.paths = ["/dev/cu.a", "/dev/cu.b"]
        harness.model.refreshPorts()
        harness.model.refreshReadiness()

        XCTAssertEqual(harness.model.availablePorts, ["/dev/cu.a", "/dev/cu.b"])
        XCTAssertEqual(harness.provider.run.performCount, 0)
        XCTAssertEqual(harness.coordinator.accessRequests, 0)
    }

    /// **Auch bei genau einem Port wird nichts von selbst gewählt.**
    func testASinglePortIsNeverSelectedAutomatically() {
        let harness = ControlHarness(portPath: "")
        harness.listing.paths = ["/dev/cu.only"]
        harness.model.refreshPorts()
        XCTAssertEqual(harness.model.selectedPortPath, "")
    }

    func testSelectingAPortSendsNothing() {
        let harness = ControlHarness(portPath: "")
        harness.model.selectPort("/dev/cu.other")
        XCTAssertEqual(harness.provider.run.performCount, 0)
        XCTAssertEqual(harness.coordinator.accessRequests, 0)
        XCTAssertNil(harness.model.pendingStep)
    }

    /// **Ein Besitzwechsel startet nichts.** Er aktualisiert nur die
    /// Anzeige — der Grund, warum das Modell den Koordinator überhaupt
    /// beobachtet.
    func testAnOwnershipChangeOnlyRefreshesTheDisplay() {
        let harness = ControlHarness()
        harness.coordinator.setOwner(.monitor)
        harness.coordinator.setOwner(.commissioning)
        harness.coordinator.setOwner(.free)

        XCTAssertEqual(harness.provider.run.performCount, 0)
        XCTAssertEqual(harness.dispatcher.backgroundWork.count, 0)
        XCTAssertEqual(harness.model.portOwner, .free)
    }

    /// **Der Portzugang selbst sendet nichts.**
    func testRequestingAccessSendsNothing() {
        let harness = ControlHarness()
        XCTAssertEqual(harness.model.requestAccess(), .granted)
        XCTAssertTrue(harness.model.hasPortAccess)
        XCTAssertEqual(harness.provider.run.performCount, 0)
        XCTAssertEqual(harness.dispatcher.backgroundWork.count, 0)
    }

    // MARK: - Bedienvertrag 2: Bestätigung zwingend

    func testRequestingAStepSendsNothingUntilItIsConfirmed() {
        let harness = ControlHarness()
        harness.model.requestAccess()

        XCTAssertEqual(harness.model.requestStep(.checkStartingRate), .awaitingConfirmation(.checkStartingRate))
        XCTAssertEqual(harness.model.pendingStep, .checkStartingRate)
        XCTAssertEqual(harness.provider.run.performCount, 0)
        XCTAssertEqual(harness.dispatcher.backgroundWork.count, 0)

        XCTAssertEqual(harness.model.confirmPendingStep(), .started(.checkStartingRate))
        harness.dispatcher.runToCompletion()
        XCTAssertEqual(harness.provider.run.commands, [.checkStartingRate])
    }

    func testConfirmingWithoutAPendingStepDoesNothing() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        XCTAssertEqual(harness.model.confirmPendingStep(), .refusedNoPendingStep)
        XCTAssertEqual(harness.provider.run.performCount, 0)
    }

    func testCancellingAPendingStepSendsNothing() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.model.requestStep(.checkStartingRate)
        harness.model.cancelPendingStep()

        XCTAssertNil(harness.model.pendingStep)
        XCTAssertEqual(harness.model.confirmPendingStep(), .refusedNoPendingStep)
        XCTAssertEqual(harness.provider.run.performCount, 0)
    }

    /// **Ein Portwechsel unter einem wartenden Schritt hinweg löscht
    /// ihn** — sonst bestätigte man etwas anderes als angezeigt.
    func testChangingThePortDropsAPendingStep() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.model.requestStep(.checkStartingRate)
        harness.model.selectPort("/dev/cu.another")

        XCTAssertNil(harness.model.pendingStep)
        XCTAssertEqual(harness.model.confirmPendingStep(), .refusedNoPendingStep)
        XCTAssertEqual(harness.provider.run.performCount, 0)
    }

    /// **Ohne Portzugang wird nichts ausgeführt** — auch nicht nach einer
    /// Bestätigung.
    func testConfirmingWithoutPortAccessExecutesNothing() {
        let harness = ControlHarness()
        harness.model.requestStep(.checkStartingRate)
        XCTAssertEqual(harness.model.confirmPendingStep(), .refusedWithoutPortAccess)
        XCTAssertEqual(harness.provider.run.performCount, 0)
        XCTAssertEqual(harness.provider.requestedPaths, [], "Es wurde nicht einmal ein Lauf hergestellt")
    }

    /// Ein Schritt, den die Lage nicht vorsieht, wird gar nicht erst
    /// angeboten. **Die Wahrheit bleibt der Reducer** — hier wird nur
    /// verhindert, dass ein Knopf in eine Verweigerung führt.
    func testAStepOutsideTheCurrentPhaseIsNotEvenOffered() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        XCTAssertEqual(harness.model.requestStep(.switchBaudRate), .refusedNotAllowed(.switchBaudRate))
        XCTAssertNil(harness.model.pendingStep)
        XCTAssertEqual(harness.provider.run.performCount, 0)
    }

    // MARK: - Bedienvertrag 3: genau ein Lauf, im Hintergrund

    func testASecondStepIsLockedWhileOneIsRunning() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.model.requestStep(.checkStartingRate)
        XCTAssertEqual(harness.model.confirmPendingStep(), .started(.checkStartingRate))

        // Der Lauf liegt in der Warteschlange und ist noch nicht fertig.
        XCTAssertTrue(harness.model.isRunning)
        XCTAssertEqual(harness.model.requestStep(.checkStartingRate), .refusedAlreadyRunning)
        XCTAssertEqual(harness.model.confirmPendingStep(), .refusedNoPendingStep)

        harness.dispatcher.runToCompletion()
        XCTAssertFalse(harness.model.isRunning)
        XCTAssertEqual(harness.provider.run.performCount, 1)
    }

    /// Und die Sperre gilt auch, wenn **während** des `perform` versucht
    /// wird, einen zweiten zu starten.
    func testNoSecondPerformOverlapsARunningOne() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.duringPerform = {
            // Dieser Aufruf kommt aus dem Ausführungsblock heraus -- mit
            // dem manuellen Dispatcher auf demselben Thread.
            harness.model.requestStep(.checkStartingRate)
            harness.model.confirmPendingStep()
        }
        harness.runStep(.checkStartingRate)

        XCTAssertEqual(harness.provider.run.overlaps, 0)
        XCTAssertEqual(harness.provider.run.performCount, 1)
    }

    /// **Pflichtnachweis (SICK-0330a-1-K2):** ``CommissioningAborting/beginRun()``
    /// wird **synchron, noch bevor der Hintergrundaufruf überhaupt
    /// eingeplant wird**, genau einmal je Lauf gerufen — nicht erst, wenn
    /// der Dispatcher ihn irgendwann tatsächlich abarbeitet. Mit dem
    /// ``ManualCommissioningDispatcher`` liegt zwischen "Schritt bestätigt"
    /// und "Hintergrundauftrag läuft wirklich" eine echte, beobachtbare
    /// Lücke — genau die Lücke, in der eine Abbruchanforderung sonst ins
    /// Leere liefe.
    func testBeginRunIsCalledSynchronouslyBeforeTheBackgroundCallIsEverDispatched() {
        let harness = ControlHarness()
        harness.model.requestAccess()

        harness.model.requestStep(.checkStartingRate)
        harness.model.confirmPendingStep()

        // Der Hintergrundauftrag liegt hier noch unangetastet in der
        // Warteschlange -- `beginRun()` muss trotzdem schon gezählt sein.
        XCTAssertEqual(
            harness.provider.run.beginRunCount, 1,
            "beginRun() muss vor dem Einplanen liegen, nicht erst im Hintergrundauftrag selbst"
        )
        XCTAssertEqual(harness.provider.run.performCount, 0, "perform() ist noch nicht gelaufen")

        harness.dispatcher.runToCompletion()

        XCTAssertEqual(harness.provider.run.performCount, 1)
        XCTAssertEqual(
            harness.provider.run.beginRunCount, harness.provider.run.performCount,
            "Genau ein beginRun() je perform() — keine zweite, verwaiste Reservierung"
        )

        // Ein zweiter, vollständiger Lauf reserviert erneut, genau einmal
        // -- `.finishSession` ist nach `.respondingAtStartingRate` ohne
        // Bestätigung erlaubt (`CommissioningStepPolicy`).
        harness.runStep(.finishSession)
        XCTAssertEqual(harness.provider.run.beginRunCount, 2)
        XCTAssertEqual(harness.provider.run.performCount, 2)
    }

    /// **`perform` läuft nicht auf dem Main Thread** — hier mit der
    /// **echten** ``SerialCommissioningDispatcher``.
    func testPerformRunsOffTheMainThreadWithTheRealDispatcher() {
        let coordinator = SpyPortCoordinator()
        let provider = SpyRunProvider()
        let model = CommissioningControlModel(
            coordinator: coordinator,
            runProvider: provider,
            dispatcher: SerialCommissioningDispatcher(),
            portListing: FakeSerialPortListing()
        )
        model.selectPort("/dev/cu.usbserial-TEST")
        model.requestAccess()
        provider.run.scriptedReports = [StepReportFactory.hold(phase: .respondingAtStartingRate)]

        let finished = expectation(description: "Bericht zugestellt")
        model.requestStep(.checkStartingRate)
        XCTAssertEqual(model.confirmPendingStep(), .started(.checkStartingRate))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finished.fulfill() }
        // Das Limit begrenzt eine Flake; der Vertrag steht in den Prüfungen danach.
        wait(for: [finished], timeout: 10.0)

        XCTAssertEqual(provider.run.ranOnMainThread, [false], "`perform` lief auf dem Main Thread")
        XCTAssertEqual(model.phase, .respondingAtStartingRate)
    }

    /// **Der Bericht erreicht zuerst den Main Thread**, und erst dort
    /// wird der Abschluss gerufen — ebenfalls mit der echten Ausführung.
    func testTheReportReachesTheMainThreadBeforeCompletion() {
        let coordinator = SpyPortCoordinator()
        let provider = SpyRunProvider()
        let model = CommissioningControlModel(
            coordinator: coordinator,
            runProvider: provider,
            dispatcher: SerialCommissioningDispatcher(),
            portListing: FakeSerialPortListing()
        )
        model.selectPort("/dev/cu.usbserial-TEST")
        model.requestAccess()
        provider.run.scriptedReports = [StepReportFactory.final(phase: .sessionFinished)]

        let finished = expectation(description: "Abschluss zugestellt")
        model.requestStep(.checkStartingRate)
        model.confirmPendingStep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finished.fulfill() }
        // Das Limit begrenzt eine Flake; der Vertrag steht in den Prüfungen danach.
        wait(for: [finished], timeout: 10.0)

        XCTAssertEqual(coordinator.completionOnMainThread, [true])
        XCTAssertEqual(coordinator.completionReports.count, 1)
    }

    /// Der Abschluss kommt **nur** aus einem gelaufenen `perform`.
    /// Ohne Lauf wird nie freigegeben — auch nicht, wenn Zugang besteht.
    func testNoCompletionWithoutAnActualRun() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.model.refreshReadiness()
        harness.model.requestStep(.checkStartingRate)
        harness.model.cancelPendingStep()

        XCTAssertEqual(harness.coordinator.completionReports.count, 0)
        XCTAssertEqual(harness.model.releasedRunCount, 0)
    }

    // MARK: - Bedienvertrag 4: hold, final, Fehler

    func testAHoldShowsPhaseNextStepsAndTheHeldPort() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [StepReportFactory.hold(phase: .respondingAtStartingRate)]
        harness.runStep(.checkStartingRate)

        XCTAssertEqual(harness.model.phase, .respondingAtStartingRate)
        XCTAssertTrue(harness.model.isPortHeld)
        XCTAssertEqual(harness.model.allowedSteps, [.enterSettingsMode, .finishSession, .abort])
        XCTAssertEqual(harness.coordinator.completionReports.count, 0, "Ein `hold` schließt nichts ab")
        XCTAssertEqual(harness.model.releasedRunCount, 0)
    }

    func testAFinalReportReleasesExactlyOnce() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [StepReportFactory.final(phase: .sessionFinished)]
        harness.runStep(.checkStartingRate)

        XCTAssertEqual(harness.coordinator.completionReports.count, 1)
        XCTAssertEqual(harness.model.releasedRunCount, 1)
        XCTAssertFalse(harness.model.isPortHeld)
        XCTAssertEqual(harness.model.allowedSteps, [], "Nach der beendeten Sitzung gibt es keinen Schritt mehr")
    }

    /// **Ein Fehlschlag bleibt ein Fehlschlag.**
    func testAFailureIsNeverShownAsSuccessOrAsAPresumedTargetRate() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [StepReportFactory.final(phase: .failed(.loginUnanswered))]
        harness.runStep(.checkStartingRate)

        XCTAssertEqual(harness.model.phase, .failed(.loginUnanswered))
        XCTAssertNil(harness.model.verifiedBaudRate, "Ohne Beleg gibt es keine Rate")
        let message = try? XCTUnwrap(harness.model.notice?.message)
        // **Seit SICK-032a3 sagt der Hinweis, was schiefging** -- im
        // ersten realen Lauf stand das nur im Protokoll.
        XCTAssertEqual(
            message?.contains(CommissioningFailure.loginUnanswered.operatorSummary), true,
            "Der Befund selbst fehlt"
        )
        XCTAssertTrue(message?.contains("No response") == true)
        XCTAssertTrue(message?.contains("restart") == true, "Der Rückweg fehlt")
        // Die Diagnose ist von hier aus erlaubt -- und nur von hier.
        XCTAssertEqual(harness.model.allowedSteps, [.runRateDiagnostics, .finishSession])
    }

    /// **PN5 (SICK-0330a-1-K1, H2/H3):** Der echte Weg
    /// ControlModel → vorhandener Run → zweiter `perform(.finishSession)`
    /// → Koordinator. Ein gescheitertes Schließen hält Lauf **und**
    /// Besitz fest, bietet **ausschließlich** den erneuten Schließversuch
    /// an, behauptet nie „frei", und erst der erfolgreiche Folgebericht
    /// räumt Lauf und Besitz **genau einmal** auf.
    func testAFailedCloseKeepsTheRunAndOwnershipAliveForAnExplicitRetryThroughTheControlModel() throws {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [
            StepReportFactory.closeFailed(phase: .sessionFinished),
            StepReportFactory.final(phase: .sessionFinished)
        ]

        harness.runStep(.checkStartingRate)

        XCTAssertTrue(harness.model.isPortHeld, "Der Besitz bleibt sichtbar gehalten")
        XCTAssertEqual(
            harness.model.allowedSteps, [.finishSession],
            "Ausschließlich der erneute, ausdrückliche Schließversuch ist angeboten"
        )
        XCTAssertEqual(harness.coordinator.completionReports.count, 0, "Kein Abschluss ohne wirklich freien Port")
        XCTAssertEqual(harness.model.releasedRunCount, 0)
        let firstMessage = try XCTUnwrap(harness.model.notice?.message)
        XCTAssertFalse(firstMessage.contains("wieder frei"), "Nie \u{201E}frei\u{201C} behaupten, solange er es real nicht ist")
        XCTAssertEqual(firstMessage, CommissioningControlModel.closeFailedWhileStoppingText)

        // Der ausdrückliche Folgeversuch -- genau der eine angebotene Schritt.
        XCTAssertEqual(harness.model.performStep(.finishSession), .started(.finishSession))
        harness.dispatcher.runToCompletion()

        XCTAssertFalse(harness.model.isPortHeld)
        XCTAssertEqual(harness.model.allowedSteps, [])
        XCTAssertEqual(harness.coordinator.completionReports.count, 1, "Genau ein Abschluss -- beim wirklich finalen Bericht")
        XCTAssertEqual(harness.model.releasedRunCount, 1)
        XCTAssertEqual(harness.provider.run.performCount, 2, "Derselbe Lauf, zwei perform-Aufrufe")
        XCTAssertEqual(harness.provider.requestedPaths.count, 1, "Kein zweiter Lauf wurde hergestellt")
        let secondMessage = try XCTUnwrap(harness.model.notice?.message)
        XCTAssertTrue(secondMessage.contains("free again"))
    }

    /// **B1-verifizierte 38400 darf angezeigt werden** — und nur sie.
    func testOnlyAVerifiedRateIsShown() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [
            StepReportFactory.hold(phase: .verified, verifiedBaudRate: .baud38400)
        ]
        harness.runStep(.checkStartingRate)

        XCTAssertEqual(harness.model.verifiedBaudRate, .baud38400)
        XCTAssertTrue(harness.model.notice?.message.contains("38400") == true)
        XCTAssertTrue(harness.model.notice?.message.contains("CRC-valid") == true)
    }

    /// **Ein Messstrom ist nie ein Wechselerfolg** (Auflage A1).
    func testAnObservedScanProfileStreamIsNeverASwitchSuccess() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [
            StepReportFactory.final(
                phase: .failed(.verificationFailed(.timeout)),
                observedScanProfileStream: true
            )
        ]
        harness.runStep(.checkStartingRate)

        XCTAssertTrue(harness.model.observedScanProfileStream)
        XCTAssertNil(harness.model.verifiedBaudRate)
        let message = harness.model.notice?.message
        XCTAssertTrue(message?.contains("unconfirmed") == true, "Der Wechsel darf nie als belegt erscheinen")
        XCTAssertFalse(message?.contains("38400 Baud antwortet") == true)
    }

    /// **Der bestätigte Messstrom wird als belegt dargestellt**
    /// (SICK-0330a-0): `measurementStreamConfirmed` entsteht seither nur
    /// noch durch einen echten, CRC-validen B0-Frame nach der
    /// Anforderung — ein bloßes ACK erreicht diesen Zustand nicht mehr,
    /// also ist die Wirkung hier tatsächlich belegt.
    func testTheConfirmedMeasurementStreamIsShownAsProven() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [
            StepReportFactory.hold(phase: .measurementStreamConfirmed)
        ]
        harness.runStep(.checkStartingRate)

        let message = try? XCTUnwrap(harness.model.notice?.message)
        XCTAssertTrue(message?.contains("continuously sending measurements") == true)
        XCTAssertTrue(message?.contains("scan stream was observed") == true)
    }

    /// Nach einem Fehlschlag bleibt der Lauf bestehen — sonst wäre die
    /// Ratendiagnose unerreichbar, weil ein frischer Executor wieder bei
    /// `.idle` stünde. Der **Portzugang** muss dafür neu angefordert
    /// werden, weil der Fehlschlag ihn freigegeben hat.
    func testDiagnosticsAfterAFailureNeedFreshAccessButTheSameRun() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [
            StepReportFactory.final(phase: .failed(.loginUnanswered)),
            StepReportFactory.final(
                phase: .diagnosticsFinished(
                    CommissioningDiagnosticsReport(outcomeAtStartingRate: .timeout, outcomeAtTargetRate: .timeout)
                )
            )
        ]
        harness.runStep(.checkStartingRate)
        XCTAssertFalse(harness.model.hasPortAccess, "Ein Fehlschlag gibt den Port frei")

        harness.model.requestStep(.runRateDiagnostics)
        XCTAssertEqual(harness.model.confirmPendingStep(), .refusedWithoutPortAccess)

        harness.model.requestAccess()
        harness.model.requestStep(.runRateDiagnostics)
        XCTAssertEqual(harness.model.confirmPendingStep(), .started(.runRateDiagnostics))
        harness.dispatcher.runToCompletion()

        XCTAssertEqual(harness.provider.run.commands, [.checkStartingRate, .runRateDiagnostics])
        XCTAssertEqual(harness.provider.requestedPaths.count, 1, "Es wurde kein zweiter Lauf hergestellt")
    }

    // MARK: - Bedienvertrag 5: Portbereitschaft und Wartephase

    func testTheOwnershipWaitingPhaseIsVisible() {
        let harness = ControlHarness()
        harness.coordinator.accessOutcome = .awaitingMonitorRelease
        harness.coordinator.readiness = .awaitingPortRelease
        harness.coordinator.isAwaitingPortRelease = true

        XCTAssertEqual(harness.model.requestAccess(), .awaitingMonitorRelease)
        XCTAssertTrue(harness.model.isAwaitingPortRelease)
        XCTAssertEqual(harness.model.readiness, .awaitingPortRelease)
        XCTAssertFalse(harness.model.hasPortAccess)
        XCTAssertTrue(harness.model.notice?.message.contains("live display") == true)
        XCTAssertTrue(harness.model.notice?.message.contains("free") == true)
        XCTAssertEqual(harness.provider.run.performCount, 0)
    }

    func testReadinessComesFromTheCoordinator() {
        let harness = ControlHarness()
        harness.coordinator.readiness = .monitorMustDisconnectFirst
        harness.model.refreshReadiness()
        XCTAssertEqual(harness.model.readiness, .monitorMustDisconnectFirst)
        XCTAssertEqual(harness.coordinator.readinessQueries.last, "/dev/cu.usbserial-TEST")
    }

    func testWithoutAPortThereIsNoReadinessAndNoRun() {
        let harness = ControlHarness(portPath: "")
        harness.model.refreshReadiness()
        XCTAssertEqual(harness.model.readiness, .noPortSelected)

        harness.model.requestAccess()
        harness.model.requestStep(.checkStartingRate)
        XCTAssertEqual(harness.model.confirmPendingStep(), .refusedRunUnavailable(.noPortSelected))
        harness.dispatcher.runToCompletion()

        XCTAssertEqual(harness.provider.run.performCount, 0)
        XCTAssertEqual(harness.provider.requestedPaths, [], "Es wurde nicht einmal ein Lauf hergestellt")
    }

    /// Ein abgelehnter Lauf **ist sichtbar** und führt nichts aus.
    func testARefusedRunIsVisibleAndExecutesNothing() {
        let harness = ControlHarness(portPath: "/dev/cu.usbserial-TEST")
        harness.provider.failure = .pathNotAllowed("/dev/tty.usbserial-TEST")
        harness.model.requestAccess()
        harness.model.requestStep(.checkStartingRate)

        XCTAssertEqual(
            harness.model.confirmPendingStep(),
            .refusedRunUnavailable(.pathNotAllowed("/dev/tty.usbserial-TEST"))
        )
        XCTAssertEqual(harness.provider.run.performCount, 0)
        XCTAssertFalse(harness.model.isRunning)
        // Der Pfad ist unsere eigene, gerade geprüfte Auswahl -- er darf
        // und soll im Hinweis stehen.
        XCTAssertTrue(harness.model.notice?.message.contains("/dev/tty.usbserial-TEST") == true)
    }

    // MARK: - Bedienvertrag: das Scanner-Passwort (SICK-032a2)

    /// **Ohne eingetragenes Passwort geht nichts hinaus** — und der
    /// Hinweis verweist auf die Einstellungen, statt etwas abzufragen.
    func testTheSwitchStepRefusesWithoutAScannerPasswordAndSendsNothing() {
        let harness = ControlHarness(storedPassword: "")
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [StepReportFactory.hold(phase: .respondingAtStartingRate)]
        harness.runStep(.checkStartingRate)

        harness.model.requestStep(.enterSettingsMode)
        XCTAssertEqual(harness.model.confirmPendingStep(), .refusedScannerPassword(.notSet))
        XCTAssertEqual(harness.provider.run.commands, [.checkStartingRate])

        let message = harness.model.notice?.message ?? ""
        XCTAssertTrue(message.contains("Settings"), "The hint must reference Settings")
        XCTAssertTrue(message.contains("Nothing was sent"))
    }

    /// Ein untauglicher Eintrag wird abgelehnt, **ohne ihn zu nennen** —
    /// nicht aus Geheimhaltung, sondern weil er im Hinweis nichts
    /// beiträgt.
    func testAnUnusableScannerPasswordIsRefusedWithoutNamingIt() {
        let harness = ControlHarness(storedPassword: "ZUKURZ")
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [StepReportFactory.hold(phase: .respondingAtStartingRate)]
        harness.runStep(.checkStartingRate)

        harness.model.requestStep(.enterSettingsMode)
        XCTAssertEqual(harness.model.confirmPendingStep(), .refusedScannerPassword(.unusable))
        XCTAssertEqual(harness.provider.run.commands, [.checkStartingRate])

        let message = harness.model.notice?.message ?? ""
        XCTAssertFalse(message.contains("ZUKURZ"), "Der eingetragene Wert gehört nicht in den Hinweis")
        XCTAssertTrue(message.contains("Nothing was sent"))
    }

    /// Das Passwort geht nur in die beiden Schritte, deren Telegramme es
    /// tatsächlich enthalten.
    func testTheStoredPasswordReachesExactlyThePasswordBearingSteps() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [
            StepReportFactory.hold(phase: .respondingAtStartingRate),
            StepReportFactory.hold(phase: .settingsModeEntered),
            StepReportFactory.hold(phase: .loggedIn)
        ]
        harness.runStep(.checkStartingRate)
        harness.runStep(.enterSettingsMode)
        harness.runStep(.login)

        XCTAssertEqual(harness.provider.run.commands, [.checkStartingRate, .enterSettingsMode, .login])
        XCTAssertEqual(harness.provider.run.secretPresence, [false, true, true])
    }

    /// Das Modell **hält** den Wert nicht — es holt ihn bei Bedarf aus
    /// der Einstellungsablage.
    func testTheModelItselfKeepsNoCopyOfThePassword() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [
            StepReportFactory.hold(phase: .respondingAtStartingRate),
            StepReportFactory.hold(phase: .settingsModeEntered)
        ]
        harness.runStep(.checkStartingRate)
        harness.runStep(.enterSettingsMode)

        let mirror = Mirror(reflecting: harness.model)
        for child in mirror.children where child.label != "passwordStore" {
            XCTAssertFalse(
                String(describing: child.value).contains(fabricatedSecretText),
                "Das Passwort steht in \(child.label ?? "?")"
            )
        }
        XCTAssertFalse(harness.model.notice?.message.contains(fabricatedSecretText) == true)
    }

    /// Der folgende Login-Schritt holt den Wert **erneut** aus der
    /// Ablage — er wurde nicht zwischengespeichert.
    func testThePasswordIsFetchedAgainForALaterStep() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [
            StepReportFactory.hold(phase: .respondingAtStartingRate),
            StepReportFactory.hold(phase: .settingsModeEntered)
        ]
        harness.runStep(.checkStartingRate)
        harness.runStep(.enterSettingsMode)

        // Jetzt vergessen: Der nächste Versuch muss scheitern.
        harness.passwordStore.forget()
        harness.model.requestStep(.login)
        XCTAssertEqual(harness.model.confirmPendingStep(), .refusedScannerPassword(.notSet))
    }

    /// Nur der Umschalt-Schritt bekommt überhaupt ein Passwort.
    func testOtherStepsCarryNoPassword() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.runStep(.checkStartingRate)
        XCTAssertEqual(harness.provider.run.secretPresence, [false])
    }

    // MARK: - Klickarmer Ablauf (SICK-032a2)

    /// **Harmlose Schritte gehen auf einen Klick** — ohne vorherige
    /// Anforderung, ohne Bestätigung.
    func testHarmlessStepsRunOnASingleClick() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [StepReportFactory.hold(phase: .respondingAtStartingRate)]

        XCTAssertEqual(harness.model.performStep(.checkStartingRate), .started(.checkStartingRate))
        harness.dispatcher.runToCompletion()
        XCTAssertEqual(harness.provider.run.commands, [.checkStartingRate])
        XCTAssertNil(harness.model.pendingStep)
    }

    /// **Was den Scanner verändert, geht nicht auf einen Klick.** Der
    /// Versuch sendet nichts und führt stattdessen in die Bestätigung.
    func testDeviceChangingStepsCannotBeRunWithASingleClick() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [StepReportFactory.hold(phase: .respondingAtStartingRate)]
        harness.runStep(.checkStartingRate)

        XCTAssertEqual(harness.model.performStep(.enterSettingsMode), .refusedNoPendingStep)
        harness.dispatcher.runToCompletion()
        XCTAssertEqual(harness.provider.run.commands, [.checkStartingRate], "Es darf nichts hinausgegangen sein")
        XCTAssertEqual(harness.model.pendingStep, .enterSettingsMode, "Der Schritt wartet jetzt auf die Bestätigung")
    }

    /// Der Messmodus verändert den Scanner ebenfalls und bleibt deshalb
    /// bestätigungspflichtig.
    func testTheMeasurementModeStepAlsoNeedsConfirmation() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [StepReportFactory.hold(phase: .verified, verifiedBaudRate: .baud38400)]
        harness.runStep(.checkStartingRate)

        XCTAssertEqual(harness.model.performStep(.requestMeasurementMode), .refusedNoPendingStep)
        harness.dispatcher.runToCompletion()
        XCTAssertEqual(harness.provider.run.commands, [.checkStartingRate])
        XCTAssertEqual(harness.model.pendingStep, .requestMeasurementMode)
    }

    // MARK: - Der primäre Ablauf (SICK-032a2)

    /// **Ein Knopf statt zweier**: Zugang holen und nachfragen.
    func testPrepareScannerTakesAccessAndAsksInOneGo() {
        let harness = ControlHarness()
        harness.provider.run.scriptedReports = [StepReportFactory.hold(phase: .respondingAtStartingRate)]

        XCTAssertEqual(harness.model.prepareScanner(), .started)
        harness.dispatcher.runToCompletion()

        XCTAssertEqual(harness.coordinator.accessRequests, 1)
        XCTAssertEqual(harness.provider.run.commands, [.checkStartingRate])
        XCTAssertEqual(harness.model.phase, .respondingAtStartingRate)
    }

    func testStepOneStartsAFreshSessionAfterThePreviousOneWasFinished() {
        let harness = ControlHarness()
        harness.model.requestAccess()
        harness.provider.run.scriptedReports = [
            StepReportFactory.final(phase: .sessionFinished),
            StepReportFactory.hold(phase: .respondingAtStartingRate)
        ]
        harness.runStep(.checkStartingRate)
        XCTAssertEqual(harness.model.phase, .sessionFinished)
        XCTAssertEqual(harness.model.allowedSteps, [])

        XCTAssertEqual(harness.model.prepareScanner(), .started)
        harness.dispatcher.runToCompletion()

        XCTAssertEqual(harness.provider.run.commands, [.checkStartingRate, .checkStartingRate])
        XCTAssertEqual(harness.model.phase, .respondingAtStartingRate)
        XCTAssertEqual(harness.model.allowedSteps, [.enterSettingsMode, .finishSession, .abort])
    }

    /// Hält die Live-Anzeige den Anschluss noch, **wird nichts gesendet
    /// und nichts nachgeholt**.
    func testPrepareScannerWaitsForTheMonitorReleaseWithoutSending() {
        let harness = ControlHarness()
        harness.coordinator.accessOutcome = .awaitingMonitorRelease

        XCTAssertEqual(harness.model.prepareScanner(), .awaitingPortRelease)
        harness.dispatcher.runToCompletion()

        XCTAssertTrue(harness.provider.run.commands.isEmpty, "Ohne Anschluss darf nichts hinausgehen")
        XCTAssertFalse(harness.model.isRunning)
    }

    /// **Ohne ausgewählten Anschluss passiert gar nichts.**
    func testPrepareScannerRefusesWithoutAPort() {
        let harness = ControlHarness(portPath: "")

        XCTAssertEqual(harness.model.prepareScanner(), .refusedNoPortSelected)
        XCTAssertEqual(harness.coordinator.accessRequests, 0, "Ohne Anschluss wird nicht einmal Zugang angefordert")
        XCTAssertTrue(harness.provider.run.commands.isEmpty)
    }
}
