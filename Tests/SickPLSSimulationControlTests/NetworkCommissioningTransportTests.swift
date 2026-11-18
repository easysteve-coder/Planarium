import Foundation
import Network
import XCTest
import SickPLSCommissioning
import SickPLSMacTransport
@testable import SickPLSSimulationControl

private final class FakeSimulationNetworkConnection: SimulationNetworkConnection, @unchecked Sendable {
    enum Cancellation {
        case immediate
        case delayed(TimeInterval)
        case never
    }

    enum SendResult {
        case success
        case failure(String)
        case never
    }

    private let lock = NSLock()
    private var callbackQueue: DispatchQueue?
    private var stateHandler: ((SimulationNetworkConnectionState) -> Void)?
    private var receiveCompletion: (([UInt8], Bool, String?) -> Void)?
    private var pendingSendCompletion: ((String?) -> Void)?
    private(set) var startCount = 0
    private(set) var sendCount = 0
    private(set) var receiveCount = 0
    private(set) var cancelCount = 0
    private(set) var sentBytes: [[UInt8]] = []

    var initialState: SimulationNetworkConnectionState?
    var cancellation: Cancellation = .immediate
    var sendResult: SendResult = .success

    func start(queue: DispatchQueue, stateHandler: @escaping (SimulationNetworkConnectionState) -> Void) {
        lock.lock()
        startCount += 1
        callbackQueue = queue
        self.stateHandler = stateHandler
        let initialState = self.initialState
        lock.unlock()
        if let initialState {
            queue.async { stateHandler(initialState) }
        }
    }

    func send(_ bytes: [UInt8], completion: @escaping (String?) -> Void) {
        lock.lock()
        sendCount += 1
        sentBytes.append(bytes)
        let queue = callbackQueue
        let result = sendResult
        if case .never = result {
            pendingSendCompletion = completion
        }
        lock.unlock()
        guard case .never = result else {
            queue?.async {
                switch result {
                case .success: completion(nil)
                case .failure(let message): completion(message)
                case .never: break
                }
            }
            return
        }
    }

    func receive(
        maximumLength: Int,
        completion: @escaping ([UInt8], Bool, String?) -> Void
    ) {
        lock.lock()
        receiveCount += 1
        receiveCompletion = completion
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelCount += 1
        let queue = callbackQueue
        let stateHandler = self.stateHandler
        let cancellation = self.cancellation
        lock.unlock()
        switch cancellation {
        case .immediate:
            queue?.async { stateHandler?(.cancelled) }
        case .delayed(let seconds):
            queue?.asyncAfter(deadline: .now() + seconds) { stateHandler?(.cancelled) }
        case .never:
            break
        }
    }

    func emitState(_ state: SimulationNetworkConnectionState) {
        lock.lock()
        let queue = callbackQueue
        let handler = stateHandler
        lock.unlock()
        queue?.async { handler?(state) }
    }

    func emitReceive(bytes: [UInt8] = [], isComplete: Bool = false, error: String? = nil) {
        lock.lock()
        let queue = callbackQueue
        let completion = receiveCompletion
        lock.unlock()
        queue?.async { completion?(bytes, isComplete, error) }
    }

    func completePendingSend(error: String?) {
        lock.lock()
        let queue = callbackQueue
        let completion = pendingSendCompletion
        pendingSendCompletion = nil
        lock.unlock()
        queue?.async { completion?(error) }
    }

    func drain() {
        lock.lock()
        let queue = callbackQueue
        lock.unlock()
        queue?.sync {}
    }
}

private final class FakeSimulationNetworkConnectionFactory: SimulationNetworkConnectionMaking {
    private(set) var connections: [FakeSimulationNetworkConnection] = []
    var makeConnectionHandler: (() -> FakeSimulationNetworkConnection)?

    func makeConnection(to endpoint: SimulationEndpoint) -> SimulationNetworkConnection {
        let connection = makeConnectionHandler?() ?? FakeSimulationNetworkConnection()
        connections.append(connection)
        return connection
    }
}

private final class ResultBox<Value>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

final class NetworkCommissioningTransportTests: XCTestCase {
    private let workQueue = DispatchQueue(label: "de.sick.tests.simulation-control.worker")
    private let endpoint = SimulationEndpoint.make(
        serviceID: "Luna|_sick._tcp|local.", host: "127.0.0.1", port: 48_321
    )!

    private func limits(
        open: Int = 80,
        write: Int = 80,
        close: Int = 80,
        buffer: Int = 8
    ) -> NetworkCommissioningTransportLimits {
        NetworkCommissioningTransportLimits(
            openTimeoutMilliseconds: open,
            writeTimeoutMilliseconds: write,
            closeTimeoutMilliseconds: close,
            receiveBufferLimit: buffer
        )
    }

    private func transport(
        fake: FakeSimulationNetworkConnection,
        limits: NetworkCommissioningTransportLimits? = nil
    ) -> NetworkCommissioningTransport {
        let factory = FakeSimulationNetworkConnectionFactory()
        factory.makeConnectionHandler = { fake }
        return NetworkCommissioningTransport(
            endpoint: endpoint,
            factory: factory,
            limits: limits ?? self.limits()
        )
    }

    private func closeOffMain(_ transport: NetworkCommissioningTransport) throws {
        try onWorker { try transport.closePort() }
    }

    private func onWorker<Value>(_ work: @escaping () throws -> Value) throws -> Value {
        let box = ResultBox<Value>()
        let done = DispatchSemaphore(value: 0)
        workQueue.async {
            box.result = Result { try work() }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

    private func readOnWorker(
        _ transport: NetworkCommissioningTransport,
        timeoutMilliseconds: Int32
    ) -> SerialPortReadOutcome {
        let box = ResultBox<SerialPortReadOutcome>()
        let done = DispatchSemaphore(value: 0)
        workQueue.async {
            box.result = .success(transport.read(timeoutMilliseconds: timeoutMilliseconds))
            done.signal()
        }
        done.wait()
        return try! box.result!.get()
    }

    func testN1ReadyRejectsSecondOpenAndIgnoresBaudRate() throws {
        let fake = FakeSimulationNetworkConnection()
        fake.initialState = .ready
        let transport = transport(fake: fake)

        try onWorker { try transport.openPort(baudRate: .baud9600) }
        XCTAssertThrowsError(try onWorker { try transport.openPort(baudRate: .baud38400) }) { error in
            XCTAssertEqual(error as? CommissioningTransportError, .portAlreadyOpen)
        }
        XCTAssertEqual(fake.startCount, 1)
    }

    func testN2FailedAndOpeningTimeoutCancelAndThrowOpenFailed() throws {
        let failed = FakeSimulationNetworkConnection()
        failed.initialState = .failed("offline")
        let failedTransport = transport(fake: failed, limits: limits(open: 80))
        XCTAssertThrowsError(try onWorker { try failedTransport.openPort(baudRate: .baud9600) }) { error in
            guard case .openFailed = error as? CommissioningTransportError else {
                return XCTFail("expected openFailed, got \(error)")
            }
        }
        XCTAssertEqual(failed.cancelCount, 1)

        let timedOut = FakeSimulationNetworkConnection()
        let timedOutTransport = transport(fake: timedOut, limits: limits(open: 20))
        XCTAssertThrowsError(try onWorker { try timedOutTransport.openPort(baudRate: .baud38400) }) { error in
            guard case .openFailed = error as? CommissioningTransportError else {
                return XCTFail("expected openFailed, got \(error)")
            }
        }
        XCTAssertEqual(timedOut.cancelCount, 1)
    }

    func testN3DelayedCloseWaitsForCancelledAndAllowsNextOpen() throws {
        let fake = FakeSimulationNetworkConnection()
        fake.initialState = .ready
        fake.cancellation = .delayed(0.03)
        let transport = transport(fake: fake, limits: limits(close: 100))
        try onWorker { try transport.openPort(baudRate: .baud9600) }

        let start = DispatchTime.now().uptimeNanoseconds
        try closeOffMain(transport)
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 30)
        XCTAssertEqual(transport.read(timeoutMilliseconds: 0), .closed)

        fake.initialState = .ready
        try onWorker { try transport.openPort(baudRate: .baud38400) }
    }

    func testN4CloseTimeoutRetainsOpenUntilLaterCancelled() throws {
        let fake = FakeSimulationNetworkConnection()
        fake.initialState = .ready
        fake.cancellation = .never
        let transport = transport(fake: fake, limits: limits(close: 20))
        try onWorker { try transport.openPort(baudRate: .baud9600) }

        XCTAssertThrowsError(try closeOffMain(transport)) { error in
            XCTAssertEqual(error as? NetworkCommissioningTransportError, .closeTimedOut)
        }
        XCTAssertThrowsError(try onWorker { try transport.openPort(baudRate: .baud38400) }) { error in
            XCTAssertEqual(error as? CommissioningTransportError, .portAlreadyOpen)
        }

        fake.cancellation = .immediate
        try closeOffMain(transport)
        fake.initialState = .ready
        try onWorker { try transport.openPort(baudRate: .baud38400) }
    }

    func testN5WriteFailureAndTimeoutCloseGenerationAndIgnoreLateCompletion() throws {
        let failed = FakeSimulationNetworkConnection()
        failed.initialState = .ready
        failed.sendResult = .failure("send failed")
        let failedTransport = transport(fake: failed)
        try onWorker { try failedTransport.openPort(baudRate: .baud9600) }
        XCTAssertThrowsError(try onWorker { try failedTransport.write([1]) }) { error in
            guard case .writeFailed = error as? CommissioningTransportError else {
                return XCTFail("expected writeFailed, got \(error)")
            }
        }
        XCTAssertEqual(failedTransport.read(timeoutMilliseconds: 0), .closed)

        let timedOut = FakeSimulationNetworkConnection()
        timedOut.initialState = .ready
        timedOut.sendResult = .never
        let timedOutTransport = transport(fake: timedOut, limits: limits(write: 20))
        try onWorker { try timedOutTransport.openPort(baudRate: .baud9600) }
        XCTAssertThrowsError(try onWorker { try timedOutTransport.write([2]) }) { error in
            guard case .writeFailed = error as? CommissioningTransportError else {
                return XCTFail("expected writeFailed, got \(error)")
            }
        }
        XCTAssertEqual(timedOutTransport.read(timeoutMilliseconds: 0), .closed)
        timedOut.completePendingSend(error: nil)
        timedOut.drain()
        XCTAssertEqual(timedOutTransport.read(timeoutMilliseconds: 0), .closed)
        XCTAssertThrowsError(try onWorker { try timedOutTransport.write([3]) }) { error in
            XCTAssertEqual(error as? CommissioningTransportError, .portNotOpen)
        }
    }

    func testN6CompleteAfterBytesDeliversBytesThenClosed() throws {
        let fake = FakeSimulationNetworkConnection()
        fake.initialState = .ready
        let transport = transport(fake: fake)
        try onWorker { try transport.openPort(baudRate: .baud9600) }
        fake.emitReceive(bytes: [1, 2], isComplete: true)
        XCTAssertEqual(readOnWorker(transport, timeoutMilliseconds: 100), .bytes([1, 2]))
        XCTAssertEqual(transport.read(timeoutMilliseconds: 0), .closed)
    }

    func testN7FragmentsAndSinglePacketsPreserveOrder() throws {
        let fake = FakeSimulationNetworkConnection()
        fake.initialState = .ready
        let transport = transport(fake: fake)
        try onWorker { try transport.openPort(baudRate: .baud9600) }
        fake.emitReceive(bytes: [1])
        fake.drain()
        fake.emitReceive(bytes: [2, 3])
        fake.drain()
        XCTAssertEqual(readOnWorker(transport, timeoutMilliseconds: 100), .bytes([1, 2, 3]))
        fake.emitReceive(bytes: [4])
        fake.drain()
        XCTAssertEqual(readOnWorker(transport, timeoutMilliseconds: 100), .bytes([4]))
    }

    func testN8FlushDropsOldBytesBeforeWriteAndKeepsResponse() throws {
        let fake = FakeSimulationNetworkConnection()
        fake.initialState = .ready
        let transport = transport(fake: fake)
        try onWorker { try transport.openPort(baudRate: .baud9600) }
        fake.emitReceive(bytes: [9, 9])
        fake.drain()
        transport.flushReceiveBuffer()
        try onWorker { try transport.write([0x02, 0x00]) }
        fake.emitReceive(bytes: [6])
        fake.drain()
        XCTAssertEqual(readOnWorker(transport, timeoutMilliseconds: 100), .bytes([6]))
    }

    func testN9OldGenerationCallbacksCannotChangeNewGeneration() throws {
        let first = FakeSimulationNetworkConnection()
        first.initialState = .ready
        let second = FakeSimulationNetworkConnection()
        second.initialState = .ready
        let factory = FakeSimulationNetworkConnectionFactory()
        factory.makeConnectionHandler = {
            factory.connections.isEmpty ? first : second
        }
        let transport = NetworkCommissioningTransport(
            endpoint: endpoint, factory: factory, limits: limits()
        )
        try onWorker { try transport.openPort(baudRate: .baud9600) }
        try closeOffMain(transport)
        try onWorker { try transport.openPort(baudRate: .baud38400) }

        first.emitReceive(bytes: [7])
        first.drain()
        XCTAssertEqual(first.receiveCount, 1)
        XCTAssertEqual(readOnWorker(transport, timeoutMilliseconds: 20), .timeout)
    }

    func testN10ReceiveBufferLimitClosesGeneration() throws {
        let fake = FakeSimulationNetworkConnection()
        fake.initialState = .ready
        let transport = transport(fake: fake, limits: limits(buffer: 8))
        try onWorker { try transport.openPort(baudRate: .baud9600) }
        fake.emitReceive(bytes: Array(0...8))
        XCTAssertEqual(readOnWorker(transport, timeoutMilliseconds: 100), .closed)
    }

    func testN13OpenRegistersFirstReceiveBeforeReturning() throws {
        let fake = FakeSimulationNetworkConnection()
        fake.initialState = .ready
        let transport = transport(fake: fake)
        try onWorker { try transport.openPort(baudRate: .baud38400) }
        XCTAssertGreaterThanOrEqual(fake.receiveCount, 1)
    }

    func testN11ReadAndCloseWithoutOpenAreClosedAndIdempotent() {
        let fake = FakeSimulationNetworkConnection()
        let transport = transport(fake: fake)
        XCTAssertEqual(transport.read(timeoutMilliseconds: 0), .closed)
        XCTAssertNoThrow(try closeOffMain(transport))
        XCTAssertEqual(fake.cancelCount, 0)
    }

    func testN12LoopbackAdapterEchoesAndCanOpenAgain() throws {
        let listener = try NWListener(using: .tcp)
        let ready = expectation(description: "loopback listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        listener.start(queue: .global(qos: .userInitiated))
        wait(for: [ready], timeout: 2)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let endpoint = try XCTUnwrap(SimulationEndpoint.make(
            serviceID: "loopback", host: "127.0.0.1", port: port
        ))
        let transport = NetworkCommissioningTransport(
            endpoint: endpoint,
            factory: NWSimulationNetworkConnectionFactory(),
            limits: limits(open: 500, write: 500, close: 500)
        )
        let start = DispatchTime.now().uptimeNanoseconds
        try onWorker { try transport.openPort(baudRate: .baud9600) }
        transport.flushReceiveBuffer()
        try onWorker { try transport.write([0x02, 0x00]) }
        XCTAssertEqual(readOnWorker(transport, timeoutMilliseconds: 500), .bytes([0x02, 0x00]))
        try closeOffMain(transport)
        try onWorker { try transport.openPort(baudRate: .baud38400) }
        try closeOffMain(transport)
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("N12 loopback duration: \(elapsedMilliseconds) ms")
        listener.cancel()
    }
}
