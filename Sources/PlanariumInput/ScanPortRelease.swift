import SickPLSMacTransport

/// Die Meldung „dieser Monitor hält den seriellen Port nicht mehr"
/// (SICK-030a, Auflage **A3** aus `review-sick-030-architecture.md`).
///
/// ## Warum es sie gibt
///
/// `ScanSession.disconnect()` kehrt **sofort** zurück; das `close(2)`
/// passiert später auf dem Lesethread — so gebaut seit SICK-012, damit
/// nie zwei Threads denselben Deskriptor anfassen. Für die Anzeige war
/// das nie ein Problem. Für eine **Portübergabe** ist es eines: Ein
/// unmittelbar nach dem Trennen gestarteter Konfigurationsablauf würde
/// denselben Pfad öffnen, während der alte Deskriptor womöglich noch
/// offen ist. Und ob macOS ein zweites Öffnen desselben `/dev/cu.*`
/// ablehnt, ist in diesem Projekt **nie verifiziert** worden — eine
/// Betriebssystemsperre wäre Sicherheitsnetz, nicht Mechanismus.
///
/// ## Was hier bewusst nicht drinsteht
///
/// **Keine Frames, keine Bytes, keine `Date`.** Dieselbe Haltung wie
/// ``ScanProfileBatch`` (SICK-029): Die Empfangszeit ist Wanduhrzeit und
/// bleibt Monitorzustand; ein Besitzmodell braucht sie nicht.
public struct ScanPortRelease: Equatable, Sendable {
    public let endpoint: ScanInputEndpoint
    /// Der Pfad, der freigegeben wurde — damit ein Anspruchsteller
    /// prüfen kann, ob es *sein* Port ist.
    public let portPath: String
    /// Die Rate, mit der diese Verbindung lief. Rein informativ; die
    /// Rate der nächsten Verbindung entscheidet das Besitzmodell.
    public let baudRate: SerialPortBaudRate

    public init(endpoint: ScanInputEndpoint) {
        self.endpoint = endpoint
        switch endpoint {
        case .serialPort(let path, let rate): portPath = path; baudRate = rate
        case .simulation: portPath = ""; baudRate = .baud38400
        }
    }

    init(portPath: String, baudRate: SerialPortBaudRate) {
        self.init(endpoint: .serialPort(path: portPath, baudRate: baudRate))
    }
}
