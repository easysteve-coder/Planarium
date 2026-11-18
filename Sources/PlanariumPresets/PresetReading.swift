import Foundation
import PlanariumDomain


/// The sole public read result. A legacy preset is a patch of explicitly
/// present values; a v6 preset replaces the complete mixer document.
public struct PresetReading {
    private enum Content { case current(InstrumentPresetV6), legacy(LegacyPresetDocumentReading) }
    private let content: Content
    public let sourceVersion: Int
    public var loadNotice: String? {
        let spatial: SpatialDocument?
        switch content {
        case .current(let value): spatial = value.document.spatial
        case .legacy(let value): spatial = value.record.spatialDocument
        }
        guard let spatial, spatial.didMigrateScaleToggle || spatial.layers.contains(where: { layer in
            layer.routings.contains { $0.program != $0.program.replacingUnsupportedToggle }
        }) else { return nil }
        return "Scale / Random scale: Toggle changed to Retrigger."
    }
    public var summary: String {
        if case .current(let value) = content { return value.summary }; return ""
    }
    public var findings: [CompatibilityImportFinding] {
        if case .legacy(let value) = content { return value.findings }; return []
    }
    public var name: String {
        switch content { case .current(let value): return value.name; case .legacy(let value): return value.record.name }
    }
    public var viewport: PresetViewport? {
        if case .current(let value) = content { return value.viewport }; return nil
    }
    public var includesChannel: Bool {
        switch content {
        case .current(let value): return value.includesChannel
        case .legacy(let value): return (value.legacySettings ?? value.record.legacySettings).instrumentChannel != nil
        }
    }
    public var legacyViewport: ScanPlaneViewport? {
        if case .legacy(let value) = content {
            let settings = value.legacySettings ?? value.record.legacySettings
            return try? ScanPlaneViewport.build(centerX: settings.viewport.centerX, centerY: settings.viewport.centerY, halfExtent: settings.viewport.halfExtent)
        }
        return nil
    }
    init(_ value: InstrumentPresetV6, version: Int = 6) { content = .current(value); sourceVersion = version }
    init(_ value: LegacyPresetDocumentReading, version: Int) { content = .legacy(value); sourceVersion = version }

    /// Pure, all-or-nothing calculation, before the Main document owner commits.
    /// E2: no channel record means every live channel field stays intact.
    public func replacing(_ live: InstrumentDocument) throws -> InstrumentDocument {
        var next: InstrumentDocument
        switch content {
        case .current(let value):
            next = value.document
            if !value.includesChannel {
                next.channels = live.channels
                next.masterLevelDecibels = live.masterLevelDecibels
                next.midiTarget = live.midiTarget
            }
        case .legacy(let reading):
            let settings = reading.legacySettings ?? reading.record.legacySettings
            _ = try ScanPlaneViewport.build(centerX: settings.viewport.centerX, centerY: settings.viewport.centerY, halfExtent: settings.viewport.halfExtent)
            // Retired zone/synth/effect fields are parser values, never a live
            // validator. Only explicitly present channel values are applied.
            next = live
            next.beatsPerMinute = 120
            if let spatial = reading.record.spatialDocument { next.spatial = spatial }
            if let detection = reading.detection { next.detection = detection }
            if let workspace = reading.legacyWorkspace {
                next.editorGrid = workspace.grid; next.channelName = workspace.channelName
                next.channelColor = workspace.channelColor
            }
            if let channel = settings.instrumentChannel {
                guard settings.masterGain.isFinite, (0...1).contains(settings.masterGain) else {
                    throw PresetDocumentReadError.decodingFailed("invalidLegacyGain")
                }
                next.channel.pan = Double(channel.pan)
                next.channel.levelDecibels = max(-120, 20 * log10(max(0.000001, Double(settings.masterGain))))
            }
            // Legacy formats carry no controller assignments; the preset replaces the instrument.
            next.controller = .empty
            next = try LegacyChannelMigration.applying(to: next)
            if !includesChannel { next.channels = live.channels; next.masterLevelDecibels = live.masterLevelDecibels }
        }
        next.spatial = try next.spatial.normalizingUnsupportedToggles()
        next.detection.roomContour = live.detection.roomContour
        _ = try InstrumentCompiler.compile(next)
        return next
    }
}

public enum PresetDocumentReader {
    public static func read(_ data: Data) -> Result<PresetReading, PresetDocumentReadError> {
        guard data.count <= SpatialDocumentBudget.production.inputBytes else { return .failure(.budgetExceeded(.inputBytes)) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.notAJSONObject) }
        guard let raw = root["formatVersion"] else { return .failure(.missingFormatVersion) }
        guard let version = PresetDocumentCodec.exactJSONInteger(raw) else { return .failure(.malformedFormatVersion) }
        guard version >= 1 else { return .failure(.unsupportedVersion(version)) }
        guard version <= 7 else { return .failure(.newerThanSupported(version)) }
        do {
            if version == 7 { return .success(PresetReading(try PresetV7Codec.decode(data), version: 7)) }
            if version == 6 { return .success(PresetReading(try PresetV6Codec.decode(data))) }
            if version == 5 {
                let old = try PresetV5Codec.decode(data)
                let document = try LegacyChannelMigration.applying(to: old.document)
                return .success(PresetReading(.init(name: old.name, document: document, viewport: old.viewport,
                    includesChannel: old.includesChannel, summary: old.summary), version: 5))
            }
            return LegacyPresetDocumentReader.read(data).map { PresetReading($0, version: version) }
        } catch let error as PresetDocumentReadError { return .failure(error) }
        catch let error as SpatialDocumentError {
            switch error {
            case .budgetExceeded(let kind): return .failure(.budgetExceeded(kind))
            case .surfaceRasterVersionUnsupported(let version): return .failure(.surfaceRasterVersionUnsupported(version))
            case .surfaceDerivationMismatch(let id): return .failure(.surfaceDerivationMismatch(surfaceID: id))
            case .surfaceSettingsMismatch, .invalidSurfaceSettings: return .failure(.inconsistentSurfaceSettings)
            default: return .failure(.spatialDocument(error))
            }
        } catch { return .failure(.decodingFailed("invalidDocument")) }
    }
}
