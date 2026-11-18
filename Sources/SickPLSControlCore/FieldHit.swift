import SickPLSCore

/// Ein einzelner **gemessener Treffer** eines Profils (SICK-033d): der
/// Messpunkt, wie ihn jede Feld- und Zonenauswertung sieht.
///
/// Trägt genau das, was der Roadmap-Vertrag verlangt -- normierten
/// Messpunktindex, linearen Rohwert, die rohen `field_flags` und eine
/// **stabile Reihenfolge** --, und nichts, was gedeutet wäre: Der Rohwert
/// besitzt inzwischen die belegte PLS-Einheit Zentimeter, aber noch keinen
/// unterstellten Winkel und keine Bedeutung der Flags.
public struct FieldHit: Equatable, Sendable {
    /// Empfangsreihenfolge im Profil, `0` für den ersten Messpunkt.
    /// **Stabil**: zwei Treffer desselben Profils sind über `order`
    /// eindeutig geordnet, unabhängig von Wert oder Index.
    public let order: Int
    /// Normierter Index `0...1` nach derselben Konvention wie
    /// `Zone.indexFraction(forIndex:count:)`.
    public let normalizedIndex: Double
    /// Roher 13-Bit-Messwert; beim PLS zugleich Zentimeterdistanz.
    public let rawValue: UInt16
    public var distanceCentimeters: UInt16 { rawValue }
    public var distanceMeters: Double { Double(rawValue) / 100.0 }
    /// Rohe 3-Bit-`field_flags`, unmodelliert durchgereicht.
    public let fieldFlags: UInt8

    /// Schlägt fehl, wenn `rawValue` keine gemessene Fläche bezeichnet.
    /// Die Gültigkeit ist damit Typinvariante und nicht Höflichkeit des
    /// Aufrufers: einen Treffer mit `0` oder `8191` gibt es nicht.
    public init?(order: Int, normalizedIndex: Double, rawValue: UInt16, fieldFlags: UInt8) {
        guard UsableRawDistance.contains(rawValue) else { return nil }
        self.order = order
        self.normalizedIndex = normalizedIndex
        self.rawValue = rawValue
        self.fieldFlags = fieldFlags
    }
}

/// Die **geordnete Trefferfolge** eines Profils -- der eine Eingang, aus
/// dem Zonen und spätere Felder ihren Wert ziehen. Wird **einmal je
/// Profil** gebaut und an alle Auswertungen gereicht; es gibt keinen
/// zweiten Weg vom Profil zum Steuerwert.
public struct FieldHitSequence: Equatable, Sendable {
    public let hits: [FieldHit]

    /// Baut die Folge in Empfangsreihenfolge. Dynamische Punktzahl ist
    /// Pflicht; nichts nimmt `90` oder eine andere feste Zahl an.
    /// Unbrauchbare Messungen (`0`, `8191`) scheiden hier aus; die übrigen
    /// behalten ihre Reihenfolge, ihren Geräteindex, Rohwert und Flags.
    public init(profile: B0ScanProfile) {
        let count = profile.measurements.count
        var hits: [FieldHit] = []
        hits.reserveCapacity(count)
        for (index, measurement) in profile.measurements.enumerated() {
            // `order` und `normalizedIndex` stammen weiter aus der
            // **ursprünglichen** Punktzahl. Ein übersprungener Messpunkt
            // verschiebt die Winkellage der übrigen nicht.
            guard let hit = FieldHit(
                order: index,
                normalizedIndex: Zone.indexFraction(forIndex: index, count: count),
                rawValue: measurement.value,
                fieldFlags: measurement.fieldFlags
            ) else { continue }
            hits.append(hit)
        }
        self.hits = hits
    }

    /// Für Tests und synthetische Felder: eine vorgegebene Folge. Die
    /// Reihenfolge wird **nicht** umsortiert; `order` bleibt, wie
    /// übergeben.
    public init(hits: [FieldHit]) {
        self.hits = hits
    }

    public var isEmpty: Bool { hits.isEmpty }
}

/// Die **sichtbare, geschlossene Politik**, nach der ein Feld aus
/// mehreren passenden Treffern genau **einen** effektiven wählt
/// (Owner-Vorgabe vor SICK-033d: ein deterministisch gewählter Treffer
/// je Feld; kein Mehrhand-Tracking).
public enum HitSelectionPolicy: String, Equatable, Sendable, CaseIterable {
    /// **Kleinster Rohwert gewinnt** („nächste erkannte Fläche"); bei
    /// gleichem Rohwert der Treffer mit der kleinsten `order`. Das ist
    /// bitgleich die Regel, nach der `Zone.evaluate` seit SICK-013
    /// arbeitet.
    case nearestSurface

    /// Wählt aus `hits` in gegebener Reihenfolge. Leer ergibt `nil`.
    public func select(from hits: [FieldHit]) -> FieldHit? {
        switch self {
        case .nearestSurface:
            var best: FieldHit?
            for hit in hits {
                if let current = best, hit.rawValue >= current.rawValue { continue }
                best = hit
            }
            return best
        }
    }
}

extension Zone {
    /// Die Politik jeder Zone. Bewusst **eine** Konstante und kein Feld:
    /// Eine Zone hat keine zweite Trefferregel.
    public static let hitSelectionPolicy: HitSelectionPolicy = .nearestSurface

    /// Ob ein Treffer in Index- **und** Wertebereich der Zone liegt
    /// (beide Grenzen inklusiv).
    public func contains(_ hit: FieldHit) -> Bool {
        indexRange.contains(hit.normalizedIndex) && valueRange.contains(hit.rawValue)
    }

    /// Alle passenden Treffer in Empfangsreihenfolge.
    public func hits(in sequence: FieldHitSequence) -> [FieldHit] {
        sequence.hits.filter(contains)
    }

    /// Der **eine** effektive Treffer nach ``hitSelectionPolicy``, oder
    /// `nil`, wenn kein Treffer passt. Streamt über die Folge, ohne
    /// die Zwischenliste zu bauen -- dasselbe Ergebnis wie
    /// `Zone.hitSelectionPolicy.select(from: hits(in:))`.
    public func effectiveHit(in sequence: FieldHitSequence) -> FieldHit? {
        switch Self.hitSelectionPolicy {
        case .nearestSurface:
            var best: FieldHit?
            for hit in sequence.hits where contains(hit) {
                if let current = best, hit.rawValue >= current.rawValue { continue }
                best = hit
            }
            return best
        }
    }

    /// Normiert den Rohwert eines Treffers auf `0...1` über den
    /// Wertebereich der Zone. **Exakt** die Rechnung von SICK-013:
    /// `(roh − unten) / (oben − unten)` in `Double`.
    public func normalizedValue(of hit: FieldHit) -> Double {
        let span = Double(valueRange.upperBound) - Double(valueRange.lowerBound)
        return (Double(hit.rawValue) - Double(valueRange.lowerBound)) / span
    }

    /// Die Bewertung aus der bereits gebauten Trefferfolge -- **die eine
    /// Auswertung** (SICK-033d-1). `evaluate(against:)` leitet sich
    /// daraus ab.
    public func evaluate(hits sequence: FieldHitSequence) -> ZoneEvaluationResult {
        guard let hit = effectiveHit(in: sequence) else { return .inactive }
        return .controlValue(normalizedValue(of: hit))
    }
}
