import SwiftUI
import PlanariumDomain
import SickPLSMonitorKit

/// Edits document values only. Learning uses clicks, never a live MIDI input.
struct ChordEffectEditor: View {
    @Binding var effect: ChordEffect
    var close: () -> Void = {}
    @State private var learning = false
    @State private var choosingTrigger = false
    @State private var trigger = 60
    @State private var keyboardOctave = 4
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Chord").font(.title2)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 24,height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help("Close Chord editor")
            }
            Picker("Mode", selection: $effect.mode) {
                ForEach(ChordEffect.Mode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Stepper("Low \(effect.low)", value: $effect.low, in: 0...effect.high)
                Stepper("High \(effect.high)", value: $effect.high, in: effect.low...127)
            }.font(.caption)
            Text("Outside this trigger range, notes pass through unchanged.").font(.caption).foregroundColor(.secondary)
            if effect.mode == .scale {
                HStack {
                    Picker("Key", selection: $effect.root) {
                        ForEach(0..<12) { Text(MIDINoteName.pitchClassName(for: $0)).tag($0) }
                    }
                    Picker("Scale", selection: $effect.scale) {
                        ForEach(SpatialScale.allCases, id: \.self) { Text(scaleName($0)).tag($0) }
                    }
                }
                Picker("Chord", selection: Binding(get: { effect.toneCount }, set: { count in
                    var updated = effect; updated.toneCount = count; updated.inversion = min(updated.inversion, count - 1); effect = updated
                })) { Text("Triad").tag(3); Text("Seventh").tag(4) }.pickerStyle(.segmented)

                Stepper("Inversion \(effect.inversion)", value: $effect.inversion, in: 0...(effect.toneCount - 1))
                Stepper("Octave \(effect.octave)", value: $effect.octave, in: -3...3)
                Toggle("Open voicing", isOn: $effect.spread)
                Text("Nearest scale degree · ties downward").font(.caption).foregroundColor(.secondary)
            } else {
                HStack {
                    Button {
                        learning.toggle(); choosingTrigger = learning
                    } label: { Image(systemName: learning ? "stop.circle" : "record.circle") }
                    .help(learning ? "Finish learning" : "Learn: choose a trigger key, then chord notes")
                    Text(learning ? (choosingTrigger ? "Choose trigger key" : "Choose chord notes") : "Click Learn to edit a chord")
                        .font(.caption)
                    Spacer()
                    Button {
                        if effect.mode == .single { effect.singleNotes = [] }
                        else { effect.multiNotes.removeValue(forKey: trigger) }
                    } label: { Image(systemName: "eraser") }.help("Clear this chord")
                    Button {
                        if effect.mode == .single { effect.singleNotes = [] } else { effect.multiNotes = [:] }
                    } label: { Image(systemName: "trash") }.help("Clear all learned chords")
                }
                Text("Trigger: \(PianoKeyboardModel.displayName(for: trigger))\(effect.mode == .single ? " · transposes from learned key" : " · unassigned keys pass through")")
                    .font(.caption)
                PianoKeyboardView(model: keyboard, velocity: .constant(100), transition: .constant(.legato), supportsNoteTransition: false, showsVelocity: false)
                Text(notes.sorted().map(PianoKeyboardModel.displayName(for:)).joined(separator: " "))
                    .font(.caption).frame(minHeight: 18)
            }
            Text("C → " + effect.notes(for: 60).map(PianoKeyboardModel.displayName(for:)).joined(separator: " "))
                .font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.08)).cornerRadius(4)
        }.toggleStyle(ReadableCheckboxStyle()).padding(20).frame(minWidth: 360, idealWidth: 580)
            .onAppear { resetSelection() }
            .onChange(of: effect.mode) { _ in resetSelection() }
    }
    private func resetSelection() {
        learning = false; choosingTrigger = false
        trigger = effect.mode == .multi ? effect.multiNotes.keys.min() ?? 60 : effect.learnedTrigger
        keyboardOctave = min(max(trigger / 12 - 1, -1), 9)
    }
    private func scaleName(_ value: SpatialScale) -> String {
        switch value {
        case .chromatic: return "Chromatic"
        case .major: return "Major"
        case .naturalMinor: return "Natural minor"
        case .majorPentatonic: return "Major pentatonic"
        case .minorPentatonic: return "Minor pentatonic"
        }
    }
    private var notes: Set<Int> {
        Set(effect.mode == .single ? effect.singleNotes : effect.multiNotes[trigger] ?? [])
    }
    private var keyboard: Binding<PianoKeyboardModel> {
        Binding(get: { PianoKeyboardModel(octave: keyboardOctave, selectedNotes: choosingTrigger ? [trigger] : notes, minimumOctave: -1) }, set: { model in
            keyboardOctave = model.octave
            guard learning else { return }
            if choosingTrigger {
                guard let selected = model.selectedNotes.symmetricDifference([trigger]).sorted().first else { return }
                trigger = selected; choosingTrigger = false
                if effect.mode == .single { effect.learnedTrigger = selected }
            } else if effect.mode == .single { effect.singleNotes = model.selectedNotes.sorted() }
            else { effect.multiNotes[trigger] = model.selectedNotes.sorted() }
        })
    }
}
