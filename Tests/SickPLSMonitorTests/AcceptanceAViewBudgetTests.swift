import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import PlanariumDomain
import PlanariumRuntime
import PlanariumPresets
import SickPLSCore
import Combine
import PlanariumApplication
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class AcceptanceAViewBudgetTests: XCTestCase {
    /// Control measurement for framework work that is deferred beyond the
    /// meter publisher. Includes hosting/run-loop overhead; not additive to
    /// the mixed profile/meter workload below.
    func testMeterOnlyMainThreadCost() throws {
        guard ProcessInfo.processInfo.environment["SICK_VIEW_COST"] == "1" else {
            throw XCTSkip("Opt-in meter-only main-thread cost")
        }
        let fixture = try MonitorRootFixture(), reader = ChannelMeterReader(), owner = fixture.root.document
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmony 27 Harmony Codex"))
        try owner.applyPresetDocument(try PresetDocumentReader.read(data).get().replacing(owner.document))
        let layout = try LayoutWorkspaceFixture(fixture: fixture, reader: reader)
        defer { layout.cleanDefaults(); fixture.root.display.stop(); reader.stop(); fixture.root.terminate {} }
        let view = NSHostingView(rootView: Workspace(layout: layout).preferredColorScheme(.dark))
        view.frame = .init(x: 0, y: 0, width: 1500, height: 1000); view.wantsLayer = true
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        fixture.root.display.stop()
        for publishes in [false, true] {
            let startCPU = try XCTUnwrap(currentThreadCPUSeconds())
            let start = ProcessInfo.processInfo.systemUptime
            var nextMeter = start, meters = 0
            while ProcessInfo.processInfo.systemUptime - start < 3 {
                if publishes && ProcessInfo.processInfo.systemUptime >= nextMeter {
                    nextMeter += 1.0 / 30; meters += 1
                    reader.observe(.init(left: Float(meters % 10) / 10, right: 0.2), elapsed: 1.0 / 30)
                }
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
            let wall = ProcessInfo.processInfo.systemUptime - start
            let cpu = try XCTUnwrap(currentThreadCPUSeconds()) - startCPU
            print("METER-CONTROL publishes=\(publishes) ticks=\(meters) cpu_us_per_profile_at25Hz=\(cpu * 1e6 / (wall * 25)) mainCPU=\(cpu / wall * 100)%")
            if publishes { XCTAssertGreaterThanOrEqual(meters, 85) }
        }
    }

    func testDetectionSectionCosts() throws {
        guard ProcessInfo.processInfo.environment["SICK_VIEW_COST"] == "1" else {
            throw XCTSkip("Opt-in main-thread section costs")
        }
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmony 27 Harmony Codex"))
        try owner.applyPresetDocument(try PresetDocumentReader.read(data).get().replacing(owner.document))
        fixture.root.display.stop()
        let config = owner.document.detection.effective
        for count in [90, 361] {
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { index in
                try .build(value: abs(index - count / 2) < 3 ? 100 : 250, fieldFlags: 0)
            })
            let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
                measurements: try FullScanProfileAdapter.measurements(from: raw),
                geometry: try FullScanProfileAdapter.geometry(from: raw))
            let projected = config.beams.virtualMMK(frame.projectedMeasurements, geometry: frame.geometry)
            let groups = config.groups.makeGroups(projected)
            let trimmed = groups.map { config.edge.trimEdges($0, minimumPoints: config.groups.groupingMinimumPoints) }
            let separated = config.groups.separatedGroups(trimmed, measurements: frame.measurements)
            let probe = CanvasTimingProbe(clock: { self.requiredThreadCPUSeconds() })
            CanvasTimingProbe.current = probe
            defer { CanvasTimingProbe.current = nil }
            for _ in 0..<300 {
                _ = CanvasTimingProbe.measure("beams") { config.beams.virtualMMK(frame.projectedMeasurements, geometry: frame.geometry) }
                _ = CanvasTimingProbe.measure("groups") { config.groups.makeGroups(projected) }
                _ = CanvasTimingProbe.measure("edge") { groups.map { config.edge.trimEdges($0, minimumPoints: config.groups.groupingMinimumPoints) } }
                _ = CanvasTimingProbe.measure("angular") { config.groups.separatedGroups(trimmed, measurements: frame.measurements) }
                _ = CanvasTimingProbe.measure("core") { separated.map { config.core.corePoints($0) } }
            }
            for stage in probe.milliseconds.keys.sorted() {
                print("DETECTION-SECTION rays=\(count) stage=\(stage) cpu_us_per_profile=\(probe.milliseconds[stage]! * 1000 / 300)")
            }
        }
    }

    /// Opt-in comparison probe: identical frames/configurations on the old
    /// and stage-based detectors; kept out of the ordinary test budget.
    func testDetectionScanCostComparison() throws {
        guard ProcessInfo.processInfo.environment["SICK_DETECTION_COST"] == "1" else {
            throw XCTSkip("Opt-in scan-cost comparison")
        }
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmony 27 Harmony Codex"))
        try owner.applyPresetDocument(try PresetDocumentReader.read(data).get().replacing(owner.document))
        fixture.root.display.stop()
        let session = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        for count in [90, 361] {
            let frames = try (0..<30).map { sample -> ProfileFrame in
                let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { index in
                    try .build(value: abs(index - count / 2) < 3 ? UInt16(90 + sample) : 250, fieldFlags: 0)
                })
                return ProfileFrame(sessionID: session, sequence: UInt64(sample), time: Double(sample) / 25,
                    measurements: try FullScanProfileAdapter.measurements(from: raw),
                    geometry: try FullScanProfileAdapter.geometry(from: raw))
            }
            for core in [UInt8(0), 3] {
                for smoothing in [DetectionTemporalSmoothing.off, .exponential(alpha: 0.5)] {
                    for mmk in [VirtualMMKMode.raw, .adaptive] {
                        var document = owner.document
                        document.detection.coreWidthCentimeters = core
                        document.detection.temporalSmoothing = smoothing
                        document.detection.virtualMMKMode = mmk
                        let compiled = try InstrumentCompiler.compile(document)
                        var detector = SpatialDetectionPipeline()
                        for frame in frames { _ = detector.select(frame: frame, instrument: compiled, contour: nil) }
                        var checksum: UInt64 = 0
                        let start = try XCTUnwrap(currentThreadCPUSeconds())
                        for index in 0..<300 {
                            let result = detector.select(frame: frames[index % frames.count], instrument: compiled, contour: nil)
                            for object in result.objects { checksum = checksum &+ object.representative.distanceCentimeters.bitPattern }
                        }
                        let microseconds = (try XCTUnwrap(currentThreadCPUSeconds()) - start) * 1e6 / 300
                        print("DETECTION-COST rays=\(count) core=\(core) temporal=\(smoothing) mmk=\(mmk) scans=300 cpu_us_per_scan=\(microseconds) checksum=\(checksum)")
                        XCTAssertNotEqual(checksum, 0)
                    }
                }
            }
        }
    }
    private struct Workspace: View {
        let layout: LayoutWorkspaceFixture
        var body: some View {
            let _ = ViewEvaluationProbe.current?.record("workspace")
            layout.view
        }
    }
    func testProfile25HzMeter30HzInvalidateOnlyCanvasAndMeter90And361() throws {
        try measureProfile25HzMeter30Hz(monitorVisible: false)
    }
    func testOpenOutputMonitorAt90And361MeasuresAdditionalPresentationCost() throws {
        try measureProfile25HzMeter30Hz(monitorVisible: true)
    }
    func testLayoutDisplayAreaAnalysis() throws {
        guard ProcessInfo.processInfo.environment["SICK_LAYOUT_ANALYSIS"] == "1" else {
            throw XCTSkip("Opt-in native layout/display area analysis")
        }
        for variant in ["full", "noMixer", "noInspector"] {
            try measureProfile25HzMeter30Hz(monitorVisible: false, analysisVariant: variant)
        }
    }
    private func measureProfile25HzMeter30Hz(monitorVisible: Bool, analysisVariant: String? = nil) throws {
        for count in [90, 361] {
            let fixture = try MonitorRootFixture(), reader = ChannelMeterReader()
            let owner = fixture.root.document
            let data: Data
            if let path = ProcessInfo.processInfo.environment["SICK_ACCEPTANCE_PRESET"] {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmony 27 Harmony Codex"))
            }
            try owner.applyPresetDocument(try PresetDocumentReader.read(data).get().replacing(owner.document))
            let layout = try LayoutWorkspaceFixture(fixture: fixture, reader: reader)
            defer { layout.cleanDefaults() }
            if analysisVariant == "noMixer" { layout.workspace.setVisible(.channelStrip, false) }
            if analysisVariant == "noInspector" {
                layout.workspace.setVisible(.layers, false); layout.workspace.setVisible(.cell, false)
            }
            var dirtyAreas: [String: Int] = [:]
            // Read native dirty flags before draining display. Rectangles are in
            // root coordinates; parent/child areas overlap and must not be summed.
            func inspect(_ node: NSView, tick: String) {
                if node.needsDisplay {
                    let rect = viewRect(node)
                    let key = "\(tick) \(type(of: node)) rect=\(rect)"
                    dirtyAreas[key, default: 0] += 1
                }
                for child in node.subviews { inspect(child, tick: tick) }
            }
            func viewRect(_ node: NSView) -> NSRect { node.convert(node.bounds, to: view) }
            let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
            defer { ViewEvaluationProbe.current = nil; fixture.root.display.stop(); reader.stop() }
            let view = RootLayoutCountingHost(rootView: Workspace(layout: layout).preferredColorScheme(.dark))
            view.frame = .init(x: 0, y: 0, width: 1500, height: 1000); view.wantsLayer = true
            // Production always draws inside a window; native live layers only
            // display there. Offscreen and never ordered front.
            let window = PresentingTestWindow(hosting: view, size: .init(width: 1500, height: 1000))
            defer { window.tearDown() }
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            fixture.root.display.stop() // paced harness supplies the exact production read
            let traceLayouts = ProcessInfo.processInfo.environment["SICK_LAYOUT_TRACE"] == "1"
            if traceLayouts { HostLayoutTrace.install(in: view) }
            probe.reset(); view.rootLayouts = 0; HostLayoutTrace.counts = [:]
            let session = UUID(), compiled = try InstrumentCompiler.compile(owner.document)
            var detector = SpatialDetectionPipeline()
            let harnessQueue = DispatchQueue(label: "AcceptanceA.profileHarness")
            let mailbox = fixture.root.runtime.mailbox
            var harnessCosts: [String: Double] = [:]
            let costProbe = ProcessInfo.processInfo.environment["SICK_VIEW_COST"] == "1"
                ? CanvasTimingProbe(clock: { self.requiredThreadCPUSeconds() }) : nil
            CanvasTimingProbe.current = costProbe
            defer { CanvasTimingProbe.current = nil }
            let monitor = OutputMonitorModel(); monitor.layers = owner.canvas.workspace.layers
            let monitorHost = NSHostingView(rootView: OutputMonitorView(model: monitor))
            monitorHost.frame = .init(x: 0, y: 0, width: 960, height: 620); monitorHost.wantsLayer = true
            var router = OutputRouter(); router.setMonitorVisible(monitorVisible)
            if monitorVisible { router.attach(.init(destination: .midi) { _ in .sent }) }
            var playState = PlayEngine.step(PlayState(), .install(compiled)).0
            let subscription = fixture.root.display.$frame.sink { frame in
                if monitorVisible, let frame { monitor.receive(frame) }
            }
            defer { subscription.cancel() }
            if monitorVisible { monitorHost.layoutSubtreeIfNeeded(); monitorHost.displayIfNeeded() }
            let startCPU = try XCTUnwrap(currentThreadCPUSeconds())
            let textureGenerations = StudioTextureCache.generations
            let start = ProcessInfo.processInfo.systemUptime
            var nextProfile = start, nextMeter = start
            var profiles = 0, meters = 0
            while ProcessInfo.processInfo.systemUptime - start < 3 {
                var tick = "idle"
                let now = ProcessInfo.processInfo.systemUptime
                if now >= nextProfile {
                    tick = "profile"
                    nextProfile += 1.0 / 25; profiles += 1
                    // DispatchWorkItem + wait guarantees execution on the worker
                    // (queue.sync may execute inline on Main). Waiting preserves
                    // the existing exact tick/read order without charging worker
                    // CPU to Main; no work survives the tick or fixture teardown.
                    var harnessError: Error?
                    let produce = DispatchWorkItem {
                        do {
                            let buildStart = costProbe == nil ? nil : self.currentThreadCPUSeconds()
                            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { index in
                                try .build(value: abs(index - count / 2) < 3 ? UInt16(90 + profiles % 30) : 250, fieldFlags: 0)
                            })
                            let frame = ProfileFrame(sessionID: session, sequence: UInt64(profiles), time: now,
                                measurements: try FullScanProfileAdapter.measurements(from: raw),
                                geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
                            if let buildStart, let end = self.currentThreadCPUSeconds() {
                                harnessCosts["harness.profile", default: 0] += end - buildStart
                            }
                            let detectionStart = costProbe == nil ? nil : self.currentThreadCPUSeconds()
                            let selection = detector.select(frame: frame, instrument: compiled, contour: nil)
                            if let detectionStart, let end = self.currentThreadCPUSeconds() {
                                harnessCosts["harness.detection", default: 0] += end - detectionStart
                            }
                            let writeStart = costProbe == nil ? nil : self.currentThreadCPUSeconds()
                            mailbox.write(.init(profile: frame, contour: nil, selection: selection,
                                revision: compiled.revision, sessionID: session, processedProfiles: UInt64(profiles),
                                soundingNoteOwners: [], outputMonitor: [], heldCells: []))
                            if let writeStart, let end = self.currentThreadCPUSeconds() {
                                harnessCosts["harness.mailbox", default: 0] += end - writeStart
                            }
                        } catch { harnessError = error }
                    }
                    if monitorVisible {
                        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { index in
                            try .build(value: abs(index - count / 2) < 3 ? UInt16(90 + profiles % 30) : 250, fieldFlags: 0)
                        })
                        let frame = ProfileFrame(sessionID: session, sequence: UInt64(profiles), time: now,
                            measurements: try FullScanProfileAdapter.measurements(from: raw),
                            geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
                        let selection = CanvasTimingProbe.measure("budget.detection") {
                            detector.select(frame: frame, instrument: compiled, contour: nil)
                        }
                        if monitorVisible {
                            let next = PlayEngine.step(playState, .frame(frame)); playState = next.0
                            router.route(next.1, sounding: playState.soundingEvents, allowOn: true)
                        }
                        fixture.root.runtime.mailbox.write(.init(profile: frame, contour: nil, selection: selection,
                            revision: compiled.revision, sessionID: session, processedProfiles: UInt64(profiles),
                            soundingNoteOwners: monitorVisible ? playState.soundingNoteOwners : [], outputMonitor: router.monitorSnapshots,
                            heldCells: monitorVisible ? playState.heldCells : []))
                    } else {
                        harnessQueue.async(execute: produce)
                        produce.wait()
                        if let harnessError { throw harnessError }
                    }
                    CanvasTimingProbe.measure("budget.display") { fixture.root.display.read() }
                }
                if now >= nextMeter {
                    tick += "+meter"
                    nextMeter += 1.0 / 30; meters += 1
                    CanvasTimingProbe.measure("budget.meterPublish") {
                        reader.observe(.init(left: Float(meters % 10) / 10, right: 0.2), elapsed: 1.0 / 30)
                    }
                }
                if monitorVisible {
                    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                    monitorHost.layoutSubtreeIfNeeded(); monitorHost.displayIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                } else {
                    if analysisVariant != nil, profiles <= 3 { inspect(view, tick: "beforeLayout/" + tick) }
                    if traceLayouts {
                        func dirty(_ node: NSView) { if node.needsLayout { HostLayoutTrace.counts["needsLayout " + String(describing: type(of: node)).prefix(120), default: 0] += 1 }
                            if node.needsUpdateConstraints { HostLayoutTrace.counts["needsConstraints " + String(describing: type(of: node)).prefix(120), default: 0] += 1 }
                            node.subviews.forEach(dirty) }
                        dirty(view)
                    }
                    CanvasTimingProbe.measure("budget.layoutDisplay") {
                        // The window's own update cycle, as AppKit runs it after each
                        // event: layout only where flagged, then dirty views and layers.
                        CanvasTimingProbe.measure("budget.layout") { window.layoutIfNeeded() }
                        CanvasTimingProbe.measure("budget.nativeDisplay") { window.displayIfNeeded() }
                    }
                    if analysisVariant != nil, profiles <= 3 { inspect(view, tick: "afterDisplay/" + tick) }
                    CanvasTimingProbe.measure("budget.runLoop") {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                    }
                }
            }
            XCTAssertEqual(StudioTextureCache.generations, textureGenerations, "Profile/meter updates must reuse material textures")
            let wall = ProcessInfo.processInfo.systemUptime - start
            let percent = (try XCTUnwrap(currentThreadCPUSeconds()) - startCPU) / wall * 100
            if let costProbe {
                for stage in harnessCosts.keys.sorted() {
                    print("VIEW-COST rays=\(count) stage=\(stage) cpu_us_per_profile=\(harnessCosts[stage]! * 1e6 / Double(profiles))")
                }
                for stage in costProbe.milliseconds.keys.sorted() {
                    print("VIEW-COST rays=\(count) stage=\(stage) cpu_us_per_profile=\(costProbe.milliseconds[stage]! * 1000 / Double(profiles))")
                }
            }
            if let analysisVariant {
                print("LAYOUT-ANALYSIS variant=\(analysisVariant) rays=\(count)")
                print("NATIVE-DIRTY distinctRects=\(dirtyAreas.count) sampledProfileTicks=3 (before layout / after display)")
                for key in dirtyAreas.keys.sorted() { print("NATIVE-DIRTY samples=\(dirtyAreas[key]!) \(key)") }
            }
            print("ABNAHME-A monitorOpen=\(monitorVisible) view rays=\(count) layers=\(owner.document.spatial.layers.count) fineCells=\(compiled.statistics.indexedAddressCount) profileTicks=\(profiles) meterTicks=\(meters) mainCPU=\(percent)% bodies=\(probe.counts)")
            reportPerformance("view/\(count)", samples: [percent], unit: "main-thread-CPU-percent")
            print("BUDGET lastabhaengig: mainCPU < 25%; Taktvollstaendigkeit profiles >= 70, meters >= 85")
            print("BUDGET deterministisch: keine Invalidierung von workspace/channel/root/layers/cell; measurement/field <= 1")
            XCTAssertGreaterThanOrEqual(profiles, 70); XCTAssertGreaterThanOrEqual(meters, 85)
            if analysisVariant == nil {
            XCTAssertEqual(probe.counts["workspace", default: 0], 0)
            XCTAssertLessThanOrEqual(probe.counts["measurement", default: 0], 1, "Only initial measurement availability may update controls")
            XCTAssertLessThanOrEqual(probe.counts["field", default: 0], 1)
            XCTAssertEqual(probe.counts["channel", default: 0], 0)
            XCTAssertEqual(probe.counts["root", default: 0], 0)
            XCTAssertEqual(probe.counts["layers", default: 0], 0)
            XCTAssertEqual(probe.counts["cell", default: 0], 0)
            XCTAssertGreaterThan(probe.counts["canvas", default: 0], 50, "Freshness: profiles are drawn natively")
            XCTAssertLessThanOrEqual(probe.counts["canvasBody", default: 0], 1, "Profiles do not re-run SwiftUI for the live layer")
            XCTAssertGreaterThan(probe.counts["meter", default: 0], 50)
            if !monitorVisible {
                // LIVE-NATIV: neither profiles nor level ticks lay out the window's
                // SwiftUI host. The two allowed passes are measurement availability
                // and the first meter activation after mounting.
                XCTAssertLessThanOrEqual(view.rootLayouts, 2, "Live presentation must not lay out the root host")
            }
            print("LIVE-NATIV rootLayouts=\(view.rootLayouts) profiles=\(profiles) meters=\(meters)")
            if traceLayouts { for (name, n) in HostLayoutTrace.counts.sorted(by: { $0.value > $1.value }) { print("HOST-LAYOUT \(n) \(name.prefix(220))") } }
            if monitorVisible { XCTAssertGreaterThan(monitor.evaluations, 0) }
            else { XCTAssertLessThan(percent, 25) }
            }
            var done = false; fixture.root.terminate { done = true }
            let deadline = Date().addingTimeInterval(3)
            while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
            XCTAssertTrue(done)
        }
    }
    private func requiredThreadCPUSeconds() -> Double {
        guard let seconds = currentThreadCPUSeconds() else {
            XCTFail("Thread CPU sampling failed")
            return 0
        }
        return seconds
    }
    nonisolated private func currentThreadCPUSeconds() -> Double? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
             + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }
}

@MainActor final class SelectionTempoTests: XCTestCase {
    /// Headless AppKit may leave NSEvent.window nil even for an owned offscreen
    /// window. Keep the native event coordinates/type, and bind its test owner
    /// explicitly as the existing routed scroll-event harness does.
    private final class RoutedMouseEvent: NSEvent {
        let target: NSWindow
        let backing: NSEvent
        init(window: NSWindow, backing: NSEvent) { target = window; self.backing = backing; super.init() }
        required init?(coder: NSCoder) { fatalError("Unused test event decoder") }
        override var window: NSWindow? { target }
        override var windowNumber: Int { backing.windowNumber }
        override var type: NSEvent.EventType { backing.type }
        override var locationInWindow: NSPoint { backing.locationInWindow }
        override var modifierFlags: NSEvent.ModifierFlags { backing.modifierFlags }
        override var clickCount: Int { backing.clickCount }
    }

    private struct Harness: View {
        let fixture: MonitorRootFixture
        let catalog: AudioCatalogModel
        let cells = SpatialActiveCellDisplayModel()
        var body: some View {
            HStack(spacing: 0) {
                CartesianScanFieldView(editor: fixture.root.document.canvas, profile: nil,
                    activeCellDisplay: cells, spatialInstrument: fixture.root.document,
                    simulationBadge: AnyView(EmptyView())).frame(width: 900)
                StableSpatialLayerInspectorView(editor: fixture.root.document.canvas,
                    audioUnits: catalog, midiOutput: fixture.root.midi,
                    spatialInstrument: fixture.root.document, evaluationCounter: nil).equatable()
                DocumentConsumer(owner: fixture.root.document).frame(width: 1)
            }.preferredColorScheme(.dark)
        }
    }
    private struct DocumentConsumer: View {
        @ObservedObject var owner: SpatialInstrumentRuntimeModel
        var body: some View {
            let _ = ViewEvaluationProbe.current?.record("selection.documentConsumer")
            Text(owner.document.channelName)
        }
    }
    private func pointers(_ view: NSView) -> [ScanFieldPointerEvents.PointerView] {
        if let pointer = view as? ScanFieldPointerEvents.PointerView { return [pointer] }
        return view.subviews.flatMap(pointers)
    }
    private func retainedMusicHost(_ view: NSView) -> NSView? {
        if view.identifier?.rawValue == "inspector.retainedMusic" { return view }
        return view.subviews.compactMap(retainedMusicHost).first
    }
    private func flush(_ host: NSView) {
        func inspectorHost(_ view: NSView) -> NSHostingView<LayerInspectorView>? {
            if let found = view as? NSHostingView<LayerInspectorView> { return found }
            return view.subviews.compactMap(inspectorHost).first
        }
        CanvasTimingProbe.measure("hosting.inspectorLayout") { inspectorHost(host)?.layoutSubtreeIfNeeded() }
        CanvasTimingProbe.measure("hosting.firstLayout") { host.layoutSubtreeIfNeeded() }
        CanvasTimingProbe.measure("hosting.runLoop") { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        CanvasTimingProbe.measure("hosting.finalLayoutDisplay") { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    }
    private func send(_ type: NSEvent.EventType, clicks: Int = 1,
                      point: CGPoint? = nil, pointer: ScanFieldPointerEvents.PointerView,
                      window: NSWindow) throws {
        let location = point ?? CGPoint(x: pointer.isKeyboardOnly ? 50 : pointer.bounds.midX, y: pointer.bounds.midY)
        let content = try XCTUnwrap(window.contentView)
        let hitPoint = content.superview?.convert(location, from: pointer) ?? content.convert(location, from: pointer)
        let hit = content.hitTest(hitPoint)
        XCTAssertTrue(hit === pointer,
                      "AppKit hit testing must reach the production responder (row=\(pointer.isKeyboardOnly), hit=\(String(describing: hit)))")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
            location: pointer.convert(location, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
        let routed = RoutedMouseEvent(window: window, backing: event)
        XCTAssertTrue(routed.window === pointer.window)
        XCTAssertNil(pointer.handle(routed), "Native production responder must consume the click")
    }
    private func load(_ name: String, owner: SpatialInstrumentRuntimeModel) throws {
        let data: Data
        if name == "Keller 03 Zwei Haende" {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            data = try Data(contentsOf: root.appendingPathComponent("PlanariumPresetsTests/Fixtures/SelectionTempo/keller-03.json"))
        } else { data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: name)) }
        var document = try PresetDocumentReader.read(data).get().replacing(owner.document)
        if ProcessInfo.processInfo.environment["SICK_SELECTION_GRID_CENTIMETERS"] == "25", name.hasPrefix("Harmony") {
            document.editorGrid = .quarterMeter
        }
        try owner.applyPresetDocument(document)
    }
    private func retainedControlHosts(_ view: NSView) -> [NSView] {
        if view.identifier?.rawValue.hasPrefix("inspector.retained.") == true { return [view] }
        return view.subviews.flatMap(retainedControlHosts)
    }
    private func nativeControls(_ view: NSView) -> [NSControl] {
        (view as? NSControl).map { [$0] } ?? view.subviews.flatMap(nativeControls)
    }
    private func textFields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
    }
    private func image(_ host: NSView, name: String, directory: URL) throws {
        // In a hidden window, an incremental cache can contain only the
        // newly mounted text field. Relayout the entire surface before proof.
        let frame = host.frame
        host.frame.size.width += 1
        flush(host)
        host.frame = frame
        flush(host)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let background = try XCTUnwrap(bitmap.colorAt(x: max(10, bitmap.pixelsWide - 20), y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(background.alphaComponent, 0.9, "Proof must include the complete inspector background")
        XCTAssertGreaterThan(background.redComponent, 0.05, "A partial/empty hidden-window cache is not a UI proof")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }
    func testFirstNativeDoubleClickOpensRenameWithStableFontAndColumnWideAndNarrow() throws {
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [600, 360] {
            let fixture = try MonitorRootFixture(), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            try load("Keller 03 Zwei Haende", owner: owner)
            fixture.root.display.stop()
            let host = NSHostingView(rootView: StableSpatialLayerInspectorView(editor: owner.canvas,
                audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()), midiOutput: fixture.root.midi,
                spatialInstrument: owner, evaluationCounter: nil).preferredColorScheme(.dark))
            host.frame = .init(x: 0, y: 0, width: width, height: 900); host.wantsLayer = true
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 900),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            flush(host)
            defer { pointers(host).forEach { $0.stopListening() }; window.orderOut(nil); window.contentView = nil; window.close() }
            let rows = pointers(host).filter(\.isKeyboardOnly).sorted {
                $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY
            }
            XCTAssertEqual(rows.count, owner.canvas.workspace.layers.count, "Exactly one native responder per row")
            let native = try XCTUnwrap(rows.dropFirst().first)
            let layer = owner.canvas.workspace.layers[1], revision = owner.document.revision
            try image(host, name: "rename-before-\(width)", directory: directory)
            try send(.leftMouseDown, pointer: native, window: window)
            try send(.leftMouseUp, pointer: native, window: window)
            flush(host)
            XCTAssertEqual(owner.canvas.workspace.selectedLayerID, layer.id)
            XCTAssertFalse(textFields(host).contains { $0.stringValue == layer.name && $0.isEditable })
            try image(host, name: "rename-selected-\(width)", directory: directory)
            let current = try XCTUnwrap(pointers(host).first { $0 === native })
            try send(.leftMouseDown, clicks: 2, pointer: current, window: window)
            try send(.leftMouseUp, clicks: 2, pointer: current, window: window)
            flush(host)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            flush(host)
            let field = try XCTUnwrap(textFields(host).first { $0.stringValue == layer.name && $0.isEditable },
                                     "The first double click must open the production RenameEntryField")
            XCTAssertEqual(field.font?.pointSize, 13)
            XCTAssertEqual(field.font?.fontDescriptor.symbolicTraits.contains(.bold), false)
            let textEditor = try XCTUnwrap(window.firstResponder as? NSTextView,
                "key=\(window.isKeyWindow), first=\(String(describing: window.firstResponder)), fieldWindow=\(field.window === window)")
            XCTAssertEqual(textEditor.string, layer.name)
            XCTAssertEqual(textEditor.selectedRange(), NSRange(location: 0, length: layer.name.utf16.count))
            XCTAssertEqual(owner.document.revision, revision)
            try image(host, name: "rename-editing-\(width)", directory: directory)
            var publications = 0
            let subscription = owner.$document.dropFirst().sink { _ in publications += 1 }
            defer { subscription.cancel() }
            let timing = CanvasTimingProbe(); CanvasTimingProbe.current = timing
            defer { CanvasTimingProbe.current = nil }
            for character in "ABCDEFGHIJ" {
                textEditor.insertText(String(character), replacementRange: textEditor.selectedRange())
                flush(host)
                XCTAssertEqual(owner.document.revision, revision)
                XCTAssertEqual(publications, 0)
            }
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            textEditor.keyDown(with: enter); flush(host)
            XCTAssertEqual(owner.canvas.workspace.layers.first { $0.id == layer.id }?.name, "ABCDEFGHIJ")
            XCTAssertEqual(publications, 1)
            XCTAssertEqual(timing.counts["runtime.compile", default: 0], 0)
            XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.canvas.workspace.layers.first { $0.id == layer.id }?.name, layer.name)
            XCTAssertTrue(owner.redo()); XCTAssertEqual(owner.canvas.workspace.layers.first { $0.id == layer.id }?.name, "ABCDEFGHIJ")
        }
    }
    func testInspectionSelectionLeavesUndoRedoAndPresetSelectionIntact() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        try load("Keller 03 Zwei Haende", owner: owner)
        let first = owner.canvas.workspace.layers[0].id, second = owner.canvas.workspace.layers[1].id
        let before = owner.document.spatial.layers
        owner.canvas.updateWorkspace(named: "Actual name edit") { $0.updateSelectedLayer { $0.name = "Changed" } }
        let editedRevision = owner.document.revision
        let inspector = LayerInspectorView(editor: owner.canvas,
            audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()), midiOutput: fixture.root.midi,
            spatialInstrument: owner, evaluationCounter: nil)
        inspector.selectLayerForInspection(second)
        XCTAssertEqual(owner.document.revision, editedRevision)
        XCTAssertEqual(owner.undoMenuTitle, "Undo: Actual name edit")
        XCTAssertEqual(try owner.snapshotPresetDocument().spatial.selectedLayerID, second)
        let inspectionSelection = owner.canvas.selection
        XCTAssertTrue(owner.undo())
        XCTAssertEqual(owner.document.spatial.layers, before)
        XCTAssertEqual(owner.canvas.workspace.selectedLayerID, second)
        XCTAssertEqual(owner.canvas.selection, inspectionSelection, "Undo of a real metadata edit must not undo the subsequent inspection selection")
        inspector.selectLayerForInspection(first)
        XCTAssertTrue(owner.canRedo, "Selection must not clear a real edit's redo")
        XCTAssertTrue(owner.redo())
        XCTAssertEqual(owner.canvas.workspace.selectedLayerID, first)
        XCTAssertEqual(owner.document.spatial.layers.first?.name, "Changed")
        let snapshot = try owner.snapshotPresetDocument()
        let roundTrip = try JSONDecoder().decode(InstrumentDocument.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundTrip.spatial.selectedLayerID, first)
        XCTAssertEqual(roundTrip.spatial.layers, snapshot.spatial.layers)
        let unknown = UUID()
        XCTAssertThrowsError(try snapshot.spatial.selectingLayer(unknown)) { error in
            XCTAssertEqual(error as? SpatialDocumentError, .unknownSelection(unknown))
        }
        let selected = try snapshot.spatial.selectingLayer(second)
        XCTAssertEqual(selected.layers, snapshot.spatial.layers)
        inspector.selectLayerForInspection(second)
        owner.updateMasterLevel(-12)
        XCTAssertEqual(owner.canvas.workspace.selectedLayerID, second, "An unrelated real document edit must preserve the session's active layer")
        XCTAssertEqual(owner.document.spatial.selectedLayerID, second)
        XCTAssertTrue(owner.undo())
        XCTAssertEqual(owner.canvas.workspace.selectedLayerID, second)
        _ = owner.canvas.selectLayers([second], active: second)
        var canvasPublications = 0
        let subscription = owner.canvas.objectWillChange.sink { canvasPublications += 1 }
        defer { subscription.cancel() }
        owner.canvas.holdHand(false)
        _ = owner.canvas.selectLayers([second], active: second)
        XCTAssertEqual(canvasPublications, 0, "Focus cleanup and repeated selection must not republish unchanged state")
    }
    func testNativeLayerAndCellSelectionVisibleWithinFiftyMillisecondsWithoutDocumentPublication() throws {
        try exerciseNativeSelection(assertTime: true)
    }

    func testNativeSelectionWorkIsBoundedEvenWithAdditionalScenes() throws {
        // Scene count magnifies the old error (two entire rows rebuilt per
        // selection). The same zero-rebuild bound must hold for every preset.
        try exerciseNativeSelection(assertTime: false, additionalScenes: 6)
    }

    func testOptInSelectionImagesWideAndNarrow() throws {
        guard ProcessInfo.processInfo.environment["SICK_SELECTION_IMAGES"] == "1" else {
            throw XCTSkip("Opt-in selection image comparison")
        }
        try exerciseNativeSelection(assertTime: false, captureImages: true)
    }

    private struct InspectorSwitchHarness: View {
        let fixture: MonitorRootFixture
        let catalog: AudioCatalogModel
        let width: CGFloat
        let cells = SpatialActiveCellDisplayModel()
        var body: some View {
            HStack(spacing: 0) {
                CartesianScanFieldView(editor: fixture.root.document.canvas, profile: nil,
                    activeCellDisplay: cells, spatialInstrument: fixture.root.document,
                    simulationBadge: AnyView(EmptyView())).frame(width: 900)
                StableSpatialLayerInspectorView(editor: fixture.root.document.canvas,
                    audioUnits: catalog, midiOutput: fixture.root.midi,
                    spatialInstrument: fixture.root.document, evaluationCounter: nil).equatable().frame(width: width)
                CellInspectorView(editor: fixture.root.document.canvas).frame(width: width)
            }.preferredColorScheme(.dark)
        }
    }

    func testInspectorContentSwitchWorkIsBounded() throws {
        try exerciseInspectorSwitch()
    }

    func testOptInInspectorContentSwitchImages() throws {
        guard ProcessInfo.processInfo.environment["SICK_INSPECTOR_IMAGES"] == "1" else {
            throw XCTSkip("Opt-in inspector switch image comparison")
        }
        for kind: String? in [nil, "cc", "pc"] {
            try exerciseInspectorSwitch(images: true, controlKind: kind)
        }
    }

    func testCCProgramAndSingleNoteInspectorSwitchWorkIsBounded() throws {
        for kind in ["cc", "pc", "note"] { try exerciseInspectorSwitch(controlKind: kind) }
    }

    private func exerciseInspectorSwitch(images: Bool = false, controlKind: String? = nil) throws {
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for preset in ["Harmony 29 Picardy Switch", "Harmony 30 Mode Wheel", "Keller 03 Zwei Haende"] {
            for width: CGFloat in (images ? [600, 360] : [600]) {
                let fixture = try MonitorRootFixture(), owner = fixture.root.document
                defer { fixture.root.terminate {} }
                try load(preset, owner: owner)
                // The saved Keller fixture has only chords. The variants
                // author one existing cell's layer through the normal document
                // boundary; no factory/preset file or runtime output is changed.
                if let kind = controlKind ?? (preset == "Keller 03 Zwei Haende" ? "cc" : nil) {
                    owner.canvas.updateWorkspace(named: "Inspector comparison: " + kind) { workspace in
                        let id = workspace.layers.last!.id
                        workspace.updateLayer(id) { layer in
                            switch kind {
                            case "cc": layer.routings = [.init(target: .midiCC(channel: 0, controller: 74), program: .constant(0.5))]
                            case "pc": layer.routings = [.init(target: .midiProgramChange(channel: 0), program: .programChange(.init(program: 10, bankMSB: 2, bankLSB: 3)))]
                            case "note": layer.routings = [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .legato))]
                            default: XCTFail("Unknown comparison kind")
                            }
                            layer.polarCellOverrides = [:]
                        }
                    }
                }
                fixture.root.display.stop()
                let host = NSHostingView(rootView: InspectorSwitchHarness(fixture: fixture,
                    catalog: AudioCatalogModel(document: owner, source: EmptyCatalog()), width: width))
                let size = CGSize(width: 900 + 2 * width, height: 1000)
                host.frame = .init(origin: .zero, size: size); host.wantsLayer = true
                let window = NSWindow(contentRect: .init(origin: CGPoint(x: -10000, y: -10000), size: size),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                flush(host); RunLoop.main.run(until: Date().addingTimeInterval(0.1)); flush(host)
                defer { pointers(host).forEach { $0.stopListening() }; window.contentView = nil }
                let field = try XCTUnwrap(pointers(host).first { !$0.isKeyboardOnly })
                // Find real clickable cells using the production hit rule, so
                // overlapping layers cannot silently turn this into a same-kind selection.
                var choices: [(String, UUID, PolarMetricGridCell, CGPoint)] = []
                for layer in owner.canvas.workspace.layers where layer.isVisible && !layer.isLocked {
                    guard let routing = layer.routings.first else { continue }
                    let kind: String
                    switch routing.program {
                    case .chord: kind = "chord"
                    case .singleNote: kind = "note"
                    case .scale, .randomScale: kind = "scale"
                    default:
                        if case .midiProgramChange = routing.target { kind = "pc" }
                        else if case .midiCC = routing.target { kind = "cc" }
                        else { kind = "control" }
                    }
                    if choices.contains(where: { $0.0 == kind }) { continue }
                    for cell in layer.polarCells.sorted(by: { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }) {
                        let center = SpatialFieldPlan.center(.init(cell: cell, grid: owner.canvas.workspace.grid))
                        let point = owner.canvas.displayGeometry(canvasSize: field.bounds.size)
                            .screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
                        var check = owner.canvas.presentation
                        _ = check.selectCell(atScreenPoint: point, canvasSize: field.bounds.size)
                        if check.workspace.selectedLayerID == layer.id && check.selectedPolarCell == cell {
                            choices.append((kind, layer.id, cell, point)); break
                        }
                    }
                }
                print("INSPECTOR-FIXTURE \(preset) layers=\(owner.canvas.workspace.layers.count) cells=\(owner.canvas.workspace.layers.reduce(0) { $0 + $1.polarCells.count }) choices=\(choices.map { $0.0 })")
                let musical = try XCTUnwrap(choices.first { $0.0 == "chord" } ?? choices.first { $0.0 == "scale" })
                let control = try XCTUnwrap(choices.first { $0.0 == (controlKind ?? "control") } ?? choices.first { $0.0 == "cc" })
                let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
                defer { ViewEvaluationProbe.current = nil; CanvasTimingProbe.current = nil }
                let revision = owner.document.revision, plan = owner.fieldPlan.identity
                var publications = 0
                let subscription = owner.$document.dropFirst().sink { _ in publications += 1 }
                defer { subscription.cancel() }
                let repetitions = ProcessInfo.processInfo.environment["SICK_VIEW_COST"] == "1" ? 3 : 2
                // Hold real references to prevent allocator address reuse.
                // The union of the first complete pair also permits the cell
                // keyboard's first mount on the musical side of that pair.
                var firstControls: [String: [NSControl]] = [:]
                for iteration in 0..<repetitions {
                    for choice in [control, musical] {
                        probe.reset(); let timing = CanvasTimingProbe(); CanvasTimingProbe.current = timing
                        let start = ProcessInfo.processInfo.systemUptime
                        try send(.leftMouseDown, point: choice.3, pointer: field, window: window)
                        try send(.leftMouseUp, point: choice.3, pointer: field, window: window)
                        let dispatched = ProcessInfo.processInfo.systemUptime
                        flush(host)
                        let laidOut = ProcessInfo.processInfo.systemUptime
                        // Include actual rasterization of the new inspector, not just invalidation.
                        let inspectorRect = NSRect(x: 900, y: 0, width: 2 * width, height: 1000)
                        let bitmap = images && iteration == repetitions - 1 ? try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: inspectorRect)) : nil
                        if let bitmap { host.cacheDisplay(in: inspectorRect, to: bitmap) }
                        let end = ProcessInfo.processInfo.systemUptime
                        FileHandle.standardError.write(Data(("INSPECTOR-SWITCH \(preset) width=\(width) variant=\(controlKind ?? "saved") iteration=\(iteration) kind=\(choice.0) model_ms=\((dispatched-start)*1000) layout_ms=\((laidOut-dispatched)*1000) export_ms=\((end-laidOut)*1000) visible_ms=\((laidOut-start)*1000) stages=\(timing.milliseconds) work=\(timing.counts) bodies=\(probe.counts)\n").utf8))
                        // Qualified by three isolated alternating baseline/diff runs.
                        // Initial construction and bitmap export have separate budgets.
                        if !images && iteration > 0 && ["control", "cc", "pc"].contains(choice.0) {
                            XCTAssertLessThan((laidOut - start) * 1000, 50,
                                "Warm steering/CC/program selection must be visible within 50 ms")
                        }
                        let controls = nativeControls(host)
                        XCTAssertFalse(controls.isEmpty, "Native creation probe must observe real controls")
                        let surfaces = retainedControlHosts(host)
                        if controlKind != "note" {
                            XCTAssertFalse(surfaces.isEmpty, "Control fixtures must observe the production native boundary")
                        }
                        for surface in surfaces {
                            let name = surface.identifier!.rawValue.replacingOccurrences(of: "inspector.retained.", with: "")
                            let showing: Bool
                            switch name {
                            case "layerProgram", "cellProgram": showing = choice.0 == "pc"
                            case "layerControl", "cellValue": showing = !["pc", "chord", "note", "scale"].contains(choice.0)
                            case "cellControl": showing = !["pc", "chord", "note", "scale", "cc"].contains(choice.0)
                            default: XCTFail("Unclassified native surface: \(name)"); continue
                            }
                            XCTAssertEqual(surface.isHidden, !showing, "\(name): every show/hide edge must reach AppKit")
                            if !showing {
                                XCTAssertNil(surface.hitTest(.zero))
                                XCTAssertTrue(textFields(surface).allSatisfy { !$0.isEnabled },
                                    "Hidden number fields must be disabled, including an old keyboard responder")
                            }
                        }
                        XCTAssertEqual(probe.counts["inspector.controlPreparation", default: 0], 0)
                        XCTAssertLessThanOrEqual(probe.counts["inspector.cellInfo", default: 0], 1)
                        if iteration == 0 { firstControls[choice.0] = controls }
                        if iteration > 0 && choice.0 != "note" {
                            let previous = Set(firstControls.values.flatMap { $0 }.map(ObjectIdentifier.init))
                            let created = controls.filter { !previous.contains(ObjectIdentifier($0)) }
                            let counts = Dictionary(grouping: created, by: { String(describing: type(of: $0)) }).mapValues(\.count)
                            FileHandle.standardError.write(Data("INSPECTOR-NATIVE \(preset) variant=\(controlKind ?? "saved") kind=\(choice.0) created=\(counts)\n".utf8))
                            XCTAssertTrue(created.isEmpty, "Unchanged inspector controls must survive the round trip: \(counts)")
                        }
                        let pianoKeys = probe.counts.filter {
                            $0.key.hasPrefix("piano.") && $0.key.dropFirst(6).first?.isNumber == true
                        }.values.reduce(0, +)
                        // One changed selection, two inspector sections and
                        // two fixed two-octave keyboards. A cold cell inspector
                        // can prepare 24 keys; a changed note/chord can update at
                        // most 48. Returning to unchanged content prepares none.
                        XCTAssertLessThanOrEqual(timing.counts["inspector.prepare", default: 0], 1)
                        XCTAssertEqual(probe.counts["inspector.rowInput", default: 0], 0)
                        XCTAssertEqual(probe.counts["inspector.sceneMembership", default: 0], 0)
                        XCTAssertEqual(probe.counts["inspector.noteRow", default: 0], 0)
                        if choice.0 != "chord" && choice.0 != "note" && choice.0 != "scale" {
                            XCTAssertEqual(probe.counts["inspector.musicPresentation", default: 0], 0)
                            XCTAssertEqual(probe.counts["inspector.musicRootUpdate", default: 0], 0)
                        }
                        XCTAssertLessThanOrEqual(probe.counts["cell", default: 0], 2)
                        XCTAssertLessThanOrEqual(probe.counts["inspector.section.assignment", default: 0], 1)
                        XCTAssertLessThanOrEqual(pianoKeys, 48)
                        // Two keyboards, at most three fixture voices plus two C labels each.
                        XCTAssertLessThanOrEqual(probe.counts["piano.labelText", default: 0], 10)
                        if iteration > 0 {
                            XCTAssertEqual(probe.counts["inspector.programFieldMount", default: 0], 0)
                            XCTAssertLessThanOrEqual(probe.counts["inspector.chordRow", default: 0], 2,
                                "Only the selected chord title may be reconsidered, never the entire catalogue")
                        }
                        if iteration > 0 && controlKind != "note" {
                            XCTAssertEqual(probe.counts["piano.layout", default: 0], 0)
                            XCTAssertEqual(pianoKeys, 0)
                            XCTAssertEqual(probe.counts["piano.labelText", default: 0], 0)
                            XCTAssertEqual(probe.counts["inspector.chordRow", default: 0], 0)
                        }
                        // Selection must still initialize an editable CC value
                        // after the enclosing section no longer uses .id(cell).
                        if choice.0 == "cc" {
                            let value = try XCTUnwrap(textFields(host).first { $0.placeholderString == "Value 0…127" })
                            XCTAssertEqual(value.stringValue, "64")
                        }
                        XCTAssertEqual(owner.canvas.workspace.selectedLayerID, choice.1)
                        XCTAssertEqual(owner.canvas.selectedPolarCell, choice.2)
                        XCTAssertEqual(publications, 0)
                        XCTAssertEqual(owner.document.revision, revision)
                        XCTAssertEqual(owner.fieldPlan.identity, plan)
                        XCTAssertNil(timing.milliseconds["runtime.compile"])
                        if images && iteration == repetitions - 1, let bitmap {
                            let name = "inspector-switch-\(preset)-\(controlKind ?? "saved")-\(choice.0)-\(Int(width))"
                            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                                .write(to: directory.appendingPathComponent(name + "-edit.png"))
                            owner.canvas.setPerformanceLocked(true)
                            flush(host)
                            let perform = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: inspectorRect))
                            host.cacheDisplay(in: inspectorRect, to: perform)
                            try XCTUnwrap(perform.representation(using: .png, properties: [:]))
                                .write(to: directory.appendingPathComponent(name + "-perform.png"))
                            owner.canvas.setPerformanceLocked(false)
                            flush(host)
                            // Lock transitions may rebuild AppKit menus. They are
                            // outside the selection-only creation contract.
                            firstControls[choice.0] = nativeControls(host)
                        }
                    }
                }
            }
        }
    }

    private func exerciseNativeSelection(assertTime: Bool, captureImages: Bool = false,
                                         additionalScenes: Int = 0) throws {
        for preset in ["Harmony 29 Picardy Switch", "Harmony 30 Mode Wheel", "Keller 03 Zwei Haende"] {
            let widths = captureImages ? [1500, 1260] : [1500]
            for width in widths {
                let fixture = try MonitorRootFixture(), owner = fixture.root.document
                defer { fixture.root.terminate {} }
                try load(preset, owner: owner)
                if additionalScenes > 0 {
                    owner.canvas.updateWorkspace(named: "Count-test scenes") { workspace in
                        for _ in 0..<additionalScenes { _ = workspace.addScene() }
                    }
                }
                fixture.root.display.stop()
                let workspace = owner.canvas.workspace
                print("SELECTION-SIZE \(preset) layers=\(workspace.layers.count) cells=\(workspace.layers.reduce(0) { $0 + $1.polarCells.count }) scenes=\(workspace.scenes.count) regions=\(owner.fieldPlan.regions.count) labels=\(owner.fieldLabels.count)")
                let host = NSHostingView(rootView: Harness(fixture: fixture,
                    catalog: AudioCatalogModel(document: owner, source: EmptyCatalog())))
                host.frame = .init(x: 0, y: 0, width: width, height: 1000); host.wantsLayer = true
                let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 1000),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFrontRegardless() // Realize a native window number for synthetic event ownership.
                defer { window.close() }
                flush(host); RunLoop.main.run(until: Date().addingTimeInterval(0.1)); flush(host)
                defer { pointers(host).forEach { $0.stopListening() }; window.contentView = nil }
                let nativeRows = pointers(host).filter(\.isKeyboardOnly).sorted {
                    $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY
                }
                XCTAssertEqual(nativeRows.count, owner.canvas.workspace.layers.count)
                let index = owner.canvas.workspace.layers.firstIndex { $0.id != owner.canvas.workspace.selectedLayerID }!
                let layer = owner.canvas.workspace.layers[index]
                let revision = owner.document.revision, plan = owner.fieldPlan.identity
                let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
                defer { ViewEvaluationProbe.current = nil; CanvasTimingProbe.current = nil }
                var publications = 0
                let subscription = owner.$document.dropFirst().sink { _ in publications += 1 }
                defer { subscription.cancel() }
                func measure(_ kind: String, action: () throws -> Void) throws {
                    let timing = CanvasTimingProbe(); CanvasTimingProbe.current = timing; probe.reset()
                    let start = ProcessInfo.processInfo.systemUptime
                    try action()
                    let dispatched = ProcessInfo.processInfo.systemUptime
                    flush(host)
                    let end = ProcessInfo.processInfo.systemUptime
                    // One write on XCTest's stream keeps its result lines intact;
                    // buffered stdout can splice a 'passed' line into the timings.
                    let evidence = "AUSWAHL-TEMPO \(preset) \(kind) dispatch=\((dispatched-start)*1000) visible=\((end-start)*1000) hosting=\((end-dispatched)*1000) stages=\(timing.milliseconds) work=\(timing.counts) bodies=\(probe.counts)\n"
                    FileHandle.standardError.write(Data(evidence.utf8))
                    if assertTime { reportPerformance("selection/\(preset)/\(kind)", samples: [(end-start)*1000], unit: "ms") }
                    print("BUDGET deterministisch: inspector.prepare<=1, row/scene/text rebuilds=0, publications=0, documentConsumer/footer=0, runtime.compile=nil, revision/plan unveraendert; lastabhaengig: Auswahl < 50 ms")
                    // A click changes one inspector input; selection decoration
                    // must never reconstruct unchanged scene controls or text.
                    XCTAssertLessThanOrEqual(timing.counts["inspector.prepare", default: 0], 1, "\(preset) \(kind)")
                    if preset == "Keller 03 Zwei Haende" {
                        XCTAssertEqual(probe.counts["inspector.controlSurfaceInput", default: 0], 0,
                            "Pure music selections must not construct dormant control forms")
                    }
                    XCTAssertEqual(probe.counts["inspector.rowInput", default: 0], 0, "\(preset) \(kind)")
                    XCTAssertEqual(probe.counts["inspector.layerListInput", default: 0], 0, "\(preset) \(kind)")
                    XCTAssertLessThanOrEqual(probe.counts["inspector.layerList", default: 0], 1, "\(preset) \(kind)")
                    XCTAssertLessThanOrEqual(probe.counts["inspector.rowDecoration", default: 0], 2, "\(preset) \(kind)")
                    XCTAssertEqual(timing.counts["inspector.rowBody", default: 0], 0, "\(preset) \(kind)")
                    XCTAssertEqual(probe.counts["inspector.sceneMembership", default: 0], 0, "\(preset) \(kind)")
                    XCTAssertEqual(timing.counts["plan.prepareLabels", default: 0], 0)
                    XCTAssertEqual(timing.counts["plan.labelOwners", default: 0], 0)
                    XCTAssertLessThanOrEqual(timing.counts["runtime.select.labels", default: 0], 1)
                    XCTAssertEqual(probe.counts["field.labelText", default: 0], 0, "\(preset) \(kind)")
                    XCTAssertLessThanOrEqual(probe.counts["field.selectionCell", default: 0], owner.canvas.selection.cells.count * 2,
                                             "Only the actual selection is highlighted, with at most two draw passes")
                    // Two octaves (24 keys), at most three evaluations while
                    // the fixed keyboard's local draft/geometry settles.
                    let pianoKeys = probe.counts.filter { $0.key.hasPrefix("piano.") && $0.key != "piano.labelText" }.values.reduce(0, +)
                    XCTAssertLessThanOrEqual(pianoKeys, 72, "\(preset) \(kind)")
                    XCTAssertLessThanOrEqual(probe.counts["piano.labelText", default: 0], 15, "\(preset) \(kind)")
                    XCTAssertLessThanOrEqual(probe.counts["layers", default: 0], 2)
                    if assertTime {
                        XCTAssertLessThan((end-start)*1000, 50, "\(preset) \(kind): includes native intent, owners, hosting/layout/display")
                    }
                    if kind == "cell" {
                        let musical: Bool
                        switch owner.canvas.workspace.selectedLayer.routings.first?.target {
                        case .midiNote?, .audioUnitNote?: musical = true
                        default: musical = false
                        }
                        // A control-cell click must not reconstruct or publish
                        // a root for the retained, invisible musical editor.
                        // Keller's real chord click still updates its visible root.
                        XCTAssertLessThanOrEqual(probe.counts["inspector.musicPresentation", default: 0], musical ? 1 : 0)
                        XCTAssertLessThanOrEqual(probe.counts["inspector.musicRootUpdate", default: 0], musical ? 1 : 0)
                        let music = try XCTUnwrap(retainedMusicHost(host))
                        XCTAssertEqual(music.isHidden, !musical)
                        if !musical { XCTAssertNil(music.hitTest(.zero)) }
                    }
                    XCTAssertEqual(publications, 0)
                    XCTAssertEqual(probe.counts["selection.documentConsumer", default: 0], 0)
                    XCTAssertEqual(probe.counts["field.footer", default: 0], 0)
                    if kind == "cell" { XCTAssertEqual(probe.counts["field.toolbar", default: 0], 0) }
                    XCTAssertNil(timing.milliseconds["runtime.compile"])
                    XCTAssertEqual(owner.document.revision, revision)
                    XCTAssertEqual(owner.fieldPlan.identity, plan)
                }
                try measure("layer") {
                    try send(.leftMouseDown, pointer: nativeRows[index], window: window)
                    try send(.leftMouseUp, pointer: nativeRows[index], window: window)
                }
                if widths.count > 1 { try image(host, name: "\(preset)-\(width)-layer", directory: TestImageDirectory.make()) }
                XCTAssertEqual(owner.canvas.workspace.selectedLayerID, layer.id)
                XCTAssertFalse(owner.canvas.selectedCells.isEmpty)
                // A real field click must switch away from this row's active layer.
                let field = try XCTUnwrap(pointers(host).first { !$0.isKeyboardOnly })
                let target = try XCTUnwrap(owner.canvas.workspace.layers.reversed().first {
                    $0.id != layer.id && $0.isVisible && !$0.isLocked && !$0.polarCells.isEmpty
                })
                let tile = try XCTUnwrap(target.polarCells.sorted { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }.first)
                let center = SpatialFieldPlan.center(.init(cell: tile, grid: owner.canvas.workspace.grid))
                let point = owner.canvas.displayGeometry(canvasSize: field.bounds.size).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
                try measure("cell") {
                    try send(.leftMouseDown, point: point, pointer: field, window: window)
                    try send(.leftMouseUp, point: point, pointer: field, window: window)
                }
                if widths.count > 1 { try image(host, name: "\(preset)-\(width)-cell", directory: TestImageDirectory.make()) }
                XCTAssertEqual(owner.canvas.selectedCells.count, 1)
                XCTAssertNotEqual(owner.canvas.workspace.selectedLayerID, layer.id)
                if !assertTime && !captureImages {
                    try measure("return-layer") {
                        try send(.leftMouseDown, pointer: nativeRows[index], window: window)
                        try send(.leftMouseUp, pointer: nativeRows[index], window: window)
                    }
                    XCTAssertEqual(owner.canvas.workspace.selectedLayerID, layer.id)
                    if ProcessInfo.processInfo.environment["SICK_VIEW_COST"] == "1" {
                        for _ in 0..<20 {
                            try measure("profile-cell") {
                                try send(.leftMouseDown, point: point, pointer: field, window: window)
                                try send(.leftMouseUp, point: point, pointer: field, window: window)
                            }
                            try measure("profile-layer") {
                                try send(.leftMouseDown, pointer: nativeRows[index], window: window)
                                try send(.leftMouseUp, pointer: nativeRows[index], window: window)
                            }
                        }
                    }
                    // Document changes must still reach the cached interaction
                    // and row subtree after several selections without rebuilding.
                    probe.reset()
                    owner.canvas.updateWorkspace(named: "Rename after selection") {
                        $0.updateLayer(layer.id) { $0.name = "Current after selection" }
                    }
                    flush(host)
                    XCTAssertEqual(owner.canvas.inspector.interaction.workspace.selectedLayer.name, "Current after selection")
                    XCTAssertGreaterThan(probe.counts["layerRow.\(layer.id)", default: 0], 0)
                }
            }
        }
    }
}

// Thin target-local bridge; format, environment and percentiles live in the
// shared reporter. Called only AFTER the timed interval. Reporting failure is
// observational and must never alter a performance assertion's outcome.
private func reportPerformance(_ scenario: String, samples: [Double], unit: String) {
    #if DEBUG
    let build = "debug"
    #else
    let build = "release"
    #endif
    do {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/perf-report.py").path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        let data = try JSONSerialization.data(withJSONObject: ["scenario": scenario, "samples": samples, "unit": unit, "build": build])
        try process.run()
        input.fileHandleForWriting.write(data); input.fileHandleForWriting.closeFile()
        let evidence = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        FileHandle.standardError.write(evidence)
        if process.terminationStatus != 0 { print("SICK-PERF reporting unavailable: status=\(process.terminationStatus)") }
    } catch { print("SICK-PERF reporting unavailable: \(error)") }
}

/// Counts the window host's own layout passes; native live layers must not cause any.
final class RootLayoutCountingHost<Content: View>: NSHostingView<Content> {
    var rootLayouts = 0
    override func layout() { rootLayouts += 1; super.layout() }
}
