import Foundation
import CoreGraphics
import SickPLSCore
import PlanariumDomain

extension CanvasSession {
    @discardableResult public func contextMenuSelection(at point: CGPoint, canvasSize: CGSize) -> Bool {
        commitNumberEdits()
        guard authorizeAuthoring() else { return false }
        return perform { $0.contextMenuSelection(at: point, canvasSize: canvasSize) }
    }
    public func isEnabled(_ command: MetricCanvasCommand, canvasSize: CGSize? = nil, profile: B0ScanProfile? = nil) -> Bool {
        presentation.isEnabled(command, canvasSize: canvasSize, profile: profile)
    }
    public func displayGeometry(canvasSize: CGSize) -> MetricCanvasGeometry { presentation.displayGeometry(canvasSize: canvasSize) }
    public func selectionHandle(at point: CGPoint, canvasSize: CGSize) -> CanvasSelectionHandle? {
        presentation.selectionHandle(at: point, canvasSize: canvasSize)
    }
    public func isSelected(_ cell: PolarMetricGridCell) -> Bool { presentation.isSelected(cell) }
    public func selectionTarget(notes: Bool) -> SpatialRoutingTarget? { presentation.selectionTarget(notes: notes) }
    public func finishEditing()  {
        perform { $0.finishEditing() }
    }
    public func noteHistoryCommand(_ changed: Bool, redo: Bool)  {
        perform { $0.noteHistoryCommand(changed, redo: redo) }
    }
    @discardableResult public func performEdit(
        named name: String,
        _ change: (inout MetricCanvasInteractionState) -> Bool
    ) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.performEdit(named: name, change) }
    }
    public func updateWorkspace(_ change: (inout SpatialInstrumentWorkspace) -> Void)  {
        guard authorizeAuthoring() else { return }
        perform { $0.updateWorkspace(change) }
    }
    public func updateWorkspace(
        named name: String,
        coalescingKey: String? = nil,
        _ change: (inout SpatialInstrumentWorkspace) -> Void
    )  {
        guard authorizeAuthoring() else { return }
        perform { $0.updateWorkspace(named: name, coalescingKey: coalescingKey, change) }
    }
    @discardableResult public func renameSelectedLayer(_ name: String) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.renameSelectedLayer(name) }
    }
    @discardableResult public func setSelectedLayerColor(_ color: SpatialLayerColor) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.setSelectedLayerColor(color) }
    }
    @discardableResult public func setSelectedLayerTarget(
        _ target: SpatialRoutingTarget,
        program: SpatialValueProgram = .constant(0)
    ) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.setSelectedLayerTarget(target, program: program) }
    }
    @discardableResult public func clearSelectedLayerTarget() -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.clearSelectedLayerTarget() }
    }
    @discardableResult public func setSelectedLayerMIDIChannel(_ channel: UInt8) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.setSelectedLayerMIDIChannel(channel) }
    }
    public func replaceWorkspace(_ workspace: SpatialInstrumentWorkspace)  {
        guard authorizeAuthoring() else { return }
        perform { $0.replaceWorkspace(workspace) }
    }
    @discardableResult public func requestGridChange(to size: MetricSquareGrid.CellSize) -> SpatialInstrumentWorkspace.GridChange {
        guard authorizeAuthoring() else { return .unchanged }
        return perform { $0.requestGridChange(to: size) }
    }
    @discardableResult public func confirmGridChange(to size: MetricSquareGrid.CellSize) -> SpatialInstrumentWorkspace.GridChange {
        guard authorizeAuthoring() else { return .unchanged }
        return perform { $0.confirmGridChange(to: size) }
    }
    public func select(tool: MetricCanvasTool)  {
        guard authorizeAuthoring() else { return }
        perform { $0.select(tool: tool) }
    }
    @discardableResult public func fitToRoom(_ contour: SpatialRoomContour, marginCentimeters: Double = 10) -> Double? {
        return perform { $0.fitToRoom(contour, marginCentimeters: marginCentimeters) }
    }
    public func toggleHorizontalMirror()  {
        perform { $0.toggleHorizontalMirror() }
    }
    public func holdHand(_ held: Bool)  {
        perform { $0.holdHand(held) }
    }
    @discardableResult public func beginViewportDrag(at point: CGPoint, canvasSize: CGSize) -> Bool {
        return perform { $0.beginViewportDrag(at: point, canvasSize: canvasSize) }
    }
    @discardableResult public func selectLayers(_ ids: Set<UUID>, active id: UUID? = nil) -> Bool {
        commitNumberEdits()
        guard authorizeAuthoring() else { return false }
        return perform { $0.selectLayers(ids, active: id) }
    }
    @discardableResult public func selectSurfaces(_ ids: Set<UUID>, routingID: UUID? = nil, inLayer layerID: UUID? = nil) -> Bool {
        commitNumberEdits()
        guard authorizeAuthoring() else { return false }
        return perform { $0.selectSurfaces(ids, routingID: routingID, inLayer: layerID) }
    }
    @discardableResult public func beginDrag(at point: CGPoint, canvasSize: CGSize,
                                   modifiers: SelectionModifiers = [], brush: Bool = false) -> Bool {
        commitNumberEdits()
        return perform { $0.beginDrag(at: point, canvasSize: canvasSize, modifiers: modifiers, brush: brush) }
    }
    @discardableResult public func updateDrag(to point: CGPoint, canvasSize: CGSize) -> Bool {
        return perform { $0.updateDrag(to: point, canvasSize: canvasSize) }
    }
    public func endDrag(canvasSize: CGSize)  {
        perform { $0.endDrag(canvasSize: canvasSize) }
    }
    @discardableResult public func selectCell(atScreenPoint point: CGPoint, canvasSize: CGSize,
                                                       modifiers: SelectionModifiers = []) -> Bool {
        commitNumberEdits()
        guard authorizeAuthoring() else { return false }
        return perform { $0.selectCell(atScreenPoint: point, canvasSize: canvasSize, modifiers: modifiers) }
    }
    @discardableResult public func toggleCellSelection(atScreenPoint point: CGPoint, canvasSize: CGSize) -> Bool {
        commitNumberEdits()
        guard authorizeAuthoring() else { return false }
        return perform { $0.toggleCellSelection(atScreenPoint: point, canvasSize: canvasSize) }
    }
    @discardableResult public func extendSelection(toScreenPoint point: CGPoint, canvasSize: CGSize) -> Bool {
        commitNumberEdits()
        guard authorizeAuthoring() else { return false }
        return perform { $0.extendSelection(toScreenPoint: point, canvasSize: canvasSize) }
    }
    @discardableResult public func selectZone(at point: CGPoint, canvasSize: CGSize,
        modifiers: SelectionModifiers = [], selectionBeforeClick: Set<CanvasCellSelection>? = nil) -> Bool {
        commitNumberEdits()
        guard authorizeAuthoring() else { return false }
        return perform { $0.selectZone(at: point, canvasSize: canvasSize, modifiers: modifiers, selectionBeforeClick: selectionBeforeClick) }
    }
    @discardableResult public func selectDoubleClick(at point: CGPoint, canvasSize: CGSize,
        modifiers: SelectionModifiers = [], selectionBeforeClick: Set<CanvasCellSelection>? = nil) -> Bool {
        commitNumberEdits()
        guard authorizeAuthoring() else { return false }
        return perform { $0.selectDoubleClick(at: point, canvasSize: canvasSize, modifiers: modifiers, selectionBeforeClick: selectionBeforeClick) }
    }
    public func clearSelection()  {
        commitNumberEdits()
        guard authorizeAuthoring() else { return }
        perform { $0.clearSelection() }
    }
    @discardableResult public func perform(_ command: MetricCanvasCommand, canvasSize: CGSize? = nil,
                                                    profile: B0ScanProfile? = nil) -> Bool {
        switch command {
        case .delete, .selectAll:
            guard authorizeAuthoring() else { return false }
        default: break
        }
        return perform { $0.perform(command, canvasSize: canvasSize, profile: profile) }
    }
    @discardableResult public func handleKey(_ key: MetricCanvasKey, modifiers: SelectionModifiers = []) -> MetricCanvasKeyCommand? {
        if key != .escape, key != .handTool {
            guard authorizeAuthoring() else { return nil }
        }
        return perform { $0.handleKey(key, modifiers: modifiers) }
    }
    @discardableResult public func duplicateSelection() -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.duplicateSelection() }
    }
    @discardableResult public func copySelection() -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.copySelection() }
    }
    public func importClipboard(_ entries: [CanvasCellCopy])  {
        guard authorizeAuthoring() else { return }
        perform { $0.importClipboard(entries) }
    }
    @discardableResult public func pasteSelection() -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.pasteSelection() }
    }
    @discardableResult public func moveSelection(toLayer id: UUID) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.moveSelection(toLayer: id) }
    }
    @discardableResult public func paintContextCell() -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.paintContextCell() }
    }
    /// Fine-lattice pitch edits use the document owner's native bulk handler;
    /// cell and layer edits still share this session, permission and history boundary.
    @discardableResult public func applyToSelection(_ operation: SpatialPitchOperation) -> Bool {
        commitNumberEdits()
        guard authorizeAuthoring() else { return false }
        perform { $0.prepareSelectionForOperation() }
        return onPitchOperation?(operation) ?? false
    }
    @discardableResult public func applyToSelection(_ operation: SpatialCellBulkOperation, coalescingKey: String? = nil) -> Result<SpatialCellBulkOutcome, SpatialCellBulkRejection> {
        guard authorizeAuthoring() else { return .failure(.layerLocked(layerID: workspace.selectedLayerID)) }
        return perform { $0.applyToSelection(operation, coalescingKey: coalescingKey) }
    }
    @discardableResult public func panViewport(byScreenX deltaX: Double, screenY deltaY: Double) -> Bool {
        return perform { $0.panViewport(byScreenX: deltaX, screenY: deltaY) }
    }
    @discardableResult public func zoom(
        byFactor factor: Double,
        atScreenPoint point: CGPoint,
        canvasSize: CGSize
    ) -> Bool {
        return perform { $0.zoom(byFactor: factor, atScreenPoint: point, canvasSize: canvasSize) }
    }
    public func applyPresetViewport(_ value: MetricCanvasViewport, canvasSize: CGSize? = nil)  {
        perform { $0.applyPresetViewport(value, canvasSize: canvasSize) }
    }
    public func resetViewport()  {
        perform { $0.resetViewport() }
    }
    @discardableResult public func followCanvasSize(_ canvasSize: CGSize) -> Bool {
        return perform { $0.followCanvasSize(canvasSize) }
    }
    @discardableResult public func resetViewport(canvasSize: CGSize) -> Bool {
        return perform { $0.resetViewport(canvasSize: canvasSize) }
    }
    @discardableResult public func fitViewport(
        toMeasurementsOf profile: B0ScanProfile,
        canvasSize: CGSize
    ) -> Bool {
        return perform { $0.fitViewport(toMeasurementsOf: profile, canvasSize: canvasSize) }
    }
    @discardableResult public func applyAssignment(_ draft: SpatialAssignmentDraft) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.applyAssignment(draft) }
    }
    @discardableResult public func rerollAssignmentSeed() -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.rerollAssignmentSeed() }
    }
    @discardableResult public func setAssignmentCCNumber(_ number: UInt8) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.setAssignmentCCNumber(number) }
    }
    @discardableResult public func setReleaseLayerTarget(_ id: UUID, layerOnly: Bool = false) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.setReleaseLayerTarget(id, layerOnly: layerOnly) }
    }
    @discardableResult public func setSceneAction(_ action: SpatialSceneSwitchAction, layerOnly: Bool = false) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.setSceneAction(action, layerOnly: layerOnly) }
    }
    @discardableResult public func resetSelectedCellsToLayer() -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.resetSelectedCellsToLayer() }
    }
    @discardableResult public func applyCellNotes(
        _ draft: SpatialCellNoteDraft,
        cell: PolarMetricGridCell
    ) -> Bool {
        guard authorizeAuthoring() else { return false }
        return perform { $0.applyCellNotes(draft, cell: cell) }
    }
}
