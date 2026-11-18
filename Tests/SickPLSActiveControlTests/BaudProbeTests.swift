import XCTest
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSActiveControl

final class BaudProbeTests: XCTestCase {

    private func identityResponseFrameBytes(address: UInt8 = 0x81) throws -> [UInt8] {
        try Frame.build(address: address, payload: [0xB1, 0x00, 0x01]).encoded()
    }

    private func b0BroadcastFrameBytes() throws -> [UInt8] {
        try Frame.build(address: 0x81, payload: [0xB0, 0x00, 0x00]).encoded()
    }

    // MARK: - N6-Äquivalent: Pfadgrenze /dev/cu.*

    func testRunRejectsPathOutsideDevCuWithoutCallingOpener() {
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [])

        XCTAssertThrowsError(
            try BaudProbe.run(portPath: "/dev/tty.usbserial-A1", targetAddress: .universal, opener: opener)
        ) { error in
            XCTAssertEqual(error as? SerialPortOpenError, .pathNotAllowed("/dev/tty.usbserial-A1"))
        }
        XCTAssertTrue(opener.requestedPaths.isEmpty)
    }

    // MARK: - Erfolgsfall

    func testFirstCandidateSucceedsAndStopsWithoutTryingSecondCandidate() throws {
        let port = FakeActiveControlSerialPort(readScript: [.bytes(try identityResponseFrameBytes())])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [port])

        let log = try BaudProbe.run(portPath: "/dev/cu.usbserial-A1", targetAddress: .universal, opener: opener)

        XCTAssertEqual(log.identifiedBaudRate, .baud9600)
        XCTAssertEqual(log.attempts.count, 1)
        XCTAssertEqual(log.attempts[0].outcome, .identified)
        XCTAssertEqual(opener.requestedBaudRates, [.baud9600])
        XCTAssertEqual(port.writeCallCount, 1, "genau ein Probe-Frame je Kandidat")
        XCTAssertEqual(port.closeCallCount, 1)
    }

    func testSecondCandidateSucceedsAfterFirstTimesOut() throws {
        let firstPort = FakeActiveControlSerialPort(readScript: [.timeout])
        let secondPort = FakeActiveControlSerialPort(readScript: [.bytes(try identityResponseFrameBytes())])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [firstPort, secondPort])

        let log = try BaudProbe.run(portPath: "/dev/cu.usbserial-A1", targetAddress: .universal, opener: opener)

        XCTAssertEqual(log.identifiedBaudRate, .baud38400)
        XCTAssertEqual(log.attempts.map(\.outcome), [.timeout, .identified])
        XCTAssertEqual(opener.requestedBaudRates, [.baud9600, .baud38400])
    }

    // MARK: - Kein Erfolg

    func testBothCandidatesTimeOutYieldsNoIdentifiedBaudRate() throws {
        let firstPort = FakeActiveControlSerialPort(readScript: [.timeout])
        let secondPort = FakeActiveControlSerialPort(readScript: [.timeout])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [firstPort, secondPort])

        let log = try BaudProbe.run(portPath: "/dev/cu.usbserial-A1", targetAddress: .universal, opener: opener)

        XCTAssertNil(log.identifiedBaudRate)
        XCTAssertEqual(log.attempts.map(\.outcome), [.timeout, .timeout])
    }

    func testUnexpectedResponseCommandByteIsReportedAndProbingContinues() throws {
        let unexpected = try Frame.build(address: 0x81, payload: [0xA0, 0x02]).encoded()
        let firstPort = FakeActiveControlSerialPort(readScript: [.bytes(unexpected)])
        let secondPort = FakeActiveControlSerialPort(readScript: [.timeout])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [firstPort, secondPort])

        let log = try BaudProbe.run(portPath: "/dev/cu.usbserial-A1", targetAddress: .universal, opener: opener)

        XCTAssertEqual(log.attempts[0].outcome, .unexpectedResponse(commandByte: 0xA0))
        XCTAssertEqual(log.attempts.count, 2, "kein Erfolg -- die Probe versucht trotzdem die zweite Kandidatenrate")
    }

    func testBytesArriveButNeverFormAValidFrameBeforeTimeoutIsAmbiguous() {
        let port = FakeActiveControlSerialPort(readScript: [.bytes([0xFF, 0xFF, 0xFF]), .timeout])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [port, port])
        // zweiter Kandidat bekommt denselben Fake -- Skript ist nach dem
        // ersten Kandidaten leer und liefert .closed, das reicht für den
        // Test dieses einen Verhaltens.

        let log = try! BaudProbe.run(portPath: "/dev/cu.usbserial-A1", targetAddress: .universal, opener: opener)

        XCTAssertEqual(log.attempts[0].outcome, .ambiguous)
    }

    func testClosedWithoutAnyPriorBytesIsTreatedAsTimeoutNotAmbiguous() {
        let port = FakeActiveControlSerialPort(readScript: [.closed])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [port, port])

        let log = try! BaudProbe.run(portPath: "/dev/cu.usbserial-A1", targetAddress: .universal, opener: opener)

        XCTAssertEqual(log.attempts[0].outcome, .timeout)
    }

    // MARK: - B0-Broadcast-Rauschen wird übersprungen, nicht als Antwort gewertet

    func testAmbientB0BroadcastBeforeRealResponseIsSkippedNotReportedAsUnexpected() throws {
        var bytes = try b0BroadcastFrameBytes()
        bytes += try identityResponseFrameBytes()
        let port = FakeActiveControlSerialPort(readScript: [.bytes(bytes)])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [port])

        let log = try BaudProbe.run(portPath: "/dev/cu.usbserial-A1", targetAddress: .universal, opener: opener)

        XCTAssertEqual(log.attempts[0].outcome, .identified)
    }

    // MARK: - write-Fehler bricht den gesamten Lauf ab

    func testWriteFailurePropagatesAndAbortsTheWholeRun() {
        let port = FakeActiveControlSerialPort(readScript: [])
        port.errorToThrowOnWrite = ActiveControlWriteError.writeFailed(errno: EIO)
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [port])

        XCTAssertThrowsError(
            try BaudProbe.run(portPath: "/dev/cu.usbserial-A1", targetAddress: .universal, opener: opener)
        ) { error in
            XCTAssertEqual(error as? ActiveControlWriteError, .writeFailed(errno: EIO))
        }
    }

    // MARK: - Zieladresse wird unverändert durchgereicht

    func testAttemptRecordsTheExplicitTargetAddressUsed() throws {
        let address = ConfirmedTargetAddress(rawValue: 5)!
        let port = FakeActiveControlSerialPort(readScript: [.bytes(try identityResponseFrameBytes())])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [port])

        let log = try BaudProbe.run(portPath: "/dev/cu.usbserial-A1", targetAddress: address, opener: opener)

        XCTAssertEqual(log.attempts[0].targetAddress, 5)
    }

    // MARK: - SICK-011a: harte Gesamtfrist statt je Leseversuch neu beginnendem Timeout

    /// (a) Fortlaufendes Rauschen (hier: autonome B0-Broadcasts) darf die
    /// Gesamtfrist nicht verlängern -- der vierte, gescriptete Leseversuch
    /// (eine gültige Identitätsantwort) darf nie erreicht werden, weil die
    /// Frist vorher abläuft. Deckt zugleich (d): das jeweils
    /// **verbleibende** Timeout, nicht das volle Gesamttimeout, muss an
    /// jeden `read`-Aufruf übergeben werden.
    func testContinuousNoiseUntilDeadlineYieldsBoundedAmbiguousUsingRemainingTimeoutPerRead() throws {
        let b0Bytes = try b0BroadcastFrameBytes()
        let neverReachedIdentityResponse = try identityResponseFrameBytes()
        let port = FakeActiveControlSerialPort(readScript: [
            .bytes(b0Bytes), .bytes(b0Bytes), .bytes(b0Bytes), .bytes(neverReachedIdentityResponse),
        ])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [port])
        // Aufrufreihenfolge in probeOnce: 1x Deadline-Berechnung, dann je
        // Schleifendurchlauf 1x Restfrist-Berechnung.
        let clock = FakeMonotonicClock(scriptedMilliseconds: [0, 10, 50, 60, 150])

        let log = try BaudProbe.run(
            portPath: "/dev/cu.usbserial-A1",
            targetAddress: .universal,
            candidates: [.baud9600],
            timeoutMilliseconds: 100,
            opener: opener,
            clock: clock
        )

        XCTAssertEqual(log.attempts[0].outcome, .ambiguous, "fortlaufendes Rauschen darf die Gesamtfrist nicht verlängern")
        XCTAssertEqual(
            port.readTimeoutsRequested, [90, 50, 40],
            "jeder read-Aufruf muss die verbleibende Restfrist erhalten, nicht erneut das volle Gesamttimeout"
        )
    }

    /// (b) Eine über mehrere Leseaufrufe fragmentiert eintreffende,
    /// CRC-valide B1-Antwort bleibt innerhalb der Gesamtfrist ein Erfolg --
    /// die Frist begrenzt nur die Gesamtwartezeit, nicht das Zusammensetzen
    /// eines Frames über mehrere Reads hinweg.
    func testFragmentedIdentityResponseBeforeDeadlineIsIdentified() throws {
        let fullFrame = try identityResponseFrameBytes()
        let splitIndex = fullFrame.count / 2
        let firstHalf = Array(fullFrame[..<splitIndex])
        let secondHalf = Array(fullFrame[splitIndex...])
        let port = FakeActiveControlSerialPort(readScript: [.bytes(firstHalf), .bytes(secondHalf)])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [port])
        let clock = FakeMonotonicClock(scriptedMilliseconds: [1000, 1100, 1300])

        let log = try BaudProbe.run(
            portPath: "/dev/cu.usbserial-A1",
            targetAddress: .universal,
            candidates: [.baud9600],
            timeoutMilliseconds: 500,
            opener: opener,
            clock: clock
        )

        XCTAssertEqual(log.attempts[0].outcome, .identified)
    }

    /// (c) Treffen innerhalb der Gesamtfrist überhaupt keine Bytes ein --
    /// hier bereits vor dem ersten Leseversuch abgelaufen --, ist das
    /// Ergebnis `.timeout`, und es wird gar nicht erst gelesen.
    func testDeadlineAlreadyExceededBeforeAnyReadYieldsTimeoutWithoutReading() throws {
        let neverReachedIdentityResponse = try identityResponseFrameBytes()
        let port = FakeActiveControlSerialPort(readScript: [.bytes(neverReachedIdentityResponse)])
        let opener = FakeActiveControlSerialPortOpener(portsToReturn: [port])
        let clock = FakeMonotonicClock(scriptedMilliseconds: [1000, 1200])

        let log = try BaudProbe.run(
            portPath: "/dev/cu.usbserial-A1",
            targetAddress: .universal,
            candidates: [.baud9600],
            timeoutMilliseconds: 100,
            opener: opener,
            clock: clock
        )

        XCTAssertEqual(log.attempts[0].outcome, .timeout)
        XCTAssertTrue(port.readTimeoutsRequested.isEmpty, "bei bereits abgelaufener Gesamtfrist darf gar nicht erst gelesen werden")
    }
}
