import SwiftUI
import PlanariumApplication
import PlanariumAudio
import PlanariumDomain
import PlanariumMIDI
import SickPLSMonitorKit

struct MixerView: View {
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    @ObservedObject var audioUnits: AudioCatalogModel
    @ObservedObject var host: AudioHost
    @ObservedObject var midi: MIDIPortOwner
    let devices: AudioOutputDeviceControlModel
    var compact = false
    var display: PerformanceDisplayModel? = nil
    var meterReader: ChannelMeterReader? = nil
    @State private var deleting: UUID?
    @State private var renaming: UUID?
    @State private var draftName = ""
    @State private var failure: String?
    private var selectedStrip: UUID? { instrument.canvas.workspace.selectedLayer.routings.first?.target.stripID }
    var body: some View {
        VStack(spacing: 0) {
            MixerUtilityHeader(devices: devices, display: display, allowsChanges: !instrument.canvas.isPerformanceLocked)
            if !compact {
                HStack(spacing: 4) {
                    Text("MIXER").font(.system(size: StudioMaterials.labelSize, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    IconActionButton("Add channel", symbol: "plus") { perform { try instrument.addChannel() } }
                        .disabled(instrument.document.channels.count >= InstrumentDocument.maximumChannels)
                        .help("Add an empty channel. Up to eight channels are available.")
                        .accessibilityIdentifier("mixer.add")
                }.padding(6)
            }
            HStack(spacing: 0) {
                if !instrument.document.channels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(instrument.document.channels) { strip in
                                VStack(spacing: 0) {
                                    if let channelHost = host.host(for: strip.id) {
                                        ChannelStripView(spatialInstrument: instrument, audioUnits: audioUnits,
                                            host: channelHost, midiOutput: midi, audioDevices: devices,
                                            meterReader: strip.id == instrument.document.channels.first?.id ? meterReader : nil,
                                            compact: compact, stripID: strip.id)
                                    } else {
                                        VStack { Spacer(); Text("Preparing channel…").font(.caption); Spacer() }
                                    }
                                }
                                .frame(width: 72)
                                .overlay(Rectangle().stroke(selectedStrip == strip.id ? Color.orange : Color.clear, lineWidth: 2))
                                .contextMenu { channelContextMenu(strip) }
                                .accessibilityIdentifier("mixer.channel.\(strip.id)")
                            }
                        }.frame(maxHeight: .infinity)
                    }
                }
                SumChannelView(devices: devices, instrument: instrument, host: host, midi: midi).frame(width: 72)
            }
            if let failure { Text(failure).font(.caption).foregroundColor(.orange) }
        }
        .background(StudioMetalSurface(metal: .darkMetal))
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            VStack(spacing: 12) {
                Text("Rename channel")
                RenameEntryField(text: $draftName, isDraftBinding: true).onSubmit { commitChannelRename() }
                HStack {
                    Button("Cancel") { renaming = nil }
                    Button("Rename") {
                        commitChannelRename()
                    }
                }
            }.padding(20).frame(width: 280)
        }
        .alert("Delete channel?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let id = deleting { perform { try instrument.deleteChannel(id) } }
                deleting = nil
            }
        } message: { Text("Notes on this channel will be released. Layers keep their target and show missing channel until you choose another channel.") }
    }
    private func commitChannelRename() {
        guard instrument.authorize(.edit) else { return }
        if let id = renaming, var strip = instrument.document.channels.first(where: { $0.id == id }) {
            strip.name = draftName; instrument.updateChannel(strip)
        }
        renaming = nil
    }
    private func perform(_ work: () throws -> Void) {
        guard instrument.authorize(.edit) else { return }
        do { try work(); failure = nil } catch { failure = "Channel change rejected" }
    }
    private func colorButton(_ title: String, _ color: SpatialLayerColor, _ channel: InstrumentChannel) -> some View {
        SelectionMenuItem(title, selected: channel.color == color) {
            guard instrument.authorize(.edit) else { return }
            var channel = channel; channel.color = color; instrument.updateChannel(channel)
        }
    }
    @ViewBuilder func channelContextMenu(_ strip: InstrumentChannel) -> some View {
        if !instrument.canvas.isPerformanceLocked {
            Button("Rename…") { beginChannelRename(strip) }
            Menu("Color") {
                colorButton("Blue", .blue, strip)
                colorButton("Orange", .orange, strip)
                colorButton("Green", .green, strip)
                colorButton("Purple", .purple, strip)
            }
            Button("Duplicate") { perform { try instrument.duplicateChannel(strip.id) } }
                .disabled(instrument.document.channels.count >= InstrumentDocument.maximumChannels)
            Button("Delete") {
                guard instrument.authorize(.edit) else { return }
                if instrument.layersUsingChannel(strip.id) > 0 { deleting = strip.id }
                else { perform { try instrument.deleteChannel(strip.id) } }
            }
        }
    }
    func beginChannelRename(_ strip: InstrumentChannel) {
        guard instrument.authorize(.edit) else { return }
        renaming = strip.id; draftName = strip.name
    }
}

/// Native text-field focus selects the complete existing name on entry.
struct RenameEntryField: View {
    @Binding var text: String
    var title = "Name"
    var context = ""
    /// Confirmation sheets already own a draft; their button must see each keystroke.
    var isDraftBinding = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var draft = ""
    @State private var baseline: String?
    @FocusState private var focused: Bool
    @State private var entryIsVisible = false
    var body: some View {
        TextField(title, text: Binding(get: { draft }, set: {
            if baseline == nil { baseline = text }
            draft = $0
            if isDraftBinding { text = $0 }
        })).focused($focused)
            .onSubmit { commit() }
            .onExitCommand { discard(); focused = false }
            .onChange(of: focused) { if !$0 { commit() } }
            .onChange(of: text) { _ in discard() }
            .onChange(of: context) { _ in discard(); focused = false }
            .onChange(of: isEnabled) { if !$0 { discard(); focused = false } }
            .onAppear {
                entryIsVisible = true; discard()
                // The native name responder resigns during this update.
                // Focus the mounted field after that resignation has finished.
                DispatchQueue.main.async {
                    guard entryIsVisible else { return }
                    focused = true
                }
            }
            .onDisappear { entryIsVisible = false; focused = false }
            .accessibilityIdentifier("rename.name")
    }
    private func commit() {
        guard !isDraftBinding else { return }
        guard let baseline else { return }
        guard isEnabled, baseline == text else { discard(); return }
        let next = draft
        self.baseline = nil
        if next != text { text = next }
    }
    private func discard() { baseline = nil; draft = text }
}

struct SumChannelView: View {
    @ObservedObject var devices: AudioOutputDeviceControlModel
    @State private var showingOutput = false
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    @ObservedObject var host: AudioHost
    @ObservedObject var midi: MIDIPortOwner
    @State private var meter = ChannelMeterReader(master: true)
    private var level: Binding<Double> {
        Binding(get: { FaderLaw.position(forGain: pow(10, instrument.document.masterLevelDecibels / 20)) },
            set: { instrument.updateMasterLevel(max(-120, 20 * log10(max(0.000001, FaderLaw.gain(forPosition: $0))))) })
    }
    var body: some View {
        VStack(spacing: 0) {
            Text("SUM").font(.system(size: StudioMaterials.labelSize, weight: .semibold)).frame(height: 24)
        GeometryReader { geometry in
        VStack(spacing: 5) {
            VStack(spacing: 6) {
            Text("SUM").font(.system(size: StudioMaterials.labelSize, weight: .semibold)).foregroundColor(StudioMaterials.inkOnLight)
            AudioOutputStripButton(model: devices, showsDevice: true) {
                if !devices.audioIsRunning && instrument.authorize(.edit) { devices.startAudio() }
                showingOutput = true
            }.popover(isPresented: $showingOutput) {
                AudioOutputDeviceCardView(model: devices, allowsChanges: !instrument.canvas.isPerformanceLocked)
            }
            VStack(spacing: 4) {
            Menu {
                if !instrument.canvas.isPerformanceLocked {
                SelectionMenuItem("Virtual source", selected: (instrument.document.midiTarget?.uniqueID ?? 0) == 0) { instrument.selectMIDITarget(nil) }
                if let id = instrument.document.midiTarget?.uniqueID, id != 0, !midi.destinations.contains(where: { $0.id == id }) {
                    SelectionMenuItem("Unavailable MIDI \(id)", selected: true) {}.disabled(true)
                }
                ForEach(midi.destinations) { destination in
                    SelectionMenuItem(destination.name, selected: instrument.document.midiTarget?.uniqueID == destination.id) {
                        instrument.selectMIDITarget(.init(uniqueID: destination.id))
                    }
                }
                Button("Refresh devices") {
                    guard instrument.authorize(.edit) else { return }
                    midi.refresh()
                }
                } else {
                    Button("Editing is locked in Perform mode") { _ = instrument.authorize(.edit) }
                }
            } label: {
                FieldToolbarMenuLabel(title: "MIDI", symbol: "pianokeys").background(StudioPlastic())
            }.menuStyle(.borderedButton).background(StudioPlastic())
                .iconAccessibility("MIDI destination", caption: "MIDI")
                .help("Global MIDI destination for every layer and channel.")
                .accessibilityIdentifier("mixer.sum.midi")
            IconActionButton("Refresh MIDI devices", symbol: "arrow.clockwise") { midi.refresh() }
                .buttonStyle(.plain).help("Refresh MIDI devices").iconAccessibility("Refresh MIDI devices")
            }
            }.frame(height: MixerStripGrid.headerHeight(geometry.size.height), alignment: .top)
            Color.clear.frame(height: 32).inspectorLayoutProbe("mixer.rail.pan")
            Text(FaderLaw.decibelLabel(forPosition: level.wrappedValue)).font(.system(size: StudioMaterials.labelSize).monospacedDigit()).foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 18).background(StudioGlass()).inspectorLayoutProbe("mixer.rail.level")
            HStack(alignment: .bottom, spacing: 3) {
                LogicVerticalFader(value: level, showsOwnScale: false, onEditing: { editing in
                    if editing { instrument.beginContinuousEdit() } else { instrument.endContinuousEdit() }
                }, studioMaterial: true).frame(width: 27, height: MixerStripGrid.faderHeight(geometry.size.height))
                LiveHelmutStereoMeter(left: { 0 }, right: { 0 }, isRunning: host.isRunning, host: host, providedReader: meter)
                    .frame(width: 26, height: MixerStripGrid.faderHeight(geometry.size.height))
            }
            .inspectorLayoutProbe("mixer.rail.fader")
            IconActionButton("PANIC", symbol: "exclamationmark.octagon.fill", emergencyFirstMouse: true, emergencyColors: StudioPanicCap.panicColors) { instrument.panicAll() }.frame(height: 36).padding(.top, MixerStripGrid.actionsGap).inspectorLayoutProbe("mixer.rail.actions")
                .accessibilityIdentifier("mixer.sum.panic")
                .help("Release all notes on all channels and MIDI outputs.")
            Color.clear.frame(height: 12)
            Text("Master").font(.system(size: StudioMaterials.labelSize)).foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 23).background(StudioGlass()).inspectorLayoutProbe("mixer.rail.name")
        }.frame(width: max(0, geometry.size.width - 10)).padding(.horizontal, 5).padding(.top, 8).padding(.bottom, 6)
            .background(StudioMetalSurface(metal: .lightAluminium))
            .frame(minHeight: geometry.size.height, alignment: .bottom)
        }
        }
        .background(StudioMetalSurface(metal: .darkMetal)).environment(\.studioMixer, true).accessibilityIdentifier("mixer.sum")
    }
}
