import AudioToolbox
import AVFoundation
import XCTest
import PlanariumDomain
import PlanariumRuntime
import PlanariumHostClockDSP
import PlanariumMIDI
@testable import PlanariumAudio

private struct MusicalReceipt {
    var tempo = 0.0, numerator = 0.0, denominator = 0, beat = 0.0, offset = 0, downbeat = 0.0
    var flags = AUHostTransportStateFlags(), sample = 0.0
    var calls = 0, valid = false
}
private final class NoteAnchorReader: @unchecked Sendable {
    let binding: PlanariumNoteRenderBinding
    var lastSample = -Double.infinity // worker-owned until its semaphore signal
    init(_ binding: PlanariumNoteRenderBinding) { self.binding = binding }
}
// A registered in-process instrument: its real render asks the host blocks.
// The recorder is preallocated and read only after synchronous offline render.
private final class ContextProbeAU: AUAudioUnit {
    private var outs: AUAudioUnitBusArray!
    let receipt = UnsafeMutablePointer<MusicalReceipt>.allocate(capacity: 1)
    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        receipt.initialize(to: MusicalReceipt())
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        outs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
    }
    deinit { receipt.deinitialize(count: 1); receipt.deallocate() }
    override var outputBusses: AUAudioUnitBusArray { outs }
    override func allocateRenderResources() throws {
        guard musicalContextBlock != nil, transportStateBlock != nil else { throw PluginLoadError("Host blocks missing before allocation") }
        try super.allocateRenderResources()
    }
    override var internalRenderBlock: AUInternalRenderBlock {
        let musical = musicalContextBlock, transport = transportStateBlock, receipt = receipt
        return { _, _, frames, _, data, _, _ in
            receipt.pointee.valid = musical?(&receipt.pointee.tempo, &receipt.pointee.numerator,
                &receipt.pointee.denominator, &receipt.pointee.beat, &receipt.pointee.offset, &receipt.pointee.downbeat) == true
            receipt.pointee.valid = receipt.pointee.valid && transport?(&receipt.pointee.flags, &receipt.pointee.sample, nil, nil) == true
            receipt.pointee.calls += 1
            for buffer in UnsafeMutableAudioBufferListPointer(data) {
                if let p = buffer.mData { memset(p, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }
}

private final class MusicalTestClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = 10.0
    private var tasks: [UUID: (Double, DispatchQueue, @Sendable () -> Void)] = [:]
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) {
        lock.lock(); time += seconds
        let due = tasks.filter { $0.value.0 <= time }
        due.keys.forEach { tasks[$0] = nil }; lock.unlock()
        due.values.forEach { $0.1.async(execute: $0.2) }
    }
    func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation {
        let id = UUID(); lock.lock(); tasks[id] = (deadline, queue, action); lock.unlock()
        return RuntimeCancellation { [weak self] in self?.cancel(id) }
    }
    private func cancel(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
}
private final class MusicalTestSource: MIDIClockSource, @unchecked Sendable {
    let receive: @Sendable (MIDIClockPacket) -> Void
    init(_ receive: @escaping @Sendable (MIDIClockPacket) -> Void) { self.receive = receive }
    func close() {}
}
@MainActor private final class ContextProbeSource: PluginComponentSource {
    var nodes: [SpatialAudioUnitIdentity: AVAudioUnit] = [:]
    func load(_ identity: SpatialAudioUnitIdentity,
              completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        if let node = nodes[identity] { completion(.success(SystemPluginUnit(unit: node))) }
        else { completion(.failure(PluginLoadError("Probe missing"))) }
    }
}

@MainActor final class HostClockOfflineTests: XCTestCase {
    func testAUv2RetirementReleasesNativeNodeAfterCallbackCleanup() throws {
        let graph = AVAudioGraph(); try graph.configure(.init(offline: true))
        weak var nativeNode: AVAudioUnit?
        func makeUnaliasedInstance() -> PluginInstance {
            let node = AVAudioUnitDelay(), d = node.audioComponentDescription
            nativeNode = node
            return PluginInstance(identity: .init(componentType: d.componentType, componentSubType: d.componentSubType,
                componentManufacturer: d.componentManufacturer), unit: SystemPluginUnit(unit: node), windows: FakeWindows(trace: Trace()))
        }
        for explicitRelease in [false, true] {
            var instance: PluginInstance? = makeUnaliasedInstance()
            try graph.attach(try XCTUnwrap(instance), instrument: false)
            graph.remove(try XCTUnwrap(instance))
            // No external strong AVAudioUnit reference keeps its AUv2 handle
            // alive. Cover explicit release and implicit property teardown.
            if explicitRelease { instance?.finishRelease() }
            instance = nil
            XCTAssertNil(nativeNode, "The callback owner must neither die early nor leak")
        }
        graph.close()
    }
    private func instantiate(_ sub: OSType = 0x544d5033) throws -> AVAudioUnit {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice, componentSubType: sub,
            componentManufacturer: 0x506c6e6d, componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.registerSubclass(ContextProbeAU.self, as: desc, name: "Planarium: Context Probe", version: 1)
        let construction = FadeConstruction()
        AVAudioUnit.instantiate(with: desc, options: []) { unit, error in construction.complete(unit, error) }
        return try construction.take()
    }
    private func attach(_ node: AVAudioUnit, to graph: AVAudioGraph) throws -> PluginInstance {
        let desc = node.audioComponentDescription
        let instance = PluginInstance(identity: .init(componentType: desc.componentType, componentSubType: desc.componentSubType,
            componentManufacturer: desc.componentManufacturer), unit: SystemPluginUnit(unit: node), windows: FakeWindows(trace: Trace()))
        try graph.attach(instance, instrument: true)
        XCTAssertNotNil(node.auAudioUnit.musicalContextBlock)
        XCTAssertNotNil(node.auAudioUnit.transportStateBlock)
        XCTAssertNil(graph.connect(instrument: instance, inserts: []).failure)
        return instance
    }
    private func render(_ graph: AVAudioGraph, _ node: AVAudioUnit, frames: UInt32 = 480) throws -> MusicalReceipt {
        let probe = try XCTUnwrap(node.auAudioUnit as? ContextProbeAU)
        let calls = probe.receipt.pointee.calls
        _ = try graph.renderOffline(frames: frames)
        XCTAssertGreaterThan(probe.receipt.pointee.calls, calls)
        let receipt = probe.receipt.pointee
        XCTAssertTrue(receipt.valid)
        XCTAssertEqual(receipt.numerator, 4); XCTAssertEqual(receipt.denominator, 4)
        XCTAssertEqual(receipt.downbeat, floor(receipt.beat / 4) * 4)
        return receipt
    }
    func testNoteObserverPublishesActualVariableBlockLengthWithoutStartingHardware() throws {
        let graph = AVAudioGraph(); try graph.configure(.init(offline: true))
        let node = try instantiate(); _ = try attach(node, to: graph)
        let binding = try XCTUnwrap(PlanariumNoteRenderBinding(unit: node.auAudioUnit, owner: node))
        XCTAssertEqual(binding.readAnchor().frames, 0)
        try graph.start()
        _ = try graph.renderOffline(frames: 480)
        let first = binding.readAnchor()
        XCTAssertEqual(first.frames, 480)
        XCTAssertEqual(first.rate, 48_000)
        _ = try graph.renderOffline(frames: 128)
        let second = binding.readAnchor()
        XCTAssertEqual(second.frames, 128)
        XCTAssertGreaterThan(second.sample, first.sample)
        graph.close()
        // The mailbox's native node owner remains alive until the observer
        // has been removed by binding teardown, even after graph removal.
        withExtendedLifetime(binding) {}
    }
    func testNoteObserverAnchorCanBeReadConcurrentlyWithVariableOfflineRendering() throws {
        let graph = AVAudioGraph(); try graph.configure(.init(offline: true))
        let node = try instantiate(); _ = try attach(node, to: graph)
        let binding = try XCTUnwrap(PlanariumNoteRenderBinding(unit: node.auAudioUnit, owner: node))
        try graph.start(); _ = try graph.renderOffline(frames: 480)
        let initialSample = binding.readAnchor().sample
        let reader = NoteAnchorReader(binding), done = DispatchSemaphore(value: 0)
        let beginReading = DispatchSemaphore(value: 0)
        defer { beginReading.signal(); graph.close() }
        DispatchQueue(label: "note-anchor-reader").async {
            beginReading.wait()
            for _ in 0..<10_000 {
                let anchor = reader.binding.readAnchor()
                if anchor.frames != 0 {
                    XCTAssertTrue(anchor.frames == 128 || anchor.frames == 480)
                    XCTAssertEqual(anchor.rate, 48_000)
                    XCTAssertTrue(anchor.sample.isFinite)
                    reader.lastSample = max(reader.lastSample, anchor.sample)
                }
            }
            done.signal()
        }
        _ = try graph.renderOffline(frames: 128)
        beginReading.signal()
        for i in 0..<200 { _ = try graph.renderOffline(frames: i.isMultiple(of: 2) ? 128 : 480) }
        guard done.wait(timeout: .now() + 10) == .success else { XCTFail("Anchor reader timeout"); return }
        XCTAssertGreaterThan(reader.lastSample, initialSample)
        graph.close()
    }
    func testSendSamplePositionTempoContinuityStopOffAndNewInstancesThroughNativeGraph() throws {
        let clock = HostMusicalClock(), graph = AVAudioGraph()
        graph.setHostMusicalClock(clock); try graph.configure(.init(offline: true))
        let node = try instantiate(), instance = try attach(node, to: graph)
        defer { graph.close() }
        clock.configure(.send, documentTempo: 120, at: 10)
        clock.updateInternal(tempo: 120, at: 10, playing: true, reset: true)
        try graph.start()
        let first = try render(graph, node)
        XCTAssertEqual(first.tempo, 120); XCTAssertEqual(first.beat, 0, accuracy: 1e-10)
        XCTAssertTrue(first.flags.contains(.moving)); XCTAssertTrue(first.flags.contains(.changed))
        let second = try render(graph, node)
        XCTAssertEqual(second.beat - first.beat, (second.sample - first.sample) / 48_000 * 2, accuracy: 1e-10)
        XCTAssertFalse(second.flags.contains(.changed))
        clock.updateInternal(tempo: 90, at: 10.02)
        let changed = try render(graph, node)
        XCTAssertEqual(changed.tempo, 90); XCTAssertEqual(changed.beat, 0.04, accuracy: 1e-10)
        let next = try render(graph, node)
        XCTAssertEqual(next.beat - changed.beat, (next.sample - changed.sample) / 48_000 * 1.5, accuracy: 1e-10)
        XCTAssertFalse(next.flags.contains(.changed))
        clock.updateInternal(tempo: 90, at: 10.04, playing: false)
        let stopped = try render(graph, node)
        XCTAssertFalse(stopped.flags.contains(.moving)); XCTAssertTrue(stopped.flags.contains(.changed))
        XCTAssertEqual(try render(graph, node).beat, stopped.beat, accuracy: 1e-10)
        clock.configure(.off, documentTempo: 135, at: 10.06)
        let off = try render(graph, node)
        XCTAssertEqual(off.tempo, 135); XCTAssertFalse(off.flags.contains(.moving))
        graph.stop(); graph.remove(instance)
        let replacement = try instantiate(0x544d5034)
        _ = try attach(replacement, to: graph); try graph.start()
        XCTAssertEqual(try render(graph, replacement).tempo, 135)
    }
    func testReceivePacketClockAndLossArePublishedWithoutMainDelivery() throws {
        let clock = HostMusicalClock(), fake = MusicalTestClock(), graph = AVAudioGraph()
        graph.setHostMusicalClock(clock); try graph.configure(.init(offline: true))
        let node = try instantiate(), instance = try attach(node, to: graph)
        _ = instance
        defer { graph.close() }
        clock.configure(.receive, documentTempo: 200, at: fake.now)
        let holder = SourceHolder()
        let input = MIDIClockReceiver(clock: fake, factory: { _, receive, _ in
            let source = MusicalTestSource(receive); holder.store(source); return source
        }, hostClock: clock)
        input.configure(sourceID: 2)
        let ready = expectation(description: "input")
        input.acknowledge { ready.fulfill() }; wait(for: [ready], timeout: 2)
        let source = try XCTUnwrap(holder.take())
        source.receive(.init(bytes: [0xfa], timestamp: fake.now, arrival: fake.now))
        for _ in 0..<25 {
            fake.advance(60 / (90 * 24))
            source.receive(.init(bytes: [0xf8], timestamp: fake.now, arrival: fake.now))
        }
        let accepted = expectation(description: "ticks")
        input.acknowledge { accepted.fulfill() }; wait(for: [accepted], timeout: 2)
        XCTAssertEqual(input.snapshot.tickCount, 25)
        try graph.start()
        let running = try render(graph, node)
        XCTAssertEqual(running.tempo, 90, accuracy: 1e-8)
        XCTAssertEqual(running.beat, 25.0 / 24, accuracy: 1e-8)
        XCTAssertTrue(running.flags.contains(.moving))
        XCTAssertGreaterThan(try render(graph, node).beat, running.beat)
        fake.advance(0.02)
        source.receive(.init(bytes: [0xfa], timestamp: fake.now, arrival: fake.now))
        let restarted = expectation(description: "start again")
        input.acknowledge { restarted.fulfill() }; wait(for: [restarted], timeout: 2)
        let startAgain = try render(graph, node)
        XCTAssertEqual(startAgain.beat, 0, accuracy: 1e-8)
        XCTAssertTrue(startAgain.flags.contains(.moving)); XCTAssertTrue(startAgain.flags.contains(.changed))
        XCTAssertFalse(try render(graph, node).flags.contains(.changed))
        fake.advance(120 / 90 + 0.01)
        let lost = expectation(description: "lost")
        input.acknowledge { lost.fulfill() }; wait(for: [lost], timeout: 2)
        let stopped = try render(graph, node)
        XCTAssertTrue(input.snapshot.isLost)
        XCTAssertFalse(stopped.flags.contains(.moving)); XCTAssertTrue(stopped.flags.contains(.changed))
        XCTAssertEqual(stopped.tempo, 90, accuracy: 1e-8)
        XCTAssertEqual(try render(graph, node).beat, stopped.beat, accuracy: 1e-8)
        input.disconnect()
    }
    func testAUv2BridgeInstallsAllLegacyHostCallbacks() throws {
        let graph = AVAudioGraph(), clock = HostMusicalClock()
        graph.setHostMusicalClock(clock); try graph.configure(.init(offline: true))
        let node = AVAudioUnitDelay()
        let desc = node.audioComponentDescription
        let instance = PluginInstance(identity: .init(componentType: desc.componentType, componentSubType: desc.componentSubType,
            componentManufacturer: desc.componentManufacturer), unit: SystemPluginUnit(unit: node), windows: FakeWindows(trace: Trace()))
        try graph.attach(instance, instrument: false)
        defer { graph.close() }
        var callbacks = HostCallbackInfo(), size = UInt32(MemoryLayout<HostCallbackInfo>.size)
        XCTAssertEqual(AudioUnitGetProperty(node.audioUnit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &callbacks, &size), noErr)
        XCTAssertNotNil(callbacks.beatAndTempoProc); XCTAssertNotNil(callbacks.musicalTimeLocationProc)
        XCTAssertNotNil(callbacks.transportStateProc); XCTAssertNotNil(callbacks.transportStateProc2)
        var tempo = 0.0, beat = 0.0
        XCTAssertEqual(callbacks.beatAndTempoProc?(callbacks.hostUserData, &beat, &tempo), noErr)
        XCTAssertEqual(tempo, 120)
        let instrumentNode = try instantiate(), instrument = try attach(instrumentNode, to: graph)
        XCTAssertNil(graph.connect(instrument: instrument, inserts: [instance]).failure)
        clock.configure(.send, documentTempo: 96, at: 10)
        clock.updateInternal(tempo: 96, at: 10, playing: true, reset: true)
        try graph.start()
        let rendered = try render(graph, instrumentNode)
        XCTAssertEqual(callbacks.beatAndTempoProc?(callbacks.hostUserData, &beat, &tempo), noErr)
        XCTAssertEqual(tempo, 96); XCTAssertEqual(beat, rendered.beat, accuracy: 1e-10)
        let next = try render(graph, instrumentNode)
        XCTAssertEqual(callbacks.beatAndTempoProc?(callbacks.hostUserData, &beat, &tempo), noErr)
        XCTAssertEqual(beat, next.beat, accuracy: 1e-10)
        XCTAssertGreaterThan(beat, rendered.beat)
    }
    func testConcurrentPublicationKeepsRenderSnapshotsCoherentAndTransportChangedIsConsumedOnce() throws {
        let graph = AVAudioGraph(), clock = HostMusicalClock()
        graph.setHostMusicalClock(clock); try graph.configure(.init(offline: true))
        let node = try instantiate(); _ = try attach(node, to: graph)
        defer { graph.close() }
        clock.configure(.receive, documentTempo: 120, at: 10)
        let producer = DispatchQueue(label: "host-clock-test-writer"), done = DispatchSemaphore(value: 0)
        producer.async {
            for i in 1...10_000 {
                // Offsets encode the same generation in tempo and frozen beat.
                let tempo = i.isMultiple(of: 2) ? 90.0 : 150.0
                clock.updateExternal(tempo: tempo, beat: tempo, at: 10, playing: false)
            }
            done.signal()
        }
        try graph.start()
        for _ in 0..<200 {
            let value = try render(graph, node)
            if value.tempo != 120 { XCTAssertEqual(value.beat, value.tempo) }
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        clock.updateExternal(tempo: 150, beat: 4, at: 10, playing: true)
        XCTAssertTrue(try render(graph, node).flags.contains(.changed))
        var flags = AUHostTransportStateFlags()
        XCTAssertTrue(node.auAudioUnit.transportStateBlock?(&flags, nil, nil, nil) == true)
        XCTAssertFalse(flags.contains(.changed), "A second query must not replay the transition")
        XCTAssertTrue(node.auAudioUnit.musicalContextBlock?(nil, nil, nil, nil, nil, nil) == true)
        clock.updateExternal(tempo: 150, beat: 4, at: 10, playing: false)
        XCTAssertTrue(try render(graph, node).flags.contains(.changed))
        XCTAssertFalse(try render(graph, node).flags.contains(.changed))
    }
    func testAudioHostPresetReplacementKeepsClockBinding() throws {
        let source = ContextProbeSource(), graph = AVAudioGraph(), trace = Trace(), runtime = FakeRuntime(trace: trace)
        let host = try AudioHost(components: source, graph: graph, runtime: runtime, windows: FakeWindows(trace: trace),
                                 configuration: .init(offline: true))
        func pluginFor(_ node: AVAudioUnit) -> InstrumentPlugin {
            let d = node.audioComponentDescription
            let identity = SpatialAudioUnitIdentity(componentType: d.componentType, componentSubType: d.componentSubType,
                                                   componentManufacturer: d.componentManufacturer)
            source.nodes[identity] = node
            return .init(identity: identity)
        }
        let first = try instantiate(), replacement = try instantiate(0x544d5034)
        var channel = host.channel; channel.instrument = pluginFor(first)
        let replacementPlugin = pluginFor(replacement)
        try host.applyMixer([channel], masterLevelDecibels: 0)
        host.hostMusicalClock.configure(.send, documentTempo: 120, at: 10)
        host.hostMusicalClock.updateInternal(tempo: 120, at: 10, playing: true, reset: true)
        try host.start()
        _ = try render(graph, first)
        _ = try render(graph, first)
        host.stop()
        for i in runtime.acknowledgements.indices { runtime.ack(i) }
        channel.instrument = replacementPlugin
        host.hostMusicalClock.updateInternal(tempo: 75, at: 10.02)
        try host.applyMixer([channel], masterLevelDecibels: 0, restoringPluginStates: true)
        for i in runtime.acknowledgements.indices { runtime.ack(i) }
        XCTAssertNil(first.auAudioUnit.musicalContextBlock)
        XCTAssertNotNil(replacement.auAudioUnit.musicalContextBlock)
        try host.start()
        let replaced = try render(graph, replacement)
        XCTAssertEqual(replaced.tempo, 75); XCTAssertTrue(replaced.flags.contains(.moving))
        host.stop()
        for i in runtime.acknowledgements.indices { runtime.ack(i) }
        host.shutdown()
        for i in runtime.acknowledgements.indices { runtime.ack(i) }
        XCTAssertNil(replacement.auAudioUnit.musicalContextBlock)
    }
    func testMixerBranchesRenderTheSameBeatAndTempo() async throws {
        let source = ContextProbeSource(), graph = AVAudioGraph(), trace = Trace(), runtime = FakeRuntime(trace: trace)
        let host = try AudioHost(components: source, graph: graph, runtime: runtime, windows: FakeWindows(trace: trace),
                                 configuration: .init(offline: true))
        func pluginFor(_ node: AVAudioUnit) -> InstrumentPlugin {
            let d = node.audioComponentDescription
            let identity = SpatialAudioUnitIdentity(componentType: d.componentType, componentSubType: d.componentSubType,
                                                   componentManufacturer: d.componentManufacturer)
            source.nodes[identity] = node; return .init(identity: identity)
        }
        let first = try instantiate(), second = try instantiate(0x544d5035)
        var channel = host.channel; channel.instrument = pluginFor(first)
        let other = InstrumentChannel(instrument: pluginFor(second), id: UUID())
        try host.applyMixer([channel, other], masterLevelDecibels: 0)
        XCTAssertTrue(try XCTUnwrap(host.host(for: other.id)).hostMusicalClock === host.hostMusicalClock)
        host.hostMusicalClock.configure(.send, documentTempo: 120, at: 10)
        host.hostMusicalClock.updateInternal(tempo: 120, at: 10, playing: true, reset: true)
        try host.start()
        for _ in 0..<5 {
            let value = try render(graph, first)
            let sibling = (second.auAudioUnit as! ContextProbeAU).receipt.pointee
            XCTAssertEqual(sibling.tempo, value.tempo); XCTAssertEqual(sibling.beat, value.beat, accuracy: 1e-10)
        }
        host.hostMusicalClock.updateInternal(tempo: 75, at: 10.05)
        let changed = try render(graph, first)
        XCTAssertEqual((second.auAudioUnit as! ContextProbeAU).receipt.pointee.beat, changed.beat, accuracy: 1e-10)
        XCTAssertEqual(changed.tempo, 75)
        // Exercise the production retire -> render fade -> new AU path while
        // the sibling keeps rendering, without stopping a physical engine.
        let replacement = try instantiate(0x544d5034)
        channel.instrument = pluginFor(replacement)
        try host.applyMixer([channel, other], masterLevelDecibels: 0, restoringPluginStates: true)
        for i in runtime.acknowledgements.indices { runtime.ack(i) }
        for _ in 0..<100 {
            if host.instrument?.identity == channel.instrument?.identity { break }
            _ = try graph.renderOffline(frames: 480)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(host.instrument?.identity, channel.instrument?.identity)
        let replaced = try render(graph, replacement)
        XCTAssertEqual(replaced.tempo, 75)
        XCTAssertEqual((second.auAudioUnit as! ContextProbeAU).receipt.pointee.beat, replaced.beat, accuracy: 1e-10)
        host.stop(); for i in runtime.acknowledgements.indices { runtime.ack(i) }
        host.shutdown(); for i in runtime.acknowledgements.indices { runtime.ack(i) }
    }
    func testScheduledStartAndTempoBoundaryUseRenderSamplesWithoutAnEarlyTransition() throws {
        let clock = HostMusicalClock(), graph = AVAudioGraph()
        graph.setHostMusicalClock(clock); try graph.configure(.init(offline: true))
        let node = try instantiate(); _ = try attach(node, to: graph)
        defer { graph.close() }
        clock.configure(.send, documentTempo: 120, at: 10)
        try graph.start(); _ = try render(graph, node)
        clock.updateInternal(tempo: 120, at: 10.05, playing: true, reset: true)
        for _ in 0..<4 {
            let early = try render(graph, node)
            XCTAssertEqual(early.beat, 0); XCTAssertFalse(early.flags.contains(.moving)); XCTAssertFalse(early.flags.contains(.changed))
        }
        let started = try render(graph, node)
        XCTAssertEqual(started.beat, 0, accuracy: 1e-10)
        XCTAssertTrue(started.flags.contains(.moving)); XCTAssertTrue(started.flags.contains(.changed))
        clock.updateInternal(tempo: 90, at: 10.08, observedAt: 10.05)
        clock.updateInternal(tempo: 150, at: 10.08, observedAt: 10.05)
        for _ in 0..<2 { XCTAssertEqual(try render(graph, node).tempo, 120) }
        let changed = try render(graph, node)
        XCTAssertEqual(changed.tempo, 150); XCTAssertEqual(changed.beat, 0.06, accuracy: 1e-10)
        XCTAssertFalse(changed.flags.contains(.changed))
    }
    func testRetainedAUAndItsCachedHostBlockSurviveGraphReallocation() throws {
        let clock = HostMusicalClock(), graph = AVAudioGraph()
        graph.setHostMusicalClock(clock); try graph.configure(.init(offline: true))
        let node = try instantiate(), instance = try attach(node, to: graph)
        let noteBinding = try XCTUnwrap(PlanariumNoteRenderBinding(unit: node.auAudioUnit, owner: node))
        defer { graph.close() }
        clock.configure(.send, documentTempo: 120, at: 10)
        clock.updateInternal(tempo: 120, at: 10, playing: true, reset: true)
        try graph.start(); _ = try render(graph, node)
        let cached = try XCTUnwrap(node.auAudioUnit.musicalContextBlock)
        try graph.configure(.init(sampleRate: 44_100, offline: true))
        try graph.attach(instance, instrument: true)
        noteBinding.configureSampleRate(44_100)
        graph.connect(instrument: instance, inserts: [])
        clock.updateInternal(tempo: 150, at: 10.01)
        try graph.start()
        let value = try render(graph, node, frames: 441)
        XCTAssertEqual(noteBinding.readAnchor().frames, 441)
        XCTAssertEqual(noteBinding.readAnchor().rate, 44_100)
        var tempo = 0.0, beat = 0.0
        XCTAssertTrue(cached(&tempo, nil, nil, &beat, nil, nil))
        XCTAssertEqual(tempo, 150); XCTAssertEqual(beat, value.beat, accuracy: 1e-10)
        let next = try render(graph, node, frames: 441)
        XCTAssertEqual(next.beat - value.beat, (next.sample - value.sample) / 44_100 * 2.5, accuracy: 1e-10)
    }
}
private final class SourceHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var source: MusicalTestSource?
    func store(_ source: MusicalTestSource) { lock.lock(); self.source = source; lock.unlock() }
    func take() -> MusicalTestSource? { lock.lock(); defer { lock.unlock() }; return source }
}
