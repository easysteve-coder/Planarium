import Foundation
import PlanariumDomain
import CoreGraphics
import SickPLSControlCore
import SickPLSCore

/// Die Werkzeuge der Instrumentfläche. Die Geste adressiert ausschließlich
/// Ringsektoren; `selectedPolarCell` ist die aktive Inspector-Adresse. Auswahl und
/// Wirkung sind absichtlich unabhängig von SwiftUI, damit ein Drag genau eine
/// festgelegte Bedeutung behält.
public enum MetricCanvasTool: String, CaseIterable, Equatable, Sendable {
    case select
    case paint
    case erase
    case pan
    case audition

    public var label: String {
        switch self {
        case .audition: return "Audition (P)"
        case .select: return "Select (V)"
        case .paint: return "Paint (B)"
        case .erase: return "Erase (E)"
        case .pan: return "Hand (H)"
        }
    }

    public var helpLine: String {
        switch self {
        case .audition: return "P Audition · press and drag to play · release to leave · Esc ends the hand"
        case .select: return "V Select · ⇧ extends range · ⌘ toggles · drag a rectangle or move selected cells · ⌥ move copies · double-click selects island · ⇧ adds / ⌘ toggles island · handles resize · ⌫ deletes · arrows 1 / ⇧ 10 steps · Space: Hand"
        case .paint: return "B Paint · click or drag paints in the active layer · one undo per stroke · Space: Hand"
        case .erase: return "E Erase · click or drag deletes cells and own values in the active layer · one undo per stroke · Space: Hand"
        case .pan: return "H Hand · drag pans · trackpad pinch zooms at the pointer · V returns to selection"
        }
    }
}

/// Modifierzustand der Messfeldauswahl. AppKit bleibt an der View-Grenze.
public struct SelectionModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = SelectionModifiers(rawValue: 1 << 0)
    public static let shift = SelectionModifiers(rawValue: 1 << 1)
    public static let option = SelectionModifiers(rawValue: 1 << 2)
}

public enum MetricCanvasKey: Equatable, Sendable {
    case commandA
    case escape
    case delete
    case left, right, up, down
    case selectTool, paintTool, eraseTool, handTool, auditionTool
    case commandC, commandX, commandV, commandD
}

public enum MetricCanvasKeyCommand: Equatable, Sendable {
    case eraseSelection
}

/// Gemeinsamer Befehlspfad für Tastatur, Menü und Kontextmenü. Die
/// Ausführungsnaht nimmt flüchtigen View-Kontext als Parameter statt ihn im
/// Kit-Zustand zu speichern.
public enum MetricCanvasCommand: Equatable, Sendable {
    case delete
    case selectAll
    case zoomIn
    case zoomOut
    case resetView
    case zoomToMeasurement
}

/// A canvas address always includes its owning layer; this is view state.
public struct CanvasCellSelection: Hashable, Sendable {
    public let layerID: UUID
    public let cell: PolarMetricGridCell
    public init(layerID: UUID, cell: PolarMetricGridCell) { self.layerID = layerID; self.cell = cell }
}

public struct CanvasCellCopy: Codable, Equatable, Sendable {
    public let layerID: UUID
    public let cell: PolarMetricGridCell
    public let actions: [SpatialCellAction]?
    public init(layerID: UUID, cell: PolarMetricGridCell, actions: [SpatialCellAction]?) {
        self.layerID = layerID; self.cell = cell; self.actions = actions
    }
}

/// Handles use polar coordinates, just like the shared document transform.
public enum CanvasSelectionHandle: CaseIterable, Equatable, Sendable {
    case inner, outer, start, end, innerStart, innerEnd, outerStart, outerEnd
    var changesInner: Bool { [.inner, .innerStart, .innerEnd].contains(self) }
    var changesOuter: Bool { [.outer, .outerStart, .outerEnd].contains(self) }
    var changesStart: Bool { [.start, .innerStart, .outerStart].contains(self) }
    var changesEnd: Bool { [.end, .innerEnd, .outerEnd].contains(self) }

    public func point(in bounds: PolarMetricCellSegment) -> MetricScanPoint {
        let radius = changesInner ? bounds.innerRadiusMeters : changesOuter ? bounds.outerRadiusMeters : bounds.midpoint.radiusMeters
        let angle = changesStart ? bounds.startBearingDegrees : changesEnd ? bounds.endBearingDegrees : bounds.midpoint.bearingDegrees
        return bounds.point(radiusMeters: radius, bearingDegrees: angle)
    }
}

/// Vollständig reiner Bedienzustand für Rasterfläche, Viewport und die eine
/// aktive Ziehgeste. Er kennt weder Scanner noch Audio, MIDI oder SwiftUI.
public struct MetricCanvasInteractionState: Equatable, Sendable {
    private static let selectionClickThreshold: CGFloat = SecondaryPointerGesture.clickThreshold
    private static let selectionSampleSpacing: CGFloat = 2

    private typealias ActiveDrag = CanvasGestureController.Drag

    public internal(set) var viewState = CanvasViewState()
    public internal(set) var gesture = CanvasGestureController()
    public internal(set) var selection = CanvasSelection()
    public internal(set) var feedback = CanvasFeedback()
    public private(set) var command: CanvasDocumentCommand?
    public internal(set) var workspace: SpatialInstrumentWorkspace
    public let selectionMaximumRadiusMeters: Double
    private var transactionName: String?
    public var clickSelectsArea: Bool { get { viewState.clickSelectsArea } set { viewState.clickSelectsArea = newValue } }
    public var selectionHelpLine: String {
        guard tool == .select else { return tool.helpLine }
        let help = clickSelectsArea ? tool.helpLine.replacingOccurrences(of: "⇧ extends range", with: "⇧ adds island")
            .replacingOccurrences(of: "double-click selects island", with: "click selects island · double-click selects cell") : tool.helpLine
        return help + " · Click selects: Cell | Area"
    }
    public var mergeZones: Bool { get { viewState.mergeZones } set { viewState.mergeZones = newValue } }
    public var showRawScan: Bool { get { viewState.showRawScan } set { viewState.showRawScan = newValue } }
    public internal(set) var isPerformanceLocked = false
    public mutating func setPerformanceLocked(_ locked: Bool) {
        guard locked != isPerformanceLocked else { return }
        resetGesture(); endCoalescing(); isPerformanceLocked = locked
    }
    public internal(set) var viewport: MetricCanvasViewport { get { viewState.viewport } set { viewState.viewport = newValue } }
    public internal(set) var keepsScannerAtBottom: Bool { get { viewState.anchored } set { viewState.anchored = newValue } }
    public internal(set) var tool: MetricCanvasTool { get { viewState.tool } set { viewState.tool = newValue } }
    public internal(set) var isHorizontallyMirrored: Bool { get { viewState.mirrored } set { viewState.mirrored = newValue } }
    public internal(set) var selectedCells: Set<CanvasCellSelection> { get { selection.cells } set { selection.cells = newValue; selection.layerIDs = []; selection.surfaceIDs = []; selection.routingID = nil } }
    public var selectedPolarCells: Set<PolarMetricGridCell> { Set(selectedCells.map(\.cell)) }
    public internal(set) var statusMessage: String? { get { feedback.status } set { feedback.status = newValue } }
    public internal(set) var clipboard: [CanvasCellCopy] { get { feedback.clipboard } set { feedback.clipboard = newValue } }
    public internal(set) var isHandHeld: Bool { get { viewState.handHeld } set { viewState.handHeld = newValue } }
    public var effectiveTool: MetricCanvasTool { isHandHeld ? .pan : tool }
    public internal(set) var contextPaintCell: PolarMetricGridCell? { get { feedback.contextCell } set { feedback.contextCell = newValue } }
    public internal(set) var movePreviewCells: Set<PolarMetricGridCell> { get { gesture.preview } set { gesture.preview = newValue } }
    public internal(set) var moveHitBoundary: Bool { get { feedback.hitBoundary } set { feedback.hitBoundary = newValue } }
    public internal(set) var selectionRectangle: CGRect? { get { gesture.rectangle } set { gesture.rectangle = newValue } }
    private var activeDrag: ActiveDrag? { get { gesture.drag } set { gesture.drag = newValue } }
    private var activeDragCanvasSize: CGSize? { get { gesture.canvasSize } set { gesture.canvasSize = newValue } }
    private var activeDragGeometry: MetricCanvasGeometry? { get { gesture.geometry } set { gesture.geometry = newValue } }
    private var selectionBeforeDrag: Set<CanvasCellSelection>? { get { gesture.selectionBefore } set { gesture.selectionBefore = newValue } }
    private var selectionAnchor: PolarMetricGridCell? { get { selection.anchor } set { selection.anchor = newValue } }
    private var dragViewportWasAnchored: Bool { get { gesture.wasAnchored } set { gesture.wasAnchored = newValue } }

    /// Kompatible Inspector-Adresse: Die Fläche arbeitet mit der Menge,
    /// der Inspector zeigt deren deterministisch erste Zelle.
    public var selectedPolarCell: PolarMetricGridCell? {
        selectedCells.filter { $0.layerID == workspace.selectedLayerID }.map(\.cell).sorted {
            ($0.ring, $0.angularIndex) < ($1.ring, $1.angularIndex)
        }.first
    }

    public init(
        viewport: MetricCanvasViewport = .instrumentDefault,
        tool: MetricCanvasTool = .select,
        isHorizontallyMirrored: Bool = false,
        selectionMaximumRadiusMeters: Double = 2
    ) {
        self.selectionMaximumRadiusMeters = selectionMaximumRadiusMeters.isFinite ? min(50, max(2, selectionMaximumRadiusMeters)) : 2
        self.workspace = SpatialInstrumentWorkspace()
        self.viewport = viewport
        self.tool = tool
        self.isHorizontallyMirrored = isHorizontallyMirrored
        self.selectedCells = []
        self.selectionRectangle = nil
        self.activeDragCanvasSize = nil
        self.selectionBeforeDrag = nil
        self.selectionAnchor = nil
        self.transactionName = nil
    }

    /// Only inputs that the inspector actually presents. Viewport, raw scan
    /// and merged-zone styling never invalidate its independent subtree.
    public func hasSameInspectorPresentation(as other: Self) -> Bool {
        workspace == other.workspace && tool == other.tool && selectedCells == other.selectedCells && selection.layerIDs == other.selection.layerIDs &&
            isPerformanceLocked == other.isPerformanceLocked
    }

    public var isDragging: Bool { activeDrag != nil }
    public var draggedSelectionHandle: CanvasSelectionHandle? {
        if case let .resize(_, _, handle) = activeDrag { return handle }
        return nil
    }
    public var isMovingSelection: Bool {
        if case .move = activeDrag { return true }
        return false
    }
    public var lastEditID: UUID? { command?.id }
    public var undoActionName: String? { command?.name }
    public mutating func finishEditing() { endCoalescing() }
    public mutating func discardGesture() { resetGesture() }
    mutating func clearPendingCommand() { command = nil }
    public mutating func noteHistoryCommand(_ changed: Bool, redo: Bool) {
        statusMessage = changed ? nil : isPerformanceLocked ? "Editing is locked in Perform mode"
            : redo ? "Nothing to redo" : "Nothing to undo"
    }

    /// Groups the complete Popover action into one document edit. The closure
    /// receives the same state used by the normal editor paths, so its final
    /// workspace is installed through the ordinary runtime publication path.
    @discardableResult
    public mutating func performEdit(
        named name: String,
        _ change: (inout MetricCanvasInteractionState) -> Bool
    ) -> Bool {
        guard !isPerformanceLocked else { return false }
        if transactionName != nil {
            return change(&self)
        }
        let before = workspace
        transactionName = name
        let selection = selectedCells
        let accepted = change(&self)
        transactionName = nil
        guard accepted else {
            workspace = before
            selectedCells = selection
            return false
        }
        recordCommand(before: before, name: name)
        return true
    }

    public mutating func updateWorkspace(_ change: (inout SpatialInstrumentWorkspace) -> Void) {
        updateWorkspace(named: "Edit document", coalescingKey: nil, change)
    }

    public mutating func updateWorkspace(
        named name: String,
        coalescingKey: String? = nil,
        _ change: (inout SpatialInstrumentWorkspace) -> Void
    ) {
        guard !isPerformanceLocked else { return }
        let before = workspace
        resetGesture()
        change(&workspace)
        let selectedLayerIDs = selection.layerIDs
        selectedCells = selectableCells(selectedCells)
        selection.layerIDs = selectedLayerIDs.intersection(workspace.layers.map(\.id))
        if isOnlyLayerSelectionChange(from: before, to: workspace) {
            recordCoalescingBoundary()
            return
        }
        recordCommand(before: before, name: name, coalescingKey: coalescingKey)
    }

    /// Gemeinsamer Dokumentweg für das Ebenen-Kontextmenü. Die Sperre wird
    /// hier erzwingbar geprüft, nicht nur durch SwiftUI-Menüzustände.
    @discardableResult
    public mutating func renameSelectedLayer(_ name: String) -> Bool {
        guard !workspace.selectedLayer.isLocked else { return false }
        let before = workspace
        updateWorkspace(named: "Rename layer", coalescingKey: "layer:\(workspace.selectedLayerID):name") {
            $0.updateSelectedLayer { $0.name = name }
        }
        return before != workspace
    }

    @discardableResult
    public mutating func setSelectedLayerColor(_ color: SpatialLayerColor) -> Bool {
        guard !workspace.selectedLayer.isLocked else { return false }
        let before = workspace
        updateWorkspace(named: "Change color", coalescingKey: "layer:\(workspace.selectedLayerID):color") {
            $0.updateSelectedLayer { $0.color = color }
        }
        return before != workspace
    }

    @discardableResult
    public mutating func setSelectedLayerTarget(
        _ target: SpatialRoutingTarget,
        program: SpatialValueProgram = .constant(0)
    ) -> Bool {
        guard !workspace.selectedLayer.isLocked else { return false }
        let before = workspace
        updateWorkspace(named: "Change output") { workspace in
            workspace.updateSelectedLayer { layer in
                if let index = layer.routings.indices.first {
                    let previous = layer.routings[index].target
                    let sameControlKind: Bool
                    switch (previous, target) {
                    case (.sceneSwitch, .sceneSwitch), (.releaseLayer, .releaseLayer): sameControlKind = true
                    default: sameControlKind = false
                    }
                    if sameControlKind {
                        for cell in layer.polarCellOverrides.keys {
                            layer.polarCellOverrides[cell] = layer.polarCellOverrides[cell]?.map { action in
                                action.target == previous ? .init(target: target, value: action.value) : action
                            }
                        }
                    }
                    layer.routings[index].target = target
                    layer.routings[index].program = program
                } else {
                    layer.routings = [.init(target: target, program: program)]
                }
            }
        }
        return before != workspace
    }

    @discardableResult
    public mutating func clearSelectedLayerTarget() -> Bool {
        guard !workspace.selectedLayer.isLocked else { return false }
        let before = workspace
        updateWorkspace(named: "Remove output") { $0.updateSelectedLayer { $0.routings.removeAll() } }
        return before != workspace
    }

    @discardableResult
    public mutating func setSelectedLayerMIDIChannel(_ channel: UInt8) -> Bool {
        guard !workspace.selectedLayer.isLocked else { return false }
        let before = workspace
        updateWorkspace(named: "Change MIDI channel") { $0.updateSelectedLayer { $0.setMIDIChannel(channel) } }
        return before != workspace
    }

    /// Derived document projection. Preserve selection/gesture/view state;
    /// the Main document owner, rather than this facade, owns app history.
    public mutating func projectWorkspace(_ workspace: SpatialInstrumentWorkspace) {
        self.workspace = workspace
        selectedCells = selectableCells(selectedCells)
    }

    public mutating func replaceWorkspace(_ workspace: SpatialInstrumentWorkspace) {
        guard !isPerformanceLocked else { return }
        let before = self.workspace
        resetGesture()
        self.workspace = workspace
        selectedCells = []
        recordCommand(before: before, name: "Replace workspace")
    }

    @discardableResult
    public mutating func requestGridChange(to size: MetricSquareGrid.CellSize) -> SpatialInstrumentWorkspace.GridChange {
        guard !isPerformanceLocked else { return .unchanged }
        let before = workspace
        resetGesture()
        let result = workspace.requestGridChange(to: size)
        if case .changed = result { selectedCells.removeAll() }
        recordCommand(before: before, name: "Change grid")
        return result
    }

    @discardableResult
    public mutating func confirmGridChange(to size: MetricSquareGrid.CellSize) -> SpatialInstrumentWorkspace.GridChange {
        guard !isPerformanceLocked else { return .unchanged }
        let before = workspace
        resetGesture()
        let result = workspace.confirmGridChange(to: size)
        if case .changed = result { selectedCells.removeAll() }
        recordCommand(before: before, name: "Change grid")
        return result
    }

    public mutating func select(tool: MetricCanvasTool) {
        guard !isPerformanceLocked else { return }
        guard self.tool != tool else { return }
        resetGesture()
        self.tool = tool
    }


    /// The fit button uses the ordinary canvas document publication and one
    /// history entry. Contour and margin remain session inputs only.
    @discardableResult
    public mutating func fitToRoom(_ contour: SpatialRoomContour, marginCentimeters: Double = 10) -> Double? {
        guard !isPerformanceLocked, activeDrag == nil else { return nil }
        let result = SpatialRoomFit.applying(to: workspace, contour: contour, marginCentimeters: marginCentimeters)
        guard result.transform.workspace != workspace else { return result.factor }
        let before = workspace
        workspace = result.transform.workspace
        selectedCells = []
        movePreviewCells = []
        moveHitBoundary = false
        recordCommand(before: before, name: "Fit to room")
        return result.factor
    }

    public mutating func toggleHorizontalMirror() {
        resetGesture()
        isHorizontallyMirrored.toggle()
    }

    public var selectionBounds: PolarMetricCellSegment? {
        PolarCellTransform.bounds(cells: selectedPolarCells, grid: workspace.grid)
    }

    private var selectionByLayer: [UUID: Set<PolarMetricGridCell>] {
        selectedCells.reduce(into: [:]) { $0[$1.layerID, default: []].insert($1.cell) }
    }

    private func geometry(_ size: CGSize) -> MetricCanvasGeometry {
        if activeDrag != nil, let activeDragGeometry { return activeDragGeometry }
        return .init(size: size, viewport: viewport, isHorizontallyMirrored: isHorizontallyMirrored)
    }

    public mutating func holdHand(_ held: Bool) { isHandHeld = held }

    @discardableResult public mutating func beginViewportDrag(at point: CGPoint, canvasSize: CGSize) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        selectionBeforeDrag = selectedCells
        dragViewportWasAnchored = keepsScannerAtBottom
        activeDragCanvasSize = canvasSize
        activeDragGeometry = .init(size: canvasSize, viewport: viewport, isHorizontallyMirrored: isHorizontallyMirrored)
        gesture.armed = true
        activeDrag = .pan(startPoint: point, startViewport: viewport)
        return true
    }

    public func displayGeometry(canvasSize: CGSize) -> MetricCanvasGeometry {
        guard activeDrag != nil, let frozen = activeDragGeometry else {
            return .init(size: canvasSize, viewport: viewport, isHorizontallyMirrored: isHorizontallyMirrored)
        }
        return .init(size: frozen.canvasRect.size, viewport: isPanningViewport ? viewport : frozen.viewport,
                     isHorizontallyMirrored: frozen.isHorizontallyMirrored)
    }
    private var isPanningViewport: Bool {
        if case .pan = activeDrag { return true }
        return false
    }

    /// Selects whole surfaces (and the assignment whose axis is shown). The surface is the user's unit:
    /// cells and whole layers are no longer selected, so no cell path can act on the choice by accident.
    @discardableResult
    public mutating func selectSurfaces(_ ids: Set<UUID>, routingID: UUID?, inLayer layerID: UUID?) -> Bool {
        guard !isPerformanceLocked else { return report("Editing is locked in Perform mode") }
        if let layerID, workspace.layers.contains(where: { $0.id == layerID }) { workspace.selectLayer(layerID) }
        selectedCells = []
        selection.surfaceIDs = ids
        selection.routingID = ids.isEmpty ? nil : routingID
        selection.anchor = nil
        recordCoalescingBoundary()
        statusMessage = nil
        return true
    }

    @discardableResult
    public mutating func selectLayers(_ ids: Set<UUID>, active id: UUID? = nil) -> Bool {
        guard !isPerformanceLocked else { return report("Editing is locked in Perform mode") }
        if let id { workspace.selectLayer(id) }
        selectedCells = Set(workspace.layers.filter { ids.contains($0.id) && $0.isVisible && !$0.isLocked }
            .flatMap { layer in layer.polarCells.filter(isInsideField).map { CanvasCellSelection(layerID: layer.id, cell: $0) } })
        selection.layerIDs = ids.intersection(workspace.layers.map(\.id))
        selection.surfaceIDs = []; selection.routingID = nil
        recordCoalescingBoundary()
        if selectedCells.isEmpty && selection.layerIDs.isEmpty {
            if let layer = workspace.layers.first(where: { ids.contains($0.id) && (!($0.isVisible) || $0.isLocked) }) {
                return report(layer.isLocked ? "Layer ‘\(layer.name)’ is locked" : "Layer ‘\(layer.name)’ is hidden")
            }
            return report("No painted cells in these layers")
        }
        statusMessage = nil
        return true
    }

    @discardableResult
    public mutating func beginDrag(at point: CGPoint, canvasSize: CGSize,
                                   modifiers: SelectionModifiers = [], brush: Bool = false) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        selectionBeforeDrag = selectedCells
        dragViewportWasAnchored = keepsScannerAtBottom
        activeDragCanvasSize = canvasSize
        activeDragGeometry = .init(size: canvasSize, viewport: viewport, isHorizontallyMirrored: isHorizontallyMirrored)
        gesture.armed = true
        moveHitBoundary = false
        statusMessage = nil
        if isPerformanceLocked || effectiveTool == .pan {
            activeDrag = .pan(startPoint: point, startViewport: viewport)
            return true
        }
        switch effectiveTool {
        case .audition: resetGesture(); return false
        case .pan: break
        case .paint, .erase:
            guard activeLayerIsEditable() else { resetGesture(); return false }
            let cell = rawCell(atScreenPoint: point, geometry: geometry(canvasSize))
            guard let cell, isInsideField(cell) else { resetGesture(); return report("Outside the editable field") }
            activeDrag = .draw(currentPoint: point, cells: [cell], erase: effectiveTool == .erase)
            movePreviewCells = [cell]
        case .select:
            // The reference-field editor explicitly supports area selection.
            // Instrument cells, in contrast, can never select empty addresses.
            let referenceBrush = selectionMaximumRadiusMeters > 2 && brush
            if !referenceBrush, modifiers.isEmpty, let handle = selectionHandle(at: point, canvasSize: canvasSize) {
                activeDrag = .resize(startPoint: point, currentPoint: point, handle: handle)
                movePreviewCells = selectedPolarCells
            } else if !referenceBrush, !modifiers.contains(.command), !modifiers.contains(.shift),
                      let hit = hit(at: point, canvasSize: canvasSize), selectedCells.contains(hit) {
                activeDrag = .move(startPoint: point, currentPoint: point, copy: modifiers.contains(.option))
                movePreviewCells = selectedPolarCells
            } else if !referenceBrush, modifiers.isEmpty, hit(at: point, canvasSize: canvasSize) == nil,
                      geometry(canvasSize).canvasRect.contains(point),
                      let bounds = selectionBounds,
                      let p = PolarProjection(geometry: geometry(canvasSize), maximumRadius: selectionMaximumRadiusMeters).point(at: point),
                      !p.isClamped,
                      (bounds.innerRadiusMeters...bounds.outerRadiusMeters).contains(p.radius),
                      (bounds.startBearingDegrees...bounds.endBearingDegrees).contains(p.bearing) {
                activeDrag = .move(startPoint: point, currentPoint: point, copy: false)
                movePreviewCells = selectedPolarCells
            } else {
                let initial = rawCell(atScreenPoint: point, geometry: geometry(canvasSize))
                activeDrag = .select(startPoint: point, currentPoint: point, modifiers: modifiers,
                    brush: referenceBrush, brushCells: initial.map { [$0] } ?? [])
                if !referenceBrush { selectionRectangle = CGRect(origin: point, size: .zero) }
            }
        }
        if case .select = activeDrag {
            return rawCell(atScreenPoint: point, geometry: geometry(canvasSize)) != nil || geometry(canvasSize).canvasRect.contains(point)
        }
        return true
    }

    @discardableResult
    public mutating func updateDrag(to point: CGPoint, canvasSize: CGSize) -> Bool {
        guard point.x.isFinite, point.y.isFinite, let drag = activeDrag else { return false }
        let canvasSize = activeDragCanvasSize ?? canvasSize
        gesture.armed = false
        switch drag {
        case let .pan(start, frozen):
            guard point != start || viewport != frozen else { return true }
            guard let panned = MetricCanvasGeometry(size: canvasSize, viewport: frozen, isHorizontallyMirrored: isHorizontallyMirrored)
                .panned(byScreenX: Double(point.x - start.x), screenY: Double(point.y - start.y)) else { return false }
            viewport = panned; keepsScannerAtBottom = false
        case let .move(start, _, copy):
            activeDrag = .move(startPoint: start, currentPoint: point, copy: copy)
            let result = moveResult(from: start, to: point, canvasSize: canvasSize)
            movePreviewCells = result.cells; moveHitBoundary = result.didHitBoundary
        case let .resize(start, _, handle):
            activeDrag = .resize(startPoint: start, currentPoint: point, handle: handle)
            let result = resizeResult(from: start, to: point, handle: handle, canvasSize: canvasSize)
            movePreviewCells = result.cells; moveHitBoundary = result.didHitBoundary
        case let .draw(previous, cells, erase):
            let sampled = cells.union(sampledCells(from: previous, to: point, canvasSize: canvasSize))
            activeDrag = .draw(currentPoint: point, cells: sampled, erase: erase)
            movePreviewCells = sampled
        case let .select(start, previous, modifiers, brush, cells):
            activeDrag = .select(startPoint: start, currentPoint: point, modifiers: modifiers, brush: brush,
                brushCells: brush ? cells.union(sampledCells(from: previous, to: point, canvasSize: canvasSize)) : [])
            selectionRectangle = brush ? nil : selectionRect(from: start, to: point)
        }
        return true
    }

    public mutating func endDrag(canvasSize: CGSize) {
        guard let drag = activeDrag else { resetGesture(); return }
        let canvasSize = activeDragCanvasSize ?? canvasSize
        switch drag {
        case .pan: break
        case let .move(start, current, copy):
            if hypot(current.x - start.x, current.y - start.y) < Self.selectionClickThreshold {
                if hit(at: start, canvasSize: canvasSize) != nil {
                    applyClick(at: start, canvasSize: canvasSize, modifiers: [])
                }
            } else { commitTransform(moveResult(from: start, to: current, canvasSize: canvasSize), copy: copy) }
        case let .resize(start, current, handle):
            if hypot(current.x - start.x, current.y - start.y) >= Self.selectionClickThreshold {
                commitTransform(resizeResult(from: start, to: current, handle: handle, canvasSize: canvasSize), named: "Resize cells")
            }
        case let .draw(_, cells, erase):
            let pairs = Set(cells.map { CanvasCellSelection(layerID: workspace.selectedLayerID, cell: $0) })
            _ = apply(erase ? .erase : .paint, to: pairs)
        case let .select(start, current, modifiers, brush, cells):
            if hypot(current.x - start.x, current.y - start.y) < Self.selectionClickThreshold {
                applyClick(at: start, canvasSize: canvasSize, modifiers: modifiers)
            } else {
                applyGestureSelection(brush ? pairs(for: cells) : self.cells(in: selectionRect(from: start, to: current), canvasSize: canvasSize),
                                      modifiers: modifiers)
            }
        }
        resetGesture()
    }

    private mutating func resetGesture() {
        activeDrag = nil; selectionRectangle = nil; activeDragCanvasSize = nil
        activeDragGeometry = nil
        selectionBeforeDrag = nil; movePreviewCells = []
        gesture.armed = false
        if let size = viewState.deferredSize { viewState.deferredSize = nil; _ = followCanvasSize(size) }
    }

    private func selectionRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        .init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func sampledCells(from a: CGPoint, to b: CGPoint, canvasSize: CGSize) -> Set<PolarMetricGridCell> {
        let count = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / Self.selectionSampleSpacing)))
        let geometry = geometry(canvasSize)
        return Set((0...count).compactMap { index in
            let f = CGFloat(index) / CGFloat(count)
            let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            guard let cell = rawCell(atScreenPoint: p, geometry: geometry), isInsideField(cell) else { return nil }
            return cell
        })
    }

    private func rawCell(atScreenPoint point: CGPoint, geometry: MetricCanvasGeometry) -> PolarMetricGridCell? {
        PolarProjection(geometry: geometry, maximumRadius: selectionMaximumRadiusMeters).cell(at: point, grid: workspace.grid)
    }

    private func isInsideField(_ cell: PolarMetricGridCell) -> Bool {
        guard (try? LegacyLatticeMigration.isInsideScannerField(cell, in: workspace.grid)) == true else { return false }
        let area = PolarMetricCellSegment(cell: cell, grid: workspace.grid)
        return area.innerRadiusMeters >= 0 && area.innerRadiusMeters <= selectionMaximumRadiusMeters
            && area.outerRadiusMeters > 0 && area.startBearingDegrees <= 90 && area.endBearingDegrees > -90
    }

    private func selectableCells(_ cells: Set<CanvasCellSelection>) -> Set<CanvasCellSelection> {
        guard !cells.isEmpty else { return cells }
        let layers = Dictionary(uniqueKeysWithValues: workspace.layers.map { ($0.id, $0) })
        return cells.filter { pair in
            guard let layer = layers[pair.layerID], isInsideField(pair.cell) else { return false }
            return selectionMaximumRadiusMeters > 2 || (layer.isVisible && !layer.isLocked && layer.polarCells.contains(pair.cell))
        }
    }

    private func isSelectable(_ pair: CanvasCellSelection) -> Bool {
        guard isInsideField(pair.cell), let layer = workspace.layers.first(where: { $0.id == pair.layerID }) else { return false }
        if selectionMaximumRadiusMeters > 2 { return true }
        return layer.isVisible && !layer.isLocked && layer.polarCells.contains(pair.cell)
    }

    private func pairs(for cells: Set<PolarMetricGridCell>) -> Set<CanvasCellSelection> {
        if selectionMaximumRadiusMeters > 2 {
            return Set(cells.filter(isInsideField).map { .init(layerID: workspace.selectedLayerID, cell: $0) })
        }
        return Set(workspace.layers.filter { $0.isVisible && !$0.isLocked }.flatMap { layer in
            layer.polarCells.intersection(cells).filter(isInsideField).map { CanvasCellSelection(layerID: layer.id, cell: $0) }
        })
    }

    private func hit(at point: CGPoint, canvasSize: CGSize) -> CanvasCellSelection? {
        guard let cell = rawCell(atScreenPoint: point, geometry: geometry(canvasSize)), isInsideField(cell) else { return nil }
        if selectionMaximumRadiusMeters > 2 { return .init(layerID: workspace.selectedLayerID, cell: cell) }
return workspace.layers.reversed().first { $0.isVisible && !$0.isLocked && $0.polarCells.contains(cell) }
            .map { .init(layerID: $0.id, cell: cell) }
    }

    private func cells(in rect: CGRect, canvasSize: CGSize) -> Set<CanvasCellSelection> {
        let geometry = geometry(canvasSize)
        if selectionMaximumRadiusMeters > 2 {
            let xs = selectionSamples(from: rect.minX, to: rect.maxX), ys = selectionSamples(from: rect.minY, to: rect.maxY)
            return pairs(for: Set(xs.flatMap { x in ys.compactMap { y in
                rawCell(atScreenPoint: .init(x: x, y: y), geometry: geometry)
            }}))
        }
        // Iterate painted addresses, not the potentially huge empty raster.
        return Set(workspace.layers.filter { $0.isVisible && !$0.isLocked }.flatMap { layer in
            layer.polarCells.filter { cell in
                guard isInsideField(cell) else { return false }
                let s = PolarMetricCellSegment(cell: cell, grid: workspace.grid)
                return rect.contains(geometry.screenPoint(for: s.point(radiusMeters: s.midpoint.radiusMeters, bearingDegrees: s.midpoint.bearingDegrees)))
            }.map { CanvasCellSelection(layerID: layer.id, cell: $0) }
        })
    }

    private func selectionSamples(from lower: CGFloat, to upper: CGFloat) -> [CGFloat] {
        let count = max(1, Int(ceil(max(0, upper - lower) / Self.selectionSampleSpacing)))
        return (0...count).map { lower + (upper - lower) * CGFloat($0) / CGFloat(count) }
    }

    private mutating func applyGestureSelection(_ pairs: Set<CanvasCellSelection>, modifiers: SelectionModifiers) {
        if modifiers.contains(.command) || modifiers.contains(.shift) { selectedCells.formUnion(pairs) }
        else { selectedCells = pairs }
        statusMessage = selectedCells.isEmpty ? "No painted cells selected" : nil
    }

    private mutating func applyClick(at point: CGPoint, canvasSize: CGSize, modifiers: SelectionModifiers) {
        guard geometry(canvasSize).canvasRect.contains(point), let clicked = hit(at: point, canvasSize: canvasSize) else {
            selectedCells = []; selectionAnchor = nil
            explainEmptyHit(at: point, canvasSize: canvasSize)
            return
        }
        if clickSelectsArea {
            _ = selectZone(at: point, canvasSize: canvasSize, modifiers: modifiers)
            return
        }
        workspace.selectLayer(clicked.layerID); recordCoalescingBoundary()
        if modifiers.contains(.shift), let anchor = selectionAnchor {
            let a = PolarMetricCellSegment(cell: anchor, grid: workspace.grid)
            let b = PolarMetricCellSegment(cell: clicked.cell, grid: workspace.grid)
            let geometry = geometry(canvasSize)
            let p = geometry.screenPoint(for: a.point(radiusMeters: a.midpoint.radiusMeters, bearingDegrees: a.midpoint.bearingDegrees))
            let q = geometry.screenPoint(for: b.point(radiusMeters: b.midpoint.radiusMeters, bearingDegrees: b.midpoint.bearingDegrees))
            selectedCells.formUnion(cells(in: selectionRect(from: p, to: q).insetBy(dx: -1, dy: -1), canvasSize: canvasSize))
            selectedCells.insert(clicked)
        } else if modifiers.contains(.command) || (selectionMaximumRadiusMeters > 2 && modifiers == [.option]) {
            if !selectedCells.insert(clicked).inserted { selectedCells.remove(clicked) }
        } else { selectedCells = [clicked] }
        if !modifiers.contains(.shift) { selectionAnchor = clicked.cell }
        statusMessage = nil
    }

    private mutating func explainEmptyHit(at point: CGPoint, canvasSize: CGSize) {
        guard let cell = rawCell(atScreenPoint: point, geometry: geometry(canvasSize)) else {
            statusMessage = geometry(canvasSize).canvasRect.contains(point) ? "Nothing selected" : "Outside the editable field"
            return
        }
        if let layer = workspace.layers.reversed().first(where: { $0.polarCells.contains(cell) && (!$0.isVisible || $0.isLocked) }) {
            statusMessage = layer.isLocked ? "Layer ‘\(layer.name)’ is locked" : "Layer ‘\(layer.name)’ is hidden"
        } else { statusMessage = "Nothing selected" }
    }

    @discardableResult public mutating func selectCell(atScreenPoint point: CGPoint, canvasSize: CGSize,
                                                       modifiers: SelectionModifiers = []) -> Bool {
        guard !isPerformanceLocked, point.x.isFinite, point.y.isFinite else { return false }
        applyClick(at: point, canvasSize: canvasSize, modifiers: modifiers)
        return geometry(canvasSize).canvasRect.contains(point)
    }

    @discardableResult public mutating func toggleCellSelection(atScreenPoint point: CGPoint, canvasSize: CGSize) -> Bool {
        selectCell(atScreenPoint: point, canvasSize: canvasSize, modifiers: .command)
    }

    @discardableResult public mutating func extendSelection(toScreenPoint point: CGPoint, canvasSize: CGSize) -> Bool {
        guard !isPerformanceLocked, let pair = hit(at: point, canvasSize: canvasSize) else { return false }
        selectedCells.insert(pair); statusMessage = nil
        return true
    }

    @discardableResult public mutating func selectZone(at point: CGPoint, canvasSize: CGSize,
        modifiers: SelectionModifiers = [], selectionBeforeClick: Set<CanvasCellSelection>? = nil) -> Bool {
        guard !isPerformanceLocked, point.x.isFinite, point.y.isFinite,
              let pair = hit(at: point, canvasSize: canvasSize) else { return report("Nothing selected") }
        guard let layer = workspace.layers.first(where: { $0.id == pair.layerID }) else { return false }
        let eligible = Set(layer.polarCells.filter(isInsideField))
        let island = Set(SpatialCellContent.island(containing: pair.cell, layer: layer, grid: workspace.grid, within: eligible)
            .map { CanvasCellSelection(layerID: pair.layerID, cell: $0) })
        let previous = selectableCells(selectionBeforeClick ?? selectedCells)
        if modifiers.contains(.command) {
            selectedCells = previous.symmetricDifference(island)
        } else if modifiers.contains(.shift) {
            selectedCells = previous.union(island)
        } else { selectedCells = island }
        workspace.selectLayer(pair.layerID); selectionAnchor = pair.cell
        recordCoalescingBoundary(); statusMessage = nil
        return true
    }

    @discardableResult public mutating func selectDoubleClick(at point: CGPoint, canvasSize: CGSize,
        modifiers: SelectionModifiers = [], selectionBeforeClick: Set<CanvasCellSelection>? = nil) -> Bool {
        // The second press of a quick double click on a frame handle belongs to
        // the resize gesture, never to island selection.
        if modifiers.isEmpty, selectionHandle(at: point, canvasSize: canvasSize) != nil { return false }
        if !clickSelectsArea { return selectZone(at: point, canvasSize: canvasSize, modifiers: modifiers, selectionBeforeClick: selectionBeforeClick) }
        guard !isPerformanceLocked else { return false }
        if let previous = selectionBeforeClick { selectedCells = previous }
        clickSelectsArea = false
        defer { clickSelectsArea = true }
        return selectCell(atScreenPoint: point, canvasSize: canvasSize, modifiers: modifiers)
    }

    public mutating func clearSelection() {
        guard !isPerformanceLocked else { return }
        resetGesture()
        selectedCells = []; statusMessage = nil
    }

    public func isEnabled(_ command: MetricCanvasCommand, canvasSize: CGSize? = nil, profile: B0ScanProfile? = nil) -> Bool {
        switch command {
        case .delete: return !isPerformanceLocked && (activeDrag != nil || !selectedCells.isEmpty)
        case .selectAll: return !isPerformanceLocked && !pairs(for: Set(workspace.layers.flatMap { $0.polarCells })).isEmpty
        case .zoomIn, .zoomOut: return validCanvasSize(canvasSize)
        case .resetView: return viewport != .instrumentDefault
        case .zoomToMeasurement:
            guard let profile, validCanvasSize(canvasSize) else { return false }
            return !MetricScanProjection().project(profile).isEmpty
        }
    }

    @discardableResult public mutating func perform(_ command: MetricCanvasCommand, canvasSize: CGSize? = nil,
                                                    profile: B0ScanProfile? = nil) -> Bool {
        switch command {
        case .delete:
            guard case .success(.applied) = applyToSelection(.erase) else { return false }
            return true
        case .selectAll:
            guard !isPerformanceLocked else { return report("Editing is locked in Perform mode") }
            selectedCells = pairs(for: Set(workspace.layers.flatMap { $0.polarCells }))
            if selectedCells.isEmpty { return report("Nothing selected") }
            statusMessage = nil; return true
        case .zoomIn: return zoomAroundCanvasCenter(byFactor: 1.4, canvasSize: canvasSize)
        case .zoomOut: return zoomAroundCanvasCenter(byFactor: 1 / 1.4, canvasSize: canvasSize)
        case .resetView:
            if let canvasSize, resetViewport(canvasSize: canvasSize) { return true }
            resetViewport(); return true
        case .zoomToMeasurement:
            guard let profile, let canvasSize else { return report("No measurement available") }
            return fitViewport(toMeasurementsOf: profile, canvasSize: canvasSize)
        }
    }

    private func validCanvasSize(_ size: CGSize?) -> Bool {
        guard let size else { return false }
        return size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private mutating func zoomAroundCanvasCenter(byFactor factor: Double, canvasSize: CGSize?) -> Bool {
        guard let size = canvasSize else { return false }
        return zoom(byFactor: factor, atScreenPoint: .init(x: size.width / 2, y: size.height / 2), canvasSize: size)
    }

    @discardableResult public mutating func handleKey(_ key: MetricCanvasKey, modifiers: SelectionModifiers = []) -> MetricCanvasKeyCommand? {
        guard !isPerformanceLocked || key == .escape else { return nil }
        let step = modifiers.contains(.shift) ? 10 : 1
        switch key {
        case .selectTool: select(tool: .select)
        case .paintTool: select(tool: .paint)
        case .eraseTool: select(tool: .erase)
        case .handTool: select(tool: .pan)
        case .auditionTool: select(tool: .audition)
        case .commandA: _ = perform(.selectAll)
        case .commandC: _ = copySelection()
        case .commandX: if copySelection() { _ = applyToSelection(.erase) }
        case .commandV: _ = pasteSelection()
        case .commandD: _ = duplicateSelection()
        case .escape:
            if activeDrag != nil {
                if case let .pan(_, frozen) = activeDrag { viewport = frozen; keepsScannerAtBottom = dragViewportWasAnchored }
                selectedCells = selectionBeforeDrag ?? selectedCells; resetGesture(); statusMessage = "Gesture cancelled"
            }
            else { clearSelection() }
        case .delete: return .eraseSelection
        case .left: moveSelection(radial: 0, angular: -step)
        case .right: moveSelection(radial: 0, angular: step)
        case .up: moveSelection(radial: step, angular: 0)
        case .down: moveSelection(radial: -step, angular: 0)
        }
        return nil
    }

    private func moveSteps(from a: CGPoint, to b: CGPoint, canvasSize: CGSize) -> (Int, Int) {
        let geometry = geometry(canvasSize)
        // Pointer coordinates may extend past the field while dragging.
        guard let p = PolarProjection(geometry: geometry, maximumRadius: selectionMaximumRadiusMeters).point(at: a), let q = PolarProjection(geometry: geometry, maximumRadius: selectionMaximumRadiusMeters).point(at: b) else { return (0, 0) }
        let dr = q.radius - p.radius
        let da = q.bearing - p.bearing
        let widest = selectedPolarCells.map { cell in
            let segment = PolarMetricCellSegment(cell: cell, grid: workspace.grid)
            return segment.endBearingDegrees - segment.startBearingDegrees
        }.max() ?? 1
        return (Int((dr / workspace.grid.cellSizeMeters).rounded()), Int((da / widest).rounded()))
    }

    private func moveResult(from a: CGPoint, to b: CGPoint, canvasSize: CGSize) -> PolarCellMove.Result {
        let steps = moveSteps(from: a, to: b, canvasSize: canvasSize)
        let result = PolarCellMove.applying(radialSteps: steps.0, angularSteps: steps.1, cellsByLayer: selectionByLayer, to: workspace)
        let clipped = PolarProjection(geometry: geometry(canvasSize), maximumRadius: selectionMaximumRadiusMeters).point(at: b)?.isClamped == true
        return .init(workspace: result.workspace, cells: result.cells, didHitBoundary: result.didHitBoundary || clipped, cellsByLayer: result.cellsByLayer)
    }

    private mutating func moveSelection(radial: Int, angular: Int) {
        guard !selectedCells.isEmpty else { _ = report("Nothing selected"); return }
        commitTransform(PolarCellMove.applying(radialSteps: radial, angularSteps: angular, cellsByLayer: selectionByLayer, to: workspace))
    }

    /// Griffgeometrie einer Auswahl, aus genau einer Rahmenberechnung.
    public struct SelectionHandleLayout {
        public let size: CGFloat
        public let hitRadius: CGFloat
        public let centers: [(handle: CanvasSelectionHandle, point: CGPoint)]
        /// Fine raster: tolerance circle plus the whole drawn square (its
        /// corners lie outside the circle); coarse grids: the square only.
        let circular: Bool

        /// Single hit rule for grabbing and for diagnosis images.
        public func hits(_ point: CGPoint, center: CGPoint) -> Bool {
            let dx = abs(center.x - point.x), dy = abs(center.y - point.y)
            if dx <= size / 2, dy <= size / 2 { return true }
            return circular ? hypot(dx, dy) <= hitRadius : dx <= hitRadius && dy <= hitRadius
        }
    }

    /// Frame handles: Existing 10/25/50-cm handles keep their fixed 16-pt
    /// screen contract and sit on the frame point. On the fine raster the size
    /// follows the whole selection on screen (not one 5-pt cell): up to 16 pt,
    /// at most half of the smaller extent. The hit radius adds up to 10 pt of
    /// tolerance (a quarter of the extent), and the handle sits just outside
    /// the frame (90 % of the hit radius), so it never covers the outermost
    /// selected cells – their centres stay movable.
    public func selectionHandleLayout(canvasSize: CGSize) -> SelectionHandleLayout? {
        guard let bounds = selectionBounds else { return nil }
        let geometry = geometry(canvasSize)
        let frame = { (handle: CanvasSelectionHandle) in geometry.screenPoint(for: handle.point(in: bounds)) }
        guard workspace.grid.cellSizeMeters < 0.1 else {
            return .init(size: CanvasGestureController.handleSize, hitRadius: CanvasGestureController.handleSize / 2,
                         centers: CanvasSelectionHandle.allCases.map { ($0, frame($0)) }, circular: false)
        }
        let scale = geometry.viewport.metersPerPoint
        let arc = bounds.midpoint.radiusMeters * (bounds.endBearingDegrees - bounds.startBearingDegrees) * .pi / 180
        let extent = CGFloat(min(bounds.radialHeightMeters, arc) / scale)
        let size = max(2, min(CanvasGestureController.handleSize, extent / 2))
        let hit = max(size / 2, min(10, extent / 4))
        let centers = CanvasSelectionHandle.allCases.map { handle -> (CanvasSelectionHandle, CGPoint) in
            let isCorner = (handle.changesInner || handle.changesOuter) && (handle.changesStart || handle.changesEnd)
            let offset = Double(hit) * 0.9 * scale / (isCorner ? 2.0.squareRoot() : 1)
            var radius = handle.changesInner ? bounds.innerRadiusMeters : handle.changesOuter ? bounds.outerRadiusMeters : bounds.midpoint.radiusMeters
            var bearing = handle.changesStart ? bounds.startBearingDegrees : handle.changesEnd ? bounds.endBearingDegrees : bounds.midpoint.bearingDegrees
            if handle.changesInner { radius = max(0, radius - offset) } else if handle.changesOuter { radius += offset }
            let angular = offset / max(radius, 0.05) * 180 / .pi
            if handle.changesStart { bearing -= angular } else if handle.changesEnd { bearing += angular }
            return (handle, geometry.screenPoint(for: bounds.point(radiusMeters: radius, bearingDegrees: bearing)))
        }
        // A selection at the visible edge keeps its handles inside the canvas.
        let area = geometry.canvasRect.insetBy(dx: size / 2, dy: size / 2)
        let kept = area.width > 0 && area.height > 0 ? centers.map { entry in
            (entry.0, CGPoint(x: min(max(entry.1.x, area.minX), area.maxX), y: min(max(entry.1.y, area.minY), area.maxY)))
        } : centers
        return .init(size: size, hitRadius: hit, centers: kept, circular: true)
    }

    public func selectionHandleSize(canvasSize: CGSize) -> CGFloat {
        selectionHandleLayout(canvasSize: canvasSize)?.size ?? CanvasGestureController.handleSize
    }

    public func selectionHandleHitRadius(canvasSize: CGSize) -> CGFloat {
        selectionHandleLayout(canvasSize: canvasSize)?.hitRadius ?? CanvasGestureController.handleSize / 2
    }

    public func selectionHandleCenter(_ handle: CanvasSelectionHandle, canvasSize: CGSize) -> CGPoint? {
        selectionHandleLayout(canvasSize: canvasSize)?.centers.first { $0.handle == handle }?.point
    }

    public func selectionHandle(at point: CGPoint, canvasSize: CGSize) -> CanvasSelectionHandle? {
        guard selectionMaximumRadiusMeters == 2, let layout = selectionHandleLayout(canvasSize: canvasSize) else { return nil }
        return layout.centers.compactMap { entry -> (CanvasSelectionHandle, CGFloat)? in
            guard layout.hits(point, center: entry.point) else { return nil }
            return (entry.handle, hypot(entry.point.x - point.x, entry.point.y - point.y))
        }.min { $0.1 < $1.1 }?.0
    }

    private func resizeResult(from a: CGPoint, to b: CGPoint, handle: CanvasSelectionHandle, canvasSize: CGSize) -> PolarCellMove.Result {
        guard let bounds = selectionBounds,
              let start = PolarProjection(geometry: geometry(canvasSize), maximumRadius: selectionMaximumRadiusMeters).point(at: a),
              let end = PolarProjection(geometry: geometry(canvasSize), maximumRadius: selectionMaximumRadiusMeters).point(at: b) else {
            return .init(workspace: workspace, cells: selectedPolarCells, didHitBoundary: false, cellsByLayer: selectionByLayer)
        }
        let dr = end.radius - start.radius
        let da = end.bearing - start.bearing
        var inner = bounds.innerRadiusMeters, outer = bounds.outerRadiusMeters
        var left = bounds.startBearingDegrees, right = bounds.endBearingDegrees
        if handle.changesInner { inner = min(outer - workspace.grid.cellSizeMeters, inner + dr) }
        if handle.changesOuter { outer = max(inner + workspace.grid.cellSizeMeters, outer + dr) }
        let minimumAngle = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: max(outer, workspace.grid.cellSizeMeters), radialHeightMeters: workspace.grid.cellSizeMeters)
        if handle.changesStart { left = min(right - minimumAngle, left + da) }
        if handle.changesEnd { right = max(left + minimumAngle, right + da) }
        let transform = PolarCellTransform(radialOrigin: bounds.innerRadiusMeters, radialTarget: inner,
            radialScale: (outer - inner) / bounds.radialHeightMeters,
            angularOrigin: bounds.startBearingDegrees, angularTarget: left,
            angularScale: (right - left) / (bounds.endBearingDegrees - bounds.startBearingDegrees))
        return PolarCellTransform.applying(transform, cellsByLayer: selectionByLayer, to: workspace)
    }


    private mutating func commitTransform(_ result: PolarCellMove.Result, copy: Bool = false, named name: String = "Move cells") {
        guard !isPerformanceLocked else { _ = report("Editing is locked in Perform mode"); return }
        let before = workspace
        var next = result.workspace
        if copy {
            for index in next.layers.indices {
                let source = before.layers[index]
                let cells = selectionByLayer[source.id] ?? []
                var layer = next.layers[index]
                layer.polarCells.formUnion(cells)
                for cell in cells where !(result.cellsByLayer[source.id] ?? []).contains(cell) {
                    layer.polarCellOverrides[cell] = source.polarCellOverrides[cell]
                }
                next.replaceLayer(layer, at: index)
            }
        }
        guard next.layers.allSatisfy({ $0.polarCells.union($0.polarCellOverrides.keys).count <= SpatialDocumentBudget.production.addressesPerLayer }) else {
            _ = report("Cell address budget exceeded"); return
        }
        workspace = next
        selectedCells = Set(result.cellsByLayer.flatMap { id, cells in cells.map { CanvasCellSelection(layerID: id, cell: $0) } })
        moveHitBoundary = result.didHitBoundary
        if workspace == before { _ = report(result.didHitBoundary ? "Stopped at the field edge" : "Cells are already at this position") }
        else { statusMessage = result.didHitBoundary ? "Stopped at the field edge" : nil }
        recordCommand(before: before, name: copy ? "Duplicate cells" : name)
    }

    @discardableResult public mutating func duplicateSelection() -> Bool {
        guard !isPerformanceLocked, !selectedCells.isEmpty else { return report("Nothing selected") }
        let before = workspace
        commitTransform(PolarCellMove.applying(radialSteps: 1, angularSteps: 1, cellsByLayer: selectionByLayer, to: workspace), copy: true)
        return workspace != before
    }

    @discardableResult public mutating func copySelection() -> Bool {
        guard !isPerformanceLocked, !selectedCells.isEmpty else { return report("Nothing selected") }
        let order = Dictionary(uniqueKeysWithValues: workspace.layers.enumerated().map { ($0.element.id, $0.offset) })
        clipboard = selectedCells.sorted {
            (order[$0.layerID] ?? Int.max, $0.cell.ring, $0.cell.angularIndex) < (order[$1.layerID] ?? Int.max, $1.cell.ring, $1.cell.angularIndex)
        }.compactMap { pair in
            guard isSelectable(pair), let layer = workspace.layers.first(where: { $0.id == pair.layerID }) else { return nil }
            return .init(layerID: pair.layerID, cell: pair.cell, actions: layer.polarCellOverrides[pair.cell])
        }
        statusMessage = "Copied \(clipboard.count) cells"
        return !clipboard.isEmpty
    }

    public mutating func importClipboard(_ entries: [CanvasCellCopy]) { clipboard = entries }

    @discardableResult public mutating func pasteSelection() -> Bool {
        guard !isPerformanceLocked else { return report("Editing is locked in Perform mode") }
        guard !clipboard.isEmpty else { return report("No cells in clipboard") }
        let before = workspace
        var next = workspace, selection: Set<CanvasCellSelection> = []
        // Validate every destination before applying any entry.
        for entry in clipboard {
            guard isInsideField(entry.cell) else { return report("Clipboard cell is outside the editable field") }
            let id = next.layers.contains { $0.id == entry.layerID } ? entry.layerID : next.selectedLayerID
            guard let index = next.layers.firstIndex(where: { $0.id == id }) else { return report("Destination layer is missing") }
            var layer = next.layers[index]
            guard layer.isVisible, !layer.isLocked else { return report(layer.isLocked ? "Layer ‘\(layer.name)’ is locked" : "Layer ‘\(layer.name)’ is hidden") }
            layer.polarCells.insert(entry.cell)
            layer.polarCellOverrides[entry.cell] = id == entry.layerID ? entry.actions : retargeted(entry.actions, to: layer)
            guard layer.polarCells.union(layer.polarCellOverrides.keys).count <= SpatialDocumentBudget.production.addressesPerLayer else {
                return report("Cell address budget exceeded")
            }
            next.replaceLayer(layer, at: index); selection.insert(.init(layerID: id, cell: entry.cell))
        }
        workspace = next; selectedCells = selection
        recordCommand(before: before, name: "Paste cells")
        if before == workspace { return report("Cells are already present") }
        statusMessage = nil; return true
    }

    @discardableResult public mutating func moveSelection(toLayer id: UUID) -> Bool {
        guard !isPerformanceLocked else { return report("Editing is locked in Perform mode") }
        guard !selectedCells.isEmpty else { return report("Nothing selected") }
        guard let destination = workspace.layers.first(where: { $0.id == id }) else { return report("Destination layer is missing") }
        guard destination.isVisible, !destination.isLocked else { return report(destination.isLocked ? "Layer ‘\(destination.name)’ is locked" : "Layer ‘\(destination.name)’ is hidden") }
        let before = workspace
        _ = copySelection()
        let copies = clipboard
        let oldSelection = selectedCells
        // Stable layer/address ordering resolves collisions deterministically.
        guard case .success = apply(.erase, to: selectedCells, recordsHistory: false) else { return false }
        clipboard = copies.map { .init(layerID: id, cell: $0.cell, actions: retargeted($0.actions, to: destination)) }
        let name = transactionName; transactionName = "Move cells to layer"
        let pasted = pasteSelection()
        transactionName = name; clipboard = copies
        guard pasted || statusMessage == "Cells are already present" else {
            workspace = before; selectedCells = oldSelection
            return false
        }
        guard workspace != before else { return report("Cells already belong to this layer") }
        statusMessage = nil
        recordCommand(before: before, name: "Move cells to layer")
        return true
    }

    public func isSelected(_ cell: PolarMetricGridCell) -> Bool { selectedPolarCells.contains(cell) }

    public func selectionTarget(notes: Bool) -> SpatialRoutingTarget? {
        let ids = Set(selectedCells.map(\.layerID))
        return workspace.layers.filter { ids.contains($0.id) }.flatMap(\.routings).first { routing in
            switch routing.target {
            case .midiNote, .audioUnitNote: return notes
            case .midiCC, .audioUnitCC, .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure, .audioUnitParameter, .midiEffectParameter: return !notes
            default: return false
            }
        }?.target
    }

    @discardableResult public mutating func paintContextCell() -> Bool {
        guard let cell = contextPaintCell else { return report("No empty position selected") }
        guard activeLayerIsEditable() else { return false }
        if case .success(.applied) = apply(.paint, to: [.init(layerID: workspace.selectedLayerID, cell: cell)]) { return true }
        return false
    }

    private mutating func activeLayerIsEditable() -> Bool {
        let layer = workspace.selectedLayer
        if layer.isLocked { return report("Layer ‘\(layer.name)’ is locked") }
        if !layer.isVisible { return report("Layer ‘\(layer.name)’ is hidden") }
        return true
    }

    @discardableResult private mutating func report(_ message: String) -> Bool { statusMessage = message; return false }

    @discardableResult public mutating func applyToSelection(_ operation: SpatialCellBulkOperation, coalescingKey: String? = nil) -> Result<SpatialCellBulkOutcome, SpatialCellBulkRejection> {
        prepareSelectionForOperation()
        return apply(operation, to: selectedCells, coalescingKey: coalescingKey)
    }

    mutating func prepareSelectionForOperation() {
        // Every selection command uses the rectangle's final painted pairs.
        if case .select = activeDrag, let size = activeDragCanvasSize { endDrag(canvasSize: size) }
        else { resetGesture() }
    }

    private mutating func apply(_ operation: SpatialCellBulkOperation, to pairs: Set<CanvasCellSelection>,
                                recordsHistory: Bool = true, coalescingKey: String? = nil) -> Result<SpatialCellBulkOutcome, SpatialCellBulkRejection> {
        guard !isPerformanceLocked else {
            statusMessage = "Editing is locked in Perform mode"
            return .failure(.layerLocked(layerID: workspace.selectedLayerID))
        }
        guard !pairs.isEmpty else { statusMessage = "Nothing selected"; return .failure(.emptySelection) }
        let before = workspace
        var next = workspace, count = 0
        let groups = Dictionary(grouping: pairs, by: \.layerID)
        for index in next.layers.indices {
            var layer = next.layers[index]
            guard let group = groups[layer.id] else { continue }
            guard layer.isVisible, !layer.isLocked else {
                statusMessage = layer.isLocked ? "Layer ‘\(layer.name)’ is locked" : "Layer ‘\(layer.name)’ is hidden"
                return .failure(.layerLocked(layerID: layer.id))
            }
            let mapped: SpatialCellBulkOperation
            switch operation {
            case let .setAction(action), let .assignAndActivate(action):
                guard let target = compatibleTarget(action.target, routings: layer.routings) else {
                    statusMessage = "Layer ‘\(layer.name)’ has no compatible output"
                    return .failure(.targetNotRouted(action.target))
                }
                let own = SpatialCellAction(target: target, value: action.value)
                mapped = { if case .assignAndActivate = operation { return .assignAndActivate(own) }; return .setAction(own) }()
            case let .removeActions(target):
                mapped = compatibleTarget(target, routings: layer.routings).map { .removeActions(target: $0) } ?? .removeOwnValues
            default: mapped = operation
            }
            let result = SpatialCellBulkEdit.apply(mapped, to: Set(group.map(\.cell)), isLocked: layer.isLocked,
                layerID: layer.id, routings: layer.routings, cells: &layer.polarCells, overrides: &layer.polarCellOverrides,
                addressBudget: SpatialDocumentBudget.production.addressesPerLayer)
            switch result {
            case .success(.applied(let changed)): count += changed
            case .success(.unchanged): break
            case .failure(let reason):
                statusMessage = "Layer ‘\(layer.name)’: \(reason)"
                return .failure(reason)
            }
            next.replaceLayer(layer, at: index)
        }
        workspace = next
        selectedCells = selectableCells(selectedCells)
        if recordsHistory { recordCommand(before: before, name: operation.undoActionName, coalescingKey: coalescingKey) }
if count == 0 { statusMessage = "No cells changed"; return .success(.unchanged) }
        statusMessage = nil
        return .success(.applied(changedCells: count))
    }

    private func compatibleTarget(_ target: SpatialRoutingTarget, routings: [SpatialRouting]) -> SpatialRoutingTarget? {
        if routings.contains(where: { $0.target == target }) { return target }
        func family(_ value: SpatialRoutingTarget) -> Int {
            switch value {
            case .midiNote, .audioUnitNote: return 0
            case .midiCC, .audioUnitCC, .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure, .audioUnitParameter, .midiEffectParameter: return 1
            case .sceneSwitch: return 2
            case .releaseLayer: return 3
            case .boolean: return 4
            case .midiAllNotesOff, .audioUnitAllNotesOff: return 5
            case .midiProgramChange, .audioUnitProgramChange: return 6
            }
        }
        return routings.first { family($0.target) == family(target) }?.target
    }

    private func retargeted(_ actions: [SpatialCellAction]?, to layer: SpatialInstrumentLayer) -> [SpatialCellAction]? {
        actions?.map { action in
            .init(target: compatibleTarget(action.target, routings: layer.routings) ?? action.target, value: action.value)
        }
    }

    private mutating func recordCommand(before: SpatialInstrumentWorkspace, name: String, coalescingKey: String? = nil) {
        guard transactionName == nil, before != workspace else { return }
        let id = coalescingKey != nil && coalescingKey == feedback.coalescingKey ? feedback.coalescingID ?? UUID() : UUID()
        feedback.coalescingKey = coalescingKey; feedback.coalescingID = id
        command = .init(id: id, name: name, before: before, after: workspace,
                        selection: selection, coalescingKey: coalescingKey)
    }
    private func isOnlyLayerSelectionChange(from a: SpatialInstrumentWorkspace, to b: SpatialInstrumentWorkspace) -> Bool {
        a.ignoringLayerSelection() == b.ignoringLayerSelection()
    }
    private mutating func recordCoalescingBoundary() { endCoalescing() }
    private mutating func endCoalescing() { feedback.coalescingKey = nil; feedback.coalescingID = nil }

    /// Verschiebt den Inhalt um die vom System gemeldete Trackpad-Strecke.
    /// Pinch bleibt davon unabhängig und zoomt weiterhin am Zeiger.
    @discardableResult
    public mutating func contextMenuSelection(at point: CGPoint, canvasSize: CGSize) -> Bool {
        guard !isPerformanceLocked, !isDragging, point.x.isFinite, point.y.isFinite,
              geometry(canvasSize).canvasRect.contains(point) else { return false }
        if let pair = hit(at: point, canvasSize: canvasSize) {
            if !selectedCells.contains(pair) { selectedCells = [pair] }
            workspace.selectLayer(pair.layerID); recordCoalescingBoundary()
            contextPaintCell = nil; statusMessage = nil
        } else {
            selectedCells = []
            contextPaintCell = rawCell(atScreenPoint: point, geometry: geometry(canvasSize)).flatMap { isInsideField($0) ? $0 : nil }
            explainEmptyHit(at: point, canvasSize: canvasSize)
        }
        return true
    }

    @discardableResult
    public mutating func panViewport(byScreenX deltaX: Double, screenY deltaY: Double) -> Bool {
        guard activeDrag == nil,
              let panned = MetricCanvasGeometry(
                  size: CGSize(width: 1, height: 1),
                  viewport: viewport,
                  isHorizontallyMirrored: isHorizontallyMirrored
              ).panned(byScreenX: deltaX, screenY: deltaY),
              panned != viewport else { return false }
        viewport = panned
        keepsScannerAtBottom = false
        return true
    }

    @discardableResult
    public mutating func zoom(
        byFactor factor: Double,
        atScreenPoint point: CGPoint,
        canvasSize: CGSize
    ) -> Bool {
        guard activeDrag == nil else { return false }
        let geometry = MetricCanvasGeometry(
            size: canvasSize, viewport: viewport,
            isHorizontallyMirrored: isHorizontallyMirrored
        )
        guard let anchor = geometry.boundedMetricPoint(forScreenPoint: point),
              let zoomed = viewport.zoomed(byFactor: factor, anchor: anchor),
              zoomed != viewport else { return false }
        viewport = zoomed
        keepsScannerAtBottom = false
        return true
    }

    /// Ein Preset bringt Maßstab und seitliche Lage mit. Seine Höhenlage
    /// stammt aus einem anderen Fenster; der Scanner bleibt deshalb an der
    /// Unterkante der aktuellen Fläche (`followCanvasSize`).
    public mutating func applyPresetViewport(_ value: MetricCanvasViewport, canvasSize: CGSize? = nil) {
        resetGesture(); viewport = value; keepsScannerAtBottom = true
        if let canvasSize { _ = followCanvasSize(canvasSize) }
    }

    public mutating func resetViewport() {
        resetGesture()
        viewport = .instrumentDefault
        keepsScannerAtBottom = true
    }

    /// Hält den Scannerursprung bei verankertem Ausschnitt exakt an der
    /// Unterkante der neuen Fläche; Maßstab und seitliche Lage bleiben.
    @discardableResult
    public mutating func followCanvasSize(_ canvasSize: CGSize) -> Bool {
        viewState.canvasSize = canvasSize
        if activeDrag != nil { viewState.deferredSize = canvasSize; return false }
        guard keepsScannerAtBottom,
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0,
              let anchored = try? MetricCanvasViewport.build(
                centerXMeters: viewport.centerXMeters,
                centerYMeters: Double(canvasSize.height) * viewport.metersPerPoint / 2,
                metersPerPoint: viewport.metersPerPoint
              ), anchored != viewport else { return false }
        viewport = anchored
        return true
    }

    /// Setzt den Scannerursprung für die konkrete Canvasgröße exakt auf
    /// die untere Kante. Die metrische Skalierung bleibt isotrop.
    @discardableResult
    public mutating func resetViewport(canvasSize: CGSize) -> Bool {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0,
              let reset = try? MetricCanvasViewport.build(
                centerXMeters: 0,
                centerYMeters: Double(canvasSize.height) * MetricCanvasViewport.instrumentDefault.metersPerPoint / 2,
                metersPerPoint: MetricCanvasViewport.instrumentDefault.metersPerPoint
              ) else { return false }
        resetGesture()
        viewport = reset
        keepsScannerAtBottom = true
        return true
    }

    /// Zoomt einmalig so, dass alle gültigen Messpunkte des Profils samt
    /// Rand vollständig und möglichst groß ins Fenster passen. Der Rand je
    /// Seite ist 10 % der Ausdehnung, mindestens 10 cm. Fernwerte und
    /// „kein Echo" fallen über die Projektion heraus. Ohne gültigen Punkt
    /// bleibt der Viewport unverändert. Reine Ansicht: keine musikalische
    /// Revision, kein Lösen.
    @discardableResult
    public mutating func fitViewport(
        toMeasurementsOf profile: B0ScanProfile,
        canvasSize: CGSize
    ) -> Bool {
        let points = MetricScanProjection().project(profile).map(\.point)
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0,
              let minX = points.map(\.xMeters).min(),
              let maxX = points.map(\.xMeters).max(),
              let minY = points.map(\.yMeters).min(),
              let maxY = points.map(\.yMeters).max()
        else { return false }
        let marginX = max(0.10, (maxX - minX) * 0.10)
        let marginY = max(0.10, (maxY - minY) * 0.10)
        let width = maxX - minX + 2 * marginX
        let height = maxY - minY + 2 * marginY
        let required = max(width / Double(canvasSize.width), height / Double(canvasSize.height))
        let metersPerPoint = min(
            max(required, MetricCanvasViewport.minimumMetersPerPoint),
            MetricCanvasViewport.maximumMetersPerPoint
        )
        guard let fitted = try? MetricCanvasViewport.build(
            centerXMeters: (minX + maxX) / 2,
            centerYMeters: (minY + maxY) / 2,
            metersPerPoint: metersPerPoint
        ) else { return false }
        resetGesture()
        viewport = fitted
        keepsScannerAtBottom = false
        return true
    }
}
