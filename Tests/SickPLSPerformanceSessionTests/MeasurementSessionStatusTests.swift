import PlanariumInput
import Foundation
import XCTest
import SickPLSCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// Die redigierte Kurzlage der RX-Sitzung und die Evidenzzahlen des
/// Koordinators (SICK-0330b).
@MainActor final class MeasurementSessionStatusTests: XCTestCase {

    private func profile(points: Int) throws -> B0ScanProfile {
        let bytes = try b0FrameBytes(measurements: Array(repeating: 1500, count: points))
        var parser = StreamParser()
        let frames = parser.feed(bytes)
        return try XCTUnwrap(ScanSessionState.decodedProfiles(in: frames).first)
    }

    func testEveryConnectionStatusMapsToItsOwnSummary() throws {
        XCTAssertEqual(MeasurementSessionStatus.describing(ScanSessionState()), .idle)

        let connecting = ScanSessionState.applyingConnecting(portPath: "/dev/cu.x", baudRate: .baud38400)
        XCTAssertEqual(MeasurementSessionStatus.describing(connecting), .opening(portPath: "/dev/cu.x"))

        let open = connecting.applyingConnected(portPath: "/dev/cu.x", baudRate: .baud38400)
        XCTAssertEqual(MeasurementSessionStatus.describing(open), .openWithoutProfile(portPath: "/dev/cu.x"),
                       "Ein offener Port ist kein Betriebsbeleg")

        let now = Date()
        let streaming = open
            .applyingProfiles([try profile(points: 90)], diagnostics: StreamParser.Diagnostics(), receivedAt: now)
            .applyingProfiles([try profile(points: 90)], diagnostics: StreamParser.Diagnostics(), receivedAt: now.addingTimeInterval(0.08))
        guard case .streaming(let port, let points) = MeasurementSessionStatus.describing(streaming) else {
            return XCTFail("Nach einem Profil muss der Strom als solcher erscheinen")
        }
        XCTAssertEqual(port, "/dev/cu.x")
        XCTAssertEqual(points, 90)
        XCTAssertEqual(try XCTUnwrap(streaming.profileRateHz), 12.5, accuracy: 0.01)

        let lost = streaming.applyingStreamEnded(portPath: "/dev/cu.x", baudRate: .baud38400, unexpectedly: true)
        XCTAssertEqual(
            MeasurementSessionStatus.describing(lost),
            .failed(portPath: "/dev/cu.x", message: "Connection ended unexpectedly (end of stream).")
        )
    }

    func testTheCoordinatorEvidenceCountsReadsAndDroppedProfiles() throws {
        let twoProfilesInOneRead = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
            + b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = CoordinatorHarness(descriptors: [
            FakeSerialPortFileDescriptor(readScript: [
                .bytes(twoProfilesInOneRead),
                .bytes(try b0FrameBytes(measurements: profileMeasurements(value: 3000))),
                .timeout, .timeout, .timeout, .timeout, .timeout, .timeout
            ])
        ])
        harness.coordinator.connect(portPath: "/dev/cu.usbserial-TEST", baudRate: .baud38400)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }

        let evidence = harness.coordinator.measurementStreamEvidence
        XCTAssertEqual(evidence.deliveredProfileBatches, 2)
        XCTAssertEqual(evidence.readsWithSeveralProfiles, 1)
        XCTAssertEqual(evidence.validFrames, 3)
        guard case .streaming(_, let points) = evidence.status else {
            return XCTFail("Der Strom steht")
        }
        XCTAssertEqual(points, 10)

        harness.coordinator.disconnect()
        waitUntil { harness.coordinator.portOwner == .free }
    }

    func testStatusChangesArePublishedWithoutASecondSessionSubscription() {
        let harness = CoordinatorHarness(descriptors: [
            FakeSerialPortFileDescriptor(readScript: Array(repeating: .timeout, count: 10))
        ])
        var seen: [MeasurementSessionStatus] = []
        let subscription = harness.coordinator.measurementSessionStatusChanges.sink { seen.append($0) }
        defer { subscription.cancel() }

        harness.coordinator.connect(portPath: "/dev/cu.usbserial-TEST", baudRate: .baud38400)
        waitUntil { seen.contains(.openWithoutProfile(portPath: "/dev/cu.usbserial-TEST")) }
        XCTAssertEqual(seen.first, .idle)
        XCTAssertTrue(seen.contains(.opening(portPath: "/dev/cu.usbserial-TEST")))
        XCTAssertTrue(harness.coordinator.hasActiveProfileSubscription)

        harness.coordinator.disconnect()
        waitUntil { harness.coordinator.portOwner == .free }
        XCTAssertEqual(seen.last, .idle)
    }
}
