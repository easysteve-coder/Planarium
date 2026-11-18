import AppKit
import SwiftUI
import SickPLSActiveControl
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport
import SickPLSSetupControl

@main
enum SetupEntry {
    static func main() {
        let args = CommandLine.arguments
        if let probeIndex = args.firstIndex(of: "--probe-baud-nologin"),
           probeIndex + 1 < args.count,
           let portIndex = args.firstIndex(of: "--port"),
           portIndex + 1 < args.count {
            var addressByte: UInt8 = 0x00
            if let aIndex = args.firstIndex(of: "--address"), aIndex + 1 < args.count,
               let parsed = UInt8(args[aIndex + 1], radix: 16) {
                addressByte = parsed
            }
            HeadlessBaudTransition.probeWithoutLogin(
                portPath: args[portIndex + 1],
                targetToken: args[probeIndex + 1],
                addressByte: addressByte
            )
            return
        }
        if let modeIndex = args.firstIndex(of: "--send-mode"),
           modeIndex + 1 < args.count,
           let portIndex = args.firstIndex(of: "--port"),
           portIndex + 1 < args.count,
           let modeByte = UInt8(args[modeIndex + 1], radix: 16) {
            var addressByte: UInt8 = 0x00
            if let aIndex = args.firstIndex(of: "--address"), aIndex + 1 < args.count,
               let parsed = UInt8(args[aIndex + 1], radix: 16) {
                addressByte = parsed
            }
            HeadlessBaudTransition.sendMode(
                portPath: args[portIndex + 1], modeByte: modeByte, addressByte: addressByte
            )
            return
        }
        if let flagIndex = args.firstIndex(of: "--headless-baud"),
           flagIndex + 1 < args.count,
           let portIndex = args.firstIndex(of: "--port"),
           portIndex + 1 < args.count {
            var addressByte: UInt8 = 0x01
            if let aIndex = args.firstIndex(of: "--address"), aIndex + 1 < args.count,
               let parsed = UInt8(args[aIndex + 1], radix: 16) {
                addressByte = parsed
            }
            HeadlessBaudTransition.run(
                portPath: args[portIndex + 1],
                targetToken: args[flagIndex + 1],
                addressByte: addressByte
            )
            return
        }
        SickPLSSetupApp.main()
    }
}

struct SickPLSSetupApp: App {
    @StateObject private var model = SetupConsoleModel()

    var body: some Scene {
        WindowGroup("SICK PLS Setup") {
            SetupConsoleView(model: model)
                .frame(minWidth: 900, minHeight: 680)
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

private struct SetupConsoleView: View {
    @ObservedObject var model: SetupConsoleModel
    @State private var showsRawReceiveTraffic = false

    var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 350, idealWidth: 390, maxWidth: 440)
                .padding(16)
            transcript
                .frame(minWidth: 480)
                .padding(16)
        }
        .onAppear {
            model.refreshPorts()
            DispatchQueue.main.async {
                SetupMeasurementWindow.shared.show(model: model)
            }
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect scanner and set operating mode").font(.headline)
                Text("Each command is triggered separately. Default target address is 00 (this device’s operating address).")
                    .font(.caption).foregroundColor(.secondary)
                Button("Open scan data window") {
                    SetupMeasurementWindow.shared.show(model: model)
                }

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Port", selection: $model.selectedPort) {
                            Text("– select –").tag("")
                            ForEach(model.ports, id: \.self) { Text($0).tag($0) }
                        }
                        .disabled(model.isOpen || model.isBusy)
                        Picker("Baud rate", selection: $model.selectedBaudRate) {
                            Text("9600").tag(SerialPortBaudRate.baud9600)
                            Text("38400").tag(SerialPortBaudRate.baud38400)
                            Text("500000").tag(SerialPortBaudRate.baud500000)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isOpen || model.isBusy)
                        TextField("Target address (Hex)", text: $model.targetAddressText)
                            .font(.system(.body, design: .monospaced))
                            .help("Host→Scanner, default 00. 81 is the scanner→host reply address.")
                        HStack {
                            Button("Refresh ports") { model.refreshPorts() }
                            Button("Open port") { model.openSelectedPort() }
                                .disabled(model.selectedPort.isEmpty || model.isOpen || model.isBusy)
                            Button("Close") { model.closePort() }
                                .disabled(!model.isOpen || model.isBusy)
                        }
                    }.padding(6)
                }

                Text(model.status).font(.caption).textSelection(.enabled)

                GroupBox("Current connection state") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Circle()
                                .fill(model.isOpen ? Color.green : Color.secondary)
                                .frame(width: 9, height: 9)
                            Text(model.liveConnectionSummary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if let requested = model.lastRequestedOperatingMode {
                            Text("Last requested: \(requested)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text("A request is verified only by valid reply or B0 frames.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Two verified starting states – each step separately") {
                    VStack(alignment: .leading, spacing: 12) {
                        SecureField("Scanner password (8 bytes)", text: $model.password)

                        Text("R26 – idle scanner after restart").font(.headline)
                        VStack(alignment: .leading, spacing: 7) {
                            Button("1. Verify identity at 9600 (31 @address)") { model.sendIdentity() }
                            Button("2. Log in (20 00 @address)") { model.sendLogin() }
                            Picker("Target baud rate", selection: $model.baudSwitchTarget) {
                                Text("9600 · 20 42").tag(SerialPortBaudRate.baud9600)
                                Text("38400 · 20 40").tag(SerialPortBaudRate.baud38400)
                                Text("500000 · 20 48").tag(SerialPortBaudRate.baud500000)
                            }
                            Button("3. Set scanner to selected baud rate") { model.sendBaudSwitch() }
                            Button("4. Reopen port at selected baud rate") { model.reconnectAtSelectedBaud() }
                                .disabled(model.selectedPort.isEmpty || model.isBusy)
                            Button("5. Verify identity at target baud rate (31 @00)") { model.sendVerificationIdentity() }
                        }

                        Divider()

                        Text("C7/C10 – already running/managed state").font(.headline)
                        VStack(alignment: .leading, spacing: 7) {
                            Button("A. PLSIBS authorization / Setup mode (20 30 @00)") { model.sendSettingsMode() }
                            Text("   After confirmed 20 30 @00 continue with R26 step 2 (20 00 @address).")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(6)
                    .disabled(!model.isOpen)
                }

                GroupBox("Scan mode") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Operating mode", selection: $model.selectedMeasurementMode) {
                            ForEach(SetupMeasurementMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        if model.selectedMeasurementMode == .customSubrange {
                            HStack {
                                TextField("Start 1…361", text: $model.subrangeStartText)
                                TextField("End 1…361", text: $model.subrangeStopText)
                            }
                            .font(.system(.body, design: .monospaced))
                        }
                        if model.selectedMeasurementMode.isExperimentalSubrange {
                            Text("Experimental: 0x27 has no positive evidence on the real PLS; the last attempt fell back to 9600 baud.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        Button("Send selected scan mode") { model.sendMeasurementMode() }
                            .disabled(!model.isOpen || model.isBusy)
                    }
                    .padding(6)
                }

                GroupBox("Manual telegram") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Complete hex bytes including STX, target address, length and CRC.")
                            .font(.caption).foregroundColor(.secondary)
                        TextField("02 01 …", text: $model.manualTelegram)
                            .font(.system(.body, design: .monospaced))
                        Button("Send telegram") { model.sendManualTelegram() }
                            .disabled(!model.isOpen)
                    }.padding(6)
                }
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live transcript").font(.headline)
                Spacer()
                Toggle("Raw RX/B0", isOn: $showsRawReceiveTraffic)
                    .toggleStyle(.checkbox)
                    .help("Show the running scan stream. Export remains complete regardless.")
                Button("Clear") { model.clearTranscript() }
                Button("Save…") { saveTranscript() }
            }
            Text(showsRawReceiveTraffic
                ? "Raw RX and B0 are visible. Guided TX password bytes are masked."
                : "Raw RX and B0 are hidden only in the display; export remains complete.")
                .font(.caption).foregroundColor(.secondary)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(visibleTranscript) { entry in
                            Text(entry.line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.transcript.count) { _ in
                    if let last = visibleTranscript.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var visibleTranscript: [SetupTranscriptEntry] {
        guard !showsRawReceiveTraffic else { return model.transcript }
        return model.transcript.filter { entry in
            if entry.direction == .receive { return false }
            if entry.direction == .frame && entry.message.contains("Command B0") { return false }
            return true
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

@MainActor
private final class SetupMeasurementWindow {
    static let shared = SetupMeasurementWindow()
    private var window: NSWindow?

    func show(model: SetupConsoleModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SICK PLS – Scan data"
        window.contentViewController = NSHostingController(rootView: SetupMeasurementView(model: model))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SickPLSSetupMeasurementWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

private struct SetupMeasurementView: View {
    @ObservedObject var model: SetupConsoleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Scanner scan data").font(.headline)
                Spacer()
                Text(model.isOpen ? "Port open · \(model.selectedBaudRate.rawValue) Baud" : "Disconnected")
                    .foregroundColor(model.isOpen ? .green : .secondary)
            }

            if let profile = model.lastProfile {
                let values = profile.measurements.map { $0.value }
                HStack(spacing: 22) {
                    metric("Profile", "\(model.validProfileCount)")
                    metric("Points", "\(values.count)")
                    metric("Minimum", "\(values.min() ?? 0)")
                    metric("Maximum", "\(values.max() ?? 0)")
                    metric("Partial scan", "\(profile.partialScanIndex)")
                }
                Divider()
                Text("Raw value over point index – automatically scaled to the current profile")
                    .font(.caption)
                    .foregroundColor(.secondary)
                MeasurementPlot(values: values)
                    .frame(minHeight: 360)
                Text("Last valid B0 profile: +\(model.lastProfileElapsedMilliseconds ?? 0) ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Spacer()
                Text("No CRC-valid B0 profile received yet.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 440)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}

private struct MeasurementPlot: View {
    let values: [UInt16]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                plot(in: proxy.size)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private func plot(in size: CGSize) -> Path {
        guard !values.isEmpty else { return Path() }
        let low = Double(values.min() ?? 0)
        let high = Double(values.max() ?? 0)
        let span = max(high - low, 1)
        let inset: CGFloat = 16
        let width = max(size.width - 2 * inset, 1)
        let height = max(size.height - 2 * inset, 1)

        return Path { path in
            for (index, value) in values.enumerated() {
                let fraction = values.count == 1 ? 0.5 : CGFloat(index) / CGFloat(values.count - 1)
                let normalized = CGFloat((Double(value) - low) / span)
                let point = CGPoint(
                    x: inset + fraction * width,
                    y: inset + (1 - normalized) * height
                )
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
    }
}


/// Headless-Baudumschaltung ohne GUI. Startet die App mit
/// `--headless-baud <9600|38400|500000> --port <pfad>` und ruft die
/// öffentliche `HeadlessBaudSetup`-Hülle auf (Adresse 01, Standardkennwort).
enum HeadlessBaudTransition {
    static func run(portPath: String, targetToken: String, addressByte: UInt8 = 0x01) {
        let target: SerialPortBaudRate
        switch targetToken {
        case "9600": target = .baud9600
        case "38400": target = .baud38400
        case "500000": target = .baud500000
        default:
            FileHandle.standardError.write(Data("Unknown target baud rate: \(targetToken)\n".utf8))
            exit(2)
        }
        print("HEADLESS: target \(target.rawValue) baud at address \(String(format: "%02X", addressByte)), start 9600, password=standard.")
        do {
            let result = try HeadlessBaudSetup.transition(portPath: portPath, targetBaud: target, addressByte: addressByte)
            result.evidence.forEach { print("  \($0)") }
            print("RESULT: Scanner at \(result.baud.rawValue) baud, MMK verified.")
            exit(0)
        } catch {
            print("Switch failed: \(error)")
            if let recovered = HeadlessBaudSetup.detectedBaud(portPath: portPath, addressByte: addressByte) {
                print("Device is now at: \(recovered.rawValue) Baud.")
            }
            exit(1)
        }
    }

    static func probeWithoutLogin(portPath: String, targetToken: String, addressByte: UInt8) {
        let target: SerialPortBaudRate
        switch targetToken {
        case "9600": target = .baud9600
        case "38400": target = .baud38400
        case "500000": target = .baud500000
        default:
            FileHandle.standardError.write(Data("Unknown target baud rate: \(targetToken)\n".utf8))
            exit(2)
        }
        print("PROBE: baud switch to \(target.rawValue) WITHOUT login, address \(String(format: "%02X", addressByte)).")
        do {
            let r = try HeadlessBaudSetup.probeBaudWithoutLogin(
                portPath: portPath, targetBaud: target, addressByte: addressByte
            )
            r.evidence.forEach { print("  \($0)") }
            if r.accepted {
                print("REPLY: ACK -- baud switch WITHOUT login accepted" +
                      (r.verifiedRate != nil ? " and effective (\(r.verifiedRate!.rawValue))." : " (effectiveness not confirmed)."))
            } else if r.negative {
                print("REPLY: NACK -- baud switch WITHOUT login rejected (login required).")
            } else {
                print("REPLY: no usable reply.")
            }
            exit(0)
        } catch {
            print("Probe failed: \(error)")
            exit(1)
        }
    }

    static func sendMode(portPath: String, modeByte: UInt8, addressByte: UInt8) {
        print("SEND-MODE: 20 \(String(format: "%02X", modeByte)) without login at address \(String(format: "%02X", addressByte)).")
        do {
            let r = try HeadlessBaudSetup.sendMode(portPath: portPath, modeByte: modeByte, addressByte: addressByte)
            r.evidence.forEach { print("  \($0)") }
            let ack = r.accepted ? "ACK" : (r.negative ? "NACK" : "no reply")
            print("REPLY: \(ack); B0 stream follows: \(r.profileFollowed ? "yes" : "no").")
            exit(0)
        } catch {
            print("ERROR: \(error)")
            exit(1)
        }
    }
}
