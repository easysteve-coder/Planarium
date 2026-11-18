import XCTest
@testable import PlanariumDomain

final class ChordEffectTests: XCTestCase {
    func testModesRangeTieInversionAndLimits() {
        var c = ChordEffect()
        XCTAssertEqual(c.notes(for: 61), [60, 64, 67])
        XCTAssertEqual(c.notes(for: 62), [62, 65, 69])
        c.toneCount = 4; c.inversion = 1
        XCTAssertEqual(c.notes(for: 60), [64, 67, 71, 72])
        c.low = 60; c.high = 72
        XCTAssertEqual(c.notes(for: 59), [59])
        c.mode = .single
        XCTAssertEqual(c.notes(for: 62), [62, 66, 69])
        c.mode = .multi; c.multiNotes = [60: [48, 55]]
        XCTAssertEqual(c.notes(for: 60), [48, 55]); XCTAssertEqual(c.notes(for: 62), [62])
        c.low = 0; c.high = 127; c.mode = .single; c.singleNotes = [60, 127]
        XCTAssertEqual(c.notes(for: 127), [127])
    }
    func testOverlappingChordsKeepHighestVelocityOncePerPitch() {
        var chord = ChordEffect(); chord.mode = .multi
        chord.multiNotes = [60: [60, 64, 67], 62: [62, 64, 67]]
        let chain = CompiledMIDIEffectChain([.init(chord: chord)])
        XCTAssertEqual(chain.apply(.notes([.init(number: 60, velocity: 40), .init(number: 62, velocity: 100)], transition: .legato)),
            .notes([.init(number: 60, velocity: 40), .init(number: 62, velocity: 100), .init(number: 64, velocity: 100), .init(number: 67, velocity: 100)], transition: .legato))
    }
    func testArpeggiatorSplitsChainAndBypassIsIdentical() throws {
        var chord = ChordEffect(); chord.mode = .single
        var arp = InstrumentMIDIEffect(arpeggiator: .init())
        let value = SpatialEvaluatedValue.notes([.init(number: 60, velocity: 90)], transition: .legato)
        XCTAssertEqual(CompiledMIDIEffectChain([.init(chord: chord), arp, .init(chord: chord)]).apply(value),
                       CompiledMIDIEffectChain([.init(chord: chord)]).apply(value))
        arp.bypassed = true
        XCTAssertEqual(CompiledMIDIEffectChain([arp]).apply(value), value)
        var harness = try Harness(90, mode: .single, transition: .legato)
        harness.document.channel.midiEffects = [.init(arpeggiator: .init()), .init(arpeggiator: .init())]
        XCTAssertThrowsError(try InstrumentCompiler.compile(harness.document))
        let data = try JSONEncoder().encode(InstrumentMIDIEffect())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "arpeggiator")
        let decoded = try JSONDecoder().decode(InstrumentMIDIEffect.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.kind, .chord); XCTAssertEqual(decoded.arpeggiator, .init())
    }
    private struct Harness {
        let id = UUID(), session = UUID()
        let geometry: ProfileGeometryIdentity
        var document: InstrumentDocument
        init(_ count: Int, mode: ChordEffect.Mode, transition: SpatialNoteTransition, bypass: Bool = false, changed: Bool = false) throws {
            geometry = .init(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            let sector = geometry.tickSpan(at: 45)!.lower
            let cells = [100, 120].map { PolarDeviceLattice(ring: $0, sector: sector)! }
            let layer = SpatialDocumentLayer(id: id, name: "Chord", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: Set(cells), routings: [
                    .init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), program: .singleNote(note: 60, velocity: 91, transition: transition)),
                    .init(target: .midiNote(channel: 2), program: .singleNote(note: 60, velocity: 91, transition: transition))], cellOverrides: changed ? [cells[1]: [.init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), value: .note(number: 62, velocity: 91))]] : [:])
            document = .init(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id), detection: .allStagesOff, revision: .newSession())
            var chord = ChordEffect(); chord.mode = mode; chord.multiNotes = [60: [60, 64, 67], 62: [62, 65, 69]]
            document.channel.midiEffects = [.init(bypassed: bypass, chord: chord)]
        }
        func frame(_ sequence: Int, ring: Int? = 100) -> PlayInput {
            .frame(.init(sessionID: session, sequence: UInt64(sequence), time: Double(sequence),
                measurements: (0..<geometry.pointCount).map { DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: UInt16($0 == 45 ? ring ?? 500 : 500))! }, geometry: geometry))
        }
        func start() throws -> PlayState {
            var state = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(document))).0
            state = PlayEngine.step(state, .sessionBegan(session)).0
            return state
        }
    }
    private func ons(_ events: [MusicEvent], au: Bool = true) -> Set<UInt8> {
        Set(events.compactMap { if case let .noteOn(destination, _, note) = $0, (destination == .audioUnit(stripID: InstrumentChannel.legacyID)) == au { return note.number }; return nil })
    }
    private func offs(_ events: [MusicEvent]) -> Set<UInt8> {
        Set(events.compactMap { if case let .noteOff(.audioUnit, _, note) = $0 { return note.number }; return nil })
    }
    func testEveryModeEntryExitHoldTogglePanicStopAndLossAt90And361() throws {
        for count in [90, 361] { for mode in ChordEffect.Mode.allCases {
            for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
                let h = try Harness(count, mode: mode, transition: transition)
                var state = try h.start()
                let entered = PlayEngine.step(state, h.frame(1)); state = entered.0
                XCTAssertEqual(ons(entered.1), [60, 64, 67]); XCTAssertEqual(ons(entered.1, au: false), [60])
                let exited = PlayEngine.step(state, h.frame(2, ring: nil))
                XCTAssertEqual(offs(exited.1), transition == .legato ? [60, 64, 67] : [])
                let lost = PlayEngine.step(state, .inputLost)
                XCTAssertEqual(offs(lost.1), transition == .legato ? [60, 64, 67] : [])
                XCTAssertEqual(offs(PlayEngine.step(lost.0, .stop).1), transition == .legato ? [] : [60, 64, 67])
                XCTAssertEqual(offs(PlayEngine.step(state, .stop).1), [60, 64, 67])
                let panic = PlayEngine.step(state, .panic)
                XCTAssertEqual(offs(panic.1), [60, 64, 67])
                XCTAssertEqual(ons(PlayEngine.step(panic.0, h.frame(2)).1), [])
                let away = PlayEngine.step(panic.0, h.frame(3, ring: nil)).0
                XCTAssertEqual(ons(PlayEngine.step(away, h.frame(4)).1), [60, 64, 67])
                if transition == .toggle {
                    let again = PlayEngine.step(exited.0, h.frame(3))
                    XCTAssertEqual(offs(again.1), [60, 64, 67]); XCTAssertEqual(again.0.soundingNoteCount, 0)
                }
                if transition == .holdUntilNext {
                    let moved = PlayEngine.step(state, h.frame(2, ring: 120))
                    XCTAssertEqual(moved.0.soundingNoteCount, 4)
                    XCTAssertEqual(offs(PlayEngine.step(moved.0, .stop).1), [60, 64, 67])
                }
            }
        } }
    }
    func testEachModeChangesChordOnMeasuredCellMovement() throws {
        for count in [90, 361] { for mode in ChordEffect.Mode.allCases {
            let h = try Harness(count, mode: mode, transition: .legato, changed: true)
            let entered = PlayEngine.step(try h.start(), h.frame(1))
            let moved = PlayEngine.step(entered.0, h.frame(2, ring: 120))
            XCTAssertEqual(offs(moved.1), [60, 64, 67])
            let expected: Set<UInt8> = mode == .single ? [62, 66, 69] : [62, 65, 69]
            XCTAssertEqual(ons(moved.1), expected)
            XCTAssertEqual(offs(PlayEngine.step(moved.0, .stop).1), expected)
        } }
    }
    func testScenesKeepExistingHoldAndTogglePolicyAndPresetReleasesEveryMode() throws {
        for count in [90, 361] { for mode in ChordEffect.Mode.allCases {
            for transition in [SpatialNoteTransition.holdUntilNext, .toggle] {
                var h = try Harness(count, mode: mode, transition: transition)
                let a = UUID(), b = UUID()
                h.document.scenes = [.init(id: a, name: "Play", activeLayerIDs: [h.id]), .init(id: b, name: "Quiet", activeLayerIDs: [])]
                h.document.currentSceneID = a
                let entered = PlayEngine.step(try h.start(), h.frame(1)).0
                let quiet = PlayEngine.step(entered, .selectScene(b))
                XCTAssertEqual(offs(quiet.1), []); XCTAssertEqual(quiet.0.soundingNoteCount, 4)
                let exited = PlayEngine.step(quiet.0, h.frame(2, ring: nil))
                let toggled = transition == .toggle
                XCTAssertEqual(offs(exited.1), toggled ? [] : [60, 64, 67])
                XCTAssertEqual(exited.0.soundingNoteCount, toggled ? 4 : 0)
                XCTAssertEqual(offs(PlayEngine.step(exited.0, .stop).1), toggled ? [60, 64, 67] : [])
                h.document.revision = .newSession()
                let preset = PlayEngine.step(entered, .install(try InstrumentCompiler.compile(h.document)))
                XCTAssertEqual(offs(preset.1), [60, 64, 67]); XCTAssertEqual(preset.0.soundingNoteCount, 0)
            }
        } }
    }
    func testChainOrderAndMultiPassThroughReachEvaluation() throws {
        let h = try Harness(90, mode: .multi, transition: .legato)
        var doc = h.document
        doc.channel.midiEffects[0].chord.multiNotes = [:]
        let compiled = try InstrumentCompiler.compile(doc)
        let handle = try XCTUnwrap(compiled.hits(tick: h.geometry.tickSpan(at: 45)!.lower, raw: 100).first)
        let values = try compiled.evaluate(active: [h.id: handle])
        XCTAssertTrue(values.contains { $0.target.stripID != nil && $0.value == .notes([.init(number: 60, velocity: 91)], transition: .legato) })
        var single = ChordEffect(); single.mode = .single; single.singleNotes = [61]
        var scale = ChordEffect(); scale.mode = .scale
        let a = CompiledMIDIEffectChain([.init(chord: single), .init(chord: scale)])
        let b = CompiledMIDIEffectChain([.init(chord: scale), .init(chord: single)])
        XCTAssertEqual(a.pitches[60], [60, 64, 67])
        XCTAssertEqual(b.pitches[60], [61, 65, 68])
    }
    func testBypassAndEmptyChainAreIdenticalAndMIDIIsUnchanged() throws {
        for count in [90, 361] {
            let h = try Harness(count, mode: .scale, transition: .legato, bypass: true)
            var empty = h.document; empty.channel.midiEffects = []
            var a = try h.start(), b = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(empty))).0
            b = PlayEngine.step(b, .sessionBegan(h.session)).0
            for input in [h.frame(1), h.frame(2, ring: 120), h.frame(3, ring: nil), .stop] {
                let left = PlayEngine.step(a, input), right = PlayEngine.step(b, input)
                XCTAssertEqual(left.1, right.1); a = left.0; b = right.0
            }
            var active = h.document; active.channel.midiEffects[0].bypassed = false
            a = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(active))).0
            a = PlayEngine.step(a, .sessionBegan(h.session)).0
            b = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(empty))).0
            b = PlayEngine.step(b, .sessionBegan(h.session)).0
            for input in [h.frame(1), h.frame(2, ring: nil), .panic, .stop] {
                let left = PlayEngine.step(a, input), right = PlayEngine.step(b, input)
                func midi(_ e: [MusicEvent]) -> [[UInt8]] { e.compactMap { event in
                    switch event {
                    case let .noteOn(.midi, ch, note): return [0x90 | ch, note.number, note.velocity]
                    case let .noteOff(.midi, ch, note): return [0x80 | ch, note.number, note.velocity]
                    case let .allNotesOff(.midi, ch): return [0xB0 | ch, 123, 0]
                    default: return nil
                    }
                } }
                XCTAssertEqual(midi(left.1), midi(right.1)); a = left.0; b = right.0
            }
        }
    }
    func testChainEditReleasesHeldNotesAndMigrationRoundtripAndValidation() throws {
        var h = try Harness(90, mode: .single, transition: .holdUntilNext)
        let old = try h.start(); let playing = PlayEngine.step(old, h.frame(1)).0
        let bytes = try JSONEncoder().encode(h.document)
        XCTAssertEqual(try JSONDecoder().decode(InstrumentDocument.self, from: bytes), h.document)
        h.document.channel.midiEffects = []; h.document.revision = try h.document.revision.advanced()
        let cleared = PlayEngine.step(playing, .install(try InstrumentCompiler.compile(h.document)))
        XCTAssertEqual(offs(cleared.1), [60, 64, 67])
        let legacyBytes = try JSONEncoder().encode(h.document)
        XCTAssertFalse(String(decoding: legacyBytes, as: UTF8.self).contains("midiEffects"))
        XCTAssertEqual(try JSONDecoder().decode(InstrumentDocument.self, from: legacyBytes).channel.midiEffects, [])
        h.document.channel.midiEffects = (0..<5).map { _ in .init() }
        XCTAssertThrowsError(try InstrumentCompiler.compile(h.document))
    }
    func testSharedPitchOwnersReleaseOnlyAfterLastOwner() {
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        let chain = CompiledMIDIEffectChain([.init()]), a = UUID(), b = UUID()
        func value(_ id: UUID, active: Bool) -> SpatialRoutingEvaluation {
            .init(routingID: id, target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), value: chain.apply(.notes(active ? [.init(number: 60, velocity: 100)] : [], transition: .legato)))
        }
        XCTAssertEqual(ledger.apply([value(a, active: true), value(b, active: true)]).count, 3)
        XCTAssertTrue(ledger.apply([value(a, active: false), value(b, active: true)]).isEmpty)
        XCTAssertEqual(ledger.apply([value(a, active: false), value(b, active: false)]).count, 3)
        XCTAssertEqual(ledger.soundingNoteCount, 0)
    }
}
