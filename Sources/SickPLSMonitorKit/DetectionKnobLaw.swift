import Foundation
import PlanariumDomain

/// Bedienregel der Detektions-Drehknöpfe: senkrechtes Ziehen rastet in
/// ganzen Schritten, nach oben wird der Wert größer.
public enum DetectionKnobLaw {
    public static let pointsPerStep = 6.0

    /// Index nach einer Zugbewegung, begrenzt auf `0..<count`.
    public static func index(start: Int, translationY: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let steps = translationY.isFinite ? Int((-translationY / pointsPerStep).rounded(.towardZero)) : 0
        return min(max(start + steps, 0), count - 1)
    }

    /// Raststellung, die einem gespeicherten Wert am nächsten liegt (bei
    /// Gleichstand die kleinere). Werte außerhalb des Rasters bleiben
    /// gespeichert, bis der Knopf bewegt wird.
    public static func nearestIndex(of value: Int, in values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        return values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
    }

    /// Zeigerwinkel in Grad: −135° am Anfang, +135° am Ende des Bereichs.
    public static func angle(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        let fraction = Double(min(max(index, 0), count - 1)) / Double(count - 1)
        return -135 + 270 * fraction
    }
}

/// Drehschalter für die zeitliche Glättung. „Off“ schaltet nur ab und behält
/// Methode und Fenster, damit das Zurückdrehen den alten Wert wiederfindet.
public enum SmoothingSwitchPosition: Int, CaseIterable, Sendable {
    case off, mean, median, exponential

    public var label: String {
        switch self {
        case .off: return "OFF"
        case .mean: return "MEAN"
        case .median: return "MEDIAN"
        case .exponential: return "EXP"
        }
    }

    public init(_ configuration: DetectionConfiguration) {
        guard configuration.smoothingEnabled else { self = .off; return }
        switch configuration.temporalSmoothing {
        case .off: self = .off
        case .mean: self = .mean
        case .median: self = .median
        case .exponential: self = .exponential
        }
    }

    public func applied(to configuration: DetectionConfiguration) -> DetectionConfiguration {
        var next = configuration
        next.time.selectMethod(rawValue)
        return next
    }
}
