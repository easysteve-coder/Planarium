import AppKit
import SwiftUI

/// Pointer ownership only; the existing SwiftUI button retains its appearance
/// and accessibility action. Emergency actions fire on the first down event.
struct EmergencyFirstMouseAction: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let action: () -> Void
    var pressed: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> EmergencyFirstMouseView {
        let view = EmergencyFirstMouseView()
        view.setAccessibilityElement(false)
        view.enabled = enabled; view.action = action; view.pressed = pressed
        return view
    }
    func updateNSView(_ view: EmergencyFirstMouseView, context: Context) {
        view.enabled = enabled; view.action = action; view.pressed = pressed
    }
}

final class EmergencyFirstMouseView: NSView {
    var enabled = true
    var action: (() -> Void)?
    var pressed: (Bool) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }
    override func mouseDown(with event: NSEvent) { if enabled { pressed(true); perform() } }
    override func mouseUp(with event: NSEvent) { pressed(false) } // Never send a second action.
    func perform() { if enabled { action?() } }
}

/// One app-owned registration: no window focus dependency, no idle timer.
/// It also reaches an emergency surface while a parent window has a sheet;
/// ordinary controls and events keep AppKit's normal activation policy.
@MainActor final class EmergencyActionMonitor {
    static let menuTitle = "PANIC — All Notes Off"
    private let panic: () -> Void
    private let registration = EmergencyEventRegistration()
    var isMonitoring: Bool { registration.token != nil }
    init(panic: @escaping () -> Void) { self.panic = panic; start() }
    func start() {
        guard !isMonitoring else { return }
        registration.token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }
    func stop() { registration.remove() }
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isMonitoring else { return event }
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .option, .shift, .control]) == [.command, .option],
           event.charactersIgnoringModifiers == "." {
            if !event.isARepeat { panic() }
            return nil
        }
        guard event.type == .leftMouseDown, let window = event.window,
              !window.isKeyWindow || window.attachedSheet != nil,
              let content = window.contentView else { return event }
        let point = content.superview?.convert(event.locationInWindow, from: nil)
            ?? content.convert(event.locationInWindow, from: nil)
        var hit = content.hitTest(point)
        while let view = hit {
            if let emergency = view as? EmergencyFirstMouseView,
               emergency.enabled, emergency.acceptsFirstMouse(for: event) {
                emergency.perform()
                return nil
            }
            hit = view.superview
        }
        return event
    }
}

private final class EmergencyEventRegistration: @unchecked Sendable {
    var token: Any?
    func remove() {
        guard let token else { return }
        NSEvent.removeMonitor(token); self.token = nil
    }
    deinit { remove() }
}

/// The identical item is used by the application Commands and native menu tests.
struct EmergencyPanicMenuItem: View {
    let panic: () -> Void
    var body: some View {
        Button(EmergencyActionMonitor.menuTitle, action: panic)
            .keyboardShortcut(".", modifiers: [.command, .option])
    }
}
