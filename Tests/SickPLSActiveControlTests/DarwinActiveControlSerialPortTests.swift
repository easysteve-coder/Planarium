import XCTest
import Darwin
@testable import SickPLSActiveControl

final class DarwinActiveControlSerialPortTests: XCTestCase {

    private func ready(_ revents: Int32) -> RawDuplexPollResult {
        RawDuplexPollResult(returnValue: 1, revents: Int16(revents), capturedErrno: 0)
    }

    private func pollError(_ errorCode: Int32) -> RawDuplexPollResult {
        RawDuplexPollResult(returnValue: -1, revents: 0, capturedErrno: errorCode)
    }

    // MARK: - openFlags: O_RDWR ist hier die bewusste, korrekte Wahl

    func testOpenFlagsAreReadWriteForThisTxCapableLibrary() {
        let flags = DarwinActiveControlSerialPortOpener.openFlags
        XCTAssertEqual(flags & O_ACCMODE, O_RDWR)
        XCTAssertEqual(flags & O_NOCTTY, O_NOCTTY)
        XCTAssertEqual(flags & O_NONBLOCK, O_NONBLOCK)
    }

    // MARK: - write

    func testWriteSendsExactBytesInOneCallWhenFullyAccepted() throws {
        let syscalls = FakeRawDuplexSyscalls(writeScript: [RawDuplexWriteResult(bytesWritten: 3, capturedErrno: 0)])
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        try port.write([0x01, 0x02, 0x03])

        XCTAssertEqual(syscalls.writeCallCount, 1)
        XCTAssertEqual(syscalls.writtenChunks, [[0x01, 0x02, 0x03]])
    }

    func testWriteLoopsUntilAllBytesAreAcceptedOnPartialWrite() throws {
        let syscalls = FakeRawDuplexSyscalls(writeScript: [
            RawDuplexWriteResult(bytesWritten: 2, capturedErrno: 0),
            RawDuplexWriteResult(bytesWritten: 1, capturedErrno: 0),
        ])
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        try port.write([0x01, 0x02, 0x03])

        XCTAssertEqual(syscalls.writeCallCount, 2)
        XCTAssertEqual(syscalls.writtenChunks, [[0x01, 0x02, 0x03], [0x03]])
    }

    func test500KWriteUsesTheConfirmedPerBytePacingPath() throws {
        let syscalls = FakeRawDuplexSyscalls()
        let port = DarwinActiveControlSerialPort(
            fileDescriptor: 999, baudRate: .baud500000, syscalls: syscalls
        )

        try port.write([0x02, 0x00, 0x20])

        XCTAssertEqual(syscalls.writtenChunks, [[0x02], [0x00], [0x20]])
    }

    func testWriteThrowsOnNegativeResult() {
        let syscalls = FakeRawDuplexSyscalls(writeScript: [RawDuplexWriteResult(bytesWritten: -1, capturedErrno: EIO)])
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertThrowsError(try port.write([0x01])) { error in
            XCTAssertEqual(error as? ActiveControlWriteError, .writeFailed(errno: EIO))
        }
    }

    func testWriteThrowsDefensivelyOnZeroByteResultForNonEmptyInput() {
        // POSIX sieht 0 für einen nicht-leeren Schreibversuch nicht vor --
        // defensiv als Fehler behandeln statt endlos zu schleifen.
        let syscalls = FakeRawDuplexSyscalls(writeScript: [RawDuplexWriteResult(bytesWritten: 0, capturedErrno: 0)])
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertThrowsError(try port.write([0x01]))
    }

    func testWriteAfterCloseThrowsWithoutTouchingSyscalls() {
        let syscalls = FakeRawDuplexSyscalls()
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        port.close()

        XCTAssertThrowsError(try port.write([0x01])) { error in
            XCTAssertEqual(error as? ActiveControlWriteError, .writeFailed(errno: EBADF))
        }
        XCTAssertEqual(syscalls.writeCallCount, 0)
    }

    // MARK: - read: dieselbe Poll-dann-Read-/errno-Logik wie SickPLSMacTransport (SICK-010)

    func testPollInWithConcurrentHangupReadsBytesInsteadOfClosingImmediately() {
        let syscalls = FakeRawDuplexSyscalls(
            pollScript: [ready(POLLIN | POLLHUP)],
            readScript: [.bytes([0x02, 0x81, 0x00, 0x02, 0xB1, 0x00, 0x11, 0x88])]
        )
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        let outcome = port.read(timeoutMilliseconds: 100)

        XCTAssertEqual(outcome, .bytes([0x02, 0x81, 0x00, 0x02, 0xB1, 0x00, 0x11, 0x88]))
        XCTAssertEqual(syscalls.readCallCount, 1)
    }

    func testHangupWithoutPollInClosesWithoutAttemptingRead() {
        let syscalls = FakeRawDuplexSyscalls(pollScript: [ready(POLLHUP)])
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(port.read(timeoutMilliseconds: 100), .closed)
        XCTAssertEqual(syscalls.readCallCount, 0)
    }

    func testPollNVALIsClassifiedAsClosed() {
        let syscalls = FakeRawDuplexSyscalls(pollScript: [ready(POLLNVAL)])
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(port.read(timeoutMilliseconds: 100), .closed)
    }

    func testPollErrorEINTRIsClassifiedAsTimeout() {
        let syscalls = FakeRawDuplexSyscalls(pollScript: [pollError(EINTR)])
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(port.read(timeoutMilliseconds: 100), .timeout)
    }

    func testPollErrorEBADFIsClassifiedAsClosed() {
        let syscalls = FakeRawDuplexSyscalls(pollScript: [pollError(EBADF)])
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(port.read(timeoutMilliseconds: 100), .closed)
    }

    func testPollTimeoutRemainsTimeout() {
        let syscalls = FakeRawDuplexSyscalls(pollScript: [RawDuplexPollResult(returnValue: 0, revents: 0, capturedErrno: 0)])
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(port.read(timeoutMilliseconds: 100), .timeout)
    }

    // MARK: - Sicherheitsnetz

    func testDeinitClosesUnderlyingSyscallWithoutExplicitClose() {
        let syscalls = FakeRawDuplexSyscalls()

        do {
            _ = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)
        }

        XCTAssertEqual(syscalls.closeCallCount, 1)
    }

    func testCloseIsIdempotent() {
        let syscalls = FakeRawDuplexSyscalls()
        let port = DarwinActiveControlSerialPort(fileDescriptor: 999, syscalls: syscalls)

        port.close()
        port.close()

        XCTAssertEqual(syscalls.closeCallCount, 1)
    }
}
