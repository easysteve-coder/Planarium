import SickPLSCore

/// Die vollständige Klassifikation einer Bestätigungsantwort auf ein
/// Konfigurationstelegramm (SICK-030a).
///
/// **Sieben getrennte Fälle, nie zusammengefasst** — dieselbe Haltung
/// wie `IdentityProbeOutcome` (SICK-011) und
/// `ThereminGateDelivery` (SICK-023): Ein geschlossenes Enum zwingt
/// jeden Aufrufer zu einem `switch` über alle Lagen, statt „nicht
/// erfolgreich" zu einem einzigen Sammelfall zu verschmelzen, in dem
/// „Gerät hat abgelehnt" und „gar nichts gekommen" gleich aussehen.
///
/// **Die wichtigste Regel: ein fehlendes Statusbyte ist niemals ACK.**
/// Die Antwort besteht aus Kommandobyte, Statusbyte und einem dritten
/// Byte; fehlt das Statusbyte, ist die Antwort **nicht auswertbar** und
/// kein Erfolg. Genau hier entstünde sonst der gefährlichste Fehler
/// dieses Modells: ein zu kurzer oder verstümmelter Frame, der als
/// Zustimmung gilt und den Ablauf weiterlaufen lässt.
public enum AcknowledgementOutcome: Equatable, Sendable {
    /// Bestätigt: erwartetes Kommandobyte **und** das Statusbyte, das
    /// Zustimmung bedeutet.
    ///
    /// **Das dritte Antwortbyte wird bewusst nicht mitgeführt und nicht
    /// ausgewertet.** Seine Bedeutung ist offen, es wurde in
    /// verschiedenen Beobachtungen unterschiedlich gesehen — und Audit
    /// und Ergebnis dieses Modells tragen grundsätzlich keine
    /// Payload-Bytes (SICK-011-Muster, Auflage A5). Ein Byte, das
    /// niemand deuten kann, ist kein Grund, diese Regel aufzuweichen.
    case acknowledged
    /// Abgelehnt: erwartetes Kommandobyte, aber das Statusbyte, das
    /// Ablehnung bedeutet. **Ein klarer Befund, kein Fehler der
    /// Übertragung** — und ein Grund, sofort zu stoppen.
    case rejected
    /// Erwartetes Kommandobyte, aber ein Statusbyte, dessen Bedeutung
    /// nicht belegt ist. **Kein Erfolg.** Getrennt von ``rejected``,
    /// weil das Gerät hier gerade nicht „nein" gesagt hat.
    case unknownStatus(UInt8)
    /// Ein CRC-valider Frame mit dem erwarteten Kommandobyte, aber ohne
    /// Statusbyte. **Niemals ACK** — siehe Typkommentar.
    case missingStatusByte
    /// Ein CRC-valider Frame mit einem anderen Kommandobyte als dem
    /// erwarteten — und ausdrücklich **nicht** dem autonomen
    /// Scanprofil-Broadcast, der einen eigenen Fall hat.
    case unexpectedCommandByte(UInt8)
    /// Ein autonomer Scanprofil-Broadcast traf ein, während auf die
    /// Bestätigung gewartet wurde.
    ///
    /// **Kein Erfolg dieses Modells** und auch kein Fehler: bekanntes
    /// Umgebungsrauschen, das übersprungen wird (dieselbe Behandlung wie
    /// in `BaudProbe` seit SICK-011). Ein Messstrom belegt **nie** einen
    /// gelungenen Baudwechsel (Auflage **A1**) — er ist ausschließlich
    /// Erfolgskriterium des experimentellen Messmodus-Schritts.
    case observedScanProfile
    /// Innerhalb der Gesamtfrist kam keine auswertbare Antwort.
    case timeout
    /// Bytes trafen ein, ließen sich aber nicht als CRC-valider Frame
    /// decodieren. Getrennt von ``timeout``, weil tatsächlich etwas
    /// ankam — aber ausdrücklich **kein** Erfolg.
    case undecodable
}

/// Die reine Klassifikationsfunktion (SICK-030a).
///
/// Kennt keinen Port, keine Uhr und keinen Zustand: Ein Frame geht
/// hinein, ein benannter Fall kommt heraus. ``timeout`` und
/// ``undecodable`` entstehen nicht hier, sondern in der späteren
/// I/O-Schleife — sie sind Lagen **ohne** Frame.
public enum AcknowledgementClassifier {

    /// Kommandobyte der Bestätigungsantwort.
    public static let responseCommandByte: UInt8 = 0xA0
    /// Statusbyte für Zustimmung.
    public static let acknowledgedStatusByte: UInt8 = 0x00
    /// Statusbyte für Ablehnung.
    public static let rejectedStatusByte: UInt8 = 0x01
    /// Kommandobyte des autonomen Scanprofil-Broadcasts.
    public static let scanProfileCommandByte: UInt8 = 0xB0

    /// Klassifiziert **einen** bereits CRC-validen Frame.
    public static func classify(_ frame: Frame) -> AcknowledgementOutcome {
        guard let commandByte = frame.payload.first else {
            // Ein Frame ohne Payload trägt nicht einmal ein
            // Kommandobyte -- er ist keine Antwort auf irgendetwas.
            return .undecodable
        }
        if commandByte == scanProfileCommandByte {
            return .observedScanProfile
        }
        guard commandByte == responseCommandByte else {
            return .unexpectedCommandByte(commandByte)
        }
        // **Erst hier** darf ein Statusbyte überhaupt gelesen werden --
        // und sein Fehlen ist ein eigener Fall, kein Default.
        guard frame.payload.count >= 2 else {
            return .missingStatusByte
        }
        switch frame.payload[1] {
        case acknowledgedStatusByte: return .acknowledged
        case rejectedStatusByte: return .rejected
        case let other: return .unknownStatus(other)
        }
    }
}

extension AcknowledgementOutcome {
    /// Genau ein Fall bedeutet Erfolg. Als berechnete Eigenschaft, damit
    /// ein neuer Fall nicht versehentlich als Erfolg durchrutscht.
    public var isAcknowledged: Bool {
        if case .acknowledged = self { return true }
        return false
    }

    /// Ob dieser Ausgang den laufenden **Login-Versuch beendet** —
    /// oder ob innerhalb derselben Frist weitergelesen werden muss
    /// (SICK-032a3a).
    ///
    /// ## Woher die Regel stammt
    ///
    /// Aus dem **ersten realen Lauf**: Bei 9600/8E1 war die Identität
    /// `B1` bestätigt, das Login an der Konfigurationsadresse bekam aber
    /// beim ersten Versuch nur eine **unlesbare** Antwort — und der
    /// Ablauf brach ab, ohne die von
    /// `SICK Doku/integration/active-sequences.md` §2 belegte eine
    /// identische Wiederholung überhaupt zu versuchen.
    ///
    /// SICK-032a3 hat daraufhin die Wiederholung auch an die unlesbare
    /// Antwort gehängt — **und dabei zu früh ausgelöst**. Die Beleglage
    /// kennt die Wiederholung **nach dem 2-Sekunden-Fenster**, nicht
    /// nach dem ersten unverständlichen Byte. Ein nacktes `06` hätte das
    /// zweite Telegramm Millisekunden nach dem ersten hinausgehen
    /// lassen, und eine **spätere gültige `A0`-Antwort in derselben
    /// Frist** wäre gar nicht mehr für das erste Telegramm gezählt
    /// worden.
    ///
    /// ## Die Grenze, bei künftigen Änderungen zu erhalten
    ///
    /// Genau **zwei** Ausgänge beenden einen Versuch, und beide sind
    /// echte Aussagen des Geräts:
    ///
    /// - ``acknowledged`` führt **weiter**, nie in eine Wiederholung.
    /// - ``rejected`` ist ein **klarer Befund** — „nein" heißt nein, und
    ///   ein zweites, identisches Telegramm wäre genau der
    ///   Wiederholungssturm, den `maximumLoginRetryCount` verhindert.
    ///
    /// **Alles Übrige beendet nichts.** ``observedScanProfile`` ist
    /// bekanntes Rauschen, und jede nicht deutbare Antwort ist für den
    /// Ablauf dasselbe wie Stille: Sie wird gemerkt, und es wird
    /// **weitergelesen**, bis die Frist wirklich abgelaufen ist. Erst
    /// dann — und nur dann — geht die eine Wiederholung hinaus.
    ///
    /// **`switch` ohne `default`** — ein neuer Fall muss sich bewusst
    /// entscheiden, statt still einen Versuch zu beenden.
    public var concludesLoginAttempt: Bool {
        switch self {
        case .acknowledged, .rejected:
            return true
        case .observedScanProfile, .unknownStatus, .missingStatusByte,
             .unexpectedCommandByte, .timeout, .undecodable:
            return false
        }
    }
}
