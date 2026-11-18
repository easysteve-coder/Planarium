import Foundation
import PlanariumDomain

struct LegacyPresetDocumentReading: Equatable {
    public enum Source: Equatable {
        case current
        case imported(fromVersion: Int)
    }

    public let record: InstrumentPresetV4
    public let source: Source
    public let findings: [CompatibilityImportFinding]
    public let legacySettings: InstrumentPreset?
    public let legacyWorkspace: SpatialInstrumentWorkspace?
    public let detection: DetectionConfiguration?

    public init(record: InstrumentPresetV4, source: Source,
                findings: [CompatibilityImportFinding], legacySettings: InstrumentPreset? = nil, legacyWorkspace: SpatialInstrumentWorkspace? = nil, detection: DetectionConfiguration? = nil) {
        self.record = record
        self.source = source
        self.findings = findings
        self.legacySettings = legacySettings; self.legacyWorkspace = legacyWorkspace; self.detection = detection
    }
}

/// Internal v1–v4 branch of PresetDocumentReader. Legacy settings normalize
/// to v3 before compatibility and spatial import. The decoded workspace
/// supplies presentation/detection values, never the live fine masks.
enum LegacyPresetDocumentReader {
    internal static let legacyNormalizationTarget = 3

    public static func read(_ data: Data) -> Result<LegacyPresetDocumentReading, PresetDocumentReadError> {
        read(data, inputByteLimit: SpatialDocumentBudget.production.inputBytes,
             migrations: .production)
    }

    internal static func read(
        _ data: Data,
        inputByteLimit: Int
    ) -> Result<LegacyPresetDocumentReading, PresetDocumentReadError> {
        read(data, inputByteLimit: inputByteLimit, migrations: .production)
    }

    internal static func read(
        _ data: Data,
        inputByteLimit: Int,
        migrations: PresetMigrations
    ) -> Result<LegacyPresetDocumentReading, PresetDocumentReadError> {
        guard data.count <= inputByteLimit else {
            return .failure(.budgetExceeded(.inputBytes))
        }

        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.notAJSONObject)
            }
            root = object
        } catch {
            return .failure(.notAJSONObject)
        }
        guard let rawVersion = root[PresetCodec.formatVersionKey] else {
            return .failure(.missingFormatVersion)
        }
        guard let version = PresetDocumentCodec.exactJSONInteger(rawVersion) else {
            return .failure(.malformedFormatVersion)
        }
        if version < 1 { return .failure(.unsupportedVersion(version)) }
        if version > InstrumentPresetV4.formatVersion {
            return .failure(.newerThanSupported(version))
        }

        if version == InstrumentPresetV4.formatVersion {
            do {
                let record = try PresetDocumentCodec.readCurrent(
                    data, inputByteLimit: inputByteLimit
                )
                return .success(LegacyPresetDocumentReading(record: record, source: .current, findings: []))
            } catch let error as PresetDocumentReadError {
                return .failure(error)
            } catch {
                return .failure(.decodingFailed("readFailed"))
            }
        }

        if version == Self.legacyNormalizationTarget {
            return readLegacy(
                data,
                root: root,
                source: .imported(fromVersion: version)
            )
        }

        var normalizedRoot = root
        if version < Self.legacyNormalizationTarget {
            do {
                normalizedRoot = try PresetCodec.migrate(
                    root,
                    from: version,
                    migrations: migrations,
                    targetVersion: Self.legacyNormalizationTarget
                )
            } catch let error as PresetFormatError {
                switch error {
                case .migrationProducedInvalidObject, .decodingFailed,
                     .unsupportedVersion, .newerThanSupported:
                    return .failure(.migrationFailed(fromVersion: version))
                default:
                    break
                }
                return .failure(.compatibility(Self.compatibilityError(error, version: version)))
            } catch {
                return .failure(.compatibility(.malformedFormatVersion))
            }
        }

        guard let normalizedData = try? JSONSerialization.data(withJSONObject: normalizedRoot),
              normalizedData.count <= inputByteLimit else {
            return .failure(.budgetExceeded(.inputBytes))
        }
        return readLegacy(
            normalizedData,
            root: normalizedRoot,
            source: .imported(fromVersion: version)
        )
    }

    private static func readLegacy(
        _ data: Data,
        root: [String: Any],
        source: LegacyPresetDocumentReading.Source
    ) -> Result<LegacyPresetDocumentReading, PresetDocumentReadError> {
        let compatibility: CompatibilityImport
        switch CompatibilityImporter.read(data) {
        case .success(let value):
            compatibility = value
        case .failure(let error):
            if case .budgetExceeded(let kind) = error {
                return .failure(.budgetExceeded(kind))
            }
            return .failure(.compatibility(error))
        }

        // The compatibility layer keeps a fully-outside override as a
        // diagnostic finding so its source can be reported. At the preset
        // boundary it is still an unplaceable override and must reject the
        // import rather than silently dropping the action.
        let droppedOverrides = compatibility.findings.compactMap { finding -> SpatialUnplaceableOverride? in
            guard case .droppedOutsideOverride(let layerIndex, let owner, let reason) = finding,
                  let layerID = compatibility.layers[safe: layerIndex]?.source.id else {
                return nil
            }
            return SpatialUnplaceableOverride(
                layerIndex: layerIndex, layerID: layerID, owner: owner, reason: reason
            )
        }
        if !droppedOverrides.isEmpty {
            return .failure(.spatialImport(.unplaceableOverrides(droppedOverrides)))
        }

        let imported: SpatialDocumentImport
        switch SpatialDocumentImporter.document(from: compatibility) {
        case .success(let value):
            imported = value
        case .failure(let error):
            if case .budgetExceeded(let kind) = error {
                return .failure(.budgetExceeded(kind))
            }
            return .failure(.spatialImport(error))
        }

        var settingsRoot = root
        settingsRoot.removeValue(forKey: "spatialWorkspace")
        let settings: InstrumentPreset
        do {
            let settingsData = try JSONSerialization.data(withJSONObject: settingsRoot)
            settings = try JSONDecoder().decode(InstrumentPreset.self, from: settingsData)
        } catch {
            return .failure(.decodingFailed(Self.stableDecodingCategory(error)))
        }

        let workspace: SpatialInstrumentWorkspace?
        if let value = root["spatialWorkspace"] {
            do {
                workspace = try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: JSONSerialization.data(withJSONObject: value))
            } catch {
                return .failure(.decodingFailed("invalidLegacyWorkspace"))
            }
        } else { workspace = nil }
        return .success(LegacyPresetDocumentReading(
            record: InstrumentPresetV4(settingsOf: settings, spatialDocument: imported.document),
            source: source,
            findings: imported.findings, legacySettings: settings, legacyWorkspace: workspace, detection: workspace?.detectionConfiguration
        ))
    }

    private static func compatibilityError(
        _ error: PresetFormatError,
        version: Int
    ) -> CompatibilityImportError {
        switch error {
        case .notAJSONObject: return .notAJSONObject
        case .missingFormatVersion: return .missingFormatVersion
        case .unsupportedVersion(let value): return .unsupportedVersion(value)
        case .newerThanSupported: return .unsupportedVersion(version)
        case .migrationProducedInvalidObject: return .unsupportedVersion(version)
        case .decodingFailed: return .unsupportedVersion(version)
        }
    }

    private static func stableDecodingCategory(_ error: Error) -> String {
        if error is DecodingError { return "decodingFailed" }
        return "readFailed"
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
