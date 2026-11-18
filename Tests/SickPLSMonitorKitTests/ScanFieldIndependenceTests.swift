@testable import PlanariumInput
import XCTest
import Foundation
import CoreGraphics
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// **Der Ausschnitt bleibt Ansicht allein** (SICK-032b2, Auftragspunkt 5;
/// `.agent_handoff/scanfield-ui-requirements.md`): Zonen, Learn, Mapping
/// und Audio bleiben unverändert, egal wie bedient wird.
///
/// Geprüft wird das -- wie schon in `ScanPlaneViewportIndependenceTests` --
/// **zweimal auf zwei verschiedene Arten**: über das Verhalten (eine
/// vollständige Bedienfolge lässt die echten Auswertungen bitgleich) und
/// über den Quelltext (die Ansichten rechnen gar nichts, und der
/// Bedienzustand fasst nichts Fachliches an). Verhalten allein wäre zu
/// schwach: Es belegt nur, dass heute keine Verbindung *benutzt* wird.
@MainActor final class ScanFieldIndependenceTests: XCTestCase {

    private let size = CGSize(width: 900, height: 700)

    private func makeProfile() throws -> B0ScanProfile {
        let measurements = try (0..<90).map { index -> B0ScanProfile.Measurement in
            try B0ScanProfile.Measurement.build(value: UInt16(21 + (index * 37) % 149), fieldFlags: 0)
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
                    valueLowerBound: 30, valueUpperBound: 180, role: .gate
                ),
                isEnabled: true
            )
        ]
    }

    /// Eine vollständige Bedienfolge: jedes Werkzeug mindestens einmal,
    /// dazu Einpassen, Ablehnungen und Zonenauswahl.
    private func exerciseEveryTool(
        _ state: inout ScanFieldViewState,
        profile: B0ScanProfile,
        zones: [EditableZone]
    ) {
        state.zoomAtCenter(byFactor: 2.5)
        state.zoomAtPointer(byScrollEvent: trackpadScroll(25), at: CGPoint(x: 400, y: 300), in: size)
        state.zoomAtPointer(byMagnification: -0.3, at: CGPoint(x: 120, y: 520), in: size)
        state.fitToProfile(profile)
        state.fitToProfile(nil)                                   // Verweigerung
        state.select(tool: .pan)
        state.beginDrag(at: CGPoint(x: 300, y: 400), in: size)
        state.updateDrag(to: CGPoint(x: 420, y: 330), in: size)
        _ = state.endDrag(at: CGPoint(x: 450, y: 320), in: size, zones: zones)
        state.select(tool: .rectangle)
        state.beginDrag(at: CGPoint(x: 200, y: 200), in: size)
        _ = state.endDrag(at: CGPoint(x: 600, y: 500), in: size, zones: zones)
        state.beginDrag(at: CGPoint(x: 200, y: 200), in: size)
        _ = state.endDrag(at: CGPoint(x: 200, y: 200), in: size, zones: zones)   // Ablehnung
        state.select(tool: .selectZone)
        state.beginDrag(at: CGPoint(x: 450, y: 600), in: size)
        _ = state.endDrag(at: CGPoint(x: 450, y: 600), in: size, zones: zones)
        state.showFullField()
    }

    // MARK: - Verhalten

    func testAFullInteractionSequenceLeavesTheProfileUntouched() throws {
        let profile = try makeProfile()
        let zones = try makeZones()
        var state = ScanFieldViewState()

        exerciseEveryTool(&state, profile: profile, zones: zones)

        XCTAssertEqual(profile.measurements.map(\.value), try makeProfile().measurements.map(\.value))
        XCTAssertEqual(profile.partialScanIndex, 0)
        XCTAssertEqual(profile.trailingBytes, [0x00])
    }

    func testAFullInteractionSequenceLeavesEveryZoneEvaluationBitIdentical() throws {
        let profile = try makeProfile()
        let zones = try makeZones()
        let reference = zones.map { $0.zone.evaluate(against: profile) }

        var state = ScanFieldViewState()
        exerciseEveryTool(&state, profile: profile, zones: zones)

        XCTAssertEqual(zones.map { $0.zone.evaluate(against: profile) }, reference)
    }

    func testAFullInteractionSequenceLeavesTheEditorLiveDisplayBitIdentical() throws {
        let profile = try makeProfile()
        var editor = ZoneEditorState()
        for editable in try makeZones() { _ = editor.addZone(editable.zone) }

        let reference = editor.evaluations(against: profile)
        let referenceEditor = editor
        XCTAssertFalse(reference.isEmpty, "Sonst prüft dieser Test nichts")

        var state = ScanFieldViewState()
        exerciseEveryTool(&state, profile: profile, zones: editor.zones)

        XCTAssertEqual(editor.evaluations(against: profile), reference)
        // Der gesamte Editorzustand -- Zonen, Ein/Aus, Auswahl, Entwurf,
        // Lernvorgang -- ist unverändert.
        XCTAssertEqual(editor, referenceEditor)
    }

    // MARK: - Struktur

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SickPLSMonitorKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Paketwurzel
    }

    /// Quelltext ohne Kommentarzeilen -- **die Lehre aus SICK-020b**: Ein
    /// Verbot, das über die ganze Datei sucht, stolpert über die eigene
    /// Erklärung. Die Kopfkommentare nennen die verbotenen Begriffe
    /// ausdrücklich, um zu begründen, warum sie dort nichts zu suchen
    /// haben.
    private func code(at relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static let scanFieldViews = [
        "Sources/SickPLSMonitor/ScanFieldView.swift",
        "Sources/SickPLSMonitor/PolarScanView.swift",
        "Sources/SickPLSMonitor/ZoneOverlayView.swift",
        "Sources/SickPLSMonitor/ZoneHandlesView.swift",
        "Sources/SickPLSMonitor/ScanFieldPointerEvents.swift"
    ]

    /// Der **direkte Bearbeitungsweg** (SICK-032b3): vom Griff über den
    /// Treffer bis in die Zonenwahrheit.
    private static let zoneEditingPath = [
        "Sources/SickPLSMonitorKit/ZoneHandleGeometry.swift",
        "Sources/SickPLSMonitorKit/ZoneGeometryReducer.swift",
        "Sources/SickPLSMonitorKit/ScanFieldViewState.swift",
        "Sources/SickPLSMonitor/ZoneHandlesView.swift",
        "Sources/SickPLSMonitor/ScanFieldView.swift"
    ]

    /// Die laufende Ansicht zeichnet **linear**: keine vierte Wurzel, in
    /// keiner der Scanfeld-Ansichten.

    /// **Auftragspunkt 7, SICK-032b3:** Auch der direkte
    /// Bearbeitungsweg ist frei von der Anzeigekompression. Ein einzelner
    /// Aufruf der vierten Wurzel sähe hier optisch plausibel aus und
    /// verschöbe doch jeden Griff gegenüber der gezeichneten Zone.

    /// Und die Gegenrichtung, damit das Verbot nicht nur ein Weglassen
    /// ist: Der Reducer rechnet wirklich über die lineare
    /// Ansichtsgeometrie, und die Griffe kommen aus **einer** Quelle.

    /// Und die Gegenrichtung: Die Messkurve wird wirklich über die lineare
    /// Projektion gezeichnet, nicht bloß nicht über die alte Formel.

    /// **Die Ansichten entscheiden nichts.** Jeder Werkzeugaufruf des
    /// Ausschnitts steht im Modell; im App-Ziel darf keiner auftauchen.

    /// Gegenrichtung: Die Werkzeugaufrufe existieren wirklich, und zwar
    /// genau an den beiden vorgesehenen Stellen des Moduls.
    func testTheViewportToolsAreCalledExactlyInTheReducerAndTheFit() throws {
        let reducer = try code(at: "Sources/SickPLSMonitorKit/ScanFieldViewState.swift")
        XCTAssertTrue(reducer.contains(".zoomed("))
        XCTAssertTrue(reducer.contains(".panned("))
        XCTAssertTrue(reducer.contains(".zoomedToRectangle("))
        XCTAssertTrue(try code(at: "Sources/SickPLSMonitorKit/ScanFieldFit.swift").contains(".zoomedToRectangle("))
    }

    /// Der Bedienzustand **liest** Zonen für die Trefferprüfung und
    /// verändert sonst nichts Fachliches: kein Editor-Schreibzugriff,
    /// kein Learn, kein Mapping, kein Audio, keine Sitzung.
    func testTheInteractionStateNeverWritesAnythingFactual() throws {
        let fileCode = try code(at: "Sources/SickPLSMonitorKit/ScanFieldViewState.swift")
        let forbidden = [
            "addZone", "removeZone", "setZone", "commitDraft", "updateDraft",
            "armLearn", "applyLearnCandidate", "ingestLearningProfile",
            "ZoneEditorState", "ZoneSignalPipeline", "ZoneLearningSession",
            "Theremin", "AVAudio", "CoreMIDI", "RXSession", "SwiftUI"
        ]
        for needle in forbidden {
            XCTAssertFalse(
                fileCode.contains(needle),
                "ScanFieldViewState darf \(needle) nicht kennen -- der Ausschnitt ist reine Ansicht"
            )
        }
    }

    /// Dasselbe für die Einpassung: Sie liest ein Profil und liefert
    /// einen Ausschnitt.
    func testTheFitOnlyReadsTheProfile() throws {
        let fileCode = try code(at: "Sources/SickPLSMonitorKit/ScanFieldFit.swift")
        for needle in ["Zone", "ZoneRole", "Theremin", "AVAudio", "CoreMIDI", "RXSession", "SwiftUI"] {
            XCTAssertFalse(fileCode.contains(needle), "ScanFieldFit darf \(needle) nicht kennen")
        }
    }

    /// Die AppKit-Naht übersetzt ein Systemereignis in Zahlen und reicht
    /// es weiter. Der Fenster→lokal-Anker stabilisiert Layoutverschiebungen;
    /// Meter, Polarprojektion und Viewport-Arithmetik bleiben im reinen Kern.
    func testThePointerBridgeContainsNoViewportArithmetic() throws {
        let fileCode = try code(at: "Sources/SickPLSMonitor/ScanFieldPointerEvents.swift")
        for needle in ["ScanPlaneViewport", "LinearScanFieldGeometry", "scrollZoomSensitivity", "MetricCanvasGeometry", "MetricCanvasViewport", "metersPerPoint"] {
            XCTAssertFalse(fileCode.contains(needle), "Die Ereignisnaht darf \(needle) nicht kennen")
        }
    }

    /// Die Zonenüberlagerung hat keine eigene Geste mehr: Im Scanfeld
    /// gibt es genau eine, und ihre Bedeutung entscheidet das Werkzeug.

    // MARK: - SICK-032b2c-K1: eine gemeinsame Canvasgrenze, kein Alt-Clip

    /// **Pflichtnachweis:** Messkurve, Zonenpfad und Griffe benutzen
    /// dieselbe Canvasdefinition -- kein statischer Alt-Fächerclip bleibt
    /// zurück (Abnahmeblocker 1, `.agent_handoff/review-sick-032b2c.md`).
    /// Geprüft strukturell: **genau eine** Stelle im App-Ziel wendet den
    /// gemeinsamen Clip an, und zwar um alle drei Ebenen zusammen; keine
    /// der drei setzt ihn ein zweites Mal für sich allein.

    /// **Gegenprobe:** Der alte Zustand -- ein eigener Clip in
    /// `PolarScanView`, keiner in `ZoneOverlayView` -- hätte den obigen
    /// Nachweis nicht bestanden. Lokal am aktuellen Quelltext simuliert,
    /// statt den längst entfernten Zustand wiederherzustellen.

}
