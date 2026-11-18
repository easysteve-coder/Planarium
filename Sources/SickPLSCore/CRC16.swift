/// Proprietäres CRC16 des SICK-PLS-Telegrammformats.
///
/// Bit-für-Bit-Port von `SickPLSMessage::_computeCRC` aus dem
/// BSD-lizenzierten SickToolbox-Referenzcode (Jason C. Derenick & Thomas H.
/// Miller, 2008, "This software is released under a BSD Open-Source
/// License", http://sicktoolbox.sourceforge.net), erhalten über
/// https://github.com/asr-ros/asr_mild_base_laserscanner/blob/master/src/SickPLSMessage.cc
/// (Zeilen `_computeCRC`, Stand des dortigen `master`-Branchs). Bit-identisch
/// zu `SickLMS2xxMessage::_computeCRC` in der offiziellen
/// https://github.com/ros-drivers/sicktoolbox (`catkin`-Branch,
/// `c++/drivers/lms2xx/sicklms2xx/SickLMS2xxMessage.cc`) — beide Klassen
/// teilen denselben Autor und dasselbe Telegrammformat.
///
/// Vollständiger BSD-Lizenztext (Copyright-Vermerk, Bedingungen,
/// Haftungsausschluss): siehe `THIRD-PARTY-NOTICES.md` im
/// Projektwurzelverzeichnis.
///
/// Das Generatorpolynom `0x8005` entspricht keinem benannten Standard-CRC16
/// (weder CCITT noch Modbus): Der Startwert, die Schiebe-Reihenfolge und die
/// Verknüpfung mit dem jeweils vorherigen Byte (`MKSHORT(aktuellesByte,
/// vorherigesByte)`, Little-Endian) sind Teil des proprietären Algorithmus
/// und dürfen nicht durch eine generische CRC16-Bibliothek ersetzt werden.
public enum SickCRC16 {
    /// Berechnet das CRC16 über die gegebenen Bytes.
    ///
    /// Generisch über `Sequence`, damit ein Aufrufer (insbesondere
    /// ``Frame/decodePrefix(from:)`` und ``StreamParser``) ein Fenster eines
    /// größeren Puffers (`ArraySlice<UInt8>`, `Data`, …) übergeben kann, ohne
    /// es vorher in ein eigenes `Array` zu kopieren (Revisor-Review
    /// SICK-003, Finding M3).
    ///
    /// - Parameter bytes: Die Bytes, über die das CRC gebildet wird (im
    ///   Frame-Kontext: Header + Payload, also `[0 ..< 4+N)`).
    /// - Returns: Das über den proprietären Algorithmus berechnete CRC16 als
    ///   reiner Zahlenwert. Die Byte-Reihenfolge auf dem Draht (Little-Endian
    ///   beim Trailer) ist keine Eigenschaft dieses Rückgabewerts, sondern
    ///   wird von ``Frame`` beim Serialisieren/Decodieren explizit hergestellt
    ///   (siehe dort) — dieser Kommentar korrigiert eine frühere, irreführende
    ///   Formulierung ("Host-Byte-Order"), siehe Revisor-Review SICK-003,
    ///   Finding N3.
    public static func compute<Bytes: Sequence>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        var crc: UInt16 = 0
        var previousByte: UInt8 = 0

        for currentByte in bytes {
            if crc & 0x8000 != 0 {
                crc = (crc & 0x7fff) << 1
                crc ^= SickPLSFrameConstants.crcGeneratorPolynomial
            } else {
                crc <<= 1
            }
            crc ^= UInt16(currentByte) | (UInt16(previousByte) << 8)
            previousByte = currentByte
        }

        return crc
    }
}
