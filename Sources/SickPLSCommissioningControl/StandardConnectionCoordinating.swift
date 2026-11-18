import Combine
import SickPLSMacTransport
import PlanariumInput

/// Die Koordinatorsicht der **Verbindungsleiste** (SICK-0330b).
///
/// ## Was hier gegenüber ``CommissioningPortCoordinating`` hinzukommt
///
/// Der manuelle Einrichtungspfad (SICK-032a) darf den Monitor bewusst
/// **nicht** selbst verbinden. Der Standardweg muss es: Er ist genau der
/// Ablauf, der einen belegten TX-Erfolg in eine RX-Messsitzung überführt.
/// Deshalb stehen hier -- und nur hier -- die bereits abgenommenen
/// Monitor-Grenzen `connect`/`disconnect` des
/// ``InputOwner`` (SICK-030a1) sowie die redigierte
/// Sitzungslage. **Es wird nichts Neues erfunden**, die Konformität
/// unten fügt kein Verhalten hinzu.
///
/// ## Die Reihenfolge, die dieses Protokoll trägt
///
/// 1. `requestCommissioningAccess()` -- der Standardlauf hält den Port
///    unter dem **Commissioning-Besitz** (er ist TX-fähig).
/// 2. `finishCommissioning(verifiedBaudRate:)` -- erst nach einem Bericht
///    mit `isPortHeld == false`, also nach dem **wirklichen** Schluss.
/// 3. `connect(portPath:baudRate:)` -- der RX-Anspruch. Das Besitzmodell
///    verweigert ihn strukturell, solange Schritt 2 fehlt.
public protocol StandardConnectionCoordinating: CommissioningPortCoordinating {
    /// Startet die RX-Messsitzung -- **erst beanspruchen, dann öffnen**
    /// (SICK-030a1).
    @discardableResult
    func connect(portPath: String, baudRate: SerialPortBaudRate) -> MonitorConnectOutcome

    /// Expliziter Entwicklungsweg mit der gerade real belegten Rate. Auch
    /// dieser Weg bleibt hinter dem einen Verbindungsmodell der App.
    @discardableResult
    func connectDevelopment(portPath: String, baudRate: SerialPortBaudRate) -> MonitorConnectOutcome

    /// Trennt die RX-Messsitzung. Das echte Schließen folgt später auf
    /// dem Lesethread; bis zum `portReleased` bleibt der Port vergeben.
    func disconnect()

    /// Gibt den Commissioning-Besitz frei; `verifiedBaudRate` nur, wenn
    /// die Rate wirklich belegt ist.
    func finishCommissioning(verifiedBaudRate: SerialPortBaudRate?)

    /// Die redigierte Kurzlage der RX-Sitzung.
    var measurementSessionStatus: MeasurementSessionStatus { get }

    /// Änderungen der Kurzlage -- **nur zum Beobachten**.
    var measurementSessionStatusChanges: AnyPublisher<MeasurementSessionStatus, Never> { get }

    /// Die aggregierten Zahlen der RX-Sitzung für die Evidenzkarte.
    var measurementStreamEvidence: MeasurementStreamEvidence { get }

    /// Die fertige Kennzahlenzeile der Referenzmessung, genau wie die Karte
    /// sie zeigt. Der Evidenztext soll sie mitnehmen, ohne die Messtypen zu
    /// kennen; einzelne Rohwerte verlassen den Messtyp weiterhin nicht.
    var referenceMeasurementLine: String { get }
}

extension InputOwner: @preconcurrency StandardConnectionCoordinating {}
