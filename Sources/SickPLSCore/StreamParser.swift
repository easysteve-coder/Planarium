/// Inkrementeller Framing-Parser für einen fortlaufenden SICK-PLS-Bytestrom.
///
/// Setzt `SICK Doku/wire-protocol.md` Abschnitt 5a um: STX-Kandidatensuche,
/// byteweise (nicht frameweise) Fehlerrückgewinnung, kein nach außen
/// sichtbarer Fehler bei Rauschen oder ungültiger CRC — beides ist im
/// laufenden Betrieb normal (Verbindungsstart mitten im Stream, Bit-Fehler).
/// Hält den Puffer als „Ringpuffer oder einfache Liste" — wörtlich so in
/// §5a als gleichwertig benannt; diese Implementierung nutzt eine einfache,
/// vorn getrimmte `Array`-Liste, keine zusätzliche Ringpuffer-Datenstruktur.
///
/// Reine Framing-Zustandsmaschine: kein Transport, kein B0-Parsing (siehe
/// `ROADMAP.md` R1 vs. R2), delegiert die eigentliche Frame-Validierung
/// vollständig an ``Frame/decodePrefix(from:)`` statt sie ein zweites Mal
/// zu implementieren.
///
/// **Kein zusätzliches Puffer-Limit:** §5a nennt eine Selbstschutz-Obergrenze
/// gegen unbegrenztes Wachstum als *Beispiel* ("z. B. 4096 Byte"), keine
/// Pflicht. Unter dem hier umgesetzten Algorithmus ist ein solches Limit
/// nachweisbar wirkungslos: Nach jedem ``feed(_:)``-Aufruf ist der Puffer
/// entweder leer (kein STX gefunden), kürzer als `headerLength` (Header
/// unvollständig) oder kürzer als die für den aktuellen Kandidaten
/// deklarierte `frameLength` (≤ `maxFrameLength` = 818 Byte) — sobald genug
/// Bytes für einen Kandidaten vorliegen, wird er in derselben Schleife sofort
/// verarbeitet (ausgeliefert oder byteweise verworfen), der Puffer wächst
/// also nie über 818 Byte hinaus. Eine zusätzliche Kappungsgrenze wäre unter
/// diesem Algorithmus toter, nicht testbarer Code und deshalb bewusst nicht
/// eingebaut (siehe Coder-Rücklauf SICK-004 für die vollständige
/// Beweisskizze).
///
/// **Abschluss (``finish()``):** ``feed(_:)`` allein hat keinen Weg zu sagen
/// „es kommt nichts mehr" — ein unvollständiger Kandidat am Pufferende würde
/// dadurch auf unbestimmte Zeit bereits vollständige, CRC-valide Frames
/// dahinter festhalten (Revisor-Review SICK-004, Finding M1: 19 % Abweichung
/// gegenüber einer Batch-Referenz ohne Nachlauf, 0 % mit Nachlauf). ``finish()``
/// behandelt einen dann unvollständigen Kandidaten wie einen ungültigen:
/// ein Byte verwerfen, weitersuchen, bis der Puffer leer ist — exakt die
/// Batch-Semantik aus §5, angewendet auf einen endlichen Strom.
///
/// **Diagnostik (``diagnostics``):** `client-architecture.md` §2.2/§3
/// verlangt für Live-Client und Windows-Test-App einen fortlaufenden Zähler
/// „valide Frames" getrennt von „verworfene STX-Kandidaten" (Revisor-Review
/// SICK-004, Finding M2) — aus reiner Beobachtung des `feed(_:)`-Ergebnisses
/// nicht ableitbar, ohne das Framing ein zweites Mal nachzubauen.
public struct StreamParser: Sendable {
    private var buffer: [UInt8] = []

    /// Fortlaufende, nie zurückgesetzte Zähler über die Lebensdauer eines
    /// ``StreamParser``. Reine Beobachtung — kein Zähler beeinflusst das
    /// Framing-Verhalten.
    public struct Diagnostics: Equatable, Sendable {
        /// Anzahl vollständig decodierter, CRC-valider Frames.
        public internal(set) var validFrames = 0
        /// STX-Kandidaten, deren Längenfeld ``SickPLSFrameConstants/payloadMaxLength`` überschritt.
        public internal(set) var discardedCandidatesOversize = 0
        /// STX-Kandidaten mit vollständiger, aber CRC-ungültiger Struktur.
        public internal(set) var discardedCandidatesChecksumMismatch = 0
        /// Kandidaten, die bei ``finish()`` noch unvollständig waren und
        /// deshalb verworfen wurden (können bei ``feed(_:)`` nicht auftreten).
        public internal(set) var discardedCandidatesAtFinish = 0
        /// Bytes, die zu keinem STX-Kandidaten gehörten (Rauschen vor dem
        /// nächsten STX, oder der gesamte Puffer, wenn kein STX enthalten war).
        public internal(set) var skippedNoiseBytes = 0

        /// Summe aller verworfenen STX-Kandidaten, unabhängig von der
        /// Ursache (`client-architecture.md` §2.2/§3 verlangt genau eine
        /// Zahl „verworfene STX-Kandidaten"). Berechnet statt gespeichert,
        /// damit eine künftige vierte Verwurfsursache automatisch mitzählt,
        /// statt bestehende Konsumenten still untermelden zu lassen
        /// (Revisor-Review SICK-007, Finding N1).
        public var discardedCandidates: Int {
            discardedCandidatesOversize + discardedCandidatesChecksumMismatch + discardedCandidatesAtFinish
        }

        /// Öffentliche Null-Initialisierung, damit UI-Code und Tests
        /// außerhalb dieses Moduls einen Vergleichswert bauen können
        /// (Revisor-Review SICK-007, Finding N2) — ohne diesen Initializer
        /// ist der synthetisierte Memberwise-Init nur modulintern sichtbar.
        public init() {}
    }

    /// Siehe ``Diagnostics``.
    public private(set) var diagnostics = Diagnostics()

    public init() {}

    /// Nur für Tests: Anzahl der aktuell gepufferten, noch nicht
    /// ausgelieferten Bytes. Kein Teil der öffentlichen API (kein `public`).
    var bufferedByteCount: Int { buffer.count }

    /// Nimmt neu eingetroffene Bytes entgegen und liefert jeden dadurch
    /// vollständig und CRC-valide gewordenen Frame, in Empfangsreihenfolge.
    ///
    /// Beliebige Chunk-Größen sind zulässig — von einem Byte pro Aufruf bis
    /// zu mehreren vollständigen Frames auf einmal. Das Ergebnis hängt nicht
    /// von der Chunk-Größe der Eingabe ab (§5a).
    public mutating func feed<Bytes: Sequence>(_ newBytes: Bytes) -> [Frame] where Bytes.Element == UInt8 {
        buffer.append(contentsOf: newBytes)
        return drain(atEndOfStream: false)
    }

    /// Signalisiert das Ende eines endlichen Stroms: liefert jeden Frame,
    /// der sich aus den noch gepufferten Bytes unter Batch-Semantik ergibt
    /// (siehe Kopfkommentar), und verwirft danach alles, was nicht zu einem
    /// vollständigen Frame wurde — kein Frame bleibt unbestimmt lange hängen.
    ///
    /// Nach ``finish()`` ist der Puffer stets leer. Der Parser bleibt danach
    /// benutzbar (z. B. für einen neuen, unabhängigen Mitschnitt); die
    /// ``diagnostics``-Zähler werden dabei **nicht** zurückgesetzt.
    ///
    /// **Nur für wirkliches Stromende** (Dateiende, Portschließung) —
    /// **nicht** für eine Lesepause oder einen Read-Timeout (Revisor-Review
    /// SICK-007, Finding N4): Ein Timeout sieht von außen genauso aus wie
    /// „gerade kommt nichts", ist aber kein Beleg dafür, dass kein weiteres
    /// Byte mehr eintrifft. `finish()` bei einem Timeout zu rufen würde
    /// einen gerade erst halb eingetroffenen, völlig gesunden Frame
    /// verwerfen und fälschlich als ``Diagnostics/discardedCandidatesAtFinish``
    /// zählen. Ein Transport-Slice ruft `finish()` ausschließlich dann,
    /// wenn feststeht, dass keine weiteren Bytes mehr eintreffen werden.
    public mutating func finish() -> [Frame] {
        drain(atEndOfStream: true)
    }

    private mutating func drain(atEndOfStream: Bool) -> [Frame] {
        var delivered: [Frame] = []

        frameLoop: while true {
            guard let stxOffset = buffer.firstIndex(of: SickPLSFrameConstants.startOfText) else {
                // Kein STX im gesamten Puffer: alles war Rauschen.
                diagnostics.skippedNoiseBytes += buffer.count
                buffer.removeAll(keepingCapacity: true)
                break frameLoop
            }
            if stxOffset > buffer.startIndex {
                // Rauschen vor dem ersten STX-Kandidaten überspringen.
                let skipped = stxOffset - buffer.startIndex
                buffer.removeFirst(skipped)
                diagnostics.skippedNoiseBytes += skipped
            }

            switch Frame.decodePrefix(from: buffer) {
            case .success(let decoded):
                delivered.append(decoded.frame)
                buffer.removeFirst(decoded.consumedBytes)
                diagnostics.validFrames += 1

            case .failure(.incompleteHeader), .failure(.incompleteFrame):
                if atEndOfStream {
                    // Es kommen keine weiteren Bytes mehr -- dieser Kandidat
                    // kann nie vollständig werden. Wie einen ungültigen
                    // Kandidaten behandeln: ein Byte verwerfen, weitersuchen.
                    buffer.removeFirst()
                    diagnostics.discardedCandidatesAtFinish += 1
                } else {
                    // Noch nicht genug Bytes für diesen Kandidaten — auf den
                    // nächsten feed(_:)-Aufruf warten, nichts verwerfen.
                    break frameLoop
                }

            case .failure(.payloadLengthExceedsMaximum):
                // Ungültiger Kandidat: nur das führende STX verwerfen, nicht
                // die ganze vermutete Framelänge — ein echter Frame könnte
                // ein Byte später beginnen (§5a, byteweise Fehlerrückgewinnung).
                buffer.removeFirst()
                diagnostics.discardedCandidatesOversize += 1

            case .failure(.checksumMismatch):
                buffer.removeFirst()
                diagnostics.discardedCandidatesChecksumMismatch += 1

            case .failure(.invalidStartByte), .failure(.trailingBytes):
                // Strukturell unerreichbar: buffer[buffer.startIndex] wurde
                // gerade als STX gefunden (invalidStartByte kann nicht
                // auftreten), und decodePrefix liefert trailingBytes nie
                // (das ist ausschließlich Frame.decodeExact vorbehalten).
                // Defensiv statt preconditionFailure (Revisor-Review
                // SICK-004, Finding N1): ein Vertrag „kein Fehler nach
                // außen" darf eine laufende RX-Sitzung nicht durch einen
                // späteren, hier unbemerkten Refactoring-Fehler abstürzen
                // lassen. Im (heute unerreichbaren) Fall wie einen
                // ungültigen Kandidaten behandeln, ohne eigenen Zähler --
                // ein Zähler für einen nachweislich unmöglichen Fall wäre
                // selbst irreführend.
                buffer.removeFirst()
            }
        }

        return delivered
    }
}
