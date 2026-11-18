import Foundation
import Network
import XCTest
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport
import SickPLSSimulationBroadcast
@testable import SickPLSSimulationControl

private final class ScriptedCommissioningTransport: CommissioningTransport {
    enum Failure: Error {
        case open
        case write
        case close
    }

    var openFailure: Error?
    var writeFailure: Error?
    var closeFailure: Error?
    var reads: [SerialPortReadOutcome]
    var now: (() -> Void)?
    private(set) var events: [String] = []
    private(set) var writes: [[UInt8]] = []
    private(set) var readCount = 0

    init(reads: [SerialPortReadOutcome] = []) {
        self.reads = reads
    }

    func openPort(baudRate: SerialPortBaudRate) throws {
        events.append("open")
        if let openFailure { throw openFailure }
    }

    func closePort() throws {
        events.append("close")
        if let closeFailure { throw closeFailure }
    }

    func flushReceiveBuffer() {
        events.append("flush")
    }

    func write(_ bytes: [UInt8]) throws {
        events.append("write")
        writes.append(bytes)
        if let writeFailure { throw writeFailure }
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        events.append("read")
        readCount += 1
        now?()
        return reads.isEmpty ? .timeout : reads.removeFirst()
    }
}

final class SimulationModeRunTests: XCTestCase {
    private let endpoint = SimulationEndpoint.make(
        serviceID: "test|_sick._tcp|local.", host: "127.0.0.1", port: 48_321
    )!

    private func lease(
        _ mode: SimulationMeasurementMode,
        generation: UInt64 = 7
    ) -> SimulationControlLease {
        SimulationControlLease(
            endpoint: endpoint,
            generation: SimulationControlGeneration(generation),
            job: .setMeasurementMode(mode)
        )
    }

    func testM1BuildsLiteralFullScanAndMinimumCommands() throws {
        // STX, address 0, little-endian payload length 2, payload, CRC16 LE.
        // For 20 24 the CRC is 0x0834; for 20 20 it is 0x0830.
        XCTAssertEqual(
            SimulationModeTelegram.command(for: .fullScan),
            [0x02, 0x00, 0x02, 0x00, 0x20, 0x24, 0x34, 0x08]
        )
        XCTAssertEqual(
            SimulationModeTelegram.command(for: .minimumPerSegment),
            [0x02, 0x00, 0x02, 0x00, 0x20, 0x20, 0x30, 0x08]
        )
    }

    func testM2MatchesOnlyTheAcknowledgementFramesAndSticks() {
        let acknowledged: [UInt8] = [0x02, 0x80, 0x03, 0x00, 0xA0, 0x00, 0x00, 0x06, 0x0A]
        let rejected: [UInt8] = [0x02, 0x80, 0x03, 0x00, 0xA0, 0x01, 0x00, 0x04, 0x0B]
        let wrongAddress: [UInt8] = [0x02, 0x81, 0x03, 0x00, 0xA0, 0x00, 0x00, 0x26, 0x1A]

        var matcher = SimulationModeReplyMatcher()
        XCTAssertEqual(matcher.feed(wrongAddress), nil)
        XCTAssertEqual(matcher.feed([0x06]), nil)
        XCTAssertEqual(matcher.feed([0x06] + acknowledged), .acknowledged)
        XCTAssertEqual(matcher.feed(rejected), .acknowledged)

        var bytewise = SimulationModeReplyMatcher()
        var decision: SimulationControlJobResult?
        for byte in acknowledged { decision = bytewise.feed([byte]) ?? decision }
        XCTAssertEqual(decision, .acknowledged)

        var rejectedMatcher = SimulationModeReplyMatcher()
        XCTAssertEqual(rejectedMatcher.feed(rejected), .rejected)
    }

    func testM3RecognizesOnlyAnOutOfFrameNack() throws {
        var matcher = SimulationModeReplyMatcher()
        XCTAssertEqual(matcher.feed([0x15]), .rejected)

        let payloadNack = try Frame.build(address: 0x81, payload: [0xA0, 0x15, 0x00]).encoded()
        var frameMatcher = SimulationModeReplyMatcher()
        XCTAssertEqual(frameMatcher.feed(payloadNack), nil)
    }

    func testM4ExecutesSuccessInOpenFlushWriteReadCloseOrder() {
        let ack: [UInt8] = [0x02, 0x80, 0x03, 0x00, 0xA0, 0x00, 0x00, 0x06, 0x0A]
        let transport = ScriptedCommissioningTransport(reads: [.bytes(ack)])
        let completion = SimulationModeRun.execute(
            lease: lease(.fullScan), transport: transport, nowMilliseconds: { 0 }
        )

        XCTAssertEqual(completion.result, SimulationControlJobResult.acknowledged)
        XCTAssertEqual(completion.closeStatus, SimulationControlCloseStatus.closed)
        XCTAssertEqual(transport.events, ["open", "flush", "write", "read", "close"])
        XCTAssertEqual(
            transport.writes,
            [[0x02, 0x00, 0x02, 0x00, 0x20, 0x24, 0x34, 0x08]]
        )
    }

    func testM5AcceptsAResponseFragmentedAcrossThreeReads() {
        let transport = ScriptedCommissioningTransport(reads: [
            .bytes([0x02, 0x80]),
            .bytes([0x03, 0x00, 0xA0]),
            .bytes([0x00, 0x00, 0x06, 0x0A])
        ])
        let completion = SimulationModeRun.execute(
            lease: lease(.minimumPerSegment), transport: transport, nowMilliseconds: { 0 }
        )

        XCTAssertEqual(completion.result, SimulationControlJobResult.acknowledged)
        XCTAssertEqual(completion.closeStatus, SimulationControlCloseStatus.closed)
    }

    func testM6TimesOutOnTheAbsoluteDeadlineAndCloses() {
        var milliseconds: UInt64 = 0
        let transport = ScriptedCommissioningTransport(reads: [.timeout, .timeout, .timeout, .timeout])
        transport.now = { milliseconds += 50 }
        let completion = SimulationModeRun.execute(
            lease: lease(.fullScan),
            transport: transport,
            limits: .init(transactionDeadlineMilliseconds: 150, readSliceMilliseconds: 50),
            nowMilliseconds: { milliseconds }
        )

        XCTAssertEqual(completion.result, SimulationControlJobResult.timedOut)
        XCTAssertEqual(completion.closeStatus, SimulationControlCloseStatus.closed)
        XCTAssertLessThanOrEqual(transport.readCount, 4)
        XCTAssertTrue(transport.events.contains("close"))
    }

    func testM7ClosedBeforeResponseIsTransportFailureAndCloses() {
        let transport = ScriptedCommissioningTransport(reads: [.closed])
        let completion = SimulationModeRun.execute(
            lease: lease(.fullScan), transport: transport, nowMilliseconds: { 0 }
        )

        XCTAssertEqual(completion.result, SimulationControlJobResult.transportFailed)
        XCTAssertEqual(completion.closeStatus, SimulationControlCloseStatus.closed)
        XCTAssertTrue(transport.events.contains("close"))
    }

    func testM8WriteFailureSkipsReadAndStillCloses() {
        let transport = ScriptedCommissioningTransport()
        transport.writeFailure = ScriptedCommissioningTransport.Failure.write
        let completion = SimulationModeRun.execute(
            lease: lease(.fullScan), transport: transport, nowMilliseconds: { 0 }
        )

        XCTAssertEqual(completion.result, SimulationControlJobResult.transportFailed)
        XCTAssertEqual(completion.closeStatus, SimulationControlCloseStatus.closed)
        XCTAssertFalse(transport.events.contains("read"))
        XCTAssertTrue(transport.events.contains("close"))
    }

    func testM9OpenFailuresReportTransportAndCloseStatus() {
        let openFailed = ScriptedCommissioningTransport()
        openFailed.openFailure = CommissioningTransportError.openFailed("offline")
        let failedCompletion = SimulationModeRun.execute(
            lease: lease(.fullScan), transport: openFailed, nowMilliseconds: { 0 }
        )
        XCTAssertEqual(failedCompletion.result, SimulationControlJobResult.transportFailed)
        XCTAssertEqual(failedCompletion.closeStatus, SimulationControlCloseStatus.closed)

        let closeTimedOut = ScriptedCommissioningTransport()
        closeTimedOut.openFailure = NetworkCommissioningTransportError.closeTimedOut
        let blockedCompletion = SimulationModeRun.execute(
            lease: lease(.fullScan), transport: closeTimedOut, nowMilliseconds: { 0 }
        )
        XCTAssertEqual(blockedCompletion.result, SimulationControlJobResult.transportFailed)
        XCTAssertEqual(blockedCompletion.closeStatus, SimulationControlCloseStatus.closeFailed)
    }

    func testM10CloseFailureDoesNotEraseAcknowledgement() {
        let ack: [UInt8] = [0x02, 0x80, 0x03, 0x00, 0xA0, 0x00, 0x00, 0x06, 0x0A]
        let transport = ScriptedCommissioningTransport(reads: [.bytes(ack)])
        transport.closeFailure = NetworkCommissioningTransportError.closeTimedOut
        let completion = SimulationModeRun.execute(
            lease: lease(.fullScan), transport: transport, nowMilliseconds: { 0 }
        )

        XCTAssertEqual(completion.result, SimulationControlJobResult.acknowledged)
        XCTAssertEqual(completion.closeStatus, SimulationControlCloseStatus.closeFailed)
    }

    func testM11LoopbackModeRunChangesTheRealBroadcastersDeviceMode() throws {
        let broadcaster = SimulationBroadcaster(profileProvider: { [] })
        broadcaster.start()
        defer { broadcaster.stop() }

        let deadline = Date().addingTimeInterval(2)
        while broadcaster.port == nil && Date() < deadline { usleep(1_000) }
        let port = try XCTUnwrap(broadcaster.port)
        let endpoint = try XCTUnwrap(SimulationEndpoint.make(
            serviceID: "loopback|_sick._tcp|local.", host: "127.0.0.1", port: port.rawValue
        ))
        let transport = NetworkCommissioningTransport(
            endpoint: endpoint,
            factory: NWSimulationNetworkConnectionFactory(),
            limits: NetworkCommissioningTransportLimits(
                openTimeoutMilliseconds: 500,
                writeTimeoutMilliseconds: 500,
                closeTimeoutMilliseconds: 500
            )
        )

        let result = runOnWorker {
            SimulationModeRun.execute(
                lease: SimulationControlLease(
                    endpoint: endpoint,
                    generation: .init(11),
                    job: .setMeasurementMode(.minimumPerSegment)
                ),
                transport: transport,
                nowMilliseconds: { UInt64(ProcessInfo.processInfo.systemUptime * 1_000) }
            )
        }
        XCTAssertEqual(result.result, SimulationControlJobResult.acknowledged)
        XCTAssertEqual(result.closeStatus, SimulationControlCloseStatus.closed)
        XCTAssertEqual(broadcaster.deviceMode, .minimumPerSegmentRequested)
    }

    private func runOnWorker<Value>(_ work: @escaping () -> Value) -> Value {
        let queue = DispatchQueue(label: "de.sick.tests.simulation-mode-run.worker")
        let done = DispatchSemaphore(value: 0)
        var value: Value?
        queue.async {
            value = work()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        return value!
    }
}
