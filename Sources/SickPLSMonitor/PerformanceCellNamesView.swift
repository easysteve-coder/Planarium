import SwiftUI
import PlanariumDomain
import SickPLSMonitorKit

/// Names only from the runtime's measured active carriers, never prediction.
struct PerformanceCellNamesView: View {
    let cells: SpatialActiveCellDisplayModel
    @State private var activeCells: [UUID: Set<PolarMetricGridCell>] = [:]
    let workspace: SpatialInstrumentWorkspace
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("performance.names")
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(PerformanceCellNames.titles(workspace: workspace, hands: activeCells), id: \.self) { title in
                        Text(title).font(.system(size: 30, weight: .semibold))
                    }
                }.padding(12).background(Color.black.opacity(0.45)).cornerRadius(8)
                Spacer()
            }
            Spacer()
        }.padding(12).accessibilityIdentifier("performance.activeCells")
            .onReceive(cells.$frame.map(\.allHands).removeDuplicates()) { next in
                if activeCells != next { activeCells = next }
            }
    }
}

enum PerformanceCellNames {
    static func titles(workspace: SpatialInstrumentWorkspace, activeCells: [UUID: PolarMetricGridCell]) -> [String] {
        titles(workspace: workspace, hands: activeCells.mapValues { [$0] })
    }
    /// One title per measured hand: two hands in one layer name both of their values.
    static func titles(workspace: SpatialInstrumentWorkspace, hands: [UUID: Set<PolarMetricGridCell>]) -> [String] {
        let audible = SpatialLayerAudibility.audibleIDs(workspace.layers.map { ($0.id, $0.isActive, $0.isSoloed) })
        var seen = Set<String>()
        return workspace.layers.flatMap { layer -> [String] in
            guard layer.isVisible, audible.contains(layer.id),
                  !layer.routings.contains(where: { $0.target.isLayerControl }),
                  let cells = hands[layer.id] else { return [] }
            return cells.sorted { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }.compactMap { cell in
                guard let value = SpatialCellInfo.make(cell: cell, layerID: layer.id, workspace: workspace)?.valueText else { return nil }
                let title = layer.name == value ? value : "\(layer.name) · \(value)"
                return seen.insert(title).inserted ? title : nil
            }
        }
    }
}
