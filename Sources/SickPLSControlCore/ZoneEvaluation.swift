import SickPLSCore

/// Ergebnis der Bewertung einer ``Zone`` gegen ein echtes
/// `B0ScanProfile` -- ausschließlich ein normierter Steuerwert
/// `0...1` oder `inactive`, nie ein MIDI-/Noten-/Frequenz-/Audiowert
/// (SICK-013-Auftrag: „eine Zonenbewertung erzeugt nur normierte
/// Steuerwerte 0...1 oder inactive, ohne MIDI, Noten, Frequenzen oder
/// Audio auszugeben").
public enum ZoneEvaluationResult: Equatable, Sendable {
    /// Normierter Steuerwert, `0...1` -- `0.0` entspricht
    /// `zone.valueRange.lowerBound`, `1.0` entspricht
    /// `zone.valueRange.upperBound` des ausgewählten Messpunkts.
    case controlValue(Double)
    /// Kein Messpunkt lag sowohl im Index- als auch im Wertebereich der
    /// Zone.
    case inactive
}

extension Zone {
    /// Bewertet diese Zone ausschließlich anhand des **echten,
    /// übergebenen** `profile` -- kein Schätzer, keine Vorhersage, kein
    /// Zustand zwischen zwei Aufrufen (SICK-013-Auftrag: „kein
    /// Schätzer/keine Vorhersage: jede Bewertung beruht nur auf dem
    /// echten, übergebenen B0-Profil"). ``Zone`` selbst hat keine
    /// veränderlichen Eigenschaften -- eine reine Funktion: derselbe
    /// `profile`-Wert ergibt bei jedem Aufruf exakt dasselbe Ergebnis,
    /// unabhängig davon, welches Profil zuvor bewertet wurde.
    ///
    /// **Auswahlregel bei mehreren Treffern** (SICK-013-Auftrag,
    /// dokumentiert und testbar): Von allen Messpunkten, deren
    /// Indexanteil in ``indexRange`` **und** deren Rohwert in
    /// ``valueRange`` liegt, gewinnt der mit dem **kleinsten Rohwert**
    /// („nächste erkannte Fläche"). Haben mehrere passende Punkte
    /// denselben kleinsten Rohwert, ist das Ergebnis ohnehin identisch
    /// -- der Steuerwert hängt nur vom gewonnenen Rohwert ab, nie davon,
    /// an welchem Index er lag; eine zusätzliche Tie-Break-Ebene ist
    /// deshalb nicht nötig, um Eindeutigkeit zu garantieren. Kein
    /// passender Punkt ergibt ``ZoneEvaluationResult/inactive``.
    ///
    /// Dynamische Punktzahl ist Pflicht: `profile.measurements.count`
    /// wird nie als `90` oder sonst eine feste Zahl angenommen.
    ///
    /// **Seit SICK-033d eine Ableitung**: Das Profil wird zur
    /// ``FieldHitSequence``, und ``evaluate(hits:)`` ist die eine
    /// Auswertung. Ergebnis bitgleich zur Fassung von SICK-013 (belegt in
    /// `FieldHitTests`).
    public func evaluate(against profile: B0ScanProfile) -> ZoneEvaluationResult {
        evaluate(hits: FieldHitSequence(profile: profile))
    }

    /// `0` für den ersten, `1` für den letzten Index eines Profils mit
    /// mindestens zwei Punkten; `0.5` für ein Profil mit genau einem
    /// Punkt (kein sinnvoller „letzter" Index sonst, keine Division
    /// durch `count - 1 == 0`) -- dieselbe Konvention wie
    /// `SickPLSMonitorKit.PolarProfileGeometry.angleFraction(forIndex:
    /// count:)`, hier unabhängig neu implementiert (siehe Typkommentar
    /// auf ``Zone``: keine Abhängigkeit auf ein UI-nahes Modul).
    static func indexFraction(forIndex index: Int, count: Int) -> Double {
        guard count > 1 else { return 0.5 }
        return Double(index) / Double(count - 1)
    }
}

extension Sequence where Element == Zone {
    /// Bewertet jede Zone unabhängig gegen dasselbe `profile` --
    /// überlappende Zonen liefern absichtlich unabhängige Ergebnisse,
    /// keine implizite Priorität zwischen ihnen (SICK-013-Auftrag:
    /// „Überlappende Zonen sind zulässig und liefern voneinander
    /// unabhängige Steuerwerte; keine implizite Priorität").
    public func evaluating(against profile: B0ScanProfile) -> [ZoneEvaluationResult] {
        map { $0.evaluate(against: profile) }
    }
}
