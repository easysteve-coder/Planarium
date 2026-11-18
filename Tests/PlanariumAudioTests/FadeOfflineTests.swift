import AudioToolbox
import AVFoundation
import XCTest
import PlanariumDomain
@testable import PlanariumAudio

@MainActor private final class OfflineEffectSource: PluginComponentSource {
    let effect: AVAudioUnit
    init(_ effect: AVAudioUnit) { self.effect = effect }
    func load(_ identity: SpatialAudioUnitIdentity,
              completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        completion(.success(SystemPluginUnit(unit: effect)))
    }
}

@MainActor final class FadeOfflineTests: XCTestCase {
    private var rightSamples: [Float] = []
    private func property<T>(_ name: String, of graph: AVAudioGraph, as type: T.Type) throws -> T {
        try XCTUnwrap(Mirror(reflecting: graph).children.first { $0.label == name }?.value as? T)
    }
    private func samples(_ graph: AVAudioGraph, frames: UInt32 = 48) throws -> [Float] {
        let buffer = try graph.renderOffline(frames: frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        rightSamples = Array(UnsafeBufferPointer(start: data[1], count: Int(buffer.frameLength)))
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
    private func jump(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).map { abs($0 - $1) }.max() ?? 0
    }
    private func installSource(_ graph: AVAudioGraph, rate: Double, constant: Bool,
                               phase: UnsafeMutablePointer<Double>) throws -> AVAudioSourceNode {
        let engine = try property("engine", of: graph, as: AVAudioEngine.self)
        let converter = try property("converter", of: graph, as: AVAudioMixerNode.self)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let increment = 2 * Double.pi * 440 / rate
        let source = AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for frame in 0..<Int(frames) {
                let value: Float = constant ? 0.25 : 0.25 * Float(sin(phase.pointee))
                phase.pointee += increment
                if phase.pointee > 2 * Double.pi { phase.pointee -= 2 * Double.pi }
                for buffer in buffers { buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = value }
            }
            return noErr
        }
        engine.attach(source); engine.connect(source, to: converter, format: format)
        return source
    }
    func testSampleExactStereoRampsAtBothRatesAndMuteSharesTheUnit() throws {
        for rate in [44_100.0, 48_000.0] {
            let graph = AVAudioGraph(); try graph.configure(.init(sampleRate: rate, offline: true))
            let phase = UnsafeMutablePointer<Double>.allocate(capacity: 1); phase.initialize(to: 0)
            defer { graph.stop(); phase.deinitialize(count: 1); phase.deallocate() }
            let source = try installSource(graph, rate: rate, constant: true, phase: phase)
            _ = source
            graph.connect(instrument: nil, inserts: []); try graph.start()
            _ = try samples(graph)
            let duration = Int((rate * 0.01).rounded())
            let token = graph.fade(silent: true)
            XCTAssertFalse(graph.fadeReached(token), "A command alone cannot acknowledge rendering")
            var down = try samples(graph, frames: UInt32(duration - 1))
            XCTAssertEqual(down, rightSamples, "Stereo gain is identical on both channels")
            XCTAssertFalse(graph.fadeReached(token), "Ack cannot precede final ramp sample")
            down += try samples(graph, frames: 1)
            XCTAssertTrue(graph.fadeReached(token))
            for i in down.indices { XCTAssertEqual(down[i], 0.25 * (1 - Float(i + 1) / Float(duration)), accuracy: 3e-6) }
            let upToken = graph.fade(silent: false)
            XCTAssertFalse(graph.fadeReached(upToken))
            let up = try samples(graph, frames: UInt32(duration))
            XCTAssertEqual(up, rightSamples)
            XCTAssertTrue(graph.fadeReached(upToken))
            for i in up.indices { XCTAssertEqual(up[i], 0.25 * Float(i + 1) / Float(duration), accuracy: 3e-6) }
            graph.setMuted(true)
            let muted = try samples(graph, frames: UInt32(duration))
            XCTAssertEqual(muted.last!, 0, accuracy: 1e-8)
            graph.stop(); try graph.start()
            XCTAssertEqual(try samples(graph).max()!, 0, accuracy: 1e-8)
            graph.setMuted(false)
            XCTAssertEqual(try samples(graph, frames: UInt32(duration)).last!, 0.25, accuracy: 3e-6)
            print("AUDIO-FADE rate=\(rate) frames=\(duration), envelope down=\(stride(from: 0, to: duration, by: duration/5).map { down[$0] }), last=\(down.last!), upLast=\(up.last!)")
        }
    }
    func testAppleDelayBypassKeepsSignalInEveryFiveMillisecondWindow() throws {
        let effect = AVAudioUnitDelay()
        effect.delayTime = 0.25; effect.feedback = 0; effect.wetDryMix = 50
        let graph = AVAudioGraph()
        let trace = Trace()
        let host = try AudioHost(components: OfflineEffectSource(effect), graph: graph,
            runtime: FakeRuntime(trace: trace), windows: FakeWindows(trace: trace), configuration: .init(offline: true))
        let phase = UnsafeMutablePointer<Double>.allocate(capacity: 1); phase.initialize(to: 0)
        defer { host.shutdown(); phase.deinitialize(count: 1); phase.deallocate() }
        let desc = effect.audioComponentDescription
        let insert = InstrumentInsert(id: UUID(), plugin: .init(identity: .init(componentType: desc.componentType,
            componentSubType: desc.componentSubType, componentManufacturer: desc.componentManufacturer)))
        var channel = InstrumentChannel(inserts: [insert]); host.apply(channel)
        _ = try installSource(graph, rate: 48_000, constant: false, phase: phase)
        try host.start()
        for _ in 0..<150 { _ = try samples(graph, frames: 512) }
        let window = 240 // 5 ms at 48 kHz
        for bypass in [true, false] {
            channel.inserts[0].bypassed = bypass; host.apply(channel)
            XCTAssertEqual(host.status[.insert(insert.id)], bypass ? .bypass : .loaded)
            var signal: [Float] = []
            for _ in 0..<16 { signal += try samples(graph, frames: 512) }
            let lowestWindowPeak = stride(from: 0, through: signal.count - window, by: window).map {
                signal[$0..<$0 + window].map(abs).max() ?? 0
            }.min() ?? 0
            XCTAssertGreaterThan(lowestWindowPeak, 0.025, "Bypass must not make a >= 5 ms hole")
            print("AUDIO-BYPASS Apple Delay off=\(bypass) smallest-5ms-peak=\(lowestWindowPeak)")
        }
    }
    func testRenderSourceCapturesOnlyPointerAndCPathHasNoRealtimeAllocationOrLocks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let swift = try String(contentsOf: root.appendingPathComponent("Sources/PlanariumAudio/PlanariumFade.swift"))
        let start = try XCTUnwrap(swift.range(of: "override var internalRenderBlock"))
        let end = try XCTUnwrap(swift.range(of: "    func reset", range: start.upperBound..<swift.endIndex))
        let render = String(swift[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(render.contains("let state = state")); XCTAssertTrue(render.contains("planarium_fade_render(state, outputData, frames)"))
        for forbidden in ["self", "[weak", "[unowned", "Array", "allocate", "print(", "NSLock", "Dispatch"] {
            XCTAssertFalse(render.contains(forbidden), "Render closure cannot contain \(forbidden)")
        }
        let c = try String(contentsOf: root.appendingPathComponent("Sources/PlanariumFadeDSP/PlanariumFadeDSP.c"))
        let cStart = try XCTUnwrap(c.range(of: "void planarium_fade_render("))
        let cRender = String(c[cStart.lowerBound...])
        for forbidden in ["malloc", "calloc", "free(", "printf", "mutex", "lock("] { XCTAssertFalse(cRender.contains(forbidden)) }
        XCTAssertTrue(cRender.contains("memory_order_acquire")); XCTAssertTrue(cRender.contains("memory_order_release"))
    }
}

extension FadeOfflineTests {
    func testRundeACatalogExcludesRegisteredInternalFadeWithoutInstantiatingIt() {
        let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
            componentSubType: 0x50666465, componentManufacturer: 0x506c6e6d, componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.registerSubclass(PlanariumFade.self, as: description, name: "Planarium: Fade", version: 1)
        XCTAssertFalse(AVAudioUnitComponentManager.shared().components(matching: description).isEmpty)
        let catalog = AudioUnitEffectCatalog(source: SystemAudioUnitComponentSource())
        XCTAssertFalse(catalog.availableEffects().contains { $0.identity.componentManufacturer == 0x506c6e6d })
        XCTAssertFalse(catalog.availableInstruments().contains { $0.identity.componentManufacturer == 0x506c6e6d })
    }
}
