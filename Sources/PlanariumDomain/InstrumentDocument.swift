import Foundation
import PlanariumControllerCore
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

/// Ordered, independently owned strips. SpatialDocument supplies the existing
/// validated polar layers/routings/programs; it contains no detection copy.
/// Room evidence belongs to the session, never to this document.
public struct InstrumentDocument: Codable, Equatable, Sendable {
    public var spatial: SpatialDocument
    public var detection: DetectionConfiguration
    public static let maximumChannels = InstrumentChannel.maximumCount
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
    /// Game controller assignments of this instrument; written only when not empty.
    public var controller: ControllerLayout = .empty

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
        case spatial, detection, channel, channels, masterLevelDecibels, midiTarget, revision, roomFilter, editorGrid, channelName, channelColor, scenes, currentSceneID, beatsPerMinute, controller
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
        controller = try values.decodeIfPresent(ControllerLayout.self, forKey: .controller) ?? .empty
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
        if controller != .empty { try values.encode(controller, forKey: .controller) }
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
