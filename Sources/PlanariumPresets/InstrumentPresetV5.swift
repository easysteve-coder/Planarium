import Foundation
import PlanariumDomain

import SickPLSControlCore

/// Complete document, optionally without a channel for cell/harmony templates.
/// An omitted document.channel preserves the live channel; a present empty
/// channel explicitly clears it. JSON null is malformed, never absence.
/// No room evidence, host configuration, file location or endpoint label.
public struct InstrumentPresetV5: Codable, Equatable, Sendable {
    public static let formatVersion = 5
    public var name: String
    /// User-facing prose, outside the musical document; empty omits the wire key.
    public var summary: String
    public static let maximumSummaryCharacters = 1000
    public var document: InstrumentDocument
    public let includesChannel: Bool
    public var viewport: PresetViewport?

    public init(name: String, document: InstrumentDocument, viewport: PresetViewport? = nil, includesChannel: Bool = true, summary: String = "") {
        self.summary = summary
        self.name = name; self.document = document; self.viewport = viewport; self.includesChannel = includesChannel
        if !includesChannel {
            self.document.channel = .init()
            self.document.channelName = "PLANARIUM"; self.document.channelColor = .blue
        }
    }
    private enum CodingKeys: String, CodingKey { case formatVersion, name, document, viewport, summary }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .formatVersion)
        guard version == Self.formatVersion else { throw PresetDocumentReadError.unsupportedVersion(version) }
        name = try values.decode(String.self, forKey: .name)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        let wire = try values.decode(PresetDocumentValue.self, forKey: .document)
        document = try LegacyChannelMigration.decodingLegacyTargets(in: wire.document); includesChannel = wire.includesChannel
        viewport = try values.decodeIfPresent(PresetViewport.self, forKey: .viewport)
        try validateSummary()
    }
    public func encode(to encoder: Encoder) throws {
        try validateSummary()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.formatVersion, forKey: .formatVersion)
        try values.encode(name, forKey: .name)
        if !summary.isEmpty { try values.encode(summary, forKey: .summary) }
        try values.encode(PresetDocumentValue(document: document, includesChannel: includesChannel), forKey: .document)
        try values.encodeIfPresent(viewport, forKey: .viewport)
    }

    private func validateSummary() throws {
        guard summary.count <= Self.maximumSummaryCharacters else {
            throw PresetDocumentReadError.summaryTooLong
        }
    }
}

/// The optional wire field belongs to presets, not to the live document,
/// which always owns a complete channel. Both expanded and compact v5
/// spatial records decode to the same complete document.
private struct PresetDocumentValue: Codable {
    let document: InstrumentDocument
    let includesChannel: Bool
    init(document: InstrumentDocument, includesChannel: Bool) {
        self.document = document; self.includesChannel = includesChannel
    }
    private enum CodingKeys: String, CodingKey {
        case spatial, detection, channel, revision, roomFilter, editorGrid, channelName, channelColor, scenes, currentSceneID
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        includesChannel = values.contains(.channel)
        let detection = try values.decode(DetectionConfiguration.self, forKey: .detection)
        _ = try values.decodeIfPresent(SpatialRoomContourConfiguration.self, forKey: .roomFilter)
        document = .init(spatial: try values.decode(SpatialDocument.self, forKey: .spatial), detection: detection,
            channel: includesChannel ? try values.decode(InstrumentChannel.self, forKey: .channel) : .init(),
            revision: try values.decode(SpatialDocumentRevision.self, forKey: .revision),
            editorGrid: try values.decodeIfPresent(MetricSquareGrid.self, forKey: .editorGrid) ?? .quarterMeter,
            channelName: try values.decodeIfPresent(String.self, forKey: .channelName) ?? "PLANARIUM",
            channelColor: try values.decodeIfPresent(SpatialLayerColor.self, forKey: .channelColor) ?? .blue,
            scenes: try values.decodeIfPresent([SpatialScene].self, forKey: .scenes) ?? [],
            currentSceneID: try values.decodeIfPresent(UUID.self, forKey: .currentSceneID))
        try LegacyLatticeMigration.validateEditorGrid(document.editorGrid)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if includesChannel {
            var legacy = document.channel; legacy.midiTarget = document.midiTarget
            try values.encode(LegacyChannelValue(channel: legacy), forKey: .channel)
            try values.encode(document.channelName, forKey: .channelName)
            try values.encode(document.channelColor, forKey: .channelColor)
        }
        try values.encode(document.spatial, forKey: .spatial)
        try values.encode(document.detection, forKey: .detection)
        try values.encode(document.revision, forKey: .revision)
        try values.encode(document.editorGrid, forKey: .editorGrid)
        if !document.scenes.isEmpty { try values.encode(document.scenes, forKey: .scenes) }
        try values.encodeIfPresent(document.currentSceneID, forKey: .currentSceneID)
    }
}

private struct LegacyChannelValue: Encodable {
    let channel: InstrumentChannel
    private enum CodingKeys: String, CodingKey { case instrument, inserts, levelDecibels, midiTarget, pan, muted, soloed }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(channel.instrument, forKey: .instrument)
        try values.encode(channel.inserts, forKey: .inserts)
        try values.encode(channel.levelDecibels, forKey: .levelDecibels)
        try values.encodeIfPresent(channel.midiTarget, forKey: .midiTarget)
        try values.encode(channel.pan, forKey: .pan)
        try values.encode(channel.muted, forKey: .muted)
        try values.encode(channel.soloed, forKey: .soloed)
    }
}

/// Exact view values, independent of a window size or old normalized extent.
public struct PresetViewport: Codable, Equatable, Sendable {
    public let centerXMeters: Double
    public let centerYMeters: Double
    public let metersPerPoint: Double
    public init(_ viewport: MetricCanvasViewport) {
        centerXMeters = viewport.centerXMeters; centerYMeters = viewport.centerYMeters
        metersPerPoint = viewport.metersPerPoint
    }
    public func validated() throws -> MetricCanvasViewport {
        try .build(centerXMeters: centerXMeters, centerYMeters: centerYMeters, metersPerPoint: metersPerPoint)
    }
}

public enum PresetV5Codec {
    public static func encode(_ preset: InstrumentPresetV5) throws -> Data {
        try validate(preset)
        let encoder = JSONEncoder()
        encoder.userInfo[SpatialRoutingTarget.legacyWireKey] = true
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(preset)
        guard data.count <= SpatialDocumentBudget.production.inputBytes else {
            throw PresetDocumentReadError.budgetExceeded(.inputBytes)
        }
        return data
    }
    static func decode(_ data: Data) throws -> InstrumentPresetV5 {
        let decoder = JSONDecoder()
        let preset = try decoder.decode(InstrumentPresetV5.self, from: data)
        try validate(preset)
        return preset
    }
    private static func validate(_ preset: InstrumentPresetV5) throws {
        _ = try InstrumentCompiler.compile(preset.document)
        if let viewport = preset.viewport { _ = try viewport.validated() }
        let inserts = preset.document.channel.inserts
        guard Set(inserts.map(\.id)).count == inserts.count else {
            throw PresetDocumentReadError.decodingFailed("duplicateInsertID")
        }
    }
}
