import Combine
import Foundation
import Network
import SickPLSCommissioning
import SickPLSMonitorKit
import PlanariumInput
import SickPLSSimulationLink

/// Ein Bonjour-Dienst, der als iPhone-Simulation angeboten wird.
public struct SimulationService: Identifiable, Equatable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let domain: String
    public let endpoint: NWEndpoint

    public init(name: String, type: String = SimulationLinkConstants.bonjourServiceType,
                domain: String = "local.", endpoint: NWEndpoint) {
        self.id = "\(name)|\(type)|\(domain)"
        self.name = name
        self.type = type
        self.domain = domain
        self.endpoint = endpoint
    }

    public static func == (lhs: SimulationService, rhs: SimulationService) -> Bool {
        lhs.id == rhs.id
    }
}

/// Quelle der Bonjour-Ergebnisse. Die Oberfläche startet und stoppt die
/// Suche ausdrücklich über `startDiscovery`/`stopDiscovery`.
public protocol SimulationServiceDiscovering: AnyObject {
    var onServicesChanged: (([SimulationService]) -> Void)? { get set }
    func start()
    func stop()
}

/// Echte Bonjour-Suche für das macOS-Ziel.
/// NWBrowser callbacks are serialized onto the main queue before published
/// state is touched; the unchecked marker documents that handoff boundary.
public final class BonjourSimulationServiceBrowser: SimulationServiceDiscovering, @unchecked Sendable {
    public var onServicesChanged: (([SimulationService]) -> Void)?
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "de.sick.planarium.simulation-browser")

    public init() {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        browser = NWBrowser(
            for: .bonjour(type: SimulationLinkConstants.bonjourServiceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services = results.compactMap { result -> SimulationService? in
                guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                return SimulationService(name: name, type: type, domain: domain, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            DispatchQueue.main.async { [weak self] in self?.onServicesChanged?(services) }
        }
    }

    public func start() { browser.start(queue: queue) }
    public func stop() { browser.cancel() }
}

public enum SimulationInputChoice: String, CaseIterable, Equatable, Sendable {
    case scanner
    case iPhoneSimulation

    public var title: String {
        switch self {
        case .scanner: return "Scanner"
        case .iPhoneSimulation: return "iPhone Simulation"
        }
    }
}

public struct SimulationInputSelectionPresentation: Equatable, Sendable {
    public let isEnabled: Bool
    public let statusText: String

    public static func derive(
        choice: SimulationInputChoice,
        measurement: MeasurementSessionStatus,
        isAwaitingPortRelease: Bool
    ) -> SimulationInputSelectionPresentation {
        let canSwitch: Bool
        switch measurement {
        case .idle:
            canSwitch = !isAwaitingPortRelease
        case .simulation(.failed):
            // A lost simulation has already ended and released its stream.
            // Keep the recovery actions usable until the user chooses a new
            // input or reconnects.
            canSwitch = !isAwaitingPortRelease
        case .opening, .openWithoutProfile, .streaming, .failed, .simulation:
            canSwitch = false
        }
        let status: String
        if canSwitch {
            status = "Select an input."
        } else if isAwaitingPortRelease {
            status = "Input can only be changed after the port is released."
        } else {
            status = "Input cannot be changed during an active measurement session."
        }
        return SimulationInputSelectionPresentation(isEnabled: canSwitch, statusText: status)
    }
}

public enum SimulationBarState: Equatable, Sendable {
    case noDevices
    case found(serviceNames: [String])
    case connecting(serviceName: String)
    case waitingForFirstProfile(serviceName: String)
    case ready(serviceName: String, pointCount: Int)
    case lost(serviceName: String, message: String)
    case disconnecting(serviceName: String?)

    public static func derive(
        services: [SimulationService],
        measurement: MeasurementSessionStatus,
        isAwaitingPortRelease: Bool
    ) -> SimulationBarState {
        switch measurement {
        case .simulation(.opening(let serviceName)):
            return .connecting(serviceName: serviceName)
        case .simulation(.openWithoutProfile(let serviceName)):
            return .waitingForFirstProfile(serviceName: serviceName)
        case .simulation(.streaming(let serviceName, let pointCount)):
            return .ready(serviceName: serviceName, pointCount: pointCount)
        case .simulation(.failed(let serviceName, let message)):
            return .lost(serviceName: serviceName, message: message)
        case .idle:
            if isAwaitingPortRelease { return .disconnecting(serviceName: nil) }
            if services.isEmpty { return .noDevices }
            return .found(serviceNames: services.map(\.name).sorted())
        case .opening, .openWithoutProfile, .streaming, .failed:
            return .disconnecting(serviceName: nil)
        }
    }
}

public protocol SimulationConnectionCoordinating: AnyObject {
    var measurementSessionStatus: MeasurementSessionStatus { get }
    var isAwaitingPortRelease: Bool { get }
    var measurementSessionStatusChanges: AnyPublisher<MeasurementSessionStatus, Never> { get }
    var portOwnershipChanges: AnyPublisher<SerialPortOwner, Never> { get }
    @discardableResult
    func connectSimulation(serviceName: String, opener: ScanByteStreamOpening) -> SimulationConnectOutcome
    func disconnect()
    // SIM-P2c-2b
    @discardableResult
    func requestSimulationControlAccess(endpoint: SimulationEndpoint, job: SimulationControlJob) -> SimulationControlAccessOutcome
    @discardableResult
    func completeSimulationControl(_ completion: SimulationControlCompletion) -> SimulationControlReleaseOutcome
}

extension InputOwner: @preconcurrency SimulationConnectionCoordinating {
    public var portOwnershipChanges: AnyPublisher<SerialPortOwner, Never> {
        $portOwner.eraseToAnyPublisher()
    }
}

/// Reines, app-unabhängiges Bedienmodell für Eingangswahl und Simulation.
/// The model is observed and mutated on the main actor by SwiftUI. Network
/// callbacks only enqueue that main-thread handoff.
public final class SimulationConnectionControlModel: ObservableObject, @unchecked Sendable {
    @Published public private(set) var services: [SimulationService] = []
    @Published public private(set) var barState: SimulationBarState
    @Published public private(set) var input: SimulationInputChoice = .scanner
    @Published public var selectedServiceID: SimulationService.ID? {
        didSet {
            if oldValue != selectedServiceID {
                resolvedEndpoint = nil
                resetModeSwitchIfNotControlled()
            }
        }
    }
    /// SIM-P2c-2b: Zustand eines Moduswechsels.
    @Published public private(set) var modeSwitch: SimulationModeSwitchState = .idle
    /// SIM-P2c-2b: Aus der laufenden RX-Verbindung aufgelöstes Ziel des
    /// gewählten Dienstes; `nil`, solange keines bekannt ist.
    @Published public private(set) var resolvedEndpoint: SimulationEndpoint?
    public let diagnostics: MeasurementDiagnosticsRecorder

    private var measurement: MeasurementSessionStatus
    private weak var coordinator: SimulationConnectionCoordinating?
    private let discoverer: SimulationServiceDiscovering
    private let modeRunner: SimulationModeRunning
    private var cancellables: Set<AnyCancellable> = []

    public init(
        coordinator: SimulationConnectionCoordinating,
        discoverer: SimulationServiceDiscovering = BonjourSimulationServiceBrowser(),
        modeRunner: SimulationModeRunning = NetworkSimulationModeRunner(),
        diagnostics: MeasurementDiagnosticsRecorder = MeasurementDiagnosticsRecorder()
    ) {
        self.coordinator = coordinator
        measurement = coordinator.measurementSessionStatus
        self.discoverer = discoverer
        self.modeRunner = modeRunner
        self.diagnostics = diagnostics
        self.barState = .noDevices
        discoverer.onServicesChanged = { [weak self] services in
            DispatchQueue.main.async { [weak self] in
                self?.services = services
                self?.selectedServiceID = self?.selectedServiceID.flatMap { id in
                    services.contains { $0.id == id } ? id : services.first?.id
                } ?? services.first?.id
                self?.refreshState()
            }
        }
        coordinator.measurementSessionStatusChanges
            .sink { [weak self] status in self?.measurement = status; self?.refreshState() }
            .store(in: &cancellables)
        coordinator.portOwnershipChanges
            .sink { [weak self] owner in
                self?.refreshState()
                if owner == .free { self?.retryModeRequestIfNeeded() }
            }
            .store(in: &cancellables)
        refreshState()
    }

    public var selectionPresentation: SimulationInputSelectionPresentation {
        SimulationInputSelectionPresentation.derive(
            choice: input,
            measurement: coordinator == nil ? .idle : measurement,
            isAwaitingPortRelease: coordinator?.isAwaitingPortRelease ?? false
        )
    }

    public var selectedService: SimulationService? {
        services.first { $0.id == selectedServiceID }
    }

    public func selectInput(_ choice: SimulationInputChoice) {
        guard selectionPresentation.isEnabled, input != choice else { return }
        coordinator?.disconnect()
        input = choice
        resetModeSwitchIfNotControlled()
        if choice == .iPhoneSimulation { startDiscovery() } else { stopDiscovery() }
    }

    public func startDiscovery() { discoverer.start() }
    public func stopDiscovery() { discoverer.stop() }

    public func connect() {
        guard let service = selectedService, input == .iPhoneSimulation else { return }
        let serviceID = service.id
        let opener = NetworkScanByteStreamOpener(
            endpoint: service.endpoint,
            diagnostics: diagnostics,
            onResolvedRemote: { [weak self] host, port in
                guard let target = self else { return }
                DispatchQueue.main.async { [weak target] in
                    target?.noteResolvedRemote(serviceID: serviceID, host: host, port: port)
                }
            }
        )
        _ = coordinator?.connectSimulation(serviceName: service.name, opener: opener)
        refreshState()
    }

    public func disconnect() {
        resetModeSwitchIfNotControlled()
        coordinator?.disconnect()
        refreshState()
    }

    // MARK: - Moduswechsel (SIM-P2c-2b)

    /// Ob die Knöpfe aktiv sind. Das Ziel muss aus der laufenden RX-Verbindung
    /// aufgelöst worden sein; ein Bonjour-Dienst allein genügt nicht.
    public var canSwitchMode: Bool {
        guard input == .iPhoneSimulation, resolvedEndpoint != nil else { return false }
        switch barState {
        case .found, .lost, .ready, .waitingForFirstProfile:
            switch modeSwitch {
            case .idle, .finished:
                return true
            case .awaitingRelease, .running, .blocked:
                return false
            }
        default:
            return false
        }
    }

    /// Startet einen Moduswechsel auf dem Main-Kontext; der eigentliche
    /// Transportlauf wird vom Runner auf einer Arbeitsqueue ausgeführt.
    public func switchMode(_ mode: SimulationMeasurementMode) {
        guard canSwitchMode, let endpoint = resolvedEndpoint else { return }
        let job = SimulationControlJob.setMeasurementMode(mode)
        switch coordinator?.requestSimulationControlAccess(endpoint: endpoint, job: job) {
        case .granted(let lease):
            modeSwitch = .running(mode)
            modeLease = lease
            retryWasUsed = false
            modeRunner.run(lease: lease) { [weak self] completion in
                guard let target = self else { return }
                DispatchQueue.main.async { [weak target] in
                    target?.handleModeCompletion(completion, mode: mode)
                }
            }
        case .awaitingRelease:
            modeSwitch = .awaitingRelease(mode)
        case .refused:
            modeSwitch = .finished(mode, .transportFailed)
        case .none:
            modeSwitch = .finished(mode, .transportFailed)
        }
    }

    /// Statustext zu einem Moduswechsel; `nil` bei `.idle`.
    public static func modeSwitchText(_ state: SimulationModeSwitchState) -> String? {
        func modeName(_ mode: SimulationMeasurementMode) -> String {
            switch mode {
            case .fullScan: return "All measurements continuously"
            case .minimumPerSegment: return "Minimum measurements continuously"
            }
        }
        switch state {
        case .idle:
            return nil
        case .awaitingRelease:
            return "Disconnecting measurement for mode switch…"
        case .running(let mode):
            return "Switching to \(modeName(mode))…"
        case .finished(let mode, let result):
            switch result {
            case .acknowledged: return "\(modeName(mode)): Command confirmed."
            case .rejected: return "\(modeName(mode)): Rejected by device."
            case .timedOut: return "\(modeName(mode)): No response."
            case .transportFailed: return "\(modeName(mode)): Connection lost."
            }
        case .blocked:
            return "Connection to simulation could not be cleanly disconnected – please wait."
        }
    }

    internal func noteResolvedRemote(serviceID: String, host: String, port: UInt16) {
        guard selectedServiceID == serviceID,
              let endpoint = SimulationEndpoint.make(serviceID: serviceID, host: host, port: port)
        else { return }
        resolvedEndpoint = endpoint
    }

    private var modeLease: SimulationControlLease?
    private var retryWasUsed = false

    private func handleModeCompletion(_ completion: SimulationControlCompletion, mode: SimulationMeasurementMode) {
        guard let coordinator else { return }
        let outcome = coordinator.completeSimulationControl(completion)
        switch outcome {
        case .released:
            modeSwitch = .finished(mode, completion.result)
            modeLease = nil
            if mode != .minimumPerSegment || completion.result != .acknowledged {
                connect()
            }
        case .stillBlocked:
            modeSwitch = .blocked(mode)
            guard !retryWasUsed, let lease = modeLease else { return }
            retryWasUsed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.modeRunner.retryClose(lease: lease) { completion in
                    DispatchQueue.main.async { self.handleModeCompletion(completion, mode: mode) }
                }
            }
        case .staleGeneration, .notHolding:
            modeSwitch = .finished(mode, .transportFailed)
            modeLease = nil
        }
    }

    public func refreshState() {
        let nextState = SimulationBarState.derive(
            services: services,
            measurement: coordinator == nil ? .idle : measurement,
            isAwaitingPortRelease: coordinator?.isAwaitingPortRelease ?? false
        )
        if nextState != barState,
           isConnectedBarState(barState),
           isLossOrDisconnectState(nextState) {
            resetModeSwitchIfNotControlled(preserveMinimumAcknowledged: true)
        }
        guard nextState != barState else { return }
        barState = nextState
    }

    private func resetModeSwitchIfNotControlled(preserveMinimumAcknowledged: Bool = false) {
        switch modeSwitch {
        case .awaitingRelease, .running, .blocked:
            return
        case .idle:
            modeSwitch = .idle
        case .finished(.minimumPerSegment, .acknowledged) where preserveMinimumAcknowledged:
            return
        case .finished:
            modeSwitch = .idle
        }
    }

    private func isConnectedBarState(_ state: SimulationBarState) -> Bool {
        switch state {
        case .ready, .waitingForFirstProfile:
            return true
        case .noDevices, .found, .connecting, .lost, .disconnecting:
            return false
        }
    }

    private func isLossOrDisconnectState(_ state: SimulationBarState) -> Bool {
        switch state {
        case .noDevices, .found, .lost, .disconnecting:
            return true
        case .connecting, .waitingForFirstProfile, .ready:
            return false
        }
    }

    private func retryModeRequestIfNeeded() {
        guard case .awaitingRelease(let mode) = modeSwitch,
              let endpoint = resolvedEndpoint else { return }
        let job = SimulationControlJob.setMeasurementMode(mode)
        switch coordinator?.requestSimulationControlAccess(endpoint: endpoint, job: job) {
        case .granted(let lease):
            modeSwitch = .running(mode)
            modeLease = lease
            retryWasUsed = false
            modeRunner.run(lease: lease) { [weak self] completion in
                guard let target = self else { return }
                DispatchQueue.main.async { [weak target] in
                    target?.handleModeCompletion(completion, mode: mode)
                }
            }
        case .awaitingRelease, .refused, .none:
            break
        }
    }
}
