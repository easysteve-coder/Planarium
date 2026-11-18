import Foundation
@testable import PlanariumApplication
import PlanariumAudio
import PlanariumDomain
import PlanariumMIDI
import PlanariumRuntime
import PlanariumPresets
import AppKit

@MainActor final class CanvasOfflineMIDI: MIDIConnectionBoundary {
    var onDestinationLost: (@MainActor () -> Void)?
    func destinations() -> [MIDITargetDescription] { [] }
    func open(_ target: InstrumentMIDITarget) -> Result<any MIDISendBoundary, MIDIConnectionError> { .failure(.init("Test destination unavailable")) }
    func close() {}
}
@MainActor final class CanvasOfflinePlugins: PluginComponentSource {
    func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) { completion(.failure(.init("Test component unavailable"))) }
}
private final class CanvasEmptyCatalog: AudioUnitComponentSource {
    func effectComponentDescriptions() -> [AudioUnitComponentDescription] { [] }
}
@MainActor struct CanvasOfflineRoot {
    let root: PlanariumComposition
    init(components: (any PluginComponentSource)? = nil, graph: CanvasOfflineGraph? = nil,
         clock: any RuntimeClock = MonotonicRuntimeClock()) throws {
        root = try .init(midi: CanvasOfflineMIDI(), components: components ?? CanvasOfflinePlugins(), clock: clock, configuration: .init(offline: true),
                         graph: graph ?? CanvasOfflineGraph(), windows: CanvasOfflineWindows())
    }
}
@MainActor final class CanvasOfflineGraph: MixerGraphBoundary {
    func makeChannelGraph() -> any AudioGraphBoundary { CanvasOfflineGraph() }
    func setMasterLevel(decibels: Double) {}
    func installMasterMeter(_ holder: PeakHolder) {}
    func removeMasterMeter() {}
    func fade(silent: Bool) -> UInt32 { 0 }
    func fadeReached(_ token: UInt32) -> Bool { true }
    func setMuted(_ muted: Bool) {}
    var permitsStart = false
    var starts = 0
    func installMeter(_ holder: PeakHolder) {}
    func removeMeter() {}
    func configure(_ configuration: AudioHostConfiguration) throws {}
    func attach(_ instance: PluginInstance, instrument: Bool) throws {}
    func remove(_ instance: PluginInstance) {}
    @discardableResult func connect(instrument: PluginInstance?, inserts: [PluginInstance]) -> AudioGraphConnectionResult { .init() }
    func setLevel(decibels: Double) {}
    func start() throws { starts += 1; if !permitsStart { XCTFail("Headless tests must not start audio") } }
    func stop() {}
}
@MainActor final class CanvasOfflineWindows: PluginWindowFactory {
    func make(title: String, size: NSSize) -> any PluginWindow { fatalError("Headless tests must not open editors") }
}

import XCTest
import CoreGraphics
@testable import SickPLSMonitorKit
import SickPLSCore

/// Legacy pure authoring cases now execute the real document owner and its
/// sole history. No test history or replay stack is implemented here.
@MainActor @dynamicMemberLookup final class CanvasDocumentFixture {
    private let root: CanvasOfflineRoot
    private var owner: SpatialInstrumentRuntimeModel
    init(viewport: MetricCanvasViewport = .instrumentDefault, tool: MetricCanvasTool = .select,
         isHorizontallyMirrored: Bool = false) {
        do {
            root = try CanvasOfflineRoot()
            owner = root.root.document
            var view = owner.canvas.viewportOwner.state
            view.viewport = viewport; view.tool = tool; view.mirrored = isHorizontallyMirrored
            owner.canvas.viewportOwner.update(view)
        } catch { fatalError("Offline document fixture could not be constructed") }
    }
    var presentation: MetricCanvasInteractionState { owner.canvas.presentation }
    var document: InstrumentDocument { owner.document }
    var session: CanvasSession { owner.canvas }
    func confirmOutputChange() { owner.confirmOutputChange() }
    subscript<T>(dynamicMember path: KeyPath<MetricCanvasInteractionState, T>) -> T {
        owner.canvas.presentation[keyPath: path]
    }
    subscript<T>(dynamicMember path: WritableKeyPath<MetricCanvasInteractionState, T>) -> T {
        get { owner.canvas.presentation[keyPath: path] }
        set { owner.canvas.perform { $0[keyPath: path] = newValue } }
    }
    var undoDepth: Int { owner.historyDepth }
    var canUndo: Bool { owner.canUndo }
    var canRedo: Bool { owner.canRedo }
    var undoActionName: String? { owner.canUndo ? String(owner.undoMenuTitle.dropFirst(6)) : nil }
    var redoActionName: String? { owner.canRedo ? String(owner.redoMenuTitle.dropFirst(6)) : nil }
    @discardableResult func undo() -> Bool { owner.undo() }
    @discardableResult func redo() -> Bool { owner.redo() }
    func replaceWorkspace(_ value: SpatialInstrumentWorkspace) {
        let view = owner.canvas.viewportOwner.state
        do {
            owner = try SpatialInstrumentRuntimeModel(runtime: root.root.runtime, audio: root.root.audio,
                                                       midi: root.root.midi, initialWorkspace: value)
            owner.canvas.viewportOwner.update(view)
        } catch { XCTFail("Fixture workspace rejected") }
    }
    deinit { MainActor.assumeIsolated { root.root.terminate {} } }

    @discardableResult public func contextMenuSelection(at point: CGPoint, canvasSize: CGSize) -> Bool {
        owner.canvas.perform { $0.contextMenuSelection(at: point, canvasSize: canvasSize) }
    }
    public func isEnabled(_ command: MetricCanvasCommand, canvasSize: CGSize? = nil, profile: B0ScanProfile? = nil) -> Bool {
        owner.canvas.presentation.isEnabled(command, canvasSize: canvasSize, profile: profile)
    }
    public func displayGeometry(canvasSize: CGSize) -> MetricCanvasGeometry { owner.canvas.presentation.displayGeometry(canvasSize: canvasSize) }
    public func selectionHandle(at point: CGPoint, canvasSize: CGSize) -> CanvasSelectionHandle? {
        owner.canvas.presentation.selectionHandle(at: point, canvasSize: canvasSize)
    }
    public func isSelected(_ cell: PolarMetricGridCell) -> Bool { owner.canvas.presentation.isSelected(cell) }
    public func selectionTarget(notes: Bool) -> SpatialRoutingTarget? { owner.canvas.presentation.selectionTarget(notes: notes) }
    public func setPerformanceLocked(_ locked: Bool)  {
        owner.canvas.setPerformanceLocked(locked)
    }
    public func finishEditing()  {
        owner.canvas.perform { $0.finishEditing() }
    }
    public func noteHistoryCommand(_ changed: Bool, redo: Bool)  {
        owner.canvas.perform { $0.noteHistoryCommand(changed, redo: redo) }
    }
    @discardableResult public func performEdit(
        named name: String,
        _ change: (inout MetricCanvasInteractionState) -> Bool
    ) -> Bool {
        return owner.canvas.perform { $0.performEdit(named: name, change) }
    }
    public func updateWorkspace(_ change: (inout SpatialInstrumentWorkspace) -> Void)  {
        owner.canvas.perform { $0.updateWorkspace(change) }
    }
    public func updateWorkspace(
        named name: String,
        coalescingKey: String? = nil,
        _ change: (inout SpatialInstrumentWorkspace) -> Void
    )  {
        owner.canvas.perform { $0.updateWorkspace(named: name, coalescingKey: coalescingKey, change) }
    }
    @discardableResult public func renameSelectedLayer(_ name: String) -> Bool {
        return owner.canvas.perform { $0.renameSelectedLayer(name) }
    }
    @discardableResult public func setSelectedLayerColor(_ color: SpatialLayerColor) -> Bool {
        return owner.canvas.perform { $0.setSelectedLayerColor(color) }
    }
    @discardableResult public func setSelectedLayerTarget(
        _ target: SpatialRoutingTarget,
        program: SpatialValueProgram = .constant(0)
    ) -> Bool {
        return owner.canvas.perform { $0.setSelectedLayerTarget(target, program: program) }
    }
    @discardableResult public func clearSelectedLayerTarget() -> Bool {
        return owner.canvas.perform { $0.clearSelectedLayerTarget() }
    }
    @discardableResult public func setSelectedLayerMIDIChannel(_ channel: UInt8) -> Bool {
        return owner.canvas.perform { $0.setSelectedLayerMIDIChannel(channel) }
    }

    @discardableResult public func requestGridChange(to size: MetricSquareGrid.CellSize) -> SpatialInstrumentWorkspace.GridChange {
        return owner.canvas.perform { $0.requestGridChange(to: size) }
    }
    @discardableResult public func confirmGridChange(to size: MetricSquareGrid.CellSize) -> SpatialInstrumentWorkspace.GridChange {
        return owner.canvas.perform { $0.confirmGridChange(to: size) }
    }
    public func select(tool: MetricCanvasTool)  {
        owner.canvas.perform { $0.select(tool: tool) }
    }
    @discardableResult public func fitToRoom(_ contour: SpatialRoomContour, marginCentimeters: Double = 10) -> Double? {
        return owner.canvas.perform { $0.fitToRoom(contour, marginCentimeters: marginCentimeters) }
    }
    public func toggleHorizontalMirror()  {
        owner.canvas.perform { $0.toggleHorizontalMirror() }
    }
    public func holdHand(_ held: Bool)  {
        owner.canvas.perform { $0.holdHand(held) }
    }
    @discardableResult public func beginViewportDrag(at point: CGPoint, canvasSize: CGSize) -> Bool {
        return owner.canvas.perform { $0.beginViewportDrag(at: point, canvasSize: canvasSize) }
    }
    @discardableResult public func selectLayers(_ ids: Set<UUID>, active id: UUID? = nil) -> Bool {
        return owner.canvas.perform { $0.selectLayers(ids, active: id) }
    }
    @discardableResult public func beginDrag(at point: CGPoint, canvasSize: CGSize,
                                   modifiers: SelectionModifiers = [], brush: Bool = false) -> Bool {
        return owner.canvas.perform { $0.beginDrag(at: point, canvasSize: canvasSize, modifiers: modifiers, brush: brush) }
    }
    @discardableResult public func updateDrag(to point: CGPoint, canvasSize: CGSize) -> Bool {
        return owner.canvas.perform { $0.updateDrag(to: point, canvasSize: canvasSize) }
    }
    public func endDrag(canvasSize: CGSize)  {
        owner.canvas.perform { $0.endDrag(canvasSize: canvasSize) }
    }
    @discardableResult public func selectCell(atScreenPoint point: CGPoint, canvasSize: CGSize,
                                                       modifiers: SelectionModifiers = []) -> Bool {
        return owner.canvas.perform { $0.selectCell(atScreenPoint: point, canvasSize: canvasSize, modifiers: modifiers) }
    }
    @discardableResult public func toggleCellSelection(atScreenPoint point: CGPoint, canvasSize: CGSize) -> Bool {
        return owner.canvas.perform { $0.toggleCellSelection(atScreenPoint: point, canvasSize: canvasSize) }
    }
    @discardableResult public func extendSelection(toScreenPoint point: CGPoint, canvasSize: CGSize) -> Bool {
        return owner.canvas.perform { $0.extendSelection(toScreenPoint: point, canvasSize: canvasSize) }
    }
    @discardableResult public func selectZone(at point: CGPoint, canvasSize: CGSize) -> Bool {
        return owner.canvas.perform { $0.selectZone(at: point, canvasSize: canvasSize) }
    }
    public func clearSelection()  {
        owner.canvas.perform { $0.clearSelection() }
    }
    @discardableResult public func perform(_ command: MetricCanvasCommand, canvasSize: CGSize? = nil,
                                                    profile: B0ScanProfile? = nil) -> Bool {
        return owner.canvas.perform { $0.perform(command, canvasSize: canvasSize, profile: profile) }
    }
    @discardableResult public func handleKey(_ key: MetricCanvasKey, modifiers: SelectionModifiers = []) -> MetricCanvasKeyCommand? {
        return owner.canvas.perform { $0.handleKey(key, modifiers: modifiers) }
    }
    @discardableResult public func duplicateSelection() -> Bool {
        return owner.canvas.perform { $0.duplicateSelection() }
    }
    @discardableResult public func copySelection() -> Bool {
        return owner.canvas.perform { $0.copySelection() }
    }
    public func importClipboard(_ entries: [CanvasCellCopy])  {
        owner.canvas.perform { $0.importClipboard(entries) }
    }
    @discardableResult public func pasteSelection() -> Bool {
        return owner.canvas.perform { $0.pasteSelection() }
    }
    @discardableResult public func moveSelection(toLayer id: UUID) -> Bool {
        return owner.canvas.perform { $0.moveSelection(toLayer: id) }
    }
    @discardableResult public func paintContextCell() -> Bool {
        return owner.canvas.perform { $0.paintContextCell() }
    }
    @discardableResult public func applyToSelection(_ operation: SpatialCellBulkOperation) -> Result<SpatialCellBulkOutcome, SpatialCellBulkRejection> {
        return owner.canvas.perform { $0.applyToSelection(operation) }
    }
    @discardableResult public func panViewport(byScreenX deltaX: Double, screenY deltaY: Double) -> Bool {
        return owner.canvas.perform { $0.panViewport(byScreenX: deltaX, screenY: deltaY) }
    }
    @discardableResult public func zoom(
        byFactor factor: Double,
        atScreenPoint point: CGPoint,
        canvasSize: CGSize
    ) -> Bool {
        return owner.canvas.perform { $0.zoom(byFactor: factor, atScreenPoint: point, canvasSize: canvasSize) }
    }
    public func applyPresetViewport(_ value: MetricCanvasViewport, canvasSize: CGSize? = nil)  {
        owner.canvas.perform { $0.applyPresetViewport(value, canvasSize: canvasSize) }
    }
    public func resetViewport()  {
        owner.canvas.perform { $0.resetViewport() }
    }
    @discardableResult public func followCanvasSize(_ canvasSize: CGSize) -> Bool {
        return owner.canvas.perform { $0.followCanvasSize(canvasSize) }
    }
    @discardableResult public func resetViewport(canvasSize: CGSize) -> Bool {
        return owner.canvas.perform { $0.resetViewport(canvasSize: canvasSize) }
    }
    @discardableResult public func fitViewport(
        toMeasurementsOf profile: B0ScanProfile,
        canvasSize: CGSize
    ) -> Bool {
        return owner.canvas.perform { $0.fitViewport(toMeasurementsOf: profile, canvasSize: canvasSize) }
    }
    @discardableResult public func applyAssignment(_ draft: SpatialAssignmentDraft) -> Bool {
        return owner.canvas.perform { $0.applyAssignment(draft) }
    }
    @discardableResult public func rerollAssignmentSeed() -> Bool {
        return owner.canvas.perform { $0.rerollAssignmentSeed() }
    }
    @discardableResult public func setAssignmentCCNumber(_ number: UInt8) -> Bool {
        return owner.canvas.perform { $0.setAssignmentCCNumber(number) }
    }
    @discardableResult public func setReleaseLayerTarget(_ id: UUID, layerOnly: Bool = false) -> Bool {
        return owner.canvas.perform { $0.setReleaseLayerTarget(id, layerOnly: layerOnly) }
    }
    @discardableResult public func setSceneAction(_ action: SpatialSceneSwitchAction, layerOnly: Bool = false) -> Bool {
        return owner.canvas.perform { $0.setSceneAction(action, layerOnly: layerOnly) }
    }
    @discardableResult public func resetSelectedCellsToLayer() -> Bool {
        return owner.canvas.perform { $0.resetSelectedCellsToLayer() }
    }
    @discardableResult public func applyCellNotes(
        _ draft: SpatialCellNoteDraft,
        cell: PolarMetricGridCell
    ) -> Bool {
        return owner.canvas.perform { $0.applyCellNotes(draft, cell: cell) }
    }

}
