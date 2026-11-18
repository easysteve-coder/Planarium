import XCTest
import SickPLSCore
@testable import SickPLSControlCore

/// SICK-033d: Trefferfolge, deterministische Trefferpolitik, typisierte
/// Zielwerte, Mischmatrix -- und der Beleg, dass `Zone.evaluate` bitgleich
/// zur Fassung von SICK-013 bleibt.
final class FieldHitTests: XCTestCase {

    private func profile(_ values: [UInt16], flags: [UInt8]? = nil) throws -> B0ScanProfile {
        let measurements = try values.enumerated().map { index, value in
            try B0ScanProfile.Measurement.build(value: value, fieldFlags: flags?[index] ?? 0)
        }
        return try B0ScanProfile.build(partialScanIndex: 0, measurements: measurements)
    }

    // MARK: - Trefferfolge

    func testTheSequenceKeepsOrderIndexValueAndFlags() throws {
        let scan = try profile([10, 20, 30], flags: [1, 0, 7])
        let sequence = FieldHitSequence(profile: scan)

        XCTAssertEqual(sequence.hits.map(\.order), [0, 1, 2])
        XCTAssertEqual(sequence.hits.map(\.normalizedIndex), [0, 0.5, 1])
        XCTAssertEqual(sequence.hits.map(\.rawValue), [10, 20, 30])
        XCTAssertEqual(sequence.hits.map(\.fieldFlags), [1, 0, 7])
    }

    func testASinglePointSitsAtTheMiddleAndAnEmptyProfileIsEmpty() throws {
        XCTAssertEqual(FieldHitSequence(profile: try profile([5])).hits.map(\.normalizedIndex), [0.5])
        XCTAssertTrue(FieldHitSequence(profile: try profile([])).isEmpty)
    }

    // MARK: - Politik

    func testNearestSurfaceTakesTheSmallestRawValueAndOnTiesTheEarliestOrder() throws {
        let hits = [
            try XCTUnwrap(FieldHit(order: 0, normalizedIndex: 0, rawValue: 300, fieldFlags: 0)),
            try XCTUnwrap(FieldHit(order: 1, normalizedIndex: 0.3, rawValue: 100, fieldFlags: 0)),
            try XCTUnwrap(FieldHit(order: 2, normalizedIndex: 0.6, rawValue: 100, fieldFlags: 3)),
            try XCTUnwrap(FieldHit(order: 3, normalizedIndex: 1, rawValue: 200, fieldFlags: 0))
        ]
        let chosen = HitSelectionPolicy.nearestSurface.select(from: hits)
        XCTAssertEqual(chosen?.order, 1)
        XCTAssertNil(HitSelectionPolicy.nearestSurface.select(from: []))
    }

    func testAZoneFiltersInclusivelyOnIndexAndValue() throws {
        let zone = try Zone.build(indexLowerBound: 0.5, indexUpperBound: 1, valueLowerBound: 100, valueUpperBound: 200, role: .pitch)
        let sequence = FieldHitSequence(profile: try profile([100, 100, 200, 201]))
        XCTAssertEqual(zone.hits(in: sequence).map(\.order), [2], "Index 1 liegt bei 1/3 < 0.5; 201 verlässt den Wertebereich")

        let atBounds = FieldHitSequence(profile: try profile([0, 0, 100, 200]))
        XCTAssertEqual(zone.hits(in: atBounds).map(\.order), [2, 3], "beide Grenzen inklusiv")
        XCTAssertEqual(zone.effectiveHit(in: atBounds)?.order, 2)
    }

    // MARK: - Bitgleichheit zur Fassung von SICK-013

    /// Die Referenz: der Wortlaut von `Zone.evaluate(against:)` vor
    /// SICK-033d, hier unverändert abgeschrieben.
    private func legacyEvaluate(_ zone: Zone, _ profile: B0ScanProfile) -> ZoneEvaluationResult {
        let count = profile.measurements.count
        var bestValue: UInt16?
        for (index, measurement) in profile.measurements.enumerated() {
            let fraction = count > 1 ? Double(index) / Double(count - 1) : 0.5
            guard zone.indexRange.contains(fraction) else { continue }
            guard zone.valueRange.contains(measurement.value) else { continue }
            if let currentBest = bestValue, measurement.value >= currentBest { continue }
            bestValue = measurement.value
        }
        guard let winningValue = bestValue else { return .inactive }
        let span = Double(zone.valueRange.upperBound) - Double(zone.valueRange.lowerBound)
        return .controlValue((Double(winningValue) - Double(zone.valueRange.lowerBound)) / span)
    }

    func testTheHitPathIsBitIdenticalToTheLegacyEvaluationForUsableRawValues() throws {
        // Deterministischer Generator, damit der Beleg reproduzierbar ist.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }

        let zones = [
            try Zone.build(indexLowerBound: 0, indexUpperBound: 1, valueLowerBound: 0, valueUpperBound: 8191, role: .pitch),
            try Zone.build(indexLowerBound: 0.25, indexUpperBound: 0.75, valueLowerBound: 400, valueUpperBound: 3000, role: .volume),
            try Zone.build(indexLowerBound: 0.5, indexUpperBound: 0.5001, valueLowerBound: 1, valueUpperBound: 2, role: .gate),
            try Zone.build(indexLowerBound: 0.9, indexUpperBound: 1, valueLowerBound: 7000, valueUpperBound: 8191, role: .filter)
        ]

        var compared = 0
        for count in [0, 1, 2, 3, 90, 180, 361] {
            for _ in 0..<40 {
                var values: [UInt16] = []
                for _ in 0..<count {
                    // Häufige Gleichstände erzwingen: kleiner Wertevorrat.
                    // Nur brauchbare Rohwerte: der Altweg filterte nicht, der
                    // Trefferpfad filtert seit P-1b. Bitgleich sind beide genau
                    // dort, wo sie dieselbe Eingabe sehen.
                    values.append(UsableRawDistance.lowestRawValue + UInt16(next() % (next() % 3 == 0 ? 8 : 8_190)))
                }
                let scan = try profile(values)
                let hits = FieldHitSequence(profile: scan)
                for zone in zones {
                    let expected = legacyEvaluate(zone, scan)
                    XCTAssertEqual(zone.evaluate(against: scan), expected)
                    XCTAssertEqual(zone.evaluate(hits: hits), expected)
                    if case .controlValue(let value) = expected, case .controlValue(let actual) = zone.evaluate(hits: hits) {
                        XCTAssertEqual(value.bitPattern, actual.bitPattern, "bitgleich, nicht nur nahe")
                    }
                    compared += 1
                }
            }
        }
        XCTAssertGreaterThan(compared, 1000)
    }

    func testTheHitPathDepartsFromTheLegacyEvaluationExactlyAtTheUnusableWireValues() throws {
        // Die Abweichung ist gewollt: „kein Echo" und „Bereichsende" sind keine
        // gemessene Fläche und dürfen kein Gate öffnen.
        let zone = try Zone.build(
            indexLowerBound: 0, indexUpperBound: 1,
            valueLowerBound: 0, valueUpperBound: 8_191, role: .gate
        )

        for unusable: UInt16 in [0, 8_191] {
            let scan = try profile([unusable])
            XCTAssertTrue(FieldHitSequence(profile: scan).isEmpty)
            XCTAssertEqual(zone.evaluate(against: scan), .inactive)
            XCTAssertNil(
                zone.targetValue(hits: FieldHitSequence(profile: scan)),
                "Ohne brauchbaren Treffer bleibt das Gate aus"
            )
            // Gegenprobe, dass die Abweichung wirklich an diesem Wert hängt und
            // nicht am Aufbau des Tests: der Altweg liefert hier einen Wert.
            guard case .controlValue = legacyEvaluate(zone, scan) else {
                return XCTFail("Der Altweg muss hier einen Wert liefern, sonst prüft der Test nichts")
            }
        }

        // Derselbe Aufbau mit einer brauchbaren Messung öffnet das Gate weiter.
        XCTAssertNotNil(zone.targetValue(hits: FieldHitSequence(profile: try profile([1]))))
    }

    func testAnUnusableWireValueCannotBecomeAHitAtAll() {
        XCTAssertNil(FieldHit(order: 0, normalizedIndex: 0, rawValue: 0, fieldFlags: 0))
        XCTAssertNil(FieldHit(order: 0, normalizedIndex: 0, rawValue: 8_191, fieldFlags: 0))
        XCTAssertNotNil(FieldHit(order: 0, normalizedIndex: 0, rawValue: 1, fieldFlags: 0))
        XCTAssertNotNil(FieldHit(order: 0, normalizedIndex: 0, rawValue: 8_190, fieldFlags: 0))
    }

    func testTheSequenceSkipsUnusableMeasurementsAndKeepsTheDeviceIndexOfTheRest() throws {
        // Vier Messungen, zwei brauchbar. Die überlebenden behalten ihre
        // Empfangsreihenfolge und ihren normierten Index aus der
        // ursprünglichen Punktzahl — nicht aus der gefilterten Liste. Eine
        // Neunummerierung würde die Winkellage verschieben.
        let sequence = FieldHitSequence(profile: try profile([0, 100, 8_191, 200]))

        XCTAssertEqual(sequence.hits.map(\.order), [1, 3])
        XCTAssertEqual(sequence.hits.map(\.rawValue), [100, 200])
        XCTAssertEqual(sequence.hits[0].normalizedIndex, Zone.indexFraction(forIndex: 1, count: 4))
        XCTAssertEqual(sequence.hits[1].normalizedIndex, Zone.indexFraction(forIndex: 3, count: 4))
    }

    // MARK: - Typisierte Zielwerte

    func testAZoneYieldsGateOrContinuousNeverDiscrete() throws {
        let sequence = FieldHitSequence(profile: try profile([500]))
        for role in ZoneRole.allCases {
            let zone = try Zone.build(indexLowerBound: 0, indexUpperBound: 1, valueLowerBound: 0, valueUpperBound: 1000, role: role)
            let value = zone.targetValue(hits: sequence)
            switch role {
            case .gate:
                XCTAssertEqual(value, .gate(0.5))
            case .pitch, .volume, .filter, .effectSend:
                XCTAssertEqual(value, .continuous(0.5))
            }
            XCTAssertNotEqual(value?.kind, .discrete)
        }
        let miss = try Zone.build(indexLowerBound: 0, indexUpperBound: 1, valueLowerBound: 600, valueUpperBound: 1000, role: .pitch)
        XCTAssertNil(miss.targetValue(hits: sequence))
    }

    func testTargetValueKindsAreClosed() {
        XCTAssertEqual(ControlTargetValue.continuous(0.2).kind, .continuous)
        XCTAssertEqual(ControlTargetValue.discrete(DiscreteStep(value: 3, range: 7)).kind, .discrete)
        XCTAssertEqual(ControlTargetValue.gate(1).kind, .gate)
        XCTAssertEqual(ControlTargetKind.allCases.count, 3)
    }

    // MARK: - Mischmatrix

    func testMixRulesArePureAndNeverInventZero() {
        let layers: [Double?] = [nil, 0.7, 0.2, nil, 0.9]
        XCTAssertEqual(LayerMixRule.firstActive.mix(layers), 0.7)
        XCTAssertEqual(LayerMixRule.maximum.mix(layers), 0.9)
        XCTAssertEqual(LayerMixRule.minimum.mix(layers), 0.2)
        for rule in LayerMixRule.allCases {
            XCTAssertNil(rule.mix([nil, nil]), "\(rule): alle inaktiv ist inaktiv, nicht 0")
            XCTAssertNil(rule.mix([]))
        }
        XCTAssertEqual(LayerMixRule.firstActive([nil, 4, 2] as [Int?]), 4)
        XCTAssertNil(LayerMixRule.firstActive([nil] as [Int?]))
    }

    func testTheUsableRangeIsOneNotionAndNamesBothWireValuesItExcludes() {
        // Genau die Grenzen, die der Lernvertrag seit SICK-030c benutzt.
        XCTAssertEqual(UsableRawDistance.lowestRawValue, 1)
        XCTAssertEqual(UsableRawDistance.highestRawValue, 8_190)

        // „Kein Echo" und „Bereichsende" sind gültige Drahtwerte, aber keine
        // gemessene Fläche.
        XCTAssertFalse(UsableRawDistance.contains(0))
        XCTAssertFalse(UsableRawDistance.contains(8_191))
        XCTAssertTrue(UsableRawDistance.contains(1))
        XCTAssertTrue(UsableRawDistance.contains(8_190))
        XCTAssertTrue(UsableRawDistance.contains(4_000))
    }
}
