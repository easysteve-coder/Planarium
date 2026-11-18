import SwiftUI
import AppKit
import PlanariumApplication
import PlanariumDomain
import SickPLSMonitorKit

/// Chooses between the surface inspector and the inspector of the advanced cell editor.
struct SurfaceInspectorGate: View {
    @ObservedObject var model: SurfaceEditorModel
    let legacy: AnyView
    var body: some View {
        if model.mode == .surfaces { SurfaceInspectorView(model: model, cellEditor: legacy) } else { legacy }
    }
}

/// A decimal measure with a field and a stepper. Typing commits on Return or when focus leaves; a held
/// stepper is one burst of the surface editor and therefore one undo step.
struct SurfaceMeasureField: View {
    let title: String
    let value: Double
    let unit: String
    var step: Double = 1
    var enabled = true
    var id: String
    let model: SurfaceEditorModel
    let commit: (Double) -> Void
    @State private var text = ""
    @State private var editing = false
    @State private var invalid = false

    private func format(_ v: Double) -> String { String(format: "%.1f", v) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).frame(width: 74, alignment: .leading)
                TextField("", text: Binding(get: { editing ? text : format(value) }, set: { text = $0; editing = true }), onCommit: {
                    let cleaned = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
                    editing = false
                    guard let parsed = Double(cleaned), parsed.isFinite else { invalid = true; return }
                    invalid = false
                    if parsed != value { commit(parsed) }
                })
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 70)
                    .disabled(!enabled)
                    .accessibilityLabel(title).accessibilityIdentifier("surface.field.\(id)")
                Text(unit).foregroundColor(.secondary).frame(width: 24, alignment: .leading)
                Stepper(title, onIncrement: { commit(value + step) }, onDecrement: { commit(value - step) },
                        onEditingChanged: { began in if began { model.beginAdjusting() } else { model.endAdjusting() } })
                    .labelsHidden().disabled(!enabled)
                    .accessibilityLabel("\(title) fine adjustment").accessibilityIdentifier("surface.stepper.\(id)")
            }
            if invalid { Text("Enter a number").font(.system(size: 9)).foregroundColor(.red) }
        }.font(.system(size: 11))
    }
}

struct SurfaceInspectorView: View {
    @ObservedObject var model: SurfaceEditorModel
    /// The assignment editor of the cell based layers, shown for an existing area that has not been converted.
    var cellEditor: AnyView? = nil
    @State private var revision = 0
    @State private var confirmReplace: UUID?
    private let secondary = Color.white.opacity(0.58)

    private var surfaces: [SpatialSurface] { model.selectedSurfaces }

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 12) {
            if surfaces.isEmpty {
                if let layer = model.legacyLayer {
                    existingArea(layer)
                    if let cellEditor { Divider().overlay(Color.white.opacity(0.1)); cellEditor }
                } else { emptyHint }
            } else if surfaces.count == 1, let surface = surfaces.first {
                single(surface)
            } else {
                multiple(surfaces)
            }
            if let hint = model.hint {
                Text(hint).font(.system(size: 10)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("surface.hint")
            }
            playingArea
        }
        .font(.system(size: 11))
        .accessibilityIdentifier("surface.inspector")
        .onReceive(model.instrument.$document) { _ in revision &+= 1 }
    }

    // MARK: Empty

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No surface selected").font(.system(size: 12, weight: .semibold))
            Text("Draw one with the rectangle (R), circle (C), polygon (G) or ring sector (S) tool, or click a surface in the field.")
                .foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Several surfaces

    private func multiple(_ chosen: [SpatialSurface]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(chosen.count) surfaces selected").font(.system(size: 12, weight: .semibold))
            actions
            colorRow(chosen)
            Text("Select a single surface to edit its size, position and assignment.").foregroundColor(secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: One surface

    private func single(_ surface: SpatialSurface) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            nameRow(surface)
            actions
            colorRow([surface])
            geometry(surface)
            assignments(surface)
        }
    }

    private func nameRow(_ surface: SpatialSurface) -> some View {
        HStack {
            Text("Name").frame(width: 74, alignment: .leading)
            SurfaceNameField(name: surface.presentation.name, id: surface.id) { _ = model.rename($0) }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            iconButton("Duplicate", "plus.square.on.square") { _ = model.duplicateSelection() }
            iconButton("Mirror left/right", "arrow.left.and.right") { _ = model.mirrorSelection() }
            iconButton("Delete", "trash") { _ = model.deleteSelection() }
            Spacer()
        }
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { FieldToolbarIconLabel(title: title, symbol: symbol).frame(width: 26, height: 22) }
            .buttonStyle(.plain).padding(3).background(HelmutChrome.control).cornerRadius(4)
            .help(title).accessibilityLabel(title).accessibilityIdentifier("surface.action.\(title)")
    }

    private func color(_ c: SpatialLayerColor) -> Color { Color(red: c.red, green: c.green, blue: c.blue) }
    private func layerColor(_ color: Color) -> SpatialLayerColor {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        return SpatialLayerColor(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }

    private func colorRow(_ chosen: [SpatialSurface]) -> some View {
        HStack {
            Text("Colour").frame(width: 74, alignment: .leading)
            ColorPicker("Surface colour", selection: Binding(get: { color(chosen.first?.presentation.color ?? .orange) },
                                                             set: { _ = model.setColor(layerColor($0)) }), supportsOpacity: false)
                .labelsHidden().accessibilityIdentifier("surface.color")
            Spacer()
        }
    }

    // MARK: Geometry

    @ViewBuilder private func geometry(_ surface: SpatialSurface) -> some View {
        switch surface.form {
        case .legacyMask:
            VStack(alignment: .leading, spacing: 4) {
                Text("Exact area of an older preset").font(.system(size: 11, weight: .semibold))
                Text("\(surface.cells.count) cells. Its outline cannot be dragged; use the steps below.")
                    .foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                existingSteps(layerID: surface.id)
            }
        case .shape(let shape, let transform):
            VStack(alignment: .leading, spacing: 4) {
                Text("Shape and position").font(.system(size: 11, weight: .semibold))
                if case .ringSector(let from, let to, let fromDegrees, let toDegrees) = shape {
                    measure("From radius", from, "cm", id: "sectorFrom") { _ = model.setSector(fromCm: $0) }
                    measure("To radius", to, "cm", id: "sectorTo") { _ = model.setSector(toCm: $0) }
                    measure("From bearing", fromDegrees, "°", id: "sectorFromDeg") { _ = model.setSector(fromDegrees: $0) }
                    measure("To bearing", toDegrees, "°", id: "sectorToDeg") { _ = model.setSector(toDegrees: $0) }
                    Text("A ring sector stays centred on the scanner.").foregroundColor(secondary)
                } else {
                    measure("X", transform.xCm, "cm", id: "x") { _ = model.setPlacement(xCm: $0) }
                    measure("Y", transform.yCm, "cm", id: "y") { _ = model.setPlacement(yCm: $0) }
                    switch shape {
                    case .rectangle(let w, let h):
                        measure("Width", w, "cm", id: "width") { _ = model.setSize(widthCm: $0) }
                        measure("Height", h, "cm", id: "height") { _ = model.setSize(heightCm: $0) }
                    case .circle(let r):
                        measure("Radius", r, "cm", id: "radius") { _ = model.setSize(radiusCm: $0) }
                    default:
                        Text("\(pointCount(shape)) corners · drag a corner in the field").foregroundColor(secondary)
                    }
                    measure("Rotation", transform.rotationDegrees, "°", step: 5, id: "rotation") { _ = model.setPlacement(rotationDegrees: $0) }
                    Text("Counter-clockwise. The arrow bearing below counts from the front.").font(.system(size: 9)).foregroundColor(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Mirrored", isOn: Binding(get: { transform.mirrorX }, set: { _ = model.setPlacement(mirrored: $0) }))
                        .accessibilityIdentifier("surface.mirrored")
                }
            }
        }
    }

    private func pointCount(_ shape: SurfaceShape) -> Int { if case .polygon(let p) = shape { return p.count }; return 0 }

    private func measure(_ title: String, _ value: Double, _ unit: String, step: Double = 1, id: String,
                         commit: @escaping (Double) -> Void) -> some View {
        SurfaceMeasureField(title: title, value: value, unit: unit, step: step, id: id, model: model, commit: commit)
    }

    // MARK: Existing areas

    private func existingArea(_ layer: SpatialDocumentLayer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Existing area").font(.system(size: 12, weight: .semibold))
            Text("\(layer.name) · \(layer.cells.count) cells from an older preset. It is shown and played exactly as saved. Looking at it changes nothing.")
                .foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
            existingSteps(layerID: layer.id)
        }
    }

    private func existingSteps(layerID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Each step converts the area to an exact surface in one undo step.").font(.system(size: 9)).foregroundColor(secondary)
            HStack(spacing: 6) {
                iconButton("Turn left 5°", "arrow.counterclockwise") {
                    _ = model.legacyOperation(layerID, { .rotateMask(surfaceID: $0, ticks: 10) }, name: "Turn area")
                }
                iconButton("Turn right 5°", "arrow.clockwise") {
                    _ = model.legacyOperation(layerID, { .rotateMask(surfaceID: $0, ticks: -10) }, name: "Turn area")
                }
                iconButton("Mirror area", "arrow.left.and.right") {
                    _ = model.legacyOperation(layerID, { .mirrorMask(surfaceID: $0) }, name: "Mirror area")
                }
                iconButton("Move away from scanner 5 cm", "arrow.up") {
                    _ = model.legacyOperation(layerID, { .shiftMask(surfaceID: $0, rings: 5) }, name: "Move area")
                }
                iconButton("Move toward scanner 5 cm", "arrow.down") {
                    _ = model.legacyOperation(layerID, { .shiftMask(surfaceID: $0, rings: -5) }, name: "Move area")
                }
                iconButton("Replace by a rectangle", "rectangle") { confirmReplace = layerID }
            }
            if confirmReplace == layerID, let loss = model.lossOfReplacing(layerID: layerID) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Replacing drops the exact outline (\(loss.cells) cells) and \(loss.overrides) own cell values. You can undo it.")
                        .foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Replace") {
                            _ = model.replaceWithRectangle(layerID: layerID)
                            confirmReplace = nil
                        }.accessibilityIdentifier("surface.replace.confirm")
                        Button("Cancel") { confirmReplace = nil }
                    }
                }
            }
        }
    }

    // MARK: Assignments

    private func assignments(_ surface: SpatialSurface) -> some View {
        let selected = model.axisRoutingID.flatMap { id in surface.routings.first { $0.id == id } } ?? surface.routings.first
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(surface.routings.count > 1 ? "Assignments" : "Assignment").font(.system(size: 11, weight: .semibold))
                Spacer()
                if let selected {
                    iconButton("Add another assignment", "plus") { _ = model.addRouting(copying: selected.id) }
                    if surface.routings.count > 1 {
                        iconButton("Remove assignment", "minus") { _ = model.removeRouting(selected.id) }
                    }
                }
            }
            if surface.routings.count > 1 {
                Picker("Assignment", selection: Binding(get: { selected?.id ?? UUID() }, set: { model.selectRouting($0) })) {
                    ForEach(Array(surface.routings.enumerated()), id: \.element.id) { index, routing in
                        Text("\(index + 1) · \(summary(routing))").tag(routing.id)
                    }
                }.labelsHidden().accessibilityIdentifier("surface.routingPicker")
            }
            if let selected { routingEditor(surface, selected) }
            else { Text("This surface has no assignment yet.").foregroundColor(secondary) }
        }
    }

    private func summary(_ routing: SpatialRouting) -> String {
        if let plays = SurfacePlays.of(routing) {
            switch routing.program {
            case .singleNote(let n, _, _): return "Note \(MIDINoteName.displayName(for: n))"
            case .chord(let notes, _, _): return "Chord \(notes.min().map(MIDINoteName.displayName(for:)) ?? "")"
            case .scale(let root, _, _, let scale, _, _, _): return "\(MIDINoteName.pitchClassName(for: root)) \(SurfaceScaleName.text(scale))"
            default: return plays.title + " " + (routing.target.controllerNumber.map { "\($0)" } ?? "")
            }
        }
        return "Kept as saved"
    }

    @ViewBuilder private func routingEditor(_ surface: SpatialSurface, _ routing: SpatialRouting) -> some View {
        if let plays = SurfacePlays.of(routing) {
            let draft = SpatialAssignmentDraft.from(program: routing.program, target: routing.target)
            Picker("Plays", selection: Binding(get: { plays }, set: { _ = model.setPlays(routing.id, $0) })) {
                ForEach(SurfacePlays.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("surface.plays")
            outputRow(routing, draft)
            switch plays {
            case .note: noteEditor(routing, draft)
            case .chord: chordEditor(routing, draft)
            case .scale: scaleEditor(surface, routing, draft)
            case .controller: controllerEditor(surface, routing, draft)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("Kept as saved").font(.system(size: 11, weight: .semibold))
                Text("This assignment is not a note, chord, scale or CC. The surface editor does not change it.")
                    .foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
            }.accessibilityIdentifier("surface.keptRouting")
        }
    }

    private func outputRow(_ routing: SpatialRouting, _ draft: SpatialAssignmentDraft) -> some View {
        let strip: UUID? = {
            switch draft.target { case .audioUnitNote(_, let s), .audioUnitCC(_, _, let s): return s; default: return nil }
        }()
        let channel: Int = {
            switch draft.target {
            case .audioUnitNote(let c, _), .audioUnitCC(let c, _, _), .midiNote(let c), .midiCC(let c, _): return Int(c) + 1
            default: return 1
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Output").frame(width: 74, alignment: .leading)
                Picker("Output", selection: Binding(get: { strip }, set: { _ = model.setOutput(routing.id, stripID: $0) })) {
                    ForEach(model.outputChoices, id: \.id) { choice in Text(choice.name).tag(choice.id) }
                }.labelsHidden().accessibilityIdentifier("surface.output")
            }
            HStack {
                Text("Channel").frame(width: 74, alignment: .leading)
                Stepper("\(channel)", value: Binding(get: { channel }, set: { _ = model.setChannel(routing.id, channel: $0) }), in: 1...16)
                    .accessibilityIdentifier("surface.channel")
            }
        }
    }

    private func noteStepper(_ title: String, _ value: Int, id: String, _ set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 74, alignment: .leading)
            Stepper(MIDINoteName.displayName(for: value), value: Binding(get: { value }, set: { set($0) }), in: 0...127)
                .accessibilityIdentifier("surface.\(id)")
        }
    }

    private func transitionPicker(_ routing: SpatialRouting, _ draft: SpatialAssignmentDraft) -> some View {
        HStack {
            Text("On release").frame(width: 74, alignment: .leading)
            Picker("On release", selection: Binding(get: { draft.transition }, set: { new in
                _ = model.updateRouting(routing.id) { $0.transition = new }
            })) {
                Text("Retrigger").tag(SpatialNoteTransition.retrigger)
                Text("Legato").tag(SpatialNoteTransition.legato)
                Text("Hold until next").tag(SpatialNoteTransition.holdUntilNext)
                if case .scale = routing.program {} else { Text("Toggle").tag(SpatialNoteTransition.toggle) }
            }.labelsHidden().accessibilityIdentifier("surface.transition")
        }
    }

    private func velocityRow(_ routing: SpatialRouting, _ draft: SpatialAssignmentDraft) -> some View {
        HStack {
            Text("Velocity").frame(width: 74, alignment: .leading)
            Stepper("\(draft.velocity)", value: Binding(get: { Int(draft.velocity) }, set: { v in
                _ = model.updateRouting(routing.id) { $0.velocity = UInt8(clamping: v) }
            }), in: 1...127).accessibilityIdentifier("surface.velocity")
        }
    }

    private func noteEditor(_ routing: SpatialRouting, _ draft: SpatialAssignmentDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            noteStepper("Note", draft.rootMIDINote, id: "note") { n in _ = model.updateRouting(routing.id) { $0.rootMIDINote = n } }
            velocityRow(routing, draft)
            transitionPicker(routing, draft)
        }
    }

    private func chordEditor(_ routing: SpatialRouting, _ draft: SpatialAssignmentDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            noteStepper("Root", draft.rootMIDINote, id: "chordRoot") { n in _ = model.updateRouting(routing.id) { $0.setRootMIDINote(n) } }
            HStack {
                Text("Chord").frame(width: 74, alignment: .leading)
                Picker("Chord", selection: Binding(get: { draft.chordPreset }, set: { preset in
                    guard let preset else { return }
                    _ = model.updateRouting(routing.id) { $0.setChordPreset(preset) }
                })) {
                    if draft.chordPreset == nil { Text("Custom").tag(SpatialChordPreset?.none) }
                    ForEach(SpatialChordPreset.allCases, id: \.self) { Text($0.displayName).tag(SpatialChordPreset?.some($0)) }
                }.labelsHidden().accessibilityIdentifier("surface.chord")
            }
            Text(draft.chordNotes.map(MIDINoteName.displayName(for:)).joined(separator: " ")).foregroundColor(secondary)
            velocityRow(routing, draft)
            transitionPicker(routing, draft)
        }
    }

    private func scaleEditor(_ surface: SpatialSurface, _ routing: SpatialRouting, _ draft: SpatialAssignmentDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            noteStepper("Root", draft.rootMIDINote, id: "scaleRoot") { n in _ = model.updateRouting(routing.id) { $0.rootMIDINote = n } }
            HStack {
                Text("Scale").frame(width: 74, alignment: .leading)
                Picker("Scale", selection: Binding(get: { draft.scale }, set: { s in _ = model.updateRouting(routing.id) { $0.scale = s } })) {
                    ForEach(SpatialScale.allCases, id: \.self) { Text(SurfaceScaleName.text($0)).tag($0) }
                }.labelsHidden().accessibilityIdentifier("surface.scale")
            }
            noteStepper("Lowest", draft.lowestMIDINote, id: "scaleLow") { n in _ = model.updateRouting(routing.id) { $0.lowestMIDINote = n } }
            noteStepper("Highest", draft.highestMIDINote, id: "scaleHigh") { n in _ = model.updateRouting(routing.id) { $0.highestMIDINote = n } }
            Toggle("Pitch rises along the programmed direction", isOn: Binding(get: { draft.ascending }, set: { v in
                _ = model.updateRouting(routing.id) { $0.ascending = v }
            })).accessibilityIdentifier("surface.ascending")
            velocityNote
            transitionPicker(routing, draft)
            axisSection(surface, routing)
        }
    }

    private var velocityNote: some View { EmptyView() }

    private func controllerEditor(_ surface: SpatialSurface, _ routing: SpatialRouting, _ draft: SpatialAssignmentDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Controller").frame(width: 74, alignment: .leading)
                Stepper("CC\(draft.ccNumber) · \(MIDIControllerNames.name(draft.ccNumber))",
                        value: Binding(get: { Int(draft.ccNumber) }, set: { n in
                            _ = model.updateRouting(routing.id) { $0.target = $0.target.withControllerNumber(UInt8(clamping: n)); $0.ccNumber = UInt8(clamping: n) }
                        }), in: 0...127).accessibilityIdentifier("surface.cc")
            }
            let low = min(draft.minimumValue, draft.maximumValue) * 127, high = max(draft.minimumValue, draft.maximumValue) * 127
            measure("From value", low.rounded(), "", id: "ccLow") { _ = model.setValueRange(routing.id, from: $0, to: high) }
            measure("To value", high.rounded(), "", id: "ccHigh") { _ = model.setValueRange(routing.id, from: low, to: $0) }
            HStack {
                Text("Course").frame(width: 74, alignment: .leading)
                Picker("Course", selection: Binding(get: { draft.curve }, set: { c in _ = model.updateRouting(routing.id) { $0.curve = c } })) {
                    Text("Linear").tag(SpatialValueCurve.linear)
                    Text("Slow start").tag(SpatialValueCurve.easeIn)
                    Text("Slow finish").tag(SpatialValueCurve.easeOut)
                }.labelsHidden().accessibilityIdentifier("surface.curve")
            }
            axisSection(surface, routing)
        }
    }

    // MARK: Axis

    @ViewBuilder private func axisSection(_ surface: SpatialSurface, _ routing: SpatialRouting) -> some View {
        if let coding = SurfaceValueCoding(surface: surface, routingID: routing.id), let arrow = coding.arrow {
            VStack(alignment: .leading, spacing: 4) {
                Text("Course over the surface").font(.system(size: 11, weight: .semibold))
                Text(coding.legend).accessibilityIdentifier("surface.legend")
                Text(coding.direction).font(.system(size: 9)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                measure("Arrow bearing", (arrow.arrowBearingDegrees * 10).rounded() / 10, "°", step: 5, id: "arrowBearing") {
                    _ = model.setArrow(routing.id, bearingDegrees: $0)
                }
                Text("0° points to the front, positive turns to the right.").font(.system(size: 9)).foregroundColor(secondary)
                HStack {
                    iconButton("Reverse arrow", "arrow.left.arrow.right") { _ = model.reverseArrow(routing.id) }
                    Text("Reverse arrow").foregroundColor(secondary)
                }
                gradientColors(surface)
            }
        }
    }

    @ViewBuilder private func gradientColors(_ surface: SpatialSurface) -> some View {
        let colors = surface.presentation.valueColors
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Gradient colours")
                Spacer()
                if colors.isEmpty {
                    Button("Choose") {
                        let stops = SurfaceColorRamp.stops(surface.presentation)
                        _ = model.setValueColors(stops)
                    }.accessibilityIdentifier("surface.gradient.choose")
                } else {
                    Button("Reset") { _ = model.setValueColors([]) }.accessibilityIdentifier("surface.gradient.reset")
                }
            }
            if colors.isEmpty {
                Text("The ramp of the surface colour is used.").font(.system(size: 9)).foregroundColor(secondary)
            }
            ForEach(Array(colors.enumerated()), id: \.offset) { index, stop in
                HStack {
                    ColorPicker("Colour \(index + 1)", selection: Binding(get: { color(stop) }, set: { new in
                        var next = colors; next[index] = layerColor(new); _ = model.setValueColors(next)
                    }), supportsOpacity: false).accessibilityIdentifier("surface.gradient.\(index)")
                    if colors.count > 2 {
                        iconButton("Remove colour", "minus") { var next = colors; next.remove(at: index); _ = model.setValueColors(next) }
                    }
                }
            }
            if !colors.isEmpty && colors.count < SurfaceLimits.maximumValueColors {
                iconButton("Add colour", "plus") { _ = model.setValueColors(colors + [colors.last ?? SpatialLayerColor(red: 1, green: 1, blue: 1)]) }
            }
        }
    }

    // MARK: Playing area

    private var playingArea: some View {
        let settings = model.document.spatial.surfaceSettings
        return VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Color.white.opacity(0.1))
            Text("Selected playing area").font(.system(size: 11, weight: .semibold))
            Text("A chosen section of the instrument in the scanner's own units. It is not a measured room.")
                .font(.system(size: 9)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Shape", selection: Binding(get: { isRectangle(settings.playArea) }, set: { rect in
                guard rect != isRectangle(settings.playArea) else { return }
                var next = settings
                next.playArea = rect ? .rectangle(xMinCm: -100, xMaxCm: 100, yMinCm: 0, yMaxCm: 200) : .standard
                _ = model.setPlayingArea(next)
            })) {
                Text("Rectangle").tag(true)
                Text("Ring sector").tag(false)
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("surface.playArea.shape")
            switch settings.playArea {
            case .rectangle(let x0, let x1, let y0, let y1):
                area("Left", x0, id: "xMin") { setArea(settings, .rectangle(xMinCm: $0, xMaxCm: x1, yMinCm: y0, yMaxCm: y1)) }
                area("Right", x1, id: "xMax") { setArea(settings, .rectangle(xMinCm: x0, xMaxCm: $0, yMinCm: y0, yMaxCm: y1)) }
                area("Near", y0, id: "yMin") { setArea(settings, .rectangle(xMinCm: x0, xMaxCm: x1, yMinCm: $0, yMaxCm: y1)) }
                area("Far", y1, id: "yMax") { setArea(settings, .rectangle(xMinCm: x0, xMaxCm: x1, yMinCm: y0, yMaxCm: $0)) }
            case .sector(let r0, let r1, let a0, let a1):
                area("From radius", r0, id: "r0") { setArea(settings, .sector(fromCm: $0, toCm: r1, fromDegrees: a0, toDegrees: a1)) }
                area("To radius", r1, id: "r1") { setArea(settings, .sector(fromCm: r0, toCm: $0, fromDegrees: a0, toDegrees: a1)) }
                area("From bearing", a0, unit: "°", id: "a0") { setArea(settings, .sector(fromCm: r0, toCm: r1, fromDegrees: $0, toDegrees: a1)) }
                area("To bearing", a1, unit: "°", id: "a1") { setArea(settings, .sector(fromCm: r0, toCm: r1, fromDegrees: a0, toDegrees: $0)) }
            }
            HStack {
                Text("Outside").frame(width: 74, alignment: .leading)
                Picker("Outside", selection: Binding(get: { settings.outsidePolicy }, set: { policy in
                    var next = settings; next.outsidePolicy = policy; _ = model.setPlayingArea(next)
                })) {
                    Text("Refuse").tag(SurfaceOutsidePolicy.error)
                    Text("Clip").tag(SurfaceOutsidePolicy.clip)
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("surface.playArea.policy")
            }
            Text(settings.outsidePolicy == .error ? "A surface that reaches outside is refused." : "Parts outside are cut off; nothing is moved.")
                .font(.system(size: 9)).foregroundColor(secondary)
        }
    }

    private func isRectangle(_ area: SurfacePlayArea) -> Bool { if case .rectangle = area { return true }; return false }
    private func setArea(_ settings: SurfaceSettings, _ area: SurfacePlayArea) {
        var next = settings; next.playArea = area; _ = model.setPlayingArea(next)
    }
    private func area(_ title: String, _ value: Double, unit: String = "cm", id: String, commit: @escaping (Double) -> Void) -> some View {
        SurfaceMeasureField(title: title, value: value, unit: unit, step: 5, id: "playArea.\(id)", model: model, commit: commit)
    }
}

/// The name field commits on Return or when focus leaves.
struct SurfaceNameField: View {
    let name: String
    let id: UUID
    let commit: (String) -> Void
    @State private var text = ""
    @State private var editing = false
    var body: some View {
        TextField("Name", text: Binding(get: { editing ? text : name }, set: { text = $0; editing = true }), onCommit: {
            editing = false
            commit(text)
        }).textFieldStyle(.roundedBorder).accessibilityIdentifier("surface.name")
    }
}
