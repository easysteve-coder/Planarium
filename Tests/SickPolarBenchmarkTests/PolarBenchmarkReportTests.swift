//
//  PolarBenchmarkReportTests.swift
//
//  AR-0A · Runde S3 — Tests für JSON-Bericht und Zusammenfassung
//

import XCTest
@testable import SickPolarBenchmark
import SickPLSMonitorKit

final class PolarBenchmarkReportTests: XCTestCase {

    // MARK: - 1. Umlauf: jsonData() Roundtrip

    func testJSONRoundtrip() throws {
        // Baue PolarBenchmarkMeasurement-Werte selbst zusammen
        let scenario = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 4,
            pointCount: 0,
            seed: 0x9E3779B97F4A7C15
        )

        let projectionStats = PolarBenchmarkDurationStatistics(samplesNanoseconds: [1000.0, 2000.0, 3000.0])
        let evaluationDiffStats = PolarBenchmarkDurationStatistics(samplesNanoseconds: [500.0, 1000.0, 1500.0])
        let combinedStats = PolarBenchmarkDurationStatistics(samplesNanoseconds: [1500.0, 3000.0, 4500.0])

        let measurement = PolarBenchmarkMeasurement(
            scenario: scenario,
            projection: projectionStats,
            evaluationDifference: evaluationDiffStats,
            combined: combinedStats,
            evaluationCount: 4,
            checksum: "0123456789abcdef"
        )

        let report = PolarBenchmarkReport(
            measurements: [measurement],
            warmupIterations: 1,
            measuredIterations: 3,
            processorCount: 8
        )

        let jsonData = try report.jsonData()
        let decodedReport = try JSONDecoder().decode(PolarBenchmarkReport.self, from: jsonData)

        XCTAssertEqual(decodedReport, report)
        XCTAssertEqual(decodedReport.schemaVersion, 1)
    }

    // MARK: - 2. Reihenfolge und Vollständigkeit

    func testOrderAndCompleteness() throws {
        let scenario1 = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 4,
            pointCount: 0,
            seed: 0x9E3779B97F4A7C15
        )
        let scenario2 = PolarBenchmarkScenario(
            sectorCount: 200,
            routingCount: 8,
            pointCount: 0,
            seed: 0x1234567890ABCDEF
        )

        let measurement1 = PolarBenchmarkMeasurement(
            scenario: scenario1,
            projection: PolarBenchmarkDurationStatistics(samplesNanoseconds: [1000.0]),
            evaluationDifference: PolarBenchmarkDurationStatistics(samplesNanoseconds: [500.0]),
            combined: PolarBenchmarkDurationStatistics(samplesNanoseconds: [1500.0]),
            evaluationCount: 4,
            checksum: "aaaaaaaaaaaaaaaa"
        )

        let measurement2 = PolarBenchmarkMeasurement(
            scenario: scenario2,
            projection: PolarBenchmarkDurationStatistics(samplesNanoseconds: [2000.0]),
            evaluationDifference: PolarBenchmarkDurationStatistics(samplesNanoseconds: [1000.0]),
            combined: PolarBenchmarkDurationStatistics(samplesNanoseconds: [3000.0]),
            evaluationCount: 8,
            checksum: "bbbbbbbbbbbbbbbb"
        )

        let report = PolarBenchmarkReport(
            measurements: [measurement1, measurement2],
            warmupIterations: 1,
            measuredIterations: 3,
            processorCount: 8
        )

        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.entries[0].label, "s100-r4")
        XCTAssertEqual(report.entries[0].checksum, "aaaaaaaaaaaaaaaa")
        XCTAssertEqual(report.entries[1].label, "s200-r8")
        XCTAssertEqual(report.entries[1].checksum, "bbbbbbbbbbbbbbbb")
    }

    // MARK: - 3. Zusammenfassung Zeilenanzahl und Inhalt

    func testSummaryLineCount() throws {
        let scenarios = [
            PolarBenchmarkScenario(sectorCount: 100, routingCount: 4, pointCount: 0, seed: 1),
            PolarBenchmarkScenario(sectorCount: 200, routingCount: 8, pointCount: 0, seed: 2),
            PolarBenchmarkScenario(sectorCount: 50, routingCount: 2, pointCount: 0, seed: 3)
        ]

        let measurements = scenarios.map { scenario in
            PolarBenchmarkMeasurement(
                scenario: scenario,
                projection: PolarBenchmarkDurationStatistics(samplesNanoseconds: [1000.0]),
                evaluationDifference: PolarBenchmarkDurationStatistics(samplesNanoseconds: [500.0]),
                combined: PolarBenchmarkDurationStatistics(samplesNanoseconds: [1500.0]),
                evaluationCount: 4,
                checksum: "checksum\(scenario.label)"
            )
        }

        let report = PolarBenchmarkReport(
            measurements: measurements,
            warmupIterations: 1,
            measuredIterations: 3,
            processorCount: 8
        )

        let summary = report.summaryText
        let lines = summary.components(separatedBy: "\n")

        // Erste Zeile + 3 Einträge = 4 Zeilen
        XCTAssertEqual(lines.count, 4)

        // Jeder Eintrag sollte Label und Prüfsumme nennen
        for (index, entry) in report.entries.enumerated() {
            let line = lines[index + 1] // +1 wegen der Header-Zeile
            XCTAssertTrue(line.contains(entry.label))
            XCTAssertTrue(line.contains(entry.checksum))
        }
    }

    // MARK: - 4. Gegenprobe Redaktion

    func testRedaction() throws {
        let scenario = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 4,
            pointCount: 0,
            seed: 0x9E3779B97F4A7C15
        )

        let measurement = PolarBenchmarkMeasurement(
            scenario: scenario,
            projection: PolarBenchmarkDurationStatistics(samplesNanoseconds: [1000.0]),
            evaluationDifference: PolarBenchmarkDurationStatistics(samplesNanoseconds: [500.0]),
            combined: PolarBenchmarkDurationStatistics(samplesNanoseconds: [1500.0]),
            evaluationCount: 4,
            checksum: "0123456789abcdef"
        )

        let report = PolarBenchmarkReport(
            measurements: [measurement],
            warmupIterations: 1,
            measuredIterations: 3,
            processorCount: 8
        )

        let jsonString = String(data: try report.jsonData(), encoding: .utf8)!

        // Gegenprobe: Keine verbotenen Inhalte
        XCTAssertFalse(jsonString.contains("hostName"))
        XCTAssertFalse(jsonString.contains("HostName"))
        XCTAssertFalse(jsonString.contains("username"))
        XCTAssertFalse(jsonString.contains("Username"))
        XCTAssertFalse(jsonString.contains("NSUserName"))
        XCTAssertFalse(jsonString.contains("/Users/"))
        XCTAssertFalse(jsonString.contains("timestamp"))
        XCTAssertFalse(jsonString.contains("Timestamp"))

        // Counter test: Ein erfundener Marker sollte nicht durchkommen
        // (Dies ist eine negative Prüfung - der JSON sollte keinen Marker enthalten)
        XCTAssertFalse(jsonString.contains("SECRET_REDACTION_MARKER"))
    }

    // MARK: - 5. Determinismus von jsonData()

    func testDeterministicJSON() throws {
        let scenario = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 4,
            pointCount: 0,
            seed: 0x9E3779B97F4A7C15
        )

        let measurement = PolarBenchmarkMeasurement(
            scenario: scenario,
            projection: PolarBenchmarkDurationStatistics(samplesNanoseconds: [1000.0, 2000.0, 3000.0]),
            evaluationDifference: PolarBenchmarkDurationStatistics(samplesNanoseconds: [500.0, 1000.0, 1500.0]),
            combined: PolarBenchmarkDurationStatistics(samplesNanoseconds: [1500.0, 3000.0, 4500.0]),
            evaluationCount: 4,
            checksum: "0123456789abcdef"
        )

        let report = PolarBenchmarkReport(
            measurements: [measurement],
            warmupIterations: 1,
            measuredIterations: 3,
            processorCount: 8
        )

        let jsonData1 = try report.jsonData()
        let jsonData2 = try report.jsonData()

        XCTAssertEqual(jsonData1, jsonData2)
    }
}
