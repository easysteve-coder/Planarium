import PlanariumDomain
import SickPLSCore
import SickPLSControlCore

/// „Messung einpassen" -- der Ausschnitt, der das **tatsächlich
/// empfangene** Profil sichtbar macht (SICK-032b2, seit SICK-032b2c
/// **planar**).
///
/// ## Warum es das gibt
///
/// Die Darstellung ist seit SICK-032b1 in beiden Achsen linear. Die
/// einzigen real gemessenen Rohwerte dieses Projekts liegen bei ≈ 21…169
/// von 8191 (SICK-012, **eine** Sitzung) und füllen damit ≈ 0,26…2,06 %
/// des Radius. Ein **fester** Start-Ausschnitt, der das ausgliche, wäre
/// eine Kalibrierungsvermutung aus einer einzigen Messsitzung -- genau
/// das, was SICK-032b1 ausdrücklich abgelehnt hat.
///
/// Dieser Typ macht stattdessen etwas anderes: Er liest **die Messung,
/// die gerade vorliegt**, und leitet den Ausschnitt daraus ab. Das ist
/// keine Annahme über das Gerät, sondern eine Aussage über die Daten.
///
/// ## Explizit entschiedene Semantik seit SICK-032b2c
///
/// Bis SICK-032b2c änderte „Einpassen" **nur die Entfernungsachse** und
/// ließ den gerade gewählten Winkelbereich unangetastet -- unter dem
/// **isotropen** planaren Ausschnitt (``ScanPlaneViewport``, eine einzige
/// Skalierung für beide Achsen) lässt sich das nicht mehr ausdrücken: Ein
/// Profil deckt den Winkel stets vollständig ab, und ein Einpassen, das
/// **alle** Messpunkte einschließt, würde von der Winkelspreizung
/// dominiert (Weltbreite bis zu `2`) und bliebe damit fast auf der
/// Gesamtansicht stehen -- der Entfernungsanteil (bei den real
/// gemessenen Werten nur ≈ `0,02`) ginge unter. Das ist genau die vom
/// Auftrag verlangte Entscheidung „begründe und entscheide es explizit,
/// statt unbemerkt polar zurückzufallen".
///
/// **Die neue Regel:** Einpassen zoomt **isotrop um den Fächerursprung**
/// (``ScanPlaneViewport/centerX``/``centerY`` bleiben `0`) auf eine
/// Halbkantenlänge, die den **am weitesten entfernten** brauchbaren
/// Messpunkt mit Rand einschließt. Da jeder Feldpunkt in der kanonischen
/// Welt `max(|x|, |y|) <= radiusFraction` erfüllt (weil `|cos|, |sin| <=
/// 1`), schließt das **jeden** brauchbaren Punkt ein, unabhängig von
/// seinem Winkel -- und weil die real gemessenen Werte durchweg nahe am
/// Ursprung liegen, zoomt das genau dorthin, wo der Inhalt tatsächlich
/// ist. Der bisherige Winkelbereich wird dabei nicht erhalten; das ist
/// eine bewusste Änderung, siehe ``viewport(fitting:within:)``.
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// 1. **Nur lesen.** Dieser Typ verändert kein Profil, keine ``Zone``,
///    kein Learn-Ergebnis, kein Mapping und keine Audiosteuerung. Er
///    liefert einen Ausschnitt und sonst nichts -- der Ausschnitt bleibt
///    eine reine Ansichtseinstellung
///    (`.agent_handoff/scanfield-ui-requirements.md`).
/// 2. **Kein zweiter Gültigkeitsweg.** Der Ausschnitt entsteht über das
///    bestehende Werkzeug
///    ``ScanPlaneViewport/zoomedToRectangle(xA:xB:yA:yB:)``
///    und **nicht** über ``ScanPlaneViewport/build(centerX:centerY:halfExtent:)``.
///    So entscheidet weiterhin genau eine Stelle, was ein gültiger
///    Ausschnitt ist, und es gibt genau einen Ablehnungsweg.
/// 3. **Kein Ersatzwert.** Liegt kein Profil vor oder enthält es keinen
///    brauchbaren Messwert, wird **verweigert**. Ein ausgedachter
///    Ausschnitt wäre wieder die Kalibrierungsvermutung.
public enum ScanFieldFit {

    /// Kleinster Rohwert, der als echte Messung in die Einpassung
    /// eingeht.
    ///
    /// `0` und `8191` bleiben außen vor -- **dieselbe** Gültigkeitsgrenze,
    /// die der Lernvertrag seit SICK-030c benutzt. Es gibt bewusst keine
    /// zweite Vorstellung davon, was ein brauchbarer Messwert ist. Ein
    /// einzelner Ausreißer an der Bereichsgrenze (typischerweise „kein
    /// Echo") würde die Einpassung sonst auf das ganze Feld aufziehen und
    /// damit genau das verhindern, wofür sie da ist.
    public static let lowestUsableRawValue = UsableRawDistance.lowestRawValue
    /// Größter Rohwert, der als echte Messung eingeht -- siehe
    /// ``lowestUsableRawValue``.
    public static let highestUsableRawValue = UsableRawDistance.highestRawValue

    /// Relativer Rand um die eingepasste Spanne, je Seite.
    ///
    /// **Eine Darstellungsentscheidung, keine Gerätewahrheit** (dieselbe
    /// Kennzeichnung wie `GatePolicy.standard`): Ohne Rand lägen der
    /// nächste und der fernste Messpunkt exakt auf der Kante des
    /// sichtbaren Bereichs, und eine kleine Bewegung fiele sofort aus dem
    /// Bild.
    public static let marginFraction: Double = 0.1

    /// Warum nicht eingepasst werden konnte -- **zwei benannte Lagen**,
    /// nie zusammengefasst: „es liegt gar keine Messung vor" ist etwas
    /// anderes als „die Messung enthält nichts Brauchbares".
    public enum Refusal: Equatable, Sendable {
        /// Es ist noch kein Profil empfangen worden.
        case noProfile
        /// Das Profil enthält keinen Messwert zwischen
        /// ``lowestUsableRawValue`` und ``highestUsableRawValue``.
        case noUsableMeasurement
        /// Der abgeleitete Ausschnitt wurde vom Werkzeug abgelehnt.
        /// Strukturell kaum erreichbar (der Rand hält die Spanne über der
        /// Mindestspanne), aber ehrlicher als ein erzwungener Wert.
        case windowRejected(ScanPlaneViewportRejection)
    }

    /// Ergebnis einer Einpassung.
    public struct Result: Equatable, Sendable {
        /// Der neue Ausschnitt.
        public let viewport: ScanPlaneViewport
        /// Wie viele Messpunkte die Einpassung getragen haben.
        public let usedMeasurementCount: Int
        /// Wie viele Messpunkte als unbrauchbar übergangen wurden --
        /// sichtbar gezählt statt still verschwiegen.
        public let ignoredMeasurementCount: Int
    }

    /// Das Ergebnis, geschlossen: `switch` ohne `default` zwingt jeden
    /// Aufrufer, die Verweigerung zu behandeln, statt sie als `nil`
    /// mitlaufen zu lassen.
    public enum Outcome: Equatable, Sendable {
        case fitted(Result)
        case refused(Refusal)
    }

    /// Leitet aus einem **echten** Profil den Ausschnitt ab, der es
    /// sichtbar macht.
    ///
    /// **Isotrop um den Fächerursprung, nach dem am weitesten entfernten
    /// brauchbaren Messpunkt** -- die oben begründete, seit SICK-032b2c
    /// explizit entschiedene Ersatzsemantik für „nur die Entfernungsachse
    /// ändern" unter dem planaren, isotropen Ausschnitt.
    ///
    /// Gerechnet wird über **alle** Messpunkte des Profils, nicht nur
    /// über einen sichtbaren Ausschnitt: Sonst hinge das Ergebnis an zwei
    /// Dingen gleichzeitig und wäre nicht mehr vorhersagbar. `current`
    /// dient nur noch als Empfänger des Werkzeugaufrufs (Regel 2) -- das
    /// Ergebnis ist unabhängig davon, welcher Ausschnitt vorher galt.
    public static func viewport(fitting profile: B0ScanProfile?, within current: ScanPlaneViewport) -> Outcome {
        guard let profile else { return .refused(.noProfile) }

        var highestRaw = UInt16.min
        var used = 0
        for measurement in profile.measurements {
            // `fieldFlags` werden hier bewusst **nicht** gedeutet --
            // dieselbe Haltung wie im Lernvertrag (SICK-030c).
            guard measurement.value >= lowestUsableRawValue,
                  measurement.value <= highestUsableRawValue else { continue }
            highestRaw = Swift.max(highestRaw, measurement.value)
            used += 1
        }
        guard used > 0 else { return .refused(.noUsableMeasurement) }

        let farFraction = Double(highestRaw) / PolarProfileGeometry.maxRawMeasurementValue
        // Der Rand ist relativ zur Spanne, hat aber eine untere Schranke:
        // Ein einzelner brauchbarer Punkt (Spanne `0`) bekäme sonst
        // überhaupt keinen sichtbaren Rand.
        let margin = Swift.max(farFraction * marginFraction, ScanPlaneViewport.minimumHalfExtent)
        let target = farFraction + margin

        let change = current.zoomedToRectangle(xA: -target, xB: target, yA: -target, yB: target)
        switch change {
        case .applied(let viewport):
            return .fitted(Result(
                viewport: viewport,
                usedMeasurementCount: used,
                ignoredMeasurementCount: profile.measurements.count - used
            ))
        case .rejected(let rejection):
            return .refused(.windowRejected(rejection))
        }
    }
}
