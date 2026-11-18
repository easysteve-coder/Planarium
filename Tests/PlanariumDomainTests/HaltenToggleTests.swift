import XCTest
@testable import PlanariumDomain

final class ToggleGuardTests: XCTestCase {
    func testWorkspacePersistenceMissingFieldAndBounds() throws {
        let layer = SpatialInstrumentLayer(name: "New", color: .orange, toggleGuardSeconds: 1.25)
        XCTAssertEqual(try JSONDecoder().decode(SpatialInstrumentLayer.self, from: JSONEncoder().encode(layer)).toggleGuardSeconds, 1.25)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(layer)) as? [String: Any])
        json.removeValue(forKey: "toggleGuardSeconds")
        XCTAssertEqual(try JSONDecoder().decode(SpatialInstrumentLayer.self, from: JSONSerialization.data(withJSONObject: json)).toggleGuardSeconds, 0)
        var legacyWorkspace = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SpatialInstrumentWorkspace(layers: [layer]))) as? [String: Any])
        XCTAssertEqual(try LegacySpatialDocumentReader.read(from: JSONSerialization.data(withJSONObject: legacyWorkspace)).document.layers[0].toggleGuardSeconds, 1.25)
        let imported = try CompatibilityImporter.read(JSONSerialization.data(withJSONObject: ["formatVersion": 3, "spatialWorkspace": legacyWorkspace])).get()
        XCTAssertEqual(try SpatialDocumentImporter.document(from: imported).get().document?.layers[0].toggleGuardSeconds, 1.25)
        legacyWorkspace["layers"] = [json]
        XCTAssertEqual(try LegacySpatialDocumentReader.read(from: JSONSerialization.data(withJSONObject: legacyWorkspace)).document.layers[0].toggleGuardSeconds, 0)
        for (input, expected) in [(-1.0, 0.0), (3.0, 2.0), (Double.infinity, 0.0)] {
            var changed = layer; changed.toggleGuardSeconds = input
            XCTAssertEqual(changed.toggleGuardSeconds, expected)
        }
    }
    private let session = UUID(), layerID = UUID(), routingID = UUID(), controlID = UUID()
    private func geometry(_ count: Int) -> ProfileGeometryIdentity {
        .init(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
    }
    private func document(_ count: Int, guardSeconds: Double = 0.5, reverse: Bool = false) throws -> InstrumentDocument {
        let g = geometry(count), a = count / 3, b = count * 2 / 3
        let cells = Set((g.tickSpan(at: a)!.lower...g.tickSpan(at: a + 2)!.upper).map { PolarDeviceLattice(ring: 100, sector: $0)! })
            .union([PolarDeviceLattice(ring: 100, sector: g.tickSpan(at: b)!.lower)!])
        let overrides = Dictionary(uniqueKeysWithValues: (g.tickSpan(at: a + 2)!.lower...g.tickSpan(at: a + 2)!.upper).map {
            (PolarDeviceLattice(ring: 100, sector: $0)!, [SpatialCellAction(target: .midiNote(channel: 0), value: .note(number: 64, velocity: 100))])
        })
        let note = SpatialDocumentLayer(id: layerID, name: "Toggle", color: .orange, isVisible: true, isActive: true,
            isLocked: false, isSoloed: false, cells: cells,
            routings: [.init(id: routingID, target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .toggle))],
            cellOverrides: overrides, toggleGuardSeconds: guardSeconds)
        let release = SpatialDocumentLayer(id: controlID, name: "Release", color: .blue, isVisible: true, isActive: true,
            isLocked: false, isSoloed: false, cells: [PolarDeviceLattice(ring: 100, sector: g.tickSpan(at: count - 5)!.lower)!],
            routings: [.init(target: .releaseLayer(layerID: layerID), program: .constant(1))], cellOverrides: [:])
        return .init(spatial: try .init(latticeVersion: .polarDeviceV2, layers: reverse ? [release, note] : [note, release], selectedLayerID: layerID),
                     detection: .allStagesOff, revision: .init(session: session, counter: 1))
    }
    private func frame(_ count: Int, _ orders: Set<Int>, _ time: Double) -> ProfileFrame {
        let g = geometry(count)
        return .init(sessionID: session, sequence: UInt64(time * 1000), time: time,
            measurements: (0..<count).map { DeviceTickMeasurement(order: $0, ticks: g.tickSpan(at: $0)!, rawCentimeters: orders.contains($0) ? 100 : 500)! }, geometry: g)
    }
    private func start(_ document: InstrumentDocument) throws -> PlayState {
        PlayEngine.step(PlayEngine.step(.init(), .install(try InstrumentCompiler.compile(document))).0, .sessionBegan(session)).0
    }
    private func step(_ state: inout PlayState, count: Int, orders: Set<Int>, time: Double) -> [MusicEvent] {
        let result = PlayEngine.step(state, .frame(frame(count, orders, time))); state = result.0; return result.1
    }
    private func ons(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case .noteOn(_, _, let note) = $0 { return note.number }; return nil }.sorted()
    }
    private func offs(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case .noteOff(_, _, let note) = $0 { return note.number }; return nil }.sorted()
    }
    func testToggleGuardDiscardsFlickerOnBothEdgesAndNeverReplaysAt90And361() throws {
        for count in [90, 361] { for guardSeconds in [0.5, 2.0] {
            var state = try start(document(count, guardSeconds: guardSeconds)); let a = count / 3
            XCTAssertEqual(ons(step(&state, count: count, orders: [a], time: 10)), [60], "First entry has no latency")
            _ = step(&state, count: count, orders: [], time: 10.01)
            XCTAssertTrue(step(&state, count: count, orders: [a], time: 10 + guardSeconds - 0.001).isEmpty)
            XCTAssertEqual(state.soundingNoteCount, 1, "Flicker must stay on")
            XCTAssertTrue(step(&state, count: count, orders: [a], time: 10 + guardSeconds).isEmpty, "Discarded entry is never replayed")
            _ = step(&state, count: count, orders: [], time: 10 + guardSeconds + 0.01)
            XCTAssertEqual(offs(step(&state, count: count, orders: [a], time: 10 + guardSeconds + 0.02)), [60])
            _ = step(&state, count: count, orders: [], time: 10 + guardSeconds + 0.03)
            XCTAssertTrue(step(&state, count: count, orders: [a], time: 10 + guardSeconds + 0.04).isEmpty)
            XCTAssertEqual(state.soundingNoteCount, 0, "Protection also follows switching off")
            XCTAssertTrue(step(&state, count: count, orders: [a], time: 10 + 2 * guardSeconds + 0.03).isEmpty)
            _ = step(&state, count: count, orders: [], time: 10 + 2 * guardSeconds + 0.04)
            XCTAssertEqual(ons(step(&state, count: count, orders: [a], time: 10 + 2 * guardSeconds + 0.05)), [60])
        } }
    }
    func testZeroAndExactExpiryUseFreshMeasuredEdges() throws {
        for count in [90, 361] { for seconds in [0.0, 0.5] {
            var state = try start(document(count, guardSeconds: seconds)); let a = count / 3
            _ = step(&state, count: count, orders: [a], time: 10)
            _ = step(&state, count: count, orders: [], time: 10 + seconds / 2)
            XCTAssertEqual(offs(step(&state, count: count, orders: [a], time: 10 + seconds)), [60])
            _ = step(&state, count: count, orders: [], time: 10 + seconds * 1.5)
            XCTAssertEqual(ons(step(&state, count: count, orders: [a], time: 10 + seconds * 2)), [60])
        } }
    }
    func testConnectedSegmentsOverridesAndDisconnectedSurfacesHaveIndependentGuards() throws {
        for count in [90, 361] {
            var state = try start(document(count)); let a = count / 3, b = count * 2 / 3
            _ = step(&state, count: count, orders: [a], time: 10)
            XCTAssertTrue(step(&state, count: count, orders: [a + 1], time: 10.6).isEmpty, "Motion inside one connected surface is not entry")
            XCTAssertEqual(ons(step(&state, count: count, orders: [a + 1, a + 2, b], time: 10.61)), [64], "Other surfaces enter independently; shared note has one On")
            XCTAssertEqual(state.soundingNoteCount, 2)
            _ = step(&state, count: count, orders: [], time: 10.62)
            XCTAssertTrue(step(&state, count: count, orders: [a, a + 2, b], time: 10.63).isEmpty)
            XCTAssertEqual(state.soundingNoteCount, 2, "A switches off but B keeps shared note; overrides and B are guarded")
            _ = step(&state, count: count, orders: [], time: 11.1)
            XCTAssertEqual(offs(step(&state, count: count, orders: [a + 2, b], time: 11.11)), [60, 64])
        }
    }
    func testReleaseLayerAndPanicAreImmediateDuringProtectionAndDoNotReplay() throws {
        for count in [90, 361] { for reverse in [false, true] { for panic in [false, true] {
            var state = try start(document(count, guardSeconds: 2, reverse: reverse)); let a = count / 3
            _ = step(&state, count: count, orders: [a], time: 10)
            let released: [MusicEvent]
            if panic { let result = PlayEngine.step(state, .panic); state = result.0; released = result.1 }
            else { released = step(&state, count: count, orders: [a, count - 5], time: 10.01) }
            XCTAssertEqual(offs(released), [60]); XCTAssertEqual(state.soundingNoteCount, 0)
            XCTAssertTrue(ons(step(&state, count: count, orders: [a], time: 12.1)).isEmpty)
            _ = step(&state, count: count, orders: [], time: 12.2)
            XCTAssertEqual(ons(step(&state, count: count, orders: [a], time: 12.3)), [60])
        } } }
    }
    func testInputLossKeepsGuardAndMeasuredExitRequirement() throws {
        for count in [90, 361] {
            var state = try start(document(count)); let a = count / 3
            _ = step(&state, count: count, orders: [a], time: 10)
            state = PlayEngine.step(state, .inputLost).0
            XCTAssertTrue(step(&state, count: count, orders: [a], time: 10.1).isEmpty)
            _ = step(&state, count: count, orders: [], time: 10.2)
            XCTAssertTrue(step(&state, count: count, orders: [a], time: 10.3).isEmpty)
            XCTAssertEqual(state.soundingNoteCount, 1)
            _ = step(&state, count: count, orders: [], time: 10.4)
            XCTAssertEqual(offs(step(&state, count: count, orders: [a], time: 10.5)), [60])
        }
    }
    func testGuardEditRetainsAcceptedEdgeAndLeavesOtherTransitionsUnchanged() throws {
        for transition in [SpatialNoteTransition.toggle, .legato, .holdUntilNext] {
            var source = try document(90)
            func replacing(_ document: InstrumentDocument, seconds: Double) throws -> InstrumentDocument {
                var result = document
                result.spatial = try .init(latticeVersion: document.spatial.latticeVersion, layers: document.spatial.layers.map { layer in
                    let routes = layer.routings.map { routing -> SpatialRouting in
                        var route = routing
                        if layer.id == layerID { route.program = .singleNote(note: 60, velocity: 100, transition: transition) }
                        return route
                    }
                    return .init(id: layer.id, name: layer.name, color: layer.color, isVisible: layer.isVisible,
                        isActive: layer.isActive, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
                        cells: layer.cells, routings: routes, cellOverrides: layer.cellOverrides, toggleGuardSeconds: seconds)
                }, selectedLayerID: layerID)
                result.revision = try document.revision.advanced()
                return result
            }
            source = try replacing(source, seconds: 0.5)
            var state = try start(source)
            _ = step(&state, count: 90, orders: [30], time: 10)
            let replacement = try replacing(source, seconds: 1)
            let compiled = try InstrumentCompiler.compile(replacement)
            let installed = PlayEngine.step(state, .install(compiled)); state = installed.0
            XCTAssertTrue(installed.1.isEmpty); XCTAssertEqual(state.soundingNoteCount, 1)
            if transition == .toggle {
                _ = step(&state, count: 90, orders: [], time: 10.01)
                XCTAssertTrue(step(&state, count: 90, orders: [30], time: 10.5).isEmpty, "New duration uses the original accepted edge")
                _ = step(&state, count: 90, orders: [], time: 10.6)
                XCTAssertEqual(offs(step(&state, count: 90, orders: [30], time: 11)), [60])
            } else {
                XCTAssertEqual(compiled.layers, try InstrumentCompiler.compile(source).layers, "Unused guard must not reinstall musical state")
            }
        }
    }
}

final class HaltenToggleTests: XCTestCase {
    private struct Harness {
        let session = UUID(), documentSession = UUID()
        let ordinary = UUID(), hold = UUID(), toggle = UUID(), control = UUID()
        let normalRoute = UUID(), holdRoute = UUID(), toggleRoute = UUID(), controlRoute = UUID()
        let count: Int
        var geometry: ProfileGeometryIdentity {
            .init(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
        }
        func cell(_ order: Int) -> PolarDeviceLattice {
            PolarDeviceLattice(ring: 100, sector: geometry.tickSpan(at: order)!.lower)!
        }
        func document(reverse: Bool = false, shared: Bool = false, ownRelease: UUID? = nil, guardSeconds: Double = 0.5) throws -> InstrumentDocument {
            func layer(_ id: UUID, _ name: String, _ order: Int, _ route: UUID, _ note: Int, _ transition: SpatialNoteTransition) -> SpatialDocumentLayer {
                .init(id: id, name: name, color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                      cells: [cell(order)], routings: [.init(id: route, target: .midiNote(channel: 0), program: .chord(notes: [note], velocity: 100, transition: transition))], cellOverrides: [:])
            }
            var toggleLayer = layer(toggle, "Am", 60, toggleRoute, shared ? 64 : 67, .toggle)
            toggleLayer = .init(id: toggleLayer.id, name: toggleLayer.name, color: toggleLayer.color, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: [cell(60), cell(70)], routings: toggleLayer.routings,
                cellOverrides: [cell(70): [.init(target: .midiNote(channel: 0), value: .note(number: 72, velocity: 100))]], toggleGuardSeconds: guardSeconds)
            let releaseTarget = SpatialRoutingTarget.releaseLayer(layerID: toggle)
            var layers = [layer(ordinary, "Ordinary", 10, normalRoute, 60, .legato),
                          layer(hold, "Hold", 40, holdRoute, 64, .holdUntilNext), toggleLayer,
                          SpatialDocumentLayer(id: control, name: "Release", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                            cells: [cell(80)], routings: [.init(id: controlRoute, target: releaseTarget, program: .constant(1))],
                            cellOverrides: ownRelease.map { [cell(80): [.init(target: releaseTarget, value: .releaseLayer(layerID: $0))]] } ?? [:])]
            if reverse { layers.reverse() }
            return .init(spatial: try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: toggle),
                         detection: .allStagesOff, revision: .init(session: documentSession, counter: 1))
        }
        func frame(_ orders: Set<Int>, _ time: Double = 10, session id: UUID? = nil) -> ProfileFrame {
            .init(sessionID: id ?? session, sequence: UInt64(time * 100), time: time,
                  measurements: (0..<count).map { DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: orders.contains($0) ? 100 : 500)! }, geometry: geometry)
        }
        func start(_ document: InstrumentDocument? = nil) throws -> PlayState {
            let state = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(document ?? self.document()))).0
            return PlayEngine.step(state, .sessionBegan(session)).0
        }
    }
    private func ons(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case .noteOn(_, _, let note) = $0 { return note.number }; return nil }.sorted()
    }
    private func offs(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case .noteOff(_, _, let note) = $0 { return note.number }; return nil }.sorted()
    }
    func testToggleParallelCellsDwellExitAndReentryAt90And361BothLayerOrders() throws {
        for count in [90, 361] { for reverse in [false, true] {
            let h = Harness(count: count)
            var state = try h.start(h.document(reverse: reverse, guardSeconds: 0))
            let on = PlayEngine.step(state, .frame(h.frame([60, 70])))
            XCTAssertEqual(ons(on.1), [67, 72]); state = on.0
            XCTAssertTrue(PlayEngine.step(state, .frame(h.frame([60, 70], 10.01))).1.isEmpty)
            state = PlayEngine.step(state, .frame(h.frame([70], 10.02))).0
            XCTAssertEqual(state.soundingNoteCount, 2)
            let off = PlayEngine.step(state, .frame(h.frame([60, 70], 10.03)))
            XCTAssertEqual(offs(off.1), [67]); XCTAssertEqual(off.0.soundingNoteCount, 1)
            state = PlayEngine.step(off.0, .frame(h.frame([], 10.04))).0
            let final = PlayEngine.step(state, .frame(h.frame([70], 10.05)))
            XCTAssertEqual(offs(final.1), [72]); XCTAssertEqual(final.0.soundingNoteCount, 0)
        } }
    }
    func testToggleLossReturnDoesNotRearmWithoutMeasuredExit() throws {
        for loss: (UUID) -> PlayInput in [{ _ in .inputLost }, { _ in .timeAdvanced(20) }, { .sessionEnded($0, reason: .failure) }] {
            let h = Harness(count: 90)
            let on = PlayEngine.step(try h.start(), .frame(h.frame([60])))
            let lost = PlayEngine.step(on.0, loss(h.session))
            XCTAssertTrue(offs(lost.1).isEmpty); XCTAssertEqual(lost.0.soundingNoteCount, 1)
            var state = lost.0
            if state.sessionID == nil { state = PlayEngine.step(state, .sessionBegan(UUID())).0 }
            let id = try XCTUnwrap(state.sessionID)
            let returned = PlayEngine.step(state, .frame(h.frame([60], 20.01, session: id)))
            XCTAssertTrue(returned.1.isEmpty); XCTAssertEqual(returned.0.soundingNoteCount, 1)
            state = PlayEngine.step(returned.0, .frame(h.frame([], 20.02, session: id))).0
            let off = PlayEngine.step(state, .frame(h.frame([60], 20.03, session: id)))
            XCTAssertEqual(offs(off.1), [67]); XCTAssertEqual(off.0.soundingNoteCount, 0)
        }
    }
    func testHoldLossThenNewTriggerStillReplacesChannelHold() throws {
        for count in [90, 361] {
            let h = Harness(count: count)
            var state = PlayEngine.step(try h.start(), .frame(h.frame([40]))).0
            let lost = PlayEngine.step(state, .inputLost)
            XCTAssertTrue(lost.1.isEmpty); XCTAssertEqual(lost.0.soundingNoteCount, 1)
            state = lost.0
            let replacing = PlayEngine.step(state, .frame(h.frame([10], 11)))
            XCTAssertEqual(offs(replacing.1), [64]); XCTAssertEqual(ons(replacing.1), [60])
        }
    }
    func testReleaseLayerSharedNoteKeepsForeignOwnerInBothOrders() throws {
        for reverse in [false, true] {
            let h = Harness(count: 90)
            let doc = try h.document(reverse: reverse, shared: true)
            let on = PlayEngine.step(try h.start(doc), .frame(h.frame([40, 60])))
            XCTAssertEqual(ons(on.1), [64]); XCTAssertEqual(on.0.soundingNoteCount, 1)
            // Keep the Hold cell selected: release-layer must not remove it.
            let release = PlayEngine.step(on.0, .frame(h.frame([40, 80], 10.01)))
            XCTAssertTrue(offs(release.1).isEmpty); XCTAssertEqual(release.0.soundingNoteCount, 1)
            let reset = PlayEngine.step(release.0, .panic)
            XCTAssertEqual(offs(reset.1), [64]); XCTAssertEqual(reset.0.soundingNoteCount, 0)
        }
    }
    func testReleaseLayerOnlyLatchedOwnersAndPerCellOverrideMissingTarget() throws {
        let h = Harness(count: 361)
        var state = PlayEngine.step(try h.start(), .frame(h.frame([10, 40, 60, 70]))).0
        let released = PlayEngine.step(state, .frame(h.frame([10, 40, 80], 10.01)))
        XCTAssertEqual(offs(released.1), [67, 72]); XCTAssertEqual(released.0.soundingNoteCount, 2)
        // A new toggle entry while dwelling on Release may start; no repeat release.
        let dwell = PlayEngine.step(released.0, .frame(h.frame([10, 40, 60, 80], 10.02)))
        XCTAssertEqual(ons(dwell.1), [67])
        let own = try h.document(ownRelease: h.hold)
        state = PlayEngine.step(try h.start(own), .frame(h.frame([40, 60]))).0
        let ownResult = PlayEngine.step(state, .frame(h.frame([80], 10.01)))
        XCTAssertEqual(offs(ownResult.1), [64]); XCTAssertEqual(ownResult.0.soundingNoteCount, 1)
        state = PlayEngine.step(try h.start(h.document(ownRelease: UUID())), .frame(h.frame([60]))).0
        XCTAssertTrue(PlayEngine.step(state, .frame(h.frame([80], 10.01))).1.isEmpty)
    }
    func testReleaseLayerBatchWinsOverNewLatchRegardlessOfLayerOrder() throws {
        for reverse in [false, true] {
            let h = Harness(count: 90)
            let result = PlayEngine.step(try h.start(h.document(reverse: reverse)), .frame(h.frame([60, 70, 80])))
            XCTAssertTrue(result.1.isEmpty); XCTAssertEqual(result.0.soundingNoteCount, 0)
        }
    }
    func testToggleIsNotReplacedByNewChannelHoldAndCoalescesDifferentVelocities() throws {
        let h = Harness(count: 90)
        var state = PlayEngine.step(try h.start(), .frame(h.frame([60]))).0
        state = PlayEngine.step(state, .frame(h.frame([40], 10.01))).0
        XCTAssertEqual(state.soundingNoteCount, 2)
        let newNote = PlayEngine.step(state, .frame(h.frame([10], 10.02)))
        XCTAssertEqual(offs(newNote.1), [64]); XCTAssertEqual(newNote.0.soundingNoteCount, 2)
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        let a = UUID(), b = UUID(), cell = h.cell(60)
        func value(_ id: UUID, _ velocity: UInt8) -> SpatialRoutingEvaluation {
            .init(routingID: id, target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), value: .notes([.init(number: 60, velocity: velocity)], transition: .toggle), cell: cell)
        }
        XCTAssertEqual(ledger.apply([value(a, 70), value(b, 110)]).count, 1)
        _ = ledger.apply([])
        XCTAssertTrue(ledger.apply([value(b, 110)]).isEmpty)
        XCTAssertEqual(ledger.heldNoteCount, 1)
        _ = ledger.apply([])
        XCTAssertEqual(ledger.apply([value(a, 70)]).count, 1)
        XCTAssertEqual(ledger.heldNoteCount, 0)
    }
    func testDeletionMoveRoutingAndLayerRemovalReleaseOnlyAffectedToggleCells() throws {
        for edit in 0..<4 {
            let h = Harness(count: 361)
            var doc = try h.document()
            let on = PlayEngine.step(try h.start(doc), .frame(h.frame([60, 70])))
            var layers = doc.spatial.layers
            let index = try XCTUnwrap(layers.firstIndex { $0.id == h.toggle })
            let old = layers[index]
            if edit == 3 { layers.remove(at: index) }
            else {
                var cells = old.cells, routes = old.routings
                if edit == 0 || edit == 1 { cells.remove(h.cell(60)) }
                if edit == 1 { cells.insert(h.cell(61)) }
                if edit == 2 { routes[0].target = .midiNote(channel: 1) }
                layers[index] = .init(id: old.id, name: old.name, color: old.color, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                    cells: cells, routings: routes, cellOverrides: old.cellOverrides)
            }
            doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: h.ordinary)
            doc.revision = .init(session: h.documentSession, counter: 2)
            let installed = PlayEngine.step(on.0, .install(try InstrumentCompiler.compile(doc)))
            XCTAssertEqual(offs(installed.1), edit < 2 ? [67] : [67, 72])
            XCTAssertEqual(installed.0.soundingNoteCount, edit < 2 ? 1 : 0)
            XCTAssertTrue(ons(installed.1).isEmpty)
        }
    }
    func testFullReleaseMatrixOrdinaryHoldToggleIncludingPresetAndInstrumentChange() throws {
        let h = Harness(count: 90)
        let doc = try h.document()
        let on = PlayEngine.step(try h.start(doc), .frame(h.frame([10, 40, 60])))
        let inputs: [(String, PlayInput, Bool)] = [
            ("stale", .timeAdvanced(20), true), ("inputLost", .inputLost, true),
            ("error end", .sessionEnded(h.session, reason: .failure), true),
            ("PANIC", .panic, false), ("stop", .stop, false), ("sleep", .sleep, false),
            ("wake", .wake, false), ("terminate", .terminate, false),
            ("user disconnect/input change", .sessionEnded(h.session, reason: .userRequested), false),
            ("live input change", .sessionBegan(UUID()), false)]
        for (name, input, persistent) in inputs {
            let result = PlayEngine.step(on.0, input)
            XCTAssertEqual(offs(result.1), persistent ? [60] : [60, 64, 67], name)
            XCTAssertEqual(result.0.soundingNoteCount, persistent ? 2 : 0, name)
        }
        var preset = doc; preset.revision = .newSession()
        XCTAssertEqual(offs(PlayEngine.step(on.0, .install(try InstrumentCompiler.compile(preset))).1), [60, 64, 67])
        var changed = doc; changed.revision = .init(session: h.documentSession, counter: 2)
        changed.channel.instrument = InstrumentPlugin(identity: .init(componentType: 1, componentSubType: 2, componentManufacturer: 3))
        let auChange = PlayEngine.step(on.0, .install(try InstrumentCompiler.compile(changed)))
        XCTAssertTrue(offs(auChange.1).isEmpty, "An AU identity change does not own MIDI notes")
        XCTAssertEqual(auChange.0.soundingNoteCount, 3)
        changed.midiTarget = .init(uniqueID: 99)
        changed.revision = try changed.revision.advanced()
        let midiChange = PlayEngine.step(auChange.0, .install(try InstrumentCompiler.compile(changed)))
        XCTAssertEqual(offs(midiChange.1), [60, 64, 67])
        XCTAssertEqual(midiChange.0.soundingNoteCount, 0)
    }
    func testPersistenceRoundTripIncludesToggleAndReleaseLayerOverrides() throws {
        let h = Harness(count: 361), doc = try h.document(ownRelease: UUID())
        let decoded = try SpatialDocument.decode(JSONEncoder().encode(doc.spatial))
        XCTAssertEqual(decoded, doc.spatial)
        XCTAssertEqual(try InstrumentCompiler.compile(.init(spatial: decoded, detection: .allStagesOff, revision: .newSession())).layers.count, 4)
    }
    func testConfirmationAfterLossCannotMasqueradeAsMeasuredExit() throws {
        let h = Harness(count: 90)
        var doc = try h.document()
        doc.detection = .init(groupingEnabled: false, representative: .nearestPoint, cellSelection: .init(confirmationProfiles: 2), minimumAngleDegrees: 0)
        var state = PlayEngine.step(try h.start(doc), .frame(h.frame([60]))).0
        XCTAssertEqual(state.soundingNoteCount, 0)
        state = PlayEngine.step(state, .frame(h.frame([60], 10.01))).0
        XCTAssertEqual(state.soundingNoteCount, 1)
        state = PlayEngine.step(state, .inputLost).0
        for time in [11.0, 11.01, 11.02] {
            let returned = PlayEngine.step(state, .frame(h.frame([60], time)))
            XCTAssertTrue(returned.1.isEmpty); XCTAssertEqual(returned.0.soundingNoteCount, 1)
            state = returned.0
        }
        state = PlayEngine.step(state, .frame(h.frame([], 11.03))).0
        state = PlayEngine.step(state, .frame(h.frame([60], 11.04))).0
        let off = PlayEngine.step(state, .frame(h.frame([60], 11.05)))
        XCTAssertEqual(offs(off.1), [67]); XCTAssertEqual(off.0.soundingNoteCount, 0)
        state = PlayEngine.step(off.0, .frame(h.frame([], 11.06))).0
        state = PlayEngine.step(state, .frame(h.frame([60], 11.07))).0
        state = PlayEngine.step(state, .frame(h.frame([60], 11.08))).0
        state = PlayEngine.step(state, .panic).0
        state = PlayEngine.step(state, .inputLost).0
        for time in [12.0, 12.01, 12.02] {
            let stayed = PlayEngine.step(state, .frame(h.frame([60], time)))
            XCTAssertTrue(stayed.1.isEmpty); XCTAssertEqual(stayed.0.soundingNoteCount, 0)
            state = stayed.0
        }
    }
    func testToggleSingleNoteAndChordSharedOwnershipInBothEntryOrders() throws {
        for reverse in [false, true] {
            let h = Harness(count: 361)
            var doc = try h.document(), layers = doc.spatial.layers
            let i = layers.firstIndex { $0.id == h.toggle }!, old = layers[i]
            var routes = old.routings
            routes[0].program = .singleNote(note: 60, velocity: 100, transition: .toggle)
            layers[i] = .init(id: old.id, name: old.name, color: old.color, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: old.cells, routings: routes, cellOverrides: old.cellOverrides)
            if reverse { layers.reverse() }
            doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: h.toggle)
            let on = PlayEngine.step(try h.start(doc), .frame(h.frame([60, 70])))
            XCTAssertEqual(on.0.soundingNoteCount, 2)
            let leaving = PlayEngine.step(on.0, .frame(h.frame([], 10.01)))
            XCTAssertTrue(leaving.1.isEmpty)
            let off = PlayEngine.step(leaving.0, .frame(h.frame([60, 70], 10.5)))
            XCTAssertEqual(off.0.soundingNoteCount, 0); XCTAssertEqual(offs(off.1).count, 2)
        }
    }
    func testInstallWhileToggleCellSelectedCannotIntroduceAnOrdinaryOwner() throws {
        let h = Harness(count: 361)
        var doc = try h.document()
        let on = PlayEngine.step(try h.start(doc), .frame(h.frame([60])))
        doc.revision = .init(session: h.documentSession, counter: 2)
        // Editing the other cell exercises ownership retention during install.
        var layers = doc.spatial.layers
        let index = layers.firstIndex { $0.id == h.toggle }!, old = layers[index]
        layers[index] = .init(id: old.id, name: old.name, color: old.color, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: old.cells, routings: old.routings, cellOverrides: [:])
        doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: h.toggle)
        let installed = PlayEngine.step(on.0, .install(try InstrumentCompiler.compile(doc)))
        XCTAssertTrue(installed.1.isEmpty); XCTAssertEqual(installed.0.soundingNoteCount, 1)
        let left = PlayEngine.step(installed.0, .frame(h.frame([], 10.01)))
        let guarded = PlayEngine.step(left.0, .frame(h.frame([60], 10.02)))
        XCTAssertTrue(guarded.1.isEmpty, "Unrelated edit retains protection")
        let exited = PlayEngine.step(guarded.0, .frame(h.frame([], 10.49)))
        let off = PlayEngine.step(exited.0, .frame(h.frame([60], 10.5)))
        XCTAssertEqual(offs(off.1), [67]); XCTAssertEqual(off.0.soundingNoteCount, 0)
    }
    func testReleaseLayerCannotRestartHeldChordFromDwellingAfterReleaseOrLoss() throws {
        let h = Harness(count: 90)
        var state = PlayEngine.step(try h.start(h.document(ownRelease: h.hold)), .frame(h.frame([40]))).0
        let released = PlayEngine.step(state, .frame(h.frame([40, 80], 10.01)))
        XCTAssertEqual(offs(released.1), [64]); XCTAssertEqual(released.0.soundingNoteCount, 0)
        state = released.0
        for time in [10.02, 10.03] {
            let dwell = PlayEngine.step(state, .frame(h.frame([40, 80], time)))
            XCTAssertTrue(dwell.1.isEmpty); state = dwell.0
        }
        state = PlayEngine.step(state, .inputLost).0
        XCTAssertTrue(PlayEngine.step(state, .frame(h.frame([40, 80], 11))).1.isEmpty)
        state = PlayEngine.step(state, .frame(h.frame([80], 11.01))).0
        let fresh = PlayEngine.step(state, .frame(h.frame([40, 80], 11.02)))
        XCTAssertEqual(ons(fresh.1), [64])
    }
    func testPanicHoldRemainsBlockedAcrossLossAndReconfirmationUntilMeasuredExit() throws {
        let h = Harness(count: 361)
        var doc = try h.document()
        doc.detection = .init(groupingEnabled: false, representative: .nearestPoint, cellSelection: .init(confirmationProfiles: 2), minimumAngleDegrees: 0)
        var state = PlayEngine.step(try h.start(doc), .frame(h.frame([40]))).0
        state = PlayEngine.step(state, .frame(h.frame([40], 10.01))).0
        XCTAssertEqual(state.soundingNoteCount, 1)
        let panic = PlayEngine.step(state, .panic)
        XCTAssertEqual(offs(panic.1), [64])
        state = PlayEngine.step(panic.0, .inputLost).0
        for time in [11.0, 11.01, 11.02] {
            let stayed = PlayEngine.step(state, .frame(h.frame([40], time)))
            XCTAssertTrue(stayed.1.isEmpty); XCTAssertEqual(stayed.0.soundingNoteCount, 0)
            state = stayed.0
        }
        state = PlayEngine.step(state, .frame(h.frame([], 11.03))).0
        let fresh = PlayEngine.step(state, .frame(h.frame([40], 11.04)))
        XCTAssertEqual(ons(fresh.1), [64]); XCTAssertEqual(fresh.0.soundingNoteCount, 1)
        XCTAssertTrue(PlayEngine.step(fresh.0, .frame(h.frame([40], 11.05))).1.isEmpty)
    }
}

final class HaltenWechselLedgerTests: XCTestCase {
    let ids = (0..<7).map { _ in UUID() }
    let chords: [[UInt8]] = [[62, 65, 69], [60, 65, 69], [60, 64, 69], [60, 64, 67], [59, 64, 67], [59, 62, 67], [59, 62, 66]]
    func values(_ active: Set<Int>) -> [SpatialRoutingEvaluation] {
        ids.indices.map { i in .init(routingID: ids[i], target: .midiNote(channel: 0), value: active.contains(i)
            ? .notes(Set(chords[i].map { .init(number: $0, velocity: 100) }), transition: .holdUntilNext) : .inactive) }
    }
    func sounding(_ ledger: SpatialNoteLedger) -> Set<UInt8> {
        Set(ledger.soundingCommands.compactMap { if case .noteOn(_, _, let n) = $0 { return n.number }; return nil })
    }
    func testReinstallCannotResurrectDisplacedOwnersAndLossDoesNotReclaimChannel() {
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        _ = ledger.apply(values([4]))
        _ = ledger.apply(values([3, 4]))
        XCTAssertTrue(ledger.retainSupported(by: values(Set(ids.indices))).isEmpty)
        XCTAssertEqual(ledger.holdOwnerCountByChannel.values.reduce(0, +), 1)
        XCTAssertTrue(ledger.releaseTransient().isEmpty)
        XCTAssertTrue(ledger.apply(values([3, 4])).isEmpty)
        XCTAssertEqual(sounding(ledger), Set(chords[3]))
        XCTAssertEqual(ledger.releaseAll().count, 3)
        XCTAssertTrue(ledger.holdOwnerCountByChannel.isEmpty)
    }
    func testMeasuredWinnerExitHandsOffToRemainingNeighbourButFreshMusicWinsFirst() {
        func contact(_ active: Set<Int>) -> [SpatialRoutingEvaluation] {
            values(active).map { value in .init(routingID: value.routingID, target: value.target,
                value: value.value, cell: .init(ring: 100, sector: 180)) }
        }
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        _ = ledger.apply(contact([2, 3])) // Am wins the simultaneous overlap.
        XCTAssertEqual(sounding(ledger), Set(chords[2]))
        _ = ledger.apply(contact([3])) // C was already touched, now exposed.
        XCTAssertEqual(sounding(ledger), Set(chords[3]))
        XCTAssertTrue(ledger.apply(contact([3])).isEmpty)
        _ = ledger.apply(contact([2, 3]))
        XCTAssertEqual(sounding(ledger), Set(chords[2]))
        _ = ledger.apply(contact([3, 4])) // Fresh Em outranks ongoing C.
        XCTAssertEqual(sounding(ledger), Set(chords[4]))
        _ = ledger.apply(contact([]))
        XCTAssertEqual(sounding(ledger), Set(chords[4]), "Empty/lost input retains Hold")
    }

    func contacts(_ active: Set<Int>, spacing: Int = 5) -> [SpatialRoutingEvaluation] {
        values(active).enumerated().map { index, value in
            .init(routingID: value.routingID, target: value.target, value: value.value,
                  cell: .init(ring: 100 + ids.firstIndex(of: value.routingID)! * spacing, sector: 180))
        }
    }
    func testNeighbourBoundaryTenAgainstElevenIncludingInputLoss() {
        for spacing in [10, 11] { for lost in [false, true] {
            var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
            _ = ledger.apply(contacts([0, 1], spacing: spacing))
            XCTAssertEqual(sounding(ledger), Set(chords[0]))
            if lost { XCTAssertTrue(ledger.releaseTransient().isEmpty) }
            _ = ledger.apply(contacts([1], spacing: spacing))
            XCTAssertEqual(sounding(ledger), Set(chords[spacing == 10 ? 1 : 0]))
        } }
    }
    func testNeighbourChainTransfersAcrossTwoMeasuredExits() {
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        for (active, winner): (Set<Int>, Int) in [([0, 1, 2], 0), ([1, 2], 1), ([2], 2)] {
            _ = ledger.apply(contacts(active))
            XCTAssertEqual(sounding(ledger), Set(chords[winner]))
            XCTAssertEqual(ledger.holdOwnerCountByChannel.values.reduce(0, +), 1)
        }
        XCTAssertEqual(ledger.releaseAll().count, 3)
    }

    func testRandomSequencesHaveAtMostOneOwnerAndExactlyItsChord() {
        var random: UInt64 = 0xC0FFEE
        for _ in 0..<8 {
            var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
            var previous: Set<Int> = [], winner: Int?
            for _ in 0..<500 {
                random = random &* 6364136223846793005 &+ 1
                let active = Set(ids.indices.filter { (random >> 32) & (1 << $0) != 0 })
                if let fresh = active.subtracting(previous).min() { winner = fresh }
                else if let old = winner, previous.contains(old), !active.contains(old),
                        let neighbour = active.filter({ abs($0 - old) * 5 <= 10 }).min() { winner = neighbour }
                _ = ledger.apply(contacts(active))
                XCTAssertTrue(ledger.holdOwnerCountByChannel.values.allSatisfy { $0 <= 1 })
                XCTAssertEqual(sounding(ledger), winner.map { Set(chords[$0]) } ?? [])
                previous = active
            }
        }
    }
    func testCommonNotePolicyHoldLegatoAndToggle() {
        for mode in [SpatialNoteTransition.holdUntilNext, .legato, .toggle] {
            for policy in SpatialCommonNotes.allCases {
                var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
                let first = ids[0], next = mode == .legato ? first : ids[1]
                func value(_ id: UUID, _ notes: [UInt8]) -> SpatialRoutingEvaluation {
                    .init(routingID: id, target: .midiNote(channel: 0),
                        value: .notes(Set(notes.map { .init(number: $0, velocity: 100) }), transition: mode),
                        cell: .init(ring: 100, sector: 180), commonNotes: policy)
                }
                _ = ledger.apply([value(first, [59, 64, 67])])
                let commands = ledger.apply(mode == .legato ? [value(next, [60, 64, 67])] : [value(first, [59, 64, 67]), value(next, [60, 64, 67])])
                for number: UInt8 in [64, 67] {
                    let shared = commands.filter { switch $0 { case .noteOff(_, _, let n), .noteOn(_, _, let n): return n.number == number; default: return false } }
                    XCTAssertEqual(shared, policy == .keep ? [] : [.noteOff(destination: .midi, channel: 0, note: .init(number: number, velocity: 100)), .noteOn(destination: .midi, channel: 0, note: .init(number: number, velocity: 100))])
                }
            }
        }
    }
    func testReroutingSameHeldPitchesStartsOnNewChannelAfterInstall() {
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        _ = ledger.apply(values([4]))
        let rerouted = values([4]).map { SpatialRoutingEvaluation(routingID: $0.routingID,
            target: .midiNote(channel: 1), value: $0.value) }
        XCTAssertEqual(ledger.retainSupported(by: rerouted).count, 3)
        let commands = ledger.apply(rerouted)
        XCTAssertEqual(commands.count, 3)
        XCTAssertTrue(commands.allSatisfy { if case .noteOn(_, 1, _) = $0 { return true }; return false })
        XCTAssertEqual(ledger.holdOwnerCountByChannel.values.reduce(0, +), 1)
    }
    func testIdenticalChordsTransferOwnershipWithKeepAndRetrigger() {
        for policy in SpatialCommonNotes.allCases {
            var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
            func value(_ id: UUID) -> SpatialRoutingEvaluation {
                .init(routingID: id, target: .midiNote(channel: 0),
                    value: .notes([.init(number: 64, velocity: 100)], transition: .holdUntilNext), commonNotes: policy)
            }
            _ = ledger.apply([value(ids[0])])
            let commands = ledger.apply([value(ids[0]), value(ids[1])])
            XCTAssertEqual(commands.count, policy == .keep ? 0 : 2)
            XCTAssertEqual(ledger.holdOwnerCountByChannel.values.reduce(0, +), 1)
            XCTAssertTrue(ledger.releaseLatched(routingIDs: [ids[0]]).isEmpty)
            XCTAssertEqual(ledger.releaseLatched(routingIDs: [ids[1]]).count, 1)
        }
    }
    func testPersistenceDefaultsAndRoundTrip() throws {
        var layer = SpatialInstrumentLayer(name: "Common", color: .orange)
        layer.commonNotes = .retrigger
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(SpatialInstrumentLayer.self, from: encoder.encode(layer)).commonNotes, .retrigger)
        let workspace = SpatialInstrumentWorkspace(layers: [layer])
        let legacy = try LegacySpatialDocumentReader.read(from: encoder.encode(workspace))
        XCTAssertEqual(legacy.document.layers.first?.commonNotes, .retrigger)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(layer)) as? [String: Any])
        json.removeValue(forKey: "commonNotes")
        XCTAssertEqual(try decoder.decode(SpatialInstrumentLayer.self, from: JSONSerialization.data(withJSONObject: json)).commonNotes, .keep)
        let document = SpatialDocumentLayer(id: layer.id, name: "Common", color: .orange, isVisible: true, isActive: true,
            isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:], commonNotes: .retrigger)
        XCTAssertEqual(try decoder.decode(SpatialDocumentLayer.self, from: encoder.encode(document)).commonNotes, .retrigger)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
        json.removeValue(forKey: "commonNotes")
        XCTAssertEqual(try decoder.decode(SpatialDocumentLayer.self, from: JSONSerialization.data(withJSONObject: json)).commonNotes, .keep)
    }
    func testOverlappingHoldEntriesReplaceInSameFrameAndNeverReclaimWhileDwelling() {
        for pair in [(4, 3), (2, 3), (3, 4), (0, 5), (0, 3)] {
            var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
            _ = ledger.apply(values([pair.0]))
            let commands = ledger.apply(values([pair.0, pair.1]))
            if ProcessInfo.processInfo.environment["SICK_HALTEN_TRACE"] == "1" {
                let trace = commands.compactMap { command -> String? in
                    switch command { case .noteOn(_, _, let n): return "+\(n.number)"; case .noteOff(_, _, let n): return "-\(n.number)"; default: return nil }
                }
                print("HALTEN_TRACE \(pair.0)->\(pair.1): \(trace.joined(separator: " "))")
            }
            XCTAssertEqual(sounding(ledger), Set(chords[pair.1]))
            XCTAssertEqual(ledger.heldNoteCount, 3)
            let common = Set(chords[pair.0]).intersection(chords[pair.1])
            XCTAssertFalse(commands.contains { command in
                switch command { case .noteOff(_, _, let n), .noteOn(_, _, let n): return common.contains(n.number); default: return false }
            }, "Common notes keep sounding")
            for active: Set<Int> in [[pair.0, pair.1], [pair.1], [], []] {
                XCTAssertTrue(ledger.apply(values(active)).isEmpty)
                XCTAssertEqual(sounding(ledger), Set(chords[pair.1]))
            }
        }
    }
}

extension HaltenWechselLedgerTests {
    func testRepresentativePriorityBeatsDocumentOrderForTwoThreeAndIndependentChannels() {
        for priorities in [[4.0, 0], [0.0, 4], [9.0, 4, 0], [4.0, 4]] {
            var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
            var inputs = values(Set(0..<priorities.count))
            for i in priorities.indices { inputs[i].representativeDistanceSquared = priorities[i] }
            _ = ledger.apply(inputs)
            let winner = priorities.indices.min { priorities[$0] < priorities[$1] }!
            XCTAssertEqual(sounding(ledger), Set(chords[winner]))
            XCTAssertTrue(ledger.apply(inputs).isEmpty, "Dwelling never reclaims")
        }
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        var first = values([0])[0]
        first.representativeDistanceSquared = 0
        var second = SpatialRoutingEvaluation(routingID: ids[1], target: .midiNote(channel: 1),
            value: .notes([.init(number: 72, velocity: 100)], transition: .holdUntilNext))
        second.representativeDistanceSquared = 0
        _ = ledger.apply([first, second])
        XCTAssertEqual(ledger.holdOwnerCountByChannel.count, 2)
    }
}

extension HaltenWechselLedgerTests {
    func testMeasuredMMKHandRepresentativeChoosesCenterZoneIncludingMirrorAndThreeZones() throws {
        for mirrored in [false, true] {
            for count in [2, 3] {
                let geometry = ProfileGeometryIdentity(operatingMode: "MMK", pointCount: 90, startAngleDegrees: -90, endAngleDegrees: 90)
                let order = mirrored ? 45 : 44
                let center = mirrored ? 182 : 178
                let ticks = count == 2 ? [center + (mirrored ? 2 : -2), center] : [center - 1, center + 1, center]
                let layers = ticks.enumerated().map { index, tick in
                    SpatialDocumentLayer(id: ids[index], name: "Zone", color: .orange,
                        isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                        cells: [PolarDeviceLattice(ring: 100, sector: tick)!],
                        routings: [.init(id: ids[index], target: .midiNote(channel: 0),
                            program: .singleNote(note: 60 + index, velocity: 100, transition: .holdUntilNext))], cellOverrides: [:])
                }
                var config = DetectionConfiguration.allStagesOff; config.representative = .mean
                let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: ids[0])
                let compiled = try InstrumentCompiler.compile(.init(spatial: spatial, detection: config, revision: .newSession()))
                var state = PlayEngine.step(PlayState(), .install(compiled)).0
                let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 10,
                    measurements: [DeviceTickMeasurement(order: order, ticks: geometry.tickSpan(at: order)!, rawCentimeters: 100)!], geometry: geometry)
                state = PlayEngine.step(state, .frame(frame)).0
                let pitches = state.soundingEvents.compactMap { event -> UInt8? in
                    if case .noteOn(_, _, let note) = event { return note.number }; return nil
                }
                XCTAssertEqual(pitches, [UInt8(60 + count - 1)])
                XCTAssertEqual(state.heldCells.first?.layerID, ids[count - 1])
            }
        }
    }
}

extension HaltenWechselLedgerTests {
    func testTwoHandsUseTheRepresentativeOfEachSelectedCarrier() throws {
        let geometry = ProfileGeometryIdentity(operatingMode: "MMK", pointCount: 90, startAngleDegrees: -90, endAngleDegrees: 90)
        let a = SpatialDocumentLayer(id: ids[0], name: "A", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [PolarDeviceLattice(ring: 100, sector: 176)!, PolarDeviceLattice(ring: 200, sector: 182)!],
            routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .holdUntilNext))], cellOverrides: [:])
        let b = SpatialDocumentLayer(id: ids[1], name: "B", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [PolarDeviceLattice(ring: 100, sector: 178)!],
            routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 64, velocity: 100, transition: .holdUntilNext))], cellOverrides: [:])
        var config = DetectionConfiguration.allStagesOff; config.representative = .mean
        let compiled = try InstrumentCompiler.compile(.init(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [a, b], selectedLayerID: a.id), detection: config, revision: .newSession()))
        let start = PlayEngine.step(PlayState(), .install(compiled)).0
        let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 10, measurements: [
            DeviceTickMeasurement(order: 44, ticks: geometry.tickSpan(at: 44)!, rawCentimeters: 100)!,
            DeviceTickMeasurement(order: 45, ticks: geometry.tickSpan(at: 45)!, rawCentimeters: 200)!
        ], geometry: geometry)
        let state = PlayEngine.step(start, .frame(frame)).0
        XCTAssertEqual(state.heldCells.map(\.layerID), [b.id], "The other hand inside A must not give A's left carrier a false containment priority")
    }
}
