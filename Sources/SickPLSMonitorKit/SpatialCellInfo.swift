import PlanariumDomain
import Foundation
import SickPLSControlCore

public enum SpatialCellValueOrigin: Equatable, Sendable {
    case layerAssignment
    case cellOverride
}

public struct SpatialCellInfo: Equatable, Sendable {
    public let layerID: UUID
    public let layerName: String
    public let segment: PolarMetricCellSegment
    public let target: SpatialRoutingTarget?
    public let value: SpatialEvaluatedValue
    public let valueText: String?
    public let origin: SpatialCellValueOrigin?
    public let transition: SpatialNoteTransition?
    public let ringText: String
    public let angleText: String

    public static func make(
        cell: PolarMetricGridCell,
        layerID: UUID,
        workspace: SpatialInstrumentWorkspace
    ) -> SpatialCellInfo? {
        guard let layer = workspace.layers.first(where: { $0.id == layerID }),
              layer.polarCells.contains(cell) else { return nil }

        let segment = PolarMetricCellSegment(cell: cell, grid: workspace.grid)
        let routing = layer.routings.first
        let value = SpatialInstrumentEvaluator().cellValues(
            layerID: layerID, cells: [cell], workspace: workspace
        )[cell] ?? .inactive
        let origin: SpatialCellValueOrigin?
        if let target = routing?.target,
           (layer.polarCellOverrides[cell] ?? []).contains(where: { $0.target == target }) {
            origin = .cellOverride
        } else {
            origin = routing == nil ? nil : .layerAssignment
        }

        let transition: SpatialNoteTransition?
        if case .notes(_, let noteTransition) = value {
            transition = noteTransition
        } else {
            transition = nil
        }

        return SpatialCellInfo(
            layerID: layerID,
            layerName: layer.name,
            segment: segment,
            target: routing?.target,
            value: value,
            valueText: SpatialReleaseLayerPresentation.target(cell: cell, layer: layer).map { "Release " + SpatialReleaseLayerPresentation.name($0, workspace: workspace) }
                ?? routing.map { SpatialCellLabel.text(for: value, target: $0.target) } ?? nil,
            origin: origin,
            transition: transition,
            ringText: Self.ringText(for: segment),
            angleText: Self.angleText(for: segment)
        )
    }

    private static func ringText(for segment: PolarMetricCellSegment) -> String {
        return String(format: "Ring %.2f–%.2f m", locale: Locale(identifier: "en_US"), segment.innerRadiusMeters, segment.outerRadiusMeters)
    }

    private static func angleText(for segment: PolarMetricCellSegment) -> String {
        let locale = Locale(identifier: "en_US")
        let start = formattedDegrees(segment.startBearingDegrees, locale: locale)
        let end = formattedDegrees(segment.endBearingDegrees, locale: locale)
        return "Angle \(start)…\(end)°"
    }

    private static func formattedDegrees(_ value: Double, locale: Locale) -> String {
        let text = String(format: "%.1f", locale: locale, value)
        return text.replacingOccurrences(of: "-", with: "−")
    }

    private init(
        layerID: UUID,
        layerName: String,
        segment: PolarMetricCellSegment,
        target: SpatialRoutingTarget?,
        value: SpatialEvaluatedValue,
        valueText: String?,
        origin: SpatialCellValueOrigin?,
        transition: SpatialNoteTransition?,
        ringText: String,
        angleText: String
    ) {
        self.layerID = layerID
        self.layerName = layerName
        self.segment = segment
        self.target = target
        self.value = value
        self.valueText = valueText
        self.origin = origin
        self.transition = transition
        self.ringText = ringText
        self.angleText = angleText
    }
}
