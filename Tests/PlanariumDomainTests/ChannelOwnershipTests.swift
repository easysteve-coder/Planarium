import XCTest
@testable import PlanariumDomain

final class ChannelOwnershipTests: XCTestCase {
    private let first = InstrumentChannel.legacyID
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private func value(_ id: UUID, strip: UUID, notes: [UInt8], transition: SpatialNoteTransition = .holdUntilNext) -> SpatialRoutingEvaluation {
        .init(routingID: id, target: .audioUnitNote(channel: 0, stripID: strip),
            value: .notes(Set(notes.map { .init(number: $0, velocity: 100) }), transition: transition),
            cell: PolarDeviceLattice(ring: 100, sector: 180)!)
    }
    func testHeldChordSurvivesMelodyOnOtherStripInBothBatchOrders() {
        for reversed in [false, true] {
            var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
            let chord = UUID(), melody = UUID()
            _ = ledger.apply([value(chord, strip: first, notes: [60, 64, 67])])
            var batch = [SpatialRoutingEvaluation(routingID: chord, target: .audioUnitNote(channel: 0, stripID: first), value: .inactive),
                         value(melody, strip: second, notes: [72], transition: .legato)]
            if reversed { batch.reverse() }
            let commands = ledger.apply(batch)
            XCTAssertFalse(commands.contains { if case .noteOff = $0 { return true }; return false })
            XCTAssertEqual(ledger.soundingNoteCount, 4)
            batch[batch.firstIndex { $0.routingID == melody }!] = value(melody, strip: second, notes: [74], transition: .legato)
            let moved = ledger.apply(batch)
            XCTAssertTrue(moved.contains(.noteOff(destination: .audioUnit(stripID: second), channel: 0, note: .init(number: 72, velocity: 100))))
            XCTAssertEqual(ledger.soundingNoteCount, 4)
        }
    }
    func testAllNotesOffAndPhysicalSharedNotesAreScopedToStrip() {
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        let a = UUID(), b = UUID(), off = UUID()
        XCTAssertEqual(ledger.apply([value(a, strip: first, notes: [60]), value(b, strip: second, notes: [60])]).count, 2)
        let commands = ledger.apply([value(a, strip: first, notes: [60]), value(b, strip: second, notes: [60]),
            .init(routingID: off, target: .audioUnitAllNotesOff(channel: 0, stripID: first), value: .boolean(true))])
        XCTAssertEqual(ledger.soundingNoteCount, 1)
        XCTAssertFalse(commands.contains { if case .noteOff(.audioUnit(let id), _, _) = $0 { return id == second }; return false })
        XCTAssertEqual(ledger.releaseAll(), [.noteOff(destination: .audioUnit(stripID: second), channel: 0, note: .init(number: 60, velocity: 100))])
    }
    private func document(count: Int) throws -> (InstrumentDocument, ProfileGeometryIdentity, UUID, UUID) {
        let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
        let a = UUID(), b = UUID()
        func layer(_ id: UUID, strip: UUID, order: Int) -> SpatialDocumentLayer {
            .init(id: id, name: "Latch", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: [PolarDeviceLattice(ring: 100, sector: geometry.tickSpan(at: order)!.lower)!],
                routings: [.init(target: .audioUnitNote(channel: 0, stripID: strip), program: .chord(notes: [60], velocity: 100, transition: order == 10 ? .holdUntilNext : .toggle))], cellOverrides: [:])
        }
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer(a, strip: first, order: 10), layer(b, strip: second, order: 60)], selectedLayerID: a)
        return (.init(spatial: spatial, detection: .allStagesOff, revision: .newSession(), channels: [.init(id: first), .init(id: second)]), geometry, a, b)
    }
    func testEveryReleaseAndLossTransitionForBothStripsAt90And361() throws {
        for count in [90, 361] {
            let (document, geometry, _, _) = try document(count: count)
            let session = UUID()
            var state = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(document))).0
            state = PlayEngine.step(state, .sessionBegan(session)).0
            let frame = ProfileFrame(sessionID: session, sequence: 1, time: 10,
                measurements: (0..<count).map { DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: [10, 60].contains($0) ? 100 : 500)! }, geometry: geometry)
            state = PlayEngine.step(state, .frame(frame)).0
            XCTAssertEqual(state.soundingNoteCount, 2)
            for input: PlayInput in [.panic, .stop, .sleep, .wake, .terminate, .sessionEnded(session), .sessionBegan(UUID())] {
                let result = PlayEngine.step(state, input)
                XCTAssertEqual(result.0.soundingNoteCount, 0)
                XCTAssertEqual(result.1.filter { if case .noteOff = $0 { return true }; return false }.count, 2)
            }
            for input: PlayInput in [.inputLost, .timeAdvanced(20), .sessionEnded(session, reason: .failure)] {
                XCTAssertEqual(PlayEngine.step(state, input).0.soundingNoteCount, 2)
            }
            var removed = document; removed.channels.removeLast(); removed.revision = try removed.revision.advanced()
            let result = PlayEngine.step(state, .install(try InstrumentCompiler.compile(removed)))
            XCTAssertEqual(result.0.soundingNoteCount, 1)
            XCTAssertEqual(result.1, [.noteOff(destination: .audioUnit(stripID: second), channel: 0, note: .init(number: 60, velocity: 100))])
        }
    }
    func testMissingStripNeverProducesOnAndEightStripLimitIsNamed() throws {
        var (document, _, a, _) = try document(count: 361)
        document.channels.removeFirst()
        let compiled = try InstrumentCompiler.compile(document)
        let cell = try XCTUnwrap(compiled.layers.first { $0.id == a }?.cells.first)
        let handle = try XCTUnwrap(compiled.hits(tick: cell.sector, raw: cell.ring).first { $0.layerID == a })
        XCTAssertEqual(try compiled.evaluate(active: [a: handle]).first?.value, .inactive)
        document.channels = (0..<8).map { .init(id: UUID(), name: "Ch \($0 + 1)") }
        XCTAssertNoThrow(try InstrumentCompiler.compile(document))
        document.channels.append(.init(id: UUID()))
        XCTAssertThrowsError(try InstrumentCompiler.compile(document)) { XCTAssertEqual($0 as? CompiledInstrumentError, .tooManyChannels(9)) }
    }

    func testInstrumentChangeOnSecondStripOnlyReleasesItsNotesInBothOrdersAt90And361() throws {
        let original = SpatialAudioUnitIdentity(componentType: 1, componentSubType: 2, componentManufacturer: 3)
        let replacement = SpatialAudioUnitIdentity(componentType: 1, componentSubType: 4, componentManufacturer: 3)
        for count in [90, 361] {
            for reversed in [false, true] {
                var (document, geometry, a, b) = try document(count: count)
                document.channels[0].instrument = .init(identity: original)
                document.channels[1].instrument = .init(identity: original)
                let layers = document.spatial.layers.map { layer in
                    SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color,
                        isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                        cells: layer.cells, routings: [.init(target: .audioUnitNote(channel: 0, stripID: layer.id == a ? first : second),
                            program: .chord(notes: layer.id == a ? [60, 64, 67] : [76], velocity: 100, transition: .holdUntilNext))], cellOverrides: [:])
                }
                document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: reversed ? layers.reversed() : layers, selectedLayerID: b)
                var state = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(document))).0
                let session = UUID()
                state = PlayEngine.step(state, .sessionBegan(session)).0
                state = PlayEngine.step(state, .frame(.init(sessionID: session, sequence: 1, time: 10,
                    measurements: (0..<count).map { DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: [10, 60].contains($0) ? 100 : 500)! }, geometry: geometry))).0
                XCTAssertEqual(state.soundingNoteCount, 4)
                document.channels[1].instrument = .init(identity: replacement)
                document.revision = try document.revision.advanced()
                let swapped = PlayEngine.step(state, .install(try InstrumentCompiler.compile(document)))
                XCTAssertEqual(swapped.1, [.noteOff(destination: .audioUnit(stripID: second), channel: 0, note: .init(number: 76, velocity: 100))])
                XCTAssertEqual(swapped.0.soundingNoteCount, 3)
                XCTAssertEqual(PlayEngine.step(swapped.0, .stop).1.filter { if case .noteOff(.audioUnit(let id), _, _) = $0 { return id == first }; return false }.count, 3)
            }
        }
    }
}
