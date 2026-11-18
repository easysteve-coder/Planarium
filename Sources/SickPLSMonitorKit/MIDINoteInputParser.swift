import Foundation

/// Reiner Parser für die kurze Noteneingabe im Inspector.
///
/// The input is intentionally small and unambiguous: an English note name
/// followed by a MIDI octave. The resulting
/// MIDI-Adresse bleibt immer im Bereich 0...127.
public enum MIDINoteInputParser {
    public static func parse(_ input: String) -> Int? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let pattern = #"^([A-Ga-g](?:b|♭|#|♯)?)(-?\d+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let nameRange = Range(match.range(at: 1), in: value),
              let octaveRange = Range(match.range(at: 2), in: value),
              let octave = Int(value[octaveRange]) else { return nil }

        let pitchClass: Int?
        switch value[nameRange].lowercased()
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b") {
        case "c": pitchClass = 0
        case "c#", "db": pitchClass = 1
        case "d": pitchClass = 2
        case "d#", "eb": pitchClass = 3
        case "e": pitchClass = 4
        case "f": pitchClass = 5
        case "f#", "gb": pitchClass = 6
        case "g": pitchClass = 7
        case "g#", "ab": pitchClass = 8
        case "a": pitchClass = 9
        case "a#", "bb": pitchClass = 10
        case "b": pitchClass = 11
        default: pitchClass = nil
        }
        guard let pitchClass else { return nil }

        let midi = (octave + 1) * 12 + pitchClass
        return (0...127).contains(midi) ? midi : nil
    }
}
