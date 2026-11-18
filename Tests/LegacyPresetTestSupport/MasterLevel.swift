@testable import PlanariumPresets
import PlanariumDomain
// MasterLevel.swift
//
// Der Masterpegel: **ein** Wert, ganz am Ende des Signalwegs.
//
// ## Wo er sitzt -- und warum genau dort
//
// Er liegt auf dem **Hauptmischer** des Hosts. Das ist der Punkt, an dem
// im `AudioGraphPlan` alles zusammenläuft: das trockene Signal, der
// Delay-Send, der Hall-Send und -- wenn eines vorbereitet ist -- die
// serielle Kette des externen AU-Racks davor. Ein Pegel dort wirkt
// deshalb hinter **allem**, mit Rack wie ohne.
//
// Daraus folgen zwei Dinge, die diesen Wert von der Scannerlautstärke
// trennen:
//
// - Er **ersetzt die Volume-Zone nicht**. Die steuert die Amplitude der
//   Stimme, also wie laut gespielt wird; der Master steuert, wie laut
//   das Ergebnis herauskommt. Beides zusammen ist ein Kanalzug, nicht
//   ein doppelter Regler.
// - Er **verfälscht sie nicht**. Er liegt hinter den Effekten, also
//   ändert er deren Verhältnis zum trockenen Signal nicht; und er
//   erreicht den DSP-Kern nie, also kann er die Hüllkurve nicht
//   verschieben.
//
// ## Kein zweiter Lautstärkeregler im Renderpfad
//
// Der Renderblock ist von diesem Wert **nicht berührt**: keine
// Multiplikation, keine zusätzliche Verzweigung, kein weiterer
// Parameter über den Seqlock. Ein Master, der im Renderpfad
// multipliziert würde, wäre nicht nur überflüssig -- er läge **vor** den
// Effekten und würde den Hall mitdämpfen, statt die Summe zu regeln.
//
// ## Warum lineare Verstärkung und kein dB
//
// Ein Kanalzug zeigt üblicherweise dB. Der Wert dahinter wäre trotzdem
// diese lineare Verstärkung -- der Mischerknoten kennt nichts anderes.
// Eine dB-Fassade bräuchte also eine zweite Darstellung, eine Umrechnung
// und einen erfundenen Punkt für „minus unendlich"; drei Gelegenheiten,
// dass die beiden Darstellungen auseinanderlaufen. Die Anzeige kann dB
// beschriften, wenn sie es will (SICK-033) -- **der Vertrag bleibt der
// Wert, den der Mischer tatsächlich bekommt.**

import Foundation

/// Der Masterpegel als validierter Wert.
///
/// Erzeugt wird er ausschließlich über ``build(gain:)`` -- eine
/// validierende Fabrik nach dem Muster von `Frame.build`, `Zone.build`
/// und `EffectParameters.build`. **Keine stille Klammerung:** ein Pegel,
/// der heimlich auf einen anderen Wert korrigiert wird, fällt niemandem
/// auf, und beim Master hieße „heimlich korrigiert" im Zweifel „viel
/// lauter als gewollt".
public struct MasterLevel: Equatable, Sendable {
    /// Der zulässige Bereich der linearen Verstärkung.
    ///
    /// `0` ist still, `1` ist unverändert. **Bewusst nicht über `1`:**
    /// Der Hauptmischer summiert trockenes Signal und beide Sends; eine
    /// Verstärkung über eins ließe diese Summe übersteuern, ohne dass
    /// irgendwo ein Begrenzer stünde.
    public static let gainRange: ClosedRange<Float> = 0...1

    /// Die lineare Verstärkung des Hauptmischers.
    public let gain: Float

    public enum BuildError: Error, Equatable {
        /// Nicht endlich oder außerhalb von ``gainRange``.
        case gainOutOfRange(Float)
    }

    private init(gain: Float) {
        self.gain = gain
    }

    /// Validierende Fabrik.
    ///
    /// Nicht endliche Werte (`nan`, `inf`) fielen schon durch die
    /// Bereichsprüfung, weil jeder Vergleich mit `nan` `false` ergibt --
    /// geprüft wird es trotzdem ausdrücklich, damit die Regel im Code
    /// steht und nicht in einer Fußnote.
    public static func build(gain: Float) throws -> MasterLevel {
        guard gain.isFinite, gainRange.contains(gain) else {
            throw BuildError.gainOutOfRange(gain)
        }
        return MasterLevel(gain: gain)
    }

    /// Unverändert: die Summe geht so heraus, wie sie hereinkommt.
    public static let unity = MasterLevel(gain: 1)

    /// Still.
    public static let silent = MasterLevel(gain: 0)

    /// Der **sichere Startwert**: `0,8`.
    ///
    /// Begründet, nicht geraten: Der Hauptmischer summiert das trockene
    /// Signal **und** beide Sends. Stehen die Sends oben, liegt die Summe
    /// über dem trockenen Pegel allein -- bei Unity wäre die Ausgabe dann
    /// schon übersteuert, bevor jemand etwas falsch gemacht hätte. `0,8`
    /// lässt dafür Luft und ist gleichzeitig laut genug, dass niemand
    /// beim ersten Ton am Rechner dreht.
    ///
    /// **Kein eingemessener Wert** und keine Aussage über irgendein
    /// Ausgabegerät -- dieselbe Kennzeichnung wie bei den übrigen
    /// Startwerten des Projekts.
    public static let startingPoint = MasterLevel(gain: 0.8)

    /// `true`, wenn nichts herauskommt.
    public var isSilent: Bool { gain == 0 }
}
