import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class LegacyCartesianAddressTests: XCTestCase {

    func testFrozenMidpointFixture() throws {
        let address = try LegacyCartesianAddress.polarCell(
            atCenterOf: MetricGridCell(column: 0, row: 2),
            in: .halfMeter
        )
        XCTAssertEqual(address, PolarMetricGridCell(ring: 2, angularIndex: 8))
    }

    func testExhaustiveHalfCircleAgreesWithLegacyFloatingPointAddress() throws {
        let (count, differences, rejections) = try compareAllCells(grid: .halfMeter)
        XCTAssertEqual(count, 42_144)
        XCTAssertEqual(differences, 0)
        XCTAssertEqual(rejections, 0)
    }

    func testBothExactDiagonalFamiliesChooseTheLargerIndex() throws {
        var positive = 0
        var negative = 0
        for column in -164...163 {
            let positiveCell = MetricGridCell(column: column, row: column)
            if positiveCell.row >= 0,
               isInUsableRange(positiveCell, grid: .halfMeter) {
                let actual = try LegacyCartesianAddress.polarCell(
                    atCenterOf: positiveCell, in: .halfMeter
                )
                let old = oldAddress(positiveCell, grid: .halfMeter)
                XCTAssertEqual(actual, old)
                positive += 1
            }

            let negativeRow = -column - 1
            if negativeRow >= 0 {
                let negativeCell = MetricGridCell(column: column, row: negativeRow)
                guard isInUsableRange(negativeCell, grid: .halfMeter) else { continue }
                let actual = try LegacyCartesianAddress.polarCell(
                    atCenterOf: negativeCell, in: .halfMeter
                )
                let old = oldAddress(negativeCell, grid: .halfMeter)
                XCTAssertEqual(actual, old)
                negative += 1
            }
        }
        XCTAssertEqual(positive, 116)
        XCTAssertEqual(negative, 116)
    }

    func testExactRingAgreesForEveryUsableHalfCircleCell() throws {
        var count = 0
        let extent = Int(floor(81.90 / MetricSquareGrid.halfMeter.cellSizeMeters - 0.5))
        for column in (-extent - 1)...extent {
            for row in 0...extent {
                let cell = MetricGridCell(column: column, row: row)
                guard isInUsableRange(cell, grid: .halfMeter) else { continue }
                let address = try LegacyCartesianAddress.polarCell(
                    atCenterOf: cell, in: .halfMeter
                )
                let x = 2 * column + 1
                let y = 2 * row + 1
                var expected = 0
                while 4 * (expected + 1) * (expected + 1) <= x * x + y * y {
                    expected += 1
                }
                XCTAssertEqual(address.ring, expected)
                count += 1
            }
        }
        XCTAssertEqual(count, 42_144)
    }

    func testAdditionalRasterWidthsAreExhaustive() throws {
        // 5 cm is measured over the explicitly named 2 m front-half band;
        // its full 81.90 m half-circle is several million cells.
        for (size, radius) in [(0.05, 2.0), (0.25, 81.90), (1.0, 81.90)] {
            let grid = try MetricSquareGrid.build(cellSizeMeters: size)
            let result = try compareAllCells(grid: grid, radiusMeters: radius)
            XCTAssertGreaterThan(result.count, 0, "size \(size)")
            XCTAssertEqual(result.differences, 0, "size \(size)")
            XCTAssertEqual(result.rejections, 0, "size \(size)")
        }
    }

    func testUnclassifiableGapIsRejectedRatherThanGuessed() throws {
        let cell = MetricGridCell(column: 1, row: 2)
        XCTAssertThrowsError(try LegacyCartesianAddress.address(
            of: cell, in: .halfMeter, bounds: .forcedGap
        )) { error in
            guard let error = error as? LegacyCartesianAddress.AddressError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(error, .unclassifiableAngle(column: 1, row: 2))
        }
    }

    func testNegativeRowsAndNonIntegerGridAreRejected() throws {
        XCTAssertThrowsError(try LegacyCartesianAddress.polarCell(
            atCenterOf: MetricGridCell(column: 0, row: -1), in: .halfMeter
        )) { error in
            guard let error = error as? LegacyCartesianAddress.AddressError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(error, .rowNotInFrontHalfPlane(column: 0, row: -1))
        }

        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.025)
        XCTAssertThrowsError(try LegacyCartesianAddress.polarCell(
            atCenterOf: MetricGridCell(column: 0, row: 2), in: grid
        )) { error in
            guard let error = error as? LegacyCartesianAddress.AddressError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(error, .nonIntegerCentimeterGrid(0.025))
        }
    }

    private typealias Comparison = (count: Int, differences: Int, rejections: Int)

    private func compareAllCells(
        grid: MetricSquareGrid,
        radiusMeters: Double = 81.90
    ) throws -> Comparison {
        var count = 0
        var differences = 0
        var rejections = 0
        let extent = Int(floor(radiusMeters / grid.cellSizeMeters - 0.5))
        for column in (-extent - 1)...extent {
            for row in 0...extent {
                let cell = MetricGridCell(column: column, row: row)
                guard isInUsableRange(cell, grid: grid, radiusMeters: radiusMeters) else { continue }
                count += 1
                do {
                    let actual = try LegacyCartesianAddress.polarCell(
                        atCenterOf: cell, in: grid
                    )
                    if actual != oldAddress(cell, grid: grid) {
                        differences += 1
                    }
                } catch {
                    rejections += 1
                }
            }
        }
        return (count, differences, rejections)
    }

    private func oldAddress(_ cell: MetricGridCell, grid: MetricSquareGrid) -> PolarMetricGridCell {
        let bounds = grid.bounds(of: cell)
        return PolarMetricGridCell(
            point: MetricScanPoint(
                xMeters: (bounds.minXMeters + bounds.maxXMeters) / 2,
                yMeters: (bounds.minYMeters + bounds.maxYMeters) / 2
            ),
            grid: grid
        )
    }

    private func isInUsableRange(
        _ cell: MetricGridCell,
        grid: MetricSquareGrid,
        radiusMeters: Double = 81.90
    ) -> Bool {
        guard let sizeCentimeters = try? LegacyLatticeMigration.centimeterGrid(grid) else {
            return false
        }
        let x = 2 * cell.column + 1
        let y = 2 * cell.row + 1
        let limitCentimeters = Int(radiusMeters * 100)
        return (x * x + y * y) * sizeCentimeters * sizeCentimeters
            <= (2 * limitCentimeters) * (2 * limitCentimeters)
    }


    // MARK: - Feines Raster: benannte Ablehnung statt stiller Fehladresse

    /// Der **alte** Polarring ist `floor(radius / cellSize)` und **nicht** der
    /// Gitterring. Bei 1-cm-Raster reicht er bis 8190, nicht bis 1638.
    ///
    /// Die erste Fassung suchte den Ring binär mit der Obergrenze 1638 und
    /// klemmte solche Zellen still dorthin: für `(0, 2000)` bei 1 cm lieferte
    /// der Altweg `(2000, 8192)`, die ganzzahlige Regel `(1638, 4096)` — auf
    /// **beiden** Achsen falsch, ohne jeden Hinweis. Das ist genau der Fall,
    /// den die Ablehnung verhindern soll.
    func testFineGridIsRejectedByNameInsteadOfSilentlyClamped() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.01)
        let cell = MetricGridCell(column: 0, row: 2000)

        // Die Zelle ist gültig: ihr Mittelpunkt liegt bei 20,005 m, weit
        // innerhalb der 81,90 m. Sie darf nicht wegen Reichweite scheitern.
        let bounds = grid.bounds(of: cell)
        let center = MetricScanPoint(
            xMeters: (bounds.minXMeters + bounds.maxXMeters) / 2,
            yMeters: (bounds.minYMeters + bounds.maxYMeters) / 2
        )
        XCTAssertEqual(PolarMetricGridCell(point: center, grid: grid).ring, 2000)

        XCTAssertThrowsError(
            try LegacyCartesianAddress.polarCell(atCenterOf: cell, in: grid)
        ) { error in
            guard case .angularTableDoesNotCover(let exponent, _, _)? =
                    error as? LegacyCartesianAddress.AddressError else {
                return XCTFail("Erwartet angularTableDoesNotCover, erhalten \(error)")
            }
            XCTAssertEqual(exponent, 12, "Die Tabelle reicht bis k = 11")
        }
    }

    /// Die Deckungsgrenze ist genau 5 cm: `ring = floor(8190 / cellSizeCm)`,
    /// und `k ≤ 11` gilt bis Ring 1638. Bei 5 cm ist der äußerste Ring genau
    /// 1638 und damit noch gedeckt; bei 4 cm sind es 2047 und k wird 12.
    func testFiveCentimetreGridIsStillCoveredAtMaximumRange() throws {
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.05)
        // Mittelpunkt bei 81,875 m — der äußerste noch brauchbare Ring.
        let cell = MetricGridCell(column: 0, row: 1637)

        let address = try LegacyCartesianAddress.polarCell(atCenterOf: cell, in: grid)
        XCTAssertEqual(address.ring, 1637)

        let bounds = grid.bounds(of: cell)
        let center = MetricScanPoint(
            xMeters: (bounds.minXMeters + bounds.maxXMeters) / 2,
            yMeters: (bounds.minYMeters + bounds.maxYMeters) / 2
        )
        XCTAssertEqual(address, PolarMetricGridCell(point: center, grid: grid),
                       "Bei 5 cm muss die ganzzahlige Regel den Altweg noch treffen")
    }
}
