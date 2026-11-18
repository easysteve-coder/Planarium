import SwiftUI
import AppKit
import PlanariumDomain
import PlanariumPresets
import PlanariumApplication

struct ChannelPresetSheet: View {
    let instrument: SpatialInstrumentRuntimeModel
    let channelID: UUID
    var presetStore: PresetFileStore? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String] = []
    @State private var selected = ""
    @State private var name = ""
    @State private var includeMix = true
    @State private var message = ""
    var store: PresetFileStore {
        if let presetStore { return presetStore }
        let base = PresetFileStore.standard().directory.deletingLastPathComponent()
        return PresetFileStore(directory: base.appendingPathComponent("ChannelPresets"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Channel presets").font(.headline)
            Text("Instrument, inserts, plugin states and bypass").font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Preset", selection: $selected) {
                Text("Choose…").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            TextField("New preset name", text: $name)
            Toggle("Include level and pan", isOn: $includeMix)
            if !message.isEmpty { Text(message).font(.caption).foregroundColor(.orange) }
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Save") { save() }.disabled(!PresetFileStore.isValidName(name))
                Button("Load") { load() }.disabled(selected.isEmpty)
            }
        }.padding(20).frame(minWidth: 300, idealWidth: 420)
            .onAppear { refresh() }
    }
    private func refresh() { do { names = try store.list() } catch { message = "Could not read channel presets" } }
    private func save() {
        do {
            guard instrument.authorize(.edit), let preset = try instrument.snapshotChannelPreset(channelID, name: name, includesLevelAndPan: includeMix) else { return }
            try store.save(ChannelPresetCodec.encode(preset), as: name)
            selected = name; message = "Saved"; refresh()
        } catch { message = "Could not save channel preset" }
    }
    private func load() {
        do {
            let preset = try ChannelPresetCodec.decode(store.load(selected))
            if try instrument.loadChannelPreset(preset, into: channelID) { dismiss() }
        } catch { message = "Could not load channel preset" }
    }
}

struct ImportPresetLayersSheet: View {
    let instrument: SpatialInstrumentRuntimeModel
    let source: InstrumentDocument
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var channelID: UUID? = nil
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import layers").font(.headline)
            Text("Copy layers and cell values. Source scenes stay in their preset.").font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Target channel", selection: $channelID) {
                Text("Match by name").tag(nil as UUID?)
                ForEach(instrument.document.channels) { Text($0.name).tag(Optional($0.id)) }
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(source.spatial.layers, id: \.id) { layer in
                        Toggle(layer.name, isOn: Binding(get: { selected.contains(layer.id) }, set: {
                            if $0 { selected.insert(layer.id) } else { selected.remove(layer.id) }
                        }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 220)
            Text("Unmatched output channels appear as missing channel.").font(.caption).fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty { Text(message).foregroundColor(.orange) }
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Import") {
                    do { if try instrument.importPresetLayers(source, ids: selected, channelID: channelID) { dismiss() } }
                    catch { message = "Could not import layers" }
                }.disabled(selected.isEmpty)
            }
        }.padding(20).frame(minWidth: 300, idealWidth: 420)
    }
}
