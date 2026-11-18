import Foundation
import PlanariumDomain

extension CodingUserInfoKey {
    /// Format version the preset container writes and expects. Absent: version 6.
    static let presetWireVersion = CodingUserInfoKey(rawValue: "PlanariumPresets.wireVersion")!
}

/// A document that cannot be written in the chosen format without losing something.
public enum PresetDocumentWriteError: Error, Equatable {
    /// The document holds editable surfaces or surface settings that only format version 7 carries.
    case requiresNewerFormat
}

/// Complete mixer snapshot, or a spatial template that preserves the live mixer.
/// The container is shared by format versions 6 and 7: 7 differs only in the version number and in
/// the surface data its spatial document may carry.
public struct InstrumentPresetV6: Codable, Equatable, Sendable {
    public static let formatVersion = 6
    public static let maximumSummaryCharacters = 1000
    public var name: String
    public var summary: String
    public var document: InstrumentDocument
    public let includesChannel: Bool
    public var viewport: PresetViewport?

    public init(name: String, document: InstrumentDocument, viewport: PresetViewport? = nil,
                includesChannel: Bool = true, summary: String = "") {
        self.name = name; self.document = document; self.viewport = viewport
        self.includesChannel = includesChannel; self.summary = summary
        if !includesChannel { self.document.channels = [.init()]; self.document.masterLevelDecibels = 0 }
    }
    private enum CodingKeys: String, CodingKey { case formatVersion, name, summary, document, viewport }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .formatVersion)
        let expected = decoder.userInfo[.presetWireVersion] as? Int ?? Self.formatVersion
        guard version == expected else { throw PresetDocumentReadError.unsupportedVersion(version) }
        name = try values.decode(String.self, forKey: .name)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        guard summary.count <= Self.maximumSummaryCharacters else { throw PresetDocumentReadError.summaryTooLong }
        viewport = try values.decodeIfPresent(PresetViewport.self, forKey: .viewport)
        let wire = try values.decode(MixerPresetDocument.self, forKey: .document)
        document = wire.document; includesChannel = wire.includesChannel
    }
    public func encode(to encoder: Encoder) throws {
        guard summary.count <= Self.maximumSummaryCharacters else { throw PresetDocumentReadError.summaryTooLong }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(encoder.userInfo[.presetWireVersion] as? Int ?? Self.formatVersion, forKey: .formatVersion)
        try values.encode(name, forKey: .name)
        if !summary.isEmpty { try values.encode(summary, forKey: .summary) }
        try values.encodeIfPresent(viewport, forKey: .viewport)
        try values.encode(MixerPresetDocument(document: document, includesChannel: includesChannel), forKey: .document)
    }
}

private struct MixerPresetDocument: Codable {
    var document: InstrumentDocument
    let includesChannel: Bool
    init(document: InstrumentDocument, includesChannel: Bool) {
        self.document = document; self.includesChannel = includesChannel
    }
    private enum CodingKeys: String, CodingKey {
        case spatial, detection, roomFilter, revision, editorGrid, channels, masterLevelDecibels, midiTarget, scenes, currentSceneID, beatsPerMinute, controller
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        includesChannel = values.contains(.channels)
        let detection = try values.decode(DetectionConfiguration.self, forKey: .detection)
        _ = try values.decodeIfPresent(SpatialRoomContourConfiguration.self, forKey: .roomFilter)
        document = .init(spatial: try values.decode(SpatialDocument.self, forKey: .spatial), detection: detection,
            revision: try values.decode(SpatialDocumentRevision.self, forKey: .revision),
            editorGrid: try values.decode(MetricSquareGrid.self, forKey: .editorGrid),
            scenes: try values.decodeIfPresent([SpatialScene].self, forKey: .scenes) ?? [],
            currentSceneID: try values.decodeIfPresent(UUID.self, forKey: .currentSceneID),
            channels: includesChannel ? try values.decode([V6Channel].self, forKey: .channels).map(\.value) : [.init()],
            masterLevelDecibels: includesChannel ? try values.decode(Double.self, forKey: .masterLevelDecibels) : 0,
            midiTarget: try values.decodeIfPresent(InstrumentMIDITarget.self, forKey: .midiTarget))
        try LegacyLatticeMigration.validateEditorGrid(document.editorGrid)
        document.beatsPerMinute = try values.decodeIfPresent(Double.self, forKey: .beatsPerMinute) ?? 120
        // Game controller assignments travel with full presets and templates; old presets have none.
        document.controller = try values.decodeIfPresent(ControllerLayout.self, forKey: .controller) ?? .empty
    }
    func encode(to encoder: Encoder) throws {
        if includesChannel { try document.encode(to: encoder); return }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(document.spatial, forKey: .spatial)
        try values.encode(document.detection, forKey: .detection)
        try values.encode(document.revision, forKey: .revision)
        try values.encode(document.editorGrid, forKey: .editorGrid)
        if !document.scenes.isEmpty { try values.encode(document.scenes, forKey: .scenes) }
        try values.encodeIfPresent(document.currentSceneID, forKey: .currentSceneID)
        if document.beatsPerMinute != 120 { try values.encode(document.beatsPerMinute, forKey: .beatsPerMinute) }
        if document.controller != .empty { try values.encode(document.controller, forKey: .controller) }
    }
}

private struct V6Channel: Decodable {
    let value: InstrumentChannel
    private enum CodingKeys: String, CodingKey { case id, name, color }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        _ = try keys.decode(UUID.self, forKey: .id)
        _ = try keys.decode(String.self, forKey: .name)
        _ = try keys.decode(SpatialLayerColor.self, forKey: .color)
        value = try InstrumentChannel(from: decoder)
    }
}

public enum PresetV6Codec {
    public static func encode(_ preset: InstrumentPresetV6) throws -> Data {
        // Never drop surface data silently: a version 6 file cannot carry it.
        guard !preset.document.spatial.requiresSurfaceFormat else { throw PresetDocumentWriteError.requiresNewerFormat }
        try validate(preset)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(preset)
        guard data.count <= SpatialDocumentBudget.production.inputBytes else { throw PresetDocumentReadError.budgetExceeded(.inputBytes) }
        return data
    }
    static func decode(_ data: Data) throws -> InstrumentPresetV6 {
        let preset = try JSONDecoder().decode(InstrumentPresetV6.self, from: data)
        guard preset.document.channels.count <= InstrumentDocument.maximumChannels else { throw PresetDocumentReadError.tooManyChannels(preset.document.channels.count) }
        try validate(preset); return preset
    }
    static func validate(_ preset: InstrumentPresetV6) throws {
        guard preset.summary.count <= InstrumentPresetV6.maximumSummaryCharacters else { throw PresetDocumentReadError.summaryTooLong }
        _ = try InstrumentCompiler.compile(preset.document)
        try preset.document.validateController()
        if let viewport = preset.viewport { _ = try viewport.validated() }
        for strip in preset.document.channels {
            guard strip.id != LegacyChannelMigration.missingID else { throw PresetDocumentReadError.decodingFailed("reservedChannelID") }
            guard Set(strip.inserts.map(\.id)).count == strip.inserts.count else {
                throw PresetDocumentReadError.decodingFailed("duplicateInsertID")
            }
        }
    }
}

public enum LegacyChannelMigration {
    public static let missingID = SpatialRoutingTarget.missingStripID
    public static func applying(to source: InstrumentDocument) throws -> InstrumentDocument {
        var document = try decodingLegacyTargets(in: source)
        var channel = source.channel; channel.id = InstrumentChannel.legacyID; channel.name = "Ch 1"
        document.channels = [channel]; document.masterLevelDecibels = 0
        return document
    }
    /// Only legacy readers call this boundary; V6 never remaps an AU target.
    static func decodingLegacyTargets(in source: InstrumentDocument) throws -> InstrumentDocument {
        var document = source
        let layers = try source.spatial.layers.map { layer -> SpatialDocumentLayer in
            // Only the legacy readers (version 5 and older) come here; those formats carry no surfaces.
            guard !layer.isSurfaceBacked else { throw SpatialDocumentError.surfacesRequireNewerFormat }
            let routings = layer.routings.map { routing in
                var routing = routing; routing.target = routing.target.withStripID(InstrumentChannel.legacyID); return routing
            }
            let overrides = layer.cellOverrides.mapValues { actions in
                actions.map { action in var action = action; action.target = action.target.withStripID(InstrumentChannel.legacyID); return action }
            }
            return SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color,
                isVisible: layer.isVisible, isActive: layer.isActive, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
                cells: layer.cells, routings: routings, cellOverrides: overrides, toggleGuardSeconds: layer.toggleGuardSeconds, commonNotes: layer.commonNotes, midiTarget: layer.midiTarget)
        }
        document.spatial = try source.spatial.replacingLayers(layers)
        document.spatial = try document.spatial.normalizingUnsupportedToggles(preservingLoadNotice: source.spatial.didMigrateScaleToggle)
        return document
    }
}

/// Format version 7: the version 6 container plus editable surfaces and surface settings in the
/// spatial document. Written only when the document needs it (see `PresetDocumentWriter`).
public enum PresetV7Codec {
    public static let formatVersion = 7
    public static func encode(_ preset: InstrumentPresetV6) throws -> Data {
        try PresetV6Codec.validate(preset)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[.presetWireVersion] = formatVersion
        encoder.userInfo[.spatialSurfacesAllowed] = true
        let data = try encoder.encode(preset)
        guard data.count <= SpatialDocumentBudget.production.inputBytes else { throw PresetDocumentReadError.budgetExceeded(.inputBytes) }
        return data
    }
    static func decode(_ data: Data) throws -> InstrumentPresetV6 {
        let decoder = JSONDecoder()
        decoder.userInfo[.presetWireVersion] = formatVersion
        decoder.userInfo[.spatialSurfacesAllowed] = true
        let preset = try decoder.decode(InstrumentPresetV6.self, from: data)
        guard preset.document.channels.count <= InstrumentDocument.maximumChannels else { throw PresetDocumentReadError.tooManyChannels(preset.document.channels.count) }
        try PresetV6Codec.validate(preset)
        return preset
    }
}

/// The one entry for writing a preset file. It chooses the lowest format version that can carry the
/// document: version 6 bytes exactly as before for every document without surfaces, version 7 when
/// a layer holds editable surfaces or the surface settings differ from the default.
public enum PresetDocumentWriter {
    public static func encode(_ preset: InstrumentPresetV6) throws -> Data {
        preset.document.spatial.requiresSurfaceFormat ? try PresetV7Codec.encode(preset) : try PresetV6Codec.encode(preset)
    }
}
