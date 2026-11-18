import XCTest
import CoreGraphics
@testable import SickPLSMonitorKit

/// Die Bildschirmseite des Ausschnitts (SICK-032b1, seit SICK-032b2c
/// **planar/formtreu**): Linearität, die affine Ausschnittsabbildung,
/// Rundlauf und die beiden Bediennähte (Anker am Zeiger, Rechteck aus
/// zwei Bildschirmecken).
///
/// **Ohne gerenderte Ansicht, ohne Gerät** -- dieselbe Trennung, die
/// `FanScreenGeometry` seit SICK-014 erlaubt.
///
/// **Was sich mit SICK-032b2c geändert hat:** Der Ausschnitt ist kein
/// Winkel-/Entfernungsrechteck (`ScanViewport`) mehr, sondern ein
/// achsenparalleles Quadrat in einer festen kanonischen Welt
/// (``ScanPlaneViewport``). Tests, die eine alleinige Eigenschaft des
/// alten Rechteckausschnitts prüften -- dass ein enger werdendes
/// Winkelfenster wieder den ganzen Öffnungswinkel füllt, oder dass die
/// **innere Entfernungsgrenze** des Ausschnitts auf den Fächermittelpunkt
/// fällt -- sind entfallen: Genau diese Eigenschaften **waren** die
/// SICK-032b2c-Fehlerklasse (Auffächerung statt Bildzoom) und dürfen
/// nicht wieder als Erwartung zurückkehren. An ihre Stelle tritt unten
/// die Formtreue-Prüfung.
final class LinearScanFieldGeometryTests: XCTestCase {

    private struct UnexpectedRejection: Error {}

    /// Halbkreis nach oben, Radius 100, Mittelpunkt im Ursprung --
    /// dieselben handnachrechenbaren Werte wie in
    /// `FanScreenGeometryTests`.
    private func makeFan(radius: CGFloat = 100) -> FanScreenGeometry {
        FanScreenGeometry(
            center: CGPoint(x: 0, y: 0),
            radius: radius,
            startAngleRadians: 270.0 * .pi / 180 - .pi / 2,
            endAngleRadians: 270.0 * .pi / 180 + .pi / 2
        )
    }

    /// Absoluter Winkel eines Bildschirmpunkts **auf dem Zweig des
    /// Fächers**. `atan2` liefert `(-pi, pi]`, der Fächer liegt hier aber
    /// bei `pi...2pi` -- ohne diese Entfaltung verglichen sich zwei
    /// verschiedene Darstellungen desselben Winkels.
    private func fanAngle(of point: CGPoint, fan: FanScreenGeometry) -> Double {
        var angle = atan2(Double(point.y - fan.center.y), Double(point.x - fan.center.x))
        while angle < fan.startAngleRadians { angle += 2 * .pi }
        while angle > fan.endAngleRadians { angle -= 2 * .pi }
        return angle
    }

    private func distanceFromCenter(_ point: CGPoint, fan: FanScreenGeometry) -> Double {
        let dx = Double(point.x - fan.center.x)
        let dy = Double(point.y - fan.center.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func applied(
        _ change: ScanPlaneViewportChange,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ScanPlaneViewport {
        guard let viewport = change.viewport else {
            XCTFail("Werkzeug abgelehnt: \(change)", file: file, line: line)
            throw UnexpectedRejection()
        }
        return viewport
    }

    // MARK: - Linearität

    func testCanvasBaselineStaysAtTheBottomAcrossViewportChanges() throws {
        let fan = FanScreenGeometry(size: CGSize(width: 800, height: 600))
        let full = LinearScanFieldGeometry(fan: fan, viewport: .fullField)
        let zoomedViewport = try ScanPlaneViewport.build(centerX: 0.2, centerY: -0.3, halfExtent: 0.25)
        let zoomed = LinearScanFieldGeometry(fan: fan, viewport: zoomedViewport)

        XCTAssertEqual(full.canvasBaselineY, full.canvasRect.maxY - 1)
        XCTAssertEqual(zoomed.canvasBaselineY, full.canvasBaselineY)
    }

    /// Gleiche Schritte in der Entfernung ergeben **gleiche Pixel** --
    /// die Kernzusage der Owner-Vorgabe „geometrisch linear".
    func testEqualRadiusStepsProduceEqualPixelSteps() {
        let fan = makeFan()
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: .fullField)

        var distances: [Double] = []
        for step in 0...10 {
            let point = geometry.project(angleFraction: 0.5, radiusFraction: Double(step) / 10)
            distances.append(distanceFromCenter(point.screenPoint, fan: fan))
        }

        let firstStep = distances[1] - distances[0]
        for step in 1..<10 {
            XCTAssertEqual(
                distances[step + 1] - distances[step], firstStep, accuracy: 1e-9,
                "Schritt \(step) muss genauso groß sein wie der erste"
            )
        }
        XCTAssertEqual(firstStep, 10, accuracy: 1e-9, "Zehn Schritte auf Radius 100")
    }

    /// **Der ausdrückliche Gegenbeweis zur vierten Wurzel** aus
    /// SICK-012b: Der real beobachtete Rohwert 169 (von 8191) liegt
    /// linear bei ≈ 2,06 % des Radius. Die alte Anzeigekompression machte
    /// daraus ≈ 38 %. Fiele sie je wieder in diesen Weg, bräche genau
    /// dieser Test.
    func testTheProjectionIsLinearAndNotTheFourthRootCompression() {
        let fan = makeFan()
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: .fullField)
        let rawValue = 169.0
        let linearFraction = rawValue / PolarProfileGeometry.maxRawMeasurementValue

        let projected = geometry.project(angleFraction: 0.5, radiusFraction: linearFraction)
        let distance = distanceFromCenter(projected.screenPoint, fan: fan)

        XCTAssertEqual(distance, Double(fan.radius) * linearFraction, accuracy: 1e-9)
        XCTAssertEqual(distance, 2.063, accuracy: 0.001, "≈ 2,06 % von Radius 100")

        let compressed = PolarProfileGeometry.displayRadiusFraction(fromRadiusFraction: linearFraction)
        XCTAssertEqual(compressed, 0.379, accuracy: 0.001, "Die alte Kompression läge bei ≈ 38 %")
        XCTAssertNotEqual(
            distance, Double(fan.radius) * compressed, accuracy: 1,
            "Die Anzeigekompression darf diesen Weg nie bestimmen"
        )
    }

    /// Gleiche Schritte auf der Winkelachse ergeben **gleiche
    /// Winkelschritte** -- die Winkelseite derselben Zusage.
    func testEqualAngleStepsProduceEqualAngularSteps() {
        let fan = makeFan()
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: .fullField)

        var angles: [Double] = []
        for step in 0...8 {
            let point = geometry.project(angleFraction: Double(step) / 8, radiusFraction: 1)
            angles.append(fanAngle(of: point.screenPoint, fan: fan))
        }

        let firstStep = angles[1] - angles[0]
        for step in 1..<8 {
            XCTAssertEqual(angles[step + 1] - angles[step], firstStep, accuracy: 1e-9)
        }
        XCTAssertEqual(firstStep, .pi / 8, accuracy: 1e-9, "Halbkreis in acht Schritten")
    }

    /// Die Linearität gilt **innerhalb** jedes Ausschnitts, nicht nur
    /// bei der Gesamtansicht.
    func testTheProjectionStaysLinearInsideAZoomedWindow() throws {
        let fan = makeFan()
        let viewport = try ScanPlaneViewport.build(centerX: 0, centerY: 0, halfExtent: 0.5)
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: viewport)

        var distances: [Double] = []
        for step in 0...10 {
            let radius = 0.02 + 0.001 * Double(step) / 10
            distances.append(
                distanceFromCenter(
                    geometry.project(angleFraction: 0.35, radiusFraction: radius).screenPoint,
                    fan: fan
                )
            )
        }

        let firstStep = distances[1] - distances[0]
        for step in 1..<10 {
            XCTAssertEqual(distances[step + 1] - distances[step], firstStep, accuracy: 1e-9)
        }
    }

    // MARK: - Formtreue (SICK-032b2c)

    /// **Die verbindliche Formtreue-Prüfung dieses Slices** (Auftrag
    /// `task-sick-032b2c.md`, „Muss nachweislich gelten"): Ein
    /// asymmetrisches Muster aus drei Feldpunkten wird unter zwei
    /// verschiedenen Ausschnitten auf den Bildschirm gebracht. Der
    /// Übergang zwischen beiden Bildern darf **ausschließlich** eine
    /// gleichmäßige Skalierung und Verschiebung sein -- keine Drehung,
    /// keine Verzerrung, keine erneute Auffächerung.
    ///
    /// Geprüft wird das direkt an den Verbindungsvektoren zwischen den
    /// drei Punkten: Sie müssen unter beiden Ausschnitten **parallel**
    /// (gleiche Richtung, kein Umklappen) bleiben und **denselben**
    /// Skalierungsfaktor tragen -- ein zweiter, abweichender Faktor wäre
    /// eine anisotrope Verzerrung.
    ///
    /// **Der Gegenbeweis** (`testTheOldReFanningCompositionFailsThisSameCheck`
    /// unten) zeigt an einer lokalen Nachbildung der bis SICK-032b2c
    /// gültigen Verkettung, dass genau diese Prüfung dort scheitert --
    /// nicht weil das Muster ungeeignet wäre, sondern weil die alte
    /// Verkettung das Muster beim Verengen des Winkelfensters tatsächlich
    /// dreht.
    func testAnAsymmetricPatternMapsAsOneAffineScalingUnderZoom() throws {
        let fan = makeFan()
        let pattern: [(angle: Double, radius: Double)] = [
            (0.3, 0.4), (0.7, 0.6), (0.5, 0.9)
        ]

        let wide = LinearScanFieldGeometry(fan: fan, viewport: .fullField)
        let narrow = LinearScanFieldGeometry(
            fan: fan,
            viewport: try ScanPlaneViewport.build(centerX: 0.1, centerY: -0.3, halfExtent: 0.6)
        )

        let wideScreen = pattern.map {
            wide.project(angleFraction: $0.angle, radiusFraction: $0.radius).screenPoint
        }
        let narrowScreen = pattern.map {
            narrow.project(angleFraction: $0.angle, radiusFraction: $0.radius).screenPoint
        }

        let wideAB = Self.vector(wideScreen, 0, 1)
        let wideAC = Self.vector(wideScreen, 0, 2)
        let narrowAB = Self.vector(narrowScreen, 0, 1)
        let narrowAC = Self.vector(narrowScreen, 0, 2)

        let scaleAB = try Self.scaleFactorAssumingPureScaling(from: wideAB, to: narrowAB, label: "AB")
        let scaleAC = try Self.scaleFactorAssumingPureScaling(from: wideAC, to: narrowAC, label: "AC")
        XCTAssertEqual(
            scaleAB, scaleAC, accuracy: 1e-9,
            "Ein einziger, gemeinsamer Skalierungsfaktor -- keine anisotrope Verzerrung"
        )
    }

    /// **Gegenprobe:** Eine direkte, lokale Nachbildung der bis
    /// SICK-032b2c gültigen Verkettung -- Winkel- und Entfernungsanteil
    /// **getrennt** auf den gewählten Ausschnitt normiert, das Ergebnis
    /// danach wieder als **vollständigen** Fächer gezeichnet
    /// (`fan.screenPoint(angleFraction:displayRadiusFraction:)` erwartet
    /// genau das: einen Anteil am ganzen Öffnungswinkel). Reimplementiert
    /// bewusst lokal in diesem Test statt den inzwischen entfernten
    /// `ScanViewport`-Typ wiederherzustellen -- die **Formel** ist der
    /// Prüfgegenstand, nicht der längst ersetzte Werttyp.
    ///
    /// Dasselbe asymmetrische Muster, dieselbe Formtreue-Prüfung wie
    /// oben -- hier muss sie **scheitern**: Ein enger werdendes
    /// Winkelfenster dreht das Muster, weil unterschiedlich weit vom
    /// Mittelpunkt entfernte Punkte unterschiedlich stark vom erneuten
    /// Auffächern betroffen sind (genau der Owner-Befund nach
    /// SICK-032b2b).
    func testTheOldReFanningCompositionFailsThisSameCheck() {
        let fan = makeFan()
        let pattern: [(angle: Double, radius: Double)] = [
            (0.3, 0.4), (0.7, 0.6), (0.5, 0.9)
        ]
        // Volle Feldbreite -- entspricht der alten Gesamtansicht.
        let fullWindow: (angle: (Double, Double), radius: (Double, Double)) = ((0, 1), (0, 1))
        // Ein enger werdendes Winkelfenster, Entfernung unverändert --
        // genau der Fall aus dem Owner-Befund.
        let narrowedWindow: (angle: (Double, Double), radius: (Double, Double)) = ((0.2, 0.8), (0, 1))

        func oldReFannedPoint(
            _ p: (angle: Double, radius: Double),
            in window: (angle: (Double, Double), radius: (Double, Double))
        ) -> CGPoint {
            let normalizedAngle = (p.angle - window.angle.0) / (window.angle.1 - window.angle.0)
            let normalizedRadius = (p.radius - window.radius.0) / (window.radius.1 - window.radius.0)
            return fan.screenPoint(angleFraction: normalizedAngle, displayRadiusFraction: normalizedRadius)
        }

        let wideScreen = pattern.map { oldReFannedPoint($0, in: fullWindow) }
        let narrowScreen = pattern.map { oldReFannedPoint($0, in: narrowedWindow) }

        let wideAB = Self.vector(wideScreen, 0, 1)
        let narrowAB = Self.vector(narrowScreen, 0, 1)

        let fromLength = Self.length(wideAB)
        let toLength = Self.length(narrowAB)
        XCTAssertGreaterThan(fromLength, 0)
        XCTAssertGreaterThan(toLength, 0)
        let fromUnit = CGPoint(x: wideAB.x / CGFloat(fromLength), y: wideAB.y / CGFloat(fromLength))
        let toUnit = CGPoint(x: narrowAB.x / CGFloat(toLength), y: narrowAB.y / CGFloat(toLength))
        let cross = Double(fromUnit.x) * Double(toUnit.y) - Double(fromUnit.y) * Double(toUnit.x)

        XCTAssertNotEqual(
            cross, 0, accuracy: 1e-6,
            "Die alte Verkettung dreht/verzerrt das Muster beim Verengen des Winkelfensters -- " +
            "genau das fängt testAnAsymmetricPatternMapsAsOneAffineScalingUnderZoom ab"
        )
    }

    private static func vector(_ points: [CGPoint], _ a: Int, _ b: Int) -> CGPoint {
        CGPoint(x: points[b].x - points[a].x, y: points[b].y - points[a].y)
    }

    private static func length(_ vector: CGPoint) -> Double {
        (Double(vector.x) * Double(vector.x) + Double(vector.y) * Double(vector.y)).squareRoot()
    }

    /// Prüft, dass `from -> to` eine reine **positive** Skalierung ist
    /// -- parallel (Kreuzprodukt der Einheitsvektoren `0`) und gleiche
    /// Richtung (Skalarprodukt nahe `1`), keine Drehung, kein Umklappen
    /// -- und liefert den Skalierungsfaktor als Längenverhältnis.
    private static func scaleFactorAssumingPureScaling(
        from: CGPoint, to: CGPoint, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Double {
        let fromLength = length(from)
        let toLength = length(to)
        guard fromLength > 1e-9, toLength > 1e-9 else {
            XCTFail("\(label): entarteter Vektor", file: file, line: line)
            throw UnexpectedRejection()
        }
        let fromUnit = CGPoint(x: from.x / CGFloat(fromLength), y: from.y / CGFloat(fromLength))
        let toUnit = CGPoint(x: to.x / CGFloat(toLength), y: to.y / CGFloat(toLength))
        let cross = Double(fromUnit.x) * Double(toUnit.y) - Double(fromUnit.y) * Double(toUnit.x)
        let dot = Double(fromUnit.x) * Double(toUnit.x) + Double(fromUnit.y) * Double(toUnit.y)
        XCTAssertEqual(
            cross, 0, accuracy: 1e-9,
            "\(label): keine Drehung -- die Richtung muss unter jedem Ausschnitt erhalten bleiben",
            file: file, line: line
        )
        XCTAssertGreaterThan(dot, 0.999, "\(label): gleiche Richtung, kein Umklappen", file: file, line: line)
        return toLength / fromLength
    }

    // MARK: - Der Ausschnitt bestimmt die Abbildung

    /// Ein Punkt außerhalb des Ausschnitts wird **nicht geklammert** --
    /// sonst klebten alle entfernten Messwerte am Rand und täuschten
    /// Messungen vor, die es nicht gibt.
    func testAPointOutsideTheWindowIsMarkedAndNotClamped() throws {
        let fan = makeFan()
        let viewport = try ScanPlaneViewport.build(centerX: 0, centerY: -0.5, halfExtent: 0.1)
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: viewport)

        let tooFar = geometry.project(angleFraction: 0.5, radiusFraction: 0.9)
        let tooNear = geometry.project(angleFraction: 0.5, radiusFraction: 0.1)
        let besideIt = geometry.project(angleFraction: 0.05, radiusFraction: 0.5)

        XCTAssertFalse(tooFar.isInsideViewport)
        XCTAssertFalse(tooNear.isInsideViewport)
        XCTAssertFalse(besideIt.isInsideViewport)
        XCTAssertGreaterThan(
            distanceFromCenter(tooFar.screenPoint, fan: fan), Double(fan.radius),
            "Außerhalb heißt wirklich außerhalb des gezeichneten Fächers"
        )
    }

    // MARK: - Rundlauf und Entartung

    func testScreenAndFieldCoordinatesAreInverseToEachOther() throws {
        let fan = makeFan()
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: .fullField)

        // Bewusst **oberhalb** von Radius 0: Dort fällt der ganze
        // Winkelbereich auf den Fächerursprung zusammen, und der Winkel
        // ist nicht rekonstruierbar (eigener Test unten).
        for angle in stride(from: 0.2, through: 0.9, by: 0.1) {
            for radius in stride(from: 0.1, through: 0.35, by: 0.05) {
                let projected = geometry.project(angleFraction: angle, radiusFraction: radius)
                let back = try XCTUnwrap(geometry.fieldCoordinate(forScreenPoint: projected.screenPoint))
                XCTAssertEqual(back.angleFraction, angle, accuracy: 1e-9)
                XCTAssertEqual(back.radiusFraction, radius, accuracy: 1e-9)
            }
        }
    }

    /// **Der Fächerursprung ist genau ein Bildschirmpunkt.**
    ///
    /// Das ist keine Schwäche der Abbildung, sondern die Spitze jeder
    /// Fächerdarstellung: Bei Rohwert `0` fällt der gesamte Winkelbereich
    /// auf denselben Weltpunkt (den Ursprung) und damit auf denselben
    /// Bildschirmpunkt -- unabhängig vom gewählten Ausschnitt, weil die
    /// kanonische Welt genau einmal, vor der affinen Ausschnittsabbildung,
    /// bestimmt wird. Ein Zeiger genau dort trägt deshalb keine
    /// Winkelinformation -- die Umkehrung liefert einen Wert, aber nicht
    /// den ursprünglichen Winkel.
    func testTheFieldOriginCollapsesOntoASinglePointWithoutAngle() throws {
        let fan = makeFan()
        let viewport = try ScanPlaneViewport.build(centerX: 0, centerY: 0, halfExtent: 0.6)
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: viewport)

        let atLowAngle = geometry.project(angleFraction: 0.2, radiusFraction: 0)
        let atHighAngle = geometry.project(angleFraction: 0.9, radiusFraction: 0)

        XCTAssertEqual(Double(atLowAngle.screenPoint.x), Double(atHighAngle.screenPoint.x), accuracy: 1e-9)
        XCTAssertEqual(Double(atLowAngle.screenPoint.y), Double(atHighAngle.screenPoint.y), accuracy: 1e-9)

        let back = try XCTUnwrap(geometry.fieldCoordinate(forScreenPoint: atLowAngle.screenPoint))
        XCTAssertEqual(back.radiusFraction, 0, accuracy: 1e-9)
        XCTAssertFalse(back.isAngleDefined, "Am Fächerursprung ist der Winkel nicht bestimmbar")
    }

    /// Bei entarteter Fächergeometrie gibt es **keine** erfundene
    /// Zeigerposition: `nil` statt eines neutralen Ersatzwerts, der den
    /// Ausschnitt an eine Stelle springen ließe, auf die niemand geklickt
    /// hat.
    func testADegenerateFanYieldsNoFieldCoordinate() {
        let degenerate = LinearScanFieldGeometry(fan: makeFan(radius: 0), viewport: .fullField)
        XCTAssertNil(degenerate.fieldCoordinate(forScreenPoint: CGPoint(x: 10, y: -10)))

        let healthy = LinearScanFieldGeometry(fan: makeFan(), viewport: .fullField)
        XCTAssertNil(healthy.fieldCoordinate(forScreenPoint: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertNil(healthy.fieldCoordinate(forScreenPoint: CGPoint(x: 0, y: CGFloat.infinity)))
    }

    // MARK: - Bediennaht: Anker am Zeiger

    /// **Der eigentliche Ankernachweis**: Beim Zoomen am Zeiger bleibt
    /// der Punkt unter dem Zeiger an derselben Bildschirmstelle -- über
    /// fünf aufeinanderfolgende Zoomschritte. Geprüft wird das über die
    /// Geometrie, nicht nur über Zahlen im Ausschnitt; das ist zugleich
    /// die Regressionsprüfung für den SICK-032b2c-Rechenfehler in
    /// `project(worldPoint:)` (doppelte Division durch `halfExtent`), der
    /// diesen Nachweis quadratisch statt linear hätte scheitern lassen.
    func testZoomingAtThePointerKeepsThatPointUnderThePointer() throws {
        let fan = makeFan()
        var viewport = try ScanPlaneViewport.build(centerX: 0, centerY: 0, halfExtent: 0.8)
        let pointer = CGPoint(x: 40, y: -55)

        for _ in 0..<5 {
            let geometry = LinearScanFieldGeometry(fan: fan, viewport: viewport)
            let anchor = try XCTUnwrap(geometry.worldPoint(forScreenPoint: pointer))

            viewport = try applied(
                viewport.zoomed(byFactor: 1.5, anchorX: Double(anchor.x), anchorY: Double(anchor.y))
            )

            let after = LinearScanFieldGeometry(fan: fan, viewport: viewport)
            let stillThere = after.project(worldPoint: anchor)
            XCTAssertEqual(Double(stillThere.screenPoint.x), Double(pointer.x), accuracy: 1e-6)
            XCTAssertEqual(Double(stillThere.screenPoint.y), Double(pointer.y), accuracy: 1e-6)
        }
    }

    // MARK: - Bediennaht: Rechteck aus zwei Bildschirmecken

    /// Der Ziehrahmen: Zwei Bildschirmecken werden zu Weltpositionen und
    /// danach zu den Grenzen des neuen Ausschnitts -- beide Ecken liegen
    /// hinterher garantiert im sichtbaren Ausschnitt (isotrope Anpassung
    /// an die **größere** der beiden Spannen, SICK-032b1).
    func testARectangleDraggedOnScreenLandsBothCornersInsideTheNewWindow() throws {
        let fan = makeFan()
        let start = ScanPlaneViewport.fullField
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: start)

        let cornerA = CGPoint(x: -30, y: -20)
        let cornerB = CGPoint(x: 25, y: -60)
        let worldA = try XCTUnwrap(geometry.worldPoint(forScreenPoint: cornerA))
        let worldB = try XCTUnwrap(geometry.worldPoint(forScreenPoint: cornerB))

        let zoomed = try applied(
            start.zoomedToRectangle(
                xA: Double(worldA.x), xB: Double(worldB.x),
                yA: Double(worldA.y), yB: Double(worldB.y)
            )
        )
        XCTAssertLessThan(zoomed.halfExtent, start.halfExtent, "Das Rechteck zoomt tatsächlich hinein")

        let after = LinearScanFieldGeometry(fan: fan, viewport: zoomed)
        for corner in [worldA, worldB] {
            let projected = after.project(worldPoint: corner)
            XCTAssertTrue(projected.isInsideViewport)
        }
    }

    // MARK: - Fenstergröße und Vollbild

    /// „Vollbild und Fenstergrößenwechsel erhalten dieselbe lineare
    /// Geometrie" (Owner-Vorgabe): Dieselbe Feldkoordinate liegt in
    /// jeder Ansichtsgröße an derselben **relativen** Stelle.
    func testTheSameFieldCoordinateKeepsItsRelativePlaceInEveryViewSize() throws {
        let viewport = try ScanPlaneViewport.build(centerX: 0, centerY: 0, halfExtent: 0.5)
        let sizes = [
            CGSize(width: 400, height: 300),
            CGSize(width: 1_280, height: 800),
            CGSize(width: 3_840, height: 2_160),
            CGSize(width: 900, height: 900)
        ]

        var relativePositions: [(Double, Double)] = []
        for size in sizes {
            let fan = FanScreenGeometry(size: size)
            let geometry = LinearScanFieldGeometry(fan: fan, viewport: viewport)
            let projected = geometry.project(angleFraction: 0.35, radiusFraction: 0.2)
            relativePositions.append((
                distanceFromCenter(projected.screenPoint, fan: fan) / Double(fan.radius),
                atan2(
                    Double(projected.screenPoint.y - fan.center.y),
                    Double(projected.screenPoint.x - fan.center.x)
                )
            ))
        }

        for position in relativePositions.dropFirst() {
            XCTAssertEqual(position.0, relativePositions[0].0, accuracy: 1e-9, "Relativer Radius")
            XCTAssertEqual(position.1, relativePositions[0].1, accuracy: 1e-9, "Winkel")
        }
    }

    // MARK: - SICK-032b2c-K1: Canvas und Viewport sind derselbe Ausschnitt

    /// **Pflichtnachweis:** Für `800 × 600` liegen in `.fullField` beide
    /// äußeren Fächerendpunkte innerhalb der definierten Canvas, und der
    /// vollständige Fächer ist sichtbar (Abnahmeblocker 1,
    /// `.agent_handoff/review-sick-032b2c.md`).
    func testFullFieldShowsBothOuterEndpointsWithinTheCanvasFor800x600() {
        let fan = FanScreenGeometry(size: CGSize(width: 800, height: 600))
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: .fullField)

        let left = geometry.project(angleFraction: 0, radiusFraction: 1).screenPoint
        let right = geometry.project(angleFraction: 1, radiusFraction: 1).screenPoint
        let canvas = geometry.canvasRect

        // Beide Endpunkte liegen **auf** dem Rand der Canvas (der
        // vollständige Fächer füllt sie exakt aus) -- `CGRect.contains`
        // schließt die obere/rechte Kante aus, deshalb ein direkter
        // Vergleich mit kleiner Toleranz statt `contains`.
        for point in [left, right] {
            XCTAssertGreaterThanOrEqual(Double(point.x), Double(canvas.minX) - 1e-9)
            XCTAssertLessThanOrEqual(Double(point.x), Double(canvas.maxX) + 1e-9)
            XCTAssertGreaterThanOrEqual(Double(point.y), Double(canvas.minY) - 1e-9)
            XCTAssertLessThanOrEqual(Double(point.y), Double(canvas.maxY) + 1e-9)
        }

        // Handnachrechenbare Werte für exakt diese, im Auftrag benannte
        // Größe -- die Gegenprobe des alten Fächerankers steht in
        // `FanScreenGeometryTests`.
        XCTAssertEqual(canvas, CGRect(x: 100, y: 0, width: 600, height: 600))
        XCTAssertEqual(Double(left.x), 100, accuracy: 1e-9)
        XCTAssertEqual(Double(left.y), 300, accuracy: 1e-9)
        XCTAssertEqual(Double(right.x), 700, accuracy: 1e-9)
        XCTAssertEqual(Double(right.y), 300, accuracy: 1e-9)
    }

    /// **Pflichtnachweis:** Für einen verschobenen Ausschnitt
    /// (`centerY = -0,5`, `halfExtent = 0,1`) landet der
    /// Viewport-Mittelpunkt in der Canvasmitte, und beide
    /// modellseitigen Grenzen entsprechen den wirklichen Clipgrenzen --
    /// **jeder** aktive Ausschnitt füllt dieselbe feste Canvas exakt,
    /// nicht nur die Gesamtansicht.
    func testAShiftedViewportCentersOnTheCanvasMiddleAndItsBoundsMatchTheTrueClipBounds() throws {
        let fan = FanScreenGeometry(size: CGSize(width: 800, height: 600))
        let viewport = try ScanPlaneViewport.build(centerX: 0, centerY: -0.5, halfExtent: 0.1)
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: viewport)
        let canvas = geometry.canvasRect

        let center = geometry.project(worldPoint: CGPoint(x: viewport.centerX, y: viewport.centerY)).screenPoint
        XCTAssertEqual(Double(center.x), Double(canvas.midX), accuracy: 1e-9)
        XCTAssertEqual(Double(center.y), Double(canvas.midY), accuracy: 1e-9)

        let lowerLeft = geometry.project(
            worldPoint: CGPoint(x: viewport.xLowerBound, y: viewport.yLowerBound)
        ).screenPoint
        let upperRight = geometry.project(
            worldPoint: CGPoint(x: viewport.xUpperBound, y: viewport.yUpperBound)
        ).screenPoint
        XCTAssertEqual(Double(lowerLeft.x), Double(canvas.minX), accuracy: 1e-9)
        XCTAssertEqual(Double(lowerLeft.y), Double(canvas.minY), accuracy: 1e-9)
        XCTAssertEqual(Double(upperRight.x), Double(canvas.maxX), accuracy: 1e-9)
        XCTAssertEqual(Double(upperRight.y), Double(canvas.maxY), accuracy: 1e-9)
    }

    /// **Gegenprobe zu beiden Tests oben:** Der alte, an der Fächerspitze
    /// verankerte Platz (`.agent_handoff/review-sick-032b2c.md`,
    /// Abnahmeblocker 1) erfüllt keinen der beiden Nachweise -- lokal
    /// nachgebildet, statt die längst ersetzte Formel in
    /// `FanScreenGeometry` wiederherzustellen.
    func testTheOldApexAnchoredFanFailsBothOfTheAboveChecks() throws {
        let size = CGSize(width: 800, height: 600)
        let minSide = min(size.width, size.height)
        let oldFan = FanScreenGeometry(
            center: CGPoint(x: size.width / 2, y: size.height - minSide * 0.05),
            radius: minSide * 0.9,
            startAngleRadians: 270.0 * .pi / 180 - .pi / 2,
            endAngleRadians: 270.0 * .pi / 180 + .pi / 2
        )
        let geometry = LinearScanFieldGeometry(fan: oldFan, viewport: .fullField)
        let left = geometry.project(angleFraction: 0, radiusFraction: 1).screenPoint
        let right = geometry.project(angleFraction: 1, radiusFraction: 1).screenPoint
        let fullCanvas = CGRect(x: 0, y: 0, width: size.width, height: size.height)

        XCTAssertFalse(
            fullCanvas.contains(left) && fullCanvas.contains(right),
            "Der alte Fächeranker muss mindestens einen Endpunkt aus der Ansicht treiben"
        )

        let shiftedViewport = try ScanPlaneViewport.build(centerX: 0, centerY: -0.5, halfExtent: 0.1)
        let shifted = LinearScanFieldGeometry(fan: oldFan, viewport: shiftedViewport)
        let center = shifted.project(
            worldPoint: CGPoint(x: shiftedViewport.centerX, y: shiftedViewport.centerY)
        ).screenPoint
        XCTAssertNotEqual(
            Double(center.y), Double(size.height / 2), accuracy: 1,
            "Der alte Anker bildet den Viewport-Mittelpunkt nicht auf die wirkliche Ansichtsmitte ab"
        )
    }

    // MARK: - SICK-032b2c-K2: Bedienumkehrung ist an die sichtbare Canvas gebunden

    /// **Pflichtnachweis:** Bei `800 × 600` (Canvas `x: 100...700`,
    /// `y: 0...600`) liefern Bildschirm `x = 0` (unsichtbarer linker
    /// Letterbox-Rand) und der echte Canvasrand `x = 100` für die
    /// **Bedienumkehr** ``LinearScanFieldGeometry/boundedWorldPoint(forScreenPoint:)``
    /// denselben Weltpunkt. Entsprechend für den rechten Rand.
    ///
    /// `.agent_handoff/review-sick-032b2c-k1.md` belegt für dieselbe
    /// Geometrie, dass die **ungeklammerte** ``worldPoint(forScreenPoint:)``
    /// bei `x = 0` noch `0,033333…` liefert statt `0,1` -- das ist genau
    /// der Unterschied, den diese Methode schließt.
    func testBoundedWorldPointAtTheLeftAndRightLetterboxMarginsEqualsTheCanvasEdgeFor800x600() throws {
        let fan = FanScreenGeometry(size: CGSize(width: 800, height: 600))
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: try ScanPlaneViewport.build(
            centerX: 0.3, centerY: 0, halfExtent: 0.2
        ))
        XCTAssertEqual(geometry.canvasRect, CGRect(x: 100, y: 0, width: 600, height: 600))

        let leftMargin = try XCTUnwrap(
            geometry.boundedWorldPoint(forScreenPoint: CGPoint(x: 0, y: 300))
        )
        let leftEdge = try XCTUnwrap(
            geometry.boundedWorldPoint(forScreenPoint: CGPoint(x: 100, y: 300))
        )
        XCTAssertEqual(Double(leftMargin.x), Double(leftEdge.x), accuracy: 1e-12)
        XCTAssertEqual(Double(leftEdge.x), 0.1, accuracy: 1e-12, "Handnachrechenbarer Wert aus dem Review")

        let rightMargin = try XCTUnwrap(
            geometry.boundedWorldPoint(forScreenPoint: CGPoint(x: 800, y: 300))
        )
        let rightEdge = try XCTUnwrap(
            geometry.boundedWorldPoint(forScreenPoint: CGPoint(x: 700, y: 300))
        )
        XCTAssertEqual(Double(rightMargin.x), Double(rightEdge.x), accuracy: 1e-12)
        XCTAssertEqual(Double(rightEdge.x), 0.5, accuracy: 1e-12)
    }

    /// **Pflichtnachweis, hohe schmale Ansicht:** Bei `800 × 600` liegt
    /// die Canvas über die volle Höhe (kein oberer/unterer Letterbox-Rand
    /// -- der kürzere Seite ist dort die Höhe). Eine hohe, schmale
    /// Ansicht (`600 × 800`) kehrt das um: Jetzt ist die Breite die
    /// kürzere Seite, und oben/unten bleibt ein unsichtbarer Rand
    /// (Canvas `y: 100...700`).
    func testBoundedWorldPointAtTheTopAndBottomLetterboxMarginsEqualsTheCanvasEdgeForANarrowTallView() throws {
        let fan = FanScreenGeometry(size: CGSize(width: 600, height: 800))
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: try ScanPlaneViewport.build(
            centerX: 0, centerY: 0.3, halfExtent: 0.2
        ))
        XCTAssertEqual(geometry.canvasRect, CGRect(x: 0, y: 100, width: 600, height: 600))

        let topMargin = try XCTUnwrap(
            geometry.boundedWorldPoint(forScreenPoint: CGPoint(x: 300, y: 0))
        )
        let topEdge = try XCTUnwrap(
            geometry.boundedWorldPoint(forScreenPoint: CGPoint(x: 300, y: 100))
        )
        XCTAssertEqual(Double(topMargin.y), Double(topEdge.y), accuracy: 1e-12)

        let bottomMargin = try XCTUnwrap(
            geometry.boundedWorldPoint(forScreenPoint: CGPoint(x: 300, y: 800))
        )
        let bottomEdge = try XCTUnwrap(
            geometry.boundedWorldPoint(forScreenPoint: CGPoint(x: 300, y: 700))
        )
        XCTAssertEqual(Double(bottomMargin.y), Double(bottomEdge.y), accuracy: 1e-12)
    }

    /// Ein Bildschirmpunkt bereits innerhalb der Canvas bleibt
    /// unverändert -- die Klammerung greift ausschließlich außerhalb.
    func testCanvasClampedScreenPointLeavesAnInsidePointUnchanged() {
        let fan = FanScreenGeometry(size: CGSize(width: 800, height: 600))
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: .fullField)
        let inside = CGPoint(x: 250, y: 400)
        XCTAssertEqual(geometry.canvasClampedScreenPoint(inside), inside)
    }

    /// **Pflichtnachweis, die exakte Zahlenprobe aus dem Review:** Mit
    /// Viewport `centerX = 0,3`, `halfExtent = 0,2` führt Zoomfaktor `2`
    /// bei Bildschirm `x = 0` zu **demselben** Ergebnis wie bei
    /// `x = 100` (`centerX = 0,2`) -- **nicht** zum alten, unsichtbaren
    /// Ankerergebnis `0,166666…`, das die ungeklammerte Umkehrung
    /// liefern würde.
    func testTheDocumentedZoomExampleLandsOnTheCanvasEdgeResultNotTheInvisibleAnchor() throws {
        let fan = FanScreenGeometry(size: CGSize(width: 800, height: 600))
        let viewport = try ScanPlaneViewport.build(centerX: 0.3, centerY: 0, halfExtent: 0.2)
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: viewport)

        let anchorAtMargin = try XCTUnwrap(
            geometry.boundedWorldPoint(forScreenPoint: CGPoint(x: 0, y: 300))
        )
        let zoomedFromMargin = try applied(
            viewport.zoomed(byFactor: 2, anchorX: Double(anchorAtMargin.x), anchorY: Double(anchorAtMargin.y))
        )

        let anchorAtEdge = try XCTUnwrap(
            geometry.boundedWorldPoint(forScreenPoint: CGPoint(x: 100, y: 300))
        )
        let zoomedFromEdge = try applied(
            viewport.zoomed(byFactor: 2, anchorX: Double(anchorAtEdge.x), anchorY: Double(anchorAtEdge.y))
        )

        XCTAssertEqual(zoomedFromMargin.centerX, zoomedFromEdge.centerX, accuracy: 1e-12)
        XCTAssertEqual(zoomedFromEdge.centerX, 0.2, accuracy: 1e-12)
        XCTAssertNotEqual(zoomedFromMargin.centerX, 0.166_666, accuracy: 1e-5)
    }

    /// **Gegenprobe:** Die **ungeklammerte** ``worldPoint(forScreenPoint:)``
    /// direkt als Zoomanker liefert exakt das alte, im Review belegte
    /// Fehlergebnis `0,166666…` -- der Beweis, dass eine direkte
    /// Verwendung dieser Methode statt ``boundedWorldPoint(forScreenPoint:)``
    /// den obigen Pflichtnachweis brechen würde.
    func testUsingTheUnclampedInversionDirectlyWouldMissTheDocumentedResult() throws {
        let fan = FanScreenGeometry(size: CGSize(width: 800, height: 600))
        let viewport = try ScanPlaneViewport.build(centerX: 0.3, centerY: 0, halfExtent: 0.2)
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: viewport)

        let unclampedAnchor = try XCTUnwrap(
            geometry.worldPoint(forScreenPoint: CGPoint(x: 0, y: 300))
        )
        XCTAssertEqual(Double(unclampedAnchor.x), 1.0 / 30.0, accuracy: 1e-9, "Handnachrechenbar: 0,3 - (4/3)*0,2")

        let zoomedFromUnclampedAnchor = try applied(
            viewport.zoomed(byFactor: 2, anchorX: Double(unclampedAnchor.x), anchorY: Double(unclampedAnchor.y))
        )
        XCTAssertEqual(
            zoomedFromUnclampedAnchor.centerX, 0.166_666_666_666_666_6, accuracy: 1e-9,
            "Das alte, im Review belegte Fehlergebnis -- kein produktiver Weg darf mehr dorthin führen"
        )
        XCTAssertNotEqual(zoomedFromUnclampedAnchor.centerX, 0.2, accuracy: 1e-6)
    }
}
