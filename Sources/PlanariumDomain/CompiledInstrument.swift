import Foundation
import PLSDeviceValues

/// A document-session revision. The owner of the document must never reuse a
/// value for different contents and must handle exhaustion explicitly.
public struct SpatialDocumentRevision: Codable, Equatable, Hashable, Sendable {
    public let session: UUID
    public let counter: UInt64

    public init(session: UUID, counter: UInt64) {
        self.session = session
        self.counter = counter
    }

    public static func newSession() -> Self {
        Self(session: UUID(), counter: 0)
    }

    public func advanced() throws -> Self {
        guard counter < UInt64.max else { throw CompiledInstrumentError.revisionOverflow }
        return Self(session: session, counter: counter + 1)
    }
}

public enum CompiledInstrumentError: Error, Equatable, Sendable {
    case unsupportedLatticeVersion(SpatialLatticeVersion)
    case invalidDetectionConfiguration
    case invalidMIDIEffects
    case invalidChannelLevel
    case incompatibleReusableIndex
    case invalidTempo
    case tooManyChannels(Int)
    case duplicateChannelID
    case revisionOverflow
    case duplicateRoutingID(UUID)
    case nonFiniteProgramValue(layerID: UUID, routingID: UUID)
    case nonFiniteOverrideValue(layerID: UUID, cell: PolarDeviceLattice)
    case invalidActiveHandle
    case staleActiveHandle
    case foreignActiveHandle
}

/// A handle returned by the compiled index. It is deliberately not publicly
/// constructible: callers must obtain it from `hits`, which proves painting,
/// layer membership and revision identity.
public struct CompiledActiveCell: Equatable, Sendable {
    public let layerID: UUID
    public let cell: PolarDeviceLattice
    public let revision: SpatialDocumentRevision
    public let candidateDistanceCentimeters: Double?
    public let candidateOrder: Int?

    internal init(layerID: UUID, cell: PolarDeviceLattice,
                  revision: SpatialDocumentRevision,
                  candidateDistanceCentimeters: Double? = nil, candidateOrder: Int? = nil) {
        self.layerID = layerID
        self.cell = cell
        self.revision = revision
        self.candidateDistanceCentimeters = candidateDistanceCentimeters
        self.candidateOrder = candidateOrder
    }

    /// The same cell reported under another layer identity (a partition shown as its layer).
    public func reassigningLayerID(_ id: UUID) -> CompiledActiveCell {
        Self(layerID: id, cell: cell, revision: revision, candidateDistanceCentimeters: candidateDistanceCentimeters, candidateOrder: candidateOrder)
    }

    internal func withCandidateDistance(_ distance: Double?, sourceOrder: Int? = nil) -> Self {
        Self(layerID: layerID, cell: cell, revision: revision,
             candidateDistanceCentimeters: distance, candidateOrder: sourceOrder ?? candidateOrder)
    }
}

public struct CompiledInstrumentStatistics: Equatable, Sendable {
    public let compiledLayerCount: Int
    public let indexedAddressCount: Int
    public let maxEntriesPerTick: Int
    public let overrideCellCount: Int
    public let dormantOverrideCells: Int
    public let ineligibleLayerCount: Int
    public let ineligibleOverrideCells: Int
    public let actionGroupCount: Int
    public let routingPlanCount: Int
    public let estimatedIndexBytes: Int

    internal init(compiledLayerCount: Int, indexedAddressCount: Int,
                  maxEntriesPerTick: Int, overrideCellCount: Int,
                  dormantOverrideCells: Int, ineligibleLayerCount: Int,
                  ineligibleOverrideCells: Int, actionGroupCount: Int,
                  routingPlanCount: Int, estimatedIndexBytes: Int) {
        self.compiledLayerCount = compiledLayerCount
        self.indexedAddressCount = indexedAddressCount
        self.maxEntriesPerTick = maxEntriesPerTick
        self.overrideCellCount = overrideCellCount
        self.dormantOverrideCells = dormantOverrideCells
        self.ineligibleLayerCount = ineligibleLayerCount
        self.ineligibleOverrideCells = ineligibleOverrideCells
        self.actionGroupCount = actionGroupCount
        self.routingPlanCount = routingPlanCount
        self.estimatedIndexBytes = estimatedIndexBytes
    }
}

public struct CompiledActionGroup: Equatable, Sendable {
    public let target: SpatialRoutingTarget
    public let summary: CompiledActionSummary

    internal init(target: SpatialRoutingTarget, summary: CompiledActionSummary) {
        self.target = target
        self.summary = summary
    }
}

public enum CompiledActionSummary: Equatable, Sendable {
    case programChange(SpatialProgramChange)
    case sceneSwitch(SpatialSceneSwitchAction)
    case releaseLayer(UUID)
    case notes([SpatialPlayedNote])
    case scalar(Double)
    case boolean(Bool)
}

public struct CompiledCellActions: Equatable, Sendable {
    public let cell: PolarDeviceLattice
    public let groups: [CompiledActionGroup]

    internal init(cell: PolarDeviceLattice, groups: [CompiledActionGroup]) {
        self.cell = cell
        self.groups = groups
    }
}

public struct CompiledRoutingPlan: Equatable, Sendable {
    public let id: UUID
    public let target: SpatialRoutingTarget
    public let program: SpatialValueProgram
    public let commonNotes: SpatialCommonNotes
    public let toggleGuardSeconds: Double
    internal let valuePlan: CompiledValuePlan
    internal let toggleRegionByCell: [PolarDeviceLattice: PolarDeviceLattice]

    internal init(_ routing: SpatialRouting, cells: [PolarDeviceLattice],
                  regions: [PolarDeviceLattice: PolarDeviceLattice], toggleGuardSeconds: Double, commonNotes: SpatialCommonNotes) {
        self.commonNotes = commonNotes
        id = routing.id
        target = routing.target
        program = routing.program
        // An unused layer setting must not change ordinary musical plans.
        self.toggleGuardSeconds = Self.isToggle(routing.program) ? toggleGuardSeconds : 0
        let plan = CompiledValuePlan(program: routing.program, cells: cells)
        valuePlan = plan
        // Compile edge-connected painted surfaces once, never on the scan path.
        // Own cell contents split surfaces so neighbouring loops stay independent.
        guard Self.isToggle(routing.program) else { toggleRegionByCell = [:]; return }
        toggleRegionByCell = regions
    }

    private static func isToggle(_ program: SpatialValueProgram) -> Bool {
        switch program {
        case .singleNote(_, _, .toggle), .chord(_, _, .toggle): return true
        default: return false
        }
    }
}

internal final class CompiledEvaluationProbe: @unchecked Sendable {
    private(set) var touchedRoutingCount = 0
    private(set) var overrideComparisons = 0

    fileprivate func noteOverrideComparison() { overrideComparisons += 1 }

    fileprivate func noteRouting() {
        touchedRoutingCount += 1
    }
}

public struct CompiledInstrumentLayer: Equatable, Sendable {
    public let midiTarget: InstrumentMIDITarget?
    public let id: UUID
    public let compiledLayerIndex: Int
    public let cells: [PolarDeviceLattice]
    public let routings: [CompiledRoutingPlan]
    public let cellActions: [CompiledCellActions]
    internal let snapRegionByCell: [PolarDeviceLattice: PolarDeviceLattice]
    internal let snapGeometry: [PolarDeviceLattice: [PolarMetricCellSegment]]

    /// Compiler emits overrides in the same (ring, sector) order as cells.
    /// Keep lookup logarithmic even for a fully overridden fine layer.
    internal func actions(for cell: PolarDeviceLattice, probe: CompiledEvaluationProbe?) -> CompiledCellActions? {
        var low = 0, high = cellActions.count
        while low < high {
            let middle = low + (high - low) / 2
            let current = cellActions[middle]
            probe?.noteOverrideComparison()
            if current.cell == cell { return current }
            if current.cell.ring < cell.ring || (current.cell.ring == cell.ring && current.cell.sector < cell.sector) {
                low = middle + 1
            } else { high = middle }
        }
        return nil
    }

    internal init(id: UUID, compiledLayerIndex: Int, cells: [PolarDeviceLattice],
                  routings: [CompiledRoutingPlan], cellActions: [CompiledCellActions],
                  snapRegionByCell: [PolarDeviceLattice: PolarDeviceLattice] = [:],
                  snapGeometry: [PolarDeviceLattice: [PolarMetricCellSegment]] = [:], midiTarget: InstrumentMIDITarget? = nil) {
        self.midiTarget = midiTarget
        self.id = id
        self.compiledLayerIndex = compiledLayerIndex
        self.cells = cells
        self.routings = routings
        self.cellActions = cellActions
        self.snapRegionByCell = snapRegionByCell
        self.snapGeometry = snapGeometry
    }
}

public struct CompiledInstrument: Equatable, Sendable {
    public let revision: SpatialDocumentRevision
    public let layers: [CompiledInstrumentLayer]
    public let statistics: CompiledInstrumentStatistics
    public let detection: DetectionConfiguration
    public let channel: InstrumentChannel
    public let channels: [InstrumentChannel]
    public let masterLevelDecibels: Double
    public let midiTarget: InstrumentMIDITarget?
    public let scenes: [SpatialScene]
    public let currentSceneID: UUID?
    /// Runtime identities (partitions) that play. A layer without surfaces is its own partition.
    public let activeLayerIDs: Set<UUID>
    /// Partition → owning layer for every compiled partition of a layer with surfaces. A partition
    /// of a layer without surfaces is absent: it is its own owner.
    public let partitionOwner: [UUID: UUID]
    /// Runtime-only provenance, never persisted in a preset. Nil is reserved
    /// for standalone engine callers without an asynchronous document mirror.
    public let sceneGeneration: UInt64?
    public let replacesScene: Bool

    internal struct IndexEntry: Equatable, Sendable {
        let ring: UInt16
        let compiledLayerIndex: UInt16
        let cellOffset: UInt32
    }

    private let columns: [[IndexEntry]]
    public let unavailableRoutingIDs: Set<UUID>
    let hasArpeggiatorModulation: Bool
    private let midiEffectChains: [UUID: CompiledMIDIEffectChain]

    internal init(revision: SpatialDocumentRevision, layers: [CompiledInstrumentLayer],
                  columns: [[IndexEntry]], statistics: CompiledInstrumentStatistics,
                  detection: DetectionConfiguration = .ownerDefaults, channel: InstrumentChannel = .init(),
                  channels: [InstrumentChannel]? = nil, masterLevelDecibels: Double = 0, midiTarget: InstrumentMIDITarget? = nil,
                  scenes: [SpatialScene] = [], currentSceneID: UUID? = nil,
                  activeLayerIDs: Set<UUID>? = nil, partitionOwner: [UUID: UUID] = [:],
                  midiEffectChains: [UUID: CompiledMIDIEffectChain]? = nil, sceneGeneration: UInt64? = nil, replacesScene: Bool = false) {
        self.revision = revision
        self.layers = layers
        self.columns = columns
        self.statistics = statistics
        self.detection = detection
        self.channel = channel
        self.channels = channels ?? [channel]
        let routings = layers.flatMap(\.routings)
        let unavailable = Set(routings.filter { !$0.target.isAvailable(in: channels ?? [channel]) }.map(\.id))
        unavailableRoutingIDs = unavailable
        hasArpeggiatorModulation = routings.contains {
            guard case .midiEffectParameter = $0.target else { return false }
            return !unavailable.contains($0.id)
        }
        self.midiEffectChains = midiEffectChains ?? Dictionary(uniqueKeysWithValues:
            (channels ?? [channel]).filter { $0.midiEffects.contains { !$0.bypassed } }
                .map { ($0.id, CompiledMIDIEffectChain($0.midiEffects)) })
        self.masterLevelDecibels = masterLevelDecibels
        self.midiTarget = midiTarget
        self.scenes = scenes
        self.currentSceneID = currentSceneID
        self.activeLayerIDs = activeLayerIDs ?? Set(layers.map(\.id))
        self.partitionOwner = partitionOwner
        self.sceneGeneration = sceneGeneration
        self.replacesScene = replacesScene
    }

    /// The layer a compiled layer (partition) belongs to; a layer without surfaces owns itself.
    public func ownerLayerID(of partitionID: UUID) -> UUID { partitionOwner[partitionID] ?? partitionID }

    public func stampingScene(generation: UInt64, replacing: Bool = false) -> Self {
        Self(revision: revision, layers: layers, columns: columns, statistics: statistics,
             detection: detection, channel: channel, channels: channels, masterLevelDecibels: masterLevelDecibels,
             midiTarget: midiTarget, scenes: scenes, currentSceneID: currentSceneID, activeLayerIDs: activeLayerIDs,
             partitionOwner: partitionOwner, midiEffectChains: midiEffectChains, sceneGeneration: generation, replacesScene: replacing)
    }

    /// Display-only detector settings with the existing immutable cell index.
    /// No compilation, revision advance or runtime installation is performed.
    public func previewingDetection(_ configuration: DetectionConfiguration) -> Self {
        Self(revision: revision, layers: layers, columns: columns, statistics: statistics,
             detection: configuration, channel: channel, channels: channels, masterLevelDecibels: masterLevelDecibels,
             midiTarget: midiTarget, scenes: scenes, currentSceneID: currentSceneID, activeLayerIDs: activeLayerIDs,
             partitionOwner: partitionOwner, midiEffectChains: midiEffectChains, sceneGeneration: sceneGeneration, replacesScene: replacesScene)
    }

    internal func withDocumentSettings(detection: DetectionConfiguration, channel: InstrumentChannel,
                                      channels: [InstrumentChannel]? = nil, masterLevelDecibels: Double = 0, midiTarget: InstrumentMIDITarget? = nil,
                                      scenes: [SpatialScene] = [], currentSceneID: UUID? = nil,
                                      revision newRevision: SpatialDocumentRevision? = nil,
                                      activeLayerIDs newActiveLayerIDs: Set<UUID>? = nil) -> Self {
        let nextChannels = channels ?? [channel]
        let reuseEffects = self.channels.count == nextChannels.count && zip(self.channels, nextChannels).allSatisfy {
            $0.id == $1.id && $0.midiEffects == $1.midiEffects
        }
        return Self(revision: newRevision ?? revision, layers: layers, columns: columns, statistics: statistics,
             detection: detection, channel: channel, channels: channels, masterLevelDecibels: masterLevelDecibels,
             midiTarget: midiTarget,
             scenes: scenes, currentSceneID: currentSceneID,
             activeLayerIDs: newActiveLayerIDs ?? activeLayerIDs, partitionOwner: partitionOwner,
             midiEffectChains: reuseEffects ? midiEffectChains : nil)
    }

    /// Finds painted cells at one exact device tick and raw distance.
    public func hits(tick: Int, raw: UInt16) -> [CompiledActiveCell] {
        guard let span = DeviceTickSpan.point(tick) else { return [] }
        return hits(span: span, raw: raw)
    }

    public func hits(tick: Int, raw: Int) -> [CompiledActiveCell] {
        guard raw >= 0, raw <= Int(UInt16.max) else { return [] }
        return hits(tick: tick, raw: UInt16(raw))
    }

    /// Finds one representative cell per layer: the smallest painted tick in
    /// the requested span at the requested raw distance.
    public func hits(span: DeviceTickSpan, raw: UInt16) -> [CompiledActiveCell] {
        guard UsableRawDistance.contains(raw) else { return [] }
        var selected: [Int: PolarDeviceLattice] = [:]
        for tick in span.lower...span.upper {
            for entry in entries(at: tick, ring: Int(raw)) {
                let compiledLayerIndex = Int(entry.compiledLayerIndex)
                guard selected[compiledLayerIndex] == nil else { continue }
                let layer = layers[compiledLayerIndex]
                selected[compiledLayerIndex] = layer.cells[Int(entry.cellOffset)]
            }
        }
        guard !selected.isEmpty else { return [] }
        return layers.enumerated().compactMap { index, layer in
            guard let cell = selected[index] else { return nil }
            return CompiledActiveCell(layerID: layer.id, cell: cell, revision: revision)
        }
    }

    public func hits(ticks: DeviceTickSpan, raw: UInt16) -> [CompiledActiveCell] {
        hits(span: ticks, raw: raw)
    }

    public func hits(ticks: DeviceTickSpan, raw: Int) -> [CompiledActiveCell] {
        hits(span: ticks, raw: raw)
    }

    public func hits(span: DeviceTickSpan, raw: Int) -> [CompiledActiveCell] {
        guard raw >= 0, raw <= Int(UInt16.max) else { return [] }
        return hits(span: span, raw: UInt16(raw))
    }

    /// Transfers only an already selected, still painted carrier. No hit
    /// search or substitute measurement can select a different cell here.
    internal func transferring(_ handle: CompiledActiveCell) -> CompiledActiveCell? {
        guard handle.revision.session == revision.session,
              let layer = layers.first(where: { $0.id == handle.layerID }),
              containsCell(handle.cell, in: layer.cells) else { return nil }
        return .init(layerID: handle.layerID, cell: handle.cell, revision: revision,
                     candidateDistanceCentimeters: handle.candidateDistanceCentimeters, candidateOrder: handle.candidateOrder)
    }

    public func evaluate(
        active: [UUID: CompiledActiveCell], activeLayerIDs: Set<UUID>? = nil
    ) throws -> [SpatialRoutingEvaluation] {
        try evaluate(active: active, activeLayerIDs: activeLayerIDs, probe: nil)
    }

    internal func evaluate(
        active: [UUID: CompiledActiveCell], activeLayerIDs: Set<UUID>? = nil, probe: CompiledEvaluationProbe?
    ) throws -> [SpatialRoutingEvaluation] {
        try validate(active)
        return layers.flatMap { layer -> [SpatialRoutingEvaluation] in
            guard activeLayerIDs?.contains(layer.id) ?? true else { return [] }
            guard let handle = active[layer.id] else {
                return layer.routings.map { routing in
                    probe?.noteRouting()
                    if unavailableRoutingIDs.contains(routing.id) {
                        return SpatialRoutingEvaluation(routingID: routing.id, target: routing.target, value: .inactive)
                    }
                    let value: SpatialEvaluatedValue
                    switch routing.target {
                    case .midiAllNotesOff, .audioUnitAllNotesOff, .sceneSwitch, .releaseLayer:
                        value = .boolean(false)
                    default:
                        value = routing.valuePlan.value(activeCell: nil, candidateDistanceCentimeters: nil)
                    }
                    return SpatialRoutingEvaluation(
                        routingID: routing.id, target: routing.target,
                        value: value
                    )
                }
            }
            return layer.routings.map { routing in
                probe?.noteRouting()
                if unavailableRoutingIDs.contains(routing.id) {
                    return SpatialRoutingEvaluation(routingID: routing.id, target: routing.target, value: .inactive)
                }
                let value: SpatialEvaluatedValue
                if case .midiAllNotesOff = routing.target {
                    value = .boolean(true)
                } else if case .audioUnitAllNotesOff = routing.target {
                    value = .boolean(true)
                } else if routing.target.isLayerControl {
                    value = .boolean(true)
                } else if let summary = layer.actions(for: handle.cell, probe: probe)?
                    .groups.first(where: { $0.target == routing.target })?.summary {
                    value = Self.evaluated(summary: summary, transition: Self.transition(of: routing.program))
                } else {
                    value = routing.valuePlan.value(
                        activeCell: handle.cell,
                        candidateDistanceCentimeters: handle.candidateDistanceCentimeters
                    )
                }
                let effectedValue = routing.target.stripID.flatMap { midiEffectChains[$0] }?.apply(value) ?? value
                let entryCell: PolarDeviceLattice?
                if case .notes(_, .toggle) = value {
                    entryCell = routing.toggleRegionByCell[handle.cell] ?? handle.cell
                } else { entryCell = nil }
                var evaluation = SpatialRoutingEvaluation(routingID: routing.id, target: routing.target, value: effectedValue, cell: entryCell,
                                                toggleGuardSeconds: routing.toggleGuardSeconds, commonNotes: routing.commonNotes)
                evaluation.displayCell = handle.cell
                evaluation.midiDestination = layer.midiTarget.flatMap {
                    $0.uniqueID == (midiTarget?.uniqueID ?? 0) ? nil : .midiEndpoint(uniqueID: $0.uniqueID)
                } ?? .midi
                return evaluation
            }
        }
    }

    private static func evaluated(
        summary: CompiledActionSummary, transition: SpatialNoteTransition
    ) -> SpatialEvaluatedValue {
        switch summary {
        case .programChange(let selection): return .programChange(selection)
        case .notes(let notes): return .notes(Set(notes), transition: transition)
        case .scalar(let value): return .scalar(value)
        case .boolean(let value): return .boolean(value)
        case .sceneSwitch, .releaseLayer: return .boolean(true)
        }
    }

    private static func transition(of program: SpatialValueProgram) -> SpatialNoteTransition {
        switch program {
        case .scale(_, _, _, _, _, _, let transition),
             .randomScale(_, _, _, _, _, let transition),
             .chord(_, _, let transition): return transition
        case .singleNote(_, _, let transition): return transition
        case .constant, .continuous, .programChange: return .retrigger
        }
    }

    /// Internal measurement hook for M-4. Search comparisons and payload
    /// entries are separate so an empty/one-entry column is observable.
    internal func measuredHits(tick: Int, raw: UInt16) -> (hits: [CompiledActiveCell], comparisons: Int, visitedEntries: Int) {
        guard DeviceTickSpan.point(tick) != nil, UsableRawDistance.contains(raw) else { return ([], 0, 0) }
        let result = lowerBoundEntries(in: columns[tick], ring: Int(raw))
        var end = result.index
        while end < columns[tick].count, Int(columns[tick][end].ring) == Int(raw) { end += 1 }
        let entries = result.index < end && result.index < columns[tick].count && Int(columns[tick][result.index].ring) == Int(raw)
            ? Array(columns[tick][result.index..<end]) : []
        let mapped = mapEntries(entries)
        return (mapped, result.comparisons, entries.count)
    }

    private func entries(at tick: Int, ring: Int) -> [IndexEntry] {
        guard tick >= 0, tick < columns.count else { return [] }
        // Most wall returns are outside the painted radial extent. The
        // sorted index proves absence at its endpoints without binary search
        // or allocating layer dictionaries for every unpainted return.
        guard let first = columns[tick].first, let last = columns[tick].last,
              ring >= Int(first.ring), ring <= Int(last.ring) else { return [] }
        let result = lowerBoundEntries(in: columns[tick], ring: ring)
        guard result.index < columns[tick].count, Int(columns[tick][result.index].ring) == ring else { return [] }
        var end = result.index
        while end < columns[tick].count, Int(columns[tick][end].ring) == ring { end += 1 }
        return Array(columns[tick][result.index..<end])
    }

    private func lowerBoundEntries(in entries: [IndexEntry], ring: Int) -> (index: Int, comparisons: Int) {
        var low = 0
        var high = entries.count
        var comparisons = 0
        while low < high {
            let middle = low + (high - low) / 2
            comparisons += 1
            if Int(entries[middle].ring) < ring { low = middle + 1 } else { high = middle }
        }
        return (low, comparisons)
    }

    private func mapEntries(_ entries: [IndexEntry]) -> [CompiledActiveCell] {
        entries.map { entry in
            let layer = layers[Int(entry.compiledLayerIndex)]
            return CompiledActiveCell(layerID: layer.id,
                                      cell: layer.cells[Int(entry.cellOffset)],
                                      revision: revision)
        }
    }

    internal func validate(_ active: [UUID: CompiledActiveCell]) throws {
        for layer in layers {
            guard let handle = active[layer.id] else { continue }
            guard handle.layerID == layer.id else { throw CompiledInstrumentError.invalidActiveHandle }
            guard handle.revision.session == revision.session else {
                throw CompiledInstrumentError.foreignActiveHandle
            }
            guard handle.revision.counter == revision.counter else {
                throw CompiledInstrumentError.staleActiveHandle
            }
            guard containsCell(handle.cell, in: layer.cells), handle.cell.ring > 0 else {
                throw CompiledInstrumentError.foreignActiveHandle
            }
        }
        for (layerID, handle) in active where !layers.contains(where: { $0.id == layerID }) {
            guard handle.layerID == layerID else { throw CompiledInstrumentError.invalidActiveHandle }
            throw CompiledInstrumentError.foreignActiveHandle
        }
    }

}

/// Binary membership for compiler-sorted device addresses.
internal func containsCell(_ cell: PolarDeviceLattice, in cells: [PolarDeviceLattice]) -> Bool {
    var low = 0
    var high = cells.count
    while low < high {
        let middle = low + (high - low) / 2
        let current = cells[middle]
        if current.ring == cell.ring && current.sector == cell.sector { return true }
        if current.ring < cell.ring || (current.ring == cell.ring && current.sector < cell.sector) {
            low = middle + 1
        } else {
            high = middle
        }
    }
    return false
}
