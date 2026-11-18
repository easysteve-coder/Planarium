import PlanariumInput
import XCTest
import SickPLSControlCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// SICK-030c, Auftragspunkt 8: Das Lernen bekommt **genau den schon
/// eintreffenden Batch** — kein zweites `RXSession`-Abonnement, kein
/// Timer, keine Parallelquelle.
///
/// Die Profile laufen hier durch die **echte** `RXSession` samt echtem
/// Hintergrund-Thread, echtem `StreamParser` und echtem
/// `B0ScanProfile.decode`; gefälscht sind nur Dateideskriptor und
/// Audiohost.
@MainActor final class CoordinatorZoneLearningTests: XCTestCase {

    private func harness(reading script: [SerialPortReadOutcome]) -> CoordinatorHarness {
        CoordinatorHarness(descriptors: [FakeSerialPortFileDescriptor(readScript: script)])
    }

    /// Ein Skript aus `count` identischen B0-Frames, danach Ruhe.
    private func script(profiles count: Int, value: UInt16) throws -> [SerialPortReadOutcome] {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: value))
        var script: [SerialPortReadOutcome] = []
        for _ in 0..<count {
            script.append(.bytes(bytes))
            script.append(.timeout)
        }
        return script + Array(repeating: .timeout, count: 60)
    }

    private func configuration() throws -> ZoneLearningConfiguration {
        try ZoneLearningConfiguration.build(
            baselineProfileCount: 2, minimumPersistenceProfiles: 1, minimumClusterPoints: 1,
            maximumIndexGap: 1, movementDelta: 40, indexPaddingPoints: 0,
            valuePadding: 20, backgroundClearance: 30, ambiguityToleranceFactor: 1.25
        )
    }

    private func armLearn(
        _ harness: CoordinatorHarness, on id: EditableZone.ID, configuration: ZoneLearningConfiguration
    ) {
        var state = harness.coordinator.editorState
        state.armLearn(zoneID: id, configuration: configuration)
        harness.coordinator.editorState = state
    }

    /// Eine zusätzliche, **deaktivierte** Zone als Lernziel — die drei
    /// Pflichtzonen des Prüfstands sind eingeschaltet und deshalb nach
    /// Auflage **D2** nicht armierbar.
    private func addLearningTarget(_ harness: CoordinatorHarness) -> EditableZone.ID {
        var state = harness.coordinator.editorState
        let id = state.addZone(CoordinatorHarness.zone(role: .filter, index: 0.0...0.2))
        state.select(nil)
        harness.coordinator.editorState = state
        return id
    }

    // MARK: - Ein Profilstrom, zwei Verbraucher

    /// Derselbe Batch erreicht Klangerzeugung **und** Lernen — und zwar
    /// jeder Batch genau einmal.
    func testEveryDeliveredBatchReachesTheLearningSessionExactlyOnce() throws {
        let harness = harness(reading: try script(profiles: 4, value: 3000))
        let target = addLearningTarget(harness)
        armLearn(harness, on: target, configuration: try configuration())

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 4 }

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 4)
        XCTAssertEqual(
            harness.coordinator.editorState.learning?.accumulator.profilesSeen, 4,
            "Genau so viele Profile wie an der Klangerzeugung — kein zweiter Strom"
        )

        harness.coordinator.disconnect()
    }

    /// Ohne armierten Vorgang passiert am Lernweg **nichts**; der
    /// Klangpfad läuft unverändert.
    func testWithoutAnArmedSessionTheProfilePathIsUnchanged() throws {
        let harness = harness(reading: try script(profiles: 3, value: 3000))

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 3 }

        XCTAssertNil(harness.coordinator.editorState.learning)
        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 3)

        harness.coordinator.disconnect()
    }

    // MARK: - Lernen bleibt folgenlos

    /// Ein laufender Lernvorgang ändert **nichts** am Klangpfad: keine
    /// Audioausgabe, kein Gate, keine Zonenänderung.
    func testAnArmedSessionStartsNoAudioAndChangesNoZone() throws {
        let harness = harness(reading: try script(profiles: 4, value: 3000))
        let target = addLearningTarget(harness)
        let zonesBefore = harness.coordinator.editorState.zones
        armLearn(harness, on: target, configuration: try configuration())

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 4 }

        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertFalse(harness.engine.isRunning)
        XCTAssertTrue(harness.root.audio.status.isEmpty)
        XCTAssertEqual(
            harness.coordinator.editorState.zones, zonesBefore,
            "Kein Kandidat schreibt von selbst in eine Zone"
        )

        harness.coordinator.disconnect()
    }

    /// Der Lernvorgang lässt die Signale der **übrigen** Zonen
    /// unangetastet (Abschnitt 4.3 Punkt 7 des Reviews).
    func testAnArmedSessionDoesNotChangeTheSignalsOfTheOtherZones() throws {
        let reference = harness(reading: try script(profiles: 3, value: 3000))
        reference.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { reference.coordinator.deliveredProfileBatches == 3 }
        reference.coordinator.disconnect()

        let learning = harness(reading: try script(profiles: 3, value: 3000))
        let target = addLearningTarget(learning)
        armLearn(learning, on: target, configuration: try configuration())
        learning.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { learning.coordinator.deliveredProfileBatches == 3 }
        XCTAssertEqual(learning.sessionDelivery.acceptedProfiles, reference.sessionDelivery.acceptedProfiles)


        learning.coordinator.disconnect()
    }

    // MARK: - Übernehmen über den produktiven Weg

    /// Ein vollständiger Lauf am produktiven Weg: armieren, echte Profile
    /// sammeln, abschließen, übernehmen — und die Zone bleibt
    /// **deaktiviert**.
    func testAFullRunOverTheProductivePathAppliesWithoutEnabling() throws {
        let quiet = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        // Zwei Grundprofile, dann drei mit einer deutlichen Wertsenke.
        var values = profileMeasurements(value: 3000)
        values[0] = 500
        values[1] = 500
        let moved = try b0FrameBytes(measurements: values)
        var script: [SerialPortReadOutcome] = []
        for bytes in [quiet, quiet, moved, moved, moved] {
            script.append(.bytes(bytes))
            script.append(.timeout)
        }
        let harness = harness(reading: script + Array(repeating: .timeout, count: 60))

        // Ein Lernziel, dessen Indexbereich die bewegten Punkte abdeckt.
        var state = harness.coordinator.editorState
        let target = state.addZone(CoordinatorHarness.zone(role: .filter, index: 0.0...0.2))
        state.select(nil)
        state.armLearn(zoneID: target, configuration: try configuration())
        harness.coordinator.editorState = state

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 5 }

        var finished = harness.coordinator.editorState
        finished.finishLearn()
        guard case .candidate(let candidate) = finished.learning?.state else {
            harness.coordinator.disconnect()
            return XCTFail("Erwartet: Kandidat, bekommen: \(String(describing: finished.learning?.state))")
        }
        XCTAssertEqual(finished.applyLearnCandidate(), .applied(candidate))
        harness.coordinator.editorState = finished

        let learned = try XCTUnwrap(harness.coordinator.editorState.zones.first { $0.id == target })
        XCTAssertEqual(learned.zone, candidate)
        XCTAssertFalse(learned.isEnabled, "**Kein automatisches Einschalten**")
        XCTAssertEqual(learned.zone.role, .filter, "Die beim Armieren festgelegte Rolle")
        XCTAssertFalse(harness.root.audio.isRunning)

        harness.coordinator.disconnect()
    }

}
