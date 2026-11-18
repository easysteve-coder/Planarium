import XCTest
@testable import PlanariumDomain
import PlanariumControllerCore

final class ControllerLayoutPersistenceTests: XCTestCase {
    private func document() throws -> InstrumentDocument {
        let layer = SpatialDocumentLayer(id: UUID(), name: "A", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                                         cells: [PolarDeviceLattice(ring: 100, sector: 180)!], routings: [], cellOverrides: [:])
        return InstrumentDocument(spatial: try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id),
                                  revision: .newSession())
    }

    func testDocumentWithoutControllerWritesNoControllerKey() throws {
        let data = try JSONEncoder().encode(try document())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"controller\""), "existing presets stay byte-identical")
        XCTAssertEqual(try JSONDecoder().decode(InstrumentDocument.self, from: data).controller, .empty)
    }

    func testControllerAssignmentsRoundTrip() throws {
        var value = try document()
        value.controller = ControllerAssistant.melody.applied(to: .empty, output: .midi(channel: 0))
        value.controller.enterRadius = 0.5
        let decoded = try JSONDecoder().decode(InstrumentDocument.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.controller, value.controller)
    }
}
