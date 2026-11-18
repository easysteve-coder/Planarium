import PlanariumInput
import Foundation
import Combine
import XCTest
import SickPLSCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

@MainActor final class CoordinatorReferenceMeasurementTests: XCTestCase {
    func testT3FiftyProfilesWithoutLearningOrMeasurementDoNotPublishCoordinatorChanges() throws {
        let frame = try profileFrame(value: 1000, count: 361)
        let harness = harness(
            reading: (0..<50).flatMap { _ in [.bytes(frame), .timeout] }
                + Array(repeating: .timeout, count: 20)
        )
        var objectWillChangeCount = 0
        let subscription = harness.coordinator.objectWillChange.sink { _ in
            objectWillChangeCount += 1
        }
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil {
            if case .connected = harness.coordinator.session.state.connection { return true }
            return false
        }
        objectWillChangeCount = 0
        waitUntil { harness.coordinator.deliveredProfileBatches == 50 }
        XCTAssertEqual(objectWillChangeCount, 0)
        withExtendedLifetime(subscription) {}
        harness.coordinator.disconnect()
    }
    private func harness(reading script: [SerialPortReadOutcome]) -> CoordinatorHarness {
        CoordinatorHarness(
            descriptors: [FakeSerialPortFileDescriptor(readScript: script)]
        )
    }

    private func profileFrame(value: UInt16, count: Int = 10) throws -> [UInt8] {
        try b0FrameBytes(measurements: Array(repeating: value, count: count))
    }

    private func deliver(
        _ harness: CoordinatorHarness,
        frames: [[UInt8]]
    ) {
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == frames.count }
    }

    func testTheExistingSingleProfileSubscriptionRemainsTheOnlyOne() {
        let harness = harness(reading: Array(repeating: .timeout, count: 20))
        XCTAssertTrue(harness.coordinator.hasActiveProfileSubscription)
    }

    func testAProfileBeforeStartReachesAudioButNotReferenceStatistics() throws {
        let frame = try profileFrame(value: 3000, count: 361)
        let harness = harness(reading: [.bytes(frame)] + Array(repeating: .timeout, count: 20))

        deliver(harness, frames: [frame])

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 1)
        XCTAssertNil(harness.coordinator.referenceMeasurement.statistics)
        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 180)
        harness.coordinator.disconnect()
    }

    func testTheFirstProfileChoosesItsMiddleWhenNoIndexWasSelected() throws {
        let cases = [(90, 45), (180, 90), (361, 180)]
        for (count, expectedIndex) in cases {
            let frame = try profileFrame(value: 3000, count: count)
            let harness = harness(reading: [.bytes(frame)] + Array(repeating: .timeout, count: 20))

            deliver(harness, frames: [frame])

            XCTAssertEqual(
                harness.coordinator.referenceMeasurement.selectedIndex,
                expectedIndex,
                "Profilmitte für (count) Punkte"
            )
            harness.coordinator.disconnect()
        }
    }

    func testThreeProfilesThroughReceiveProduceThreeReferenceSamples() throws {
        let frames = try [100, 200, 300].map { try profileFrame(value: UInt16($0)) }
        let harness = harness(
            reading: frames.map(SerialPortReadOutcome.bytes) + Array(repeating: .timeout, count: 40)
        )
        harness.coordinator.startReferenceMeasurement()

        deliver(harness, frames: frames)

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 3)
        XCTAssertEqual(harness.coordinator.referenceMeasurement.statistics?.sampleCount, 3)
        harness.coordinator.disconnect()
    }

    func testStoppingLeavesTheExistingSeriesUnchanged() throws {
        let first = try profileFrame(value: 100)
        let second = try profileFrame(value: 200)
        let harness = harness(
            reading: [.bytes(first)] + Array(repeating: .timeout, count: 20)
                + [.bytes(second)] + Array(repeating: .timeout, count: 30)
        )
        harness.coordinator.startReferenceMeasurement()
        deliver(harness, frames: [first])
        harness.coordinator.stopReferenceMeasurement()
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 2)
        XCTAssertEqual(harness.coordinator.referenceMeasurement.statistics?.sampleCount, 1)
        XCTAssertFalse(harness.coordinator.referenceMeasurement.isRunning)
        harness.coordinator.disconnect()
    }

    func testChangingIndexWhileRunningDiscardsTheOldSeries() throws {
        let first = try profileFrame(value: 100)
        let second = try profileFrame(value: 200)
        let harness = harness(
            reading: [.bytes(first)] + Array(repeating: .timeout, count: 20)
                + [.bytes(second)] + Array(repeating: .timeout, count: 30)
        )
        try harness.coordinator.selectReferenceIndex(0)
        harness.coordinator.startReferenceMeasurement()
        deliver(harness, frames: [first])
        try harness.coordinator.selectReferenceIndex(1)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }

        XCTAssertEqual(harness.coordinator.referenceMeasurement.statistics?.sampleCount, 1)
        XCTAssertEqual(harness.coordinator.referenceMeasurement.statistics?.index, 1)
        XCTAssertTrue(harness.coordinator.referenceMeasurement.isRunning)
        harness.coordinator.disconnect()
    }

    func testAProfileWithoutTheSelectedIndexIsCounted() throws {
        let frame = try profileFrame(value: 3000, count: 90)
        let harness = harness(reading: [.bytes(frame)] + Array(repeating: .timeout, count: 20))
        try harness.coordinator.selectReferenceIndex(180)
        harness.coordinator.startReferenceMeasurement()

        deliver(harness, frames: [frame])

        XCTAssertNil(harness.coordinator.referenceMeasurement.statistics)
        XCTAssertEqual(harness.coordinator.referenceMeasurement.profilesWithoutIndex, 1)
        harness.coordinator.disconnect()
    }

    func testInvalidIndexIsRejectedAndTheMaximumIsAccepted() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 20))
        XCTAssertThrowsError(try harness.coordinator.selectReferenceIndex(referenceIndexMaximum + 1))
        XCTAssertNoThrow(try harness.coordinator.selectReferenceIndex(referenceIndexMaximum))
        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, referenceIndexMaximum)
    }

    func testPresentationDistinguishesTheThreeReferenceStates() throws {
        var model = try ReferenceMeasurementModel(index: 0)
        let idle = ReferenceMeasurementPresentation.describe(model)
        model.start()
        let runningWithoutValue = ReferenceMeasurementPresentation.describe(model)
        model.record(try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: [try B0ScanProfile.Measurement.build(value: 123, fieldFlags: 0)]
        ))
        let runningWithValue = ReferenceMeasurementPresentation.describe(model)

        XCTAssertNotEqual(idle, runningWithoutValue)
        XCTAssertNotEqual(runningWithoutValue, runningWithValue)
        XCTAssertNotEqual(idle, runningWithValue)
        XCTAssertTrue(runningWithValue.contains("Reference index 0:"))
    }

    func testPresentationExhaustivelyDistinguishesTheFourReachableReferenceStates() throws {
        let idleHarness = harness(reading: Array(repeating: .timeout, count: 20))
        idleHarness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        idleHarness.coordinator.disconnect()
        let idle = ReferenceMeasurementPresentation.describe(idleHarness.coordinator.referenceMeasurement)

        let waitingHarness = harness(reading: Array(repeating: .timeout, count: 20))
        waitingHarness.coordinator.startReferenceMeasurement()
        let waiting = ReferenceMeasurementPresentation.describe(waitingHarness.coordinator.referenceMeasurement)
        waitingHarness.coordinator.stopReferenceMeasurement()

        let runningFrame = try profileFrame(value: 1234)
        let runningHarness = harness(
            reading: [.bytes(runningFrame)] + Array(repeating: .timeout, count: 20)
        )
        runningHarness.coordinator.startReferenceMeasurement()
        runningHarness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { runningHarness.coordinator.deliveredProfileBatches == 1 }
        let running = ReferenceMeasurementPresentation.describe(runningHarness.coordinator.referenceMeasurement)
        runningHarness.coordinator.disconnect()

        let stoppedFrame = try profileFrame(value: 2345)
        let stoppedDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(stoppedFrame)] + Array(repeating: .timeout, count: 20)
        )
        let stoppedHarness = CoordinatorHarness(descriptors: [stoppedDescriptor])
        stoppedHarness.coordinator.startReferenceMeasurement()
        stoppedHarness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { stoppedHarness.coordinator.deliveredProfileBatches == 1 }
        stoppedHarness.coordinator.disconnect()
        waitUntil { stoppedDescriptor.closeCallCount == 1 }
        waitUntil { stoppedHarness.coordinator.portOwner == .free }
        let stopped = ReferenceMeasurementPresentation.describe(stoppedHarness.coordinator.referenceMeasurement)

        let texts = [idle, waiting, running, stopped]
        XCTAssertEqual(Set(texts).count, 4, "Alle vier echten Zustände brauchen eigene Texte.")
        XCTAssertTrue(stopped.contains("Reference measurement: stopped"))
        XCTAssertTrue(stopped.contains("Reference index 5:"))
    }

    func testReferenceRecordingIsTextuallyAfterAudioAndLearning() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PlanariumScannerUI/ScannerWorkspaceModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let audio = try XCTUnwrap(source.range(of: "deliveredProfileBatches += 1"))
        let learning = try XCTUnwrap(source.range(of: "editorState.ingestLearningProfile(batch.profile)"))
        let reference = try XCTUnwrap(source.range(of: "referenceMeasurement.record(batch.profile)"))

        XCTAssertLessThan(audio.lowerBound, learning.lowerBound)
        XCTAssertLessThan(learning.lowerBound, reference.lowerBound)
    }

    func testAReconnectDeterminesTheMiddleAgainForTheNewProfileSize() throws {
        let first = try profileFrame(value: 1000, count: 180)
        let second = try profileFrame(value: 2000, count: 361)
        let firstDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(first)] + Array(repeating: .timeout, count: 20)
        )
        let secondDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(second)] + Array(repeating: .timeout, count: 20)
        )
        let harness = CoordinatorHarness(descriptors: [firstDescriptor, secondDescriptor])
        harness.coordinator.startReferenceMeasurement()

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 1 }
        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 90)
        harness.coordinator.disconnect()
        waitUntil { firstDescriptor.closeCallCount == 1 }
        pumpMainLoop(seconds: 0.1)

        harness.coordinator.startReferenceMeasurement()
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }

        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 180)
        harness.coordinator.disconnect()
    }

    func testAReadFailureStopsTheSeriesWithoutExplicitDisconnect() throws {
        let first = try profileFrame(value: 1000, count: 180)
        let second = try profileFrame(value: 1100, count: 180)
        let third = try profileFrame(value: 2000, count: 180)
        let fourth = try profileFrame(value: 2100, count: 180)
        let firstDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(first), .bytes(second)] + Array(repeating: .timeout, count: 5) + [.closed]
        )
        let secondDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(third), .bytes(fourth)] + Array(repeating: .timeout, count: 5) + [.closed]
        )
        let harness = CoordinatorHarness(descriptors: [firstDescriptor, secondDescriptor])
        harness.coordinator.startReferenceMeasurement()

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }
        waitUntil { firstDescriptor.closeCallCount == 1 }
        waitUntil { harness.coordinator.portOwner == .free }
        XCTAssertFalse(harness.coordinator.referenceMeasurement.isRunning)
        XCTAssertEqual(harness.coordinator.referenceMeasurement.statistics?.sampleCount, 2)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 4 }

        XCTAssertFalse(harness.coordinator.referenceMeasurement.isRunning)
        XCTAssertEqual(harness.coordinator.referenceMeasurement.statistics?.sampleCount, 2)
    }

    func testAnExplicitIndexSurvivesAReconnectAndIsNotReplacedByTheMiddle() throws {
        let first = try profileFrame(value: 1000, count: 361)
        let second = try profileFrame(value: 2000, count: 361)
        let firstDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(first)] + Array(repeating: .timeout, count: 20)
        )
        let secondDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(second)] + Array(repeating: .timeout, count: 20)
        )
        let harness = CoordinatorHarness(descriptors: [firstDescriptor, secondDescriptor])
        try harness.coordinator.selectReferenceIndex(300)
        harness.coordinator.startReferenceMeasurement()

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 1 }
        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 300)
        harness.coordinator.disconnect()
        waitUntil { firstDescriptor.closeCallCount == 1 }
        pumpMainLoop(seconds: 0.1)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }

        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 300)
        XCTAssertNotEqual(harness.coordinator.referenceMeasurement.selectedIndex, 180)
        harness.coordinator.disconnect()
    }

    func testDifferentProfileSizeWithoutRestartChangesIndexAndDiscardsStatistics() throws {
        let first = try profileFrame(value: 1000, count: 180)
        let second = try profileFrame(value: 2000, count: 361)
        let firstDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(first)] + Array(repeating: .timeout, count: 20)
        )
        let secondDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(second)] + Array(repeating: .timeout, count: 20)
        )
        let harness = CoordinatorHarness(descriptors: [firstDescriptor, secondDescriptor])
        harness.coordinator.startReferenceMeasurement()

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 1 }
        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 90)
        XCTAssertEqual(harness.coordinator.referenceMeasurement.statistics?.sampleCount, 1)
        harness.coordinator.disconnect()
        waitUntil { firstDescriptor.closeCallCount == 1 }
        waitUntil { harness.coordinator.portOwner == .free }

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }

        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 180)
        XCTAssertNil(
            harness.coordinator.referenceMeasurement.statistics,
            "Andere Profilgröße verwirft die alte Reihe absichtlich."
        )
        harness.coordinator.disconnect()
    }

    func testSameProfileSizeWithoutRestartKeepsTheVisibleStatistics() throws {
        let first = try profileFrame(value: 1000, count: 180)
        let second = try profileFrame(value: 1100, count: 180)
        let third = try profileFrame(value: 1200, count: 180)
        let firstDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(first), .bytes(second)] + Array(repeating: .timeout, count: 20)
        )
        let secondDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(third)] + Array(repeating: .timeout, count: 20)
        )
        let harness = CoordinatorHarness(descriptors: [firstDescriptor, secondDescriptor])
        harness.coordinator.startReferenceMeasurement()

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }
        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 90)
        XCTAssertEqual(harness.coordinator.referenceMeasurement.statistics?.sampleCount, 2)
        harness.coordinator.disconnect()
        waitUntil { firstDescriptor.closeCallCount == 1 }
        waitUntil { harness.coordinator.portOwner == .free }

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 3 }

        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 90)
        XCTAssertEqual(harness.coordinator.referenceMeasurement.statistics?.sampleCount, 2)
        harness.coordinator.disconnect()
    }

    func testExplicitIndexSurvivesDifferentProfileSizesWithoutRestart() throws {
        let first = try profileFrame(value: 1000, count: 361)
        let second = try profileFrame(value: 2000, count: 180)
        let firstDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(first)] + Array(repeating: .timeout, count: 20)
        )
        let secondDescriptor = FakeSerialPortFileDescriptor(
            readScript: [.bytes(second)] + Array(repeating: .timeout, count: 20)
        )
        let harness = CoordinatorHarness(descriptors: [firstDescriptor, secondDescriptor])
        try harness.coordinator.selectReferenceIndex(300)
        harness.coordinator.startReferenceMeasurement()

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 1 }
        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 300)
        harness.coordinator.disconnect()
        waitUntil { firstDescriptor.closeCallCount == 1 }
        waitUntil { harness.coordinator.portOwner == .free }

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 2 }

        XCTAssertEqual(harness.coordinator.referenceMeasurement.selectedIndex, 300)
        harness.coordinator.disconnect()
    }
}
