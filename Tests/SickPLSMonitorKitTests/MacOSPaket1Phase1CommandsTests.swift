import XCTest
import CoreGraphics
import Foundation
import SickPLSControlCore
import SickPLSCore
@testable import SickPLSMonitorKit

/// macOS-Paket 1c: Fokusabhängige Editorbefehle und Ansichtsmenü.
/// Die Befehlsnaht ist in Phase 1 absichtlich noch nicht im Produktstand.
@MainActor final class MacOSPaket1Phase1CommandsTests: XCTestCase {
    private let canvasSize = CGSize(width: 800, height: 800)
    private let target = SpatialRoutingTarget.midiNote(channel: 1)
    private let layerID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    private let routingID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!

    func testC1CommandEnablementUsesPureIsEnabledQuery() throws {
        let empty = state(with: [])
        XCTAssertFalse(empty.isEnabled(.delete))
        XCTAssertFalse(empty.isEnabled(.selectAll))

        let pan = CanvasDocumentFixture(tool: .pan)
        XCTAssertFalse(pan.isEnabled(.selectAll))

        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let resting = state(with: [], overrides: [cell: [action]])
        XCTAssertFalse(resting.isEnabled(.selectAll))

        let selected = state(with: [cell])
        XCTAssertTrue(selected.selectCell(atScreenPoint: CGPoint(x: 400, y: 750), canvasSize: canvasSize))
        XCTAssertTrue(selected.isEnabled(.delete))
    }

    func testC2SelectAllUsesTheSameCommandPathAndExcludesDormantOverrides() throws {
        let cell = try XCTUnwrap(cell(at: CGPoint(x: 400, y: 750)))
        let state = state(with: [], overrides: [cell: [action]])

        XCTAssertFalse(state.perform(.selectAll))
        XCTAssertFalse(state.selectedPolarCells.contains(cell))
    }

    // Native UI behavior is covered by CanvasWindowContractTests.

    func testC4ViewCommandsUsePerformWithoutDocumentHistory() throws {
        let state = state(with: [])
        let before = state.viewport
        XCTAssertTrue(state.perform(.zoomIn, canvasSize: canvasSize))
        XCTAssertNotEqual(state.viewport, before)
        XCTAssertEqual(state.undoDepth, 0)

        XCTAssertTrue(state.perform(.resetView))
        XCTAssertEqual(state.viewport, CanvasDocumentFixture().viewport)
        XCTAssertFalse(state.isEnabled(.zoomToMeasurement, canvasSize: canvasSize))
    }

    private var action: SpatialCellAction {
        SpatialCellAction(target: target, value: .note(number: 60, velocity: 100))
    }

    /// MacBook-Tastaturen haben keine Entf-Taste: ⌫ muss im fokussierten
    /// Messfeld Zellen löschen, über denselben Befehlsweg.
    // Native UI behavior is covered by CanvasWindowContractTests.

    private func state(
        with cells: Set<PolarMetricGridCell>,
        overrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
    ) -> CanvasDocumentFixture {
        let state = CanvasDocumentFixture(tool: .select)
        state.replaceWorkspace(SpatialInstrumentWorkspace(layers: [
            SpatialInstrumentLayer(
                id: layerID,
                name: "Befehls-Testebene", color: .orange,
                polarCells: cells,
                routings: [SpatialRouting(id: routingID, target: target, program: .constant(0.5))],
                polarCellOverrides: overrides
            )
        ]))
        return state
    }

    private func cell(at point: CGPoint) -> PolarMetricGridCell? {
        let geometry = MetricCanvasGeometry(
            size: canvasSize, viewport: CanvasDocumentFixture().viewport
        )
        guard let metric = geometry.boundedMetricPoint(forScreenPoint: point) else { return nil }
        return PolarMetricGridCell(point: metric, grid: .quarterMeter)
    }
}
