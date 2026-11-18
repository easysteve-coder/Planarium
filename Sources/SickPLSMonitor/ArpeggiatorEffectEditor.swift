import SwiftUI
import PlanariumDomain

struct ArpeggiatorEffectEditor: View {
    @Binding var effect: ArpeggiatorEffect
    var liveValues: [SpatialRoutingTarget: Double] = [:]
    var stripID: UUID = SpatialRoutingTarget.missingStripID
    var slotID: UUID = SpatialRoutingTarget.missingStripID
    var close: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Arpeggiator").font(.title2)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 24,height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help("Close Arpeggiator editor")
            }
            Text("PLANARIUM · MIDI FX").font(.caption).foregroundColor(.secondary)
            ForEach(ArpeggiatorModulationTarget.allCases, id: \.self) { parameter in
                if let value = liveValues[.midiEffectParameter(stripID: stripID, slotID: slotID, parameter: parameter)] {
                    Label("\(parameter.title)  \(liveText(parameter, value))", systemImage: "hand.raised")
                        .font(.caption).foregroundColor(HelmutChrome.purple)
                        .help("Live hand modulation; the editor value is unchanged")
                }
            }
            Text("Direction").font(.caption).foregroundColor(.secondary)
            Picker("Direction", selection: $effect.direction) {
                ForEach(ArpeggiatorEffect.Direction.allCases, id: \.self) { Text(directionName($0)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Picker("Rate", selection: $effect.rate) {
                ForEach(ArpeggiatorEffect.Rate.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Stepper("Octaves  \(effect.octaves)", value: $effect.octaves, in: 1...4)
            VStack(alignment: .leading) {
                DeferredControlSlider(value: $effect.gate, range: 10...100, defaultValue: 50, title: "Gate (%)")
                    .help("Length of each note relative to its step")
            }
            VStack(alignment: .leading) {
                DeferredControlSlider(value: $effect.swing, range: 0...75, defaultValue: 0, title: "Swing (%)")
                    .help("Swing applies to straight rates")
            }
            Toggle("As Played velocity", isOn: Binding(get: { effect.velocity == 0 }, set: { effect.velocity = $0 ? 0 : 100 }))
            if effect.velocity != 0 {
                Stepper("Velocity  \(effect.velocity)", value: $effect.velocity, in: 1...127)
            }
            Toggle("Sync to beat", isOn: $effect.syncToBeat).help("Wait for the next grid point instead of starting immediately")
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<16) { index in
                    RoundedRectangle(cornerRadius: 3).fill(index % 4 == 0 ? HelmutChrome.purple : HelmutChrome.controlRaised)
                        .frame(height: CGFloat(16 + (index % 4) * 12))
                }
            }.frame(height: 60).accessibilityHidden(true)
            Text("Hold / Toggle keeps the sequence running. Releasing the input ends all notes.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accentColor(HelmutChrome.purple).toggleStyle(ReadableCheckboxStyle()).padding(20).frame(minWidth: 360, idealWidth: 640)
    }
    private func liveText(_ parameter: ArpeggiatorModulationTarget, _ value: Double) -> String {
        if parameter == .rate { return ArpeggiatorEffect.Rate.allCases[Int(value)].rawValue }
        return String(format: "%.0f", value) + (parameter == .gate || parameter == .swing ? " %" : "")
    }
    private func directionName(_ direction: ArpeggiatorEffect.Direction) -> String {
        switch direction {
        case .up: return "Up"
        case .down: return "Down"
        case .upDown: return "Up/Down"
        case .random: return "Random"
        case .asPlayed: return "As Played"
        }
    }
}

/// Shared content of the inspector target menu and its offline presentation proof.
struct MIDIEffectTargetChoices: View {
    let channels: [InstrumentChannel]
    var apply: (SpatialRoutingTarget) -> Void
    var body: some View {
        ForEach(channels) { strip in
            ForEach(strip.midiEffects.filter { $0.kind == .arpeggiator }) { slot in
                ForEach(ArpeggiatorModulationTarget.allCases, id: \.self) { parameter in
                    Button("\(strip.name) · Arpeggiator · \(parameter.title)") {
                        apply(.midiEffectParameter(stripID: strip.id, slotID: slot.id, parameter: parameter))
                    }.help("Use measured hand distance to modulate \(parameter.title.lowercased())")
                }
            }
        }
    }
}
