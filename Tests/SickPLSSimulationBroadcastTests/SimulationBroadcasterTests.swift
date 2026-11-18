import PlanariumInput
import XCTest
import Foundation
import Network
import Combine
import SickPLSCore
import SickPLSDeviceModel
import SickPLSSimulationBroadcast
import SickPLSSimulationControl
import SickPLSSimulationLink
import SickPLSMonitorKit

private final class ManualTickSource: SimulationTickSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    private var started = DispatchSemaphore(value: 0)

    func start(interval: Double, handler: @escaping () -> Void) {
        lock.lock()
        self.handler = handler
        let started = self.started
        lock.unlock()
        started.signal()
    }

    func stop() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    func waitUntilStarted(timeout: TimeInterval = 2) {
        lock.lock()
        let started = self.started
        lock.unlock()
        XCTAssertEqual(started.wait(timeout: .now() + timeout), .success)
    }

    func fire() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }
}

private final class ConnectionStateBox: @unchecked Sendable {
    var values: [Bool] = []
}

private final class ModeBox: @unchecked Sendable {
    let lock = NSLock()
    var values: [VirtualPLSMode] = []
}

private final class LoopbackCommandClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "de.sick.tests.simulation-broadcast.client")
    private let receiveLock = NSLock()
    private var receivePending = false
    private var receiveHasResult = false
    private var receiveBytes: [UInt8] = []
    private var receiveError: NWError?
    private var receiveComplete = false
    private var receiveSemaphore: DispatchSemaphore?

    init(port: NWEndpoint.Port) throws {
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"), port: port, using: .tcp
        )
        let ready = DispatchSemaphore(value: 0)
        var failed = false
        let lock = NSLock()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                lock.lock()
                if case .failed = state { failed = true }
                if case .cancelled = state { failed = true }
                lock.unlock()
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 1) == .success else {
            connection.cancel()
            throw ScanByteStreamOpenError.timedOut
        }
        lock.lock()
        let didFail = failed
        lock.unlock()
        if didFail {
            connection.cancel()
            throw ScanByteStreamOpenError.unreachable
        }
    }

    func send(_ bytes: [UInt8]) throws {
        let done = DispatchSemaphore(value: 0)
        var error: NWError?
        connection.send(content: Data(bytes), completion: .contentProcessed { sendError in
            error = sendError
            done.signal()
        })
        guard done.wait(timeout: .now() + 1) == .success else {
            throw ScanByteStreamOpenError.timedOut
        }
        if error != nil { throw ScanByteStreamOpenError.unreachable }
    }

    func receive(timeout: TimeInterval = 1) throws -> [UInt8] {
        receiveLock.lock()
        if receiveHasResult {
            let bytes = receiveBytes
            let error = receiveError
            let complete = receiveComplete
            receiveHasResult = false
            receiveBytes = []
            receiveError = nil
            receiveComplete = false
            receiveLock.unlock()
            if error != nil || (complete && bytes.isEmpty) {
                throw ScanByteStreamOpenError.unreachable
            }
            return bytes
        }
        let done: DispatchSemaphore
        if receivePending {
            done = receiveSemaphore!
        } else {
            done = DispatchSemaphore(value: 0)
            receivePending = true
            receiveSemaphore = done
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                self.receiveLock.lock()
                self.receiveBytes = data.map(Array.init) ?? []
                self.receiveComplete = isComplete
                self.receiveError = error
                self.receiveHasResult = true
                self.receivePending = false
                self.receiveLock.unlock()
                done.signal()
            }
        }
        receiveLock.unlock()
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw ScanByteStreamOpenError.timedOut
        }
        return try receive(timeout: 0)
    }

    func close() { connection.cancel() }
}

@MainActor final class SimulationBroadcasterTests: XCTestCase {
    private func command(_ payload: [UInt8]) throws -> [UInt8] {
        try Frame.build(address: 0x00, payload: payload).encoded()
    }

    private func expectedResponse(_ payload: [UInt8]) throws -> [UInt8] {
        try Frame.build(address: 0x80, payload: payload).encoded()
    }

    private func assertResponse(
        from client: LoopbackCommandClient,
        payload: [UInt8]
    ) throws {
        let actual = try client.receive()
        XCTAssertEqual(actual, try expectedResponse(payload))
    }

    private func assertTimedOut(
        _ client: LoopbackCommandClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try client.receive(timeout: 0.05)
            XCTFail("expected receive timeout", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ScanByteStreamOpenError, .timedOut, file: file, line: line)
        }
    }

    private func startBroadcaster(
        tickSource: ManualTickSource,
        profile: [UInt16] = [8191]
    ) throws -> (SimulationBroadcaster, LoopbackCommandClient) {
        let broadcaster = SimulationBroadcaster(
            interval: 0.01,
            tickSource: tickSource,
            profileProvider: { profile }
        )
        broadcaster.start()
        let portExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in broadcaster.port != nil },
            object: broadcaster
        )
        wait(for: [portExpectation], timeout: 2)
        let port = try XCTUnwrap(broadcaster.port)
        return (broadcaster, try LoopbackCommandClient(port: port))
    }

    func testH1CommandEnablesFullScanAndReturnsLiteralAcknowledgement() throws {
        let ticks = ManualTickSource()
        let (broadcaster, client) = try startBroadcaster(tickSource: ticks)
        defer { client.close(); broadcaster.stop() }

        try client.send(command([0x20, 0x24]))
        try assertResponse(from: client, payload: [0xA0, 0x00, 0x00])
        XCTAssertEqual(broadcaster.deviceMode, .fullScan)
    }

    func testH2MinimumModeAcknowledgesAndSuppressesProfiles() throws {
        let ticks = ManualTickSource()
        let (broadcaster, client) = try startBroadcaster(tickSource: ticks)
        defer { client.close(); broadcaster.stop() }

        try client.send(command([0x20, 0x20]))
        try assertResponse(from: client, payload: [0xA0, 0x00, 0x00])
        XCTAssertEqual(broadcaster.deviceMode, .minimumPerSegmentRequested)
        ticks.waitUntilStarted()
        for _ in 0..<5 { ticks.fire() }
        XCTAssertGreaterThanOrEqual(broadcaster.suppressedProfileCount, 1)
        assertTimedOut(client)
    }

    func testH3ModeSurvivesReconnectAndFullScanResumesProfiles() throws {
        let ticks = ManualTickSource()
        let (broadcaster, first) = try startBroadcaster(tickSource: ticks)
        defer { first.close(); broadcaster.stop() }
        let disconnected = expectation(description: "first connection disconnected")
        broadcaster.connectionStateHandler = { state in
            if !state { disconnected.fulfill() }
        }

        try first.send(command([0x20, 0x20]))
        try assertResponse(from: first, payload: [0xA0, 0x00, 0x00])
        first.close()
        wait(for: [disconnected], timeout: 1)

        let reconnected = expectation(description: "second connection connected")
        broadcaster.connectionStateHandler = { state in
            if state { reconnected.fulfill() }
        }
        let second = try LoopbackCommandClient(port: try XCTUnwrap(broadcaster.port))
        defer { second.close() }
        wait(for: [reconnected], timeout: 1)
        XCTAssertEqual(broadcaster.deviceMode, .minimumPerSegmentRequested)
        ticks.fire()
        assertTimedOut(second)

        try second.send(command([0x20, 0x24]))
        try assertResponse(from: second, payload: [0xA0, 0x00, 0x00])
        ticks.fire()
        let expectedProfile = try B0TelegramEncoder.frameBytes(values: [8191])
        let actualProfile = try second.receive()
        XCTAssertEqual(actualProfile, expectedProfile)
    }

    func testH4DisconnectFreesSlotBeforeNextTickSend() throws {
        let ticks = ManualTickSource()
        let (broadcaster, first) = try startBroadcaster(tickSource: ticks)
        defer { first.close(); broadcaster.stop() }
        let disconnected = expectation(description: "first connection disconnected")
        broadcaster.connectionStateHandler = { state in
            if !state { disconnected.fulfill() }
        }
        first.close()
        let start = DispatchTime.now().uptimeNanoseconds
        wait(for: [disconnected], timeout: 1)
        let disconnectedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertLessThan(disconnectedMilliseconds, 200)
        let reconnected = expectation(description: "second connection connected")
        broadcaster.connectionStateHandler = { state in
            if state { reconnected.fulfill() }
        }
        let second = try LoopbackCommandClient(port: try XCTUnwrap(broadcaster.port))
        defer { second.close() }
        wait(for: [reconnected], timeout: 1)
        ticks.fire()
        let expectedProfile = try B0TelegramEncoder.frameBytes(values: [8191])
        let actualProfile = try second.receive()
        XCTAssertEqual(actualProfile, expectedProfile)
    }

    func testH5UnsupportedModeCommandAcknowledgesWithoutChangingMode() throws {
        let ticks = ManualTickSource()
        let (broadcaster, client) = try startBroadcaster(tickSource: ticks)
        defer { client.close(); broadcaster.stop() }

        try client.send(command([0x20, 0x22]))
        try assertResponse(from: client, payload: [0xA0, 0x01, 0x00])
        XCTAssertEqual(broadcaster.deviceMode, .idle)
    }

    func testH6FragmentedCommandAndLeadingNoiseProduceOneResponse() throws {
        let ticks = ManualTickSource()
        let (broadcaster, client) = try startBroadcaster(tickSource: ticks)
        defer { client.close(); broadcaster.stop() }

        let frame = try command([0x20, 0x24])
        try client.send([0xFF, 0x13] + Array(frame.prefix(2)))
        try client.send(Array(frame[2..<5]))
        try client.send(Array(frame.dropFirst(5)))
        try assertResponse(from: client, payload: [0xA0, 0x00, 0x00])
        XCTAssertEqual(broadcaster.deviceMode, .fullScan)
        assertTimedOut(client)
    }

    func testH7RepeatedSameCommandNotifiesModeChangeOnce() throws {
        let ticks = ManualTickSource()
        let (broadcaster, client) = try startBroadcaster(tickSource: ticks)
        defer { client.close(); broadcaster.stop() }
        let modes = ModeBox()
        let changed = expectation(description: "one mode change")
        changed.assertForOverFulfill = false
        broadcaster.deviceModeHandler = { mode in
            modes.lock.lock()
            modes.values.append(mode)
            modes.lock.unlock()
            changed.fulfill()
        }

        let frame = try command([0x20, 0x24])
        try client.send(frame)
        _ = try client.receive()
        wait(for: [changed], timeout: 1)
        try client.send(frame)
        _ = try client.receive()
        Thread.sleep(forTimeInterval: 0.05)
        modes.lock.lock()
        let count = modes.values.count
        modes.lock.unlock()
        XCTAssertEqual(count, 1)
    }

    func testBroadcasterTargetIsAvailable() {
        let broadcaster = SimulationBroadcaster(profileProvider: { [8191] })
        broadcaster.start()
        broadcaster.stop()
        XCTAssertNil(broadcaster.port)
    }

    func testLoopbackBroadcasterFeedsNetworkOpener() throws {
        let ticks = ManualTickSource()
        let values: [UInt16] = [96, 8191, 120]
        let broadcaster = SimulationBroadcaster(tickSource: ticks, profileProvider: { values })
        broadcaster.start()
        let portExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in broadcaster.port != nil },
            object: broadcaster
        )
        wait(for: [portExpectation], timeout: 2)
        let port = try XCTUnwrap(broadcaster.port)
        let opener = NetworkScanByteStreamOpener(endpoint: .hostPort(host: .ipv4(.loopback), port: port))
        let stream = try opener.openStream()
        ticks.waitUntilStarted()
        ticks.fire()
        guard case let .bytes(bytes) = stream.read(timeoutMilliseconds: 1_000) else { XCTFail("no broadcast frame"); return }
        XCTAssertEqual(bytes, try B0TelegramEncoder.frameBytes(values: values))
        stream.close(); broadcaster.stop()
    }

    func testConnectionStateCallbackReportsMainThreadConnectAndDisconnect() throws {
        let broadcaster = SimulationBroadcaster(profileProvider: { [8191] })
        let connected = expectation(description: "broadcaster connected")
        let disconnected = expectation(description: "broadcaster disconnected")
        let states = ConnectionStateBox()
        broadcaster.connectionStateHandler = { state in
            XCTAssertTrue(Thread.isMainThread)
            states.values.append(state)
            if state { connected.fulfill() }
            else if states.values.dropLast().contains(true), states.values.dropLast().allSatisfy({ $0 }) {
                disconnected.fulfill()
            }
        }
        broadcaster.start()
        let portExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in broadcaster.port != nil },
            object: broadcaster
        )
        wait(for: [portExpectation], timeout: 2)
        let port = try XCTUnwrap(broadcaster.port)
        let stream = try NetworkScanByteStreamOpener(endpoint: .hostPort(host: .ipv4(.loopback), port: port)).openStream()
        wait(for: [connected], timeout: 2)
        stream.close()
        wait(for: [disconnected], timeout: 2)
        XCTAssertEqual(states.values.first, true)
        XCTAssertTrue(states.values.dropFirst().contains(false))
        broadcaster.stop()
        let mainDrain = expectation(description: "duplicate disconnect drained")
        DispatchQueue.main.async { mainDrain.fulfill() }
        wait(for: [mainDrain], timeout: 1)
        XCTAssertEqual(states.values, [true, false])
    }

    func testSecondClientIsRejectedWhileFirstContinues() throws {
        let ticks = ManualTickSource()
        let values: [UInt16] = [101, 102]
        let broadcaster = SimulationBroadcaster(tickSource: ticks, profileProvider: { values })
        broadcaster.start()
        let portExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in broadcaster.port != nil },
            object: broadcaster
        )
        wait(for: [portExpectation], timeout: 2)
        let port = try XCTUnwrap(broadcaster.port)
        let first = try NetworkScanByteStreamOpener(endpoint: .hostPort(host: .ipv4(.loopback), port: port)).openStream()
        ticks.waitUntilStarted()
        let secondOpener = NetworkScanByteStreamOpener(endpoint: .hostPort(host: .ipv4(.loopback), port: port), timeoutSeconds: 0.1)
        let second = try secondOpener.openStream()
        guard case .closed = second.read(timeoutMilliseconds: 100) else { XCTFail("second client was not rejected"); return }
        ticks.fire()
        guard case let .bytes(bytes) = first.read(timeoutMilliseconds: 1_000) else { XCTFail("first client stopped"); return }
        XCTAssertEqual(bytes, try B0TelegramEncoder.frameBytes(values: values))
        first.close(); broadcaster.stop()
    }

    func testMoreThanThreeUnacknowledgedProfilesAreDroppedAndCounted() throws {
        let ticks = ManualTickSource()
        let broadcaster = SimulationBroadcaster(tickSource: ticks, completionPolicy: .holdForTesting, profileProvider: { [8191] })
        broadcaster.start()
        let portExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in broadcaster.port != nil },
            object: broadcaster
        )
        wait(for: [portExpectation], timeout: 2)
        let port = try XCTUnwrap(broadcaster.port)
        let stream = try NetworkScanByteStreamOpener(endpoint: .hostPort(host: .ipv4(.loopback), port: port)).openStream()
        ticks.waitUntilStarted()
        for _ in 0..<4 { ticks.fire() }
        let dropExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in broadcaster.droppedProfileCount == 1 },
            object: broadcaster
        )
        wait(for: [dropExpectation], timeout: 2)
        XCTAssertEqual(broadcaster.droppedProfileCount, 1)
        stream.close(); broadcaster.stop()
    }

    func testRXSessionSimulationReceivesProfileAndReleasesOnceOnStop() throws {
        let ticks = ManualTickSource()
        let values: [UInt16] = [90, 91, 92]
        let broadcaster = SimulationBroadcaster(tickSource: ticks, profileProvider: { values })
        broadcaster.start()
        let portExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in broadcaster.port != nil },
            object: broadcaster
        )
        wait(for: [portExpectation], timeout: 2)
        let port = try XCTUnwrap(broadcaster.port)
        let session = RXSession(readTimeoutMilliseconds: 20)
        let profileExpectation = expectation(description: "profile received by RXSession")
        let releaseExpectation = expectation(description: "one port release")
        var releases = 0
        var profileFulfilled = false
        var releaseFulfilled = false
        let profileSubscription = session.performanceProfiles.sink { _ in
            if !profileFulfilled { profileFulfilled = true; profileExpectation.fulfill() }
        }
        let releaseSubscription = session.portReleased.sink { _ in
            releases += 1
            if !releaseFulfilled { releaseFulfilled = true; releaseExpectation.fulfill() }
        }
        let opener = NetworkScanByteStreamOpener(endpoint: .hostPort(host: .ipv4(.loopback), port: port))
        InputOwner(session: session).connectSimulation(serviceName: "Planarium-Sim-Test", opener: opener)
        ticks.waitUntilStarted()
        ticks.fire()
        wait(for: [profileExpectation], timeout: 2)
        broadcaster.stop()
        wait(for: [releaseExpectation], timeout: 2)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(session.state.lastProfile?.measurements.map(\.value), values)
        profileSubscription.cancel(); releaseSubscription.cancel()
    }
}
