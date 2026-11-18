import CoreGraphics
import Darwin

/// Reine Bildschirmgeometrie der Fächerdarstellung -- von
/// `PolarScanView` (Messpunkte zeichnen) und dem Zoneneditor (SICK-014:
/// Zonenflächen zeichnen, Canvas-Gesten in Fächerkoordinaten
/// zurückrechnen) gemeinsam genutzt, damit dieselbe Geometrie nicht an
/// zwei Stellen eigenständig -- und potenziell abweichend -- entsteht
/// (derselbe Grundsatz wie beim einzigen fachlichen Zonenvertrag,
/// `SickPLSControlCore.Zone`).
///
/// Nutzt `CoreGraphics` (`CGPoint`/`CGFloat`), bewusst aber kein
/// SwiftUI (kein `Angle`, keine `View`) -- reine Geometrie, ohne
/// Hintergrund-Thread oder gerenderte Ansicht testbar, genau wie
/// ``PolarProfileGeometry``/``ZoneEditorGeometry``.
public struct FanScreenGeometry: Equatable, Sendable {
    public let center: CGPoint
    public let radius: CGFloat
    /// Öffnungswinkel in Radiant, **kein** reales Sichtfeld des
    /// Scanners -- derselbe willkürliche, klar benannte
    /// Darstellungs-Platzhalter wie zuvor eigenständig in
    /// `PolarScanView` (SICK-012-Auftrag Punkt 6).
    public let startAngleRadians: Double
    public let endAngleRadians: Double

    public static let openingAngleDegrees: Double = 180

    /// Baut die Fächergeometrie für eine Ansicht der gegebenen Größe.
    ///
    /// **Seit SICK-032b2c-K1 ein isotroper, zentrierter Quadrat-Fit der
    /// kanonischen Welt** (`-1...1` × `-1...1`, ``ScanPlaneViewport``s
    /// eigener Wertebereich) -- nicht mehr die alte, an der Fächerspitze
    /// nahe dem unteren Rand verankerte Platzierung. `center` ist die
    /// **wirkliche Mitte** dieser Ansicht, `radius` ihre **wirkliche
    /// Halbausdehnung** auf der kürzeren Achse. Das ist die
    /// Voraussetzung dafür, dass **jeder** aktuell aktive
    /// ``ScanPlaneViewport`` -- nicht nur die Gesamtansicht -- exakt auf
    /// diese Fläche abgebildet wird: ``LinearScanFieldGeometry/project(worldPoint:)``
    /// sendet den Mittelpunkt des jeweils aktiven Ausschnitts stets auf
    /// `center` und dessen Rand stets auf `center ± radius`, unabhängig
    /// vom gewählten ``ScanPlaneViewport/halfExtent`` (Abnahmeblocker 1,
    /// `.agent_handoff/review-sick-032b2c.md`). Zuvor war `center` **nicht**
    /// die Mitte der sichtbaren Fläche und `radius` **nicht** deren
    /// Halbausdehnung -- beide äußeren Fächerendpunkte lagen für eine
    /// 800×600-Ansicht außerhalb `0...800`.
    ///
    /// **Bewusst offengelassene Leerflächen (Auftragspunkt 2), nicht
    /// durch Clipping versteckt:** Der 180°-Öffnungswinkel deckt nur die
    /// Hälfte der kanonischen Welt ab (`sin` ist für `180°...360°` nie
    /// positiv) -- die **untere** Hälfte des gefitteten Quadrats bleibt
    /// deshalb immer leer. Bei einer nicht quadratischen Ansicht kommen
    /// zusätzlich zwei gleich breite Ränder hinzu (links/rechts bei
    /// breiter als hoch, oben/unten bei höher als breit) -- eine
    /// zentrierte, isotrope Letterbox-Fläche, wie vom Auftrag
    /// ausdrücklich zugelassen.
    public init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        radius = min(size.width, size.height) / 2
        let halfOpening = Self.openingAngleDegrees / 2 * .pi / 180
        let center270 = 270.0 * .pi / 180
        startAngleRadians = center270 - halfOpening
        endAngleRadians = center270 + halfOpening
    }

    /// Für Tests und benutzerdefinierte Platzierungen: direkte
    /// Konstruktion ohne `CGSize`-Umweg.
    public init(center: CGPoint, radius: CGFloat, startAngleRadians: Double, endAngleRadians: Double) {
        self.center = center
        self.radius = radius
        self.startAngleRadians = startAngleRadians
        self.endAngleRadians = endAngleRadians
    }

    /// Winkel (Radiant) eines relativen Index-/Winkelanteils (`0...1`) --
    /// die **einzige** Stelle, an der aus einem Anteil ein Winkel wird
    /// (SICK-030b2, Auflage **D5** „Indexformel geteilt"). Sie stand
    /// zuvor zweimal da: hier in ``screenPoint(angleFraction:displayRadiusFraction:)``
    /// und noch einmal beim Zeichnen der Ringsektoren des Zoneneditors.
    /// Zwei Kopien derselben Formel laufen früher oder später
    /// auseinander -- dieselbe Begründung wie beim einzigen fachlichen
    /// Zonenvertrag `SickPLSControlCore.Zone`.
    public func angleRadians(forIndexFraction indexFraction: Double) -> Double {
        startAngleRadians + (endAngleRadians - startAngleRadians) * indexFraction
    }

    /// Bildschirmposition eines Fächerpunkts -- `displayRadiusFraction`
    /// ist bereits Anzeige-komprimiert (siehe `PolarProfileGeometry
    /// .displayRadiusFraction(fromRadiusFraction:)`/``ZoneEditorGeometry``).
    public func screenPoint(angleFraction: Double, displayRadiusFraction: Double) -> CGPoint {
        let angle = angleRadians(forIndexFraction: angleFraction)
        let r = radius * CGFloat(displayRadiusFraction)
        return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
    }

    /// Eine aus einem Bildschirmpunkt zurückgerechnete Fächerkoordinate.
    ///
    /// Seit SICK-032b2b ein Wert statt eines Tupels, weil er eine dritte
    /// Angabe trägt: ob der Winkel überhaupt gemessen wurde.
    public struct FanCoordinate: Equatable, Sendable {
        public let angleFraction: Double
        public let displayRadiusFraction: Double

        /// Trägt der ausgewertete Bildschirmpunkt überhaupt eine
        /// Winkelinformation? (SICK-032b2b)
        ///
        /// `false` **genau dann**, wenn der Punkt mit dem Mittelpunkt des
        /// Fächers zusammenfällt -- der Spitze der Darstellung. Dort hat
        /// `atan2(0, 0)` keinen definierten Wert; die Zahl in
        /// ``angleFraction`` ist dann ein Artefakt der Umrechnung
        /// (beim gezeichneten Halbkreis fällt sie auf `1.0`) und **kein
        /// Messwert**. Jeder andere Punkt hat eine echte Richtung, auch
        /// ein Punkt ein Pixel daneben; dass dort die Winkelanteile `0`
        /// und `1` unmittelbar nebeneinander liegen, ist die Geometrie
        /// des Fächers und kein Fehler.
        ///
        /// Wer den Wert **zeichnet**, darf ihn unbesehen nehmen -- er
        /// landet ohnehin auf demselben Punkt. Wer ihn als **Anker einer
        /// Bedienhandlung** benutzt, muss diesen Fall behandeln, sonst
        /// reißt ein erfundener Winkel den Ausschnitt an eine Kante
        /// (siehe ``LinearScanFieldGeometry/FieldCoordinate``).
        public let isAngleDefined: Bool

        public init(angleFraction: Double, displayRadiusFraction: Double, isAngleDefined: Bool) {
            self.angleFraction = angleFraction
            self.displayRadiusFraction = displayRadiusFraction
            self.isAngleDefined = isAngleDefined
        }
    }

    /// Kehrt ``screenPoint(angleFraction:displayRadiusFraction:)`` um
    /// (SICK-014-Auftrag: „den Umweg Bildschirmkoordinate ↔ relative
    /// Index-/Rohwertkoordinate sauber behandeln"). Klammert beide
    /// Ergebnisse in `0...1`, damit eine Geste knapp außerhalb des
    /// gezeichneten Fächers nicht zu einem Wert außerhalb des gültigen
    /// Bereichs führt -- bei `radius <= 0` (entartete Ansichtsgröße)
    /// ergibt sich `0.0` statt einer Division durch 0.
    ///
    /// Seit SICK-032b2b meldet das Ergebnis zusätzlich, ob der Winkel
    /// überhaupt bestimmbar war -- siehe ``FanCoordinate/isAngleDefined``.
    public func fanCoordinate(forScreenPoint point: CGPoint) -> FanCoordinate {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        let displayRadiusFraction = radius > 0 ? (distance / Double(radius)).clamped(to: 0...1) : 0

        var angle = atan2(dy, dx)
        while angle < startAngleRadians { angle += 2 * .pi }
        while angle > endAngleRadians { angle -= 2 * .pi }
        let span = endAngleRadians - startAngleRadians
        let angleFraction = span != 0 ? ((angle - startAngleRadians) / span).clamped(to: 0...1) : 0.5

        return FanCoordinate(
            angleFraction: angleFraction,
            displayRadiusFraction: displayRadiusFraction,
            // Genau der Punkt, an dem `atan2` keinen Wert hat.
            isAngleDefined: !(dx == 0 && dy == 0)
        )
    }
}
