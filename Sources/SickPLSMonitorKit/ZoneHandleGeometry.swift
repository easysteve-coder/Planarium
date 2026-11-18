import PlanariumDomain
import CoreGraphics
import SickPLSControlCore

/// Wo die vier Griffe einer Zone liegen und was unter dem Zeiger liegt
/// (SICK-032b3).
///
/// ## Warum das hier steht und nicht in der Ansicht
///
/// Dieselbe Rechnung beantwortet **zwei** Fragen: „wohin zeichne ich den
/// Griff?" und „welchen Griff hat der Zeiger getroffen?". Lägen sie an
/// zwei Stellen, könnten sie auseinanderlaufen -- und zwar unbemerkt, weil
/// ein leicht danebenliegender Trefferbereich aussieht wie ein
/// ungenauer Klick, nicht wie ein Fehler. Deshalb: **eine** Quelle,
/// ohne SwiftUI, ohne gerenderte Ansicht prüfbar.
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// 1. **Nur die lineare Geometrie.** Feld ↔ Bildschirm läuft
///    ausschließlich über ``LinearScanFieldGeometry``; die
///    Anzeigekompression aus SICK-012b (vierte Wurzel) kommt im
///    Bearbeitungsweg **nicht** vor. Ein Quelltexttest hält das fest.
/// 2. **Die Toleranz ist reine Treffergröße in Punkten, nie eine
///    fachliche Mindestspanne** (Befund **N7** aus
///    `review-sick-030-architecture.md`): Sie entscheidet, was der Zeiger
///    erwischt, und **nie**, welche Zone gültig ist. Die fachliche
///    Mindestausdehnung bleibt allein bei ``ZoneDraft``.
/// 3. **Nur lesen.** Nichts hier verändert eine ``Zone``, eine Auswahl,
///    eine Aktivierung oder einen Ausschnitt.
public enum ZoneHandleGeometry {

    /// Trefferradius eines Griffs in Bildschirmpunkten.
    ///
    /// **Eine Bedienentscheidung, keine Fachgrenze** (Regel 2). `14` ist
    /// grob eine Fingerkuppe bzw. ein bequemes Mausziel und bleibt klein
    /// genug, dass zwei Griffe einer schmalen Zone sich nicht dauerhaft
    /// gegenseitig verdecken -- und falls doch, gewinnt der **nächste**,
    /// nicht der erstbeste.
    public static let handleHitRadius: CGFloat = 14

    /// Sichtbarer Durchmesser eines gezeichneten Griffs in Punkten --
    /// bewusst kleiner als der Trefferradius: Ein Ziel darf großzügiger
    /// sein, als es aussieht, aber nie kleiner.
    public static let handleDiameter: CGFloat = 11

    /// Ein Griff mit seiner Bildschirmposition.
    public struct PlacedHandle: Equatable, Sendable {
        public let handle: ZoneGeometryHandle
        public let screenPoint: CGPoint
        /// Liegt der Griff im sichtbaren Ausschnitt? Ein Griff außerhalb
        /// wird **weder gezeichnet noch getroffen** (Auftragspunkt 5) --
        /// sonst behauptete ein Punkt am Bildrand eine Grenze, die gerade
        /// gar nicht zu sehen ist.
        public let isVisible: Bool
    }

    /// Die vier Griffe der Zone, in fester Reihenfolge
    /// (``ZoneGeometryHandle/allCases``).
    ///
    /// Gelegt werden sie auf die **Mitte** der jeweiligen Kante: Die
    /// beiden Indexgriffe an die seitlichen Kanten auf halber Entfernung,
    /// die beiden Wertgriffe an die innere und äußere Kante auf halbem
    /// Winkel. So gehört jeder Griff sichtbar zu genau der Grenze, die er
    /// bewegt, und keine zwei fallen zusammen.
    public static func placedHandles(
        for zone: Zone,
        in geometry: LinearScanFieldGeometry
    ) -> [PlacedHandle] {
        let angleLower = zone.indexRange.lowerBound
        let angleUpper = zone.indexRange.upperBound
        let angleMid = (angleLower + angleUpper) / 2
        let radiusInner = radiusFraction(of: zone.valueRange.lowerBound)
        let radiusOuter = radiusFraction(of: zone.valueRange.upperBound)
        let radiusMid = (radiusInner + radiusOuter) / 2

        let placements: [(ZoneGeometryHandle, Double, Double)] = [
            (.indexLowerBound, angleLower, radiusMid),
            (.indexUpperBound, angleUpper, radiusMid),
            (.valueInnerBound, angleMid, radiusInner),
            (.valueOuterBound, angleMid, radiusOuter)
        ]

        return placements.map { handle, angle, radius in
            let projected = geometry.project(angleFraction: angle, radiusFraction: radius)
            return PlacedHandle(
                handle: handle,
                screenPoint: projected.screenPoint,
                isVisible: projected.isInsideViewport
            )
        }
    }

    /// Überlappt die Zone den sichtbaren Ausschnitt überhaupt?
    ///
    /// **Dieselbe Bedingung, nach der `ZoneOverlayView` zeichnet** -- sie
    /// ruft diese Methode auf, damit „wird gezeichnet" und „ist bedienbar"
    /// nicht auseinanderlaufen können.
    ///
    /// **Seit SICK-032b2c-K1 eine exakte, analytische Umhüllende statt
    /// einer festen Stichprobe** (Abnahmeblocker 2,
    /// `.agent_handoff/review-sick-032b2c.md`): Die vorherige 16er-
    /// Winkelabtastung konnte das tatsächliche Extremum eines Bogens
    /// zwischen zwei Stichproben verfehlen und eine sichtbare Zone
    /// **fälschlich als unsichtbar** melden -- belegt an einer Zone mit
    /// Winkelanteil `0,11...0,91` und einem `0,0002` schmalen Viewport um
    /// den Bogenpunkt `(0,-1)` (Winkelanteil `0,5`): Die lokale Bogenmitte
    /// der Stichprobe (Winkelanteil `0,51`) lag knapp daneben, und die
    /// höhere feste Stichprobenzahl hätte den Fehler nur verschoben,
    /// nicht beseitigt.
    ///
    /// Die neue Umhüllende wertet für Innen- und Außenbogen je die
    /// **beiden Endwinkel** und **jeden im Winkelbereich liegenden
    /// kartesischen Extremwinkel** aus (`0°`, `90°`, `180°`, `270°` --
    /// dort erreicht `cos` bzw. `sin` sein lokales Extremum). Das ist
    /// keine Näherung: Zwischen zwei solchen Winkeln ist ein Kreisbogen
    /// in `x` und `y` streng monoton, sein Extremum liegt deshalb
    /// **immer** an einem der geprüften Winkel -- keine False Negatives,
    /// unabhängig von der Zonenbreite.
    ///
    /// **Keine zweite Trigonometrie** (Regel 1 dieses Typs, wörtlich auch
    /// ``LinearScanFieldGeometry``s eigene Regel): Jeder Kandidatenwinkel
    /// wird als Winkel**anteil** ermittelt und über die bestehende
    /// ``LinearScanFieldGeometry/worldPoint(angleFraction:radiusFraction:)``
    /// ausgewertet -- dieselbe einzige Stelle, die auch
    /// ``placedHandles(for:in:)`` benutzt. Diese Datei selbst ruft nie
    /// `cos`/`sin` auf.
    public static func isVisible(_ zone: Zone, in geometry: LinearScanFieldGeometry) -> Bool {
        let innerFraction = radiusFraction(of: zone.valueRange.lowerBound)
        let outerFraction = radiusFraction(of: zone.valueRange.upperBound)
        let angleLower = zone.indexRange.lowerBound
        let angleUpper = zone.indexRange.upperBound

        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for angle in candidateAngleFractions(lower: angleLower, upper: angleUpper, in: geometry.fan) {
            for radius in [innerFraction, outerFraction] {
                let world = geometry.worldPoint(angleFraction: angle, radiusFraction: radius)
                minX = Swift.min(minX, Double(world.x))
                maxX = Swift.max(maxX, Double(world.x))
                minY = Swift.min(minY, Double(world.y))
                maxY = Swift.max(maxY, Double(world.y))
            }
        }

        let viewport = geometry.viewport
        return maxX >= viewport.xLowerBound && minX <= viewport.xUpperBound
            && maxY >= viewport.yLowerBound && minY <= viewport.yUpperBound
    }

    /// Alle Winkelanteile, an denen der Bogen zwischen `lower` und
    /// `upper` sein kartesisches Extremum erreichen kann: die beiden
    /// Endwinkel selbst, plus jeder Kardinalwinkel, der -- zurückgerechnet
    /// in einen Winkelanteil **dieses** Fächers -- in den Bereich fällt.
    private static func candidateAngleFractions(
        lower: Double, upper: Double, in fan: FanScreenGeometry
    ) -> [Double] {
        var candidates = [lower, upper]
        for cardinal in [0.0, .pi / 2, .pi, 3 * .pi / 2] {
            guard let fraction = angleFraction(ofCardinal: cardinal, in: fan),
                  fraction >= lower, fraction <= upper
            else { continue }
            candidates.append(fraction)
        }
        return candidates
    }

    /// Der Winkelanteil (`0...1`, bezogen auf den **vollen** Fächer), an
    /// dem der Kardinalwinkel `cardinal` (modulo `2π`) liegt -- `nil`,
    /// wenn er im Öffnungswinkel dieses Fächers gar nicht vorkommt (bei
    /// den festen `180°`, wie bisher immer gebaut, trifft das auf `90°`
    /// zu).
    private static func angleFraction(ofCardinal cardinal: Double, in fan: FanScreenGeometry) -> Double? {
        let span = fan.endAngleRadians - fan.startAngleRadians
        guard span != 0 else { return nil }
        let twoPi = 2 * Double.pi
        let shifted = cardinal - fan.startAngleRadians
        let remainder = shifted - twoPi * (shifted / twoPi).rounded(.down)
        guard fan.startAngleRadians + remainder <= fan.endAngleRadians else { return nil }
        return remainder / span
    }

    /// Was eine an diesem Punkt beginnende Geste bedeuten würde -- oder
    /// `nil`, wenn dort nichts dieser Zone liegt.
    ///
    /// **Griffe schlagen die Fläche**, und unter mehreren Griffen in
    /// Reichweite gewinnt der **nächste**. Ohne diese Reihenfolge wäre
    /// eine schmale Zone nicht mehr über ihre Griffe bedienbar: Deren
    /// Trefferbereiche liegen dann vollständig in ihrer eigenen Fläche,
    /// und ein Zug würde immer die ganze Zone verschieben.
    ///
    /// **Bewusste, mit den Ausschnittswerkzeugen einheitliche Grenze:**
    /// Die Flächenprüfung benutzt ``LinearScanFieldGeometry/fieldCoordinate(forScreenPoint:)``,
    /// und die klammert einen Zeiger neben dem gezeichneten Fächer auf
    /// die nächstgelegene Feldposition -- genauso, wie Zoom und
    /// Rechteckzoom seit SICK-032b1/b2 ihre Anker klammern. Ein Klick
    /// knapp außerhalb des Fächers kann deshalb eine Zone am Feldrand
    /// treffen. Das ist dieselbe Konvention an allen Stellen und deshalb
    /// vorhersagbar; eine Sonderregel nur hier wäre es nicht.
    public static func gesture(
        at point: CGPoint,
        for zone: Zone,
        in geometry: LinearScanFieldGeometry
    ) -> ZoneGeometryGesture? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        // **Dieselbe Prüfung, die auch der Reducer stellt.** Bei
        // entarteter Geometrie fallen alle Griffe auf denselben
        // Ersatzpunkt -- ein Klick dorthin träfe scheinbar eine Grenze,
        // und die Geste würde anschließend zu Recht abgelehnt. Ein Ziel,
        // das nicht bedienbar ist, wird gar nicht erst angeboten.
        guard geometry.isUsableForEditing else { return nil }
        guard isVisible(zone, in: geometry) else { return nil }

        // Verglichen wird das **Quadrat** der Entfernung: Das spart nicht
        // nur die Wurzel, es hält den Bearbeitungsweg auch frei von jedem
        // `squareRoot`, den ein Quelltexttest sonst nicht von einer
        // Anzeigekompression unterscheiden könnte.
        let hitRadiusSquared = handleHitRadius * handleHitRadius
        var nearest: (handle: ZoneGeometryHandle, distanceSquared: CGFloat)?
        for placed in placedHandles(for: zone, in: geometry) where placed.isVisible {
            let dx = placed.screenPoint.x - point.x
            let dy = placed.screenPoint.y - point.y
            let distanceSquared = dx * dx + dy * dy
            guard distanceSquared.isFinite, distanceSquared <= hitRadiusSquared else { continue }
            if nearest == nil || distanceSquared < nearest!.distanceSquared {
                nearest = (placed.handle, distanceSquared)
            }
        }
        if let nearest { return .handle(nearest.handle) }

        guard let field = geometry.fieldCoordinate(forScreenPoint: point) else { return nil }
        let rawValue = ZoneEditorGeometry.rawValue(fromRadiusFraction: field.radiusFraction)
        guard zone.indexRange.contains(field.angleFraction),
              zone.valueRange.contains(rawValue) else { return nil }
        return .moveWholeZone
    }

    /// Rohwert -> linearer Anteil an der festen 13-Bit-Obergrenze. **Die
    /// einzige Umrechnung dieser Richtung in diesem Weg**, und sie ist
    /// eine Division -- keine Kompression.
    private static func radiusFraction(of value: UInt16) -> Double {
        Double(value) / PolarProfileGeometry.maxRawMeasurementValue
    }
}
