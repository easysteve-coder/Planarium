@testable import PlanariumInput
import XCTest
import Combine
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSMonitorKit

/// Die Portübergabe (SICK-030a, Auflage **A3**).
///
/// ## Was hier bewiesen wird
///
/// „Nur einer darf den Port haben" scheiterte bisher an einer
/// Zeitlücke: ``RXSession/disconnect()`` kehrt **sofort** zurück, das
/// `close(2)` macht der Lesethread später. Wer unmittelbar danach
/// denselben Pfad öffnete, traf womöglich auf einen noch offenen
/// Deskriptor.
///
/// Diese Tests belegen die Zusage, mit der die Lücke geschlossen ist:
/// **das Freigabesignal kommt nach dem tatsächlichen `close()` und genau
/// einmal je Verbindungsversuch.** Der Beweis hängt am
/// `closeCallCount` des Fake-Deskriptors — nicht an einer Wartezeit.
///
/// Kein physisches Gerät, ausschließlich die Fakes aus `Fakes.swift`,
/// aber mit dem **echten** Hintergrund-Thread von ``ReadLoopWorker``.
@MainActor final class ScanPortReleaseTests: XCTestCase {

    /// Wartet auf eine Bedingung. Das Zeitlimit begrenzt eine Flake und ist
    /// **keine** Zusicherung; siehe die gleichnamige Hilfe in `RXSessionTests`.
    private func waitUntil(
        timeout: TimeInterval = 10.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("Bedingung nicht innerhalb von \(timeout)s erfüllt", file: file, line: line)
    }

    /// Läuft den RunLoop eine feste Spanne weiter, um zu belegen, dass
    /// **nichts mehr** kommt. Ein „es kam nur eins" ist ohne diese
    /// Nachlaufzeit keine Aussage.
    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Zeichnet jede Freigabe auf, **zusammen mit dem Schließzähler zum
    /// Zeitpunkt der Zustellung** — daran hängt die Reihenfolgeaussage.
    private func record(
        _ session: RXSession,
        _ descriptor: FakeSerialPortFileDescriptor?
    ) -> ReleaseLog {
        let log = ReleaseLog()
        session.portReleased
            .sink { release in
                log.append(release, closeCountAtDelivery: descriptor?.closeCallCount ?? -1)
            }
            .store(in: &cancellables)
        return log
    }

    final class ReleaseLog {
        private(set) var releases: [ScanPortRelease] = []
        private(set) var closeCountsAtDelivery: [Int] = []
        var count: Int { releases.count }

        func append(_ release: ScanPortRelease, closeCountAtDelivery: Int) {
            releases.append(release)
            closeCountsAtDelivery.append(closeCountAtDelivery)
        }
    }

    // MARK: - Die Zeitlücke selbst

    /// **Der Kern der Auflage.** Direkt nach ``RXSession/disconnect()``
    /// hält die Sitzung den Port noch — der Deskriptor ist zu diesem
    /// Zeitpunkt nachweislich noch offen.
    func testDisconnectAloneDoesNotReleaseThePort() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 50))
        let opener = FakeSerialPortOpener(portsToReturn: [descriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 400)
        let log = record(session, descriptor)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }
        XCTAssertTrue(session.isPortHeld)

        session.disconnect()

        // Synchron unmittelbar danach: getrennt, aber **nicht**
        // freigegeben -- der Lesethread steckt noch im Leseversuch.
        XCTAssertEqual(session.state, ScanSessionState(), "Der Zustand ist sofort zurückgesetzt")
        XCTAssertEqual(descriptor.closeCallCount, 0, "Der Deskriptor ist noch offen")
        XCTAssertTrue(session.isPortHeld, "Der Port gilt weiter als gehalten")
        XCTAssertEqual(log.count, 0, "Es wurde noch nichts freigegeben")

        waitUntil { log.count == 1 }
        XCTAssertFalse(session.isPortHeld)
    }

    /// **Freigabe erst nach dem echten `close()`** — belegt am
    /// Schließzähler im Augenblick der Zustellung, nicht an einer
    /// Wartezeit.
    ///
    /// Der Fake braucht dafür ein **langsames** `close()`: Die Freigabe
    /// läuft über `DispatchQueue.main.async`, und dieser Umweg dauert
    /// länger als ein sofort zurückkehrendes `close()` — eine im
    /// Lesethread falsche Reihenfolge wäre beim Eintreffen längst wieder
    /// unsichtbar. Erst das Zeitfenster macht sie sichtbar (die
    /// Gegenprobe „erst freigeben, dann schließen" fällt damit auf).
    func testTheReleaseArrivesOnlyAfterTheDescriptorWasActuallyClosed() {
        let descriptor = FakeSerialPortFileDescriptor(
            readScript: Array(repeating: .timeout, count: 50),
            closeDelaySeconds: 0.3
        )
        let opener = FakeSerialPortOpener(portsToReturn: [descriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 30)
        let log = record(session, descriptor)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }
        session.disconnect()

        waitUntil { log.count == 1 }
        XCTAssertEqual(
            log.closeCountsAtDelivery, [1],
            "Beim Eintreffen der Freigabe muss der Deskriptor bereits geschlossen sein"
        )
    }

    /// Auch das **Stromende** schließt und gibt frei — dieser Pfad
    /// schloss vor SICK-030a gar nicht ausdrücklich.
    func testTheEndOfTheStreamAlsoClosesAndReleases() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: [.closed], closeDelaySeconds: 0.3)
        let opener = FakeSerialPortOpener(portsToReturn: [descriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 30)
        let log = record(session, descriptor)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)

        waitUntil { log.count == 1 }
        XCTAssertEqual(log.closeCountsAtDelivery, [1])
        XCTAssertFalse(session.isPortHeld)
        settle()
        XCTAssertEqual(log.count, 1, "Auch am Stromende genau eine Freigabe")
    }

    // MARK: - Genau einmal

    func testTheReleaseFiresExactlyOncePerConnection() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 50))
        let opener = FakeSerialPortOpener(portsToReturn: [descriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 30)
        let log = record(session, descriptor)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }
        session.disconnect()
        waitUntil { log.count == 1 }

        // Mehrfaches Trennen darf keine zweite Freigabe erzeugen.
        session.disconnect()
        session.disconnect()
        settle()

        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(descriptor.closeCallCount, 1)
    }

    /// **Auch ein gescheitertes Öffnen gibt frei.** Sonst wartete ein
    /// Anspruchsteller auf ein Signal, das nie käme — und der Port wäre
    /// dauerhaft blockiert, obwohl ihn niemand hält.
    func testAFailedOpenReleasesExactlyOnceAsWell() {
        struct OpenFailure: Error {}
        let opener = FakeSerialPortOpener(portsToReturn: [])
        opener.errorToThrow = OpenFailure()
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 30)
        let log = record(session, nil)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)

        waitUntil { log.count == 1 }
        settle()
        XCTAssertEqual(log.count, 1)
        XCTAssertFalse(session.isPortHeld, "Nach einem gescheiterten Öffnen hält die Sitzung nichts")
    }

    // MARK: - Verspätete Freigaben

    /// **Die Freigabe der alten Verbindung darf die neue nicht
    /// freigeben.** Genau das wäre der gefährliche Fall: Das
    /// Commissioning bekäme grünes Licht, während der Monitor gerade
    /// wieder liest.
    func testALateReleaseOfAnOldConnectionDoesNotFreeTheNewOne() {
        let slow = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 50))
        let fresh = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 50))
        let opener = FakeSerialPortOpener(portsToReturn: [slow, fresh])
        // Ein langer Leseversuch hält den alten Worker fest, während die
        // neue Verbindung schon steht -- deterministisch statt zufällig.
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 400)
        let log = record(session, nil)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }

        session.disconnect()
        waitUntil { !session.isPortHeld && slow.closeCallCount == 1 }
        session.connect(portPath: "/dev/cu.fake2", baudRate: .baud38400)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.fake2", baudRate: .baud38400) }

        // Jetzt schließt der **alte** Worker und meldet seine Freigabe.
        waitUntil { slow.closeCallCount == 1 }
        settle()

        XCTAssertEqual(log.count, 1, "Die alte Verbindung wurde vor dem neuen Öffnen wirklich freigegeben")
        XCTAssertTrue(session.isPortHeld, "Die neue Verbindung hält den Port weiter")
        XCTAssertEqual(fresh.closeCallCount, 0)

        session.disconnect()
        waitUntil { log.count == 2 }
        XCTAssertEqual(log.releases.last?.portPath, "/dev/cu.fake2", "Und zwar die der neuen Verbindung")
    }

    // MARK: - Inhalt des Signals

    /// Das Signal trägt Pfad und Rate **seiner eigenen** Verbindung —
    /// und weder Bytes noch Frames noch eine Wanduhrzeit.
    func testTheReleaseCarriesItsOwnConnectionParameters() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: [.closed])
        let opener = FakeSerialPortOpener(portsToReturn: [descriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 30)
        let log = record(session, descriptor)

        session.connect(portPath: "/dev/cu.usbserial-030a", baudRate: .baud38400)
        waitUntil { log.count == 1 }

        XCTAssertEqual(
            log.releases.first,
            ScanPortRelease(portPath: "/dev/cu.usbserial-030a", baudRate: .baud38400)
        )
    }

    /// Der Rundlauf, den das Besitzmodell erwartet: Jede Verbindung
    /// bringt ihre eigene Freigabe, in ihrer eigenen Reihenfolge.
    func testEveryConnectionBringsItsOwnRelease() {
        let first = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 50))
        let second = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 50))
        let opener = FakeSerialPortOpener(portsToReturn: [first, second])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 30)
        let log = record(session, nil)

        session.connect(portPath: "/dev/cu.a", baudRate: .baud9600)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.a", baudRate: .baud9600) }
        session.disconnect()
        waitUntil { log.count == 1 }

        session.connect(portPath: "/dev/cu.b", baudRate: .baud38400)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.b", baudRate: .baud38400) }
        XCTAssertTrue(session.isPortHeld, "Die neue Verbindung hält wieder")
        session.disconnect()
        waitUntil { log.count == 2 }

        XCTAssertEqual(log.releases.map(\.portPath), ["/dev/cu.a", "/dev/cu.b"])
        XCTAssertEqual(log.releases.map(\.baudRate), [.baud9600, .baud38400])
        XCTAssertEqual(first.closeCallCount, 1)
        XCTAssertEqual(second.closeCallCount, 1)
    }
}
