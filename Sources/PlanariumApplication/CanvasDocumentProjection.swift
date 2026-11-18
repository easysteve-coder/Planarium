import Foundation
import PlanariumDomain
import SickPLSControlCore

/// The existing coarse canvas is an editing projection of the device lattice.
/// Metadata edits never remigrate its masks. Only explicitly added/deleted
/// coarse tiles alter coverage; untouched fine addresses/overrides survive.
enum CanvasDocumentProjection {
    /// The coarse cell canvas is a picture of a layer made of editable surfaces, not an editor of it.
    enum ProjectionError: Error, Equatable { case surfaceBackedLayerContentIsReadOnly }

    static func tile(_ cell: PolarDeviceLattice, grid: MetricSquareGrid) -> PolarMetricGridCell {
        // UI grids have already passed the domain's integer-centimeter check.
        try! LegacyLatticeMigration.project(cell, in: grid)
    }
    static func workspace(_ document: InstrumentDocument) -> SpatialInstrumentWorkspace {
        let grid = document.editorGrid
        let layers = document.spatial.layers.map { layer -> SpatialInstrumentLayer in
            var overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
            // A layer of surfaces is shown through its partitions: the union of their cells and masks.
            let overrideSource = layer.isSurfaceBacked ? layer.surfaces.reduce(into: [:]) { $0.merge($1.cellOverrides) { first, _ in first } } : layer.cellOverrides
            // Stable projection; distinct fine overrides remain authoritative
            // in the document even if a coarse editor tile cannot show both.
            for cell in overrideSource.keys.sorted(by: { ($0.ring, $0.sector) < ($1.ring, $1.sector) }) {
                let tile = tile(cell, grid: grid)
                if overrides[tile] == nil { overrides[tile] = overrideSource[cell] }
            }
            let cells = layer.isSurfaceBacked ? layer.surfaces.flatMap(\.cells) : Array(layer.cells)
            var projected = SpatialInstrumentLayer(id: layer.id, name: layer.name, color: layer.color,
                isVisible: layer.isVisible, isActive: layer.isActive, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
                polarCells: Set(cells.map { tile($0, grid: grid) }), routings: layer.allRoutings, polarCellOverrides: overrides,
                toggleGuardSeconds: layer.toggleGuardSeconds, commonNotes: layer.commonNotes, midiTarget: layer.midiTarget)
            projected.isSurfaceBacked = layer.isSurfaceBacked
            return projected
        }
        var value = SpatialInstrumentWorkspace(grid: grid, layers: layers, channelName: document.channelName,
            channelColor: document.channelColor, detectionConfiguration: document.detection,
            preserveLayerStructure: true, scenes: document.scenes, currentSceneID: document.currentSceneID)
        value.selectLayer(document.spatial.selectedLayerID)
        return value
    }
    static func applying(_ after: SpatialInstrumentWorkspace, before: SpatialInstrumentWorkspace,
                         to source: InstrumentDocument) throws -> InstrumentDocument {
        var result = source
        result.editorGrid = after.grid; result.channelName = after.channelName; result.channelColor = after.channelColor
        result.detection = after.detectionConfiguration
        let layers = try after.layers.map { edited -> SpatialDocumentLayer in
            let oldProjection = before.layers.first { $0.id == edited.id }
            let old = source.spatial.layers.first { $0.id == edited.id }
            if edited.isSurfaceBacked || old?.isSurfaceBacked == true {
                // Only organisation fields of such a layer may change here. A copy of one cannot be
                // rebuilt from its picture, and its content is never edited cell by cell.
                guard let old, old.isSurfaceBacked, edited.isSurfaceBacked else { throw ProjectionError.surfaceBackedLayerContentIsReadOnly }
                if before.grid == after.grid {
                    guard let oldProjection, edited.polarCells == oldProjection.polarCells, edited.routings == oldProjection.routings,
                          edited.polarCellOverrides == oldProjection.polarCellOverrides else {
                        throw ProjectionError.surfaceBackedLayerContentIsReadOnly
                    }
                }
                return SpatialDocumentLayer(id: edited.id, name: edited.name, color: edited.color,
                    isVisible: edited.isVisible, isActive: edited.isActive, isLocked: edited.isLocked, isSoloed: edited.isSoloed,
                    cells: [], routings: [], cellOverrides: [:], toggleGuardSeconds: edited.toggleGuardSeconds,
                    commonNotes: edited.commonNotes, midiTarget: edited.midiTarget, surfaces: old.surfaces)
            }
            var cells = old?.cells ?? []
            var overrides = old?.cellOverrides ?? [:]
            if before.grid != after.grid {
                return SpatialDocumentLayer(id: edited.id, name: edited.name, color: edited.color,
                    isVisible: edited.isVisible, isActive: edited.isActive, isLocked: edited.isLocked, isSoloed: edited.isSoloed,
                    cells: cells, routings: edited.routings, cellOverrides: overrides, toggleGuardSeconds: edited.toggleGuardSeconds, commonNotes: edited.commonNotes, midiTarget: edited.midiTarget)
            }
            let removed = (oldProjection?.polarCells ?? []).subtracting(edited.polarCells)
            if !removed.isEmpty { cells = Set(cells.filter { !removed.contains(tile($0, grid: before.grid)) }) }
            for added in edited.polarCells.subtracting(oldProjection?.polarCells ?? []) {
                cells.formUnion(try LegacyLatticeMigration.migrate(added, in: after.grid).cells)
            }
            let targetChanged = old.map { $0.routings.map(\.target) != edited.routings.map(\.target) } ?? false
            if targetChanged, let old { overrides = retarget(old.cellOverrides, from: old.routings, to: edited.routings).values }
            let changedKeys = targetChanged ? Set<PolarMetricGridCell>() : Set(edited.polarCellOverrides.keys).union(oldProjection?.polarCellOverrides.keys.map { $0 } ?? [])
            for key in changedKeys where edited.polarCellOverrides[key] != oldProjection?.polarCellOverrides[key] {
                for cell in overrides.keys where tile(cell, grid: before.grid) == key { overrides[cell] = nil }
                if let actions = edited.polarCellOverrides[key] {
                    for cell in try LegacyLatticeMigration.migrate(key, in: after.grid).cells { overrides[cell] = actions }
                }
            }
            return SpatialDocumentLayer(id: edited.id, name: edited.name, color: edited.color,
                isVisible: edited.isVisible, isActive: edited.isActive, isLocked: edited.isLocked, isSoloed: edited.isSoloed,
                cells: cells, routings: edited.routings, cellOverrides: overrides, toggleGuardSeconds: edited.toggleGuardSeconds, commonNotes: edited.commonNotes, midiTarget: edited.midiTarget)
        }
        result.spatial = try source.spatial.replacingLayers(layers, selectedLayerID: after.selectedLayerID)
        result.scenes = after.scenes
        result.currentSceneID = after.currentSceneID
        return result
    }
    static func outputLoss(_ after: SpatialInstrumentWorkspace, in source: InstrumentDocument) -> Int {
        source.spatial.layers.reduce(0) { count, old in
            guard !old.isSurfaceBacked, let edited = after.layers.first(where: { $0.id == old.id }),
                  old.routings.map(\.target) != edited.routings.map(\.target) else { return count }
            return count + retarget(old.cellOverrides, from: old.routings, to: edited.routings).lost
        }
    }
    private static func retarget(_ overrides: [PolarDeviceLattice: [SpatialCellAction]],
                                 from old: [SpatialRouting], to new: [SpatialRouting])
        -> (values: [PolarDeviceLattice: [SpatialCellAction]], lost: Int) {
        var values: [PolarDeviceLattice: [SpatialCellAction]] = [:]
        var lost = 0
        for (cell, actions) in overrides {
            var migrated: [SpatialCellAction] = []
            for action in actions {
                if new.contains(where: { $0.target == action.target }) { migrated.append(action); continue }
                guard let index = old.firstIndex(where: { $0.target == action.target }) else {
                    migrated.append(action); continue // previously dormant, unrelated value
                }
                let replacement = new.first(where: { $0.id == old[index].id }) ?? (new.indices.contains(index) ? new[index] : nil)
                if let replacement, fits(action.value, target: replacement.target) {
                    migrated.append(.init(target: replacement.target, value: action.value))
                } else { lost += 1 }
            }
            // Empty overrides have their own meaning and survive independently.
            if !migrated.isEmpty || actions.isEmpty { values[cell] = migrated }
        }
        return (values, lost)
    }
    private static func fits(_ value: SpatialCellValue, target: SpatialRoutingTarget) -> Bool {
        switch (value, target) {
        case (.programChange, .midiProgramChange), (.programChange, .audioUnitProgramChange): return true
        case (.note, .midiNote), (.note, .audioUnitNote), (.chord, .midiNote), (.chord, .audioUnitNote),
             (.scalar, .audioUnitCC), (.scalar, .audioUnitPitchBend), (.scalar, .audioUnitChannelPressure),
             (.scalar, .midiCC), (.scalar, .midiPitchBend), (.scalar, .midiChannelPressure), (.scalar, .audioUnitParameter), (.scalar, .midiEffectParameter),
             (.boolean, .boolean), (.sceneSwitch, .sceneSwitch), (.releaseLayer, .releaseLayer): return true
        default: return false
        }
    }

}
