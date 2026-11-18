import Foundation
import PlanariumDomain

/// Independent format: never changes the complete instrument preset wire format.
public struct ChannelPreset: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var formatVersion = currentVersion
    public var name: String
    public var channel: InstrumentChannel
    public var includesLevelAndPan: Bool
    public init(name: String, channel: InstrumentChannel, includesLevelAndPan: Bool = true) {
        self.name = name; self.channel = channel; self.includesLevelAndPan = includesLevelAndPan
    }
    public func replacing(_ destination: InstrumentChannel) -> InstrumentChannel {
        var result = channel
        result.id = destination.id; result.name = destination.name; result.color = destination.color
        result.muted = destination.muted; result.soloed = destination.soloed
        result.midiTarget = destination.midiTarget
        if !includesLevelAndPan { result.levelDecibels = destination.levelDecibels; result.pan = destination.pan }
        return result
    }
}

public enum ChannelPresetCodec {
    public enum Failure: Error { case version, budget, invalid }
    public static func encode(_ value: ChannelPreset) throws -> Data {
        try validate(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= SpatialDocumentBudget.production.inputBytes else { throw Failure.budget }
        return data
    }
    public static func decode(_ data: Data) throws -> ChannelPreset {
        guard data.count <= SpatialDocumentBudget.production.inputBytes else { throw Failure.budget }
        let value = try JSONDecoder().decode(ChannelPreset.self, from: data)
        try validate(value); return value
    }
    private static func validate(_ value: ChannelPreset) throws {
        guard value.formatVersion == ChannelPreset.currentVersion else { throw Failure.version }
        guard PresetFileStore.isValidName(value.name) else { throw Failure.invalid }
        let id = UUID()
        let layer = SpatialDocumentLayer(id: id, name: "Validation", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
        let document = InstrumentDocument(spatial: spatial, revision: .newSession(), channels: [value.channel])
        _ = try InstrumentCompiler.compile(document)
    }
}
