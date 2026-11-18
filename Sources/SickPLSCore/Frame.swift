/// Ein einzelnes, vollständiges SICK-PLS-Telegramm (Frame).
///
/// Aufbau auf dem Draht (siehe `SICK Doku/wire-protocol.md` Abschnitt 2):
///
/// ```
/// Offset   Länge   Feld
/// ------   -----   ----
/// 0        1       STX = 0x02
/// 1        1       Adresse
/// 2..3     2       Payload-Länge, uint16 Little-Endian, in Bytes
/// 4..N     N       Payload
/// N+4..+1  2       CRC16 (proprietär, Little-Endian), über Byte [0 .. 4+N)
/// ```
///
/// **Längenobergrenze (812, nicht 818):** `wire-protocol.md` widerspricht sich
/// an dieser Stelle selbst — Abschnitt 5 Regel 2a nennt für dieselbe Prüfung
/// `MESSAGE_MAX_LEN` (818), Abschnitt 5a das engere `PAYLOAD_MAX_LEN` (812).
/// Diese Implementierung folgt bewusst 812 (`SickPLSFrameConstants.payloadMaxLength`):
/// Ein Längenfeld von 818 ergäbe einen 824-Byte-Frame und würde
/// `MESSAGE_MAX_LEN` selbst sprengen, 812 ist daher die einzige in sich
/// widerspruchsfreie Lesart. Als bewusste, dokumentierte Abweichung von
/// Abschnitt 5 Regel 2a festgehalten (Revisor-Review SICK-003, Finding M1),
/// nicht als Versehen.
///
/// `Frame` bildet ausschließlich den Vertrag für **ein** bereits
/// vollständig vorliegendes Telegramm ab (Serialisierung und Decodierung).
/// Fortlaufendes Stream-Framing über mehrere ankommende Byte-Chunks hinweg
/// (siehe Abschnitt 5a derselben Datei) leistet ``StreamParser``, der auf
/// ``decodePrefix(from:)`` aufsetzt.
public struct Frame: Equatable, Sendable {
    /// Adressbyte (Ziel bei Host→Scanner, Quelle bei Scanner→Host).
    public let address: UInt8

    /// Payload-Bytes des Frames (ohne Header/Trailer).
    public let payload: [UInt8]

    private init(address: UInt8, payload: [UInt8]) {
        // Invariante, die build(...) und decodePrefix(...) bereits geprüft
        // haben müssen: Ohne sie würde encoded() das Längenfeld unbemerkt
        // verkürzen (UInt16-Überlauf), siehe Revisor-Review SICK-003, N2.
        precondition(
            payload.count <= SickPLSFrameConstants.payloadMaxLength,
            "Frame.payload darf SickPLSFrameConstants.payloadMaxLength nicht überschreiten; "
                + "dies ist eine interne Invariante, die build(...) und decodePrefix(...) bereits durchsetzen."
        )
        self.address = address
        self.payload = payload
    }

    /// Fehler beim Aufbau eines ``Frame`` aus Adresse und Payload.
    public enum BuildError: Error, Equatable, Sendable {
        /// Die Payload überschreitet ``SickPLSFrameConstants/payloadMaxLength``.
        case payloadTooLarge(Int)
    }

    /// Baut ein ``Frame`` aus Adresse und Payload.
    ///
    /// - Throws: ``BuildError/payloadTooLarge(_:)``, wenn `payload.count`
    ///   ``SickPLSFrameConstants/payloadMaxLength`` überschreitet.
    public static func build(address: UInt8, payload: [UInt8]) throws -> Frame {
        guard payload.count <= SickPLSFrameConstants.payloadMaxLength else {
            throw BuildError.payloadTooLarge(payload.count)
        }
        return Frame(address: address, payload: payload)
    }

    /// Serialisiert den Frame in seine Byte-Darstellung auf dem Draht,
    /// inklusive STX, Längenfeld (Little-Endian) und CRC16-Trailer
    /// (Little-Endian).
    public func encoded() -> [UInt8] {
        let length = UInt16(payload.count)

        var bytes: [UInt8] = []
        bytes.reserveCapacity(SickPLSFrameConstants.headerLength + payload.count + SickPLSFrameConstants.trailerLength)
        bytes.append(SickPLSFrameConstants.startOfText)
        bytes.append(address)
        bytes.append(UInt8(length & 0xFF))
        bytes.append(UInt8((length >> 8) & 0xFF))
        bytes.append(contentsOf: payload)

        let crc = SickCRC16.compute(bytes)
        bytes.append(UInt8(crc & 0xFF))
        bytes.append(UInt8((crc >> 8) & 0xFF))

        return bytes
    }

    /// Ergebnis von ``decodePrefix(from:)``: der decodierte Frame plus die
    /// Anzahl der dafür tatsächlich verbrauchten Bytes.
    public struct Decoded: Equatable, Sendable {
        public let frame: Frame
        /// Anzahl der Bytes, die dieser Frame am Anfang des übergebenen
        /// Puffers belegt (`headerLength + payload.count + trailerLength`).
        /// Erspart Aufrufern (insbesondere ``StreamParser``), diesen Wert
        /// selbst nachzurechnen (Revisor-Review SICK-003, Finding M3).
        public let consumedBytes: Int
    }

    /// Fehler beim Decodieren eines ``Frame`` aus einem Byte-Puffer.
    public enum DecodingError: Error, Equatable, Sendable {
        /// Das erste Byte ist kein STX (`0x02`).
        case invalidStartByte(UInt8)
        /// Der Puffer enthält weniger als ``SickPLSFrameConstants/headerLength`` Byte.
        case incompleteHeader(available: Int, required: Int)
        /// Das Längenfeld überschreitet ``SickPLSFrameConstants/payloadMaxLength``.
        case payloadLengthExceedsMaximum(UInt16)
        /// Der Puffer enthält weniger Byte, als der vollständige Frame laut Längenfeld benötigt.
        case incompleteFrame(available: Int, required: Int)
        /// Das berechnete CRC16 stimmt nicht mit dem Trailer überein.
        ///
        /// Benennung bewusst `received`/`computed` (nicht `expected`): Der
        /// vom Draht gelesene Trailer-Wert ist nicht "erwartet", sondern
        /// schlicht empfangen — `expected` las sich in einer Diagnoseausgabe
        /// genau verkehrt herum (Revisor-Review SICK-003, Finding N1).
        case checksumMismatch(received: UInt16, computed: UInt16)
        /// Nur von ``decodeExact(from:)``: der Puffer enthält nach einem
        /// vollständigen, CRC-validen Frame noch weitere Bytes.
        case trailingBytes(consumed: Int, total: Int)
    }

    /// Decodiert **einen** vollständigen Frame vom Anfang von `bytes`.
    ///
    /// Nachfolgende Bytes in `bytes` (z. B. der Beginn des nächsten Frames
    /// oder Rauschen) sind zulässig und werden ignoriert — genau das braucht
    /// ein Aufrufer, der über einem gleitenden Puffer arbeitet (siehe
    /// ``StreamParser``). Für einen Puffer, der garantiert **nur** einen
    /// einzigen Frame enthalten darf, siehe ``decodeExact(from:)``.
    ///
    /// Generisch über `RandomAccessCollection` mit `Index == Int` (erfüllt
    /// von `Array<UInt8>`, `ArraySlice<UInt8>` und `Data`), damit ein
    /// Ringpuffer ein Fenster ohne Kopie übergeben kann (Revisor-Review
    /// SICK-003, Finding M3).
    public static func decodePrefix<Bytes: RandomAccessCollection>(
        from bytes: Bytes
    ) -> Result<Decoded, DecodingError> where Bytes.Element == UInt8, Bytes.Index == Int {
        guard let firstByte = bytes.first else {
            return .failure(.incompleteHeader(available: 0, required: SickPLSFrameConstants.headerLength))
        }
        guard firstByte == SickPLSFrameConstants.startOfText else {
            return .failure(.invalidStartByte(firstByte))
        }
        guard bytes.count >= SickPLSFrameConstants.headerLength else {
            return .failure(.incompleteHeader(available: bytes.count, required: SickPLSFrameConstants.headerLength))
        }

        let base = bytes.startIndex
        let length = UInt16(bytes[base + 2]) | (UInt16(bytes[base + 3]) << 8)
        guard length <= SickPLSFrameConstants.payloadMaxLength else {
            return .failure(.payloadLengthExceedsMaximum(length))
        }

        let frameLength = SickPLSFrameConstants.headerLength + Int(length) + SickPLSFrameConstants.trailerLength
        guard bytes.count >= frameLength else {
            return .failure(.incompleteFrame(available: bytes.count, required: frameLength))
        }

        let payloadStart = base + SickPLSFrameConstants.headerLength
        let payloadEnd = payloadStart + Int(length)
        let frameEnd = base + frameLength

        // CRC direkt über das Puffer-Fenster berechnet, ohne eine Kopie nur
        // für die Prüfsumme anzulegen — SickCRC16.compute nimmt jede
        // Byte-Sequenz. Nur die letztlich ausgelieferte Payload wird unten
        // materialisiert.
        let computedCRC = SickCRC16.compute(bytes[base..<payloadEnd])
        let receivedCRC = UInt16(bytes[frameEnd - 2]) | (UInt16(bytes[frameEnd - 1]) << 8)
        guard computedCRC == receivedCRC else {
            return .failure(.checksumMismatch(received: receivedCRC, computed: computedCRC))
        }

        let payload = Array(bytes[payloadStart..<payloadEnd])
        let frame = Frame(address: bytes[base + 1], payload: payload)
        return .success(Decoded(frame: frame, consumedBytes: frameLength))
    }

    /// Decodiert `bytes` als **genau einen** vollständigen Frame — der
    /// Puffer darf weder zu kurz sein noch überzählige Bytes nach dem Frame
    /// enthalten.
    ///
    /// Für einen Puffer, der zusätzliche nachfolgende Bytes enthalten darf
    /// (z. B. den Anfang des nächsten Frames), siehe ``decodePrefix(from:)``.
    public static func decodeExact<Bytes: RandomAccessCollection>(
        from bytes: Bytes
    ) -> Result<Frame, DecodingError> where Bytes.Element == UInt8, Bytes.Index == Int {
        switch decodePrefix(from: bytes) {
        case .success(let decoded):
            let total = bytes.count
            guard decoded.consumedBytes == total else {
                return .failure(.trailingBytes(consumed: decoded.consumedBytes, total: total))
            }
            return .success(decoded.frame)
        case .failure(let error):
            return .failure(error)
        }
    }
}
