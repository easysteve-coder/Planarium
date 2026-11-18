//
//  PolarBenchmarkScenarioTests.swift
//
import XCTest
@testable import SickPolarBenchmark
import SickPLSCore
import SickPLSMonitorKit

final class PolarBenchmarkScenarioTests: XCTestCase {

    private let factory = PolarBenchmarkScenarioFactory()

    // MARK: - 1. Determinismus von profile(for:)

    func testProfileDeterministicSameSeed() throws {
        let scenario = PolarBenchmarkScenario(
            sectorCount: 10,
            routingCount: 2,
            pointCount: 90,
            seed: 0x9E3779B97F4A7C15
        )

        let profile1 = try factory.profile(for: scenario)
        let profile2 = try factory.profile(for: scenario)

        XCTAssertEqual(profile1.measurements, profile2.measurements)
    }

    // MARK: - 2. Determinismus von sectors(for:)

    func testSectorsDeterministicFor100() {
        let scenario = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 0
        )

        let sectors1 = factory.sectors(for: scenario)
        let sectors2 = factory.sectors(for: scenario)

        XCTAssertEqual(sectors1.count, 100)
        XCTAssertEqual(sectors2.count, 100)
        XCTAssertEqual(sectors1, sectors2)

        let uniqueCells = Set(sectors1)
        XCTAssertEqual(uniqueCells.count, 100)
    }

    func testSectorsDeterministicFor1000() {
        let scenario = PolarBenchmarkScenario(
            sectorCount: 1000,
            routingCount: 0
        )

        let sectors1 = factory.sectors(for: scenario)
        let sectors2 = factory.sectors(for: scenario)

        XCTAssertEqual(sectors1.count, 1000)
        XCTAssertEqual(sectors2.count, 1000)
        XCTAssertEqual(sectors1, sectors2)

        let uniqueCells = Set(sectors1)
        XCTAssertEqual(uniqueCells.count, 1000)
    }

    // MARK: - 3. Workspace-Prüfung

    func testWorkspaceStructure() {
        let scenario = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 4
        )

        let workspace = factory.workspace(for: scenario)

        XCTAssertEqual(workspace.coordinateMode, .polar)
        XCTAssertEqual(workspace.layers.count, scenario.routingCount)
        let layer = workspace.layers[0]

        XCTAssertEqual(layer.polarCells.count, scenario.sectorCount)
        XCTAssertEqual(layer.routings.count, 1)

        let workspace2 = factory.workspace(for: scenario)
        XCTAssertEqual(workspace.layers.flatMap { $0.routings.map { $0.id } },
                       workspace2.layers.flatMap { $0.routings.map { $0.id } })
    }

    // MARK: - 4. Gegenprobe über den echten Produktpfad

    func testEvaluatorWithEmptyProfile() throws {
        let scenario = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 4
        )

        let emptyProfile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: []
        )
        let workspace = factory.workspace(for: scenario)

        let evaluations = try PreparedPolarBenchmark(profile: emptyProfile, workspace: workspace).evaluate()

        XCTAssertEqual(evaluations[1].value, .inactive, "Routing 1 (.continuous) should be inactive")
        XCTAssertEqual(evaluations[3].value, .inactive, "Routing 3 (.constant) should be inactive")
    }

    // MARK: - 5. Neue Gegenproben gegen K1/K2

    func testProfileHas90MeasurementsInRange() throws {
        let scenario = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 4,
            pointCount: 90,
            seed: 0x9E3779B97F4A7C15
        )

        let profile = try factory.profile(for: scenario)

        XCTAssertEqual(profile.measurements.count, 90, "profile must contain exactly 90 measurements")
        for measurement in profile.measurements {
            // B0ScanProfile.Measurement value is in centimeters, range 50..1500 per factory
            XCTAssertGreaterThanOrEqual(measurement.value, 50)
            XCTAssertLessThanOrEqual(measurement.value, 1500)
        }
    }

    func testChecksumDiffersForDifferentSectorCounts() throws {

        let scenario100 = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 4,
            pointCount: 90,
            seed: 0x9E3779B97F4A7C15
        )
        let profile100 = try factory.profile(for: scenario100)
        let workspace100 = factory.workspace(for: scenario100)
        let evaluations100 = try PreparedPolarBenchmark(profile: profile100, workspace: workspace100).evaluate()
        let checksum100 = PolarBenchmarkChecksum.value(of: evaluations100)

        let scenario5000 = PolarBenchmarkScenario(
            sectorCount: 5000,
            routingCount: 4,
            pointCount: 90,
            seed: 0x9E3779B97F4A7C15
        )
        let profile5000 = try factory.profile(for: scenario5000)
        let workspace5000 = factory.workspace(for: scenario5000)
        let evaluations5000 = try PreparedPolarBenchmark(profile: profile5000, workspace: workspace5000).evaluate()
        let checksum5000 = PolarBenchmarkChecksum.value(of: evaluations5000)

        XCTAssertNotEqual(
            checksum100, checksum5000,
            "Checksums must differ for sectorCount 100 vs 5000 with pointCount 90"
        )
    }

    func testNonEmptyEvaluationWith90Points() throws {
        let scenario = PolarBenchmarkScenario(
            sectorCount: 100,
            routingCount: 4,
            pointCount: 90,
            seed: 0x9E3779B97F4A7C15
        )

        let profile = try factory.profile(for: scenario)
        let workspace = factory.workspace(for: scenario)

        let evaluations = try PreparedPolarBenchmark(profile: profile, workspace: workspace).evaluate()

        // At least one evaluation must be active (not .inactive)
        let hasActiveEvaluation = evaluations.contains { eval in
            if case .inactive = eval.value {
                return false
            }
            return true
        }
        XCTAssertTrue(hasActiveEvaluation, "At least one evaluation must be active with 90 points")

        // With 90 points and 100 sectors, at least one evaluation should be active
        // and the profile should have measurements
        XCTAssertEqual(profile.measurements.count, 90, "Profile must have 90 measurements")
    }
}
