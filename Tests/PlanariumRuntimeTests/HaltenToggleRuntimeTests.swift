import XCTest
import Dispatch
import PlanariumDomain
import PlanariumRuntime

final class HaltenToggleRuntimeTests: RuntimeTestCase {
    func testSoundingNotesPublishWithoutEnablingFullOutputMonitor() throws {
        let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
        c.runtime.install(try mixed(.holdUntilNext, guardSeconds: 0)); c.runtime.sessionBegan(session)
        c.runtime.frame(.init(sessionID: session, sequence: 1, time: 10,
            measurements: [DeviceTickMeasurement(order: 0, ticks: .point(180)!, rawCentimeters: 100)!]))
        flush(c.runtime)
        let frame = try XCTUnwrap(c.mailbox.read())
        XCTAssertFalse(frame.soundingNoteOwners.isEmpty)
        XCTAssertTrue(frame.outputMonitor.isEmpty)
        c.runtime.panic(); flush(c.runtime)
        XCTAssertTrue(c.mailbox.read()?.soundingNoteOwners.isEmpty == true)
    }

    func testGuardUsesProfileTimeOnBothFakeOutputsAndDiscardsEarlyEntry() throws {
        for seconds in [0.0, 0.5, 2.0] {
            let midi = FakeBoundary(), au = FakeBoundary(), clock = FakeClock()
            let c = composition(clock: clock, midi: midi, au: au)
            c.runtime.install(try mixed(.toggle, guardSeconds: seconds)); c.runtime.sessionBegan(session)
            var sequence: UInt64 = 0
            func deliver(_ occupied: Bool, _ time: Double) {
                sequence += 1
                c.runtime.frame(.init(sessionID: session, sequence: sequence, time: time,
                    measurements: occupied ? [DeviceTickMeasurement(order: 0, ticks: .point(180)!, rawCentimeters: 100)!] : []))
                flush(c.runtime)
            }
            deliver(true, 10)
            for sink in [midi, au] { XCTAssertEqual(sink.sounding, [60]) }
            deliver(false, 10.01); deliver(true, 10.02)
            for sink in [midi, au] { XCTAssertEqual(sink.sounding, seconds == 0 ? [] : [60]) }
            deliver(true, 10 + seconds + 0.03)
            for sink in [midi, au] { XCTAssertEqual(sink.sounding, seconds == 0 ? [] : [60], "No delayed replay") }
            deliver(false, 10 + seconds + 0.04); deliver(true, 10 + seconds + 0.05)
            for sink in [midi, au] { XCTAssertEqual(sink.sounding, seconds == 0 ? [60] : []) }
            deliver(false, 10 + seconds + 0.06); deliver(true, 10 + seconds + 0.07)
            for sink in [midi, au] { XCTAssertTrue(sink.sounding.isEmpty, "Off edge also protected") }
            XCTAssertEqual(clock.now, 10, "No wall time or timer advancement")
            c.runtime.stop(); flush(c.runtime)
        }
    }
    func testSnapMeasuredBoundaryDrivesLegatoHoldAndToggleOnBothFakeOutputs() throws {
        for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
            let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
            let a = try LegacyLatticeMigration.migrate(.init(ring: 4, angularIndex: 16), in: .quarterMeter).cells
            let b = try LegacyLatticeMigration.migrate(.init(ring: 5, angularIndex: 16), in: .quarterMeter).cells
            let targets: [SpatialRoutingTarget] = [.midiNote(channel: 0), .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)]
            let layer = SpatialDocumentLayer(id: session, name: "Snap notes", color: .orange,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: a.union(b),
                routings: targets.map { .init(target: $0, program: .singleNote(note: 60, velocity: 90, transition: transition)) },
                cellOverrides: Dictionary(uniqueKeysWithValues: b.map { cell in
                    (cell, targets.map { .init(target: $0, value: .note(number: 64, velocity: 90)) })
                }), toggleGuardSeconds: 0)
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: session)
            var config = DetectionConfiguration.allStagesOff
            config.cellSelection = .init(boundaryMarginCentimeters: 5)
            c.runtime.install(try InstrumentCompiler.compile(.init(spatial: spatial, detection: config, revision: .newSession())))
            c.runtime.sessionBegan(session)
            var sequence: UInt64 = 0
            func deliver(_ radii: [UInt16]) {
                sequence += 1
                c.runtime.frame(.init(sessionID: session, sequence: sequence, time: 10 + Double(sequence) / 25,
                    measurements: radii.enumerated().map { DeviceTickMeasurement(order: $0.offset, ticks: .point(185)!, rawCentimeters: $0.element)! }))
                flush(c.runtime)
            }
            deliver([101])
            for sink in [midi, au] { XCTAssertEqual(sink.sounding, [60]) }
            for raw: UInt16 in [125, 130, 124, 130] {
                deliver([raw])
                for sink in [midi, au] { XCTAssertEqual(sink.sounding, [60], "No musical change before the Snap boundary") }
            }
            deliver([131])
            for sink in [midi, au] { XCTAssertEqual(sink.sounding, transition == .toggle ? [60, 64] : [64]) }
            deliver([126]); deliver([131])
            for sink in [midi, au] { XCTAssertEqual(sink.sounding, transition == .toggle ? [60, 64] : [64], "No false re-entry inside Snap") }
            deliver([])
            for sink in [midi, au] { XCTAssertEqual(sink.sounding.count, transition == .legato ? 0 : transition == .toggle ? 2 : 1) }
            if transition == .toggle {
                deliver([131])
                for sink in [midi, au] { XCTAssertEqual(sink.sounding, [60], "Real exit rearms toggle") }
                deliver([]); deliver([101, 140])
                for sink in [midi, au] { XCTAssertEqual(sink.sounding, [64], "Two hands can toggle independent surfaces in one layer") }
            }
            c.runtime.panic(); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
            c.runtime.stop(); flush(c.runtime)
        }
    }
    func testIngressOverflowReleasesAlsoLatchedNotesAndRecoversOnBothFakeSinks() throws {
        let midi = FakeBoundary(), au = FakeBoundary(), mailbox = DisplayFrameMailbox()
        let runtime = PerformanceRuntime(clock: FakeClock(), mailbox: mailbox, profileCapacity: 1)
        runtime.attach(RuntimePorts.midi(id: midiID, boundary: midi))
        runtime.attach(RuntimePorts.audioUnit(id: auID, boundary: au))
        runtime.install(try mixed()); runtime.sessionBegan(session)
        let entered = expectation(description: "First profile in MIDI fake"), gate = DispatchSemaphore(value: 0)
        midi.setHook { bytes in
            if bytes == [0x90, 60, 100] { entered.fulfill(); gate.wait() }
        }
        runtime.frame(profile())
        wait(for: [entered], timeout: 10)
        midi.setHook(nil)
        runtime.frame(profile(2)); runtime.frame(profile(3))
        gate.signal(); flush(runtime)
        XCTAssertEqual(mailbox.read()?.overflowProfiles, 1)
        XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
        flush(runtime)
        XCTAssertEqual(runtime.inputBacklogStatus, .recovered)
        runtime.frame(profile(4)); flush(runtime)
        XCTAssertEqual(midi.sounding.count, 3); XCTAssertEqual(au.sounding.count, 3)
        runtime.panic(); flush(runtime)
        XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
    }
    func testHaltenWechselOverlappingProfilesAndCommonNotePolicyOnBothFakeOutputs() throws {
        for count in [90, 361] { for policy in SpatialCommonNotes.allCases {
            let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            let orders = [count / 3, count * 2 / 3], ids = [UUID(), UUID()]
            let layers = ids.indices.map { i -> SpatialDocumentLayer in
                let span = geometry.tickSpan(at: orders[i])!
                return .init(id: ids[i], name: i == 0 ? "Em" : "C", color: .orange,
                    isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                    cells: Set((span.lower...span.upper).map { PolarDeviceLattice(ring: 100, sector: $0)! }),
                    routings: [SpatialRoutingTarget.midiNote(channel: 0), .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)].map {
                        .init(target: $0, program: .chord(notes: i == 0 ? [59, 64, 67] : [60, 64, 67], velocity: 100, transition: .holdUntilNext))
                    }, cellOverrides: [:], commonNotes: policy)
            }
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: ids[0])
            c.runtime.install(try InstrumentCompiler.compile(.init(spatial: spatial, detection: .allStagesOff, revision: .newSession())))
            c.runtime.sessionBegan(session)
            var sequence: UInt64 = 0
            func deliver(_ active: [Int]) {
                sequence += 1
                c.runtime.frame(.init(sessionID: session, sequence: sequence, time: 10 + Double(sequence) / 25,
                    measurements: active.map { DeviceTickMeasurement(order: orders[$0], ticks: geometry.tickSpan(at: orders[$0])!, rawCentimeters: 100)! }, geometry: geometry))
                flush(c.runtime)
            }
            deliver([0])
            let midiBefore = midi.receipts.count, auBefore = au.receipts.count
            deliver([0, 1])
            for (sink, offset) in [(midi, midiBefore), (au, auBefore)] {
                XCTAssertEqual(sink.sounding, [60, 64, 67])
                let bytes = sink.receipts.dropFirst(offset).map(\.bytes)
                XCTAssertTrue(bytes.contains([0x80, 59, 0]))
                XCTAssertTrue(bytes.contains([0x90, 60, 100]))
                for common: UInt8 in [64, 67] {
                    XCTAssertEqual(bytes.contains([0x80, common, 0]), policy == .retrigger)
                    XCTAssertEqual(bytes.contains([0x90, common, 100]), policy == .retrigger)
                }
                XCTAssertEqual(sink.duplicateOns, 0)
            }
            deliver([0, 1]); deliver([1]); deliver([])
            c.runtime.sessionEnded(session, reason: .failure); flush(c.runtime)
            for sink in [midi, au] { XCTAssertEqual(sink.sounding, [60, 64, 67]) }
            c.runtime.panic(); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
            c.runtime.stop(); flush(c.runtime)
        } }
    }
    func testAuditionUsesQAndSharedLedgerWithAndWithoutScanner90And361() throws {
        for count in [90, 361] { for connected in [false, true] {
            for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
                let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
                c.runtime.install(try mixed(transition, guardSeconds: 0))
                if connected {
                    c.runtime.sessionBegan(session)
                    c.runtime.frame(.init(sessionID: session, sequence: 1, time: 10, measurements: [],
                        geometry: .init(operatingMode: "test", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)))
                }
                c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime)
                XCTAssertEqual(midi.sounding, [60]); XCTAssertEqual(au.sounding, [60])
                c.runtime.audition(nil); flush(c.runtime)
                XCTAssertEqual(midi.sounding.isEmpty, transition == .legato)
                c.runtime.panic(); flush(c.runtime)
                XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
                c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime)
                XCTAssertEqual(midi.sounding, [60])
                c.runtime.panic(); flush(c.runtime)
                c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime)
                XCTAssertTrue(midi.sounding.isEmpty, "PANIC blocks the occupied surface on the same ledger path")
                c.runtime.audition(nil); c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime)
                XCTAssertEqual(midi.sounding, [60])
                c.runtime.stop(); flush(c.runtime)
            }
        } }
    }

    func testAuditionContinuousDistanceMatchesMeasuredQEvaluation90And361() throws {
        for count in [90, 361] {
            let midi = FakeBoundary(), c = composition(midi: midi)
            let layer = SpatialDocumentLayer(id: session, name: "Continuous", color: .orange,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: Set((100...200).map { PolarDeviceLattice(ring: $0, sector: 180)! }),
                routings: [.init(target: .midiCC(channel: 0, controller: 74),
                    program: .continuous(minimum: 0, maximum: 1, directionDegrees: 90, curve: .linear))], cellOverrides: [:])
            let doc = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: session),
                detection: .allStagesOff, revision: .newSession())
            c.runtime.install(try InstrumentCompiler.compile(doc))
            c.runtime.audition(.init(xMeters: 0, yMeters: 1.25)); flush(c.runtime)
            XCTAssertEqual(midi.receipts.last?.bytes, [0xB0, 74, 32])
            c.runtime.audition(.init(xMeters: 0, yMeters: 1.5)); flush(c.runtime)
            XCTAssertEqual(midi.receipts.last?.bytes, [0xB0, 74, 64])
            c.runtime.audition(nil); c.runtime.sessionBegan(session)
            c.runtime.frame(.init(sessionID: session, sequence: 1, time: 10,
                measurements: [.init(order: 0, ticks: .point(180)!, rawCentimeters: 125)!],
                geometry: .init(operatingMode: "test", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)))
            flush(c.runtime); XCTAssertEqual(midi.receipts.last?.bytes, [0xB0, 74, 32])
            c.runtime.stop(); flush(c.runtime)
        }
    }

    func testAuditionRemainsAdditionalHandAcrossScannerBeginFailureAndStale90And361() throws {
        for count in [90, 361] {
            let midi = FakeBoundary(), clock = FakeClock(), c = composition(clock: clock, midi: midi)
            c.runtime.install(try mixed(.legato)); c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime)
            XCTAssertEqual(midi.sounding, [60])
            c.runtime.sessionBegan(session)
            c.runtime.frame(.init(sessionID: session, sequence: 1, time: 10, measurements: [],
                geometry: .init(operatingMode: "test", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)))
            flush(c.runtime); XCTAssertEqual(midi.sounding, [60])
            clock.advance(11); flush(c.runtime); XCTAssertEqual(midi.sounding, [60])
            c.runtime.sessionEnded(session, reason: .failure); flush(c.runtime)
            XCTAssertEqual(midi.sounding, [60])
            c.runtime.audition(nil); flush(c.runtime); XCTAssertTrue(midi.sounding.isEmpty)
            c.runtime.stop(); flush(c.runtime)
        }
    }

    func testMeasuredSceneEdgeEndsAuditionOnQWithoutMainCallback90And361() throws {
        for count in [90, 361] {
            let midi = FakeBoundary(), c = composition(midi: midi)
            let note = SpatialDocumentLayer(id: UUID(), name: "Note", color: .orange,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: [PolarDeviceLattice(ring: 100, sector: 180)!],
                routings: [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 90, transition: .legato))], cellOverrides: [:])
            let control = SpatialDocumentLayer(id: UUID(), name: "Next", color: .blue,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: [PolarDeviceLattice(ring: 140, sector: 200)!],
                routings: [.init(target: .sceneSwitch(action: .next, dwellSeconds: 0.2), program: .constant(1))], cellOverrides: [:])
            let a = SpatialScene(name: "A", activeLayerIDs: [note.id]), b = SpatialScene(name: "B", activeLayerIDs: [note.id])
            let doc = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [note, control], selectedLayerID: note.id),
                detection: .allStagesOff, revision: .newSession(), scenes: [a, b], currentSceneID: a.id)
            c.runtime.install(try InstrumentCompiler.compile(doc)); c.runtime.sessionBegan(session)
            c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime); XCTAssertEqual(midi.sounding, [60])
            c.runtime.frame(.init(sessionID: session, sequence: 1, time: 10,
                measurements: [.init(order: 0, ticks: .point(200)!, rawCentimeters: 140)!],
                geometry: .init(operatingMode: "test", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)))
            flush(c.runtime); XCTAssertTrue(midi.sounding.isEmpty)
            XCTAssertEqual(c.mailbox.read()?.scene?.currentSceneID, b.id)
            c.runtime.stop(); flush(c.runtime)
        }
    }

    func testAuditionCannotResurrectRealCarrierRejectedByDetectionEdit90And361() throws {
        for count in [90, 361] {
            let midi = FakeBoundary(), c = composition(midi: midi)
            c.runtime.install(try mixed(.legato)); c.runtime.sessionBegan(session)
            c.runtime.frame(.init(sessionID: session, sequence: 1, time: 10,
                measurements: [.init(order: 0, ticks: .point(180)!, rawCentimeters: 100)!],
                geometry: .init(operatingMode: "test", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)))
            flush(c.runtime); XCTAssertEqual(midi.sounding, [60])
            var detection = DetectionConfiguration.allStagesOff
            detection.groupingEnabled = true; detection.groupingMinimumPoints = 2
            c.runtime.detectionChanged(try mixed(.legato, revision: .init(session: session, counter: 2), detectionConfiguration: detection))
            flush(c.runtime); XCTAssertTrue(midi.sounding.isEmpty)
            c.runtime.audition(.init(xMeters: 0, yMeters: 2)); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty, "The new empty detector result remains authoritative")
            c.runtime.stop(); flush(c.runtime)
        }
    }

    func testStationaryAuditionSwitchesImmediatelyWithoutInventingScannerFrames() throws {
        let midi = FakeBoundary(), clock = FakeClock(), c = composition(clock: clock, midi: midi)
        let layer = SpatialDocumentLayer(id: session, name: "Scene", color: .orange,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [PolarDeviceLattice(ring: 100, sector: 180)!], routings: [
                .init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 90, transition: .legato)),
                .init(target: .sceneSwitch(action: .next, dwellSeconds: 0.2), program: .constant(1))], cellOverrides: [:])
        let a = SpatialScene(name: "A", activeLayerIDs: [layer.id]), b = SpatialScene(name: "B", activeLayerIDs: [layer.id])
        let doc = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: session),
            detection: .allStagesOff, revision: .newSession(), scenes: [a, b], currentSceneID: a.id)
        c.runtime.install(try InstrumentCompiler.compile(doc)); c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime)
        XCTAssertEqual(c.mailbox.read()?.scene?.currentSceneID, b.id)
        XCTAssertTrue(midi.sounding.isEmpty, "The scene edge ends the mixed musical hand immediately")
        clock.advance(11); flush(c.runtime); flush(c.runtime)
        XCTAssertEqual(c.mailbox.read()?.scene?.currentSceneID, b.id)
        XCTAssertEqual(c.runtime.diagnostics.processedProfiles, 0)
        XCTAssertTrue(clock.deadlines.isEmpty, "Ending the hand removes its Q deadline")
        c.runtime.stop(); flush(c.runtime)
    }

    func testAuditionExitAfterPanicCannotUnlockAStillMeasuredHand90And361() throws {
        for count in [90, 361] { for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
            let midi = FakeBoundary(), au = FakeBoundary(), c = composition(midi: midi, au: au)
            c.runtime.install(try mixed(transition, guardSeconds: 0)); c.runtime.sessionBegan(session)
            func frame(_ sequence: UInt64, occupied: Bool) {
                c.runtime.frame(.init(sessionID: session, sequence: sequence, time: 10,
                    measurements: occupied ? [.init(order: 0, ticks: .point(180)!, rawCentimeters: 100)!] : [],
                    geometry: .init(operatingMode: "test", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)))
                flush(c.runtime)
            }
            frame(1, occupied: true)
            c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime)
            XCTAssertEqual(midi.sounding, [60])
            c.runtime.panic(); c.runtime.audition(nil); flush(c.runtime)
            frame(2, occupied: true)
            XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
            frame(3, occupied: false); frame(4, occupied: true)
            XCTAssertEqual(midi.sounding, [60]); XCTAssertEqual(au.sounding, [60])
            c.runtime.stop(); flush(c.runtime)
        } }
    }

    private func mixed(_ transition: SpatialNoteTransition? = nil, revision: SpatialDocumentRevision? = nil, snap: UInt16 = 0, guardSeconds: Double = 0.5, detectionConfiguration: DetectionConfiguration? = nil) throws -> CompiledInstrument {
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let transitions: [SpatialNoteTransition] = transition.map { [$0] } ?? [.legato, .holdUntilNext, .toggle]
        let routes = [SpatialOutputDestination.midi, .audioUnit(stripID: InstrumentChannel.legacyID)].flatMap { destination in
            transitions.enumerated().map { index, value in
                SpatialRouting(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", (destination == .midi ? 100 : 200) + index))!,
                    target: destination == .midi ? .midiNote(channel: UInt8(index)) : .audioUnitNote(channel: UInt8(index), stripID: InstrumentChannel.legacyID),
                    program: .chord(notes: [60 + index], velocity: 100, transition: value))
            }
        }
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [
            .init(id: session, name: "Matrix", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                  cells: [cell], routings: routes, cellOverrides: [:], toggleGuardSeconds: guardSeconds)], selectedLayerID: session)
        var detection = detectionConfiguration ?? DetectionConfiguration.allStagesOff
        detection.cellSelection = .init(boundaryMarginCentimeters: snap)
        return try InstrumentCompiler.compile(.init(spatial: spatial, detection: detection, revision: revision ?? .init(session: session, counter: 1)))
    }
    func testBacklogAgeBudgetReleasesEveryNoteModeAt90And361AndRecovers() throws {
        for count in [90, 361] {
            let midi = FakeBoundary(), au = FakeBoundary(), clock = FakeClock()
            let c = composition(clock: clock, midi: midi, au: au)
            c.runtime.install(try mixed()); c.runtime.sessionBegan(session)
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan",
                pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            func frame(_ sequence: UInt64, time: Double) -> ProfileFrame {
                .init(sessionID: session, sequence: sequence, time: time,
                    measurements: (0..<count).map { DeviceTickMeasurement(order: $0,
                        ticks: geometry.tickSpan(at: $0)!, rawCentimeters: $0 == count / 2 ? 100 : 500)! }, geometry: geometry)
            }
            c.runtime.frame(frame(1, time: 8)); flush(c.runtime)
            XCTAssertEqual(midi.sounding.count, 3); XCTAssertEqual(au.sounding.count, 3)
            XCTAssertEqual(c.runtime.diagnostics.overflowProfiles, 0, "Exactly two seconds is within budget")
            c.runtime.frame(frame(2, time: 7.999)); flush(c.runtime); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
            XCTAssertEqual(c.runtime.diagnostics.overflowProfiles, 1)
            XCTAssertEqual(c.runtime.inputBacklogStatus, .recovered)
            c.runtime.frame(frame(3, time: 10)); flush(c.runtime)
            XCTAssertEqual(midi.sounding.count, 3); XCTAssertEqual(au.sounding.count, 3)
            XCTAssertEqual(midi.duplicateOns, 0); XCTAssertEqual(au.duplicateOns, 0)
            c.runtime.stop(); flush(c.runtime)
        }
    }
    func testProfileAgingOnQReleasesLatchesBeforeFollowingFailureAndRecovers() throws {
        for count in [90, 361] {
            let midi = FakeBoundary(), au = FakeBoundary(), clock = FakeClock()
            let c = composition(clock: clock, midi: midi, au: au)
            c.runtime.install(try mixed()); c.runtime.sessionBegan(session)
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan",
                pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            let measurements = (0..<count).map { DeviceTickMeasurement(order: $0,
                ticks: geometry.tickSpan(at: $0)!, rawCentimeters: $0 == count / 2 ? 100 : 500)! }
            let entered = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
            midi.setHook { bytes in if bytes == [0x90, 60, 100] {
                entered.signal(); _ = gate.wait(timeout: .now() + 10)
            } }
            defer { gate.signal() }
            c.runtime.frame(.init(sessionID: session, sequence: 1, time: 10, measurements: measurements, geometry: geometry))
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            midi.setHook(nil)
            c.runtime.frame(.init(sessionID: session, sequence: 2, time: 10, measurements: measurements, geometry: geometry))
            c.runtime.sessionEnded(session, reason: .failure)
            clock.advance(12.001)
            gate.signal(); flush(c.runtime); flush(c.runtime)
            XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
            XCTAssertEqual(c.runtime.diagnostics.overflowProfiles, 1)
            XCTAssertEqual(c.runtime.diagnostics.processedProfiles, 1)
            c.runtime.sessionBegan(other)
            c.runtime.frame(.init(sessionID: other, sequence: 3, time: clock.now, measurements: measurements, geometry: geometry))
            flush(c.runtime)
            XCTAssertEqual(midi.sounding.count, 3); XCTAssertEqual(au.sounding.count, 3)
            c.runtime.stop(); flush(c.runtime)
        }
    }
    func testCompleteReleaseMatrixThroughMIDIFakeAndAUFakeAt90And361() throws {
        for snap: UInt16 in [0, 5] { for count in [90, 361] { for path in 0..<11 {
            let midi = FakeBoundary(), au = FakeBoundary(), clock = FakeClock(), source = FakeProfileSource()
            let c = composition(clock: clock, midi: midi, au: au, source: source)
            c.runtime.install(try mixed(snap: snap)); source.deliver(.began(session))
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "MMK" : "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            source.deliver(.frame(.init(sessionID: session, sequence: 1, time: 10,
                measurements: (0..<count).map { DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: $0 == count / 2 ? 100 : 500)! }, geometry: geometry)))
            flush(c.runtime)
            XCTAssertEqual(midi.sounding.count, 3); XCTAssertEqual(au.sounding.count, 3)
            switch path {
            case 0: clock.advance(20); flush(c.runtime)
            case 1: source.deliver(.ended(session, reason: .failure))
            case 2: c.runtime.panic()
            case 3: c.runtime.stop()
            case 4: c.runtime.sleep()
            case 5: c.runtime.wake()
            case 6: c.runtime.terminate(ack: {})
            case 7: source.deliver(.ended(session, reason: .userRequested))
            case 8: source.deliver(.began(other))
            case 9: c.runtime.install(try mixed(revision: .newSession(), snap: snap))
            case 10:
                // Explicit instrument replacement through the same complete document boundary.
                var channel = InstrumentChannel()
                channel.instrument = .init(identity: .init(componentType: 1, componentSubType: 2, componentManufacturer: 3))
                let instrument = try mixed(snap: snap)
                let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: instrument.layers.map { layer in
                    .init(id: layer.id, name: "Changed", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                        cells: Set(layer.cells), routings: layer.routings.map { .init(id: $0.id, target: $0.target, program: $0.program) }, cellOverrides: [:]) }, selectedLayerID: session)
                c.runtime.install(try InstrumentCompiler.compile(.init(spatial: spatial, detection: instrument.detection, channel: channel, revision: .init(session: session, counter: 2))))
            default: XCTFail("Uncovered matrix path")
            }
            flush(c.runtime)
            XCTAssertEqual(midi.sounding.count, path < 2 ? 2 : path == 10 ? 3 : 0, "MIDI is independent of AU replacement: path \(path), \(count)")
            XCTAssertEqual(au.sounding.count, path < 2 ? 2 : 0, "AU path \(path), \(count)")
            XCTAssertEqual(midi.duplicateOns, 0); XCTAssertEqual(au.duplicateOns, 0)
            c.runtime.stop(); flush(c.runtime)
        } } }
    }
    func testFailureRecoveryToggleOffAndUserDisconnectAfterFailureThroughSource() throws {
        let midi = FakeBoundary(), au = FakeBoundary(), source = FakeProfileSource()
        let c = composition(midi: midi, au: au, source: source)
        c.runtime.install(try mixed(.toggle, guardSeconds: 0)); source.deliver(.began(session)); source.deliver(.frame(profile()))
        flush(c.runtime)
        source.deliver(.ended(session, reason: .failure)); flush(c.runtime)
        XCTAssertEqual(midi.sounding.count, 1); XCTAssertEqual(au.sounding.count, 1)
        source.deliver(.began(other)); source.deliver(.frame(profile(2, session: other)))
        flush(c.runtime)
        XCTAssertEqual(midi.sounding.count, 1); XCTAssertEqual(au.sounding.count, 1)
        source.deliver(.frame(profile(3, session: other, empty: true)))
        source.deliver(.frame(profile(4, session: other))); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
        source.deliver(.frame(profile(5, session: other, empty: true)))
        source.deliver(.frame(profile(6, session: other)))
        source.deliver(.ended(other, reason: .failure)); flush(c.runtime)
        XCTAssertEqual(midi.sounding.count, 1)
        source.deliver(.ended(other, reason: .userRequested)); flush(c.runtime)
        XCTAssertTrue(midi.sounding.isEmpty); XCTAssertTrue(au.sounding.isEmpty)
        XCTAssertEqual(midi.duplicateOns, 0); XCTAssertEqual(au.duplicateOns, 0)
    }
}

extension HaltenToggleRuntimeTests {
    func testHeldCellReceiptsSurviveMeasuredExitAndLossButClearOnExplicitRelease() throws {
        for transition in [SpatialNoteTransition.holdUntilNext, .toggle, .legato] {
            let c = composition()
            c.runtime.install(try mixed(transition, guardSeconds: 0)); c.runtime.sessionBegan(session)
            c.runtime.frame(.init(sessionID: session, sequence: 1, time: 10,
                measurements: [DeviceTickMeasurement(order: 0, ticks: .point(180)!, rawCentimeters: 100)!]))
            flush(c.runtime)
            XCTAssertFalse(c.mailbox.read()!.activeCells.isEmpty)
            c.runtime.frame(.init(sessionID: session, sequence: 2, time: 10.04, measurements: []))
            flush(c.runtime)
            XCTAssertTrue(c.mailbox.read()!.activeCells.isEmpty)
            XCTAssertEqual(c.mailbox.read()!.heldCells.isEmpty, transition == .legato)
            c.runtime.sessionEnded(session, reason: .failure); flush(c.runtime)
            XCTAssertEqual(c.mailbox.read()!.heldCells.isEmpty, transition == .legato)
            c.runtime.panic(); flush(c.runtime)
            XCTAssertTrue(c.mailbox.read()!.heldCells.isEmpty)
            c.runtime.stop(); flush(c.runtime)
            XCTAssertTrue(c.mailbox.read()!.heldCells.isEmpty)
        }
    }
}

extension HaltenToggleRuntimeTests {
    func testHeldCellsFollowNextTriggerToggleOffAndPresetReplacement() throws {
        for transition in [SpatialNoteTransition.holdUntilNext, .toggle] {
            let c = composition(), route = UUID()
            let a = PolarDeviceLattice(ring: 100, sector: 180)!, b = PolarDeviceLattice(ring: 200, sector: 180)!
            let layer = SpatialDocumentLayer(id: session, name: "Held cells", color: .orange,
                isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [a, b],
                routings: [.init(id: route, target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: transition))],
                cellOverrides: [b: [.init(target: .midiNote(channel: 0), value: .note(number: 64, velocity: 100))]], toggleGuardSeconds: 0)
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: session)
            let document = InstrumentDocument(spatial: spatial, detection: .allStagesOff, revision: .newSession())
            c.runtime.install(try InstrumentCompiler.compile(document)); c.runtime.sessionBegan(session)
            var sequence: UInt64 = 0
            func deliver(_ raw: UInt16?) {
                sequence += 1
                c.runtime.frame(.init(sessionID: session, sequence: sequence, time: 10 + Double(sequence) / 25,
                    measurements: raw.map { [DeviceTickMeasurement(order: 180, ticks: .point(180)!, rawCentimeters: $0)!] } ?? []))
                flush(c.runtime)
            }
            deliver(100); deliver(nil)
            XCTAssertEqual(Set(c.mailbox.read()!.heldCells.map(\.cell)), [a])
            deliver(200)
            XCTAssertEqual(Set(c.mailbox.read()!.heldCells.map(\.cell)), transition == .toggle ? [a, b] : [b])
            if transition == .toggle { deliver(nil); deliver(100); XCTAssertEqual(Set(c.mailbox.read()!.heldCells.map(\.cell)), [b]) }
            var replacement = document; replacement.revision = .newSession()
            c.runtime.install(try InstrumentCompiler.compile(replacement)); flush(c.runtime)
            XCTAssertTrue(c.mailbox.read()!.heldCells.isEmpty)
            c.runtime.stop(); flush(c.runtime)
        }
    }
}


extension HaltenToggleRuntimeTests {
    func testSceneAuditionFirstClickRecoveryImmediateAndWrap() throws {
        for action in [SpatialSceneSwitchAction.next, .previous] {
            for initial in 0..<5 { for duration in [0.1, 0.25] {
                let clock = FakeClock(), c = composition(clock: clock)
                let layer = SpatialDocumentLayer(id: UUID(), name: "Scene control", color: .blue,
                    isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                    cells: [PolarDeviceLattice(ring: 100, sector: 180)!],
                    routings: [.init(target: .sceneSwitch(action: action, dwellSeconds: 0.2), program: .constant(1))], cellOverrides: [:])
                let scenes = (0..<3).map { SpatialScene(name: "Scene \($0)", activeLayerIDs: [layer.id]) }
                let original: UUID? = initial < 3 ? scenes[initial].id : initial == 3 ? nil : UUID()
                let doc = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id),
                    detection: .allStagesOff, revision: .newSession(), scenes: scenes, currentSceneID: original)
                c.runtime.install(try InstrumentCompiler.compile(doc)); flush(c.runtime)
                XCTAssertEqual(c.mailbox.read()?.scene?.currentSceneID, doc.currentSceneID)
                let base = initial < 3 ? initial : 0
                let expected = (base + (action == .next ? 1 : 2)) % scenes.count
                c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime)
                XCTAssertEqual(c.mailbox.read()?.scene?.currentSceneID, scenes[expected].id)
                // Drag events already queued before Main has ended the gesture
                // must not count as another entry.
                for _ in 0..<3 {
                    c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime)
                    XCTAssertEqual(c.mailbox.read()?.scene?.currentSceneID, scenes[expected].id)
                }
                clock.advance(10 + duration); flush(c.runtime); flush(c.runtime)
                XCTAssertEqual(c.mailbox.read()?.scene?.currentSceneID, scenes[expected].id)
                c.runtime.audition(nil); flush(c.runtime)
                XCTAssertEqual(c.mailbox.read()?.scene?.currentSceneID, scenes[expected].id)
                c.runtime.audition(.init(xMeters: 0, yMeters: 1)); flush(c.runtime)
                let next = (expected + (action == .next ? 1 : 2)) % scenes.count
                XCTAssertEqual(c.mailbox.read()?.scene?.currentSceneID, scenes[next].id, "Release rearms the next press")
                XCTAssertEqual(c.runtime.diagnostics.processedProfiles, 0)
                c.runtime.stop(); flush(c.runtime)
            } }
        }
    }
}
