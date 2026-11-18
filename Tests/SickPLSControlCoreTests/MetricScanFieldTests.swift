import XCTest
import SickPLSCore
@testable import SickPLSControlCore

final class MetricScanFieldTests: XCTestCase {
    private func profile(_ values: [UInt16], flags: [UInt8]? = nil) throws -> B0ScanProfile {
        let measurements = try values.enumerated().map { index, value in
            try B0ScanProfile.Measurement.build(value: value, fieldFlags: flags?[index] ?? 0)
        }
        return try B0ScanProfile.build(partialScanIndex: 0, measurements: measurements)
    }

    func testForwardSemicircleProjectsCentimetersIntoCartesianMeters() throws {
        let result = MetricScanProjection().project(try profile([100, 100, 100], flags: [1, 2, 3]))

        XCTAssertEqual(result.map(\.distanceCentimeters), [100, 100, 100])
        XCTAssertEqual(result.map(\.fieldFlags), [1, 2, 3])
        XCTAssertEqual(result[0].point.xMeters, -1, accuracy: 1e-12)
        XCTAssertEqual(result[0].point.yMeters, 0, accuracy: 1e-12)
        XCTAssertEqual(result[1].point.xMeters, 0, accuracy: 1e-12)
        XCTAssertEqual(result[1].point.yMeters, 1, accuracy: 1e-12)
        XCTAssertEqual(result[2].point.xMeters, 1, accuracy: 1e-12)
        XCTAssertEqual(result[2].point.yMeters, 0, accuracy: 1e-12)
    }

    func testSinglePointUsesTheMiddleOfTheConfiguredSpan() throws {
        let span = try ScanAngularSpan.build(startDegrees: 10, endDegrees: 30)
        let result = MetricScanProjection(angularSpan: span).project(try profile([200]))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].normalizedIndex, 0.5)
        XCTAssertEqual(result[0].point.xMeters, sin(20 * .pi / 180) * 2, accuracy: 1e-12)
        XCTAssertEqual(result[0].point.yMeters, cos(20 * .pi / 180) * 2, accuracy: 1e-12)
    }

    func testAngularSpanRejectsNonFiniteAndEmptyValues() {
        XCTAssertThrowsError(try ScanAngularSpan.build(startDegrees: .nan, endDegrees: 90))
        XCTAssertThrowsError(try ScanAngularSpan.build(startDegrees: -90, endDegrees: .infinity))
        XCTAssertThrowsError(try ScanAngularSpan.build(startDegrees: 12, endDegrees: 12))
    }

    func testGridUsesFloorAtBothSidesOfTheOrigin() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.5)

        XCTAssertEqual(grid.cell(containing: .init(xMeters: 0, yMeters: 0)), .init(column: 0, row: 0))
        XCTAssertEqual(grid.cell(containing: .init(xMeters: 0.499, yMeters: 0.999)), .init(column: 0, row: 1))
        XCTAssertEqual(grid.cell(containing: .init(xMeters: -0.001, yMeters: -0.501)), .init(column: -1, row: -2))
        XCTAssertNil(grid.cell(containing: .init(xMeters: .nan, yMeters: 0)))

        XCTAssertEqual(
            grid.bounds(of: .init(column: -1, row: 2)),
            MetricGridCellBounds(minXMeters: -0.5, maxXMeters: 0, minYMeters: 1, maxYMeters: 1.5)
        )
    }

    func testGridRejectsInvalidCellSizes() {
        for value in [0.0, -0.1, .infinity, .nan] {
            XCTAssertThrowsError(try MetricSquareGrid.build(cellSizeMeters: value))
        }
    }

    // MARK: - P-1c: Phantomtreffer und Segmente

    /// E1: Rohwerte 0 und 8191 erzeugen keinen Punkt im räumlichen Pfad.
    func testProjectionFiltersUnusableRawValues() throws {
        // 0 = "kein Echo", 8191 = "Bereichsende" — beide unbrauchbar.
        let result = MetricScanProjection().project(try profile([0, 100, 8191]))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].distanceCentimeters, 100)
        XCTAssertEqual(result[0].order, 1)
    }

    /// E1: Ein Profil, das ausschließlich unbrauchbare Werte trägt,
    /// liefert keine Punkte.
    func testProjectionAllUnusableYieldsEmpty() throws {
        let result = MetricScanProjection().project(try profile([0, 8191, 0]))

        XCTAssertTrue(result.isEmpty)
    }

    /// E2: Die Winkellage der verbleibenden Messung wird aus dem
    /// ursprünglichen Index und der ursprünglichen Punktzahl berechnet,
    /// nicht aus der Position in der gefilterten Liste.
    func testProjectionPreservesOriginalIndexForBearing() throws {
        // Drei Messungen; die mittlere (Index 1) ist unbrauchbar.
        // Die verbleibenden (Index 0 und 2) behalten ihre Peilung
        // basierend auf der Gesamtpunktzahl 3.
        let result = MetricScanProjection().project(try profile([100, 0, 200]))

        XCTAssertEqual(result.count, 2)
        // Index 0 von 3 → fraction 0/2 = 0 → bearing −90°
        XCTAssertEqual(result[0].normalizedIndex, Zone.indexFraction(forIndex: 0, count: 3))
        // Index 2 von 3 → fraction 2/2 = 1 → bearing +90°
        XCTAssertEqual(result[1].normalizedIndex, Zone.indexFraction(forIndex: 2, count: 3))
        // Die Peilung ist NICHT 0.5 (das wäre der Fall, wenn Index 2
        // in einer 2-Punkt-Liste als letzter gezählt würde).
        XCTAssertNotEqual(result[1].normalizedIndex, 0.5)
    }

    /// E3 + E4: Segmente brechen an Lücken. Ein Profil mit gültigen
    /// Punkten an Index 0, 1, 3, 4 (Index 2 unbrauchbar) ergibt zwei
    /// Segmente: {0,1} und {3,4}.
    func testSegmentsBreakAtGap() throws {
        let segments = MetricScanProjection().projectSegments(try profile([100, 200, 0, 300, 400]))

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].points.map(\.order), [0, 1])
        XCTAssertEqual(segments[1].points.map(\.order), [3, 4])
        XCTAssertFalse(segments[0].isIsolated)
        XCTAssertFalse(segments[1].isIsolated)
    }

    /// E5: Ein einzelner gültiger Punkt zwischen zwei Lücken bildet ein
    /// isoliertes Segment und bleibt sichtbar.
    func testIsolatedPointBetweenGaps() throws {
        // Index 0 und 2 unbrauchbar, Index 1 gültig → isolierter Punkt.
        let segments = MetricScanProjection().projectSegments(try profile([0, 150, 8191]))

        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].isIsolated)
        XCTAssertEqual(segments[0].points.count, 1)
        XCTAssertEqual(segments[0].points[0].order, 1)
        XCTAssertEqual(segments[0].points[0].distanceCentimeters, 150)
    }

    /// E5: Mehrere isolierte Punkte zwischen Lücken bleiben jeweils
    /// sichtbar als eigene Segmente.
    func testMultipleIsolatedPoints() throws {
        // Nur Index 1 und 3 gültig, dazwischen Index 2 unbrauchbar.
        let segments = MetricScanProjection().projectSegments(try profile([0, 100, 0, 200, 0]))

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[0].isIsolated)
        XCTAssertTrue(segments[1].isIsolated)
        XCTAssertEqual(segments[0].points[0].order, 1)
        XCTAssertEqual(segments[1].points[0].order, 3)
    }

    /// E4-Gegenprobe: Wenn die Segmentierung Lücken überbrücken würde
    /// (d. h. alle gültigen Punkte in ein einziges Segment legen),
    /// müsste dieser Test rot werden.
    func testSegmentsDoNotBridgeGaps() throws {
        // Fünf Punkte, Index 2 unbrauchbar. Richtig: zwei Segmente.
        // Falsch (überbrückt): ein einziges Segment mit vier Punkten.
        let segments = MetricScanProjection().projectSegments(try profile([100, 200, 0, 300, 400]))

        // Die falsche Variante (ein Segment, vier Punkte) bricht hier:
        XCTAssertEqual(segments.count, 2, "Lücken müssen Segmente trennen, nicht überbrücken.")
        // Und die falsche Variante (ein Segment) bricht auch hier:
        XCTAssertNotEqual(segments.first?.points.count, 4, "Kein Segment darf über eine Lücke hinweg Punkte verbinden.")
    }

}
