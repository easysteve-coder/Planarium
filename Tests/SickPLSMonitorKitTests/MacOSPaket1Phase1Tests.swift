import XCTest
import CoreGraphics
@testable import SickPLSMonitorKit

/// macOS-Paket 1a: Gestenabschluss, Esc und erste Löschung.
/// macOS-Paket 1a: Produktionsnaht für Gestenabschluss, Esc und Löschen.
final class MacOSPaket1Phase1Tests: XCTestCase {
    private let canvasSize = CGSize(width: 800, height: 800)

    func testT1DeleteAfterMouseUpLostCommitsTheVisibleGestureSelection() throws {
        let start = CGPoint(x: 390, y: 720)
        let end = CGPoint(x: 430, y: 770)
        let target = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        var state = state(with: [target])

        XCTAssertTrue(state.beginDrag(at: start, canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: end, canvasSize: canvasSize))
        let result = state.applyToSelection(.erase)

        XCTAssertEqual(result, .success(.applied(changedCells: 1)))
        XCTAssertFalse(state.workspace.selectedLayer.polarCells.contains(target))
        XCTAssertFalse(state.isDragging)
    }

    func testT2DeleteAfterNormalDragHasTheExistingEraseResult() throws {
        let start = CGPoint(x: 400, y: 750)
        let target = try XCTUnwrap(cell(at: start))
        var state = state(with: [target])

        XCTAssertTrue(state.beginDrag(at: start, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        XCTAssertEqual(state.selectedPolarCells, [target])

        XCTAssertEqual(state.applyToSelection(.erase), .success(.applied(changedCells: 1)))
        XCTAssertFalse(state.workspace.selectedLayer.polarCells.contains(target))
    }

    func testT3EscapeDuringNewDragRestoresPreviousSelectionAndMouseUpIsInert() {
        let first = CGPoint(x: 400, y: 750)
        let second = CGPoint(x: 600, y: 750)
        var state = state(with: [cell(at: first)!])

        XCTAssertTrue(state.beginDrag(at: first, canvasSize: canvasSize))
        state.endDrag(canvasSize: canvasSize)
        let selectionBeforeNewDrag = state.selectedPolarCells
        XCTAssertFalse(selectionBeforeNewDrag.isEmpty)

        XCTAssertTrue(state.beginDrag(at: second, canvasSize: canvasSize))
        XCTAssertTrue(state.updateDrag(to: CGPoint(x: 630, y: 750), canvasSize: canvasSize))
        XCTAssertNil(state.handleKey(.escape))
        XCTAssertEqual(state.selectedPolarCells, selectionBeforeNewDrag)

        state.endDrag(canvasSize: canvasSize)
        XCTAssertEqual(state.selectedPolarCells, selectionBeforeNewDrag)
    }

    func testT4EscapeWithoutGestureClearsTheSelection() {
        var state = state(with: [cell(at: CGPoint(x: 400, y: 750))!])
        XCTAssertTrue(state.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertFalse(state.selectedPolarCells.isEmpty)

        XCTAssertNil(state.handleKey(.escape))
        XCTAssertTrue(state.selectedPolarCells.isEmpty)
        XCTAssertFalse(state.isDragging)
    }

    func testT5LockedAndEmptySelectionHaveDefinedRejections() throws {
        let point = CGPoint(x: 400, y: 750)
        let target = try XCTUnwrap(cell(at: point))
        var locked = state(with: [target], locked: true)
        XCTAssertTrue(locked.selectCell(atScreenPoint: point, canvasSize: canvasSize))
        XCTAssertEqual(
            locked.applyToSelection(.erase),
            .failure(.emptySelection)
        )

        var empty = MetricCanvasInteractionState(tool: .select)
        XCTAssertEqual(empty.applyToSelection(.erase), .failure(.emptySelection))
    }

    private func state(
        with cells: Set<PolarMetricGridCell>, locked: Bool = false
    ) -> MetricCanvasInteractionState {
        var state = MetricCanvasInteractionState(tool: .select)
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [
            SpatialInstrumentLayer(
                name: "Testebene", color: .orange, isLocked: locked, polarCells: cells
            )
        ]))
        return state
    }

    private func cell(at point: CGPoint) -> PolarMetricGridCell? {
        let geometry = MetricCanvasGeometry(
            size: canvasSize, viewport: MetricCanvasInteractionState().viewport
        )
        guard let metric = geometry.boundedMetricPoint(forScreenPoint: point) else { return nil }
        return PolarMetricGridCell(point: metric, grid: .quarterMeter)
    }
}
