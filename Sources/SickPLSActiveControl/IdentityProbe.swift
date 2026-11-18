import SickPLSCore

/// Der explizite, zustandsfreie Identitäts-/Statusprobe-Pfad
/// `0x31 → 0xB1` (`SICK Doku/wire-protocol.md` Abschnitt 6: 🟢 seit
/// Runde 18 in jeder Runde reproduziert — die am besten belegte
/// Host→Scanner-Interaktion des gesamten Projekts). **Zustandsfrei**:
/// kein Login, kein Passwort, keine Sitzungsverwaltung — ein einzelnes
/// Anfrage-/Antwort-Paar ohne Vorbedingung.
///
/// SICK-011-Auftrag: „NUR den expliziten, zustandsfreien 0x31→0xB1-
/// Identitätsprobe-Pfad" — bewusst **kein** Login (`0x20`/Modus `0x30`
/// bzw. `0x00`), **kein** Baudratenwechsel (`0x20`/Baudcode), **kein**
/// Messmodus-Wechsel (`0x20`/Modus `0x20`/`0x21`). Diese Datei kennt
/// ausschließlich die beiden Bytes `0x31`/`0xB1`.
public enum IdentityProbe {
    /// Anfragecode. `wire-protocol.md` Abschnitt 6: Payload der Anfrage
    /// ist „keine (1 Byte Kommando)" — der gesamte Frame-Payload ist
    /// genau dieses eine Byte.
    public static let requestCommandByte: UInt8 = 0x31
    /// Erwarteter Antwortcode (`Antwortcode = Anfragecode + 0x80`,
    /// dieselbe, in jeder Zeile der Kommandoübersicht real bestätigte
    /// Konvention).
    public static let expectedResponseCommandByte: UInt8 = 0xB1

    /// Baut den Anfrage-Frame für `address` — reiner Werttyp, sendet
    /// nichts selbst und öffnet keine Verbindung.
    public static func requestFrame(address: ConfirmedTargetAddress) -> Frame {
        // 1-Byte-Payload liegt immer weit unter `payloadMaxLength` --
        // `Frame.build` kann hier strukturell nicht fehlschlagen.
        try! Frame.build(address: address.rawValue, payload: [requestCommandByte])
    }

    /// `true` genau dann, wenn `frame` eine gültige Antwort auf die
    /// Identitätsprobe ist -- Payload beginnt mit dem erwarteten
    /// Antwortcode `0xB1`. Der Rest des Payloads (laut `wire-protocol.md`
    /// ein Firmware-/Herstellcode-String) wird bewusst **nicht**
    /// ausgewertet oder zurückgegeben -- siehe ``IdentityProbeOutcome``
    /// und den SICK-011-Auftrag „Auditdaten ohne Rohpayload".
    public static func isExpectedResponse(_ frame: Frame) -> Bool {
        frame.payload.first == expectedResponseCommandByte
    }
}

/// Vier getrennte Ergebnisse für einen einzelnen Identitätsprobe-Versuch
/// -- **nie** zusammengefasst (`SICK Doku/active-control-roadmap.md`
/// Abschnitt 3.2, analog `pls_control.TransactionStatus`). Insbesondere:
/// eine Antwort ohne das erwartete `0xB1`-Kommandobyte ist
/// ``unexpectedResponse(commandByte:)``, **niemals** ein
/// stillschweigendes ``identified``.
///
/// Trägt an keiner Stelle rohe Payload-Bytes oder den im `0xB1`-Payload
/// enthaltenen Firmware-/Herstellcode-String -- nur das eine
/// Kommandobyte, wo es zur Unterscheidung nötig ist (SICK-011-Auftrag:
/// „Auditdaten ohne Rohpayload/Secrets").
public enum IdentityProbeOutcome: Equatable, Sendable {
    /// Ein CRC-valider Frame mit dem erwarteten Antwortcode `0xB1` traf
    /// vollständig ein.
    case identified
    /// Innerhalb des Timeouts trafen keine (oder keine vollständigen)
    /// Bytes ein. Kein Fehler -- nur „keine Antwort in dieser Zeit".
    case timeout
    /// Ein CRC-valider Frame traf ein, aber mit einem anderen
    /// Kommandobyte als `0xB1` im Payload (ausgenommen `0xB0` --
    /// autonomer Scanprofil-Broadcast, siehe ``BaudProbe`` und
    /// `wire-protocol.md` Abschnitt 6, letzte Zeile -- der wird als
    /// bekanntes Umgebungsrauschen übersprungen, nicht hier gemeldet).
    case unexpectedResponse(commandByte: UInt8)
    /// Bytes trafen ein, ließen sich aber bis zum Timeout nicht als
    /// CRC-valider Frame decodieren (Rauschen, Bitfehler, falsche
    /// Baudrate). Getrennt von ``timeout``, weil tatsächlich etwas
    /// ankam -- aber ausdrücklich **kein** Erfolg.
    case ambiguous
}
