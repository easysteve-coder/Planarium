import AVFoundation
import XCTest
import PlanariumDomain
import PlanariumRuntime
@testable import PlanariumAudio

/// Owner 20.10.2026: a strip added while audio runs stayed silent, even from
/// the plugin's own keyboard. Production path: running mixer, add strip, then
/// load its instrument; its notes must reach the master.
@MainActor final class ChannelAddedWhileRunningTests: XCTestCase {
    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        return condition()
    }
    func testStripAddedWhileRunningReachesMaster() throws {
        for instrumentLater in [false, true] {
            let runtime = PerformanceRuntime(clock: MonotonicRuntimeClock(), mailbox: DisplayFrameMailbox())
            let graph = AVAudioGraph()
            let host = try AudioHost(components: SystemPluginSource(), graph: graph,
                runtime: PerformanceAudioPort(runtime: runtime), windows: AppKitPluginWindows(), configuration: .init(offline: true))
            defer { var done = false; host.shutdown { done = true }; XCTAssertTrue(wait { done }) }
            let apple = InstrumentPlugin(identity: .init(componentType: 0x61756D75, componentSubType: 0x646C7320, componentManufacturer: 0x6170706C))
            var channels = [InstrumentChannel(instrument: apple)]
            try host.applyMixer(channels, masterLevelDecibels: 0)
            XCTAssertTrue(wait { host.status[.instrument] == .loaded })
            try host.start()
            let second = UUID()
            channels.append(InstrumentChannel(instrument: instrumentLater ? nil : apple, id: second, name: "New"))
            try host.applyMixer(channels, masterLevelDecibels: 0)
            if instrumentLater {
                channels[1].instrument = apple
                try host.applyMixer(channels, masterLevelDecibels: 0)
            }
            let child = try XCTUnwrap(host.host(for: second))
            XCTAssertTrue(wait { child.status[.instrument] == .loaded }, "later \(instrumentLater)")
            XCTAssertTrue(child.isRunning, "later \(instrumentLater)")
            let schedule = try XCTUnwrap(child.instrument?.scheduleBoundary())
            XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x90, 60, 100]), .sent)
            var peak: Float = 0
            for cycle in 0..<32 {
                let buffer = try graph.renderOffline()
                let samples = try XCTUnwrap(buffer.floatChannelData)
                for c in 0..<Int(buffer.format.channelCount) { for f in 0..<Int(buffer.frameLength) where cycle >= 4 { peak = max(peak, abs(samples[c][f])) } }
            }
            XCTAssertGreaterThan(peak, 0, "new strip silent, instrument later \(instrumentLater)")
            _ = schedule.scheduleMIDI(bytes: [0xB0, 123, 0])
        }
    }
}
