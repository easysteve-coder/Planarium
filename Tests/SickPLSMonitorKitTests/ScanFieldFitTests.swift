import XCTest
import CoreGraphics
import SickPLSCore
@testable import SickPLSMonitorKit

/// **Die Antwort auf Auftragspunkt 7** (SICK-032b2): Ein reales
/// 90-Punkt-Profil muss sich **ohne Designannahme** sichtbar einpassen
/// lassen.
///
/// **Seit SICK-032b2c isotrop um den Fächerursprung** (siehe
/// `ScanFieldFit`s Kopfkommentar): Der Nachweis bleibt derselbe -- die
/// tatsächlich gemessenen Rohwerte füllen den sichtbaren Bereich zum
/// größten Teil aus, ohne dass irgendwo eine Entfernungsgrenze festgelegt
/// wurde --, nur die konkrete Rechnung dahinter hat sich geändert.
@MainActor final class ScanFieldFitTests: XCTestCase {

    private let size = CGSize(width: 800, height: 600)

    /// Ein synthetisches 90-Punkt-Profil in der Größenordnung des
    /// einzigen echten Mitschnitts (SICK-012, Rohwerte ≈ 21…169) --
    /// **keine Gerätewahrheit**, nur plausibles Material. Die Endpunkte
    /// 21 und 169 kommen wirklich vor.
    private func makeRealisticProfile() throws -> B0ScanProfile {
        var values: [UInt16] = [21, 169]
        for index in 0..<88 {
            values.append(UInt16(30 + (index * 17) % 130))
        }
        let measurements = try values.map {
            try B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0)
        }
        return try B0ScanProfile.build(
            partialScanIndex: 0, measurements: measurements, trailingBytes: [0x00]
        )
    }

    private func profile(of values: [UInt16]) throws -> B0ScanProfile {
        let measurements = try values.map {
            try B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0)
        }
        return try B0ScanProfile.build(
            partialScanIndex: 0, measurements: measurements, trailingBytes: [0x00]
        )
    }

    // MARK: - Der Kernnachweis

    func testARealisticProfileBecomesClearlyVisibleAfterFitting() throws {
        let profile = try makeRealisticProfile()

        // Ausgangslage: linear gegen die feste 8191er-Grenze füllen die
        // echten Werte ≈ 0,26…2,06 % des Radius -- praktisch unsichtbar,
        // also weit innerhalb der Gesamtansicht (Halbkantenlänge `1`).
        let farFractionBefore = 169.0 / PolarProfileGeometry.maxRawMeasurementValue
        XCTAssertLessThan(farFractionBefore / ScanPlaneViewport.fullField.halfExtent, 0.03, "Sonst belegt dieser Test nichts")

        var state = ScanFieldViewState()
        let outcome = state.fitToProfile(profile)

        guard case .fitted(let result) = outcome else {
            return XCTFail("Einpassen wurde verweigert: \(outcome)")
        }
        XCTAssertEqual(result.usedMeasurementCount, 90)
        XCTAssertEqual(result.ignoredMeasurementCount, 0)
        XCTAssertNil(state.notice)

        // Der am weitesten entfernte brauchbare Messpunkt (169) muss den
        // sichtbaren Bereich jetzt fast ausfüllen -- das ist die
        // Umkehrung des obigen "praktisch unsichtbar".
        let farFractionAfter = 169.0 / PolarProfileGeometry.maxRawMeasurementValue
        XCTAssertGreaterThan(farFractionAfter / state.viewport.halfExtent, 0.85)
        XCTAssertLessThanOrEqual(farFractionAfter / state.viewport.halfExtent, 1.0)
    }

    /// Und jeder einzelne Messpunkt liegt danach wirklich im Bild --
    /// nicht nur die beiden Extremwerte. Das folgt hier sogar
    /// **strukturell**: Jeder brauchbare Punkt hat `radiusFraction <=`
    /// den größten benutzten Rohwert, und genau der bestimmt
    /// ``ScanPlaneViewport/halfExtent``.
    func testEveryMeasurementOfTheProfileLiesInsideTheFittedWindow() throws {
        let profile = try makeRealisticProfile()
        var state = ScanFieldViewState()
        state.fitToProfile(profile)

        let geometry = state.geometry(in: size)
        for point in PolarProfileGeometry.points(for: profile) {
            let projected = geometry.project(
                angleFraction: point.angleFraction, radiusFraction: point.radiusFraction
            )
            XCTAssertTrue(projected.isInsideViewport, "Messpunkt außerhalb: \(point)")
        }
    }

    // MARK: - Verweigerungen, nie Ersatzwerte

    func testFittingWithoutAProfileIsRefusedVisiblyAndChangesNothing() throws {
        var state = ScanFieldViewState()
        state.zoomAtCenter(byFactor: 3)
        let before = state.viewport

        XCTAssertEqual(state.fitToProfile(nil), .refused(.noProfile))
        XCTAssertEqual(state.viewport, before)
        XCTAssertEqual(state.notice, .fitNeedsProfile)
    }

    func testAProfileWithoutAUsableMeasurementIsRefused() throws {
        var state = ScanFieldViewState()
        let before = state.viewport
        let outcome = state.fitToProfile(try profile(of: [0, 8_191, 0, 8_191]))

        XCTAssertEqual(outcome, .refused(.noUsableMeasurement))
        XCTAssertEqual(state.viewport, before)
        XCTAssertEqual(state.notice, .fitFoundNoUsableMeasurement)
    }

    /// `0` und `8191` bleiben außen vor -- dieselbe Gültigkeitsgrenze wie
    /// im Lernvertrag seit SICK-030c. Ein einzelnes „kein Echo" darf die
    /// Einpassung nicht auf das ganze Feld aufziehen.
    func testTheSentinelValuesAreIgnoredAndCountedInsteadOfWideningTheWindow() throws {
        var state = ScanFieldViewState()
        let outcome = state.fitToProfile(try profile(of: [0, 40, 60, 80, 8_191]))

        guard case .fitted(let result) = outcome else {
            return XCTFail("Einpassen wurde verweigert: \(outcome)")
        }
        XCTAssertEqual(result.usedMeasurementCount, 3)
        XCTAssertEqual(result.ignoredMeasurementCount, 2)
        // Der größte **brauchbare** Wert ist 80 (≈ 0,0098 von 8191); mit
        // Rand bleibt die Halbkantenlänge deutlich unter der, die `8191`
        // (der Sentinel) ergäbe -- praktisch die Gesamtansicht (`1`).
        XCTAssertLessThan(state.viewport.halfExtent, 0.02, "Die Randwerte haben den Ausschnitt aufgezogen")
    }

    /// Ein Profil, in dem jeder brauchbare Punkt denselben Rohwert trägt,
    /// hat die Spanne `0` -- der Mindestrand macht daraus trotzdem einen
    /// gültigen Ausschnitt.
    func testAProfileWithASingleDistinctValueStillYieldsAValidWindow() throws {
        var state = ScanFieldViewState()
        let outcome = state.fitToProfile(try profile(of: [100, 100, 100]))

        guard case .fitted = outcome else {
            return XCTFail("Einpassen wurde verweigert: \(outcome)")
        }
        XCTAssertNoThrow(try ScanPlaneViewport.build(
            centerX: state.viewport.centerX,
            centerY: state.viewport.centerY,
            halfExtent: state.viewport.halfExtent
        ))
    }

    // MARK: - Ein absoluter, vom bisherigen Ausschnitt unabhängiger Ausschnitt

    /// **Seit SICK-032b2c bewusst anders als zuvor** (siehe
    /// `ScanFieldFit`s Kopfkommentar): Unter dem isotropen planaren
    /// Ausschnitt lässt sich „nur die Entfernungsachse ändern" nicht mehr
    /// ausdrücken. Einpassen zoomt stattdessen **immer auf den
    /// Fächerursprung zentriert** -- unabhängig davon, welcher
    /// Ausschnitt vorher galt.
    func testFittingAlwaysCentresOnTheOriginRegardlessOfThePreviousViewport() throws {
        var state = ScanFieldViewState()
        // Einen bewusst exzentrischen Ausschnitt herstellen.
        state.select(tool: .rectangle)
        let a = state.geometry(in: size).project(angleFraction: 0.3, radiusFraction: 0.2).screenPoint
        let b = state.geometry(in: size).project(angleFraction: 0.7, radiusFraction: 0.9).screenPoint
        state.beginDrag(at: a, in: size)
        _ = state.endDrag(at: b, in: size, zones: [])
        XCTAssertNotEqual(state.viewport.centerX, 0, accuracy: 1e-9, "Sonst prüft dieser Test nichts")

        state.fitToProfile(try makeRealisticProfile())

        XCTAssertEqual(state.viewport.centerX, 0, accuracy: 1e-12)
        XCTAssertEqual(state.viewport.centerY, 0, accuracy: 1e-12)
    }

    /// Das Einpassen benutzt **alle** Messpunkte des Profils, nicht nur
    /// die im sichtbaren Bereich -- sonst hinge das Ergebnis an zwei
    /// Dingen gleichzeitig. Seit SICK-032b2c ist das Ergebnis sogar
    /// **vollständig unabhängig** vom bisherigen Ausschnitt: derselbe
    /// absolute, ursprungszentrierte Zielausschnitt entsteht immer.
    func testFittingUsesTheWholeProfileRegardlessOfTheVisibleWindow() throws {
        let profile = try makeRealisticProfile()

        var wide = ScanFieldViewState()
        wide.fitToProfile(profile)

        var narrow = ScanFieldViewState()
        narrow.select(tool: .rectangle)
        let a = narrow.geometry(in: size).project(angleFraction: 0.8, radiusFraction: 0.1).screenPoint
        let b = narrow.geometry(in: size).project(angleFraction: 0.95, radiusFraction: 0.9).screenPoint
        narrow.beginDrag(at: a, in: size)
        _ = narrow.endDrag(at: b, in: size, zones: [])
        narrow.fitToProfile(profile)

        XCTAssertEqual(narrow.viewport, wide.viewport)
    }

    // MARK: - Die Rechnung selbst

    func testTheFittedWindowIsTheFarthestMeasurementPlusTheDocumentedMargin() throws {
        let outcome = ScanFieldFit.viewport(
            fitting: try profile(of: [1_000, 2_000]), within: .fullField
        )
        guard case .fitted(let result) = outcome else {
            return XCTFail("Einpassen wurde verweigert: \(outcome)")
        }

        let far = 2_000 / PolarProfileGeometry.maxRawMeasurementValue
        let margin = Swift.max(far * ScanFieldFit.marginFraction, ScanPlaneViewport.minimumHalfExtent)

        XCTAssertEqual(result.viewport.centerX, 0, accuracy: 1e-12)
        XCTAssertEqual(result.viewport.centerY, 0, accuracy: 1e-12)
        XCTAssertEqual(result.viewport.halfExtent, far + margin, accuracy: 1e-12)
    }

    /// Das Einpassen geht durch das bestehende Werkzeug und klammert
    /// deshalb wie dieses aufs Feld.
    func testTheMarginNeverLeavesTheField() throws {
        let outcome = ScanFieldFit.viewport(fitting: try profile(of: [1, 2]), within: .fullField)
        guard case .fitted(let result) = outcome else {
            return XCTFail("Einpassen wurde verweigert: \(outcome)")
        }
        XCTAssertGreaterThanOrEqual(result.viewport.halfExtent, ScanPlaneViewport.minimumHalfExtent)
        XCTAssertLessThanOrEqual(result.viewport.halfExtent, ScanPlaneViewport.maximumHalfExtent)
    }
}
