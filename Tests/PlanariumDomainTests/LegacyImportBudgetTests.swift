import Foundation
import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class LegacyImportBudgetTests: XCTestCase {
    private let selected = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let a60 = SpatialCellAction(
        target: .midiNote(channel: 0),
        value: .note(number: 60, velocity: 100)
    )

    func testInputSizeIsRejectedBeforeJSONSerialization() throws {
        let budget = SpatialDocumentBudget(
            inputBytes: 3, layers: 256, addressesPerLayer: 262_144,
            addressesPerDocument: 1_048_576, actionAssignments: 1_048_576,
            noteEntries: 1_048_576
        )
        let result = CompatibilityImporter.read(
            Data("not-json".utf8), context: nil, budget: budget
        )
        XCTAssertEqual(result, .failure(.budgetExceeded(.inputBytes)))
    }

    func testInputSizeBoundaryIsAcceptedAndBoundaryPlusOneIsRejected() throws {
        let data = try legacyRoot()
        let exact = budget(inputBytes: data.count)
        XCTAssertTrue(CompatibilityImporter.read(data, context: nil, budget: exact).isSuccess)
        XCTAssertEqual(
            CompatibilityImporter.read(data, context: nil, budget: budget(inputBytes: data.count - 1)),
            .failure(.budgetExceeded(.inputBytes))
        )
    }

    func testLayerBoundariesAreCheckedByBothImporters() throws {
        let data = try legacyRoot()
        let source = try XCTUnwrap(CompatibilityImporter.read(data).successValue)
        XCTAssertTrue(CompatibilityImporter.read(data, context: nil, budget: budget(layers: 1)).isSuccess)
        XCTAssertEqual(
            CompatibilityImporter.read(data, context: nil, budget: budget(layers: 0)),
            .failure(.budgetExceeded(.layers))
        )
        XCTAssertTrue(SpatialDocumentImporter.document(from: source, budget: budget(layers: 1)).isSuccess)
        XCTAssertEqual(
            SpatialDocumentImporter.document(from: source, budget: budget(layers: 0)),
            .failure(.budgetExceeded(.layers))
        )
    }

    func testAddressLayerBoundariesAreCheckedByBothImporters() throws {
        let data = try legacyRoot()
        let source = try XCTUnwrap(CompatibilityImporter.read(data).successValue)
        XCTAssertTrue(CompatibilityImporter.read(data, context: nil, budget: budget(addressesPerLayer: 2_250)).isSuccess)
        XCTAssertEqual(
            CompatibilityImporter.read(data, context: nil, budget: budget(addressesPerLayer: 2_249)),
            .failure(.budgetExceeded(.addressesPerLayer))
        )
        XCTAssertTrue(SpatialDocumentImporter.document(from: source, budget: budget(addressesPerLayer: 2_250)).isSuccess)
        XCTAssertEqual(
            SpatialDocumentImporter.document(from: source, budget: budget(addressesPerLayer: 2_249)),
            .failure(.budgetExceeded(.addressesPerLayer))
        )
    }

    func testActionAssignmentsAreCheckedBeforeLegacyOverrideCopy() throws {
        let oneAction = try legacyRoot(actionCount: 1)
        let exact = budget(actionAssignments: 2_250)
        let justUnder = budget(actionAssignments: 2_249)

        XCTAssertTrue(CompatibilityImporter.read(oneAction, context: nil, budget: exact).isSuccess)
        XCTAssertEqual(
            CompatibilityImporter.read(oneAction, context: nil, budget: justUnder),
            .failure(.budgetExceeded(.actionAssignments))
        )
    }

    func testNoteEntriesAreCheckedAcrossEveryMigratedTarget() throws {
        let chord = SpatialCellAction(
            target: .midiNote(channel: 0),
            value: .chord(notes: [60, 62], velocity: 100)
        )
        let data = try legacyRoot(actions: [chord])
        let exact = budget(noteEntries: 4_500)
        let justOver = budget(noteEntries: 4_499)

        XCTAssertTrue(CompatibilityImporter.read(data, context: nil, budget: exact).isSuccess)
        XCTAssertEqual(
            CompatibilityImporter.read(data, context: nil, budget: justOver),
            .failure(.budgetExceeded(.noteEntries))
        )
    }

    func testSpatialImporterActionAssignmentBoundaryUsesSameInput() throws {
        let data = try legacyRoot(actionCount: 1)
        let source = try XCTUnwrap(CompatibilityImporter.read(data).successValue)
        XCTAssertTrue(SpatialDocumentImporter.document(
            from: source, budget: budget(actionAssignments: 2_250)
        ).isSuccess)
        XCTAssertEqual(
            SpatialDocumentImporter.document(
                from: source, budget: budget(actionAssignments: 2_249)
            ),
            .failure(.budgetExceeded(.actionAssignments))
        )
    }

    func testSpatialImporterNoteEntryBoundaryUsesSameInput() throws {
        let chord = SpatialCellAction(
            target: .midiNote(channel: 0),
            value: .chord(notes: [60, 62], velocity: 100)
        )
        let data = try legacyRoot(actions: [chord])
        let source = try XCTUnwrap(CompatibilityImporter.read(data).successValue)
        XCTAssertTrue(SpatialDocumentImporter.document(
            from: source, budget: budget(noteEntries: 4_500)
        ).isSuccess)
        XCTAssertEqual(
            SpatialDocumentImporter.document(
                from: source, budget: budget(noteEntries: 4_499)
            ),
            .failure(.budgetExceeded(.noteEntries))
        )
    }

    func testRoutingBudgetBoundaryIsSharedByCompatibilityAndSpatialImporter() throws {
        let routing = SpatialRouting(target: .midiNote(channel: 0), program: .constant(1))
        let data = try legacyRoot(actions: [], routings: [routing, routing])
        let source = try XCTUnwrap(CompatibilityImporter.read(data).successValue)
        let exact = budget(routings: 2)
        let justUnder = budget(routings: 1)

        XCTAssertTrue(CompatibilityImporter.read(data, context: nil, budget: exact).isSuccess)
        XCTAssertEqual(
            CompatibilityImporter.read(data, context: nil, budget: justUnder),
            .failure(.budgetExceeded(.routings))
        )
        XCTAssertTrue(SpatialDocumentImporter.document(from: source, budget: exact).isSuccess)
        XCTAssertEqual(
            SpatialDocumentImporter.document(from: source, budget: justUnder),
            .failure(.budgetExceeded(.routings))
        )
    }

    func testCompatibilityAddressDocumentBoundaryUsesSameInput() throws {
        let data = try legacyRoot()
        let exact = budget(addressesPerDocument: 2_250)
        XCTAssertTrue(CompatibilityImporter.read(data, context: nil, budget: exact).isSuccess)
        XCTAssertEqual(
            CompatibilityImporter.read(data, context: nil, budget: budget(addressesPerDocument: 2_249)),
            .failure(.budgetExceeded(.addressesPerDocument))
        )
    }

    func testImporterSharesAddressDocumentCounterAcrossLayers() throws {
        let data = try legacyRoot(layerCount: 2)
        let source = try XCTUnwrap(CompatibilityImporter.read(data).successValue)
        let exact = budget(addressesPerLayer: 2_250, addressesPerDocument: 4_500)
        let justOver = budget(addressesPerLayer: 2_250, addressesPerDocument: 4_499)

        guard case .success = SpatialDocumentImporter.document(from: source, budget: exact) else {
            return XCTFail("Zwei Ebenen an der dokumentweiten Grenze müssen akzeptiert werden")
        }
        XCTAssertEqual(
            SpatialDocumentImporter.document(from: source, budget: justOver),
            .failure(.budgetExceeded(.addressesPerDocument))
        )
    }

    private func budget(
        inputBytes: Int = .max,
        layers: Int = 256,
        addressesPerLayer: Int = 262_144,
        addressesPerDocument: Int = 1_048_576,
        actionAssignments: Int = 1_048_576,
        noteEntries: Int = 1_048_576,
        routings: Int = 4_096
    ) -> SpatialDocumentBudget {
        SpatialDocumentBudget(
            inputBytes: inputBytes, layers: layers,
            addressesPerLayer: addressesPerLayer,
            addressesPerDocument: addressesPerDocument,
            actionAssignments: actionAssignments,
            noteEntries: noteEntries,
            routings: routings
        )
    }

    private func legacyRoot(
        actionCount: Int = 0,
        layerCount: Int = 1
    ) throws -> Data {
        try legacyRoot(actions: Array(repeating: a60, count: actionCount), layerCount: layerCount)
    }

    private func legacyRoot(
        actions: [SpatialCellAction],
        layerCount: Int = 1,
        routings: [SpatialRouting] = []
    ) throws -> Data {
        let polar = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let layers = (0..<layerCount).map { index in
            SpatialInstrumentLayer(
                id: index == 0 ? selected : UUID(), name: "Layer \(index)", color: .orange,
                polarCells: [polar],
                routings: routings,
                polarCellOverrides: actions.isEmpty ? [:] : [polar: actions]
            )
        }
        let values = try layers.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        let grid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MetricSquareGrid.halfMeter))
        let workspace = try JSONSerialization.data(withJSONObject: [
            "grid": grid, "layers": values, "selectedLayerID": selected.uuidString,
            "coordinateMode": "polar"
        ])
        return try JSONSerialization.data(withJSONObject: [
            "formatVersion": 3,
            "spatialWorkspace": try JSONSerialization.jsonObject(with: workspace)
        ])
    }
}

private extension Result where Failure: Error {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
