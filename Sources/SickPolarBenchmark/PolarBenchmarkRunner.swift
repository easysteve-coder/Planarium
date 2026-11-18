//
//  PolarBenchmarkRunner.swift
//  AR-0A - S2: Messkern, Statistik, Pruefsumme
//

import Foundation
import PlanariumDomain
import SickPLSCore
import SickPLSControlCore
import SickPLSMonitorKit

// MARK: - Duration Statistics

/// Kennzahlen für Laufzeitmessungen in Nanosekunden.
public struct PolarBenchmarkDurationStatistics: Equatable, Sendable {
    public let sampleCount: Int
    public let meanNanoseconds: Double
    public let p95Nanoseconds: Double
    public let maximumNanoseconds: Double

    public init(samplesNanoseconds: [Double]) {
        self.sampleCount = samplesNanoseconds.count
        
        if samplesNanoseconds.isEmpty {
            self.meanNanoseconds = 0
            self.p95Nanoseconds = 0
            self.maximumNanoseconds = 0
        } else {
            let sorted = samplesNanoseconds.sorted()
            self.meanNanoseconds = sorted.reduce(0, +) / Double(sorted.count)
            
            let p95Index = min(sorted.count - 1, max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1))
            self.p95Nanoseconds = Double(sorted[p95Index])
            
            self.maximumNanoseconds = Double(sorted.last!)
        }
    }
}

// MARK: - Checksum Calculation

/// FNV-1a 64-bit Hash für die Prüfsummenberechnung.
/// Offset: 0xcbf29ce484222325, Prime: 0x100000001b3
private func fnv1a64Hash(_ data: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    let prime: UInt64 = 0x100000001b3
    for byte in data {
        hash ^= UInt64(byte)
        hash = (hash &* prime) & 0xFFFFFFFFFFFFFFFF
    }
    return hash
}

private func checksumValue(for evaluation: SpatialRoutingEvaluation) -> String {
    switch evaluation.value {
    case .programChange(let selection):
        return "\(evaluation.routingID.uuidString)|pc\(selection.program)/\(selection.bankMSB.map(String.init) ?? "-")/\(selection.bankLSB.map(String.init) ?? "-")"
    case .inactive:
        return "\(evaluation.routingID.uuidString)|i"
    case let .scalar(value):
        return "\(evaluation.routingID.uuidString)|s\(String(format: "%.6f", value))"
    case let .boolean(value):
        return "\(evaluation.routingID.uuidString)|b\(value ? "1" : "0")"
    case let .notes(set, transition):
        let sortedNotes = set.map { "\($0.number)/\($0.velocity)" }.sorted().joined(separator: ",")
        let transitionString: String
        switch transition {
        case .retrigger:
            transitionString = "#r"
        case .legato:
            transitionString = "#l"
        case .holdUntilNext:
            transitionString = "#h"
        case .toggle:
            transitionString = "#t"
        case let .overlap(milliseconds):
            transitionString = "#o\(String(format: "%.3f", milliseconds))"
        }
        return "\(evaluation.routingID.uuidString)|n\(sortedNotes)\(transitionString)"
    }
}

public enum PolarBenchmarkChecksum {
    public static func value(of evaluations: [SpatialRoutingEvaluation]) -> String {
        let texts = evaluations.map { checksumValue(for: $0) }.sorted()
        let combined = texts.joined(separator: "\n")
        let hash = fnv1a64Hash(Array(combined.utf8))
        return String(format: "%016llx", hash)
    }
}

// MARK: - Measurement

/// Ein einzelnes Benchmark-Messungsergebnis.
public struct PolarBenchmarkMeasurement: Equatable, Sendable {
    public let scenario: PolarBenchmarkScenario
    public let projection: PolarBenchmarkDurationStatistics
    public let evaluationDifference: PolarBenchmarkDurationStatistics
    public let combined: PolarBenchmarkDurationStatistics
    public let evaluationCount: Int
    public let checksum: String

    public init(
        scenario: PolarBenchmarkScenario,
        projection: PolarBenchmarkDurationStatistics,
        evaluationDifference: PolarBenchmarkDurationStatistics,
        combined: PolarBenchmarkDurationStatistics,
        evaluationCount: Int,
        checksum: String
    ) {
        self.scenario = scenario
        self.projection = projection
        self.evaluationDifference = evaluationDifference
        self.combined = combined
        self.evaluationCount = evaluationCount
        self.checksum = checksum
    }
}

// MARK: - Error

public enum PolarBenchmarkError: Error, Equatable, Sendable {
    case unstableChecksum(scenarioLabel: String, expected: String, found: String)
}

/// Prepared offline input to the same compiled selector and value plan used
/// by the runtime. Compilation is outside all measured intervals.
public struct PreparedPolarBenchmark: Sendable {
    private let compiled: CompiledInstrument
    private let frame: ProfileFrame
    public init(profile: B0ScanProfile, workspace: SpatialInstrumentWorkspace) throws {
        let workspaceValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace))
        let compatibility = try CompatibilityImporter.read(JSONSerialization.data(withJSONObject: ["formatVersion": 3, "spatialWorkspace": workspaceValue])).get()
        let spatial = try SpatialDocumentImporter.document(from: compatibility).get().document!
        compiled = try InstrumentCompiler.compile(.init(spatial: spatial, detection: .allStagesOff, revision: .newSession()))
        // Empty input is the explicit no-measurement case, never an angle.
        let geometry = profile.measurements.isEmpty ? ProfileGeometryIdentity(operatingMode: "fullScan", pointCount: 361, startAngleDegrees: -90, endAngleDegrees: 90) : try FullScanProfileAdapter.geometry(from: profile)
        frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
            measurements: profile.measurements.isEmpty ? [] : try FullScanProfileAdapter.measurements(from: profile), geometry: geometry, rawProfile: profile)
    }
    public func evaluate() throws -> [SpatialRoutingEvaluation] {
        var detection = SpatialDetectionPipeline()
        let selected = detection.select(frame: frame, instrument: compiled, contour: nil)
        return try compiled.evaluate(active: selected.activeHandles)
    }
}

// MARK: - Runner

/// Läuft Benchmark-Messungen für Polarszenarien durch und liefert Statistik und Prüfsumme.
public struct PolarBenchmarkRunner: Sendable {
    public let factory: PolarBenchmarkScenarioFactory
    public let warmupIterations: Int
    public let measuredIterations: Int

    public init(
        factory: PolarBenchmarkScenarioFactory = PolarBenchmarkScenarioFactory(),
        warmupIterations: Int = 5,
        measuredIterations: Int = 60
    ) {
        self.factory = factory
        self.warmupIterations = warmupIterations
        self.measuredIterations = measuredIterations
    }

    public func run(_ scenario: PolarBenchmarkScenario) throws -> PolarBenchmarkMeasurement {
        // Profil und Workspace VOR der Messung einmal erzeugen
        let profile = try factory.profile(for: scenario)
        let workspace = factory.workspace(for: scenario)
        let input = try PreparedPolarBenchmark(profile: profile, workspace: workspace)
        func evaluate() throws -> [SpatialRoutingEvaluation] { try input.evaluate() }
        
        // Erste Auswertung für Referenz-Prüfsumme
        let firstEvaluations = try evaluate()
        let referenceChecksum = PolarBenchmarkChecksum.value(of: firstEvaluations)
        let evaluationCount = firstEvaluations.count
        
        // Warmup-Durchläufe
        var warmupProjectionCountSum: Int = 0
        var warmupEvaluationCountSum: Int = 0
        for _ in 0..<warmupIterations {
            let projected = MetricScanProjection().project(profile)
            warmupProjectionCountSum += projected.count
            let evalResult = try evaluate()
            warmupEvaluationCountSum += evalResult.count
        }
        withExtendedLifetime(warmupProjectionCountSum) {}
        withExtendedLifetime(warmupEvaluationCountSum) {}
        
        // Gemessene Durchläufe
        var projectionSamples: [Double] = []
        var combinedSamples: [Double] = []
        var measuredProjectionCountSum: Int = 0
        var measuredEvaluationCountSum: Int = 0
        
        for _ in 0..<measuredIterations {
            // 1. Projektion messen
            let projectionStart = DispatchTime.now().uptimeNanoseconds
            let projected = MetricScanProjection().project(profile)
            let projectionEnd = DispatchTime.now().uptimeNanoseconds
            let projectionNanos = Double(projectionEnd - projectionStart)
            projectionSamples.append(projectionNanos)
            measuredProjectionCountSum += projected.count
            
            // 2. Evaluator messen (kombinierte Laufzeit)
            let evalStart = DispatchTime.now().uptimeNanoseconds
            let evaluations = try evaluate()
            let evalEnd = DispatchTime.now().uptimeNanoseconds
            let evalNanos = Double(evalEnd - evalStart)
            combinedSamples.append(evalNanos)
            measuredEvaluationCountSum += evaluations.count
            
            // Prüfsumme außerhalb der Zeitfenster berechnen
            let currentChecksum = PolarBenchmarkChecksum.value(of: evaluations)
            if currentChecksum != referenceChecksum {
                throw PolarBenchmarkError.unstableChecksum(
                    scenarioLabel: scenario.label,
                    expected: referenceChecksum,
                    found: currentChecksum
                )
            }
        }
        
        // Akkumulatoren vor Wegoptimierung schützen
        withExtendedLifetime(measuredProjectionCountSum) {}
        withExtendedLifetime(measuredEvaluationCountSum) {}
        
        // EvaluationDifference: max(0, kombiniert - projektion)
        let evaluationDifferenceSamples = zip(combinedSamples, projectionSamples).map {
            max(0, $0 - $1)
        }
        
        let projectionStats = PolarBenchmarkDurationStatistics(samplesNanoseconds: projectionSamples)
        let combinedStats = PolarBenchmarkDurationStatistics(samplesNanoseconds: combinedSamples)
        let evaluationDifferenceStats = PolarBenchmarkDurationStatistics(samplesNanoseconds: evaluationDifferenceSamples)
        
        return PolarBenchmarkMeasurement(
            scenario: scenario,
            projection: projectionStats,
            evaluationDifference: evaluationDifferenceStats,
            combined: combinedStats,
            evaluationCount: evaluationCount,
            checksum: referenceChecksum
        )
    }

    public func run(_ scenarios: [PolarBenchmarkScenario]) throws -> [PolarBenchmarkMeasurement] {
        try scenarios.map { try run($0) }
    }
}
