import PlanariumInput
import PlanariumScannerUI
import XCTest
@testable import SickPLSCommissioningControl

/// Zustandsableitung und feste Textabbildung der Verbindungsleiste
/// (SICK-0330b) -- reine Textvarianten per Präsentationstest.
final class ConnectionBarPresentationTests: XCTestCase {

    private let port = "/dev/cu.usbserial-TEST"

    private func report(_ phase: StandardConnectionPhase, held: Bool, final isFinal: Bool) -> StandardConnectionReport {
        StandardConnectionReport(phase: phase, audit: StandardConnectionAudit(), isPortHeld: held, isFinal: isFinal)
    }

    private func derive(
        _ run: StandardConnectionReport?,
        stage: ConnectionBarState.RunStage = .idle,
        measurement: MeasurementSessionStatus = .idle,
        awaiting: Bool = false,
        disconnected: String? = nil
    ) -> ConnectionBarState {
        ConnectionBarState.derive(
            run: run, runPortPath: run == nil ? nil : port, stage: stage,
            measurement: measurement, isAwaitingPortRelease: awaiting, lastDisconnectedPort: disconnected
        )
    }

    // MARK: - Jeder Zustand ist über die Ableitung erreichbar

    func testEveryBarStateIsDerivable() {
        XCTAssertEqual(derive(nil), .disconnected)
        XCTAssertEqual(derive(report(.idle, held: false, final: false), stage: .connecting), .observing(portPath: port))
        XCTAssertEqual(derive(report(.observingPassively, held: true, final: false), stage: .connecting), .observing(portPath: port))
        XCTAssertEqual(derive(report(.checkingIdentityAtTargetRate, held: true, final: false), stage: .connecting), .checkingIdentity(portPath: port))
        XCTAssertEqual(
            derive(report(.runningCommissioning(.awaitingMeasurementStream, origin: .fallbackFromStartingRate), held: true, final: false), stage: .connecting),
            .preparing(portPath: port, stage: .awaitingMeasurementStream)
        )
        XCTAssertEqual(derive(report(.ready(.passiveScanProfile), held: true, final: false), stage: .releasingTransmitPort), .closingTransmitPort(portPath: port))
        XCTAssertEqual(derive(report(.failed(.portCloseFailed), held: true, final: false)), .transmitPortStillHeld(portPath: port))
        XCTAssertEqual(derive(report(.ready(.passiveScanProfile), held: false, final: true), measurement: .opening(portPath: port)), .openingMeasurement(portPath: port))
        XCTAssertEqual(derive(nil, measurement: .openWithoutProfile(portPath: port)), .awaitingFirstProfile(portPath: port))
        XCTAssertEqual(derive(nil, measurement: .streaming(portPath: port, pointCount: 90)), .ready(portPath: port, pointCount: 90))
        XCTAssertEqual(derive(nil, measurement: .failed(portPath: port, message: "weg")), .streamLost(portPath: port, message: "weg"))
        XCTAssertEqual(derive(nil, awaiting: true, disconnected: port), .disconnecting(portPath: port))
        XCTAssertEqual(derive(nil, disconnected: port), .disconnectedScannerMaySend(portPath: port))
        XCTAssertEqual(derive(report(.failed(.loginRejected), held: false, final: true)), .failed(portPath: port, failure: .loginRejected))
    }

    func testTheRunDominatesTheSessionWhileItHoldsThePort() {
        // Eine alte Sitzungslage darf einen laufenden Lauf nie verdecken.
        let state = derive(
            report(.checkingIdentityAtTargetRate, held: true, final: false), stage: .connecting,
            measurement: .failed(portPath: port, message: "alt")
        )
        XCTAssertEqual(state, .checkingIdentity(portPath: port))
    }

    func testAnAbortedRunIsShownAsFailedNotAsDisconnected() {
        XCTAssertEqual(derive(report(.failed(.aborted), held: false, final: true)), .failed(portPath: port, failure: .aborted))
        XCTAssertEqual(ConnectionBarPresentation(.failed(portPath: port, failure: .aborted)).statusText, "Aborted.")
    }

    // MARK: - Texte

    func testStatusTextsNameTheDeviceEffectWithoutProtocolDetails() {
        let texts: [ConnectionBarState: String] = [
            .observing(portPath: port): "Searching for scanner at \(port) – listening only.",
            .checkingIdentity(portPath: port): "Checking identity.",
            .preparing(portPath: port, stage: .loggingInAndSwitchingBaudRate): "Logging in and switching baud rate.",
            .preparing(portPath: port, stage: .awaitingMeasurementStream): "Measurements requested – waiting for stream.",
            .closingTransmitPort(portPath: port): "Stream held – reopening port for measurement.",
            .awaitingFirstProfile(portPath: port): "Port open – waiting for first profile.",
            .ready(portPath: port, pointCount: 90): "Ready – 90 points, Rate being determined.",
            .disconnecting(portPath: port): "Disconnecting.",
            .disconnectedScannerMaySend(portPath: port): "Disconnected – scanner may still be sending."
        ]
        for (state, expected) in texts {
            XCTAssertEqual(ConnectionBarPresentation(state).statusText, expected)
        }
        for (state, text) in texts {
            for forbidden in ["0xB1", "0xB0", "Telegramm", "CRC", "MMK"] {
                XCTAssertFalse(text.contains(forbidden), "\(state) nennt \(forbidden)")
            }
        }
    }

    func testEveryPreparationStageHasItsOwnSentence() {
        let stages: [StandardConnectionCommissioningStage] = [
            .adoptingConfirmedIdentity, .checkingStartingRate, .respondingAtStartingRate,
            .loggingInAndSwitchingBaudRate, .verifiedAtTargetRate, .awaitingMeasurementStream,
            .runningRateDiagnostics, .rateDiagnosticsFinished, .sessionFinished
        ]
        let sentences = Set(stages.map { ConnectionBarPresentation(.preparing(portPath: port, stage: $0)).statusText })
        XCTAssertEqual(sentences.count, stages.count, "Keine zwei Stufen teilen sich einen Satz")
    }

    func testFailuresCarryAConcreteNextAction() {
        let password = ConnectionBarPresentation(.failed(portPath: port, failure: .missingOrUnusablePassword))
        XCTAssertTrue(password.nextActionText?.contains("Settings") == true)
        XCTAssertFalse(password.isBusy)
        XCTAssertFalse(password.showsDisconnect)

        let busy = ConnectionBarPresentation(.failed(portPath: port, failure: .portOpenFailed))
        XCTAssertTrue(busy.nextActionText?.contains("busy") == true)

        let held = ConnectionBarPresentation(.transmitPortStillHeld(portPath: port))
        XCTAssertTrue(held.offersCloseRetry)
        XCTAssertTrue(held.isBusy)
        XCTAssertFalse(held.showsDisconnect)
    }

    func testBusyAndDisconnectFlagsFollowTheState() {
        XCTAssertFalse(ConnectionBarPresentation(.disconnected).isBusy)
        XCTAssertFalse(ConnectionBarPresentation(.disconnected).showsDisconnect)
        XCTAssertTrue(ConnectionBarPresentation(.observing(portPath: port)).showsDisconnect)
        XCTAssertFalse(ConnectionBarPresentation(.closingTransmitPort(portPath: port)).showsDisconnect, "Während des Schlusses gibt es nichts abzubrechen")
        XCTAssertTrue(ConnectionBarPresentation(.ready(portPath: port, pointCount: 1)).showsDisconnect)
        XCTAssertFalse(ConnectionBarPresentation(.streamLost(portPath: port, message: "x")).isBusy)
    }

    func testRateFormattingUsesOneDecimalWithComma() {
        XCTAssertEqual(ConnectionBarPresentation.format(rateHz: 12.46), "12,5 Hz")
        XCTAssertEqual(ConnectionBarPresentation.format(rateHz: 4.0), "4,0 Hz")
        XCTAssertEqual(ConnectionBarPresentation.format(rateHz: 0.04), "0,0 Hz")
    }
}

extension ConnectionBarState: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ConnectionBarPresentation(self).statusText)
    }
}
