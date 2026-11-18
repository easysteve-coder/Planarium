import XCTest
import CoreGraphics
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// SICK-030b2: der reine, SwiftUI-freie Zonen-Geometrie-Reducer,
/// **seit SICK-032b3 vollständig linear**. Alle Tests rechnen
/// ausschließlich mit Fachwerten und einer konstruierten
/// ``LinearScanFieldGeometry`` — keine Ansicht, keine Geste des Systems,
/// kein Scanner, kein Audiogerät.
final class ZoneGeometryReducerTests: XCTestCase {

    // MARK: - Aufbau

    /// Ein bewusst schlichter Fächer: Mittelpunkt im Ursprung, Radius
    /// 1000, Öffnung von `0` bis `.pi` — damit lässt sich jeder
    /// Index-/Rohwertpunkt von Hand nachrechnen.
    private let fan = FanScreenGeometry(
        center: .zero, radius: 1000, startAngleRadians: 0, endAngleRadians: .pi
    )

    /// Die Ansichtsgeometrie zur Gesamtansicht. Ein **zweiter**
    /// Ausschnitt wird in `ZoneGeometryViewportTests` geprüft; hier geht
    /// es um die Fachregeln, und die dürfen von ihm nicht abhängen.
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

    /// Der Bildschirmpunkt, der **genau** diesem Index-/Rohwertpaar
    /// entspricht — über dieselben Formeln, die auch der Zoneneditor zum
    /// Zeichnen benutzt. Damit prüfen die Tests die Umkehrung des
    /// Reducers gegen die Vorwärtsrichtung der Anzeige, nicht gegen eine
    /// zweite, nachgebaute Rechnung.
    private func screenPoint(index: Double, value: UInt16) -> CGPoint {
        geometry.project(
            angleFraction: index,
            radiusFraction: Double(value) / PolarProfileGeometry.maxRawMeasurementValue
        ).screenPoint
    }

    private func start(_ zone: Zone, at point: CGPoint) -> ZoneGeometryGestureStart {
        ZoneGeometryGestureStart(zoneID: UUID(), zone: zone, location: point)
    }

    private func updated(
        _ gesture: ZoneGeometryGesture,
        _ zone: Zone,
        from origin: CGPoint,
        to destination: CGPoint,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Zone {
        let outcome = ZoneGeometryReducer.apply(
            gesture, from: start(zone, at: origin), toScreenPoint: destination, in: geometry
        )
        guard case .updated(let result) = outcome else {
            XCTFail("Erwartet: aktualisierte Zone, bekommen: \(outcome)", file: file, line: line)
            throw XCTSkip("siehe vorherigen Fehlschlag")
        }
        return result
    }

    // MARK: - Die vier Griffe bewegen je genau eine Grenze

    func testDraggingTheIndexLowerHandleMovesOnlyThatBound() throws {
        let zone = try zone()
        let result = try updated(
            .handle(.indexLowerBound), zone,
            from: screenPoint(index: 0.3, value: 2000),
            to: screenPoint(index: 0.4, value: 2000)
        )

        XCTAssertEqual(result.indexRange.lowerBound, 0.4, accuracy: 1e-9)
        XCTAssertEqual(result.indexRange.upperBound, 0.7, accuracy: 1e-12)
        XCTAssertEqual(result.valueRange, 1000...4000, "Der Rohwert bleibt unberührt")
    }

    func testDraggingTheIndexUpperHandleMovesOnlyThatBound() throws {
        let zone = try zone()
        let result = try updated(
            .handle(.indexUpperBound), zone,
            from: screenPoint(index: 0.7, value: 2000),
            to: screenPoint(index: 0.55, value: 2000)
        )

        XCTAssertEqual(result.indexRange.lowerBound, 0.3, accuracy: 1e-12)
        XCTAssertEqual(result.indexRange.upperBound, 0.55, accuracy: 1e-9)
        XCTAssertEqual(result.valueRange, 1000...4000)
    }

    func testDraggingTheInnerValueHandleMovesOnlyThatBound() throws {
        let zone = try zone()
        let result = try updated(
            .handle(.valueInnerBound), zone,
            from: screenPoint(index: 0.5, value: 1000),
            to: screenPoint(index: 0.5, value: 2500)
        )

        XCTAssertEqual(Double(result.valueRange.lowerBound), 2500, accuracy: 2)
        XCTAssertEqual(result.valueRange.upperBound, 4000, "Die Außengrenze bleibt stehen")
        XCTAssertEqual(result.indexRange.lowerBound, 0.3, accuracy: 1e-12)
        XCTAssertEqual(result.indexRange.upperBound, 0.7, accuracy: 1e-12)
    }

    func testDraggingTheOuterValueHandleMovesOnlyThatBound() throws {
        let zone = try zone()
        let result = try updated(
            .handle(.valueOuterBound), zone,
            from: screenPoint(index: 0.5, value: 4000),
            to: screenPoint(index: 0.5, value: 6500)
        )

        XCTAssertEqual(Double(result.valueRange.upperBound), 6500, accuracy: 2)
        XCTAssertEqual(result.valueRange.lowerBound, 1000, "Die Innengrenze bleibt stehen")
    }

    /// Ein Griff folgt der **Gesamtverschiebung**, also auch dann, wenn
    /// er nicht exakt auf seiner eigenen Grenze angefasst wurde — sonst
    /// spränge die Zone beim Anfassen.
    func testAHandleFollowsTheTranslationEvenWhenGrabbedSlightlyOff() throws {
        let zone = try zone()
        let result = try updated(
            .handle(.indexLowerBound), zone,
            from: screenPoint(index: 0.32, value: 2000), // 0,02 daneben
            to: screenPoint(index: 0.42, value: 2000)
        )

        XCTAssertEqual(result.indexRange.lowerBound, 0.4, accuracy: 1e-9, "0,3 + 0,10, nicht 0,42")
    }

    // MARK: - Griffe stoppen, sie tauschen nie (Befund N7 (2))

    func testTheIndexLowerHandleStopsAtTheMinimumSpanInsteadOfCrossingOver() throws {
        let zone = try zone()
        let result = try updated(
            .handle(.indexLowerBound), zone,
            from: screenPoint(index: 0.3, value: 2000),
            to: screenPoint(index: 0.95, value: 2000) // weit hinter die Obergrenze
        )

        XCTAssertEqual(
            result.indexRange.lowerBound, 0.7 - ZoneDraft.minimumIndexSpan, accuracy: 1e-9,
            "Stoppt vor der Obergrenze"
        )
        XCTAssertEqual(result.indexRange.upperBound, 0.7, accuracy: 1e-12, "Die Obergrenze weicht nicht aus")
        XCTAssertLessThan(result.indexRange.lowerBound, result.indexRange.upperBound)
    }

    func testTheIndexUpperHandleStopsAtTheMinimumSpanInsteadOfCrossingOver() throws {
        let zone = try zone()
        let result = try updated(
            .handle(.indexUpperBound), zone,
            from: screenPoint(index: 0.7, value: 2000),
            to: screenPoint(index: 0.05, value: 2000)
        )

        XCTAssertEqual(result.indexRange.lowerBound, 0.3, accuracy: 1e-12)
        XCTAssertEqual(result.indexRange.upperBound, 0.3 + ZoneDraft.minimumIndexSpan, accuracy: 1e-9)
    }

    func testTheInnerValueHandleStopsBelowTheOuterOne() throws {
        let zone = try zone()
        let result = try updated(
            .handle(.valueInnerBound), zone,
            from: screenPoint(index: 0.5, value: 1000),
            to: screenPoint(index: 0.5, value: 8000)
        )

        XCTAssertEqual(result.valueRange.lowerBound, 4000 - ZoneDraft.minimumValueSpan)
        XCTAssertEqual(result.valueRange.upperBound, 4000)
    }

    func testTheOuterValueHandleStopsAboveTheInnerOne() throws {
        let zone = try zone()
        let result = try updated(
            .handle(.valueOuterBound), zone,
            from: screenPoint(index: 0.5, value: 4000),
            to: screenPoint(index: 0.5, value: 0)
        )

        XCTAssertEqual(result.valueRange.lowerBound, 1000)
        XCTAssertEqual(result.valueRange.upperBound, 1000 + ZoneDraft.minimumValueSpan)
    }

    /// Auch eine bereits minimal schmale Zone bleibt gültig, statt zu
    /// entarten oder den Reducer zum Absturz zu bringen (die Klammerung
    /// dort arbeitet mit umgekehrten Schranken).
    func testAnAlreadyMinimalZoneStaysValidWhenItsHandleIsPushedFurther() throws {
        let narrow = try zone(index: 0.4...0.4005, value: 2000...2001)

        for gesture in ZoneGeometryGesture.allGestures {
            let result = try updated(
                gesture, narrow,
                from: screenPoint(index: 0.4, value: 2000),
                to: screenPoint(index: 0.9, value: 7000)
            )
            XCTAssertLessThan(result.indexRange.lowerBound, result.indexRange.upperBound, "\(gesture)")
            XCTAssertLessThan(result.valueRange.lowerBound, result.valueRange.upperBound, "\(gesture)")
        }
    }

    // MARK: - Die ganze Zone verschieben

    func testMovingTheWholeZoneKeepsBothSpans() throws {
        let zone = try zone()
        let result = try updated(
            .moveWholeZone, zone,
            from: screenPoint(index: 0.5, value: 2000),
            to: screenPoint(index: 0.6, value: 3000)
        )

        XCTAssertEqual(
            result.indexRange.upperBound - result.indexRange.lowerBound, 0.4, accuracy: 1e-9,
            "Indexspanne erhalten"
        )
        XCTAssertEqual(
            Int(result.valueRange.upperBound) - Int(result.valueRange.lowerBound), 3000,
            "Rohwertspanne erhalten"
        )
        XCTAssertEqual(result.indexRange.lowerBound, 0.4, accuracy: 1e-9)
        XCTAssertEqual(Double(result.valueRange.lowerBound), 2000, accuracy: 2)
    }

    func testMovingTheWholeZoneBackwardsWorksTheSameWay() throws {
        let zone = try zone()
        let result = try updated(
            .moveWholeZone, zone,
            from: screenPoint(index: 0.5, value: 3000),
            to: screenPoint(index: 0.35, value: 2000)
        )

        XCTAssertEqual(result.indexRange.lowerBound, 0.15, accuracy: 1e-9)
        XCTAssertEqual(result.indexRange.upperBound, 0.55, accuracy: 1e-9)
        XCTAssertEqual(Double(result.valueRange.lowerBound), 0, accuracy: 2)
    }

    func testMovingTheWholeZoneStopsAtTheUpperEdgeWithoutOverflowOrFlip() throws {
        let zone = try zone()
        let result = try updated(
            .moveWholeZone, zone,
            from: screenPoint(index: 0.5, value: 2000),
            to: screenPoint(index: 1.0, value: 8191)
        )

        XCTAssertEqual(result.indexRange.upperBound, 1.0, accuracy: 1e-9)
        XCTAssertEqual(
            result.indexRange.upperBound - result.indexRange.lowerBound, 0.4, accuracy: 1e-9,
            "Am Rand schrumpft die Zone nicht"
        )
        XCTAssertEqual(result.valueRange.upperBound, Zone.maxRawMeasurementValue)
        XCTAssertEqual(
            Int(result.valueRange.upperBound) - Int(result.valueRange.lowerBound), 3000
        )
    }

    func testMovingTheWholeZoneStopsAtTheLowerEdgeWithoutOverflowOrFlip() throws {
        let zone = try zone()
        let result = try updated(
            .moveWholeZone, zone,
            from: screenPoint(index: 0.5, value: 4000),
            to: screenPoint(index: 0.0, value: 0)
        )

        XCTAssertEqual(result.indexRange.lowerBound, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.indexRange.upperBound, 0.4, accuracy: 1e-9)
        XCTAssertEqual(result.valueRange.lowerBound, 0)
        XCTAssertEqual(result.valueRange.upperBound, 3000)
    }

    /// Kein Delta-Aufsummieren: derselbe Zielpunkt ergibt immer dasselbe
    /// Ergebnis, egal wie oft der Reducer unterwegs gefragt wurde.
    func testTheResultDependsOnlyOnStartAndCurrentPoint() throws {
        let zone = try zone()
        let origin = screenPoint(index: 0.5, value: 2000)
        let destination = screenPoint(index: 0.62, value: 2600)
        let gestureStart = start(zone, at: origin)

        var last: Zone?
        for intermediate in [0.52, 0.58, 0.44, 0.62] {
            _ = ZoneGeometryReducer.apply(
                .moveWholeZone, from: gestureStart,
                toScreenPoint: screenPoint(index: intermediate, value: 2600), in: geometry
            )
            guard case .updated(let zone) = ZoneGeometryReducer.apply(
                .moveWholeZone, from: gestureStart, toScreenPoint: destination, in: geometry
            ) else { return XCTFail("Erwartet: aktualisierte Zone") }
            if let last { XCTAssertEqual(zone, last) }
            last = zone
        }
    }

    // MARK: - Vierte-Wurzel-Inversion

    /// Jeder Rohwert, den die Anzeige an eine Bildschirmposition legt,
    /// muss von dort auch wieder zurückkommen.
    func testEveryRawValueSurvivesTheRoundTripThroughTheScreen() throws {
        let zone = try zone(value: 100...200)

        for value in stride(from: 0, through: 8191, by: 173).map(UInt16.init) {
            let result = try updated(
                .handle(.valueOuterBound), zone,
                from: screenPoint(index: 0.5, value: 200),
                to: screenPoint(index: 0.5, value: value)
            )
            // Die Außengrenze wandert um den Rohwertunterschied und
            // stoppt an der fachlichen Mindestspanne über der Innengrenze.
            let expected = max(Int(value), 100 + Int(ZoneDraft.minimumValueSpan))
            XCTAssertEqual(
                Double(result.valueRange.upperBound), Double(expected), accuracy: 2, "Rohwert \(value)"
            )
        }
    }

    /// Der real beobachtete Wertebereich aus dem SICK-012-Mitschnitt
    /// (≈ 21…169 von 8191) liegt **linear** bei 0,26…2,06 % des Radius —
    /// seit SICK-032b3 ohne jede Kompression. Der Test hält beides fest:
    /// dass die Lage wirklich so klein ist, und dass die Umkehrung dort
    /// trotzdem exakt stimmt.
    ///
    /// Das ist der Ersatz für den SICK-030b2-Test, der an derselben
    /// Stelle die vierte-Wurzel-Lage (≈ 22–38 % des Radius) festhielt.
    /// Diese Aussage ist nicht mehr wahr und wurde **ersetzt**, nicht
    /// gelöscht; die Bedienbarkeit im kleinen Bereich beantwortet jetzt
    /// der Ausschnitt, siehe `testTheSameValueRangeBecomesWorkableInsideAFittedViewport`.
    func testTheRealisticSick012ValueRangeIsTinyButMapsBackExactly() throws {
        let zone = try zone(value: 21...169)

        for value in [UInt16(21), 40, 90, 120, 169] {
            let point = screenPoint(index: 0.5, value: value)
            let fraction = fan.fanCoordinate(forScreenPoint: point).displayRadiusFraction
            XCTAssertGreaterThan(fraction, 0.002, "Wert \(value)")
            XCTAssertLessThan(fraction, 0.021, "Wert \(value) füllt linear nur ~2 % des Radius")

            let result = try updated(
                .handle(.valueInnerBound), zone,
                from: screenPoint(index: 0.5, value: 21),
                to: point
            )
            let expected = min(Int(value), 169 - Int(ZoneDraft.minimumValueSpan))
            XCTAssertEqual(
                Double(result.valueRange.lowerBound), Double(expected), accuracy: 1, "Wert \(value)"
            )
        }
    }

    /// Und genau dieselben Werte sind in einem eingepassten Ausschnitt
    /// bedienbar: Derselbe Rohwertunterschied entspricht dort einer um
    /// Größenordnungen längeren Strecke auf dem Bildschirm.
    ///
    /// **Das ist die eigentliche Antwort auf die verlorene Kompression**
    /// (SICK-032b1/b2): nicht eine verbogene Skala, sondern ein
    /// wählbarer Ausschnitt.
    func testTheSameValueRangeBecomesWorkableInsideAFittedViewport() throws {
        let zoomed = try ScanPlaneViewport.build(
            centerX: 0, centerY: 0,
            halfExtent: 200 / PolarProfileGeometry.maxRawMeasurementValue
        )
        let close = LinearScanFieldGeometry(fan: fan, viewport: zoomed)

        func distance(_ geo: LinearScanFieldGeometry) -> CGFloat {
            let a = geo.project(angleFraction: 0.5, radiusFraction: 21 / PolarProfileGeometry.maxRawMeasurementValue).screenPoint
            let b = geo.project(angleFraction: 0.5, radiusFraction: 169 / PolarProfileGeometry.maxRawMeasurementValue).screenPoint
            return ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }

        let wide = distance(geometry)
        let near = distance(close)
        XCTAssertLessThan(wide, 25, "In der Gesamtansicht sind 21…169 kaum zu greifen")
        XCTAssertGreaterThan(near, 700, "Im eingepassten Ausschnitt füllen sie das Feld")

        // Und die Bearbeitung rechnet in diesem Ausschnitt genauso exakt.
        let zone = try zone(value: 21...169)
        let outcome = ZoneGeometryReducer.apply(
            .handle(.valueOuterBound),
            from: start(zone, at: close.project(
                angleFraction: 0.5, radiusFraction: 169 / PolarProfileGeometry.maxRawMeasurementValue
            ).screenPoint),
            toScreenPoint: close.project(
                angleFraction: 0.5, radiusFraction: 190 / PolarProfileGeometry.maxRawMeasurementValue
            ).screenPoint,
            in: close
        )
        guard case .updated(let result) = outcome else {
            return XCTFail("Erwartet: aktualisierte Zone, bekommen: \(outcome)")
        }
        XCTAssertEqual(Double(result.valueRange.upperBound), 190, accuracy: 1)
        XCTAssertEqual(result.valueRange.lowerBound, 21, "Die Innengrenze bleibt unberührt")
    }

    // MARK: - Der gewählte Ausschnitt (SICK-032b3)

    /// **Jede** Geste rechnet in **jedem** Ausschnitt richtig: Wer einen
    /// Griff auf einen Feldpunkt zieht, bekommt genau diesen Fachwert --
    /// egal, wie weit hinein- oder herausgezoomt ist.
    ///
    /// Das ist die eigentliche Aussage der Umstellung auf die lineare
    /// Ansichtsgeometrie: Die Bearbeitung folgt dem, was gezeichnet ist.
    func testEveryGestureIsExactInEveryViewport() throws {
        let viewports: [ScanPlaneViewport] = [
            .fullField,
            try ScanPlaneViewport.build(centerX: 0, centerY: 0, halfExtent: 0.5),
            try ScanPlaneViewport.build(centerX: 0, centerY: 0, halfExtent: 0.36)
        ]

        for viewport in viewports {
            let geo = LinearScanFieldGeometry(fan: fan, viewport: viewport)
            func screen(index: Double, value: UInt16) -> CGPoint {
                geo.project(
                    angleFraction: index,
                    radiusFraction: Double(value) / PolarProfileGeometry.maxRawMeasurementValue
                ).screenPoint
            }

            let zone = try self.zone(index: 0.45...0.55, value: 2000...2600)
            let from = screen(index: 0.5, value: 2300)
            // Ein Ziel, das in **jedem** dieser Ausschnitte sichtbar ist
            // -- sonst prüfte der Test unten die Klammerung am Rand
            // statt die Genauigkeit.
            let to: UInt16 = 2500

            // Ein Griff landet exakt auf dem angesteuerten Fachwert.
            let outcome = ZoneGeometryReducer.apply(
                .handle(.valueOuterBound), from: start(zone, at: from),
                toScreenPoint: screen(index: 0.5, value: to), in: geo
            )
            guard case .updated(let moved) = outcome else {
                return XCTFail("\(viewport): erwartet aktualisierte Zone, bekommen \(outcome)")
            }
            XCTAssertEqual(
                Double(moved.valueRange.upperBound), 2600 + Double(to) - 2300,
                accuracy: 2, "\(viewport)"
            )
            XCTAssertEqual(moved.valueRange.lowerBound, 2000, "\(viewport): Innengrenze unberührt")

            // Und eine Geste ohne Weg verändert in jedem Ausschnitt nichts.
            for gesture in ZoneGeometryGesture.allGestures {
                let still = ZoneGeometryReducer.apply(
                    gesture, from: start(zone, at: from), toScreenPoint: from, in: geo
                )
                XCTAssertEqual(still, .updated(zone), "\(viewport) / \(gesture)")
            }
        }
    }

    /// Derselbe Bildschirmweg bewegt im engeren Ausschnitt **weniger**
    /// Rohwerte -- das ist der ganze Zweck des Zoomens, und es muss sich
    /// im Ergebnis zeigen, nicht nur im Bild.
    func testTheSameScreenDistanceMovesFewerRawValuesInACloserViewport() throws {
        let zone = try zone(value: 2000...6000)
        let close = LinearScanFieldGeometry(fan: fan, viewport: try ScanPlaneViewport.build(
            centerX: 0, centerY: 0.3, halfExtent: 0.1
        ))

        func movedUpperBound(in geo: LinearScanFieldGeometry) throws -> Double {
            let origin = geo.project(angleFraction: 0.5, radiusFraction: 0.3).screenPoint
            let target = CGPoint(x: origin.x, y: origin.y - 100)
            let outcome = ZoneGeometryReducer.apply(
                .handle(.valueOuterBound), from: start(zone, at: origin),
                toScreenPoint: target, in: geo
            )
            guard case .updated(let result) = outcome else {
                XCTFail("Erwartet: aktualisierte Zone, bekommen: \(outcome)")
                return 0
            }
            return Double(result.valueRange.upperBound)
        }

        let wide = abs(try movedUpperBound(in: geometry) - 6000)
        let near = abs(try movedUpperBound(in: close) - 6000)
        XCTAssertGreaterThan(wide, near, "Die Gesamtansicht bewegt bei gleichem Weg mehr Rohwerte")
        XCTAssertGreaterThan(wide, 4 * near, "Der Unterschied ist deutlich, nicht marginal")
    }

    /// Und die Gegenrichtung zum Test darüber: Ein Zug **über den
    /// sichtbaren Rand hinaus** stoppt am Rand, statt einen Fachwert
    /// anzunehmen, der gar nicht zu sehen ist. Dieselbe Klammerung, die
    /// auch Zoom und Rechteckzoom für ihre Anker benutzen.
    func testDraggingBeyondTheVisibleEdgeStopsAtThatEdge() throws {
        let window = try ScanPlaneViewport.build(
            centerX: 0, centerY: 0.275, halfExtent: 0.075
        )
        let geo = LinearScanFieldGeometry(fan: fan, viewport: window)
        let edgeValue = ZoneEditorGeometry.rawValue(fromRadiusFraction: 0.35)

        let zone = try zone(value: 2000...2600)
        let from = geo.project(angleFraction: 0.5, radiusFraction: 0.3).screenPoint
        // Ein Punkt weit außerhalb des gezeichneten Fächers.
        let farOutside = geo.project(angleFraction: 0.5, radiusFraction: 3.0).screenPoint

        let outcome = ZoneGeometryReducer.apply(
            .handle(.valueOuterBound), from: start(zone, at: from),
            toScreenPoint: farOutside, in: geo
        )
        guard case .updated(let result) = outcome else {
            return XCTFail("Erwartet: aktualisierte Zone, bekommen: \(outcome)")
        }
        let expected = 2600 + Double(edgeValue) - Double(ZoneEditorGeometry.rawValue(fromRadiusFraction: 0.3))
        XCTAssertEqual(Double(result.valueRange.upperBound), expected, accuracy: 2)
        XCTAssertLessThan(
            result.valueRange.upperBound, Zone.maxRawMeasurementValue,
            "Es wird nicht auf die Feldobergrenze gesprungen"
        )
    }

    // MARK: - Sichtbare Ablehnungen statt erfundener Fachwerte

    func testANonFiniteGestureValueIsRejected() throws {
        let zone = try zone()
        let valid = screenPoint(index: 0.5, value: 2000)
        let broken: [CGPoint] = [
            CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.nan),
            CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: 0, y: -CGFloat.infinity)
        ]

        for point in broken {
            XCTAssertEqual(
                ZoneGeometryReducer.apply(.moveWholeZone, from: start(zone, at: valid), toScreenPoint: point, in: geometry),
                .rejected(.nonFiniteGestureValue), "Zielpunkt \(point)"
            )
            XCTAssertEqual(
                ZoneGeometryReducer.apply(.moveWholeZone, from: start(zone, at: point), toScreenPoint: valid, in: geometry),
                .rejected(.nonFiniteGestureValue), "Startpunkt \(point)"
            )
        }
    }

    func testDegenerateFanGeometryIsRejectedInsteadOfSilentlyProducingNeutralValues() throws {
        let zone = try zone()
        let degenerate: [FanScreenGeometry] = [
            FanScreenGeometry(center: .zero, radius: 0, startAngleRadians: 0, endAngleRadians: .pi),
            FanScreenGeometry(center: .zero, radius: -10, startAngleRadians: 0, endAngleRadians: .pi),
            FanScreenGeometry(center: .zero, radius: CGFloat.nan, startAngleRadians: 0, endAngleRadians: .pi),
            FanScreenGeometry(center: CGPoint(x: CGFloat.nan, y: 0), radius: 100, startAngleRadians: 0, endAngleRadians: .pi),
            FanScreenGeometry(center: .zero, radius: 100, startAngleRadians: 1, endAngleRadians: 1),
            FanScreenGeometry(center: .zero, radius: 100, startAngleRadians: Double.nan, endAngleRadians: .pi)
        ]

        for fan in degenerate {
            XCTAssertEqual(
                ZoneGeometryReducer.apply(
                    .moveWholeZone, from: start(zone, at: .zero), toScreenPoint: CGPoint(x: 10, y: 10),
                    in: LinearScanFieldGeometry(fan: fan, viewport: .fullField)
                ),
                .rejected(.degenerateFanGeometry), "\(fan)"
            )
        }
    }

    // MARK: - Was eine Geste niemals verändert

    func testTheRoleIsCarriedThroughUnchangedByEveryGesture() throws {
        for role in ZoneRole.allCases {
            let zone = try zone(role: role)
            for gesture in ZoneGeometryGesture.allGestures {
                let result = try updated(
                    gesture, zone,
                    from: screenPoint(index: 0.5, value: 2000),
                    to: screenPoint(index: 0.55, value: 2400)
                )
                XCTAssertEqual(result.role, role, "\(gesture)")
            }
        }
    }

    func testAZeroLengthGestureLeavesTheZoneExactlyAsItWas() throws {
        let zone = try zone()
        let point = screenPoint(index: 0.5, value: 2000)

        for gesture in ZoneGeometryGesture.allGestures {
            let result = try updated(gesture, zone, from: point, to: point)
            XCTAssertEqual(result, zone, "\(gesture)")
        }
    }
}
