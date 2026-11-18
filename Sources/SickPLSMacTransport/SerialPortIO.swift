/// Ergebnis eines einzelnen Leseversuchs an einem seriellen Port.
///
/// Die Dreiteilung ist der zentrale Vertrag dieses Pakets (SICK-008,
/// `StreamParser.finish()`-Kopfkommentar; SICK-009-Auftrag): ``timeout``
/// bedeutet nur „gerade kommt nichts" und darf niemals wie ein Stromende
/// behandelt werden — nur ``closed`` ist ein echtes Stromende (EOF, Gerät
/// getrennt, Datei-Handle geschlossen) und darf `StreamParser.finish()`
/// auslösen.
public enum SerialPortReadOutcome: Equatable, Sendable {
    /// Neu eingetroffene Bytes (kann leer sein, falls `read` 0 Byte ohne
    /// Fehler liefert, ohne dass das Gerät den Stream beendet hat).
    case bytes([UInt8])
    /// Innerhalb der angefragten Zeitspanne sind keine Bytes eingetroffen.
    /// **Kein** Stromende — der nächste Aufruf kann wieder Bytes liefern.
    case timeout
    /// Echtes Stromende: EOF, Portschließung oder Geräte-Trennung.
    ///
    /// **Invariante** (review-sick-009.md Finding N1): Ein Konformer, der
    /// `.closed` liefert, hat den zugrundeliegenden Deskriptor dabei
    /// bereits geschlossen (siehe ``SerialPortFileDescriptor/close()``,
    /// „mehrfaches Schließen ist unschädlich"). Ein Aufrufer darf sich
    /// darauf verlassen und muss nach einem `.closed`-Ergebnis nicht
    /// zusätzlich selbst `close()` rufen, um den Deskriptor freizugeben.
    case closed
}

/// Ein geöffneter serieller Port, reduziert auf die reine Lese-API. Es
/// gibt bewusst **keine** `write`-Methode und keine Möglichkeit, TX-Bytes
/// zu senden — analog zu `pls_recorder.recorder.ReadOnlySerial` in
/// `SICK Doku/fixtures-and-testing.md` Abschnitt 5 und der in
/// `SICK Doku/client-architecture.md` Abschnitt 2.1 beschriebenen
/// Trennung von RX-only- und TX-fähigem Konformer.
public protocol SerialPortFileDescriptor: AnyObject {
    /// Liest neu eingetroffene Bytes oder wartet höchstens
    /// `timeoutMilliseconds` auf welche. Blockiert nie länger als das.
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome

    /// Schließt den Port. Danach liefert `read` nur noch ``SerialPortReadOutcome/closed``.
    /// Mehrfaches Schließen ist unschädlich.
    func close()
}

/// Öffnet einen seriellen Port unter einem expliziten Pfad und mit einer
/// expliziten Baudrate. Es gibt bewusst **keine** Methode, die selbst
/// einen Port auswählt oder automatisch verbindet — jeder Aufrufer muss
/// Pfad **und** Baudrate explizit nennen (SICK-009-Auftrag: „keine
/// automatische Verbindung/kein Auto-Scan"; SICK-010-Scope-Änderung:
/// „kein Auto-Baud", siehe ``SerialPortBaudRate``).
///
/// Diese Protokollgrenze ist die testbare FD/Syscall-Abstraktion: Die
/// reale Implementierung (``DarwinSerialPortOpener``) kapselt `open(2)`,
/// `termios`, `poll(2)`/`read(2)`; Tests verwenden stattdessen einen Fake
/// und öffnen nie ein physisches Gerät.
public protocol SerialPortOpener {
    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> SerialPortFileDescriptor
}

/// Fehler beim Öffnen eines seriellen Ports.
public enum SerialPortOpenError: Error, Equatable, Sendable {
    /// `open(2)` scheiterte; `errno` ist der rohe POSIX-Fehlercode.
    case openFailed(errno: Int32)
    /// `tcgetattr`/`tcsetattr` scheiterte beim Konfigurieren von
    /// ``SerialPortSettings``; `errno` ist der rohe POSIX-Fehlercode.
    case configurationFailed(errno: Int32)
    /// `path` lag außerhalb von `/dev/cu.*` (review-sick-009.md Finding
    /// N6: der öffentliche Öffnungspfad ist bewusst auf reine
    /// Callout-Geräte beschränkt, siehe
    /// ``SickPLSSerialConnection/open(portPath:opener:)``).
    case pathNotAllowed(String)
}
