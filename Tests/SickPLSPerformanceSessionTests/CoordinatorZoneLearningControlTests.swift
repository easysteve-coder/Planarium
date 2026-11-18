import PlanariumInput
import XCTest
import SickPLSControlCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// SICK-032c2, Akzeptanz 2: Die **produktive** Bedienung des Hand-Learns
/// über den Koordinator.
///
/// Armieren, Fortschritt, Beenden, Übernehmen, Abbrechen und Verwerfen
/// laufen hier genau den Weg, den die Zonenkarte nimmt — und der
/// Fortschritt entsteht **ausschließlich** aus echten Profilen: Die
/// Profile laufen durch die **echte** `RXSession` samt echtem
/// Hintergrund-Thread, echtem `StreamParser` und echtem
/// `B0ScanProfile.decode`; gefälscht sind nur Dateideskriptor und
/// Audiohost.
@MainActor final class CoordinatorZoneLearningControlTests: XCTestCase {

    // MARK: - Aufbau

    private func harness(reading script: [SerialPortReadOutcome]) -> CoordinatorHarness {
        CoordinatorHarness(descriptors: [FakeSerialPortFileDescriptor(readScript: script)])
    }

    /// Ein Skript, das **die feste Vorgabekonfiguration** bedient
    /// (`ZoneLearningConfiguration.default`, die der Koordinator
    /// benutzt): fünf ruhige Grundprofile, danach drei Profile mit einer
    /// deutlichen Senke auf den Messpunkten 0…3.
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

    /// Legt eine neue — und damit **ausgeschaltete** — Zone direkt im
    /// Editorzustand an; sie ist danach ausgewählt.
    ///
    /// **Seit SICK-032c3a nicht mehr über `coordinator.addZone(role:)`**
    /// — der legt inzwischen keine Zone mehr sofort an, sondern startet
    /// einen Lernentwurf (siehe `CoordinatorLearnDraftTests`). Diese
    /// Tests prüfen das Lernen einer bereits vorhandenen Zone und
    /// brauchen dafür nur irgendeine gültige, ausgeschaltete Zone als
    /// Vorrichtung.
    @discardableResult
    private func addLearningTarget(
        _ harness: CoordinatorHarness, role: ZoneRole = .filter
    ) throws -> EditableZone.ID {
        var state = harness.coordinator.editorState
        let id = state.addZone(CoordinatorHarness.zone(role: role, index: 0.25...0.75))
        harness.coordinator.editorState = state
        return id
    }

    private func learning(_ harness: CoordinatorHarness) throws -> ZoneLearningPresentation {
        try XCTUnwrap(harness.coordinator.selectedZoneLearning)
    }

    private func zone(
        _ harness: CoordinatorHarness, _ id: EditableZone.ID
    ) throws -> EditableZone {
        try XCTUnwrap(harness.coordinator.editorState.zones.first { $0.id == id })
    }

    // MARK: - Armieren

    /// **Auflage D2 am produktiven Weg:** Eine eingeschaltete Zone lässt
    /// sich nicht armieren — sichtbar abgelehnt, ohne Vorgang.
    func testArmingAnEnabledZoneIsRefused() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        harness.coordinator.selectZoneForEditing(harness.pitchZoneID)

        let blocked = try learning(harness)
        XCTAssertEqual(blocked.block, .zoneIsEnabled)
        XCTAssertFalse(blocked.canStart)

        XCTAssertEqual(harness.coordinator.startZoneLearning(), .zoneIsEnabled)
        XCTAssertNil(
            harness.coordinator.editorState.learning,
            "Eine abgelehnte Armierung legt keinen Vorgang an"
        )
        XCTAssertEqual(
            harness.coordinator.zoneLearningNotice?.message,
            ZoneLearningBlock.zoneIsEnabled.message
        )
        XCTAssertEqual(harness.coordinator.zoneLearningNotice?.isSuccess, false)
    }

    /// Nach dem Ausschalten derselben Zone geht es — der Sperrgrund ist
    /// in einem Handgriff auflösbar.
    func testDisablingTheSameZoneUnlocksTheStart() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        harness.coordinator.selectZoneForEditing(harness.pitchZoneID)
        harness.coordinator.setZone(harness.pitchZoneID, isEnabled: false)

        XCTAssertNil(try learning(harness).block)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)
        XCTAssertEqual(try learning(harness).phase, .waitingForProfiles)
        XCTAssertEqual(harness.coordinator.zoneLearningNotice?.isSuccess, true)
    }

    /// Eine ausgeschaltete Zone wird armiert; an einer **anderen** Zone
    /// ist der Start währenddessen gesperrt, und ihr eigener Schritt
    /// bleibt `idle`.
    func testASecondZoneIsBlockedWhileOneIsLearning() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        let first = try addLearningTarget(harness, role: .filter)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        let second = try addLearningTarget(harness, role: .effectSend)
        let blocked = try learning(harness)
        XCTAssertEqual(blocked.zoneID, second)
        XCTAssertEqual(blocked.phase, .idle)
        XCTAssertEqual(blocked.block, .otherZoneIsLearning)
        XCTAssertFalse(blocked.canStart)

        XCTAssertEqual(
            harness.coordinator.startZoneLearning(), .alreadyLearning(zoneID: first),
            "Der laufende Vorgang bleibt unangetastet"
        )
        XCTAssertEqual(harness.coordinator.editorState.learning?.zoneID, first)
    }

    /// **SICK-032c3a-K1:** Ein sammelnder vorzonaler Entwurf sperrt das
    /// Armieren einer Zone genauso wie eine andere sammelnde Zone --
    /// benannt, und der Entwurf bleibt unangetastet.
    func testACollectingDraftBlocksArmingAndLeavesTheDraftUntouched() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        XCTAssertEqual(harness.coordinator.startLearnDraft(role: .pitch), .started)
        let target = try addLearningTarget(harness, role: .filter)
        harness.coordinator.selectZoneForEditing(target)

        let blocked = try learning(harness)
        XCTAssertEqual(blocked.block, .learnDraftIsCollecting)
        XCTAssertFalse(blocked.canStart)

        XCTAssertEqual(harness.coordinator.startZoneLearning(), .blockedByLearnDraft)
        XCTAssertNil(harness.coordinator.editorState.learning, "Es wurde nichts armiert")
        XCTAssertEqual(
            harness.coordinator.zoneLearningNotice?.message,
            ZoneLearningBlock.learnDraftIsCollecting.message
        )
        XCTAssertEqual(harness.coordinator.zoneLearningNotice?.isSuccess, false)
        XCTAssertEqual(
            harness.coordinator.learnDraftPresentation?.phase, .waitingForProfiles,
            "Der sammelnde Entwurf bleibt unangetastet"
        )
    }

    // MARK: - Fortschritt nur aus echten Profilen

    /// **Der einzige Fortschrittsweg.** Ohne eintreffende Profile bleibt
    /// es bei „Warte auf Messwerte" — auch wenn der Haupt-RunLoop lange
    /// läuft. Es gibt keinen Timer, keine Uhr und keinen Balken.
    func testProgressComesOnlyFromRealProfiles() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 80))
        try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        pumpMainLoop(seconds: 0.5)
        XCTAssertEqual(try learning(harness).progressLabel, "Waiting for measurements")

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        pumpMainLoop(seconds: 0.5)
        XCTAssertEqual(
            try learning(harness).progressLabel, "Waiting for measurements",
            "Eine bloße Verbindung ohne Messwerte bewegt nichts"
        )
        XCTAssertEqual(harness.coordinator.deliveredProfileBatches, 0)

        harness.coordinator.disconnect()
    }

    /// Die echte Profilfolge führt durch **beide** Schritte: erst
    /// Grundprofil, dann Bewegung — mit den Zahlen des Lernvertrags.
    func testRealProfilesAdvanceBaselineThenMovement() throws {
        let harness = harness(reading: try learnableScript())
        try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)

        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }
        XCTAssertEqual(try learning(harness).stepTitle, "Keep scan field clear briefly")
        XCTAssertEqual(try learning(harness).progressLabel, "Baseline profile 1 of 5")

        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }
        let movement = try learning(harness)
        XCTAssertEqual(movement.stepTitle, "Move hand through desired area")
        XCTAssertEqual(
            movement.progressLabel, "8 profiles · 4 measurement points changed · 4 stable",
            "Genau die Zahlen des Lernvertrags, nichts Hochgerechnetes"
        )
        XCTAssertTrue(movement.canFinish)
        XCTAssertTrue(movement.canCancel)
        XCTAssertFalse(movement.canApply)

        harness.coordinator.disconnect()
    }

    // MARK: - Übernehmen

    /// **Der Kernnachweis:** Ein vollständiger Lauf über den produktiven
    /// Weg schreibt den Vorschlag in dieselbe Zone — und lässt sie
    /// **aus**, ohne Slot, ohne Gate, ohne Audio.
    func testApplyingALearnedZoneLeavesItOffWithoutSlotGateOrAudio() throws {
        let harness = harness(reading: try learnableScript())
        let target = try addLearningTarget(harness)
        let zoneBefore = try zone(harness, target).zone
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }

        harness.coordinator.finishZoneLearning()
        let proposal = try learning(harness)
        guard let candidate = proposal.phase.candidateZone else {
            harness.coordinator.disconnect()
            return XCTFail("Erwartet: Vorschlag, bekommen: \(proposal.phase)")
        }
        XCTAssertEqual(proposal.candidateBoundsLabel, ZoneBoundsText.label(for: candidate))
        XCTAssertTrue(proposal.canApply)
        XCTAssertNotEqual(candidate, zoneBefore, "Der Vorschlag ist ein anderer Bereich")
        XCTAssertEqual(
            try zone(harness, target).zone, zoneBefore,
            "Ein Vorschlag allein schreibt nichts"
        )


        guard case .applied(let written) = harness.coordinator.applyZoneLearningCandidate() else {
            harness.coordinator.disconnect()
            return XCTFail("Übernehmen wurde abgelehnt")
        }

        XCTAssertEqual(written, candidate)
        let learned = try zone(harness, target)
        XCTAssertEqual(learned.zone, candidate)
        XCTAssertFalse(learned.isEnabled, "**Kein automatisches Einschalten** (Auflage D2)")
        XCTAssertEqual(learned.zone.role, .filter, "Die beim Armieren festgelegte Rolle")
        XCTAssertEqual(
            harness.engine.isRunning, false,
            "Übernehmen weist keinen Spiel-Slot zu"
        )
        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertFalse(harness.engine.isRunning)
        XCTAssertTrue(harness.root.audio.status.isEmpty)
        XCTAssertEqual(harness.coordinator.zoneLearningNotice?.isSuccess, true)

        harness.coordinator.disconnect()
    }

    /// Übernehmen ohne Vorschlag wird benannt abgelehnt und ändert nichts.
    func testApplyingWithoutACandidateIsNamedAndChangesNothing() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        let target = try addLearningTarget(harness)
        let before = try zone(harness, target).zone
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        XCTAssertEqual(harness.coordinator.applyZoneLearningCandidate(), .noCandidate(.arming))
        XCTAssertEqual(try zone(harness, target).zone, before)
        XCTAssertEqual(harness.coordinator.zoneLearningNotice?.isSuccess, false)
    }

    // MARK: - Abbrechen und Verwerfen

    /// **Abbrechen** während einer Sammlung lässt die Zone unverändert —
    /// und der Grund bleibt danach lesbar.
    func testCancellingLeavesTheZoneUntouched() throws {
        let harness = harness(reading: try learnableScript())
        let target = try addLearningTarget(harness)
        let before = try zone(harness, target)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 5 }

        harness.coordinator.cancelZoneLearning()

        let cancelled = try learning(harness)
        XCTAssertEqual(cancelled.phase, .cancelled(.operatorCancelled))
        XCTAssertEqual(cancelled.stepTitle, "Cancelled")
        XCTAssertEqual(cancelled.instruction, ZoneLearningCancellation.operatorCancelled.operatorText)
        XCTAssertTrue(cancelled.canDiscard)
        XCTAssertTrue(cancelled.canStart, "Ein neuer Anlauf ist sofort möglich")
        XCTAssertEqual(try zone(harness, target), before, "Die Zone ist unverändert")
        XCTAssertFalse(harness.root.audio.isRunning)

        harness.coordinator.disconnect()
    }

    /// **Verwerfen** nach einem Ergebnis lässt die Zone ebenfalls
    /// unverändert und räumt den Vorgang weg.
    func testDiscardingAResultLeavesTheZoneUntouched() throws {
        let harness = harness(reading: try learnableScript())
        let target = try addLearningTarget(harness)
        let before = try zone(harness, target)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }
        harness.coordinator.finishZoneLearning()
        XCTAssertNotNil(try learning(harness).phase.candidateZone)

        harness.coordinator.discardZoneLearning()

        XCTAssertNil(harness.coordinator.editorState.learning)
        let cleared = try learning(harness)
        XCTAssertEqual(cleared.phase, .idle)
        XCTAssertNil(cleared.candidateBoundsLabel)
        XCTAssertTrue(cleared.canStart)
        XCTAssertEqual(try zone(harness, target), before, "Die Zone ist unverändert")

        harness.coordinator.disconnect()
    }

    // MARK: - Die vorhandenen, typisierten Abbruchursachen bleiben sichtbar

    /// Das **Einschalten** der Zielzone beendet den Vorgang mit seiner
    /// eigenen, benannten Ursache — und die bleibt verständlich lesbar.
    func testEnablingTheTargetZoneEndsTheRunVisibly() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        let target = try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.setZone(target, isEnabled: true)

        let ended = try learning(harness)
        XCTAssertEqual(ended.phase, .cancelled(.zoneActivationChanged))
        XCTAssertEqual(ended.block, .zoneIsEnabled)
        XCTAssertFalse(ended.canStart)
        XCTAssertEqual(
            ended.instruction, ZoneLearningCancellation.zoneActivationChanged.operatorText
        )
    }

    /// Eine **Rollenänderung** beendet den Vorgang ebenfalls sichtbar.
    func testChangingTheRoleEndsTheRunVisibly() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        try addLearningTarget(harness, role: .filter)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        var draft = try XCTUnwrap(harness.coordinator.zoneDraft)
        draft.role = .effectSend
        harness.coordinator.updateZoneDraft(draft)
        XCTAssertTrue(harness.coordinator.commitZoneDraft())

        XCTAssertEqual(try learning(harness).phase, .cancelled(.zoneRoleChanged))
    }

    /// Das **Entfernen** der Zielzone beendet den Vorgang; ohne Auswahl
    /// gibt es danach keinen Lernbereich mehr.
    func testRemovingTheTargetZoneEndsTheRun() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        let target = try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        harness.coordinator.removeZone(target)

        XCTAssertEqual(
            harness.coordinator.editorState.learning?.state, .cancelled(.zoneRemoved)
        )
        XCTAssertNil(
            harness.coordinator.selectedZoneLearning,
            "Ohne ausgewählte Zone gibt es keine Karte und keinen Lernbereich"
        )
    }

    // MARK: - Lernen bleibt folgenlos

    /// Ein **abgeschlossener, nicht übernommener** Lauf lässt Zonen,
    /// Zuordnung, Gate und Audio vollständig unberührt.
    func testAFinishedButUnappliedRunChangesNothingObservable() throws {
        let harness = harness(reading: try learnableScript())
        try addLearningTarget(harness)

        let zonesBefore = harness.coordinator.editorState.zones

        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }
        harness.coordinator.finishZoneLearning()

        XCTAssertEqual(harness.coordinator.editorState.zones, zonesBefore)
        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertTrue(harness.root.audio.status.isEmpty)

        harness.coordinator.disconnect()
    }

    /// Die Lernparameter der Karte sind **genau** die, mit denen armiert
    /// wird — eine Anzeige, die eine andere Konfiguration behauptete,
    /// wäre wertlos.
    func testTheShownParametersAreTheOnesUsedForArming() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        try addLearningTarget(harness)
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        let shown = try learning(harness).configuration
        XCTAssertEqual(
            harness.coordinator.editorState.learning?.accumulator.configuration, shown
        )
        XCTAssertEqual(shown, .default)
    }
}
