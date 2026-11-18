import AppKit

/// Offscreen window that reports itself visible, like an instrument window on
/// stage. Native live layers only display inside a window, and the field's
/// presentation visibility follows the window's occlusion state.
final class PresentingTestWindow: NSWindow {
    convenience init(hosting view: NSView, size: CGSize) {
        self.init(contentRect: .init(x: -10000, y: -10000, width: size.width, height: size.height),
                  styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; contentView = view
    }
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
    func tearDown() { contentView = nil; close() }
}
