import AppKit
import SwiftUI
import SickPLSCommissioning
import SickPLSCommissioningControl
import PlanariumScannerUI
import PlanariumInput

/// Die sichtbare Scanner-Einrichtung (SICK-032a, Auflage E3; Bedienung
/// seit SICK-032a2 auf einen primären Ablauf zusammengezogen).
///
/// **Reine Komposition.** Ablauf, Sperren, Threadwechsel, Portbesitz und
/// jeder angezeigte Satz liegen in ``CommissioningControlModel``; hier
/// steht kein `DispatchQueue`, kein Executor, kein Transport, keine
/// Zeitquelle und kein selbst formulierter Warntext.
/// `CommissioningControlBoundaryTests` prüft das am Quelltext.
///
/// **Kein Passwortfeld mehr** (SICK-032a2): Das Scanner-Passwort ist eine
/// gewöhnliche Einstellung und steht in den App-Einstellungen. Fehlt es,
/// sagt das Modell das hier — mitten im Ablauf wird nichts abgefragt.
struct CommissioningControlView: View {

    @ObservedObject var model: CommissioningControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scanner Setup")
                .font(.headline)

            briefing
            Divider()
            portPicker
            Divider()
            primaryAction
            Divider()
            stepStage

            if let notice = model.notice {
                Text(notice.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.auditEntries.isEmpty {
                Divider()
                auditList
            }
        }
        .onAppear {
            model.refreshPorts()
            model.refreshReadiness()
        }
    }

    // MARK: - Dauerhaft sichtbare Vorabinformation (Bedienvertrag 1)

    private var briefing: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.briefing.lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Anschluss

    private var portPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Port")
                    .font(.subheadline)
                Spacer()
                Button("Refresh ports") { model.refreshPorts() }
                    .disabled(model.isRunning)
            }
            if model.availablePorts.isEmpty {
                Text("No port found. Is the scanner connected?")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.availablePorts, id: \.self) { path in
                    Button {
                        model.selectPort(path)
                    } label: {
                        HStack {
                            Image(systemName: path == model.selectedPortPath ? "largecircle.fill.circle" : "circle")
                            Text(path).font(.caption)
                        }.frame(maxWidth: .infinity,minHeight: 24,alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .auditedButtonSurface(path,font: 11,foreground: path == model.selectedPortPath ? .black : .white,background: path == model.selectedPortPath ? StageTheme.amber : HelmutChrome.control)
                    .disabled(model.isRunning)
                }
            }
            Text(readinessText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var readinessText: String {
        switch model.readiness {
        case .ready: return "Ready."
        case .monitorMustDisconnectFirst: return "The live display is still using the port."
        case .simulationMustDisconnectFirst: return "The iPhone simulation is still using the port."
        case .simulationControlMustFinishFirst: return "The simulation is switching — please wait."
        case .awaitingPortRelease: return "The port is closing — please wait."
        case .noPortSelected: return "No port selected yet."
        case .portPathNotAllowed: return "This port is not allowed."
        }
    }

    // MARK: - Der primäre Ablauf (SICK-032a2)

    /// **Ein Knopf für alles Harmlose.** Er übernimmt den Anschluss und
    /// fragt beim Scanner nach, ob er antwortet — mehr geht dabei nicht
    /// hinaus, und das Gerät wird nicht verändert.
    private var primaryAction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("1. Connect and check at 9600 baud") {
                model.prepareScanner()
            }
            .disabled(model.isRunning || model.selectedPortPath.isEmpty)

            if model.isRunning {
                Text("Running …")
                    .font(.caption)
            }
        }
    }

    // MARK: - Was danach möglich ist

    private var stepStage: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let phase = model.phase {
                Text("Status: \(Self.describe(phase))")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let verified = model.verifiedBaudRate {
                Text("Switch confirmed: The scanner now responds at \(verified.rawValue) baud.")
                    .font(.caption)
            }
            if model.observedScanProfileStream {
                Text("The scanner is sending measurements — that alone does not confirm the switch.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Manual sequence")
                .font(.subheadline)

            // Alle Gerätephasen bleiben sichtbar. Eine noch nicht
            // erreichte Phase ist deaktiviert statt verschwunden; damit
            // ist jederzeit erkennbar, wo insbesondere Schritt 4 liegt
            // und welches bestätigte Ergebnis ihn freischaltet.
            ForEach(Array(Self.manualSequence.enumerated()), id: \.offset) { _, command in
                Button(Self.title(of: command)) {
                    model.requestStep(command)
                }
                .disabled(model.isRunning || !model.allowedSteps.contains(command))
            }

            // Diagnose und Sitzungsende gehören nicht zur sechsphasigen
            // Gerätekette und erscheinen nur, wenn das Modell sie anbietet.
            ForEach(Array(model.allowedSteps.filter {
                !Self.manualSequence.contains($0) && $0 != .checkStartingRate
            }.enumerated()), id: \.offset) { _, command in
                Button(Self.title(of: command)) { model.performStep(command) }
                    .disabled(model.isRunning)
            }

            if let pending = model.pendingStep {
                confirmation(for: pending)
            }
        }
    }

    private func confirmation(for command: CommissioningCommand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Really: \(Self.title(of: command))?")
                .font(.subheadline)
            Text(Self.effect(of: command))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            if Self.needsPassword(command), model.scannerPasswordUsability != .usable {
                Text(Self.passwordHint(model.scannerPasswordUsability))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Yes, run") {
                    model.confirmPendingStep()
                }
                .disabled(model.isRunning)
                Button("Cancel") {
                    model.cancelPendingStep()
                }
            }
        }
    }

    private static func passwordHint(_ usability: ScannerPasswordUsability) -> String {
        switch usability {
        case .notSet:
            return "The scanner password is not set yet. It is in the app settings."
        case .unusable:
            return "The scanner password in the settings does not match what the device expects yet."
        case .usable:
            return ""
        }
    }

    private static func needsPassword(_ command: CommissioningCommand) -> Bool {
        switch command {
        case .enterSettingsMode, .login, .switchBaudRate: return true
        case .checkStartingRate, .setTargetBaudRate, .connectTargetRate,
             .requestMeasurementMode, .runRateDiagnostics, .finishSession, .abort:
            return false
        }
    }

    // MARK: - Protokoll

    private var auditList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What happened so far")
                .font(.subheadline)
            ForEach(Array(model.auditEntries.enumerated()), id: \.offset) { _, entry in
                Text(Self.describe(entry, origin: model.auditEntries.first?.monotonicMillis ?? 0))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Copy") { copyEvidence() }
                Button("Save …") { saveEvidence() }
            }
        }
    }

    private func copyEvidence() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.evidenceExportText(), forType: .string)
    }

    private func saveEvidence() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sick-manual-setup.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.evidenceExportText().write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Beschriftungen

    private static let manualSequence: [CommissioningCommand] = [
        .enterSettingsMode, .login, .setTargetBaudRate,
        .connectTargetRate, .requestMeasurementMode
    ]

    private static func title(of command: CommissioningCommand) -> String {
        switch command {
        case .checkStartingRate: return "Check again"
        case .enterSettingsMode: return "2. Enter settings mode"
        case .login: return "3. Log in at 9600 baud"
        case .setTargetBaudRate: return "4. Set 38400 baud"
        case .connectTargetRate: return "5. Connect at 38400 baud"
        case .switchBaudRate: return "Switch scanner to fast transmission"
        case .requestMeasurementMode: return "6. Start MMK mode"
        case .runRateDiagnostics: return "Check connection"
        case .finishSession: return "Done"
        case .abort: return "Cancel"
        }
    }

    private static func effect(of command: CommissioningCommand) -> String {
        switch command {
        case .checkStartingRate:
            return "Only checks whether the scanner responds. It is not modified."
        case .enterSettingsMode:
            return "Sends 20 30 to address 1 once. The sequence then pauses."
        case .login:
            return "Sends the login 20 00 to address 1 once. The sequence then pauses; if no response arrives, the documented attempt can be triggered again."
        case .setTargetBaudRate:
            return "Sends 20 40 to address 1 once. After confirmation, the connection stays at 9600 baud for now."
        case .connectTargetRate:
            return "Closes the 9600-baud connection, opens 38400 baud and checks the scanner identity there."
        case .switchBaudRate:
            return "Logs in to the scanner and switches it permanently. "
                + "If something goes wrong, the only fix is to power-cycle the scanner."
        case .requestMeasurementMode:
            return "Asks the scanner to send measurements permanently. "
                + "Whether it complies is not yet confirmed."
        case .runRateDiagnostics:
            return "Checks at both speeds whether the scanner responds. It is not modified."
        case .finishSession:
            return "Ends the setup and releases the port."
        case .abort:
            return "Aborts and releases the port."
        }
    }

    private static func describe(_ phase: CommissioningPhase) -> String {
        switch phase {
        case .idle: return "nothing done yet"
        case .checkingStartingRate: return "checking"
        case .enteringSettingsMode: return "Entering settings mode"
        case .enteringSettingsModeManually: return "Logging in at 9600 baud"
        case .respondingAtStartingRate: return "the scanner responds"
        case .settingsModeEntered: return "Login at 9600 baud confirmed"
        case .loggingIn(let attempt):
            // Der zweite Versuch ist die **eine** belegte Wiederholung
            // (SICK-032a3) -- sie darf sichtbar sein, damit niemand sie
            // für eine hängende Anmeldung hält.
            return attempt == 1 ? "Logging in" : "Logging in (second and final attempt)"
        case .loggingInManually: return "Opening settings mode"
        case .loggedIn: return "Settings mode confirmed"
        case .requestingBaudSwitch: return "Switch requested"
        case .requestingBaudSwitchManually: return "Setting 38400 baud"
        case .baudSwitchAcknowledged: return "38400 baud confirmed; reconnect pending"
        case .closingPort: return "Closing port"
        case .openingTargetPort: return "Reopening port"
        case .verifyingTargetRate: return "Verifying switch"
        case .verified: return "Switch confirmed"
        case .awaitingMeasurementStream: return "Measurements requested (waiting for new scan stream)"
        case .measurementStreamConfirmed: return "Scan stream confirmed"
        case .runningDiagnostics: return "Checking connection"
        case .diagnosticsFinished: return "Check complete"
        case .failed(let failure): return failure.operatorSummary
        case .sessionFinished: return "finished"
        }
    }

    private static func describe(_ entry: CommissioningAuditEntry, origin: Int64) -> String {
        "+\(entry.monotonicMillis - origin) ms  \(describe(entry.action)) "
            + "(Attempt \(entry.attemptNumber), Address \(entry.targetAddress)): \(describe(entry.outcome))"
    }

    private static func describe(_ action: CommissioningAction) -> String {
        switch action {
        case .identityCheck(let rate): return "Check at \(rate.rawValue) baud"
        case .settingsMode: return "Settings mode"
        case .login: return "Login"
        case .baudSwitchRequest: return "Baud switch"
        case .verification(let rate): return "Verification at \(rate.rawValue) baud"
        case .measurementModeRequest: return "Request measurements"
        case .fullScanMeasurementModeRequest: return "Request full scan (361 points)"
        case .diagnosticProbe(let rate): return "Check at \(rate.rawValue) baud"
        }
    }

    private static func describe(_ outcome: CommissioningAuditOutcome) -> String {
        switch outcome {
        case .sent: return "sent"
        case .acknowledged: return "acknowledged"
        case .rejected: return "rejected"
        case .timedOut: return "no response"
        case .ambiguous: return "Response unreadable"
        case .observedScanProfileStream: return "Measurements observed"
        case .writeFailed: return "Send failed"
        }
    }
}
