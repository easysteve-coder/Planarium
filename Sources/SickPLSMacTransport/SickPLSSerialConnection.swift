import SickPLSCore

/// Eine geöffnete, reine Lese-Verbindung zu einem SICK-PLS-Scanner über
/// einen expliziten `/dev/cu.*`-Pfad. Vermittelt `StreamParser`-Frames und
/// -Diagnostik an den Client (SICK-009-Auftrag); parst optional B0-Profile
/// nicht selbst -- das bleibt Sache des Aufrufers über
/// `B0ScanProfile.decode(from:)`, damit diese Schicht reine Transport-
/// Verantwortung behält (Trennung wie in
/// `SICK Doku/client-architecture.md` Abschnitt 2.1 vorgegeben).
///
/// **Keine `write`-Methode, keine TX-Kommandos.** Es gibt bewusst keinen
/// Weg, über diesen Typ ein einziges Byte zu senden.
///
/// **Kein Auto-Scan, keine automatische Verbindung:** ``open(portPath:opener:)``
/// verlangt immer einen expliziten Pfad; diese Klasse wählt nie selbst
/// einen Port.
public final class SickPLSSerialConnection {
    /// Ergebnis eines ``readNext(timeoutMilliseconds:)``- oder
    /// ``close()``-Aufrufs.
    public typealias ReadResult = FrameReadResult
    /*
        /// Neu vollständig und CRC-valide gewordene Frames, in
        /// Empfangsreihenfolge (kann leer sein, insbesondere bei
        /// ``timeout``/kein neuer Frame oder solange ein Frame noch
        /// unvollständig ist).
        public let frames: [Frame]
        /// Fortlaufender Diagnostikstand nach diesem Aufruf, siehe
        /// `StreamParser.Diagnostics`.
        public let diagnostics: StreamParser.Diagnostics
        /// `true` genau dann, wenn dieser Aufruf ein echtes Stromende war
        /// (EOF, Portschließung) -- **nicht** bei einem Lesetimeout.
        public let reachedEndOfStream: Bool
    }
    */

    public let portPath: String
    /// Die für diese Verbindung tatsächlich verwendete Baudrate — explizit
    /// vom Aufrufer gewählt, nie erraten (SICK-010-Scope-Änderung: kein
    /// Auto-Baud). Zum Anzeigen/Protokollieren gedacht (z. B. CLI-Ausgabe).
    public let baudRate: SerialPortBaudRate
    private let stream: ReadOnlyFrameStream
    /// Ob ``close()`` den Deskriptor bereits geschlossen hat (SICK-030a).
    ///
    /// **Bewusst getrennt von ``hasReachedEndOfStream``**: Ein
    /// Stromende, das das *Gerät* auslöst (EOF, abgezogener Adapter, ein
    /// nach SICK-010 als Stromende klassifizierter Lesefehler), sagt
    /// nichts darüber, ob *unser* Dateideskriptor zu ist. Vor SICK-030a
    /// waren beide dasselbe Flag, und ``close()`` sprang nach einem
    /// gerätegetriebenen Stromende vor dem `fileDescriptor.close()`
    /// wieder heraus.

    private init(portPath: String, baudRate: SerialPortBaudRate, fileDescriptor: SerialPortFileDescriptor) {
        self.portPath = portPath
        self.baudRate = baudRate
        self.stream = ReadOnlyFrameStream(descriptor: fileDescriptor)
    }

    /// Öffnet den Port unter `portPath` explizit und konfiguriert ihn nach
    /// `SerialPortSettings` (8E1, kein Flow-Control) und der übergebenen
    /// `baudRate` (kein Auto-Baud). Es gibt keinen separaten
    /// Verbindungsschritt danach -- der zurückgegebene Wert ist sofort
    /// lesebereit.
    ///
    /// `portPath` muss vom Aufrufer explizit gewählt werden (z. B. aus
    /// ``SerialPortEnumeration/availablePortPaths(lister:)`` oder einer
    /// Kommandozeilenangabe) -- diese Methode rät oder scannt nie selbst.
    /// `baudRate` ebenso: kein Auto-Baud (SICK-010-Scope-Änderung), siehe
    /// ``SerialPortBaudRate``.
    ///
    /// **Pfadgrenze `/dev/cu.*`** (SICK-010, schließt `review-sick-009.md`
    /// Finding N6): Der öffentliche Öffnungspfad ist bewusst auf reine
    /// Callout-Geräte beschränkt (Präfix `/dev/cu.`) -- Darwins
    /// `/dev/tty.*`-Gegenstücke warten beim Öffnen typischerweise auf
    /// Carrier-Detect/DCD und sind für einen Scanner ohne Modemsignale
    /// ungeeignet; ein beliebiger anderer Pfad (Regeldatei, Socket, `/dev/null`
    /// ...) ist ohnehin nie ein SICK-Port. Geprüft hier, an der einzigen
    /// öffentlichen Öffnungsstelle dieses Pakets, statt tiefer in
    /// ``DarwinSerialPortOpener`` (der bleibt pfadunabhängig testbar) oder
    /// im CLI (das ist nicht der einzige denkbare Aufrufer).
    public static func open(
        portPath: String,
        baudRate: SerialPortBaudRate,
        opener: SerialPortOpener = DarwinSerialPortOpener()
    ) throws -> SickPLSSerialConnection {
        guard portPath.hasPrefix("/dev/cu.") else {
            throw SerialPortOpenError.pathNotAllowed(portPath)
        }
        let fileDescriptor = try opener.open(atPath: portPath, baudRate: baudRate)
        return SickPLSSerialConnection(portPath: portPath, baudRate: baudRate, fileDescriptor: fileDescriptor)
    }

    /// Siehe `StreamParser.Diagnostics`. Fortlaufend, nie zurückgesetzt.
    public var diagnostics: StreamParser.Diagnostics { stream.diagnostics }

    /// Liest einmal: wartet höchstens `timeoutMilliseconds` auf neue Bytes
    /// und liefert alle dadurch vollständig gewordenen Frames.
    ///
    /// **Ein Timeout ruft niemals `StreamParser.finish()` auf** (SICK-008-
    /// Kontrakt, `StreamParser.finish()`-Kopfkommentar) -- er bedeutet nur
    /// „gerade kommt nichts", ein bereits halb eingetroffener Frame bleibt
    /// für den nächsten Aufruf erhalten. Nur ein echtes Stromende
    /// (``ReadResult/reachedEndOfStream`` `== true`, ausgelöst durch EOF
    /// oder ``close()``) flusht den Restpuffer über `finish()`.
    ///
    /// Nach dem ersten Aufruf mit `reachedEndOfStream == true` liefern
    /// weitere Aufrufe unverändert `reachedEndOfStream == true` und keine
    /// neuen Frames, ohne den Port erneut anzufassen.
    public func readNext(timeoutMilliseconds: Int32 = 1_000) -> ReadResult {
        stream.readNext(timeoutMilliseconds: timeoutMilliseconds)
    }

    /// Schließt den Port explizit und flusht den Restpuffer über
    /// `StreamParser.finish()` -- ein echtes Stromende, ausgelöst vom
    /// Aufrufer statt vom Gerät. Mehrfacher Aufruf ist unschädlich und
    /// liefert ab dem zweiten Mal keine neuen Frames mehr.
    ///
    /// **Der Deskriptor wird auf jeden Fall geschlossen** (SICK-030a),
    /// auch wenn das Stromende schon vom Gerät kam. Die reale
    /// `DarwinSerialPortFileDescriptor` schließt sich bei EOF zwar selbst,
    /// aber das ist ihre Eigenschaft, keine Zusage des Protokolls
    /// ``SerialPortFileDescriptor`` -- und auf genau dieser stillen
    /// Annahme stünde sonst die Portübergabe des Monitors. `close()` ist
    /// bei beiden Implementierungen mehrfach unschädlich.
    @discardableResult
    public func close() -> ReadResult {
        stream.close()
    }
}
