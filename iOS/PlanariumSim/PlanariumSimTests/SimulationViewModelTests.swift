import XCTest
import SickPLSDeviceModel
@testable import PlanariumSim

final class SimulationViewModelTests: XCTestCase {
    func testProductionSimulationDefaultsTo361SingleRays() {
        let suite = "FullScanDefault-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SimulationViewModel(defaults: defaults)
        XCTAssertEqual(model.pointCount, 361)
        XCTAssertEqual(model.sampling, .singleRay)
    }
    func testDeviceModeTextUsesThePublishedLabels() {
        XCTAssertEqual(SimulationViewModel.deviceModeText(for: .idle), "Bereit")
        XCTAssertEqual(SimulationViewModel.deviceModeText(for: .fullScan), "Alle Messwerte kontinuierlich")
        XCTAssertEqual(SimulationViewModel.deviceModeText(for: .minimumPerSegmentRequested), "Messwerte min. kontinuierlich – nicht nachgebildet, sendet keine Profile")
    }

    func testNeedsDisplayTickDecisionMatrix() {
        XCTAssertFalse(SimulationViewModel.needsDisplayTick(isRunning: false, isConnected: false, mode: .idle))
        XCTAssertFalse(SimulationViewModel.needsDisplayTick(isRunning: false, isConnected: true, mode: .fullScan))
        XCTAssertTrue(SimulationViewModel.needsDisplayTick(isRunning: true, isConnected: false, mode: .idle))
        XCTAssertFalse(SimulationViewModel.needsDisplayTick(isRunning: true, isConnected: true, mode: .idle))
        XCTAssertFalse(SimulationViewModel.needsDisplayTick(isRunning: true, isConnected: true, mode: .fullScan))
        XCTAssertTrue(SimulationViewModel.needsDisplayTick(isRunning: true, isConnected: true, mode: .minimumPerSegmentRequested))
    }

    func testRoomBackgroundDefaultsOnAndPersistsAnExplicitOff() {
        let suiteName = "PlanariumSimTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let fresh = SimulationViewModel(defaults: defaults)
        XCTAssertTrue(fresh.roomBackground)

        fresh.roomBackground = false
        let restored = SimulationViewModel(defaults: defaults)
        XCTAssertFalse(restored.roomBackground)
    }
}
