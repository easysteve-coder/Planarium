import SickPLSCore
import SickPLSMacTransport

/// Ein einzelner Identitätsprobe-Versuch bei einer bestimmten Baudrate --
/// zugleich der Audit-Datensatz. Trägt **nie** rohe Payload-Bytes oder
/// Secrets (SICK-011-Auftrag) -- ``IdentityProbeOutcome`` selbst kann das
/// strukturell nicht, siehe dort.
public struct IdentityProbeAttempt: Equatable, Sendable {
    public let baudRate: SerialPortBaudRate
    public let targetAddress: UInt8
    public let outcome: IdentityProbeOutcome

    public init(baudRate: SerialPortBaudRate, targetAddress: UInt8, outcome: IdentityProbeOutcome) {
        self.baudRate = baudRate
        self.targetAddress = targetAddress
        self.outcome = outcome
    }
}

/// Vollständiges, chronologisches Audit-Protokoll eines ``BaudProbe/run``-
/// Laufs -- entspricht der in `SICK Doku/active-control-roadmap.md`
/// Abschnitt 3.4 verlangten „Audit-Protokoll jeder gesendeten Aktion"
/// (Zeitstempel sind hier bewusst weggelassen: dieser Typ ist ein reiner,
/// synchron zurückgegebener Wert, kein Log-Sink -- ein Aufrufer, der
/// Zeitstempel braucht, versieht jeden ``IdentityProbeAttempt`` beim
/// Empfang selbst damit).
public struct IdentityProbeAuditLog: Equatable, Sendable {
    public let attempts: [IdentityProbeAttempt]

    public init(attempts: [IdentityProbeAttempt]) {
        self.attempts = attempts
    }

    /// Die Baudrate, bei der die Identitätsprobe erfolgreich war -- `nil`,
    /// wenn keiner der Kandidaten geantwortet hat.
    public var identifiedBaudRate: SerialPortBaudRate? {
        attempts.first { $0.outcome == .identified }?.baudRate
    }
}

/// Begrenzte, lokale Baudraten-Erkennung über die Identitätsprobe
/// (SICK-011-Auftrag). **Kein** Auto-Baud im Sinne von „beliebige Raten
/// ausprobieren" -- genau die zwei dokumentierten Kandidaten
/// (``candidates``), je Rate genau **ein** Probe-Frame (keine
/// automatischen Wiederholungen, `active-control-roadmap.md` Abschnitt
/// 3.3), klarer Timeout pro Leseversuch. Bricht beim ersten
/// ``IdentityProbeOutcome/identified`` sofort ab -- keine überflüssigen
/// weiteren Sendeversuche, sobald eine Rate bereits geantwortet hat.
public enum BaudProbe {
    /// Feste, dokumentierte Kandidatenliste -- keine beliebige Werteliste
    /// (SICK-011-Auftrag: „Kandidaten 9600,38400"). Reihenfolge: der
    /// Owner-gemeldete aktuelle Wert zuerst (SICK-010-Scope-Änderung,
    /// 2026-09-21), der historische Wert als zweiter Versuch.
    public static let candidates: [SerialPortBaudRate] = [.baud9600, .baud38400]

    /// Führt die Identitätsprobe über `candidates` aus.
    ///
    /// - Prüft `portPath` gegen `/dev/cu.*` (wie
    ///   `SickPLSSerialConnection.open`, SICK-010 Finding N6) --
    ///   **bevor** der Opener je aufgerufen wird.
    /// - Öffnet für jeden Kandidaten frisch (eigene Baudrate,
    ///   `termios`-Konfiguration ist pro Öffnungsvorgang fest) und
    ///   schließt danach wieder -- unabhängig vom Ergebnis.
    /// - Ein `write`-Fehler bricht den gesamten Lauf ab (wirft), statt
    ///   ihn stillschweigend als „keine Antwort" für diesen Kandidaten zu
    ///   werten -- ein Schreibfehler ist ein strukturelles Problem
    ///   (Gerät getrennt, Deskriptor ungültig), kein Protokollergebnis.
    public static func run(
        portPath: String,
        targetAddress: ConfirmedTargetAddress,
        candidates: [SerialPortBaudRate] = BaudProbe.candidates,
        timeoutMilliseconds: Int32 = 500,
        opener: ActiveControlSerialPortOpener,
        clock: MonotonicClock = DarwinMonotonicClock()
    ) throws -> IdentityProbeAuditLog {
        guard portPath.hasPrefix("/dev/cu.") else {
            throw SerialPortOpenError.pathNotAllowed(portPath)
        }

        var attempts: [IdentityProbeAttempt] = []
        for baudRate in candidates {
            let outcome = try probeOnce(
                portPath: portPath,
                baudRate: baudRate,
                targetAddress: targetAddress,
                timeoutMilliseconds: timeoutMilliseconds,
                opener: opener,
                clock: clock
            )
            attempts.append(IdentityProbeAttempt(baudRate: baudRate, targetAddress: targetAddress.rawValue, outcome: outcome))
            if outcome == .identified {
                break
            }
        }
        return IdentityProbeAuditLog(attempts: attempts)
    }

    /// Führt genau einen Probe-Versuch aus. `timeoutMilliseconds` ist eine
    /// **harte, monotone Gesamtfrist ab dem Sendezeitpunkt** -- kein
    /// Timeout, der bei jedem neu eingetroffenen Byte (echtes Rauschen wie
    /// autonome `0xB0`-Broadcasts eingeschlossen) von Neuem beginnt
    /// (SICK-011a, Korrektur eines sonst unbegrenzten Wartens bei
    /// fortlaufendem Umgebungsrauschen). Eine innerhalb dieser Frist
    /// fragmentiert eintreffende, CRC-valide `0xB1`-Antwort bleibt
    /// trotzdem `.identified` -- die Frist begrenzt nur die Gesamtwartezeit,
    /// nicht die Fähigkeit, einen über mehrere Leseaufrufe verteilten
    /// Frame zusammenzusetzen.
    private static func probeOnce(
        portPath: String,
        baudRate: SerialPortBaudRate,
        targetAddress: ConfirmedTargetAddress,
        timeoutMilliseconds: Int32,
        opener: ActiveControlSerialPortOpener,
        clock: MonotonicClock
    ) throws -> IdentityProbeOutcome {
        let port = try opener.open(atPath: portPath, baudRate: baudRate)
        defer { port.close() }

        // Genau ein Probe-Frame -- kein automatischer Wiederholversuch
        // (`active-control-roadmap.md` Abschnitt 3.3).
        try port.write(IdentityProbe.requestFrame(address: targetAddress).encoded())

        // Deadline ab dem Sendezeitpunkt, nicht ab dem jeweils letzten
        // Leseaufruf -- siehe Kopfkommentar dieser Funktion.
        let deadlineMilliseconds = clock.nowMilliseconds() + Int64(timeoutMilliseconds)

        var parser = StreamParser()
        var receivedAnyBytes = false

        while true {
            let remainingMilliseconds = deadlineMilliseconds - clock.nowMilliseconds()
            guard remainingMilliseconds > 0 else {
                return receivedAnyBytes ? .ambiguous : .timeout
            }
            let boundedReadTimeout = Int32(min(remainingMilliseconds, Int64(Int32.max)))

            switch port.read(timeoutMilliseconds: boundedReadTimeout) {
            case .bytes(let bytes):
                receivedAnyBytes = true
                for frame in parser.feed(bytes) {
                    if IdentityProbe.isExpectedResponse(frame) {
                        return .identified
                    }
                    // Der autonome Scanprofil-Broadcast (`0xB0`,
                    // `wire-protocol.md` Abschnitt 6, letzte Zeile) läuft
                    // unabhängig von dieser Probe weiter, falls der
                    // Scanner gerade aktiv scannt -- bekanntes
                    // Umgebungsrauschen, kein Antwortversuch auf unsere
                    // Anfrage, deshalb übersprungen statt als
                    // `unexpectedResponse` gemeldet. Verlängert die
                    // Gesamtfrist oben ausdrücklich nicht.
                    if frame.payload.first == B0ScanProfile.commandByte {
                        continue
                    }
                    return .unexpectedResponse(commandByte: frame.payload.first ?? 0x00)
                }
                // Noch kein vollständiger, relevanter Frame -- weiter
                // innerhalb der verbleibenden Gesamtfrist lesen.
            case .timeout:
                return receivedAnyBytes ? .ambiguous : .timeout
            case .closed:
                let frames = parser.finish()
                if frames.contains(where: IdentityProbe.isExpectedResponse) {
                    return .identified
                }
                return receivedAnyBytes ? .ambiguous : .timeout
            }
        }
    }
}
