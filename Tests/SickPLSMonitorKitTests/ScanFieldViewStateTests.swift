import XCTest
import CoreGraphics
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// **Die Weiterleitung der Bedienhandlungen** (SICK-032b2): Jede
/// Handlung der Oberfläche landet bei genau dem Werkzeug von
/// ``ScanPlaneViewport``, das sie bedeuten soll -- und bei keinem anderen.
///
/// Geprüft wird nicht „irgendetwas hat sich geändert", sondern die
/// **Gleichheit mit dem direkten Werkzeugaufruf**. Nur so fällt auf, wenn
/// eine Handlung heimlich eine zweite Rechnung mitbringt.
@MainActor final class ScanFieldViewStateTests: XCTestCase {

    private let size = CGSize(width: 800, height: 600)

    private func zoomedState() throws -> ScanFieldViewState {
        var state = ScanFieldViewState()
        state.zoomAtCenter(byFactor: 4)
        XCTAssertFalse(state.viewport.isFullField, "Sonst prüft der Test die Gesamtansicht")
        return state
    }

    private func screenPoint(angle: Double, radius: Double, in state: ScanFieldViewState) -> CGPoint {
        state.geometry(in: size).project(angleFraction: angle, radiusFraction: radius).screenPoint
    }

    // MARK: - Ausgangslage

    func testANewStateShowsTheWholeFieldWithTheZoneToolAndNoNotice() {
        let state = ScanFieldViewState()
        XCTAssertEqual(state.viewport, .fullField)
        XCTAssertEqual(state.tool, .selectZone)
        XCTAssertNil(state.notice)
        XCTAssertNil(state.drag)
        XCTAssertNil(state.rubberBandRect(in: size))
    }

    // MARK: - Gesamtansicht

    func testFullFieldForwardsToTheFullFieldValue() throws {
        var state = try zoomedState()
        state.showFullField()
        XCTAssertEqual(state.viewport, ScanPlaneViewport.fullField)
        XCTAssertNil(state.notice)
    }

    // MARK: - Lupe

    func testTheMagnifierZoomsAroundTheCentreOfTheCurrentWindow() throws {
        var state = try zoomedState()
        let before = state.viewport
        let expected = before.zoomed(
            byFactor: ScanFieldViewState.buttonZoomFactor,
            anchorX: before.centerX, anchorY: before.centerY
        )

        state.zoomAtCenter(byFactor: ScanFieldViewState.buttonZoomFactor)
        XCTAssertEqual(state.viewport, expected.viewport)
    }

    func testZoomingOutWithTheMagnifierIsTheInverseDirection() throws {
        var state = try zoomedState()
        let narrow = state.viewport.halfExtent
        state.zoomAtCenter(byFactor: 1 / ScanFieldViewState.buttonZoomFactor)
        XCTAssertGreaterThan(state.viewport.halfExtent, narrow)
    }

    func testANonPositiveZoomFactorLeavesTheWindowAloneAndIsVisible() throws {
        var state = try zoomedState()
        let before = state.viewport
        state.zoomAtCenter(byFactor: 0)
        XCTAssertEqual(state.viewport, before)
        XCTAssertEqual(state.notice, .viewGeometryUnusable)
    }

    // MARK: - Zoom am Zeiger

    /// **Seit SICK-032b2c ist der Anker eine Weltposition**, keine
    /// Feldkoordinate mehr: Der Zoom am Zeiger fragt
    /// ``LinearScanFieldGeometry/worldPoint(forScreenPoint:)``, nicht
    /// ``LinearScanFieldGeometry/fieldCoordinate(forScreenPoint:)`` --
    /// derselbe Wechsel, der den Sonderfall an der Fächerspitze
    /// überflüssig macht (siehe unten).
    ///
    /// **Seit SICK-032b2c-K2 ist die erwartete Rechnung selbst an die
    /// Canvas gebunden:** Der Sondenpunkt (Radiusanteil `0,4`) liegt bei
    /// der hier gezoomten `halfExtent` von `0,25` außerhalb der
    /// sichtbaren Canvas -- die Erwartung entsteht deshalb über
    /// ``LinearScanFieldGeometry/boundedWorldPoint(forScreenPoint:)``,
    /// denselben produktiven Weg wie `zoomAtPointer`.
    func testPointerZoomForwardsTheWorldPositionUnderThePointerAsAnchor() throws {
        var state = try zoomedState()
        let before = state.viewport
        let point = screenPoint(angle: 0.3, radius: 0.4, in: state)

        let anchor = try XCTUnwrap(state.geometry(in: size).boundedWorldPoint(forScreenPoint: point))
        let expected = before.zoomed(
            byFactor: 1.5, anchorX: Double(anchor.x), anchorY: Double(anchor.y)
        )

        state.zoomAtPointer(byFactor: 1.5, at: point, in: size)
        XCTAssertEqual(state.viewport, expected.viewport)
    }

    /// Die eigentliche Zusage der Bedienung: **Was unter dem Zeiger liegt,
    /// bleibt unter dem Zeiger.**
    ///
    /// Der Test daneben prüft die *Weiterleitung* (Gleichheit mit dem
    /// direkten Werkzeugaufruf); dieser prüft die *Wirkung* und ist
    /// deshalb bewusst kein zweiter Gleichheitstest: Er misst den
    /// Bildschirmpunkt derselben Feldkoordinate **vor und nach** dem Zoom.
    /// Ohne ihn bliebe eine am Anker vorbeigehende Umsetzung (etwa ein
    /// stiller Rückfall auf den Fenstermittelpunkt) nur an einer einzigen
    /// Stelle sichtbar.
    ///
    /// Geprüft über **alle drei Eingabekanäle** -- Lupe am Zeiger,
    /// Scrollrad und Pinch --, weil jeder von ihnen seinen eigenen Weg in
    /// die Umrechnung hat.
    func testZoomingAtThePointerLeavesThePointUnderThePointerWhereItIs() throws {
        // Radius bewusst deutlich unter der Halbkantenlänge der
        // Ausgangslage (`zoomedState()`, `halfExtent == 0.25`): Die Sonde
        // muss selbst **innerhalb** des gerade sichtbaren Ausschnitts
        // liegen, sonst zöge die radiale Randklammerung von
        // `fieldCoordinate(forScreenPoint:)` (SICK-032b2c, „ein Zug über
        // den sichtbaren Rand hinaus stoppt am Rand") die Sonde auf den
        // Ausschnittsrand -- ein anderer Feldpunkt als der, auf dem `point`
        // tatsächlich steht, und der Test prüfte dann etwas anderes als
        // den Ankernachweis.
        let probes: [(angle: Double, radius: Double)] = [
            (0.42, 0.10), (0.5, 0.15), (0.58, 0.20), (0.45, 0.18),
        ]

        for probe in probes {
            // Drei Zustände, dieselbe Ausgangslage, drei Eingabekanäle.
            var byFactor = try zoomedState()
            var byScroll = byFactor
            var byPinch = byFactor

            let point = screenPoint(angle: probe.angle, radius: probe.radius, in: byFactor)
            let anchor = try XCTUnwrap(
                byFactor.geometry(in: size).fieldCoordinate(forScreenPoint: point),
                "Die Sonde muss im Feld liegen, sonst prüft der Test nichts"
            )

            byFactor.zoomAtPointer(byFactor: 1.6, at: point, in: size)
            byScroll.zoomAtPointer(byScrollEvent: trackpadScroll(30), at: point, in: size)
            byPinch.zoomAtPointer(byMagnification: 0.4, at: point, in: size)

            for (channel, state) in [
                ("Lupe am Zeiger", byFactor), ("Scrollrad", byScroll), ("Pinch", byPinch),
            ] {
                XCTAssertNotEqual(
                    state.viewport, try zoomedState().viewport,
                    "\(channel) hat gar nicht gezoomt -- dann sagt der Test nichts aus"
                )

                let after = state.geometry(in: size).project(
                    angleFraction: anchor.angleFraction, radiusFraction: anchor.radiusFraction
                ).screenPoint

                XCTAssertEqual(
                    Double(after.x), Double(point.x), accuracy: 1e-6,
                    "\(channel) bei \(probe): der Punkt ist waagerecht weggewandert"
                )
                XCTAssertEqual(
                    Double(after.y), Double(point.y), accuracy: 1e-6,
                    "\(channel) bei \(probe): der Punkt ist senkrecht weggewandert"
                )
            }
        }
    }

    /// Der Bedienzustand rechnet den Faktor **nicht selbst** -- er fragt
    /// die eine dafür zuständige Stelle (SICK-032b2b).
    func testScrollingIsTranslatedThroughTheOneDocumentedTranslation() throws {
        var direct = try zoomedState()
        var scrolled = direct

        let point = screenPoint(angle: 0.5, radius: 0.5, in: direct)
        let event = trackpadScroll(12)
        let factor = try XCTUnwrap(ScanFieldZoomInput.zoomFactor(for: event))

        direct.zoomAtPointer(byFactor: factor, at: point, in: size)
        scrolled.zoomAtPointer(byScrollEvent: event, at: point, in: size)

        XCTAssertEqual(scrolled.viewport, direct.viewport)
    }

    func testScrollingUpZoomsInAndScrollingDownZoomsOut() throws {
        var state = try zoomedState()
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)
        let start = state.viewport.halfExtent

        state.zoomAtPointer(byScrollEvent: trackpadScroll(20), at: point, in: size)
        let afterIn = state.viewport.halfExtent
        XCTAssertLessThan(afterIn, start)

        state.zoomAtPointer(byScrollEvent: trackpadScroll(-20), at: point, in: size)
        XCTAssertGreaterThan(state.viewport.halfExtent, afterIn)
    }

    /// Ein Trackpad-Schwung darf nicht in einem Bild vom ganzen Feld in
    /// die Mindestspanne springen.
    func testAnExtremeScrollIsLimitedToTheDocumentedMaximum() throws {
        var limited = ScanFieldViewState()
        var atMaximum = ScanFieldViewState()
        let point = screenPoint(angle: 0.5, radius: 0.5, in: limited)

        limited.zoomAtPointer(byScrollEvent: trackpadScroll(10_000), at: point, in: size)
        atMaximum.zoomAtPointer(
            byScrollEvent: trackpadScroll(ScanFieldZoomInput.maximumScrollPointsPerEvent),
            at: point, in: size
        )
        XCTAssertEqual(limited.viewport, atMaximum.viewport)
    }

    func testPinchIsTranslatedIntoFactorPlusOne() throws {
        var direct = try zoomedState()
        var pinched = direct
        let point = screenPoint(angle: 0.6, radius: 0.2, in: direct)

        direct.zoomAtPointer(byFactor: 1.25, at: point, in: size)
        pinched.zoomAtPointer(byMagnification: 0.25, at: point, in: size)

        XCTAssertEqual(pinched.viewport, direct.viewport)
    }

    func testANonFinitePointerInputLeavesTheWindowAloneAndIsVisible() throws {
        var state = try zoomedState()
        let before = state.viewport
        state.zoomAtPointer(byScrollEvent: trackpadScroll(.nan), at: .zero, in: size)
        XCTAssertEqual(state.viewport, before)
        XCTAssertEqual(state.notice, .viewGeometryUnusable)
    }

    func testADegenerateViewSizeLeavesTheWindowAloneAndIsVisible() throws {
        var state = try zoomedState()
        let before = state.viewport
        state.zoomAtPointer(byFactor: 2, at: .zero, in: .zero)
        XCTAssertEqual(state.viewport, before)
        XCTAssertEqual(state.notice, .viewGeometryUnusable)
    }

    // MARK: - Verschieben

    /// **Seit SICK-032b2c-K2 an der Canvas gebunden:** Beide Sonden
    /// (Radiusanteile `0,5`/`0,7`) liegen bei der hier gezoomten
    /// `halfExtent` von `0,25` außerhalb der sichtbaren Canvas -- die
    /// Erwartung entsteht deshalb über `boundedWorldPoint`, demselben
    /// produktiven Weg wie `applyPan`.
    func testPanningForwardsTheTotalTranslationSinceTheGestureStarted() throws {
        var state = try zoomedState()
        let start = state.viewport
        let from = screenPoint(angle: 0.4, radius: 0.5, in: state)
        let to = screenPoint(angle: 0.6, radius: 0.7, in: state)

        let geo = state.geometry(in: size)
        let startWorld = try XCTUnwrap(geo.boundedWorldPoint(forScreenPoint: from))
        let endWorld = try XCTUnwrap(geo.boundedWorldPoint(forScreenPoint: to))
        let expected = start.panned(
            byX: Double(startWorld.x) - Double(endWorld.x),
            byY: Double(startWorld.y) - Double(endWorld.y)
        )

        state.select(tool: .pan)
        state.beginDrag(at: from, in: size)
        state.updateDrag(to: to, in: size)

        XCTAssertEqual(state.viewport, expected.viewport)
    }

    /// **Die Lehre aus SICK-030b2:** Gerechnet wird aus der
    /// Gesamtverschiebung seit dem Gestenbeginn, nie delta-akkumuliert.
    /// Dieselbe Position zweimal gemeldet darf den Inhalt nicht ein
    /// zweites Mal um dieselbe Strecke schieben.
    func testRepeatingTheSamePanPositionDoesNotMoveTwice() throws {
        var state = try zoomedState()
        state.select(tool: .pan)
        let from = screenPoint(angle: 0.4, radius: 0.5, in: state)
        let to = screenPoint(angle: 0.55, radius: 0.6, in: state)

        state.beginDrag(at: from, in: size)
        state.updateDrag(to: to, in: size)
        let afterFirst = state.viewport
        state.updateDrag(to: to, in: size)
        state.updateDrag(to: to, in: size)

        XCTAssertEqual(state.viewport, afterFirst)
    }

    func testPanningPreservesTheHalfExtent() throws {
        var state = try zoomedState()
        state.select(tool: .pan)
        let halfExtent = state.viewport.halfExtent

        state.beginDrag(at: screenPoint(angle: 0.5, radius: 0.5, in: state), in: size)
        state.updateDrag(to: screenPoint(angle: 0.2, radius: 0.2, in: state), in: size)

        XCTAssertEqual(state.viewport.halfExtent, halfExtent, accuracy: 1e-12)
    }

    func testEndingAPanReportsAViewportChangeAndSelectsNoZone() throws {
        var state = try zoomedState()
        state.select(tool: .pan)
        state.beginDrag(at: screenPoint(angle: 0.5, radius: 0.5, in: state), in: size)
        let outcome = state.endDrag(
            at: screenPoint(angle: 0.45, radius: 0.45, in: state), in: size, zones: []
        )
        XCTAssertEqual(outcome, .viewportChanged)
        XCTAssertNil(state.drag)
    }

    // MARK: - Rechteckzoom

    /// Beide Sonden liegen in der Gesamtansicht (`halfExtent = 1`)
    /// innerhalb der Canvas; `boundedWorldPoint` entspricht hier
    /// rechnerisch `worldPoint`, ist aber seit SICK-032b2c-K2 derselbe
    /// Weg wie im produktiven `endDrag`.
    func testTheRectangleToolForwardsBothCornersToTheRectangleTool() throws {
        var state = ScanFieldViewState()
        state.select(tool: .rectangle)
        let a = screenPoint(angle: 0.2, radius: 0.3, in: state)
        let b = screenPoint(angle: 0.7, radius: 0.8, in: state)

        let geo = state.geometry(in: size)
        let worldA = try XCTUnwrap(geo.boundedWorldPoint(forScreenPoint: a))
        let worldB = try XCTUnwrap(geo.boundedWorldPoint(forScreenPoint: b))
        let expected = state.viewport.zoomedToRectangle(
            xA: Double(worldA.x), xB: Double(worldB.x),
            yA: Double(worldA.y), yB: Double(worldB.y)
        )

        state.beginDrag(at: a, in: size)
        state.updateDrag(to: b, in: size)
        let outcome = state.endDrag(at: b, in: size, zones: [])

        XCTAssertEqual(outcome, .viewportChanged)
        XCTAssertEqual(state.viewport, expected.viewport)
    }

    /// **Seit SICK-032b2c-K2 liegen beide Ecken innerhalb der sichtbaren
    /// Canvas** (`x: 100...700` bei `800 × 600`): Die alten Punkte
    /// `(10, 10)`/`(90, 70)` lagen beide vollständig im unsichtbaren
    /// linken Letterbox-Rand und wären jetzt zu Recht auf denselben
    /// Canvasrand geklammert -- ein Rahmen ohne Breite wäre dann kein
    /// Nachweis mehr für den Gummirahmen selbst, sondern nur für die
    /// Randklammerung (die hat ihre eigenen Nachweise weiter unten).
    func testTheRubberBandIsOnlyVisibleWhileTheRectangleToolDrags() throws {
        var state = ScanFieldViewState()
        state.select(tool: .pan)
        state.beginDrag(at: CGPoint(x: 110, y: 10), in: size)
        state.updateDrag(to: CGPoint(x: 190, y: 70), in: size)
        XCTAssertNil(state.rubberBandRect(in: size), "Verschieben zieht keinen Rahmen")

        state.select(tool: .rectangle)
        state.beginDrag(at: CGPoint(x: 190, y: 70), in: size)
        state.updateDrag(to: CGPoint(x: 110, y: 10), in: size)

        let rect = try XCTUnwrap(state.rubberBandRect(in: size))
        XCTAssertEqual(rect.minX, 110, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 10, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 80, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 60, accuracy: 1e-9)

        _ = state.endDrag(at: CGPoint(x: 110, y: 10), in: size, zones: [])
        XCTAssertNil(state.rubberBandRect(in: size))
    }

    /// Ein Rahmen ohne Fläche ist ein Verrutschen beim Klicken, keine
    /// Anweisung -- der Ausschnitt bleibt, und der Grund wird sichtbar.
    func testADegenerateRectangleIsRefusedVisiblyAndChangesNothing() throws {
        var state = try zoomedState()
        state.select(tool: .rectangle)
        let before = state.viewport
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)

        state.beginDrag(at: point, in: size)
        let outcome = state.endDrag(at: point, in: size, zones: [])

        XCTAssertEqual(outcome, .nothing)
        XCTAssertEqual(state.viewport, before)
        XCTAssertEqual(state.notice, .rectangleTooSmall)
    }

    // MARK: - Zonenauswahl

    private func makeZones() throws -> [EditableZone] {
        [
            EditableZone(
                zone: try Zone.build(
                    indexLowerBound: 0.4, indexUpperBound: 0.6,
                    valueLowerBound: 3_000, valueUpperBound: 5_000, role: .pitch
                ),
                isEnabled: false
            ),
            EditableZone(
                zone: try Zone.build(
                    indexLowerBound: 0.0, indexUpperBound: 0.2,
                    valueLowerBound: 10, valueUpperBound: 200, role: .gate
                ),
                isEnabled: false
            )
        ]
    }

    func testTheZoneToolForwardsTheTopmostZoneUnderThePointer() throws {
        var state = ScanFieldViewState()
        let zones = try makeZones()
        let before = state.viewport
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)

        state.beginDrag(at: point, in: size)
        let outcome = state.endDrag(at: point, in: size, zones: zones)

        XCTAssertEqual(outcome, .selectZone(zones[0].id))
        XCTAssertEqual(state.viewport, before, "Eine Zonenauswahl verändert den Ausschnitt nicht")
    }

    func testAClickIntoEmptySpaceDeselects() throws {
        var state = ScanFieldViewState()
        let zones = try makeZones()
        let point = screenPoint(angle: 0.9, radius: 0.9, in: state)

        state.beginDrag(at: point, in: size)
        XCTAssertEqual(state.endDrag(at: point, in: size, zones: zones), .selectZone(nil))
    }

    func testDraggingWithTheDefaultSelectionToolPansTheZoomedViewport() throws {
        var state = try zoomedState()
        let from = CGPoint(x: 400, y: 300)
        let to = CGPoint(x: 450, y: 330)
        let before = state.viewport

        state.beginDrag(at: from, in: size)
        let outcome = state.endDrag(at: to, in: size, zones: [])

        XCTAssertEqual(outcome, .viewportChanged)
        XCTAssertNotEqual(state.viewport, before)
        XCTAssertEqual(state.tool, .selectZone)
    }

    func testTinyPointerMovementStillCountsAsASelectionClick() throws {
        var state = ScanFieldViewState()
        let zones = try makeZones()
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)

        state.beginDrag(at: point, in: size)
        let outcome = state.endDrag(
            at: CGPoint(x: point.x + 2, y: point.y + 1), in: size, zones: zones
        )

        XCTAssertEqual(outcome, .selectZone(zones[0].id))
        XCTAssertEqual(state.viewport, .fullField)
    }

    /// **Unveränderte Auswahlregel:** Die zuletzt gezeichnete passende
    /// Zone gewinnt, auch bei Überlappung.
    func testTheLastDrawnOverlappingZoneWins() throws {
        var zones = try makeZones()
        zones.append(EditableZone(
            zone: try Zone.build(
                indexLowerBound: 0.3, indexUpperBound: 0.7,
                valueLowerBound: 2_000, valueUpperBound: 6_000, role: .volume
            ),
            isEnabled: false
        ))

        var state = ScanFieldViewState()
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)
        state.beginDrag(at: point, in: size)
        XCTAssertEqual(state.endDrag(at: point, in: size, zones: zones), .selectZone(zones[2].id))
    }

    /// Die Trefferprüfung läuft **durch den Ausschnitt**: Dieselbe
    /// Zone bleibt nach einem Zoom unter demselben Feldpunkt treffbar,
    /// auch wenn dieser Feldpunkt jetzt woanders auf dem Bildschirm
    /// liegt.
    func testTheHitTestFollowsTheViewport() throws {
        var state = ScanFieldViewState()
        let zones = try makeZones()

        // Faktor bewusst klein genug, dass die Zielzone (Rohwert
        // 3000…5000, ≈ 0,366…0,611 als Weltanteil) innerhalb der
        // resultierenden Halbkantenlänge bleibt -- sonst zöge die
        // radiale Randklammerung von `fieldCoordinate(forScreenPoint:)`
        // (SICK-032b2c) den Feldpunkt auf den Ausschnittsrand, statt auf
        // die Zone selbst.
        state.zoomAtCenter(byFactor: 1.5)
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)
        XCTAssertEqual(state.zoneID(at: point, in: size, among: zones), zones[0].id)
    }

    // MARK: - Werkzeugwechsel und Hinweise

    func testSwitchingToolsCancelsARunningGesture() throws {
        var state = ScanFieldViewState()
        state.select(tool: .rectangle)
        state.beginDrag(at: CGPoint(x: 10, y: 10), in: size)
        XCTAssertNotNil(state.drag)

        state.select(tool: .pan)
        XCTAssertNil(state.drag, "Sonst endete die Geste mit einer anderen Bedeutung, als sie begann")
        XCTAssertNil(state.rubberBandRect(in: size))
    }

    func testAGestureKeepsTheToolItStartedWith() throws {
        var state = ScanFieldViewState()
        state.select(tool: .pan)
        state.beginDrag(at: CGPoint(x: 100, y: 100), in: size)
        let session = try XCTUnwrap(state.drag)
        XCTAssertEqual(session.tool, .pan)
    }

    func testANoticeDisappearsOnlyThroughASuccessfulAction() throws {
        var state = try zoomedState()
        state.zoomAtCenter(byFactor: -1)
        XCTAssertEqual(state.notice, .viewGeometryUnusable)

        state.zoomAtCenter(byFactor: 1.2)
        XCTAssertNil(state.notice)
    }

    // MARK: - SICK-032b2c-K2: Bedienfläche ist die sichtbare Canvas

    /// **Pflichtnachweis:** Ein Pan vollständig im unsichtbaren linken
    /// Letterbox-Rand (`800 × 600`, Canvas `x: 100...700`) verschiebt den
    /// Ausschnitt nicht -- beide Endpunkte klammern auf denselben
    /// Canvasrand-Weltpunkt.
    func testPanEntirelyWithinTheLeftLetterboxMarginDoesNotChangeTheViewport() throws {
        var state = try zoomedState()
        state.select(tool: .pan)
        let before = state.viewport

        state.beginDrag(at: CGPoint(x: 0, y: 300), in: size)
        state.updateDrag(to: CGPoint(x: 50, y: 300), in: size)

        XCTAssertEqual(state.viewport, before)
    }

    /// **Pflichtnachweis:** Ein Pan, der von innen über den Canvasrand
    /// hinauszieht, stoppt dort; weitere Bewegung im selben Letterbox-Rand
    /// ändert nichts mehr.
    func testPanFromInsidePastTheCanvasEdgeStopsThereAndFurtherMovementChangesNothing() throws {
        var state = try zoomedState()
        state.select(tool: .pan)

        state.beginDrag(at: CGPoint(x: 400, y: 300), in: size)
        state.updateDrag(to: CGPoint(x: 100, y: 300), in: size)
        let atEdge = state.viewport

        state.updateDrag(to: CGPoint(x: 0, y: 300), in: size)
        XCTAssertEqual(state.viewport, atEdge, "Weitere Bewegung im selben Rand ändert nichts mehr")
    }

    /// **Pflichtnachweis:** Ein Rahmenzoom mit einer Ecke außerhalb der
    /// Canvas entspricht exakt derselben Geste mit der Ecke am
    /// Canvasrand.
    func testRectangleZoomWithACornerOutsideTheCanvasMatchesTheSameGestureWithTheCornerAtTheEdge() throws {
        var outsideState = ScanFieldViewState()
        outsideState.select(tool: .rectangle)
        outsideState.beginDrag(at: CGPoint(x: 300, y: 200), in: size)
        let outsideOutcome = outsideState.endDrag(at: CGPoint(x: 5_000, y: 500), in: size, zones: [])

        var edgeState = ScanFieldViewState()
        edgeState.select(tool: .rectangle)
        edgeState.beginDrag(at: CGPoint(x: 300, y: 200), in: size)
        let edgeOutcome = edgeState.endDrag(at: CGPoint(x: 700, y: 500), in: size, zones: [])

        XCTAssertEqual(outsideOutcome, edgeOutcome)
        XCTAssertEqual(outsideState.viewport, edgeState.viewport)
        XCTAssertEqual(edgeOutcome, .viewportChanged, "Sonst prüft der Test nichts")
    }

    /// **Pflichtnachweis:** Der sichtbare Gummirahmen verlässt
    /// ``LinearScanFieldGeometry/canvasRect`` nicht, auch wenn die Geste
    /// weit darüber hinausgezogen wird.
    func testTheVisibleRubberBandNeverLeavesTheCanvasRect() throws {
        var state = ScanFieldViewState()
        state.select(tool: .rectangle)
        state.beginDrag(at: CGPoint(x: -500, y: -400), in: size)
        state.updateDrag(to: CGPoint(x: 5_000, y: 4_000), in: size)

        let rect = try XCTUnwrap(state.rubberBandRect(in: size))
        let canvas = state.geometry(in: size).canvasRect
        XCTAssertTrue(canvas.contains(rect) || rect == canvas, "\(rect) muss innerhalb \(canvas) liegen")
        XCTAssertEqual(rect, canvas, "Ein Rahmen weit jenseits jeder Kante füllt die Canvas exakt aus")
    }

    /// **Gegenprobe zu den drei Tests oben:** Die direkte, ungeklammerte
    /// Bedienumkehr (`worldPoint(forScreenPoint:)`) statt
    /// `boundedWorldPoint(forScreenPoint:)` lässt einen Pan vollständig im
    /// Letterbox-Rand tatsächlich wirken -- der Beweis, dass eine direkte
    /// Verwendung der ungeklammerten Umkehrung in Zoom/Pan/Rahmen die
    /// obigen Nachweise bräche (Pflichtnachweis „Gegenproben",
    /// `.agent_handoff/task-sick-032b2c-k2.md`).
    func testUsingTheUnclampedInversionDirectlyWouldMoveTheViewportInTheLetterboxMargin() throws {
        let state = try zoomedState()
        let geo = state.geometry(in: size)
        let startWorld = try XCTUnwrap(geo.worldPoint(forScreenPoint: CGPoint(x: 0, y: 300)))
        let endWorld = try XCTUnwrap(geo.worldPoint(forScreenPoint: CGPoint(x: 50, y: 300)))
        XCTAssertNotEqual(
            Double(startWorld.x), Double(endWorld.x), accuracy: 1e-9,
            "Die ungeklammerte Umkehrung unterscheidet beide Letterbox-Punkte -- anders als boundedWorldPoint"
        )
    }

    // MARK: - Invariante über alle Bedienhandlungen

    /// Jede Bedienfolge liefert einen Ausschnitt, den die **strenge**
    /// Fabrik akzeptiert -- der Reducer kann also keinen ungültigen
    /// Zustand erzeugen.
    func testEveryReachableWindowSurvivesTheStrictFactory() throws {
        var state = ScanFieldViewState()
        var seed: UInt64 = 0x032B_2_5EED
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }

        for step in 0..<1_500 {
            let point = CGPoint(x: next() * 800, y: next() * 600)
            switch step % 6 {
            case 0: state.zoomAtCenter(byFactor: 0.2 + next() * 3)
            case 1: state.zoomAtPointer(byScrollEvent: trackpadScroll((next() - 0.5) * 240), at: point, in: size)
            case 2: state.zoomAtPointer(byMagnification: (next() - 0.5), at: point, in: size)
            case 3:
                state.select(tool: .pan)
                state.beginDrag(at: point, in: size)
                state.updateDrag(to: CGPoint(x: next() * 800, y: next() * 600), in: size)
                _ = state.endDrag(at: CGPoint(x: next() * 800, y: next() * 600), in: size, zones: [])
            case 4:
                state.select(tool: .rectangle)
                state.beginDrag(at: point, in: size)
                _ = state.endDrag(at: CGPoint(x: next() * 800, y: next() * 600), in: size, zones: [])
            default:
                if next() < 0.1 { state.showFullField() }
            }

            let viewport = state.viewport
            XCTAssertNoThrow(
                try ScanPlaneViewport.build(
                    centerX: viewport.centerX, centerY: viewport.centerY, halfExtent: viewport.halfExtent
                ),
                "Schritt \(step) hat einen ungültigen Ausschnitt erzeugt: \(viewport)"
            )
        }
    }

    // MARK: - „Tatsächlich angewandt" (SICK-032c3b)
    //
    // Grundlage für „manuelle Navigation sperrt, Ablehnung/Wirkungs-
    // losigkeit nicht" (`.agent_handoff/task-sick-032c3b.md`): Die
    // Entscheidung, ob eine Viewportbedienung wirklich etwas bewegt hat,
    // liegt in diesen Rückgabewerten -- nicht in einer zweiten SwiftUI-
    // Heuristik. Pflichtnachweis 4.

    func testZoomAtCenterReturnsTrueWhenTheViewportActuallyChanges() throws {
        var state = try zoomedState()
        XCTAssertTrue(state.zoomAtCenter(byFactor: 2))
    }

    func testZoomAtCenterReturnsFalseWhenTheFactorIsRejected() {
        var state = ScanFieldViewState()
        XCTAssertFalse(state.zoomAtCenter(byFactor: -1))
        XCTAssertNotNil(state.notice)
    }

    func testZoomAtPointerReturnsTrueWhenTheViewportActuallyChanges() throws {
        var state = try zoomedState()
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)
        XCTAssertTrue(state.zoomAtPointer(byFactor: 1.5, at: point, in: size))
    }

    func testZoomAtPointerReturnsFalseWhenTheGeometryIsUnusable() {
        var state = ScanFieldViewState()
        XCTAssertFalse(
            state.zoomAtPointer(byFactor: 1.5, at: CGPoint(x: 10, y: 10), in: CGSize(width: 0, height: 0))
        )
    }

    func testShowFullFieldReturnsFalseWhenAlreadyShowingTheFullField() {
        var state = ScanFieldViewState()
        XCTAssertTrue(state.viewport.isFullField)
        XCTAssertFalse(state.showFullField())
    }

    func testShowFullFieldReturnsTrueWhenLeavingAZoomedState() throws {
        var state = try zoomedState()
        XCTAssertTrue(state.showFullField())
    }

    /// **Der Kernfall:** Ein Zug ohne Nettoverschiebung seit Gestenbeginn
    /// (derselbe Bildschirmpunkt bei Beginn und Ende, etwa ein Klick mit
    /// gewähltem Verschieben-Werkzeug) meldet ``.nothing``, **nicht**
    /// ``.viewportChanged`` -- sonst sperrte ein bloßer Klick fälschlich
    /// den automatischen Learn-Fokus.
    func testAZeroMovementPanReportsNothingNotViewportChanged() throws {
        var state = try zoomedState()
        state.select(tool: .pan)
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)
        state.beginDrag(at: point, in: size)
        let outcome = state.endDrag(at: point, in: size, zones: [])
        XCTAssertEqual(outcome, .nothing)
        XCTAssertEqual(state.viewport, try zoomedState().viewport)
    }

    /// Dieselbe Prüfung während der laufenden Geste (``updateDrag``), die
    /// live -- nicht erst am Ende -- meldet.
    func testAZeroMovementPanDuringTheGestureReportsNothing() throws {
        var state = try zoomedState()
        state.select(tool: .pan)
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)
        state.beginDrag(at: point, in: size)
        let outcome = state.updateDrag(to: point, in: size)
        XCTAssertEqual(outcome, .nothing)
    }

    /// Die Gegenrichtung: Eine echte Verschiebung meldet weiterhin
    /// ``.viewportChanged`` -- dieselbe Erwartung wie
    /// ``testEndingAPanReportsAViewportChangeAndSelectsNoZone``, hier als
    /// zusätzlicher Beleg für ``updateDrag(to:in:)``.
    func testAnEffectivePanDuringTheGestureReportsViewportChanged() throws {
        var state = try zoomedState()
        state.select(tool: .pan)
        state.beginDrag(at: screenPoint(angle: 0.5, radius: 0.5, in: state), in: size)
        let outcome = state.updateDrag(to: screenPoint(angle: 0.2, radius: 0.2, in: state), in: size)
        XCTAssertEqual(outcome, .viewportChanged)
    }

    // MARK: - Learn-Fokus anwenden/verweigern (SICK-032c3b)

    func testApplyLearnFocusResultSetsExactlyTheGivenViewportAndClearsDragAndNotice() throws {
        var state = try zoomedState()
        state.select(tool: .pan)
        state.beginDrag(at: screenPoint(angle: 0.5, radius: 0.5, in: state), in: size)
        state.noteLearnFocusRefusal(.noProfile)

        let target = try ScanPlaneViewport.build(centerX: 0.1, centerY: -0.2, halfExtent: 0.05)
        let result = ScanFieldFocusArea.Result(
            valueRange: 100...200, viewport: target,
            carriedMeasurementCount: 3, ignoredAsUnusableCount: 0, ignoredAsOutlierCount: 0
        )

        state.applyLearnFocusResult(result)

        XCTAssertEqual(state.viewport, target)
        XCTAssertNil(state.drag)
        XCTAssertNil(state.notice)
    }

    func testNoteLearnFocusRefusalSetsAMatchingNoticeAndLeavesTheViewportUnchanged() throws {
        var state = try zoomedState()
        let before = state.viewport

        state.noteLearnFocusRefusal(.noUsableMeasurement)

        XCTAssertEqual(state.viewport, before)
        XCTAssertEqual(state.notice, .learnFocusUnavailable(.noUsableMeasurement))
        XCTAssertEqual(state.notice?.message, ScanFieldFocusArea.Refusal.noUsableMeasurement.operatorText)
    }
}
