import CoreGraphics
import Foundation
import PlanariumDomain

// A pointer drag on a surface is an ephemeral geometric sketch. `evaluate()` is pure: it turns the
// start, the pointer now and the original surfaces into the picture to draw and, when the drag
// is let go, the edits to commit. Nothing here touches a document, a compiler or a sound.

public struct SurfaceModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = SurfaceModifiers(rawValue: 1)
    public static let option = SurfaceModifiers(rawValue: 2)
    public static let command = SurfaceModifiers(rawValue: 4)
}

public extension SurfaceEditError {
    /// Plain words for the notice line. Names no internal identifier.
    var userMessage: String {
        switch self {
        case .layerLocked: return "Layer is locked"
        case .emptySelection: return "Nothing selected"
        case .invalidNumber: return "A number is not usable"
        case .layerHasOwnContent: return "Convert the layer to a surface first"
        case .alreadySurfaceBacked: return "Layer already consists of surfaces"
        case .notAShapedSurface: return "An exact mask can only be turned, mirrored or shifted on the grid"
        case .notAnExactMask: return "Only an exact mask can do this"
        case .ringSectorCannotBePlaced: return "A ring sector stays centred on the scanner"
        case .resizeCannotChangeFrame: return "Resize keeps the kind of shape; a ring sector and a placed shape cannot be exchanged"
        case .maskWouldLeaveTheGrid: return "The mask would leave the measuring grid; nothing changed"
        case .derivation(_, let reason):
            switch reason {
            case .noCells: return "The shape contains no measuring cell"
            case .outsidePlayArea: return "The shape reaches outside the play area"
            case .invalidShape(let problems): return SurfaceProblemText.text(problems) ?? "The shape is not valid"
            case .rasterLimit: return "The shape is too large"
            case .invalidPlayArea, .unsupportedRasterVersion: return "The play area is not valid"
            }
        case .document(.budgetExceeded): return "Too many surfaces or cells"
        case .invalidSettings: return "The play area is not valid"
        case .invalidAssignment: return "The assignment is not valid"
        case .notAPolygon: return "Only a polygon has corners to move"
        case .pointIndexOutOfRange: return "That corner does not exist"
        default: return "Surface edit rejected"
        }
    }
}

/// A polygon the user is still clicking together. It is a sketch until it is closed.
public struct SurfacePolygonDraft: Equatable, Sendable {
    public private(set) var points: [SurfacePoint] = []
    /// Where the pointer is now (the rubber-band edge).
    public var hover: SurfacePoint?
    public init() {}

    /// Adds a corner. The same place twice in a row is one corner.
    @discardableResult public mutating func add(_ point: SurfacePoint) -> Bool {
        let tidy = SurfaceTidy.point(point)
        guard tidy.x.isFinite, tidy.y.isFinite, points.last != tidy else { return false }
        points.append(tidy)
        return true
    }
    @discardableResult public mutating func removeLast() -> Bool { points.popLast() != nil }

    /// Why the corners placed so far do not make a polygon. Fewer than three corners is simply "not yet".
    public var problems: [SurfaceShapeProblem] {
        points.count >= 3 ? SurfaceGeometry.polygonProblems(points) : []
    }
    public var canClose: Bool { points.count >= 3 && problems.isEmpty }
    public var message: String? {
        if points.isEmpty { return nil }
        if points.count < 3 { return "A polygon needs at least 3 corners" }
        return SurfaceProblemText.text(problems)
    }
    /// The finished shape, centred on its box so that turning and mirroring act about its middle.
    public func shape() -> (shape: SurfaceShape, transform: SurfaceTransform)? {
        guard canClose else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let centre = SurfacePoint(x: SurfaceTidy.centimeters((xs.min()! + xs.max()!) / 2), y: SurfaceTidy.centimeters((ys.min()! + ys.max()!) / 2))
        let local = points.map { SurfacePoint(x: SurfaceTidy.centimeters($0.x - centre.x), y: SurfaceTidy.centimeters($0.y - centre.y)) }
        guard SurfaceGeometry.polygonProblems(local).isEmpty else { return nil }
        return (.polygon(pointsCm: local), SurfaceTransform(xCm: centre.x, yCm: centre.y))
    }
}

public struct SurfaceGesture: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case draw(SurfaceTool)
        case move
        case rotate(pivot: SurfacePoint, startAngle: Double)
        case handle(SurfaceHandleKind)
        case marquee(additive: Bool)
    }

    /// What the drag looks like now and what it would commit.
    public struct Result: Equatable, Sendable {
        /// New shape and placement of surfaces being moved, turned or resized (by surface).
        public var placements: [UUID: SurfacePlacement] = [:]
        /// The surface being drawn.
        public var drawn: (shape: SurfaceShape, transform: SurfaceTransform)?
        /// The control arrow while it is dragged: world angle it points to.
        public var arrow: (surfaceID: UUID, routingID: UUID, degrees: Double)?
        /// A rubber-band box, in screen points.
        public var marquee: CGRect?
        public var edits: [SurfaceEdit] = []
        public var undoName = ""
        /// Why the drag cannot be committed as it stands (shown in red). `nil` when it can.
        public var problem: String?
        public var isValid: Bool { problem == nil }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.placements == rhs.placements && lhs.drawn?.shape == rhs.drawn?.shape && lhs.drawn?.transform == rhs.drawn?.transform
                && lhs.arrow?.surfaceID == rhs.arrow?.surfaceID && lhs.arrow?.routingID == rhs.arrow?.routingID && lhs.arrow?.degrees == rhs.arrow?.degrees
                && lhs.marquee == rhs.marquee && lhs.edits == rhs.edits && lhs.undoName == rhs.undoName && lhs.problem == rhs.problem
        }
    }

    public let kind: Kind
    /// The geometry the drag started in. Zoom and pan during a drag change nothing of its meaning.
    public let space: SurfaceCanvasSpace
    public let startScreen: CGPoint
    public let start: SurfacePoint
    public private(set) var currentScreen: CGPoint
    public private(set) var current: SurfacePoint
    public private(set) var modifiers: SurfaceModifiers
    /// The selected surfaces as they were when the drag began, in document order.
    public let originals: [SpatialSurface]
    /// The layer a drawn surface goes into.
    public let layerID: UUID?

    /// A press that never moved this far is a click, not a drag.
    public static let dragThreshold: CGFloat = 3
    public var isDrag: Bool { hypot(currentScreen.x - startScreen.x, currentScreen.y - startScreen.y) >= Self.dragThreshold }

    public init(kind: Kind, space: SurfaceCanvasSpace, startScreen: CGPoint, start: SurfacePoint,
                originals: [SpatialSurface], layerID: UUID? = nil, modifiers: SurfaceModifiers = []) {
        self.kind = kind; self.space = space; self.startScreen = startScreen; self.start = start
        currentScreen = startScreen; current = start; self.modifiers = modifiers
        self.originals = originals; self.layerID = layerID
    }

    @discardableResult
    public mutating func update(toScreen screen: CGPoint, modifiers: SurfaceModifiers) -> Bool {
        guard screen.x.isFinite, screen.y.isFinite, let world = space.world(screen) else { return false }
        currentScreen = screen; current = world; self.modifiers = modifiers
        return true
    }

    // MARK: Why a selection cannot be moved, turned or scaled

    public static func moveRefusal(_ surfaces: [SpatialSurface]) -> String? {
        for surface in surfaces {
            if surface.isLegacyMask { return "An exact area from an older preset is shifted by whole cells in the inspector" }
            if case .shape(.ringSector, _) = surface.form { return "A ring sector stays centred on the scanner; change its radii and bearings" }
        }
        return nil
    }

    // MARK: Evaluation

    public func evaluate() -> Result {
        var result = Result()
        let ids = originals.map(\.id)
        switch kind {
        case .marquee:
            result.marquee = CGRect(x: min(startScreen.x, currentScreen.x), y: min(startScreen.y, currentScreen.y),
                                    width: abs(currentScreen.x - startScreen.x), height: abs(currentScreen.y - startScreen.y))

        case .draw(let tool):
            drawing(tool, into: &result)

        case .move:
            var dx = current.x - start.x, dy = current.y - start.y
            if modifiers.contains(.shift) { if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 } }
            let edit = SurfaceEdit.moveSurfaces(ids: ids, dxCm: SurfaceTidy.centimeters(dx), dyCm: SurfaceTidy.centimeters(dy))
            result.undoName = edit.undoName
            place(edit, into: &result)

        case .rotate(let pivot, let startAngle):
            var degrees = SurfaceFrame.angleDegrees(from: pivot, to: current) - startAngle
            degrees = SurfaceAxis.normalized(degrees)
            degrees = modifiers.contains(.shift) ? (degrees / 15).rounded() * 15 : SurfaceTidy.degrees(degrees)
            let edit = SurfaceEdit.rotateSurfaces(ids: ids, degrees: degrees, aroundXCm: SurfaceTidy.centimeters(pivot.x), aroundYCm: SurfaceTidy.centimeters(pivot.y))
            result.undoName = edit.undoName
            place(edit, into: &result)

        case .handle(let handle):
            resizing(handle, into: &result)
        }
        return result
    }

    private func place(_ edit: SurfaceEdit, into result: inout Result) {
        result.edits = [edit]
        do {
            for surface in originals {
                if let placement = try SurfaceEditor.placement(of: surface, after: edit) { result.placements[surface.id] = placement }
            }
        } catch let error as SurfaceEditError { result.problem = error.userMessage; result.edits = [] }
        catch { result.problem = "Surface edit rejected"; result.edits = [] }
        checkShapes(&result)
    }

    /// An edit that would leave a shape unusable is shown as such; the commit would be refused anyway.
    private func checkShapes(_ result: inout Result) {
        guard result.problem == nil else { return }
        for (_, placement) in result.placements {
            if let text = SurfaceProblemText.text(placement.shape.problems(transform: placement.transform)) { result.problem = text; result.edits = []; return }
        }
    }

    private func drawing(_ tool: SurfaceTool, into result: inout Result) {
        let dx = current.x - start.x, dy = current.y - start.y
        switch tool {
        case .rectangle:
            var halfX = abs(dx) / 2, halfY = abs(dy) / 2
            var centre = SurfacePoint(x: (start.x + current.x) / 2, y: (start.y + current.y) / 2)
            if modifiers.contains(.shift) { let side = max(halfX, halfY); halfX = side; halfY = side
                centre = SurfacePoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side)) }
            if modifiers.contains(.option) {
                halfX = abs(dx); halfY = abs(dy)
                if modifiers.contains(.shift) { halfX = max(halfX, halfY); halfY = halfX }
                centre = start
            }
            let shape = SurfaceShape.rectangle(widthCm: SurfaceTidy.centimeters(halfX * 2), heightCm: SurfaceTidy.centimeters(halfY * 2))
            let transform = SurfaceTransform(xCm: SurfaceTidy.centimeters(centre.x), yCm: SurfaceTidy.centimeters(centre.y))
            result.drawn = (shape, transform)
            result.undoName = "Add surface"
            result.problem = SurfaceProblemText.text(shape.problems(transform: transform))
        case .circle:
            let shape = SurfaceShape.circle(radiusCm: SurfaceTidy.centimeters(hypot(dx, dy)))
            let transform = SurfaceTransform(xCm: SurfaceTidy.centimeters(start.x), yCm: SurfaceTidy.centimeters(start.y))
            result.drawn = (shape, transform)
            result.undoName = "Add surface"
            result.problem = SurfaceProblemText.text(shape.problems(transform: transform))
        case .ringSector:
            let r0 = hypot(start.x, max(0, start.y)), r1 = hypot(current.x, max(0, current.y))
            let b0 = SurfaceFrame.bearingDegrees(start), b1 = SurfaceFrame.bearingDegrees(current)
            let shape = Self.sector(r0, r1, b0, b1)
            result.drawn = (shape, .identity)
            result.undoName = "Add surface"
            result.problem = SurfaceProblemText.text(shape.problems(transform: .identity))
        case .select, .polygon: break
        }
    }

    /// Radii to whole centimetres, bearings to the 0.5° of the measuring grid.
    static func sector(_ r0: Double, _ r1: Double, _ b0: Double, _ b1: Double) -> SurfaceShape {
        let a = min(r0, r1).rounded(), b = max(r0, r1).rounded()
        let c = (min(b0, b1) * 2).rounded() / 2, d = (max(b0, b1) * 2).rounded() / 2
        return .ringSector(fromCm: a, toCm: b, fromDegrees: max(c, -90), toDegrees: min(d, 90))
    }


    /// Extents (in the rectangle's own frame) after dragging a corner or an edge to `pointer`. The
    /// opposite corner or edge stays; ⌥ keeps the middle instead, ⇧ keeps the proportions of a corner.
    static func resizedRectangle(width w: Double, height h: Double, signX sx: Int, signY sy: Int, pointer p: SurfacePoint,
                                 modifiers: SurfaceModifiers) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let fromCentre = modifiers.contains(.option)
        var minX = -w / 2, maxX = w / 2, minY = -h / 2, maxY = h / 2
        if modifiers.contains(.shift), sx != 0, sy != 0, w > 0, h > 0 {
            if fromCentre {
                let k = max(abs(p.x) / (w / 2), abs(p.y) / (h / 2))
                return (-k * w / 2, k * w / 2, -k * h / 2, k * h / 2)
            }
            let fixedX = sx > 0 ? -w / 2 : w / 2, fixedY = sy > 0 ? -h / 2 : h / 2
            let dx = p.x - fixedX, dy = p.y - fixedY
            let k = max(abs(dx) / w, abs(dy) / h)
            let x2 = fixedX + (dx >= 0 ? 1 : -1) * k * w, y2 = fixedY + (dy >= 0 ? 1 : -1) * k * h
            return (min(fixedX, x2), max(fixedX, x2), min(fixedY, y2), max(fixedY, y2))
        }
        if sx != 0 {
            if fromCentre { minX = -abs(p.x); maxX = abs(p.x) }
            else { let fixed = sx > 0 ? -w / 2 : w / 2; minX = min(fixed, p.x); maxX = max(fixed, p.x) }
        }
        if sy != 0 {
            if fromCentre { minY = -abs(p.y); maxY = abs(p.y) }
            else { let fixed = sy > 0 ? -h / 2 : h / 2; minY = min(fixed, p.y); maxY = max(fixed, p.y) }
        }
        return (minX, maxX, minY, maxY)
    }

    /// The pointer as the handle's own point: a handle is drawn and grabbed a little off its true place
    /// (outside the box, or pushed in from the edge of the canvas). The distance between the press and that
    /// place is kept, so the first movement of a drag is continuous and an unmoved press changes nothing.
    private func grabbed(by anchor: SurfacePoint) -> SurfacePoint {
        SurfacePoint(x: current.x + anchor.x - start.x, y: current.y + anchor.y - start.y)
    }

    private func resizing(_ handle: SurfaceHandleKind, into result: inout Result) {
        switch handle {
        case .rectCorner(let sx, let sy), .rectEdge(let sx, let sy):
            guard let surface = originals.first, case .shape(.rectangle(let w, let h), let t) = surface.form else { return }
            let anchor = SurfaceFrame.world(.init(x: Double(sx) * w / 2, y: Double(sy) * h / 2), t)
            let p = SurfaceFrame.local(grabbed(by: anchor), t)
            let (minX, maxX, minY, maxY) = Self.resizedRectangle(width: w, height: h, signX: sx, signY: sy, pointer: p, modifiers: modifiers)
            let centre = SurfaceFrame.world(.init(x: (minX + maxX) / 2, y: (minY + maxY) / 2), t)
            var next = t
            next.xCm = SurfaceTidy.centimeters(centre.x); next.yCm = SurfaceTidy.centimeters(centre.y)
            let edit = SurfaceEdit.resizeSurface(id: surface.id, shape: .rectangle(widthCm: SurfaceTidy.centimeters(maxX - minX), heightCm: SurfaceTidy.centimeters(maxY - minY)), transform: next)
            result.undoName = edit.undoName
            place(edit, into: &result)

        case .circleRadius(let index):
            guard let surface = originals.first, case .shape(.circle(let r), let t) = surface.form else { return }
            let (s, c) = SurfaceTrig.sinCos(degrees: Double(index) * 90)
            let pointer = grabbed(by: SurfacePoint(x: t.xCm + r * c, y: t.yCm + r * s))
            let edit = SurfaceEdit.resizeSurface(id: surface.id, shape: .circle(radiusCm: SurfaceTidy.centimeters(hypot(pointer.x - t.xCm, pointer.y - t.yCm))), transform: t)
            result.undoName = edit.undoName
            place(edit, into: &result)

        case .polygonPoint(let index):
            guard let surface = originals.first, case .shape(.polygon(let points), let t) = surface.form, points.indices.contains(index) else { return }
            let pointer = grabbed(by: SurfaceFrame.world(points[index], t))
            let edit = SurfaceEdit.movePolygonPoint(id: surface.id, index: index, to: SurfaceTidy.point(SurfaceFrame.local(pointer, t)))
            result.undoName = edit.undoName
            place(edit, into: &result)

        case .frameCorner(let sx, let sy):
            if let reason = Self.scaleRefusal(originals) { result.problem = reason; return }
            let bounds = originals.dropFirst().reduce(originals[0].worldBounds) { $0.union($1.worldBounds) }
            let corner = SurfacePoint(x: sx > 0 ? bounds.maxX : bounds.minX, y: sy > 0 ? bounds.maxY : bounds.minY)
            let anchor = modifiers.contains(.option)
                ? SurfacePoint(x: (bounds.minX + bounds.maxX) / 2, y: (bounds.minY + bounds.maxY) / 2)
                : SurfacePoint(x: sx > 0 ? bounds.minX : bounds.maxX, y: sy > 0 ? bounds.minY : bounds.maxY)
            let vx = corner.x - anchor.x, vy = corner.y - anchor.y, length2 = vx * vx + vy * vy
            guard length2 > 1e-9 else { result.problem = "The surface has no size to scale"; return }
            let pointer = grabbed(by: corner)
            let k = ((pointer.x - anchor.x) * vx + (pointer.y - anchor.y) * vy) / length2
            guard k.isFinite, k >= 0.05 else { result.problem = "Too small"; return }
            var edits: [SurfaceEdit] = []
            for surface in originals {
                guard case .shape(let shape, let t) = surface.form else { continue }
                var next = t
                next.xCm = SurfaceTidy.centimeters(anchor.x + k * (t.xCm - anchor.x))
                next.yCm = SurfaceTidy.centimeters(anchor.y + k * (t.yCm - anchor.y))
                let scaled: SurfaceShape
                switch shape {
                case .rectangle(let w, let h): scaled = .rectangle(widthCm: SurfaceTidy.centimeters(w * k), heightCm: SurfaceTidy.centimeters(h * k))
                case .circle(let r): scaled = .circle(radiusCm: SurfaceTidy.centimeters(r * k))
                case .polygon(let points): scaled = .polygon(pointsCm: points.map { SurfacePoint(x: SurfaceTidy.centimeters($0.x * k), y: SurfaceTidy.centimeters($0.y * k)) })
                case .ringSector: result.problem = Self.scaleRefusal(originals); return
                }
                edits.append(.resizeSurface(id: surface.id, shape: scaled, transform: next))
            }
            result.undoName = "Scale surfaces"
            do {
                for edit in edits { for surface in originals { if let p = try SurfaceEditor.placement(of: surface, after: edit) { result.placements[surface.id] = p } } }
                result.edits = edits
            } catch let error as SurfaceEditError { result.problem = error.userMessage } catch { result.problem = "Surface edit rejected" }
            checkShapes(&result)

        case .rotate:
            break // turning has its own gesture kind

        case .sectorInner, .sectorOuter, .sectorStart, .sectorEnd, .sectorInnerStart, .sectorInnerEnd, .sectorOuterStart, .sectorOuterEnd:
            guard let surface = originals.first, case .shape(.ringSector(let from, let to, let fromDegrees, let toDegrees), _) = surface.form else { return }
            // The handles stand outside the sector; radius and bearing follow the pointer's movement from the press.
            let moved = hypot(current.x, max(0, current.y)) - hypot(start.x, max(0, start.y))
            let turned = SurfaceFrame.bearingDegrees(current) - SurfaceFrame.bearingDegrees(start)
            var r0 = from, r1 = to, b0 = fromDegrees, b1 = toDegrees
            switch handle {
            case .sectorInner, .sectorInnerStart, .sectorInnerEnd: r0 = from + moved
            default: break
            }
            switch handle {
            case .sectorOuter, .sectorOuterStart, .sectorOuterEnd: r1 = to + moved
            default: break
            }
            switch handle {
            case .sectorStart, .sectorInnerStart, .sectorOuterStart: b0 = fromDegrees + turned
            default: break
            }
            switch handle {
            case .sectorEnd, .sectorInnerEnd, .sectorOuterEnd: b1 = toDegrees + turned
            default: break
            }
            let shape = Self.sector(r0, r1, b0, b1)
            let edit = SurfaceEdit.resizeSurface(id: surface.id, shape: shape, transform: .identity)
            result.undoName = edit.undoName
            place(edit, into: &result)

        case .axisTip(let routingID):
            guard let surface = originals.first, let routing = surface.materializedRoutings().first(where: { $0.id == routingID }),
                  SurfaceAxis.directionDegrees(of: routing.program) != nil else { return }
            let bounds = surface.worldBounds
            let centre = SurfacePoint(x: (bounds.minX + bounds.maxX) / 2, y: (bounds.minY + bounds.maxY) / 2)
            var arrow = SurfaceFrame.angleDegrees(from: centre, to: current)
            arrow = modifiers.contains(.shift) ? (arrow / 15).rounded() * 15 : arrow.rounded()
            arrow = SurfaceAxis.normalized(arrow)
            // The edit stores the program's own angle; the arrow points half a turn away from it when the value rises against it.
            let programAngle = SurfaceAxis.risesAgainstDirection(routing.program) ? SurfaceAxis.normalized(arrow + 180) : arrow
            let edit = SurfaceEdit.setAxis(surfaceID: surface.id, routingID: routingID, worldDegrees: programAngle)
            result.arrow = (surface.id, routingID, arrow)
            result.edits = [edit]
            result.undoName = edit.undoName
        }
    }

    /// Why a selection cannot be scaled (or turned) as one box.
    public static func scaleRefusal(_ surfaces: [SpatialSurface]) -> String? {
        for surface in surfaces {
            if surface.isLegacyMask { return "An exact area from an older preset cannot be scaled or turned together with other surfaces" }
            if case .shape(.ringSector, _) = surface.form { return "A ring sector stays centred on the scanner; change its radii and bearings" }
        }
        return nil
    }
}
