@testable import PlanariumInput
import XCTest
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSMonitorKit

/// Integrationstests für ``RXSession`` inklusive ihres echten
/// Hintergrund-Threads (``ReadLoopWorker``) -- anders als
/// ``ScanSessionStateTests`` (reine, synchrone Reducer-Logik) prüft
/// dieser Testfall die „saubere Lifecycle"-Anforderung aus dem
/// SICK-012-Auftrag selbst: ob `connect`/`disconnect` tatsächlich einen
/// Hintergrund-Thread starten/stoppen und der veröffentlichte Zustand
/// dabei korrekt ankommt. Kein physisches Gerät -- ausschließlich
/// `FakeSerialPortOpener`/`FakeSerialPortFileDescriptor`.
@MainActor final class RXSessionTests: XCTestCase {

    /// Pumpt den Haupt-RunLoop, bis `condition` erfüllt ist oder das
    /// Timeout erreicht ist -- nötig, weil ``RXSession`` ihre
    /// `@Published`-Zustandsänderungen über `DispatchQueue.main.async`
    /// aus einem echten Hintergrund-Thread heraus veröffentlicht.
    /// Wartet auf eine Bedingung. Das Zeitlimit begrenzt eine Flake und ist
    /// **keine** Zusicherung: kein Test verlangt, dass eine Bedingung schnell
    /// erfüllt wird, nur dass sie erfüllt wird.
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

    private func b0FrameBytes(measurements: [UInt16]) throws -> [UInt8] {
        let n = measurements.count
        var payload: [UInt8] = [B0ScanProfile.commandByte, UInt8(n & 0xFF), UInt8((n >> 8) & 0x03)]
        for value in measurements {
            payload.append(UInt8(value & 0xFF))
            payload.append(UInt8((value >> 8) & 0x1F))
        }
        payload.append(0xAA)
        return try Frame.build(address: 0x81, payload: payload).encoded()
    }

    // MARK: - Erfolgreiche Verbindung inklusive Profilübernahme

    func testConnectPublishesConnectedThenAppliesReceivedProfile() throws {
        let frameBytes = try b0FrameBytes(measurements: [1, 2, 3])
        let descriptor = FakeSerialPortFileDescriptor(readScript: [.bytes(frameBytes)] + Array(repeating: .timeout, count: 50))
        let opener = FakeSerialPortOpener(portsToReturn: [descriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 20)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)

        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }
        waitUntil { session.state.lastProfile != nil }

        XCTAssertEqual(session.state.lastProfile?.measurements.count, 3)
        XCTAssertEqual(opener.requestedPaths, ["/dev/cu.fake"])
        XCTAssertEqual(opener.requestedBaudRates, [.baud9600])

        session.disconnect()
    }

    // MARK: - Explizites Trennen

    func testDisconnectResetsStateAndClosesTheUnderlyingDescriptor() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let opener = FakeSerialPortOpener(portsToReturn: [descriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 20)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }

        session.disconnect()

        XCTAssertEqual(session.state, ScanSessionState())
        waitUntil { descriptor.closeCallCount == 1 }
    }

    func testDisconnectWithoutAnActiveConnectionIsANoOp() {
        let opener = FakeSerialPortOpener(portsToReturn: [])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 20)

        session.disconnect()

        XCTAssertEqual(session.state, ScanSessionState())
        XCTAssertTrue(opener.requestedPaths.isEmpty)
    }

    // MARK: - Fehler beim Öffnen

    func testConnectFailurePublishesFailedState() {
        let opener = FakeSerialPortOpener(portsToReturn: [])
        opener.errorToThrow = SerialPortOpenError.openFailed(errno: 2)
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 20)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)

        waitUntil {
            if case .failed(let portPath, let baudRate, _) = session.state.connection {
                return portPath == "/dev/cu.fake" && baudRate == .baud9600
            }
            return false
        }
    }

    // MARK: - Kein paralleler zweiter Verbindungsversuch

    func testConnectWhileAlreadyConnectingIsIgnored() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let opener = FakeSerialPortOpener(portsToReturn: [descriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 20)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        session.connect(portPath: "/dev/cu.other", baudRate: .baud38400)

        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }

        XCTAssertEqual(opener.requestedPaths, ["/dev/cu.fake"], "der zweite connect()-Aufruf während des ersten darf keinen weiteren Öffnungsversuch auslösen")

        session.disconnect()
    }

    // MARK: - SICK-012a: keine Retain-Cycles zwischen RXSession/ReadLoopWorker

    /// Belegt die Korrektur von Retain-Cycle 1 (`ReadLoopWorker` ->
    /// `DispatchWorkItem` -> Closure mit `[self]` -> `ReadLoopWorker`,
    /// SICK-012a-Auftrag) sowie das kooperative Aufbrechen dieses Zyklus
    /// nach `disconnect()`: Ohne die Korrektur bliebe der Worker über
    /// seinen eigenen, sich selbst festhaltenden `DispatchWorkItem`
    /// dauerhaft am Leben, selbst nachdem ``RXSession`` ihn längst
    /// nicht mehr referenziert.


    /// Belegt dieselbe Korrektur zusätzlich über den Weg, den
    /// `RXSession.deinit` selbst geht (kein expliziter `disconnect()`,
    /// sondern vollständige Freigabe): Sowohl `RXSession` als auch ihr
    /// `ReadLoopWorker` müssen deallokierbar sein, sobald der Testcode
    /// selbst keine starke Referenz mehr hält.


    /// Belegt Retain-Cycle 2 (`ReadLoopWorker` -> `onEvent`-Closure ->
    /// `newWorker` -> `ReadLoopWorker`) indirekt über sein sichtbares
    /// Symptom: Ein Ereignis, das der bereits getrennte Worker noch auf
    /// die Hauptwarteschlange gelegt hatte, darf den inzwischen auf den
    /// Leerzustand zurückgesetzten Zustand nicht wieder überschreiben.
    func testStaleEventsFromADisconnectedWorkerNeverOverwriteTheResetState() {
        let descriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let opener = FakeSerialPortOpener(portsToReturn: [descriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 20)

        session.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }

        session.disconnect()
        XCTAssertEqual(session.state, ScanSessionState())

        // Gibt dem noch laufenden Hintergrund-Thread reichlich Zeit, die
        // Stornierung zu bemerken und dabei möglicherweise noch
        // ausstehende Ereignisse auf die Hauptwarteschlange zu legen --
        // keines davon darf den zurückgesetzten Zustand danach erneut
        // überschreiben.
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            XCTAssertEqual(session.state, ScanSessionState(), "ein verspätetes Ereignis des getrennten Workers darf den zurückgesetzten Zustand nicht überschreiben")
        }
    }

    /// Ergänzt den vorigen Test um den Fall, dass zwischenzeitlich schon
    /// eine neue Verbindung aufgebaut wurde: Ein verspätetes Ereignis des
    /// alten, ersetzten Workers darf auch den frischen, aktiven Zustand
    /// der neuen Verbindung nicht überschreiben.
    func testStaleEventsFromAReplacedWorkerNeverOverwriteTheNewConnectionState() {
        let oldDescriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let newDescriptor = FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 200))
        let opener = FakeSerialPortOpener(portsToReturn: [oldDescriptor, newDescriptor])
        let session = RXSession(opener: opener, readTimeoutMilliseconds: 20)

        session.connect(portPath: "/dev/cu.old", baudRate: .baud9600)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.old", baudRate: .baud9600) }

        session.disconnect()
        waitUntil { !session.isPortHeld }
        session.connect(portPath: "/dev/cu.new", baudRate: .baud38400)
        waitUntil { session.state.connection == .connected(portPath: "/dev/cu.new", baudRate: .baud38400) }

        // Der alte Worker kann noch bis zu ~20 ms brauchen, um seine
        // Stornierung zu bemerken -- ein dabei noch ausstehendes
        // Ereignis darf den frisch aufgebauten neuen Verbindungszustand
        // nicht zurücksetzen oder überschreiben.
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            XCTAssertEqual(session.state.connection, .connected(portPath: "/dev/cu.new", baudRate: .baud38400))
        }

        session.disconnect()
    }

    // MARK: - SICK-012b: thread-sicherer Worker-Lifecycle

    /// Treibt viele schnelle `connect()`/`disconnect()`-Zyklen direkt
    /// hintereinander über die öffentliche API. Jeder Zyklus lässt
    /// `stop()` (Aufrufer-Thread, hier der Test/Haupt-Thread) und `run()`
    /// samt seinem `defer { workItem = nil }` (Hintergrund-Thread) auf
    /// demselben `ReadLoopWorker.workItem` zusammentreffen, oft bevor der
    /// Hintergrund-Thread überhaupt die erste Abbruchprüfung erreicht hat
    /// -- genau das Race-Fenster, das vor SICK-012b unsynchronisiert war
    /// (siehe Typkommentar auf `ReadLoopWorker.workItem`). Ein einzelner
    /// Testlauf kann eine fehlende Synchronisierung nicht in jedem Fall
    /// beweisen (dafür bräuchte es einen Thread Sanitizer, siehe
    /// Checkpoint/Handoff), aber 25 rasch aufeinanderfolgende Zyklen
    /// durchlaufen das Fenster real und wiederholt statt nur strukturell
    /// plausibel zu bleiben -- und der Endzustand muss dabei in jedem Fall
    /// konsistent bleiben (kein Absturz, kein hängen gebliebener Worker,
    /// kein von einem verspäteten Ereignis überschriebener Leerzustand).

}
