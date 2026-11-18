import PlanariumInput
import XCTest
import SickPLSControlCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// SICK-032c2a: **Ein Lernlauf gehört zu genau einer ununterbrochenen
/// Messsitzung.**
///
/// `ZoneLearningCancellation.disconnected` gab es seit SICK-030c im
/// Vertrag, aber keine Stelle löste ihn aus — ein sammelnder Lauf blieb
/// über eine Trennung hinweg stehen und hätte nach einer
/// Wiederverbindung mit einem **alten Grundprofil** weitergerechnet.
///
/// Die Profile laufen hier durch die **echte** `RXSession` samt echtem
/// Hintergrund-Thread, echtem `StreamParser` und echtem
/// `B0ScanProfile.decode`; gefälscht sind nur Dateideskriptor und
/// Audiohost.
@MainActor final class CoordinatorZoneLearningDisconnectTests: XCTestCase {

    // MARK: - Aufbau

    private func harness(
        _ scripts: [[SerialPortReadOutcome]]
    ) -> CoordinatorHarness {
        CoordinatorHarness(
            descriptors: scripts.map { FakeSerialPortFileDescriptor(readScript: $0) }
        )
    }

    /// Fünf ruhige Grundprofile, danach Ruhe — der Lauf bleibt also
    /// **sammelnd** stehen, bis ihn jemand beendet.
    private func quietScript(profiles: Int = 3, thenIdle idle: Int = 80) throws -> [SerialPortReadOutcome] {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        var script: [SerialPortReadOutcome] = []
        for _ in 0..<profiles {
            script.append(.bytes(bytes))
            script.append(.timeout)
        }
        return script + Array(repeating: .timeout, count: idle)
    }

    /// Dasselbe, aber **ohne** abschließende Ruhe: Ist das Skript
    /// erschöpft, meldet der Fake `.closed` — das bestehende
    /// „unerwartetes Stromende" der `RXSession`.
    private func endingScript(profiles: Int = 3) throws -> [SerialPortReadOutcome] {
        try quietScript(profiles: profiles, thenIdle: 0)
    }

    /// Ein vollständig lernbarer Lauf: fünf Grundprofile (die feste
    /// Vorgabekonfiguration), danach drei mit einer Senke auf den
    /// Messpunkten 0…3.
    private func learnableScript() throws -> [SerialPortReadOutcome] {
        let quiet = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        var moved = profileMeasurements(value: 3000)
        for index in 0...3 { moved[index] = 500 }
        let movement = try b0FrameBytes(measurements: moved)

        var script: [SerialPortReadOutcome] = []
        for bytes in Array(repeating: quiet, count: 5) + Array(repeating: movement, count: 3) {
            script.append(.bytes(bytes))
            script.append(.timeout)
        }
        return script + Array(repeating: .timeout, count: 80)
    }

    /// **Seit SICK-032c3a direkt im Editorzustand**, nicht mehr über
    /// `coordinator.addZone(role:)` — der startet inzwischen einen
    /// Lernentwurf statt sofort eine Zone anzulegen (siehe
    /// `CoordinatorLearnDraftTests`).
    @discardableResult
    private func addLearningTarget(_ harness: CoordinatorHarness) throws -> EditableZone.ID {
        var state = harness.coordinator.editorState
        let id = state.addZone(CoordinatorHarness.zone(role: .filter, index: 0.25...0.75))
        harness.coordinator.editorState = state
        return id
    }

    private func zone(
        _ harness: CoordinatorHarness, _ id: EditableZone.ID
    ) throws -> EditableZone {
        try XCTUnwrap(harness.coordinator.editorState.zones.first { $0.id == id })
    }

    // MARK: - 1. Ausdrückliches Trennen

    /// **Der Kernnachweis:** Ein sammelnder Lauf endet beim
    /// ausdrücklichen Trennen mit `.disconnected` — und die spätere
    /// Wiederverbindung setzt ihn **nicht** fort.
    func testAnExplicitDisconnectEndsACollectingRunAndItCannotResume() throws {
        let harness = harness([try quietScript(), try quietScript()])
        let target = try addLearningTarget(harness)
        let zoneBefore = try zone(harness, target)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 3 }
        XCTAssertTrue(
            harness.coordinator.editorState.learning?.isCollecting == true,
            "Vor dem Trennen sammelt der Lauf noch"
        )
        let profilesBeforeDisconnect = harness.coordinator.editorState.learning?.accumulator.profilesSeen
        // **Unverändertheit, nicht ein fester Wert:** Das Gate steht hier
        // durch die echten Profile der drei Pflichtzonen — die Frage ist,
        // ob das *Trennen* daran etwas ändert.

        harness.coordinator.disconnect()

        XCTAssertEqual(
            harness.coordinator.editorState.learning?.state, .cancelled(.disconnected),
            "Das Trennen beendet den Lauf sofort und benannt"
        )
        XCTAssertEqual(try zone(harness, target), zoneBefore, "Die Zone ist unverändert")
        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertTrue(harness.root.audio.status.isEmpty)
        // Die Karte zeigt den **bestehenden** Satz.
        let shown = try XCTUnwrap(harness.coordinator.selectedZoneLearning)
        XCTAssertEqual(shown.phase, .cancelled(.disconnected))
        XCTAssertEqual(shown.instruction, ZoneLearningCancellation.disconnected.operatorText)
        XCTAssertTrue(shown.canStart, "Ein neuer Anlauf ist möglich")

        // **Wiederverbinden setzt den alten Lauf nicht fort.**
        waitUntil { !harness.coordinator.session.isPortHeld }
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 6 }

        XCTAssertEqual(
            harness.coordinator.editorState.learning?.state, .cancelled(.disconnected),
            "Neue Profile beleben den beendeten Lauf nicht wieder"
        )
        XCTAssertEqual(
            harness.coordinator.editorState.learning?.accumulator.profilesSeen,
            profilesBeforeDisconnect,
            "Und sie werden auch nicht mehr gezählt"
        )

        harness.coordinator.disconnect()
    }

    // MARK: - 2. Unerwartetes Stromende

    /// Derselbe Abbruch auf dem **bestehenden** Stromende-Pfad der
    /// `RXSession` — ohne dass jemand `disconnect()` gerufen hätte.
    func testAnUnexpectedStreamEndEndsACollectingRun() throws {
        let harness = harness([try endingScript()])
        let target = try addLearningTarget(harness)
        let zoneBefore = try zone(harness, target)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.editorState.learning?.isCollecting == false }

        XCTAssertEqual(
            harness.coordinator.editorState.learning?.state, .cancelled(.disconnected)
        )
        XCTAssertEqual(
            harness.coordinator.session.state.connection,
            .failed(
                portPath: "/dev/cu.fake",
                baudRate: .baud9600,
                message: "Connection ended unexpectedly (end of stream)."
            ),
            "Der bestehende Stromende-Pfad, nicht ein neu erfundener"
        )
        XCTAssertEqual(try zone(harness, target), zoneBefore)
        XCTAssertFalse(harness.root.audio.isRunning)
    }

    /// Auch ein **gescheitertes Öffnen** beendet den Lauf — der
    /// Verbindungsversuch ist vorbei, und ein Grundfenster ohne Sitzung
    /// ist nichts wert.
    func testAFailedOpenAlsoEndsACollectingRun() throws {
        let harness = harness([try quietScript()])
        harness.opener.errorToThrow = FakeSerialPortOpener.OpenFailure()
        try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.editorState.learning?.isCollecting == false }

        XCTAssertEqual(
            harness.coordinator.editorState.learning?.state, .cancelled(.disconnected)
        )
    }

    // MARK: - 3. Was eine Trennung nicht anfassen darf

    /// Ein **fertiger Vorschlag** übersteht eine Trennung unverändert.
    func testAFinishedCandidateSurvivesADisconnect() throws {
        let harness = harness([try learnableScript()])
        try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }
        harness.coordinator.finishZoneLearning()

        let candidate = try XCTUnwrap(harness.coordinator.editorState.learning?.candidate)

        harness.coordinator.disconnect()
        waitUntil { !harness.coordinator.session.isPortHeld }

        XCTAssertEqual(
            harness.coordinator.editorState.learning?.state, .candidate(candidate),
            "Ein gefallenes Ergebnis wird von einer Trennung nie überschrieben"
        )
        XCTAssertTrue(try XCTUnwrap(harness.coordinator.selectedZoneLearning).canApply)
    }

    /// Ein **vom Bedienenden abgebrochener** Lauf behält seinen Grund.
    func testAnOperatorCancelledRunKeepsItsReason() throws {
        let harness = harness([try quietScript()])
        try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }
        harness.coordinator.cancelZoneLearning()

        harness.coordinator.disconnect()
        waitUntil { !harness.coordinator.session.isPortHeld }

        XCTAssertEqual(
            harness.coordinator.editorState.learning?.state, .cancelled(.operatorCancelled),
            "Der ursprüngliche Grund bleibt stehen — sonst läse niemand mehr, was wirklich geschah"
        )
    }

    /// Eine **verworfene** Sitzung bleibt verworfen; eine Trennung legt
    /// keine neue an.
    func testADiscardedRunIsNotRecreatedByADisconnect() throws {
        let harness = harness([try quietScript()])
        try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }
        harness.coordinator.discardZoneLearning()

        harness.coordinator.disconnect()
        waitUntil { !harness.coordinator.session.isPortHeld }

        XCTAssertNil(harness.coordinator.editorState.learning)
    }

    // MARK: - 4. Doppeltes Ende, und kein Ende ohne Verbindung

    /// **Doppeltes Ende erzeugt keine zweite Zustandsänderung.** Trennen
    /// meldet sich zweimal — sofort und später über das echte
    /// Freigabe-Ereignis —, und ein zweites `disconnect()` kommt
    /// obendrauf.
    func testASecondEndProducesNoSecondStateChange() throws {
        let harness = harness([try quietScript()])
        try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }

        harness.coordinator.disconnect()
        let afterFirstEnd = harness.coordinator.editorState.learning

        harness.coordinator.disconnect()
        waitUntil { !harness.coordinator.session.isPortHeld }
        pumpMainLoop(seconds: 0.2)

        XCTAssertEqual(
            harness.coordinator.editorState.learning, afterFirstEnd,
            "Der ganze Vorgangswert ist unverändert — nicht nur sein Zustandsfall"
        )
    }

    /// **Ohne Verbindung endet nichts.** Ein armierter Lauf, der noch auf
    /// seine erste Messung wartet, überlebt ein `disconnect()` ins Leere.
    func testDisconnectWithoutAConnectionLeavesAnArmedRunAlone() throws {
        let harness = harness([try quietScript()])
        try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)
        XCTAssertFalse(harness.coordinator.session.isPortHeld)

        harness.coordinator.disconnect()
        pumpMainLoop(seconds: 0.2)

        XCTAssertEqual(harness.coordinator.editorState.learning?.state, .arming)
        XCTAssertEqual(
            try XCTUnwrap(harness.coordinator.selectedZoneLearning).progressLabel,
            "Waiting for measurements"
        )
    }

    /// Eine Trennung **ohne** armierten Lauf verändert nichts und legt
    /// keine Sitzung an.
    func testDisconnectWithoutAnArmedRunChangesNothing() throws {
        let harness = harness([try quietScript()])
        let zonesBefore = harness.coordinator.editorState.zones

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }
        harness.coordinator.disconnect()
        waitUntil { !harness.coordinator.session.isPortHeld }

        XCTAssertNil(harness.coordinator.editorState.learning)
        XCTAssertEqual(harness.coordinator.editorState.zones, zonesBefore)
    }

    // MARK: - 5. Der Profilweg bleibt einer

    /// Das Trennen hängt an den **vorhandenen** Wegen: Nach dem Ende
    /// erreicht kein Profil mehr die Klangerzeugung, und der
    /// Profilzähler der Sitzung läuft genau wie zuvor.
    func testTheSingleProfilePathIsUnchangedByTheNewEnding() throws {
        let harness = harness([try quietScript(profiles: 3)])
        try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 3 }

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 3)
        XCTAssertEqual(
            harness.coordinator.editorState.learning?.accumulator.profilesSeen, 3,
            "Genau so viele wie an der Klangerzeugung — kein zweiter Strom"
        )

        harness.coordinator.disconnect()
        waitUntil { !harness.coordinator.session.isPortHeld }
        pumpMainLoop(seconds: 0.2)

        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 3)
        XCTAssertTrue(harness.coordinator.hasActiveProfileSubscription)
        XCTAssertTrue(harness.coordinator.hasActivePortReleaseSubscription)
    }
}
