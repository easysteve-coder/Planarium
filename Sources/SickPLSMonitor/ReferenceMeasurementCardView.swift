import SwiftUI
import SickPLSCore
import PlanariumScannerUI
import PlanariumInput

/// Die sichtbare Bedienkarte für die Referenzmessung (SICK-034e).
///
/// Die Karte besitzt keinen eigenen Messzustand und berechnet keine Zahlen.
/// Sie reicht die drei Bedienhandlungen an den Koordinator und zeigt den
/// vollständigen Präsentationstext des Messmodells.
struct ReferenceMeasurementCardView: View {
    let coordinator: ScannerWorkspaceModel
    @State private var indexText = ""
    @State private var rejection: String?

    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("reference.buttons")
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference measurement")
                .font(.headline)

            ReferenceMeasurementLiveText(coordinator: coordinator)

            HStack(spacing: 6) {
                TextField("Index 0…\(referenceIndexMaximum)", text: $indexText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120)
                IconActionButton("Select index", symbol: "checkmark", action: selectIndex)
            }

            HStack(spacing: 6) {
                IconActionButton("Start measurement", symbol: "play.fill") { coordinator.startReferenceMeasurement() }
                IconActionButton("Stop measurement", symbol: "stop.fill") { coordinator.stopReferenceMeasurement() }
            }

            if let rejection {
                Text(rejection)
                    .foregroundColor(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
        )
    }

    private func selectIndex() {
        let trimmed = indexText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = Int(trimmed) else {
            rejection = "Index rejected: please enter a whole number."
            return
        }
        do {
            try coordinator.selectReferenceIndex(index)
            rejection = nil
        } catch {
            // Die einzige Bereichsentscheidung liegt im Modell. Die Karte
            // zeigt, was der Wurf sagt.
            rejection = "Index rejected: valid range is 0…\(referenceIndexMaximum)."
        }
    }
}

private struct ReferenceMeasurementLiveText: View {
    @ObservedObject var coordinator: ScannerWorkspaceModel
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("reference.liveText")
        Text(ReferenceMeasurementPresentation.describe(coordinator.referenceMeasurement))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
