import SwiftUI
import PlanariumMIDI
import PlanariumPresets

struct PerformanceSettingsView: View {
    @ObservedObject var footswitch: PanicFootswitchModel
    @ObservedObject var presets: PresetControlModel
    var sources: () -> [MIDITargetDescription]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Reopen last preset", isOn: $presets.reopenLastPreset)
                .help("Restore the last preset, scene and newer unsaved recovery on startup")
            Divider()
            Text("Panic Footswitch").font(.headline)
            Picker("MIDI source", selection: Binding(get: { footswitch.sourceID }, set: { footswitch.selectSource($0) })) {
                Text("None").tag(Int32(0))
                let available = sources()
                if footswitch.sourceID != 0 && !available.contains(where: { $0.id == footswitch.sourceID }) {
                    Text("Missing source (\(footswitch.sourceID))").tag(footswitch.sourceID)
                }
                ForEach(available, id: \.id) { source in Text(source.name).tag(source.id) }
            }
            HStack {
                Button { footswitch.learn() } label: { Image(systemName: "ear.badge.waveform") }.help("Learn the next Note On or controller press").disabled(footswitch.sourceID == 0)
                Button { footswitch.clear() } label: { Image(systemName: "trash") }.help("Clear the learned footswitch")
                Text(footswitch.status).accessibilityLabel("Footswitch status: \(footswitch.status)")
            }
            if let trigger = footswitch.trigger {
                Text("Channel \(Int(trigger.status & 0x0f) + 1) · \(trigger.status & 0xf0 == 0x90 ? "Note" : "CC") \(trigger.number)")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let notice = presets.notice { Text(notice).font(.caption).foregroundColor(.secondary) }
        }.padding(20).frame(minWidth: 300, idealWidth: 500, alignment: .leading)
    }
}
