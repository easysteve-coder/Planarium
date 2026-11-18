import Foundation
import PLSDeviceValues
import SickPLSCore

public struct ProfileGeometryIdentity: Equatable, Sendable {
    public let operatingMode: String
    public let pointCount: Int
    public let startAngleDegrees: Double
    public let endAngleDegrees: Double

    public init(
        operatingMode: String,
        pointCount: Int,
        startAngleDegrees: Double,
        endAngleDegrees: Double
    ) {
        self.operatingMode = operatingMode
        self.pointCount = pointCount
        self.startAngleDegrees = startAngleDegrees
        self.endAngleDegrees = endAngleDegrees
    }

    public static let fullScan361 = Self(
        operatingMode: "fullScan", pointCount: 361,
        startAngleDegrees: -90, endAngleDegrees: 90
    )

    /// Partition all 361 document ticks by the nearest measured bearing.
    /// Halfway ties belong to the following sample. Integer arithmetic keeps
    /// adjacent MMK spans gap-free and disjoint, including ticks 0 and 360.
    public func tickSpan(at index: Int) -> DeviceTickSpan? {
        guard [90, 180, 361].contains(pointCount), (0..<pointCount).contains(index),
              startAngleDegrees == -90, endAngleDegrees == 90 else { return nil }
        let divisor = 2 * (pointCount - 1)
        func ceiling(_ numerator: Int) -> Int { (numerator + divisor - 1) / divisor }
        let lower = index == 0 ? 0 : ceiling((2 * index - 1) * 360)
        let upper = index == pointCount - 1 ? 360 : ceiling((2 * index + 1) * 360) - 1
        return .init(lower: lower, upper: upper)
    }

    /// The same measured index/angle rule supplies detection and display.
    /// The visual anchor is the actual sample bearing, not a rounded tick.
    public func project(_ measurements: [DeviceTickMeasurement], rawProfile: B0ScanProfile? = nil) -> [ProjectedScanMeasurement] {
        guard pointCount > 1, let span = try? ScanAngularSpan.build(
            startDegrees: startAngleDegrees, endDegrees: endAngleDegrees) else { return [] }
        return measurements.compactMap { measurement in
            guard (0..<pointCount).contains(measurement.order) else { return nil }
            let fraction = Double(measurement.order) / Double(pointCount - 1)
            let bearing = span.bearingDegrees(at: fraction) * .pi / 180
            let radius = Double(measurement.rawCentimeters) / 100
            let flags: UInt8
            if let profile = rawProfile, profile.measurements.indices.contains(measurement.order) {
                flags = profile.measurements[measurement.order].fieldFlags
            } else { flags = 0 }
            return .init(order: measurement.order, normalizedIndex: fraction,
                         distanceCentimeters: measurement.rawCentimeters, fieldFlags: flags,
                         point: .init(xMeters: sin(bearing) * radius, yMeters: cos(bearing) * radius))
        }
    }
}

public struct DetectionConfirmationProgress: Equatable, Sendable {
    public let target: CompiledActiveCell
    public let observedProfiles: Int
    public let requiredProfiles: Int
}

public struct DeviceLatticeSelection: Equatable, Sendable {
    public let groupingEvidence: DetectionGroupingEvidence?
    public let confirmationProgress: [DetectionConfirmationProgress]
    public let activeHandles: [UUID: CompiledActiveCell]
    public let candidateDistancesCentimeters: [UUID: Double]
    public let objects: [DetectionObject]
    public let representative: DetectionRepresentative?
    public let contourMatches: Bool
    public let filteredOrders: Set<Int>
    /// All measured control carriers, independent of the one musical carrier per layer.
    public let sceneControlHandles: [CompiledActiveCell]
    /// Accepted measured carriers before entry confirmation; only used to
    /// observe exits, never to start notes or fire controls.
    public let measuredEntryHandles: [CompiledActiveCell]

    public init(
        activeHandles: [UUID: CompiledActiveCell],
        candidateDistancesCentimeters: [UUID: Double], representative: DetectionRepresentative? = nil,
        contourMatches: Bool = true, filteredOrders: Set<Int> = [], objects: [DetectionObject] = [],
        sceneControlHandles: [CompiledActiveCell] = [], measuredEntryHandles: [CompiledActiveCell] = [],
        confirmationProgress: [DetectionConfirmationProgress] = [], groupingEvidence: DetectionGroupingEvidence? = nil
    ) {
        self.groupingEvidence = groupingEvidence
        self.confirmationProgress = confirmationProgress
        self.activeHandles = activeHandles
        self.candidateDistancesCentimeters = candidateDistancesCentimeters
        self.objects = objects
        self.sceneControlHandles = sceneControlHandles
        self.measuredEntryHandles = measuredEntryHandles
        self.representative = representative; self.contourMatches = contourMatches; self.filteredOrders = filteredOrders
    }

    public var active: [UUID: CompiledActiveCell] { activeHandles }
    public var isEmpty: Bool { activeHandles.isEmpty }
}

public struct DeviceLatticeSelector: Sendable {
    private struct LayerState: Sendable {
        var active: CompiledActiveCell?
        var pending = 0
        var pendingCell: PolarDeviceLattice?
    }

    private var states: [UUID: LayerState] = [:]
    private var rememberedRevision: SpatialDocumentRevision?
    private var rememberedGeometry: ProfileGeometryIdentity?
    private var backlashByLayer: [UUID: Double] = [:]
    private let holdGeometry = DeviceLatticeHoldGeometry()

    internal private(set) var indexRequestCount = 0

    public init() {}

    public mutating func step(
        measurements: [DeviceTickMeasurement],
        instrument: CompiledInstrument,
        geometry: ProfileGeometryIdentity,
        configuration: SpatialHysteresisConfiguration = .init()
    ) -> DeviceLatticeSelection {
        if rememberedRevision != instrument.revision || rememberedGeometry != geometry {
            reset()
            rememberedRevision = instrument.revision
            rememberedGeometry = geometry
        }
        guard !measurements.isEmpty else {
            states.removeAll()
            backlashByLayer.removeAll()
            return .init(activeHandles: [:], candidateDistancesCentimeters: [:])
        }

        var candidates: [UUID: (handle: CompiledActiveCell, measurement: DeviceTickMeasurement)] = [:]
        for measurement in measurements {
            indexRequestCount += 1
            for handle in instrument.hits(span: measurement.ticks, raw: measurement.rawCentimeters) {
                let candidate = (handle: handle, measurement: measurement)
                if let current = candidates[handle.layerID], !isEarlier(candidate, than: current) {
                    continue
                }
                candidates[handle.layerID] = candidate
            }
        }

        var progress: [DetectionConfirmationProgress] = []
        var activeHandles: [UUID: CompiledActiveCell] = [:]
        var eligible = Set<UUID>()
        for layer in instrument.layers {
            eligible.insert(layer.id)
            var state = states[layer.id] ?? LayerState(active: nil)
            let previousActive = state.active
            guard let candidate = candidates[layer.id] else {
                if let active = state.active {
                    let held = measurements.contains {
                        holdGeometry.contains($0, active: active.cell, layer: layer, margin: configuration)
                    }
                    if !held {
                        state.active = nil
                        state.pending = 0
                        state.pendingCell = nil
                        backlashByLayer[layer.id] = nil
                    } else {
                        state.pending = 0
                        state.pendingCell = nil
                    }
                }
                states[layer.id] = state
                if let active = state.active { activeHandles[layer.id] = active }
                continue
            }

            if state.active == nil {
                state.active = candidate.handle
                state.pending = 0
            } else if let active = state.active {
                let heldMeasurements = measurements.filter {
                    holdGeometry.contains($0, active: active.cell, layer: layer, margin: configuration)
                }
                let leadsHeld = !holdGeometry.contains(candidate.measurement, active: active.cell, layer: layer, margin: configuration)
                          && Double(candidate.measurement.rawCentimeters)
                            < Double(heldMeasurements.map(\.rawCentimeters).min() ?? UInt16.max)
                                - Double(configuration.radialMarginCentimeters)
                if candidate.handle.cell != active.cell && (heldMeasurements.isEmpty || leadsHeld) {
                    let pendingCell = (configuration.snapCentimeters ?? 0) > 0
                        ? layer.snapRegionByCell[candidate.handle.cell] ?? candidate.handle.cell : candidate.handle.cell
                    if state.pendingCell != pendingCell { state.pending = 0 }
                    state.pendingCell = pendingCell
                    state.pending += 1
                    progress.append(.init(target: candidate.handle, observedProfiles: state.pending,
                        requiredProfiles: configuration.switchConfirmationProfiles))
                    if state.pending >= configuration.switchConfirmationProfiles {
                        state.active = candidate.handle
                        state.pending = 0
                        state.pendingCell = nil
                    }
                } else {
                    state.pending = 0
                    state.pendingCell = nil
                }
            }

            states[layer.id] = state
            guard let active = state.active else { continue }
            activeHandles[layer.id] = active

            let rawDistance = Double(candidate.measurement.rawCentimeters)
            let freshEntry = previousActive == nil || previousActive?.cell != active.cell
            if freshEntry || configuration.continuousBacklashCentimeters == 0 {
                backlashByLayer[layer.id] = rawDistance
            } else {
                let backlash = Double(configuration.continuousBacklashCentimeters)
                let previous = backlashByLayer[layer.id] ?? rawDistance
                backlashByLayer[layer.id] = rawDistance > previous + backlash
                    ? rawDistance - backlash
                    : rawDistance < previous - backlash ? rawDistance + backlash : previous
            }
            let filteredDistance = backlashByLayer[layer.id] ?? rawDistance
            let outputActive = active.withCandidateDistance(filteredDistance, sourceOrder: candidate.measurement.order)
            state.active = outputActive
            states[layer.id] = state
            activeHandles[layer.id] = outputActive
        }

        states = states.filter { eligible.contains($0.key) }
        backlashByLayer = backlashByLayer.filter { eligible.contains($0.key) }
        return DeviceLatticeSelection(
            activeHandles: activeHandles,
            candidateDistancesCentimeters: activeHandles.compactMapValues(\.candidateDistanceCentimeters),
            confirmationProgress: progress
        )
    }

    internal mutating func install(_ instrument: CompiledInstrument) {
        if let rememberedRevision, rememberedRevision.session != instrument.revision.session { reset() }
        for id in Array(states.keys) {
            guard let layer = instrument.layers.first(where: { $0.id == id }) else {
                states[id] = nil; backlashByLayer[id] = nil; continue
            }
            if let active = states[id]?.active {
                states[id]?.active = instrument.transferring(active)
                if states[id]?.active == nil { backlashByLayer[id] = nil }
            }
            if let pending = states[id]?.pendingCell, !layer.cells.contains(pending) {
                states[id]?.pendingCell = nil; states[id]?.pending = 0
            }
        }
        rememberedRevision = instrument.revision
    }

    public mutating func reset() {
        states.removeAll()
        rememberedRevision = nil
        rememberedGeometry = nil
        backlashByLayer.removeAll()
        indexRequestCount = 0
    }

    private func isEarlier(
        _ lhs: (handle: CompiledActiveCell, measurement: DeviceTickMeasurement),
        than rhs: (handle: CompiledActiveCell, measurement: DeviceTickMeasurement)
    ) -> Bool {
        lhs.measurement.rawCentimeters == rhs.measurement.rawCentimeters
            ? lhs.measurement.order < rhs.measurement.order
            : lhs.measurement.rawCentimeters < rhs.measurement.rawCentimeters
    }
}
