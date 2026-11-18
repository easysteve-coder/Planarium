import XCTest
@testable import PlanariumDomain

final class SingleNoteTests: XCTestCase {
    private struct Harness {
        let layer = UUID(), route = UUID(), session = UUID(), revision = SpatialDocumentRevision.newSession()
        let count: Int
        let target: SpatialRoutingTarget
        var geometry: ProfileGeometryIdentity {
            .init(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count,
                  startAngleDegrees: -90, endAngleDegrees: 90)
        }
        var startTick: Int { geometry.tickSpan(at: 40)!.lower }
        var cells: Set<PolarDeviceLattice> {
            Set((100...124).flatMap { ring in
                (startTick...startTick + 12).map { PolarDeviceLattice(ring: ring, sector: $0)! }
            })
        }
        func document(_ program: SpatialValueProgram, override: Bool = false) throws -> InstrumentDocument {
            let actions: [SpatialCellAction] = [.init(target: target, value: .note(number: 72, velocity: 83))]
            let layer = SpatialDocumentLayer(id: layer, name: "Single", color: .orange,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: cells, routings: [.init(id: route, target: target, program: program)],
                cellOverrides: override ? Dictionary(uniqueKeysWithValues: cells.map { ($0, actions) }) : [:])
            return .init(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id),
                         detection: .allStagesOff, revision: revision)
        }
        func frame(_ points: [Int: UInt16], _ time: Double, session: UUID? = nil) -> ProfileFrame {
            .init(sessionID: session ?? self.session, sequence: UInt64(time * 1000), time: time,
                measurements: (0..<count).map {
                    DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: points[$0] ?? 500)!
                }, geometry: geometry)
        }
        func start(_ document: InstrumentDocument) throws -> PlayState {
            PlayEngine.step(PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(document))).0,
                            .sessionBegan(session)).0
        }
    }
    private func ons(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case .noteOn(_, _, let note) = $0 { return note.number }; return nil }.sorted()
    }
    private func offs(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case .noteOff(_, _, let note) = $0 { return note.number }; return nil }.sorted()
    }

    func testToggleMovementInPaintedSurfaceExitReentryAndMultipleRays90And361() throws {
        for count in [90, 361] {
            for variant in 0..<3 {
                let h = Harness(count: count, target: .midiNote(channel: 0))
                let program: SpatialValueProgram = variant == 1
                    ? .chord(notes: [60, 64], velocity: 83, transition: .toggle)
                    : .singleNote(note: 60, velocity: 83, transition: .toggle)
                let expected: [UInt8] = variant == 2 ? [72] : variant == 1 ? [60, 64] : [60]
                var state = try h.start(h.document(program, override: variant == 2))
                let on = PlayEngine.step(state, .frame(h.frame([40: 100, 41: 100], 1)))
                XCTAssertEqual(ons(on.1), expected); XCTAssertTrue(offs(on.1).isEmpty); state = on.0
                // One centimetre, then one tick (0.5 degrees at 361 points).
                for (points, time) in [([40: UInt16(101)], 1.01), ([41: UInt16(101)], 1.02), ([42: UInt16(102)], 1.03)] {
                    let moved = PlayEngine.step(state, .frame(h.frame(points, time)))
                    XCTAssertTrue(moved.1.isEmpty, "count=\(count), variant=\(variant), movement=\(points)")
                    XCTAssertEqual(moved.0.soundingNoteCount, expected.count); state = moved.0
                }
                state = PlayEngine.step(state, .frame(h.frame([:], 1.04))).0
                let off = PlayEngine.step(state, .frame(h.frame([41: 101, 42: 102], 1.5)))
                XCTAssertEqual(offs(off.1), expected); XCTAssertTrue(ons(off.1).isEmpty)
                XCTAssertEqual(off.0.soundingNoteCount, 0)
            }
        }
    }

    func testToggleLossAndPanicDoNotRearmByMovingInsideSurface() throws {
        for count in [90, 361] {
            for (panic, lossFirst) in [(false, false), (true, false), (true, true)] {
                let h = Harness(count: count, target: .midiNote(channel: 0))
                var doc = try h.document(.singleNote(note: 60, velocity: 90, transition: .toggle))
                doc.detection.cellSelection.confirmationProfiles = 2
                var state = try h.start(doc)
                state = PlayEngine.step(state, .frame(h.frame([40: 100], 1))).0
                state = PlayEngine.step(state, .frame(h.frame([40: 100], 1.01))).0
                XCTAssertEqual(state.soundingNoteCount, 1)
                if lossFirst { state = PlayEngine.step(state, .inputLost).0 }
                if panic {
                    let result = PlayEngine.step(state, .panic)
                    XCTAssertEqual(offs(result.1), [60]); state = result.0
                }
                if !lossFirst { state = PlayEngine.step(state, .inputLost).0 }
                for time in [2.0, 2.01, 2.02] {
                    let result = PlayEngine.step(state, .frame(h.frame([41: 101], time)))
                    XCTAssertTrue(result.1.isEmpty)
                    XCTAssertEqual(result.0.soundingNoteCount, panic ? 0 : 1); state = result.0
                }
                state = PlayEngine.step(state, .frame(h.frame([:], 2.03))).0
                state = PlayEngine.step(state, .frame(h.frame([42: 102], 2.04))).0
                let reentry = PlayEngine.step(state, .frame(h.frame([42: 102], 2.05)))
                XCTAssertEqual(panic ? ons(reentry.1) : offs(reentry.1), [60])
                XCTAssertEqual(reentry.0.soundingNoteCount, panic ? 1 : 0)
            }
        }
    }

    func testSingleNoteCompleteReleaseMatrixForMIDIAndAU90And361() throws {
        for count in [90, 361] {
            for target: SpatialRoutingTarget in [.midiNote(channel: 0), .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)] {
                for transition: SpatialNoteTransition in [.legato, .retrigger, .overlap(milliseconds: 35), .holdUntilNext, .toggle] {
                    let h = Harness(count: count, target: target)
                    let doc = try h.document(.singleNote(note: 60, velocity: 90, transition: transition))
                    let on = PlayEngine.step(try h.start(doc), .frame(h.frame([40: 100], 1)))
                    XCTAssertEqual(ons(on.1), [60])
                    let latched = transition == .toggle || transition == .holdUntilNext
                    let matrix: [(String, PlayInput, Bool)] = [
                        ("exit", .frame(h.frame([:], 1.01)), latched),
                        ("stale", .timeAdvanced(20), latched), ("inputLost", .inputLost, latched),
                        ("error end", .sessionEnded(h.session, reason: .failure), latched),
                        ("PANIC", .panic, false), ("stop", .stop, false), ("sleep", .sleep, false),
                        ("wake", .wake, false), ("terminate", .terminate, false),
                        ("user disconnect", .sessionEnded(h.session, reason: .userRequested), false),
                        ("input change", .sessionBegan(UUID()), false)
                    ]
                    for (name, input, persists) in matrix {
                        let result = PlayEngine.step(on.0, input)
                        XCTAssertEqual(offs(result.1), persists ? [] : [60], "\(name), \(transition), \(target), \(count)")
                        XCTAssertEqual(result.0.soundingNoteCount, persists ? 1 : 0)
                    }
                    var replacement = doc; replacement.revision = .newSession()
                    XCTAssertEqual(offs(PlayEngine.step(on.0, .install(try InstrumentCompiler.compile(replacement))).1), [60])
                    replacement = doc; replacement.revision = try doc.revision.advanced()
                    if case .midiNote = target { replacement.midiTarget = .init(uniqueID: 123) }
                    else { replacement.channel.instrument = .init(identity: .init(componentType: 1, componentSubType: 2, componentManufacturer: 3)) }
                    XCTAssertEqual(offs(PlayEngine.step(on.0, .install(try InstrumentCompiler.compile(replacement))).1), [60])
                }
            }
        }
    }

    func testPanicSurfaceLockSurvivesCosmeticInstallUntilMeasuredExit() throws {
        for count in [90, 361] {
            let h = Harness(count: count, target: .midiNote(channel: 0))
            var doc = try h.document(.singleNote(note: 60, velocity: 90, transition: .toggle))
            var state = PlayEngine.step(try h.start(doc), .frame(h.frame([40: 100], 1))).0
            state = PlayEngine.step(state, .panic).0
            doc.channel.name = "Renamed channel"
            doc.revision = try doc.revision.advanced()
            state = PlayEngine.step(state, .install(try InstrumentCompiler.compile(doc))).0
            let moved = PlayEngine.step(state, .frame(h.frame([41: 101], 1.01)))
            XCTAssertTrue(moved.1.isEmpty); XCTAssertEqual(moved.0.soundingNoteCount, 0)
            state = PlayEngine.step(moved.0, .frame(h.frame([:], 1.02))).0
            let entered = PlayEngine.step(state, .frame(h.frame([41: 101], 1.03)))
            XCTAssertEqual(ons(entered.1), [60]); XCTAssertEqual(entered.0.soundingNoteCount, 1)
        }
    }

    func testEqualOverrideAndDefaultShareOnePaintedSurface() throws {
        let h = Harness(count: 361, target: .midiNote(channel: 0))
        var doc = try h.document(.singleNote(note: 60, velocity: 90, transition: .toggle))
        let old = doc.spatial.layers[0]
        let ownCells = old.cells.filter { $0.sector >= h.startTick + 8 }
        let layer = SpatialDocumentLayer(id: old.id, name: old.name, color: old.color,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: old.cells,
            routings: old.routings, cellOverrides: Dictionary(uniqueKeysWithValues: ownCells.map {
                ($0, [.init(target: h.target, value: .note(number: 60, velocity: 90))])
            }))
        doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        var state = PlayEngine.step(try h.start(doc), .frame(h.frame([40: 100], 1))).0
        let moved = PlayEngine.step(state, .frame(h.frame([48: 101], 1.01)))
        XCTAssertTrue(moved.1.isEmpty); state = moved.0
        state = PlayEngine.step(state, .frame(h.frame([:], 1.02))).0
        let off = PlayEngine.step(state, .frame(h.frame([40: 101], 1.5)))
        XCTAssertEqual(offs(off.1), [60]); XCTAssertEqual(off.0.soundingNoteCount, 0)
    }

    func testSingleNotePersistenceDraftAndScaleToggleMigration() throws {
        let h = Harness(count: 361, target: .midiNote(channel: 0))
        for transition: SpatialNoteTransition in [.legato, .retrigger, .holdUntilNext, .toggle] {
            let program = SpatialValueProgram.singleNote(note: 73, velocity: 81, transition: transition)
            let doc = try h.document(program)
            XCTAssertEqual(try SpatialDocument.decode(JSONEncoder().encode(doc.spatial)), doc.spatial)
            let draft = SpatialAssignmentDraft.from(program: program, target: h.target)
            XCTAssertEqual(draft.kind, .singleNote); XCTAssertEqual(draft.velocity, 81)
            XCTAssertEqual(SpatialAssignmentDraft.program(from: draft), program)
        }
        for program: SpatialValueProgram in [
            .scale(rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84, scale: .major, directionDegrees: 90, ascending: true, transition: .toggle),
            .randomScale(rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84, scale: .major, seed: 123, transition: .toggle)
        ] {
            let doc = try h.document(program)
            let decoded = try SpatialDocument.decode(JSONEncoder().encode(doc.spatial))
            XCTAssertTrue(decoded.didMigrateScaleToggle)
            XCTAssertEqual(decoded.layers[0].routings[0].program, program.replacingUnsupportedToggle)
            XCTAssertEqual(decoded.layers[0].cells, doc.spatial.layers[0].cells)
            XCTAssertEqual(decoded.layers[0].routings[0].id, h.route)
            XCTAssertFalse(SpatialAssignmentDraft.program(from: .from(program: program, target: h.target)).supportsToggle)
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.spatialDocumentBudget] = SpatialDocumentBudget(inputBytes: 100_000,
            layers: 1, addressesPerLayer: 400, addressesPerDocument: 400,
            actionAssignments: 0, noteEntries: 0, routings: 1)
        let single = try h.document(.singleNote(note: 60, velocity: 90, transition: .legato))
        XCTAssertThrowsError(try decoder.decode(SpatialDocument.self, from: JSONEncoder().encode(single.spatial))) {
            XCTAssertEqual($0 as? SpatialDocumentError, .budgetExceeded(.noteEntries))
        }
    }

    func testAdjacentOwnContentsRemainIndependentAndNonAnchorEditReleasesAffectedSurface() throws {
        for count in [90, 361] {
            let h = Harness(count: count, target: .midiNote(channel: 0))
            var doc = try h.document(.singleNote(note: 60, velocity: 90, transition: .toggle))
            let old = doc.spatial.layers[0]
            let overrideCells = old.cells.filter { $0.sector >= h.startTick + 8 }
            let actions: [SpatialCellAction] = [.init(target: h.target, value: .note(number: 72, velocity: 90))]
            func layer(_ cells: Set<PolarDeviceLattice>) -> SpatialDocumentLayer {
                .init(id: old.id, name: old.name, color: old.color, isVisible: true, isActive: true,
                      isLocked: false, isSoloed: false, cells: cells, routings: old.routings,
                      cellOverrides: Dictionary(uniqueKeysWithValues: overrideCells.map { ($0, actions) }))
            }
            doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer(old.cells)], selectedLayerID: old.id)
            let on = PlayEngine.step(try h.start(doc), .frame(h.frame([40: 100, count == 90 ? 42 : 48: 100], 1)))
            XCTAssertEqual(ons(on.1), [60, 72]); XCTAssertEqual(on.0.soundingNoteCount, 2)
            // The edited centimetre is not the canonical anchor or active hit.
            var cells = old.cells; cells.remove(PolarDeviceLattice(ring: 110, sector: h.startTick + 2)!)
            doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer(cells)], selectedLayerID: old.id)
            doc.revision = try doc.revision.advanced()
            let edited = PlayEngine.step(on.0, .install(try InstrumentCompiler.compile(doc)))
            XCTAssertEqual(offs(edited.1), [60]); XCTAssertEqual(edited.0.soundingNoteCount, 1)
            let left = PlayEngine.step(edited.0, .frame(h.frame([:], 1.01)))
            let off = PlayEngine.step(left.0, .frame(h.frame([count == 90 ? 42 : 48: 101], 1.5)))
            XCTAssertEqual(offs(off.1), [72]); XCTAssertEqual(off.0.soundingNoteCount, 0)
        }
    }
}
