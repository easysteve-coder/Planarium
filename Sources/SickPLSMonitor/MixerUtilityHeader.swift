import SwiftUI
import SickPLSMonitorKit
import Combine
import PlanariumAudio
import PlanariumApplication
import PlanariumDomain

/// One compact output card and passive mini keyboard above all mixer rails.
struct MixerUtilityHeader: View {
    @ObservedObject var devices: AudioOutputDeviceControlModel
    let display: PerformanceDisplayModel?
    let allowsChanges: Bool
    @State private var showingOutput = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { showingOutput = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AUDIO OUTPUT").font(.system(size: 10, weight: .semibold))
                    Text(devices.selectedDevice.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    Text(devices.outputSummary).font(.system(size: 10)).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    .cornerRadius(4).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Audio output").help(devices.outputSummary)
                .auditedButtonSurface("Audio output",font: 10,foreground: .white,background: HelmutChrome.control)
                .popover(isPresented: $showingOutput) { AudioOutputDeviceCardView(model: devices, allowsChanges: allowsChanges) }
            if let display { MixerMiniKeyboard(display: display) }
            else { MiniKeyboardNotes(notes: []) }
        }.padding(6).frame(height: 140).frame(maxWidth: .infinity)
            .background(StageTheme.workspace).accessibilityIdentifier("mixer.utilities")
    }
}
struct MixerMiniKeyboard: View {
    let display: PerformanceDisplayModel
    @State private var notes: Set<Int> = []
    var body: some View {
        let _ = ViewEvaluationProbe.current?.record("mixer.keyboard")
        MiniKeyboardNotes(notes: notes).equatable()
            .onReceive(display.$frame.map { Set($0?.soundingNoteOwners.map { Int($0.number) } ?? []) }.removeDuplicates()) { notes = $0 }
            // Mounting and native window visibility have separate owners.
            // The display model gates this request with the main window state.
            .onAppear { display.setMixerMonitorVisible(true) }
            .onDisappear { display.setMixerMonitorVisible(false) }
    }
}
struct MiniKeyboardNotes: View, Equatable {
    let notes: Set<Int>
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("OUTPUT · \(notes.count) notes").font(.system(size: 8, weight: .semibold))
            InstrumentKeyboard(notes: Array(0..<24), selected: Set(notes.map { $0 % 24 }), selectedColor: StageTheme.amber, labels: false)
                .frame(height: 22).accessibilityHidden(true)
        }.accessibilityLabel("Output monitor: \(notes.count) sounding notes").allowsHitTesting(false)
    }
}
