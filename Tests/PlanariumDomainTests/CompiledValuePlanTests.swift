import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class CompiledValuePlanTests: XCTestCase {
    private let revision = SpatialDocumentRevision(
        session: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!, counter: 7)

    private func cell(_ ring: Int, _ sector: Int) throws -> PolarDeviceLattice {
        try XCTUnwrap(PolarDeviceLattice(ring: ring, sector: sector))
    }

    private func layer(
        cells: Set<PolarDeviceLattice>, routings: [SpatialRouting],
        overrides: [PolarDeviceLattice: [SpatialCellAction]] = [:]
    ) -> SpatialDocumentLayer {
        SpatialDocumentLayer(
            id: UUID(), name: "Wertplan", color: .orange,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: cells, routings: routings, cellOverrides: overrides)
    }

    private func document(_ layer: SpatialDocumentLayer) throws -> SpatialDocument {
        try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
    }

    private func value(
        _ compiled: CompiledInstrument, at cell: PolarDeviceLattice,
        candidateDistance: Double? = nil, routingIndex: Int = 0
    ) throws -> SpatialEvaluatedValue {
        let handle = try XCTUnwrap(compiled.hits(tick: cell.sector, raw: cell.ring).first)
            .withCandidateDistance(candidateDistance)
        return try XCTUnwrap(compiled.evaluate(active: [handle.layerID: handle])[routingIndex].value)
    }

    func testW1ConstantChordAllNotesOffAndOverrideParity() throws {
        let addressed = try cell(100, 180)
        let constant = SpatialRoutingTarget.midiCC(channel: 0, controller: 1)
        let chord = SpatialRoutingTarget.midiNote(channel: 0)
        let noteOverride = SpatialCellAction(target: chord, value: .note(number: 60, velocity: 100))
        let routings = [
            SpatialRouting(target: constant, program: .constant(0.75)),
            SpatialRouting(target: chord, program: .chord(notes: [48, 55], velocity: 90, transition: .retrigger)),
            SpatialRouting(target: .midiAllNotesOff(channel: 0), program: .constant(1)),
            SpatialRouting(target: .audioUnitAllNotesOff(channel: 0, stripID: InstrumentChannel.legacyID), program: .constant(1))
        ]
        let compiled = try SpatialInstrumentCompiler.compile(
            try document(layer(cells: [addressed], routings: routings, overrides: [addressed: [noteOverride]])),
            revision: revision)
        let values = try compiled.evaluate(active: [
            compiled.layers[0].id: try XCTUnwrap(compiled.hits(tick: 180, raw: 100).first)
        ]).map { $0.value }
        XCTAssertEqual(values, [
            .scalar(0.75),
            .notes([.init(number: 60, velocity: 100)], transition: .retrigger),
            .boolean(true), .boolean(true)
        ])
        let inactive = try compiled.evaluate(active: [:]).map { $0.value }
        XCTAssertEqual(inactive, [.inactive, .notes([] , transition: .retrigger), .boolean(false), .boolean(false)])
    }

    func testW2HeldCellUsesCandidateDistanceForEveryCentimeter() throws {
        let cells = Set((1...200).compactMap { try? cell($0, 180) })
        let routing = SpatialRouting(
            target: .midiCC(channel: 0, controller: 2),
            program: .continuous(minimum: 0, maximum: 127, directionDegrees: 90, curve: .linear))
        let compiled = try SpatialInstrumentCompiler.compile(
            try document(layer(cells: cells, routings: [routing])), revision: revision)
        let held = try XCTUnwrap(compiled.hits(tick: 180, raw: 120).first)
        let values: [Double] = try (100...130).map { y in
            let result = try compiled.evaluate(active: [held.layerID: held.withCandidateDistance(Double(y))])
            guard case .scalar(let scalar) = result[0].value else {
                XCTFail("W2 scalar expected")
                return 0
            }
            return scalar
        }
        XCTAssertEqual(values.count, 31)
        XCTAssertEqual(values.first!, 127 * 99 / 199, accuracy: 0.0000001)
        XCTAssertEqual(values.last!, 127 * 129 / 199, accuracy: 0.0000001)
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, 31)
    }

    func testW3PerTickProjectionExtremaMatchIndependentBruteForce() throws {
        var state: UInt64 = 0x6A09E667F3BCC909
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        for direction in [0.0, 37.0, 90.0, 135.0, 270.0] {
            var cells = Set<PolarDeviceLattice>()
            for _ in 0..<50 {
                let ring = Int(next() % 200) + 1
                let sector = Int(next() % 361)
                cells.insert(try cell(ring, sector))
            }
            let routing = SpatialRouting(
                target: .midiCC(channel: 0, controller: 3),
                program: .continuous(minimum: 0, maximum: 1, directionDegrees: direction, curve: .linear))
            let compiled = try SpatialInstrumentCompiler.compile(
                try document(layer(cells: cells, routings: [routing])), revision: revision)
            let plan = compiled.layers[0].routings[0].valuePlan
            let sinDirection = sin(direction * .pi / 180)
            let cosDirection = cos(direction * .pi / 180)
            for tick in 0...360 {
                let projections = cells.filter { $0.sector == tick }.map { cell in
                    let bearing = (-90 + 0.5 * Double(cell.sector)) * .pi / 180
                    return Double(cell.ring) * (sin(bearing) * cosDirection + cos(bearing) * sinDirection)
                }
                if let minimum = projections.min(), let maximum = projections.max() {
                    XCTAssertEqual(plan.minimumProjectionByTick[tick], minimum, accuracy: 0.0000001)
                    XCTAssertEqual(plan.maximumProjectionByTick[tick], maximum, accuracy: 0.0000001)
                }
            }
        }
    }

    func testW4ScaleUsesActiveRingAndDescendingReversesIndex() throws {
        let cells = Set((1...200).compactMap { try? cell($0, 180) })
        func compile(_ ascending: Bool) throws -> CompiledInstrument {
            try SpatialInstrumentCompiler.compile(try document(layer(cells: cells, routings: [
                .init(target: .midiNote(channel: 0), program: .scale(
                    rootMIDINote: 0, lowestMIDINote: 0, highestMIDINote: 127,
                    scale: .chromatic, directionDegrees: 90, ascending: ascending, transition: .retrigger))
            ])), revision: revision)
        }
        let up = try compile(true); let down = try compile(false)
        func note(_ instrument: CompiledInstrument, _ ring: Int) throws -> UInt8 {
            guard case .notes(let notes, _) = try value(instrument, at: try cell(ring, 180)) else {
                XCTFail("scale note expected")
                return 0
            }
            return try XCTUnwrap(notes.first?.number)
        }
        XCTAssertEqual(try note(up, 1), 0)
        XCTAssertEqual(try note(up, 100), 63)
        XCTAssertEqual(try note(up, 200), 127)
        XCTAssertEqual(try note(down, 1), 127)
        XCTAssertEqual(try note(down, 100), 64)
        XCTAssertEqual(try note(down, 200), 0)
    }

    func testW5RandomScaleIsStableForFixedSeedSectorAndRing() throws {
        let samples: [(Int, Int, UInt64, UInt8)] = [
            (17, 23, 0x0123456789ABCDEF, 21),
            (100, 180, 0x0FEDCBA987654321, 6),
            (200, 359, 0xA5A5A5A5A5A5A5A5, 76)
        ]
        for (ring, sector, seed, expected) in samples {
            let addressed = try cell(ring, sector)
            let routing = SpatialRouting(target: .midiNote(channel: 0), program: .randomScale(
                rootMIDINote: 0, lowestMIDINote: 0, highestMIDINote: 127,
                scale: .chromatic, seed: seed, transition: .retrigger))
            let first = try SpatialInstrumentCompiler.compile(
                try document(layer(cells: [addressed], routings: [routing])), revision: revision)
            let second = try SpatialInstrumentCompiler.compile(
                try document(layer(cells: [addressed], routings: [routing])), revision: revision)
            XCTAssertEqual(try value(first, at: addressed), try value(second, at: addressed))
            guard case .notes(let notes, _) = try value(first, at: addressed), let note = notes.first?.number else {
                return XCTFail("random scale note expected")
            }
            XCTAssertEqual(note, expected)
        }
    }

    func testW6EvaluationTouchesOnlyRoutingsNotCells() throws {
        let routings = (0..<3).map { _ in
            SpatialRouting(target: .midiCC(channel: 0, controller: 4), program: .constant(1))
        }
        let one = try SpatialInstrumentCompiler.compile(
            try document(layer(cells: [try cell(1, 0)], routings: routings)), revision: revision)
        let all = Set((0..<262_144).compactMap { offset -> PolarDeviceLattice? in
            let ring = offset % PolarDeviceLattice.maxRing + 1
            let sector = offset / PolarDeviceLattice.maxRing
            return try? cell(ring, sector)
        })
        let many = try SpatialInstrumentCompiler.compile(
            try document(layer(cells: all, routings: routings)), revision: revision)
        let oneProbe = CompiledEvaluationProbe()
        let manyProbe = CompiledEvaluationProbe()
        _ = try one.evaluate(active: [:], probe: oneProbe)
        _ = try many.evaluate(active: [:], probe: manyProbe)
        XCTAssertEqual(oneProbe.touchedRoutingCount, 3)
        XCTAssertEqual(manyProbe.touchedRoutingCount, 3)
    }

}
