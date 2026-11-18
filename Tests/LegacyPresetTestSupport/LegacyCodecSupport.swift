import Foundation
import PlanariumDomain
import SickPLSMonitorKit
@testable import PlanariumPresets

extension PresetCodec {
    public static func encode(_ preset: InstrumentPreset) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(preset)
    }
    public static func decode(_ data: Data, migrations: PresetMigrations = .production) throws -> InstrumentPreset {
        guard let object = try? JSONSerialization.jsonObject(with: data), var json = object as? [String: Any] else {
            throw PresetFormatError.notAJSONObject
        }
        guard let version = json[formatVersionKey] as? Int else {
            throw PresetFormatError.missingFormatVersion
        }
        guard version >= migrations.earliestSupportedVersion else {
            throw PresetFormatError.unsupportedVersion(version)
        }
        guard version <= InstrumentPreset.currentFormatVersion else {
            throw PresetFormatError.newerThanSupported(version)
        }

        json = try migrate(json, from: version, migrations: migrations,
                           targetVersion: InstrumentPreset.currentFormatVersion)

        do {
            let migrated = try JSONSerialization.data(withJSONObject: json)
            return try JSONDecoder().decode(InstrumentPreset.self, from: migrated)
        } catch let error as PresetFormatError {
            throw error
        } catch {
            throw PresetFormatError.decodingFailed(String(describing: error))
        }
    }
}

extension PresetDocumentCodec {
    public static func encode(_ preset: InstrumentPresetV4) throws -> Data {
        try encode(preset, inputByteLimit: SpatialDocumentBudget.production.inputBytes)
    }
    internal static func encode(_ preset: InstrumentPresetV4,
                                inputByteLimit: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(preset)
            guard data.count <= inputByteLimit else {
                throw PresetDocumentReadError.budgetExceeded(.inputBytes)
            }
            return data
        } catch let error as PresetDocumentReadError {
            throw error
        } catch let error as SpatialDocumentError {
            if case .budgetExceeded(let kind) = error {
                throw PresetDocumentReadError.budgetExceeded(kind)
            }
            throw PresetDocumentReadError.spatialDocument(error)
        } catch {
            throw PresetDocumentReadError.decodingFailed("encodingFailed")
        }
    }
}
