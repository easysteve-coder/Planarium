import Combine
import Dispatch
import Foundation
import PlanariumDomain
import PlanariumRuntime
import SickPLSCore
import SickPLSMacTransport

/// The single ingress capability. Lock serializes end versus frame admission;
/// callbacks only enqueue onto Q and never wait for Main. A retired reader
/// cannot feed a later connection. No descriptor is touched under this lock.
private final class InputDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var receive: (@Sendable (ProfileSourceEvent) -> Void)?
    private var active: UUID?
    private var lastSession: UUID?
    nonisolated func bind(_ receive: @escaping @Sendable (ProfileSourceEvent) -> Void) {
        lock.lock(); defer { lock.unlock() }
        precondition(self.receive == nil, "Input has exactly one runtime consumer")
        self.receive = receive
    }
    func begin(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        precondition(active == nil)
        active = id; lastSession = id; receive?(.began(id))
    }
    func frame(_ frame: ProfileFrame) {
        lock.lock(); defer { lock.unlock() }
        guard active == frame.sessionID else { return }
        receive?(.frame(frame))
    }
    func end(_ id: UUID, reason: InputSessionEndReason) {
        lock.lock(); defer { lock.unlock() }
        guard active == id || (active == nil && lastSession == id && reason == .userRequested) else { return }
        active = nil
        if reason == .userRequested { lastSession = nil }
        receive?(.ended(id, reason: reason))
    }
}

/// InputOwner's read-only status surface. Connection entry points are internal:
/// only the lease owner can open a source. Descriptor open/read/close run on R.
@MainActor public final class RXSession: ObservableObject {
    public let profileRateDisplay = ProfileRateDisplayModel()
    /// Full evidence is read on demand by diagnostics/zone tools. Streaming
    /// observers receive only the small discrete status, never a state+profile copy.
    private var sessionEvidence = ScanSessionState()
    public private(set) var state: ScanSessionState {
        get { sessionEvidence }
        set { sessionEvidence = newValue; publishMeasurementStatus() }
    }
    private func publishMeasurementStatus() {
        let next = MeasurementSessionStatus.describing(connection: sessionEvidence.connection,
                                                       pointCount: sessionEvidence.lastProfile?.measurements.count)
        if measurementStatus != next { measurementStatus = next }
    }
    @Published public private(set) var measurementStatus: MeasurementSessionStatus = .idle
    @Published public private(set) var isPortHeld = false
    public private(set) var sessionID: UUID?
    public private(set) var deliveredProfileBatches = 0
    /// Main-status batches containing several profiles, including folded
    /// status updates. Runtime delivery on Q is separate and lossless here.
    public private(set) var readsWithSeveralProfiles = 0
    public var portReleased: AnyPublisher<ScanPortRelease, Never> { released.eraseToAnyPublisher() }
    public var performanceProfiles: AnyPublisher<ScanProfileBatch, Never> { profiles.eraseToAnyPublisher() }
    private let released = PassthroughSubject<ScanPortRelease, Never>()
    private let profiles = PassthroughSubject<ScanProfileBatch, Never>()
    private let delivery = InputDelivery()
    private let opener: any SerialPortOpener
    private let clock: any RuntimeClock
    private let timeout: Int32
    private var reader: InputReader?
    private var connectionID: UUID?
    private var previousEndpoint: ScanInputEndpoint?

    public init(opener: any SerialPortOpener = DarwinSerialPortOpener(),
                readTimeoutMilliseconds: Int32 = 200,
                clock: any RuntimeClock = MonotonicRuntimeClock()) {
        self.opener = opener; self.clock = clock; timeout = readTimeoutMilliseconds
    }
    deinit { reader?.stop() }
    nonisolated func bind(_ receive: @escaping @Sendable (ProfileSourceEvent) -> Void) { delivery.bind(receive) }
    func connect(portPath: String, baudRate: SerialPortBaudRate) {
        connect(endpoint: .serialPort(path: portPath, baudRate: baudRate),
                source: .serial(path: portPath, rate: baudRate, opener: opener))
    }
    func connectSimulation(serviceName: String, opener: any ScanByteStreamOpening) {
        connect(endpoint: .simulation(serviceName: serviceName), source: .stream(opener))
    }
    private func connect(endpoint: ScanInputEndpoint, source: InputReader.Source) {
        guard !isPortHeld else { return }
        if let connectionID, let previousEndpoint, previousEndpoint != endpoint {
            delivery.end(connectionID, reason: .userRequested)
        }
        profileRateDisplay.reset()
        previousEndpoint = endpoint
        let id = UUID()
        connectionID = id; sessionID = id; isPortHeld = true
        switch endpoint {
        case .serialPort(let path, let rate): state = .applyingConnecting(portPath: path, baudRate: rate)
        case .simulation(let name): state = .applyingSimulationConnecting(serviceName: name)
        }
        delivery.begin(id)
        let handoff = InputStatusHandoff(session: self)
        let worker = InputReader(source: source, id: id, clock: clock, timeout: timeout,
            deliver: { [delivery] in delivery.frame($0) },
            end: { [delivery] in delivery.end(id, reason: .failure) },
            status: { handoff.enqueue($0, id: id, endpoint: endpoint) })
        reader = worker; worker.start()
    }
    func disconnect() {
        guard let id = connectionID else { return }
        delivery.end(id, reason: .userRequested) // stop admission immediately; descriptor closes on R
        sessionID = nil
        profileRateDisplay.reset()
        reader?.stop()
        state = state.applyingDisconnected()
    }
    fileprivate func apply(_ event: InputReader.Status, id: UUID, endpoint: ScanInputEndpoint) {
        guard connectionID == id else { return }
        if case .released = event {
            reader = nil; sessionID = nil; isPortHeld = false
            released.send(.init(endpoint: endpoint))
            return
        }
        guard sessionID == id else { return }
        switch event {
        case .opened:
            switch endpoint {
            case .serialPort(let path, let rate): state = state.applyingConnected(portPath: path, baudRate: rate)
            case .simulation(let name): state = state.applyingSimulationConnected(serviceName: name)
            }
        case .read(let values, let diagnostics, let time, let coalesced, let receivedAt, let geometry):
            // Mutate the bare storage, not an observed/computed property's
            // get-modify-set temporary containing the entire profile.
            sessionEvidence.ingestProfiles(values, diagnostics: diagnostics, receivedAt: receivedAt,
                                           skippedProfiles: max(0, values.count - 1) + coalesced, geometry: geometry)
            publishMeasurementStatus()
            profileRateDisplay.observe(sessionEvidence.profileRateHz, at: time)
            if let last = values.last {
                deliveredProfileBatches += 1
                if values.count > 1 || coalesced > 0 { readsWithSeveralProfiles += 1 }
                profiles.send(.init(profile: last, profileCountInRead: values.count, receivedAtMonotonic: time))
            }
        case .failed(let message):
            profileRateDisplay.reset()
            switch endpoint {
            case .serialPort(let path, let rate): state = state.applyingConnectFailure(portPath: path, baudRate: rate, message: message)
            case .simulation(let name): state = state.applyingSimulationFailure(serviceName: name, message: message)
            }
        case .released: break
        }
    }
}

/// Cross-thread status transfer only. Main's weak reference is never read on R.
/// Up to 64 read batches preserve learning/reference samples; overflow folds
/// into the newest batch and explicitly counts discarded profiles.
private final class InputStatusHandoff: @unchecked Sendable {
    private weak var session: RXSession?
    private let lock = NSLock()
    private var pending: [(InputReader.Status, UUID, ScanInputEndpoint)] = []
    private var scheduled = false
    init(session: RXSession) { self.session = session }
    func enqueue(_ event: InputReader.Status, id: UUID, endpoint: ScanInputEndpoint) {
        lock.lock()
        if pending.count >= 64, case .read = event, let last = pending.last, case .read = last.0 {
            if case .read(let newProfiles, let diagnostics, let time, let newSkipped, let newDate, let geometry) = event,
               case .read(let oldProfiles, _, let oldTime, let oldSkipped, let oldDate, _) = last.0 {
                pending[pending.count - 1] = (.read(newProfiles.isEmpty ? oldProfiles : newProfiles, diagnostics, newProfiles.isEmpty ? oldTime : time,
                    newProfiles.isEmpty ? oldSkipped : oldSkipped + oldProfiles.count + newSkipped, newProfiles.isEmpty ? oldDate : newDate, geometry), id, endpoint)
            }
        } else { pending.append((event, id, endpoint)) }
        let needsSchedule = !scheduled; scheduled = true
        lock.unlock()
        if needsSchedule { DispatchQueue.main.async { self.drain() } }
    }
    @MainActor private func drain() {
        lock.lock(); let events = pending; pending.removeAll(keepingCapacity: true); scheduled = false; lock.unlock()
        for (event, id, endpoint) in events { session?.apply(event, id: id, endpoint: endpoint) }
    }
}

/// Immutable construction data crosses to R exactly once. Cancellation is
/// locked; only R accesses the descriptor/parser. The lock never covers I/O.
private final class InputReader: @unchecked Sendable {
    enum Source { case serial(path: String, rate: SerialPortBaudRate, opener: any SerialPortOpener), stream(any ScanByteStreamOpening) }
    enum Status { case opened, read([B0ScanProfile], StreamParser.Diagnostics, Double, Int, Date, ProfileGeometryDiagnostic), failed(String), released }
    private let source: Source
    private let id: UUID
    private let clock: any RuntimeClock
    private let timeout: Int32
    private let deliver: @Sendable (ProfileFrame) -> Void
    private let end: @Sendable () -> Void
    private let status: @Sendable (Status) -> Void
    private let lock = NSLock()
    private var cancelled = false
    init(source: Source, id: UUID, clock: any RuntimeClock, timeout: Int32,
         deliver: @escaping @Sendable (ProfileFrame) -> Void, end: @escaping @Sendable () -> Void,
         status: @escaping @Sendable (Status) -> Void) {
        self.source = source; self.id = id; self.clock = clock; self.timeout = timeout
        self.deliver = deliver; self.end = end; self.status = status
    }
    func start() { DispatchQueue.global(qos: .userInteractive).async { self.run() } }
    func stop() { lock.lock(); cancelled = true; lock.unlock() }
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private var endOfStreamMessage: String {
        switch source {
        case .serial: return "Connection ended unexpectedly (end of stream)."
        case .stream: return "Connection ended unexpectedly (end of stream)."
        }
    }
    private func run() {
        defer { end(); status(.released) }
        let descriptor: any SerialPortFileDescriptor
        do {
            switch source {
            case .serial(let path, let rate, let opener):
                guard path.hasPrefix("/dev/cu.") else { throw SerialPortOpenError.pathNotAllowed(path) }
                descriptor = try opener.open(atPath: path, baudRate: rate)
            case .stream(let opener): descriptor = try opener.openStream()
            }
        } catch { status(.failed(InputFailurePresentation.describe(error))); return }
        let stream = ReadOnlyFrameStream(descriptor: descriptor)
        defer { stream.close() }
        status(.opened)
        var sequence: UInt64 = 0
        var geometryDiagnostic = ProfileGeometryDiagnostic()
        var lastDiagnostics: StreamParser.Diagnostics?
        while !stopped {
            let result = stream.readNext(timeoutMilliseconds: timeout)
            let time = clock.now
            let profiles = ScanSessionState.decodedProfiles(in: result.frames)
            // Every decoded profile reaches Q in wire arrival order. Only
            // the Main status/display handoff may coalesce publications.
            for profile in profiles {
                let geometry: ProfileGeometryIdentity
                if let supported = try? FullScanProfileAdapter.geometry(from: profile) {
                    geometry = supported
                    geometryDiagnostic.geometry = supported
                    geometryDiagnostic.rejectedPointCount = nil
                    geometryDiagnostic.rejectedPartialScanIndex = nil
                } else {
                    geometry = .init(operatingMode: "unsupported", pointCount: profile.measurements.count,
                        startAngleDegrees: -90, endAngleDegrees: 90)
                    geometryDiagnostic.geometry = nil
                    geometryDiagnostic.unsupportedProfiles &+= 1
                    geometryDiagnostic.rejectedPointCount = profile.measurements.count
                    geometryDiagnostic.rejectedPartialScanIndex = profile.partialScanIndex
                }
                sequence &+= 1
                let measurements = (try? FullScanProfileAdapter.measurements(from: profile)) ?? []
                deliver(.init(sessionID: id, sequence: sequence, time: time, measurements: measurements,
                              geometry: geometry, rawProfile: profile))
            }
            if !profiles.isEmpty || lastDiagnostics != result.diagnostics {
                status(.read(profiles, result.diagnostics, time, 0, Date(), geometryDiagnostic))
                lastDiagnostics = result.diagnostics
            }
            if result.reachedEndOfStream { if !stopped { status(.failed(endOfStreamMessage)) }; return }
        }
    }
}
