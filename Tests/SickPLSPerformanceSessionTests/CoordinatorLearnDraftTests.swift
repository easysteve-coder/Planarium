import PlanariumInput
import XCTest
import SickPLSControlCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// SICK-032c3a am **produktiven Weg**: echter Zoneneditor, echter
/// Controller, echte `RXSession` mit echtem Hintergrund-Thread und
/// echtem Framing — gefälscht sind nur Dateideskriptor und Audiohost.
///
/// **Keine SwiftUI-Ansicht.** Wie `CoordinatorZoneLearningControlTests`
/// bedient dieser Prüfstand ausschließlich Methoden des Koordinators.
@MainActor final class CoordinatorLearnDraftTests: XCTestCase {

    // MARK: - Aufbau

    private func harness(reading script: [SerialPortReadOutcome]) -> CoordinatorHarness {
        CoordinatorHarness(descriptors: [FakeSerialPortFileDescriptor(readScript: script)])
    }

    /// Ein Skript, das **die feste Vorgabekonfiguration** bedient
    /// (`ZoneLearningConfiguration.default`, die der Koordinator
    /// benutzt): fünf ruhige Grundprofile, danach drei Profile mit einer
    /// deutlichen Senke auf den Messpunkten 0…3 -- dieselbe wie in
    /// `CoordinatorZoneLearningControlTests`.
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

    private func presentation(_ harness: CoordinatorHarness) throws -> LearnDraftPresentation {
        try XCTUnwrap(harness.coordinator.learnDraftPresentation)
    }

    // MARK: - Anlegen erzeugt keine Zone (Pflichtnachweis 1, produktiv)

    func testAddZoneAtTheCoordinatorStartsADraftWithoutAnyZoneSlotGateOrAudioEffect() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        let before = harness.coordinator.zoneInserts.count

        XCTAssertEqual(harness.coordinator.addZone(role: .effectSend), .started)

        XCTAssertEqual(harness.coordinator.zoneInserts.count, before)
        XCTAssertEqual(try presentation(harness).role, .effectSend)
        XCTAssertEqual(try presentation(harness).phase, .waitingForProfiles)
        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertFalse(harness.engine.isRunning)
    }

    // MARK: - Fortschritt nur aus echten Profilen

    func testProgressComesOnlyFromRealProfiles() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 80))
        harness.coordinator.startLearnDraft(role: .filter)

        pumpMainLoop(seconds: 0.3)
        XCTAssertEqual(try presentation(harness).progressLabel, "Waiting for measurements")

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        pumpMainLoop(seconds: 0.3)
        XCTAssertEqual(
            try presentation(harness).progressLabel, "Waiting for measurements",
            "Eine bloße Verbindung ohne Messwerte bewegt nichts"
        )
        harness.coordinator.disconnect()
    }

    func testRealProfilesAdvanceBaselineThenMovement() throws {
        let harness = harness(reading: try learnableScript())
        harness.coordinator.startLearnDraft(role: .filter)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)

        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }
        XCTAssertEqual(try presentation(harness).progressLabel, "Baseline profile 1 of 5")

        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }
        XCTAssertEqual(
            try presentation(harness).progressLabel, "8 profiles · 4 measurement points changed · 4 stable"
        )

        harness.coordinator.disconnect()
    }

    // MARK: - Übernehmen (Pflichtnachweis 4, produktiv)

    /// **Der Kernnachweis:** Ein vollständiger Lauf über den produktiven
    /// Weg legt genau eine ausgewählte, ausgeschaltete Zone mit der
    /// beim Anlegen gewählten Rolle an -- ohne Slot, ohne Gate, ohne
    /// Audio.
    func testApplyingALearnedDraftProducesExactlyOneSelectedDisabledZoneWithoutSlotGateOrAudio() throws {
        let harness = harness(reading: try learnableScript())
        let zonesBefore = harness.coordinator.editorState.zones.count
        harness.coordinator.startLearnDraft(role: .filter)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }

        harness.coordinator.finishLearnDraft()
        let proposal = try presentation(harness)
        guard let candidate = proposal.phase.candidateZone else {
            harness.coordinator.disconnect()
            return XCTFail("Erwartet: Vorschlag, bekommen: \(proposal.phase)")
        }
        XCTAssertTrue(proposal.canApply)

        let outcome = harness.coordinator.applyLearnDraftCandidate()
        guard case .applied(let id, let written) = outcome else {
            harness.coordinator.disconnect()
            return XCTFail("Übernehmen wurde abgelehnt: \(outcome)")
        }
        XCTAssertEqual(written, candidate)
        XCTAssertEqual(harness.coordinator.editorState.zones.count, zonesBefore + 1, "Genau eine neue Zone")
        let inserted = try XCTUnwrap(harness.coordinator.zoneInserts.first { $0.id == id })
        XCTAssertEqual(inserted.zone, candidate)
        XCTAssertEqual(inserted.zone.role, .filter)
        XCTAssertEqual(inserted.activation, .off, "Auflage D2: weiterhin ausgeschaltet")
        XCTAssertTrue(inserted.isSelected)
        XCTAssertNil(harness.coordinator.learnDraftPresentation, "Der Entwurf ist verbraucht")
        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertFalse(harness.engine.isRunning)

        harness.coordinator.disconnect()
    }

    /// Eine zweite Übernahme desselben, längst verbrauchten Entwurfs
    /// legt keine zweite Zone an.
    func testASecondApplyAfterASuccessfulOneCreatesNoSecondZone() throws {
        let harness = harness(reading: try learnableScript())
        harness.coordinator.startLearnDraft(role: .filter)
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }
        harness.coordinator.finishLearnDraft()

        guard case .applied = harness.coordinator.applyLearnDraftCandidate() else {
            harness.coordinator.disconnect()
            return XCTFail("Testvoraussetzung: die erste Übernahme gelingt")
        }
        let countAfterFirst = harness.coordinator.editorState.zones.count

        XCTAssertEqual(harness.coordinator.applyLearnDraftCandidate(), .notDrafting)
        XCTAssertEqual(harness.coordinator.editorState.zones.count, countAfterFirst)

        harness.coordinator.disconnect()
    }

    // MARK: - Verbindungsverlust beendet einen sammelnden Entwurf (Pflichtnachweis 5, produktiv)

    /// **Derselbe Schutz wie beim zonengebundenen Lernen** (SICK-032c2a),
    /// hier für den vorzonalen Entwurf.
    func testAnExplicitDisconnectEndsACollectingDraftWithDisconnected() throws {
        let harness = harness(reading: try learnableScript())
        harness.coordinator.startLearnDraft(role: .filter)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }

        harness.coordinator.disconnect()
        waitUntil { !harness.coordinator.session.isPortHeld }

        XCTAssertEqual(try presentation(harness).phase, .cancelled(.disconnected))
    }

    /// Ein bereits gefallenes Ergebnis überlebt eine spätere Trennung
    /// unangetastet, und die nächste Wiederverbindung setzt **keinen**
    /// alten Profilstand fort.
    func testAFinishedDraftIsUntouchedByASubsequentDisconnectAndANewOneStartsFresh() throws {
        let harness = harness(reading: [.closed] + Array(repeating: .timeout, count: 80))
        harness.coordinator.startLearnDraft(role: .filter)
        harness.coordinator.finishLearnDraft() // sofort beendet -> Verweigerung
        guard case .refused = try presentation(harness).phase else {
            return XCTFail("Testvoraussetzung: der Entwurf ist bereits beendet")
        }

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.portOwner == .free }

        XCTAssertEqual(
            try presentation(harness).phase, .refused(.baselineIncomplete(seen: 0, required: 5)),
            "Ein unerwartetes Stromende überschreibt kein bereits gefallenes Ergebnis"
        )

        XCTAssertEqual(harness.coordinator.startLearnDraft(role: .filter), .started)
        XCTAssertEqual(try presentation(harness).phase, .waitingForProfiles, "Kein alter Stand wirkt weiter")
    }

    // MARK: - Relevanter Bereich in der Präsentation

    func testTheFocusAreaReflectsTheLastReceivedRealProfile() throws {
        let harness = harness(reading: try learnableScript())
        harness.coordinator.startLearnDraft(role: .filter)
        XCTAssertEqual(
            try presentation(harness).focusArea, .refused(.noProfile),
            "Ohne Profil kein Bereich -- aber ein Entwurf läuft, also kein `nil`"
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }

        guard case .focused(let result) = try presentation(harness).focusArea else {
            harness.coordinator.disconnect()
            return XCTFail("Erwartet: ein fokussierter Bereich aus dem echten Profil")
        }
        XCTAssertGreaterThan(result.carriedMeasurementCount, 0)

        harness.coordinator.disconnect()
    }

    // MARK: - Atomar gekoppelter Fokus (K1, Abnahmeblocker 4, Pflichtnachweise 5+6)

    /// **Der frühere Fehler, jetzt korrigiert:** Ein ausdrückliches
    /// „Einpassen" **ohne** aktuelles Profil gab bislang trotzdem
    /// `.focusNow` aus und sperrte sofort den späteren automatischen
    /// Erstfokus. Über die atomar gekoppelte Grenze passiert beides
    /// nicht -- der Einmalzustand bleibt ausstehend, und das erste
    /// spätere echte Profil fokussiert noch automatisch.
    func testAFailedExplicitFitWithoutAProfileDoesNotConsumeOrLockTheAutomaticFocus() throws {
        let harness = harness(reading: try learnableScript())
        harness.coordinator.startLearnDraft(role: .filter)

        XCTAssertEqual(
            harness.coordinator.resolveLearnDraftFocus(.explicitFitRequested),
            .nothingToFocus(.noProfile)
        )
        XCTAssertTrue(
            harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true,
            "Ein erfolgloser Versuch sperrt den ausstehenden automatischen Fokus nicht"
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }

        guard case .focus = harness.coordinator.resolveLearnDraftFocus(.measurementAvailable) else {
            harness.coordinator.disconnect()
            return XCTFail("Der spätere automatische Fokus wirkt noch -- das erste echte Profil fokussiert")
        }
        XCTAssertFalse(harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true)

        harness.coordinator.disconnect()
    }

    /// **Pflichtnachweis 6, erste Hälfte:** Eine automatische Anfrage
    /// ohne berechenbaren Bereich verbraucht den Einmalzustand nicht.
    func testAnAutomaticRequestWithoutAComputableAreaConsumesNothing() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        harness.coordinator.startLearnDraft(role: .filter)

        XCTAssertEqual(
            harness.coordinator.resolveLearnDraftFocus(.measurementAvailable),
            .nothingToFocus(.noProfile)
        )
        XCTAssertTrue(harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true)
    }

    /// **Pflichtnachweis 6, zweite Hälfte:** Ein erfolgreicher
    /// automatischer Fokus liefert den berechneten Bereich, wirkt aber
    /// höchstens einmal -- eine zweite Anfrage trotz weiterhin
    /// berechenbarem Bereich ergibt `.doNothing`.
    func testASuccessfulAutomaticFocusFiresExactlyOnce() throws {
        let harness = harness(reading: try learnableScript())
        harness.coordinator.startLearnDraft(role: .filter)
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }

        guard case .focus(let result) = harness.coordinator.resolveLearnDraftFocus(.measurementAvailable) else {
            harness.coordinator.disconnect()
            return XCTFail("Erwartet: ein berechneter Bereich aus dem echten Profil")
        }
        XCTAssertGreaterThan(result.carriedMeasurementCount, 0)
        XCTAssertFalse(harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true)

        XCTAssertEqual(
            harness.coordinator.resolveLearnDraftFocus(.measurementAvailable), .doNothing,
            "Der Bereich bliebe weiterhin berechenbar -- die Entscheidung sagt trotzdem \"jetzt nicht\""
        )

        harness.coordinator.disconnect()
    }

    /// Ein erfolgreiches explizites Einpassen bleibt jederzeit möglich,
    /// liefert den Bereich **und** sperrt zusätzlich den noch
    /// ausstehenden automatischen Erstfokus (unverändertes Verhalten).
    func testASuccessfulExplicitFitReturnsTheAreaAndLocksTheAutomaticFocus() throws {
        let harness = harness(reading: try learnableScript())
        harness.coordinator.startLearnDraft(role: .filter)
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }

        guard case .focus = harness.coordinator.resolveLearnDraftFocus(.explicitFitRequested) else {
            harness.coordinator.disconnect()
            return XCTFail("Erwartet: ein berechneter Bereich")
        }
        XCTAssertFalse(harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true)

        harness.coordinator.disconnect()
    }

    /// Manuelle Navigation sperrt weiterhin sofort und unbedingt --
    /// unabhängig davon, ob überhaupt ein Profil vorliegt.
    func testManualNavigationLocksImmediatelyRegardlessOfAnyProfile() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        harness.coordinator.startLearnDraft(role: .filter)

        XCTAssertEqual(harness.coordinator.resolveLearnDraftFocus(.manualNavigation), .doNothing)
        XCTAssertFalse(harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true)
    }

    func testResolveWithoutARunningDraftReturnsNoDraft() {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        XCTAssertEqual(harness.coordinator.resolveLearnDraftFocus(.manualNavigation), .noDraft)
        XCTAssertEqual(harness.coordinator.resolveLearnDraftFocus(.measurementAvailable), .noDraft)
    }

    // MARK: - Fokus verwendet nur ein aktuelles Sitzungsprofil (K1, Abnahmeblocker 3)

    /// **Der frühere Fehler, jetzt korrigiert:** Profil empfangen ->
    /// unerwartetes Stromende -> ein frisch gestarteter Entwurf zeigte
    /// bislang noch den relevanten Bereich der bereits beendeten
    /// Sitzung. Erst das erste Profil der **nächsten** Sitzung liefert
    /// wieder einen Bereich.
    func testAFreshDraftAfterAnUnexpectedStreamEndShowsNoFocusAreaBeforeTheNextSessionsFirstProfile() throws {
        let firstSessionProfile = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let secondSessionProfile = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = CoordinatorHarness(descriptors: [
            // Ein `.timeout` nach dem Profil gibt dem Haupt-Thread ein
            // Zeitfenster, den Bereich zu sehen, **bevor** das Skript
            // erschöpft ist und der Fake das unerwartete Stromende
            // meldet -- sonst könnten beide Ereignisse im selben
            // `waitUntil`-Durchlauf verarbeitet werden.
            FakeSerialPortFileDescriptor(readScript: [.bytes(firstSessionProfile), .timeout]),
            FakeSerialPortFileDescriptor(
                readScript: [.bytes(secondSessionProfile)] + Array(repeating: .timeout, count: 80)
            )
        ])
        harness.coordinator.startLearnDraft(role: .filter)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }
        guard case .focused = try presentation(harness).focusArea else {
            return XCTFail("Testvoraussetzung: das erste Profil lieferte einen Bereich")
        }

        // Unerwartetes Stromende: das Skript ist erschöpft, der Fake
        // meldet `.closed`. `endLearningBecauseConnectionEnded()` beendet
        // den noch sammelnden Entwurf mit `.disconnected`.
        waitUntil { !harness.coordinator.session.isPortHeld }

        // Neuer Entwurf -- „neu starten" ersetzt den beendeten
        // stillschweigend (kein `discardLearnDraft()` nötig).
        XCTAssertEqual(harness.coordinator.startLearnDraft(role: .filter), .started)

        XCTAssertEqual(
            try presentation(harness).focusArea, .refused(.noProfile),
            "Das Profil der beendeten Sitzung darf nicht als aktuell gelten"
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 2 }

        guard case .focused = try presentation(harness).focusArea else {
            harness.coordinator.disconnect()
            return XCTFail("Nach dem ersten Profil der neuen Sitzung ist Fokus wieder möglich")
        }

        harness.coordinator.disconnect()
    }

    // MARK: - Fokusprofil endet sofort mit der ausdrücklichen Sitzung (K2)

    /// **Der Supervisor-Befund aus K1, jetzt geschlossen**
    /// (`review-sick-032c3a-k1.md`): Zwischen dem ausdrücklichen
    /// `disconnect()` und dem tatsächlichen, asynchronen `close(2)` auf
    /// dem Lesethread lag ein Zeitfenster, in dem die **logische**
    /// Messsitzung bereits beendet war, das Fokusprofil aber noch stand
    /// -- ein neu gestarteter Entwurf hätte darauf fokussieren können,
    /// obwohl die Sitzung schon vorbei war. `closeDelaySeconds` macht
    /// dieses Fenster für den Test **zuverlässig** offen, statt sich auf
    /// einen zufälligen Thread-Schedule zu verlassen (Pflichtnachweis 2).
    ///
    /// Pflichtnachweis 1, vollständig: Profil empfangen -> ausdrücklicher
    /// Disconnect -> **vor** dem Port-Release neuen Draft starten ->
    /// beide Anfragearten bleiben verweigert und der automatische
    /// Erstfokus bleibt ausstehend -> nach dem späteren Release gilt
    /// dasselbe -> erst das erste Profil der neuen Sitzung fokussiert.
    func testFocusProfileIsInvalidatedImmediatelyOnExplicitDisconnectBeforePortRelease() throws {
        let firstSessionProfile = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let secondSessionProfile = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = CoordinatorHarness(descriptors: [
            FakeSerialPortFileDescriptor(
                readScript: [.bytes(firstSessionProfile), .timeout], closeDelaySeconds: 0.3
            ),
            FakeSerialPortFileDescriptor(
                readScript: [.bytes(secondSessionProfile)] + Array(repeating: .timeout, count: 80)
            )
        ])

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }

        harness.coordinator.disconnect()
        // Der Übergang wird sofort markiert (SICK-030a1) -- das echte
        // `close(2)` steht wegen `closeDelaySeconds` noch aus, das Fenster
        // ist damit für die folgenden Zusicherungen offen.
        XCTAssertTrue(
            harness.coordinator.isAwaitingPortRelease,
            "Testvoraussetzung: das echte Release steht noch aus"
        )

        // Vor dem Port-Release: ein neuer Entwurf.
        XCTAssertEqual(harness.coordinator.startLearnDraft(role: .filter), .started)

        XCTAssertEqual(
            harness.coordinator.learnDraftFocusArea(within: .fullField), .refused(.noProfile),
            "Das Profil der bereits ausdrücklich beendeten Sitzung darf nicht als aktuell gelten"
        )
        XCTAssertEqual(
            harness.coordinator.resolveLearnDraftFocus(.measurementAvailable), .nothingToFocus(.noProfile)
        )
        XCTAssertTrue(
            harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true,
            "Eine Verweigerung lässt den automatischen Erstfokus ausstehend"
        )
        XCTAssertEqual(
            harness.coordinator.resolveLearnDraftFocus(.explicitFitRequested), .nothingToFocus(.noProfile)
        )
        XCTAssertTrue(
            harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true
        )

        // Nach dem tatsächlichen Release gilt dasselbe -- bis zum ersten
        // Profil der neuen Sitzung.
        waitUntil { !harness.coordinator.isAwaitingPortRelease }
        XCTAssertEqual(
            harness.coordinator.learnDraftFocusArea(within: .fullField), .refused(.noProfile)
        )

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 2 }

        guard case .focus = harness.coordinator.resolveLearnDraftFocus(.measurementAvailable) else {
            harness.coordinator.disconnect()
            return XCTFail("Das erste Profil der neuen Sitzung fokussiert wieder automatisch")
        }

        harness.coordinator.disconnect()
    }

    /// Regel 4 des K2-Auftrags: Ein `disconnect()` **ohne** gehaltenen
    /// Port darf einen nur armierten Draft nicht beenden -- keine neue
    /// Seiteneffektregel. Das Fokusprofil ist in diesem Zustand ohnehin
    /// nicht aktuell (nie verbunden gewesen).
    func testDisconnectWithoutAHeldPortLeavesAMerelyArmedDraftUntouched() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        XCTAssertFalse(harness.coordinator.session.isPortHeld, "Testvoraussetzung: nie verbunden")
        XCTAssertEqual(harness.coordinator.startLearnDraft(role: .filter), .started)

        harness.coordinator.disconnect()

        XCTAssertEqual(try presentation(harness).phase, .waitingForProfiles, "Der Entwurf sammelt unverändert weiter")
        XCTAssertEqual(
            harness.coordinator.learnDraftFocusArea(within: .fullField), .refused(.noProfile)
        )
    }

    // MARK: - Profil mit ausschließlich unbrauchbaren Werten (K2, Pflichtnachweis 3)

    /// **Die in K1 fehlende Nachweislücke**, jetzt geschlossen
    /// (`review-sick-032c3a-k1.md`, „Nachweislücke aus K1"): ein
    /// vorliegendes, aktuelles Profil, dessen Messwerte ausschließlich
    /// unbrauchbar sind (`0`, außerhalb `lowestUsableRawValue
    /// ...highestUsableRawValue`), verbraucht **weder** bei
    /// automatischer **noch** bei ausdrücklicher Anfrage den
    /// Fokuszustand. Ein späteres brauchbares Profil derselben gültigen
    /// Sitzung fokussiert danach automatisch genau einmal.
    func testAProfileWithOnlyUnusableValuesDoesNotConsumeTheFocusStateAndALaterUsableProfileStillFocusesOnce() throws {
        let unusableProfile = try b0FrameBytes(measurements: Array(repeating: 0, count: 10))
        let usableProfile = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = CoordinatorHarness(descriptors: [
            FakeSerialPortFileDescriptor(
                readScript: [.bytes(unusableProfile), .timeout, .bytes(usableProfile)]
                    + Array(repeating: .timeout, count: 80)
            )
        ])
        harness.coordinator.startLearnDraft(role: .filter)
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }

        XCTAssertEqual(
            harness.coordinator.learnDraftFocusArea(within: .fullField), .refused(.noUsableMeasurement)
        )
        XCTAssertEqual(
            harness.coordinator.resolveLearnDraftFocus(.measurementAvailable),
            .nothingToFocus(.noUsableMeasurement)
        )
        XCTAssertTrue(
            harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true,
            "Ein unbrauchbares Profil sperrt und verbraucht den automatischen Erstfokus nicht"
        )
        XCTAssertEqual(
            harness.coordinator.resolveLearnDraftFocus(.explicitFitRequested),
            .nothingToFocus(.noUsableMeasurement)
        )
        XCTAssertTrue(
            harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true
        )

        waitUntil { harness.coordinator.deliveredProfileBatches >= 2 }

        guard case .focus = harness.coordinator.resolveLearnDraftFocus(.measurementAvailable) else {
            harness.coordinator.disconnect()
            return XCTFail("Ein späteres brauchbares Profil derselben Sitzung fokussiert automatisch")
        }
        XCTAssertFalse(harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true)

        harness.coordinator.disconnect()
    }

    // MARK: - Sperrgrund in der Präsentation (K1, Pflichtnachweis 2)

    /// Ein **beendeter** Entwurf bleibt lesbar, während eine daneben
    /// armierte, sammelnde Zone einen Neustart benannt sperrt --
    /// spiegelbildlich zu `CoordinatorZoneLearningControlTests.testACollectingDraftBlocksArmingAndLeavesTheDraftUntouched`.
    func testACollectingZoneLearningSessionBlocksRestartInThePresentation() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        harness.coordinator.startLearnDraft(role: .filter)
        harness.coordinator.cancelLearnDraft()
        guard case .cancelled = try presentation(harness).phase else {
            return XCTFail("Testvoraussetzung: der Entwurf ist bereits beendet")
        }

        var state = harness.coordinator.editorState
        // `addZone` wählt die neue Zone sofort aus (SICK-014).
        let zoneID = state.addZone(CoordinatorHarness.zone(role: .gate, index: 0.25...0.75))
        harness.coordinator.editorState = state
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        let shown = try presentation(harness)
        XCTAssertEqual(shown.block, .zoneLearningIsCollecting(zoneID: zoneID))
        XCTAssertFalse(shown.canStart)
        XCTAssertEqual(shown.phase, .cancelled(.operatorCancelled), "Das beendete Ergebnis bleibt lesbar")
    }

    // MARK: - Zurückweisung, Abbruch, Löschen ändern nie ``zones``

    func testDiscardingACollectingDraftCreatesNoZone() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        let before = harness.coordinator.editorState.zones.count
        harness.coordinator.startLearnDraft(role: .filter)

        harness.coordinator.discardLearnDraft()

        XCTAssertNil(harness.coordinator.learnDraftPresentation)
        XCTAssertEqual(harness.coordinator.editorState.zones.count, before)
    }

    func testCancellingACollectingDraftCreatesNoZone() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        let before = harness.coordinator.editorState.zones.count
        harness.coordinator.startLearnDraft(role: .filter)

        harness.coordinator.cancelLearnDraft()

        XCTAssertEqual(try presentation(harness).phase, .cancelled(.operatorCancelled))
        XCTAssertEqual(harness.coordinator.editorState.zones.count, before)
    }

    // MARK: - Rückmeldung des Bedienschritts (SICK-032c3b, Pflichtnachweis 1)
    //
    // **Ein eigenes Feld** (``ScannerWorkspaceModel/learnDraftNotice``),
    // getrennt von ``ScannerWorkspaceModel/zoneLearningNotice`` --
    // beide Karten können gleichzeitig sichtbar sein und dürfen sich
    // nicht gegenseitig überschreiben.

    func testStartingADraftPublishesASuccessNotice() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        XCTAssertNil(harness.coordinator.learnDraftNotice)

        XCTAssertEqual(harness.coordinator.startLearnDraft(role: .pitch), .started)

        let notice = try XCTUnwrap(harness.coordinator.learnDraftNotice)
        XCTAssertTrue(notice.isSuccess)
    }

    /// Ein zweiter Start während einer laufenden Sammlung ist **benannt
    /// verweigert**, und der laufende Entwurf bleibt unangetastet.
    func testASecondStartWhileCollectingIsNamedAndLeavesTheRunningDraftUntouched() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        harness.coordinator.startLearnDraft(role: .pitch)
        let roleBefore = try presentation(harness).role

        let outcome = harness.coordinator.startLearnDraft(role: .filter)

        XCTAssertEqual(outcome, .alreadyDrafting)
        let notice = try XCTUnwrap(harness.coordinator.learnDraftNotice)
        XCTAssertFalse(notice.isSuccess)
        XCTAssertEqual(try presentation(harness).role, roleBefore, "Der laufende Entwurf bleibt unangetastet")
    }

    /// Ein Start, der an einer parallel sammelnden, bereits vorhandenen
    /// Zone scheitert (SICK-032c3a-K1), ist ebenfalls benannt verweigert.
    func testAStartBlockedByACollectingZoneLearningSessionIsNamed() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        var state = harness.coordinator.editorState
        let zoneID = state.addZone(CoordinatorHarness.zone(role: .gate, index: 0.25...0.75))
        harness.coordinator.editorState = state
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed)

        let outcome = harness.coordinator.startLearnDraft(role: .pitch)

        XCTAssertEqual(outcome, .blockedByZoneLearning(zoneID: zoneID))
        let notice = try XCTUnwrap(harness.coordinator.learnDraftNotice)
        XCTAssertFalse(notice.isSuccess)
        XCTAssertNil(harness.coordinator.learnDraftPresentation, "Es entstand kein Entwurf")
    }

    func testFinishCancelAndDiscardClearTheDraftNotice() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        harness.coordinator.startLearnDraft(role: .pitch)
        XCTAssertNotNil(harness.coordinator.learnDraftNotice)

        harness.coordinator.finishLearnDraft()
        XCTAssertNil(harness.coordinator.learnDraftNotice)

        harness.coordinator.startLearnDraft(role: .pitch)
        XCTAssertNotNil(harness.coordinator.learnDraftNotice)
        harness.coordinator.cancelLearnDraft()
        XCTAssertNil(harness.coordinator.learnDraftNotice)

        harness.coordinator.startLearnDraft(role: .pitch)
        harness.coordinator.cancelLearnDraft()
        XCTAssertNotNil(try presentation(harness))
        harness.coordinator.discardLearnDraft()
        XCTAssertNil(harness.coordinator.learnDraftNotice)
    }

    func testApplyingADraftPublishesASuccessNoticeAndApplyingWithoutOnePublishesNotDrafting() throws {
        let harness = harness(reading: try learnableScript())
        harness.coordinator.startLearnDraft(role: .filter)
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }
        harness.coordinator.finishLearnDraft()

        guard case .applied = harness.coordinator.applyLearnDraftCandidate() else {
            harness.coordinator.disconnect()
            return XCTFail("Testvoraussetzung: die Übernahme gelingt")
        }
        let successNotice = try XCTUnwrap(harness.coordinator.learnDraftNotice)
        XCTAssertTrue(successNotice.isSuccess)

        XCTAssertEqual(harness.coordinator.applyLearnDraftCandidate(), .notDrafting)
        let failureNotice = try XCTUnwrap(harness.coordinator.learnDraftNotice)
        XCTAssertFalse(failureNotice.isSuccess)

        harness.coordinator.disconnect()
    }

    // MARK: - Vollständige Folge (Pflichtnachweis 7)
    //
    // Auto-Fokus -> manuelle Navigation -> explizites Einpassen ->
    // Vorschau -> Übernahme, ausschließlich über die produktive Grenze
    // (``resolveLearnDraftFocus(_:within:)``). Profil, Kandidat und
    // fachliche Zonengrenzen bleiben dabei bitgleich -- nur der
    // zurückgegebene Ausschnitt und, beim letzten Schritt, die Zonenliste
    // ändern sich.
    func testAFullSequenceFromAutomaticFocusThroughManualNavigationAndExplicitFitToCommitLeavesProfileAndCandidateBitIdentical() throws {
        let harness = harness(reading: try learnableScript())
        harness.coordinator.startLearnDraft(role: .filter)
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)

        // (1) Automatischer Fokus auf das erste brauchbare Profil. Die
        // Fokusrechnung selbst liest nur -- sie verbraucht und verändert
        // kein Profil (Vergleich unmittelbar vor/nach demselben Aufruf,
        // ohne dass dazwischen ein neues echtes Profil eintreffen kann).
        waitUntil { harness.coordinator.deliveredProfileBatches >= 1 }
        let profileBeforeFirstFocus = harness.coordinator.session.state.lastProfile
        let firstOutcome = harness.coordinator.resolveLearnDraftFocus(.measurementAvailable, within: .fullField)
        guard case .focus(let firstResult) = firstOutcome else {
            harness.coordinator.disconnect()
            return XCTFail("Erwartet: automatischer Fokus, bekommen: \(firstOutcome)")
        }
        XCTAssertEqual(harness.coordinator.session.state.lastProfile, profileBeforeFirstFocus)

        // (2) Manuelle Navigation sperrt jede weitere Automatik --
        // unbedingt, ohne selbst einen Ausschnitt zu berechnen oder das
        // Profil anzufassen.
        XCTAssertEqual(
            harness.coordinator.resolveLearnDraftFocus(.manualNavigation, within: firstResult.viewport), .doNothing
        )
        XCTAssertFalse(harness.coordinator.editorState.learnDraft?.focus.isAutomaticFocusStillPending == true)
        XCTAssertEqual(harness.coordinator.session.state.lastProfile, profileBeforeFirstFocus)

        // Weitere echte Profile treffen ein (das Sammeln braucht sie) und
        // lösen -- weil gesperrt -- keinen Auto-Fokus mehr aus.
        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }
        let profileBeforeSecondFocus = harness.coordinator.session.state.lastProfile
        XCTAssertEqual(
            harness.coordinator.resolveLearnDraftFocus(.measurementAvailable, within: firstResult.viewport), .doNothing
        )
        XCTAssertEqual(harness.coordinator.session.state.lastProfile, profileBeforeSecondFocus)

        // (3) Explizites Einpassen wirkt weiterhin, auch nach der Sperre --
        // und liest ebenfalls nur, ohne das laufende Profil zu verändern.
        let secondOutcome = harness.coordinator.resolveLearnDraftFocus(.explicitFitRequested, within: firstResult.viewport)
        guard case .focus(let secondResult) = secondOutcome else {
            harness.coordinator.disconnect()
            return XCTFail("Erwartet: erfolgreiches Einpassen, bekommen: \(secondOutcome)")
        }
        XCTAssertEqual(harness.coordinator.session.state.lastProfile, profileBeforeSecondFocus)

        // (4) Vorschau: das Sammeln beenden und den Kandidaten lesen.
        harness.coordinator.finishLearnDraft()
        let candidateBeforeApply = try presentation(harness).phase.candidateZone
        XCTAssertNotNil(candidateBeforeApply)

        // (5) Übernahme.
        let applyOutcome = harness.coordinator.applyLearnDraftCandidate()
        guard case .applied(_, let writtenZone) = applyOutcome else {
            harness.coordinator.disconnect()
            return XCTFail("Übernehmen wurde abgelehnt: \(applyOutcome)")
        }

        // Die fachlichen Zonengrenzen sind exakt die des zuvor gelesenen
        // Kandidaten -- die Fokusfolge hat sie nicht verändert.
        XCTAssertEqual(writtenZone, candidateBeforeApply)
        // Die beiden Fokusausschnitte selbst dürfen sich unterscheiden --
        // genau das ist der einzige erlaubte Unterschied dieser Folge.
        XCTAssertNotEqual(firstResult.viewport, secondResult.viewport)

        harness.coordinator.disconnect()
    }

    // MARK: - Sichtbarer Hinweis-Host über die Draft-Lebensdauer hinaus
    // (SICK-032c3b-K1, Abnahmeblocker 1, Pflichtnachweis 1)
    //
    // Diese vier Tests belegen am **produktiven** Weg (echter Koordinator,
    // echte ``ZoneEditorState``, echte `RXSession`), dass
    // ``ScannerWorkspaceModel/learnDraftSurface`` den Hinweis
    // genau dort trägt, wo eine Oberfläche ihn tatsächlich zeigen würde --
    // nicht nur, dass ``ScannerWorkspaceModel/learnDraftNotice``
    // gesetzt ist (das belegten schon die Tests oben).

    /// **Pflichtnachweis 1, erster Fall:** Ein bereits sammelndes
    /// zonengebundenes Learn verweigert `+ Zone` benannt; es existiert
    /// kein vorzonaler Draft, und der negative Hinweis ist dennoch über
    /// den Fallback-Host sichtbar -- nicht nur im gespeicherten Feld.
    func testARefusalWithoutAnyDraftIsVisibleThroughTheFallbackHost() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        var state = harness.coordinator.editorState
        let zoneID = state.addZone(CoordinatorHarness.zone(role: .gate, index: 0.25...0.75))
        harness.coordinator.editorState = state
        XCTAssertEqual(harness.coordinator.startZoneLearning(), .armed, "Testvoraussetzung: ein sammelndes Learn")

        let outcome = harness.coordinator.addZone(role: .pitch)

        XCTAssertEqual(outcome, .blockedByZoneLearning(zoneID: zoneID), "Benannt verweigert, kein stilles Nichtstun")
        XCTAssertNil(harness.coordinator.learnDraftPresentation, "Testvoraussetzung: es existiert kein Draft")

        let surface = harness.coordinator.learnDraftSurface
        XCTAssertNil(surface.presentation)
        XCTAssertNil(surface.cardNotice, "Es gibt keine Karte, die ihn zeigen könnte")
        let hosted = try XCTUnwrap(surface.hostedNotice, "Der Hinweis muss ohne Draft trotzdem gehostet sein")
        XCTAssertFalse(hosted.isSuccess)
        XCTAssertEqual(hosted, LearnDraftStartOutcome.blockedByZoneLearning(zoneID: zoneID).notice)
    }

    /// **Pflichtnachweis 1, zweiter Fall:** Nach erfolgreicher Übernahme
    /// ist der Draft verschwunden, die ausgeschaltete echte Zone
    /// vorhanden, und der Erfolgshinweis bleibt über den Fallback-Host
    /// sichtbar.
    func testASuccessfulApplyLeavesTheSuccessNoticeVisibleThroughTheFallbackHostAfterTheDraftIsGone() throws {
        let harness = harness(reading: try learnableScript())
        let zonesBefore = harness.coordinator.editorState.zones.count
        harness.coordinator.startLearnDraft(role: .filter)
        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches >= 8 }
        harness.coordinator.finishLearnDraft()
        guard try presentation(harness).phase.candidateZone != nil else {
            harness.coordinator.disconnect()
            return XCTFail("Testvoraussetzung: ein Vorschlag liegt vor")
        }

        guard case .applied(let id, _) = harness.coordinator.applyLearnDraftCandidate() else {
            harness.coordinator.disconnect()
            return XCTFail("Testvoraussetzung: die Übernahme gelingt")
        }
        harness.coordinator.disconnect()

        XCTAssertNil(harness.coordinator.learnDraftPresentation, "Der Draft ist verschwunden")
        XCTAssertEqual(harness.coordinator.editorState.zones.count, zonesBefore + 1)
        let inserted = try XCTUnwrap(harness.coordinator.zoneInserts.first { $0.id == id })
        XCTAssertEqual(inserted.activation, .off, "Auflage D2: die neue Zone bleibt ausgeschaltet")

        let surface = harness.coordinator.learnDraftSurface
        XCTAssertNil(surface.presentation)
        XCTAssertNil(surface.cardNotice)
        let hosted = try XCTUnwrap(
            surface.hostedNotice, "Der Erfolgshinweis muss den verschwundenen Draft überleben"
        )
        XCTAssertTrue(hosted.isSuccess)
    }

    /// **Pflichtnachweis 1, dritter Fall:** Bei bestehendem Draft
    /// erscheint derselbe Hinweis nicht in zwei Hosts -- nur die Karte,
    /// nie zusätzlich der Fallback-Host.
    func testWithAnExistingDraftTheNoticeAppearsOnlyInTheCardNeverAlsoInTheFallbackHost() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))

        XCTAssertEqual(harness.coordinator.startLearnDraft(role: .pitch), .started)

        let surface = harness.coordinator.learnDraftSurface
        XCTAssertNotNil(surface.presentation, "Testvoraussetzung: ein Draft läuft")
        XCTAssertNotNil(surface.cardNotice, "Der Starterfolg soll in der Karte erscheinen")
        XCTAssertNil(surface.hostedNotice, "Nicht zusätzlich im Fallback-Host")
    }

    /// **Pflichtnachweis:** Die bestehende Lösch-/Ersetzungssemantik bei
    /// der nächsten Draftaktion bleibt erhalten -- ein `finishLearnDraft()`
    /// leert `learnDraftNotice`, und der Schnappschuss spiegelt das in
    /// beiden Slots sofort.
    func testTheNextDraftActionClearsTheNoticeFromWhicheverHostShowedIt() throws {
        let harness = harness(reading: Array(repeating: .timeout, count: 10))
        harness.coordinator.startLearnDraft(role: .pitch)
        XCTAssertNotNil(harness.coordinator.learnDraftSurface.cardNotice, "Testvoraussetzung: die Karte zeigt ihn")

        harness.coordinator.finishLearnDraft()

        let surfaceAfterFinish = harness.coordinator.learnDraftSurface
        XCTAssertNil(surfaceAfterFinish.cardNotice, "Der nächste Schritt ersetzt den Hinweis -- hier durch nichts")
        XCTAssertNil(surfaceAfterFinish.hostedNotice)
    }

    // MARK: - Echte Gegenprobe (Pflichtnachweis 3)
    //
    // Diese eine Zeile beschreibt die Gegenprobe, die tatsächlich am
    // Quelltext durchgeführt wurde (siehe Rücklauf-Dokumentation) --
    // ``LearnDraftSurface/hostedNotice`` probeweise auf `nil` gesetzt
    // (die Fallback-Host-Entscheidung entfernt) ließ
    // `testARefusalWithoutAnyDraftIsVisibleThroughTheFallbackHost` und
    // `testASuccessfulApplyLeavesTheSuccessNoticeVisibleThroughTheFallbackHostAfterTheDraftIsGone`
    // erwartungsgemäß fehlschlagen; danach byteidentisch wiederhergestellt.
}
