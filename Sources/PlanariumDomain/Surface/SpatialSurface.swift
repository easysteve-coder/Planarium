import Foundation
import PLSDeviceValues

/// The exact cells and per-cell actions of an existing layer, taken over unchanged. Cells and
/// overrides are the primary data; no shape is guessed from them.
public struct LegacyMask: Equatable, Sendable {
    public let cells: Set<PolarDeviceLattice>
    public let cellOverrides: [PolarDeviceLattice: [SpatialCellAction]]
    public init(cells: Set<PolarDeviceLattice>, cellOverrides: [PolarDeviceLattice: [SpatialCellAction]] = [:]) {
        self.cells = cells; self.cellOverrides = cellOverrides
    }
}

/// The authored footprint of a surface. A shaped surface keeps its original shape and placement;
/// its cells are derived. A legacy mask keeps its cells.
public enum SurfaceForm: Equatable, Sendable {
    case shape(SurfaceShape, SurfaceTransform)
    case legacyMask(LegacyMask)
}

/// A surface as it runs: one carrier, one hysteresis, one panic lock. Layers organise; partitions play.
public struct SpatialRuntimePartition: Equatable, Sendable {
    /// Identity in the compiled instrument. A layer without surfaces has one partition with the layer's ID.
    public let id: UUID
    public let ownerLayerID: UUID
    public let surfaceID: UUID?
    /// Ordered by ring, then tick.
    public let cells: [PolarDeviceLattice]
    /// Routings as the runtime must see them (axis angles in the world frame).
    public let routings: [SpatialRouting]
    public let cellOverrides: [PolarDeviceLattice: [SpatialCellAction]]
}

/// An editable area with stable identity, its own assignments and its own control axis.
public struct SpatialSurface: Equatable, Sendable {
    /// Display only; changing it never rebuilds the compiled index.
    public struct Presentation: Equatable, Sendable {
        public var name: String
        public var color: SpatialLayerColor
        /// Visual coding of the value course. Colours are never read back as values.
        public var valueColors: [SpatialLayerColor]
        public init(name: String, color: SpatialLayerColor, valueColors: [SpatialLayerColor] = []) {
            self.name = name; self.color = color; self.valueColors = valueColors
        }
    }
    public let id: UUID
    public private(set) var presentation: Presentation
    public let form: SurfaceForm
    /// Authored assignments. The axis angle of a shaped surface is in the surface's own frame.
    public let routings: [SpatialRouting]
    /// The play area the derivation was made under (a legacy mask is never cut: always `.standard`).
    public let settings: SurfaceSettings
    /// Cells derived at construction. Not part of equality: it is a function of form and settings.
    public let derivation: SurfaceDerivation

    public init(id: UUID = UUID(), presentation: Presentation, form: SurfaceForm, routings: [SpatialRouting] = [],
                settings: SurfaceSettings = .standard,
                budget: SurfaceRasterBudget = SurfaceRasterizer.documentBudget) throws {
        self.id = id; self.presentation = presentation; self.form = form; self.routings = routings
        switch form {
        case .shape(let shape, let transform):
            self.settings = settings
            derivation = try SurfaceRasterizer.derive(shape: shape, transform: transform, settings: settings, budget: budget)
        case .legacyMask(let mask):
            self.settings = .standard
            derivation = SurfaceRasterizer.derive(maskCells: mask.cells)
        }
    }

    /// Reconstruct with an already verified derivation (decoder).
    init(id: UUID, presentation: Presentation, form: SurfaceForm, routings: [SpatialRouting],
         settings: SurfaceSettings, derivation: SurfaceDerivation) {
        self.id = id; self.presentation = presentation; self.form = form; self.routings = routings
        self.settings = settings; self.derivation = derivation
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.presentation == rhs.presentation && lhs.form == rhs.form
            && lhs.routings == rhs.routings && lhs.settings == rhs.settings
    }

    public var cells: [PolarDeviceLattice] { derivation.cells }
    public var isLegacyMask: Bool { if case .legacyMask = form { return true }; return false }
    public var transform: SurfaceTransform {
        if case .shape(_, let transform) = form { return transform }
        return .identity
    }
    public var cellOverrides: [PolarDeviceLattice: [SpatialCellAction]] {
        if case .legacyMask(let mask) = form { return mask.cellOverrides }
        return [:]
    }

    /// The single place where the authoring frame becomes the runtime frame: axis angles of a
    /// shaped surface are replaced by their world angles. Everything that compiles or previews
    /// the surface reads this.
    public func materializedRoutings() -> [SpatialRouting] {
        guard case .shape(let shape, let transform) = form else { return routings }
        // A ring sector is centred on the scanner and cannot be placed: local = world.
        if case .ringSector = shape { return routings }
        guard transform != .identity else { return routings }
        return routings.map { routing in
            var routing = routing
            routing.program = SurfaceAxis.worldProgram(routing.program, transform: transform)
            return routing
        }
    }

    /// The carrier of this surface. A surface does not know its layer, so the owner is named by the caller.
    public func partition(ownerLayerID: UUID) -> SpatialRuntimePartition {
        .init(id: id, ownerLayerID: ownerLayerID, surfaceID: id, cells: derivation.cells,
              routings: materializedRoutings(), cellOverrides: cellOverrides)
    }

    /// A whole-surface pitch edit. Shapes and cells stay; assignments (and a mask's overrides) change.
    public func applying(_ operation: SpatialPitchOperation) throws -> Self {
        var routings = self.routings
        try operation.apply(toRoutings: &routings)
        switch form {
        case .shape: return replacing(routings: routings)
        case .legacyMask(let mask):
            var overrides = mask.cellOverrides
            try operation.apply(toOverrides: &overrides)
            return Self(id: id, presentation: presentation, form: .legacyMask(LegacyMask(cells: mask.cells, cellOverrides: overrides)),
                        routings: routings, settings: settings, derivation: derivation)
        }
    }

    public func replacingPresentation(_ presentation: Presentation) -> Self {
        var copy = self; copy.presentation = presentation; return copy
    }

    /// Same musical inputs, ignoring name and colours.
    func hasSameIndexInputs(as other: Self) -> Bool {
        var normalized = self
        normalized.presentation = other.presentation
        return normalized == other
    }

    /// The same surface derived again under other document settings (all-or-nothing).
    public func rederived(under settings: SurfaceSettings) throws -> Self {
        try Self(id: id, presentation: presentation, form: form, routings: routings, settings: settings)
    }
    public func replacing(form: SurfaceForm, routings: [SpatialRouting]? = nil) throws -> Self {
        try Self(id: id, presentation: presentation, form: form, routings: routings ?? self.routings, settings: settings)
    }
    /// Assignments never change the cells, so the derivation is kept.
    public func replacing(routings: [SpatialRouting]) -> Self {
        Self(id: id, presentation: presentation, form: form, routings: routings, settings: settings, derivation: derivation)
    }
}

// MARK: Copies

public extension SpatialSurface {
    /// A copy with a new surface identity and new routing identities. Targets and per-cell values
    /// go through the given maps (the caller retargets release layers and strips). The derivation is
    /// kept: a copy of a shape has the same cells.
    func copying(retargeting target: (SpatialRoutingTarget) -> SpatialRoutingTarget,
                 value: (SpatialCellValue) -> SpatialCellValue) -> SpatialSurface {
        let routings = routings.map { SpatialRouting(id: UUID(), target: target($0.target), program: $0.program, chordRootMIDINote: $0.chordRootMIDINote) }
        let form: SurfaceForm
        switch self.form {
        case .shape: form = self.form
        case .legacyMask(let mask):
            form = .legacyMask(LegacyMask(cells: mask.cells, cellOverrides: mask.cellOverrides.mapValues { actions in
                actions.map { SpatialCellAction(target: target($0.target), value: value($0.value)) }
            }))
        }
        return SpatialSurface(id: UUID(), presentation: presentation, form: form, routings: routings, settings: settings, derivation: derivation)
    }
}

public extension SpatialDocumentLayer {
    /// A complete copy under a new layer identity. Surfaces get new identities too, so no surface,
    /// partition or routing ID exists twice in the document.
    func copying(newLayerID: UUID, retargeting target: (SpatialRoutingTarget) -> SpatialRoutingTarget,
                 value: (SpatialCellValue) -> SpatialCellValue) -> SpatialDocumentLayer {
        SpatialDocumentLayer(id: newLayerID, name: name, color: color, isVisible: isVisible, isActive: isActive,
            isLocked: isLocked, isSoloed: isSoloed, cells: cells,
            routings: routings.map { SpatialRouting(id: UUID(), target: target($0.target), program: $0.program, chordRootMIDINote: $0.chordRootMIDINote) },
            cellOverrides: cellOverrides.mapValues { actions in actions.map { SpatialCellAction(target: target($0.target), value: value($0.value)) } },
            toggleGuardSeconds: toggleGuardSeconds, commonNotes: commonNotes, midiTarget: midiTarget,
            surfaces: surfaces.map { $0.copying(retargeting: target, value: value) })
    }
}

public extension SpatialDocumentLayer {
    /// The shaped surfaces derived again under other document settings (a copy from another
    /// document). All-or-nothing: a surface that no longer fits refuses the whole layer.
    func rederivingSurfaces(under settings: SurfaceSettings) throws -> SpatialDocumentLayer {
        guard isSurfaceBacked else { return self }
        return replacing(surfaces: try surfaces.map { surface in
            guard !surface.isLegacyMask, surface.settings != settings else { return surface }
            do { return try surface.rederived(under: settings) }
            catch { throw SpatialDocumentError.surfaceSettingsMismatch(surfaceID: surface.id) }
        })
    }
}
