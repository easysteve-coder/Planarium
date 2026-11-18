import Foundation
import PLSDeviceValues

// Pure geometry of editable surfaces. Coordinates are centimetres with the scanner
// fixed at (0, 0): +x right, +y forward, visible half space y >= 0. A bearing is
// measured from the front: -90° left, 0° front, +90° right (x = r·sin, y = r·cos).
// Shapes become cells on the polarDeviceV2 grid (ring = raw distance in cm,
// tick 0…360 = bearing -90° + 0.5°·tick). One rule for the Patch Construction Kit
// and for the surface editor; nothing here knows kit texts or kit limits.

public struct SurfacePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Placement of a rectangle, circle or polygon: mirror the local x coordinate,
/// then rotate counter-clockwise (mathematically positive) about the local
/// origin, then move by (xCm, yCm).
public struct SurfaceTransform: Equatable, Sendable {
    public var xCm = 0.0
    public var yCm = 0.0
    public var rotationDegrees = 0.0
    public var mirrorX = false
    public init(xCm: Double = 0, yCm: Double = 0, rotationDegrees: Double = 0, mirrorX: Bool = false) {
        self.xCm = xCm; self.yCm = yCm; self.rotationDegrees = rotationDegrees; self.mirrorX = mirrorX
    }
    public static let identity = SurfaceTransform()
}

public struct SurfaceBounds: Equatable, Sendable {
    public var minX: Double, maxX: Double, minY: Double, maxY: Double
    public init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY
    }
    public func disjoint(from other: SurfaceBounds) -> Bool {
        maxX < other.minX - SurfaceGrid.epsilon || minX > other.maxX + SurfaceGrid.epsilon
            || maxY < other.minY - SurfaceGrid.epsilon || minY > other.maxY + SurfaceGrid.epsilon
    }
    public func union(_ other: SurfaceBounds) -> SurfaceBounds {
        SurfaceBounds(minX: min(minX, other.minX), maxX: max(maxX, other.maxX),
                      minY: min(minY, other.minY), maxY: max(maxY, other.maxY))
    }
    /// Distances from the scanner to the nearest and farthest point of the box.
    public var radialRange: (near: Double, far: Double) {
        let dx = minX > 0 ? minX : (maxX < 0 ? -maxX : 0), dy = minY > 0 ? minY : (maxY < 0 ? -maxY : 0)
        return (hypot(dx, dy), hypot(max(abs(minX), abs(maxX)), max(abs(minY), abs(maxY))))
    }
}

/// Sine and cosine in degrees; exact at multiples of 90° so that quarter turns
/// leave no rounding noise behind.
public enum SurfaceTrig {
    public static func sinCos(degrees: Double) -> (sin: Double, cos: Double) {
        let turns = degrees / 90
        if turns == turns.rounded(), abs(turns) < 1e6 {
            switch ((Int(turns) % 4) + 4) % 4 {
            case 0: return (0, 1)
            case 1: return (1, 0)
            case 2: return (0, -1)
            default: return (-1, 0)
            }
        }
        let radians: Double = degrees * .pi / 180
        return (sin(radians), cos(radians))
    }
}

/// Fixed numeric bounds of the geometry. Processing limits, not statements about the scanner.
public enum SurfaceLimits {
    /// Largest absolute coordinate or size of a shape.
    public static let maximumCoordinateCentimeters = 2000.0
    /// Rasterising never looks beyond this ring (explicitly not a statement about scanner range).
    public static let processingRadiusCentimeters = 1000.0
    public static let maximumPolygonPoints = 32
    /// Most colours of a surface's value-course coding. One limit for editor, document, writer and reader.
    public static let maximumValueColors = 16
}

/// The measuring grid shapes are rasterised onto.
public enum SurfaceGrid {
    /// Only rounding errors of the trigonometry, never a geometric margin.
    public static let epsilon = 1e-9
    public static let ticks = PolarDeviceLattice.maxTick + 1
    public static func bearing(tick: Int) -> Double { PolarDeviceLattice.bearingDegrees(forTick: tick) }
    /// Per tick: sin and cos of the bearing.
    public static let unit: [(sin: Double, cos: Double)] = (0..<ticks).map { SurfaceTrig.sinCos(degrees: bearing(tick: $0)) }
    public static func point(ring: Int, tick: Int) -> SurfacePoint {
        SurfacePoint(x: Double(ring) * unit[tick].sin, y: Double(ring) * unit[tick].cos)
    }
    /// Radius window `[from, to)`, bearing window `[from, to)`; a `to` of +90° includes the last tick.
    public static func sectorContains(ring: Int, tick: Int, fromCm: Double, toCm: Double, fromDegrees: Double, toDegrees: Double) -> Bool {
        let radius = Double(ring), bearing = bearing(tick: tick)
        guard radius >= fromCm, radius < toCm, bearing >= fromDegrees else { return false }
        return bearing < toDegrees || (toDegrees == 90 && bearing == 90)
    }
    public static func key(_ cell: PolarDeviceLattice) -> Int { cell.ring * ticks + cell.sector }
}

public enum SurfacePlayAreaProblem: Equatable, Sendable {
    case notFinite
    case rectangleOrder
    case behindScanner(yMin: Double)
    case rectangleCoordinatesOutOfRange
    case sectorRadii
    case sectorBearings
    case beyondProcessingLimit(radius: Double)
}

/// The chosen playing section of the instrument. Not a measured room and not a proven scanner range.
public enum SurfacePlayArea: Equatable, Sendable {
    case rectangle(xMinCm: Double, xMaxCm: Double, yMinCm: Double, yMaxCm: Double)
    case sector(fromCm: Double, toCm: Double, fromDegrees: Double, toDegrees: Double)

    /// The instrument default (ROADMAP fit to room: radius 0…200 cm, full fan). Not a measured room.
    public static let standard = SurfacePlayArea.sector(fromCm: 0, toCm: 200, fromDegrees: -90, toDegrees: 90)

    public var bounds: SurfaceBounds {
        switch self {
        case .rectangle(let xMin, let xMax, let yMin, let yMax):
            return SurfaceBounds(minX: xMin, maxX: xMax, minY: yMin, maxY: yMax)
        case .sector(let from, let to, let fromDegrees, let toDegrees):
            return SurfaceGeometry.sectorBounds(fromCm: from, toCm: to, fromDegrees: fromDegrees, toDegrees: toDegrees)
        }
    }
    public var boundingRadius: Double {
        switch self {
        case .rectangle(let xMin, let xMax, _, let yMax): return hypot(max(abs(xMin), abs(xMax)), yMax)
        case .sector(_, let to, _, _): return to
        }
    }
    public func contains(ring: Int, tick: Int) -> Bool {
        switch self {
        case .rectangle(let xMin, let xMax, let yMin, let yMax):
            let p = SurfaceGrid.point(ring: ring, tick: tick), e = SurfaceGrid.epsilon
            return p.x >= xMin - e && p.x < xMax - e && p.y >= yMin - e && p.y < yMax - e
        case .sector(let from, let to, let fromDegrees, let toDegrees):
            return SurfaceGrid.sectorContains(ring: ring, tick: tick, fromCm: from, toCm: to, fromDegrees: fromDegrees, toDegrees: toDegrees)
        }
    }

    public func problems() -> [SurfacePlayAreaProblem] {
        var result: [SurfacePlayAreaProblem] = []
        switch self {
        case .rectangle(let xMin, let xMax, let yMin, let yMax):
            guard [xMin, xMax, yMin, yMax].allSatisfy(\.isFinite) else { return [.notFinite] }
            if !(xMin < xMax) || !(yMin < yMax) { result.append(.rectangleOrder) }
            if yMin < 0 { result.append(.behindScanner(yMin: yMin)) }
            if xMin.magnitude > SurfaceLimits.maximumCoordinateCentimeters || xMax.magnitude > SurfaceLimits.maximumCoordinateCentimeters
                || yMax > SurfaceLimits.maximumCoordinateCentimeters {
                result.append(.rectangleCoordinatesOutOfRange)
            }
        case .sector(let from, let to, let fromDegrees, let toDegrees):
            guard [from, to, fromDegrees, toDegrees].allSatisfy(\.isFinite) else { return [.notFinite] }
            if !(0 <= from && from < to) { result.append(.sectorRadii) }
            if !(-90 <= fromDegrees && fromDegrees < toDegrees && toDegrees <= 90) { result.append(.sectorBearings) }
        }
        if result.isEmpty, boundingRadius > SurfaceLimits.processingRadiusCentimeters {
            result.append(.beyondProcessingLimit(radius: boundingRadius))
        }
        return result
    }
}

public enum SurfaceShapeProblem: Equatable, Sendable {
    /// A rectangle or circle size is not a finite number in (0, limit].
    case size(field: String)
    case sectorNotFinite
    case sectorRadii
    case sectorBearings
    case sectorBeyondProcessingLimit(toCm: Double)
    case sectorCannotBePlaced
    case polygonPointCount(found: Int)
    case polygonPointsOutOfRange
    case polygonRepeatedPoint(index: Int, point: SurfacePoint)
    case polygonNoArea
    case polygonFoldBack(edge: Int, otherEdge: Int)
    case polygonEdgesMeet(edge: Int, otherEdge: Int, pointCount: Int)
    case transformNotFinite
    case transformPositionOutOfRange
    case transformRotationOutOfRange
}

/// A surface's footprint in its own local coordinates.
public enum SurfaceShape: Equatable, Sendable {
    case rectangle(widthCm: Double, heightCm: Double)
    case circle(radiusCm: Double)
    case polygon(pointsCm: [SurfacePoint])
    /// Ring sector centred on the scanner; cannot be moved, rotated or mirrored.
    case ringSector(fromCm: Double, toCm: Double, fromDegrees: Double, toDegrees: Double)

    public func problems(transform: SurfaceTransform) -> [SurfaceShapeProblem] {
        let limit = SurfaceLimits.maximumCoordinateCentimeters
        var result: [SurfaceShapeProblem] = []
        func size(_ value: Double, _ name: String) {
            if !value.isFinite || value <= 0 || value > limit { result.append(.size(field: name)) }
        }
        switch self {
        case .rectangle(let width, let height): size(width, "widthCm"); size(height, "heightCm")
        case .circle(let radius): size(radius, "radiusCm")
        case .polygon(let points): result.append(contentsOf: SurfaceGeometry.polygonProblems(points))
        case .ringSector(let from, let to, let fromDegrees, let toDegrees):
            if ![from, to, fromDegrees, toDegrees].allSatisfy(\.isFinite) { result.append(.sectorNotFinite); break }
            if !(0 <= from && from < to) { result.append(.sectorRadii) }
            if !(-90 <= fromDegrees && fromDegrees < toDegrees && toDegrees <= 90) { result.append(.sectorBearings) }
            if to > SurfaceLimits.processingRadiusCentimeters { result.append(.sectorBeyondProcessingLimit(toCm: to)) }
            if transform != .identity { result.append(.sectorCannotBePlaced) }
        }
        if case .ringSector = self {} else {
            if ![transform.xCm, transform.yCm, transform.rotationDegrees].allSatisfy(\.isFinite) {
                result.append(.transformNotFinite)
            } else {
                if transform.xCm.magnitude > limit || transform.yCm.magnitude > limit { result.append(.transformPositionOutOfRange) }
                if transform.rotationDegrees.magnitude > 360 { result.append(.transformRotationOutOfRange) }
            }
        }
        return result
    }
}

/// Countdowns for the two bounds of rasterising: grid points looked at and cells produced.
public struct SurfaceRasterBudget: Equatable, Sendable {
    public var candidates: Int
    public var cells: Int
    public init(candidates: Int, cells: Int) { self.candidates = candidates; self.cells = cells }
}

public enum SurfaceRasterError: Error, Equatable, Sendable {
    /// More grid points would have to be looked at than the budget allows.
    case workLimit
    /// More cells would result than the budget allows.
    case cellLimit
}

/// A shape with its placement, ready to be turned into grid cells.
public struct SurfacePlacedShape: Equatable, Sendable {
    public let shape: SurfaceShape
    public let transform: SurfaceTransform
    public init(shape: SurfaceShape, transform: SurfaceTransform) { self.shape = shape; self.transform = transform }

    /// World coordinates of the outline's corners (circle and ring sector: none).
    public func worldVertices() -> [SurfacePoint] {
        let local: [SurfacePoint]
        switch shape {
        case .rectangle(let w, let h):
            local = [SurfacePoint(x: -w / 2, y: -h / 2), SurfacePoint(x: w / 2, y: -h / 2), SurfacePoint(x: w / 2, y: h / 2), SurfacePoint(x: -w / 2, y: h / 2)]
        case .polygon(let points): local = points
        case .circle, .ringSector: return []
        }
        let (s, c) = SurfaceTrig.sinCos(degrees: transform.rotationDegrees)
        return local.map { forward($0, sin: s, cos: c) }
    }
    private func forward(_ p: SurfacePoint, sin s: Double, cos c: Double) -> SurfacePoint {
        let x0 = transform.mirrorX ? -p.x : p.x
        return SurfacePoint(x: c * x0 - s * p.y + transform.xCm, y: s * x0 + c * p.y + transform.yCm)
    }

    public var worldBounds: SurfaceBounds {
        switch shape {
        case .circle(let radius):
            return SurfaceBounds(minX: transform.xCm - radius, maxX: transform.xCm + radius, minY: transform.yCm - radius, maxY: transform.yCm + radius)
        case .ringSector(let from, let to, let fromDegrees, let toDegrees):
            return SurfaceGeometry.sectorBounds(fromCm: from, toCm: to, fromDegrees: fromDegrees, toDegrees: toDegrees)
        default:
            let points = worldVertices()
            return SurfaceBounds(minX: points.map(\.x).min()!, maxX: points.map(\.x).max()!,
                                 minY: points.map(\.y).min()!, maxY: points.map(\.y).max()!)
        }
    }

    /// Does the shape contain this world point? The same predicate the rasteriser uses.
    public func contains(x: Double, y: Double) -> Bool {
        containment()(0, 0, x, y)
    }

    /// Grid cells of the shape (rings >= 1, never beyond the processing limit), ordered by ring then tick.
    /// The budget counts the grid points looked at and the cells produced.
    public func cells(budget: inout SurfaceRasterBudget) throws -> [PolarDeviceLattice] {
        let bounds = worldBounds, e = SurfaceGrid.epsilon
        let radial = bounds.radialRange
        let ringLimit = min(Int(SurfaceLimits.processingRadiusCentimeters), PolarDeviceLattice.maxRing)
        let firstRing = max(1, Int((radial.near - e).rounded(.up))), lastRing = min(ringLimit, Int((radial.far + e).rounded(.down)))
        guard firstRing <= lastRing else { return [] }
        let predicate = containment()
        var result: [PolarDeviceLattice] = []
        for ring in firstRing...lastRing {
            budget.candidates -= SurfaceGrid.ticks
            guard budget.candidates >= 0 else { throw SurfaceRasterError.workLimit }
            let radius = Double(ring)
            for tick in 0..<SurfaceGrid.ticks {
                let x = radius * SurfaceGrid.unit[tick].sin, y = radius * SurfaceGrid.unit[tick].cos
                guard x >= bounds.minX - e, x <= bounds.maxX + e, y >= bounds.minY - e, y <= bounds.maxY + e else { continue }
                if predicate(ring, tick, x, y) {
                    budget.cells -= 1
                    guard budget.cells >= 0 else { throw SurfaceRasterError.cellLimit }
                    result.append(PolarDeviceLattice(ring: ring, sector: tick)!)
                }
            }
        }
        return result
    }

    private func containment() -> (Int, Int, Double, Double) -> Bool {
        let e = SurfaceGrid.epsilon
        if case .ringSector(let from, let to, let fromDegrees, let toDegrees) = shape {
            return { ring, tick, x, y in
                if ring > 0 {
                    return SurfaceGrid.sectorContains(ring: ring, tick: tick, fromCm: from, toCm: to, fromDegrees: fromDegrees, toDegrees: toDegrees)
                }
                // Free point: radius and bearing from the coordinates.
                let radius = hypot(x, y), bearing = atan2(x, y) * 180 / .pi
                return radius >= from && radius < to && bearing >= fromDegrees && (bearing < toDegrees || (toDegrees == 90 && bearing == 90))
            }
        }
        let (s, c) = SurfaceTrig.sinCos(degrees: transform.rotationDegrees)
        let t = transform
        /// Inverse placement: undo the move, undo the rotation, undo the mirror.
        func local(_ x: Double, _ y: Double) -> (Double, Double) {
            let dx = x - t.xCm, dy = y - t.yCm
            let lx = c * dx + s * dy, ly = -s * dx + c * dy
            return (t.mirrorX ? -lx : lx, ly)
        }
        switch shape {
        case .rectangle(let width, let height):
            let hw = width / 2, hh = height / 2
            return { _, _, x, y in
                let (lx, ly) = local(x, y)
                return lx >= -hw - e && lx < hw - e && ly >= -hh - e && ly < hh - e
            }
        case .circle(let radius):
            return { _, _, x, y in
                let (lx, ly) = local(x, y)
                return lx * lx + ly * ly <= (radius + e) * (radius + e)
            }
        case .polygon(let points):
            return { _, _, x, y in
                let (lx, ly) = local(x, y)
                return SurfaceGeometry.polygon(points, contains: SurfacePoint(x: lx, y: ly))
            }
        case .ringSector: return { _, _, _, _ in false }
        }
    }
}

public enum SurfaceGeometry {
    public static func sectorBounds(fromCm: Double, toCm: Double, fromDegrees: Double, toDegrees: Double) -> SurfaceBounds {
        var points: [SurfacePoint] = []
        for radius in [fromCm, toCm] {
            for degrees in [fromDegrees, toDegrees] {
                let (s, c) = SurfaceTrig.sinCos(degrees: degrees)
                points.append(SurfacePoint(x: radius * s, y: radius * c))
            }
        }
        if fromDegrees < 0 && toDegrees > 0 { points.append(SurfacePoint(x: 0, y: toCm)) }
        return SurfaceBounds(minX: points.map(\.x).min()!, maxX: points.map(\.x).max()!,
                             minY: points.map(\.y).min()!, maxY: points.map(\.y).max()!)
    }

    // MARK: Polygons

    /// Inside including the border (a point within rounding distance of an edge counts as inside).
    public static func polygon(_ points: [SurfacePoint], contains p: SurfacePoint) -> Bool {
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let a = points[i], b = points[j]
            if distanceSquared(from: p, toSegment: a, b) <= SurfaceGrid.epsilon * SurfaceGrid.epsilon { return true }
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
    private static func distanceSquared(from p: SurfacePoint, toSegment a: SurfacePoint, _ b: SurfacePoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        let ex = a.x + t * dx - p.x, ey = a.y + t * dy - p.y
        return ex * ex + ey * ey
    }

    /// Why a point list is not a usable simple polygon. Both winding directions are fine;
    /// the first point must not be repeated at the end.
    public static func polygonProblems(_ points: [SurfacePoint]) -> [SurfaceShapeProblem] {
        let range = 3...SurfaceLimits.maximumPolygonPoints
        guard range.contains(points.count) else { return [.polygonPointCount(found: points.count)] }
        let limit = SurfaceLimits.maximumCoordinateCentimeters
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= limit && abs($0.y) <= limit }) else {
            return [.polygonPointsOutOfRange]
        }
        var seen = Set<[Double]>()
        for (index, point) in points.enumerated() where !seen.insert([point.x, point.y]).inserted {
            return [.polygonRepeatedPoint(index: index, point: point)]
        }
        // All points on one line: no area at all (checked first, a fold-back would be a misleading reason).
        let first = points[0], second = points[1]
        if points.allSatisfy({ abs((second.x - first.x) * ($0.y - first.y) - (second.y - first.y) * ($0.x - first.x)) <= SurfaceGrid.epsilon }) {
            return [.polygonNoArea]
        }
        let count = points.count
        for i in 0..<count {
            let a = points[i], b = points[(i + 1) % count]
            for j in (i + 1)..<count {
                let c = points[j], d = points[(j + 1) % count]
                let adjacent = j == i + 1 || (i == 0 && j == count - 1)
                if adjacent {
                    // Edges sharing a corner may only meet there: a collinear fold-back overlays them.
                    let shared = j == i + 1 ? b : a
                    let u = j == i + 1 ? a : b, v = j == i + 1 ? d : c
                    let cross = (u.x - shared.x) * (v.y - shared.y) - (u.y - shared.y) * (v.x - shared.x)
                    let dot = (u.x - shared.x) * (v.x - shared.x) + (u.y - shared.y) * (v.y - shared.y)
                    if abs(cross) <= SurfaceGrid.epsilon, dot > 0 { return [.polygonFoldBack(edge: i, otherEdge: j)] }
                } else if segmentsMeet(a, b, c, d) {
                    return [.polygonEdgesMeet(edge: i, otherEdge: j, pointCount: count)]
                }
            }
        }
        return []
    }

    /// True when the closed segments share at least one point (touching counts).
    private static func segmentsMeet(_ a: SurfacePoint, _ b: SurfacePoint, _ c: SurfacePoint, _ d: SurfacePoint) -> Bool {
        func orientation(_ p: SurfacePoint, _ q: SurfacePoint, _ r: SurfacePoint) -> Int {
            let value = (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
            return abs(value) <= SurfaceGrid.epsilon ? 0 : (value > 0 ? 1 : -1)
        }
        func within(_ p: SurfacePoint, _ q: SurfacePoint, _ r: SurfacePoint) -> Bool {
            min(p.x, q.x) - SurfaceGrid.epsilon <= r.x && r.x <= max(p.x, q.x) + SurfaceGrid.epsilon
                && min(p.y, q.y) - SurfaceGrid.epsilon <= r.y && r.y <= max(p.y, q.y) + SurfaceGrid.epsilon
        }
        let o1 = orientation(a, b, c), o2 = orientation(a, b, d), o3 = orientation(c, d, a), o4 = orientation(c, d, b)
        if o1 != o2 && o3 != o4 { return true }
        return (o1 == 0 && within(a, b, c)) || (o2 == 0 && within(a, b, d)) || (o3 == 0 && within(c, d, a)) || (o4 == 0 && within(c, d, b))
    }
}
