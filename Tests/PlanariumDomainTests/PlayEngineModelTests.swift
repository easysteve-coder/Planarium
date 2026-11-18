import XCTest
import SickPLSControlCore
@testable import PlanariumDomain

final class PlayEngineModelTests: XCTestCase {
    private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    private let documentSession = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
    private let layerID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!

    private struct Sound: Hashable {
        let destination: SpatialOutputDestination
        let channel: UInt8
        let number: UInt8
    }
    private struct Generator {
        var value: UInt64 = 0x504C_414E_4152_4955
        mutating func index(_ count: Int) -> Int {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return Int((value >> 32) % UInt64(count))
        }
    }
    private func compiled(_ revision: UInt64 = 1, notes: Bool = true,
                          transition: SpatialNoteTransition = .legato,
                          detection: DetectionConfiguration = .allStagesOff,
                          channel: InstrumentChannel = .init()) throws -> CompiledInstrument {
        let cells = try Set([100, 120].map { try XCTUnwrap(PolarDeviceLattice(ring: $0, sector: 180)) })
        let routes: [SpatialRouting] = notes ? [SpatialOutputDestination.midi, .audioUnit(stripID: InstrumentChannel.legacyID)].enumerated().map { index, destination in
            SpatialRouting(id: UUID(uuidString: "00000000-0000-0000-0000-00000000003\(index)")!,
                           target: destination == .midi ? .midiNote(channel: 2) : .audioUnitNote(channel: 3, stripID: InstrumentChannel.legacyID),
                           program: .scale(rootMIDINote: 60, lowestMIDINote: 60, highestMIDINote: 72,
                                           scale: .chromatic, directionDegrees: 90, ascending: true, transition: transition))
        } : []
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [
            SpatialDocumentLayer(id: layerID, name: "Model", color: .orange, isVisible: true,
                                 isActive: true, isLocked: false, isSoloed: false,
                                 cells: cells, routings: routes, cellOverrides: [:])
        ], selectedLayerID: layerID)
        return try InstrumentCompiler.compile(.init(spatial: spatial, detection: detection, channel: channel,
                                                    revision: .init(session: documentSession, counter: revision)))
    }
    private func frame(_ sequence: UInt64, ring: UInt16 = 100, empty: Bool = false) throws -> ProfileFrame {
        let measurements = empty ? [] : [try XCTUnwrap(DeviceTickMeasurement(
            order: 180, ticks: try XCTUnwrap(.point(180)), rawCentimeters: ring))]
        return .init(sessionID: session, sequence: sequence, time: Double(sequence), measurements: measurements)
    }
    private func observe(_ events: [MusicEvent], sound: inout Set<Sound>, file: StaticString = #filePath, line: UInt = #line) {
        for event in events {
            switch event {
            case let .noteOn(destination, channel, note):
                let key = Sound(destination: destination, channel: channel, number: note.number)
                XCTAssertTrue(sound.insert(key).inserted, "Duplicate On", file: file, line: line)
            case let .noteOff(destination, channel, note):
                let key = Sound(destination: destination, channel: channel, number: note.number)
                XCTAssertNotNil(sound.remove(key), "Off without owned On", file: file, line: line)
            case let .allNotesOff(destination, channel):
                sound = sound.filter { $0.destination != destination || $0.channel != channel }
            case .scalar, .boolean, .sceneChanged, .programChange, .midiValue: break
            }
        }
    }

    private struct SceneHarness {
        let a = UUID(), b = UUID(), control = UUID()
        let one = UUID(), two = UUID(), three = UUID()
        let document: InstrumentDocument
        let instrument: CompiledInstrument

        init(sharedA: Bool = false) throws {
            func cell(_ ring: Int, _ sector: Int = 180) throws -> PolarDeviceLattice {
                try XCTUnwrap(PolarDeviceLattice(ring: ring, sector: sector))
            }
            let note = SpatialValueProgram.chord(notes: [60], velocity: 100, transition: .legato)
            let layers = [
                SpatialDocumentLayer(id: a, name: "A", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                                     cells: [try cell(100), try cell(110)], routings: [.init(target: .midiNote(channel: 0), program: note)], cellOverrides: [:]),
                SpatialDocumentLayer(id: b, name: "B", color: .blue, isVisible: true, isActive: false, isLocked: false, isSoloed: false,
                                     cells: [try cell(120)], routings: [.init(target: .midiNote(channel: 0), program: note)], cellOverrides: [:]),
                SpatialDocumentLayer(id: control, name: "Control", color: .green, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                                     cells: [try cell(140, 181)], routings: [.init(target: .sceneSwitch(action: .next, dwellSeconds: 0.2), program: .constant(1))], cellOverrides: [:])
            ]
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: a)
            let scenes = [
                SpatialScene(id: one, name: "One", activeLayerIDs: [a]),
                SpatialScene(id: two, name: "Two", activeLayerIDs: sharedA ? [a, b] : [b]),
                SpatialScene(id: three, name: "Three", activeLayerIDs: [a])
            ]
            document = .init(spatial: spatial, detection: .allStagesOff,
                revision: .init(session: PlayEngineModelTests().documentSession, counter: 80), scenes: scenes, currentSceneID: one)
            instrument = try InstrumentCompiler.compile(document)
        }

        func frame(_ sequence: UInt64, _ time: Double, rings: [Int]) throws -> ProfileFrame {
            let samples = try rings.enumerated().map { index, ring in
                try XCTUnwrap(DeviceTickMeasurement(order: 45 + index, ticks: try XCTUnwrap(.point(ring == 140 ? 181 : 180)), rawCentimeters: UInt16(ring)))
            }
            return .init(sessionID: PlayEngineModelTests().session, sequence: sequence, time: time, measurements: samples,
                         geometry: .init(operatingMode: "MMK", pointCount: 90, startAngleDegrees: -90, endAngleDegrees: 90))
        }
    }

    private func mutedSceneState(_ harness: SceneHarness) throws -> PlayState {
        var state = PlayEngine.step(PlayState(), .install(harness.instrument)).0
        state = PlayEngine.step(state, .sessionBegan(session)).0
        state = PlayEngine.step(state, .frame(try harness.frame(1, 0, rings: [100, 140]))).0
        state = PlayEngine.step(state, .frame(try harness.frame(2, 0.2, rings: [100, 140]))).0
        return state
    }

    func testSceneMixerInstallKeepsSustainedNoteAndActivationBlock() throws {
        let changes: [(String, (inout InstrumentChannel) -> Void)] = [
            ("fader", { $0.levelDecibels = -6 }), ("pan", { $0.pan = 0.5 }),
            ("mute", { $0.muted = true }), ("solo", { $0.soloed = true })
        ]
        for (name, change) in changes {
            let h = try SceneHarness()
            var state = PlayEngine.step(PlayState(), .install(h.instrument)).0
            state = PlayEngine.step(state, .frame(try h.frame(1, 0, rings: [100, 120]))).0
            XCTAssertEqual(state.soundingNoteCount, 1)
            let switched = PlayEngine.step(state, .selectScene(h.two))
            XCTAssertEqual(switched.1, [.sceneChanged(h.two)])
            var document = h.document
            document.revision = try document.revision.advanced()
            document.currentSceneID = h.two
            let layers = document.spatial.layers.map { layer in
                SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color, isVisible: layer.isVisible,
                    isActive: layer.id == h.b || layer.id == h.control, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
                    cells: layer.cells, routings: layer.routings, cellOverrides: layer.cellOverrides)
            }
            document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: h.a)
            change(&document.channels[0])
            let installed = PlayEngine.step(switched.0, .install(try InstrumentCompiler.compile(document)))
            XCTAssertTrue(installed.1.isEmpty, name)
            let held = PlayEngine.step(installed.0, .frame(try h.frame(2, 0.1, rings: [100, 120])))
            XCTAssertTrue(held.1.isEmpty, "\(name): no Off of sustained A or On of already occupied B")
            XCTAssertEqual(held.0.soundingNoteCount, 1, name)
            let exit = PlayEngine.step(held.0, .frame(try h.frame(3, 0.2, rings: [])))
            XCTAssertEqual(exit.1.filter { if case .noteOff = $0 { return true }; return false }.count, 1, name)
            let reentry = PlayEngine.step(exit.0, .frame(try h.frame(4, 0.3, rings: [120])))
            XCTAssertEqual(reentry.1.filter { if case .noteOn = $0 { return true }; return false }.count, 1, name)
        }
    }

    func testSceneUnchangedMusicInstallKeepsEntryLatchAndPanicCells() throws {
        let h = try SceneHarness()
        var document = h.document; document.revision = try document.revision.advanced()
        document.channel.levelDecibels = -6
        let replacement = try InstrumentCompiler.compile(document)
        var state = PlayEngine.step(PlayState(), .install(h.instrument)).0
        let fired = PlayEngine.step(state, .frame(try h.frame(1, 0, rings: [140])))
        XCTAssertEqual(fired.1, [.sceneChanged(h.two)])
        state = PlayEngine.step(fired.0, .install(replacement)).0
        let held = PlayEngine.step(state, .frame(try h.frame(2, 0.21, rings: [140])))
        XCTAssertTrue(held.1.isEmpty, "Install preserves the entry latch")
        document.revision = try document.revision.advanced()
        state = PlayEngine.step(held.0, .install(try InstrumentCompiler.compile(document))).0
        XCTAssertTrue(PlayEngine.step(state, .frame(try h.frame(3, 0.42, rings: [140]))).1.isEmpty, "Fired entry cannot rearm on install")

        state = PlayEngine.step(fired.0, .panic).0
        document.revision = try document.revision.advanced()
        state = PlayEngine.step(state, .install(try InstrumentCompiler.compile(document))).0
        state = PlayEngine.step(state, .frame(try h.frame(4, 0.5, rings: [140]))).0
        XCTAssertTrue(PlayEngine.step(state, .frame(try h.frame(5, 0.71, rings: [140]))).1.isEmpty, "PANIC control cell remains blocked")
        state = PlayEngine.step(state, .frame(try h.frame(6, 0.8, rings: []))).0
        let reentered = PlayEngine.step(state, .frame(try h.frame(7, 0.9, rings: [140])))
        XCTAssertEqual(reentered.1, [.sceneChanged(h.three)])
        XCTAssertTrue(PlayEngine.step(reentered.0, .frame(try h.frame(8, 1.11, rings: [140]))).1.isEmpty)
    }
    func testSceneUnchangedInstallDoesNotActivateAuthoredInactiveControl() throws {
        let h = try SceneHarness()
        var document = h.document
        let layers = document.spatial.layers.map { layer in
            SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color, isVisible: layer.isVisible,
                isActive: layer.id == h.a, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
                cells: layer.cells, routings: layer.routings, cellOverrides: layer.cellOverrides)
        }
        document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: h.a)
        var state = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(document))).0
        document.revision = try document.revision.advanced(); document.channel.levelDecibels = -6
        state = PlayEngine.step(state, .install(try InstrumentCompiler.compile(document))).0
        state = PlayEngine.step(state, .frame(try h.frame(1, 0, rings: [140]))).0
        XCTAssertTrue(PlayEngine.step(state, .frame(try h.frame(2, 0.21, rings: [140]))).1.isEmpty,
                      "An unchanged install cannot activate an explicitly inactive control layer")
    }
    func testSceneUnchangedInstallKeepsActiveIDsExcludedFromIndexBySolo() throws {
        let h = try SceneHarness()
        var document = h.document; document.scenes = []; document.currentSceneID = nil
        let layers = document.spatial.layers.map { layer in
            SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color, isVisible: layer.isVisible,
                isActive: layer.id != h.control, isLocked: layer.isLocked, isSoloed: layer.id == h.a,
                cells: layer.cells, routings: layer.routings, cellOverrides: layer.cellOverrides)
        }
        document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: h.a)
        let state = PlayEngine.step(PlayState(), .install(try InstrumentCompiler.compile(document))).0
        XCTAssertEqual(state.sceneSnapshot?.activeLayerIDs, [h.a, h.b])
        document.revision = try document.revision.advanced(); document.channel.pan = 0.5
        let installed = PlayEngine.step(state, .install(try InstrumentCompiler.compile(document))).0
        XCTAssertEqual(installed.sceneSnapshot?.activeLayerIDs, state.sceneSnapshot?.activeLayerIDs)
        XCTAssertEqual(installed.sceneSnapshot?.generation, state.sceneSnapshot?.generation)
    }

    /// 8,000 seeded sequences, lengths 1...8. An independent external note
    /// model checks emitted events, rather than trusting the ledger's counter.
    func testSeededAllInputsAndReturnGuarantee() throws {
        let normal = try compiled()
        let noNotes = try compiled(2, notes: false)
        let overlap = try compiled(3, transition: .overlap(milliseconds: 25))
        let configured = try compiled(4, detection: .ownerDefaults)
        var random = Generator()
        var seen = Set<Int>()
        var steps = 0
        for sequence in 0..<8_000 {
            var state = PlayState()
            var sound = Set<Sound>()
            var panicAwaitingProfile = false
            for offset in 0..<(sequence % 8 + 1) {
                let choice = random.index(19)
                seen.insert(choice)
                let tick = UInt64(offset + 1)
                let input: PlayInput
                let releases: Bool
                switch choice {
                case 0: input = .install(normal); releases = false
                case 1: input = .install(noNotes); releases = true
                case 2: input = .install(overlap); releases = false
                case 3: input = .frame(try frame(tick)); releases = false
                case 4: input = .frame(try frame(tick, ring: 120)); releases = false
                case 5: input = .frame(try frame(tick, empty: true)); releases = true
                case 6: input = .sessionBegan(session); releases = true
                case 7: input = .sessionEnded(session); releases = true
                case 8: input = .panic; releases = true; panicAwaitingProfile = true
                case 9: input = .stop; releases = true
                case 10: input = .sleep; releases = true
                case 11: input = .wake; releases = true
                case 12: input = .terminate; releases = true
                case 13: input = .detectionChanged(configured); releases = false
                case 14: input = .roomContour(nil); releases = false
                case 15: input = .inputLost; releases = true
                case 16:
                    input = .roomContour(SpatialRoomContour(
                        capturedAt: Date(timeIntervalSince1970: 0),
                        geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5, startAngleDegrees: -90,
                                        sourceIdentifier: "scanner:default"),
                        nearestDistancesCentimeters: Array(repeating: 150, count: 361),
                        spreadCentimeters: Array(repeating: 0, count: 361)))
                    releases = false
                case 18: input = .timeAdvanced(Double(tick)); releases = true
                case 17: input = .sessionEnded(UUID(uuidString: "00000000-0000-0000-0000-000000000099")!); releases = false
                default: fatalError("exhaustive generator")
                }
                let beforeCount = state.processedProfileCount
                let beforeRevision = state.instrument?.revision
                let result = PlayEngine.step(state, input)
                state = result.0
                observe(result.1, sound: &sound)
                XCTAssertEqual(sound.count, state.soundingNoteCount, "sequence \(sequence), offset \(offset), input \(choice)")
                if releases { XCTAssertTrue(sound.isEmpty, "release input \(choice)") }
                if case .frame = input {
                    if state.instrument != nil {
                        XCTAssertEqual(state.processedProfileCount, beforeCount + 1, "return guarantee")
                    }
                    panicAwaitingProfile = false
                }
                if panicAwaitingProfile { XCTAssertTrue(sound.isEmpty, "Panic cannot restart from commands") }
                if case .install(let instrument) = input, beforeRevision == instrument.revision {
                    XCTAssertTrue(result.1.isEmpty, "same revision must be idempotent")
                }
                steps += 1
            }
            let ended = PlayEngine.step(state, .terminate)
            observe(ended.1, sound: &sound)
            XCTAssertTrue(sound.isEmpty)
        }
        XCTAssertEqual(seen, Set(0..<19))
        XCTAssertEqual(steps, 36_000)
    }

    private func verifyRelease(_ input: PlayInput) throws {
        var state = PlayEngine.step(PlayState(), .install(try compiled(transition: .overlap(milliseconds: 25)))).0
        var sound = Set<Sound>()
        let on = PlayEngine.step(state, .frame(try frame(1)))
        state = on.0; observe(on.1, sound: &sound)
        XCTAssertEqual(sound.count, 2)
        let changed = PlayEngine.step(state, .frame(try frame(2, ring: 120)))
        state = changed.0; observe(changed.1, sound: &sound)
        XCTAssertEqual(sound.count, 4, "two overlap tails are owned")
        let result = PlayEngine.step(state, input)
        observe(result.1, sound: &sound)
        XCTAssertTrue(sound.isEmpty)
        XCTAssertEqual(result.0.soundingNoteCount, 0)
        // Every release path also has a playable return, without reinstall.
        let returnedRing: UInt16
        if case .panic = input { returnedRing = 120 } else { returnedRing = 100 }
        var returned = PlayEngine.step(result.0, .frame(try frame(3, ring: returnedRing)))
        XCTAssertEqual(returned.0.processedProfileCount, result.0.processedProfileCount + 1)
        if case .panic = input {
            XCTAssertEqual(returned.0.soundingNoteCount, 0, "Panic-held cell stays silent")
            let left = PlayEngine.step(returned.0, .frame(try frame(4, empty: true)))
            returned = PlayEngine.step(left.0, .frame(try frame(5)))
        }
        if result.0.instrument?.layers.contains(where: { !$0.routings.isEmpty }) == true {
            XCTAssertEqual(returned.0.soundingNoteCount, 2)
        }
    }
    func testReleaseInputLoss() throws { try verifyRelease(.inputLost) }
    func testReleaseStale() throws { try verifyRelease(.timeAdvanced(3)) }
    func testReleaseStop() throws { try verifyRelease(.stop) }
    func testReleaseSleep() throws { try verifyRelease(.sleep) }
    func testReleaseWake() throws { try verifyRelease(.wake) }
    func testReleaseTerminate() throws { try verifyRelease(.terminate) }
    func testReleasePanic() throws { try verifyRelease(.panic) }
    func testReleaseSessionEnd() throws { try verifyRelease(.sessionEnded(session)) }
    func testReleaseSessionBegin() throws { try verifyRelease(.sessionBegan(session)) }
    func testReleaseInstallWithoutCarrier() throws { try verifyRelease(.install(try compiled(5, notes: false))) }
    func testReleaseEmptyProfile() throws { try verifyRelease(.frame(try frame(3, empty: true))) }

    func testSameRevisionIdempotenceAndSupportedInstallKeepsNotes() throws {
        let original = try compiled()
        var state = PlayEngine.step(PlayState(), .install(original)).0
        state = PlayEngine.step(state, .frame(try frame(1))).0
        let same = PlayEngine.step(state, .install(original))
        XCTAssertTrue(same.1.isEmpty)
        XCTAssertEqual(same.0.soundingNoteCount, 2)
        let supported = PlayEngine.step(same.0, .install(try compiled(2)))
        XCTAssertTrue(supported.1.isEmpty)
        XCTAssertEqual(supported.0.soundingNoteCount, 2)
        XCTAssertTrue(PlayEngine.step(supported.0, .frame(try frame(2))).1.isEmpty)
    }

    func testOverlapAndStaleUseSuppliedTimeWithoutAnotherProfile() throws {
        var state = PlayEngine.step(PlayState(), .install(try compiled(transition: .overlap(milliseconds: 25)))).0
        state = PlayEngine.step(state, .frame(try frame(1))).0
        state = PlayEngine.step(state, .frame(try frame(2, ring: 120))).0
        XCTAssertEqual(state.soundingNoteCount, 4)
        let deadline = try XCTUnwrap(state.nextDeadline)
        XCTAssertEqual(deadline, 2.025, accuracy: 0.000_001)
        let overlapOff = PlayEngine.step(state, .timeAdvanced(deadline))
        XCTAssertEqual(overlapOff.1.count, 2)
        XCTAssertEqual(overlapOff.0.soundingNoteCount, 2)
        let staleOff = PlayEngine.step(overlapOff.0, .timeAdvanced(try XCTUnwrap(overlapOff.0.nextDeadline)))
        XCTAssertEqual(staleOff.1.count, 2)
        XCTAssertEqual(staleOff.0.soundingNoteCount, 0)
        XCTAssertNil(staleOff.0.nextDeadline)
        XCTAssertEqual(PlayEngine.step(staleOff.0, .frame(try frame(3))).0.soundingNoteCount, 2)
    }

    func testInstrumentIdentityChangeReleasesOnlyAUAndMIDITargetChangeOnlyMIDI() throws {
        let a = SpatialAudioUnitIdentity(componentType: 1, componentSubType: 2, componentManufacturer: 3)
        let b = SpatialAudioUnitIdentity(componentType: 1, componentSubType: 4, componentManufacturer: 3)
        var channel = InstrumentChannel(instrument: .init(identity: a, state: Data([1])), midiTarget: .init(uniqueID: 42))
        var state = PlayEngine.step(PlayState(), .install(try compiled(channel: channel))).0
        state = PlayEngine.step(state, .frame(try frame(1))).0
        channel.instrument?.state = Data([2])
        let stateChange = PlayEngine.step(state, .install(try compiled(2, channel: channel)))
        XCTAssertTrue(stateChange.1.isEmpty, "state change keeps the same instrument carrier")
        channel.instrument?.identity = b
        let auChange = PlayEngine.step(stateChange.0, .install(try compiled(3, channel: channel)))
        XCTAssertEqual(auChange.1, [.noteOff(destination: .audioUnit(stripID: InstrumentChannel.legacyID), channel: 3, note: .init(number: 60, velocity: 100))])
        XCTAssertEqual(auChange.0.soundingNoteCount, 1, "MIDI does not belong to the AU instrument")
        state = PlayEngine.step(auChange.0, .frame(try frame(2))).0
        channel.midiTarget = .init(uniqueID: 99)
        let midiChange = PlayEngine.step(state, .install(try compiled(4, channel: channel)))
        XCTAssertEqual(midiChange.1, [.noteOff(destination: .midi, channel: 2, note: .init(number: 60, velocity: 100))])
        XCTAssertEqual(midiChange.0.soundingNoteCount, 1)
    }

    func testEveryCommandIsDefinedWithoutInstrumentAndPanicCoversEveryDestination() throws {
        for command: PlayInput in [.panic, .stop, .sleep, .wake, .terminate, .inputLost,
                                   .sessionBegan(session), .sessionEnded(session), .roomContour(nil),
                                   .frame(try frame(1))] {
            let result = PlayEngine.step(PlayState(), command)
            XCTAssertNil(result.0.instrument)
            XCTAssertEqual(result.0.soundingNoteCount, 0)
        }
        XCTAssertEqual(PlayEngine.step(PlayState(), .panic).1.count, 32)
    }

    func testSceneEntryKeepsExistingNotesAndRequiresMeasuredExitAtNinetyPoints() throws {
        let a = UUID(), b = UUID(), control = UUID(), first = UUID(), second = UUID()
        func cell(_ ring: Int, _ sector: Int = 180) throws -> PolarDeviceLattice {
            try XCTUnwrap(PolarDeviceLattice(ring: ring, sector: sector))
        }
        let note: SpatialValueProgram = .chord(notes: [60], velocity: 100, transition: .legato)
        let layers = [
            SpatialDocumentLayer(id: a, name: "A", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                                 cells: [try cell(100)], routings: [.init(target: .midiNote(channel: 0), program: note)], cellOverrides: [:]),
            SpatialDocumentLayer(id: b, name: "B", color: .blue, isVisible: true, isActive: false, isLocked: false, isSoloed: false,
                                 cells: [try cell(120)], routings: [.init(target: .midiNote(channel: 0), program: note)], cellOverrides: [:]),
            SpatialDocumentLayer(id: control, name: "Control", color: .green, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                                 cells: [try cell(140, 181)], routings: [.init(target: .sceneSwitch(action: .scene(second), dwellSeconds: 0.2), program: .constant(1))], cellOverrides: [:])
        ]
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: a)
        let scenes = [SpatialScene(id: first, name: "One", activeLayerIDs: [a]), SpatialScene(id: second, name: "Two", activeLayerIDs: [b])]
        let instrument = try InstrumentCompiler.compile(.init(spatial: spatial, detection: .allStagesOff,
            revision: .init(session: documentSession, counter: 40), scenes: scenes, currentSceneID: first))
        func sceneFrame(_ sequence: UInt64, _ time: Double, includeA: Bool = true, includeControl: Bool = true) throws -> ProfileFrame {
            var samples: [DeviceTickMeasurement] = []
            if includeA { samples.append(try XCTUnwrap(DeviceTickMeasurement(order: 45, ticks: try XCTUnwrap(.point(180)), rawCentimeters: 100))) }
            if includeControl { samples.append(try XCTUnwrap(DeviceTickMeasurement(order: 46, ticks: try XCTUnwrap(.point(181)), rawCentimeters: 140))) }
            return .init(sessionID: session, sequence: sequence, time: time, measurements: samples,
                         geometry: .init(operatingMode: "MMK", pointCount: 90, startAngleDegrees: -90, endAngleDegrees: 90))
        }
        var state = PlayEngine.step(PlayState(), .install(instrument)).0
        state = PlayEngine.step(state, .sessionBegan(session)).0
        state = PlayEngine.step(state, .frame(try sceneFrame(0, -0.1, includeControl: false))).0
        let entered = PlayEngine.step(state, .frame(try sceneFrame(1, 0)))
        state = entered.0
        XCTAssertEqual(entered.1.filter { if case .sceneChanged(second) = $0 { return true }; return false }.count, 1)
        XCTAssertFalse(entered.1.contains { if case .noteOff = $0 { return true }; return false })
        let short = PlayEngine.step(state, .frame(try sceneFrame(2, 0.15)))
        state = short.0
        XCTAssertFalse(short.1.contains { if case .sceneChanged = $0 { return true }; return false })
        let fired = PlayEngine.step(state, .frame(try sceneFrame(3, 0.2)))
        state = fired.0
        XCTAssertFalse(fired.1.contains { if case .sceneChanged = $0 { return true }; return false })
        XCTAssertFalse(fired.1.contains { if case .noteOff = $0 { return true }; return false })
        let held = PlayEngine.step(state, .frame(try sceneFrame(4, 2)))
        XCTAssertFalse(held.1.contains { if case .sceneChanged = $0 { return true }; return false })
        XCTAssertFalse(held.1.contains { if case .noteOff = $0 { return true }; return false })
        let left = PlayEngine.step(held.0, .frame(try sceneFrame(5, 2.1, includeA: false, includeControl: false)))
        XCTAssertEqual(left.1.filter { if case .noteOff = $0 { return true }; return false }.count, 1)
    }

    func testSceneSwitchKeepsNoteForLayerActiveInBothScenes() throws {
        let harness = try SceneHarness(sharedA: true)
        var state = PlayEngine.step(PlayState(), .install(harness.instrument)).0
        state = PlayEngine.step(state, .sessionBegan(session)).0
        state = PlayEngine.step(state, .frame(try harness.frame(1, 0, rings: [100]))).0
        let changed = PlayEngine.step(state, .frame(try harness.frame(2, 0.01, rings: [100, 140])))
        XCTAssertEqual(changed.1.filter { if case .sceneChanged(harness.two) = $0 { return true }; return false }.count, 1)
        XCTAssertFalse(changed.1.contains { if case .noteOff = $0 { return true }; return false })
        XCTAssertFalse(changed.1.contains { if case .noteOn = $0 { return true }; return false })
        let continued = PlayEngine.step(changed.0, .frame(try harness.frame(3, 0.3, rings: [100, 140])))
        XCTAssertFalse(continued.1.contains { if case .noteOff = $0 { return true }; return false })
        XCTAssertFalse(continued.1.contains { if case .noteOn = $0 { return true }; return false })
    }

    func testMutedLayerMovingToAnotherCellStopsWithoutStartingAnotherNote() throws {
        let harness = try SceneHarness()
        let moved = PlayEngine.step(try mutedSceneState(harness), .frame(try harness.frame(3, 0.3, rings: [110, 140])))
        XCTAssertEqual(moved.1.filter { if case .noteOff = $0 { return true }; return false }.count, 1)
        XCTAssertFalse(moved.1.contains { if case .noteOn = $0 { return true }; return false })
    }

    func testMutedLayerCannotStartANewNote() throws {
        let harness = try SceneHarness()
        let entered = PlayEngine.step(try mutedSceneState(harness), .frame(try harness.frame(3, 0.3, rings: [110])))
        let held = PlayEngine.step(entered.0, .frame(try harness.frame(4, 0.4, rings: [110])))
        XCTAssertFalse(held.1.contains { if case .noteOn = $0 { return true }; return false })
    }

    func testSceneSwitchSwipeAndNextRoundTripRequireMeasuredReentry() throws {
        let harness = try SceneHarness()
        var state = PlayEngine.step(PlayState(), .install(harness.instrument)).0
        state = PlayEngine.step(state, .sessionBegan(session)).0
        let swipe = PlayEngine.step(state, .frame(try harness.frame(1, 0, rings: [140])))
        state = swipe.0
        XCTAssertEqual(swipe.1.filter { if case .sceneChanged(harness.two) = $0 { return true }; return false }.count, 1)
        state = PlayEngine.step(state, .frame(try harness.frame(2, 0.05, rings: []))).0
        let first = PlayEngine.step(state, .frame(try harness.frame(3, 1, rings: [140])))
        XCTAssertEqual(first.1.filter { if case .sceneChanged(harness.three) = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(PlayEngine.step(first.0, .frame(try harness.frame(4, 1.21, rings: [140]))).1.isEmpty)
        state = PlayEngine.step(first.0, .frame(try harness.frame(5, 1.3, rings: []))).0
        let second = PlayEngine.step(state, .frame(try harness.frame(6, 2, rings: [140])))
        XCTAssertEqual(second.1.filter { if case .sceneChanged(harness.one) = $0 { return true }; return false }.count, 1)
    }

    func testMutedSceneNoteReleasesForLossStopPresetAndPanic() throws {
        let harness = try SceneHarness()
        let replacement = try compiled(99, notes: false)
        for (name, input) in [("loss", PlayInput.inputLost), ("stop", .stop), ("preset", .install(replacement)), ("panic", .panic)] {
            let released = PlayEngine.step(try mutedSceneState(harness), input)
            XCTAssertTrue(released.1.contains { if case .noteOff = $0 { return true }; return false }, name)
            XCTAssertEqual(released.0.soundingNoteCount, 0, name)
        }
    }
}

extension PlayEngineModelTests {
    func testRundeEReleaseHoldBlockSurvivesDriftUntilAnotherSurface() throws {
        let releaseID = UUID()
        let cells = Set((100...160).map { PolarDeviceLattice(ring: $0,sector: 180)! })
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let note = SpatialDocumentLayer(id: layerID,name: "Hold",color: .blue,isVisible: true,isActive: true,isLocked: false,isSoloed: false,
            cells: cells,routings: [.init(target: target,program: .chord(notes: [60],velocity: 100,transition: .holdUntilNext))],
            cellOverrides: Dictionary(uniqueKeysWithValues: (140...160).map { (PolarDeviceLattice(ring: $0,sector: 180)!,[.init(target: target,value: .note(number: 67,velocity: 100))]) }))
        let release = SpatialDocumentLayer(id: releaseID,name: "Release",color: .orange,isVisible: true,isActive: true,isLocked: false,isSoloed: false,
            cells: [PolarDeviceLattice(ring: 100,sector: 180)!],routings: [.init(target: .releaseLayer(layerID: layerID),program: .constant(1))],cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2,layers: [note,release],selectedLayerID: layerID)
        let instrument = try InstrumentCompiler.compile(.init(spatial: spatial,detection: .allStagesOff,revision: .newSession()))
        var state = PlayEngine.step(PlayState(),.install(instrument)).0
        state = PlayEngine.step(state,.frame(try frame(1,ring: 110))).0
        XCTAssertEqual(state.soundingNoteCount,1)
        state = PlayEngine.step(state,.frame(try frame(2,ring: 100))).0
        XCTAssertEqual(state.soundingNoteCount,0)
        for (n,distance) in [106,130].enumerated() {
            let result = PlayEngine.step(state,.frame(try frame(UInt64(n+3),ring: UInt16(distance))))
            state = result.0
            XCTAssertFalse(result.1.contains { if case .noteOn = $0 { return true }; return false })
            XCTAssertEqual(state.soundingNoteCount,0)
        }
        let crossed = PlayEngine.step(state,.frame(try frame(5,ring: 145)))
        XCTAssertEqual(crossed.0.soundingNoteCount,1)
        XCTAssertTrue(crossed.1.contains { if case .noteOn(_,_,let note) = $0 { return note.number == 67 }; return false })
    }

    func testRundeESceneActivationBlockSurvivesDriftUntilAnotherSurface() throws {
        let b = UUID(), one = UUID(), two = UUID()
        let cells = Set((100...160).map { PolarDeviceLattice(ring: $0,sector: 180)! })
        let target = SpatialRoutingTarget.midiNote(channel: 0)
        let layers = [(layerID,true,60),(b,false,64)].map { id,active,number in
            SpatialDocumentLayer(id: id,name: "Scene",color: .blue,isVisible: true,isActive: active,isLocked: false,isSoloed: false,
                cells: cells,routings: [.init(target: target,program: .chord(notes: [number],velocity: 100,transition: .legato))],
                cellOverrides: Dictionary(uniqueKeysWithValues: (140...160).map { (PolarDeviceLattice(ring: $0,sector: 180)!,[.init(target: target,value: .note(number: 67,velocity: 100))]) }))
        }
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2,layers: layers,selectedLayerID: layerID)
        let instrument = try InstrumentCompiler.compile(.init(spatial: spatial,detection: .allStagesOff,revision: .newSession(),
            scenes: [.init(id: one,name: "One",activeLayerIDs: [layerID]),.init(id: two,name: "Two",activeLayerIDs: [b])],currentSceneID: one))
        var state = PlayEngine.step(PlayState(),.install(instrument)).0
        state = PlayEngine.step(state,.frame(try frame(1,ring: 100))).0
        state = PlayEngine.step(state,.selectScene(two)).0
        for (n,distance) in [106,130].enumerated() {
            let result = PlayEngine.step(state,.frame(try frame(UInt64(n+2),ring: UInt16(distance))))
            state = result.0
            XCTAssertFalse(result.1.contains { if case .noteOn = $0 { return true }; return false })
        }
        let crossed = PlayEngine.step(state,.frame(try frame(4,ring: 145)))
        XCTAssertTrue(crossed.1.contains { if case .noteOn(_,_,let note) = $0 { return note.number == 67 }; return false })
    }
}
