

/// Wie der gemeinsame Steuerweg auf MIDI 1 abgebildet wird (SICK-036a).
/// Validierend, ohne stille Korrektur.
public struct MIDIOutputConfiguration: Equatable, Sendable {
    public enum BuildError: Error, Equatable {
        /// Kanal außerhalb `1...16`.
        case channelOutOfRange(Int)
        /// Bendbereich außerhalb `1...24` Halbtöne.
        case bendRangeOutOfRange(Int)
        /// Controllernummer außerhalb `0...127`.
        case controllerOutOfRange(Int)
        /// Zwei Rollen auf derselben Controllernummer.
        case duplicateController(Int)
    }

    /// Kanal `1...16`, wie der Spieler ihn zählt.
    public let channel: Int
    /// Pitch-Bend-Bereich des Empfängers in Halbtönen (`±`).
    public let bendRangeSemitones: Int
    /// Die eine Pitch-Domäne: Grundnote und Umfang.
    public let pitchDomain: PitchDomain
    /// Ob der Pitch-Steuerwert invertiert wirkt -- dieselbe Bedeutung
    /// wie die Audio-Polarität, hier als eigener Wert dieser Senke.
    public let pitchInverted: Bool
    public let volumeController: Int
    public let filterController: Int
    public let effectSendController: Int

    private init(
        channel: Int, bendRangeSemitones: Int, pitchDomain: PitchDomain, pitchInverted: Bool,
        volumeController: Int, filterController: Int, effectSendController: Int
    ) {
        self.channel = channel
        self.bendRangeSemitones = bendRangeSemitones
        self.pitchDomain = pitchDomain
        self.pitchInverted = pitchInverted
        self.volumeController = volumeController
        self.filterController = filterController
        self.effectSendController = effectSendController
    }

    /// Kanal 1, ±2 Halbtöne (General-MIDI-Vorgabe), CC7 Lautstärke,
    /// CC74 Filter, CC91 Effekt-Send. Ein Startwert, keine Gerätewahrheit.
    public static let standard = MIDIOutputConfiguration(
        channel: 1, bendRangeSemitones: 2, pitchDomain: .standard, pitchInverted: false,
        volumeController: 7, filterController: 74, effectSendController: 91
    )

    public static func build(
        channel: Int = standard.channel,
        bendRangeSemitones: Int = standard.bendRangeSemitones,
        pitchDomain: PitchDomain = standard.pitchDomain,
        pitchInverted: Bool = standard.pitchInverted,
        volumeController: Int = standard.volumeController,
        filterController: Int = standard.filterController,
        effectSendController: Int = standard.effectSendController
    ) throws -> MIDIOutputConfiguration {
        guard (1...16).contains(channel) else { throw BuildError.channelOutOfRange(channel) }
        guard (1...24).contains(bendRangeSemitones) else { throw BuildError.bendRangeOutOfRange(bendRangeSemitones) }
        let controllers = [volumeController, filterController, effectSendController]
        for controller in controllers where !(0...127).contains(controller) {
            throw BuildError.controllerOutOfRange(controller)
        }
        if let duplicate = controllers.first(where: { value in controllers.filter { $0 == value }.count > 1 }) {
            throw BuildError.duplicateController(duplicate)
        }
        return MIDIOutputConfiguration(
            channel: channel, bendRangeSemitones: bendRangeSemitones, pitchDomain: pitchDomain,
            pitchInverted: pitchInverted, volumeController: volumeController,
            filterController: filterController, effectSendController: effectSendController
        )
    }

    /// Kanal auf dem Draht, `0...15`.
    var wireChannel: UInt8 { UInt8(channel - 1) }

}
