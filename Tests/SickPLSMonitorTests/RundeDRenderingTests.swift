import XCTest
import AppKit
import SwiftUI
import PlanariumDomain
@testable import PlanariumApplication
import PlanariumPresets
import SickPLSCommissioningControl
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class RundeDRenderingTests: XCTestCase {
    func testDialogsAndPitchInspectorWideNarrowOffline() throws {
        _ = NSApplication.shared
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let strip = owner.document.channels[0].id
        let layers = (0..<3).map { index in
            SpatialDocumentLayer(id: UUID(), name: ["Harmony", "Melody", "Bass"][index], color: index == 1 ? .orange : .blue,
                isVisible: true, isActive: index != 2, isLocked: index == 2, isSoloed: false, cells: [],
                routings: [.init(target: index == 1 ? .midiNote(channel: 1) : .audioUnitNote(channel: 0, stripID: strip),
                    program: .chord(notes: [60, 64, 67], velocity: 100, transition: index == 0 ? .holdUntilNext : .legato))], cellOverrides: [:])
        }
        try owner.edit { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id) }
        XCTAssertTrue(owner.canvas.selectLayers(Set(layers.map(\.id)), active: layers[0].id))
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: layout.suiteName))
        var preferences = WorkspacePreferences()
        preferences.collapsedLayerGroups[owner.document.revision.session.uuidString] = ["au:" + strip.uuidString]
        WorkspacePreferenceStore.save(preferences, to: defaults)
        for width in [300, 420] {
            let inspectorView = AnyView(SpatialLayerInspectorView(editor: owner.canvas,
                audioUnits: layout.view.audioUnits, midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil))
            let views: [(String, AnyView)] = [
                ("channel-presets", AnyView(ChannelPresetSheet(instrument: owner, channelID: owner.document.channels[0].id, presetStore: PresetFileStore(directory: directory.appendingPathComponent("Presets"))))),
                ("import-layers", AnyView(ImportPresetLayersSheet(instrument: owner, source: owner.document))),
                ("multi-pitch-inspector", inspectorView), ("multi-pitch-inspector-perform", inspectorView),
                ("multi-pitch-inspector-collapsed", AnyView(LayerInspectorView(editor: owner.canvas,
                    audioUnits: layout.view.audioUnits, midiOutput: fixture.root.midi, spatialInstrument: owner,
                    evaluationCounter: nil, workspaceDefaults: defaults))),
                ("multi-pitch-inspector-labels", inspectorView), ("multi-pitch-inspector-perform-labels", inspectorView)
            ]
            for (name, view) in views {
                owner.canvas.setPerformanceLocked(name.contains("perform"))
                let height = name == "channel-presets" ? 300 : name == "import-layers" ? 470 : 900
                let host = NSHostingView(rootView: view.environment(\.fieldToolbarLabels, name.hasSuffix("labels")).environment(\.colorScheme, .dark).preferredColorScheme(.dark).background(StageTheme.workspace))
                host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
                let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.isReleasedWhenClosed = false; window.contentView = host
                host.frame = .init(x: 0, y: 0, width: width, height: height)
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name)-\(width).png"))
                XCTAssertGreaterThan(host.fittingSize.width, 0)
                window.close()
            }
        }
    }
}

extension RundeDRenderingTests {
    func testChannelPresetMissingInsertKeepsRemainingChannelAndNamesUnavailableSlot() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults() }
        let plugin = InstrumentPlugin(identity: .init(componentType: 0x61756678, componentSubType: 123, componentManufacturer: 456), state: Data([7, 8]))
        let insert = InstrumentInsert(id: UUID(), plugin: plugin, bypassed: true)
        var channel = owner.document.channels[0]; channel.inserts = [insert]; channel.levelDecibels = -8
        XCTAssertTrue(try owner.loadChannelPreset(.init(name: "Unavailable", channel: channel), into: channel.id))
        let strip = ChannelStripView(spatialInstrument: owner, audioUnits: layout.view.audioUnits, host: fixture.root.audio,
            midiOutput: fixture.root.midi, audioDevices: layout.view.audioDevices)
        XCTAssertTrue(strip.slots[0].title.hasPrefix("Unavailable insert"))
        XCTAssertEqual(owner.document.channels[0].inserts, [insert])
        XCTAssertEqual(owner.document.channels[0].levelDecibels, -8)
    }
}

extension RundeDRenderingTests {
    func testOwner1005EveryCaptionFitsInFullWorkspaceAtThreeWidthsModesAndLabelStates() throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        CaptionLayoutProbe.enabled = true
        defer { CaptionLayoutProbe.enabled = false }
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        layout.workspace.setVisible(.setup, false)
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var allTitles = Set<String>()
        for width in [1280,1728,2000] {
            for labels in [false,true] {
                layout.workspace.setButtonLabels(labels)
                for perform in [false,true] {
                    if (layout.workspace.mode == .perform) != perform { layout.workspace.togglePerformance(canvas: fixture.root.document.canvas) }
                    let host = NSHostingView(rootView: layout.view.environment(\.colorScheme, .dark).preferredColorScheme(.dark))
                    host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
                    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: .darkAqua)
                    window.isReleasedWhenClosed = false; window.contentView = host
                    host.frame = .init(x: 0, y: 0, width: width, height: 1100)
                    window.orderFrontRegardless(); host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    func elements(_ value: Any, depth: Int = 0) -> [NSObject] {
                        guard depth < 30, let object = value as? NSObject else { return [] }
                        let children = (object as? NSAccessibilityProtocol)?.accessibilityChildren()
                            ?? (object.responds(to: NSSelectorFromString("accessibilityChildren")) ? object.value(forKey: "accessibilityChildren") as? [Any] : nil) ?? []
                        return [object] + children.flatMap { elements($0, depth: depth + 1) }
                    }
                    func label(_ object: NSObject) -> String? {
                        (object as? NSAccessibilityProtocol)?.accessibilityLabel()
                            ?? (object.responds(to: NSSelectorFromString("accessibilityLabel")) ? object.value(forKey: "accessibilityLabel") as? String : nil)
                    }
                    if let disclosure = elements(window).first(where: { label($0) == "Expand detection" }) {
                        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("accessibilityPerformPress"), to: disclosure, from: nil))
                        RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    }
                    var toolbarFrames: [String: CGRect] = [:]
                    func visit(_ view: NSView) {
                        guard !view.isHidden else { return }
                        if let id = view.identifier?.rawValue, id.hasPrefix("caption.frame.") {
                            let title = String(id.dropFirst("caption.frame.".count))
                            let rect = view.convert(view.bounds, to: host)
                            if rect.intersects(host.bounds), rect.width > 0 {
                                allTitles.insert(title)
                                if title == "Hand (H)" || title == "Cell size" { toolbarFrames[title] = rect }
                                if let caption = view.toolTip {
                                    let intrinsic = (caption as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9)])
                                    XCTAssertGreaterThanOrEqual(rect.width + 1, intrinsic.width, "\(width) \(labels) \(perform): \(title) width")
                                    XCTAssertGreaterThanOrEqual(rect.height, 30, "\(width) \(labels) \(perform): \(title) height")
                                    var parent = view.superview
                                    while let ancestor = parent, ancestor !== host {
                                        if ancestor is NSButton {
                                            let bounds = ancestor.convert(ancestor.bounds, to: host).insetBy(dx: -1, dy: -1)
                                            XCTAssertTrue(bounds.contains(rect), "Native bezel clips \(title): \(rect) outside \(bounds)")
                                        }
                                        parent = ancestor.superview
                                    }
                                }
                                XCTAssertGreaterThanOrEqual(rect.minX, -1, "\(title) outside window")
                                XCTAssertLessThanOrEqual(rect.maxX, host.bounds.maxX + 1, "\(title) outside window")
                            }
                        }
                        for child in view.subviews { visit(child) }
                    }
                    visit(host)
                    if let hand = toolbarFrames["Hand (H)"], let size = toolbarFrames["Cell size"] {
                        XCTAssertLessThanOrEqual(hand.maxX, size.minX, "Tool captions must not overlap cell-size controls")
                    }
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("owner1005-\(width)-labels-\(labels)-perform-\(perform).png"))
                    window.close()
                }
            }
        }
        for title in ["Save preset (⌘S)", "Refresh preset list", "Capture room", "Fit to room", "Grouping", "Add channel", "Merge zones", "Show raw scan", "Scanner flag bits", "Mute"] {
            XCTAssertTrue(allTitles.contains(title), "Caption was not inspected: \(title)")
        }
        print("RUNDE-D owner1005: inspected \(allTitles.count) distinct caption actions across 12 full workspace states")
    }

    func testOwner1005RealMainMenuContainsOneViewAndPreservesNativeCommands() throws {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let menu = NSMenu(title: "Main")
        for title in ["File", "Edit", "View", "Preset", "Tempo", "View", "Window", "Help"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title); menu.addItem(item)
        }
        let views = menu.items.filter { $0.title == "View" }
        views[0].submenu?.addItem(withTitle: "Show Toolbar", action: nil, keyEquivalent: "")
        views[1].submenu?.addItem(withTitle: "Button labels", action: nil, keyEquivalent: "l")
        NSApp.mainMenu = menu
        ViewMenuRepair.install(); ViewMenuRepair.install()
        let result = try XCTUnwrap(NSApp.mainMenu)
        XCTAssertEqual(result.items.filter { $0.title == "View" }.count, 1)
        XCTAssertEqual(result.items.first { $0.title == "View" }?.submenu?.items.map(\.title), ["Show Toolbar", "Button labels"])
    }
}

extension RundeDRenderingTests {
    func testGroupHeaderSelectsEightWithoutRowRebuildAndCollapsePersistsOutsideDocument() throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: layout.suiteName))
        owner.canvas.updateWorkspace { workspace in
            for _ in 0..<7 { _ = workspace.addLayer() }
        }
        let name = "No output"
        let probe = ViewEvaluationProbe(); ViewEvaluationProbe.current = probe
        defer { ViewEvaluationProbe.current = nil }
        let host = NSHostingView(rootView: LayerInspectorView(editor: owner.canvas, audioUnits: layout.view.audioUnits,
            midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil, workspaceDefaults: defaults))
        let window = NSWindow(contentRect: .init(x: -10000,y: -10000,width: 420,height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.frame = .init(x: 0,y: 0,width: 420,height: 900); window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func elements(_ value: Any, depth: Int = 0) -> [NSObject] {
            guard depth < 30, let object = value as? NSObject else { return [] }
            let children = (object as? NSAccessibilityProtocol)?.accessibilityChildren()
                ?? (object.responds(to: NSSelectorFromString("accessibilityChildren")) ? object.value(forKey: "accessibilityChildren") as? [Any] : nil) ?? []
            return [object] + children.flatMap { elements($0, depth: depth + 1) }
        }
        func target(_ label: String) throws -> NSObject {
            try XCTUnwrap(elements(window).first { object in
                ((object as? NSAccessibilityProtocol)?.accessibilityLabel()
                    ?? (object.responds(to: NSSelectorFromString("accessibilityLabel")) ? object.value(forKey: "accessibilityLabel") as? String : nil)) == label
            })
        }
        func press(_ label: String) throws {
            let element = try target(label)
            XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("accessibilityPerformPress"), to: element, from: nil))
        }
        let document = owner.document
        let groupButton = try target("Select group " + name)
        probe.reset()
        let start = Date()
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("accessibilityPerformPress"), to: groupButton, from: nil))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
        print("RUNDE-D group click eight layers: \(Date().timeIntervalSince(start) * 1000) ms")
        XCTAssertEqual(owner.canvas.selection.layerIDs.count, 8)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(probe.counts["inspector.rowInput", default: 0], 0)
        XCTAssertEqual(probe.counts["inspector.layerList", default: 0], 0)
        XCTAssertEqual(owner.document, document)
        try press("Collapse group " + name)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let key = document.revision.session.uuidString
        XCTAssertEqual(WorkspacePreferenceStore.load(from: defaults).collapsedLayerGroups[key], ["none"])
        XCTAssertEqual(owner.document, document)
        layout.workspace.setButtonLabels(false)
        XCTAssertEqual(WorkspacePreferenceStore.load(from: defaults).collapsedLayerGroups[key], ["none"], "Other workspace preferences must retain collapse state")
        try press("Collapse group " + name)
        XCTAssertEqual(WorkspacePreferenceStore.load(from: defaults).collapsedLayerGroups[key], [])
    }
}

extension RundeDRenderingTests {
    func testOwner1005MixerRailsAndSlotsAlignAtTwoWidthsOneThreeEightChannelsBothModes() throws {
        _ = NSApplication.shared
        InspectorLayoutProbe.enabled = true
        defer { InspectorLayoutProbe.enabled = false }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for count in [1,3,8] {
            let fixture = try MonitorRootFixture(), owner = fixture.root.document
            let layout = try LayoutWorkspaceFixture(fixture: fixture)
            defer { layout.cleanDefaults(); fixture.root.terminate {} }
            for _ in 1..<count { _ = try owner.addChannel() }
            // Missing identities deliberately exercise long fallback slot titles;
            // no plugin is instantiated and no audio graph is started.
            try owner.edit { document in
                for index in document.channels.indices {
                    document.channels[index].instrument = .init(identity: .init(componentType: 0x61756d75, componentSubType: 998, componentManufacturer: 999))
                }
            }
            for width in [1280,2000] {
                for perform in [false,true] {
                    owner.canvas.setPerformanceLocked(perform)
                    let allocation = WorkspaceLayout.forAvailableWidth(Double(width), channelCount: count)[.channelStrip].width
                    let host = NSHostingView(rootView: MixerView(instrument: owner, audioUnits: layout.view.audioUnits,
                        host: fixture.root.audio, midi: fixture.root.midi, devices: layout.view.audioDevices,
                        compact: perform, display: fixture.root.display).background(StageTheme.workspace).environment(\.fieldToolbarLabels, true).environment(\.colorScheme, .dark).preferredColorScheme(.dark))
                    host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
                    let window = NSWindow(contentRect: .init(x: -10000,y: -10000,width: allocation,height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: .darkAqua)
                    window.isReleasedWhenClosed = false; window.contentView = host
                    host.frame = .init(x: 0,y: 0,width: allocation,height: 900)
                    window.orderFrontRegardless(); host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    var rails: [String: [CGRect]] = [:]
                    var slots: [CGRect] = []
                    func visit(_ view: NSView) {
                        guard !view.isHidden else { return }
                        if let id = view.identifier?.rawValue {
                            let rect = view.convert(view.bounds, to: host)
                            if id.hasPrefix("inspector.frame.mixer.rail.") { rails[id,default:[]].append(rect) }
                            if id.hasPrefix("inspector.frame.mixer.slot.") { slots.append(rect) }
                        }
                        for child in view.subviews { visit(child) }
                    }
                    visit(host)
                    for (name,frames) in rails {
                        XCTAssertEqual(frames.count, count + 1, "\(name): missing strip")
                        let first = try XCTUnwrap(frames.first)
                        for rect in frames {
                            XCTAssertEqual(rect.minY, first.minY, accuracy: 1, "\(width) \(count) \(perform): \(name)")
                            XCTAssertEqual(rect.height, first.height, accuracy: 1, name)
                            if name.hasSuffix("actions") { XCTAssertGreaterThanOrEqual(rect.height, 44, "Fader actions need eight points of breathing room") }
                            if name.hasSuffix("fader") { XCTAssertLessThanOrEqual(rect.height, MixerStripGrid.faderTravel + 1, "Owner 20.10.2026: fader travel at most as before"); XCTAssertGreaterThanOrEqual(rect.height, 119) }
                        }
                    }
                    XCTAssertEqual(rails.count, 5)
                    XCTAssertGreaterThanOrEqual(slots.count, count)
                    for slot in slots {
                        XCTAssertLessThanOrEqual(slot.width, 62.5, "Slot must stay inside 72pt strip with padding")
                        XCTAssertGreaterThan(slot.width, 55)
                    }
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("mixer-rails-\(width)-\(count)-perform-\(perform).png"))
                    window.close()
                }
            }
        }
    }
}

@MainActor final class RundeFRenderingTests: XCTestCase {
    private final class KeyboardEventHost<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    private func pump(_ host: NSView) {
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.08)); host.layoutSubtreeIfNeeded()
    }
    private func capture(_ host: NSView, _ name: String) throws {
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
    func testLayerButtonsStayInsideAndOrderButtonsAdjacent() throws {
        _ = NSApplication.shared
        InspectorLayoutProbe.enabled = true
        defer { InspectorLayoutProbe.enabled = false }
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults() }
        owner.canvas.updateWorkspace { workspace in
            for index in 1...4 { _ = workspace.addScene(name: "Scene \(index)") }
        }
        for name in ["Harmony", String(repeating: "Very long layer name ", count: 8)] {
            owner.canvas.updateWorkspace { workspace in
                if name != "Harmony" {
                    for index in 5...16 { _ = workspace.addScene(name: "Scene \(index)") }
                }
                workspace.updateSelectedLayer { $0.name = name }
                if workspace.layers.count < 2 { _ = workspace.addLayer() }
            }
            for labels in [false, true] {
                for width in [300, 520] {
                    let host = NSHostingView(rootView: LayerInspectorView(editor: owner.canvas, audioUnits: layout.view.audioUnits,
                        midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
                        .environment(\.fieldToolbarLabels, labels))
                    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    host.frame = .init(x: 0, y: 0, width: width, height: 1100); pump(host)
                    var frames: [String: CGRect] = [:]
                    func visit(_ view: NSView) {
                        if let id = view.identifier?.rawValue, id.hasPrefix("inspector.frame.") {
                            frames[id] = view.convert(view.bounds, to: host)
                        }
                        for child in view.subviews { visit(child) }
                    }
                    visit(host)
                    let controls = frames.filter { $0.key.hasPrefix("inspector.frame.layer.") && !$0.key.contains("colorStrip") && !$0.key.contains("colorPoint") }
                    XCTAssertEqual(controls.count, owner.canvas.workspace.layers.count * 4)
                    for (id, rect) in controls {
                        XCTAssertGreaterThanOrEqual(rect.minX, 0, id)
                        XCTAssertLessThanOrEqual(rect.maxX, CGFloat(width), "\(id) \(labels) \(rect)")
                    }
                    let up = try XCTUnwrap(frames["inspector.frame.order.up"])
                    let down = try XCTUnwrap(frames["inspector.frame.order.down"])
                    XCTAssertLessThanOrEqual(down.minX - up.maxX, 2.01)
                    XCTAssertGreaterThanOrEqual(down.minX - up.maxX, 0)
                    XCTAssertLessThanOrEqual(up.width, 40)
                    XCTAssertLessThanOrEqual(down.width, 40)
                    if labels { try capture(host, "runde-f-inspector-\(width)-\(name == "Harmony" ? "short" : "long").png") }
                }
            }
        }
    }
    @discardableResult private func renderKeyboard<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, auditLayout: Bool = false) throws -> [String: CGRect] {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).preferredColorScheme(.dark)
            .foregroundColor(.white).background(StageTheme.workspace))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = .init(x: 0, y: 0, width: width, height: height); window.orderFrontRegardless(); pump(host)
        try capture(host, name)
        if auditLayout {
            let failures = LayoutGuardian.violations(LayoutGuardian.elements(in: host,window: window),view: name)
            XCTAssertTrue(failures.isEmpty,failures.joined(separator: "\n"))
        }
        var frames: [String: CGRect] = [:]
        func visit(_ view: NSView) {
            if let id = view.identifier?.rawValue { frames[id] = view.convert(view.bounds, to: host) }
            view.subviews.forEach(visit)
        }
        visit(host)
        return frames
    }
    func testKeyboardZoomAndChordEditorEvidence() throws {
        _ = NSApplication.shared
        for zoom in [0.6, 1.0, 2.0] {
            let keyboard = InstrumentKeyboard(notes: Array(0..<128), marks: [60: [.init(color: .orange, velocity: 100, held: false)], 64: [.init(color: .purple, velocity: 70, held: true)]])
            try renderKeyboard(keyboard, width: 1350 * zoom, height: 88, name: "runde-f-keyboard-\(zoom).png")
        }
        var chord = ChordEffect(); chord.mode = .single
        for width in [360, 580] {
            try renderKeyboard(ChordEffectEditor(effect: .constant(chord)), width: CGFloat(width), height: 650, name: "runde-f-chord-\(width).png")
            try renderKeyboard(PianoKeyboardView(model: .constant(.init(selectedNotes: [60,64,67])), velocity: .constant(100), transition: .constant(.legato), supportsNoteTransition: true),
                width: CGFloat(width), height: 220, name: "runde-f-piano-\(width).png")
        }
    }
}

extension RundeFRenderingTests {
    func testDetectionRightEmptyHalfTogglesAndToolbarModesRender() throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        InspectorLayoutProbe.enabled = true
        defer { InspectorLayoutProbe.enabled = false }
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let suite = "runde-f-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for area in [false, true] {
            defaults.set(area, forKey: "clickSelectsArea")
            for width in [420, 1000] {
                let host = NSHostingView(rootView: CartesianScanFieldView(editor: owner.canvas, profile: nil,
                    activeCellDisplay: SpatialActiveCellDisplayModel(), spatialInstrument: owner, simulationBadge: AnyView(Text("Offline"))).defaultAppStorage(defaults).environment(\.colorScheme, .dark).preferredColorScheme(.dark).foregroundColor(.white))
                let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
                host.appearance = NSAppearance(named: .darkAqua); window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.frame = .init(x: 0, y: 0, width: width, height: 800); window.makeKeyAndOrderFront(nil); pump(host)
                XCTAssertEqual(owner.canvas.presentation.clickSelectsArea, area)
                let selection = owner.canvas.selectedCells
                func elements(_ value: Any, depth: Int = 0) -> [NSObject] {
                    guard depth < 40, let object = value as? NSObject else { return [] }
                    let children = (object as? NSAccessibilityProtocol)?.accessibilityChildren()
                        ?? (object.responds(to: NSSelectorFromString("accessibilityChildren")) ? object.value(forKey: "accessibilityChildren") as? [Any] : nil) ?? []
                    return [object] + children.flatMap { elements($0, depth: depth + 1) }
                }
                let modeButton = try XCTUnwrap(elements(window).first { object in
                    let label = (object as? NSAccessibilityProtocol)?.accessibilityLabel()
                        ?? (object.responds(to: NSSelectorFromString("accessibilityLabel")) ? object.value(forKey: "accessibilityLabel") as? String : nil)
                    return label == "Click selects: " + (area ? "Area" : "Cell")
                })
                XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("accessibilityPerformPress"), to: modeButton, from: nil)); pump(host)
                XCTAssertEqual(defaults.bool(forKey: "clickSelectsArea"), !area)
                XCTAssertEqual(owner.canvas.selectedCells, selection)
                XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("accessibilityPerformPress"), to: modeButton, from: nil)); pump(host)
                XCTAssertEqual(owner.canvas.presentation.clickSelectsArea, area)
                try capture(host, "runde-f-toolbar-\(area)-\(width).png")
                func marker(_ view: NSView) -> NSView? {
                    if view.identifier?.rawValue == "inspector.frame.detection.disclosure" { return view }
                    return view.subviews.compactMap(marker).first
                }
                let row = try XCTUnwrap(marker(host))
                let p = row.convert(.init(x: row.bounds.width - 6, y: row.bounds.midY), to: nil)
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
                let before = row.convert(row.bounds, to: host)
                NSApp.postEvent(up, atStart: true); window.sendEvent(down); window.sendEvent(up)
                _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
                pump(host)
                // Expanding the modules moves the field down; the label remains full width.
                let after = row.convert(row.bounds, to: host)
                XCTAssertEqual(after.width, before.width, accuracy: 0.1)
                func hasExpandedMarker(_ view: NSView) -> Bool {
                    view.identifier?.rawValue == "inspector.frame.detection.module.Room" || view.subviews.contains { hasExpandedMarker($0) }
                }
                try capture(host, "runde-f-detection-open-\(area)-\(width).png")
                XCTAssertTrue(hasExpandedMarker(host), "Click in empty right half must expand detection; row \(row.bounds), click \(p)")
            }
        }
    }
}

extension RundeFRenderingTests {
    func testNativePianoBlackOverlapAndWhiteBelowUseVisibleShapes() throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        InspectorLayoutProbe.enabled = true
        defer { InspectorLayoutProbe.enabled = false }
        var model = PianoKeyboardModel(octave: 4)
        let binding = Binding(get: { model }, set: { model = $0 })
        let host = KeyboardEventHost(rootView: PianoKeyboardView(model: binding, velocity: .constant(100), transition: .constant(.legato), supportsNoteTransition: false, showsVelocity: false))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 420, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = .init(x: 0, y: 0, width: 420, height: 180); window.makeKeyAndOrderFront(nil); pump(host)
        func marker(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "inspector.frame.keyboard.keys" { return view }
            return view.subviews.compactMap(marker).first
        }
        let keys = try XCTUnwrap(marker(host))
        let layout = PianoKeyboardLayout.layout(for: model.visibleNotes, width: keys.bounds.width, height: 52)
        let black = try XCTUnwrap(layout.first { $0.note == 61 })
        for y in [CGFloat(10), CGFloat(48)] {
            let screenY = keys.isFlipped ? y : keys.bounds.height - y
            let point = keys.convert(.init(x: black.frame.midX, y: screenY), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { NSApp.postEvent(up, atStart: true) }
            NSApp.sendEvent(down); pump(host)
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
            pump(host)
            XCTAssertEqual(model.selectedNotes, y == 10 ? [61] : [60,61])
        }

    }
}

extension RundeFRenderingTests {
    func testHarmonyThirtyEveryGroupedRowShowsColorStripAndPointAndPaletteIsThreeByEight() throws {
        _ = NSApplication.shared
        InspectorLayoutProbe.enabled = true
        defer { InspectorLayoutProbe.enabled = false }
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults() }
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Harmony 30 Mode Wheel"))
        try owner.applyPresetDocument(try PresetDocumentReader.read(data).get().replacing(owner.document))
        let original = owner.document
        for labels in [false, true] {
            for width in [300, 520] {
                let host = NSHostingView(rootView: LayerInspectorView(editor: owner.canvas, audioUnits: layout.view.audioUnits,
                    midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
                    .environment(\.fieldToolbarLabels, labels).preferredColorScheme(.dark))
                let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.frame = .init(x: 0, y: 0, width: width, height: 1400); window.orderFrontRegardless(); pump(host)
                var stripes: [CGRect] = [], points: [CGRect] = []
                func visit(_ view: NSView) {
                    if let id = view.identifier?.rawValue {
                        if id.hasPrefix("inspector.frame.layer.colorStrip.") { stripes.append(view.convert(view.bounds, to: host)) }
                        if id.hasPrefix("inspector.frame.layer.colorPoint.") { points.append(view.convert(view.bounds, to: host)) }
                    }
                    view.subviews.forEach(visit)
                }
                visit(host)
                print("RUNDE-G labels=\(labels) width=\(width) pointMinX=\(points.map(\.minX).min() ?? -999) pointMinWidth=\(points.map(\.width).min() ?? -999)")
                XCTAssertEqual(stripes.count, owner.canvas.workspace.layers.count)
                XCTAssertEqual(points.count, stripes.count)
                for rect in stripes + points {
                    XCTAssertGreaterThanOrEqual(rect.minX, 0)
                    XCTAssertLessThanOrEqual(rect.maxX, CGFloat(width))
                    XCTAssertGreaterThan(rect.height, 0)
                }
                for stripe in stripes { XCTAssertEqual(stripe.width, 4, accuracy: 0.01) }
                for point in points { XCTAssertGreaterThanOrEqual(point.width, 16) }
                try capture(host, "runde-g-harmony30-\(labels)-\(width).png")
            }
        }
        XCTAssertEqual(owner.document, original, "Presentation must retain every preset color")
        let frames = try renderKeyboard(LayerColorPalette(selected: .blue, select: { _ in }), width: 244, height: 150, name: "runde-g-palette.png")
        let swatches = frames.filter { $0.key.hasPrefix("inspector.frame.palette.") }.map(\.value)
        XCTAssertEqual(swatches.count, 24)
        XCTAssertEqual(Set(swatches.map { Int($0.midX.rounded()) }).count, 8)
        XCTAssertEqual(Set(swatches.map { Int($0.midY.rounded()) }).count, 3)
    }
}

extension RundeFRenderingTests {
    func testColorChoiceKeepsItsLayerAddressAfterDeletionAndUsesOneUndo() throws {
        let fixture = try MonitorRootFixture(), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults() }
        let first = owner.canvas.workspace.selectedLayerID
        owner.canvas.updateWorkspace { _ = $0.addLayer() }
        let second = owner.canvas.workspace.selectedLayerID
        let view = LayerInspectorView(editor: owner.canvas, audioUnits: layout.view.audioUnits,
            midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
        owner.canvas.updateWorkspace { $0.selectLayer(first); $0.deleteSelectedLayer() }
        let before = owner.document
        view.selectLayerAndApply(first) { $0.setSelectedLayerColor(.purple) }
        XCTAssertEqual(owner.document, before)
        XCTAssertEqual(owner.canvas.workspace.selectedLayerID, second)
        let depth = owner.historyDepth
        view.selectLayerAndApply(second) { $0.setSelectedLayerColor(SpatialLayerColor.palette[17]) }
        XCTAssertEqual(owner.document.spatial.layers.first?.color, SpatialLayerColor.palette[17])
        XCTAssertEqual(owner.historyDepth, depth + 1)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.spatial, before.spatial)
        owner.canvas.setPerformanceLocked(true)
        let locked = owner.document
        view.selectLayerAndApply(second) { $0.setSelectedLayerColor(.purple) }
        XCTAssertEqual(owner.document, locked)
    }
}


extension RundeFRenderingTests {
    func testMIDIFXRoleContrastAndChannelSlotsWideNarrow() throws {
        _ = NSApplication.shared
        func luminance(_ rgb: [Double]) -> Double {
            let values = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return zip(values, [0.2126,0.7152,0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let petrol = try XCTUnwrap(NSColor(HelmutChrome.midiFX).usingColorSpace(.sRGB))
        let rgb = [Double(petrol.redComponent),Double(petrol.greenComponent),Double(petrol.blueComponent)]
        XCTAssertGreaterThan((luminance(rgb)+0.05)/(luminance([0.035,0.045,0.05])+0.05), 4.5)
        let dimmed = zip(rgb,[0.43,0.43,0.44]).map { $0 * 0.3 + $1 * 0.7 }
        XCTAssertGreaterThan(1.05/(luminance(dimmed)+0.05), 4.5)
        XCTAssertNotEqual(NSColor(HelmutChrome.midiFX), NSColor(HelmutChrome.purple))
        XCTAssertNotEqual(NSColor(HelmutChrome.midiFX), NSColor(HelmutChrome.blue))
        for width in [90,180] { for bypassed in [false,true] {
            var chord = InstrumentMIDIEffect(); chord.bypassed = bypassed
            var arp = InstrumentMIDIEffect(arpeggiator: .init()); arp.bypassed = bypassed
            let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture)
            defer { layout.cleanDefaults(); fixture.root.terminate {} }
            let instrument = AudioUnitInstrumentCandidate(identity: try XCTUnwrap(.init(componentSubType: 1, componentManufacturer: 1)), name: "AU Instrument", manufacturerName: "Offline fixture", isSandboxSafe: true)
            let effect = try AudioUnitIdentity.build(componentType: AudioUnitIdentity.effectComponentType, componentSubType: 2, componentManufacturer: 1)
            let view = HelmutStripSurface(master: .constant(0.7), selectedEntry: .constant(.audioOutput),
                audioIsRunning: false, audioSummary: "stopped", midiSummary: "off",
                effectSlots: [.init(id: 0, title: "AU Insert", isOn: true, canToggle: true, target: .audioUnit(effect))],
                audioUnitEffects: [], audioUnitInstruments: [instrument], selectedAudioUnitInstrument: instrument,
                isMuted: false, isSoloed: false, toggleMute: {}, toggleSolo: {},
                instrumentIsOn: true, instrumentPreparation: .empty, instrumentCanToggle: true,
                toggleInstrument: {}, selectAudioUnitInstrument: { _ in }, openAudioUnitInstrument: { _ in },
                assignEffect: { _,_ in }, toggleEffect: { _ in }, openEffect: { _ in },
                channelName: .constant("Roles"), channelColor: .constant(.blue), pan: 0, setPan: { _ in },
                midiDestinations: nil, selectedMIDIDestinationID: nil, selectMIDIDestination: { _ in },
                refreshMIDIDestinations: {}, midiNotice: nil, audioDevices: layout.view.audioDevices,
                midiEffectsView: AnyView(MIDIEffectSlotsView(slots: [chord,arp], add: {}, toggle: { _ in }, open: { _ in }, remove: { _ in }, move: { _,_ in })))
            try renderKeyboard(view, width: CGFloat(width), height: 900, name: "runde-h-slots-\(width)-bypass-\(bypassed).png")
        }}
    }
}

/// Reusable offline guard. Scroll documents keep their own container; nested
/// controls and explicitly marked compound controls are not compared as siblings.
@MainActor struct LayoutGuardian {
    struct Element {
        var name: String
        var frame: CGRect
        var container: CGRect
        var control: Bool
        var hitFrame: CGRect? = nil
        var group = ""
        var font: Double? = nil
        var foreground: [Double]? = nil
        var background: [Double]? = nil
    }
    static func contrast(_ foreground: [Double], _ background: [Double]) -> Double {
        func luminance(_ values: [Double]) -> Double {
            zip(values.prefix(3), [0.2126,0.7152,0.0722]).reduce(0) { result, pair in
                let value = pair.0 <= 0.04045 ? pair.0 / 12.92 : pow((pair.0 + 0.055) / 1.055, 2.4)
                return result + value * pair.1
            }
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a,b)+0.05)/(min(a,b)+0.05)
    }
    static func violations(_ elements: [Element], view: String) -> [String] {
        var failures: [String] = []
        for element in elements {
            let frame = element.frame
            if !element.container.insetBy(dx: -0.01, dy: -0.01).contains(frame) {
                failures.append("\(view) · \(element.name) · overflow \(frame) outside \(element.container)")
            }
            let hit = element.hitFrame ?? frame
            if element.control && (hit.width < 19.99 || hit.height < 19.99) {
                failures.append("\(view) · \(element.name) · hit area \(hit.width)×\(hit.height), minimum 20×20")
            }
            if let font = element.font, font < 10 {
                failures.append("\(view) · \(element.name) · font \(font) pt, minimum 10")
            }
            if let foreground = element.foreground, let background = element.background {
                let ratio = contrast(foreground, background)
                if ratio < 4.5 { failures.append("\(view) · \(element.name) · contrast \(ratio):1, minimum 4.5") }
            }
        }
        let controls = elements.filter(\.control)
        for i in controls.indices { for j in controls.indices where j > i {
            let a = controls[i], b = controls[j]
            if (a.frame == b.container && a.frame.contains(b.frame)) || (b.frame == a.container && b.frame.contains(a.frame)) { continue } // proven native parent/child only
            let intersection = a.frame.intersection(b.frame)
            if !intersection.isNull && intersection.width > 0.75 && intersection.height > 0.75 {
                failures.append("\(view) · \(a.name) / \(b.name) · overlap \(intersection)")
                continue
            }
            if !a.group.isEmpty && a.group == b.group { continue }
            let verticalOverlap = min(a.frame.maxY,b.frame.maxY)-max(a.frame.minY,b.frame.minY)
            let horizontalOverlap = min(a.frame.maxX,b.frame.maxX)-max(a.frame.minX,b.frame.minX)
            let dx = max(a.frame.minX,b.frame.minX)-min(a.frame.maxX,b.frame.maxX)
            let dy = max(a.frame.minY,b.frame.minY)-min(a.frame.maxY,b.frame.maxY)
            if verticalOverlap > 1 && dx >= 0 && dx < 3.99 {
                failures.append("\(view) · \(a.name) / \(b.name) · horizontal gap \(dx) pt, minimum 4")
            }
            if horizontalOverlap > 1 && dy >= 0 && dy < 3.99 {
                failures.append("\(view) · \(a.name) / \(b.name) · vertical gap \(dy) pt, minimum 4")
            }
        }}
        return failures
    }
    static func children(_ object: NSObject) -> [Any] {
        (object as? NSAccessibilityProtocol)?.accessibilityChildren()
            ?? (object.responds(to: NSSelectorFromString("accessibilityChildren")) ? object.value(forKey: "accessibilityChildren") as? [Any] : nil) ?? []
    }
    static func string(_ object: NSObject, _ key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }
    static func frame(_ object: NSObject) -> CGRect {
        if let value = object as? NSAccessibilityProtocol { return value.accessibilityFrame() }
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return .zero }
        return value.rectValue
    }
    static func elements(in host: NSView, window: NSWindow) -> [Element] {
        var result: [Element] = [], groups: [(String,CGRect)] = [], hitRegions: [CGRect] = []
        var seen = Set<ObjectIdentifier>()
        func local(_ frame: CGRect) -> CGRect { host.convert(window.convertFromScreen(frame), from: nil) }
        func walk(_ value: Any, container: CGRect, controlParent: Bool = false, group: String = "", ancestry: String = "", inheritedFont: Double? = nil, inheritedInk: [Double]? = nil, inheritedBackground: [Double]? = nil) {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
            let ax = object as? NSAccessibilityProtocol
            let role = ax?.accessibilityRole()?.rawValue ?? string(object,"accessibilityRole") ?? ""
            let frame = local(Self.frame(object))
            let isControl = ["AXButton","AXPopUpButton","AXTextField","AXCheckBox","AXRadioButton","AXSlider","AXIncrementor","AXComboBox","AXColorWell","AXDisclosureTriangle","AXMenuButton","AXRadioGroup"].contains(role)
            let baseName = ["accessibilityLabel","accessibilityTitle","accessibilityValue","accessibilityIdentifier"].compactMap { string(object,$0) }.first(where: { !$0.isEmpty }) ?? role
            let name = baseName == "AXButton" ? baseName + " " + ancestry + " type=" + String(describing: type(of: object)) : baseName
            let childGroup = role == "AXRadioGroup" || object is NSSegmentedControl ? "native segments \(ObjectIdentifier(object))" : group
            let font = (object as? NSControl)?.font.map { Double($0.pointSize) } ?? inheritedFont
            func rgb(_ color: NSColor) -> [Double]? {
                guard let value = color.usingColorSpace(.sRGB) else { return nil }
                return [Double(value.redComponent),Double(value.greenComponent),Double(value.blueComponent)]
            }
            var ink = inheritedInk, background = inheritedBackground
            if let button = object as? NSButton, !button.title.isEmpty {
                let titleInk = button.attributedTitle.length > 0 ? button.attributedTitle.attribute(.foregroundColor,at: 0,effectiveRange: nil) as? NSColor : nil
                ink = rgb(titleInk ?? (button.isEnabled ? NSColor.controlTextColor : NSColor.disabledControlTextColor))
                background = rgb(button.bezelColor ?? NSColor.controlColor)
            } else if object is NSSegmentedControl {
                ink = rgb(NSColor.controlTextColor); background = rgb(NSColor.controlBackgroundColor)
            }
            let usable = frame.width > 0.5 && frame.height > 0.5
            var childContainer = container
            if let clip = object as? NSClipView, let document = clip.documentView {
                childContainer = document.convert(document.bounds, to: host)
            }
            if usable && (isControl || role == "AXStaticText") && frame.intersects(host.bounds) {
                result.append(.init(name: name, frame: frame, container: childContainer,
                    control: isControl && !controlParent, group: group, font: isControl ? font : nil, foreground: isControl ? ink : nil, background: isControl ? background : nil))
            }
            if isControl && usable { childContainer = frame.intersection(childContainer) }
            let children = Self.children(object)
            children.forEach { walk($0, container: childContainer, controlParent: controlParent || ["AXScrollBar","AXIncrementor","AXTextField","AXComboBox","AXPopUpButton","AXSlider","AXRadioGroup"].contains(role), group: childGroup, ancestry: ancestry + "/" + role, inheritedFont: font, inheritedInk: ink, inheritedBackground: background) }
        }
        walk(window, container: host.bounds)
        walk(host, container: host.bounds)
        func native(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            walk(view, container: host.bounds)
            let frame = view.convert(view.bounds, to: host)
            if let id = view.identifier?.rawValue, id.hasPrefix("inspector.frame.audit.hit.") { hitRegions.append(frame) }
            if let id = view.identifier?.rawValue, id.hasPrefix("inspector.frame.audit.group.") {
                groups.append((id, frame))
            }
            if let id = view.identifier?.rawValue, id.hasPrefix("button.audit."),
               let text = view.toolTip, let data = text.data(using: .utf8),
               let role = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any], frame.intersects(host.bounds) {
                if let group = role["group"] as? String, !group.isEmpty { groups.append((group,frame)) }
                result.append(.init(name: id, frame: frame, container: host.bounds, control: (role["group"] as? String ?? "").isEmpty,
                    group: role["group"] as? String ?? "", font: role["font"] as? Double,
                    foreground: role["foreground"] as? [Double], background: role["background"] as? [Double]))
            }
            if let id = view.identifier?.rawValue, id.hasPrefix("caption.frame."), view.toolTip != nil, frame.intersects(host.bounds) {
                result.append(.init(name: id, frame: frame, container: host.bounds, control: false, font: 10))
            }
            view.subviews.forEach(native)
        }
        native(host)
        for index in result.indices {
            if result[index].control, let hit = hitRegions.first(where: { $0.insetBy(dx: -0.5,dy: -0.5).contains(result[index].frame) }) {
                result[index].frame = hit
            }
            if let group = groups.filter({ $0.1.insetBy(dx: -0.5, dy: -0.5).contains(result[index].frame) }).min(by: { $0.1.width*$0.1.height < $1.1.width*$1.1.height }) {
                result[index].group = group.0
            }
        }
        for index in result.indices where result[index].name.hasPrefix("caption.frame.") {
            let center = CGPoint(x: result[index].frame.midX,y: result[index].frame.midY)
            if let owner = result.filter({ $0.control && $0.frame.contains(center) }).min(by: { $0.frame.width*$0.frame.height < $1.frame.width*$1.frame.height }) {
                result[index].container = owner.frame
            }
        }
        // AX includes native focus rings. Merge the same control's declared
        // surface with its native hit bounds; padded decoration cannot fake a hit.
        var merged = Set<Int>()
        for index in result.indices where result[index].name.hasPrefix("button.audit.") && result[index].control {
            let surface = result[index].frame
            for other in result.indices where other != index && result[other].control && !result[other].name.hasPrefix("button.audit.") {
                let native = result[other].frame
                let sameNamedControl = result[index].name == "button.audit." + result[other].name && surface.insetBy(dx: -0.5,dy: -0.5).contains(native)
                if sameNamedControl || (abs(surface.midX-native.midX) <= 0.75 && abs(surface.midY-native.midY) <= 0.75 && native.width <= surface.width+1.1 && native.height <= surface.height+1.1) {
                    result[index].hitFrame = native.width >= surface.width-0.01 && native.height >= surface.height-0.01 ? surface : native
                    if !result[other].name.isEmpty { result[index].name += " (" + result[other].name + ")" }
                    merged.insert(other)
                }
            }
        }
        result = result.enumerated().filter { !merged.contains($0.offset) }.map(\.element)
        // Native and AX may describe the same button. Retain the role-rich entry.
        var unique: [Element] = []
        for item in result.reversed() {
            if unique.contains(where: { $0.control == item.control && abs($0.frame.minX-item.frame.minX)<0.5 && abs($0.frame.minY-item.frame.minY)<0.5 && abs($0.frame.width-item.frame.width)<0.5 && abs($0.frame.height-item.frame.height)<0.5 }) { continue }
            unique.append(item)
        }
        return unique
    }
}

extension RundeFRenderingTests {
    func testLayoutGuardianDetectsEveryViolationIncludingTooWideButton() {
        let box = CGRect(x: 0,y: 0,width: 100,height: 100)
        let wide = LayoutGuardian.Element(name: "deliberately too wide", frame: .init(x: 5,y: 5,width: 120,height: 24), container: box, control: true)
        XCTAssertTrue(LayoutGuardian.violations([wide], view: "counterprobe").contains { $0.contains("overflow") })
        let tiny = LayoutGuardian.Element(name: "tiny", frame: .init(x: 0,y: 0,width: 12,height: 12), container: box, control: true, font: 8, foreground: [0.8,0.8,0.8], background: [0.7,0.7,0.7])
        let neighbour = LayoutGuardian.Element(name: "neighbour", frame: .init(x: 14,y: 0,width: 24,height: 24), container: box, control: true)
        let violations = LayoutGuardian.violations([tiny,neighbour], view: "counterprobe")
        for token in ["hit area","font","contrast","gap"] { XCTAssertTrue(violations.contains { $0.contains(token) }, token) }
        var overlap = neighbour; overlap.frame.origin.x = 10
        XCTAssertTrue(LayoutGuardian.violations([tiny,overlap], view: "counterprobe").contains { $0.contains("overlap") })
        let covering = LayoutGuardian.Element(name: "covering sibling",frame: .init(x: 0,y: 0,width: 80,height: 80),container: box,control: true)
        XCTAssertTrue(LayoutGuardian.violations([covering,neighbour],view: "counterprobe").contains { $0.contains("overlap") })
    }
    func testLayoutGuardianAllMainViewsWideNarrowLabelsAndLongNames() throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = previousAppearance }
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        InspectorLayoutProbe.enabled = true; CaptionLayoutProbe.enabled = true
        defer { InspectorLayoutProbe.enabled = false; CaptionLayoutProbe.enabled = false }
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture), owner = fixture.root.document
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        owner.canvas.updateWorkspace { workspace in workspace.updateSelectedLayer {
            $0.name = "A deliberately very long layer name with many words and a very long suffix"
            $0.polarCells = [.init(ring: 3, angularIndex: 8)]
            $0.routings = [.init(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .legato))]
        }}
        owner.canvas.updateWorkspace { workspace in
            let first = workspace.selectedLayerID, routing = workspace.selectedLayer.routings
            _ = workspace.addLayer(name: "Another deliberately long grouped layer name")
            workspace.updateSelectedLayer { $0.routings = routing }
            workspace.selectLayer(first)
            for index in 1...3 { _ = workspace.addScene(name: "Long scene name \(index)") }
        }
        let cell = PolarMetricGridCell(ring: 3, angularIndex: 8), size = CGSize(width: 800, height: 800)
        let center = SpatialFieldPlan.center(.init(cell: cell, grid: owner.canvas.workspace.grid))
        let point = MetricCanvasGeometry(size: size, viewport: owner.canvas.viewport).screenPoint(for: .init(xMeters: center.x, yMeters: center.y))
        _ = owner.canvas.selectCell(atScreenPoint: point, canvasSize: size)
        let sourceLayer = owner.document.spatial.layers[0]
        let overrideAddress = try XCTUnwrap(sourceLayer.cells.first)
        let overrideLayer = SpatialDocumentLayer(id: sourceLayer.id, name: sourceLayer.name, color: sourceLayer.color,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: sourceLayer.cells,
            routings: sourceLayer.routings,
            cellOverrides: [overrideAddress: [.init(target: .midiNote(channel: 0), value: .note(number: 64, velocity: 100))]])
        try owner.edit { document in
            document.channels[0].name = "LongName01"
            var layers = document.spatial.layers
            layers[0] = overrideLayer
            document.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: sourceLayer.id)
        }
        layout.view.presets.draftName = "A deliberately long preset name near the maximum name length"
        layout.view.presets.draftSummary = "A long description that must wrap inside its own disclosure container without covering any controls."
        layout.view.presets.commitSaveAs()
        XCTAssertEqual(layout.view.presets.lastLoadedName,layout.view.presets.draftName)
        let password = ScannerPasswordSettingsModel(store: UserDefaultsScannerPasswordStore(defaults: try XCTUnwrap(UserDefaults(suiteName: layout.suiteName))))
        let commissioning = CommissioningControlModel(coordinator: fixture.root.input)
        var chordMulti = ChordEffect(); chordMulti.mode = .multi
        var chordSingle = ChordEffect(); chordSingle.mode = .single
        var failures: [String] = [], coverage: [[String:Any]] = []
        for labels in [false,true] { for wide in [false,true] {
            layout.workspace.setButtonLabels(labels)
            let inspector = SpatialLayerInspectorView(editor: owner.canvas, audioUnits: layout.view.audioUnits,
                midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil)
            var views: [(String,AnyView,CGFloat,CGFloat)] = [
                ("workspace-field-detection-preset-mixer-sum",AnyView(layout.view),wide ? 2000:1280,1200),
                ("layer-inspector",AnyView(inspector),wide ? 520:300,1400),
                ("cell-inspector",AnyView(CellInspectorView(editor: owner.canvas)),wide ? 520:300,1400),
                ("chord",AnyView(ChordEffectEditor(effect: .constant(.init()))),wide ? 640:360,850),
                ("chord-multi",AnyView(ChordEffectEditor(effect: .constant(chordMulti))),wide ? 640:360,850),
                ("chord-single",AnyView(ChordEffectEditor(effect: .constant(chordSingle))),wide ? 640:360,850),
                ("piano",AnyView(PianoKeyboardView(model: .constant(.init(selectedNotes: [60,64,67])),velocity: .constant(100),transition: .constant(.legato),supportsNoteTransition: true)),wide ? 520:300,450),
                ("layer-palette",AnyView(LayerColorPalette(selected: .blue,select: { _ in })),244,160),
                ("arpeggiator",AnyView(ArpeggiatorEffectEditor(effect: .constant(.init()))),wide ? 640:360,850),
                ("mixer-channel-and-sum",AnyView(MixerView(instrument: owner,audioUnits: layout.view.audioUnits,host: fixture.root.audio,midi: fixture.root.midi,devices: layout.view.audioDevices)),wide ? 640:300,1100),
                ("preset-bar",AnyView(PresetBarView(model: layout.view.presets,aboutInitiallyExpanded: true)),wide ? 800:400,600),
                ("field-toolbar-and-detection",AnyView(CartesianScanFieldView(editor: owner.canvas,profile: nil,activeCellDisplay: SpatialActiveCellDisplayModel(),spatialInstrument: owner,simulationBadge: AnyView(Text("Offline")),detectionInitiallyExpanded: true)),wide ? 1000:420,1500),
                ("midi-fx",AnyView(MIDIEffectSlotsView(slots: [.init(),.init(arpeggiator: .init())],add: {},toggle: { _ in },open: { _ in },remove: { _ in },move: { _,_ in }).padding(5).background(HelmutChrome.strip)),wide ? 180:90,250),
                ("midi-fx-hover",AnyView(MIDIEffectSlotsView(slots: [.init(),.init(arpeggiator: .init())],add: {},toggle: { _ in },open: { _ in },remove: { _ in },move: { _,_ in },controlsAreVisibleForPreview: true).padding(5).background(HelmutChrome.strip)),wide ? 180:90,250),
                ("au-slots-hover",AnyView(StudioInsertRow(title: "AU Insert",accessibilityBase: "insert",tint: HelmutChrome.blue,isOn: true,canToggle: true,canOpen: true,toggle: {},open: {},choices: [],controlsAreVisibleForPreview: true).padding(5)),wide ? 180:90,60),
                ("au-slots",AnyView(VStack(spacing: 4) {
                    StudioInsertRow(title: "AU Instrument",accessibilityBase: "instrument",tint: HelmutChrome.purple,isOn: true,canToggle: true,canOpen: true,toggle: {},open: {},choices: [])
                    StudioInsertRow(title: "AU Insert",accessibilityBase: "insert",tint: HelmutChrome.blue,isOn: true,canToggle: true,canOpen: true,toggle: {},open: {},choices: [])
                }.padding(5)),wide ? 180:90,100),
                ("apply-discard",AnyView(HStack(spacing: 4) {
                    AssignmentActionButton(title: "Apply assignment",symbol: "checkmark",tint: .green,action: {})
                    AssignmentActionButton(title: "Discard",symbol: "xmark",tint: .red,action: {})
                }),wide ? 520:300,100)
            ]
            for tab in PlanariumSettingsTab.allCases {
                views.append(("settings-" + tab.rawValue,AnyView(PlanariumSettingsView(workspace: layout.workspace,spatialInstrument: owner,
                    scannerPassword: password,scannerSetup: layout.view.scannerSetup,connection: layout.view.connection,
                    commissioning: commissioning,input: fixture.root.input,midi: fixture.root.midi,recording: fixture.root.profileRecording,
                    footswitch: fixture.root.footswitch,presets: layout.view.presets,sourceCatalog: { [] },selectedTab: tab)),wide ? 800:620,900))
            }
            for (name,view,width,height) in views {
                let host = NSHostingView(rootView: view.environment(\.fieldToolbarLabels,labels).environment(\.colorScheme,.dark).preferredColorScheme(.dark))
                host.appearance = NSAppearance(named: .darkAqua)
                let window = NSWindow(contentRect: .init(x: -10000,y: -10000,width: width,height: height),styleMask: [.borderless],backing: .buffered,defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
                host.frame = .init(x: 0,y: 0,width: width,height: height); window.orderFrontRegardless(); pump(host)
                let elements = LayoutGuardian.elements(in: host,window: window)
                XCTAssertTrue(elements.contains(where: \.control),"\(name) must expose actual controls")
                coverage.append(["view": name,"width": width,"labels": labels,"elements": elements.count,
                    "controls": elements.filter(\.control).count,"fonts": elements.filter { $0.font != nil }.count,
                    "colorRoles": elements.filter { $0.foreground != nil && $0.background != nil }.count])
                failures += LayoutGuardian.violations(elements,view: "\(name) width=\(width) labels=\(labels)")
                try capture(host,"runde-i-\(name)-\(Int(width))-labels-\(labels).png")
                window.contentView = nil; window.close()
            }
        }}
        let auditDirectory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: auditDirectory,withIntermediateDirectories: true)
        let coverageURL = auditDirectory.appendingPathComponent("layout-guardian-coverage.json")
        try JSONSerialization.data(withJSONObject: coverage,options: [.prettyPrinted,.sortedKeys]).write(to: coverageURL)
        let log = auditDirectory.appendingPathComponent("layout-guardian-violations.txt")
        try failures.joined(separator: "\n").write(to: log,atomically: true,encoding: .utf8)
        XCTAssertTrue(failures.isEmpty, failures.prefix(60).joined(separator: "\n") + "\nAll diagnostics: \(log.path)")
    }
}

extension RundeFRenderingTests {
    func testLayoutGuardianSliderExpandedHitAreaReceivesNativeEdgeClick() throws {
        _ = NSApplication.shared
        InspectorLayoutProbe.enabled = true
        defer { InspectorLayoutProbe.enabled = false }
        var value = 50.0
        let binding = Binding(get: { value },set: { value = $0 })
        let host = KeyboardEventHost(rootView: DeferredControlSlider(value: binding,range: 0...100,defaultValue: 50,title: "Guarded slider"))
        let window = NSWindow(contentRect: .init(x: -10000,y: -10000,width: 400,height: 100),styleMask: [.titled],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = .init(x: 0,y: 0,width: 400,height: 100); window.makeKeyAndOrderFront(nil); pump(host)
        func marker(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "inspector.frame.audit.hit.slider.Guarded slider" { return view }
            return view.subviews.compactMap(marker).first
        }
        let hit = try XCTUnwrap(marker(host))
        XCTAssertGreaterThanOrEqual(hit.bounds.height,20)
        let point = hit.convert(.init(x: hit.bounds.width * 0.85,y: 1),to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,location: point,modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp,location: point,modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: window.windowNumber,context: nil,eventNumber: 2,clickCount: 1,pressure: 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { NSApp.postEvent(up,atStart: true) }
        NSApp.sendEvent(down); pump(host)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp,until: Date(),inMode: .default,dequeue: true) { NSApp.sendEvent(queued) }
        pump(host)
        XCTAssertGreaterThan(value,75,"The extra hit area must operate the slider, not merely enlarge its audit frame")
    }
}

extension RundeFRenderingTests {
    func testSettingsNavigationButtonsVisitAllPanelsAndReturnWithoutEditingDocument() throws {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true,forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let fixture = try MonitorRootFixture(), layout = try LayoutWorkspaceFixture(fixture: fixture), owner = fixture.root.document
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        let password = ScannerPasswordSettingsModel(store: UserDefaultsScannerPasswordStore(defaults: try XCTUnwrap(UserDefaults(suiteName: layout.suiteName))))
        let content = PlanariumSettingsView(workspace: layout.workspace,spatialInstrument: owner,scannerPassword: password,
            scannerSetup: layout.view.scannerSetup,connection: layout.view.connection,commissioning: .init(coordinator: fixture.root.input),
            input: fixture.root.input,midi: fixture.root.midi,recording: fixture.root.profileRecording,
            footswitch: fixture.root.footswitch,presets: layout.view.presets,sourceCatalog: { [] })
        let host = NSHostingView(rootView: content.environment(\.colorScheme,.dark).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: .init(x: -10000,y: -10000,width: 620,height: 900),styleMask: [.borderless],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = .init(x: 0,y: 0,width: 620,height: 900); window.orderFrontRegardless(); pump(host)
        let original = owner.document
        func elements() -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            func visit(_ value: Any) -> [NSObject] {
                guard let object = value as? NSObject,seen.insert(ObjectIdentifier(object)).inserted else { return [] }
                return [object] + LayoutGuardian.children(object).flatMap(visit)
            }
            return visit(window)
        }
        for (tab,heading): (PlanariumSettingsTab,String) in [(.performance,"Panic Footswitch"),(.scanner,"Scanner password"),(.development,"Host Baud Rate"),(.support,"Scanner Setup"),(.tempo,"Clock direction")] {
            let button = try XCTUnwrap(elements().first { object in
                return LayoutGuardian.string(object,"accessibilityRole") == "AXButton" && LayoutGuardian.string(object,"accessibilityLabel") == tab.title
            })
            XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("accessibilityPerformPress"),to: button,from: nil)); pump(host)
            XCTAssertTrue(elements().contains { object in
                return ["accessibilityLabel","accessibilityTitle","accessibilityValue"].compactMap { LayoutGuardian.string(object,$0) }.contains(heading)
            },"The native \(tab.title) action must display \(heading)")
            XCTAssertEqual(owner.document,original)
        }
    }
}

extension RundeFRenderingTests {
    func testRecoveredPresetBadgeWideNarrowAndActualSaveReloadTransitions() throws {
        _ = NSApplication.shared
        InspectorLayoutProbe.enabled = true; CaptionLayoutProbe.enabled = true
        defer { InspectorLayoutProbe.enabled = false; CaptionLayoutProbe.enabled = false }
        for factory in [false,true] {
            let fixture = try MonitorRootFixture(), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryUI-\(UUID())")
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
            let store = PresetFileStore(directory: directory.appendingPathComponent("Presets"))
            let recovery = PresetRecoveryStore(url: directory.appendingPathComponent("Recovery.json"))
            let suite = "RecoveryUI-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let name = factory ? "Harmony 30 Mode Wheel" : "A deliberately long user preset name for the recovered state"
            let original = InstrumentPresetV6(name: name,document: owner.document)
            let library = factory ? try FactoryPresetLibrary(presets: [original]) : .empty
            let factoryBytes = library.data(named: name)
            if !factory { try store.save(PresetV6Codec.encode(original),as: name) }
            let first = PresetControlModel(store: store,documentOwner: owner,factoryPresets: library)
            var models = [first]
            defer { models.forEach { $0.stopRecovery() }; recovery.flush(); try? FileManager.default.removeItem(at: directory) }
            first.configureRecovery(defaults: defaults,store: recovery)
            XCTAssertNotNil(first.load(name,decision: .discard))
            try owner.edit { $0.beatsPerMinute = 137 }
            first.draftSummary = "Unsaved restored document"
            first.captureRecoveryIfNeeded(now: .distantFuture); recovery.flush(); first.stopRecovery()
            defaults.set(0.0,forKey: "presetLastSaved")
            let restored = PresetControlModel(store: store,documentOwner: owner,factoryPresets: library)
            models.append(restored); restored.configureRecovery(defaults: defaults,store: recovery); restored.restoreStartup()
            XCTAssertTrue(restored.isRecovered); XCTAssertEqual(restored.lastLoadedName,name)
            XCTAssertEqual(restored.recoveryTooltip.contains("Factory preset unchanged"),factory)
            for labels in [false,true] { for width in [400,800] {
                let frames = try renderKeyboard(PresetBarView(model: restored).environment(\.fieldToolbarLabels,labels),width: CGFloat(width),height: 350,
                    name: "runde-j-recovered-factory-\(factory)-\(width)-labels-\(labels).png",auditLayout: true)
                let badge = try XCTUnwrap(frames["inspector.frame.preset.recovered"])
                let symbol = try XCTUnwrap(frames["inspector.frame.preset.recoverySymbol"])
                XCTAssertGreaterThan(badge.width,0); XCTAssertGreaterThan(symbol.width,0)
                XCTAssertGreaterThanOrEqual(badge.minX,0); XCTAssertLessThanOrEqual(symbol.maxX,CGFloat(width))
            }}
            restored.requestSave()
            if factory { XCTAssertTrue(restored.isRecovered); restored.commitSaveAs() }
            XCTAssertFalse(restored.isRecovered)
            let saved = try renderKeyboard(PresetBarView(model: restored),width: 400,height: 350,
                name: "runde-j-saved-factory-\(factory).png",auditLayout: true)
            XCTAssertNil(saved["inspector.frame.preset.recovered"])
            XCTAssertEqual(library.data(named: name),factoryBytes)
            try owner.edit { $0.beatsPerMinute = 149 }
            restored.captureRecoveryIfNeeded(now: .distantFuture); recovery.flush(); restored.stopRecovery()
            defaults.set(0.0,forKey: "presetLastSaved")
            let again = PresetControlModel(store: store,documentOwner: owner,factoryPresets: library)
            models.append(again); again.configureRecovery(defaults: defaults,store: recovery); again.restoreStartup()
            XCTAssertTrue(again.isRecovered)
            XCTAssertNotNil(again.load(name,decision: .discard)); XCTAssertFalse(again.isRecovered)
            let reloaded = try renderKeyboard(PresetBarView(model: again),width: 400,height: 350,
                name: "runde-j-reloaded-factory-\(factory).png",auditLayout: true)
            XCTAssertNil(reloaded["inspector.frame.preset.recovered"])
            XCTAssertEqual(owner.document.beatsPerMinute,factory ? 120 : 137)
        }
    }
}
