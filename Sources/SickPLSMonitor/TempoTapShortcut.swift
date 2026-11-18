import AppKit
import SwiftUI

/// A plain T belongs to the instrument only when AppKit is not editing text.
struct TempoTapKeyDecision {
    static func shouldTap(characters: String?, modifiers: NSEvent.ModifierFlags,
                          isKeyDown: Bool, isRepeat: Bool, isInstrumentWindow: Bool,
                          isTextInput: Bool, hasSheetOrModal: Bool) -> Bool {
        isKeyDown && !isRepeat && characters == "t"
            && modifiers.intersection([.command, .option, .control, .shift]).isEmpty
            && isInstrumentWindow && !isTextInput && !hasSheetOrModal
    }
}

/// One owner in the App scene, independent of how many instrument windows exist.
@MainActor final class TempoTapShortcutMonitor: ObservableObject {
    private let tap: () -> Void
    private let cancelCapture: () -> Bool
    private let keyWindow: @MainActor () -> NSWindow?
    private let instrumentViews = NSHashTable<NSView>.weakObjects()
    private let registration = TempoTapEventRegistration()
    var isMonitoring: Bool { registration.token != nil }

    init(tap: @escaping () -> Void, cancelCapture: @escaping () -> Bool = { false }, keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) {
        self.tap = tap
        self.cancelCapture = cancelCapture
        self.keyWindow = keyWindow
        start()
    }

    func start() {
        guard !isMonitoring else { return }
        registration.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, keyWindow: self.keyWindow(), modalWindow: NSApp.modalWindow)
        }
    }

    func stop() { registration.remove() }

    func register(_ view: NSView) { instrumentViews.add(view) }

    func handle(_ event: NSEvent, keyWindow: NSWindow?, modalWindow: NSWindow?) -> NSEvent? {
        guard event.type == .keyDown else { return event }
        let responder = keyWindow?.firstResponder
        let isInstrumentWindow = keyWindow != nil && event.window === keyWindow
            && instrumentViews.allObjects.contains { $0.window === keyWindow }
        if event.keyCode == 53, isInstrumentWindow, modalWindow == nil,
           keyWindow?.attachedSheet == nil, keyWindow?.sheetParent == nil, cancelCapture() {
            // Capture consumes Escape; the text responder must still discard its draft.
            if responder is NSText || responder is NSTextField { responder?.keyDown(with: event) }
            return nil
        }
        guard TempoTapKeyDecision.shouldTap(characters: event.characters,
            modifiers: event.modifierFlags, isKeyDown: event.type == .keyDown,
            isRepeat: event.isARepeat, isInstrumentWindow: isInstrumentWindow,
            isTextInput: responder is NSText || responder is NSTextField,
            hasSheetOrModal: keyWindow?.attachedSheet != nil || keyWindow?.sheetParent != nil || modalWindow != nil)
        else { return event }
        tap()
        return nil
    }
}

/// Exclusive ownership permits removal during destruction, like lifecycle tokens.
private final class TempoTapEventRegistration: @unchecked Sendable {
    var token: Any?
    func remove() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }
    deinit { remove() }
}

/// Only the instrument WindowGroup contains this marker; Settings and panels do not.
struct TempoTapWorkspaceRegistration: NSViewRepresentable {
    let monitor: TempoTapShortcutMonitor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        monitor.register(view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
