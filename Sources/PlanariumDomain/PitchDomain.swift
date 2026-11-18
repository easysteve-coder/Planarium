/// MIDI-Notendomäne für die unverändert lesbaren MIDI-/Preset-Einstellungen.
public struct PitchDomain: Equatable, Sendable {
    public enum BuildError: Error, Equatable {
        /// Grundnote außerhalb des MIDI-Notenraums `0...127`.
        case rootNoteOutOfRange(Int)
        /// Ein Umfang von null oder weniger Halbtönen wäre keine
        /// Tonhöhensteuerung.
        case spanNotPositive(Int)
        /// Grundnote plus Umfang verlässt den MIDI-Notenraum.
        case spanExceedsNoteRange(rootNote: Int, spanSemitones: Int)
    }

    /// Grundnote als MIDI-Notennummer (`69` = A4).
    public let rootNote: Int
    /// Umfang in Halbtönen über der Grundnote.
    public let spanSemitones: Int

    private init(rootNote: Int, spanSemitones: Int) {
        self.rootNote = rootNote
        self.spanSemitones = spanSemitones
    }

    /// A1 (MIDI 33) plus fünf Oktaven -- deckungsgleich mit dem
    /// musikalischen Startwert des Audiopfads (55 Hz … 1760 Hz).
    public static let standard = PitchDomain(rootNote: 33, spanSemitones: 60)

    public static func build(rootNote: Int, spanSemitones: Int) throws -> PitchDomain {
        guard (0...127).contains(rootNote) else { throw BuildError.rootNoteOutOfRange(rootNote) }
        guard spanSemitones > 0 else { throw BuildError.spanNotPositive(spanSemitones) }
        guard rootNote + spanSemitones <= 127 else {
            throw BuildError.spanExceedsNoteRange(rootNote: rootNote, spanSemitones: spanSemitones)
        }
        return PitchDomain(rootNote: rootNote, spanSemitones: spanSemitones)
    }

    /// Höchste Note der Domäne.
    public var topNote: Int { rootNote + spanSemitones }

}
