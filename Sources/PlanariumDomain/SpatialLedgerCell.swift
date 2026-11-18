import Foundation
import PLSDeviceValues
import PlanariumMusicCore

/// The scanner's activation identity is its polar device cell.
public typealias SpatialRoutingEvaluation = RoutingEvaluation<PolarDeviceLattice>
public typealias SpatialNoteLedger = NoteLedger<PolarDeviceLattice>

extension PolarDeviceLattice: LedgerCell {
    /// A neighbour continues the same measured hand when it lies within one hand
    /// width (10 cm) of the previous Hold owner, measured in the scan plane.
    public func continuesContact(from previous: PolarDeviceLattice) -> Bool {
        func point(_ cell: PolarDeviceLattice) -> (Double, Double) {
            let angle = (Double(cell.sector) * 0.5 - 90) * Double.pi / 180
            return (Double(cell.ring) * sin(angle), Double(cell.ring) * cos(angle))
        }
        let n = point(self), p = point(previous)
        return hypot(n.0 - p.0, n.1 - p.1) <= 10
    }
}

extension NoteLedger where Cell == PolarDeviceLattice {
    /// Editing one painted surface leaves separate loops in the layer intact.
    internal mutating func retainToggleCells(from current: CompiledInstrument?, to replacement: CompiledInstrument) -> [SpatialOutputCommand] {
        retainToggles { routingID, cell in
            guard let current, current.revision.session == replacement.revision.session,
                  let old = current.layers.first(where: { $0.routings.contains { $0.id == routingID } }),
                  let new = replacement.layers.first(where: { $0.id == old.id }),
                  containsCell(cell, in: old.cells), containsCell(cell, in: new.cells),
                  let routing = old.routings.first(where: { $0.id == routingID }),
                  let newRouting = new.routings.first(where: { $0.id == routingID }),
                  routing.target == newRouting.target, routing.program == newRouting.program, old.midiTarget == new.midiTarget else { return false }
            let oldRegion = Set(routing.toggleRegionByCell.filter { $0.value == cell }.map(\.key))
            let newRegion = Set(newRouting.toggleRegionByCell.filter { $0.value == cell }.map(\.key))
            guard oldRegion == newRegion else { return false }
            let oldHandle = CompiledActiveCell(layerID: old.id, cell: cell, revision: current.revision)
            let newHandle = CompiledActiveCell(layerID: new.id, cell: cell, revision: replacement.revision)
            let oldValue = try? current.evaluate(active: [old.id: oldHandle], activeLayerIDs: [old.id]).first { $0.routingID == routingID }?.value
            let newValue = try? replacement.evaluate(active: [new.id: newHandle], activeLayerIDs: [new.id]).first { $0.routingID == routingID }?.value
            guard let oldValue, let newValue else { return false }
            return oldValue == newValue
        }
    }
}
