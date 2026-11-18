import XCTest
import Foundation
import SickPLSControlCore
@testable import PlanariumDomain

final class LegacySpatialDocumentTests: XCTestCase {

    // MARK: - 1. Kartesische Altform wörtlich erhalten

    func testCartesianLegacyFormPreservedLiterally() throws {
        let cell = MetricGridCell(column: 0, row: 2)
        let action = SpatialCellAction(
            target: .midiNote(channel: 0),
            value: .note(number: 60, velocity: 100)
        )
        let layer = LegacyLayerDocument(
            name: "Test",
            color: SpatialLayerColor(red: 1, green: 0, blue: 0),
            cells: [cell],
            cellOverrides: [cell: [action]]
        )
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.5)
        let data = try LegacyWorkspaceDocument.data(layer: layer, grid: grid)

        let reading = try LegacySpatialDocumentReader.read(from: data)

        XCTAssertEqual(reading.document.layers.count, 1)
        let l = reading.document.layers[0]
        XCTAssertEqual(l.cells.count, 1)
        XCTAssertEqual(l.cellOverrides.count, 1)
        XCTAssertTrue(l.polarCells.isEmpty)
        XCTAssertTrue(l.polarCellOverrides.isEmpty)
        XCTAssertEqual(reading.document.cellSizeMeters, 0.5)
        XCTAssertTrue(reading.findings.isEmpty)
    }

    // MARK: - 2. Tragende Gegenprobe: SpatialInstrumentWorkspace migriert

    func testCounterProofSpatialInstrumentWorkspaceMigrates() throws {
        let cell = MetricGridCell(column: 0, row: 2)
        let action = SpatialCellAction(
            target: .midiNote(channel: 0),
            value: .note(number: 60, velocity: 100)
        )
        let layer = LegacyLayerDocument(
            name: "Test",
            color: SpatialLayerColor(red: 1, green: 0, blue: 0),
            cells: [cell],
            cellOverrides: [cell: [action]]
        )
        let grid = try MetricSquareGrid.build(cellSizeMeters: 0.5)
        let data = try LegacyWorkspaceDocument.data(layer: layer, grid: grid)

        let workspace = try JSONDecoder().decode(
            SpatialInstrumentWorkspace.self,
            from: data
        )

        // Die Altform ist dort weg — polar ist da.
        let l = workspace.layers[0]
        XCTAssertEqual(l.polarCells.count, 1)
        XCTAssertEqual(l.polarCellOverrides.count, 1)
    }

    // MARK: - 3. Reihenfolge der Ebenen

    func testLayerOrderPreserved() throws {
        let json = """
        {
            "grid": {"cellSizeMeters": 0.5},
            "layers": [
                {"id":"A0000000-0000-0000-0000-000000000001","name":"Gamma","color":{"red":1,"green":0,"blue":0,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false,"routings":[]},
                {"id":"A0000000-0000-0000-0000-000000000002","name":"Alpha","color":{"red":0,"green":0,"blue":1,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false,"routings":[]},
                {"id":"A0000000-0000-0000-0000-000000000003","name":"Beta","color":{"red":0,"green":1,"blue":0,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false,"routings":[]}
            ],
            "selectedLayerID": "A0000000-0000-0000-0000-000000000001"
        }
        """
        let data = json.data(using: .utf8)!
        let reading = try LegacySpatialDocumentReader.read(from: data)

        let names = reading.document.layers.map(\.name)
        XCTAssertEqual(names, ["Gamma", "Alpha", "Beta"])
    }

    // MARK: - 4. Unbekannte Auswahl bleibt wörtlich, Befund wird gemeldet

    func testUnknownSelectionPreservedWithFinding() throws {
        let foreignID = UUID()
        let json = """
        {
            "grid": {"cellSizeMeters": 0.5},
            "layers": [
                {"id":"B0000000-0000-0000-0000-000000000001","name":"Solo","color":{"red":1,"green":0,"blue":0,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false,"routings":[]}
            ],
            "selectedLayerID": "\(foreignID)"
        }
        """
        let data = json.data(using: .utf8)!
        let reading = try LegacySpatialDocumentReader.read(from: data)

        XCTAssertEqual(reading.document.selectedLayerID, foreignID)
        XCTAssertEqual(reading.findings, [.unknownSelection(foreignID)])
    }

    // MARK: - 5. Leerer Ebenenstapel

    func testEmptyLayerStack() {
        let json = """
        {"grid":{"cellSizeMeters":0.5},"layers":[],"selectedLayerID":"B0000000-0000-0000-0000-000000000001"}
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try LegacySpatialDocumentReader.read(from: data)) { error in
            XCTAssertEqual(error as? LegacySpatialDocumentError, .emptyLayerStack)
        }
    }

    // MARK: - 6. Krummes Raster (2,5 cm)

    func testNonIntegerCentimeterGrid() {
        let json = """
        {"grid":{"cellSizeMeters":0.025},"layers":[{"id":"B0000000-0000-0000-0000-000000000001","name":"X","color":{"red":1,"green":0,"blue":0,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false,"routings":[]}],"selectedLayerID":"B0000000-0000-0000-0000-000000000001"}
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try LegacySpatialDocumentReader.read(from: data)) { error in
            XCTAssertEqual(error as? LegacySpatialDocumentError, .nonIntegerCentimeterGrid(0.025))
        }
    }

    // MARK: - 7. Kein JSON-Objekt

    func testNotAJSONObject() {
        let data = Data("nein".utf8)
        XCTAssertThrowsError(try LegacySpatialDocumentReader.read(from: data)) { error in
            XCTAssertEqual(error as? LegacySpatialDocumentError, .notAJSONObject)
        }
    }

    // MARK: - 8. Fehlende Pflichtangabe einer Ebene wird benannt abgelehnt

    func testMalformedLayerNamesItsIndex() {
        // Die mittlere Ebene hat kein `routings`. Der Produktdekoder
        // verlangt das Feld ebenfalls; ein Altdokument ohne es war nie
        // lesbar. Erwartet wird Index 1, nicht Index 0.
        let json = """
        {
            "grid": {"cellSizeMeters": 0.5},
            "layers": [
                {"id":"C0000000-0000-0000-0000-000000000001","name":"Eins","color":{"red":1,"green":0,"blue":0,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false,"routings":[]},
                {"id":"C0000000-0000-0000-0000-000000000002","name":"Zwei","color":{"red":0,"green":1,"blue":0,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false},
                {"id":"C0000000-0000-0000-0000-000000000003","name":"Drei","color":{"red":0,"green":0,"blue":1,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false,"routings":[]}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try LegacySpatialDocumentReader.read(from: data)) { error in
            guard case .malformedLayer(let index, _)? = error as? LegacySpatialDocumentError else {
                return XCTFail("Erwartet malformedLayer, erhalten \(error)")
            }
            XCTAssertEqual(index, 1, "Der Befund muss die zweite Ebene benennen, nicht die erste")
        }
    }

    // MARK: - 9. Strukturfehler oberhalb der Ebenen beschuldigt keine Ebene

    func testMalformedDocumentBlamesNoLayer() {
        // `grid` fehlt. Das ist kein Ebenenfehler und darf keinen
        // Ebenenindex erfinden.
        let json = """
        {"layers":[],"selectedLayerID":"D0000000-0000-0000-0000-000000000001"}
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try LegacySpatialDocumentReader.read(from: data)) { error in
            guard case .malformedDocument? = error as? LegacySpatialDocumentError else {
                return XCTFail("Erwartet malformedDocument, erhalten \(error)")
            }
        }
    }

    // MARK: - 10. Fehlende Auswahl ist ein Befund, keine stille Reparatur

    func testAbsentSelectionIsReported() throws {
        let json = """
        {
            "grid": {"cellSizeMeters": 0.5},
            "layers": [
                {"id":"E0000000-0000-0000-0000-000000000001","name":"Einzig","color":{"red":1,"green":0,"blue":0,"alpha":1},"isVisible":true,"isActive":true,"isLocked":false,"isSoloed":false,"routings":[]}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let reading = try LegacySpatialDocumentReader.read(from: data)

        XCTAssertNil(reading.document.selectedLayerID)
        XCTAssertEqual(reading.findings, [.unknownSelection(nil)])
    }
}
