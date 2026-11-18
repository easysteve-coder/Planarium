import SickPLSCommissioning
import SickPLSMacTransport
import PlanariumInput

/// Die **Offline-Evidenzkarte** eines Verbindungsversuchs samt der
/// laufenden RX-Sitzung (SICK-0330b) -- damit SICK-034 nichts
/// Unsichtbares messen muss.
///
/// Alles hier ist bereits redigiert: das eigene Laufaudit, das
/// typisiert eingebettete Commissioning-Audit, die beobachtete
/// Fortschrittsfolge und die aggregierten RX-Zahlen. **Keine Rohframes,
/// keine Bytes, kein Passwort, kein Fremdtext** -- die Typen, aus denen
/// die Karte entsteht, tragen so etwas strukturell nicht.
public struct ConnectionEvidence: Equatable, Sendable {
    public let portPath: String
    /// Die Fortschrittsfolge des Laufs -- echte Übergänge in Reihenfolge.
    public let phases: [StandardConnectionPhase]
    /// Der abschließende Bericht des Laufs.
    public let finalReport: StandardConnectionReport?
    /// Die RX-Zahlen zum Zeitpunkt des Exports.
    public let stream: MeasurementStreamEvidence
    /// Die fertige Kennzahlenzeile der Referenzmessung zum Zeitpunkt des
    /// Exports.
    public let referenceMeasurementLine: String

    public init(
        portPath: String,
        phases: [StandardConnectionPhase],
        finalReport: StandardConnectionReport?,
        stream: MeasurementStreamEvidence,
        referenceMeasurementLine: String
    ) {
        self.portPath = portPath
        self.phases = phases
        self.finalReport = finalReport
        self.stream = stream
        self.referenceMeasurementLine = referenceMeasurementLine
    }
}

/// Der redigierte Textexport der Evidenzkarte -- **deterministisch**,
/// zeilenweise, ohne Zeitstempel der Wanduhr (nur monotone Millisekunden
/// relativ zum ersten Eintrag). Jeder `switch` ohne `default`.
public enum ConnectionEvidenceExport {

    public static func text(_ evidence: ConnectionEvidence) -> String {
        var lines: [String] = []
        lines.append("SICK PLS Laser-Theremin – Connection evidence")
        lines.append("Connection: \(evidence.portPath)")
        lines.append("")
        lines.append("Standard run progress:")
        if evidence.phases.isEmpty {
            lines.append("  (no run)")
        }
        for phase in evidence.phases {
            lines.append("  - \(describe(phase))")
        }
        if let report = evidence.finalReport {
            lines.append("Result: \(describe(report.phase)); Port held: \(yesNo(report.isPortHeld)); final: \(yesNo(report.isFinal))")
            lines.append("")
            lines.append("Run audit:")
            let origin = report.audit.entries.first?.monotonicMillis ?? 0
            for entry in report.audit.entries {
                lines.append("  +\(entry.monotonicMillis - origin) ms  \(describe(entry.action)) → \(describe(entry.outcome))")
            }
            if let commissioning = report.audit.commissioning {
                lines.append("Commissioning audit:")
                let commissioningOrigin = commissioning.entries.first?.monotonicMillis ?? origin
                for entry in commissioning.entries {
                    var line = "  +\(entry.monotonicMillis - commissioningOrigin) ms  \(describe(entry.action)) (attempt \(entry.attemptNumber)) → \(describe(entry.outcome))"
                    if let immediate = entry.immediateResponse {
                        line += ", immediate response: \(describe(immediate))"
                    }
                    lines.append(line)
                }
            }
        }
        lines.append("")
        lines.append("Measurement session:")
        lines.append("  Status: \(describe(evidence.stream.status))")
        if let rate = evidence.stream.profileRateHz { lines.append("  Profile rate: \(ConnectionBarPresentation.format(rateHz: rate))") }
        lines.append("  Delivered read operations: \(evidence.stream.deliveredProfileBatches)")
        lines.append("  reads with several profiles: \(evidence.stream.readsWithSeveralProfiles)")
        lines.append("  Valid frames: \(evidence.stream.validFrames)")
        lines.append("  Discarded candidates: \(evidence.stream.discardedCandidates)")
        lines.append("  of which oversize: \(evidence.stream.discardedCandidatesOversize)")
        lines.append("  of which CRC errors: \(evidence.stream.discardedCandidatesChecksumMismatch)")
        lines.append("  of which at finish: \(evidence.stream.discardedCandidatesAtFinish)")
        lines.append("  Skipped noise bytes: \(evidence.stream.skippedNoiseBytes)")
        lines.append("")
        lines.append("Reference measurement:")
        for line in evidence.referenceMeasurementLine.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("  \(line)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    static func describe(_ phase: StandardConnectionPhase) -> String {
        switch phase {
        case .idle: return "Start"
        case .observingPassively: return "Passive observation"
        case .checkingIdentityAtTargetRate: return "Identity check at target rate"
        case .runningCommissioning(let stage, let origin):
            return "Commissioning (\(describe(stage)), \(describe(origin)))"
        case .ready(let path): return "Ready (\(describe(path)))"
        case .failed(let failure): return "Failed (\(failure.operatorSummary))"
        }
    }

    static func describe(_ stage: StandardConnectionCommissioningStage) -> String {
        switch stage {
        case .adoptingConfirmedIdentity: return "Identity adopted"
        case .checkingStartingRate: return "Starting rate check"
        case .respondingAtStartingRate: return "Scanner responds at starting rate"
        case .loggingInAndSwitchingBaudRate: return "Login and baud switch"
        case .verifiedAtTargetRate: return "Target rate verified"
        case .awaitingMeasurementStream: return "Awaiting measurement stream"
        case .runningRateDiagnostics: return "Rate diagnostics"
        case .rateDiagnosticsFinished: return "Rate diagnostics finished"
        case .sessionFinished: return "Session finished"
        }
    }

    static func describe(_ origin: StandardConnectionCommissioningOrigin) -> String {
        switch origin {
        case .activeContinuationFromConfirmedIdentity: return "Active continuation"
        case .fallbackFromStartingRate: return "Fallback via starting rate"
        }
    }

    static func describe(_ path: StandardConnectionSuccessPath) -> String {
        switch path {
        case .passiveScanProfile: return "Existing measurement stream adopted"
        case .scanProfileDuringIdentityProbe: return "Measurement stream during identity check"
        case .activeContinuationMeasurementStream: return "Measurement stream after active continuation"
        case .commissioningFallbackMeasurementStream: return "Measurement stream after full commissioning"
        }
    }

    static func describe(_ action: StandardConnectionAuditAction) -> String {
        switch action {
        case .openPort(let rate): return "Open port (\(rate.rawValue) baud)"
        case .observeForScanProfile(let rate): return "Awaiting measurement stream (\(rate.rawValue) baud)"
        case .identityProbeAtTargetRate(let rate): return "Identity probe (\(rate.rawValue) baud)"
        case .closePort: return "Close port"
        }
    }

    static func describe(_ outcome: StandardConnectionAuditOutcome) -> String {
        switch outcome {
        case .opened: return "Opened"
        case .scanProfileObserved: return "Measurement stream observed"
        case .timedOut: return "Timed out"
        case .identityGap(let gap): return describe(gap)
        case .identified: return "Identity verified"
        case .closed: return "Closed"
        case .aborted: return "Aborted"
        case .readFailed: return "Read failed"
        case .writeFailed: return "Write failed"
        case .openFailed: return "Open failed"
        case .closeFailed: return "Close failed"
        }
    }

    static func describe(_ gap: ConnectionPolicyIdentityGap) -> String {
        switch gap {
        case .timeout: return "No identity response"
        case .unexpectedResponse: return "Unexpected response"
        case .ambiguous: return "Unreadable response"
        }
    }

    static func describe(_ action: CommissioningAction) -> String {
        switch action {
        case .identityCheck(let rate): return "Query at \(rate.rawValue) baud"
        case .settingsMode: return "Settings mode"
        case .login: return "Login"
        case .baudSwitchRequest: return "Baud switch"
        case .verification(let rate): return "Verification at \(rate.rawValue) baud"
        case .measurementModeRequest: return "Request measurements"
        case .fullScanMeasurementModeRequest: return "Request full scan (361 points)"
        case .diagnosticProbe(let rate): return "Probe at \(rate.rawValue) baud"
        }
    }

    static func describe(_ outcome: CommissioningAuditOutcome) -> String {
        switch outcome {
        case .sent: return "Sent"
        case .acknowledged: return "Acknowledged"
        case .rejected: return "Rejected"
        case .timedOut: return "No response"
        case .ambiguous: return "Response unreadable"
        case .observedScanProfileStream: return "Measurements observed"
        case .writeFailed: return "Write failed"
        }
    }

    static func describe(_ response: CommissioningImmediateResponse) -> String {
        switch response {
        case .acknowledged: return "Acknowledged"
        case .rejected: return "Rejected"
        case .unreadable: return "Unreadable"
        }
    }

    static func describe(_ status: MeasurementSessionStatus) -> String {
        switch status {
        case .idle: return "No session"
        case .opening(let portPath): return "Opening (\(portPath))"
        case .openWithoutProfile(let portPath): return "Open without profile (\(portPath))"
        case .streaming(let portPath, let pointCount):
            return "Measurement stream (\(portPath)), \(pointCount) points"
        case .failed(let portPath, let message): return "Finished (\(portPath)): \(message)"
        case .simulation(let simulation):
            switch simulation {
            case .opening(let service): return "Input: iPhone simulation \(service) — no scanner data (opening)"
            case .openWithoutProfile(let service): return "Input: iPhone simulation \(service) — no scanner data (open without profile)"
            case .streaming(let service, let count):
                return "Input: iPhone simulation \(service) — no scanner data, \(count) points"
            case .failed(let service, let message): return "Input: iPhone simulation \(service) — no scanner data (\(message))"
            }
        }
    }
}
