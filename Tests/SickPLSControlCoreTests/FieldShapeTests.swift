import XCTest
import SickPLSCore
@testable import SickPLSControlCore

/// SICK-033e: Raster, Fächer und Tonartfelder mit expliziten Zellenwerten,
/// abhängig nur von Index und Rohwert des Treffers -- Streifen bleibt
/// bitgleich, Gate bleibt Streifen.
final class FieldShapeTests: XCTestCase {

    private func sequence(_ values: [UInt16]) throws -> FieldHitSequence {
        let measurements = try values.map { try B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0) }
        return FieldHitSequence(profile: try B0ScanProfile.build(partialScanIndex: 0, measurements: measurements))
    }

    private func zone(_ role: ZoneRole = .pitch) throws -> Zone {
        try Zone.build(indexLowerBound: 0, indexUpperBound: 1, valueLowerBound: 0, valueUpperBound: 1000, role: role)
    }

    // MARK: - Fabriken

    func testCellFactoriesRefuseInconsistentInput() {
        XCTAssertThrowsError(try GridCells.build(columns: 0, rows: 1, values: [], range: 0))
        XCTAssertThrowsError(try GridCells.build(columns: 2, rows: 1, values: [0], range: 1)) {
            XCTAssertEqual($0 as? GridCells.BuildError, .valueCountMismatch(expected: 2, actual: 1))
        }
        XCTAssertThrowsError(try GridCells.build(columns: 1, rows: 1, values: [5], range: 4)) {
            XCTAssertEqual($0 as? GridCells.BuildError, .valueOutOfRange(5, range: 4))
        }
        XCTAssertThrowsError(try FanCells.build(values: [], range: 0))
        XCTAssertThrowsError(try FanCells.counting(sectors: 0))
        XCTAssertThrowsError(try KeyCells.build(scale: .major, octaves: 0))
        XCTAssertThrowsError(try KeyCells.build(scale: .chromatic, octaves: 6)) {
            XCTAssertEqual($0 as? KeyCells.BuildError, .cellsExceedSpan(highest: 72, spanSemitones: 60))
        }
    }

    func testAGateFieldMustBeAStrip() throws {
        let cells = try FanCells.counting(sectors: 3)
        XCTAssertThrowsError(try Field.build(zone: try zone(.gate), shape: .fan(cells))) {
            XCTAssertEqual($0 as? Field.BuildError, .gateRequiresStrip)
        }
        XCTAssertNoThrow(try Field.build(zone: try zone(.gate), shape: .strip))
        XCTAssertEqual(Field.strip(try zone(.gate)).shape, .strip)
    }

    // MARK: - Explizite Zellenwerte

    func testKeyCellsListTheScaleDegreesPlusTheClosingOctave() throws {
        let major = try KeyCells.build(scale: .major, octaves: 1)
        XCTAssertEqual(major.values, [0, 2, 4, 5, 7, 9, 11, 12])
        XCTAssertEqual(major.range, 60)
        let pentatonic = try KeyCells.build(scale: .pentatonicMinor, octaves: 2, rootOffset: 12)
        XCTAssertEqual(pentatonic.values, [12, 15, 17, 19, 22, 24, 27, 29, 31, 34, 36])
    }

    func testTheStripIsBitIdenticalToTheZone() throws {
        let hits = try sequence([700, 300, 900])
        let field = try Field.build(zone: try zone(.volume), shape: .strip)
        XCTAssertEqual(field.targetValue(hits: hits), try zone(.volume).targetValue(hits: hits))
        XCTAssertEqual(field.targetValue(hits: hits), .continuous(0.3))
    }

    func testGridCellsFollowIndexAndValueOfTheEffectiveHit() throws {
        // 2 Spalten × 2 Zeilen, Werte explizit: [links unten, rechts unten, links oben, rechts oben]
        let cells = try GridCells.build(columns: 2, rows: 2, values: [10, 20, 30, 40], range: 40)
        let field = try Field.build(zone: try zone(), shape: .grid(cells))

        // Kleinster Rohwert gewinnt: Index 2 von 0…4 (0.5 → rechte Spalte), Wert 100 (untere Zeile).
        XCTAssertEqual(field.targetValue(hits: try sequence([5000, 5000, 100, 5000, 5000])), .discrete(DiscreteStep(value: 20, range: 40)))
        // Index 0 → linke Spalte, Wert 900 → obere Zeile.
        XCTAssertEqual(field.targetValue(hits: try sequence([900, 5000, 5000, 5000, 5000])), .discrete(DiscreteStep(value: 30, range: 40)))
        // Obere Grenze gehört zur letzten Zelle.
        XCTAssertEqual(field.targetValue(hits: try sequence([5000, 5000, 5000, 5000, 1000])), .discrete(DiscreteStep(value: 40, range: 40)))
        XCTAssertNil(field.targetValue(hits: try sequence([5000, 5000])))
    }

    func testFanSectorsFollowOnlyTheIndex() throws {
        let cells = try FanCells.build(values: [3, 1, 2], range: 3)
        let field = try Field.build(zone: try zone(), shape: .fan(cells))
        XCTAssertEqual(field.targetValue(hits: try sequence([10, 5000, 5000, 5000])), .discrete(DiscreteStep(value: 3, range: 3)))
        XCTAssertEqual(field.targetValue(hits: try sequence([5000, 5000, 999, 5000])), .discrete(DiscreteStep(value: 2, range: 3)), "Index 2/3 → dritter Sektor")
        XCTAssertEqual(field.targetValue(hits: try sequence([5000, 10, 5000, 5000])), .discrete(DiscreteStep(value: 1, range: 3)))
    }

    func testKeyFieldsYieldSemitoneOffsetsOverTheStandardSpan() throws {
        let cells = try KeyCells.build(scale: .major, octaves: 1)
        let field = try Field.build(zone: try zone(), shape: .key(cells))
        // 8 Zellen über den Index; Index 7/7 = 1.0 → letzte Zelle = 12.
        let top = field.targetValue(hits: try sequence([5000, 5000, 5000, 5000, 5000, 5000, 5000, 10]))
        XCTAssertEqual(top, .discrete(DiscreteStep(value: 12, range: 60)))
        // Normiert 12/60 = 0.2 -- dieselbe Pitch-Domäne wie der Streifen.
        if case .discrete(let step) = top { XCTAssertEqual(step.normalized, 0.2, accuracy: 1e-12) }
        let first = field.targetValue(hits: try sequence([10, 5000, 5000, 5000, 5000, 5000, 5000, 5000]))
        XCTAssertEqual(first, .discrete(DiscreteStep(value: 0, range: 60)))
    }

    // MARK: - Stabil gegen alles außer Treffer

    /// Die Zellenwahl kennt keinen Bildschirm: Zwei Felder mit gleichen
    /// Zonen und Zellen liefern für gleiche Treffer gleiche Werte, egal
    /// wie oft und in welcher Reihenfolge gefragt wird.
    func testCellSelectionIsAPureFunctionOfTheHits() throws {
        let cells = try GridCells.counting(columns: 3, rows: 3)
        let field = try Field.build(zone: try zone(), shape: .grid(cells))
        let hits = try sequence([5000, 640, 5000, 5000])
        let first = field.targetValue(hits: hits)
        for _ in 0..<5 {
            XCTAssertEqual(field.targetValue(hits: hits), first)
        }
        XCTAssertEqual(first, .discrete(DiscreteStep(value: 4, range: 8)), "Spalte 1 (Index 1/3), Zeile 1 (640/1000) → 1·3 + 1")
    }

    func testCellIndexBoundariesAreClosedAtTheTop() {
        XCTAssertEqual(FieldShape.cellIndex(for: 0, count: 4), 0)
        XCTAssertEqual(FieldShape.cellIndex(for: 0.25, count: 4), 1)
        XCTAssertEqual(FieldShape.cellIndex(for: 0.999, count: 4), 3)
        XCTAssertEqual(FieldShape.cellIndex(for: 1, count: 4), 3)
        XCTAssertEqual(FieldShape.cellIndex(for: 0.7, count: 1), 0)
    }
}
