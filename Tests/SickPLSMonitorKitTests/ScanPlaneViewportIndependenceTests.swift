@testable import LegacyPresetTestSupport
@testable import PlanariumInput
import XCTest
import Foundation
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// **Der Kern der Owner-Vorgabe** (SICK-032b1,
/// `.agent_handoff/scanfield-ui-requirements.md`): „Der Viewport ist eine
/// reine Ansichtseinstellung: Er darf Messdaten, Zonen, Learn-Ergebnis,
/// Mapping und Audiosteuerung niemals umrechnen, abschneiden oder
/// verändern."
///
/// Geprüft wird das zweimal, absichtlich auf zwei verschiedene Arten:
///
/// - **Verhalten:** Dieselben echten Auswertungen laufen unter vielen
///   sehr verschiedenen Ausschnitten und liefern **bitgleiche**
///   Ergebnisse.
/// - **Struktur:** Die beiden neuen Dateien enthalten im Quelltext gar
///   keinen Zonen-, Mapping- oder Messbezug und keine nichtlineare
///   Formel. Verhalten allein wäre hier zu schwach -- es belegt nur, dass
///   heute keine Verbindung *benutzt* wird, nicht, dass keine besteht.
@MainActor final class ScanPlaneViewportIndependenceTests: XCTestCase {

    // MARK: - Testmaterial

    /// Ein synthetisches Profil in der Größenordnung des einzigen echten
    /// Mitschnitts (SICK-012, Rohwerte ≈ 21…169) -- **keine
    /// Gerätewahrheit**, nur plausibles Material.
    private func makeProfile(count: Int = 90) throws -> B0ScanProfile {
        let measurements = try (0..<count).map { index -> B0ScanProfile.Measurement in
            let value = UInt16(21 + (index * 37) % 149)
            return try B0ScanProfile.Measurement.build(value: value, fieldFlags: 0)
        }
        return try B0ScanProfile.build(
            partialScanIndex: 0, measurements: measurements, trailingBytes: [0x00]
        )
    }

    private func makeZones() throws -> [EditableZone] {
        [
            EditableZone(
                zone: try Zone.build(
                    indexLowerBound: 0.1, indexUpperBound: 0.4,
                    valueLowerBound: 20, valueUpperBound: 200, role: .pitch
                ),
                isEnabled: true
            ),
            EditableZone(
                zone: try Zone.build(
                    indexLowerBound: 0.45, indexUpperBound: 0.8,
                    valueLowerBound: 30, valueUpperBound: 180, role: .volume
                ),
                isEnabled: true
            ),
            EditableZone(
                zone: try Zone.build(
                    indexLowerBound: 0.6, indexUpperBound: 0.95,
                    valueLowerBound: 25, valueUpperBound: 175, role: .gate
                ),
                isEnabled: true
            )
        ]
    }

    /// Eine breite Auswahl sehr verschiedener Ausschnitte -- von der
    /// Gesamtansicht bis zu einem Fenster, das jede Zone „abschneiden"
    /// würde, wenn der Ausschnitt die Daten je berührte.
    private func makeViewports() throws -> [ScanPlaneViewport] {
        var viewports: [ScanPlaneViewport] = [.fullField]
        viewports.append(try ScanPlaneViewport.build(centerX: 0, centerY: 0, halfExtent: 0.0005))
        viewports.append(try ScanPlaneViewport.build(centerX: 0.85, centerY: -0.85, halfExtent: 0.1))
        viewports.append(try ScanPlaneViewport.build(centerX: -0.3, centerY: 0.4, halfExtent: 0.05))

        // Dazu ein paar, die über die echten Werkzeuge entstanden sind.
        var built = ScanPlaneViewport.fullField
        for step in 0..<6 {
            let change = built.zoomed(
                byFactor: 1.9,
                anchorX: Double(step) / 6 - 0.5,
                anchorY: 0.004 * Double(step + 1)
            )
            guard let next = change.viewport else {
                XCTFail("Werkzeug abgelehnt: \(change)")
                continue
            }
            built = next
            viewports.append(built)
        }
        return viewports
    }

    // MARK: - Verhalten: die Auswertung ändert sich nicht

    /// Der fachliche Zonenvertrag (`SickPLSControlCore.Zone`) liefert
    /// unter jedem Ausschnitt **bitgleich** dasselbe.
    func testZoneEvaluationIsBitIdenticalUnderEveryViewport() throws {
        let profile = try makeProfile()
        let zones = try makeZones()
        let viewports = try makeViewports()

        let reference = zones.map { $0.zone.evaluate(against: profile) }

        for viewport in viewports {
            // Der Ausschnitt steht da, wird benutzt -- und ändert nichts.
            _ = LinearScanFieldGeometry(fan: FanScreenGeometry(size: CGSize(width: 800, height: 600)), viewport: viewport)
            let evaluated = zones.map { $0.zone.evaluate(against: profile) }
            XCTAssertEqual(evaluated, reference, "Ausschnitt \(viewport) hat die Auswertung verändert")
        }
    }

    /// Die Live-Anzeige des Zoneneditors ebenso -- und zwar
    /// einschließlich der Werte, nicht nur der Trefferlage.
    func testTheEditorEvaluationIsBitIdenticalUnderEveryViewport() throws {
        let profile = try makeProfile()
        var editor = ZoneEditorState()
        for editable in try makeZones() {
            // Neue Zonen entstehen deaktiviert (SICK-030b1/D2); die
            // Live-Anzeige bewertet trotzdem **jede** Zone -- genau das
            // macht diesen Test aussagekräftig.
            _ = editor.addZone(editable.zone)
        }

        let reference = editor.evaluations(against: profile)
        XCTAssertFalse(reference.isEmpty, "Sonst prüft dieser Test nichts")

        for viewport in try makeViewports() {
            _ = LinearScanFieldGeometry(fan: FanScreenGeometry(size: CGSize(width: 640, height: 480)), viewport: viewport)
            XCTAssertEqual(editor.evaluations(against: profile), reference)
        }
    }

    // MARK: - Struktur: es gibt gar keine Verbindung

    private func source(of fileName: String) throws -> String {
        let module = ["PolarProfileGeometry.swift", "ScanPlaneViewport.swift"].contains(fileName) ? "PlanariumDomain" : "SickPLSMonitorKit"
        return try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // SickPLSMonitorKitTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // Paketwurzel
                .appendingPathComponent("Sources/\(module)/\(fileName)"),
            encoding: .utf8
        )
    }

    /// Kommentarzeilen entfernen, bevor im Quelltext gesucht wird.
    ///
    /// **Die Lehre aus SICK-020b**: Ein Verbot, das über die ganze Datei
    /// sucht, stolpert über die eigene Erklärung -- die Kopfkommentare
    /// beider Dateien *nennen* die verbotene Formel ausdrücklich, um zu
    /// begründen, warum sie hier nichts zu suchen hat.
    private func code(of fileName: String) throws -> String {
        try source(of: fileName)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static let viewportFiles = ["ScanPlaneViewport.swift", "LinearScanFieldGeometry.swift"]

    /// Keine nichtlineare Formel im **gesamten** Weg Bildschirm ↔ Feld --
    /// im Code, ohne jede Ausnahme.
    ///
    /// **Seit SICK-032b2c-K1 keine Ausnahme mehr** (Abnahmeblocker 1,
    /// `.agent_handoff/review-sick-032b2c.md`): Die vorherige radiale
    /// Randklammerung der Umkehrung (Bildschirm -> Feld) brauchte eine
    /// euklidische Vektorlänge und damit eine Quadratwurzel. Sie ist
    /// durch eine achsenweise Klammerung ersetzt -- der sichtbare
    /// Ausschnitt ist ein Quadrat, kein eingeschriebener Kreis --, die
    /// keine braucht. Die gesamte Datei bleibt deshalb ohne jeden
    /// Sonderfall frei von jeder Quadratwurzel.
    func testNoNonLinearFormulaExistsInTheDrawingPath() throws {
        let forbiddenEverywhere = [
            "displayRadiusFraction(from", "pow(", "log(", "log2(", "log10(", "exp("
        ]
        let squareRootNeedles = ["squareRoot", "sqrt("]

        let viewportCode = try code(of: "ScanPlaneViewport.swift")
        for needle in forbiddenEverywhere + squareRootNeedles {
            XCTAssertFalse(
                viewportCode.contains(needle),
                "ScanPlaneViewport.swift darf \(needle) nicht enthalten -- reine kartesische Arithmetik"
            )
        }

        let geometryCode = try code(of: "LinearScanFieldGeometry.swift")
        for needle in forbiddenEverywhere + squareRootNeedles {
            XCTAssertFalse(
                geometryCode.contains(needle),
                "LinearScanFieldGeometry.swift darf \(needle) nicht enthalten"
            )
        }
    }

    /// Die Gegenrichtung: Die Prüfung oben darf nicht ins Leere laufen.
    func testTheNonLinearRuleWouldActuallyCatchSomething() throws {
        let compressionSource = try source(of: "PolarProfileGeometry.swift")
        XCTAssertTrue(
            compressionSource.contains("squareRoot"),
            "Die alte Kompression existiert weiterhin -- die Regel prüft also etwas Reales"
        )
        for fileName in Self.viewportFiles {
            XCTAssertFalse(try code(of: fileName).isEmpty, "\(fileName) muss Code enthalten")
        }
    }

    /// Kein fachlicher Bezug im Ausschnittsweg: Was der Typ nicht kennt,
    /// kann er nicht umrechnen, abschneiden oder verändern.
    func testTheViewportPathReferencesNothingFactual() throws {
        let forbidden = [
            "Zone", "ZoneRole", "EditableZone", "ZoneDraft",
            "B0ScanProfile", "Measurement", "ScanProfileBatch",
            "Theremin", "MasterLevel", "ThereminParameters",
            "RXSession", "Commissioning", "AVAudio", "CoreMIDI", "SwiftUI"
        ]
        for fileName in Self.viewportFiles {
            let fileCode = try code(of: fileName)
            for needle in forbidden {
                XCTAssertFalse(
                    fileCode.contains(needle),
                    "\(fileName) darf \(needle) nicht kennen -- der Ausschnitt ist reine Ansicht"
                )
            }
        }
    }

    /// ``ScanPlaneViewport`` importiert **gar nichts**. Das ist die
    /// schärfste Form der Trennung: kein Framework, kein Fachmodul, keine
    /// Systemuhr.
    func testTheViewportValueImportsNothingAtAll() throws {
        let viewportCode = try code(of: "ScanPlaneViewport.swift")
        XCTAssertFalse(viewportCode.contains("import "), "ScanPlaneViewport darf nichts importieren")

        // Die Geometrie darf genau eines: CoreGraphics für `CGPoint`.
        let geometryImports = try code(of: "LinearScanFieldGeometry.swift")
            .split(separator: "\n")
            .filter { $0.hasPrefix("import ") }
            .map(String.init)
        XCTAssertEqual(geometryImports, ["import CoreGraphics"])
    }

    /// Und umgekehrt: Der **auswertende** Weg weiß nichts vom Ausschnitt.
    /// Ein Ausschnitt, den eine Zonenauswertung, das Lernen oder der
    /// Empfang liest, wäre genau die Vermischung, die die Owner-Vorgabe
    /// ausschließt.
    ///
    /// **Bewusst enger als in SICK-032b1** (dort standen auch
    /// `ZoneEditorState` und `ZoneGeometryReducer` in dieser Liste):
    /// Seit SICK-032b3 ist die direkte Zonenbearbeitung an die lineare
    /// Ansichtsgeometrie gebunden — sie **muss** wissen, wo ein
    /// Bildschirmpunkt im Feld liegt, sonst könnte man eine Zone nicht
    /// dort anfassen, wo sie gezeichnet ist. Die eigentliche Zusage ist
    /// nicht „kennt den Typ nicht", sondern „ein Ausschnittswechsel
    /// verändert keine Zone"; die steht deshalb als **Verhaltens**test
    /// gleich darunter, nicht mehr als Textsuche.
    func testNoEvaluatingTypeKnowsAboutTheViewport() throws {
        for fileName in [
            "ZoneLearningSession.swift",
            "ZoneDraft.swift", "RXSession.swift", "ScanSessionState.swift"
        ] {
            let fileCode = try (fileName == "RXSession.swift" || fileName == "ScanSessionState.swift" ? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/PlanariumInput/\(fileName)")) : code(of: fileName))
            XCTAssertFalse(
                fileCode.contains("ScanPlaneViewport"),
                "\(fileName) darf den Ausschnitt nicht kennen"
            )
            XCTAssertFalse(
                fileCode.contains("LinearScanFieldGeometry"),
                "\(fileName) darf die Ansichtsgeometrie nicht kennen"
            )
        }
    }

    /// Die Zusage, auf die es ankommt: **Ein Ausschnittswechsel allein
    /// verändert keine Zone** — auch nicht, seit der Bearbeitungsweg die
    /// Ansichtsgeometrie kennt.
    ///
    /// Geprüft wird über die echte Bedienoberfläche des Zustands
    /// (Werkzeuge, Lupe, Einpassen), gegen einen unveränderten
    /// `ZoneEditorState` als Ganzes — nicht gegen einzelne Felder.
    func testChangingTheViewportNeverTouchesTheZoneTruth() throws {
        var editor = ZoneEditorState()
        let id = editor.addZone(try Zone.build(
            indexLowerBound: 0.3, indexUpperBound: 0.7,
            valueLowerBound: 1000, valueUpperBound: 4000, role: .pitch
        ))
        editor.select(id)
        let untouched = editor

        var field = ScanFieldViewState()
        let size = CGSize(width: 800, height: 600)
        let profile = try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: try (0..<90).map { _ in
                try B0ScanProfile.Measurement.build(value: 120, fieldFlags: 0)
            },
            trailingBytes: [0]
        )

        field.zoomAtCenter(byFactor: 3)
        field.zoomAtPointer(byScrollEvent: trackpadScroll(25), at: CGPoint(x: 400, y: 500), in: size)
        field.zoomAtPointer(byMagnification: 0.3, at: CGPoint(x: 380, y: 520), in: size)
        field.fitToProfile(profile)
        field.select(tool: .pan)
        field.beginDrag(at: CGPoint(x: 400, y: 500), in: size)
        field.updateDrag(to: CGPoint(x: 460, y: 460), in: size)
        field.endDrag(at: CGPoint(x: 460, y: 460), in: size, zones: editor.zones)
        field.select(tool: .rectangle)
        field.beginDrag(at: CGPoint(x: 300, y: 400), in: size)
        field.endDrag(at: CGPoint(x: 520, y: 560), in: size, zones: editor.zones)
        field.showFullField()

        XCTAssertEqual(editor, untouched, "Kein Ausschnittswerkzeug darf die Zonenwahrheit anfassen")
    }
}
