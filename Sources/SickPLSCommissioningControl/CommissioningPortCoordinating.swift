import Combine
import SickPLSCommissioning
import SickPLSMacTransport
import PlanariumInput

/// Die Portsicht des Bedienmodells (SICK-032a, Bedienvertrag Punkt 5).
///
/// **Vier Mitglieder, alle bereits abgenommen.** Portpfad- und
/// Besitzbereitschaft kommen ausschließlich aus
/// ``InputOwner`` (SICK-030a1/031); dieses Protokoll
/// erfindet nichts dazu, es macht den bestehenden Weg nur
/// **injizierbar**.
///
/// **Warum eine Naht und kein direkter Typ:** Ein echter
/// `InputOwner` erzeugt einen
/// `ThereminPerformanceController` und damit eine `ThereminAudioEngine`.
/// Die Nachweise dieses Slices sollen ohne Audiodienst und ohne
/// Audiogerät laufen; sie fahren deshalb einen Spion. Der produktive Weg
/// bleibt derselbe — die Konformität steht unten und fügt **kein**
/// Verhalten hinzu.
///
/// **Was hier bewusst fehlt:** `ScanSession`, `connect`, `disconnect`,
/// jede serielle API. Das Bedienmodell darf den Monitor nicht selbst
/// trennen — das tut ``requestCommissioningAccess()`` kontrolliert und an
/// genau einer Stelle.
public protocol CommissioningPortCoordinating: AnyObject {
    /// Ob ein Lauf beginnen dürfte — **führt nichts aus**.
    func commissioningRunReadiness(portPath: String) -> CommissioningRunReadiness
    /// Fordert den Portbesitz an; trennt den Monitor höchstens
    /// **kontrolliert** und wartet die echte Freigabe ab.
    @discardableResult
    func requestCommissioningAccess() -> CommissioningAccessOutcome
    /// Gibt den Besitz **genau einmal** frei, und nur bei einem
    /// Endbericht.
    @discardableResult
    func completeCommissioning(with report: CommissioningStepReport) -> CommissioningCompletionOutcome
    /// Wer den Port gerade hält.
    var portOwner: SerialPortOwner { get }
    /// Ob das tatsächliche Schließen noch aussteht.
    var isAwaitingPortRelease: Bool { get }
    /// Besitzwechsel — **nur zum Beobachten**.
    ///
    /// Die Wartephase nach einem kontrollierten Trennen endet erst mit
    /// dem echten `portReleased`-Ereignis (SICK-030a). Ohne diese
    /// Meldung müsste die Bedienung entweder pollen (ein Timer, den der
    /// Auftrag verbietet) oder den Bedienenden blind erneut drücken
    /// lassen.
    ///
    /// **Sie löst nichts aus.** Das Bedienmodell aktualisiert daraufhin
    /// ausschließlich seine Anzeige; ein eigener Nachweis belegt, dass
    /// ein Besitzwechsel keine Sendung erzeugt.
    var portOwnershipChanges: AnyPublisher<SerialPortOwner, Never> { get }
}

extension InputOwner: @preconcurrency CommissioningPortCoordinating {
    public var portOwnershipChanges: AnyPublisher<SerialPortOwner, Never> {
        $portOwner.eraseToAnyPublisher()
    }
}
