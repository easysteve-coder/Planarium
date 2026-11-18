import PlanariumDomain
import Foundation

/// Reine Zellbeschriftung für die statische Instrumentebene.
public enum SpatialCellLabel {
    public static func hasOwnValue(cell: PolarMetricGridCell, layer: SpatialInstrumentLayer) -> Bool {
        layer.polarCellOverrides[cell]?.isEmpty == false
    }
    public static func text(
        for value: SpatialEvaluatedValue,
        target: SpatialRoutingTarget,
        preferredChordName: String? = nil
    ) -> String? {
        switch value {
        case .programChange(let selection): return "PC \(selection.displayedProgram)"
        case .inactive:
            return nil
        case let .notes(notes, _):
            let numbers = notes.map { Int($0.number) }.sorted()
            guard let root = numbers.first else { return nil }
            let rootName = MIDINoteName.displayName(for: root)
            if numbers.count == 1 { return rootName }

            if let chord = chordName(notes: numbers, preferredName: preferredChordName) { return chord }
            return "\(rootName) +\(max(0, numbers.count - 1))"
        case let .scalar(value):
            switch target {
            case .midiCC, .audioUnitCC:
                return String(Int((value * 127).rounded()))
            case .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure, .audioUnitParameter, .midiEffectParameter:
                return "\(Int((value * 100).rounded())) %"
            default:
                return String(Int(value.rounded()))
            }
        case let .boolean(value):
            return value ? "on" : "off"
        }
    }

    /// Inversions are named from pitch classes. A separately voiced bass
    /// (below a complete upper chord) is retained as a slash bass.
    public static func chordName(notes: [Int], preferredName: String? = nil) -> String? {
        if let preferredName, let parsed = parse(preferredName),
           parsed.classes == Set(notes.map { (($0 % 12)+12)%12 }) {
            return parsed.name
        }
        let sorted = Array(Set(notes)).sorted()
        guard let bass = sorted.first else { return nil }
        if sorted.count >= 4, sorted[1] - bass > 7,
           let upper = recognize(Array(sorted.dropFirst())) {
            return upper.root == bass % 12 ? upper.name : upper.name + "/" + MIDINoteName.pitchClassName(for: bass)
        }
        return recognize(sorted)?.name
    }

    private static let qualities: [(String, [Int])] = [
        ("", [0,4,7]), ("m", [0,3,7]), ("°", [0,3,6]), ("+", [0,4,8]),
        ("7", [0,4,7,10]), ("maj7", [0,4,7,11]), ("m7", [0,3,7,10]),
        ("m7♭5", [0,3,6,10]), ("°7", [0,3,6,9]),
        ("sus2", [0,2,7]), ("sus4", [0,5,7]), ("6", [0,4,7,9]), ("m6", [0,3,7,9])
    ]
    private static func parse(_ text: String) -> (classes: Set<Int>, name: String)? {
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(pieces.count) else { return nil }
        func root(_ text: String) -> (pc: Int, name: String, rest: String)? {
            guard let first = text.first, let base = ["C":0,"D":2,"E":4,"F":5,"G":7,"A":9,"B":11,"H":11][String(first)] else { return nil }
            var rest = String(text.dropFirst()), pc = base, name = String(first)
            if let accidental = rest.first, ["b","♭","#","♯"].contains(String(accidental)) {
                let flat = accidental == "b" || accidental == "♭"
                pc += flat ? -1 : 1; name += flat ? "♭" : "♯"; rest = String(rest.dropFirst())
            }
            return ((pc+12)%12,name,rest)
        }
        guard let chordRoot = root(pieces[0]) else { return nil }
        let suffix = chordRoot.rest.replacingOccurrences(of: "b", with: "♭").replacingOccurrences(of: "o", with: "°")
        guard let intervals = qualities.first(where: { $0.0 == suffix })?.1 else { return nil }
        var classes = Set(intervals.map { (chordRoot.pc+$0)%12 })
        var name = chordRoot.name+suffix
        if pieces.count == 2 {
            guard let bass = root(pieces[1]), bass.rest.isEmpty else { return nil }
            classes.insert(bass.pc); name += "/"+bass.name
        }
        return (classes,name)
    }

    private static func recognize(_ notes: [Int]) -> (root: Int, name: String)? {
        guard let bass = notes.min() else { return nil }
        let classes = Set(notes.map { (($0 % 12) + 12) % 12 })
        // Bass first resolves symmetric chords deterministically. Quality
        // precedence resolves nonsymmetric enharmonic ambiguities (m7/6).
        for (suffix, intervals) in qualities {
            let roots = [bass % 12] + classes.sorted().filter { $0 != bass % 12 }
            for root in roots where Set(intervals.map { (root + $0) % 12 }) == classes {
                return (root, MIDINoteName.pitchClassName(for: root) + suffix)
            }
        }
        return nil
    }

    /// Prüft die Sichtbarkeit ausschließlich in Bildschirm-Punkten.
    public static func isVisible(
        segment: PolarMetricCellSegment,
        metersPerPoint: Double
    ) -> Bool {
        guard metersPerPoint > 0, metersPerPoint.isFinite else { return false }
        let radialPoints = segment.radialHeightMeters / metersPerPoint
        let arcPoints = segment.outerArcWidthMeters / metersPerPoint
        return radialPoints >= 14 && arcPoints >= 14
    }
}
