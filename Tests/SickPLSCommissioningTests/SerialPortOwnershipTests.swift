import PlanariumInput
import XCTest
import SickPLSMacTransport
@testable import SickPLSCommissioning

/// Das Besitzmodell (Auflage **A3**). **Ein zweiter gleichzeitiger
/// Besitzer ist strukturell unmöglich** — das ist die Zusage, die diese
/// Tests belegen.
final class SerialPortOwnershipTests: XCTestCase {

    func testAFreshOwnershipIsFree() {
        let ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.owner, .free)
        XCTAssertFalse(ownership.isAwaitingRelease)
        XCTAssertNil(ownership.verifiedBaudRate)
    }

    func testCommissioningIsRefusedWhileTheMonitorHoldsThePort() {
        var ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForMonitor(), .granted)
        XCTAssertEqual(ownership.claimForCommissioning(), .refused(.heldByMonitor))
        XCTAssertEqual(ownership.owner, .monitor, "Der Anspruch ändert nichts")
    }

    func testTheMonitorIsRefusedWhileCommissioningHoldsThePort() {
        var ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForCommissioning(), .granted)
        XCTAssertEqual(ownership.claimForMonitor(), .refused(.heldByCommissioning))
        XCTAssertEqual(ownership.owner, .commissioning)
    }

    /// **Der Kern der Auflage:** Trennen allein gibt den Port nicht
    /// frei. `disconnect()` kehrt sofort zurück, das echte `close()`
    /// folgt später auf dem Lesethread.
    func testDisconnectAloneDoesNotReleaseThePort() {
        var ownership = SerialPortOwnership()
        ownership.claimForMonitor()
        ownership.noteMonitorDisconnectRequested()

        XCTAssertTrue(ownership.isAwaitingRelease)
        XCTAssertEqual(
            ownership.claimForCommissioning(), .refused(.awaitingRelease),
            "Solange das Schließen aussteht, bekommt niemand den Port"
        )
        XCTAssertEqual(ownership.owner, .monitor)
    }

    func testOnlyTheActualReleaseSignalFreesThePort() {
        var ownership = SerialPortOwnership()
        ownership.claimForMonitor()
        ownership.noteMonitorDisconnectRequested()
        ownership.notePortReleased()

        XCTAssertEqual(ownership.owner, .free)
        XCTAssertFalse(ownership.isAwaitingRelease)
        XCTAssertEqual(ownership.claimForCommissioning(), .granted)
    }

    /// Die Freigabe darf auch ohne vorheriges „getrennt" ankommen — ein
    /// Stromende trennt von sich aus.
    func testAReleaseWithoutAPriorDisconnectAlsoFrees() {
        var ownership = SerialPortOwnership()
        ownership.claimForMonitor()
        ownership.notePortReleased()
        XCTAssertEqual(ownership.owner, .free)
    }

    /// Eine verspätete Freigabe darf dem Commissioning nicht den Port
    /// unter den Füßen wegziehen.
    func testALateReleaseDoesNotStealThePortFromCommissioning() {
        var ownership = SerialPortOwnership()
        ownership.claimForMonitor()
        ownership.noteMonitorDisconnectRequested()
        ownership.notePortReleased()
        ownership.claimForCommissioning()

        ownership.notePortReleased()   // verspätete Meldung der alten Verbindung

        XCTAssertEqual(ownership.owner, .commissioning)
    }

    func testRepeatedReleasesAreHarmless() {
        var ownership = SerialPortOwnership()
        ownership.claimForMonitor()
        ownership.notePortReleased()
        ownership.notePortReleased()
        XCTAssertEqual(ownership.owner, .free)
    }

    func testClaimingTwiceForTheSameOwnerIsNotAnError() {
        var ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForMonitor(), .granted)
        XCTAssertEqual(ownership.claimForMonitor(), .granted)
        XCTAssertEqual(ownership.owner, .monitor)
    }

    // MARK: - Verifizierte Rate

    /// **Nach belegter Verifikation verbindet der Monitor mit der
    /// verifizierten Rate**, nicht mit einer Nutzereingabe.
    func testAfterVerificationTheMonitorUsesTheVerifiedRate() {
        var ownership = SerialPortOwnership()
        ownership.claimForCommissioning()
        ownership.releaseCommissioning(verifiedBaudRate: .baud38400)

        XCTAssertEqual(ownership.owner, .free)
        XCTAssertEqual(ownership.verifiedBaudRate, .baud38400)
        XCTAssertEqual(
            ownership.monitorConnectBaudRate(requested: .baud9600), .baud38400,
            "Die belegte Rate schlägt den Nutzerwert"
        )
    }

    func testWithoutAVerifiedRateTheRequestedOneIsUsed() {
        let ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.monitorConnectBaudRate(requested: .baud9600), .baud9600)
        XCTAssertEqual(ownership.monitorConnectBaudRate(requested: .baud38400), .baud38400)
    }

    /// Ein gescheiterter Ablauf überschreibt eine früher belegte Rate
    /// nicht — er hat nichts Neues bewiesen.
    func testAFailedRunLeavesAPreviouslyVerifiedRateAlone() {
        var ownership = SerialPortOwnership()
        ownership.claimForCommissioning()
        ownership.releaseCommissioning(verifiedBaudRate: .baud38400)
        ownership.claimForCommissioning()
        ownership.releaseCommissioning(verifiedBaudRate: nil)

        XCTAssertEqual(ownership.verifiedBaudRate, .baud38400)
    }

    /// Das Freigeben durch den Falschen ist wirkungslos.
    func testReleasingCommissioningWhileTheMonitorHoldsChangesNothing() {
        var ownership = SerialPortOwnership()
        ownership.claimForMonitor()
        ownership.releaseCommissioning(verifiedBaudRate: .baud38400)
        XCTAssertEqual(ownership.owner, .monitor)
        XCTAssertNil(ownership.verifiedBaudRate)
    }
}
