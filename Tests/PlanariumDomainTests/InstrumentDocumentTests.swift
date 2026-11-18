import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class InstrumentDocumentTests: XCTestCase {
    private func document() throws -> InstrumentDocument {
        let layer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let routing = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let cells = try Set([100, 105, 110].map { try XCTUnwrap(PolarDeviceLattice(ring: $0, sector: 180)) })
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [
            .init(id: layer, name: "Channel", color: .orange, isVisible: true,
                  isActive: true, isLocked: false, isSoloed: false, cells: cells,
                  routings: [.init(id: routing, target: .midiCC(channel: 1, controller: 74),
                                   program: .continuous(minimum: 0.125, maximum: 0.875,
                                                        directionDegrees: 90, curve: .linear))],
                  cellOverrides: [:])
        ], selectedLayerID: layer)
        let identity = SpatialAudioUnitIdentity(componentType: 1, componentSubType: 2, componentManufacturer: 3)
        return InstrumentDocument(
            spatial: spatial,
            detection: .init(temporalSmoothing: .mean(window: 4), roomContour: .init(isEnabled: true, toleranceCentimeters: 9)),
            channel: .init(instrument: .init(identity: identity, state: Data([1, 2, 3])),
                           inserts: [.init(id: layer, plugin: .init(identity: identity, state: Data([4, 5])), bypassed: true),
                                     .init(id: routing, plugin: .init(identity: identity, state: Data([6])), bypassed: false)],
                           levelDecibels: -6, midiTarget: .init(uniqueID: 42)),
            revision: .init(session: layer, counter: 17))
    }

    func testReusedIndexMatchesFreshCompileAndRejectsMusicalChanges() throws {
        let original = try reuseFixture(), compiled = try InstrumentCompiler.compile(original)
        let cell = original.spatial.layers[0].cells.sorted { $0.ring < $1.ring }[0]
        let other = PolarDeviceLattice(ring: 120, sector: 180)!
        let anotherCell = PolarDeviceLattice(ring: 105, sector: 180)!
        let action = SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 67, velocity: 100))
        let changes: [(String, (inout InstrumentDocument) throws -> Void)] = [
            ("detection", { $0.detection.groupingMinimumPoints = 3 }),
            ("grid", { $0.editorGrid = MetricSquareGrid.CellSize.fiftyCentimeter.grid }),
            ("midi", { $0.midiTarget = .init(uniqueID: 99) }),
            ("channel identity", { $0.channels[0].id = UUID() }),
            ("channel count", { $0.channels.removeLast() }),
            ("channel order", { $0.channels.reverse() }),
            ("plugin identity", { $0.channels[0].instrument?.identity.componentSubType = 99 }),
            ("plugin state", { $0.channels[0].instrument?.state = Data([99]) }),
            ("plugin remove", { $0.channels[0].instrument = nil }),
            ("plugin add", { $0.channels[1].instrument = $0.channels[0].instrument }),
            ("insert order", { $0.channels[0].inserts.reverse() }),
            ("insert add", { $0.channels[0].inserts.append(.init(id: UUID(), plugin: $0.channels[0].instrument!)) }),
            ("insert remove", { $0.channels[0].inserts.removeLast() }),
            ("insert identity", { $0.channels[0].inserts[0].id = UUID() }),
            ("insert plugin", { $0.channels[0].inserts[0].plugin.identity.componentSubType = 99 }),
            ("insert state", { $0.channels[0].inserts[0].plugin.state = Data([99]) }),
            ("insert bypass", { $0.channels[0].inserts[0].bypassed.toggle() }),
            ("channel midi", { $0.channels[0].midiTarget = .init(uniqueID: 99) }),
            ("scene count", { $0.scenes.removeLast() }),
            ("scene order", { $0.scenes.reverse() }),
            ("scene identity", { $0.scenes[0].id = UUID() }),
            ("scene membership", { $0.scenes[0].activeLayerIDs = [$0.spatial.layers[1].id] }),
            ("current scene", { $0.currentSceneID = $0.scenes[1].id }),
            ("lattice version", { $0.spatial = try .init(latticeVersion: .polarDeviceV1, layers: $0.spatial.layers, selectedLayerID: $0.spatial.selectedLayerID) }),
            ("layer count", { $0.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [$0.spatial.layers[0]], selectedLayerID: $0.spatial.selectedLayerID) }),
            ("layer order", { $0.spatial = try .init(latticeVersion: .polarDeviceV2, layers: $0.spatial.layers.reversed(), selectedLayerID: $0.spatial.selectedLayerID) }),
            ("layer identity", { try self.changeLayer(&$0, field: "id", value: UUID()) }),
            ("cells add", { try self.changeLayer(&$0, field: "cells", value: $0.spatial.layers[0].cells.union([other])) }),
            ("cells remove", { try self.changeLayer(&$0, field: "cells", value: $0.spatial.layers[0].cells.subtracting([cell])) }),
            ("routing identity", { var routes = $0.spatial.layers[0].routings; routes[0].id = UUID(); try self.changeLayer(&$0, field: "routings", value: routes) }),
            ("routing program", { var routes = $0.spatial.layers[0].routings; routes[0].program = .constant(0.5); try self.changeLayer(&$0, field: "routings", value: routes) }),
            ("routing target", { var routes = $0.spatial.layers[0].routings; routes[0].target = .midiCC(channel: 2, controller: 71); try self.changeLayer(&$0, field: "routings", value: routes) }),
            ("routing transition", { var routes = $0.spatial.layers[0].routings; routes[1].program = .chord(notes: [60], velocity: 100, transition: .legato); try self.changeLayer(&$0, field: "routings", value: routes) }),
            ("routing order", { try self.changeLayer(&$0, field: "routings", value: $0.spatial.layers[0].routings.reversed()) }),
            ("routing add", { try self.changeLayer(&$0, field: "routings", value: $0.spatial.layers[0].routings + [.init(target: .midiCC(channel: 3, controller: 11), program: .constant(0.3))]) }),
            ("routing remove", { try self.changeLayer(&$0, field: "routings", value: [$0.spatial.layers[0].routings[0]]) }),
            ("override add", { try self.changeLayer(&$0, field: "cellOverrides", value: [OverrideRecord(cell: cell, actions: [action]), OverrideRecord(cell: anotherCell, actions: [action])]) }),
            ("override change", { try self.changeLayer(&$0, field: "cellOverrides", value: [OverrideRecord(cell: cell, actions: [.init(target: action.target, value: .note(number: 69, velocity: 100))])]) }),
            ("override remove", { try self.changeLayer(&$0, field: "cellOverrides", value: [OverrideRecord]()) }),
            ("layer active", { try self.changeLayer(&$0, field: "isActive", value: false) }),
            ("layer solo", { try self.changeLayer(&$0, field: "isSoloed", value: true) }),
            ("toggle guard", { try self.changeLayer(&$0, field: "toggleGuardSeconds", value: 1.5) }),
            ("layer midi", { try self.changeLayer(&$0, field: "midiTarget", value: InstrumentMIDITarget(uniqueID: 99)) })
        ]
        for (name, change) in changes {
            var next = original; try change(&next)
            XCTAssertNotEqual(next, original, "Mutation must change the fixture: \(name)")
            XCTAssertFalse(InstrumentCompiler.canReuseIndex(from: original, for: next), name)
            XCTAssertFalse(InstrumentCompiler.canReuseIndex(from: next, for: original), "reverse: \(name)")
            XCTAssertThrowsError(try InstrumentCompiler.reusingIndex(compiled, from: original, for: next), name)
        }
    }

    func testEveryReusableMetadataFieldMatchesFreshCompileIndividuallyAndTogether() throws {
        let original = try reuseFixture(), compiled = try InstrumentCompiler.compile(original)
        let changes: [(String, (inout InstrumentDocument) throws -> Void)] = [
            ("layer name", { try self.changeLayer(&$0, field: "name", value: "Renamed") }),
            ("layer color", { try self.changeLayer(&$0, field: "color", value: SpatialLayerColor.blue) }),
            ("layer visibility", { try self.changeLayer(&$0, field: "isVisible", value: false) }),
            ("layer lock", { try self.changeLayer(&$0, field: "isLocked", value: true) }),
            ("selection", { $0.spatial = try $0.spatial.selectingLayer($0.spatial.layers[1].id) }),
            ("channel name", { $0.channels[0].name = "Renamed" }),
            ("channel color", { $0.channels[0].color = .orange }),
            ("channel level", { $0.channels[0].levelDecibels = -12 }),
            ("channel pan", { $0.channels[0].pan = 0.5 }),
            ("channel mute", { $0.channels[0].muted = true }),
            ("channel solo", { $0.channels[0].soloed = true }),
            ("master level", { $0.masterLevelDecibels = -12 }),
            ("tempo", { $0.beatsPerMinute = 135 }),
            ("scene name", { $0.scenes[0].name = "Renamed" }),
            ("revision", { $0.revision = try $0.revision.advanced() })
        ]
        func check(_ next: InstrumentDocument, _ name: String) throws {
            XCTAssertNotEqual(next, original, name)
            XCTAssertTrue(InstrumentCompiler.canReuseIndex(from: original, for: next), name)
            XCTAssertEqual(try InstrumentCompiler.reusingIndex(compiled, from: original, for: next),
                           try InstrumentCompiler.compile(next), name)
        }
        var metadata = original
        for (name, change) in changes {
            var next = original; try change(&next); try check(next, name)
            try change(&metadata)
        }
        try check(metadata, "all metadata combined")
        metadata.channel.pan = .nan
        XCTAssertThrowsError(try InstrumentCompiler.reusingIndex(compiled, from: original, for: metadata))
    }

    private struct OverrideRecord: Encodable {
        var cell: PolarDeviceLattice
        var actions: [SpatialCellAction]
    }

    // Mutate one encoded field of the immutable layer, preserving every other
    // field. This deliberately does not duplicate the compiler's field list.
    private func changeLayer<T: Encodable>(_ document: inout InstrumentDocument, field: String, value: T) throws {
        var layers = document.spatial.layers
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(layers[0])) as? [String: Any])
        object[field] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
        layers[0] = try JSONDecoder().decode(SpatialDocumentLayer.self, from: JSONSerialization.data(withJSONObject: object))
        let selected = document.spatial.selectedLayerID == document.spatial.layers[0].id ? layers[0].id : document.spatial.selectedLayerID
        document.spatial = try .init(latticeVersion: document.spatial.latticeVersion, layers: layers, selectedLayerID: selected)
    }

    private func reuseFixture() throws -> InstrumentDocument {
        var result = try document()
        var routes = result.spatial.layers[0].routings
        routes.append(.init(target: .midiNote(channel: 0), program: .chord(notes: [60], velocity: 100, transition: .retrigger)))
        try changeLayer(&result, field: "routings", value: routes)
        try changeLayer(&result, field: "cellOverrides", value: [OverrideRecord(cell: PolarDeviceLattice(ring: 100, sector: 180)!,
            actions: [.init(target: routes[1].target, value: .note(number: 67, velocity: 100))])])
        let first = result.spatial.layers[0]
        let second = SpatialDocumentLayer(id: UUID(), name: "Second", color: .blue, isVisible: true, isActive: true,
            isLocked: false, isSoloed: false, cells: [PolarDeviceLattice(ring: 150, sector: 180)!], routings: routes.map { .init(target: $0.target, program: $0.program) }, cellOverrides: [:])
        result.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [first, second], selectedLayerID: first.id)
        result.channels.append(.init(id: UUID(), name: "Second"))
        result.scenes = [.init(name: "First", activeLayerIDs: [first.id]), .init(name: "Second", activeLayerIDs: [second.id])]
        result.currentSceneID = result.scenes[0].id
        return result
    }

    func testCompleteDocumentRoundTripsIncludingDetectionChannelAndInsertOrder() throws {
        let original = try document()
        let data = try JSONEncoder().encode(original)
        var persisted = original; persisted.detection.roomContour = .init()
        XCTAssertEqual(try JSONDecoder().decode(InstrumentDocument.self, from: data), persisted)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("roomFilter"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("nearestDistancesCentimeters"))
        let compiled = try InstrumentCompiler.compile(original)
        XCTAssertEqual(compiled.detection, original.detection)
        XCTAssertEqual(compiled.channel, original.channel)
        XCTAssertEqual(compiled.revision, original.revision)
    }

    func testCompilerPreservesOldSpatialResultAndIsBitDeterministic() throws {
        let original = try document()
        let old = try SpatialInstrumentCompiler.compile(original.spatial, revision: original.revision)
        let baseline = try InstrumentCompiler.compile(original)
        // RUNDE-E adds the canonical surface partition even at Snap 0.
        // Music remains bit-identical; compare the added geometry with the
        // same editor-grid compiler rather than the legacy gridless metadata.
        let surfaces = try SpatialInstrumentCompiler.compile(original.spatial, revision: original.revision, snapGrid: original.editorGrid)
        XCTAssertEqual(baseline.layers, surfaces.layers)
        XCTAssertEqual(baseline.layers.map(\.cells), old.layers.map(\.cells))
        XCTAssertEqual(baseline.layers.map(\.routings), old.layers.map(\.routings))
        XCTAssertEqual(baseline.layers.map(\.cellActions), old.layers.map(\.cellActions))
        XCTAssertEqual(baseline.statistics, old.statistics)
        // The canonical musical fingerprint includes Double bit patterns,
        // exact hits/ordering and every cell evaluation, not just float ==.
        func fingerprint(_ compiled: CompiledInstrument) throws -> [UInt64] {
            var bits: [UInt64] = []
            for ring in 100...110 {
                let hits = compiled.hits(tick: 180, raw: ring)
                bits.append(UInt64(hits.count))
                for handle in hits {
                    bits += [UInt64(handle.cell.ring), UInt64(handle.cell.sector)]
                    for value in try compiled.evaluate(active: [handle.layerID: handle]) {
                        if case .scalar(let scalar) = value.value { bits.append(scalar.bitPattern) }
                    }
                }
            }
            return bits
        }
        let expected = try fingerprint(baseline)
        for _ in 0..<64 {
            let compiled = try InstrumentCompiler.compile(original)
            XCTAssertEqual(compiled, baseline)
            XCTAssertEqual(try fingerprint(compiled), expected)
        }
    }

    func testCompiledSnapshotCannotChangeWhenEditableDocumentChanges() throws {
        var editable = try document()
        let compiled = try InstrumentCompiler.compile(editable)
        editable.detection = .allStagesOff
        editable.channel.inserts.reverse()
        editable.channel.instrument?.state = Data([99])
        editable.revision = try editable.revision.advanced()
        let changed = try InstrumentCompiler.compile(editable)
        XCTAssertNotEqual(compiled.detection, changed.detection)
        XCTAssertNotEqual(compiled.channel, changed.channel)
        XCTAssertNotEqual(compiled.revision, changed.revision)
        XCTAssertEqual(compiled.layers, changed.layers)
    }

    func testCompilerRejectsNonFiniteChannelLevel() throws {
        var editable = try document()
        editable.channel.levelDecibels = .nan
        XCTAssertThrowsError(try InstrumentCompiler.compile(editable)) {
            XCTAssertEqual($0 as? CompiledInstrumentError, .invalidChannelLevel)
        }
    }

    func testDetectionChangedUsesTheCompiledDocumentAndDoesNotRevertOnInstall() throws {
        var editable = try document()
        editable.detection = .allStagesOff
        let initial = try InstrumentCompiler.compile(editable)
        var state = PlayEngine.step(PlayState(), .install(initial)).0
        editable.detection.roomContour = .init(isEnabled: true, toleranceCentimeters: 17)
        editable.revision = try editable.revision.advanced()
        let replacement = try InstrumentCompiler.compile(editable)
        state = PlayEngine.step(state, .detectionChanged(replacement)).0
        XCTAssertEqual(state.instrument?.detection, editable.detection)
        state = PlayEngine.step(state, .install(replacement)).0
        XCTAssertEqual(state.instrument?.detection, editable.detection)
    }
    func testCompilerRejectsInvalidDetectionInsteadOfProducingNaNMeasurements() throws {
        var editable = try document()
        for smoothing: DetectionTemporalSmoothing in [.exponential(alpha: .nan), .exponential(alpha: 2), .mean(window: 0)] {
            editable.detection.temporalSmoothing = smoothing
            XCTAssertThrowsError(try InstrumentCompiler.compile(editable)) {
                XCTAssertEqual($0 as? CompiledInstrumentError, .invalidDetectionConfiguration)
            }
        }
    }

    func testRoomContourReductionUsesOnlySuppliedSamplesAndTime() throws {
        let geometry = SpatialRoomContour.Geometry(pointCount: 3, angleResolutionDegrees: 90,
                                                    startAngleDegrees: -90, sourceIdentifier: "test")
        let time = Date(timeIntervalSince1970: 123)
        let samples: [[UInt16?]] = [[100, nil, 40], [104, 200, nil], [102, nil, nil]]
        let contour = try XCTUnwrap(SpatialRoomContour.measured(profiles: samples, capturedAt: time, geometry: geometry))
        XCTAssertEqual(contour.capturedAt, time)
        XCTAssertEqual(contour.nearestDistancesCentimeters, [102, nil, nil], "Single returns cannot establish a stable boundary")
        XCTAssertEqual(contour.spreadCentimeters, [4, nil, nil])
        XCTAssertEqual(SpatialRoomContour.measured(profiles: samples, capturedAt: time, geometry: geometry), contour)
    }

}
