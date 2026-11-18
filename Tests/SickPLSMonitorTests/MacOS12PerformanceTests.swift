import AppKit
import Combine
import SwiftUI
import XCTest
import PlanariumApplication
@testable import PlanariumInput
import PlanariumScannerUI
@testable import PlanariumDomain
import PlanariumRuntime
import PlanariumMIDI
import PlanariumPresets
import SickPLSCore
import SickPLSMacTransport
import SickPLSMonitorKit
import SickPLSSetupControl
import SickPLSCommissioningControl
import SickPLSSimulationControl
@testable import SickPLSMonitor

/// Exercises production input R → Q → Main, with a fake byte stream and no
/// device, application launch, audio or MIDI resource. Assertions count work;
/// the 40 ms pacing describes the input, never a pass/fail CPU/time budget.
@MainActor final class MacOS12PerformanceTests: XCTestCase {
    func testMixerKeyboardDeduplicatesFiftyFramesAndOneNoteChange() throws {
        let mailbox = DisplayFrameMailbox()
        // Use a dedicated mailbox to exercise the real display publication boundary.
        let model = PerformanceDisplayModel(mailbox: mailbox)
        let view = host(MixerMiniKeyboard(display: model), width: 200, height: 80)
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil; model.stop() }
        model.start(); flush([view]); flush([view])
        let baseline = probe.counts["mixer.keyboard", default: 0]
        for n in 1...50 {
            mailbox.write(.init(selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]), processedProfiles: UInt64(n)))
            model.read(); flush([view])
        }
        XCTAssertLessThanOrEqual(probe.counts["mixer.keyboard", default: 0] - baseline, 1)
        let beforeNote = probe.counts["mixer.keyboard", default: 0]
        mailbox.write(.init(selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:]),
            soundingNoteOwners: [.init(layerID: UUID(), destination: .midi, channel: 0, number: 60, latched: false)]))
        model.read(); flush([view]); flush([view])
        XCTAssertEqual(probe.counts["mixer.keyboard", default: 0], beforeNote + 1)
    }

    func testTenCommitsKeepDuplicateFocusIdentityAndCommandsStable() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        let owner = fixture.root.document
        let menu = MenuPresentationModel(instrument: owner, workspace: layout.workspace)
        let commands = PlanariumCommands(workspace: layout.workspace, spatialInstrument: owner, presets: layout.view.presets, presentation: menu)
        let duplicate = WorkspaceCommands(instrument: owner, presentation: menu, presets: layout.view.presets)
        let view = host(MenuBoundary(presentation: menu, commands: commands, duplicate: duplicate))
        flush([view]); flush([view])
        let initial = SpatialLayerInspectorView(editor: owner.canvas, audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()), midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil).duplicateLayerCommand
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        for n in 0..<10 {
            var detection = owner.document.detection
            detection.groupingJumpCentimeters = UInt16(11 + n)
            owner.updateDetectionConfiguration(detection)
            XCTAssertEqual(SpatialLayerInspectorView(editor: owner.canvas, audioUnits: AudioCatalogModel(document: owner, source: EmptyCatalog()), midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil).duplicateLayerCommand, initial)
            flush([view])
        }
        XCTAssertLessThanOrEqual(probe.counts["commands", default: 0], 1)
    }

    private struct SceneBoundary: View {
        @ObservedObject var ownership: AppOwnership<ContentView>
        var body: some View {
            let _ = ViewEvaluationProbe.current?.record("offline.scene")
            ownership.models
        }
    }
    private struct MenuBoundary: View {
        @ObservedObject var presentation: MenuPresentationModel
        let commands: PlanariumCommands
        let duplicate: WorkspaceCommands
        var body: some View {
            // Evaluate the REAL Commands bodies at their actual observation
            // boundary. Commands cannot be mounted in NSHostingView itself.
            let _ = commands.body
            let _ = duplicate.body
            Text(presentation.value.undoTitle)
        }
    }
    private func flush(_ views: [NSView]) {
        for view in views { view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
        mainTurn()
        for view in views { view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
    }
    /// Offscreen hosts can leave the run loop without any timer/source after
    /// nested delivery. Supply our own monotonic wake-up and execute one bounded
    /// turn, rather than asking Foundation to run indefinitely until a Date.
    private func mainTurn() {
        let wake = DispatchWorkItem {}
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.003, execute: wake)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.003))
        wake.cancel()
    }
    private func host(_ view: some View, width: CGFloat = 1500, height: CGFloat = 900) -> NSView {
        let view = NSHostingView(rootView: view)
        view.frame = .init(x: 0, y: 0, width: width, height: height)
        view.wantsLayer = true
        return view
    }
    func testFiftyProfilesDoNotInvalidateScenesCommandsSettingsOrHeaderButtons() throws {
        for simulated in [false, true] {
            for points in [90, 361] { try verifyFiftyProfiles(simulated: simulated, points: points) }
        }
    }
    private func verifyFiftyProfiles(simulated: Bool, points: Int) throws {
        let stream = CountedProfileStream()
        let source = CountedClockSource(), graph = MonitorGraph(); graph.permitsStart = true
        let fixture = try MonitorRootFixture(scanner: CountedScanner(stream: stream), graph: graph,
            clockSourceFactory: { source.open($0, $1, $2) }), layout = try LayoutWorkspaceFixture(fixture: fixture)
        let channelMeter = ChannelMeterReader(), masterMeter = ChannelMeterReader(master: true)
        let root = fixture.root, view = layout.view
        if simulated { view.simulation.selectInput(.iPhoneSimulation) }
        let ownership = AppOwnership(view)
        let menu = MenuPresentationModel(instrument: root.document, workspace: layout.workspace)
        let commands = PlanariumCommands(workspace: layout.workspace, spatialInstrument: root.document, presets: view.presets, presentation: menu)
        let duplicate = WorkspaceCommands(instrument: root.document, presentation: menu, presets: view.presets)
        let password = ScannerPasswordSettingsModel(store: UserDefaultsScannerPasswordStore(defaults: try XCTUnwrap(UserDefaults(suiteName: layout.suiteName))))
        let commissioning = CommissioningControlModel(coordinator: root.input)
        let settings = PlanariumSettingsView(workspace: layout.workspace, spatialInstrument: root.document,
            scannerPassword: password, scannerSetup: view.scannerSetup, connection: view.connection,
            commissioning: commissioning, input: root.input, midi: root.midi, recording: root.profileRecording, sourceCatalog: { [] })
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil; layout.cleanDefaults(); root.display.stop(); root.terminate {} }
        let main = host(SceneBoundary(ownership: ownership))
        let settingsHost = host(settings, width: 650, height: 780)
        let development = host(ScannerDevelopmentSettingsView(model: view.scannerSetup, connection: view.connection,
            coordinator: root.input, instrument: root.document, recording: root.profileRecording), width: 620, height: 720)
        let menuHost = host(MenuBoundary(presentation: menu, commands: commands, duplicate: duplicate), width: 200, height: 50)
        let views = [main, settingsHost, development, menuHost]
        var transitions: [MeasurementSessionStatus] = []
        let statusToken = root.input.measurementSessionStatusChanges.sink { transitions.append($0) }
        defer { statusToken.cancel() }
        if simulated {
            XCTAssertEqual(root.input.connectSimulation(serviceName: "Offline @25 Hz", opener: stream), .connecting)
        } else {
            XCTAssertEqual(root.input.connectDevelopment(portPath: "/dev/cu.offline", baudRate: .baud500000), .connecting(baudRate: .baud500000))
        }
        // Start the optional reference acquisition too: this is the scanner
        // workspace's profile-rate publisher seen by the original App.
        view.scannerWorkspace.startReferenceMeasurement()
        root.display.start()
        stream.produce(try packet(100, points: points))
        wait(views) { root.input.session.deliveredProfileBatches >= 1 }
        layout.workspace.setVisible(.setup, true)
        for _ in 0..<8 { flush(views) }
        root.display.start()
        root.document.configureClock(direction: .receive, targets: [], sourceID: 1)
        wait(views) { source.isOpen && root.document.externalClock.isSourceAvailable }
        try root.audio.start()
        channelMeter.start(root.audio); masterMeter.start(root.audio)
        defer { channelMeter.stop(); masterMeter.stop(); root.audio.stop() }
        var publications: [String: Int] = [:]
        var tokens: [AnyCancellable] = []
        func observe<T: ObservableObject>(_ name: String, _ object: T) where T.ObjectWillChangePublisher == ObservableObjectPublisher {
            object.objectWillChange.sink { publications[name, default: 0] += 1 }.store(in: &tokens)
        }
        observe("connection", view.connection); observe("simulation", view.simulation)
        observe("scannerWorkspace", view.scannerWorkspace); observe("instrument", root.document)
        observe("inputOwner", root.input); observe("setup", view.scannerSetup)
        observe("presets", view.presets); observe("audioUnits", view.audioUnits)
        observe("audioDevices", view.audioDevices); observe("workspace", layout.workspace)
        observe("scannerPassword", password); observe("commissioning", commissioning)
        observe("appOwnership", ownership); observe("menu", menu); observe("rate", root.input.profileRateDisplay)
        root.input.session.objectWillChange.sink { publications["rxStatus", default: 0] += 1 }.store(in: &tokens)
        view.scannerWorkspace.$editorState.dropFirst().sink { _ in publications["zoneEditor", default: 0] += 1 }.store(in: &tokens)
        for key in ["input.backlog", "header.liveRate", "commands", "settings", "root", "offline.scene"] {
            XCTAssertGreaterThan(probe.counts[key, default: 0], 0, "Mounted positive control: \(key)")
        }
        probe.reset()
        let start = ProcessInfo.processInfo.systemUptime
        let pumpStart = root.display.pumpPassCount
        let first = root.input.session.deliveredProfileBatches
        for index in 1...50 {
            let deadline = start + Double(index) / 25
            source.emit(index: index)
            channelMeter.observe(.init(left: 0.5, right: 0.25, deliveries: index), elapsed: 0.04)
            masterMeter.observe(.init(left: 0.5, right: 0.25, deliveries: index), elapsed: 0.04)
            let delivered = root.display.deliveryCount
            stream.produce(try packet(UInt16(100 + index % 30), points: points))
            wait(views) { root.input.session.deliveredProfileBatches >= first + index }
            wait(views) { root.display.deliveryCount > delivered && root.display.frame?.profile?.sequence == UInt64(first + index) }
            repeat { flush(views) } while ProcessInfo.processInfo.systemUptime < deadline
        }
        let seconds = ProcessInfo.processInfo.systemUptime - start
        print("MACOS12 simulated=\(simulated) profiles=50 rays=\(points) seconds=\(seconds) publications=\(publications) bodies=\(probe.counts)")
        print("MACOS12 counts/s=\(probe.counts.mapValues { Double($0) / seconds })")
        XCTAssertGreaterThanOrEqual(root.display.pumpPassCount - pumpStart, 50, "Production mailbox signal drives the pump")
        XCTAssertEqual(root.input.session.deliveredProfileBatches - first, 50)
        XCTAssertEqual(root.clockReceiver.snapshot.tickCount, 100)
        XCTAssertGreaterThan(channelMeter.readCount, 0); XCTAssertGreaterThan(masterMeter.readCount, 0)
        XCTAssertEqual(MeterReadPulse.shared.timerCount, 1)
        XCTAssertEqual(publications["rxStatus", default: 0], 0)
        XCTAssertEqual(publications["zoneEditor", default: 0], 0)
        XCTAssertEqual(publications["connection", default: 0], 0)
        XCTAssertGreaterThan(publications["scannerWorkspace", default: 0], 0)
        let streaming: MeasurementSessionStatus = simulated
            ? .simulation(.streaming(serviceName: "Offline @25 Hz", pointCount: points))
            : .streaming(portPath: "/dev/cu.offline", pointCount: points)
        XCTAssertEqual(transitions, simulated
            ? [.idle, .simulation(.opening(serviceName: "Offline @25 Hz")), .simulation(.openWithoutProfile(serviceName: "Offline @25 Hz")), streaming]
            : [.idle, .opening(portPath: "/dev/cu.offline"), .openWithoutProfile(portPath: "/dev/cu.offline"), streaming])
        XCTAssertEqual(publications["simulation", default: 0], 0)
        for name in ["inputOwner", "instrument", "workspace"] { XCTAssertEqual(publications[name, default: 0], 0, name) }
        // k=0 after streaming settles: no mode, menu history, layout or clock
        // direction changes occur in these 50 profiles. Not a CPU threshold.
        for key in ["offline.scene", "commands", "workspace.commands", "settings", "settings.development.buttons", "root", "header.buttons", "header.input.button", "connection.buttons", "connection.evidence", "simulation.switch", "simulation.badge", "simulation.buttons", "reference.buttons"] {
            XCTAssertEqual(probe.counts[key, default: 0], 0, key)
        }
        // One initial availability transition may build the field toolbar;
        // all subsequent profiles must stay in the live canvas.
        XCTAssertLessThanOrEqual(probe.counts["field.toolbar", default: 0], 1)
        XCTAssertEqual(publications["appOwnership", default: 0], 0)
        XCTAssertEqual(publications["menu", default: 0], 0)
        XCTAssertGreaterThan(probe.counts["reference.liveText", default: 0], 0, "Visible reference values still update independently")
        XCTAssertNotNil(root.input.profileRateDisplay.hertz)
        let export = view.connection.evidenceExportText()
        XCTAssertTrue(export.contains("Delivered read operations: \(first + 50)"), "Explicit export reads fresh counters despite the quiet card")
        XCTAssertTrue(export.contains("Profile rate:"))
        XCTAssertGreaterThan(probe.counts["profileRate.text", default: 0], 0, "Live Hz text still receives sampled telemetry")
        for count in [publications["rate", default: 0], probe.counts["header.liveRate", default: 0]] {
            XCTAssertLessThanOrEqual(count, 3, "Rate display stays sampled in the two-second run")
        }
        let rateTexts = probe.instanceCounts["profileRate.text", default: [:]]
        XCTAssertEqual(rateTexts.count, 4, "Header, setup and two development summaries are mounted")
        XCTAssertEqual(rateTexts.values.reduce(0, +), probe.counts["profileRate.text", default: 0])
        for count in rateTexts.values { XCTAssertLessThanOrEqual(count, 3, "profileRate.text per mounted leaf") }
        XCTAssertEqual(probe.counts["input.backlog", default: 0], 0)
        probe.reset()
        layout.workspace.togglePerformance(canvas: root.document.canvas)
        wait(views) { ["commands", "settings", "root"].allSatisfy { probe.counts[$0, default: 0] > 0 } }
        layout.workspace.togglePerformance(canvas: root.document.canvas)
        root.input.disconnect()
        wait(views) { !root.input.session.isPortHeld }
        XCTAssertEqual(transitions.last, .idle)
        XCTAssertEqual(transitions.count, 5)
        _ = tokens

    }

    func testRateTelemetryUsesMonotonicOneSecondWindowsRoundsAndResets() {
        let rate = ProfileRateDisplayModel()
        var seen: [Double?] = []
        let token = rate.$hertz.dropFirst().sink { seen.append($0) }
        defer { token.cancel() }
        for index in 0..<100 { rate.observe(25.123 + Double(index % 2) * 0.001, at: Double(index) * 0.04) }
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(rate.hertz, 25.12)
        rate.observe(26.876, at: 4)
        XCTAssertEqual(rate.hertz, 26.88)
        XCTAssertEqual(seen.count, 2)
        rate.observe(99, at: 4.99)
        XCTAssertEqual(seen.count, 2)
        rate.observe(.nan, at: .infinity)
        XCTAssertEqual(seen.count, 2)
        rate.reset(); XCTAssertNil(rate.hertz)
        rate.reset(); XCTAssertEqual(seen.count, 3)
        rate.observe(nil, at: 0)
        rate.observe(30, at: 1)
        XCTAssertEqual(rate.hertz, 30)
        XCTAssertEqual(seen.count, 4)
    }

    func testHandoffCommitsBeforeConsumptionAndTwoWindowsCancelReplaceInBothOrders() {
        for reverse in [false, true] {
            let source = HandoffSource()
            var connected: [VerifiedScannerConnection] = []
            func makeBridge() -> NSView {
                host(ScannerHandoffBridge(handoffs: source.$endpoint.eraseToAnyPublisher(),
                    current: { source.endpoint }, consume: {
                        XCTAssertNotNil(source.endpoint, "The Published value has committed before consumption")
                        source.endpoint = nil
                    }, connect: {
                        XCTAssertNil(source.endpoint, "Claim before invoking the connection effect")
                        // Deliberately permit nested Main processing while the
                        // second window's callback is still queued.
                        self.mainTurn()
                        connected.append($0)
                    }), width: 100, height: 50)
            }
            let first = makeBridge(), second = makeBridge()
            let views = reverse ? [second, first] : [first, second]
            for _ in 0..<4 { flush(views) }
            let a = VerifiedScannerConnection(portPath: "/dev/cu.offline-A", baudRate: .baud500000)
            let b = VerifiedScannerConnection(portPath: "/dev/cu.offline-B", baudRate: .baud38400)
            source.endpoint = a
            XCTAssertTrue(connected.isEmpty, "Never reenter the Published willSet")
            for _ in 0..<4 { flush(views) }
            XCTAssertEqual(connected, [a]); XCTAssertNil(source.endpoint)
            source.endpoint = a; source.endpoint = nil
            for _ in 0..<4 { flush(views) }
            XCTAssertEqual(connected, [a], "A cancelled queued handoff must not connect")
            source.endpoint = a; source.endpoint = b
            for _ in 0..<4 { flush(views) }
            XCTAssertEqual(connected, [a, b], "Only the current replacement connects, once across both windows")
            XCTAssertNil(source.endpoint)
            let reopened = makeBridge()
            for _ in 0..<4 { flush([reopened]) }
            XCTAssertEqual(connected, [a, b], "Consumed handoffs cannot resurrect on a new window")
        }
    }

    func testSourceKeepsAppAndCommandsObservationNarrow() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: directory.appendingPathComponent("Sources/SickPLSMonitor/SickPLSMonitorApp.swift"))
        let app = try XCTUnwrap(source.components(separatedBy: "struct SickPLSMonitorApp: App {").last?.components(separatedBy: "private struct MainWindowContent").first)
        XCTAssertEqual(app.components(separatedBy: "@StateObject").count - 1, 1)
        XCTAssertTrue(app.contains("AppOwnership<AppModels>"))
        XCTAssertFalse(app.contains("@ObservedObject"))
        let commands = try XCTUnwrap(source.components(separatedBy: "struct PlanariumCommands: Commands {").last?.components(separatedBy: "struct PlanariumSettingsView").first)
        XCTAssertEqual(commands.components(separatedBy: "@ObservedObject").count - 1, 1)
        XCTAssertTrue(commands.contains("@ObservedObject var presentation: MenuPresentationModel"))
    }

    func testMenuSnapshotUpdatesForRealTransitionsAndNotUnrelatedPublications() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        let owner = fixture.root.document, model = MenuPresentationModel(instrument: owner, workspace: layout.workspace)
        var changes = 0
        let token = model.objectWillChange.sink { changes += 1 }; defer { token.cancel() }
        owner.setBeatsPerMinute(137)
        wait([]) { model.value.canUndo }
        XCTAssertEqual(model.value.undoTitle, owner.undoMenuTitle)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(owner.undo()); wait([]) { model.value.canRedo }
        XCTAssertEqual(model.value.redoTitle, owner.redoMenuTitle)
        XCTAssertTrue(owner.redo()); wait([]) { !model.value.canRedo }
        layout.workspace.togglePerformance(canvas: owner.canvas)
        wait([]) { model.value.locked && model.value.mode == .perform }
        layout.workspace.togglePerformance(canvas: owner.canvas)
        wait([]) { !model.value.locked && model.value.mode == .edit }
        layout.workspace.setVisible(.layers, false)
        wait([]) { !model.value.visibility.layers }
        owner.configureClock(direction: .receive, targets: [], sourceID: nil, sourceName: "None")
        wait([]) { model.value.receivingClock }
        owner.configureClock(direction: .off, targets: [], sourceID: nil, sourceName: "None")
        wait([]) { !model.value.receivingClock }
        let before = changes
        for _ in 0..<10 { owner.objectWillChange.send(); layout.workspace.objectWillChange.send() }
        for _ in 0..<5 { flush([]) }
        XCTAssertEqual(changes, before)
    }
    func testSettingsControlsStillInvalidateForEditsAndKeepLiveProfileChangesNarrow() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        let view = layout.view
        let image = host(ScannerDevelopmentSettingsView(model: view.scannerSetup, connection: view.connection,
            coordinator: fixture.root.input, instrument: fixture.root.document, recording: fixture.root.profileRecording), width: 620, height: 720)
        for _ in 0..<8 { flush([image]) }
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        view.scannerSetup.selectedMeasurementMode = .customSubrange
        for _ in 0..<8 { flush([image]) }
        XCTAssertGreaterThan(probe.counts["settings.development.buttons", default: 0], 0)
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        XCTAssertTrue(fields(image).contains { $0.placeholderString == "Start 1…361" }, "Subrange edit reveals real new controls")
        probe.reset()
        view.scannerSetup.password = "TESTRATE"
        view.scannerSetup.targetAddressText = "01"
        for _ in 0..<8 { flush([image]) }
        XCTAssertGreaterThan(probe.counts["settings.development.buttons", default: 0], 0)
        XCTAssertTrue(fields(image).contains { $0.stringValue == "01" })
        probe.reset()
        for _ in 0..<20 {
            view.scannerSetup.objectWillChange.send()
            flush([image])
        }
        XCTAssertEqual(probe.counts["settings.development.buttons", default: 0], 0)
    }

    func testSettingsEveryTabAndPerformInSystemLightAndDarkWideAndNarrow() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        let root = fixture.root, view = layout.view
        defer { layout.cleanDefaults(); root.terminate {} }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: layout.suiteName))
        let password = ScannerPasswordSettingsModel(store: UserDefaultsScannerPasswordStore(defaults: defaults))
        let commissioning = CommissioningControlModel(coordinator: root.input)
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for perform in [false, true] {
            if perform { layout.workspace.togglePerformance(canvas: root.document.canvas) }
            for tab in perform ? [.development] : PlanariumSettingsTab.allCases {
                for dark in [false, true] {
                    for width in [740, 620] {
                        let content = PlanariumSettingsView(workspace: layout.workspace, spatialInstrument: root.document,
                            scannerPassword: password, scannerSetup: view.scannerSetup, connection: view.connection,
                            commissioning: commissioning, input: root.input, midi: root.midi, recording: root.profileRecording,
                            footswitch: root.footswitch, presets: view.presets, sourceCatalog: { [] }, selectedTab: tab)
                        let image = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light))
                        image.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        image.frame = .init(x: 0, y: 0, width: width, height: 820)
                        image.wantsLayer = true
                        for _ in 0..<5 { flush([image]) }
                        let bitmap = try XCTUnwrap(image.bitmapImageRepForCachingDisplay(in: image.bounds))
                        image.cacheDisplay(in: image.bounds, to: bitmap)
                        let name = "settings-\(perform ? "perform" : tab.rawValue)-system-\(dark ? "dark" : "light")-\(width).png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
                        // A rendered background point must stay dark in both
                        // system appearances, rather than white-on-light Aqua.
                        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 10, y: bitmap.pixelsHigh - 10)?.usingColorSpace(.deviceRGB))
                        XCTAssertLessThan(max(color.redComponent, color.greenComponent, color.blueComponent), 0.3, name)
                    }
                }
            }
        }
    }

    private func wait(_ views: [NSView], file: StaticString = #filePath, line: UInt = #line, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { flush(views) }
        XCTAssertTrue(predicate(), "Offline input/transition did not arrive", file: file, line: line)
    }
    private func packet(_ value: UInt16, points: Int = 361) throws -> [UInt8] {
        var payload: [UInt8] = [0xb0, UInt8(points & 255), UInt8(points >> 8)]
        for _ in 0..<points { payload += [UInt8(value & 255), UInt8(value >> 8)] }
        payload += [0]
        return try Frame.build(address: 0x81, payload: payload).encoded()
    }
}
private final class CountedProfileStream: ScanByteStreamOpening, SerialPortFileDescriptor, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    func openStream() throws -> any SerialPortFileDescriptor { self }
    func produce(_ value: [UInt8]) { lock.lock(); bytes += value; lock.unlock() }
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        lock.lock(); let result = bytes; bytes = []; lock.unlock()
        if result.isEmpty { Thread.sleep(forTimeInterval: 0.001); return .timeout }
        return .bytes(result)
    }
    func close() {}
}

private struct CountedScanner: SerialPortOpener {
    let stream: CountedProfileStream
    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> any SerialPortFileDescriptor { stream }
}

@MainActor private final class HandoffSource: ObservableObject {
    @Published var endpoint: VerifiedScannerConnection?
}

private final class CountedClockSource: MIDIClockSource, @unchecked Sendable {
    private let lock = NSLock()
    private var receive: (@Sendable (MIDIClockPacket) -> Void)?
    func open(_ id: Int32, _ receive: @escaping @Sendable (MIDIClockPacket) -> Void,
              _ lost: @escaping @Sendable () -> Void) -> (any MIDIClockSource)? {
        lock.lock(); self.receive = receive; lock.unlock(); return self
    }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return receive != nil }
    func emit(index: Int) {
        lock.lock(); let receive = receive; lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        if index == 1 { receive?(.init(bytes: [0xfa], timestamp: 10, arrival: now)) }
        for tick in (index*2-1)...(index*2) {
            receive?(.init(bytes: [0xf8], timestamp: 10 + Double(tick) / 48, arrival: now))
        }
    }
    func close() { lock.lock(); receive = nil; lock.unlock() }
}
