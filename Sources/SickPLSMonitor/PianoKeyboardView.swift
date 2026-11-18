import AppKit
import SwiftUI
import SickPLSMonitorKit

struct PianoKeyboardView: View {
    @Binding var model: PianoKeyboardModel
    @Binding var velocity: Double
    @Binding var transition: SpatialNoteTransition
    var showsVelocity = true
    let supportsNoteTransition: Bool
    let supportsToggle: Bool
    let onTransitionChange: ((SpatialNoteTransition) -> Void)?

    init(
        model: Binding<PianoKeyboardModel>,
        velocity: Binding<Double>,
        transition: Binding<SpatialNoteTransition>,
        supportsNoteTransition: Bool,
        showsVelocity: Bool = true,
        supportsToggle: Bool = true,
        onTransitionChange: ((SpatialNoteTransition) -> Void)? = nil
    ) {
        _model = model
        _velocity = velocity
        _transition = transition
        self.supportsNoteTransition = supportsNoteTransition
        self.showsVelocity = showsVelocity
        self.supportsToggle = supportsToggle
        self.onTransitionChange = onTransitionChange
    }

    var body: some View { CanvasTimingProbe.measure("inspector.pianoBody") { content } }
    @ViewBuilder private var content: some View {
        let _ = ViewEvaluationProbe.current?.record("piano.body")
        let keyboard = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { model.shiftOctave(by: -1) } label: {
                    FieldToolbarIconLabel(title: "Octave down", symbol: "chevron.left")
                }
                .buttonStyle(CaptionActionStyle())
                .help("Move down one octave")
                .iconAccessibility("Move down one octave", caption: "Octave down")
                    .disabled(model.octave == model.minimumOctave)
                Text("Octave \(model.octave)").font(.caption.monospacedDigit())
                Button { model.shiftOctave(by: 1) } label: {
                    FieldToolbarIconLabel(title: "Octave up", symbol: "chevron.right")
                }
                .buttonStyle(CaptionActionStyle())
                .help("Move up one octave")
                .iconAccessibility("Move up one octave", caption: "Octave up")
                    .disabled(model.octave == PianoKeyboardModel.highestOctave)
            }

            GeometryReader { proxy in
                let keys = PianoKeyboardLayout.layout(for: keyboard.visibleNotes, width: proxy.size.width, height: 52)
                ZStack(alignment: .topLeading) {
                    PianoKeyboardKeys(model: keyboard, width: proxy.size.width).equatable()
                        .allowsHitTesting(false).accessibilityHidden(true)
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .frame(width: proxy.size.width, height: 52)
                        .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                            if let note = PianoKeyboardLayout.hitTest(keys: keys, point: value.location) { model.toggle(note: note) }
                        })
                }.frame(width: proxy.size.width, height: 52)
                    .accessibilityLabel("Note keyboard")
                    .accessibilityValue(keyboard.selectedNoteNames)

            }
            .frame(height: 54).inspectorLayoutProbe("keyboard.keys")

            if supportsNoteTransition {
                Picker("Transition", selection: transitionSelection) {
                    Text("Retrigger").tag(SpatialNoteTransition.retrigger)
                    Text("Legato").tag(SpatialNoteTransition.legato)
                    Text("Overlap").tag(SpatialNoteTransition.overlap(milliseconds: 35))
                    if case let .overlap(milliseconds) = transition, milliseconds != 35 {
                        Text("Overlap (\(Int(milliseconds)) ms)")
                            .tag(SpatialNoteTransition.overlap(milliseconds: milliseconds))
                    }
                    Text("Hold till next trigger").tag(SpatialNoteTransition.holdUntilNext)
                    if supportsToggle { Text("Toggle: on / next entry off").tag(SpatialNoteTransition.toggle) }
                }
                .pickerStyle(.menu).help(HoldTransitionHelp.text)
                if transition == .holdUntilNext || transition == .toggle {
                    Text(HoldTransitionHelp.text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Applies to the whole layer")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if showsVelocity {
            DeferredControlSlider(value: $velocity, range: 1...127, defaultValue: 100, title: "Velocity")
                .labelsHidden()
            .frame(minWidth: 0, maxWidth: .infinity)
            .help("Sets the MIDI velocity for notes played by this layer.")
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var transitionSelection: Binding<SpatialNoteTransition> {
        Binding(
            get: { transition },
            set: { value in
                transition = value
                onTransitionChange?(value)
            }
        )
    }

}

/// Immutable drawing input: changing a binding or hiding the editor cannot
/// rebuild an unchanged two-octave keyboard. Actions stay outside this boundary.
private struct PianoKeyboardKeys: View, Equatable {
    let model: PianoKeyboardModel
    let width: CGFloat
    var body: some View { CanvasTimingProbe.measure("inspector.pianoGridBody") {
        let _ = ViewEvaluationProbe.current?.record("piano.layout")
        return InstrumentKeyboard(notes: model.visibleNotes, selected: model.selectedNotes)
            .frame(width: width, height: 52)
    } }
}

/// Shared passive renderer; interactive bindings stay in the keyboard owner.
struct InstrumentKeyboard: View {
    let notes: [Int]
    var selected: Set<Int> = []
    var selectedColor: Color = .accentColor
    var marks: [Int: [KeyboardMark]] = [:]
    var labels = true
    var body: some View {
        let _ = selected.forEach { ViewEvaluationProbe.current?.record("piano.selected.\($0)") }
        Canvas { context, size in
            let keys = PianoKeyboardLayout.layout(for: notes, width: size.width, height: size.height)
            for key in keys {
                let rect = key.frame
                let path = Path(rect)
                if key.isBlack {
                    context.fill(path, with: .linearGradient(Gradient(colors: [Color(white: 0.26), .black]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                    context.stroke(Path(CGRect(x: rect.minX + 1, y: 1, width: max(0, rect.width - 2), height: 1)), with: .color(.white.opacity(0.3)))
                } else {
                    context.draw(Self.ivory, in: rect)
                    context.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3)), with: .color(Color.brown.opacity(0.2)))
                }
                if selected.contains(key.note) { context.fill(path, with: .color(selectedColor.opacity(0.72))) }
                context.stroke(path, with: .color(.black.opacity(0.45)), lineWidth: 0.5)
                let indicators = marks[key.note] ?? []
                for (index, mark) in indicators.enumerated() {
                    let h = min(14, rect.height / CGFloat(max(1, indicators.count)))
                    let area = CGRect(x: rect.minX + 1, y: rect.maxY - CGFloat(index + 1) * h, width: max(1, rect.width - 2), height: h)
                    context.fill(Path(area), with: .color(mark.color.opacity(0.3 + 0.7 * Double(mark.velocity) / 127)))
                    context.draw(Text(mark.held ? "◇" : "●").font(.system(size: min(10, h))).foregroundColor(.white), at: CGPoint(x: area.midX, y: area.midY))
                }
                if labels && (key.note % 12 == 0 || selected.contains(key.note)) && rect.width > 9 && indicators.isEmpty {
                    context.draw(Text(PianoKeyboardModel.keyLabel(for: key.note, selected: selected.contains(key.note), keyWidth: rect.width)).font(.system(size: key.isBlack ? 8 : 9)).foregroundColor(key.isBlack ? .white : .black), at: CGPoint(x: rect.midX, y: rect.maxY - 7))
                }
            }
        }
        .accessibilityLabel("Keyboard")
        .accessibilityValue(accessibilitySummary)
    }
    private var accessibilitySummary: String {
        let active = selected.union(marks.keys).sorted()
        guard !active.isEmpty else { return "No notes" }
        return active.map { note in
            let indicators = marks[note] ?? []
            let state = indicators.isEmpty ? "selected" : indicators.contains(where: \.held) ? "held" : "playing"
            return PianoKeyboardModel.displayName(for: note) + ", " + state
        }.joined(separator: "; ")
    }
    static let ivory: Image = {
        let width = 32, height = 128
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                let grain = Double((x * 13 + x * x * 7) % 17) / 1500
                let patina = Double((x * 7 + y * 3) % 23) / 3000
                ctx.setFillColor(CGColor(red: 0.91 - grain - patina, green: 0.865 - grain - patina, blue: 0.73 - grain - patina, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return Image(decorative: ctx.makeImage()!, scale: 1)
    }()
}
struct KeyboardMark {
    let color: Color
    let velocity: UInt8
    let held: Bool
}
