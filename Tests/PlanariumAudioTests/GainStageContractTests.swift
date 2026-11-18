import XCTest
import AVFoundation
import PlanariumDomain
@testable import PlanariumAudio

@MainActor final class GainStageContractTests: XCTestCase {
    private func property<T>(_ name: String, of graph: AVAudioGraph, as type: T.Type) throws -> T {
        try XCTUnwrap(Mirror(reflecting: graph).children.first { $0.label == name }?.value as? T)
    }
    func testPlusSixUsesDocumentedGainStageAndDoublesOfflineAmplitude() throws {
        for sampleRate in [44_100.0,48_000.0] {
            let graph = AVAudioGraph()
            try graph.configure(.init(sampleRate: sampleRate, offline: true))
            let engine = try property("engine", of: graph, as: AVAudioEngine.self)
            let converter = try property("converter", of: graph, as: AVAudioMixerNode.self)
            let gain = try property("gain", of: graph, as: AVAudioUnitEQ.self)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
            // Same macOS-12 construction as the supervisor's compiled proof.
            let source = AVAudioSourceNode(format: format) { _,_,frames,list in
                for buffer in UnsafeMutableAudioBufferListPointer(list) {
                    let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                    for frame in 0..<Int(frames) { samples[frame] = 0.25 }
                }
                return noErr
            }
            engine.attach(source); engine.connect(source, to: converter, format: format)
            graph.connect(instrument: nil, inserts: [])
            graph.setMasterLevel(decibels: 0)
            try graph.start(); defer { graph.stop() }
            func peak(_ db: Double) throws -> Float {
                graph.setMasterLevel(decibels: db)
                var peak: Float = 0
                for cycle in 0..<30 {
                    let buffer = try graph.renderOffline()
                    let data = try XCTUnwrap(buffer.floatChannelData)
                    if cycle >= 10 { for ch in 0..<Int(buffer.format.channelCount) { for i in 0..<Int(buffer.frameLength) { peak = max(peak,abs(data[ch][i])) } } }
                }
                return peak
            }
            let base = try peak(0), plus = try peak(6)
            XCTAssertEqual(base,0.25,accuracy: 0.001)
            XCTAssertEqual(plus/base,Float(pow(10,6/20.0)),accuracy: 0.003)
            // This assertion also rejects the undocumentated outputVolume>1
            // path, even on systems where it produces the same amplitude.
            XCTAssertEqual(gain.globalGain,6)
            XCTAssertEqual(engine.mainMixerNode.outputVolume,1)
            let minus = try peak(-6)
            XCTAssertEqual(minus/base,Float(pow(10,-6/20.0)),accuracy: 0.003)
            graph.setMasterLevel(decibels: -120)
            XCTAssertEqual(engine.mainMixerNode.outputVolume,0)
            XCTAssertEqual(try peak(-120),0,accuracy: 1e-8)
            graph.setMasterLevel(decibels: 0)
            XCTAssertEqual(gain.globalGain,0); XCTAssertEqual(engine.mainMixerNode.outputVolume,1)
            // Reconnecting the serial insert path keeps the persistent gain.
            graph.connect(instrument: nil, inserts: [])
            XCTAssertEqual(try peak(6)/base,Float(pow(10,6/20.0)),accuracy: 0.003)
            print("Gain proof rate=\(sampleRate) base=\(base) plus6=\(plus) ratio=\(plus/base) minus6=\(minus)")
        }
    }
    func testConfigureRecreatesGainEdgesInNewDeviceClock() throws {
        let graph = AVAudioGraph()
        for rate in [48_000.0,44_100.0,48_000.0] {
            try graph.configure(.init(sampleRate: rate, offline: true))
            graph.connect(instrument: nil, inserts: [])
            graph.setMasterLevel(decibels: 6)
            let gain = try property("gain", of: graph, as: AVAudioUnitEQ.self)
            XCTAssertEqual(gain.globalGain,6)
            try graph.start()
            let buffer = try graph.renderOffline()
            XCTAssertEqual(buffer.format.sampleRate, rate)
            graph.stop()
        }
    }
}
