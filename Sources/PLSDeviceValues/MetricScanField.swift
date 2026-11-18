import Foundation
import SickPLSCore

/// Ein physischer Punkt in der Scanebene. Der Scanner steht im Ursprung,
/// `x` wächst nach rechts und `y` nach vorn. Die Einheit ist Meter.
public struct MetricScanPoint: Equatable, Sendable {
    public let xMeters: Double
    public let yMeters: Double

    public init(xMeters: Double, yMeters: Double) {
        self.xMeters = xMeters
        self.yMeters = yMeters
    }
}

/// Expliziter Winkelvertrag eines Profils. Die reale Orientierung kann beim
/// Hardwaretest gespiegelt oder enger gewählt werden, ohne die metrische
/// Domäne oder Rasterflächen umzudeuten.
public struct ScanAngularSpan: Equatable, Sendable {
    public enum BuildError: Error, Equatable, Sendable {
        case nonFiniteStart(Double)
        case nonFiniteEnd(Double)
        case emptySpan(Double)
    }

    public let startDegrees: Double
    public let endDegrees: Double

    private init(startDegrees: Double, endDegrees: Double) {
        self.startDegrees = startDegrees
        self.endDegrees = endDegrees
    }

    public static func build(startDegrees: Double, endDegrees: Double) throws -> ScanAngularSpan {
        guard startDegrees.isFinite else { throw BuildError.nonFiniteStart(startDegrees) }
        guard endDegrees.isFinite else { throw BuildError.nonFiniteEnd(endDegrees) }
        guard startDegrees != endDegrees else { throw BuildError.emptySpan(startDegrees) }
        return ScanAngularSpan(startDegrees: startDegrees, endDegrees: endDegrees)
    }

    /// Produktkonvention für den vollen 180°-Fächer: links nach rechts,
    /// Blickrichtung des Scanners ist `0°`. Die reale Richtung wird in
    /// SICK-034 mit einem asymmetrischen Referenzkörper verifiziert.
    public static let forwardSemicircle = try! ScanAngularSpan.build(
        startDegrees: -90,
        endDegrees: 90
    )

    public func bearingDegrees(at fraction: Double) -> Double {
        startDegrees + (endDegrees - startDegrees) * fraction
    }
}

/// Ein metrisch projizierter, weiterhin vollständig auf seine Drahtquelle
/// zurückführbarer Messpunkt.
public struct ProjectedScanMeasurement: Equatable, Sendable {
    public let order: Int
    public let normalizedIndex: Double
    public let distanceCentimeters: UInt16
    public let fieldFlags: UInt8
    public let point: MetricScanPoint

    /// Erzeugt eine bereits projizierte Messung. Die Detection-Pipeline nutzt
    /// diesen Produktkonstruktor, um geglättete Rohwerte mit derselben
    /// Geometrie weiterzureichen.
    public init(
        order: Int, normalizedIndex: Double, distanceCentimeters: UInt16,
        fieldFlags: UInt8, point: MetricScanPoint
    ) {
        self.order = order
        self.normalizedIndex = normalizedIndex
        self.distanceCentimeters = distanceCentimeters
        self.fieldFlags = fieldFlags
        self.point = point
    }
}

/// Reine Polar→Kartesisch-Abbildung. Sie verändert weder Messwerte noch
/// Statusbits und kennt keinen Viewport.
public struct MetricScanProjection: Equatable, Sendable {
    public let angularSpan: ScanAngularSpan

    public init(angularSpan: ScanAngularSpan = .forwardSemicircle) {
        self.angularSpan = angularSpan
    }

    /// Projiziert alle **brauchbaren** Messungen des Profils. Messungen,
    /// die keine gemessene Fläche bezeichnen (`UsableRawDistance`),
    /// erzeugen keinen Punkt (E1). Die Winkellage jeder verbleibenden
    /// Messung wird aus ihrem **ursprünglichen** Index und der
    /// **ursprünglichen** Punktzahl berechnet (E2).
    public func project(_ profile: B0ScanProfile) -> [ProjectedScanMeasurement] {
        let count = profile.measurements.count
        var result: [ProjectedScanMeasurement] = []
        result.reserveCapacity(count)
        for (order, measurement) in profile.measurements.enumerated() {
            guard UsableRawDistance.contains(measurement.value) else { continue }
            let fraction = count > 1 ? Double(order) / Double(count - 1) : 0.5
            let bearing = angularSpan.bearingDegrees(at: fraction) * .pi / 180
            let distance = measurement.distanceMeters
            result.append(ProjectedScanMeasurement(
                order: order,
                normalizedIndex: fraction,
                distanceCentimeters: measurement.distanceCentimeters,
                fieldFlags: measurement.fieldFlags,
                point: MetricScanPoint(
                    xMeters: sin(bearing) * distance,
                    yMeters: cos(bearing) * distance
                )
            ))
        }
        return result
    }

    /// Projiziert das Profil und gruppiert die gültigen Messpunkte in
    /// zusammenhängende Abschnitte. Zwei Punkte gehören zusammen, wenn
    /// ihre ursprünglichen Indizes aufeinanderfolgen. Mindestens ein
    /// unbrauchbarer Messpunkt dazwischen trennt die Abschnitte (E3).
    /// Ein Abschnitt mit genau einem Punkt ist ein isolierter Messpunkt
    /// (E5).
    public func projectSegments(_ profile: B0ScanProfile) -> [ProjectedScanSegment] {
        let projected = project(profile)
        guard !projected.isEmpty else { return [] }

        var segments: [ProjectedScanSegment] = []
        var current: [ProjectedScanMeasurement] = [projected[0]]

        for i in 1..<projected.count {
            if projected[i].order == projected[i - 1].order + 1 {
                current.append(projected[i])
            } else {
                segments.append(ProjectedScanSegment(points: current))
                current = [projected[i]]
            }
        }
        segments.append(ProjectedScanSegment(points: current))
        return segments
    }
}

/// Ein zusammenhängender Abschnitt gültiger Messpunkte in der
/// Empfangsreihenfolge. Ein Abschnitt mit genau einem Punkt ist ein
/// isolierter Messpunkt, der als Punkt statt als Linie dargestellt
/// wird (E5).
public struct ProjectedScanSegment: Equatable, Sendable {
    public let points: [ProjectedScanMeasurement]

    /// `true`, wenn der Abschnitt genau einen Messpunkt enthält.
    public var isIsolated: Bool { points.count == 1 }
}

/// Ganzzahlige Adresse einer quadratischen Rasterzelle. Negative Spalten
/// liegen links, negative Zeilen hinter dem Scannerursprung.
public struct MetricGridCell: Codable, Hashable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

public struct MetricGridCellBounds: Equatable, Sendable {
    public init(minXMeters: Double, maxXMeters: Double, minYMeters: Double, maxYMeters: Double) {
        self.minXMeters = minXMeters; self.minYMeters = minYMeters
        self.maxXMeters = maxXMeters; self.maxYMeters = maxYMeters
    }
    public let minXMeters: Double
    public let maxXMeters: Double
    public let minYMeters: Double
    public let maxYMeters: Double
}

/// Ein unendliches, am Scannerursprung ausgerichtetes Quadratraster.
public struct MetricSquareGrid: Codable, Equatable, Sendable {
    public enum CellSize: String, CaseIterable, Codable, Equatable, Sendable {
        case oneCentimeter
        case twoCentimeter
        case threeCentimeter
        case fourCentimeter
        case fiveCentimeter
        case tenCentimeter
        case twentyFiveCentimeter
        case fiftyCentimeter

        public var meters: Double {
            switch self {
            case .oneCentimeter: return 0.01
            case .twoCentimeter: return 0.02
            case .threeCentimeter: return 0.03
            case .fourCentimeter: return 0.04
            case .fiveCentimeter: return 0.05
            case .tenCentimeter: return 0.10
            case .twentyFiveCentimeter: return 0.25
            case .fiftyCentimeter: return 0.50
            }
        }

        public var displayName: String {
            switch self {
            case .oneCentimeter: return "1 cm"
            case .twoCentimeter: return "2 cm"
            case .threeCentimeter: return "3 cm"
            case .fourCentimeter: return "4 cm"
            case .fiveCentimeter: return "5 cm"
            case .tenCentimeter: return "10 cm"
            case .twentyFiveCentimeter: return "25 cm"
            case .fiftyCentimeter: return "50 cm"
            }
        }

        public var grid: MetricSquareGrid {
            try! MetricSquareGrid.build(cellSizeMeters: meters)
        }
    }

    public enum BuildError: Error, Equatable, Sendable {
        case cellSizeNotPositive(Double)
    }

    public let cellSizeMeters: Double

    private init(cellSizeMeters: Double) {
        self.cellSizeMeters = cellSizeMeters
    }

    private enum CodingKeys: String, CodingKey { case cellSizeMeters }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let size = try values.decode(Double.self, forKey: .cellSizeMeters)
        do {
            self = try Self.build(cellSizeMeters: size)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .cellSizeMeters, in: values,
                debugDescription: "Die Rasterweite muss endlich und groesser als null sein."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(cellSizeMeters, forKey: .cellSizeMeters)
    }

    public static func build(cellSizeMeters: Double) throws -> MetricSquareGrid {
        guard cellSizeMeters.isFinite, cellSizeMeters > 0 else {
            throw BuildError.cellSizeNotPositive(cellSizeMeters)
        }
        return MetricSquareGrid(cellSizeMeters: cellSizeMeters)
    }

    public static let halfMeter = try! MetricSquareGrid.build(cellSizeMeters: 0.5)
    public static let quarterMeter = try! MetricSquareGrid.build(cellSizeMeters: 0.25)
    public static let oneCentimeter = try! MetricSquareGrid.build(cellSizeMeters: 0.01)
    public static let twoCentimeter = try! MetricSquareGrid.build(cellSizeMeters: 0.02)
    public static let threeCentimeter = try! MetricSquareGrid.build(cellSizeMeters: 0.03)
    public static let fourCentimeter = try! MetricSquareGrid.build(cellSizeMeters: 0.04)
    public static let fiveCentimeter = try! MetricSquareGrid.build(cellSizeMeters: 0.05)
    public static let tenCentimeter = try! MetricSquareGrid.build(cellSizeMeters: 0.10)

    public var cellSizeOption: CellSize? {
        CellSize.allCases.first { abs($0.meters - cellSizeMeters) < 0.000_000_1 }
    }

    public func cell(containing point: MetricScanPoint) -> MetricGridCell? {
        guard point.xMeters.isFinite, point.yMeters.isFinite else { return nil }
        return MetricGridCell(
            column: Int(floor(point.xMeters / cellSizeMeters)),
            row: Int(floor(point.yMeters / cellSizeMeters))
        )
    }

    public func bounds(of cell: MetricGridCell) -> MetricGridCellBounds {
        let minX = Double(cell.column) * cellSizeMeters
        let minY = Double(cell.row) * cellSizeMeters
        return MetricGridCellBounds(
            minXMeters: minX,
            maxXMeters: minX + cellSizeMeters,
            minYMeters: minY,
            maxYMeters: minY + cellSizeMeters
        )
    }
}

public enum MetricGridPaintMode: Equatable, Sendable {
    case paint
    case erase
}
