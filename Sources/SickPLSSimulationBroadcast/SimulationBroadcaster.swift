import Dispatch
import Foundation
import Network
import SickPLSDeviceModel
import SickPLSSimulationLink

public protocol SimulationTickSource: AnyObject {
    func start(interval: Double, handler: @escaping () -> Void)
    func stop()
}

public enum SimulationSendCompletionPolicy: Equatable, Sendable {
    case normal
    case holdForTesting
}

public final class DispatchSimulationTickSource: SimulationTickSource, @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    public init() {}
    public func start(interval: Double, handler: @escaping () -> Void) { stop(); let timer = DispatchSource.makeTimerSource(); timer.schedule(deadline: .now() + interval, repeating: interval); timer.setEventHandler(handler: handler); timer.resume(); self.timer = timer }
    public func stop() { timer?.cancel(); timer = nil }
}

public final class SimulationBroadcaster: @unchecked Sendable {
    public typealias ProfileProvider = () -> [UInt16]
    public typealias ConnectionStateHandler = @Sendable (Bool) -> Void
    private let provider: ProfileProvider; private let interval: Double; private let tickSource: SimulationTickSource; private let completionPolicy: SimulationSendCompletionPolicy; private let queue = DispatchQueue(label: "sick.simulation.broadcast")
    private var listener: NWListener?; private var connection: NWConnection?; private var outstanding = 0
    private let device = VirtualPLSDevice()
    private var lastNotifiedConnectionState: Bool?
    public var connectionStateHandler: ConnectionStateHandler?
    private var droppedProfileCountValue = 0
    private var portValue: NWEndpoint.Port?

    /// The state is owned by `queue`; callers read it through the same queue.
    /// There is currently no call from `queue` itself, so synchronous reads do
    /// not recurse into the serial queue.
    public var droppedProfileCount: Int { queue.sync { droppedProfileCountValue } }
    public typealias DeviceModeHandler = @Sendable (VirtualPLSMode) -> Void
    /// SIM-P2c-1: Moduswechsel des Gerätemodells, auf Main gemeldet.
    public var deviceModeHandler: DeviceModeHandler?
    /// SIM-P2c-1: Modus des Gerätemodells; überdauert Verbindungswechsel.
    public var deviceMode: VirtualPLSMode { queue.sync { device.mode } }
    /// SIM-P2c-1: Profile, die wegen eines nicht nachgebildeten Modus nicht
    /// gesendet wurden.
    public var suppressedProfileCount: Int { queue.sync { suppressedProfileCountValue } }
    private var suppressedProfileCountValue = 0
    public var port: NWEndpoint.Port? { queue.sync { portValue } }
    public init(port: NWEndpoint.Port? = NWEndpoint.Port(rawValue: 0), service: NWListener.Service? = nil,
                interval: Double = 0.04, tickSource: SimulationTickSource = DispatchSimulationTickSource(),
                completionPolicy: SimulationSendCompletionPolicy = .normal,
                profileProvider: @escaping ProfileProvider) {
        self.provider = profileProvider; self.interval = interval; self.tickSource = tickSource; self.completionPolicy = completionPolicy
        let parameters = NWParameters.tcp
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        parameters.defaultProtocolStack.transportProtocol = tcp
        if let port, let created = try? NWListener(using: parameters, on: port) {
            listener = created
            listener?.service = service
        }
    }
    public func start() {
        guard let listener else { return }
        listener.newConnectionHandler = { [weak self] candidate in self?.accept(candidate) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .ready = state else { return }
            self?.queue.async { [weak self, weak listener] in
                self?.portValue = listener?.port
            }
        }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.tickSource.stop()
            if let connection = self.connection {
                self.connection = nil
                connection.cancel()
            }
            self.listener?.cancel()
            self.listener = nil
            self.notifyConnectionState(false)
        }
    }

    private func accept(_ candidate: NWConnection) {
        let owner = self
        queue.async { [weak owner, candidate] in
            guard let owner else { return }
            guard owner.connection == nil else { candidate.cancel(); return }
            owner.connection = candidate
            candidate.stateUpdateHandler = { [weak owner, weak candidate] state in
                guard let owner, let candidate else { return }
                owner.queue.async { [weak owner, weak candidate] in
                    guard let owner, let candidate else { return }
                    switch state {
                    case .ready:
                        guard owner.connection === candidate else { return }
                        owner.notifyConnectionState(true)
                        owner.tickSource.start(interval: owner.interval) { [weak owner] in owner?.sendProfile() }
                        owner.receiveNext(from: candidate)
                    case .failed, .cancelled:
                        owner.finish(candidate)
                    default:
                        break
                    }
                }
            }
            candidate.start(queue: owner.queue)
        }
    }

    private func receiveNext(from candidate: NWConnection) {
        guard connection === candidate else { return }
        candidate.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak candidate] data, _, isComplete, error in
            guard let self, let candidate else { return }
            self.queue.async { [weak self, weak candidate] in
                guard let self, let candidate, self.connection === candidate else { return }
                let oldMode = self.device.mode
                let outputs = data.map { self.device.receive(bytes: $0) } ?? []
                for output in outputs {
                    switch output {
                    case .framed(let frame):
                        candidate.send(content: Data(frame.encoded()), completion: .contentProcessed { _ in })
                    case .singleByte(let byte):
                        candidate.send(content: Data([byte.rawValue]), completion: .contentProcessed { _ in })
                    case .notSupported:
                        break
                    }
                }
                let newMode = self.device.mode
                if oldMode != newMode, let handler = self.deviceModeHandler {
                    DispatchQueue.main.async { handler(newMode) }
                }
                if isComplete || error != nil {
                    self.finish(candidate)
                } else {
                    self.receiveNext(from: candidate)
                }
            }
        }
    }

    private func finish(_ candidate: NWConnection) {
        guard connection === candidate else { return }
        connection = nil
        outstanding = 0
        tickSource.stop()
        candidate.cancel()
        notifyConnectionState(false)
    }

    private func notifyConnectionState(_ connected: Bool) {
        guard lastNotifiedConnectionState != connected else { return }
        lastNotifiedConnectionState = connected
        guard let handler = connectionStateHandler else { return }
        DispatchQueue.main.async { handler(connected) }
    }
    private func sendProfile() {
        let owner = self
        queue.async { [weak owner] in
            guard let owner, let connection = owner.connection else { return }
            if owner.device.mode == .minimumPerSegmentRequested {
                owner.suppressedProfileCountValue += 1
                return
            }
            guard owner.outstanding < 3 else { owner.droppedProfileCountValue += 1; return }
            guard let bytes = try? B0TelegramEncoder.frameBytes(values: owner.provider()) else { return }
            owner.outstanding += 1
            connection.send(content: Data(bytes), completion: .contentProcessed { [weak owner] _ in
                guard owner?.completionPolicy == .normal else { return }
                owner?.queue.async { [weak owner] in owner?.outstanding = max(0, (owner?.outstanding ?? 1) - 1) }
            })
        }
    }
}
