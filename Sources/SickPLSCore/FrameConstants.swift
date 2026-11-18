/// Zentrale Konstanten des SICK-PLS-Telegrammformats.
///
/// Quelle: `SICK Doku/wire-protocol.md` Abschnitt 2 und 4 (Frame-Aufbau,
/// CRC16), rückgeführt auf `SickPLSMessage.hh` im BSD-lizenzierten
/// SickToolbox-Referenzcode (Jason C. Derenick & Thomas H. Miller, 2008,
/// http://sicktoolbox.sourceforge.net), erhalten über
/// https://github.com/asr-ros/asr_mild_base_laserscanner/blob/master/include/SickPLSMessage.hh
/// (`SICK_PLS_MSG_HEADER_LEN`, `SICK_PLS_MSG_PAYLOAD_MAX_LEN`,
/// `SICK_PLS_MSG_TRAILER_LEN`, `CRC16_GEN_POL`), bit-identisch zur
/// offiziellen LMS2xx-Variante in https://github.com/ros-drivers/sicktoolbox
/// (`include/sicktoolbox/SickLMS2xxMessage.hh`). Vollständiger BSD-Lizenztext:
/// siehe `THIRD-PARTY-NOTICES.md` im Projektwurzelverzeichnis.
///
/// **Abweichung von `client-architecture.md` §2.1:** Die dort skizzierte
/// Dateiliste (`CRC16.swift`, `Frame.swift`, …) nennt keine eigene
/// Konstanten-Datei. Diese Extraktion ist eine bewusste, sichtbar benannte
/// Abweichung (TEAM_RULES Regel „eigene Abweichungen werden sichtbar
/// benannt", Revisor-Review SICK-003, Finding N6): Header-/Payload-/
/// Trailer-Länge und das CRC-Polynom sind Frame- *und* CRC-Vertrag
/// gemeinsam und gehören an eine Stelle statt doppelt gepflegt zu werden.
public enum SickPLSFrameConstants {
    /// Start-of-Text-Byte, markiert den Beginn eines Frame-Kandidaten.
    public static let startOfText: UInt8 = 0x02

    /// Länge des festen Headers in Byte (STX + Adresse + 2 Byte Länge).
    public static let headerLength = 4

    /// Maximale Payload-Länge in Byte (`SICK_PLS_MSG_PAYLOAD_MAX_LEN`).
    public static let payloadMaxLength = 812

    /// Länge des Trailers in Byte (2 Byte CRC16).
    public static let trailerLength = 2

    /// Maximale Gesamtlänge eines Frames in Byte (Header + maximale Payload + Trailer).
    public static let maxFrameLength = headerLength + payloadMaxLength + trailerLength

    /// Generatorpolynom des proprietären CRC16 (`CRC16_GEN_POL`). Kein
    /// benannter Standard-CRC16 (weder CCITT noch Modbus) — die
    /// Bitverarbeitung in ``SickCRC16`` gehört untrennbar dazu.
    public static let crcGeneratorPolynomial: UInt16 = 0x8005
}
