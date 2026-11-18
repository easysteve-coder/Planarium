import AppKit
import SwiftUI
import XCTest
import PlanariumDomain
@testable import PlanariumApplication
import PlanariumInput
@testable import PlanariumPresets
import PlanariumRuntime
import SickPLSCore
import SickPLSMacTransport
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class WorkspaceRenderingTests: XCTestCase {
    func testHarmony29MoveAndCompressionPreviewMeasurements() throws {
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmony 29 Picardy Switch"))
        let document = try PresetV6Codec.decode(data).document
        let workspace = CanvasDocumentProjection.workspace(document)
        let cells = Set(workspace.layers.flatMap(\.polarCells))
        let count = workspace.layers.reduce(0) { $0 + $1.polarCells.count }
        XCTAssertEqual(count, 3520)
        for compression in [false, true] {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20 {
                if compression { _ = PolarCellTransform.applying(.init(radialScale: 0.7), cells: cells, layerIDs: [], to: workspace) }
                else { _ = PolarCellMove.applying(radialSteps: 1, angularSteps: 0, cells: cells, layerIDs: [], to: workspace) }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 20_000_000
            print("Harmony 29 \(count) cells \(compression ? "compression" : "move"): \(ms) ms (reference budget 8 ms)")
            XCTAssertTrue(ms.isFinite)
        }
    }

    func testDetectionKnobRealMouseDefersCommitUntilUpAndPublishesDraft() throws {
        _ = NSApplication.shared.setActivationPolicy(.regular)
        NSApp.finishLaunching(); NSApp.activate(ignoringOtherApps: true)
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let original = owner.document.detection, preview = DetectionCanvasPreview()
        let knob = DetectionKnob(title: "Minimum gap", values: Array(1...30), value: Int(original.groupingJumpCentimeters),
            defaultValue: 10, format: { "\($0) cm" }, help: "Minimum gap", select: { value in
                var config = owner.document.detection; config.groupingJumpCentimeters = UInt16(value)
                owner.updateDetectionConfiguration(config)
            }, onPreview: preview.action(.minimumGap, base: original, matchingContour: false, performing: false))
        let cells = SpatialActiveCellDisplayModel()
        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<361).map { _ in try .build(value: 400, fieldFlags: 0) })
        cells.update(profileFrame: .init(sessionID: UUID(), sequence: 1, time: 0,
            measurements: try FullScanProfileAdapter.measurements(from: raw),
            geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw), activeCells: [:])
        var rendered: (DetectionConfiguration, DetectionOverlayPresentation)?
        preview.didRender = { rendered = ($0, $1) }
        let field = CartesianScanFieldView(editor: owner.canvas, profile: raw, activeCellDisplay: cells,
            spatialInstrument: owner, simulationBadge: AnyView(EmptyView()), forceDetectionOverlay: .minimumGap, detectionPreview: preview)
        let fieldHost = NSHostingView(rootView: field)
        let fieldWindow = NSWindow(contentRect: .init(x: -11000, y: -10000, width: 600, height: 450),
            styleMask: [.borderless], backing: .buffered, defer: false)
        fieldWindow.isReleasedWhenClosed = false; fieldWindow.contentView = fieldHost; fieldWindow.orderFrontRegardless()
        defer { fieldWindow.contentView = nil; fieldWindow.close() }
        let host = NSHostingView(rootView: knob.frame(width: 160, height: 120))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 160, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        func flush() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); fieldHost.layoutSubtreeIfNeeded(); fieldHost.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        flush(); flush()
        let timing = CanvasTimingProbe(); CanvasTimingProbe.current = timing
        defer { CanvasTimingProbe.current = nil }
        func send(_ type: NSEvent.EventType, y: CGFloat) throws {
            let point = host.convert(.init(x: 80, y: y), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            NSApp.sendEvent(event); flush()
        }
        try send(.leftMouseDown, y: 60)
        for y: CGFloat in [66, 72, 78] {
            try send(.leftMouseDragged, y: y)
            XCTAssertEqual(owner.document.detection, original)
        }
        let draft = try XCTUnwrap(preview.configuration)
        XCTAssertNotEqual(draft, original)
        let shown = try XCTUnwrap(rendered)
        XCTAssertEqual(shown.0, draft)
        XCTAssertFalse(shown.1.labels.isEmpty)
        XCTAssertTrue(shown.1.labels.allSatisfy { $0.text.hasPrefix("\(draft.groupingJumpCentimeters) cm ·") })
        XCTAssertEqual(timing.counts["runtime.compile", default: 0], 0)
        try send(.leftMouseUp, y: 78)
        XCTAssertEqual(owner.document.detection, draft)
        XCTAssertEqual(timing.counts["runtime.compile", default: 0], 1)
        XCTAssertNil(preview.configuration)
    }

    func testHeaderEveryButtonExactlyOnceAndHeightWideNarrowLabelsEditPerform() throws {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop(); fixture.root.terminate {} }
        let owner = fixture.root.document
        let original = owner.document
        let host = NSHostingView(rootView: MeasurementPane(display: fixture.root.display, instrument: owner,
            simulation: layout.view.simulation, workspace: layout.workspace).padding(12)
            .environment(\.colorScheme, .dark).background(StageTheme.workspace))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 1200, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
        defer { window.close() }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func elements(_ value: Any, depth: Int = 0) -> [NSObject] {
            guard depth < 40, let element = value as? NSObject else { return [] }
            let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren()
                ?? (element.responds(to: NSSelectorFromString("accessibilityChildren"))
                    ? element.value(forKey: "accessibilityChildren") as? [Any] : nil)
                ?? element.accessibilityAttributeValue(.children) as? [Any] ?? []
            return [element] + children.flatMap { elements($0, depth: depth + 1) }
        }
        func label(_ element: NSObject) -> String? {
            (element as? NSAccessibilityProtocol)?.accessibilityLabel()
                ?? (element.responds(to: NSSelectorFromString("accessibilityLabel"))
                    ? element.value(forKey: "accessibilityLabel") as? String : nil)
                ?? element.accessibilityAttributeValue(.description) as? String
                ?? element.accessibilityAttributeValue(.title) as? String
        }
        func frame(_ element: NSObject) -> CGRect {
            (element as? NSAccessibilityProtocol)?.accessibilityFrame()
                ?? (element.responds(to: NSSelectorFromString("accessibilityFrame"))
                    ? (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue : nil) ?? .zero
        }
        func pointer(_ view: NSView) -> ScanFieldPointerEvents.PointerView? {
            if let pointer = view as? ScanFieldPointerEvents.PointerView, !pointer.isKeyboardOnly { return pointer }
            return view.subviews.compactMap(pointer).first
        }
        let editNames = MetricCanvasTool.allCases.map(\.label) + ["Cell size", "Reset view", "Zoom to measurement",
            "Zoom out", "Zoom in", "Mirror horizontally", "Merge zones", "Show raw scan", "Scanner flag bits", "Add scene", "Device fields"]
        for performing in [false, true] {
            if performing { layout.workspace.togglePerformance(canvas: owner.canvas) }
            for labels in [false, true] {
                layout.workspace.setFieldToolbarLabels(labels)
                XCTAssertEqual(WorkspaceControlModel(defaults: try XCTUnwrap(UserDefaults(suiteName: layout.suiteName))).preferences.fieldToolbarLabels, labels)
                for width in [1200, 380] {
                    window.setContentSize(.init(width: width, height: 900))
                    host.frame = .init(x: 0, y: 0, width: width, height: 900)
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                    host.layoutSubtreeIfNeeded()
                    let all = elements(host)
                    let names = (performing ? [] : editNames) + ["Scenes", "Show device fields"]
                    for name in names {
                        let matches = all.filter { label($0) == name }
                        XCTAssertEqual(matches.count, 1, "\(name) width=\(width) labels=\(labels) perform=\(performing)")
                        if let element = matches.first {
                            let rect = frame(element)
                            XCTAssertGreaterThan(rect.width, 0, name)
                            let inWindow = window.convertFromScreen(rect)
                            let local = host.convert(inWindow, from: nil)
                            XCTAssertGreaterThanOrEqual(local.minX, -1, name)
                            XCTAssertLessThanOrEqual(local.maxX, CGFloat(width) + 1, name)
                        }
                    }
                    let controls = names.compactMap { name in all.first { label($0) == name } }
                    for (index, left) in controls.enumerated() {
                        for right in controls.dropFirst(index + 1) {
                            XCTAssertFalse(frame(left).insetBy(dx: 1, dy: 1).intersects(frame(right).insetBy(dx: 1, dy: 1)),
                                "Overlapping \(label(left) ?? "?") / \(label(right) ?? "?") width=\(width) labels=\(labels)")
                        }
                    }
                    if performing {
                        for original in editNames {
                            let name = original
                            XCTAssertFalse(all.contains { label($0) == name }, name)
                        }
                    }
                    let field = try XCTUnwrap(pointer(host))
                    let rect = field.convert(field.bounds, to: host)
                    let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
                    // Measured on 5ba5155 product code before this slice: 204 / 236 pt.
                    let before: CGFloat = width == 1200 ? 204 : 236
                    let oldFieldHeight: CGFloat = width == 1200 ? 546 : 514
                    print("KOPFLEISTE width=\(width) labels=\(labels) perform=\(performing) top=\(top) savedAbove=\(before - top) fieldHeight=\(rect.height) gainedField=\(rect.height - oldFieldHeight)")
                    if !performing && !labels { XCTAssertLessThan(top, before) }
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(
                        "header-\(width)-\(labels ? "labels" : "icons")-\(performing ? "perform" : "edit").png"))
                    let whole = NSHostingView(rootView: layout.view.environment(\.colorScheme, .dark))
                    whole.appearance = NSAppearance(named: .darkAqua)
                    try captureLayout2(whole, width: width == 380 ? 1024 : 1728,
                        name: "header-\(labels ? "labels" : "icons")-\(performing ? "perform" : "edit")", directory: directory)
                }
            }
        }
        XCTAssertEqual(owner.document, original)
    }

    func testHeaderInputNoticeKeepsHeightForEveryStatusAndLayoutContainsEveryGroupOnce() throws {
        for status in [InputBacklogStatus.ready, .overloaded, .recovered] {
            let host = NSHostingView(rootView: InputBacklogNotice(status: status).frame(width: 380))
            XCTAssertEqual(host.fittingSize.height, 18)
        }
        for width in [356.0, 716, 1176, 1704] {
            for labels in [false, true] {
                let rows = FieldToolbarLayout.rows(width: width, labels: labels, performing: false, scenes: true, deviceFields: true)
                XCTAssertEqual(rows.flatMap { $0 }, FieldToolbarLayout.Group.allCases)
                for row in rows {
                    XCTAssertLessThanOrEqual(row.reduce(0) { $0 + FieldToolbarLayout.width($1, labels: labels) } + Double(row.count - 1) * 8, width)
                }
            }
        }
    }

    func testHeaderNativeMenusPersistLabelsAndKeepScenesPlayableWithAuthoringLocked() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        let owner = fixture.root.document
        owner.canvas.updateWorkspace { _ = $0.addScene(); _ = $0.addScene() }
        let scenes = owner.canvas.workspace.scenes
        func nativeMenu<V: View>(_ view: V, check: (NSMenu) throws -> Void) throws {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 280, height: 80),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
            defer { window.close() }
            host.frame = .init(x: 0, y: 0, width: 280, height: 80)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            func popup(_ view: NSView) -> NSPopUpButton? {
                if let button = view as? NSPopUpButton { return button }
                return view.subviews.compactMap(popup).first
            }
            let button = try XCTUnwrap(popup(host)), menu = try XCTUnwrap(button.menu)
            let timer = Timer.scheduledTimer(timeInterval: 0.05, target: menu,
                selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .eventTracking); button.performClick(nil); timer.invalidate()
            menu.delegate?.menuWillOpen?(menu); menu.delegate?.menuNeedsUpdate?(menu); menu.update()
            try check(menu)
        }
        let labels = Binding(get: { layout.workspace.preferences.fieldToolbarLabels }, set: { layout.workspace.setFieldToolbarLabels($0) })
        try nativeMenu(Menu("Toolbar") { FieldToolbarLabelMenu(labels: labels) }) { menu in
            XCTAssertEqual(menu.items.filter { !$0.title.isEmpty }.map(\.title), ["Show labels", "Icons only"])
            for (title, expected) in [("Show labels", true), ("Icons only", false)] {
                menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == title }))
                XCTAssertEqual(layout.workspace.preferences.fieldToolbarLabels, expected)
                XCTAssertEqual(WorkspaceControlModel(defaults: try XCTUnwrap(UserDefaults(suiteName: layout.suiteName))).preferences.fieldToolbarLabels, expected)
            }
        }
        for performing in [false, true] {
            if performing { layout.workspace.togglePerformance(canvas: owner.canvas) }
            try nativeMenu(SceneBarView(instrument: owner, compact: true)) { menu in
                for scene in scenes {
                    let indices = menu.items.indices.filter { menu.items[$0].title == scene.name || menu.items[$0].title == "✓ " + scene.name }
                    XCTAssertEqual(indices.count, 1)
                    menu.performActionForItem(at: try XCTUnwrap(indices.first))
                    let deadline = Date().addingTimeInterval(2)
                    while owner.canvas.workspace.currentSceneID != scene.id, Date() < deadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                    }
                    XCTAssertEqual(owner.canvas.workspace.currentSceneID, scene.id)
                }
                XCTAssertEqual(menu.items.filter { $0.title.hasPrefix("Edit ") }.count, performing ? 0 : scenes.count)
            }
        }
    }
    func testLayout2CellScenesAndPerformanceWideAndNarrowWithActualMMK90() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop() }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        layout.view.simulation.selectInput(.iPhoneSimulation)
        let host = NSHostingView(rootView: layout.view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
        host.frame = .init(x: 0, y: 0, width: 1728, height: 900)
        host.layoutSubtreeIfNeeded()
        // Detached offline hosting does not promise when SwiftUI onAppear
        // runs. Establish this fixture's subscription before the first scan.
        fixture.root.display.start()
        let owner = fixture.root.document
        for preset in ["Harmony 29 Picardy Switch", "Harmony 30 Mode Wheel"] {
            XCTAssertNotNil(layout.view.presets.load(preset, decision: .discard))
            XCTAssertEqual(owner.canvas.workspace.scenes.count, preset.contains("29") ? 2 : 6)
            let musical = try XCTUnwrap(owner.document.spatial.layers.first { $0.isActive && $0.routings.contains {
                if case .midiNote = $0.target { return true }; if case .audioUnitNote = $0.target { return true }; return false
            } })
            let noteCell = try XCTUnwrap(musical.cells.sorted { ($0.ring, $0.sector) < ($1.ring, $1.sector) }.first)
            let setupStart = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(fixture.root.input.connectSimulation(serviceName: "Offline MMK 90", opener: try OfflineLayoutStream(cell: noteCell)), .connecting)
            let sessionID = try XCTUnwrap(fixture.root.input.session.sessionID)
            // Establish the actual R -> Q -> Main handoff for this session
            // before checking/rendering the layout. The fixed settle below
            // alone is not an acknowledgement of asynchronous input startup.
            let readyDeadline = Date().addingTimeInterval(3)
            while fixture.root.display.frame?.profile?.sessionID != sessionID, Date() < readyDeadline {
                fixture.root.display.start()
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertEqual(fixture.root.display.frame?.profile?.sessionID, sessionID,
                "\(preset): RX=\(fixture.root.input.session.state.lastProfile?.measurements.count ?? -1), Q=\(fixture.root.runtime.mailbox.read()?.profile?.measurements.count ?? -1), pump=\(fixture.root.display.pumpPassCount)")
            print("LAYOUT2-READY preset=\(preset) setup_ms=\((ProcessInfo.processInfo.systemUptime - setupStart) * 1000) pump=\(fixture.root.display.pumpPassCount)")
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            XCTAssertEqual(fixture.root.display.frame?.profile?.measurements.count, 90)
            for kind in ["note", "switch"] {
                let layer = kind == "note" ? musical : try XCTUnwrap(owner.document.spatial.layers.first { $0.routings.contains { if case .sceneSwitch = $0.target { return true }; return false } })
                owner.canvas.updateWorkspace { $0.selectLayer(layer.id) }
                let tile = try XCTUnwrap(owner.canvas.workspace.selectedLayer.polarCells.sorted { ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex) }.first)
                let size = CGSize(width: 3000, height: 4000)
                let center = SpatialFieldPlan.center(.init(cell: tile, grid: owner.canvas.workspace.grid))
                let point = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
                _ = owner.canvas.selectCell(atScreenPoint: point, canvasSize: size)
                XCTAssertNotNil(owner.canvas.selectedPolarCell)
                if kind == "switch" { XCTAssertTrue(owner.canvas.setSceneAction(.scene(owner.canvas.workspace.scenes[0].id))) }
                layout.workspace.setVisible(.setup, false); layout.workspace.selectTab(.cell)
                for width in [1728, 1024] {
                    try captureLayout2(host, width: width, name: "\(owner.canvas.workspace.scenes.count)-scenes-\(kind)", directory: directory)
                }
            }
            let preferences = layout.workspace.preferences
            layout.workspace.togglePerformance(canvas: owner.canvas)
            for width in [1728, 1024] {
                try captureLayout2(host, width: width, name: "\(owner.canvas.workspace.scenes.count)-scenes-perform", directory: directory)
                XCTAssertTrue(owner.canvas.isPerformanceLocked)
            }
            fixture.root.input.disconnect()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let releasedDeadline = Date().addingTimeInterval(3)
            while fixture.root.input.session.isPortHeld, Date() < releasedDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertFalse(fixture.root.input.session.isPortHeld, "Release the old input before reconnecting the next preset")
            XCTAssertTrue(layout.workspace.inputLost)
            for width in [1728, 1024] {
                try captureLayout2(host, width: width, name: "\(owner.canvas.workspace.scenes.count)-scenes-input-lost", directory: directory)
            }
            XCTAssertEqual(layout.workspace.preferences, preferences)
            layout.workspace.togglePerformance(canvas: owner.canvas)
            XCTAssertEqual(layout.workspace.preferences, preferences)
        }
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }
    private func captureLayout2(_ host: NSHostingView<some View>, width: Int, name: String, directory: URL) throws {
        host.frame = .init(x: 0, y: 0, width: width, height: 900)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("layout-2-\(name)-\(width).png"))
    }
    func testRealWorkspaceAllVisibilityStatesWithMMK90WideAndNarrow() throws {
        let fixture = try MonitorRootFixture()
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop() }
        layout.view.presets.load("Harmony 30 Mode Wheel")
        XCTAssertNotNil(layout.view.presets.lastLoadedName)
        layout.view.simulation.selectInput(.iPhoneSimulation)
        let stream = try OfflineLayoutStream()
        _ = fixture.root.input.connectSimulation(serviceName: "Offline MMK 90", opener: stream)
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [1728, 1280, 1024] {
            let host = NSHostingView(rootView: layout.view.environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.wantsLayer = true
            let height = width == 1024 ? 2400 : 1100
            host.frame = .init(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(fixture.root.display.frame?.profile?.measurements.count, 90)
            // Actual runtime publication populates the production canvas.
            let size = CGSize(width: 3000, height: 4000)
            let owner = fixture.root.document
            let selected = try XCTUnwrap(owner.canvas.workspace.selectedLayer.polarCells.sorted {
                $0.ring == $1.ring ? $0.angularIndex < $1.angularIndex : $0.ring < $1.ring
            }.first)
            let center = SpatialFieldPlan.center(.init(cell: selected, grid: owner.canvas.workspace.grid))
            let point = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
            _ = owner.canvas.selectCell(atScreenPoint: point, canvasSize: size)
            XCTAssertNotNil(fixture.root.document.canvas.selectedPolarCell)
            XCTAssertNotNil(SpatialCellInfo.make(cell: selected, layerID: owner.canvas.workspace.selectedLayerID, workspace: owner.canvas.workspace))
            for state in ["all", "setup-collapsed", "tabs-layers", "tabs-cell", "field-strip"] {
                layout.workspace.setVisible(.setup, state == "all" || state.hasPrefix("tabs"))
                layout.workspace.setVisible(.layers, state != "field-strip")
                layout.workspace.setVisible(.cell, state != "field-strip")
                layout.workspace.setVisible(.channelStrip, true)
                layout.workspace.selectTab(state == "tabs-cell" ? .cell : .layers)
                // Tabs are a narrow-window state; wide images show both panes.
                if state.hasPrefix("tabs") && width == 1728 { continue }
                host.frame.size.width = CGFloat(width)
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 1000)
                let name = "layout-1-\(state)-\(width).png"
                try data.write(to: directory.appendingPathComponent(name))
            }
        }
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }

    func testFieldIdentityAndDisplayContinueAcrossAutoCollapseAndBothTabOrders() throws {
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop() }
        let host = NSHostingView(rootView: layout.view)
        host.frame = .init(x: 0, y: 0, width: 1024, height: 900)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        // A user-panned viewport must survive changes in field size. The
        // default anchored viewport intentionally follows the scanner bottom.
        XCTAssertTrue(fixture.root.document.canvas.panViewport(byScreenX: 7, screenY: 5))
        let before = fixture.root.document.canvas.viewport
        _ = fixture.root.input.connectSimulation(serviceName: "Offline MMK 90", opener: try OfflineLayoutStream())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(layout.workspace.preferences.setup)
        let first = try XCTUnwrap(fixture.root.display.frame?.profile?.sequence)
        for tab in [WorkspaceLayout.InspectorTab.cell, .layers, .cell] {
            layout.workspace.selectTab(tab)
            layout.workspace.setVisible(.setup, true)
            host.layoutSubtreeIfNeeded()
            layout.workspace.setVisible(.setup, false)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertGreaterThan(try XCTUnwrap(fixture.root.display.frame?.profile?.sequence), first)
        XCTAssertEqual(fixture.root.document.canvas.viewport, before)
        print("LAYOUT-1 identity bodies=\(probe.counts)")
        XCTAssertEqual(probe.counts["measurementAppear", default: 0], 0)
        XCTAssertEqual(probe.counts["measurementDisappear", default: 0], 0)
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }
}
private struct OfflineLayoutStream: ScanByteStreamOpening {
    let descriptor: OfflineLayoutDescriptor
    init() throws {
        var payload: [UInt8] = [0xb0, 90, 0]
        for index in 0..<90 { payload += [abs(index - 45) < 3 ? 90 : 250, 0] }
        payload += [0]
        descriptor = OfflineLayoutDescriptor(bytes: try Frame.build(address: 0x81, payload: payload).encoded())
    }
    init(cell: PolarDeviceLattice) throws {
        let geometry = ProfileGeometryIdentity(operatingMode: "MMK", pointCount: 90, startAngleDegrees: -90, endAngleDegrees: 90)
        let selected = try XCTUnwrap((0..<90).first { geometry.tickSpan(at: $0).map { $0.lower...$0.upper ~= cell.sector } ?? false })
        var payload: [UInt8] = [0xb0, 90, 0]
        for order in 0..<90 {
            let raw = abs(order - selected) <= 1 ? cell.ring : 500
            payload += [UInt8(raw & 0xff), UInt8(raw >> 8)]
        }
        payload += [0]
        descriptor = OfflineLayoutDescriptor(bytes: try Frame.build(address: 0x81, payload: payload).encoded())
    }
    func openStream() throws -> any SerialPortFileDescriptor { descriptor }
}
private final class OfflineLayoutDescriptor: SerialPortFileDescriptor, Sendable {
    let bytes: [UInt8]
    init(bytes: [UInt8]) { self.bytes = bytes }
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        Thread.sleep(forTimeInterval: 0.04)
        return .bytes(bytes)
    }
    func close() {}
}

extension WorkspaceRenderingTests {
    func testRundeALabelsEditPerformWideNarrowAndReadOnlyInserts() throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        var channel = fixture.root.document.document.channels[0]
        let identity = SpatialAudioUnitIdentity(componentType: 0x61756678, componentSubType: 123, componentManufacturer: 456)
        channel.inserts = (0..<2).map { _ in .init(id: UUID(), plugin: .init(identity: identity)) }
        fixture.root.document.updateChannel(channel)
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for perform in [false, true] {
            if perform { layout.workspace.togglePerformance(canvas: fixture.root.document.canvas) }
            for labels in [false, true] {
                layout.workspace.setButtonLabels(labels)
                let host = NSHostingView(rootView: layout.view.environment(\.colorScheme, .dark))
                host.appearance = NSAppearance(named: .darkAqua)
                for width in [1728, 1024] {
                    try captureLayout2(host, width: width,
                        name: "runde-a-\(perform ? "perform" : "edit")-\(labels ? "labels" : "icons")", directory: directory)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let edge = try XCTUnwrap(bitmap.colorAt(x: 1, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                    let amber = try XCTUnwrap(NSColor(StageTheme.amber).usingColorSpace(.deviceRGB))
                    let amberDistance = abs(edge.redComponent - amber.redComponent)
                        + abs(edge.greenComponent - amber.greenComponent) + abs(edge.blueComponent - amber.blueComponent)
                    if perform { XCTAssertLessThan(amberDistance, 0.08, "Variant B frame must remain visible with captions on or off") }
                    else { XCTAssertGreaterThan(amberDistance, 0.2) }
                    let headerView = WorkspaceStatusView(input: fixture.root.input,
                        simulation: layout.view.simulation, workspace: layout.workspace, presets: layout.view.presets,
                        instrument: fixture.root.document)
                    if perform {
                        for area in [WorkspaceLayout.Area.setup, .layers, .cell, .channelStrip] {
                            XCTAssertEqual(headerView.tooltip(area), "Locked in Perform mode · ⌘⇧P to edit")
                        }
                    }
                    let header = NSHostingView(rootView: headerView.environment(\.fieldToolbarLabels, labels))
                    header.frame = .init(x: 0, y: 0, width: width, height: 44)
                    XCTAssertEqual(header.fittingSize.height, 44, "Mode changes must not move the field below the header")
                    if perform {
                        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 44),
                            styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false; window.contentView = header; window.orderFrontRegardless()
                        header.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                        func elements(_ value: Any, depth: Int = 0) -> [NSObject] {
                            guard depth < 40, let element = value as? NSObject else { return [] }
                            let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren()
                                ?? (element.responds(to: NSSelectorFromString("accessibilityChildren"))
                                    ? element.value(forKey: "accessibilityChildren") as? [Any] : nil) ?? []
                            return [element] + children.flatMap { elements($0, depth: depth + 1) }
                        }
                        let edit = try XCTUnwrap(elements(header).first {
                            (($0 as? NSAccessibilityProtocol)?.accessibilityLabel()
                                ?? ($0.responds(to: NSSelectorFromString("accessibilityLabel"))
                                    ? $0.value(forKey: "accessibilityLabel") as? String : nil)) == "Edit ⌘⇧P"
                        })
                        let screen = (edit as? NSAccessibilityProtocol)?.accessibilityFrame()
                            ?? (edit.responds(to: NSSelectorFromString("accessibilityFrame"))
                                ? (edit.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue : nil) ?? .zero
                        let local = header.convert(window.convertFromScreen(screen), from: nil)
                        XCTAssertGreaterThan(local.width, 50, "Edit must remain a usable visible button")
                        XCTAssertGreaterThanOrEqual(local.minX, 0)
                        XCTAssertLessThanOrEqual(local.maxX, CGFloat(width))
                        window.close()
                    }
                    if !perform && width == 1024 {
                        func segments(_ view: NSView) -> [NSSegmentedControl] {
                            (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(segments)
                        }
                        let all = segments(host)
                        XCTAssertFalse(all.isEmpty)
                        for control in all { XCTAssertEqual(control.segmentCount, 2, "A caption must not become another picker choice") }
                    }
                }
            }
        }
        var actions = 0
        let readOnly = StudioInsertRow(title: "Instrument · DLS", accessibilityBase: "runde-a.readOnly", tint: .purple,
            isOn: true, canToggle: true, canOpen: true, toggle: { actions += 1 }, open: { actions += 1 },
            choices: [.init(id: "empty", title: "Empty", selected: true, action: { actions += 1 })], readOnly: true)
        let host = NSHostingView(rootView: readOnly)
        host.frame = .init(x: 0, y: 0, width: 92, height: 30); host.layoutSubtreeIfNeeded()
        func controls(_ view: NSView) -> [NSControl] {
            (view as? NSControl).map { [$0] } ?? view.subviews.flatMap(controls)
        }
        XCTAssertTrue(controls(host).isEmpty)
        XCTAssertEqual(actions, 0)
    }

    func testRundeANativeSelectionItemsHaveExactlyOneStateAndSelectionAction() throws {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let palette = [Color(red: 0.2, green: 0.5, blue: 0.9), Color(red: 0.92, green: 0.56, blue: 0.1)]
        let rgb = try XCTUnwrap(NSColor(palette[0]).usingColorSpace(.deviceRGB))
        let restored = Color(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        XCTAssertTrue(StageTheme.sameColor(palette[0], restored), "Color-panel round trips must retain the native selection")
        XCTAssertEqual(palette.filter { StageTheme.sameColor($0, restored) }.count, 1)
        let cases: [(String, [String], Int)] = [
            ("midi-channel", (1...16).map { "Channel \($0)" }, 5),
            ("output", ["No output", "AU instrument", "MIDI"], 1),
            ("cc", ["7 · Volume", "10 · Pan", "74 · Brightness"], 2)
        ]
        for (name, titles, initial) in cases {
            var selected = initial
            let host = NSHostingView(rootView: Menu(name) {
                ForEach(titles.indices, id: \.self) { index in
                    SelectionMenuItem(titles[index], selected: index == selected) { selected = index }
                }
            })
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 220, height: 40),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
            defer { window.close() }
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            func popup(_ view: NSView) -> NSPopUpButton? {
                if let button = view as? NSPopUpButton { return button }
                return view.subviews.compactMap(popup).first
            }
            let button = try XCTUnwrap(popup(host)), menu = try XCTUnwrap(button.menu)
            let directory = TestImageDirectory.make()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let capture = RundeAMenuCapture(menu: menu, owner: window, directory: directory, name: name)
            let timer = Timer.scheduledTimer(timeInterval: 0.05, target: capture,
                selector: #selector(RundeAMenuCapture.captureAndClose), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .eventTracking); button.performClick(nil); timer.invalidate()
            menu.delegate?.menuWillOpen?(menu); menu.delegate?.menuNeedsUpdate?(menu); menu.update()
            let choices = menu.items.filter { titles.contains($0.title) }
            XCTAssertEqual(choices.count, titles.count)
            XCTAssertEqual(choices.filter { $0.state == .on }.map(\.title), [titles[initial]])
            XCTAssertFalse(choices.contains { $0.title.contains("✓") })
            let next = (initial + 1) % titles.count
            menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == titles[next] }))
            XCTAssertEqual(selected, next)
        }
    }
}

extension WorkspaceRenderingTests {
    func testRundeAFiftyLocalStepsRenderEachControlWithoutRebuildingUnchangedPiano() throws {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        for kind in ["velocity", "pan", "fader", "detection"] {
            let drag = ControlDragSession()
            var value = 0.0, writes = 0
            let binding = Binding(get: { value }, set: { value = $0; writes += 1 })
            let control: AnyView
            switch kind {
            case "velocity": control = AnyView(DeferredControlSlider(value: binding, range: 0...100, defaultValue: 100, drag: drag))
            case "pan": control = AnyView(HelmutPanKnob(pan: 0, setPan: { _ in writes += 1 }, diameter: 32, drag: drag))
            case "fader": control = AnyView(LogicVerticalFader(value: binding, showsOwnScale: false, drag: drag).frame(width: 30, height: 180))
            default: control = AnyView(DetectionKnob(title: "Minimum gap", values: Array(0...100), value: 0,
                defaultValue: 10, format: { "\($0)" }, help: "Minimum gap", select: { _ in writes += 1 }, drag: drag))
            }
            let host = NSHostingView(rootView: VStack {
                PianoKeyboardView(model: .constant(.init()), velocity: .constant(100), transition: .constant(.retrigger), supportsNoteTransition: false)
                control
            }.padding(12).environment(\.fieldToolbarLabels, false))
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 320, height: 380),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
            defer { window.close() }
            host.frame = .init(x: 0, y: 0, width: 320, height: 380)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            func pixels() throws -> Data {
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            }
            let before = try pixels()
            let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
            defer { ViewEvaluationProbe.current = nil }
            drag.begin(0, write: { value = $0; writes += 1 })
            let start = ProcessInfo.processInfo.systemUptime
            for step in 1...50 { drag.change(kind == "pan" || kind == "fader" ? Double(step) / 100 : Double(step), live: false) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            let after = try pixels()
            let drawMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertNotEqual(before, after, "The real \(kind) control must render its local draft before publication")
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(probe.counts["piano.body", default: 0], 0)
            XCTAssertEqual(probe.counts["piano.layout", default: 0], 0)
            drag.finish(); XCTAssertEqual(writes, 1)
            print("RUNDE-A \(kind) offscreen_50_steps_to_render_ms=\(drawMS) unchanged_piano_body=0")
        }
    }
}

@MainActor private final class RundeAMenuCapture: NSObject {
    let menu: NSMenu
    let owner: NSWindow
    let directory: URL
    let name: String
    init(menu: NSMenu, owner: NSWindow, directory: URL, name: String) {
        self.menu = menu; self.owner = owner; self.directory = directory; self.name = name
    }
    @objc func captureAndClose() {
        for candidate in NSApplication.shared.windows where candidate !== owner {
            guard String(describing: type(of: candidate)).contains("Menu"), let surface = candidate.contentView,
                  surface.bounds.width > 0, let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { continue }
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            // Native Aqua draws black glyphs into a transparent bitmap. Supply
            // its light background so the actual menu text stays legible.
            let image = NSImage(size: bitmap.size)
            image.lockFocus()
            NSColor.white.setFill(); NSRect(origin: .zero, size: bitmap.size).fill()
            let glyphs = NSImage(size: bitmap.size); glyphs.addRepresentation(bitmap)
            glyphs.draw(in: NSRect(origin: .zero, size: bitmap.size))
            image.unlockFocus()
            if let data = image.tiffRepresentation, let opaque = NSBitmapImageRep(data: data) {
                try? opaque.representation(using: .png, properties: [:])?.write(to:
                    directory.appendingPathComponent("runde-a-native-\(name)-menu.png"))
            }
        }
        menu.cancelTracking()
    }
}


extension WorkspaceRenderingTests {
    func testSnapPreviewFromOffHasCanonicalRegionsWithoutRuntimeCommitAndCachesScalarSteps() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let layer = SpatialInstrumentLayer(name: "C major", color: .blue,
            polarCells: [.init(ring: 2, angularIndex: 7), .init(ring: 2, angularIndex: 8)],
            routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [60,64,67], velocity: 90, transition: .retrigger))])
        owner.canvas.replaceWorkspace(.init(grid: .quarterMeter, layers: [layer], preserveLayerStructure: true))
        var configuration = owner.document.detection
        configuration.cellSelection.boundaryMarginCentimeters = 0
        owner.updateDetectionConfiguration(configuration)
        let revision = owner.document.revision
        let preview = DetectionCanvasPreview(), cells = SpatialActiveCellDisplayModel()
        let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<361).map { _ in try .build(value: 200, fieldFlags: 0) })
        cells.update(profile: raw, activeCells: [:])
        var rendered: (DetectionConfiguration, DetectionOverlayPresentation)?
        preview.didRender = { rendered = ($0,$1) }
        let field = CartesianScanFieldView(editor: owner.canvas, profile: raw, activeCellDisplay: cells,
            spatialInstrument: owner, simulationBadge: AnyView(EmptyView()), forceDetectionOverlay: .edgeMargin,
            detectionPreview: preview)
        let host = NSHostingView(rootView: field)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 740, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
        defer { window.close() }
        host.frame = .init(x: 0, y: 0, width: 740, height: 1000)
        func flush() {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        flush(); flush()
        XCTAssertFalse(DetectionOverlayPresentation.cellMargins(instrument: owner.compiledInstrument, layerID: layer.id, centimeters: 3).shapes.isEmpty,
            "Snap Off still carries the canonical partition for PANIC surface locks")
        let action = preview.action(.snap, base: configuration, matchingContour: false, performing: false)
        var preceding: DetectionOverlayPresentation?
        for value in [3,4,5] {
            rendered = nil; action(value); flush(); flush()
            let result = try XCTUnwrap(rendered)
            XCTAssertEqual(result.0.cellSelection.boundaryMarginCentimeters, UInt16(value))
            XCTAssertFalse(result.1.shapes.isEmpty, "The first preview from Off must already show the region")
            if let preceding { XCTAssertNotEqual(result.1, preceding) }
            preceding = result.1
            XCTAssertEqual(owner.document.revision, revision)
            XCTAssertEqual(owner.document.detection.cellSelection.boundaryMarginCentimeters, 0)
            XCTAssertEqual(preview.snapCompilationCount, 1, "Scalar drag steps must reuse canonical display regions")
        }
        configuration.cellSelection.boundaryMarginCentimeters = 3
        owner.updateDetectionConfiguration(configuration); preview.update(nil); flush(); flush()
        XCTAssertEqual(preview.snapCompilationCount, 2, "A committed revision must replace the display cache")
        XCTAssertEqual(rendered?.1, DetectionOverlayPresentation.cellMargins(instrument: owner.compiledInstrument,
            layerID: layer.id, centimeters: 3), "Display partition must equal the newly committed runtime partition")
    }

    func testReglerFluessigSixtySpacedStepsStayLocalUntilExactReleaseWideNarrow() throws {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        for width in [1024, 1728] {
            let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
            let owner = fixture.root.document, drag = ControlDragSession()
            defer { layout.cleanDefaults(); fixture.root.terminate {}; ViewEvaluationProbe.current = nil; CanvasTimingProbe.current = nil }
            let original = owner.document.detection
            let preview = DetectionCanvasPreview(), cells = SpatialActiveCellDisplayModel()
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<361).map { _ in try .build(value: 400, fieldFlags: 0) })
            let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
                measurements: try FullScanProfileAdapter.measurements(from: raw),
                geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
            cells.update(profileFrame: frame, activeCells: [:])
            var rendered: (DetectionConfiguration, DetectionOverlayPresentation)?
            preview.didRender = { rendered = ($0, $1) }

            let knob = DetectionKnob(title: "Minimum gap", values: Array(1...30), value: Int(original.groupingJumpCentimeters),
                defaultValue: 10, format: { "\($0) cm" }, help: "Minimum gap", select: { value in
                    var configuration = owner.document.detection
                    configuration.groupingJumpCentimeters = UInt16(value)
                    owner.updateDetectionConfiguration(configuration)
                }, onEditing: { if $0 { owner.beginContinuousEdit() } else { owner.endContinuousEdit() } },
                onPreview: preview.action(.minimumGap, base: original, matchingContour: false, performing: false), drag: drag)
            let mounting = ViewEvaluationProbe(); ViewEvaluationProbe.current = mounting
            let field = CartesianScanFieldView(editor: owner.canvas, profile: raw, activeCellDisplay: cells,
                spatialInstrument: owner, simulationBadge: AnyView(EmptyView()), forceDetectionOverlay: .minimumGap,
                detectionPreview: preview)
            let host = NSHostingView(rootView: VStack { layout.view; field.frame(height: 450); knob })
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 1100),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
            defer { window.close() }
            host.frame = .init(x: 0, y: 0, width: width, height: 1100)
            func flush() {
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.045))
            }
            flush(); flush()
            // Drain the initial runtime install before measuring interaction.
            // Under TSan its delayed host publication can outlive the mount.
            let startup = expectation(description: "Initial runtime installation acknowledged")
            fixture.root.runtime.acknowledge { startup.fulfill() }
            wait(for: [startup], timeout: 5)
            flush(); flush()
            XCTAssertGreaterThan(mounting.counts["presetBar.body", default: 0], 0)
            XCTAssertGreaterThan(mounting.counts["channel", default: 0], 0)
            let probe = ViewEvaluationProbe(), timing = CanvasTimingProbe()
            ViewEvaluationProbe.current = probe; CanvasTimingProbe.current = timing
            for step in 1...60 {
                let next = 1 + step % 30
                knob.changeDrag(translationY: -Double(next - Int(original.groupingJumpCentimeters)) * 6, fine: false)
                flush() // Exceed the former 40 ms publication timer on every step.
                XCTAssertEqual(owner.document.detection, original)
                let shown = try XCTUnwrap(rendered)
                XCTAssertEqual(shown.0.groupingJumpCentimeters, UInt16(next))
                XCTAssertFalse(shown.1.labels.isEmpty)
                XCTAssertTrue(shown.1.labels.allSatisfy { $0.text.hasPrefix("\(next) cm ·") })
                // The actual drawn measure segment must have the current length.
                let measure = try XCTUnwrap(shown.1.shapes.first)
                let p = try XCTUnwrap(measure.points.first), q = try XCTUnwrap(measure.points.last)
                XCTAssertEqual(hypot(q.xMeters-p.xMeters, q.yMeters-p.yMeters), Double(next)/100, accuracy: 0.000001)
            }
            XCTAssertEqual(drag.displayed, 1)
            XCTAssertEqual(timing.counts["runtime.compile", default: 0], 0)
            XCTAssertEqual(probe.counts["presetBar.body", default: 0], 0)
            XCTAssertEqual(probe.counts["channel", default: 0], 0)
            XCTAssertGreaterThan(timing.counts["field.scanDraw", default: 0], 0)
            XCTAssertLessThanOrEqual(timing.counts["field.scanDraw", default: 0], 60)
            XCTAssertEqual(probe.counts["field", default: 0], 0, "Canvas preview must not reevaluate the field/toolbar")
            let directory = TestImageDirectory.make()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try captureLayout2(host, width: width, name: "regler-preview-document-10-draft-1", directory: directory)
            let final = try XCTUnwrap(drag.displayed)
            drag.finish(); flush()
            XCTAssertNil(preview.configuration)
            try captureLayout2(host, width: width, name: "regler-committed-1", directory: directory)
            XCTAssertEqual(owner.document.detection.groupingJumpCentimeters, UInt16(final))
            XCTAssertEqual(timing.counts["runtime.compile", default: 0], 1)
            XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.detection, original)
            knob.changeDrag(translationY: -12, fine: false); drag.cancel()
            XCTAssertNil(preview.configuration)
            knob.changeDrag(translationY: -18, fine: false) // Remaining events after Escape stay ignored.
            XCTAssertNil(preview.configuration)
            drag.finish(); flush()
            XCTAssertEqual(owner.document.detection, original)
            XCTAssertNil(preview.configuration)
            XCTAssertEqual(rendered?.0, original)
        }
    }
}
