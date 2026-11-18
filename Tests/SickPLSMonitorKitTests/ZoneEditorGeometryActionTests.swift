import XCTest
import CoreGraphics
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// SICK-030b2, Auftragspunkt 4: die Einbindung des Reducers in den
/// Editorzustand — eine Wahrheit, sichtbare Ablehnungen und nichts
/// darüber hinaus.
final class ZoneEditorGeometryActionTests: XCTestCase {

    private let fan = FanScreenGeometry(
        center: .zero, radius: 1000, startAngleRadians: 0, endAngleRadians: .pi
    )

    /// Seit SICK-032b3 läuft der Bearbeitungsweg über die **lineare**
    /// Ansichtsgeometrie; die Fächerplatzierung steckt darin.
    private var geometry: LinearScanFieldGeometry {
        LinearScanFieldGeometry(fan: fan, viewport: .fullField)
    }

    private func zone(
        index: ClosedRange<Double> = 0.3...0.7,
        value: ClosedRange<UInt16> = 1000...4000,
        role: ZoneRole = .pitch
    ) throws -> Zone {
        try Zone.build(
            indexLowerBound: index.lowerBound, indexUpperBound: index.upperBound,
            valueLowerBound: value.lowerBound, valueUpperBound: value.upperBound,
            role: role
        )
    }

    private func screenPoint(index: Double, value: UInt16) -> CGPoint {
        geometry.project(
            angleFraction: index,
            radiusFraction: Double(value) / PolarProfileGeometry.maxRawMeasurementValue
        ).screenPoint
    }

    private func measurement(_ value: UInt16) throws -> B0ScanProfile.Measurement {
        try B0ScanProfile.Measurement.build(value: value, fieldFlags: 0)
    }

    /// Ein Zustand mit genau einer, bereits ausgewählten Zone.
    private func state(with zone: Zone) -> (ZoneEditorState, EditableZone.ID) {
        var state = ZoneEditorState()
        let id = state.addZone(zone)
        return (state, id)
    }

    private func start(
        _ id: EditableZone.ID, _ zone: Zone, at point: CGPoint
    ) -> ZoneGeometryGestureStart {
        ZoneGeometryGestureStart(zoneID: id, zone: zone, location: point)
    }

    // MARK: - Die Geste schreibt in die eine Wahrheit

    func testAGestureWritesTheNewZoneStraightIntoTheZoneList() throws {
        let original = try zone()
        var (state, id) = state(with: original)

        let outcome = state.applyGeometryGesture(
            .moveWholeZone,
            from: start(id, original, at: screenPoint(index: 0.5, value: 2000)),
            toScreenPoint: screenPoint(index: 0.6, value: 2000),
            in: geometry
        )

        guard case .applied(let applied) = outcome else {
            return XCTFail("Erwartet: angewandt, bekommen: \(outcome)")
        }
        XCTAssertEqual(state.zones.first?.zone, applied, "Genau das, was gemeldet wurde")
        XCTAssertEqual(state.zones.first?.zone.indexRange.lowerBound ?? 0, 0.4, accuracy: 1e-9)
    }

    /// **Keine Delta-Akkumulation am Zustand** (Auftragspunkt 2): Eine
    /// laufende Geste schreibt fortlaufend nach `zones[i].zone`. Würde
    /// der nächste Schritt seine Ausgangswerte von dort statt aus der
    /// Momentaufnahme nehmen, wanderte die Zone bei jedem Ereignis ein
    /// weiteres Mal um dieselbe Strecke.
    func testRepeatedEventsOfOneGestureLandOnTheSameZone() throws {
        let original = try zone()
        var (state, id) = state(with: original)
        let gestureStart = start(id, original, at: screenPoint(index: 0.5, value: 2000))
        let destination = screenPoint(index: 0.6, value: 2600)

        state.applyGeometryGesture(.moveWholeZone, from: gestureStart, toScreenPoint: destination, in: geometry)
        let afterFirst = try XCTUnwrap(state.zones.first?.zone)

        // Dieselbe Geste, dieselbe Momentaufnahme, weitere Ereignisse --
        // auch mit Zwischenpunkten dazwischen.
        for intermediate in [0.55, 0.58, 0.52, 0.6] {
            state.applyGeometryGesture(
                .moveWholeZone, from: gestureStart,
                toScreenPoint: screenPoint(index: intermediate, value: 2600), in: geometry
            )
        }
        state.applyGeometryGesture(.moveWholeZone, from: gestureStart, toScreenPoint: destination, in: geometry)

        XCTAssertEqual(state.zones.first?.zone, afterFirst, "Die Zone wandert nicht mit jedem Ereignis weiter")
    }

    func testRepeatedHandleEventsOfOneGestureLandOnTheSameBound() throws {
        let original = try zone()
        var (state, id) = state(with: original)
        let gestureStart = start(id, original, at: screenPoint(index: 0.7, value: 2000))
        let destination = screenPoint(index: 0.85, value: 2000)

        for _ in 0..<5 {
            state.applyGeometryGesture(
                .handle(.indexUpperBound), from: gestureStart, toScreenPoint: destination, in: geometry
            )
        }

        XCTAssertEqual(
            state.zones.first?.zone.indexRange.upperBound ?? 0, 0.85, accuracy: 1e-9,
            "0,7 + 0,15 -- einmal, nicht fünfmal"
        )
    }

    /// Auflage **D3**: Jede direkte Änderung leitet den offenen Entwurf
    /// neu aus der gespeicherten Zone ab, statt zwei Stände zu mischen.
    func testTheOpenDraftIsRederivedFromTheStoredZone() throws {
        let original = try zone()
        var (state, id) = state(with: original)

        // Ein halb getippter, noch nicht übernommener Eingabewert.
        var typed = ZoneDraft(zone: original)
        typed.valueUpperBound = 7777
        state.updateDraft(typed)
        XCTAssertEqual(state.draft?.valueUpperBound, 7777, "Testvoraussetzung")

        state.applyGeometryGesture(
            .handle(.indexUpperBound),
            from: start(id, original, at: screenPoint(index: 0.7, value: 2000)),
            toScreenPoint: screenPoint(index: 0.8, value: 2000),
            in: geometry
        )

        let stored = try XCTUnwrap(state.zones.first?.zone)
        XCTAssertEqual(state.draft, ZoneDraft(zone: stored), "Entwurf == gespeicherte Zone")
        XCTAssertEqual(state.draft?.valueUpperBound, 4000, "Der ungespeicherte Tippwert verfällt sichtbar")
    }

    func testAGestureOnAnUnselectedZoneLeavesTheDraftEmpty() throws {
        let original = try zone()
        var (state, id) = state(with: original)
        state.select(nil)
        XCTAssertNil(state.draft, "Testvoraussetzung")

        state.applyGeometryGesture(
            .moveWholeZone,
            from: start(id, original, at: screenPoint(index: 0.5, value: 2000)),
            toScreenPoint: screenPoint(index: 0.55, value: 2000),
            in: geometry
        )

        XCTAssertNil(state.draft, "Eine Geste wählt nichts aus")
        XCTAssertNil(state.selectedZoneID)
    }

    // MARK: - Sichtbare Ablehnungen, unveränderter Zustand

    func testAnUnknownZoneIDIsRejectedAndChangesNothing() throws {
        let original = try zone()
        var (state, _) = state(with: original)
        let before = state

        let outcome = state.applyGeometryGesture(
            .moveWholeZone,
            from: start(UUID(), original, at: screenPoint(index: 0.5, value: 2000)),
            toScreenPoint: screenPoint(index: 0.9, value: 6000),
            in: geometry
        )

        XCTAssertEqual(outcome, .unknownZone)
        XCTAssertEqual(state, before, "Der Zustand bleibt vollständig unverändert")
    }

    func testANonFiniteGestureValueIsRejectedAndChangesNothing() throws {
        let original = try zone()
        var (state, id) = state(with: original)
        let before = state

        let outcome = state.applyGeometryGesture(
            .moveWholeZone,
            from: start(id, original, at: screenPoint(index: 0.5, value: 2000)),
            toScreenPoint: CGPoint(x: CGFloat.nan, y: 12),
            in: geometry
        )

        XCTAssertEqual(outcome, .rejected(.nonFiniteGestureValue))
        XCTAssertEqual(state, before)
    }

    func testDegenerateFanGeometryIsRejectedAndChangesNothing() throws {
        let original = try zone()
        var (state, id) = state(with: original)
        let before = state

        let outcome = state.applyGeometryGesture(
            .moveWholeZone,
            from: start(id, original, at: .zero),
            toScreenPoint: CGPoint(x: 10, y: 10),
            in: LinearScanFieldGeometry(
                fan: FanScreenGeometry(center: .zero, radius: 0, startAngleRadians: 0, endAngleRadians: .pi),
                viewport: .fullField
            )
        )

        XCTAssertEqual(outcome, .rejected(.degenerateFanGeometry))
        XCTAssertEqual(state, before)
    }

    // MARK: - Was die Geste nicht anfasst (Auftragspunkt 5)

    func testAGestureChangesNeitherIdentityNorActivationNorRole() throws {
        let original = try zone(role: .gate)
        var (state, id) = state(with: original)
        state.setZone(id, isEnabled: true)

        state.applyGeometryGesture(
            .handle(.valueOuterBound),
            from: start(id, original, at: screenPoint(index: 0.5, value: 4000)),
            toScreenPoint: screenPoint(index: 0.5, value: 6000),
            in: geometry
        )

        let editable = try XCTUnwrap(state.zones.first)
        XCTAssertEqual(editable.id, id, "Die Identität bleibt")
        XCTAssertTrue(editable.isEnabled, "Die Aktivierung bleibt")
        XCTAssertEqual(editable.zone.role, .gate, "Die Rolle bleibt")
    }

    func testAGestureNeverActivatesADisabledZone() throws {
        let original = try zone()
        var (state, id) = state(with: original)
        XCTAssertFalse(try XCTUnwrap(state.zones.first).isEnabled, "Testvoraussetzung (SICK-030b1)")

        for gesture in ZoneGeometryGesture.allGestures {
            state.applyGeometryGesture(
                gesture,
                from: start(id, original, at: screenPoint(index: 0.5, value: 2000)),
                toScreenPoint: screenPoint(index: 0.55, value: 2200),
                in: geometry
            )
            XCTAssertFalse(try XCTUnwrap(state.zones.first).isEnabled, "\(gesture)")
        }
    }

    func testAGestureLeavesEveryOtherZoneUntouched() throws {
        var state = ZoneEditorState()
        let first = try zone(index: 0.0...0.2, role: .volume)
        let second = try zone(index: 0.3...0.7, role: .pitch)
        let firstID = state.addZone(first)
        let secondID = state.addZone(second)

        state.applyGeometryGesture(
            .moveWholeZone,
            from: start(secondID, second, at: screenPoint(index: 0.5, value: 2000)),
            toScreenPoint: screenPoint(index: 0.65, value: 3000),
            in: geometry
        )

        XCTAssertEqual(state.zones.first?.id, firstID)
        XCTAssertEqual(state.zones.first?.zone, first, "Die andere Zone ist unangetastet")
        XCTAssertNotEqual(state.zones.last?.zone, second, "Testvoraussetzung: die gezogene hat sich geändert")
    }

    /// Die Live-Anzeige bewertet unverändert **jede** Zone, und zwar mit
    /// den neuen Grenzen — eine Geste verändert daran nur, was sie
    /// verändern soll.
    func testTheLiveEvaluationUsesTheNewBoundsImmediately() throws {
        let original = try zone(index: 0.0...0.4, value: 1000...4000)
        var (state, id) = state(with: original)
        let profile = try B0ScanProfile.build(
            partialScanIndex: 0, measurements: [try measurement(2000), try measurement(2000)]
        )
        XCTAssertNotNil(state.evaluations(against: profile)[id])

        // Den Wertbereich so weit nach außen ziehen, dass 2000 herausfällt.
        state.applyGeometryGesture(
            .moveWholeZone,
            from: start(id, original, at: screenPoint(index: 0.2, value: 2000)),
            toScreenPoint: screenPoint(index: 0.2, value: 6000),
            in: geometry
        )

        XCTAssertEqual(state.evaluations(against: profile)[id], .inactive)
    }
}
