import SwiftUI
import PlanariumInput
import SickPLSCommissioningControl
import SickPLSSetupControl
import SickPLSSimulationControl

struct SimulationInputSwitchView: View {
    @ObservedObject var simulation: SimulationConnectionControlModel
    let scannerBar: AnyView
    var rate: ProfileRateDisplayModel? = nil

    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("simulation.switch")
        VStack(alignment: .leading, spacing: 8) {
            SimulationInputPickerView(model: simulation)
            if simulation.input == .iPhoneSimulation {
                SimulationBarView(model: simulation, rate: rate)
            } else {
                scannerBar
            }
        }
    }
}

struct SimulationInputBadgeView: View {
    @ObservedObject var model: SimulationConnectionControlModel

    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("simulation.badge")
        Group {
            if model.input == .iPhoneSimulation {
                Text("Simulation")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .accessibilityIdentifier("measurement.simulationBadge")
            }
        }
    }
}

struct SimulationInputPickerView: View {
    @ObservedObject var model: SimulationConnectionControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Input", selection: Binding(
                get: { model.input },
                set: { model.selectInput($0) }
            )) {
                ForEach(SimulationInputChoice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.selectionPresentation.isEnabled)
            Text(model.selectionPresentation.statusText)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("simulation.inputPicker")
    }
}

struct SimulationBarView: View {
    @ObservedObject var model: SimulationConnectionControlModel
    var rate: ProfileRateDisplayModel? = nil

    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("simulation.buttons")
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("iPhone simulation").font(.headline)
                Spacer()
                Text("SIMULATION")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange, in: Capsule())
                    .accessibilityIdentifier("simulation.badge")
            }

            Menu {
                if model.services.isEmpty {
                    Text("No iPhone simulation found")
                }
                ForEach(model.services) { service in
                    SelectionMenuItem(service.name, selected: model.selectedServiceID == service.id) { model.selectedServiceID = service.id }
                }
            } label: {
                Label(model.selectedService?.name ?? "Select simulation", systemImage: "iphone")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .disabled(!canSelectService)

            Group {
                if case .ready(_, let points) = model.barState, let rate, !modeSwitchIsBusy {
                    ProfileRateText(rate: rate) { value in
                        let text = value.map { String(format: "%.1f Hz", $0) } ?? "Rate being determined"
                        return "Ready – \(points) points, \(text)."
                    }
                } else { Text(activeStatusText) }
            }.font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("simulation.status")

            if case .finished = model.modeSwitch,
               let resultText = SimulationConnectionControlModel.modeSwitchText(model.modeSwitch) {
                Text(resultText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .finished(.minimumPerSegment, .acknowledged) = model.modeSwitch {
                Text("This mode is not emulated in the simulation; it sends no profiles. Go back with 'All measurements continuously'.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let nextActionText {
                Text(nextActionText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("Measurement mode")
                    .font(.caption.weight(.semibold))
                Button("All measurements continuously") { model.switchMode(.fullScan) }
                    .disabled(!model.canSwitchMode)
                    .accessibilityIdentifier("simulation.mode.fullScan")
                Button("Min. measurements continuously") { model.switchMode(.minimumPerSegment) }
                    .disabled(!model.canSwitchMode)
                    .accessibilityIdentifier("simulation.mode.minimum")
            }

            HStack {
                if isConnected {
                    iconButton("xmark", "Disconnect") { model.disconnect() }
                        .accessibilityIdentifier("simulation.disconnect")
                } else {
                    iconButton("link", "Connect") { model.connect() }
                        .disabled(model.selectedService == nil || !canConnect)
                        .accessibilityIdentifier("simulation.connect")
                }
                iconButton("arrow.clockwise", "Search again") { model.startDiscovery() }
                    .disabled(!canConnect)
            }
        }
        .onAppear { model.startDiscovery() }
        .onDisappear { model.stopDiscovery() }
    }

    private var canConnect: Bool {
        model.selectionPresentation.isEnabled && model.input == .iPhoneSimulation
    }

    private var canSelectService: Bool {
        switch model.barState {
        case .found, .lost:
            return !model.services.isEmpty
        case .noDevices, .connecting, .waitingForFirstProfile, .ready, .disconnecting:
            return false
        }
    }

    private var isConnected: Bool {
        switch model.barState {
        case .connecting, .waitingForFirstProfile, .ready, .disconnecting:
            return true
        case .noDevices, .found, .lost:
            return false
        }
    }

    private var statusText: String {
        switch model.barState {
        case .noDevices: return "No iPhone simulation found on the local network."
        case .found(let names): return names.isEmpty ? "No iPhone simulation found." : "Simulation found – ready to connect."
        case .connecting(let name): return "Connecting to \(name) …"
        case .waitingForFirstProfile(let name): return "Connected to \(name) – waiting for the first profile."
        case .ready(_, let points): return "Ready – \(points) points, Rate being determined."
        case .lost(_, let message): return message
        case .disconnecting: return "Disconnecting simulation."
        }
    }

    private var modeSwitchIsBusy: Bool {
        switch model.modeSwitch {
        case .awaitingRelease, .running, .blocked: return true
        case .idle, .finished: return false
        }
    }
    private var activeStatusText: String {
        switch model.modeSwitch {
        case .awaitingRelease, .running, .blocked:
            return SimulationConnectionControlModel.modeSwitchText(model.modeSwitch) ?? statusText
        case .idle, .finished:
            return statusText
        }
    }

    private var nextActionText: String? {
        if case .lost(_, let message) = model.barState,
           message.contains("Local network") {
            return "Allow local network access in macOS, then connect again."
        }
        return nil
    }

    private func iconButton(
        _ symbol: String, _ label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { FieldToolbarIconLabel(title: label, symbol: symbol).frame(minWidth: 22, minHeight: 22).contentShape(Rectangle()) }
            .buttonStyle(.borderless)
            .help(label)
            .iconAccessibility(label)
    }
}
