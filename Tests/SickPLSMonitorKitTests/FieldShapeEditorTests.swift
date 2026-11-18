import XCTest
import SickPLSCore
import SickPLSControlCore
@testable import SickPLSMonitorKit

/// SICK-033e im Editor: Formwechsel über den Entwurf, Gate bleibt
/// Streifen, Formwechsel verwirft Prognosehistorie, Zellgrenzen sind
/// reine Feldanteile.
final class FieldShapeEditorTests: XCTestCase {

    private func zone(_ role: ZoneRole = .pitch) throws -> Zone {
        try Zone.build(indexLowerBound: 0.2, indexUpperBound: 0.6, valueLowerBound: 1000, valueUpperBound: 3000, role: role)
    }

    private func profile(_ values: [UInt16]) throws -> B0ScanProfile {
        try B0ScanProfile.build(partialScanIndex: 0, measurements: try values.map { try B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0) })
    }

    func testCommittingTheDraftCarriesTheShape() throws {
        var state = ZoneEditorState()
        let id = state.addZone(try zone())
        XCTAssertEqual(state.zones[0].shape, .strip)
        XCTAssertEqual(state.draft?.shape, .strip)

        var draft = try XCTUnwrap(state.draft)
        draft.shape = .fan(try FanCells.counting(sectors: 5))
        state.updateDraft(draft)
        XCTAssertTrue(state.commitDraft())

        XCTAssertEqual(state.zones[0].shape, .fan(try FanCells.counting(sectors: 5)))
        XCTAssertEqual(state.selectedZoneID, id)
        XCTAssertEqual(state.draft?.shape, state.zones[0].shape, "der Entwurf folgt der Zone")
    }

    func testAGateZoneAlwaysEvaluatesAsAStrip() throws {
        var state = ZoneEditorState()
        state.addZone(try zone())
        var draft = try XCTUnwrap(state.draft)
        draft.shape = .grid(try GridCells.counting(columns: 2, rows: 2))
        state.updateDraft(draft)
        XCTAssertTrue(state.commitDraft())

        // Rolle auf Gate: die Form fällt auf Streifen zurück -- sichtbar,
        // im Entwurf und in der Zone.
        var gateDraft = try XCTUnwrap(state.draft)
        gateDraft.role = .gate
        state.updateDraft(gateDraft)
        XCTAssertTrue(state.commitDraft())
        XCTAssertEqual(state.zones[0].shape, .strip)
        XCTAssertEqual(state.draft?.shape, .strip)
        XCTAssertEqual(state.zones[0].field.shape, .strip)

        // Und selbst eine direkt gesetzte Form wirkt bei Gate nicht.
        let forced = EditableZone(zone: try zone(.gate), isEnabled: true, shape: .fan(try FanCells.counting(sectors: 3)))
        XCTAssertEqual(forced.field.shape, .strip)
    }

    func testHandleHitSizeIsAScreenConstantIndependentOfZoom() {
        XCTAssertEqual(ZoneHandleGeometry.handleHitRadius, 14)
        XCTAssertGreaterThan(ZoneHandleGeometry.handleHitRadius, ZoneHandleGeometry.handleDiameter / 2)
    }
}
