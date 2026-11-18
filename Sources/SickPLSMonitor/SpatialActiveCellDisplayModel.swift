import Combine
import Foundation
import SickPLSCore
import SickPLSMonitorKit
import PlanariumDomain
import PlanariumRuntime
import SickPLSControlCore

struct SpatialDisplayFrame: Equatable {
    /// Every hand per layer: the explicit sets, else the single representative of each layer.
    var allHands: [UUID: Set<PolarMetricGridCell>] {
        handCells.isEmpty ? activeCells.mapValues { [$0] } : handCells
    }
    let profile: B0ScanProfile?
    let activeCells: [UUID: PolarMetricGridCell]
    var heldCells: [UUID: Set<PolarMetricGridCell>] = [:]
    /// Every measured hand per owning layer. Several hands (surfaces) of one layer are all shown;
    /// `activeCells` keeps one per layer for the callers that only need a representative.
    var handCells: [UUID: Set<PolarMetricGridCell>] = [:]
    var projectedMeasurements: [ProjectedScanMeasurement] = []
    var sessionID: UUID?
    var sequence: UInt64?
    var sourceFrame: ProfileFrame?
    var confirmationProgress: [DetectionConfirmationProgress] = []
}

/// Der sichtbare aktive Zellzustand ist bewusst vom Laufzeitmodell getrennt.
/// Die View erhält damit genau den bereits für den Klang gewählten Zellwert,
/// ohne den Selector ein zweites Mal auszuführen.
@MainActor final class SpatialActiveCellDisplayModel: ObservableObject {
    static func tile(_ cell: PolarDeviceLattice, grid: MetricSquareGrid) -> PolarMetricGridCell? {
        try? LegacyLatticeMigration.project(cell, in: grid)
    }
    @Published private(set) var frame = SpatialDisplayFrame(profile: nil, activeCells: [:])

    var activeCells: [UUID: PolarMetricGridCell] { frame.activeCells }
    /// All measured hands per layer (several for a layer with more than one surface).
    var activeCellSets: [UUID: Set<PolarMetricGridCell>] { frame.allHands }
    var latestProfile: B0ScanProfile? { frame.profile }

    func update(_ cells: [UUID: PolarMetricGridCell]) {
        update(profile: frame.profile, activeCells: cells)
    }

    func update(profile: B0ScanProfile?, activeCells: [UUID: PolarMetricGridCell]) {
        guard frame.profile != profile || frame.activeCells != activeCells || !frame.heldCells.isEmpty else { return }
        let source: ProfileFrame?
        if let profile, let geometry = try? FullScanProfileAdapter.geometry(from: profile),
           let measurements = try? FullScanProfileAdapter.measurements(from: profile, geometry: geometry) {
            source = ProfileFrame(sessionID: UUID(), sequence: 0, time: 0, measurements: measurements,
                                  geometry: geometry, rawProfile: profile)
        } else { source = nil }
        let next = SpatialDisplayFrame(profile: profile, activeCells: activeCells,
                                       projectedMeasurements: source?.projectedMeasurements ?? [], sourceFrame: source)
        frame = next
    }

    func update(profileFrame: ProfileFrame?, activeCells: [UUID: PolarMetricGridCell], heldCells: [UUID: Set<PolarMetricGridCell>] = [:], handCells: [UUID: Set<PolarMetricGridCell>] = [:], confirmationProgress: [DetectionConfirmationProgress] = []) {
        // Session + sequence identify immutable acquisition data. Cells may
        // still change on a command with the same profile (Stop/PANIC/install).
        guard frame.sessionID != profileFrame?.sessionID || frame.sequence != profileFrame?.sequence ||
              (profileFrame == nil && frame.profile != nil) || frame.activeCells != activeCells || frame.handCells != handCells || frame.heldCells != heldCells || frame.confirmationProgress != confirmationProgress else { return }
        let next = SpatialDisplayFrame(profile: profileFrame?.rawProfile, activeCells: activeCells, heldCells: heldCells, handCells: handCells,
                                      projectedMeasurements: profileFrame?.projectedMeasurements ?? [],
                                      sessionID: profileFrame?.sessionID, sequence: profileFrame?.sequence, sourceFrame: profileFrame, confirmationProgress: confirmationProgress)
        frame = next
    }

    /// Hold decoration follows sounding receipts. A geometric candidate that
    /// lost the channel competition must not look like a sounding chord.
    func update(_ display: DisplayFrame, workspace: SpatialInstrumentWorkspace) {
        let holdOnly = Set(workspace.layers.filter { layer in
            !layer.routings.isEmpty && layer.routings.allSatisfy {
                SpatialAssignmentDraft.from(program: $0.program, target: $0.target).transition == .holdUntilNext
            }
        }.map(\.id))
        let soundingHolds = Set(display.heldCells.map(\.layerID))
        var active: [UUID: PolarMetricGridCell] = [:]
        for handle in display.activeCells where !holdOnly.contains(handle.layerID) || soundingHolds.contains(handle.layerID) {
            active[handle.layerID] = Self.tile(handle.cell, grid: workspace.grid)
        }
        var hands: [UUID: Set<PolarMetricGridCell>] = [:]
        for handle in display.activeCells where !holdOnly.contains(handle.layerID) || soundingHolds.contains(handle.layerID) {
            if let tile = Self.tile(handle.cell, grid: workspace.grid) { hands[handle.layerID, default: []].insert(tile) }
        }
        var held: [UUID: Set<PolarMetricGridCell>] = [:]
        for handle in display.heldCells {
            if let tile = Self.tile(handle.cell, grid: workspace.grid) { held[handle.layerID, default: []].insert(tile) }
        }
        update(profileFrame: display.profile, activeCells: active, heldCells: held, handCells: hands, confirmationProgress: display.selection.confirmationProgress)
    }

    func reset() {
        update([:])
    }
}
