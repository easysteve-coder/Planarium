import XCTest
import CoreGraphics
@testable import SickPLSMonitorKit

// MARK: - Gemeinsame Ereignisbauer des Testziels

/// Ein Trackpad-/Magic-Mouse-Ereignis: ``deltaY`` in **Punkten**.
func trackpadScroll(_ deltaY: Double) -> ScanFieldScrollEvent {
    ScanFieldScrollEvent(deltaY: deltaY, hasPreciseDeltas: true, isDirectionInvertedFromDevice: false)
}

/// Ein klassisches Mausrad: ``deltaY`` zählt **Rastungen**.
func wheelScroll(_ lines: Double) -> ScanFieldScrollEvent {
    ScanFieldScrollEvent(deltaY: lines, hasPreciseDeltas: false, isDirectionInvertedFromDevice: false)
}

/// **Die Zoomrechnung des Scanfelds** (SICK-032b2b).
///
/// Anlass war ein Fehlerbericht aus dem laufenden Gerätetest: Beim
/// Hineinzoomen sprang das Messfeld sichtbar. Die Ursache lag in drei
/// belegten Fehlern der Übersetzung Zeigerereignis -> Ausschnitt; jeder
/// von ihnen hat hier mindestens eine eigene Regression.
///
/// **Diese Tests vergleichen bewusst nicht den Weg mit sich selbst.** Sie
/// prüfen Zusagen, die unabhängig von der Umsetzung formulierbar sind:
/// „hin und zurück lässt alles, wie es war", „dieselbe Strecke wirkt
/// gleich, egal in wie vielen Ereignissen sie kommt", „was unter dem
/// Zeiger liegt, bleibt dort", „ein Winkel, den es nicht gibt, wird nicht
/// als Anker benutzt".
@MainActor final class ScanFieldZoomTests: XCTestCase {

    private let size = CGSize(width: 800, height: 600)
    private var fan: FanScreenGeometry { FanScreenGeometry(size: size) }

    private func zoomedState() throws -> ScanFieldViewState {
        var state = ScanFieldViewState()
        state.zoomAtCenter(byFactor: 4)
        XCTAssertFalse(state.viewport.isFullField, "Sonst prüft der Test die Gesamtansicht")
        return state
    }

    private func screenPoint(angle: Double, radius: Double, in state: ScanFieldViewState) -> CGPoint {
        state.geometry(in: size).project(angleFraction: angle, radiusFraction: radius).screenPoint
    }

    private func assertViewportsAreEqual(
        _ actual: ScanPlaneViewport, _ expected: ScanPlaneViewport,
        accuracy: Double, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.centerX, expected.centerX, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.centerY, expected.centerY, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.halfExtent, expected.halfExtent, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - Ursache 1: der Faktor war affin statt multiplikativ

    /// **Die Kernregression.** Gemessen am Stand vor diesem Slice wuchs
    /// die Entfernungsspanne bei zehn Mal „vor und zurück gescrollt" von
    /// `0,25` auf `0,376` -- ein Weglaufen um die Hälfte aus einer
    /// Bewegung, die unterm Strich null Strecke hatte. Ursache war
    /// `1 + Strecke * k`: `1,2 * 0,8 = 0,96`.
    func testScrollingBackAndForthLeavesTheViewportExactlyWhereItWas() throws {
        var state = try zoomedState()
        let reference = state.viewport
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)

        for _ in 0..<10 {
            state.zoomAtPointer(byScrollEvent: trackpadScroll(20), at: point, in: size)
            state.zoomAtPointer(byScrollEvent: trackpadScroll(-20), at: point, in: size)
        }

        assertViewportsAreEqual(
            state.viewport, reference, accuracy: 1e-12,
            "Zehn neutrale Scrollbewegungen dürfen den Ausschnitt nicht verschieben"
        )
    }

    /// Dasselbe eine Stufe tiefer und ohne Ansicht: Die beiden Faktoren
    /// sind exakte Kehrwerte.
    func testOppositeScrollDistancesAreExactReciprocals() throws {
        for distance in [1.0, 7.5, 16, 40, 60, 10_000] {
            let forward = try XCTUnwrap(ScanFieldZoomInput.zoomFactor(forScrollDistanceInPoints: distance))
            let backward = try XCTUnwrap(ScanFieldZoomInput.zoomFactor(forScrollDistanceInPoints: -distance))
            XCTAssertEqual(forward * backward, 1.0, accuracy: 1e-12, "Strecke \(distance)")
        }
    }

    /// **Ursache 2: Das Ergebnis hing davon ab, wie macOS die Bewegung in
    /// Ereignisse zerlegt.** Vorher ergab eine Strecke von 40 in einem
    /// Ereignis `0,1786`, dieselbe Strecke in zwei Ereignissen `0,1736`.
    /// Wie viele Ereignisse das System schickt, ist nicht Sache des
    /// Bedienenden.
    func testTheSameScrollDistanceActsTheSameHoweverItIsSplitIntoEvents() throws {
        let point = screenPoint(angle: 0.5, radius: 0.5, in: try zoomedState())

        var inOneEvent = try zoomedState()
        inOneEvent.zoomAtPointer(byScrollEvent: trackpadScroll(48), at: point, in: size)

        for pieces in [2, 3, 4, 6, 8, 16] {
            var split = try zoomedState()
            for _ in 0..<pieces {
                split.zoomAtPointer(byScrollEvent: trackpadScroll(48 / Double(pieces)), at: point, in: size)
            }
            assertViewportsAreEqual(
                split.viewport, inOneEvent.viewport, accuracy: 1e-12,
                "Dieselbe Strecke in \(pieces) Ereignissen muss dasselbe bewirken"
            )
        }
    }

    /// Die Begrenzung je Ereignis ist **symmetrisch** -- vorher waren
    /// ihre beiden Enden `1,4` und `0,6` und damit keine Kehrwerte.
    func testThePerEventLimitIsSymmetric() throws {
        let inward = try XCTUnwrap(ScanFieldZoomInput.zoomFactor(for: trackpadScroll(1e9)))
        let outward = try XCTUnwrap(ScanFieldZoomInput.zoomFactor(for: trackpadScroll(-1e9)))

        XCTAssertEqual(inward * outward, 1.0, accuracy: 1e-12)
        XCTAssertEqual(
            inward,
            try XCTUnwrap(ScanFieldZoomInput.zoomFactor(
                forScrollDistanceInPoints: ScanFieldZoomInput.maximumScrollPointsPerEvent
            )),
            accuracy: 1e-12
        )
        XCTAssertLessThan(inward, 1.5, "Ein einzelnes Ereignis darf nicht springen")
        XCTAssertGreaterThan(inward, 1.2, "Sonst wäre die Grenze unbrauchbar eng")
    }

    // MARK: - Ursache 3: Einheit und Richtung des Ereignisses

    /// **Eine Rastung des Mausrads ist keine Punktstrecke.** Vorher war
    /// `deltaY == 1` ein Faktor von `1,01`; zehn Rastungen kamen auf
    /// `1,10` und das Rad war praktisch wirkungslos.
    func testAWheelDetentCountsAsLinesAndNotAsPoints() throws {
        let detent = try XCTUnwrap(ScanFieldZoomInput.zoomFactor(for: wheelScroll(1)))
        let sameDistanceOnATrackpad = try XCTUnwrap(
            ScanFieldZoomInput.zoomFactor(for: trackpadScroll(ScanFieldZoomInput.pointsPerWheelLine))
        )
        XCTAssertEqual(detent, sameDistanceOnATrackpad, accuracy: 1e-12)

        var state = try zoomedState()
        let reference = state.viewport
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)
        for _ in 0..<10 { state.zoomAtPointer(byScrollEvent: wheelScroll(1), at: point, in: size) }

        XCTAssertGreaterThan(
            reference.halfExtent / state.viewport.halfExtent, 2.0,
            "Zehn Rastungen müssen deutlich mehr als eine Verdopplung ergeben"
        )
    }

    /// **Die Richtung folgt dem Gerät, nicht der Scrolleinstellung.**
    /// Dieselbe Handbewegung darf ihre Wirkung nicht umkehren, nur weil
    /// „natürliches Scrollen" umgestellt wurde.
    func testTheZoomDirectionFollowsTheDeviceAndNotTheScrollingPreference() throws {
        let normal = ScanFieldScrollEvent(
            deltaY: 20, hasPreciseDeltas: true, isDirectionInvertedFromDevice: false
        )
        // Dieselbe Gerätebewegung, vom System bereits umgedreht gemeldet.
        let inverted = ScanFieldScrollEvent(
            deltaY: -20, hasPreciseDeltas: true, isDirectionInvertedFromDevice: true
        )

        XCTAssertEqual(
            try XCTUnwrap(ScanFieldZoomInput.zoomFactor(for: normal)),
            try XCTUnwrap(ScanFieldZoomInput.zoomFactor(for: inverted)),
            accuracy: 1e-12
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(ScanFieldZoomInput.zoomFactor(for: normal)), 1,
            "Vom Bedienenden weg geschoben zoomt hinein"
        )
        XCTAssertLessThan(
            try XCTUnwrap(ScanFieldZoomInput.zoomFactor(
                for: ScanFieldScrollEvent(deltaY: 20, hasPreciseDeltas: true, isDirectionInvertedFromDevice: true)
            )),
            1,
            "Die umgekehrte Gerätebewegung zoomt heraus"
        )
    }

    /// Die isolierte Einheit der Ereignisnaht, für sich geprüft: Strecke
    /// in Punkten, Richtung, Begrenzung.
    func testTheScrollDistanceTranslationIsExplicitAboutUnitAndDirection() throws {
        XCTAssertEqual(
            try XCTUnwrap(ScanFieldZoomInput.scrollDistanceInPoints(for: trackpadScroll(12))), 12
        )
        XCTAssertEqual(
            try XCTUnwrap(ScanFieldZoomInput.scrollDistanceInPoints(for: wheelScroll(3))),
            3 * ScanFieldZoomInput.pointsPerWheelLine
        )
        XCTAssertEqual(
            try XCTUnwrap(ScanFieldZoomInput.scrollDistanceInPoints(
                for: ScanFieldScrollEvent(deltaY: 12, hasPreciseDeltas: true, isDirectionInvertedFromDevice: true)
            )),
            -12
        )
        XCTAssertEqual(
            try XCTUnwrap(ScanFieldZoomInput.scrollDistanceInPoints(for: wheelScroll(1_000))),
            ScanFieldZoomInput.maximumScrollPointsPerEvent,
            "Auch eine beschleunigte Rastungsfolge bleibt begrenzt"
        )
        XCTAssertEqual(
            try XCTUnwrap(ScanFieldZoomInput.scrollDistanceInPoints(for: trackpadScroll(0))), 0
        )
        XCTAssertEqual(
            try XCTUnwrap(ScanFieldZoomInput.zoomFactor(forScrollDistanceInPoints: 0)), 1,
            "Keine Bewegung, kein Zoom"
        )
    }

    // MARK: - Die Fächerspitze

    /// **Dort gibt es keinen Winkel** -- und seit SICK-032b2b sagt die
    /// Geometrie das auch, statt den Artefaktwert von `atan2(0, 0)` als
    /// Messwert auszugeben.
    func testTheFanApexReportsThatItCarriesNoAngle() throws {
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: .fullField)

        let apex = try XCTUnwrap(geometry.fieldCoordinate(forScreenPoint: fan.center))
        XCTAssertFalse(apex.isAngleDefined)
        XCTAssertEqual(apex.radiusFraction, 0, "Die Entfernung ist dort sehr wohl bestimmt")

        for offset in [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1)] {
            let nearby = try XCTUnwrap(geometry.fieldCoordinate(
                forScreenPoint: CGPoint(x: fan.center.x + offset.x, y: fan.center.y + offset.y)
            ))
            XCTAssertTrue(
                nearby.isAngleDefined,
                "Nur der Mittelpunkt selbst trägt keinen Winkel, kein Umfeld davon"
            )
        }
    }

    /// **Die zweite Kernregression, seit SICK-032b2c strukturell
    /// unmöglich statt durch einen Sonderfall verhindert.** Vorher riss
    /// ein Zoom genau auf der Spitze den Winkelausschnitt gegen seine
    /// obere Kante -- gemessen `[0,2857 … 1,0]` nach einem Schritt, und
    /// weitere Schritte hielten ihn dort fest -- weil der Zoomanker
    /// selbst eine Feldkoordinate (mit einem erfundenen Winkel an der
    /// Spitze) war. Seit SICK-032b2c ist der Zoomanker eine **kanonische
    /// Weltposition**, und die Spitze ist darin nur der Ursprung -- ein
    /// gewöhnlicher, wohldefinierter Punkt. Ein Zoom dort ist ein Zoom
    /// **um den Ursprung**, ohne jede Sonderbehandlung.
    func testZoomingExactlyOnTheFanApexZoomsAroundTheWorldOrigin() throws {
        var state = ScanFieldViewState()

        for step in 1...3 {
            state.zoomAtPointer(byFactor: 1.4, at: fan.center, in: size)

            XCTAssertEqual(
                state.viewport.centerX, 0, accuracy: 1e-12,
                "Schritt \(step): der Mittelpunkt bleibt auf dem Ursprung"
            )
            XCTAssertEqual(
                state.viewport.centerY, 0, accuracy: 1e-12,
                "Schritt \(step): der Mittelpunkt bleibt auf dem Ursprung"
            )
            XCTAssertLessThan(
                state.viewport.halfExtent, ScanPlaneViewport.fullField.halfExtent,
                "Schritt \(step): trotzdem wirklich gezoomt"
            )
        }
    }

    /// Und die Gegenrichtung: Ein Bildpunkt neben der Spitze zoomt um
    /// **seine eigene** Weltposition, nicht um den Ursprung.
    func testOnePixelBesideTheApexZoomsAroundItsOwnWorldPosition() throws {
        var state = ScanFieldViewState()
        let beside = CGPoint(x: fan.center.x - 1, y: fan.center.y)
        let anchor = try XCTUnwrap(state.geometry(in: size).worldPoint(forScreenPoint: beside))
        XCTAssertNotEqual(Double(anchor.x), 0, accuracy: 1e-9, "Sonst prüft dieser Test nichts")

        let expected = state.viewport.zoomed(
            byFactor: 1.4, anchorX: Double(anchor.x), anchorY: Double(anchor.y)
        )
        state.zoomAtPointer(byFactor: 1.4, at: beside, in: size)
        XCTAssertEqual(state.viewport, expected.viewport)
    }

    // MARK: - Ankererhaltung über wiederholte Schritte, beide Achsen

    /// **Was unter dem Zeiger liegt, bleibt unter dem Zeiger** -- nicht
    /// nur bei einem Schritt, sondern über eine ganze Folge, und über
    /// alle drei Eingabekanäle.
    ///
    /// Gemessen wird die **Bildschirmposition** derselben Feldkoordinate
    /// vor und nach jedem Schritt; das ist eine Zusage über die Wirkung
    /// und keine zweite Rechnung desselben Wegs.
    func testRepeatedZoomingKeepsTheFieldPointUnderThePointerOnBothAxes() throws {
        // Seit SICK-032b2c-K1 sitzt `fan.center` in der wirklichen
        // Canvasmitte (`(400, 300)` für 800×600); der 180°-Öffnungswinkel
        // deckt weiterhin nur die **obere** Hälfte ab (`sin <= 0`,
        // Auftragspunkt 2), die untere bleibt bewusst leer. Diese vier
        // Sonden liegen deshalb bei `y <= 300` -- ein Punkt in der
        // unteren, leeren Hälfte (etwa das alte `(700, 520)`) hat gar
        // keinen gültigen Feldwinkel und ist kein sinnvoller Anker für
        // diesen Rundlauf-Vergleich.
        let probes = [
            CGPoint(x: 400, y: 300), CGPoint(x: 250, y: 200),
            CGPoint(x: 600, y: 150), CGPoint(x: 400, y: 120),
        ]
        let channels: [(String, (inout ScanFieldViewState, CGPoint) -> Void)] = [
            ("Scrollrad", { state, point in
                state.zoomAtPointer(byScrollEvent: wheelScroll(1), at: point, in: self.size)
            }),
            ("Trackpad", { state, point in
                state.zoomAtPointer(byScrollEvent: trackpadScroll(18), at: point, in: self.size)
            }),
            ("Pinch", { state, point in
                state.zoomAtPointer(byMagnification: 0.12, at: point, in: self.size)
            }),
        ]

        for probe in probes {
            for (name, zoom) in channels {
                var state = ScanFieldViewState()
                for step in 1...12 {
                    let before = try XCTUnwrap(
                        state.geometry(in: size).fieldCoordinate(forScreenPoint: probe)
                    )
                    let halfExtentBefore = state.viewport.halfExtent
                    zoom(&state, probe)
                    XCTAssertLessThan(
                        state.viewport.halfExtent, halfExtentBefore,
                        "\(name) bei \(probe), Schritt \(step): gar nicht gezoomt -- dann sagt der Test nichts"
                    )

                    let after = state.geometry(in: size).project(
                        angleFraction: before.angleFraction, radiusFraction: before.radiusFraction
                    ).screenPoint
                    XCTAssertEqual(
                        Double(after.x), Double(probe.x), accuracy: 1e-9,
                        "\(name) bei \(probe), Schritt \(step): waagerecht weggewandert"
                    )
                    XCTAssertEqual(
                        Double(after.y), Double(probe.y), accuracy: 1e-9,
                        "\(name) bei \(probe), Schritt \(step): senkrecht weggewandert"
                    )
                }
            }
        }
    }

    // MARK: - Ränder, Anschlag und unbrauchbare Eingaben

    /// Am Feldrand hört der Ausschnitt auf, statt überzulaufen -- und er
    /// bleibt in jedem Schritt gültig.
    func testZoomingOutAtAViewportCornerStaysInsideTheField() throws {
        var state = try zoomedState()
        state.zoomAtCenter(byFactor: 4)
        let corner = screenPoint(
            angle: 1.0, radius: 1.0, in: state
        )

        for step in 1...20 {
            state.zoomAtPointer(byScrollEvent: trackpadScroll(-40), at: corner, in: size)
            let viewport = state.viewport
            XCTAssertGreaterThanOrEqual(viewport.xLowerBound, -1, "Schritt \(step)")
            XCTAssertLessThanOrEqual(viewport.xUpperBound, 1, "Schritt \(step)")
            XCTAssertGreaterThanOrEqual(viewport.yLowerBound, -1, "Schritt \(step)")
            XCTAssertLessThanOrEqual(viewport.yUpperBound, 1, "Schritt \(step)")
            XCTAssertNoThrow(
                try ScanPlaneViewport.build(
                    centerX: viewport.centerX, centerY: viewport.centerY, halfExtent: viewport.halfExtent
                ),
                "Schritt \(step) hat einen ungültigen Ausschnitt erzeugt: \(viewport)"
            )
        }
        XCTAssertEqual(state.viewport, .fullField, "Weit genug herausgezoomt ist das ganze Feld")
    }

    /// Am Anschlag der Mindestspanne bleibt ein weiterer Schritt
    /// wirkungslos -- und stürzt nicht ab und kippt nicht um.
    func testZoomingInBeyondTheMinimumSpanIsStable() throws {
        var state = ScanFieldViewState()
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)
        for _ in 0..<200 { state.zoomAtPointer(byScrollEvent: trackpadScroll(60), at: point, in: size) }
        let atStop = state.viewport

        XCTAssertEqual(atStop.halfExtent, ScanPlaneViewport.minimumHalfExtent, accuracy: 1e-12)

        for _ in 0..<5 { state.zoomAtPointer(byScrollEvent: trackpadScroll(60), at: point, in: size) }
        XCTAssertEqual(state.viewport, atStop)
    }

    /// Nicht endliche Eingaben lassen den Ausschnitt unangetastet und
    /// werden sichtbar -- auf **beiden** Zeigerkanälen.
    func testNonFinitePointerInputChangesNothingAndIsVisible() throws {
        for bad in [Double.nan, .infinity, -.infinity] {
            var scrolled = try zoomedState()
            let reference = scrolled.viewport
            scrolled.zoomAtPointer(
                byScrollEvent: trackpadScroll(bad), at: CGPoint(x: 400, y: 300), in: size
            )
            XCTAssertEqual(scrolled.viewport, reference, "Scrollstrecke \(bad)")
            XCTAssertEqual(scrolled.notice, .viewGeometryUnusable, "Scrollstrecke \(bad)")

            var pinched = try zoomedState()
            pinched.zoomAtPointer(byMagnification: bad, at: CGPoint(x: 400, y: 300), in: size)
            XCTAssertEqual(pinched.viewport, reference, "Pinch \(bad)")
            XCTAssertEqual(pinched.notice, .viewGeometryUnusable, "Pinch \(bad)")

            XCTAssertNil(ScanFieldZoomInput.zoomFactor(for: trackpadScroll(bad)))
            XCTAssertNil(ScanFieldZoomInput.zoomFactor(forMagnification: bad))
            XCTAssertNil(ScanFieldZoomInput.zoomFactor(forScrollDistanceInPoints: bad))
        }
    }

    /// Ein Pinch-Ereignis kann rechnerisch einen Faktor `<= 0` ergeben
    /// (`magnification <= -1`). Der ist bedeutungslos -- er wird
    /// geklammert, statt den Ausschnitt zu spiegeln oder abgelehnt zu
    /// werden.
    func testAnExtremePinchIsBoundedInsteadOfTurningTheFieldInsideOut() throws {
        for magnification in [-5.0, -1.0, -0.999, 12.0] {
            let factor = try XCTUnwrap(ScanFieldZoomInput.zoomFactor(forMagnification: magnification))
            XCTAssertGreaterThanOrEqual(factor, ScanFieldZoomInput.minimumPinchFactor)
            XCTAssertLessThanOrEqual(factor, ScanFieldZoomInput.maximumPinchFactor)
        }
        XCTAssertEqual(
            ScanFieldZoomInput.minimumPinchFactor * ScanFieldZoomInput.maximumPinchFactor, 1,
            accuracy: 1e-12, "Auch die Pinch-Grenzen sind Kehrwerte"
        )

        var state = try zoomedState()
        let point = screenPoint(angle: 0.5, radius: 0.5, in: state)
        let before = state.viewport
        state.zoomAtPointer(byMagnification: -5, at: point, in: size)
        XCTAssertGreaterThan(
            state.viewport.halfExtent, before.halfExtent,
            "Ein starkes Aufziehen zoomt heraus -- es spiegelt das Feld nicht"
        )
    }

    // MARK: - Die Grenze der Ereignisnaht

    /// **Die AppKit-Naht reicht das ganze Ereignis weiter.** Nähme sie
    /// eine der beiden Systemangaben weg, stünde die Rechnung wieder vor
    /// einer Zahl ohne Einheit und ohne Richtung -- genau der Zustand vor
    /// diesem Slice.
    func testThePointerBridgeForwardsUnitAndDirectionOfTheSystemEvent() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SickPLSMonitor/ScanFieldPointerEvents.swift")
        let code = try String(contentsOf: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for needle in [
            "hasPreciseDeltas: event.hasPreciseScrollingDeltas",
            "isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice",
            "deltaY: Double(event.scrollingDeltaY)"
        ] {
            XCTAssertTrue(code.contains(needle), "Die Ereignisnaht muss \(needle) weiterreichen")
        }
        for needle in ["ScanFieldZoomInput", "pointsPerWheelLine", "exp2", "scrollPointsPerDoubling"] {
            XCTAssertFalse(code.contains(needle), "Die Ereignisnaht darf \(needle) nicht kennen")
        }
    }

    /// Und die Gegenrichtung: Die Kennlinie steht an **einer** Stelle des
    /// Moduls. Eine zweite wäre eine zweite Wahrheit darüber, wie stark
    /// ein Scrollereignis wirkt.
    func testTheZoomCurveExistsExactlyOnce() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SickPLSMonitorKit")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "Sonst prüft dieser Test nichts")

        var carriers: [String] = []
        for file in files where try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter({ !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
            .joined(separator: "\n")
            .contains("exp2(") {
            carriers.append(file.lastPathComponent)
        }
        XCTAssertEqual(carriers, ["ScanFieldZoomInput.swift"])
    }
}
