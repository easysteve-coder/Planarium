import XCTest
import PlanariumDomain
@testable import PlanariumRuntime

private final class SampleBoundaryFake: AUScheduleBoundary, PlannedNoteBoundary, SampleNoteBoundary, @unchecked Sendable {
    struct Entry { let bytes: [UInt8]; let deadline: Double; let immediate: Bool }
    private let capacity: Int
    init(capacity: Int = .max) { self.capacity = capacity }
    private let lock = NSLock()
    private var values: [Entry] = [], directValues: [[UInt8]] = []
    private var invalidations = 0
    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return values }
    var direct: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return directValues }
    var canceled: Int { lock.lock(); defer { lock.unlock() }; return invalidations }
    let planningLead = 0.0
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { lock.lock(); defer { lock.unlock() }; directValues.append(bytes); return .sent }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
    func sendPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult { .faulted }
    func cancelPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult { .sent }
    func enqueueSampleNote(bytes: [UInt8], deadline: Double, immediate: Bool) -> PortSendResult {
        lock.lock(); defer { lock.unlock() }; guard values.count < capacity else { return .faulted }; values.append(.init(bytes: bytes, deadline: deadline, immediate: immediate)); return .sent
    }
    func invalidateSampleNotes() { lock.lock(); invalidations += 1; lock.unlock() }
}
final class ArpeggiatorTests: RuntimeTestCase {
    private func document(_ count: Int, transition: SpatialNoteTransition = .legato, effects: [InstrumentMIDIEffect]) throws -> InstrumentDocument {
        let geometry = ProfileGeometryIdentity(operatingMode: "test", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
        let cell = PolarDeviceLattice(ring: 100, sector: geometry.tickSpan(at: count / 2)!.lower)!
        let nextCell = PolarDeviceLattice(ring: 120, sector: cell.sector)!
        let layer = SpatialDocumentLayer(id: UUID(), name: "Arp", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [cell, nextCell], routings: [
            .init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), program: .singleNote(note: 60, velocity: 91, transition: transition)),
            .init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 91, transition: transition))], cellOverrides: [nextCell: [.init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), value: .note(number: 64, velocity: 91))]])
        var result = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id), detection: .allStagesOff, revision: .newSession())
        result.channel.midiEffects = effects
        return result
    }
    private func frame(_ count: Int, ring: UInt16 = 100, empty: Bool = false, sequence: UInt64 = 1, time: Double = 10) -> ProfileFrame {
        let geometry = ProfileGeometryIdentity(operatingMode: "test", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
        return .init(sessionID: session, sequence: sequence, time: time, measurements: (0..<count).map {
            DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: !empty && $0 == count / 2 ? ring : 500)!
        }, geometry: geometry)
    }
    func testAuditionDrivesExistingChordArpeggiatorAndStopsOnRelease90And361() throws {
        for count in [90, 361] {
            let clock = FakeClock(), au = SampleBoundaryFake(), host = HostMusicalClock()
            host.updateInternal(tempo: 120, at: 10)
            let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock, hostClock: host)
            var chord = ChordEffect(); chord.mode = .single
            let doc = try document(count, effects: [.init(chord: chord), .init(arpeggiator: .init())])
            runtime.attach(RuntimePorts.audioUnit(boundary: au)); runtime.install(try InstrumentCompiler.compile(doc))
            let tick = ProfileGeometryIdentity(operatingMode: "test", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90).tickSpan(at: count / 2)!.lower
            let angle = PolarDeviceLattice.bearingDegrees(forTick: tick) * .pi / 180
            runtime.audition(.init(xMeters: sin(angle), yMeters: cos(angle))); flush(runtime)
            XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.map { $0.bytes[1] }, [60])
            clock.advance(10.1); flush(runtime)
            XCTAssertGreaterThan(au.entries.filter { $0.bytes[0] == 0x90 }.count, 1)
            runtime.audition(nil); flush(runtime)
            let before = au.entries.count, canceled = au.canceled
            clock.advance(10.4); flush(runtime)
            XCTAssertEqual(au.entries.count, before); XCTAssertGreaterThan(canceled, 0)
            runtime.stop(); flush(runtime)
        }
    }

    func testProductionRuntimeSuppressesDirectInputsAndRunsChordBeforeAndAfterWithoutProfiles() throws {
        for count in [90, 361] {
            let clock = FakeClock(), au = SampleBoundaryFake(), midi = FakeBoundary(), host = HostMusicalClock()
            host.updateInternal(tempo: 120, at: 10)
            let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock, hostClock: host)
            var chord = ChordEffect(); chord.mode = .single
            let doc = try document(count, effects: [.init(chord: chord), .init(arpeggiator: .init()), .init(chord: chord)])
            runtime.attach(RuntimePorts.audioUnit(boundary: au)); runtime.attach(RuntimePorts.midi(boundary: midi))
            runtime.install(try InstrumentCompiler.compile(doc)); runtime.sessionBegan(session); runtime.frame(frame(count)); flush(runtime)
            XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.map { $0.bytes[1] }, [60, 64, 67])
            XCTAssertTrue(au.entries.first!.immediate)
            XCTAssertFalse(au.direct.contains { $0[0] == 0x90 })
            XCTAssertEqual(midi.receipts.filter { $0.bytes[0] == 0x90 }.map(\.bytes), [[0x90, 60, 91]])
            clock.advance(10.1); flush(runtime)
            XCTAssertEqual(Array(au.entries.filter { $0.bytes[0] == 0x90 }.suffix(3)).map { $0.bytes[1] }, [64, 68, 71])
            XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.last!.deadline, 10.125, accuracy: 1e-9)
            let before = au.entries.count, canceled = au.canceled
            runtime.frame(frame(count, empty: true, sequence: 2, time: 10.1)); flush(runtime)
            XCTAssertGreaterThan(au.canceled, canceled)
            clock.advance(10.3); flush(runtime)
            XCTAssertEqual(au.entries.count, before)
            runtime.stop(); flush(runtime)
        }
    }
    func testHoldToggleKeepProducerThroughHandExitAndInputLossButStopCancels() throws {
        for count in [90, 361] { for transition in [SpatialNoteTransition.holdUntilNext, .toggle] {
            let clock = FakeClock(), au = SampleBoundaryFake()
            let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock)
            runtime.attach(RuntimePorts.audioUnit(boundary: au))
            runtime.install(try InstrumentCompiler.compile(document(count, transition: transition, effects: [.init(arpeggiator: .init())])))
            runtime.sessionBegan(session); runtime.frame(frame(count)); flush(runtime)
            runtime.frame(frame(count, empty: true, sequence: 2)); runtime.sessionEnded(session, reason: .failure); flush(runtime)
            let before = au.entries.count
            clock.advance(10.1); flush(runtime)
            XCTAssertGreaterThan(au.entries.count, before)
            runtime.stop(); flush(runtime)
            let ended = au.entries.count
            clock.advance(10.3); flush(runtime)
            XCTAssertEqual(au.entries.count, ended)
        } }
    }
    func testRealAbortTransitionsInvalidateAndNeverRestartFromOldLedger() throws {
        for count in [90, 361] {
            for reason in ["panic", "stop", "sleep", "terminate", "preset", "chain", "bypass", "engine", "scene"] {
                let clock = FakeClock(), au = SampleBoundaryFake()
                let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock)
                var doc = try document(count, transition: .holdUntilNext, effects: [.init(arpeggiator: .init())])
                let sceneA = SpatialScene(name: "A", activeLayerIDs: Set(doc.spatial.layers.map(\.id)))
                let sceneB = SpatialScene(name: "B", activeLayerIDs: [])
                doc.scenes = [sceneA, sceneB]; doc.currentSceneID = sceneA.id
                runtime.attach(RuntimePorts.audioUnit(boundary: au))
                runtime.install(try InstrumentCompiler.compile(doc)); runtime.sessionBegan(session); runtime.frame(frame(count)); flush(runtime)
                XCTAssertFalse(au.entries.isEmpty, reason)
                let before = au.entries.count, canceled = au.canceled
                switch reason {
                case "panic": runtime.panic()
                case "stop": runtime.stop()
                case "sleep": runtime.sleep()
                case "terminate": runtime.terminate {}
                case "engine": runtime.releaseAudioForConfigurationChange()
                case "scene": runtime.selectScene(sceneB.id)
                default:
                    doc.revision = .newSession()
                    if reason == "bypass" { doc.channel.midiEffects[0].bypassed = true }
                    if reason == "chain" { doc.channel.midiEffects[0].arpeggiator.octaves = 2 }
                    runtime.install(try InstrumentCompiler.compile(doc))
                }
                flush(runtime)
                clock.advance(10.2); flush(runtime)
                XCTAssertGreaterThan(au.canceled, canceled, reason)
                XCTAssertEqual(au.entries.count, before, reason)
            }
        }
    }
    func testRingOverflowInvalidatesOwnerAndDoesNotRetryHeldInput() throws {
        let clock = FakeClock(), au = SampleBoundaryFake(capacity: 1)
        let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock)
        runtime.attach(RuntimePorts.audioUnit(boundary: au))
        runtime.install(try InstrumentCompiler.compile(document(361, transition: .holdUntilNext, effects: [.init(arpeggiator: .init())])))
        runtime.sessionBegan(session); runtime.frame(frame(361)); flush(runtime)
        let cancellations = au.canceled
        XCTAssertEqual(au.entries.count, 1)
        clock.advance(10.2); flush(runtime)
        runtime.frame(frame(361, sequence: 2, time: 10.2)); flush(runtime)
        XCTAssertEqual(au.entries.count, 1); XCTAssertEqual(au.canceled, cancellations)
        runtime.stop(); flush(runtime)
    }
    func testFullDeadlineClockReleasesProducerInsteadOfLosingWakeup() throws {
        let clock = FakeClock(), noteClock = NotePlanningClock(), au = SampleBoundaryFake()
        let queue = DispatchQueue(label: "arpeggio-clock-full")
        let jobs = (0..<16).compactMap { _ in noteClock.trySchedule(at: noteClock.now + 60, on: queue) {} }
        defer { jobs.forEach { $0.cancel() } }
        XCTAssertEqual(jobs.count, 16)
        let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: noteClock)
        runtime.attach(RuntimePorts.audioUnit(boundary: au))
        runtime.install(try InstrumentCompiler.compile(document(361, transition: .holdUntilNext, effects: [.init(arpeggiator: .init())])))
        runtime.sessionBegan(session); flush(runtime)
        let before = au.canceled
        runtime.frame(frame(361)); flush(runtime)
        XCTAssertGreaterThan(au.canceled, before)
        XCTAssertEqual(au.entries.count, 2)
        runtime.frame(frame(361, sequence: 2)); flush(runtime)
        XCTAssertEqual(au.entries.count, 2)
        runtime.stop(); flush(runtime)
    }
    func testNoBoundInstrumentDoesNotPollThePlanningClock() throws {
        let inputClock = FakeClock(), noteClock = FakeClock()
        let runtime = PerformanceRuntime(clock: inputClock, mailbox: .init(), noteClock: noteClock)
        runtime.install(try InstrumentCompiler.compile(document(361, effects: [.init(arpeggiator: .init())])))
        runtime.sessionBegan(session); runtime.frame(frame(361)); flush(runtime)
        XCTAssertTrue(noteClock.deadlines.isEmpty)
        runtime.stop(); flush(runtime)
    }
    func testInputChangesRandomAndPitchBounds() {
        var producer = ArpeggioProducer(), effect = ArpeggiatorEffect()
        effect.direction = .random; effect.octaves = 4
        producer.update([.init(channel: 0, note: .init(number: 120, velocity: 91))], at: 10, effect: effect, beat: 0, tempo: 120)
        for _ in 0..<20 { XCTAssertEqual(producer.step(effect: effect, tempo: 120)!.0.note.number, 120) }
        let next = producer.next
        producer.update([.init(channel: 0, note: .init(number: 60, velocity: 70))], at: 10.1, effect: effect, beat: 0, tempo: 120)
        XCTAssertEqual(producer.next, next)
        XCTAssertTrue([60, 72, 84, 96].contains(Int(producer.step(effect: effect, tempo: 120)!.0.note.number)))
    }
    func testNewHeldInputAfterSceneAbortCanStartANewGeneration() throws {
        let clock = FakeClock(), au = SampleBoundaryFake()
        let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock)
        var doc = try document(361, transition: .holdUntilNext, effects: [.init(arpeggiator: .init())])
        let layers = Set(doc.spatial.layers.map(\.id))
        let a = SpatialScene(name: "A", activeLayerIDs: layers), b = SpatialScene(name: "B", activeLayerIDs: layers)
        doc.scenes = [a, b]; doc.currentSceneID = a.id
        runtime.attach(RuntimePorts.audioUnit(boundary: au))
        runtime.install(try InstrumentCompiler.compile(doc)); runtime.sessionBegan(session); runtime.frame(frame(361)); flush(runtime)
        runtime.selectScene(b.id); flush(runtime)
        let stopped = au.entries.count
        clock.advance(10.1); flush(runtime)
        XCTAssertEqual(au.entries.count, stopped)
        runtime.frame(frame(361, ring: 120, sequence: 2, time: 10.1)); flush(runtime)
        XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.last?.bytes[1], 64)
        XCTAssertGreaterThan(au.entries.count, stopped)
        runtime.stop(); flush(runtime)
    }
    func testTempoOnlyDocumentInstallKeepsArpeggiatorRunning() throws {
        let clock = FakeClock(), host = HostMusicalClock(), au = SampleBoundaryFake()
        host.updateInternal(tempo: 120, at: 10)
        let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock, hostClock: host)
        var doc = try document(361, transition: .holdUntilNext, effects: [.init(arpeggiator: .init())])
        runtime.attach(RuntimePorts.audioUnit(boundary: au))
        runtime.install(try InstrumentCompiler.compile(doc)); runtime.sessionBegan(session); runtime.frame(frame(361)); flush(runtime)
        let cancellations = au.canceled
        doc.beatsPerMinute = 60
        doc.revision = .init(session: doc.revision.session, counter: doc.revision.counter + 1)
        host.updateInternal(tempo: 60, at: 10.05)
        clock.advance(10.05); runtime.install(try InstrumentCompiler.compile(doc)); flush(runtime)
        clock.advance(10.16); flush(runtime)
        XCTAssertEqual(au.canceled, cancellations)
        XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.last!.deadline, 10.2, accuracy: 1e-9)
        runtime.stop(); flush(runtime)
    }
    func testExternalTempoWakesLongLookaheadWithoutProfilesOrRuntimeCommands() throws {
        let clock = FakeClock(), host = HostMusicalClock(), au = SampleBoundaryFake()
        host.configure(.receive, documentTempo: 30, at: 10)
        host.updateExternal(tempo: 30, beat: 0, at: 10, playing: true)
        let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock, hostClock: host)
        var effect = ArpeggiatorEffect(); effect.rate = .quarter
        runtime.attach(RuntimePorts.audioUnit(boundary: au))
        runtime.install(try InstrumentCompiler.compile(document(361, transition: .holdUntilNext, effects: [.init(arpeggiator: effect)])))
        runtime.sessionBegan(session); runtime.frame(frame(361)); flush(runtime)
        runtime.sessionEnded(session, reason: .failure); flush(runtime)
        XCTAssertTrue(clock.deadlines.contains { abs($0 - 11.95) < 1e-8 })
        clock.advance(10.1)
        host.updateExternal(tempo: 300, beat: 0.05, at: 10.1, playing: true)
        let retimed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            clock.deadlines.contains { abs($0 - 10.24) < 1e-8 }
        }, object: nil)
        wait(for: [retimed], timeout: 3)
        clock.advance(10.25); flush(runtime)
        let played = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            au.entries.filter { $0.bytes[0] == 0x90 }.count == 2
        }, object: nil)
        wait(for: [played], timeout: 3)
        XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.last!.deadline, 10.29, accuracy: 1e-8)
        runtime.stop(); flush(runtime)
    }
    func testExternalTempoChangesOnlyUnwrittenStepsAndTransportStopKeepsLastTempo() throws {
        let clock = FakeClock(), host = HostMusicalClock(), au = SampleBoundaryFake()
        host.configure(.receive, documentTempo: 120, at: 10)
        host.updateExternal(tempo: 120, beat: 0, at: 10, playing: true)
        let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock, hostClock: host)
        runtime.attach(RuntimePorts.audioUnit(boundary: au))
        runtime.install(try InstrumentCompiler.compile(document(361, transition: .holdUntilNext, effects: [.init(arpeggiator: .init())])))
        runtime.sessionBegan(session); runtime.frame(frame(361)); flush(runtime)
        clock.advance(10.1); flush(runtime)
        XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.last!.deadline, 10.125, accuracy: 1e-9)
        host.updateExternal(tempo: 60, beat: 0.3, at: 10.15, playing: true)
        clock.advance(10.2); flush(runtime)
        clock.advance(10.31); flush(runtime)
        XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.last!.deadline, 10.35, accuracy: 1e-9)
        host.updateExternal(tempo: 60, beat: 0.51, at: 10.36, playing: false)
        clock.advance(10.56); flush(runtime)
        XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.last!.deadline, 10.6, accuracy: 1e-9)
        runtime.stop(); flush(runtime)
    }
    private func addControl(to doc: inout InstrumentDocument, target: SpatialRoutingTarget) throws {
        let original = doc.spatial.layers[0]
        let control = SpatialDocumentLayer(id: UUID(), name: "Hand", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: original.cells.filter { $0.ring == 120 }, routings: [.init(target: target,
                program: .continuous(minimum: 1, maximum: 1, directionDegrees: 0, curve: .linear))], cellOverrides: [:])
        doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: doc.spatial.layers + [control], selectedLayerID: original.id)
    }
    func testCompilerInstallClearsModulationForSceneBypassAndRemovedSurface() throws {
        for count in [90, 361] { for reason in ["scene", "bypass", "surface"] {
            let clock = FakeClock(), mailbox = DisplayFrameMailbox(), au = SampleBoundaryFake()
            let runtime = PerformanceRuntime(clock: clock, mailbox: mailbox, noteClock: clock)
            var doc = try document(count, transition: .holdUntilNext, effects: [.init(arpeggiator: .init())])
            let target = SpatialRoutingTarget.midiEffectParameter(stripID: doc.channel.id, slotID: doc.channel.midiEffects[0].id, parameter: .gate)
            try addControl(to: &doc, target: target)
            runtime.attach(RuntimePorts.audioUnit(boundary: au)); runtime.install(try InstrumentCompiler.compile(doc))
            runtime.sessionBegan(session); runtime.frame(frame(count, ring: 120)); flush(runtime)
            XCTAssertFalse(mailbox.read()!.arpeggiatorModulation.values.isEmpty)
            doc.revision = try doc.revision.advanced()
            if reason == "bypass" { doc.channel.midiEffects[0].bypassed = true }
            if reason == "surface" {
                let layer = doc.spatial.layers[0]
                doc.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
            }
            let compiled = try InstrumentCompiler.compile(doc)
            runtime.install(reason == "scene" ? compiled.stampingScene(generation: 1, replacing: true) : compiled); flush(runtime)
            XCTAssertTrue(mailbox.read()!.arpeggiatorModulation.values.isEmpty, reason)
            runtime.stop(); flush(runtime)
        } }
    }
    func testHandParametersAndPanicScenePresetResetThroughProductionAtBothGeometries() throws {
        for count in [90, 361] {
            for parameter in ArpeggiatorModulationTarget.allCases {
                let clock = FakeClock(), au = SampleBoundaryFake(), mailbox = DisplayFrameMailbox(), host = HostMusicalClock()
                host.updateInternal(tempo: 120, at: 10)
                let runtime = PerformanceRuntime(clock: clock, mailbox: mailbox, noteClock: clock, hostClock: host)
                var doc = try document(count, transition: .holdUntilNext, effects: [.init(arpeggiator: .init())])
                                let target = SpatialRoutingTarget.midiEffectParameter(stripID: doc.channel.id, slotID: doc.channel.midiEffects[0].id, parameter: parameter)
                try addControl(to: &doc, target: target)
                let scene = SpatialScene(name: "Same layers", activeLayerIDs: Set(doc.spatial.layers.map(\.id)))
                doc.scenes = [scene]
                runtime.attach(RuntimePorts.audioUnit(boundary: au)); runtime.install(try InstrumentCompiler.compile(doc))
                runtime.sessionBegan(session); runtime.frame(frame(count)); flush(runtime)
                let original = au.entries
                clock.advance(10.02); runtime.frame(frame(count, ring: 120, sequence: 2, time: 10.02)); flush(runtime)
                XCTAssertFalse(mailbox.read()!.arpeggiatorModulation.values.isEmpty)
                clock.advance(10.1); flush(runtime)
                XCTAssertEqual(Array(au.entries.prefix(original.count)).map(\.deadline), original.map(\.deadline))
                let effect = mailbox.read()!.arpeggiatorModulation.applying(to: .init(), stripID: doc.channel.id, slotID: doc.channel.midiEffects[0].id)
                let ons = au.entries.filter { $0.bytes[0] == 0x90 }, offs = au.entries.filter { $0.bytes[0] == 0x80 }
                switch parameter {
                case .velocity: XCTAssertEqual(ons.last!.bytes[2], 127)
                case .gate: XCTAssertEqual(offs.last!.deadline - ons.last!.deadline, 0.125, accuracy: 1e-9)
                case .swing: XCTAssertEqual(offs.last!.deadline - ons.last!.deadline, 0.125 * 0.25 * 0.5, accuracy: 1e-9)
                case .octaves:
                    XCTAssertEqual(effect.octaves, 4)
                    clock.advance(10.3); flush(runtime)
                    XCTAssertTrue(au.entries.contains { $0.bytes[0] == 0x90 && $0.bytes[1] >= 72 })
                case .rate: XCTAssertEqual(effect.rate, .thirtySecond)
                }
                runtime.selectScene(scene.id); flush(runtime)
                XCTAssertTrue(mailbox.read()!.arpeggiatorModulation.values.isEmpty)
                runtime.frame(frame(count, ring: 120, sequence: 3, time: 10.3)); flush(runtime)
                runtime.panic(); flush(runtime)
                XCTAssertTrue(mailbox.read()!.arpeggiatorModulation.values.isEmpty)
                runtime.frame(frame(count, empty: true, sequence: 4, time: 10.31)); flush(runtime)
                runtime.frame(frame(count, ring: 120, sequence: 5, time: 10.32)); flush(runtime)
                XCTAssertFalse(mailbox.read()!.arpeggiatorModulation.values.isEmpty)
                doc.revision = .newSession(); runtime.install(try InstrumentCompiler.compile(doc)); flush(runtime)
                XCTAssertTrue(mailbox.read()!.arpeggiatorModulation.values.isEmpty)
                runtime.stop(); flush(runtime)
            }
        }
    }
    func testHandRateChangesOnlyUnwrittenStepsAndExitRestoresEditorAt90And361() throws {
        for count in [90, 361] {
            let clock = FakeClock(), au = SampleBoundaryFake(), host = HostMusicalClock(), mailbox = DisplayFrameMailbox()
            host.updateInternal(tempo: 120, at: 10)
            let runtime = PerformanceRuntime(clock: clock, mailbox: mailbox, noteClock: clock, hostClock: host)
            var doc = try document(count, transition: .holdUntilNext, effects: [.init(arpeggiator: .init())])
                        let target = SpatialRoutingTarget.midiEffectParameter(stripID: doc.channel.id, slotID: doc.channel.midiEffects[0].id, parameter: .rate)
            try addControl(to: &doc, target: target)
            runtime.attach(RuntimePorts.audioUnit(boundary: au)); runtime.install(try InstrumentCompiler.compile(doc))
            runtime.sessionBegan(session); runtime.frame(frame(count)); flush(runtime)
            clock.advance(10.1); flush(runtime)
            let before = au.entries, canceled = au.canceled
            runtime.frame(frame(count, ring: 120, sequence: 2, time: 10.1)); flush(runtime)
            XCTAssertEqual(mailbox.read()?.arpeggiatorModulation.values[target], 5)
            XCTAssertEqual(au.canceled, canceled)
            XCTAssertEqual(Array(au.entries.prefix(before.count)).map(\.deadline), before.map(\.deadline))
            clock.advance(10.15); flush(runtime)
            XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.map(\.deadline), [10, 10.125, 10.1875])
            XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.map { Int((($0.deadline - 10) * 48_000).rounded()) }, [0, 6000, 9000])
            let planned = au.entries
            runtime.frame(frame(count, ring: 100, sequence: 3, time: 10.15)); flush(runtime)
            XCTAssertTrue(mailbox.read()!.arpeggiatorModulation.values.isEmpty)
            XCTAssertEqual(Array(au.entries.prefix(planned.count)).map(\.deadline), planned.map(\.deadline))
            clock.advance(10.27); flush(runtime)
            XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.last!.deadline, 10.3125, accuracy: 1e-9)
            XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.map(\.deadline), [10, 10.125, 10.1875, 10.3125])
            XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.map { Int((($0.deadline - 10) * 48_000).rounded()) }, [0, 6000, 9000, 15000])
            XCTAssertEqual(au.canceled, canceled)
            runtime.stop(); flush(runtime)
        }
    }
    func testHandRateChangesPendingSyncBeforeAnyStepWasWrittenAtBothGeometries() throws {
        for count in [90, 361] {
            let clock = FakeClock(), au = SampleBoundaryFake(), host = HostMusicalClock()
            host.updateInternal(tempo: 120, at: 10)
            let runtime = PerformanceRuntime(clock: clock, mailbox: .init(), noteClock: clock, hostClock: host)
            var effect = ArpeggiatorEffect(); effect.rate = .quarter; effect.syncToBeat = true
            var doc = try document(count, transition: .holdUntilNext, effects: [.init(arpeggiator: effect)])
            let target = SpatialRoutingTarget.midiEffectParameter(stripID: doc.channel.id, slotID: doc.channel.midiEffects[0].id, parameter: .rate)
            try addControl(to: &doc, target: target)
            runtime.attach(RuntimePorts.audioUnit(boundary: au)); runtime.install(try InstrumentCompiler.compile(doc))
            runtime.sessionBegan(session); runtime.frame(frame(count)); flush(runtime)
            XCTAssertTrue(au.entries.isEmpty)
            let canceled = au.canceled
            clock.advance(10.1); runtime.frame(frame(count, ring: 120, sequence: 2, time: 10.1)); flush(runtime)
            XCTAssertEqual(au.entries.filter { $0.bytes[0] == 0x90 }.map(\.deadline), [10.125])
            XCTAssertEqual(au.canceled, canceled)
            runtime.stop(); flush(runtime)
        }
    }
    func testSlowToFastChangeKeepsPhaseWithoutReplayingElapsedSteps() {
        var producer = ArpeggioProducer(), effect = ArpeggiatorEffect()
        effect.rate = .quarter
        producer.update([.init(channel: 0, note: .init(number: 60, velocity: 80))], at: 10, effect: effect, beat: 0, tempo: 120)
        _ = producer.step(effect: effect, tempo: 120)
        producer.modulateRate(.thirtySecond, tempo: 120, notBefore: 10.4)
        XCTAssertEqual(producer.next!, 10.4375, accuracy: 1e-9)
        XCTAssertEqual(producer.index, 1)
    }
    func testCursorDirectionsRatesOctavesVelocitySwingTempoAndSync() {
        let inputs: [ArpeggioProducer.Input] = [67, 60, 64].map { .init(channel: 0, note: .init(number: UInt8($0), velocity: 80)) }
        let expected: [ArpeggiatorEffect.Direction: [UInt8]] = [.up: [60,64,67,60], .down: [67,64,60,67], .upDown: [60,64,67,64], .asPlayed: [67,60,64,67]]
        for (direction, notes) in expected {
            var producer = ArpeggioProducer(), effect = ArpeggiatorEffect(); effect.direction = direction
            producer.update(inputs, at: 10, effect: effect, beat: 0, tempo: 120)
            XCTAssertEqual((0..<4).map { _ in producer.step(effect: effect, tempo: 120)!.0.note.number }, notes)
        }
        for rate in ArpeggiatorEffect.Rate.allCases {
            var producer = ArpeggioProducer(), effect = ArpeggiatorEffect(); effect.rate = rate; effect.syncToBeat = true
            producer.update(inputs, at: 10, effect: effect, beat: 0, tempo: 120)
            let first = producer.step(effect: effect, tempo: 120)!
            XCTAssertEqual(first.1, 10 + rate.beats / 2, accuracy: 1e-9); XCTAssertFalse(first.3)
        }
        var pending = ArpeggioProducer(), sync = ArpeggiatorEffect()
        sync.rate = .quarter; sync.syncToBeat = true
        pending.update(inputs, at: 10, effect: sync, beat: -0.1, tempo: 120)
        XCTAssertEqual(pending.step(effect: sync, tempo: 120)!.1, 10.05, accuracy: 1e-9)
        var producer = ArpeggioProducer(), effect = ArpeggiatorEffect()
        effect.octaves = 2; effect.velocity = 110; effect.swing = 50; effect.gate = 100
        producer.update([inputs[1]], at: 10, effect: effect, beat: 0, tempo: 120)
        let first = producer.step(effect: effect, tempo: 120)!, second = producer.step(effect: effect, tempo: 60)!
        XCTAssertEqual(first.0.note.velocity, 110); XCTAssertEqual(second.0.note.number, 72)
        XCTAssertEqual(first.2, 10.1875); XCTAssertEqual(second.1, 10.1875); XCTAssertEqual(second.2, 10.3125)
    }
}
