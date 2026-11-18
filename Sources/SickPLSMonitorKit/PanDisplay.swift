import Foundation

/// Anzeige und Zugmathematik des Pan-Reglers im Kanalzug. Rein, ohne View.
/// Pan reicht von −1 (ganz links) über 0 (Mitte) bis +1 (ganz rechts).
public enum PanDisplay {
    /// Zugweg in Punkten für den ganzen Bereich von links nach rechts.
    public static let dragTravel = 120.0

    /// „C“ in der Mitte, sonst „L37“ bzw. „R37“ in Prozent.
    public static func label(_ pan: Double) -> String {
        let percent = Int((min(max(pan, -1), 1) * 100).rounded())
        if percent == 0 { return "C" }
        return percent < 0 ? "L\(-percent)" : "R\(percent)"
    }

    /// Nach oben ziehen (negative Verschiebung) dreht nach rechts.
    public static func dragged(startPan: Double, translationY: Double) -> Double {
        let start = min(max(startPan, -1), 1)
        guard translationY.isFinite else { return start }
        return min(max(start - translationY * 2 / dragTravel, -1), 1)
    }

    /// Zeigerwinkel in Grad: −135 ganz links, 0 Mitte, +135 ganz rechts.
    public static func indicatorAngle(_ pan: Double) -> Double {
        min(max(pan, -1), 1) * 135
    }
}
