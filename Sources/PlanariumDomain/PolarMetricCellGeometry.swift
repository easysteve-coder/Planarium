import Foundation
import PLSDeviceValues

/// Wahl der bearbeiteten Rastertopologie. Ein Wechsel wandelt die gespeicherte
/// Maske in echte Zellen der Zieltopologie um; es ist kein Darstellungsfilter.
public enum MetricViewportCoordinateMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case cartesian
    case polar

    public var label: String {
        switch self {
        case .cartesian: return "Kartesisch"
        case .polar: return "Polar"
        }
    }
}

/// Eindeutige Adresse einer Zelle im adaptiven Polarraster. Anders als die
/// frühere Projektion kartesischer Zellmittelpunkte hat jede sichtbare Zelle
/// genau eine Adresse und kann deshalb unabhängig bemalt werden.
public struct PolarMetricGridCell: Codable, Equatable, Hashable, Sendable {
    public let ring: Int
    public let angularIndex: Int

    public init(ring: Int, angularIndex: Int) {
        self.ring = max(0, ring)
        self.angularIndex = angularIndex
    }

    public init(point: MetricScanPoint, grid: MetricSquareGrid) {
        let radius = hypot(point.xMeters, point.yMeters)
        ring = max(0, Int(floor(radius / grid.cellSizeMeters)))
        let outerRadius = Double(ring + 1) * grid.cellSizeMeters
        let step = PolarMetricCellSegment.angularStepDegrees(
            outerRadiusMeters: outerRadius,
            radialHeightMeters: grid.cellSizeMeters
        )
        let bearing = atan2(point.xMeters, point.yMeters) * 180 / .pi
        angularIndex = Int(floor((bearing + 180) / step))
    }

    /// Stabile Hilfsadresse für bestehende musikalische Wertefunktionen.
    public var valueCell: MetricGridCell {
        MetricGridCell(column: angularIndex, row: ring)
    }
}

/// Polare Darstellung genau einer metrischen Rasterzelle als Zelle des
/// sichtbaren Ringsektorrasters. Das kartesische Zellzentrum bestimmt Ring
/// und Winkelzelle; die Grenzen rasten anschließend exakt auf denselben
/// Bögen und radialen Linien ein, die der Viewport zeichnet.
public struct PolarMetricCellSegment: Codable, Equatable, Sendable {
    public let innerRadiusMeters: Double
    public let outerRadiusMeters: Double
    public let startBearingDegrees: Double
    public let endBearingDegrees: Double

    public init(
        innerRadiusMeters: Double,
        outerRadiusMeters: Double,
        startBearingDegrees: Double,
        endBearingDegrees: Double
    ) {
        self.innerRadiusMeters = innerRadiusMeters
        self.outerRadiusMeters = outerRadiusMeters
        self.startBearingDegrees = startBearingDegrees
        self.endBearingDegrees = endBearingDegrees
    }

    public init(cell: MetricGridCell, grid: MetricSquareGrid) {
        let bounds = grid.bounds(of: cell)
        let centerX = (bounds.minXMeters + bounds.maxXMeters) / 2
        let centerY = (bounds.minYMeters + bounds.maxYMeters) / 2
        self.init(
            point: MetricScanPoint(xMeters: centerX, yMeters: centerY),
            grid: grid
        )
    }

    /// Liefert exakt die sichtbare Ringzelle unter einem metrischen Punkt.
    /// Damit verwenden Hintergrund, Darstellung und Pointer-Hit-Test
    /// dieselben Grenzen.
    public init(point: MetricScanPoint, grid: MetricSquareGrid) {
        self.init(cell: PolarMetricGridCell(point: point, grid: grid), grid: grid)
    }

    public init(cell: PolarMetricGridCell, grid: MetricSquareGrid) {
        let radialStep = grid.cellSizeMeters
        innerRadiusMeters = Double(cell.ring) * radialStep
        outerRadiusMeters = Double(cell.ring + 1) * radialStep
        let angularStep = Self.angularStepDegrees(
            outerRadiusMeters: outerRadiusMeters,
            radialHeightMeters: radialStep
        )
        startBearingDegrees = Double(cell.angularIndex) * angularStep - 180
        endBearingDegrees = startBearingDegrees + angularStep
    }

    /// Das sichtbare Polarraster beginnt mit 90°-Zellen und halbiert diese
    /// ringweise so oft, dass die äußere Bogenbreite höchstens das 1,5-Fache
    /// der radialen Höhe beträgt.
    public static func angularStepDegrees(
        outerRadiusMeters: Double,
        radialHeightMeters: Double,
        baseAngularStepDegrees: Double = 90,
        maximumWidthToRadialHeightRatio: Double = 1.5
    ) -> Double {
        guard outerRadiusMeters > 0, radialHeightMeters > 0,
              baseAngularStepDegrees > 0, maximumWidthToRadialHeightRatio > 0 else {
            return baseAngularStepDegrees
        }
        var angularStep = baseAngularStepDegrees
        while outerRadiusMeters * angularStep * .pi / 180
                > maximumWidthToRadialHeightRatio * radialHeightMeters {
            angularStep /= 2
        }
        return angularStep
    }

    public func point(radiusMeters: Double, bearingDegrees: Double) -> MetricScanPoint {
        let radians = bearingDegrees * .pi / 180
        return MetricScanPoint(
            xMeters: sin(radians) * radiusMeters,
            yMeters: cos(radians) * radiusMeters
        )
    }

    /// Breite der Zelle an ihrem äußeren Kreisbogen. Dort ist ein Ringsektor
    /// am breitesten und muss deshalb die 1,5:1-Regel erfüllen.
    public var outerArcWidthMeters: Double {
        outerRadiusMeters * abs(endBearingDegrees - startBearingDegrees) * .pi / 180
    }

    public var radialHeightMeters: Double {
        max(0, outerRadiusMeters - innerRadiusMeters)
    }

    /// The geometrical centre used by editor operations.  Keeping it here
    /// means that hit testing, painting and cell moves use one polar model.
    public var midpoint: (radiusMeters: Double, bearingDegrees: Double) {
        ((innerRadiusMeters + outerRadiusMeters) / 2,
         (startBearingDegrees + endBearingDegrees) / 2)
    }

    /// Teilt einen zu breiten Ringsektor ausschließlich in Winkelrichtung.
    /// Radius, Gesamtwinkel und Fläche bleiben erhalten.
    public func subdivided(
        maximumWidthToRadialHeightRatio maximumRatio: Double = 1.5
    ) -> [PolarMetricCellSegment] {
        guard radialHeightMeters > 0, maximumRatio > 0 else { return [self] }
        let count = max(1, Int(ceil(
            outerArcWidthMeters / (radialHeightMeters * maximumRatio)
        )))
        guard count > 1 else { return [self] }

        let angularStep = (endBearingDegrees - startBearingDegrees) / Double(count)
        return (0..<count).map { index in
            let start = startBearingDegrees + Double(index) * angularStep
            return PolarMetricCellSegment(
                innerRadiusMeters: innerRadiusMeters,
                outerRadiusMeters: outerRadiusMeters,
                startBearingDegrees: start,
                endBearingDegrees: start + angularStep
            )
        }
    }
}
