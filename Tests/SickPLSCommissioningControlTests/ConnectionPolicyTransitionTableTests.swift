import XCTest
@testable import SickPLSCommissioningControl
import SickPLSActiveControl

/// Die vollständige Übergangstabelle der Verbindungspolitik
/// (Pflichtnachweis 7, seit SICK-0330r-K1 Pflichtnachweis 6, seit
/// SICK-0330r-K2 Pflichtnachweis "Die vollständige Übergangstabelle
/// bleibt grün"): jeder erreichbare Zustand gekreuzt mit jedem der zehn
/// Ereignisse.
///
/// **Strukturell erreichbare Zustandsformen** (dreizehn -- `openingPort`,
/// `closingPort` und seit SICK-0330r-K1 `closeFailed` tragen je zwei
/// fachlich verschieden reagierende Ausprägungen): `idle`,
/// `openingPort(windDownTo: nil)`, `openingPort(windDownTo: .aborted)`,
/// `awaitingScanProfile`, `checkingIdentityAtTargetRate`, `ready`,
/// `closingPort(.failure(.aborted))`,
/// `closingPort(.commissioningContinuation(.timeout))`,
/// `closeFailed(.failure(.aborted), reason:)`,
/// `closeFailed(.commissioningContinuation(.timeout), reason:)`,
/// `continuingActively`, `continuingViaCommissioning(.timeout)`,
/// `failed(.aborted)`. Für `identityOutcome` innerhalb von
/// `checkingIdentityAtTargetRate` werden zusätzlich alle vier
/// ``IdentityProbeOutcome``-Fälle einzeln geprüft, weil dort jeder von
/// ihnen einen anderen Übergang auslöst. Seit SICK-0330r-K2 (K2-2) ist
/// ``ConnectionPolicyIdentityGap/unexpectedResponse`` datenfrei -- das
/// Ereignis `identityOutcome(.unexpectedResponse(commandByte:))` bleibt
/// unverändert (das niedrigere `IdentityProbeOutcome` darf das Byte
/// tragen), der resultierende Übergang bildet aber jeden Bytewert auf
/// dieselbe geschlossene Kategorie ab.
final class ConnectionPolicyTransitionTableTests: XCTestCase {

    private let path = "/dev/cu.usbserial-TAB"
    private var port: ConnectionPolicyPort { try! ConnectionPolicyPort.build(path: path) }

    private let allEvents: [ConnectionPolicyEvent] = [
        .operatorRequestedConnection(portPath: "/dev/cu.usbserial-TAB"),
        .operatorAborted,
        .portOpened,
        .portOpenFailed(ConnectionPolicyIOFailure()),
        .validScanProfileObserved,
        .observationTimedOut,
        .identityOutcome(.identified),
        .connectionLost(ConnectionPolicyIOFailure()),
        .portClosed,
        .portCloseFailed(ConnectionPolicyIOFailure())
    ]

    private func makeModel(reachingPhase build: (inout ConnectionPolicyModel) -> Void) -> ConnectionPolicyModel {
        var model = ConnectionPolicyModel()
        build(&model)
        return model
    }

    // MARK: - `idle`

    func testEveryEventAtIdle() {
        for event in allEvents {
            var model = ConnectionPolicyModel()
            let directive = model.apply(event)
            switch event {
            case .operatorRequestedConnection:
                XCTAssertEqual(directive, .openPort(port, baudRate: .baud38400), "\(event)")
                XCTAssertEqual(model.phase, .openingPort(windDownTo: nil), "\(event)")
            default:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .failed(.unexpectedEvent), "\(event)")
            }
        }
    }

    // MARK: - `openingPort(windDownTo: nil)`

    func testEveryEventWhileOpeningPortWithNoWindDown() {
        for event in allEvents {
            var model = makeModel { $0.apply(.operatorRequestedConnection(portPath: path)) }
            let directive = model.apply(event)
            switch event {
            case .portOpened:
                XCTAssertEqual(directive, .observeForScanProfile(port, baudRate: .baud38400), "\(event)")
                XCTAssertEqual(model.phase, .awaitingScanProfile, "\(event)")
            case .portOpenFailed(let reason):
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .failed(.portOpenFailed(reason)), "\(event)")
            case .operatorAborted:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .openingPort(windDownTo: .aborted), "\(event)")
            default:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .openingPort(windDownTo: .unexpectedEvent), "\(event)")
            }
        }
    }

    // MARK: - `openingPort(windDownTo: .aborted)`

    func testEveryEventWhileOpeningPortAlreadyWindingDown() {
        for event in allEvents {
            var model = makeModel {
                $0.apply(.operatorRequestedConnection(portPath: path))
                $0.apply(.operatorAborted)
            }
            XCTAssertEqual(model.phase, .openingPort(windDownTo: .aborted))
            let directive = model.apply(event)
            switch event {
            case .portOpened:
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)), "\(event)")
            case .portOpenFailed:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .failed(.aborted), "\(event)")
            default:
                // Bereits vermerkt -- jedes weitere Ereignis wartet
                // unverändert auf das wirkliche Öffnungsergebnis.
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .openingPort(windDownTo: .aborted), "\(event)")
            }
        }
    }

    // MARK: - `awaitingScanProfile`

    func testEveryEventWhileAwaitingScanProfile() {
        for event in allEvents {
            var model = makeModel {
                $0.apply(.operatorRequestedConnection(portPath: path))
                $0.apply(.portOpened)
            }
            XCTAssertEqual(model.phase, .awaitingScanProfile)
            let directive = model.apply(event)
            switch event {
            case .validScanProfileObserved:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .ready, "\(event)")
            case .observationTimedOut:
                XCTAssertEqual(directive, .sendIdentityProbeAtTargetRate(port, baudRate: .baud38400), "\(event)")
                XCTAssertEqual(model.phase, .checkingIdentityAtTargetRate, "\(event)")
            case .operatorAborted:
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)), "\(event)")
            case .connectionLost(let reason):
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.connectionLost(reason))), "\(event)")
            default:
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.unexpectedEvent)), "\(event)")
            }
        }
    }

    // MARK: - `checkingIdentityAtTargetRate` (inklusive aller vier `IdentityProbeOutcome`-Fälle)

    func testEveryEventWhileCheckingIdentity() {
        let identityEvents: [ConnectionPolicyEvent] = [
            .identityOutcome(.identified),
            .identityOutcome(.timeout),
            .identityOutcome(.unexpectedResponse(commandByte: 0x99)),
            .identityOutcome(.ambiguous)
        ]
        let events = allEvents.filter { if case .identityOutcome = $0 { return false } else { return true } }
            + identityEvents

        for event in events {
            var model = makeModel {
                $0.apply(.operatorRequestedConnection(portPath: path))
                $0.apply(.portOpened)
                $0.apply(.observationTimedOut)
            }
            XCTAssertEqual(model.phase, .checkingIdentityAtTargetRate)
            let directive = model.apply(event)
            switch event {
            case .validScanProfileObserved:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .ready, "\(event)")
            case .identityOutcome(.identified):
                XCTAssertEqual(directive, .requestActiveContinuation(port, baudRate: .baud38400), "\(event)")
                XCTAssertEqual(model.phase, .continuingActively, "\(event)")
            case .identityOutcome(.timeout):
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.commissioningContinuation(.timeout)), "\(event)")
            case .identityOutcome(.unexpectedResponse):
                // K2-2: das rohe Kommandobyte des Ereignisses wird nicht
                // gebunden -- jeder Bytewert bildet auf dieselbe
                // datenfreie Kategorie ab.
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(
                    model.phase,
                    .closingPort(.commissioningContinuation(.unexpectedResponse)),
                    "\(event)"
                )
            case .identityOutcome(.ambiguous):
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.commissioningContinuation(.ambiguous)), "\(event)")
            case .operatorAborted:
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)), "\(event)")
            case .connectionLost(let reason):
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.connectionLost(reason))), "\(event)")
            default:
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.unexpectedEvent)), "\(event)")
            }
        }
    }

    // MARK: - `ready`

    func testEveryEventWhileReady() {
        for event in allEvents {
            var model = makeModel {
                $0.apply(.operatorRequestedConnection(portPath: path))
                $0.apply(.portOpened)
                $0.apply(.validScanProfileObserved)
            }
            XCTAssertEqual(model.phase, .ready)
            let directive = model.apply(event)
            switch event {
            case .validScanProfileObserved, .identityOutcome, .observationTimedOut:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .ready, "\(event)")
            case .operatorAborted:
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)), "\(event)")
            case .connectionLost(let reason):
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.connectionLost(reason))), "\(event)")
            default:
                XCTAssertEqual(directive, .closePort(port), "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.unexpectedEvent)), "\(event)")
            }
        }
    }

    // MARK: - `closingPort(.failure(...))`

    func testEveryEventWhileClosingPortForAFailure() {
        for event in allEvents {
            var model = makeModel {
                $0.apply(.operatorRequestedConnection(portPath: path))
                $0.apply(.portOpened)
                $0.apply(.operatorAborted)
            }
            XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)))
            let directive = model.apply(event)
            switch event {
            case .portClosed:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .failed(.aborted), "\(event)")
            case .portCloseFailed:
                // H2 (SICK-0330r-K1): nichtterminal, kein sofortiges
                // `failed` -- der Schließfehler allein bestätigt keine
                // Freigabe.
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .closeFailed(.failure(.aborted), reason: ConnectionPolicyIOFailure()), "\(event)")
                XCTAssertTrue(model.needsPort, "\(event)")
            default:
                // Auch `operatorAborted` ändert hier nichts: die bereits
                // dominante `.failure(.aborted)` bleibt unverändert.
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)), "\(event)")
            }
        }
    }

    // MARK: - `closingPort(.commissioningContinuation(...))`

    func testEveryEventWhileClosingPortForACommissioningContinuation() {
        for event in allEvents {
            var model = makeModel {
                $0.apply(.operatorRequestedConnection(portPath: path))
                $0.apply(.portOpened)
                $0.apply(.observationTimedOut)
                $0.apply(.identityOutcome(.timeout))
            }
            XCTAssertEqual(model.phase, .closingPort(.commissioningContinuation(.timeout)))
            let directive = model.apply(event)
            switch event {
            case .portClosed:
                XCTAssertEqual(
                    directive,
                    .requestCommissioningContinuation(port, .timeout, baudRate: .baud9600),
                    "\(event)"
                )
                XCTAssertEqual(model.phase, .continuingViaCommissioning(.timeout), "\(event)")
            case .portCloseFailed:
                // H2: nichtterminal statt sofort `failed`.
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .closeFailed(.commissioningContinuation(.timeout), reason: ConnectionPolicyIOFailure()), "\(event)")
                XCTAssertTrue(model.needsPort, "\(event)")
            case .operatorAborted:
                // H1: die vorgemerkte Commissioning-Fortsetzung wird
                // unwiderruflich verworfen -- der Zustand wechselt
                // sichtbar auf `.failure(.aborted)`, bleibt aber
                // `closingPort` (das Schließen läuft noch).
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.failure(.aborted)), "\(event)")
            default:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .closingPort(.commissioningContinuation(.timeout)), "\(event)")
            }
        }
    }

    // MARK: - `closeFailed(.failure(...))` (SICK-0330r-K1, H2)

    func testEveryEventWhileCloseFailedForAFailure() {
        for event in allEvents {
            var model = makeModel {
                $0.apply(.operatorRequestedConnection(portPath: path))
                $0.apply(.portOpened)
                $0.apply(.operatorAborted)
                $0.apply(.portCloseFailed(ConnectionPolicyIOFailure()))
            }
            XCTAssertEqual(model.phase, .closeFailed(.failure(.aborted), reason: ConnectionPolicyIOFailure()))
            let directive = model.apply(event)
            switch event {
            case .portClosed:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .failed(.aborted), "\(event)")
                XCTAssertFalse(model.needsPort, "\(event)")
            default:
                // Weder ein wiederholter Schließfehler noch ein Abbruch
                // (bereits dominant) noch jedes andere Ereignis liefert
                // hier eine Direktive oder verlässt `closeFailed`.
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .closeFailed(.failure(.aborted), reason: ConnectionPolicyIOFailure()), "\(event)")
                XCTAssertTrue(model.needsPort, "\(event)")
            }
        }
    }

    // MARK: - `closeFailed(.commissioningContinuation(...))` (SICK-0330r-K1, H2/H1)

    func testEveryEventWhileCloseFailedForACommissioningContinuation() {
        for event in allEvents {
            var model = makeModel {
                $0.apply(.operatorRequestedConnection(portPath: path))
                $0.apply(.portOpened)
                $0.apply(.observationTimedOut)
                $0.apply(.identityOutcome(.timeout))
                $0.apply(.portCloseFailed(ConnectionPolicyIOFailure()))
            }
            XCTAssertEqual(model.phase, .closeFailed(.commissioningContinuation(.timeout), reason: ConnectionPolicyIOFailure()))
            let directive = model.apply(event)
            switch event {
            case .portClosed:
                XCTAssertEqual(
                    directive,
                    .requestCommissioningContinuation(port, .timeout, baudRate: .baud9600),
                    "\(event)"
                )
                XCTAssertEqual(model.phase, .continuingViaCommissioning(.timeout), "\(event)")
                XCTAssertFalse(model.needsPort, "\(event)")
            case .operatorAborted:
                // H1 gilt auch hier: die vorgemerkte Commissioning-
                // Fortsetzung wird verworfen, der Port bleibt aber
                // sichtbar gehalten (weiterhin `closeFailed`).
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .closeFailed(.failure(.aborted), reason: ConnectionPolicyIOFailure()), "\(event)")
                XCTAssertTrue(model.needsPort, "\(event)")
            default:
                XCTAssertEqual(directive, .none, "\(event)")
                XCTAssertEqual(model.phase, .closeFailed(.commissioningContinuation(.timeout), reason: ConnectionPolicyIOFailure()), "\(event)")
                XCTAssertTrue(model.needsPort, "\(event)")
            }
        }
    }

    // MARK: - Terminale Zustände: keine weitere Wirkung

    func testEveryEventAtContinuingActivelyIsANoOp() {
        for event in allEvents {
            var model = makeModel {
                $0.apply(.operatorRequestedConnection(portPath: path))
                $0.apply(.portOpened)
                $0.apply(.observationTimedOut)
                $0.apply(.identityOutcome(.identified))
            }
            XCTAssertEqual(model.phase, .continuingActively)
            let directive = model.apply(event)
            XCTAssertEqual(directive, .none, "\(event)")
            XCTAssertEqual(model.phase, .continuingActively, "\(event)")
        }
    }

    func testEveryEventAtContinuingViaCommissioningIsANoOp() {
        for event in allEvents {
            var model = makeModel {
                $0.apply(.operatorRequestedConnection(portPath: path))
                $0.apply(.portOpened)
                $0.apply(.observationTimedOut)
                $0.apply(.identityOutcome(.timeout))
                $0.apply(.portClosed)
            }
            XCTAssertEqual(model.phase, .continuingViaCommissioning(.timeout))
            let directive = model.apply(event)
            XCTAssertEqual(directive, .none, "\(event)")
            XCTAssertEqual(model.phase, .continuingViaCommissioning(.timeout), "\(event)")
        }
    }

    func testEveryEventAtFailedIsANoOp() {
        for event in allEvents {
            var model = makeModel { $0.apply(.operatorRequestedConnection(portPath: "")) }
            XCTAssertEqual(model.phase, .failed(.startRefused(.empty)))
            let directive = model.apply(event)
            XCTAssertEqual(directive, .none, "\(event)")
            XCTAssertEqual(model.phase, .failed(.startRefused(.empty)), "\(event)")
        }
    }
}
