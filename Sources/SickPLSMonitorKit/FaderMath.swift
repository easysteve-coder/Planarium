/// Reine Fader-Rechnung (macOS-Paket 3a). Ziehen ist relativ zum Greifpunkt,
/// damit der Fader beim Anfassen nicht springt; Tastatur und Bedienhilfen
/// verstellen in festen Schritten.
public enum FaderMath {
    public static let step = 0.05

    public static func dragged(startValue: Double, translationY: Double, travel: Double) -> Double {
        guard travel > 0, travel.isFinite, translationY.isFinite else { return clamp(startValue) }
        return clamp(startValue - translationY / travel)
    }

    public static func stepped(_ value: Double, up: Bool) -> Double {
        clamp(value + (up ? step : -step))
    }

    private static func clamp(_ value: Double) -> Double { max(0, min(1, value)) }
}
