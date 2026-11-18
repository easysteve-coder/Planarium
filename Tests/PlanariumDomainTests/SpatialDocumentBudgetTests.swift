import Foundation
import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class SpatialDocumentBudgetTests: XCTestCase {
    private let selected = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    func testProductionBudgetLiterals() {
        XCTAssertEqual(SpatialDocumentBudget.production.inputBytes, 67_108_864)
        XCTAssertEqual(SpatialDocumentBudget.production.layers, 256)
        XCTAssertEqual(SpatialDocumentBudget.production.addressesPerLayer, 262_144)
        XCTAssertEqual(SpatialDocumentBudget.production.addressesPerDocument, 1_048_576)
        XCTAssertEqual(SpatialDocumentBudget.production.actionAssignments, 1_048_576)
        XCTAssertEqual(SpatialDocumentBudget.production.noteEntries, 1_048_576)
        XCTAssertEqual(SpatialDocumentBudget.production.routings, 4_096)
    }

    func testRoutingBudgetIsDocumentWideAndRejectsPoisonAfterBoundary() throws {
        let routing = SpatialRouting(target: .midiNote(channel: 0), program: .constant(1))
        let layer = SpatialDocumentLayer(id: selected, name: "x", color: .orange,
                                         isVisible: true, isActive: true, isLocked: false,
                                         isSoloed: false, cells: [], routings: [routing],
                                         cellOverrides: [:])
        let document = try SpatialDocument(latticeVersion: .polarDeviceV2,
                                           layers: [layer], selectedLayerID: selected)
        let data = try JSONEncoder().encode(document)
        let exact = SpatialDocumentBudget(inputBytes: .max, layers: 1,
                                          addressesPerLayer: 1, addressesPerDocument: 1,
                                          actionAssignments: 1, noteEntries: 1, routings: 1)
        XCTAssertNoThrow(try decode(data, budget: exact))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        var routings = try XCTUnwrap(layers[0]["routings"] as? [[String: Any]])
        routings.append(["poison": "not-a-routing"])
        layers[0]["routings"] = routings
        object["layers"] = layers
        let poisoned = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try decode(poisoned, budget: exact)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.routings))
        }
    }

    func testRoutingChordSharesNoteBudgetWithCellActions() throws {
        let action = SpatialCellAction(target: .midiNote(channel: 0),
                                       value: .note(number: 60, velocity: 100))
        let routing = SpatialRouting(target: .midiNote(channel: 1),
                                     program: .chord(notes: [62], velocity: 100, transition: .legato))
        let layer = SpatialDocumentLayer(id: selected, name: "x", color: .orange,
                                         isVisible: true, isActive: true, isLocked: false,
                                         isSoloed: false, cells: [], routings: [routing],
                                         cellOverrides: [PolarDeviceLattice(ring: 0, sector: 0)!: [action]])
        let document = try SpatialDocument(latticeVersion: .polarDeviceV2,
                                           layers: [layer], selectedLayerID: selected)
        let data = try JSONEncoder().encode(document)
        let exact = SpatialDocumentBudget(inputBytes: .max, layers: 1,
                                          addressesPerLayer: 1, addressesPerDocument: 1,
                                          actionAssignments: 1, noteEntries: 2, routings: 1)
        XCTAssertNoThrow(try decode(data, budget: exact))
        let oneLess = SpatialDocumentBudget(inputBytes: .max, layers: 1,
                                            addressesPerLayer: 1, addressesPerDocument: 1,
                                            actionAssignments: 1, noteEntries: 1, routings: 1)
        XCTAssertThrowsError(try decode(data, budget: oneLess)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.noteEntries))
        }
    }

    func testAddressesPerLayerBoundaryAndInvalidPoison() throws {
        let cells = (1...726).flatMap { ring in (0...360).map { "{\"ring\":\(ring),\"sector\":\($0)}" } }
            + (0..<58).map { "{\"ring\":727,\"sector\":\($0)}" }
        XCTAssertNoThrow(try decode(document(cells: cells)))
        XCTAssertThrowsError(try decode(document(cells: cells + ["{\"ring\":239,\"sector\":16}"]))) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.addressesPerLayer))
        }
        let poison = cells + ["{\"ring\":727,\"sector\":58}"]
        XCTAssertThrowsError(try decode(document(cells: poison))) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.addressesPerLayer))
        }
    }

    func testOverrideAddressesCountOnlyOutsideCells() throws {
        let cells = (1...726).flatMap { ring in (0...360).map { "{\"ring\":\(ring),\"sector\":\($0)}" } }
            + (0..<57).map { "{\"ring\":727,\"sector\":\($0)}" }
        let overrides = "[{\"cell\":{\"ring\":727,\"sector\":57},\"actions\":[]},{\"cell\":{\"ring\":727,\"sector\":58},\"actions\":[]}]"
        XCTAssertThrowsError(try decode(document(cells: cells, overrides: overrides))) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.addressesPerLayer))
        }
        let inside = "[{\"cell\":{\"ring\":727,\"sector\":56},\"actions\":[]}]"
        XCTAssertNoThrow(try decode(document(cells: cells, overrides: inside)))
    }

    func testLayerAndDocumentAddressBudgets() throws {
        let layers = (0..<256).map { layerJSON(index: $0, cells: ["{\"ring\":1,\"sector\":\($0 % 8)}"]) }.joined(separator: ",")
        XCTAssertNoThrow(try decode(document(layers: layers)))
        XCTAssertThrowsError(try decode(document(layers: layers + "," + layerJSON(index: 256, cells: ["{\"ring\":1,\"sector\":0}"])))) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.layers))
        }
        let small = SpatialDocumentBudget(inputBytes: .max, layers: 256, addressesPerLayer: 262_144,
                                          addressesPerDocument: 6, actionAssignments: 1_048_576, noteEntries: 1_048_576)
        let three = (0..<3).map { layerJSON(index: $0, cells: ["{\"ring\":1,\"sector\":\($0 * 2)}", "{\"ring\":1,\"sector\":\($0 * 2 + 1)}"]) }.joined(separator: ",")
        XCTAssertNoThrow(try decode(document(layers: three), budget: small))
        XCTAssertThrowsError(try decode(document(layers: three + "," + layerJSON(index: 3, cells: ["{\"ring\":1,\"sector\":6}"])), budget: small)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.addressesPerDocument))
        }
    }

    func testT4cAddressesPerLayerResetsBetweenDecoderLayers() throws {
        let budget = SpatialDocumentBudget(inputBytes: .max, layers: 256,
                                           addressesPerLayer: 3, addressesPerDocument: 6,
                                           actionAssignments: 1_048_576, noteEntries: 1_048_576)
        let two = layerJSON(index: 0, cells: ["{\"ring\":1,\"sector\":0}", "{\"ring\":1,\"sector\":1}", "{\"ring\":1,\"sector\":2}"])
            + "," + layerJSON(index: 1, cells: ["{\"ring\":1,\"sector\":3}", "{\"ring\":1,\"sector\":4}", "{\"ring\":1,\"sector\":5}"])
        XCTAssertNoThrow(try decode(document(layers: two), budget: budget))
        let four = layerJSON(index: 0, cells: ["{\"ring\":1,\"sector\":0}", "{\"ring\":1,\"sector\":1}", "{\"ring\":1,\"sector\":2}", "{\"ring\":1,\"sector\":3}"])
        XCTAssertThrowsError(try decode(document(layers: four), budget: budget)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.addressesPerLayer))
        }
    }

    func testThrowingInitResetsAddressesPerLayerAndChecksLayerLimit() throws {
        let cells = Set((1...726).flatMap { ring in
            (0...360).compactMap { sector in PolarDeviceLattice(ring: ring, sector: sector) }
        } + (0..<58).compactMap { PolarDeviceLattice(ring: 727, sector: $0) })
        let first = SpatialDocumentLayer(id: selected, name: "a", color: .orange, isVisible: true, isActive: true,
                                         isLocked: false, isSoloed: false, cells: cells, routings: [], cellOverrides: [:])
        let second = SpatialDocumentLayer(id: UUID(), name: "b", color: .blue, isVisible: true, isActive: true,
                                          isLocked: false, isSoloed: false, cells: cells, routings: [], cellOverrides: [:])
        XCTAssertNoThrow(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [first, second], selectedLayerID: selected))
        let many = [first] + (0..<256).map { _ in
            SpatialDocumentLayer(id: UUID(), name: "x", color: .blue, isVisible: true, isActive: true,
                                 isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])
        }
        XCTAssertThrowsError(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: many, selectedLayerID: selected)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.layers))
        }
    }

    func testActionAndNoteBudgetsAreDocumentWideAndElementWise() throws {
        let budget = SpatialDocumentBudget(inputBytes: .max, layers: 256, addressesPerLayer: 262_144,
                                           addressesPerDocument: 1_048_576, actionAssignments: 4, noteEntries: 1_048_576)
        let one = actionJSON(value: "{\"note\":{\"number\":60,\"velocity\":100}}")
        XCTAssertNoThrow(try decode(document(overrides: "[{\"cell\":{\"ring\":0,\"sector\":1},\"actions\":[\(one),\(one),\(one),\(one)]}]"), budget: budget))
        XCTAssertThrowsError(try decode(document(overrides: "[{\"cell\":{\"ring\":0,\"sector\":1},\"actions\":[\(one),\(one),\(one),\(one),\(one)]}]"), budget: budget)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.actionAssignments))
        }
        let noteBudget = SpatialDocumentBudget(inputBytes: .max, layers: 256, addressesPerLayer: 262_144,
                                               addressesPerDocument: 1_048_576, actionAssignments: 1_048_576, noteEntries: 3)
        let chord = actionJSON(value: "{\"chord\":{\"notes\":[60,62,64],\"velocity\":100}}")
        XCTAssertNoThrow(try decode(document(overrides: "[{\"cell\":{\"ring\":0,\"sector\":1},\"actions\":[\(chord)]}]"), budget: noteBudget))
        XCTAssertThrowsError(try decode(document(overrides: "[{\"cell\":{\"ring\":0,\"sector\":1},\"actions\":[\(chord.replacingOccurrences(of: "64", with: "64,\"x\""))]}]"), budget: noteBudget)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.noteEntries))
        }
    }

    func testDecodeRoundTripAndInputBudget() throws {
        let layer = SpatialDocumentLayer(id: selected, name: "x", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                                         cells: [], routings: [], cellOverrides: [:])
        let document = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: selected)
        XCTAssertEqual(try SpatialDocument.decode(JSONEncoder().encode(document)), document)
        let oversized = Data(repeating: 0, count: SpatialDocumentBudget.production.inputBytes + 1)
        XCTAssertThrowsError(try SpatialDocument.decode(oversized)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .budgetExceeded(.inputBytes))
        }
        let exact = Data(repeating: 0, count: SpatialDocumentBudget.production.inputBytes)
        XCTAssertThrowsError(try SpatialDocument.decode(exact)) { error in
            XCTAssertTrue(error is DecodingError, "Exact input size must reach JSONDecoder")
        }
    }

    private func decode(_ data: Data, budget: SpatialDocumentBudget = .production) throws -> SpatialDocument {
        let decoder = JSONDecoder()
        decoder.userInfo[.spatialDocumentBudget] = budget
        return try decoder.decode(SpatialDocument.self, from: data)
    }

    private func document(cells: [String] = [], overrides: String = "[]", layers: String? = nil) -> Data {
        let body = layers ?? layerJSON(index: 0, cells: cells, overrides: overrides)
        return Data("{\"latticeVersion\":\"polarDeviceV2\",\"layers\":[\(body)],\"selectedLayerID\":\"\(selected.uuidString)\"}".utf8)
    }

    private func layerJSON(index: Int, cells: [String], overrides: String = "[]") -> String {
        let id = index == 0 ? selected.uuidString : String(format: "%08X-AAAA-AAAA-AAAA-%012X", index + 1, index + 1)
        return "{\"id\":\"\(id)\",\"name\":\"x\",\"color\":{\"red\":1,\"green\":0,\"blue\":0,\"alpha\":1},\"isVisible\":true,\"isActive\":true,\"isLocked\":false,\"isSoloed\":false,\"cells\":[\(cells.joined(separator: ","))],\"routings\":[],\"cellOverrides\":\(overrides)}"
    }

    private func actionJSON(value: String) -> String {
        "{\"target\":{\"midiNote\":{\"channel\":1}},\"value\":\(value)}"
    }
}
