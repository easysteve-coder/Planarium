import XCTest
@testable import SickPLSMonitorKit

/// Der Ausschnittswert selbst (SICK-032b1, seit SICK-032b2c
/// **planar/kartesisch**): Fabrik, Grenzen und die drei Werkzeuge --
/// Verschieben, Zoom am Anker, Rahmenzoom -- sowie ``ScanPlaneViewport/fullField``.
///
/// **Ohne Bildschirm, ohne Ansicht, ohne Gerät.** Die Bildschirmseite
/// steht in `LinearScanFieldGeometryTests`, die Trennung von Zonen und
/// Klangmapping in `ScanPlaneViewportIndependenceTests`.
///
/// ## Was sich gegenüber der alten `ScanViewportTests` geändert hat
///
/// Diese Datei ersetzt `ScanViewportTests.swift` vollständig -- der alte
/// `ScanViewport`-Typ (Winkel-/Entfernungsrechteck) ist entfallen
/// (SICK-032b2c). Drei Tests hatten keine sinnvolle Entsprechung mehr
/// und sind ersatzlos gestrichen, nicht mechanisch übersetzt:
///
/// - **Die „nominal exakte Spanne"-Rundungsfalle** (alt:
///   `testTheSpanRuleIsReadOnTheComputedDifference`) gab es nur, weil
///   die alte Fabrik eine Spanne aus zwei getrennt übergebenen Grenzen
///   *berechnete*. ``ScanPlaneViewport/build(centerX:centerY:halfExtent:)``
///   nimmt ``ScanPlaneViewport/halfExtent`` direkt entgegen -- es gibt
///   keine solche Subtraktion mehr, gegen die sich rundende Eingaben
///   verhalten könnten.
/// - **Die Anker-Klammerung beim Zoom** (alt:
///   `testAnAnchorOutsideTheFieldIsClampedRatherThanRejected`) war eine
///   Eigenschaft der alten winkel-/entfernungsanteiligen Formel. Die
///   neue, rein affine Formel braucht sie nicht: Ein beliebiger
///   `anchorX`/`anchorY`-Wert ist eine gültige Eingabe der linearen
///   Gleichung, geklammert wird -- wie bei jedem Werkzeug -- allein das
///   **Ergebnis** (``ScanPlaneViewportTests/testZoomingClampsOnlyTheResultingCenterNotTheAnchorItself``
///   hält das als bewusste, geprüfte Eigenschaft fest, statt es
///   stillschweigend zu verlieren).
/// - **Achsenweise Entartungsprüfung beim Rahmenzoom** (alt: zwei
///   Unterfälle von `testADegenerateRectangleIsRefusedOnEitherAxis`)
///   gilt nicht mehr: Der isotrope Rahmenzoom passt sich der **größeren**
///   Spanne an (Regel 3 in ``ScanPlaneViewport``), ein auf einer Achse
///   entarteter, auf der anderen ausgedehnter Rahmen ist deshalb **kein**
///   Klick mehr, sondern ein gültiges (quadratisches) Einpassen --
///   ``testARectangleDegenerateOnOnlyOneAxisStillFitsToTheOtherAxis``
///   hält das als eigene, bewusste Eigenschaft fest.
@MainActor final class ScanPlaneViewportTests: XCTestCase {

    private struct UnexpectedRejection: Error {}

    private func assertValid(
        _ viewport: ScanPlaneViewport,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(viewport.centerX.isFinite, "centerX endlich", file: file, line: line)
        XCTAssertTrue(viewport.centerY.isFinite, "centerY endlich", file: file, line: line)
        XCTAssertTrue(viewport.halfExtent.isFinite, "halfExtent endlich", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            viewport.halfExtent, ScanPlaneViewport.minimumHalfExtent,
            "halfExtent mindestens die Mindestspanne", file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            viewport.halfExtent, ScanPlaneViewport.maximumHalfExtent,
            "halfExtent höchstens die ganze Welt", file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(viewport.xLowerBound, -1, "x im Feld", file: file, line: line)
        XCTAssertLessThanOrEqual(viewport.xUpperBound, 1, "x im Feld", file: file, line: line)
        XCTAssertGreaterThanOrEqual(viewport.yLowerBound, -1, "y im Feld", file: file, line: line)
        XCTAssertLessThanOrEqual(viewport.yUpperBound, 1, "y im Feld", file: file, line: line)
        // Muss außerdem die strenge Fabrik überstehen -- sonst gäbe es
        // zwei Vorstellungen von „gültig".
        XCTAssertNoThrow(
            try ScanPlaneViewport.build(
                centerX: viewport.centerX, centerY: viewport.centerY, halfExtent: viewport.halfExtent
            ),
            file: file, line: line
        )
    }

    private func applied(
        _ change: ScanPlaneViewportChange,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ScanPlaneViewport {
        guard let viewport = change.viewport else {
            XCTFail("Werkzeug abgelehnt: \(change)", file: file, line: line)
            throw UnexpectedRejection()
        }
        assertValid(viewport, file: file, line: line)
        return viewport
    }

    // MARK: - Gesamtansicht und Fabrik

    func testTheFullFieldIsTheWholeCanonicalWorld() {
        let full = ScanPlaneViewport.fullField

        XCTAssertEqual(full.centerX, 0)
        XCTAssertEqual(full.centerY, 0)
        XCTAssertEqual(full.halfExtent, ScanPlaneViewport.maximumHalfExtent)
        XCTAssertEqual(full.xLowerBound, -1)
        XCTAssertEqual(full.xUpperBound, 1)
        XCTAssertEqual(full.yLowerBound, -1)
        XCTAssertEqual(full.yUpperBound, 1)
        XCTAssertTrue(full.isFullField)
        assertValid(full)
    }

    func testAZoomedWindowIsNotTheFullField() throws {
        let zoomed = try ScanPlaneViewport.build(centerX: 0.5, centerY: 0, halfExtent: 0.3)
        XCTAssertFalse(zoomed.isFullField)
    }

    func testTheFactoryRejectsEachViolationWithItsOwnError() {
        func error(centerX: Double, centerY: Double, halfExtent: Double) -> ScanPlaneViewport.BuildError? {
            do {
                _ = try ScanPlaneViewport.build(centerX: centerX, centerY: centerY, halfExtent: halfExtent)
                return nil
            } catch let buildError as ScanPlaneViewport.BuildError {
                return buildError
            } catch {
                return nil
            }
        }

        XCTAssertEqual(error(centerX: .nan, centerY: 0, halfExtent: 0.5), .nonFiniteInput)
        XCTAssertEqual(error(centerX: 0, centerY: .infinity, halfExtent: 0.5), .nonFiniteInput)
        XCTAssertEqual(error(centerX: 0, centerY: 0, halfExtent: .nan), .nonFiniteInput)
        XCTAssertEqual(error(centerX: 0, centerY: 0, halfExtent: 1e-5), .halfExtentTooSmall)
        XCTAssertEqual(error(centerX: 0, centerY: 0, halfExtent: 1.5), .halfExtentTooLarge)
        XCTAssertEqual(error(centerX: 0.9, centerY: 0, halfExtent: 0.5), .centerOutsideField)
        XCTAssertEqual(error(centerX: 0, centerY: -0.9, halfExtent: 0.5), .centerOutsideField)
    }

    /// Die Mindestspanne ist eine **Schranke**, kein Abstand: Genau auf
    /// ihr ist noch gültig, erst darunter wird abgelehnt. Dieselbe
    /// inklusive Grenzregel wie bei der Stale-Grenze der Prognose
    /// (SICK-015a).
    func testExactlyTheMinimumHalfExtentIsStillValid() throws {
        let viewport = try ScanPlaneViewport.build(
            centerX: 0, centerY: 0, halfExtent: ScanPlaneViewport.minimumHalfExtent
        )
        assertValid(viewport)
    }

    /// Genau auf der oberen Schranke ist ebenfalls noch gültig.
    func testExactlyTheMaximumHalfExtentIsStillValid() throws {
        let viewport = try ScanPlaneViewport.build(
            centerX: 0, centerY: 0, halfExtent: ScanPlaneViewport.maximumHalfExtent
        )
        assertValid(viewport)
        XCTAssertTrue(viewport.isFullField)
    }

    /// Ein von einem Werkzeug erzeugter Ausschnitt lässt sich immer
    /// wieder durch die strenge Fabrik schicken -- sonst gäbe es zwei
    /// Vorstellungen von „gültig", und ein gespeicherter und neu
    /// geladener Ausschnitt könnte plötzlich abgelehnt werden.
    func testAWindowProducedByAToolAlwaysSurvivesTheStrictFactory() throws {
        // Tief hineingezoomt an einem ungeraden Anker: genau die Lage,
        // in der die Mindestspanne knapp verfehlt würde.
        var viewport = ScanPlaneViewport.fullField
        for _ in 0..<40 {
            viewport = try applied(viewport.zoomed(byFactor: 3.7, anchorX: 0.3137, anchorY: -0.7919))
            _ = try ScanPlaneViewport.build(
                centerX: viewport.centerX, centerY: viewport.centerY, halfExtent: viewport.halfExtent
            )
        }
        XCTAssertGreaterThanOrEqual(viewport.halfExtent, ScanPlaneViewport.minimumHalfExtent)
    }

    // MARK: - Verschieben

    func testPanningKeepsTheHalfExtentExactly() throws {
        let start = try ScanPlaneViewport.build(centerX: 0.35, centerY: 0.25, halfExtent: 0.15)

        let moved = try applied(start.panned(byX: 0.15, byY: -0.05))

        XCTAssertEqual(moved.halfExtent, start.halfExtent, accuracy: 1e-12)
        XCTAssertEqual(moved.centerX, 0.5, accuracy: 1e-12)
        XCTAssertEqual(moved.centerY, 0.2, accuracy: 1e-12)
    }

    /// Am Rand hört die Bewegung auf -- der Ausschnitt wird **nicht**
    /// gestaucht und klappt nicht um.
    func testPanningStopsAtTheFieldEdgeWithoutShrinking() throws {
        let start = try ScanPlaneViewport.build(centerX: 0.7, centerY: -0.7, halfExtent: 0.1)

        let pushedUp = try applied(start.panned(byX: 5, byY: 5))
        XCTAssertEqual(pushedUp.centerX, 0.9, accuracy: 1e-12)
        XCTAssertEqual(pushedUp.centerY, 0.9, accuracy: 1e-12)
        XCTAssertEqual(pushedUp.halfExtent, start.halfExtent, accuracy: 1e-12)

        let pushedDown = try applied(start.panned(byX: -5, byY: -5))
        XCTAssertEqual(pushedDown.centerX, -0.9, accuracy: 1e-12)
        XCTAssertEqual(pushedDown.centerY, -0.9, accuracy: 1e-12)
        XCTAssertEqual(pushedDown.halfExtent, start.halfExtent, accuracy: 1e-12)
    }

    /// Die Gesamtansicht füllt das Feld bereits aus -- ein Schub ist
    /// ausgeführt und bewegt nichts. Das ist `applied`, nicht `rejected`.
    func testPanningTheFullFieldChangesNothingAndIsStillApplied() throws {
        let moved = try applied(ScanPlaneViewport.fullField.panned(byX: 0.3, byY: -0.3))
        XCTAssertEqual(moved, ScanPlaneViewport.fullField)
    }

    func testPanningRejectsNonFiniteInput() throws {
        let start = try ScanPlaneViewport.build(centerX: 0.35, centerY: 0.25, halfExtent: 0.15)

        XCTAssertEqual(start.panned(byX: .nan, byY: 0), .rejected(.nonFiniteInput))
        XCTAssertEqual(start.panned(byX: 0, byY: .infinity), .rejected(.nonFiniteInput))
    }

    // MARK: - Zoom am Anker

    /// Die Kernzusage für „am Zeiger zoomen": Der Anker behält seine
    /// **relative** Lage im Ausschnitt, der Ausschnitt wird enger.
    func testZoomingInKeepsTheAnchorAtItsRelativePosition() throws {
        let start = try ScanPlaneViewport.build(centerX: 0.4, centerY: 0.4, halfExtent: 0.2)
        let anchorX = 0.5   // 75 % der X-Spanne
        let anchorY = 0.3   // 25 % der Y-Spanne

        let zoomed = try applied(start.zoomed(byFactor: 2, anchorX: anchorX, anchorY: anchorY))

        XCTAssertEqual(zoomed.halfExtent, start.halfExtent / 2, accuracy: 1e-12)
        XCTAssertEqual(
            (anchorX - zoomed.xLowerBound) / (2 * zoomed.halfExtent), 0.75, accuracy: 1e-12,
            "Der Anker liegt weiterhin bei 75 % der X-Spanne"
        )
        XCTAssertEqual(
            (anchorY - zoomed.yLowerBound) / (2 * zoomed.halfExtent), 0.25, accuracy: 1e-12,
            "Der Anker liegt weiterhin bei 25 % der Y-Spanne"
        )
    }

    func testZoomingOutWidensTheWindowAroundTheSameAnchor() throws {
        let start = try ScanPlaneViewport.build(centerX: 0.5, centerY: 0.5, halfExtent: 0.1)

        let zoomed = try applied(start.zoomed(byFactor: 0.5, anchorX: 0.5, anchorY: 0.5))

        XCTAssertEqual(zoomed.halfExtent, start.halfExtent * 2, accuracy: 1e-12)
        XCTAssertEqual(zoomed.xLowerBound, 0.3, accuracy: 1e-12)
        XCTAssertEqual(zoomed.yUpperBound, 0.7, accuracy: 1e-12)
    }

    /// Ein Zoom hinein und wieder heraus mit demselben Anker und dem
    /// Kehrwert landet wieder beim Ausgangsausschnitt -- solange keine
    /// Schranke dazwischenkommt.
    func testZoomingInAndOutAgainReturnsToTheSameWindow() throws {
        let start = try ScanPlaneViewport.build(centerX: 0.5, centerY: 0.5, halfExtent: 0.25)

        let zoomedIn = try applied(start.zoomed(byFactor: 4, anchorX: 0.4, anchorY: 0.6))
        let zoomedOut = try applied(zoomedIn.zoomed(byFactor: 0.25, anchorX: 0.4, anchorY: 0.6))

        XCTAssertEqual(zoomedOut.centerX, start.centerX, accuracy: 1e-12)
        XCTAssertEqual(zoomedOut.centerY, start.centerY, accuracy: 1e-12)
        XCTAssertEqual(zoomedOut.halfExtent, start.halfExtent, accuracy: 1e-12)
    }

    /// Ein sehr großer Faktor kann die Invarianten nicht verletzen: Die
    /// Spanne bleibt bei der Mindestspanne stehen -- **exakt**, da
    /// ``ScanPlaneViewport`` die untere Schranke direkt zurückgibt statt
    /// sie aus zwei Grenzen zu berechnen.
    func testZoomingInFarBeyondTheLimitStopsAtTheMinimumHalfExtent() throws {
        let start = ScanPlaneViewport.fullField

        let zoomed = try applied(start.zoomed(byFactor: 1e9, anchorX: 0, anchorY: 0))
        XCTAssertEqual(zoomed.halfExtent, ScanPlaneViewport.minimumHalfExtent)

        let evenDeeper = try applied(zoomed.zoomed(byFactor: 1e9, anchorX: 0, anchorY: 0))
        XCTAssertEqual(evenDeeper.halfExtent, ScanPlaneViewport.minimumHalfExtent)
    }

    /// Herauszoomen endet spätestens bei der Gesamtansicht -- es gibt
    /// nichts jenseits des Felds.
    func testZoomingOutFarBeyondTheFieldEndsAtTheFullField() throws {
        let start = try ScanPlaneViewport.build(centerX: 0.45, centerY: 0.45, halfExtent: 0.05)

        let zoomed = try applied(start.zoomed(byFactor: 1e-9, anchorX: 0.45, anchorY: 0.45))

        XCTAssertEqual(zoomed, ScanPlaneViewport.fullField)
    }

    /// Ein enger Ausschnitt am Rand kann den Anker nicht mehr an seiner
    /// Stelle halten -- er bleibt gültig und im Feld, statt darüber
    /// hinauszulaufen.
    func testZoomingOutAtTheEdgeShiftsBackIntoTheFieldAndStaysValid() throws {
        let start = try ScanPlaneViewport.build(centerX: 0.05, centerY: 0.95, halfExtent: 0.05)

        let zoomed = try applied(start.zoomed(byFactor: 0.25, anchorX: 0, anchorY: 1))

        XCTAssertEqual(zoomed.xLowerBound, 0, accuracy: 1e-12)
        XCTAssertEqual(zoomed.yUpperBound, 1, accuracy: 1e-12)
    }

    /// **Bewusste, geprüfte Eigenschaft (siehe Dateikopf):** Geklammert
    /// wird ausschließlich das **Ergebnis**, nie der Anker selbst -- ein
    /// weit außerhalb liegender Anker ist eine gültige Eingabe der
    /// affinen Formel und zieht den Mittelpunkt in seine Richtung, statt
    /// vorab auf `-1...1` zu springen.
    func testZoomingClampsOnlyTheResultingCenterNotTheAnchorItself() throws {
        let start = ScanPlaneViewport.fullField

        let farAnchor = try applied(start.zoomed(byFactor: 4, anchorX: 1000, anchorY: 0))
        let interiorAnchor = try applied(start.zoomed(byFactor: 4, anchorX: 0.5, anchorY: 0))

        XCTAssertNotEqual(
            farAnchor, interiorAnchor,
            "Ein weit außerhalb liegender Anker fließt unverändert in die affine Formel ein " +
            "und ergibt deshalb ein anderes Ergebnis als ein Anker innerhalb des Felds -- " +
            "eine vorab auf das Feld geklammerte Zeigerposition ergäbe hier keinen Unterschied"
        )
        // Beide bleiben trotzdem gültig -- geklammert wird das Ergebnis.
        assertValid(farAnchor)
        assertValid(interiorAnchor)
        // Der weit außerhalb liegende Anker zieht den Mittelpunkt bis an
        // die Feldgrenze für diese Halbkantenlänge -- sichtbar daran,
        // dass er dort landet, wo auch ein Anker exakt am Feldrand
        // gelandet wäre.
        let edgeAnchor = try applied(start.zoomed(byFactor: 4, anchorX: 1, anchorY: 0))
        XCTAssertEqual(farAnchor, edgeAnchor)
    }

    func testZoomingRejectsANonPositiveFactorAndNonFiniteInput() throws {
        let start = try ScanPlaneViewport.build(centerX: 0.5, centerY: 0.5, halfExtent: 0.3)

        XCTAssertEqual(
            start.zoomed(byFactor: 0, anchorX: 0.5, anchorY: 0.5), .rejected(.nonPositiveZoomFactor)
        )
        XCTAssertEqual(
            start.zoomed(byFactor: -2, anchorX: 0.5, anchorY: 0.5), .rejected(.nonPositiveZoomFactor)
        )
        XCTAssertEqual(
            start.zoomed(byFactor: .nan, anchorX: 0.5, anchorY: 0.5), .rejected(.nonFiniteInput)
        )
        XCTAssertEqual(
            start.zoomed(byFactor: 2, anchorX: .infinity, anchorY: 0.5), .rejected(.nonFiniteInput)
        )
        XCTAssertEqual(
            start.zoomed(byFactor: 2, anchorX: 0.5, anchorY: .nan), .rejected(.nonFiniteInput)
        )
    }

    // MARK: - Rahmenzoom

    func testASquareRectangleBecomesExactlyTheNewWindow() throws {
        let start = ScanPlaneViewport.fullField

        let zoomed = try applied(start.zoomedToRectangle(xA: 0.3, xB: 0.55, yA: 0.1, yB: 0.35))

        XCTAssertEqual(zoomed.xLowerBound, 0.3, accuracy: 1e-12)
        XCTAssertEqual(zoomed.xUpperBound, 0.55, accuracy: 1e-12)
        XCTAssertEqual(zoomed.yLowerBound, 0.1, accuracy: 1e-12)
        XCTAssertEqual(zoomed.yUpperBound, 0.35, accuracy: 1e-12)
    }

    /// Niemand zieht einen Rahmen immer von links oben nach rechts
    /// unten. Alle vier Ziehrichtungen ergeben denselben Ausschnitt.
    func testEveryDragDirectionYieldsTheSameWindow() throws {
        let start = ScanPlaneViewport.fullField
        let expected = try applied(start.zoomedToRectangle(xA: 0.3, xB: 0.55, yA: 0.1, yB: 0.35))

        let directions: [(Double, Double, Double, Double)] = [
            (0.55, 0.3, 0.1, 0.35),
            (0.3, 0.55, 0.35, 0.1),
            (0.55, 0.3, 0.35, 0.1)
        ]
        for (xA, xB, yA, yB) in directions {
            let zoomed = try applied(start.zoomedToRectangle(xA: xA, xB: xB, yA: yA, yB: yB))
            XCTAssertEqual(zoomed, expected, "Ziehrichtung darf den Ausschnitt nicht ändern")
        }
    }

    /// Ein Rahmen ohne Fläche auf **beiden** Achsen ist ein Verrutschen
    /// beim Klicken, keine Anweisung -- und wird deshalb abgelehnt statt
    /// in einen maximalen Zoom übersetzt.
    func testAPureClickIsRefused() {
        let start = ScanPlaneViewport.fullField

        XCTAssertEqual(
            start.zoomedToRectangle(xA: 0.4, xB: 0.4, yA: 0.4, yB: 0.4),
            .rejected(.degenerateRectangle)
        )
        XCTAssertEqual(
            start.zoomedToRectangle(xA: 0.4, xB: .nan, yA: 0.1, yB: 0.9),
            .rejected(.nonFiniteInput)
        )
    }

    /// **Bewusste, geprüfte Eigenschaft (siehe Dateikopf):** Ein auf
    /// **einer** Achse entarteter Rahmen ist -- anders als beim alten
    /// anisotropen Ausschnitt -- **kein** Ablehnungsfall mehr: Der
    /// isotrope Rahmenzoom passt sich der größeren der beiden Spannen an,
    /// eine reine „Linie" ergibt deshalb ein gültiges, quadratisches
    /// Einpassen um ihren Mittelpunkt.
    func testARectangleDegenerateOnOnlyOneAxisStillFitsToTheOtherAxis() throws {
        let start = ScanPlaneViewport.fullField

        let degenerateOnX = try applied(start.zoomedToRectangle(xA: 0.4, xB: 0.4, yA: 0.1, yB: 0.9))
        XCTAssertEqual(degenerateOnX.halfExtent, 0.4, accuracy: 1e-12)
        XCTAssertEqual(degenerateOnX.centerX, 0.4, accuracy: 1e-12)
        XCTAssertEqual(degenerateOnX.centerY, 0.5, accuracy: 1e-12)

        let degenerateOnY = try applied(start.zoomedToRectangle(xA: 0.1, xB: 0.9, yA: 0.4, yB: 0.4))
        XCTAssertEqual(degenerateOnY.halfExtent, 0.4, accuracy: 1e-12)
    }

    /// Ein über den Feldrand hinaus gezogener Rahmen ist normal --
    /// geklammert wird auf das Feld, abgelehnt wird nichts. Hier ist der
    /// Rahmen so groß, dass die größere Spanne die ganze Welt deckt --
    /// das Ergebnis ist deshalb exakt die Gesamtansicht.
    func testARectangleDraggedFarBeyondTheFieldEndsAtTheFullField() throws {
        let zoomed = try applied(
            ScanPlaneViewport.fullField.zoomedToRectangle(xA: -3, xB: 0.4, yA: 0.2, yB: 9)
        )
        XCTAssertEqual(zoomed, ScanPlaneViewport.fullField)
    }

    /// Ein Rechteckzoom setzt **auf dem Feld** an, nicht auf dem
    /// bisherigen Ausschnitt -- die Eckkoordinaten sind kanonische
    /// Weltwerte, keine Anteile am aktuellen Ausschnitt.
    func testTheRectangleIsReadInAbsoluteWorldCoordinatesNotWindowCoordinates() throws {
        let narrow = try ScanPlaneViewport.build(centerX: 0.65, centerY: 0.65, halfExtent: 0.05)

        let zoomed = try applied(narrow.zoomedToRectangle(xA: 0.62, xB: 0.64, yA: 0.61, yB: 0.63))

        XCTAssertEqual(zoomed.xLowerBound, 0.62, accuracy: 1e-12)
        XCTAssertEqual(zoomed.yUpperBound, 0.63, accuracy: 1e-12)
    }

    // MARK: - Robustheit über beliebige Bedienfolgen

    /// Keine Folge von Werkzeugen -- in keiner Reihenfolge, mit keinem
    /// Faktor und keinem Anker -- kann einen ungültigen Ausschnitt
    /// erzeugen. Deterministisch über einen festen Generator, damit ein
    /// Fehlschlag reproduzierbar bleibt.
    func testNoSequenceOfToolsCanProduceAnInvalidWindow() throws {
        var seed: UInt64 = 0x032B_2C_5EED
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }

        var viewport = ScanPlaneViewport.fullField
        for step in 0..<3_000 {
            let change: ScanPlaneViewportChange
            switch step % 4 {
            case 0:
                change = viewport.panned(byX: next() * 4 - 2, byY: next() * 4 - 2)
            case 1:
                change = viewport.zoomed(
                    byFactor: next() * 20 + 1e-6,
                    anchorX: next() * 3 - 1.5, anchorY: next() * 3 - 1.5
                )
            case 2:
                change = viewport.zoomedToRectangle(
                    xA: next() * 2 - 0.5, xB: next() * 2 - 0.5,
                    yA: next() * 2 - 0.5, yB: next() * 2 - 0.5
                )
            default:
                change = .applied(ScanPlaneViewport.fullField)
            }
            switch change {
            case .applied(let next):
                assertValid(next)
                viewport = next
            case .rejected:
                // Eine Ablehnung lässt den Ausschnitt unangetastet --
                // genau das ist hier die Zusage.
                assertValid(viewport)
            }
        }
    }
}
