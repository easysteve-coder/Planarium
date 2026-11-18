import SwiftUI
import PlanariumDomain
import PlanariumApplication
import PlanariumInput
import PlanariumPresets
import SickPLSSimulationControl
import SickPLSMonitorKit

struct WorkspaceStatusView: View {
    let input: InputOwner
    let simulation: SimulationConnectionControlModel
    @ObservedObject var workspace: WorkspaceControlModel
    let presets: PresetControlModel
    let instrument: SpatialInstrumentRuntimeModel
    static var buildLabel: String { "Build \(PlanariumBuildIdentity.current.buildNumber)" }
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("header.buttons")
        GeometryReader { geometry in
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                WorkspaceInputStatusView(input: input, simulation: simulation, workspace: workspace)
                if workspace.mode != .perform || geometry.size.width >= 1200 {
                    WorkspaceDocumentStatusView(presets: presets, instrument: instrument)
                }
                TempoHeaderView(instrument: instrument)
                Button { OutputMonitorWindowController.shared.show() } label: {
                    InstrumentKeyboard(notes: Array(60..<72), labels: false).frame(width: 36, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Output Monitor (⌘⇧M)").accessibilityLabel("Output Monitor")
                ForEach([WorkspaceLayout.Area.setup, .layers, .cell, .channelStrip], id: \.self) { area in
                    Button { workspace.setVisible(area, !workspace.preferences.visibility[area]) } label: {
                        FieldToolbarIconLabel(title: area.rawValue == "channelStrip" ? "Strip" : area.rawValue.capitalized, symbol: symbol(area))
                        .frame(width: 36).frame(minHeight: 24)
                        .background(workspace.preferences.visibility[area] ? StageTheme.amber.opacity(0.22) : .clear)
                        .cornerRadius(4)
                        // A clear background is not a hit region in SwiftUI.
                        // Keep the symbol's complete framed button area active
                        // in both visibility states.
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(tooltip(area)).iconAccessibility(tooltip(area), caption: area.rawValue == "channelStrip" ? "Strip" : area.rawValue.capitalized)
                    .accessibilityIdentifier("workspace.toggle.\(area.rawValue)")
                    .disabled(workspace.mode == .perform)
                }
            }.padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            HStack(spacing: 12) {
                if workspace.mode == .perform {
                    Text("PERFORM · ⌘⇧P to edit")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(.black)
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("workspace.perform-banner")
                    Button { workspace.togglePerformance(canvas: instrument.canvas) } label: {
                        Label("Edit  ⌘⇧P", systemImage: "pencil")
                        .font(.system(size: 13, weight: .bold)).fixedSize()
                        .foregroundColor(StageTheme.amber).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(StageTheme.canvas).cornerRadius(5)
                    }.buttonStyle(.plain).help("Leave Perform mode and restore the previous editing layout (⌘⇧P).")
                    .accessibilityLabel("Edit ⌘⇧P")
                    .accessibilityIdentifier("workspace.edit").fixedSize()
                } else {
                    Spacer(minLength: 8)
                    Text(Self.buildLabel)
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize()
                    .help(PlanariumBuildIdentity.current.aboutVersionText)
                    .accessibilityIdentifier("workspace.build")
                    IconActionButton("Perform (⌘⇧P)", symbol: "music.mic") { workspace.togglePerformance(canvas: instrument.canvas) }
                    .help("Enter Perform mode: lock field editing (⌘⇧P).")
                }
            }.padding(.horizontal, 12).frame(width: workspace.mode == .perform ? geometry.size.width * 0.44 : 220, height: 44)
            .background(workspace.mode == .perform ? StageTheme.amber : Color.clear)
        }.font(.system(size: 11))
        }.frame(height: 44)
        .background(workspace.mode == .perform && workspace.inputLost ? Color.red.opacity(0.45) : StageTheme.canvas)
    }

    private func symbol(_ area: WorkspaceLayout.Area) -> String {
        switch area {
        case .setup: return "sidebar.left"
        case .layers: return "square.stack.3d.up"
        case .cell: return "square.dashed"
        case .channelStrip: return "slider.vertical.3"
        case .field: return "waveform"
        }
    }
    func tooltip(_ area: WorkspaceLayout.Area) -> String {
        if workspace.mode == .perform { return InstrumentAction.performanceLockReason }
        switch area {
        case .setup: return "Show or hide Setup (⌘1)"
        case .layers: return "Show or hide Layers (⌘2)"
        case .cell: return "Show or hide Cell (⌘3)"
        case .channelStrip: return "Show or hide Channel strip (⌘4)"
        case .field: return "Measurement field"
        }
    }
}
struct TempoHeaderView: View {
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    @ObservedObject private var clock: ClockDisplayState
    init(instrument: SpatialInstrumentRuntimeModel) {
        self.instrument = instrument; clock = instrument.clockDisplay
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
            TextField("BPM", value: Binding(get: { instrument.displayedBeatsPerMinute }, set: { instrument.setBeatsPerMinute($0) }),
                      formatter: Self.formatter)
                .textFieldStyle(.roundedBorder).frame(width: 52)
                .disabled(instrument.isReceivingClock || (instrument.canvas.isPerformanceLocked && !InstrumentAction.tempo.allowedInPerformance))
                .help(instrument.isReceivingClock ? "Tempo follows the external MIDI clock; switch to Off or Send to edit the preset BPM." : "Tempo, 30–300 BPM · saved in the preset").accessibilityIdentifier("tempo.bpm")
            if instrument.isReceivingClock {
                Label("Ext", systemImage: "arrow.down.circle").help("External MIDI clock · \(instrument.clockSourceName)")
            } else { Text("BPM").foregroundColor(.secondary) }
            IconActionButton("Tap Tempo (T)", symbol: "hand.tap") { instrument.tapTempo() }
                .disabled(instrument.isReceivingClock || (instrument.canvas.isPerformanceLocked && !InstrumentAction.tempo.allowedInPerformance))
                .help(instrument.isReceivingClock ? "Tap is unavailable while following an external MIDI clock." : "Tap Tempo (T) · average of the last four intervals; resets after a two-second pause")
                .accessibilityIdentifier("tempo.tap")
            IconActionButton(instrument.clockTransportPlaying ? "Stop transport" : "Play transport",
                             symbol: instrument.clockTransportPlaying ? "stop.fill" : "play.fill",
                             emergencyFirstMouse: instrument.clockTransportPlaying) {
                if instrument.clockTransportPlaying { instrument.stopClockTransport() } else { instrument.startClockTransport() }
            }.disabled(instrument.isReceivingClock)
                .help(instrument.isReceivingClock ? "Transport follows the external MIDI clock." : "Start or stop MIDI Clock independently of audio playback.")
                .accessibilityIdentifier("tempo.transport")
        }
        if instrument.isReceivingClock && clock.value.isLost {
            Text("External clock lost").font(.caption).foregroundColor(.orange)
        }
        }
    }
    private static let formatter: NumberFormatter = {
        let value = NumberFormatter(); value.numberStyle = .decimal; value.maximumFractionDigits = 1
        value.minimum = 30; value.maximum = 300; return value
    }()
}
private struct WorkspaceDocumentStatusView: View {
    @ObservedObject var presets: PresetControlModel
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    var body: some View {
        Text(presets.lastLoadedName ?? "Untitled").lineLimit(1).help("Current preset")
        Text(instrument.canvas.workspace.scenes.first { $0.id == instrument.canvas.workspace.currentSceneID }?.name ?? "No scene")
            .lineLimit(1).foregroundColor(.secondary).help("Active scene")
    }
}
/// Fixed height keeps a rejection from moving the canvas during a gesture.
struct WorkspaceDocumentNotice: View {
    @ObservedObject private var notices: InstrumentNoticeState
    init(instrument: SpatialInstrumentRuntimeModel) {
        notices = instrument.notices
    }
    var body: some View {
        Text(notices.text ?? "").font(.system(size: 11)).foregroundColor(.orange)
            .lineLimit(1).help(notices.text ?? "")
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 20)
            .accessibilityIdentifier("workspace.document-notice")
    }
}
private struct WorkspaceInputStatusView: View {
    let input: InputOwner
    let simulation: SimulationConnectionControlModel
    let workspace: WorkspaceControlModel
    @State private var inputChoice: SimulationInputChoice = .scanner
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("header.input.button")
        Button { workspace.setVisible(.setup, true) } label: {
            WorkspaceInputLiveStatus(input: input, workspace: workspace, inputChoice: inputChoice)
                .frame(minHeight: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Show input setup")
        .onReceive(simulation.$input.removeDuplicates()) { if inputChoice != $0 { inputChoice = $0 } }
    }
}
private struct WorkspaceInputLiveStatus: View {
    let input: InputOwner
    @ObservedObject var workspace: WorkspaceControlModel
    let inputChoice: SimulationInputChoice
    @State private var status: MeasurementSessionStatus = .idle
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("header.liveRate")
        HStack(spacing: 5) {
            Circle().fill(ready ? Color.green : lost ? Color.red : Color.gray).frame(width: 7, height: 7)
            Text(inputChoice == .scanner ? "Scanner" : "iPhone Simulation")
            Group {
                if workspace.mode == .perform && workspace.inputLost { Text("Input lost") }
                else if ready {
                    ProfileRateText(rate: input.profileRateDisplay) { value in
                        value.map { "\(Int($0.rounded())) Hz" } ?? "— Hz"
                    }
                } else { Text(rateText) }
            }.monospacedDigit().foregroundColor(workspace.mode == .perform && workspace.inputLost ? .white : .secondary)
        }.onReceive(input.measurementSessionStatusChanges) { value in
            if value != status { status = value }
            workspace.accept(value)
        }
    }
    private var ready: Bool {
        switch status { case .streaming, .simulation(.streaming): return true; default: return false }
    }
    private var lost: Bool {
        switch status { case .failed, .simulation(.failed): return true; default: return false }
    }
    private var rateText: String {
        switch status {
        case .streaming, .simulation(.streaming): return "— Hz"
        case .idle: return "Disconnected"
        case .failed, .simulation(.failed): return "Input lost"
        case .opening, .simulation(.opening): return "Connecting"
        case .openWithoutProfile, .simulation(.openWithoutProfile): return "Waiting for profiles"
        }
    }
}
