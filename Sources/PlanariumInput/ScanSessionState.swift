import struct Foundation.Date
import SickPLSCore
import SickPLSMacTransport
import PlanariumDomain

/// R supplies cumulative rejection counts even when Main coalesces read batches.
public struct ProfileGeometryDiagnostic: Equatable, Sendable {
    public var geometry: ProfileGeometryIdentity?
    public var unsupportedProfiles: UInt64 = 0
    public var rejectedPointCount: Int?
    public var rejectedPartialScanIndex: UInt8?
    public init() {}
}

/// Verbindungsstatus einer ``ScanSession`` -- immer explizit, nie eine
/// automatische Verbindung (SICK-012-Auftrag). Jeder Zustand außer
/// ``disconnected`` trägt Port/Baudrate, damit die Ansicht ohne
/// Zusatzzustand weiß, wozu ein Verbindungs-/Fehlerzustand gehört.
public enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting(portPath: String, baudRate: SerialPortBaudRate)
    case connected(portPath: String, baudRate: SerialPortBaudRate)
    case simulationConnecting(serviceName: String)
    case simulationConnected(serviceName: String)
    /// `message` ist bereits eine menschenlesbare Beschreibung ohne
    /// Rohbytes oder Secrets (siehe `ScanSession.describe(_:)`), niemals
    /// ein roher Fehlercode oder Payload.
    case failed(portPath: String, baudRate: SerialPortBaudRate, message: String)
    case simulationFailed(serviceName: String, message: String)
}

/// Reiner, unveränderlicher Zustandswert einer ``ScanSession`` --
/// vollständig unabhängig von SwiftUI, Threading oder echtem Transport,
/// damit Zustandsübergänge, Diagnoseweitergabe und Geometrie/Skalierung
/// ohne Hintergrund-Thread oder physisches Gerät testbar sind
/// (SICK-012-Auftrag: „ein testbarer ScanSession-/ViewModel-Rand trennt
/// Transport, Zustandsmodell und SwiftUI-Ansicht").
///
/// Jede `applying...`-Methode ist eine reine Funktion (alter Zustand +
/// Ereignis -> neuer Zustand), keine hat einen Seiteneffekt oder liest
/// die Systemzeit selbst -- Zeitstempel kommen immer als Parameter vom
/// Aufrufer (analog zur injizierbaren `MonotonicClock` aus SICK-011a).
public struct ScanSessionState: Equatable, Sendable {
    /// Wie viele zuletzt empfangene, valide B0-Profil-Zeitstempel für die
    /// rollierende Ratenberechnung vorgehalten werden.
    static let rateWindowCount = 8

    public var connection: ConnectionStatus = .disconnected
    /// Fortlaufender Diagnostikstand des aktuell verwendeten `StreamParser`
    /// (siehe `StreamParser.Diagnostics`) -- valide/verworfene Frames,
    /// übersprungene Rauschbytes. Wird bei jedem neuen ``applyingConnecting``
    /// zurückgesetzt, weil eine neue Verbindung einen neuen Parser bekommt.
    public var diagnostics = StreamParser.Diagnostics()
    public var profileGeometry = ProfileGeometryDiagnostic()
    /// Das zuletzt empfangene, bereits CRC-valide und B0-decodierte Profil
    /// -- `nil`, solange noch keines eingetroffen ist (leerer Zustand,
    /// SICK-012-Auftrag Punkt 7).
    public var lastProfile: B0ScanProfile?
    public var lastProfileReceivedAt: Date?
    /// Rollierende Profilrate in Hz über die letzten
    /// ``rateWindowCount`` empfangenen Profile -- `nil`, solange weniger
    /// als zwei Profile vorliegen, um daraus eine Rate zu bilden.
    public var profileRateHz: Double?
    /// Ausgelassene Status-/Anzeigepublikationen auf Main. Der Klangpfad
    /// erhält unabhängig davon jedes Profil auf R → Q.
    public var skippedProfiles = 0

    private var recentProfileTimestamps: [Date] = []

    public init() {}

    private init(connection: ConnectionStatus) {
        self.connection = connection
    }

    // MARK: - Übergänge

    /// Ein neuer, expliziter Verbindungsversuch beginnt -- setzt den
    /// gesamten Zustand bewusst zurück (neuer `StreamParser`, kein
    /// „altes" Profil aus einer vorherigen Verbindung bleibt sichtbar
    /// stehen und suggeriert Aktualität, die nicht mehr besteht).
    public static func applyingConnecting(portPath: String, baudRate: SerialPortBaudRate) -> ScanSessionState {
        ScanSessionState(connection: .connecting(portPath: portPath, baudRate: baudRate))
    }

    public func applyingConnected(portPath: String, baudRate: SerialPortBaudRate) -> ScanSessionState {
        var copy = self
        copy.connection = .connected(portPath: portPath, baudRate: baudRate)
        return copy
    }

    public static func applyingSimulationConnecting(serviceName: String) -> ScanSessionState {
        ScanSessionState(connection: .simulationConnecting(serviceName: serviceName))
    }

    public func applyingSimulationConnected(serviceName: String) -> ScanSessionState {
        var copy = self
        copy.connection = .simulationConnected(serviceName: serviceName)
        return copy
    }

    public func applyingSimulationFailure(serviceName: String, message: String) -> ScanSessionState {
        var copy = self
        copy.connection = .simulationFailed(serviceName: serviceName, message: message)
        return copy
    }

    /// `message` muss bereits menschenlesbar und ohne Rohbytes/Secrets
    /// sein (siehe ``ConnectionStatus/failed(portPath:baudRate:message:)``).
    public func applyingConnectFailure(portPath: String, baudRate: SerialPortBaudRate, message: String) -> ScanSessionState {
        var copy = self
        copy.connection = .failed(portPath: portPath, baudRate: baudRate, message: message)
        return copy
    }

    /// Neue Frames aus einem Leseversuch -- aktualisiert die Diagnostik
    /// immer, versucht jeden Frame als B0-Profil zu decodieren (ein
    /// Decodierfehler, etwa ein unerwartetes Kommandobyte, wird bewusst
    /// still ignoriert statt den gesamten Zustand mit einem Fehler zu
    /// überschreiben -- die Diagnostik allein macht so etwas sichtbar,
    /// siehe `StreamParser.Diagnostics`).
    public func applyingFrames(_ frames: [Frame], diagnostics: StreamParser.Diagnostics, receivedAt: Date) -> ScanSessionState {
        applyingProfiles(
            Self.decodedProfiles(in: frames), diagnostics: diagnostics, receivedAt: receivedAt
        )
    }

    /// Dieselbe Zustandsfortschreibung mit **bereits decodierten**
    /// Profilen (SICK-029).
    ///
    /// **Warum es diese zweite Tür gibt:** `ScanSession` braucht die
    /// decodierten Profile seit SICK-029 selbst, um daraus das
    /// Performance-Ereignis zu bilden. Würde sie hier ein zweites Mal
    /// decodieren, gäbe es zwei Stellen, die entscheiden, was in einem
    /// Lesevorgang ein gültiges B0-Profil ist — und die könnten
    /// auseinanderlaufen. Stattdessen decodiert die Sitzung **einmal**
    /// über ``decodedProfiles(in:)`` und reicht das Ergebnis hierher
    /// weiter.
    ///
    /// ``applyingFrames(_:diagnostics:receivedAt:)`` bleibt unverändert
    /// gültig und ist nur noch ein Aufruf dieser Methode.
    public func applyingProfiles(
        _ profiles: [B0ScanProfile],
        diagnostics: StreamParser.Diagnostics,
        receivedAt: Date,
        skippedProfiles: Int = 0
    ) -> ScanSessionState {
        var copy = self
        copy.ingestProfiles(profiles, diagnostics: diagnostics, receivedAt: receivedAt, skippedProfiles: skippedProfiles)
        return copy
    }

    /// In-place Main evidence update. No snapshot publication or whole-state
    /// copy is needed for the discrete status/rate consumers.
    mutating func ingestProfiles(_ profiles: [B0ScanProfile], diagnostics: StreamParser.Diagnostics,
                                 receivedAt: Date, skippedProfiles: Int = 0,
                                 geometry: ProfileGeometryDiagnostic? = nil) {
        self.diagnostics = diagnostics
        self.skippedProfiles += max(0, skippedProfiles)
        if let geometry { profileGeometry = geometry }
        for profile in profiles {
            lastProfile = profile
            lastProfileReceivedAt = receivedAt
            recordProfileTimestamp(receivedAt)
        }
    }

    /// Die **eine** Stelle, die entscheidet, welche Frames eines
    /// Lesevorgangs gültige B0-Profile sind — in Empfangsreihenfolge.
    ///
    /// Ein Decodierfehler (etwa ein unerwartetes Kommandobyte) wird
    /// bewusst still übersprungen statt den gesamten Zustand mit einem
    /// Fehler zu überschreiben; sichtbar wird so etwas allein über
    /// `StreamParser.Diagnostics`.
    public static func decodedProfiles(in frames: [Frame]) -> [B0ScanProfile] {
        frames.compactMap { frame in
            guard case .success(let profile) = B0ScanProfile.decode(from: frame.payload) else {
                return nil
            }
            return profile
        }
    }

    /// Ein echtes Stromende (siehe `SickPLSSerialConnection.ReadResult
    /// .reachedEndOfStream`). `unexpectedly` unterscheidet ein vom Nutzer
    /// über ``ScanSession/disconnect()`` ausgelöstes Ende (kein Fehler)
    /// von einem echten Verbindungsverlust (Fehlerzustand) -- diese
    /// Unterscheidung kann nur der Aufrufer treffen, der weiß, ob gerade
    /// ein Trennen angefordert wurde.
    public func applyingStreamEnded(portPath: String, baudRate: SerialPortBaudRate, unexpectedly: Bool) -> ScanSessionState {
        guard unexpectedly else {
            return .init()
        }
        var copy = self
        copy.connection = .failed(portPath: portPath, baudRate: baudRate, message: "Connection ended unexpectedly (end of stream).")
        return copy
    }

    /// Ein vom Nutzer explizit angefordertes Trennen -- immer ein voller
    /// Rücksetzung auf den Leerzustand, kein Fehler.
    public func applyingDisconnected() -> ScanSessionState {
        ScanSessionState()
    }

    // MARK: - Rollierende Profilrate

    private mutating func recordProfileTimestamp(_ date: Date) {
        recentProfileTimestamps.append(date)
        if recentProfileTimestamps.count > Self.rateWindowCount {
            recentProfileTimestamps.removeFirst(recentProfileTimestamps.count - Self.rateWindowCount)
        }
        guard recentProfileTimestamps.count >= 2,
              let first = recentProfileTimestamps.first,
              let last = recentProfileTimestamps.last else {
            profileRateHz = nil
            return
        }
        let span = last.timeIntervalSince(first)
        profileRateHz = span > 0 ? Double(recentProfileTimestamps.count - 1) / span : nil
    }
}
