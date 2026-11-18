import XCTest
import PlanariumRuntime
import PlanariumDomain
@testable import PlanariumAudio

final class PerformanceAudioPortTests: XCTestCase {
    @MainActor func testDeviceChangeReleasesAudioAndPreservesMIDINotes() async throws {
        for native in [false, true] {
            let trace = Trace(), components = FakeComponents(), graph = FakeGraph(trace: trace)
            let runtime = PerformanceRuntime(clock: MonotonicRuntimeClock(), mailbox: DisplayFrameMailbox())
            let host = try AudioHost(components: components, graph: graph,
                runtime: PerformanceAudioPort(runtime: runtime), windows: FakeWindows(trace: trace))
            host.apply(.init(instrument: plugin()))
            let unit = FakeUnit(trace: trace), audio = HostNoteSchedule(), midi = HostNoteSchedule()
            unit.schedule = audio; components.succeed(0, unit); try host.start()
            runtime.attach(RuntimePorts.midi(boundary: midi))
            let session = UUID()
            let layer = SpatialDocumentLayer(id: UUID(), name: "Both", color: .orange, isVisible: true,
                isActive: true, isLocked: false, isSoloed: false, cells: [PolarDeviceLattice(ring: 100, sector: 180)!],
                routings: [SpatialRoutingTarget.audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), .midiNote(channel: 3)].map {
                    .init(target: $0, program: .chord(notes: [60], velocity: 100, transition: .holdUntilNext))
                }, cellOverrides: [:])
            runtime.install(try InstrumentCompiler.compile(.init(spatial: .init(latticeVersion: .polarDeviceV2,
                layers: [layer], selectedLayerID: layer.id), detection: .allStagesOff, revision: .init(session: session, counter: 1))))
            runtime.sessionBegan(session)
            runtime.frame(.init(sessionID: session, sequence: 1, time: runtime.diagnosticTime,
                measurements: [.init(order: 180, ticks: .point(180)!, rawCentimeters: 100)!]))
            let sounded = expectation(description: "sounded")
            runtime.acknowledge { sounded.fulfill() }; await fulfillment(of: [sounded], timeout: 5)
            XCTAssertEqual(midi.messages, [[0x93, 60, 100]])
            if native { graph.reportConfigurationChange() } else { host.configure(.init(sampleRate: 44_100)) }
            let changed = expectation(description: "changed")
            runtime.acknowledge { changed.fulfill() }; await fulfillment(of: [changed], timeout: 5)
            XCTAssertEqual(midi.messages, [[0x93, 60, 100]], "device change must preserve MIDI, native=\(native)")
            if !native { XCTAssertTrue(audio.messages.contains([0x80, 60, 0])) }
            if native {
                for _ in 0..<100 {
                    if audio.messages.count == 49 { break }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                XCTAssertEqual(audio.messages, [[0x90, 60, 100]] + (UInt8(0)...15).flatMap { MusicEventMIDIEncoding.releaseMessages(channel: $0) },
                    "A retained AU must be reset after restart when its stopped engine refused the old release")
            }
            let ended = expectation(description: "shutdown")
            host.shutdown { ended.fulfill() }; await fulfillment(of: [ended], timeout: 5)
            runtime.stop()
            let stopped = expectation(description: "stopped")
            runtime.acknowledge { stopped.fulfill() }; await fulfillment(of: [stopped], timeout: 5)
            XCTAssertEqual(midi.messages, [[0x93, 60, 100], [0x83, 60, 0]])
        }
    }
    /// Owner 20.10.2026 (Build 1034, iMac): arpeggiator silent with Odin and
    /// DecentSampler. The production lease hid the sample boundary from Q.
    @MainActor func testProductionLeaseForwardsSampleNotesForTheArpeggiator() throws {
        let h = try Harness(); defer { h.finish() }
        let unit = h.unit()
        let native = SampleSchedule()
        unit.schedule = native
        h.host.apply(.init(instrument: plugin()))
        h.components.succeed(0, unit)
        let lease = try XCTUnwrap(h.runtime.schedules.values.first as? any SampleNoteBoundary,
                                  "Production schedule must expose the render-clocked sample path")
        XCTAssertTrue(lease.sampleNotesAvailable)
        XCTAssertEqual(lease.enqueueSampleNote(bytes: [0x90, 60, 100], deadline: 1, immediate: true), .unbound)
        try h.host.start()
        XCTAssertEqual(lease.enqueueSampleNote(bytes: [0x90, 60, 100], deadline: 1, immediate: true), .sent)
        XCTAssertEqual(native.enqueued, 1)
        h.graph.reportConfigurationChange()
        XCTAssertEqual(lease.enqueueSampleNote(bytes: [0x80, 60, 0], deadline: 2, immediate: false), .unbound)
        lease.invalidateSampleNotes()
        XCTAssertEqual(native.invalidations, 1, "Cleanup reaches the retained instance while stopped")
    }

    @MainActor func testScheduleIsUnboundBeforeStartAndAfterNativeEngineStops() throws {
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin()))
        h.components.succeed(0, h.unit())
        let schedule = try XCTUnwrap(h.runtime.schedules.values.first)
        let parameter = SpatialAudioUnitParameterTarget(component: plugin().identity, address: 42,
            identifier: "gain", displayName: "Gain", stripID: InstrumentChannel.legacyID)
        XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x90, 60, 100]), .unbound)
        XCTAssertEqual(schedule.scheduleParameter(parameter, normalizedValue: 0.5), .unbound)
        try h.host.start()
        XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x90, 60, 100]), .sent)
        XCTAssertEqual(schedule.scheduleParameter(parameter, normalizedValue: 0.5), .sent)
        h.graph.reportConfigurationChange()
        XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x90, 60, 100]), .unbound)
        XCTAssertEqual(schedule.scheduleParameter(parameter, normalizedValue: 0.5), .unbound)
    }
    @MainActor func testHostReleaseMatrixWithSoundingHeldNoteUsesProductionRuntime() async throws {
        // Device/rate change, native callback, replacement, removal, Stop,
        // shutdown, fullState refresh and rejected instrument connection all
        // cross the real Runtime retire.
        for branch in 0..<8 {
            let trace = Trace(), components = FakeComponents(), graph = FakeGraph(trace: trace)
            let runtime = PerformanceRuntime(clock: MonotonicRuntimeClock(), mailbox: DisplayFrameMailbox())
            let host = try AudioHost(components: components, graph: graph,
                runtime: PerformanceAudioPort(runtime: runtime), windows: FakeWindows(trace: trace))
            host.apply(.init(instrument: plugin(1, state: 1)))
            let unit = FakeUnit(trace: trace), schedule = HostNoteSchedule()
            unit.schedule = schedule; components.succeed(0, unit); try host.start()
            let old = try XCTUnwrap(host.instrument), session = UUID()
            let layer = SpatialDocumentLayer(id: UUID(), name: "Held note", color: .orange, isVisible: true,
                isActive: true, isLocked: false, isSoloed: false, cells: [PolarDeviceLattice(ring: 100, sector: 180)!],
                routings: [.init(target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), program: .chord(notes: [60], velocity: 100, transition: .holdUntilNext))],
                cellOverrides: [:])
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
            runtime.install(try InstrumentCompiler.compile(.init(spatial: spatial, detection: .allStagesOff,
                revision: .init(session: session, counter: 1))))
            runtime.sessionBegan(session)
            runtime.frame(.init(sessionID: session, sequence: 1, time: runtime.diagnosticTime,
                measurements: [.init(order: 180, ticks: .point(180)!, rawCentimeters: 100)!]))
            let sounded = expectation(description: "Q sounded branch \(branch)")
            runtime.acknowledge { sounded.fulfill() }
            await fulfillment(of: [sounded], timeout: 5)
            XCTAssertEqual(schedule.messages, [[0x90, 60, 100]])
            switch branch {
            case 0: host.configure(.init(sampleRate: 44_100))
            case 1: graph.reportConfigurationChange()
            case 2: host.apply(.init(instrument: plugin(2)))
            case 3: host.apply(.init())
            case 4: host.stop()
            case 5: host.shutdown()
            case 6: host.apply(.init(instrument: plugin(1, state: 2)))
            default:
                graph.connectionFailures[plugin().identity] = .init("Instrument connection refused")
                host.apply(host.channel)
            }
            let released = expectation(description: "Q released branch \(branch)")
            runtime.acknowledge { released.fulfill() }
            await fulfillment(of: [released], timeout: 5)
            // A native stop cannot accept Off/CC123. Its retired receipt must
            // report unbound rather than manufacture successful sends.
            if branch == 1 {
                for _ in 0..<100 {
                    if schedule.messages.count == 49 { break }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            let expected: [[UInt8]] = branch == 1 ? [[0x90, 60, 100]] + (UInt8(0)...15).flatMap { MusicEventMIDIEncoding.releaseMessages(channel: $0) } :
                [[0x90, 60, 100], [0x80, 60, 0]] +
                (branch == 0 ? (UInt8(0)...15).map { [0xB0 | $0, 123, 0] } : [])
            XCTAssertEqual(schedule.messages, expected, "branch \(branch)")
            if graph.transitionSilent { graph.reportFadeReached() }
            for _ in 0..<100 {
                if !graph.transitionSilent { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertFalse(graph.transitionSilent)
            if branch == 2 || branch == 3 || branch == 5 || branch == 7 { XCTAssertNil(old.unit) }
            else { XCTAssertTrue(host.instrument === old) }
            let done = expectation(description: "shutdown branch \(branch)")
            host.shutdown { done.fulfill() }
            await fulfillment(of: [done], timeout: 5)
        }
    }
    @MainActor func testProductionRuntimeRetireAckIsTheGraphReleaseBoundary() async throws {
        let trace = Trace(), components = FakeComponents()
        let graph = FakeGraph(trace: trace), windows = FakeWindows(trace: trace)
        let mailbox = DisplayFrameMailbox()
        let runtime = PerformanceRuntime(clock: MonotonicRuntimeClock(), mailbox: mailbox)
        let host = try AudioHost(components: components, graph: graph,
            runtime: PerformanceAudioPort(runtime: runtime), windows: windows)
        host.apply(.init(instrument: plugin()))
        components.succeed(0, FakeUnit(trace: trace))
        let old = try XCTUnwrap(host.instrument)
        old.openEditor(title: "fake")
        host.apply(.init(instrument: plugin(2)))
        // Main has not yielded, so even if Q has already released its port,
        // its asynchronous acknowledgement cannot have freed the graph.
        XCTAssertNotNil(old.unit); XCTAssertNotNil(old.editor)
        XCTAssertTrue(graph.attached.contains(old.id))
        for _ in 0..<1000 {
            if old.unit == nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(old.unit); XCTAssertNil(old.editor)
        XCTAssertFalse(graph.attached.contains(old.id))
        XCTAssertEqual(mailbox.read()?.retiredPort?.id, old.id)
        XCTAssertEqual(mailbox.read()?.retiredPort?.soundingNotes, 0)
        XCTAssertEqual(components.requests.count, 2)
        components.succeed(1, FakeUnit(trace: trace))
        let completion = expectation(description: "shutdown acknowledged")
        host.shutdown { completion.fulfill() }
        await fulfillment(of: [completion], timeout: 5)
        XCTAssertNil(host.instrument); XCTAssertTrue(graph.attached.isEmpty)
    }
}

private final class HostNoteSchedule: AUScheduleBoundary, MIDISendBoundary, @unchecked Sendable {
    func send(bytes: [UInt8]) -> PortSendResult { scheduleMIDI(bytes: bytes) }
    private let lock = NSLock()
    private var log: [[UInt8]] = []
    var messages: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return log }
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult {
        lock.lock(); log.append(bytes); lock.unlock(); return .sent
    }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
}

private final class SampleSchedule: AUScheduleBoundary, PlannedNoteBoundary, SampleNoteBoundary, @unchecked Sendable {
    private let lock = NSLock()
    private var enqueuedCount = 0, invalidationCount = 0
    var enqueued: Int { lock.lock(); defer { lock.unlock() }; return enqueuedCount }
    var invalidations: Int { lock.lock(); defer { lock.unlock() }; return invalidationCount }
    var planningLead: Double { 0 }
    func permitsNoteOn(bytes: [UInt8], now: Double) -> Bool { true }
    func sendPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult { .sent }
    func cancelPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult { .sent }
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { .sent }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
    func enqueueSampleNote(bytes: [UInt8], deadline: Double, immediate: Bool) -> PortSendResult {
        lock.lock(); enqueuedCount += 1; lock.unlock(); return .sent
    }
    func invalidateSampleNotes() { lock.lock(); invalidationCount += 1; lock.unlock() }
}
