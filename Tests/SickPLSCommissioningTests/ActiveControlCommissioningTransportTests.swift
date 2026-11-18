import XCTest
import SickPLSActiveControl
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSCommissioning

/// Die reale ``CommissioningTransport``-Umsetzung (SICK-031) — **gegen
/// einen Spion, nie gegen einen echten Port**.
///
/// Kein Gerät, keine PTY-Probe, kein Byte an Hardware.
final class ActiveControlCommissioningTransportTests: XCTestCase {

    private var opener: SpyActiveControlSerialPortOpener!

    override func setUp() {
        super.setUp()
        opener = SpyActiveControlSerialPortOpener()
    }

    private func makeTransport(path: String = "/dev/cu.usbserial-TEST") throws
        -> ActiveControlCommissioningTransport {
        try ActiveControlCommissioningTransport(portPath: path, opener: opener)
    }

    // MARK: - Pfadgrenze

    /// Die `/dev/cu.`-Grenze steht **im Initialisierer** — ein
    /// unzulässiger Pfad gelangt gar nicht erst in einen Lauf.
    func testAPathOutsideCalloutDevicesIsRefusedBeforeAnythingHappens() {
        XCTAssertThrowsError(
            try ActiveControlCommissioningTransport(portPath: "/dev/tty.usbserial-TEST", opener: opener)
        ) { error in
            XCTAssertEqual(error as? CommissioningTransportError, .pathNotAllowed("/dev/tty.usbserial-TEST"))
        }
        XCTAssertTrue(opener.openedPaths.isEmpty, "Der Opener wurde nie erreicht")
    }

    /// **Das Erzeugen öffnet nichts.**
    func testCreatingTheTransportOpensNothing() throws {
        _ = try makeTransport()
        XCTAssertTrue(opener.openedPaths.isEmpty)
        XCTAssertTrue(opener.openedRates.isEmpty)
    }

    // MARK: - Öffnen und Schließen

    func testOpeningPassesThroughExactlyThePathAndRate() throws {
        let transport = try makeTransport()

        try transport.openPort(baudRate: .baud38400)

        XCTAssertEqual(opener.openedPaths, ["/dev/cu.usbserial-TEST"])
        XCTAssertEqual(opener.openedRates, [.baud38400])
        XCTAssertTrue(transport.isPortOpen)
    }

    /// **Der Nachweis für den Ratenwechsel der Diagnose:** Ein zweites
    /// Öffnen ohne vorheriges Schließen wird abgelehnt — sonst spräche
    /// die zweite Probe womöglich noch über die alte Verbindung.
    func testASecondOpenWithoutAPrecedingCloseIsRefused() throws {
        let transport = try makeTransport()
        try transport.openPort(baudRate: .baud9600)

        XCTAssertThrowsError(try transport.openPort(baudRate: .baud38400)) { error in
            XCTAssertEqual(error as? CommissioningTransportError, .portAlreadyOpen)
        }
        XCTAssertEqual(opener.openedRates, [.baud9600], "Es kam keine zweite Verbindung zustande")
    }

    /// Und nach einem echten Schließen geht es bei der anderen Rate
    /// weiter.
    func testAfterARealCloseTheOtherRateCanBeOpened() throws {
        let transport = try makeTransport()
        try transport.openPort(baudRate: .baud9600)
        let first = opener.lastPort

        try transport.closePort()
        XCTAssertFalse(transport.isPortOpen)
        XCTAssertEqual(first?.closeCount, 1)

        try transport.openPort(baudRate: .baud38400)
        XCTAssertEqual(opener.openedRates, [.baud9600, .baud38400])
        XCTAssertNotIdentical(opener.lastPort, first, "Eine wirklich neue Verbindung")
    }

    /// **Schließen ist idempotent** und wirft nie, wenn nichts offen ist.
    func testClosingIsIdempotentAndNeverThrowsWithoutAnOpenPort() throws {
        let transport = try makeTransport()

        XCTAssertNoThrow(try transport.closePort())

        try transport.openPort(baudRate: .baud9600)
        let port = opener.lastPort
        XCTAssertNoThrow(try transport.closePort())
        XCTAssertNoThrow(try transport.closePort())
        XCTAssertEqual(port?.closeCount, 1, "Der darunterliegende Port wird genau einmal geschlossen")
    }

    func testAFailedOpenIsWrappedWithItsPosixCode() throws {
        opener.openError = SerialPortOpenError.openFailed(errno: 16)
        let transport = try makeTransport()

        XCTAssertThrowsError(try transport.openPort(baudRate: .baud9600)) { error in
            XCTAssertEqual(error as? CommissioningTransportError, .openFailed("open(2) errno 16"))
        }
        XCTAssertFalse(transport.isPortOpen)
    }

    // MARK: - Schreiben und Lesen

    func testWritingWithoutAnOpenPortIsARefusalAndNotASilentNoOp() throws {
        let transport = try makeTransport()

        XCTAssertThrowsError(try transport.write([0x01, 0x02])) { error in
            XCTAssertEqual(error as? CommissioningTransportError, .portNotOpen)
        }
    }

    func testWritingReachesThePortUnchanged() throws {
        let transport = try makeTransport()
        try transport.openPort(baudRate: .baud9600)
        let frame = CommissioningTelegram.identityRequest(address: .universal)

        try transport.write(frame.encoded())

        XCTAssertEqual(opener.lastPort?.writtenPayloads, [frame.encoded()])
    }

    func testAFailedWriteIsWrappedWithItsPosixCode() throws {
        let transport = try makeTransport()
        try transport.openPort(baudRate: .baud9600)
        opener.lastPort?.writeError = ActiveControlWriteError.writeFailed(errno: 5)

        XCTAssertThrowsError(try transport.write([0x01])) { error in
            XCTAssertEqual(error as? CommissioningTransportError, .writeFailed("write(2) errno 5"))
        }
    }

    func testReadingWithoutAnOpenPortReportsAClosedStreamAndNeverCrashes() throws {
        let transport = try makeTransport()
        XCTAssertEqual(transport.read(timeoutMilliseconds: 10), .closed)
    }

    // MARK: - Empfangspuffer leeren

    /// **Leeren wartet nicht**: Es räumt ab, was schon dasteht, mit
    /// Timeout `0` — und hört auf, sobald nichts mehr kommt.
    func testFlushingDrainsWhatIsAlreadyThereWithoutWaiting() throws {
        let transport = try makeTransport()
        opener.nextReadScript = [.bytes([0x01, 0x02]), .bytes([0x03]), .timeout]
        try transport.openPort(baudRate: .baud9600)

        transport.flushReceiveBuffer()

        XCTAssertEqual(opener.lastPort?.readTimeouts, [0, 0, 0], "Nie gewartet")
        XCTAssertTrue(opener.lastPort?.readScript.isEmpty ?? false)
    }

    /// **Ein Dauerstrom hält das Leeren nicht auf.** Ohne Obergrenze
    /// liefe es endlos, und zwar ausgerechnet vor dem Senden.
    func testFlushingIsBoundedEvenAgainstAnEndlessStream() throws {
        let transport = try makeTransport()
        opener.nextReadScript = Array(
            repeating: .bytes([0xAA]),
            count: ActiveControlCommissioningTransport.flushAttemptLimit * 3
        )
        try transport.openPort(baudRate: .baud9600)

        transport.flushReceiveBuffer()

        XCTAssertEqual(
            opener.lastPort?.readTimeouts.count,
            ActiveControlCommissioningTransport.flushAttemptLimit
        )
    }

    /// Ohne offenen Port ist Leeren folgenlos.
    func testFlushingWithoutAnOpenPortDoesNothing() throws {
        let transport = try makeTransport()
        transport.flushReceiveBuffer()
        XCTAssertNil(opener.lastPort)
    }

    // MARK: - Zusammenspiel mit dem Executor

    /// Der Executor über dem **echten** Adapter: die Diagnosefolge
    /// wechselt die Rate mit einem wirklichen Schließen dazwischen —
    /// weiterhin ohne Gerät.
    func testTheExecutorDrivesTheRealAdapterThroughTheDiagnosticsSequence() throws {
        let clock = TestMonotonicClock()
        opener.clock = clock
        let transport = try makeTransport()
        let executor = CommissioningExecutor(transport: transport, clock: clock)

        // Die Ausgangsprüfung läuft in die Frist (der Spion schweigt) --
        // der Zustand, aus dem die Ratendiagnose angeboten wird.
        _ = executor.perform(.checkStartingRate)
        let diagnostics = executor.perform(.runRateDiagnostics)

        XCTAssertTrue(diagnostics.isFinal)
        XCTAssertEqual(
            opener.openedRates,
            [.baud9600, .baud9600, .baud38400],
            "Ausgangsprüfung, dann je Probe eine eigene Verbindung"
        )
        XCTAssertFalse(transport.isPortOpen, "Nach dem Ende ist nichts mehr offen")
        XCTAssertNil(diagnostics.verifiedBaudRate, "Nichts geantwortet, nichts belegt")
    }
}
