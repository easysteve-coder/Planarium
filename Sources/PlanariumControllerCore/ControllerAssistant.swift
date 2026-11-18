import Foundation
import PlanariumMusicCore

/// Where an assistant sends its notes and controls: one Audio Unit strip or
/// one MIDI channel of the sum output.
public enum ControllerAssistantOutput: Equatable, Sendable {
    case audioUnit(stripID: UUID, channel: UInt8)
    case midi(channel: UInt8)

    func note() -> SpatialRoutingTarget {
        switch self {
        case let .audioUnit(strip, channel): return .audioUnitNote(channel: channel, stripID: strip)
        case let .midi(channel): return .midiNote(channel: channel)
        }
    }
    func cc(_ controller: UInt8) -> SpatialRoutingTarget {
        switch self {
        case let .audioUnit(strip, channel): return .audioUnitCC(channel: channel, controller: controller, stripID: strip)
        case let .midi(channel): return .midiCC(channel: channel, controller: controller)
        }
    }
}

/// Ready-made assignment sets for a quick start. Each replaces the
/// assignments of the elements it uses and keeps all others.
public enum ControllerAssistant: String, CaseIterable, Sendable {
    /// Six pads: face buttons and shoulders play General MIDI drums.
    case drums
    /// Right stick plays a scale around the stick, R2 opens the filter, L1 holds (sustain).
    case melody
    /// Face buttons play the four chords I–V–vi–IV of a key; the D-pad holds.
    case chords

    public var title: String {
        switch self {
        case .drums: return "Drums"
        case .melody: return "Melody"
        case .chords: return "Chords"
        }
    }

    public func assignments(output: ControllerAssistantOutput, rootMIDINote: Int = 60) -> [ControllerAssignment] {
        let palette = SpatialLayerColor.palette
        func color(_ index: Int) -> SpatialLayerColor { palette[index % palette.count] }
        switch self {
        case .drums:
            let pads: [(ControllerElement, String, Int)] = [
                (.cross, "Kick", 36), (.circle, "Snare", 38), (.square, "Closed hat", 42),
                (.triangle, "Open hat", 46), (.l1, "Crash", 49), (.r1, "Ride", 51),
            ]
            return pads.enumerated().map { index, pad in
                .init(name: pad.1, color: color(index), element: pad.0,
                      routing: .init(target: output.note(), program: .singleNote(note: pad.2, velocity: 100, transition: .retrigger)))
            }
        case .melody:
            let low = max(0, min(127, rootMIDINote)), high = max(low, min(127, rootMIDINote + 12))
            return [
                .init(name: "Melody", color: color(4), element: .rightStick,
                      routing: .init(target: output.note(), program: .scale(rootMIDINote: low, lowestMIDINote: low, highestMIDINote: high,
                                                                          scale: .major, directionDegrees: 90, ascending: true, transition: .legato))),
                .init(name: "Filter", color: color(3), element: .r2,
                      routing: .init(target: output.cc(74), program: .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear))),
                .init(name: "Sustain", color: color(2), element: .l1,
                      routing: .init(target: output.cc(64), program: .constant(1))),
            ]
        case .chords:
            // I, V, vi, IV in the major key of the root.
            let chords: [(ControllerElement, String, [Int])] = [
                (.cross, "I", [0, 4, 7]), (.circle, "V", [7, 11, 14]),
                (.square, "vi", [9, 12, 16]), (.triangle, "IV", [5, 9, 12]),
            ]
            return chords.enumerated().compactMap { index, chord in
                let notes = chord.2.map { rootMIDINote + $0 }.filter { (0...127).contains($0) }
                guard !notes.isEmpty else { return nil }
                return .init(name: chord.1, color: color(index), element: chord.0,
                             routing: .init(target: output.note(), program: .chord(notes: notes, velocity: 96, transition: .holdUntilNext)))
            }
        }
    }

    /// The layout with this assistant's assignments in place of the ones on
    /// the same elements.
    public func applied(to layout: ControllerLayout, output: ControllerAssistantOutput, rootMIDINote: Int = 60) -> ControllerLayout {
        let added = assignments(output: output, rootMIDINote: rootMIDINote)
        let used = Set(added.map(\.element))
        var next = layout
        next.assignments = layout.assignments.filter { !used.contains($0.element) } + added
        return next
    }
}
