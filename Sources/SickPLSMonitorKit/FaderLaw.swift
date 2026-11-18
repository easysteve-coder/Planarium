import Foundation
import PlanariumDomain

public enum FaderLaw {
    public struct ScaleMark: Equatable, Sendable {
        public let position: Double
        public let dB: Double
        public var label: String { dB <= -60 ? "−∞" : String(format: dB > 0 ? "+%.0f" : "%.0f", dB) }
        public init(position: Double, dB: Double) { self.position = position; self.dB = dB }
    }

    public static let unityPosition = 0.75
    public static let maximumGain = pow(10.0, InstrumentChannel.maximumLevelDecibels / 20.0)
    public static let scaleMarks: [ScaleMark] = [
        ScaleMark(position: 0, dB: -60), ScaleMark(position: 0.08, dB: -40),
        ScaleMark(position: 0.16, dB: -30), ScaleMark(position: 0.28, dB: -20),
        ScaleMark(position: 0.36, dB: -15), ScaleMark(position: 0.46, dB: -10),
        ScaleMark(position: 0.56, dB: -6), ScaleMark(position: 0.65, dB: -3),
        ScaleMark(position: unityPosition, dB: 0), ScaleMark(position: 0.875, dB: 3),
        ScaleMark(position: 1, dB: InstrumentChannel.maximumLevelDecibels)
    ]

    public static func decibels(forPosition position: Double) -> Double {
        guard position.isFinite else { return -60 }
        let p = min(max(position, 0), 1)
        for (lower, upper) in zip(scaleMarks, scaleMarks.dropFirst()) where p <= upper.position {
            let fraction = (p - lower.position) / (upper.position - lower.position)
            return lower.dB + fraction * (upper.dB - lower.dB)
        }
        return 6
    }

    public static func position(forDecibels decibels: Double) -> Double {
        guard decibels.isFinite, decibels > -60 else { return 0 }
        if decibels >= 6 { return 1 }
        for (lower, upper) in zip(scaleMarks, scaleMarks.dropFirst()) where decibels <= upper.dB {
            let fraction = (decibels - lower.dB) / (upper.dB - lower.dB)
            return lower.position + fraction * (upper.position - lower.position)
        }
        return 0
    }

    public static func gain(forPosition position: Double) -> Double {
        let dB = decibels(forPosition: position)
        return dB <= -60 ? 0 : pow(10, dB / 20)
    }

    public static func position(forGain gain: Double) -> Double {
        guard gain > 0, gain.isFinite else { return 0 }
        return position(forDecibels: 20 * log10(gain))
    }

    public static func decibelLabel(forPosition position: Double) -> String {
        let dB = decibels(forPosition: position)
        guard dB > -60 else { return "−∞" }
        return String(format: dB > 0 ? "+%.1f" : "%.1f", dB).replacingOccurrences(of: "-", with: "−")
    }
}
