import Dispatch

/// Wo ein Einrichtungsschritt läuft und wo sein Bericht ankommt
/// (SICK-032a, Auflage E3).
///
/// ## Die zwei Zusagen
///
/// - ``runSerialized(_:)`` führt die übergebene Arbeit **außerhalb des
///   Main Threads** und **serialisiert** aus: Zwei Aufrufe überlappen
///   nie. `CommissioningExecutor.perform` ist synchron, blockierend und
///   nicht threadsicher (Review-Befund N5 zu SICK-031) — ein zweiter
///   Einstieg während eines laufenden Aufrufs ist undefiniert.
/// - ``deliverOnMain(_:)`` bringt den Bericht auf den Kontroll-Thread,
///   **bevor** irgendetwas am Bedienmodell oder am Portbesitz geschieht.
///   Das Bedienmodell führt `@Published`-Zustand und ruft
///   `completeCommissioning(with:)`; beides gehört auf den Main Thread.
///
/// **Injizierbar, damit die Nachweise ohne echten Timer und ohne
/// Wartezeit laufen** — die Reihenfolgeaussagen sind sonst nicht
/// deterministisch prüfbar.
public protocol CommissioningDispatching {
    func runSerialized(_ work: @escaping () -> Void)
    func deliverOnMain(_ work: @escaping () -> Void)
}

/// Die produktive Umsetzung: **eine** serielle Warteschlange und der
/// Main Thread.
///
/// **Verbindliche Regeln, bei künftigen Änderungen zu erhalten:**
///
/// - Die Warteschlange ist **seriell** (keine `attributes: .concurrent`)
///   und gehört genau dieser Instanz. Sie ist die Zusage „höchstens ein
///   `perform` gleichzeitig" auf Systemebene; das Bedienmodell sperrt
///   zusätzlich auf dem Main Thread, damit eine zweite Bedienhandlung
///   gar nicht erst in die Warteschlange gerät.
/// - ``deliverOnMain(_:)`` ist **immer asynchron**, auch vom Main Thread
///   aus. Die Abkürzung `if Thread.isMainThread { work() }` machte das
///   Verhalten vom aufrufenden Thread abhängig und öffnete Reentrancy —
///   dieselbe Lehre wie bei `MainQueueDispatcher` aus SICK-028.
public final class SerialCommissioningDispatcher: CommissioningDispatching {

    private let queue: DispatchQueue

    public init() {
        self.queue = DispatchQueue(label: "de.sick.pls.commissioning.run", qos: .userInitiated)
    }

    public func runSerialized(_ work: @escaping () -> Void) {
        let handoff = SerializedWork(run: work)
        queue.async { handoff.run() }
    }

    public func deliverOnMain(_ work: @escaping () -> Void) {
        let handoff = SerializedWork(run: work)
        DispatchQueue.main.async { handoff.run() }
    }
}

/// **`@unchecked Sendable`, begründet:** Die Closure läuft genau einmal
/// auf der seriellen Warteschlange bzw. dem Main Thread -- nie parallel.
struct SerializedWork: @unchecked Sendable {
    let run: () -> Void
}
