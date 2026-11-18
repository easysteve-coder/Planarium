import SwiftUI
import SickPLSMonitorKit

struct StableCellInspectorView: View, Equatable {
    let editor: CanvasSession
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.editor === rhs.editor }
    var body: some View { CellInspectorHostingSurface(editor: editor) }
}
private struct CellInspectorHostingSurface: NSViewRepresentable {
    let editor: CanvasSession
    func makeNSView(context: Context) -> NSHostingView<CellInspectorView> {
        NSHostingView(rootView: CellInspectorView(editor: editor))
    }
    func updateNSView(_ view: NSHostingView<CellInspectorView>, context: Context) {}
}
