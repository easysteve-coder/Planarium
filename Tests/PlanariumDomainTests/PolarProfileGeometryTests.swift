import XCTest
import func Foundation.pow
import SickPLSCore
@testable import PlanariumDomain

final class PolarProfileGeometryTests: XCTestCase {

    private func measurement(_ value: UInt16) throws -> B0ScanProfile.Measurement {
        try B0ScanProfile.Measurement.build(value: value, fieldFlags: 0)
    }

    // MARK: - Radius-Skalierung: relativ zum größten 13-Bit-Wert, nicht zum Profil-Maximum

    func testRadiusFractionForZeroValueIsZero() throws {
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(0)])

        let points = PolarProfileGeometry.points(for: profile)

        XCTAssertEqual(points[0].radiusFraction, 0.0)
    }

    func testRadiusFractionForMaxThirteenBitValueIsOne() throws {
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(0x1FFF)])

        let points = PolarProfileGeometry.points(for: profile)

        XCTAssertEqual(points[0].radiusFraction, 1.0, accuracy: 1e-9)
    }

    func testRadiusFractionIsRelativeToFixedRangeNotToProfileMaximum() throws {
        // Ein Profil, dessen größter Wert weit unter 8191 liegt, darf
        // trotzdem nicht auf 1.0 hochskaliert werden -- sonst würde ein
        // "ruhiges" Profil (alle Werte klein) optisch genauso weit
        // ausschlagen wie ein Profil mit tatsächlich hohen Rohwerten, was
        // eine nicht vorhandene Kalibrierung vortäuschen würde.
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(100)])

        let points = PolarProfileGeometry.points(for: profile)

        XCTAssertEqual(points[0].radiusFraction, 100.0 / 8191.0, accuracy: 1e-9)
        XCTAssertLessThan(points[0].radiusFraction, 1.0)
    }

    // MARK: - Winkel-Skalierung: gleichmäßig über den Indexbereich, keine Division durch 0

    func testAngleFractionSpansZeroToOneAcrossMultiplePoints() throws {
        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: [try measurement(1), try measurement(2), try measurement(3)]
        )

        let points = PolarProfileGeometry.points(for: profile)

        XCTAssertEqual(points.map(\.angleFraction), [0.0, 0.5, 1.0])
    }

    func testAngleFractionForSinglePointProfileIsMidpointNotDivisionByZero() throws {
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(1)])

        let points = PolarProfileGeometry.points(for: profile)

        XCTAssertEqual(points[0].angleFraction, 0.5)
    }

    func testEmptyProfileYieldsEmptyPointsWithoutCrashing() throws {
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [])

        let points = PolarProfileGeometry.points(for: profile)

        XCTAssertTrue(points.isEmpty)
    }

    func testPointsPreserveMeasurementOrder() throws {
        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: [try measurement(10), try measurement(20), try measurement(30)]
        )

        let points = PolarProfileGeometry.points(for: profile)

        XCTAssertEqual(points.map(\.radiusFraction), [10.0 / 8191.0, 20.0 / 8191.0, 30.0 / 8191.0])
    }

    // MARK: - Anzeige-Skalierung (SICK-012b): displayRadiusFraction macht reale, kleine Rohwerte sichtbar

    func testDisplayRadiusFractionForZeroValueIsZero() throws {
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(0)])

        let points = PolarProfileGeometry.points(for: profile)

        XCTAssertEqual(points[0].displayRadiusFraction, 0.0)
    }

    func testDisplayRadiusFractionForMaxThirteenBitValueIsOne() throws {
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(0x1FFF)])

        let points = PolarProfileGeometry.points(for: profile)

        XCTAssertEqual(points[0].displayRadiusFraction, 1.0, accuracy: 1e-9)
    }

    func testDisplayRadiusFractionIsTheFourthRootOfRadiusFraction() throws {
        // Zwei aufeinanderfolgende `.squareRoot()`-Anwendungen == vierte
        // Wurzel -- exakt gegen `pow(_:_:)` geprüft, damit die
        // Implementierung (Stdlib-`squareRoot()`, kein `pow`-Import) nicht
        // unbemerkt von der dokumentierten Kompression abweicht.
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(169)])

        let points = PolarProfileGeometry.points(for: profile)

        let expected = pow(169.0 / 8191.0, 0.25)
        XCTAssertEqual(points[0].displayRadiusFraction, expected, accuracy: 1e-9)
    }

    func testDisplayRadiusFractionMakesRealObservedValuesClearlyVisibleUnlikeTheLinearFraction() throws {
        // SICK-012b-Auftrag: die real beobachteten Rohwerte (≈ 21...169,
        // siehe Checkpoint) sind unter dem linearen `radiusFraction`
        // gegenüber der festen 8191er-Grenze praktisch unsichtbar (< 3 %).
        // `displayRadiusFraction` muss denselben Wert klar sichtbar
        // (> 20 % des Anzeigeradius) darstellen, ohne den Maximalfall zu
        // verzerren.
        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: [try measurement(21), try measurement(169)]
        )

        let points = PolarProfileGeometry.points(for: profile)

        XCTAssertLessThan(points[0].radiusFraction, 0.01)
        XCTAssertGreaterThan(points[0].displayRadiusFraction, 0.2)
        XCTAssertLessThan(points[1].radiusFraction, 0.03)
        XCTAssertGreaterThan(points[1].displayRadiusFraction, 0.35)
    }

    func testDisplayRadiusFractionIsMonotonicallyIncreasingInRadiusFraction() throws {
        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: [try measurement(1), try measurement(100), try measurement(1000), try measurement(8191)]
        )

        let points = PolarProfileGeometry.points(for: profile)

        let displayFractions = points.map(\.displayRadiusFraction)
        XCTAssertEqual(displayFractions, displayFractions.sorted())
        XCTAssertEqual(Set(displayFractions).count, displayFractions.count, "unterschiedliche Rohwerte müssen unterschiedliche Anzeigewerte ergeben, sonst wären sie in der Ansicht nicht unterscheidbar")
    }

    func testDisplayRadiusFractionOfAPointDoesNotDependOnOtherPointsInTheSameProfile() throws {
        // Kein Flackern zwischen Bildern (SICK-012b-Auftrag): die
        // Kompression ist eine reine Funktion des eigenen `radiusFraction`
        // -- unabhängig davon, welche anderen Werte im selben Profil
        // vorkommen (anders als eine Neuskalierung auf das jeweilige
        // Profil-Maximum).
        let loneProfile = try B0ScanProfile.build(partialScanIndex: 0, measurements: [try measurement(50)])
        let crowdedProfile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: [try measurement(50), try measurement(8000), try measurement(1)]
        )

        let loneDisplayFraction = PolarProfileGeometry.points(for: loneProfile)[0].displayRadiusFraction
        let crowdedDisplayFraction = PolarProfileGeometry.points(for: crowdedProfile)[0].displayRadiusFraction

        XCTAssertEqual(loneDisplayFraction, crowdedDisplayFraction, accuracy: 1e-9)
    }
}
