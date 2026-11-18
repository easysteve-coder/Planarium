import Foundation
import PLSDeviceValues

/// What happens to cells of a shape that lie outside the play area. The default never cuts silently.
public enum SurfaceOutsidePolicy: String, Codable, Equatable, Sendable {
    /// A shape reaching outside the play area (or behind the scanner) is refused.
    case error
    /// Only on request: the outside part is cut off and counted.
    case clip
}

/// Document-wide surface settings. The play area is a chosen playing section, not a measured
/// room and not a proven scanner range. Masks of existing layers are never cut by it.
public struct SurfaceSettings: Equatable, Sendable {
    public var playArea: SurfacePlayArea
    public var outsidePolicy: SurfaceOutsidePolicy
    public init(playArea: SurfacePlayArea = .standard, outsidePolicy: SurfaceOutsidePolicy = .error) {
        self.playArea = playArea; self.outsidePolicy = outsidePolicy
    }
    public static let standard = SurfaceSettings()
    public var isStandard: Bool { self == .standard }
    public func problems() -> [SurfacePlayAreaProblem] { playArea.problems() }
}

public enum SurfaceDerivationError: Error, Equatable, Sendable {
    case unsupportedRasterVersion(Int)
    case invalidShape([SurfaceShapeProblem])
    case invalidPlayArea([SurfacePlayAreaProblem])
    case rasterLimit(SurfaceRasterError)
    /// The shape produced no cell inside the play area. `generated` counts the cells before cutting.
    case noCells(generated: Int)
    /// Policy `error`: part of the shape lies outside the play area or behind the scanner.
    case outsidePlayArea(outside: Int, generated: Int, behindScanner: Bool)
}

/// The cells a shape really produces under one play area. Derived, never a primary datum.
public struct SurfaceDerivation: Equatable, Sendable {
    public let rasterVersion: Int
    /// Ordered by ring, then tick.
    public let cells: [PolarDeviceLattice]
    /// Cells of the shape before the play area cut them.
    public let generatedCount: Int
    public var clippedCount: Int { generatedCount - cells.count }
    public let behindScanner: Bool
    public let digest: UInt64
    public var digestText: String {
        let text = String(digest, radix: 16)
        return String(repeating: "0", count: 16 - text.count) + text
    }
}

/// The single rasteriser for the Patch Construction Kit and the surface editor. A change of the
/// rule (predicate, epsilon, trigonometry, order) is a new version; the old one stays frozen.
public enum SurfaceRasterizer {
    public static let currentVersion = 1

    /// Work bounds of one surface: every grid point out to the processing radius, and the
    /// per-layer address budget as the cell cap.
    public static let documentBudget = SurfaceRasterBudget(
        candidates: Int(SurfaceLimits.processingRadiusCentimeters) * SurfaceGrid.ticks,
        cells: SpatialDocumentBudget.production.addressesPerLayer)

    /// FNV-1a-64 over (ring, tick) as two little-endian UInt16 each, in cell order.
    /// Detects corruption and rule drift; it is not a security function.
    public static func digest(of cells: [PolarDeviceLattice]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) { hash ^= UInt64(byte); hash = hash &* 0x100_0000_01b3 }
        for cell in cells {
            let ring = UInt16(truncatingIfNeeded: cell.ring), tick = UInt16(truncatingIfNeeded: cell.sector)
            mix(UInt8(ring & 0xff)); mix(UInt8(ring >> 8)); mix(UInt8(tick & 0xff)); mix(UInt8(tick >> 8))
        }
        return hash
    }

    /// Rasterises a shape and applies the play area according to the policy. All-or-nothing.
    public static func derive(shape: SurfaceShape, transform: SurfaceTransform, settings: SurfaceSettings,
                              version: Int = currentVersion,
                              budget: SurfaceRasterBudget = documentBudget) throws -> SurfaceDerivation {
        guard version == 1 else { throw SurfaceDerivationError.unsupportedRasterVersion(version) }
        let areaProblems = settings.playArea.problems()
        guard areaProblems.isEmpty else { throw SurfaceDerivationError.invalidPlayArea(areaProblems) }
        let shapeProblems = shape.problems(transform: transform)
        guard shapeProblems.isEmpty else { throw SurfaceDerivationError.invalidShape(shapeProblems) }
        let placed = SurfacePlacedShape(shape: shape, transform: transform)
        var remaining = budget
        let generated: [PolarDeviceLattice]
        do { generated = try placed.cells(budget: &remaining) }
        catch let error as SurfaceRasterError { throw SurfaceDerivationError.rasterLimit(error) }
        let area = settings.playArea
        let inside = generated.filter { area.contains(ring: $0.ring, tick: $0.sector) }
        let outside = generated.count - inside.count
        var isSector = false
        if case .ringSector = shape { isSector = true }
        let behind = !isSector && placed.worldBounds.minY < -SurfaceGrid.epsilon
        guard !inside.isEmpty else { throw SurfaceDerivationError.noCells(generated: generated.count) }
        if settings.outsidePolicy == .error, outside > 0 || behind {
            throw SurfaceDerivationError.outsidePlayArea(outside: outside, generated: generated.count, behindScanner: behind)
        }
        return SurfaceDerivation(rasterVersion: version, cells: inside, generatedCount: generated.count,
                                 behindScanner: behind, digest: digest(of: inside))
    }

    /// Derivation of an exact mask: the cells are the primary datum, nothing is cut.
    public static func derive(maskCells: Set<PolarDeviceLattice>) -> SurfaceDerivation {
        let sorted = maskCells.sorted { $0.ring == $1.ring ? $0.sector < $1.sector : $0.ring < $1.ring }
        return SurfaceDerivation(rasterVersion: currentVersion, cells: sorted, generatedCount: sorted.count,
                                 behindScanner: false, digest: digest(of: sorted))
    }
}
