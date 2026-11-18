import Combine
import SwiftUI
import SickPLSMonitorKit

enum ScannerFlagPalette {
    static let colors: [Color] = [.white, .cyan, .green, .yellow, .orange, .red, .purple, .pink]
}

/// A separate profile subscriber keeps footer counts live without
/// reevaluating the stable editor controls on every scan. Only changed counts
/// reach SwiftUI; identical flag counts across profiles cause no update.
struct ScannerFlagLegendView: View {
    let model: SpatialActiveCellDisplayModel
    @State private var presentation: ScannerFlagPresentation
    static let title = "Scanner flag bits · unfiltered raw scan"
    init(model: SpatialActiveCellDisplayModel) {
        self.model = model
        _presentation = State(initialValue: ScannerFlagPresentation(profile: model.latestProfile))
    }
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("field.flagLegend")
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.title).font(.caption)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(ScannerFlagPresentation.values, id: \.self) { flag in
                    HStack(spacing: 4) {
                        Circle().fill(ScannerFlagPalette.colors[Int(flag)]).frame(width: 7, height: 7)
                        Text("\(ScannerFlagPresentation.label(flag)): \(presentation.counts[Int(flag)])")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }.accessibilityIdentifier("field.scanner-flags")
            .onReceive(model.$frame.map { ScannerFlagPresentation(profile: $0.profile) }.removeDuplicates()) { next in
                if presentation != next { presentation = next }
            }
    }
}
