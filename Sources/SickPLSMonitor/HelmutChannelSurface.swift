import AppKit
import Combine
import SwiftUI
import PlanariumAudio
import PlanariumApplication
import SickPLSMonitorKit
import PlanariumPresets
import PlanariumMIDI
import PlanariumDomain

// HELMUT R340 / Logic-orientierte Oberfläche. Fachzustand bleibt im
// vorhandenen Controller; diese Bausteine zeichnen ausschließlich dessen
// Kanal- und Inspector-Chrom. Inspector und Strip verwenden absichtlich
// exakt denselben Fader und damit denselben 17 × 35 pt großen Griff.

enum HelmutChrome {
    static let inspector = Color(red: 0.115, green: 0.118, blue: 0.130)
    static let strip = Color(red: 0.43, green: 0.43, blue: 0.44)
    static let gutter = Color(red: 0.075, green: 0.075, blue: 0.085)
    static let control = Color(red: 0.16, green: 0.165, blue: 0.18)
    static let controlRaised = Color(red: 0.22, green: 0.225, blue: 0.24)
    static let line = Color.white.opacity(0.10)
    static let primary = Color.white.opacity(0.90)
    static let secondary = Color.white.opacity(0.58)
    static let disabled = Color.white.opacity(0.34)
    static let meter = Color(red: 0.41, green: 0.82, blue: 0.48)
    static let midiFX = Color(red: 0.20, green: 0.62, blue: 0.66)
    static let purple = Color(red: 0.57, green: 0.31, blue: 0.75)
    static let blue = Color(red: 0.25, green: 0.43, blue: 0.72)
}

enum StudioEffectChoiceTarget: Hashable {
    case audioUnit(AudioUnitIdentity)
    case insert(UUID, AudioUnitIdentity)
    var identity: AudioUnitIdentity {
        switch self { case .audioUnit(let value), .insert(_, let value): return value }
    }
}

struct StudioEffectSlot: Identifiable {
    let id: Int
    let title: String
    let isOn: Bool
    let canToggle: Bool
    let target: StudioEffectChoiceTarget?
}

struct HelmutInspectorSurface: View {
    @Binding var master: Double
    let masterDB: String
    let audioIsRunning: Bool
    let editor: CanvasSession
    @ObservedObject var audioUnits: AudioCatalogModel
    @ObservedObject var midiOutput: MIDIPortOwner
    let spatialInstrument: SpatialInstrumentRuntimeModel

    var body: some View {
        StableSpatialLayerInspectorView(
            editor: editor,
            audioUnits: audioUnits,
            midiOutput: midiOutput,
            spatialInstrument: spatialInstrument,
            evaluationCounter: nil
        )
        .equatable()
    }
}

struct HelmutStripSurface: View {
    @Binding var master: Double
    @Binding var selectedEntry: ChannelStripEntry
    let audioIsRunning: Bool
    let audioSummary: String
    let midiSummary: String
    let effectSlots: [StudioEffectSlot]
    let audioUnitEffects: [AudioUnitEffectCandidate]
    let audioUnitInstruments: [AudioUnitInstrumentCandidate]
    let selectedAudioUnitInstrument: AudioUnitInstrumentCandidate?
    let isMuted: Bool
    let isSoloed: Bool
    let toggleMute: () -> Void
    let toggleSolo: () -> Void
    let instrumentIsOn: Bool
    let instrumentPreparation: AudioUnitInstrumentPreparationState
    let instrumentCanToggle: Bool
    let toggleInstrument: () -> Void
    let selectAudioUnitInstrument: (AudioUnitInstrumentIdentity?) -> Void
    let openAudioUnitInstrument: (AudioUnitInstrumentIdentity) -> Void
    let assignEffect: (Int, StudioEffectChoiceTarget?) -> Void
    let toggleEffect: (StudioEffectChoiceTarget) -> Void
    let openEffect: (StudioEffectChoiceTarget) -> Void
    // Preview fixtures supply samples; production uses meterHost below.
    var outputLeftPeak: () -> Double = { 0 }
    var outputRightPeak: () -> Double = { 0 }
    @Binding var channelName: String
    @Binding var channelColor: Color
    let pan: Double
    let setPan: (Double) -> Void
    let midiDestinations: [MIDITargetDescription]?
    let selectedMIDIDestinationID: Int32?
    let selectMIDIDestination: (Int32?) -> Void
    let refreshMIDIDestinations: () -> Void
    let midiNotice: String?
    @ObservedObject var audioDevices: AudioOutputDeviceControlModel
    var meterHost: AudioHost? = nil
    var meterReader: ChannelMeterReader? = nil
    var onContinuousEditing: (Bool) -> Void = { _ in }
    var compact = false
    var channelNumber = 1
    var authoringAllowed: () -> Bool = { true }
    var performanceLocked = false
    var instrumentUnavailable = false
    var midiEffectsView: AnyView = AnyView(EmptyView())
    var sendALevelDecibels = -120.0
    var sendBLevelDecibels = -120.0
    @State private var isEditingChannelName = false
    @State private var outputCardIsPresented = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 5) {
            ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 5) {
            midiEffectsView
            StudioInsertRow(
                title: instrumentTitle,
                accessibilityBase: "strip.instrument",
                tint: selectedAudioUnitInstrument == nil ? HelmutChrome.controlRaised : HelmutChrome.purple,
                isOn: instrumentIsOn, canToggle: instrumentCanToggle,
                canOpen: selectedAudioUnitInstrument != nil,
                toggle: toggleInstrument, open: openInstrument,
                choices: instrumentChoices, readOnly: performanceLocked
            )
            ForEach(effectSlots) { slot in
                StudioInsertRow(
                    title: slot.title, accessibilityBase: "strip.fx.\(slot.id)",
                    tint: slot.target == nil ? HelmutChrome.controlRaised : HelmutChrome.blue,
                    isOn: slot.isOn,
                    canToggle: slot.canToggle,
                    canOpen: slot.target != nil,
                    toggle: { if let target = slot.target { toggleEffect(target) } },
                    open: { if let target = slot.target { openEffect(target) } },
                    choices: effectChoices(for: slot.id, selected: slot.target), readOnly: performanceLocked
                )
            }
            PreparedSendControls(a: sendALevelDecibels, b: sendBLevelDecibels)
            mainButton
            if !compact {
            if let destinations = midiDestinations {
                Menu {
                    SelectionMenuItem("Virtual source", selected: selectedMIDIDestinationID == nil) {
                        selectMIDIDestination(nil)
                    }
                    if let id = selectedMIDIDestinationID, !destinations.contains(where: { $0.id == id }) {
                        SelectionMenuItem("Unavailable MIDI \(id)", selected: true) {}.disabled(true)
                    }
                    ForEach(destinations) { destination in
                        SelectionMenuItem(destination.name, selected: selectedMIDIDestinationID == destination.id) { selectMIDIDestination(destination.id) }
                    }
                    Divider()
                    Button("Refresh devices") { refreshMIDIDestinations() }
                } label: {
                    Text(
                        destinations.first { $0.id == selectedMIDIDestinationID }?.name
                            ?? "Virtual source"
                    )
                    .font(.system(size: StudioMaterials.labelSize, weight: .semibold))
                    .lineLimit(1)

                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(HelmutChrome.control)
                    .cornerRadius(3)
                }
                .background(StudioPlastic())
                .accessibilityIdentifier("strip.midi.destination")
                .help("Choose the MIDI destination, or use the virtual source.")
                if let notice = midiNotice {
                    Text(notice)
                        .font(.system(size: StudioMaterials.labelSize)).foregroundColor(StudioMaterials.inkOnLight)
                        .lineLimit(2)
                }
            }
            }
            }
            }.frame(height: MixerStripGrid.headerHeight(geometry.size.height), alignment: .top)
            HelmutPanKnob(pan: pan, setPan: setPan, diameter: 32, onEditing: onContinuousEditing, studioMaterial: true)
                .frame(height: 32).inspectorLayoutProbe("mixer.rail.pan")
            Text(FaderLaw.decibelLabel(forPosition: master))
                .font(.system(size: StudioMaterials.labelSize, weight: .semibold).monospacedDigit())
                .foregroundColor(HelmutChrome.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 18)
                .background(StudioGlass()).inspectorLayoutProbe("mixer.rail.level")
            HStack(alignment: .bottom, spacing: ChannelStripLayout.faderRowSpacing) {
                HelmutFaderScale()
                    .frame(width: ChannelStripLayout.faderScaleWidth, height: MixerStripGrid.faderHeight(geometry.size.height))
                LogicVerticalFader(value: $master, showsOwnScale: false, onEditing: onContinuousEditing, studioMaterial: true)
                    .frame(width: ChannelStripLayout.faderWidth, height: MixerStripGrid.faderHeight(geometry.size.height))
                LiveHelmutStereoMeter(left: outputLeftPeak, right: outputRightPeak, isRunning: audioIsRunning, host: meterHost, providedReader: meterReader)
                    .frame(width: ChannelStripLayout.meterWidth, height: MixerStripGrid.faderHeight(geometry.size.height))
            }
            .inspectorLayoutProbe("mixer.rail.fader")
            HStack(spacing: 4) {
                HelmutChannelButton("M", isOn: isMuted, activeColor: .orange,
                                    help: "Mute or unmute this channel", action: toggleMute)
                HelmutChannelButton("S", isOn: isSoloed, activeColor: .yellow,
                                    help: "Solo this channel without changing its level", action: toggleSolo)
            }
            .frame(height: 36).padding(.top, MixerStripGrid.actionsGap).inspectorLayoutProbe("mixer.rail.actions")
            Text(String(format: "%02d", channelNumber))
                .font(.system(size: StudioMaterials.labelSize, weight: .semibold).monospacedDigit())
                .foregroundColor(StudioMaterials.secondaryInk).frame(height: 12)
                    channelNameField.inspectorLayoutProbe("mixer.rail.name")
                }
                .frame(width: max(0, geometry.size.width - 10))
                .padding(.horizontal, 5)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .background(StudioMetalSurface(metal: .lightAluminium))
                // Owner 20.10.2026: strips sit flush with the lower window edge.
                .frame(minHeight: geometry.size.height, alignment: .bottom)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(StudioMetalSurface(metal: .darkMetal))
        .environment(\.studioMixer, true)
        .foregroundColor(HelmutChrome.primary)
        .accessibilityIdentifier("channel.strip")
        .accessibilityValue("Audio \(audioSummary), MIDI \(midiSummary)")
        .onChange(of: performanceLocked) { if $0 { isEditingChannelName = false } }
    }

    private var instrumentTitle: String {
        guard let name = selectedAudioUnitInstrument?.name else { return instrumentUnavailable ? "Unavailable instrument" : "—" }
        switch instrumentPreparation {
        case .preparing: return "\(name) …"
        case .prepared: return name
        case .failed: return "\(name) !"
        case .empty, .selected: return name
        }
    }

    private var mainButton: some View {
        AudioOutputStripButton(model: audioDevices) {
            selectedEntry = .audioOutput
            if !audioDevices.audioIsRunning && authoringAllowed() {
                audioDevices.startAudio()
            }
            outputCardIsPresented = true
        }
        .popover(isPresented: $outputCardIsPresented, arrowEdge: .trailing) {
            AudioOutputDeviceCardView(model: audioDevices, allowsChanges: !performanceLocked)
        }
    }

    private var channelNameField: some View {
        Group {
            if isEditingChannelName {
                RenameEntryField(text: Binding(get: { channelName }, set: { name in
                    guard authoringAllowed() else { return }
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { channelName = value }
                }), title: "Channel name")
                    .textFieldStyle(.plain)
                    .disabled(performanceLocked)
                    .onSubmit { isEditingChannelName = false }
                    .onExitCommand { isEditingChannelName = false }
            } else {
                Text(channelName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 23)
            }
        }
        .font(.system(size: StudioMaterials.labelSize, weight: .semibold))
        .foregroundColor(.white)
        .frame(maxWidth: .infinity).frame(height: 23)
        .background(StudioGlass()).overlay(alignment: .bottom) { channelColor.frame(height: 2).allowsHitTesting(false) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginChannelNameEdit() }
        .contextMenu {
            if !performanceLocked {
            Button("Rename…") { beginChannelNameEdit() }
            Menu("Color…") {
                channelColorButton("Default", .blue)
                channelColorButton("Amber", .orange)
                channelColorButton("Green", .green)
                channelColorButton("Violet", .purple)
            }
            }
        }
    }

    private func beginChannelNameEdit() {
        guard authoringAllowed() else { return }
        isEditingChannelName = true
    }

    private func channelColorButton(_ title: String, _ color: SpatialLayerColor) -> some View {
        SelectionMenuItem(title, selected: StageTheme.sameColor(channelColor, Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))) {
            guard authoringAllowed() else { return }
            channelColor = Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
        }
    }

    private var instrumentChoices: [StudioInsertChoice] {
        let ids = StudioInsertChoiceIDs.instrument(audioUnitInstruments)
        let unavailable = instrumentUnavailable ? [StudioInsertChoice(id: "unavailable-instrument", title: "Unavailable instrument", selected: true, action: {})] : []
        return unavailable + [StudioInsertChoice(id: ids[0], title: "Empty", selected: selectedAudioUnitInstrument == nil && !instrumentUnavailable, action: { selectAudioUnitInstrument(nil) })]
            + zip(audioUnitInstruments, ids.dropFirst()).map { instrument, id in
                StudioInsertChoice(
                    id: id,
                    title: "\(instrument.manufacturerName) · \(instrument.name)",
                    selected: instrument.identity == selectedAudioUnitInstrument?.identity,
                    action: { selectAudioUnitInstrument(instrument.identity) }
                )
            }
    }

    private func openInstrument() {
        guard let instrument = selectedAudioUnitInstrument else { return }
        selectedEntry = .synth
        openAudioUnitInstrument(instrument.identity)
    }

    private func effectChoices(for slot: Int, selected: StudioEffectChoiceTarget?) -> [StudioInsertChoice] {
        let ids = StudioInsertChoiceIDs.effects(slot: slot, audioUnitEffects)
        let missing = selected != nil && !audioUnitEffects.contains { $0.identity == selected?.identity }
        let unavailable = missing ? [StudioInsertChoice(id: "unavailable-\(slot)", title: "Unavailable insert", selected: true, action: {})] : []
        return unavailable + [
            StudioInsertChoice(id: ids[0], title: "Empty", selected: selected == nil, action: { assignEffect(slot, nil) })
        ] + zip(audioUnitEffects, ids.dropFirst()).map { effect, id in
            let target = StudioEffectChoiceTarget.audioUnit(effect.identity)
            return StudioInsertChoice(
                id: id,
                title: "\(effect.manufacturerName) · \(effect.name)", selected: selected?.identity == target.identity,
                action: { assignEffect(slot, target) }
            )
        }
    }

}

/// Gemeinsamer M/S-Schalter für Kanalzug und Ebenenliste. Die Ebenenansicht
/// kopiert weder Farbe noch Form, damit Solo überall gleich aussieht.
struct HelmutChannelButton: View {
    let title: String
    let isOn: Bool
    let activeColor: Color
    let help: String
    let action: () -> Void

    init(
        _ title: String, isOn: Bool, activeColor: Color,
        help: String, action: @escaping () -> Void
    ) {
        self.title = title
        self.isOn = isOn
        self.activeColor = activeColor
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            FieldToolbarIconLabel(title: title == "M" ? "Mute" : "Solo", symbol: title == "M" ? "speaker.slash" : "headphones")
                .font(.system(size: StudioMaterials.labelSize, weight: .semibold))
                .foregroundColor(isOn ? StageTheme.readableInk(on: activeColor) : .white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 21)
                .cornerRadius(3)
        }
        .buttonStyle(StudioKeyStyle(tint: isOn ? activeColor : HelmutChrome.controlRaised, active: isOn))
        .help(help)
        .buttonLayoutRole(help,font: 10,foreground: isOn ? StageTheme.readableInk(on: activeColor) : .white,background: isOn ? activeColor : HelmutChrome.controlRaised)
        .iconAccessibility(help, caption: title == "M" ? "Mute" : "Solo")
        .accessibilityValue(isOn ? "on" : "off")
    }
}

/// HELMUT R315: in Ruhe ein Name; im Hover drei unveränderte Teilflächen
/// (18 pt / Rest / 18 pt) für ON/OFF, Editor und Auswahl.
struct StudioInsertChoice: Identifiable {
    let id: String
    let title: String
    let selected: Bool
    let action: () -> Void
}

enum StudioInsertChoiceIDs {
    static func instrument(_ instruments: [AudioUnitInstrumentCandidate]) -> [String] {
        ["empty-instrument"] + instruments.map { "instrument-\($0.identity.displayCode)" }
    }

    static func effects(slot: Int, _ effects: [AudioUnitEffectCandidate]) -> [String] {
        ["empty-effect-\(slot)"] + effects.map { "effect-\(slot)-\($0.identity.displayCode)" }
    }
}

struct StudioInsertRow: View {
    private enum Part { case power, editor, choice }

    let title: String
    let accessibilityBase: String
    let tint: Color
    let isOn: Bool
    let canToggle: Bool
    let canOpen: Bool
    let toggle: () -> Void
    let open: () -> Void
    let choices: [StudioInsertChoice]
    var readOnly = false
    var controlsAreVisibleForPreview = false

    @State private var hoveredPart: Part?
    @State private var isHovered = false

    private var hovering: Bool { isHovered || controlsAreVisibleForPreview }

    var body: some View {
        Group {
            if readOnly {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: StudioMaterials.labelSize, weight: .semibold)).lineLimit(2)
                    Image(systemName: "lock.fill").font(.system(size: StudioMaterials.labelSize)).accessibilityLabel("Locked")
                    Text(isOn ? "on" : "off").font(.system(size: StudioMaterials.labelSize)).fixedSize()
                }
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(StudioPlastic(tint: isOn ? tint : HelmutChrome.controlRaised, pressed: !isOn))
                    .cornerRadius(3)
                    .accessibilityIdentifier("\(accessibilityBase).read-only")
                    .accessibilityValue(isOn ? "on" : "off")
                    .help(title + (isOn ? " · on · " : " · off · ") + "Locked in Perform mode · ⌘⇧P to edit")
            } else { editableRow }
        }.help(title).inspectorLayoutProbe("mixer.slot." + accessibilityBase)
            .foregroundColor(.white).buttonLayoutRole(title, font: 10, foreground: .white, background: isOn ? tint : HelmutChrome.controlRaised, group: accessibilityBase)
    }
    private var editableRow: some View {
        ZStack {
            HStack(spacing: 0) {
                Button(action: toggle) { part("power", .power, width: 20) }
                    .buttonStyle(StudioSlotPartStyle())
                    .disabled(!canToggle)
                    .iconAccessibility("Toggle \(title)", caption: "On")
                    .accessibilityIdentifier("\(accessibilityBase).power")
                    .help(isOn ? "Turn this insert off." : "Turn this insert on.")
                Button(action: open) { part("slider.horizontal.3", .editor, width: nil) }
                    .buttonStyle(StudioSlotPartStyle())
                    .disabled(!canOpen)
                    .iconAccessibility("\(title) settings", caption: "Edit")
                    .accessibilityIdentifier("\(accessibilityBase).editor")
                    .help("Open the settings for \(title).")
                Menu {
                    if choices.isEmpty {
                        Text("No Audio Units found")
                    } else {
                        ForEach(choices) { choice in
                            SelectionMenuItem(choice.title, selected: choice.selected, choose: choice.action)
                        }
                    }
                } label: {
                    part("chevron.up.chevron.down", .choice, width: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20, height: 30)
                .contentShape(Rectangle())
                .iconAccessibility("Choose insert", caption: "AU")
                .accessibilityIdentifier("\(accessibilityBase).choice")
                .help("Choose an instrument or effect for this insert.")
            }
            if !hovering {
                Text(title)
                    .font(.system(size: StudioMaterials.labelSize, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(StudioPlastic(tint: isOn ? tint : HelmutChrome.controlRaised, pressed: !isOn))
        .foregroundColor(.white)
        .overlay { hoverDividers }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onHover { inside in
            isHovered = inside
            if !inside { hoveredPart = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(isOn ? "on" : "off")
    }

    private func part(_ symbol: String, _ part: Part, width: CGFloat?) -> some View {
        Group {
            if hovering {
                // Owner 21.10.2026: hover shows icons only, no captions.
                Image(systemName: symbol).font(.system(size: 9))
            } else {
                Color.clear
            }
        }
        .frame(width: width ?? 18, height: 30)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(hoveredPart == part ? Color.white.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredPart = part }
            else if hoveredPart == part { hoveredPart = nil }
        }
    }

    @ViewBuilder
    private var hoverDividers: some View {
        if hovering {
            Canvas { context, size in
                for x in [CGFloat(18), size.width - 18] {
                    context.fill(
                        Path(CGRect(x: x - 0.5, y: 0, width: 0.5, height: size.height)),
                        with: .color(Color.white.opacity(0.34))
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }

}

/// Keeps its chosen color while a plug-in window has the focus: system prominent
/// buttons turn grey in inactive windows, an emergency control must not.
struct PanicButtonStyle: ButtonStyle {
    var pressed = false
    var colors = StudioPanicCap.stopColors
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed || pressed ? 1 : 0)
            .font(.system(size: StudioMaterials.labelSize, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4).padding(.vertical, 4)
            .frame(minWidth: 20, minHeight: 20)
            .background(StudioPanicCap(pressed: configuration.isPressed || pressed, colors: colors))
            .contentShape(Rectangle())
    }
}

struct HelmutMeter: View {
    let level: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.38))
            Self.gradient.mask(HelmutMeterFill(level: level)).padding(1)
        }
    }

    static let gradient = LinearGradient(
        stops: MeterLaw.colorStops.map {
            .init(color: color($0.zone), location: MeterLaw.position(forDecibels: $0.decibels))
        },
        startPoint: .bottom, endPoint: .top
    )

    static func color(_ zone: MeterLaw.Zone) -> Color {
        switch zone {
        case .safe: return HelmutChrome.meter
        case .warning: return .orange
        case .over: return .red
        }
    }
}

/// Shape receives the existing layout rectangle while drawing; live levels
/// do not reconstruct a GeometryReader or trigger a layout measurement.
private struct HelmutMeterFill: Shape {
    let level: Double
    func path(in rect: CGRect) -> Path {
        let height = rect.height * max(0, min(1, level))
        return Path(CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height))
    }
}

struct LiveHelmutStereoMeter: View {
    @Environment(\.studioMixer) private var studioMixer
    @StateObject private var ownedReader = ChannelMeterReader()
    @State private var previewClip = MeterClipState()
    let left: () -> Double
    let right: () -> Double
    let isRunning: Bool
    let host: AudioHost?
    let providedReader: ChannelMeterReader?
    var body: some View {
        Group {
            if let host {
                HostedStereoMeter(reader: providedReader ?? ownedReader, host: host)
            } else {
                HelmutStereoMeterSample(left: isRunning ? left() : 0, right: isRunning ? right() : 0, clip: $previewClip)
            }
        }.background { if studioMixer { StudioGlass() } }.help("Live level after the fader, in dBFS. The red overload indicator clears itself after \(Int(MeterClipState.holdSeconds)) s; click to clear it at once.")
    }
}
struct HostedStereoMeter: View {
    let reader: ChannelMeterReader
    @Environment(\.presentationVisible) private var presentationVisible
    let host: AudioHost
    @State private var viewer = UUID()
    var body: some View {
        VStack(spacing: 2) {
            HostedMeterClip(reader: reader)
            HStack(spacing: 1) {
                HelmutMeterScale().equatable().frame(width: ChannelStripLayout.meterLabelWidth)
                HostedMeterBars(reader: reader)
                    .frame(minWidth: 2 * ChannelStripLayout.meterBarMinimumWidth + 1)
            }
        }
            .onAppear { reader.setVisible(presentationVisible); reader.start(host, viewer: viewer) }
            .onChange(of: presentationVisible) { reader.setVisible($0) }
            .onDisappear { reader.stop(viewer: viewer) }
    }
}
private struct HostedMeterClip: View {
    let reader: ChannelMeterReader
    @State private var clipped = false
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("meter.clip")
        Button { reader.resetClip() } label: {
            Rectangle().fill(clipped ? Color.red : Color.black.opacity(0.38)).frame(height: 5).frame(minWidth: 20,minHeight: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Reset overload indicator.")
            .accessibilityLabel("Reset overload indicator")
            .onReceive(reader.$clip.map(\.isClipped).removeDuplicates()) { clipped = $0 }
    }
}
/// Live bars drawn natively: a 30-Hz level change marks only this view for
/// display instead of laying out the window's SwiftUI host.
private struct HostedMeterBars: NSViewRepresentable {
    let reader: ChannelMeterReader
    @MainActor final class Coordinator {
        private var source: ObjectIdentifier?
        private var subscription: AnyCancellable?
        /// Uses the delivered value: `@Published` emits before it assigns.
        func observe(_ reader: ChannelMeterReader, view: MeterBarsView) {
            guard source != ObjectIdentifier(reader) else { return }
            source = ObjectIdentifier(reader)
            view.peaks = reader.peaks
            subscription = reader.$peaks.dropFirst().sink { [weak view] peaks in
                MainActor.assumeIsolated {
                    ViewEvaluationProbe.current?.record("meter")
                    view?.peaks = peaks
                }
            }
        }
        func cancel() { subscription = nil; source = nil }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MeterBarsView { MeterBarsView() }
    func updateNSView(_ view: MeterBarsView, context: Context) {
        ViewEvaluationProbe.current?.record("meter")
        context.coordinator.observe(reader, view: view)
    }
    static func dismantleNSView(_ view: MeterBarsView, coordinator: Coordinator) { coordinator.cancel() }
}

/// Two bars in one CoreGraphics pass, visually equal to `HelmutMeter`:
/// dark rounded well, zone gradient masked from the bottom, 1-pt inset.
@MainActor final class MeterBarsView: NSView {
    var peaks = StereoPeaks() {
        didSet { if peaks != oldValue { needsDisplay = true } }
    }
    private static let well = NSColor(Color.black.opacity(0.38)).cgColor
    private static let gradient: CGGradient = {
        let stops = MeterLaw.colorStops
        let colors = stops.map { NSColor(HelmutMeter.color($0.zone)).usingColorSpace(.sRGB)?.cgColor ?? NSColor.green.cgColor }
        let locations = stops.map { CGFloat(MeterLaw.position(forDecibels: $0.decibels)) }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    }()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// `.onSetNeedsDisplay` does not redraw on resize; a constant level must
    /// not leave the old bars stretched.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
    private(set) var drawCount = 0
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawCount += 1
        let width = max(0, (bounds.width - 1) / 2)
        for (index, gain) in [peaks.left, peaks.right].enumerated() {
            let bar = CGRect(x: CGFloat(index) * (width + 1), y: 0, width: width, height: bounds.height)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 1, cornerHeight: 1, transform: nil))
            context.setFillColor(Self.well); context.fillPath()
            let inner = bar.insetBy(dx: 1, dy: 1)
            let level = CGFloat(max(0, min(1, MeterLaw.position(forGain: Double(gain)))))
            guard level > 0, inner.width > 0, inner.height > 0 else { continue }
            context.saveGState()
            // Unflipped view: y grows upwards, the fill starts at the bottom.
            context.clip(to: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * level))
            context.drawLinearGradient(Self.gradient, start: CGPoint(x: inner.midX, y: inner.minY),
                                       end: CGPoint(x: inner.midX, y: inner.maxY), options: [])
            context.restoreGState()
        }
    }
}
private struct HelmutMeterScale: View, Equatable {
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("meter.scale")
        GeometryReader { geometry in
            ForEach(MeterLaw.scaleDecibels, id: \.self) { decibels in
                Text(String(-decibels)).font(.system(size: 6).monospacedDigit())
                    .foregroundColor(HelmutChrome.secondary)
                    .position(x: geometry.size.width/2,
                        y: 3+(geometry.size.height-6)*(1-MeterLaw.position(forDecibels: Double(decibels))))
            }
        }
    }
}
struct HelmutStereoMeterSample: View {
    let left: Double
    let right: Double
    @Binding var clip: MeterClipState
    var observesPeaks = true
    var body: some View {
        VStack(spacing: 2) {
            Button { clip.reset() } label: {
                Rectangle().fill(clip.isClipped ? Color.red : Color.black.opacity(0.38)).frame(height: 5).frame(minWidth: 20,minHeight: 20).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Reset overload indicator.")
                .accessibilityLabel("Reset overload indicator")
            HStack(spacing: 1) {
                HelmutMeterScale().equatable().frame(width: ChannelStripLayout.meterLabelWidth)
                HelmutMeter(level: MeterLaw.position(forGain: left))
                    .frame(minWidth: ChannelStripLayout.meterBarMinimumWidth)
                HelmutMeter(level: MeterLaw.position(forGain: right))
                    .frame(minWidth: ChannelStripLayout.meterBarMinimumWidth)
            }
        }
        .onAppear { if observesPeaks { clip.observe(peak: max(left,right)) } }
        .onChange(of: max(left,right)) { if observesPeaks { clip.observe(peak: $0) } }
    }
}

/// Echter Pan-Regler des Instrumentkanals: vertikal ziehen, Doppelklick
/// stellt auf Mitte. Anzeige und Zugmathematik kommen aus `PanDisplay`.
struct HelmutPanKnob: View {
    let pan: Double
    let setPan: (Double) -> Void
    let diameter: CGFloat
    var onEditing: (Bool) -> Void = { _ in }
    var studioMaterial = false
    @StateObject var drag = ControlDragSession()

    var body: some View {
        let shownPan = drag.displayed ?? pan
        ZStack {
            Circle().fill(Color.black.opacity(0.34))
            if studioMaterial {
                Circle().stroke(Color.black.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: [1, 2]))
                Circle().trim(from: 0.12, to: 0.88).stroke(StudioMaterials.secondaryInk, lineWidth: 1).rotationEffect(.degrees(90)).padding(-2)
            }
            Circle()
                .fill(LinearGradient(
                    colors: [Color(white: 0.36), Color(white: 0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .padding(diameter * 0.12)
                .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
            Capsule()
                .fill(Color.white.opacity(0.70))
                .frame(width: 1.5, height: diameter * 0.18)
                .offset(y: -diameter * 0.26)
                .rotationEffect(.degrees(PanDisplay.indicatorAngle(shownPan)))
            Text(PanDisplay.label(shownPan))
                .font(.system(size: max(studioMaterial ? 10 : 7, diameter * 0.23), weight: .medium).monospacedDigit())
                .foregroundColor(.white)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { event in
                    drag.begin(pan, write: setPan, editing: onEditing)
                    let translation = drag.translated(Double(event.translation.height), fine: NSEvent.modifierFlags.contains(.option))
                    drag.change(PanDisplay.dragged(startPan: drag.initial ?? pan, translationY: translation), live: true)
                }
                .onEnded { _ in drag.finish() }
        )
        .onDisappear { drag.cancel(); drag.finish() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { drag.cancel(); drag.finish(); setPan(0) })
        .modifier(ControlScrollAction { delta, fine in setPan(min(1, max(-1, pan + (delta > 0 ? 0.05 : -0.05) * (fine ? 0.1 : 1)))) })
        .help("Drag vertically to pan. Double-click to center.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pan")
        .accessibilityValue(PanDisplay.label(drag.displayed ?? pan))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setPan(min(pan + 0.05, 1))
            case .decrement: setPan(max(pan - 0.05, -1))
            @unknown default: break
            }
        }
    }
}

/// Aufgedruckte Faderskala aus `FaderLaw.scaleMarks`. Jede Marke sitzt auf
/// der Griffmitte genau der Stellung, die ihren dB-Wert setzt; die 35 pt
/// entsprechen der Griffhöhe von `LogicVerticalFader`.
private struct HelmutFaderScale: View {
    var body: some View {
        GeometryReader { geometry in
            let capHeight: CGFloat = 35
            let travel = max(1, geometry.size.height - capHeight)
            ForEach(FaderLaw.scaleMarks, id: \.dB) { mark in
                HStack(spacing: 1) {
                    Text(mark.label)
                        .font(.system(size: StudioMaterials.labelSize).monospacedDigit())
                        .foregroundColor(StudioMaterials.inkOnLight)
                        .lineLimit(1)
                        .fixedSize()
                    Rectangle().fill(StudioMaterials.secondaryInk).frame(width: 3, height: 1)
                }
                .frame(width: geometry.size.width, alignment: .trailing)
                .position(
                    x: geometry.size.width / 2,
                    y: capHeight / 2 + travel * CGFloat(1 - mark.position)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Gemeinsamer Inspector-/Strip-Fader. Der Griff entspricht dem richtigen
/// HELMUT-Strip-Griff: 17 × 35 pt, schmal hochkant, zwei Riffelzonen und
/// ein durchgehender dunkler Mittelindex.
struct LogicVerticalFader: View {
    @Binding var value: Double
    let showsOwnScale: Bool
    var onEditing: (Bool) -> Void = { _ in }
    var studioMaterial = false
    @StateObject var drag = ControlDragSession()

    var body: some View {
        GeometryReader { geometry in
            let capHeight: CGFloat = 35
            let travel = max(1, geometry.size.height - capHeight)
            // Draw from local drag state first.  Publishing the document and
            // audio value is coalesced by ControlDragSession, so a costly
            // channel update cannot leave the cap a mouse event behind.
            let clamped = max(0, min(1, drag.displayed ?? value))
            let y = travel * (1 - clamped)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.black.opacity(0.58))
                    .frame(width: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsOwnScale { tickLadder }
                LogicFaderCap(studioMaterial: studioMaterial)
                    .offset(y: y)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { event in
                        drag.begin(value, write: { value = $0 }, editing: onEditing)
                        let translation = drag.translated(Double(event.translation.height), fine: NSEvent.modifierFlags.contains(.option))
                        drag.change(FaderMath.dragged(startValue: drag.initial ?? value, translationY: translation, travel: Double(travel)), live: true)
                    }
                    .onEnded { _ in drag.finish() }
            )
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { drag.cancel(); drag.finish(); value = FaderLaw.unityPosition })
        .modifier(ControlScrollAction { delta, fine in
            value = min(1, max(0, value + (delta > 0 ? 0.01 : -0.01) * (fine ? 0.1 : 1)))
        })
        .onDisappear { drag.cancel(); drag.finish() }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .up: value = FaderMath.stepped(value, up: true)
            case .down: value = FaderMath.stepped(value, up: false)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .help("Adjust the master output level. 0 dB is unity gain.")
        .accessibilityLabel("Master fader")
        .accessibilityValue("\(FaderLaw.decibelLabel(forPosition: drag.displayed ?? value)) dB")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = FaderMath.stepped(value, up: true)
            case .decrement: value = FaderMath.stepped(value, up: false)
            @unknown default: break
            }
        }
    }

    private var tickLadder: some View {
        GeometryReader { geometry in
            ForEach(0..<25, id: \.self) { index in
                let major = index.isMultiple(of: 4)
                Rectangle()
                    .fill(Color.white.opacity(major ? 0.36 : 0.20))
                    .frame(width: major ? 8 : 5, height: 0.5)
                    .position(
                        x: geometry.size.width / 2 - (major ? 8 : 6),
                        y: 8 + CGFloat(index) * max(1, (geometry.size.height - 16) / 24)
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct LogicFaderCap: View {
    var studioMaterial = false
    private struct Band {
        let y: CGFloat
        let height: CGFloat
        let tone: Double
    }

    private static let bands: [Band] = {
        var result: [Band] = []
        for index in 0..<10 {
            result.append(Band(y: CGFloat(index) * 0.5, height: 0.5, tone: 0.82 + Double(index) * 0.008))
        }
        let tones = [0.624, 0.655, 0.694, 0.745, 0.796, 0.820, 0.839, 0.859, 0.875, 0.890]
        var y: CGFloat = 5
        for index in 0..<5 {
            result.append(Band(y: y, height: 2, tone: tones[index])); y += 2
            if index < 4 { result.append(Band(y: y, height: 0.5, tone: tones[index] - 0.09)); y += 0.5 }
        }
        result.append(Band(y: 17, height: 1, tone: 0.325))
        y = 18
        for index in 5..<10 {
            result.append(Band(y: y, height: 2, tone: tones[index])); y += 2
            if index < 9 { result.append(Band(y: y, height: 0.5, tone: tones[index] - 0.09)); y += 0.5 }
        }
        for index in 0..<10 {
            result.append(Band(y: 30 + CGFloat(index) * 0.5, height: 0.5, tone: 0.72 - Double(index) * 0.01))
        }
        return result
    }()

    var body: some View {
        Canvas { context, size in
            for band in Self.bands {
                context.fill(
                    Path(CGRect(x: 0, y: band.y, width: size.width, height: band.height)),
                    with: .color(Color(white: band.tone))
                )
            }
        }
        .frame(width: 17, height: 35)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.65), lineWidth: 0.5))
        .overlay(alignment: .topLeading) {
            if studioMaterial { Color.white.opacity(0.55).frame(width: 7, height: 1).padding(.leading, 2).allowsHitTesting(false) }
        }
        .shadow(color: .black.opacity(0.7), radius: 2, y: 3)
        .frame(maxWidth: .infinity)
    }
}


/// One vertical rail shared by every channel and SUM, independent of slot count.
enum MixerStripGrid {
    /// Owner 20.10.2026: compact strips. Slot area and fader travel keep
    /// their natural size; a taller window leaves the gutter below empty
    /// instead of stretching the fader or opening a gap inside the strip;
    /// the free space stays above the strips (flush with the window bottom).
    static let slotAreaHeight: CGFloat = 346
    static let faderTravel: CGFloat = 200
    /// Owner 21.10.2026: some air between fader and Mute/Solo/PANIC.
    static let actionsGap: CGFloat = 8
    // pan32 + level18 + actionsGap + actions36 + number12 + name23 + gaps30 + padding14.
    static let railBelowSlots: CGFloat = 165 + actionsGap
    /// Short windows shorten the fader (down to 120 pt) before anything scrolls.
    static func faderHeight(_ height: CGFloat) -> CGFloat {
        min(faderTravel, max(120, height - slotAreaHeight - railBelowSlots))
    }
    static func headerHeight(_ height: CGFloat) -> CGFloat { slotAreaHeight }
}


struct PreparedSendControls: View {
    let a: Double
    let b: Double
    var body: some View {
        VStack(spacing: 2) {
            send("A", a); send("B", b)
        }.help("Sends: in preparation").accessibilityIdentifier("mixer.sends.prepared")
    }
    private func send(_ name: String, _ decibels: Double) -> some View {
        VStack(spacing: 0) {
            Text("Send " + name + " · " + (decibels <= -120 ? "−∞" : String(format: "%.1f", decibels)))
                .font(.system(size: StudioMaterials.labelSize)).foregroundColor(StudioMaterials.inkOnLight).lineLimit(1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15)).frame(height: 3)
                Circle().fill(Color.white.opacity(0.5)).frame(width: 12,height: 12)
            }.frame(height: 20).accessibilityElement(children: .ignore)
                .accessibilityLabel("Send " + name + ": in preparation")

        }.help("Sends: in preparation")
    }
}
