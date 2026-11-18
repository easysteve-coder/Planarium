//
//  PolarBenchmarkReport.swift
//  AR-0A · Runde S3 — JSON-Bericht und Zusammenfassung
//

import Foundation

// MARK: - PolarBenchmarkReport

/// Maschinenlesbarer und menschenlesbarer Bericht der Benchmark-Messungen.
/// Enthält keinen Hostnamen, keinen Benutzernamen, keinen Pfad, keinen Zeitstempel.
public struct PolarBenchmarkReport: Codable, Equatable, Sendable {

    /// Laufzeitkenndaten in Mikrosekunden.
    public struct Durations: Codable, Equatable, Sendable {
        public let meanMicroseconds: Double
        public let p95Microseconds: Double
        public let maximumMicroseconds: Double

        public init(meanMicroseconds: Double, p95Microseconds: Double, maximumMicroseconds: Double) {
            self.meanMicroseconds = meanMicroseconds
            self.p95Microseconds = p95Microseconds
            self.maximumMicroseconds = maximumMicroseconds
        }
    }

    /// Ein Eintrag im Bericht für ein Szenario.
    public struct Entry: Codable, Equatable, Sendable {
        public let label: String
        public let sectorCount: Int
        public let routingCount: Int
        public let pointCount: Int
        public let seed: UInt64
        public let evaluationCount: Int
        public let sampleCount: Int
        public let projection: Durations
        public let evaluationDifference: Durations
        public let combined: Durations
        public let checksum: String

        public init(
            label: String,
            sectorCount: Int,
            routingCount: Int,
            pointCount: Int,
            seed: UInt64,
            evaluationCount: Int,
            sampleCount: Int,
            projection: Durations,
            evaluationDifference: Durations,
            combined: Durations,
            checksum: String
        ) {
            self.label = label
            self.sectorCount = sectorCount
            self.routingCount = routingCount
            self.pointCount = pointCount
            self.seed = seed
            self.evaluationCount = evaluationCount
            self.sampleCount = sampleCount
            self.projection = projection
            self.evaluationDifference = evaluationDifference
            self.combined = combined
            self.checksum = checksum
        }
    }

    public let schemaVersion: Int          // immer 1
    public let warmupIterations: Int
    public let measuredIterations: Int
    public let processorCount: Int
    public let entries: [Entry]

    public init(
        measurements: [PolarBenchmarkMeasurement],
        warmupIterations: Int,
        measuredIterations: Int,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.schemaVersion = 1
        self.warmupIterations = warmupIterations
        self.measuredIterations = measuredIterations
        self.processorCount = processorCount

        self.entries = measurements.map { measurement in
            let convertToMicroseconds = { (nanoseconds: Double) -> Double in
                // Mikrosekunden sind Nanosekunden geteilt durch 1000,
                // auf drei Stellen gerundet über (wert / 1000 * 1000).rounded() / 1000
                return (nanoseconds / 1000 * 1000).rounded() / 1000
            }

            let projectionDurations = Durations(
                meanMicroseconds: convertToMicroseconds(measurement.projection.meanNanoseconds),
                p95Microseconds: convertToMicroseconds(measurement.projection.p95Nanoseconds),
                maximumMicroseconds: convertToMicroseconds(measurement.projection.maximumNanoseconds)
            )

            let evaluationDifferenceDurations = Durations(
                meanMicroseconds: convertToMicroseconds(measurement.evaluationDifference.meanNanoseconds),
                p95Microseconds: convertToMicroseconds(measurement.evaluationDifference.p95Nanoseconds),
                maximumMicroseconds: convertToMicroseconds(measurement.evaluationDifference.maximumNanoseconds)
            )

            let combinedDurations = Durations(
                meanMicroseconds: convertToMicroseconds(measurement.combined.meanNanoseconds),
                p95Microseconds: convertToMicroseconds(measurement.combined.p95Nanoseconds),
                maximumMicroseconds: convertToMicroseconds(measurement.combined.maximumNanoseconds)
            )

            return Entry(
                label: measurement.scenario.label,
                sectorCount: measurement.scenario.sectorCount,
                routingCount: measurement.scenario.routingCount,
                pointCount: measurement.scenario.pointCount,
                seed: measurement.scenario.seed,
                evaluationCount: measurement.evaluationCount,
                sampleCount: measurement.projection.sampleCount,
                projection: projectionDurations,
                evaluationDifference: evaluationDifferenceDurations,
                combined: combinedDurations,
                checksum: measurement.checksum
            )
        }
    }

    /// Erzeugt JSON-Daten mit sortierten Keys und Pretty-Printing.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Menschenlesbare Zusammenfassung.
    public var summaryText: String {
        var lines: [String] = []

        // Erste Zeile
        lines.append(
            "Polar-Benchmark · \(entries.count) scenarios · Warmup \(warmupIterations) · Runs \(measuredIterations) · \(processorCount) cores"
        )

        // Je Eintrag eine Zeile
        for entry in entries {
            let projectionLine = String(format: "%.3f", entry.projection.meanMicroseconds) + 
                " p95 " + String(format: "%.3f", entry.projection.p95Microseconds) + 
                " max " + String(format: "%.3f", entry.projection.maximumMicroseconds) + " µs"

            let evaluationDifferenceLine = String(format: "%.3f", entry.evaluationDifference.meanMicroseconds) + 
                " p95 " + String(format: "%.3f", entry.evaluationDifference.p95Microseconds) + 
                " max " + String(format: "%.3f", entry.evaluationDifference.maximumMicroseconds) + " µs"

            let combinedLine = String(format: "%.3f", entry.combined.meanMicroseconds) + 
                " p95 " + String(format: "%.3f", entry.combined.p95Microseconds) + 
                " max " + String(format: "%.3f", entry.combined.maximumMicroseconds) + " µs"

            let entryLine = "\(entry.label) · Projection mean \(projectionLine) · Evaluation mean \(evaluationDifferenceLine) · Total mean \(combinedLine) · Checksum \(entry.checksum)"
            lines.append(entryLine)
        }

        return lines.joined(separator: "\n")
    }
}
