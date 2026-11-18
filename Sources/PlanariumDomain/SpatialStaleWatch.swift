import Foundation
import PLSDeviceValues

/// Entscheidet ausschließlich, ob seit dem letzten echten Profil die
/// gemeinsame Eingangsverlustgrenze überschritten wurde. Die Entscheidung
/// erzeugt keine Werte und wird nach dem ersten Treffer entprellt.
public struct SpatialStaleWatch: Sendable {
    public private(set) var staleTimeoutSeconds: Double

    private var lastProfileTime: Double?
    private var hasFiredForCurrentProfile = false

    public static let defaultTimeoutSeconds: Double = 0.35
    public init(staleTimeoutSeconds: Double = Self.defaultTimeoutSeconds) {
        precondition(staleTimeoutSeconds.isFinite && staleTimeoutSeconds > 0)
        self.staleTimeoutSeconds = staleTimeoutSeconds
    }

    /// Meldet ein tatsächlich akzeptiertes Profil als frischen Eingang.
    public mutating func noteProfile(at time: Double) {
        guard time.isFinite else { return }
        lastProfileTime = time
        hasFiredForCurrentProfile = false
    }

    /// Liefert genau beim ersten `elapsed > staleTimeoutSeconds` true.
    public mutating func check(at time: Double) -> Bool {
        guard let lastProfileTime,
              time.isFinite,
              time - lastProfileTime > staleTimeoutSeconds,
              !hasFiredForCurrentProfile else { return false }
        hasFiredForCurrentProfile = true
        return true
    }

    /// Vergisst den alten Eingang vollständig, etwa nach einem echten
    /// Portende, Schlaf, Stop oder Beenden.
    public mutating func reset() {
        lastProfileTime = nil
        hasFiredForCurrentProfile = false
    }

    /// Absolute monotonic deadline for the next stale check, if a profile
    /// has been accepted and the current watch has not fired yet.
    public var nextDeadline: Double? {
        guard let lastProfileTime, !hasFiredForCurrentProfile else { return nil }
        return lastProfileTime + staleTimeoutSeconds
    }
}
