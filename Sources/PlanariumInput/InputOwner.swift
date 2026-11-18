import Combine
import Foundation
import PlanariumDomain
import PlanariumRuntime
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport

/// Sole source/lease owner. All control and ownership state belongs to Main;
/// the reader touches only its descriptor and a locked delivery capability.
@MainActor public final class InputOwner: ObservableObject, RuntimeProfileSource {
    public var profileRateDisplay: ProfileRateDisplayModel { session.profileRateDisplay }
    public let session: RXSession
    @Published public private(set) var portOwner: SerialPortOwner = .free
    @Published public private(set) var isAwaitingPortRelease = false
    @Published public private(set) var verifiedBaudRate: SerialPortBaudRate?
    @Published public private(set) var portAccessNotice: PortAccessNotice?
    public var referenceMeasurementLineProvider: (() -> String)?
    public var referenceMeasurementLine: String { referenceMeasurementLineProvider?() ?? "Reference measurement: not available." }
    private var closed = false
    private var shutdownCallbacks: [@MainActor () -> Void] = []
    private var ownership = SerialPortOwnership()
    private var releaseSubscription: AnyCancellable?
    public init(session: RXSession? = nil) {
        let session = session ?? RXSession()
        self.session = session
        releaseSubscription = session.portReleased.sink { [weak self] _ in self?.notePortReleased() }
    }
    public nonisolated func bind(_ receive: @escaping @Sendable (ProfileSourceEvent) -> Void) { session.bind(receive) }
    @discardableResult
    public func connect(portPath: String, baudRate: SerialPortBaudRate) -> MonitorConnectOutcome {
        guard !closed else { return .refused(.awaitingRelease) }
        switch ownership.claimForMonitor() {
        case .refused(let refusal):
            publishOwnership(notice: .describing(refusal))
            return .refused(refusal)
        case .granted:
            let effectiveBaudRate = ownership.monitorConnectBaudRate(requested: baudRate)
            publishOwnership(notice: nil)
            session.connect(portPath: portPath, baudRate: effectiveBaudRate)
            return .connecting(baudRate: effectiveBaudRate)
        }
    }

    /// Ausdrücklicher Entwicklungsweg für eine bereits manuell vorbereitete
    /// Scanner-Sitzung. Anders als der Produktweg übernimmt er genau die
    /// gewählte Hostrate und überschreibt sie nicht mit einer früheren
    /// Commissioning-Verifikation. Portbesitz, Sitzung, Profilweitergabe,
    /// Audio/MIDI und Trennen bleiben vollständig derselbe Produktionspfad.
    @discardableResult
    public func connectDevelopment(
        portPath: String,
        baudRate: SerialPortBaudRate
    ) -> MonitorConnectOutcome {
        guard !closed else { return .refused(.awaitingRelease) }
        switch ownership.claimForMonitor() {
        case .refused(let refusal):
            publishOwnership(notice: .describing(refusal))
            return .refused(refusal)
        case .granted:
            publishOwnership(notice: nil)
            session.connect(portPath: portPath, baudRate: baudRate)
            return .connecting(baudRate: baudRate)
        }
    }

    @discardableResult
    public func connectSimulation(
        serviceName: String,
        opener: ScanByteStreamOpening
    ) -> SimulationConnectOutcome {
        guard !closed else { return .refused(.awaitingRelease) }
        switch ownership.claimForSimulation() {
        case .refused(let refusal):
            publishOwnership(notice: .describing(refusal))
            return .refused(refusal)
        case .granted:
            publishOwnership(notice: nil)
            session.connectSimulation(serviceName: serviceName, opener: opener)
            return .connecting
        }
    }

    /// Ausdrückliches Trennen. Das Profilabonnement bleibt bestehen; es
    /// gehört der Sitzung, nicht der Verbindung.
    ///
    /// **Der Übergang wird vor dem asynchronen Trennen markiert**
    /// (SICK-030a1): `ScanSession.disconnect()` kehrt sofort zurück, das
    /// echte `close(2)` folgt später auf dem Lesethread. Bis zum
    /// tatsächlichen ``ScanSession/portReleased`` bekommt deshalb
    /// niemand den Port.
    public func disconnect() {
        ownership.noteMonitorDisconnectRequested()
        publishOwnership(notice: nil)
        session.disconnect()
    }

    public func shutdown(_ completion: @escaping @MainActor () -> Void) {
        closed = true
        guard session.isPortHeld else { completion(); return }
        shutdownCallbacks.append(completion)
        disconnect()
    }

    // MARK: - Die I/O-freie Commissioning-Grenze (für SICK-031)

    /// Fordert den Port für einen Einrichtungslauf an.
    ///
    /// **Diese Methode öffnet nichts, sendet nichts und wartet auf
    /// nichts.** Sie vergibt ausschließlich den Besitz; der eigentliche
    /// Ablauf entsteht in SICK-031 auf dem Modell aus
    /// `SickPLSCommissioning`.
    ///
    /// Hält der Monitor den Port, wird **höchstens dessen kontrolliertes
    /// Trennen veranlasst** — nie ein Deskriptor weggerissen. Der Besitz
    /// wechselt erst mit dem echten Freigabe-Ereignis; bis dahin
    /// antwortet diese Methode ``CommissioningAccessOutcome/awaitingMonitorRelease``,
    /// und der Aufrufer fragt später erneut.
    @discardableResult
    public func requestCommissioningAccess() -> CommissioningAccessOutcome {
        guard !closed else { return .refused(.awaitingRelease) }
        switch ownership.claimForCommissioning() {
        case .granted:
            publishOwnership(notice: nil)
            return .granted
        case .refused(.heldByMonitor):
            // Kontrolliertes Trennen -- derselbe Weg, den auch der
            // Bedienende nimmt, inklusive Wartemarkierung.
            disconnect()
            publishOwnership(notice: PortAccessNotice(
                "The monitor is disconnecting. Setup starts once the port is released."
            ))
            return .awaitingMonitorRelease
        case .refused(.awaitingRelease):
            publishOwnership(notice: .describing(.awaitingRelease))
            return .awaitingMonitorRelease
        case .refused(let refusal):
            publishOwnership(notice: .describing(refusal))
            return .refused(refusal)
        }
    }

    /// Ob ein Einrichtungslauf **beginnen dürfte** — ohne etwas zu tun
    /// (SICK-031, vorbereitet für SICK-032).
    ///
    /// **Diese Methode öffnet nichts, sendet nichts und beansprucht
    /// nichts.** Sie beantwortet nur die Startvoraussetzung, damit eine
    /// spätere Oberfläche den Knopf **begründet** sperren kann. Die
    /// Pfadgrenze wird hier vorab beantwortet und im Transport ein
    /// zweites Mal durchgesetzt — die Antwort einer Ansicht ist keine
    /// Zusicherung.
    public func commissioningRunReadiness(portPath: String) -> CommissioningRunReadiness {
        guard !portPath.isEmpty else { return .noPortSelected }
        guard portPath.hasPrefix("/dev/cu.") else { return .portPathNotAllowed }
        if isAwaitingPortRelease { return .awaitingPortRelease }
        switch portOwner {
        case .free, .commissioning:
            return .ready
        case .monitor:
            return .monitorMustDisconnectFirst
        case .simulation:
            return .simulationMustDisconnectFirst
        case .simulationControl:
            return .simulationControlMustFinishFirst
        }
    }

    /// Schließt einen Einrichtungslauf ab und gibt den Portbesitz
    /// **genau einmal** frei (SICK-031).
    ///
    /// Der Bericht stammt aus `CommissioningExecutor`; dieser Koordinator
    /// führt selbst **keinen** Lauf aus — er besitzt keinen Transport,
    /// keinen Executor und keine Uhr, und `SickPLSActiveControl` ist für
    /// dieses Ziel ausdrücklich verboten (`PerformanceSessionBoundaryTests`).
    ///
    /// **Die Rate kommt ausschließlich aus dem Bericht.** Sie ist dort
    /// nur gesetzt, wenn eine CRC-valide Identitätsantwort am neu
    /// geöffneten Port bei der Zielrate kam (Auflage A1) — ein `0xB0`-
    /// Messstrom, eine Bestätigung oder ein vermuteter Wechsel setzen sie
    /// nie. Dieser Koordinator leitet sie **nicht** ab und rät sie nicht.
    @discardableResult
    public func completeCommissioning(with report: CommissioningStepReport) -> CommissioningCompletionOutcome {
        guard portOwner == .commissioning else { return .notHoldingPort }
        guard report.isFinal else { return .stillRunning }
        finishCommissioning(verifiedBaudRate: report.verifiedBaudRate)
        return .released(verifiedBaudRate: report.verifiedBaudRate)
    }

    /// Gibt den Commissioning-Besitz wieder frei.
    ///
    /// `verifiedBaudRate` übergibt **nur**, wer die Rate wirklich belegt
    /// hat (eine CRC-valide Identitätsantwort bei genau dieser Rate,
    /// Auflage A1); ein Fehlschlag übergibt `nil` und lässt eine früher
    /// belegte Rate unangetastet.
    public func finishCommissioning(verifiedBaudRate: SerialPortBaudRate? = nil) {
        ownership.releaseCommissioning(verifiedBaudRate: verifiedBaudRate)
        publishOwnership(notice: nil)
    }

    // MARK: - Simulations-Steuersitzung (SIM-P2a)

    /// Fordert eine Steuersitzung an. Öffnet und sendet nichts.
    /// Hält Simulations-RX den Port, wird es kontrolliert getrennt
    /// (`.awaitingRelease`); Hardware-RX und Commissioning werden verweigert.
    @discardableResult
    public func requestSimulationControlAccess(
        endpoint: SimulationEndpoint,
        job: SimulationControlJob
    ) -> SimulationControlAccessOutcome {
        guard !closed else { return .refused(.awaitingRelease) }
        switch ownership.claimForSimulationControl() {
        case .granted:
            guard let generation = ownership.simulationControlGeneration else {
                publishOwnership(notice: .describing(.heldBySimulationControl))
                return .refused(.heldBySimulationControl)
            }
            publishOwnership(notice: nil)
            return .granted(SimulationControlLease(endpoint: endpoint, generation: generation, job: job))
        case .refused(.heldBySimulation):
            disconnect()
            publishOwnership(notice: .describing(.awaitingRelease))
            return .awaitingRelease
        case .refused(.awaitingRelease):
            publishOwnership(notice: .describing(.awaitingRelease))
            return .awaitingRelease
        case .refused(.heldByMonitor):
            publishOwnership(notice: .describing(.heldByMonitor))
            return .refused(.heldByMonitor)
        case .refused(let refusal):
            publishOwnership(notice: .describing(refusal))
            return .refused(refusal)
        }
    }

    /// Schließt eine Steuersitzung ab. Wirkt nur mit der gehaltenen
    /// Generation; `.closeFailed` lässt den Besitz gesperrt.
    @discardableResult
    public func completeSimulationControl(
        _ completion: SimulationControlCompletion
    ) -> SimulationControlReleaseOutcome {
        let outcome = ownership.releaseSimulationControl(completion)
        publishOwnership(notice: nil)
        return outcome
    }

    // MARK: - Besitzfortschreibung

    /// Der **einzige** Weg von „Monitor hält" zurück zu „frei": das
    /// echte Freigabe-Ereignis nach dem tatsächlichen `close()`.
    private func notePortReleased() {
        ownership.notePortReleased()
        publishOwnership(notice: portAccessNotice)
        let callbacks = shutdownCallbacks; shutdownCallbacks.removeAll(); callbacks.forEach { $0() }
    }

    private func publishOwnership(notice: PortAccessNotice?) {
        isAwaitingPortRelease = ownership.isAwaitingRelease
        verifiedBaudRate = ownership.verifiedBaudRate
        portAccessNotice = notice
        // `portOwnershipChanges` ist `$portOwner`, dessen @Published-Signal
        // im `willSet` feuert. Alle beobachteten Besitzfelder müssen deshalb
        // bereits konsistent stehen, bevor `portOwner` dieses Signal auslöst;
        // sonst liest der Sink noch den alten Awaiting-Wert.
        portOwner = ownership.owner
    }

    // MARK: - Die redigierte Sitzungslage für die Verbindungsleiste (SICK-0330b)

    /// Die Kurzlage der RX-Sitzung -- **abgeleitet**, nie gespeichert;
    /// es entsteht kein weiteres Abonnement auf der Sitzung.
    public var measurementSessionStatus: MeasurementSessionStatus {
        session.measurementStatus
    }

    /// Diskrete Kurzlage der Sitzung, ohne Kopie des vollständigen
    /// Profil-/Diagnosezustands. **Nur zum Beobachten.**
    public var measurementSessionStatusChanges: AnyPublisher<MeasurementSessionStatus, Never> {
        session.$measurementStatus
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Die aggregierten Zahlen der Sitzung für die Evidenzkarte --
    /// ebenfalls eine reine Ableitung aus bereits vorhandenen Werten.
    public var measurementStreamEvidence: MeasurementStreamEvidence {
        let diagnostics = session.state.diagnostics
        return MeasurementStreamEvidence(
            status: measurementSessionStatus,
            profileRateHz: profileRateDisplay.hertz,
            deliveredProfileBatches: session.deliveredProfileBatches,
            readsWithSeveralProfiles: session.readsWithSeveralProfiles,
            validFrames: diagnostics.validFrames,
            discardedCandidates: diagnostics.discardedCandidates,
            discardedCandidatesOversize: diagnostics.discardedCandidatesOversize,
            discardedCandidatesChecksumMismatch: diagnostics.discardedCandidatesChecksumMismatch,
            discardedCandidatesAtFinish: diagnostics.discardedCandidatesAtFinish,
            skippedNoiseBytes: diagnostics.skippedNoiseBytes
        )
    }

}
