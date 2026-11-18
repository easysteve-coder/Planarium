import AppKit
import AVFoundation
import Combine
import SwiftUI
import XCTest
import PlanariumAudio
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class ChannelMeterTests: XCTestCase {
    func testClipClearsItselfAfterHoldAndDecayIsTwentyDecibelsPerSecond() {
        let reader = ChannelMeterReader()
        reader.observe(.init(left: 1.2, right: 0.6), elapsed: 0)
        XCTAssertTrue(reader.clip.isClipped)
        reader.observe(.init(), elapsed: 1)
        XCTAssertEqual(reader.peaks.left, ChannelMeterReader.displayGain(0.12), accuracy: 0.00001)
        XCTAssertEqual(reader.peaks.right, ChannelMeterReader.displayGain(0.06), accuracy: 0.00001)
        XCTAssertEqual(MeterLaw.position(forGain: Double(reader.peaks.left)), MeterLaw.position(forDecibels: -18.5), accuracy: 0.00001)
        XCTAssertTrue(reader.clip.isClipped, "1 s after the overload the indicator still holds")
        reader.observe(.init(left: 1.1, right: 0), elapsed: 0.9)
        reader.observe(.init(), elapsed: 1.9)
        XCTAssertTrue(reader.clip.isClipped, "A new overload restarts the hold time")
        reader.observe(.init(), elapsed: 0.2)
        XCTAssertFalse(reader.clip.isClipped, "Without a new overload the indicator clears itself")
        reader.observe(.init(left: 2, right: 2), elapsed: 0)
        XCTAssertTrue(reader.clip.isClipped)
        reader.resetClip(); XCTAssertFalse(reader.clip.isClipped)
    }
    func testVisibleOnlyTimerAtMostThirtyHertzAndDuplicateStart() async throws {
        XCTAssertEqual(ChannelMeterReader.interval, 1.0 / 30, accuracy: 1e-12)
        let graph = MonitorGraph(); graph.permitsStart = true
        let fixture = try MonitorRootFixture(graph: graph)
        let reader = ChannelMeterReader()
        var publications = 0
        let subscription = reader.$peaks.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel(); reader.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(publications, 0); XCTAssertFalse(reader.isTimerActive)
        reader.start(fixture.root.audio); reader.start(fixture.root.audio)
        XCTAssertFalse(reader.isTimerActive, "Stopped host has no timer")
        try fixture.root.audio.start()
        let before = publications, readsBefore = reader.readCount
        let started = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: 1_050_000_000)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(publications - before, 0, "Silent taps never invalidate views")
        XCTAssertGreaterThan(reader.readCount - readsBefore, 0)
        XCTAssertLessThanOrEqual(reader.readCount - readsBefore, Int(ceil(elapsed * 30)) + 1,
                                 "30 Hz bound over actual elapsed time: \(elapsed) s")
        XCTAssertTrue(reader.isTimerActive)
        fixture.root.audio.suspendMeter(); XCTAssertFalse(reader.isTimerActive)
        try fixture.root.audio.start(); XCTAssertTrue(reader.isTimerActive)
        fixture.root.audio.stop(); XCTAssertFalse(reader.isTimerActive)
        reader.stop(); XCTAssertFalse(reader.isTimerActive)
        let hidden = publications
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(publications, hidden)
    }
    /// Owner 07.10.2026: „Pegelanzeige geht nicht“. A rebuilt strip shows
    /// its new meter before the old one disappears; the late disappearance
    /// must not stop the shared reader.
    func testRebuiltMeterAppearingBeforeOldDisappearsKeepsReading() throws {
        let graph = MonitorGraph(); graph.permitsStart = true
        let fixture = try MonitorRootFixture(graph: graph)
        let reader = ChannelMeterReader()
        defer { reader.stop() }
        try fixture.root.audio.start()
        let old = UUID(), rebuilt = UUID()
        reader.start(fixture.root.audio, viewer: old)
        XCTAssertTrue(reader.isTimerActive)
        reader.start(fixture.root.audio, viewer: rebuilt)
        reader.stop(viewer: old)
        XCTAssertTrue(reader.isTimerActive, "The rebuilt meter keeps the reader running")
        XCTAssertTrue(fixture.root.audio.isMeterActive)
        reader.observe(.init(left: 1.3, right: 0), elapsed: 0)
        reader.stop(viewer: rebuilt)
        XCTAssertFalse(reader.isTimerActive, "The last meter leaving stops reading")
        XCTAssertFalse(reader.clip.isClipped, "A stopped meter shows no stale overload")
        XCTAssertFalse(fixture.root.audio.isMeterActive)
    }
    func testNativeMeterViewDoesNotResetClipWhenObservingDisplayPeaks() throws {
        let fixture = try MonitorRootFixture()
        let reader = ChannelMeterReader()
        let host = NSHostingView(rootView: HostedStereoMeter(reader: reader, host: fixture.root.audio))
        host.frame = NSRect(x: 0, y: 0, width: 24, height: 244)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        reader.observe(.init(left: 1.2, right: 0.7), elapsed: 0)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        XCTAssertTrue(reader.clip.isClipped)
    }
    func testMeterStatesRenderWideAndNarrow() throws {
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, peak) in [("still", 0.0), ("quiet", 0.2), ("running", 0.5), ("hot", 0.9), ("clip", 1.2)] {
            var state = MeterClipState(); state.observe(peak: peak)
            for width in [300, 520] {
                let view = HStack { Text("Channel strip · \(name)"); Spacer(); HelmutStereoMeterSample(left: peak, right: peak / 2, clip: .constant(state)).frame(width: 24, height: 244) }
                    .padding().background(Color.gray).environment(\.colorScheme, .dark)
                try P7Images.render(view, width: width, height: 280, name: "p7-meter-\(name)-\(width).png", directory: directory)
            }
        }
    }
}
@MainActor enum P7Images {
    static func render<V: View>(_ view: V, width: Int, height: Int, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading).background(Color.gray))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.wantsLayer = true; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst, bytesPerRow: 0, bitsPerPixel: 0))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}

extension ChannelMeterTests {
    func testSilenceConstantAndSubHalfDecibelChangesPublishOnlyVisibleTransitions() {
        let reader = ChannelMeterReader()
        var changes = 0
        let token = reader.objectWillChange.sink { changes += 1 }
        defer { token.cancel() }
        for i in 0..<100 { reader.observe(.init(deliveries: i, deliveredFrames: i * 512), elapsed: 1.0 / 30) }
        XCTAssertEqual(changes, 0)
        reader.observe(.init(left: 0.5, right: 0.25), elapsed: 0)
        XCTAssertEqual(changes, 1)
        for i in 0..<100 {
            reader.observe(.init(left: 0.5 + Float(i % 2) * 0.0001, right: 0.25, deliveries: i), elapsed: 1.0 / 30)
        }
        XCTAssertEqual(changes, 1, "Raw sample jitter and delivery counters are invisible")
        reader.observe(.init(left: 0.6, right: 0.25), elapsed: 0)
        XCTAssertEqual(changes, 2, "A real visible level change reaches the bars")
        reader.observe(.init(left: 1.2, right: 1.2), elapsed: 0)
        let clipped = changes
        for _ in 0..<100 { reader.observe(.init(left: 1.2, right: 1.2), elapsed: 1.0 / 30) }
        XCTAssertEqual(changes, clipped, "Repeated overload only refreshes private hold time")
        reader.observe(.init(), elapsed: 4)
        let settled = changes
        for _ in 0..<100 { reader.observe(.init(), elapsed: 1.0 / 30) }
        XCTAssertFalse(reader.clip.isClipped); XCTAssertEqual(reader.peaks, .init())
        XCTAssertEqual(changes, settled)
    }
    func testConstantTapSamplesThroughReadPublishOnceForChannelAndMaster() throws {
        let graph = MonitorGraph(); graph.permitsStart = true
        let fixture = try MonitorRootFixture(graph: graph)
        let channel = ChannelMeterReader(), master = ChannelMeterReader(master: true)
        defer { channel.stop(); master.stop(); fixture.root.audio.stop(); fixture.root.terminate {} }
        try fixture.root.audio.start()
        channel.start(fixture.root.audio); master.start(fixture.root.audio)
        let channelTap = try XCTUnwrap(graph.meter), masterTap = try XCTUnwrap(graph.masterMeter)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let data = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<32 { data[0][i] = 0.5; data[1][i] = 0.25 }
        var channelChanges = 0, masterChanges = 0
        let a = channel.objectWillChange.sink { channelChanges += 1 }
        let b = master.objectWillChange.sink { masterChanges += 1 }
        defer { a.cancel(); b.cancel() }
        let before = [channel.readCount, master.readCount]
        for _ in 0..<100 {
            channelTap.accumulate(buffer); masterTap.accumulate(buffer)
            channel.read(); master.read()
        }
        XCTAssertEqual([channel.readCount, master.readCount], before.map { $0 + 100 })
        XCTAssertEqual(channelChanges, 1); XCTAssertEqual(masterChanges, 1)
        XCTAssertEqual(channel.peaks.left, ChannelMeterReader.displayGain(0.5))
        XCTAssertEqual(master.peaks.right, ChannelMeterReader.displayGain(0.25))
        for i in 0..<32 { data[0][i] = 0.8; data[1][i] = 0.6 }
        channelTap.accumulate(buffer); masterTap.accumulate(buffer)
        channel.read(); master.read()
        XCTAssertEqual(channelChanges, 2); XCTAssertEqual(masterChanges, 2, "A changed tap still reaches each meter")
    }

    func testChannelAndMasterShareOnePulseInBothVisibilityAndDepartureOrders() throws {
        for reverse in [false, true] {
            let graph = MonitorGraph(); graph.permitsStart = true
            let fixture = try MonitorRootFixture(graph: graph)
            let channel = ChannelMeterReader(), master = ChannelMeterReader(master: true)
            let readers = reverse ? [master, channel] : [channel, master]
            try fixture.root.audio.start()
            readers.forEach { $0.start(fixture.root.audio) }
            XCTAssertEqual(MeterReadPulse.shared.timerCount, 1)
            let before = readers.map(\.readCount)
            MeterReadPulse.shared.read()
            XCTAssertEqual(readers.map(\.readCount), before.map { $0 + 1 })
            readers[0].setVisible(false)
            XCTAssertEqual(MeterReadPulse.shared.timerCount, 1)
            let hidden = readers[0].readCount
            MeterReadPulse.shared.read(); XCTAssertEqual(readers[0].readCount, hidden)
            readers[1].setVisible(false)
            XCTAssertEqual(MeterReadPulse.shared.timerCount, 0)
            readers[0].setVisible(true); XCTAssertEqual(MeterReadPulse.shared.timerCount, 1)
            readers[1].setVisible(true); XCTAssertEqual(MeterReadPulse.shared.timerCount, 1)
            readers[0].stop(); XCTAssertEqual(MeterReadPulse.shared.timerCount, 1)
            readers[1].stop(); XCTAssertEqual(MeterReadPulse.shared.timerCount, 0)
            fixture.root.audio.stop(); fixture.root.terminate {}
        }
    }
    func testLiveBarChangesDoNotRebuildScale() throws {
        let fixture = try MonitorRootFixture(), reader = ChannelMeterReader()
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil; reader.stop(); fixture.root.terminate {} }
        let host = NSHostingView(rootView: HostedStereoMeter(reader: reader, host: fixture.root.audio))
        host.frame = .init(x: 0, y: 0, width: 24, height: 244)
        func flush() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        for _ in 0..<3 { flush() }
        probe.reset()
        for level in [Float(0.2), 0.4, 0.6] {
            reader.observe(.init(left: level, right: level), elapsed: 0); flush()
        }
        XCTAssertGreaterThan(probe.counts["meter", default: 0], 0)
        XCTAssertEqual(probe.counts["meter.scale", default: 0], 0)
        XCTAssertEqual(probe.counts["meter.clip", default: 0], 0)
    }
}
