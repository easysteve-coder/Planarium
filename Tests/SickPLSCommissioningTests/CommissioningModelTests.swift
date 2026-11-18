import XCTest
import SickPLSActiveControl
import SickPLSMacTransport
@testable import SickPLSCommissioning

/// Jeder Übergang des Reducers — ohne Port, ohne Uhr, ohne Gerät.
final class CommissioningModelTests: XCTestCase {

    private func model() -> CommissioningModel { CommissioningModel() }

    // MARK: - Ausgangsprüfung

    func testTheStartingRateCheckSendsTheHarmlessIdentityProbe() {
        var model = model()
        let directive = model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)

        XCTAssertEqual(
            directive,
            .sendIdentityProbe(
                address: model.recipe.configurationAddress.rawValue,
                deadlineMillis: 1_000 + model.recipe.responseTimeoutMilliseconds
            )
        )
        XCTAssertEqual(model.phase, .checkingStartingRate)
        // **Die Frist ist im Modell sichtbar**, nicht in einer Schleife.
        XCTAssertEqual(model.pendingDeadlineMillis, 1_000 + model.recipe.responseTimeoutMilliseconds)
    }

    /// **Auflage A7:** Der bestätigte Ausgangszustand ist ein Ruhepunkt
    /// mit **gehaltenem** Port — kein Ende mit Freigabe.
    func testAnAnsweringDeviceReachesTheRestingPointAndKeepsThePort() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        let directive = model.apply(.identityOutcome(.identified), atMillis: 1_150)

        XCTAssertEqual(directive, .hold, "Ruhen, aber halten")
        XCTAssertFalse(directive.releasesPort, "Ein Ruhepunkt gibt nichts frei")
        XCTAssertEqual(model.phase, .respondingAtStartingRate)
        XCTAssertNil(model.pendingDeadlineMillis, "Es steht keine Frist mehr aus")
        XCTAssertTrue(model.needsPort, "Das Login folgt auf derselben Verbindung")
    }

    func testASilentDeviceFailsWithTheObservedOutcome() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        let directive = model.apply(.deadlineReached, atMillis: 3_000)

        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.noDeviceAtStartingRate(.timeout)))
    }

    // MARK: - Der überwachte Wechsel

    func testTheSwitchOnlyStartsFromAConfirmedStartingState() {
        var model = model()
        // Ohne vorherige Antwort: abgelehnt.
        let directive = model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 1_000)
        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.unexpectedEvent))
    }

    func testTheSwitchRefusesWithoutASecret() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        let directive = model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: false), atMillis: 2_000)
        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.unexpectedEvent))
    }

    /// Der Windows-Vertrag erlaubt genau zwei identische Wiederholungen,
    /// jeweils erst nach dem vollstaendigen Antwortfenster.
    func testTheLoginIsRepeatedExactlyTwiceAfterItsDeadlines() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)

        let settingsMode = model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        XCTAssertEqual(settingsMode, .sendSettingsMode(deadlineMillis: 4_000))
        XCTAssertEqual(model.phase, .enteringSettingsMode)

        let first = model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        XCTAssertEqual(first, .sendLogin(attempt: 1, deadlineMillis: 4_000))
        XCTAssertEqual(model.phase, .loggingIn(attempt: 1))

        let second = model.apply(.deadlineReached, atMillis: 4_000)
        XCTAssertEqual(second, .sendLogin(attempt: 2, deadlineMillis: 6_000))
        XCTAssertEqual(model.phase, .loggingIn(attempt: 2))

        let third = model.apply(.deadlineReached, atMillis: 6_000)
        XCTAssertEqual(third, .sendLogin(attempt: 3, deadlineMillis: 8_000))
        XCTAssertEqual(model.phase, .loggingIn(attempt: 3))

        // Und keine vierte Sendung.
        let fourth = model.apply(.deadlineReached, atMillis: 8_000)
        XCTAssertEqual(fourth, .stop)
        XCTAssertEqual(model.phase, .failed(.loginUnanswered))
    }

    func testSettingsModeMustBeAcknowledgedBeforeTheFirstLogin() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)

        XCTAssertEqual(
            model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000),
            .sendSettingsMode(deadlineMillis: 4_000)
        )
        XCTAssertTrue(model.audit.entries.filter { $0.action == .login }.isEmpty)

        XCTAssertEqual(
            model.apply(.acknowledgement(.acknowledged), atMillis: 2_100),
            .sendLogin(attempt: 1, deadlineMillis: 4_100)
        )
        XCTAssertEqual(model.audit.entries.map(\.action).suffix(2), [.settingsMode, .login])
    }

    func testRejectedSettingsModeStopsBeforeAnyLogin() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)

        XCTAssertEqual(model.apply(.acknowledgement(.rejected), atMillis: 2_100), .stop)
        XCTAssertEqual(model.phase, .failed(.settingsModeRejected))
        XCTAssertTrue(model.audit.entries.filter { $0.action == .login }.isEmpty)
    }

    /// Die Wiederholung ist im Protokoll als **zweite Sendung**
    /// sichtbar, nicht als eigener Schritt getarnt.
    func testTheRepeatedLoginIsVisibleAsASecondTransmission() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        model.apply(.deadlineReached, atMillis: 4_000)

        let logins = model.audit.entries.filter { $0.action == .login }
        XCTAssertEqual(logins.map(\.attemptNumber), [1, 2])
        XCTAssertEqual(logins.first?.outcome, .timedOut)
        XCTAssertEqual(logins.last?.outcome, .sent)
    }

    /// **Kein anderes Telegramm hat eine Wiederholung.**
    func testNoOtherTelegramIsEverRepeated() {
        // Baudwechsel
        var switching = model()
        switching.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        switching.apply(.identityOutcome(.identified), atMillis: 1_100)
        switching.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        switching.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        switching.apply(.acknowledgement(.acknowledged), atMillis: 2_150)
        XCTAssertEqual(switching.phase, .requestingBaudSwitch)
        XCTAssertEqual(switching.apply(.deadlineReached, atMillis: 4_200), .stop)
        XCTAssertEqual(switching.phase, .failed(.baudSwitchUnanswered))
        XCTAssertEqual(switching.audit.entries.filter { $0.action == .baudSwitchRequest }.count, 1)

        // Verifikation
        var verifying = model()
        verifying.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        verifying.apply(.identityOutcome(.identified), atMillis: 1_100)
        verifying.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        verifying.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        verifying.apply(.acknowledgement(.acknowledged), atMillis: 2_150)
        verifying.apply(.acknowledgement(.acknowledged), atMillis: 2_300)
        verifying.apply(.portClosed, atMillis: 2_400)
        verifying.apply(.portOpened(.baud38400), atMillis: 2_500)
        XCTAssertEqual(verifying.apply(.deadlineReached, atMillis: 4_500), .stop)
        XCTAssertEqual(verifying.phase, .failed(.verificationFailed(.timeout)))
        XCTAssertEqual(verifying.audit.entries.filter { $0.action == .verification(.baud38400) }.count, 1)

        // Ausgangsprüfung
        var checking = model()
        checking.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        checking.apply(.deadlineReached, atMillis: 3_000)
        XCTAssertEqual(checking.audit.entries.filter { $0.action == .identityCheck(.baud9600) }.count, 1)
    }

    func testTheSwitchIsOneSupervisedTransactionInTheDocumentedOrder() {
        var model = model()
        let directives = runSuccessfulSwitch(&model)

        XCTAssertEqual(
            directives,
            [
                .sendIdentityProbe(address: 0x01, deadlineMillis: 3_000),
                .hold,
                .sendSettingsMode(deadlineMillis: 4_000),
                .sendLogin(attempt: 1, deadlineMillis: 4_000),
                .sendLogin(attempt: 2, deadlineMillis: 6_000),
                .sendLogin(attempt: 3, deadlineMillis: 8_000),
                .sendBaudSwitch(deadlineMillis: 8_150),
                .closePort,
                .openPort(.baud38400),
                .sendIdentityProbe(address: 0x00, deadlineMillis: 8_500),
                .hold
            ]
        )
        XCTAssertEqual(model.phase, .verified)
        // **Auflage A7:** In der ganzen Transaktion gibt keine einzige
        // Anweisung den Port frei.
        XCTAssertFalse(directives.contains { $0.releasesPort })
    }

    /// **Auflage A1:** Erfolg ist die Identitätsantwort am neu
    /// geöffneten Port — nicht ein Messstrom.
    func testSuccessIsTheIdentityAnswerAtTheTargetRate() {
        var model = model()
        runSuccessfulSwitch(&model)
        XCTAssertEqual(model.phase, .verified)
        XCTAssertEqual(model.verifiedBaudRate, .baud38400)
        // Es war **kein** Messstrom nötig.
        XCTAssertFalse(model.observedScanProfileStream)
    }

    /// Ein Messstrom allein belegt gar nichts — er hält den Ablauf nur
    /// nicht auf.
    func testAnObservedScanStreamNeverCompletesTheSwitch() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_150)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_300)
        model.apply(.portClosed, atMillis: 2_400)
        model.apply(.portOpened(.baud38400), atMillis: 2_500)

        let directive = model.apply(.acknowledgement(.observedScanProfile), atMillis: 2_600)

        XCTAssertEqual(directive, .none, "Rauschen wird übersprungen, nicht gewertet")
        XCTAssertEqual(model.phase, .verifyingTargetRate, "Der Wechsel ist damit nicht belegt")
        XCTAssertNil(model.verifiedBaudRate)
        XCTAssertTrue(model.observedScanProfileStream, "Beobachtet wird es trotzdem")
    }

    /// Ein Messstrom **während** des Wartens verlängert nichts und
    /// verändert die Frist nicht.
    func testAnObservedScanStreamDoesNotMoveTheDeadline() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        let deadline = model.pendingDeadlineMillis
        model.apply(.acknowledgement(.observedScanProfile), atMillis: 1_500)
        XCTAssertEqual(model.pendingDeadlineMillis, deadline)
    }

    // MARK: - Der Fehlertext für den Bedienenden (SICK-032a3)

    /// **Jeder Befund hat einen eigenen Satz** — und keiner davon trägt
    /// eine Nutzlast.
    func testEveryFailureHasItsOwnDataFreeOperatorSummary() {
        let marker = "ERFUNDENER-ADAPTERTEXT-032A3"
        let failures: [CommissioningFailure] = [
            .noDeviceAtStartingRate(.timeout),
            .loginRejected,
            .loginUnanswered,
            .loginAmbiguous,
            .baudSwitchRejected,
            .baudSwitchUnanswered,
            .baudSwitchAmbiguous,
            .portOpenFailed(marker),
            .portCloseFailed(marker),
            .verificationFailed(.timeout),
            .measurementModeRejected,
            .measurementStreamAbsent,
            .writeFailed(marker),
            .abortedByOperator,
            .unexpectedEvent
        ]

        var seen: Set<String> = []
        for failure in failures {
            let summary = failure.operatorSummary
            XCTAssertFalse(summary.isEmpty, "\(failure)")
            XCTAssertFalse(
                summary.contains(marker),
                "\(failure): der Adaptertext gehört nicht in den Bedientext"
            )
            XCTAssertTrue(seen.insert(summary).inserted, "\(failure): derselbe Satz wie ein anderer Befund")
        }
    }

    /// Die drei Login-Befunde bleiben **unterscheidbar** — „abgelehnt",
    /// „keine Antwort" und „unlesbar" verlangen verschiedene Handgriffe
    /// am Gerät.
    func testTheThreeLoginFailuresStayDistinguishableInPlainLanguage() {
        XCTAssertTrue(CommissioningFailure.loginRejected.operatorSummary.contains("rejected"))
        XCTAssertTrue(CommissioningFailure.loginUnanswered.operatorSummary.contains("No response"))
        XCTAssertTrue(CommissioningFailure.loginAmbiguous.operatorSummary.contains("unreadable"))
        XCTAssertTrue(CommissioningFailure.loginUnanswered.operatorSummary.contains("third attempt"))
        XCTAssertTrue(CommissioningFailure.loginAmbiguous.operatorSummary.contains("third attempt"))
    }

    // MARK: - Fehlerwege

    /// **Eine Ablehnung ist ein klarer Befund und wird nie wiederholt**
    /// (SICK-032a3): „nein" heißt nein, und ein zweites, identisches
    /// Telegramm wäre genau der Wiederholungssturm, den
    /// `maximumLoginRetryCount` verhindert.
    func testARejectedLoginStopsImmediatelyAndNeverRetries() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)

        let directive = model.apply(.acknowledgement(.rejected), atMillis: 2_150)

        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.loginRejected))
        XCTAssertNil(model.pendingDeadlineMillis)
        XCTAssertEqual(model.audit.entries.filter { $0.action == .login }.count, 1)
    }

    /// **Der Kern von SICK-032a3a:** Eine Antwort, die sich nicht
    /// deuten lässt, **beendet den Versuch nicht**. Sie wird gemerkt,
    /// und es wird in **derselben** Frist weitergelesen.
    ///
    /// SICK-032a3 hat hier sofort wiederholt — das zweite Telegramm
    /// wäre Millisekunden nach dem ersten hinausgegangen statt nach dem
    /// vollen 2-Sekunden-Fenster, das die Beleglage nennt.
    func testAnUnreadableLoginAnswerKeepsTheWindowOpenAndSendsNothing() {
        let outcomes: [AcknowledgementOutcome] = [
            .missingStatusByte,
            .unknownStatus(0x02),
            .unexpectedCommandByte(0xB1),
            .undecodable,
            .timeout
        ]
        for outcome in outcomes {
            var model = model()
            model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
            model.apply(.identityOutcome(.identified), atMillis: 1_100)
            model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
            model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
            let deadline = model.pendingDeadlineMillis

            let directive = model.apply(.acknowledgement(outcome), atMillis: 2_150)

            XCTAssertEqual(directive, .none, "\(outcome): es geht nichts hinaus")
            XCTAssertEqual(model.phase, .loggingIn(attempt: 1), "\(outcome): immer noch der erste Versuch")
            XCTAssertEqual(model.pendingDeadlineMillis, deadline, "\(outcome): dieselbe Frist")
            XCTAssertEqual(
                model.audit.entries.filter { $0.action == .login }.count, 1,
                "\(outcome): genau eine Sendung"
            )
        }
    }

    /// **Erst das Fristende löst eine Wiederholung aus** — und der
    /// Abstand zwischen den Sendungen ist mindestens das volle
    /// Lesefenster.
    func testTheRetryGoesOutOnlyAtTheDeadlineAndAFullWindowLater() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        let firstDeadline = try? XCTUnwrap(model.pendingDeadlineMillis)

        // Mitten im Fenster kommt Undeutbares -- ohne Wirkung.
        model.apply(.acknowledgement(.undecodable), atMillis: 2_150)
        XCTAssertEqual(model.audit.entries.filter { $0.action == .login }.count, 1)

        let retry = model.apply(.deadlineReached, atMillis: 4_000)

        XCTAssertEqual(
            retry,
            .sendLogin(attempt: 2, deadlineMillis: 6_000)
        )
        XCTAssertEqual(model.phase, .loggingIn(attempt: 2))
        XCTAssertTrue(model.needsPort, "dieselbe offene Verbindung")
        XCTAssertFalse(retry.releasesPort)
        XCTAssertTrue(retry.requiresReceiveBufferFlush)
        XCTAssertEqual(firstDeadline, 2_000 + model.recipe.loginResponseTimeoutMilliseconds)
        // Der Befund des Fensters steht im Audit -- „undeutbar", nicht
        // „gar nichts".
        XCTAssertEqual(model.audit.entries.filter { $0.action == .login }.first?.outcome, .ambiguous)

        let third = model.apply(.deadlineReached, atMillis: 6_000)
        XCTAssertEqual(third, .sendLogin(attempt: 3, deadlineMillis: 8_000))
        let stop = model.apply(.deadlineReached, atMillis: 8_000)

        XCTAssertEqual(stop, .stop)
        XCTAssertEqual(
            model.phase, .failed(.loginUnanswered),
            "Im dritten Fenster kam gar nichts -- der Befund wird nicht vom ersten geerbt"
        )
        let loginEntries = model.audit.entries.filter { $0.action == .login }
        XCTAssertEqual(loginEntries.map(\.attemptNumber), [1, 2, 3], "nie eine vierte Sendung")
        XCTAssertEqual(loginEntries.map(\.outcome), [.ambiguous, .timedOut, .timedOut])
    }

    /// **Ein spätes ACK in derselben Frist führt ohne Wiederholung
    /// weiter** — es gehört noch zum ersten Telegramm.
    func testALateAcknowledgementInTheSameWindowNeedsNoSecondLogin() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        model.apply(.acknowledgement(.undecodable), atMillis: 2_050)
        model.apply(.acknowledgement(.unexpectedCommandByte(0x06)), atMillis: 2_100)

        let directive = model.apply(.acknowledgement(.acknowledged), atMillis: 2_400)

        XCTAssertEqual(
            directive,
            .sendBaudSwitch(deadlineMillis: 2_400 + model.recipe.responseTimeoutMilliseconds)
        )
        XCTAssertEqual(model.phase, .requestingBaudSwitch)
        let loginEntries = model.audit.entries.filter { $0.action == .login }
        XCTAssertEqual(loginEntries.count, 1, "Genau eine Login-Sendung")
        XCTAssertEqual(loginEntries.map(\.outcome), [.acknowledged])
    }

    /// **Drei Fenster mit Undeutbarem enden als `loginAmbiguous`** — der
    /// Unterschied zu „es kam gar nichts" bleibt erhalten.
    func testThreeUnreadableWindowsFailAsAmbiguousAndNeverSendAFourthTime() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        model.apply(.acknowledgement(.undecodable), atMillis: 2_150)
        model.apply(.deadlineReached, atMillis: 4_000)
        model.apply(.acknowledgement(.missingStatusByte), atMillis: 4_150)
        model.apply(.deadlineReached, atMillis: 6_000)
        model.apply(.acknowledgement(.undecodable), atMillis: 6_150)

        let stop = model.apply(.deadlineReached, atMillis: 8_000)

        XCTAssertEqual(stop, .stop)
        XCTAssertEqual(model.phase, .failed(.loginAmbiguous))
        let loginEntries = model.audit.entries.filter { $0.action == .login }
        XCTAssertEqual(loginEntries.map(\.attemptNumber), [1, 2, 3], "nie eine vierte Sendung")
        XCTAssertEqual(loginEntries.map(\.outcome), [.ambiguous, .ambiguous, .ambiguous])
    }

    /// **ACK führt weiter — auch im zweiten Fenster.** Der zweite
    /// Versuch ist ein vollwertiger Login, kein Notbehelf.
    func testAnAcknowledgementOnTheSecondAttemptContinuesToTheBaudSwitch() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        model.apply(.acknowledgement(.missingStatusByte), atMillis: 2_150)
        model.apply(.deadlineReached, atMillis: 4_000)

        let directive = model.apply(.acknowledgement(.acknowledged), atMillis: 4_300)

        XCTAssertEqual(
            directive,
            .sendBaudSwitch(deadlineMillis: 4_300 + model.recipe.responseTimeoutMilliseconds)
        )
        XCTAssertEqual(model.phase, .requestingBaudSwitch)
        let loginEntries = model.audit.entries.filter { $0.action == .login }
        XCTAssertEqual(loginEntries.map(\.outcome), [.ambiguous, .acknowledged])
    }

    /// **Genau zwei Ausgänge beenden einen Login-Versuch** — und der
    /// Rest hält das Fenster offen.
    func testExactlyTwoOutcomesConcludeALoginAttempt() {
        XCTAssertTrue(AcknowledgementOutcome.acknowledged.concludesLoginAttempt)
        XCTAssertTrue(AcknowledgementOutcome.rejected.concludesLoginAttempt)
        for outcome: AcknowledgementOutcome in [
            .observedScanProfile, .unknownStatus(0x02), .missingStatusByte,
            .unexpectedCommandByte(0x06), .timeout, .undecodable
        ] {
            XCTAssertFalse(outcome.concludesLoginAttempt, "\(outcome)")
        }
    }

    /// Ein Messstrom **verbraucht keinen Versuch** — er ist bekanntes
    /// Rauschen und wird übersprungen, auch beliebig oft.
    func testAnObservedScanStreamDuringLoginConsumesNoAttempt() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        let deadline = model.pendingDeadlineMillis

        for offset in 0..<5 {
            let directive = model.apply(.acknowledgement(.observedScanProfile), atMillis: 2_050 + Int64(offset))
            XCTAssertEqual(directive, .none)
        }

        XCTAssertEqual(model.phase, .loggingIn(attempt: 1), "Immer noch der erste Versuch")
        XCTAssertEqual(model.pendingDeadlineMillis, deadline, "Und die Frist steht unverändert")
        XCTAssertTrue(model.observedScanProfileStream)
        XCTAssertEqual(model.audit.entries.filter { $0.action == .login }.count, 1)
    }

    func testAFailedPortOpenIsItsOwnFailure() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_150)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_300)
        model.apply(.portClosed, atMillis: 2_400)
        let directive = model.apply(.portOpenFailed("errno 16"), atMillis: 2_500)

        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.portOpenFailed("errno 16")))
    }

    func testAWriteFailureStopsFromAnyPhase() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        let directive = model.apply(.writeFailed("errno 5"), atMillis: 1_050)
        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.writeFailed("errno 5")))
        XCTAssertEqual(model.audit.entries.last?.outcome, .writeFailed)
    }

    func testAnAbortStopsFromAnyPhase() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        XCTAssertEqual(model.apply(.operatorAborted, atMillis: 2_100), .stop)
        XCTAssertEqual(model.phase, .failed(.abortedByOperator))
    }

    /// **Kein „zurück auf 9600"** — nur ein Hinweis (Befund M3).
    func testAFailureOffersOnlyAHintAndNoReverseCommand() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.deadlineReached, atMillis: 3_000)

        guard case .failed(let failure) = model.phase else { return XCTFail("Erwartet: Fehlschlag") }
        XCTAssertTrue(failure.recoveryHint.contains("restart"))
        // Es gibt keine Anweisung, die etwas zurückstellen könnte.
        let allDirectives: [CommissioningDirective] = [
            .none, .sendIdentityProbe(address: 1, deadlineMillis: 0),
            .sendSettingsMode(deadlineMillis: 0), .sendLogin(attempt: 1, deadlineMillis: 0),
            .sendBaudSwitch(deadlineMillis: 0), .sendMeasurementMode(deadlineMillis: 0),
            .closePort, .openPort(.baud9600), .hold, .stop
        ]
        XCTAssertEqual(allDirectives.count, 10, "Neue Anweisung? Dann hier bewusst mitpflegen.")
    }

    // MARK: - Diagnose

    /// **SICK-030a3, Kern:** Die vollständige Folge — öffnen, proben,
    /// **wirklich** schließen, bei der anderen Rate wieder öffnen, proben,
    /// abschließen.
    func testDiagnosticsProbeEachRateOnAConnectionActuallyOpenedThatWay() {
        var model = failedModel()

        let directives = runDiagnostics(
            &model, startingOutcome: .timeout, targetOutcome: .identified
        )

        XCTAssertEqual(
            directives,
            [
                .openPort(.baud9600),
                .sendIdentityProbe(address: 0x00, deadlineMillis: 6_100),
                .closePort,
                .openPort(.baud38400),
                .sendIdentityProbe(address: 0x00, deadlineMillis: 6_500),
                .stop
            ]
        )

        guard case .diagnosticsFinished(let report) = model.phase else {
            return XCTFail("Erwartet: abgeschlossene Diagnose")
        }
        XCTAssertFalse(report.respondsAtStartingRate)
        XCTAssertTrue(report.respondsAtTargetRate)
    }

    /// **Zwischen den beiden Proben steht ein Close und ein Open auf der
    /// jeweils angegebenen Rate** — die Aussage, um die es in diesem
    /// Slice geht, als eigener Test.
    func testThereIsARealCloseAndReopenBetweenTheTwoProbes() {
        var model = failedModel()
        let directives = runDiagnostics(
            &model, startingOutcome: .identified, targetOutcome: .timeout
        )

        guard
            let firstProbe = directives.firstIndex(where: \.isSendDirective),
            let lastProbe = directives.lastIndex(where: \.isSendDirective),
            firstProbe < lastProbe
        else { return XCTFail("Erwartet: zwei Proben") }

        let between = Array(directives[(firstProbe + 1)..<lastProbe])
        XCTAssertEqual(
            between, [.closePort, .openPort(.baud38400)],
            "Genau ein Schließen und ein Öffnen bei der Zielrate"
        )
        XCTAssertFalse(
            between.contains { $0.releasesPort },
            "Der Ratenwechsel gibt den Port nicht ab, er wechselt die Rate"
        )
    }

    /// **Jeder Öffnungsschritt wird bestätigt, bevor gesendet wird.**
    func testNoProbeIsSentBeforeItsPortOpeningIsConfirmed() {
        var model = failedModel()

        let request = model.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        XCTAssertEqual(request, .openPort(.baud9600))
        XCTAssertFalse(request.isSendDirective, "Erst öffnen, dann proben")
        XCTAssertNil(model.pendingDeadlineMillis, "Ohne Sendung keine Frist")
        XCTAssertTrue(
            model.audit.entries.allSatisfy { $0.action != .diagnosticProbe(.baud9600) },
            "Und noch kein Protokolleintrag für eine Probe, die nicht hinausging"
        )

        XCTAssertEqual(
            model.apply(.portOpened(.baud9600), atMillis: 4_100),
            .sendIdentityProbe(address: 0x00, deadlineMillis: 6_100)
        )
        XCTAssertEqual(model.pendingDeadlineMillis, 6_100)

        // Dasselbe vor der zweiten Probe.
        XCTAssertEqual(model.apply(.identityOutcome(.timeout), atMillis: 4_300), .closePort)
        let reopen = model.apply(.portClosed, atMillis: 4_400)
        XCTAssertEqual(reopen, .openPort(.baud38400))
        XCTAssertFalse(reopen.isSendDirective)
        XCTAssertNil(model.pendingDeadlineMillis)
        XCTAssertEqual(
            model.audit.entries.filter { $0.action == .diagnosticProbe(.baud38400) }.count, 0
        )
    }

    /// **Beide Deadlinepfade**: Eine abgelaufene Frist ist ein sauber
    /// auditiertes Ergebnis, kein Abbruch — die Folge läuft weiter.
    func testADeadlineAtEitherRateIsAnAuditedResultAndNotAnAbort() {
        var first = failedModel()
        first.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        first.apply(.portOpened(.baud9600), atMillis: 4_100)
        XCTAssertEqual(first.apply(.deadlineReached, atMillis: 6_100), .closePort)
        XCTAssertEqual(
            first.audit.entries.last(where: { $0.action == .diagnosticProbe(.baud9600) })?.outcome,
            .timedOut
        )
        XCTAssertNil(first.pendingDeadlineMillis)

        var second = failedModel()
        second.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        second.apply(.portOpened(.baud9600), atMillis: 4_100)
        second.apply(.identityOutcome(.identified), atMillis: 4_300)
        second.apply(.portClosed, atMillis: 4_400)
        second.apply(.portOpened(.baud38400), atMillis: 4_500)

        XCTAssertEqual(second.apply(.deadlineReached, atMillis: 6_500), .stop)
        guard case .diagnosticsFinished(let report) = second.phase else {
            return XCTFail("Erwartet: abgeschlossene Diagnose")
        }
        XCTAssertTrue(report.respondsAtStartingRate)
        XCTAssertFalse(report.respondsAtTargetRate, "Eine Zeitüberschreitung ist ein Ergebnis")
        XCTAssertEqual(
            second.audit.entries.last(where: { $0.action == .diagnosticProbe(.baud38400) })?.outcome,
            .timedOut
        )
        XCTAssertNil(second.pendingDeadlineMillis)
    }

    /// Ein Öffnungsfehler beendet die Diagnose sichtbar — an **beiden**
    /// Öffnungsstellen, ohne Konfigurationstelegramm und ohne Retry.
    func testAFailedPortOpenEndsTheDiagnosticsAtEitherRate() {
        var atStart = failedModel()
        atStart.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        let firstSends = atStart.audit.entries.count
        XCTAssertEqual(atStart.apply(.portOpenFailed("errno 16"), atMillis: 4_100), .stop)
        XCTAssertEqual(atStart.phase, .failed(.portOpenFailed("errno 16")))
        XCTAssertFalse(atStart.needsPort)
        XCTAssertEqual(atStart.audit.entries.count, firstSends, "Es ging nichts hinaus")

        var atTarget = failedModel()
        atTarget.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        atTarget.apply(.portOpened(.baud9600), atMillis: 4_100)
        atTarget.apply(.identityOutcome(.identified), atMillis: 4_300)
        atTarget.apply(.portClosed, atMillis: 4_400)
        XCTAssertEqual(atTarget.apply(.portOpenFailed("errno 2"), atMillis: 4_500), .stop)
        XCTAssertEqual(atTarget.phase, .failed(.portOpenFailed("errno 2")))
        XCTAssertFalse(atTarget.needsPort)
        XCTAssertEqual(
            atTarget.audit.entries.filter { $0.action == .diagnosticProbe(.baud38400) }.count, 0
        )
    }

    /// Ein **Schließfehler** ebenso: Was offen bleibt, spricht noch die
    /// alte Rate — dann wird bei der Zielrate nicht weitergemacht.
    func testAFailedPortCloseEndsTheDiagnostics() {
        var model = failedModel()
        model.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        model.apply(.portOpened(.baud9600), atMillis: 4_100)
        model.apply(.identityOutcome(.identified), atMillis: 4_300)

        XCTAssertEqual(model.apply(.portCloseFailed("errno 9"), atMillis: 4_400), .stop)
        XCTAssertEqual(model.phase, .failed(.portCloseFailed("errno 9")))
        XCTAssertFalse(model.needsPort)
        XCTAssertEqual(
            model.audit.entries.filter { $0.action == .diagnosticProbe(.baud38400) }.count, 0
        )
    }

    /// **Eine falsche Rate gilt nicht als die angeforderte.**
    func testAPortOpenedAtTheWrongRateEndsTheDiagnostics() {
        var atStart = failedModel()
        atStart.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        XCTAssertEqual(atStart.apply(.portOpened(.baud38400), atMillis: 4_100), .stop)
        XCTAssertEqual(atStart.phase, .failed(.unexpectedEvent))
        XCTAssertEqual(
            atStart.audit.entries.filter { $0.action == .diagnosticProbe(.baud38400) }.count, 0,
            "Auf einer Verbindung, die niemand angefordert hat, wird nichts gesendet"
        )

        var atTarget = failedModel()
        atTarget.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        atTarget.apply(.portOpened(.baud9600), atMillis: 4_100)
        atTarget.apply(.identityOutcome(.identified), atMillis: 4_300)
        atTarget.apply(.portClosed, atMillis: 4_400)
        XCTAssertEqual(atTarget.apply(.portOpened(.baud9600), atMillis: 4_500), .stop)
        XCTAssertEqual(atTarget.phase, .failed(.unexpectedEvent))
    }

    /// **Eine unerwartete Reihenfolge** beendet die Diagnose, statt sie
    /// stillschweigend weiterlaufen zu lassen.
    func testAnUnexpectedOrderEndsTheDiagnostics() {
        // Antwort, bevor überhaupt geöffnet wurde.
        var early = failedModel()
        early.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        XCTAssertEqual(early.apply(.identityOutcome(.identified), atMillis: 4_050), .stop)
        XCTAssertEqual(early.phase, .failed(.unexpectedEvent))

        // Öffnungsmeldung, während eine Probe läuft.
        var whileProbing = failedModel()
        whileProbing.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        whileProbing.apply(.portOpened(.baud9600), atMillis: 4_100)
        XCTAssertEqual(whileProbing.apply(.portOpened(.baud9600), atMillis: 4_150), .stop)
        XCTAssertEqual(whileProbing.phase, .failed(.unexpectedEvent))

        // Schließmeldung, während eine Probe läuft.
        var closedWhileProbing = failedModel()
        closedWhileProbing.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        closedWhileProbing.apply(.portOpened(.baud9600), atMillis: 4_100)
        XCTAssertEqual(closedWhileProbing.apply(.portClosed, atMillis: 4_150), .stop)
        XCTAssertEqual(closedWhileProbing.phase, .failed(.unexpectedEvent))

        // Frist, während auf das Schließen gewartet wird -- dort steht
        // keine Sendung aus, die ablaufen könnte.
        var whileClosing = failedModel()
        whileClosing.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        whileClosing.apply(.portOpened(.baud9600), atMillis: 4_100)
        whileClosing.apply(.identityOutcome(.identified), atMillis: 4_300)
        XCTAssertEqual(whileClosing.apply(.deadlineReached, atMillis: 4_350), .stop)
        XCTAssertEqual(whileClosing.phase, .failed(.unexpectedEvent))

        // Und die Diagnose lässt sich nicht aus sich selbst heraus neu
        // starten.
        var restarting = failedModel()
        restarting.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        XCTAssertEqual(restarting.apply(.operatorRequestedDiagnostics, atMillis: 4_050), .stop)
        XCTAssertEqual(restarting.phase, .failed(.unexpectedEvent))
    }

    /// Ein Abbruch beendet die Diagnose aus **jedem** Schritt und gibt
    /// den Port frei.
    func testAnAbortEndsTheDiagnosticsFromEveryStep() {
        let steps: [[CommissioningEvent]] = [
            [],
            [.portOpened(.baud9600)],
            [.portOpened(.baud9600), .identityOutcome(.identified)],
            [.portOpened(.baud9600), .identityOutcome(.identified), .portClosed],
            [
                .portOpened(.baud9600), .identityOutcome(.identified), .portClosed,
                .portOpened(.baud38400)
            ]
        ]
        for (index, prefix) in steps.enumerated() {
            var model = failedModel()
            model.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
            for (offset, event) in prefix.enumerated() {
                model.apply(event, atMillis: 4_100 + Int64(offset) * 100)
            }
            XCTAssertTrue(model.needsPort, "Schritt \(index) hält den Port")

            let directive = model.apply(.operatorAborted, atMillis: 5_000)
            XCTAssertEqual(directive, .stop, "Schritt \(index)")
            XCTAssertTrue(directive.releasesPort, "Schritt \(index)")
            XCTAssertEqual(model.phase, .failed(.abortedByOperator), "Schritt \(index)")
            XCTAssertFalse(model.needsPort, "Schritt \(index)")
        }
    }

    /// **Portstatus:** gehalten über den ganzen Ratenwechsel hinweg,
    /// danach frei.
    func testTheDiagnosticsHoldThePortAcrossTheRateChange() {
        var model = failedModel()
        XCTAssertFalse(model.needsPort, "Nach einem Fehlschlag ist der Port frei")

        var held: [Bool] = []
        model.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        held.append(model.needsPort)
        model.apply(.portOpened(.baud9600), atMillis: 4_100)
        held.append(model.needsPort)
        model.apply(.identityOutcome(.identified), atMillis: 4_300)
        held.append(model.needsPort)          // zwischen Close-Anweisung und Bestätigung
        model.apply(.portClosed, atMillis: 4_400)
        held.append(model.needsPort)          // zwischen Open-Anweisung und Bestätigung
        model.apply(.portOpened(.baud38400), atMillis: 4_500)
        held.append(model.needsPort)

        XCTAssertEqual(held, [true, true, true, true, true], "Dazwischen nie losgelassen")

        let finish = model.apply(.identityOutcome(.identified), atMillis: 4_700)
        XCTAssertEqual(finish, .stop)
        XCTAssertTrue(finish.releasesPort, "Das letzte Schließen liegt im Stop-Vertrag")
        XCTAssertFalse(model.needsPort)
        XCTAssertNil(model.pendingDeadlineMillis)
    }

    /// **Das letzte Schließen setzt kein offenes FD voraus:** Auch der
    /// Abbruch vor dem ersten Öffnen endet mit demselben `stop`.
    func testTheFinalCloseNeverPresumesAnOpenDescriptor() {
        var neverOpened = failedModel()
        neverOpened.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        let directive = neverOpened.apply(.portOpenFailed("errno 16"), atMillis: 4_100)

        XCTAssertEqual(directive, .stop)
        XCTAssertTrue(directive.releasesPort)
        XCTAssertNotEqual(directive, .closePort, "Kein Schließen dessen, was nie offen war")
        XCTAssertFalse(neverOpened.needsPort)
    }

    /// **Der Auditbericht:** genau zwei benannte Proben, je Rate eine,
    /// mit dem richtigen Ergebnis — und kein einziges
    /// Konfigurationstelegramm.
    func testTheDiagnosticsAuditHasExactlyOneNamedProbePerRate() {
        var model = failedModel()
        let entriesBefore = model.audit.entries.count
        runDiagnostics(&model, startingOutcome: .timeout, targetOutcome: .identified)

        let added = model.audit.entries.suffix(model.audit.entries.count - entriesBefore)
        XCTAssertEqual(
            added.map(\.action),
            [.diagnosticProbe(.baud9600), .diagnosticProbe(.baud38400)],
            "Nur Identitätsproben, kein Login, kein Baudtelegramm, kein Rückstellkommando"
        )
        XCTAssertEqual(added.map(\.outcome), [.timedOut, .acknowledged])
        XCTAssertEqual(added.map(\.attemptNumber), [1, 1], "Keine Wiederholung")
        XCTAssertTrue(added.allSatisfy { $0.targetAddress == model.recipe.verificationAddress.rawValue })

        for entry in added {
            let rendered = String(describing: entry)
            for byte in testSecretBytes {
                XCTAssertFalse(rendered.contains(String(byte)))
            }
            XCTAssertFalse(rendered.contains("payload"))
            XCTAssertFalse(rendered.contains("Payload"))
        }
    }

    /// **Die Probe ist der einzige Sendefall der Diagnose** — und sie
    /// verlangt wie jede Sendung einen geleerten Empfangspuffer.
    func testTheProbeIsTheOnlySendCaseAndDemandsAFlushedReceiveBuffer() {
        var model = failedModel()
        let directives = runDiagnostics(
            &model, startingOutcome: .identified, targetOutcome: .identified
        )

        let sending = directives.filter(\.isSendDirective)
        XCTAssertEqual(
            sending,
            [
                .sendIdentityProbe(address: 0x00, deadlineMillis: 6_100),
                .sendIdentityProbe(address: 0x00, deadlineMillis: 6_500)
            ]
        )
        XCTAssertTrue(sending.allSatisfy(\.requiresReceiveBufferFlush))
        // Und **kein** Konfigurationstelegramm ist dabei.
        for directive in directives {
            switch directive {
            case .sendSettingsMode, .sendLogin, .sendBaudSwitch, .sendMeasurementMode:
                XCTFail("Die Diagnose sendet kein Konfigurationstelegramm: \(directive)")
            case .none, .sendIdentityProbe, .closePort, .openPort, .hold, .stop:
                break
            }
        }
    }

    /// Ein Messstrom hält die Diagnose in **keinem** Schritt auf und
    /// belegt in keinem etwas.
    func testAnObservedScanStreamNeverCountsAsAnIdentityResult() {
        var model = failedModel()
        model.apply(.operatorRequestedDiagnostics, atMillis: 4_000)
        XCTAssertEqual(model.apply(.acknowledgement(.observedScanProfile), atMillis: 4_050), .none)
        XCTAssertEqual(model.phase, .runningDiagnostics(step: .openingPort(.baud9600), report: emptyReport))

        model.apply(.portOpened(.baud9600), atMillis: 4_100)
        let deadline = model.pendingDeadlineMillis
        XCTAssertEqual(model.apply(.acknowledgement(.observedScanProfile), atMillis: 4_150), .none)
        XCTAssertEqual(
            model.phase, .runningDiagnostics(step: .probing(.baud9600), report: emptyReport),
            "Ein Messstrom ist kein Identitätsergebnis"
        )
        XCTAssertEqual(model.pendingDeadlineMillis, deadline, "Und verschiebt die Frist nicht")
        XCTAssertTrue(model.observedScanProfileStream, "Beobachtet wird er trotzdem")
    }

    /// **Erschöpfende Liste der Diagnoseschritte** — ein neuer Schritt
    /// muss hier bewusst mitgepflegt werden.
    func testTheDiagnosticsStepsAreExactlyThese() {
        let allSteps: [CommissioningDiagnosticsStep] = [
            .openingPort(.baud9600),
            .probing(.baud9600),
            .closingPort(.baud9600)
        ]
        XCTAssertEqual(allSteps.count, 3, "Neuer Schritt? Dann hier bewusst mitpflegen.")
        // Dieselben Schritte gibt es bei der Zielrate; sie sind über die
        // Rate unterscheidbar, nicht über einen eigenen Fall.
        XCTAssertNotEqual(
            CommissioningDiagnosticsStep.openingPort(.baud9600),
            CommissioningDiagnosticsStep.openingPort(.baud38400)
        )
    }

    func testDiagnosticsAreOnlyOfferedAfterAFailure() {
        var model = model()
        XCTAssertEqual(model.apply(.operatorRequestedDiagnostics, atMillis: 1_000), .stop)
        XCTAssertEqual(model.phase, .failed(.unexpectedEvent))
    }

    // MARK: - Diagnosehilfen

    private var emptyReport: CommissioningDiagnosticsReport {
        CommissioningDiagnosticsReport(outcomeAtStartingRate: nil, outcomeAtTargetRate: nil)
    }

    /// Ein Modell nach einem echten Fehlschlag — der einzige Zustand, aus
    /// dem die Diagnose angeboten wird.
    private func failedModel() -> CommissioningModel {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.deadlineReached, atMillis: 3_000)
        return model
    }

    /// Führt die vollständige Diagnosefolge und gibt jede Anweisung
    /// zurück.
    @discardableResult
    private func runDiagnostics(
        _ model: inout CommissioningModel,
        startingOutcome: IdentityProbeOutcome,
        targetOutcome: IdentityProbeOutcome
    ) -> [CommissioningDirective] {
        [
            model.apply(.operatorRequestedDiagnostics, atMillis: 4_000),
            model.apply(.portOpened(.baud9600), atMillis: 4_100),
            model.apply(.identityOutcome(startingOutcome), atMillis: 4_300),
            model.apply(.portClosed, atMillis: 4_400),
            model.apply(.portOpened(.baud38400), atMillis: 4_500),
            model.apply(.identityOutcome(targetOutcome), atMillis: 4_700)
        ]
    }

    // MARK: - Experimenteller Messmodus (SICK-0330a-0)

    func testTheMeasurementModeStepIsSeparateAndOnlyAfterVerification() {
        var model = model()
        XCTAssertEqual(model.apply(.operatorRequestedMeasurementMode, atMillis: 1_000), .stop)
        XCTAssertEqual(model.phase, .failed(.unexpectedEvent))

        var verified = self.model()
        runSuccessfulSwitch(&verified)
        let directive = verified.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)
        XCTAssertEqual(directive, .sendMeasurementMode(deadlineMillis: 8_000))
        XCTAssertEqual(verified.phase, .awaitingMeasurementStream(deadlineMillis: 8_000))
    }

    /// **Pflichtnachweis 3:** Die Sendung bei `t = 5.000` trägt exakt die
    /// absolute Stromfrist `8.000` — die feste 3-Sekunden-Frist, nicht
    /// das 2-Sekunden-Fenster der übrigen Sendungen.
    func testMeasurementModeCarriesTheFixedThreeSecondStreamDeadline() {
        var model = model()
        runSuccessfulSwitch(&model)
        let directive = model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

        XCTAssertEqual(directive, .sendMeasurementMode(deadlineMillis: 8_000))
        XCTAssertEqual(model.pendingDeadlineMillis, 8_000)
        XCTAssertEqual(model.recipe.measurementStreamTimeoutMilliseconds, 3_000)
    }

    /// **Pflichtnachweis 3, Fortsetzung:** ACK, jede unlesbare/unbekannte
    /// Antwort und Stille lassen die Frist **exakt** stehen — sie
    /// entscheiden den Schritt nicht und senden nichts erneut.
    func testEveryNonRejectingAcknowledgementLeavesTheStreamDeadlineUntouched() {
        let outcomes: [AcknowledgementOutcome] = [
            .acknowledged, .unknownStatus(0x02), .missingStatusByte,
            .unexpectedCommandByte(0x06), .undecodable, .timeout
        ]
        for outcome in outcomes {
            var model = self.model()
            runSuccessfulSwitch(&model)
            model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

            let directive = model.apply(.acknowledgement(outcome), atMillis: 5_150)

            XCTAssertEqual(directive, .none, "\(outcome): weder Erfolg noch sofortiger Fehler")
            XCTAssertEqual(
                model.phase, .awaitingMeasurementStream(deadlineMillis: 8_000),
                "\(outcome): unverändert dieselbe Wartephase"
            )
            XCTAssertEqual(model.pendingDeadlineMillis, 8_000, "\(outcome): dieselbe Frist")
            XCTAssertEqual(
                model.audit.entries.filter { $0.action == .measurementModeRequest }.count, 1,
                "\(outcome): genau eine Sendung"
            )
        }
    }

    /// **Pflichtnachweis 4:** ACK ohne nachfolgenden B0-Beleg ist kein
    /// Erfolg — am Fristende folgt `measurementStreamAbsent`.
    func testAnAcknowledgementWithoutAFollowingStreamEndsAsMeasurementStreamAbsent() {
        var model = model()
        runSuccessfulSwitch(&model)
        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 5_150)

        let directive = model.apply(.deadlineReached, atMillis: 8_000)

        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.measurementStreamAbsent))
        XCTAssertFalse(model.needsPort)
        XCTAssertFalse(model.observedScanProfileStream)
    }

    /// **Pflichtnachweis 5:** Unlesbar/unbekannt/keine Quittung und **erst
    /// danach** ein neuer B0-Frame **innerhalb derselben Frist** führt
    /// zum Stromerfolg — der Port bleibt gehalten.
    func testAnObservedScanProfileAfterInconclusiveAnswersWithinTheSameDeadlineConfirmsTheStream() {
        var model = model()
        runSuccessfulSwitch(&model)
        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)
        model.apply(.acknowledgement(.undecodable), atMillis: 5_150)
        model.apply(.acknowledgement(.unknownStatus(0x02)), atMillis: 5_300)

        let directive = model.apply(.acknowledgement(.observedScanProfile), atMillis: 7_900)

        XCTAssertEqual(directive, .hold, "Ruhen, aber halten -- erst der Sitzungsabschluss gibt frei")
        XCTAssertEqual(directive.releasesPort, false)
        XCTAssertEqual(model.phase, .measurementStreamConfirmed)
        XCTAssertTrue(model.needsPort)
        XCTAssertTrue(model.observedScanProfileStream)
        XCTAssertNil(model.pendingDeadlineMillis)
        XCTAssertEqual(
            model.audit.entries.filter { $0.action == .measurementModeRequest }.count, 1,
            "Genau eine Sendung, nie eine Wiederholung"
        )
    }

    /// **Pflichtnachweis 6:** Ein eindeutiges NACK stoppt **sofort** als
    /// `measurementModeRejected` -- auch wenn danach noch ein B0-Ereignis
    /// einträfe, ändert das nichts mehr.
    func testARejectedMeasurementModeStopsImmediatelyEvenWithALaterScanProfile() {
        var model = model()
        runSuccessfulSwitch(&model)
        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

        let directive = model.apply(.acknowledgement(.rejected), atMillis: 5_150)

        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.measurementModeRejected))
        XCTAssertFalse(model.needsPort)
        XCTAssertNil(model.pendingDeadlineMillis)

        // Ein B0-Ereignis danach ändert nichts mehr -- der Ablauf ist zu
        // Ende, `applyAtRestingPoint`s `.failed`-Zweig merkt es sich nur
        // als Information.
        let afterwards = model.apply(.acknowledgement(.observedScanProfile), atMillis: 5_200)
        XCTAssertEqual(afterwards, .none)
        XCTAssertEqual(model.phase, .failed(.measurementModeRejected))
    }

    /// **Pflichtnachweis 7:** Ein **vor** der MMK-Anforderung beobachtetes
    /// B0 erfüllt den späteren Schritt nicht -- nur ein B0 **nach** der
    /// Anforderung zählt.
    func testAScanProfileObservedBeforeTheRequestDoesNotSatisfyItLater() {
        var model = model()
        runSuccessfulSwitch(&model)
        // Ein Messstrom am Ruhepunkt `.verified`, **vor** der Anforderung.
        XCTAssertEqual(model.apply(.acknowledgement(.observedScanProfile), atMillis: 4_800), .none)
        XCTAssertTrue(model.observedScanProfileStream, "Beobachtet wird er trotzdem")

        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)
        // Danach kommt nichts mehr -- nur die alte Beobachtung liegt vor.
        let directive = model.apply(.deadlineReached, atMillis: 8_000)

        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(
            model.phase, .failed(.measurementStreamAbsent),
            "Die frühere Beobachtung erfüllt die Anforderung nicht rückwirkend"
        )
    }

    /// **Pflichtnachweis 8:** B0 im MMK-Fenster rührt `verifiedBaudRate`
    /// nicht an -- die Rate bleibt exakt der bereits belegte B1-Wert.
    func testTheStreamConfirmationNeverTouchesVerifiedBaudRate() {
        var model = model()
        runSuccessfulSwitch(&model)
        let rateBeforeMeasurementMode = model.verifiedBaudRate
        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

        let directive = model.apply(.acknowledgement(.observedScanProfile), atMillis: 5_200)

        XCTAssertEqual(directive, .hold)
        XCTAssertEqual(model.phase, .measurementStreamConfirmed)
        XCTAssertEqual(model.verifiedBaudRate, rateBeforeMeasurementMode, "B0 setzt die Rate nicht neu")
        XCTAssertEqual(model.verifiedBaudRate, .baud38400)
    }

    /// **Pflichtnachweis 9:** Egal wie viele nicht entscheidende Antworten
    /// eintreffen -- die MMK-Sendung geht genau **einmal** hinaus, keine
    /// zweite Frist, kein Portöffnen/-schließen.
    func testTheMeasurementModeIsSentExactlyOnceRegardlessOfHowManyInconclusiveAnswersArrive() {
        var model = model()
        runSuccessfulSwitch(&model)
        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

        let inconclusive: [AcknowledgementOutcome] = [
            .acknowledged, .unknownStatus(0x02), .missingStatusByte,
            .unexpectedCommandByte(0x06), .undecodable, .timeout
        ]
        var directives: [CommissioningDirective] = []
        for (offset, outcome) in inconclusive.enumerated() {
            directives.append(model.apply(.acknowledgement(outcome), atMillis: 5_100 + Int64(offset)))
        }

        XCTAssertTrue(directives.allSatisfy { $0 == .none })
        XCTAssertEqual(model.phase, .awaitingMeasurementStream(deadlineMillis: 8_000))
        XCTAssertEqual(model.pendingDeadlineMillis, 8_000)
        XCTAssertEqual(
            model.audit.entries.filter { $0.action == .measurementModeRequest }.count, 1,
            "Genau eine Sendung, unabhängig davon, wie viele Antworten eintreffen"
        )
        XCTAssertFalse(
            directives.contains { $0 == .closePort || $0 == .openPort(.baud38400) },
            "Kein Portöffnen/-schließen in diesem Fenster"
        )
    }

    /// Der Abschluss ist eine Bedienhandlung an einem Ruhepunkt -- die
    /// Stromfrist läuft noch, also gibt es hier nichts zu „beenden".
    func testFinishingMidMeasurementStreamWaitIsNotAQuietSuccess() {
        var model = model()
        runSuccessfulSwitch(&model)
        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

        let directive = model.apply(.operatorFinishedSession, atMillis: 5_050)

        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.unexpectedEvent), "Nicht als beendet ausgegeben")
        XCTAssertNotEqual(model.phase, .sessionFinished)
        XCTAssertTrue(
            model.audit.entries.filter { $0.action == .measurementModeRequest }.count == 1,
            "Der Abbruch sendet nichts erneut"
        )
    }

    // MARK: - MMK-Audit und harte Stromfrist (SICK-0330a-0-K1)

    /// **Pflichtnachweis 1:** ACK vor der Frist, danach B0 vor der
    /// Frist -- das Audit zeigt **beide** Tatsachen gleichzeitig, und
    /// die Phase endet regulär im Stromerfolg.
    func testAcknowledgedThenStreamRecordsBothFactsOnTheSameEntry() {
        var model = model()
        runSuccessfulSwitch(&model)
        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 5_150)

        let directive = model.apply(.acknowledgement(.observedScanProfile), atMillis: 7_900)

        XCTAssertEqual(directive, .hold)
        XCTAssertEqual(model.phase, .measurementStreamConfirmed)
        let entry = model.audit.entries.last(where: { $0.action == .measurementModeRequest })
        XCTAssertEqual(entry?.immediateResponse, .acknowledged)
        XCTAssertEqual(entry?.outcome, .observedScanProfileStream)
    }

    /// **Pflichtnachweis 2:** Eine unlesbare Antwort vor der Frist,
    /// danach B0 vor der Frist -- dieselbe redigierte Kategorie **und**
    /// die Stromwirkung stehen gemeinsam auf demselben Eintrag.
    func testUnreadableResponseThenStreamRecordsBothFactsOnTheSameEntry() {
        var model = model()
        runSuccessfulSwitch(&model)
        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)
        model.apply(.acknowledgement(.undecodable), atMillis: 5_150)

        let directive = model.apply(.acknowledgement(.observedScanProfile), atMillis: 7_900)

        XCTAssertEqual(directive, .hold)
        XCTAssertEqual(model.phase, .measurementStreamConfirmed)
        let entry = model.audit.entries.last(where: { $0.action == .measurementModeRequest })
        XCTAssertEqual(entry?.immediateResponse, .unreadable)
        XCTAssertEqual(entry?.outcome, .observedScanProfileStream)
    }

    /// **Pflichtnachweis 3:** Zwei verschiedene unbekannte Status- bzw.
    /// Kommandobytes ergeben dieselbe datenfreie Auditkategorie -- und
    /// diese Kategorie trägt strukturell nie ein Rohbyte.
    func testTwoDifferentUnknownStatusOrCommandBytesYieldTheSameRedactedCategoryWithNoPayload() {
        let variants: [(AcknowledgementOutcome, AcknowledgementOutcome)] = [
            (.unknownStatus(0x02), .unknownStatus(0xFE)),
            (.unexpectedCommandByte(0x06), .unexpectedCommandByte(0x99))
        ]
        for (a, b) in variants {
            var modelA = model()
            runSuccessfulSwitch(&modelA)
            modelA.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)
            modelA.apply(.acknowledgement(a), atMillis: 5_150)

            var modelB = model()
            runSuccessfulSwitch(&modelB)
            modelB.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)
            modelB.apply(.acknowledgement(b), atMillis: 5_150)

            let entryA = modelA.audit.entries.last(where: { $0.action == .measurementModeRequest })
            let entryB = modelB.audit.entries.last(where: { $0.action == .measurementModeRequest })
            XCTAssertEqual(entryA?.immediateResponse, .unreadable, "\(a)")
            XCTAssertEqual(entryA?.immediateResponse, entryB?.immediateResponse, "\(a) vs \(b)")
        }

        // Strukturell: `unreadable` trägt keine Nutzlast -- es gibt kein
        // Byte, das irgendwo erscheinen könnte.
        let mirror = Mirror(reflecting: CommissioningImmediateResponse.unreadable)
        XCTAssertEqual(mirror.children.count, 0, "unreadable trägt keine Nutzlast")
    }

    /// **Pflichtnachweis 4:** Ohne jede unmittelbare Antwort und ohne B0
    /// zeigt das Audit nach Fristablauf „keine Antwort"
    /// (`immediateResponse == nil`) und „kein Strom" (`outcome ==
    /// .timedOut`) getrennt.
    func testNoImmediateResponseAndNoStreamAreRecordedSeparatelyAfterTheDeadline() {
        var model = model()
        runSuccessfulSwitch(&model)
        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

        let directive = model.apply(.deadlineReached, atMillis: 8_000)

        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.measurementStreamAbsent))
        XCTAssertNil(model.pendingDeadlineMillis)
        let entry = model.audit.entries.last(where: { $0.action == .measurementModeRequest })
        XCTAssertNil(entry?.immediateResponse, "keine Antwort")
        XCTAssertEqual(entry?.outcome, .timedOut, "kein Strom")
    }

    /// **Pflichtnachweis 5:** Sendung bei 5.000 (Frist 8.000): B0 bei
    /// 7.999 bestätigt, B0 bei 8.000 und 8.001 endet jeweils
    /// `.measurementStreamAbsent`, nie bestätigt.
    func testTheStreamDeadlineIsAHardBoundaryForTheConfirmingScanProfile() {
        var confirmedJustBeforeDeadline = model()
        runSuccessfulSwitch(&confirmedJustBeforeDeadline)
        confirmedJustBeforeDeadline.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)
        let confirmingDirective = confirmedJustBeforeDeadline.apply(
            .acknowledgement(.observedScanProfile), atMillis: 7_999
        )
        XCTAssertEqual(confirmingDirective, .hold)
        XCTAssertEqual(confirmedJustBeforeDeadline.phase, .measurementStreamConfirmed)

        for lateMillis in [Int64(8_000), Int64(8_001)] {
            var model = self.model()
            runSuccessfulSwitch(&model)
            model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

            let directive = model.apply(.acknowledgement(.observedScanProfile), atMillis: lateMillis)

            XCTAssertEqual(directive, .stop, "\(lateMillis)")
            XCTAssertEqual(model.phase, .failed(.measurementStreamAbsent), "\(lateMillis)")
        }
    }

    /// **Pflichtnachweis 6:** ACK und NACK bei oder nach 8.000
    /// unterliegen ebenfalls der bereits abgelaufenen Stromfrist -- kein
    /// verspäteter alternativer Endzustand.
    func testALateAcknowledgedOrRejectedResponseNeverProducesAnAlternateOutcome() {
        let lateOutcomes: [AcknowledgementOutcome] = [.acknowledged, .rejected]
        for outcome in lateOutcomes {
            var model = self.model()
            runSuccessfulSwitch(&model)
            model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

            let directive = model.apply(.acknowledgement(outcome), atMillis: 8_000)

            XCTAssertEqual(directive, .stop, "\(outcome)")
            XCTAssertEqual(model.phase, .failed(.measurementStreamAbsent), "\(outcome)")
            XCTAssertNotEqual(
                model.phase, .failed(.measurementModeRejected),
                "Kein verspäteter alternativer Endzustand für \(outcome)"
            )
        }
    }

    /// **Pflichtnachweis 7:** `deadlineReached` bei 7.999 verkürzt die
    /// Frist nicht; dasselbe Ereignis bei 8.000 endet
    /// `.measurementStreamAbsent`.
    func testAPrematureDeadlineReachedDoesNotShortenTheStreamDeadline() {
        var model = model()
        runSuccessfulSwitch(&model)
        model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

        let premature = model.apply(.deadlineReached, atMillis: 7_999)
        XCTAssertEqual(premature, .none)
        XCTAssertEqual(model.phase, .awaitingMeasurementStream(deadlineMillis: 8_000))
        XCTAssertEqual(model.pendingDeadlineMillis, 8_000)

        let onTime = model.apply(.deadlineReached, atMillis: 8_000)
        XCTAssertEqual(onTime, .stop)
        XCTAssertEqual(model.phase, .failed(.measurementStreamAbsent))
        XCTAssertNil(model.pendingDeadlineMillis)
    }

    // MARK: - Bereits belegte Zielrate (SICK-0330a-0, Teil 1)

    /// **Pflichtnachweis 1:** Frisches Modell + der von der
    /// Verbindungspolitik bereits bestätigte B1-Beleg -> Zielrate
    /// verifiziert, Port gehalten, keine wirkende Direktive, kein Login
    /// und keine zweite Probe.
    func testAnAlreadyConfirmedIdentityAtTheTargetRateIsAcceptedWithoutASecondProbeOrLogin() {
        var model = model()
        let directive = model.apply(.identityAlreadyConfirmedAtTargetRate, atMillis: 1_000)

        XCTAssertEqual(directive, .hold, "Kein Login, keine zweite Probe -- nur ein Ruhepunkt mit gehaltenem Port")
        XCTAssertFalse(directive.releasesPort)
        XCTAssertEqual(model.phase, .verified)
        XCTAssertEqual(model.verifiedBaudRate, .baud38400)
        XCTAssertTrue(model.needsPort)
        XCTAssertNil(model.pendingDeadlineMillis)
        XCTAssertTrue(model.audit.entries.isEmpty, "Keine Sendung dieses Modells, kein Eintrag")
    }

    /// **Pflichtnachweis 2:** Der Eintritt trägt keinen
    /// `IdentityProbeOutcome` — er ist mit einem B0-Ereignis strukturell
    /// nicht zu verwechseln, und ein echtes B0-Ereignis an einem
    /// frischen Modell verifiziert nichts.
    func testTheEntryCannotBeConfusedWithAnObservedScanProfile() {
        var model = model()
        let directive = model.apply(.acknowledgement(.observedScanProfile), atMillis: 1_000)

        XCTAssertEqual(directive, .none)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.verifiedBaudRate)
        XCTAssertTrue(model.observedScanProfileStream, "Beobachtet wird es trotzdem")
    }

    /// Ein doppeltes oder mitten in einem laufenden Ablauf eintreffendes
    /// Auftreten ist ein sichtbarer Fehler -- **kein** stiller Neustart.
    func testTheEntryIsRejectedOutsideAFreshModel() {
        // Mitten in der Ausgangsprüfung.
        var busy = model()
        busy.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        let midFlow = busy.apply(.identityAlreadyConfirmedAtTargetRate, atMillis: 1_050)
        XCTAssertEqual(midFlow, .stop)
        XCTAssertEqual(busy.phase, .failed(.unexpectedEvent))

        // Doppelt, nach einer schon erfolgten Übernahme.
        var already = model()
        already.apply(.identityAlreadyConfirmedAtTargetRate, atMillis: 1_000)
        let duplicate = already.apply(.identityAlreadyConfirmedAtTargetRate, atMillis: 1_100)
        XCTAssertEqual(duplicate, .stop)
        XCTAssertEqual(already.phase, .failed(.unexpectedEvent))
        // Die zuvor belegte Rate bleibt unangetastet stehen -- kein
        // stiller Neustart, der sie löschen oder erneut setzen würde.

        // Nach einem regulär durchlaufenen, echten Wechsel.
        var real = model()
        runSuccessfulSwitch(&real)
        let afterRealSwitch = real.apply(.identityAlreadyConfirmedAtTargetRate, atMillis: 5_000)
        XCTAssertEqual(afterRealSwitch, .stop)
        XCTAssertEqual(real.phase, .failed(.unexpectedEvent))
    }

    /// Der übernommene Beleg trägt genauso weit wie ein selbst
    /// durchgeführter: Der Messmodus-Schritt setzt unverändert darauf
    /// auf.
    func testTheAlreadyConfirmedEntryCarriesAsFarAsARealVerification() {
        var model = model()
        model.apply(.identityAlreadyConfirmedAtTargetRate, atMillis: 1_000)

        let directive = model.apply(.operatorRequestedMeasurementMode, atMillis: 2_000)

        XCTAssertEqual(directive, .sendMeasurementMode(deadlineMillis: 5_000))
        XCTAssertEqual(model.phase, .awaitingMeasurementStream(deadlineMillis: 5_000))
        if case .openPort = directive { XCTFail("Kein verdecktes Wiederöffnen") }
    }

    // MARK: - Audit

    /// Das Protokoll trägt **nie** Bytes oder ein Geheimnis.
    func testTheAuditCarriesNeitherBytesNorSecret() {
        var model = model()
        runSuccessfulSwitch(&model)

        XCTAssertFalse(model.audit.entries.isEmpty)
        for entry in model.audit.entries {
            let rendered = String(describing: entry)
            for byte in testSecretBytes {
                XCTAssertFalse(rendered.contains(String(byte)))
            }
            XCTAssertFalse(rendered.contains("payload"))
            XCTAssertFalse(rendered.contains("Payload"))
        }
    }

    /// Jeder Eintrag trägt einen monotonen Zeitpunkt des Aufrufers.
    func testEveryAuditEntryCarriesTheCallersMonotonicInstant() {
        var model = model()
        runSuccessfulSwitch(&model)
        let millis = model.audit.entries.map(\.monotonicMillis)
        XCTAssertEqual(millis, millis.sorted(), "Zeitpunkte laufen nie rückwärts")
        XCTAssertEqual(millis.first, 1_000)
    }

    func testTheAuditRecordsEveryTransmissionExactlyOnce() {
        var model = model()
        runSuccessfulSwitch(&model)
        XCTAssertEqual(
            model.audit.entries.map(\.action),
            [
                .identityCheck(.baud9600),
                .settingsMode,
                .login,
                .login,
                .login,
                .baudSwitchRequest,
                .verification(.baud38400)
            ]
        )
        XCTAssertTrue(model.audit.entries.allSatisfy { $0.outcome != .sent })
    }

    // MARK: - Portbedarf

    func testTheModelSaysWhenItNeedsThePort() {
        var model = model()
        XCTAssertFalse(model.needsPort, "Vor dem Beginn nicht")
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        XCTAssertTrue(model.needsPort, "Während einer laufenden Sendung schon")
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        XCTAssertTrue(model.needsPort, "Am Ruhepunkt weiterhin — er hält den Port")
        runSuccessfulSwitchFromRestingPoint(&model)
        XCTAssertTrue(model.needsPort, "Nach der Verifikation auch")
        model.apply(.operatorFinishedSession, atMillis: 9_000)
        XCTAssertFalse(model.needsPort, "Erst der Sitzungsabschluss gibt frei")
    }

    /// **Auflage A7, Kern:** Der Port bleibt vom Beginn der
    /// Ausgangsprüfung bis zur `closingPort`-Phase durchgehend gehalten.
    func testThePortIsHeldFromTheStartingCheckUntilTheClosingPhase() {
        var model = model()
        var held: [Bool] = []

        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        held.append(model.needsPort)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)
        held.append(model.needsPort)
        model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        held.append(model.needsPort)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)
        held.append(model.needsPort)
        model.apply(.acknowledgement(.acknowledged), atMillis: 2_150)
        held.append(model.needsPort)
        let closing = model.apply(.acknowledgement(.acknowledged), atMillis: 2_300)
        held.append(model.needsPort)

        XCTAssertEqual(closing, .closePort, "Erst hier wird die alte Verbindung geschlossen")
        XCTAssertEqual(held, [true, true, true, true, true, true], "Dazwischen nie losgelassen")
    }

    /// **Auflage A7:** Das Login geht über dieselbe Verbindung — es gibt
    /// **kein** verdecktes Wiederöffnen davor.
    func testTheLoginNeverAsksForAReopenedPort() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_100)

        let settingsMode = model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000)
        let directive = model.apply(.acknowledgement(.acknowledged), atMillis: 2_000)

        XCTAssertEqual(settingsMode, .sendSettingsMode(deadlineMillis: 4_000))
        XCTAssertEqual(directive, .sendLogin(attempt: 1, deadlineMillis: 4_000))
        if case .openPort = directive { XCTFail("Kein verdecktes Wiederöffnen") }
        XCTAssertNotEqual(directive, .openPort(.baud9600))
    }

    /// **Auflage A7:** Dasselbe für den experimentellen Messmodus am
    /// bereits bei der Zielrate geöffneten Port.
    func testTheMeasurementModeNeverAsksForAReopenedPort() {
        var model = model()
        runSuccessfulSwitch(&model)

        let directive = model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000)

        XCTAssertEqual(directive, .sendMeasurementMode(deadlineMillis: 8_000))
        if case .openPort = directive { XCTFail("Kein verdecktes Wiederöffnen") }
        XCTAssertNotEqual(directive, .openPort(.baud38400))
    }

    // MARK: - Der einzige Freigabepunkt

    /// **Auflage A7:** Ein erfolgreicher Ablauf gibt den Port
    /// ausschließlich beim ausdrücklichen Sitzungsabschluss frei — auch
    /// nach dem belegten Messstrom.
    func testOnlyTheExplicitSessionEndReleasesThePort() {
        var model = model()
        var directives = runSuccessfulSwitch(&model)
        directives.append(model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000))
        // Weder ein ACK noch eine unlesbare Antwort geben etwas frei --
        // erst der belegte Messstrom bringt die Wartephase zur Ruhe.
        directives.append(model.apply(.acknowledgement(.acknowledged), atMillis: 5_150))
        directives.append(model.apply(.acknowledgement(.observedScanProfile), atMillis: 5_300))

        XCTAssertFalse(
            directives.contains { $0.releasesPort },
            "Bis hierher hat nichts freigegeben"
        )
        XCTAssertEqual(model.phase, .measurementStreamConfirmed)
        XCTAssertTrue(model.needsPort)

        let finish = model.apply(.operatorFinishedSession, atMillis: 6_000)

        XCTAssertEqual(finish, .stop)
        XCTAssertTrue(finish.releasesPort)
        XCTAssertEqual(model.phase, .sessionFinished)
        XCTAssertFalse(model.needsPort)
        XCTAssertNil(model.pendingDeadlineMillis)
    }

    /// Der Abschluss ist eine Bedienhandlung an einem Ruhepunkt, kein
    /// Notausgang mitten in einer Sendung — dafür gibt es den Abbruch.
    func testFinishingMidTransmissionIsNotAQuietSuccess() {
        var model = model()
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)

        let directive = model.apply(.operatorFinishedSession, atMillis: 1_050)

        XCTAssertEqual(directive, .stop)
        XCTAssertEqual(model.phase, .failed(.unexpectedEvent), "Nicht als beendet ausgegeben")
        XCTAssertNotEqual(model.phase, .sessionFinished)
    }

    /// „Nie begonnen" und „bewusst beendet" bleiben unterscheidbar, und
    /// nach dem Abschluss lässt sich neu beginnen.
    func testTheFinishedSessionIsItsOwnStateAndCanStartOver() {
        var model = model()
        XCTAssertEqual(model.apply(.operatorFinishedSession, atMillis: 1_000), .stop)
        XCTAssertEqual(model.phase, .sessionFinished)
        XCTAssertNotEqual(model.phase, .idle)

        let again = model.apply(.operatorRequestedStartingRateCheck, atMillis: 2_000)
        XCTAssertEqual(again, .sendIdentityProbe(address: 0x01, deadlineMillis: 4_000))
        XCTAssertTrue(model.needsPort)
    }

    // MARK: - RX-Puffer vor jedem TX (Befund N1)

    /// **Jede** Sendungsdirektive verlangt das Leeren des
    /// Empfangspuffers — Identität, **alle drei** Login-Sendungen,
    /// Baudwechsel und Messmodus.
    func testEverySendDirectiveDemandsAFlushedReceiveBuffer() {
        var model = model()
        var directives = runSuccessfulSwitch(&model)
        directives.append(model.apply(.operatorRequestedMeasurementMode, atMillis: 5_000))

        let sending = directives.filter(\.isSendDirective)
        XCTAssertEqual(
            sending,
            [
                .sendIdentityProbe(address: 0x01, deadlineMillis: 3_000),
                .sendSettingsMode(deadlineMillis: 4_000),
                .sendLogin(attempt: 1, deadlineMillis: 4_000),
                .sendLogin(attempt: 2, deadlineMillis: 6_000),
                .sendLogin(attempt: 3, deadlineMillis: 8_000),
                .sendBaudSwitch(deadlineMillis: 8_150),
                .sendIdentityProbe(address: 0x00, deadlineMillis: 8_500),
                .sendMeasurementMode(deadlineMillis: 8_000)
            ],
            "Alle drei Login-Sendungen sind einzeln dabei"
        )
        XCTAssertTrue(sending.allSatisfy(\.requiresReceiveBufferFlush))
    }

    /// Und **nichts anderes** verlangt es: Sendung und Leeren decken
    /// sich genau, in beide Richtungen.
    func testFlushingIsDemandedByExactlyTheSendDirectives() {
        let allDirectives: [CommissioningDirective] = [
            .none,
            .sendIdentityProbe(address: 0x01, deadlineMillis: 1),
            .sendSettingsMode(deadlineMillis: 1),
            .sendLogin(attempt: 1, deadlineMillis: 1),
            .sendBaudSwitch(deadlineMillis: 1),
            .sendMeasurementMode(deadlineMillis: 1),
            .closePort,
            .openPort(.baud38400),
            .hold,
            .stop
        ]
        XCTAssertEqual(allDirectives.count, 10, "Neue Anweisung? Dann hier bewusst mitpflegen.")

        for directive in allDirectives {
            XCTAssertEqual(
                directive.requiresReceiveBufferFlush,
                directive.isSendDirective,
                "\(directive)"
            )
        }
        XCTAssertEqual(allDirectives.filter(\.requiresReceiveBufferFlush).count, 5)
        XCTAssertFalse(CommissioningDirective.hold.requiresReceiveBufferFlush)
        XCTAssertFalse(CommissioningDirective.openPort(.baud38400).requiresReceiveBufferFlush)
    }

    @discardableResult
    private func runSuccessfulSwitchFromRestingPoint(
        _ model: inout CommissioningModel
    ) -> [CommissioningDirective] {
        [
            model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000),
            model.apply(.acknowledgement(.acknowledged), atMillis: 2_000),
            model.apply(.acknowledgement(.acknowledged), atMillis: 2_150),
            model.apply(.acknowledgement(.acknowledged), atMillis: 2_300),
            model.apply(.portClosed, atMillis: 2_400),
            model.apply(.portOpened(.baud38400), atMillis: 2_500),
            model.apply(.identityOutcome(.identified), atMillis: 2_650)
        ]
    }
}
