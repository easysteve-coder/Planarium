import SickPLSMonitorKit
import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

private let q2TestSession = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!

extension SpatialDocumentRevision {
    init(testCounter: UInt64) {
        self.init(session: q2TestSession, counter: testCounter)
    }
}

final class CompiledInstrumentTests: XCTestCase {
    private let revision = SpatialDocumentRevision(testCounter: 7)

    private func cell(_ ring: Int, _ sector: Int) throws -> PolarDeviceLattice {
        try XCTUnwrap(PolarDeviceLattice(ring: ring, sector: sector))
    }

    private func document(
        lattice: SpatialLatticeVersion = .polarDeviceV2,
        layers: [SpatialDocumentLayer]
    ) throws -> SpatialDocument {
        try SpatialDocument(latticeVersion: lattice, layers: layers, selectedLayerID: layers[0].id)
    }

    private func layer(
        id: UUID = UUID(), cells: Set<PolarDeviceLattice>, active: Bool = true,
        soloed: Bool = false, routings: [SpatialRouting] = [],
        overrides: [PolarDeviceLattice: [SpatialCellAction]] = [:],
        name: String = "Ebene"
    ) -> SpatialDocumentLayer {
        SpatialDocumentLayer(id: id, name: name, color: .orange,
                             isVisible: true, isActive: active, isLocked: false,
                             isSoloed: soloed, cells: cells, routings: routings,
                             cellOverrides: overrides)
    }

    func testP1PhysicalM0AddressRangeAndHits() throws {
        let cells = Set((100...149).flatMap { ring in (180...224).compactMap { try? cell(ring, $0) } })
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let doc = try document(layers: [layer(cells: cells, routings: [.init(target: target, program: .constant(1))])])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)

        XCTAssertEqual(compiled.statistics.indexedAddressCount, 2_250)
        XCTAssertEqual(compiled.hits(tick: 180, raw: 100).map(\.cell), [try cell(100, 180)])
        XCTAssertEqual(compiled.hits(tick: 224, raw: 149).map(\.cell), [try cell(149, 224)])
        XCTAssertEqual(compiled.hits(tick: 200, raw: 120).map(\.cell), [try cell(120, 200)])
        XCTAssertTrue(compiled.hits(tick: 179, raw: 120).isEmpty)
        XCTAssertTrue(compiled.hits(tick: 225, raw: 120).isEmpty)
        XCTAssertTrue(compiled.hits(tick: 200, raw: 99).isEmpty)
        XCTAssertTrue(compiled.hits(tick: 200, raw: 150).isEmpty)
    }

    func testG2LegacyM0ReachesCompilerOnlyThroughImporterAndDocument() throws {
        let legacy = LegacyLayerDocument(
            name: "M-0", color: .orange,
            cells: [MetricGridCell(column: 0, row: 2)]
        )
        let workspace = try LegacyWorkspaceDocument.data(layer: legacy, grid: .halfMeter)
        let workspaceObject = try JSONSerialization.jsonObject(with: workspace)
        let wrapped = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 3, "spatialWorkspace": workspaceObject
        ])
        let source: CompatibilityImport
        switch CompatibilityImporter.read(wrapped) {
        case .success(let value): source = value
        case .failure(let error): XCTFail("Import fehlgeschlagen: \(error)"); return
        }
        let imported: SpatialDocument
        switch SpatialDocumentImporter.document(from: source) {
        case .success(let result): imported = try XCTUnwrap(result.document)
        case .failure(let error): XCTFail("Dokumentimport fehlgeschlagen: \(error)"); return
        }
        let compiled = try SpatialInstrumentCompiler.compile(imported, revision: revision)
        XCTAssertEqual(compiled.statistics.indexedAddressCount, 2_250)
        XCTAssertEqual(compiled.hits(tick: 180, raw: 100).count, 1)
    }

    func testP2RadialAddressDoesNotCrossLayers() throws {
        let aID = UUID(); let bID = UUID()
        let a = try cell(100, 200); let b = try cell(150, 200)
        let doc = try document(layers: [layer(id: aID, cells: [a]), layer(id: bID, cells: [b])])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)
        XCTAssertEqual(compiled.hits(tick: 200, raw: 100).map(\.layerID), [aID])
        XCTAssertEqual(compiled.hits(tick: 200, raw: 150).map(\.layerID), [bID])
        XCTAssertTrue(compiled.hits(tick: 200, raw: 125).isEmpty)
    }

    func testP3SpanChoosesSmallestPaintedTickPerLayer() throws {
        let first = try cell(120, 181); let second = try cell(120, 183)
        let doc = try document(layers: [layer(cells: [first, second])])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)
        XCTAssertEqual(compiled.hits(span: try XCTUnwrap(DeviceTickSpan(lower: 180, upper: 183)), raw: 120).map(\.cell), [first])
        XCTAssertTrue(compiled.hits(span: try XCTUnwrap(DeviceTickSpan(lower: 184, upper: 187)), raw: 120).isEmpty)
        XCTAssertTrue(compiled.hits(span: try XCTUnwrap(DeviceTickSpan(lower: 180, upper: 180)), raw: 120).isEmpty)
    }

    func testP4EligibilityAndDocumentOrder() throws {
        let firstID = UUID(); let secondID = UUID(); let thirdID = UUID()
        let first = layer(id: firstID, cells: [try cell(10, 1)], active: true)
        let second = layer(id: secondID, cells: [try cell(20, 1)], active: false)
        let third = layer(id: thirdID, cells: [try cell(30, 1)], active: true, soloed: true)
        let doc = try document(layers: [first, second, third])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)
        XCTAssertEqual(compiled.layers.map(\.id), [thirdID])
        XCTAssertEqual(compiled.hits(tick: 1, raw: 30).map(\.layerID), [thirdID])
    }

    func testP5DormantOverrideIsCountedButNotIndexed() throws {
        let dormant = try cell(80, 80)
        let action = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 60, velocity: 100))
        let doc = try document(layers: [layer(cells: [], routings: [], overrides: [dormant: [action]])])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)
        XCTAssertEqual(compiled.statistics.dormantOverrideCells, 1)
        XCTAssertEqual(compiled.statistics.indexedAddressCount, 0)
        XCTAssertTrue(compiled.hits(tick: 80, raw: 80).isEmpty)
    }

    func testP6RejectsV1AndNonFiniteValues() throws {
        let id = UUID(); let routingID = UUID()
        let base = try cell(20, 20)
        let v1 = try document(lattice: .polarDeviceV1, layers: [layer(id: id, cells: [base])])
        XCTAssertThrowsError(try SpatialInstrumentCompiler.compile(v1, revision: revision)) { error in
            XCTAssertEqual(error as? CompiledInstrumentError, .unsupportedLatticeVersion(.polarDeviceV1))
        }
        let bad = try document(layers: [layer(id: id, cells: [base], routings: [
            .init(id: routingID, target: .midiCC(channel: 0, controller: 1), program: .constant(.infinity))
        ])])
        XCTAssertThrowsError(try SpatialInstrumentCompiler.compile(bad, revision: revision)) { error in
            XCTAssertEqual(error as? CompiledInstrumentError,
                           .nonFiniteProgramValue(layerID: id, routingID: routingID))
        }
    }

    func testP7SetInsertionOrderAndRevisionAreDeterministic() throws {
        let a = try cell(100, 180); let b = try cell(101, 181)
        let target = SpatialRoutingTarget.boolean(name: "hit")
        let routing = SpatialRouting(id: UUID(), target: target, program: .constant(1))
        let first = try document(layers: [layer(cells: [a, b], routings: [routing])])
        let second = try document(layers: [layer(id: first.layers[0].id, cells: [b, a], routings: [routing])])
        let one = try SpatialInstrumentCompiler.compile(first, revision: revision)
        let two = try SpatialInstrumentCompiler.compile(second, revision: revision)
        XCTAssertEqual(one, two)
        XCTAssertNotEqual(one, try SpatialInstrumentCompiler.compile(first, revision: SpatialDocumentRevision(testCounter: 8)))
    }

    func testP8BinarySearchReportsComparisonsSeparatelyFromHits() throws {
        let cells = Set((1...8).compactMap { try? cell($0, 100) })
        let doc = try document(layers: [layer(cells: cells)])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)
        let measured = compiled.measuredHits(tick: 100, raw: 8)
        XCTAssertLessThanOrEqual(measured.comparisons, 4) // ceil(log2(8 + 1))
        XCTAssertEqual(measured.visitedEntries, 1)
        XCTAssertEqual(measured.hits.map(\.cell), [try cell(8, 100)])
    }

    func testF6RejectsDuplicateRoutingIDsAcrossLayers() throws {
        let id = UUID()
        let routingID = UUID()
        let routing = SpatialRouting(id: routingID, target: .boolean(name: "x"), program: .constant(1))
        let doc = try document(layers: [
            layer(id: id, cells: [try cell(1, 1)], routings: [routing]),
            layer(cells: [try cell(2, 2)], routings: [routing])
        ])
        XCTAssertEqual(try? SpatialInstrumentCompiler.compile(doc, revision: revision), nil)
    }

    func testF9AllActionsReduceToOneDeterministicSummaryPerTarget() throws {
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let c = try cell(20, 20)
        let actions = [
            SpatialCellAction(target: target, value: .note(number: 64, velocity: 90)),
            SpatialCellAction(target: target, value: .note(number: 60, velocity: 100)),
            SpatialCellAction(target: target, value: .chord(notes: [64, 67], velocity: 80))
        ]
        let doc = try document(layers: [layer(cells: [c], routings: [.init(target: target, program: .constant(1))], overrides: [c: actions])])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)
        XCTAssertEqual(compiled.layers[0].cellActions.count, 1)
        XCTAssertEqual(compiled.layers[0].cellActions[0].groups.count, 1)
        XCTAssertEqual(compiled.statistics.actionGroupCount, 1)
        XCTAssertEqual(
            compiled.layers[0].cellActions[0].groups[0].summary,
            .notes([.init(number: 60, velocity: 100), .init(number: 64, velocity: 80), .init(number: 64, velocity: 90), .init(number: 67, velocity: 80)])
        )
    }

    func testTenThousandOverridesKeepExactValuesWithLogarithmicRuntimeLookup() throws {
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let cells = try (100..<200).flatMap { ring in try (100..<200).map { try cell(ring, $0) } }
        let overrides = Dictionary(uniqueKeysWithValues: cells.enumerated().map { index, cell in
            (cell, [SpatialCellAction(target: target, value: .note(number: index % 128, velocity: 90))])
        })
        let doc = try document(layers: [layer(cells: Set(cells), routings: [
            .init(target: target, program: .singleNote(note: 60, velocity: 100, transition: .retrigger))
        ], overrides: overrides)])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)
        let id = doc.layers[0].id
        XCTAssertEqual(compiled.layers[0].cellActions.count, 10_000)
        let probe = CompiledEvaluationProbe()
        let start = ProcessInfo.processInfo.systemUptime
        var worst = 0
        for (index, cell) in cells.enumerated() {
            let before = probe.overrideComparisons
            let result = try compiled.evaluate(active: [id: .init(layerID: id, cell: cell, revision: revision)],
                                               activeLayerIDs: nil, probe: probe)
            XCTAssertEqual(result.first?.value, .notes([.init(number: UInt8(index % 128), velocity: 90)], transition: .retrigger))
            XCTAssertGreaterThan(probe.overrideComparisons - before, 0, "Production evaluation must use the measured lookup")
            worst = max(worst, probe.overrideComparisons - before)
        }
        XCTAssertLessThanOrEqual(worst, 14)
        print("FABLE overrides=10000 evaluations=10000 comparisons=\(probe.overrideComparisons) seconds=\(ProcessInfo.processInfo.systemUptime - start)")
        // Sparse table: a painted cell without an override falls back to its routing.
        let sparse = try document(layers: [layer(id: id, cells: Set(cells), routings: doc.layers[0].routings,
            overrides: [cells[0]: overrides[cells[0]]!, cells[9999]: overrides[cells[9999]]!])])
        let fallback = try SpatialInstrumentCompiler.compile(sparse, revision: revision)
        for cell in [cells[1], cells[5000], cells[9998]] {
            XCTAssertEqual(try fallback.evaluate(active: [id: .init(layerID: id, cell: cell, revision: revision)]).first?.value,
                           .notes([.init(number: 60, velocity: 100)], transition: .retrigger))
        }
    }

    func testQ2RevisionAPIHasNoPublicLegacyCounterEntryPoint() throws {
        let source = try String(contentsOfFile:
            "Sources/PlanariumDomain/CompiledInstrument.swift", encoding: .utf8)
        let revisionSource = String(source.split(separator: "public struct SpatialDocumentRevision", maxSplits: 1)[1])
        XCTAssertTrue(revisionSource.contains("public init(session: UUID, counter: UInt64)"))
        XCTAssertFalse(revisionSource.contains("public init(_"))
        XCTAssertFalse(revisionSource.contains("public init(rawValue:"))
        XCTAssertFalse(revisionSource.contains("public var rawValue"))
        XCTAssertFalse(revisionSource.contains("legacySession"))
    }

    func testQ1TransitionBelongsToEachRoutingNotTheSharedTargetSummary() throws {
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let addressedCell = try cell(21, 21)
        let routings = [
            SpatialRouting(target: target,
                           program: .chord(notes: [60], velocity: 100, transition: .retrigger)),
            SpatialRouting(target: target,
                           program: .chord(notes: [60], velocity: 100, transition: .legato))
        ]
        let action = SpatialCellAction(target: target, value: .chord(notes: [64], velocity: 90))
        let compiled = try SpatialInstrumentCompiler.compile(
            try document(layers: [layer(cells: [addressedCell], routings: routings,
                                        overrides: [addressedCell: [action]])]), revision: revision)

        let groups = try XCTUnwrap(compiled.layers[0].cellActions.first?.groups)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].summary, .notes([.init(number: 64, velocity: 90)]))

        func transition(of program: SpatialValueProgram) -> SpatialNoteTransition? {
            guard case let .chord(_, _, transition) = program else { return nil }
            return transition
        }
        XCTAssertEqual(transition(of: compiled.layers[0].routings[0].program), .retrigger)
        XCTAssertEqual(transition(of: compiled.layers[0].routings[1].program), .legato)
    }

    func testQ1EmptyOverrideEffectsRemainCompiledPerTarget() throws {
        let cell = try self.cell(20, 20)
        let note = SpatialRoutingTarget.midiNote(channel: 0)
        let boolean = SpatialRoutingTarget.boolean(name: "empty")
        let scalar = SpatialRoutingTarget.midiCC(channel: 0, controller: 7)
        let overrides = [
            SpatialCellAction(target: note, value: .chord(notes: [], velocity: 100)),
            SpatialCellAction(target: boolean, value: .chord(notes: [], velocity: 100)),
            SpatialCellAction(target: scalar, value: .chord(notes: [], velocity: 100))
        ]
        let compiled = try SpatialInstrumentCompiler.compile(
            try document(layers: [layer(cells: [cell], routings: [
                .init(target: note, program: .chord(notes: [60], velocity: 100, transition: .legato)),
                .init(target: boolean, program: .constant(1)),
                .init(target: scalar, program: .constant(1))
            ], overrides: [cell: overrides])]), revision: revision)
        let groups = try XCTUnwrap(compiled.layers[0].cellActions.first?.groups)
        XCTAssertEqual(groups.first { $0.target == note }?.summary,
                       .notes([]))
        XCTAssertEqual(groups.first { $0.target == boolean }?.summary, .boolean(false))
        XCTAssertEqual(groups.first { $0.target == scalar }?.summary, .scalar(0))
    }

    func testQ1CompiledAndDocumentLayerIndicesAreDifferentNumberSpaces() throws {
        let first = layer(cells: [try cell(10, 10)], active: false)
        let second = layer(cells: [try cell(20, 20)])
        let thirdID = UUID()
        let third = layer(id: thirdID, cells: [try cell(30, 30)])
        let document = try document(layers: [first, second, third])
        let compiled = try SpatialInstrumentCompiler.compile(document, revision: revision)
        XCTAssertEqual(compiled.layers.map(\.compiledLayerIndex), [0, 1])
        XCTAssertEqual(document.layers.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(compiled.layers.map(\.id), [second.id, thirdID], "Compiled index 0 is document index 1")
        XCTAssertEqual(compiled.layers.last?.id, thirdID)
    }

    func testF2HandlesCarryRevisionAndDoNotAcceptRingZeroFromQuery() throws {
        let c = try cell(1, 0)
        let doc = try document(layers: [layer(cells: [c])])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)
        let handle = try XCTUnwrap(compiled.hits(tick: 0, raw: 1).first)
        XCTAssertEqual(handle.revision, revision)
        XCTAssertTrue(compiled.hits(tick: 0, raw: 0).isEmpty)
        XCTAssertThrowsError(try SpatialDocumentRevision(testCounter: UInt64.max).advanced())
        XCTAssertEqual(try SpatialDocumentRevision(testCounter: 4).advanced().counter, 5)
    }

    func testDeviceTickTypesRejectInvalidBoundsAndRawValues() {
        XCTAssertNil(DeviceTickSpan(lower: -1, upper: 1))
        XCTAssertNil(DeviceTickSpan(lower: 2, upper: 1))
        XCTAssertNil(DeviceTickSpan(lower: 0, upper: 361))
        XCTAssertNotNil(DeviceTickSpan(lower: 0, upper: 360))
        XCTAssertNil(DeviceTickMeasurement(order: 0, ticks: .init(lower: 0, upper: 0)!, rawCentimeters: 0))
        XCTAssertNotNil(DeviceTickMeasurement(order: 0, ticks: .init(lower: 0, upper: 0)!, rawCentimeters: 100))
    }

    func testF1OverrideValidationHasStableSmallestCellPriority() throws {
        let layerID = UUID()
        var overrides: [PolarDeviceLattice: [SpatialCellAction]] = [:]
        for ring in stride(from: 50, through: 1, by: -1) {
            overrides[try cell(ring, 10)] = [
                .init(target: .midiCC(channel: 0, controller: 1), value: .scalar(.nan))
            ]
        }
        let doc = try document(layers: [layer(id: layerID, cells: [], overrides: overrides)])
        XCTAssertThrowsError(try SpatialInstrumentCompiler.compile(doc, revision: revision)) { error in
            XCTAssertEqual(error as? CompiledInstrumentError,
                           .nonFiniteOverrideValue(layerID: layerID, cell: try! self.cell(1, 10)))
        }
    }

    func testF2StatisticsCountIneligibleLayersAndOverridesSeparately() throws {
        let inactiveCell = try cell(10, 10)
        let soloSuppressedCell = try cell(20, 20)
        let action = SpatialCellAction(target: .boolean(name: "x"), value: .boolean(true))
        let activeSolo = layer(cells: [try cell(30, 30)], soloed: true)
        let inactive = layer(cells: [], active: false, overrides: [inactiveCell: [action]])
        let suppressed = layer(cells: [], overrides: [soloSuppressedCell: [action]])
        let doc = try document(layers: [inactive, suppressed, activeSolo])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)
        XCTAssertEqual(compiled.statistics.ineligibleLayerCount, 2)
        XCTAssertEqual(compiled.statistics.ineligibleOverrideCells, 2)
        XCTAssertEqual(compiled.statistics.dormantOverrideCells, 0)
    }

    func testP4InvisibleActiveAndInactiveSoloDoNotChangeEligibility() throws {
        let visible = layer(id: UUID(), cells: [try cell(10, 10)])
        let invisible = layer(id: UUID(), cells: [try cell(11, 10)])
        let inactiveSolo = layer(id: UUID(), cells: [try cell(12, 10)], active: false, soloed: true)
        let doc = try document(layers: [visible, invisible, inactiveSolo])
        let compiled = try SpatialInstrumentCompiler.compile(doc, revision: revision)
        XCTAssertEqual(compiled.layers.map(\.id), [visible.id, invisible.id])
    }

    func testP6F7RejectsAllNamedNonFiniteAndOverflowCasesWithoutMarkerLeak() throws {
        let id = UUID(); let cell = try cell(3, 3)
        let marker = "MARKER-M3-4711"
        let directionID = UUID()
        let direction = try document(layers: [layer(id: id, cells: [cell], routings: [
            .init(id: directionID, target: .boolean(name: marker), program: .continuous(minimum: 0, maximum: 1, directionDegrees: .nan, curve: .linear))
        ], name: marker)])
        XCTAssertThrowsError(try SpatialInstrumentCompiler.compile(direction, revision: revision)) { error in
            XCTAssertEqual(error as? CompiledInstrumentError, .nonFiniteProgramValue(layerID: id, routingID: directionID))
            XCTAssertFalse(String(describing: error).contains("MARKER-M3-4711"))
        }
        let overlapID = UUID()
        let overlap = try document(layers: [layer(id: id, cells: [cell], routings: [
            .init(id: overlapID, target: .boolean(name: marker), program: .chord(notes: [60], velocity: 100, transition: .overlap(milliseconds: .infinity)))
        ], name: marker)])
        XCTAssertThrowsError(try SpatialInstrumentCompiler.compile(overlap, revision: revision)) { error in
            XCTAssertEqual(error as? CompiledInstrumentError, .nonFiniteProgramValue(layerID: id, routingID: overlapID))
            XCTAssertFalse(String(describing: error).contains(marker))
        }
        for program in [
            SpatialValueProgram.continuous(minimum: -Double.greatestFiniteMagnitude, maximum: Double.greatestFiniteMagnitude, directionDegrees: 0, curve: .linear),
            .scale(rootMIDINote: Int.max, lowestMIDINote: 0, highestMIDINote: 127, scale: .chromatic, directionDegrees: 0, ascending: true, transition: .retrigger)
        ] {
            let routingID = UUID()
            let doc = try document(layers: [layer(id: id, cells: [cell], routings: [
                .init(id: routingID, target: .boolean(name: marker), program: program)
            ], name: marker)])
            XCTAssertThrowsError(try SpatialInstrumentCompiler.compile(doc, revision: revision)) { error in
                XCTAssertEqual(error as? CompiledInstrumentError, .nonFiniteProgramValue(layerID: id, routingID: routingID))
                XCTAssertFalse(String(describing: error).contains(marker))
            }
        }
        let overrideID = UUID()
        let overrideActions = [
            SpatialCellAction(target: .midiCC(channel: 0, controller: 1), value: .scalar(.greatestFiniteMagnitude)),
            SpatialCellAction(target: .midiCC(channel: 0, controller: 1), value: .scalar(.greatestFiniteMagnitude))
        ]
        let overrideDoc = try document(layers: [layer(id: overrideID, cells: [], active: false, overrides: [cell: overrideActions], name: marker)])
        XCTAssertThrowsError(try SpatialInstrumentCompiler.compile(overrideDoc, revision: revision)) { error in
            XCTAssertEqual(error as? CompiledInstrumentError, .nonFiniteOverrideValue(layerID: overrideID, cell: cell))
            XCTAssertFalse(String(describing: error).contains(marker))
        }
    }

    func testP7ReversedOverrideInsertionOrderCompilesIdentically() throws {
        let a = try cell(10, 10); let b = try cell(20, 20)
        let target = SpatialRoutingTarget.midiCC(channel: 0, controller: 7)
        let actionsA = [SpatialCellAction(target: target, value: .scalar(0.2))]
        let actionsB = [SpatialCellAction(target: target, value: .scalar(0.8))]
        var first: [PolarDeviceLattice: [SpatialCellAction]] = [:]
        first[a] = actionsA; first[b] = actionsB
        var second: [PolarDeviceLattice: [SpatialCellAction]] = [:]
        second[b] = actionsB; second[a] = actionsA
        let routing = SpatialRouting(target: target, program: .constant(0))
        let id = UUID()
        let one = try SpatialInstrumentCompiler.compile(try document(layers: [layer(id: id, cells: [a, b], routings: [routing], overrides: first)]), revision: revision)
        let two = try SpatialInstrumentCompiler.compile(try document(layers: [layer(id: id, cells: [a, b], routings: [routing], overrides: second)]), revision: revision)
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.layers[0].cellActions.map(\.cell), [a, b])
    }

    func testP8SearchBoundariesAndFullBudgetColumn() throws {
        for count in [0, 1, 2, 4, 8, 16] {
            let cells: Set<PolarDeviceLattice> = count == 0
                ? []
                : Set((1...count).compactMap { try? cell($0, 100) })
            let compiled = try SpatialInstrumentCompiler.compile(try document(layers: [layer(cells: cells)]), revision: revision)
            let measured = compiled.measuredHits(tick: 100, raw: UInt16(count == 0 ? 1 : count))
            let bound = Int(ceil(log2(Double(count + 1))))
            XCTAssertLessThanOrEqual(measured.comparisons, bound)
            XCTAssertEqual(measured.visitedEntries, measured.hits.count)
            XCTAssertEqual(compiled.measuredHits(tick: 100, raw: 0).visitedEntries, 0)
        }
        let boundaryLimit = Int(ceil(log2(Double(16 + 1))))
        let boundaryCases: [(Set<PolarDeviceLattice>, Int, Int)] = [
            (Set((1...16).compactMap { try? cell($0, 101) }), 1, 1),
            (Set((1...16).compactMap { try? cell($0, 101) }), 16, 1),
            (Set((5...16).compactMap { try? cell($0, 101) }), 3, 0),
            (Set(stride(from: 2, through: 16, by: 2).compactMap { try? cell($0, 101) }), 7, 0),
            (Set((1...16).compactMap { try? cell($0, 101) }), 17, 0)
        ]
        for (cells, raw, expectedHits) in boundaryCases {
            let boundary = try SpatialInstrumentCompiler.compile(
                try document(layers: [layer(cells: cells)]), revision: revision
            )
            let measured = boundary.measuredHits(tick: 101, raw: UInt16(raw))
            XCTAssertLessThanOrEqual(measured.comparisons, boundaryLimit)
            XCTAssertEqual(measured.visitedEntries, measured.hits.count)
            XCTAssertEqual(measured.hits.count, expectedHits)
        }
        let all = Set((0..<262_144).compactMap { offset in
            let ring = offset % PolarDeviceLattice.maxRing + 1
            let sector = offset / PolarDeviceLattice.maxRing
            return try? cell(ring, sector)
        })
        let compiled = try SpatialInstrumentCompiler.compile(try document(layers: [layer(cells: all)]), revision: revision)
        XCTAssertEqual(compiled.statistics.indexedAddressCount, 262_144)
        let fullColumn = Set((1...PolarDeviceLattice.maxRing).compactMap { try? cell($0, 102) })
        let full = try SpatialInstrumentCompiler.compile(
            try document(layers: [layer(cells: fullColumn)]), revision: revision
        )
        XCTAssertEqual(full.statistics.maxEntriesPerTick, PolarDeviceLattice.maxRing)
        let fullMeasured = full.measuredHits(tick: 102, raw: 4096)
        XCTAssertLessThanOrEqual(
            fullMeasured.comparisons,
            Int(ceil(log2(Double(PolarDeviceLattice.maxRing + 1))))
        )
        XCTAssertEqual(fullMeasured.visitedEntries, fullMeasured.hits.count)
    }

    func testF6DuplicateRoutingIDIsNamed() throws {
        let routingID = UUID()
        let routing = SpatialRouting(id: routingID, target: .boolean(name: "x"), program: .constant(1))
        let doc = try document(layers: [
            layer(cells: [try cell(1, 1)], routings: [routing]),
            layer(cells: [try cell(2, 2)], routings: [routing])
        ])
        XCTAssertThrowsError(try SpatialInstrumentCompiler.compile(doc, revision: revision)) { error in
            XCTAssertEqual(error as? CompiledInstrumentError, .duplicateRoutingID(routingID))
        }
    }

    func testF2HandlesRejectWrongKeyStaleRevisionAndForeignCell() throws {
        let id = UUID(); let cellA = try cell(10, 10); let cellB = try cell(20, 20)
        let documentA = try document(layers: [layer(id: id, cells: [cellA])])
        let compiledA = try SpatialInstrumentCompiler.compile(documentA, revision: revision)
        let handle = try XCTUnwrap(compiledA.hits(tick: 10, raw: 10).first)
        XCTAssertThrowsError(try compiledA.validate([UUID(): handle])) { error in
            XCTAssertEqual(error as? CompiledInstrumentError, .invalidActiveHandle)
        }
        let compiledRevision = try SpatialInstrumentCompiler.compile(documentA, revision: SpatialDocumentRevision(testCounter: 8))
        XCTAssertThrowsError(try compiledRevision.validate([id: handle])) { error in
            XCTAssertEqual(error as? CompiledInstrumentError, .staleActiveHandle)
        }
        let documentB = try document(layers: [layer(id: id, cells: [cellB])])
        let compiledB = try SpatialInstrumentCompiler.compile(documentB, revision: revision)
        XCTAssertThrowsError(try compiledB.validate([id: handle])) { error in
            XCTAssertEqual(error as? CompiledInstrumentError, .foreignActiveHandle)
        }
    }

    func testKorrektur7AllNotesOffScalarMeanAndBooleanOR() throws {
        let c = try cell(30, 30)
        let allOff = SpatialRoutingTarget.midiAllNotesOff(channel: 0)
        let scalar = SpatialRoutingTarget.midiCC(channel: 0, controller: 1)
        let boolean = SpatialRoutingTarget.boolean(name: "b")
        let actions = [
            SpatialCellAction(target: allOff, value: .boolean(false)),
            SpatialCellAction(target: scalar, value: .scalar(0.2)),
            SpatialCellAction(target: scalar, value: .scalar(0.8)),
            SpatialCellAction(target: boolean, value: .boolean(false)),
            SpatialCellAction(target: boolean, value: .boolean(true))
        ]
        let layer = self.layer(cells: [c], routings: [
            .init(target: allOff, program: .constant(1)), .init(target: scalar, program: .constant(1)), .init(target: boolean, program: .constant(1))
        ], overrides: [c: actions])
        let compiled = try SpatialInstrumentCompiler.compile(try document(layers: [layer]), revision: revision)
        XCTAssertEqual(compiled.layers[0].cellActions[0].groups.count, 2)
        XCTAssertEqual(compiled.layers[0].cellActions[0].groups.first(where: { $0.target == scalar })?.summary, .scalar(0.5))
        XCTAssertEqual(compiled.layers[0].cellActions[0].groups.first(where: { $0.target == boolean })?.summary, .boolean(true))
        XCTAssertFalse(compiled.layers[0].cellActions[0].groups.contains { $0.target == allOff })
    }

    func testN3OverridesForUnroutedTargetsProduceNoGroups() throws {
        let routedCell = try cell(40, 40)
        let unroutedCell = try cell(50, 50)
        let note = SpatialRoutingTarget.midiNote(channel: 0)
        let scalarTarget = SpatialRoutingTarget.midiCC(channel: 0, controller: 7)
        let routedActions = [
            SpatialCellAction(target: scalarTarget, value: .scalar(0.5)),
            SpatialCellAction(target: note, value: .note(number: 60, velocity: 100))
        ]
        let unroutedActions = [
            SpatialCellAction(target: scalarTarget, value: .scalar(0.7))
        ]
        let document = try self.document(layers: [
            layer(cells: [routedCell], routings: [.init(target: note, program: .constant(1))], overrides: [routedCell: routedActions]),
            layer(cells: [unroutedCell], overrides: [unroutedCell: unroutedActions])
        ])
        let compiled = try SpatialInstrumentCompiler.compile(document, revision: revision)
        XCTAssertEqual(compiled.statistics.actionGroupCount, 1)
        XCTAssertEqual(compiled.statistics.overrideCellCount, 2)
        XCTAssertEqual(compiled.layers[0].cellActions.count, 1)
        XCTAssertEqual(compiled.layers[0].cellActions[0].groups.map(\.target), [note])
        XCTAssertTrue(compiled.layers[1].cellActions.isEmpty)
    }

    func testS1ForbiddenTargetsDoNotNameM3aTypes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let forbidden = ["Sources/SickPLSMonitor", "Sources/PlanariumPresets"]
        let names = ["CompiledInstrument", "SpatialInstrumentCompiler", "DeviceLatticeHitGeometry", "DeviceTickSpan", "DeviceTickMeasurement"]
        for directory in forbidden {
            let url = root.appendingPathComponent(directory)
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                for case let file as URL in enumerator {
                    guard file.pathExtension == "swift" else { continue }
                    let source = try String(contentsOf: file)
                    for name in names { XCTAssertFalse(source.contains(name), "\(file.lastPathComponent) nennt \(name)") }
                }
            }
        }
    }
}
