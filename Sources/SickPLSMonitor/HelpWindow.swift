import AppKit
import SwiftUI
import SickPLSMonitorKit

/// Die Hilfeansicht (SICK-039): rendert ``HelpTopics`` -- nur Text,
/// keine Handlung.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Planarium – Hilfe").font(.title2).bold()
                ForEach(HelpTopics.all) { topic in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(topic.title).font(.headline)
                        Text(topic.body)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, idealWidth: 560, minHeight: 360, idealHeight: 640)
    }
}

/// Öffnet **ein** Hilfefenster über AppKit -- das `Window`-Scene von
/// SwiftUI gibt es erst ab macOS 13, die Zielplattform ist macOS 12.
/// Ein zweiter Aufruf holt dasselbe Fenster nach vorn.
@MainActor
final class HelpWindowController {
    static let shared = HelpWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hilfe"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HelpView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
