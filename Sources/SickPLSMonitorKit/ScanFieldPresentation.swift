import Foundation
import PlanariumDomain

/// Pure display policy; object evidence has already been grouped on Q.
public struct ScanFieldPresentation {
    public let showsRawScan: Bool
    public let objects: [DetectionObject]
    public let contour: [MetricScanPoint?]
    public let scatterNotice: String?
    public init(contour room: SpatialRoomContour?, matches: Bool, configuration: SpatialRoomContourConfiguration,
                showRawScan: Bool, objects: [DetectionObject]) {
        let active = room != nil && matches && configuration.isEnabled
        showsRawScan = !active || showRawScan
        self.objects = active ? objects : []
        contour = active ? room!.nearestDistancesCentimeters.indices.map { index in
            guard let distance = room!.nearestDistancesCentimeters[index] else { return nil }
            let bearing = room!.geometry.startAngleDegrees + Double(index) * room!.geometry.angleResolutionDegrees
            return .init(xMeters: sin(bearing * .pi / 180) * Double(distance)/100,
                         yMeters: cos(bearing * .pi / 180) * Double(distance)/100)
        } : []
        let scatter = Int(room?.measuredScatterCentimeters ?? 0)
        let tolerance = Int(configuration.toleranceCentimeters)
        scatterNotice = active && tolerance < 3
            ? "Wall scatter ±\(scatter) cm — stable nearest boundary; suggest 3 cm tolerance for future scan variation."
            : nil
    }
}

/// View-owned canonical Snap regions keyed by the authoritative document owner.
/// Compiled data remains behind MonitorKit; only display shapes leave this cache.
@MainActor public final class SnapRegionOverlayCache {
    public init() {}
    private var snapRevision: SpatialDocumentRevision?
    private var snapGrid: MetricSquareGrid?
    private var snapInstrument: CompiledInstrument?
    private var snapActiveLayers: Set<UUID> = []
    public private(set) var compilationCount = 0

    /// Display-owned canonical regions, including the first drag from Snap Off.
    /// Scalar previews reuse this cache; nothing is installed in the runtime.
    public func presentation(document: InstrumentDocument, layerID: UUID, centimeters: UInt16) -> DetectionOverlayPresentation {
        let activeLayers = Set(document.spatial.layers.filter(\.isActive).map(\.id))
        if snapRevision != document.revision || snapGrid != document.editorGrid || snapActiveLayers != activeLayers {
            var displayDocument = document
            displayDocument.detection.cellSelection.boundaryMarginCentimeters = 1
            snapInstrument = try? InstrumentCompiler.compile(displayDocument)
            snapRevision = document.revision
            snapGrid = document.editorGrid
            snapActiveLayers = activeLayers
            compilationCount += 1
        }
        guard let snapInstrument else { return .empty }
        return .cellMargins(instrument: snapInstrument, layerID: layerID, centimeters: centimeters)
    }
}
