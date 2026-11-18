import PlanariumInput
import XCTest
import SickPLSActiveControl
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// **Die Koordinatorseite von SICK-031:** Startvoraussetzung und
/// Abschluss eines Einrichtungslaufs.
///
/// Der Bericht stammt hier aus einem **echten** `CommissioningExecutor`
/// über einen Fake-Transport — nicht aus einem nachgebauten Wert. Nur so
/// belegt der Test wirklich, dass die Rate ausschließlich über eine
/// CRC-valide Identitätsantwort bei der Zielrate in den Koordinator
/// gelangt (Auflage A1).
///
/// **Kein echter Port, kein Gerät, kein Byte an Hardware.** Gefälscht
/// sind allein Dateideskriptor, Transport und Audiohost; `RXSession`
/// läuft mit ihrem echten Hintergrund-Thread.
@MainActor final class CoordinatorCommissioningRunTests: XCTestCase {

    private func harness(
        descriptors: [FakeSerialPortFileDescriptor] = [
            FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        ]
    ) -> CoordinatorHarness {
        CoordinatorHarness(descriptors: descriptors)
    }

    // MARK: - Startvoraussetzung

    func testAFreshCoordinatorIsReadyOnACalloutPath() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.commissioningRunReadiness(portPath: "/dev/cu.fake"), .ready)
    }

    /// Ohne ausgewählten Port gibt es nichts zu öffnen — und das ist eine
    /// **eigene** Lage, kein „nicht bereit".
    func testWithoutASelectedPortTheRunIsNotReadyForItsOwnReason() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.commissioningRunReadiness(portPath: ""), .noPortSelected)
    }

    /// Die `/dev/cu.`-Grenze wird **vorab** beantwortet, damit eine
    /// spätere Oberfläche begründet sperren kann; durchgesetzt wird sie
    /// trotzdem ein zweites Mal im Transport.
    func testAPathOutsideCalloutDevicesIsAnsweredInAdvance() {
        let harness = harness()
        XCTAssertEqual(
            harness.coordinator.commissioningRunReadiness(portPath: "/dev/tty.fake"),
            .portPathNotAllowed
        )
    }

    /// **Der Monitor muss zuerst kontrolliert getrennt werden** — und
    /// zwischen „getrennt" und „wirklich geschlossen" liegt noch eine
    /// eigene Lage.
    func testTheMonitorMustDisconnectFirstAndTheRealReleaseIsAwaited() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let harness = harness(descriptors: [descriptor])

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }

        XCTAssertEqual(
            harness.coordinator.commissioningRunReadiness(portPath: "/dev/cu.fake"),
            .monitorMustDisconnectFirst
        )

        harness.coordinator.disconnect()
        XCTAssertEqual(descriptor.closeCallCount, 0, "Noch ist nichts geschlossen")
        XCTAssertEqual(
            harness.coordinator.commissioningRunReadiness(portPath: "/dev/cu.fake"),
            .awaitingPortRelease
        )

        waitUntil { harness.coordinator.portOwner == .free }
        XCTAssertEqual(descriptor.closeCallCount, 1)
        XCTAssertEqual(harness.coordinator.commissioningRunReadiness(portPath: "/dev/cu.fake"), .ready)
    }

    /// **Die Auskunft führt nichts aus.** Sie beansprucht nichts, öffnet
    /// nichts und fasst die Sitzung nicht an — auch nicht beim zehnten
    /// Mal.
    func testAskingForReadinessChangesNothingAtAll() {
        let harness = harness()

        for _ in 0..<10 {
            _ = harness.coordinator.commissioningRunReadiness(portPath: "/dev/cu.fake")
            _ = harness.coordinator.commissioningRunReadiness(portPath: "/dev/tty.fake")
            _ = harness.coordinator.commissioningRunReadiness(portPath: "")
        }

        XCTAssertEqual(harness.coordinator.portOwner, .free)
        XCTAssertFalse(harness.coordinator.isAwaitingPortRelease)
        XCTAssertNil(harness.coordinator.portAccessNotice)
        XCTAssertTrue(harness.opener.requestedPaths.isEmpty, "Die Sitzung wurde nie angefasst")
        XCTAssertEqual(harness.coordinator.session.state, ScanSessionState())
    }

    // MARK: - Abschluss: genau einmal freigeben

    /// **Der Kernnachweis.** Ein echter, erfolgreicher Lauf endet mit
    /// einer belegten Zielrate, und der Koordinator gibt den Besitz
    /// **genau einmal** frei und übernimmt genau diese Rate.
    func testAFinalReportWithAProvenRateReleasesOnceAndAdoptsThatRate() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)

        let report = runSuccessfulSwitchToTheTargetRate()
        XCTAssertEqual(report.verifiedBaudRate, .baud38400)
        XCTAssertTrue(report.isFinal)

        let outcome = harness.coordinator.completeCommissioning(with: report)

        XCTAssertEqual(outcome, .released(verifiedBaudRate: .baud38400))
        XCTAssertEqual(harness.coordinator.portOwner, .free)
        XCTAssertEqual(harness.coordinator.verifiedBaudRate, .baud38400)

        // Und die belegte Rate schlägt die Bedienauswahl beim nächsten
        // Verbinden -- der eigentliche Zweck des ganzen Laufs.
        XCTAssertEqual(
            harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600),
            .connecting(baudRate: .baud38400)
        )
        harness.coordinator.disconnect()
    }

    /// **Ein zweiter Abschlussaufruf gibt nicht ein zweites Mal frei** —
    /// er landet sichtbar in `notHoldingPort`.
    func testASecondCompletionIsRefusedInsteadOfReleasingTwice() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        let report = runSuccessfulSwitchToTheTargetRate()

        XCTAssertEqual(
            harness.coordinator.completeCommissioning(with: report),
            .released(verifiedBaudRate: .baud38400)
        )
        XCTAssertEqual(harness.coordinator.completeCommissioning(with: report), .notHoldingPort)
        XCTAssertEqual(harness.coordinator.portOwner, .free)
    }

    /// Ein Abschluss **ohne** gehaltenen Port gibt nichts frei und
    /// übernimmt vor allem keine Rate.
    func testCompletingWithoutHoldingThePortAdoptsNothing() {
        let harness = harness()
        let report = runSuccessfulSwitchToTheTargetRate()

        XCTAssertEqual(harness.coordinator.completeCommissioning(with: report), .notHoldingPort)
        XCTAssertNil(harness.coordinator.verifiedBaudRate)
    }

    /// **Ein Ruhepunkt ist kein Endstand.** Der Ablauf hält den Port
    /// weiter, und es wird nichts freigegeben.
    func testAReportThatIsNotFinalReleasesNothing() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)

        let clock = TestMonotonicClock()
        let transport = SilentCommissioningTransport(
            readScript: [.bytes(identityResponse().encoded())], clock: clock
        )
        let executor = CommissioningExecutor(transport: transport, clock: clock)
        let report = executor.perform(.checkStartingRate)

        XCTAssertFalse(report.isFinal)
        XCTAssertTrue(report.isPortHeld)
        XCTAssertEqual(harness.coordinator.completeCommissioning(with: report), .stillRunning)
        XCTAssertEqual(harness.coordinator.portOwner, .commissioning, "Der Port bleibt beansprucht")
        XCTAssertNil(harness.coordinator.verifiedBaudRate)
    }

    /// **Ein Fehlschlag gibt frei, belegt aber nichts** — und lässt eine
    /// früher belegte Rate unangetastet.
    func testAFailedRunReleasesWithoutProvingARate() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        XCTAssertEqual(harness.coordinator.completeCommissioning(with: runSuccessfulSwitchToTheTargetRate()), .released(verifiedBaudRate: .baud38400))

        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        let clock = TestMonotonicClock()
        let transport = SilentCommissioningTransport(readScript: [], clock: clock)
        let executor = CommissioningExecutor(transport: transport, clock: clock)
        let failed = executor.perform(.checkStartingRate)

        XCTAssertTrue(failed.isFinal)
        XCTAssertNil(failed.verifiedBaudRate)
        XCTAssertEqual(
            harness.coordinator.completeCommissioning(with: failed),
            .released(verifiedBaudRate: nil)
        )
        XCTAssertEqual(harness.coordinator.portOwner, .free)
        XCTAssertEqual(
            harness.coordinator.verifiedBaudRate, .baud38400,
            "Die früher belegte Rate bleibt stehen"
        )
    }

    /// **Ein beobachteter Messstrom belegt die Rate nicht.** Der
    /// Koordinator leitet sie nicht ab — er nimmt ausschließlich, was im
    /// Bericht steht.
    func testAnObservedScanProfileStreamNeverSetsTheRate() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)

        let clock = TestMonotonicClock()
        let transport = SilentCommissioningTransport(readScript: [
            .bytes(identityResponse().encoded()),
            .bytes(acknowledgement().encoded()),
            .bytes(acknowledgement().encoded()),
            .bytes(scanProfile().encoded()),
            .bytes(scanProfile().encoded())
        ], clock: clock)
        let executor = CommissioningExecutor(transport: transport, clock: clock)
        executor.perform(.checkStartingRate)
        let report = executor.perform(.switchBaudRate, secret: fabricatedSecret)

        XCTAssertTrue(report.observedScanProfileStream)
        XCTAssertNil(report.verifiedBaudRate)
        XCTAssertEqual(
            harness.coordinator.completeCommissioning(with: report),
            .released(verifiedBaudRate: nil)
        )
        XCTAssertNil(harness.coordinator.verifiedBaudRate)
    }

    // MARK: - Nichts davon startet etwas

    /// **Kein Autostart.** Weder Anfordern noch Abschließen eines
    /// Einrichtungslaufs startet die Audioausgabe, den Nachführtakt oder
    /// eine Monitorverbindung.
    func testACommissioningRunNeverStartsAudioTheTickerOrTheMonitor() {
        let harness = harness()

        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        XCTAssertEqual(harness.coordinator.completeCommissioning(with: runSuccessfulSwitchToTheTargetRate()), .released(verifiedBaudRate: .baud38400))

        XCTAssertFalse(harness.engine.isRunning)
        XCTAssertTrue(harness.root.audio.status.isEmpty)
        XCTAssertFalse(harness.host.isRunning)
        XCTAssertTrue(harness.opener.requestedPaths.isEmpty, "Es wurde nie eine Sitzung geöffnet")
        XCTAssertEqual(harness.coordinator.session.state, ScanSessionState())
    }

    /// Und der Monitor kommt während eines laufenden Einrichtungslaufs
    /// nicht an den Port.
    func testTheMonitorIsRefusedWhileARunHoldsThePort() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)

        XCTAssertEqual(
            harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600),
            .refused(.heldByCommissioning)
        )
        XCTAssertEqual(
            harness.coordinator.commissioningRunReadiness(portPath: "/dev/cu.fake"), .ready,
            "Der laufende Vorgang selbst darf weitermachen"
        )
    }

    // MARK: - Hilfen

    /// Fährt einen **echten** Executor über einen Fake-Transport durch
    /// den vollständigen Weg 9600 → 38400 und gibt den Endbericht zurück.
    private func runSuccessfulSwitchToTheTargetRate() -> CommissioningStepReport {
        let clock = TestMonotonicClock()
        let transport = SilentCommissioningTransport(readScript: [
            .bytes(identityResponse().encoded()),
            .bytes(acknowledgement().encoded()),
            .bytes(acknowledgement().encoded()),
            .bytes(acknowledgement().encoded()),
            .bytes(identityResponse().encoded())
        ], clock: clock)
        let executor = CommissioningExecutor(transport: transport, clock: clock)
        executor.perform(.checkStartingRate)
        executor.perform(.switchBaudRate, secret: fabricatedSecret)
        return executor.perform(.finishSession)
    }

    /// Acht frei erfundene Bytes — **mit dem echten Wert aus der
    /// technischen Dokumentation hat das nichts zu tun** (Auflage A5).
    private var fabricatedSecret: InstallationSecret {
        InstallationSecret(bytes: [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])!
    }

    private func identityResponse() -> Frame {
        try! Frame.build(
            address: 0x81,
            payload: [IdentityProbe.expectedResponseCommandByte, 0x41, 0x42]
        )
    }

    private func acknowledgement() -> Frame {
        try! Frame.build(
            address: 0x81,
            payload: [AcknowledgementClassifier.responseCommandByte, 0x00, 0x00]
        )
    }

    private func scanProfile() -> Frame {
        try! Frame.build(
            address: 0x81,
            payload: [AcknowledgementClassifier.scanProfileCommandByte, 0x02, 0x00, 0x10, 0x00, 0x20, 0x00, 0xAA]
        )
    }
}

/// Ein Transport, der **nichts** tut als das Skript abzuspielen.
///
/// Er ist bewusst schlicht: Der ausführliche Nachweis der Grenze steht in
/// `SickPLSCommissioningTests`; hier geht es allein darum, einen echten
/// Bericht zu erzeugen.
private final class SilentCommissioningTransport: CommissioningTransport {
    private var readScript: [SerialPortReadOutcome]
    private var isOpen = false
    /// Die Zeitbasis, die auch der Executor benutzt.
    ///
    /// Seit SICK-031a (E2) ist ein `.timeout` kein Fristende mehr,
    /// sondern führt zurück in die Restfrist-Schleife. Die Frist muss
    /// hier deshalb wirklich verstreichen — sonst liefe die Schleife
    /// endlos, und mit einer echten Uhr wäre der Test langsam statt
    /// deterministisch.
    let clock: TestMonotonicClock

    init(readScript: [SerialPortReadOutcome], clock: TestMonotonicClock) {
        self.readScript = readScript
        self.clock = clock
    }

    func openPort(baudRate: SerialPortBaudRate) throws {
        guard !isOpen else { throw CommissioningTransportError.portAlreadyOpen }
        isOpen = true
    }

    func closePort() throws { isOpen = false }

    func flushReceiveBuffer() {}

    func write(_ bytes: [UInt8]) throws {
        guard isOpen else { throw CommissioningTransportError.portNotOpen }
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        guard !readScript.isEmpty else {
            clock.advance(by: Int64(timeoutMilliseconds))
            return .timeout
        }
        clock.advance(by: 10)
        return readScript.removeFirst()
    }
}

/// Eine Uhr, die ausschließlich der Test bewegt.
///
/// Eigene Kopie: `SickPLSCommissioningTests` ist ein anderes Bundle, und
/// eine geteilte Testgrundlage über Bundlegrenzen hinweg gäbe es nur um
/// den Preis eines gemeinsamen Ziels.
final class TestMonotonicClock: MonotonicClock {
    private(set) var millis: Int64 = 0
    func nowMilliseconds() -> Int64 { millis }
    func advance(by delta: Int64) { millis += delta }
}
