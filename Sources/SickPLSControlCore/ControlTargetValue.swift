/// Die drei **Zieltypen** eines Steuerwerts (SICK-033d). Geschlossen;
/// jede Stelle, die einen Wert weiterreicht, schaltet ohne `default`.
public enum ControlTargetKind: String, Equatable, Hashable, Sendable, CaseIterable {
    /// Ein stetiger Wert `0...1` -- **der einzige**, der den Predictor
    /// erreicht.
    case continuous
    /// Eine Zelle, Stufe oder Tonartstufe. Wird nie prognostiziert und
    /// nie geglättet; ein Sprung ist hier gewollt.
    case discrete
    /// Ein punktuelles Gate-Ereignis. Wird nie prognostiziert, nie
    /// gehalten, nie gemischt.
    case gate
}

/// Ein **typisierter** Zielwert. Kein nacktes `Double`: Wer einen Wert in
/// der Hand hält, weiß, ob er stetig, diskret oder ein Gate ist -- und
/// die Pipeline entscheidet daran strukturell, ob ein Predictor
/// beteiligt sein darf.
public enum ControlTargetValue: Equatable, Sendable {
    case continuous(Double)
    /// Ein Schritt mit Bezugsrahmen -- normierbar ohne zweite Rechnung.
    case discrete(DiscreteStep)
    case gate(Double)

    public var kind: ControlTargetKind {
        switch self {
        case .continuous: return .continuous
        case .discrete: return .discrete
        case .gate: return .gate
        }
    }
}

extension Zone {
    /// Der typisierte Zielwert einer Zone aus der Trefferfolge.
    ///
    /// Eine Zone kennt **keine Zellen**: Sie liefert je nach Rolle einen
    /// stetigen Wert oder ein Gate, nie ``ControlTargetValue/discrete(_:)``.
    /// Diskrete Werte entstehen erst aus Feldern mit Zellen (Raster,
    /// Fächer, Tonartfelder; SICK-033e).
    public func targetValue(hits sequence: FieldHitSequence) -> ControlTargetValue? {
        guard case .controlValue(let value) = evaluate(hits: sequence) else { return nil }
        switch role {
        case .gate:
            return .gate(value)
        case .pitch, .volume, .filter, .effectSend:
            return .continuous(value)
        }
    }
}

/// Wie mehrere **Ebenen** desselben Ziels zu einem Wert gemischt werden
/// (SICK-033d, Mischmatrix). Geschlossen und parameterabhängig; es gibt
/// keinen `default`-Ausweg.
///
/// Gemischt werden nur **stetige** Werte. Diskrete Werte und Gates
/// kennen genau eine Regel -- ``firstActive(_:)`` --, weil ein Mittel
/// aus zwei Zellen oder zwei Gates keine Bedeutung hätte.
public enum LayerMixRule: String, Equatable, Sendable, CaseIterable {
    /// Die erste aktive Ebene in Ebenenreihenfolge gewinnt.
    case firstActive
    /// Der größte aktive Wert gewinnt.
    case maximum
    /// Der kleinste aktive Wert gewinnt.
    case minimum

    /// Mischt stetige Ebenenwerte in Ebenenreihenfolge. Inaktive Ebenen
    /// (`nil`) zählen nicht; sind alle inaktiv, ist das Ergebnis `nil`
    /// -- nie `0`.
    public func mix(_ layers: [Double?]) -> Double? {
        let active = layers.compactMap { $0 }
        switch self {
        case .firstActive: return active.first
        case .maximum: return active.max()
        case .minimum: return active.min()
        }
    }

    /// Die **einzige** Regel für diskrete Werte und Gates: erste aktive
    /// Ebene. Generisch, damit es für beide Typen genau eine Stelle gibt.
    public static func firstActive<Value>(_ layers: [Value?]) -> Value? {
        for layer in layers {
            if let value = layer { return value }
        }
        return nil
    }
}
