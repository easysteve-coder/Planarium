import Foundation
import XCTest
import SickPLSControlCore
import SickPLSCore
@testable import PlanariumDomain

enum CompiledBudgetScenarioFixtures {
    struct Scenario {
        let name: String
        let layers: [SpatialDocumentLayer]
        let expectedLayerCount: Int
        let expectedIndexedAddressCount: Int
        let expectedMaxEntriesPerTick: Int
        let expectedRoutingPlanCount: Int
        let expectedEstimatedIndexBytes: Int
    }

    static let full = Scenario(
        name: "S1 voll", layers: makeFullLayers(), expectedLayerCount: 256,
        expectedIndexedAddressCount: 1_048_576,
        expectedMaxEntriesPerTick: 3_328,
        expectedRoutingPlanCount: 4_096,
        expectedEstimatedIndexBytes: 8_388_608
    )

    static let column = Scenario(
        name: "S2 Spalte", layers: makeColumnLayers(), expectedLayerCount: 20,
        expectedIndexedAddressCount: 8_400,
        expectedMaxEntriesPerTick: 400,
        expectedRoutingPlanCount: 320,
        expectedEstimatedIndexBytes: 67_200
    )

    static let empty = Scenario(
        name: "S3 leer", layers: makeEmptyLayers(), expectedLayerCount: 256,
        expectedIndexedAddressCount: 0,
        expectedMaxEntriesPerTick: 0,
        expectedRoutingPlanCount: 4_096,
        expectedEstimatedIndexBytes: 0
    )

    static let all: [Scenario] = [full, column, empty]

    fileprivate static let cachedDocuments: [String: SpatialDocument] = {
        Dictionary(uniqueKeysWithValues: all.map { scenario in
            (scenario.name, try! makeDocument(for: scenario))
        })
    }()

    fileprivate static let cachedInstruments: [String: CompiledInstrument] = {
        Dictionary(uniqueKeysWithValues: all.map { scenario in
            (scenario.name, try! SpatialInstrumentCompiler.compile(
                cachedDocuments[scenario.name]!, revision: revision(for: scenario)))
        })
    }()

    static func document(for scenario: Scenario) throws -> SpatialDocument {
        cachedDocuments[scenario.name]!
    }

    static func compiled(for scenario: Scenario) -> CompiledInstrument {
        cachedInstruments[scenario.name]!
    }

    static func prewarm() {
        _ = cachedInstruments
    }

    private static func makeDocument(for scenario: Scenario) throws -> SpatialDocument {
        try SpatialDocument(
            latticeVersion: .polarDeviceV2,
            layers: scenario.layers,
            selectedLayerID: try XCTUnwrap(scenario.layers.first?.id)
        )
    }

    static func revision(for scenario: Scenario) -> SpatialDocumentRevision {
        SpatialDocumentRevision(testCounter: UInt64(all.firstIndex { $0.name == scenario.name }! + 1))
    }

    static func usableHandMeasurements() throws -> [DeviceTickMeasurement] {
        try usableHandMeasurements(ticks: 0..<20)
    }

    static func usableHandMeasurements(ticks: Range<Int>) throws -> [DeviceTickMeasurement] {
        let profile = try handProfile(ticks: ticks)
        return try FullScanProfileAdapter.measurements(from: profile)
    }

    static func handProfile(ticks: Range<Int> = 0..<20) throws -> B0ScanProfile {
        try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: (0..<361).map { tick in
                try! B0ScanProfile.Measurement.build(
                    value: ticks.contains(tick) ? 80 : B0ScanProfile.measurementValueMaximum,
                    fieldFlags: 0
                )
            }
        )
    }

    static func emptyProfile() throws -> B0ScanProfile {
        try B0ScanProfile.build(partialScanIndex: 0, measurements: [])
    }

    static func unusableProfile() throws -> B0ScanProfile {
        try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: (0..<361).map { _ in
                try! B0ScanProfile.Measurement.build(
                    value: B0ScanProfile.measurementValueMaximum, fieldFlags: 0)
            }
        )
    }

    static func documentWithOneExtraAddress(in scenario: Scenario) throws -> SpatialDocument {
        var layers = scenario.layers
        let last = try XCTUnwrap(layers.indices.last)
        let layer = layers[last]
        let extra = try XCTUnwrap(PolarDeviceLattice(ring: 201, sector: 0))
        layers[last] = SpatialDocumentLayer(
            id: layer.id, name: layer.name, color: layer.color,
            isVisible: layer.isVisible, isActive: layer.isActive,
            isLocked: layer.isLocked, isSoloed: layer.isSoloed,
            cells: layer.cells.union([extra]), routings: layer.routings,
            cellOverrides: layer.cellOverrides
        )
        return try SpatialDocument(
            latticeVersion: .polarDeviceV2, layers: layers,
            selectedLayerID: try XCTUnwrap(layers.first?.id))
    }

    static func documentWithOneExtraRouting(in scenario: Scenario) throws -> SpatialDocument {
        var layers = scenario.layers
        let last = try XCTUnwrap(layers.indices.last)
        let layer = layers[last]
        var routings = layer.routings
        routings.append(SpatialRouting(
            id: uuid(999_999), target: .midiNote(channel: 0), program: .constant(1)))
        layers[last] = SpatialDocumentLayer(
            id: layer.id, name: layer.name, color: layer.color,
            isVisible: layer.isVisible, isActive: layer.isActive,
            isLocked: layer.isLocked, isSoloed: layer.isSoloed,
            cells: layer.cells, routings: routings, cellOverrides: layer.cellOverrides
        )
        return try SpatialDocument(
            latticeVersion: .polarDeviceV2, layers: layers,
            selectedLayerID: try XCTUnwrap(layers.first?.id))
    }

    private static func makeFullLayers() -> [SpatialDocumentLayer] {
        let cells = fullCells()
        return (0..<256).map { layerIndex in
            makeLayer(index: layerIndex, cells: cells,
                      routingCount: 16, withNoteOverrides: true)
        }
    }

    private static func makeColumnLayers() -> [SpatialDocumentLayer] {
        let cells = Set((80...99).flatMap { ring in
            (170...190).compactMap { PolarDeviceLattice(ring: ring, sector: $0) }
        })
        return (0..<20).map { layerIndex in
            makeLayer(index: layerIndex, cells: cells,
                      routingCount: 16, withNoteOverrides: false)
        }
    }

    private static func makeEmptyLayers() -> [SpatialDocumentLayer] {
        (0..<256).map { layerIndex in
            makeLayer(index: layerIndex, cells: [],
                      routingCount: 16, withNoteOverrides: false)
        }
    }

    private static func fullCells() -> Set<PolarDeviceLattice> {
        var cells = Set((0..<20).compactMap { PolarDeviceLattice(ring: 80, sector: $0) })
        var index = 0
        while cells.count < 4_096 {
            let ring = 1 + index % 200
            let tick = (index * 137) % 361
            if let cell = PolarDeviceLattice(ring: ring, sector: tick) {
                cells.insert(cell)
            }
            index += 1
        }
        return cells
    }

    private static func makeLayer(
        index: Int, cells: Set<PolarDeviceLattice>, routingCount: Int,
        withNoteOverrides: Bool
    ) -> SpatialDocumentLayer {
        let routings = (0..<routingCount).map { routingIndex in
            SpatialRouting(
                id: uuid(index * 16 + routingIndex + 1),
                target: .midiNote(channel: 0), program: .constant(1))
        }
        let overrides: [PolarDeviceLattice: [SpatialCellAction]]
        if withNoteOverrides {
            overrides = Dictionary(uniqueKeysWithValues: cells.map { cell in
                (cell, [SpatialCellAction(
                    target: .midiNote(channel: 0),
                    value: .note(number: 60, velocity: 100))])
            })
        } else {
            overrides = [:]
        }
        return SpatialDocumentLayer(
            id: uuid(index + 1), name: "Szenario \(index)", color: .orange,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: cells, routings: routings, cellOverrides: overrides)
    }

    private static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", value))!
    }
}

// Die deterministische Testgrundlage wird vor dem XCTest-Testzeitraum gebaut;
// die Smoke-Tests selbst bleiben ungetimt.
private let compiledBudgetScenarioEagerCache = CompiledBudgetScenarioFixtures.cachedInstruments
