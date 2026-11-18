import XCTest
@testable import SickPLSMacTransport
import SickPLSCore

final class SickPLSSerialConnectionTests: XCTestCase {

    func testSerialFacadeAndReadOnlyStreamAreBitIdenticalForOneChunkScript() throws {
        let frames = try [
            Frame.build(address: 0x81, payload: [0xB0, 0x01, 0x00, 90, 0]),
            Frame.build(address: 0x81, payload: [0xB0, 0x01, 0x00, 91, 0]),
            Frame.build(address: 0x81, payload: [0xB0, 0x01, 0x00, 92, 0])
        ]
        var corrupted = frames[1].encoded()
        corrupted[corrupted.count - 1] ^= 0xFF
        let bytes = [0x55, 0xAA, 0x13, 0x7F, 0x00] + frames[0].encoded() + corrupted + frames[2].encoded()
        let chunks = stride(from: 0, to: bytes.count, by: 7).map { start in
            Array(bytes[start..<min(start + 7, bytes.count)])
        }
        let script = chunks.map(SerialPortReadOutcome.bytes) + [.closed]

        let serialFD = FakeSerialPortFileDescriptor(script: script)
        let serial = try SickPLSSerialConnection.open(
            portPath: "/dev/cu.bit-identical", baudRate: .baud38400,
            opener: FakeSerialPortOpener(fileDescriptor: serialFD)
        )
        let directFD = FakeSerialPortFileDescriptor(script: script)
        let direct = ReadOnlyFrameStream(descriptor: directFD)

        var serialResults: [FrameReadResult] = []
        var directResults: [FrameReadResult] = []
        repeat {
            serialResults.append(serial.readNext())
            directResults.append(direct.readNext())
        } while !serialResults.last!.reachedEndOfStream

        XCTAssertEqual(serialResults, directResults)
        XCTAssertEqual(serialResults.flatMap(\.frames), [frames[0], frames[2]])
        XCTAssertEqual(serialResults.last?.diagnostics, directResults.last?.diagnostics)
        XCTAssertEqual(serialResults.last?.reachedEndOfStream, true)
    }

    func testOpenPassesExplicitPortPathToOpenerWithoutAutoScan() throws {
        let fakeFileDescriptor = FakeSerialPortFileDescriptor(script: [])
        let opener = FakeSerialPortOpener(fileDescriptor: fakeFileDescriptor)

        _ = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        XCTAssertEqual(opener.requestedPaths, ["/dev/cu.usbserial-A1"], "kein Auto-Scan: genau der übergebene Pfad wird angefragt")
    }

    func testOpenPropagatesOpenerError() {
        let opener = FakeSerialPortOpener(fileDescriptor: FakeSerialPortFileDescriptor(script: []))
        opener.errorToThrow = SerialPortOpenError.openFailed(errno: 2) // ENOENT

        XCTAssertThrowsError(
            try SickPLSSerialConnection.open(portPath: "/dev/cu.does-not-exist", baudRate: .baud9600, opener: opener)
        ) { error in
            XCTAssertEqual(error as? SerialPortOpenError, .openFailed(errno: 2))
        }
    }

    // MARK: - N6: öffentlicher Öffnungspfad auf /dev/cu.* begrenzt

    func testOpenRejectsPathOutsideDevCuWithoutCallingOpener() {
        let opener = FakeSerialPortOpener(fileDescriptor: FakeSerialPortFileDescriptor(script: []))

        XCTAssertThrowsError(
            try SickPLSSerialConnection.open(portPath: "/dev/tty.usbserial-A1", baudRate: .baud9600, opener: opener)
        ) { error in
            XCTAssertEqual(error as? SerialPortOpenError, .pathNotAllowed("/dev/tty.usbserial-A1"))
        }
        XCTAssertTrue(opener.requestedPaths.isEmpty, "ein unzulässiger Pfad darf den Opener nie erreichen")
    }

    func testOpenRejectsArbitraryNonDevicePath() {
        let opener = FakeSerialPortOpener(fileDescriptor: FakeSerialPortFileDescriptor(script: []))

        XCTAssertThrowsError(
            try SickPLSSerialConnection.open(portPath: "/etc/passwd", baudRate: .baud9600, opener: opener)
        ) { error in
            XCTAssertEqual(error as? SerialPortOpenError, .pathNotAllowed("/etc/passwd"))
        }
    }

    func testOpenAcceptsDevCuPrefixedPath() throws {
        let fakeFileDescriptor = FakeSerialPortFileDescriptor(script: [])
        let opener = FakeSerialPortOpener(fileDescriptor: fakeFileDescriptor)

        _ = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        XCTAssertEqual(opener.requestedPaths, ["/dev/cu.usbserial-A1"])
    }

    // MARK: - SICK-010-Scope-Änderung: kein Auto-Baud, explizite Baudrate

    func testOpenPassesExplicitBaudRateToOpenerWithoutGuessing() throws {
        let opener = FakeSerialPortOpener(fileDescriptor: FakeSerialPortFileDescriptor(script: []))

        _ = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        XCTAssertEqual(opener.requestedBaudRates, [.baud9600])
    }

    func testOpenAcceptsHistoricalBaudRateAsWell() throws {
        let opener = FakeSerialPortOpener(fileDescriptor: FakeSerialPortFileDescriptor(script: []))

        _ = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud38400, opener: opener)

        XCTAssertEqual(opener.requestedBaudRates, [.baud38400])
    }

    func testConnectionExposesTheBaudRateItWasOpenedWith() throws {
        let opener = FakeSerialPortOpener(fileDescriptor: FakeSerialPortFileDescriptor(script: []))

        let connection = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        XCTAssertEqual(connection.baudRate, .baud9600)
    }

    func testReadNextFeedsBytesIntoParserAndDeliversFrames() throws {
        let frame = try Frame.build(address: 0x81, payload: [0x31])
        let fakeFileDescriptor = FakeSerialPortFileDescriptor(script: [.bytes(frame.encoded())])
        let opener = FakeSerialPortOpener(fileDescriptor: fakeFileDescriptor)
        let connection = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        let result = connection.readNext()

        XCTAssertEqual(result.frames, [frame])
        XCTAssertFalse(result.reachedEndOfStream)
        XCTAssertEqual(result.diagnostics.validFrames, 1)
    }

    func testTimeoutDoesNotTriggerFinishOrDiscardBufferedBytes() throws {
        // SICK-008/SICK-009-Kontrakt: ein Lesetimeout ist kein Stromende --
        // ein am Timeout-Zeitpunkt unvollständiger Frame muss nach dem
        // nächsten erfolgreichen Read trotzdem vollständig ankommen.
        let frame = try Frame.build(address: 0x81, payload: [0x01, 0x02, 0x03, 0x04, 0x05])
        let bytes = frame.encoded()
        let firstChunk = Array(bytes[0..<3])
        let secondChunk = Array(bytes[3...])

        let fakeFileDescriptor = FakeSerialPortFileDescriptor(script: [
            .bytes(firstChunk),
            .timeout,
            .bytes(secondChunk),
        ])
        let opener = FakeSerialPortOpener(fileDescriptor: fakeFileDescriptor)
        let connection = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        let afterFirstChunk = connection.readNext()
        XCTAssertEqual(afterFirstChunk.frames, [])
        XCTAssertFalse(afterFirstChunk.reachedEndOfStream)

        let afterTimeout = connection.readNext()
        XCTAssertEqual(afterTimeout.frames, [])
        XCTAssertFalse(afterTimeout.reachedEndOfStream)
        XCTAssertEqual(afterTimeout.diagnostics.discardedCandidatesAtFinish, 0, "ein Timeout darf finish() nicht auslösen")

        let afterSecondChunk = connection.readNext()
        XCTAssertEqual(afterSecondChunk.frames, [frame], "der am Timeout unvollständige Frame muss trotzdem ankommen")
        XCTAssertFalse(afterSecondChunk.reachedEndOfStream)
    }

    func testClosedOutcomeFlushesRemainingBufferExactlyOnceViaFinish() throws {
        // review-sick-004.md-Arbeitsbeispiel, hier über den Transport statt
        // direkt am StreamParser: ein STX, das sich erst am Stromende als
        // Rauschen herausstellt, gefolgt vom eigentlichen Frame.
        let stream: [UInt8] = [0x02, 0x02, 0x81, 0x00, 0x00, 0x11, 0x88]
        let fakeFileDescriptor = FakeSerialPortFileDescriptor(script: [.bytes(stream), .closed])
        let opener = FakeSerialPortOpener(fileDescriptor: fakeFileDescriptor)
        let connection = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        let afterBytes = connection.readNext()
        XCTAssertEqual(afterBytes.frames, [])
        XCTAssertFalse(afterBytes.reachedEndOfStream)

        let afterClosed = connection.readNext()
        let expectedFrame = try Frame.build(address: 0x81, payload: [])
        XCTAssertEqual(afterClosed.frames, [expectedFrame])
        XCTAssertTrue(afterClosed.reachedEndOfStream)
        XCTAssertEqual(afterClosed.diagnostics.discardedCandidatesAtFinish, 1)
        XCTAssertEqual(afterClosed.diagnostics.validFrames, 1)
    }

    func testReadNextAfterEndOfStreamReturnsClosedWithoutTouchingFileDescriptorAgain() throws {
        let fakeFileDescriptor = FakeSerialPortFileDescriptor(script: [.closed])
        let opener = FakeSerialPortOpener(fileDescriptor: fakeFileDescriptor)
        let connection = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        let first = connection.readNext()
        XCTAssertTrue(first.reachedEndOfStream)
        XCTAssertEqual(fakeFileDescriptor.readCallCount, 1)

        let second = connection.readNext()
        XCTAssertTrue(second.reachedEndOfStream)
        XCTAssertEqual(second.frames, [])
        XCTAssertEqual(fakeFileDescriptor.readCallCount, 1, "nach Stromende darf der Deskriptor nicht erneut gelesen werden")
    }

    func testExplicitCloseCallsUnderlyingCloseAndFinishesParserExactlyOnce() throws {
        let fakeFileDescriptor = FakeSerialPortFileDescriptor(script: [.bytes([0x02, 0x81, 0x00])]) // unvollständiger Header
        let opener = FakeSerialPortOpener(fileDescriptor: fakeFileDescriptor)
        let connection = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        _ = connection.readNext()
        let closeResult = connection.close()

        XCTAssertTrue(closeResult.reachedEndOfStream)
        XCTAssertEqual(closeResult.diagnostics.discardedCandidatesAtFinish, 1)
        XCTAssertEqual(fakeFileDescriptor.closeCallCount, 1)

        let secondClose = connection.close()
        XCTAssertEqual(fakeFileDescriptor.closeCallCount, 1, "close() ist idempotent -- der Deskriptor wird nicht zweimal geschlossen")
        XCTAssertEqual(secondClose.frames, [])
    }

    /// **SICK-030a:** Auch nach einem *vom Gerät* ausgelösten Stromende
    /// schließt ``SickPLSSerialConnection/close()`` den Deskriptor —
    /// und genau einmal.
    ///
    /// Vorher sprang `close()` in diesem Fall vorzeitig heraus, weil ein
    /// einziges Flag „Strom zu Ende" und „Deskriptor zu" zusammenfasste.
    /// Dass die reale `DarwinSerialPortFileDescriptor` sich bei EOF von
    /// selbst schließt, ist **ihre** Eigenschaft und keine Zusage des
    /// Protokolls — auf der Annahme stünde sonst die Portübergabe des
    /// Monitors.
    func testCloseAfterADeviceSideEndOfStreamStillClosesTheDescriptor() throws {
        let fakeFileDescriptor = FakeSerialPortFileDescriptor(script: [.closed])
        let opener = FakeSerialPortOpener(fileDescriptor: fakeFileDescriptor)
        let connection = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        XCTAssertTrue(connection.readNext().reachedEndOfStream)
        XCTAssertEqual(fakeFileDescriptor.closeCallCount, 0, "Das Gerät hat beendet -- geschlossen hat noch niemand")

        let closeResult = connection.close()

        XCTAssertEqual(fakeFileDescriptor.closeCallCount, 1)
        XCTAssertTrue(closeResult.reachedEndOfStream)
        XCTAssertEqual(closeResult.frames, [], "Der Restpuffer wurde schon beim Stromende geflusht")

        connection.close()
        XCTAssertEqual(fakeFileDescriptor.closeCallCount, 1, "und weiterhin nur genau einmal")
    }

    func testReadNextPassesTimeoutThrough() throws {
        let fakeFileDescriptor = FakeSerialPortFileDescriptor(script: [.timeout])
        let opener = FakeSerialPortOpener(fileDescriptor: fakeFileDescriptor)
        let connection = try SickPLSSerialConnection.open(portPath: "/dev/cu.usbserial-A1", baudRate: .baud9600, opener: opener)

        _ = connection.readNext(timeoutMilliseconds: 250)

        XCTAssertEqual(fakeFileDescriptor.requestedTimeouts, [250])
    }
}
