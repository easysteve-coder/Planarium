import XCTest
@testable import PlanariumDomain
import SickPLSControlCore

final class LegacyOverrideMigrationTests: XCTestCase {

    private let grid = MetricSquareGrid.halfMeter

    private let a60 = SpatialCellAction(
        target: .midiNote(channel: 0),
        value: .note(number: 60, velocity: 100)
    )
    private let a67 = SpatialCellAction(
        target: .midiNote(channel: 0),
        value: .note(number: 67, velocity: 100)
    )
    private let a72 = SpatialCellAction(
        target: .midiNote(channel: 0),
        value: .note(number: 72, velocity: 100)
    )

    // MARK: - Helper

    private func makeLayer(
        polarCells: Set<PolarMetricGridCell>,
        polarOverrides: [PolarMetricGridCell: [SpatialCellAction]] = [:],
        cartesianCells: Set<MetricGridCell> = []
    ) -> LegacySpatialLayer {
        LegacySpatialLayer(
            id: UUID(),
            name: "Test",
            color: SpatialLayerColor(red: 1, green: 0, blue: 0),
            isVisible: true,
            isActive: true,
            isLocked: false,
            isSoloed: false,
            cells: cartesianCells,
            polarCells: polarCells,
            routings: [],
            cellOverrides: [:],
            polarCellOverrides: polarOverrides
        )
    }

    // MARK: - M-0: der tragende Fall

    func testM0_singlePaintedCell_withOverride() throws {
        let c8 = PolarMetricGridCell(ring: 0, angularIndex: 2)
        let layer = makeLayer(
            polarCells: [c8],
            polarOverrides: [c8: [a60]]
        )

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertEqual(result.overrides.count, 4410)
        XCTAssertTrue(result.conflicts.isEmpty)
        for (_, actions) in result.overrides {
            XCTAssertEqual(actions, [a60])
        }
        XCTAssertEqual(result.cartesianCellsNotMigrated, 0)

        // **Die Prämisse, ohne die die Zusicherung oben leer wäre.**
        // „Keine Konflikte" ist nur dann eine Aussage, wenn es hier
        // überhaupt Zielzellen mit einem zweiten Altbesitzer gibt. Die
        // Die Maskenmigration weist die 13 Randzellen aus, die der
        // **unbemalten** Nachbarzelle (0, 3) gehören.
        let mask = try LegacyMaskMigration.migrate(paintedCells: [c8], in: grid)
        XCTAssertTrue(mask.edgeGrowthCells.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    // MARK: - Bemalt ohne Override

    func testPaintedWithoutOverride_noOverrideNoConflict() throws {
        let c8 = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let layer = makeLayer(polarCells: [c8])

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertTrue(result.overrides.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.cartesianCellsNotMigrated, 0)
    }

    // MARK: - Identische Aktionen

    func testIdenticalActions_adoptedOnce() throws {
        let c8 = PolarMetricGridCell(ring: 0, angularIndex: 2)
        let c9 = PolarMetricGridCell(ring: 0, angularIndex: 3)
        let layer = makeLayer(
            polarCells: [c8, c9],
            polarOverrides: [c8: [a60], c9: [a60]]
        )

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertEqual(result.overrides.count, 8820)
        XCTAssertTrue(result.conflicts.isEmpty)

        let sharedCells: Set<PolarDeviceLattice> = [
            PolarDeviceLattice(ring: 2, sector: 2)!,
            PolarDeviceLattice(ring: 3, sector: 3)!,
            PolarDeviceLattice(ring: 4, sector: 4)!,
            PolarDeviceLattice(ring: 7, sector: 7)!,
            PolarDeviceLattice(ring: 8, sector: 7)!,
            PolarDeviceLattice(ring: 12, sector: 11)!,
            PolarDeviceLattice(ring: 13, sector: 11)!,
            PolarDeviceLattice(ring: 22, sector: 22)!,
            PolarDeviceLattice(ring: 23, sector: 22)!,
            PolarDeviceLattice(ring: 24, sector: 22)!,
            PolarDeviceLattice(ring: 25, sector: 22)!,
            PolarDeviceLattice(ring: 26, sector: 22)!,
            PolarDeviceLattice(ring: 27, sector: 22)!,
        ]
        for cell in sharedCells {
            XCTAssertEqual(result.overrides[cell], [a60])
        }
    }

    // MARK: - Verschiedene Aktionen

    func testDifferentActions_conflictOnSharedCells() throws {
        let c8 = PolarMetricGridCell(ring: 0, angularIndex: 2)
        let c9 = PolarMetricGridCell(ring: 0, angularIndex: 3)
        let layer = makeLayer(
            polarCells: [c8, c9],
            polarOverrides: [c8: [a60], c9: [a67]]
        )

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.overrides.count, 8820)

        // Keine Zelle steht in beiden.
        for cell in result.overrides.keys {
            XCTAssertNil(result.conflicts[cell])
        }
    }

    func testReorderedActionsAreAConflict() throws {
        let c8 = PolarMetricGridCell(ring: 0, angularIndex: 2)
        let c9 = PolarMetricGridCell(ring: 0, angularIndex: 3)
        let layer = makeLayer(
            polarCells: [c8, c9],
            polarOverrides: [c8: [a60, a67], c9: [a67, a60]]
        )

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.overrides.count, 8820)
    }

    /// Gleich lang und gegenseitig enthalten heißt **nicht** gleich.
    ///
    /// `[a60, a60]` gegen `[a60, a67]`: beide Listen haben zwei Einträge,
    /// und jeder Eintrag der ersten kommt in der zweiten vor. Ein Vergleich,
    /// der nur das prüft, hält sie für identisch und übernimmt stillschweigend
    /// eine der beiden — aus einem echten Konflikt würde ein stiller
    /// Verlust. Der Vergleich muss jedes Element verbrauchen.
    func testDuplicateActionsAreNotIdentical() throws {
        let c8 = PolarMetricGridCell(ring: 0, angularIndex: 2)
        let c9 = PolarMetricGridCell(ring: 0, angularIndex: 3)
        let layer = makeLayer(
            polarCells: [c8, c9],
            polarOverrides: [c8: [a60, a60], c9: [a60, a67]]
        )

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertTrue(result.conflicts.isEmpty,
                      "Reine Polarziele bleiben auch bei doppelten Aktionen disjunkt")
        XCTAssertEqual(result.overrides.count, 8820)
    }

    // MARK: - Override gegen Fallback

    func testOverrideVsFallback_conflictOnSharedCells() throws {
        let c8 = PolarMetricGridCell(ring: 0, angularIndex: 2)
        let c9 = PolarMetricGridCell(ring: 0, angularIndex: 3)
        let layer = makeLayer(
            polarCells: [c8, c9],
            polarOverrides: [c8: [a60]]  // c9 hat keinen Eintrag → Fallback
        )

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.overrides.count, 4410)
    }

    // MARK: - Keine Überschneidung

    func testNoOverlap_noConflict() throws {
        let c8 = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let c10 = PolarMetricGridCell(ring: 2, angularIndex: 10)
        let layer = makeLayer(
            polarCells: [c8, c10],
            polarOverrides: [c8: [a60], c10: [a67]]
        )

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.overrides.count, 4500)
    }

    // MARK: - Drei Zellen, drei verschiedene Aktionen

    func testThreeCells_threeDifferentActions() throws {
        let c8 = PolarMetricGridCell(ring: 0, angularIndex: 2)
        let c9 = PolarMetricGridCell(ring: 0, angularIndex: 3)
        let c10 = PolarMetricGridCell(ring: 0, angularIndex: 4)
        let layer = makeLayer(
            polarCells: [c8, c9, c10],
            polarOverrides: [c8: [a60], c9: [a67], c10: [a72]]
        )

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.overrides.count, 13230)
    }

    func testFarRingMappingIsOneToOne_noConflict() throws {
        let c8 = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let c9 = PolarMetricGridCell(ring: 2, angularIndex: 9)
        let layer = makeLayer(
            polarCells: [c8, c9],
            polarOverrides: [c8: [a60], c9: [a67]]
        )

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.overrides.count, 4500)
    }

    // MARK: - Kartesischer Rest

    func testCartesianCellsNotMigrated() throws {
        let cartesian: Set<MetricGridCell> = [
            MetricGridCell(column: 0, row: 0),
            MetricGridCell(column: 1, row: 0),
            MetricGridCell(column: 0, row: 1)
        ]
        let c8 = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let layer = makeLayer(
            polarCells: [c8],
            cartesianCells: cartesian
        )

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertEqual(result.cartesianCellsNotMigrated, 3)
    }

    // MARK: - Leere Ebene

    func testEmptyLayer() throws {
        let layer = makeLayer(polarCells: [])

        let result = try LegacyOverrideMigration.migrate(layer: layer, in: grid)

        XCTAssertTrue(result.overrides.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.cartesianCellsNotMigrated, 0)
    }
}
