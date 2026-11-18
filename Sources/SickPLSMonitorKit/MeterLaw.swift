import Foundation

/// dBFS is independent of fader gain. Unity is full scale; silence is zero.
public enum MeterLaw {
    public static let scaleDecibels = Array(stride(from: 0, through: -60, by: -3))
    public static func position(forDecibels decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 60)/60))
    }
    public static func position(forGain gain: Double) -> Double {
        guard gain.isFinite, gain > 0 else { return 0 }
        return position(forDecibels: 20*log10(gain))
    }

    /// Farbzone eines Pegels wie in Logic: grün bis −12 dBFS, orange ab −6,
    /// rot ab −3. Dazwischen verläuft die Farbe stufenlos.
    public enum Zone: Equatable, Sendable { case safe, warning, over }
    /// Farbstützpunkte des Balkens von unten nach oben, in dBFS. Die Farbe
    /// hängt an der Höhe im Balken, nicht am aktuellen Pegel.
    public static let colorStops: [(decibels: Double, zone: Zone)] = [
        (-60, .safe), (-12, .safe), (-6, .warning), (-3, .warning), (0, .over)
    ]
}
/// Übersteuerung über Vollaussteuerung. Die Anzeige verschwindet nach
/// `holdSeconds` ohne neue Übersteuerung von selbst; ein Klick löscht sofort.
public struct MeterClipState: Equatable, Sendable {
    public static let holdSeconds = 2.0
    public private(set) var isClipped = false
    private var remainingSeconds = 0.0
    public init() {}
    public mutating func observe(peak: Double) {
        guard peak.isFinite && peak > 1 else { return }
        isClipped = true; remainingSeconds = Self.holdSeconds
    }
    public mutating func advance(elapsed: Double) {
        guard isClipped, elapsed.isFinite, elapsed > 0 else { return }
        remainingSeconds -= elapsed
        if remainingSeconds <= 0 { reset() }
    }
    public mutating func reset() { isClipped = false; remainingSeconds = 0 }
}
