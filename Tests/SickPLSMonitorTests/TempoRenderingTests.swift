import AppKit
import Dispatch
import SwiftUI
import XCTest
import PlanariumDomain
import PlanariumMIDI
import PlanariumRuntime
import PlanariumApplication
@testable import SickPLSMonitor

@MainActor private final class TempoDestinations: MIDIConnectionBoundary {
    var onDestinationLost: (@MainActor () -> Void)?
    func destinations() -> [MIDITargetDescription] { [.init(id: 71, name: "IAC Driver · MainStage"), .init(id: 72, name: "Audio Interface · H90")] }
    func open(_ target: InstrumentMIDITarget) -> Result<any MIDISendBoundary, MIDIConnectionError> { .failure(.init("Offline image")) }
    func close() {}
}
private final class TempoImageSource: MIDIClockSource, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (MIDIClockPacket) -> Void)?
    private var nextTick = 0.0
    func open(_ id: Int32, receive: @escaping @Sendable (MIDIClockPacket) -> Void, lost: @escaping @Sendable () -> Void) -> (any MIDIClockSource)? {
        guard id == 71 else { return nil }
        lock.lock(); callback = receive; nextTick = ProcessInfo.processInfo.systemUptime; lock.unlock(); return self
    }
    func emit(_ bytes: [UInt8], at time: Double) {
        lock.lock(); let callback = callback; lock.unlock()
        callback?(.init(bytes: bytes, timestamp: time, arrival: ProcessInfo.processInfo.systemUptime))
    }
    func tick() {
        lock.lock(); let callback = callback, time = nextTick; nextTick += 1 / 48; lock.unlock()
        callback?(.init(bytes: [0xf8], timestamp: time, arrival: ProcessInfo.processInfo.systemUptime))
    }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }
    func close() { lock.lock(); callback = nil; lock.unlock() }
}
@MainActor final class TempoRenderingTests: XCTestCase {
    private func waitForClock(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(predicate())
    }
    func testReceiveHeaderAndSettingsRunningStoppedLostWideNarrowAndControlsDisabled() throws {
        // This is process-global; establish the AX mode instead of inheriting
        // it from an earlier full-suite rendering test.
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let source = TempoImageSource(), fixture = try MonitorRootFixture(midi: TempoDestinations(), clockSourceFactory: { source.open($0, receive: $1, lost: $2) })
        let owner = fixture.root.document
        owner.setBeatsPerMinute(93)
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = owner.document
        let dirty = layout.view.presets.isDirty
        XCTAssertFalse(dirty)
        layout.workspace.setClockDirection(.receive)
        layout.workspace.setClockSource(71, name: "MainStage · IAC Driver")
        layout.workspace.applyClockPreferences(to: owner)
        waitForClock { source.isOpen }
        let start = ProcessInfo.processInfo.systemUptime
        source.emit([0xfa], at: start)
        let ticks = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "tempo.image.source", qos: .userInteractive))
        ticks.schedule(deadline: .now(), repeating: 1 / 48)
        ticks.setEventHandler { source.tick() }; ticks.resume()
        defer { ticks.cancel() }
        waitForClock { fixture.root.clockReceiver.snapshot.tickCount >= 25 && owner.clockTransportPlaying }
        XCTAssertEqual(owner.displayedBeatsPerMinute, 120)
        for state in ["running", "stopped", "lost"] {
            if state == "stopped" {
                source.emit([0xfc], at: start + 0.6); waitForClock { !owner.clockTransportPlaying && !owner.externalClock.isLost }
            }
            if state == "lost" { ticks.cancel(); waitForClock { owner.externalClock.isLost } }
            for width in [1728, 1024] {
                try render(layout.view, width: width, height: 900, name: "tempo-receive-\(state)-\(width)", directory: directory)
                XCTAssertEqual(owner.clockTransportPlaying, state == "running", state)
                XCTAssertEqual(owner.externalClock.isLost, state == "lost", state)
            }
        }
        let host = NSHostingView(rootView: TempoHeaderView(instrument: owner))
        host.frame = .init(x: 0, y: 0, width: 280, height: 70); host.layoutSubtreeIfNeeded()
        let elements = accessibilityElements(host)
        for label in ["Tap Tempo (T)", "Play transport"] {
            let control = try XCTUnwrap(elements.first { accessibilityLabel($0) == label })
            XCTAssertEqual(control.value(forKey: "accessibilityEnabled") as? Bool, false, label)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        XCTAssertFalse(try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first).isEnabled)
        let sources: [MIDITargetDescription] = [.init(id: 71, name: "MainStage · IAC Driver"), .init(id: 72, name: "Audio Interface · H90")]
        for state in ["available", "unavailable", "none", "perform"] {
            if state == "unavailable" { layout.workspace.setClockSource(99, name: "Disconnected source") }
            if state == "none" { layout.workspace.setClockSource(nil) }
            if state != "perform" { layout.workspace.applyClockPreferences(to: owner) }
            if state == "unavailable" { waitForClock { owner.externalClock.isLost && !owner.externalClock.isSourceAvailable } }
            if state == "perform" { layout.workspace.togglePerformance(canvas: owner.canvas) }
            for width in [460, 360] {
                try render(TempoSyncSettingsView(workspace: layout.workspace, instrument: owner, midi: fixture.root.midi, sourceCatalog: { sources }),
                           width: width, height: 400, name: "tempo-receive-settings-\(state)-\(width)", directory: directory)
            }
        }
        XCTAssertEqual(owner.document, original)
        XCTAssertEqual(layout.view.presets.isDirty, dirty)
    }
    func testPerformHeaderBPMAndTapControlsAreEnabledAndEditTheOwner() throws {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let clock = ShortcutTempoClock(), fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        owner.canvas.setPerformanceLocked(true)
        let host = NSHostingView(rootView: TempoHeaderView(instrument: owner))
        host.frame = .init(x: 0, y: 0, width: 280, height: 50)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(host)
        let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(field.isEnabled)
        let elements = accessibilityElements(window)
        let tap = try XCTUnwrap(elements.first { accessibilityLabel($0) == "Tap Tempo (T)" },
            "Missing Tap: \(elements.map { accessibilityLabel($0) ?? String(describing: type(of: $0)) })")
        XCTAssertTrue(tap.responds(to: NSSelectorFromString("isAccessibilityEnabled")))
        XCTAssertEqual(tap.value(forKey: "accessibilityEnabled") as? Bool, true)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        for (text, code) in [("1", UInt16(18)), ("3", 20), ("7", 26)] {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            editor.keyDown(with: key)
        }
        XCTAssertTrue(window.makeFirstResponder(nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(owner.document.beatsPerMinute, 137)
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("accessibilityPerformPress"), to: tap, from: nil))
        clock.set(0.5)
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("accessibilityPerformPress"), to: tap, from: nil))
        XCTAssertEqual(owner.document.beatsPerMinute, 120, "The real Tap control reaches the owner's tempo history")
        XCTAssertNil(owner.notice)
    }

    private func accessibilityElements(_ value: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 30, let element = value as? NSObject else { return [] }
        let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren()
            ?? (element.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? element.value(forKey: "accessibilityChildren") as? [Any] : nil)
            ?? element.accessibilityAttributeValue(.children) as? [Any] ?? []
        return [element] + children.flatMap { accessibilityElements($0, depth: depth + 1) }
    }

    private func accessibilityLabel(_ element: NSObject) -> String? {
        (element as? NSAccessibilityProtocol)?.accessibilityLabel()
            ?? (element.responds(to: NSSelectorFromString("accessibilityLabel"))
                ? element.value(forKey: "accessibilityLabel") as? String : nil)
            ?? element.accessibilityAttributeValue(.description) as? String
            ?? element.accessibilityAttributeValue(.title) as? String
    }

    func testHeaderAndSettingsAllVisibleStatesWideAndNarrowWithoutRealOutputs() throws {
        let fixture = try MonitorRootFixture(midi: TempoDestinations()), layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.terminate {} }
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = fixture.root.document
        for state in ["default", "custom", "playing", "perform"] {
            if state == "custom" { owner.setBeatsPerMinute(137.5) }
            if state == "playing" { owner.startClockTransport() }
            if state == "perform" { owner.stopClockTransport(); layout.workspace.togglePerformance(canvas: owner.canvas) }
            for width in [1728, 1024] {
                try render(layout.view, width: width, height: 900, name: "tempo-header-\(state)-\(width)", directory: directory)
            }
        }
        layout.workspace.togglePerformance(canvas: owner.canvas)
        fixture.root.midi.refresh()
        for state in ["off", "send", "unavailable"] {
            layout.workspace.setClockSendEnabled(state != "off")
            layout.workspace.setClockTarget(71, selected: state != "off")
            layout.workspace.setClockTarget(72, selected: state != "off")
            if state == "unavailable" { layout.workspace.setClockTarget(99, selected: true) }
            for width in [460, 360] {
                try render(TempoSyncSettingsView(workspace: layout.workspace, instrument: owner, midi: fixture.root.midi),
                           width: width, height: 400, name: "tempo-settings-\(state)-\(width)", directory: directory)
            }
        }
        XCTAssertEqual(layout.workspace.preferences.clockTargetIDs, [71, 72, 99])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(owner.document), as: UTF8.self).contains("clockTargetIDs"))
    }
    private func render(_ view: some View, width: Int, height: Int, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
