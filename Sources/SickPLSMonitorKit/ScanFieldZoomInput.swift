import Darwin

/// Ein rohes Scrollereignis des Systems, wie die AppKit-Naht es meldet
/// (SICK-032b2b).
///
/// **Ein reiner Ereignisbericht, keine Rechnung.** Der Typ trägt genau
/// die drei Angaben, die macOS über ein Scrollereignis macht und die für
/// eine Zoomentscheidung zusammen gehören -- die Strecke **und** ihre
/// Einheit **und** ihre Richtung. Alle drei getrennt weiterzureichen
/// wäre die Einladung, eine davon zu vergessen; genau das war der Fehler,
/// den dieser Slice behebt: Bis SICK-032b2 kam nur `deltaY` an, ohne zu
/// sagen, ob es Zeilen oder Punkte sind und ob der Bedienende die
/// Scrollrichtung umgestellt hat.
///
/// **Bewusst keine validierende Fabrik** (anders als `Frame.build`/
/// `Zone.build`/``ScanPlaneViewport/build(centerX:centerY:halfExtent:)``):
/// Es gibt keine Invariante zu sichern. Ein Systemereignis darf jeden
/// Wert tragen, auch einen nicht endlichen; was daraus wird, entscheidet
/// ``ScanFieldZoomInput`` sichtbar über ein Optional.
public struct ScanFieldScrollEvent: Equatable, Sendable {

    /// `NSEvent.scrollingDeltaY` -- **die Einheit steht nicht in dieser
    /// Zahl**, sondern in ``hasPreciseDeltas``.
    public let deltaY: Double

    /// `NSEvent.hasPreciseScrollingDeltas`.
    ///
    /// `true` bei Trackpad und Magic Mouse: ``deltaY`` ist dann eine
    /// Strecke in **Punkten**. `false` bei einem klassischen Mausrad:
    /// ``deltaY`` zählt dann **Rastungen (Zeilen)**, üblicherweise `1`
    /// oder `3` je Klick.
    public let hasPreciseDeltas: Bool

    /// `NSEvent.isDirectionInvertedFromDevice` -- `true`, wenn der
    /// Bedienende „natürliches Scrollen" eingeschaltet hat und das System
    /// ``deltaY`` deshalb bereits gegenüber der echten Gerätebewegung
    /// umgedreht hat.
    public let isDirectionInvertedFromDevice: Bool

    public init(deltaY: Double, hasPreciseDeltas: Bool, isDirectionInvertedFromDevice: Bool) {
        self.deltaY = deltaY
        self.hasPreciseDeltas = hasPreciseDeltas
        self.isDirectionInvertedFromDevice = isDirectionInvertedFromDevice
    }
}

/// Die **einzige** Stelle, an der aus einem Zeigerereignis ein Zoomfaktor
/// wird (SICK-032b2b).
///
/// ## Warum es diesen Typ gibt
///
/// Die Übersetzung lag bis SICK-032b2 als zwei Zeilen in
/// ``ScanFieldViewState`` und war dort nur mittelbar prüfbar. Sie hatte
/// drei belegte Fehler, und alle drei waren am Gerät sichtbar:
///
/// 1. **Der Faktor war affin statt multiplikativ** (`1 + Strecke * k`).
///    Damit ist ein Zoomschritt nicht umkehrbar: `1,2 * 0,8 = 0,96`, der
///    Ausschnitt wächst bei jedem Hin und Her um gut vier Prozent. Zehn
///    Mal vor und zurück gescrollt vergrößerte die Entfernungsspanne
///    gemessen von `0,25` auf `0,376` -- ein Wegdriften aus einer
///    Bewegung, die unterm Strich null Strecke hatte.
/// 2. **Das Ergebnis hing davon ab, wie macOS eine Bewegung in Ereignisse
///    zerlegt.** Eine Strecke in einem Ereignis ergab einen anderen
///    Ausschnitt als dieselbe Strecke in zwei Ereignissen (gemessen
///    `0,1786` gegen `0,1736`). Wie viele Ereignisse das System schickt,
///    ist nicht Sache des Bedienenden.
/// 3. **Zeilen und Punkte wurden gleich behandelt.** Eine Rastung eines
///    Mausrads (`deltaY == 1`) ergab den Faktor `1,01`; zehn Rastungen
///    kamen auf `1,10` -- das Rad war praktisch wirkungslos. Ein
///    Trackpadschwung derselben *Zahl* nach lieferte dagegen bis
///    `1,4` **je Ereignis**.
///
/// ## Die drei Regeln, bei künftigen Änderungen zu erhalten
///
/// 1. **Der Faktor ist multiplikativ:** `2^(Strecke / Strecke je
///    Verdopplung)`. Daraus folgt beides, was oben fehlte -- `f(+d)` und
///    `f(-d)` sind exakte Kehrwerte, und `f(a) * f(b) == f(a + b)`, die
///    Zerlegung in Ereignisse ist also wirkungslos. **Das ist keine
///    Skalierung der Darstellung:** Die Feldachsen bleiben streng linear
///    (``ScanPlaneViewport``, ``LinearScanFieldGeometry``); hier wird
///    ausschließlich die *Bedienstrecke* in einen *Faktor* übersetzt,
///    und ein Zoomfaktor ist seiner Natur nach multiplikativ.
/// 2. **Die Strecke wird auf eine Einheit gebracht, bevor sie gerechnet
///    wird** -- Punkte. Eine Rastung zählt ``pointsPerWheelLine``.
/// 3. **Die Richtung folgt dem Gerät, nicht der Scrolleinstellung.**
///    „Natürliches Scrollen" ist eine Aussage darüber, wie sich *Inhalt
///    beim Scrollen* bewegen soll; ein Zoom ist kein Scrollen. Würde die
///    Einstellung durchschlagen, kehrte dieselbe Handbewegung je nach
///    Systemeinstellung ihre Wirkung um.
public enum ScanFieldZoomInput {

    /// Wie viele Punkte Scrollstrecke einer Rastung eines klassischen
    /// Mausrads entsprechen.
    ///
    /// **Dokumentierter Startwert, keine Gerätewahrheit** (dieselbe
    /// Kennzeichnung wie `ControlValuePredictorConfiguration.startingPoint`
    /// und `GatePolicy.standard`). Mit ``scrollPointsPerDoubling``
    /// ergeben sich rund zehn Prozent je Rastung und etwa acht Rastungen
    /// je Verdopplung.
    public static let pointsPerWheelLine: Double = 16

    /// Wie viele Punkte Scrollstrecke den Zoomfaktor verdoppeln.
    ///
    /// **Dokumentierter Startwert.** Ein bequemer Trackpadschwung liegt
    /// bei einigen hundert Punkten und ergibt damit einige
    /// Verdopplungen -- spürbar, ohne dass die Orientierung verloren
    /// geht.
    public static let scrollPointsPerDoubling: Double = 120

    /// Obergrenze der je **einzelnem** Ereignis ausgewerteten Strecke.
    ///
    /// Sie ist die Zusage „ein einzelnes normales Systemereignis lässt
    /// den Ausschnitt nie springen": Mehr als ein halber
    /// Verdopplungsschritt, also Faktor `2^0,5 ≈ 1,414`, kommt aus einem
    /// Ereignis nicht heraus. Die Grenze ist **symmetrisch**, weil der
    /// Faktor multiplikativ ist -- anders als die frühere affine
    /// Rechnung, deren Grenzen `1,4` und `0,6` keine Kehrwerte waren.
    public static let maximumScrollPointsPerEvent: Double = 60

    /// Untere Schranke des Faktors eines **einzelnen** Pinch-Ereignisses.
    public static let minimumPinchFactor: Double = 0.5
    /// Obere Schranke des Faktors eines **einzelnen** Pinch-Ereignisses
    /// -- siehe ``minimumPinchFactor``; beide sind Kehrwerte.
    public static let maximumPinchFactor: Double = 2

    /// Die Scrollstrecke eines Ereignisses in **Punkten**, in
    /// Geräterichtung und auf ``maximumScrollPointsPerEvent`` begrenzt.
    ///
    /// Positiv heißt „vom Bedienenden weg geschoben" und zoomt hinein.
    /// `nil` bei nicht endlicher Eingabe -- der Aufrufer macht das
    /// sichtbar, statt einen Ersatzwert zu erfinden.
    public static func scrollDistanceInPoints(for event: ScanFieldScrollEvent) -> Double? {
        guard event.deltaY.isFinite else { return nil }
        let deviceMotion = event.isDirectionInvertedFromDevice ? -event.deltaY : event.deltaY
        let points = event.hasPreciseDeltas ? deviceMotion : deviceMotion * pointsPerWheelLine
        return points.clamped(
            to: -maximumScrollPointsPerEvent...maximumScrollPointsPerEvent
        )
    }

    /// Zoomfaktor einer Scrollstrecke in Punkten -- **multiplikativ**,
    /// siehe Regel 1.
    ///
    /// Die Begrenzung steht auch hier, damit die Funktion für sich
    /// genommen total ist und nicht darauf baut, dass ein Aufrufer vorher
    /// begrenzt hat.
    public static func zoomFactor(forScrollDistanceInPoints distance: Double) -> Double? {
        guard distance.isFinite else { return nil }
        let limited = distance.clamped(
            to: -maximumScrollPointsPerEvent...maximumScrollPointsPerEvent
        )
        return exp2(limited / scrollPointsPerDoubling)
    }

    /// Zoomfaktor eines rohen Scrollereignisses -- die Verkettung der
    /// beiden Schritte darüber.
    public static func zoomFactor(for event: ScanFieldScrollEvent) -> Double? {
        guard let distance = scrollDistanceInPoints(for: event) else { return nil }
        return zoomFactor(forScrollDistanceInPoints: distance)
    }

    /// Zoomfaktor eines Trackpad-Pinch.
    ///
    /// `NSEvent.magnification` ist laut Apple die **Änderung** des
    /// Maßstabs, der Faktor also `1 + magnification` -- das bleibt
    /// unverändert die dokumentierte Bedeutung der Systemschnittstelle
    /// und wird hier bewusst **nicht** durch eine eigene Kennlinie
    /// ersetzt. Je Ereignis liegt der Wert im Bereich weniger Promille
    /// bis weniger Prozent; der dadurch verbleibende Unterschied zu einer
    /// exakt umkehrbaren Rechnung liegt unter `1e-4` je Ereignis und ist
    /// keine erkennbare Bedienwirkung.
    ///
    /// Geklammert wird trotzdem: Ein einzelnes Ereignis darf den
    /// Ausschnitt nicht springen lassen, und ein Faktor `<= 0` (bei
    /// `magnification <= -1`) hat keine Bedeutung.
    public static func zoomFactor(forMagnification magnification: Double) -> Double? {
        guard magnification.isFinite else { return nil }
        return (1 + magnification).clamped(to: minimumPinchFactor...maximumPinchFactor)
    }
}
