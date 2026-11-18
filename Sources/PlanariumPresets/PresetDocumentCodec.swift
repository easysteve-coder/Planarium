import Foundation
import PlanariumDomain

public enum PresetDocumentReadError: Error, Equatable {
    case summaryTooLong
    case tooManyChannels(Int)
    case notAJSONObject
    case missingFormatVersion
    case malformedFormatVersion
    case unsupportedVersion(Int)
    case newerThanSupported(Int)
    case budgetExceeded(SpatialDocumentBudget.Kind)
    case migrationFailed(fromVersion: Int)
    case unknownLatticeVersion
    case unsupportedLatticeVersion(SpatialLatticeVersion)
    case legacySpatialField
    case compatibility(CompatibilityImportError)
    case spatialImport(SpatialDocumentImportError)
    case spatialDocument(SpatialDocumentError)
    /// A surface was stored with a newer cell-derivation rule than this build knows.
    case surfaceRasterVersionUnsupported(Int)
    /// The cells derived from a surface's shape differ from the stored count or digest.
    case surfaceDerivationMismatch(surfaceID: UUID)
    /// A surface does not fit the stored play area or the play area itself is invalid.
    case inconsistentSurfaceSettings
    case decodingFailed(String)
}

enum PresetDocumentCodec {




    public static func readCurrent(_ data: Data) throws -> InstrumentPresetV4 {
        try readCurrent(data, inputByteLimit: SpatialDocumentBudget.production.inputBytes)
    }

    internal static func readCurrent(_ data: Data,
                                     inputByteLimit: Int) throws -> InstrumentPresetV4 {
        guard data.count <= inputByteLimit else {
            throw PresetDocumentReadError.budgetExceeded(.inputBytes)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PresetDocumentReadError.notAJSONObject
        }
        guard let root = object as? [String: Any] else {
            throw PresetDocumentReadError.notAJSONObject
        }
        guard let rawVersion = root["formatVersion"] else {
            throw PresetDocumentReadError.missingFormatVersion
        }
        guard let version = exactJSONInteger(rawVersion) else {
            throw PresetDocumentReadError.malformedFormatVersion
        }
        if version < 1 { throw PresetDocumentReadError.unsupportedVersion(version) }
        if version > InstrumentPresetV4.formatVersion {
            throw PresetDocumentReadError.newerThanSupported(version)
        }
        guard version == InstrumentPresetV4.formatVersion else {
            throw PresetDocumentReadError.unsupportedVersion(version)
        }
        if root.keys.contains("spatialWorkspace") {
            throw PresetDocumentReadError.legacySpatialField
        }
        if let document = root["spatialDocument"] as? [String: Any],
           let rawLattice = document["latticeVersion"] as? String {
            switch rawLattice {
            case SpatialLatticeVersion.polarDeviceV2.rawValue: break
            case SpatialLatticeVersion.polarDeviceV1.rawValue:
                throw PresetDocumentReadError.unsupportedLatticeVersion(.polarDeviceV1)
            default:
                throw PresetDocumentReadError.unknownLatticeVersion
            }
        }
        do {
            return try JSONDecoder().decode(InstrumentPresetV4.self, from: data)
        } catch let error as PresetDocumentReadError {
            throw error
        } catch let error as SpatialDocumentError {
            if case .budgetExceeded(let kind) = error {
                throw PresetDocumentReadError.budgetExceeded(kind)
            }
            throw PresetDocumentReadError.spatialDocument(error)
        } catch {
            throw PresetDocumentReadError.decodingFailed(stableDecodingCategory(error))
        }
    }

    internal static func exactJSONInteger(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c" else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              number.compare(NSNumber(value: Int.min)) != .orderedAscending,
              number.compare(NSNumber(value: Int.max)) != .orderedDescending else { return nil }
        let integer = number.intValue
        guard Double(integer) == double else { return nil }
        return integer
    }

    private static func stableDecodingCategory(_ error: Error) -> String {
        if error is DecodingError { return "decodingFailed" }
        return "readFailed"
    }
}
