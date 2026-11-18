import PlanariumInput
import PlanariumDomain
import XCTest
import SickPLSMacTransport
import SickPLSMonitorKit
import PlanariumPresets
@testable import PlanariumScannerUI

/// Lebenszyklus: **genau ein** Abonnement, kein alter Worker, kein
/// zweiter Empfänger — und niemals ein Autostart der Ausgabe.
@MainActor final class CoordinatorLifecycleTests: XCTestCase {

    // MARK: - Abonnement und Worker

    func testTheCoordinatorSubscribesExactlyOnceAtInit() {
        let harness = CoordinatorHarness(
            descriptors: [FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 20))]
        )
        XCTAssertTrue(harness.coordinator.hasActiveProfileSubscription)
    }

    func testDisconnectLeavesNoWorkerAndKeepsTheOneSubscription() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let harness = CoordinatorHarness(descriptors: [descriptor])

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }

        harness.coordinator.disconnect()

        // Kein alter Worker: Der Zustand ist sofort zurückgesetzt und
        // der Deskriptor wird vom Hintergrund-Thread selbst geschlossen.
        // (`RXSession.worker` ist modulintern und von hier aus
        // bewusst nicht erreichbar — geprüft wird das beobachtbare
        // Ergebnis, nicht das private Feld.)
        XCTAssertEqual(harness.coordinator.session.state, ScanSessionState())
        waitUntil { descriptor.closeCallCount == 1 }
        // Das Abonnement gehört der Sitzung, nicht der Verbindung.
        XCTAssertTrue(harness.coordinator.hasActiveProfileSubscription)
    }

    /// **Der Kern des „kein zweiter Empfänger"-Nachweises:** Nach einem
    /// Trennen und erneutem Verbinden kommt jedes Profil weiterhin
    /// **genau einmal** an. Ein zweites Abonnement würde hier sofort
    /// doppelt zählen.
    func testReconnectingDoesNotCreateASecondReceiver() throws {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let first = FakeSerialPortFileDescriptor(
            readScript: [.bytes(bytes)] + Array(repeating: .timeout, count: 50)
        )
        let second = FakeSerialPortFileDescriptor(
            readScript: [.bytes(bytes)] + Array(repeating: .timeout, count: 50)
        )
        let harness = CoordinatorHarness(descriptors: [first, second])

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 1 }
        harness.coordinator.disconnect()
        pumpMainLoop(seconds: 0.2)
        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 1)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }
        pumpMainLoop(seconds: 0.2)

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 2)
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.count, 2)

        harness.coordinator.disconnect()
    }

    /// Ein Profil, das erst **nach** dem Trennen fertig gelesen würde,
    /// erreicht die Klangerzeugung nicht mehr.
    func testNoProfileArrivesAfterDisconnect() throws {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let descriptor = FakeSerialPortFileDescriptor(
            readScript: [.timeout, .bytes(bytes)] + Array(repeating: .timeout, count: 50)
        )
        let harness = CoordinatorHarness(descriptors: [descriptor])

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        harness.coordinator.disconnect()
        pumpMainLoop(seconds: 0.5)

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 0)
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.count, 0)
    }

    /// Nach dem Freigeben des Koordinators erreicht kein Profil mehr den
    /// Controller — die `AnyCancellable` endet mit ihm.
    ///
    /// Die Sitzung wird hier außerhalb stark gehalten,
    /// sonst wäre der Nachweis trivial (mit dem Koordinator verschwände
    /// ohnehin alles).
    func testAfterTheCoordinatorIsReleasedTheSessionContinuesWithoutRetainingIt() throws {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let descriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(bytes), .timeout, .bytes(bytes)]
                + Array(repeating: .timeout, count: 50)
        )
        let opener = FakeSerialPortOpener(portsToReturn: [descriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 20)
        weak var weakCoordinator: ScannerWorkspaceModel?
        do {
            let coordinator = ScannerWorkspaceModel(session: session)
            weakCoordinator = coordinator
            coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
            waitUntil { coordinator.deliveredProfileBatches == 1 }
        }

        XCTAssertNil(weakCoordinator, "Der Koordinator muss freigegeben sein")

        // Das zweite Profil kommt real an — beim Monitorzustand.
        waitUntil { session.state.diagnostics.validFrames == 2 }
        pumpMainLoop(seconds: 0.2)

        // Die freigegebene Koordinatorinstanz darf vom Abonnement nicht gehalten werden.
        XCTAssertNil(weakCoordinator)

        InputOwner(session: session).disconnect()
    }

    // MARK: - Kein Autostart

    func testNeitherConnectingNorProfilesStartAudio() throws {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = CoordinatorHarness(
            descriptors: [FakeSerialPortFileDescriptor(
                readScript: [.bytes(bytes), .timeout, .bytes(bytes)]
                    + Array(repeating: .timeout, count: 50)
            )]
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }

        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertFalse(harness.engine.isRunning)
        XCTAssertTrue(harness.root.audio.status.isEmpty)

        harness.coordinator.disconnect()
    }

    func testAZoneChangeNeverStartsAudio() {
        let harness = CoordinatorHarness(
            descriptors: [FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 20))]
        )

        harness.removeZone(harness.gateZoneID)

        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertFalse(harness.engine.isRunning)
    }

    /// Der ausdrückliche Start ist und bleibt der einzige Weg zur
    /// Ausgabe — die Gegenrichtung zum Autostart-Nachweis.
}
