import Combine
import Foundation
import SickPLSCommissioning
import SickPLSMacTransport
import PlanariumInput

/// Das Bedienmodell der **kompakten Verbindungsleiste** (SICK-0330b,
/// absorbiert SICK-0331) -- der **erste und einzige Produktionsaufrufer**
/// des abgenommenen ``StandardConnectionRun`` und seiner
/// Fortschrittsgrenze.
///
/// ## Was dieses Modell ist
///
/// Die schmale Koordinationsschicht zwischen der Leiste und drei bereits
/// abgenommenen Teilen: dem Portbesitz des `InputOwner`
/// (über ``StandardConnectionCoordinating``), dem ``StandardConnectionRun``
/// (über ``StandardConnectionRunProviding``) und der RX-Sitzung (über
/// die redigierte ``MeasurementSessionStatus``-Kurzlage). **Es ist keine
/// zweite Zustandsmaschine**: Die Wahrheit über den Lauf ist der
/// ``StandardConnectionReport``, die Wahrheit über RX die Kurzlage.
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// 1. Manual connection and USB startup use the same proven connection path.
///    Automatic candidates are USB serial only; an explicit disconnect
///    suppresses subsequent startup requests until a manual connection.
/// 2. **Genau ein Portbesitzer.** Der Lauf hält den Port unter dem
///    Commissioning-Besitz; RX beansprucht ihn erst, nachdem der Besitz
///    freigegeben wurde -- und der wird erst freigegeben, nachdem ein
///    Bericht `isPortHeld == false` **beobachtet** wurde. Kein Feld
///    dieses Modells rät den Portzustand.
/// 3. **Jeder TX-fähige Port ist wirklich geschlossen, bevor RX beginnt.**
///    Nach `.ready` ruft dieses Modell ``StandardConnectionRun/releasePortForMeasurement()``
///    und startet RX ausschließlich aus dessen portfreiem Bericht.
/// 4. **Die Leiste liest nur die Fortschrittsgrenze.** Kein internes
///    Feld des Laufs, keine Transportgrenze, kein Executor.
/// 5. **Höchstens ein blockierender Aufruf gleichzeitig**, seriell im
///    Hintergrund; jeder Bericht erreicht zuerst den Kontroll-Thread.
///
/// ## Threadvertrag
///
/// Alle öffentlichen Mitglieder gehören dem Kontroll-Thread. Der einzige
/// Fremd-Thread ist die serialisierte Ausführung von `connect`,
/// `releasePortForMeasurement` und `retryClose`; von dort kommen
/// ausschließlich Berichte über ``CommissioningDispatching/deliverOnMain(_:)``
/// zurück. `requestAbort()` ist von jedem Thread aus sicher.
public final class StandardConnectionControlModel: ObservableObject {

    // MARK: - Sichtbarer Zustand

    /// All named callouts for support. Manual refresh never selects a port;
    /// startup and automatic connection use the USB-only snapshot below.
    @Published public private(set) var availablePorts: [String] = []
    @Published public var showsAllPorts = false
    public var usbSerialPorts: [String] { availablePorts.filter { ScannerSerialPortKind.classify($0) == .usbSerial } }
    public var visiblePorts: [String] {
        usbSerialPorts + (showsAllPorts ? availablePorts.filter { ScannerSerialPortKind.classify($0) == .other } : [])
    }
    public static let noUSBAdapterNotice = "No USB serial adapter found · connect the scanner cable"
    private var observedUSBPorts: Set<String>?
    private var ownerDisconnected = false
    /// Der ausgewählte Pfad. Leer heißt: keiner.
    @Published public private(set) var selectedPortPath = ""
    @Published public private(set) var measurementMode: ScannerMeasurementMode
    /// Der eine sichtbare Zustand der Leiste -- abgeleitet, nie gesetzt.
    @Published public private(set) var barState: ConnectionBarState = .disconnected
    /// Der zuletzt beobachtete Bericht des Standardlaufs.
    @Published public private(set) var lastReport: StandardConnectionReport?
    /// Die echten Fortschrittsübergänge des laufenden oder letzten Laufs.
    @Published public private(set) var observedPhases: [StandardConnectionPhase] = []
    /// Ein Bedienhinweis außerhalb des Laufzustands (Besitzverweigerung,
    /// fehlender Anschluss). Verschwindet nur durch den nächsten
    /// erfolgreichen Bedienschritt an derselben Stelle.
    @Published public private(set) var notice: String?
    /// Die Laufstufe -- ob und welcher blockierende Aufruf gerade läuft.
    @Published public private(set) var runStage: ConnectionBarState.RunStage = .idle
    /// Der sichtbare Kandidatenfortschritt eines ausdrücklich gestarteten
    /// Automatiklaufs. `nil` bedeutet: keine automatische Suche.
    @Published public private(set) var automaticSearchProgress: AutomaticPortSearchProgress?
    /// Abgeschlossene Kandidaten dieses Automatiklaufs, in echter Reihenfolge.
    @Published public private(set) var automaticSearchAttempts: [AutomaticPortSearchAttempt] = []

    /// Die Präsentation des aktuellen Zustands -- reine Ableitung.
    public var presentation: ConnectionBarPresentation { ConnectionBarPresentation(barState) }

    /// Nach einer belegten Setup-Verbindung kann das Hauptfenster direkt
    /// wieder verbinden. Ohne diesen Beleg muss die App zuerst den sicheren
    /// Erkennungs-/Setup-Ablauf fahren und darf nicht den alten festen
    /// 38.400-Baud-Weg erraten.
    public var hasVerifiedDevelopmentEndpoint: Bool {
        verifiedDevelopmentEndpoint?.portPath == selectedPortPath
    }

    /// Die Evidenzkarte zum jetzigen Augenblick: Laufteil aus dem
    /// letzten Bericht, RX-Zahlen live vom Koordinator.
    public var evidence: ConnectionEvidence {
        ConnectionEvidence(
            portPath: runPortPath ?? selectedPortPath,
            phases: observedPhases,
            finalReport: lastReport,
            stream: coordinator.measurementStreamEvidence,
            referenceMeasurementLine: coordinator.referenceMeasurementLine
        )
    }

    /// Der redigierte Textexport der Evidenzkarte.
    public func evidenceExportText() -> String {
        ConnectionEvidenceExport.text(evidence)
    }

    // MARK: - Abhängigkeiten

    private let coordinator: StandardConnectionCoordinating
    private let runProvider: StandardConnectionRunProviding
    private let dispatcher: CommissioningDispatching
    private let portListing: SerialPortListing

    /// Der Lauf, solange er läuft **oder** den Port noch hält. Verworfen
    /// erst bei einem finalen, portfreien Bericht -- ein gescheiterter
    /// Schluss hält ihn fest, weil nur er den Retry ausführen kann.
    private var run: StandardConnectionRun?
    /// Der Port des laufenden bzw. letzten Laufs.
    private var runPortPath: String?
    /// Der Port, der zuletzt ausdrücklich getrennt wurde -- für die
    /// sichtbare Erklärung „der Scanner kann weiter senden".
    private var lastDisconnectedPort: String?
    /// Der zuletzt vom sicheren Setup-Ablauf belegte RX-Endpunkt. Er bleibt
    /// über ein Trennen hinweg erhalten, damit „Verbinden“ im Hauptfenster
    /// nicht wieder auf den alten festen 38.400-Baud-Lauf zurückfällt.
    private var verifiedDevelopmentEndpoint: (portPath: String, baudRate: SerialPortBaudRate)?
    /// Feste Momentaufnahme für genau einen Automatiklauf. Änderungen an der
    /// Geräteliste werden nie mitten in den Lauf hineingemischt.
    private var automaticCandidates: [String] = []
    private var automaticCandidateIndex: Int?
    /// Die RX-Kurzlage, gespiegelt aus dem Koordinator.
    private var measurement: MeasurementSessionStatus
    private var cancellables: Set<AnyCancellable> = []
    private var pendingDeviceSetup: (() -> Void)?
    private var deviceSetupOutputsReleased = false
    private var modeBeforeDeviceSetup: ScannerMeasurementMode = .mmk
    private let releaseOutputs: ((@escaping @Sendable () -> Void) -> Void)?
    private var deviceSetupGeneration: UUID?
    public func selectMeasurementMode(_ mode: ScannerMeasurementMode) {
        guard !deviceSetupActive, run == nil, runStage == .idle else { return }
        measurementMode = mode
        verifiedDevelopmentEndpoint = nil
    }
    @Published public private(set) var deviceSetupActive = false
    public var scannerMeasurementActive: Bool {
        switch measurement {
        case .opening, .openWithoutProfile, .streaming: return true
        case .idle, .failed, .simulation: return false
        }
    }
    private var scannerConnectionEstablished: Bool {
        switch measurement {
        case .openWithoutProfile, .streaming: return true
        case .idle, .opening, .failed, .simulation: return false
        }
    }

    /// The existing disconnect edge releases outputs before port release.
    /// A setup worker starts only once the RX owner reports its real close.
    public func beginDeviceSetup(mode: ScannerMeasurementMode, start: @escaping () -> Void) {
        guard !deviceSetupActive, run == nil, runStage == .idle else { return }
        guard let releaseOutputs else {
            notice = "Measurement change unavailable: no output release boundary is installed."
            return
        }
        let generation = UUID()
        ownerDisconnected = false
        deviceSetupGeneration = generation
        modeBeforeDeviceSetup = measurementMode
        measurementMode = mode
        verifiedDevelopmentEndpoint = nil
        deviceSetupActive = true
        deviceSetupOutputsReleased = false
        pendingDeviceSetup = start
        let completion = SerializedWork { [weak self] in
            guard self?.deviceSetupGeneration == generation else { return }
            self?.deviceSetupOutputsReleased = true
            self?.attemptDeviceSetup()
        }
        releaseOutputs { completion.run() }
    }

    public func cancelPendingDeviceSetup() {
        ownerDisconnected = true
        guard pendingDeviceSetup != nil else { return }
        pendingDeviceSetup = nil; deviceSetupActive = false
        deviceSetupGeneration = nil
        selectMeasurementMode(modeBeforeDeviceSetup)
        notice = "Measurement change cancelled before setup started."
    }

    private func attemptDeviceSetup() {
        guard deviceSetupOutputsReleased, let start = pendingDeviceSetup else { return }
        switch coordinator.requestCommissioningAccess() {
        case .granted:
            pendingDeviceSetup = nil
            start()
        case .awaitingMonitorRelease:
            notice = "Releasing outputs and waiting for the measurement port to close."
        case .refused(let refusal):
            pendingDeviceSetup = nil
            deviceSetupActive = false
            notice = Self.describe(refusal)
        }
    }

    public func finishDeviceSetup(portPath: String?, baudRate: SerialPortBaudRate?, mode: ScannerMeasurementMode) {
        guard deviceSetupActive, pendingDeviceSetup == nil else { return }
        deviceSetupActive = false
        deviceSetupGeneration = nil
        notice = nil
        measurementMode = mode
        coordinator.finishCommissioning(verifiedBaudRate: baudRate)
        if ownerDisconnected {
            if let portPath, let baudRate { verifiedDevelopmentEndpoint = (portPath, baudRate) }
            noteCancelledConnection(portPath: portPath ?? selectedPortPath)
            return
        }
        if let portPath, let baudRate { _ = connectDevelopment(portPath: portPath, baudRate: baudRate) }
        else { refreshBarState() }
    }

    /// Die einzige Rate, mit der ein erfolgreicher Standardlauf endet:
    /// alle vier Erfolgswege belegen den Messstrom bei 38.400.
    public static let measurementBaudRate: SerialPortBaudRate = .baud38400

    public init(
        coordinator: StandardConnectionCoordinating,
        runProvider: StandardConnectionRunProviding,
        dispatcher: CommissioningDispatching = SerialCommissioningDispatcher(),
        portListing: SerialPortListing = SystemSerialPortListing(),
        defaults: UserDefaults = .standard,
        releaseOutputs: ((@escaping @Sendable () -> Void) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.releaseOutputs = releaseOutputs
        self.measurementMode = .fullScan
        self.runProvider = runProvider
        self.dispatcher = dispatcher
        self.portListing = portListing
        self.measurement = coordinator.measurementSessionStatus
        // Besitzwechsel starten keinen neuen Lauf. Nur ein ausdrücklich
        // angeforderter Wechsel wartet hier auf den belegten RX-Schluss.
        coordinator.portOwnershipChanges
            .sink { [weak self, dispatcher] owner in
                self?.refreshBarState()
                if owner == .free, self?.pendingDeviceSetup != nil, self?.deviceSetupOutputsReleased == true {
                    dispatcher.deliverOnMain { self?.attemptDeviceSetup() }
                }
            }
            .store(in: &cancellables)
        coordinator.measurementSessionStatusChanges
            .sink { [weak self] status in
                self?.measurement = status
                self?.refreshBarState()
            }
            .store(in: &cancellables)
        refreshBarState()
    }

    // MARK: - Anschluss

    /// Liest die verfügbaren Pfade neu ein. **Wählt nie von selbst.**
    public func refreshPorts() {
        let paths = Array(Set(portListing.availablePortPaths())).sorted()
        if availablePorts != paths { availablePorts = paths }
    }

    /// Startup/hotplug decision. The caller supplies the explicit input choice
    /// and the existing setup route; this model never creates another port owner.
    public func checkUSBStartup(simulationSelected: Bool, start: ([String]) -> Void) {
        refreshPorts()
        let ports = usbSerialPorts, current = Set(ports)
        let previouslyObserved = observedUSBPorts
        let appeared = observedUSBPorts.map { !current.subtracting($0).isEmpty } ?? true
        observedUSBPorts = current
        guard appeared, !ownerDisconnected, !simulationSelected,
              !scannerConnectionEstablished, coordinator.portOwner != .simulation else { return }
        guard coordinator.portOwner == .free, !coordinator.isAwaitingPortRelease,
              !deviceSetupActive, run == nil, runStage == .idle else {
            // A new adapter remains pending until the existing owner really
            // releases the port. Connection, simulation and owner disconnect
            // above consume the event, so this cannot become a reconnect loop.
            observedUSBPorts = previouslyObserved
            return
        }
        guard !ports.isEmpty else { notice = Self.noUSBAdapterNotice; return }
        selectPort(ports[0])
        start(ports)
    }

    public func noteNoUSBAdapter() { notice = Self.noUSBAdapterNotice }

    /// Wählt einen Pfad. **Startet nichts.** Während eines laufenden
    /// oder porthaltenden Laufs bleibt die Auswahl gesperrt.
    public func selectPort(_ path: String) {
        guard !deviceSetupActive, runStage == .idle, run == nil else { return }
        if !selectedPortPath.isEmpty, selectedPortPath != path { coordinator.disconnect() }
        if verifiedDevelopmentEndpoint?.portPath != path {
            verifiedDevelopmentEndpoint = nil
        }
        selectedPortPath = path
        notice = nil
    }

    /// Ergebnis des bewussten Klicks auf „Automatisch“.
    public enum AutomaticConnectOutcome: Equatable, Sendable {
        case started(candidateCount: Int)
        case completedWithoutScanner
        case refusedBusy
        case refusedNoCandidates
        case refused(SerialPortOwnershipRefusal)
    }

    /// Prüft eine feste Momentaufnahme der verfügbaren Anschlüsse
    /// **sequenziell**. Jeder Kandidat benutzt exakt denselben
    /// ``StandardConnectionRun`` wie die manuelle Auswahl; es existiert kein
    /// zweites Telegramm-, Login- oder Baudwissen.
    @discardableResult
    public func connectAutomatically() -> AutomaticConnectOutcome {
        guard !deviceSetupActive, runStage == .idle, run == nil, automaticCandidateIndex == nil else {
            notice = "A connection attempt is already in progress."
            return .refusedBusy
        }

        refreshPorts()
        guard !usbSerialPorts.isEmpty else {
            notice = Self.noUSBAdapterNotice
            return .refusedNoCandidates
        }

        ownerDisconnected = false
        automaticCandidates = usbSerialPorts
        automaticCandidateIndex = 0
        automaticSearchAttempts = []
        notice = nil
        let count = automaticCandidates.count
        switch startCurrentAutomaticCandidate() {
        case .started:
            return .started(candidateCount: count)
        case .refusedBusy, .refusedNoPortSelected, .refusedRunUnavailable:
            // Diese Fälle werden vom Helfer entweder zum nächsten Kandidaten
            // weitergeführt oder als abgeschlossener Suchlauf sichtbar.
            return automaticCandidateIndex == nil ? .completedWithoutScanner : .refusedBusy
        case .awaitingPortRelease:
            cancelAutomaticSearch(keepAttempts: true)
            return .refused(.awaitingRelease)
        case .refused(let refusal):
            cancelAutomaticSearch(keepAttempts: true)
            return .refused(refusal)
        }
    }

    // MARK: - Verbinden

    /// Was aus einem Klick auf `Verbinden` wurde.
    public enum ConnectOutcome: Equatable, Sendable {
        /// Der Standardlauf ist gestartet.
        case started
        case refusedBusy
        case refusedNoPortSelected
        /// Der Monitor hielt den Port; sein kontrolliertes Trennen wurde
        /// veranlasst. Danach genügt ein erneuter Klick.
        case awaitingPortRelease
        case refused(SerialPortOwnershipRefusal)
        case refusedRunUnavailable(CommissioningRunUnavailableReason)
    }

    /// **Der Klick auf `Verbinden`.** Beansprucht den Port für den Lauf,
    /// baut genau einen ``StandardConnectionRun`` und plant dessen
    /// `connect(portPath:)` seriell ein.
    @discardableResult
    public func connect() -> ConnectOutcome {
        guard !deviceSetupActive, runStage == .idle, run == nil else {
            notice = "A connection attempt is already in progress."
            return .refusedBusy
        }
        guard !selectedPortPath.isEmpty else {
            notice = "Please select the port the scanner is connected to first."
            return .refusedNoPortSelected
        }
        ownerDisconnected = false
        if let endpoint = verifiedDevelopmentEndpoint,
           endpoint.portPath == selectedPortPath {
            switch connectVerifiedDevelopmentEndpoint(endpoint) {
            case .connecting:
                return .started
            case .refused(let refusal):
                return .refused(refusal)
            }
        }
        switch coordinator.requestCommissioningAccess() {
        case .granted:
            break
        case .awaitingMonitorRelease:
            notice = "The measurement session is being disconnected. Please tap \"Connect\" again shortly."
            refreshBarState()
            return .awaitingPortRelease
        case .refused(let refusal):
            notice = Self.describe(refusal)
            refreshBarState()
            return .refused(refusal)
        }

        let portPath = selectedPortPath
        let newRun: StandardConnectionRun
        do {
            newRun = try runProvider.makeRun(portPath: portPath, measurementMode: measurementMode) { [weak self, dispatcher] report in
                dispatcher.deliverOnMain { self?.noteProgress(report) }
            }
        } catch let reason as CommissioningRunUnavailableReason {
            coordinator.finishCommissioning(verifiedBaudRate: nil)
            notice = Self.describe(reason)
            refreshBarState()
            return .refusedRunUnavailable(reason)
        } catch {
            // **Kein fremder Fehler wird beschrieben** (SICK-032a1).
            coordinator.finishCommissioning(verifiedBaudRate: nil)
            notice = Self.describe(.transportUnavailable)
            refreshBarState()
            return .refusedRunUnavailable(.transportUnavailable)
        }

        run = newRun
        runPortPath = portPath
        lastDisconnectedPort = nil
        lastReport = nil
        observedPhases = []
        notice = nil
        runStage = .connecting
        // Die Laufkante synchron vor dem Einplanen reservieren
        // (SICK-0330a-1-K2) -- ein Abbruch in der Lücke trifft den Lauf.
        newRun.beginRun()
        refreshBarState()

        dispatcher.runSerialized { [self, dispatcher] in
            let report = newRun.connect(portPath: portPath)
            dispatcher.deliverOnMain { [self] in
                finishConnect(with: report, run: newRun)
            }
        }
        return .started
    }

    /// Verbindet nach einer expliziten Entwicklungs-/Setup-Transaktion
    /// mit deren belegter Rate. Die App-Oberflaeche spricht auch fuer
    /// diesen Sonderweg niemals direkt mit dem Koordinator.
    @discardableResult
    public func connectDevelopment(
        portPath: String,
        baudRate: SerialPortBaudRate
    ) -> MonitorConnectOutcome {
        guard !deviceSetupActive, runStage == .idle, run == nil else {
            return .refused(.heldByCommissioning)
        }
        guard !portPath.isEmpty else {
            notice = "Please select the port the scanner is connected to first."
            return .refused(.awaitingRelease)
        }
        let endpoint = (portPath: portPath, baudRate: baudRate)
        ownerDisconnected = false
        selectedPortPath = portPath
        verifiedDevelopmentEndpoint = endpoint
        return connectVerifiedDevelopmentEndpoint(endpoint)
    }

    private func connectVerifiedDevelopmentEndpoint(
        _ endpoint: (portPath: String, baudRate: SerialPortBaudRate)
    ) -> MonitorConnectOutcome {
        let outcome = coordinator.connectDevelopment(
            portPath: endpoint.portPath,
            baudRate: endpoint.baudRate
        )
        switch outcome {
        case .connecting:
            runPortPath = nil
            lastReport = nil
            observedPhases = []
            lastDisconnectedPort = nil
            notice = "Verified scanner state: receiving at \(endpoint.baudRate.rawValue) baud."
        case .refused(let refusal):
            notice = Self.describe(refusal)
        }
        refreshBarState()
        return outcome
    }

    /// **Der Klick auf `Trennen`.** Während eines laufenden Standardlaufs
    /// ist das ein kooperativer Abbruch; bei laufender RX-Sitzung das
    /// kontrollierte Trennen. Trennen behauptet nichts über das Gerät:
    /// Der Scanner kann weiter senden, und die Leiste sagt das.
    public func disconnect() {
        ownerDisconnected = true
        if let run, runStage == .connecting {
            cancelAutomaticSearch(keepAttempts: true)
            run.requestAbort()
            return
        }
        switch measurement {
        case .opening(let portPath), .openWithoutProfile(let portPath), .streaming(let portPath, _):
            lastDisconnectedPort = portPath
            coordinator.disconnect()
        case .failed(let portPath, _):
            lastDisconnectedPort = portPath
            coordinator.disconnect()
        case .simulation(let status):
            switch status {
            case .opening(let service), .openWithoutProfile(let service), .streaming(let service, _), .failed(let service, _):
                lastDisconnectedPort = "iPhone-Simulation \(service)"
                coordinator.disconnect()
            }
        case .idle:
            break
        }
        notice = nil
        refreshBarState()
    }

    /// Der ausdrückliche erneute Schließversuch nach einem gescheiterten
    /// Schluss -- **genau ein realer Versuch** je Klick.
    public func retryClose() {
        guard let run, runStage == .idle, lastReport?.isPortHeld == true else { return }
        runStage = .retryingClose
        refreshBarState()
        dispatcher.runSerialized { [self, dispatcher] in
            let report = run.retryClose()
            dispatcher.deliverOnMain { [self] in
                resolvePortRelease(with: report, run: run)
            }
        }
    }

    // MARK: - Berichtsauswertung (ausschließlich Kontroll-Thread)

    /// Ein Zwischenbericht der Fortschrittsgrenze.
    private func noteProgress(_ report: StandardConnectionReport) {
        guard run != nil else { return }
        if observedPhases.last != report.phase {
            observedPhases.append(report.phase)
        }
        lastReport = report
        refreshBarState()
    }

    /// Der Endbericht von `connect(portPath:)`.
    private func finishConnect(with report: StandardConnectionReport, run finishedRun: StandardConnectionRun) {
        guard finishedRun === run else { return }
        noteProgress(report)

        switch report.phase {
        case .ready:
            guard report.isPortHeld else {
                // Strukturell nicht vorgesehen: `connect` lässt einen
                // Erfolgsport offen. Sichtbar entschieden statt still.
                startMeasurement(after: report)
                return
            }
            runStage = .releasingTransmitPort
            refreshBarState()
            dispatcher.runSerialized { [self, dispatcher] in
                let released = finishedRun.releasePortForMeasurement()
                dispatcher.deliverOnMain { [self] in
                    resolvePortRelease(with: released, run: finishedRun)
                }
            }
        case .failed, .idle, .observingPassively, .checkingIdentityAtTargetRate, .runningCommissioning:
            resolvePortRelease(with: report, run: finishedRun)
        }
    }

    /// Wertet einen Bericht nach einem Schließversuch (Erfolgsfreigabe,
    /// Fehlschluss, Retry) aus.
    private func resolvePortRelease(with report: StandardConnectionReport, run finishedRun: StandardConnectionRun) {
        guard finishedRun === run else { return }
        noteProgress(report)
        runStage = .idle

        if report.isPortHeld {
            // Der Port ist real noch offen -- gleich, was der Anlass war.
            // Der Lauf bleibt, damit ein Retry ihn schließen kann; der
            // Besitz bleibt beim Lauf.
            refreshBarState()
            return
        }

        // Port wirklich frei: Besitz genau einmal zurückgeben.
        run = nil
        if case .ready = report.phase {
            recordAutomaticAttempt(portPath: runPortPath, result: .ready)
            cancelAutomaticSearch(keepAttempts: true)
            startMeasurement(after: report)
        } else {
            coordinator.finishCommissioning(verifiedBaudRate: nil)
            if continueAutomaticSearch(after: report) {
                return
            }
            refreshBarState()
        }
    }

    // MARK: - Automatischer Portkandidatenlauf

    /// Startet den aktuellen Kandidaten. Synchron verweigerte bzw. nicht
    /// herstellbare Läufe werden ebenfalls sequenziell weitergeführt.
    private func startCurrentAutomaticCandidate() -> ConnectOutcome {
        guard let index = automaticCandidateIndex, automaticCandidates.indices.contains(index) else {
            finishAutomaticSearchWithoutScanner()
            return .refusedNoPortSelected
        }
        let path = automaticCandidates[index]
        selectedPortPath = path
        automaticSearchProgress = AutomaticPortSearchProgress(
            portPath: path,
            candidateNumber: index + 1,
            candidateCount: automaticCandidates.count
        )

        let outcome = connect()
        switch outcome {
        case .started:
            // Ein bereits verifizierter Entwicklungsendpunkt geht direkt in
            // RX und erzeugt keinen Standardlauf.
            if run == nil {
                recordAutomaticAttempt(portPath: path, result: .ready)
                cancelAutomaticSearch(keepAttempts: true)
            }
            return outcome
        case .refusedRunUnavailable(let reason):
            recordAutomaticAttempt(portPath: path, result: .runUnavailable(reason))
            if advanceAutomaticCandidate() {
                return startCurrentAutomaticCandidate()
            }
            finishAutomaticSearchWithoutScanner()
            return outcome
        case .refusedBusy, .refusedNoPortSelected, .awaitingPortRelease, .refused:
            return outcome
        }
    }

    /// Nur Befunde, die den Anschluss nicht als Scanner belegen, gehen zum
    /// nächsten Port. Sobald der Scanner erkennbar antwortete, bleibt sein
    /// konkreter Handlungsfehler sichtbar statt an einem anderen Port
    /// überschrieben zu werden.
    private func continueAutomaticSearch(after report: StandardConnectionReport) -> Bool {
        guard automaticCandidateIndex != nil,
              let portPath = runPortPath,
              case .failed(let failure) = report.phase else { return false }

        recordAutomaticAttempt(portPath: portPath, result: .failed(failure))
        switch failure {
        case .aborted, .portCloseFailed, .missingOrUnusablePassword,
             .settingsModeRejected, .settingsModeUnanswered, .settingsModeAmbiguous,
             .loginRejected, .loginUnanswered, .loginAmbiguous,
             .baudSwitchRejected, .baudSwitchUnanswered, .baudSwitchAmbiguous,
             .targetRateSilent, .targetRateUnexpectedResponse, .targetRateAmbiguousResponse,
             .measurementModeRejected, .measurementStreamAbsent, .measurementPointCountMismatch,
             .unexpectedEvent:
            cancelAutomaticSearch(keepAttempts: true)
            return false
        case .invalidPort, .portOpenFailed, .portReadFailed, .portWriteFailed,
             .manualPreparationRequired, .startingRateSilent,
             .startingRateUnexpectedResponse, .startingRateAmbiguousResponse:
            break
        }

        if advanceAutomaticCandidate() {
            _ = startCurrentAutomaticCandidate()
            return true
        }
        finishAutomaticSearchWithoutScanner()
        return false
    }

    private func advanceAutomaticCandidate() -> Bool {
        guard let index = automaticCandidateIndex else { return false }
        let next = index + 1
        guard automaticCandidates.indices.contains(next) else { return false }
        automaticCandidateIndex = next
        return true
    }

    private func finishAutomaticSearchWithoutScanner() {
        cancelAutomaticSearch(keepAttempts: true)
        notice = "None of the checked ports had a scanner connected."
        refreshBarState()
    }

    private func cancelAutomaticSearch(keepAttempts: Bool) {
        automaticCandidateIndex = nil
        automaticCandidates = []
        automaticSearchProgress = nil
        if !keepAttempts { automaticSearchAttempts = [] }
    }

    private func recordAutomaticAttempt(
        portPath: String?, result: AutomaticPortSearchAttempt.Result
    ) {
        guard automaticCandidateIndex != nil, let portPath else { return }
        automaticSearchAttempts.append(.init(portPath: portPath, result: result))
    }

    /// RX beginnt -- **ausschließlich** aus einem portfreien Erfolgsbericht.
    private func startMeasurement(after report: StandardConnectionReport) {
        precondition(!report.isPortHeld, "RX darf nie bei gehaltenem TX-Port beginnen")
        guard let portPath = runPortPath else { return }
        coordinator.finishCommissioning(verifiedBaudRate: Self.measurementBaudRate)
        guard !ownerDisconnected else { noteCancelledConnection(portPath: portPath); return }
        switch coordinator.connect(portPath: portPath, baudRate: Self.measurementBaudRate) {
        case .connecting:
            notice = nil
        case .refused(let refusal):
            notice = Self.describe(refusal)
        }
        refreshBarState()
    }

    private func noteCancelledConnection(portPath: String) {
        lastDisconnectedPort = portPath.isEmpty ? nil : portPath
        notice = "Connection cancelled by user."
        refreshBarState()
    }

    private func refreshBarState() {
        let next = ConnectionBarState.derive(
            run: lastReport,
            runPortPath: runPortPath,
            stage: runStage,
            measurement: measurement,
            isAwaitingPortRelease: coordinator.isAwaitingPortRelease,
            lastDisconnectedPort: lastDisconnectedPort
        )
        if barState != next { barState = next }
    }

    // MARK: - Texte (im Modell, nicht in der Ansicht)

    private static func describe(_ refusal: SerialPortOwnershipRefusal) -> String {
        switch refusal {
        case .heldByMonitor: return "The measurement session is still using this port. Please disconnect first."
        case .heldByCommissioning: return "The scanner setup is already using this port. Please tap \"Done\" there first."
        case .heldBySimulation: return "The iPhone simulation is still using this port. Please disconnect first."
        case .heldBySimulationControl: return "The simulation is being switched. One moment."
        case .awaitingRelease: return "The port is being closed. One moment."
        }
    }

    private static func describe(_ reason: CommissioningRunUnavailableReason) -> String {
        switch reason {
        case .noPortSelected:
            return "No port is selected."
        case .pathNotAllowed(let path):
            return "Port \(path) is not allowed for the scanner."
        case .transportUnavailable:
            return "The port could not be prepared. Nothing was sent. "
                + "Please check the cable and selection, then try again."
        }
    }
}
