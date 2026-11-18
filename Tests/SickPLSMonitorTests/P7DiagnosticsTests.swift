import AppKit
import Dispatch
import SwiftUI
import XCTest
import PlanariumInput
import PlanariumRuntime
import PlanariumAudio
import PlanariumDomain
import SickPLSCore
@testable import SickPLSMonitor

@MainActor final class P7DiagnosticsTests: XCTestCase {
    func testWindowExcludesEarlierSamplesEvenWhenClockValuesAreIdentical() async throws {
        let fixture = try MonitorRootFixture(clock: P7FrozenClock())
        fixture.root.runtime.panic()
        await withCheckedContinuation { continuation in fixture.root.runtime.acknowledge { continuation.resume() } }
        let begin = DiagnosticSnapshot.read(input: fixture.root.input, runtime: fixture.root.runtime, host: fixture.root.audio, midi: fixture.root.midi)
        fixture.root.runtime.panic()
        await withCheckedContinuation { continuation in fixture.root.runtime.acknowledge { continuation.resume() } }
        let end = DiagnosticSnapshot.read(input: fixture.root.input, runtime: fixture.root.runtime, host: fixture.root.audio, midi: fixture.root.midi)
        let window = DiagnosticMeasurementWindow(begin: begin, end: end, interrupted: false)
        XCTAssertEqual(begin.time, end.time)
        XCTAssertEqual(end.runtime.panicTimings.count, 2)
        XCTAssertTrue(window.lines.contains { $0.hasPrefix("Panic → router return: n 1 ") })
    }
    func testMeasurementWindowCopyOnlyAfterEndAndHideInterrupts() async throws {
        let fixture = try MonitorRootFixture()
        let reader = DiagnosticsReader()
        XCTAssertNil(reader.window)
        reader.start { .read(input: fixture.root.input, runtime: fixture.root.runtime, host: fixture.root.audio, midi: fixture.root.midi) }
        reader.beginMeasurement(); XCTAssertTrue(reader.measuring); XCTAssertNil(reader.window)
        fixture.root.runtime.panic()
        await withCheckedContinuation { continuation in fixture.root.runtime.acknowledge { continuation.resume() } }
        reader.endMeasurement()
        XCTAssertFalse(reader.measuring)
        let window = try XCTUnwrap(reader.window)
        XCTAssertFalse(window.interrupted)
        XCTAssertEqual(window.end.runtime.panicTimingCount, 1)
        XCTAssertTrue(window.lines.joined(separator: "\n").contains("Panic → router return: n 1"))
        reader.beginMeasurement(); XCTAssertNil(reader.window)
        reader.stop(); XCTAssertTrue(reader.window?.interrupted == true)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/SickPLSMonitor/DiagnosticsView.swift"))
        XCTAssertTrue(source.contains("if let window, let snapshot"))
    }
    func testReportRejectsSyntheticForeignMarkerIncludingPathsAndPluginErrors() throws {
        let marker = "P7_FAKE_FOREIGN_MARKER"
        let fixture = try MonitorRootFixture(components: MarkerPlugins(marker: marker))
        fixture.root.audio.apply(.init(instrument: .init(identity: .init(componentType: 0x61756d75, componentSubType: 1, componentManufacturer: 2))))
        let snapshot = DiagnosticSnapshot.read(input: fixture.root.input, runtime: fixture.root.runtime, host: fixture.root.audio, midi: fixture.root.midi)
        let window = DiagnosticMeasurementWindow(begin: snapshot, end: snapshot, interrupted: false)
        let text = DiagnosticReportPresentation.copyText(snapshot, window: window,
            build: .init(marketingVersion: marker, buildNumber: "/Users/fictional/" + marker, gitRevision: "secret=" + marker))
        XCTAssertFalse(text.contains(marker)); XCTAssertFalse(text.contains("/Users/")); XCTAssertFalse(text.contains("secret="))
        XCTAssertTrue(text.contains("Version unknown · Build unknown"))
        // A connection failure's arbitrary path/name/message must be discarded
        // before the public presentation, not just scrubbed by the formatter.
        let state = ScanSessionState().applyingConnectFailure(portPath: "/Users/fictional/" + marker, baudRate: .baud38400, message: marker)
        XCTAssertEqual(DiagnosticInputPresentation.status(state.connection), "scanner failed")
    }
    func testDiagnosticsWindowStatesRenderWideAndNarrow() throws {
        let fixture = try MonitorRootFixture()
        let snapshot = DiagnosticSnapshot.read(input: fixture.root.input, runtime: fixture.root.runtime, host: fixture.root.audio, midi: fixture.root.midi)
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for complete in [false, true] {
            let window = complete ? DiagnosticMeasurementWindow(begin: snapshot, end: snapshot, interrupted: false) : nil
            for width in [360, 900] {
                let view = DiagnosticsContent(snapshot: snapshot, window: window, measuring: false, begin: {}, end: {})
                    .padding().background(Color.white).foregroundColor(.black)
                try P7Images.render(view, width: width, height: 720, name: "p7-diagnostics-\(complete ? "window" : "no-window")-\(width).png", directory: directory)
            }
        }
    }
}

private struct P7FrozenClock: RuntimeClock {
    let now: Double = 0
    func schedule(at deadline: Double, on queue: DispatchQueue,
                  _ fire: @escaping @Sendable () -> Void) -> RuntimeCancellation { RuntimeCancellation {} }
}

@MainActor private struct MarkerPlugins: PluginComponentSource {
    let marker: String
    func load(_ identity: SpatialAudioUnitIdentity,
              completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        completion(.failure(.init("/Users/fictional/" + marker + " secret=" + marker)))
    }
}
