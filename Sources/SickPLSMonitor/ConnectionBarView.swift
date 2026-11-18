import SwiftUI
import PlanariumInput
import SickPLSCommissioningControl
import SickPLSSetupControl
import SickPLSCommissioning
import PlanariumRuntime
import SickPLSSimulationControl

/// Both the scene's USB startup and the buttons reuse the existing setup handoff.
@MainActor extension StandardConnectionControlModel {
    func startScannerSetup(using setup: SetupConsoleModel, remainingPorts: [String] = []) {
        guard !selectedPortPath.isEmpty else { return }
        setup.selectedPort = selectedPortPath
        setup.baudSwitchTarget = .baud500000
        setup.targetAddressText = "00"
        beginDeviceSetup(mode: .fullScan) {
            setup.performSafeBaudTransition(measurementMode: .fullScan) { endpoint, actualMode in
                self.finishDeviceSetup(portPath: endpoint?.portPath, baudRate: endpoint?.baudRate, mode: actualMode)
                if endpoint == nil, setup.canTryAnotherPort, let next = remainingPorts.first {
                    self.selectPort(next)
                    self.startScannerSetup(using: setup, remainingPorts: Array(remainingPorts.dropFirst()))
                }
            }
        }
    }
    func startAutomaticScannerSetup(using setup: SetupConsoleModel) {
        refreshPorts()
        guard let first = usbSerialPorts.first else { noteNoUSBAdapter(); return }
        selectPort(first)
        startScannerSetup(using: setup, remainingPorts: Array(usbSerialPorts.dropFirst()))
    }
}

/// Scene-owned listing watch, independent of whether Setup is visible.
/// IOKit notifications read names only; setup retains sole port ownership.
@MainActor final class ScannerUSBStartupMonitor: ObservableObject {
    private let connection: StandardConnectionControlModel
    private let setup: SetupConsoleModel
    private let simulation: SimulationConnectionControlModel
    private let clock: any RuntimeClock
    private let changes: any ScannerUSBChangeWatching
    private var poll: RuntimeCancellation?
    private var generation: UUID?
    init(connection: StandardConnectionControlModel, setup: SetupConsoleModel,
         simulation: SimulationConnectionControlModel, clock: any RuntimeClock = MonotonicRuntimeClock(),
         changes: (any ScannerUSBChangeWatching)? = nil) {
        self.connection = connection; self.setup = setup; self.simulation = simulation; self.clock = clock; self.changes = changes ?? ScannerUSBChanges()
    }
    func start() {
        guard generation == nil else { return }
        let generation = UUID(); self.generation = generation
        let installed = changes.start { [weak self] in self?.check(generation) }
        // Arm before listing: a device arriving between listing and initial
        // notification drain must not disappear into that startup gap.
        check(generation)
        if !installed { checkAndSchedule(generation) }
    }
    func stop() { generation = nil; changes.stop(); poll?.cancel(); poll = nil }
    private func check(_ generation: UUID) {
        guard self.generation == generation else { return }
        connection.checkUSBStartup(simulationSelected: simulation.input == .iPhoneSimulation) { ports in
            guard !setup.isBusy else { return }
            connection.startScannerSetup(using: setup, remainingPorts: Array(ports.dropFirst()))
        }
    }
    /// Fallback only if the OS rejects registration. The clock's tolerance is
    /// opt-in; musical deadlines continue using the original exact method.
    private func checkAndSchedule(_ generation: UUID) {
        guard self.generation == generation else { return }
        poll = clock.scheduleCoalescible(at: clock.now + 1, tolerance: 0.2, on: .main) { [weak self] in
            MainActor.assumeIsolated { self?.check(generation); self?.checkAndSchedule(generation) }
        }
    }
    deinit { poll?.cancel() }
}

/// Die **kompakte Verbindungsleiste** (SICK-0330b, absorbiert SICK-0331):
/// Anschlussauswahl, Verbinden/Trennen, Status und Fortschritt -- keine
/// Baudauswahl, keine Protokolldetails, aber ehrliche Gerätewirkung.
///
/// **Reine Komposition.** Ablauf, Besitz, Threadwechsel und Zustand liegen
/// in den beiden Control-Modellen; die reine Auswahlregel zwischen sicherer
/// Baudratenerkennung und Standardsuche liegt in `SickPLSSetupControl`.
/// Hier steht kein Transport, kein Lauf und keine Zeitquelle. Diese Ansicht ist seit SICK-0330b der
/// **einzige** Verbindungsweg der App -- die frühere direkte
/// Monitorverbindung mit Baudauswahl ist ersatzlos entfallen.
struct ConnectionBarView: View {
    @ObservedObject var model: StandardConnectionControlModel
    @ObservedObject var scannerSetup: SetupConsoleModel
    var rate: ProfileRateDisplayModel? = nil

    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("connection.buttons")
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection").font(.headline)
            if model.deviceSetupActive || scannerSetup.isBusy {
                IconActionButton("Abort measurement change", symbol: "xmark") {
                    model.cancelPendingDeviceSetup()
                    scannerSetup.abortSafeTransition()
                }
            }

            HStack(spacing: 8) {
                portMenu
                iconButton("arrow.clockwise", "Refresh ports") { model.refreshPorts() }
                    .disabled(model.presentation.isBusy)
            }
            Toggle("Show all ports", isOn: $model.showsAllPorts)
                .font(.caption).toggleStyle(ReadableCheckboxStyle())

            if let progress = model.automaticSearchProgress {
                Text(progress.operatorText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connection.automaticProgress")
            }

            HStack(spacing: 8) {
                statusSymbol
                Group {
                    if !scannerSetup.isBusy, case .ready = model.barState, let rate {
                        ProfileRateText(rate: rate) { ConnectionBarPresentation(model.barState, profileRateHz: $0).statusText }
                    } else { Text(scannerSetup.isBusy ? scannerSetup.status : model.presentation.statusText) }
                }.font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connection.status")
            }

            if let next = model.presentation.nextActionText {
                Text(next)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if model.presentation.showsDisconnect {
                    iconButton("xmark", "Disconnect") {
                        if model.deviceSetupActive { model.cancelPendingDeviceSetup(); scannerSetup.abortSafeTransition() }
                        else { model.disconnect() }
                    }
                        .accessibilityIdentifier("connection.disconnect")
                } else if model.presentation.offersCloseRetry {
                    iconButton("arrow.clockwise", "Retry closing port") { model.retryClose() }
                        .accessibilityIdentifier("connection.retryClose")
                } else {
                    iconButton("link", "Connect") { connect() }
                        .disabled(model.selectedPortPath.isEmpty || model.presentation.isBusy || model.deviceSetupActive || scannerSetup.isBusy)
                        .accessibilityIdentifier("connection.connect")
                    iconButton("wand.and.stars", "Connect automatically") { connectAutomatically() }
                        .disabled(model.presentation.isBusy || scannerSetup.isBusy)
                        .accessibilityIdentifier("connection.connectAutomatically")
                }
            }

            if let notice = model.notice ?? setupNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.refreshPorts() }
    }

    private func connect() {
        model.startScannerSetup(using: scannerSetup)
    }

    private func connectAutomatically() {
        model.startAutomaticScannerSetup(using: scannerSetup)
    }

    private var setupNotice: String? {
        guard scannerSetup.status != "Disconnected." else { return nil }
        return scannerSetup.status
    }

    private func iconButton(
        _ symbol: String, _ label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { FieldToolbarIconLabel(title: label, symbol: symbol).frame(minWidth: 22, minHeight: 22).contentShape(Rectangle()) }
            .buttonStyle(.borderless)
            .help(label)
            .iconAccessibility(label)
    }

    private var portMenu: some View {
        Menu {
            ScannerPortListView(model: model)
        } label: {
            Label(
                model.selectedPortPath.isEmpty ? "Choose port" : model.selectedPortPath,
                systemImage: "cable.connector"
            )
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .disabled(model.presentation.isBusy || model.deviceSetupActive || scannerSetup.isBusy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Choose the scanner port.")
    }

    /// Das Steckersymbol: grün bereit, gelb unterwegs, rot bei Fehler
    /// oder Verlust, grau getrennt. Die Zuordnung steht hier, weil sie
    /// reine Darstellung ist; **jeder Fall** ist benannt.
    private var statusSymbol: some View {
        let (name, color): (String, Color)
        if scannerSetup.isBusy {
            return Image(systemName: "circle.dotted").foregroundColor(.orange)
        }
        switch model.barState {
        case .disconnected, .disconnectedScannerMaySend:
            (name, color) = ("circle", .secondary)
        case .observing, .checkingIdentity, .preparing, .closingTransmitPort,
             .openingMeasurement, .awaitingFirstProfile, .disconnecting:
            (name, color) = ("circle.dotted", .orange)
        case .transmitPortStillHeld, .streamLost, .failed:
            (name, color) = ("exclamationmark.triangle.fill", .red)
        case .ready:
            (name, color) = ("circle.fill", .green)
        case .inputIsSimulation:
            (name, color) = ("circle.fill", .orange)
        }
        return Image(systemName: name).foregroundColor(color)
    }
}

struct ScannerPortListView: View {
    @ObservedObject var model: StandardConnectionControlModel
    var body: some View {
        if model.visiblePorts.isEmpty { Text(StandardConnectionControlModel.noUSBAdapterNotice) }
        ForEach(model.visiblePorts, id: \.self) { path in
            SelectionMenuItem(path, selected: model.selectedPortPath == path) { model.selectPort(path) }
        }
    }
}
