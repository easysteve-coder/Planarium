import SickPLSMacTransport

/// Eine geöffnete, **TX-fähige** serielle Verbindung. Im Gegensatz zu
/// `SerialPortFileDescriptor` (`SickPLSMacTransport`, strukturell ohne
/// `write`) hat dieser Typ bewusst eine `write`-Methode.
///
/// **Das ist die einzige Stelle in diesem Projekt, an der eine
/// `write`-fähige Protokollgrenze existiert.** SICK-011-Auftrag:
/// „Separate SickPLSActiveControl-Bibliothek, NICHT RX-Transport
/// erweitern" -- `SickPLSMacTransport` bleibt deshalb unverändert und
/// strukturell RX-only; dieses Paket definiert eine eigene, parallele
/// Protokollgrenze statt `SerialPortFileDescriptor` um `write` zu
/// erweitern. Die Lese-Seite (``SerialPortReadOutcome``) wird bewusst
/// aus `SickPLSMacTransport` wiederverwendet -- das ist ein reiner
/// Werttyp ohne TX-Bezug, keine Erweiterung des RX-Transports.
public protocol ActiveControlSerialPort: AnyObject {
    /// Schreibt `bytes` vollständig oder wirft. Kein Teil-Erfolg wird
    /// stillschweigend als Erfolg gewertet.
    func write(_ bytes: [UInt8]) throws
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome
    /// Schließt den Port. Mehrfaches Schließen ist unschädlich (wie
    /// `SerialPortFileDescriptor.close()`).
    func close()
}

/// Fehler beim Schreiben über eine ``ActiveControlSerialPort``.
public enum ActiveControlWriteError: Error, Equatable, Sendable {
    /// `write(2)` scheiterte oder lieferte weniger Bytes als angefordert
    /// (nach Ausschöpfung eines internen Wiederholversuchs für echte
    /// Teil-Schreibvorgänge); `errno` ist der rohe POSIX-Fehlercode, wo
    /// vorhanden.
    case writeFailed(errno: Int32)
}

/// Öffnet einen seriellen Port **mit Schreibzugriff** unter einem
/// expliziten Pfad und einer expliziten Baudrate -- wie
/// `SerialPortOpener` (SICK-009-Auftrag: kein Auto-Scan; SICK-010-Auftrag:
/// kein Auto-Baud), aber für den TX-fähigen Konformer.
public protocol ActiveControlSerialPortOpener {
    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> ActiveControlSerialPort
}
