import XCTest
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// SICK-032c3a, Abschnitt 2 -- der robuste relevante Rohwertbereich und
/// seine planare Fokusgeometrie. Pflichtnachweise 2 und 3.
@MainActor final class ScanFieldFocusAreaTests: XCTestCase {

    private func profile(of values: [UInt16]) throws -> B0ScanProfile {
        let measurements = try values.map {
            try B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0)
        }
        return try B0ScanProfile.build(
            partialScanIndex: 0, measurements: measurements, trailingBytes: [0x00]
        )
    }

    private func zone(value: ClosedRange<UInt16>, role: ZoneRole = .pitch) throws -> Zone {
        try Zone.build(
            indexLowerBound: 0.1, indexUpperBound: 0.4,
            valueLowerBound: value.lowerBound, valueUpperBound: value.upperBound, role: role
        )
    }

    /// Ein synthetisches Profil in der Größenordnung des einzigen echten
    /// Mitschnitts (SICK-012, Rohwerte ≈ 21…169) -- **keine
    /// Gerätewahrheit**, nur plausibles Material. Die Endpunkte 21 und
    /// 169 kommen wirklich vor.
    private func compactProfile() throws -> B0ScanProfile {
        var values: [UInt16] = [21, 169]
        for index in 0..<88 {
            values.append(UInt16(30 + (index * 17) % 130))
        }
        return try profile(of: values)
    }

    // MARK: - Verweigerungen (Pflichtnachweis 2)

    func testWithoutAProfileNothingIsFocused() {
        XCTAssertEqual(
            ScanFieldFocusArea.area(forProfile: nil, within: .fullField), .refused(.noProfile)
        )
    }

    func testWithOnlyUnusableValuesNothingIsFocused() throws {
        let outcome = ScanFieldFocusArea.area(
            forProfile: try profile(of: [0, 8_191, 0, 8_191]), within: .fullField
        )
        XCTAssertEqual(outcome, .refused(.noUsableMeasurement))
    }

    func testTheTwoRefusalReasonsAreDistinguishable() throws {
        let withoutProfile = ScanFieldFocusArea.area(forProfile: nil, within: .fullField)
        let withUnusableOnly = ScanFieldFocusArea.area(
            forProfile: try profile(of: [0, 8_191]), within: .fullField
        )
        XCTAssertNotEqual(withoutProfile, withUnusableOnly)
    }

    func testHasUsableMeasurementMatchesTheSameThreshold() throws {
        XCTAssertFalse(try ScanFieldFocusArea.hasUsableMeasurement(in: profile(of: [0, 8_191])))
        XCTAssertTrue(try ScanFieldFocusArea.hasUsableMeasurement(in: profile(of: [0, 100, 8_191])))
    }

    // MARK: - Kompaktheit und robuste Ausreißerregel (Pflichtnachweis 3)

    func testACompactRealisticProfileYieldsACompactRelevantRange() throws {
        let outcome = ScanFieldFocusArea.area(forProfile: try compactProfile(), within: .fullField)
        guard case .focused(let result) = outcome else {
            return XCTFail("Verweigert: \(outcome)")
        }
        // Alle 90 Werte tragen -- keiner ist ein Ausreißer, die Spanne
        // ist zu klein für die Fünffach-MAD-Schwelle.
        XCTAssertEqual(result.carriedMeasurementCount, 90)
        XCTAssertEqual(result.ignoredAsOutlierCount, 0)
        XCTAssertEqual(result.ignoredAsUnusableCount, 0)
        // Kompakt heißt: deutlich unter dem vollen Rohwertbereich.
        XCTAssertLessThan(result.valueRange.upperBound, 250)
        XCTAssertGreaterThanOrEqual(result.valueRange.lowerBound, 0)
        // Der Ausschnitt zeigt entsprechend nur einen kleinen Teil des
        // Felds -- deutlich enger als die Gesamtansicht.
        XCTAssertLessThan(result.viewport.halfExtent, 0.05)
    }

    /// **Der Kernnachweis:** Derselbe kompakte Datensatz plus ein
    /// einzelner ferner, aber gültiger Ausreißer bleibt kompakt --
    /// unterlegt mit der Gegenprobe, dass die naive `ScanFieldFit`-
    /// Maximum-Variante auf denselben Daten weit aufzieht.
    func testASingleFarOutlierDoesNotWidenTheRangeButTheNaiveMaximumVariantWould() throws {
        var values: [UInt16] = [21, 169, 6_000]
        for index in 0..<88 {
            values.append(UInt16(30 + (index * 17) % 130))
        }
        let profileWithOutlier = try profile(of: values)

        let robust = ScanFieldFocusArea.area(forProfile: profileWithOutlier, within: .fullField)
        guard case .focused(let result) = robust else {
            return XCTFail("Verweigert: \(robust)")
        }
        XCTAssertEqual(result.ignoredAsOutlierCount, 1, "Der Ausreißer wird sichtbar gezählt")
        XCTAssertEqual(result.carriedMeasurementCount, 90)
        XCTAssertLessThan(
            result.valueRange.upperBound, 250,
            "Ein einzelner Ausreißer darf den kompakten Bereich nicht aufziehen"
        )
        XCTAssertLessThan(result.viewport.halfExtent, 0.05)

        // Gegenprobe: Die bestehende, bewusst naive `ScanFieldFit`-
        // Maximum-Variante zieht auf denselben Daten fast auf die
        // Gesamtansicht auf -- **das** ist der Unterschied, den die
        // robuste Regel verhindert.
        let naive = ScanFieldFit.viewport(fitting: profileWithOutlier, within: .fullField)
        guard case .fitted(let naiveResult) = naive else {
            return XCTFail("Verweigert: \(naive)")
        }
        XCTAssertGreaterThan(
            naiveResult.viewport.halfExtent, 0.5,
            "Die naive Maximum-Variante zieht wegen des Ausreißers auf, das belegt genau die Notwendigkeit der robusten Regel"
        )
        XCTAssertGreaterThan(
            naiveResult.viewport.halfExtent, result.viewport.halfExtent * 10,
            "Robust und naiv müssen sich für denselben Datensatz deutlich unterscheiden"
        )
    }

    /// Kleine Stichproben dürfen nicht komplett weggefiltert werden:
    /// Ein einziger brauchbarer Wert hat keine Streuung (MAD `0`) und
    /// bleibt deshalb sein eigener Träger.
    func testASingleMeasurementIsNeverFilteredOut() throws {
        let outcome = ScanFieldFocusArea.area(forProfile: try profile(of: [100]), within: .fullField)
        guard case .focused(let result) = outcome else {
            return XCTFail("Verweigert: \(outcome)")
        }
        XCTAssertEqual(result.carriedMeasurementCount, 1)
        XCTAssertEqual(result.ignoredAsOutlierCount, 0)
    }

    /// Zwei weit auseinanderliegende, aber beide gültige Werte haben
    /// noch keine verlässliche Streuungsgrundlage -- auch hier bleibt
    /// jeder Wert Träger, keiner gilt als Ausreißer.
    func testTwoMeasurementsAreBothCarriedRegardlessOfTheirDistance() throws {
        let outcome = ScanFieldFocusArea.area(forProfile: try profile(of: [21, 169]), within: .fullField)
        guard case .focused(let result) = outcome else {
            return XCTFail("Verweigert: \(outcome)")
        }
        XCTAssertEqual(result.carriedMeasurementCount, 2)
        XCTAssertEqual(result.ignoredAsOutlierCount, 0)
    }

    /// **Pflichtnachweis 1 aus `task-sick-032c3a-k1.md` (Abnahmeblocker
    /// 1):** MAD `0` bei einer großen, fast durchgehend gleichen Menge
    /// schließt einen einzelnen fernen, aber gültigen Wert trotzdem
    /// robust aus. Die vorherige pauschale `MAD == 0 -> infinity`-Regel
    /// hätte hier **alle** 90 Werte getragen und den Bereich bis nahe
    /// `6000` aufgezogen.
    func testAMajorityConstantSampleWithMADZeroStillExcludesASingleFarOutlier() throws {
        var values = Array(repeating: UInt16(100), count: 89)
        values.append(6_000)
        let outcome = ScanFieldFocusArea.area(forProfile: try profile(of: values), within: .fullField)
        guard case .focused(let result) = outcome else {
            return XCTFail("Verweigert: \(outcome)")
        }
        XCTAssertEqual(result.ignoredAsOutlierCount, 1, "Der einzelne ferne Wert gilt als Ausreißer")
        XCTAssertEqual(result.carriedMeasurementCount, 89)
        XCTAssertEqual(result.ignoredAsUnusableCount, 0)
        XCTAssertEqual(result.carriedMeasurementCount + result.ignoredAsOutlierCount + result.ignoredAsUnusableCount, values.count, "Die Zähler gehen exakt auf")
        XCTAssertLessThan(
            result.valueRange.upperBound, 250,
            "Der Bereich bleibt kompakt um 100 -- nicht bis in Richtung 6000 aufgezogen"
        )
    }

    func testUnusableSentinelsAreCountedSeparatelyFromOutliers() throws {
        var values: [UInt16] = [0, 8_191, 21, 169]
        for index in 0..<88 { values.append(UInt16(30 + (index * 17) % 130)) }
        let outcome = ScanFieldFocusArea.area(forProfile: try profile(of: values), within: .fullField)
        guard case .focused(let result) = outcome else {
            return XCTFail("Verweigert: \(outcome)")
        }
        XCTAssertEqual(result.ignoredAsUnusableCount, 2)
        XCTAssertEqual(result.carriedMeasurementCount + result.ignoredAsOutlierCount, values.count - 2)
    }

    // MARK: - Padding und Mindestspanne

    func testAConstantProfileStillYieldsAValidRangeWithTheMinimumSpan() throws {
        let outcome = ScanFieldFocusArea.area(forProfile: try profile(of: [100, 100, 100]), within: .fullField)
        guard case .focused(let result) = outcome else {
            return XCTFail("Verweigert: \(outcome)")
        }
        let span = Int(result.valueRange.upperBound) - Int(result.valueRange.lowerBound)
        XCTAssertGreaterThanOrEqual(span, Int(ScanFieldFocusArea.minimumValueSpan))
    }

    func testTheResultAlwaysSurvivesTheStrictViewportFactory() throws {
        let outcome = ScanFieldFocusArea.area(forProfile: try compactProfile(), within: .fullField)
        guard case .focused(let result) = outcome else {
            return XCTFail("Verweigert: \(outcome)")
        }
        XCTAssertNoThrow(try ScanPlaneViewport.build(
            centerX: result.viewport.centerX, centerY: result.viewport.centerY,
            halfExtent: result.viewport.halfExtent
        ))
    }

    // MARK: - Learn-Kandidatin einschließen

    /// Der Fokus darf aktuelle Messung und Kandidatin gemeinsam
    /// einschließen -- eine Kandidatin außerhalb der Messspanne weitet
    /// den Bereich sichtbar auf, statt ignoriert zu werden.
    func testACandidateOutsideTheMeasuredRangeWidensTheFocus() throws {
        let withoutCandidate = ScanFieldFocusArea.area(
            forProfile: try compactProfile(), within: .fullField
        )
        guard case .focused(let plain) = withoutCandidate else {
            return XCTFail("Verweigert: \(withoutCandidate)")
        }

        let farCandidate = try zone(value: 3_000...3_200)
        let withCandidate = ScanFieldFocusArea.area(
            forProfile: try compactProfile(), candidate: farCandidate, within: .fullField
        )
        guard case .focused(let widened) = withCandidate else {
            return XCTFail("Verweigert: \(withCandidate)")
        }
        XCTAssertGreaterThan(widened.valueRange.upperBound, plain.valueRange.upperBound)
        XCTAssertGreaterThanOrEqual(widened.valueRange.upperBound, farCandidate.valueRange.upperBound)
    }

    /// Eine Kandidatin **innerhalb** der bereits getragenen Spanne
    /// ändert nichts.
    func testACandidateInsideTheMeasuredRangeDoesNotChangeTheFocus() throws {
        let plainOutcome = ScanFieldFocusArea.area(forProfile: try compactProfile(), within: .fullField)
        guard case .focused(let plain) = plainOutcome else {
            return XCTFail("Verweigert: \(plainOutcome)")
        }

        let innerCandidate = try zone(value: 50...100)
        let withCandidateOutcome = ScanFieldFocusArea.area(
            forProfile: try compactProfile(), candidate: innerCandidate, within: .fullField
        )
        guard case .focused(let withCandidate) = withCandidateOutcome else {
            return XCTFail("Verweigert: \(withCandidateOutcome)")
        }
        XCTAssertEqual(withCandidate.valueRange, plain.valueRange)
    }

    // MARK: - Reine Ansichtseinstellung (Pflichtnachweis 7)

    /// Wie `ScanFieldFit`: `current` ist nur ein Werkzeugempfänger, das
    /// Ergebnis hängt nicht vom vorherigen Ausschnitt ab.
    func testTheResultIsIndependentOfThePreviousViewport() throws {
        let eccentric = try ScanPlaneViewport.build(centerX: 0.3, centerY: -0.2, halfExtent: 0.4)
        let fromFullField = ScanFieldFocusArea.area(forProfile: try compactProfile(), within: .fullField)
        let fromEccentric = ScanFieldFocusArea.area(forProfile: try compactProfile(), within: eccentric)
        XCTAssertEqual(fromFullField, fromEccentric)
    }
}
