/// Interne Bequemlichkeit für mehrere Geometrie-/Editor-Typen dieses
/// Moduls (``ZoneEditorGeometry``, ``FanScreenGeometry``, ``ZoneDraft``)
/// -- absichtlich nicht `public`, reine Implementierungshilfe.
extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
