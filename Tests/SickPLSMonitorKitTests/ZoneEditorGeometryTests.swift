import XCTest
import SickPLSControlCore
@testable import SickPLSMonitorKit

final class ZoneEditorGeometryTests: XCTestCase {

    // MARK: - Vorwärtsrichtung deckt sich mit PolarProfileGeometry

    func testDisplayRadiusFractionForZeroValueIsZero() {
        XCTAssertEqual(ZoneEditorGeometry.displayRadiusFraction(fromValue: 0), 0.0)
    }

    func testDisplayRadiusFractionForMaxThirteenBitValueIsOne() {
        XCTAssertEqual(ZoneEditorGeometry.displayRadiusFraction(fromValue: 0x1FFF), 1.0, accuracy: 1e-9)
    }

    func testDisplayRadiusFractionMatchesThePolarProfileGeometryFormulaForTheSameRawValue() {
        // Eine gezeichnete Zonenfläche muss exakt an derselben
        // Bildschirmposition liegen wie ein Messpunkt mit demselben
        // Rohwert -- beide müssen dieselbe, einzige Formel verwenden.
        let value: UInt16 = 169
        let expected = PolarProfileGeometry.displayRadiusFraction(fromRadiusFraction: Double(value) / 8191.0)

        XCTAssertEqual(ZoneEditorGeometry.displayRadiusFraction(fromValue: value), expected, accuracy: 1e-9)
    }

    // MARK: - Rückwärtsrichtung ist die exakte Umkehrung

    func testRadiusFractionFromDisplayRadiusFractionRoundTripsForRepresentativeValues() {
        for value: UInt16 in [0, 1, 21, 169, 1000, 4000, 8000, 8191] {
            let display = ZoneEditorGeometry.displayRadiusFraction(fromValue: value)
            let roundTripped = ZoneEditorGeometry.radiusFraction(fromDisplayRadiusFraction: display)

            XCTAssertEqual(roundTripped, Double(value) / 8191.0, accuracy: 1e-6, "Rundreise für Rohwert \(value) muss verlustfrei sein")
        }
    }

    func testRadiusFractionClampsOutOfRangeDisplayFractionsInsteadOfProducingInvalidResults() {
        XCTAssertEqual(ZoneEditorGeometry.radiusFraction(fromDisplayRadiusFraction: -0.5), 0.0)
        XCTAssertEqual(ZoneEditorGeometry.radiusFraction(fromDisplayRadiusFraction: 1.5), 1.0)
    }

    // MARK: - Rohwert-Umrechnung

    func testRawValueFromRadiusFractionRoundTripsForRepresentativeValues() {
        for value: UInt16 in [0, 1, 21, 169, 1000, 4000, 8000, 8191] {
            let radiusFraction = Double(value) / 8191.0
            XCTAssertEqual(ZoneEditorGeometry.rawValue(fromRadiusFraction: radiusFraction), value)
        }
    }

    func testRawValueFromRadiusFractionClampsOutOfRangeInput() {
        XCTAssertEqual(ZoneEditorGeometry.rawValue(fromRadiusFraction: -1.0), 0)
        XCTAssertEqual(ZoneEditorGeometry.rawValue(fromRadiusFraction: 2.0), 0x1FFF)
    }

    func testRawValueFromDisplayRadiusFractionRoundTripsThroughBothConversions() {
        let value: UInt16 = 4000
        let display = ZoneEditorGeometry.displayRadiusFraction(fromValue: value)

        XCTAssertEqual(ZoneEditorGeometry.rawValue(fromDisplayRadiusFraction: display), value)
    }

    // MARK: - Indexrichtung ist bereits linear, nur Klammerung

    func testIndexFractionPassesThroughValuesInsideRange() {
        XCTAssertEqual(ZoneEditorGeometry.indexFraction(fromAngleFraction: 0.0), 0.0)
        XCTAssertEqual(ZoneEditorGeometry.indexFraction(fromAngleFraction: 0.5), 0.5)
        XCTAssertEqual(ZoneEditorGeometry.indexFraction(fromAngleFraction: 1.0), 1.0)
    }

    func testIndexFractionClampsOutOfRangeInput() {
        XCTAssertEqual(ZoneEditorGeometry.indexFraction(fromAngleFraction: -0.2), 0.0)
        XCTAssertEqual(ZoneEditorGeometry.indexFraction(fromAngleFraction: 1.2), 1.0)
    }
}
