import Foundation
import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class CompatibilityImporterTests: XCTestCase {

    func testCartesianV3ConnectsAddressAndMask() throws {
        let legacy = LegacyLayerDocument(
            name: "Kartesisch",
            color: SpatialLayerColor(red: 1, green: 0, blue: 0),
            cells: [MetricGridCell(column: 0, row: 2)]
        )
        let workspace = try LegacyWorkspaceDocument.data(
            layer: legacy,
            grid: .halfMeter,
            coordinateMode: "cartesian"
        )
        let result = try CompatibilityImporter.read(wrap(workspace: workspace)).get()

        XCTAssertEqual(result.layers.count, 1)
        XCTAssertEqual(result.layers[0].sourcePolarCells, [PolarMetricGridCell(ring: 2, angularIndex: 8)])
        XCTAssertEqual(result.layers[0].cells.count, 2250)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testSameInputIsDeterministicAndContextIsIgnored() throws {
        let workspace = try makeWorkspace(
            polarCells: [(0, 2), (0, 3)],
            selectedLayerID: "10000000-0000-0000-0000-000000000001"
        )
        let first = try CompatibilityImporter.read(
            wrap(workspace: workspace), context: "first.json"
        ).get()
        let second = try CompatibilityImporter.read(
            wrap(workspace: workspace), context: "second.json"
        ).get()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.layers[0].cells.count, 8820)
        XCTAssertEqual(first.layers[0].edgeGrowthProbeCount, 0)
    }

    func testMissingWorkspaceIsAStatusNotAnError() throws {
        let data = Data(#"{"formatVersion":3}"#.utf8)
        let result = try CompatibilityImporter.read(data).get()

        XCTAssertNil(result.document)
        XCTAssertEqual(result.layers.count, 0)
        XCTAssertEqual(result.findings, [.noSpatialInventory])
    }

    func testEmptyWorkspaceIsAStatusNotARejection() throws {
        let workspace = try makeWorkspace()
        let result = try CompatibilityImporter.read(wrap(workspace: workspace)).get()

        XCTAssertNotNil(result.document)
        XCTAssertTrue(result.findings.contains(.noSpatialInventory))
        XCTAssertTrue(result.findings.contains(.document(.unknownSelection(nil))))
    }

    func testPresentMalformedWorkspaceIsRejected() throws {
        let data = Data(#"{"formatVersion":3,"spatialWorkspace":null}"#.utf8)

        XCTAssertEqual(
            CompatibilityImporter.read(data),
            .failure(.malformedSpatialWorkspace(.malformedDocument(
                reason: "spatialWorkspace is not a JSON object"
            )))
        )
    }

    func testVersionFailuresAreNamed() throws {
        XCTAssertEqual(
            CompatibilityImporter.read(Data(#"{"formatVersion":2}"#.utf8)),
            .failure(.unsupportedVersion(2))
        )
        XCTAssertEqual(
            CompatibilityImporter.read(Data(#"{"formatVersion":"3"}"#.utf8)),
            .failure(.malformedFormatVersion)
        )
        XCTAssertEqual(
            CompatibilityImporter.read(Data("{}".utf8)),
            .failure(.missingFormatVersion)
        )
    }

    func testNonIntegerGridIsRejectedByCompatibilityBoundary() throws {
        let workspace = try makeWorkspace(cellSizeMeters: 0.025, polarCells: [(2, 8)])

        XCTAssertEqual(
            CompatibilityImporter.read(try wrap(workspace: workspace)),
            .failure(.nonIntegerCentimeterGrid(0.025))
        )
    }

    func testLossFindingsPreserveSourceAndReason() throws {
        let workspace = try makeWorkspace(
            polarCells: [(3, 7), (122, 259), (163, 256)]
        )
        let result = try CompatibilityImporter.read(wrap(workspace: workspace)).get()

        XCTAssertTrue(result.findings.contains {
            if case .fullyLost(layerIndex: 0, cell: PolarMetricGridCell(ring: 3, angularIndex: 7),
                                rasterCentimeters: 50, reason: .fullyOutsideScannerField) = $0 { return true }
            return false
        })
        XCTAssertTrue(result.findings.contains {
            if case .fullyLost(layerIndex: 0, cell: PolarMetricGridCell(ring: 122, angularIndex: 259),
                                rasterCentimeters: 50, reason: .noValidDeviceProbe) = $0 { return true }
            return false
        })
        XCTAssertTrue(result.findings.contains {
            if case .radialPartialLoss(layerIndex: 0, cell: PolarMetricGridCell(ring: 163, angularIndex: 256),
                                       rasterCentimeters: 50, centimeters: 9) = $0 { return true }
            return false
        })
    }

    func testEdgeGrowthIsASeparateFinding() throws {
        let workspace = try makeWorkspace(polarCells: [(0, 2)])
        let result = try CompatibilityImporter.read(wrap(workspace: workspace)).get()

        XCTAssertFalse(result.findings.contains {
            if case .edgeGrowth(layerIndex: 0, rasterCentimeters: 50,
                                probeCount: _, cells: _) = $0 { return true }
            return false
        })
    }

    func testCartesianAddressFailureIsACollectionFinding() throws {
        let legacy = LegacyLayerDocument(
            name: "Außen",
            color: SpatialLayerColor(red: 1, green: 0, blue: 0),
            cells: [MetricGridCell(column: 0, row: 2000)]
        )
        let workspace = try LegacyWorkspaceDocument.data(layer: legacy, grid: .halfMeter)
        let result = try CompatibilityImporter.read(wrap(workspace: workspace)).get()

        XCTAssertTrue(result.findings.contains {
            if case .cartesianAddress(layerIndex: 0, cell: MetricGridCell(column: 0, row: 2000),
                                      rasterCentimeters: 50, error: .outsideValueRange) = $0 { return true }
            return false
        })
    }

    private func wrap(workspace: Data) throws -> Data {
        let workspaceObject = try JSONSerialization.jsonObject(with: workspace)
        return try JSONSerialization.data(withJSONObject: [
            "formatVersion": 3,
            "spatialWorkspace": workspaceObject
        ])
    }

    private func makeWorkspace(
        cellSizeMeters: Double = 0.5,
        polarCells: [(Int, Int)] = [],
        selectedLayerID: String? = nil
    ) throws -> Data {
        let layer: [String: Any] = [
            "id": "10000000-0000-0000-0000-000000000001",
            "name": "Polar",
            "color": ["red": 1, "green": 0, "blue": 0, "alpha": 1],
            "isVisible": true,
            "isActive": true,
            "isLocked": false,
            "isSoloed": false,
            "routings": [],
            "polarCells": polarCells.map { ["ring": $0.0, "angularIndex": $0.1] }
        ]
        var workspace: [String: Any] = [
            "grid": ["cellSizeMeters": cellSizeMeters],
            "layers": [layer]
        ]
        if let selectedLayerID {
            workspace["selectedLayerID"] = selectedLayerID
        }
        return try JSONSerialization.data(withJSONObject: workspace)
    }
}
