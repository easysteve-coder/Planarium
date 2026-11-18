import SickPLSMacTransport

/// Warum ein Transportschritt nicht ausgeführt werden konnte (SICK-031).
///
/// **Benannt statt `Bool`** — dieselbe Haltung wie
/// ``SerialPortOwnershipRefusal``: „es ist schon offen" und „es ist gar
/// nicht offen" verlangen verschiedene Handgriffe.
public enum CommissioningTransportError: Error, Equatable, Sendable {
    /// Ein zweites Öffnen, ohne dass vorher geschlossen wurde.
    ///
    /// **Der Grund, warum es diesen Fall gibt:** Beim Ratenwechsel der
    /// Diagnose (SICK-030a3) steht zwischen den beiden Proben ein
    /// ausdrückliches Schließen. Bliebe ein Öffnen ohne dieses Schließen
    /// erlaubt, spräche die zweite Probe womöglich noch über die alte
    /// Verbindung — genau der Fehler, den SICK-030a3 im Modell behoben
    /// hat. Hier steht dieselbe Regel für die Ausführung.
    case portAlreadyOpen
    /// Geschrieben oder gelesen werden soll auf einer Verbindung, die
    /// nicht offen ist.
    case portNotOpen
    /// Der Pfad liegt außerhalb von `/dev/cu.` (dieselbe Grenze wie
    /// `SickPLSSerialConnection.open` seit SICK-010 und `BaudProbe`).
    case pathNotAllowed(String)
    /// Das Öffnen selbst schlug fehl; die Meldung stammt aus der
    /// darunterliegenden Grenze und trägt **nie** Nutzdaten.
    case openFailed(String)
    /// Das Schreiben schlug fehl.
    case writeFailed(String)
}

/// Die schmale Grenze, über die der ``CommissioningExecutor`` mit einem
/// seriellen Port spricht (SICK-031).
///
/// ## Warum es sie gibt
///
/// Bis SICK-030a3 war das Commissioning ein reiner Wertreducer: Er
/// *sagte*, was zu tun wäre (``CommissioningDirective``), und niemand tat
/// es. Diese Grenze ist der **einzige** Ort, an dem Direktiven wirklich
/// ausgeführt werden — öffnen, schließen, Empfangspuffer leeren,
/// schreiben, lesen.
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// - **Fünf Mitglieder, mehr nicht.** Keine Baudratensuche, keine
///   Wiederholung, kein Timer, keine Zustandsmaschine. Wer hier eine
///   Methode ergänzt, verschiebt Ablauflogik aus dem geprüften Reducer
///   in eine zweite, ungeprüfte Stelle.
/// - **``read(timeoutMilliseconds:)`` wartet bei Stille in aller Regel
///   bis zum Ablauf dieser Zeitspanne** — das ist eine **Erläuterung,
///   keine Voraussetzung** (SICK-031a, Auflage E2). Eine Umsetzung
///   *darf* vorzeitig mit ``SerialPortReadOutcome/timeout`` zurückkehren,
///   und der reale Adapter tut das auch: `DarwinActiveControlSerialPort`
///   klassifiziert ein von einem Signal unterbrochenes `poll(2)`
///   (`EINTR`) als `.timeout`. Der Executor übergibt deshalb zwar immer
///   die **gesamte Restfrist**, wertet ein `.timeout` aber **nie** als
///   Fristende, sondern rechnet die Restfrist neu; die Frist ist
///   ausschließlich die absolute, monotone Grenze des Reducers.
/// - **``flushReceiveBuffer()`` wirft nicht und meldet nichts.** Sie ist
///   eine Vorbereitung, kein Protokollschritt: Was sie wegwirft, ist
///   definitionsgemäß alles, was **vor** unserer Sendung ankam, und
///   damit keine Antwort darauf.
public protocol CommissioningTransport: AnyObject {

    /// Öffnet den Port bei **genau** dieser Rate.
    ///
    /// Ein zweites Öffnen ohne vorheriges ``closePort()`` ist ein Fehler
    /// (``CommissioningTransportError/portAlreadyOpen``), keine stille
    /// Wiederverwendung.
    func openPort(baudRate: SerialPortBaudRate) throws

    /// Schließt eine offene Verbindung. **Idempotent:** Ist nichts
    /// offen, passiert nichts und es wird nicht geworfen.
    func closePort() throws

    /// Leert den Empfangspuffer. Wird **vor jeder** Sendung gerufen und
    /// nie danach.
    func flushReceiveBuffer()

    /// Schreibt die Bytes vollständig oder wirft.
    func write(_ bytes: [UInt8]) throws

    /// Liest höchstens bis `timeoutMilliseconds`.
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome
}
