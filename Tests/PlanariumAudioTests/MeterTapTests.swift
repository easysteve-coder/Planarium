import XCTest
import AVFoundation
@testable import PlanariumAudio

@MainActor final class MeterTapTests: XCTestCase {
    private func property<T>(_ name: String, of graph: AVAudioGraph, as type: T.Type) throws -> T {
        try XCTUnwrap(Mirror(reflecting: graph).children.first { $0.label == name }?.value as? T)
    }
    func testOfflineTapMeasuresPlusSixStereoSeparatelyAndMonoOnBothChannels() throws {
        for channels: UInt32 in [2, 1] {
            let graph = AVAudioGraph()
            try graph.configure(.init(offline: true))
            let engine = try property("engine", of: graph, as: AVAudioEngine.self)
            let converter = try property("converter", of: graph, as: AVAudioMixerNode.self)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
            let source = AVAudioSourceNode(format: format) { _, _, frames, list in
                for (channel, buffer) in UnsafeMutableAudioBufferListPointer(list).enumerated() {
                    let values = buffer.mData!.assumingMemoryBound(to: Float.self)
                    for frame in 0..<Int(frames) { values[frame] = channel == 0 ? 0.25 : 0.125 }
                }
                return noErr
            }
            engine.attach(source); engine.connect(source, to: converter, format: format)
            graph.connect(instrument: nil, inserts: []); graph.setLevel(decibels: 6)
            let holder = PeakHolder()
            try graph.installMeter(holder) // stopped -> no tap
            XCTAssertFalse(try property("meterInstalled", of: graph, as: Bool.self))
            try graph.start(); try graph.installMeter(holder); try graph.installMeter(holder)
            defer { graph.stop() }
            let frames = 51_200
            for _ in 0..<100 {
                _ = try graph.renderOffline()
                RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            let value = holder.take()
            XCTAssertEqual(value.left, 0.25 * Float(pow(10, 6 / 20.0)), accuracy: 0.002)
            XCTAssertEqual(value.right, (channels == 1 ? 0.25 : 0.125) * Float(pow(10, 6 / 20.0)), accuracy: 0.002)
            XCTAssertGreaterThan(value.deliveries, 0)
            print("P7 offline channels=\(channels) L=\(value.left) R=\(value.right) deliveries=\(value.deliveries) frames=\(frames) deliveredFrames=\(value.deliveredFrames) bufferHz=\(Double(value.deliveries) * 48_000 / Double(max(1, value.deliveredFrames)))")
            graph.stop()
            XCTAssertFalse(try property("meterInstalled", of: graph, as: Bool.self))
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            _ = holder.take()
            XCTAssertEqual(holder.take(), StereoPeaks(), "Taking a drained holder resets both peaks and delivery counters")
            try graph.start()
            for _ in 0..<30 {
                _ = try graph.renderOffline()
                RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            let residual = holder.take().deliveries
            XCTAssertEqual(residual, 0, "Restart without visible meter must not retain an old native tap")
            guard residual == 0 else { return } // A failing removal must not install a second native tap.
            try graph.installMeter(holder)
            try graph.configure(.init(sampleRate: 44_100, offline: true))
            XCTAssertFalse(try property("meterInstalled", of: graph, as: Bool.self))
        }
    }
    func testHostTapStopVisibilitySuspendReconfigureAndShutdownInBothOrders() throws {
        let h = try Harness(); defer { h.finish() }
        h.host.setMeterVisible(true)
        XCTAssertNil(h.graph.meter)
        try h.host.start(); XCTAssertEqual(h.graph.meterInstalls, 1)
        h.host.setMeterVisible(true); XCTAssertEqual(h.graph.meterInstalls, 1)
        h.host.stop(); XCTAssertEqual(h.graph.meterRemovals, 1); XCTAssertNil(h.graph.meter)
        h.host.setMeterVisible(true); XCTAssertNil(h.graph.meter)
        try h.host.start(); XCTAssertEqual(h.graph.meterInstalls, 2)
        h.host.setMeterVisible(false); XCTAssertEqual(h.graph.meterRemovals, 2)
        h.host.stop(); XCTAssertEqual(h.graph.meterRemovals, 2)
        try h.host.start(); XCTAssertNil(h.graph.meter)
        h.host.setMeterVisible(true); XCTAssertEqual(h.graph.meterInstalls, 3)
        h.host.suspendMeter(); XCTAssertNil(h.graph.meter)
        h.host.setMeterVisible(false); h.host.setMeterVisible(true); XCTAssertNil(h.graph.meter)
        try h.host.start(); XCTAssertEqual(h.graph.meterInstalls, 4)
        h.host.configure(.init(sampleRate: 44_100)); XCTAssertEqual(h.graph.meterRemovals, 4)
        XCTAssertEqual(h.graph.meterInstalls, 5)
        h.host.shutdown(); XCTAssertEqual(h.graph.meterRemovals, 5); XCTAssertNil(h.graph.meter)
        h.host.setMeterVisible(true); try h.host.start(); XCTAssertNil(h.graph.meter)
    }
    func testHostRemovesTapBeforeBlockedRetireAndKeepsLatestPlaybackIntent() throws {
        for stopFirst in [false, true] {
            let h = try Harness(); defer { h.finish() }
            h.host.apply(.init(instrument: plugin())); h.components.succeed(0, h.unit())
            try h.host.start(); h.host.setMeterVisible(true)
            if stopFirst { h.host.stop() }
            else { h.host.configure(.init(sampleRate: 44_100)) }
            XCTAssertNil(h.graph.meter, "Tap is removed before Q acknowledgement")
            h.host.setMeterVisible(false); h.host.setMeterVisible(true)
            XCTAssertNil(h.graph.meter)
            if stopFirst { h.host.configure(.init(sampleRate: 44_100)) }
            else { h.host.stop() }
            h.runtime.ack()
            XCTAssertFalse(h.host.isRunning); XCTAssertNil(h.graph.meter)
            try h.host.start(); XCTAssertNotNil(h.graph.meter)
        }
    }
}
