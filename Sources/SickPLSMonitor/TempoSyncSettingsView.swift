import SwiftUI
import PlanariumApplication
import PlanariumMIDI
import PlanariumDomain

struct TempoSyncSettingsView: View {
    @ObservedObject var workspace: WorkspaceControlModel
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    @ObservedObject var midi: MIDIPortOwner
    @ObservedObject private var clock: ClockDisplayState
    init(workspace: WorkspaceControlModel, instrument: SpatialInstrumentRuntimeModel, midi: MIDIPortOwner,
         sourceCatalog: @escaping () -> [MIDITargetDescription] = { [] }) {
        self.workspace = workspace; self.instrument = instrument; self.midi = midi
        self.sourceCatalog = sourceCatalog; clock = instrument.clockDisplay
    }
    var sourceCatalog: () -> [MIDITargetDescription] = { [] }
    @State private var sources: [MIDITargetDescription] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tempo & Sync").font(.title2)
            Text("Clock direction").font(.headline)
            Picker("Clock direction", selection: Binding(get: { workspace.preferences.clockDirection }, set: {
                guard instrument.authorize(.edit) else { return }
                workspace.setClockDirection($0)
                applyClockPreferences()
            })) {
                Text("Off").tag(ClockDirection.off)
                Text("Send").tag(ClockDirection.send)
                Text("Receive").tag(ClockDirection.receive)
            }.pickerStyle(.segmented).labelsHidden()
            if workspace.preferences.clockDirection == .receive {
                HStack {
                    Text("Clock source").font(.headline)
                    Spacer()
                    IconActionButton("Refresh MIDI sources", symbol: "arrow.clockwise") { sources = sourceCatalog() }
                }
                Picker("Source", selection: Binding<Int32?>(get: { workspace.preferences.clockSourceID }, set: { id in
                    guard instrument.authorize(.edit) else { return }
                    workspace.setClockSource(id, name: sources.first { $0.id == id }?.name)
                    applyClockPreferences()
                })) {
                    Text("None").tag(Int32?.none)
                    ForEach(sources.filter { $0.id != workspace.preferences.clockSourceID }) { source in Text(source.name).tag(Optional(source.id)) }
                    if let id = workspace.preferences.clockSourceID {
                        Text(selectedSourceTitle(id)).tag(Optional(id))
                    }
                }
                Text("Planarium follows one source · 24 clocks per beat\nStart / Continue / Stop control the clock transport only.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if clock.value.isLost { Text("External clock lost").foregroundColor(.orange) }
                Spacer(minLength: 0)
            } else {
                HStack {
                    Text("Clock destinations").font(.headline)
                    Spacer()
                    IconActionButton("Refresh MIDI destinations", symbol: "arrow.clockwise") { midi.refresh() }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(midi.destinations) { destination in
                            Toggle(destination.name, isOn: target(destination.id)).help("Independent of the note destination.")
                        }
                        ForEach(workspace.preferences.clockTargetIDs.filter { id in !midi.destinations.contains { $0.id == id } }, id: \.self) { id in
                            Toggle("Unavailable destination (\(id))", isOn: target(id)).foregroundColor(.secondary)
                        }
                        if midi.destinations.isEmpty { Text("No MIDI destinations available").foregroundColor(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 120)
                Text("24 clocks per beat · Start / Stop\nSelected destinations join at the next transport start. For MainStage, choose an IAC destination in Audio MIDI Setup.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("BPM is saved in the preset. Clock direction, destinations and source are saved on this Mac.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(minWidth: 360, idealWidth: 460, maxWidth: .infinity, minHeight: 360)
        .background(StageTheme.workspace).preferredColorScheme(.dark).tint(StageTheme.amber)
        .disabled(instrument.canvas.isPerformanceLocked)
        .onAppear { midi.refresh(); sources = sourceCatalog() }
    }
    private func target(_ id: Int32) -> Binding<Bool> {
        Binding(get: { workspace.preferences.clockTargetIDs.contains(id) }, set: {
            guard instrument.authorize(.edit) else { return }
            workspace.setClockTarget(id, selected: $0)
            applyClockPreferences()
        })
    }
    private func applyClockPreferences() {
        workspace.applyClockPreferences(to: instrument)
    }
    private func selectedSourceTitle(_ id: Int32) -> String {
        let name = sources.first { $0.id == id }?.name ?? workspace.preferences.clockSourceName ?? String(id)
        let available = instrument.clockSourceID == id && clock.value.isSourceAvailable
        return available ? name : "Unavailable · \(name)"
    }
}
