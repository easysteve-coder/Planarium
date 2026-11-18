import Foundation
import PLSDeviceValues

public enum SpatialInstrumentCompiler {
    public static func compile(
        _ document: SpatialDocument,
        revision: SpatialDocumentRevision,
        requiredLayerIDs: Set<UUID> = [],
        snapGrid: MetricSquareGrid? = nil
    ) throws -> CompiledInstrument {
        guard document.latticeVersion == .polarDeviceV2 else {
            throw CompiledInstrumentError.unsupportedLatticeVersion(document.latticeVersion)
        }

        try validate(document)
        let audible = SpatialLayerAudibility.audibleIDs(document.layers.map { ($0.id, $0.isActive, $0.isSoloed) })
        // The ordinary compiled index keeps its established audibility
        // contract.  A scene member or control layer is added explicitly so
        // it can become audible on the runtime control path without a new
        // snapshot.
        // Eligibility is decided per runtime partition: a layer's state (active, solo, scene
        // membership) reaches all of its partitions; a control routing makes only its own
        // partition required, exactly as it would make its own layer required.
        let layerRequired = audible.union(requiredLayerIDs)
        var eligible: [(layer: SpatialDocumentLayer, partition: SpatialRuntimePartition)] = []
        var ineligibleCount = 0, ineligibleOverrideCells = 0
        for layer in document.layers {
            if layer.isSurfaceBacked {
                for surface in layer.surfaces {
                    if layerRequired.contains(layer.id) || surface.routings.contains(where: { $0.target.isLayerControl }) {
                        eligible.append((layer, surface.partition(ownerLayerID: layer.id)))
                    } else {
                        ineligibleCount += 1
                        ineligibleOverrideCells += surface.cellOverrides.count
                    }
                }
            } else if layerRequired.contains(layer.id) || layer.routings.contains(where: { $0.target.isLayerControl }) {
                eligible.append((layer, layer.partitions[0]))
            } else {
                ineligibleCount += 1
                ineligibleOverrideCells += layer.cellOverrides.count
            }
        }
        // Compiled layer indices are UInt16; the document budget already keeps partitions far below.
        guard eligible.count <= Int(UInt16.max) else { throw SpatialDocumentError.budgetExceeded(.partitions) }

        var compiledLayers: [CompiledInstrumentLayer] = []
        compiledLayers.reserveCapacity(eligible.count)
        var columns = Array(repeating: [CompiledInstrument.IndexEntry](), count: PolarDeviceLattice.maxTick + 1)
        var indexedAddressCount = 0
        var maxEntriesPerTick = 0
        var dormantOverrideCells = 0
        var overrideCellCount = 0
        var actionGroupCount = 0
        var routingPlanCount = 0
        var partitionOwner: [UUID: UUID] = [:]

        for (compiledLayerIndex, entry) in eligible.enumerated() {
            let layer = entry.layer, partition = entry.partition
            let cells = partition.cells
            let routingTargets = Set(partition.routings.map(\.target))
            var cellActions: [CompiledCellActions] = []
            if layer.isSurfaceBacked { partitionOwner[partition.id] = layer.id }

            for cell in cells {
                guard let actions = partition.cellOverrides[cell], !actions.isEmpty else { continue }
                overrideCellCount += 1
                let groups = summaries(
                    for: actions, allowedTargets: routingTargets
                )
                actionGroupCount += groups.count
                if !groups.isEmpty {
                    cellActions.append(CompiledCellActions(cell: cell, groups: groups))
                }
            }
            for overrideCell in partition.cellOverrides.keys where !containsCell(overrideCell, in: cells) {
                dormantOverrideCells += 1
            }

            let contents = surfaceContents(routings: partition.routings, overrides: partition.cellOverrides, cells: cells, snapEnabled: snapGrid != nil)
            let regions = contents.isEmpty ? [:] : SpatialCellContent.regions(cells: cells, contents: contents)
            let snapRegions = try snapGrid.map { try SpatialCellContent.snapRegions(cells: cells, contents: contents, grid: $0) } ?? [:]
            let geometry = try snapGrid.map { try snapGeometry(cells: cells, regions: snapRegions, grid: $0) } ?? [:]
            let compiled = CompiledInstrumentLayer(
                id: partition.id,
                compiledLayerIndex: compiledLayerIndex,
                cells: cells,
                routings: partition.routings.map { CompiledRoutingPlan($0, cells: cells, regions: regions, toggleGuardSeconds: layer.toggleGuardSeconds, commonNotes: layer.commonNotes) },
                cellActions: cellActions,
                snapRegionByCell: snapRegions, snapGeometry: geometry, midiTarget: layer.midiTarget
            )
            compiledLayers.append(compiled)
            routingPlanCount += partition.routings.count

            for (offset, cell) in cells.enumerated() {
                columns[cell.sector].append(.init(
                    ring: UInt16(cell.ring), compiledLayerIndex: UInt16(compiledLayerIndex), cellOffset: UInt32(offset)
                ))
                indexedAddressCount += 1
            }
        }

        for index in columns.indices {
            columns[index].sort {
                if $0.ring != $1.ring { return $0.ring < $1.ring }
                if $0.compiledLayerIndex != $1.compiledLayerIndex { return $0.compiledLayerIndex < $1.compiledLayerIndex }
                return $0.cellOffset < $1.cellOffset
            }
            maxEntriesPerTick = max(maxEntriesPerTick, columns[index].count)
        }

        let statistics = CompiledInstrumentStatistics(
            compiledLayerCount: compiledLayers.count,
            indexedAddressCount: indexedAddressCount,
            maxEntriesPerTick: maxEntriesPerTick,
            overrideCellCount: overrideCellCount,
            dormantOverrideCells: dormantOverrideCells,
            ineligibleLayerCount: ineligibleCount,
            ineligibleOverrideCells: ineligibleOverrideCells,
            actionGroupCount: actionGroupCount,
            routingPlanCount: routingPlanCount,
            estimatedIndexBytes: indexedAddressCount * 8
        )
        return CompiledInstrument(
            revision: revision, layers: compiledLayers, columns: columns, statistics: statistics,
            activeLayerIDs: document.activeRuntimeIDs, partitionOwner: partitionOwner
        )
    }

    /// Document-wide identity and value checks shared with the surface editor.
    internal static func validate(_ document: SpatialDocument) throws {
        var routingIDs = Set<UUID>()
        for layer in document.layers {
            for routing in layer.allRoutings {
                guard routingIDs.insert(routing.id).inserted else {
                    throw CompiledInstrumentError.duplicateRoutingID(routing.id)
                }
                if let root = routing.chordRootMIDINote, !(0...127).contains(root) {
                    throw CompiledInstrumentError.nonFiniteProgramValue(layerID: layer.id, routingID: routing.id)
                }
                try validate(routing.program, layerID: layer.id, routingID: routing.id)
            }
            for cell in layer.cellOverrides.keys.sorted(by: cellOrder) {
                let actions = layer.cellOverrides[cell] ?? []
                try validate(actions, layerID: layer.id, cell: cell)
            }
            for surface in layer.surfaces {
                for cell in surface.cellOverrides.keys.sorted(by: cellOrder) {
                    try validate(surface.cellOverrides[cell] ?? [], layerID: layer.id, cell: cell)
                }
            }
        }
    }

    private static func validate(
        _ program: SpatialValueProgram, layerID: UUID, routingID: UUID
    ) throws {
        func finite(_ value: Double) -> Bool { value.isFinite }
        func checkedInt(_ lhs: Int, _ rhs: Int) -> Bool {
            !lhs.addingReportingOverflow(rhs).overflow
        }
        switch program {
        case .programChange(let selection):
            guard selection.isValid else {
                throw CompiledInstrumentError.nonFiniteProgramValue(layerID: layerID, routingID: routingID)
            }
        case .constant(let value):
            guard finite(value) else { throw CompiledInstrumentError.nonFiniteProgramValue(layerID: layerID, routingID: routingID) }
        case let .continuous(minimum, maximum, direction, _):
            guard finite(minimum), finite(maximum), finite(direction),
                  (maximum - minimum).isFinite else {
                throw CompiledInstrumentError.nonFiniteProgramValue(layerID: layerID, routingID: routingID)
            }
        case let .scale(root, low, high, _, direction, _, transition):
            guard finite(direction), checkedInt(root, 127), checkedInt(low, 127), checkedInt(high, 127),
                  valid(transition) else {
                throw CompiledInstrumentError.nonFiniteProgramValue(layerID: layerID, routingID: routingID)
            }
        case let .randomScale(root, low, high, _, _, transition):
            guard checkedInt(root, 127), checkedInt(low, 127), checkedInt(high, 127),
                  valid(transition) else {
                throw CompiledInstrumentError.nonFiniteProgramValue(layerID: layerID, routingID: routingID)
            }
        case let .singleNote(note, _, transition):
            guard checkedInt(note, 127), valid(transition) else {
                throw CompiledInstrumentError.nonFiniteProgramValue(layerID: layerID, routingID: routingID)
            }
        case let .chord(notes, _, transition):
            guard notes.allSatisfy({ $0.addingReportingOverflow(127).overflow == false }),
                  valid(transition) else {
                throw CompiledInstrumentError.nonFiniteProgramValue(layerID: layerID, routingID: routingID)
            }
        }
    }

    private static func valid(_ transition: SpatialNoteTransition) -> Bool {
        if case .overlap(let milliseconds) = transition { return milliseconds.isFinite }
        return true
    }

    private static func validate(
        _ actions: [SpatialCellAction], layerID: UUID, cell: PolarDeviceLattice
    ) throws {
        var scalarSums: [SpatialRoutingTarget: Double] = [:]
        for action in actions {
            if case .programChange(let selection) = action.value, !selection.isValid {
                throw CompiledInstrumentError.nonFiniteOverrideValue(layerID: layerID, cell: cell)
            }
            if case .scalar(let value) = action.value {
                guard value.isFinite else {
                    throw CompiledInstrumentError.nonFiniteOverrideValue(layerID: layerID, cell: cell)
                }
                let old = scalarSums[action.target, default: 0]
                let sum = old + value
                guard sum.isFinite else {
                    throw CompiledInstrumentError.nonFiniteOverrideValue(layerID: layerID, cell: cell)
                }
                scalarSums[action.target] = sum
            }
        }
    }

    private static func summaries(
        for actions: [SpatialCellAction], allowedTargets: Set<SpatialRoutingTarget>
    ) -> [CompiledActionGroup] {
        var targets: [SpatialRoutingTarget] = []
        for action in actions where allowedTargets.contains(action.target) {
            // All-notes-off is a control routing and always wins over cell
            // overrides; it therefore never gets an override summary.
            if case .midiAllNotesOff = action.target { continue }
            if case .audioUnitAllNotesOff = action.target { continue }
            if !targets.contains(action.target) { targets.append(action.target) }
        }
        return targets.compactMap { target in
            let values = actions.filter { $0.target == target }.map(\.value)
            guard let summary = SpatialCellContent.summarize(values, target: target)
            else { return nil }
            return CompiledActionGroup(target: target, summary: summary)
        }
    }

    private static func surfaceContents(routings: [SpatialRouting], overrides: [PolarDeviceLattice: [SpatialCellAction]],
                                        cells: [PolarDeviceLattice], snapEnabled: Bool) -> [PolarDeviceLattice: [CompiledActionSummary]] {
        guard snapEnabled || routings.contains(where: { routing in
            switch routing.program {
            case .singleNote(_, _, .toggle), .chord(_, _, .toggle): return true
            default: return false
            }
        }) else { return [:] }
        let plans = routings.map { CompiledValuePlan(program: $0.program, cells: cells) }
        return Dictionary(uniqueKeysWithValues: cells.map { cell in
            (cell, zip(routings, plans).map { routing, plan in
                SpatialCellContent.effective(target: routing.target, actions: overrides[cell] ?? [],
                    defaultValue: plan.value(activeCell: cell, candidateDistanceCentimeters: nil))
            })
        })
    }

    private static func cellOrder(_ lhs: PolarDeviceLattice, _ rhs: PolarDeviceLattice) -> Bool {
        lhs.ring == rhs.ring ? lhs.sector < rhs.sector : lhs.ring < rhs.ring
    }

    /// Use the exact drawn arcs, including fractional angular edges and cells
    /// projected from partial imported masks. Fine addresses never shrink Snap.
    private static func snapGeometry(cells: [PolarDeviceLattice], regions: [PolarDeviceLattice: PolarDeviceLattice],
                                     grid: MetricSquareGrid) throws -> [PolarDeviceLattice: [PolarMetricCellSegment]] {
        let projected = try Dictionary(grouping: cells) { try LegacyLatticeMigration.project($0, in: grid) }
        var result: [PolarDeviceLattice: [PolarMetricCellSegment]] = [:]
        for address in projected.keys.sorted(by: { $0.ring == $1.ring ? $0.angularIndex < $1.angularIndex : $0.ring < $1.ring }) {
            let fineCells = projected[address] ?? []
            let anchors = Set(fineCells.compactMap { regions[$0] })
            // A drawn cell is the minimum Snap geometry even when a
            // scale or random program evaluates differently on its fine rays.
            for anchor in anchors {
                result[anchor, default: []].append(.init(cell: address, grid: grid))
            }
        }
        return result
    }
}

/// One effective-content definition for editor islands, Toggle and Snap surfaces.
/// Action order, duplicate notes and explicit values equal to the layer default
/// cannot introduce artificial surface boundaries.
public enum SpatialCellContent {
    /// Snap uses the editor's edge adjacency, so even a partial fine mask
    /// cannot introduce an invisible gap or boundary inside a drawn cell.
    /// A cell with varying fine values remains the minimum indivisible surface.
    internal static func snapRegions(cells: [PolarDeviceLattice], contents: [PolarDeviceLattice: [CompiledActionSummary]],
                                     grid: MetricSquareGrid) throws -> [PolarDeviceLattice: PolarDeviceLattice] {
        let projected = try Dictionary(grouping: cells) { try LegacyLatticeMigration.project($0, in: grid) }
        let addresses = projected.keys.sorted { $0.ring == $1.ring ? $0.angularIndex < $1.angularIndex : $0.ring < $1.ring }
        var uniform: [PolarMetricGridCell: [CompiledActionSummary]] = [:]
        for address in addresses {
            guard let fine = projected[address], let first = fine.first, let value = contents[first],
                  fine.allSatisfy({ contents[$0] == value }) else { continue }
            uniform[address] = value
        }
        var remaining = Set(addresses), result: [PolarDeviceLattice: PolarDeviceLattice] = [:]
        for seed in addresses where remaining.remove(seed) != nil {
            guard let anchor = projected[seed]?.first else { continue }
            var queue = [seed], offset = 0
            while offset < queue.count {
                let current = queue[offset]; offset += 1
                for fine in projected[current] ?? [] { result[fine] = anchor }
                guard let value = uniform[seed] else { continue }
                for neighbour in neighbours(of: current, grid: grid) where remaining.contains(neighbour) && uniform[neighbour] == value {
                    remaining.remove(neighbour); queue.append(neighbour)
                }
            }
        }
        return result
    }

    internal static func regions(cells: [PolarDeviceLattice], contents: [PolarDeviceLattice: [CompiledActionSummary]]) -> [PolarDeviceLattice: PolarDeviceLattice] {
        var remaining = Set(cells), regions: [PolarDeviceLattice: PolarDeviceLattice] = [:]
        for seed in cells where remaining.remove(seed) != nil {
            var queue = [seed], offset = 0
            regions[seed] = seed
            while offset < queue.count {
                let cell = queue[offset]; offset += 1
                for (ring, sector) in [(cell.ring - 1, cell.sector), (cell.ring + 1, cell.sector),
                                       (cell.ring, cell.sector - 1), (cell.ring, cell.sector + 1)] {
                    guard let neighbour = PolarDeviceLattice(ring: ring, sector: sector),
                          remaining.contains(neighbour), contents[neighbour] == contents[seed] else { continue }
                    remaining.remove(neighbour); regions[neighbour] = seed; queue.append(neighbour)
                }
            }
        }
        return regions
    }
    internal static func effective(target: SpatialRoutingTarget, actions: [SpatialCellAction],
                                   defaultValue: SpatialEvaluatedValue) -> CompiledActionSummary {
        let values = actions.filter { $0.target == target }.map(\.value)
        if !values.isEmpty {
            switch target {
            case .midiAllNotesOff, .audioUnitAllNotesOff: break
            default: if let summary = summarize(values, target: target) { return summary }
            }
        }
        switch defaultValue {
        case .programChange(let selection): return .programChange(selection)
        case .notes(let notes, _): return .notes(notes.sorted {
            $0.number == $1.number ? $0.velocity < $1.velocity : $0.number < $1.number
        })
        case .scalar(let value): return .scalar(value)
        case .boolean(let value): return .boolean(value)
        case .inactive: return .boolean(false)
        }
    }

    public static func island(containing seed: PolarMetricGridCell, layer: SpatialInstrumentLayer,
                              grid: MetricSquareGrid,
                              within allowedCells: Set<PolarMetricGridCell>? = nil) -> Set<PolarMetricGridCell> {
        let eligible = layer.polarCells.intersection(allowedCells ?? layer.polarCells)
        guard eligible.contains(seed) else { return [] }
        let cells = Array(layer.polarCells)
        let defaults = layer.routings.map { routing -> [PolarMetricGridCell: SpatialEvaluatedValue] in
            var projection = layer
            projection.routings = [routing]; projection.polarCellOverrides = [:]
            return SpatialInstrumentEvaluator().cellValues(layerID: layer.id, cells: cells,
                workspace: .init(grid: grid, layers: [projection]))
        }
        func content(_ cell: PolarMetricGridCell) -> [CompiledActionSummary] {
            layer.routings.enumerated().map { index, routing in
                effective(target: routing.target, actions: layer.polarCellOverrides[cell] ?? [],
                          defaultValue: defaults[index][cell] ?? .inactive)
            }
        }
        let seedContent = content(seed)
        var visited: Set<PolarMetricGridCell> = [seed], queue = [seed], offset = 0
        while offset < queue.count {
            let cell = queue[offset]; offset += 1
            for neighbour in neighbours(of: cell, grid: grid) where eligible.contains(neighbour) && !visited.contains(neighbour) {
                guard content(neighbour) == seedContent else { continue }
                visited.insert(neighbour); queue.append(neighbour)
            }
        }
        return visited
    }

    private static func neighbours(of cell: PolarMetricGridCell, grid: MetricSquareGrid) -> [PolarMetricGridCell] {
        let area = PolarMetricCellSegment(cell: cell, grid: grid)
        var result = [PolarMetricGridCell(ring: cell.ring, angularIndex: cell.angularIndex - 1),
                      PolarMetricGridCell(ring: cell.ring, angularIndex: cell.angularIndex + 1)]
        for ring in [cell.ring - 1, cell.ring + 1] where ring >= 0 {
            let step = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: Double(ring + 1) * grid.cellSizeMeters,
                                                                radialHeightMeters: grid.cellSizeMeters)
            // Shared boundaries are corner contact only; a rounding residue
            // must never turn an exactly touching cell into an edge neighbour.
            let first = Int(((area.startBearingDegrees + 180) / step + 1e-9).rounded(.down))
            let end = Int(((area.endBearingDegrees + 180) / step - 1e-9).rounded(.up))
            for index in first..<end {
                result.append(.init(ring: ring, angularIndex: index))
            }
        }
        return result
    }

    internal static func summarize(
        _ values: [SpatialCellValue], target: SpatialRoutingTarget
    ) -> CompiledActionSummary? {
        if target.isProgramChange,
           let selection = values.compactMap({ value -> SpatialProgramChange? in
               if case .programChange(let selection) = value { return selection }; return nil
           }).first { return .programChange(selection) }
        if case .releaseLayer = target,
           let id = values.compactMap({ value -> UUID? in
               if case .releaseLayer(let id) = value { return id }; return nil
           }).first { return .releaseLayer(id) }
        if case .sceneSwitch = target,
           let action = values.compactMap({ value -> SpatialSceneSwitchAction? in
               if case .sceneSwitch(let action) = value { return action }; return nil
           }).first { return .sceneSwitch(action) }
        let notes = values.flatMap { value -> [SpatialPlayedNote] in
            switch value {
            case let .note(number, velocity): return [.init(number: UInt8(clamping: number), velocity: velocity)]
            case let .chord(numbers, velocity): return numbers.map { .init(number: UInt8(clamping: $0), velocity: velocity) }
            default: return []
            }
        }
        if !notes.isEmpty {
            return .notes(Array(Set(notes)).sorted {
                $0.number == $1.number ? $0.velocity < $1.velocity : $0.number < $1.number
            })
        }
        let scalars = values.compactMap { value -> Double? in
            if case .scalar(let value) = value { return value }
            return nil
        }
        if !scalars.isEmpty { return .scalar(scalars.reduce(0, +) / Double(scalars.count)) }
        let booleans = values.compactMap { value -> Bool? in
            if case .boolean(let value) = value { return value }
            return nil
        }
        if !booleans.isEmpty { return .boolean(booleans.contains(true)) }
        switch target {
        case .midiNote, .audioUnitNote:
            return .notes([])
        case .boolean, .midiAllNotesOff, .audioUnitAllNotesOff, .sceneSwitch, .releaseLayer:
            return .boolean(false)
        default:
            return .scalar(0)
        }
    }
}


public extension SpatialInstrumentCompiler {
    /// Exact inherited fine-cell values for authoring, independent of activity
    /// and output availability. Shares Runtime's value preparation, not its index.
    static func inheritedValues(in layer: SpatialDocumentLayer, cells: Set<PolarDeviceLattice>) throws -> [PolarDeviceLattice: [SpatialRoutingEvaluation]] {
        for routing in layer.routings { try validate(routing.program, layerID: layer.id, routingID: routing.id) }
        let painted = layer.cells.sorted { ($0.ring, $0.sector) < ($1.ring, $1.sector) }
        let plans = layer.routings.map { ($0, CompiledValuePlan(program: $0.program, cells: painted)) }
        return Dictionary(uniqueKeysWithValues: cells.intersection(layer.cells).map { cell in
            (cell, plans.map { routing, plan in
                SpatialRoutingEvaluation(routingID: routing.id, target: routing.target,
                    value: plan.value(activeCell: cell, candidateDistanceCentimeters: nil))
            })
        })
    }
}
