import XCTest
import SickPLSControlCore
import SickPLSCore
@testable import PlanariumDomain

final class CompiledBudgetSmokeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        CompiledBudgetScenarioFixtures.prewarm()
    }

    func testEveryScenarioCompilesWithIndependentLiteralStatistics() throws {
        for scenario in CompiledBudgetScenarioFixtures.all {
            let compiled = CompiledBudgetScenarioFixtures.compiled(for: scenario)
            XCTAssertEqual(compiled.statistics.compiledLayerCount, scenario.expectedLayerCount, scenario.name)
            XCTAssertEqual(compiled.statistics.indexedAddressCount, scenario.expectedIndexedAddressCount, scenario.name)
            XCTAssertEqual(compiled.statistics.maxEntriesPerTick, scenario.expectedMaxEntriesPerTick, scenario.name)
            XCTAssertEqual(compiled.statistics.routingPlanCount, scenario.expectedRoutingPlanCount, scenario.name)
            XCTAssertEqual(compiled.statistics.estimatedIndexBytes, scenario.expectedEstimatedIndexBytes, scenario.name)
        }
    }

    func testTenProfilesAskTheIndexOncePerUsableMeasurementAndSelectExpectedLayers() throws {
        for scenario in CompiledBudgetScenarioFixtures.all {
            let usable = try CompiledBudgetScenarioFixtures.usableHandMeasurements(
                ticks: scenario.name == "S2 Spalte" ? 170..<190 : 0..<20)
            let compiled = CompiledBudgetScenarioFixtures.compiled(for: scenario)
            var selector = DeviceLatticeSelector()
            var result = DeviceLatticeSelection(activeHandles: [:], candidateDistancesCentimeters: [:])
            for _ in 0..<10 {
                result = selector.step(
                    measurements: usable, instrument: compiled,
                    geometry: .fullScan361, configuration: .disabled)
            }
            XCTAssertEqual(selector.indexRequestCount, 200, scenario.name)
            let expectedActiveLayers = scenario.name == "S1 voll" ? 256
                : scenario.name == "S2 Spalte" ? 20 : 0
            XCTAssertEqual(result.activeHandles.count, expectedActiveLayers, scenario.name)

            XCTAssertTrue(selector.step(
                measurements: [], instrument: compiled,
                geometry: .fullScan361, configuration: .disabled).isEmpty)
            let unusable = try CompiledBudgetScenarioFixtures.unusableProfile()
            XCTAssertTrue(selector.step(
                measurements: try FullScanProfileAdapter.measurements(from: unusable), instrument: compiled, geometry: .fullScan361,
                configuration: .disabled).isEmpty)
        }
    }

    func testColumnMeasuredHitsStayWithinCeilingOfBinarySearchDepth() throws {
        let scenario = CompiledBudgetScenarioFixtures.column
        let compiled = CompiledBudgetScenarioFixtures.compiled(for: scenario)
        let measured = compiled.measuredHits(tick: 180, raw: 80)
        let ceiling = Int(ceil(log2(Double(scenario.expectedMaxEntriesPerTick + 1))))
        XCTAssertEqual(measured.visitedEntries, 20)
        XCTAssertLessThanOrEqual(measured.comparisons, ceiling)
    }

    func testAddressAndRoutingBudgetRejectThePoisonedLastElement() throws {
        XCTAssertThrowsError(try CompiledBudgetScenarioFixtures.documentWithOneExtraAddress(
            in: CompiledBudgetScenarioFixtures.full)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.addressesPerDocument))
        }
        XCTAssertThrowsError(try CompiledBudgetScenarioFixtures.documentWithOneExtraRouting(
            in: CompiledBudgetScenarioFixtures.empty)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.routings))
        }
    }

    func testProfilesAreConstructedWithExpectedShapesAndNoProductionCallers() throws {
        XCTAssertEqual(try CompiledBudgetScenarioFixtures.handProfile().measurements.count, 361)
        XCTAssertEqual(try CompiledBudgetScenarioFixtures.handProfile().measurements.filter {
            $0.value == 80
        }.count, 20)
        XCTAssertEqual(try CompiledBudgetScenarioFixtures.emptyProfile().measurements.count, 0)
        XCTAssertEqual(try CompiledBudgetScenarioFixtures.unusableProfile().measurements.filter {
            $0.value != 8191
        }.count, 0)

        for path in ["Sources/SickPLSMonitor", "Sources/PlanariumPresets"] {
            for file in try FileManager.default.subpathsOfDirectory(atPath: path) where file.hasSuffix(".swift") {
                let source = try String(contentsOfFile: "\(path)/\(file)", encoding: .utf8)
                XCTAssertFalse(source.contains("CompiledBudgetScenarioFixtures"), "\(path)/\(file)")
            }
        }
    }

    func testHandMeasurementsUseTheProductionProfileAdapter() throws {
        let path = "Tests/PlanariumDomainTests/CompiledBudgetScenarioFixtures.swift"
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(source.contains("FullScanProfileAdapter.measurements(from: profile)"))
        XCTAssertFalse(source.contains("profile.measurements.enumerated().compactMap"))
    }
}
