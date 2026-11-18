import PlanariumInput
import XCTest
import Network
import SickPLSCore
import SickPLSMacTransport
import SickPLSMonitorKit
import SickPLSSimulationControl
import SickPLSSimulationLink
@testable import PlanariumScannerUI
@testable import SickPLSCommissioningControl

private final class SimulationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: TimeInterval) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

@MainActor final class SimulationCoordinatorIntegrationTests: XCTestCase {
    private func harness(reading script: [SerialPortReadOutcome]) -> CoordinatorHarness {
        CoordinatorHarness(
            descriptors: [FakeSerialPortFileDescriptor(readScript: script)]
        )
    }

    private func waitForRelease(_ harness: CoordinatorHarness) {
        waitUntil { harness.sessionDelivery.inputEndedCount == 1 && !harness.coordinator.session.isPortHeld }
        XCTAssertEqual(harness.sessionDelivery.inputEndedCount, 1)
    }

    private func waitForSimulationConnection(_ harness: CoordinatorHarness) {
        waitUntil {
            if case .simulationConnected = harness.coordinator.session.state.connection { return true }
            return false
        }
    }

    private func listener(sending payloads: [Data] = []) throws -> (NWListener, NWEndpoint.Port) {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                if !payloads.isEmpty {
                    var sendNext: ((Int) -> Void)!
                    sendNext = { index in
                        connection.send(content: payloads[index], completion: .contentProcessed { _ in
                            guard index + 1 < payloads.count else { return }
                            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                                sendNext(index + 1)
                            }
                        })
                    }
                    sendNext(0)
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        let ready = expectation(description: "simulation listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .global(qos: .userInitiated))
        wait(for: [ready], timeout: 2)
        guard let port = listener.port else {
            listener.cancel()
            throw NSError(domain: "SimulationCoordinatorIntegrationTests", code: 1)
        }
        return (listener, port)
    }

    func testSimulationEndToEndThroughNWListenerCoordinatorDelivers90And361PointProfiles() throws {
        let mmk = Array(0..<90).map { UInt16(100 + $0) }
        let fullScan = Array(0..<361).map { UInt16(200 + $0) }
        let payloads = [
            Data(try B0TelegramEncoder.frameBytes(values: mmk)),
            Data(try B0TelegramEncoder.frameBytes(values: fullScan))
        ]
        let (listener, port) = try listener(sending: payloads)
        defer { listener.cancel() }

        let harness = harness(reading: Array(repeating: .timeout, count: 100))
        let opener = NetworkScanByteStreamOpener(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            timeoutSeconds: 2
        )
        XCTAssertEqual(
            harness.coordinator.connectSimulation(serviceName: "nw-loopback", opener: opener),
            .connecting
        )
        waitUntil { harness.sessionDelivery.acceptedProfiles.count == 2 }

        guard harness.sessionDelivery.acceptedProfiles.count == 2 else {
            harness.coordinator.disconnect()
            return
        }
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles[0], mmk)
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles[1], fullScan)
        guard case .simulation(.streaming(
            serviceName: "nw-loopback", pointCount: 361
        )) = harness.coordinator.measurementSessionStatus else {
            XCTFail("unexpected simulation status: \(harness.coordinator.measurementSessionStatus)")
            harness.coordinator.disconnect()
            return
        }
        XCTAssertNotNil(harness.coordinator.session.state.profileRateHz)
        let bar = ConnectionBarState.derive(
            run: nil,
            runPortPath: nil,
            stage: .idle,
            measurement: harness.coordinator.measurementSessionStatus,
            isAwaitingPortRelease: false,
            lastDisconnectedPort: nil
        )
        XCTAssertEqual(bar, .inputIsSimulation(serviceName: "nw-loopback"))

        harness.coordinator.disconnect()
        waitForRelease(harness)
    }

    func testSimulationEndToEndThroughCoordinatorDelivers90And361AndSimulationBar() throws {
        let harness = harness(reading: [.bytes(try b0FrameBytes(measurements: [90, 361]))] + Array(repeating: .timeout, count: 20))

        XCTAssertEqual(
            harness.coordinator.connectSimulation(serviceName: "loopback", opener: harness.opener),
            .connecting
        )
        waitUntil { harness.sessionDelivery.acceptedProfiles.count == 1 }

        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles, [[90, 361]])
        XCTAssertEqual(
            harness.coordinator.measurementSessionStatus,
            .simulation(.streaming(serviceName: "loopback", pointCount: 2))
        )
        let bar = ConnectionBarState.derive(
            run: nil,
            runPortPath: nil,
            stage: .idle,
            measurement: harness.coordinator.measurementSessionStatus,
            isAwaitingPortRelease: false,
            lastDisconnectedPort: nil
        )
        XCTAssertEqual(bar, .inputIsSimulation(serviceName: "loopback"))

        harness.coordinator.disconnect()
        waitForRelease(harness)
    }

    func testSimulationDisconnectReleasesExactlyOnceThroughCoordinator() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 40))
        _ = harness.coordinator.connectSimulation(serviceName: "disconnect", opener: harness.opener)
        waitForSimulationConnection(harness)
        harness.coordinator.disconnect()
        waitForRelease(harness)
    }

    func testSimulationFINReleasesExactlyOnceThroughCoordinator() throws {
        let harness = harness(reading: [.closed])
        _ = harness.coordinator.connectSimulation(serviceName: "fin", opener: harness.opener)
        waitForRelease(harness)
        XCTAssertEqual(harness.coordinator.portOwner, .free)
        XCTAssertFalse(harness.coordinator.isAwaitingPortRelease)
        XCTAssertEqual(
            harness.coordinator.measurementSessionStatus,
            .simulation(.failed(serviceName: "fin", message: "Connection ended unexpectedly (end of stream)."))
        )
    }

    func testSimulationSilenceDoesNotEndBeforeTheBoundaryAndDisconnectEndsOnce() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 200))
        _ = harness.coordinator.connectSimulation(serviceName: "quiet", opener: harness.opener)
        waitForSimulationConnection(harness)
        pumpMainLoop(seconds: 0.05)
        XCTAssertEqual(harness.sessionDelivery.inputEndedCount, 0)
        harness.coordinator.disconnect()
        waitForRelease(harness)
    }

    func testSimulationSilenceBeyondTwoSecondsReleasesExactlyOnceThroughCoordinator() throws {
        let (listener, port) = try listener()
        defer { listener.cancel() }
        let clock = SimulationTestClock()
        let opener = NetworkScanByteStreamOpener(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            timeoutSeconds: 2,
            silenceLimitSeconds: 2,
            now: { clock.now }
        )
        let harness = harness(reading: [])
        _ = harness.coordinator.connectSimulation(serviceName: "quiet-loopback", opener: opener)
        waitForSimulationConnection(harness)

        XCTAssertEqual(harness.sessionDelivery.inputEndedCount, 0)
        clock.set(2.001)
        waitForRelease(harness)
        pumpMainLoop(seconds: 0.05)
        XCTAssertEqual(harness.sessionDelivery.inputEndedCount, 1)
    }

    func testSimulationOpenFailureReleasesExactlyOnceThroughCoordinator() throws {
        let harness = harness(reading: [])
        harness.opener.errorToThrow = FakeSerialPortOpener.OpenFailure()
        _ = harness.coordinator.connectSimulation(serviceName: "closed-port", opener: harness.opener)
        waitForRelease(harness)
        XCTAssertEqual(
            harness.coordinator.measurementSessionStatus,
            .simulation(.failed(serviceName: "closed-port", message: "Unknown error opening the connection."))
        )
    }

    func testSimulationFINAndDisconnectInEitherOrderStillReleaseOnce() throws {
        let finFirst = harness(reading: [.closed])
        _ = finFirst.coordinator.connectSimulation(serviceName: "fin-first", opener: finFirst.opener)
        waitUntil { finFirst.sessionDelivery.inputEndedCount == 1 }
        finFirst.coordinator.disconnect()
        XCTAssertEqual(finFirst.sessionDelivery.inputEndedCount, 1)

        let disconnectFirst = harness(reading: Array(repeating: .timeout, count: 20))
        _ = disconnectFirst.coordinator.connectSimulation(serviceName: "disconnect-first", opener: disconnectFirst.opener)
        waitForSimulationConnection(disconnectFirst)
        disconnectFirst.coordinator.disconnect()
        waitForRelease(disconnectFirst)
    }
}
