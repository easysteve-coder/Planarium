import PlanariumDomain
import Foundation

/// Reines Präsentationsmodell für die kleine Zuweisungsklaviatur.
/// Die View kennt weder MIDI-Grenzen noch die Notennamenlogik.
public struct PianoKeyboardModel: Equatable, Sendable {
    public static let lowestOctave = 0
    public static let highestOctave = 9
    public static let visibleNoteCount = 24

    public let minimumOctave: Int
    public private(set) var octave: Int
    public private(set) var selectedNotes: Set<Int>

    public init(octave: Int = 4, selectedNotes: Set<Int> = [], minimumOctave: Int = Self.lowestOctave) {
        self.minimumOctave = min(max(minimumOctave, -1), Self.lowestOctave)
        self.octave = min(max(octave, self.minimumOctave), Self.highestOctave)
        self.selectedNotes = selectedNotes.filter { (0...127).contains($0) }
    }

    public var visibleNotes: [Int] {
        // Die UI-Oktavzahl folgt dem lesbaren Notennamen: Oktave 4 beginnt
        // bei C4 = MIDI 60, nicht bei MIDI 48 (C3).
        let start = (octave + 1) * 12
        return Array(start...min(start + Self.visibleNoteCount - 1, 127))
    }

    public var selectedNoteNames: String {
        selectedNotes.sorted().map(Self.displayName(for:)).joined(separator: " ")
    }

    public mutating func shiftOctave(by amount: Int) {
        octave = min(max(octave + amount, minimumOctave), Self.highestOctave)
    }

    public mutating func toggle(note: Int) {
        guard (0...127).contains(note) else { return }
        if selectedNotes.contains(note) { selectedNotes.remove(note) }
        else { selectedNotes.insert(note) }
    }

    public mutating func setSelectedNotes(_ notes: Set<Int>) {
        selectedNotes = notes.filter { (0...127).contains($0) }
    }

    public static func isBlackKey(_ note: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(note.modulo12)
    }

    public static func displayName(for note: Int) -> String {
        MIDINoteName.displayName(for: note)
    }

    public static func keyLabel(for note: Int, selected: Bool, keyWidth: CGFloat) -> String {
        selected && keyWidth < 28
            ? MIDINoteName.pitchClassName(for: note)
            : displayName(for: note)
    }
}

private extension Int {
    var modulo12: Int { ((self % 12) + 12) % 12 }
}
