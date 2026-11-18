import Foundation
import Network
import SickPLSCommissioning
import SickPLSMacTransport

// SIM-P2b: Netzwerktransport für die Simulations-Steuersitzung.
//
// Vertrag (Review SIM-P2, Abschnitt P2b):
// - Nur der ausgewählte `SimulationEndpoint`; kein Serialfallback, kein `portPath`.
// - `openPort(baudRate:)` ist geerbte Form: Baud hat auf TCP keine Wirkung und
//   belegt nichts.
// - `closePort()` kehrt erst zurück, wenn die Verbindung terminal ist
//   (`.cancelled`), oder wirft nach `closeTimeout`. Danach liefert diese
//   Generation keine Bytes mehr, und ausstehende Operationen sind entwertet.
// - Die blockierenden Aufrufe laufen auf dem Arbeitskontext des Aufrufers
//   (Commissioning-Queue). Netzwerk-Callbacks laufen auf einer eigenen Queue.
//   Main darf nie blockieren.
//
// Belegt durch Loopback-Spike des Supervisors (03.10.2026, 3 Runden):
// `.cancelled` kam nach < 1 ms; ein ausstehendes `receive` endete vorher mit
// `done` oder POSIX 89; ein `send` nach `cancel` endete mit POSIX 89.

/// Zustand der Netzwerkverbindung, unabhängig von `NWConnection`.
public enum SimulationNetworkConnectionState: Equatable, Sendable {
    case preparing
    case ready
    case waiting(String)
    case failed(String)
    case cancelled
}

/// Testbare Grenze um genau eine Netzwerkverbindung. Alle Callbacks laufen
/// auf der bei `start(queue:)` übergebenen Queue.
public protocol SimulationNetworkConnection: AnyObject {
    func start(queue: DispatchQueue, stateHandler: @escaping (SimulationNetworkConnectionState) -> Void)
    func send(_ bytes: [UInt8], completion: @escaping (_ error: String?) -> Void)
    /// `isComplete` = Gegenseite hat geschlossen.
    func receive(
        maximumLength: Int,
        completion: @escaping (_ bytes: [UInt8], _ isComplete: Bool, _ error: String?) -> Void
    )
    func cancel()
}

public protocol SimulationNetworkConnectionMaking {
    func makeConnection(to endpoint: SimulationEndpoint) -> SimulationNetworkConnection
}

/// Fristen und Grenzen. Alle endlich.
public struct NetworkCommissioningTransportLimits: Equatable, Sendable {
    public var openTimeoutMilliseconds: Int
    public var writeTimeoutMilliseconds: Int
    public var closeTimeoutMilliseconds: Int
    public var receiveBufferLimit: Int

    public init(
        openTimeoutMilliseconds: Int = 2_000,
        writeTimeoutMilliseconds: Int = 1_000,
        closeTimeoutMilliseconds: Int = 1_000,
        receiveBufferLimit: Int = 64 * 1024
    ) {
        self.openTimeoutMilliseconds = openTimeoutMilliseconds
        self.writeTimeoutMilliseconds = writeTimeoutMilliseconds
        self.closeTimeoutMilliseconds = closeTimeoutMilliseconds
        self.receiveBufferLimit = receiveBufferLimit
    }

    public static let standard = NetworkCommissioningTransportLimits()
}

/// Fehler, die nur der Netzwerktransport kennt. Der Executor behandelt
/// jeden geworfenen Fehler aus `closePort()` als gescheitertes Schließen.
public enum NetworkCommissioningTransportError: Error, Equatable, Sendable {
    /// `.cancelled` kam nicht innerhalb der Frist. Der Besitz bleibt gesperrt.
    case closeTimedOut
    /// Der Empfangspuffer hat seine Grenze überschritten; die Generation ist
    /// beendet.
    case receiveBufferOverflow
}

/// `CommissioningTransport` über eine `SimulationNetworkConnection`.
/// Der interne Zustand ist durch einen Lock geschützt; Callbacks prüfen die
/// Generation, bevor sie etwas ändern.
public final class NetworkCommissioningTransport: CommissioningTransport, @unchecked Sendable {
    public let endpoint: SimulationEndpoint
    private let factory: SimulationNetworkConnectionMaking
    private let limits: NetworkCommissioningTransportLimits
    private let callbackQueue = DispatchQueue(label: "de.sick.planarium.simulation-control.network")
    private let condition = NSCondition()
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: GenerationState?

    private final class GenerationState {
        let number: UInt64
        let connection: SimulationNetworkConnection
        var ready = false
        var openFinished = false
        var openFailure: String?
        var cancelled = false
        var terminal = false
        var unusable = false
        var buffer: [UInt8] = []

        init(number: UInt64, connection: SimulationNetworkConnection) {
            self.number = number
            self.connection = connection
        }
    }

    private final class SendWait {
        let semaphore = DispatchSemaphore(value: 0)
        var error: String?
    }

    public init(
        endpoint: SimulationEndpoint,
        factory: SimulationNetworkConnectionMaking,
        limits: NetworkCommissioningTransportLimits = .standard
    ) {
        self.endpoint = endpoint
        self.factory = factory
        self.limits = limits
    }

    public func openPort(baudRate: SerialPortBaudRate) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        dispatchPrecondition(condition: .notOnQueue(callbackQueue))
        condition.lock()
        guard activeGeneration == nil else {
            condition.unlock()
            throw CommissioningTransportError.portAlreadyOpen
        }
        nextGeneration &+= 1
        let state = GenerationState(
            number: nextGeneration,
            connection: factory.makeConnection(to: endpoint)
        )
        activeGeneration = state
        condition.unlock()

        state.connection.start(queue: callbackQueue) { [weak self, state] connectionState in
            guard let self else { return }
            self.handle(connectionState, for: state)
        }

        condition.lock()
        let opened = waitForStateLocked(state, until: Date().addingTimeInterval(milliseconds(limits.openTimeoutMilliseconds))) {
            state.openFinished
        }
        let failure = state.openFailure
        condition.unlock()

        guard opened, state.ready else {
            state.connection.cancel()
            condition.lock()
            let cancelled = waitForStateLocked(state, until: Date().addingTimeInterval(milliseconds(limits.closeTimeoutMilliseconds))) {
                state.cancelled
            }
            if cancelled, activeGeneration === state {
                activeGeneration = nil
            }
            condition.unlock()
            if !cancelled {
                throw NetworkCommissioningTransportError.closeTimedOut
            }
            throw CommissioningTransportError.openFailed(failure ?? "not ready")
        }
    }

    public func closePort() throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        dispatchPrecondition(condition: .notOnQueue(callbackQueue))
        condition.lock()
        guard let state = activeGeneration else {
            condition.unlock()
            return
        }
        let alreadyCancelled = state.cancelled
        condition.unlock()
        if !alreadyCancelled {
            state.connection.cancel()
        }
        condition.lock()
        let cancelled = waitForStateLocked(state, until: Date().addingTimeInterval(milliseconds(limits.closeTimeoutMilliseconds))) {
            state.cancelled
        }
        if cancelled, activeGeneration === state {
            state.terminal = true
            state.buffer.removeAll(keepingCapacity: false)
            activeGeneration = nil
            condition.broadcast()
        }
        condition.unlock()

        guard cancelled else {
            throw NetworkCommissioningTransportError.closeTimedOut
        }
    }

    public func flushReceiveBuffer() {
        condition.lock()
        activeGeneration?.buffer.removeAll(keepingCapacity: false)
        condition.unlock()
    }

    public func write(_ bytes: [UInt8]) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        dispatchPrecondition(condition: .notOnQueue(callbackQueue))
        condition.lock()
        guard let state = activeGeneration, state.ready, !state.terminal, !state.unusable else {
            condition.unlock()
            throw CommissioningTransportError.portNotOpen
        }
        let connection = state.connection
        let wait = SendWait()
        condition.unlock()

        connection.send(bytes) { [weak self, weak state] error in
            guard let self, let state else { return }
            self.condition.lock()
            guard self.activeGeneration === state, !state.unusable else {
                self.condition.unlock()
                return
            }
            wait.error = error
            if error != nil {
                state.unusable = true
                state.terminal = true
                state.buffer.removeAll(keepingCapacity: false)
            }
            self.condition.broadcast()
            self.condition.unlock()
            wait.semaphore.signal()
        }

        let result = wait.semaphore.wait(timeout: .now() + .milliseconds(limits.writeTimeoutMilliseconds))
        if result == .timedOut {
            condition.lock()
            if activeGeneration === state {
                state.unusable = true
                state.terminal = true
                state.buffer.removeAll(keepingCapacity: false)
                condition.broadcast()
            }
            condition.unlock()
            throw CommissioningTransportError.writeFailed("Timeout")
        }
        if let error = wait.error {
            throw CommissioningTransportError.writeFailed(error)
        }
    }

    public func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        if timeoutMilliseconds > 0 {
            dispatchPrecondition(condition: .notOnQueue(.main))
            dispatchPrecondition(condition: .notOnQueue(callbackQueue))
        }
        let deadline = Date().addingTimeInterval(milliseconds(Int(timeoutMilliseconds)))
        condition.lock()
        defer { condition.unlock() }

        while true {
            guard let state = activeGeneration, !state.unusable else { return .closed }
            if !state.buffer.isEmpty {
                let bytes = state.buffer
                state.buffer.removeAll(keepingCapacity: false)
                return .bytes(bytes)
            }
            if state.terminal { return .closed }
            guard timeoutMilliseconds > 0 else { return .timeout }
            guard condition.wait(until: deadline) else { return .timeout }
        }
    }

    private func handle(_ connectionState: SimulationNetworkConnectionState, for state: GenerationState) {
        switch connectionState {
        case .preparing:
            return
        case .ready:
            condition.lock()
            guard activeGeneration === state, !state.terminal else {
                condition.unlock()
                return
            }
            state.ready = true
            condition.unlock()

            registerReceive(for: state)

            condition.lock()
            state.openFinished = true
            condition.broadcast()
            condition.unlock()
        case .failed(let message):
            condition.lock()
            guard activeGeneration === state else {
                condition.unlock()
                return
            }
            state.openFailure = message
            state.openFinished = true
            condition.broadcast()
            condition.unlock()
        case .waiting(let message):
            condition.lock()
            guard activeGeneration === state else {
                condition.unlock()
                return
            }
            state.openFailure = message
            state.openFinished = true
            condition.broadcast()
            condition.unlock()
        case .cancelled:
            condition.lock()
            guard activeGeneration === state else {
                condition.unlock()
                return
            }
            state.cancelled = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private func registerReceive(for state: GenerationState) {
        state.connection.receive(maximumLength: limits.receiveBufferLimit + 1) { [weak self, state] bytes, isComplete, error in
            guard let self else { return }
            self.handleReceive(bytes: bytes, isComplete: isComplete, error: error, for: state)
        }
    }

    private func handleReceive(
        bytes: [UInt8],
        isComplete: Bool,
        error: String?,
        for state: GenerationState
    ) {
        condition.lock()
        guard activeGeneration === state, !state.terminal, !state.unusable else {
            condition.unlock()
            return
        }
        guard let current = activeGeneration else {
            condition.unlock()
            return
        }
        current.buffer.append(contentsOf: bytes)
        if current.buffer.count > limits.receiveBufferLimit {
            current.buffer.removeAll(keepingCapacity: false)
            current.terminal = true
            condition.broadcast()
            condition.unlock()
            return
        }
        let ended = isComplete || error != nil
        if ended {
            current.terminal = true
            condition.broadcast()
            condition.unlock()
            return
        }
        condition.broadcast()
        condition.unlock()
        registerReceive(for: state)
    }

    private func waitForStateLocked(
        _ state: GenerationState,
        until deadline: Date,
        _ predicate: () -> Bool
    ) -> Bool {
        while !predicate() {
            guard condition.wait(until: deadline) else { return predicate() }
        }
        return true
    }

    private func milliseconds(_ value: Int) -> TimeInterval {
        TimeInterval(max(value, 0)) / 1_000
    }
}

private final class UnsafeCallbackBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Produktionsadapter auf `NWConnection` (TCP, `noDelay`).
public final class NWSimulationNetworkConnection: SimulationNetworkConnection, @unchecked Sendable {
    private let connection: NWConnection

    public init(endpoint: SimulationEndpoint) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port) ?? .any,
            using: parameters
        )
    }

    public func start(queue: DispatchQueue, stateHandler: @escaping (SimulationNetworkConnectionState) -> Void) {
        let stateHandler = UnsafeCallbackBox(stateHandler)
        connection.stateUpdateHandler = { state in
            switch state {
            case .setup, .preparing: stateHandler.value(.preparing)
            case .ready: stateHandler.value(.ready)
            case .waiting(let error): stateHandler.value(.waiting(String(describing: error)))
            case .failed(let error): stateHandler.value(.failed(String(describing: error)))
            case .cancelled: stateHandler.value(.cancelled)
            @unknown default: stateHandler.value(.failed("Unknown connection state"))
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ bytes: [UInt8], completion: @escaping (String?) -> Void) {
        let completion = UnsafeCallbackBox(completion)
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            completion.value(error.map { String(describing: $0) })
        })
    }

    public func receive(
        maximumLength: Int,
        completion: @escaping ([UInt8], Bool, String?) -> Void
    ) {
        let completion = UnsafeCallbackBox(completion)
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            completion.value(data.map { [UInt8]($0) } ?? [], isComplete, error.map { String(describing: $0) })
        }
    }

    public func cancel() { connection.cancel() }
}

public struct NWSimulationNetworkConnectionFactory: SimulationNetworkConnectionMaking {
    public init() {}
    public func makeConnection(to endpoint: SimulationEndpoint) -> SimulationNetworkConnection {
        NWSimulationNetworkConnection(endpoint: endpoint)
    }
}
