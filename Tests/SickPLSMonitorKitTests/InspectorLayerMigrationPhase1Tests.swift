import XCTest
import SickPLSControlCore
import SickPLSCore
@testable import SickPLSMonitorKit

@MainActor final class InspectorLayerMigrationPhase1Tests: XCTestCase {
    private let layerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let noteRoutingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let ccRoutingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let cell = PolarMetricGridCell(ring: 3, angularIndex: 7)

    private var noteRouting: SpatialRouting {
        SpatialRouting(
            id: noteRoutingID,
            target: .midiNote(channel: 0),
            program: .chord(notes: [60], velocity: 100, transition: .retrigger)
        )
    }

    private var ccRouting: SpatialRouting {
        SpatialRouting(
            id: ccRoutingID,
            target: .midiCC(channel: 0, controller: 74),
            program: .constant(0.5)
        )
    }

    private func workspace(
        routings: [SpatialRouting],
        polarCellOverrides: [PolarMetricGridCell: [SpatialCellAction]] = [:]
    ) -> SpatialInstrumentWorkspace {
        SpatialInstrumentWorkspace(
            grid: .halfMeter,
            layers: [SpatialInstrumentLayer(
                id: layerID,
                name: "Profil",
                color: .blue,
                isVisible: false,
                isActive: true,
                isLocked: true,
                isSoloed: true,
                polarCells: [cell],
                routings: routings,
                polarCellOverrides: polarCellOverrides
            )]
        )
    }

    private func profile(_ centimeters: [UInt16]) throws -> B0ScanProfile {
        try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: try centimeters.map {
                try B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0)
            }
        )
    }

    func testI1PublicMutationRejectsASecondRoutingOnTheLayer() {
        var workspace = workspace(routings: [noteRouting])

        workspace.updateSelectedLayer { layer in
            layer.routings.append(ccRouting)
        }

        XCTAssertEqual(workspace.layers.count, 1)
        XCTAssertEqual(workspace.selectedLayer.routings, [noteRouting],
                       "Eine Layer-Mutation muss ein zweites Routing ablehnen oder über die erlaubte Ersetzungs-API führen.")
    }

    func testI2OldJSONPresetSplitsTwoRoutingsIntoOrderedLayers() throws {
        let override = SpatialCellAction(
            target: .midiNote(channel: 0), value: .note(number: 64, velocity: 90)
        )
        let oldPreset = try JSONEncoder().encode(
            workspace(routings: [noteRouting, ccRouting], polarCellOverrides: [cell: [override]])
        )
        let loaded = try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: oldPreset)

        XCTAssertEqual(loaded.layers.count, 2)
        XCTAssertEqual(loaded.layers.map(\.routings.count), [1, 1])
        XCTAssertEqual(loaded.layers.map { $0.routings.map(\.target) }, [[.midiNote(channel: 0)], [.midiCC(channel: 0, controller: 74)]])
        XCTAssertEqual(loaded.layers.map(\.polarCells), [[cell], [cell]])
        XCTAssertEqual(loaded.layers.map(\.name), ["Profil", "Profil · 2"])
        XCTAssertEqual(loaded.layers.map(\.color), [.blue, .blue])
        XCTAssertEqual(loaded.layers.map(\.isActive), [true, true])
        XCTAssertEqual(loaded.layers.map(\.isVisible), [false, false])
        XCTAssertEqual(loaded.layers.map(\.isLocked), [true, true])
        XCTAssertEqual(loaded.layers.map(\.isSoloed), [true, true])
        XCTAssertEqual(loaded.layers.map { $0.polarCellOverrides }, [[cell: [override]], [cell: [override]]])
    }


    func testI4SingleRoutingPresetRetainsItsValueAndBytes() throws {
        let oldPreset = try JSONEncoder().encode(workspace(routings: [noteRouting]))
        let loaded = try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: oldPreset)
        let reencoded = try JSONEncoder().encode(loaded)

        XCTAssertEqual(loaded.layers.count, 1)
        XCTAssertEqual(loaded.layers[0].routings, [noteRouting])
        XCTAssertEqual(loaded.layers[0].polarCells, [cell])
        let canonicalOld = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(JSONSerialization.jsonObject(with: oldPreset)),
            options: [.sortedKeys]
        )
        let canonicalNew = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded)),
            options: [.sortedKeys]
        )
        XCTAssertEqual(canonicalNew, canonicalOld)
    }

    func testInspectorOutputDropdownActionIsUndoableWithCommandZDocumentSemantics() {
        let state = CanvasDocumentFixture()
        state.replaceWorkspace(workspace(routings: []))
        state.updateWorkspace(named: "Ziel ändern") { document in
            document.updateSelectedLayer { layer in
                layer.routings = [SpatialRouting(
                    target: .midiNote(channel: 0),
                    program: .constant(0.5)
                )]
            }
        }
        XCTAssertEqual(state.workspace.selectedLayer.routings.first?.target,
                       SpatialRoutingTarget.midiNote(channel: 0))
        XCTAssertTrue(state.undo(), "⌘Z muss die Dropdown-Aktion als Dokumentänderung zurücknehmen")
        XCTAssertTrue(state.workspace.selectedLayer.routings.isEmpty)
    }
}
