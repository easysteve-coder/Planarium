import Foundation
import PLSDeviceValues

/// Persistierbare Farbe ohne Abhängigkeit von SwiftUI/AppKit.
public struct SpatialLayerColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let blue = SpatialLayerColor(red: 0.18, green: 0.55, blue: 0.96)
    /// FIRSTofFIFTH-Amber als primäre Bühnenfarbe.
    public static let orange = SpatialLayerColor(red: 1.00, green: 0.55, blue: 0.00)
    public static let green = SpatialLayerColor(red: 0.25, green: 0.78, blue: 0.42)
    public static let purple = SpatialLayerColor(red: 0.67, green: 0.36, blue: 0.88)
    /// Three rows of eight distinct hues: vivid, medium and muted.
    /// Existing documents retain their stored RGB values.
    public static let palette: [SpatialLayerColor] = [
        .orange, .init(red: 0.94, green: 0.80, blue: 0.12), .init(red: 0.20, green: 0.82, blue: 0.32), .init(red: 0.12, green: 0.78, blue: 0.84),
        .blue, .init(red: 0.60, green: 0.30, blue: 0.94), .init(red: 0.93, green: 0.22, blue: 0.68), .init(red: 0.95, green: 0.18, blue: 0.18),
        .init(red: 0.92, green: 0.68, blue: 0.40), .init(red: 0.85, green: 0.86, blue: 0.36), .init(red: 0.53, green: 0.79, blue: 0.48), .init(red: 0.42, green: 0.79, blue: 0.74),
        .init(red: 0.47, green: 0.68, blue: 0.92), .init(red: 0.67, green: 0.53, blue: 0.85), .init(red: 0.89, green: 0.48, blue: 0.69), .init(red: 0.95, green: 0.50, blue: 0.45),
        .init(red: 0.65, green: 0.45, blue: 0.26), .init(red: 0.58, green: 0.59, blue: 0.28), .init(red: 0.31, green: 0.55, blue: 0.36), .init(red: 0.27, green: 0.53, blue: 0.55),
        .init(red: 0.32, green: 0.43, blue: 0.66), .init(red: 0.48, green: 0.36, blue: 0.62), .init(red: 0.61, green: 0.32, blue: 0.48), .init(red: 0.64, green: 0.32, blue: 0.28)
    ]

}

/// Pure editor move.  It deliberately lives with the document model rather
/// than the SwiftUI gesture so previews and keyboard moves cannot develop a
/// second address rule.
public enum PolarCellMove {
    public struct Result: Equatable, Sendable {
        public let workspace: SpatialInstrumentWorkspace
        public let cells: Set<PolarMetricGridCell>
        public let didHitBoundary: Bool
        public let cellsByLayer: [UUID: Set<PolarMetricGridCell>]

        public init(workspace: SpatialInstrumentWorkspace, cells: Set<PolarMetricGridCell>, didHitBoundary: Bool,
                    cellsByLayer: [UUID: Set<PolarMetricGridCell>] = [:]) {
            self.workspace = workspace; self.cells = cells; self.didHitBoundary = didHitBoundary
            self.cellsByLayer = cellsByLayer
        }
    }

    /// Moves the supplied cells in each requested layer.  The radial part is
    /// measured in editor-ring heights; the angular part is measured in the
    /// widest source segment. Each axis accepts its largest feasible whole
    /// step at the playable boundary; all cells retain their relative shape.
    public static func applying(
        radialSteps: Int,
        angularSteps: Int,
        cells: Set<PolarMetricGridCell>,
        layerIDs: Set<UUID>,
        to source: SpatialInstrumentWorkspace
    ) -> Result {
        applying(radialSteps: radialSteps, angularSteps: angularSteps,
                 cellsByLayer: PolarCellTransform.selection(cells: cells, layerIDs: layerIDs, in: source), to: source)
    }

    public static func applying(radialSteps: Int, angularSteps: Int,
                                cellsByLayer: [UUID: Set<PolarMetricGridCell>], to source: SpatialInstrumentWorkspace) -> Result {
        let sourceCells = Set(cellsByLayer.values.flatMap { $0 })
        guard !sourceCells.isEmpty, radialSteps != 0 || angularSteps != 0 else {
            return Result(workspace: source, cells: sourceCells, didHitBoundary: false, cellsByLayer: cellsByLayer)
        }
        let angularStep = sourceCells.map { cell in
            let segment = PolarMetricCellSegment(cell: cell, grid: source.grid)
            return segment.endBearingDegrees - segment.startBearingDegrees
        }.max() ?? 0
        let originals = sourceCells.map { ($0, PolarMetricCellSegment(cell: $0, grid: source.grid)) }
        let radialMinimum = Int(ceil(-originals.map { $0.1.innerRadiusMeters }.min()! / source.grid.cellSizeMeters - 1e-9))
        let radialMaximum = Int(floor((2 - originals.map { $0.1.outerRadiusMeters }.max()!) / source.grid.cellSizeMeters + 1e-9))
        let angularMinimum = Int(ceil((-90 - originals.map { $0.1.startBearingDegrees }.min()!) / angularStep))
        let angularMaximum = Int(floor((90 - originals.map { $0.1.endBearingDegrees }.max()!) / angularStep))
        let acceptedRadial = radialMinimum <= radialMaximum ? min(max(radialSteps, radialMinimum), radialMaximum) : 0
        let acceptedAngular = angularMinimum <= angularMaximum ? min(max(angularSteps, angularMinimum), angularMaximum) : 0
        if acceptedRadial == 0 && acceptedAngular == 0 {
            return Result(workspace: source, cells: sourceCells, didHitBoundary: true, cellsByLayer: cellsByLayer)
        }
        let radiusDelta = Double(acceptedRadial) * source.grid.cellSizeMeters
        let bearingDelta = Double(acceptedAngular) * angularStep
        return PolarCellTransform.rasterizing(.init(radialTarget: radiusDelta, angularTarget: bearingDelta),
            cellsByLayer: cellsByLayer, to: source,
            didHitBoundary: acceptedRadial != radialSteps || acceptedAngular != angularSteps)
    }

    static func addressOrder(_ lhs: PolarMetricGridCell, _ rhs: PolarMetricGridCell) -> Bool {
        (lhs.ring, lhs.angularIndex) < (rhs.ring, rhs.angularIndex)
    }

    private static func cell(containing midpoint: (radiusMeters: Double, bearingDegrees: Double), grid: MetricSquareGrid) -> PolarMetricGridCell {
        // Raw distance zero is not a usable device address. A sub-ring fit
        // falls back to the nearest usable ring instead of disappearing when
        // the editor projection is compiled back to the device lattice.
        let radius = max(Double(UsableRawDistance.lowestRawValue) / 100 + 1e-12, midpoint.radiusMeters)
        return PolarMetricGridCell(point: MetricScanPoint(
            xMeters: sin(midpoint.bearingDegrees * .pi / 180) * radius,
            yMeters: cos(midpoint.bearingDegrees * .pi / 180) * radius
        ), grid: grid)
    }

    /// The single raster rule for moves, compression and expansion. Every
    /// target midpoint inside a transformed segment gets a source, including
    /// the intermediate rings and angles created by expansion.
    static func targetCells(for shifted: PolarMetricCellSegment, grid: MetricSquareGrid) -> [PolarMetricGridCell] {
        let lowerRing = max(0, Int(floor(shifted.innerRadiusMeters / grid.cellSizeMeters)))
        let upperRing = min(Int((2 / grid.cellSizeMeters).rounded(.up)) - 1, Int(floor(shifted.outerRadiusMeters / grid.cellSizeMeters)))
        guard lowerRing <= upperRing else { return [] }
        var result: [PolarMetricGridCell] = []
        for ring in lowerRing...upperRing {
            if Double(ring + 1) * grid.cellSizeMeters <= Double(UsableRawDistance.lowestRawValue) / 100 { continue }
            let step = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: Double(ring + 1) * grid.cellSizeMeters, radialHeightMeters: grid.cellSizeMeters)
            let lowerAngle = max(-90, shifted.startBearingDegrees)
            let upperAngle = min(90, shifted.endBearingDegrees)
            let lowerIndex = max(0, Int(ceil((lowerAngle + 180) / step - 0.5)))
            let upperIndex = min(Int((360 / step).rounded()) - 1, Int(floor((upperAngle + 180) / step - 0.5)))
            guard lowerIndex <= upperIndex else { continue }
            for angularIndex in lowerIndex...upperIndex {
                let candidate = PolarMetricGridCell(ring: ring, angularIndex: angularIndex)
                let middle = PolarMetricCellSegment(cell: candidate, grid: grid).midpoint
                if middle.radiusMeters >= shifted.innerRadiusMeters, middle.radiusMeters <= shifted.outerRadiusMeters,
                   middle.bearingDegrees >= shifted.startBearingDegrees, middle.bearingDegrees <= shifted.endBearingDegrees,
                   middle.bearingDegrees >= -90, middle.bearingDegrees <= 90 {
                    result.append(candidate)
                }
            }
        }
        return result.isEmpty ? [cell(containing: shifted.midpoint, grid: grid)] : result
    }

    static func isBetterWinner(_ lhs: PolarMetricGridCell, than rhs: PolarMetricGridCell, for target: PolarMetricGridCell, shifted: [PolarMetricGridCell: PolarMetricCellSegment], grid: MetricSquareGrid) -> Bool {
        guard let left = shifted[lhs], let right = shifted[rhs] else { return addressOrder(lhs, rhs) }
        let targetMiddle = PolarMetricCellSegment(cell: target, grid: grid).midpoint
        func distance(_ segment: PolarMetricCellSegment) -> Double {
            let middle = segment.midpoint
            let delta = (middle.bearingDegrees - targetMiddle.bearingDegrees) * .pi / 180
            return sqrt(middle.radiusMeters * middle.radiusMeters + targetMiddle.radiusMeters * targetMiddle.radiusMeters - 2 * middle.radiusMeters * targetMiddle.radiusMeters * cos(delta))
        }
        let a = distance(left), b = distance(right)
        return a == b ? addressOrder(lhs, rhs) : a < b
    }
}

/// Affine transform of polar segments, shared by all editor transformations.
/// The source/target origins and positive scales describe r' and theta'
/// directly; no Cartesian intermediate or independent raster is involved.
public struct PolarCellTransform: Equatable, Sendable {
    public var radialOrigin: Double
    public var radialTarget: Double
    public var radialScale: Double
    public var angularOrigin: Double
    public var angularTarget: Double
    public var angularScale: Double

    public init(radialOrigin: Double = 0, radialTarget: Double = 0, radialScale: Double = 1,
                angularOrigin: Double = 0, angularTarget: Double = 0, angularScale: Double = 1) {
        self.radialOrigin = radialOrigin; self.radialTarget = radialTarget; self.radialScale = radialScale
        self.angularOrigin = angularOrigin; self.angularTarget = angularTarget; self.angularScale = angularScale
    }

    public func segment(_ value: PolarMetricCellSegment) -> PolarMetricCellSegment {
        .init(innerRadiusMeters: radialTarget + (value.innerRadiusMeters - radialOrigin) * radialScale,
              outerRadiusMeters: radialTarget + (value.outerRadiusMeters - radialOrigin) * radialScale,
              startBearingDegrees: angularTarget + (value.startBearingDegrees - angularOrigin) * angularScale,
              endBearingDegrees: angularTarget + (value.endBearingDegrees - angularOrigin) * angularScale)
    }

    public static func sourceCells(cells: Set<PolarMetricGridCell>, layerIDs: Set<UUID>,
                                   in source: SpatialInstrumentWorkspace) -> Set<PolarMetricGridCell> {
        if layerIDs.isEmpty { return cells }
        return source.layers.filter { layerIDs.contains($0.id) }.reduce(into: []) { $0.formUnion($1.polarCells) }
    }

    static func selection(cells: Set<PolarMetricGridCell>, layerIDs: Set<UUID>,
                          in source: SpatialInstrumentWorkspace) -> [UUID: Set<PolarMetricGridCell>] {
        Dictionary(uniqueKeysWithValues: source.layers.compactMap { layer in
            let selected = layerIDs.isEmpty ? (layer.id == source.selectedLayerID ? layer.polarCells.intersection(cells) : [])
                : (layerIDs.contains(layer.id) ? layer.polarCells : [])
            return selected.isEmpty ? nil : (layer.id, selected)
        })
    }

    public static func bounds(cells: Set<PolarMetricGridCell>, grid: MetricSquareGrid) -> PolarMetricCellSegment? {
        guard !cells.isEmpty else { return nil }
        let segments = cells.map { PolarMetricCellSegment(cell: $0, grid: grid) }
        return .init(innerRadiusMeters: segments.map(\.innerRadiusMeters).min()!,
                     outerRadiusMeters: segments.map(\.outerRadiusMeters).max()!,
                     startBearingDegrees: segments.map(\.startBearingDegrees).min()!,
                     endBearingDegrees: segments.map(\.endBearingDegrees).max()!)
    }

    public static func applying(_ requested: Self, cells: Set<PolarMetricGridCell>, layerIDs: Set<UUID>,
                                to source: SpatialInstrumentWorkspace) -> PolarCellMove.Result {
        applying(requested, cellsByLayer: selection(cells: cells, layerIDs: layerIDs, in: source), to: source)
    }

    public static func applying(_ requested: Self, cellsByLayer: [UUID: Set<PolarMetricGridCell>],
                                to source: SpatialInstrumentWorkspace) -> PolarCellMove.Result {
        let selected = Set(cellsByLayer.values.flatMap { $0 })
        guard [requested.radialOrigin, requested.radialTarget, requested.radialScale,
               requested.angularOrigin, requested.angularTarget, requested.angularScale].allSatisfy(\.isFinite),
              requested.radialScale > 0, requested.angularScale > 0,
              let original = bounds(cells: selected, grid: source.grid) else {
            return .init(workspace: source, cells: selected, didHitBoundary: false, cellsByLayer: cellsByLayer)
        }
        let desired = requested.segment(original)
        guard [desired.innerRadiusMeters, desired.outerRadiusMeters, desired.startBearingDegrees,
               desired.endBearingDegrees].allSatisfy(\.isFinite) else {
            return .init(workspace: source, cells: selected, didHitBoundary: true, cellsByLayer: cellsByLayer)
        }
        func interval(_ lower: Double, _ upper: Double, minimum: Double, limit: ClosedRange<Double>) -> (Double, Double) {
            let width = min(limit.upperBound - limit.lowerBound, max(minimum, upper - lower))
            let start = min(max(lower, limit.lowerBound), limit.upperBound - width)
            return (start, start + width)
        }
        let radial = interval(desired.innerRadiusMeters, desired.outerRadiusMeters,
                              minimum: source.grid.cellSizeMeters, limit: 0...2)
        // Radial-only fitting must never widen the source bearing span.
        // The midpoint fallback already guarantees a raster segment.
        let minimumAngle = requested.angularScale == 1
            ? original.endBearingDegrees - original.startBearingDegrees
            : PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: radial.1, radialHeightMeters: source.grid.cellSizeMeters)
        let angular = interval(desired.startBearingDegrees, desired.endBearingDegrees, minimum: minimumAngle, limit: -90...90)
        let accepted = Self(radialOrigin: original.innerRadiusMeters, radialTarget: radial.0,
                            radialScale: (radial.1 - radial.0) / original.radialHeightMeters,
                            angularOrigin: original.startBearingDegrees, angularTarget: angular.0,
                            angularScale: (angular.1 - angular.0) / (original.endBearingDegrees - original.startBearingDegrees))
        let boundary = abs(radial.0 - desired.innerRadiusMeters) > 1e-9 || abs(radial.1 - desired.outerRadiusMeters) > 1e-9
            || abs(angular.0 - desired.startBearingDegrees) > 1e-9 || abs(angular.1 - desired.endBearingDegrees) > 1e-9
        if abs(radial.0 - original.innerRadiusMeters) < 1e-9, abs(radial.1 - original.outerRadiusMeters) < 1e-9,
           abs(angular.0 - original.startBearingDegrees) < 1e-9, abs(angular.1 - original.endBearingDegrees) < 1e-9 {
            return .init(workspace: source, cells: selected, didHitBoundary: boundary, cellsByLayer: cellsByLayer)
        }
        return rasterizing(accepted, cellsByLayer: cellsByLayer, to: source, didHitBoundary: boundary)
    }

    static func rasterizing(_ transform: Self, cells: Set<PolarMetricGridCell>, layerIDs: Set<UUID>,
                            to source: SpatialInstrumentWorkspace, didHitBoundary: Bool) -> PolarCellMove.Result {
        rasterizing(transform, cellsByLayer: selection(cells: cells, layerIDs: layerIDs, in: source),
                    to: source, didHitBoundary: didHitBoundary)
    }

    static func rasterizing(_ transform: Self, cellsByLayer: [UUID: Set<PolarMetricGridCell>],
                            to source: SpatialInstrumentWorkspace, didHitBoundary: Bool) -> PolarCellMove.Result {
        rasterizing(cellsByLayer: cellsByLayer, to: source, didHitBoundary: didHitBoundary) {
            transform.segment($0)
        }
    }

    static func rasterizing(cellsByLayer: [UUID: Set<PolarMetricGridCell>],
                            to source: SpatialInstrumentWorkspace, didHitBoundary: Bool,
                            segmentTransform: (PolarMetricCellSegment) -> PolarMetricCellSegment) -> PolarCellMove.Result {
        let sourceCells = Set(cellsByLayer.values.flatMap { $0 })
        let shifted = Dictionary(uniqueKeysWithValues: sourceCells.map {
            ($0, segmentTransform(PolarMetricCellSegment(cell: $0, grid: source.grid)))
        })
        var targets: [PolarMetricGridCell: [PolarMetricGridCell]] = [:]
        for (cell, segment) in shifted {
            targets[cell] = PolarCellMove.targetCells(for: segment, grid: source.grid)
        }
        var workspace = source
        var resultSelection: [UUID: Set<PolarMetricGridCell>] = [:]
        for index in workspace.layers.indices where cellsByLayer[workspace.layers[index].id] != nil {
            var layer = workspace.layers[index]
            let moving = layer.polarCells.intersection(cellsByLayer[layer.id] ?? [])
            guard !moving.isEmpty else { continue }
            let movingValues = Dictionary(uniqueKeysWithValues: moving.compactMap { cell in
                layer.polarCellOverrides[cell].map { (cell, $0) }
            })
            layer.polarCells.subtract(moving)
            for cell in moving { layer.polarCellOverrides.removeValue(forKey: cell) }
            var winners: [PolarMetricGridCell: PolarMetricGridCell] = [:]
            for old in moving.sorted(by: PolarCellMove.addressOrder) {
                for target in targets[old] ?? [] {
                    guard let current = winners[target] else { winners[target] = old; continue }
                    if PolarCellMove.isBetterWinner(old, than: current, for: target, shifted: shifted, grid: source.grid) {
                        winners[target] = old
                    }
                }
            }
            for target in winners.keys.sorted(by: PolarCellMove.addressOrder) {
                layer.polarCells.insert(target)
                layer.polarCellOverrides.removeValue(forKey: target)
                if let winner = winners[target], let actions = movingValues[winner] {
                    layer.polarCellOverrides[target] = actions
                }
            }
            resultSelection[layer.id] = Set(winners.keys)
            workspace.replaceLayer(layer, at: index)
        }
        return .init(workspace: workspace, cells: Set(resultSelection.values.flatMap { $0 }),
                     didHitBoundary: didHitBoundary, cellsByLayer: resultSelection)
    }
}

/// Session-only room fitting and diagnostic evidence. The contour is never
/// added to the workspace; all musical metadata passes through unchanged.
public enum SpatialRoomFit {
    public struct Result: Equatable, Sendable {
        public let factor: Double
        public let maximumFactor: Double
        public let transform: PolarCellMove.Result
    }
    public struct Warnings: Equatable, Sendable {
        public let outsideCells: Set<PolarMetricGridCell>
        public let narrowLayerNames: [String]
        public init(outsideCells: Set<PolarMetricGridCell>, narrowLayerNames: [String]) {
            self.outsideCells = outsideCells; self.narrowLayerNames = narrowLayerNames
        }
        public var messages: [String] {
            var values: [String] = []
            if !outsideCells.isEmpty { values.append("\(outsideCells.count) \(outsideCells.count == 1 ? "cell" : "cells") beyond the room contour") }
            values += narrowLayerNames.map { "\($0): zone narrower than a hand (10 cm)" }
            return values
        }
    }

    /// Captured bins intersecting the segment by bearing, including half a
    /// measured ray interval at either edge. Missing measurements add no bound.
    public static func wallMeters(over segment: PolarMetricCellSegment, contour: SpatialRoomContour) -> Double? {
        let geometry = contour.geometry, step = geometry.angleResolutionDegrees
        guard step.isFinite, step > 0, geometry.startAngleDegrees.isFinite, geometry.pointCount > 0 else { return nil }
        let last = min(geometry.pointCount, contour.nearestDistancesCentimeters.count) - 1
        let firstIndex = max(0, Int(ceil((segment.startBearingDegrees - step / 2 - geometry.startAngleDegrees) / step - 1e-9)))
        let lastIndex = min(last, Int(floor((segment.endBearingDegrees + step / 2 - geometry.startAngleDegrees) / step + 1e-9)))
        guard firstIndex <= lastIndex else { return nil }
        return (firstIndex...lastIndex).compactMap { contour.nearestDistancesCentimeters[$0] }.min().map { Double($0) / 100 }
    }

    /// Closing of inward gaps narrower than one hand at the surrounding
    /// wall. Only a bracketed dip is bridged; wide walls and open edges stay.
    /// This is fit evidence, never a replacement for the captured raw scan.
    public static func fittingContour(_ contour: SpatialRoomContour) -> SpatialRoomContour {
        let values = contour.nearestDistancesCentimeters
        let step = contour.geometry.angleResolutionDegrees * Double.pi / 180
        guard values.count >= 3, step.isFinite, step > 0 else { return contour }
        var result = values
        for left in 0..<(values.count - 2) {
            guard let a = values[left] else { continue }
            for right in (left + 2)..<values.count {
                guard let b = values[right] else { continue }
                let shoulder = min(a, b)
                guard Double(shoulder) * Double(right - left) * step < 10 else { continue }
                for index in (left + 1)..<right {
                    if let value = result[index], value < shoulder { result[index] = shoulder }
                }
            }
        }
        if let drawn = contour.drawnDistancesCentimeters {
            for index in result.indices where drawn.indices.contains(index) {
                if let bound = drawn[index] { result[index] = min(result[index] ?? bound, bound) }
            }
        }
        return .init(geometry: contour.geometry, nearestDistancesCentimeters: result,
            spreadCentimeters: contour.spreadCentimeters, drawnDistancesCentimeters: contour.drawnDistancesCentimeters)
    }

    public static func applying(to source: SpatialInstrumentWorkspace, contour: SpatialRoomContour,
                                marginCentimeters: Double = 10) -> Result {
        let contour = fittingContour(contour)
        let all = Set(source.layers.flatMap(\.polarCells))
        let unchanged = Result(factor: 1, maximumFactor: 1,
            transform: .init(workspace: source, cells: all, didHitBoundary: false))
        guard !all.isEmpty else { return unchanged }
        let geometry = contour.geometry
        let step = geometry.angleResolutionDegrees
        guard step.isFinite, step > 0, geometry.startAngleDegrees.isFinite else { return unchanged }
        let count = min(geometry.pointCount, contour.nearestDistancesCentimeters.count)
        guard count > 0 else { return unchanged }
        let margin = marginCentimeters.isFinite ? max(0, marginCentimeters) / 100 : 0.1
        var walls = contour.nearestDistancesCentimeters.prefix(count).map { $0.map { Double($0) / 100 } }
        let known = walls.indices.filter { walls[$0] != nil }
        guard !known.isEmpty else { return unchanged }
        // Only bracketed gaps are bridged. An unmeasured edge is not evidence
        // for a wall. Linear interpolation cannot overshoot either neighbour.
        for pair in zip(known, known.dropFirst()) where pair.1 > pair.0 + 1 {
            let left = walls[pair.0]!, right = walls[pair.1]!
            for i in (pair.0 + 1)..<pair.1 {
                walls[i] = left + (right - left) * Double(i - pair.0) / Double(pair.1 - pair.0)
            }
        }
        // Conservative lower envelope: slope <= one metre per metre of wall
        // arc. A near single beam becomes a hand-wide rounded indentation;
        // raising it with a median would cross the measured obstacle.
        for i in 1..<count {
            if let previous = walls[i - 1], let current = walls[i] {
                walls[i] = min(current, previous + max(0.1, min(previous, current)) * step * .pi / 180)
            }
        }
        if count > 1 {
            for i in stride(from: count - 2, through: 0, by: -1) {
                if let next = walls[i + 1], let current = walls[i] {
                    walls[i] = min(current, next + max(0.1, min(next, current)) * step * .pi / 180)
                }
            }
        }
        func indices(_ segment: PolarMetricCellSegment) -> ClosedRange<Int>? {
            let lo = max(0, Int(ceil((segment.startBearingDegrees - step / 2 - geometry.startAngleDegrees) / step - 1e-9)))
            let hi = min(count - 1, Int(floor((segment.endBearingDegrees + step / 2 - geometry.startAngleDegrees) / step + 1e-9)))
            return lo <= hi ? lo...hi : nil
        }
        var outer = Array(repeating: 0.0, count: count)
        for cell in all {
            let segment = PolarMetricCellSegment(cell: cell, grid: source.grid)
            if let range = indices(segment) {
                for i in range { outer[i] = max(outer[i], segment.outerRadiusMeters) }
            }
        }
        var factors = Array(repeating: 1.0, count: count)
        for i in factors.indices where outer[i] > 0 {
            if let wall = walls[i] {
                // The existing editor play range is 2 m. Expansion never
                // creates a second, larger range just for this operation.
                factors[i] = max(0, min(2, wall - margin)) / outer[i]
            }
        }
        func factor(_ segment: PolarMetricCellSegment) -> Double {
            guard let range = indices(segment) else { return 1 }
            return range.map { factors[$0] }.min() ?? 1
        }
        let scales = all.map { factor(.init(cell: $0, grid: source.grid)) }
        let minimum = scales.min() ?? 1, maximum = scales.max() ?? 1
        guard scales.contains(where: { abs($0 - 1) > 1e-9 }) else { return unchanged }
        let transformed = PolarCellTransform.rasterizing(
            cellsByLayer: Dictionary(uniqueKeysWithValues: source.layers.map { ($0.id, $0.polarCells) }),
            to: source, didHitBoundary: false) { segment in
                PolarCellTransform(radialScale: max(1e-12, factor(segment))).segment(segment)
            }
        return .init(factor: minimum, maximumFactor: maximum, transform: transformed)
    }

    public enum Failure: Error {
        case dormantOverrideCollision
        /// Shaped surfaces are placed by their own geometry; a fit that would change anything refuses instead of ignoring them.
        case surfaceLayersCannotBeFitted
    }

    public struct DocumentResult: Sendable {
        public let document: InstrumentDocument
        public let minimumFactor: Double
        public let maximumFactor: Double
        public let mergedCells: Int
    }

    /// Fit the authoritative 1 cm × 0.5° lattice. The editor projection must
    /// never choose between fine overrides or rotate a musical assignment.
    public static func applying(to source: InstrumentDocument, contour: SpatialRoomContour,
                                marginCentimeters: Double = 10) throws -> DocumentResult {
        let contour = fittingContour(contour)
        var outer = Array(repeating: 0.0, count: 361)
        for layer in source.spatial.layers {
            for cell in layer.isSurfaceBacked ? layer.surfaces.flatMap(\.cells) : Array(layer.cells) {
                outer[cell.sector] = max(outer[cell.sector], Double(cell.ring + 1) / 100)
            }
        }
        let margin = marginCentimeters.isFinite ? max(0, marginCentimeters) / 100 : 0.1
        let step = contour.geometry.angleResolutionDegrees
        let count = min(contour.geometry.pointCount, contour.nearestDistancesCentimeters.count)
        var walls = Array<Double?>(repeating: nil, count: 361)
        if step.isFinite, step > 0, contour.geometry.startAngleDegrees.isFinite, count > 0 {
            let known = (0..<count).compactMap { i -> (Double, Double)? in
                guard let distance = contour.nearestDistancesCentimeters[i] else { return nil }
                return (contour.geometry.startAngleDegrees + Double(i) * step, Double(distance) / 100)
            }
            var cursor = 0
            for tick in 0...360 {
                let bearing = PolarDeviceLattice.bearingDegrees(forTick: tick)
                while cursor + 1 < known.count && known[cursor + 1].0 < bearing { cursor += 1 }
                if cursor < known.count, abs(known[cursor].0 - bearing) < 1e-9 { walls[tick] = known[cursor].1 }
                else if cursor + 1 < known.count, bearing >= known[cursor].0, bearing <= known[cursor + 1].0 {
                    let left = known[cursor], right = known[cursor + 1]
                    walls[tick] = left.1 + (right.1 - left.1) * (bearing - left.0) / (right.0 - left.0)
                }
            }
            // Include every measured beam in its nearest 0.5° bin. Thus a
            // non-aligned capture cannot hide a narrow obstacle by interpolation.
            for (bearing, distance) in known {
                let tick = Int(((bearing + 90) * 2).rounded())
                if (0...360).contains(tick) { walls[tick] = min(walls[tick] ?? distance, distance) }
            }
        }
        var factors = outer.indices.map { tick -> Double in
            guard outer[tick] > 0, let wall = walls[tick] else { return 1 }
            return max(0, min(2, wall - margin)) / outer[tick]
        }
        // A zone uses circular bands, not one independent staircase per
        // half-degree ray. Split where the set of musical layers changes and
        // at most every 30 degrees; every band takes its most restrictive wall.
        var signatures = Array(repeating: [Int](), count: 361)
        for (index, layer) in source.spatial.layers.enumerated() {
            for tick in Set((layer.isSurfaceBacked ? layer.surfaces.flatMap(\.cells) : Array(layer.cells)).map(\.sector)) { signatures[tick].append(index) }
        }
        var first = 0
        while first < 361 {
            var end = first + 1
            while end < min(361, first + 60), signatures[end] == signatures[first],
                  (walls[end] != nil) == (walls[first] != nil) { end += 1 }
            if walls[first] != nil, let target = (first..<end).filter({ outer[$0] > 0 })
                .map({ outer[$0] * factors[$0] }).min() {
                for tick in first..<end where outer[tick] > 0 { factors[tick] = target / outer[tick] }
            }
            first = end
        }
        let used = outer.indices.filter { outer[$0] > 0 }.map { factors[$0] }
        guard used.contains(where: { abs($0 - 1) > 1e-9 }) else {
            return .init(document: source, minimumFactor: 1, maximumFactor: 1, mergedCells: 0)
        }
        guard !source.spatial.layers.contains(where: \.isSurfaceBacked) else { throw Failure.surfaceLayersCannotBeFitted }
        var result = source, merged = 0
        let layers = try source.spatial.layers.map { old -> SpatialDocumentLayer in
            var winners: [PolarDeviceLattice: PolarDeviceLattice] = [:]
            // Whole radial intervals are filled when enlarged. On compression
            // nearer source addresses win deterministically; report every merge.
            for cell in old.cells {
                let f = factors[cell.sector]
                if abs(f - 1) < 1e-9 { winners[cell] = cell; continue }
                let upper = max(1, min(199, Int(floor(Double(cell.ring + 1) * f + 1e-9)) - 1))
                let lower = min(upper, max(1, Int(floor(Double(cell.ring) * f + 1e-9))))
                for ring in lower...upper {
                    let target = PolarDeviceLattice(ring: ring, sector: cell.sector)!
                    if let current = winners[target] {
                        merged += 1
                        if cell.ring < current.ring { winners[target] = cell }
                    } else { winners[target] = cell }
                }
            }
            // Dormant authoring values are metadata, not playable geometry.
            // Keep them byte-for-byte; never let a fit silently activate one.
            var overrides = old.cellOverrides.filter { !old.cells.contains($0.key) }
            guard overrides.keys.allSatisfy({ winners[$0] == nil }) else { throw Failure.dormantOverrideCollision }
            for (target, original) in winners {
                if let actions = old.cellOverrides[original] { overrides[target] = actions }
            }
            return old.replacingGeometry(cells: Set(winners.keys), overrides: overrides)
        }
        result.spatial = try source.spatial.replacingLayers(layers)
        return .init(document: result, minimumFactor: used.min() ?? 1, maximumFactor: used.max() ?? 1, mergedCells: merged)
    }

    public static func warnings(in workspace: SpatialInstrumentWorkspace, contour: SpatialRoomContour?,
                                toleranceCentimeters: UInt16) -> Warnings {
        guard let rawContour = contour else { return .init(outsideCells: [], narrowLayerNames: []) }
        let contour = fittingContour(rawContour)
        var outside: Set<PolarMetricGridCell> = [], narrow: [String] = []
        for layer in workspace.layers {
            for cell in layer.polarCells {
                let segment = PolarMetricCellSegment(cell: cell, grid: workspace.grid)
                if let wall = wallMeters(over: segment, contour: contour),
                   segment.outerRadiusMeters > max(0, wall - Double(toleranceCentimeters) / 100) + 1e-9 { outside.insert(cell) }
            }
            if let bounds = PolarCellTransform.bounds(cells: layer.polarCells, grid: workspace.grid) {
                let arc = bounds.midpoint.radiusMeters * (bounds.endBearingDegrees - bounds.startBearingDegrees) * .pi / 180
                if bounds.radialHeightMeters < 0.1 - 1e-9 || arc < 0.1 - 1e-9 { narrow.append(layer.name) }
            }
        }
        return .init(outsideCells: outside, narrowLayerNames: narrow)
    }
}

/// Stabile AU-Komponentenkennung an der räumlichen Routinggrenze.
public struct SpatialAudioUnitIdentity: Codable, Hashable, Sendable {
    public var componentType: UInt32
    public var componentSubType: UInt32
    public var componentManufacturer: UInt32

    public init(componentType: UInt32, componentSubType: UInt32, componentManufacturer: UInt32) {
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
    }
}

public struct SpatialAudioUnitParameterTarget: Codable, Hashable, Sendable {
    public var stripID: UUID
    public var component: SpatialAudioUnitIdentity
    public var address: UInt64
    /// Herstellerkennung als zweite, menschenlesbare Prüfkante. Die Adresse
    /// bleibt autoritativ; bei Widerspruch wird nie still neu zugeordnet.
    public var identifier: String
    public var displayName: String

    public init(component: SpatialAudioUnitIdentity, address: UInt64, identifier: String, displayName: String, stripID: UUID) {
        self.stripID = stripID
        self.component = component
        self.address = address
        self.identifier = identifier
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey { case stripID, component, address, identifier, displayName }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stripID = try values.decodeIfPresent(UUID.self, forKey: .stripID) ?? SpatialRoutingTarget.missingStripID
        component = try values.decode(SpatialAudioUnitIdentity.self, forKey: .component)
        address = try values.decode(UInt64.self, forKey: .address)
        identifier = try values.decode(String.self, forKey: .identifier)
        displayName = try values.decode(String.self, forKey: .displayName)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if encoder.userInfo[SpatialRoutingTarget.legacyWireKey] as? Bool != true { try values.encode(stripID, forKey: .stripID) }
        try values.encode(component, forKey: .component)
        try values.encode(address, forKey: .address)
        try values.encode(identifier, forKey: .identifier)
        try values.encode(displayName, forKey: .displayName)
    }
}

public enum SpatialRoutingDestination: Equatable, Sendable {
    case audioUnit
    case midi
    case other
}

extension SpatialRoutingTarget {
    /// Wire-only compatibility. Live AU targets always carry a concrete ID.
    public static let missingStripID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    public static let legacyWireKey = CodingUserInfoKey(rawValue: "planarium.legacyTargetWire")!
    private enum Wire: Codable {
        case midiEffectParameter(stripID: UUID, slotID: UUID, parameter: ArpeggiatorModulationTarget)
        case audioUnitParameter(SpatialAudioUnitParameterTarget)
        case audioUnitNote(channel: UInt8, stripID: UUID?)
        case audioUnitAllNotesOff(channel: UInt8, stripID: UUID?)
        case audioUnitCC(channel: UInt8, controller: UInt8, stripID: UUID)
        case audioUnitProgramChange(channel: UInt8, stripID: UUID)
        case audioUnitPitchBend(channel: UInt8, stripID: UUID)
        case audioUnitChannelPressure(channel: UInt8, stripID: UUID)
        case midiNote(channel: UInt8)
        case midiCC(channel: UInt8, controller: UInt8)
        case midiProgramChange(channel: UInt8)
        case midiPitchBend(channel: UInt8)
        case midiChannelPressure(channel: UInt8)
        case midiAllNotesOff(channel: UInt8)
        case sceneSwitch(action: SpatialSceneSwitchAction, dwellSeconds: Double)
        case releaseLayer(layerID: UUID)
        case boolean(name: String)
    }
    public init(from decoder: Decoder) throws {
        switch try Wire(from: decoder) {
        case .midiEffectParameter(let id, let slot, let parameter): self = .midiEffectParameter(stripID: id, slotID: slot, parameter: parameter)
        case .audioUnitParameter(let value): self = .audioUnitParameter(value)
        case .audioUnitNote(let channel, let id): self = .audioUnitNote(channel: channel, stripID: id ?? Self.missingStripID)
        case .audioUnitAllNotesOff(let channel, let id): self = .audioUnitAllNotesOff(channel: channel, stripID: id ?? Self.missingStripID)
        case .audioUnitCC(let channel, let controller, let id): self = .audioUnitCC(channel: channel, controller: controller, stripID: id)
        case .audioUnitProgramChange(let channel, let id): self = .audioUnitProgramChange(channel: channel, stripID: id)
        case .audioUnitPitchBend(let channel, let id): self = .audioUnitPitchBend(channel: channel, stripID: id)
        case .audioUnitChannelPressure(let channel, let id): self = .audioUnitChannelPressure(channel: channel, stripID: id)
        case .midiNote(let channel): self = .midiNote(channel: channel)
        case .midiCC(let channel, let controller): self = .midiCC(channel: channel, controller: controller)
        case .midiProgramChange(let channel): self = .midiProgramChange(channel: channel)
        case .midiPitchBend(let channel): self = .midiPitchBend(channel: channel)
        case .midiChannelPressure(let channel): self = .midiChannelPressure(channel: channel)
        case .midiAllNotesOff(let channel): self = .midiAllNotesOff(channel: channel)
        case .sceneSwitch(let action, let dwell): self = .sceneSwitch(action: action, dwellSeconds: dwell)
        case .releaseLayer(let id): self = .releaseLayer(layerID: id)
        case .boolean(let name): self = .boolean(name: name)
        }
    }
    public func encode(to encoder: Encoder) throws {
        if encoder.userInfo[Self.legacyWireKey] as? Bool == true {
            switch self {
            case .audioUnitNote(let channel, _), .audioUnitAllNotesOff(let channel, _):
                var root = encoder.container(keyedBy: LegacyKeys.self)
                var payload = root.nestedContainer(keyedBy: LegacyKeys.self, forKey: {
                    if case .audioUnitNote = self { return .audioUnitNote }; return .audioUnitAllNotesOff
                }())
                try payload.encode(channel, forKey: .channel)
                return
            default: break
            }
        }
        let value: Wire
        switch self {
        case .midiEffectParameter(let id, let slot, let parameter): value = .midiEffectParameter(stripID: id, slotID: slot, parameter: parameter)
        case .audioUnitParameter(let target): value = .audioUnitParameter(target)
        case .audioUnitNote(let channel, let id): value = .audioUnitNote(channel: channel, stripID: id)
        case .audioUnitAllNotesOff(let channel, let id): value = .audioUnitAllNotesOff(channel: channel, stripID: id)
        case .audioUnitCC(let channel, let controller, let id): value = .audioUnitCC(channel: channel, controller: controller, stripID: id)
        case .audioUnitProgramChange(let channel, let id): value = .audioUnitProgramChange(channel: channel, stripID: id)
        case .audioUnitPitchBend(let channel, let id): value = .audioUnitPitchBend(channel: channel, stripID: id)
        case .audioUnitChannelPressure(let channel, let id): value = .audioUnitChannelPressure(channel: channel, stripID: id)
        case .midiNote(let channel): value = .midiNote(channel: channel)
        case .midiCC(let channel, let controller): value = .midiCC(channel: channel, controller: controller)
        case .midiProgramChange(let channel): value = .midiProgramChange(channel: channel)
        case .midiPitchBend(let channel): value = .midiPitchBend(channel: channel)
        case .midiChannelPressure(let channel): value = .midiChannelPressure(channel: channel)
        case .midiAllNotesOff(let channel): value = .midiAllNotesOff(channel: channel)
        case .sceneSwitch(let action, let dwell): value = .sceneSwitch(action: action, dwellSeconds: dwell)
        case .releaseLayer(let id): value = .releaseLayer(layerID: id)
        case .boolean(let name): value = .boolean(name: name)
        }
        try value.encode(to: encoder)
    }
    private enum LegacyKeys: String, CodingKey { case audioUnitNote, audioUnitAllNotesOff, channel }
}

/// A scene is an ordered, named snapshot of the audible layer set.  Control
/// layers are deliberately excluded by `SpatialInstrumentWorkspace`.
public struct SpatialScene: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var activeLayerIDs: Set<UUID>

    private enum CodingKeys: String, CodingKey { case id, name, activeLayerIDs }

    public init(id: UUID = UUID(), name: String, activeLayerIDs: Set<UUID>) {
        self.id = id
        self.name = name
        self.activeLayerIDs = activeLayerIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        activeLayerIDs = try values.decode(Set<UUID>.self, forKey: .activeLayerIDs)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(activeLayerIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .activeLayerIDs)
    }
}

public enum SpatialSceneSwitchAction: Codable, Hashable, Sendable {
    case next
    case previous
    case scene(UUID)
}

/// Gleichrangige Ziele des räumlichen Instruments.
public enum SpatialRoutingTarget: Codable, Hashable, Sendable {
    case midiEffectParameter(stripID: UUID, slotID: UUID, parameter: ArpeggiatorModulationTarget)
    case audioUnitParameter(SpatialAudioUnitParameterTarget)
    /// Noten ausschließlich an das im Kanalzug geladene AU-Instrument.
    case audioUnitNote(channel: UInt8, stripID: UUID)
    case audioUnitAllNotesOff(channel: UInt8, stripID: UUID)
    /// MIDI controls exclusively to the instrument of the selected strip.
    case audioUnitCC(channel: UInt8, controller: UInt8, stripID: UUID)
    case audioUnitProgramChange(channel: UInt8, stripID: UUID)
    case audioUnitPitchBend(channel: UInt8, stripID: UUID)
    case audioUnitChannelPressure(channel: UInt8, stripID: UUID)
    /// Notes exclusively to the selected CoreMIDI output.
    case midiNote(channel: UInt8)
    case midiCC(channel: UInt8, controller: UInt8)
    case midiProgramChange(channel: UInt8)
    case midiPitchBend(channel: UInt8)
    case midiChannelPressure(channel: UInt8)
    case midiAllNotesOff(channel: UInt8)
    /// A measured control-cell.  It is consumed by the runtime and never sent
    /// to MIDI or an audio unit.
    case sceneSwitch(action: SpatialSceneSwitchAction, dwellSeconds: Double)
    case releaseLayer(layerID: UUID)
    case boolean(name: String)

    public var isProgramChange: Bool {
        switch self { case .midiProgramChange, .audioUnitProgramChange: return true; default: return false }
    }
    public var controllerNumber: UInt8? {
        switch self { case .midiCC(_, let cc), .audioUnitCC(_, let cc, _): return cc; default: return nil }
    }
    public func withControllerNumber(_ cc: UInt8) -> Self {
        switch self {
        case .midiCC(let ch, _): return .midiCC(channel: ch, controller: cc)
        case .audioUnitCC(let ch, _, let id): return .audioUnitCC(channel: ch, controller: cc, stripID: id)
        default: return self
        }
    }
    /// Retarget the same MIDI message and values between a strip and CoreMIDI.
    public func retargeted(to destination: SpatialRoutingDestination, stripID: UUID) -> Self {
        if self.destination == destination {
            return destination == .audioUnit ? withStripID(stripID) : self
        }
        let channel = midiChannel ?? 0
        switch (self, destination) {
        case (.midiCC(_, let cc), .audioUnit): return .audioUnitCC(channel: channel, controller: cc, stripID: stripID)
        case (.midiProgramChange, .audioUnit): return .audioUnitProgramChange(channel: channel, stripID: stripID)
        case (.midiPitchBend, .audioUnit): return .audioUnitPitchBend(channel: channel, stripID: stripID)
        case (.midiChannelPressure, .audioUnit): return .audioUnitChannelPressure(channel: channel, stripID: stripID)
        case (.midiAllNotesOff, .audioUnit): return .audioUnitAllNotesOff(channel: channel, stripID: stripID)
        case (.audioUnitCC(_, let cc, _), .midi): return .midiCC(channel: channel, controller: cc)
        case (.audioUnitProgramChange, .midi): return .midiProgramChange(channel: channel)
        case (.audioUnitPitchBend, .midi): return .midiPitchBend(channel: channel)
        case (.audioUnitChannelPressure, .midi): return .midiChannelPressure(channel: channel)
        case (.audioUnitAllNotesOff, .midi): return .midiAllNotesOff(channel: channel)
        case (_, .audioUnit): return .audioUnitNote(channel: channel, stripID: stripID)
        case (_, .midi): return .midiNote(channel: channel)
        case (_, .other): return self
        }
    }

    public var isLayerControl: Bool {
        switch self {
        case .sceneSwitch, .releaseLayer: return true
        default: return false
        }
    }

    public var stripID: UUID? {
        switch self {
        case .audioUnitNote(_, let id), .audioUnitAllNotesOff(_, let id), .audioUnitCC(_, _, let id),
             .audioUnitProgramChange(_, let id), .audioUnitPitchBend(_, let id), .audioUnitChannelPressure(_, let id): return id
        case .midiEffectParameter(let id, _, _): return id
        case .audioUnitParameter(let target): return target.stripID
        default: return nil
        }
    }
    public func withStripID(_ id: UUID) -> Self {
        switch self {
        case .audioUnitNote(let channel, _): return .audioUnitNote(channel: channel, stripID: id)
        case .audioUnitAllNotesOff(let channel, _): return .audioUnitAllNotesOff(channel: channel, stripID: id)
        case .audioUnitCC(let ch, let cc, _): return .audioUnitCC(channel: ch, controller: cc, stripID: id)
        case .audioUnitProgramChange(let ch, _): return .audioUnitProgramChange(channel: ch, stripID: id)
        case .audioUnitPitchBend(let ch, _): return .audioUnitPitchBend(channel: ch, stripID: id)
        case .audioUnitChannelPressure(let ch, _): return .audioUnitChannelPressure(channel: ch, stripID: id)
        case .midiEffectParameter(_, let slot, let parameter): return .midiEffectParameter(stripID: id, slotID: slot, parameter: parameter)
        case .audioUnitParameter(var target): target.stripID = id; return .audioUnitParameter(target)
        default: return self
        }
    }

    public var destination: SpatialRoutingDestination {
        switch self {
        case .audioUnitParameter, .audioUnitNote, .audioUnitAllNotesOff, .audioUnitCC,
             .audioUnitProgramChange, .audioUnitPitchBend, .audioUnitChannelPressure:
            return .audioUnit
        case .midiNote, .midiCC, .midiProgramChange, .midiPitchBend, .midiChannelPressure, .midiAllNotesOff:
            return .midi
        case .midiEffectParameter, .sceneSwitch, .releaseLayer, .boolean:
            return .other
        }
    }

    public var midiChannel: UInt8? {
        switch self {
        case .audioUnitCC(let channel, _, _), .audioUnitProgramChange(let channel, _),
             .audioUnitPitchBend(let channel, _), .audioUnitChannelPressure(let channel, _),
             .audioUnitNote(let channel, _), .audioUnitAllNotesOff(let channel, _): return channel
        case .midiNote(let channel): return channel
        case .midiCC(let channel, _): return channel
        case .midiProgramChange(let channel): return channel
        case .midiPitchBend(let channel): return channel
        case .midiChannelPressure(let channel): return channel
        case .midiAllNotesOff(let channel): return channel
        case .midiEffectParameter, .audioUnitParameter, .sceneSwitch, .releaseLayer, .boolean:
            return nil
        }
    }

    public func withMIDIChannel(_ channel: UInt8) -> SpatialRoutingTarget {
        switch self {
        case .midiEffectParameter: return self
        case .audioUnitParameter(let parameter):
            return .audioUnitParameter(parameter)
        case .audioUnitNote(_, let id):
            return .audioUnitNote(channel: channel, stripID: id)
        case .audioUnitAllNotesOff(_, let id):
            return .audioUnitAllNotesOff(channel: channel, stripID: id)
        case .audioUnitCC(_, let cc, let id): return .audioUnitCC(channel: channel, controller: cc, stripID: id)
        case .audioUnitProgramChange(_, let id): return .audioUnitProgramChange(channel: channel, stripID: id)
        case .audioUnitPitchBend(_, let id): return .audioUnitPitchBend(channel: channel, stripID: id)
        case .audioUnitChannelPressure(_, let id): return .audioUnitChannelPressure(channel: channel, stripID: id)
        case .midiNote:
            return .midiNote(channel: channel)
        case .midiCC(_, let controller):
            return .midiCC(channel: channel, controller: controller)
        case .midiProgramChange: return .midiProgramChange(channel: channel)
        case .midiPitchBend:
            return .midiPitchBend(channel: channel)
        case .midiChannelPressure:
            return .midiChannelPressure(channel: channel)
        case .midiAllNotesOff:
            return .midiAllNotesOff(channel: channel)
        case .sceneSwitch(let action, let dwellSeconds):
            return .sceneSwitch(action: action, dwellSeconds: dwellSeconds)
        case .releaseLayer: return self
        case .boolean(let name):
            return .boolean(name: name)
        }
    }
}

public enum SpatialScale: String, Codable, CaseIterable, Sendable {
    case chromatic
    case major
    case naturalMinor
    case majorPentatonic
    case minorPentatonic

    public var semitoneOffsets: [Int] {
        switch self {
        case .chromatic: return Array(0..<12)
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .naturalMinor: return [0, 2, 3, 5, 7, 8, 10]
        case .majorPentatonic: return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        }
    }
}

/// English musical note names for the interface. MIDI note numbers remain the
/// canonical internal representation.
public enum MIDINoteName {
    private static let pitchClasses = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    public static func pitchClassName(for note: Int) -> String {
        let clamped = min(max(note, 0), 127)
        return pitchClasses[clamped % 12]
    }

    public static func displayName(for note: Int) -> String {
        let clamped = min(max(note, 0), 127)
        return "\(pitchClassName(for: clamped))\(clamped / 12 - 1)"
    }
}

public enum SpatialChordPreset: String, Codable, CaseIterable, Sendable {
    case major, minor, power, diminished, augmented, suspended2, suspended4
    case dominant7, major7, minor7

    public var displayName: String {
        switch self {
        case .major: return "Major"
        case .minor: return "Minor"
        case .power: return "Power Chord"
        case .diminished: return "Diminished"
        case .augmented: return "Augmented"
        case .suspended2: return "Sus2"
        case .suspended4: return "Sus4"
        case .dominant7: return "Dominant 7"
        case .major7: return "Major 7"
        case .minor7: return "Minor 7"
        }
    }

    public var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .power: return [0, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .suspended2: return [0, 2, 7]
        case .suspended4: return [0, 5, 7]
        case .dominant7: return [0, 4, 7, 10]
        case .major7: return [0, 4, 7, 11]
        case .minor7: return [0, 3, 7, 10]
        }
    }

    public func notes(root: Int) -> [Int] {
        intervals.map { min(max(root + $0, 0), 127) }
    }
}

public enum SpatialValueCurve: String, Codable, CaseIterable, Sendable {
    case linear
    case easeIn
    case easeOut
}

/// Shared pitches on a musical transition; old documents default to Keep.
public enum SpatialCommonNotes: String, Codable, CaseIterable, Sendable {
    case keep
    case retrigger
}

public enum SpatialNoteTransition: Codable, Equatable, Hashable, Sendable {
    case retrigger
    case legato
    case overlap(milliseconds: Double)
    /// Ton/Akkord bleibt nach Verlassen der Fläche stehen und wird erst
    /// durch den nächsten gehaltenen Klang desselben Kanals ersetzt.
    case holdUntilNext
    /// Each measured cell entry flips its own persistent note ownership.
    case toggle
}

/// Wiederholbare Assistentendefinition. Werte werden daraus am Raster neu
/// berechnet; eine Rasteränderung skaliert daher keine Farben oder MIDI-Werte.
public enum SpatialValueProgram: Codable, Equatable, Sendable {
    case programChange(SpatialProgramChange)
    case constant(Double)
    case continuous(minimum: Double, maximum: Double, directionDegrees: Double, curve: SpatialValueCurve)
    case scale(rootMIDINote: Int, lowestMIDINote: Int, highestMIDINote: Int, scale: SpatialScale,
               directionDegrees: Double, ascending: Bool, transition: SpatialNoteTransition)
    case randomScale(rootMIDINote: Int, lowestMIDINote: Int, highestMIDINote: Int, scale: SpatialScale,
                     seed: UInt64, transition: SpatialNoteTransition)
    case chord(notes: [Int], velocity: UInt8, transition: SpatialNoteTransition)
    case singleNote(note: Int, velocity: UInt8, transition: SpatialNoteTransition)

    public var supportsToggle: Bool {
        switch self {
        case .singleNote, .chord: return true
        case .scale, .randomScale, .constant, .continuous, .programChange: return false
        }
    }

    /// Compatibility normalization at the load/editor boundary.
    public var replacingUnsupportedToggle: Self {
        switch self {
        case let .scale(root, low, high, scale, direction, ascending, .toggle):
            return .scale(rootMIDINote: root, lowestMIDINote: low, highestMIDINote: high,
                          scale: scale, directionDegrees: direction, ascending: ascending, transition: .retrigger)
        case let .randomScale(root, low, high, scale, seed, .toggle):
            return .randomScale(rootMIDINote: root, lowestMIDINote: low, highestMIDINote: high,
                                scale: scale, seed: seed, transition: .retrigger)
        default: return self
        }
    }
}

public struct SpatialRouting: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var target: SpatialRoutingTarget
    /// Chord spelling independent of inversion bass; absent means the legacy lowest note.
    public var chordRootMIDINote: Int?
    public var program: SpatialValueProgram

    public init(id: UUID = UUID(), target: SpatialRoutingTarget, program: SpatialValueProgram, chordRootMIDINote: Int? = nil) {
        self.id = id
        self.target = target
        self.program = program
        self.chordRootMIDINote = chordRootMIDINote
    }
}

public enum SpatialCellValue: Codable, Equatable, Sendable {
    case programChange(SpatialProgramChange)
    case scalar(Double)
    case note(number: Int, velocity: UInt8)
    case chord(notes: [Int], velocity: UInt8)
    case boolean(Bool)
    case sceneSwitch(action: SpatialSceneSwitchAction)
    case releaseLayer(layerID: UUID)
}

public struct SpatialCellAction: Codable, Equatable, Sendable {
    public var target: SpatialRoutingTarget
    public var value: SpatialCellValue

    public init(target: SpatialRoutingTarget, value: SpatialCellValue) {
        self.target = target
        self.value = value
    }
}

public struct SpatialInstrumentLayer: Identifiable, Codable, Equatable, Sendable {
    /// Nil uses the existing sum MIDI output. Explicit targets are per layer,
    /// shared by notes and Controls, and independent from MIDI clock targets.
    public var midiTarget: InstrumentMIDITarget? = nil
    public var id: UUID
    public var name: String
    public var color: SpatialLayerColor
    /// Nur Darstellung. Eine unsichtbare aktive Ebene spielt weiter.
    public var isVisible: Bool
    /// Klang/MIDI. Unabhängig von `isVisible`.
    public var isActive: Bool
    public var isLocked: Bool
    public var isSoloed: Bool
    public var commonNotes: SpatialCommonNotes
    /// Profile-time protection after each accepted Toggle edge, per surface.
    public var toggleGuardSeconds: Double {
        didSet { toggleGuardSeconds = Self.normalizedToggleGuard(toggleGuardSeconds) }
    }
    public static let defaultToggleGuardSeconds = 0.5
    public static func normalizedToggleGuard(_ seconds: Double) -> Double {
        seconds.isFinite ? min(2, max(0, seconds)) : 0
    }
    public var polarCells: Set<PolarMetricGridCell>
    public var routings: [SpatialRouting]
    public var polarCellOverrides: [PolarMetricGridCell: [SpatialCellAction]]
    /// The document holds this layer as editable surfaces. Cells and routings above are only a
    /// read-only picture of them: the coarse cell editor never changes such a layer.
    public var isSurfaceBacked = false

    /// Nur für das Lesen eines Dokuments von vor dem polaren Cutover. Der
    /// Arbeitsbereich wandelt diesen Bestand beim Anlegen und beim Dekodieren um
    /// und leert ihn sofort; im laufenden Betrieb ist beides immer leer, und die
    /// Kodierung schreibt es nie.
    fileprivate var legacyCells: Set<MetricGridCell> = []
    fileprivate var legacyCellOverrides: [MetricGridCell: [SpatialCellAction]] = [:]

    public init(
        id: UUID = UUID(), name: String, color: SpatialLayerColor,
        isVisible: Bool = true, isActive: Bool = true, isLocked: Bool = false,
        isSoloed: Bool = false, polarCells: Set<PolarMetricGridCell> = [],
        routings: [SpatialRouting] = [],
        polarCellOverrides: [PolarMetricGridCell: [SpatialCellAction]] = [:],
        toggleGuardSeconds: Double = Self.defaultToggleGuardSeconds,
        commonNotes: SpatialCommonNotes = .keep,
        midiTarget: InstrumentMIDITarget? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isVisible = isVisible
        self.isActive = isActive
        self.isLocked = isLocked
        self.isSoloed = isSoloed
        self.commonNotes = commonNotes
        self.toggleGuardSeconds = Self.normalizedToggleGuard(toggleGuardSeconds)
        self.midiTarget = midiTarget
        self.polarCells = polarCells
        self.routings = routings
        self.polarCellOverrides = polarCellOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, isVisible, isActive, isLocked, isSoloed
        case cells, polarCells, routings, cellOverrides, polarCellOverrides
        case toggleGuardSeconds, commonNotes, midiTarget, surfaceBacked
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isSurfaceBacked = try values.decodeIfPresent(Bool.self, forKey: .surfaceBacked) ?? false
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        midiTarget = try values.decodeIfPresent(InstrumentMIDITarget.self, forKey: .midiTarget)
        color = try values.decode(SpatialLayerColor.self, forKey: .color)
        isVisible = try values.decode(Bool.self, forKey: .isVisible)
        isActive = try values.decode(Bool.self, forKey: .isActive)
        isLocked = try values.decode(Bool.self, forKey: .isLocked)
        isSoloed = try values.decode(Bool.self, forKey: .isSoloed)
        commonNotes = try values.decodeIfPresent(SpatialCommonNotes.self, forKey: .commonNotes) ?? .keep
        toggleGuardSeconds = Self.normalizedToggleGuard(try values.decodeIfPresent(Double.self, forKey: .toggleGuardSeconds) ?? 0)
        legacyCells = try values.decodeIfPresent(Set<MetricGridCell>.self, forKey: .cells) ?? []
        polarCells = try values.decodeIfPresent(Set<PolarMetricGridCell>.self, forKey: .polarCells) ?? []
        routings = try values.decode([SpatialRouting].self, forKey: .routings)
        legacyCellOverrides = try values.decodeIfPresent(
            [MetricGridCell: [SpatialCellAction]].self, forKey: .cellOverrides
        ) ?? [:]
        polarCellOverrides = try values.decodeIfPresent(
            [PolarMetricGridCell: [SpatialCellAction]].self,
            forKey: .polarCellOverrides
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(midiTarget, forKey: .midiTarget)
        try values.encode(color, forKey: .color)
        try values.encode(isVisible, forKey: .isVisible)
        try values.encode(isActive, forKey: .isActive)
        try values.encode(isLocked, forKey: .isLocked)
        try values.encode(isSoloed, forKey: .isSoloed)
        if commonNotes != .keep { try values.encode(commonNotes, forKey: .commonNotes) }
        if toggleGuardSeconds > 0 { try values.encode(toggleGuardSeconds, forKey: .toggleGuardSeconds) }
        try values.encode(polarCells, forKey: .polarCells)
        try values.encode(routings, forKey: .routings)
        try values.encode(polarCellOverrides, forKey: .polarCellOverrides)
        if isSurfaceBacked { try values.encode(true, forKey: .surfaceBacked) }
    }

    public mutating func setMIDIChannel(_ channel: UInt8) {
        for i in routings.indices {
            routings[i].target = routings[i].target.withMIDIChannel(channel)
        }
        for (cell, actions) in polarCellOverrides {
            var updated = actions
            for i in updated.indices {
                updated[i].target = updated[i].target.withMIDIChannel(channel)
            }
            polarCellOverrides[cell] = updated
        }
    }
}

/// Autoritativer räumlicher Instrumentzustand. Die Rasterweite gilt für das
/// Projekt; Ebenen tragen Masken und Zuordnungen, nicht eigene Raster.
public struct SpatialInstrumentWorkspace: Codable, Equatable, Sendable {
    public private(set) var grid: MetricSquareGrid
    public private(set) var layers: [SpatialInstrumentLayer]
    public private(set) var selectedLayerID: UUID
    /// Kanalzug-Chrom gehört zum Dokument, nicht zum Rechner.
    public private(set) var channelName: String
    public private(set) var channelColor: SpatialLayerColor
    /// Autoritative Zelltopologie. Darstellung und Auswertung lesen denselben
    /// Wert; Zellen der jeweils anderen Topologie werden nicht parallel aktiv.
    public private(set) var coordinateMode: MetricViewportCoordinateMode
    public private(set) var detectionConfiguration: DetectionConfiguration
    public private(set) var scenes: [SpatialScene]
    public private(set) var currentSceneID: UUID?

    public enum GridChange: Equatable, Sendable {
        case unchanged
        case changed
    }

    public init(
        grid: MetricSquareGrid = .quarterMeter,
        layers: [SpatialInstrumentLayer]? = nil,
        channelName: String = "PLANARIUM",
        channelColor: SpatialLayerColor = .blue,
        detectionConfiguration: DetectionConfiguration = .ownerDefaults,
        /// ⚠️ Überholt: Die Topologie ist ausschließlich polar; der Wert wird ignoriert.
        coordinateMode: MetricViewportCoordinateMode = .polar,
        /// Document projections keep the authoritative layer and routing IDs.
        preserveLayerStructure: Bool = false,
        scenes: [SpatialScene] = [], currentSceneID: UUID? = nil
    ) {
        let initial = layers?.isEmpty == false
            ? (preserveLayerStructure ? layers! : Self.splitMultiRoutingLayers(layers!))
            : [SpatialInstrumentLayer(name: "Layer 1", color: .orange)]
        self.grid = grid
        self.layers = initial
        self.selectedLayerID = initial[0].id
        self.channelName = channelName
        self.channelColor = channelColor
        self.coordinateMode = .polar
        self.detectionConfiguration = detectionConfiguration
        self.scenes = scenes
        self.currentSceneID = scenes.contains(where: { $0.id == currentSceneID }) ? currentSceneID : nil
        migrateLegacyCartesianCells()
    }

    private enum CodingKeys: String, CodingKey {
        case grid, layers, selectedLayerID, channelName, channelColor, coordinateMode, detectionConfiguration, scenes, currentSceneID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grid = try values.decodeIfPresent(MetricSquareGrid.self, forKey: .grid) ?? .halfMeter
        layers = try values.decode([SpatialInstrumentLayer].self, forKey: .layers)
        guard !layers.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .layers, in: values, debugDescription: "Ein Workspace braucht mindestens eine Ebene."
            )
        }
        let decodedSelection = try values.decodeIfPresent(UUID.self, forKey: .selectedLayerID)
        if let decodedSelection, layers.contains(where: { $0.id == decodedSelection }) {
            selectedLayerID = decodedSelection
        } else {
            selectedLayerID = layers[0].id
        }
        channelName = try values.decodeIfPresent(String.self, forKey: .channelName) ?? "PLANARIUM"
        channelColor = try values.decodeIfPresent(SpatialLayerColor.self, forKey: .channelColor) ?? .blue
        coordinateMode = .polar
        detectionConfiguration = try values.decodeIfPresent(DetectionConfiguration.self, forKey: .detectionConfiguration) ?? .legacyDefaults
        scenes = try values.decodeIfPresent([SpatialScene].self, forKey: .scenes) ?? []
        let decodedScene = try values.decodeIfPresent(UUID.self, forKey: .currentSceneID)
        currentSceneID = scenes.contains(where: { $0.id == decodedScene }) ? decodedScene : nil
        migrateLegacyCartesianCells()
        layers = Self.splitMultiRoutingLayers(layers)
        if !layers.contains(where: { $0.id == selectedLayerID }) {
            selectedLayerID = layers[0].id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(grid, forKey: .grid)
        try values.encode(layers, forKey: .layers)
        try values.encode(selectedLayerID, forKey: .selectedLayerID)
        try values.encode(channelName, forKey: .channelName)
        try values.encode(channelColor, forKey: .channelColor)
        try values.encode(detectionConfiguration, forKey: .detectionConfiguration)
        try values.encode(coordinateMode, forKey: .coordinateMode)
        try values.encode(scenes, forKey: .scenes)
        try values.encodeIfPresent(currentSceneID, forKey: .currentSceneID)
    }

    public mutating func setChannelName(_ name: String) {
        channelName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "PLANARIUM" : name
    }

    public mutating func setChannelColor(_ color: SpatialLayerColor) {
        channelColor = color
    }

    public mutating func setDetectionConfiguration(_ configuration: DetectionConfiguration) {
        detectionConfiguration = configuration
    }

    public var selectedLayer: SpatialInstrumentLayer {
        layers.first(where: { $0.id == selectedLayerID }) ?? layers[0]
    }

    public mutating func updateLayer(_ id: UUID, _ change: (inout SpatialInstrumentLayer) -> Void) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        change(&layers[index])
    }

    public var controlLayerIDs: Set<UUID> {
        Set(layers.compactMap { layer in
            layer.routings.contains { $0.target.isLayerControl } ? layer.id : nil
        })
    }

    public mutating func addScene(name: String? = nil) -> UUID {
        let scene = SpatialScene(name: name ?? "Scene \(scenes.count + 1)", activeLayerIDs: activeNonControlLayerIDs)
        scenes.append(scene)
        currentSceneID = scene.id
        return scene.id
    }

    public mutating func rememberCurrentScene() {
        guard let currentSceneID else { return }
        updateScene(currentSceneID)
    }

    public mutating func updateScene(_ id: UUID) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[index].activeLayerIDs = activeNonControlLayerIDs
    }

    public mutating func toggleSceneMembership(scene id: UUID, layer: UUID) {
        guard layers.contains(where: { $0.id == layer }), !controlLayerIDs.contains(layer),
              let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        if !scenes[index].activeLayerIDs.insert(layer).inserted { scenes[index].activeLayerIDs.remove(layer) }
    }

    public mutating func selectScene(_ id: UUID?) {
        guard let id, let scene = scenes.first(where: { $0.id == id }) else { currentSceneID = nil; return }
        currentSceneID = id
        let controls = controlLayerIDs
        for index in layers.indices {
            layers[index].isActive = controls.contains(layers[index].id) || scene.activeLayerIDs.contains(layers[index].id)
        }
    }

    public mutating func deleteScene(_ id: UUID) {
        scenes.removeAll { $0.id == id }
        if currentSceneID == id { currentSceneID = nil }
    }

    public mutating func renameScene(_ id: UUID, to name: String) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        scenes[index].name = trimmed.isEmpty ? "Scene" : trimmed
    }

    public mutating func moveScene(id: UUID, by offset: Int) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index + offset, 0), scenes.count - 1)
        guard index != destination else { return }
        scenes.swapAt(index, destination)
    }

    private var activeNonControlLayerIDs: Set<UUID> {
        let controls = controlLayerIDs
        return Set(layers.filter { $0.isActive && !controls.contains($0.id) }.map(\.id))
    }

    /// Haltewahl ist nur für diskrete Notenprogramme sinnvoll. Kontinuierliche
    /// und konstante Ebenen haben keine Note, die ein Ledger halten könnte.
    public var supportsNoteTransition: Bool {
        guard let program = selectedLayer.routings.first?.program else { return false }
        switch program {
        case .scale, .randomScale, .chord, .singleNote: return true
        case .constant, .continuous, .programChange: return false
        }
    }

    public var selectedNoteTransition: SpatialNoteTransition? {
        guard let program = selectedLayer.routings.first?.program else { return nil }
        switch program {
        case let .scale(_, _, _, _, _, _, transition),
             let .randomScale(_, _, _, _, _, transition),
             let .chord(_, _, transition):
            return transition
        case let .singleNote(_, _, transition): return transition
        case .constant, .continuous, .programChange:
            return nil
        }
    }

    /// Startwert des Noten-Popovers. Der Dokumentwert hat Vorrang; nur eine
    /// Ebene ohne Notenprogramm fällt auf den neutralen Anschlag zurück.
    public func popoverNoteTransitionStartValue() -> SpatialNoteTransition {
        selectedNoteTransition ?? .retrigger
    }

    /// Ändert den Übergang aller Notenrouten der angegebenen Ebenen. Andere
    /// Routings haben keinen Notenübergang und bleiben unverändert.
    public mutating func setNoteTransition(
        _ transition: SpatialNoteTransition,
        for layerIDs: Set<UUID>
    ) {
        for layerIndex in layers.indices where layerIDs.contains(layers[layerIndex].id) {
            for routingIndex in layers[layerIndex].routings.indices {
                switch layers[layerIndex].routings[routingIndex].program {
                case let .scale(root, lowest, highest, scale, direction, ascending, _):
                    layers[layerIndex].routings[routingIndex].program = .scale(
                        rootMIDINote: root, lowestMIDINote: lowest, highestMIDINote: highest,
                        scale: scale, directionDegrees: direction, ascending: ascending,
                        transition: transition == .toggle ? .retrigger : transition
                    )
                case let .randomScale(root, lowest, highest, scale, seed, _):
                    layers[layerIndex].routings[routingIndex].program = .randomScale(
                        rootMIDINote: root, lowestMIDINote: lowest, highestMIDINote: highest,
                        scale: scale, seed: seed, transition: transition == .toggle ? .retrigger : transition
                    )
                case let .chord(notes, velocity, _):
                    layers[layerIndex].routings[routingIndex].program = .chord(
                        notes: notes, velocity: velocity, transition: transition
                    )
                case let .singleNote(note, velocity, _):
                    layers[layerIndex].routings[routingIndex].program = .singleNote(
                        note: note, velocity: velocity, transition: transition
                    )
                case .constant, .continuous, .programChange:
                    continue
                }
            }
        }
    }

    /// Ändert den Übergang aller Notenrouten der ausgewählten Ebene.
    /// Der Popover ruft diese Kit-Naht vor dem Zell-Override auf.
    public mutating func setNoteTransition(_ transition: SpatialNoteTransition) {
        setNoteTransition(transition, for: [selectedLayerID])
    }

    public var playableCellCount: Int {
        layers.reduce(0) { $0 + $1.polarCells.count }
    }

    public var ownValueCount: Int {
        layers.reduce(0) { total, layer in
            total + layer.polarCellOverrides.values.reduce(0) { $0 + $1.count }
        }
    }

    /// Ob der Dokumentinhalt mindestens ein Routing zum CoreMIDI-Ausgang
    /// enthält. Ebenenaktivität, Solo und Sichtbarkeit ändern diese Regel
    /// nicht: Stille wird über das Routing, nicht über den Ausgang, erzeugt.
    public var requiresMIDIOutput: Bool {
        layers.contains { layer in
            layer.routings.contains { routing in
                switch routing.target {
                case .midiNote, .midiCC, .midiProgramChange, .midiPitchBend, .midiChannelPressure,
                     .midiAllNotesOff:
                    return true
                case .midiEffectParameter, .audioUnitParameter, .audioUnitNote, .audioUnitAllNotesOff,
                     .audioUnitCC, .audioUnitProgramChange, .audioUnitPitchBend, .audioUnitChannelPressure,
                     .sceneSwitch, .releaseLayer, .boolean:
                    return false
                }
            }
        }
    }

    /// Kanonische Form für Dokumentvergleiche: Nur die Ebenenauswahl wird
    /// ausgeblendet. Alle übrigen gespeicherten Ebenenfelder bleiben erhalten.
    public func ignoringLayerSelection() -> SpatialInstrumentWorkspace {
        var normalized = self
        normalized.selectedLayerID = normalized.layers.first?.id ?? normalized.selectedLayerID
        return normalized
    }

    /// Klangrelevanter Schlüssel für den Live-Cutover. Reine Inspektor- und
    /// Darstellungsänderungen dürfen weder Noten lösen noch Bindings neu
    /// erzeugen: Name, Farbe, Sichtbarkeit, Sperre, Ebenenauswahl und
    /// Reihenfolge der Anzeige sind deshalb absichtlich ausgeschlossen.
    public func isMusicallyEquivalent(to other: SpatialInstrumentWorkspace) -> Bool {
        guard grid == other.grid,
              coordinateMode == other.coordinateMode,
              layers.count == other.layers.count else { return false }
        return zip(layers, other.layers).allSatisfy { lhs, rhs in
            lhs.id == rhs.id
                && lhs.isActive == rhs.isActive
                && lhs.isSoloed == rhs.isSoloed
                && lhs.polarCells == rhs.polarCells
                && lhs.routings == rhs.routings
                && lhs.polarCellOverrides == rhs.polarCellOverrides
        }
    }

    @discardableResult
    public mutating func requestGridChange(to size: MetricSquareGrid.CellSize) -> GridChange {
        guard grid != size.grid else { return .unchanged }
        return confirmGridChange(to: size)
    }

    @discardableResult
    public mutating func confirmGridChange(to size: MetricSquareGrid.CellSize) -> GridChange {
        guard grid != size.grid else { return .unchanged }
        let oldGrid = grid
        // The live document retains exact fine addresses. This coarse legacy
        // facade reprojects for standalone editing; it never clears values.
        layers = layers.map { layer in
            var projected = layer
            projected.polarCells = Set(layer.polarCells.flatMap { cell in
                (try? LegacyLatticeMigration.migrate(cell, in: oldGrid).cells.map {
                    try LegacyLatticeMigration.project($0, in: size.grid)
                }) ?? []
            })
            projected.polarCellOverrides = [:]
            for cell in layer.polarCellOverrides.keys.sorted(by: { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }) {
                for fine in (try? LegacyLatticeMigration.migrate(cell, in: oldGrid).cells) ?? [] {
                    if let tile = try? LegacyLatticeMigration.project(fine, in: size.grid), projected.polarCellOverrides[tile] == nil {
                        projected.polarCellOverrides[tile] = layer.polarCellOverrides[cell]
                    }
                }
            }
            return projected
        }
        grid = size.grid
        return .changed
    }

    public mutating func selectLayer(_ id: UUID) {
        guard layers.contains(where: { $0.id == id }) else { return }
        selectedLayerID = id
    }

    @discardableResult
    public mutating func addLayer(name: String? = nil) -> UUID {
        let palette = SpatialLayerColor.palette
        let layer = SpatialInstrumentLayer(
            name: name ?? "Layer \(layers.count + 1)",
            color: palette[layers.count % palette.count]
        )
        layers.append(layer)
        selectedLayerID = layer.id
        return layer.id
    }

    public mutating func deleteSelectedLayer() {
        guard layers.count > 1 else { return }
        layers.removeAll { $0.id == selectedLayerID }
        selectedLayerID = layers[0].id
        if layers.count == 1 {
            layers[0].isSoloed = false
        }
    }

    /// Makes a document-local copy.  Routing identities are ownership keys and
    /// must therefore never cross into another layer unchanged.
    @discardableResult
    public mutating func duplicateSelectedLayer() -> UUID? {
        guard let index = layers.firstIndex(where: { $0.id == selectedLayerID }) else { return nil }
        let original = layers[index]
        var copy = original
        copy.id = UUID()
        copy.name = uniqueLayerName("\(original.name) copy")
        copy.routings = original.routings.map { SpatialRouting(id: UUID(), target: $0.target, program: $0.program) }
        layers.insert(copy, at: index + 1)
        for sceneIndex in scenes.indices where scenes[sceneIndex].activeLayerIDs.contains(original.id) {
            scenes[sceneIndex].activeLayerIDs.insert(copy.id)
        }
        selectedLayerID = copy.id
        return copy.id
    }

    /// Inserts portable layers directly below the selection.  A scene is a
    /// set of layer IDs, so imported IDs are freshly allocated before any
    /// scene membership is changed.
    @discardableResult
    public mutating func insertCopiedLayers(_ source: [SpatialInstrumentLayer]) -> [UUID] {
        guard !source.isEmpty else { return [] }
        let insertion = (layers.firstIndex(where: { $0.id == selectedLayerID }) ?? layers.count - 1) + 1
        var copies: [SpatialInstrumentLayer] = []
        for layer in source {
            var copy = layer
            copy.id = UUID()
            copy.name = uniqueLayerName("\(layer.name) copy", including: copies.map(\.name))
            copy.routings = layer.routings.map { SpatialRouting(id: UUID(), target: $0.target, program: $0.program) }
            copies.append(copy)
        }
        layers.insert(contentsOf: copies, at: insertion)
        if let sceneID = currentSceneID, let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID }) {
            for copy in copies where !copy.routings.contains(where: { $0.target.isLayerControl }) {
                scenes[sceneIndex].activeLayerIDs.insert(copy.id)
            }
        }
        selectedLayerID = copies[0].id
        return copies.map(\.id)
    }

    private func uniqueLayerName(_ proposed: String, including additional: [String] = []) -> String {
        let occupied = Set(layers.map(\.name)).union(additional)
        guard occupied.contains(proposed) else { return proposed }
        var number = 2
        while occupied.contains("\(proposed) \(number)") { number += 1 }
        return "\(proposed) \(number)"
    }

    public mutating func moveSelectedLayer(by offset: Int) {
        guard let source = layers.firstIndex(where: { $0.id == selectedLayerID }) else { return }
        let destination = source + offset
        guard layers.indices.contains(destination) else { return }
        layers.swapAt(source, destination)
    }

    public mutating func updateSelectedLayer(_ change: (inout SpatialInstrumentLayer) -> Void) {
        guard let index = layers.firstIndex(where: { $0.id == selectedLayerID }) else { return }
        var changed = layers[index]
        change(&changed)
        // Metadata edits must preserve a loaded document's routing set.
        // The legacy editor's single-routing rule applies only to routing edits.
        if changed.routings != layers[index].routings, changed.routings.count > 1 {
            changed.routings = Array(changed.routings.prefix(1))
        }
        layers[index] = changed
    }

    private static func splitMultiRoutingLayers(
        _ source: [SpatialInstrumentLayer]
    ) -> [SpatialInstrumentLayer] {
        source.flatMap { layer in
            guard layer.routings.count > 1 else { return [layer] }
            return layer.routings.enumerated().map { index, routing in
                var split = layer
                split.id = index == 0 ? layer.id : UUID()
                split.name = index == 0 ? layer.name : "\(layer.name) · \(index + 1)"
                split.routings = [routing]
                return split
            }
        }
    }

    public mutating func replaceLayer(_ layer: SpatialInstrumentLayer, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index] = layer
    }

    /// Migriert ausschließlich Altdokumente: liest die kartesischen
    /// Altfelder, überträgt sie auf die polare Topologie und leert sie.
    /// Im laufenden Betrieb sind die Altfelder immer leer; die Funktion tut
    /// dann nichts.
    private mutating func migrateLegacyCartesianCells() {
        layers = layers.map { oldLayer in
            var layer = oldLayer
            var converted = layer.polarCells
            var overrides = layer.polarCellOverrides
            for cell in layer.legacyCells {
                let target = Self.polarCell(atCenterOf: cell, grid: grid)
                converted.insert(target)
                if let actions = layer.legacyCellOverrides[cell] {
                    overrides[target] = Self.mergedActions([overrides[target] ?? [], actions])
                }
            }
            layer.polarCells = converted
            layer.polarCellOverrides = overrides
            layer.legacyCells.removeAll()
            layer.legacyCellOverrides.removeAll()
            return layer
        }
        coordinateMode = .polar
    }

    /// Die **einzige** Regel, nach der eine kartesische Altzelle zu einer
    /// Polaradresse wird: über ihren Mittelpunkt. Sie ist modulweit sichtbar,
    /// weil der Interaktionszustand beim Übernehmen einer alten gemalten Fläche
    /// dieselbe Regel braucht und keine zweite Kopie davon existieren darf.
    public static func polarCell(
        atCenterOf cell: MetricGridCell, grid: MetricSquareGrid
    ) -> PolarMetricGridCell {
        let bounds = grid.bounds(of: cell)
        return PolarMetricGridCell(
            point: MetricScanPoint(
                xMeters: (bounds.minXMeters + bounds.maxXMeters) / 2,
                yMeters: (bounds.minYMeters + bounds.maxYMeters) / 2
            ),
            grid: grid
        )
    }

    private static func mergedActions(_ lists: [[SpatialCellAction]]) -> [SpatialCellAction] {
        lists.flatMap { $0 }.reduce(into: []) { result, action in
            if !result.contains(action) { result.append(action) }
        }
    }
}
