import SickPLSCore

/// Reine Geometrie-/Skalierungsschicht für die relative Polar-/
/// Fächer-Darstellung eines ``B0ScanProfile`` -- unabhängig von SwiftUI,
/// damit sie ohne eine gerenderte Ansicht getestet werden kann
/// (SICK-012-Auftrag: „relative Geometrie/Skalierung" testen).
///
/// Display-normalized geometry. Raw distances are centimeters (meters =
/// raw / 100). Normalization and optional visual compression change only
/// screen coordinates; they do not change the metric measurement contract.
public enum PolarProfileGeometry {
    /// Ein einzelner, bereits auf `0...1` normierter Platzhalterpunkt.
    public struct Point: Equatable, Sendable {
        /// Position des Messpunkts innerhalb des Profils, `0...1` über den
        /// gesamten Indexbereich -- **kein** physischer Winkel.
        public let angleFraction: Double
        /// Rohmesswert relativ zum größten in 13 Bit darstellbaren Wert
        /// (`0x1FFF` = 8191, siehe `b0-scan-profile.md` Abschnitt 1),
        /// **nicht** relativ zum größten Wert *in diesem einen Profil* --
        /// nur so bleibt die Skalierung über mehrere Profile hinweg
        /// vergleichbar und täuscht keine physische Kalibrierung vor.
        public let radiusFraction: Double
        /// Rein darstellungsbezogene, monotone Kompression von
        /// ``radiusFraction`` (vierte Wurzel, zweifaches `.squareRoot()`)
        /// -- **ausschließlich zur Sichtbarkeit gedacht, keine
        /// physikalische Bedeutung, keine Kalibrierung.**
        ///
        /// Grund (SICK-012b, Supervisor-Befund): Die real beobachteten
        /// Rohwerte liegen bei ≈ 21...169 (siehe Checkpoint, SICK-012-
        /// Mitschnitt) -- gegenüber der festen 8191er-Grenze ergibt das
        /// lineare `radiusFraction` nur ≈ 0,3...2,1 % und macht ein
        /// echtes Profil in einer Ansicht mit realistischer Pixelgröße
        /// praktisch unsichtbar. Eine Kompression, die auf dem
        /// *ohnehin bereits festen* `radiusFraction` (nicht auf dem
        /// jeweiligen Profil-Maximum) aufbaut, bleibt eine reine,
        /// deterministische Funktion nur dieses einen Punkts -- sie
        /// hängt weder vom übrigen Profil noch vom vorherigen Bild ab
        /// und kann deshalb nie zwischen zwei Bildern "flackern"
        /// (anders als eine Neuskalierung auf das jeweils aktuelle
        /// Profil-Maximum, die je nach Profil unterschiedlich ausfiele).
        /// Die vierte Wurzel ist mit der reinen Swift-Stdlib
        /// (`.squareRoot()`, zweifach angewendet) berechenbar, ohne
        /// einen zusätzlichen `Darwin`/`Foundation`-Import für `pow`.
        /// Beispiel: 169/8191 ≈ 2,06 % linear, aber ≈ 38 % nach dieser
        /// Kompression; 21/8191 ≈ 0,26 % linear, aber ≈ 22 % danach --
        /// beide damit deutlich sichtbar, ohne den Maximalfall (8191 ->
        /// weiterhin exakt `1.0`) zu verzerren.
        public let displayRadiusFraction: Double

        public init(angleFraction: Double, radiusFraction: Double) {
            self.angleFraction = angleFraction
            self.radiusFraction = radiusFraction
            self.displayRadiusFraction = PolarProfileGeometry.displayRadiusFraction(fromRadiusFraction: radiusFraction)
        }
    }

    /// Der größte in 13 Bit darstellbare Rohmesswert -- feste
    /// Normierungsgrundlage für ``Point/radiusFraction``, siehe dort.
    public static let maxRawMeasurementValue: Double = 0x1FFF

    /// Vierte Wurzel von `radiusFraction` -- siehe
    /// ``Point/displayRadiusFraction``. Öffentlich (nicht nur intern auf
    /// ``Point``) und eigenständig, damit andere Bildschirmdarstellungen
    /// dieselbe Formel wiederverwenden statt sie ein zweites Mal
    /// nachzubauen (SICK-014: der Zoneneditor zeichnet Zonenflächen mit
    /// exakt derselben Kompression, über ``ZoneEditorGeometry``, das
    /// diese Funktion für die Vorwärtsrichtung aufruft). `radiusFraction`
    /// ist stets `>= 0` (ein Quotient zweier nichtnegativer Werte),
    /// `.squareRoot()` ist deshalb für jeden hier vorkommenden Wert
    /// definiert.
    public static func displayRadiusFraction(fromRadiusFraction radiusFraction: Double) -> Double {
        radiusFraction.squareRoot().squareRoot()
    }

    /// Leitet aus `profile.measurements` normierte Platzhalterpunkte ab.
    /// Ein Profil mit null oder einem Messpunkt liefert eine Liste
    /// derselben Länge, ohne durch Null zu teilen (siehe
    /// ``angleFraction(forIndex:count:)``).
    public static func points(for profile: B0ScanProfile) -> [Point] {
        let count = profile.measurements.count
        return profile.measurements.enumerated().map { index, measurement in
            Point(
                angleFraction: angleFraction(forIndex: index, count: count),
                radiusFraction: Double(measurement.value) / maxRawMeasurementValue
            )
        }
    }

    /// `0` für den ersten, `1` für den letzten Index eines Profils mit
    /// mindestens zwei Punkten; `0.5` für ein Profil mit genau einem
    /// Punkt (kein sinnvoller „letzter" Index sonst); niemals eine
    /// Division durch `count - 1 == 0`.
    static func angleFraction(forIndex index: Int, count: Int) -> Double {
        guard count > 1 else { return 0.5 }
        return Double(index) / Double(count - 1)
    }
}
