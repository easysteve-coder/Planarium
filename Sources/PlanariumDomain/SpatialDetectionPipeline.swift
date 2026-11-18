import Foundation
import PLSDeviceValues
import SickPLSCore

public enum DetectionTemporalSmoothing: Codable, Equatable, Sendable {
    case off
    case mean(window: Int)
    case median(window: Int)
    case exponential(alpha: Double)
}

public enum DetectionRepresentativeMode: String, Codable, CaseIterable, Sendable {
    case nearestPoint
    case mean
    case median
    case nearestPointWithOffset
}

/// Spatial-only emulation of the scanner's minimum-measurement mode. It
/// changes distances before object grouping, never the profile's bearings or
/// its number of rays.
public enum VirtualMMKMode: String, Codable, CaseIterable, Sendable {
    case raw
    case fixed1
    case fixed2
    case adaptive

    public var label: String {
        switch self {
        case .raw: "0.5°"
        case .fixed1: "1°"
        case .fixed2: "2°"
        case .adaptive: "Adaptive"
        }
    }
}

public struct DetectionCellSelection: Codable, Equatable, Sendable {
    /// Snap distance. Keep the historic Edge-margin key for preset compatibility.
    public var boundaryMarginCentimeters: UInt16
    public var confirmationProfiles: Int

    public init(boundaryMarginCentimeters: UInt16 = 0, confirmationProfiles: Int = 1) {
        self.boundaryMarginCentimeters = min(boundaryMarginCentimeters, 10)
        self.confirmationProfiles = min(max(confirmationProfiles, 1), 4)
    }
}

public struct DetectionConfiguration: Codable, Equatable, Sendable {
    public var room: SpatialRoomContourConfiguration
    public var time: DetectionTimeConfiguration
    public var beams: DetectionBeamsConfiguration
    public var groups: DetectionGroupsConfiguration
    public var edge: DetectionEdgeConfiguration
    public var core: DetectionCoreConfiguration
    public var representativeStage: DetectionRepresentativeConfiguration
    public var cells: DetectionCellsConfiguration

    // Source compatibility for existing documents, callers and recordings.
    public var smoothingEnabled: Bool {
        get { time.smoothingEnabled }
        set { time.smoothingEnabled = newValue }
    }
    public var temporalSmoothing: DetectionTemporalSmoothing {
        get { time.temporalSmoothing }
        set { time.temporalSmoothing = newValue }
    }
    public var virtualMMKMode: VirtualMMKMode {
        get { beams.virtualMMKMode }
        set { beams.virtualMMKMode = newValue }
    }
    public var virtualMMKTargetWidthCentimeters: UInt8 {
        get { beams.virtualMMKTargetWidthCentimeters }
        set { beams.virtualMMKTargetWidthCentimeters = newValue }
    }
    public var virtualMMKSoftness: UInt8 {
        get { beams.virtualMMKSoftness }
        set { beams.virtualMMKSoftness = newValue }
    }
    public var groupingEnabled: Bool {
        get { groups.groupingEnabled }
        set { groups.groupingEnabled = newValue }
    }
    public var groupingJumpCentimeters: UInt16 {
        get { groups.groupingJumpCentimeters }
        set { groups.groupingJumpCentimeters = newValue }
    }
    public var groupingMinimumPoints: Int {
        get { groups.groupingMinimumPoints }
        set { groups.groupingMinimumPoints = newValue }
    }
    public var minimumAngleDegrees: Int {
        get { groups.minimumAngleDegrees }
        set { groups.minimumAngleDegrees = newValue }
    }
    public var edgePoints: UInt8 {
        get { edge.edgePoints }
        set { edge.edgePoints = newValue }
    }
    public var coreWidthCentimeters: UInt8 {
        get { core.coreWidthCentimeters }
        set { core.coreWidthCentimeters = newValue }
    }
    public var representative: DetectionRepresentativeMode {
        get { representativeStage.representative }
        set { representativeStage.representative = newValue }
    }
    public var representativeOffsetCentimeters: UInt16 {
        get { representativeStage.representativeOffsetCentimeters }
        set { representativeStage.representativeOffsetCentimeters = newValue }
    }
    public var cellSelection: DetectionCellSelection {
        get { cells.cellSelection }
        set { cells.cellSelection = newValue }
    }
    public var continuousBacklashCentimeters: UInt16 {
        get { cells.continuousBacklashCentimeters }
        set { cells.continuousBacklashCentimeters = newValue }
    }
    public var roomContour: SpatialRoomContourConfiguration {
        get { room }
        set { room = newValue }
    }
    public static let edgePointThresholdCentimeters = DetectionEdgeConfiguration.thresholdCentimeters
    public var effective: Self {
        var value = self
        value.time = time.effective
        return value
    }
    public mutating func setSmoothingEnabled(_ enabled: Bool) {
        time.setSmoothingEnabled(enabled)
    }
    public init(
        temporalSmoothing: DetectionTemporalSmoothing = DetectionTimeConfiguration.defaults.temporalSmoothing,
        groupingEnabled: Bool = DetectionGroupsConfiguration.defaults.groupingEnabled,
        groupingJumpCentimeters: UInt16 = DetectionGroupsConfiguration.defaults.groupingJumpCentimeters,
        groupingMinimumPoints: Int = DetectionGroupsConfiguration.defaults.groupingMinimumPoints,
        representative: DetectionRepresentativeMode = DetectionRepresentativeConfiguration.defaults.representative,
        representativeOffsetCentimeters: UInt16 = DetectionRepresentativeConfiguration.defaults.representativeOffsetCentimeters,
        cellSelection: DetectionCellSelection = DetectionCellsConfiguration.defaults.cellSelection,
        continuousBacklashCentimeters: UInt16 = DetectionCellsConfiguration.defaults.continuousBacklashCentimeters,
        roomContour: SpatialRoomContourConfiguration = SpatialRoomContourConfiguration.defaults,
        minimumAngleDegrees: Int = DetectionGroupsConfiguration.defaults.minimumAngleDegrees,
        virtualMMKMode: VirtualMMKMode = DetectionBeamsConfiguration.defaults.virtualMMKMode,
        virtualMMKTargetWidthCentimeters: UInt8 = DetectionBeamsConfiguration.defaults.virtualMMKTargetWidthCentimeters,
        virtualMMKSoftness: UInt8 = DetectionBeamsConfiguration.defaults.virtualMMKSoftness,
        edgePoints: UInt8 = DetectionEdgeConfiguration.defaults.edgePoints,
        coreWidthCentimeters: UInt8 = DetectionCoreConfiguration.defaults.coreWidthCentimeters
    ) {
        room = roomContour
        time = .init(temporalSmoothing: temporalSmoothing)
        beams = .init(virtualMMKMode: virtualMMKMode, virtualMMKTargetWidthCentimeters: virtualMMKTargetWidthCentimeters, virtualMMKSoftness: virtualMMKSoftness)
        groups = .init(groupingEnabled: groupingEnabled, groupingJumpCentimeters: groupingJumpCentimeters, groupingMinimumPoints: groupingMinimumPoints, minimumAngleDegrees: minimumAngleDegrees)
        edge = .init(edgePoints: edgePoints)
        core = .init(coreWidthCentimeters: coreWidthCentimeters)
        representativeStage = .init(representative: representative, representativeOffsetCentimeters: representativeOffsetCentimeters)
        cells = .init(cellSelection: cellSelection, continuousBacklashCentimeters: continuousBacklashCentimeters)
    }

    public static let ownerDefaults = DetectionConfiguration()

    /// Shared metric window for the spatial minimum and its display fan.
    public func virtualMMKWindowDegrees(distanceCentimeters: Double) -> Double {
        beams.virtualMMKWindowDegrees(distanceCentimeters: distanceCentimeters)
    }

    public func virtualMMKWeight(fractionOfHalfWidth fraction: Double) -> Double {
        beams.virtualMMKWeight(fractionOfHalfWidth: fraction)
    }

    /// Defaults used only when an older workspace has no detection object at
    /// all. Such a file predates virtual MMK and must retain raw rays.
    public static let legacyDefaults = DetectionConfiguration(virtualMMKMode: .raw, edgePoints: 0, coreWidthCentimeters: 0)

    public static let allStagesOff = DetectionConfiguration(
        groupingEnabled: false,
        representative: .nearestPoint,
        cellSelection: .init(),
        continuousBacklashCentimeters: 0, minimumAngleDegrees: 0,
        virtualMMKMode: .raw, edgePoints: 0, coreWidthCentimeters: 0
    )

    public init(from decoder: Decoder) throws {
        room = .init()
        time = try DetectionTimeConfiguration(from: decoder)
        beams = try DetectionBeamsConfiguration(from: decoder)
        groups = try DetectionGroupsConfiguration(from: decoder)
        edge = try DetectionEdgeConfiguration(from: decoder)
        core = try DetectionCoreConfiguration(from: decoder)
        representativeStage = try DetectionRepresentativeConfiguration(from: decoder)
        cells = try DetectionCellsConfiguration(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try time.encode(to: encoder)
        try beams.encode(to: encoder)
        try groups.encode(to: encoder)
        try edge.encode(to: encoder)
        try core.encode(to: encoder)
        try representativeStage.encode(to: encoder)
        try cells.encode(to: encoder)
    }

    public func replacingTemporalSmoothing(_ value: DetectionTemporalSmoothing) -> Self {
        var copy = self; copy.temporalSmoothing = value; return copy
    }

    public func replacingRepresentative(_ value: DetectionRepresentativeMode) -> Self {
        var copy = self; copy.representative = value; return copy
    }

    public func replacingCellSelection(_ value: DetectionCellSelection) -> Self {
        var copy = self; copy.cellSelection = value; return copy
    }
}

public struct DetectionRepresentative: Equatable, Sendable {
    public let point: MetricScanPoint
    public let distanceCentimeters: Double
    public let bearingDegrees: Double

    public init(point: MetricScanPoint) {
        self.point = point
        self.distanceCentimeters = hypot(point.xMeters, point.yMeters) * 100
        self.bearingDegrees = atan2(point.xMeters, point.yMeters) * 180 / .pi
    }
}

/// Display evidence captured at the real stage boundaries, including groups
/// rejected by the point-count floor. Absent on the musical hot path.
public struct DetectionGroupingEvidence: Equatable, Sendable {
    public let measurements: [ProjectedScanMeasurement]
    public let groupsBeforeMinimumPoints: [[ProjectedScanMeasurement]]
    public let groupsBeforeAngularSeparation: [[ProjectedScanMeasurement]]
    public let acceptedOrders: Set<Int>
}

/// Evidence from the very groups consumed by the selector, never regrouped by UI.
public struct DetectionObject: Equatable, Sendable {
    public let sourceOrder: Int?
    public let center: MetricScanPoint
    public let diameterMeters: Double
    public let representative: DetectionRepresentative
    /// Populated only by the display call; exact accepted group membership.
    public let measuredOrders: [Int]
    public let coreOrders: [Int]
    public let discardedEdgeOrders: [Int]
    /// Parallel sides of the metric core strip, for clipping inside the disc.
    public let coreStrip: [MetricScanPoint]
    /// Display evidence from the actual Beams/Core/Time stages. Empty on the
    /// musical path; overlays never reconstruct transformed group geometry.
    public let groupPoints: [MetricScanPoint]
    public let representativeInput: [ProjectedScanMeasurement]
    public init(center: MetricScanPoint, diameterMeters: Double, representative: DetectionRepresentative, measuredOrders: [Int] = [],
                coreOrders: [Int] = [], discardedEdgeOrders: [Int] = [], coreStrip: [MetricScanPoint] = [],
                groupPoints: [MetricScanPoint] = [], representativeInput: [ProjectedScanMeasurement] = [], sourceOrder: Int? = nil) {
        self.sourceOrder = sourceOrder
        self.center = center; self.diameterMeters = diameterMeters; self.representative = representative
        self.measuredOrders = measuredOrders
        self.coreOrders = coreOrders; self.discardedEdgeOrders = discardedEdgeOrders; self.coreStrip = coreStrip
        self.groupPoints = groupPoints; self.representativeInput = representativeInput
    }
}

public struct DetectionLatency: Equatable, Sendable {
    public let milliseconds: Int
    public let isNominal: Bool
    public let dependsOnSignal: Bool

    public static func confirmationTooltip(profiles: Int, profileRateHertz: Double) -> String {
        let normalized = min(max(profiles, 1), 4)
        let base = DetectionConfiguration.ownerDefaults
        let one = DetectionLatency(
            configuration: base.replacingCellSelection(.init(confirmationProfiles: 1)),
            profileRateHertz: profileRateHertz
        )
        let selected = DetectionLatency(
            configuration: base.replacingCellSelection(.init(confirmationProfiles: normalized)),
            profileRateHertz: profileRateHertz
        )
        let addedMilliseconds = max(0, selected.milliseconds - one.milliseconds)
        let timing = addedMilliseconds == 0
            ? "no added confirmation delay"
            : "about \(addedMilliseconds) ms added delay at \(Int(profileRateHertz.rounded())) Hz"
        return "Requires \(normalized) consecutive scans in a new cell before switching. " +
            (normalized == 1
                ? "Immediate and fastest, but may flicker at cell borders. "
                : "Steadier, but responds later. ") + timing + "."
    }

    public init(configuration: DetectionConfiguration, profileRateHertz: Double) {
        let rate = max(profileRateHertz, 0.000_001)
        switch configuration.effective.temporalSmoothing {
        case .off:
            milliseconds = max(0, Int((Double(max(configuration.cellSelection.confirmationProfiles - 1, 0)) / rate * 1_000).rounded()))
            isNominal = configuration.cellSelection.confirmationProfiles > 1
            dependsOnSignal = false
        case .mean(let window):
            let temporal = Double(max(window - 1, 0)) / 2 / rate * 1_000
            let confirmation = Double(max(configuration.cellSelection.confirmationProfiles - 1, 0)) / rate * 1_000
            milliseconds = Int((temporal + confirmation).rounded())
            isNominal = true
            dependsOnSignal = false
        case .median, .exponential:
            milliseconds = Int((Double(max(configuration.cellSelection.confirmationProfiles - 1, 0)) / rate * 1_000).rounded())
            isNominal = false
            dependsOnSignal = true
        }
    }
}

/// One compiled detection path for sound and display. Only configuration
/// and temporal history are mutable; the input projection stays unchanged.
public struct SpatialDetectionPipeline: Sendable {
    public private(set) var configuration: DetectionConfiguration
    private var deviceSelector = DeviceLatticeSelector()
    private var history: [[ProjectedScanMeasurement]] = []
    private var historyPointCount: Int?
    private var exponentialByOrder: [Int: Double] = [:]
    private struct SceneCarrier: Hashable, Sendable { let layer: UUID; let cell: PolarDeviceLattice }
    private var sceneConfirmation: [SceneCarrier: Int] = [:]
    private var sceneSnapCarriers: [CompiledActiveCell] = []
    private var sceneSnapGeometry: ProfileGeometryIdentity?

    public init(configuration: DetectionConfiguration = .ownerDefaults) {
        self.configuration = configuration.effective
    }

    public mutating func update(configuration: DetectionConfiguration) {
        guard self.configuration != configuration.effective else { return }
        let next = configuration.effective
        // New smoothing/filter semantics require new samples; changing
        // grouping/selection leaves the temporal measurement history intact.
        if self.configuration.temporalSmoothing != next.temporalSmoothing || self.configuration.roomContour != next.roomContour ||
            self.configuration.coreWidthCentimeters != next.coreWidthCentimeters || self.configuration.edgePoints != next.edgePoints {
            history.removeAll(); historyPointCount = nil; exponentialByOrder.removeAll()
        }
        self.configuration = next
        deviceSelector.reset()
        sceneConfirmation.removeAll()
        sceneSnapCarriers.removeAll()
    }

    internal mutating func install(_ instrument: CompiledInstrument) {
        update(configuration: instrument.detection)
        deviceSelector.install(instrument)
        sceneConfirmation.removeAll()
        sceneSnapCarriers = sceneSnapCarriers.compactMap { instrument.transferring($0) }
    }

    public mutating func reset() {
        deviceSelector.reset()
        sceneConfirmation.removeAll()
        sceneSnapCarriers.removeAll()
        sceneSnapGeometry = nil
        history.removeAll()
        historyPointCount = nil
        exponentialByOrder.removeAll()
    }

    /// Compiled polar ingress. Configuration is always a document snapshot;
    /// temporal history and selection are the only mutable detection state.
    public mutating func select(
        frame: ProfileFrame, instrument: CompiledInstrument, contour: SpatialRoomContour?
    ) -> DeviceLatticeSelection {
        select(frame: frame, instrument: instrument, contour: contour, recordingProfile: true)
    }

    public mutating func selectForPresentation(
        frame: ProfileFrame, instrument: CompiledInstrument, contour: SpatialRoomContour?
    ) -> DeviceLatticeSelection {
        select(frame: frame, instrument: instrument, contour: contour, recordingProfile: true, collectGroupEvidence: true)
    }

    internal mutating func select(
        frame: ProfileFrame, instrument: CompiledInstrument, contour: SpatialRoomContour?, recordingProfile: Bool,
        collectGroupEvidence: Bool = false
    ) -> DeviceLatticeSelection {
        update(configuration: instrument.detection)
        if sceneSnapGeometry != frame.geometry {
            sceneSnapCarriers.removeAll(); sceneConfirmation.removeAll()
            sceneSnapGeometry = frame.geometry
        }
        let contourGeometry = SpatialRoomContour.Geometry(
            pointCount: frame.geometry.pointCount,
            angleResolutionDegrees: frame.geometry.pointCount > 1
                ? (frame.geometry.endAngleDegrees - frame.geometry.startAngleDegrees) / Double(frame.geometry.pointCount - 1) : 180,
            startAngleDegrees: frame.geometry.startAngleDegrees,
            sourceIdentifier: frame.sourceIdentifier)
        let contourMatches = contour?.compatibility(with: contourGeometry) ?? true
        if configuration == .allStagesOff && !collectGroupEvidence {
            // Preserve the original device spans and integer distances. With
            // every stage off, Cartesian projection and order-based quadratic
            // lookup cannot change the result and add avoidable Q work.
            let valid = frame.measurements.filter { UsableRawDistance.contains($0.rawCentimeters) }
            let selection = deviceSelector.step(measurements: valid, instrument: instrument, geometry: frame.geometry,
                configuration: .init(radialMarginCentimeters: 0, angularMarginTicks: 0,
                                     switchConfirmationProfiles: 1, continuousBacklashCentimeters: 0))
            let controls = sceneControls(valid, instrument: instrument, recordingProfile: recordingProfile)
            return .init(activeHandles: selection.activeHandles,
                         candidateDistancesCentimeters: selection.candidateDistancesCentimeters,
                         contourMatches: contourMatches, sceneControlHandles: controls.confirmed, measuredEntryHandles: controls.measured, confirmationProgress: selection.confirmationProgress)
        }
        if historyPointCount != frame.geometry.pointCount {
            history.removeAll()
            exponentialByOrder.removeAll()
            deviceSelector.reset()
            sceneConfirmation.removeAll()
            sceneSnapCarriers.removeAll()
            historyPointCount = frame.geometry.pointCount
        }
        var filteredOrders = Set<Int>()
        var selectedRepresentative: DetectionRepresentative?
        var projected = frame.projectedMeasurements
        var objects: [DetectionObject] = []
        var filtered: [DeviceTickMeasurement] = []
        var nearestGroupDistance = Double.greatestFiniteMagnitude
        var groupingMeasurements: [ProjectedScanMeasurement] = []
        var groupsBeforeMinimumPoints: [[ProjectedScanMeasurement]] = []
        var groupsBeforeAngularSeparation: [[ProjectedScanMeasurement]] = []
        var acceptedGroupOrders = Set<Int>()
        var originalGroups: [[ProjectedScanMeasurement]] = []
        var groups: [[ProjectedScanMeasurement]] = []
        var cores: [[ProjectedScanMeasurement]] = []
        var smoothedByOrder: [Int: ProjectedScanMeasurement] = [:]
        var selection: DeviceLatticeSelection?
        for operation in DetectionStagePlan.operations(configuration: configuration) {
            switch operation {
            case .room:
                let result = configuration.room.filter(projected, contour: contour, geometry: contourGeometry, matches: contourMatches)
                projected = result.measurements; filteredOrders = result.rejectedOrders
            case .time:
                guard configuration.time.temporalSmoothing != .off else { continue }
                let input = configuration.core.coreWidthCentimeters > 0 ? cores.flatMap { $0 } : projected
                let result = advanceTime(input, recordingProfile: recordingProfile)
                if configuration.core.coreWidthCentimeters > 0 {
                    smoothedByOrder = Dictionary(uniqueKeysWithValues: result.map { ($0.order, $0) })
                } else { projected = result }
            case .beams:
                projected = configuration.beams.virtualMMK(projected, geometry: frame.geometry)
            case .groups:
                if collectGroupEvidence {
                    groupingMeasurements = projected
                    var grouping = configuration.groups; grouping.groupingMinimumPoints = 1
                    groupsBeforeMinimumPoints = grouping.makeGroups(projected)
                }
                originalGroups = configuration.groups.makeGroups(projected)
                groups = originalGroups
            case .edge:
                groups = groups.map { configuration.edge.trimEdges($0, minimumPoints: configuration.groups.groupingMinimumPoints) }
            case .angularSeparation:
                if collectGroupEvidence { groupsBeforeAngularSeparation = groups }
                groups = configuration.groups.separatedGroups(groups, measurements: frame.measurements)
                if collectGroupEvidence { acceptedGroupOrders = Set(groups.flatMap { $0.map(\.order) }) }
            case .core:
                cores = groups.map { configuration.core.corePoints($0) }
            case .representative:
                for (index, group) in groups.enumerated() where !group.isEmpty {
                    let core = cores[index]
                    let representative = configuration.representativeStage.makeRepresentative(core.map { smoothedByOrder[$0.order] ?? $0 })
                    let xs = group.map { $0.point.xMeters }, ys = group.map { $0.point.yMeters }
                    let original = collectGroupEvidence ? originalGroups.first { $0.contains { $0.order == group[0].order } } : nil
                    let orders = Set(group.map(\.order))
                    objects.append(.init(center: .init(xMeters: xs.reduce(0,+)/Double(group.count), yMeters: ys.reduce(0,+)/Double(group.count)),
                        diameterMeters: max(0.04, hypot(xs.max()! - xs.min()!, ys.max()! - ys.min()!)), representative: representative,
                        measuredOrders: collectGroupEvidence ? group.map(\.order) : [],
                        coreOrders: collectGroupEvidence ? core.map(\.order) : [],
                        discardedEdgeOrders: original?.filter { !orders.contains($0.order) }.map(\.order) ?? [],
                        coreStrip: configuration.core.coreStrip(group),
                        groupPoints: collectGroupEvidence ? group.map(\.point) : [],
                        representativeInput: collectGroupEvidence ? core.map { smoothedByOrder[$0.order] ?? $0 } : [], sourceOrder: group[0].order))
                    // The optional display anchor remains the nearest object. Sound
                    // receives every object; the selector chooses independently per layer.
                    let groupDistance = configuration.groups.distance(of: group)
                    if groupDistance < nearestGroupDistance {
                        selectedRepresentative = representative
                        nearestGroupDistance = groupDistance
                    }
                    let tick = Int(((representative.bearingDegrees + 90) * 2).rounded())
                    let distance = representative.distanceCentimeters.rounded()
                    // Representatives stay on a measured bearing, including after
                    // radial smoothing/offset. Preserve that sample's MMK segment;
                    // quantizing it to one tick would throw its other rays away.
                    let source = core.first {
                        abs(atan2($0.point.xMeters, $0.point.yMeters) * 180 / .pi - representative.bearingDegrees) < 1e-9
                    }.flatMap { point in frame.measurements.first { $0.order == point.order } }
                    if let span = source?.ticks ?? DeviceTickSpan.point(tick), distance.isFinite,
                       distance >= 0, distance <= Double(UInt16.max),
                       let measurement = DeviceTickMeasurement(order: group[0].order, ticks: span,
                                                               rawCentimeters: UInt16(distance)) {
                        filtered.append(measurement)
                    }
                }
            case .cells:
                selection = configuration.cells.select(filtered, instrument: instrument, geometry: frame.geometry, state: &deviceSelector)
            }
        }
        // The plan always ends in Cells. No independent selection path.
        guard let selection else { preconditionFailure("Detection plan must include Cells") }
        let controls = sceneControls(filtered, instrument: instrument, recordingProfile: recordingProfile)
        return .init(activeHandles: selection.activeHandles, candidateDistancesCentimeters: selection.candidateDistancesCentimeters,
                     representative: selectedRepresentative, contourMatches: contourMatches, filteredOrders: filteredOrders, objects: objects,
                     sceneControlHandles: controls.confirmed, measuredEntryHandles: controls.measured, confirmationProgress: selection.confirmationProgress,
                     groupingEvidence: collectGroupEvidence ? .init(measurements: groupingMeasurements,
                        groupsBeforeMinimumPoints: groupsBeforeMinimumPoints, groupsBeforeAngularSeparation: groupsBeforeAngularSeparation,
                        acceptedOrders: acceptedGroupOrders) : nil)
    }

    /// Use the same accepted object measurements as musical detection. One
    /// measured MMK span chooses the first painted carrier per control layer;
    /// additional hands remain independent. No raw/prognosed parallel input.
    private mutating func sceneControls(_ measurements: [DeviceTickMeasurement], instrument: CompiledInstrument, recordingProfile: Bool) -> (confirmed: [CompiledActiveCell], measured: [CompiledActiveCell]) {
        let controls = Set(instrument.layers.filter { layer in
            layer.routings.contains {
                if $0.target.isLayerControl { return true }
                switch $0.program {
                case .singleNote(_, _, .toggle), .singleNote(_, _, .holdUntilNext),
                     .chord(_, _, .toggle), .scale(_, _, _, _, _, _, .toggle), .randomScale(_, _, _, _, _, .toggle),
                     .chord(_, _, .holdUntilNext), .scale(_, _, _, _, _, _, .holdUntilNext), .randomScale(_, _, _, _, _, .holdUntilNext): return true
                default: return false
                }
            }
        }.map(\.id))
        guard !controls.isEmpty else { sceneSnapCarriers.removeAll(); return ([], []) }
        let snap = configuration.cellSelection.boundaryMarginCentimeters
        func carrierKey(_ handle: CompiledActiveCell) -> SceneCarrier {
            let cell = snap > 0
                ? instrument.layers.first(where: { $0.id == handle.layerID })?.snapRegionByCell[handle.cell] ?? handle.cell : handle.cell
            return SceneCarrier(layer: handle.layerID, cell: cell)
        }
        let margin = SpatialHysteresisConfiguration(snapCentimeters: snap)
        let holdGeometry = DeviceLatticeHoldGeometry()
        let held: [CompiledActiveCell] = snap == 0 ? [] : sceneSnapCarriers.compactMap { instrument.transferring($0) }.filter { handle in
            guard let layer = instrument.layers.first(where: { $0.id == handle.layerID }) else { return false }
            return measurements.contains { holdGeometry.contains($0, active: handle.cell, layer: layer, margin: margin) }
        }
        var result = held
        for measurement in measurements {
            var seen = Set<UUID>()
            for hit in instrument.hits(span: measurement.ticks, raw: measurement.rawCentimeters)
                where controls.contains(hit.layerID) && seen.insert(hit.layerID).inserted {
                if snap > 0, let layer = instrument.layers.first(where: { $0.id == hit.layerID }),
                   held.contains(where: { $0.layerID == hit.layerID && holdGeometry.contains(measurement, active: $0.cell, layer: layer, margin: margin) }) { continue }
                if !result.contains(where: { carrierKey($0) == carrierKey(hit) }) { result.append(hit) }
            }
        }
        let required = configuration.cellSelection.confirmationProfiles
        if recordingProfile {
            var next: [SceneCarrier: Int] = [:]
            for handle in result {
                let key = carrierKey(handle)
                next[key] = min(required, (sceneConfirmation[key] ?? 0) + 1)
            }
            sceneConfirmation = next
            // A pending entry has no active Snap surface yet. Confirmed
            // carriers retain their provenance through metadata installs.
            sceneSnapCarriers = snap > 0 ? result.filter { handle in
                held.contains(where: { carrierKey($0) == carrierKey(handle) })
                    || next[carrierKey(handle), default: 0] >= required
            } : []
        }
        return (result.filter { sceneConfirmation[carrierKey($0), default: 0] >= required }, result)
    }

    private mutating func advanceTime(_ input: [ProjectedScanMeasurement], recordingProfile: Bool) -> [ProjectedScanMeasurement] {
        if recordingProfile { history.append(input) }
        let capacity = configuration.time.historyCapacity
        if history.count > capacity { history.removeFirst(history.count - capacity) }
        return smooth(input, advanceExponential: recordingProfile)
    }

    internal mutating func smooth(_ current: [ProjectedScanMeasurement], advanceExponential: Bool) -> [ProjectedScanMeasurement] {
        configuration.time.smooth(current, history: history, exponential: &exponentialByOrder,
                                  advanceExponential: advanceExponential)
    }

    internal func virtualMMK(_ measurements: [ProjectedScanMeasurement], geometry: ProfileGeometryIdentity) -> [ProjectedScanMeasurement] {
        configuration.beams.virtualMMK(measurements, geometry: geometry)
    }

    internal func trimEdges(_ group: [ProjectedScanMeasurement]) -> [ProjectedScanMeasurement] {
        configuration.edge.trimEdges(group, minimumPoints: configuration.groups.groupingMinimumPoints)
    }

    internal func corePoints(_ group: [ProjectedScanMeasurement]) -> [ProjectedScanMeasurement] {
        configuration.core.corePoints(group)
    }
}
