import AppKit
import Combine
import SwiftUI
import SickPLSCommissioningControl
import SickPLSMacTransport
import PlanariumScannerUI
import PlanariumInput
import SickPLSSetupControl
import PlanariumApplication

/// Bewusst manuelle Entwicklungsoberfläche. Kein Befehl läuft automatisch;
/// der normale Produktweg in der Hauptansicht bleibt davon unabhängig.
struct ScannerDevelopmentSettingsView: View {
    let model: SetupConsoleModel
    let connection: StandardConnectionControlModel
    let coordinator: InputOwner
    let instrument: SpatialInstrumentRuntimeModel
    let recording: ProfileRecordingModel

    @State private var controls: SetupControlsSnapshot?
    @State private var connectionActive = false
    var body: some View {
        let _ = controls // Register the projected @State as a rendering dependency.
        let _ = ViewEvaluationProbe.current?.record("settings.development.buttons")
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Scanner Development").font(.title2.bold())
                ProfileRecordingControls(recording: recording, instrument: instrument)
                Text("Disconnect the normal theremin connection before use. Each TX step is triggered individually and fully logged.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ScannerDevelopmentLiveStatus(model: model, coordinator: coordinator)

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Port", selection: Binding(get: { model.selectedPort }, set: { model.selectedPort = $0 })) {
                            Text("– select –").tag("")
                            ForEach(model.ports, id: \.self) { Text($0).tag($0) }
                        }
                        .disabled(model.isOpen || model.isBusy)
                        Picker("Host Baud Rate", selection: Binding(get: { model.selectedBaudRate }, set: { model.selectedBaudRate = $0 })) {
                            baudChoices
                        }
                        .disabled(model.isOpen || model.isBusy)
                        TextField("Target address (hex, set on PLS101-316: 00)", text: Binding(get: { model.targetAddressText }, set: { model.targetAddressText = $0 }))
                            .font(.system(.body, design: .monospaced))
                        HStack {
                            Button("Search again") { model.refreshPorts() }
                            Button("Detect scanner state") { model.detectScannerState() }
                                .disabled(model.selectedPort.isEmpty || model.isBusy)
                            Button("Open port") { model.openSelectedPort() }
                                .disabled(model.selectedPort.isEmpty || model.isOpen || model.isBusy)
                            Button("Close") { model.closePort() }
                                .disabled(!model.isOpen || model.isBusy)
                        }
                        Text(model.status).font(.caption).textSelection(.enabled)
                    }.padding(6)
                }

                GroupBox("Setup and Baud Rate") {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Scanner password (8 bytes)", text: Binding(get: { model.password }, set: { model.password = $0 }))
                        HStack {
                            Button("Identity 31") { model.sendIdentity() }
                            Button("Settings mode 20 30") { model.sendSettingsMode() }
                            Button("Login 20 00") { model.sendLogin() }
                        }
                        .disabled(!model.isOpen || model.isBusy)
                        Picker("Target baud rate", selection: Binding(get: { model.baudSwitchTarget }, set: { model.baudSwitchTarget = $0 })) {
                            Text("9600 · 20 42").tag(SerialPortBaudRate.baud9600)
                            Text("38400 · 20 40").tag(SerialPortBaudRate.baud38400)
                            Text("500000 · 20 48").tag(SerialPortBaudRate.baud500000)
                        }
                        HStack {
                            Button("Connect with Full scan 361") {
                                model.performSafeBaudTransition()
                            }
                            .disabled(model.selectedPort.isEmpty || model.isBusy)
                            Button("Send baud switch") { model.sendBaudSwitch() }
                                .disabled(!model.isOpen || model.isBusy)
                            Button("Reconnect host") { model.reconnectAtSelectedBaud() }
                                .disabled(!model.isOpen || model.isBusy)
                        }
                        Text("The safe sequence discards assumptions from a previous app run, detects 500000/38400/9600, verifies each step, and releases the port only after a valid B0 measurement stream.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Measurement mode") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Operating mode", selection: Binding(get: { model.selectedMeasurementMode }, set: { model.selectedMeasurementMode = $0 })) {
                            ForEach(SetupMeasurementMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        if model.selectedMeasurementMode == .customSubrange {
                            HStack {
                                TextField("Start 1…361", text: Binding(get: { model.subrangeStartText }, set: { model.subrangeStartText = $0 }))
                                TextField("End 1…361", text: Binding(get: { model.subrangeStopText }, set: { model.subrangeStopText = $0 }))
                            }.font(.system(.body, design: .monospaced))
                        }
                        if model.selectedMeasurementMode.isExperimentalSubrange {
                            Text("0x27 is not yet positively confirmed. 90° uses 91…271, 120° uses 61…301; the last real attempt fell back to 9600 baud.")
                                .font(.caption).foregroundColor(.orange)
                        }
                        Button("Send selected mode") { model.sendMeasurementMode() }
                            .disabled(!model.isOpen || model.isBusy)
                    }.padding(6)
                }

                GroupBox("App Connection") {
                    VStack(alignment: .leading, spacing: 8) {
                        ScannerMeasurementSummary(coordinator: coordinator)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("A successful safe setup sequence automatically connects the entire app. B0 profiles appear in the main window and feed zones, synthesizer, and MIDI.")
                            .font(.caption).foregroundColor(.secondary)
                        Button("Disconnect") { connection.disconnect() }
                            .disabled(!connectionActive)
                    }.padding(6)
                }

                ScannerDevelopmentLog(model: model)
            }
            .padding(20)
        }
        .frame(width: 620, height: 720)
        .stageSettings()
        .onAppear { model.refreshPorts(); controls = SetupControlsSnapshot(model); connectionActive = scannerConnectionActive(coordinator.measurementSessionStatus) }
        .onReceive(model.objectWillChange.receive(on: RunLoop.main).map { SetupControlsSnapshot(model) }.removeDuplicates()) {
            if controls != $0 { controls = $0 }
        }
        .onReceive(coordinator.measurementSessionStatusChanges.map(scannerConnectionActive).removeDuplicates()) {
            if connectionActive != $0 { connectionActive = $0 }
        }
    }

    @ViewBuilder private var baudChoices: some View {
        Text("9600").tag(SerialPortBaudRate.baud9600)
        Text("38400").tag(SerialPortBaudRate.baud38400)
        Text("500000").tag(SerialPortBaudRate.baud500000)
    }
}

struct ProfileRecordingControls: View {
    @ObservedObject var recording: ProfileRecordingModel
    let instrument: SpatialInstrumentRuntimeModel
    var body: some View {
        GroupBox("Record profiles") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Record profiles · 10 s") {
                        recording.begin(detection: instrument.document.detection, contour: instrument.roomContour)
                    }.disabled(recording.isRecording).accessibilityIdentifier("scanner.recordProfiles")
                    if recording.isRecording { Button("Cancel") { recording.cancel() } }
                }
                HStack {
                    Button("Show in Finder") {
                        if let url = recording.savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }.disabled(recording.savedURL == nil)
                }
                if recording.isRecording { ProgressView(value: recording.progress) }
                Text(recording.notice).font(.caption).textSelection(.enabled)
                Text("Raw profiles only · allowed in Perform · saved in Application Support/Planarium/Recordings")
                    .font(.caption).foregroundColor(.secondary)
            }.padding(6)
        }
    }
}

private func scannerConnectionActive(_ status: MeasurementSessionStatus) -> Bool {
    switch status {
    case .idle, .failed: return false
    case .opening, .openWithoutProfile, .streaming, .simulation: return true
    }
}

private struct ScannerMeasurementSummary: View {
    let coordinator: InputOwner
    @State private var status: MeasurementSessionStatus = .idle
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("settings.liveRate")
        ProfileRateText(rate: coordinator.profileRateDisplay, text: summary).onReceive(coordinator.measurementSessionStatusChanges) { status = $0 }
    }
    private func summary(_ rate: Double?) -> String {
        switch status {
        case .idle:
            return "Measurement path: disconnected"
        case .opening(let portPath):
            return "Measurement path: opening \(portPath)"
        case .openWithoutProfile(let portPath):
            return "Measurement path: \(portPath) open, no valid B0 profile yet"
        case .streaming(let portPath, let points):
            let rateText = rate.map { String(format: "%.2f Hz", $0) } ?? "Rate being measured"
            return "Measurement path: \(portPath) · \(points) points · \(rateText)"
        case .failed(let portPath, let message):
            return "Measurement path failed: \(portPath) · \(message)"
        case .simulation(let status):
            switch status {
            case .opening(let service): return "Measurement path: simulation \(service) opening"
            case .openWithoutProfile(let service): return "Measurement path: simulation \(service) open, no profile yet"
            case .streaming(let service, let points):
                let rateText = rate.map { String(format: "%.2f Hz", $0) } ?? "Rate being measured"
                return "Measurement path: simulation \(service) · \(points) points · \(rateText)"
            case .failed(let service, let message): return "Measurement path simulation failed: \(service) · \(message)"
            }
        }
    }

}

private struct ScannerDevelopmentLiveStatus: View {
    @ObservedObject var model: SetupConsoleModel
    let coordinator: InputOwner
    @State private var connectionActive = false
    var body: some View {
        GroupBox("Current Connection Status") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill((model.isOpen || connectionActive) ? Color.green : Color.secondary)
                        .frame(width: 9, height: 9)
                    if connectionActive { ScannerMeasurementSummary(coordinator: coordinator) }
                    else { Text(model.liveConnectionSummary) }
                }
                if let requested = model.lastRequestedOperatingMode {
                    Text("Last requested: \(requested)").font(.caption).foregroundColor(.secondary)
                }
                if let profile = model.lastProfile {
                    Text("\(model.validProfileCount) valid profiles · last \(profile.measurements.count) points")
                        .font(.caption.monospacedDigit())
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }.onReceive(coordinator.measurementSessionStatusChanges.map(scannerConnectionActive).removeDuplicates()) {
            if connectionActive != $0 { connectionActive = $0 }
        }
    }
}
private struct ScannerDevelopmentLog: View {
    let model: SetupConsoleModel
    var body: some View {
        GroupBox("Live Log") {
            VStack(alignment: .leading, spacing: 6) {
                ScannerDevelopmentLogEntries(model: model)
                HStack {
                    Button("Clear") { model.clearTranscript() }
                    Button("Save …") { saveTranscript() }
                }
            }.padding(6)
        }
    }

    private func saveTranscript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sick-pls-setup-protokoll.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.exportText.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct ScannerDevelopmentLogEntries: View {
    @ObservedObject var model: SetupConsoleModel
    var body: some View {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.transcript.suffix(250)) { entry in
                            Text(entry.line).font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 150, maxHeight: 220)
    }
}

/// Values used by the editable controls; raw profiles, rate and transcript are
/// deliberately observed only by the two live subviews above.
private struct SetupControlsSnapshot: Equatable {
    let ports: [String]
    let port: String
    let hostBaud: SerialPortBaudRate
    let targetBaud: SerialPortBaudRate
    let mode: SetupMeasurementMode
    let start: String
    let stop: String
    let address: String
    let password: String
    let open: Bool
    let busy: Bool
    let status: String
    init(_ model: SetupConsoleModel) {
        ports = model.ports; port = model.selectedPort; hostBaud = model.selectedBaudRate
        targetBaud = model.baudSwitchTarget; mode = model.selectedMeasurementMode
        start = model.subrangeStartText; stop = model.subrangeStopText
        address = model.targetAddressText; password = model.password
        open = model.isOpen; busy = model.isBusy; status = model.status
    }
}
