import AppKit
import SwiftUI
import SickPLSCommissioningControl

/// Die **Offline-Evidenzkarte** samt redigiertem Textexport
/// (SICK-0330b) -- ablesbar und exportierbar, bevor SICK-034 real misst.
///
/// **Reine Komposition.** Der Text entsteht vollständig in
/// ``ConnectionEvidenceExport``; diese Ansicht zeigt ihn und reicht ihn
/// an die Zwischenablage oder einen Sicherungsdialog weiter. Sie liest
/// keine Rohdaten und formuliert nichts selbst.
struct ConnectionEvidenceView: View {
    @ObservedObject var model: StandardConnectionControlModel
    @State private var saveError: String?

    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("connection.evidence")
        VStack(alignment: .leading, spacing: 8) {
            Text("Evidence").font(.headline)

            ScrollView {
                Text(model.evidenceExportText())
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 260)

            HStack {
                IconActionButton("Copy connection evidence", symbol: "doc.on.doc") { copyToPasteboard() }
                IconActionButton("Save connection evidence", symbol: "square.and.arrow.down") { save() }
            }
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.evidenceExportText(), forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sick-connection-evidence.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.evidenceExportText().write(to: url, atomically: true, encoding: .utf8)
            saveError = nil
        } catch {
            saveError = "Could not save the evidence report."
        }
    }
}
