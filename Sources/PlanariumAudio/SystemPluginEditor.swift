import AppKit

/// Observes the actual editor, including AUv2 frame-only resizing. Window
/// resize notifications cannot feed back: content sizes are compared before
/// applying, and notifications carry the source's size independently.
@MainActor public final class AppKitPluginEditor: PluginEditor {
    public let viewController: NSViewController
    public var controller: NSViewController? { viewController }
    private var preferred: NSKeyValueObservation?
    private var frameObserver: NSObjectProtocol?
    private var handler: (@MainActor (NSSize) -> Void)?
    private var previousPostsFrameChanges = false
    private var observationGeneration: UInt64 = 0
    public init(controller: NSViewController) { self.viewController = controller }
    public var initialSize: NSSize {
        _ = viewController.view
        let preferred = viewController.preferredContentSize
        if valid(preferred) { return preferred }
        let frame = viewController.view.frame.size
        if valid(frame) { return frame }
        let fitting = viewController.view.fittingSize
        return valid(fitting) ? fitting : NSSize(width: 640, height: 480)
    }
    public func observeSize(_ handler: @escaping @MainActor (NSSize) -> Void) {
        stopObserving()
        self.handler = handler
        let generation = observationGeneration
        previousPostsFrameChanges = viewController.view.postsFrameChangedNotifications
        viewController.view.postsFrameChangedNotifications = true
        preferred = viewController.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let size = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }; self.handler?(size)
            }
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: viewController.view, queue: .main
        ) { [weak self] notification in
            // Snapshot the posting view before scheduling. A subsequent layout
            // or preferred-size event must not rewrite this event's value.
            let source = EditorFrameSource(notification.object as? NSView)
            let size = MainActor.assumeIsolated { source.view?.frame.size }
            guard let size else { return }
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }; self.handler?(size)
            }
        }
    }
    public func stopObserving() {
        observationGeneration &+= 1
        preferred?.invalidate(); preferred = nil
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
            viewController.view.postsFrameChangedNotifications = previousPostsFrameChanges
        }
        frameObserver = nil; handler = nil
    }
    private func valid(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 1 && size.height > 1
    }
}

@MainActor public struct AppKitPluginWindows: PluginWindowFactory {
    public init() {}
    public func make(title: String, size: NSSize) -> any PluginWindow { AppKitPluginWindow(title: title, size: size) }
}

@MainActor public final class AppKitPluginWindow: PluginWindow {
    public let nativeWindow: NSWindow
    private var closeObserver: NSObjectProtocol?
    public var contentSize: NSSize { nativeWindow.contentRect(forFrameRect: nativeWindow.frame).size }
    init(title: String, size: NSSize) {
        // Floating panel as in Logic: it stays above the main window but does
        // not take its focus, so the first click on a fader or PANIC acts
        // (owner run 07.10.2026). It becomes key only for text input.
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .miniaturizable],
                            backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        nativeWindow = panel
        nativeWindow.title = title
        nativeWindow.isReleasedWhenClosed = false
        nativeWindow.contentMinSize = NSSize(width: 1, height: 1)
    }
    public func install(_ editor: any PluginEditor) {
        nativeWindow.contentViewController = PluginEditorContent.make(editor, size: contentSize)
    }
    public func resize(_ size: NSSize) {
        let frame = nativeWindow.frame
        nativeWindow.setContentSize(size)
        nativeWindow.contentView?.subviews.first?.setFrameSize(size)
        nativeWindow.setFrameOrigin(NSPoint(x: frame.minX, y: frame.maxY - nativeWindow.frame.height))
    }
    public func show(offscreen: Bool) {
        if offscreen {
            nativeWindow.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
            nativeWindow.orderOut(nil) // never activates NSApp or fronts a window
        } else { nativeWindow.orderFront(nil) } // never steals the main window's focus
    }
    public func close() { nativeWindow.close() }
    public func observeClose(_ handler: @escaping @MainActor @Sendable () -> Void) {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: nativeWindow, queue: .main) { _ in MainActor.assumeIsolated { handler() } }
    }
    public func clearEditor() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if let controller = nativeWindow.contentViewController { PluginEditorContent.clear(controller) }
        nativeWindow.contentViewController = nil
        nativeWindow.contentView = nil
    }
}

@MainActor public enum PluginEditorContent {
    public static func make(_ editor: any PluginEditor, size: NSSize) -> NSViewController? {
        guard let controller = editor.controller else { return nil }
        let view = controller.view
        let container = NSViewController()
        container.view = NSView(frame: NSRect(origin: .zero, size: size))
        container.view.autoresizingMask = [.width, .height]
        // Preserve controller containment/appearance and responder lifecycle,
        // including hosted AU editors. Only the container view is window-sized.
        controller.removeFromParent()
        container.addChild(controller)
        view.removeFromSuperview()
        view.autoresizingMask = []
        view.setFrameOrigin(.zero)
        view.setFrameSize(size)
        container.view.addSubview(view)
        return container
    }
    public static func clear(_ container: NSViewController) {
        for child in container.children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
    }
}

/// The notification is registered with queue .main. This capability carries
/// only its posting view to the synchronous Main assertion, never to Q/R.
private final class EditorFrameSource: @unchecked Sendable {
    let view: NSView?
    init(_ view: NSView?) { self.view = view }
}
