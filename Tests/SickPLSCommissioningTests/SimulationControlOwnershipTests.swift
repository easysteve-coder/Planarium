import PlanariumInput
import XCTest
import SickPLSMacTransport
@testable import SickPLSCommissioning

final class SimulationControlOwnershipTests: XCTestCase {
    private let job = SimulationControlJob.setMeasurementMode(.fullScan)

    private func completion(
        generation: SimulationControlGeneration,
        closeStatus: SimulationControlCloseStatus
    ) -> SimulationControlCompletion {
        SimulationControlCompletion(
            generation: generation,
            job: job,
            result: .acknowledged,
            closeStatus: closeStatus
        )
    }

    func testS1ControlGenerationStartsAtOneAndNeverRepeats() throws {
        var ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForSimulationControl(), .granted)
        let first = try XCTUnwrap(ownership.simulationControlGeneration)
        XCTAssertEqual(first, SimulationControlGeneration(1))
        XCTAssertEqual(
            ownership.releaseSimulationControl(completion(generation: first, closeStatus: .closed)),
            .released
        )
        XCTAssertEqual(ownership.owner, .free)
        XCTAssertNil(ownership.simulationControlGeneration)

        XCTAssertEqual(ownership.claimForSimulationControl(), .granted)
        XCTAssertEqual(ownership.simulationControlGeneration, SimulationControlGeneration(2))
    }

    func testS2ControlClaimNamesEveryExistingOwnerAndAwaitingRelease() {
        var ownership = SerialPortOwnership()

        XCTAssertEqual(ownership.claimForMonitor(), .granted)
        XCTAssertEqual(ownership.claimForSimulationControl(), .refused(.heldByMonitor))

        ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForSimulation(), .granted)
        XCTAssertEqual(ownership.claimForSimulationControl(), .refused(.heldBySimulation))

        ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForCommissioning(), .granted)
        XCTAssertEqual(ownership.claimForSimulationControl(), .refused(.heldByCommissioning))

        ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForMonitor(), .granted)
        ownership.noteMonitorDisconnectRequested()
        XCTAssertEqual(ownership.claimForSimulationControl(), .refused(.awaitingRelease))
    }

    func testS3ControlSessionExcludesAllOtherClaimsAndSecondControlSession() throws {
        var ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForSimulationControl(), .granted)
        let generation = try XCTUnwrap(ownership.simulationControlGeneration)

        XCTAssertEqual(ownership.claimForMonitor(), .refused(.heldBySimulationControl))
        XCTAssertEqual(ownership.claimForSimulation(), .refused(.heldBySimulationControl))
        XCTAssertEqual(ownership.claimForCommissioning(), .refused(.heldBySimulationControl))
        XCTAssertEqual(ownership.claimForSimulationControl(), .refused(.heldBySimulationControl))
        XCTAssertEqual(ownership.owner, .simulationControl)
        XCTAssertEqual(ownership.simulationControlGeneration, generation)
    }

    func testS4StaleAndRepeatedCompletionsDoNotReleaseAnotherGeneration() throws {
        var ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForSimulationControl(), .granted)
        let first = try XCTUnwrap(ownership.simulationControlGeneration)
        XCTAssertEqual(
            ownership.releaseSimulationControl(completion(generation: first, closeStatus: .closed)),
            .released
        )
        XCTAssertEqual(ownership.claimForSimulationControl(), .granted)
        let second = try XCTUnwrap(ownership.simulationControlGeneration)

        XCTAssertEqual(
            ownership.releaseSimulationControl(completion(generation: first, closeStatus: .closed)),
            .staleGeneration
        )
        XCTAssertEqual(ownership.owner, .simulationControl)
        XCTAssertEqual(ownership.simulationControlGeneration, second)

        XCTAssertEqual(
            ownership.releaseSimulationControl(completion(generation: second, closeStatus: .closed)),
            .released
        )
        XCTAssertEqual(
            ownership.releaseSimulationControl(completion(generation: second, closeStatus: .closed)),
            .notHolding
        )
    }

    func testS5CloseFailureKeepsControlBlockedUntilTheSameGenerationCloses() throws {
        var ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForSimulationControl(), .granted)
        let generation = try XCTUnwrap(ownership.simulationControlGeneration)

        XCTAssertEqual(
            ownership.releaseSimulationControl(completion(generation: generation, closeStatus: .closeFailed)),
            .stillBlocked
        )
        XCTAssertEqual(ownership.owner, .simulationControl)
        XCTAssertEqual(ownership.simulationControlGeneration, generation)
        XCTAssertEqual(ownership.claimForMonitor(), .refused(.heldBySimulationControl))

        XCTAssertEqual(
            ownership.releaseSimulationControl(completion(generation: generation, closeStatus: .closed)),
            .released
        )
    }

    func testS6ControlReleaseNeverChangesVerifiedBaudRate() throws {
        var ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForCommissioning(), .granted)
        ownership.releaseCommissioning(verifiedBaudRate: .baud38400)
        XCTAssertEqual(ownership.verifiedBaudRate, .baud38400)

        XCTAssertEqual(ownership.claimForSimulationControl(), .granted)
        let generation = try XCTUnwrap(ownership.simulationControlGeneration)
        XCTAssertEqual(
            ownership.releaseSimulationControl(completion(generation: generation, closeStatus: .closeFailed)),
            .stillBlocked
        )
        XCTAssertEqual(ownership.verifiedBaudRate, .baud38400)
        XCTAssertEqual(
            ownership.releaseSimulationControl(completion(generation: generation, closeStatus: .closed)),
            .released
        )
        XCTAssertEqual(ownership.verifiedBaudRate, .baud38400)

        var withoutRate = SerialPortOwnership()
        XCTAssertEqual(withoutRate.claimForSimulationControl(), .granted)
        let withoutRateGeneration = try XCTUnwrap(withoutRate.simulationControlGeneration)
        _ = withoutRate.releaseSimulationControl(
            completion(generation: withoutRateGeneration, closeStatus: .closed)
        )
        XCTAssertNil(withoutRate.verifiedBaudRate)
    }

    func testS7HardwareReleaseSignalsDoNotReleaseControlSession() throws {
        var ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForSimulationControl(), .granted)
        let generation = try XCTUnwrap(ownership.simulationControlGeneration)

        ownership.noteMonitorDisconnectRequested()
        ownership.notePortReleased()

        XCTAssertEqual(ownership.owner, .simulationControl)
        XCTAssertEqual(ownership.simulationControlGeneration, generation)
    }

    func testS8SimulationEndpointRejectsPathsAndMissingAddressParts() throws {
        XCTAssertNil(SimulationEndpoint.make(serviceID: "", host: "127.0.0.1", port: 9000))
        XCTAssertNil(SimulationEndpoint.make(serviceID: "sim", host: "", port: 9000))
        XCTAssertNil(SimulationEndpoint.make(serviceID: "sim", host: "/dev/cu.x", port: 9000))
        XCTAssertNil(SimulationEndpoint.make(serviceID: "sim", host: "127.0.0.1", port: 0))

        let endpoint = try XCTUnwrap(
            SimulationEndpoint.make(serviceID: "sim|_planarium-sim._tcp|local", host: "127.0.0.1", port: 9000)
        )
        XCTAssertEqual(endpoint.serviceID, "sim|_planarium-sim._tcp|local")
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(endpoint.port, 9000)
    }
}
