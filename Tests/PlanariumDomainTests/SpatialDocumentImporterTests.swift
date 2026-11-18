import XCTest
import Foundation
import SickPLSControlCore
@testable import PlanariumDomain

final class SpatialDocumentImporterTests: XCTestCase {
    private let a60 = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 60, velocity: 100))
    private let a67 = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 67, velocity: 100))

    private func root(workspace: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "formatVersion": 3,
            "spatialWorkspace": try JSONSerialization.jsonObject(with: workspace)
        ])
    }

    private func legacyRoot(_ layers: [LegacyLayerDocument], selected: UUID? = nil) throws -> Data {
        let values = try layers.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        let grid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MetricSquareGrid.halfMeter))
        let id = selected ?? layers[0].id
        let workspace = try JSONSerialization.data(withJSONObject: [
            "grid": grid, "layers": values, "selectedLayerID": id.uuidString,
            "coordinateMode": "cartesian"
        ])
        return try root(workspace: workspace)
    }

    private func polarRoot(_ layers: [SpatialInstrumentLayer], selected: UUID? = nil) throws -> Data {
        let values = try layers.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        let grid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MetricSquareGrid.halfMeter))
        let id = selected ?? layers[0].id
        let workspace = try JSONSerialization.data(withJSONObject: [
            "grid": grid, "layers": values, "selectedLayerID": id.uuidString,
            "coordinateMode": "polar"
        ])
        return try root(workspace: workspace)
    }

    private func mixedRoot(
        cartesian: LegacyLayerDocument, polarCells: Set<PolarMetricGridCell>,
        polarOverrides: [PolarMetricGridCell: [SpatialCellAction]]
    ) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cartesian)) as? [String: Any])
        let polar = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SpatialInstrumentLayer(id: cartesian.id, name: cartesian.name, color: cartesian.color,
                                  polarCells: polarCells, polarCellOverrides: polarOverrides)
        )) as? [String: Any])
        object["polarCells"] = polar["polarCells"]
        object["polarCellOverrides"] = polar["polarCellOverrides"]
        let grid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MetricSquareGrid.halfMeter))
        let workspace = try JSONSerialization.data(withJSONObject: [
            "grid": grid, "layers": [object], "selectedLayerID": cartesian.id.uuidString,
            "coordinateMode": "cartesian"
        ])
        return try root(workspace: workspace)
    }

    private func imported(_ data: Data) throws -> CompatibilityImport {
        guard case .success(let value) = CompatibilityImporter.read(data) else {
            XCTFail("Legacy-Import muss erfolgreich sein")
            throw NSError(domain: "SpatialDocumentImporterTests", code: 1)
        }
        return value
    }

    func testT1CartesianFixtureImports2250Actions() throws {
        let cell = MetricGridCell(column: 0, row: 2)
        let layer = LegacyLayerDocument(name: "fixture", color: .orange,
                                        cells: [cell], cellOverrides: [cell: [a60]])
        let compatibility = try imported(try legacyRoot([layer]))
        guard case .success(let result) = SpatialDocumentImporter.document(from: compatibility),
              let document = result.document else { return XCTFail("Import muss erfolgreich sein") }
        XCTAssertEqual(document.layers[0].cells.count, 2250)
        XCTAssertEqual(document.layers[0].cellOverrides.count, 2250)
        XCTAssertTrue(document.layers[0].cellOverrides.values.allSatisfy { $0 == [a60] })
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testT2CartesianOwnersWithEqualActionsAdoptOnce() throws {
        let c1 = MetricGridCell(column: 1, row: 6), c2 = MetricGridCell(column: 2, row: 6)
        let layer = LegacyLayerDocument(name: "cc", color: .orange, cells: [c1, c2],
                                        cellOverrides: [c1: [a60], c2: [a60]])
        let compatibility = try imported(try legacyRoot([layer]))
        guard case .success(let result) = SpatialDocumentImporter.document(from: compatibility),
              let document = result.document else { return XCTFail("Import muss erfolgreich sein") }
        XCTAssertEqual(document.layers[0].cellOverrides.count, 1100)
        XCTAssertTrue(document.layers[0].cellOverrides.values.allSatisfy { $0 == [a60] })
    }

    func testT3CartesianOwnersDifferentActionsAreNamedConflicts() throws {
        let c1 = MetricGridCell(column: 1, row: 6), c2 = MetricGridCell(column: 2, row: 6)
        let layer = LegacyLayerDocument(name: "cc", color: .orange, cells: [c1, c2],
                                        cellOverrides: [c1: [a60], c2: [a67]])
        let compatibility = try imported(try legacyRoot([layer]))
        guard case .failure(.overrideConflicts(let conflicts)) = SpatialDocumentImporter.document(from: compatibility) else {
            return XCTFail("Erwartete Konflikte")
        }
        XCTAssertEqual(conflicts.count, 1100)
        XCTAssertEqual(conflicts[0].cell, PolarDeviceLattice(ring: 300, sector: 203))
        XCTAssertEqual(conflicts[0].owners.map(\.origin), [.cartesian(c1), .cartesian(c2)])
        XCTAssertEqual(conflicts[0].owners.map(\.polarAddress), [PolarMetricGridCell(ring: 6, angularIndex: 17), PolarMetricGridCell(ring: 6, angularIndex: 17)])
    }

    func testT4CartesianOwnerAgainstFallbackConflicts() throws {
        let c1 = MetricGridCell(column: 1, row: 6), c2 = MetricGridCell(column: 2, row: 6)
        let layer = LegacyLayerDocument(name: "cc", color: .orange, cells: [c1, c2],
                                        cellOverrides: [c1: [a60]])
        let compatibility = try imported(try legacyRoot([layer]))
        guard case .failure(.overrideConflicts(let conflicts)) = SpatialDocumentImporter.document(from: compatibility) else {
            return XCTFail("Erwartete Fallback-Konflikte")
        }
        XCTAssertEqual(conflicts.count, 1100)
        XCTAssertEqual(conflicts[0].owners.map(\.actions), [[a60], nil])
    }

    func testT5CartesianAndPolarEqualActionsAdoptOnce() throws {
        let c = MetricGridCell(column: 0, row: 2)
        let layer = LegacyLayerDocument(name: "mixed", color: .orange, cells: [c], cellOverrides: [c: [a60]])
        let polar = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let compatibility = try imported(try mixedRoot(cartesian: layer, polarCells: [polar], polarOverrides: [polar: [a60]]))
        guard case .success(let result) = SpatialDocumentImporter.document(from: compatibility), let document = result.document else {
            return XCTFail("Gemischter Import muss erfolgreich sein")
        }
        XCTAssertEqual(document.layers[0].cellOverrides.count, 2250)
        XCTAssertTrue(document.layers[0].cellOverrides.values.allSatisfy { $0 == [a60] })
    }

    func testT6CartesianAndPolarDifferentActionsConflict() throws {
        let c = MetricGridCell(column: 0, row: 2)
        let layer = LegacyLayerDocument(name: "mixed", color: .orange, cells: [c], cellOverrides: [c: [a60]])
        let polar = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let compatibility = try imported(try mixedRoot(cartesian: layer, polarCells: [polar], polarOverrides: [polar: [a67]]))
        guard case .failure(.overrideConflicts(let conflicts)) = SpatialDocumentImporter.document(from: compatibility) else {
            return XCTFail("Erwartete gemischte Konflikte")
        }
        XCTAssertEqual(conflicts.count, 2250)
        XCTAssertEqual(conflicts[0].owners.map(\.origin), [.polar(polar), .cartesian(c)])
    }

    func testT7CartesianAndPolarFallbackConflict() throws {
        let c = MetricGridCell(column: 0, row: 2)
        let layer = LegacyLayerDocument(name: "mixed", color: .orange, cells: [c])
        let polar = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let compatibility = try imported(try mixedRoot(cartesian: layer, polarCells: [polar], polarOverrides: [polar: [a60]]))
        guard case .failure(.overrideConflicts(let conflicts)) = SpatialDocumentImporter.document(from: compatibility) else {
            return XCTFail("Erwartete Fallback-Konflikte")
        }
        XCTAssertEqual(conflicts.count, 2250)
        XCTAssertEqual(conflicts[0].owners.map(\.actions), [[a60], nil])
    }

    func testT8ReversedOwnerOrderHasIdenticalResult() throws {
        let c1 = MetricGridCell(column: 1, row: 6), c2 = MetricGridCell(column: 2, row: 6)
        let address = PolarMetricGridCell(ring: 6, angularIndex: 17)
        let first = LegacyOverrideOwner(origin: .cartesian(c1), polarAddress: address, actions: [a60])
        let second = LegacyOverrideOwner(origin: .cartesian(c2), polarAddress: address, actions: [a67])
        let forward = try LegacyOverrideMigration.migrate(owners: [first, second], in: .halfMeter)
        let reverse = try LegacyOverrideMigration.migrate(owners: [second, first], in: .halfMeter)
        XCTAssertEqual(Set(forward.unplacedOwners.map { $0.owner.origin }),
                       Set(reverse.unplacedOwners.map { $0.owner.origin }))
        XCTAssertTrue(forward.unplacedOwners.allSatisfy { $0.reason == .fullyOutsideScannerField })
        XCTAssertTrue(reverse.unplacedOwners.allSatisfy { $0.reason == .fullyOutsideScannerField })
    }

    func testT9DormantCartesianOverrideIsResolvedOrNamed() throws {
        let painted = MetricGridCell(column: 0, row: 2)
        let dormant = MetricGridCell(column: 1, row: 2)
        let layer = LegacyLayerDocument(name: "dormant", color: .orange, cells: [painted],
                                        cellOverrides: [dormant: [a60]])
        let compatibility = try imported(try legacyRoot([layer]))
        guard case .success(let imported) = SpatialDocumentImporter.document(from: compatibility),
              let document = imported.document else {
            return XCTFail("Konfliktfreie ruhende Belegung muss erhalten bleiben")
        }
        XCTAssertTrue(document.layers[0].cellOverrides.values.contains { $0 == [a60] })
    }

    func testU1PaintedPolarOverrideOutsideScannerIsRejectedWithReason() throws {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 7)
        let layer = SpatialInstrumentLayer(name: "bemalt", color: .orange,
                                           polarCells: [cell], polarCellOverrides: [cell: [a60]])
        let compatibility = try imported(try polarRoot([layer]))
        guard case .success(let result) = SpatialDocumentImporter.document(from: compatibility),
              let document = result.document else {
            return XCTFail("H1 muss trotz entfallener Belegung importierbar sein")
        }
        XCTAssertTrue(document.layers[0].cellOverrides.isEmpty)
        XCTAssertEqual(result.findings.filter {
            if case .droppedOutsideOverride(layerIndex: 0, owner: let owner, reason: .fullyOutsideScannerField) = $0 {
                return owner.origin == .polar(cell) && owner.actions == [a60]
            }
            return false
        }.count, 1)
    }

    func testU2PaintedCartesianOverrideOutsideScannerIsRejectedWithReason() throws {
        let cell = try XCTUnwrap((-170...170).flatMap { column in
            (0...170).map { row in MetricGridCell(column: column, row: row) }
        }.first { candidate in
            guard let address = try? LegacyCartesianAddress.polarCell(atCenterOf: candidate, in: .halfMeter),
                  let migration = try? LegacyLatticeMigration.migrate(address, in: .halfMeter)
            else { return false }
            return migration.cells.isEmpty
        })
        let layer = LegacyLayerDocument(name: "kartesisch", color: .orange,
                                        cells: [cell], cellOverrides: [cell: [a60]])
        let compatibility = try imported(try legacyRoot([layer]))
        guard case .failure(.unplaceableOverrides(let cases)) = SpatialDocumentImporter.document(from: compatibility) else {
            return XCTFail("U2 muss eine unplatzierbare kartesische Belegung melden")
        }
        XCTAssertEqual(cases.count, 1)
        XCTAssertEqual(cases[0].reason, .noValidDeviceProbe)
        XCTAssertEqual(cases[0].owner.origin, .cartesian(cell))
    }

    func testU3PaintedPolarWithoutOverrideRemainsMaskLossOnly() throws {
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 7)
        let layer = SpatialInstrumentLayer(name: "bemalt", color: .orange, polarCells: [cell])
        let compatibility = try imported(try polarRoot([layer]))
        guard case .success(let result) = SpatialDocumentImporter.document(from: compatibility) else {
            return XCTFail("U3 ohne Belegung muss erfolgreich sein")
        }
        XCTAssertEqual(result.findings.filter {
            if case .fullyLost(layerIndex: 0, cell: cell, rasterCentimeters: _, reason: _) = $0 { return true }
            return false
        }.count, 1)
        XCTAssertFalse(result.findings.contains {
            if case .droppedOutsideOverride = $0 { return true }
            return false
        })
    }

    func testH4DroppedOutsideDoesNotHideWouldActivate() throws {
        let outside = PolarMetricGridCell(ring: 3, angularIndex: 7)
        let painted = PolarMetricGridCell(ring: 0, angularIndex: 2)
        let dormant = PolarMetricGridCell(ring: 0, angularIndex: 3)
        let layer = SpatialInstrumentLayer(name: "gemischt", color: .orange,
                                           polarCells: [outside, painted],
                                           polarCellOverrides: [outside: [a60], dormant: [a67]])
        let compatibility = try imported(try polarRoot([layer]))
        guard case .success(let imported) = SpatialDocumentImporter.document(from: compatibility),
              let document = imported.document else {
            return XCTFail("H4 darf benachbarte reine Polarzellen nicht als Aktivierungskonflikt behandeln")
        }
        XCTAssertEqual(document.layers[0].cellOverrides.count, 4410)
        XCTAssertEqual(compatibility.findings.filter {
            if case .droppedOutsideOverride = $0 { return true }
            return false
        }.count, 1)
    }

    func testH5DroppedOutsideFindingsAreSourceOrderIndependent() throws {
        let first = PolarMetricGridCell(ring: 3, angularIndex: 7)
        let second = PolarMetricGridCell(ring: 3, angularIndex: 6)
        let layerA = SpatialInstrumentLayer(name: "verluste", color: .orange,
                                            polarCells: [first, second],
                                            polarCellOverrides: [first: [a60], second: [a67]])
        let layerB = SpatialInstrumentLayer(name: "verluste", color: .orange,
                                            polarCells: [second, first],
                                            polarCellOverrides: [second: [a67], first: [a60]])
        let firstImport = try imported(try polarRoot([layerA]))
        let secondImport = try imported(try polarRoot([layerB]))
        XCTAssertEqual(firstImport.findings, secondImport.findings)
    }

    func testU5CachedUnplacedOwnersCarrySameReason() throws {
        let address = PolarMetricGridCell(ring: 3, angularIndex: 7)
        let first = LegacyOverrideOwner(origin: .polar(address), polarAddress: address, actions: [a60])
        let second = LegacyOverrideOwner(origin: .cartesian(MetricGridCell(column: 0, row: 0)), polarAddress: address, actions: [a67])
        let result = try LegacyOverrideMigration.migrate(owners: [first, second], in: .halfMeter)
        XCTAssertEqual(result.unplacedOwners.map(\.reason), [.fullyOutsideScannerField, .fullyOutsideScannerField])
    }

    func testU6ReorderedUnplaceableOwnersAreIdentical() throws {
        let address = PolarMetricGridCell(ring: 3, angularIndex: 7)
        let first = LegacyOverrideOwner(origin: .polar(address), polarAddress: address, actions: [a60])
        let second = LegacyOverrideOwner(origin: .cartesian(MetricGridCell(column: 0, row: 0)), polarAddress: address, actions: [a67])
        let forward = try LegacyOverrideMigration.migrate(owners: [first, second], in: .halfMeter)
        let reverse = try LegacyOverrideMigration.migrate(owners: [second, first], in: .halfMeter)
        XCTAssertEqual(Set(forward.unplacedOwners.map { $0.owner.origin }),
                       Set(reverse.unplacedOwners.map { $0.owner.origin }))
        XCTAssertTrue(forward.unplacedOwners.allSatisfy { $0.reason == .fullyOutsideScannerField })
        XCTAssertTrue(reverse.unplacedOwners.allSatisfy { $0.reason == .fullyOutsideScannerField })
    }

    func testT1DormantPolarOverrideSurvivesUnpainted() throws {
        let painted = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let dormant = PolarMetricGridCell(ring: 0, angularIndex: 3)
        let layer = SpatialInstrumentLayer(name: "ruhig", color: .orange,
                                           polarCells: [painted],
                                           polarCellOverrides: [dormant: [a67]])
        let compatibility = try imported(try polarRoot([layer]))
        guard case .success(let result) = SpatialDocumentImporter.document(from: compatibility),
              let document = result.document else { return XCTFail("T1 muss importierbar sein") }
        XCTAssertEqual(document.layers[0].cells.count, 2250)
        XCTAssertEqual(document.layers[0].cellOverrides.count, 4410)
        XCTAssertTrue(document.layers[0].cells.intersection(document.layers[0].cellOverrides.keys).isEmpty)
    }

    func testT2DormantPolarOverrideWouldActivateIsNamed() throws {
        let painted = PolarMetricGridCell(ring: 0, angularIndex: 2)
        let dormant = PolarMetricGridCell(ring: 0, angularIndex: 3)
        let layer = SpatialInstrumentLayer(name: "ruhig", color: .orange,
                                           polarCells: [painted],
                                           polarCellOverrides: [dormant: [a67]])
        let compatibility = try imported(try polarRoot([layer]))
        guard case .success(let imported) = SpatialDocumentImporter.document(from: compatibility),
              let document = imported.document else {
            return XCTFail("T2 darf benachbarte reine Polarzellen nicht als Aktivierungskonflikt behandeln")
        }
        XCTAssertEqual(document.layers[0].cellOverrides.count, 4410)
    }

    func testT3CartesianPaintedAgainstDormantPolarIsNamed() throws {
        let painted = MetricGridCell(column: 0, row: 2)
        let dormant = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let layer = LegacyLayerDocument(name: "gemischt", color: .orange, cells: [painted])
        let compatibility = try imported(try mixedRoot(cartesian: layer, polarCells: [], polarOverrides: [dormant: [a60]]))
        guard case .failure(.unresolvedDormantOverrides(let cases)) = SpatialDocumentImporter.document(from: compatibility) else {
            return XCTFail("T3 muss 2250 Aktivierungen benennen")
        }
        XCTAssertEqual(cases.count, 2250)
    }

    func testT4DormantCartesianOwnersEqualOrConflict() throws {
        let c1 = MetricGridCell(column: 1, row: 6), c2 = MetricGridCell(column: 2, row: 6)
        let equal = LegacyLayerDocument(name: "ruhig", color: .orange,
                                        cellOverrides: [c1: [a60], c2: [a60]])
        let equalCompatibility = try imported(try legacyRoot([equal]))
        guard case .success(let equalImport) = SpatialDocumentImporter.document(from: equalCompatibility),
              let equalDocument = equalImport.document else { return XCTFail("T4 gleich muss importierbar sein") }
        XCTAssertTrue(equalDocument.layers[0].cells.isEmpty)
        XCTAssertEqual(equalDocument.layers[0].cellOverrides.count, 1100)
        XCTAssertTrue(equalDocument.layers[0].cellOverrides.values.allSatisfy { $0 == [a60] })

        let different = LegacyLayerDocument(name: "ruhig", color: .orange,
                                            cellOverrides: [c1: [a60], c2: [a67]])
        let differentCompatibility = try imported(try legacyRoot([different]))
        guard case .failure(.unresolvedDormantOverrides(let cases)) = SpatialDocumentImporter.document(from: differentCompatibility) else {
            return XCTFail("T4 verschiedene Listen müssen Konflikte benennen")
        }
        XCTAssertEqual(cases.count, 1100)
        XCTAssertTrue(cases.allSatisfy {
            if case .conflict = $0.issue { return true }
            return false
        })
    }

    func testT5DormantCartesianAndPolarAreDeterministic() throws {
        let cartesian = MetricGridCell(column: 1, row: 6)
        let polar = PolarMetricGridCell(ring: 6, angularIndex: 17)
        let equalLayer = LegacyLayerDocument(name: "gemischt", color: .orange,
                                             cellOverrides: [cartesian: [a60]])
        let equalCompatibility = try imported(try mixedRoot(cartesian: equalLayer, polarCells: [], polarOverrides: [polar: [a60]]))
        guard case .success(let equalImport) = SpatialDocumentImporter.document(from: equalCompatibility),
              let equalDocument = equalImport.document else { return XCTFail("T5 gleich muss importierbar sein") }
        XCTAssertEqual(equalDocument.layers[0].cellOverrides.count, 1100)

        let differentLayer = LegacyLayerDocument(name: "gemischt", color: .orange,
                                                 cellOverrides: [cartesian: [a60]])
        let differentCompatibility = try imported(try mixedRoot(cartesian: differentLayer, polarCells: [], polarOverrides: [polar: [a67]]))
        guard case .failure(.unresolvedDormantOverrides(let cases)) = SpatialDocumentImporter.document(from: differentCompatibility) else {
            return XCTFail("T5 verschiedene Listen müssen Konflikte benennen")
        }
        XCTAssertEqual(cases.count, 1100)

        let reversed = try imported(try mixedRoot(cartesian: equalLayer, polarCells: [], polarOverrides: [polar: [a60]]))
        XCTAssertEqual(equalCompatibility, reversed)
    }

    func testT6DormantPolarOutsideScannerIsUnplaceable() throws {
        let dormant = PolarMetricGridCell(ring: 3, angularIndex: 7)
        let layer = SpatialInstrumentLayer(name: "hinter Scanner", color: .orange,
                                           polarCells: [], polarCellOverrides: [dormant: [a60]])
        let compatibility = try imported(try polarRoot([layer]))
        guard case .success(let result) = SpatialDocumentImporter.document(from: compatibility),
              let document = result.document else {
            return XCTFail("H2 muss trotz entfallener ruhender Belegung importierbar sein")
        }
        XCTAssertTrue(document.layers[0].cellOverrides.isEmpty)
        XCTAssertEqual(result.findings.filter {
            if case .droppedOutsideOverride(layerIndex: 0, owner: let owner, reason: .fullyOutsideScannerField) = $0 {
                return owner.origin == .polar(dormant) && owner.actions == [a60]
            }
            return false
        }.count, 1)
    }

    func testT7DocumentRoundTripPreservesDormantOverride() throws {
        let painted = PolarMetricGridCell(ring: 2, angularIndex: 8)
        let dormant = PolarMetricGridCell(ring: 0, angularIndex: 3)
        let layer = SpatialInstrumentLayer(name: "ruhig", color: .orange,
                                           polarCells: [painted], polarCellOverrides: [dormant: [a67]])
        let compatibility = try imported(try polarRoot([layer]))
        guard case .success(let result) = SpatialDocumentImporter.document(from: compatibility),
              let document = result.document else { return XCTFail("T7 Ausgangsdokument fehlt") }
        XCTAssertEqual(try JSONDecoder().decode(SpatialDocument.self, from: JSONEncoder().encode(document)), document)

        let overrideCell = try XCTUnwrap(PolarDeviceLattice(ring: 57, sector: 359))
        let handLayer = SpatialDocumentLayer(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            name: "Hand", color: .orange, isVisible: true, isActive: true,
            isLocked: false, isSoloed: false, cells: [], routings: [],
            cellOverrides: [overrideCell: [a60]]
        )
        let hand = try SpatialDocument(latticeVersion: .polarDeviceV2,
                                       layers: [handLayer], selectedLayerID: handLayer.id)
        let handRoundTrip = try JSONDecoder().decode(
            SpatialDocument.self, from: JSONEncoder().encode(hand)
        )
        XCTAssertEqual(handRoundTrip, hand)
        XCTAssertEqual(handRoundTrip.layers[0].cellOverrides[overrideCell], [a60])
        XCTAssertTrue(handRoundTrip.layers[0].cells.isEmpty)
    }

    func testT8ImportKeepsLegacySourceVerbatim() throws {
        let cell = MetricGridCell(column: 0, row: 2)
        let data = try legacyRoot([LegacyLayerDocument(name: "Quelle", color: .orange, cells: [cell])])
        let compatibility = try imported(data)
        let rootObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let workspaceData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(rootObject["spatialWorkspace"]))
        let expected = try LegacySpatialDocumentReader.read(from: workspaceData).document.layers[0]
        XCTAssertEqual(compatibility.layers[0].source, expected)
    }
}
