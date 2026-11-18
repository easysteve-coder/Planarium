import Foundation
import PlanariumDomain

// Kit adapter of the shared surface geometry. The shapes, placements, play area and the
// rasteriser live in PlanariumDomain (Surface/SurfaceGeometry.swift) and are the same rule
// the surface editor uses; this file only maps them to the kit's names and plain-language texts.
// Coordinates, bearings and rotation follow that file's header.

public typealias PatchPoint = SurfacePoint
public typealias PatchTransform = SurfaceTransform
public typealias PatchBounds = SurfaceBounds
public typealias PatchTrig = SurfaceTrig
public typealias PatchGrid = SurfaceGrid
public typealias PatchPlayArea = SurfacePlayArea
public typealias PatchShape = SurfaceShape
public typealias PatchPlacedShape = SurfacePlacedShape
typealias PatchGeometry = SurfaceGeometry

extension SurfacePlayArea {
    var summary: String {
        switch self {
        case .rectangle(let xMin, let xMax, let yMin, let yMax):
            return "rectangle x \(PatchNumber.text(xMin))…\(PatchNumber.text(xMax)) cm, y \(PatchNumber.text(yMin))…\(PatchNumber.text(yMax)) cm"
        case .sector(let from, let to, let fromDegrees, let toDegrees):
            return "ring sector \(PatchNumber.text(from))…\(PatchNumber.text(to)) cm, bearing \(PatchNumber.text(fromDegrees))°…\(PatchNumber.text(toDegrees))°"
        }
    }

    func kitProblems() -> [String] {
        let limit = Int(SurfaceLimits.maximumCoordinateCentimeters)
        return problems().map { problem in
            switch problem {
            case .notFinite: return "playArea: all numbers must be finite"
            case .rectangleOrder: return "playArea: need xMinCm < xMaxCm and yMinCm < yMaxCm"
            case .behindScanner(let yMin):
                return "playArea: yMinCm \(PatchNumber.text(yMin)) is behind the scanner — the visible half space starts at y = 0"
            case .rectangleCoordinatesOutOfRange: return "playArea: coordinates must stay within ±\(limit) cm"
            case .sectorRadii: return "playArea: need 0 <= fromCm < toCm"
            case .sectorBearings:
                return "playArea: need -90 <= fromDegrees < toDegrees <= 90 (-90° left, 0° front, +90° right)"
            case .beyondProcessingLimit(let radius):
                return "playArea: reaches \(PatchNumber.text(radius)) cm from the scanner; this offline kit processes at most \(Int(SurfaceLimits.processingRadiusCentimeters)) cm (a processing limit, not a statement about the scanner)"
            }
        }
    }
}

extension SurfaceShape {
    var summary: String {
        switch self {
        case .rectangle(let width, let height): return "rectangle \(PatchNumber.text(width))×\(PatchNumber.text(height)) cm"
        case .circle(let radius): return "circle r \(PatchNumber.text(radius)) cm"
        case .polygon(let points): return "polygon \(points.count) points"
        case .ringSector(let from, let to, let fromDegrees, let toDegrees):
            return "ring sector \(PatchNumber.text(from))…\(PatchNumber.text(to)) cm, \(PatchNumber.text(fromDegrees))°…\(PatchNumber.text(toDegrees))°"
        }
    }

    func kitProblems(transform: SurfaceTransform) -> [String] {
        let limit = Int(SurfaceLimits.maximumCoordinateCentimeters)
        return problems(transform: transform).map { problem in
            switch problem {
            case .size(let field): return "\(field) must be a finite number above 0 and at most \(limit) cm"
            case .sectorNotFinite: return "all sector numbers must be finite"
            case .sectorRadii: return "need 0 <= fromCm < toCm"
            case .sectorBearings: return "need -90 <= fromDegrees < toDegrees <= 90 (-90° left, 0° front, +90° right)"
            case .sectorBeyondProcessingLimit(let to):
                return "toCm \(PatchNumber.text(to)) is beyond the offline processing limit of \(Int(SurfaceLimits.processingRadiusCentimeters)) cm"
            case .sectorCannotBePlaced:
                return "a ring-sector shape is centred on the scanner and cannot be moved, rotated or mirrored (a bearing would become ambiguous) — use a polygon for a placed wedge"
            case .polygonPointCount(let found):
                return "polygon needs 3–\(SurfaceLimits.maximumPolygonPoints) corner points, found \(found)"
            case .polygonPointsOutOfRange: return "polygon points must be finite and within ±\(limit) cm"
            case .polygonRepeatedPoint(let index, let point):
                return "polygon point \(index) (\(PatchNumber.text(point.x)), \(PatchNumber.text(point.y))) repeats an earlier point — list each corner once and do not repeat the first point at the end"
            case .polygonNoArea: return "polygon has no area (all points on one line)"
            case .polygonFoldBack(let edge, let other): return "polygon edges \(edge) and \(other) fold back onto each other (overlaid edges)"
            case .polygonEdgesMeet(let edge, let other, let count):
                return "polygon edges \(edge) (point \(edge)→\((edge + 1) % count)) and \(other) (point \(other)→\((other + 1) % count)) cross or touch — the outline must be a simple closed shape"
            case .transformNotFinite: return "transform numbers must be finite"
            case .transformPositionOutOfRange: return "transform xCm/yCm must stay within ±\(limit) cm"
            case .transformRotationOutOfRange: return "transform rotationDegrees must be within -360…360"
            }
        }
    }
}

extension SurfacePlacedShape {
    /// Grid cells of the shape (rings >= 1, never beyond the offline limit), ordered by ring then tick.
    /// `candidates` counts the grid points looked at and stops the work when it reaches zero.
    func cells(candidates: inout Int, cellBudget: inout Int) throws -> [PolarDeviceLattice] {
        var budget = SurfaceRasterBudget(candidates: candidates, cells: cellBudget)
        defer { candidates = budget.candidates; cellBudget = budget.cells }
        do { return try cells(budget: &budget) }
        catch SurfaceRasterError.workLimit {
            throw PatchKitError("the shapes are too large or too numerous to rasterise within the kit's work limit — make the regions smaller or fewer")
        } catch {
            throw PatchKitError("the regions together would assign more than \(PatchKitLimits.maximumCellAssignments) cells — make them smaller")
        }
    }
}

/// Locale-free number text: at most two decimals, no exponent, no trailing zeros.
enum PatchNumber {
    static func text(_ value: Double, decimals: Int = 2) -> String {
        guard value.isFinite else { return "?" }
        let factor = (0..<decimals).reduce(1.0) { result, _ in result * 10 }
        let scaled = (abs(value) * factor).rounded()
        guard scaled < 9e15 else { return value < 0 ? "-big" : "big" }
        let whole = Int64(scaled)
        let unit = Int64(factor)
        var fraction = String(whole % unit)
        fraction = String(repeating: "0", count: decimals - fraction.count) + fraction
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let sign = value < 0 && whole != 0 ? "-" : ""
        return sign + String(whole / unit) + (fraction.isEmpty ? "" : "." + fraction)
    }
}
