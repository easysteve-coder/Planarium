import XCTest
import Foundation
import Combine
@testable import PlanariumApplication
import PlanariumDomain
import PlanariumRuntime
import PlanariumInput
import PlanariumMIDI
import PlanariumAudio
import PlanariumPresets
import SickPLSCore
import SickPLSControlCore
import SickPLSMonitorKit
import SickPLSMacTransport

final class FakeSend: MIDISendBoundary, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[UInt8]] = []
    private var times: [Double] = []
    private var offGate: DispatchSemaphore?
    private var blocked = false
    func blockNextOff() -> DispatchSemaphore { lock.lock(); defer { lock.unlock() }; let gate = DispatchSemaphore(value: 0); offGate = gate; return gate }
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    func send(bytes: [UInt8]) -> PortSendResult {
        lock.lock()
        let gate = bytes.first == 0x80 ? offGate : nil
        if gate != nil { offGate = nil; blocked = true }
        lock.unlock()
        if let gate { _ = gate.wait(timeout: .now() + 5) }
        lock.lock(); defer { lock.unlock() }
        messages.append(bytes); times.append(Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
        return .sent
    }
    var sent: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return messages }
    var sendTimes: [Double] { lock.lock(); defer { lock.unlock() }; return times }
}
@MainActor final class FakeMIDI: MIDIConnectionBoundary {
    var onDestinationLost: (@MainActor () -> Void)?
    var onDestinationsChanged: (@MainActor () -> Void)?
    var reportedDestinations: [MIDITargetDescription] = [.init(id: 1, name: "One"), .init(id: 2, name: "Two")]
    var catalogStops = 0
    func stopObservingDestinations() { catalogStops += 1 }
    let sends: [FakeSend]
    var siblings: [FakeMIDI] = []
    init(sends: [FakeSend] = [FakeSend(), FakeSend(), FakeSend()]) { self.sends = sends }
    func makeIndependentConnection() -> (any MIDIConnectionBoundary)? {
        let sibling = FakeMIDI(sends: sends); siblings.append(sibling); return sibling
    }
    var opens: [Int32] = []
    var closes = 0
    var messagesAtClose: [[[UInt8]]] = []
    func destinations() -> [MIDITargetDescription] { reportedDestinations }
    func open(_ target: InstrumentMIDITarget) -> Result<any MIDISendBoundary, MIDIConnectionError> {
        opens.append(target.uniqueID); return .success(sends[target.uniqueID == 0 ? 2 : Int(target.uniqueID)-1])
    }
    func close() { closes += 1; if let id = opens.last { messagesAtClose.append(sends[id == 0 ? 2 : Int(id)-1].sent) } }
}
@MainActor final class FakeComponents: PluginComponentSource {
    var loads: [SpatialAudioUnitIdentity] = []
    func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        loads.append(identity); completion(.failure(.init("Synthetic component unavailable")))
    }
}
final class FakeDescriptor: SerialPortFileDescriptor, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [SerialPortReadOutcome] = []
    private var closeCount = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return closeCount }
    func append(_ value: SerialPortReadOutcome) { lock.lock(); script.append(value); lock.unlock() }
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        lock.lock(); let value = script.isEmpty ? SerialPortReadOutcome.timeout : script.removeFirst(); lock.unlock()
        if value == .timeout { Thread.sleep(forTimeInterval: 0.0002) }
        return value
    }
    func close() { lock.lock(); closeCount += 1; lock.unlock() }
}
final class FakeScanner: SerialPortOpener, @unchecked Sendable {
    private let lock = NSLock()
    let descriptors: [FakeDescriptor]
    private var index = 0
    init(_ descriptors: [FakeDescriptor] = [FakeDescriptor(), FakeDescriptor()]) { self.descriptors = descriptors }
    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> any SerialPortFileDescriptor {
        lock.lock(); defer { lock.unlock() }; let value = descriptors[index]; index += 1; return value
    }
}
/// Release-route tests freeze time so the independent stale watchdog cannot
/// hide a removed command. Benchmarks keep the real monotonic clock.
private struct FrozenClock: RuntimeClock {
    let now: Double = 0
    func schedule(at deadline: Double, on queue: DispatchQueue, _ fire: @escaping @Sendable () -> Void) -> RuntimeCancellation { RuntimeCancellation {} }
}
@MainActor struct RootFixture {
    let midi = FakeMIDI()
    let components = FakeComponents()
    let scanner = FakeScanner()
    let root: PlanariumComposition
    init(clock: any RuntimeClock = MonotonicRuntimeClock(), clockSinkFactory: @escaping MIDIClockSinkFactory = { _ in nil },
         clockSourceFactory: @escaping MIDIClockSourceFactory = { _, _, _ in nil },
         footswitchDefaults: UserDefaults? = nil,
         footswitchSourceFactory: @escaping MIDIClockSourceFactory = { _, _, _ in nil }, activityBoundary: (any PerformanceActivityBoundary)? = nil) throws {
        root = try PlanariumComposition(scanner: scanner, midi: midi, components: components, clock: clock,
            configuration: .init(offline: true), graph: CompositionGraph(), windows: CompositionWindows(), clockSinkFactory: clockSinkFactory, clockSourceFactory: clockSourceFactory, activityBoundary: activityBoundary, footswitchDefaults: footswitchDefaults, footswitchSourceFactory: footswitchSourceFactory)
    }
    func install(tick: Int = 180) throws {
        let layer = SpatialDocumentLayer(id: UUID(), name: "Note", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [PolarDeviceLattice(tick: tick, rawCentimeters: 100)!],
            routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [60], velocity: 100, transition: .retrigger))], cellOverrides: [:])
        try root.document.edit { doc in
            doc.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
            doc.detection = .allStagesOff; doc.midiTarget = .init(uniqueID: 1)
        }
    }
    func bytes(_ value: UInt16 = 100, pointCount: Int = 361) throws -> [UInt8] {
        var payload: [UInt8] = [0xb0, UInt8(pointCount & 255), UInt8(pointCount >> 8)]
        for i in 0..<pointCount { let value: UInt16 = i == (pointCount == 90 ? 45 : 180) ? value : 8191; payload += [UInt8(value & 255), UInt8(value >> 8)] }
        payload += [0]
        return try Frame.build(address: 0x81, payload: payload).encoded()
    }
}
@MainActor final class ProductionCompositionTests: XCTestCase {
    func testEditorCellOverridesAndLayerAssignmentReachInstalledRuntimeFor90And361() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()), owner = f.root.document
            defer { p8Finish(f) }
            try f.install(tick: 79)
            f.root.runtime.sessionBegan(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
            p8Ack(f)
            XCTAssertTrue(owner.canvas.perform(.selectAll))
            XCTAssertEqual(owner.canvas.selection.cells.count, 1)
            let probe = CanvasTimingProbe(); CanvasTimingProbe.current = probe
            defer { CanvasTimingProbe.current = nil }
            var sequence: UInt64 = 0
            func expectNote(_ note: UInt8?, _ context: String) {
                // Leave and re-enter through the real frame/selection/output
                // route so a retained old index cannot hide behind a held note.
                sequence += 1; p8Frame(f, count: count, sequence: sequence, distance: 150)
                let start = f.midi.sends[0].sent.count
                sequence += 1; p8Frame(f, count: count, sequence: sequence, distance: 100)
                let notes = Array(f.midi.sends[0].sent.dropFirst(start)).filter { $0.first == 0x90 }
                XCTAssertEqual(notes, note.map { [[0x90, $0, 100]] } ?? [], "\(count): \(context)")
                XCTAssertEqual(f.root.runtime.mailbox.read()?.revision, owner.document.revision, context)
            }
            expectNote(60, "initial layer value")
            for note in [67, 69] {
                guard case .success(.applied) = owner.canvas.applyToSelection(.setAction(.init(
                    target: .midiNote(channel: 0), value: .note(number: note, velocity: 100)))) else {
                    return XCTFail("Cell inspector bulk action must change the existing cell")
                }
                p8Ack(f)
                XCTAssertFalse(owner.document.spatial.layers[0].cellOverrides.isEmpty)
                expectNote(UInt8(note), "cell override \(note)")
            }
            guard case .success(.applied) = owner.canvas.applyToSelection(.removeOwnValues) else {
                return XCTFail("Remove cell override must apply")
            }
            p8Ack(f); expectNote(60, "removed override restores layer value")
            XCTAssertTrue(owner.canvas.setSelectedLayerTarget(.midiNote(channel: 0),
                program: .chord(notes: [72], velocity: 100, transition: .retrigger)))
            p8Ack(f); expectNote(72, "new layer assignment")
            owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.isActive = false } }
            p8Ack(f); expectNote(nil, "inactive layer")
            owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.isActive = true } }
            p8Ack(f); expectNote(72, "reactivated layer")
            XCTAssertEqual(probe.counts["runtime.compile", default: 0], 6)
        }
    }

    func testEditorMixerTempoAndMetadataRetainIndexAndHistory() throws {
        let f = try RootFixture(), owner = f.root.document
        defer { f.root.terminate {} }
        owner.canvas.updateWorkspace { workspace in
            workspace.updateSelectedLayer { layer in
                layer.polarCells = Set((8..<32).flatMap { ring in
                    (8..<24).map { PolarMetricGridCell(ring: ring, angularIndex: $0) }
                })
            }
        }
        let plan = owner.fieldPlan.identity, compiled = owner.compiledInstrument
        let depth = owner.historyDepth
        let probe = CanvasTimingProbe(); CanvasTimingProbe.current = probe
        defer { CanvasTimingProbe.current = nil }
        for step in 1...10 {
            var channel = owner.document.channel; channel.levelDecibels = -Double(step)
            owner.updateChannel(channel)
        }
        owner.setBeatsPerMinute(135)
        XCTAssertEqual(probe.counts["runtime.compile", default: 0], 0)
        XCTAssertEqual(probe.counts["plan.prepareLabels", default: 0], 0)
        XCTAssertEqual(owner.fieldPlan.identity, plan)
        XCTAssertTrue(owner.compiledInstrument == compiled, "Mixer/tempo must retain the entire installed snapshot")
        XCTAssertEqual(owner.historyDepth, depth + 11)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.beatsPerMinute, 120)
        XCTAssertTrue(owner.redo()); XCTAssertEqual(owner.document.beatsPerMinute, 135)
        XCTAssertEqual(owner.fieldPlan.identity, plan)
        XCTAssertEqual(probe.counts["runtime.compile", default: 0], 0)
        owner.canvas.renameSelectedLayer("Named layer")
        var channel = owner.document.channel; channel.name = "Named channel"; channel.color = .orange
        owner.updateChannel(channel)
        XCTAssertEqual(probe.counts["runtime.compile", default: 0], 0)
        XCTAssertEqual(owner.compiledInstrument.statistics, compiled.statistics)
        XCTAssertEqual(owner.compiledInstrument.revision, owner.document.revision)
        XCTAssertTrue(owner.undo()); XCTAssertTrue(owner.undo())
        XCTAssertTrue(owner.redo()); XCTAssertTrue(owner.redo())
        XCTAssertEqual(owner.document.channel.name, "Named channel")
        XCTAssertEqual(owner.canvas.workspace.selectedLayer.name, "Named layer")
        channel = owner.document.channel; channel.name = ""; owner.updateChannel(channel)
        XCTAssertEqual(owner.canvas.workspace.channelName, "", "Projection must preserve raw metadata without the authoring setter's fallback")
        owner.canvas.renameSelectedLayer("Again")
        XCTAssertEqual(owner.document.channel.name, "", "A canvas edit must not overwrite the document's channel metadata")
        XCTAssertTrue(owner.undo()); XCTAssertTrue(owner.undo())
        XCTAssertEqual(owner.document.channel.name, "Named channel")
        let levelBeforeRename = owner.document.channel.levelDecibels
        owner.beginContinuousEdit()
        channel = owner.document.channel; channel.levelDecibels = -20; owner.updateChannel(channel)
        channel.name = "Independent rename"; owner.updateChannel(channel)
        owner.endContinuousEdit()
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.channel.name, "Named channel")
        XCTAssertEqual(owner.document.channel.levelDecibels, -20, "Rename owns its Undo even during a mixer gesture")
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.channel.levelDecibels, levelBeforeRename)
        // A musical change must still compile and reach production Runtime.
        owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.isActive.toggle() } }
        XCTAssertEqual(probe.counts["runtime.compile", default: 0], 1)
        XCTAssertNotEqual(owner.compiledInstrument.revision, compiled.revision)
        let revision = owner.document.revision, invalidPlan = owner.fieldPlan.identity
        channel = owner.document.channel; channel.levelDecibels = .nan
        owner.updateChannel(channel)
        XCTAssertEqual(owner.document.revision, revision)
        XCTAssertEqual(owner.fieldPlan.identity, invalidPlan)
    }

    func testEditorDetectionCompilesOnceAndInvalidCandidateIsAtomic() throws {
        let f = try RootFixture(), owner = f.root.document
        defer { f.root.terminate {} }
        var configuration = owner.document.detection
        let probe = CanvasTimingProbe(); CanvasTimingProbe.current = probe
        defer { CanvasTimingProbe.current = nil }
        configuration.minimumAngleDegrees = 12
        owner.updateDetectionConfiguration(configuration)
        XCTAssertEqual(probe.counts["runtime.compile", default: 0], 1)
        XCTAssertEqual(owner.document.detection, configuration)
        let document = owner.document, plan = owner.fieldPlan.identity
        configuration.temporalSmoothing = .mean(window: 0)
        owner.updateDetectionConfiguration(configuration)
        XCTAssertEqual(owner.document, document)
        XCTAssertEqual(owner.fieldPlan.identity, plan)
        XCTAssertEqual(probe.counts["runtime.compile", default: 0], 1)
        XCTAssertTrue(owner.undo()); XCTAssertTrue(owner.redo())
        XCTAssertEqual(owner.document.detection, document.detection)
    }

    func testRetargetAUAndMIDIPreservesOwnValuesAndProgramThroughDocumentOwner() throws {
        let f = try RootFixture(clock: TempoManualClock(0)), owner = f.root.document
        defer { p8Finish(f) }
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!, strip = owner.document.channels[0].id
        for target: SpatialRoutingTarget in [.midiCC(channel: 8, controller: 11), .midiProgramChange(channel: 8),
                                             .midiPitchBend(channel: 8), .midiChannelPressure(channel: 8)] {
            let selection = SpatialProgramChange(program: 3, countsFromOne: false, bankMSB: 4, bankLSB: 5)
            let value: SpatialCellValue = target.isProgramChange ? .programChange(selection) : .scalar(0.25)
            let program: SpatialValueProgram = target.isProgramChange ? .programChange(selection) : .constant(0.75)
            let layer = SpatialDocumentLayer(id: UUID(), name: "Retarget", color: .blue, isVisible: true,
                isActive: true, isLocked: false, isSoloed: false, cells: [cell],
                routings: [.init(target: target, program: program)], cellOverrides: [cell: [.init(target: target, value: value)]])
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
            try owner.edit { $0.spatial = spatial }
            for destination: SpatialRoutingDestination in [.audioUnit, .midi] {
                let replacement = target.retargeted(to: destination, stripID: strip)
                XCTAssertTrue(owner.canvas.setSelectedLayerTarget(replacement, program: program))
                XCTAssertEqual(owner.outputChangeLossCount, 0)
                XCTAssertEqual(owner.document.spatial.layers[0].routings[0].program, program)
                XCTAssertEqual(owner.document.spatial.layers[0].cellOverrides[cell], [.init(target: replacement, value: value)])
            }
        }
    }

    func testProgramCountingPreferenceUsesUIDAndDoesNotRewriteExplicitPresetSelections() throws {
        let suite = "AU-MIDI-counting-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = PerformanceRuntime(clock: TempoManualClock(0), mailbox: .init())
        let transport = FakeMIDI(), restoredTransport = FakeMIDI()
        let owner = MIDIPortOwner(runtime: runtime, transport: transport, preferences: defaults)
        XCTAssertTrue(owner.programCountsFromOne(for: 1))
        owner.rememberProgramCounting(false, for: 1)
        XCTAssertFalse(owner.programCountsFromOne(for: 1)); XCTAssertTrue(owner.programCountsFromOne(for: 2))
        let restored = MIDIPortOwner(runtime: runtime, transport: restoredTransport, preferences: defaults)
        XCTAssertFalse(restored.programCountsFromOne(for: 1))
        let explicit = SpatialProgramChange(program: 3, countsFromOne: true)
        XCTAssertEqual(try JSONDecoder().decode(SpatialProgramChange.self, from: JSONEncoder().encode(explicit)), explicit)
        owner.shutdown {}; restored.shutdown {}; runtime.terminate(ack: {})
        XCTAssertNil(transport.onDestinationsChanged); XCTAssertNil(restoredTransport.onDestinationsChanged)
        XCTAssertEqual(transport.catalogStops, 1); XCTAssertEqual(restoredTransport.catalogStops, 1)
    }

    func testSelectedMIDIDestinationReceivesCCAndProgramAndCatalogUpdatesWithoutRedirect() throws {
        let f = try RootFixture(clock: TempoManualClock(0)), owner = f.root.document
        defer { p8Finish(f) }
        let id = UUID(), cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let layer = SpatialDocumentLayer(id: id, name: "H90", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: [cell], routings: [
                .init(target: .midiCC(channel: 8, controller: 11), program: .constant(1)),
                .init(target: .midiProgramChange(channel: 8), program: .programChange(.init(program: 2, countsFromOne: false, bankMSB: 3, bankLSB: 4)))
            ], cellOverrides: [:], midiTarget: .init(uniqueID: 2))
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
        try owner.edit {
            $0.spatial = spatial
            $0.detection = .allStagesOff; $0.midiTarget = .init(uniqueID: 1)
        }
        p8Ack(f)
        let session = UUID(); f.root.runtime.sessionBegan(session)
        f.root.runtime.frame(.init(sessionID: session, sequence: 1, time: 0,
            measurements: [.init(order: 180, ticks: .point(180)!, rawCentimeters: 100)!]))
        p8Ack(f)
        XCTAssertEqual(f.midi.sends[1].sent, [[0xB8, 11, 127], [0xB8, 0, 3], [0xB8, 32, 4], [0xC8, 2]])
        XCTAssertTrue(f.midi.sends[0].sent.isEmpty)
        f.midi.reportedDestinations = [.init(id: 1, name: "One"), .init(id: 3, name: "Bluetooth")]
        f.midi.onDestinationsChanged?()
        XCTAssertEqual(f.root.midi.destinations, f.midi.reportedDestinations)
        XCTAssertEqual(owner.document.spatial.layers[0].midiTarget?.uniqueID, 2)
        XCTAssertEqual(f.midi.siblings.first?.opens, [2], "Catalog refresh must not reroute an unavailable stored target")
    }

    func testProgramChangePerformLockLayerTargetsAndProductionReleaseMatrix() throws {
        let f = try RootFixture(clock: TempoManualClock(0)), owner = f.root.document
        defer { p8Finish(f) }
        let cell = PolarDeviceLattice(ring: 100, sector: 180)!, id = UUID()
        let route = SpatialRouting(target: .midiProgramChange(channel: 15), program: .programChange(.init(program: 4, bankMSB: 2)))
        let layer = SpatialDocumentLayer(id: id, name: "Effect", color: .blue, isVisible: true, isActive: true, isLocked: false,
            isSoloed: false, cells: [cell], routings: [route], cellOverrides: [:], midiTarget: .init(uniqueID: 2))
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
        try owner.edit(name: "Program setup") {
            $0.spatial = spatial
            $0.detection = .allStagesOff; $0.midiTarget = .init(uniqueID: 1)
        }
        p8Ack(f)
        XCTAssertEqual(f.midi.opens, [1]); XCTAssertEqual(f.midi.siblings.count, 1)
        XCTAssertEqual(f.midi.siblings.first?.opens, [2])
        owner.canvas.setPerformanceLocked(true)
        let before = owner.document
        for mutation in ["assignment", "number", "bank", "counting", "target", "channel"] {
            owner.canvas.updateWorkspace { workspace in
                workspace.updateSelectedLayer { layer in
                    switch mutation {
                    case "assignment": layer.routings[0].program = .constant(0.5)
                    case "number": layer.routings[0].program = .programChange(.init(program: 5))
                    case "bank": layer.routings[0].program = .programChange(.init(program: 4, bankLSB: 7))
                    case "counting": layer.routings[0].program = .programChange(.init(program: 4, countsFromOne: false))
                    case "target": layer.midiTarget = .init(uniqueID: 1)
                    default: layer.setMIDIChannel(0)
                    }
                }
            }
            XCTAssertEqual(owner.document, before, mutation)
            XCTAssertEqual(owner.notice, InstrumentAction.performanceLockReason, mutation)
        }
        let session = UUID()
        f.root.runtime.sessionBegan(session)
        func frame(_ sequence: UInt64, empty: Bool = false) {
            f.root.runtime.frame(.init(sessionID: session, sequence: sequence, time: 0,
                measurements: empty ? [] : [DeviceTickMeasurement(order: 180, ticks: .point(180)!, rawCentimeters: 100)!]))
            p8Ack(f)
        }
        frame(1)
        XCTAssertEqual(f.midi.sends[1].sent, [[0xBF, 0, 2], [0xCF, 4]], "Sending remains allowed in Perform")
        XCTAssertTrue(f.midi.sends[0].sent.isEmpty)
        let sent = f.midi.sends[1].sent
        owner.panicAll(); p8Ack(f)
        XCTAssertTrue(f.midi.sends[1].sent.dropFirst(sent.count).allSatisfy { $0[1] == 123 })
        frame(2, empty: true); frame(3)
        XCTAssertEqual(f.midi.sends[1].sent.filter { $0[0] == 0xCF }.count, 2)
        owner.canvas.setPerformanceLocked(false)
        owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.midiTarget = .init(uniqueID: 1) } }
        p8Ack(f)
        frame(4)
        XCTAssertTrue(f.midi.sends[0].sent.contains([0xCF, 4]))
        XCTAssertGreaterThan(f.midi.siblings[0].closes, 0)
        XCTAssertEqual(owner.document.spatial.layers[0].midiTarget?.uniqueID, 1)
        let imported = try SpatialInstrumentRuntimeModel.compileWorkspace(owner.canvas.workspace)
        XCTAssertEqual(imported.layers[0].midiTarget?.uniqueID, 1, "The public coarse-workspace import also preserves the new target")
        XCTAssertEqual(imported.layers[0].routings[0].program, route.program)
        let programsBeforePreset = f.midi.sends[0].sent.filter { $0[0] == 0xCF }.count
        try owner.applyPresetDocument(owner.document)
        p8Ack(f); frame(5, empty: true); frame(6)
        XCTAssertEqual(f.midi.sends[0].sent.filter { $0[0] == 0xCF }.count, programsBeforePreset + 1,
                       "A real production preset replacement resets the remembered program even when its selection is identical")
    }
    private struct StageScene {
        let a: UUID, b: UUID, one: UUID, two: UUID
        let au: FakeAURelease
    }
    private func stageInstall(_ f: RootFixture, transition: SpatialNoteTransition = .legato) throws -> StageScene {
        let a = UUID(), b = UUID(), one = UUID(), two = UUID(), au = FakeAURelease()
        f.root.runtime.attach(RuntimePorts.audioUnit(id: UUID(), boundary: au))
        let targets: [SpatialRoutingTarget] = [.midiNote(channel: 0), .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)]
        let layers = [(a, 100, true, 60), (b, 120, false, 67)].map { id, ring, active, note in
            SpatialDocumentLayer(id: id, name: "Stage \(note)", color: .blue, isVisible: true, isActive: active, isLocked: false, isSoloed: false,
                cells: [PolarDeviceLattice(ring: ring, sector: ring == 120 ? 160 : 79)!],
                routings: targets.map { .init(target: $0, program: .chord(notes: [note], velocity: 100, transition: transition)) }, cellOverrides: [:])
        }
        try f.root.document.edit { document in
            document.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: a)
            document.detection = .allStagesOff; document.midiTarget = .init(uniqueID: 1)
            document.scenes = [.init(id: one, name: "One", activeLayerIDs: [a]), .init(id: two, name: "Two", activeLayerIDs: [b])]
            document.currentSceneID = one
        }
        f.root.runtime.sessionBegan(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
        p8Ack(f); wait { f.root.document.canvas.workspace.currentSceneID == one && f.midi.opens == [1] }
        return .init(a: a, b: b, one: one, two: two, au: au)
    }
    private func stageFrame(_ f: RootFixture, count: Int, sequence: UInt64, rings: [UInt16]) {
        let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "segmentMinimum" : "fullScan",
            pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
        f.root.runtime.frame(.init(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!, sequence: sequence,
            time: Double(sequence) * 0.01,
            measurements: rings.map { ring in
                let order = count == 90 ? (ring == 120 ? 40 : 20) : (ring == 120 ? 160 : 79)
                return DeviceTickMeasurement(order: order, ticks: geometry.tickSpan(at: order)!, rawCentimeters: ring)!
            }, geometry: geometry))
    }
    /// Intentionally hold Main: acknowledgements and scene mirroring cannot
    /// run while the real production queue advances and publishes its mailbox.
    private func stageAwaitQueue(_ f: RootFixture, _ predicate: (DisplayFrame) -> Bool,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let until = Date().addingTimeInterval(5)
        while !(f.root.runtime.mailbox.read().map(predicate) ?? false), Date() < until { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(f.root.runtime.mailbox.read().map(predicate) ?? false, file: file, line: line)
    }
    func testStageTempoInPerformKeepsSoundingNotesAndInstalledRevisionFor90And361() throws {
        for count in [90, 361] {
            let clock = TempoManualClock(0), f = try RootFixture(clock: clock)
            defer { p8Finish(f) }
            let scene = try stageInstall(f), owner = f.root.document
            stageFrame(f, count: count, sequence: 1, rings: [100]); p8Ack(f)
            let beforeMIDI = f.midi.sends[0].sent, beforeAU = scene.au.send.sent
            XCTAssertEqual(beforeMIDI, [[0x90, 60, 100]])
            XCTAssertEqual(beforeAU, beforeMIDI)
            let installedRevision = f.root.runtime.mailbox.read()?.revision
            XCTAssertNotNil(installedRevision)
            owner.canvas.setPerformanceLocked(true)
            owner.setBeatsPerMinute(133)
            stageFrame(f, count: count, sequence: 2, rings: [100]); p8Ack(f)
            XCTAssertEqual(owner.document.beatsPerMinute, 133)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.revision, installedRevision, "BPM must not reinstall the instrument")
            XCTAssertEqual(f.midi.sends[0].sent, beforeMIDI)
            XCTAssertEqual(scene.au.send.sent, beforeAU)
            owner.tapTempo(); clock.set(0.5); owner.tapTempo()
            stageFrame(f, count: count, sequence: 3, rings: [100]); p8Ack(f)
            XCTAssertEqual(owner.document.beatsPerMinute, 120)
            XCTAssertNil(owner.notice)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.revision, installedRevision, "Tap must not reinstall the instrument")
            XCTAssertNotEqual(owner.document.revision, installedRevision, "Tempo still records preset/history changes")
            XCTAssertEqual(f.midi.sends[0].sent, beforeMIDI, "No new Note-Off or Note-On")
            XCTAssertEqual(scene.au.send.sent, beforeAU, "No new AU Note-Off or Note-On")
            stageFrame(f, count: count, sequence: 4, rings: []); p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent.last, [0x80, 60, 0], "The measured exit still releases the held note")
            XCTAssertEqual(scene.au.send.sent.last, [0x80, 60, 0])
        }
    }

    func testStageMixerDoesNotInstallAndKeepsSceneNotesFor90And361() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            let scene = try stageInstall(f)
            stageFrame(f, count: count, sequence: 1, rings: [100, 120]); p8Ack(f)
            let beforeMIDI = f.midi.sends[0].sent, beforeAU = scene.au.send.sent
            XCTAssertEqual(beforeMIDI, [[0x90, 60, 100]]); XCTAssertEqual(beforeAU, beforeMIDI)
            f.root.document.selectScene(scene.two); p8Ack(f)
            wait { f.root.document.document.currentSceneID == scene.two }
            f.root.document.canvas.setPerformanceLocked(true)
            let installedRevision = f.root.runtime.mailbox.read()?.revision
            var channel = f.root.document.document.channel
            let changes: [(inout InstrumentChannel) -> Void] = [
                { $0.levelDecibels = -6 }, { $0.pan = 0.5 }, { $0.muted = true }, { $0.soloed = true }
            ]
            for (index, change) in changes.enumerated() {
                change(&channel); f.root.document.updateChannel(channel)
                stageFrame(f, count: count, sequence: UInt64(index + 2), rings: [100, 120]); p8Ack(f)
                XCTAssertEqual(f.root.runtime.mailbox.read()?.revision, installedRevision, "Mixer cannot install")
                XCTAssertEqual(f.midi.sends[0].sent, beforeMIDI)
                XCTAssertEqual(scene.au.send.sent, beforeAU)
            }
            f.root.document.updateMasterLevel(-9); p8Ack(f)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.revision, installedRevision)
            XCTAssertNotEqual(f.root.document.document.revision, installedRevision, "Mixer still records history/preset dirtiness")
            f.root.document.canvas.setPerformanceLocked(false)
            XCTAssertTrue(f.root.document.undo()); p8Ack(f)
            stageFrame(f, count: count, sequence: 6, rings: [100, 120]); p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent, beforeMIDI, "Undo install keeps the same musical state")
            XCTAssertEqual(scene.au.send.sent, beforeAU)
            try f.root.document.edit { $0.scenes[0].name = "Renamed scene" }; p8Ack(f)
            stageFrame(f, count: count, sequence: 7, rings: [100, 120]); p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent, beforeMIDI, "A scene name is not a musical change")
            XCTAssertEqual(scene.au.send.sent, beforeAU)
            stageFrame(f, count: count, sequence: 8, rings: []); p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent.last, [0x80, 60, 0])
            stageFrame(f, count: count, sequence: 9, rings: [120]); p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent.last, [0x90, 67, 100])
        }
    }
    func testStageStaleSceneInstallWithHeldMainDeliveryFor90And361() throws {
        for count in [90, 361] {
            for commitFirst in [false, true] {
                let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
                let scene = try stageInstall(f)
                stageFrame(f, count: count, sequence: 1, rings: [100, 120]); p8Ack(f)
                let oldGeneration = try XCTUnwrap(f.root.runtime.mailbox.read()?.scene?.generation)
                let sent = f.midi.sends[0].sent
                if commitFirst { try f.root.document.edit { $0.channelName = "Before switch" } }
                f.root.document.selectScene(scene.two)
                stageAwaitQueue(f) { $0.scene?.currentSceneID == scene.two }
                XCTAssertEqual(f.root.document.document.currentSceneID, scene.one, "Main has not received the new scene")
                if !commitFirst { try f.root.document.edit { $0.channelName = "After switch" } }
                let revision = f.root.document.document.revision
                stageAwaitQueue(f) { $0.revision == revision && $0.scene?.currentSceneID == scene.two }
                XCTAssertGreaterThan(try XCTUnwrap(f.root.runtime.mailbox.read()?.scene?.generation), oldGeneration)
                stageFrame(f, count: count, sequence: 2, rings: [100, 120])
                stageAwaitQueue(f) { $0.processedProfiles == 2 }
                XCTAssertEqual(f.midi.sends[0].sent, sent, "Stale Install cannot revert the scene or reset its transition")
                XCTAssertEqual(scene.au.send.sent, sent)
                p8Ack(f); wait { f.root.document.document.currentSceneID == scene.two }
                XCTAssertEqual(f.root.document.canvas.workspace.currentSceneID, scene.two)
                XCTAssertEqual(Set(f.root.document.document.spatial.layers.filter(\.isActive).map(\.id)), [scene.b])
            }
        }
    }
    func testStageDeferredOldSceneCallbackCannotOverwritePresetWithSameSceneIDs() throws {
        let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
        let scene = try stageInstall(f)
        let deliver = try XCTUnwrap(f.root.runtime.onSceneChanged)
        let deferred = DeferredStageScenes()
        f.root.runtime.onSceneChanged = { deferred.append($0) }
        f.root.document.selectScene(scene.two); p8Ack(f)
        XCTAssertEqual(f.root.document.document.currentSceneID, scene.one)
        let old = try XCTUnwrap(deferred.snapshots.last)
        let preset = f.root.document.document
        try f.root.document.applyPresetDocument(preset); p8Ack(f)
        let latest = try XCTUnwrap(deferred.snapshots.last)
        XCTAssertGreaterThan(latest.generation, old.generation)
        deliver(old); p8Ack(f)
        XCTAssertEqual(f.root.document.document.currentSceneID, scene.one, "Revision rejects old callback before preset acknowledgement")
        deliver(latest); p8Ack(f)
        deliver(old); p8Ack(f)
        XCTAssertEqual(f.root.document.document.currentSceneID, scene.one)
        XCTAssertEqual(f.root.document.canvas.workspace.currentSceneID, scene.one)
        f.root.runtime.onSceneChanged = deliver
        f.root.document.selectScene(scene.two); p8Ack(f)
        wait { f.root.document.document.currentSceneID == scene.two }
    }
    func testStageConsecutiveAuthoredSceneInstallsWinWhileMainDeliveryIsHeld() throws {
        let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
        let scene = try stageInstall(f)
        func authored(_ id: UUID, active: UUID) throws {
            try f.root.document.edit { document in
                let layers = document.spatial.layers.map { layer in
                    SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color, isVisible: layer.isVisible,
                        isActive: layer.id == active, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
                        cells: layer.cells, routings: layer.routings, cellOverrides: layer.cellOverrides)
                }
                document.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: scene.a)
                document.currentSceneID = id
            }
        }
        try authored(scene.two, active: scene.b)
        stageAwaitQueue(f) { $0.scene?.currentSceneID == scene.two }
        try authored(scene.one, active: scene.a)
        stageAwaitQueue(f) { $0.scene?.currentSceneID == scene.one && $0.revision == f.root.document.document.revision }
        p8Ack(f)
        XCTAssertEqual(f.root.document.document.currentSceneID, scene.one)
        XCTAssertEqual(Set(f.root.document.document.spatial.layers.filter(\.isActive).map(\.id)), [scene.a])
    }
    func testStageAuthoringAcknowledgementKeepsRawActivityAndSoloBits() throws {
        let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
        let scene = try stageInstall(f)
        try f.root.document.edit { document in
            let layers = document.spatial.layers.map { layer in
                SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color, isVisible: layer.isVisible,
                    isActive: true, isLocked: layer.isLocked, isSoloed: layer.id == scene.a,
                    cells: layer.cells, routings: layer.routings, cellOverrides: layer.cellOverrides)
            }
            document.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: scene.a)
        }
        let authored = f.root.document.document.spatial
        p8Ack(f); p8Ack(f)
        XCTAssertEqual(f.root.document.document.spatial, authored, "Audible set is not raw activity; B stays active under A's Solo")
        XCTAssertEqual(f.root.runtime.mailbox.read()?.scene?.activeLayerIDs, [scene.a, scene.b])
        try f.root.document.edit { $0.channelName = "Metadata" }; p8Ack(f)
        XCTAssertEqual(f.root.runtime.mailbox.read()?.scene?.activeLayerIDs, [scene.a, scene.b])
        XCTAssertEqual(f.root.document.document.spatial, authored)
        f.root.document.selectScene(scene.one); p8Ack(f)
        wait { f.root.document.document.spatial.layers.first(where: { $0.id == scene.b })?.isActive == false }
    }
    func testStageReleaseMatrixAfterMixerAndSceneFor90And361() throws {
        for count in [90, 361] {
            for mode in [SpatialNoteTransition.legato, .holdUntilNext, .toggle, .overlap(milliseconds: 100)] {
                for edge in 0..<9 {
                    let f = try RootFixture(clock: FrozenClock())
                    let scene = try stageInstall(f, transition: mode)
                    stageFrame(f, count: count, sequence: 1, rings: [100]); p8Ack(f)
                    f.root.document.selectScene(scene.two); p8Ack(f)
                    wait { f.root.document.document.currentSceneID == scene.two }
                    var channel = f.root.document.document.channel; channel.pan = 0.25
                    f.root.document.updateChannel(channel); p8Ack(f)
                    XCTAssertEqual(f.midi.sends[0].sent, [[0x90, 60, 100]])
                    XCTAssertEqual(scene.au.send.sent, [[0x90, 60, 100]])
                    switch edge {
                    case 0: f.root.panic()
                    case 1: f.root.document.stopSpatialMode()
                    case 2: f.root.runtime.sessionEnded(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
                    case 3: f.root.runtime.sessionBegan(UUID())
                    case 4: try f.root.document.applyPresetDocument(f.root.document.document)
                    case 5: f.root.sleep()
                    case 6: f.root.runtime.wake()
                    case 7: p8Finish(f)
                    case 8:
                        f.root.runtime.sessionEnded(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!, reason: .failure)
                        p8Ack(f)
                        let held = mode == .holdUntilNext || mode == .toggle
                        XCTAssertEqual(f.midi.sends[0].sent.contains([0x80,60,0]), !held)
                        XCTAssertEqual(scene.au.send.sent.contains([0x80,60,0]), !held)
                        f.root.runtime.sessionBegan(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
                        p8Ack(f)
                        XCTAssertEqual(f.midi.sends[0].sent.contains([0x80,60,0]), !held, "Recovery keeps conscious holds")
                        XCTAssertEqual(scene.au.send.sent.contains([0x80,60,0]), !held)
                        f.root.stop()
                    default: XCTFail("Missing release edge")
                    }
                    p8Ack(f)
                    XCTAssertTrue(f.midi.sends[0].sent.contains([0x80, 60, 0]), "MIDI: \(count), \(mode), edge \(edge)")
                    XCTAssertTrue(scene.au.send.sent.contains([0x80, 60, 0]), "AU: \(count), \(mode), edge \(edge)")
                    XCTAssertTrue(f.root.runtime.mailbox.read()?.ports.allSatisfy { $0.soundingNotes == 0 } == true)
                    if edge != 7 { p8Finish(f) }
                }
            }
        }
    }
    func testGlobalMIDITargetSurvivesMixerReorderAndDeleteWithoutReopening() throws {
        let f = try RootFixture(clock: FrozenClock()); try f.install(); p8Ack(f)
        wait { f.midi.opens == [1] }
        f.root.document.selectMIDITarget(.init(uniqueID: 2)); wait { f.midi.opens == [1, 2] }
        try f.root.document.addChannel()
        try f.root.document.edit { $0.channels.reverse() }
        try f.root.document.deleteChannel(InstrumentChannel.legacyID)
        p8Ack(f)
        XCTAssertEqual(f.root.document.document.midiTarget, .init(uniqueID: 2))
        XCTAssertEqual(f.midi.opens, [1, 2]); XCTAssertEqual(f.midi.closes, 1)
        p8Finish(f)
    }
    func testZeroMixerSurvivesLayerEditExportImportUndoRedo() throws {
        let f = try RootFixture(clock: FrozenClock()), owner = f.root.document
        defer { p8Finish(f) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let presets = PresetControlModel(store: .init(directory: directory), documentOwner: owner)
        try owner.deleteChannel(InstrumentChannel.legacyID)
        owner.canvas.updateWorkspace { $0.updateSelectedLayer { $0.name = "Empty mixer layer" } }
        XCTAssertTrue(owner.document.channels.isEmpty)
        XCTAssertTrue(try owner.snapshotPresetDocument().channels.isEmpty)
        XCTAssertTrue(owner.undo()); XCTAssertTrue(owner.document.channels.isEmpty)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.channels.count, 1)
        XCTAssertTrue(owner.redo()); XCTAssertTrue(owner.document.channels.isEmpty)
        XCTAssertTrue(owner.redo()); XCTAssertTrue(owner.document.channels.isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("empty.json")
        presets.draftName = "Empty Mixer"; presets.export(to: file)
        let reading = try PresetDocumentReader.read(Data(contentsOf: file)).get()
        XCTAssertTrue(try reading.replacing(owner.document).channels.isEmpty)
        presets.importFiles([file]); XCTAssertEqual(presets.notice, "Imported: empty")
        presets.load("empty", decision: .discard)
        XCTAssertTrue(owner.document.channels.isEmpty)
    }
    func testCompositionActivityFollowsAudioAndScannerAndTermination() throws {
        let activity = CompositionActivityFake()
        let f = try RootFixture(activityBoundary: activity)
        try f.root.audio.start(); XCTAssertEqual(activity.begins, 1)
        try f.root.audio.start(); XCTAssertEqual(activity.begins, 1)
        _ = f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
        f.root.audio.stop(); XCTAssertEqual(activity.ends, 0)
        f.root.input.disconnect(); wait { f.root.input.portOwner == .free }
        XCTAssertEqual(activity.ends, 1)
        try f.root.audio.start(); XCTAssertEqual(activity.begins, 2)
        p8Finish(f); XCTAssertEqual(activity.ends, 2)
    }
    func testFootswitchReleasesActualRuntimeWhileMainIsBlocked90And361() throws {
        for count in [90, 361] {
            let source = CompositionFootswitchSource()
            let defaults = UserDefaults(suiteName: "CompositionFootswitch-\(UUID())")!
            defaults.set(123, forKey: "panicFootswitch.source")
            defaults.set(try JSONEncoder().encode(PanicFootswitchTrigger(status: 0x90, number: 64, value: 100)!), forKey: "panicFootswitch.trigger")
            let f = try RootFixture(clock: FrozenClock(), footswitchDefaults: defaults, footswitchSourceFactory: { _, receive, _ in source.bind(receive); return source })
            defer { p8Finish(f) }
            try p8Install(f)
            f.root.document.canvas.select(tool: .audition)
            f.root.document.audition(.init(xMeters: 0, yMeters: 1))
            XCTAssertNotNil(f.root.document.auditionPoint)
            p8Frame(f, count: count, sequence: 1, distance: 100)
            let sink = f.midi.sends[0]
            XCTAssertTrue(sink.sent.contains([0x90, 60, 100]))
            let done = DispatchSemaphore(value: 0)
            DispatchQueue(label: "background fake pedal").async {
                source.press()
                let deadline = Date().addingTimeInterval(1)
                while Date() < deadline && !sink.sent.contains([0x80, 60, 0]) { Thread.sleep(forTimeInterval: 0.001) }
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
            XCTAssertTrue(sink.sent.contains([0x80, 60, 0]), "PANIC must arrive before Main unblocks")
            let before = sink.sent.filter { $0.first == 0x90 }.count
            p8Frame(f, count: count, sequence: 2, distance: 100)
            XCTAssertEqual(sink.sent.filter { $0.first == 0x90 }.count, before)
            wait { f.root.document.auditionPoint == nil }
        }
    }
    func testRestartPresetIsSilentUntilFreshMeasuredFrame90And361() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            try p8Install(f)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Restart-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PresetFileStore(directory: directory)
            let defaults = UserDefaults(suiteName: "Restart-\(UUID())")!
            let recovery = PresetRecoveryStore(url: directory.appendingPathComponent("recovery.json"))
            let presets = PresetControlModel(store: store, documentOwner: f.root.document, factoryPresets: .empty)
            presets.configureRecovery(defaults: defaults, store: recovery)
            presets.draftName = "Live"; XCTAssertTrue(presets.save())
            let next = try RootFixture(clock: FrozenClock()); defer { p8Finish(next) }
            let restarted = PresetControlModel(store: store, documentOwner: next.root.document, factoryPresets: .empty)
            restarted.configureRecovery(defaults: defaults, store: recovery); restarted.restoreStartup(); p8Ack(next)
            XCTAssertFalse(next.midi.sends[0].sent.contains { $0.first == 0x90 })
            next.root.runtime.sessionBegan(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!); p8Ack(next)
            XCTAssertFalse(next.midi.sends[0].sent.contains { $0.first == 0x90 })
            p8Frame(next, count: count, sequence: 1, distance: 100)
            XCTAssertTrue(next.midi.sends[0].sent.contains([0x90, 60, 100]))
        }
    }
    private func p8Ack(_ f: RootFixture) {
        let done = expectation(description: "Runtime acknowledged")
        f.root.runtime.acknowledge { done.fulfill() }; wait(for: [done], timeout: 5)
    }
    private func p8Frame(_ f: RootFixture, count: Int, sequence: UInt64, distance: UInt16, time: Double = 0) {
        let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "segmentMinimum" : "fullScan",
            pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
        let index = count == 90 ? 20 : 79
        f.root.runtime.frame(.init(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!, sequence: sequence, time: time,
            measurements: [DeviceTickMeasurement(order: index, ticks: geometry.tickSpan(at: index)!, rawCentimeters: distance)!], geometry: geometry))
        p8Ack(f)
    }
    private func p8Install(_ f: RootFixture, transition: SpatialNoteTransition = .legato,
                           smoothing: DetectionTemporalSmoothing = .off, secondDistance: Int = 103) throws {
        let first = PolarDeviceLattice(ring: 100, sector: 79)!, second = PolarDeviceLattice(ring: secondDistance, sector: 79)!
        let layer = SpatialDocumentLayer(id: UUID(), name: "P8", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: [first, second], routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [60], velocity: 100, transition: transition))],
            cellOverrides: [second: [.init(target: .midiNote(channel: 0), value: .note(number: 67, velocity: 100))]])
        try f.root.document.edit { doc in
            doc.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
            doc.detection = .init(temporalSmoothing: smoothing, groupingEnabled: false, representative: .nearestPoint)
            doc.midiTarget = .init(uniqueID: 1)
        }
        f.root.runtime.sessionBegan(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
        p8Ack(f)
    }
    private func p8Finish(_ f: RootFixture) { var done = false; f.root.terminate { done = true }; wait { done } }
    func testP8RevisionKeepsMeasuredSelectionHistoryAndOverlapFor90And361() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            try p8Install(f, transition: .overlap(milliseconds: 100), smoothing: .mean(window: 3))
            for (i, distance) in [UInt16(100), 100, 110].enumerated() { p8Frame(f, count: count, sequence: UInt64(i + 1), distance: distance) }
            XCTAssertEqual(f.root.runtime.mailbox.read()?.activeCells.first?.cell.ring, 103)
            let before = f.midi.sends[0].sent
            var channel = f.root.document.document.channel; channel.levelDecibels = -6
            f.root.document.updateChannel(channel); p8Ack(f)
            channel.pan = 0.5; f.root.document.updateChannel(channel); p8Ack(f)
            try f.root.document.edit { $0.channelName = "Renamed" }; p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent, before, "Revision cannot restart detection or drop overlap tails")
            XCTAssertEqual(f.root.runtime.mailbox.read()?.activeCells.first?.cell.ring, 103)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.activeCells.first?.revision, f.root.document.document.revision)
            p8Frame(f, count: count, sequence: 4, distance: 100, time: 0.11)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.activeCells.first?.cell.ring, 103, "Mean history survives install")
            XCTAssertEqual(f.midi.sends[0].sent.filter { $0 == [0x80, 60, 0] }.count, 1, "Original overlap deadline survives install")
            XCTAssertFalse(f.midi.sends[0].sent.contains([0x80, 67, 0]))

        }
    }
    func testP8HoldLeavesValidAreaAndNextNoteReplacesFor90And361() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            try p8Install(f, transition: .holdUntilNext)
            p8Frame(f, count: count, sequence: 1, distance: 100)
            let before = f.midi.sends[0].sent
            p8Frame(f, count: count, sequence: 2, distance: 150)
            XCTAssertEqual(f.midi.sends[0].sent, before)
            XCTAssertTrue(f.root.runtime.mailbox.read()?.activeCells.isEmpty == true)
            p8Frame(f, count: count, sequence: 3, distance: 103)
            XCTAssertEqual(Array(f.midi.sends[0].sent.suffix(2)), [[0x80, 60, 0], [0x90, 67, 100]])
            f.root.stop(); p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent.last, [0x80, 67, 0])
        }
    }

    private var p8bModes: [SpatialNoteTransition] {
        [.legato, .retrigger, .overlap(milliseconds: 100), .holdUntilNext]
    }
    private func p8bLayer(ring: Int, target: SpatialRoutingTarget, notes: [UInt8],
                         transition: SpatialNoteTransition, continuous: Bool = false,
                         nextCellNotes: [UInt8]? = nil) -> SpatialDocumentLayer {
        let overrides: [PolarDeviceLattice: [SpatialCellAction]] = nextCellNotes.map {
            [PolarDeviceLattice(ring: 120, sector: 79)!: [.init(target: target, value: .chord(notes: $0.map(Int.init), velocity: 100))]]
        } ?? [:]
        return .init(id: UUID(), name: "R2b", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: Set((continuous ? [100, 150, 120] : [ring]).map { PolarDeviceLattice(ring: $0, sector: 79)! }),
            routings: [.init(target: target, program: .chord(notes: notes.map(Int.init), velocity: 100, transition: transition))], cellOverrides: overrides)
    }
    private func p8bInstall(_ f: RootFixture, destination: SpatialOutputDestination, mode: SpatialNoteTransition,
                           reverse: Bool, firstNotes: [UInt8] = [60], nextNotes: [UInt8] = [67],
                           nextTarget: SpatialRoutingTarget? = nil, extra: [SpatialDocumentLayer] = [],
                           continuousNext: Bool = false, nextCellNotes: [UInt8]? = nil) throws -> FakeAURelease {
        let au = FakeAURelease()
        f.root.runtime.attach(RuntimePorts.audioUnit(id: UUID(), boundary: au))
        let target: SpatialRoutingTarget = destination == .midi ? .midiNote(channel: 0) : .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)
        let a = p8bLayer(ring: 100, target: target, notes: firstNotes, transition: .holdUntilNext)
        let b = p8bLayer(ring: 120, target: nextTarget ?? target, notes: nextNotes, transition: mode,
                        continuous: continuousNext, nextCellNotes: nextCellNotes)
        try f.root.document.edit { doc in
            doc.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: (reverse ? [b, a] : [a, b]) + extra, selectedLayerID: a.id)
            doc.detection = .allStagesOff
            doc.midiTarget = .init(uniqueID: 1)
        }
        f.root.runtime.sessionBegan(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
        p8Ack(f)
        return au
    }
    private func p8bNotes(_ messages: [[UInt8]]) -> Set<[UInt8]> {
        messages.reduce(into: Set<[UInt8]>()) { sounding, bytes in
            guard bytes.count == 3 else { return }
            switch bytes[0] & 0xf0 {
            case 0x90: sounding.insert([bytes[0] & 0x0f, bytes[1]])
            case 0x80: sounding.remove([bytes[0] & 0x0f, bytes[1]])
            case 0xb0 where bytes[1] == 123: sounding = sounding.filter { $0[0] != bytes[0] & 0x0f }
            default: break
            }
        }
    }
    private func p8bReplacement(first: [UInt8], next: [UInt8]) throws {
        for count in [90, 361] {
            for destination in [SpatialOutputDestination.midi, .audioUnit(stripID: InstrumentChannel.legacyID)] {
                for reverse in [false, true] {
                    for mode in p8bModes {
                        let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
                        let au = try p8bInstall(f, destination: destination, mode: mode, reverse: reverse,
                                               firstNotes: first, nextNotes: next)
                        let sink = destination == .midi ? f.midi.sends[0] : au.send
                        let context = "points=\(count), destination=\(destination), reverse=\(reverse), mode=\(mode)"
                        p8Frame(f, count: count, sequence: 1, distance: 100)
                        let on = first.sorted().map { [UInt8(0x90), $0, UInt8(100)] }
                        XCTAssertEqual(sink.sent, on, context)
                        p8Frame(f, count: count, sequence: 2, distance: 150)
                        XCTAssertEqual(sink.sent, on, context)
                        XCTAssertTrue(f.root.runtime.mailbox.read()?.activeCells.isEmpty == true, context)
                        p8Frame(f, count: count, sequence: 3, distance: 120)
                        let off = first.filter { !next.contains($0) }.sorted().map { [UInt8(0x80), $0, UInt8(0)] }
                        let nextOn = next.filter { !first.contains($0) }.sorted().map { [UInt8(0x90), $0, UInt8(100)] }
                        XCTAssertEqual(sink.sent, on + off + nextOn, context)
                        XCTAssertEqual(p8bNotes(sink.sent), Set(next.map { [UInt8(0), $0] }), context)
                        let display = try XCTUnwrap(f.root.runtime.mailbox.read())
                        XCTAssertEqual(display.profile?.geometry.pointCount, count, context)
                        XCTAssertEqual(display.processedProfiles, 3, context)
                        XCTAssertEqual(display.activeCells.map { $0.cell.ring }, [120], context)
                        f.root.stop(); p8Ack(f)
                        XCTAssertTrue(p8bNotes(sink.sent).isEmpty, context)
                    }
                }
            }
        }
    }
    func testP8R2bOutgoingHoldReplacedByEveryModeFor90And361() throws {
        try p8bReplacement(first: [60], next: [67])
    }
    func testP8R2bSameNoteReleasesOldHoldOwnerFor90And361() throws {
        try p8bReplacement(first: [60], next: [60])
    }
    func testP8R2bChordReleasesEntireOldHoldFor90And361() throws {
        try p8bReplacement(first: [60, 64, 67], next: [62, 67, 69])
    }
    func testP8R2bOtherChannelOrOutputHalfKeepsHoldFor90And361() throws {
        for count in [90, 361] {
            for destination in [SpatialOutputDestination.midi, .audioUnit(stripID: InstrumentChannel.legacyID)] {
                let otherChannel: SpatialRoutingTarget = destination == .midi ? .midiNote(channel: 1) : .audioUnitNote(channel: 1, stripID: InstrumentChannel.legacyID)
                let otherHalf: SpatialRoutingTarget = destination == .midi ? .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID) : .midiNote(channel: 0)
                for nextTarget in [otherChannel, otherHalf] {
                    for reverse in [false, true] {
                        for mode in p8bModes {
                            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
                            let au = try p8bInstall(f, destination: destination, mode: mode, reverse: reverse, nextTarget: nextTarget)
                            p8Frame(f, count: count, sequence: 1, distance: 100)
                            p8Frame(f, count: count, sequence: 2, distance: 150)
                            p8Frame(f, count: count, sequence: 3, distance: 120)
                            let sink = destination == .midi ? f.midi.sends[0] : au.send
                            XCTAssertTrue(p8bNotes(sink.sent).contains([0, 60]))
                            XCTAssertFalse(sink.sent.contains([0x80, 60, 0]))
                            XCTAssertEqual(p8bNotes(f.midi.sends[0].sent).count + p8bNotes(au.send.sent).count, 2)
                            f.root.stop(); p8Ack(f)
                            XCTAssertTrue(p8bNotes(f.midi.sends[0].sent).isEmpty)
                            XCTAssertTrue(p8bNotes(au.send.sent).isEmpty)
                        }
                    }
                }
            }
        }
    }
    func testP8R2bReplacementPreservesPolyphonyAndSharedNoteOwnersFor90And361() throws {
        for count in [90, 361] {
            for destination in [SpatialOutputDestination.midi, .audioUnit(stripID: InstrumentChannel.legacyID)] {
                let target: SpatialRoutingTarget = destination == .midi ? .midiNote(channel: 0) : .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID)
                for persistentNote: UInt8 in [60, 72] {
                    for reverse in [false, true] {
                        for mode in p8bModes {
                            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
                            let poly = p8bLayer(ring: 100, target: target, notes: [persistentNote], transition: .legato, continuous: true)
                            let activeHold = p8bLayer(ring: 100, target: target, notes: [75], transition: .holdUntilNext, continuous: true)
                            let au = try p8bInstall(f, destination: destination, mode: mode, reverse: reverse, extra: [poly, activeHold])
                            let sink = destination == .midi ? f.midi.sends[0] : au.send
                            p8Frame(f, count: count, sequence: 1, distance: 100)
                            p8Frame(f, count: count, sequence: 2, distance: 150)
                            let before = sink.sent
                            p8Frame(f, count: count, sequence: 3, distance: 120)
                            let expected: [[UInt8]] = persistentNote == 60
                                ? [[0x90, 67, 100]] : [[0x80, 60, 0], [0x90, 67, 100]]
                            XCTAssertEqual(Array(sink.sent.dropFirst(before.count)), expected)
                            XCTAssertEqual(p8bNotes(sink.sent), [[0, persistentNote], [0, 67]])
                            XCTAssertFalse(sink.sent.contains([0x90, 75, 100]), "Second simultaneous Hold loses to the first layer")
                            XCTAssertFalse(sink.sent.contains([0x80, persistentNote, 0]))
                            XCTAssertFalse(sink.sent.contains([0x80, 75, 0]))
                            f.root.stop(); p8Ack(f)
                            XCTAssertTrue(p8bNotes(sink.sent).isEmpty)
                        }
                    }
                }
            }
        }
    }
    func testP8R2bUnchangedSoundDoesNotExpireOutgoingHoldFor90And361() throws {
        for count in [90, 361] {
            for destination in [SpatialOutputDestination.midi, .audioUnit(stripID: InstrumentChannel.legacyID)] {
                for reverse in [false, true] {
                    for mode in p8bModes {
                        let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
                        let au = try p8bInstall(f, destination: destination, mode: mode, reverse: reverse, continuousNext: true)
                        let sink = destination == .midi ? f.midi.sends[0] : au.send
                        p8Frame(f, count: count, sequence: 1, distance: 100)
                        let before = sink.sent
                        p8Frame(f, count: count, sequence: 2, distance: 150)
                        p8Frame(f, count: count, sequence: 3, distance: 120)
                        XCTAssertEqual(sink.sent, before)
                        XCTAssertEqual(p8bNotes(sink.sent), mode == .holdUntilNext
                            ? [[0, reverse ? 67 : 60]] : [[0, 60], [0, 67]])
                        f.root.stop(); p8Ack(f)
                        XCTAssertTrue(p8bNotes(sink.sent).isEmpty)
                    }
                }
            }
        }
    }
    func testP8R2bReducedChordExpiresHoldOnlyWhenItStartsNewSoundFor90And361() throws {
        for count in [90, 361] {
            for destination in [SpatialOutputDestination.midi, .audioUnit(stripID: InstrumentChannel.legacyID)] {
                for reverse in [false, true] {
                    for mode in p8bModes {
                        let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
                        let au = try p8bInstall(f, destination: destination, mode: mode, reverse: reverse,
                                               nextNotes: [67, 69], continuousNext: true, nextCellNotes: [67])
                        let sink = destination == .midi ? f.midi.sends[0] : au.send
                        p8Frame(f, count: count, sequence: 1, distance: 100)
                        XCTAssertEqual(p8bNotes(sink.sent), mode == .holdUntilNext
                            ? (reverse ? [[0, 67], [0, 69]] : [[0, 60]]) : [[0, 60], [0, 67], [0, 69]])
                        p8Frame(f, count: count, sequence: 2, distance: 150)
                        let before = sink.sent
                        p8Frame(f, count: count, sequence: 3, distance: 120)
                        if mode == .holdUntilNext {
                            XCTAssertEqual(Array(sink.sent.dropFirst(before.count)),
                                           reverse ? [[0x80, 69, 0]] : [[0x80, 60, 0], [0x90, 67, 100]])
                            XCTAssertEqual(p8bNotes(sink.sent), [[0, 67]])
                        } else {
                            XCTAssertFalse(sink.sent.contains([0x80, 60, 0]))
                            XCTAssertEqual(sink.sent.filter { $0 == [0x90, 67, 100] }.count, 1)
                            p8Frame(f, count: count, sequence: 4, distance: 120, time: 0.11)
                            XCTAssertEqual(p8bNotes(sink.sent), [[0, 60], [0, 67]])
                        }
                        f.root.stop(); p8Ack(f)
                        XCTAssertTrue(p8bNotes(sink.sent).isEmpty)
                    }
                }
            }
        }
    }
    func testP8ConfirmationSurvivesMetadataRevisionFor90And361() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            try p8Install(f, secondDistance: 130)
            var config = f.root.document.document.detection
            config.cellSelection = .init(boundaryMarginCentimeters: 1, confirmationProfiles: 3)
            f.root.document.updateDetectionConfiguration(config); p8Ack(f)
            p8Frame(f, count: count, sequence: 1, distance: 100)
            p8Frame(f, count: count, sequence: 2, distance: 130)
            var channel = f.root.document.document.channel; channel.pan = 0.2
            f.root.document.updateChannel(channel); p8Ack(f)
            p8Frame(f, count: count, sequence: 3, distance: 130)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.activeCells.first?.cell.ring, 100)
            try f.root.document.edit { $0.channelName = "Confirming" }; p8Ack(f)
            p8Frame(f, count: count, sequence: 4, distance: 130)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.activeCells.first?.cell.ring, 130)
            XCTAssertEqual(f.midi.sends[0].sent.filter { $0[0] == 0x90 }.count, 2)
        }
    }
    func testP8DetectionConfigurationKeepsCompatibleHistoryAndAppliesNewMethodFor90And361() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            try p8Install(f, smoothing: .mean(window: 3))
            for (i, distance) in [UInt16(100), 100, 110].enumerated() { p8Frame(f, count: count, sequence: UInt64(i + 1), distance: distance) }
            let before = f.midi.sends[0].sent
            var config = f.root.document.document.detection; config.continuousBacklashCentimeters = 1
            f.root.document.updateDetectionConfiguration(config); p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent, before, "Config preview uses filled history once")
            p8Frame(f, count: count, sequence: 4, distance: 100)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.activeCells.first?.cell.ring, 103)
            config.temporalSmoothing = .median(window: 3)
            f.root.document.updateDetectionConfiguration(config); p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent.last, [0x80, 67, 0], "New smoothing method begins with current measurement")
            XCTAssertEqual(f.midi.sends[0].sent.filter { $0[0] == 0x90 }.count, 2, "Install cannot create a note")
            p8Frame(f, count: count, sequence: 5, distance: 100)
            XCTAssertEqual(f.midi.sends[0].sent.last, [0x90, 60, 100])
        }
    }
    func testP8PresetReplacementReleasesHoldFor90And361() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            try p8Install(f, transition: .holdUntilNext)
            p8Frame(f, count: count, sequence: 1, distance: 100)
            p8Frame(f, count: count, sequence: 2, distance: 150)
            try f.root.document.applyPresetDocument(f.root.document.document)
            p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent.last, [0x80, 60, 0])
        }
    }
    func testP8UnrelatedLayerRoutingEditPreservesSelectionAndOverlapFor90And361() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            try p8Install(f, transition: .overlap(milliseconds: 100), smoothing: .mean(window: 3))
            for (i, distance) in [UInt16(100), 100, 110].enumerated() { p8Frame(f, count: count, sequence: UInt64(i + 1), distance: distance) }
            let before = f.midi.sends[0].sent
            let extra = SpatialDocumentLayer(id: UUID(), name: "Unrelated", color: .green, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                cells: [PolarDeviceLattice(ring: 200, sector: 79)!],
                routings: [.init(target: .midiNote(channel: 1), program: .chord(notes: [72], velocity: 100, transition: .legato))], cellOverrides: [:])
            try f.root.document.edit { doc in doc.spatial = try! .init(latticeVersion: .polarDeviceV2,
                layers: doc.spatial.layers + [extra], selectedLayerID: doc.spatial.selectedLayerID) }
            p8Ack(f); XCTAssertEqual(f.midi.sends[0].sent, before)
            p8Frame(f, count: count, sequence: 4, distance: 100, time: 0.11)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.activeCells.first?.cell.ring, 103)
            XCTAssertEqual(f.midi.sends[0].sent.last, [0x80, 60, 0])
            // Removing the actual selected carrier is a genuine release.
            try f.root.document.edit { doc in
                let old = doc.spatial.layers[0]
                let reduced = SpatialDocumentLayer(id: old.id, name: old.name, color: old.color, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                    cells: [PolarDeviceLattice(ring: 100, sector: 79)!], routings: old.routings, cellOverrides: [:])
                doc.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [reduced, extra], selectedLayerID: old.id)
            }
            p8Ack(f); XCTAssertEqual(f.midi.sends[0].sent.last, [0x80, 67, 0])
        }
    }
    func testP8ContinuousChannelAndDetectionEditsAreOneUndoCommand() throws {
        let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
        try f.root.document.edit(name: "Previous") { $0.channelName = "Previous" }
        let initial = f.root.document.document
        f.root.document.beginContinuousEdit()
        for db in [-1.0, -2, -3] {
            var channel = f.root.document.document.channel; channel.levelDecibels = db
            f.root.document.updateChannel(channel)
            XCTAssertEqual(f.root.audio.channel.levelDecibels, db, "Intermediate samples reach audio")
        }
        f.root.document.endContinuousEdit()
        XCTAssertTrue(f.root.document.undo()); XCTAssertEqual(f.root.document.document.channel.levelDecibels, 0)
        XCTAssertEqual(f.root.document.document.channelName, "Previous")
        XCTAssertTrue(f.root.document.redo()); XCTAssertEqual(f.root.document.document.channel.levelDecibels, -3)
        XCTAssertTrue(f.root.document.undo()); XCTAssertTrue(f.root.document.undo())
        XCTAssertNotEqual(f.root.document.document.channelName, "Previous")
        XCTAssertFalse(f.root.document.canUndo, "Exactly one entry was added by the gesture")
        for mode in 0..<4 {
            f.root.document.beginContinuousEdit()
            for value in 1...3 {
                if mode == 0 {
                    var channel = f.root.document.document.channel; channel.pan = Double(value) / 4
                    f.root.document.updateChannel(channel)
                } else {
                    var configuration = f.root.document.document.detection
                    if mode == 1 { configuration.temporalSmoothing = .exponential(alpha: Double(value) / 4) }
                    if mode == 2 { configuration.roomContour.toleranceCentimeters = UInt16(10 + value) }
                    if mode == 3 { configuration.continuousBacklashCentimeters = UInt16(value) }
                    f.root.document.updateDetectionConfiguration(configuration)
                }
            }
            f.root.document.endContinuousEdit()
            XCTAssertTrue(f.root.document.undo())
            XCTAssertEqual(f.root.document.document.channel.pan, initial.channel.pan)
            XCTAssertEqual(f.root.document.document.detection, initial.detection)
            XCTAssertFalse(f.root.document.canUndo)
        }
    }
    private func objectNotes(pointCount: Int, grouping: Bool, gap: UInt16 = 10,
                             farther: UInt16 = 130, separateLayers: Bool = true,
                             smoothing: DetectionTemporalSmoothing = .off, separated: Bool = false) throws -> [[UInt8]] {
        let f = try RootFixture(clock: FrozenClock())
        let firstIndex = pointCount == 90 ? 20 : 79
        let secondIndex = firstIndex + (separated ? 8 : 1)
        // Independent MMK oracle: sample 20 covers 79...82, sample 21 covers
        // 83...86. Both masks sit at the span edge, away from its visual anchor.
        let first = PolarDeviceLattice(ring: 100, sector: 79)!
        let second = PolarDeviceLattice(ring: Int(farther), sector: pointCount == 90 ? (separated ? 112 : 83) : secondIndex)!
        let firstLayer = SpatialDocumentLayer(id: UUID(), name: "First object", color: .blue,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false,
            cells: separateLayers ? [first] : [first, second],
            routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [60], velocity: 100, transition: .retrigger))],
            cellOverrides: separateLayers ? [:] : [second: [.init(target: .midiNote(channel: 0), value: .note(number: 67, velocity: 100))]])
        let secondLayer = SpatialDocumentLayer(id: UUID(), name: "Second object", color: .green,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [second],
            routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [67], velocity: 100, transition: .retrigger))], cellOverrides: [:])
        try f.root.document.edit { document in
            document.spatial = try! .init(latticeVersion: .polarDeviceV2,
                layers: separateLayers ? [firstLayer, secondLayer] : [firstLayer], selectedLayerID: firstLayer.id)
            document.detection = .init(temporalSmoothing: smoothing, groupingEnabled: grouping,
                groupingJumpCentimeters: gap, representative: .nearestPoint, minimumAngleDegrees: 0)
            document.midiTarget = .init(uniqueID: 1)
        }
        var payload: [UInt8] = [0xb0, UInt8(pointCount & 255), UInt8(pointCount >> 8)]
        for index in 0..<pointCount {
            let value: UInt16 = index == firstIndex ? 100 : index == secondIndex ? farther : 8191
            payload += [UInt8(value & 255), UInt8(value >> 8)]
        }
        payload += [0]
        f.scanner.descriptors[0].append(.bytes(try Frame.build(address: 0x81, payload: payload).encoded()))
        f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
        wait { f.root.runtime.mailbox.read()?.profile?.sequence == 1 }
        let frame = try XCTUnwrap(f.root.runtime.mailbox.read())
        XCTAssertEqual(frame.profile?.geometry.pointCount, pointCount)
        let notes = f.midi.sends[0].sent.filter { $0.first == 0x90 }
        XCTAssertEqual(frame.activeCells.count, notes.count)
        finish(f)
        XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first == 0x80 }.count, notes.count)
        return notes.sorted { $0[1] < $1[1] }
    }
    func testOwnerRun2EveryObjectCanSoundInItsOwnLayerFor90And361() throws {
        for count in [90, 361] {
            XCTAssertEqual(try objectNotes(pointCount: count, grouping: true), [[0x90, 60, 100], [0x90, 67, 100]])
        }
    }
    func testOwnerRun2GroupingOffUsesEveryMeasurementFor90And361() throws {
        for count in [90, 361] {
            for smoothing in [DetectionTemporalSmoothing.off, .mean(window: 2)] {
                XCTAssertEqual(try objectNotes(pointCount: count, grouping: false, smoothing: smoothing), [[0x90, 60, 100], [0x90, 67, 100]])
            }
        }
    }
    func testOwnerRun2ObjectsSeparatedByMissingMeasurementsRemainDistinctAtEqualDistanceFor90And361() throws {
        for count in [90, 361] {
            XCTAssertEqual(try objectNotes(pointCount: count, grouping: true, farther: 100, separated: true), [[0x90, 60, 100], [0x90, 67, 100]])
        }
    }
    func testOwnerRun2SameLayerSoundsOnlyNearestObjectFor90And361() throws {
        for count in [90, 361] {
            for grouping in [true, false] {
                XCTAssertEqual(try objectNotes(pointCount: count, grouping: grouping, separateLayers: false), [[0x90, 60, 100]])
            }
        }
    }
    func testOwnerRun2MinimumGapMergesNearbyObjectsAndChangingItSplitsThemFor90And361() throws {
        for count in [90, 361] {
            XCTAssertEqual(try objectNotes(pointCount: count, grouping: true, gap: 10, farther: 106), [[0x90, 60, 100]])
            XCTAssertEqual(try objectNotes(pointCount: count, grouping: true, gap: 5, farther: 106), [[0x90, 60, 100], [0x90, 67, 100]])
        }
    }

    private func supportedGeometry(_ pointCount: Int, simulation: Bool) throws {
        let f = try RootFixture(clock: FrozenClock()); try f.install(tick: 2)
        if simulation { f.root.input.connectSimulation(serviceName: "Synthetic MMK", opener: GeometryStream(f.scanner.descriptors[0])) }
        else { f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400) }
        var payload: [UInt8] = [0xb0, UInt8(pointCount & 255), UInt8(pointCount >> 8)]
        for _ in 0..<pointCount { payload += [100, 0] }; payload += [0]
        f.scanner.descriptors[0].append(.bytes(try Frame.build(address: 0x81, payload: payload).encoded()))
        wait { f.root.runtime.mailbox.read()?.profile != nil }
        let frame = try XCTUnwrap(f.root.runtime.mailbox.read())
        XCTAssertEqual(frame.profile?.geometry.pointCount, pointCount)
        XCTAssertEqual(frame.profile?.geometry.startAngleDegrees, -90)
        XCTAssertEqual(frame.profile?.geometry.endAngleDegrees, 90)
        XCTAssertEqual(frame.activeCells.count, 1)
        XCTAssertTrue(f.midi.sends[0].sent.contains([0x90, 60, 100]))
        XCTAssertEqual(frame.profile?.measurements.first?.ticks.lower, 0)
        XCTAssertEqual(frame.profile?.measurements.last?.ticks.upper, 360)
        let points = try XCTUnwrap(frame.profile?.projectedMeasurements)
        XCTAssertEqual(points.count, pointCount)
        XCTAssertEqual(try XCTUnwrap(points.first).point.xMeters, -1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(points.last).point.xMeters, 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(points.first).point.yMeters, 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(points.last).point.yMeters, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(points.map(\.point.yMeters).max() ?? 0, 0.99)
        wait { f.root.input.session.state.profileGeometry.geometry?.pointCount == pointCount }
        XCTAssertEqual(f.root.input.session.state.profileGeometry.geometry, frame.profile?.geometry)
        XCTAssertEqual(f.root.input.session.state.profileGeometry.unsupportedProfiles, 0)
        finish(f)
    }
    func testMMK90SimulationPlaysThroughProductionRoot() throws { try supportedGeometry(90, simulation: true) }
    func testMMK90ScannerPlaysThroughProductionRoot() throws { try supportedGeometry(90, simulation: false) }
    func testScan180PlaysThroughProductionRoot() throws { try supportedGeometry(180, simulation: false) }
    func testFullScan361PlaysThroughProductionRoot() throws { try supportedGeometry(361, simulation: false) }
    func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let until = Date().addingTimeInterval(3)
        while !predicate(), Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
    func sounding() throws -> RootFixture {
        let f = try RootFixture(clock: FrozenClock()); try f.install()
        f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
        f.scanner.descriptors[0].append(.bytes(try f.bytes()))
        wait { f.midi.sends[0].sent.contains { $0.first == 0x90 } }
        return f
    }
    func off(_ f: RootFixture) { wait { f.midi.sends[0].sent.contains { $0.first == 0x80 } } }
    func finish(_ f: RootFixture) { var done = false; f.root.terminate { done = true }; wait { done }; wait { f.scanner.descriptors[0].count == 1 } }
    func testPanicReleasesThroughProductionRoot() throws { let f = try sounding(); f.root.panic(); off(f); finish(f) }
    func testRundeEPanicSurfaceDriftAndIndependentLayerPartitions90And361() throws {
        for count in [90,361] { for transition in [SpatialNoteTransition.legato, .holdUntilNext, .toggle] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            // Install through the same production path as the stage release matrix.
            let stage = try stageInstall(f, transition: transition)
            let firstID = f.root.document.document.spatial.layers[0].id
            let secondID = UUID()
            func layer(_ id: UUID, split: Int, channel: UInt8) -> SpatialDocumentLayer {
                let cells = Set((100...160).map { PolarDeviceLattice(ring: $0, sector: 79)! })
                let targets: [SpatialRoutingTarget] = [.midiNote(channel: channel), .audioUnitNote(channel: channel, stripID: InstrumentChannel.legacyID)]
                return .init(id: id, name: "Surface", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                    cells: cells, routings: targets.map { .init(target: $0, program: .chord(notes: [60+Int(channel)], velocity: 100, transition: transition)) },
                    cellOverrides: Dictionary(uniqueKeysWithValues: (split...160).map { ring in
                        (PolarDeviceLattice(ring: ring, sector: 79)!, targets.map { .init(target: $0, value: .note(number: 67+Int(channel), velocity: 100)) })
                    }))
            }
            try f.root.document.edit { doc in
                doc.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [layer(firstID, split: 140, channel: 0),layer(secondID, split: 120, channel: 1)], selectedLayerID: firstID)
                doc.detection = .allStagesOff
                doc.scenes = []; doc.currentSceneID = nil
            }
            p8Ack(f)
            p8Frame(f, count: count, sequence: 1, distance: 100)
            XCTAssertTrue(f.midi.sends[0].sent.contains([0x90,60,100]))
            XCTAssertTrue(stage.au.send.sent.contains([0x90,60,100]))
            f.root.panic(); p8Ack(f)
            let midiCount = f.midi.sends[0].sent.filter { $0.first.map { $0 & 0xf0 == 0x90 } == true }.count
            let auCount = stage.au.send.sent.filter { $0.first.map { $0 & 0xf0 == 0x90 } == true }.count
            for (sequence,distance) in [106,110,119].enumerated() {
                p8Frame(f, count: count, sequence: UInt64(sequence+2), distance: UInt16(distance))
                XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first.map { $0 & 0xf0 == 0x90 } == true }.count,midiCount)
                XCTAssertEqual(stage.au.send.sent.filter { $0.first.map { $0 & 0xf0 == 0x90 } == true }.count,auCount)
            }
            p8Frame(f, count: count, sequence: 5, distance: 130)
            XCTAssertEqual(f.midi.sends[0].sent.last,[0x91,68,100], "Only layer two crossed its content boundary")
            XCTAssertFalse(f.midi.sends[0].sent.suffix(2).contains([0x90,60,100]))
            p8Frame(f, count: count, sequence: 6, distance: 145)
            XCTAssertTrue(f.midi.sends[0].sent.suffix(3).contains([0x90,67,100]))
            p8Frame(f, count: count, sequence: 7, distance: 100)
            XCTAssertTrue(f.midi.sends[0].sent.suffix(4).contains([0x90,60,100]))
            XCTAssertTrue(stage.au.send.sent.suffix(4).contains([0x90,60,100]))
            f.root.panic(); p8Ack(f)
            p8Frame(f, count: count, sequence: 8, distance: 200)
            let before = f.midi.sends[0].sent.filter { $0 == [0x90,60,100] }.count
            p8Frame(f, count: count, sequence: 9, distance: 100)
            XCTAssertEqual(f.midi.sends[0].sent.filter { $0 == [0x90,60,100] }.count,before+1,"A measured empty cell re-arms the surface")
        } }
    }

    func testAcceptanceAPanicHeldCellSilentAndMeasuredOtherCellUnlocks90And361() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            // Three centimetres remains inside one drawn 5 cm surface.
            // Ten centimetres reaches a distinct canonical content region.
            try p8Install(f, secondDistance: 110)
            p8Frame(f, count: count, sequence: 1, distance: 100)
            f.root.panic(); p8Ack(f)
            let before = f.midi.sends[0].sent.filter { $0.first == 0x90 }.count
            p8Frame(f, count: count, sequence: 2, distance: 100)
            XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first == 0x90 }.count, before)
            p8Frame(f, count: count, sequence: 3, distance: 110)
            XCTAssertEqual(f.midi.sends[0].sent.last, [0x90, 67, 100])
            p8Frame(f, count: count, sequence: 4, distance: 100)
            XCTAssertTrue(f.midi.sends[0].sent.suffix(2).contains([0x90, 60, 100]))
            XCTAssertEqual(f.root.runtime.mailbox.read()?.overflowProfiles, 0)
        }
    }
    func testStopReleasesThroughProductionRoot() throws { let f = try sounding(); f.root.stop(); off(f); finish(f) }
    func testSleepReleasesAndWakeNeedsFreshProfile() throws {
        let f = try sounding(); try f.root.audio.start(); f.root.audio.setMeterVisible(true)
        XCTAssertTrue(f.root.audio.isMeterActive)
        f.root.sleep(); XCTAssertFalse(f.root.audio.isMeterActive, "Sleep removes the tap before waiting for Q")
        off(f); let count = f.midi.sends[0].sent.filter { $0.first == 0x90 }.count
        f.root.wake(); p8Ack(f)
        XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first == 0x90 }.count, count)
        f.scanner.descriptors[0].append(.bytes(try f.bytes())); wait { f.midi.sends[0].sent.filter { $0.first == 0x90 }.count == count + 1 }; finish(f)
    }
    func testDisconnectReleasesBeforeCloseAndFreshSessionOnReconnect() throws {
        let f = try sounding(); let old = f.root.input.session.sessionID
        f.root.input.disconnect(); off(f); wait { f.scanner.descriptors[0].count == 1 && !f.root.input.isAwaitingPortRelease }
        f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
        XCTAssertNotEqual(old, f.root.input.session.sessionID)
        f.scanner.descriptors[1].append(.bytes(try f.bytes())); wait { f.midi.sends[0].sent.filter { $0.first == 0x90 }.count == 2 }
        f.root.input.disconnect(); off(f); var done = false; f.root.terminate { done = true }; wait { done }; wait { f.scanner.descriptors[1].count == 1 }
    }
    func testSourceLossReleasesThroughProductionRoot() throws { let f = try sounding(); f.scanner.descriptors[0].append(.closed); off(f); finish(f) }
    func testHaltenToggleProductionFailureKeepsLatchAndRecoveryOffThenUserEndReleases() throws {
        for transition: SpatialNoteTransition in [.holdUntilNext, .toggle] { for failureFirst in [true, false] {
            let f = try RootFixture(clock: FrozenClock()); defer { p8Finish(f) }
            try f.install()
            let layer = f.root.document.document.spatial.layers[0]
            var routes = layer.routings; routes[0].program = .chord(notes: [60], velocity: 100, transition: transition)
            try f.root.document.edit { doc in
                doc.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [
                    .init(id: layer.id, name: layer.name, color: layer.color, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                        cells: layer.cells, routings: routes, cellOverrides: [:], toggleGuardSeconds: 0)], selectedLayerID: layer.id)
            }
            f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
            f.scanner.descriptors[0].append(.bytes(try f.bytes()))
            wait { f.midi.sends[0].sent.contains { $0.first == 0x90 } }
            f.scanner.descriptors[0].append(.closed)
            wait { !f.root.input.session.isPortHeld }; p8Ack(f)
            XCTAssertFalse(f.midi.sends[0].sent.contains { $0.first == 0x80 }, "Reader failure preserves deliberate latch")
            f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
            f.scanner.descriptors[1].append(.bytes(try f.bytes()))
            wait { f.root.input.session.deliveredProfileBatches >= 2 }; p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first == 0x90 }.count, 1)
            if transition == .toggle {
                f.scanner.descriptors[1].append(.bytes(try f.bytes(8191) + f.bytes()))
                off(f)
                f.scanner.descriptors[1].append(.bytes(try f.bytes(8191) + f.bytes()))
                wait { f.midi.sends[0].sent.filter { $0.first == 0x90 }.count == 2 }
            }
            if failureFirst {
                f.scanner.descriptors[1].append(.closed)
                wait { !f.root.input.session.isPortHeld }; p8Ack(f)
            }
            let before = f.midi.sends[0].sent.filter { $0.first == 0x80 }.count
            f.root.input.disconnect(); p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first == 0x80 }.count, before + 1, "User disconnect after error must release")
            wait { !f.root.input.session.isPortHeld }; p8Ack(f)
            XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first == 0x80 }.count, before + 1, "Later reader end cannot repeat the release")
        } }
    }
    func testMIDITargetChangeRetiresBeforeClosingAndAttachesOnlyAfterAck() throws {
        let f = try sounding()
        f.root.document.selectMIDITarget(.init(uniqueID: 2)); wait { f.midi.opens == [1, 2] }
        XCTAssertTrue(f.midi.messagesAtClose[0].contains { $0.first == 0x80 })
        XCTAssertFalse(f.midi.sends[1].sent.contains { $0.first == 0x90 })
        f.scanner.descriptors[0].append(.bytes(try f.bytes())); wait { f.midi.sends[1].sent.contains { $0.first == 0x90 } }; finish(f)
    }
    func testMIDIDestinationLossRetiresBeforeRetry() throws { let f = try sounding(); f.midi.onDestinationLost?(); wait { f.midi.closes == 1 }; XCTAssertTrue(f.midi.messagesAtClose[0].contains { $0.first == 0x80 }); finish(f) }
    func testMIDIRebindingResetsNewDestinationBeforeAnyNoteOn() throws {
        let f = try sounding(); defer { finish(f) }
        f.root.document.selectMIDITarget(.init(uniqueID: 2))
        wait { f.midi.opens == [1, 2] }
        let reset = (UInt8(0)...15).flatMap { MusicEventMIDIEncoding.releaseMessages(channel: $0) }
        wait { f.midi.sends[1].sent.count >= reset.count }
        XCTAssertEqual(Array(f.midi.sends[1].sent.prefix(reset.count)), reset)
        XCTAssertTrue(f.midi.messagesAtClose[0].contains([0x80, 60, 0]))
        f.scanner.descriptors[0].append(.bytes(try f.bytes()))
        wait { f.midi.sends[1].sent.contains([0x90, 60, 100]) }
        let before = f.midi.sends[1].sent.count
        f.midi.onDestinationLost?()
        wait { f.midi.closes == 2 && f.midi.opens == [1, 2, 2] }
        wait { f.midi.sends[1].sent.count >= before + 1 + reset.count }
        XCTAssertEqual(Array(f.midi.sends[1].sent.suffix(reset.count)), reset)
    }
    func testTerminateAcknowledgesReleaseBeforeClosingMIDI() throws { let f = try sounding(); finish(f); XCTAssertTrue(f.midi.messagesAtClose[0].contains { $0.first == 0x80 }); XCTAssertFalse(f.root.audio.isRunning) }
    func testDetectionChangeReleasesAndUsesDocumentConfiguration() throws {
        let f = try sounding(); var config = DetectionConfiguration.ownerDefaults; config.groupingMinimumPoints = 2
        f.root.document.updateDetectionConfiguration(config); off(f)
        XCTAssertEqual(f.root.document.canvas.workspace.detectionConfiguration, f.root.document.document.detection); finish(f)
    }
    func testUndoAndRedoEachAdvanceRevisionAndRestoreWholeChannel() throws {
        let f = try RootFixture(); let before = f.root.document.document
        var channel = before.channel; channel.pan = 0.75; channel.muted = true
        f.root.document.updateChannel(channel); let edited = f.root.document.document.revision
        XCTAssertTrue(f.root.document.undo()); XCTAssertEqual(f.root.document.document.channel, before.channel)
        XCTAssertGreaterThan(f.root.document.document.revision.counter, edited.counter)
        XCTAssertTrue(f.root.document.redo()); XCTAssertEqual(f.root.document.document.channel, channel)
        var done = false; f.root.terminate { done = true }; wait { done }
    }
    func testCanvasMetadataEditPreservesImportedFineMaskAndOverrides() throws {
        let f = try RootFixture(); try f.install(); let spatial = f.root.document.document.spatial
        f.root.document.canvas.renameSelectedLayer("Renamed")
        XCTAssertEqual(f.root.document.document.spatial.layers[0].cells, spatial.layers[0].cells)
        XCTAssertEqual(f.root.document.document.spatial.layers[0].cellOverrides, spatial.layers[0].cellOverrides)
        XCTAssertEqual(f.root.document.document.spatial.layers[0].name, "Renamed")
        var done = false; f.root.terminate { done = true }; wait { done }
    }
    func testTerminationIsIdempotentAndCannotOpenAnotherSource() throws {
        let f = try sounding(); finish(f)
        var second = false; f.root.terminate { second = true }; wait { second }
        XCTAssertEqual(f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400), .refused(.awaitingRelease))
        XCTAssertEqual(f.midi.closes, 1); XCTAssertEqual(f.scanner.descriptors[1].count, 0)
    }
    func testSleepingFramesCannotReopenNotesAndWakeResumesPreviouslyRunningAudio() throws {
        let f = try sounding(); try f.root.audio.start(); f.root.sleep(); off(f)
        let before = f.midi.sends[0].sent.count
        f.scanner.descriptors[0].append(.bytes(try f.bytes()))
        wait { (f.root.runtime.mailbox.read()?.discardedProfiles ?? 0) > 0 }
        XCTAssertEqual(f.midi.sends[0].sent.count, before)
        f.root.wake(); XCTAssertTrue(f.root.audio.isRunning)
        XCTAssertEqual(f.midi.sends[0].sent.count, before)
        f.scanner.descriptors[0].append(.bytes(try f.bytes()))
        wait { f.midi.sends[0].sent.count > before }
        finish(f)
    }
    func testWakeBeforeSleepAckResumesWithoutStartingNotesAndStoppedHostStaysStopped() throws {
        for wasRunning in [false, true] {
            let f = try sounding()
            f.root.audio.setMeterVisible(true)
            if wasRunning { try f.root.audio.start() }
            let noteOns = f.midi.sends[0].sent.filter { $0.first == 0x90 }.count
            f.root.sleep(); XCTAssertFalse(f.root.audio.isMeterActive)
            f.root.wake()
            let barrier = expectation(description: "sleep/wake processed")
            f.root.runtime.acknowledge { barrier.fulfill() }; wait(for: [barrier], timeout: 3)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            XCTAssertEqual(f.root.audio.isRunning, wasRunning)
            XCTAssertEqual(f.root.audio.isMeterActive, wasRunning)
            XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first == 0x90 }.count, noteOns)
            finish(f)
        }
    }
    func testNewInputSessionDuringSleepCannotStartNotesBeforeWakeAndFreshProfile() throws {
        let f = try RootFixture(clock: FrozenClock()); try f.install()
        f.root.sleep()
        let slept = expectation(description: "sleep applied")
        f.root.runtime.acknowledge { slept.fulfill() }; wait(for: [slept], timeout: 3)
        f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
        f.scanner.descriptors[0].append(.bytes(try f.bytes()))
        wait { f.root.input.session.state.lastProfile != nil }
        let frame = expectation(description: "sleeping source processed")
        f.root.runtime.acknowledge { frame.fulfill() }; wait(for: [frame], timeout: 3)
        XCTAssertTrue(f.midi.sends[0].sent.isEmpty)
        f.root.wake()
        f.scanner.descriptors[0].append(.bytes(try f.bytes()))
        wait { f.root.runtime.mailbox.read()?.profile?.sequence == 2 }
        XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first == 0x90 }.count, 1)
        finish(f)
    }
    func testProductionContourSurvivesDisconnectReconnectAndDocumentReplacement() throws {
        let f = try sounding()
        let contour = SpatialRoomContour(geometry: .init(pointCount: 361,
            angleResolutionDegrees: 0.5, startAngleDegrees: -90, sourceIdentifier: "scanner:default"),
            nearestDistancesCentimeters: Array(repeating: 100, count: 361),
            spreadCentimeters: Array(repeating: 0, count: 361))
        f.root.runtime.roomContour(contour)
        var detection = f.root.document.document.detection; detection.roomContour.isEnabled = true
        f.root.document.updateDetectionConfiguration(detection)
        f.scanner.descriptors[0].append(.bytes(try f.bytes()))
        wait { f.root.runtime.mailbox.read()?.selection.filteredOrders.contains(180) == true }
        XCTAssertEqual(f.root.runtime.mailbox.read()?.contour, contour)
        f.root.input.disconnect(); wait { f.scanner.descriptors[0].count == 1 && !f.root.input.isAwaitingPortRelease }
        try f.install()
        XCTAssertEqual(f.root.runtime.mailbox.read()?.contour, contour)
        f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
        f.scanner.descriptors[1].append(.bytes(try f.bytes()))
        wait { f.root.input.session.state.lastProfile != nil }
        let barrier = expectation(description: "new session contour")
        f.root.runtime.acknowledge { barrier.fulfill() }; wait(for: [barrier], timeout: 3)
        XCTAssertEqual(f.root.runtime.mailbox.read()?.contour, contour)
        finish(f)
    }
    func testExactCanvasProjectionRoundTripsEveryMigratedAddressAtBoundaries() throws {
        for grid in [MetricSquareGrid.quarterMeter, .halfMeter] {
            for ring in 0..<20 {
                for angular in 0..<64 {
                    let tile = PolarMetricGridCell(ring: ring, angularIndex: angular)
                    let cells = try LegacyLatticeMigration.migrate(tile, in: grid).cells
                    let mismatch = try cells.first { try LegacyLatticeMigration.project($0, in: grid) != tile }
                    XCTAssertNil(mismatch, "projection boundary \(grid) \(tile)")
                }
            }
        }
    }

    func testBlockedMainCannotDelayProfileNoteOffOnQ() throws {
        let f = try sounding()
        f.scanner.descriptors[0].append(.bytes(try f.bytes(8191)))
        Thread.sleep(forTimeInterval: 0.05) // no Main pumping: R → Q stays live
        XCTAssertTrue(f.midi.sends[0].sent.contains { $0.first == 0x80 })
        finish(f)
    }

    func testMIDIRetireKeepsTransportOpenWhileOffIsBlocked() throws {
        let f = try sounding(); let gate = f.midi.sends[0].blockNextOff(); defer { gate.signal() }
        f.root.document.selectMIDITarget(.init(uniqueID: 2)); wait { f.midi.sends[0].isBlocked }
        XCTAssertEqual(f.midi.closes, 0); XCTAssertEqual(f.midi.opens, [1])
        gate.signal(); wait { f.midi.opens == [1, 2] }
        XCTAssertTrue(f.midi.messagesAtClose[0].contains { $0.first == 0x80 }); finish(f)
    }
    func testTerminationEndsWithinTwoSecondsAndLogsBlockedMIDINoteOff() throws {
        let f = try sounding(); let before = f.root.audio.channel
        try f.root.audio.start(); f.root.audio.setMeterVisible(true)
        XCTAssertTrue(f.root.audio.isMeterActive)
        let gate = f.midi.sends[0].blockNextOff(); defer { gate.signal() }
        let started = MonotonicRuntimeClock().now
        var completions = 0; f.root.terminate { completions += 1 }
        XCTAssertFalse(f.root.audio.isMeterActive, "Termination removes the tap before a blocked output can delay Q")
        wait { f.midi.sends[0].isBlocked }
        wait { completions == 1 }
        XCTAssertLessThanOrEqual(MonotonicRuntimeClock().now - started, 2)
        let report = try XCTUnwrap(f.root.terminationReport)
        XCTAssertTrue(report.deadlineExpired)
        XCTAssertEqual(report.unconfirmedNoteOffs.count, 1)
        let note = try XCTUnwrap(report.unconfirmedNoteOffs.first)
        XCTAssertEqual(note.destination, .midi); XCTAssertEqual(note.channel, 0); XCTAssertEqual(note.note, 60)
        XCTAssertTrue(report.protocolLines.contains { $0.contains(note.portID.uuidString) && $0.contains("channel=0, note=60") })
        XCTAssertEqual(f.midi.closes, 0); XCTAssertEqual(f.root.audio.channel, before)
        f.root.terminate { completions += 1 }; XCTAssertEqual(completions, 2)
        gate.signal(); wait { f.midi.closes == 1 }
        XCTAssertEqual(completions, 2)
        XCTAssertTrue(f.midi.messagesAtClose[0].contains { $0.first == 0x80 })
    }
    func testTerminationEndsWithinTwoSecondsAndLogsBlockedAURelease() throws {
        let f = try sounding(); let boundary = FakeAURelease()
        let id = UUID(); f.root.runtime.attach(RuntimePorts.audioUnit(id: id, boundary: boundary))
        try f.root.document.edit { doc in
            let old = doc.spatial.layers[0]
            let layer = SpatialDocumentLayer(id: old.id, name: old.name, color: old.color,
                isVisible: old.isVisible, isActive: old.isActive, isLocked: old.isLocked, isSoloed: old.isSoloed,
                cells: old.cells, routings: old.routings + [.init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID),
                    program: .chord(notes: [67], velocity: 100, transition: .retrigger))], cellOverrides: old.cellOverrides)
            doc.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        }
        f.scanner.descriptors[0].append(.bytes(try f.bytes()))
        wait { boundary.send.sent.contains([0x90, 67, 100]) }
        let gate = boundary.send.blockNextOff(); defer { gate.signal() }
        let started = MonotonicRuntimeClock().now
        var done = false; f.root.terminate { done = true }; wait { boundary.send.isBlocked }; wait { done }
        XCTAssertLessThanOrEqual(MonotonicRuntimeClock().now - started, 2)
        let report = try XCTUnwrap(f.root.terminationReport)
        XCTAssertTrue(report.deadlineExpired)
        XCTAssertEqual(report.unconfirmedNoteOffs, [.init(portID: id, destination: .audioUnit(stripID: InstrumentChannel.legacyID), channel: 0, note: 67)])
        // The healthy preceding MIDI port receives Panic on all sixteen channels.
        XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first.map { $0 & 0xf0 == 0xb0 } == true && $0[1] == 123 }.count, 16)
        gate.signal(); wait { f.midi.closes == 1 }
    }
    func testUnblockedTerminationConfirmsPanicAndCompletesOnceWithoutDeadline() throws {
        let f = try sounding(); let started = MonotonicRuntimeClock().now
        var done = 0; f.root.terminate { done += 1 }; wait { done == 1 }
        XCTAssertLessThan(MonotonicRuntimeClock().now - started, 1)
        XCTAssertEqual(f.root.terminationReport?.deadlineExpired, false)
        XCTAssertEqual(f.root.terminationReport?.unconfirmedNoteOffs, [])
        XCTAssertEqual(f.midi.sends[0].sent.filter { $0.first.map { $0 & 0xf0 == 0xb0 } == true && $0[1] == 123 }.count, 16)
    }

    func testUnsupportedProfileGeometryReleasesInsteadOfHoldingPreviousNote() throws {
        let f = try sounding(); f.scanner.descriptors[0].append(.bytes(try f.bytes(pointCount: 10)))
        wait { f.root.input.session.state.profileGeometry.unsupportedProfiles == 1 }
        XCTAssertEqual(f.root.input.session.state.profileGeometry.rejectedPointCount, 10)
        XCTAssertEqual(f.root.input.session.state.profileGeometry.rejectedPartialScanIndex, 0)
        XCTAssertNil(f.root.input.session.state.profileGeometry.geometry)
        off(f); finish(f)
    }
    func testPartialScanRejectionIsVisibleAndCountIncludesSupersededProfiles() throws {
        let f = try sounding()
        f.root.document.beginRoomContourCapture()
        var payload: [UInt8] = [0xb0, 90, 8]
        for _ in 0..<90 { payload += [100, 0] }; payload += [0]
        let bytes = try Frame.build(address: 0x81, payload: payload).encoded()
        f.scanner.descriptors[0].append(.bytes(bytes + bytes))
        wait { f.root.input.session.state.profileGeometry.unsupportedProfiles == 2 }
        XCTAssertEqual(f.root.input.session.state.profileGeometry.rejectedPointCount, 90)
        XCTAssertEqual(f.root.input.session.state.profileGeometry.rejectedPartialScanIndex, 1)
        waitCapture(f.root.document)
        XCTAssertEqual(f.root.document.roomContourCaptureProgress, 0)
        XCTAssertFalse(f.root.document.isCapturingRoomContour)
        XCTAssertEqual(f.root.document.contourCapture.notice, "Capture cancelled: invalid scanner geometry")
        f.root.document.cancelRoomContourCapture()
        off(f); finish(f)
    }
    func testDisplayReaderDoesNotRepublishAnUnchangedMailbox() throws {
        let f = try RootFixture()
        let barrier = expectation(description: "initial document installed")
        f.root.runtime.acknowledge { barrier.fulfill() }; wait(for: [barrier], timeout: 3)
        var publications = 0
        let observation = f.root.display.$frame.dropFirst().sink { _ in publications += 1 }
        f.root.display.read()
        for _ in 0..<25 { f.root.display.read() }
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(observation) {}
        var done = false; f.root.terminate { done = true }; wait { done }
    }
    func testSeveralProfilesInOneReadAllReachSoundInArrivalOrder() throws {
        let f = try RootFixture(); try f.install()
        f.scanner.descriptors[0].append(.bytes(try f.bytes() + f.bytes(8191)))
        f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
        wait { f.root.runtime.mailbox.read()?.profile?.sequence == 2 }
        XCTAssertEqual(f.midi.sends[0].sent.map { $0[0] }, [0x90, 0x80])
        XCTAssertEqual(f.root.runtime.mailbox.read()?.processedProfiles, 2); finish(f)
    }
    func testBacklogNoticeIsReadThroughProductionDisplayWhileQBlocksAndAfterRecovery() throws {
        let f = try RootFixture(clock: FrozenClock()); try f.install()
        let runtime = f.root.runtime, id = UUID()
        runtime.sessionBegan(id)
        let hit = DeviceTickMeasurement(order: 180, ticks: .point(180)!, rawCentimeters: 100)!
        runtime.frame(.init(sessionID: id, sequence: 1, time: 0, measurements: [hit]))
        wait { f.midi.sends[0].sent.contains([0x90, 60, 100]) }
        let gate = f.midi.sends[0].blockNextOff()
        defer { gate.signal() }
        runtime.frame(.init(sessionID: id, sequence: 2, time: 0, measurements: []))
        wait { f.midi.sends[0].isBlocked }
        for sequence in 3...53 { runtime.frame(.init(sessionID: id, sequence: UInt64(sequence), time: 0, measurements: [hit])) }
        f.root.display.read()
        XCTAssertEqual(f.root.display.inputBacklogStatus, .overloaded)
        XCTAssertEqual(f.root.display.inputBacklogStatus.message, "Input is over 2 seconds behind · releasing all notes.")
        gate.signal()
        wait { runtime.inputBacklogStatus == .recovered }
        f.root.display.read()
        XCTAssertEqual(f.root.display.inputBacklogStatus, .recovered)
        runtime.frame(.init(sessionID: id, sequence: 54, time: 0, measurements: [hit]))
        wait { runtime.mailbox.read()?.profile?.sequence == 54 }
        XCTAssertEqual(f.midi.sends[0].sent.filter { $0 == [0x90, 60, 100] }.count, 2)
        p8Finish(f)
    }
    func testBurstWithinTwoSecondBudgetHasNoLostDuplicatedOrReorderedSound() throws {
        for count in [90, 361] {
            let f = try RootFixture(clock: FrozenClock()); try f.install()
            var burst: [UInt8] = []
            for _ in 0..<24 { burst += try f.bytes(pointCount: count) + f.bytes(8191, pointCount: count) }
            f.scanner.descriptors[0].append(.bytes(burst))
            f.root.input.connectDevelopment(portPath: "/dev/cu.fake", baudRate: .baud38400)
            wait { f.root.runtime.mailbox.read()?.profile?.sequence == 48 }
            XCTAssertEqual(f.midi.sends[0].sent, (0..<24).flatMap { _ in [[0x90, 60, 100], [0x80, 60, 0]] })
            XCTAssertEqual(f.root.runtime.mailbox.read()?.processedProfiles, 48)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.overflowProfiles, 0)
            XCTAssertEqual(f.root.runtime.mailbox.read()?.discardedProfiles, 0)
            finish(f)
        }
    }

    func testVirtualSourceSelectionIsDocumentDerivedAndRetiresThePhysicalTarget() throws {
        let f = try sounding()
        f.root.document.selectMIDITarget(nil); wait { f.midi.opens == [1, 0] }
        XCTAssertNil(f.root.document.document.midiTarget)
        XCTAssertTrue(f.midi.messagesAtClose[0].contains { $0.first == 0x80 })
        finish(f)
    }

    func testInvalidEditorGridRejectsBeforeHistoryOrInstallation() throws {
        let f = try RootFixture(); let before = f.root.document.document
        XCTAssertThrowsError(try f.root.document.edit { $0.editorGrid = try! .build(cellSizeMeters: 0.29) })
        XCTAssertEqual(f.root.document.document, before); XCTAssertFalse(f.root.document.canUndo)
        var done = false; f.root.terminate { done = true }; wait { done }
    }
    func testDisplayReaderContinuesInTrackingModeAndKeepsOnlyTheNewestFrame() throws {
        let f = try RootFixture(); p8Ack(f)
        f.root.runtime.mailbox.write(.init(selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]), processedProfiles: 42))
        f.root.display.start()
        let until = Date().addingTimeInterval(0.15)
        while Date() < until { RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.005)) }
        XCTAssertEqual(f.root.display.frame?.processedProfiles, 42)
        f.root.display.stop(); var done = false; f.root.terminate { done = true }; wait { done }
    }

    func testLegacyViewportAppliesToVisibleCanvasWithoutDocumentRevision() throws {
        let f = try RootFixture(); let revision = f.root.document.document.revision
        let viewport = try ScanPlaneViewport.build(centerX: 0, centerY: 0.25, halfExtent: 0.2)
        f.root.document.applyLegacyPresetViewport(viewport)
        f.root.document.updateCanvasCommandContext(size: .init(width: 800, height: 800), profile: nil)
        // Owner 07.10.2026: scale is restored, the scanner stays at the bottom
        // edge of today's canvas (800 pt · 0.04095 m/pt / 2), not at the
        // height of the window the preset was saved in.
        XCTAssertEqual(f.root.document.canvas.viewport.metersPerPoint, 0.04095, accuracy: 1e-9)
        XCTAssertEqual(f.root.document.canvas.viewport.centerYMeters, 16.38, accuracy: 1e-9)
        XCTAssertEqual(f.root.document.legacyPresetViewport.halfExtent, viewport.halfExtent, accuracy: 1e-9)
        XCTAssertEqual(f.root.document.document.revision, revision)
        var done = false; f.root.terminate { done = true }; wait { done }
    }

}

private final class DeferredStageScenes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RuntimeSceneSnapshot] = []
    func append(_ scene: RuntimeSceneSnapshot) { lock.lock(); values.append(scene); lock.unlock() }
    var snapshots: [RuntimeSceneSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
}

private struct GeometryStream: ScanByteStreamOpening {
    let descriptor: FakeDescriptor
    init(_ descriptor: FakeDescriptor) { self.descriptor = descriptor }
    func openStream() throws -> any SerialPortFileDescriptor { descriptor }
}
@MainActor private final class CompositionGraph: AudioGraphBoundary {
    func fade(silent: Bool) -> UInt32 { 0 }
    func fadeReached(_ token: UInt32) -> Bool { true }
    func setMuted(_ muted: Bool) {}
    func installMeter(_ holder: PeakHolder) {}
    func removeMeter() {}
    func configure(_ configuration: AudioHostConfiguration) throws {}
    func attach(_ instance: PluginInstance, instrument: Bool) throws {}
    func remove(_ instance: PluginInstance) {}
    @discardableResult func connect(instrument: PluginInstance?, inserts: [PluginInstance]) -> AudioGraphConnectionResult { .init() }
    func setLevel(decibels: Double) {}
    func start() throws {} // Injected pure graph: never opens an audio device.
    func stop() {}
}
@MainActor private final class CompositionWindows: PluginWindowFactory {
    func make(title: String, size: NSSize) -> any PluginWindow { fatalError("Production root tests must not open real editors") }
}

private final class FakeAURelease: AUScheduleBoundary, @unchecked Sendable {
    let send = FakeSend()
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { send.send(bytes: bytes) }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
}

@MainActor private func waitCapture(_ owner: SpatialInstrumentRuntimeModel) {
    let done = DispatchSemaphore(value: 0)
    owner.roomCapture.acknowledge { done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
}

private final class CompositionFootswitchSource: MIDIClockSource, @unchecked Sendable {
    private let lock = NSLock()
    private var receive: (@Sendable (MIDIClockPacket) -> Void)?
    func bind(_ action: @escaping @Sendable (MIDIClockPacket) -> Void) { lock.lock(); receive = action; lock.unlock() }
    func press() { lock.lock(); let callback = receive; lock.unlock(); callback?(.init(bytes: [0x90, 64, 100], timestamp: 0, arrival: 0)) }
    func close() { lock.lock(); receive = nil; lock.unlock() }
}

@MainActor private final class CompositionActivityFake: PerformanceActivityBoundary {
    var begins = 0, ends = 0
    func begin() -> NSObjectProtocol { begins += 1; return NSObject() }
    func end(_ token: NSObjectProtocol) { ends += 1 }
}
