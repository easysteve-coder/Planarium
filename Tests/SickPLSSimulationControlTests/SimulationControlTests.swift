import PlanariumInput
import Foundation
import Combine
import Network
import XCTest
import SickPLSCore
import SickPLSCommissioning
@testable import SickPLSMonitorKit
import SickPLSSimulationControl
import SickPLSSimulationLink
import PlanariumScannerUI

private final class FakeSimulationDiscoverer: SimulationServiceDiscovering {
    var onServicesChanged: (([SimulationService]) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

private final class FakeSimulationCoordinator: SimulationConnectionCoordinating {
    private let statusSubject = PassthroughSubject<MeasurementSessionStatus, Never>()
    private let ownerSubject = PassthroughSubject<SerialPortOwner, Never>()
    var measurementSessionStatus: MeasurementSessionStatus = .idle
    var isAwaitingPortRelease = false
    private(set) var connectSimulationCount = 0
    var measurementSessionStatusChanges: AnyPublisher<MeasurementSessionStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }
    var portOwnershipChanges: AnyPublisher<SerialPortOwner, Never> {
        ownerSubject.eraseToAnyPublisher()
    }
    func connectSimulation(serviceName: String, opener: ScanByteStreamOpening) -> SimulationConnectOutcome {
        connectSimulationCount += 1
        return .connecting
    }
    func disconnect() {}
    func requestSimulationControlAccess(endpoint: SimulationEndpoint, job: SimulationControlJob) -> SimulationControlAccessOutcome {
        .refused(.heldBySimulationControl)
    }
    func completeSimulationControl(_ completion: SimulationControlCompletion) -> SimulationControlReleaseOutcome {
        .notHolding
    }
    func publish(_ status: MeasurementSessionStatus) {
        measurementSessionStatus = status
        statusSubject.send(status)
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ value: TimeInterval) {
        lock.lock(); self.value = value; lock.unlock()
    }
}

final class SimulationControlTests: XCTestCase {
    func testOwnershipMatrixCoversBothSourcesAndReleaseOrder() {
        var ownership = SerialPortOwnership()
        XCTAssertEqual(ownership.claimForSimulation(), .granted)
        XCTAssertEqual(ownership.claimForMonitor(), .refused(.heldBySimulation))
        XCTAssertEqual(ownership.claimForCommissioning(), .refused(.heldBySimulation))

        ownership.noteMonitorDisconnectRequested()
        XCTAssertEqual(ownership.claimForSimulation(), .refused(.awaitingRelease))
        ownership.notePortReleased()
        XCTAssertEqual(ownership.owner, .free)

        XCTAssertEqual(ownership.claimForMonitor(), .granted)
        XCTAssertEqual(ownership.claimForSimulation(), .refused(.heldByMonitor))
        ownership.noteMonitorDisconnectRequested()
        ownership.notePortReleased()
        XCTAssertEqual(ownership.owner, .free)

        XCTAssertEqual(ownership.claimForSimulation(), .granted)
        ownership.notePortReleased()
        XCTAssertEqual(ownership.owner, .free)
    }

    func testEncoderProducesTheWireBytesUsedByTheNetworkSource() throws {
        let bytes = try B0TelegramEncoder.frameBytes(values: [90, 361], trailingByte: 0)
        XCTAssertEqual(bytes.first, 0x02)
        XCTAssertEqual(bytes.dropFirst().first, SimulationLinkConstants.scannerSourceAddress)
        let decoded = try XCTUnwrap(try? Frame.decodeExact(from: bytes).get())
        XCTAssertEqual(decoded.payload.last, 0)
        XCTAssertGreaterThan(bytes.count, 8)
    }

    func testNetworkOpenerAcceptsLoopbackAndReadsAnEncodedFrame() throws {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                let data = Data((try? B0TelegramEncoder.frameBytes(values: [90, 361])) ?? [])
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .global(qos: .userInitiated))
        wait(for: [ready], timeout: 2)
        guard let port = listener.port else { XCTFail("listener has no port"); return }

        let opener = NetworkScanByteStreamOpener(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            timeoutSeconds: 2
        )
        let descriptor = try opener.openStream()
        let outcome = descriptor.read(timeoutMilliseconds: 2_000)
        guard case .bytes(let received) = outcome else {
            XCTFail("expected encoded frame, got \(outcome)")
            descriptor.close()
            listener.cancel()
            return
        }
        XCTAssertEqual(received, try B0TelegramEncoder.frameBytes(values: [90, 361]))
        descriptor.close()
        listener.cancel()
    }

    func testNetworkStreamClosesAfterInjectedSilenceLimit() throws {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .global(qos: .userInitiated))
        wait(for: [ready], timeout: 2)
        guard let port = listener.port else { XCTFail("listener has no port"); return }

        let opener = NetworkScanByteStreamOpener(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            timeoutSeconds: 2,
            silenceLimitSeconds: 0
        )
        let descriptor = try opener.openStream()
        guard let stream = descriptor as? NetworkScanByteStream else {
            XCTFail("expected network stream")
            descriptor.close()
            listener.cancel()
            return
        }
        let outcome = stream.read(timeoutMilliseconds: 1_000)
        XCTAssertEqual(outcome, .closed)
        descriptor.close()
        listener.cancel()
    }

    func testNetworkStreamUsesTheExactSilenceBoundaryWithInjectedClock() throws {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: .global(qos: .userInitiated))
        wait(for: [ready], timeout: 2)
        guard let port = listener.port else { XCTFail("listener has no port"); return }

        let clock = LockedTestClock()
        let opener = NetworkScanByteStreamOpener(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            timeoutSeconds: 2,
            silenceLimitSeconds: 2,
            now: { clock.now }
        )
        let descriptor = try opener.openStream()
        clock.set(2)
        XCTAssertEqual(descriptor.read(timeoutMilliseconds: 0), .timeout)
        clock.set(2.001)
        XCTAssertEqual(descriptor.read(timeoutMilliseconds: 1_000), .closed)
        descriptor.close()
        listener.cancel()
    }

    func testSimulationControlHasNoTransmitCallOrProfileSink() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SickPLSSimulationControl/NetworkScanByteStream.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains(".send("))
        XCTAssertFalse(source.contains("performanceProfiles"))
        XCTAssertFalse(source.contains("acceptSupplementaryProfile"))
    }

    func testSimulationLinkImportsOnlyCoreAndAppHasNoSimulationSessionCall() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let linkSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/SickPLSSimulationLink/SimulationLink.swift"),
            encoding: .utf8
        )
        let imports = linkSource.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("import ") }
        XCTAssertEqual(imports, ["import SickPLSCore"])

        let appDirectory = packageRoot.appendingPathComponent("Sources/SickPLSMonitor")
        let appSources = try FileManager.default.contentsOfDirectory(at: appDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for sourceURL in appSources {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertFalse(source.contains("session.connectSimulation"), sourceURL.lastPathComponent)
        }
    }

    func testSimulationBarStateCoversEveryVisibleTransition() {
        let service = SimulationService(
            name: "Luna", endpoint: .hostPort(host: "127.0.0.1", port: 1234)
        )
        XCTAssertEqual(SimulationBarState.derive(services: [], measurement: .idle, isAwaitingPortRelease: false), .noDevices)
        XCTAssertEqual(SimulationBarState.derive(services: [service], measurement: .idle, isAwaitingPortRelease: false), .found(serviceNames: ["Luna"]))
        XCTAssertEqual(SimulationBarState.derive(services: [service], measurement: .simulation(.opening(serviceName: "Luna")), isAwaitingPortRelease: false), .connecting(serviceName: "Luna"))
        XCTAssertEqual(SimulationBarState.derive(services: [service], measurement: .simulation(.openWithoutProfile(serviceName: "Luna")), isAwaitingPortRelease: false), .waitingForFirstProfile(serviceName: "Luna"))
        XCTAssertEqual(SimulationBarState.derive(services: [service], measurement: .simulation(.streaming(serviceName: "Luna", pointCount: 361)), isAwaitingPortRelease: false), .ready(serviceName: "Luna", pointCount: 361))
        XCTAssertEqual(SimulationBarState.derive(services: [service], measurement: .simulation(.failed(serviceName: "Luna", message: "verloren")), isAwaitingPortRelease: false), .lost(serviceName: "Luna", message: "verloren"))
        XCTAssertEqual(SimulationBarState.derive(services: [service], measurement: .idle, isAwaitingPortRelease: true), .disconnecting(serviceName: nil))
    }

    func testInputSelectionIsLockedForEveryNonIdleStatus() {
        let coordinator = FakeSimulationCoordinator()
        let discoverer = FakeSimulationDiscoverer()
        let model = SimulationConnectionControlModel(coordinator: coordinator, discoverer: discoverer)
        model.selectInput(.iPhoneSimulation)
        coordinator.publish(.simulation(.opening(serviceName: "Luna")))
        model.selectInput(.scanner)
        XCTAssertEqual(model.input, .iPhoneSimulation)
        XCTAssertFalse(model.selectionPresentation.isEnabled)
        XCTAssertEqual(model.selectionPresentation.statusText, "Input cannot be changed during an active measurement session.")
        XCTAssertEqual(discoverer.startCount, 1)
    }

    func testSimulationLossIsRecoverableWithoutRestart() {
        let coordinator = FakeSimulationCoordinator()
        let discoverer = FakeSimulationDiscoverer()
        let model = SimulationConnectionControlModel(coordinator: coordinator, discoverer: discoverer)
        let service = SimulationService(name: "Luna", endpoint: .hostPort(host: "127.0.0.1", port: 1234))
        discoverer.onServicesChanged?([service])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        model.selectInput(.iPhoneSimulation)
        coordinator.publish(.simulation(.streaming(serviceName: "Luna", pointCount: 90)))
        coordinator.publish(.simulation(.failed(serviceName: "Luna", message: "2 s ohne Daten")))

        XCTAssertEqual(model.barState, .lost(serviceName: "Luna", message: "2 s ohne Daten"))
        XCTAssertTrue(model.selectionPresentation.isEnabled)
        model.connect()
        XCTAssertEqual(coordinator.connectSimulationCount, 1)
        model.startDiscovery()
        XCTAssertEqual(discoverer.startCount, 2)
        model.selectInput(.scanner)
        XCTAssertEqual(model.input, .scanner)
    }

    func testSimulationLossKeepsItsCauseVisibleWhileRecoveryIsEnabled() {
        let coordinator = FakeSimulationCoordinator()
        let model = SimulationConnectionControlModel(coordinator: coordinator, discoverer: FakeSimulationDiscoverer())
        coordinator.publish(.simulation(.failed(serviceName: "Luna", message: "Connection ended unexpectedly (end of stream).")))

        XCTAssertEqual(model.barState, .lost(serviceName: "Luna", message: "Connection ended unexpectedly (end of stream)."))
        XCTAssertTrue(model.selectionPresentation.isEnabled)
    }

    func testCachedStatusFallsBackToIdleWhenCoordinatorIsReleased() {
        var coordinator: FakeSimulationCoordinator? = FakeSimulationCoordinator()
        let model = SimulationConnectionControlModel(coordinator: coordinator!, discoverer: FakeSimulationDiscoverer())
        coordinator?.publish(.simulation(.streaming(serviceName: "Luna", pointCount: 361)))
        XCTAssertEqual(model.barState, .ready(serviceName: "Luna", pointCount: 361))
        coordinator = nil
        model.refreshState()
        XCTAssertEqual(model.barState, .noDevices)
        XCTAssertTrue(model.selectionPresentation.isEnabled)
    }

    func testSimulationBarStatePublishesOnlyForDiscreteChangesAfterReady() {
        let coordinator = FakeSimulationCoordinator()
        let model = SimulationConnectionControlModel(
            coordinator: coordinator, discoverer: FakeSimulationDiscoverer()
        )
        var publications = 0
        let cancellable = model.$barState.sink { _ in publications += 1 }
        coordinator.publish(.simulation(.streaming(serviceName: "Luna", pointCount: 361)))
        publications = 0
        for _ in 0..<100 {
            coordinator.publish(.simulation(.streaming(serviceName: "Luna", pointCount: 361)))
        }
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(model.barState, .ready(serviceName: "Luna", pointCount: 361))
        withExtendedLifetime(cancellable) {}
    }

    func testWorkspacePassesSimulationAsValueAndSimulationActionsUseTooltips() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/ContentView.swift"), encoding: .utf8)
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("let simulation: SimulationConnectionControlModel"))
        XCTAssertTrue(workspace.contains("let simulation: SimulationConnectionControlModel"))
        XCTAssertFalse(content.contains("@ObservedObject private var simulation"))
        XCTAssertFalse(workspace.contains("@ObservedObject var simulation"))
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/SimulationConnectionBarView.swift"), encoding: .utf8)
        for symbol in ["iconButton(\"link\"", "iconButton(\"arrow.clockwise\"", "iconButton(\"xmark\""] {
            XCTAssertTrue(bar.contains(symbol), "fehlendes Symbol: \(symbol)")
        }
        XCTAssertTrue(bar.contains(".help(label)"))
        XCTAssertTrue(bar.contains("case .found, .lost"))
    }

    func testBonjourAndInfoPlistContractsArePresent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSSimulationControl/SimulationConnectionControlModel.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("NWBrowser(") && source.contains(".bonjour(type: SimulationLinkConstants.bonjourServiceType"))
        XCTAssertTrue(source.contains("result.endpoint"))
        let script = try String(contentsOf: root.appendingPathComponent("scripts/make-app-bundle.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("<key>NSLocalNetworkUsageDescription</key>"))
        XCTAssertTrue(script.contains("Planarium receives simulated scanner data from the iPhone app on the same local network."))
        XCTAssertTrue(script.contains("<key>NSBonjourServices</key>"))
        XCTAssertTrue(script.contains("<string>_planarium-sim._tcp</string>"))
    }

    func testWaitingForLocalNetworkHasTheReconnectInstruction() {
        let description = InputFailurePresentation.describe(ScanByteStreamOpenError.waitingForLocalNetwork)
        XCTAssertEqual(description, "Local network access is not yet allowed. Allow it in macOS, then reconnect.")
    }

    func testIPhoneSimulationFieldIsOutsideScrollingControlsAndNamesDevice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("iOS/PlanariumSim/PlanariumSim/SimulationView.swift"), encoding: .utf8)
        let model = try String(contentsOf: root.appendingPathComponent("iOS/PlanariumSim/PlanariumSim/SimulationViewModel.swift"), encoding: .utf8)
        let field = try XCTUnwrap(view.range(of: "SimulationField(model: model)"))
        let scroll = try XCTUnwrap(view.range(of: "ScrollView {"))
        XCTAssertLessThan(field.lowerBound, scroll.lowerBound)
        XCTAssertTrue(view.contains("simulation.serviceName"))
        XCTAssertTrue(model.contains("targetEnvironment(simulator)"))
        XCTAssertTrue(model.contains("· \\(deviceKind)"))
    }

    func testIPhoneSimulationKeepsSendingWhileInactiveAndStopsInBackground() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("iOS/PlanariumSim/PlanariumSim/SimulationViewModel.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("else if phase == .background"))
        XCTAssertFalse(source.contains("else { stop() }"))
    }

    func testIPhoneSimulationRoomBackgroundDefaultsOnAndPersistsOff() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = try String(contentsOf: root.appendingPathComponent("iOS/PlanariumSim/PlanariumSim/SimulationViewModel.swift"), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent("iOS/PlanariumSim/PlanariumSim/SimulationView.swift"), encoding: .utf8)
        XCTAssertTrue(model.contains("as? Bool ?? true"))
        XCTAssertTrue(model.contains("defaults.set(roomBackground, forKey: Self.roomBackgroundDefaultsKey)"))
        XCTAssertTrue(view.contains("Toggle(\"Messfeldrand senden\", isOn: $model.roomBackground)"))
    }

    func testIPhoneSimulationConnectionStatusButtonAndFieldHalfPlaneContracts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("iOS/PlanariumSim/PlanariumSim/SimulationView.swift"), encoding: .utf8)
        let model = try String(contentsOf: root.appendingPathComponent("iOS/PlanariumSim/PlanariumSim/SimulationViewModel.swift"), encoding: .utf8)
        let touch = try String(contentsOf: root.appendingPathComponent("iOS/PlanariumSim/PlanariumSim/TouchCaptureView.swift"), encoding: .utf8)
        XCTAssertTrue(model.contains("connectionStateHandler"))
        XCTAssertTrue(model.contains("Mac verbunden · 25 Hz"))
        XCTAssertTrue(model.contains("return \"Senden aus\""))
        XCTAssertTrue(view.contains("Senden stoppen"))
        XCTAssertTrue(view.contains("Senden starten"))
        XCTAssertTrue(view.contains("scanner.y"))
        XCTAssertTrue(touch.contains("maximumY"))
        XCTAssertTrue(touch.contains("ignored"))
    }
}
