import CoreGraphics

/// Die **planare** Abbildung zwischen Feldkoordinate und Bildschirm,
/// durch den gewählten Ausschnitt (SICK-032b1, seit SICK-032b2c
/// **formtreu**: `.agent_handoff/task-sick-032b2c.md`).
///
/// ## Der Fehler, den dieser Typ seit SICK-032b2c nicht mehr macht
///
/// Bis SICK-032b2c normierte diese Geometrie den gewählten Winkel- und
/// Entfernungsbereich (``ScanPlaneViewport``s Vorgänger `ScanViewport`)
/// **getrennt** auf `0...1` und zeichnete das Ergebnis danach wieder als
/// **vollständigen** Fächer (``FanScreenGeometry/screenPoint(angleFraction:displayRadiusFraction:)``
/// erwartet genau das: einen Anteil am **ganzen** Öffnungswinkel). Jeder
/// enger werdende Winkelausschnitt wurde damit auf den ganzen Halbkreis
/// aufgefächert -- eine polare Umparametrisierung, kein Bildzoom. Ein
/// physisch festes Messwertmuster konnte dabei beim Zoomen seine Form
/// und Ausrichtung auf dem Bildschirm ändern (Owner-Befund nach
/// SICK-032b2b).
///
/// ## Die zwei Schritte, seither streng getrennt
///
/// 1. **Kanonische Welt** (``worldPoint(angleFraction:radiusFraction:)``):
///    Die Position eines Feldpunkts im **vollen** Fächer -- unabhängig
///    vom aktuellen Ausschnitt, genau einmal über die **unveränderten**
///    Feldanteile bestimmt (nie über einen bereits ausschnittsnormierten
///    Bruchteil).
/// 2. **Affine Ausschnittsabbildung** (``project(worldPoint:)``): Der
///    aktuelle ``ScanPlaneViewport`` skaliert und verschiebt diese
///    bereits feststehende Position **affin** (Skalierung + Verschiebung,
///    keine Drehung) in die sichtbare Ansicht.
///
/// ``project(angleFraction:radiusFraction:)`` ist nur noch die
/// Verkettung beider Schritte; es gibt keinen dritten Weg, der sie
/// umgeht.
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// 1. **Keine Wurzel, kein Logarithmus, keine sonstige nichtlineare
///    Kompression.** Die vierte Wurzel aus SICK-012b
///    (``PolarProfileGeometry/displayRadiusFraction(fromRadiusFraction:)``)
///    gehört ausschließlich der alten Darstellung; sie darf **nie** in
///    diesen Weg geraten.
/// 2. **Keine zweite Trigonometrie.** Winkel und Bildschirmpunkt
///    entstehen ausschließlich über ``FanScreenGeometry`` -- auch die
///    kanonische Welt ist nur eine Auswertung von
///    ``FanScreenGeometry/screenPoint(angleFraction:displayRadiusFraction:)``/
///    ``FanScreenGeometry/fanCoordinate(forScreenPoint:)`` an einem
///    **Einheitsfächer** (Mittelpunkt Ursprung, Radius `1`, **derselbe**
///    Öffnungswinkel wie ``fan``) -- keine eigene `cos`/`sin`/`atan2`-Zeile
///    in dieser Datei.
/// 3. **Keine erneute Auffächerung.** Der Winkel eines Feldpunkts entsteht
///    genau einmal, aus dem **unveränderten** `angleFraction` -- nie aus
///    einem bereits durch den Ausschnitt geteilten Bruchteil. Die
///    einzige Stelle, an der ``viewport`` überhaupt vorkommt, ist die
///    affine Umrechnung Welt ↔ Bildschirm.
/// 4. **Nichts Fachliches.** Kein Import von `SickPLSCore` oder
///    `SickPLSControlCore`: kein Profil, keine Messung, keine ``Zone``,
///    keine Rolle. Es geht eine Zahl hinein und eine Bildschirmposition
///    heraus.
/// 5. **Genau eine Bedienumkehrung für Bedienpunkte** (SICK-032b2c-K2,
///    `.agent_handoff/review-sick-032b2c-k1.md`): ``worldPoint(forScreenPoint:)``
///    ist der mathematisch ungeklammerte reine Vertrag und bleibt das --
///    ``canvasRect`` ist die sichtbare Fläche, ``GeometryReader`` kann
///    darüber hinaus unsichtbare Letterbox-Ränder zeichnen. **Jede
///    Geste** (Zoom-Anker, Pan-Beginn/-Fortsetzung, beide Ecken des
///    Rahmenzooms, Auswahl, Zonenbearbeitung, der sichtbare
///    Gummirahmen) muss stattdessen ``boundedWorldPoint(forScreenPoint:)``
///    bzw. ``canvasClampedScreenPoint(_:)`` verwenden -- **nicht** je
///    Werkzeug eine eigene Grenzformel auf dem bereits berechneten
///    Weltpunkt nachbauen (das war der Unterschied zwischen K1 und K2:
///    K1 klammerte in ``fieldCoordinate(forScreenPoint:)`` bereits
///    richtig, aber mit einer zweiten, eigenen Weltklammerung statt der
///    einen Bildschirmklammerung).
public struct LinearScanFieldGeometry: Equatable, Sendable {

    /// Platzierung, Radius und Öffnungswinkel des gezeichneten Fächers.
    public let fan: FanScreenGeometry
    /// Der sichtbare Ausschnitt -- ein planares, kartesisches Fenster in
    /// die kanonische Welt.
    public let viewport: ScanPlaneViewport

    public init(fan: FanScreenGeometry, viewport: ScanPlaneViewport) {
        self.fan = fan
        self.viewport = viewport
    }

    /// Die feste, sichtbare Canvasfläche dieser Geometrie -- **unabhängig
    /// vom aktuellen** ``viewport``. Jeder aktive Ausschnitt füllt sie
    /// exakt (siehe ``FanScreenGeometry/init(size:)``), deshalb ist sie
    /// der **eine gemeinsame** Clip für Messkurve, Fächerkontur, Zonen
    /// und Griffe (SICK-032b2c-K1, Auftragspunkt 3) -- keine Ebene
    /// bekommt eine eigene, abweichende Grenze.
    public var canvasRect: CGRect {
        CGRect(
            x: fan.center.x - fan.radius,
            y: fan.center.y - fan.radius,
            width: fan.radius * 2,
            height: fan.radius * 2
        )
    }

    /// Die sichtbare Scanner-Basis bleibt am unteren Rand der Canvas.
    /// Sie ist eine Orientierungsmarke der Darstellung und deshalb bewusst
    /// unabhängig vom verschieb- und zoombaren Welt-Ausschnitt.
    public var canvasBaselineY: CGFloat {
        canvasRect.maxY - 1
    }

    /// Der Skalenfaktor der affinen Ausschnittsabbildung -- **derselbe**
    /// Wert, den ``project(worldPoint:)`` intern für beide Achsen
    /// benutzt. Eine öffentliche Stelle dafür, damit ihn niemand ein
    /// zweites Mal herleitet (SICK-032b2c-K1: zuvor zweimal, hier und in
    /// `ZoneOverlayView`).
    public var screenScale: CGFloat {
        fan.radius / CGFloat(viewport.halfExtent)
    }

    /// Derselbe Öffnungswinkel wie ``fan``, aber Mittelpunkt Ursprung und
    /// Radius `1` -- die kanonische Welt lebt hier, unabhängig von
    /// Fenstergröße und Ausschnitt. **Die einzige Stelle, an der dieser
    /// Hilfswert entsteht.**
    private var unitFan: FanScreenGeometry {
        FanScreenGeometry(
            center: .zero, radius: 1,
            startAngleRadians: fan.startAngleRadians, endAngleRadians: fan.endAngleRadians
        )
    }

    /// Eine auf den Bildschirm gebrachte Feldkoordinate.
    public struct ProjectedPoint: Equatable, Sendable {
        /// Die Bildschirmposition.
        public let screenPoint: CGPoint
        /// Liegt die Feldkoordinate im sichtbaren Ausschnitt?
        ///
        /// **Getrennt mitgeliefert statt den Punkt wegzulassen:** Eine
        /// Linie zwischen zwei Messpunkten, von denen einer außerhalb
        /// liegt, braucht beide Positionen, um an der richtigen Stelle
        /// aus dem Bild zu laufen. Ob geklippt, ausgeblendet oder
        /// blass gezeichnet wird, entscheidet die Ansicht -- nicht die
        /// Geometrie.
        public let isInsideViewport: Bool
    }

    /// Eine aus einem Bildschirmpunkt zurückgerechnete Feldkoordinate.
    public struct FieldCoordinate: Equatable, Sendable {
        public let angleFraction: Double
        public let radiusFraction: Double

        /// Trägt der ausgewertete Bildschirmpunkt eine echte
        /// Winkelinformation? -- siehe
        /// ``FanScreenGeometry/FanCoordinate/isAngleDefined``.
        public let isAngleDefined: Bool

        public init(angleFraction: Double, radiusFraction: Double, isAngleDefined: Bool) {
            self.angleFraction = angleFraction
            self.radiusFraction = radiusFraction
            self.isAngleDefined = isAngleDefined
        }
    }

    /// Taugt diese Geometrie als Grundlage einer **Bearbeitung**?
    ///
    /// Zum **Zeichnen** ist jede Geometrie brauchbar: ``FanScreenGeometry``
    /// liefert bei entarteten Werten bewusst neutrale Ersatzwerte, und
    /// ein Bild, das nichts zeigt, ist richtig. Als Grundlage einer
    /// **Geste** wäre derselbe Ersatzwert dagegen ein erfundener
    /// Fachwert.
    public var isUsableForEditing: Bool {
        fan.center.x.isFinite && fan.center.y.isFinite
            && fan.radius.isFinite && fan.radius > 0
            && fan.startAngleRadians.isFinite && fan.endAngleRadians.isFinite
            && fan.endAngleRadians != fan.startAngleRadians
    }

    // MARK: - Kanonische Welt (Schritt 1)

    /// Die Position einer Feldkoordinate im **vollen** Fächer -- **genau
    /// einmal** bestimmt, unabhängig vom aktuellen ``viewport``.
    ///
    /// Eine reine Auswertung von
    /// ``FanScreenGeometry/screenPoint(angleFraction:displayRadiusFraction:)``
    /// am Einheitsfächer: derselbe Winkel, den auch das **volle**
    /// gezeichnete Bild an dieser Feldkoordinate hätte, nur auf Radius
    /// `1` normiert statt auf ``fan``s tatsächlichen Bildschirmradius.
    public func worldPoint(angleFraction: Double, radiusFraction: Double) -> CGPoint {
        unitFan.screenPoint(angleFraction: angleFraction, displayRadiusFraction: radiusFraction)
    }

    /// Die Umkehrung von ``worldPoint(angleFraction:radiusFraction:)``:
    /// aus einer Weltposition zurück zur Feldkoordinate im vollen
    /// Fächer, **ohne** Bezug zum aktuellen ``viewport``.
    public func fieldCoordinate(forWorldPoint point: CGPoint) -> FanScreenGeometry.FanCoordinate {
        unitFan.fanCoordinate(forScreenPoint: point)
    }

    // MARK: - Affine Ausschnittsabbildung (Schritt 2)

    /// Weltposition -> Bildschirm: **eine** Skalierung (``fan/radius``
    /// geteilt durch ``ScanPlaneViewport/halfExtent``) und **eine**
    /// Verschiebung, auf beiden Achsen gleich -- keine Drehung, keine
    /// Kompression.
    ///
    /// Ein Weltpunkt außerhalb des Ausschnitts liefert eine Position
    /// außerhalb des gezeichneten Fächers und `isInsideViewport == false`;
    /// es wird **nicht** geklammert.
    public func project(worldPoint point: CGPoint) -> ProjectedPoint {
        let offsetX = Double(point.x) - viewport.centerX
        let offsetY = Double(point.y) - viewport.centerY
        // Eine einzige Division durch `halfExtent`, gebündelt in `scale`.
        // `offsetX`/`offsetY` sind noch unnormiert -- würde man sie zuerst
        // selbst durch `halfExtent` teilen und danach nochmals mit
        // `scale` (das seinerseits schon durch `halfExtent` teilt)
        // multiplizieren, ginge die Division doppelt ein und die
        // Bildschirmposition skalierte quadratisch statt linear mit dem
        // Zoom -- bei `halfExtent == 1` (Gesamtansicht) zufällig richtig,
        // bei jedem anderen Ausschnitt sichtbar falsch.
        let scale = screenScale
        let screenPoint = CGPoint(
            x: fan.center.x + scale * CGFloat(offsetX),
            y: fan.center.y + scale * CGFloat(offsetY)
        )
        let normalizedX = offsetX / viewport.halfExtent
        let normalizedY = offsetY / viewport.halfExtent
        let isInside = normalizedX >= -1 && normalizedX <= 1 && normalizedY >= -1 && normalizedY <= 1
        return ProjectedPoint(screenPoint: screenPoint, isInsideViewport: isInside)
    }

    /// Feldkoordinate -> Bildschirm -- die Verkettung beider Schritte,
    /// **nie** ein eigener, dritter Weg.
    public func project(angleFraction: Double, radiusFraction: Double) -> ProjectedPoint {
        project(worldPoint: worldPoint(angleFraction: angleFraction, radiusFraction: radiusFraction))
    }

    /// Bildschirm -> Weltposition, die Umkehrung von
    /// ``project(worldPoint:)``.
    ///
    /// `nil` bei entarteter Fächergeometrie (`radius <= 0`) -- als
    /// **Anker einer Bedienhandlung** wäre ein Ersatzwert eine erfundene
    /// Zeigerposition.
    ///
    /// **Mathematisch ungeklammert, bewusst so** (SICK-032b2c-K2): Dies
    /// ist der reine affine Vertrag, nicht die Bedienumkehrung. Ein
    /// Bildschirmpunkt außerhalb ``canvasRect`` -- etwa in einem
    /// unsichtbaren Letterbox-Rand -- liefert hier ehrlich eine
    /// Weltposition außerhalb des Ausschnitts. **Kein produktiver
    /// Gestenweg darf diese Methode direkt für einen möglicherweise
    /// außerhalb liegenden Bedienpunkt aufrufen** -- dafür steht
    /// ``boundedWorldPoint(forScreenPoint:)``.
    public func worldPoint(forScreenPoint point: CGPoint) -> CGPoint? {
        guard fan.radius > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let normalizedX = Double((point.x - fan.center.x) / fan.radius)
        let normalizedY = Double((point.y - fan.center.y) / fan.radius)
        let worldX = viewport.centerX + normalizedX * viewport.halfExtent
        let worldY = viewport.centerY + normalizedY * viewport.halfExtent
        return CGPoint(x: worldX, y: worldY)
    }

    /// Ein Bildschirmpunkt, achsenweise auf ``canvasRect`` geklammert --
    /// die tatsächlich sichtbare Bedienfläche, nicht das volle
    /// `GeometryReader`-Rechteck einschließlich seiner Letterbox-Ränder
    /// (SICK-032b2c-K2, `.agent_handoff/review-sick-032b2c-k1.md`). Ein
    /// Punkt bereits innerhalb bleibt unverändert.
    ///
    /// **Die eine Stelle, an der Bedienpunkte auf die Canvas begrenzt
    /// werden** -- benutzt von ``boundedWorldPoint(forScreenPoint:)`` für
    /// jede Bedienumkehrung und von der Ansicht für den sichtbaren
    /// Gummirahmen, damit Rechenweg und Zeichnung nie auseinanderlaufen.
    public func canvasClampedScreenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: Swift.min(Swift.max(point.x, canvasRect.minX), canvasRect.maxX),
            y: Swift.min(Swift.max(point.y, canvasRect.minY), canvasRect.maxY)
        )
    }

    /// Bildschirm -> Welt **für eine Bedienhandlung** (Zoom-Anker,
    /// Pan-Beginn/-Fortsetzung, beide Ecken des Rahmenzooms, Auswahl und
    /// Zonenbearbeitung) -- SICK-032b2c-K2, schließt
    /// `.agent_handoff/review-sick-032b2c-k1.md`.
    ///
    /// Klammert den Bildschirmpunkt zuerst achsenweise über
    /// ``canvasClampedScreenPoint(_:)`` auf ``canvasRect`` und bildet ihn
    /// **danach** über dieselbe affine Umkehrung
    /// ``worldPoint(forScreenPoint:)`` in die kanonische Welt ab -- **eine
    /// benannte Umkehrung**, nicht je Werkzeug eine eigene Grenzformel.
    /// Ein Zeiger im unsichtbaren Letterbox-Rand liefert deshalb denselben
    /// Weltpunkt wie einer genau am sichtbaren Canvasrand: Weitere
    /// Bewegung im selben Rand ändert nichts mehr, und eine Geste, die
    /// vollständig im selben Rand beginnt und endet, bewegt den
    /// Ausschnitt überhaupt nicht.
    ///
    /// `nil` bei entarteter Fächergeometrie oder nicht endlichem Punkt --
    /// dieselbe Grenze wie ``worldPoint(forScreenPoint:)``.
    public func boundedWorldPoint(forScreenPoint point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return worldPoint(forScreenPoint: canvasClampedScreenPoint(point))
    }

    /// Bildschirm -> Feldkoordinate: Bildschirm -> Welt (``viewport``) ->
    /// voller Fächer -> Feldkoordinate (``unitFan``). **Keine erneute
    /// Auffächerung eines Ausschnitts** -- der zweite Schritt kennt
    /// ``viewport`` nicht.
    ///
    /// Liefert `nil` bei entarteter Fächergeometrie. Das Ergebnis liegt
    /// immer in `0...1`.
    ///
    /// **Ein Zeiger jenseits der sichtbaren Canvas klammert achsenweise
    /// auf ihren Rand, nicht auf den vollen Feldrand** (SICK-030b2-Vertrag
    /// „Zug über den sichtbaren Rand hinaus stoppt am Rand", seither
    /// unverändert gültig). **Seit SICK-032b2c-K2 über dieselbe eine
    /// Bedienumkehrung wie jede andere Geste** (Auftragspunkt 1/2,
    /// `.agent_handoff/review-sick-032b2c-k1.md`):
    /// ``boundedWorldPoint(forScreenPoint:)`` klammert den Bildschirmpunkt
    /// zuerst auf ``canvasRect`` -- **die tatsächlich sichtbare Fläche**,
    /// nicht auf einen unsichtbaren Letterbox-Rand und nicht mehr über
    /// eine zweite, eigene Weltklammerung (bis K1 radial, bis K2 zwar
    /// achsenweise, aber eine **eigene** Formel auf dem bereits
    /// berechneten Weltpunkt -- beides mathematisch gleichwertig zur
    /// Canvas-Klammerung, aber eine unnötige zweite Herleitung derselben
    /// Grenze). Fachwerte und Zonen bleiben unverändert; geklammert wird
    /// ausschließlich der Bedienpunkt.
    ///
    /// **Die innere Fächerspitze bleibt ein geometrisch unvermeidlicher
    /// Sonderfall** (unverändert seit SICK-032b2b,
    /// ``FieldCoordinate/isAngleDefined``): Fällt die zurückgerechnete
    /// Weltposition mit dem Fächerursprung zusammen, trägt sie keine
    /// Winkelinformation. Die Entfernung bleibt richtig.
    public func fieldCoordinate(forScreenPoint point: CGPoint) -> FieldCoordinate? {
        guard let world = boundedWorldPoint(forScreenPoint: point) else { return nil }
        let raw = fieldCoordinate(forWorldPoint: world)
        return FieldCoordinate(
            angleFraction: raw.angleFraction.clamped(to: 0...1),
            radiusFraction: raw.displayRadiusFraction.clamped(to: 0...1),
            isAngleDefined: raw.isAngleDefined
        )
    }
}
