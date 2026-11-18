import SickPLSCommissioning
import SickPLSMacTransport

/// Das Ergebnis eines **Monitor**-Verbindungsversuchs über den
/// Koordinator (SICK-030a1).
///
/// **Typisiert statt `Void`**: Ein abgelehnter Verbindungsversuch sieht
/// von außen sonst genauso aus wie ein erfolgreicher, und eine
/// Oberfläche, die nichts davon erfährt, zeigt weiter „nicht
/// verbunden" ohne Grund.
///
/// Der mitgelieferte `baudRate` ist die **tatsächlich verwendete** Rate
/// — nach einer belegten Verifikation ist das die verifizierte, nicht
/// die im Bedienfeld gewählte.
public enum MonitorConnectOutcome: Equatable {
    case connecting(baudRate: SerialPortBaudRate)
    case refused(SerialPortOwnershipRefusal)
}

public enum SimulationConnectOutcome: Equatable {
    case connecting
    case refused(SerialPortOwnershipRefusal)
}

/// Das Ergebnis einer **Commissioning**-Anforderung (SICK-030a1).
///
/// Die Grenze ist bewusst **I/O-frei**: Sie vergibt nur den Besitz.
/// Öffnen, Senden und Fristen entstehen erst in SICK-031.
/// Ergebnis einer Anfrage nach einer Simulations-Steuersitzung (SIM-P2a).
public enum SimulationControlAccessOutcome: Equatable {
    case granted(SimulationControlLease)
    /// Simulations-RX wird kontrolliert getrennt; nach der echten Freigabe
    /// erneut anfragen.
    case awaitingRelease
    case refused(SerialPortOwnershipRefusal)
}

public enum CommissioningAccessOutcome: Equatable {
    /// Der Port gehört jetzt dem Commissioning.
    case granted
    /// Der Monitor hielt den Port; sein **kontrolliertes** Trennen wurde
    /// veranlasst. Der Besitz wechselt erst mit dem echten
    /// `portReleased`-Ereignis — **hier wird nichts erzwungen und nichts
    /// abgewartet**, der Aufrufer fragt danach erneut.
    case awaitingMonitorRelease
    /// Es hält jemand anderes, und auch ein Trennen hilft nicht.
    case refused(SerialPortOwnershipRefusal)
}

/// Ob ein Einrichtungslauf **beginnen dürfte** (SICK-031, vorbereitet für
/// SICK-032).
///
/// **Diese Auskunft führt nichts aus.** Sie beantwortet genau eine Frage,
/// damit eine spätere Oberfläche den Knopf begründet sperren kann, statt
/// den Bedienenden in eine Verweigerung laufen zu lassen.
public enum CommissioningRunReadiness: Equatable {
    /// Der Port ist frei oder gehört bereits dem Commissioning.
    case ready
    /// Der Monitor hält den Port. Erst ``InputOwner/disconnect()``
    /// oder ``InputOwner/requestCommissioningAccess()``,
    /// dann das echte Freigabe-Ereignis abwarten.
    case monitorMustDisconnectFirst
    case simulationMustDisconnectFirst
    /// Eine Simulations-Steuersitzung läuft oder ist nach gescheitertem
    /// Schließen gesperrt (SIM-P2a).
    case simulationControlMustFinishFirst
    /// Getrennt, aber das **tatsächliche** Schließen steht noch aus.
    case awaitingPortRelease
    /// Ohne ausgewählten Port gibt es nichts zu öffnen.
    case noPortSelected
    /// Der Pfad liegt außerhalb von `/dev/cu.` — dieselbe Grenze wie im
    /// Transport, hier nur **vorab** beantwortet.
    case portPathNotAllowed
}

/// Was beim Abschluss eines Einrichtungslaufs mit dem Portbesitz geschah
/// (SICK-031).
///
/// **Genau einmal freigeben** ist die Regel; dieser Typ macht sichtbar,
/// ob das gerade passiert ist oder ob jemand ein zweites Mal gerufen hat.
public enum CommissioningCompletionOutcome: Equatable {
    /// Freigegeben. `verifiedBaudRate` ist gesetzt, **wenn und nur wenn**
    /// der Lauf eine CRC-valide Identitätsantwort bei der Zielrate
    /// gesehen hat (Auflage A1).
    case released(verifiedBaudRate: SerialPortBaudRate?)
    /// Der Bericht ist kein Endstand — der Ablauf ruht mit gehaltenem
    /// Port und kann weitergehen. **Es wurde nichts freigegeben.**
    case stillRunning
    /// Das Commissioning hält den Port gar nicht (mehr). Ein zweiter
    /// Abschlussaufruf landet hier, statt still ein zweites Mal
    /// freizugeben.
    case notHoldingPort
}

/// Eine kurze, im **Modell** formulierte Rückmeldung zum Portzugriff
/// (SICK-030a1, Muster wie `PerformanceNotice` aus SICK-028).
///
/// **Der Text entsteht hier und nicht in der Ansicht** — sonst hinge er
/// an einer SwiftUI-Datei ohne Testziel.
public struct PortAccessNotice: Equatable {
    public let message: String

    init(_ message: String) {
        self.message = message
    }

    static func describing(_ refusal: SerialPortOwnershipRefusal) -> PortAccessNotice {
        switch refusal {
        case .heldByMonitor:
            return PortAccessNotice("The monitor holds the port. Disconnect first.")
        case .heldByCommissioning:
            return PortAccessNotice("Commissioning holds the port. Finish first.")
        case .heldBySimulation:
            return PortAccessNotice("The iPhone simulation holds the port. Disconnect first.")
        case .heldBySimulationControl:
            return PortAccessNotice("The simulation is switching. One moment.")
        case .awaitingRelease:
            return PortAccessNotice("The port is closing. One moment.")
        }
    }
}
