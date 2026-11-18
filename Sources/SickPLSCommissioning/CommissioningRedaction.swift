import SickPLSCore

/// Inhaltsbasierte Redaktion (SICK-030a, Auflage **A5**).
///
/// ## Warum inhaltsbasiert und nicht positionsbasiert
///
/// Der naheliegende Weg wäre, „im Login-Telegramm die Bytes ab Offset N
/// zu schwärzen". Genau daran ist die Referenzimplementierung in
/// mehreren Beobachtungsrunden gescheitert: Sobald ein Telegramm an
/// anderer Stelle, in einem Sammelpuffer oder in einer Fehlermeldung
/// landete, griff die Regel nicht mehr, und das Geheimnis stand im
/// Protokoll. Eine Redaktion, die vom **Modusbyte** oder vom **Offset**
/// abhängt, schützt nur den einen Pfad, an den ihr Autor gedacht hat.
///
/// Diese Redaktion sucht deshalb **den Inhalt**: Wo immer die
/// Geheimnisbytes in einer Bytefolge stehen, werden sie ersetzt — an
/// jeder Position, auch mehrfach, auch in einem Puffer, der mit dem
/// Login-Telegramm nichts zu tun hat.
///
/// ## Die eigentliche Sicherheit liegt eine Ebene höher
///
/// ``describe(_:)`` gibt grundsätzlich **keine** Payload-Bytes aus —
/// nicht die geschwärzten und nicht die harmlosen. Die Redaktion ist das
/// Netz darunter, für jeden Pfad, der doch einmal Bytes in die Hand
/// bekommt.
public enum CommissioningRedaction {

    /// Das Ersatzbyte. Gleiche Länge wie das Original, damit eine
    /// Längenangabe nicht verrät, dass etwas entfernt wurde — und damit
    /// eine redigierte Folge weiterhin die Struktur zeigt.
    public static let replacementByte: UInt8 = 0x00

    /// `true`, wenn `bytes` die Geheimnisbytes an **irgendeiner**
    /// Position enthält.
    public static func containsSecret(_ bytes: [UInt8], secret: InstallationSecret) -> Bool {
        secret.withBytes { needle in
            firstIndex(of: needle, in: bytes) != nil
        }
    }

    /// Ersetzt **jedes** Vorkommen der Geheimnisbytes.
    ///
    /// Überlappungsfrei von links nach rechts; nach einem Treffer geht
    /// die Suche hinter ihm weiter.
    public static func redacting(_ bytes: [UInt8], secret: InstallationSecret) -> [UInt8] {
        secret.withBytes { needle in
            guard !needle.isEmpty else { return bytes }
            var result = bytes
            var searchStart = 0
            while searchStart <= result.count - needle.count,
                  let hit = firstIndex(of: needle, in: result, from: searchStart) {
                for offset in 0..<needle.count {
                    result[hit + offset] = replacementByte
                }
                searchStart = hit + needle.count
            }
            return result
        }
    }

    /// Die **einzige** Frame-Beschreibung dieses Moduls — für Audit,
    /// Anzeige und Fehlermeldungen.
    ///
    /// Sie nennt Adresse, Kommandobyte und Payload-**Länge** und
    /// ausdrücklich **keinen** weiteren Payload-Inhalt. Das
    /// Kommandobyte ist Protokollstruktur (es steht in jeder
    /// Kommandoübersicht) und ist nötig, um eine Antwort überhaupt
    /// zuordnen zu können; alles dahinter ist entweder uninteressant
    /// oder geheim, und die Unterscheidung wollen wir hier gar nicht
    /// erst treffen müssen.
    public static func describe(_ frame: Frame) -> String {
        let command = frame.payload.first.map(hex) ?? "none"
        return "Address \(hex(frame.address)), "
            + "Command \(command), \(frame.payload.count) Byte Payload"
    }

    /// Eigene Hex-Formatierung statt `String(format:)`: Dieses Ziel
    /// importiert bewusst kein Foundation (siehe
    /// `CommissioningBoundaryTests`).
    static func hex(_ byte: UInt8) -> String {
        let digits = "0123456789ABCDEF"
        let high = digits[digits.index(digits.startIndex, offsetBy: Int(byte >> 4))]
        let low = digits[digits.index(digits.startIndex, offsetBy: Int(byte & 0x0F))]
        return "0x\(high)\(low)"
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count, start >= 0 else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            var matches = true
            for offset in 0..<needle.count where haystack[index + offset] != needle[offset] {
                matches = false
                break
            }
            if matches { return index }
            index += 1
        }
        return nil
    }
}
