import SickPLSCommissioning

/// Redigierter Export des vollständig handbedienten Einrichtungswegs.
/// Er enthält nur benannte Aktionen, Zieladresse, monotone Relativzeit
/// und klassifizierte Ergebnisse — niemals Telegrammbytes oder Passwort.
public enum ManualCommissioningEvidenceExport {

    public static func text(
        portPath: String,
        phase: CommissioningPhase?,
        entries: [CommissioningAuditEntry]
    ) -> String {
        var lines = [
            "SICK PLS Laser-Theremin – Manual commissioning log",
            "Port: \(portPath.isEmpty ? "–" : portPath)",
            "Status: \(describe(phase))",
            "",
            "Steps:"
        ]
        guard let origin = entries.first?.monotonicMillis else {
            lines.append("  (no step sent yet)")
            return lines.joined(separator: "\n") + "\n"
        }
        for entry in entries {
            var line = "  +\(entry.monotonicMillis - origin) ms  \(describe(entry.action))"
            line += " (attempt \(entry.attemptNumber), address \(entry.targetAddress))"
            line += " → \(describe(entry.outcome))"
            if let immediate = entry.immediateResponse {
                line += ", immediate response: \(describe(immediate))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func describe(_ phase: CommissioningPhase?) -> String {
        guard let phase else { return "not started" }
        switch phase {
        case .idle: return "ready for the 9600 baud check"
        case .checkingStartingRate: return "9600 baud check in progress"
        case .respondingAtStartingRate: return "9600 baud confirmed"
        case .enteringSettingsMode: return "automatic settings sequence in progress"
        case .enteringSettingsModeManually: return "opening settings mode"
        case .settingsModeEntered: return "settings mode confirmed"
        case .loggingIn(let attempt): return "automatic login in progress (attempt \(attempt))"
        case .loggingInManually: return "login at 9600 baud in progress"
        case .loggedIn: return "login at 9600 baud confirmed"
        case .requestingBaudSwitch: return "automatic baud switch in progress"
        case .requestingBaudSwitchManually: return "baud switch to 38400 in progress"
        case .baudSwitchAcknowledged: return "baud switch confirmed; reconnection pending"
        case .closingPort: return "closing 9600 baud connection"
        case .openingTargetPort: return "opening 38400 baud connection"
        case .verifyingTargetRate: return "verifying 38400 baud connection"
        case .verified: return "38400 baud confirmed"
        case .awaitingMeasurementStream: return "MMK requested; verifying measurement stream"
        case .measurementStreamConfirmed: return "MMK measurement stream confirmed"
        case .runningDiagnostics: return "rate diagnostics in progress"
        case .diagnosticsFinished: return "rate diagnostics finished"
        case .failed(let failure): return "failed: \(failure.operatorSummary)"
        case .sessionFinished: return "finished"
        }
    }

    private static func describe(_ action: CommissioningAction) -> String {
        switch action {
        case .identityCheck(let rate): return "verify connection at \(rate.rawValue) baud"
        case .settingsMode: return "activate settings mode (20 30)"
        case .login: return "login at 9600 baud (20 00)"
        case .baudSwitchRequest: return "set 38400 baud (20 40)"
        case .verification(let rate): return "verify connection at \(rate.rawValue) baud"
        case .measurementModeRequest: return "start MMK mode (20 20)"
        case .fullScanMeasurementModeRequest: return "start full scan mode (20 24)"
        case .diagnosticProbe(let rate): return "diagnostics at \(rate.rawValue) baud"
        }
    }

    private static func describe(_ outcome: CommissioningAuditOutcome) -> String {
        switch outcome {
        case .sent: return "sent; response pending"
        case .acknowledged: return "confirmed"
        case .rejected: return "rejected"
        case .timedOut: return "no response"
        case .ambiguous: return "response unreadable"
        case .observedScanProfileStream: return "measurement stream observed"
        case .writeFailed: return "send failed"
        }
    }

    private static func describe(_ response: CommissioningImmediateResponse) -> String {
        switch response {
        case .acknowledged: return "confirmed"
        case .rejected: return "rejected"
        case .unreadable: return "unreadable"
        }
    }
}
