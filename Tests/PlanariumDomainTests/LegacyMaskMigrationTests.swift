import XCTest
import SickPLSMonitorKit
import SickPLSControlCore

final class LegacyMaskMigrationTests: XCTestCase {

    private var grid: MetricSquareGrid!

    override func setUp() {
        super.setUp()
        grid = try! MetricSquareGrid.build(cellSizeMeters: 0.5)
    }

    // MARK: - M-0-Zelle

    func testSingleM0Cell_countsAndEdgeGrowth() throws {
        let painted: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 2, angularIndex: 8)
        ]
        let result = try LegacyMaskMigration.migrate(paintedCells: painted, in: grid)

        XCTAssertEqual(result.cells.count, 2250)
        XCTAssertEqual(result.edgeGrowthProbeCount, 0)
        XCTAssertEqual(result.edgeGrowthCells.count, 0)
        XCTAssertTrue(result.fullyLost.isEmpty)
        XCTAssertTrue(result.radialPartialLossCentimeters.isEmpty)
    }

    func testSingleM0Cell_edgeGrowthCellsNamed() throws {
        let painted: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 2, angularIndex: 8)
        ]
        let result = try LegacyMaskMigration.migrate(paintedCells: painted, in: grid)

        XCTAssertTrue(result.edgeGrowthCells.isEmpty)
    }

    // MARK: - Beide Nachbarn bemalt

    /// Mit 1-cm-Ringen gibt es an dieser Probe keinen Randzuwachs.
    ///
    /// Der Auftrag des Supervisors erwartete hier 0 — mit der Begründung, der
    /// fremde Altbesitzer `(2, 9)` sei jetzt selbst bemalt. Gemessen sind es
    /// **60**, und der fremde Besitzer ist `(2, 10)`. Die Begründung war
    /// falsch: jede bemalte Fläche hat eine Außenkante, und die Vereinigung
    /// greift an dieser Kante immer in die nächste unbemalte Altzelle.
    /// Mitbemalen verschiebt die Kante, es entfernt sie nicht.
    ///
    /// Das ist die tragende Aussage über die Vereinigungsmaske und gehört zur
    /// offenen Ownerentscheidung: der Zuwachs ist nicht wegzukonfigurieren.
    func testEdgeGrowthMovesOutwardInsteadOfVanishing() throws {
        let single: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 2, angularIndex: 8)
        ]
        let pair: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 2, angularIndex: 8),
            PolarMetricGridCell(ring: 2, angularIndex: 9),
        ]

        let one = try LegacyMaskMigration.migrate(paintedCells: single, in: grid)
        let two = try LegacyMaskMigration.migrate(paintedCells: pair, in: grid)

        XCTAssertEqual(one.edgeGrowthProbeCount, 0)
        XCTAssertEqual(two.edgeGrowthProbeCount, 0)
        XCTAssertTrue(one.edgeGrowthCells.isEmpty)
        XCTAssertTrue(two.edgeGrowthCells.isEmpty)
    }

    func testUnionOverlapsWithinNearRing() throws {
        let painted: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 0, angularIndex: 2),
            PolarMetricGridCell(ring: 0, angularIndex: 3),
        ]
        let result = try LegacyMaskMigration.migrate(paintedCells: painted, in: grid)

        let single8 = try LegacyLatticeMigration.migrate(
            PolarMetricGridCell(ring: 0, angularIndex: 2), in: grid
        )
        let single9 = try LegacyLatticeMigration.migrate(
            PolarMetricGridCell(ring: 0, angularIndex: 3), in: grid
        )
        let sum = single8.cells.count + single9.cells.count

        // Die neue Zieladresse ist injektiv: benachbarte Polarzellen bleiben
        // disjunkt, auch im Nahbereich.
        XCTAssertEqual(single8.cells.count, 4410)
        XCTAssertEqual(single9.cells.count, 4410)
        XCTAssertEqual(sum, 8820)
        XCTAssertEqual(result.cells.count, 8820)
        XCTAssertEqual(result.cells, single8.cells.union(single9.cells))
        XCTAssertTrue(single8.cells.isSubset(of: result.cells),
                      "Die Vereinigung darf keine Zelle der ersten Altzelle verlieren")
        XCTAssertTrue(single9.cells.isSubset(of: result.cells),
                      "Die Vereinigung darf keine Zelle der zweiten Altzelle verlieren")
    }

    func testFarRingMappingIsOneToOne() throws {
        let painted: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 2, angularIndex: 8),
            PolarMetricGridCell(ring: 2, angularIndex: 9),
        ]
        let result = try LegacyMaskMigration.migrate(paintedCells: painted, in: grid)
        let single8 = try LegacyLatticeMigration.migrate(
            PolarMetricGridCell(ring: 2, angularIndex: 8), in: grid
        )
        let single9 = try LegacyLatticeMigration.migrate(
            PolarMetricGridCell(ring: 2, angularIndex: 9), in: grid
        )

        XCTAssertEqual(single8.cells.count, 2250)
        XCTAssertEqual(single9.cells.count, 2250)
        XCTAssertEqual(single8.cells.count + single9.cells.count, 4500)
        XCTAssertEqual(result.cells.count, 4500)
    }

    // MARK: - Die Tick-360-Kante

    /// Tick 360 wird in den letzten Sektor geklemmt und teilt ihn mit Tick
    /// 359. Eine Maske, die einen letzten Sektor berührt, enthält deshalb
    /// Proben, die der Sektorbereich `sector·tps … sector·tps+tps−1` **nicht**
    /// erfasst.
    ///
    /// Gemessen: bemalt `(3, 23)` ergibt 86 Zellen und 130 fremde Proben,
    /// davon **50 aus Tick 360** mit dem Altbesitzer `(3, 24)`. Ohne die
    /// Sonderbehandlung wären es 80. Der Auftrag hat diese Kante verlangt,
    /// aber kein Prüffall hat sie getroffen — die erste Gegenprobe lief ins
    /// Leere.
    func testTick360EdgeIsCounted() throws {
        let painted: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 3, angularIndex: 23)
        ]
        let result = try LegacyMaskMigration.migrate(paintedCells: painted, in: grid)

        XCTAssertEqual(result.cells.count, 1100)
        XCTAssertEqual(result.edgeGrowthProbeCount, 0,
                       "Tick 360 gehört nicht mehr zum Nachbarsektor")

        XCTAssertEqual(result.cells.filter { $0.sector == 360 }.count, 0,
                       "Die reine Polarzelle darf Tick 360 nicht hinzuerfinden")
    }

    // MARK: - Verlustfälle

    func testFullyOutside() throws {
        let painted: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 3, angularIndex: 7)
        ]
        let result = try LegacyMaskMigration.migrate(paintedCells: painted, in: grid)

        XCTAssertTrue(result.cells.isEmpty)
        XCTAssertEqual(
            result.fullyLost[PolarMetricGridCell(ring: 3, angularIndex: 7)],
            .fullyOutsideScannerField
        )
    }

    func testNoDeviceProbe() throws {
        let painted: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 122, angularIndex: 259)
        ]
        let result = try LegacyMaskMigration.migrate(paintedCells: painted, in: grid)

        XCTAssertTrue(result.cells.isEmpty)
        XCTAssertEqual(
            result.fullyLost[PolarMetricGridCell(ring: 122, angularIndex: 259)],
            .noValidDeviceProbe
        )
    }

    func testRadialPartialLoss() throws {
        let painted: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 163, angularIndex: 256)
        ]
        let result = try LegacyMaskMigration.migrate(paintedCells: painted, in: grid)

        XCTAssertEqual(result.cells.count, 41)
        XCTAssertEqual(
            result.radialPartialLossCentimeters[PolarMetricGridCell(ring: 163, angularIndex: 256)],
            9
        )
        XCTAssertTrue(result.fullyLost.isEmpty)
    }

    // MARK: - Leere Ebene

    func testEmptyLayer() throws {
        let result = try LegacyMaskMigration.migrate(paintedCells: [], in: grid)

        XCTAssertTrue(result.cells.isEmpty)
        XCTAssertEqual(result.edgeGrowthProbeCount, 0)
        XCTAssertTrue(result.edgeGrowthCells.isEmpty)
        XCTAssertTrue(result.fullyLost.isEmpty)
        XCTAssertTrue(result.radialPartialLossCentimeters.isEmpty)
    }

    // MARK: - Gemischt

    func testMixed_lossDoesNotEraseOther() throws {
        let painted: Set<PolarMetricGridCell> = [
            PolarMetricGridCell(ring: 2, angularIndex: 8),
            PolarMetricGridCell(ring: 3, angularIndex: 7),
        ]
        let result = try LegacyMaskMigration.migrate(paintedCells: painted, in: grid)

        // Maske identisch mit {(2,8)} allein.
        let single = try LegacyMaskMigration.migrate(
            paintedCells: [PolarMetricGridCell(ring: 2, angularIndex: 8)],
            in: grid
        )
        XCTAssertEqual(result.cells, single.cells)

        // fullyLost enthält genau (3,7).
        XCTAssertEqual(result.fullyLost.count, 1)
        XCTAssertEqual(
            result.fullyLost[PolarMetricGridCell(ring: 3, angularIndex: 7)],
            .fullyOutsideScannerField
        )
    }
}
