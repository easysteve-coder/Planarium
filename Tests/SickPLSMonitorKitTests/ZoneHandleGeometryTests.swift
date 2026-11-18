import XCTest
import CoreGraphics
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// SICK-032b3: Wo die vier Griffe liegen und was der Zeiger trifft.
///
/// Alle Tests rechnen gegen eine konstruierte Ansichtsgeometrie — keine
/// gerenderte Ansicht, keine Geste des Systems, kein Scanner, kein
/// Audiogerät.
final class ZoneHandleGeometryTests: XCTestCase {

    private let fan = FanScreenGeometry(
        center: .zero, radius: 1000, startAngleRadians: 0, endAngleRadians: .pi
    )

    private var fullField: LinearScanFieldGeometry {
        LinearScanFieldGeometry(fan: fan, viewport: .fullField)
    }

    private func zone(
        index: ClosedRange<Double> = 0.3...0.7,
        value: ClosedRange<UInt16> = 2000...6000,
        role: ZoneRole = .pitch
    ) throws -> Zone {
        try Zone.build(
            indexLowerBound: index.lowerBound, indexUpperBound: index.upperBound,
            valueLowerBound: value.lowerBound, valueUpperBound: value.upperBound,
            role: role
        )
    }

    private func point(
        index: Double, value: Double, in geometry: LinearScanFieldGeometry
    ) -> CGPoint {
        geometry.project(
            angleFraction: index,
            radiusFraction: value / PolarProfileGeometry.maxRawMeasurementValue
        ).screenPoint
    }

    private func placed(
        _ handle: ZoneGeometryHandle, of zone: Zone, in geometry: LinearScanFieldGeometry
    ) throws -> ZoneHandleGeometry.PlacedHandle {
        let all = ZoneHandleGeometry.placedHandles(for: zone, in: geometry)
        return try XCTUnwrap(all.first { $0.handle == handle })
    }

    // MARK: - Lage

    func testEveryHandleIsPlacedOnTheBoundaryItMoves() throws {
        let zone = try zone()
        let geometry = fullField

        let expected: [(ZoneGeometryHandle, CGPoint)] = [
            (.indexLowerBound, point(index: 0.3, value: 4000, in: geometry)),
            (.indexUpperBound, point(index: 0.7, value: 4000, in: geometry)),
            (.valueInnerBound, point(index: 0.5, value: 2000, in: geometry)),
            (.valueOuterBound, point(index: 0.5, value: 6000, in: geometry))
        ]

        for (handle, expectedPoint) in expected {
            let actual = try placed(handle, of: zone, in: geometry).screenPoint
            XCTAssertEqual(Double(actual.x), Double(expectedPoint.x), accuracy: 1e-6, "\(handle)")
            XCTAssertEqual(Double(actual.y), Double(expectedPoint.y), accuracy: 1e-6, "\(handle)")
        }
    }

    func testAllFourHandlesExistExactlyOnceAndInAStableOrder() throws {
        let placed = ZoneHandleGeometry.placedHandles(for: try zone(), in: fullField)
        XCTAssertEqual(placed.map(\.handle), ZoneGeometryHandle.allCases)
    }

    func testNoTwoHandlesOfAWellFormedZoneFallOnTheSamePoint() throws {
        let placed = ZoneHandleGeometry.placedHandles(for: try zone(), in: fullField)
        for a in placed.indices {
            for b in placed.indices where b > a {
                let dx = placed[a].screenPoint.x - placed[b].screenPoint.x
                let dy = placed[a].screenPoint.y - placed[b].screenPoint.y
                XCTAssertGreaterThan(
                    (dx * dx + dy * dy).squareRoot(), 1,
                    "\(placed[a].handle) und \(placed[b].handle) fallen zusammen"
                )
            }
        }
    }

    /// Die Griffe folgen dem Ausschnitt — sonst läge der Trefferbereich
    /// nach einem Zoom nicht mehr auf der gezeichneten Zone.
    func testTheHandlesFollowTheViewport() throws {
        let zone = try zone()
        let zoomed = try ScanPlaneViewport.build(centerX: 0.1, centerY: 0.1, halfExtent: 0.3)
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: zoomed)

        let inner = try placed(.valueInnerBound, of: zone, in: geometry).screenPoint
        let expected = point(index: 0.5, value: 2000, in: geometry)
        XCTAssertEqual(Double(inner.x), Double(expected.x), accuracy: 1e-6)
        XCTAssertEqual(Double(inner.y), Double(expected.y), accuracy: 1e-6)

        // Und die Lage ist eine andere als in der Gesamtansicht.
        let wide = try placed(.valueInnerBound, of: zone, in: fullField).screenPoint
        XCTAssertGreaterThan(abs(Double(inner.x - wide.x)) + abs(Double(inner.y - wide.y)), 10)
    }

    // MARK: - Sichtbarkeit

    func testAZoneCompletelyOutsideTheViewportIsNeitherVisibleNorOperable() throws {
        let far = try zone(value: 7000...8000)
        let near = try ScanPlaneViewport.build(centerX: 0, centerY: 0, halfExtent: 0.05)
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: near)

        XCTAssertFalse(ZoneHandleGeometry.isVisible(far, in: geometry))
        for handle in ZoneGeometryHandle.allCases {
            XCTAssertFalse(try placed(handle, of: far, in: geometry).isVisible, "\(handle)")
        }
        // Und auch die eigene Griffposition ist dann kein Ziel.
        let onHandle = point(index: 0.5, value: 7000, in: geometry)
        XCTAssertNil(ZoneHandleGeometry.gesture(at: onHandle, for: far, in: geometry))
    }

    /// Eine **teilweise** sichtbare Zone bleibt bedienbar — aber nur über
    /// die Griffe, die wirklich im Bild liegen.
    func testOnlyTheHandlesInsideTheViewportAreOperable() throws {
        let zone = try zone(value: 2000...6000)
        let window = try ScanPlaneViewport.build(
            centerX: 0, centerY: 0,
            halfExtent: 5000 / PolarProfileGeometry.maxRawMeasurementValue
        )
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: window)

        XCTAssertTrue(ZoneHandleGeometry.isVisible(zone, in: geometry))
        XCTAssertTrue(try placed(.valueInnerBound, of: zone, in: geometry).isVisible)
        XCTAssertFalse(
            try placed(.valueOuterBound, of: zone, in: geometry).isVisible,
            "Die Außengrenze bei 6000 liegt außerhalb des Fensters bis 5000"
        )

        let outerPoint = try placed(.valueOuterBound, of: zone, in: geometry).screenPoint
        XCTAssertNotEqual(
            ZoneHandleGeometry.gesture(at: outerPoint, for: zone, in: geometry),
            .handle(.valueOuterBound),
            "Ein unsichtbarer Griff ist kein Ziel"
        )
    }

    // MARK: - Treffer

    func testEachHandleIsHitAtItsOwnPosition() throws {
        let zone = try zone()
        for handle in ZoneGeometryHandle.allCases {
            let position = try placed(handle, of: zone, in: fullField).screenPoint
            XCTAssertEqual(
                ZoneHandleGeometry.gesture(at: position, for: zone, in: fullField),
                .handle(handle)
            )
        }
    }

    /// **Griffe schlagen die Fläche.** Ohne diese Reihenfolge wäre eine
    /// schmale Zone über ihre Griffe gar nicht bedienbar: Deren
    /// Trefferbereiche liegen dann vollständig in ihrer eigenen Fläche.
    func testAHandleInsideTheZoneAreaStillWinsOverMovingTheWholeZone() throws {
        let zone = try zone()
        let inner = try placed(.valueInnerBound, of: zone, in: fullField).screenPoint

        // Der Griffpunkt liegt fachlich auf der Zonenfläche.
        let field = try XCTUnwrap(fullField.fieldCoordinate(forScreenPoint: inner))
        XCTAssertTrue(zone.indexRange.contains(field.angleFraction))
        XCTAssertTrue(
            zone.valueRange.contains(ZoneEditorGeometry.rawValue(fromRadiusFraction: field.radiusFraction))
        )

        XCTAssertEqual(
            ZoneHandleGeometry.gesture(at: inner, for: zone, in: fullField),
            .handle(.valueInnerBound)
        )
    }

    func testTheNearestHandleWinsWhenTwoAreWithinReach() throws {
        // Eine sehr schmale Zone: Beide Indexgriffe liegen dicht
        // beieinander, aber nicht auf demselben Punkt.
        let narrow = try zone(index: 0.50...0.51)
        let lower = try placed(.indexLowerBound, of: narrow, in: fullField).screenPoint
        let upper = try placed(.indexUpperBound, of: narrow, in: fullField).screenPoint
        let distance = ((lower.x - upper.x) * (lower.x - upper.x)
            + (lower.y - upper.y) * (lower.y - upper.y)).squareRoot()
        XCTAssertLessThan(distance, 2 * ZoneHandleGeometry.handleHitRadius, "Sonst prüft der Test nichts")

        XCTAssertEqual(
            ZoneHandleGeometry.gesture(at: lower, for: narrow, in: fullField),
            .handle(.indexLowerBound)
        )
        XCTAssertEqual(
            ZoneHandleGeometry.gesture(at: upper, for: narrow, in: fullField),
            .handle(.indexUpperBound)
        )
    }

    func testTheZoneAreaMovesTheWholeZone() throws {
        let zone = try zone()
        // Mitte der Zone, weit weg von jedem Griff.
        let center = point(index: 0.5, value: 4000, in: fullField)
        XCTAssertEqual(
            ZoneHandleGeometry.gesture(at: center, for: zone, in: fullField),
            .moveWholeZone
        )
    }

    func testAPointFarOutsideTheZoneHitsNothing() throws {
        let zone = try zone(index: 0.3...0.4, value: 2000...2400)
        let elsewhere = point(index: 0.8, value: 6000, in: fullField)
        XCTAssertNil(ZoneHandleGeometry.gesture(at: elsewhere, for: zone, in: fullField))
    }

    func testANonFiniteOrDegenerateInputHitsNothingInsteadOfGuessing() throws {
        let zone = try zone()
        for broken in [
            CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)
        ] {
            XCTAssertNil(ZoneHandleGeometry.gesture(at: broken, for: zone, in: fullField), "\(broken)")
        }

        let degenerate = LinearScanFieldGeometry(
            fan: FanScreenGeometry(center: .zero, radius: 0, startAngleRadians: 0, endAngleRadians: .pi),
            viewport: .fullField
        )
        XCTAssertNil(ZoneHandleGeometry.gesture(at: .zero, for: zone, in: degenerate))
    }

    /// Die Trefferregel ist **reine Treffergröße** und hat mit der
    /// fachlichen Mindestspanne nichts zu tun (Befund **N7**): Eine
    /// Zone bleibt gültig, egal wie groß der Trefferradius ist.
    func testTheHitRadiusIsATargetSizeAndNotAFactualLimit() throws {
        XCTAssertGreaterThan(ZoneHandleGeometry.handleHitRadius, ZoneHandleGeometry.handleDiameter / 2)

        let tiny = try zone(index: 0.5...(0.5 + ZoneDraft.minimumIndexSpan))
        XCTAssertTrue(
            ZoneHandleGeometry.isVisible(tiny, in: fullField),
            "Eine fachlich gerade noch gültige Zone bleibt sichtbar und bedienbar"
        )
        XCTAssertEqual(ZoneHandleGeometry.placedHandles(for: tiny, in: fullField).count, 4)
    }

    // MARK: - SICK-032b2c-K1: exakte Gegenprobe gegen das dokumentierte False Negative

    /// **Der verbindliche Pflichtnachweis aus `task-sick-032b2c-k1.md`:**
    /// eine Zone mit Winkelanteil `0,11...0,91`, äußerem Radius `1`, in
    /// einem `0,0002` schmalen Viewport um den Bogenpunkt `(0,-1)`
    /// (Winkelanteil `0,5`, `centerY = -0,9999`, `halfExtent = 0,0001`).
    /// Der echte Bogen enthält diesen Punkt und schneidet den Viewport --
    /// die Zone **muss** sichtbar sein.
    ///
    /// **Eine eigene `FanScreenGeometry(size:)`** statt des
    /// dateiweiten `fan` (der hier `0°...180°` öffnet, nicht die
    /// projektweite `180°...360°`) -- die Kardinalwinkelrechnung der
    /// Review-Gegenprobe bezieht sich auf den echten, über `init(size:)`
    /// gebauten Fächer.
    func testTheDocumentedFalseNegativeIsNowCorrectlyVisible() throws {
        let fan = FanScreenGeometry(size: CGSize(width: 800, height: 600))
        let zone = try zone(index: 0.11...0.91, value: 1...8191)
        let viewport = try ScanPlaneViewport.build(centerX: 0, centerY: -0.9999, halfExtent: 0.0001)
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: viewport)

        XCTAssertTrue(
            ZoneHandleGeometry.isVisible(zone, in: geometry),
            "Der Bogen enthält bei Winkelanteil 0,5 den Punkt (0,-1) und schneidet " +
            "den engen Viewport um ihn -- die Zone muss sichtbar sein"
        )
        XCTAssertNotNil(
            ZoneHandleGeometry.gesture(
                at: geometry.project(angleFraction: 0.5, radiusFraction: 1).screenPoint,
                for: zone, in: geometry
            ),
            "Sichtbar heißt auch bedienbar -- dieselbe Bedingung entscheidet beides"
        )
    }

    /// **Gegenprobe:** Eine lokale Nachbildung der bisherigen 16er-
    /// Winkelabtastung scheitert an genau diesem Fall -- ihre lokale
    /// Bogenmitte (Winkelanteil `0,51`) verfehlt das tatsächliche
    /// Extremum bei Winkelanteil `0,5` knapp. Reimplementiert bewusst
    /// lokal in diesem Test statt die inzwischen ersetzte Stichprobe in
    /// `ZoneHandleGeometry` wiederherzustellen -- die **Methode** ist der
    /// Prüfgegenstand, nicht ein längst ersetzter Codepfad.
    func testTheOld16StepSamplingFailsThisSameCase() throws {
        let fan = FanScreenGeometry(size: CGSize(width: 800, height: 600))
        let zone = try zone(index: 0.11...0.91, value: 1...8191)
        let viewport = try ScanPlaneViewport.build(centerX: 0, centerY: -0.9999, halfExtent: 0.0001)
        let geometry = LinearScanFieldGeometry(fan: fan, viewport: viewport)

        func oldIsVisible() -> Bool {
            let innerFraction = Double(zone.valueRange.lowerBound) / PolarProfileGeometry.maxRawMeasurementValue
            let outerFraction = Double(zone.valueRange.upperBound) / PolarProfileGeometry.maxRawMeasurementValue
            let angleLower = zone.indexRange.lowerBound
            let angleUpper = zone.indexRange.upperBound

            var minX = Double.infinity, maxX = -Double.infinity
            var minY = Double.infinity, maxY = -Double.infinity
            let sampleCount = 16
            for step in 0...sampleCount {
                let angle = angleLower + (angleUpper - angleLower) * Double(step) / Double(sampleCount)
                for radius in [innerFraction, outerFraction] {
                    let world = geometry.worldPoint(angleFraction: angle, radiusFraction: radius)
                    minX = Swift.min(minX, Double(world.x)); maxX = Swift.max(maxX, Double(world.x))
                    minY = Swift.min(minY, Double(world.y)); maxY = Swift.max(maxY, Double(world.y))
                }
            }
            let vp = geometry.viewport
            return maxX >= vp.xLowerBound && minX <= vp.xUpperBound
                && maxY >= vp.yLowerBound && minY <= vp.yUpperBound
        }

        XCTAssertFalse(
            oldIsVisible(),
            "Die alte 16er-Abtastung muss an diesem Fall scheitern -- sonst prüft " +
            "testTheDocumentedFalseNegativeIsNowCorrectlyVisible nichts Reales"
        )
        XCTAssertTrue(ZoneHandleGeometry.isVisible(zone, in: geometry), "Die neue Umhüllende bleibt korrekt")
    }
}
