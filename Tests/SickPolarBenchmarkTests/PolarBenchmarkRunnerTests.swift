//
//  PolarBenchmarkRunnerTests.swift
//
//  AR-0A · Runde S2 — Tests für Messkern, Statistik und Prüfsumme
//

import XCTest
import SickPolarBenchmark
import SickPLSMonitorKit

final class PolarBenchmarkRunnerTests: XCTestCase {

    // MARK: - 1. Kennzahlen aus eingesetzten Stichproben

    func testStatisticsHundredSamples() {
        let samples = (1...100).map { Double($0) }
        let stats = PolarBenchmarkDurationStatistics(samplesNanoseconds: samples)

        XCTAssertEqual(stats.sampleCount, 100)
        XCTAssertEqual(stats.meanNanoseconds, 50.5, accuracy: 0.001)
        XCTAssertEqual(stats.p95Nanoseconds, 95.0, accuracy: 0.001)
        XCTAssertEqual(stats.maximumNanoseconds, 100.0, accuracy: 0.001)
    }

    func testStatisticsSingleSample() {
        let stats = PolarBenchmarkDurationStatistics(samplesNanoseconds: [42.0])

        XCTAssertEqual(stats.sampleCount, 1)
        XCTAssertEqual(stats.meanNanoseconds, 42.0)
        XCTAssertEqual(stats.p95Nanoseconds, 42.0)
        XCTAssertEqual(stats.maximumNanoseconds, 42.0)
    }

    func testStatisticsTwoSamples() {
        let stats = PolarBenchmarkDurationStatistics(samplesNanoseconds: [10.0, 20.0])

        XCTAssertEqual(stats.sampleCount, 2)
        XCTAssertEqual(stats.meanNanoseconds, 15.0)
        XCTAssertEqual(stats.p95Nanoseconds, 20.0)
        XCTAssertEqual(stats.maximumNanoseconds, 20.0)
    }

    func testStatisticsEmptySample() {
        let stats = PolarBenchmarkDurationStatistics(samplesNanoseconds: [])

        XCTAssertEqual(stats.sampleCount, 0)
        XCTAssertEqual(stats.meanNanoseconds, 0)
        XCTAssertEqual(stats.p95Nanoseconds, 0)
        XCTAssertEqual(stats.maximumNanoseconds, 0)
    }

    // MARK: - 2. Prüfsumme ist reihenfolgeunabhängig

    func testChecksumOrderIndependent() {
        let evalA = SpatialRoutingEvaluation(
            routingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            target: .midiNote(channel: 0),
            value: .scalar(0.5)
        )
        let evalB = SpatialRoutingEvaluation(
            routingID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            target: .boolean(name: "test"),
            value: .boolean(true)
        )

        let forward = PolarBenchmarkChecksum.value(of: [evalA, evalB])
        let reversed = PolarBenchmarkChecksum.value(of: [evalB, evalA])

        XCTAssertEqual(forward, reversed)
    }

    // MARK: - 3. Gegenprobe: geänderte Werte ergeben andere Prüfsumme

    func testChecksumSensitivityVelocity() {
        let base = SpatialRoutingEvaluation(
            routingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            target: .midiNote(channel: 0),
            value: .notes([SpatialPlayedNote(number: 60, velocity: 100)], transition: .retrigger)
        )
        let changed = SpatialRoutingEvaluation(
            routingID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            target: .midiNote(channel: 0),
            value: .notes([SpatialPlayedNote(number: 60, velocity: 101)], transition: .retrigger)
        )

        XCTAssertNotEqual(
            PolarBenchmarkChecksum.value(of: [base]),
            PolarBenchmarkChecksum.value(of: [changed])
        )
    }

    func testChecksumSensitivityScalar() {
        let base = SpatialRoutingEvaluation(
            routingID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            target: .midiCC(channel: 0, controller: 70),
            value: .scalar(0.5)
        )
        let changed = SpatialRoutingEvaluation(
            routingID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            target: .midiCC(channel: 0, controller: 70),
            value: .scalar(0.5 + 0.000002)
        )

        XCTAssertNotEqual(
            PolarBenchmarkChecksum.value(of: [base]),
            PolarBenchmarkChecksum.value(of: [changed])
        )
    }

    // MARK: - 4. Determinismus: zwei aufeinanderfolgende Läufe

    func testDeterministicRuns() throws {
        let runner = PolarBenchmarkRunner(
            factory: PolarBenchmarkScenarioFactory(),
            warmupIterations: 1,
            measuredIterations: 3
        )
        let scenario = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 4,
            pointCount: 90,
            seed: 0x9E3779B97F4A7C15
        )

        let first = try runner.run(scenario)
        let second = try runner.run(scenario)

        XCTAssertEqual(first.checksum, second.checksum)

        XCTAssertEqual(first.projection.sampleCount, 3)
        XCTAssertEqual(first.evaluationDifference.sampleCount, 3)
        XCTAssertEqual(first.combined.sampleCount, 3)

        XCTAssertEqual(second.projection.sampleCount, 3)
        XCTAssertEqual(second.evaluationDifference.sampleCount, 3)
        XCTAssertEqual(second.combined.sampleCount, 3)

        XCTAssertGreaterThan(first.evaluationCount, 0)
    }

    // MARK: - 5. Werte endlich und nicht negativ

    func testValuesFiniteAndNonNegative() throws {
        let runner = PolarBenchmarkRunner(
            factory: PolarBenchmarkScenarioFactory(),
            warmupIterations: 1,
            measuredIterations: 3
        )
        let scenario = PolarBenchmarkScenario(
            sectorCount: 200,
            routingCount: 16,
            pointCount: 90,
            seed: 0x9E3779B97F4A7C15
        )

        let result = try runner.run(scenario)

        // Endlichkeit
        XCTAssertTrue(result.projection.meanNanoseconds.isFinite)
        XCTAssertTrue(result.projection.p95Nanoseconds.isFinite)
        XCTAssertTrue(result.projection.maximumNanoseconds.isFinite)
        XCTAssertTrue(result.evaluationDifference.meanNanoseconds.isFinite)
        XCTAssertTrue(result.evaluationDifference.p95Nanoseconds.isFinite)
        XCTAssertTrue(result.evaluationDifference.maximumNanoseconds.isFinite)
        XCTAssertTrue(result.combined.meanNanoseconds.isFinite)
        XCTAssertTrue(result.combined.p95Nanoseconds.isFinite)
        XCTAssertTrue(result.combined.maximumNanoseconds.isFinite)

        // Nichtnegativ
        XCTAssertGreaterThanOrEqual(result.projection.meanNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(result.projection.p95Nanoseconds, 0)
        XCTAssertGreaterThanOrEqual(result.projection.maximumNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(result.evaluationDifference.meanNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(result.evaluationDifference.p95Nanoseconds, 0)
        XCTAssertGreaterThanOrEqual(result.evaluationDifference.maximumNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(result.combined.meanNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(result.combined.p95Nanoseconds, 0)
        XCTAssertGreaterThanOrEqual(result.combined.maximumNanoseconds, 0)
    }
}
