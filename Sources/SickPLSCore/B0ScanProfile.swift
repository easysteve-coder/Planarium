/// Ein einzelnes, bereits vollständig CRC-validiertes B0-Scanprofil
/// (autonomer Broadcast des Scanners, `Frame.payload` eines B0-Frames).
///
/// Aufbau der Payload (siehe `SICK Doku/b0-scan-profile.md` Abschnitt 1):
///
/// ```
/// Byte    Bedeutung
/// 0       Kommandobyte 0xB0
/// 1       num_measurements low byte
/// 2       Bit 0-1: num_measurements high bits
///         Bit 3-4: partial_scan_index
///         Bit 2, 5-7: unbelegt/unmodelliert
/// 3..     num_measurements * 2 Byte, je Messpunkt 2 Byte:
///           lo = Byte[i*2], hi = Byte[i*2+1]
///           Messwert (13 Bit)   = lo + 256*(hi & 0x1F)
///           field_flags (3 Bit) = (hi & 0xE0) >> 5
/// ```
///
/// Struktur-Decoder mit der inzwischen belegten PLS-Distanzeinheit
/// **Zentimeter**. Der Drahtwert bleibt unverändert als 13-Bit-``UInt16``
/// erhalten; ``Measurement/distanceCentimeters`` und
/// ``Measurement/distanceMeters`` sind verlustfreie beziehungsweise reine
/// Anzeigeableitungen davon. Eine Winkelinterpretation sowie eine Bedeutung
/// der `field_flags` werden weiterhin nicht unterstellt (b0-scan-profile.md §1:
/// „field_flags sind unmodelliert"), **keine** Teilscan-Reassemblierung über
/// mehrere Frames (`partial_scan_index` wird nur roh durchgereicht) — all das
/// ist laut `AGENTS.md`/`ROADMAP.md` ausdrücklich spätere, eigene Arbeit.
///
/// **Bekannte Dokument-Ungenauigkeit (Owner-Entscheidung SICK-006, revidiert
/// gegenüber SICK-005):** Die Feldstruktur oben beschreibt, *wie* die ersten
/// `3 + 2*N` Payload-Byte gelesen werden — sie behauptet aber nirgends, dass
/// die Payload dort endet. `b0-scan-profile.md` Abschnitt 3 tabelliert für
/// alle drei beobachteten Punktzahlen eine **um genau 1 Byte längere**
/// Gesamtlänge (`4 + 2*N`):
///
/// | N   | 3+2*N (Feldstruktur §1) | Tabelle §3 (real erwartet) |
/// |-----|-------------------------|----------------------------|
/// | 90  | 183                     | **184**                    |
/// | 180 | 363                     | **364**                    |
/// | 361 | 725                     | **726**                    |
///
/// Für 90 Punkte ist die Framegröße 190 Byte 🟢 live-verifiziert (zweifach
/// unabhängig: als exakter Wert in §3 und als konstanter 190-Byte-Abstand
/// über 439 Frames in §4) — `190 − 4 (Header) − 2 (CRC) = 184`. `3+2*N` hat
/// für diesen Fall **keine** ganzzahlige Lösung (`184 = 3+2N → N = 90,5`),
/// `4+2*N` dagegen exakt `N = 90`. **`4+2*N` ist damit die erwartete,
/// real beobachtete Drahtform**, nicht `3+2*N`.
///
/// Die Bedeutung des zusätzlichen, einen Trailer-Bytes ist weiterhin
/// **ungeklärt** — eine Vermutung (ein abschließendes Statusbyte, wie es die
/// LMS2xx-/PLS-Telegrammfamilie an anderer Stelle kennt) ist nicht belegt und
/// wird hier bewusst **nicht** als Tatsache behandelt. Deshalb: Der Decoder
/// verlangt weiterhin strikt mindestens `3 + 2*N` Byte (die dokumentierten
/// Felder müssen vollständig vorhanden sein — Datenverlust bleibt ein
/// harter Fehler), akzeptiert aber jedes Byte danach und reicht es
/// unverändert und uninterpretiert über ``trailingBytes`` durch. Ein echter
/// RX-only-Mitschnitt bleibt Pflicht, um zu klären, was dieses Byte ist
/// (siehe Checkpoint, verknüpft mit dem offenen CRC-Altrisiko).
///
/// **Wichtige Unterscheidung (Revisor-Review SICK-006, Finding M1):**
/// „Keine Interpretation" gilt für die *Bedeutung* des Zusatzbytes, nicht für
/// seine *Position*. Dass es **hinter** den Messwerten liegt statt z. B.
/// zwischen Header und Messwerten eingeschoben, ist eine strukturelle
/// Annahme, gestützt auf `b0-scan-profile.md` §1 (das die Messwerte
/// ausdrücklich auf Byte `3..` legt — ein eingeschobenes Byte würde §1
/// widersprechen, ein angehängtes nicht), aber am Gerät nicht gemessen.
/// Eine falsche Positionsannahme wäre an Länge und `trailingBytes.count`
/// allein **nicht** erkennbar (beide blieben gleich, nur die Messwerte
/// wären um ein Byte verschoben) — falsifizierbar nur über Wertplausibilität
/// und `partialScanIndex` (siehe Validierungs-Checkliste im Checkpoint).
public struct B0ScanProfile: Equatable, Sendable {
    /// Oberes Ende des 13-Bit-Messwertbereichs; 8191 bedeutet Bereichsende.
    public static let measurementValueMaximum: UInt16 = 8191

    /// Kommandobyte, das ein B0-Scanprofil einleitet.
    public static let commandByte: UInt8 = 0xB0

    /// Länge des festen Headers in Byte (Kommandobyte + 2 Byte
    /// Punktzahl/Index), bevor die Messwerte beginnen.
    public static let headerLength = 3

    /// 2-Bit-Feld, roh durchgereicht (siehe b0-scan-profile.md §2: in jedem
    /// bisher ausgewerteten realen Capture durchgehend `0`, Bedeutung bei
    /// abweichendem Wert nicht geklärt).
    public let partialScanIndex: UInt8

    /// Header-Byte 2 vollständig und unverändert, einschließlich der laut
    /// b0-scan-profile.md §1 „unbelegt/unmodelliert" geführten Bits 2 und
    /// 5–7. ``partialScanIndex`` und die High-Bits von `num_measurements`
    /// sind bereits daraus abgeleitet — dieses Feld verliert trotzdem keine
    /// Information: Sollte sich die Bedeutung der unmodellierten Bits später
    /// klären, muss dafür nicht rückwirkend neu decodiert werden.
    public let rawHeaderByte2: UInt8

    /// Messpunkte in Empfangsreihenfolge. `measurements.count` ist
    /// `num_measurements` aus dem Header — bewusst nicht zusätzlich als
    /// eigenes Feld gespeichert, um keine zwei Quellen der Wahrheit für
    /// denselben Wert zu haben.
    public let measurements: [Measurement]

    /// Bytes nach dem letzten dokumentierten Messpunkt, roh und
    /// uninterpretiert (leer, wenn die Payload exakt `3 + 2*N` Byte lang
    /// war). Nach heutigem Kenntnisstand real erwartet: genau 1 Byte,
    /// unbekannter Bedeutung — siehe Kopfkommentar.
    public let trailingBytes: [UInt8]

    /// Ein einzelner Messpunkt: 13-Bit-Distanzwert in Zentimetern plus rohe
    /// 3-Bit-`field_flags` ohne interpretierte Feldbedeutung.
    public struct Measurement: Equatable, Sendable {
        /// Unveränderter Drahtwert, 13 Bit (0...8191). Beim PLS ist dieser
        /// Wert durch SickToolbox, Herstellerunterlagen und reale Profile als
        /// Zentimeterdistanz belegt. Der historische Name bleibt für
        /// Quellkompatibilität erhalten.
        public let value: UInt16

        /// Kanonische PLS-Distanz in Zentimetern. Exakt derselbe ganzzahlige
        /// Wert wie ``value``; keine Kalibrierung und keine Rundung.
        public var distanceCentimeters: UInt16 { value }

        /// Distanz in Metern für kartesische Benutzeroberflächen.
        /// Ausschließlich Einheitenumrechnung, keine Kalibrierkurve.
        public var distanceMeters: Double { Double(value) / 100.0 }

        /// `field_flags`, 3 Bit (0...7). Bedeutung unmodelliert.
        public let fieldFlags: UInt8

        init(value: UInt16, fieldFlags: UInt8) {
            self.value = value
            self.fieldFlags = fieldFlags
        }

        /// Fehler bei der validierenden Konstruktion eines synthetischen
        /// ``Measurement`` über ``build(value:fieldFlags:)``.
        public enum BuildError: Error, Equatable, Sendable {
            /// `value` passt nicht in 13 Bit (0...8191).
            case valueExceedsThirteenBits(UInt16)
            /// `fieldFlags` passt nicht in 3 Bit (0...7).
            case fieldFlagsExceedThreeBits(UInt8)
        }

        /// Öffentliche, validierende Konstruktion für synthetische
        /// Messpunkte (SwiftUI-Previews, UI-Tests) — anders als
        /// ``decode(from:)`` (intern, aus bereits maskierten Wire-Bytes)
        /// prüft dieser Weg beide Feldbreiten explizit, sodass sich kein
        /// ``Measurement`` mit einem außerhalb seines Bitbereichs liegenden
        /// Wert erzeugen lässt (Revisor-Review SICK-007, B0-N1).
        public static func build(value: UInt16, fieldFlags: UInt8) throws -> Measurement {
            guard value <= 0x1FFF else {
                throw BuildError.valueExceedsThirteenBits(value)
            }
            guard fieldFlags <= 0x07 else {
                throw BuildError.fieldFlagsExceedThreeBits(fieldFlags)
            }
            return Measurement(value: value, fieldFlags: fieldFlags)
        }
    }

    private init(
        partialScanIndex: UInt8,
        rawHeaderByte2: UInt8,
        measurements: [Measurement],
        trailingBytes: [UInt8]
    ) {
        self.partialScanIndex = partialScanIndex
        self.rawHeaderByte2 = rawHeaderByte2
        self.measurements = measurements
        self.trailingBytes = trailingBytes
    }

    /// Fehler bei der validierenden Konstruktion eines synthetischen
    /// ``B0ScanProfile`` über ``build(partialScanIndex:measurements:trailingBytes:)``.
    public enum BuildError: Error, Equatable, Sendable {
        /// `partialScanIndex` passt nicht in 2 Bit (0...3).
        case partialScanIndexExceedsTwoBits(UInt8)
        /// `measurements.count` übersteigt die Punktzahl, die das
        /// 10-Bit-`num_measurements`-Feld (Byte 1 + Bit 0-1 von Byte 2)
        /// überhaupt darstellen kann (0...1023).
        case measurementCountExceedsTransportableRange(Int)
    }

    /// Öffentliche, validierende Konstruktion für synthetische Profile
    /// (SwiftUI-Previews, UI-Tests), unabhängig von ``decode(from:)`` (das
    /// bereits CRC-valide Wire-Bytes voraussetzt). `measurements` müssen
    /// bereits über ``Measurement/build(value:fieldFlags:)`` validiert sein
    /// — dieser Initializer prüft zusätzlich ``partialScanIndex`` und die
    /// Punktzahl, sodass sich kein Profil mit ungültigen Werten, Flags oder
    /// Indizes erzeugen lässt (Revisor-Review SICK-007, B0-N1).
    /// `rawHeaderByte2` wird aus `partialScanIndex` und der Punktzahl
    /// zusammengesetzt; die laut Doku unmodellierten Bits bleiben `0` — für
    /// ein synthetisches Profil gibt es keine „unbekannten" Wire-Bits.
    public static func build(
        partialScanIndex: UInt8,
        measurements: [Measurement],
        trailingBytes: [UInt8] = []
    ) throws -> B0ScanProfile {
        guard partialScanIndex <= 0x03 else {
            throw BuildError.partialScanIndexExceedsTwoBits(partialScanIndex)
        }
        guard measurements.count <= 0x3FF else {
            throw BuildError.measurementCountExceedsTransportableRange(measurements.count)
        }

        let numberOfMeasurementsHighBits = UInt8((measurements.count >> 8) & 0x03)
        let rawHeaderByte2 = numberOfMeasurementsHighBits | (partialScanIndex << 3)

        return B0ScanProfile(
            partialScanIndex: partialScanIndex,
            rawHeaderByte2: rawHeaderByte2,
            measurements: measurements,
            trailingBytes: trailingBytes
        )
    }

    /// Fehler beim Decodieren eines ``B0ScanProfile`` aus einer Frame-Payload.
    public enum DecodingError: Error, Equatable, Sendable {
        /// Die Payload ist leer.
        case emptyPayload
        /// Byte 0 ist nicht ``B0ScanProfile/commandByte``.
        case unexpectedCommandByte(UInt8)
        /// Die Payload enthält weniger als ``B0ScanProfile/headerLength`` Byte.
        case payloadTooShortForHeader(available: Int, required: Int)
        /// Die Payload enthält weniger als `3 + 2*N` Byte (`N` = aus dem
        /// Header gelesene `num_measurements`) — die dokumentierten Felder
        /// passen nicht vollständig hinein. Überzählige Bytes darüber
        /// hinaus sind dagegen **kein** Fehler, siehe ``trailingBytes``.
        case payloadTooShortForMeasurements(numberOfMeasurements: Int, required: Int, available: Int)
    }

    /// Decodiert ein ``B0ScanProfile`` aus einer bereits CRC-validierten
    /// Frame-Payload (`Frame.payload` eines B0-Frames).
    ///
    /// Kein Streaming, kein Zusammensetzen über mehrere Frames — die Payload
    /// muss bereits vollständig vorliegen (siehe `Frame.decodePrefix`/
    /// `StreamParser` für den vorgelagerten Schritt).
    public static func decode(from payload: [UInt8]) -> Result<B0ScanProfile, DecodingError> {
        guard let commandByte = payload.first else {
            return .failure(.emptyPayload)
        }
        guard commandByte == Self.commandByte else {
            return .failure(.unexpectedCommandByte(commandByte))
        }
        guard payload.count >= headerLength else {
            return .failure(.payloadTooShortForHeader(available: payload.count, required: headerLength))
        }

        let rawHeaderByte2 = payload[2]
        let numberOfMeasurements = Int(payload[1]) + 256 * Int(rawHeaderByte2 & 0x03)
        let partialScanIndex = (rawHeaderByte2 & 0x18) >> 3

        let measurementsEnd = headerLength + 2 * numberOfMeasurements
        guard payload.count >= measurementsEnd else {
            return .failure(.payloadTooShortForMeasurements(
                numberOfMeasurements: numberOfMeasurements,
                required: measurementsEnd,
                available: payload.count
            ))
        }

        var measurements: [Measurement] = []
        measurements.reserveCapacity(numberOfMeasurements)
        for index in 0..<numberOfMeasurements {
            let lo = payload[headerLength + index * 2]
            let hi = payload[headerLength + index * 2 + 1]
            let value = UInt16(lo) | (UInt16(hi & 0x1F) << 8)
            let fieldFlags = (hi & 0xE0) >> 5
            measurements.append(Measurement(value: value, fieldFlags: fieldFlags))
        }

        let trailingBytes = Array(payload[measurementsEnd...])

        return .success(B0ScanProfile(
            partialScanIndex: partialScanIndex,
            rawHeaderByte2: rawHeaderByte2,
            measurements: measurements,
            trailingBytes: trailingBytes
        ))
    }
}
