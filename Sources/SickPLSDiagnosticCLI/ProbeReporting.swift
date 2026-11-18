import SickPLSActiveControl
import SickPLSMacTransport

// Formatierung für die aktive Identitätsprobe (SICK-011-Auftrag). Wie
// `CLIReporting.swift`: reine Funktionen, kein `print`, keine
// Verbindung, kein Senden -- und trägt an keiner Stelle rohe
// Payload-Bytes (die gibt es hier ohnehin nicht: ``IdentityProbeOutcome``
// kann sie strukturell nicht enthalten, siehe dort).

/// Vorschau vor jedem Sendeversuch -- SICK-011-Auftrag: „zeigt vor Senden
/// Ziel, Raten, Wirkung". Wird **immer** ausgegeben, bevor
/// `BaudProbe.run` aufgerufen wird, nie erst danach.
func describeProbePreview(portPath: String, targetAddress: ConfirmedTargetAddress, candidates: [SerialPortBaudRate]) -> String {
    let rates = candidates.map { String($0.rawValue) }.joined(separator: ", ")
    return """
    Active identity probe (opt-in, SICK-011):
      Target: \(portPath), Target address \(targetAddress.rawValue)\(targetAddress == .universal ? " (universal address, Default)" : "")
      Candidate rates: \(rates) baud, exactly one probe frame (0x31) per rate, no automatic retry
      Effect: sends only the documented stateless identity/status telegram (0x31 -> 0xB1)
      No login, baud switch or scan mode switch -- none of these actions is implemented here
    """
}

func describe(_ attempt: IdentityProbeAttempt) -> String {
    "  \(attempt.baudRate.rawValue) Baud, Target address \(attempt.targetAddress): \(describe(attempt.outcome))"
}

func describe(_ outcome: IdentityProbeOutcome) -> String {
    switch outcome {
    case .identified:
        return "identified (CRC-valid 0xB1 reply)"
    case .timeout:
        return "no reply (timeout)"
    case .unexpectedResponse(let commandByte):
        return "unexpected reply (command byte \(hexByte(commandByte)), not 0xB1)"
    case .ambiguous:
        return "ambiguous (bytes received, but no CRC-valid 0xB1 frame before timeout)"
    }
}

func describe(_ auditLog: IdentityProbeAuditLog) -> String {
    if let identified = auditLog.identifiedBaudRate {
        return "Result: identified at \(identified.rawValue) Baud."
    }
    return "Result: not identified at any candidate rate."
}
