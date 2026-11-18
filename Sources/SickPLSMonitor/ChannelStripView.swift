import AppKit
import SwiftUI
import PlanariumApplication
import PlanariumAudio
import PlanariumDomain
import PlanariumMIDI
import PlanariumPresets
import SickPLSMonitorKit

/// Every editable channel value belongs to the document. The displayed insert
/// list is derived from that value; loaded/bypass/error status comes from host.
struct ChannelStripView: View {
    @ObservedObject var spatialInstrument: SpatialInstrumentRuntimeModel
    @ObservedObject var audioUnits: AudioCatalogModel
    @ObservedObject var host: AudioHost
    @ObservedObject var midiOutput: MIDIPortOwner
    let audioDevices: AudioOutputDeviceControlModel
    var meterReader: ChannelMeterReader? = nil
    var compact = false
    var stripID: UUID? = nil
    @State private var showingChannelPresets = false
    @State private var editingMIDIEffect: UUID?
    @State private var selectedEntry: ChannelStripEntry = .pitch
    var channel: InstrumentChannel { spatialInstrument.document.channels.first { $0.id == (stripID ?? spatialInstrument.document.channel.id) } ?? .init() }
    var selectedInstrument: AudioUnitInstrumentCandidate? {
        guard let identity = channel.instrument?.identity else { return nil }
        return audioUnits.availableInstruments.first { $0.identity.componentSubType == identity.componentSubType && $0.identity.componentManufacturer == identity.componentManufacturer }
    }
    private func edit(_ change: (inout InstrumentChannel) -> Void) {
        var value = channel; change(&value); spatialInstrument.updateChannel(value)
    }
    /// A delayed text commit keeps its strip identity even after deletion.
    var channelNameBinding: Binding<String> {
        let id = stripID ?? spatialInstrument.document.channel.id
        return Binding(get: {
            spatialInstrument.document.channels.first { $0.id == id }?.name ?? ""
        }, set: { name in
            guard spatialInstrument.authorize(.edit),
                  var current = spatialInstrument.document.channels.first(where: { $0.id == id }) else { return }
            current.name = name; spatialInstrument.updateChannel(current)
        })
    }
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("channel")
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { showingChannelPresets = true } label: { Image(systemName: "folder").frame(width: 20,height: 20).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Channel presets").accessibilityLabel("Channel presets")
                    .disabled(spatialInstrument.canvas.isPerformanceLocked)
            }.padding(.horizontal, 6).frame(height: 24)
        HelmutStripSurface(master: level, selectedEntry: $selectedEntry,
                audioIsRunning: host.isRunning,
                audioSummary: host.isRunning ? "running" : "stopped", midiSummary: midiOutput.isRunning ? "on" : "off",
                effectSlots: slots, audioUnitEffects: audioUnits.availableEffects,
                audioUnitInstruments: audioUnits.availableInstruments, selectedAudioUnitInstrument: selectedInstrument,
                isMuted: channel.muted, isSoloed: channel.soloed,
                toggleMute: { edit { $0.muted.toggle() } }, toggleSolo: { edit { $0.soloed.toggle() } },
                instrumentIsOn: instrumentIsOn, instrumentPreparation: preparation,
                instrumentCanToggle: host.instrument != nil,
                toggleInstrument: { if host.isRunning { spatialInstrument.stopSpatialAudio() } else { spatialInstrument.startSpatialAudio() } },
                selectAudioUnitInstrument: { identity in
                    spatialInstrument.selectInstrument(identity.map { spatialIdentity(AudioUnitInstrumentIdentity.componentType, $0.componentSubType, $0.componentManufacturer) }, stripID: channel.id, editorTitle: identity.flatMap { id in audioUnits.availableInstruments.first(where: { $0.identity == id })?.name })
                }, openAudioUnitInstrument: { _ in
                    guard spatialInstrument.authorize(.edit) else { return }
                    host.instrument?.openEditor(title: selectedInstrument?.name ?? "Instrument")
                },
                assignEffect: assign, toggleEffect: toggle, openEffect: open,
                channelName: channelNameBinding,
                channelColor: Binding(get: { color(channel.color) }, set: { selected in
                    guard spatialInstrument.authorize(.edit) else { return }
                    let rgb = NSColor(selected).usingColorSpace(.deviceRGB) ?? .systemBlue
                    edit { $0.color = .init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent) }
                }), pan: channel.pan, setPan: { value in edit { $0.pan = value } },
                midiDestinations: nil, selectedMIDIDestinationID: nil,
                selectMIDIDestination: { _ in },
                refreshMIDIDestinations: {
                    guard spatialInstrument.authorize(.edit) else { return }
                    midiOutput.refresh()
                }, midiNotice: midiOutput.notice, audioDevices: audioDevices, meterHost: host, meterReader: meterReader, onContinuousEditing: { editing in
                    if editing { spatialInstrument.beginContinuousEdit() } else { spatialInstrument.endContinuousEdit() }
                }, compact: compact, channelNumber: (spatialInstrument.document.channels.firstIndex { $0.id == channel.id } ?? 0) + 1,
                authoringAllowed: { spatialInstrument.authorize(.edit) }, performanceLocked: spatialInstrument.canvas.isPerformanceLocked,
                instrumentUnavailable: channel.instrument != nil && selectedInstrument == nil,
                midiEffectsView: AnyView(midiEffects), sendALevelDecibels: channel.sendALevelDecibels, sendBLevelDecibels: channel.sendBLevelDecibels)
        }.sheet(isPresented: $showingChannelPresets) { ChannelPresetSheet(instrument: spatialInstrument, channelID: channel.id) }
        .sheet(isPresented: Binding(get: { editingMIDIEffect != nil }, set: { if !$0 { editingMIDIEffect = nil } })) {
            if let id = editingMIDIEffect, channel.midiEffects.contains(where: { $0.id == id }) {
                if channel.midiEffects.first(where: { $0.id == id })?.kind == .arpeggiator {
                    LiveArpeggiatorEffectEditor(display: spatialInstrument.arpeggiatorModulationDisplay, effect: Binding(get: { channel.midiEffects.first(where: { $0.id == id })?.arpeggiator ?? .init() }, set: { effect in
                        guard spatialInstrument.authorize(.edit) else { return }
                        edit { value in if let index = value.midiEffects.firstIndex(where: { $0.id == id }) { value.midiEffects[index].arpeggiator = effect } }
                    }), stripID: channel.id, slotID: id, close: { editingMIDIEffect = nil })
                } else {
                ChordEffectEditor(effect: Binding(get: { channel.midiEffects.first(where: { $0.id == id })?.chord ?? .init() }, set: { chord in
                    guard spatialInstrument.authorize(.edit) else { return }
                    edit { value in if let index = value.midiEffects.firstIndex(where: { $0.id == id }) { value.midiEffects[index].chord = chord } }
                }), close: { editingMIDIEffect = nil })
                }
            }
        }
                .frame(width: CGFloat(WorkspaceLayout.channelStripWidth))
                .frame(maxHeight: .infinity, alignment: .top)
    }
    private var midiEffects: some View {
        MIDIEffectSlotsView(slots: channel.midiEffects, ownerID: channel.id, revision: spatialInstrument.document.revision, locked: spatialInstrument.canvas.isPerformanceLocked,
            add: {
                guard spatialInstrument.authorize(.edit), channel.midiEffects.count < 4 else { return }
                let slot = InstrumentMIDIEffect(); edit { $0.midiEffects.append(slot) }; editingMIDIEffect = slot.id
            }, addArpeggiator: {
                guard spatialInstrument.authorize(.edit), channel.midiEffects.count < 4, !channel.midiEffects.contains(where: { $0.kind == .arpeggiator }) else { return }
                let slot = InstrumentMIDIEffect(arpeggiator: .init()); edit { $0.midiEffects.append(slot) }; editingMIDIEffect = slot.id
            }, toggle: { id in
                guard spatialInstrument.authorize(.edit) else { return }
                edit { value in if let index = value.midiEffects.firstIndex(where: { $0.id == id }) { value.midiEffects[index].bypassed.toggle() } }
            }, open: { id in if spatialInstrument.authorize(.edit) { editingMIDIEffect = id } }, remove: { id in
                guard spatialInstrument.authorize(.edit) else { return }
                edit { $0.midiEffects.removeAll { $0.id == id } }
            }, move: midiEffectMoveAction)
    }
    /// Capture the document revision and strip before the provider starts loading.
    /// Even undo or loading a preset with identical IDs invalidates that reply.
    var midiEffectMoveAction: (UUID, UUID) -> Void {
        let owner = spatialInstrument
        let revision = owner.document.revision
        let channelID = stripID ?? owner.document.channel.id
        return { id, target in
            guard owner.document.revision == revision, owner.authorize(.edit),
                  var value = owner.document.channels.first(where: { $0.id == channelID }),
                  id != target, let from = value.midiEffects.firstIndex(where: { $0.id == id }),
                  let to = value.midiEffects.firstIndex(where: { $0.id == target }) else { return }
            value.midiEffects.insert(value.midiEffects.remove(at: from), at: to)
            owner.updateChannel(value)
        }
    }

    private var level: Binding<Double> {
        Binding(get: { FaderLaw.position(forGain: pow(10, channel.levelDecibels / 20)) },
                set: { position in edit { $0.levelDecibels = max(-120, 20 * log10(max(0.000001, FaderLaw.gain(forPosition: position)))) } })
    }
    var preparation: AudioUnitInstrumentPreparationState {
        guard let identity = selectedInstrument?.identity else { return .empty }
        if host.graphFailure != nil { return .failed(identity) }
        switch host.status[.instrument] {
        case .loading: return .preparing(identity)
        case .loaded, .bypass: return .prepared(identity)
        case .failed: return .failed(identity)
        case nil: return .selected(identity)
        }
    }
    var instrumentIsOn: Bool { host.isRunning && host.status[.instrument] == .loaded }
    var slots: [StudioEffectSlot] {
        channel.inserts.enumerated().map { index, insert in
            let identity = try? AudioUnitIdentity.build(componentType: insert.plugin.identity.componentType, componentSubType: insert.plugin.identity.componentSubType, componentManufacturer: insert.plugin.identity.componentManufacturer)
            let name = audioUnits.availableEffects.first { $0.identity == identity }?.name ?? "Unavailable insert"
            let status = host.status[.insert(insert.id)]
            let failed: Bool
            if case .failed = status { failed = true } else { failed = false }
            let title = failed ? "\(name) !" : status == .loading ? "\(name) …" : name
            return .init(id: index, title: title, isOn: status == .loaded,
                         canToggle: host.inserts[insert.id] != nil, target: identity.map { .insert(insert.id, $0) })
        } + (channel.inserts.count..<max(4, channel.inserts.count + 1)).map {
            .init(id: $0, title: "—", isOn: false, canToggle: false, target: nil)
        }
    }
    private func assign(_ index: Int, _ target: StudioEffectChoiceTarget?) {
        guard spatialInstrument.authorize(.edit) else { return }
        let newID = UUID()
        edit { channel in
            if channel.inserts.indices.contains(index) { channel.inserts.remove(at: index) }
            if case .audioUnit(let identity) = target {
                channel.inserts.insert(.init(id: newID, plugin: .init(identity: spatialIdentity(identity.componentType, identity.componentSubType, identity.componentManufacturer))), at: min(index, channel.inserts.count))
            }
        }
        if case .audioUnit(let identity) = target {
            host.openEditorWhenLoaded(at: .insert(newID),
                identity: spatialIdentity(identity.componentType, identity.componentSubType, identity.componentManufacturer),
                title: audioUnits.availableEffects.first(where: { $0.identity == identity })?.name ?? "Insert",
                allowed: { [weak spatialInstrument] in spatialInstrument?.canvas.isPerformanceLocked == false })
        }
    }
    private func toggle(_ target: StudioEffectChoiceTarget) {
        guard spatialInstrument.authorize(.edit) else { return }
        guard case .insert(let id, _) = target else { return }
        let bypassed = host.status[.insert(id)] != .bypass
        edit { channel in
            if let index = channel.inserts.firstIndex(where: { $0.id == id }) { channel.inserts[index].bypassed = bypassed }
        }
        host.setInsertBypassFromStrip(id, bypassed: bypassed)
    }
    private func open(_ target: StudioEffectChoiceTarget) {
        guard spatialInstrument.authorize(.edit) else { return }
        guard case .insert(let id, _) = target else { return }
        host.instance(at: .insert(id))?.openEditor(title: slots.first(where: { $0.target == target })?.title ?? "Insert")
    }
    private func spatialIdentity(_ type: UInt32, _ sub: UInt32, _ manufacturer: UInt32) -> SpatialAudioUnitIdentity {
        .init(componentType: type, componentSubType: sub, componentManufacturer: manufacturer)
    }
    private func color(_ value: SpatialLayerColor) -> Color { .init(red: value.red, green: value.green, blue: value.blue, opacity: value.alpha) }
}

@MainActor private struct LiveArpeggiatorEffectEditor: View {
    @ObservedObject var display: ArpeggiatorModulationDisplay
    @Binding var effect: ArpeggiatorEffect
    let stripID: UUID
    let slotID: UUID
    let close: () -> Void
    var body: some View {
        ArpeggiatorEffectEditor(effect: $effect, liveValues: display.value.values,
            stripID: stripID, slotID: slotID, close: close)
    }
}
