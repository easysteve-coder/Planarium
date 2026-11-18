import CoreGraphics
import Foundation
import PlanariumDomain
import PLSDeviceValues

// Pure geometry of the surface editor's canvas: centimetres in the world, points on the screen,
// the tools, what a click picks and where the handles of a selection stand. No document is
// changed here; every edit leaves through `SurfaceEdit` and the document owner.

/// What a drag on the empty field draws, or the choice to select. Panning and auditioning stay the
/// canvas tools they always were.
public enum SurfaceTool: String, CaseIterable, Equatable, Sendable {
    case select, rectangle, circle, polygon, ringSector

    public var label: String {
        switch self {
        case .select: return "Select (V)"
        case .rectangle: return "Rectangle (R)"
        case .circle: return "Circle (C)"
        case .polygon: return "Polygon (G)"
        case .ringSector: return "Ring sector (S)"
        }
    }
    public var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .polygon: return "hexagon"
        case .ringSector: return "chart.pie"
        }
    }
    public var helpLine: String {
        switch self {
        case .select:
            return "V Select · click picks a surface · ⇧ adds · drag moves · drag on empty field selects a box · handles resize and turn · ⌫ deletes · arrows nudge 1 cm / ⇧ 10 cm · ⌘D duplicates · Esc cancels"
        case .rectangle: return "R Rectangle · drag draws · ⇧ square · ⌥ from the centre · Esc cancels"
        case .circle: return "C Circle · drag from the centre to the edge · Esc cancels"
        case .polygon: return "G Polygon · click places corners · Enter or double-click closes · ⌫ takes back the last corner · Esc discards"
        case .ringSector: return "S Ring sector · drag between two radii and two bearings from the scanner · Esc cancels"
        }
    }
    /// Key that chooses the tool.
    public var key: Character {
        switch self {
        case .select: return "v"
        case .rectangle: return "r"
        case .circle: return "c"
        case .polygon: return "g"
        case .ringSector: return "s"
        }
    }
    public var drawsNewSurfaces: Bool { self != .select }
}

/// Centimetres in the world (+x right, +y forward, scanner at the origin) and points on the screen.
/// The mirrored view and the zoom live in the geometry; nothing else converts.
public struct SurfaceCanvasSpace: Equatable, Sendable {
    public let geometry: MetricCanvasGeometry
    public init(_ geometry: MetricCanvasGeometry) { self.geometry = geometry }

    public func screen(_ point: SurfacePoint) -> CGPoint {
        geometry.screenPoint(for: MetricScanPoint(xMeters: point.x / 100, yMeters: point.y / 100))
    }
    public func world(_ point: CGPoint) -> SurfacePoint? {
        geometry.metricPoint(forScreenPoint: point).map { SurfacePoint(x: $0.xMeters * 100, y: $0.yMeters * 100) }
    }
    /// Screen points per centimetre; a size in points is `points / pointsPerCentimeter` centimetres.
    public var pointsPerCentimeter: Double { 0.01 / geometry.viewport.metersPerPoint }
    public var canvasRect: CGRect { geometry.canvasRect }
}

/// Numbers the editor enters into the document: a tenth of a centimetre and of a degree is finer than
/// any measuring cell (1 cm, 0.5°) and keeps the entered values readable.
public enum SurfaceTidy {
    public static func centimeters(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    public static func degrees(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    public static func point(_ p: SurfacePoint) -> SurfacePoint { .init(x: centimeters(p.x), y: centimeters(p.y)) }
}

/// A world-frame point mapped through a placement and back.
public enum SurfaceFrame {
    public static func world(_ local: SurfacePoint, _ t: SurfaceTransform) -> SurfacePoint {
        let (s, c) = SurfaceTrig.sinCos(degrees: t.rotationDegrees)
        let x = t.mirrorX ? -local.x : local.x
        return .init(x: c * x - s * local.y + t.xCm, y: s * x + c * local.y + t.yCm)
    }
    public static func local(_ world: SurfacePoint, _ t: SurfaceTransform) -> SurfacePoint {
        let (s, c) = SurfaceTrig.sinCos(degrees: t.rotationDegrees)
        let dx = world.x - t.xCm, dy = world.y - t.yCm
        let lx = c * dx + s * dy, ly = -s * dx + c * dy
        return .init(x: t.mirrorX ? -lx : lx, y: ly)
    }
    /// Counter-clockwise angle (degrees) of the vector from `origin` to `point`; 0 is to the right.
    public static func angleDegrees(from origin: SurfacePoint, to point: SurfacePoint) -> Double {
        atan2(point.y - origin.y, point.x - origin.x) * 180 / .pi
    }
    public static func bearingDegrees(_ point: SurfacePoint) -> Double {
        atan2(point.x, max(0, point.y)) * 180 / .pi
    }
}

/// Plain words for a shape that cannot be used. Names no internal identifier.
public enum SurfaceProblemText {
    public static func text(_ problem: SurfaceShapeProblem) -> String {
        switch problem {
        case .size: return "Too small or too large"
        case .sectorNotFinite, .sectorRadii, .sectorBearings: return "Radius or bearing range is not valid"
        case .sectorBeyondProcessingLimit: return "The sector reaches too far"
        case .sectorCannotBePlaced: return "A ring sector stays centred on the scanner"
        case .polygonPointCount: return "A polygon needs at least 3 corners"
        case .polygonPointsOutOfRange: return "A corner is too far away"
        case .polygonRepeatedPoint: return "Two corners are at the same place"
        case .polygonNoArea: return "All corners are on one line"
        case .polygonFoldBack, .polygonEdgesMeet: return "Edges must not cross or touch"
        case .transformNotFinite, .transformPositionOutOfRange, .transformRotationOutOfRange: return "The position is not valid"
        }
    }
    public static func text(_ problems: [SurfaceShapeProblem]) -> String? { problems.first.map(text) }
}

// MARK: Picking

/// What a click on the field picks. Layers are tried from the selected one, then from the top of the
/// stack; inside a layer the surface drawn last wins. Hidden layers cannot be picked.
public enum SurfacePicker {
    public struct Pick: Equatable, Sendable {
        public let surfaceID: UUID
        public let layerID: UUID
    }

    public static func pick(at point: SurfacePoint, in document: SpatialDocument) -> Pick? {
        var order = document.layers.reversed().map { $0 }
        if let index = order.firstIndex(where: { $0.id == document.selectedLayerID }) {
            let selected = order.remove(at: index); order.insert(selected, at: 0)
        }
        for layer in order where layer.isVisible {
            for surface in layer.surfaces.reversed() where surface.containsWorldPoint(xCm: point.x, yCm: point.y) {
                return Pick(surfaceID: surface.id, layerID: layer.id)
            }
        }
        return nil
    }

    /// A layer that still consists of cells (an older preset) whose cell lies under the point. The layer is
    /// then the unit to pick: its cells are never edited one by one.
    public static func pickLegacyLayer(at point: SurfacePoint, in document: SpatialDocument) -> UUID? {
        guard point.x.isFinite, point.y.isFinite, point.y >= 0 else { return nil }
        let radius = hypot(point.x, point.y).rounded(), tick = ((SurfaceFrame.bearingDegrees(point) + 90) / 0.5).rounded()
        guard radius >= 1, radius <= Double(PolarDeviceLattice.maxRing), tick >= 0, tick <= Double(PolarDeviceLattice.maxTick),
              let cell = PolarDeviceLattice(ring: Int(radius), sector: Int(tick)) else { return nil }
        var order = document.layers.reversed().map { $0 }
        if let index = order.firstIndex(where: { $0.id == document.selectedLayerID }) {
            let selected = order.remove(at: index); order.insert(selected, at: 0)
        }
        return order.first { $0.isVisible && !$0.isSurfaceBacked && $0.cells.contains(cell) }?.id
    }

    /// Surfaces whose footprint touches the world box (a rubber-band selection).
    public static func surfaces(in box: SurfaceBounds, document: SpatialDocument) -> [Pick] {
        document.layers.filter(\.isVisible).flatMap { layer in
            layer.surfaces.filter { !$0.worldBounds.disjoint(from: box) }.map { Pick(surfaceID: $0.id, layerID: layer.id) }
        }
    }

    public static func surface(_ id: UUID, in document: SpatialDocument) -> (surface: SpatialSurface, layer: SpatialDocumentLayer)? {
        for layer in document.layers {
            if let surface = layer.surfaces.first(where: { $0.id == id }) { return (surface, layer) }
        }
        return nil
    }
}

// MARK: Handles

public enum SurfaceHandleKind: Hashable, Sendable {
    /// Corner of a rectangle in its own frame; signs say which one.
    case rectCorner(sx: Int, sy: Int)
    case rectEdge(sx: Int, sy: Int)
    case circleRadius(index: Int)
    case polygonPoint(index: Int)
    /// Corner of the box around the selection (uniform scaling about the opposite corner).
    case frameCorner(sx: Int, sy: Int)
    case rotate
    case sectorInner, sectorOuter, sectorStart, sectorEnd
    case sectorInnerStart, sectorInnerEnd, sectorOuterStart, sectorOuterEnd
    /// The tip of the control arrow of one assignment: dragging it turns the value axis.
    case axisTip(routingID: UUID)

    public var isAxis: Bool { if case .axisTip = self { return true }; return false }
}

public struct SurfaceHandle: Equatable, Sendable {
    public let kind: SurfaceHandleKind
    /// Where the handle is drawn and grabbed, in screen points.
    public let center: CGPoint
    public let isEnabled: Bool
    /// Why a handle cannot be used (shown as its help text). `nil` when enabled.
    public let disabledReason: String?
}

public struct SurfaceHandleLayout: Equatable, Sendable {
    public static let handleSize = CanvasGestureController.handleSize
    public let size: CGFloat
    public let hitRadius: CGFloat
    public let handles: [SurfaceHandle]
    /// Corners of the selection frame on the screen (clockwise from the upper left), if there is one.
    public let frame: [CGPoint]

    /// The handle under a point: the nearest within the hit radius. A disabled handle is returned too,
    /// so that its reason can be shown instead of the press falling through to the surface below.
    public func handle(at point: CGPoint) -> SurfaceHandle? {
        handles.compactMap { handle -> (SurfaceHandle, CGFloat)? in
            let dx = abs(handle.center.x - point.x), dy = abs(handle.center.y - point.y)
            guard (dx <= size / 2 && dy <= size / 2) || hypot(dx, dy) <= hitRadius else { return nil }
            return (handle, hypot(dx, dy))
        }.min { $0.1 < $1.1 }?.0
    }

    public static let empty = SurfaceHandleLayout(size: handleSize, hitRadius: handleSize / 2, handles: [], frame: [])

    /// - Parameters:
    ///   - surfaces: the selected surfaces, in document order.
    ///   - routings: the assignment whose axis arrow is shown, if any (`surface.id`, routing).
    ///   - lockedReason: why nothing can be edited right now (locked layer, Perform mode).
    public static func make(surfaces: [SpatialSurface], axisRoutingID: UUID?, space: SurfaceCanvasSpace,
                            lockedReason: String?) -> SurfaceHandleLayout {
        guard !surfaces.isEmpty else { return .empty }
        let bounds = surfaces.dropFirst().reduce(surfaces[0].worldBounds) { $0.union($1.worldBounds) }
        let corners = [SurfacePoint(x: bounds.minX, y: bounds.maxY), SurfacePoint(x: bounds.maxX, y: bounds.maxY),
                       SurfacePoint(x: bounds.maxX, y: bounds.minY), SurfacePoint(x: bounds.minX, y: bounds.minY)].map(space.screen)
        // The size follows the selection on screen as before (never smaller than the cell selection's handles).
        let extent = CGFloat(min(hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y),
                                 hypot(corners[2].x - corners[1].x, corners[2].y - corners[1].y)))
        let size = max(8, min(handleSize, extent / 2))
        let hit = max(size / 2 + 1, min(11, extent / 3))
        var handles: [SurfaceHandle] = []
        func add(_ kind: SurfaceHandleKind, _ point: CGPoint, _ reason: String?) {
            let blocked = lockedReason ?? reason
            handles.append(.init(kind: kind, center: keepInside(point, space.canvasRect, size), isEnabled: blocked == nil, disabledReason: blocked))
        }
        func addFrameCorners(_ reason: String?) {
            let centre = CGPoint(x: (corners[0].x + corners[2].x) / 2, y: (corners[0].y + corners[2].y) / 2)
            // corners: upper-left, upper-right, lower-right, lower-left
            for (index, sign) in [(-1, 1), (1, 1), (1, -1), (-1, -1)].enumerated() {
                add(.frameCorner(sx: sign.0, sy: sign.1), offset(corners[index], away: centre, by: hit * 0.9), reason)
            }
        }
        func addFrameRotation(_ reason: String?) {
            add(.rotate, offset(midpoint(corners[0], corners[1]), away: midpoint(corners[2], corners[3]), by: 26), reason)
        }

        if surfaces.count == 1, let surface = surfaces.first {
            switch surface.form {
            case .shape(.rectangle(let width, let height), let transform):
                let hw = width / 2, hh = height / 2
                for (sx, sy) in [(-1, 1), (1, 1), (1, -1), (-1, -1)] {
                    add(.rectCorner(sx: sx, sy: sy), space.screen(SurfaceFrame.world(.init(x: Double(sx) * hw, y: Double(sy) * hh), transform)), nil)
                }
                if extent > size * 5 {
                    for (sx, sy) in [(0, 1), (1, 0), (0, -1), (-1, 0)] {
                        add(.rectEdge(sx: sx, sy: sy), space.screen(SurfaceFrame.world(.init(x: Double(sx) * hw, y: Double(sy) * hh), transform)), nil)
                    }
                }
                // Turning: above the top edge, along the rectangle's own upward direction.
                let top = space.screen(SurfaceFrame.world(.init(x: 0, y: hh), transform))
                let centre = space.screen(SurfaceFrame.world(.init(x: 0, y: 0), transform))
                add(.rotate, offset(top, away: centre, by: 26), nil)
            case .shape(.circle(let radius), let transform):
                for index in 0..<4 {
                    let (s, c) = SurfaceTrig.sinCos(degrees: Double(index) * 90)
                    add(.circleRadius(index: index), space.screen(.init(x: transform.xCm + radius * c, y: transform.yCm + radius * s)), nil)
                }
            case .shape(.polygon(let points), let transform):
                for (index, point) in points.enumerated() { add(.polygonPoint(index: index), space.screen(SurfaceFrame.world(point, transform)), nil) }
                addFrameCorners(nil)
                addFrameRotation(nil)
            case .shape(.ringSector(let from, let to, let fromDegrees, let toDegrees), _):
                let midRadius = (from + to) / 2, midBearing = (fromDegrees + toDegrees) / 2
                func polar(_ radius: Double, _ bearing: Double) -> CGPoint {
                    let (s, c) = SurfaceTrig.sinCos(degrees: bearing)
                    return space.screen(.init(x: radius * s, y: radius * c))
                }
                let push = Double(hit * 0.9) / max(space.pointsPerCentimeter, 1e-9)
                let angular = push / max(midRadius, 1) * 180 / .pi
                let inner = max(0, from - push), outer = to + push
                add(.sectorInner, polar(inner, midBearing), nil); add(.sectorOuter, polar(outer, midBearing), nil)
                add(.sectorStart, polar(midRadius, fromDegrees - angular), nil); add(.sectorEnd, polar(midRadius, toDegrees + angular), nil)
                add(.sectorInnerStart, polar(inner, fromDegrees - angular), nil); add(.sectorInnerEnd, polar(inner, toDegrees + angular), nil)
                add(.sectorOuterStart, polar(outer, fromDegrees - angular), nil); add(.sectorOuterEnd, polar(outer, toDegrees + angular), nil)
            case .legacyMask:
                let reason = "An exact area from an older preset keeps its cells: turn, mirror or shift it by whole cells in the inspector"
                addFrameCorners(reason)
                addFrameRotation(reason)
            }
        } else {
            // Several surfaces: one box, scaled and turned together from the original shapes.
            let unscalable = surfaces.contains { surface in
                if surface.isLegacyMask { return true }
                if case .shape(.ringSector, _) = surface.form { return true }
                return false
            }
            let reason = unscalable ? "A ring sector or an exact area from an older preset cannot be scaled or turned together with other surfaces" : nil
            addFrameCorners(reason)
            addFrameRotation(reason)
        }
        if let routingID = axisRoutingID, surfaces.count == 1, let surface = surfaces.first,
           let arrow = SurfaceAxisPresentation(surface: surface, routingID: routingID) {
            add(.axisTip(routingID: routingID), SurfaceArrowScreen.ends(arrow, space: space).tip, nil)
        }
        return SurfaceHandleLayout(size: size, hitRadius: hit, handles: handles, frame: corners)
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    private static func offset(_ point: CGPoint, away from: CGPoint, by distance: CGFloat) -> CGPoint {
        let dx = point.x - from.x, dy = point.y - from.y, length = hypot(dx, dy)
        guard length > 1e-6 else { return CGPoint(x: point.x, y: point.y - distance) }
        return CGPoint(x: point.x + dx / length * distance, y: point.y + dy / length * distance)
    }
    /// A selection at the visible edge keeps its handles inside the canvas.
    private static func keepInside(_ point: CGPoint, _ rect: CGRect, _ size: CGFloat) -> CGPoint {
        let area = rect.insetBy(dx: size / 2, dy: size / 2)
        guard area.width > 0, area.height > 0 else { return point }
        return CGPoint(x: min(max(point.x, area.minX), area.maxX), y: min(max(point.y, area.minY), area.maxY))
    }
}


/// The arrow of a course is drawn a little inside the surface, so its tip handle never sits on a frame handle.
public enum SurfaceArrowScreen {
    public static func ends(_ arrow: SurfaceAxisPresentation, space: SurfaceCanvasSpace) -> (start: CGPoint, tip: CGPoint) {
        let a = space.screen(arrow.start), b = space.screen(arrow.tip)
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 1 else { return (a, b) }
        let inset = min(26, length / 3)
        let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
        return (CGPoint(x: a.x + ux * inset, y: a.y + uy * inset), CGPoint(x: b.x - ux * inset, y: b.y - uy * inset))
    }
}
