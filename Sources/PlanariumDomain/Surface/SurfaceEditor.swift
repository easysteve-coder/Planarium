import Foundation
import PLSDeviceValues

/// A new surface as the user draws it. The cells follow from the shape; they are never part of the draft.
public struct SurfaceDraft: Equatable, Sendable {
    public var id: UUID
    public var presentation: SpatialSurface.Presentation
    public var shape: SurfaceShape
    public var transform: SurfaceTransform
    public var routings: [SpatialRouting]
    public init(id: UUID = UUID(), presentation: SpatialSurface.Presentation, shape: SurfaceShape,
                transform: SurfaceTransform = .identity, routings: [SpatialRouting] = []) {
        self.id = id; self.presentation = presentation; self.shape = shape; self.transform = transform; self.routings = routings
    }
}

/// Shape and placement of a surface after a geometric edit, plus the assignments that must change with it.
public struct SurfacePlacement: Equatable, Sendable {
    public var shape: SurfaceShape
    public var transform: SurfaceTransform
    /// Set only when the edit rewrites the axis together with the placement (mirroring a ring sector).
    public var routings: [SpatialRouting]?
    public init(shape: SurfaceShape, transform: SurfaceTransform, routings: [SpatialRouting]? = nil) {
        self.shape = shape; self.transform = transform; self.routings = routings
    }
}

/// One user action on surfaces, applied to a document as a whole or not at all.
public enum SurfaceEdit: Equatable, Sendable {
    // Creating and removing
    case addSurface(layerID: UUID, SurfaceDraft)
    /// Copies in the same layer with new identities, moved by the offset (a ring sector and a mask stay in place).
    case duplicateSurfaces(ids: [UUID], dxCm: Double, dyCm: Double)
    case deleteSurfaces(ids: [UUID])
    // Placement of shaped surfaces
    case moveSurfaces(ids: [UUID], dxCm: Double, dyCm: Double)
    /// Counter-clockwise about a world point.
    case rotateSurfaces(ids: [UUID], degrees: Double, aroundXCm: Double, aroundYCm: Double)
    /// Mirror left/right about the vertical world line x = `aboutXCm`.
    case mirrorSurfaces(ids: [UUID], aboutXCm: Double)
    case setTransform(id: UUID, SurfaceTransform)
    /// New size, with the placement that goes with it.
    case resizeSurface(id: UUID, shape: SurfaceShape, transform: SurfaceTransform)
    /// A polygon corner, in the surface's own frame.
    case movePolygonPoint(id: UUID, index: Int, to: SurfacePoint)
    // Assignment and axis
    case setRoutings(surfaceID: UUID, routings: [SpatialRouting])
    /// Drag the axis to a world angle (program convention); stored in the surface's own frame.
    case setAxis(surfaceID: UUID, routingID: UUID, worldDegrees: Double)
    case reverseAxis(surfaceID: UUID, routingID: UUID)
    case setValueRange(surfaceID: UUID, routingID: UUID, minimum: Double, maximum: Double)
    case setPresentation(surfaceID: UUID, SpatialSurface.Presentation)
    // Document settings
    case setSurfaceSettings(SurfaceSettings)
    // Existing layers
    /// A layer made of cells becomes one exact-mask surface; identities, assignments and overrides stay.
    case promoteLayer(layerID: UUID)
    /// Replace an exact mask by a shape. Cells and per-cell values of the mask are dropped.
    case replaceMaskWithShape(surfaceID: UUID, shape: SurfaceShape, transform: SurfaceTransform)
    /// Turn an exact mask about the scanner by whole ticks (0.5° each).
    case rotateMask(surfaceID: UUID, ticks: Int)
    case mirrorMask(surfaceID: UUID)
    /// Move an exact mask away from or toward the scanner by whole rings (1 cm each).
    case shiftMask(surfaceID: UUID, rings: Int)

    /// Menu title of the undo step.
    public var undoName: String {
        switch self {
        case .addSurface: return "Add surface"
        case .duplicateSurfaces: return "Duplicate surfaces"
        case .deleteSurfaces: return "Delete surfaces"
        case .moveSurfaces: return "Move surfaces"
        case .rotateSurfaces: return "Rotate surfaces"
        case .mirrorSurfaces: return "Mirror surfaces"
        case .setTransform: return "Place surface"
        case .resizeSurface: return "Resize surface"
        case .movePolygonPoint: return "Move point"
        case .setRoutings: return "Assignment"
        case .setAxis, .reverseAxis: return "Value axis"
        case .setValueRange: return "Value range"
        case .setPresentation: return "Surface look"
        case .setSurfaceSettings: return "Play area"
        case .promoteLayer: return "Convert layer to surface"
        case .replaceMaskWithShape: return "Replace mask by shape"
        case .rotateMask: return "Rotate mask"
        case .mirrorMask: return "Mirror mask"
        case .shiftMask: return "Shift mask"
        }
    }

    /// Edits of this kind may share one undo step, but only inside a series the caller opened
    /// explicitly (a drag, a nudge burst); without one every edit is its own step.
    public var coalescingKey: String? {
        switch self {
        case .moveSurfaces(let ids, _, _): return "move:" + ids.map(\.uuidString).joined(separator: ",")
        case .rotateSurfaces(let ids, _, _, _): return "rotate:" + ids.map(\.uuidString).joined(separator: ",")
        case .setTransform(let id, _): return "place:" + id.uuidString
        case .resizeSurface(let id, _, _): return "resize:" + id.uuidString
        case .movePolygonPoint(let id, let index, _): return "point:\(id):\(index)"
        case .setAxis(let id, let routing, _): return "axis:\(id):\(routing)"
        case .setValueRange(let id, let routing, _, _): return "range:\(id):\(routing)"
        default: return nil
        }
    }
}

public enum SurfaceEditError: Error, Equatable, Sendable {
    case unknownLayer(UUID)
    case unknownSurface(UUID)
    case unknownRouting(UUID)
    case layerLocked(UUID)
    case emptySelection
    /// A number is not finite or beyond any sensible size.
    case invalidNumber
    /// The layer still has its own cells or assignments; convert it to a surface first.
    case layerHasOwnContent(UUID)
    case alreadySurfaceBacked(UUID)
    /// The operation moves or turns a shape; an exact mask can only be turned, mirrored or shifted on the grid.
    case notAShapedSurface(UUID)
    case notAnExactMask(UUID)
    /// A ring sector is centred on the scanner: it can be resized, and mirrored about the scanner axis.
    case ringSectorCannotBePlaced(UUID)
    /// A resize keeps the kind of frame: placeable shape stays placeable, ring sector stays ring sector.
    case resizeCannotChangeFrame(UUID)
    case notAPolygon(UUID)
    case pointIndexOutOfRange(Int)
    case routingHasNoAxis(UUID)
    /// A whole-grid operation would push a cell off the grid (nothing is changed).
    case maskWouldLeaveTheGrid(UUID)
    case derivation(surfaceID: UUID, SurfaceDerivationError)
    case document(SpatialDocumentError)
    case invalidSettings
    /// An assignment holds a value the instrument cannot compile (not finite, out of range, duplicate routing).
    case invalidAssignment(CompiledInstrumentError)
}

/// The pure part of editing surfaces: a document in, the next document out, or an error and nothing.
/// Window, canvas and gestures never touch a document except through this and the document owner.
public enum SurfaceEditor {
    public static func apply(_ edit: SurfaceEdit, to document: InstrumentDocument) throws -> InstrumentDocument {
        var next = document
        var spatial = document.spatial
        switch edit {
        case .setSurfaceSettings(let settings):
            guard settings.problems().isEmpty else { throw SurfaceEditError.invalidSettings }
            // Every shaped surface is derived again under the new play area; if one cannot be, nothing changes.
            let layers = try spatial.layers.map { layer -> SpatialDocumentLayer in
                guard layer.isSurfaceBacked else { return layer }
                return layer.replacing(surfaces: try layer.surfaces.map { surface in
                    guard !surface.isLegacyMask else { return surface }
                    do { return try surface.rederived(under: settings) }
                    catch let error as SurfaceDerivationError { throw SurfaceEditError.derivation(surfaceID: surface.id, error) }
                })
            }
            do { spatial = try spatial.replacingLayers(layers, surfaceSettings: settings) }
            catch let error as SpatialDocumentError { throw SurfaceEditError.document(error) }
        default:
            var layers = spatial.layers
            try applyToLayers(edit, &layers, settings: spatial.surfaceSettings)
            do { spatial = try spatial.replacingLayers(layers) }
            catch let error as SpatialDocumentError { throw SurfaceEditError.document(error) }
        }
        do { try SpatialInstrumentCompiler.validate(spatial) }
        catch let error as CompiledInstrumentError { throw SurfaceEditError.invalidAssignment(error) }
        next.spatial = spatial
        return next
    }

    // MARK: Layer level

    private static func applyToLayers(_ edit: SurfaceEdit, _ layers: inout [SpatialDocumentLayer], settings: SurfaceSettings) throws {
        switch edit {
        case .addSurface(let layerID, let draft):
            let index = try layerIndex(layerID, in: layers)
            let layer = layers[index]
            try requireUnlocked(layer)
            guard layer.isSurfaceBacked || (layer.cells.isEmpty && layer.routings.isEmpty && layer.cellOverrides.isEmpty) else {
                throw SurfaceEditError.layerHasOwnContent(layerID)
            }
            try number(draft.transform.xCm, draft.transform.yCm, draft.transform.rotationDegrees)
            let surface = try makeSurface(id: draft.id, presentation: draft.presentation, shape: draft.shape, transform: draft.transform,
                                          routings: draft.routings, settings: settings)
            layers[index] = layer.replacing(surfaces: layer.surfaces + [surface])

        case .deleteSurfaces(let ids):
            try transformSurfaces(ids, &layers) { _ in nil }

        case .duplicateSurfaces(let ids, let dx, let dy):
            try number(dx, dy)
            try transformSurfaces(ids, &layers, duplicate: true) { surface in
                var copy = surface.copying(retargeting: { $0 }, value: { $0 })
                copy = copy.replacingPresentation(.init(name: surface.presentation.name + " copy", color: surface.presentation.color, valueColors: surface.presentation.valueColors))
                guard case .shape(let shape, var transform) = copy.form, !isRingSector(shape), dx != 0 || dy != 0 else { return copy }
                transform.xCm += dx; transform.yCm += dy
                return try rebuilt(copy, shape: shape, transform: transform, settings: settings)
            }

        case .moveSurfaces(let ids, let dx, let dy):
            try number(dx, dy)
            try transformSurfaces(ids, &layers) { try replacingPlacement($0, after: edit, settings: settings) }

        case .rotateSurfaces(let ids, let degrees, let px, let py):
            try number(degrees, px, py)
            try transformSurfaces(ids, &layers) { try replacingPlacement($0, after: edit, settings: settings) }

        case .mirrorSurfaces(let ids, let c):
            try number(c)
            try transformSurfaces(ids, &layers) { try replacingPlacement($0, after: edit, settings: settings) }

        case .setTransform(let id, let transform):
            try number(transform.xCm, transform.yCm, transform.rotationDegrees)
            try transformSurfaces([id], &layers) { try replacingPlacement($0, after: edit, settings: settings) }

        case .resizeSurface(let id, _, let transform):
            try number(transform.xCm, transform.yCm, transform.rotationDegrees)
            try transformSurfaces([id], &layers) { try replacingPlacement($0, after: edit, settings: settings) }

        case .movePolygonPoint(let id, _, let point):
            try number(point.x, point.y)
            try transformSurfaces([id], &layers) { try replacingPlacement($0, after: edit, settings: settings) }

        case .setRoutings(let surfaceID, let routings):
            try transformSurfaces([surfaceID], &layers) { $0.replacing(routings: routings) }

        case .setAxis(let surfaceID, let routingID, let world):
            try number(world)
            try transformSurfaces([surfaceID], &layers) { surface in
                try replacingRouting(routingID, in: surface) { routing in
                    guard SurfaceAxis.directionDegrees(of: routing.program) != nil else { throw SurfaceEditError.routingHasNoAxis(routingID) }
                    let transform = isRingSectorSurface(surface) ? SurfaceTransform.identity : surface.transform
                    routing.program = SurfaceAxis.replacingDirection(of: routing.program, with: SurfaceAxis.localDegrees(world: world, transform: transform))
                }
            }

        case .reverseAxis(let surfaceID, let routingID):
            try transformSurfaces([surfaceID], &layers) { surface in
                try replacingRouting(routingID, in: surface) { routing in
                    guard SurfaceAxis.directionDegrees(of: routing.program) != nil else { throw SurfaceEditError.routingHasNoAxis(routingID) }
                    routing.program = SurfaceAxis.reversed(routing.program)
                }
            }

        case .setValueRange(let surfaceID, let routingID, let minimum, let maximum):
            try number(minimum, maximum)
            try transformSurfaces([surfaceID], &layers) { surface in
                try replacingRouting(routingID, in: surface) { routing in
                    guard case .continuous(_, _, let degrees, let curve) = routing.program else { throw SurfaceEditError.routingHasNoAxis(routingID) }
                    routing.program = .continuous(minimum: minimum, maximum: maximum, directionDegrees: degrees, curve: curve)
                }
            }

        case .setPresentation(let surfaceID, let presentation):
            try transformSurfaces([surfaceID], &layers, requiresUnlocked: false) { $0.replacingPresentation(presentation) }

        case .promoteLayer(let layerID):
            let index = try layerIndex(layerID, in: layers)
            let layer = layers[index]
            try requireUnlocked(layer)
            guard !layer.isSurfaceBacked else { throw SurfaceEditError.alreadySurfaceBacked(layerID) }
            let surface = SpatialSurface(id: layer.id, presentation: .init(name: layer.name, color: layer.color),
                                         form: .legacyMask(LegacyMask(cells: layer.cells, cellOverrides: layer.cellOverrides)),
                                         routings: layer.routings, settings: .standard,
                                         derivation: SurfaceRasterizer.derive(maskCells: layer.cells))
            layers[index] = SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color, isVisible: layer.isVisible,
                isActive: layer.isActive, isLocked: layer.isLocked, isSoloed: layer.isSoloed, cells: [], routings: [], cellOverrides: [:],
                toggleGuardSeconds: layer.toggleGuardSeconds, commonNotes: layer.commonNotes, midiTarget: layer.midiTarget, surfaces: [surface])

        case .replaceMaskWithShape(let surfaceID, let shape, let transform):
            try number(transform.xCm, transform.yCm, transform.rotationDegrees)
            try transformSurfaces([surfaceID], &layers) { surface in
                guard surface.isLegacyMask else { throw SurfaceEditError.notAnExactMask(surfaceID) }
                // The mask's axis angles are world angles; the shape stores them in its own frame, audibly unchanged.
                let frame = isRingSector(shape) ? SurfaceTransform.identity : transform
                let routings = surface.routings.map { routing -> SpatialRouting in
                    var routing = routing
                    if let d = SurfaceAxis.directionDegrees(of: routing.program) {
                        routing.program = SurfaceAxis.replacingDirection(of: routing.program, with: SurfaceAxis.localDegrees(world: d, transform: frame))
                    }
                    return routing
                }
                return try makeSurface(id: surface.id, presentation: surface.presentation, shape: shape, transform: transform, routings: routings, settings: settings)
            }

        case .rotateMask(let surfaceID, let ticks):
            // A turn of more than the whole grid cannot keep any cell on it; the axis angle of an
            // (empty) mask must not absorb an absurd count either.
            guard ticks.magnitude <= UInt(PolarDeviceLattice.maxTick) else { throw SurfaceEditError.invalidNumber }
            try transformSurfaces([surfaceID], &layers) { surface in
                try remapMask(surface, tick: { checkedSum($0, ticks) }, ring: { $0 },
                              angle: { SurfaceAxis.normalized($0 - Double(ticks) * 0.5) })
            }
        case .mirrorMask(let surfaceID):
            try transformSurfaces([surfaceID], &layers) { surface in
                try remapMask(surface, tick: { PolarDeviceLattice.maxTick - $0 }, ring: { $0 },
                              angle: { SurfaceAxis.normalized(180 - $0) })
            }
        case .shiftMask(let surfaceID, let rings):
            try transformSurfaces([surfaceID], &layers) { surface in
                try remapMask(surface, tick: { $0 }, ring: { checkedSum($0, rings) }, angle: { $0 })
            }

        case .setSurfaceSettings:
            break // handled by the caller: it re-derives the whole document
        }
    }


    // MARK: Placement (shared by the edit and by the canvas preview)

    /// The shape and placement a geometric edit gives one surface, without deriving cells. The edit
    /// itself and the canvas preview of a drag both read this, so a preview cannot differ from the
    /// result. `nil` when the edit does not place this surface (another surface, or no geometry).
    public static func placement(of surface: SpatialSurface, after edit: SurfaceEdit) throws -> SurfacePlacement? {
        switch edit {
        case .moveSurfaces(let ids, let dx, let dy):
            guard ids.contains(surface.id) else { return nil }
            let (shape, transform) = try placed(surface)
            guard !isRingSector(shape) else { throw SurfaceEditError.ringSectorCannotBePlaced(surface.id) }
            var moved = transform; moved.xCm += dx; moved.yCm += dy
            return SurfacePlacement(shape: shape, transform: moved)

        case .rotateSurfaces(let ids, let degrees, let px, let py):
            guard ids.contains(surface.id) else { return nil }
            let (s, c) = SurfaceTrig.sinCos(degrees: degrees)
            let (shape, transform) = try placed(surface)
            guard !isRingSector(shape) else { throw SurfaceEditError.ringSectorCannotBePlaced(surface.id) }
            var turned = transform
            let ox = transform.xCm - px, oy = transform.yCm - py
            turned.xCm = c * ox - s * oy + px
            turned.yCm = s * ox + c * oy + py
            turned.rotationDegrees = SurfaceAxis.normalized(transform.rotationDegrees + degrees)
            return SurfacePlacement(shape: shape, transform: turned)

        case .mirrorSurfaces(let ids, let c):
            guard ids.contains(surface.id) else { return nil }
            let (shape, transform) = try placed(surface)
            if case .ringSector(let from, let to, let fromDegrees, let toDegrees) = shape {
                // Only about the scanner's own axis; the window flips and the axis angles flip with it.
                guard c == 0 else { throw SurfaceEditError.ringSectorCannotBePlaced(surface.id) }
                let mirrored = SurfaceShape.ringSector(fromCm: from, toCm: to, fromDegrees: -toDegrees, toDegrees: -fromDegrees)
                let routings = surface.routings.map { routing -> SpatialRouting in
                    var routing = routing
                    if let d = SurfaceAxis.directionDegrees(of: routing.program) {
                        routing.program = SurfaceAxis.replacingDirection(of: routing.program, with: SurfaceAxis.normalized(180 - d))
                    }
                    return routing
                }
                return SurfacePlacement(shape: mirrored, transform: .identity, routings: routings)
            }
            var mirrored = transform
            mirrored.xCm = 2 * c - transform.xCm
            mirrored.rotationDegrees = SurfaceAxis.normalized(0 - transform.rotationDegrees)
            mirrored.mirrorX = !transform.mirrorX
            return SurfacePlacement(shape: shape, transform: mirrored)

        case .setTransform(let id, let transform):
            guard id == surface.id else { return nil }
            let (shape, _) = try placed(surface)
            guard !isRingSector(shape) else { throw SurfaceEditError.ringSectorCannotBePlaced(surface.id) }
            return SurfacePlacement(shape: shape, transform: transform)

        case .resizeSurface(let id, let shape, let transform):
            guard id == surface.id else { return nil }
            let (current, _) = try placed(surface)
            // The axis is stored in the surface's own frame: a placeable shape has a local frame,
            // a ring sector is centred on the scanner (local = world). Changing between the two
            // would read the same angle in another frame; that needs an explicit conversion.
            guard isRingSector(current) == isRingSector(shape) else { throw SurfaceEditError.resizeCannotChangeFrame(surface.id) }
            // A ring sector cannot be placed: a placement offered with it is refused, never turned into identity.
            if isRingSector(shape), transform != .identity { throw SurfaceEditError.ringSectorCannotBePlaced(surface.id) }
            return SurfacePlacement(shape: shape, transform: transform)

        case .movePolygonPoint(let id, let index, let point):
            guard id == surface.id else { return nil }
            let (shape, transform) = try placed(surface)
            guard case .polygon(var points) = shape else { throw SurfaceEditError.notAPolygon(surface.id) }
            guard points.indices.contains(index) else { throw SurfaceEditError.pointIndexOutOfRange(index) }
            points[index] = point
            return SurfacePlacement(shape: .polygon(pointsCm: points), transform: transform)

        default:
            return nil
        }
    }

    private static func replacingPlacement(_ surface: SpatialSurface, after edit: SurfaceEdit, settings: SurfaceSettings) throws -> SpatialSurface {
        guard let placement = try placement(of: surface, after: edit) else { return surface }
        return try rebuilt(surface, shape: placement.shape, transform: placement.transform, routings: placement.routings, settings: settings)
    }

    // MARK: Helpers

    private static func number(_ values: Double...) throws {
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 1e6 }) else { throw SurfaceEditError.invalidNumber }
    }
    /// A sum that is nil instead of trapping: an offset beyond the grid is a rejection, never a crash.
    private static func checkedSum(_ a: Int, _ b: Int) -> Int? {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : sum
    }
    private static func layerIndex(_ id: UUID, in layers: [SpatialDocumentLayer]) throws -> Int {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { throw SurfaceEditError.unknownLayer(id) }
        return index
    }
    private static func requireUnlocked(_ layer: SpatialDocumentLayer) throws {
        guard !layer.isLocked else { throw SurfaceEditError.layerLocked(layer.id) }
    }
    private static func isRingSector(_ shape: SurfaceShape) -> Bool { if case .ringSector = shape { return true }; return false }
    private static func isRingSectorSurface(_ surface: SpatialSurface) -> Bool {
        if case .shape(let shape, _) = surface.form { return isRingSector(shape) }
        return false
    }
    private static func placed(_ surface: SpatialSurface) throws -> (SurfaceShape, SurfaceTransform) {
        guard case .shape(let shape, let transform) = surface.form else { throw SurfaceEditError.notAShapedSurface(surface.id) }
        return (shape, transform)
    }
    private static func makeSurface(id: UUID, presentation: SpatialSurface.Presentation, shape: SurfaceShape, transform: SurfaceTransform,
                                    routings: [SpatialRouting], settings: SurfaceSettings) throws -> SpatialSurface {
        do { return try SpatialSurface(id: id, presentation: presentation, form: .shape(shape, transform), routings: routings, settings: settings) }
        catch let error as SurfaceDerivationError { throw SurfaceEditError.derivation(surfaceID: id, error) }
    }
    /// The same surface with another shape or placement; its authored axis (local frame) is untouched.
    private static func rebuilt(_ surface: SpatialSurface, shape: SurfaceShape, transform: SurfaceTransform,
                                routings: [SpatialRouting]? = nil, settings: SurfaceSettings) throws -> SpatialSurface {
        let kept = isRingSector(shape) ? SurfaceTransform.identity : transform
        return try makeSurface(id: surface.id, presentation: surface.presentation, shape: shape, transform: kept,
                               routings: routings ?? surface.routings, settings: settings)
    }
    private static func replacingRouting(_ id: UUID, in surface: SpatialSurface, _ change: (inout SpatialRouting) throws -> Void) throws -> SpatialSurface {
        guard let index = surface.routings.firstIndex(where: { $0.id == id }) else { throw SurfaceEditError.unknownRouting(id) }
        var routings = surface.routings
        try change(&routings[index])
        return surface.replacing(routings: routings)
    }

    /// Applies `change` to each named surface, in document order. `nil` removes the surface; with
    /// `duplicate` the result is inserted after the original instead of replacing it.
    private static func transformSurfaces(_ ids: [UUID], _ layers: inout [SpatialDocumentLayer], duplicate: Bool = false,
                                          requiresUnlocked: Bool = true, _ change: (SpatialSurface) throws -> SpatialSurface?) throws {
        guard !ids.isEmpty else { throw SurfaceEditError.emptySelection }
        let wanted = Set(ids)
        var found = Set<UUID>()
        for index in layers.indices {
            guard layers[index].surfaces.contains(where: { wanted.contains($0.id) }) else { continue }
            if requiresUnlocked { try requireUnlocked(layers[index]) }
            var result: [SpatialSurface] = []
            for surface in layers[index].surfaces {
                guard wanted.contains(surface.id) else { result.append(surface); continue }
                found.insert(surface.id)
                let changed = try change(surface)
                if duplicate { result.append(surface) }
                if let changed { result.append(changed) }
            }
            layers[index] = layers[index].replacing(surfaces: result)
        }
        if let missing = ids.first(where: { !found.contains($0) }) { throw SurfaceEditError.unknownSurface(missing) }
    }

    /// One all-or-nothing remap of an exact mask: every cell and every per-cell value moves, or none does.
    private static func remapMask(_ surface: SpatialSurface, tick: (Int) -> Int?, ring: (Int) -> Int?,
                                  angle: (Double) -> Double) throws -> SpatialSurface {
        guard case .legacyMask(let mask) = surface.form else { throw SurfaceEditError.notAnExactMask(surface.id) }
        func map(_ cell: PolarDeviceLattice) throws -> PolarDeviceLattice {
            guard let target = ring(cell.ring), target >= 1, let sector = tick(cell.sector),
                  let moved = PolarDeviceLattice(ring: target, sector: sector) else {
                throw SurfaceEditError.maskWouldLeaveTheGrid(surface.id)
            }
            return moved
        }
        var cells = Set<PolarDeviceLattice>(), overrides: [PolarDeviceLattice: [SpatialCellAction]] = [:]
        for cell in mask.cells { cells.insert(try map(cell)) }
        for (cell, actions) in mask.cellOverrides { overrides[try map(cell)] = actions }
        let routings = surface.routings.map { routing -> SpatialRouting in
            var routing = routing
            if let d = SurfaceAxis.directionDegrees(of: routing.program) {
                routing.program = SurfaceAxis.replacingDirection(of: routing.program, with: angle(d))
            }
            return routing
        }
        return SpatialSurface(id: surface.id, presentation: surface.presentation,
                              form: .legacyMask(LegacyMask(cells: cells, cellOverrides: overrides)), routings: routings,
                              settings: .standard, derivation: SurfaceRasterizer.derive(maskCells: cells))
    }

    /// A copy of a layer of surfaces below the original: new layer, surface and assignment identities,
    /// the same scenes, selected. (A layer of cells is copied by the cell editor, which cannot copy this.)
    public static func duplicatingLayer(_ layerID: UUID, in document: InstrumentDocument) throws -> InstrumentDocument {
        var layers = document.spatial.layers
        let index = try layerIndex(layerID, in: layers)
        let original = layers[index]
        let taken = Set(layers.map(\.name))
        var name = original.name + " copy", number = 2
        while taken.contains(name) { name = original.name + " copy \(number)"; number += 1 }
        // The copy releases itself, not the original: every reference to the original layer inside
        // it (assignment targets, per-cell targets and values) points at the new identity.
        // References to other layers stay.
        let newID = UUID()
        let copy = original.copying(newLayerID: newID, retargeting: { target in
            if case .releaseLayer(let id) = target, id == original.id { return .releaseLayer(layerID: newID) }
            return target
        }, value: { value in
            if case .releaseLayer(let id) = value, id == original.id { return .releaseLayer(layerID: newID) }
            return value
        }).renaming(name)
        layers.insert(copy, at: index + 1)
        var next = document
        do { next.spatial = try document.spatial.replacingLayers(layers, selectedLayerID: copy.id) }
        catch let error as SpatialDocumentError { throw SurfaceEditError.document(error) }
        for sceneIndex in next.scenes.indices where next.scenes[sceneIndex].activeLayerIDs.contains(original.id) {
            next.scenes[sceneIndex].activeLayerIDs.insert(copy.id)
        }
        do { try SpatialInstrumentCompiler.validate(next.spatial) }
        catch let error as CompiledInstrumentError { throw SurfaceEditError.invalidAssignment(error) }
        return next
    }

    /// What replacing an exact mask by a shape would drop, to show before the user confirms.
    public static func lossOfReplacingMask(surfaceID: UUID, in document: InstrumentDocument) -> (cells: Int, overrides: Int)? {
        for layer in document.spatial.layers {
            for surface in layer.surfaces where surface.id == surfaceID {
                if case .legacyMask(let mask) = surface.form { return (mask.cells.count, mask.cellOverrides.count) }
            }
        }
        return nil
    }
}
