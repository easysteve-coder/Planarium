import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class LegacyLatticeMigrationTests: XCTestCase {

    private let grid = MetricSquareGrid.halfMeter
    private let legacyCell = PolarMetricGridCell(ring: 2, angularIndex: 8)

    // MARK: - E5: Der Beleg wird an der Zelle der eingefrorenen Fixtures geprüft.

    func testE5_frozenFixtureCellMigratesToExactly2250Cells() throws {
        let result = try LegacyLatticeMigration.migrate(legacyCell, in: grid)

        XCTAssertEqual(result.cells.count, 2250,
                       "E5: Erwartet 2250 Zellen, erhalten \(result.cells.count)")
        XCTAssertNil(result.lossReason, "E5: Erwartet keinen Verlustgrund")
        XCTAssertEqual(result.radialPartialLossCentimeters, 0, "E5: Erwartet 0 cm Teilverlust")

        // Belegte Ringe: 100 bis 149.
        let rings = Set(result.cells.map(\.ring))
        XCTAssertEqual(rings, Set(100...149),
                       "E5: Erwartet Ringe 100…149, erhalten \(rings.sorted())")

        // Kleinster und größter Sektorindex.
        let sectors = result.cells.map(\.sector)
        XCTAssertEqual(sectors.min(), 180,
                       "E5: Erwartet kleinsten Sektor 180, erhalten \(String(describing: sectors.min()))")
        XCTAssertEqual(sectors.max(), 224,
                       "E5: Erwartet größten Sektor 224, erhalten \(String(describing: sectors.max()))")
    }

    // MARK: - E6: Tragende Gegenprobe — rot bei Mittelpunktregel.

    func testE6_counterProbe_midpointRuleWouldFail() throws {
        let result = try LegacyLatticeMigration.migrate(legacyCell, in: grid)

        // Mittelpunktregel liefert genau 1 Zelle; die Regel liefert 120.
        XCTAssertGreaterThan(result.cells.count, 1,
                             "E6: Mittelpunktregel würde 1 Zelle liefern, Regel liefert \(result.cells.count)")

        // Probe knapp innerhalb (radial): tick 200, raw 149 → muss in der Menge sein.
        let insideRadial = PolarDeviceLattice(tick: 200, rawCentimeters: 149)
        XCTAssertNotNil(insideRadial, "E6: Innere radiale Probe muss gültig sein")
        XCTAssertTrue(result.cells.contains(insideRadial!),
                      "E6: Innere radiale Probe (tick 200, raw 149) muss in der Zellmenge sein")

        // Probe knapp außerhalb (radial): tick 200, raw 150 → darf NICHT in der Menge sein.
        let outsideRadial = PolarDeviceLattice(tick: 200, rawCentimeters: 150)
        XCTAssertNotNil(outsideRadial, "E6: Äußere radiale Probe muss gültig sein")
        XCTAssertFalse(result.cells.contains(outsideRadial!),
                       "E6: Äußere radiale Probe (tick 200, raw 150) darf NICHT in der Zellmenge sein")

        // Probe knapp innerhalb (winklig): tick 224, raw 120 → muss in der Menge sein.
        let insideAngular = PolarDeviceLattice(tick: 224, rawCentimeters: 120)
        XCTAssertNotNil(insideAngular, "E6: Innere winklige Probe muss gültig sein")
        XCTAssertTrue(result.cells.contains(insideAngular!),
                      "E6: Innere winklige Probe (tick 224, raw 120) muss in der Zellmenge sein")

        // Probe knapp außerhalb (winklig): tick 225, raw 100 → darf NICHT in der Menge sein.
        // raw 100 → Ring 20, tps 5: Tick 224 → Sektor 44, Tick 225 → Sektor 45.
        // Die Zelle (20, 45) ist nur über Ticks 225…229 erreichbar — alle außerhalb
        // des gültigen Bereichs 180…224.
        let outsideAngular = PolarDeviceLattice(tick: 225, rawCentimeters: 100)
        XCTAssertNotNil(outsideAngular, "E6: Äußere winklige Probe muss gültig sein")
        XCTAssertFalse(result.cells.contains(outsideAngular!),
                       "E6: Äußere winklige Probe (tick 225, raw 100) darf NICHT in der Zellmenge sein")
    }

    // MARK: - M-1a2: Tragende Grenzgegenprobe — exakte Ring- und Winkelkanten.

    func testM1a2_boundaryProbes_exactRingAndAngularEdges() throws {
        let result = try LegacyLatticeMigration.migrate(legacyCell, in: grid)

        // Innere Ringgrenze: raw == 100 → IN der Menge.
        let innerRadial = PolarDeviceLattice(tick: 200, rawCentimeters: 100)
        XCTAssertNotNil(innerRadial, "M-1a2: Innere Ringgrenze muss gültig sein")
        XCTAssertTrue(result.cells.contains(innerRadial!),
                      "M-1a2: Innere Ringgrenze (raw 100) muss in der Zellmenge sein")

        // Äußere Ringgrenze: raw == 150 → NICHT in der Menge.
        let outerRadial = PolarDeviceLattice(tick: 200, rawCentimeters: 150)
        XCTAssertNotNil(outerRadial, "M-1a2: Äußere Ringgrenze muss gültig sein")
        XCTAssertFalse(result.cells.contains(outerRadial!),
                       "M-1a2: Äußere Ringgrenze (raw 150) darf NICHT in der Zellmenge sein")

        // Innere winklige Grenze: tick == 180 → IN der Menge.
        let innerAngular = PolarDeviceLattice(tick: 180, rawCentimeters: 120)
        XCTAssertNotNil(innerAngular, "M-1a2: Innere winklige Grenze muss gültig sein")
        XCTAssertTrue(result.cells.contains(innerAngular!),
                      "M-1a2: Innere winklige Grenze (tick 180) muss in der Zellmenge sein")

        // Äußere winklige Grenze: tick == 225 → NICHT in der Menge.
        // raw 100 → Ring 20, tps 5: Tick 225 ist Sektorgrenze (Sektor 45),
        // während Tick 224 in Sektor 44 liegt. Die Zelle (20, 45) ist nur über
        // Ticks 225…229 erreichbar — alle außerhalb des gültigen Bereichs.
        let outerAngular = PolarDeviceLattice(tick: 225, rawCentimeters: 100)
        XCTAssertNotNil(outerAngular, "M-1a2: Äußere winklige Grenze muss gültig sein")
        XCTAssertFalse(result.cells.contains(outerAngular!),
                       "M-1a2: Äußere winklige Grenze (tick 225, raw 100) darf NICHT in der Zellmenge sein")
    }

    // MARK: - B1: Brücke — exakte Herleitung ≡ angularStepDegrees.

    func testB1_bridge_integerExponentMatchesFloatingPointStep() {
        let historicalSizes: [Double] = [0.02, 0.05, 0.1, 0.25, 0.5, 1.0]
        var deviations = 0

        for cs in historicalSizes {
            for ring in 0...1000 {
                // Exakte Ganzzahlherleitung.
                let piBound = 3_141_592_654
                let scale = 1_000_000_000
                let ringPlusOne = ring + 1
                var k = 0
                while 3 * (1 << k) * scale < ringPlusOne * piBound {
                    k += 1
                }
                let exactStep = 90.0 / Double(1 << k)

                // Gleitkommafunktion (Darstellung).
                let outerRadius = Double(ring + 1) * cs
                let fpStep = PolarMetricCellSegment.angularStepDegrees(
                    outerRadiusMeters: outerRadius,
                    radialHeightMeters: cs
                )

                if exactStep != fpStep {
                    deviations += 1
                    if deviations <= 3 {
                        print("B1-Abweichung: ring=\(ring), cs=\(cs), exact=\(exactStep), fp=\(fpStep)")
                    }
                }
            }
        }

        XCTAssertEqual(deviations, 0,
                       "B1: Erwartet 0 Abweichungen in 24 000 Fällen, erhalten \(deviations)")
    }

    // MARK: - B2: Nicht-ganzzahliges Zentimetermaß wird benannt abgelehnt.

    func testB2_nonIntegerCentimeterGridIsRejected() throws {
        // 0.5 m = 50 cm → ganzzahlig → akzeptiert.
        let okGrid = try MetricSquareGrid.build(cellSizeMeters: 0.5)
        let cell = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let result = try LegacyLatticeMigration.migrate(cell, in: okGrid)
        XCTAssertFalse(result.cells.isEmpty, "B2: 0.5 m Raster muss Zellen liefern")

        // 0.025 m = 2.5 cm → nicht ganzzahlig → abgelehnt.
        let badGrid = try MetricSquareGrid.build(cellSizeMeters: 0.025)
        XCTAssertThrowsError(try LegacyLatticeMigration.migrate(cell, in: badGrid)) { error in
            guard case LegacyLatticeMigration.MigrationError.nonIntegerCentimeterGrid(let cs) = error else {
                XCTFail("B2: Erwartet nonIntegerCentimeterGrid, erhalten \(error)")
                return
            }
            XCTAssertEqual(cs, 0.025, "B2: Fehler muss die Rasterweite 0.025 tragen")
        }
    }

    // MARK: - B3a: 11,25°-Sektor — Tickmenge direkt an der Peilungsfunktion.

    func testB3a_tickSet_directOnBearingFunction() {
        // Altring 3, angularIndex 16, k=3, Schrittweite 11,25°.
        // Exakte obere Grenze: 180·17 / 8 = 382,5 → tick = 382,5 − 180 = 202,5.
        // Die Grenze liegt echt zwischen Tick 202 und 203 — es gibt nichts aufzurunden.
        //
        // Warum beweist dieser Fall auf Zellebene nichts?
        // Tick 203 liegt in allen Ringen 30…39 im selben Sektor wie Tick 202:
        //   Ringe 30–37 (tps 3): 202/3 = 67, 203/3 = 67 → Sektor 67
        //   Ringe 38–39 (tps 2): 202/2 = 101, 203/2 = 101 → Sektor 101
        // Die Zellmenge ist für Ticks 180…202 und 180…203 identisch (je 88 Zellen).
        // Nur die direkte Tickprüfung trägt hier.

        let ticks = LegacyLatticeMigration.bearingTicks(forRing: 3, angularIndex: 16)

        XCTAssertEqual(ticks, Array(180...202),
                       "B3a: Erwartet Ticks 180…202, erhalten \(ticks)")
        XCTAssertEqual(ticks.count, 23,
                       "B3a: Erwartet 23 Ticks, erhalten \(ticks.count)")
    }

    // MARK: - B3b: 11,25°-Sektor — tragende Gegenprobe auf Zellebene.

    func testB3b_counterProbe_cellLevel_angularIndex10() throws {
        // Altring 3, angularIndex 10, k=3, Schrittweite 11,25°.
        // Exakte obere Grenze: 180·11 / 8 = 247,5 → tick = 247,5 − 180 = 67,5.
        // Die Grenze liegt echt zwischen Tick 67 und 68.
        //
        // Hier ändert die gerundete Grenze die Zellmenge wirklich:
        // Tick 68 in Ring 38 (tps 2): sector = 68/2 = 34 → neue Zelle.
        // Tick 68 in Ring 39 (tps 2): sector = 68/2 = 34 → neue Zelle.
        // Gerundete Variante: 88 + 2 = 90 Zellen.

        let grid = MetricSquareGrid.halfMeter
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 10)
        let result = try LegacyLatticeMigration.migrate(cell, in: grid)

        // 1150 Zellen.
        XCTAssertEqual(result.cells.count, 1150,
                       "B3b: Erwartet 1150 Zellen, erhalten \(result.cells.count)")

        // Sektoren: 45…67.
        let sectors = result.cells.map(\.sector)
        XCTAssertEqual(sectors.min(), 45,
                       "B3b: Erwartet kleinsten Sektor 45, erhalten \(String(describing: sectors.min()))")
        XCTAssertEqual(sectors.max(), 67,
                       "B3b: Erwartet größten Sektor 67, erhalten \(String(describing: sectors.max()))")

        // Die zwei Zusatzzellen der gerundeten Variante (Tick 68) dürfen NICHT enthalten sein:
        // (ring 190, sector 68): Tick 68, raw 190 → 190/1 = 190, 68/1 = 68.
        let extraCell38 = PolarDeviceLattice(tick: 68, rawCentimeters: 190)
        XCTAssertNotNil(extraCell38, "B3b: Tick 68, raw 190 muss gültig sein")
        XCTAssertFalse(result.cells.contains(extraCell38!),
                       "B3b: (ring 190, sector 68) darf NICHT in der Zellmenge sein")

        // (ring 195, sector 68): Tick 68, raw 195 → 195/1 = 195, 68/1 = 68.
        let extraCell39 = PolarDeviceLattice(tick: 68, rawCentimeters: 195)
        XCTAssertNotNil(extraCell39, "B3b: Tick 68, raw 195 muss gültig sein")
        XCTAssertFalse(result.cells.contains(extraCell39!),
                       "B3b: (ring 195, sector 68) darf NICHT in der Zellmenge sein")
    }

    // MARK: - M-1b-a: Verlustgrund und Teilverlust

    func testM1ba_angularlyBelow_fullyOutside() throws {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 7)
        let result = try LegacyLatticeMigration.migrate(cell, in: grid)

        XCTAssertTrue(result.cells.isEmpty, "M-1b-a: Erwartet 0 Zellen")
        XCTAssertEqual(result.lossReason, .fullyOutsideScannerField,
                       "M-1b-a: Erwartet fullyOutsideScannerField")
        XCTAssertEqual(result.radialPartialLossCentimeters, 0,
                       "M-1b-a: Erwartet 0 cm Teilverlust")
    }

    func testM1ba_angularlyAbove_fullyOutside() throws {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 25)
        let result = try LegacyLatticeMigration.migrate(cell, in: grid)

        XCTAssertTrue(result.cells.isEmpty, "M-1b-a: Erwartet 0 Zellen")
        XCTAssertEqual(result.lossReason, .fullyOutsideScannerField,
                       "M-1b-a: Erwartet fullyOutsideScannerField")
        XCTAssertEqual(result.radialPartialLossCentimeters, 0,
                       "M-1b-a: Erwartet 0 cm Teilverlust")
    }

    func testM1ba_radiallyOutside_fullyOutside() throws {
        let cell = PolarMetricGridCell(ring: 200, angularIndex: 10)
        let result = try LegacyLatticeMigration.migrate(cell, in: grid)

        XCTAssertTrue(result.cells.isEmpty, "M-1b-a: Erwartet 0 Zellen")
        XCTAssertEqual(result.lossReason, .fullyOutsideScannerField,
                       "M-1b-a: Erwartet fullyOutsideScannerField")
        XCTAssertEqual(result.radialPartialLossCentimeters, 0,
                       "M-1b-a: Erwartet 0 cm Teilverlust")
    }

    func testM1ba_inField_noValidProbe() throws {
        let cell = PolarMetricGridCell(ring: 122, angularIndex: 259)
        let result = try LegacyLatticeMigration.migrate(cell, in: grid)

        XCTAssertTrue(result.cells.isEmpty, "M-1b-a: Erwartet 0 Zellen")
        XCTAssertEqual(result.lossReason, .noValidDeviceProbe,
                       "M-1b-a: Erwartet noValidDeviceProbe")
        XCTAssertEqual(result.radialPartialLossCentimeters, 0,
                       "M-1b-a: Erwartet 0 cm Teilverlust")
    }

    func testM1ba_upperAngularEdge_valid() throws {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 24)
        let result = try LegacyLatticeMigration.migrate(cell, in: grid)

        XCTAssertEqual(result.cells.count, 50,
                       "M-1b-a: Erwartet 50 Zellen, erhalten \(result.cells.count)")
        XCTAssertNil(result.lossReason, "M-1b-a: Erwartet keinen Verlustgrund")
        XCTAssertEqual(result.radialPartialLossCentimeters, 0,
                       "M-1b-a: Erwartet 0 cm Teilverlust")

        // Genau ein Tick: 360 — direkt an der Peilungsfunktion, nicht
        // aus dem Ergebnis abgeleitet.
        XCTAssertEqual(LegacyLatticeMigration.bearingTicks(forRing: 3, angularIndex: 24),
                       [360],
                       "M-1b-a: Erwartet genau Tick 360 an der oberen Feldkante")

        // Beobachtbare Folge im Gitter: Tick 360 bleibt Tick 360.
        let rings = Set(result.cells.map(\.ring))
        XCTAssertEqual(rings, Set(150...199),
                       "M-1b-a: Erwartet Ringe 150…199, erhalten \(rings.sorted())")
        for cell in result.cells {
            XCTAssertEqual(cell.sector, 360,
                           "M-1b-a: Ring \(cell.ring): Erwartet Tick 360, erhalten \(cell.sector)")
        }
    }

    func testM1ba_radialPartialLoss() throws {
        let cell = PolarMetricGridCell(ring: 163, angularIndex: 256)
        let result = try LegacyLatticeMigration.migrate(cell, in: grid)

        XCTAssertEqual(result.cells.count, 41,
                       "M-1b-a: Erwartet 41 Zellen, erhalten \(result.cells.count)")
        XCTAssertNil(result.lossReason, "M-1b-a: Erwartet keinen Verlustgrund")
        XCTAssertEqual(result.radialPartialLossCentimeters, 9,
                       "M-1b-a: Erwartet 9 cm Teilverlust")

        // Ringe 8150…8190, Sektor 0, ein Tick: 0.
        let rings = Set(result.cells.map(\.ring))
        XCTAssertEqual(rings, Set(8150...8190),
                       "M-1b-a: Erwartet Ringe 8150…8190, erhalten \(rings.sorted())")
        let sectors = Set(result.cells.map(\.sector))
        XCTAssertEqual(sectors, [0], "M-1b-a: Erwartet nur Sektor 0")
    }

    func testM1ba_unchangedValid() throws {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 16)
        let result = try LegacyLatticeMigration.migrate(cell, in: grid)

        XCTAssertEqual(result.cells.count, 1150,
                       "M-1b-a: Erwartet 1150 Zellen, erhalten \(result.cells.count)")
        XCTAssertNil(result.lossReason, "M-1b-a: Erwartet keinen Verlustgrund")
        XCTAssertEqual(result.radialPartialLossCentimeters, 0,
                       "M-1b-a: Erwartet 0 cm Teilverlust")
    }

    // MARK: - M-1b-a: Invariantentest

    func testM1ba_invariant_lossReasonPresentIfAndOnlyIfCellsEmpty() throws {
        var totalCases = 0
        var emptyWithReason = 0
        var nonEmptyWithoutReason = 0

        for ring in 0...40 {
            // Anzahl der Indizes hängt von k ab; wir durchmustern 0…(3·2^k).
            let maxIdx = 3 * LegacyLatticeMigration.angularDivisor(forRing: ring)

            for idx in 0...maxIdx {
                totalCases += 1
                let cell = PolarMetricGridCell(ring: ring, angularIndex: idx)
                let result = try LegacyLatticeMigration.migrate(cell, in: grid)

                if result.cells.isEmpty {
                    XCTAssertNotNil(result.lossReason,
                                   "Invariante verletzt: ring \(ring), idx \(idx) — leere Zellen ohne Grund")
                    emptyWithReason += 1
                } else {
                    XCTAssertNil(result.lossReason,
                                 "Invariante verletzt: ring \(ring), idx \(idx) — Zellen vorhanden aber Grund gesetzt")
                    nonEmptyWithoutReason += 1
                }
            }
        }

        // Der Durchlauf darf nicht entarten: beide Seiten müssen wirklich
        // vorkommen, sonst wäre die Invariante trivial erfüllbar.
        XCTAssertEqual(totalCases, 4103,
                       "M-1b-a: Erwartet 4103 durchmusterte Fälle, erhalten \(totalCases)")
        XCTAssertEqual(emptyWithReason, 1354,
                       "M-1b-a: Erwartet 1354 leere Fälle mit Grund, erhalten \(emptyWithReason)")
        XCTAssertEqual(nonEmptyWithoutReason, 2749,
                       "M-1b-a: Erwartet 2749 nicht leere Fälle ohne Grund, erhalten \(nonEmptyWithoutReason)")
    }
}
