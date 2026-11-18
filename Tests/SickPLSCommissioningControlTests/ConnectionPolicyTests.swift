import Foundation
import XCTest
@testable import SickPLSCommissioningControl
import SickPLSActiveControl
import SickPLSMacTransport

/// Prüft die reine Verbindungspolitik (SICK-0330r) gegen die Pflichtnachweise
/// des Auftrags -- seit SICK-0330r-K1 ergänzt um die Abbruch-/Freigabe- und
/// Redaktionskorrekturen aus `review-sick-0330r.md` (H1-H4).
///
/// **Kein Port, kein Gerät, kein Thread, keine echte Zeit** -- jeder Test
/// treibt `ConnectionPolicyModel.apply(_:)` unmittelbar mit synthetischen
/// Ereignissen.
final class ConnectionPolicyTests: XCTestCase {

    private let validPath = "/dev/cu.usbserial-A1"
    private var port: ConnectionPolicyPort { try! ConnectionPolicyPort.build(path: validPath) }

    // MARK: - Pflichtnachweis 1: Start ohne gültigen Port

    func testStartWithoutAnExplicitValidPortIsNamedRefusedAndProducesNoDirective() {
        var model = ConnectionPolicyModel()
        let directive = model.apply(.operatorRequestedConnection(portPath: ""))
        XCTAssertEqual(directive, .none)
        XCTAssertEqual(model.phase, .failed(.startRefused(.empty)))
        XCTAssertNil(model.port)
        XCTAssertFalse(model.needsPort)
    }

    func testStartWithAPathOutsideTheAllowedPrefixIsNamedRefused() {
        var model = ConnectionPolicyModel()
        let directive = model.apply(.operatorRequestedConnection(portPath: "/dev/tty.usbserial-A1"))
        XCTAssertEqual(directive, .none)
        XCTAssertEqual(
            model.phase,
            .failed(.startRefused(.pathNotAllowed("/dev/tty.usbserial-A1")))
        )
        XCTAssertNil(model.port)
    }

    func testInitializationAlonePicksNoPortAndProducesNothing() {
        let model = ConnectionPolicyModel()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.port)
        XCTAssertFalse(model.needsPort)
    }

    func testAValidStartOpensTheOnePortAtTheTargetRate() {
        var model = ConnectionPolicyModel()
        let directive = model.apply(.operatorRequestedConnection(portPath: validPath))
        XCTAssertEqual(directive, .openPort(port, baudRate: .baud38400))
        XCTAssertEqual(model.phase, .openingPort(windDownTo: nil))
        XCTAssertEqual(model.port, port)
        XCTAssertTrue(model.needsPort)
        XCTAssertEqual(ConnectionPolicyModel.targetBaudRate, .baud38400)
    }

    // MARK: - Pflichtnachweis 2: passiver Fast Path

    func testAScanProfileInThePassiveFastPathLeadsDirectlyToReadyWithoutIdentityOrCommissioning() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        XCTAssertEqual(model.apply(.portOpened), .observeForScanProfile(port, baudRate: .baud38400))
        XCTAssertEqual(model.phase, .awaitingScanProfile)

        let directive = model.apply(.validScanProfileObserved)

        XCTAssertEqual(directive, .none)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.needsPort)
    }

    /// Spy/Tabellenbeleg: Über den gesamten passiven Fast Path hinweg
    /// taucht **nie** eine identitäts- oder commissioningbezogene
    /// Direktive auf.
    func testThePassiveFastPathNeverRequestsIdentityOrCommissioning() {
        var model = ConnectionPolicyModel()
        var directives: [ConnectionPolicyDirective] = []
        directives.append(model.apply(.operatorRequestedConnection(portPath: validPath)))
        directives.append(model.apply(.portOpened))
        directives.append(model.apply(.validScanProfileObserved))

        for directive in directives {
            switch directive {
            case .sendIdentityProbeAtTargetRate, .requestActiveContinuation,
                 .requestCommissioningContinuation:
                XCTFail("Der passive Fast Path hat unnötiges TX angefordert: \(directive)")
            case .none, .openPort, .observeForScanProfile, .closePort:
                continue
            }
        }
        XCTAssertEqual(model.phase, .ready)
    }

    // MARK: - Pflichtnachweis 3: kein B0 -> B1 bei 38.400 -> aktive Fortsetzung

    func testNoScanProfileLeadsExactlyToTheIdentityCheckAtTheTargetRate() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)

        let directive = model.apply(.observationTimedOut)

        XCTAssertEqual(directive, .sendIdentityProbeAtTargetRate(port, baudRate: .baud38400))
        XCTAssertEqual(model.phase, .checkingIdentityAtTargetRate)
        XCTAssertTrue(model.needsPort)
    }

    func testValidB1AtTheTargetRateLeadsToTheActiveContinuationWithThePortHeld() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)

        let directive = model.apply(.identityOutcome(.identified))

        XCTAssertEqual(directive, .requestActiveContinuation(port, baudRate: .baud38400))
        XCTAssertEqual(model.phase, .continuingActively)
        XCTAssertTrue(model.needsPort, "Der Port bleibt für die aktive Fortsetzung gehalten")
    }

    func testValidB1NeverRequestsAnotherBaudSwitch() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)

        let directive = model.apply(.identityOutcome(.identified))

        if case .requestCommissioningContinuation = directive {
            XCTFail("Ein belegtes B1 darf nie zu einer Commissioning-Fortsetzung führen")
        }
        XCTAssertNotEqual(directive, .openPort(port, baudRate: .baud38400))
    }

    // MARK: - Pflichtnachweis 4: Timeout/unerwartet/unauswertbar -> Commissioning ab 9600

    func testIdentityTimeoutAtTheTargetRateLeadsToTheCommissioningContinuationAfterClosing() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)

        let closeDirective = model.apply(.identityOutcome(.timeout))
        XCTAssertEqual(closeDirective, .closePort(port))
        XCTAssertEqual(model.phase, .closingPort(.commissioningContinuation(.timeout)))
        XCTAssertTrue(model.needsPort, "Der Port ist noch nicht bestätigt geschlossen")

        let handoffDirective = model.apply(.portClosed)
        XCTAssertEqual(
            handoffDirective,
            .requestCommissioningContinuation(port, .timeout, baudRate: .baud9600)
        )
        XCTAssertEqual(model.phase, .continuingViaCommissioning(.timeout))
        XCTAssertFalse(model.needsPort, "Nach bestätigtem Schließen ist der Port frei")
    }

    func testUnexpectedIdentityResponseAtTheTargetRateLeadsToTheCommissioningContinuation() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)

        XCTAssertEqual(
            model.apply(.identityOutcome(.unexpectedResponse(commandByte: 0x42))),
            .closePort(port)
        )
        XCTAssertEqual(
            model.phase,
            .closingPort(.commissioningContinuation(.unexpectedResponse))
        )

        XCTAssertEqual(
            model.apply(.portClosed),
            .requestCommissioningContinuation(port, .unexpectedResponse, baudRate: .baud9600)
        )
        XCTAssertEqual(
            model.phase,
            .continuingViaCommissioning(.unexpectedResponse)
        )
    }

    func testUndecodableIdentityResponseAtTheTargetRateLeadsToTheCommissioningContinuation() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)

        XCTAssertEqual(model.apply(.identityOutcome(.ambiguous)), .closePort(port))
        XCTAssertEqual(model.phase, .closingPort(.commissioningContinuation(.ambiguous)))

        XCTAssertEqual(
            model.apply(.portClosed),
            .requestCommissioningContinuation(port, .ambiguous, baudRate: .baud9600)
        )
        XCTAssertEqual(model.phase, .continuingViaCommissioning(.ambiguous))
    }

    func testNoneOfTheThreeIdentityGapsInventAConfirmedRateOrIdentity() {
        for outcome: IdentityProbeOutcome in [.timeout, .unexpectedResponse(commandByte: 0x11), .ambiguous] {
            var model = ConnectionPolicyModel()
            model.apply(.operatorRequestedConnection(portPath: validPath))
            model.apply(.portOpened)
            model.apply(.observationTimedOut)
            model.apply(.identityOutcome(outcome))
            model.apply(.portClosed)

            guard case .continuingViaCommissioning = model.phase else {
                return XCTFail("Erwartete Commissioning-Fortsetzung für \(outcome), war \(model.phase)")
            }
        }
    }

    // MARK: - Pflichtnachweis 5: B0 gewinnt während der Prüfphase

    func testAScanProfileDuringTheIdentityCheckWinsAndPreventsAnyFurtherActiveContinuation() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)

        let directive = model.apply(.validScanProfileObserved)
        XCTAssertEqual(directive, .none)
        XCTAssertEqual(model.phase, .ready)

        // Eine verspätete B1-Antwort für die inzwischen überholte Probe
        // darf `ready` weder verlassen noch doch noch eine Fortsetzung
        // anfordern.
        let lateOutcome = model.apply(.identityOutcome(.identified))
        XCTAssertEqual(lateOutcome, .none)
        XCTAssertEqual(model.phase, .ready)
    }

    func testB1AloneNeverReachesReady() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)
        model.apply(.identityOutcome(.identified))

        XCTAssertNotEqual(model.phase, .ready)
        XCTAssertEqual(model.phase, .continuingActively)
    }

    // MARK: - Pflichtnachweis 6: Fehler, Abbruch, Stromverlust, geordnete Freigabe

    func testPortOpenFailureEndsVisiblyWithoutAPortToClose() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))

        let directive = model.apply(.portOpenFailed(ConnectionPolicyIOFailure()))

        XCTAssertEqual(directive, .none)
        XCTAssertEqual(model.phase, .failed(.portOpenFailed(ConnectionPolicyIOFailure())))
        XCTAssertFalse(model.needsPort)
    }

    func testAbortWhileAwaitingAScanProfileClosesFirstAndOnlyThenFails() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)

        let closeDirective = model.apply(.operatorAborted)
        XCTAssertEqual(closeDirective, .closePort(port))
        XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)))
        XCTAssertTrue(model.needsPort)

        let finalDirective = model.apply(.portClosed)
        XCTAssertEqual(finalDirective, .none)
        XCTAssertEqual(model.phase, .failed(.aborted))
        XCTAssertFalse(model.needsPort)
    }

    func testAbortWhileTheOpenRequestIsStillInFlightWaitsForTheRealOutcome() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))

        // Der Öffnungsversuch ist bereits hinausgegangen -- ein Abbruch
        // kann ihn nicht zurücknehmen, nur vormerken.
        let markDirective = model.apply(.operatorAborted)
        XCTAssertEqual(markDirective, .none)
        XCTAssertEqual(model.phase, .openingPort(windDownTo: .aborted))

        // Öffnet der Port doch noch, muss er jetzt geschlossen werden.
        let closeDirective = model.apply(.portOpened)
        XCTAssertEqual(closeDirective, .closePort(port))
        XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)))

        XCTAssertEqual(model.apply(.portClosed), .none)
        XCTAssertEqual(model.phase, .failed(.aborted))
    }

    func testAbortWhileTheOpenRequestIsInFlightAndItThenFailsNeedsNoClose() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.operatorAborted)

        let directive = model.apply(.portOpenFailed(ConnectionPolicyIOFailure()))

        XCTAssertEqual(directive, .none)
        XCTAssertEqual(model.phase, .failed(.aborted))
        XCTAssertFalse(model.needsPort)
    }

    func testUnexpectedEventWhileOpeningWaitsForTheRealOutcomeBeforeClosing() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))

        XCTAssertEqual(model.apply(.connectionLost(ConnectionPolicyIOFailure())), .none)
        XCTAssertEqual(model.phase, .openingPort(windDownTo: .unexpectedEvent))

        XCTAssertEqual(model.apply(.portOpened), .closePort(port))
        XCTAssertEqual(model.phase, .closingPort(.failure(.unexpectedEvent)))

        XCTAssertEqual(model.apply(.portClosed), .none)
        XCTAssertEqual(model.phase, .failed(.unexpectedEvent))
    }

    func testAbortInEveryRunningPhaseEndsVisiblyAndReleasesTheHeldPort() {
        func runToAwaitingScanProfile() -> ConnectionPolicyModel {
            var model = ConnectionPolicyModel()
            model.apply(.operatorRequestedConnection(portPath: validPath))
            model.apply(.portOpened)
            return model
        }
        func runToCheckingIdentity() -> ConnectionPolicyModel {
            var model = runToAwaitingScanProfile()
            model.apply(.observationTimedOut)
            return model
        }
        func runToReady() -> ConnectionPolicyModel {
            var model = runToAwaitingScanProfile()
            model.apply(.validScanProfileObserved)
            return model
        }

        for var model in [runToAwaitingScanProfile(), runToCheckingIdentity(), runToReady()] {
            XCTAssertEqual(model.apply(.operatorAborted), .closePort(port))
            guard case .closingPort(.failure(.aborted)) = model.phase else {
                return XCTFail("Erwartete closingPort(.failure(.aborted)), war \(model.phase)")
            }
            XCTAssertEqual(model.apply(.portClosed), .none)
            XCTAssertEqual(model.phase, .failed(.aborted))
            XCTAssertFalse(model.needsPort)
        }
    }

    func testConnectionLostAfterReadyEndsVisiblyAndReleasesThePortAndStartsNoTXOrLoop() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.validScanProfileObserved)
        XCTAssertEqual(model.phase, .ready)

        let closeDirective = model.apply(.connectionLost(ConnectionPolicyIOFailure()))
        XCTAssertEqual(closeDirective, .closePort(port))
        XCTAssertEqual(model.phase, .closingPort(.failure(.connectionLost(ConnectionPolicyIOFailure()))))

        let finalDirective = model.apply(.portClosed)
        XCTAssertEqual(finalDirective, .none)
        XCTAssertEqual(model.phase, .failed(.connectionLost(ConnectionPolicyIOFailure())))
        XCTAssertFalse(model.needsPort)
    }

    func testUnexpectedEventEndsVisiblyAfterOrderedClosing() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)

        // `.portClosed` während `.awaitingScanProfile` ist unerwartet --
        // es wurde nie ein Schließen angefordert.
        let directive = model.apply(.portClosed)
        XCTAssertEqual(directive, .closePort(port))
        XCTAssertEqual(model.phase, .closingPort(.failure(.unexpectedEvent)))
        XCTAssertEqual(model.apply(.portClosed), .none)
        XCTAssertEqual(model.phase, .failed(.unexpectedEvent))
    }

    func testDoubleOrLateReleaseDoesNotAffectANewRun() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.operatorAborted)
        model.apply(.portClosed)
        XCTAssertEqual(model.phase, .failed(.aborted))

        // Eine zweite, verspätete Freigabe (oder jedes andere Ereignis)
        // an diesem bereits terminalen Wert ändert nichts.
        for event: ConnectionPolicyEvent in [
            .portClosed, .portCloseFailed(ConnectionPolicyIOFailure()), .operatorAborted,
            .validScanProfileObserved, .identityOutcome(.identified),
            .operatorRequestedConnection(portPath: validPath)
        ] {
            let directive = model.apply(event)
            XCTAssertEqual(directive, .none)
            XCTAssertEqual(model.phase, .failed(.aborted))
        }

        // Ein neuer Lauf ist ein neuer Wert -- unbeeinflusst vom alten.
        var newRun = ConnectionPolicyModel()
        XCTAssertEqual(newRun.phase, .idle)
        let newDirective = newRun.apply(.operatorRequestedConnection(portPath: validPath))
        XCTAssertEqual(newDirective, .openPort(port, baudRate: .baud38400))
    }

    func testWaitingIsAnExplicitlyNamedStateNotADeadEnd() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        XCTAssertEqual(model.phase, .awaitingScanProfile)
        // Weder `.idle` noch `.failed` -- ein eigens benannter Wartezustand.
        if case .awaitingScanProfile = model.phase {} else {
            XCTFail("Erwartete einen benannten Wartezustand")
        }
    }

    // MARK: - Pflichtnachweis 8: genau ein Port, Gegenprobe

    func testThePortNeverChangesAcrossTheWholeRun() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        let portAfterStart = model.port
        model.apply(.portOpened)
        model.apply(.validScanProfileObserved)
        XCTAssertEqual(model.port, portAfterStart)
        XCTAssertEqual(model.port, port)
    }

    /// Gegenprobe: Eine Fassung, die den Fast Path unnötiges TX anfordern
    /// ließe, muss an ``testThePassiveFastPathNeverRequestsIdentityOrCommissioning``
    /// scheitern -- belegt hier durch direkte Prüfung, dass `ready` ohne
    /// jede Identitäts-/Commissioning-Direktive erreicht wird.
    func testReadyIsNeverReachedThroughPortOpeningOrB1Alone() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        XCTAssertNotEqual(model.phase, .ready, "Bloßes Öffnen darf `ready` nicht erreichen")

        model.apply(.observationTimedOut)
        model.apply(.identityOutcome(.identified))
        XCTAssertNotEqual(model.phase, .ready, "B1 allein darf `ready` nicht erreichen")
        XCTAssertEqual(model.phase, .continuingActively)
    }

    // MARK: - SICK-0330r-K1, Pflichtnachweis 1 (H1): Abbruch bleibt dominant

    /// Wörtlich die im Korrekturauftrag genannte Sequenz: B0-Timeout,
    /// B1-Timeout (löst die `closePort`-Direktive aus), Abbruch während
    /// des laufenden Schließens, dann die tatsächliche Freigabe. Das
    /// Ergebnis muss `.aborted` sein und darf zu keinem Zeitpunkt danach
    /// eine aktive oder Commissioning-Direktive liefern.
    func testAbortDuringOrderedClosingForACommissioningContinuationEndsAbortedNotCommissioning() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)

        let closeDirective = model.apply(.identityOutcome(.timeout))
        XCTAssertEqual(closeDirective, .closePort(port))
        XCTAssertEqual(model.phase, .closingPort(.commissioningContinuation(.timeout)))

        let abortDirective = model.apply(.operatorAborted)
        XCTAssertEqual(abortDirective, .none)
        XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)))

        let finalDirective = model.apply(.portClosed)
        XCTAssertEqual(finalDirective, .none)
        XCTAssertEqual(model.phase, .failed(.aborted))
        XCTAssertFalse(model.needsPort)

        if case .requestCommissioningContinuation = finalDirective {
            XCTFail("Nach einem Abbruch darf nie eine Commissioning-Fortsetzung entstehen")
        }
        if case .requestActiveContinuation = finalDirective {
            XCTFail("Nach einem Abbruch darf nie eine aktive Fortsetzung entstehen")
        }
    }

    /// Gegenprobe zu H1: Ohne die Abbruchdominanz (`abortedOutcome`
    /// entfernt bzw. wirkungslos) würde `.portClosed` weiterhin die
    /// vorgemerkte Commissioning-Fortsetzung ausliefern. Diese Prüfung
    /// wäre in dem alten, fehlerhaften Verhalten falsch -- sie bricht,
    /// solange die Dominanz nicht gilt.
    func testCounterProofWithoutAbortDominanceWouldStillOfferCommissioningContinuation() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)
        model.apply(.identityOutcome(.timeout))
        model.apply(.operatorAborted)

        let finalDirective = model.apply(.portClosed)

        // Das ist die geforderte Aussage der Korrektur: kein
        // `requestCommissioningContinuation`, egal was vorher passierte.
        XCTAssertNotEqual(
            finalDirective,
            .requestCommissioningContinuation(port, .timeout, baudRate: .baud9600)
        )
        XCTAssertEqual(model.phase, .failed(.aborted))
    }

    /// H1: Abbruch bleibt auch aus dem Fehler-Schließweg (nicht nur dem
    /// Commissioning-Weg) typisiert möglich und ändert dort nichts, da
    /// dort bereits `.failure(.aborted)` oder ein anderer Fehlschlag
    /// dominant ist.
    func testAbortDuringOrderedClosingForAFailureLeavesTheFailureUnchanged() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.connectionLost(ConnectionPolicyIOFailure()))
        XCTAssertEqual(model.phase, .closingPort(.failure(.connectionLost(ConnectionPolicyIOFailure()))))

        XCTAssertEqual(model.apply(.operatorAborted), .none)
        XCTAssertEqual(model.phase, .closingPort(.failure(.connectionLost(ConnectionPolicyIOFailure()))))

        XCTAssertEqual(model.apply(.portClosed), .none)
        XCTAssertEqual(model.phase, .failed(.connectionLost(ConnectionPolicyIOFailure())))
    }

    // MARK: - SICK-0330r-K1, Pflichtnachweis 2 (H2): Schließfehler ist keine Freigabe

    func testPortCloseFailedFromAFailureClosingPathStaysNonTerminalWithThePortHeld() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.operatorAborted)
        XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)))

        let directive = model.apply(.portCloseFailed(ConnectionPolicyIOFailure()))

        XCTAssertEqual(directive, .none)
        XCTAssertEqual(model.phase, .closeFailed(.failure(.aborted), reason: ConnectionPolicyIOFailure()))
        XCTAssertTrue(model.needsPort, "Ein fehlgeschlagener Schluss bestätigt keine Freigabe")
        if case .requestActiveContinuation = directive {
            XCTFail("Ein Schließfehler darf keine aktive Fortsetzung starten")
        }
        if case .requestCommissioningContinuation = directive {
            XCTFail("Ein Schließfehler darf keine Commissioning-Fortsetzung starten")
        }

        // Erst ein späteres, tatsächlich bestätigtes `portClosed` gibt frei.
        let finalDirective = model.apply(.portClosed)
        XCTAssertEqual(finalDirective, .none)
        XCTAssertEqual(model.phase, .failed(.aborted))
        XCTAssertFalse(model.needsPort)
    }

    func testPortCloseFailedFromACommissioningClosingPathStaysNonTerminalWithThePortHeld() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)
        model.apply(.identityOutcome(.timeout))
        XCTAssertEqual(model.phase, .closingPort(.commissioningContinuation(.timeout)))

        let directive = model.apply(.portCloseFailed(ConnectionPolicyIOFailure()))

        XCTAssertEqual(directive, .none)
        XCTAssertEqual(model.phase, .closeFailed(.commissioningContinuation(.timeout), reason: ConnectionPolicyIOFailure()))
        XCTAssertTrue(model.needsPort, "Ein fehlgeschlagener Schluss bestätigt keine Freigabe")

        // Erst ein späteres, tatsächlich bestätigtes `portClosed` gibt frei
        // und liefert erst dann die vorgesehene Commissioning-Fortsetzung.
        let finalDirective = model.apply(.portClosed)
        XCTAssertEqual(
            finalDirective,
            .requestCommissioningContinuation(port, .timeout, baudRate: .baud9600)
        )
        XCTAssertEqual(model.phase, .continuingViaCommissioning(.timeout))
        XCTAssertFalse(model.needsPort)
    }

    func testRepeatedPortCloseFailedStaysNonTerminalWithoutASecondDirective() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.operatorAborted)
        model.apply(.portCloseFailed(ConnectionPolicyIOFailure()))
        XCTAssertEqual(model.phase, .closeFailed(.failure(.aborted), reason: ConnectionPolicyIOFailure()))

        // Kein stiller Retry -- ein wiederholter Schließfehler ändert
        // nichts und liefert keine zweite Direktive.
        for _ in 0..<3 {
            let directive = model.apply(.portCloseFailed(ConnectionPolicyIOFailure()))
            XCTAssertEqual(directive, .none)
            XCTAssertEqual(model.phase, .closeFailed(.failure(.aborted), reason: ConnectionPolicyIOFailure()))
            XCTAssertTrue(model.needsPort)
        }

        XCTAssertEqual(model.apply(.portClosed), .none)
        XCTAssertEqual(model.phase, .failed(.aborted))
    }

    /// Gegenprobe zu H2: Ohne die Korrektur würde `portCloseFailed` sofort
    /// `needsPort == false` und einen terminalen `failed`-Zustand
    /// erreichen -- exakt der im Review belegte Fehler.
    func testCounterProofTheOldBehaviorWouldHaveClaimedReleaseOnACloseFailure() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.operatorAborted)
        model.apply(.portCloseFailed(ConnectionPolicyIOFailure()))

        // Die geforderte Aussage der Korrektur: kein `false`, kein
        // terminaler `failed`-Zustand allein durch den Schließfehler.
        XCTAssertTrue(model.needsPort)
        if case .failed = model.phase {
            XCTFail("Ein Schließfehler allein darf nicht terminal `failed` erreichen")
        }
    }

    // MARK: - SICK-0330r-K1, Pflichtnachweis 3 (H2/H1 zusammen): Abbruch nach Schließfehler

    func testAbortAfterPortCloseFailedDiscardsAPendingCommissioningContinuationButHoldsThePort() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)
        model.apply(.identityOutcome(.timeout))
        model.apply(.portCloseFailed(ConnectionPolicyIOFailure()))
        XCTAssertEqual(model.phase, .closeFailed(.commissioningContinuation(.timeout), reason: ConnectionPolicyIOFailure()))

        let abortDirective = model.apply(.operatorAborted)
        XCTAssertEqual(abortDirective, .none)
        XCTAssertEqual(model.phase, .closeFailed(.failure(.aborted), reason: ConnectionPolicyIOFailure()))
        XCTAssertTrue(model.needsPort, "Der Port bleibt bis `portClosed` sichtbar gehalten")

        let finalDirective = model.apply(.portClosed)
        XCTAssertEqual(finalDirective, .none)
        XCTAssertEqual(model.phase, .failed(.aborted))
        XCTAssertFalse(model.needsPort)
        if case .requestCommissioningContinuation = finalDirective {
            XCTFail("Die verworfene Commissioning-Fortsetzung darf nie mehr entstehen")
        }
    }

    // MARK: - SICK-0330r-K1, Pflichtnachweis 4 (H3): jede Direktive trägt ihren Port

    func testEveryActingDirectiveCarriesExactlyTheOneModelPortAndTheCorrectRateWhereApplicable() {
        var model = ConnectionPolicyModel()
        var directives: [ConnectionPolicyDirective] = []
        directives.append(model.apply(.operatorRequestedConnection(portPath: validPath)))
        directives.append(model.apply(.portOpened))
        directives.append(model.apply(.observationTimedOut))
        directives.append(model.apply(.identityOutcome(.timeout)))
        directives.append(model.apply(.portClosed))

        for directive in directives {
            switch directive {
            case .none:
                continue
            case .openPort(let p, let rate):
                XCTAssertEqual(p, port)
                XCTAssertEqual(rate, .baud38400)
            case .observeForScanProfile(let p, let rate):
                XCTAssertEqual(p, port)
                XCTAssertEqual(rate, .baud38400)
            case .sendIdentityProbeAtTargetRate(let p, let rate):
                XCTAssertEqual(p, port)
                XCTAssertEqual(rate, .baud38400)
            case .closePort(let p):
                XCTAssertEqual(p, port)
            case .requestActiveContinuation(let p, let rate):
                XCTAssertEqual(p, port)
                XCTAssertEqual(rate, .baud38400)
            case .requestCommissioningContinuation(let p, _, let rate):
                XCTAssertEqual(p, port)
                XCTAssertEqual(rate, .baud9600)
            }
        }
    }

    // MARK: - SICK-0330r-K1, Pflichtnachweis 5 (H4): geschlossene Fehlerkategorien

    func testFailureEventsAndStatesAreBuildableOnlyWithTheClosedCategory() {
        // Kompilierbarkeitsnachweis: `ConnectionPolicyIOFailure()` ist die
        // einzige Möglichkeit, diese Fälle zu bauen -- es existiert kein
        // `String`-Initialisierer mehr. `ConnectionPolicyFailure` trägt
        // seit SICK-0330r-K2 (K2-1) bewusst **kein** `portCloseFailed`
        // mehr -- der Fall war produktiv unerreichbar (siehe
        // `testAConnectionPolicyFailureCannotBeConstructedAsPortCloseFailed`
        // weiter unten für den entsprechenden Quelltextnachweis).
        let reason = ConnectionPolicyIOFailure()
        XCTAssertEqual(ConnectionPolicyEvent.portOpenFailed(reason), .portOpenFailed(ConnectionPolicyIOFailure()))
        XCTAssertEqual(ConnectionPolicyEvent.connectionLost(reason), .connectionLost(ConnectionPolicyIOFailure()))
        XCTAssertEqual(ConnectionPolicyEvent.portCloseFailed(reason), .portCloseFailed(ConnectionPolicyIOFailure()))
        XCTAssertEqual(
            ConnectionPolicyFailure.portOpenFailed(reason),
            .portOpenFailed(ConnectionPolicyIOFailure())
        )
        XCTAssertEqual(
            ConnectionPolicyFailure.connectionLost(reason),
            .connectionLost(ConnectionPolicyIOFailure())
        )
    }

    // MARK: - SICK-0330r-K2 (K2-1): der Portschlussgrund wird gebunden statt verworfen

    /// Pflichtnachweis: Der genaue Schließgrund aus dem Ereignis ist im
    /// tatsächlich erreichbaren `closeFailed`-Zustand vorhanden -- über
    /// einen echten Reducer-Übergang, nicht über direkte Enum-
    /// Konstruktion.
    func testTheExactCloseFailureReasonFromTheEventIsPresentInTheReachableCloseFailedState() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.operatorAborted)
        XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)))

        let reason = ConnectionPolicyIOFailure()
        let directive = model.apply(.portCloseFailed(reason))

        XCTAssertEqual(directive, .none)
        guard case .closeFailed(let outcome, let storedReason) = model.phase else {
            return XCTFail("Erwartete closeFailed(_:reason:), war \(model.phase)")
        }
        XCTAssertEqual(outcome, .failure(.aborted))
        XCTAssertEqual(storedReason, reason)
    }

    /// Pflichtnachweis: Wiederholtes `portCloseFailed` hat eine
    /// ausdrücklich festgelegte Semantik -- der zuletzt gemeldete Grund
    /// ersetzt den vorherigen, der vorgemerkte Ausgang bleibt
    /// unverändert, und es entsteht nie eine zweite Direktive.
    func testRepeatedPortCloseFailedReplacesTheStoredReasonWithTheLatestOneAndNeverProducesASecondDirective() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)
        model.apply(.identityOutcome(.timeout))
        XCTAssertEqual(model.apply(.portCloseFailed(ConnectionPolicyIOFailure())), .none)
        XCTAssertEqual(model.phase, .closeFailed(.commissioningContinuation(.timeout), reason: ConnectionPolicyIOFailure()))

        for _ in 0..<3 {
            let directive = model.apply(.portCloseFailed(ConnectionPolicyIOFailure()))
            XCTAssertEqual(directive, .none)
            XCTAssertEqual(
                model.phase,
                .closeFailed(.commissioningContinuation(.timeout), reason: ConnectionPolicyIOFailure())
            )
        }
    }

    /// Pflichtnachweis: Abbruch nach fehlgeschlagenem Schluss erhält die
    /// Fehlerkategorie (ersetzt eine vorgemerkte Commissioning-
    /// Fortsetzung durch `.aborted`), verwirft diese Fortsetzung, hält
    /// `needsPort == true` -- und der gespeicherte Schließgrund bleibt
    /// dabei unangetastet.
    func testAbortAfterAFailedCloseKeepsTheStoredReasonDiscardsCommissioningAndHoldsThePort() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)
        model.apply(.identityOutcome(.timeout))
        let reason = ConnectionPolicyIOFailure()
        model.apply(.portCloseFailed(reason))
        XCTAssertEqual(model.phase, .closeFailed(.commissioningContinuation(.timeout), reason: reason))

        XCTAssertEqual(model.apply(.operatorAborted), .none)

        guard case .closeFailed(let outcome, let storedReason) = model.phase else {
            return XCTFail("Erwartete closeFailed(_:reason:), war \(model.phase)")
        }
        XCTAssertEqual(outcome, .failure(.aborted))
        XCTAssertEqual(storedReason, reason, "Der gespeicherte Schließgrund bleibt unverändert erhalten")
        XCTAssertTrue(model.needsPort)
    }

    /// Pflichtnachweis: Ein späteres `portClosed` löst weiterhin das nach
    /// Abbruch gültige Ergebnis ohne TX- oder Commissioning-Nachlauf auf.
    func testALaterPortClosedStillResolvesTheAbortedOutcomeWithNoTXOrCommissioningFollowUp() {
        var model = ConnectionPolicyModel()
        model.apply(.operatorRequestedConnection(portPath: validPath))
        model.apply(.portOpened)
        model.apply(.observationTimedOut)
        model.apply(.identityOutcome(.timeout))
        model.apply(.portCloseFailed(ConnectionPolicyIOFailure()))
        model.apply(.operatorAborted)

        let finalDirective = model.apply(.portClosed)

        XCTAssertEqual(finalDirective, .none)
        XCTAssertEqual(model.phase, .failed(.aborted))
        XCTAssertFalse(model.needsPort)
        if case .requestCommissioningContinuation = finalDirective {
            XCTFail("Nach Abbruch darf nie eine Commissioning-Fortsetzung entstehen")
        }
        if case .requestActiveContinuation = finalDirective {
            XCTFail("Nach Abbruch darf nie eine aktive Fortsetzung entstehen")
        }
    }

    /// Pflichtnachweis 4: `ConnectionPolicyFailure.portCloseFailed`
    /// existiert nicht mehr -- Kompilierbarkeitsnachweis über den
    /// Quelltext, da ein Testfall, der ihn direkt konstruierte, keinen
    /// erreichbaren Übergang belegt hätte (die Gegenprobe der ursprünglich
    /// beanstandete Zustand).
    func testConnectionPolicyFailureDeclarationHasExactlyFiveCasesWithoutPortCloseFailed() throws {
        let url = ControlSourcePaths.sources.appendingPathComponent("ConnectionPolicy.swift")
        let rawSource = try String(contentsOf: url, encoding: .utf8)
        // Nur produktiver Quelltext -- ein erklärender Kommentar, der den
        // Fallnamen zur Begründung seiner Abwesenheit nennt (siehe
        // Kopfkommentar der Datei), darf diese Prüfung nicht auslösen.
        let source = rawSource.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let declarationRange = source.range(of: "public enum ConnectionPolicyFailure"),
              let closingBraceRange = source.range(of: "\n}", range: declarationRange.upperBound..<source.endIndex)
        else {
            return XCTFail("Konnte den Deklarationsblock von ConnectionPolicyFailure nicht finden")
        }
        let block = source[declarationRange.lowerBound..<closingBraceRange.upperBound]
        XCTAssertFalse(block.contains("portCloseFailed"), "ConnectionPolicyFailure trägt keinen portCloseFailed-Fall mehr")
        for caseName in ["startRefused", "portOpenFailed", "aborted", "unexpectedEvent", "connectionLost"] {
            XCTAssertTrue(block.contains("case \(caseName)"), "ConnectionPolicyFailure vermisst \(caseName)")
        }
    }

    // MARK: - SICK-0330r-K2 (K2-2): die Identitätslücke ist datenfrei

    /// Pflichtnachweis: Zwei unterschiedliche unerwartete Kommandobytes
    /// ergeben dieselbe datenfreie Identitätslücke und dieselbe
    /// Policy-Entscheidung.
    func testTwoDifferentUnexpectedCommandBytesYieldTheSameDataFreeIdentityGapAndTheSameDecision() {
        func run(commandByte: UInt8) -> (ConnectionPolicyDirective, ConnectionPolicyPhase) {
            var model = ConnectionPolicyModel()
            model.apply(.operatorRequestedConnection(portPath: validPath))
            model.apply(.portOpened)
            model.apply(.observationTimedOut)
            let directive = model.apply(.identityOutcome(.unexpectedResponse(commandByte: commandByte)))
            return (directive, model.phase)
        }

        let (directiveA, phaseA) = run(commandByte: 0x01)
        let (directiveB, phaseB) = run(commandByte: 0xFF)

        XCTAssertEqual(directiveA, directiveB)
        XCTAssertEqual(directiveA, .closePort(port))
        XCTAssertEqual(phaseA, phaseB)
        XCTAssertEqual(phaseA, .closingPort(.commissioningContinuation(.unexpectedResponse)))
    }

    /// Kompilierbarkeitsnachweis: `ConnectionPolicyIdentityGap.unexpectedResponse`
    /// nimmt keinen Parameter mehr -- das niedrigere
    /// `IdentityProbeOutcome.unexpectedResponse(commandByte:)` bleibt
    /// davon unberührt.
    func testConnectionPolicyIdentityGapUnexpectedResponseTakesNoParameter() {
        let gap: ConnectionPolicyIdentityGap = .unexpectedResponse
        XCTAssertEqual(gap, ConnectionPolicyIdentityGap.unexpectedResponse)

        let lowerOutcome: IdentityProbeOutcome = .unexpectedResponse(commandByte: 0x7A)
        if case .unexpectedResponse(let commandByte) = lowerOutcome {
            XCTAssertEqual(commandByte, 0x7A, "Die niedrigere Ebene darf das Byte weiterhin tragen")
        } else {
            XCTFail("Erwartete IdentityProbeOutcome.unexpectedResponse(commandByte:)")
        }
    }
}
