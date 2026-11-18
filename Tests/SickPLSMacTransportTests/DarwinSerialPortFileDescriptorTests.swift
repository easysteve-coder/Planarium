import XCTest
import Darwin
@testable import SickPLSMacTransport

/// Ein vorab festgelegtes Skript von rohen `poll`/`read`-Ergebnissen --
/// ersetzt die tatsächlichen Syscalls vollständig, damit die exakte
/// Entscheidungslogik in `DarwinSerialPortFileDescriptor` getestet werden
/// kann, ohne einen echten Dateideskriptor oder ein Pseudo-Terminal zu
/// öffnen (SICK-010-Auftrag, review-sick-009.md Findings M1-M3).
final class FakeRawSerialSyscalls: RawSerialSyscalls {
    private var pollScript: [RawPollResult]
    private var readScript: [RawReadResult]
    private(set) var pollCallCount = 0
    private(set) var readCallCount = 0
    private(set) var closeCallCount = 0

    init(pollScript: [RawPollResult] = [], readScript: [RawReadResult] = []) {
        self.pollScript = pollScript
        self.readScript = readScript
    }

    func poll(fileDescriptor: Int32, timeoutMilliseconds: Int32) -> RawPollResult {
        pollCallCount += 1
        guard !pollScript.isEmpty else {
            return RawPollResult(returnValue: 0, revents: 0, capturedErrno: 0)
        }
        return pollScript.removeFirst()
    }

    func read(fileDescriptor: Int32, maxLength: Int) -> RawReadResult {
        readCallCount += 1
        guard !readScript.isEmpty else { return .endOfFile }
        return readScript.removeFirst()
    }

    func close(fileDescriptor: Int32) {
        closeCallCount += 1
    }
}

final class DarwinSerialPortFileDescriptorTests: XCTestCase {

    private func ready(_ revents: Int32) -> RawPollResult {
        RawPollResult(returnValue: 1, revents: Int16(revents), capturedErrno: 0)
    }

    private func pollError(_ errorCode: Int32) -> RawPollResult {
        RawPollResult(returnValue: -1, revents: 0, capturedErrno: errorCode)
    }

    // MARK: - M1: bei POLLIN erst lesen, HUP erst nach read == 0

    func testPollInWithConcurrentHangupReadsBytesInsteadOfClosingImmediately() {
        // review-sick-009.md 2.1/M1: am echten Stromende meldet poll()
        // "revents = POLLIN|POLLHUP" gemeinsam. Noch im Kernel-Puffer
        // stehende Bytes dürfen dabei nicht verloren gehen.
        let syscalls = FakeRawSerialSyscalls(
            pollScript: [ready(POLLIN | POLLHUP)],
            readScript: [.bytes([0x02, 0x81, 0x00, 0x00, 0x11, 0x88])]
        )
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        let outcome = descriptor.read(timeoutMilliseconds: 100)

        XCTAssertEqual(outcome, .bytes([0x02, 0x81, 0x00, 0x00, 0x11, 0x88]))
        XCTAssertEqual(syscalls.readCallCount, 1, "bei gesetztem POLLIN muss read() versucht werden")
    }

    func testPollInWithConcurrentHangupAndSubsequentEOFClosesAfterReadReturnsZero() {
        let syscalls = FakeRawSerialSyscalls(
            pollScript: [ready(POLLIN | POLLHUP)],
            readScript: [.endOfFile]
        )
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        let outcome = descriptor.read(timeoutMilliseconds: 100)

        XCTAssertEqual(outcome, .closed)
        XCTAssertEqual(syscalls.readCallCount, 1)
        XCTAssertEqual(syscalls.closeCallCount, 1)
    }

    func testHangupWithoutPollInClosesWithoutAttemptingRead() {
        // Kein POLLIN -- nichts zu lesen, ein reiner Hangup-Zustand.
        let syscalls = FakeRawSerialSyscalls(pollScript: [ready(POLLHUP)])
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        let outcome = descriptor.read(timeoutMilliseconds: 100)

        XCTAssertEqual(outcome, .closed)
        XCTAssertEqual(syscalls.readCallCount, 0)
    }

    // MARK: - M2: errno-Klassifikation statt pauschalem Timeout

    func testPollErrorEINTRIsClassifiedAsTimeout() {
        let syscalls = FakeRawSerialSyscalls(pollScript: [pollError(EINTR)])
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(descriptor.read(timeoutMilliseconds: 100), .timeout)
        XCTAssertEqual(syscalls.closeCallCount, 0)
    }

    func testPollErrorEBADFIsClassifiedAsClosedNotEndlessTimeout() {
        // review-sick-009.md M2: ein ungültiger Deskriptor darf nicht
        // dauerhaft "timeout" bleiben.
        let syscalls = FakeRawSerialSyscalls(pollScript: [pollError(EBADF)])
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(descriptor.read(timeoutMilliseconds: 100), .closed)
        XCTAssertEqual(syscalls.closeCallCount, 1)
    }

    func testPollNVALIsClassifiedAsClosed() {
        let syscalls = FakeRawSerialSyscalls(pollScript: [ready(POLLNVAL)])
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(descriptor.read(timeoutMilliseconds: 100), .closed)
    }

    func testReadErrorEAGAINIsClassifiedAsTimeout() {
        let syscalls = FakeRawSerialSyscalls(pollScript: [ready(POLLIN)], readScript: [.error(errno: EAGAIN)])
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(descriptor.read(timeoutMilliseconds: 100), .timeout)
        XCTAssertEqual(syscalls.closeCallCount, 0)
    }

    func testReadErrorEIOIsClassifiedAsClosed() {
        let syscalls = FakeRawSerialSyscalls(pollScript: [ready(POLLIN)], readScript: [.error(errno: EIO)])
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(descriptor.read(timeoutMilliseconds: 100), .closed)
        XCTAssertEqual(syscalls.closeCallCount, 1)
    }

    func testPollTimeoutRemainsTimeout() {
        let syscalls = FakeRawSerialSyscalls(pollScript: [RawPollResult(returnValue: 0, revents: 0, capturedErrno: 0)])
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        XCTAssertEqual(descriptor.read(timeoutMilliseconds: 100), .timeout)
    }

    // MARK: - M3: deinit schließt den Deskriptor auch ohne expliziten close()-Aufruf

    func testDeinitClosesUnderlyingSyscallWithoutExplicitClose() {
        let syscalls = FakeRawSerialSyscalls()

        do {
            _ = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)
        }

        XCTAssertEqual(syscalls.closeCallCount, 1, "deinit muss den Deskriptor schließen, auch ohne close()")
    }

    // MARK: - N1: .closed impliziert bereits geschlossen (Invariante)

    func testCloseIsIdempotent() {
        let syscalls = FakeRawSerialSyscalls()
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        descriptor.close()
        descriptor.close()

        XCTAssertEqual(syscalls.closeCallCount, 1)
    }

    func testReadAfterCloseReturnsClosedWithoutTouchingSyscallsAgain() {
        let syscalls = FakeRawSerialSyscalls()
        let descriptor = DarwinSerialPortFileDescriptor(fileDescriptor: 999, syscalls: syscalls)

        descriptor.close()
        let outcome = descriptor.read(timeoutMilliseconds: 100)

        XCTAssertEqual(outcome, .closed)
        XCTAssertEqual(syscalls.pollCallCount, 0)
        XCTAssertEqual(syscalls.readCallCount, 0)
    }

    // MARK: - M4: O_RDONLY, verbindlich, ohne O_RDWR-Fallback

    func testOpenFlagsAreStrictlyReadOnlyWithoutWriteFallback() {
        let flags = DarwinSerialPortOpener.openFlags

        XCTAssertEqual(flags & O_ACCMODE, O_RDONLY, "Zugriffsmodus muss exakt O_RDONLY sein, kein O_RDWR/O_WRONLY")
        XCTAssertEqual(flags & O_NOCTTY, O_NOCTTY)
        XCTAssertEqual(flags & O_NONBLOCK, O_NONBLOCK)
    }
}
