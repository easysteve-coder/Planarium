import Foundation

/// Built-in note effects. Array order is signal order; ownership stays in the ledger.
public struct InstrumentMIDIEffect: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case chord, arpeggiator }
    public var id: UUID
    public var kind: Kind = .chord
    public var bypassed: Bool
    public var arpeggiator: ArpeggiatorEffect = .init()
    public var chord: ChordEffect
    private enum CodingKeys: String, CodingKey { case id, kind, bypassed, chord, arpeggiator }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        bypassed = try c.decode(Bool.self, forKey: .bypassed)
        chord = try c.decode(ChordEffect.self, forKey: .chord)
        arpeggiator = try c.decodeIfPresent(ArpeggiatorEffect.self, forKey: .arpeggiator) ?? .init()
    }
    public init(arpeggiator: ArpeggiatorEffect) {
        id = UUID(); kind = .arpeggiator; bypassed = false; chord = .init(); self.arpeggiator = arpeggiator
    }
    public init(id: UUID = UUID(), bypassed: Bool = false, chord: ChordEffect = .init()) {
        self.id = id; self.bypassed = bypassed; self.chord = chord
    }
}

public struct ChordEffect: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case scale, single, multi }
    public var mode: Mode = .scale
    public var root: Int = 0
    public var scale: SpatialScale = .major
    public var toneCount: Int = 3
    public var inversion: Int = 0
    public var octave: Int = 0
    public var spread: Bool = false
    public var low: Int = 0
    public var high: Int = 127
    public var learnedTrigger: Int = 60
    public var singleNotes: [Int] = [60, 64, 67]
    public var multiNotes: [Int: [Int]] = [:]
    public init() {}
    public var isValid: Bool {
        (0...11).contains(root) && (3...4).contains(toneCount) && (0..<toneCount).contains(inversion)
        && (-3...3).contains(octave) && (0...127).contains(low) && (low...127).contains(high)
        && (0...127).contains(learnedTrigger) && Self.valid(singleNotes)
        && multiNotes.count <= 128 && multiNotes.allSatisfy { (0...127).contains($0.key) && Self.valid($0.value) }
    }
    private static func valid(_ notes: [Int]) -> Bool {
        notes.count <= 128 && Set(notes).count == notes.count && notes.allSatisfy { (0...127).contains($0) }
    }
    public func notes(for input: Int) -> [Int] {
        guard isValid, (low...high).contains(input) else { return [input] }
        switch mode {
        case .single: return singleNotes.map { $0 + input - learnedTrigger }.filter { (0...127).contains($0) }
        case .multi: return multiNotes[input] ?? [input]
        case .scale:
            let offsets = scale.semitoneOffsets.sorted()
            // Include neighboring octaves, so boundary quantization and inversions stay musical.
            let degrees = (-2...12).flatMap { oct in offsets.map { oct * 12 + root + $0 } }
            guard let nearest = degrees.indices.min(by: {
                let a = abs(degrees[$0] - input), b = abs(degrees[$1] - input)
                return a == b ? degrees[$0] < degrees[$1] : a < b
            }) else { return [] }
            var notes = (0..<toneCount).map { degrees[min(nearest + $0 * 2, degrees.count - 1)] }
            for _ in 0..<inversion { notes.append(notes.removeFirst() + 12) }
            return notes.enumerated().map { index, note in
                note + octave * 12 + (spread && index % 2 == 1 ? 12 : 0)
            }.filter { (0...127).contains($0) }.sorted()
        }
    }
}

/// Constructed when the document is compiled, never in the profile evaluation loop.
package struct CompiledMIDIEffectChain: Equatable, Sendable {
    package let pitches: [[UInt8]]
    package init(_ slots: [InstrumentMIDIEffect]) {
        let active = slots.filter { !$0.bypassed }
        let stages: [[[Int]]] = active.prefix { $0.kind != .arpeggiator }.map { slot in
            switch slot.kind {
            case .chord: return (0...127).map { slot.chord.notes(for: $0) }
            case .arpeggiator: return (0...127).map { [$0] }
            }
        }
        pitches = (0...127).map { input in
            var notes = [input]
            for stage in stages {
                notes = Array(Set(notes.flatMap { stage[$0] })).sorted()
            }
            return notes.map { UInt8($0) }
        }
    }
    package func apply(_ value: SpatialEvaluatedValue) -> SpatialEvaluatedValue {
        guard case let .notes(notes, transition) = value else { return value }
        var velocities: [UInt8: UInt8] = [:]
        for note in notes {
            for pitch in pitches[Int(note.number)] {
                velocities[pitch] = max(velocities[pitch] ?? 0, note.velocity)
            }
        }
        return .notes(Set(velocities.map { SpatialPlayedNote(number: $0.key, velocity: $0.value) }), transition: transition)
    }
}

public struct ArpeggiatorEffect: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, CaseIterable, Sendable { case up, down, upDown, random, asPlayed }
    public enum Rate: String, Codable, CaseIterable, Sendable {
        case quarter = "1/4", eighth = "1/8", eighthTriplet = "1/8T", sixteenth = "1/16", sixteenthTriplet = "1/16T", thirtySecond = "1/32"
        public var beats: Double {
            switch self {
            case .quarter: return 1
            case .eighth: return 0.5
            case .eighthTriplet: return 1.0 / 3
            case .sixteenth: return 0.25
            case .sixteenthTriplet: return 1.0 / 6
            case .thirtySecond: return 0.125
            }
        }
    }
    public var direction: Direction = .up
    public var rate: Rate = .sixteenth
    public var octaves = 1
    public var gate = 50.0
    public var swing = 0.0
    /// Zero preserves the velocity of the selected input note.
    public var velocity = 0
    public var syncToBeat = false
    public init() {}
    public var isValid: Bool {
        (1...4).contains(octaves) && gate.isFinite && (10...100).contains(gate)
        && swing.isFinite && (0...75).contains(swing) && (0...127).contains(velocity)
    }
}

/// Live modulation never changes the stored editor settings.
public enum ArpeggiatorModulationTarget: String, Codable, Hashable, CaseIterable, Sendable {
    case rate, octaves, gate, swing, velocity
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    package func apply(_ scalar: Double, to effect: inout ArpeggiatorEffect, previous: Double? = nil) -> Double {
        let unit = min(1, max(0, scalar.isFinite ? scalar : 0))
        let mapped: Double
        switch self {
        case .rate: mapped = unit * 5
        case .octaves: mapped = 1 + unit * 3
        case .gate: mapped = 10 + unit * 90
        case .swing: mapped = unit * 75
        case .velocity: mapped = 1 + unit * 126
        }
        let discrete = self == .rate || self == .octaves || self == .velocity
        // Half a step beyond the ordinary rounding boundary in either direction.
        let value = discrete ? (previous.map { abs(mapped - $0) < 1 ? $0 : mapped.rounded() } ?? mapped.rounded()) : mapped
        switch self {
        case .rate: effect.rate = ArpeggiatorEffect.Rate.allCases[Int(value)]
        case .octaves: effect.octaves = Int(value)
        case .gate: effect.gate = value
        case .swing: effect.swing = value
        case .velocity: effect.velocity = Int(value)
        }
        return value
    }
}

public extension SpatialRoutingTarget {
    func isAvailable(in channels: [InstrumentChannel]) -> Bool {
        if case .midiEffectParameter(let strip, let slot, _) = self {
            return channels.first { $0.id == strip }?.midiEffects.contains { $0.id == slot && $0.kind == .arpeggiator && !$0.bypassed } == true
        }
        return stripID.map { id in channels.contains { $0.id == id } } ?? true
    }
}
