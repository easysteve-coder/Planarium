@testable import PlanariumPresets
import PlanariumDomain
/// Ob ein normierter Steuerwert **aufsteigend** oder **absteigend**
/// wirkt (SICK-024-Auftrag 1).
///
/// Je Rolle ausdrücklich einstellbar, weil der physikalische Aufbau das
/// Vorzeichen bestimmt und nicht der Klang: Ob sich der Ton beim
/// Annähern an den Scanner hebt oder senkt, hängt davon ab, wo die
/// Zone liegt und wo der Spieler steht. Ein fest verdrahtetes Vorzeichen
/// wäre eine Annahme über die Aufstellung, die niemand geprüft hat.
public enum MappingPolarity: String, Equatable, Hashable, Sendable, CaseIterable {
    /// `0` → unteres Ende, `1` → oberes Ende.
    case normal
    /// `0` → oberes Ende, `1` → unteres Ende.
    case inverted

    /// Wendet die Polarität auf einen normierten Steuerwert an. Ein
    /// Wert in `0...1` bleibt in `0...1`.
    func applied(to control: Double) -> Double {
        switch self {
        case .normal: return control
        case .inverted: return 1 - control
        }
    }
}

/// Wie ein normierter Steuerwert auf die Amplitude wirkt.
///
/// Beide Kurven sind **lückenlos und monoton**; sie unterscheiden sich
/// nur darin, wie schnell es am unteren Ende leise wird.
public enum VolumeResponseCurve: String, Equatable, Hashable, Sendable, CaseIterable {
    /// Amplitude folgt dem Steuerwert unmittelbar.
    case linear
    /// Amplitude folgt dem **Quadrat** des Steuerwerts. Das kommt der
    /// wahrgenommenen Lautstärke näher: Die lineare Kurve wirkt im
    /// unteren Drittel bereits deutlich laut, die quadratische lässt
    /// dort mehr Platz für leises Spiel.
    case quadratic

    func amplitudeFactor(for control: Double) -> Double {
        switch self {
        case .linear: return control
        case .quadratic: return control * control
        }
    }
}

/// Wie die vier kontinuierlichen Rollen des Steuervertrags auf den
/// Synthesizer wirken (SICK-024-Auftrag 1).
///
/// **Die Vorgaben sind musikalische Startwerte, keine Scanner- oder
/// Messwahrheit.** Sie stammen aus keiner Messung an einem Gerät und
/// sind nicht an einem echten Spielaufbau eingestellt worden -- genau
/// wie `ControlValuePredictorConfiguration.startingPoint` (SICK-015)
/// und `GatePolicy.standard` (SICK-022) ausdrücklich gekennzeichnet
/// sind. Sie sind so gewählt, dass nichts wehtut, wenn jemand sie beim
/// ersten Mal unverändert lässt.
///
/// **Validiert wird ohne stille Korrektur** (Hausmuster wie
/// `Frame.build`/`Zone.build`/`EffectParameters.build`): nicht endliche
/// Werte, leere oder verdrehte Bereiche und alles außerhalb des
/// sicheren Hörbereichs sind sichtbare Fehler.
public struct LegacyMappingConfiguration: Equatable, Sendable {
    /// Verstöße gegen den Konfigurationsvertrag -- **ein eigener Fall je
    /// Regel**, damit die Meldung sagt, was zu ändern ist.
    public enum BuildError: Error, Equatable {
        case pitchBoundNotFinite(Double)
        /// Außerhalb von ``safeAudibleRangeHz``.
        case pitchBoundOutsideSafeRange(Double)
        /// Unteres Ende nicht **echt** kleiner als das obere. Ein
        /// entarteter Bereich wäre keine Tonhöhensteuerung mehr,
        /// sondern ein konstanter Ton -- und die logarithmische
        /// Übersetzung wäre nicht mehr umkehrbar.
        case pitchRangeNotAscending(lower: Double, upper: Double)

        case filterBoundNotFinite(Double)
        case filterBoundOutsideSafeRange(Double)
        case filterRangeNotAscending(lower: Double, upper: Double)

        case maximumAmplitudeNotFinite(Double)
        /// Außerhalb `0...1`.
        case maximumAmplitudeOutOfRange(Double)

        case maximumSendNotFinite(Double)
        /// Außerhalb `0...1`.
        case maximumSendOutOfRange(Double)
    }

    /// Der sichere Hörbereich, in dem Ton- und Filterfrequenzen liegen
    /// müssen: **20 Hz bis 20 000 Hz**.
    ///
    /// Die untere Schranke ist echt positiv, weil die logarithmische
    /// Übersetzung sonst nicht definiert wäre; die obere hält Abstand
    /// zur Nyquist-Grenze der üblichen Abtastraten (44 100 / 48 000 Hz).
    /// Der DSP-Kern bliebe zwar auch darüber stabil -- der TPT-Filter
    /// ist unbedingt stabil (SICK-016) --, aber weder ein Ton noch eine
    /// Grenzfrequenz jenseits davon ist noch eine musikalische Angabe.
    public static let safeAudibleRangeHz: ClosedRange<Double> = 20...20_000

    /// Tiefster Ton bei anliegendem Steuerwert am unteren Ende
    /// (nach Polarität).
    public let pitchLowestHz: Double
    /// Höchster Ton am oberen Ende (nach Polarität).
    public let pitchHighestHz: Double
    public let pitchPolarity: MappingPolarity

    public let filterLowestHz: Double
    public let filterHighestHz: Double
    public let filterPolarity: MappingPolarity

    /// Amplitude bei vollem Steuerwert. Bewusst unter `1`, damit die
    /// Summe aus trockenem Signal und beiden Sends Kopfraum behält.
    public let maximumAmplitude: Double
    public let volumeCurve: VolumeResponseCurve
    public let volumePolarity: MappingPolarity

    /// Delay-Sendpegel bei vollem `effectSend`-Steuerwert.
    public let maximumDelaySend: Double
    /// Hall-Sendpegel bei vollem `effectSend`-Steuerwert.
    public let maximumReverbSend: Double
    public let effectSendPolarity: MappingPolarity

    private init(
        pitchLowestHz: Double,
        pitchHighestHz: Double,
        pitchPolarity: MappingPolarity,
        filterLowestHz: Double,
        filterHighestHz: Double,
        filterPolarity: MappingPolarity,
        maximumAmplitude: Double,
        volumeCurve: VolumeResponseCurve,
        volumePolarity: MappingPolarity,
        maximumDelaySend: Double,
        maximumReverbSend: Double,
        effectSendPolarity: MappingPolarity
    ) {
        self.pitchLowestHz = pitchLowestHz
        self.pitchHighestHz = pitchHighestHz
        self.pitchPolarity = pitchPolarity
        self.filterLowestHz = filterLowestHz
        self.filterHighestHz = filterHighestHz
        self.filterPolarity = filterPolarity
        self.maximumAmplitude = maximumAmplitude
        self.volumeCurve = volumeCurve
        self.volumePolarity = volumePolarity
        self.maximumDelaySend = maximumDelaySend
        self.maximumReverbSend = maximumReverbSend
        self.effectSendPolarity = effectSendPolarity
    }

    /// **Musikalischer Startwert, keine Gerätewahrheit.**
    ///
    /// - Tonhöhe **55 Hz bis 1760 Hz**: genau fünf Oktaven, von A1 bis
    ///   A6. Ein runder, spielbarer Ausschnitt, der unten nicht im
    ///   Bassbrummen und oben nicht im Pfeifen endet.
    /// - Filter **200 Hz bis 12 000 Hz**: unten bleibt der Ton hörbar
    ///   (eine Grenzfrequenz unter dem Grundton würde ihn verschlucken),
    ///   oben ist der Tiefpass praktisch offen.
    /// - Amplitude bis **0,8** -- Kopfraum für die beiden Sends.
    /// - Lautstärkekurve **quadratisch**, siehe
    ///   ``VolumeResponseCurve/quadratic``.
    /// - Sends bis **0,5** je Weg: deutlich hörbar, aber nie lauter als
    ///   das trockene Signal.
    /// - Alle Polaritäten **normal**; welche Richtung am realen Aufbau
    ///   die richtige ist, weiß dieser Slice nicht.
    public static let musicalStartingPoint = LegacyMappingConfiguration(
        pitchLowestHz: 55,
        pitchHighestHz: 1760,
        pitchPolarity: .normal,
        filterLowestHz: 200,
        filterHighestHz: 12_000,
        filterPolarity: .normal,
        maximumAmplitude: 0.8,
        volumeCurve: .quadratic,
        volumePolarity: .normal,
        maximumDelaySend: 0.5,
        maximumReverbSend: 0.5,
        effectSendPolarity: .normal
    )

    /// Validierende Fabrik. Jeder Parameter hat den Wert von
    /// ``musicalStartingPoint``, wenn er nicht genannt wird -- wer eine
    /// Sache ändern will, schreibt eine Zeile und erbt den Rest.
    public static func build(
        pitchLowestHz: Double = musicalStartingPoint.pitchLowestHz,
        pitchHighestHz: Double = musicalStartingPoint.pitchHighestHz,
        pitchPolarity: MappingPolarity = musicalStartingPoint.pitchPolarity,
        filterLowestHz: Double = musicalStartingPoint.filterLowestHz,
        filterHighestHz: Double = musicalStartingPoint.filterHighestHz,
        filterPolarity: MappingPolarity = musicalStartingPoint.filterPolarity,
        maximumAmplitude: Double = musicalStartingPoint.maximumAmplitude,
        volumeCurve: VolumeResponseCurve = musicalStartingPoint.volumeCurve,
        volumePolarity: MappingPolarity = musicalStartingPoint.volumePolarity,
        maximumDelaySend: Double = musicalStartingPoint.maximumDelaySend,
        maximumReverbSend: Double = musicalStartingPoint.maximumReverbSend,
        effectSendPolarity: MappingPolarity = musicalStartingPoint.effectSendPolarity
    ) throws -> LegacyMappingConfiguration {
        for bound in [pitchLowestHz, pitchHighestHz] {
            guard bound.isFinite else { throw BuildError.pitchBoundNotFinite(bound) }
            guard safeAudibleRangeHz.contains(bound) else {
                throw BuildError.pitchBoundOutsideSafeRange(bound)
            }
        }
        guard pitchLowestHz < pitchHighestHz else {
            throw BuildError.pitchRangeNotAscending(lower: pitchLowestHz, upper: pitchHighestHz)
        }

        for bound in [filterLowestHz, filterHighestHz] {
            guard bound.isFinite else { throw BuildError.filterBoundNotFinite(bound) }
            guard safeAudibleRangeHz.contains(bound) else {
                throw BuildError.filterBoundOutsideSafeRange(bound)
            }
        }
        guard filterLowestHz < filterHighestHz else {
            throw BuildError.filterRangeNotAscending(lower: filterLowestHz, upper: filterHighestHz)
        }

        guard maximumAmplitude.isFinite else {
            throw BuildError.maximumAmplitudeNotFinite(maximumAmplitude)
        }
        guard maximumAmplitude >= 0, maximumAmplitude <= 1 else {
            throw BuildError.maximumAmplitudeOutOfRange(maximumAmplitude)
        }

        for send in [maximumDelaySend, maximumReverbSend] {
            guard send.isFinite else { throw BuildError.maximumSendNotFinite(send) }
            guard send >= 0, send <= 1 else { throw BuildError.maximumSendOutOfRange(send) }
        }

        return LegacyMappingConfiguration(
            pitchLowestHz: pitchLowestHz,
            pitchHighestHz: pitchHighestHz,
            pitchPolarity: pitchPolarity,
            filterLowestHz: filterLowestHz,
            filterHighestHz: filterHighestHz,
            filterPolarity: filterPolarity,
            maximumAmplitude: maximumAmplitude,
            volumeCurve: volumeCurve,
            volumePolarity: volumePolarity,
            maximumDelaySend: maximumDelaySend,
            maximumReverbSend: maximumReverbSend,
            effectSendPolarity: effectSendPolarity
        )
    }
}
