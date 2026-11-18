import CoreGraphics
import SickPLSControlCore


/// Einziger Bildschirm-Rundlauf der metrischen Arbeitsfläche. Bildschirm-Y
/// wächst nach unten, Welt-Y nach vorn/oben.
public struct MetricCanvasGeometry: Equatable, Sendable {
    public let canvasRect: CGRect
    public let viewport: MetricCanvasViewport
    public let isHorizontallyMirrored: Bool

    public init(
        size: CGSize,
        viewport: MetricCanvasViewport,
        isHorizontallyMirrored: Bool = false
    ) {
        self.canvasRect = CGRect(origin: .zero, size: size)
        self.viewport = viewport
        self.isHorizontallyMirrored = isHorizontallyMirrored
    }

    /// Reine Orientierungsmarke, unabhängig vom Viewport.
    public var canvasBaselineY: CGFloat { canvasRect.maxY - 1 }

    /// Verschiebt um eine **Bildschirmstrecke** und kennt dabei die
    /// Spiegelung. Ohne sie liefe das Verschieben bei gespiegelter
    /// Darstellung horizontal verkehrt herum -- Zoomen und Malen rechnen
    /// seit jeher über diese Geometrie, das Verschieben tat es nicht
    /// (Ownerbefund 28.09.2026).
    public func panned(byScreenX deltaX: Double, screenY deltaY: Double) -> MetricCanvasViewport? {
        guard deltaX.isFinite, deltaY.isFinite else { return nil }
        let effectiveX = isHorizontallyMirrored ? -deltaX : deltaX
        return try? MetricCanvasViewport.build(
            centerXMeters: viewport.centerXMeters - effectiveX * viewport.metersPerPoint,
            centerYMeters: viewport.centerYMeters + deltaY * viewport.metersPerPoint,
            metersPerPoint: viewport.metersPerPoint
        )
    }

    public func screenPoint(for point: MetricScanPoint) -> CGPoint {
        let horizontal = CGFloat((point.xMeters - viewport.centerXMeters) / viewport.metersPerPoint)
        return CGPoint(
            x: canvasRect.midX + (isHorizontallyMirrored ? -horizontal : horizontal),
            y: canvasRect.midY - CGFloat((point.yMeters - viewport.centerYMeters) / viewport.metersPerPoint)
        )
    }

    public func metricPoint(forScreenPoint point: CGPoint) -> MetricScanPoint? {
        guard point.x.isFinite, point.y.isFinite,
              canvasRect.width > 0, canvasRect.height > 0 else { return nil }
        return MetricScanPoint(
            xMeters: viewport.centerXMeters
                + Double(point.x - canvasRect.midX) * viewport.metersPerPoint
                    * (isHorizontallyMirrored ? -1 : 1),
            yMeters: viewport.centerYMeters - Double(point.y - canvasRect.midY) * viewport.metersPerPoint
        )
    }

    public func clampedScreenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, canvasRect.minX), canvasRect.maxX),
            y: min(max(point.y, canvasRect.minY), canvasRect.maxY)
        )
    }

    public func boundedMetricPoint(forScreenPoint point: CGPoint) -> MetricScanPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return metricPoint(forScreenPoint: clampedScreenPoint(point))
    }

    public func isVisible(_ point: MetricScanPoint) -> Bool {
        canvasRect.contains(screenPoint(for: point))
    }
}
