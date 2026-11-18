import AppKit
import Combine
import SwiftUI

private struct PresentationVisibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var presentationVisible: Bool {
        get { self[PresentationVisibleKey.self] }
        set { self[PresentationVisibleKey.self] = newValue }
    }
}

/// Observation belongs to the actual instrument window, including when another
/// app covers it. No application activation test: a visible inactive window
/// still presents measurements. Detached offline hosting keeps its default.
struct WindowPresentationVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
    func updateNSView(_ view: VisibilityView, context: Context) { view.changed = changed }

    @MainActor final class VisibilityView: NSView {
        var changed: (Bool) -> Void
        private var observations: [AnyCancellable] = []
        private var visible: Bool?
        private let applicationHidden: @MainActor () -> Bool
        init(changed: @escaping (Bool) -> Void, applicationHidden: @escaping @MainActor () -> Bool = { NSApp.isHidden }) {
            self.changed = changed; self.applicationHidden = applicationHidden; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); observations.removeAll()
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observations.append(NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observations.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            // Avoid changing SwiftUI state during native view construction.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        private func refresh() {
            guard let window else { return }
            let next = window.occlusionState.contains(.visible) && !window.isMiniaturized && !applicationHidden()
            guard visible != next else { return }
            visible = next; changed(next)
        }
    }
}
