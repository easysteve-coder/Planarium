import SickPLSCore

/// Eine Zone beschreibt einen rein relativen Ausschnitt eines
/// B0-Scanprofils -- ausschließlich als Indexbereich (`0...1`, **kein**
/// Gradwinkel) und Rohwertbereich (`0...8191`, **keine** Millimeter),
/// siehe SICK-013-Auftrag. `SickPLSControlCore` ist UI-, Transport-,
/// MIDI-, Audio- und Gerätefrei -- es kennt weder SwiftUI/Combine/
/// Dispatch noch reale Geräte, nur `SickPLSCore`s `B0ScanProfile`
/// (keine Abhängigkeit auf `SickPLSMonitorKit`, `SickPLSMacTransport`
/// oder `SickPLSActiveControl`).
///
/// Eine Zone erzeugt selbst **keinen** MIDI-/Audio-/Notenwert -- nur
/// einen normierten Steuerwert `0...1` oder `inactive`
/// (``ZoneEvaluationResult``, siehe `Zone.evaluate(against:)`). Die
/// Übersetzung in konkrete MIDI-/Audio-Werte, ein grafischer
/// Zoneneditor und jede Bewegungsprognose sind bewusst spätere, eigene
/// Slices (SICK-013-Auftrag: „Keine Zoneneditor-UI in diesem Slice").
public struct Zone: Equatable, Sendable {
    /// Größter darstellbare Rohmesswert (13 Bit, `0x1FFF` = 8191) --
    /// dieselbe feste Obergrenze wie `SickPLSMonitorKit
    /// .PolarProfileGeometry.maxRawMeasurementValue`, hier unabhängig
    /// neu definiert, um keine Abhängigkeit auf ein UI-nahes Modul
    /// einzuführen (siehe Typkommentar oben).
    public static let maxRawMeasurementValue: UInt16 = 0x1FFF

    /// Relativer Indexbereich innerhalb eines Profils, `0...1` --
    /// **kein** physischer Winkel.
    public let indexRange: ClosedRange<Double>
    /// Rohwertbereich, `0...8191` -- **keine** physikalische Einheit.
    public let valueRange: ClosedRange<UInt16>
    public let role: ZoneRole

    private init(indexRange: ClosedRange<Double>, valueRange: ClosedRange<UInt16>, role: ZoneRole) {
        self.indexRange = indexRange
        self.valueRange = valueRange
        self.role = role
    }

    /// Fehler bei der validierenden Konstruktion einer ``Zone`` über
    /// ``build(indexLowerBound:indexUpperBound:valueLowerBound:valueUpperBound:role:)``.
    public enum BuildError: Error, Equatable, Sendable {
        /// Ein Indexgrenzwert liegt außerhalb von `0...1`.
        case indexBoundOutOfRange(Double)
        /// `indexLowerBound` ist nicht echt kleiner als `indexUpperBound`
        /// -- eine Zone ohne Ausdehnung wäre nicht sinnvoll normierbar.
        case indexRangeNotIncreasing(lower: Double, upper: Double)
        /// Ein Wertgrenzwert übersteigt ``maxRawMeasurementValue``.
        case valueBoundOutOfRange(UInt16)
        /// `valueLowerBound` ist nicht echt kleiner als `valueUpperBound`
        /// -- dieselbe Begründung wie ``indexRangeNotIncreasing``, hier
        /// zusätzlich Voraussetzung für die Division bei der Normierung
        /// in `Zone.evaluate(against:)`.
        case valueRangeNotIncreasing(lower: UInt16, upper: UInt16)
    }

    /// Öffentliche, validierende Konstruktion (Muster wie
    /// `Frame.build`/`B0ScanProfile.build` in `SickPLSCore`) -- eine
    /// ``Zone`` mit ungültigen oder entarteten (nicht ausgedehnten)
    /// Bereichen lässt sich strukturell nicht erzeugen.
    public static func build(
        indexLowerBound: Double,
        indexUpperBound: Double,
        valueLowerBound: UInt16,
        valueUpperBound: UInt16,
        role: ZoneRole
    ) throws -> Zone {
        guard indexLowerBound >= 0, indexLowerBound <= 1 else {
            throw BuildError.indexBoundOutOfRange(indexLowerBound)
        }
        guard indexUpperBound >= 0, indexUpperBound <= 1 else {
            throw BuildError.indexBoundOutOfRange(indexUpperBound)
        }
        guard indexLowerBound < indexUpperBound else {
            throw BuildError.indexRangeNotIncreasing(lower: indexLowerBound, upper: indexUpperBound)
        }
        guard valueLowerBound <= maxRawMeasurementValue else {
            throw BuildError.valueBoundOutOfRange(valueLowerBound)
        }
        guard valueUpperBound <= maxRawMeasurementValue else {
            throw BuildError.valueBoundOutOfRange(valueUpperBound)
        }
        guard valueLowerBound < valueUpperBound else {
            throw BuildError.valueRangeNotIncreasing(lower: valueLowerBound, upper: valueUpperBound)
        }

        return Zone(
            indexRange: indexLowerBound...indexUpperBound,
            valueRange: valueLowerBound...valueUpperBound,
            role: role
        )
    }
}
