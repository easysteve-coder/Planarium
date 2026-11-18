import CoreGraphics
import SickPLSControlCore

/// Die vier Griffe einer Zone im Fächer (SICK-030b2, Review-Befund
/// **N7**). Jeder Griff bewegt **genau eine** fachliche Grenze; welche,
/// steht hier und nur hier.
///
/// „Innen"/„außen" statt „unten"/„oben" beim Rohwert, weil der Rohwert im
/// Fächer als **Radius** erscheint: Die Rohwert-Untergrenze liegt näher
/// am Mittelpunkt, die Obergrenze weiter außen. Beim Index heißt es
/// weiterhin Unter-/Obergrenze, weil er als Winkel erscheint und dort
/// keine natürliche Innen/Außen-Lesart existiert.
public enum ZoneGeometryHandle: Hashable, Sendable, CaseIterable {
    /// Bewegt ausschließlich `Zone.indexRange.lowerBound`.
    case indexLowerBound
    /// Bewegt ausschließlich `Zone.indexRange.upperBound`.
    case indexUpperBound
    /// Bewegt ausschließlich `Zone.valueRange.lowerBound` (innen, kleiner
    /// Radius).
    case valueInnerBound
    /// Bewegt ausschließlich `Zone.valueRange.upperBound` (außen, großer
    /// Radius).
    case valueOuterBound
}

/// Was die laufende Geste tut -- entweder **ein** Griff oder die
/// **gesamte** Zone. Bewusst ein geschlossenes Enum statt eines
/// optionalen Griffs: „kein Griff" und „ganze Zone" wären sonst derselbe
/// Wert, und ein Aufrufer könnte den Unterschied übersehen.
public enum ZoneGeometryGesture: Equatable, Sendable {
    /// Verschiebt die gesamte Zone; Index- und Rohwertspanne bleiben
    /// erhalten, soweit die fachlichen Grenzen es zulassen.
    case moveWholeZone
    case handle(ZoneGeometryHandle)

    /// Alle möglichen Gesten -- `CaseIterable` synthetisiert das bei
    /// zugeordneten Werten nicht, und die Tests sollen erschöpfend über
    /// alle fünf laufen können.
    public static let allGestures: [ZoneGeometryGesture] =
        [.moveWholeZone] + ZoneGeometryHandle.allCases.map(ZoneGeometryGesture.handle)
}

/// Der **eingefrorene** Zustand beim Gestenbeginn (SICK-030b2,
/// Auftragspunkt 2 und FIRSTofFIFTH-Befund aus
/// `review-sick-030-architecture.md`: „Drag als Gesamt-`translation`
/// statt Delta-Akkumulation").
///
/// **Warum die Zone hier mitgeführt wird und nicht aus dem Modell gelesen
/// wird:** Der Reducer schreibt während der Geste fortlaufend nach
/// `zones[i].zone`. Läse er die Ausgangswerte jedes Mal von dort, wäre
/// jede Bewegung ein Delta auf dem bereits bewegten Stand — Rundungen
/// würden sich aufaddieren, und ein am Rand gestoppter Griff käme beim
/// Zurückziehen nicht an seinen Ausgangspunkt zurück. Mit dieser
/// Momentaufnahme ist das Ergebnis **allein** eine Funktion von
/// Ausgangszustand und aktuellem Zeigerpunkt.
public struct ZoneGeometryGestureStart: Equatable, Sendable {
    /// Die Zone, auf die sich die Geste bezieht.
    public let zoneID: EditableZone.ID
    /// Ihre Fachwerte **beim Gestenbeginn**, nicht der aktuelle Stand.
    public let zone: Zone
    /// Der Bildschirmpunkt, an dem die Geste begann.
    public let location: CGPoint

    public init(zoneID: EditableZone.ID, zone: Zone, location: CGPoint) {
        self.zoneID = zoneID
        self.zone = zone
        self.location = location
    }
}

/// Warum eine Geste **nicht** in Fachwerte übersetzt werden konnte.
/// Jeder Fall ist benannt; es gibt keinen stillen Rückfall auf
/// irgendeinen Ersatzwert (Auftragspunkt 4: „nie still falsche Fachwerte
/// bauen").
public enum ZoneGeometryRejection: Equatable, Sendable {
    /// Ein Gestenwert (Start- oder aktueller Punkt) war `NaN` oder
    /// unendlich.
    case nonFiniteGestureValue
    /// Die Fächergeometrie taugt nicht zum Zurückrechnen: kein oder
    /// nichtendlicher Radius, nichtendlicher Mittelpunkt oder ein
    /// Öffnungswinkel von null. ``FanScreenGeometry/fanCoordinate(forScreenPoint:)``
    /// liefert für diese Fälle bewusst neutrale Ersatzwerte (`0`/`0.5`) —
    /// für das **Zeichnen** ist das richtig, für eine **Bearbeitung**
    /// wäre es ein erfundener Fachwert, deshalb hier die Ablehnung.
    case degenerateFanGeometry
    /// Struktureller Sicherheitsnetz-Fall: Die geklammerten Grenzen
    /// ergaben trotz allem keine gültige `Zone`. Die Klammerung dieses
    /// Reducers soll das ausschließen — abstürzen oder eine falsche Zone
    /// schreiben soll er deswegen trotzdem nicht (dieselbe Haltung wie
    /// der defensive Verwurf in `StreamParser`, SICK-007).
    case degenerateResult
}

/// Ergebnis des reinen Reducers.
public enum ZoneGeometryOutcome: Equatable, Sendable {
    /// Die vollständige, bereits über `Zone.build(...)` geprüfte neue
    /// Zone — **kein** Delta, kein Entwurf.
    case updated(Zone)
    case rejected(ZoneGeometryRejection)
}

/// Reiner, SwiftUI-freier Reducer für die direkte Zonenbearbeitung im
/// Scanfeld (SICK-030b2, **seit SICK-032b3 vollständig linear**). Kennt
/// Fachwerte, Ansichtsgeometrie und Gestenwerte — **keine** `View`,
/// **keine** Geste des Systems, **keinen** Scanner, **keine** Audio- oder
/// Zuordnungslogik.
///
/// ## Was hier bewusst *nicht* passiert
///
/// - **Keine zweite Geometrieformel.** Bildschirm → Feldkoordinate läuft
///   ausschließlich über ``LinearScanFieldGeometry/fieldCoordinate(forScreenPoint:)``,
///   Feldkoordinate → Rohwert ausschließlich über die **lineare**
///   ``ZoneEditorGeometry/rawValue(fromRadiusFraction:)``.
/// - **Keine Anzeigekompression.** Die vierte Wurzel aus SICK-012b
///   (`PolarProfileGeometry.displayRadiusFraction`) kommt in diesem Weg
///   **nicht mehr** vor: Seit SICK-032b2 zeichnet die Ansicht linear
///   durch den Ausschnitt, und ein Griff muss dort liegen, wo die
///   Zonenfläche gezeichnet wird. Ein Quelltexttest hält das fest.
/// - **Keine Pixel-Mindestspanne.** Die Mindestausdehnung ist fachlich
///   (`ZoneDraft.minimumIndexSpan`/`minimumValueSpan`), sonst hinge die
///   Gültigkeit einer Zone von der Fenstergröße ab (Befund **N7** (1)).
///   Die Treffergröße eines Griffs in Punkten ist etwas anderes und liegt
///   in ``ZoneHandleGeometry``.
/// - **Kein Griff-Tausch.** Trifft ein Griff die Gegengrenze, **stoppt**
///   er; er springt nicht auf die andere Seite (Befund **N7** (2):
///   stoppen ist vorhersagbar und braucht keine Umsortierung).
/// - **Keine Aktivierung, keine Zuweisung, kein Gate.** Eine Geste ändert
///   ausschließlich die vier Grenzen einer Zone.
///
/// ## Die Empfindlichkeit hängt jetzt am Ausschnitt
///
/// Vor SICK-032b3 verzerrte die Anzeigekompression die Auflösung je nach
/// Entfernung. Linear ist ein Pixel überall gleich viele Rohwerte —
/// **wie viele**, entscheidet allein der gewählte Ausschnitt. Der real
/// beobachtete Wertebereich (≈ 21…169 von 8191, SICK-012) füllt in der
/// Gesamtansicht nur ≈ 2 % des Radius; dort ist eine Zone dieser
/// Größenordnung nicht fein bedienbar. Die Antwort darauf ist
/// „Messung einpassen" bzw. Zoom (SICK-032b2), nicht eine Verbiegung der
/// Skala; für exakte Eingaben gibt es weiterhin die Zahlenfelder des
/// Inspectors.
public enum ZoneGeometryReducer {

    /// Übersetzt den aktuellen Zeigerpunkt einer laufenden Geste in eine
    /// neue, gültige `Zone`.
    ///
    /// Gerechnet wird mit der **Gesamtverschiebung seit `start`**, in
    /// Fachwerten: Start- und aktueller Bildschirmpunkt werden je einmal
    /// in Index-/Rohwert übersetzt, und deren Differenz wandert auf die
    /// Grenzen der Ausgangszone. Das gilt für die ganze Zone **und** für
    /// einen einzelnen Griff — ein Griff folgt damit der Handbewegung,
    /// ohne beim Anfassen zu springen, falls jemand ihn nicht exakt
    /// mittig erwischt.
    public static func apply(
        _ gesture: ZoneGeometryGesture,
        from start: ZoneGeometryGestureStart,
        toScreenPoint location: CGPoint,
        in geometry: LinearScanFieldGeometry
    ) -> ZoneGeometryOutcome {
        guard isFinite(start.location), isFinite(location) else {
            return .rejected(.nonFiniteGestureValue)
        }
        guard geometry.isUsableForEditing,
              let from = fieldValues(of: start.location, in: geometry),
              let to = fieldValues(of: location, in: geometry) else {
            return .rejected(.degenerateFanGeometry)
        }

        let indexDelta = to.index - from.index
        let valueDelta = to.value - from.value

        let zone = start.zone
        let indexLower = zone.indexRange.lowerBound
        let indexUpper = zone.indexRange.upperBound
        let valueLower = Int(zone.valueRange.lowerBound)
        let valueUpper = Int(zone.valueRange.upperBound)

        let bounds: (indexLower: Double, indexUpper: Double, valueLower: Int, valueUpper: Int)

        switch gesture {
        case .moveWholeZone:
            let indexSpan = indexUpper - indexLower
            let valueSpan = valueUpper - valueLower
            // Die Untergrenze trägt die Verschiebung, die Obergrenze
            // folgt über die erhaltene Spanne -- so kann am Rand weder
            // etwas überlaufen noch die Zone umklappen oder schrumpfen.
            let newIndexLower = clamp(indexLower + indexDelta, 0, 1 - indexSpan)
            let newValueLower = clamp(valueLower + valueDelta, 0, maxRawValue - valueSpan)
            // Das `min` fängt den Gleitkommarest ab: `1 - spanne` und
            // `untergrenze + spanne` müssen sich nicht bitgenau zu `1`
            // ergänzen, und `Zone.build` lehnt `1.0000000000000002`
            // zu Recht ab.
            bounds = (
                newIndexLower, Swift.min(1, newIndexLower + indexSpan),
                newValueLower, Swift.min(maxRawValue, newValueLower + valueSpan)
            )

        case .handle(.indexLowerBound):
            // Stoppt an der Gegengrenze, springt nie darüber hinaus.
            let limit = max(0, indexUpper - ZoneDraft.minimumIndexSpan)
            bounds = (clamp(indexLower + indexDelta, 0, limit), indexUpper, valueLower, valueUpper)

        case .handle(.indexUpperBound):
            let limit = min(1, indexLower + ZoneDraft.minimumIndexSpan)
            bounds = (indexLower, clamp(indexUpper + indexDelta, limit, 1), valueLower, valueUpper)

        case .handle(.valueInnerBound):
            let limit = max(0, valueUpper - Int(ZoneDraft.minimumValueSpan))
            bounds = (indexLower, indexUpper, clamp(valueLower + valueDelta, 0, limit), valueUpper)

        case .handle(.valueOuterBound):
            let limit = min(maxRawValue, valueLower + Int(ZoneDraft.minimumValueSpan))
            bounds = (indexLower, indexUpper, valueLower, clamp(valueUpper + valueDelta, limit, maxRawValue))
        }

        guard let updated = try? Zone.build(
            indexLowerBound: bounds.indexLower,
            indexUpperBound: bounds.indexUpper,
            valueLowerBound: UInt16(bounds.valueLower),
            valueUpperBound: UInt16(bounds.valueUpper),
            role: zone.role
        ) else {
            return .rejected(.degenerateResult)
        }
        return .updated(updated)
    }

    // MARK: - Hilfen

    private static let maxRawValue = Int(Zone.maxRawMeasurementValue)

    /// Bildschirmpunkt -> Fachwerte, ausschließlich über die **lineare**
    /// Ansichtsgeometrie. `nil` bei entarteter Geometrie -- dieselbe
    /// Unterscheidung wie dort: zum Zeichnen ist ein Ersatzwert richtig,
    /// als Grundlage einer Bearbeitung wäre er ein erfundener Fachwert.
    private static func fieldValues(
        of point: CGPoint,
        in geometry: LinearScanFieldGeometry
    ) -> (index: Double, value: Int)? {
        guard let field = geometry.fieldCoordinate(forScreenPoint: point) else { return nil }
        return (
            index: ZoneEditorGeometry.indexFraction(fromAngleFraction: field.angleFraction),
            value: Int(ZoneEditorGeometry.rawValue(fromRadiusFraction: field.radiusFraction))
        )
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    /// Klammert und hält dabei auch eine **umgekehrte** Schranke aus
    /// (`upper < lower`) -- das kann bei einer bereits sehr schmalen
    /// Ausgangszone entstehen, und `ClosedRange` würde dann abstürzen.
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), Swift.max(lower, upper))
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        Swift.min(Swift.max(value, lower), Swift.max(lower, upper))
    }
}
