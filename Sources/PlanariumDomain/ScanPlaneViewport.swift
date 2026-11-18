/// Der sichtbare Ausschnitt des Scanfelds -- ein **planarer**,
/// achsenparalleles Quadrat in einem festen kanonischen Weltbild des
/// vollständigen Fächerfelds (SICK-032b2c).
///
/// ## Warum planar und nicht polar
///
/// Bis SICK-032b2c beschrieb der Ausschnitt einen Winkel- und einen
/// Entfernungsbereich (`angleLower/Upper`, `radiusLower/Upper`,
/// vormals `ScanViewport`). `LinearScanFieldGeometry` normierte diese
/// beiden Bereiche getrennt auf `0...1` und zeichnete sie danach wieder
/// als **vollständigen** Fächer -- jeder enger werdende Winkelbereich
/// wurde dabei auf den ganzen Halbkreis aufgefächert. Ein Bildzoom ist
/// das nicht, sondern eine polare Umparametrisierung: Ein physisch
/// festes Messwertmuster konnte dabei beim Zoomen seine Form und
/// Ausrichtung auf dem Bildschirm ändern.
///
/// Dieser Typ beschreibt den Ausschnitt stattdessen als **kartesisches**
/// Rechteck (hier: ein Quadrat, siehe unten) in der **kanonischen Welt**
/// -- der festen Position eines Feldpunkts im **vollen** Fächer, wie sie
/// ``LinearScanFieldGeometry/worldPoint(angleFraction:radiusFraction:)``
/// genau einmal bestimmt. Der Ausschnitt skaliert und verschiebt diese
/// bereits feststehende Position anschließend nur noch **affin**
/// (Skalierung + Verschiebung, keine Drehung, keine Kompression) in die
/// sichtbare Ansicht. Keine erneute Auffächerung ist damit strukturell
/// ausgeschlossen: Der Winkel eines Feldpunkts entsteht nie ein zweites
/// Mal aus einem bereits normierten Bruchteil.
///
/// ## Warum ein Quadrat (isotrop) statt vier unabhängiger Grenzen
///
/// Cos und Sin sind für jeden Öffnungswinkel auf `-1...1` beschränkt;
/// die kanonische Welt jedes Feldpunkts liegt deshalb -- unabhängig vom
/// konkreten Öffnungswinkel des gezeichneten Fächers -- innerhalb des
/// Quadrats `-1...1` × `-1...1`. Der Ausschnitt hält **eine** Skalierung
/// (``halfExtent``) für **beide** Achsen: Scrollrad, Pinch und Lupe
/// wenden auf beiden Achsen denselben Faktor an, und ein Rahmenzoom passt
/// sich der **größeren** der beiden gezogenen Spannen an (wie ein
/// „Einpassen" in einer Karten-/Bildansicht, nicht ein Verzerren). Damit
/// bleibt jeder Zoom eine reine Ähnlichkeitsabbildung: Winkel, Verhältnisse
/// und Kreisbögen bleiben exakt erhalten, nie elliptisch verzerrt.
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// 1. **Kein Import.** Dieser Typ kennt weder `CoreGraphics` noch ein
///    Fachmodul -- reine `Double`-Arithmetik über zwei Geradengleichungen
///    je Achse.
/// 2. **Validierende Fabrik ohne stille Korrektur** (Hausmuster wie
///    `Frame.build`/`Zone.build`): ``build(centerX:centerY:halfExtent:)``
///    lehnt jede Verletzung mit einem eigenen, benannten Fehler ab.
/// 3. **Die vier Werkzeuge** (``panned(byX:byY:)``,
///    ``zoomed(byFactor:anchorX:anchorY:)``,
///    ``zoomedToRectangle(xA:xB:yA:yB:)``, dazu ``fullField``) klammern
///    selbst auf die gespeicherten Zahlen -- ihr Ergebnis übersteht
///    immer die strenge Fabrik.
public struct ScanPlaneViewport: Equatable, Sendable {

    /// Mittelpunkt des sichtbaren Ausschnitts in kanonischen
    /// Weltkoordinaten.
    public let centerX: Double
    public let centerY: Double

    /// Halbe Kantenlänge des sichtbaren Ausschnitts in Weltkoordinaten,
    /// auf **beiden** Achsen gleich. Kleiner heißt näher herangezoomt.
    public let halfExtent: Double

    /// Untere Schranke von ``halfExtent``.
    ///
    /// **Dokumentierter Startwert, keine Gerätewahrheit** -- derselbe
    /// Zahlenwert wie die frühere `ScanViewport.minimumAngleSpan`/
    /// `minimumRadiusSpan`.
    public static let minimumHalfExtent: Double = 1e-4

    /// Der Rand der kanonischen Welt: Cos/Sin sind für jeden
    /// Öffnungswinkel auf diesen Bereich beschränkt.
    private static let worldLowerBound: Double = -1
    private static let worldUpperBound: Double = 1

    /// Obere Schranke von ``halfExtent`` -- die ganze kanonische Welt auf
    /// einmal, mehr gibt es nicht zu zeigen.
    public static let maximumHalfExtent: Double = (worldUpperBound - worldLowerBound) / 2

    /// Die Gesamtansicht: die ganze kanonische Welt, mittig.
    public static let fullField = ScanPlaneViewport(
        centerX: 0, centerY: 0, halfExtent: maximumHalfExtent
    )

    /// Ist dieser Ausschnitt die Gesamtansicht?
    public var isFullField: Bool { self == Self.fullField }

    public var xLowerBound: Double { centerX - halfExtent }
    public var xUpperBound: Double { centerX + halfExtent }
    public var yLowerBound: Double { centerY - halfExtent }
    public var yUpperBound: Double { centerY + halfExtent }

    public enum BuildError: Error, Equatable, Sendable {
        case nonFiniteInput
        case halfExtentTooSmall
        case halfExtentTooLarge
        case centerOutsideField
    }

    /// Ungeprüfter interner Konstruktor -- ausschließlich für bereits
    /// geklammerte Werte aus ``fullField`` und den vier Werkzeugen. Jeder
    /// von außen erreichbare Weg läuft über ``build(centerX:centerY:halfExtent:)``.
    private init(centerX: Double, centerY: Double, halfExtent: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.halfExtent = halfExtent
    }

    /// Validierende Fabrik. Lehnt jede Verletzung ab, statt sie still zu
    /// klammern.
    public static func build(centerX: Double, centerY: Double, halfExtent: Double) throws -> ScanPlaneViewport {
        guard centerX.isFinite, centerY.isFinite, halfExtent.isFinite else {
            throw BuildError.nonFiniteInput
        }
        guard halfExtent >= minimumHalfExtent else { throw BuildError.halfExtentTooSmall }
        guard halfExtent <= maximumHalfExtent else { throw BuildError.halfExtentTooLarge }
        let minCenter = worldLowerBound + halfExtent
        let maxCenter = worldUpperBound - halfExtent
        guard centerX >= minCenter, centerX <= maxCenter,
              centerY >= minCenter, centerY <= maxCenter else {
            throw BuildError.centerOutsideField
        }
        return ScanPlaneViewport(centerX: centerX, centerY: centerY, halfExtent: halfExtent)
    }

    // MARK: - Verschieben

    /// Verschiebt den Ausschnitt um eine Weltstrecke je Achse. Am Rand
    /// hört die Bewegung auf -- der Ausschnitt wird **nicht** gestaucht
    /// und klappt nicht um.
    public func panned(byX dx: Double, byY dy: Double) -> ScanPlaneViewportChange {
        guard dx.isFinite, dy.isFinite else { return .rejected(.nonFiniteInput) }
        let newCenterX = Self.clampedCenter(centerX + dx, halfExtent: halfExtent)
        let newCenterY = Self.clampedCenter(centerY + dy, halfExtent: halfExtent)
        return .applied(ScanPlaneViewport(centerX: newCenterX, centerY: newCenterY, halfExtent: halfExtent))
    }

    // MARK: - Zoom am Anker

    /// Zoomt um einen Weltpunkt: Er behält seine **relative** Lage im
    /// Ausschnitt, der Ausschnitt selbst wird enger (`factor > 1`) oder
    /// weiter (`factor < 1`).
    ///
    /// **Derselbe Faktor auf beiden Achsen** -- das ist die strukturelle
    /// Zusage der Formtreue für Scrollrad, Pinch und Lupe: Es gibt keine
    /// zwei Zahlen, die auseinanderlaufen könnten.
    public func zoomed(byFactor factor: Double, anchorX: Double, anchorY: Double) -> ScanPlaneViewportChange {
        guard factor.isFinite, anchorX.isFinite, anchorY.isFinite else { return .rejected(.nonFiniteInput) }
        guard factor > 0 else { return .rejected(.nonPositiveZoomFactor) }

        let rawHalfExtent = halfExtent / factor
        let newHalfExtent = Self.clampedHalfExtent(rawHalfExtent)
        // Der **wirklich eingetretene** Verhältniswert, nicht der
        // nominal angeforderte Faktor -- an einer Schranke weichen beide
        // voneinander ab, und nur so bleiben Spanne und Ankerverschiebung
        // zueinander konsistent.
        let ratio = newHalfExtent / halfExtent
        let rawCenterX = anchorX + (centerX - anchorX) * ratio
        let rawCenterY = anchorY + (centerY - anchorY) * ratio
        let newCenterX = Self.clampedCenter(rawCenterX, halfExtent: newHalfExtent)
        let newCenterY = Self.clampedCenter(rawCenterY, halfExtent: newHalfExtent)
        return .applied(ScanPlaneViewport(centerX: newCenterX, centerY: newCenterY, halfExtent: newHalfExtent))
    }

    // MARK: - Rahmenzoom

    /// Zwei Weltecken werden zum neuen Ausschnitt -- **isotrop
    /// eingepasst**: ``halfExtent`` deckt die **größere** der beiden
    /// gezogenen Spannen, wie ein „Einpassen" in einer Karten-/Bildansicht.
    /// Niemand zieht einen Rahmen immer von links oben nach rechts unten;
    /// alle vier Ziehrichtungen ergeben denselben Ausschnitt.
    public func zoomedToRectangle(xA: Double, xB: Double, yA: Double, yB: Double) -> ScanPlaneViewportChange {
        guard xA.isFinite, xB.isFinite, yA.isFinite, yB.isFinite else { return .rejected(.nonFiniteInput) }
        let width = abs(xB - xA)
        let height = abs(yB - yA)
        let rawHalfExtent = Swift.max(width, height) / 2
        guard rawHalfExtent >= Self.minimumHalfExtent else { return .rejected(.degenerateRectangle) }

        let newHalfExtent = Self.clampedHalfExtent(rawHalfExtent)
        let midX = (xA + xB) / 2
        let midY = (yA + yB) / 2
        let newCenterX = Self.clampedCenter(midX, halfExtent: newHalfExtent)
        let newCenterY = Self.clampedCenter(midY, halfExtent: newHalfExtent)
        return .applied(ScanPlaneViewport(centerX: newCenterX, centerY: newCenterY, halfExtent: newHalfExtent))
    }

    // MARK: - Hilfen

    private static func clampedHalfExtent(_ raw: Double) -> Double {
        if raw < minimumHalfExtent { return minimumHalfExtent }
        if raw > maximumHalfExtent { return maximumHalfExtent }
        return raw
    }

    /// Hält den Mittelpunkt so, dass der Ausschnitt innerhalb der
    /// kanonischen Welt bleibt. Deckt ``halfExtent`` die Welt bereits
    /// vollständig ab (an der oberen Schranke, `minCenter > maxCenter`
    /// wäre sonst ein Absturz), steht der Mittelpunkt auf der Weltmitte.
    private static func clampedCenter(_ raw: Double, halfExtent: Double) -> Double {
        let minCenter = worldLowerBound + halfExtent
        let maxCenter = worldUpperBound - halfExtent
        guard minCenter <= maxCenter else { return (worldLowerBound + worldUpperBound) / 2 }
        return Swift.min(Swift.max(raw, minCenter), maxCenter)
    }
}

/// Ergebnis eines Ausschnittswerkzeugs -- geschlossen, damit kein
/// Aufrufer eine Ablehnung als `nil` mitlaufen lässt.
public enum ScanPlaneViewportChange: Equatable, Sendable {
    case applied(ScanPlaneViewport)
    case rejected(ScanPlaneViewportRejection)

    /// Der neue Ausschnitt, falls das Werkzeug ihn angewandt hat -- `nil`
    /// bei einer Ablehnung. Bequemlichkeit für Aufrufer, die eine
    /// Ablehnung an dieser Stelle bereits ausgeschlossen haben (etwa
    /// Tests, die den direkten Werkzeugaufruf als Erwartungswert nehmen).
    public var viewport: ScanPlaneViewport? {
        if case .applied(let viewport) = self { return viewport }
        return nil
    }
}

public enum ScanPlaneViewportRejection: Equatable, Sendable {
    case nonFiniteInput
    case nonPositiveZoomFactor
    case degenerateRectangle
}
