import AVFoundation
import XCTest
import PlanariumDomain
import PlanariumRuntime
@testable import PlanariumAudio

@MainActor final class ChannelMixerOfflineTests: XCTestCase {
    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        return condition()
    }
    func testNativeMasterPeaksSurviveRebuildForOneAndMultipleStrips() throws {
        for count in [1, 2] {
            let runtime = PerformanceRuntime(clock: MonotonicRuntimeClock(), mailbox: DisplayFrameMailbox())
            let graph = AVAudioGraph()
            let host = try AudioHost(components: SystemPluginSource(), graph: graph,
                runtime: PerformanceAudioPort(runtime: runtime), windows: AppKitPluginWindows(), configuration: .init(offline: true))
            defer { var done = false; host.shutdown { done = true }; XCTAssertTrue(wait { done }) }
            let apple = InstrumentPlugin(identity: .init(componentType: 0x61756D75, componentSubType: 0x646C7320, componentManufacturer: 0x6170706C))
            let channels = (0..<count).map { InstrumentChannel(instrument: apple, id: $0 == 0 ? InstrumentChannel.legacyID : UUID()) }
            try host.applyMixer(channels, masterLevelDecibels: 0)
            XCTAssertTrue(wait { channels.allSatisfy { host.host(for: $0.id)?.instrument != nil } })
            try host.start()
            func peak() throws -> Float {
                var result: Float = 0
                for _ in 0..<24 {
                    let buffer = try graph.renderOffline()
                    let samples = try XCTUnwrap(buffer.floatChannelData)
                    for c in 0..<Int(buffer.format.channelCount) { for f in 0..<Int(buffer.frameLength) { result = max(result, abs(samples[c][f])) } }
                }
                return result
            }
            for level in [-120.0, -12, 6] {
                try host.applyMixer(channels, masterLevelDecibels: level)
                let rate = host.configuration.sampleRate == 44_100 ? 48_000.0 : 44_100.0
                host.configure(.init(sampleRate: rate, offline: true))
                XCTAssertTrue(wait { host.configuration.sampleRate == rate && channels.allSatisfy { host.host(for: $0.id)?.isRunning == true } })
                let schedule = try XCTUnwrap(host.instrument?.scheduleBoundary())
                XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x90, 60, 100]), .sent)
                let actual = try peak()
                XCTAssertEqual(schedule.scheduleMIDI(bytes: [0xB0, 120, 0]), .sent)
                _ = try peak()
                try host.applyMixer(channels, masterLevelDecibels: 0)
                XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x90, 60, 100]), .sent)
                let reference = try peak()
                if level == -120 { XCTAssertEqual(actual, 0, accuracy: 1e-7) }
                else { XCTAssertGreaterThan(actual, 0); XCTAssertEqual(Double(actual / reference), pow(10, level / 20), accuracy: 0.03) }
                print("OWNER-LAUF-1010 native master: strips \(count), dB \(level), peak \(actual), reference \(reference)")
                XCTAssertEqual(schedule.scheduleMIDI(bytes: [0xB0, 123, 0]), .sent)
                _ = try peak()
            }
        }
    }
    func testAppleHeldChordAndIndependentMelodySoloMuteAndSumOffline() throws {
        let runtime = PerformanceRuntime(clock: MonotonicRuntimeClock(), mailbox: DisplayFrameMailbox())
        let graph = AVAudioGraph()
        let host = try AudioHost(components: SystemPluginSource(), graph: graph,
            runtime: PerformanceAudioPort(runtime: runtime), windows: AppKitPluginWindows(), configuration: .init(offline: true))
        defer { var done = false; host.shutdown { done = true }; XCTAssertTrue(wait { done }) }
        let second = UUID()
        let apple = InstrumentPlugin(identity: .init(componentType: 0x61756D75, componentSubType: 0x646C7320, componentManufacturer: 0x6170706C))
        var channels = [InstrumentChannel(instrument: apple), InstrumentChannel(instrument: apple, id: second, name: "Lead")]
        try host.applyMixer(channels, masterLevelDecibels: 0)
        XCTAssertTrue(wait { host.status[.instrument] == .loaded && host.host(for: second)?.status[.instrument] == .loaded })
        let firstSchedule = try XCTUnwrap(host.instrument?.scheduleBoundary())
        let secondHost = try XCTUnwrap(host.host(for: second)), secondSchedule = try XCTUnwrap(secondHost.instrument?.scheduleBoundary())
        XCTAssertFalse(host.instrument === secondHost.instrument)
        var router = OutputRouter()
        router.attach(RuntimePorts.audioUnit(boundary: firstSchedule))
        router.attach(RuntimePorts.audioUnit(stripID: second, boundary: secondSchedule))
        var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
        let chord = UUID(), melody = UUID()
        func evaluation(_ id: UUID, strip: UUID, notes: [UInt8], transition: SpatialNoteTransition) -> SpatialRoutingEvaluation {
            .init(routingID: id, target: .audioUnitNote(channel: 0, stripID: strip), value: .notes(Set(notes.map { .init(number: $0, velocity: 100) }), transition: transition))
        }
        func events(_ commands: [SpatialOutputCommand]) -> [MusicEvent] {
            commands.compactMap { command in
                switch command {
                case .noteOn(let d, let c, let n): return .noteOn(destination: d, channel: c, note: n)
                case .noteOff(let d, let c, let n): return .noteOff(destination: d, channel: c, note: n)
                default: return nil
                }
            }
        }
        try host.start(); host.setMeterVisible(true); secondHost.setMeterVisible(true)
        router.route(events(ledger.apply([evaluation(chord, strip: InstrumentChannel.legacyID, notes: [60, 64, 67], transition: .holdUntilNext)])), sounding: events(ledger.soundingCommands), allowOn: true)
        var pcm: [UInt32] = []
        func peak(_ cycles: Int = 32, record: Bool = false) throws -> Float {
            var peak: Float = 0
            for cycle in 0..<cycles {
                let buffer = try graph.renderOffline()
                let samples = try XCTUnwrap(buffer.floatChannelData)
                for channel in 0..<Int(buffer.format.channelCount) { for frame in 0..<Int(buffer.frameLength) {
                    if cycle >= 8 { peak = max(peak, abs(samples[channel][frame])) }
                    if record { pcm.append(samples[channel][frame].bitPattern) }
                } }
            }
            return peak
        }
        XCTAssertGreaterThan(try peak(record: true), 0)
        let batch = [SpatialRoutingEvaluation(routingID: chord, target: .audioUnitNote(channel: 0, stripID: InstrumentChannel.legacyID), value: .inactive),
                     evaluation(melody, strip: second, notes: [76], transition: .legato)]
        let melodyCommands = ledger.apply(batch)
        XCTAssertFalse(melodyCommands.contains { if case .noteOff(.audioUnit(let id), _, _) = $0 { return id == InstrumentChannel.legacyID }; return false })
        router.route(events(melodyCommands), sounding: events(ledger.soundingCommands), allowOn: true)
        XCTAssertEqual(ledger.soundingNoteCount, 4); XCTAssertGreaterThan(try peak(record: true), 0)
        channels[1].soloed = true; try host.applyMixer(channels, masterLevelDecibels: 0)
        XCTAssertGreaterThan(try peak(record: true), 0)
        channels[1].muted = true; try host.applyMixer(channels, masterLevelDecibels: 0)
        XCTAssertEqual(try peak(record: true), 0, accuracy: 1e-7)
        channels[1].soloed = false; try host.applyMixer(channels, masterLevelDecibels: 0)
        XCTAssertGreaterThan(try peak(record: true), 0, "Held chord remains audible after melody is muted")
        try host.applyMixer(channels, masterLevelDecibels: -120)
        XCTAssertEqual(try peak(record: true), 0, accuracy: 1e-7)
        try host.applyMixer(channels, masterLevelDecibels: 0)
        XCTAssertGreaterThan(try peak(record: true), 0)
        // AVAudioEngine delivers taps asynchronously, including in manual
        // rendering mode. Await their evidence, not the speed of this thread.
        var sumDeliveries = 0, firstDeliveries = 0, leadDeliveries = 0
        XCTAssertTrue(wait {
            sumDeliveries += Int(host.takeMasterPeaks().deliveries)
            firstDeliveries += Int(host.takeMeterPeaks().deliveries)
            leadDeliveries += Int(secondHost.takeMeterPeaks().deliveries)
            return sumDeliveries > 0 && firstDeliveries > 0 && leadDeliveries > 0
        })
        router.route(events(ledger.releaseAll()), sounding: [], allowOn: false)
        XCTAssertEqual(router.display.map(\.soundingNotes), [0, 0])
        let originalFirst = host.instrument, originalSecond = secondHost.instrument
        host.configure(.init(sampleRate: 44_100, offline: true))
        XCTAssertTrue(wait { host.configuration.sampleRate == 44_100 && secondHost.configuration.sampleRate == 44_100 && host.isRunning && secondHost.isRunning })
        XCTAssertTrue(host.instrument === originalFirst); XCTAssertTrue(secondHost.instrument === originalSecond)
        XCTAssertEqual(try graph.renderOffline().format.sampleRate, 44_100)
        if let directory = ProcessInfo.processInfo.environment["SICK_TEST_ARTIFACT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try pcm.withUnsafeBytes { Data($0) }.write(to: url.appendingPathComponent("two-strips-float32-stereo-planar-blocks.pcm"))
        }
        print("KANALZÜGE-1 Apple offline: chord+melody, independent instances, Solo/Mute, master silence/recovery, meters \(sumDeliveries)/\(firstDeliveries)/\(leadDeliveries)")
    }
}
