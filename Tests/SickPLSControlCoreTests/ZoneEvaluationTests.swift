import XCTest
import SickPLSCore
@testable import SickPLSControlCore

/// Nachweis (SICK-013-Auftrag): Zonengrenzen, unterschiedliche
/// Punktzahlen, kein Treffer, Auswahl bei mehreren Treffern, unabhängige
/// Überlappungen, Normierung sowie der Beweis, dass keinerlei
/// Prognose/Stale-Wert erzeugt wird.
final class ZoneEvaluationTests: XCTestCase {

    private func measurement(_ value: UInt16) throws -> B0ScanProfile.Measurement {
        try B0ScanProfile.Measurement.build(value: value, fieldFlags: 0)
    }

    private func profile(_ values: [UInt16]) throws -> B0ScanProfile {
        try B0ScanProfile.build(partialScanIndex: 0, measurements: try values.map { try measurement($0) })
    }

    // MARK: - Zonengrenzen (inklusiv) und Trennung Index-/Wertebereich

    func testIndexExactlyAtZoneLowerBoundCounts() throws {
        // 3 Punkte, Indexanteile 0.0 / 0.5 / 1.0 -- nur Index 1 (exakt
        // 0.5, die Untergrenze) liegt in 0.5...0.6.
        let zone = try Zone.build(indexLowerBound: 0.5, indexUpperBound: 0.6, valueLowerBound: 0, valueUpperBound: 8191, role: .pitch)
        let scan = try profile([1, 500, 1])

        XCTAssertEqual(zone.evaluate(against: scan), .controlValue(500.0 / 8191.0), "der exakte untere Indexgrenzwert muss noch als Treffer zählen")
    }

    func testPointOutsideIndexRangeIsExcludedEvenIfItsValueWouldOtherwiseWin() throws {
        // 3 Punkte, Indexanteile 0.0 / 0.5 / 1.0 -- Zone erfasst nur
        // Index 1. Die viel kleineren Werte an Index 0/2 liegen zwar im
        // Wertebereich, aber außerhalb des Indexbereichs und dürfen die
        // Auswahl nicht beeinflussen.
        let zone = try Zone.build(indexLowerBound: 0.4, indexUpperBound: 0.6, valueLowerBound: 0, valueUpperBound: 8191, role: .pitch)
        let scan = try profile([1, 5000, 1])

        XCTAssertEqual(zone.evaluate(against: scan), .controlValue(5000.0 / 8191.0))
    }

    func testPointOutsideValueRangeIsExcludedEvenIfItsIndexMatches() throws {
        let zone = try Zone.build(indexLowerBound: 0.0, indexUpperBound: 1.0, valueLowerBound: 100, valueUpperBound: 200, role: .pitch)
        let scan = try profile([50, 150, 8191])

        XCTAssertEqual(zone.evaluate(against: scan), .controlValue(0.5))
    }

    // MARK: - Kein Treffer

    func testNoMatchingPointYieldsInactive() throws {
        let zone = try Zone.build(indexLowerBound: 0.0, indexUpperBound: 1.0, valueLowerBound: 100, valueUpperBound: 200, role: .pitch)
        let scan = try profile([50, 8191, 10])

        XCTAssertEqual(zone.evaluate(against: scan), .inactive)
    }

    func testEmptyProfileYieldsInactiveWithoutCrashing() throws {
        let zone = try Zone.build(indexLowerBound: 0.0, indexUpperBound: 1.0, valueLowerBound: 0, valueUpperBound: 8191, role: .pitch)
        let scan = try profile([])

        XCTAssertEqual(zone.evaluate(against: scan), .inactive)
    }

    // MARK: - Auswahl bei mehreren Treffern ("nächste erkannte Fläche")

    func testSmallestValueAmongMultipleMatchesWins() throws {
        let zone = try Zone.build(indexLowerBound: 0.0, indexUpperBound: 1.0, valueLowerBound: 0, valueUpperBound: 8191, role: .pitch)
        let scan = try profile([300, 100, 200])

        XCTAssertEqual(zone.evaluate(against: scan), .controlValue(100.0 / 8191.0))
    }

    func testMultiplePointsWithTheSameSmallestValueYieldTheSameDeterministicResult() throws {
        let zone = try Zone.build(indexLowerBound: 0.0, indexUpperBound: 1.0, valueLowerBound: 0, valueUpperBound: 8191, role: .pitch)
        let scanWithOneMinimum = try profile([100, 50, 200])
        let scanWithTiedMinimum = try profile([100, 50, 50])

        XCTAssertEqual(zone.evaluate(against: scanWithOneMinimum), .controlValue(50.0 / 8191.0))
        XCTAssertEqual(
            zone.evaluate(against: scanWithTiedMinimum), .controlValue(50.0 / 8191.0),
            "ein Gleichstand im kleinsten Rohwert muss denselben Steuerwert ergeben wie ein einzelner Treffer mit diesem Wert -- die Regel hängt nur vom Rohwert ab, nie vom Index"
        )
    }

    // MARK: - Normierung

    func testNormalizationMapsValueRangeBoundsToZeroAndOne() throws {
        let zone = try Zone.build(indexLowerBound: 0, indexUpperBound: 1, valueLowerBound: 1000, valueUpperBound: 3000, role: .volume)

        XCTAssertEqual(zone.evaluate(against: try profile([1000])), .controlValue(0.0))
        XCTAssertEqual(zone.evaluate(against: try profile([3000])), .controlValue(1.0))
        XCTAssertEqual(zone.evaluate(against: try profile([2000])), .controlValue(0.5))
    }

    // MARK: - Dynamische Punktzahl, keine 90-Punkt-Annahme

    func testWorksAcrossDifferentPointCountsWithoutAssumingNinety() throws {
        let zone = try Zone.build(indexLowerBound: 0.0, indexUpperBound: 1.0, valueLowerBound: 0, valueUpperBound: 8191, role: .pitch)

        XCTAssertEqual(zone.evaluate(against: try profile([42])), .controlValue(42.0 / 8191.0), "Ein-Punkt-Profil")
        XCTAssertEqual(
            zone.evaluate(against: try profile(Array(repeating: 4000, count: 180))),
            .controlValue(4000.0 / 8191.0),
            "180-Punkt-Profil"
        )
        XCTAssertEqual(
            zone.evaluate(against: try profile(Array(repeating: 4000, count: 361))),
            .controlValue(4000.0 / 8191.0),
            "361-Punkt-Profil"
        )
    }

    // MARK: - Unabhängige Überlappungen

    func testOverlappingZonesEvaluateIndependentlyWithoutImplicitPriority() throws {
        let narrowZone = try Zone.build(indexLowerBound: 0, indexUpperBound: 1, valueLowerBound: 0, valueUpperBound: 100, role: .pitch)
        let wideZone = try Zone.build(indexLowerBound: 0, indexUpperBound: 1, valueLowerBound: 0, valueUpperBound: 8191, role: .volume)
        let scan = try profile([50])

        let resultsInOneOrder = [narrowZone, wideZone].evaluating(against: scan)
        let resultsInReverseOrder = [wideZone, narrowZone].evaluating(against: scan)

        XCTAssertEqual(resultsInOneOrder, [.controlValue(50.0 / 100.0), .controlValue(50.0 / 8191.0)])
        XCTAssertEqual(
            resultsInReverseOrder, [.controlValue(50.0 / 8191.0), .controlValue(50.0 / 100.0)],
            "beide Zonen erfassen denselben, sich überlappenden Punkt -- jede liefert trotzdem ihren eigenen, nur von der eigenen valueRange abhängigen Steuerwert, unabhängig von der Reihenfolge"
        )
    }

    // MARK: - Kein Schätzer/keine Vorhersage, kein Stale-Wert

    func testEvaluationNeverReflectsAPreviouslyEvaluatedProfile() throws {
        let zone = try Zone.build(indexLowerBound: 0, indexUpperBound: 1, valueLowerBound: 0, valueUpperBound: 8191, role: .gate)
        let profileA = try profile([100])
        let profileB = try profile([5000])

        XCTAssertEqual(zone.evaluate(against: profileA), .controlValue(100.0 / 8191.0))
        XCTAssertEqual(
            zone.evaluate(against: profileB), .controlValue(5000.0 / 8191.0),
            "die zweite Bewertung darf nicht durch die erste beeinflusst sein"
        )
        XCTAssertEqual(
            zone.evaluate(against: profileA), .controlValue(100.0 / 8191.0),
            "eine erneute Bewertung von profileA muss wieder exakt dasselbe Ergebnis wie beim ersten Mal liefern -- kein Zustand, kein Gedächtnis, kein veralteter Wert zwischen zwei Aufrufen"
        )
    }
}
