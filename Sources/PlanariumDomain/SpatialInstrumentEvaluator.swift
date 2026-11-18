import Foundation
import PLSDeviceValues
import SickPLSCore

public struct SpatialPlayedNote: Hashable, Sendable {
    public let number: UInt8
    public let velocity: UInt8

    public init(number: UInt8, velocity: UInt8) {
        self.number = min(number, 127)
        self.velocity = min(velocity, 127)
    }
}

public enum SpatialEvaluatedValue: Equatable, Sendable {
    case programChange(SpatialProgramChange)
    case inactive
    case notes(Set<SpatialPlayedNote>, transition: SpatialNoteTransition)
    case scalar(Double)
    case boolean(Bool)
}

public struct SpatialRoutingEvaluation: Equatable, Sendable {
    /// Measured representative priority; geometry stays outside the ledger.
    public var displayCell: PolarDeviceLattice?
    public var representativeDistanceSquared: Double = .infinity
    public var midiDestination: SpatialOutputDestination = .midi
    public let routingID: UUID
    public let target: SpatialRoutingTarget
    public let value: SpatialEvaluatedValue
    /// Toggle entry identity: the compiled anchor of a painted surface,
    /// shared by its fine segments. Hold carries its measured sounding cell.
    public let cell: PolarDeviceLattice?
    public let commonNotes: SpatialCommonNotes
    public let toggleGuardSeconds: Double

    public init(routingID: UUID, target: SpatialRoutingTarget, value: SpatialEvaluatedValue, cell: PolarDeviceLattice? = nil,
                toggleGuardSeconds: Double = 0, commonNotes: SpatialCommonNotes = .keep) {
        self.routingID = routingID
        self.target = target
        self.value = value
        self.cell = cell
        self.commonNotes = commonNotes
        self.toggleGuardSeconds = SpatialInstrumentLayer.normalizedToggleGuard(toggleGuardSeconds)
    }
}

/// Pure coarse-cell value projection for editor labels. Live profiles use
/// the compiled detection and value plan; this type owns no selection state.
public struct SpatialInstrumentEvaluator: Sendable {
    public init() {}

    public func evaluate(
        activeCells: [UUID: PolarMetricGridCell],
        workspace: SpatialInstrumentWorkspace
    ) -> [SpatialRoutingEvaluation] {
        evaluate(activeCells: activeCells, candidateDistancesCentimeters: [:], workspace: workspace)
    }

    public func evaluate(
        activeCells: [UUID: PolarMetricGridCell],
        candidateMeasurements: [UUID: ProjectedScanMeasurement],
        workspace: SpatialInstrumentWorkspace
    ) -> [SpatialRoutingEvaluation] {
        evaluate(
            activeCells: activeCells,
            candidateDistancesCentimeters: candidateMeasurements.mapValues { Double($0.distanceCentimeters) },
            workspace: workspace
        )
    }

    public func evaluate(
        activeCells: [UUID: PolarMetricGridCell],
        candidateDistancesCentimeters: [UUID: Double],
        workspace: SpatialInstrumentWorkspace
    ) -> [SpatialRoutingEvaluation] {
        let audible = SpatialLayerAudibility.audibleIDs(workspace.layers.map { ($0.id, $0.isActive, $0.isSoloed) })
        return workspace.layers.flatMap { layer -> [SpatialRoutingEvaluation] in
            guard audible.contains(layer.id) else { return [] }
            let activePolarCells = activeCells[layer.id].map { Set([$0]) } ?? []
            let activeCells = Set(activePolarCells.map(\.valueCell))
            let allValueCells = Set(layer.polarCells.map(\.valueCell))
            return layer.routings.map { routing in
                SpatialRoutingEvaluation(
                    routingID: routing.id,
                    target: routing.target,
                    value: value(
                        for: routing,
                        activeCells: activeCells,
                        activePolarCells: activePolarCells,
                        allValueCells: allValueCells,
                        layer: layer,
                        grid: workspace.grid,
                        candidateDistance: candidateDistancesCentimeters[layer.id]
                    ), commonNotes: layer.commonNotes
                )
            }
        }
    }

    /// Berechnet die Zellwerte einer Ebene in einem Durchlauf. Die Ausdehnung
    /// der Ebene wird je richtungsabhängigem Routing einmal bestimmt und die
    /// Zellbewertung benutzt dieselbe `value`-Logik wie der Spielpfad.
    public func cellValues(
        layerID: UUID,
        cells: [PolarMetricGridCell],
        workspace: SpatialInstrumentWorkspace
    ) -> [PolarMetricGridCell: SpatialEvaluatedValue] {
        guard let layer = workspace.layers.first(where: { $0.id == layerID }),
              let routing = layer.routings.first else { return [:] }

        // Constant, chord, single-note, random and override values do not
        // depend on the extent of the layer. Single-cell labels must not walk
        // thousands of unrelated painted cells for these programs.
        let allValueCells: Set<MetricGridCell>
        let extent: DirectionalExtent?
        switch routing.program {
        case let .continuous(_, _, direction, _),
             let .scale(_, _, _, _, direction, _, _):
            allValueCells = Set(layer.polarCells.map(\.valueCell))
            extent = directionalExtent(
                allCells: allValueCells, grid: workspace.grid, degrees: direction
            )
        default:
            allValueCells = []
            extent = nil
        }

        var result: [PolarMetricGridCell: SpatialEvaluatedValue] = [:]
        result.reserveCapacity(cells.count)
        for cell in cells {
            result[cell] = value(
                for: routing,
                activeCells: [cell.valueCell],
                activePolarCells: [cell],
                allValueCells: allValueCells,
                layer: layer,
                grid: workspace.grid,
                candidateDistance: nil,
                directionalExtent: extent
            )
        }
        return result
    }

    private func value(
        for routing: SpatialRouting,
        activeCells: Set<MetricGridCell>,
        activePolarCells: Set<PolarMetricGridCell>,
        allValueCells: Set<MetricGridCell>,
        layer: SpatialInstrumentLayer,
        grid: MetricSquareGrid,
        candidateDistance: Double?,
        directionalExtent: DirectionalExtent? = nil
    ) -> SpatialEvaluatedValue {
        if case .midiAllNotesOff = routing.target {
            return .boolean(!activeCells.isEmpty)
        }
        if case .audioUnitAllNotesOff = routing.target {
            return .boolean(!activeCells.isEmpty)
        }
        if routing.target.isLayerControl {
            return .boolean(!activeCells.isEmpty)
        }
        let overrides = activePolarCells.flatMap { cell in
            (layer.polarCellOverrides[cell] ?? []).filter { $0.target == routing.target }.map(\.value)
        }
        if !overrides.isEmpty { return combine(overrides, target: routing.target, fallback: routing.program) }

        switch routing.program {
        case .programChange(let selection): return activeCells.isEmpty ? .inactive : .programChange(selection)
        case .constant(let value):
            return activeCells.isEmpty ? .inactive : .scalar(value)
        case let .continuous(minimum, maximum, direction, curve):
            guard !activeCells.isEmpty else { return .inactive }
            let cell = activeCells[activeCells.startIndex]
            let value = continuousValueAtDistance(
                cell: cell,
                polarCell: activePolarCells.first,
                distanceCentimeters: candidateDistance,
                allCells: allValueCells,
                grid: grid,
                minimum: minimum,
                maximum: maximum,
                directionDegrees: direction,
                curve: curve,
                directionalExtent: directionalExtent
            )
            return .scalar(value)
        case let .scale(root, low, high, scale, direction, ascending, transition):
            let notes = activeCells.map {
                SpatialPlayedNote(number: UInt8(clamping: scaleNote(
                    cell: $0, allCells: allValueCells, grid: grid, root: root,
                    low: low, high: high, scale: scale,
                    directionDegrees: direction, ascending: ascending,
                    directionalExtent: directionalExtent
                )), velocity: 100)
            }
            return .notes(Set(notes), transition: transition)
        case let .randomScale(root, low, high, scale, seed, transition):
            let allowed = allowedNotes(root: root, low: low, high: high, scale: scale)
            let notes = activeCells.map { cell -> SpatialPlayedNote in
                let mixed = deterministicHash(seed: seed, cell: cell)
                let note = allowed.isEmpty ? min(max(root, 0), 127) : allowed[Int(mixed % UInt64(allowed.count))]
                return SpatialPlayedNote(number: UInt8(clamping: note), velocity: 100)
            }
            return .notes(Set(notes), transition: transition)
        case let .singleNote(note, velocity, transition):
            return .notes(activeCells.isEmpty ? [] : [.init(number: UInt8(clamping: note), velocity: velocity)], transition: transition)
        case let .chord(notes, velocity, transition):
            let result = activeCells.isEmpty ? [] : notes.map {
                SpatialPlayedNote(number: UInt8(clamping: min(max($0, 0), 127)), velocity: velocity)
            }
            return .notes(Set(result), transition: transition)
        }
    }

    private func continuousValueAtDistance(
        cell: MetricGridCell,
        polarCell: PolarMetricGridCell?,
        distanceCentimeters: Double?,
        allCells: Set<MetricGridCell>,
        grid: MetricSquareGrid,
        minimum: Double,
        maximum: Double,
        directionDegrees: Double,
        curve: SpatialValueCurve,
        directionalExtent: DirectionalExtent? = nil
    ) -> Double {
        guard let distanceCentimeters, let polarCell else {
            return continuousValue(cell: cell, allCells: allCells, grid: grid,
                                   minimum: minimum, maximum: maximum,
                                   directionDegrees: directionDegrees, curve: curve,
                                   directionalExtent: directionalExtent)
        }
        let segment = PolarMetricCellSegment(cell: polarCell, grid: grid)
        let angle = ((segment.startBearingDegrees + segment.endBearingDegrees) / 2) * .pi / 180
        let adjustedPoint = MetricScanPoint(
            xMeters: sin(angle) * distanceCentimeters / 100,
            yMeters: cos(angle) * distanceCentimeters / 100
        )
        let adjustedCell = PolarMetricGridCell(point: adjustedPoint, grid: grid).valueCell
        return continuousValue(cell: adjustedCell, allCells: allCells, grid: grid,
                               minimum: minimum, maximum: maximum,
                               directionDegrees: directionDegrees, curve: curve)
    }

    private func combine(
        _ values: [SpatialCellValue], target: SpatialRoutingTarget, fallback: SpatialValueProgram
    ) -> SpatialEvaluatedValue {
        if target.isProgramChange,
           let selection = values.compactMap({ value -> SpatialProgramChange? in
               if case .programChange(let selection) = value { return selection }; return nil
           }).first { return .programChange(selection) }
        let transition: SpatialNoteTransition
        switch fallback {
        case .scale(_, _, _, _, _, _, let value), .randomScale(_, _, _, _, _, let value), .chord(_, _, let value), .singleNote(_, _, let value):
            transition = value
        default: transition = .retrigger
        }
        let notes = values.flatMap { value -> [SpatialPlayedNote] in
            switch value {
            case let .note(number, velocity): return [.init(number: UInt8(clamping: number), velocity: velocity)]
            case let .chord(numbers, velocity): return numbers.map { .init(number: UInt8(clamping: $0), velocity: velocity) }
            default: return []
            }
        }
        if !notes.isEmpty { return .notes(Set(notes), transition: transition) }
        let scalars = values.compactMap { value -> Double? in
            if case .scalar(let scalar) = value { return scalar }
            return nil
        }
        if !scalars.isEmpty { return .scalar(scalars.reduce(0, +) / Double(scalars.count)) }
        let booleans = values.compactMap { value -> Bool? in
            if case .boolean(let boolean) = value { return boolean }
            return nil
        }
        if !booleans.isEmpty { return .boolean(booleans.contains(true)) }
        switch target {
        case .midiNote, .audioUnitNote: return .notes([], transition: transition)
        case .boolean, .midiAllNotesOff, .audioUnitAllNotesOff, .sceneSwitch, .releaseLayer: return .boolean(false)
        default: return .scalar(0)
        }
    }

    private func continuousValue(
        cell: MetricGridCell, allCells: Set<MetricGridCell>, grid: MetricSquareGrid,
        minimum: Double, maximum: Double, directionDegrees: Double, curve: SpatialValueCurve,
        directionalExtent: DirectionalExtent? = nil
    ) -> Double {
        let fraction = directionalFraction(
            cell: cell, allCells: allCells, grid: grid, degrees: directionDegrees,
            precomputed: directionalExtent
        )
        let shaped: Double
        switch curve { case .linear: shaped = fraction; case .easeIn: shaped = fraction * fraction; case .easeOut: shaped = 1 - pow(1 - fraction, 2) }
        return minimum + (maximum - minimum) * shaped
    }

    private func scaleNote(
        cell: MetricGridCell, allCells: Set<MetricGridCell>, grid: MetricSquareGrid,
        root: Int, low: Int, high: Int, scale: SpatialScale,
        directionDegrees: Double, ascending: Bool,
        directionalExtent: DirectionalExtent? = nil
    ) -> Int {
        let allowed = allowedNotes(root: root, low: low, high: high, scale: scale)
        guard !allowed.isEmpty else { return min(max(root, 0), 127) }
        var fraction = directionalFraction(
            cell: cell, allCells: allCells, grid: grid, degrees: directionDegrees,
            precomputed: directionalExtent
        )
        if !ascending { fraction = 1 - fraction }
        let index = min(Int((fraction * Double(allowed.count)).rounded(.down)), allowed.count - 1)
        return allowed[index]
    }

    private struct DirectionalExtent {
        let minimum: Double
        let maximum: Double
    }

    private func directionalExtent(
        allCells: Set<MetricGridCell>, grid: MetricSquareGrid, degrees: Double
    ) -> DirectionalExtent? {
        guard !allCells.isEmpty else { return nil }
        let radians = degrees * .pi / 180
        let projections = allCells.map { item -> Double in
            let bounds = grid.bounds(of: item)
            let x = (bounds.minXMeters + bounds.maxXMeters) / 2
            let y = (bounds.minYMeters + bounds.maxYMeters) / 2
            return x * cos(radians) + y * sin(radians)
        }
        guard let minimum = projections.min(), let maximum = projections.max() else { return nil }
        return DirectionalExtent(minimum: minimum, maximum: maximum)
    }

    private func directionalFraction(
        cell: MetricGridCell, allCells: Set<MetricGridCell>, grid: MetricSquareGrid, degrees: Double,
        precomputed: DirectionalExtent? = nil
    ) -> Double {
        guard !allCells.isEmpty else { return 0 }
        let extent = precomputed ?? directionalExtent(allCells: allCells, grid: grid, degrees: degrees)
        guard let extent, extent.maximum > extent.minimum else { return 0 }
        let radians = degrees * .pi / 180
        let bounds = grid.bounds(of: cell)
        let x = (bounds.minXMeters + bounds.maxXMeters) / 2
        let y = (bounds.minYMeters + bounds.maxYMeters) / 2
        let projection = x * cos(radians) + y * sin(radians)
        return min(max((projection - extent.minimum) / (extent.maximum - extent.minimum), 0), 1)
    }

    private func allowedNotes(root: Int, low: Int, high: Int, scale: SpatialScale) -> [Int] {
        let lower = min(max(min(low, high), 0), 127)
        let upper = min(max(max(low, high), 0), 127)
        let pitchClasses = Set(scale.semitoneOffsets.map { (($0 + root) % 12 + 12) % 12 })
        return Array(lower...upper).filter { pitchClasses.contains(($0 % 12 + 12) % 12) }
    }

    private func deterministicHash(seed: UInt64, cell: MetricGridCell) -> UInt64 {
        var value = seed ^ UInt64(bitPattern: Int64(cell.column)) &* 0x9E3779B97F4A7C15
        value ^= UInt64(bitPattern: Int64(cell.row)) &* 0xBF58476D1CE4E5B9
        value ^= value >> 30; value &*= 0xBF58476D1CE4E5B9
        value ^= value >> 27; value &*= 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
