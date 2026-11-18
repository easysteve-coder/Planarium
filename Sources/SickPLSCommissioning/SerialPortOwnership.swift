import SickPLSMacTransport

/// Wer den seriellen Port gerade besitzt (SICK-030a, Auflage **A3**).
public enum SerialPortOwner: Equatable, Sendable {
    case free
    case monitor
    case simulation
    case commissioning
    case simulationControl
}

/// Das Ergebnis eines Besitzanspruchs (SICK-030a).
///
/// **Bewusst ein eigener Typ statt `Result<Void, …>`**: Ein Anspruch hat
/// genau zwei Ausgänge, und der erfolgreiche trägt keinen Wert — ein
/// `Result<Void, …>` wäre weder vergleichbar noch aussagekräftiger.
public enum SerialPortClaimOutcome: Equatable, Sendable {
    case granted
    case refused(SerialPortOwnershipRefusal)
}

/// Warum ein Zugriff verweigert wurde (SICK-030a).
///
/// **Benannt statt `false`**: „Ein anderer hält den Port" und „der Port
/// wird gerade noch geschlossen" sind für den Bedienenden zwei
/// verschiedene Lagen — die eine verlangt eine Entscheidung, die andere
/// nur einen Augenblick Geduld.
public enum SerialPortOwnershipRefusal: Equatable, Sendable, Error {
    case heldByMonitor
    case heldBySimulation
    case heldByCommissioning
    case heldBySimulationControl
    /// Der Monitor wurde bereits getrennt, das **tatsächliche**
    /// Schließen steht aber noch aus.
    case awaitingRelease
}

/// Das strukturelle Besitzmodell des seriellen Ports (SICK-030a,
/// Auflage **A3**).
///
/// ## Warum es das gibt
///
/// „Nur einer darf den Port haben" war bisher eine Regel, kein
/// Mechanismus — und sie war nicht durchsetzbar, aus zwei Gründen:
///
/// 1. **`ScanSession.disconnect()` kehrt sofort zurück.** Den
///    Dateideskriptor schließt der Hintergrund-Thread, später. Ein
///    unmittelbar danach gestartetes Commissioning öffnete denselben
///    Pfad, während der alte Deskriptor noch offen sein konnte.
/// 2. **Eine Betriebssystemsperre ist im Projekt nicht verifiziert.**
///    Ob macOS ein zweites Öffnen desselben `/dev/cu.*` ablehnt, ist
///    hier nie geprüft worden; `EBUSY` bleibt deshalb **Sicherheitsnetz,
///    nicht Mechanismus.**
///
/// Deshalb hängt der Übergang „Monitor → frei" an einem **ausdrücklichen
/// Freigabesignal**, das `ScanSession` erst nach dem tatsächlichen
/// `close()` sendet (`ScanSession.portReleased`, SICK-030a).
///
/// ## Zwei Regeln, die bei künftigen Änderungen zu erhalten sind
///
/// - **Ein zweiter gleichzeitiger Besitzer ist im Modell unmöglich.**
///   Jeder Anspruch wird gegen den aktuellen Besitzer geprüft und
///   sichtbar verweigert — nie still überschrieben.
/// - **Nach belegter Verifikation verbindet der Monitor mit der
///   verifizierten Rate**, nicht mit einer Nutzereingabe. Sonst hätte
///   der Ablauf die Rate gerade bewiesen, und die Oberfläche riete
///   daneben.
///
/// Reiner Wert: keine Uhr, kein Port, kein Thread — dasselbe Muster wie
/// `ScanSessionState` und `ThereminRoleAssignmentState`.
public struct SerialPortOwnership: Equatable, Sendable {
    public private(set) var owner: SerialPortOwner = .free
    /// Der Monitor wurde getrennt, das tatsächliche Schließen steht noch
    /// aus. **Solange das gilt, bekommt niemand den Port.**
    public private(set) var isAwaitingRelease = false
    /// Die durch einen abgeschlossenen Ablauf belegte Rate.
    public private(set) var verifiedBaudRate: SerialPortBaudRate?
    /// Generation der gehaltenen Steuersitzung; `nil`, solange keine gehalten wird.
    public private(set) var simulationControlGeneration: SimulationControlGeneration?
    /// Monotone Sitzungsnummer; sie wird auch nach der Freigabe nicht zurückgesetzt.
    private var nextSimulationControlGeneration: UInt64 = 0

    public init() {}

    /// Die Rate, mit der der Monitor als Nächstes verbinden soll:
    /// bevorzugt die verifizierte, sonst die vom Bedienenden gewählte.
    public func monitorConnectBaudRate(requested: SerialPortBaudRate) -> SerialPortBaudRate {
        verifiedBaudRate ?? requested
    }

    // MARK: - Monitor

    @discardableResult
    public mutating func claimForMonitor() -> SerialPortClaimOutcome {
        if isAwaitingRelease { return .refused(.awaitingRelease) }
        switch owner {
        case .free:
            owner = .monitor
            return .granted
        case .monitor:
            // Schon unser Port -- kein Fehler, aber auch keine zweite
            // Verbindung.
            return .granted
        case .simulation:
            return .refused(.heldBySimulation)
        case .commissioning:
            return .refused(.heldByCommissioning)
        case .simulationControl:
            return .refused(.heldBySimulationControl)
        }
    }

    /// Der Monitor wurde getrennt. **Der Port ist damit noch nicht
    /// frei** — erst ``notePortReleased()`` gibt ihn frei.
    public mutating func noteMonitorDisconnectRequested() {
        guard owner == .monitor || owner == .simulation else { return }
        isAwaitingRelease = true
    }

    /// Das Freigabesignal der `ScanSession` ist eingetroffen: Der
    /// Deskriptor ist **tatsächlich** geschlossen.
    ///
    /// Mehrfacher Aufruf ist unschädlich; ein Signal, während das
    /// Commissioning den Port hält, wird ignoriert (es gehörte zu einer
    /// früheren Monitorverbindung).
    public mutating func notePortReleased() {
        guard owner == .monitor || owner == .simulation else {
            isAwaitingRelease = false
            return
        }
        owner = .free
        isAwaitingRelease = false
    }

    // MARK: - Commissioning

    @discardableResult
    public mutating func claimForCommissioning() -> SerialPortClaimOutcome {
        if isAwaitingRelease { return .refused(.awaitingRelease) }
        switch owner {
        case .free:
            owner = .commissioning
            return .granted
        case .monitor:
            return .refused(.heldByMonitor)
        case .simulation:
            return .refused(.heldBySimulation)
        case .commissioning:
            return .granted
        case .simulationControl:
            return .refused(.heldBySimulationControl)
        }
    }

    @discardableResult
    public mutating func claimForSimulation() -> SerialPortClaimOutcome {
        if isAwaitingRelease { return .refused(.awaitingRelease) }
        switch owner {
        case .free, .simulation:
            owner = .simulation
            return .granted
        case .monitor:
            return .refused(.heldByMonitor)
        case .commissioning:
            return .refused(.heldByCommissioning)
        case .simulationControl:
            return .refused(.heldBySimulationControl)
        }
    }

    /// Der Ablauf ist zu Ende. `verifiedBaudRate` merkt sich eine
    /// belegte Rate; ein Fehlschlag übergibt `nil` und lässt eine früher
    /// belegte Rate unangetastet.
    public mutating func releaseCommissioning(verifiedBaudRate: SerialPortBaudRate? = nil) {
        guard owner == .commissioning else { return }
        if let verifiedBaudRate { self.verifiedBaudRate = verifiedBaudRate }
        owner = .free
        isAwaitingRelease = false
    }

    // MARK: - Simulations-Steuersitzung (SIM-P2a)

    @discardableResult
    public mutating func claimForSimulationControl() -> SerialPortClaimOutcome {
        if isAwaitingRelease { return .refused(.awaitingRelease) }
        switch owner {
        case .free:
            nextSimulationControlGeneration &+= 1
            simulationControlGeneration = SimulationControlGeneration(nextSimulationControlGeneration)
            owner = .simulationControl
            return .granted
        case .monitor:
            return .refused(.heldByMonitor)
        case .simulation:
            return .refused(.heldBySimulation)
        case .commissioning:
            return .refused(.heldByCommissioning)
        case .simulationControl:
            return .refused(.heldBySimulationControl)
        }
    }

    @discardableResult
    public mutating func releaseSimulationControl(
        _ completion: SimulationControlCompletion
    ) -> SimulationControlReleaseOutcome {
        guard owner == .simulationControl else { return .notHolding }
        guard simulationControlGeneration == completion.generation else {
            return .staleGeneration
        }
        switch completion.closeStatus {
        case .closeFailed:
            return .stillBlocked
        case .closed:
            owner = .free
            isAwaitingRelease = false
            simulationControlGeneration = nil
            return .released
        }
    }
}
