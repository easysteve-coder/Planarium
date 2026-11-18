import Foundation
import PlanariumDomain
import SickPLSMonitorKit

/// What a routing of a surface plays, in the words of the inspector.
public enum SurfacePlays: CaseIterable, Equatable, Sendable {
    case note, chord, scale, controller
    public var title: String {
        switch self {
        case .note: return "Note"
        case .chord: return "Chord"
        case .scale: return "Scale"
        case .controller: return "CC"
        }
    }
    /// Classifies a routing; `nil` for programs the surface inspector keeps untouched (program change, scene switch,
    /// release, random scale, constants, effect parameters).
    public static func of(_ routing: SpatialRouting) -> SurfacePlays? {
        switch (routing.program, routing.target) {
        case (.singleNote, .audioUnitNote), (.singleNote, .midiNote): return .note
        case (.chord, .audioUnitNote), (.chord, .midiNote): return .chord
        case (.scale, .audioUnitNote), (.scale, .midiNote): return .scale
        case (.continuous, .audioUnitCC), (.continuous, .midiCC): return .controller
        default: return nil
        }
    }
}

/// Inspector commands. Each one is a validated document edit through `applySurfaceEdits`; a value the
/// domain refuses leaves the document unchanged and the reason in `hint`.
extension SurfaceEditorModel {
    @discardableResult
    func commit(_ edits: [SurfaceEdit], _ name: String) -> Bool {
        hint = nil
        let before = instrument.notice
        // A single edit goes through the series-aware path, so a held stepper is one undo step; several
        // edits belong together and are one validated commit of their own.
        let applied = edits.count == 1 ? instrument.applySurfaceEdit(edits[0]) : instrument.applySurfaceEdits(edits, undoName: name)
        if applied { return true }
        hint = instrument.notice.flatMap { $0 == before && before != nil ? nil : $0 } ?? instrument.notice ?? "The change was refused"
        return false
    }

    /// The surface the inspector edits: exactly one selected.
    public var singleSurface: SpatialSurface? { selectedSurfaces.count == 1 ? selectedSurfaces.first : nil }

    // MARK: Series (steppers)

    public func beginAdjusting() { instrument.beginSurfaceEditSeries() }
    public func endAdjusting() { instrument.endSurfaceEditSeries() }
    @discardableResult public func cancelAdjusting() -> Bool { instrument.cancelSurfaceEditSeries() }

    // MARK: Presentation

    @discardableResult
    public func rename(_ name: String) -> Bool {
        guard let surface = singleSurface else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { hint = "A surface needs a name"; return false }
        var next = surface.presentation; next.name = trimmed
        guard next != surface.presentation else { return true }
        return commit([.setPresentation(surfaceID: surface.id, next)], "Rename surface")
    }
    @discardableResult
    public func setColor(_ color: SpatialLayerColor) -> Bool {
        let edits = selectedSurfaces.compactMap { surface -> SurfaceEdit? in
            var next = surface.presentation; next.color = color
            return next == surface.presentation ? nil : .setPresentation(surfaceID: surface.id, next)
        }
        return commit(edits, "Colour surface")
    }
    /// The colours of the value course (two to sixteen), or none for the dark-to-bright ramp of the surface colour.
    @discardableResult
    public func setValueColors(_ colors: [SpatialLayerColor]) -> Bool {
        guard let surface = singleSurface else { return false }
        var next = surface.presentation; next.valueColors = colors
        guard next != surface.presentation else { return true }
        return commit([.setPresentation(surfaceID: surface.id, next)], "Course colours")
    }

    // MARK: Placement

    private func shaped(_ surface: SpatialSurface) -> (shape: SurfaceShape, transform: SurfaceTransform)? {
        if case .shape(let shape, let transform) = surface.form { return (shape, transform) }
        return nil
    }
    @discardableResult
    public func setPlacement(xCm: Double? = nil, yCm: Double? = nil, rotationDegrees: Double? = nil, mirrored: Bool? = nil) -> Bool {
        guard let surface = singleSurface, var (_, transform) = shaped(surface).map({ ($0.shape, $0.transform) }) else {
            hint = "This area cannot be placed by numbers"; return false
        }
        if let xCm { transform.xCm = xCm }
        if let yCm { transform.yCm = yCm }
        if let rotationDegrees { transform.rotationDegrees = rotationDegrees }
        if let mirrored { transform.mirrorX = mirrored }
        return commit([.setTransform(id: surface.id, transform)], "Place surface")
    }
    @discardableResult
    public func setSize(widthCm: Double? = nil, heightCm: Double? = nil, radiusCm: Double? = nil) -> Bool {
        guard let surface = singleSurface, let (shape, transform) = shaped(surface).map({ ($0.shape, $0.transform) }) else { return false }
        let next: SurfaceShape
        switch shape {
        case .rectangle(let w, let h): next = .rectangle(widthCm: widthCm ?? w, heightCm: heightCm ?? h)
        case .circle(let r): next = .circle(radiusCm: radiusCm ?? r)
        default: return false
        }
        return commit([.resizeSurface(id: surface.id, shape: next, transform: transform)], "Resize surface")
    }
    @discardableResult
    public func setSector(fromCm: Double? = nil, toCm: Double? = nil, fromDegrees: Double? = nil, toDegrees: Double? = nil) -> Bool {
        guard let surface = singleSurface, case .ringSector(let a, let b, let c, let d)? = shaped(surface)?.shape else { return false }
        return commit([.resizeSurface(id: surface.id, shape: .ringSector(fromCm: fromCm ?? a, toCm: toCm ?? b,
                                                                       fromDegrees: fromDegrees ?? c, toDegrees: toDegrees ?? d),
                                       transform: .identity)], "Resize surface")
    }

    // MARK: Assignments

    /// Destination choices for the output of a routing: the strips of the document and the MIDI output.
    public var outputChoices: [(id: UUID?, name: String)] {
        document.channels.map { ($0.id, $0.name) } + [(nil, "MIDI output")]
    }

    @discardableResult
    public func setRoutings(_ routings: [SpatialRouting], undoName: String = "Change assignment") -> Bool {
        guard let surface = singleSurface else { return false }
        guard !routings.isEmpty else { hint = "A surface needs at least one assignment"; return false }
        return commit([.setRoutings(surfaceID: surface.id, routings: routings)], undoName)
    }

    /// Changes one routing with the draft the older inspector uses, so both agree on what a note, chord, scale or CC means.
    @discardableResult
    public func updateRouting(_ id: UUID, undoName: String = "Change assignment", _ change: (inout SpatialAssignmentDraft) -> Void) -> Bool {
        guard let surface = singleSurface, let index = surface.routings.firstIndex(where: { $0.id == id }) else { return false }
        var routings = surface.routings
        var draft = SpatialAssignmentDraft.from(program: routings[index].program, target: routings[index].target)
        change(&draft)
        routings[index].target = draft.target
        routings[index].program = SpatialAssignmentDraft.program(from: draft)
        // The older draft puts a CC range in ascending order, which would turn an inverse range around
        // whenever anything else about it changes. The surface inspector keeps the stored direction.
        if draft.kind == .continuous, case .continuous(let low, let high, let degrees, let curve) = routings[index].program,
           draft.minimumValue > draft.maximumValue, low < high {
            routings[index].program = .continuous(minimum: draft.minimumValue, maximum: draft.maximumValue, directionDegrees: degrees, curve: curve)
        }
        if draft.kind == .chord { routings[index].chordRootMIDINote = nil }
        return setRoutings(routings, undoName: undoName)
    }

    /// Changes what a routing plays. The destination (strip or MIDI output and channel) stays; the message type follows.
    @discardableResult
    public func setPlays(_ id: UUID, _ plays: SurfacePlays) -> Bool {
        updateRouting(id, undoName: "Change assignment") { draft in
            let channel: UInt8, strip: UUID?
            switch draft.target {
            case .audioUnitNote(let c, let s), .audioUnitCC(let c, _, let s): channel = c; strip = s
            case .midiNote(let c), .midiCC(let c, _): channel = c; strip = nil
            default: channel = 0; strip = document.channels.first?.id
            }
            func note() -> SpatialRoutingTarget { strip.map { .audioUnitNote(channel: channel, stripID: $0) } ?? .midiNote(channel: channel) }
            switch plays {
            case .note: draft.target = note(); draft.kind = .singleNote
            case .chord:
                draft.target = note(); draft.setChordPreset(.major)
            case .scale:
                draft.target = note(); draft.kind = .scale
                draft.lowestMIDINote = draft.rootMIDINote; draft.highestMIDINote = min(127, draft.rootMIDINote + 12)
                if draft.transition == .toggle { draft.transition = .retrigger }
            case .controller:
                let cc = draft.ccNumber
                draft.target = strip.map { .audioUnitCC(channel: channel, controller: cc, stripID: $0) } ?? .midiCC(channel: channel, controller: cc)
                draft.kind = .continuous
                draft.minimumValue = 0; draft.maximumValue = 1
            }
        }
    }

    /// Moves a routing's output to a strip (`stripID`) or the MIDI output (`nil`), keeping channel and message.
    @discardableResult
    public func setOutput(_ id: UUID, stripID: UUID?) -> Bool {
        updateRouting(id, undoName: "Change output") { draft in
            let destination: SpatialRoutingDestination = stripID == nil ? .midi : .audioUnit
            draft.target = draft.target.retargeted(to: destination, stripID: stripID ?? UUID())
        }
    }
    @discardableResult
    public func setChannel(_ id: UUID, channel: Int) -> Bool {
        let value = UInt8(clamping: min(max(channel, 1), 16) - 1)
        return updateRouting(id, undoName: "Change channel") { draft in
            switch draft.target {
            case .audioUnitNote(_, let s): draft.target = .audioUnitNote(channel: value, stripID: s)
            case .audioUnitCC(_, let cc, let s): draft.target = .audioUnitCC(channel: value, controller: cc, stripID: s)
            case .midiNote: draft.target = .midiNote(channel: value)
            case .midiCC(_, let cc): draft.target = .midiCC(channel: value, controller: cc)
            default: break
            }
        }
    }
    @discardableResult
    public func addRouting(copying id: UUID) -> Bool {
        guard let surface = singleSurface, let source = surface.routings.first(where: { $0.id == id }) else { return false }
        let copy = SpatialRouting(id: UUID(), target: source.target, program: source.program, chordRootMIDINote: source.chordRootMIDINote)
        guard setRoutings(surface.routings + [copy], undoName: "Add assignment") else { return false }
        selectRouting(copy.id)
        return true
    }
    @discardableResult
    public func removeRouting(_ id: UUID) -> Bool {
        guard let surface = singleSurface else { return false }
        let rest = surface.routings.filter { $0.id != id }
        guard setRoutings(rest, undoName: "Remove assignment") else { return false }
        selectRouting(rest.first.map(\.id))
        return true
    }

    // MARK: Axis

    /// Turns the arrow of a routing to a bearing (0° = front, positive to the right).
    @discardableResult
    public func setArrow(_ routingID: UUID, bearingDegrees: Double) -> Bool {
        guard let surface = singleSurface,
              let routing = surface.materializedRoutings().first(where: { $0.id == routingID }) else { return false }
        var program = SurfaceAxis.programDegrees(fromBearing: bearingDegrees)
        // The stored direction is where the program reads from low to high; an inverse range reads backwards.
        if SurfaceAxis.risesAgainstDirection(routing.program) { program += 180 }
        return commit([.setAxis(surfaceID: surface.id, routingID: routingID, worldDegrees: SurfaceAxis.normalized(program))], "Turn arrow")
    }
    @discardableResult
    public func reverseArrow(_ routingID: UUID) -> Bool {
        guard let surface = singleSurface else { return false }
        return commit([.reverseAxis(surfaceID: surface.id, routingID: routingID)], "Reverse arrow")
    }
    /// The value range of a CC as 0…127 units: `low` is the value at the start of the arrow, `high` the one at its
    /// tip. An inverse range stays inverse when one end is changed, because the order in the stored program follows
    /// the programmed direction while the arrow always points to the higher value. Entering a start above the end
    /// deliberately turns the course around.
    @discardableResult
    public func setValueRange(_ routingID: UUID, from low: Double, to high: Double) -> Bool {
        guard let surface = singleSurface,
              let routing = surface.routings.first(where: { $0.id == routingID }) else { return false }
        let inverse = SurfaceAxis.risesAgainstDirection(routing.program)
        return commit([.setValueRange(surfaceID: surface.id, routingID: routingID,
                                      minimum: (inverse ? high : low) / 127, maximum: (inverse ? low : high) / 127)], "Change range")
    }

    // MARK: Playing area

    @discardableResult
    public func setPlayingArea(_ settings: SurfaceSettings) -> Bool {
        commit([.setSurfaceSettings(settings)], "Change playing area")
    }

    // MARK: Existing layers (exact areas of older presets)

    /// The layer an unconverted (cell based) area belongs to, when one is chosen in the field.
    public var legacyLayer: SpatialDocumentLayer? {
        guard selectedSurfaceIDs.isEmpty,
              let id = instrument.canvas.selection.layerIDs.first, instrument.canvas.selection.layerIDs.count == 1,
              let layer = document.spatial.layers.first(where: { $0.id == id }), !layer.isSurfaceBacked, !layer.cells.isEmpty
        else { return nil }
        return layer
    }
    /// One step on an existing area. The area is converted to an exact surface in the same undo step; nothing changes by looking.
    @discardableResult
    public func legacyOperation(_ layerID: UUID, _ edit: (UUID) -> SurfaceEdit, name: String) -> Bool {
        guard let layer = document.spatial.layers.first(where: { $0.id == layerID }) else { return false }
        var edits: [SurfaceEdit] = []
        if !layer.isSurfaceBacked { edits.append(.promoteLayer(layerID: layerID)) }
        edits.append(edit(layerID))
        guard commit(edits, name) else { return false }
        _ = select([layerID])
        return true
    }
    /// What replacing the exact area of a layer by a shape drops, for the confirmation.
    public func lossOfReplacing(layerID: UUID) -> (cells: Int, overrides: Int)? {
        guard let layer = document.spatial.layers.first(where: { $0.id == layerID }) else { return nil }
        if layer.isSurfaceBacked { return SurfaceEditor.lossOfReplacingMask(surfaceID: layerID, in: document) }
        return (layer.cells.count, layer.cellOverrides.count)
    }
}

extension SurfaceEditorModel {
    /// Replaces the exact area of a layer by the rectangle around it. The caller has shown what is dropped.
    @discardableResult
    public func replaceWithRectangle(layerID: UUID) -> Bool {
        guard let layer = document.spatial.layers.first(where: { $0.id == layerID }) else { return false }
        let cells: [PolarDeviceLattice] = layer.isSurfaceBacked ? (layer.surfaces.first?.cells ?? []) : Array(layer.cells)
        guard !cells.isEmpty else { return false }
        let points = cells.map { SurfaceGrid.point(ring: $0.ring, tick: $0.sector) }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!, minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let width = max(1, SurfaceTidy.centimeters(maxX - minX)), height = max(1, SurfaceTidy.centimeters(maxY - minY))
        let transform = SurfaceTransform(xCm: SurfaceTidy.centimeters((minX + maxX) / 2), yCm: SurfaceTidy.centimeters((minY + maxY) / 2))
        return legacyOperation(layerID, { .replaceMaskWithShape(surfaceID: $0, shape: .rectangle(widthCm: width, heightCm: height), transform: transform) },
                               name: "Replace area by rectangle")
    }
}
