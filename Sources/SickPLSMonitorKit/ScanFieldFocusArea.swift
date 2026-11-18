import PlanariumDomain
import SickPLSCore
import SickPLSControlCore

/// Der für die Anzeige **relevante Rohwertbereich** eines echten Profils
/// -- robust gegen einzelne Ausreißer -- und die dazugehörige planare
/// Fokusgeometrie (SICK-032c3a, `.agent_handoff/task-sick-032c3a.md`
/// Abschnitt 2).
///
/// ## Warum das ein eigener Typ ist, und ``ScanFieldFit`` unangetastet bleibt
///
/// ``ScanFieldFit`` (SICK-032b2/032b2c) nimmt bewusst den **weitesten**
/// brauchbaren Rohwert als Ausschnittsgrenze -- richtig für „Messung
/// einpassen" auf ein bereits gutmütiges echtes Profil, aber **nicht
/// robust**: Ein einzelner, an sich gültiger, aber weit entfernter
/// Ausreißer (ein Fehlecho, ein Objekt am Bildrand) zöge den Ausschnitt
/// bis fast auf die Gesamtansicht auf, obwohl der eigentliche
/// Arbeitsbereich kompakt bleibt (SICK-012: `21...169`). Beim Anlegen
/// einer neuen Zone -- wo noch niemand weiß, ob ein Wert Rauschen oder
/// Absicht ist -- wäre das irreführend. Dieser Typ bleibt deshalb
/// eigenständig, statt ``ScanFieldFit`` robuster (und für seinen
/// bestehenden, bereits abgenommenen Anwendungsfall komplizierter) zu
/// machen; die vorhandenen Tests zu ``ScanFieldFit`` dienen hier
/// zusätzlich als **Gegenprobe**: Was diese Datei robust ausschließt,
/// zöge ``ScanFieldFit`` auf dieselben Daten sichtbar auf.
///
/// ## Die robuste Ausreißerregel
///
/// 1. Nur Werte in ``ScanFieldFit/lowestUsableRawValue``...
///    ``ScanFieldFit/highestUsableRawValue`` gehen ein -- **dieselbe**
///    Gültigkeitsgrenze wie bei „Messung einpassen" und im Lernvertrag
///    seit SICK-030c, keine zweite Vorstellung davon, was ein
///    brauchbarer Messwert ist.
/// 2. Median und **MAD** (Median der absoluten Abweichungen vom
///    Median) der brauchbaren Werte bestimmen eine Schwelle:
///    `MAD * `` outlierDeviationMultiplier``. Ein Wert, dessen Abstand
///    zum Median diese Schwelle übersteigt, zählt als Ausreißer und
///    trägt **nicht** zum Bereich bei -- wird aber sichtbar mitgezählt
///    (``Result/ignoredAsOutlierCount``), nie stillschweigend
///    verschluckt.
/// 3. **MAD `0` heißt "keine Mehrheitsstreuung", nicht "alles tragen":**
///    Liegt die Mehrheit der brauchbaren Werte exakt auf dem Median (MAD
///    `0`), fällt die Schwelle auf die **mittlere** Abweichung vom
///    Median zurück (`meanAD`) -- ein einzelner ferner Wert trägt zu
///    seinem eigenen Mittel nur mit `1/n` bei und bleibt bei einer
///    hinreichend großen Stichprobe deutlich über der daraus
///    abgeleiteten Schwelle, fällt also selbst heraus (SICK-032c3a-K1,
///    Abnahmeblocker 1: die vorherige pauschale `MAD == 0 -> infinity`-
///    Regel trug auch einen klar isolierten fernen Wert, sobald die
///    Mehrheit exakt gleich war -- `89 x 100` plus ein gültiger Wert
///    `6000` zog den Bereich bis nahe `6000` auf statt kompakt um `100`
///    zu bleiben). **Kleine Stichproben bleiben dabei weiterhin
///    vollständig erhalten:** Sind auch alle Abweichungen `0` (ein
///    einzelner Wert, eine identische Zweierprobe, oder eine wirklich
///    konstante Menge), ist `meanAD` ebenfalls `0` -- dann gibt es
///    keinen abweichenden Wert, den eine Schwelle ausschließen könnte,
///    und sie bleibt unendlich. Der Median selbst liegt außerdem immer
///    innerhalb jeder positiven Schwelle -- die Trägermenge ist deshalb
///    strukturell nie leer.
/// 4. Auf die Spanne der Trägerwerte (plus, sobald vorhanden, die
///    Grenzen einer Learn-Kandidatin) kommt ein **relativer** Rand
///    (``marginFraction``) mit einer **absoluten** Untergrenze
///    (``minimumPaddingRawValue``) -- ohne die läge ein einzelner
///    brauchbarer Wert (Spanne `0`) exakt auf der Kante. Danach wird auf
///    die **fachliche Mindestspanne** (``minimumValueSpan``) erweitert,
///    falls nötig.
///
/// Alle vier Zahlen sind **dokumentierte Darstellungsentscheidungen,
/// keine Gerätewahrheit** -- dieselbe Kennzeichnung wie
/// `ZoneLearningConfiguration.default` und `ScanFieldFit.marginFraction`.
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// 1. **Nur lesen.** Wie ``ScanFieldFit``: kein Profil, keine ``Zone``,
///    kein Learn-Ergebnis, keine Audiosteuerung wird hier verändert --
///    dieser Typ liefert einen Rohwertbereich und einen Ausschnitt und
///    sonst nichts.
/// 2. **Kein zweiter Gültigkeitsweg** für den Ausschnitt: Wie
///    ``ScanFieldFit`` entsteht er über das bestehende Werkzeug
///    ``ScanPlaneViewport/zoomedToRectangle(xA:xB:yA:yB:)``, nicht über
///    ``ScanPlaneViewport/build(centerX:centerY:halfExtent:)``.
/// 3. **Kein Ersatzwert.** Ohne Profil oder ohne brauchbaren Messwert
///    wird **verweigert** -- nie ein ausgedachter Bereich.
public enum ScanFieldFocusArea {

    /// Dieselbe Gültigkeitsgrenze wie ``ScanFieldFit`` -- bewusst
    /// **referenziert**, nicht neu definiert (siehe Kopfkommentar).
    public static let lowestUsableRawValue = ScanFieldFit.lowestUsableRawValue
    public static let highestUsableRawValue = ScanFieldFit.highestUsableRawValue

    /// Relativer Rand um die getragene Spanne, je Seite -- dieselbe
    /// Größenordnung wie ``ScanFieldFit/marginFraction``.
    public static let marginFraction: Double = 0.1

    /// Absolute Untergrenze des Rands -- ohne sie bekäme eine Spanne von
    /// `0` (ein einzelner brauchbarer Wert überall im Profil) gar keinen
    /// sichtbaren Rand.
    public static let minimumPaddingRawValue: UInt16 = 5

    /// Fachliche Mindestspanne des relevanten Bereichs, in Rohwerten.
    public static let minimumValueSpan: UInt16 = 40

    /// Ab dem Wievielfachen des MAD ein Wert als Ausreißer gilt.
    ///
    /// `5` ist bewusst großzügig: Bei den real gemessenen Werten
    /// (SICK-012, `21...169`) liegt die gesamte Spanne deutlich
    /// innerhalb dieser Schwelle -- sie soll echte, weit entfernte
    /// Fehlmessungen ausschließen, nicht die normale Streuung einer
    /// bewegten Hand.
    public static let outlierDeviationMultiplier: Double = 5.0

    /// Warum kein relevanter Bereich entstand -- **zwei benannte
    /// Lagen**, wie bei ``ScanFieldFit/Refusal``: „gar keine Messung"
    /// ist etwas anderes als „keine brauchbare Messung darin".
    public enum Refusal: Equatable, Sendable {
        case noProfile
        case noUsableMeasurement
        case windowRejected(ScanPlaneViewportRejection)

        /// Verständliche Rückmeldung für ein ausdrückliches „Einpassen",
        /// das keinen relevanten Bereich fand (SICK-032c3b). **Der Text
        /// entsteht im Modell** -- dieselbe Regel wie bei
        /// ``ScanFieldNotice/message`` seit SICK-032b2.
        public var operatorText: String {
            switch self {
            case .noProfile:
                return "No profile received yet — nothing to fit."
            case .noUsableMeasurement:
                return "The current profile has no usable measurement. The viewport is unchanged."
            case .windowRejected:
                return "The relevant area could not be shown as a viewport. The viewport is unchanged."
            }
        }
    }

    /// Ergebnis einer Fokusableitung.
    public struct Result: Equatable, Sendable {
        /// Der relevante Rohwertbereich -- Scannerfachraum (Index/
        /// Rohwert), **keine** Meter- oder Distanzbehauptung.
        public let valueRange: ClosedRange<UInt16>
        /// Der Ausschnitt, der diesen Bereich zeigt.
        public let viewport: ScanPlaneViewport
        /// Wie viele Messpunkte den Bereich getragen haben.
        public let carriedMeasurementCount: Int
        /// Wie viele Messpunkte unbrauchbar waren (`0`/`8191`).
        public let ignoredAsUnusableCount: Int
        /// Wie viele brauchbare Messpunkte als Ausreißer galten und den
        /// Bereich deshalb **nicht** aufgezogen haben.
        public let ignoredAsOutlierCount: Int
    }

    /// Geschlossen, wie ``ScanFieldFit/Outcome`` -- kein Aufrufer soll
    /// eine Verweigerung als `nil` mitlaufen lassen.
    public enum Outcome: Equatable, Sendable {
        case focused(Result)
        case refused(Refusal)
    }

    /// Ob `profile` **überhaupt** einen brauchbaren Messwert trägt --
    /// eine schnelle Vorabfrage ohne die volle Berechnung, für
    /// Aufrufer, die nur wissen müssen, ob sich ein Fokus lohnen würde
    /// (siehe ``LearnFocusState/Input/measurementAvailable``).
    public static func hasUsableMeasurement(in profile: B0ScanProfile) -> Bool {
        profile.measurements.contains {
            $0.value >= lowestUsableRawValue && $0.value <= highestUsableRawValue
        }
    }

    /// Leitet aus einem **echten** Profil den relevanten Rohwertbereich
    /// und den dazugehörigen Ausschnitt ab.
    ///
    /// `candidate` schließt, sobald vorhanden, die Grenzen einer
    /// Learn-Kandidatin **mit ein** -- der Fokus darf aktuelle Messung
    /// und Kandidatin gemeinsam zeigen (Auftragstext); sie ist niemals
    /// als Ausreißer ausschließbar, weil sie kein Messwert, sondern ein
    /// bereits geprüfter fachlicher Wert ist.
    ///
    /// `current` dient nur als Empfänger des Werkzeugaufrufs (wie bei
    /// ``ScanFieldFit/viewport(fitting:within:)``) -- das Ergebnis ist
    /// unabhängig davon, welcher Ausschnitt vorher galt.
    public static func area(
        forProfile profile: B0ScanProfile?,
        candidate: Zone? = nil,
        within current: ScanPlaneViewport
    ) -> Outcome {
        guard let profile else { return .refused(.noProfile) }

        var usable: [UInt16] = []
        var ignoredUnusable = 0
        for measurement in profile.measurements {
            if measurement.value >= lowestUsableRawValue, measurement.value <= highestUsableRawValue {
                usable.append(measurement.value)
            } else {
                ignoredUnusable += 1
            }
        }
        guard !usable.isEmpty else { return .refused(.noUsableMeasurement) }

        let sorted = usable.sorted()
        let median = Self.median(of: sorted.map(Double.init))
        let deviations = sorted.map { abs(Double($0) - median) }
        let mad = Self.median(of: deviations.sorted())

        // Regel 3 im Kopfkommentar (SICK-032c3a-K1): MAD `0` fällt auf
        // die mittlere Abweichung zurück, statt die Schwelle pauschal
        // auf unendlich zu setzen -- das schließt einen isolierten
        // fernen Wert in einer größeren, sonst gleichen Menge robust
        // aus, während Einzelwert/Zweierprobe (dort ist auch `meanAD`
        // `0`) weiterhin vollständig erhalten bleiben.
        let threshold: Double
        if mad > 0 {
            threshold = mad * outlierDeviationMultiplier
        } else {
            let meanDeviation = deviations.reduce(0, +) / Double(deviations.count)
            threshold = meanDeviation > 0 ? meanDeviation * outlierDeviationMultiplier : Double.infinity
        }

        var inliers: [UInt16] = []
        var outlierCount = 0
        for value in sorted {
            if abs(Double(value) - median) <= threshold {
                inliers.append(value)
            } else {
                outlierCount += 1
            }
        }
        // Struktureller Sicherheitsnetz-Fall: Der Median selbst (bzw.
        // sein nächster Nachbar) hat Abstand `<= threshold` (`threshold
        // >= 0`), `inliers` ist deshalb nie leer.
        guard let inlierLower = inliers.min(), let inlierUpper = inliers.max() else {
            return .refused(.noUsableMeasurement)
        }

        var lower = Int(inlierLower)
        var upper = Int(inlierUpper)
        if let candidate {
            lower = Swift.min(lower, Int(candidate.valueRange.lowerBound))
            upper = Swift.max(upper, Int(candidate.valueRange.upperBound))
        }

        let span = upper - lower
        let padding = Swift.max(Int((Double(span) * marginFraction).rounded()), Int(minimumPaddingRawValue))
        lower = Swift.max(0, lower - padding)
        upper = Swift.min(Int(Zone.maxRawMeasurementValue), upper + padding)

        if upper - lower < Int(minimumValueSpan) {
            let deficit = Int(minimumValueSpan) - (upper - lower)
            upper = Swift.min(Int(Zone.maxRawMeasurementValue), upper + deficit)
            if upper - lower < Int(minimumValueSpan) {
                lower = Swift.max(0, upper - Int(minimumValueSpan))
            }
        }

        let valueRange = UInt16(lower)...UInt16(upper)

        // Dieselbe „am weitesten entfernten brauchbaren Punkt plus
        // Rand"-Rechnung wie ``ScanFieldFit`` -- angewandt auf die
        // bereits robuste, gepolsterte Obergrenze.
        let farFraction = Double(upper) / PolarProfileGeometry.maxRawMeasurementValue
        let viewportMargin = Swift.max(farFraction * marginFraction, ScanPlaneViewport.minimumHalfExtent)
        let target = farFraction + viewportMargin

        switch current.zoomedToRectangle(xA: -target, xB: target, yA: -target, yB: target) {
        case .applied(let viewport):
            return .focused(Result(
                valueRange: valueRange,
                viewport: viewport,
                carriedMeasurementCount: inliers.count,
                ignoredAsUnusableCount: ignoredUnusable,
                ignoredAsOutlierCount: outlierCount
            ))
        case .rejected(let rejection):
            return .refused(.windowRejected(rejection))
        }
    }

    /// Median einer **bereits aufsteigend sortierten** `Double`-Folge.
    private static func median(of sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let count = sortedValues.count
        if count % 2 == 1 { return sortedValues[count / 2] }
        return (sortedValues[count / 2 - 1] + sortedValues[count / 2]) / 2
    }
}
