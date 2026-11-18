import XCTest
import CoreGraphics
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// SICK-032b3: die direkte Zonenbearbeitung im Scanfeld — Werkzeug-
/// trennung, eine Zonenwahrheit und die Grenzen, die eine Geste **nicht**
/// überschreitet.
///
/// Alle Tests laufen ohne gerenderte Ansicht, ohne Gerät und ohne
/// Scanner; gefahren wird die echte öffentliche Bedien-API von
/// ``ScanFieldViewState`` gegen einen echten ``ZoneEditorState``.
@MainActor final class ScanFieldZoneEditingTests: XCTestCase {

    private let size = CGSize(width: 800, height: 600)

    private func makeEditor(
        index: ClosedRange<Double> = 0.3...0.7,
        value: ClosedRange<UInt16> = 2000...6000,
        role: ZoneRole = .pitch
    ) throws -> (ZoneEditorState, EditableZone.ID) {
        var editor = ZoneEditorState()
        let id = editor.addZone(try Zone.build(
            indexLowerBound: index.lowerBound, indexUpperBound: index.upperBound,
            valueLowerBound: value.lowerBound, valueUpperBound: value.upperBound,
            role: role
        ))
        editor.select(id)
        return (editor, id)
    }

    private func editingState() -> ScanFieldViewState {
        var state = ScanFieldViewState()
        state.select(tool: .editZone)
        return state
    }

    private func point(
        index: Double, value: Double, in state: ScanFieldViewState
    ) -> CGPoint {
        state.geometry(in: size).project(
            angleFraction: index,
            radiusFraction: value / PolarProfileGeometry.maxRawMeasurementValue
        ).screenPoint
    }

    /// Fährt eine vollständige Geste und wendet **jeden** Zwischenschritt
    /// auf den Editorzustand an — genau wie die Ansicht es tut.
    @discardableResult
    private func drag(
        _ state: inout ScanFieldViewState,
        _ editor: inout ZoneEditorState,
        from origin: CGPoint,
        through waypoints: [CGPoint] = [],
        to destination: CGPoint
    ) -> ScanFieldDragOutcome {
        state.beginDrag(at: origin, in: size, zones: editor.zones, selectedZoneID: editor.selectedZoneID)
        for waypoint in waypoints {
            apply(state.updateDrag(to: waypoint, in: size), to: &editor)
        }
        let outcome = state.endDrag(at: destination, in: size, zones: editor.zones)
        apply(outcome, to: &editor)
        return outcome
    }

    private func apply(_ outcome: ScanFieldDragOutcome, to editor: inout ZoneEditorState) {
        switch outcome {
        case .editZone(let command):
            editor.apply(command)
        case .selectZone(let id):
            editor.select(id)
        case .viewportChanged, .nothing:
            break
        }
    }

    // MARK: - Werkzeugtrennung

    func testOnlyTheEditToolProducesAZoneEditAtAll() throws {
        for tool in ScanFieldTool.allCases {
            var (editor, _) = try makeEditor()
            var state = ScanFieldViewState()
            state.select(tool: tool)

            let start = point(index: 0.5, value: 4000, in: state)
            let end = point(index: 0.6, value: 4400, in: state)
            let outcome = drag(&state, &editor, from: start, to: end)

            if tool == .editZone {
                guard case .editZone = outcome else {
                    return XCTFail("Erwartet: Bearbeitungsbefehl, bekommen: \(outcome)")
                }
            } else {
                if case .editZone = outcome {
                    XCTFail("\(tool) darf keine Zone bearbeiten")
                }
            }
        }
    }

    func testTheEditToolNeverMovesTheViewport() throws {
        var (editor, _) = try makeEditor()
        var state = editingState()
        // **Bewusst ein eingezoomter Ausschnitt.** In der Gesamtansicht
        // ist ein Verschieben geometrisch folgenlos -- der Ausschnitt
        // deckt bereits alles ab und `panned` stößt sofort an den Rand.
        // Ein Test dort könnte ein versehentliches Mitverschieben gar
        // nicht sehen.
        state.zoomAtPointer(
            byFactor: 2, at: point(index: 0.5, value: 4000, in: state), in: size
        )
        let before = state.viewport
        XCTAssertFalse(before.isFullField)
        // Gegenprobe zur Aussagekraft: Mit dem Verschieben-Werkzeug
        // bewegt sich genau dieser Zug sichtbar.
        var panState = state
        panState.select(tool: .pan)
        var untouched = editor
        drag(
            &panState, &untouched,
            from: point(index: 0.5, value: 4000, in: state),
            through: [point(index: 0.55, value: 4200, in: state)],
            to: point(index: 0.62, value: 4600, in: state)
        )
        XCTAssertNotEqual(panState.viewport, before, "Sonst prüft der Test unten nichts")

        drag(
            &state, &editor,
            from: point(index: 0.5, value: 4000, in: state),
            through: [point(index: 0.55, value: 4200, in: state)],
            to: point(index: 0.62, value: 4600, in: state)
        )

        XCTAssertEqual(state.viewport, before, "Bearbeiten verschiebt den Ausschnitt nicht")
    }

    func testTheEditToolNeverChangesTheSelection() throws {
        var editor = ZoneEditorState()
        let first = editor.addZone(try Zone.build(
            indexLowerBound: 0.1, indexUpperBound: 0.3,
            valueLowerBound: 1000, valueUpperBound: 2000, role: .pitch
        ))
        let second = editor.addZone(try Zone.build(
            indexLowerBound: 0.6, indexUpperBound: 0.9,
            valueLowerBound: 5000, valueUpperBound: 7000, role: .volume
        ))
        editor.select(first)

        var state = editingState()
        // Mitten in die **andere** Zone ziehen.
        drag(
            &state, &editor,
            from: point(index: 0.75, value: 6000, in: state),
            to: point(index: 0.8, value: 6400, in: state)
        )

        XCTAssertEqual(editor.selectedZoneID, first, "Die Auswahl bleibt, wo sie war")
        XCTAssertEqual(
            editor.zones.first(where: { $0.id == second })?.zone.indexRange.lowerBound, 0.6,
            "Und die nicht ausgewählte Zone bleibt unverändert"
        )
    }

    func testThePanToolStillMovesOnlyTheViewport() throws {
        var (editor, _) = try makeEditor()
        let zonesBefore = editor.zones
        var state = ScanFieldViewState()
        state.select(tool: .pan)

        // **Mitten auf der ausgewählten Zone beginnen**, und zwar in
        // einer zweiten Fahrt genau auf einem ihrer Griffe. Eine
        // verdeckte Vorrangregel „Treffer auf Griff/Zone gewinnt, sonst
        // Verschieben" -- die Variante, die dieser Slice ausdrücklich
        // nicht gebaut hat -- würde genau hier zuschlagen; an einem
        // beliebigen Punkt neben der Zone bliebe sie unsichtbar.
        drag(
            &state, &editor,
            from: point(index: 0.5, value: 4000, in: state),
            through: [point(index: 0.55, value: 4200, in: state)],
            to: point(index: 0.62, value: 4600, in: state)
        )
        XCTAssertEqual(editor.zones, zonesBefore, "Verschieben fasst keine Zone an")

        let handle = try XCTUnwrap(
            ZoneHandleGeometry.placedHandles(
                for: XCTUnwrap(editor.zones.first).zone, in: state.geometry(in: size)
            ).first
        ).screenPoint
        drag(
            &state, &editor,
            from: handle,
            through: [CGPoint(x: handle.x + 20, y: handle.y - 15)],
            to: CGPoint(x: handle.x + 40, y: handle.y - 30)
        )
        XCTAssertEqual(editor.zones, zonesBefore, "Auch ein Zug genau auf einem Griff bearbeitet nichts")
    }

    // MARK: - Eine Zonenwahrheit

    func testTheAppliedCommandLandsInTheZoneListAndNowhereElse() throws {
        var (editor, id) = try makeEditor()
        var state = editingState()

        drag(
            &state, &editor,
            from: point(index: 0.5, value: 4000, in: state),
            to: point(index: 0.6, value: 4000, in: state)
        )

        let zone = try XCTUnwrap(editor.zones.first(where: { $0.id == id })?.zone)
        XCTAssertEqual(zone.indexRange.lowerBound, 0.4, accuracy: 1e-9)
        XCTAssertEqual(zone.indexRange.upperBound, 0.8, accuracy: 1e-9)
        XCTAssertEqual(zone.valueRange, 2000...6000, "Der Rohwertbereich bleibt unberührt")
    }

    /// Der offene Inspector-Entwurf wird aus der Zone **neu abgeleitet**
    /// (Auflage D3) — es gibt keinen zweiten Stand, der später
    /// zusammengeführt werden müsste.
    func testTheOpenInspectorDraftIsRederivedFromTheEditedZone() throws {
        var (editor, id) = try makeEditor()
        editor.updateDraft(ZoneDraft(
            indexLowerBound: 0.01, indexUpperBound: 0.02,
            valueLowerBound: 10, valueUpperBound: 20, role: .gate
        ))
        var state = editingState()

        drag(
            &state, &editor,
            from: point(index: 0.5, value: 4000, in: state),
            to: point(index: 0.55, value: 4000, in: state)
        )

        let zone = try XCTUnwrap(editor.zones.first(where: { $0.id == id })?.zone)
        let draft = try XCTUnwrap(editor.draft)
        XCTAssertEqual(draft.indexLowerBound, zone.indexRange.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(draft.valueUpperBound, zone.valueRange.upperBound)
        XCTAssertEqual(draft.role, zone.role, "Der halb getippte Rollenwechsel verfällt")
    }

    func testEveryHandleMovesExactlyItsOwnBoundary() throws {
        let expectations: [(ZoneGeometryHandle, Double, Double)] = [
            (.indexLowerBound, 0.3, 0.4), (.indexUpperBound, 0.7, 0.8)
        ]

        for (handle, from, to) in expectations {
            var (editor, id) = try makeEditor()
            var state = editingState()
            let original = try XCTUnwrap(editor.zones.first?.zone)

            let startPoint = ZoneHandleGeometry.placedHandles(
                for: original, in: state.geometry(in: size)
            ).first { $0.handle == handle }!.screenPoint
            let delta = point(index: to, value: 4000, in: state).x
                - point(index: from, value: 4000, in: state).x
            let endPoint = CGPoint(x: startPoint.x + delta, y: startPoint.y)

            drag(&state, &editor, from: startPoint, to: endPoint)

            let zone = try XCTUnwrap(editor.zones.first(where: { $0.id == id })?.zone)
            XCTAssertEqual(zone.valueRange, original.valueRange, "\(handle) fasst den Rohwert nicht an")
            if handle == .indexLowerBound {
                XCTAssertEqual(zone.indexRange.upperBound, original.indexRange.upperBound, accuracy: 1e-9)
                XCTAssertGreaterThan(zone.indexRange.lowerBound, original.indexRange.lowerBound)
            } else {
                XCTAssertEqual(zone.indexRange.lowerBound, original.indexRange.lowerBound, accuracy: 1e-9)
                XCTAssertGreaterThan(zone.indexRange.upperBound, original.indexRange.upperBound)
            }
        }
    }

    /// Ziehen und wieder zurück landet **exakt** auf dem Ausgangswert —
    /// der Beweis, dass die Geste aus der Gesamtverschiebung seit dem
    /// eingefrorenen Start rechnet und nicht Deltas aufaddiert.
    func testPullingBackToTheStartRestoresTheZoneExactly() throws {
        var (editor, id) = try makeEditor()
        let original = try XCTUnwrap(editor.zones.first?.zone)
        var state = editingState()

        let startPoint = point(index: 0.5, value: 4000, in: state)
        state.beginDrag(at: startPoint, in: size, zones: editor.zones, selectedZoneID: editor.selectedZoneID)
        for waypoint in [
            point(index: 0.58, value: 4600, in: state),
            point(index: 0.66, value: 5200, in: state),
            point(index: 0.44, value: 3400, in: state)
        ] {
            apply(state.updateDrag(to: waypoint, in: size), to: &editor)
        }
        apply(state.endDrag(at: startPoint, in: size, zones: editor.zones), to: &editor)

        XCTAssertEqual(editor.zones.first(where: { $0.id == id })?.zone, original)
    }

    /// Dieselbe Geste mehrfach angewandt ergibt dasselbe Ergebnis —
    /// Delta-Akkumulation ist damit ausgeschlossen.
    func testApplyingTheSameGestureRepeatedlyIsIdempotent() throws {
        var (editor, id) = try makeEditor()
        var state = editingState()

        let startPoint = point(index: 0.5, value: 4000, in: state)
        let endPoint = point(index: 0.6, value: 4400, in: state)

        state.beginDrag(at: startPoint, in: size, zones: editor.zones, selectedZoneID: editor.selectedZoneID)
        apply(state.updateDrag(to: endPoint, in: size), to: &editor)
        let afterFirst = try XCTUnwrap(editor.zones.first(where: { $0.id == id })?.zone)

        for _ in 0..<5 {
            apply(state.updateDrag(to: endPoint, in: size), to: &editor)
        }
        apply(state.endDrag(at: endPoint, in: size, zones: editor.zones), to: &editor)

        XCTAssertEqual(editor.zones.first(where: { $0.id == id })?.zone, afterFirst)
    }

    /// Die Bearbeitung läuft auch **im gewählten Ausschnitt** korrekt:
    /// Ein Zug über dieselbe Bildschirmstrecke bewegt dort weniger
    /// Rohwerte, und die Zone landet trotzdem exakt unter dem Zeiger.
    func testEditingIsCorrectInsideAZoomedViewport() throws {
        var (editor, id) = try makeEditor(value: 2000...3000)
        var state = editingState()
        // Ausschnitt über die **echte** Bedienung erzeugen: einpassen auf
        // ein Profil in derselben Größenordnung wie die Zone.
        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: try (0..<90).map { index in
                try B0ScanProfile.Measurement.build(
                    value: UInt16(2000 + (index % 12) * 90), fieldFlags: 0
                )
            },
            trailingBytes: [0]
        )
        state.fitToProfile(profile)
        XCTAssertFalse(state.viewport.isFullField, "Sonst prüft der Test die Gesamtansicht")
        XCTAssertLessThan(state.viewport.halfExtent, 0.5, "Der Ausschnitt ist wirklich eng")

        drag(
            &state, &editor,
            from: point(index: 0.5, value: 2500, in: state),
            to: point(index: 0.5, value: 2700, in: state)
        )

        let zone = try XCTUnwrap(editor.zones.first(where: { $0.id == id })?.zone)
        XCTAssertEqual(Double(zone.valueRange.lowerBound), 2200, accuracy: 2)
        XCTAssertEqual(Double(zone.valueRange.upperBound), 3200, accuracy: 2)
    }

    // MARK: - Sichtbare Verweigerungen

    func testDraggingWithoutASelectedZoneSaysSoAndChangesNothing() throws {
        var editor = ZoneEditorState()
        _ = editor.addZone(try Zone.build(
            indexLowerBound: 0.3, indexUpperBound: 0.7,
            valueLowerBound: 2000, valueUpperBound: 6000, role: .pitch
        ))
        // `addZone` wählt die neue Zone aus; hier soll ausdrücklich
        // **keine** ausgewählt sein.
        editor.select(nil)
        let before = editor
        var state = editingState()

        let outcome = drag(
            &state, &editor,
            from: point(index: 0.5, value: 4000, in: state),
            to: point(index: 0.6, value: 4400, in: state)
        )

        XCTAssertEqual(outcome, .nothing)
        XCTAssertEqual(state.notice, .editNeedsSelectedZone)
        XCTAssertEqual(editor, before)
    }

    func testDraggingBesideTheSelectedZoneSaysSoAndChangesNothing() throws {
        var (editor, _) = try makeEditor(index: 0.3...0.4, value: 2000...2400)
        let before = editor
        var state = editingState()

        let outcome = drag(
            &state, &editor,
            from: point(index: 0.85, value: 7000, in: state),
            to: point(index: 0.9, value: 7400, in: state)
        )

        XCTAssertEqual(outcome, .nothing)
        XCTAssertEqual(state.notice, .editMissedSelectedZone)
        XCTAssertEqual(editor, before)
    }

    func testANoticeFromAMissedEditDisappearsOnlyThroughASuccessfulAction() throws {
        var (editor, _) = try makeEditor(index: 0.3...0.4, value: 2000...2400)
        var state = editingState()

        drag(
            &state, &editor,
            from: point(index: 0.85, value: 7000, in: state),
            to: point(index: 0.9, value: 7400, in: state)
        )
        XCTAssertEqual(state.notice, .editMissedSelectedZone)

        drag(
            &state, &editor,
            from: point(index: 0.35, value: 2200, in: state),
            to: point(index: 0.4, value: 2200, in: state)
        )
        XCTAssertNil(state.notice)
    }

    func testSwitchingToolsCancelsARunningEdit() throws {
        var (editor, id) = try makeEditor()
        let original = try XCTUnwrap(editor.zones.first?.zone)
        var state = editingState()

        state.beginDrag(
            at: point(index: 0.5, value: 4000, in: state),
            in: size, zones: editor.zones, selectedZoneID: editor.selectedZoneID
        )
        state.select(tool: .pan)
        apply(state.updateDrag(to: point(index: 0.7, value: 5000, in: state), in: size), to: &editor)

        XCTAssertNil(state.drag)
        XCTAssertEqual(editor.zones.first(where: { $0.id == id })?.zone, original)
    }

    // MARK: - Was eine Geste niemals anfasst

    func testAnEditNeverChangesActivationRoleOrTheZoneIdentity() throws {
        var (editor, id) = try makeEditor(role: .gate)
        let before = try XCTUnwrap(editor.zones.first)
        XCTAssertFalse(before.isEnabled, "Neue Zonen entstehen deaktiviert (SICK-030b1/D2)")
        var state = editingState()

        drag(
            &state, &editor,
            from: point(index: 0.5, value: 4000, in: state),
            through: [point(index: 0.55, value: 4200, in: state)],
            to: point(index: 0.6, value: 4400, in: state)
        )

        let after = try XCTUnwrap(editor.zones.first(where: { $0.id == id }))
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.isEnabled, before.isEnabled, "Eine Geste schaltet nichts ein")
        XCTAssertEqual(after.zone.role, .gate, "Und ändert keine Rolle")
        XCTAssertNotEqual(after.zone, before.zone, "Sonst prüft der Test nichts")
    }

    func testAnEditTouchesNoOtherZone() throws {
        var editor = ZoneEditorState()
        let target = editor.addZone(try Zone.build(
            indexLowerBound: 0.3, indexUpperBound: 0.7,
            valueLowerBound: 2000, valueUpperBound: 6000, role: .pitch
        ))
        let other = editor.addZone(try Zone.build(
            indexLowerBound: 0.35, indexUpperBound: 0.65,
            valueLowerBound: 2200, valueUpperBound: 5800, role: .volume
        ))
        editor.select(target)
        let otherBefore = try XCTUnwrap(editor.zones.first(where: { $0.id == other }))
        var state = editingState()

        drag(
            &state, &editor,
            from: point(index: 0.5, value: 4000, in: state),
            to: point(index: 0.58, value: 4400, in: state)
        )

        XCTAssertEqual(editor.zones.first(where: { $0.id == other }), otherBefore)
        XCTAssertNotEqual(
            editor.zones.first(where: { $0.id == target })?.zone,
            otherBefore.zone, "Sonst prüft der Test nichts"
        )
    }

    // MARK: - SICK-032b2c-K2: Konsistenz am sichtbaren Canvasrand

    /// **Pflichtnachweis:** Bei `800 × 600` liegt die Canvas der
    /// Gesamtansicht bei `x: 100...700`. Jede der vier Griffbewegungen
    /// **und** das Verschieben der ganzen Zone liefern für ein Ziel
    /// jenseits von `x = 700` **dasselbe** Ergebnis wie für dasselbe Ziel
    /// exakt auf `x = 700` (Auftragspunkt 2/Pflichtnachweis
    /// „Zonenbearbeitung bleibt am Canvasrand konsistent",
    /// `.agent_handoff/task-sick-032b2c-k2.md`). Beide Zielpunkte teilen
    /// dieselbe `y`-Koordinate, damit ``LinearScanFieldGeometry/canvasClampedScreenPoint(_:)``
    /// sie auf denselben Bildschirmpunkt klammert, unabhängig vom
    /// tatsächlichen Öffnungswinkel des Fächers.
    func testEveryZoneEditingGestureIsConsistentAtTheCanvasEdge() throws {
        for gesture in ZoneGeometryGesture.allGestures {
            func run(destinationX: CGFloat) throws -> Zone {
                var (editor, id) = try makeEditor()
                var state = editingState()
                let original = try XCTUnwrap(editor.zones.first?.zone)

                let start: CGPoint
                switch gesture {
                case .moveWholeZone:
                    start = point(index: 0.5, value: 4000, in: state)
                case .handle(let handle):
                    start = try XCTUnwrap(
                        ZoneHandleGeometry.placedHandles(for: original, in: state.geometry(in: size))
                            .first { $0.handle == handle }
                    ).screenPoint
                }

                let destination = CGPoint(x: destinationX, y: start.y)
                drag(&state, &editor, from: start, to: destination)
                return try XCTUnwrap(editor.zones.first(where: { $0.id == id })?.zone)
            }

            let atCanvasEdge = try run(destinationX: 700)
            let farBeyondCanvasEdge = try run(destinationX: 5_000)
            XCTAssertEqual(
                atCanvasEdge, farBeyondCanvasEdge,
                "\(gesture): jenseits der sichtbaren Canvas darf nichts weiter wirken als am Rand"
            )
        }
    }

    /// **Pflichtnachweis, Auswahl:** Ein Klick jenseits der sichtbaren
    /// Canvas trifft dieselbe Zone (oder dieselbe Leere) wie derselbe
    /// Klick exakt am Canvasrand -- die Trefferprüfung folgt derselben
    /// einen Bedienumkehrung wie die Bearbeitung.
    func testSelectionIsConsistentAtTheCanvasEdge() throws {
        var editor = ZoneEditorState()
        // Deckt den äußersten Feldpunkt (Winkelanteil `1`, Rohwert nahe
        // dem Maximum) -- genau dessen Bildschirmposition ist bei
        // `800 × 600` der rechte Canvasrand (`(700, 300)`,
        // `testFullFieldShowsBothOuterEndpointsWithinTheCanvasFor800x600`).
        _ = editor.addZone(try Zone.build(
            indexLowerBound: 0.9, indexUpperBound: 1.0,
            valueLowerBound: 7_000, valueUpperBound: 8_191, role: .volume
        ))
        let state = ScanFieldViewState()
        let edgePoint = state.geometry(in: size).project(angleFraction: 1, radiusFraction: 1).screenPoint
        XCTAssertEqual(Double(edgePoint.x), 700, accuracy: 1e-6, "Sonst stimmt die Testannahme über den Canvasrand nicht")
        XCTAssertEqual(Double(edgePoint.y), 300, accuracy: 1e-6, "Sonst stimmt die Testannahme über den Canvasrand nicht")
        let referenceY = edgePoint.y

        let atEdgeID = state.zoneID(at: CGPoint(x: 700, y: referenceY), in: size, among: editor.zones)
        let beyondEdgeID = state.zoneID(at: CGPoint(x: 5_000, y: referenceY), in: size, among: editor.zones)
        XCTAssertEqual(atEdgeID, beyondEdgeID)
        XCTAssertNotNil(atEdgeID, "Sonst prüft der Test nur zwei leere Treffer gegeneinander")

        // Und über die vollständige Geste (`beginDrag`/`endDrag`), wie
        // die Ansicht sie tatsächlich fährt.
        var atEdgeState = state
        atEdgeState.beginDrag(at: CGPoint(x: 700, y: referenceY), in: size)
        let atEdgeOutcome = atEdgeState.endDrag(
            at: CGPoint(x: 700, y: referenceY), in: size, zones: editor.zones
        )

        var beyondEdgeState = state
        beyondEdgeState.beginDrag(at: CGPoint(x: 5_000, y: referenceY), in: size)
        let beyondEdgeOutcome = beyondEdgeState.endDrag(
            at: CGPoint(x: 5_000, y: referenceY), in: size, zones: editor.zones
        )

        XCTAssertEqual(atEdgeOutcome, beyondEdgeOutcome)
        XCTAssertEqual(atEdgeOutcome, .selectZone(atEdgeID))
    }

    /// Eine Bearbeitungsgeste ist **keine musikalische Handlung**: Sie
    /// erreicht weder Profil noch Auswertung. Geprüft an der echten
    /// Zonenauswertung gegen ein echtes synthetisches Profil.
    func testAnEditProducesNoEvaluationOfItsOwn() throws {
        var (editor, _) = try makeEditor()
        var state = editingState()
        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: try (0..<90).map { _ in
                try B0ScanProfile.Measurement.build(value: 4000, fieldFlags: 0)
            },
            trailingBytes: [0]
        )
        let before = editor.evaluations(against: profile)

        drag(
            &state, &editor,
            from: point(index: 0.5, value: 4000, in: state),
            to: point(index: 0.5, value: 4000, in: state)
        )

        XCTAssertEqual(editor.evaluations(against: profile), before)
        XCTAssertEqual(
            editor.evaluations(against: nil), [:],
            "Ohne Profil entsteht kein Wert -- auch nicht aus einer Geste"
        )
    }
}
