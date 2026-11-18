import PlanariumInput
import XCTest
import SickPLSControlCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// SICK-030b1 am **produktiven Weg**: echter Zoneneditor, echte
/// `RXSession` mit echtem Hintergrund-Thread, echter `StreamParser`,
/// echte Laufzeitbrücke — gefälscht sind nur Dateideskriptor und
/// Audiohost.
@MainActor final class CoordinatorZoneActivationTests: XCTestCase {

    private func harness(reading script: [SerialPortReadOutcome]) -> CoordinatorHarness {
        CoordinatorHarness(
            descriptors: [FakeSerialPortFileDescriptor(readScript: script)]
        )
    }

    // MARK: - Auflage A6 am ganzen Weg

    // MARK: - Spielbarkeit

    // MARK: - Nichts geschieht von selbst

    func testSwitchingAZoneNeverStartsAudio() {
        let harness = harness(reading: Array(repeating: .timeout, count: 20))

        harness.setZone(harness.pitchZoneID, isEnabled: false)
        harness.setZone(harness.pitchZoneID, isEnabled: true)
        harness.setZone(harness.gateZoneID, isEnabled: false)

        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertFalse(harness.engine.isRunning)
        XCTAssertTrue(harness.root.audio.status.isEmpty)
    }

}
