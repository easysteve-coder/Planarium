/// Metrischer, isotroper Ausschnitt der kartesischen Instrumentfläche.
/// `metersPerPoint` ist auf beiden Achsen gleich; Zoom kann die Geometrie
/// deshalb niemals verzerren.
public struct MetricCanvasViewport: Equatable, Sendable {
    public enum BuildError: Error, Equatable, Sendable {
        case nonFiniteCenter
        case metersPerPointNotPositive(Double)
        case metersPerPointOutOfRange(Double)
    }

    public static let minimumMetersPerPoint = 0.0005
    public static let maximumMetersPerPoint = 0.25

    public let centerXMeters: Double
    public let centerYMeters: Double
    public let metersPerPoint: Double

    private init(centerXMeters: Double, centerYMeters: Double, metersPerPoint: Double) {
        self.centerXMeters = centerXMeters
        self.centerYMeters = centerYMeters
        self.metersPerPoint = metersPerPoint
    }

    public static func build(
        centerXMeters: Double,
        centerYMeters: Double,
        metersPerPoint: Double
    ) throws -> MetricCanvasViewport {
        guard centerXMeters.isFinite, centerYMeters.isFinite else {
            throw BuildError.nonFiniteCenter
        }
        guard metersPerPoint.isFinite, metersPerPoint > 0 else {
            throw BuildError.metersPerPointNotPositive(metersPerPoint)
        }
        guard Self.minimumMetersPerPoint...Self.maximumMetersPerPoint ~= metersPerPoint else {
            throw BuildError.metersPerPointOutOfRange(metersPerPoint)
        }
        return MetricCanvasViewport(
            centerXMeters: centerXMeters,
            centerYMeters: centerYMeters,
            metersPerPoint: metersPerPoint
        )
    }

    /// Startansicht: bei 800 pt Höhe liegen Scannerursprung und untere
    /// Rasterkante zusammen, sichtbar sind ungefähr acht Meter nach vorn.
    public static let instrumentDefault = try! MetricCanvasViewport.build(
        centerXMeters: 0,
        centerYMeters: 4,
        metersPerPoint: 0.01
    )

    /// `factor > 1` zoomt hinein. Der metrische Punkt unter dem Zeiger
    /// behält dabei exakt seine Bildschirmposition.
    public func zoomed(byFactor factor: Double, anchor: MetricScanPoint) -> MetricCanvasViewport? {
        guard factor.isFinite, factor > 0,
              anchor.xMeters.isFinite, anchor.yMeters.isFinite else { return nil }
        let newScale = min(
            max(metersPerPoint / factor, Self.minimumMetersPerPoint),
            Self.maximumMetersPerPoint
        )
        let ratio = newScale / metersPerPoint
        return MetricCanvasViewport(
            centerXMeters: anchor.xMeters + (centerXMeters - anchor.xMeters) * ratio,
            centerYMeters: anchor.yMeters + (centerYMeters - anchor.yMeters) * ratio,
            metersPerPoint: newScale
        )
    }
}
