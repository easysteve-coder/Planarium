import CoreGraphics
import Foundation
import PlanariumDomain

/// Synchronous gesture storage. All geometry and source selection are fixed
/// at arming; preview has no document side effects.
public struct CanvasGestureController: Equatable, Sendable {
    public enum Input: Equatable, Sendable {
        case arm(CGPoint, modifiers: SelectionModifiers, brush: Bool)
        case armPan(CGPoint)
        case drag(CGPoint)
        case release(CGPoint)
        case cancel
    }
    public enum Phase: Equatable, Sendable {
        case idle, armed, panning, moving, resizing(CanvasSelectionHandle), painting, erasing, selecting
    }
    enum Drag: Equatable, Sendable {
        case pan(startPoint: CGPoint, startViewport: MetricCanvasViewport)
        case select(startPoint: CGPoint, currentPoint: CGPoint, modifiers: SelectionModifiers, brush: Bool, brushCells: Set<PolarMetricGridCell>)
        case move(startPoint: CGPoint, currentPoint: CGPoint, copy: Bool)
        case resize(startPoint: CGPoint, currentPoint: CGPoint, handle: CanvasSelectionHandle)
        case draw(currentPoint: CGPoint, cells: Set<PolarMetricGridCell>, erase: Bool)
    }
    var drag: Drag?
    var canvasSize: CGSize?
    var geometry: MetricCanvasGeometry?
    var selectionBefore: Set<CanvasCellSelection>?
    var wasAnchored = true
    var armed = false
    public var preview: Set<PolarMetricGridCell> = []
    public var rectangle: CGRect?
    public init() {}
    public var phase: Phase {
        guard let drag else { return .idle }
        if armed { return .armed }
        switch drag {
        case .pan: return .panning
        case .move: return .moving
        case let .resize(_, _, handle): return .resizing(handle)
        case let .draw(_, _, erase): return erase ? .erasing : .painting
        case .select: return .selecting
        }
    }
    public static let handleSize: CGFloat = 16
    /// Reducer context is freshly assembled from the independent owners.
    /// Only release can return an authoring command.
    @discardableResult public mutating func reduce(_ input: Input, canvasSize: CGSize,
                                                  context: inout MetricCanvasInteractionState) -> CanvasDocumentCommand? {
        context.gesture = self
        context.clearPendingCommand()
        switch input {
        case let .arm(point, modifiers, brush): _ = context.beginDrag(at: point, canvasSize: canvasSize, modifiers: modifiers, brush: brush)
        case let .armPan(point): _ = context.beginViewportDrag(at: point, canvasSize: canvasSize)
        case let .drag(point): _ = context.updateDrag(to: point, canvasSize: canvasSize)
        case let .release(point):
            _ = context.updateDrag(to: point, canvasSize: canvasSize)
            context.endDrag(canvasSize: canvasSize)
        case .cancel: _ = context.handleKey(.escape)
        }
        self = context.gesture
        return context.command
    }
}

/// All editor screen/polar operations use this projection and context radius.
public struct PolarProjection: Equatable, Sendable {
    public let geometry: MetricCanvasGeometry
    public let maximumRadius: Double
    public init(geometry: MetricCanvasGeometry, maximumRadius: Double) {
        self.geometry = geometry; self.maximumRadius = maximumRadius
    }
    public func point(at screen: CGPoint) -> (radius: Double, bearing: Double, isClamped: Bool)? {
        guard let metric = geometry.metricPoint(forScreenPoint: screen) else { return nil }
        // Orthogonal projection onto the front half-plane is continuous at
        // +/-90 degrees and never mirrors a pointer behind the scanner.
        let forward = max(0, metric.yMeters)
        let radius = hypot(metric.xMeters, forward)
        return (min(maximumRadius, radius), atan2(metric.xMeters, forward) * 180 / .pi, radius > maximumRadius || metric.yMeters < 0)
    }
    public func screenPoint(radius: Double, bearing: Double) -> CGPoint {
        let radians = bearing * .pi / 180
        return geometry.screenPoint(for: .init(xMeters: sin(radians) * radius, yMeters: cos(radians) * radius))
    }
    public func cell(at screen: CGPoint, grid: MetricSquareGrid) -> PolarMetricGridCell? {
        guard let polar = point(at: screen), !polar.isClamped, polar.radius < maximumRadius else { return nil }
        let radians = polar.bearing * .pi / 180
        return .init(point: .init(xMeters: sin(radians) * polar.radius, yMeters: cos(radians) * polar.radius), grid: grid)
    }
}
