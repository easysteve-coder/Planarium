import SwiftUI
import PlanariumInput

/// Only this text leaf observes sampled Hz. Controls never observe telemetry.
struct ProfileRateText: View {
    @ObservedObject var rate: ProfileRateDisplayModel
    let text: (Double?) -> String
    // Allocated only by the offline probe. Distinguish simultaneously mounted
    // rate leaves without confusing their sum with work per displayed text.
    @State private var evaluationID: UUID? = ViewEvaluationProbe.current.map { _ in UUID() }
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("profileRate.text", instance: evaluationID)
        Text(text(rate.hertz))
    }
}
