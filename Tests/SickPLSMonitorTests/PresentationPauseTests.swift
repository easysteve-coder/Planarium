import AppKit
import Combine
import SwiftUI
import XCTest
import PlanariumApplication
import PlanariumDomain
import PlanariumRuntime
@testable import SickPLSMonitor

@MainActor final class PresentationPauseTests: XCTestCase {
    private final class Window: NSWindow {
        var testVisible = true
        var testMiniaturized = false
        override var occlusionState: NSWindow.OcclusionState { testVisible ? [.visible] : [] }
        override var isMiniaturized: Bool { testMiniaturized }
    }
    private func flush(_ host: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    }
    private func ack(_ runtime: PerformanceRuntime) {
        let done = expectation(description: "Runtime processed input")
        runtime.acknowledge { done.fulfill() }
        wait(for: [done], timeout: 5)
    }
    func testNativeOcclusionAndMinimizationPauseCanvasPumpAndMetersWhileRuntimeContinues() throws {
        for minimized in [false, true] {
            let graph = MonitorGraph(); graph.permitsStart = true
            let f = try MonitorRootFixture(graph: graph, clock: PauseClock()), layout = try LayoutWorkspaceFixture(fixture: f)
            let meter = ChannelMeterReader()
            var view = layout.view; view.providedMeterReader = meter
            let host = NSHostingView(rootView: view)
            host.frame = .init(x: 0, y: 0, width: 1500, height: 1000)
            let window = Window(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
            defer { ViewEvaluationProbe.current = nil; meter.stop(); f.root.display.stop(); window.close(); layout.cleanDefaults(); f.root.terminate {} }
            try f.root.audio.start()
            let session = UUID(); f.root.runtime.sessionBegan(session); ack(f.root.runtime)
            for _ in 0..<4 { flush(host) }
            f.root.runtime.frame(.init(sessionID: session, sequence: 1, time: 0, measurements: [])); ack(f.root.runtime)
            for _ in 0..<4 { flush(host) }
            XCTAssertTrue(meter.isTimerActive)
            if minimized { window.testMiniaturized = true } else { window.testVisible = false }
            NotificationCenter.default.post(name: minimized ? NSWindow.didMiniaturizeNotification : NSWindow.didChangeOcclusionStateNotification, object: window)
            for _ in 0..<4 { flush(host) }
            XCTAssertFalse(meter.isTimerActive)
            let passes = f.root.display.pumpPassCount, canvas = probe.counts["canvas", default: 0], reads = meter.readCount
            let processed = f.root.runtime.diagnostics.processedProfiles
            for n: UInt64 in 2...51 {
                f.root.runtime.frame(.init(sessionID: session, sequence: n, time: 0, measurements: []))
                ack(f.root.runtime); meter.read(); flush(host)
            }
            XCTAssertEqual(f.root.runtime.diagnostics.processedProfiles - processed, 50)
            XCTAssertEqual(f.root.display.pumpPassCount, passes)
            XCTAssertEqual(probe.counts["canvas", default: 0], canvas)
            XCTAssertEqual(meter.readCount, reads)
            window.testVisible = true; window.testMiniaturized = false
            NotificationCenter.default.post(name: minimized ? NSWindow.didDeminiaturizeNotification : NSWindow.didChangeOcclusionStateNotification, object: window)
            for _ in 0..<4 { flush(host) }
            XCTAssertEqual(f.root.display.pumpPassCount - passes, 1)
            XCTAssertEqual(f.root.display.frame?.profile?.sequence, 51)
            XCTAssertTrue(meter.isTimerActive)
        }
    }
    func testMixerAndWindowVisibilityBothOrdersCatchUpExactlyOnce() {
        for hideMixerFirst in [false, true] { for showMixerFirst in [false, true] {
            let mailbox = DisplayFrameMailbox(), display = PerformanceDisplayModel(mailbox: mailbox)
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            func write(_ sequence: UInt64) {
                mailbox.write(.init(selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]), processedProfiles: sequence))
                settle()
            }
            display.start(); display.setMixerMonitorVisible(true); write(1)
            let initial = display.pumpPassCount
            if hideMixerFirst { display.setMixerMonitorVisible(false); settle() }
            display.setVisible(false); settle()
            write(2) // A still-mounted mini keyboard cannot override a hidden window.
            XCTAssertEqual(display.pumpPassCount, initial)
            if !hideMixerFirst { display.setMixerMonitorVisible(false); settle() }
            write(3)
            XCTAssertEqual(display.pumpPassCount, initial)
            if showMixerFirst { display.setMixerMonitorVisible(true); settle() }
            display.setVisible(true); settle()
            if !showMixerFirst { display.setMixerMonitorVisible(true); settle() }
            XCTAssertEqual(display.pumpPassCount, initial + 1)
            XCTAssertEqual(display.frame?.processedProfiles, 3)
            display.setMixerMonitorVisible(false); display.stop()
        } }
    }

    func testApplicationHideNotificationsPauseAndUnhideWithoutWindowOcclusionChange() {
        var hidden = false, states: [Bool] = []
        let native = WindowPresentationVisibility.VisibilityView(changed: { states.append($0) }, applicationHidden: { hidden })
        let window = Window(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = native
        defer { window.close() }
        flush(native)
        XCTAssertEqual(states, [true])
        hidden = true; NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
        XCTAssertEqual(states, [true, false])
        hidden = false; NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: nil)
        XCTAssertEqual(states, [true, false, true])
        // Duplicate notifications cannot create another catch-up request.
        NotificationCenter.default.post(name: NSApplication.didUnhideNotification, object: nil)
        XCTAssertEqual(states.count, 3)
    }
    func testDiagnosticsPauseResumesOneCurrentSampleAndSkipsUnchangedPresentation() throws {
        let f = try MonitorRootFixture(clock: PauseClock()), reader = DiagnosticsReader()
        var samples = 0, publications = 0
        let token = reader.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { token.cancel(); reader.stop(); f.root.terminate {} }
        reader.start {
            samples += 1
            return .read(input: f.root.input, runtime: f.root.runtime, host: f.root.audio, midi: f.root.midi)
        }
        reader.read(); reader.read()
        XCTAssertEqual(samples, 2); XCTAssertEqual(publications, 1)
        reader.beginMeasurement(); reader.setVisible(false)
        let baseline = samples
        for _ in 0..<100 { reader.read() }
        XCTAssertEqual(samples, baseline); XCTAssertTrue(reader.measuring)
        f.root.runtime.panic(); ack(f.root.runtime)
        reader.setVisible(true)
        XCTAssertEqual(samples, baseline + 1); XCTAssertEqual(reader.snapshot?.runtime.panicTimingCount, 1)
        reader.endMeasurement(); XCTAssertFalse(reader.window?.interrupted ?? true)
    }
}
private struct PauseClock: RuntimeClock {
    let now = 0.0
    func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation { .init {} }
}
