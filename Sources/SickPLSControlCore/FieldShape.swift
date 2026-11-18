/// Ein **diskreter Schritt** mit seinem Bezugsrahmen (SICK-033e): `value`
/// in `0...range`. Normiert ist er `value / range`; damit fällt ein
/// Tonartschritt `s` über der Domäne `0...60` exakt auf denselben
/// Steuerwert, den ein stetiger Pitch bei `s/60` hätte -- **eine**
/// Pitch-Domäne, keine zweite Rechnung.
public struct DiscreteStep: Equatable, Sendable {
    public let value: Int
    public let range: Int

    public init(value: Int, range: Int) {
        self.value = value
        self.range = range
    }

    /// `0...1`; `range == 0` ergibt `0` (eine einzelne Zelle).
    public var normalized: Double {
        guard range > 0 else { return 0 }
        return Double(value) / Double(range)
    }
}

/// Eine Tonart als Menge von Halbtonstufen je Oktave. Geschlossen; eine
/// Tonart außerhalb dieser Liste ist ein bewusster Erweiterungsschritt.
public enum MusicalScale: String, Equatable, Sendable, CaseIterable {
    case chromatic
    case major
    case naturalMinor
    case pentatonicMajor
    case pentatonicMinor

    /// Halbtonstufen innerhalb einer Oktave, aufsteigend, beginnend
    /// bei `0`.
    public var degrees: [Int] {
        switch self {
        case .chromatic: return Array(0..<12)
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .naturalMinor: return [0, 2, 3, 5, 7, 8, 10]
        case .pentatonicMajor: return [0, 2, 4, 7, 9]
        case .pentatonicMinor: return [0, 3, 5, 7, 10]
        }
    }
}

/// Die **Feldform** eines Ziels (SICK-033e): wie aus dem effektiven
/// Treffer der Zone ein Wert wird. Geschlossen -- Streifen, Raster,
/// Fächer, Tonartfeld; Vektorfelder sind laut Owner-Entscheidung vom
/// 23.09.2026 kein Releaseumfang.
///
/// **Alle Zellenwerte sind explizit** (Raster, Fächer) oder aus einer
/// benannten Regel abgeleitet (Tonart) und hängen nur vom normierten
/// Index und vom Rohwert des Treffers ab -- nie von Bildschirm, Zoom oder
/// Ausschnitt. Ein Viewportwechsel ändert keinen Wert.
public enum FieldShape: Equatable, Sendable {
    /// Der Streifen: stetiger Wert über den Wertebereich der Zone --
    /// bitgleich `Zone.evaluate`.
    case strip
    /// Raster `columns × rows` über Index × Wert mit einem expliziten
    /// Wert je Zelle.
    case grid(GridCells)
    /// Fächer: `sectors` Zellen über den Indexbereich mit explizitem
    /// Wert je Sektor.
    case fan(FanCells)
    /// Tonartfeld: Stufen einer Tonart über `octaves` Oktaven entlang
    /// des Indexbereichs; der Wert ist ein Halbtonversatz zur Grundnote
    /// der Pitch-Domäne.
    case key(KeyCells)

    public var kind: FieldShapeKind {
        switch self {
        case .strip: return .strip
        case .grid: return .grid
        case .fan: return .fan
        case .key: return .key
        }
    }

    /// Welchen Zieltyp diese Form erzeugt (ohne Gate-Rolle).
    public var targetKind: ControlTargetKind {
        switch self {
        case .strip: return .continuous
        case .grid, .fan, .key: return .discrete
        }
    }
}

/// Die Formen als Etikett, für Auswahl und Anzeige.
public enum FieldShapeKind: String, Equatable, Sendable, CaseIterable {
    case strip, grid, fan, key
}

/// Explizite Rasterzellen. `values.count == columns * rows`, Zeile für
/// Zeile (`values[row * columns + column]`); Spalten laufen über den
/// Index, Zeilen über den Wert (innen nach außen).
public struct GridCells: Equatable, Sendable {
    public enum BuildError: Error, Equatable {
        case dimensionNotPositive(columns: Int, rows: Int)
        case valueCountMismatch(expected: Int, actual: Int)
        case valueOutOfRange(Int, range: Int)
        case rangeNegative(Int)
    }

    public let columns: Int
    public let rows: Int
    public let values: [Int]
    /// Bezugsrahmen aller Zellenwerte, `values[i]` in `0...range`.
    public let range: Int

    private init(columns: Int, rows: Int, values: [Int], range: Int) {
        self.columns = columns
        self.rows = rows
        self.values = values
        self.range = range
    }

    public static func build(columns: Int, rows: Int, values: [Int], range: Int) throws -> GridCells {
        guard columns > 0, rows > 0 else { throw BuildError.dimensionNotPositive(columns: columns, rows: rows) }
        guard range >= 0 else { throw BuildError.rangeNegative(range) }
        guard values.count == columns * rows else {
            throw BuildError.valueCountMismatch(expected: columns * rows, actual: values.count)
        }
        for value in values where value < 0 || value > range {
            throw BuildError.valueOutOfRange(value, range: range)
        }
        return GridCells(columns: columns, rows: rows, values: values, range: range)
    }

    /// Ein Raster, dessen Zellen von links unten nach rechts oben
    /// durchzählen -- der Startwert des Editors.
    public static func counting(columns: Int, rows: Int) throws -> GridCells {
        let count = columns * rows
        return try build(columns: columns, rows: rows, values: Array(0..<max(count, 0)), range: max(count - 1, 0))
    }

    public func value(column: Int, row: Int) -> Int { values[row * columns + column] }
}

/// Explizite Fächersektoren über den Indexbereich.
public struct FanCells: Equatable, Sendable {
    public enum BuildError: Error, Equatable {
        case sectorsNotPositive(Int)
        case valueCountMismatch(expected: Int, actual: Int)
        case valueOutOfRange(Int, range: Int)
        case rangeNegative(Int)
    }

    public let values: [Int]
    public let range: Int
    public var sectors: Int { values.count }

    private init(values: [Int], range: Int) {
        self.values = values
        self.range = range
    }

    public static func build(values: [Int], range: Int) throws -> FanCells {
        guard !values.isEmpty else { throw BuildError.sectorsNotPositive(values.count) }
        guard range >= 0 else { throw BuildError.rangeNegative(range) }
        for value in values where value < 0 || value > range {
            throw BuildError.valueOutOfRange(value, range: range)
        }
        return FanCells(values: values, range: range)
    }

    public static func counting(sectors: Int) throws -> FanCells {
        guard sectors > 0 else { throw BuildError.sectorsNotPositive(sectors) }
        return try build(values: Array(0..<sectors), range: sectors - 1)
    }
}

/// Tonartzellen: die Stufen von `scale` über `octaves` Oktaven ab
/// `rootOffset` Halbtönen, als Halbtonversatz zur Grundnote der
/// Pitch-Domäne. `spanSemitones` ist der Bezugsrahmen der Domäne (Standard
/// 60); jede Zelle liegt in `0...spanSemitones`.
public struct KeyCells: Equatable, Sendable {
    public enum BuildError: Error, Equatable {
        case octavesNotPositive(Int)
        case rootOffsetNegative(Int)
        case spanNotPositive(Int)
        case cellsExceedSpan(highest: Int, spanSemitones: Int)
    }

    public let scale: MusicalScale
    public let octaves: Int
    public let rootOffset: Int
    public let spanSemitones: Int

    /// Der Standardumfang der Pitch-Domäne (A1 + 60 Halbtöne).
    public static let standardSpanSemitones = 60

    private init(scale: MusicalScale, octaves: Int, rootOffset: Int, spanSemitones: Int) {
        self.scale = scale
        self.octaves = octaves
        self.rootOffset = rootOffset
        self.spanSemitones = spanSemitones
    }

    public static func build(
        scale: MusicalScale,
        octaves: Int,
        rootOffset: Int = 0,
        spanSemitones: Int = standardSpanSemitones
    ) throws -> KeyCells {
        guard octaves > 0 else { throw BuildError.octavesNotPositive(octaves) }
        guard rootOffset >= 0 else { throw BuildError.rootOffsetNegative(rootOffset) }
        guard spanSemitones > 0 else { throw BuildError.spanNotPositive(spanSemitones) }
        let cells = KeyCells(scale: scale, octaves: octaves, rootOffset: rootOffset, spanSemitones: spanSemitones)
        if let highest = cells.values.last, highest > spanSemitones {
            throw BuildError.cellsExceedSpan(highest: highest, spanSemitones: spanSemitones)
        }
        return cells
    }

    /// Die expliziten Zellenwerte: je Oktave die Stufen, zum Schluss die
    /// Oktave über der letzten -- damit ein Feld über eine Oktave beide
    /// Grundtöne enthält.
    public var values: [Int] {
        var result: [Int] = []
        for octave in 0..<octaves {
            for degree in scale.degrees {
                result.append(rootOffset + octave * 12 + degree)
            }
        }
        result.append(rootOffset + octaves * 12)
        return result
    }

    public var range: Int { spanSemitones }
}

// MARK: - Zellenwahl

extension FieldShape {
    /// Zellenindex entlang einer normierten Lage `t` in `0...1` bei
    /// `count` Zellen -- die obere Grenze gehört zur letzten Zelle.
    /// Reine Ganzzahlrechnung auf dem Anteil; hängt nur von `t` ab.
    static func cellIndex(for t: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let index = Int((t * Double(count)).rounded(.down))
        return min(max(index, 0), count - 1)
    }

    /// Anteil eines Treffers innerhalb des Indexbereichs der Zone.
    static func indexFraction(of hit: FieldHit, in zone: Zone) -> Double {
        let span = zone.indexRange.upperBound - zone.indexRange.lowerBound
        return (hit.normalizedIndex - zone.indexRange.lowerBound) / span
    }
}

/// Ein **Feld**: die Zone (Region, Rolle, Trefferpolitik) mit ihrer
/// Form. **Die eine Auswertung** je Ziel.
public struct Field: Equatable, Sendable {
    public enum BuildError: Error, Equatable {
        /// Ein Gate ist stets ein Streifen: Zellen ergäben ein
        /// diskretes Gate, das es nicht gibt.
        case gateRequiresStrip
    }

    public let zone: Zone
    public let shape: FieldShape

    private init(zone: Zone, shape: FieldShape) {
        self.zone = zone
        self.shape = shape
    }

    public static func build(zone: Zone, shape: FieldShape) throws -> Field {
        if zone.role == .gate, shape != .strip { throw BuildError.gateRequiresStrip }
        return Field(zone: zone, shape: shape)
    }

    /// Der Streifen ist für jede Rolle gültig -- deshalb ohne `throws`.
    public static func strip(_ zone: Zone) -> Field {
        Field(zone: zone, shape: .strip)
    }

    /// Der typisierte Zielwert. Streifen und Gate laufen über
    /// `Zone.targetValue` (bitgleich SICK-013); Zellen über den
    /// effektiven Treffer -- dieselbe Politik, dieselbe Folge.
    public func targetValue(hits sequence: FieldHitSequence) -> ControlTargetValue? {
        switch shape {
        case .strip:
            return zone.targetValue(hits: sequence)
        case .grid(let cells):
            guard let hit = zone.effectiveHit(in: sequence) else { return nil }
            let column = FieldShape.cellIndex(for: FieldShape.indexFraction(of: hit, in: zone), count: cells.columns)
            let row = FieldShape.cellIndex(for: zone.normalizedValue(of: hit), count: cells.rows)
            return .discrete(DiscreteStep(value: cells.value(column: column, row: row), range: cells.range))
        case .fan(let cells):
            guard let hit = zone.effectiveHit(in: sequence) else { return nil }
            let sector = FieldShape.cellIndex(for: FieldShape.indexFraction(of: hit, in: zone), count: cells.sectors)
            return .discrete(DiscreteStep(value: cells.values[sector], range: cells.range))
        case .key(let cells):
            guard let hit = zone.effectiveHit(in: sequence) else { return nil }
            let values = cells.values
            let cell = FieldShape.cellIndex(for: FieldShape.indexFraction(of: hit, in: zone), count: values.count)
            return .discrete(DiscreteStep(value: values[cell], range: cells.range))
        }
    }
}
