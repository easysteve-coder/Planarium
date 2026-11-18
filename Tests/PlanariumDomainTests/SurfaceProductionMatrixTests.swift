import XCTest
@testable import PlanariumDomain

/// Release matrix and value oracle for a layer of several surfaces, through the production path
/// (compile → PlayEngine → music events) with fakes only, at 90 and 361 rays. The layer's existing
/// rules (scene, loss, stop, hold, panic, edit) must hold for every one of its partitions.
final class SurfaceProductionMatrixTests: XCTestCase {
    private let session = UUID(), documentSession = UUID(), layerID = UUID(), otherLayerID = UUID(), controlID = UUID()
    private let aID = UUID(), bID = UUID(), dayID = UUID(), nightID = UUID()

    private func geometry(_ count: Int) -> ProfileGeometryIdentity {
        .init(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
    }
    private func spot(_ count: Int, _ order: Int, ring: Int = 100) -> SurfaceTransform {
        let span = geometry(count).tickSpan(at: order)!
        let p = SurfaceGrid.point(ring: ring, tick: (span.lower + span.upper) / 2)
        return .init(xCm: p.x, yCm: p.y)
    }
    private func note(_ n: Int, _ transition: SpatialNoteTransition) -> SpatialRouting {
        .init(target: .midiNote(channel: 0), program: .singleNote(note: n, velocity: 100, transition: transition))
    }
    private func surface(_ id: UUID, at transform: SurfaceTransform, _ routing: SpatialRouting) throws -> SpatialSurface {
        try SpatialSurface(id: id, presentation: .init(name: "S", color: .orange),
                           form: .shape(.rectangle(widthCm: 12, heightCm: 12), transform), routings: [routing])
    }
    /// One layer, two surfaces (notes 60 and 62), two scenes: day has the layer, night has another layer.
    private func document(_ count: Int, _ transition: SpatialNoteTransition, moved: Bool = false, dropFirst: Bool = false,
                          together: Bool = true, withRelease: Bool = false, sameNote: Bool = false) throws -> InstrumentDocument {
        let a = try surface(aID, at: spot(count, moved ? count / 6 : count / 3), note(60, transition))
        let b = try surface(bID, at: spot(count, count * 2 / 3), note(sameNote ? 60 : 62, transition))
        func layer(_ id: UUID, _ surfaces: [SpatialSurface]) -> SpatialDocumentLayer {
            .init(id: id, name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false,
                  isSoloed: false, cells: [], routings: [], cellOverrides: [:], surfaces: surfaces)
        }
        // Separate layers use the layer IDs `aID`/`bID`, so both forms share partition identities.
        let layers = together ? [layer(layerID, dropFirst ? [b] : [a, b])] : (dropFirst ? [layer(bID, [b])] : [layer(aID, [a]), layer(bID, [b])])
        let other = SpatialDocumentLayer(id: otherLayerID, name: "Other", color: .blue, isVisible: true, isActive: true, isLocked: false,
            isSoloed: false, cells: [PolarDeviceLattice(ring: 100, sector: geometry(count).tickSpan(at: count - 5)!.lower)!],
            routings: [note(70, .retrigger)], cellOverrides: [:])
        // A control layer in the same scenes: its cell releases the whole layer (every partition of it).
        let control = SpatialDocumentLayer(id: controlID, name: "Release", color: .blue, isVisible: true, isActive: true, isLocked: false,
            isSoloed: false, cells: [PolarDeviceLattice(ring: 100, sector: geometry(count).tickSpan(at: count - 8)!.lower)!],
            routings: [.init(target: .releaseLayer(layerID: together ? layerID : aID), program: .constant(1))], cellOverrides: [:])
        let extras = withRelease ? [other, control] : [other]
        return .init(spatial: try .init(latticeVersion: .polarDeviceV2, layers: layers + extras, selectedLayerID: layers[0].id),
                     detection: .allStagesOff, revision: .init(session: documentSession, counter: moved || dropFirst ? 2 : 1),
                     scenes: [.init(id: dayID, name: "Day", activeLayerIDs: Set(layers.map(\.id) + (withRelease ? [controlID] : []))), .init(id: nightID, name: "Night", activeLayerIDs: [otherLayerID])],
                     currentSceneID: dayID)
    }
    private func frame(_ count: Int, _ orders: Set<Int>, _ time: Double) -> ProfileFrame {
        let g = geometry(count)
        return .init(sessionID: session, sequence: UInt64(time * 1000), time: time,
            measurements: (0..<count).map { DeviceTickMeasurement(order: $0, ticks: g.tickSpan(at: $0)!, rawCentimeters: orders.contains($0) ? 100 : 500)! }, geometry: g)
    }
    private func start(_ document: InstrumentDocument) throws -> PlayState {
        PlayEngine.step(PlayEngine.step(.init(), .install(try InstrumentCompiler.compile(document))).0, .sessionBegan(session)).0
    }
    /// Both hands in, both notes sounding.
    private func holding(_ count: Int, _ transition: SpatialNoteTransition, together: Bool = true) throws -> PlayState {
        var state = try start(document(count, transition, together: together))
        _ = step(&state, .frame(frame(count, [count / 3], 10)))
        _ = step(&state, .frame(frame(count, [count / 3, count * 2 / 3], 10.1)))
        if transition == .toggle { _ = step(&state, .frame(frame(count, [], 10.2))) }
        XCTAssertEqual(state.soundingNoteCount, 2, "precondition (\(count), \(transition))")
        return state
    }
    private func step(_ state: inout PlayState, _ input: PlayInput) -> [MusicEvent] {
        let result = PlayEngine.step(state, input); state = result.0; return result.1
    }
    private func ons(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case .noteOn(_, _, let n) = $0 { return n.number }; return nil }.sorted()
    }
    private func offs(_ events: [MusicEvent]) -> [UInt8] {
        events.compactMap { if case .noteOff(_, _, let n) = $0 { return n.number }; return nil }.sorted()
    }

    // MARK: Release matrix

    func testEveryEndOfPlayReleasesBothPartitionsOfTheLayer() throws {
        let inputs: [(String, PlayInput)] = [
            ("panic", .panic), ("stop", .stop), ("sleep", .sleep), ("wake", .wake), ("terminate", .terminate),
            ("inputLost", .inputLost), ("session failed", .sessionEnded(session, reason: .failure)),
            ("session ended", .sessionEnded(session, reason: .userRequested)),
        ]
        for count in [90, 361] {
            for (name, input) in inputs {
                var state = try holding(count, .retrigger)
                let events = step(&state, input)
                XCTAssertEqual(offs(events), [60, 62], "\(name) at \(count)")
                XCTAssertEqual(state.soundingNoteCount, 0, "\(name) at \(count)")
                XCTAssertTrue(ons(events).isEmpty, "no note starts from \(name)")
            }
        }
    }

    /// A scene change keeps a note sounding while the hand that plays it is still in (the layer's
    /// rule), then ends it; this holds for each partition of the layer, exactly as for layers of
    /// their own, and holds that were toggled stay as they are for an inactive layer.
    func testSceneChangeEndsBothPartitionsWhenTheirHandsLeaveAndMatchesSeparateLayers() throws {
        for count in [90, 361] {
            var together = try holding(count, .retrigger), apart = try holding(count, .retrigger, together: false)
            var x = step(&together, .selectScene(nightID)), y = step(&apart, .selectScene(nightID))
            XCTAssertEqual(x.count, 1); XCTAssertEqual(x, y)
            XCTAssertEqual(together.soundingNoteCount, 2, "the hands are still in")
            x = step(&together, .frame(frame(count, [count / 3, count * 2 / 3], 11))); y = step(&apart, .frame(frame(count, [count / 3, count * 2 / 3], 11)))
            XCTAssertTrue(x.isEmpty); XCTAssertEqual(x, y)
            XCTAssertTrue(ons(step(&together, .frame(frame(count, [count / 3, count * 2 / 3], 11.05)))).isEmpty, "inactive surfaces play nothing")
            x = step(&together, .frame(frame(count, [], 11.1))); y = step(&apart, .frame(frame(count, [], 11.1)))
            XCTAssertEqual(offs(x), [60, 62]); XCTAssertEqual(offs(x), offs(y)); XCTAssertEqual(together.soundingNoteCount, 0)
            XCTAssertEqual(ons(step(&together, .frame(frame(count, [count - 5], 11.2)))), [70], "the other scene plays from a measured entry")
        }
    }

    func testToggledHoldsAcrossASceneChangeBehaveLikeSeparateLayers() throws {
        for count in [90, 361] {
            var together = try holding(count, .toggle), apart = try holding(count, .toggle, together: false)
            let script: [PlayInput] = [.selectScene(nightID), .frame(frame(count, [], 11)), .frame(frame(count, [count / 3], 11.1)),
                                       .frame(frame(count, [], 11.2)), .selectScene(dayID), .frame(frame(count, [count / 3], 11.3)), .frame(frame(count, [], 11.4))]
            for input in script { let a = step(&together, input), b = step(&apart, input); XCTAssertEqual(offs(a), offs(b)); XCTAssertEqual(ons(a), ons(b)) }
            XCTAssertEqual(together.soundingNoteCount, apart.soundingNoteCount)
            XCTAssertEqual(offs(step(&together, .panic)), offs(step(&apart, .panic)), "panic ends whatever is still held, the same in both forms")
            XCTAssertEqual(together.soundingNoteCount, 0)
        }
    }

    func testHeldNotesSurviveInputLossButNotPanicStopOrTermination() throws {
        for count in [90, 361] {
            var held = try holding(count, .toggle)
            XCTAssertTrue(offs(step(&held, .inputLost)).isEmpty, "owner exception: an involuntary loss keeps what was deliberately held (\(count))")
            XCTAssertEqual(held.soundingNoteCount, 2)
            for (name, input) in [("panic", PlayInput.panic), ("stop", .stop), ("terminate", .terminate)] {
                var state = held
                XCTAssertEqual(offs(step(&state, input)), [60, 62], "\(name) after a loss releases both held partitions (\(count))")
                XCTAssertEqual(state.soundingNoteCount, 0)
            }
            for (name, input) in [("panic", PlayInput.panic), ("stop", .stop), ("terminate", .terminate)] {
                var state = try holding(count, .toggle)
                XCTAssertEqual(offs(step(&state, input)), [60, 62], "\(name) releases both held partitions directly (\(count))")
            }
        }
    }

    func testPanicLocksEachPartitionUntilItsHandLeaves() throws {
        for count in [90, 361] {
            var state = try start(document(count, .retrigger))
            _ = step(&state, .frame(frame(count, [count / 3, count * 2 / 3], 10)))
            XCTAssertEqual(offs(step(&state, .panic)), [60, 62])
            XCTAssertTrue(ons(step(&state, .frame(frame(count, [count / 3, count * 2 / 3], 10.1)))).isEmpty, "panic is not undone by the hands staying in")
            _ = step(&state, .frame(frame(count, [], 10.2)))
            XCTAssertEqual(ons(step(&state, .frame(frame(count, [count / 3], 10.3)))), [60])
        }
    }

    // MARK: Edit while hands are in

    func testInstallingAnEditedDocumentNeverStartsANoteAndEndsOnlyWhatIsNoLongerCarried() throws {
        for count in [90, 361] {
            for (name, edited) in [("moved", try document(count, .retrigger, moved: true)), ("deleted", try document(count, .retrigger, dropFirst: true))] {
                var state = try holding(count, .retrigger)
                let events = step(&state, .install(try InstrumentCompiler.compile(edited)))
                XCTAssertTrue(ons(events).isEmpty, "an edit starts no note (\(name), \(count))")
                XCTAssertFalse(offs(events).contains(62), "the untouched surface keeps sounding (\(name), \(count))")
                // The frame after the edit decides: surface A no longer carries the hand, B still does.
                let after = step(&state, .frame(frame(count, [count / 3, count * 2 / 3], 10.3)))
                XCTAssertTrue(ons(after).isEmpty, "(\(name), \(count))")
                XCTAssertEqual(state.soundingNoteCount, 1, "only B's note remains (\(name), \(count))")
            }
        }
    }

    func testAnEditWithToggledHoldsReleasesLikeTheSameEditOnSeparateLayersAndStartsNoNote() throws {
        for count in [90, 361] {
            for (name, together, apart) in [("moved", try document(count, .toggle, moved: true), try document(count, .toggle, moved: true, together: false)),
                                            ("deleted", try document(count, .toggle, dropFirst: true), try document(count, .toggle, dropFirst: true, together: false))] {
                var one = try holding(count, .toggle), two = try holding(count, .toggle, together: false)
                let x = step(&one, .install(try InstrumentCompiler.compile(together))), y = step(&two, .install(try InstrumentCompiler.compile(apart)))
                XCTAssertEqual(offs(x), offs(y), "\(name) at \(count)")
                XCTAssertTrue(ons(x).isEmpty, "an edit starts no note (\(name), \(count))")
                XCTAssertTrue(offs(x).contains(60), "the held note of the changed surface ends (\(name), \(count))")
                XCTAssertEqual(one.soundingNoteCount, two.soundingNoteCount)
            }
        }
    }

    func testUndoBackIntoTheOldDocumentStartsNoNoteEitherUntilTheHandEntersAgain() throws {
        for count in [90, 361] {
            var state = try start(document(count, .retrigger, moved: true))
            _ = step(&state, .frame(frame(count, [count / 3, count * 2 / 3], 10)))
            XCTAssertEqual(state.soundingNoteCount, 1)
            let events = step(&state, .install(try InstrumentCompiler.compile(document(count, .retrigger))))
            XCTAssertTrue(ons(events).isEmpty)
        }
    }

    // MARK: layerRelease reaches every partition, also after Edit, Undo, Delete

    func testReleaseLayerEndsEveryPartitionAfterEditDeleteAndUndo() throws {
        for count in [90, 361] {
            let original = try document(count, .toggle, withRelease: true)
            let moved = try document(count, .toggle, moved: true, withRelease: true)
            let deleted = try document(count, .toggle, dropFirst: true, withRelease: true)
            let cases: [(String, [InstrumentDocument], Set<Int>, [UInt8])] = [
                ("original", [original], [count / 3, count * 2 / 3], [60, 62]),
                ("moved", [original, moved], [count / 6, count * 2 / 3], [60, 62]),
                ("deleted", [original, deleted], [count * 2 / 3], [62]),
                ("undone", [original, moved, original], [count / 3, count * 2 / 3], [60, 62]),
            ]
            for (name, installs, hands, expected) in cases {
                var state = try start(installs[0])
                var t = 10.0
                for later in installs.dropFirst() {
                    let events = step(&state, .install(try InstrumentCompiler.compile(later)))
                    XCTAssertTrue(ons(events).isEmpty, "no note from the edit itself (\(name), \(count))")
                }
                for order in hands.sorted() {
                    t += 0.2; _ = step(&state, .frame(frame(count, [order], t)))
                    t += 0.2; _ = step(&state, .frame(frame(count, [], t)))
                }
                XCTAssertEqual(state.soundingNoteCount, expected.count, "toggled holds established (\(name), \(count))")
                t += 0.5
                XCTAssertEqual(offs(step(&state, .frame(frame(count, [count - 8], t)))), expected, "the control cell releases every partition (\(name), \(count))")
                XCTAssertEqual(state.soundingNoteCount, 0)
                var panicked = state
                _ = step(&panicked, .frame(frame(count, [], t + 0.1)))
                XCTAssertTrue(offs(step(&panicked, .panic)).isEmpty, "nothing left for panic after the release (\(name), \(count))")
            }
        }
    }

    func testPartitionsSharingANoteBehaveLikeLayersSharingIt() throws {
        for count in [90, 361] {
            for transition in [SpatialNoteTransition.retrigger, .toggle] {
                var together = try start(document(count, transition, sameNote: true)), apart = try start(document(count, transition, together: false, sameNote: true))
                let a = count / 3, b = count * 2 / 3
                let script: [(Set<Int>, Double)] = [([a], 10), ([a, b], 10.1), ([b], 10.2), ([], 10.3), ([a], 10.4), ([], 10.5)]
                var total = 0
                for (orders, time) in script {
                    let x = step(&together, .frame(frame(count, orders, time))), y = step(&apart, .frame(frame(count, orders, time)))
                    XCTAssertEqual(ons(x), ons(y), "ons t=\(time) \(transition) \(count)"); XCTAssertEqual(offs(x), offs(y), "offs t=\(time) \(transition) \(count)")
                    XCTAssertEqual(together.soundingNoteCount, apart.soundingNoteCount)
                    total += x.count
                }
                XCTAssertGreaterThan(total, 0)
                XCTAssertEqual(offs(step(&together, .panic)), offs(step(&apart, .panic)))
            }
        }
    }

    // MARK: Layer of surfaces plays like the same surfaces in layers of their own

    func testSurfacesOfOneLayerPlayLikeTheSameSurfacesInSeparateLayers() throws {
        for count in [90, 361] {
            let cc = SpatialRouting(target: .midiCC(channel: 0, controller: 74),
                                    program: .continuous(minimum: 0.1, maximum: 0.9, directionDegrees: 0, curve: .easeIn))
            let scale = SpatialRouting(target: .midiNote(channel: 0), program: .scale(rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 72,
                scale: .major, directionDegrees: 90, ascending: false, transition: .retrigger))
            let a = try SpatialSurface(id: aID, presentation: .init(name: "A", color: .orange),
                form: .shape(.rectangle(widthCm: 30, heightCm: 30), spot(count, count / 3)), routings: [cc])
            let b = try SpatialSurface(id: bID, presentation: .init(name: "B", color: .green),
                form: .shape(.rectangle(widthCm: 14, heightCm: 40), spot(count, count * 2 / 3)), routings: [scale])
            func doc(_ layers: [SpatialDocumentLayer]) throws -> InstrumentDocument {
                .init(spatial: try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id), detection: .allStagesOff,
                      revision: .init(session: UUID(), counter: 1))
            }
            func layer(_ id: UUID, _ surfaces: [SpatialSurface]) -> SpatialDocumentLayer {
                .init(id: id, name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                      cells: [], routings: [], cellOverrides: [:], surfaces: surfaces)
            }
            var together = try start(doc([layer(layerID, [a, b])])), apart = try start(doc([layer(UUID(), [a]), layer(UUID(), [b])]))
            let script: [(Set<Int>, Double)] = [([count / 3], 10), ([count / 3, count * 2 / 3], 10.1), ([count * 2 / 3], 10.2), ([], 10.3)]
            var total = 0
            for (orders, time) in script {
                let x = step(&together, .frame(frame(count, orders, time))), y = step(&apart, .frame(frame(count, orders, time)))
                XCTAssertEqual(x.map { "\($0)" }.sorted(), y.map { "\($0)" }.sorted(), "t=\(time) at \(count)"); total += x.count
            }
            XCTAssertGreaterThanOrEqual(total, 4, "the comparison saw real output (\(count))")
        }
    }

    // MARK: The value field against the real compiler and an independent closed form

    private func independentFraction(_ s: SpatialSurface, worldDegrees d: Double, _ c: PolarDeviceLattice) -> Double {
        let dx = cos(d * .pi / 180), dy = sin(d * .pi / 180)
        func p(_ c: PolarDeviceLattice) -> Double { let q = SurfaceGrid.point(ring: c.ring, tick: c.sector); return q.x * dx + q.y * dy }
        let all = s.cells.map(p)
        return (p(c) - all.min()!) / (all.max()! - all.min()!)
    }

    func testEachSurfaceNormalisesItsOwnCCAndScaleAndThePreviewMatchesTheCompiler() throws {
        for (rotation, mirror) in [(0.0, false), (50.0, false), (-110.0, true)] {
            for (low, high, curve) in [(0.0, 1.0, SpatialValueCurve.linear), (1.0, 0.0, .easeIn), (0.25, 0.8, .easeOut), (0.9, 0.2, .easeOut)] {
                for ascending in [true, false] {
                    let localCC = 20.0, localScale = -70.0
                    let ccRouting = SpatialRouting(target: .midiCC(channel: 0, controller: 74),
                        program: .continuous(minimum: low, maximum: high, directionDegrees: localCC, curve: curve))
                    let scaleRouting = SpatialRouting(target: .midiNote(channel: 0), program: .scale(rootMIDINote: 62, lowestMIDINote: 50,
                        highestMIDINote: 80, scale: .naturalMinor, directionDegrees: localScale, ascending: ascending, transition: .retrigger))
                    let small = try SpatialSurface(id: aID, presentation: .init(name: "small", color: .orange),
                        form: .shape(.rectangle(widthCm: 14, heightCm: 10), .init(xCm: -40, yCm: 90, rotationDegrees: rotation, mirrorX: mirror)), routings: [ccRouting])
                    let big = try SpatialSurface(id: bID, presentation: .init(name: "big", color: .green),
                        form: .shape(.rectangle(widthCm: 50, heightCm: 24), .init(xCm: 40, yCm: 110, rotationDegrees: rotation, mirrorX: mirror)), routings: [scaleRouting])
                    let layer = SpatialDocumentLayer(id: layerID, name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false,
                        isSoloed: false, cells: [], routings: [], cellOverrides: [:], surfaces: [small, big])
                    let doc = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layerID),
                        detection: .allStagesOff, revision: .init(session: UUID(), counter: 1))
                    let instrument = try InstrumentCompiler.compile(doc)
                    let label = "rot \(rotation) mirror \(mirror) \(low)→\(high) \(curve) ascending \(ascending)"

                    // World directions, derived here from first principles (mirror, then rotate).
                    func world(_ local: Double) -> Double {
                        let lx = cos(local * .pi / 180) * (mirror ? -1 : 1), ly = sin(local * .pi / 180)
                        let r = rotation * .pi / 180
                        return atan2(sin(r) * lx + cos(r) * ly, cos(r) * lx - sin(r) * ly) * 180 / .pi
                    }
                    let ccField = try SurfaceValueField(surface: small, routingID: ccRouting.id)
                    let scaleField = try SurfaceValueField(surface: big, routingID: scaleRouting.id)
                    var seenHigh = false
                    for c in small.cells {
                        let f = independentFraction(small, worldDegrees: world(localCC), c)
                        let shaped: Double
                        switch curve { case .linear: shaped = f; case .easeIn: shaped = f * f; case .easeOut: shaped = 1 - (1 - f) * (1 - f) }
                        let expected = low + (high - low) * shaped
                        let evaluations = try instrument.evaluate(active: [aID: CompiledActiveCell(layerID: aID, cell: c, revision: instrument.revision)])
                        let compiled = evaluations.first { $0.routingID == ccRouting.id }!.value
                        guard case .scalar(let value) = compiled, case .scalar(let previewed) = ccField.sample(c).value else { return XCTFail("not scalar") }
                        XCTAssertEqual(value, expected, accuracy: 1e-6, "compiler vs closed form \(label)")
                        XCTAssertEqual(previewed, value, accuracy: 1e-12, "preview vs compiler \(label)")
                        if f > 1 - 1e-9 { seenHigh = true; XCTAssertEqual(value, high, accuracy: 1e-9, "the small surface reaches its own end value \(label)") }
                    }
                    XCTAssertTrue(seenHigh, label)
                    // The scale: independent allowed notes and index.
                    let minor = Set([0, 2, 3, 5, 7, 8, 10].map { (($0 + 62) % 12 + 12) % 12 })
                    let allowed = (50...80).filter { minor.contains($0 % 12) }
                    var lowestSeen = Int.max, highestSeen = Int.min
                    for c in big.cells {
                        let f = independentFraction(big, worldDegrees: world(localScale), c)
                        let adjusted = ascending ? f : 1 - f
                        let expected = allowed[min(Int((adjusted * Double(allowed.count)).rounded(.down)), allowed.count - 1)]
                        let evaluations = try instrument.evaluate(active: [bID: CompiledActiveCell(layerID: bID, cell: c, revision: instrument.revision)])
                        guard case .notes(let notes, _) = evaluations.first(where: { $0.routingID == scaleRouting.id })!.value,
                              case .notes(let previewed, _) = scaleField.sample(c).value else { return XCTFail("not notes") }
                        XCTAssertEqual(notes.map { Int($0.number) }, [expected], "compiler vs closed form \(label)")
                        XCTAssertEqual(previewed, notes, "preview vs compiler \(label)")
                        lowestSeen = min(lowestSeen, expected); highestSeen = max(highestSeen, expected)
                    }
                    XCTAssertEqual(lowestSeen, allowed.first, "the big surface spans the whole scale on its own extent \(label)")
                    XCTAssertEqual(highestSeen, allowed.last, label)
                }
            }
        }
    }

    func testTwoCCTargetsOfOneLayerEachFollowTheirOwnSurfaceAndAnIdenticalTargetBehavesAsBetweenLayers() throws {
        for count in [90, 361] {
            func cc(_ n: UInt8) -> SpatialRouting {
                .init(target: .midiCC(channel: 0, controller: n), program: .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear))
            }
            func playedValues(_ routingA: SpatialRouting, _ routingB: SpatialRouting, separateLayers: Bool) throws -> [String] {
                let a = try surface(aID, at: spot(count, count / 3), routingA), b = try surface(bID, at: spot(count, count * 2 / 3), routingB)
                func layer(_ id: UUID, _ s: [SpatialSurface]) -> SpatialDocumentLayer {
                    .init(id: id, name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                          cells: [], routings: [], cellOverrides: [:], surfaces: s)
                }
                let layers = separateLayers ? [layer(UUID(), [a]), layer(UUID(), [b])] : [layer(layerID, [a, b])]
                var state = try start(.init(spatial: try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id),
                                            detection: .allStagesOff, revision: .init(session: UUID(), counter: 1)))
                var values: [String] = []
                for (orders, time) in [(Set([count / 3, count * 2 / 3]), 10.0), (Set([count / 3]), 10.1), (Set([count * 2 / 3]), 10.2)] {
                    for case .scalar(_, let target, let value) in step(&state, .frame(frame(count, orders, time))) { values.append("\(target) \(value)") }
                }
                return values
            }
            let distinctTargets = try playedValues(cc(74), cc(1), separateLayers: false)
            XCTAssertEqual(distinctTargets, try playedValues(cc(74), cc(1), separateLayers: true), "two targets, \(count)")
            XCTAssertFalse(distinctTargets.isEmpty)
            XCTAssertEqual(try playedValues(cc(74), cc(74), separateLayers: false), try playedValues(cc(74), cc(74), separateLayers: true),
                           "an identical target resolves exactly as it does between layers (\(count))")
        }
    }
}
