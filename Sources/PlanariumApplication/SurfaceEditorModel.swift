import Combine
import CoreGraphics
import Foundation
import PlanariumDomain
import SickPLSMonitorKit

/// The mouse cursor a spot of the field asks for. The view turns it into a system cursor.
public enum SurfaceCursorKind: Equatable, Sendable {
    case arrow, crosshair, move, resizeHorizontal, resizeVertical, resizeDiagonal, rotate, forbidden
}

/// The field's surface editor: tool, selection, the sketch of the drag in progress and every
/// command a pointer, a key or the inspector gives to surfaces. It owns no document and no history:
/// a gesture is a sketch until it is let go, and then it reaches the document exactly once through
/// `SpatialInstrumentRuntimeModel.applySurfaceEdits` (permission, validation, compile, one undo step).
/// Nothing here starts a note, a timer or a task.
@MainActor public final class SurfaceEditorModel: ObservableObject {
    public enum Mode: Equatable, Sendable {
        /// The normal editor: the surface is the unit.
        case surfaces
        /// The advanced cell editor of the older presets.
        case cells
    }

    public unowned let instrument: SpatialInstrumentRuntimeModel
    @Published public private(set) var mode: Mode = .surfaces
    @Published public private(set) var tool: SurfaceTool = .select
    @Published public private(set) var gesture: SurfaceGesture?
    @Published public private(set) var preview: SurfaceGesture.Result?
    @Published public private(set) var polygon: SurfacePolygonDraft?
    /// The measuring grid as an alignment aid; off unless asked for.
    @Published public private(set) var showsGrid = false
    /// Last thing worth telling about the sketch or a refused handle (cleared by the next action).
    @Published public internal(set) var hint: String?
    private var space: SurfaceCanvasSpace?
    private var nudgeKeyCode: UInt16?
    private var pendingClick: PendingClick?

    private struct PendingClick {
        enum Reason { case toggle(UUID), narrowTo(UUID), clear }
        let reason: Reason
    }

    init(instrument: SpatialInstrumentRuntimeModel) { self.instrument = instrument }

    // MARK: Mode and tool

    public func setMode(_ next: Mode) {
        guard next != mode else { return }
        cancelEverything()
        mode = next
        if next == .surfaces, instrument.canvas.presentation.tool != .select { instrument.canvas.select(tool: .select) }
        instrument.refreshCanvasPresentation()
        instrument.objectWillChange.send()
    }
    public func select(tool next: SurfaceTool) {
        if next != tool { cancelEverything(); tool = next }
        if instrument.canvas.presentation.tool != .select { instrument.canvas.select(tool: .select) }
    }
    public func setShowsGrid(_ value: Bool) { if showsGrid != value { showsGrid = value } }

    /// Says why a key or command does nothing here; changes no document.
    public func refuse(_ text: String) { hint = text }

    public var isSketching: Bool { gesture != nil || polygon != nil }

    // MARK: Selection (read)

    public var document: InstrumentDocument { instrument.document }
    public var selectedSurfaceIDs: Set<UUID> { instrument.canvas.selection.surfaceIDs }
    /// The selected surfaces that still exist, in document order.
    public var selectedSurfaces: [SpatialSurface] {
        let ids = selectedSurfaceIDs
        guard !ids.isEmpty else { return [] }
        return document.spatial.layers.flatMap(\.surfaces).filter { ids.contains($0.id) }
    }
    public func layer(of surfaceID: UUID) -> SpatialDocumentLayer? {
        document.spatial.layers.first { $0.surfaces.contains { $0.id == surfaceID } }
    }
    /// The assignment whose control arrow is shown: the chosen one, else the first with an axis.
    public var axisRoutingID: UUID? {
        let surfaces = selectedSurfaces
        guard surfaces.count == 1, let surface = surfaces.first else { return nil }
        if let id = instrument.canvas.selection.routingID, surface.routings.contains(where: { $0.id == id }) { return id }
        return Self.defaultRoutingID(of: surface)
    }
    nonisolated public static func defaultRoutingID(of surface: SpatialSurface) -> UUID? {
        (surface.routings.first { SurfaceAxis.directionDegrees(of: $0.program) != nil } ?? surface.routings.first)?.id
    }
    /// Why nothing can be edited right now.
    public var lockedReason: String? {
        if instrument.canvas.isPerformanceLocked { return InstrumentAction.performanceLockReason }
        let layers = Set(selectedSurfaces.compactMap { layer(of: $0.id)?.id })
        if document.spatial.layers.contains(where: { layers.contains($0.id) && $0.isLocked }) { return "Layer is locked" }
        return nil
    }

    public func handleLayout(geometry: MetricCanvasGeometry) -> SurfaceHandleLayout {
        guard mode == .surfaces, !isSketching || gesture != nil else { return .empty }
        return SurfaceHandleLayout.make(surfaces: selectedSurfaces, axisRoutingID: axisRoutingID,
                                        space: SurfaceCanvasSpace(geometry), lockedReason: lockedReason)
    }

    // MARK: Selecting

    @discardableResult
    public func select(_ ids: Set<UUID>, routingID: UUID? = nil) -> Bool {
        // Across layers the topmost layer of the stack that holds a chosen surface becomes the layer new surfaces go to.
        let holding = Set(ids.compactMap { layer(of: $0)?.id })
        let layerID = document.spatial.layers.last { holding.contains($0.id) }?.id
        var routing = routingID
        if routing == nil, ids.count == 1, let id = ids.first, let surface = document.spatial.layers.flatMap(\.surfaces).first(where: { $0.id == id }) {
            routing = Self.defaultRoutingID(of: surface)
        }
        return instrument.canvas.selectSurfaces(ids, routingID: routing, inLayer: layerID)
    }
    public func selectRouting(_ id: UUID?) {
        guard let first = selectedSurfaces.first, selectedSurfaces.count == 1 else { return }
        _ = instrument.canvas.selectSurfaces([first.id], routingID: id, inLayer: nil)
    }
    public func clearSelection() { _ = instrument.canvas.selectSurfaces([]) }
    @discardableResult
    public func selectAll() -> Bool {
        let ids = Set(document.spatial.layers.filter { $0.isVisible && !$0.isLocked }.flatMap(\.surfaces).map(\.id))
        guard !ids.isEmpty else { hint = "There is no surface to select"; return false }
        return select(ids)
    }

    /// Called by the document owner after every installed document: selection and sketch follow it.
    func documentDidChange(_ value: InstrumentDocument) {
        cancelGesture()
        // A polygon being clicked together belongs to the document it was started on; an undo, a preset
        // or any other replacement drops it. A nudge burst is not touched: its own installs land here too.
        polygon = nil
        let live = Set(value.spatial.layers.flatMap(\.surfaces).map(\.id))
        let chosen = instrument.canvas.selection.surfaceIDs
        let kept = chosen.intersection(live)
        if kept != chosen {
            var routing = instrument.canvas.selection.routingID
            if kept.count == 1, let surface = value.spatial.layers.flatMap(\.surfaces).first(where: { $0.id == kept.first }) {
                if routing == nil || !surface.routings.contains(where: { $0.id == routing }) { routing = Self.defaultRoutingID(of: surface) }
            }
            _ = instrument.canvas.selectSurfaces(kept, routingID: routing)
        }
    }

    // MARK: Pointer

    /// - Returns: whether the press belongs to the surface editor (the view then does not treat it as a cell gesture).
    @discardableResult
    public func pointerDown(at screen: CGPoint, geometry: MetricCanvasGeometry, modifiers: SurfaceModifiers, clickCount: Int = 1) -> Bool {
        guard mode == .surfaces else { return false }
        hint = nil
        guard instrument.authorize(.edit) else { return true }
        let space = SurfaceCanvasSpace(geometry)
        self.space = space
        guard let world = space.world(screen) else { return true }
        if tool == .polygon {
            if clickCount >= 2 { _ = finishPolygon(); return true }
            var draft = polygon ?? SurfacePolygonDraft()
            if draft.points.count >= 3, let first = draft.points.first,
               hypot(space.screen(first).x - screen.x, space.screen(first).y - screen.y) <= 10 {
                polygon = draft
                _ = finishPolygon(); return true
            }
            draft.add(world)
            draft.hover = world
            polygon = draft
            hint = draft.message
            return true
        }
        if tool.drawsNewSurfaces {
            guard let layerID = targetLayerID() else { return true }
            gesture = SurfaceGesture(kind: .draw(tool), space: space, startScreen: screen, start: world,
                                     originals: [], layerID: layerID, modifiers: modifiers)
            preview = gesture?.evaluate()
            return true
        }
        // Select tool. A handle of the selection comes first.
        let layout = SurfaceHandleLayout.make(surfaces: selectedSurfaces, axisRoutingID: axisRoutingID, space: space, lockedReason: lockedReason)
        if let handle = layout.handle(at: screen) {
            guard handle.isEnabled else { hint = handle.disabledReason; return true }
            beginHandleGesture(handle.kind, screen: screen, world: world, modifiers: modifiers)
            return true
        }
        let pick = SurfacePicker.pick(at: world, in: document.spatial)
        let selected = selectedSurfaceIDs
        if let pick {
            if selected.contains(pick.surfaceID) {
                // Pressing a chosen surface moves all chosen ones; without a drag, ⇧ takes it out, a plain click narrows to it.
                pendingClick = modifiers.contains(.shift) ? .init(reason: .toggle(pick.surfaceID)) : .init(reason: .narrowTo(pick.surfaceID))
            } else {
                var ids: Set<UUID> = modifiers.contains(.shift) ? selected.union([pick.surfaceID]) : [pick.surfaceID]
                if modifiers.contains(.command) { ids = selected.union([pick.surfaceID]) }
                guard select(ids, routingID: nil) else { return true }
                pendingClick = nil
            }
            beginMove(screen: screen, world: world, modifiers: modifiers)
            return true
        }
        if let legacy = SurfacePicker.pickLegacyLayer(at: world, in: document.spatial) {
            _ = instrument.canvas.selectLayers([legacy], active: legacy)
            return true
        }
        // Empty field: a box selects; a plain click clears.
        pendingClick = modifiers.contains(.shift) ? nil : .init(reason: .clear)
        gesture = SurfaceGesture(kind: .marquee(additive: modifiers.contains(.shift)), space: space, startScreen: screen, start: world,
                                 originals: [], modifiers: modifiers)
        preview = gesture?.evaluate()
        return true
    }

    /// A secondary click on a surface chooses it (unless it is already chosen) before its menu opens.
    /// - Returns: whether there is anything to act on.
    public func prepareContextMenu(at screen: CGPoint, geometry: MetricCanvasGeometry) -> Bool {
        guard mode == .surfaces, instrument.authorize(.edit), let world = SurfaceCanvasSpace(geometry).world(screen),
              let pick = SurfacePicker.pick(at: world, in: document.spatial) else { return false }
        if !selectedSurfaceIDs.contains(pick.surfaceID) { return select([pick.surfaceID]) }
        return true
    }

    private func beginMove(screen: CGPoint, world: SurfacePoint, modifiers: SurfaceModifiers) {
        let chosen = selectedSurfaces
        if let reason = SurfaceGesture.moveRefusal(chosen) {
            // A sector or an exact area is selected but not dragged; say why once the user actually drags.
            hint = reason; gesture = nil; preview = nil; return
        }
        gesture = SurfaceGesture(kind: .move, space: space ?? SurfaceCanvasSpace(MetricCanvasGeometry(size: .init(width: 1, height: 1), viewport: .instrumentDefault)),
                                 startScreen: screen, start: world, originals: chosen, modifiers: modifiers)
        preview = gesture?.evaluate()
    }

    private func beginHandleGesture(_ handle: SurfaceHandleKind, screen: CGPoint, world: SurfacePoint, modifiers: SurfaceModifiers) {
        guard let space else { return }
        let chosen = selectedSurfaces
        let kind: SurfaceGesture.Kind
        switch handle {
        case .rotate:
            let bounds = chosen.dropFirst().reduce(chosen[0].worldBounds) { $0.union($1.worldBounds) }
            let pivot = SurfaceTidy.point(SurfacePoint(x: (bounds.minX + bounds.maxX) / 2, y: (bounds.minY + bounds.maxY) / 2))
            kind = .rotate(pivot: pivot, startAngle: SurfaceFrame.angleDegrees(from: pivot, to: world))
        default: kind = .handle(handle)
        }
        gesture = SurfaceGesture(kind: kind, space: space, startScreen: screen, start: world, originals: chosen, modifiers: modifiers)
        preview = gesture?.evaluate()
    }

    public func pointerMoved(to screen: CGPoint, geometry: MetricCanvasGeometry) {
        guard tool == .polygon, var draft = polygon, let world = SurfaceCanvasSpace(geometry).world(screen) else { return }
        draft.hover = world
        polygon = draft
    }

    public func pointerDragged(to screen: CGPoint, modifiers: SurfaceModifiers) {
        guard var current = gesture else { return }
        guard current.update(toScreen: screen, modifiers: modifiers) else { return }
        gesture = current
        preview = current.isDrag ? current.evaluate() : nil
    }

    public func pointerUp(at screen: CGPoint, modifiers: SurfaceModifiers) {
        guard var current = gesture else { pendingClick = nil; return }
        _ = current.update(toScreen: screen, modifiers: modifiers)
        gesture = nil; preview = nil
        defer { pendingClick = nil }
        guard instrument.authorize(.edit) else { return }
        if case .marquee(let additive) = current.kind {
            if current.isDrag, let rect = current.evaluate().marquee, let a = current.space.world(rect.origin),
               let b = current.space.world(CGPoint(x: rect.maxX, y: rect.maxY)) {
                let box = SurfaceBounds(minX: min(a.x, b.x), maxX: max(a.x, b.x), minY: min(a.y, b.y), maxY: max(a.y, b.y))
                let found = Set(SurfacePicker.surfaces(in: box, document: document.spatial).map(\.surfaceID))
                _ = select(additive ? selectedSurfaceIDs.union(found) : found)
            } else if case .clear? = pendingClick?.reason { clearSelection() }
            return
        }
        guard current.isDrag else {
            // A click: select what was pressed, change nothing else.
            if case .draw = current.kind { hint = "Drag to draw a surface"; return }
            switch pendingClick?.reason {
            case .toggle(let id)?: var ids = selectedSurfaceIDs; ids.remove(id); _ = select(ids)
            case .narrowTo(let id)?: if selectedSurfaceIDs != [id] { _ = select([id]) }
            default: break
            }
            return
        }
        let result = current.evaluate()
        if let problem = result.problem { hint = problem; return }
        switch current.kind {
        case .draw:
            guard let drawn = result.drawn, let layerID = current.layerID else { return }
            _ = addSurface(shape: drawn.shape, transform: drawn.transform, toLayer: layerID)
        default:
            guard !result.edits.isEmpty else { return }
            _ = instrument.applySurfaceEdits(result.edits, undoName: result.undoName)
        }
    }

    /// Escape, a change of tool, focus or document: the sketch is dropped and nothing is committed.
    @discardableResult
    public func cancelGesture() -> Bool {
        let had = gesture != nil
        gesture = nil; preview = nil; pendingClick = nil
        return had
    }
    /// Everything in progress: a drag, a polygon being clicked together, a held nudge.
    @discardableResult
    public func cancelEverything() -> Bool {
        let had = gesture != nil || polygon != nil || nudgeKeyCode != nil
        gesture = nil; preview = nil; polygon = nil; pendingClick = nil; hint = nil
        endNudge()
        return had
    }

    // MARK: Polygon

    @discardableResult
    public func finishPolygon() -> Bool {
        guard let draft = polygon else { return false }
        guard let shaped = draft.shape(), let layerID = targetLayerID() else {
            hint = draft.message ?? "A polygon needs at least 3 corners"; return false
        }
        polygon = nil
        return addSurface(shape: shaped.shape, transform: shaped.transform, toLayer: layerID) != nil
    }
    @discardableResult
    public func removeLastPolygonPoint() -> Bool {
        guard var draft = polygon, draft.removeLast() else { return false }
        polygon = draft.points.isEmpty ? nil : draft
        hint = draft.message
        return true
    }

    // MARK: Adding

    /// The layer a new surface goes into: the selected one, if it can take one.
    private func targetLayerID() -> UUID? {
        let layer = document.spatial.layers.first { $0.id == instrument.canvas.workspace.selectedLayerID } ?? document.spatial.layers.first
        guard let layer else { return nil }
        if layer.isLocked { hint = "Layer is locked"; return nil }
        return layer.id
    }

    /// Adds a surface to a layer. A layer that still holds cells of an older preset is first converted
    /// to an exact area in the same step, so one undo takes both back. Returns the new surface's identity.
    @discardableResult
    public func addSurface(shape: SurfaceShape, transform: SurfaceTransform, toLayer layerID: UUID) -> UUID? {
        guard let layer = document.spatial.layers.first(where: { $0.id == layerID }) else { return nil }
        let id = UUID()
        let draft = SurfaceDraft(id: id, presentation: .init(name: newSurfaceName(), color: layer.color),
                                 shape: shape, transform: transform, routings: defaultRoutings(for: layer))
        var edits: [SurfaceEdit] = []
        if !layer.isSurfaceBacked && !(layer.cells.isEmpty && layer.routings.isEmpty && layer.cellOverrides.isEmpty) {
            edits.append(.promoteLayer(layerID: layerID))
        }
        edits.append(.addSurface(layerID: layerID, draft))
        guard instrument.applySurfaceEdits(edits, undoName: "Add surface") else { return nil }
        _ = instrument.canvas.workspace.selectedLayerID == layerID ? true : instrument.canvas.selectLayers([layerID], active: layerID)
        _ = select([id])
        return id
    }

    /// What a new surface plays: what its neighbours in the layer play, else the layer's own assignment,
    /// else a single middle C on the first strip, which the inspector then changes.
    func defaultRoutings(for layer: SpatialDocumentLayer) -> [SpatialRouting] {
        func fresh(_ routings: [SpatialRouting]) -> [SpatialRouting] {
            routings.map { SpatialRouting(id: UUID(), target: $0.target, program: $0.program, chordRootMIDINote: $0.chordRootMIDINote) }
        }
        if let sibling = layer.surfaces.last, !sibling.routings.isEmpty { return fresh(sibling.routings) }
        if !layer.routings.isEmpty { return fresh(layer.routings) }
        guard let strip = document.channels.first else { return [] }
        return [SpatialRouting(target: .audioUnitNote(channel: 0, stripID: strip.id),
                               program: .singleNote(note: 60, velocity: 100, transition: .retrigger))]
    }

    private func newSurfaceName() -> String {
        let taken = Set(document.spatial.layers.flatMap(\.surfaces).map(\.presentation.name))
        var number = document.spatial.layers.flatMap(\.surfaces).count + 1
        while taken.contains("Surface \(number)") { number += 1 }
        return "Surface \(number)"
    }

    // MARK: Commands on the selection

    @discardableResult
    public func deleteSelection() -> Bool {
        let ids = selectedSurfaces.map(\.id)
        guard !ids.isEmpty else { hint = "Nothing selected"; return false }
        cancelEverything()
        let before = selectedSurfaceIDs
        guard instrument.applySurfaceEdits([.deleteSurfaces(ids: ids)], undoName: "Delete surfaces") else { return false }
        _ = before
        return true
    }

    @discardableResult
    public func duplicateSelection(offsetCm: Double = 10) -> Bool {
        let ids = selectedSurfaces.map(\.id)
        guard !ids.isEmpty else { hint = "Nothing selected"; return false }
        cancelEverything()
        let known = Set(document.spatial.layers.flatMap(\.surfaces).map(\.id))
        guard instrument.applySurfaceEdits([.duplicateSurfaces(ids: ids, dxCm: offsetCm, dyCm: 0)], undoName: "Duplicate surfaces") else { return false }
        let copies = Set(document.spatial.layers.flatMap(\.surfaces).map(\.id)).subtracting(known)
        if !copies.isEmpty { _ = select(copies) }
        return true
    }

    /// Mirrors the selection left/right about the middle of its box.
    @discardableResult
    public func mirrorSelection() -> Bool {
        let chosen = selectedSurfaces
        guard !chosen.isEmpty else { hint = "Nothing selected"; return false }
        let bounds = chosen.dropFirst().reduce(chosen[0].worldBounds) { $0.union($1.worldBounds) }
        let centre = chosen.contains { if case .shape(.ringSector, _) = $0.form { return true }; return false } ? 0
            : SurfaceTidy.centimeters((bounds.minX + bounds.maxX) / 2)
        return instrument.applySurfaceEdits([.mirrorSurfaces(ids: chosen.map(\.id), aboutXCm: centre)], undoName: "Mirror surfaces")
    }

    @discardableResult
    public func rotateSelection(degrees: Double) -> Bool {
        let chosen = selectedSurfaces
        guard !chosen.isEmpty else { hint = "Nothing selected"; return false }
        let bounds = chosen.dropFirst().reduce(chosen[0].worldBounds) { $0.union($1.worldBounds) }
        return instrument.applySurfaceEdits([.rotateSurfaces(ids: chosen.map(\.id), degrees: degrees,
            aroundXCm: SurfaceTidy.centimeters((bounds.minX + bounds.maxX) / 2), aroundYCm: SurfaceTidy.centimeters((bounds.minY + bounds.maxY) / 2))],
            undoName: "Rotate surfaces")
    }

    // MARK: Nudging (a held key is one undo step)

    @discardableResult
    public func nudge(dxCm: Double, dyCm: Double, keyCode: UInt16) -> Bool {
        let chosen = selectedSurfaces
        guard !chosen.isEmpty else { return false }
        if let reason = SurfaceGesture.moveRefusal(chosen) { hint = reason; return true }
        if nudgeKeyCode == nil {
            guard instrument.authorize(.edit) else { return true }
            instrument.beginSurfaceEditSeries()
        }
        nudgeKeyCode = keyCode
        _ = instrument.applySurfaceEdit(.moveSurfaces(ids: chosen.map(\.id), dxCm: dxCm, dyCm: dyCm))
        return true
    }
    /// Releasing the arrow key (or any loss of focus, tool or document) closes the burst.
    public func endNudge() {
        guard nudgeKeyCode != nil else { return }
        nudgeKeyCode = nil
        instrument.endSurfaceEditSeries()
    }
    public func keyReleased(_ keyCode: UInt16) { if nudgeKeyCode == keyCode { endNudge() } }

    // MARK: Clipboard (within one preset)

    /// What was copied or cut: the surfaces as they were (shape, placement, look, assignments) and the
    /// layer they came from. Nothing in it refers to a surface that may be gone by the time of pasting.
    private struct Clipboard {
        let session: UUID
        let layerID: UUID
        let drafts: [SurfaceDraft]
        /// Sources that were still in the document when copied: the first paste then lands beside them.
        let sourcesRemain: Bool
        var pastes = 0
    }
    private static var clipboard: Clipboard?

    @discardableResult
    public func copySelection() -> Bool { takeToClipboard(sourcesRemain: true) }

    /// Copy and delete as one command: the clipboard is complete before anything is removed, and a
    /// refused copy removes nothing.
    @discardableResult
    public func cutSelection() -> Bool {
        guard takeToClipboard(sourcesRemain: false) else { return false }
        return deleteSelection()
    }

    private func takeToClipboard(sourcesRemain: Bool) -> Bool {
        let chosen = selectedSurfaces
        guard !chosen.isEmpty else { hint = "Nothing selected"; return false }
        let layers = Set(chosen.compactMap { layer(of: $0.id)?.id })
        guard layers.count == 1, let layerID = layers.first else {
            hint = "Surfaces of one layer can be copied together"; return false
        }
        var drafts: [SurfaceDraft] = []
        for surface in chosen {
            guard case .shape(let shape, let transform) = surface.form else {
                hint = "An exact area from an older preset cannot be copied or cut; duplicate it instead"; return false
            }
            drafts.append(SurfaceDraft(presentation: surface.presentation, shape: shape, transform: transform, routings: surface.routings))
        }
        Self.clipboard = Clipboard(session: document.revision.session, layerID: layerID, drafts: drafts, sourcesRemain: sourcesRemain)
        return true
    }

    /// Pastes the copied surfaces as new ones (new identities, new assignment identities) into the layer
    /// they came from, next to where they were. The outputs of a surface belong to the preset it was made in:
    /// into another preset nothing is pasted, and nothing is silently pointed at other outputs.
    @discardableResult
    public func pasteSelection() -> Bool {
        guard var board = Self.clipboard else { hint = "Nothing copied"; return false }
        guard board.session == document.revision.session else {
            hint = "Surfaces keep the outputs of their own preset; they can only be pasted there"; return false
        }
        guard let layer = document.spatial.layers.first(where: { $0.id == board.layerID }) else {
            hint = "The layer of the copied surfaces no longer exists"; return false
        }
        let step = Double(board.pastes + (board.sourcesRemain ? 1 : 0)) * 10
        var edits: [SurfaceEdit] = []
        var ids: [UUID] = []
        for draft in board.drafts {
            var copy = draft
            copy.id = UUID()
            copy.presentation.name = draft.presentation.name + " copy"
            copy.transform.xCm += step
            copy.routings = draft.routings.map { SpatialRouting(id: UUID(), target: $0.target, program: $0.program, chordRootMIDINote: $0.chordRootMIDINote) }
            if case .ringSector = copy.shape { copy.transform = draft.transform }
            edits.append(.addSurface(layerID: layer.id, copy))
            ids.append(copy.id)
        }
        guard commit(edits, "Paste surfaces") else { return false }
        board.pastes += 1
        Self.clipboard = board
        _ = select(Set(ids))
        return true
    }
    public static func resetClipboard() { clipboard = nil }

    // MARK: Cursor

    public func cursor(at screen: CGPoint, geometry: MetricCanvasGeometry) -> SurfaceCursorKind {
        guard mode == .surfaces else { return .arrow }
        if let gesture {
            switch gesture.kind {
            case .draw: return .crosshair
            case .move: return .move
            case .rotate: return .rotate
            case .marquee: return .crosshair
            case .handle(let handle): return Self.cursor(for: handle)
            }
        }
        if tool.drawsNewSurfaces { return .crosshair }
        let space = SurfaceCanvasSpace(geometry)
        let layout = SurfaceHandleLayout.make(surfaces: selectedSurfaces, axisRoutingID: axisRoutingID, space: space, lockedReason: lockedReason)
        if let handle = layout.handle(at: screen) { return handle.isEnabled ? Self.cursor(for: handle.kind) : .forbidden }
        if let world = space.world(screen), let pick = SurfacePicker.pick(at: world, in: document.spatial) {
            return selectedSurfaceIDs.contains(pick.surfaceID) ? .move : .arrow
        }
        return .arrow
    }
    static func cursor(for handle: SurfaceHandleKind) -> SurfaceCursorKind {
        switch handle {
        case .rotate: return .rotate
        case .rectEdge(let sx, _): return sx != 0 ? .resizeHorizontal : .resizeVertical
        case .sectorStart, .sectorEnd: return .resizeHorizontal
        case .sectorInner, .sectorOuter: return .resizeVertical
        case .rectCorner, .frameCorner, .circleRadius, .sectorInnerStart, .sectorInnerEnd, .sectorOuterStart, .sectorOuterEnd: return .resizeDiagonal
        case .polygonPoint, .axisTip: return .move
        }
    }
}
