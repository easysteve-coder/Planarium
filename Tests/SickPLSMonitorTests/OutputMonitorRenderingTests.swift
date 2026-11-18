import AppKit
import SwiftUI
import XCTest
import PlanariumApplication
@testable import PlanariumDomain
import PlanariumRuntime
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class OutputMonitorRenderingTests: XCTestCase {
    func testMonitorWideNarrowAndUnchangedFramesDoNoPresentationWork() throws {
        _ = NSApplication.shared
        var router = OutputRouter(); router.setMonitorVisible(true)
        router.attach(.init(destination: .midi) { _ in .sent })
        let notes = [0, 4, 7].map { MusicEvent.noteOn(destination: .midi, channel: 0, note: .init(number: UInt8($0), velocity: 100)) }
        let controls = [1, 7, 11].map { MusicEvent.midiValue(destination: .midi, target: .midiCC(channel: 0, controller: UInt8($0)), value: Double($0 + 50) / 127) }
        router.route(notes + controls, sounding: notes, allowOn: true)
        let frame = DisplayFrame(selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]), outputMonitor: router.monitorSnapshots)
        let model = OutputMonitorModel(); model.receive(frame)
        let count = model.evaluations
        for _ in 0..<100 { model.receive(frame) }
        XCTAssertEqual(model.evaluations, count)
        model.paused = true
        let frozen = model.frozenEvents
        router.panic()
        model.receive(.init(selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]), outputMonitor: router.monitorSnapshots))
        XCTAssertEqual(model.frozenEvents, frozen)
        model.paused = false
        XCTAssertNotEqual(model.frozenEvents, frozen, "Resume catches up without requiring another output event")
        // Restore the sounding chord for the presentation evidence.
        router.route(notes + controls, sounding: notes, allowOn: true)
        model.receive(.init(selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]), outputMonitor: router.monitorSnapshots))
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent_handoff/runs/runde-c")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let live = SpatialInstrumentLayer(name: "Live", color: .orange)
        let held = SpatialInstrumentLayer(name: "Held", color: .purple)
        model.layers = [live, held]
        model.owners = [
            .init(layerID: live.id, destination: .midi, channel: 0, number: 0, latched: false),
            .init(layerID: held.id, destination: .midi, channel: 0, number: 4, latched: true)
        ]
        for width in [520, 1000] {
            for zoom in [0.6, 1.0, 2.0] {
                try render(OutputMonitorView(model: model, zoom: zoom), width: width, height: 640,
                    name: "output-monitor-\(width)-\(zoom).png", directory: TestImageDirectory.make())
            }
        }
    }
}

extension OutputMonitorRenderingTests {
    func testHandAndHeldFieldWideNarrowPublishOnlyOnChange() throws {
        let cell = PolarMetricGridCell(ring: 4, angularIndex: 16)
        let layer = SpatialInstrumentLayer(name: "Held C", color: .orange, polarCells: [cell])
        let workspace = SpatialInstrumentWorkspace(layers: [layer])
        let display = SpatialActiveCellDisplayModel()
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".agent_handoff/runs/runde-c")
        for held in [false, true] {
            display.update(profileFrame: nil, activeCells: held ? [:] : [layer.id: cell], heldCells: held ? [layer.id: [cell]] : [:])
            for width in [360, 900] {
                let viewport = try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 1, metersPerPoint: 0.005)
                let geometry = MetricCanvasGeometry(size: .init(width: width, height: 400), viewport: viewport)
                try render(SpatialInstrumentActiveLayer(cells: display, workspace: workspace, geometry: geometry),
                    width: width, height: 400, name: "field-\(held ? "held" : "hand")-\(width).png", directory: directory)
            }
        }
    }
}

extension OutputMonitorRenderingTests {
    private func render<V: View>(_ view: V, width: Int, height: Int, name: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).frame(width: CGFloat(width), height: CGFloat(height)).background(Color(red: 0.06, green: 0.06, blue: 0.07)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height); host.wantsLayer = true
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}

extension OutputMonitorRenderingTests {
    func testClosedAndHiddenMonitorCancelsTheProductionSubscription() async throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let mailbox = DisplayFrameMailbox()
        let runtime = PerformanceRuntime(clock: MonotonicRuntimeClock(), mailbox: mailbox)
        let display = PerformanceDisplayModel(mailbox: mailbox, runtime: runtime)
        display.start(); defer { display.stop() }
        let controller = OutputMonitorWindowController()
        controller.configure(display: display, instrument: fixture.root.document)
        runtime.attach(.init(destination: .midi) { _ in .sent })
        func flush() async {
            await withCheckedContinuation { continuation in runtime.acknowledge { continuation.resume() } }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        await flush()
        XCTAssertEqual(controller.model.evaluations, 0)
        controller.setVisible(true); await flush()
        XCTAssertGreaterThan(controller.model.evaluations, 0, "Positive control: visible production subscription receives actual port frame")
        let visibleCount = controller.model.evaluations
        display.stop(); display.setVisible(false)
        runtime.panic(); await flush()
        XCTAssertGreaterThan(controller.model.evaluations, visibleCount, "The independent monitor keeps the single pump active when the main field disappears")
        let count = controller.model.evaluations
        controller.setVisible(false); await flush()
        for _ in 0..<5 { runtime.panic(); await flush() }
        XCTAssertEqual(controller.model.evaluations, count)
        XCTAssertTrue(mailbox.read()!.outputMonitor.isEmpty)
        controller.setVisible(true); await flush()
        XCTAssertFalse(mailbox.read()!.outputMonitor.isEmpty)
        XCTAssertGreaterThan(controller.model.evaluations, count, "Reopening restarts the pump even with the main field still closed")
        controller.setVisible(false)
    }
}

extension OutputMonitorRenderingTests {
    func testSteadyHeldFramesDoNotRebuildTheFieldAndReleaseDoes() throws {
        let cell = PolarMetricGridCell(ring: 4, angularIndex: 16)
        let layer = SpatialInstrumentLayer(name: "Held", color: .orange, polarCells: [cell])
        let workspace = SpatialInstrumentWorkspace(layers: [layer])
        let display = SpatialActiveCellDisplayModel()
        let viewport = try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 1, metersPerPoint: 0.005)
        let geometry = MetricCanvasGeometry(size: .init(width: 600, height: 400), viewport: viewport)
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        display.update(profileFrame: nil, activeCells: [:], heldCells: [layer.id: [cell]])
        let host = NSHostingView(rootView: SpatialInstrumentActiveLayer(cells: display, workspace: workspace, geometry: geometry))
        host.frame = .init(x: 0, y: 0, width: 600, height: 400)
        let window = PresentingTestWindow(hosting: host, size: .init(width: 600, height: 400))
        defer { window.tearDown() }
        func flush() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        flush()
        let before = probe.counts["field.activeDraw", default: 0], bodies = probe.counts["field.activeBody", default: 0]
        XCTAssertGreaterThan(before, 0)
        let session = UUID()
        for sequence in 1...100 {
            let frame = ProfileFrame(sessionID: session, sequence: UInt64(sequence), time: Double(sequence), measurements: [])
            display.update(profileFrame: frame, activeCells: [:], heldCells: [layer.id: [cell]])
        }
        flush()
        XCTAssertEqual(probe.counts["field.activeDraw", default: 0], before, "Steady held cells are not redrawn per profile")
        display.reset()
        flush()
        XCTAssertGreaterThan(probe.counts["field.activeDraw", default: 0], before, "Release redraws the active layer")
        XCTAssertEqual(probe.counts["field.activeBody", default: 0], bodies, "Cell changes do not re-run SwiftUI")
        XCTAssertTrue(display.frame.heldCells.isEmpty)
    }
}
