import Foundation

/// Every playing source (the scanner, each game controller) owns its sound
/// targets exclusively (Owner 18.11.2026). The one allowed split: on one target
/// one source plays the notes and another sends the controls. Even then each
/// class has exactly one owner.
public enum OutputClass: String, Codable, Hashable, Sendable, CaseIterable {
    /// Note on/off with velocity, hold, program change and bank select, and the
    /// channel-mode messages that end notes (CC 120–127, All Notes Off).
    case notes
    /// Continuous controls: CC (except bank select and channel mode), sustain,
    /// pitch bend, channel pressure, Audio Unit and MIDI-effect parameters.
    case controls
}

/// A resolved sound target: an Audio Unit instrument (all its channels) or one
/// channel of one CoreMIDI output. Aliases of the same output resolve to the
/// same key before ownership is compared.
public enum OutputTargetKey: Hashable, Sendable, CustomStringConvertible {
    case audioUnit(stripID: UUID)
    case midi(endpoint: Int32?, channel: UInt8)

    public var description: String {
        switch self {
        case .audioUnit(let id): return "AU \(id.uuidString.prefix(8))"
        case .midi(let endpoint, let channel): return "MIDI \(endpoint.map(String.init) ?? "sum") ch \(Int(channel) + 1)"
        }
    }
}

/// Identifies one playing source. The scanner is one source; every controller
/// slot is its own.
public struct PlayingSourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let scanner = PlayingSourceID("scanner")
    public static func controller(_ slot: Int) -> PlayingSourceID { .init("controller.\(slot)") }
    public var description: String { rawValue }
}

public struct OutputClaim: Hashable, Sendable {
    public let source: PlayingSourceID
    public let target: OutputTargetKey
    public let outputClass: OutputClass
    public init(source: PlayingSourceID, target: OutputTargetKey, outputClass: OutputClass) {
        self.source = source; self.target = target; self.outputClass = outputClass
    }
}

public struct OutputConflict: Hashable, Sendable {
    public let target: OutputTargetKey
    public let outputClass: OutputClass
    public let owner: PlayingSourceID
    public let rejected: PlayingSourceID
}

public enum OutputOwnership {
    /// The class a routing target sends in, or nil for targets that never reach
    /// a sound output (scene switches, layer release, named booleans).
    public static func outputClass(of target: SpatialRoutingTarget) -> OutputClass? {
        switch target {
        case .midiNote, .audioUnitNote, .midiProgramChange, .audioUnitProgramChange,
             .midiAllNotesOff, .audioUnitAllNotesOff:
            return .notes
        case .midiCC(_, let cc), .audioUnitCC(_, let cc, _):
            return controllerClass(cc)
        case .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure,
             .audioUnitParameter, .midiEffectParameter:
            return .controls
        case .sceneSwitch, .releaseLayer, .boolean:
            return nil
        }
    }

    /// Bank select (0/32) selects the sound that is played; channel mode
    /// (120–127) ends or resets notes. Both belong to the note owner.
    public static func controllerClass(_ cc: UInt8) -> OutputClass {
        switch cc {
        case 0, 32, 120...127: return .notes
        default: return .controls
        }
    }

    /// Resolves a target to its physical key. `midiEndpoint` is the explicit
    /// CoreMIDI output of the routing; `sumEndpoint` the instrument's sum output,
    /// so `.midi` and an explicit sum endpoint compare equal.
    public static func key(of target: SpatialRoutingTarget, midiEndpoint: Int32?, sumEndpoint: Int32?) -> OutputTargetKey? {
        if let strip = target.stripID, target.destination != .midi { return .audioUnit(stripID: strip) }
        guard target.destination == .midi, let channel = target.midiChannel else { return nil }
        return .midi(endpoint: midiEndpoint ?? sumEndpoint, channel: channel & 0x0F)
    }

    /// First claim wins (callers order the established source first); every
    /// later claim of the same target and class by another source is a conflict.
    public static func conflicts(_ claims: [OutputClaim]) -> [OutputConflict] {
        var owners: [OutputTargetKey: [OutputClass: PlayingSourceID]] = [:]
        var result: [OutputConflict] = []
        for claim in claims {
            if let owner = owners[claim.target]?[claim.outputClass] {
                if owner != claim.source {
                    result.append(.init(target: claim.target, outputClass: claim.outputClass, owner: owner, rejected: claim.source))
                }
            } else {
                owners[claim.target, default: [:]][claim.outputClass] = claim.source
            }
        }
        return Array(Set(result)).sorted { "\($0.target)\($0.outputClass)\($0.rejected)" < "\($1.target)\($1.outputClass)\($1.rejected)" }
    }
}
