import PlanariumInput
import Combine
import XCTest
import SickPLSCommissioning
import SickPLSMacTransport
@testable import PlanariumScannerUI

@MainActor final class SimulationControlCoordinatorTests: XCTestCase {
    private let endpoint = SimulationEndpoint.make(
        serviceID: "sim|_planarium-sim._tcp|local", host: "127.0.0.1", port: 9000
    )!
    private let job = SimulationControlJob.setMeasurementMode(.minimumPerSegment)

    private func simulationHarness(
        closeDelaySeconds: TimeInterval = 0,
        script: [SerialPortReadOutcome] = Array(repeating: .timeout, count: 100)
    ) -> CoordinatorHarness {
        CoordinatorHarness(descriptors: [
            FakeSerialPortFileDescriptor(
                readScript: script,
                closeDelaySeconds: closeDelaySeconds
            )
        ])
    }

    func testS9SimulationRXAwaitsRealReleaseThenGrantsExactlyOnce() {
        let descriptor = FakeSerialPortFileDescriptor(
            readScript: Array(repeating: .timeout, count: 100),
            closeDelaySeconds: 0.2
        )
        let harness = CoordinatorHarness(descriptors: [descriptor])
        var controlOwnerEvents: [SerialPortOwner] = []
        let cancellable = harness.coordinator.portOwnershipChanges.sink {
            if $0 == .simulationControl { controlOwnerEvents.append($0) }
        }
        defer { cancellable.cancel(); harness.coordinator.disconnect() }

        XCTAssertEqual(
            harness.coordinator.connectSimulation(serviceName: "rx", opener: harness.opener),
            .connecting
        )
        waitUntil {
            if case .simulationConnected = harness.coordinator.session.state.connection { return true }
            return false
        }

        XCTAssertEqual(
            harness.coordinator.requestSimulationControlAccess(endpoint: endpoint, job: job),
            .awaitingRelease
        )
        XCTAssertEqual(
            harness.coordinator.requestSimulationControlAccess(endpoint: endpoint, job: job),
            .awaitingRelease
        )

        waitUntil { harness.coordinator.portOwner == .free }
        XCTAssertEqual(descriptor.closeCallCount, 1)
        guard case .granted(let lease) = harness.coordinator.requestSimulationControlAccess(endpoint: endpoint, job: job) else {
            XCTFail("Simulation control must be granted after the real release")
            return
        }
        XCTAssertEqual(lease.generation, SimulationControlGeneration(1))
        XCTAssertEqual(controlOwnerEvents.count, 1)
    }

    func testS10SimulationControlNeverDisconnectsHardwareRX() {
        let harness = CoordinatorHarness(descriptors: [
            FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 100))
        ])
        defer { harness.coordinator.disconnect() }

        XCTAssertEqual(
            harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600),
            .connecting(baudRate: .baud9600)
        )
        XCTAssertEqual(
            harness.coordinator.requestSimulationControlAccess(endpoint: endpoint, job: job),
            .refused(.heldByMonitor)
        )
        waitUntil { harness.opener.requestedPaths.count == 1 }
        XCTAssertEqual(harness.opener.requestedPaths, ["/dev/cu.fake"])
        XCTAssertEqual(harness.coordinator.portOwner, .monitor)
    }

    func testS11SimulationControlBlocksMonitorConnectAndCommissioningReadiness() {
        let harness = simulationHarness()
        defer { harness.coordinator.disconnect() }

        let access = harness.coordinator.requestSimulationControlAccess(endpoint: endpoint, job: job)
        XCTAssertEqual(access, .granted(SimulationControlLease(endpoint: endpoint, generation: .init(1), job: job)))
        XCTAssertEqual(
            harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600),
            .refused(.heldBySimulationControl)
        )
        XCTAssertTrue(harness.opener.requestedPaths.isEmpty)
        XCTAssertEqual(
            harness.coordinator.commissioningRunReadiness(portPath: "/dev/cu.fake"),
            .simulationControlMustFinishFirst
        )
    }

    /// A later disconnect signal from the old simulation RX cannot release
    /// the already granted control session.
    func testS12DisconnectWhileControlSessionHeldDoesNotDropControlSession() {
        let harness = simulationHarness(script: [.closed])
        XCTAssertEqual(
            harness.coordinator.connectSimulation(serviceName: "old-rx", opener: harness.opener),
            .connecting
        )
        waitUntil { harness.coordinator.portOwner == .free }

        let access = harness.coordinator.requestSimulationControlAccess(endpoint: endpoint, job: job)
        XCTAssertEqual(access, .granted(SimulationControlLease(endpoint: endpoint, generation: .init(1), job: job)))

        harness.coordinator.disconnect()
        XCTAssertEqual(harness.coordinator.portOwner, .simulationControl)
    }
}
