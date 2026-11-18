import SwiftUI
import PlanariumDomain

struct ChannelOutputChoices: View {
    let channels: [InstrumentChannel]
    let selectedID: UUID?
    let select: (UUID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let selectedID, !channels.contains(where: { $0.id == selectedID }) {
                Text("missing channel").foregroundColor(.orange).font(.system(size: 12, weight: .bold))
                    .accessibilityIdentifier("output.missingChannel")
                    .help("This channel was removed. The layer stays silent until you choose an available channel.")
            }
            ForEach(Array(channels.enumerated()), id: \.element.id) { index, strip in
                Button { select(strip.id) } label: {
                    HStack {
                        Circle().fill(Color(red: strip.color.red, green: strip.color.green, blue: strip.color.blue)).frame(width: 7, height: 7)
                        Text(strip.name == "Ch \(index + 1)" ? strip.name : "Ch \(index + 1) \(strip.name)").lineLimit(1)
                        Spacer()
                        if selectedID == strip.id { Image(systemName: "checkmark") }
                    }.padding(5).background(selectedID == strip.id ? Color.orange.opacity(0.25) : Color.white.opacity(0.08)).cornerRadius(4)
                        .frame(maxWidth: .infinity, minHeight: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Route this layer to \(strip.name).")
                    .accessibilityIdentifier("output.channel.\(strip.id)")
            }
        }
    }
}
