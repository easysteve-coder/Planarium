

/// Die **redigierte Kurzlage** der RX-Messsitzung, wie die
/// Verbindungsleiste sie braucht (SICK-0330b).
///
/// Bewusst ein eigener, geschlossener Wert statt `ScanSessionState`:
/// Die Leiste liest weder Profile noch Parserzähler noch
/// Transportfelder, sondern genau die Aussagen, die ihr Status zeigt --
/// Punktzahl und ob der Strom steht. Die Live-Rate bleibt separate Telemetrie. `message` ist der bereits
/// menschenlesbare, rohbytefreie Text aus `ScanSession.describe(_:)`.
public enum MeasurementSessionStatus: Equatable, Sendable {
    /// Keine RX-Sitzung.
    case idle
    /// Der Port wird für RX geöffnet; noch kein Profil.
    case opening(portPath: String)
    /// Der Port ist offen, aber es kam noch kein CRC-valides Profil --
    /// ein offener Port ist kein Betriebsbeleg.
    case openWithoutProfile(portPath: String)
    /// Mindestens ein CRC-valides Profil ist über diese Sitzung
    /// eingetroffen.
    case streaming(portPath: String, pointCount: Int)
    /// Die Sitzung ist unerwartet zu Ende oder ließ sich nicht öffnen.
    case failed(portPath: String, message: String)
    case simulation(SimulationSessionStatus)

    /// Die Kurzlage aus dem Sitzungszustand -- **eine reine Abbildung**,
    /// ohne `default`: Ein neuer Verbindungsstatus muss sich hier
    /// entscheiden.
    public static func describing(_ state: ScanSessionState) -> MeasurementSessionStatus {
        describing(connection: state.connection, pointCount: state.lastProfile?.measurements.count)
    }

    /// Streaming derives its summary from scalars; full evidence is not copied
    /// through the publication path merely to read these two fields.
    static func describing(connection: ConnectionStatus, pointCount: Int?) -> MeasurementSessionStatus {
        switch connection {
        case .disconnected:
            return .idle
        case .connecting(let portPath, _):
            return .opening(portPath: portPath)
        case .connected(let portPath, _):
            guard let pointCount else {
                return .openWithoutProfile(portPath: portPath)
            }
            return .streaming(
                portPath: portPath,
                pointCount: pointCount
            )
        case .failed(let portPath, _, let message):
            return .failed(portPath: portPath, message: message)
        case .simulationConnecting(let serviceName):
            return .simulation(.opening(serviceName: serviceName))
        case .simulationConnected(let serviceName):
            guard let pointCount else { return .simulation(.openWithoutProfile(serviceName: serviceName)) }
            return .simulation(.streaming(serviceName: serviceName, pointCount: pointCount))
        case .simulationFailed(let serviceName, let message):
            return .simulation(.failed(serviceName: serviceName, message: message))
        }
    }
}

public enum SimulationSessionStatus: Equatable, Sendable {
    case opening(serviceName: String)
    case openWithoutProfile(serviceName: String)
    case streaming(serviceName: String, pointCount: Int)
    case failed(serviceName: String, message: String)
}

/// Die aggregierten, rohbytefreien Zahlen der RX-Sitzung für die
/// Offline-Evidenzkarte (SICK-0330b) -- genau die Werte, die SICK-034
/// später abliest: Gesamtreads und `readsWithSeveralProfiles` stehen
/// ausdrücklich dabei.
public struct MeasurementStreamEvidence: Equatable, Sendable {
    public let profileRateHz: Double?
    public let status: MeasurementSessionStatus
    /// Lesevorgänge, die mindestens ein Profil an die Klangerzeugung
    /// lieferten.
    public let deliveredProfileBatches: Int
    /// Davon Lesevorgänge mit **mehr als einem** Profil -- die Zahl, an
    /// der SICK-034c hängt.
    public let readsWithSeveralProfiles: Int
    public let validFrames: Int
    public let discardedCandidates: Int
    public let discardedCandidatesOversize: Int
    public let discardedCandidatesChecksumMismatch: Int
    public let discardedCandidatesAtFinish: Int
    public let skippedNoiseBytes: Int

    public init(
        status: MeasurementSessionStatus,
        profileRateHz: Double? = nil,
        deliveredProfileBatches: Int,
        readsWithSeveralProfiles: Int,
        validFrames: Int,
        discardedCandidates: Int,
        discardedCandidatesOversize: Int,
        discardedCandidatesChecksumMismatch: Int,
        discardedCandidatesAtFinish: Int,
        skippedNoiseBytes: Int
    ) {
        self.status = status
        self.profileRateHz = profileRateHz
        self.deliveredProfileBatches = deliveredProfileBatches
        self.readsWithSeveralProfiles = readsWithSeveralProfiles
        self.validFrames = validFrames
        self.discardedCandidates = discardedCandidates
        self.discardedCandidatesOversize = discardedCandidatesOversize
        self.discardedCandidatesChecksumMismatch = discardedCandidatesChecksumMismatch
        self.discardedCandidatesAtFinish = discardedCandidatesAtFinish
        self.skippedNoiseBytes = skippedNoiseBytes
    }

    /// Ohne Sitzung: alles null, Status `idle`.
    public static let none = MeasurementStreamEvidence(
        status: .idle, deliveredProfileBatches: 0, readsWithSeveralProfiles: 0,
        validFrames: 0, discardedCandidates: 0, discardedCandidatesOversize: 0,
        discardedCandidatesChecksumMismatch: 0, discardedCandidatesAtFinish: 0, skippedNoiseBytes: 0
    )
}
