import PlanariumInput
import Combine
import Foundation
import SickPLSMacTransport
import PlanariumScannerUI
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl

// Testgrundlage für `StandardConnectionControlModel` (SICK-0330b).
//
// **Echter Lauf, echter Reducer, echter Executor, echtes Besitzmodell.**
// Gefälscht sind nur Transport, Uhr, Passwortablage, Portliste,
// Dispatcher und die RX-Sitzung -- Letztere als bloße Kurzlage, die der
// Spion-Koordinator auf Zuruf verändert.

/// Ein Koordinator-Spion mit dem **echten** ``SerialPortOwnership``.
///
/// Dadurch gilt die reale Verweigerung: Solange der Lauf den Port unter
/// dem Commissioning-Besitz hält, wird ein RX-Anspruch abgelehnt. Genau
/// das ist die Gegenprobe zur Reihenfolge „erst wirklich schließen, dann
/// RX".
final class SpyStandardConnectionCoordinator: StandardConnectionCoordinating {

    private var ownership = SerialPortOwnership()
    private let ownerSubject: CurrentValueSubject<SerialPortOwner, Never>
    private let statusSubject = CurrentValueSubject<MeasurementSessionStatus, Never>(.idle)

    /// Jede Besitz- und Sitzungshandlung in Reihenfolge.
    private(set) var events: [String] = []
    private(set) var finishedBaudRates: [SerialPortBaudRate?] = []
    private(set) var connectRequests: [(portPath: String, baudRate: SerialPortBaudRate)] = []
    private(set) var disconnectCount = 0

    /// Wird **unmittelbar vor** dem RX-Anspruch gerufen -- der Haltepunkt
    /// für die Frage „ist der TX-Port jetzt wirklich zu?".
    var onConnect: (() -> Void)?

    var streamEvidence = MeasurementStreamEvidence.none
    var referenceMeasurementLine = "Reference measurement: not running"

    init() {
        ownerSubject = CurrentValueSubject(.free)
    }

    func holdSimulationForTest() {
        precondition(ownership.claimForSimulation() == .granted)
        publish()
    }

    // MARK: CommissioningPortCoordinating

    var portOwner: SerialPortOwner { ownership.owner }
    var isAwaitingPortRelease: Bool { ownership.isAwaitingRelease }
    var portOwnershipChanges: AnyPublisher<SerialPortOwner, Never> { ownerSubject.eraseToAnyPublisher() }

    func commissioningRunReadiness(portPath: String) -> CommissioningRunReadiness { .ready }

    @discardableResult
    func requestCommissioningAccess() -> CommissioningAccessOutcome {
        events.append("requestAccess")
        switch ownership.claimForCommissioning() {
        case .granted:
            publish()
            return .granted
        case .refused(.heldByMonitor):
            disconnect()
            return .awaitingMonitorRelease
        case .refused(let refusal):
            return .refused(refusal)
        }
    }

    @discardableResult
    func completeCommissioning(with report: CommissioningStepReport) -> CommissioningCompletionOutcome {
        .notHoldingPort
    }

    // MARK: StandardConnectionCoordinating

    @discardableResult
    func connect(portPath: String, baudRate: SerialPortBaudRate) -> MonitorConnectOutcome {
        onConnect?()
        events.append("rxConnect")
        connectRequests.append((portPath, baudRate))
        switch ownership.claimForMonitor() {
        case .refused(let refusal):
            return .refused(refusal)
        case .granted:
            let effective = ownership.monitorConnectBaudRate(requested: baudRate)
            publish()
            statusSubject.send(.opening(portPath: portPath))
            return .connecting(baudRate: effective)
        }
    }

    func connectDevelopment(
        portPath: String,
        baudRate: SerialPortBaudRate
    ) -> MonitorConnectOutcome {
        connect(portPath: portPath, baudRate: baudRate)
    }

    func disconnect() {
        events.append("rxDisconnect")
        disconnectCount += 1
        ownership.noteMonitorDisconnectRequested()
        publish()
    }

    func finishCommissioning(verifiedBaudRate: SerialPortBaudRate?) {
        events.append("finishCommissioning")
        finishedBaudRates.append(verifiedBaudRate)
        ownership.releaseCommissioning(verifiedBaudRate: verifiedBaudRate)
        publish()
    }

    var measurementSessionStatus: MeasurementSessionStatus { statusSubject.value }
    var measurementSessionStatusChanges: AnyPublisher<MeasurementSessionStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }
    var measurementStreamEvidence: MeasurementStreamEvidence { streamEvidence }

    // MARK: Sitzung auf Zuruf

    // Retained fixture label; rate is deliberately absent from discrete status.
    // Real telemetry/rounding is exercised on the RX path in MacOS12PerformanceTests.
    func simulateFirstProfile(portPath: String, rateHz _: Double?, pointCount: Int) {
        statusSubject.send(.streaming(portPath: portPath, pointCount: pointCount))
    }

    func simulateStreamLost(portPath: String, message: String) {
        statusSubject.send(.failed(portPath: portPath, message: message))
        ownership.notePortReleased()
        publish()
    }

    /// Das echte Freigabe-Ereignis nach dem `close(2)` des Lesethreads.
    func simulatePortReleased() {
        ownership.notePortReleased()
        statusSubject.send(.idle)
        publish()
    }

    private func publish() {
        ownerSubject.send(ownership.owner)
    }
}

/// Stellt einen **echten** ``StandardConnectionRun`` über einen
/// skriptbaren Transport bereit -- oder verweigert.
final class ScriptedStandardConnectionRunProvider: StandardConnectionRunProviding {
    let clock = TestMonotonicClock()
    let passwordStore: TrackingScannerPasswordStore
    private(set) var transports: [ScriptedStandardConnectionTransport] = []
    private(set) var runs: [StandardConnectionRun] = []
    private(set) var requestedModes: [ScannerMeasurementMode] = []
    var failure: CommissioningRunUnavailableReason?
    /// Bereitet jeden neuen Transport vor (Skript, Haltepunkte).
    var prepareTransport: ((ScriptedStandardConnectionTransport) -> Void)?
    /// Variante für Kandidatenläufe, deren Skript vom Port abhängt.
    var prepareTransportForPort: ((String, ScriptedStandardConnectionTransport) -> Void)?

    init(storedPassword: String = standardTestSecretText) {
        passwordStore = TrackingScannerPasswordStore(initial: storedPassword)
    }

    var transport: ScriptedStandardConnectionTransport { transports[transports.count - 1] }

    func makeRun(
        portPath: String,
        measurementMode: ScannerMeasurementMode = .mmk,
        onProgress: @escaping StandardConnectionProgressHandler
    ) throws -> StandardConnectionRun {
        if let failure { throw failure }
        requestedModes.append(measurementMode)
        let transport = ScriptedStandardConnectionTransport(clock: clock)
        prepareTransportForPort?(portPath, transport)
        prepareTransport?(transport)
        transports.append(transport)
        let run = StandardConnectionRun(
            transport: transport, passwordStore: passwordStore, measurementMode: measurementMode, clock: clock, onProgress: onProgress
        )
        runs.append(run)
        return run
    }
}

/// Ein fertig verdrahtetes Verbindungsmodell samt Spionen.
struct ConnectionHarness {
    let coordinator = SpyStandardConnectionCoordinator()
    let provider: ScriptedStandardConnectionRunProvider
    let dispatcher = ManualCommissioningDispatcher()
    let listing = FakeSerialPortListing()
    let model: StandardConnectionControlModel

    static let portPath = "/dev/cu.usbserial-TEST"

    init(storedPassword: String = standardTestSecretText, selectPort: Bool = true, measurementMode: ScannerMeasurementMode? = .mmk) {
        provider = ScriptedStandardConnectionRunProvider(storedPassword: storedPassword)
        listing.paths = [Self.portPath]
        model = StandardConnectionControlModel(
            coordinator: coordinator,
            runProvider: provider,
            dispatcher: dispatcher,
            portListing: listing,
            defaults: UserDefaults(suiteName: "ConnectionHarness-\(UUID())")!
        )
        model.refreshPorts()
        // Historical port-ownership cases deliberately exercise MMK 90.
        // nil keeps the production default and is tested separately with 361.
        if let measurementMode { model.selectMeasurementMode(measurementMode) }
        if selectPort {
            model.selectPort(Self.portPath)
        }
    }

    /// Ein passiver Erfolg: der erste Lesevorgang liefert sofort B0.
    func preparePassiveSuccess() {
        provider.prepareTransport = { transport in
            transport.readScript = [.standardFrame(standardScanProfileFrame())]
        }
    }

    /// Der vollständige 9600-Rückfall (Login, Baudwechsel, Verifikation,
    /// MMK), skriptiert ab dem dritten realen Lesevorgang.
    func prepareFullFallback() {
        provider.prepareTransport = { transport in
            var readCount = 0
            transport.onRead = {
                readCount += 1
                if readCount == 3 {
                    transport.readScript = [
                        .standardFrame(standardIdentityResponseFrame()),
                        .standardFrame(standardAcknowledgementFrame()),
                        .standardFrame(standardAcknowledgementFrame()),
                        .standardFrame(standardIdentityResponseFrame()),
                        .standardFrame(standardScanProfileFrame())
                    ]
                }
            }
        }
    }

    /// Klick auf `Verbinden` und vollständiger Vollzug aller
    /// Hintergrund- und Hauptzustellungen.
    @discardableResult
    func connectToCompletion() -> StandardConnectionControlModel.ConnectOutcome {
        let outcome = model.connect()
        settle()
        return outcome
    }

    /// Vollzieht Hintergrund und Zustellung, bis beide Warteschlangen
    /// leer sind -- der Schluss wird erst aus einer Zustellung heraus
    /// eingeplant und braucht deshalb eine zweite Runde.
    func settle() {
        while !dispatcher.backgroundWork.isEmpty || !dispatcher.mainWork.isEmpty {
            dispatcher.runToCompletion()
        }
    }
}
