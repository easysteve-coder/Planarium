import AVFoundation
import XCTest
import PlanariumDomain
@testable import PlanariumAudio

@MainActor final class InstrumentFadeTests: XCTestCase {
    func testFadeWaitDoesNotPollGraphOnMain() async throws {
        let h = try loaded(); defer { h.finish() }
        let old = try XCTUnwrap(h.host.instrument)
        h.host.apply(.init(instrument: plugin(2))); h.runtime.ack()
        try await Task.sleep(nanoseconds: 25_000_000)
        XCTAssertNotNil(old.unit)
        XCTAssertEqual(h.graph.mainFadeQueries, 0, "Main must only receive the final fade completion")
        h.graph.reportFadeReached()
        try await drain { old.unit == nil }
        XCTAssertEqual(h.graph.mainFadeQueries, 0)
    }
    private func loaded() throws -> Harness {
        let h = try Harness()
        h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit())
        try h.host.start()
        return h
    }
    private func drain(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(predicate())
    }
    func testReplacementRetireThenSilenceThenDetachThenRestore() async throws {
        let h = try loaded(); defer { h.finish() }
        let old = try XCTUnwrap(h.host.instrument)
        h.trace.events.removeAll()
        h.host.apply(.init(instrument: plugin(2))); h.runtime.ack()
        XCTAssertEqual(h.trace.events, ["retire", "ack", "fade-0"])
        XCTAssertNotNil(old.unit); XCTAssertTrue(h.graph.attached.contains(old.id))
        XCTAssertEqual(h.components.requests.count, 1)
        h.graph.reportFadeReached()
        try await drain { old.unit == nil }
        let events = h.trace.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "fade-reached")), try XCTUnwrap(events.firstIndex(of: "graph-remove")))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "graph-remove")), try XCTUnwrap(events.firstIndex(of: "fade-1")))
        h.components.succeed(1, h.unit())
        XCTAssertTrue(h.host.isRunning); XCTAssertFalse(h.graph.transitionSilent)
    }
    func testReplacementFadeTimeoutIsBoundedAndLatestIdentityWins() async throws {
        let h = try loaded(); defer { h.finish() }
        let old = try XCTUnwrap(h.host.instrument)
        h.host.apply(.init(instrument: plugin(2))); let start = Date(); h.runtime.ack()
        h.host.apply(.init(instrument: plugin(3)))
        XCTAssertNotNil(old.unit); XCTAssertEqual(h.graph.fadeRequests, [true])
        try await drain { old.unit == nil }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.075); XCTAssertLessThan(elapsed, 0.2)
        XCTAssertEqual(h.components.requests[1].identity, plugin(3).identity)
        XCTAssertEqual(h.graph.fadeRequests, [true, false])
        print("AUDIO-HOST-1 instrument fade no-render timeout=\(elapsed)s, configured bound=80ms")
    }
    func testShutdownStopAndConfigurationDuringAcknowledgedFadeInBothOrders() async throws {
        for branch in 0..<3 {
            for fadeFirst in [true, false] {
                let h = try loaded(); defer { h.finish() }
                let old = try XCTUnwrap(h.host.instrument)
                h.host.apply(.init(instrument: plugin(2)))
                if fadeFirst { h.runtime.ack() }
                switch branch {
                case 0: h.host.shutdown()
                case 1: h.host.stop()
                default: h.graph.reportConfigurationChange()
                }
                if !fadeFirst { h.runtime.ack() }
                try await drain { old.unit == nil }
                XCTAssertFalse(h.graph.transitionSilent)
                XCTAssertEqual(h.host.isRunning, branch == 2)
                let connections = h.graph.connections
                try await Task.sleep(nanoseconds: 90_000_000)
                XCTAssertEqual(h.graph.connections, connections, "Cancelled fade never rewires a later graph")
            }
        }
    }
    func testStoppedReplacementHasNoFadeWait() throws {
        let h = try Harness(); defer { h.finish() }
        h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit())
        let old = try XCTUnwrap(h.host.instrument)
        h.host.apply(.init(instrument: plugin(2))); h.runtime.ack()
        XCTAssertNil(old.unit); XCTAssertTrue(h.graph.fadeRequests.isEmpty)
    }

    func testSineInstrumentReplacementOfflineStaysWithinTwoSignalSteps() async throws {
        let engine = AVAudioEngine(), graph = AVAudioGraph(makeEngine: { engine }, selectDevice: { _, _ in })
        let trace = Trace(), runtime = FakeRuntime(trace: trace), components = SineInstrumentComponents()
        let host = try AudioHost(components: components, graph: graph, runtime: runtime,
            windows: FakeWindows(trace: trace), configuration: .init(offline: true))
        let phase = UnsafeMutablePointer<Double>.allocate(capacity: 1); phase.initialize(to: .pi / 2)
        defer { host.shutdown(); runtime.ack(runtime.acknowledgements.count - 1); phase.deinitialize(count: 1); phase.deallocate() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        func source(to node: AVAudioUnit) -> AVAudioSourceNode {
            let source = AVAudioSourceNode(format: format) { _, _, frames, list in
                for i in 0..<Int(frames) {
                    let sample = Float(0.25 * sin(phase.pointee)); phase.pointee += 2 * .pi * 440 / 48_000
                    for buffer in UnsafeMutableAudioBufferListPointer(list) { buffer.mData!.assumingMemoryBound(to: Float.self)[i] = sample }
                }
                return noErr
            }
            engine.attach(source); engine.connect(source, to: node, format: format)
            return source
        }
        func samples(_ count: UInt32) throws -> [Float] {
            let buffer = try graph.renderOffline(frames: count)
            return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        }
        func jump(_ signal: [Float]) -> Float { zip(signal, signal.dropFirst()).map { abs($0 - $1) }.max() ?? 0 }
        host.apply(.init(instrument: plugin()))
        let old = try XCTUnwrap(host.instrument)
        let firstSource = source(to: try XCTUnwrap(old.unit?.audioNode))
        try host.start()
        let step = Float(0.5 * sin(.pi * 440 / 48_000)), bound = 2 * step
        var signal = try samples(512)
        host.apply(.init(instrument: plugin(2))); runtime.ack()
        signal += try samples(512) // full fade-down, real render acknowledgement
        try await drain { host.instrument?.identity == plugin(2).identity }
        XCTAssertNil(old.unit)
        phase.pointee = .pi / 2 // adversarial phase change at the silent boundary
        let next = try XCTUnwrap(host.instrument)
        let secondSource = source(to: try XCTUnwrap(next.unit?.audioNode))
        signal += try samples(512)
        XCTAssertLessThanOrEqual(jump(signal), bound)
        XCTAssertTrue(signal.contains { abs($0) < 1e-8 })
        XCTAssertGreaterThan(signal.suffix(32).map(abs).max()!, 0.01)
        print("AUDIO-HOST-1 sine instrument replacement jump=\(jump(signal)), bound=\(bound)")

        // Same graph, immediate native detach at a naturally reached peak.
        var abrupt: [Float] = []
        for _ in 0..<120 {
            abrupt = try samples(1)
            if abs(sin(phase.pointee)) > 0.995 { break }
        }
        graph.remove(next)
        abrupt += try samples(48)
        XCTAssertGreaterThan(jump(abrupt), bound)
        print("AUDIO-HOST-1 sine counterexample immediate detach jump=\(jump(abrupt)), rejected bound=\(bound)")
        graph.stop(); engine.detach(firstSource); engine.detach(secondSource)
    }
}

@MainActor private final class SineInstrumentComponents: PluginComponentSource {
    func load(_ identity: SpatialAudioUnitIdentity,
              completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        completion(.success(SystemPluginUnit(unit: AVAudioUnitEQ(numberOfBands: 0))))
    }
}
