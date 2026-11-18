import SickPLSControlCore

/// Editierbarer Zwischenzustand der Felder einer Zone -- eigenständig
/// von `Zone`, weil ein Nutzer beim Tippen/Ziehen vorübergehend
/// ungültige oder nicht-aufsteigende Werte erzeugen kann (Feld leer,
/// vertauschte Grenzen, außerhalb `0...1`/`0...8191`). `ZoneDraft`
/// selbst ist deshalb **keine** `Zone` und trägt keine
/// Validierungsgarantie -- erst ``clamp()`` gefolgt von
/// ``resolvedZone()`` liefert wieder eine über `Zone.build(...)`
/// geprüfte, gültige `Zone`. Das Modell (`ZoneEditorState.zones`)
/// bekommt nie einen unkommittierten Entwurf zu sehen (SICK-014-
/// Auftrag: „ungültige Zwischenwerte dürfen nie in das Modell
/// gelangen").
public struct ZoneDraft: Equatable, Sendable {
    public var indexLowerBound: Double
    public var indexUpperBound: Double
    public var valueLowerBound: UInt16
    public var valueUpperBound: UInt16
    public var role: ZoneRole
    /// Die Feldform (SICK-033e). Wird beim Übernehmen mit der Zone
    /// gesetzt; für `gate` ohne Wirkung (siehe `EditableZone.field`).
    public var shape: FieldShape

    public init(zone: Zone, shape: FieldShape = .strip) {
        indexLowerBound = zone.indexRange.lowerBound
        indexUpperBound = zone.indexRange.upperBound
        valueLowerBound = zone.valueRange.lowerBound
        valueUpperBound = zone.valueRange.upperBound
        role = zone.role
        self.shape = shape
    }

    public init(
        indexLowerBound: Double,
        indexUpperBound: Double,
        valueLowerBound: UInt16,
        valueUpperBound: UInt16,
        role: ZoneRole,
        shape: FieldShape = .strip
    ) {
        self.indexLowerBound = indexLowerBound
        self.indexUpperBound = indexUpperBound
        self.valueLowerBound = valueLowerBound
        self.valueUpperBound = valueUpperBound
        self.role = role
        self.shape = shape
    }

    /// Kleinster erzwungener Abstand zwischen Unter- und Obergrenze,
    /// falls eine Klammerung beide sonst gleich oder vertauscht ließe --
    /// ohne diesen Mindestabstand könnte ``resolvedZone()`` nach
    /// ``clamp()`` immer noch scheitern (`Zone.build` verlangt echtes
    /// Aufsteigen, siehe `Zone.BuildError`).
    public static let minimumIndexSpan = 0.001
    public static let minimumValueSpan: UInt16 = 1

    /// Klammert jedes Feld einzeln in seinen gültigen Bereich (Index
    /// `0...1`, Rohwert `0...8191`) und erzwingt danach echtes
    /// Aufsteigen (Ober- > Untergrenze) durch minimales Nachschieben
    /// der jeweils anderen Grenze. Nach ``clamp()`` liefert
    /// ``resolvedZone()`` in jedem Fall eine gültige `Zone`
    /// (SICK-014-Auftrag: „Bereichsklammerung").
    public mutating func clamp() {
        indexLowerBound = indexLowerBound.clamped(to: 0...1)
        indexUpperBound = indexUpperBound.clamped(to: 0...1)
        if indexLowerBound >= indexUpperBound {
            if indexLowerBound >= 1 - Self.minimumIndexSpan {
                indexLowerBound = 1 - Self.minimumIndexSpan
                indexUpperBound = 1
            } else {
                indexUpperBound = indexLowerBound + Self.minimumIndexSpan
            }
        }

        let maxValue = Zone.maxRawMeasurementValue
        valueLowerBound = min(valueLowerBound, maxValue)
        valueUpperBound = min(valueUpperBound, maxValue)
        if valueLowerBound >= valueUpperBound {
            if valueLowerBound >= maxValue - Self.minimumValueSpan {
                valueLowerBound = maxValue - Self.minimumValueSpan
                valueUpperBound = maxValue
            } else {
                valueUpperBound = valueLowerBound + Self.minimumValueSpan
            }
        }
    }

    /// Baut über `Zone.build(...)` -- den einzigen fachlichen Vertrag --
    /// eine `Zone` aus den aktuellen Feldern. `nil`, falls sie (z. B.
    /// ohne vorheriges ``clamp()``) noch ungültig sind.
    public func resolvedZone() -> Zone? {
        try? Zone.build(
            indexLowerBound: indexLowerBound,
            indexUpperBound: indexUpperBound,
            valueLowerBound: valueLowerBound,
            valueUpperBound: valueUpperBound,
            role: role
        )
    }
}
