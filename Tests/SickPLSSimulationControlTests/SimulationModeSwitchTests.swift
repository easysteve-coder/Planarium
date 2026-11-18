import PlanariumInput
import Combine
import Foundation
import Network
import XCTest
import SickPLSCommissioning
import PlanariumScannerUI
@testable import SickPLSMonitorKit
@testable import SickPLSSimulationControl
import SickPLSSimulationLink

private final class ModeSwitchDiscoverer: SimulationServiceDiscovering {
    var onServicesChanged: (([SimulationService]) -> Void)?
    func start() {}
    func stop() {}

    func publish(_ services: [SimulationService]) {
        onServicesChanged?(services)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
}

private final class ModeSwitchCoordinator: SimulationConnectionCoordinating {
    private let statusSubject = PassthroughSubject<MeasurementSessionStatus, Never>()
    private let ownerSubject = PassthroughSubject<SerialPortOwner, Never>()

    var measurementSessionStatus: MeasurementSessionStatus = .idle
    var isAwaitingPortRelease = false
    var accessResults: [SimulationControlAccessOutcome] = []
    var releaseResults: [SimulationControlReleaseOutcome] = []
    private(set) var accessCount = 0
    private(set) var completionCount = 0
    private(set) var connectSimulationCount = 0
    var openers: [ScanByteStreamOpening] = []

    var measurementSessionStatusChanges: AnyPublisher<MeasurementSessionStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    var portOwnershipChanges: AnyPublisher<SerialPortOwner, Never> {
        ownerSubject.eraseToAnyPublisher()
    }

    func connectSimulation(serviceName: String, opener: ScanByteStreamOpening) -> SimulationConnectOutcome {
        connectSimulationCount += 1
        openers.append(opener)
        return .connecting
    }

    func disconnect() {}

    func requestSimulationControlAccess(
        endpoint: SimulationEndpoint,
        job: SimulationControlJob
    ) -> SimulationControlAccessOutcome {
        accessCount += 1
        return accessResults.isEmpty ? .refused(.heldBySimulationControl) : accessResults.removeFirst()
    }

    func completeSimulationControl(_ completion: SimulationControlCompletion) -> SimulationControlReleaseOutcome {
        completionCount += 1
        return releaseResults.isEmpty ? .notHolding : releaseResults.removeFirst()
    }

    func publish(_ status: MeasurementSessionStatus) {
        measurementSessionStatus = status
        statusSubject.send(status)
    }

    func publishOwnership(_ owner: SerialPortOwner) {
        ownerSubject.send(owner)
    }
}

private final class ModeSwitchRunner: SimulationModeRunning {
    private(set) var runLeases: [SimulationControlLease] = []
    private(set) var retryLeases: [SimulationControlLease] = []
    var runCompletion: ((SimulationControlCompletion) -> Void)?
    var retryCompletion: ((SimulationControlCompletion) -> Void)?

    func run(lease: SimulationControlLease, completion: @escaping (SimulationControlCompletion) -> Void) {
        runLeases.append(lease)
        runCompletion = completion
    }

    func retryClose(lease: SimulationControlLease, completion: @escaping (SimulationControlCompletion) -> Void) {
        retryLeases.append(lease)
        retryCompletion = completion
    }
}

private final class ResolvedCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, UInt16)] = []

    func append(host: String, port: UInt16) {
        lock.lock()
        values.append((host, port))
        lock.unlock()
    }

    var snapshot: [(String, UInt16)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class SimulationModeSwitchTests: XCTestCase {
    private let endpoint = SimulationEndpoint.make(serviceID: "Luna|_planarium-sim._tcp|local.", host: "127.0.0.1", port: 45123)!

    private func makeModel(
        coordinator: ModeSwitchCoordinator,
        discoverer: ModeSwitchDiscoverer,
        runner: ModeSwitchRunner = ModeSwitchRunner()
    ) -> SimulationConnectionControlModel {
        let model = SimulationConnectionControlModel(
            coordinator: coordinator,
            discoverer: discoverer,
            modeRunner: runner
        )
        let service = SimulationService(
            name: "Luna",
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint.port)!)
        )
        discoverer.publish([service])
        model.selectInput(.iPhoneSimulation)
        coordinator.publish(.simulation(.streaming(serviceName: "Luna", pointCount: 361)))
        model.noteResolvedRemote(serviceID: service.id, host: "127.0.0.1", port: endpoint.port)
        return model
    }

    private func grantedLease(mode: SimulationMeasurementMode = .fullScan) -> SimulationControlLease {
        SimulationControlLease(
            endpoint: endpoint,
            generation: SimulationControlGeneration(1),
            job: .setMeasurementMode(mode)
        )
    }

    private func completion(
        lease: SimulationControlLease,
        result: SimulationControlJobResult = .acknowledged,
        closeStatus: SimulationControlCloseStatus = .closed
    ) -> SimulationControlCompletion {
        SimulationControlCompletion(
            generation: lease.generation,
            job: lease.job,
            result: result,
            closeStatus: closeStatus
        )
    }

    func testCanSwitchModeRequiresSimulationReadyResolvedEndpointAndIdleState() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let runner = ModeSwitchRunner()
        let model = makeModel(coordinator: coordinator, discoverer: discoverer, runner: runner)

        XCTAssertTrue(model.canSwitchMode, "Simulation + ready + Ziel + idle muss aktiv sein")

        let scannerCoordinator = ModeSwitchCoordinator()
        let scannerDiscoverer = ModeSwitchDiscoverer()
        let scannerModel = SimulationConnectionControlModel(
            coordinator: scannerCoordinator,
            discoverer: scannerDiscoverer,
            modeRunner: ModeSwitchRunner()
        )
        let scannerService = SimulationService(name: "Luna", endpoint: .hostPort(host: "127.0.0.1", port: 45123))
        scannerDiscoverer.publish([scannerService])
        scannerCoordinator.publish(.simulation(.streaming(serviceName: "Luna", pointCount: 361)))
        scannerModel.noteResolvedRemote(serviceID: scannerService.id, host: "127.0.0.1", port: 45123)
        XCTAssertFalse(scannerModel.canSwitchMode, "Scanner gesperrt")

        let openingCoordinator = ModeSwitchCoordinator()
        let openingDiscoverer = ModeSwitchDiscoverer()
        let openingModel = makeModel(coordinator: openingCoordinator, discoverer: openingDiscoverer)
        openingCoordinator.publish(.simulation(.opening(serviceName: "Luna")))
        XCTAssertFalse(openingModel.canSwitchMode, "während Öffnen gesperrt")

        let serviceChangeCoordinator = ModeSwitchCoordinator()
        let serviceChangeDiscoverer = ModeSwitchDiscoverer()
        let serviceChangeModel = makeModel(coordinator: serviceChangeCoordinator, discoverer: serviceChangeDiscoverer)
        serviceChangeDiscoverer.publish([SimulationService(name: "Other", endpoint: .hostPort(host: "127.0.0.1", port: 45124))])
        XCTAssertFalse(serviceChangeModel.canSwitchMode, "Dienstwechsel sperrt")

        let modeCoordinator = ModeSwitchCoordinator()
        let modeDiscoverer = ModeSwitchDiscoverer()
        let modeModel = makeModel(coordinator: modeCoordinator, discoverer: modeDiscoverer)
        modeCoordinator.accessResults = [.awaitingRelease]
        modeModel.switchMode(.fullScan)
        XCTAssertEqual(modeModel.modeSwitch, .awaitingRelease(.fullScan))
        XCTAssertFalse(modeModel.canSwitchMode, "nicht-idle Moduswechsel sperrt")
    }

    func testAwaitingReleaseRetriesOnceThenRunsAndReconnectsAfterRelease() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let runner = ModeSwitchRunner()
        let model = makeModel(coordinator: coordinator, discoverer: discoverer, runner: runner)
        let lease = grantedLease()
        coordinator.accessResults = [.awaitingRelease, .granted(lease)]
        coordinator.releaseResults = [.released]

        XCTAssertTrue(model.canSwitchMode)
        model.switchMode(.fullScan)
        XCTAssertEqual(model.modeSwitch, .awaitingRelease(.fullScan))
        coordinator.publishOwnership(.free)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(coordinator.accessCount, 2)
        XCTAssertEqual(model.modeSwitch, .running(.fullScan))
        XCTAssertEqual(runner.runLeases, [lease])

        runner.runCompletion?(completion(lease: lease))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(coordinator.completionCount, 1)
        XCTAssertEqual(model.modeSwitch, .finished(.fullScan, .acknowledged))
        XCTAssertEqual(coordinator.connectSimulationCount, 1)
    }

    func testStillBlockedRetriesCloseOnceAndSecondFailureStaysBlocked() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let runner = ModeSwitchRunner()
        let model = makeModel(coordinator: coordinator, discoverer: discoverer, runner: runner)
        let lease = grantedLease()
        coordinator.accessResults = [.granted(lease)]
        coordinator.releaseResults = [.stillBlocked, .stillBlocked]

        XCTAssertTrue(model.canSwitchMode)
        model.switchMode(.fullScan)
        XCTAssertEqual(model.modeSwitch, .running(.fullScan))
        runner.runCompletion?(completion(lease: lease, closeStatus: .closeFailed))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(model.modeSwitch, .blocked(.fullScan))
        let retry = expectation(description: "exactly one retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            XCTAssertEqual(runner.retryLeases, [lease])
            runner.retryCompletion?(self.completion(lease: lease, closeStatus: .closeFailed))
            retry.fulfill()
        }
        wait(for: [retry], timeout: 1.0)
        XCTAssertEqual(model.modeSwitch, .blocked(.fullScan))
        XCTAssertEqual(runner.retryLeases.count, 1)
    }

    func testRefusedFinishesTransportFailedWithoutRunOrReconnect() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let runner = ModeSwitchRunner()
        let model = makeModel(coordinator: coordinator, discoverer: discoverer, runner: runner)
        coordinator.accessResults = [.refused(.heldByMonitor)]

        XCTAssertTrue(model.canSwitchMode)
        model.switchMode(.fullScan)
        XCTAssertEqual(model.modeSwitch, .finished(.fullScan, .transportFailed))
        XCTAssertTrue(runner.runLeases.isEmpty)
        XCTAssertEqual(coordinator.connectSimulationCount, 0)
    }

    func testSecondFreeOwnershipNotificationDoesNotRequestWhileRunning() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let runner = ModeSwitchRunner()
        let model = makeModel(coordinator: coordinator, discoverer: discoverer, runner: runner)
        let lease = grantedLease()
        coordinator.accessResults = [.granted(lease)]

        XCTAssertTrue(model.canSwitchMode)
        model.switchMode(.fullScan)
        XCTAssertEqual(model.modeSwitch, .running(.fullScan))
        coordinator.publishOwnership(.free)
        coordinator.publishOwnership(.free)
        XCTAssertEqual(coordinator.accessCount, 1)
    }

    func testChangingSelectedServiceClearsResolvedEndpointAndDisablesSwitching() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let model = makeModel(coordinator: coordinator, discoverer: discoverer)
        let other = SimulationService(name: "Other", endpoint: .hostPort(host: "127.0.0.1", port: 45124))

        XCTAssertNotNil(model.resolvedEndpoint)
        discoverer.publish([other])
        XCTAssertNil(model.resolvedEndpoint)
        XCTAssertFalse(model.canSwitchMode)
    }

    func testModeSwitchTextCoversAllResultsAndMinimumModeNotice() {
        XCTAssertNil(SimulationConnectionControlModel.modeSwitchText(.idle))
        XCTAssertEqual(
            SimulationConnectionControlModel.modeSwitchText(.awaitingRelease(.fullScan)),
            "Disconnecting measurement for mode switch…"
        )
        XCTAssertEqual(
            SimulationConnectionControlModel.modeSwitchText(.running(.minimumPerSegment)),
            "Switching to Minimum measurements continuously…"
        )
        XCTAssertEqual(
            SimulationConnectionControlModel.modeSwitchText(.finished(.fullScan, .acknowledged)),
            "All measurements continuously: Command confirmed."
        )
        XCTAssertEqual(
            SimulationConnectionControlModel.modeSwitchText(.finished(.minimumPerSegment, .rejected)),
            "Minimum measurements continuously: Rejected by device."
        )
        XCTAssertEqual(
            SimulationConnectionControlModel.modeSwitchText(.finished(.fullScan, .timedOut)),
            "All measurements continuously: No response."
        )
        XCTAssertEqual(
            SimulationConnectionControlModel.modeSwitchText(.finished(.fullScan, .transportFailed)),
            "All measurements continuously: Connection lost."
        )
        XCTAssertEqual(
            SimulationConnectionControlModel.modeSwitchText(.blocked(.fullScan)),
            "Connection to simulation could not be cleanly disconnected – please wait."
        )
    }

    func testNetworkOpenerReportsResolvedRemoteExactlyOnceAfterReady() throws {
        let listener = try NWListener(using: .tcp)
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
        }
        listener.start(queue: .global(qos: .userInitiated))
        wait(for: [ready], timeout: 2)
        guard let port = listener.port else { XCTFail("listener has no port"); return }

        let resolved = expectation(description: "resolved remote")
        let calls = ResolvedCallBox()
        let opener = NetworkScanByteStreamOpener(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            timeoutSeconds: 2,
            onResolvedRemote: { host, resolvedPort in
                calls.append(host: host, port: resolvedPort)
                resolved.fulfill()
            }
        )
        let descriptor = try opener.openStream()
        wait(for: [resolved], timeout: 2)
        XCTAssertEqual(calls.snapshot.count, 1)
        XCTAssertEqual(calls.snapshot.first?.1, port.rawValue)
        descriptor.close()
        listener.cancel()
    }

    func testFinishedResultResetsAfterConnectionLossAndDoesNotHideBarStatus() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let runner = ModeSwitchRunner()
        let model = makeModel(coordinator: coordinator, discoverer: discoverer, runner: runner)
        let lease = grantedLease()
        coordinator.accessResults = [.granted(lease)]
        coordinator.releaseResults = [.released]

        model.switchMode(.fullScan)
        runner.runCompletion?(completion(lease: lease))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(model.modeSwitch, .finished(.fullScan, .acknowledged))

        coordinator.publish(.simulation(.failed(serviceName: "Luna", message: "Verbindung verloren")))
        XCTAssertEqual(model.modeSwitch, .idle)
        XCTAssertEqual(model.barState, .lost(serviceName: "Luna", message: "Verbindung verloren"))
    }

    func testControlledDisconnectKeepsModeSwitchStateDuringAwaitingRelease() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let model = makeModel(coordinator: coordinator, discoverer: discoverer)
        coordinator.accessResults = [.awaitingRelease]

        model.switchMode(.fullScan)
        XCTAssertEqual(model.modeSwitch, .awaitingRelease(.fullScan))
        coordinator.publish(.simulation(.opening(serviceName: "Luna")))
        XCTAssertEqual(model.modeSwitch, .awaitingRelease(.fullScan))
    }

    func testMinimumModeAcknowledgementDoesNotReconnect() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let runner = ModeSwitchRunner()
        let model = makeModel(coordinator: coordinator, discoverer: discoverer, runner: runner)
        let lease = grantedLease(mode: .minimumPerSegment)
        coordinator.accessResults = [.granted(lease)]
        coordinator.releaseResults = [.released]

        model.switchMode(.minimumPerSegment)
        runner.runCompletion?(completion(lease: lease))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(model.modeSwitch, .finished(.minimumPerSegment, .acknowledged))
        XCTAssertEqual(coordinator.connectSimulationCount, 0)
    }

    func testMinimumModeAcknowledgementSurvivesLossAndExplainsSilence() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let runner = ModeSwitchRunner()
        let model = makeModel(coordinator: coordinator, discoverer: discoverer, runner: runner)
        let lease = grantedLease(mode: .minimumPerSegment)
        coordinator.accessResults = [.granted(lease)]
        coordinator.releaseResults = [.released]

        model.switchMode(.minimumPerSegment)
        runner.runCompletion?(completion(lease: lease))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        coordinator.publish(.simulation(.failed(serviceName: "Luna", message: "2 s ohne Profile")))

        XCTAssertEqual(model.modeSwitch, .finished(.minimumPerSegment, .acknowledged))
        XCTAssertEqual(model.barState, .lost(serviceName: "Luna", message: "2 s ohne Profile"))
    }

    func testResolvedTargetAllowsReturnToFullModeFromFoundAndLost() {
        for status in [
            MeasurementSessionStatus.idle,
            .simulation(.failed(serviceName: "Luna", message: "verloren"))
        ] {
            let coordinator = ModeSwitchCoordinator()
            let discoverer = ModeSwitchDiscoverer()
            let runner = ModeSwitchRunner()
            let model = makeModel(coordinator: coordinator, discoverer: discoverer, runner: runner)
            coordinator.publish(status)
            XCTAssertTrue(model.canSwitchMode)
            let lease = grantedLease()
            coordinator.accessResults = [.granted(lease)]
            coordinator.releaseResults = [.released]

            model.switchMode(.fullScan)
            runner.runCompletion?(completion(lease: lease))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertEqual(coordinator.connectSimulationCount, 1)
        }
    }

    func testFoundWithoutResolvedTargetCannotSwitchMode() {
        let coordinator = ModeSwitchCoordinator()
        let discoverer = ModeSwitchDiscoverer()
        let model = SimulationConnectionControlModel(
            coordinator: coordinator,
            discoverer: discoverer,
            modeRunner: ModeSwitchRunner()
        )
        discoverer.publish([SimulationService(name: "Luna", endpoint: .hostPort(host: "127.0.0.1", port: 45123))])
        model.selectInput(.iPhoneSimulation)
        coordinator.publish(.idle)

        XCTAssertEqual(model.barState, .found(serviceNames: ["Luna"]))
        XCTAssertNil(model.resolvedEndpoint)
        XCTAssertFalse(model.canSwitchMode)
    }
}
