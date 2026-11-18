import AppKit
import SwiftUI
import XCTest
import PlanariumRuntime
@testable import SickPLSMonitor

@MainActor final class EmergencyActionTests: XCTestCase {
    private func prepare() {
        _ = NSApplication.shared.setActivationPolicy(.regular)
        NSApp.finishLaunching(); NSApp.activate(ignoringOtherApps: true)
    }
    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
    }
    private func window(width: Int = 500, height: Int = 200) -> NSWindow {
        let result = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        result.isReleasedWhenClosed = false
        return result
    }
    private func surfaces(_ view: NSView) -> [EmergencyFirstMouseView] {
        (view as? EmergencyFirstMouseView).map { [$0] } ?? view.subviews.flatMap(surfaces)
    }
    private func click(_ surface: NSView, in window: NSWindow) throws {
        let location = surface.convert(CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
    }
    private func key(_ window: NSWindow, repeated: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: ".", charactersIgnoringModifiers: ".", isARepeat: repeated, keyCode: 47))
    }
    private func ack(_ runtime: PerformanceRuntime) {
        let done = expectation(description: "Emergency reached Q")
        runtime.acknowledge { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testUnrelatedStopButtonHasNoEmergencyFirstMouseSurface() {
        let host = NSHostingView(rootView: IconActionButton("Stop", symbol: "stop.fill") {})
        host.frame = .init(x: 0, y: 0, width: 200, height: 100)
        settle(host)
        XCTAssertTrue(surfaces(host).isEmpty)
    }

    func testActiveAndDisabledEmergencySurfacesDispatchAtMostOnce() throws {
        prepare()
        for disabled in [false, true] {
            var actions = 0
            let host = NSHostingView(rootView: IconActionButton("PANIC", symbol: "exclamationmark.octagon.fill", emergencyFirstMouse: true) {
                actions += 1
            }.disabled(disabled))
            let main = window(); defer { main.contentView = nil; main.close() }
            main.contentView = host; host.frame = .init(x: 0, y: 0, width: 500, height: 200)
            main.makeKeyAndOrderFront(nil); settle(host)
            let surface = try XCTUnwrap(surfaces(host).first)
            let monitor = EmergencyActionMonitor(panic: { actions += 1 })
            defer { monitor.stop() }
            try click(surface, in: main); settle(host)
            XCTAssertEqual(actions, disabled ? 0 : 1)
        }
    }

    func testNativeFirstClickOnProductionMixerPanicsOnceWithPluginMonitorOrSheetInFront() throws {
        prepare()
        for width in [1728, 1024] { for frontKind in ["plugin", "monitor", "sheet"] {
            let graph = MonitorGraph(), fixture = try MonitorRootFixture(graph: graph)
            let layout = try LayoutWorkspaceFixture(fixture: fixture)
            defer { layout.cleanDefaults(); fixture.root.terminate {} }
            layout.workspace.setVisible(.channelStrip, true)
            let host = NSHostingView(rootView: layout.view)
            let height = width == 1024 ? 2400 : 1000
            let main = window(width: width, height: height), front = window()
            main.contentView = host; host.frame = .init(x: 0, y: 0, width: width, height: height)
            defer { if main.attachedSheet != nil { main.endSheet(front) }; main.contentView = nil; main.close(); front.close() }
            main.makeKeyAndOrderFront(nil); settle(host)
            let panic = try XCTUnwrap(surfaces(host).first)
            XCTAssertGreaterThan(panic.bounds.width, 0)
            XCTAssertTrue(main.contentView!.bounds.contains(panic.convert(panic.bounds, to: main.contentView)), "Native click must target a visible control")
            let monitor = EmergencyActionMonitor(panic: { fixture.root.document.panicAll() })
            defer { monitor.stop() }
            if frontKind == "sheet" { main.beginSheet(front) }
            else { front.title = frontKind; front.makeKeyAndOrderFront(nil) }
            settle(host)
            XCTAssertFalse(main.isKeyWindow)
            ack(fixture.root.runtime)
            let before = fixture.root.runtime.diagnostics.panicTimingCount
            try click(panic, in: main); ack(fixture.root.runtime)
            XCTAssertEqual(fixture.root.runtime.diagnostics.panicTimingCount, before + 1,
                "First native click must send exactly one PANIC with \(frontKind) in front at \(width), surface \(panic.convert(panic.bounds, to: nil)), content \(main.contentView!.bounds)")
            if frontKind == "sheet" { XCTAssertTrue(main.attachedSheet === front) }
            XCTAssertEqual(graph.starts, 0)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".agent_handoff/runs/fit-raumform-rueckgabe")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("panic-\(frontKind)-\(width).png"))
        } }
    }

    func testNativeStopTransportFirstClickDoesNotRestartOnMouseUp() throws {
        prepare()
        let fixture = try MonitorRootFixture(clock: ShortcutTempoClock())
        defer { fixture.root.terminate {} }
        fixture.root.document.startClockTransport()
        XCTAssertTrue(fixture.root.document.clockTransportPlaying)
        let host = NSHostingView(rootView: TempoHeaderView(instrument: fixture.root.document))
        let main = window(), plugin = window()
        defer { main.contentView = nil; main.close(); plugin.close() }
        main.contentView = host; host.frame = .init(x: 0, y: 0, width: 500, height: 200)
        main.makeKeyAndOrderFront(nil); settle(host)
        let stop = try XCTUnwrap(surfaces(host).first)
        let monitor = EmergencyActionMonitor(panic: { fixture.root.document.panicAll() })
        defer { monitor.stop() }
        plugin.makeKeyAndOrderFront(nil); settle(host)
        XCTAssertFalse(main.isKeyWindow)
        try click(stop, in: main); settle(host)
        XCTAssertFalse(fixture.root.document.clockTransportPlaying)
        XCTAssertTrue(surfaces(host).isEmpty, "Play keeps its ordinary first-click policy")
    }

    func testGlobalPanicShortcutFromEveryWindowAndSheetAndRegistrationLifetime() throws {
        prepare()
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let main = window(), plugin = window(), sheet = window()
        defer { if main.attachedSheet != nil { main.endSheet(sheet) }; main.close(); plugin.close(); sheet.close() }
        main.makeKeyAndOrderFront(nil)
        var monitor: EmergencyActionMonitor? = EmergencyActionMonitor(panic: { fixture.root.document.panicAll() })
        let released = { [weak monitor] in monitor }
        defer { monitor?.stop() }
        for front in [main, plugin] {
            front.makeKeyAndOrderFront(nil)
            monitor?.start(); monitor?.start()
            ack(fixture.root.runtime)
            let before = fixture.root.runtime.diagnostics.panicTimingCount
            NSApp.sendEvent(try key(front)); ack(fixture.root.runtime)
            XCTAssertEqual(fixture.root.runtime.diagnostics.panicTimingCount, before + 1)
            NSApp.sendEvent(try key(front, repeated: true)); ack(fixture.root.runtime)
            XCTAssertEqual(fixture.root.runtime.diagnostics.panicTimingCount, before + 1)
        }
        main.beginSheet(sheet)
        let before = fixture.root.runtime.diagnostics.panicTimingCount
        NSApp.sendEvent(try key(sheet)); ack(fixture.root.runtime)
        XCTAssertEqual(fixture.root.runtime.diagnostics.panicTimingCount, before + 1)
        monitor?.stop(); monitor?.stop()
        XCTAssertFalse(try XCTUnwrap(monitor).isMonitoring)
        monitor = nil; XCTAssertNil(released())
    }

    func testSharedProductionMenuItemHasShortcutAndInvokesPanicOnce() throws {
        prepare()
        var panics = 0
        let host = NSHostingView(rootView: Menu("Instrument") { EmergencyPanicMenuItem(panic: { panics += 1 }) }.menuStyle(.borderlessButton))
        let main = window(); defer { main.contentView = nil; main.close() }
        main.contentView = host; host.frame = .init(x: 0, y: 0, width: 500, height: 200)
        main.makeKeyAndOrderFront(nil); settle(host)
        func menus(_ view: NSView) -> [NSMenu] {
            (view.menu.map { [$0] } ?? []) + view.subviews.flatMap(menus)
        }
        func popup(_ view: NSView) -> NSPopUpButton? {
            if let button = view as? NSPopUpButton { return button }
            return view.subviews.compactMap(popup).first
        }
        let button = try XCTUnwrap(popup(host))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for menu in menus(host) { menu.cancelTracking() }
        }
        button.performClick(nil)
        settle(host)
        let menu = try XCTUnwrap(menus(host).first { $0.items.contains { $0.title == EmergencyActionMonitor.menuTitle } })
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == EmergencyActionMonitor.menuTitle })
        XCTAssertEqual(menu.items[index].keyEquivalent, ".")
        XCTAssertEqual(menu.items[index].keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]), [.command, .option])
        menu.performActionForItem(at: index); settle(host)
        XCTAssertEqual(panics, 1)
        XCTAssertTrue(menu.performKeyEquivalent(with: try key(main))); settle(host)
        XCTAssertEqual(panics, 2)
    }
}
