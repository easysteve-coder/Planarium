import PlanariumDomain
import SickPLSControlCore

/// Reine Umrechnung zwischen der (bereits Anzeige-komprimierten)
/// Fächerposition und dem relativen Index-/Rohwertraum, in dem
/// `SickPLSControlCore.Zone` lebt (SICK-014-Auftrag, Architektur
/// Punkt 2: „den Umweg Bildschirmkoordinate ↔ relative
/// Index-/Rohwertkoordinate sauber behandeln; für den Radius gilt die
/// inverse Anzeige-Kompression"). Kennt kein `CoreGraphics`, keine
/// Bildschirmkoordinaten -- diese Schicht kennt nur `0...1`-Anteile,
/// siehe ``FanScreenGeometry`` für den Bildschirm-Umweg davor/danach.
public enum ZoneEditorGeometry {
    /// Vorwärtsrichtung: roher Messwert (`0...8191`) -> Anzeige-
    /// komprimierte Fächerposition -- ruft dieselbe, einzige Formel wie
    /// echte Messpunkte auf (`PolarProfileGeometry
    /// .displayRadiusFraction(fromRadiusFraction:)`), damit eine
    /// gezeichnete Zonenfläche exakt an derselben Bildschirmposition
    /// liegt wie ein Messpunkt mit demselben Rohwert.
    public static func displayRadiusFraction(fromValue value: UInt16) -> Double {
        PolarProfileGeometry.displayRadiusFraction(fromRadiusFraction: Double(value) / PolarProfileGeometry.maxRawMeasurementValue)
    }

    /// Rückwärtsrichtung: kehrt die vierte Wurzel aus
    /// `PolarProfileGeometry.displayRadiusFraction(fromRadiusFraction:)`
    /// um (`x -> x^4`, über zweifaches Quadrieren statt `pow` --
    /// dieselbe Stdlib-only-Bauweise wie die Vorwärtsrichtung).
    /// Klammert das Ergebnis in `0...1`, damit eine Geste knapp
    /// außerhalb des gezeichneten Fächers nicht zu einem Wert außerhalb
    /// des gültigen Bereichs führt.
    public static func radiusFraction(fromDisplayRadiusFraction displayRadiusFraction: Double) -> Double {
        let clamped = displayRadiusFraction.clamped(to: 0...1)
        let squared = clamped * clamped
        return squared * squared
    }

    /// Wandelt einen linearen `radiusFraction` (`0...1`) in den rohen
    /// Messwert (`0...8191`) um -- die Umkehrung der Normierung aus
    /// `PolarProfileGeometry.points(for:)`.
    public static func rawValue(fromRadiusFraction radiusFraction: Double) -> UInt16 {
        let clamped = radiusFraction.clamped(to: 0...1)
        return UInt16((clamped * Double(Zone.maxRawMeasurementValue)).rounded())
    }

    /// Bequemlichkeitsfunktion: Anzeige-komprimierte Fächerposition
    /// direkt in den rohen Messwert (ruft die beiden obigen Schritte
    /// hintereinander auf).
    public static func rawValue(fromDisplayRadiusFraction displayRadiusFraction: Double) -> UInt16 {
        rawValue(fromRadiusFraction: radiusFraction(fromDisplayRadiusFraction: displayRadiusFraction))
    }

    /// `angleFraction` ist in beide Richtungen bereits linear (keine
    /// Kompression) -- nur eine Bereichsklammerung, für eine Geste knapp
    /// außerhalb des gezeichneten Fächers.
    public static func indexFraction(fromAngleFraction angleFraction: Double) -> Double {
        angleFraction.clamped(to: 0...1)
    }
}
