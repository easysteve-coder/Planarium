import PlanariumInput
import Combine
import Foundation
import XCTest
import SickPLSControlCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// SICK-032c1 am **produktiven Weg**: echter Zoneneditor, echter
/// Controller, echte `RXSession` mit echtem Hintergrund-Thread und
/// echtem Framing — gefälscht sind nur Dateideskriptor und Audiohost.
///
/// **Keine SwiftUI-Ansicht.** Die Inserts und ihre Karte bedienen
/// ausschließlich Methoden des Koordinators; genau die werden hier
/// gerufen. Ein Test, der eine Ansicht aufbaute, bewiese nur, dass
/// *dieser* Renderdurchlauf stattfand.
@MainActor final class CoordinatorZoneInsertTests: XCTestCase {

    private func harness(reading script: [SerialPortReadOutcome]) -> CoordinatorHarness {
        CoordinatorHarness(descriptors: [FakeSerialPortFileDescriptor(readScript: script)])
    }

    private func quietHarness() -> CoordinatorHarness {
        harness(reading: Array(repeating: .timeout, count: 20))
    }

    private func insert(
        _ id: EditableZone.ID, in harness: CoordinatorHarness
    ) throws -> ZoneInsertStatus {
        try XCTUnwrap(harness.coordinator.zoneInserts.first { $0.id == id })
    }

    /// Legt eine Zone **direkt** im Editorzustand an -- als reine
    /// Testvorrichtung für Fälle, die irgendeine ausgeschaltete Zone
    /// zum Bearbeiten brauchen, aber nicht das Anlegeverhalten selbst
    /// prüfen (SICK-032c3a: `coordinator.addZone(role:)` legt seither
    /// keine Zone mehr sofort an, siehe `CoordinatorLearnDraftTests`).
    @discardableResult
    private func addFixtureZone(
        _ harness: CoordinatorHarness, role: ZoneRole, index: ClosedRange<Double> = 0.25...0.75
    ) -> EditableZone.ID {
        var state = harness.coordinator.editorState
        let id = state.addZone(CoordinatorHarness.zone(role: role, index: index))
        harness.coordinator.editorState = state
        return id
    }

    // MARK: - Live heißt Messung (Anforderung 4)

    func testWithoutAnyProfileEveryInsertSaysNoMeasurement() throws {
        let harness = quietHarness()

        XCTAssertEqual(harness.coordinator.zoneInserts.count, 3)
        for insert in harness.coordinator.zoneInserts {
            XCTAssertEqual(insert.live, .noProfile)
            XCTAssertEqual(insert.live.label, "no measurement")
            XCTAssertFalse(insert.live.isHit)
        }
    }

    /// Der angezeigte Wert ist **bitgleich** die reine Auswertung des
    /// gerade vorliegenden Profils — keine Glättung, keine Prognose.
    func testTheLiveValueIsExactlyTheEvaluationOfTheCurrentProfile() throws {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = harness(reading: [.bytes(bytes)] + Array(repeating: .timeout, count: 40))

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.deliveredProfileBatches == 1 }

        let profile = try XCTUnwrap(harness.coordinator.session.state.lastProfile)
        for insert in harness.coordinator.zoneInserts {
            guard case .controlValue(let expected) = insert.zone.evaluate(against: profile) else {
                return XCTFail("Diese Zone sollte im Testprofil getroffen sein")
            }
            XCTAssertEqual(
                insert.live, .hit(expected),
                "Die Anzeige ist die Messung selbst, nicht eine abgeleitete Zahl"
            )
        }

        harness.coordinator.disconnect()
    }

    /// Ein echtes Profil, das keine Zone sieht, ist `notHit` — und
    /// ausdrücklich **nicht** `noProfile`.
    func testAProfileNoZoneSeesIsNotHitRatherThanNoProfile() throws {
        let bytes = try b0FrameBytes(measurements: measurementsSeenByNoZone())
        let harness = harness(reading: [.bytes(bytes)] + Array(repeating: .timeout, count: 40))

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.lastProfile != nil }

        for insert in harness.coordinator.zoneInserts {
            XCTAssertEqual(insert.live, .notHit)
            XCTAssertEqual(insert.live.label, "not hit")
        }

        harness.coordinator.disconnect()
    }

    /// Eine **ausgeschaltete** Zone wird weiter bewertet — sonst könnte
    /// man sie nicht einrichten, bevor man sie einschaltet (SICK-030b1).
    func testADisabledZoneStillShowsItsMeasurement() throws {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = harness(reading: [.bytes(bytes)] + Array(repeating: .timeout, count: 40))
        harness.coordinator.setZone(harness.pitchZoneID, isEnabled: false)

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.lastProfile != nil }

        let pitch = try insert(harness.pitchZoneID, in: harness)
        XCTAssertEqual(pitch.activation, .off)
        XCTAssertTrue(pitch.live.isHit, "Ausgeschaltet heißt nicht unbewertet")

        harness.coordinator.disconnect()
    }

    // MARK: - Drei getrennte Angaben (Anforderung 1)

    func testSelectionActivationAndHitAreThreeSeparateFacts() throws {
        let bytes = try b0FrameBytes(measurements: profileMeasurements(value: 3000))
        let harness = harness(reading: [.bytes(bytes)] + Array(repeating: .timeout, count: 40))

        harness.coordinator.connect(portPath: "/dev/cu.fake", baudRate: .baud9600)
        waitUntil { harness.coordinator.session.state.lastProfile != nil }

        harness.coordinator.selectZoneForEditing(harness.pitchZoneID)
        harness.coordinator.setZone(harness.pitchZoneID, isEnabled: false)

        let pitch = try insert(harness.pitchZoneID, in: harness)
        XCTAssertTrue(pitch.isSelected)
        XCTAssertEqual(pitch.activation, .off)
        XCTAssertTrue(pitch.live.isHit)

        let volume = try insert(harness.volumeZoneID, in: harness)
        XCTAssertFalse(volume.isSelected)
        XCTAssertEqual(volume.activation, .on)
        XCTAssertTrue(volume.live.isHit)

        // Keine der drei Angaben lässt sich aus einer anderen ableiten:
        // Hier unterscheiden sich Auswahl und Aktivierung, während der
        // Treffer für beide Zonen derselbe ist.
        XCTAssertNotEqual(pitch.isSelected, volume.isSelected)
        XCTAssertNotEqual(pitch.activation, volume.activation)
        XCTAssertEqual(pitch.live.isHit, volume.live.isHit)

        harness.coordinator.disconnect()
    }

    func testTheInsertsFollowTheEditorOrder() {
        let harness = quietHarness()
        XCTAssertEqual(
            harness.coordinator.zoneInserts.map(\.id),
            harness.coordinator.editorState.zones.map(\.id)
        )
    }

    // MARK: - Anlegen (SICK-032c3a: über einen Lernentwurf, keine Zone sofort)

    /// **Der Kernnachweis von SICK-032c3a, Pflichtnachweis 1:** Anlegen
    /// erzeugt keine `EditableZone` und insbesondere nicht die alten
    /// erfundenen Grenzen `1000...4000` -- es startet einen Entwurf.
    func testAddingANewZoneStartsALearnDraftInsteadOfCreatingAZone() throws {
        let harness = quietHarness()
        let before = harness.coordinator.zoneInserts.count

        XCTAssertEqual(harness.coordinator.addZone(role: .filter), .started)

        XCTAssertEqual(
            harness.coordinator.zoneInserts.count, before,
            "Anlegen erzeugt noch keine sichtbare Zone"
        )
        XCTAssertNil(harness.coordinator.zoneDraft, "Kein Kartenentwurf ohne Zone")
        let presentation = try XCTUnwrap(harness.coordinator.learnDraftPresentation)
        XCTAssertEqual(presentation.role, .filter)
        XCTAssertEqual(presentation.phase, .waitingForProfiles)
    }

    func testAddingANewZoneStartsNoAudioAndAssignsNoSlot() throws {
        let harness = quietHarness()
        let before = harness.coordinator.editorState.zones.count
        XCTAssertEqual(harness.coordinator.addZone(role: .gate), .started)

        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertFalse(harness.engine.isRunning)
        XCTAssertEqual(
            harness.coordinator.editorState.zones.count, before,
            "Ohne Übernahme entsteht keine Zone -- also auch kein neuer Slot-Kandidat"
        )
    }

    // MARK: - Aktivierung über den produktiven Pfad (Anforderung 3)

    func testSwitchingAnUnknownZoneIsRefusedAndChangesNothing() {
        let harness = quietHarness()
        let before = harness.coordinator.editorState.zones

        XCTAssertFalse(harness.coordinator.setZone(UUID(), isEnabled: true))
        XCTAssertFalse(harness.coordinator.removeZone(UUID()))
        XCTAssertEqual(harness.coordinator.editorState.zones, before)
    }

    // MARK: - Karte und Griffe sind eine Wahrheit (Anforderung 2)

    private static let cardGeometry = LinearScanFieldGeometry(
        fan: FanScreenGeometry(size: CGSize(width: 600, height: 600)),
        viewport: .fullField
    )

    private func handlePoint(
        _ handle: ZoneGeometryHandle, of zone: Zone
    ) throws -> CGPoint {
        let placed = ZoneHandleGeometry.placedHandles(for: zone, in: Self.cardGeometry)
        return try XCTUnwrap(placed.first { $0.handle == handle }).screenPoint
    }

    func testTheCardAndTheHandlesEditTheSameZone() throws {
        let harness = quietHarness()
        harness.coordinator.selectZoneForEditing(harness.pitchZoneID)

        // 1. Über die Karte: Entwurf ändern und übernehmen.
        var draft = try XCTUnwrap(harness.coordinator.zoneDraft)
        draft.indexUpperBound = 0.42
        harness.coordinator.updateZoneDraft(draft)
        XCTAssertEqual(
            try insert(harness.pitchZoneID, in: harness).zone.indexRange.upperBound, 0.3,
            "Ein Entwurf allein verändert die Zone nicht"
        )
        XCTAssertTrue(harness.coordinator.commitZoneDraft())
        XCTAssertEqual(
            try insert(harness.pitchZoneID, in: harness).zone.indexRange.upperBound, 0.42,
            accuracy: 1e-9
        )

        // 2. Über die Griffe: dieselbe Zone, derselbe Zustand.
        let zoneNow = try insert(harness.pitchZoneID, in: harness).zone
        let start = ZoneGeometryGestureStart(
            zoneID: harness.pitchZoneID,
            zone: zoneNow,
            location: try handlePoint(.indexUpperBound, of: zoneNow)
        )
        let target = Self.cardGeometry.project(angleFraction: 0.6, radiusFraction: 0.3).screenPoint
        let command = ZoneGeometryCommand(
            gesture: .handle(.indexUpperBound),
            start: start,
            location: target,
            geometry: Self.cardGeometry
        )

        guard case .applied(let moved) = harness.coordinator.applyZoneGeometry(command) else {
            return XCTFail("Die Geste hätte greifen müssen")
        }
        XCTAssertEqual(moved.indexRange.upperBound, 0.6, accuracy: 0.02)

        // 3. Die Karte zeigt danach genau das — der Entwurf wurde aus der
        //    einen Zonenwahrheit neu abgeleitet (Auflage D3), es gibt
        //    keinen zweiten Stand.
        let redrawn = try XCTUnwrap(harness.coordinator.zoneDraft)
        XCTAssertEqual(redrawn.indexUpperBound, moved.indexRange.upperBound)
        XCTAssertEqual(redrawn.indexLowerBound, moved.indexRange.lowerBound)
        XCTAssertEqual(redrawn.valueLowerBound, moved.valueRange.lowerBound)
        XCTAssertEqual(redrawn.valueUpperBound, moved.valueRange.upperBound)
        XCTAssertEqual(
            try insert(harness.pitchZoneID, in: harness).zone, moved,
            "Insert, Karte und Griffe zeigen denselben Zustand"
        )
    }

    func testEditingAZoneNeverActivatesItAndNeverAssignsASlot() throws {
        let harness = quietHarness()
        let newID = addFixtureZone(harness, role: .pitch)

        var draft = try XCTUnwrap(harness.coordinator.zoneDraft)
        draft.valueUpperBound = 5000
        harness.coordinator.updateZoneDraft(draft)
        harness.coordinator.commitZoneDraft()

        let zoneNow = try insert(newID, in: harness).zone
        let start = ZoneGeometryGestureStart(
            zoneID: newID,
            zone: zoneNow,
            location: try handlePoint(.valueOuterBound, of: zoneNow)
        )
        harness.coordinator.applyZoneGeometry(
            ZoneGeometryCommand(
                gesture: .moveWholeZone,
                start: start,
                location: Self.cardGeometry.project(angleFraction: 0.55, radiusFraction: 0.35).screenPoint,
                geometry: Self.cardGeometry
            )
        )

        let after = try insert(newID, in: harness)
        XCTAssertEqual(after.activation, .off)
        XCTAssertFalse(harness.root.audio.isRunning)
    }

    /// Auswählen ist Bedienung der Karte, keine Zuweisung: Es ändert
    /// weder Slot noch Aktivierung noch den Ton.
    func testSelectingAZoneChangesNothingButTheSelection() throws {
        let harness = quietHarness()
        let before = harness.coordinator.editorState.zones

        harness.coordinator.selectZoneForEditing(harness.gateZoneID)

        XCTAssertEqual(harness.coordinator.editorState.zones, before)
        XCTAssertFalse(harness.root.audio.isRunning)
        XCTAssertEqual(try insert(harness.gateZoneID, in: harness).activation, .on)
    }
}
