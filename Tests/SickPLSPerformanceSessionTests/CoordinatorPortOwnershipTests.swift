@testable import PlanariumInput
import XCTest
import SickPLSCommissioning
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// **Der Nachweis von SICK-030a1:** Der Portbesitz ist im produktiven
/// Koordinator durchgesetzt — nicht mehr nur als Parallelstruktur
/// daneben gebaut.
///
/// Gearbeitet wird mit der **echten** `RXSession` samt echtem
/// Hintergrund-Thread und echtem Freigabe-Ereignis; gefälscht ist allein
/// der Dateideskriptor. Das ist der Punkt: Die Aussage „erst nach dem
/// tatsächlichen `close()`" lässt sich nur am echten Ereignis zeigen.
@MainActor final class CoordinatorPortOwnershipTests: XCTestCase {

    private func harness(
        descriptors: [FakeSerialPortFileDescriptor] = [
            FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        ]
    ) -> CoordinatorHarness {
        CoordinatorHarness(descriptors: descriptors)
    }

    // MARK: - Ausgangszustand

    func testAFreshCoordinatorHoldsNothingAndSubscribesExactlyOnce() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.portOwner, .free)
        XCTAssertFalse(harness.coordinator.isAwaitingPortRelease)
        XCTAssertNil(harness.coordinator.verifiedBaudRate)
        XCTAssertNil(harness.coordinator.portAccessNotice)
        XCTAssertTrue(harness.coordinator.hasActivePortReleaseSubscription)
    }

    func testConnectingClaimsTheMonitorOwnership() {
        let harness = harness()

        let outcome = harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)

        XCTAssertEqual(outcome, .connecting(baudRate: .baud9600))
        XCTAssertEqual(harness.coordinator.portOwner, .monitor)
        XCTAssertNil(harness.coordinator.portAccessNotice)

        harness.coordinator.disconnect()
    }

    // MARK: - a) Commissioning erst nach dem echten Freigabe-Ereignis

    /// **Die Kernaussage.** Nach dem Trennen ist der Port nicht sofort
    /// frei: `RXSession.disconnect()` kehrt sofort zurück, das echte
    /// `close(2)` folgt später auf dem Lesethread.
    func testCommissioningIsGrantedOnlyAfterTheRealPortReleaseEvent() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let harness = harness(descriptors: [descriptor])

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }

        harness.coordinator.disconnect()

        // Synchron unmittelbar danach: Der Deskriptor ist nachweislich
        // noch offen -- und genau deshalb bekommt das Commissioning den
        // Port nicht.
        XCTAssertEqual(descriptor.closeCallCount, 0)
        XCTAssertTrue(harness.coordinator.isAwaitingPortRelease)
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .awaitingMonitorRelease)
        XCTAssertEqual(harness.coordinator.portOwner, .monitor)

        // Jetzt das echte Ereignis abwarten.
        waitUntil { harness.coordinator.portOwner == .free }
        XCTAssertEqual(descriptor.closeCallCount, 1, "Freigegeben wurde erst nach dem echten close()")
        XCTAssertFalse(harness.coordinator.isAwaitingPortRelease)

        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        XCTAssertEqual(harness.coordinator.portOwner, .commissioning)
    }

    /// Fordert das Commissioning bei **laufendem** Monitor an, wird
    /// höchstens dessen kontrolliertes Trennen veranlasst — nie ein
    /// Deskriptor weggerissen.
    func testRequestingCommissioningWhileConnectedOnlyAsksTheMonitorToDisconnect() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let harness = harness(descriptors: [descriptor])

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }

        let outcome = harness.coordinator.requestCommissioningAccess()

        XCTAssertEqual(outcome, .awaitingMonitorRelease)
        XCTAssertEqual(harness.coordinator.portOwner, .monitor, "Der Besitz wechselt nicht im Vorgriff")
        XCTAssertTrue(harness.coordinator.isAwaitingPortRelease)
        XCTAssertNotNil(harness.coordinator.portAccessNotice, "Und der Bedienende erfährt davon")

        waitUntil { harness.coordinator.portOwner == .free }
        XCTAssertEqual(descriptor.closeCallCount, 1)
    }

    // MARK: - b) Der Monitor darf während des Commissionings nicht verbinden

    func testTheMonitorCannotConnectWhileCommissioningHoldsThePort() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)

        let outcome = harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)

        XCTAssertEqual(outcome, .refused(.heldByCommissioning))
        XCTAssertEqual(harness.coordinator.portOwner, .commissioning)
        XCTAssertNotNil(harness.coordinator.portAccessNotice)
        XCTAssertTrue(
            harness.opener.requestedPaths.isEmpty,
            "Die Sitzung wurde gar nicht erst angefasst"
        )
        XCTAssertEqual(harness.coordinator.session.state, ScanSessionState())
    }

    /// Nach Abschluss ist der Weg wieder frei.
    func testAfterCommissioningFinishesTheMonitorCanConnectAgain() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        harness.coordinator.finishCommissioning()

        XCTAssertEqual(harness.coordinator.portOwner, .free)
        XCTAssertEqual(
            harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600),
            .connecting(baudRate: .baud9600)
        )

        harness.coordinator.disconnect()
    }

    // MARK: - c) Auch ein gescheitertes Öffnen gibt frei

    /// Ohne diesen Weg bliebe der Port für immer beansprucht, obwohl ihn
    /// niemand hält — und zwar genau dann, wenn etwas schiefging.
    func testAFailedMonitorOpenReleasesThePortThroughTheRealEvent() {
        let harness = harness(descriptors: [])
        harness.opener.errorToThrow = FakeSerialPortOpener.OpenFailure()

        XCTAssertEqual(
            harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600),
            .connecting(baudRate: .baud9600)
        )
        XCTAssertEqual(harness.coordinator.portOwner, .monitor)

        waitUntil { harness.coordinator.portOwner == .free }

        XCTAssertFalse(harness.coordinator.isAwaitingPortRelease)
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
    }

    // MARK: - d) Die verifizierte Rate schlägt die Bedienauswahl

    func testAVerifiedRateBeatsTheRequestedOne() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        harness.coordinator.finishCommissioning(verifiedBaudRate: .baud38400)

        XCTAssertEqual(harness.coordinator.verifiedBaudRate, .baud38400)

        let outcome = harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)

        XCTAssertEqual(outcome, .connecting(baudRate: .baud38400))
        waitUntil { !harness.opener.requestedBaudRates.isEmpty }
        XCTAssertEqual(
            harness.opener.requestedBaudRates, [.baud38400],
            "Geöffnet wird mit der belegten Rate, nicht mit der angefragten"
        )

        harness.coordinator.disconnect()
    }

    func testDevelopmentConnectionUsesExplicit500KEvenAfterOlderVerification() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        harness.coordinator.finishCommissioning(verifiedBaudRate: .baud38400)

        let outcome = harness.coordinator.connectDevelopment(
            portPath: "/dev/cu.fake", baudRate: .baud500000
        )

        XCTAssertEqual(outcome, .connecting(baudRate: .baud500000))
        waitUntil { !harness.opener.requestedBaudRates.isEmpty }
        XCTAssertEqual(harness.opener.requestedBaudRates, [.baud500000])

        harness.coordinator.disconnect()
    }

    /// Ohne Verifikation gilt unverändert die Bedienauswahl.
    func testWithoutAVerifiedRateTheRequestedOneIsUsed() {
        let harness = harness()

        XCTAssertEqual(
            harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600),
            .connecting(baudRate: .baud9600)
        )
        waitUntil { !harness.opener.requestedBaudRates.isEmpty }
        XCTAssertEqual(harness.opener.requestedBaudRates, [.baud9600])

        harness.coordinator.disconnect()
    }

    /// Ein gescheiterter Einrichtungslauf belegt nichts — und überschreibt
    /// eine früher belegte Rate nicht.
    func testAFailedCommissioningRunLeavesTheVerifiedRateAlone() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        harness.coordinator.finishCommissioning(verifiedBaudRate: .baud38400)
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        harness.coordinator.finishCommissioning(verifiedBaudRate: nil)

        XCTAssertEqual(harness.coordinator.verifiedBaudRate, .baud38400)
    }

    // MARK: - Rückmeldung

    /// Eine Verweigerung ist sichtbar — und verschwindet erst durch
    /// einen **erfolgreichen** Bedienschritt an derselben Stelle
    /// (dieselbe Regel wie `PerformanceNotice` seit SICK-028).
    func testTheNoticeSurvivesUntilTheNextSuccessfulStep() {
        let harness = harness()
        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        let refusalNotice = harness.coordinator.portAccessNotice
        XCTAssertNotNil(refusalNotice)

        pumpMainLoop(seconds: 0.2)
        XCTAssertEqual(harness.coordinator.portAccessNotice, refusalNotice, "Kein Verschwinden durch Zeitablauf")

        harness.coordinator.finishCommissioning()
        XCTAssertNil(harness.coordinator.portAccessNotice)
    }

    /// Jede Verweigerungsursache trägt ihren eigenen Text — „belegt" und
    /// „wird gerade geschlossen" sind für den Bedienenden zwei Lagen.
    func testEveryRefusalHasItsOwnMessage() {
        let messages = Set(
            [SerialPortOwnershipRefusal.heldByMonitor, .heldByCommissioning, .awaitingRelease]
                .map { PortAccessNotice.describing($0).message }
        )
        XCTAssertEqual(messages.count, 3)
        XCTAssertFalse(messages.contains(where: \.isEmpty))
    }

    // MARK: - Der Besitz überlebt keine Abkürzung

    /// Das Profilabonnement und das Freigabe-Abonnement gehören beide
    /// der Sitzung: Ein zweiter `connect` legt **kein zweites** an.
    func testReconnectingCreatesNoSecondSubscription() {
        let harness = harness(descriptors: [
            FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200)),
            FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        ])

        harness.coordinator.connect(portPath: "/dev/cu.a", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.connection == .connected(portPath: "/dev/cu.a", baudRate: .baud9600) }
        harness.coordinator.disconnect()
        waitUntil { harness.coordinator.portOwner == .free }

        harness.coordinator.connect(portPath: "/dev/cu.b", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.connection == .connected(portPath: "/dev/cu.b", baudRate: .baud9600) }
        XCTAssertEqual(harness.coordinator.portOwner, .monitor)

        harness.coordinator.disconnect()
        waitUntil { harness.coordinator.portOwner == .free }
        XCTAssertTrue(harness.coordinator.hasActivePortReleaseSubscription)
        XCTAssertTrue(harness.coordinator.hasActiveProfileSubscription)
    }

    /// **Klärung vor einer Änderung (RECONNECT-2):** Der produktive Weg kann
    /// während des echten Schließens keine neue Sitzungsgeneration starten.
    /// Der frühe Coordinator-Versuch wird am Besitzmodell abgewiesen; erst
    /// nach der tatsächlichen Freigabe folgen Commissioning und Monitor in
    /// der vorgesehenen Reihenfolge.
    func testProductiveReconnectWaitsForReleaseBeforeCommissioningAndMonitor() {
        let first = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let second = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let harness = harness(descriptors: [first, second])

        XCTAssertEqual(
            harness.coordinator.connect(portPath: "/dev/cu.first", baudRate: .baud9600),
            .connecting(baudRate: .baud9600)
        )
        waitUntil {
            harness.coordinator.session.state.connection ==
                .connected(portPath: "/dev/cu.first", baudRate: .baud9600)
        }

        harness.coordinator.disconnect()
        XCTAssertEqual(
            harness.coordinator.connect(portPath: "/dev/cu.early", baudRate: .baud9600),
            .refused(.awaitingRelease)
        )
        XCTAssertEqual(harness.coordinator.portOwner, .monitor)
        XCTAssertTrue(harness.coordinator.isAwaitingPortRelease)

        waitUntil { first.closeCallCount == 1 }
        waitUntil { harness.coordinator.portOwner == .free }
        XCTAssertFalse(harness.coordinator.isAwaitingPortRelease)

        XCTAssertEqual(harness.coordinator.requestCommissioningAccess(), .granted)
        harness.coordinator.finishCommissioning()
        XCTAssertEqual(harness.coordinator.portOwner, .free)
        XCTAssertEqual(
            harness.coordinator.connect(portPath: "/dev/cu.second", baudRate: .baud38400),
            .connecting(baudRate: .baud38400)
        )
        waitUntil { harness.opener.requestedPaths.count == 2 }
        harness.coordinator.disconnect()
        waitUntil { second.closeCallCount == 1 }
        waitUntil { harness.coordinator.portOwner == .free }
    }
}
