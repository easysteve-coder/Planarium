import PlanariumDomain
import Foundation

public enum SpatialCellBulkOperation: Equatable, Sendable {
    case paint, erase, deactivate, removeOwnValues
    case setAction(SpatialCellAction)
    case assignAndActivate(SpatialCellAction)
    case removeActions(target: SpatialRoutingTarget)

    public var undoActionName: String {
        switch self {
        case .paint: return "Paint cells"
        case .erase: return "Delete cells"
        case .deactivate: return "Deactivate cells"
        case .setAction, .assignAndActivate: return "Assign note"
        case .removeActions, .removeOwnValues: return "Remove assignment"
        }
    }
}

public enum SpatialCellBulkRejection: Error, Equatable, Sendable {
    case emptySelection
    case layerLocked(layerID: UUID)
    case targetNotRouted(SpatialRoutingTarget)
    case valueDoesNotFitTarget
    case valueOutOfRange
    case addressBudgetExceeded(limit: Int)
    case unsupportedCoordinateMode
    case noSelectedLayer
}

public enum SpatialCellBulkOutcome: Equatable, Sendable {
    case unchanged
    case applied(changedCells: Int)
}

public enum SpatialCellBulkEdit {
    /// Keep each layer's musical assignment when only its compatible output changes.
    public static func retarget(_ layer: inout SpatialInstrumentLayer, to target: SpatialRoutingTarget,
                                fallbackProgram: SpatialValueProgram) {
        guard !layer.routings.isEmpty else {
            layer.routings = [.init(target: target, program: fallbackProgram)]; return
        }
        let previous = layer.routings[0].target
        let comparable = previous.retargeted(to: target.destination, stripID: target.stripID ?? SpatialRoutingTarget.missingStripID)
        let normalized = target.withMIDIChannel(comparable.midiChannel ?? 0).withStripID(comparable.stripID ?? SpatialRoutingTarget.missingStripID)
        layer.routings[0].target = target
        let compatibleFamily = previous.destination == target.destination || (previous.midiChannel != nil && target.midiChannel != nil)
        if !compatibleFamily || normalized != comparable {
            layer.routings[0].program = fallbackProgram
            layer.routings[0].chordRootMIDINote = nil
        }
        layer.routings = [layer.routings[0]]
    }

    public static func apply<Cell: Hashable>(
        _ operation: SpatialCellBulkOperation, to selection: Set<Cell>,
        isLocked: Bool, layerID: UUID, routings: [SpatialRouting],
        cells: inout Set<Cell>, overrides: inout [Cell: [SpatialCellAction]],
        addressBudget: Int
    ) -> Result<SpatialCellBulkOutcome, SpatialCellBulkRejection> {
        guard !selection.isEmpty else { return .failure(.emptySelection) }
        guard !isLocked else { return .failure(.layerLocked(layerID: layerID)) }

        if case let .setAction(action) = operation {
            guard routings.contains(where: { $0.target == action.target }) else {
                return .failure(.targetNotRouted(action.target))
            }
            guard valueFits(action.value, target: action.target) else {
                return .failure(.valueDoesNotFitTarget)
            }
            guard valueIsInRange(action.value) else {
                return .failure(.valueOutOfRange)
            }
        }
        if case let .assignAndActivate(action) = operation {
            guard routings.contains(where: { $0.target == action.target }) else {
                return .failure(.targetNotRouted(action.target))
            }
            guard valueFits(action.value, target: action.target) else {
                return .failure(.valueDoesNotFitTarget)
            }
            guard valueIsInRange(action.value) else {
                return .failure(.valueOutOfRange)
            }
        }

        let oldCells = cells
        let oldOverrides = overrides
        var nextCells = cells
        var nextOverrides = overrides

        switch operation {
        case .paint:
            nextCells.formUnion(selection)
        case .deactivate:
            nextCells.subtract(selection)
        case .erase:
            nextCells.subtract(selection)
            for cell in selection { nextOverrides[cell] = nil }
        case .removeOwnValues:
            for cell in selection { nextOverrides[cell] = nil }
        case let .setAction(action), let .assignAndActivate(action):
            for cell in selection {
                var actions = nextOverrides[cell] ?? []
                actions.removeAll { $0.target == action.target }
                actions.append(action)
                nextOverrides[cell] = actions
            }
            if case .assignAndActivate = operation {
                nextCells.formUnion(selection)
            }
        case let .removeActions(target):
            for cell in selection {
                guard var actions = nextOverrides[cell] else { continue }
                actions.removeAll { $0.target == target }
                nextOverrides[cell] = actions.isEmpty ? nil : actions
            }
        }

        guard nextCells.union(nextOverrides.keys).count <= addressBudget else {
            return .failure(.addressBudgetExceeded(limit: addressBudget))
        }
        let changed = selection.reduce(into: 0) { count, cell in
            if oldCells.contains(cell) != nextCells.contains(cell) || oldOverrides[cell] != nextOverrides[cell] {
                count += 1
            }
        }
        cells = nextCells
        overrides = nextOverrides
        return changed == 0 ? .success(.unchanged) : .success(.applied(changedCells: changed))
    }

    private static func valueFits(_ value: SpatialCellValue, target: SpatialRoutingTarget) -> Bool {
        switch target {
        case .midiProgramChange, .audioUnitProgramChange:
            if case .programChange = value { return true }; return false
        case .midiNote, .audioUnitNote:
            if case .note = value { return true }
            if case .chord = value { return true }
            return false
        case .boolean:
            if case .boolean = value { return true }
            return false
        case .sceneSwitch:
            if case .sceneSwitch = value { return true }
            return false
        case .releaseLayer:
            if case .releaseLayer = value { return true }
            return false
        case .audioUnitAllNotesOff, .midiAllNotesOff:
            return false
        case .midiEffectParameter, .audioUnitParameter, .midiCC, .audioUnitCC, .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure:
            if case .scalar = value { return true }
            return false
        }
    }

    private static func valueIsInRange(_ value: SpatialCellValue) -> Bool {
        switch value {
        case .programChange(let selection):
            return selection.isValid
        case let .scalar(number): return number.isFinite && (0...1).contains(number)
        case let .note(number, velocity): return (0...127).contains(number) && (1...127).contains(Int(velocity))
        case let .chord(notes, velocity):
            return !notes.isEmpty && notes.allSatisfy { (0...127).contains($0) } && (1...127).contains(Int(velocity))
        case .boolean, .sceneSwitch, .releaseLayer: return true
        }
    }
}

public enum SpatialCellBulkMenuDisabledReason: Equatable, Sendable {
    case emptySelection
    case layerLocked
    case noRouting
    case valueDoesNotFitTarget
}

public struct SpatialCellBulkMenuItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case activate, assignNote, assignScalar, removeActions, deactivate, erase, duplicate, paintHere, selectLayer, moveToLayer(UUID)
    }
    public let kind: Kind
    public let isEnabled: Bool
    public let disabledReason: SpatialCellBulkMenuDisabledReason?
    public init(kind: Kind, isEnabled: Bool, disabledReason: SpatialCellBulkMenuDisabledReason? = nil) {
        self.kind = kind; self.isEnabled = isEnabled; self.disabledReason = disabledReason
    }
}

public enum SpatialCellBulkMenu {
    public static func items(in state: MetricCanvasInteractionState) -> [SpatialCellBulkMenuItem] {
        guard !state.isPerformanceLocked else { return [] }
        if state.selectedCells.isEmpty {
            return [.init(kind: .paintHere, isEnabled: state.contextPaintCell != nil && !state.isPerformanceLocked)]
        }
        let ids = Set(state.selectedCells.map(\.layerID))
        let layers = state.workspace.layers.filter { ids.contains($0.id) }
        let editable = !state.isPerformanceLocked && layers.allSatisfy { $0.isVisible && !$0.isLocked }
        let notes = layers.allSatisfy { layer in layer.routings.contains { routing in
            switch routing.target { case .midiNote, .audioUnitNote: return true; default: return false }
        } }
        let scalar = layers.allSatisfy { layer in layer.routings.contains { routing in
            switch routing.target { case .midiCC, .audioUnitCC, .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure, .audioUnitParameter, .midiEffectParameter: return true; default: return false }
        } }
        return [.init(kind: .selectLayer, isEnabled: editable),
                .init(kind: .assignNote, isEnabled: editable && notes), .init(kind: .assignScalar, isEnabled: editable && scalar),
                .init(kind: .removeActions, isEnabled: editable), .init(kind: .deactivate, isEnabled: editable),
                .init(kind: .erase, isEnabled: editable), .init(kind: .duplicate, isEnabled: editable)]
            + state.workspace.layers.map { .init(kind: .moveToLayer($0.id), isEnabled: editable && $0.isVisible && !$0.isLocked) }
    }

    public static func title(_ kind: SpatialCellBulkMenuItem.Kind, in state: MetricCanvasInteractionState) -> String {
        switch kind {
        case .selectLayer: return "Select layer"
        case .activate: return "Playable (layer rule)"
        case .assignNote: return "Note/chord…"
        case .assignScalar: return "CC value…"
        case .removeActions: return "Remove own values"
        case .deactivate: return "Deactivate cells"
        case .erase: return "Delete cells"
        case .duplicate: return "Duplicate cells"
        case .paintHere: return "Paint here in \(state.workspace.selectedLayer.name)"
        case .moveToLayer(let id): return state.workspace.layers.first { $0.id == id }?.name ?? "Missing layer"
        }
    }

    public static func items(layer: SpatialInstrumentLayer, selectionCount: Int) -> [SpatialCellBulkMenuItem] {
        let locked = layer.isLocked
        let hasSelection = selectionCount > 0
        let routing = layer.routings.first?.target
        let noteOK = routing.map { if case .midiNote = $0 { return true }; if case .audioUnitNote = $0 { return true }; return false } ?? false
        let scalarOK = routing.map { switch $0 { case .midiEffectParameter, .audioUnitParameter, .midiCC, .audioUnitCC, .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure: return true; default: return false } } ?? false
        func item(_ kind: SpatialCellBulkMenuItem.Kind, _ fits: Bool = true) -> SpatialCellBulkMenuItem {
            if locked { return .init(kind: kind, isEnabled: false, disabledReason: .layerLocked) }
            if !hasSelection { return .init(kind: kind, isEnabled: false, disabledReason: .emptySelection) }
            if !fits { return .init(kind: kind, isEnabled: false, disabledReason: routing == nil ? .noRouting : .valueDoesNotFitTarget) }
            return .init(kind: kind, isEnabled: true)
        }
        return [item(.activate), item(.assignNote, noteOK), item(.assignScalar, scalarOK), item(.removeActions, routing != nil), item(.deactivate), item(.erase)]
    }
}

public extension SpatialInstrumentWorkspace {
    @discardableResult
    mutating func applyBulk(_ operation: SpatialCellBulkOperation, to selection: Set<PolarMetricGridCell>, addressBudget: Int) -> Result<SpatialCellBulkOutcome, SpatialCellBulkRejection> {
        guard coordinateMode == .polar else { return .failure(.unsupportedCoordinateMode) }
        guard let index = layers.firstIndex(where: { $0.id == selectedLayerID }) else { return .failure(.noSelectedLayer) }
        var layer = layers[index]
        let result = SpatialCellBulkEdit.apply(operation, to: selection, isLocked: layer.isLocked, layerID: layer.id,
                                               routings: layer.routings, cells: &layer.polarCells,
                                               overrides: &layer.polarCellOverrides, addressBudget: addressBudget)
        if case .success = result { replaceLayer(layer, at: index) }
        return result
    }
}

/// Layer and cell commands share CanvasSession's document-command transaction.
/// Locked members are counted and skipped before the one workspace publication.
public extension CanvasSession {
    func setLayerLocks(_ ids: Set<UUID>, locked: Bool) {
        commitNumberEdits()
        updateWorkspace(named: "Change layer lock") { workspace in
            for id in ids { workspace.updateLayer(id) { $0.isLocked = locked } }
        }
    }
    @discardableResult func applyToLayers(_ ids: Set<UUID>, named name: String,
                                          _ change: (inout SpatialInstrumentLayer) -> Void) -> Int {
        commitNumberEdits()
        let skipped = workspace.layers.filter { ids.contains($0.id) && $0.isLocked }.count
        updateWorkspace(named: name) { workspace in
            for id in ids {
                guard let layer = workspace.layers.first(where: { $0.id == id }), !layer.isLocked else { continue }
                workspace.updateLayer(id, change)
            }
        }
        if skipped > 0 { perform { $0.statusMessage = "\(skipped) locked layers unchanged" } }
        return skipped
    }
}

public extension SpatialCellBulkEdit {
    static func apply(_ operation: SpatialPitchOperation, to document: InstrumentDocument,
                      selection: CanvasSelection, activeLayerID: UUID) throws -> InstrumentDocument {
        let pairs = selection.layerIDs.isEmpty ? selection.cells : []
        // Chosen surfaces are the unit: exactly they change, in whatever layer they stand. Every other
        // surface keeps its assignments and per-cell values untouched.
        if !selection.surfaceIDs.isEmpty {
            var next = document
            var layers = next.spatial.layers
            var found = Set<UUID>()
            for i in layers.indices {
                let layer = layers[i]
                let chosen = layer.surfaces.filter { selection.surfaceIDs.contains($0.id) }
                guard !chosen.isEmpty else { continue }
                found.formUnion(chosen.map(\.id))
                guard !layer.isLocked else { continue }
                layers[i] = layer.replacing(surfaces: try layer.surfaces.map { selection.surfaceIDs.contains($0.id) ? try $0.applying(operation) : $0 })
            }
            guard found == selection.surfaceIDs else { throw SpatialPitchOperation.Failure.unknownSurface }
            next.spatial = try next.spatial.replacingLayers(layers)
            return next
        }
        let ids = selection.effectiveLayerIDs(activeLayerID: activeLayerID)
        var next = document
        var layers = next.spatial.layers
        for i in layers.indices where ids.contains(layers[i].id) {
            guard !layers[i].isLocked else { continue }
            let layer = layers[i]
            if layer.isSurfaceBacked {
                // A whole-layer pitch edit reaches every surface. Coarse cells of a surface are no unit
                // to edit: refuse out loud instead of leaving the layer as it was.
                guard pairs.isEmpty else { throw SpatialPitchOperation.Failure.cellsOfASurface }
                layers[i] = layer.replacing(surfaces: try layer.surfaces.map { try $0.applying(operation) })
                continue
            }
            var routings = layer.routings, overrides = layer.cellOverrides
            if pairs.isEmpty {
                try operation.apply(toRoutings: &routings)
                try operation.apply(toOverrides: &overrides)
            } else {
                let tiles = Set(pairs.filter { $0.layerID == layers[i].id }.map(\.cell))
                let addresses = try layers[i].cells.union(overrides.keys).filter {
                    tiles.contains(try LegacyLatticeMigration.project($0, in: document.editorGrid))
                }
                let inherited = try SpatialInstrumentCompiler.inheritedValues(in: layer, cells: Set(addresses))
                for key in addresses {
                    let originalActions = overrides[key] ?? []
                    var actions = try originalActions.map { SpatialCellAction(target: $0.target, value: try operation.applying(to: $0.value)) }
                    for value in inherited[key] ?? [] where !originalActions.contains(where: { $0.target == value.target }) {
                        guard case let .notes(notes, _) = value.value, let first = notes.first else { continue }
                        let source: SpatialCellValue = notes.count == 1 ? .note(number: Int(first.number), velocity: first.velocity)
                            : .chord(notes: notes.map { Int($0.number) }, velocity: first.velocity)
                        let transformed = try operation.applying(to: source)
                        if transformed != source { actions.append(.init(target: value.target, value: transformed)) }
                    }
                    if actions != originalActions { overrides[key] = actions }
                }
            }
            layers[i] = SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color,
                isVisible: layer.isVisible, isActive: layer.isActive, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
                cells: layer.cells, routings: routings, cellOverrides: overrides,
                toggleGuardSeconds: layer.toggleGuardSeconds, commonNotes: layer.commonNotes, midiTarget: layer.midiTarget,
                surfaces: layer.surfaces)
        }
        next.spatial = try next.spatial.replacingLayers(layers)
        return next
    }
}
