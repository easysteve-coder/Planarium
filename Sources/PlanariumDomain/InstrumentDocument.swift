import Foundation
import PLSDeviceValues

/// Document-owner permissions shared by authoring and preset entry points.
public enum InstrumentAction: CaseIterable, Sendable {
    case edit, tempo, mixer, scene, loadPreset, captureRoom, fitRoom, presentation, release

    public var allowedInPerformance: Bool {
        switch self {
        case .mixer, .scene, .loadPreset, .captureRoom, .fitRoom: return true
        // Navigation, measured publication and output release do not author
        // the instrument. They remain available while authoring is locked.
        case .presentation, .release: return true
        case .edit: return false
        case .tempo: return true
        }
    }
    public static let performanceLockReason = "Locked in Perform mode · ⌘⇧P to edit"
}

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

/// Ordered, independently owned strips. SpatialDocument supplies the existing
/// validated polar layers/routings/programs; it contains no detection copy.
/// Room evidence belongs to the session, never to this document.
public struct InstrumentDocument: Codable, Equatable, Sendable {
    public var spatial: SpatialDocument
    public var detection: DetectionConfiguration
    public static let maximumChannels = 8
    public var channels: [InstrumentChannel]
    public var masterLevelDecibels: Double
    public var midiTarget: InstrumentMIDITarget?
    /// Compatibility projection for single-strip authoring callers.
    public var channel: InstrumentChannel {
        get { channels.first ?? .init() }
        set { if !channels.isEmpty { channels[0] = newValue } }
    }
    public var editorGrid: MetricSquareGrid
    public var channelName: String {
        get { channel.name }
        set { channel.name = newValue }
    }
    public var channelColor: SpatialLayerColor {
        get { channel.color }
        set { channel.color = newValue }
    }
    /// Scene authoring state is persisted with the preset.  A missing value is
    /// intentionally an old preset, not an implicit scene.
    public var scenes: [SpatialScene]
    public var currentSceneID: UUID?
    public var revision: SpatialDocumentRevision
    public var beatsPerMinute: Double = 120

    public init(spatial: SpatialDocument, detection: DetectionConfiguration = .ownerDefaults,
                channel: InstrumentChannel = .init(), revision: SpatialDocumentRevision,
                editorGrid: MetricSquareGrid = MetricSquareGrid.CellSize.fiveCentimeter.grid, channelName: String? = nil, channelColor: SpatialLayerColor? = nil,
                scenes: [SpatialScene] = [], currentSceneID: UUID? = nil,
                channels: [InstrumentChannel]? = nil, masterLevelDecibels: Double = 0,
                midiTarget: InstrumentMIDITarget? = nil) {
        self.spatial = spatial
        self.detection = detection
        var first = channel
        if let channelName { first.name = channelName }
        if let channelColor { first.color = channelColor }
        self.channels = channels ?? [first]
        self.masterLevelDecibels = masterLevelDecibels
        self.midiTarget = midiTarget ?? self.channels.first?.midiTarget
        for index in self.channels.indices { self.channels[index].midiTarget = nil }
        self.revision = revision
        self.editorGrid = editorGrid
        self.scenes = scenes
        self.currentSceneID = scenes.contains(where: { $0.id == currentSceneID }) ? currentSceneID : nil
    }
    // Session contour settings and evidence are never persisted. Old roomFilter
    // values remain readable and are deliberately ignored.
    private enum CodingKeys: String, CodingKey {
        case spatial, detection, channel, channels, masterLevelDecibels, midiTarget, revision, roomFilter, editorGrid, channelName, channelColor, scenes, currentSceneID, beatsPerMinute
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        spatial = try values.decode(SpatialDocument.self, forKey: .spatial)
        detection = try values.decode(DetectionConfiguration.self, forKey: .detection)
        _ = try values.decodeIfPresent(SpatialRoomContourConfiguration.self, forKey: .roomFilter)
        if values.contains(.channels) {
            channels = try values.decode([InstrumentChannel].self, forKey: .channels)
        } else {
            var first = try values.decode(InstrumentChannel.self, forKey: .channel)
            first.name = "Ch 1"
            first.color = try values.decodeIfPresent(SpatialLayerColor.self, forKey: .channelColor) ?? .blue
            channels = [first]
        }
        masterLevelDecibels = try values.decodeIfPresent(Double.self, forKey: .masterLevelDecibels) ?? 0
        midiTarget = try values.decodeIfPresent(InstrumentMIDITarget.self, forKey: .midiTarget) ?? channels.first?.midiTarget
        for index in channels.indices { channels[index].midiTarget = nil }
        editorGrid = try values.decodeIfPresent(MetricSquareGrid.self, forKey: .editorGrid) ?? .quarterMeter
        do { try LegacyLatticeMigration.validateEditorGrid(editorGrid) }
        catch {
            throw DecodingError.dataCorruptedError(forKey: .editorGrid, in: values,
                debugDescription: "Editor grid must be a representable integer number of centimeters.")
        }
        scenes = try values.decodeIfPresent([SpatialScene].self, forKey: .scenes) ?? []
        let decodedScene = try values.decodeIfPresent(UUID.self, forKey: .currentSceneID)
        currentSceneID = scenes.contains(where: { $0.id == decodedScene }) ? decodedScene : nil
        revision = try values.decode(SpatialDocumentRevision.self, forKey: .revision)
        beatsPerMinute = try values.decodeIfPresent(Double.self, forKey: .beatsPerMinute) ?? 120
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(spatial, forKey: .spatial)
        try values.encode(detection, forKey: .detection)
        try values.encode(channels, forKey: .channels)
        try values.encode(masterLevelDecibels, forKey: .masterLevelDecibels)
        try values.encodeIfPresent(midiTarget, forKey: .midiTarget)
        try values.encode(revision, forKey: .revision)
        try values.encode(editorGrid, forKey: .editorGrid)
        if !scenes.isEmpty { try values.encode(scenes, forKey: .scenes) }
        try values.encodeIfPresent(currentSceneID, forKey: .currentSceneID)
        if beatsPerMinute != 120 { try values.encode(beatsPerMinute, forKey: .beatsPerMinute) }
    }

}

public enum InstrumentCompiler {
    /// All inputs that affect index, actions, routing or output resource identity.
    /// Presentation metadata and scalar mixer/tempo values are excluded.
    public static func canReuseIndex(from document: InstrumentDocument, for value: InstrumentDocument) -> Bool {
        guard value.detection == document.detection, value.editorGrid == document.editorGrid,
              value.midiTarget == document.midiTarget, value.scenes.count == document.scenes.count,
              zip(value.scenes, document.scenes).allSatisfy({ next, old in
                  var normalized = next; normalized.name = old.name
                  return normalized == old
              }),
              value.currentSceneID == document.currentSceneID,
              value.spatial.latticeVersion == document.spatial.latticeVersion,
              value.spatial.surfaceSettings == document.spatial.surfaceSettings,
              value.spatial.layers.count == document.spatial.layers.count,
              value.channels.count == document.channels.count else { return false }
        for (next, old) in zip(value.channels, document.channels) {
            var normalized = next
            normalized.name = old.name; normalized.color = old.color
            normalized.levelDecibels = old.levelDecibels; normalized.pan = old.pan
            normalized.muted = old.muted; normalized.soloed = old.soloed
            guard normalized == old else { return false }
        }
        return zip(value.spatial.layers, document.spatial.layers).allSatisfy { next, old in
            next.hasSameIndexInputs(as: old)
        }
    }
    /// Restamp a compatible index; mismatched musical inputs never enter this path.
    public static func reusingIndex(_ compiled: CompiledInstrument, from previous: InstrumentDocument,
                                   for document: InstrumentDocument) throws -> CompiledInstrument {
        guard compiled.revision.session == previous.revision.session,
              canReuseIndex(from: previous, for: document) else { throw CompiledInstrumentError.incompatibleReusableIndex }
        try validateSettings(document)
        return compiled.withDocumentSettings(detection: document.detection, channel: document.channel,
            channels: document.channels, masterLevelDecibels: document.masterLevelDecibels,
            midiTarget: document.midiTarget, scenes: runtimeScenes(of: document), currentSceneID: document.currentSceneID,
            revision: document.revision,
            activeLayerIDs: document.spatial.activeRuntimeIDs)
    }
    /// Cheap scalar/identity checks shared by edits that retain the musical index.
    public static func validateSettings(_ document: InstrumentDocument) throws {
        guard Tempo.isValid(document.beatsPerMinute) else { throw CompiledInstrumentError.invalidTempo }
        try LegacyLatticeMigration.validateEditorGrid(document.editorGrid)
        switch document.detection.temporalSmoothing {
        case .off: break
        case .mean(let window), .median(let window):
            guard window > 0 else { throw CompiledInstrumentError.invalidDetectionConfiguration }
        case .exponential(let alpha):
            guard alpha.isFinite, (0...1).contains(alpha) else {
                throw CompiledInstrumentError.invalidDetectionConfiguration
            }
        }
        guard (1...4).contains(document.detection.cellSelection.confirmationProfiles),
              document.detection.cellSelection.boundaryMarginCentimeters <= 10,
              (1...10).contains(document.detection.groupingMinimumPoints),
              document.detection.edgePoints <= 2, document.detection.coreWidthCentimeters <= 10,
              (0...90).contains(document.detection.minimumAngleDegrees) else {
            throw CompiledInstrumentError.invalidDetectionConfiguration
        }
        guard document.channels.count <= InstrumentDocument.maximumChannels else {
            throw CompiledInstrumentError.tooManyChannels(document.channels.count)
        }
        guard Set(document.channels.map(\.id)).count == document.channels.count else {
            throw CompiledInstrumentError.duplicateChannelID
        }
        guard document.channels.allSatisfy({ channel in
            channel.midiEffects.count <= 4
                && channel.midiEffects.filter { $0.kind == .arpeggiator }.count <= 1
                && Set(channel.midiEffects.map(\.id)).count == channel.midiEffects.count
                && channel.midiEffects.allSatisfy { $0.chord.isValid && $0.arpeggiator.isValid }
        }) else {
            throw CompiledInstrumentError.invalidMIDIEffects
        }
        guard document.masterLevelDecibels.isFinite, document.masterLevelDecibels <= InstrumentChannel.maximumLevelDecibels,
              document.channels.allSatisfy({ $0.sendALevelDecibels.isFinite && (-120...6).contains($0.sendALevelDecibels) && $0.sendBLevelDecibels.isFinite && (-120...6).contains($0.sendBLevelDecibels) && $0.levelDecibels.isFinite && $0.levelDecibels <= InstrumentChannel.maximumLevelDecibels && $0.pan.isFinite && (-1...1).contains($0.pan) }) else {
            throw CompiledInstrumentError.invalidChannelLevel
        }
    }
    public static func compile(_ document: InstrumentDocument) throws -> CompiledInstrument {
        try validateSettings(document)
        let sceneLayerIDs = Set(document.scenes.flatMap(\.activeLayerIDs))
        return try SpatialInstrumentCompiler.compile(document.spatial, revision: document.revision,
                                                     requiredLayerIDs: sceneLayerIDs,
                                                     snapGrid: document.editorGrid)
            .withDocumentSettings(detection: document.detection, channel: document.channel,
                                  channels: document.channels, masterLevelDecibels: document.masterLevelDecibels,
                                  midiTarget: document.midiTarget,
                                  scenes: runtimeScenes(of: document), currentSceneID: document.currentSceneID)
    }
    /// Scenes name layers; the runtime plays partitions. The compiled scenes list the partitions of
    /// each named layer (a layer without surfaces is its own partition), the document's scenes stay as authored.
    static func runtimeScenes(of document: InstrumentDocument) -> [SpatialScene] {
        guard document.spatial.layers.contains(where: \.isSurfaceBacked) else { return document.scenes }
        return document.scenes.map { scene in
            var scene = scene
            scene.activeLayerIDs = document.spatial.runtimeIDs(forLayerIDs: scene.activeLayerIDs)
            return scene
        }
    }
}
