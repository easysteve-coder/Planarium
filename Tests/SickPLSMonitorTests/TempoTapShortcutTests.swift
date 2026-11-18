import AppKit
import SwiftUI
import XCTest
import Dispatch
import PlanariumDomain
import PlanariumRuntime
@testable import SickPLSMonitor

final class ShortcutTempoClock: RuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 0
    var now: Double { lock.lock(); defer { lock.unlock() }; return time }
    func set(_ value: Double) { lock.lock(); time = value; lock.unlock() }
    func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation { .init {} }
}

@MainActor final class TempoTapShortcutTests: XCTestCase {
    func testDecisionAllowsOnlyUnmodifiedTInFreeInstrumentWindow() {
        func decision(text: String? = "t", flags: NSEvent.ModifierFlags = [],
                      down: Bool = true, repeated: Bool = false, instrument: Bool = true,
                      editing: Bool = false, sheet: Bool = false) -> Bool {
            TempoTapKeyDecision.shouldTap(characters: text, modifiers: flags, isKeyDown: down,
                isRepeat: repeated, isInstrumentWindow: instrument, isTextInput: editing,
                hasSheetOrModal: sheet)
        }
        XCTAssertTrue(decision())
        XCTAssertFalse(decision(editing: true))
        XCTAssertFalse(decision(sheet: true))
        XCTAssertFalse(decision(instrument: false))
        for flag in [NSEvent.ModifierFlags.command, .option, .control, .shift,
                     [.command, .shift], [.option, .control]] {
            XCTAssertFalse(decision(flags: flag), "\(flag)")
        }
        for text in ["T", "x", "", nil] { XCTAssertFalse(decision(text: text)) }
        XCTAssertFalse(decision(down: false))
        XCTAssertFalse(decision(repeated: true))
    }

    func testRealTextFieldKeepsTAndFreeResponderTapsAfterEditingEnds() throws {
        var taps = 0
        let monitor = TempoTapShortcutMonitor(tap: { taps += 1 })
        defer { monitor.stop() }
        let window = makeWindow()
        defer { window.close() }
        let field = NSTextField(string: "Prese")
        field.frame = .init(x: 0, y: 0, width: 250, height: 40)
        window.contentView?.addSubview(field)
        monitor.register(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        let t = try event(window)
        let forwarded = try XCTUnwrap(monitor.handle(t, keyWindow: window, modalWindow: nil))
        XCTAssertTrue(forwarded === t)
        editor.keyDown(with: forwarded)
        XCTAssertEqual(editor.string, "Preset")
        XCTAssertEqual(taps, 0)
        XCTAssertTrue(window.makeFirstResponder(window.contentView))
        XCTAssertNil(monitor.handle(t, keyWindow: window, modalWindow: nil))
        XCTAssertEqual(taps, 1)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNotNil(monitor.handle(t, keyWindow: window, modalWindow: nil))
        XCTAssertEqual(taps, 1)
    }

    func testTextViewAndNSTextRespondersKeepEvents() throws {
        var taps = 0
        let monitor = TempoTapShortcutMonitor(tap: { taps += 1 })
        defer { monitor.stop() }
        let window = makeWindow()
        defer { window.close() }
        let text = NSTextView(frame: .init(x: 0, y: 0, width: 250, height: 40))
        window.contentView?.addSubview(text)
        monitor.register(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        let t = try event(window)
        XCTAssertTrue(monitor.handle(t, keyWindow: window, modalWindow: nil) === t)
        text.keyDown(with: t)
        XCTAssertEqual(text.string, "t")
        XCTAssertEqual(taps, 0)
    }

    func testWorkspaceRegistrationFollowsTwoWindowsWithoutInstallingAnotherMonitor() throws {
        var taps = 0
        let monitor = TempoTapShortcutMonitor(tap: { taps += 1 })
        defer { monitor.stop() }
        let first = makeWindow(), second = makeWindow(), settings = makeWindow()
        defer { first.close(); second.close(); settings.close() }
        let marker = NSHostingView(rootView: TempoTapWorkspaceRegistration(monitor: monitor))
        marker.frame = .init(x: 0, y: 0, width: 300, height: 80)
        first.contentView = marker
        marker.layoutSubtreeIfNeeded()
        XCTAssertNil(monitor.handle(try event(first), keyWindow: first, modalWindow: nil))
        monitor.start(); monitor.start()
        XCTAssertTrue(monitor.isMonitoring)
        let secondMarker = NSHostingView(rootView: TempoTapWorkspaceRegistration(monitor: monitor))
        second.contentView = secondMarker
        secondMarker.layoutSubtreeIfNeeded()
        XCTAssertNil(monitor.handle(try event(second), keyWindow: second, modalWindow: nil))
        let settingsT = try event(settings)
        XCTAssertTrue(monitor.handle(settingsT, keyWindow: settings, modalWindow: nil) === settingsT)
        first.contentView = NSView()
        let detachedT = try event(first)
        XCTAssertTrue(monitor.handle(detachedT, keyWindow: first, modalWindow: nil) === detachedT)
        second.contentView = marker
        marker.layoutSubtreeIfNeeded()
        XCTAssertNil(monitor.handle(try event(second), keyWindow: second, modalWindow: nil))
        XCTAssertEqual(taps, 3)
        monitor.stop(); monitor.stop()
        XCTAssertFalse(monitor.isMonitoring)
        monitor.start()
        XCTAssertTrue(monitor.isMonitoring)
    }

    func testSheetModalAndMismatchedWindowPassEventsAndRecover() throws {
        var taps = 0
        let monitor = TempoTapShortcutMonitor(tap: { taps += 1 })
        defer { monitor.stop() }
        let window = makeWindow(), sheet = makeWindow(), other = makeWindow()
        defer { window.close(); sheet.close(); other.close() }
        let view = try XCTUnwrap(window.contentView)
        monitor.register(view)
        let t = try event(window)
        XCTAssertNil(monitor.handle(t, keyWindow: window, modalWindow: nil))
        window.beginSheet(sheet)
        XCTAssertTrue(monitor.handle(t, keyWindow: window, modalWindow: nil) === t)
        let sheetT = try event(sheet)
        monitor.register(try XCTUnwrap(sheet.contentView))
        XCTAssertTrue(monitor.handle(sheetT, keyWindow: sheet, modalWindow: nil) === sheetT)
        window.endSheet(sheet)
        XCTAssertNil(monitor.handle(t, keyWindow: window, modalWindow: nil))
        XCTAssertTrue(monitor.handle(t, keyWindow: window, modalWindow: other) === t)
        XCTAssertNil(monitor.handle(t, keyWindow: window, modalWindow: nil))
        XCTAssertTrue(monitor.handle(t, keyWindow: other, modalWindow: nil) === t)
        XCTAssertTrue(monitor.handle(t, keyWindow: nil, modalWindow: nil) === t)
        let nonKey = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            subtype: 0, data1: 0, data2: 0))
        XCTAssertTrue(monitor.handle(nonKey, keyWindow: window, modalWindow: nil) === nonKey)
        XCTAssertEqual(taps, 3)
    }

    func testProductionDispatchConsumesOneTAndMonitorDestructionRemovesCallback() throws {
        let window = makeWindow(), second = makeWindow()
        defer { window.close(); second.close() }
        var taps = 0
        var activeWindow: NSWindow? = window
        // The test process stays inactive; only the key-window lookup is supplied.
        // Dispatch still traverses the real NSEvent local monitor in NSApp.sendEvent.
        var monitor: TempoTapShortcutMonitor? = TempoTapShortcutMonitor(tap: { taps += 1 }, keyWindow: { activeWindow })
        let releasedMonitor = { [weak monitor] in monitor }
        monitor?.register(try XCTUnwrap(window.contentView))
        monitor?.register(try XCTUnwrap(second.contentView))
        monitor?.start()
        NSApp.sendEvent(try event(window))
        XCTAssertEqual(taps, 1)
        activeWindow = second
        monitor?.start()
        NSApp.sendEvent(try event(second))
        XCTAssertEqual(taps, 2, "A second window must not install a second callback")
        activeWindow = window
        monitor?.stop()
        NSApp.sendEvent(try event(window))
        XCTAssertEqual(taps, 2)
        monitor?.start()
        NSApp.sendEvent(try event(window))
        XCTAssertEqual(taps, 3)
        monitor = nil
        XCTAssertNil(releasedMonitor())
        NSApp.sendEvent(try event(window))
        XCTAssertEqual(taps, 3)
    }

    func testKeyboardRouteKeepsOwnerPerformPermission() throws {
        for perform in [false, true] {
            let clock = ShortcutTempoClock(), fixture = try MonitorRootFixture(clock: clock), owner = fixture.root.document
            defer { fixture.root.terminate {} }
            let monitor = TempoTapShortcutMonitor(tap: { owner.tapTempo() })
            defer { monitor.stop() }
            let window = makeWindow()
            defer { window.close() }
            monitor.register(try XCTUnwrap(window.contentView))
            owner.canvas.setPerformanceLocked(perform)
            owner.setBeatsPerMinute(90)
            XCTAssertEqual(owner.document.beatsPerMinute, 90)
            let t = try event(window)
            XCTAssertNil(monitor.handle(t, keyWindow: window, modalWindow: nil))
            clock.set(0.4)
            XCTAssertNil(monitor.handle(t, keyWindow: window, modalWindow: nil))
            XCTAssertEqual(owner.document.beatsPerMinute, 150)
            XCTAssertNil(owner.notice)
            let field = NSTextField(string: "")
            field.frame = .init(x: 0, y: 0, width: 250, height: 40)
            window.contentView?.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            clock.set(0.8)
            let forwarded = try XCTUnwrap(monitor.handle(t, keyWindow: window, modalWindow: nil))
            editor.keyDown(with: forwarded)
            XCTAssertEqual(editor.string, "t")
            XCTAssertEqual(owner.document.beatsPerMinute, 150)
            XCTAssertTrue(window.makeFirstResponder(window.contentView))
            clock.set(1.2)
            XCTAssertNil(monitor.handle(t, keyWindow: window, modalWindow: nil))
            XCTAssertEqual(owner.document.beatsPerMinute, 100, accuracy: 1e-9, "Typing T did not enter tap history")
            XCTAssertNil(owner.notice)
        }
    }

    func testAppMenuHasNoTKeyEquivalentAndAppOwnsMonitor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/SickPLSMonitorApp.swift"))
        XCTAssertFalse(source.contains("keyboardShortcut(\"t\""))
        XCTAssertTrue(source.contains("Button(\"Tap Tempo (T)\")"))
        XCTAssertTrue(source.contains("@StateObject private var ownership: AppOwnership<AppModels>") && source.contains("let tempoTapShortcut: TempoTapShortcutMonitor"))
        XCTAssertTrue(source.contains("TempoTapWorkspaceRegistration(monitor: models.tempoTapShortcut)"))
        XCTAssertTrue(source.contains("TempoTapShortcutMonitor(tap: { root.document.tapTempo() }"))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func event(_ window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "t",
            charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
    }
}
