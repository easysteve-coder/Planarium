/// Transportfreie Typen der Simulations-Steuersitzung (SIM-P2a).
///
/// Eine Steuersitzung sendet typisierte Aufträge an die iPhone-Simulation.
/// Sie läuft unter demselben Besitzmodell wie Hardware-RX, Simulations-RX
/// und Commissioning (``SerialPortOwnership``), damit nie zwei Wege
/// gleichzeitig eine Verbindung halten.
///
/// Hier steht **keine** Netzwerk- und keine Seriell-API. Eine TCP-Adresse
/// wird nie als `portPath` weitergereicht, und eine Simulation belegt nie
/// eine reale Baudrate.

/// Ein geprüftes Simulationsziel: stabile Dienstidentität plus aufgelöstes
/// Netzwerkziel. Nur über ``make(serviceID:host:port:)`` erzeugbar.
public struct SimulationEndpoint: Equatable, Hashable, Sendable {
    /// Stabile Bonjour-Identität („Name|Typ|Domain").
    public let serviceID: String
    public let host: String
    public let port: UInt16

    private init(serviceID: String, host: String, port: UInt16) {
        self.serviceID = serviceID
        self.host = host
        self.port = port
    }

    /// `nil` bei leerer Identität, leerem Host, Port 0 oder einem Host, der
    /// wie ein Gerätepfad aussieht (`/`-Präfix).
    public static func make(serviceID: String, host: String, port: UInt16) -> SimulationEndpoint? {
        guard !serviceID.isEmpty, !host.isEmpty, !host.hasPrefix("/"), port != 0 else { return nil }
        return SimulationEndpoint(serviceID: serviceID, host: host, port: port)
    }
}

/// Der Messmodus, den die Simulation einnehmen soll. Genau die zwei
/// belegten Modi; kein frei programmierbares Telegramm.
public enum SimulationMeasurementMode: Equatable, Sendable {
    case fullScan
    case minimumPerSegment
}

/// Ein typisierter Steuerauftrag.
public enum SimulationControlJob: Equatable, Sendable {
    case setMeasurementMode(SimulationMeasurementMode)
}

/// Fortlaufende Nummer einer Steuersitzung. Eine Completion wirkt nur,
/// wenn ihre Generation die aktuell gehaltene ist.
public struct SimulationControlGeneration: Equatable, Hashable, Comparable, Sendable {
    public let value: UInt64

    public init(_ value: UInt64) { self.value = value }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// Der erteilte Besitz einer Steuersitzung.
public struct SimulationControlLease: Equatable, Sendable {
    public let endpoint: SimulationEndpoint
    public let generation: SimulationControlGeneration
    public let job: SimulationControlJob

    public init(endpoint: SimulationEndpoint, generation: SimulationControlGeneration, job: SimulationControlJob) {
        self.endpoint = endpoint
        self.generation = generation
        self.job = job
    }
}

/// Wie die Verbindung der Steuersitzung tatsächlich endete.
public enum SimulationControlCloseStatus: Equatable, Sendable {
    /// Verbindung terminal; keine weiteren Sendungen oder Lieferungen dieser
    /// Generation möglich.
    case closed
    /// Schließen ist gescheitert oder nicht fristgerecht bestätigt. Der Besitz
    /// bleibt gesperrt.
    case closeFailed
}

/// Wie der Auftrag selbst ausging. Ein ACK heißt nur „Kommando bestätigt",
/// nicht „Modus im Strom verifiziert".
public enum SimulationControlJobResult: Equatable, Sendable {
    case acknowledged
    case rejected
    case timedOut
    case transportFailed
}

/// Abschluss einer Steuersitzung. Trägt Herkunft über den Typ, Generation und
/// den tatsächlichen Schließstatus, aber **keine** Baudrate.
public struct SimulationControlCompletion: Equatable, Sendable {
    public let generation: SimulationControlGeneration
    public let job: SimulationControlJob
    public let result: SimulationControlJobResult
    public let closeStatus: SimulationControlCloseStatus

    public init(
        generation: SimulationControlGeneration,
        job: SimulationControlJob,
        result: SimulationControlJobResult,
        closeStatus: SimulationControlCloseStatus
    ) {
        self.generation = generation
        self.job = job
        self.result = result
        self.closeStatus = closeStatus
    }
}

/// Wirkung einer Completion auf das Besitzmodell.
public enum SimulationControlReleaseOutcome: Equatable, Sendable {
    /// Genau ein Besitzwechsel zu `.free`.
    case released
    /// Schließen nicht bestätigt: Besitz bleibt gesperrt.
    case stillBlocked
    /// Falsche oder alte Generation: wirkungslos.
    case staleGeneration
    /// Die Steuersitzung hält den Port nicht (mehr): wirkungslos.
    case notHolding
}
