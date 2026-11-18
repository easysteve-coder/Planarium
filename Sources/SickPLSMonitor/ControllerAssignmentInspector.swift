import SwiftUI
import PlanariumApplication
import PlanariumControllerCore
import PlanariumDomain

/// What an assignment plays, in the inspector's words.
enum ControllerAssignmentKind: String, CaseIterable {
    case note, scale, chord, control
    var title: String {
        switch self {
        case .note: return "Note"
        case .scale: return "Scale"
        case .chord: return "Chord"
        case .control: return "Controller (CC)"
        }
    }
    var symbol: String {
        switch self {
        case .note: return "music.note"
        case .scale: return "music.note.list"
        case .chord: return "pianokeys"
        case .control: return "slider.horizontal.3"
        }
    }
}

/// Pure editing rules of the inspector, kept out of the view for tests.
enum ControllerAssignmentEditing {
    static func kind(of assignment: ControllerAssignment) -> ControllerAssignmentKind {
        switch assignment.routing.program {
        case .scale, .randomScale: return .scale
        case .chord: return .chord
        case .constant, .continuous, .programChange: return .control
        case .singleNote: return assignment.routing.target.isNoteTarget ? .note : .control
        }
    }

    /// A fresh assignment for an element: buttons play a note, triggers and
    /// sticks send a controller unless asked otherwise.
    static func make(_ element: ControllerElement, kind: ControllerAssignmentKind, output: ControllerAssistantOutput,
                     color: SpatialLayerColor) -> ControllerAssignment {
        var assignment = ControllerAssignment(name: element.displayName, color: color, element: element,
                                              routing: .init(target: .midiNote(channel: 0), program: .constant(0)))
        assignment.routing = routing(kind, element: element, output: output, keeping: nil)
        return assignment
    }

    static func routing(_ kind: ControllerAssignmentKind, element: ControllerElement, output: ControllerAssistantOutput,
                        keeping old: SpatialRouting?) -> SpatialRouting {
        let id = old?.id ?? UUID()
        let note: SpatialRoutingTarget, cc: SpatialRoutingTarget
        switch output {
        case let .audioUnit(strip, channel):
            note = .audioUnitNote(channel: channel, stripID: strip); cc = .audioUnitCC(channel: channel, controller: 74, stripID: strip)
        case let .midi(channel):
            note = .midiNote(channel: channel); cc = .midiCC(channel: channel, controller: 74)
        }
        let transition: SpatialNoteTransition = element.isPositional ? .legato : .retrigger
        switch kind {
        case .note: return .init(id: id, target: note, program: .singleNote(note: 60, velocity: 100, transition: transition))
        case .scale: return .init(id: id, target: note, program: .scale(rootMIDINote: 60, lowestMIDINote: 60, highestMIDINote: 72, scale: .major,
                                                                         directionDegrees: 90, ascending: true, transition: .legato))
        case .chord: return .init(id: id, target: note, program: .chord(notes: [60, 64, 67], velocity: 96, transition: transition))
        case .control:
            let program: SpatialValueProgram = element.kind == .button ? .constant(1) : .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear)
            return .init(id: id, target: cc, program: program)
        }
    }

    static func output(of target: SpatialRoutingTarget) -> ControllerAssistantOutput {
        let channel = target.midiChannel ?? 0
        if let strip = target.stripID { return .audioUnit(stripID: strip, channel: channel) }
        return .midi(channel: channel)
    }

    /// Moves the routing to another output, keeping what it plays.
    static func retarget(_ target: SpatialRoutingTarget, to output: ControllerAssistantOutput) -> SpatialRoutingTarget {
        let controller = target.ccNumber
        switch (output, controller) {
        case let (.audioUnit(strip, channel), nil): return .audioUnitNote(channel: channel, stripID: strip)
        case let (.audioUnit(strip, channel), cc?): return .audioUnitCC(channel: channel, controller: cc, stripID: strip)
        case let (.midi(channel), nil): return .midiNote(channel: channel)
        case let (.midi(channel), cc?): return .midiCC(channel: channel, controller: cc)
        }
    }

    static func noteName(_ number: Int) -> String {
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return "\(names[((number % 12) + 12) % 12])\(number / 12 - 1)"
    }
}

extension SpatialRoutingTarget {
    var isNoteTarget: Bool {
        switch self {
        case .midiNote, .audioUnitNote: return true
        default: return false
        }
    }
    var ccNumber: UInt8? {
        switch self {
        case let .midiCC(_, controller), let .audioUnitCC(_, controller, _): return controller
        default: return nil
        }
    }
}

/// Assignments of one selected element: kind, output, what it plays, color.
struct ControllerAssignmentInspector: View {
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    let stage: ControllerStageModel
    let element: ControllerElement
    @State private var conflicts: [UUID: OutputConflict] = [:]

    private var assignments: [ControllerAssignment] { instrument.document.controller.assignments.filter { $0.element == element } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(element.displayName).font(.headline)
                Spacer()
                ForEach(ControllerAssignmentKind.allCases, id: \.self) { kind in
                    if kind != .scale || element.isPositional {
                        Button { add(kind) } label: { Image(systemName: kind.symbol) }
                            .buttonStyle(.borderless).help("Add: \(kind.title)")
                    }
                }
            }
            if assignments.isEmpty {
                Text("No assignment · add one with the symbols above").font(.caption).foregroundColor(.secondary)
            }
            ForEach(assignments) { assignment in
                ControllerAssignmentRow(instrument: instrument, assignment: assignment,
                                        conflict: conflicts[assignment.id] ?? stage.conflicts[assignment.id])
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        .accessibilityIdentifier("controller.inspector")
        .onReceive(stage.$conflicts) { if $0 != conflicts { conflicts = $0 } }
    }

    private func add(_ kind: ControllerAssignmentKind) {
        let used = instrument.document.controller.assignments.map(\.color)
        let color = SpatialLayerColor.palette.first { !used.contains($0) } ?? .orange
        let strip = instrument.document.channels.first { $0.instrument != nil }
        let output: ControllerAssistantOutput = strip.map { .audioUnit(stripID: $0.id, channel: 0) } ?? .midi(channel: 0)
        instrument.updateControllerAssignment(ControllerAssignmentEditing.make(element, kind: kind, output: output, color: color))
    }
}

private struct ControllerAssignmentRow: View {
    @ObservedObject var instrument: SpatialInstrumentRuntimeModel
    let assignment: ControllerAssignment
    let conflict: OutputConflict?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: ControllerAssignmentEditing.kind(of: assignment).symbol)
                TextField("Name", text: Binding(get: { assignment.name }, set: { name in change { $0.name = name } }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                outputMenu
                Spacer()
                Toggle(isOn: Binding(get: { assignment.isActive }, set: { on in change { $0.isActive = on } })) {
                    Image(systemName: "power")
                }.toggleStyle(.button).help(assignment.isActive ? "Active" : "Inactive")
                Button { instrument.removeControllerAssignment(assignment.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove assignment")
            }
            programEditor
            HStack(spacing: 3) {
                ForEach(Array(SpatialLayerColor.palette.prefix(12).enumerated()), id: \.offset) { _, color in
                    Circle().fill(Color(red: color.red, green: color.green, blue: color.blue))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white, lineWidth: color == assignment.color ? 2 : 0))
                        .onTapGesture { change { $0.color = color } }
                }
                if assignment.element.isPositional { zoneMenu }
            }
            if let conflict {
                Label("Silent: the \(conflict.owner == .scanner ? "scanner" : "other source") already plays this output", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Color(red: assignment.color.red, green: assignment.color.green, blue: assignment.color.blue).opacity(0.6)))
    }

    private func change(_ edit: (inout ControllerAssignment) -> Void) {
        var next = assignment; edit(&next)
        guard next != assignment else { return }
        instrument.updateControllerAssignment(next)
    }

    private var outputMenu: some View {
        let current = ControllerAssignmentEditing.output(of: assignment.routing.target)
        let strips = instrument.document.channels
        let title: String = {
            switch current {
            case let .audioUnit(strip, channel): return "\(strips.first { $0.id == strip }?.name ?? "Strip") · Ch \(channel + 1)"
            case let .midi(channel): return "MIDI · Ch \(channel + 1)"
            }
        }()
        return Menu(title) {
            ForEach(strips) { strip in
                Button(strip.name) { change { $0.routing.target = ControllerAssignmentEditing.retarget($0.routing.target, to: .audioUnit(stripID: strip.id, channel: $0.routing.target.midiChannel ?? 0)) } }
            }
            Button("MIDI output") { change { $0.routing.target = ControllerAssignmentEditing.retarget($0.routing.target, to: .midi(channel: $0.routing.target.midiChannel ?? 0)) } }
            Divider()
            Menu("Channel") {
                ForEach(0..<16, id: \.self) { channel in
                    Button("Channel \(channel + 1)") {
                        change {
                            let output: ControllerAssistantOutput
                            switch ControllerAssignmentEditing.output(of: $0.routing.target) {
                            case let .audioUnit(strip, _): output = .audioUnit(stripID: strip, channel: UInt8(channel))
                            case .midi: output = .midi(channel: UInt8(channel))
                            }
                            $0.routing.target = ControllerAssignmentEditing.retarget($0.routing.target, to: output)
                        }
                    }
                }
            }
        }.fixedSize().help("Output and channel")
    }

    private var zoneMenu: some View {
        let title: String = {
            if case let .sector(index, count) = assignment.zone { return "Sector \(index + 1) of \(count)" }
            return "Whole"
        }()
        return Menu(title) {
            Button("Whole") { change { $0.zone = .whole } }
            ForEach([2, 4, 8], id: \.self) { count in
                Menu("\(count) sectors") {
                    ForEach(0..<count, id: \.self) { index in
                        Button("Sector \(index + 1)") { change { $0.zone = .sector(index: index, count: count) } }
                    }
                }
            }
        }.fixedSize().help("Which part of the stick or touchpad plays")
    }

    @ViewBuilder private var programEditor: some View {
        switch assignment.routing.program {
        case let .singleNote(note, velocity, transition):
            HStack {
                Stepper("\(ControllerAssignmentEditing.noteName(note))", value: Binding(get: { note }, set: { next in
                    change { $0.routing.program = .singleNote(note: min(127, max(0, next)), velocity: velocity, transition: transition) } }), in: 0...127)
                transitionMenu(transition) { t in .singleNote(note: note, velocity: velocity, transition: t) }
            }
        case let .chord(notes, velocity, transition):
            HStack {
                Stepper("Root \(ControllerAssignmentEditing.noteName(notes.first ?? 60)) · \(notes.count) notes", value: Binding(get: { notes.first ?? 60 }, set: { next in
                    let shift = next - (notes.first ?? 60)
                    let moved = notes.map { $0 + shift }
                    guard moved.allSatisfy({ (0...127).contains($0) }) else { return }
                    change { $0.routing.program = .chord(notes: moved, velocity: velocity, transition: transition) } }), in: 0...127)
                transitionMenu(transition) { t in .chord(notes: notes, velocity: velocity, transition: t) }
            }
        case let .scale(root, low, high, scale, degrees, ascending, transition):
            HStack {
                Picker("", selection: Binding(get: { scale }, set: { next in
                    change { $0.routing.program = .scale(rootMIDINote: root, lowestMIDINote: low, highestMIDINote: high, scale: next, directionDegrees: degrees, ascending: ascending, transition: transition) } })) {
                    ForEach(SpatialScale.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 140)
                Stepper("From \(ControllerAssignmentEditing.noteName(low))", value: Binding(get: { low }, set: { next in
                    let shift = next - low
                    guard (0...127).contains(high + shift) else { return }
                    change { $0.routing.program = .scale(rootMIDINote: root + shift, lowestMIDINote: next, highestMIDINote: high + shift, scale: scale, directionDegrees: degrees, ascending: ascending, transition: transition) } }), in: 0...127)
            }
        case let .continuous(minimum, maximum, degrees, curve):
            HStack {
                ccStepper
                Text("\(Int(minimum * 127))…\(Int(maximum * 127))").font(.caption).foregroundColor(.secondary)
                Button { change { $0.routing.program = .continuous(minimum: maximum, maximum: minimum, directionDegrees: degrees, curve: curve) } } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }.buttonStyle(.borderless).help("Invert the range")
            }
        case let .constant(value):
            HStack {
                ccStepper
                Stepper("Value \(Int(value * 127))", value: Binding(get: { Int(value * 127) }, set: { next in
                    change { $0.routing.program = .constant(Double(min(127, max(0, next))) / 127) } }), in: 0...127)
            }
        default:
            Text("Edited in the layer inspector format").font(.caption).foregroundColor(.secondary)
        }
    }

    private var ccStepper: some View {
        let cc = Int(assignment.routing.target.ccNumber ?? 74)
        return Stepper("CC \(cc)", value: Binding(get: { cc }, set: { next in
            let number = UInt8(min(119, max(1, next)))
            change {
                switch $0.routing.target {
                case let .midiCC(channel, _): $0.routing.target = .midiCC(channel: channel, controller: number)
                case let .audioUnitCC(channel, _, strip): $0.routing.target = .audioUnitCC(channel: channel, controller: number, stripID: strip)
                default: break
                }
            } }), in: 1...119).help("Controller number (CC0/32 and 120–127 belong to the note owner)")
    }

    private func transitionMenu(_ current: SpatialNoteTransition, _ make: @escaping (SpatialNoteTransition) -> SpatialValueProgram) -> some View {
        let options: [(SpatialNoteTransition, String, String)] = [
            (.retrigger, "Play while held", "hand.tap"), (.holdUntilNext, "Hold until next", "pin"), (.toggle, "Toggle", "repeat.1"),
        ]
        return HStack(spacing: 2) {
            ForEach(options, id: \.1) { option in
                Button { change { $0.routing.program = make(option.0) } } label: {
                    Image(systemName: option.2).foregroundColor(current == option.0 ? StageTheme.amberBright : .secondary)
                }.buttonStyle(.borderless).help(option.1)
            }
        }
    }
}
