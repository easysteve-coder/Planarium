import XCTest
import PlanariumDomain
@testable import SickPLSMonitorKit

/// EDITOR-ANFASSER: Die Griffe einer Mehrfachauswahl auf dem feinen Raster
/// dürfen nicht an der Größe einer einzelnen Zelle hängen. Alle Fälle laufen
/// über denselben Trefferweg wie die App (`selectionHandle`, `beginDrag`,
/// `selectAll`-Auswahl) – kein Test baut eigene Geometrie nach.
@MainActor final class SelectionHandleToleranceTests: XCTestCase {
    let size = CGSize(width: 800, height: 800)
    let grid = MetricSquareGrid.fiveCentimeter

    /// Zwei Ebenen mit demselben 10-Ringe-Block (≈ 50 cm × 68 cm).
    func multiSelection(viewport: MetricCanvasViewport = .instrumentDefault) -> CanvasDocumentFixture {
        var cells: Set<PolarMetricGridCell> = []
        for ring in 8..<18 {
            for bearing in stride(from: -30.0, through: 30, by: 3) {
                let radius = (Double(ring) + 0.5) * grid.cellSizeMeters
                cells.insert(.init(point: .init(xMeters: sin(bearing * .pi / 180) * radius,
                    yMeters: cos(bearing * .pi / 180) * radius), grid: grid))
            }
        }
        let state = CanvasDocumentFixture(viewport: viewport)
        state.replaceWorkspace(.init(grid: grid, layers: [
            .init(name: "A", color: .orange, polarCells: cells),
            .init(name: "B", color: .blue, polarCells: cells)]))
        _ = state.perform(.selectAll)
        return state
    }

    func handlePoint(_ handle: CanvasSelectionHandle, _ state: CanvasDocumentFixture) throws -> CGPoint {
        try XCTUnwrap(state.presentation.selectionHandleCenter(handle, canvasSize: size))
    }

    /// Griffe sitzen außen am Rahmen: die Mitte jeder markierten Zelle – auch
    /// der äußersten – bleibt Verschiebefläche (alter Vertrag, Fabrikauswahl).
    func testCentreOfEverySelectedCellStaysMoveAreaAndHandlesLieOutsideTheFrame() throws {
        let state = multiSelection()
        let geometry = state.displayGeometry(canvasSize: size)
        for cell in state.selectedPolarCells {
            let segment = PolarMetricCellSegment(cell: cell, grid: grid)
            let p = geometry.screenPoint(for: segment.point(radiusMeters: segment.midpoint.radiusMeters, bearingDegrees: segment.midpoint.bearingDegrees))
            XCTAssertNil(state.selectionHandle(at: p, canvasSize: size), "\(cell)")
        }
        let bounds = try XCTUnwrap(state.selectionBounds)
        for handle in CanvasSelectionHandle.allCases {
            let frame = geometry.screenPoint(for: handle.point(in: bounds))
            XCTAssertEqual(state.selectionHandle(at: frame, canvasSize: size), handle, "frame point of \(handle) still hits")
        }
    }

    /// Der Punkt liegt in der Trefferfläche des Griffs. Nur wo sich die
    /// Flächen benachbarter Griffe nicht überlappen, entscheidet nicht der
    /// nächste Mittelpunkt, sondern der Griff selbst.
    func assertGrabs(_ handle: CanvasSelectionHandle, at p: CGPoint, _ state: CanvasDocumentFixture, _ note: String,
                     strict: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = try XCTUnwrap(state.presentation.selectionHandleLayout(canvasSize: size))
        let own = try XCTUnwrap(layout.centers.first { $0.handle == handle }).point
        XCTAssertTrue(layout.hits(p, center: own), note, file: file, line: line)
        if strict { XCTAssertEqual(state.selectionHandle(at: p, canvasSize: size), handle, note, file: file, line: line) }
        else { XCTAssertNotNil(state.selectionHandle(at: p, canvasSize: size), note, file: file, line: line) }
    }

    func viewport(metersPerPoint: Double, centerX: Double = 0, centerY: Double = 4) throws -> MetricCanvasViewport {
        try MetricCanvasViewport.build(centerXMeters: centerX, centerYMeters: centerY, metersPerPoint: metersPerPoint)
    }

    /// Ursache: bei 0,01 m/pt ist eine 5-cm-Zelle 5 pt groß; das alte Maß
    /// `min(cell, …) / scale / 2` ergab ein 2,5-pt-Quadrat (Trefferradius
    /// 1,25 pt) – auch für eine 50 cm große Mehrfachauswahl.
    func testMultiSelectionHandlesAreGrabbableNextToTheVisibleHandle() throws {
        for mpp in [0.01, 0.006, 0.02] {
            let state = multiSelection(viewport: try viewport(metersPerPoint: mpp, centerY: 0.65))
            XCTAssertGreaterThanOrEqual(state.presentation.selectionHandleSize(canvasSize: size), 8, "m/pt \(mpp): sichtbarer Griff")
            for handle in CanvasSelectionHandle.allCases {
                let center = try handlePoint(handle, state)
                for (dx, dy) in [(0.0, 0.0), (5, 0), (-5, 0), (0, 5), (0, -5), (4, 4), (-4, -4)] {
                    let p = CGPoint(x: center.x + dx, y: center.y + dy)
                    XCTAssertEqual(state.selectionHandle(at: p, canvasSize: size), handle, "\(handle) m/pt \(mpp) Δ(\(dx),\(dy))")
                }
            }
        }
    }

    /// Treffertoleranz reicht über den gezeichneten 16-pt-Griff hinaus, aber
    /// nicht weiter als 10 pt.
    func testToleranceExtendsBeyondDrawnHandleButIsBounded() throws {
        let state = multiSelection()
        XCTAssertEqual(state.presentation.selectionHandleSize(canvasSize: size), 16)
        for handle in CanvasSelectionHandle.allCases {
            let c = try handlePoint(handle, state)
            XCTAssertEqual(state.selectionHandle(at: .init(x: c.x + 7, y: c.y - 7), canvasSize: size), handle, "\(handle)")
            XCTAssertNotEqual(state.selectionHandle(at: .init(x: c.x + 11, y: c.y), canvasSize: size), handle, "\(handle)")
        }
    }

    func testResizeStartsKnappNebenDemGriffUndEndetAlsEinUndoSchritt() throws {
        let state = multiSelection()
        let before = state.workspace, depth = state.undoDepth
        let center = try handlePoint(.outerEnd, state)
        let down = CGPoint(x: center.x + 5, y: center.y - 5)
        XCTAssertTrue(state.beginDrag(at: down, canvasSize: size))
        XCTAssertEqual(state.gesture.phase, .armed)
        XCTAssertTrue(state.updateDrag(to: .init(x: down.x + 20, y: down.y - 20), canvasSize: size))
        XCTAssertEqual(state.gesture.phase, .resizing(.outerEnd))
        let preview = state.movePreviewCells
        XCTAssertGreaterThan(preview.count, state.selectedPolarCells.count)
        XCTAssertTrue(state.updateDrag(to: .init(x: down.x + 40, y: down.y - 40), canvasSize: size))
        state.endDrag(canvasSize: size)
        XCTAssertNotEqual(state.workspace, before)
        XCTAssertEqual(state.undoDepth, depth + 1)
        XCTAssertEqual(Set(state.selectedCells.map(\.layerID)).count, 2)
        XCTAssertTrue(state.undo()); XCTAssertEqual(state.workspace, before)
    }

    func testEscapeDiscardsResizePreview() throws {
        let state = multiSelection()
        let before = state.workspace, selection = state.selectedCells, depth = state.undoDepth
        let down = try handlePoint(.outer, state)
        _ = state.beginDrag(at: down, canvasSize: size)
        _ = state.updateDrag(to: .init(x: down.x, y: down.y - 30), canvasSize: size)
        XCTAssertFalse(state.movePreviewCells.isEmpty)
        _ = state.handleKey(.escape)
        XCTAssertEqual(state.gesture.phase, .idle)
        XCTAssertTrue(state.movePreviewCells.isEmpty)
        XCTAssertEqual(state.workspace, before); XCTAssertEqual(state.selectedCells, selection)
        XCTAssertEqual(state.undoDepth, depth)
    }

    /// Das Innere der Auswahl bleibt Verschiebefläche, nicht Griff.
    func testSelectionInteriorStillMovesAndFarOutsideStartsRectangle() throws {
        let state = multiSelection()
        let geometry = state.displayGeometry(canvasSize: size)
        let bounds = try XCTUnwrap(state.selectionBounds)
        let middle = geometry.screenPoint(for: bounds.point(radiusMeters: bounds.midpoint.radiusMeters, bearingDegrees: bounds.midpoint.bearingDegrees))
        XCTAssertNil(state.selectionHandle(at: middle, canvasSize: size))
        _ = state.beginDrag(at: middle, canvasSize: size)
        _ = state.updateDrag(to: .init(x: middle.x + 20, y: middle.y), canvasSize: size)
        XCTAssertEqual(state.gesture.phase, .moving)
        _ = state.handleKey(.escape)
        let outer = try handlePoint(.outer, state)
        XCTAssertNil(state.selectionHandle(at: .init(x: outer.x, y: outer.y - 14), canvasSize: size))
    }

    /// Eine einzelne 5-cm-Zelle (5 pt) behält ihre bedienbare Mitte.
    func testSingleFineCellKeepsDraggableCentre() throws {
        let state = multiSelection()
        let cell = try XCTUnwrap(state.selectedPolarCells.first)
        let one = CanvasDocumentFixture()
        one.replaceWorkspace(.init(grid: grid, layers: [.init(name: "A", color: .orange, polarCells: [cell])]))
        _ = one.perform(.selectAll)
        XCTAssertLessThanOrEqual(one.presentation.selectionHandleSize(canvasSize: size), 2.6)
        let bounds = try XCTUnwrap(one.selectionBounds)
        let centre = one.displayGeometry(canvasSize: size).screenPoint(for:
            bounds.point(radiusMeters: bounds.midpoint.radiusMeters, bearingDegrees: bounds.midpoint.bearingDegrees))
        XCTAssertNil(one.selectionHandle(at: centre, canvasSize: size))
    }

    /// Zweiter Fehlerweg: Der zweite Klick eines schnellen Doppelklicks auf
    /// einen Griff darf nicht als „Insel wählen“ die Auswahl ersetzen.
    func testDoubleClickOnHandleKeepsSelection() throws {
        for clickSelectsArea in [false, true] {
            let state = multiSelection()
            state.session.perform { $0.clickSelectsArea = clickSelectsArea }
            let selection = state.selectedCells
            let p = try handlePoint(.outerStart, state)
            XCTAssertFalse(state.session.selectDoubleClick(at: p, canvasSize: size))
            XCTAssertEqual(state.selectedCells, selection)
        }
    }

    /// Review 22.10.: Der sichtbare Griff ist ein Quadrat; auch seine Ecken
    /// (Abstand > Trefferradius des Kreises) müssen greifen.
    func testEveryPointOfTheVisibleSquareHandleGrabs() throws {
        for mpp in [0.01, 0.006, 0.02] {
            // Auswahl mittig im Bild, damit nur der Zoom und kein Rand wirkt.
            let state = multiSelection(viewport: try viewport(metersPerPoint: mpp, centerY: 0.65))
            let half = state.presentation.selectionHandleSize(canvasSize: size) / 2 - 0.01
            for handle in CanvasSelectionHandle.allCases {
                let c = try handlePoint(handle, state)
                for (sx, sy) in [(1.0, 1.0), (1, -1), (-1, 1), (-1, -1), (1, 0), (0, -1)] {
                    let p = CGPoint(x: c.x + sx * half, y: c.y + sy * half)
                    try assertGrabs(handle, at: p, state, "\(handle) m/pt \(mpp) Ecke(\(sx),\(sy))", strict: mpp <= 0.01)
                }
            }
        }
    }

    /// Auswahl am sichtbaren Rand (Pan links/rechts/oben/unten): jeder Griff
    /// liegt voll im Canvas, greift in Mitte und Quadratecke, und das
    /// Vergrößern beginnt dort als eine Geste.
    func testHandlesStayReachableForSelectionAtEveryCanvasEdge() throws {
        let rect = CGRect(origin: .zero, size: size)
        // Bildschirm-y wächst nach unten: cy = -3.3 schiebt die Auswahl an den oberen Rand.
        let pans: [(String, Double, Double)] = [("links", 3.95, 0.65), ("rechts", -3.95, 0.65), ("oben", 0, -3.3), ("unten", 0, 4.45),
                                                ("links-oben", 3.95, -3.3), ("rechts-unten", -3.95, 4.45)]
        for (name, cx, cy) in pans {
            let state = multiSelection(viewport: try viewport(metersPerPoint: 0.01, centerX: cx, centerY: cy))
            let half = state.presentation.selectionHandleSize(canvasSize: size) / 2 - 0.01
            for handle in CanvasSelectionHandle.allCases {
                let c = try handlePoint(handle, state)
                XCTAssertTrue(rect.insetBy(dx: half, dy: half).contains(c), "\(name) \(handle) \(c) liegt nicht voll im Canvas")
                try assertGrabs(handle, at: c, state, "\(name) \(handle) Mitte", strict: false)
                try assertGrabs(handle, at: CGPoint(x: c.x + half, y: c.y + half), state, "\(name) \(handle) Ecke", strict: false)
            }
            // Beginn der Vergrößerung an einem randnahen Griff: eine Geste, ein Undo-Schritt.
            let before = state.workspace, depth = state.undoDepth
            let intended: CanvasSelectionHandle = name.contains("links") ? .outerStart : .outerEnd
            let down = try handlePoint(intended, state)
            // Wo Griffe am Rand zusammenrücken (Ecken), entscheidet der nächste Mittelpunkt.
            let handle = try XCTUnwrap(state.selectionHandle(at: down, canvasSize: size), name)
            if !name.contains("-") { XCTAssertEqual(handle, intended, name) }
            XCTAssertTrue(state.beginDrag(at: down, canvasSize: size), name)
            _ = state.updateDrag(to: .init(x: down.x + 1, y: down.y - 12), canvasSize: size)
            XCTAssertEqual(state.gesture.phase, .resizing(handle), name)
            _ = state.updateDrag(to: .init(x: down.x + 1, y: down.y - 30), canvasSize: size)
            state.endDrag(canvasSize: size)
            if state.workspace != before { XCTAssertEqual(state.undoDepth, depth + 1, name); XCTAssertTrue(state.undo()) }
            XCTAssertEqual(state.workspace, before, name)
        }
    }

    /// Feldrand: Ursprung und ±90°. Die Griffe liegen dort an definierten,
    /// endlichen Punkten, und die Mitte einer Zelle wird nie zum Griff.
    func testHandlesAtOriginAndAtNinetyDegreesStayFiniteAndLeaveCellCentresMovable() throws {
        for (rings, bearings) in [(0..<3, stride(from: -90.0, through: -75, by: 3).map { $0 }), (0..<4, stride(from: 75.0, through: 90, by: 3).map { $0 })] {
            var cells: Set<PolarMetricGridCell> = []
            for ring in rings { for bearing in bearings {
                let radius = (Double(ring) + 0.5) * grid.cellSizeMeters
                cells.insert(.init(point: .init(xMeters: sin(bearing * .pi / 180) * radius, yMeters: cos(bearing * .pi / 180) * radius), grid: grid))
            } }
            let state = CanvasDocumentFixture(viewport: try viewport(metersPerPoint: 0.004, centerX: 0, centerY: 0.5))
            state.replaceWorkspace(.init(grid: grid, layers: [.init(name: "A", color: .orange, polarCells: cells)]))
            _ = state.perform(.selectAll)
            let geometry = state.displayGeometry(canvasSize: size)
            for handle in CanvasSelectionHandle.allCases {
                let c = try handlePoint(handle, state)
                XCTAssertTrue(c.x.isFinite && c.y.isFinite, "\(handle)")
                try assertGrabs(handle, at: c, state, "\(handle)", strict: false)
            }
            let bounds = try XCTUnwrap(state.selectionBounds)
            let layout = try XCTUnwrap(state.presentation.selectionHandleLayout(canvasSize: size))
            for cell in state.selectedPolarCells {
                let segment = PolarMetricCellSegment(cell: cell, grid: grid)
                let p = geometry.screenPoint(for: segment.point(radiusMeters: segment.midpoint.radiusMeters, bearingDegrees: segment.midpoint.bearingDegrees))
                // Mitten innerhalb der Rahmenmitte bleiben frei, sofern der Griff sie nicht ohnehin überdeckt.
                if layout.centers.allSatisfy({ !layout.hits(p, center: $0.point) }) { XCTAssertNil(state.selectionHandle(at: p, canvasSize: size)) }
            }
            XCTAssertGreaterThan(bounds.endBearingDegrees, bounds.startBearingDegrees)
        }
    }
}
