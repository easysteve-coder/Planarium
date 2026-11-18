import Foundation

/// Persistierbare Farbe ohne Abhängigkeit von SwiftUI/AppKit.
public struct SpatialLayerColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let blue = SpatialLayerColor(red: 0.18, green: 0.55, blue: 0.96)
    /// FIRSTofFIFTH-Amber als primäre Bühnenfarbe.
    public static let orange = SpatialLayerColor(red: 1.00, green: 0.55, blue: 0.00)
    public static let green = SpatialLayerColor(red: 0.25, green: 0.78, blue: 0.42)
    public static let purple = SpatialLayerColor(red: 0.67, green: 0.36, blue: 0.88)
    /// Three rows of eight distinct hues: vivid, medium and muted.
    /// Existing documents retain their stored RGB values.
    public static let palette: [SpatialLayerColor] = [
        .orange, .init(red: 0.94, green: 0.80, blue: 0.12), .init(red: 0.20, green: 0.82, blue: 0.32), .init(red: 0.12, green: 0.78, blue: 0.84),
        .blue, .init(red: 0.60, green: 0.30, blue: 0.94), .init(red: 0.93, green: 0.22, blue: 0.68), .init(red: 0.95, green: 0.18, blue: 0.18),
        .init(red: 0.92, green: 0.68, blue: 0.40), .init(red: 0.85, green: 0.86, blue: 0.36), .init(red: 0.53, green: 0.79, blue: 0.48), .init(red: 0.42, green: 0.79, blue: 0.74),
        .init(red: 0.47, green: 0.68, blue: 0.92), .init(red: 0.67, green: 0.53, blue: 0.85), .init(red: 0.89, green: 0.48, blue: 0.69), .init(red: 0.95, green: 0.50, blue: 0.45),
        .init(red: 0.65, green: 0.45, blue: 0.26), .init(red: 0.58, green: 0.59, blue: 0.28), .init(red: 0.31, green: 0.55, blue: 0.36), .init(red: 0.27, green: 0.53, blue: 0.55),
        .init(red: 0.32, green: 0.43, blue: 0.66), .init(red: 0.48, green: 0.36, blue: 0.62), .init(red: 0.61, green: 0.32, blue: 0.48), .init(red: 0.64, green: 0.32, blue: 0.28)
    ]

}


/// Stabile AU-Komponentenkennung an der räumlichen Routinggrenze.
public struct SpatialAudioUnitIdentity: Codable, Hashable, Sendable {
    public var componentType: UInt32
    public var componentSubType: UInt32
    public var componentManufacturer: UInt32

    public init(componentType: UInt32, componentSubType: UInt32, componentManufacturer: UInt32) {
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
    }
}

public struct SpatialAudioUnitParameterTarget: Codable, Hashable, Sendable {
    public var stripID: UUID
    public var component: SpatialAudioUnitIdentity
    public var address: UInt64
    /// Herstellerkennung als zweite, menschenlesbare Prüfkante. Die Adresse
    /// bleibt autoritativ; bei Widerspruch wird nie still neu zugeordnet.
    public var identifier: String
    public var displayName: String

    public init(component: SpatialAudioUnitIdentity, address: UInt64, identifier: String, displayName: String, stripID: UUID) {
        self.stripID = stripID
        self.component = component
        self.address = address
        self.identifier = identifier
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey { case stripID, component, address, identifier, displayName }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stripID = try values.decodeIfPresent(UUID.self, forKey: .stripID) ?? SpatialRoutingTarget.missingStripID
        component = try values.decode(SpatialAudioUnitIdentity.self, forKey: .component)
        address = try values.decode(UInt64.self, forKey: .address)
        identifier = try values.decode(String.self, forKey: .identifier)
        displayName = try values.decode(String.self, forKey: .displayName)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if encoder.userInfo[SpatialRoutingTarget.legacyWireKey] as? Bool != true { try values.encode(stripID, forKey: .stripID) }
        try values.encode(component, forKey: .component)
        try values.encode(address, forKey: .address)
        try values.encode(identifier, forKey: .identifier)
        try values.encode(displayName, forKey: .displayName)
    }
}

public enum SpatialRoutingDestination: Equatable, Sendable {
    case audioUnit
    case midi
    case other
}

extension SpatialRoutingTarget {
    /// Wire-only compatibility. Live AU targets always carry a concrete ID.
    public static let missingStripID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    public static let legacyWireKey = CodingUserInfoKey(rawValue: "planarium.legacyTargetWire")!
    private enum Wire: Codable {
        case midiEffectParameter(stripID: UUID, slotID: UUID, parameter: ArpeggiatorModulationTarget)
        case audioUnitParameter(SpatialAudioUnitParameterTarget)
        case audioUnitNote(channel: UInt8, stripID: UUID?)
        case audioUnitAllNotesOff(channel: UInt8, stripID: UUID?)
        case audioUnitCC(channel: UInt8, controller: UInt8, stripID: UUID)
        case audioUnitProgramChange(channel: UInt8, stripID: UUID)
        case audioUnitPitchBend(channel: UInt8, stripID: UUID)
        case audioUnitChannelPressure(channel: UInt8, stripID: UUID)
        case midiNote(channel: UInt8)
        case midiCC(channel: UInt8, controller: UInt8)
        case midiProgramChange(channel: UInt8)
        case midiPitchBend(channel: UInt8)
        case midiChannelPressure(channel: UInt8)
        case midiAllNotesOff(channel: UInt8)
        case sceneSwitch(action: SpatialSceneSwitchAction, dwellSeconds: Double)
        case releaseLayer(layerID: UUID)
        case boolean(name: String)
    }
    public init(from decoder: Decoder) throws {
        switch try Wire(from: decoder) {
        case .midiEffectParameter(let id, let slot, let parameter): self = .midiEffectParameter(stripID: id, slotID: slot, parameter: parameter)
        case .audioUnitParameter(let value): self = .audioUnitParameter(value)
        case .audioUnitNote(let channel, let id): self = .audioUnitNote(channel: channel, stripID: id ?? Self.missingStripID)
        case .audioUnitAllNotesOff(let channel, let id): self = .audioUnitAllNotesOff(channel: channel, stripID: id ?? Self.missingStripID)
        case .audioUnitCC(let channel, let controller, let id): self = .audioUnitCC(channel: channel, controller: controller, stripID: id)
        case .audioUnitProgramChange(let channel, let id): self = .audioUnitProgramChange(channel: channel, stripID: id)
        case .audioUnitPitchBend(let channel, let id): self = .audioUnitPitchBend(channel: channel, stripID: id)
        case .audioUnitChannelPressure(let channel, let id): self = .audioUnitChannelPressure(channel: channel, stripID: id)
        case .midiNote(let channel): self = .midiNote(channel: channel)
        case .midiCC(let channel, let controller): self = .midiCC(channel: channel, controller: controller)
        case .midiProgramChange(let channel): self = .midiProgramChange(channel: channel)
        case .midiPitchBend(let channel): self = .midiPitchBend(channel: channel)
        case .midiChannelPressure(let channel): self = .midiChannelPressure(channel: channel)
        case .midiAllNotesOff(let channel): self = .midiAllNotesOff(channel: channel)
        case .sceneSwitch(let action, let dwell): self = .sceneSwitch(action: action, dwellSeconds: dwell)
        case .releaseLayer(let id): self = .releaseLayer(layerID: id)
        case .boolean(let name): self = .boolean(name: name)
        }
    }
    public func encode(to encoder: Encoder) throws {
        if encoder.userInfo[Self.legacyWireKey] as? Bool == true {
            switch self {
            case .audioUnitNote(let channel, _), .audioUnitAllNotesOff(let channel, _):
                var root = encoder.container(keyedBy: LegacyKeys.self)
                var payload = root.nestedContainer(keyedBy: LegacyKeys.self, forKey: {
                    if case .audioUnitNote = self { return .audioUnitNote }; return .audioUnitAllNotesOff
                }())
                try payload.encode(channel, forKey: .channel)
                return
            default: break
            }
        }
        let value: Wire
        switch self {
        case .midiEffectParameter(let id, let slot, let parameter): value = .midiEffectParameter(stripID: id, slotID: slot, parameter: parameter)
        case .audioUnitParameter(let target): value = .audioUnitParameter(target)
        case .audioUnitNote(let channel, let id): value = .audioUnitNote(channel: channel, stripID: id)
        case .audioUnitAllNotesOff(let channel, let id): value = .audioUnitAllNotesOff(channel: channel, stripID: id)
        case .audioUnitCC(let channel, let controller, let id): value = .audioUnitCC(channel: channel, controller: controller, stripID: id)
        case .audioUnitProgramChange(let channel, let id): value = .audioUnitProgramChange(channel: channel, stripID: id)
        case .audioUnitPitchBend(let channel, let id): value = .audioUnitPitchBend(channel: channel, stripID: id)
        case .audioUnitChannelPressure(let channel, let id): value = .audioUnitChannelPressure(channel: channel, stripID: id)
        case .midiNote(let channel): value = .midiNote(channel: channel)
        case .midiCC(let channel, let controller): value = .midiCC(channel: channel, controller: controller)
        case .midiProgramChange(let channel): value = .midiProgramChange(channel: channel)
        case .midiPitchBend(let channel): value = .midiPitchBend(channel: channel)
        case .midiChannelPressure(let channel): value = .midiChannelPressure(channel: channel)
        case .midiAllNotesOff(let channel): value = .midiAllNotesOff(channel: channel)
        case .sceneSwitch(let action, let dwell): value = .sceneSwitch(action: action, dwellSeconds: dwell)
        case .releaseLayer(let id): value = .releaseLayer(layerID: id)
        case .boolean(let name): value = .boolean(name: name)
        }
        try value.encode(to: encoder)
    }
    private enum LegacyKeys: String, CodingKey { case audioUnitNote, audioUnitAllNotesOff, channel }
}

/// A scene is an ordered, named snapshot of the audible layer set.  Control
/// layers are deliberately excluded by `SpatialInstrumentWorkspace`.
public struct SpatialScene: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var activeLayerIDs: Set<UUID>

    private enum CodingKeys: String, CodingKey { case id, name, activeLayerIDs }

    public init(id: UUID = UUID(), name: String, activeLayerIDs: Set<UUID>) {
        self.id = id
        self.name = name
        self.activeLayerIDs = activeLayerIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        activeLayerIDs = try values.decode(Set<UUID>.self, forKey: .activeLayerIDs)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(activeLayerIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .activeLayerIDs)
    }
}

public enum SpatialSceneSwitchAction: Codable, Hashable, Sendable {
    case next
    case previous
    case scene(UUID)
}

/// Gleichrangige Ziele des räumlichen Instruments.
public enum SpatialRoutingTarget: Codable, Hashable, Sendable {
    case midiEffectParameter(stripID: UUID, slotID: UUID, parameter: ArpeggiatorModulationTarget)
    case audioUnitParameter(SpatialAudioUnitParameterTarget)
    /// Noten ausschließlich an das im Kanalzug geladene AU-Instrument.
    case audioUnitNote(channel: UInt8, stripID: UUID)
    case audioUnitAllNotesOff(channel: UInt8, stripID: UUID)
    /// MIDI controls exclusively to the instrument of the selected strip.
    case audioUnitCC(channel: UInt8, controller: UInt8, stripID: UUID)
    case audioUnitProgramChange(channel: UInt8, stripID: UUID)
    case audioUnitPitchBend(channel: UInt8, stripID: UUID)
    case audioUnitChannelPressure(channel: UInt8, stripID: UUID)
    /// Notes exclusively to the selected CoreMIDI output.
    case midiNote(channel: UInt8)
    case midiCC(channel: UInt8, controller: UInt8)
    case midiProgramChange(channel: UInt8)
    case midiPitchBend(channel: UInt8)
    case midiChannelPressure(channel: UInt8)
    case midiAllNotesOff(channel: UInt8)
    /// A measured control-cell.  It is consumed by the runtime and never sent
    /// to MIDI or an audio unit.
    case sceneSwitch(action: SpatialSceneSwitchAction, dwellSeconds: Double)
    case releaseLayer(layerID: UUID)
    case boolean(name: String)

    public var isProgramChange: Bool {
        switch self { case .midiProgramChange, .audioUnitProgramChange: return true; default: return false }
    }
    public var controllerNumber: UInt8? {
        switch self { case .midiCC(_, let cc), .audioUnitCC(_, let cc, _): return cc; default: return nil }
    }
    public func withControllerNumber(_ cc: UInt8) -> Self {
        switch self {
        case .midiCC(let ch, _): return .midiCC(channel: ch, controller: cc)
        case .audioUnitCC(let ch, _, let id): return .audioUnitCC(channel: ch, controller: cc, stripID: id)
        default: return self
        }
    }
    /// Retarget the same MIDI message and values between a strip and CoreMIDI.
    public func retargeted(to destination: SpatialRoutingDestination, stripID: UUID) -> Self {
        if self.destination == destination {
            return destination == .audioUnit ? withStripID(stripID) : self
        }
        let channel = midiChannel ?? 0
        switch (self, destination) {
        case (.midiCC(_, let cc), .audioUnit): return .audioUnitCC(channel: channel, controller: cc, stripID: stripID)
        case (.midiProgramChange, .audioUnit): return .audioUnitProgramChange(channel: channel, stripID: stripID)
        case (.midiPitchBend, .audioUnit): return .audioUnitPitchBend(channel: channel, stripID: stripID)
        case (.midiChannelPressure, .audioUnit): return .audioUnitChannelPressure(channel: channel, stripID: stripID)
        case (.midiAllNotesOff, .audioUnit): return .audioUnitAllNotesOff(channel: channel, stripID: stripID)
        case (.audioUnitCC(_, let cc, _), .midi): return .midiCC(channel: channel, controller: cc)
        case (.audioUnitProgramChange, .midi): return .midiProgramChange(channel: channel)
        case (.audioUnitPitchBend, .midi): return .midiPitchBend(channel: channel)
        case (.audioUnitChannelPressure, .midi): return .midiChannelPressure(channel: channel)
        case (.audioUnitAllNotesOff, .midi): return .midiAllNotesOff(channel: channel)
        case (_, .audioUnit): return .audioUnitNote(channel: channel, stripID: stripID)
        case (_, .midi): return .midiNote(channel: channel)
        case (_, .other): return self
        }
    }

    public var isLayerControl: Bool {
        switch self {
        case .sceneSwitch, .releaseLayer: return true
        default: return false
        }
    }

    public var stripID: UUID? {
        switch self {
        case .audioUnitNote(_, let id), .audioUnitAllNotesOff(_, let id), .audioUnitCC(_, _, let id),
             .audioUnitProgramChange(_, let id), .audioUnitPitchBend(_, let id), .audioUnitChannelPressure(_, let id): return id
        case .midiEffectParameter(let id, _, _): return id
        case .audioUnitParameter(let target): return target.stripID
        default: return nil
        }
    }
    public func withStripID(_ id: UUID) -> Self {
        switch self {
        case .audioUnitNote(let channel, _): return .audioUnitNote(channel: channel, stripID: id)
        case .audioUnitAllNotesOff(let channel, _): return .audioUnitAllNotesOff(channel: channel, stripID: id)
        case .audioUnitCC(let ch, let cc, _): return .audioUnitCC(channel: ch, controller: cc, stripID: id)
        case .audioUnitProgramChange(let ch, _): return .audioUnitProgramChange(channel: ch, stripID: id)
        case .audioUnitPitchBend(let ch, _): return .audioUnitPitchBend(channel: ch, stripID: id)
        case .audioUnitChannelPressure(let ch, _): return .audioUnitChannelPressure(channel: ch, stripID: id)
        case .midiEffectParameter(_, let slot, let parameter): return .midiEffectParameter(stripID: id, slotID: slot, parameter: parameter)
        case .audioUnitParameter(var target): target.stripID = id; return .audioUnitParameter(target)
        default: return self
        }
    }

    public var destination: SpatialRoutingDestination {
        switch self {
        case .audioUnitParameter, .audioUnitNote, .audioUnitAllNotesOff, .audioUnitCC,
             .audioUnitProgramChange, .audioUnitPitchBend, .audioUnitChannelPressure:
            return .audioUnit
        case .midiNote, .midiCC, .midiProgramChange, .midiPitchBend, .midiChannelPressure, .midiAllNotesOff:
            return .midi
        case .midiEffectParameter, .sceneSwitch, .releaseLayer, .boolean:
            return .other
        }
    }

    public var midiChannel: UInt8? {
        switch self {
        case .audioUnitCC(let channel, _, _), .audioUnitProgramChange(let channel, _),
             .audioUnitPitchBend(let channel, _), .audioUnitChannelPressure(let channel, _),
             .audioUnitNote(let channel, _), .audioUnitAllNotesOff(let channel, _): return channel
        case .midiNote(let channel): return channel
        case .midiCC(let channel, _): return channel
        case .midiProgramChange(let channel): return channel
        case .midiPitchBend(let channel): return channel
        case .midiChannelPressure(let channel): return channel
        case .midiAllNotesOff(let channel): return channel
        case .midiEffectParameter, .audioUnitParameter, .sceneSwitch, .releaseLayer, .boolean:
            return nil
        }
    }

    public func withMIDIChannel(_ channel: UInt8) -> SpatialRoutingTarget {
        switch self {
        case .midiEffectParameter: return self
        case .audioUnitParameter(let parameter):
            return .audioUnitParameter(parameter)
        case .audioUnitNote(_, let id):
            return .audioUnitNote(channel: channel, stripID: id)
        case .audioUnitAllNotesOff(_, let id):
            return .audioUnitAllNotesOff(channel: channel, stripID: id)
        case .audioUnitCC(_, let cc, let id): return .audioUnitCC(channel: channel, controller: cc, stripID: id)
        case .audioUnitProgramChange(_, let id): return .audioUnitProgramChange(channel: channel, stripID: id)
        case .audioUnitPitchBend(_, let id): return .audioUnitPitchBend(channel: channel, stripID: id)
        case .audioUnitChannelPressure(_, let id): return .audioUnitChannelPressure(channel: channel, stripID: id)
        case .midiNote:
            return .midiNote(channel: channel)
        case .midiCC(_, let controller):
            return .midiCC(channel: channel, controller: controller)
        case .midiProgramChange: return .midiProgramChange(channel: channel)
        case .midiPitchBend:
            return .midiPitchBend(channel: channel)
        case .midiChannelPressure:
            return .midiChannelPressure(channel: channel)
        case .midiAllNotesOff:
            return .midiAllNotesOff(channel: channel)
        case .sceneSwitch(let action, let dwellSeconds):
            return .sceneSwitch(action: action, dwellSeconds: dwellSeconds)
        case .releaseLayer: return self
        case .boolean(let name):
            return .boolean(name: name)
        }
    }
}

public enum SpatialScale: String, Codable, CaseIterable, Sendable {
    case chromatic
    case major
    case naturalMinor
    case majorPentatonic
    case minorPentatonic

    public var semitoneOffsets: [Int] {
        switch self {
        case .chromatic: return Array(0..<12)
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .naturalMinor: return [0, 2, 3, 5, 7, 8, 10]
        case .majorPentatonic: return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        }
    }
}

/// English musical note names for the interface. MIDI note numbers remain the
/// canonical internal representation.
public enum MIDINoteName {
    private static let pitchClasses = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    public static func pitchClassName(for note: Int) -> String {
        let clamped = min(max(note, 0), 127)
        return pitchClasses[clamped % 12]
    }

    public static func displayName(for note: Int) -> String {
        let clamped = min(max(note, 0), 127)
        return "\(pitchClassName(for: clamped))\(clamped / 12 - 1)"
    }
}

public enum SpatialChordPreset: String, Codable, CaseIterable, Sendable {
    case major, minor, power, diminished, augmented, suspended2, suspended4
    case dominant7, major7, minor7

    public var displayName: String {
        switch self {
        case .major: return "Major"
        case .minor: return "Minor"
        case .power: return "Power Chord"
        case .diminished: return "Diminished"
        case .augmented: return "Augmented"
        case .suspended2: return "Sus2"
        case .suspended4: return "Sus4"
        case .dominant7: return "Dominant 7"
        case .major7: return "Major 7"
        case .minor7: return "Minor 7"
        }
    }

    public var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .power: return [0, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .suspended2: return [0, 2, 7]
        case .suspended4: return [0, 5, 7]
        case .dominant7: return [0, 4, 7, 10]
        case .major7: return [0, 4, 7, 11]
        case .minor7: return [0, 3, 7, 10]
        }
    }

    public func notes(root: Int) -> [Int] {
        intervals.map { min(max(root + $0, 0), 127) }
    }
}

public enum SpatialValueCurve: String, Codable, CaseIterable, Sendable {
    case linear
    case easeIn
    case easeOut
}

/// Shared pitches on a musical transition; old documents default to Keep.
public enum SpatialCommonNotes: String, Codable, CaseIterable, Sendable {
    case keep
    case retrigger
}

public enum SpatialNoteTransition: Codable, Equatable, Hashable, Sendable {
    case retrigger
    case legato
    case overlap(milliseconds: Double)
    /// Ton/Akkord bleibt nach Verlassen der Fläche stehen und wird erst
    /// durch den nächsten gehaltenen Klang desselben Kanals ersetzt.
    case holdUntilNext
    /// Each measured cell entry flips its own persistent note ownership.
    case toggle
}

/// Wiederholbare Assistentendefinition. Werte werden daraus am Raster neu
/// berechnet; eine Rasteränderung skaliert daher keine Farben oder MIDI-Werte.
public enum SpatialValueProgram: Codable, Equatable, Sendable {
    case programChange(SpatialProgramChange)
    case constant(Double)
    case continuous(minimum: Double, maximum: Double, directionDegrees: Double, curve: SpatialValueCurve)
    case scale(rootMIDINote: Int, lowestMIDINote: Int, highestMIDINote: Int, scale: SpatialScale,
               directionDegrees: Double, ascending: Bool, transition: SpatialNoteTransition)
    case randomScale(rootMIDINote: Int, lowestMIDINote: Int, highestMIDINote: Int, scale: SpatialScale,
                     seed: UInt64, transition: SpatialNoteTransition)
    case chord(notes: [Int], velocity: UInt8, transition: SpatialNoteTransition)
    case singleNote(note: Int, velocity: UInt8, transition: SpatialNoteTransition)

    public var supportsToggle: Bool {
        switch self {
        case .singleNote, .chord: return true
        case .scale, .randomScale, .constant, .continuous, .programChange: return false
        }
    }

    /// Compatibility normalization at the load/editor boundary.
    public var replacingUnsupportedToggle: Self {
        switch self {
        case let .scale(root, low, high, scale, direction, ascending, .toggle):
            return .scale(rootMIDINote: root, lowestMIDINote: low, highestMIDINote: high,
                          scale: scale, directionDegrees: direction, ascending: ascending, transition: .retrigger)
        case let .randomScale(root, low, high, scale, seed, .toggle):
            return .randomScale(rootMIDINote: root, lowestMIDINote: low, highestMIDINote: high,
                                scale: scale, seed: seed, transition: .retrigger)
        default: return self
        }
    }
}

public struct SpatialRouting: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var target: SpatialRoutingTarget
    /// Chord spelling independent of inversion bass; absent means the legacy lowest note.
    public var chordRootMIDINote: Int?
    public var program: SpatialValueProgram

    public init(id: UUID = UUID(), target: SpatialRoutingTarget, program: SpatialValueProgram, chordRootMIDINote: Int? = nil) {
        self.id = id
        self.target = target
        self.program = program
        self.chordRootMIDINote = chordRootMIDINote
    }
}

public enum SpatialCellValue: Codable, Equatable, Sendable {
    case programChange(SpatialProgramChange)
    case scalar(Double)
    case note(number: Int, velocity: UInt8)
    case chord(notes: [Int], velocity: UInt8)
    case boolean(Bool)
    case sceneSwitch(action: SpatialSceneSwitchAction)
    case releaseLayer(layerID: UUID)
}

public struct SpatialCellAction: Codable, Equatable, Sendable {
    public var target: SpatialRoutingTarget
    public var value: SpatialCellValue

    public init(target: SpatialRoutingTarget, value: SpatialCellValue) {
        self.target = target
        self.value = value
    }
}

