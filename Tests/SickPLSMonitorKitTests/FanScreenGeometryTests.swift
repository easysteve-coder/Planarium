import XCTest
import CoreGraphics
@testable import SickPLSMonitorKit

final class FanScreenGeometryTests: XCTestCase {

    private func makeGeometry() -> FanScreenGeometry {
        // Halbkreis, geöffnet nach oben (Mittelwinkel 270°), Radius 100,
        // Mittelpunkt im Ursprung -- einfache Werte für Handnachrechnung.
        FanScreenGeometry(
            center: CGPoint(x: 0, y: 0),
            radius: 100,
            startAngleRadians: 270.0 * .pi / 180 - .pi / 2,
            endAngleRadians: 270.0 * .pi / 180 + .pi / 2
        )
    }

    // MARK: - Geteilte Indexformel (SICK-030b2, Auflage D5)

    func testAngleRadiansMapsTheFractionLinearlyOntoTheOpeningAngle() {
        let fan = makeGeometry()

        XCTAssertEqual(fan.angleRadians(forIndexFraction: 0), fan.startAngleRadians, accuracy: 1e-12)
        XCTAssertEqual(fan.angleRadians(forIndexFraction: 1), fan.endAngleRadians, accuracy: 1e-12)
        XCTAssertEqual(
            fan.angleRadians(forIndexFraction: 0.5),
            (fan.startAngleRadians + fan.endAngleRadians) / 2, accuracy: 1e-12
        )
    }

    /// `screenPoint` **muss** dieselbe Formel benutzen -- sonst läge eine
    /// gezeichnete Zonenfläche neben den Messpunkten desselben Index.
    func testScreenPointUsesExactlyThatAngle() {
        let fan = makeGeometry()

        for fraction in [0.0, 0.17, 0.5, 0.83, 1.0] {
            let point = fan.screenPoint(angleFraction: fraction, displayRadiusFraction: 1)
            let angle = fan.angleRadians(forIndexFraction: fraction)
            XCTAssertEqual(
                Double(point.x), Double(fan.center.x) + Double(fan.radius) * cos(angle),
                accuracy: 1e-9, "Anteil \(fraction)"
            )
            XCTAssertEqual(
                Double(point.y), Double(fan.center.y) + Double(fan.radius) * sin(angle),
                accuracy: 1e-9, "Anteil \(fraction)"
            )
        }
    }

    // MARK: - Konstruktion aus einer Ansichtsgröße (SICK-032b2c-K1)

    /// Seit SICK-032b2c-K1 kein an der Fächerspitze verankerter Platz
    /// mehr (Abnahmeblocker 1, `.agent_handoff/review-sick-032b2c.md`):
    /// `center`/`radius` sind die wirkliche Mitte und Halbausdehnung
    /// eines isotropen, zentrierten Quadrat-Fits -- für eine quadratische
    /// Größe deckungsgleich mit der ganzen Ansicht.
    func testInitFromSizeCentersAndFitsASquareViewExactly() {
        let geometry = FanScreenGeometry(size: CGSize(width: 200, height: 200))

        XCTAssertEqual(geometry.center.x, 100)
        XCTAssertEqual(geometry.center.y, 100)
        XCTAssertEqual(geometry.radius, 100)
    }

    /// Bei einer nicht quadratischen Größe bestimmt die **kürzere** Achse
    /// den Radius, und `center` bleibt die wirkliche Mitte -- keine
    /// Verformung, nur ein gleichmäßiger Letterbox-Rand auf der längeren
    /// Achse (Auftragspunkt 2).
    func testInitFromSizeFitsTheShorterAxisAndStaysCenteredForNonSquareSizes() {
        let wide = FanScreenGeometry(size: CGSize(width: 800, height: 600))
        XCTAssertEqual(wide.center.x, 400)
        XCTAssertEqual(wide.center.y, 300)
        XCTAssertEqual(wide.radius, 300)

        let tall = FanScreenGeometry(size: CGSize(width: 600, height: 800))
        XCTAssertEqual(tall.center.x, 300)
        XCTAssertEqual(tall.center.y, 400)
        XCTAssertEqual(tall.radius, 300)
    }

    // MARK: - Vorwärts-/Rückwärtsrichtung sind exakte Umkehrungen

    func testScreenPointThenFanCoordinateRoundTripsForRepresentativePositions() {
        let geometry = makeGeometry()

        // radius == 0 bewusst ausgenommen: am Mittelpunkt fällt jeder
        // Winkel auf denselben Bildschirmpunkt zusammen, der Winkelanteil
        // ist dort strukturell nicht rekonstruierbar (siehe eigener Test
        // unten für dieses entartete Zentrum).
        for angleFraction: Double in [0.0, 0.25, 0.5, 0.75, 1.0] {
            for displayRadiusFraction: Double in [0.1, 0.5, 1.0] {
                let screenPoint = geometry.screenPoint(angleFraction: angleFraction, displayRadiusFraction: displayRadiusFraction)
                let roundTripped = geometry.fanCoordinate(forScreenPoint: screenPoint)

                XCTAssertEqual(roundTripped.angleFraction, angleFraction, accuracy: 1e-6, "Winkel bei angle=\(angleFraction), radius=\(displayRadiusFraction)")
                XCTAssertEqual(roundTripped.displayRadiusFraction, displayRadiusFraction, accuracy: 1e-6, "Radius bei angle=\(angleFraction), radius=\(displayRadiusFraction)")
            }
        }
    }

    func testFanCoordinateAtCenterIsZeroRadiusAndAStableInRangeAngle() {
        let geometry = makeGeometry()

        let coordinate = geometry.fanCoordinate(forScreenPoint: geometry.center)

        XCTAssertEqual(coordinate.displayRadiusFraction, 0.0)
        XCTAssertGreaterThanOrEqual(coordinate.angleFraction, 0.0)
        XCTAssertLessThanOrEqual(coordinate.angleFraction, 1.0)
    }

    // MARK: - Gesten außerhalb des gezeichneten Fächers werden geklammert, nicht abgelehnt

    func testFanCoordinateForPointBelowTheFanClampsIntoRangeInsteadOfLoopingOrCrashing() {
        let geometry = makeGeometry()

        // Gerade nach unten vom Mittelpunkt: außerhalb des nach oben
        // geöffneten Halbkreises.
        let belowCenter = CGPoint(x: geometry.center.x, y: geometry.center.y + 50)

        let coordinate = geometry.fanCoordinate(forScreenPoint: belowCenter)

        XCTAssertGreaterThanOrEqual(coordinate.angleFraction, 0.0)
        XCTAssertLessThanOrEqual(coordinate.angleFraction, 1.0)
        XCTAssertGreaterThanOrEqual(coordinate.displayRadiusFraction, 0.0)
        XCTAssertLessThanOrEqual(coordinate.displayRadiusFraction, 1.0)
    }

    func testFanCoordinateForPointFarBeyondTheRadiusClampsDisplayRadiusFractionToOne() {
        let geometry = makeGeometry()

        let farPoint = CGPoint(x: geometry.center.x, y: geometry.center.y - 10_000)

        let coordinate = geometry.fanCoordinate(forScreenPoint: farPoint)

        XCTAssertEqual(coordinate.displayRadiusFraction, 1.0)
    }

    func testFanCoordinateWithDegenerateZeroRadiusDoesNotDivideByZero() {
        let geometry = FanScreenGeometry(center: .zero, radius: 0, startAngleRadians: 0, endAngleRadians: .pi)

        let coordinate = geometry.fanCoordinate(forScreenPoint: CGPoint(x: 5, y: 5))

        XCTAssertEqual(coordinate.displayRadiusFraction, 0.0)
        XCTAssertGreaterThanOrEqual(coordinate.angleFraction, 0.0)
        XCTAssertLessThanOrEqual(coordinate.angleFraction, 1.0)
    }
}
