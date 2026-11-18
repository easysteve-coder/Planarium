/// Die serielle Restkonfiguration für den SICK PLS101-316, mit fester
/// Baudrate ausgenommen (siehe ``SerialPortBaudRate``): 8 Datenbits,
/// gerade Parität, 1 Stopbit, kein Hardware- oder Software-Flow-Control
/// (`SICK Doku/wire-protocol.md` Abschnitt 1).
///
/// Bewusst **keine** konfigurierbaren Alternativen für diese Werte: Der
/// Auftrag nennt sie fest, nicht als Startwert unter mehreren, und ein
/// höherer Baudratenwechsel ist laut `wire-protocol.md` Abschnitt 6 ein
/// eigenes, bisher nur für den jeweils aktiven Wert erfolgreich
/// reproduziertes Telegramm — kein Transportparameter, den dieser Slice
/// frei wählbar machen sollte.
public enum SerialPortSettings {
    public static let dataBits = 8
    public static let parity = Parity.even
    public static let stopBits = 1
    public static let flowControl = FlowControl.none

    public enum Parity: Sendable {
        case even
    }

    public enum FlowControl: Sendable {
        case none
    }
}

/// Explizit gewählte Baudrate für eine **rein lesende** Verbindung —
/// **kein** Auto-Baud, kein beliebiger `Int32`, nur die drei am Projektgerät
/// verwendeten Werte sind wählbar. 500000 ist ausschließlich über RS-422
/// belegt und wird auf Darwin exakt per `IOSSIOSPEED` gesetzt.
///
/// **Hintergrund der Änderung:** `wire-protocol.md` Abschnitt 1 belegt
/// 38 400 Baud als 🟢 live-verifizierten Wert (Runde 12) — das war bis
/// SICK-010 die einzige, fest einprogrammierte Konfiguration. Der Owner
/// hat am 2026-09-21 gemeldet, dass der aktuell angeschlossene Scanner
/// mit **9 600 Baud** läuft; dieser Slice öffnet den Port bei genau
/// diesem RX-Startwert. `9600` und `38400` sind hier zwei gleichrangige,
/// **rein passiv gehörte** Konfigurationen — kein Ablauf, der von der
/// einen zur anderen wechselt. Es gibt bewusst **kein** Auto-Baud
/// (Ausprobieren mehrerer Bitraten am realen Port wäre bereits ein
/// aktiver Schritt) — der Aufrufer (CLI: `--baud`, Bibliothek:
/// `SickPLSSerialConnection.open(portPath:baudRate:opener:)`) muss den
/// Wert immer explizit nennen. Der geschlossene Standardlauf bleibt trotz
/// des erweiterten Transporttyps bei 9600 → 38400; 500000 ist eine bewusst
/// bediente Entwicklungsoption.
///
/// **Bewusst nicht Teil dieses Typs oder dieses Pakets:** Ein aktiver
/// Baudratenwechsel des Geräts selbst ist laut `wire-protocol.md`
/// Abschnitt 6 ein eigenes TX-Telegramm (Kommando `0x20` mit Baudcode),
/// bisher nur für den jeweils bereits aktiven Wert (38400) erfolgreich
/// reproduziert — jeder andere Zielwert scheiterte bislang (NACK/
/// Timeout). Ebenso dokumentiert, aber ausdrücklich nicht aktiv
/// reproduziert: ein Telegramm-Kandidat für einen „kontinuierlichen"
/// Messmodus (`wire-protocol.md` Abschnitt 6, Kommando `0x20`/Modus
/// `0x20`). Beides sind TX-Aktionen und damit außerhalb des RX-only-
/// Scopes von `SickPLSMacTransport` — dieses Paket hat strukturell keine
/// `write`-Methode und implementiert daher weder den Wechsel noch den
/// Modus. Ein späterer, separat freizugebender TX-Konfigurationsslice
/// (vorgemerkt als SICK-011) müsste beides eigenständig und mit
/// eigener Team-Entscheidung vor jedem realen Befehl umsetzen.
public enum SerialPortBaudRate: Int32, Sendable, CaseIterable {
    /// Owner-gemeldete, aktuell am angeschlossenen Scanner konfigurierte
    /// RX-Startbaudrate (gemeldet 2026-09-21). **Noch nicht am echten
    /// Port validiert** — siehe Checkpoint, offenes Risiko wie CRC/B0-
    /// Trailerbyte/`termios`-Konfiguration insgesamt.
    case baud9600 = 9_600
    /// Historisch 🟢 live-verifizierte RX-Zielbaudrate (`wire-protocol.md`
    /// Abschnitt 1, Runde 12) — weiterhin ein gültiger, explizit
    /// wählbarer Wert, nur seit der Owner-Meldung vom 2026-09-21 nicht
    /// mehr der Startwert am aktuell angeschlossenen Scanner.
    case baud38400 = 38_400
    /// Am realen PLS101-316 über RS-422 am 23.09.2026 live bestätigt.
    /// Darwin setzt diesen nichtstandardisierten Wert über `IOSSIOSPEED`;
    /// es gibt keinen Rückfall auf 460800 oder eine andere Näherung.
    case baud500000 = 500_000
}
