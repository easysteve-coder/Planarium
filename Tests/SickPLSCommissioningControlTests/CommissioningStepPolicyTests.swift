import XCTest
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl

/// Die angebotenen Schritte folgen **eins zu eins** den Ruhepunkten des
/// abgenommenen Reducers (SICK-030a/a2/a3).
///
/// **Diese Ableitung entscheidet nichts.** Wäre sie falsch, entstünde
/// kein unerlaubter Ablauf, sondern ein sichtbarer `unexpectedEvent` —
/// der Nachweis unten fährt das ausdrücklich gegen den echten Reducer.
final class CommissioningStepPolicyTests: XCTestCase {

    private let policy = CommissioningStepPolicy()

    func testBeforeTheFirstRunOnlyTheHarmlessCheckIsOffered() {
        XCTAssertEqual(policy.allowedSteps(after: .idle), [.checkStartingRate])
        XCTAssertEqual(CommissioningStepPolicy.beforeFirstRun, [.checkStartingRate])
    }

    /// **Die Handkette beginnt nur nach einer echten Antwort des Geräts.**
    func testTheManualSequenceIsOfferedOneStepAtATime() {
        XCTAssertEqual(
            policy.allowedSteps(after: .respondingAtStartingRate),
            [.enterSettingsMode, .finishSession, .abort]
        )
        XCTAssertEqual(policy.allowedSteps(after: .settingsModeEntered), [.login, .finishSession, .abort])
        XCTAssertEqual(policy.allowedSteps(after: .loggedIn), [.setTargetBaudRate, .finishSession, .abort])
        XCTAssertEqual(
            policy.allowedSteps(after: .baudSwitchAcknowledged),
            [.connectTargetRate, .finishSession, .abort]
        )
        for phase: CommissioningPhase in [
            .idle,
            .verified,
            .measurementStreamConfirmed,
            .failed(.loginUnanswered),
            .sessionFinished
        ] {
            XCTAssertFalse(
                policy.allowedSteps(after: phase).contains(.enterSettingsMode),
                "Handkette wurde in \(phase) angeboten"
            )
        }
    }

    func testTheMeasurementModeIsOfferedOnlyAfterAProvenVerification() {
        XCTAssertTrue(policy.allowedSteps(after: .verified).contains(.requestMeasurementMode))
        for phase: CommissioningPhase in [
            .idle,
            .respondingAtStartingRate,
            .measurementStreamConfirmed,
            .failed(.baudSwitchRejected),
            .sessionFinished
        ] {
            XCTAssertFalse(
                policy.allowedSteps(after: phase).contains(.requestMeasurementMode),
                "Messmodus wurde in \(phase) angeboten"
            )
        }
    }

    func testDiagnosticsAreOfferedOnlyAfterAFailure() {
        XCTAssertTrue(policy.allowedSteps(after: .failed(.loginUnanswered)).contains(.runRateDiagnostics))
        for phase: CommissioningPhase in [
            .idle,
            .respondingAtStartingRate,
            .settingsModeEntered,
            .loggedIn,
            .baudSwitchAcknowledged,
            .verified,
            .measurementStreamConfirmed,
            .sessionFinished
        ] {
            XCTAssertFalse(
                policy.allowedSteps(after: phase).contains(.runRateDiagnostics),
                "Diagnose wurde in \(phase) angeboten"
            )
        }
    }

    /// **Der Freigabepunkt ist von jedem Ruhepunkt erreichbar** — außer
    /// nach der beendeten Sitzung, wo es nichts mehr zu beenden gibt.
    func testFinishingIsReachableFromEveryRestingPoint() {
        for phase: CommissioningPhase in [
            .respondingAtStartingRate,
            .verified,
            .measurementStreamConfirmed,
            .failed(.loginUnanswered),
            .diagnosticsFinished(
                CommissioningDiagnosticsReport(outcomeAtStartingRate: .timeout, outcomeAtTargetRate: .timeout)
            )
        ] {
            XCTAssertTrue(
                policy.allowedSteps(after: phase).contains(.finishSession),
                "In \(phase) ließe sich die Sitzung nicht beenden"
            )
        }
        XCTAssertEqual(policy.allowedSteps(after: .sessionFinished), [])
    }

    /// Zwischenlagen können in einem **Bericht** nicht vorkommen —
    /// `perform` kehrt erst an einem Ruhepunkt zurück. Falls doch, ist
    /// „nichts anbieten" die richtige Antwort.
    func testIntermediatePhasesOfferNothing() {
        for phase: CommissioningPhase in [
            .checkingStartingRate,
            .enteringSettingsMode,
            .enteringSettingsModeManually,
            .loggingIn(attempt: 1),
            .loggingInManually,
            .requestingBaudSwitch,
            .requestingBaudSwitchManually,
            .closingPort,
            .openingTargetPort,
            .verifyingTargetRate,
            .awaitingMeasurementStream(deadlineMillis: 0)
        ] {
            XCTAssertEqual(policy.allowedSteps(after: phase), [], "\(phase) bot etwas an")
        }
    }

    /// **Der Reducer bleibt die Wahrheit.** Jeder angebotene Schritt wird
    /// dort auch wirklich angenommen.
    ///
    /// Geprüft gegen den **echten** `CommissioningModel`, und zwar in
    /// Ruhepunkten, die er selbst über gültige Ereignisse erreicht hat —
    /// **kein Testhaken, der eine Phase hineinschreibt**, sonst bewiese
    /// der Nachweis nur, dass zwei Aufzählungen gleich heißen.
    func testEveryOfferedStepIsAcceptedByTheRealReducer() {
        for makeModel in Self.restingPointBuilders {
            let reference = makeModel()
            for command in policy.allowedSteps(after: reference.phase) {
                var model = makeModel()
                let before = model.phase
                model.apply(Self.event(for: command), atMillis: 10_000)
                if case .failed(.unexpectedEvent) = model.phase {
                    XCTFail("\(command) wurde in \(before) angeboten, aber vom Reducer abgelehnt")
                }
            }
        }
    }

    /// Gegenrichtung: Die Ruhepunkte, die hier geprüft werden, sind
    /// wirklich die des Reducers — sonst liefe der Nachweis oben über
    /// eine Auswahl, die nie vorkommt.
    func testTheRestingPointsAreTheOnesTheReducerActuallyReaches() {
        let reached = Self.restingPointBuilders.map { $0().phase }
        XCTAssertEqual(reached.count, 9)
        XCTAssertEqual(reached[0], .idle)
        XCTAssertEqual(reached[1], .respondingAtStartingRate)
        XCTAssertEqual(reached[2], .settingsModeEntered)
        XCTAssertEqual(reached[3], .loggedIn)
        XCTAssertEqual(reached[4], .baudSwitchAcknowledged)
        XCTAssertEqual(reached[5], .verified)
        XCTAssertEqual(reached[6], .measurementStreamConfirmed)
        XCTAssertEqual(reached[7], .failed(.abortedByOperator))
        guard case .diagnosticsFinished = reached[8] else {
            return XCTFail("Die Diagnose wurde nicht erreicht: \(reached[8])")
        }
    }

    // MARK: - Ruhepunkte über gültige Ereignisse

    private static let restingPointBuilders: [() -> CommissioningModel] = [
        { CommissioningModel(recipe: .r26) },
        { respondingAtStartingRate() },
        { settingsModeEntered() },
        { loggedIn() },
        { baudSwitchAcknowledged() },
        { verified() },
        { measurementStreamConfirmed() },
        { failed() },
        { diagnosticsFinished() }
    ]

    private static func respondingAtStartingRate() -> CommissioningModel {
        var model = CommissioningModel(recipe: .r26)
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 0)
        model.apply(.identityOutcome(.identified), atMillis: 10)
        return model
    }

    private static func verified() -> CommissioningModel {
        var model = respondingAtStartingRate()
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 20)
        model.apply(.acknowledgement(.acknowledged), atMillis: 30)   // Einstellungsmodus
        model.apply(.acknowledgement(.acknowledged), atMillis: 40)   // Login
        model.apply(.acknowledgement(.acknowledged), atMillis: 50)   // Baudwechsel
        model.apply(.portClosed, atMillis: 60)
        model.apply(.portOpened(.baud38400), atMillis: 70)
        model.apply(.identityOutcome(.identified), atMillis: 80)
        return model
    }

    private static func settingsModeEntered() -> CommissioningModel {
        var model = respondingAtStartingRate()
        model.apply(.operatorRequestedSettingsMode(secretIsAvailable: true), atMillis: 20)
        model.apply(.acknowledgement(.acknowledged), atMillis: 30)
        return model
    }

    private static func loggedIn() -> CommissioningModel {
        var model = settingsModeEntered()
        model.apply(.operatorRequestedLogin(secretIsAvailable: true), atMillis: 40)
        model.apply(.acknowledgement(.acknowledged), atMillis: 50)
        return model
    }

    private static func baudSwitchAcknowledged() -> CommissioningModel {
        var model = loggedIn()
        model.apply(.operatorRequestedTargetBaudRate, atMillis: 60)
        model.apply(.acknowledgement(.acknowledged), atMillis: 70)
        return model
    }

    private static func measurementStreamConfirmed() -> CommissioningModel {
        var model = verified()
        model.apply(.operatorRequestedMeasurementMode, atMillis: 90)
        // **SICK-0330a-0:** Erst ein echter B0-Frame nach der Anforderung
        // bringt diesen Ruhepunkt zur Ruhe -- ein bloßes ACK genügt
        // nicht mehr.
        model.apply(.acknowledgement(.observedScanProfile), atMillis: 100)
        return model
    }

    private static func failed() -> CommissioningModel {
        var model = CommissioningModel(recipe: .r26)
        model.apply(.operatorAborted, atMillis: 0)
        return model
    }

    private static func diagnosticsFinished() -> CommissioningModel {
        var model = failed()
        model.apply(.operatorRequestedDiagnostics, atMillis: 100)
        model.apply(.portOpened(.baud9600), atMillis: 110)
        model.apply(.identityOutcome(.timeout), atMillis: 120)
        model.apply(.portClosed, atMillis: 130)
        model.apply(.portOpened(.baud38400), atMillis: 140)
        model.apply(.identityOutcome(.timeout), atMillis: 150)
        return model
    }

    private static func event(for command: CommissioningCommand) -> CommissioningEvent {
        switch command {
        case .checkStartingRate: return .operatorRequestedStartingRateCheck
        case .enterSettingsMode: return .operatorRequestedSettingsMode(secretIsAvailable: true)
        case .login: return .operatorRequestedLogin(secretIsAvailable: true)
        case .setTargetBaudRate: return .operatorRequestedTargetBaudRate
        case .connectTargetRate: return .operatorRequestedTargetRateConnection
        case .switchBaudRate: return .operatorRequestedBaudSwitch(secretIsAvailable: true)
        case .requestMeasurementMode: return .operatorRequestedMeasurementMode
        case .runRateDiagnostics: return .operatorRequestedDiagnostics
        case .finishSession: return .operatorFinishedSession
        case .abort: return .operatorAborted
        }
    }

    // MARK: - Bestätigungspflicht (SICK-032a2)

    /// **Bestätigt wird, was den Scanner verändert** — und sonst nichts.
    func testOnlyDeviceChangingStepsNeedConfirmation() {
        let policy = CommissioningStepPolicy()
        XCTAssertTrue(policy.requiresConfirmation(.switchBaudRate))
        XCTAssertTrue(policy.requiresConfirmation(.enterSettingsMode))
        XCTAssertTrue(policy.requiresConfirmation(.login))
        XCTAssertTrue(policy.requiresConfirmation(.setTargetBaudRate))
        XCTAssertTrue(policy.requiresConfirmation(.connectTargetRate))
        XCTAssertTrue(policy.requiresConfirmation(.requestMeasurementMode))

        XCTAssertFalse(policy.requiresConfirmation(.checkStartingRate))
        XCTAssertFalse(policy.requiresConfirmation(.runRateDiagnostics))
        XCTAssertFalse(policy.requiresConfirmation(.finishSession))
        XCTAssertFalse(policy.requiresConfirmation(.abort))
    }

    /// Die harmlosen Schritte senden höchstens die Nachfrage oder
    /// beenden den Vorgang — deshalb dürfen sie auf einen Klick gehen.
    func testEveryStepOfferedBeforeTheFirstRunIsASingleClick() {
        let policy = CommissioningStepPolicy()
        for command in CommissioningStepPolicy.beforeFirstRun {
            XCTAssertFalse(
                policy.requiresConfirmation(command),
                "Der Einstieg darf keine Bestätigung verlangen"
            )
        }
    }
}
