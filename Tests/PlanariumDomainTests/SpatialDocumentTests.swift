import Foundation
import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class SpatialDocumentTests: XCTestCase {
    private let firstID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let secondID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let routingID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    private func cell(_ ring: Int, _ sector: Int) throws -> PolarDeviceLattice {
        try XCTUnwrap(PolarDeviceLattice(ring: ring, sector: sector))
    }

    private func handJSONText() -> String {
        """
        {
          "latticeVersion":"polarDeviceV2",
          "layers":[
            {"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"Leer","color":{"red":0.18,"green":0.55,"blue":0.96,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false,"cells":[],"routings":[],"cellOverrides":[]},
            {"id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","name":"Spiel","color":{"red":1,"green":0.55,"blue":0,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false,"cells":[{"ring":0,"sector":3},{"ring":57,"sector":359}],"routings":[],"cellOverrides":[{"cell":{"ring":57,"sector":359},"actions":[{"target":{"midiNote":{"channel":1}},"value":{"note":{"number":60,"velocity":100}}}]}]}
          ],
          "selectedLayerID":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        }
        """
    }

    private func handJSON() -> Data {
        Data(handJSONText().utf8)
    }

    func testHandWrittenDocumentDecodesWithLayerOrderSelectionAndOverride() throws {
        let document = try JSONDecoder().decode(SpatialDocument.self, from: handJSON())
        let overrideCell = try cell(57, 359)
        let expectedAction = SpatialCellAction(
            target: .midiNote(channel: 1), value: .note(number: 60, velocity: 100)
        )
        XCTAssertEqual(document.latticeVersion, .polarDeviceV2)
        XCTAssertEqual(document.layers.map(\.id), [firstID, secondID])
        XCTAssertEqual(document.selectedLayerID, secondID)
        XCTAssertEqual(document.layers[1].cells, [try cell(0, 3), overrideCell])
        XCTAssertEqual(document.layers[1].cellOverrides[overrideCell], [expectedAction])
    }

    func testEncodedDocumentUsesOnlyCurrentSpatialKeysAndSortsCells() throws {
        let layer = SpatialDocumentLayer(
            id: secondID, name: "Spiel", color: .orange,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [try cell(57, 359), try cell(0, 3)], routings: [], cellOverrides: [:]
        )
        let document = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: secondID)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["latticeVersion", "layers", "selectedLayerID"])
        let encodedLayer = try XCTUnwrap((object["layers"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(encodedLayer.keys), ["id", "name", "color", "isVisible", "isActive", "isLocked", "isSoloed", "cells", "routings", "cellOverrides", "toggleGuardSeconds"])
        XCTAssertEqual(encodedLayer["toggleGuardSeconds"] as? Double, 0.5)
        XCTAssertNil(encodedLayer["grid"])
        XCTAssertNil(encodedLayer["coordinateMode"])
        XCTAssertNil(encodedLayer["angularIndex"])
        XCTAssertNil(encodedLayer["polarCells"])
        XCTAssertNil(encodedLayer["cellSizeMeters"])
        let firstCell = try XCTUnwrap((encodedLayer["cells"] as? [[Int]])?.first)
        XCTAssertEqual(firstCell, [0, 3, 3])
    }

    func testEncodingIsDeterministicAcrossSetAndOverrideInsertionOrder() throws {
        let a = try cell(0, 3)
        let b = try cell(57, 359)
        let action = SpatialCellAction(target: .midiNote(channel: 1), value: .note(number: 60, velocity: 100))
        let layerA = SpatialDocumentLayer(id: secondID, name: "x", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [a, b], routings: [SpatialRouting(id: routingID, target: .midiNote(channel: 1), program: .constant(1))], cellOverrides: [b: [action], a: [action]])
        let layerB = SpatialDocumentLayer(id: secondID, name: "x", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [b, a], routings: [SpatialRouting(id: routingID, target: .midiNote(channel: 1), program: .constant(1))], cellOverrides: [a: [action], b: [action]])
        let one = try JSONEncoder.sorted.encode(SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layerA], selectedLayerID: secondID))
        let two = try JSONEncoder.sorted.encode(SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layerB], selectedLayerID: secondID))
        XCTAssertEqual(one, two)
    }

    func testRejectsMissingOrUnknownVersionWithDecodingErrorsOnValidDocument() throws {
        let decoder = JSONDecoder()
        let missingVersion = handJSONText().replacingOccurrences(of: "\"latticeVersion\":\"polarDeviceV2\",", with: "")
        XCTAssertThrowsError(try decoder.decode(SpatialDocument.self, from: Data(missingVersion.utf8))) { error in
            guard case DecodingError.keyNotFound = error else { return XCTFail("Erwartet keyNotFound, erhalten: \(error)") }
        }
        let oldVersion = handJSONText().replacingOccurrences(of: "polarDeviceV2", with: "polarDeviceV1")
        XCTAssertThrowsError(try decoder.decode(SpatialDocument.self, from: Data(oldVersion.utf8))) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .unsupportedLatticeVersion(.polarDeviceV1))
        }
        let unknownVersion = handJSONText().replacingOccurrences(of: "polarDeviceV2", with: "polarDeviceV3")
        XCTAssertThrowsError(try decoder.decode(SpatialDocument.self, from: Data(unknownVersion.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else { return XCTFail("Erwartet dataCorrupted, erhalten: \(error)") }
        }
    }

    func testRejectsInvalidCellAsDataCorrupted() throws {
        let decoder = JSONDecoder()
        let invalidCell = handJSONText().replacingOccurrences(of: #"{"ring":57,"sector":359}"#, with: #"{"ring":0,"sector":361}"#)
        XCTAssertThrowsError(try decoder.decode(SpatialDocument.self, from: Data(invalidCell.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else { return XCTFail("Erwartet dataCorrupted, erhalten: \(error)") }
        }
    }

    func testRejectsDuplicateCellsAndOverridesWithTheirSpatialErrors() throws {
        let decoder = JSONDecoder()
        let duplicateCell = handJSONText().replacingOccurrences(of: #"{"ring":0,"sector":3},{"ring":57,"sector":359}"#, with: #"{"ring":0,"sector":3},{"ring":0,"sector":3}"#)
        let expectedCell = try cell(0, 3)
        XCTAssertThrowsError(try decoder.decode(SpatialDocument.self, from: Data(duplicateCell.utf8))) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .duplicateCell(layerID: self.secondID, cell: expectedCell))
        }
        let duplicateOverride = handJSONText().replacingOccurrences(
            of: "\"cellOverrides\":[{",
            with: "\"cellOverrides\":[{\"cell\":{\"ring\":57,\"sector\":359},\"actions\":[]},{"
        )
        let expectedOverrideCell = try cell(57, 359)
        XCTAssertThrowsError(try decoder.decode(SpatialDocument.self, from: Data(duplicateOverride.utf8))) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .duplicateOverrideCell(layerID: self.secondID, cell: expectedOverrideCell))
        }
    }

    func testRejectsEmptyDuplicateAndUnknownSelectionThroughThrowingInit() throws {
        let layer = SpatialDocumentLayer(id: firstID, name: "x", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])
        XCTAssertThrowsError(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [], selectedLayerID: firstID)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .emptyLayerStack)
        }
        XCTAssertThrowsError(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer, layer], selectedLayerID: firstID)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .duplicateLayerID(firstID))
        }
        XCTAssertThrowsError(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: secondID)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .unknownSelection(secondID))
        }
    }

    func testPolarDeviceV2RasterFactsAreExplicit() {
        XCTAssertEqual(SpatialLatticeVersion.polarDeviceV2.tickCount, 361)
        XCTAssertEqual(SpatialLatticeVersion.polarDeviceV2.ringQuantumCentimeters, 1)
        XCTAssertEqual(SpatialLatticeVersion.polarDeviceV2.tickDegrees, 0.5)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
