import PlanariumInput
import XCTest
import SickPLSCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// Der eigentliche Nachweis dieses Slices (SICK-029): Ein echtes
/// B0-Profil erreicht die Klangerzeugung **modellseitig** — ohne
/// SwiftUI-Ansicht, ohne Fenster, ohne Renderdurchlauf.
///
/// Die Profile laufen hier durch die **echte** `RXSession` mit echtem
/// Hintergrund-Thread, echtem `StreamParser` und echtem
/// `B0ScanProfile.decode`; gefälscht ist allein der Dateideskriptor.
@MainActor final class CoordinatorProfileDeliveryTests: XCTestCase {

    private func harness(reading script: [SerialPortReadOutcome]) -> CoordinatorHarness {
        CoordinatorHarness(
            descriptors: [FakeSerialPortFileDescriptor(readScript: script)]
        )
    }

    // MARK: - Ein Profil, genau einmal

    func testASingleB0ProfileReachesTheControllerExactlyOnceWithoutAnyView() throws {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = harness(
            reading: [.bytes(bytes)] + Array(repeating: .timeout, count: 50)
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 1 }

        // Nachlaufen lassen: Es darf **kein zweites Mal** ankommen.
        pumpMainLoop()
        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 1)
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.count, 1)
        XCTAssertEqual(harness.coordinator.readsWithSeveralProfiles, 0)

        harness.coordinator.disconnect()
    }

    /// Die Monitoranzeige bleibt unberührt — sie ist ein zweiter,
    /// unabhängiger Empfänger desselben Lesevorgangs.
    func testTheMonitorStateStillSeesTheProfileAsWell() throws {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = harness(
            reading: [.bytes(bytes)] + Array(repeating: .timeout, count: 50)
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 1 }

        XCTAssertEqual(harness.coordinator.session.state.lastProfile?.measurements.count, 10)
        XCTAssertEqual(harness.coordinator.session.state.diagnostics.validFrames, 1)

        harness.coordinator.disconnect()
    }

    // MARK: - Was kein Performance-Ereignis erzeugt

    func testPureNoiseProducesNoPerformanceEvent() {
        // Bytes, die nie einen gültigen Rahmen ergeben.
        let noise: [UInt8] = Array(repeating: 0x5A, count: 64)
        let harness = harness(
            reading: [.bytes(noise)] + Array(repeating: .timeout, count: 20)
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.diagnostics.skippedNoiseBytes > 0 }
        pumpMainLoop()

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 0)
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.count, 0)

        harness.coordinator.disconnect()
    }

    func testAValidNonB0FrameProducesNoPerformanceEvent() throws {
        let bytes = try nonB0FrameBytes()
        let harness = harness(
            reading: [.bytes(bytes)] + Array(repeating: .timeout, count: 20)
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        // Der Rahmen ist gültig — er zählt in der Diagnose, ergibt aber
        // kein Scanprofil.
        waitUntil { harness.coordinator.session.state.diagnostics.validFrames == 1 }
        pumpMainLoop()

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 0)
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.count, 0)
        XCTAssertNil(harness.coordinator.session.state.lastProfile)

        harness.coordinator.disconnect()
    }

    func testAReadWithoutAnyBytesProducesNoPerformanceEvent() {
        let harness = harness(reading: Array(repeating: .timeout, count: 20))

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.connection == .connected(portPath: "/dev/cu.fake", baudRate: .baud9600) }
        pumpMainLoop()

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 0)
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.count, 0)

        harness.coordinator.disconnect()
    }

    // MARK: - Mehrere Profile in einem Lesevorgang

    /// **Die bewusst offene Grenze, benannt statt versteckt.**
    ///
    /// Drei B0-Frames in *einem* Lesevorgang ergeben **ein**
    /// Performance-Ereignis mit dem **letzten** Profil — und der
    /// Koordinator zählt sichtbar mit, dass dabei frühere Profile
    /// verworfen wurden. Eine künstliche Zeitfolge für die früheren
    /// entsteht ausdrücklich nicht: Es gibt für sie keine belastbaren
    /// Einzelzeitstempel.
    func testSeveralProfilesInOneReadYieldExactlyTheLastOne() throws {
        let first = try b0FrameBytes(measurements: Array(repeating: 1000, count: 10))
        let second = try b0FrameBytes(measurements: Array(repeating: 2000, count: 10))
        let third = try b0FrameBytes(measurements: Array(repeating: 3000, count: 12))
        let harness = harness(
            reading: [.bytes(first + second + third)] + Array(repeating: .timeout, count: 50)
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 1 }
        pumpMainLoop()

        // Genau ein Ereignis, nicht drei.
        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 1)
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.count, 1)
        // Und es war das letzte: 12 Punkte statt 10.
        XCTAssertEqual(harness.coordinator.session.state.lastProfile?.measurements.count, 12)
        // Klar benannt, nicht verschwiegen.
        XCTAssertEqual(harness.coordinator.readsWithSeveralProfiles, 1)

        harness.coordinator.disconnect()
    }

    /// **Der Nachweis der Batch-Invariante ist umgezogen** (SICK-029a).
    ///
    /// Bis SICK-029 baute hier ein Test einen `ScanProfileBatch` direkt.
    /// Das geht nicht mehr: Sein Initialisierer ist seit SICK-029a
    /// modulintern, ein Batch entsteht ausschließlich in `RXSession`.
    /// Genau dort wird die Invariante jetzt geprüft
    /// (`RXSessionProfilePublisherTests`) — an ihrer Entstehungs-
    /// stelle statt an einem nachgebauten Wert.
    ///
    /// Was hier bleibt, ist die **Wirkung** des Zählwerts auf den
    /// Koordinator: Sie ist bereits in
    /// `testSeveralProfilesInOneReadYieldExactlyTheLastOne` und
    /// `testASingleB0ProfileReachesTheControllerExactlyOnceWithoutAnyView`
    /// belegt (`readsWithSeveralProfiles` `1` bzw. `0`).
    func testTheCoordinatorReadsTheDropFlagFromRealBatchesOnly() throws {
        let single = try b0FrameBytes(measurements: profileMeasurements(value: 1000))
        let harness = harness(
            reading: [.bytes(single)] + Array(repeating: .timeout, count: 50)
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 1 }

        // Ein echter Lesevorgang mit genau einem Profil verwirft nichts.
        XCTAssertEqual(harness.coordinator.readsWithSeveralProfiles, 0)

        harness.coordinator.disconnect()
    }

    // MARK: - Gate-Endzustand trotz zusammengefasstem Rückstau

    func testMainBacklogRetainsReadBatchesAndDisplaysFinalOutsideProfile() throws {
        let inside = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let outside = try b0FrameBytes(measurements: measurementsSeenByNoZone())
        let harness = harness(
            reading: [.bytes(inside), .timeout, .timeout, .bytes(outside)]
                + Array(repeating: .timeout, count: 50)
        )

        harness.coordinator.connect(portPath: "/dev/cu.perf1-gate-out", baudRate: .baud9600)
        Thread.sleep(forTimeInterval: 0.08)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }

        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.count, 2)
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.last, measurementsSeenByNoZone())
        XCTAssertEqual(harness.coordinator.session.state.skippedProfiles, 0)
        harness.coordinator.disconnect()
    }

    func testMainBacklogRetainsReadBatchesAndDisplaysFinalInsideProfile() throws {
        let outside = try b0FrameBytes(measurements: measurementsSeenByNoZone())
        let inside = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = harness(
            reading: [.bytes(outside), .timeout, .timeout, .bytes(inside)]
                + Array(repeating: .timeout, count: 50)
        )

        harness.coordinator.connect(portPath: "/dev/cu.perf1-gate-in", baudRate: .baud9600)
        Thread.sleep(forTimeInterval: 0.08)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }

        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.count, 2)
        XCTAssertEqual(harness.sessionDelivery.acceptedProfiles.last, profileMeasurements(value: 3000))
        XCTAssertEqual(harness.coordinator.session.state.skippedProfiles, 0)
        harness.coordinator.disconnect()
    }
}
