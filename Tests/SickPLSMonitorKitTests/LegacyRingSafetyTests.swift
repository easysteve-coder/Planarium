import Foundation
import XCTest
import SickPLSControlCore
@testable import SickPLSMonitorKit

final class LegacyRingSafetyTests: XCTestCase {
    func testExtremePolarCellsAreNamedLossesWithoutOverflow() throws {
        let addresses = [
            (Int.max, 8),
            (Int.min, 8),
            (1_000_000_000_000, 8),
            (0, Int.max),
            (0, -1)
        ]

        for (ring, angularIndex) in addresses {
            let result = CompatibilityImporter.read(try legacyData(polarCells: [(ring, angularIndex)]))
            guard case .success(let imported) = result else {
                return XCTFail("Extremadresse \(ring)/\(angularIndex) wurde nicht benannt übernommen")
            }
            XCTAssertTrue(
                imported.findings.contains {
                    if case .fullyLost(_, _, _, .fullyOutsideScannerField) = $0 { return true }
                    return false
                },
                "Extremadresse \(ring)/\(angularIndex) muss als fullyOutsideScannerField erscheinen"
            )
        }
    }

    func testExtremePolarOverrideKeysRemainNamedAndDoNotCrash() throws {
        let addresses = [
            (Int.max, 8),
            (Int.min, 8),
            (1_000_000_000_000, 8),
            (0, Int.max),
            (0, -1)
        ]

        for address in addresses {
            let result = CompatibilityImporter.read(try legacyData(polarOverrides: [address]))
            guard case .success(let imported) = result else {
                return XCTFail("Override-Extremadresse wurde nicht benannt übernommen")
            }
            XCTAssertFalse(imported.layers.isEmpty)
            XCTAssertTrue(
                imported.findings.contains {
                    if case .droppedOutsideOverride = $0 { return true }
                    if case .dormantOverrides = $0 { return true }
                    return false
                },
                "Override-Extremadresse muss einen benannten Befund liefern"
            )
        }
    }

    func testExtremeCartesianCellsAreNamedAddressFindingsWithoutOverflow() throws {
        let cells = [
            MetricGridCell(column: Int.max, row: 0),
            MetricGridCell(column: 0, row: Int.max),
            MetricGridCell(column: Int.min, row: 0),
            MetricGridCell(column: 0, row: Int.min)
        ]

        for cell in cells {
            let result = CompatibilityImporter.read(try legacyData(cells: [cell]))
            guard case .success(let imported) = result else {
                return XCTFail("Kartesische Extremzelle wurde nicht benannt übernommen")
            }
            XCTAssertTrue(
                imported.findings.contains {
                    if case .cartesianAddress = $0 { return true }
                    return false
                },
                "Kartesische Extremzelle braucht einen cartesianAddress-Befund"
            )
        }
    }

    private func legacyData(
        cells: Set<MetricGridCell> = [],
        polarCells: [(Int, Int)] = [],
        polarOverrides: [(Int, Int)] = []
    ) throws -> Data {
        let layerID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let layer = LegacyRingLayer(
            id: layerID,
            cells: cells,
            polarCells: polarCells.map { RawPolarAddress(ring: $0.0, angularIndex: $0.1) },
            polarCellOverrides: polarOverrides.map { (RawPolarAddress(ring: $0.0, angularIndex: $0.1), []) }
        )
        let document = LegacyRingDocument(
            grid: .halfMeter,
            layers: [layer],
            selectedLayerID: layerID
        )
        let encoded = try JSONEncoder().encode(document)
        let workspace = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(withJSONObject: [
            "formatVersion": 3,
            "spatialWorkspace": workspace
        ])
    }
}

private struct LegacyRingDocument: Encodable {
    let grid: MetricSquareGrid
    let layers: [LegacyRingLayer]
    let selectedLayerID: UUID
}

private struct LegacyRingLayer: Encodable {
    let id: UUID
    let name = "Extremtest"
    let color = SpatialLayerColor.orange
    let isVisible = true
    let isActive = true
    let isLocked = false
    let isSoloed = false
    let cells: Set<MetricGridCell>
    let polarCells: [RawPolarAddress]
    let routings: [SpatialRouting] = []
    let cellOverrides: [MetricGridCell: [SpatialCellAction]] = [:]
    let polarCellOverrides: [(RawPolarAddress, [SpatialCellAction])]

    private enum CodingKeys: String, CodingKey {
        case id, name, color, isVisible, isActive, isLocked, isSoloed
        case cells, polarCells, routings, cellOverrides, polarCellOverrides
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(color, forKey: .color)
        try values.encode(isVisible, forKey: .isVisible)
        try values.encode(isActive, forKey: .isActive)
        try values.encode(isLocked, forKey: .isLocked)
        try values.encode(isSoloed, forKey: .isSoloed)
        try values.encode(cells, forKey: .cells)
        try values.encode(polarCells, forKey: .polarCells)
        try values.encode(routings, forKey: .routings)
        // The old reader treats this optional dictionary as absent in the
        // polar-only legacy form; omitting it keeps the fixture minimal.
        try values.encode(RawPolarOverrideDictionary(values: polarCellOverrides), forKey: .polarCellOverrides)
    }
}

private struct RawPolarAddress: Encodable {
    let ring: Int
    let angularIndex: Int

    init(ring: Int, angularIndex: Int) { self.ring = ring; self.angularIndex = angularIndex }
}

private struct RawPolarOverrideDictionary: Encodable {
    let values: [(RawPolarAddress, [SpatialCellAction])]

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for (key, actions) in values {
            try container.encode(key)
            try container.encode(actions)
        }
    }
}
