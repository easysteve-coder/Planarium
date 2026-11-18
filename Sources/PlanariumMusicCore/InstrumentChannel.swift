import Foundation

/// Opaque, serializable plug-in state. No AU object crosses the domain boundary.
public struct InstrumentPlugin: Codable, Equatable, Sendable {
    public var identity: SpatialAudioUnitIdentity
    public var state: Data

    public init(identity: SpatialAudioUnitIdentity, state: Data = Data()) {
        self.identity = identity
        self.state = state
    }
}

public struct InstrumentInsert: Codable, Equatable, Sendable {
    public var id: UUID
    public var plugin: InstrumentPlugin
    public var bypassed: Bool

    public init(id: UUID, plugin: InstrumentPlugin, bypassed: Bool = false) {
        self.id = id
        self.plugin = plugin
        self.bypassed = bypassed
    }
}

/// Stable endpoint identity, independent of a currently open MIDI port.
public struct InstrumentMIDITarget: Codable, Equatable, Sendable {
    public var uniqueID: Int32
    public init(uniqueID: Int32) { self.uniqueID = uniqueID }
}

public struct InstrumentChannel: Identifiable, Codable, Equatable, Sendable {
    /// Deterministic identity of the single strip in migrated documents.
    public static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let maximumLevelDecibels = 6.0
    public var id: UUID
    public var name: String
    public var color: SpatialLayerColor
    public var instrument: InstrumentPlugin?
    /// Array order is signal order.
    public var inserts: [InstrumentInsert]
    public var midiEffects: [InstrumentMIDIEffect] = []
    /// Reserved only; -120 dB is the stored −∞ sentinel. No signal routing.
    public var sendALevelDecibels: Double = -120
    public var sendBLevelDecibels: Double = -120
    public var levelDecibels: Double
    /// Legacy wire input only. Live routing uses InstrumentDocument.midiTarget.
    public var midiTarget: InstrumentMIDITarget?
    public var pan: Double
    public var muted: Bool
    public var soloed: Bool
    public var audibleLevelDecibels: Double { muted ? -120 : levelDecibels }

    public init(instrument: InstrumentPlugin? = nil, inserts: [InstrumentInsert] = [],
                levelDecibels: Double = 0, midiTarget: InstrumentMIDITarget? = nil,
                pan: Double = 0, muted: Bool = false, soloed: Bool = false,
                id: UUID = Self.legacyID, name: String = "Ch 1", color: SpatialLayerColor = .blue) {
        self.id = id; self.name = name; self.color = color
        self.instrument = instrument
        self.inserts = inserts
        self.levelDecibels = levelDecibels
        self.midiTarget = midiTarget
        self.pan = pan; self.muted = muted; self.soloed = soloed
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, instrument, inserts, midiEffects, sendALevelDecibels, sendBLevelDecibels, levelDecibels, midiTarget, pan, muted, soloed
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? Self.legacyID
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Ch 1"
        color = try values.decodeIfPresent(SpatialLayerColor.self, forKey: .color) ?? .blue
        instrument = try values.decodeIfPresent(InstrumentPlugin.self, forKey: .instrument)
        inserts = try values.decode([InstrumentInsert].self, forKey: .inserts)
        midiEffects = try values.decodeIfPresent([InstrumentMIDIEffect].self, forKey: .midiEffects) ?? []
        sendALevelDecibels = try values.decodeIfPresent(Double.self, forKey: .sendALevelDecibels) ?? -120
        sendBLevelDecibels = try values.decodeIfPresent(Double.self, forKey: .sendBLevelDecibels) ?? -120
        levelDecibels = try values.decode(Double.self, forKey: .levelDecibels)
        midiTarget = try values.decodeIfPresent(InstrumentMIDITarget.self, forKey: .midiTarget)
        pan = try values.decode(Double.self, forKey: .pan)
        muted = try values.decode(Bool.self, forKey: .muted)
        soloed = try values.decode(Bool.self, forKey: .soloed)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name); try values.encode(color, forKey: .color)
        try values.encodeIfPresent(instrument, forKey: .instrument); try values.encode(inserts, forKey: .inserts)
        if !midiEffects.isEmpty { try values.encode(midiEffects, forKey: .midiEffects) }
        if sendALevelDecibels != -120 { try values.encode(sendALevelDecibels, forKey: .sendALevelDecibels) }
        if sendBLevelDecibels != -120 { try values.encode(sendBLevelDecibels, forKey: .sendBLevelDecibels) }
        try values.encode(levelDecibels, forKey: .levelDecibels); try values.encode(pan, forKey: .pan)
        try values.encode(muted, forKey: .muted); try values.encode(soloed, forKey: .soloed)
    }
}


extension InstrumentChannel {
    /// Upper bound of independently owned strips in one instrument.
    public static let maximumCount = 8
}

/// Rejection of a channel set by a sound host. Documents are validated by their
/// compiler first; this is the host's own second barrier.
public enum ChannelSetError: Error, Equatable, Sendable {
    case tooManyChannels(Int)
    case duplicateChannelID
}
