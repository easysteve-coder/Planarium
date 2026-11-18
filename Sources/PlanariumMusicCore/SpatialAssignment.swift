import Foundation

/// Device-independent program selection. Only the display origin is one-based;
/// the stored and transmitted program and optional banks are always 0...127.
public struct SpatialProgramChange: Codable, Equatable, Sendable {
    public var program: UInt8
    public var countsFromOne: Bool
    public var bankMSB: UInt8?
    public var bankLSB: UInt8?
    public init(program: UInt8 = 0, countsFromOne: Bool = true, bankMSB: UInt8? = nil, bankLSB: UInt8? = nil) {
        self.program = min(program, 127); self.countsFromOne = countsFromOne
        self.bankMSB = bankMSB.map { min($0, 127) }; self.bankLSB = bankLSB.map { min($0, 127) }
    }
    public var displayedProgram: Int { Int(program) + (countsFromOne ? 1 : 0) }
    public var isValid: Bool { program <= 127 && (bankMSB.map { $0 <= 127 } ?? true) && (bankLSB.map { $0 <= 127 } ?? true) }
    private enum CodingKeys: String, CodingKey { case program, countsFromOne, bankMSB, bankLSB }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        program = try values.decodeIfPresent(UInt8.self, forKey: .program) ?? 0
        countsFromOne = try values.decodeIfPresent(Bool.self, forKey: .countsFromOne) ?? true
        bankMSB = try values.decodeIfPresent(UInt8.self, forKey: .bankMSB)
        bankLSB = try values.decodeIfPresent(UInt8.self, forKey: .bankLSB)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Program and bank must be 0–127"))
        }
    }
    public func hasSameWireSelection(as other: Self) -> Bool {
        program == other.program && bankMSB == other.bankMSB && bankLSB == other.bankLSB
    }
}

/// The assignment shape shown by the inspector. It deliberately keeps the
/// fields that are not currently edited so a draft can round-trip losslessly.
public enum SpatialAssignmentKind: Equatable, Sendable {
    case constant
    case continuous
    case scale
    case randomScale
    case chord
    case singleNote
    case programChange
}

public struct SpatialAssignmentDraft: Equatable, Sendable {
    public var target: SpatialRoutingTarget
    public var kind: SpatialAssignmentKind
    public var rootMIDINote: Int
    public var lowestMIDINote: Int
    public var highestMIDINote: Int
    public var scale: SpatialScale
    public var directionDegrees: Double
    public var ascending: Bool
    public var transition: SpatialNoteTransition
    public var seed: UInt64
    public var minimumValue: Double
    public var maximumValue: Double
    public var curve: SpatialValueCurve
    public var chordNotes: [Int]
    public var velocity: UInt8
    public var ccNumber: UInt8
    public var programChange: SpatialProgramChange = .init()

    /// Root spelling survives inversion; legacy custom voicings stay custom.
    public var chordPreset: SpatialChordPreset? {
        guard kind == .chord, let bass = chordNotes.min() else { return nil }
        if let exact = SpatialChordPreset.allCases.first(where: { $0.notes(root: rootMIDINote) == chordNotes }) { return exact }
        guard bass != rootMIDINote else { return nil }
        let intervals = Set(chordNotes.map { (($0 - rootMIDINote) % 12 + 12) % 12 })
        return SpatialChordPreset.allCases.first { $0.intervals.count == chordNotes.count && Set($0.intervals) == intervals }
    }

    public init(
        target: SpatialRoutingTarget,
        kind: SpatialAssignmentKind,
        rootMIDINote: Int = 60,
        lowestMIDINote: Int = 48,
        highestMIDINote: Int = 84,
        scale: SpatialScale = .major,
        directionDegrees: Double = 90,
        ascending: Bool = true,
        transition: SpatialNoteTransition = .legato,
        seed: UInt64 = 0,
        minimumValue: Double = 0,
        maximumValue: Double = 1,
        curve: SpatialValueCurve = .linear,
        chordNotes: [Int] = [60, 64, 67],
        velocity: UInt8 = 100,
        ccNumber: UInt8 = 74
    ) {
        self.target = target
        self.kind = kind
        self.rootMIDINote = rootMIDINote
        self.lowestMIDINote = lowestMIDINote
        self.highestMIDINote = highestMIDINote
        self.scale = scale
        self.directionDegrees = directionDegrees
        self.ascending = ascending
        self.transition = transition
        self.seed = seed
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.curve = curve
        self.chordNotes = chordNotes
        self.velocity = velocity
        self.ccNumber = ccNumber
    }

    public static func from(program: SpatialValueProgram, target: SpatialRoutingTarget) -> Self {
        let cc: UInt8
        cc = target.controllerNumber ?? 74
        switch program {
        case .programChange(let selection):
            var draft = Self(target: target, kind: .programChange)
            draft.programChange = selection
            return draft
        case .constant(let value):
            return Self(target: target, kind: .constant, minimumValue: value, maximumValue: value, ccNumber: cc)
        case .continuous(let minimum, let maximum, let direction, let curve):
            return Self(target: target, kind: .continuous, directionDegrees: direction,
                        minimumValue: minimum, maximumValue: maximum, curve: curve, ccNumber: cc)
        case .scale(let root, let low, let high, let scale, let direction, let ascending, let transition):
            return Self(target: target, kind: .scale, rootMIDINote: root, lowestMIDINote: low,
                        highestMIDINote: high, scale: scale, directionDegrees: direction,
                        ascending: ascending, transition: transition, ccNumber: cc)
        case .randomScale(let root, let low, let high, let scale, let seed, let transition):
            return Self(target: target, kind: .randomScale, rootMIDINote: root, lowestMIDINote: low,
                        highestMIDINote: high, scale: scale, transition: transition, seed: seed, ccNumber: cc)
        case .chord(let notes, let velocity, let transition):
            return Self(target: target, kind: .chord, rootMIDINote: notes.min() ?? 60,
                        transition: transition, chordNotes: notes,
                        velocity: velocity, ccNumber: cc)
        case .singleNote(let note, let velocity, let transition):
            return Self(target: target, kind: .singleNote, rootMIDINote: note,
                        transition: transition, velocity: velocity, ccNumber: cc)
        }
    }

    /// Changes the chord preset and derives its notes from the current root.
    public mutating func setChordPreset(_ preset: SpatialChordPreset) {
        kind = .chord
        chordNotes = preset.notes(root: rootMIDINote)
    }

    /// Sets a normalized, freely chosen chord and derives its root from the
    /// lowest selected note.
    @discardableResult
    public mutating func setChordNotes(_ notes: Set<Int>) -> Bool {
        let normalized = Array(Set(notes.filter { (0...127).contains($0) })).sorted()
        guard !normalized.isEmpty else { return false }
        kind = .chord
        chordNotes = normalized
        rootMIDINote = normalized[0]
        return true
    }

    /// Changes the root and transposes an existing chord by the same delta.
    public mutating func setRootMIDINote(_ root: Int) {
        let clampedRoot = min(max(root, 0), 127)
        let delta = clampedRoot - rootMIDINote
        if kind == .chord {
            chordNotes = chordNotes.map { min(max($0 + delta, 0), 127) }
        }
        rootMIDINote = clampedRoot
    }

    public static func program(from draft: Self) -> SpatialValueProgram {
        switch draft.kind {
        case .programChange: return .programChange(draft.programChange)
        case .constant:
            return .constant(draft.minimumValue)
        case .continuous:
            if case .midiEffectParameter = draft.target {
                return .continuous(minimum: draft.minimumValue, maximum: draft.maximumValue,
                                   directionDegrees: draft.directionDegrees, curve: draft.curve)
            }
            return .continuous(minimum: min(draft.minimumValue, draft.maximumValue),
                               maximum: max(draft.minimumValue, draft.maximumValue),
                               directionDegrees: draft.directionDegrees, curve: draft.curve)
        case .scale:
            return .scale(rootMIDINote: draft.rootMIDINote,
                          lowestMIDINote: min(draft.lowestMIDINote, draft.highestMIDINote),
                          highestMIDINote: max(draft.lowestMIDINote, draft.highestMIDINote),
                          scale: draft.scale, directionDegrees: draft.directionDegrees,
                          ascending: draft.ascending, transition: draft.transition == .toggle ? .retrigger : draft.transition)
        case .randomScale:
            return .randomScale(rootMIDINote: draft.rootMIDINote,
                                lowestMIDINote: min(draft.lowestMIDINote, draft.highestMIDINote),
                                highestMIDINote: max(draft.lowestMIDINote, draft.highestMIDINote),
                                scale: draft.scale, seed: draft.seed, transition: draft.transition == .toggle ? .retrigger : draft.transition)
        case .chord:
            return .chord(notes: draft.chordNotes, velocity: draft.velocity, transition: draft.transition)
        case .singleNote:
            return .singleNote(note: min(max(draft.rootMIDINote, 0), 127), velocity: draft.velocity, transition: draft.transition)
        }
    }

}

/// Atomic pitch edits: validate every resulting note before publishing a document.
public enum SpatialPitchOperation: Equatable, Sendable {
    case transpose(Int), invertDown, invertUp
    public var title: String {
        switch self { case .transpose: return "Transpose"; case .invertDown: return "Invert chord down"; case .invertUp: return "Invert chord up" }
    }
    public enum Failure: Error {
        case range
        /// Coarse cells were selected on a layer that consists of surfaces. A surface is edited whole:
        /// choose surfaces (or no selection, for the whole layer), never a cell of one.
        case cellsOfASurface
        /// A chosen surface no longer exists in the document.
        case unknownSurface
    }
    private func notes(_ source: [Int], chord: Bool) throws -> [Int] {
        var result = source.sorted()
        switch self {
        case .transpose(let amount):
            guard (-48...48).contains(amount) else { throw Failure.range }
            result = try result.map {
                let next = $0.addingReportingOverflow(amount)
                guard !next.overflow else { throw Failure.range }; return next.partialValue
            }
        case .invertDown:
            if chord, let highest = result.popLast() {
                let next = highest.subtractingReportingOverflow(12)
                guard !next.overflow else { throw Failure.range }; result.insert(next.partialValue, at: 0)
            }
        case .invertUp:
            if chord, !result.isEmpty {
                let next = result.removeFirst().addingReportingOverflow(12)
                guard !next.overflow else { throw Failure.range }; result.append(next.partialValue)
            }
        }
        guard result.allSatisfy({ (0...127).contains($0) }) else { throw Failure.range }
        return result.sorted()
    }
    public func applying(to value: SpatialCellValue) throws -> SpatialCellValue {
        switch value {
        case let .note(number, velocity): return .note(number: try notes([number], chord: false)[0], velocity: velocity)
        case let .chord(source, velocity): return .chord(notes: try notes(source, chord: true), velocity: velocity)
        case .scalar, .programChange, .boolean, .sceneSwitch, .releaseLayer: return value
        }
    }
    /// Whole-layer edit of assignments: each program, and the chord spelling that goes with it.
    public func apply(toRoutings routings: inout [SpatialRouting]) throws {
        for r in routings.indices {
            if case .chord(let notes, _, _) = routings[r].program {
                let root = routings[r].chordRootMIDINote ?? notes.min()
                if case .transpose = self, let root {
                    if case let .note(number, _) = try applying(to: SpatialCellValue.note(number: root, velocity: 100)) { routings[r].chordRootMIDINote = number }
                }
                else { routings[r].chordRootMIDINote = root }
            }
            routings[r].program = try applying(to: routings[r].program)
            if case let .chord(notes, _, _) = routings[r].program, routings[r].chordRootMIDINote == notes.min() {
                routings[r].chordRootMIDINote = nil
            }
        }
    }
    public func apply<Key: Hashable>(toOverrides overrides: inout [Key: [SpatialCellAction]]) throws {
        for key in overrides.keys {
            overrides[key] = try overrides[key]?.map {
                .init(target: $0.target, value: try applying(to: $0.value))
            }
        }
    }
    public func applying(to program: SpatialValueProgram) throws -> SpatialValueProgram {
        switch program {
        case let .singleNote(note, velocity, transition):
            return .singleNote(note: try notes([note], chord: false)[0], velocity: velocity, transition: transition)
        case let .chord(source, velocity, transition):
            return .chord(notes: try notes(source, chord: true), velocity: velocity, transition: transition)
        case let .scale(root, low, high, scale, direction, ascending, transition):
            guard case .transpose = self else { return program }
            let n = try [root, low, high].map { try notes([$0], chord: false)[0] }
            return .scale(rootMIDINote: n[0], lowestMIDINote: n[1], highestMIDINote: n[2], scale: scale, directionDegrees: direction, ascending: ascending, transition: transition)
        case let .randomScale(root, low, high, scale, seed, transition):
            guard case .transpose = self else { return program }
            let n = try [root, low, high].map { try notes([$0], chord: false)[0] }
            return .randomScale(rootMIDINote: n[0], lowestMIDINote: n[1], highestMIDINote: n[2], scale: scale, seed: seed, transition: transition)
        case .constant, .continuous, .programChange: return program
        }
    }
}
