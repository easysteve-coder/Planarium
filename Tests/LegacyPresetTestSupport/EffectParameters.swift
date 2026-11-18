@testable import PlanariumPresets
import PlanariumDomain
// EffectParameters.swift
//
// Der Parametersatz der beiden internen Sends (Delay und Hall).
//
// Bewusst **klein**: nur die wenigen Werte, die für einen brauchbaren
// Send tatsächlich gebraucht werden. Jeder weitere Regler gehört in das
// Audio-Unit-Rack von Schritt 8, nicht hierher.
//
// **Was hier ausdrücklich nicht steht:** jede Zuordnung von
// Scannerwerten auf Effektparameter. Die `effectSend`-Zonen aus
// `SickPLSControlCore` bleiben in diesem Slice unangeschlossen.

import Foundation

/// Hallcharakter als geschlossene Auswahl.
///
/// Bewusst eine **feste, benannte Auswahl** statt einzelner Regler für
/// Raumgröße, Dämpfung und Diffusion: die zugrunde liegenden Presets
/// von `AVAudioUnitReverb` sind aufeinander abgestimmte Räume. Einzelne
/// Regler wären hier eine selbst erfundene Reverb-Architektur, und
/// genau die soll dieser Slice nicht bauen.
public enum ReverbCharacter: String, CaseIterable, Equatable, Sendable {
    case smallRoom
    case mediumRoom
    case largeRoom
    case mediumHall
    case largeHall
    case cathedral
}

/// Parametersatz der beiden Sends.
///
/// Erzeugt wird er ausschließlich über `build(...)` — eine validierende
/// Fabrik nach dem Muster von `Frame.build`, `Zone.build` und
/// `ControlValuePredictorConfiguration.build`. **Es gibt bewusst keine
/// stille Klammerung:** ein Effektparameter, der heimlich auf einen
/// anderen Wert korrigiert wird, fällt niemandem auf. Jede Regel hat
/// einen eigenen Fehlerfall.
public struct EffectParameters: Equatable, Sendable {
    // MARK: - Grenzen

    /// Sendpegel, linear. `0` = der Send ist stumm.
    public static let sendRange: ClosedRange<Float> = 0...1

    /// Verzögerungszeit in Sekunden. Obergrenze ist die von
    /// `AVAudioUnitDelay` zugesicherte maximale Verzögerung.
    public static let delayTimeRange: ClosedRange<Float> = 0.001...2.0

    /// Rückkopplung in Prozent.
    ///
    /// **Bewusst bei 85 % gedeckelt**, obwohl `AVAudioUnitDelay` bis
    /// ±100 % zulässt: ab 100 % klingt die Verzögerung nicht mehr ab,
    /// sondern schaukelt sich auf. Für einen Send, dessen Pegel jemand
    /// im Spiel aufdreht, ist das kein Klangeffekt, sondern ein Risiko.
    public static let delayFeedbackRange: ClosedRange<Float> = 0...85

    // MARK: - Werte

    /// Pegel des Delay-Sends.
    public let delaySend: Float

    /// Verzögerungszeit des Delays in Sekunden.
    public let delayTimeSeconds: Float

    /// Rückkopplung des Delays in Prozent.
    public let delayFeedbackPercent: Float

    /// Pegel des Hall-Sends.
    public let reverbSend: Float

    /// Hallcharakter.
    public let reverbCharacter: ReverbCharacter

    // MARK: - Fehler

    public enum BuildError: Error, Equatable {
        case delaySendOutOfRange(Float)
        case delayTimeOutOfRange(Float)
        case delayFeedbackOutOfRange(Float)
        case reverbSendOutOfRange(Float)
    }

    private init(
        delaySend: Float,
        delayTimeSeconds: Float,
        delayFeedbackPercent: Float,
        reverbSend: Float,
        reverbCharacter: ReverbCharacter
    ) {
        self.delaySend = delaySend
        self.delayTimeSeconds = delayTimeSeconds
        self.delayFeedbackPercent = delayFeedbackPercent
        self.reverbSend = reverbSend
        self.reverbCharacter = reverbCharacter
    }

    /// Validierende Fabrik. Lehnt jeden nicht endlichen oder außerhalb
    /// des Bereichs liegenden Wert mit einem eigenen Fehler ab und
    /// korrigiert nichts stillschweigend.
    ///
    /// Nicht endliche Werte (`nan`, `inf`) fallen durch die
    /// Bereichsprüfung, weil ein Vergleich mit `nan` immer `false`
    /// ergibt — geprüft wird das trotzdem ausdrücklich.
    public static func build(
        delaySend: Float,
        delayTimeSeconds: Float,
        delayFeedbackPercent: Float,
        reverbSend: Float,
        reverbCharacter: ReverbCharacter
    ) throws -> EffectParameters {
        guard delaySend.isFinite, sendRange.contains(delaySend) else {
            throw BuildError.delaySendOutOfRange(delaySend)
        }
        guard delayTimeSeconds.isFinite, delayTimeRange.contains(delayTimeSeconds) else {
            throw BuildError.delayTimeOutOfRange(delayTimeSeconds)
        }
        guard delayFeedbackPercent.isFinite, delayFeedbackRange.contains(delayFeedbackPercent) else {
            throw BuildError.delayFeedbackOutOfRange(delayFeedbackPercent)
        }
        guard reverbSend.isFinite, sendRange.contains(reverbSend) else {
            throw BuildError.reverbSendOutOfRange(reverbSend)
        }
        return EffectParameters(
            delaySend: delaySend,
            delayTimeSeconds: delayTimeSeconds,
            delayFeedbackPercent: delayFeedbackPercent,
            reverbSend: reverbSend,
            reverbCharacter: reverbCharacter
        )
    }

    /// Der **neutrale** Ausgangszustand: beide Sends auf `0`.
    ///
    /// Die Klangwerte darunter sind sinnvoll vorbelegt, wirken aber
    /// nicht, solange die Sendpegel `0` sind — die Ausgabe ist dann
    /// vollständig trocken.
    public static let neutral = EffectParameters(
        delaySend: 0,
        delayTimeSeconds: 0.25,
        delayFeedbackPercent: 25,
        reverbSend: 0,
        reverbCharacter: .mediumRoom
    )

    /// `true`, wenn beide Sends stumm sind und die Ausgabe damit
    /// trocken bleibt.
    public var isDry: Bool {
        delaySend == 0 && reverbSend == 0
    }
}
