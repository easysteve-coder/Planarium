import Foundation
import Network
import Dispatch
import SickPLSMacTransport
import SickPLSMonitorKit
import SickPLSSimulationLink

private final class NetworkOpenState: @unchecked Sendable {
    let lock = NSLock()
    var ready = false
    var failed = false
    var waitingForLocalNetwork = false
}

/// RX-only Network.framework adapter. No application bytes are sent.
public final class NetworkScanByteStream: SerialPortFileDescriptor, @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let silenceLimitSeconds: TimeInterval
    private let now: () -> TimeInterval
    private let diagnostics: MeasurementDiagnosticsRecorder?
    private var buffer: [UInt8] = []
    private var isComplete = false
    private var isClosed = false
    private var lastReceived: TimeInterval
    private var closeRecorded = false

    public init(
        connection: NWConnection,
        silenceLimitSeconds: TimeInterval = SimulationLinkConstants.silenceLimitSeconds,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        diagnostics: MeasurementDiagnosticsRecorder? = nil
    ) {
        self.connection = connection
        self.silenceLimitSeconds = silenceLimitSeconds
        self.now = now
        self.lastReceived = now()
        self.diagnostics = diagnostics
        receiveNext()
    }

    public func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        let deadline = now() + max(0, Double(timeoutMilliseconds) / 1000)
        while true {
            lock.lock()
            if !buffer.isEmpty {
                let bytes = buffer
                buffer.removeAll(keepingCapacity: true)
                lock.unlock()
                return .bytes(bytes)
            }
            let complete = isComplete
            let silent = now() - lastReceived > silenceLimitSeconds
            lock.unlock()
            if complete || silent {
                if complete {
                    close(reason: .complete)
                } else {
                    close(reason: .silence(lastReceivedAtMonotonic: lastReceived))
                }
                return .closed
            }
            let remaining = deadline - now()
            if remaining <= 0 { return .timeout }
            _ = semaphore.wait(timeout: .now() + remaining)
        }
    }

    public func close() {
        close(reason: .local(caller: .explicitDisconnect))
    }

    private func close(reason: SimulationCloseReasonDiagnostic) {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        isComplete = true
        let shouldRecord = !closeRecorded
        closeRecorded = true
        lock.unlock()
        if shouldRecord { diagnostics?.recordConnectionClosed(reason, at: now()) }
        connection.cancel()
        semaphore.signal()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.lock.lock()
            if let data {
                self.buffer.append(contentsOf: data)
                self.lastReceived = self.now()
                self.diagnostics?.recordReceiveBlock(byteCount: data.count, at: self.lastReceived)
            }
            if let error {
                self.isComplete = true
                self.closeRecorded = true
                self.diagnostics?.recordConnectionClosed(
                    .error(code: String(describing: error)), at: self.now()
                )
            } else if complete || self.isClosed {
                self.isComplete = true
            }
            let shouldContinue = !self.isComplete && !self.isClosed
            self.lock.unlock()
            self.semaphore.signal()
            if shouldContinue { self.receiveNext() }
        }
    }
}

public final class NetworkScanByteStreamOpener: ScanByteStreamOpening {
    private let endpoint: NWEndpoint
    private let timeoutSeconds: TimeInterval
    private let silenceLimitSeconds: TimeInterval
    private let now: () -> TimeInterval
    private let diagnostics: MeasurementDiagnosticsRecorder?
    /// SIM-P2c-2b: meldet nach `.ready` das aufgelöste Gegenüber (Host, Port)
    /// aus `currentPath.remoteEndpoint`, falls es `.hostPort` ist.
    /// Wird nach dem erfolgreichen Aufbau genau einmal für ein aufgelöstes
    /// `.hostPort`-Gegenüber gerufen.
    private let onResolvedRemote: (@Sendable (String, UInt16) -> Void)?
    public init(
        endpoint: NWEndpoint,
        timeoutSeconds: TimeInterval = SimulationLinkConstants.openTimeoutSeconds,
        silenceLimitSeconds: TimeInterval = SimulationLinkConstants.silenceLimitSeconds,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        diagnostics: MeasurementDiagnosticsRecorder? = nil,
        onResolvedRemote: (@Sendable (String, UInt16) -> Void)? = nil
    ) {
        self.onResolvedRemote = onResolvedRemote
        self.endpoint = endpoint
        self.timeoutSeconds = timeoutSeconds
        self.silenceLimitSeconds = silenceLimitSeconds
        self.now = now
        self.diagnostics = diagnostics
    }

    public func openStream() throws -> SerialPortFileDescriptor {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let connection = NWConnection(to: endpoint, using: parameters)
        let semaphore = DispatchSemaphore(value: 0)
        let state = NetworkOpenState()
        connection.stateUpdateHandler = { [state] networkState in
            state.lock.lock()
            switch networkState {
            case .ready: state.ready = true
            case .waiting:
                state.failed = true
                state.waitingForLocalNetwork = true
            case .failed, .cancelled: state.failed = true
            case .setup, .preparing: break
            @unknown default: state.failed = true
            }
            state.lock.unlock()
            semaphore.signal()
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        let deadline = DispatchTime.now() + timeoutSeconds
        while semaphore.wait(timeout: deadline) == .success {
            state.lock.lock()
            let isReady = state.ready
            let didFail = state.failed
            let isWaitingForLocalNetwork = state.waitingForLocalNetwork
            state.lock.unlock()
            if isReady {
                if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remoteEndpoint {
                    onResolvedRemote?(String(describing: host), port.rawValue)
                }
                return NetworkScanByteStream(
                    connection: connection,
                    silenceLimitSeconds: silenceLimitSeconds,
                    now: now,
                    diagnostics: diagnostics
                )
            }
            if didFail {
                connection.cancel()
                throw isWaitingForLocalNetwork
                    ? ScanByteStreamOpenError.waitingForLocalNetwork
                    : ScanByteStreamOpenError.unreachable
            }
        }
        connection.cancel()
        throw ScanByteStreamOpenError.timedOut
    }
}
