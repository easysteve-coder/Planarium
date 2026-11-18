import Combine
import CoreGraphics
import Foundation
import PlanariumDomain

/// Opt-in stage timings for offline interaction measurements. No publication;
/// the production path does not read a clock unless a probe is installed.
@MainActor public final class CanvasTimingProbe {
    public static var current: CanvasTimingProbe?
    public private(set) var milliseconds: [String: Double] = [:]
    public private(set) var counts: [String: Int] = [:]
    private let clock: () -> Double
    public init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    nonisolated public static func recordOnMain(_ stage: String) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { current?.counts[stage, default: 0] += 1 }
    }
    public static func measure<R>(_ stage: String, _ operation: () throws -> R) rethrows -> R {
        guard let probe = current else { return try operation() }
        probe.counts[stage, default: 0] += 1
        let start = probe.clock()
        defer { probe.milliseconds[stage, default: 0] += (probe.clock() - start) * 1_000 }
        return try operation()
    }
}

/// Selection belongs to editing, independently of view transforms and gestures.
public struct CanvasSelection: Equatable, Sendable {
    public var cells: Set<CanvasCellSelection> = []
    public var layerIDs: Set<UUID> = []
    /// Selected surfaces and the assignment whose axis is shown. Part of the selection so that Undo restores them.
    public var surfaceIDs: Set<UUID> = []
    public var routingID: UUID?
    public var anchor: PolarMetricGridCell?
    public init(cells: Set<CanvasCellSelection> = [], anchor: PolarMetricGridCell? = nil) {
        self.cells = cells; self.anchor = anchor
    }
    public func effectiveLayerIDs(activeLayerID: UUID) -> Set<UUID> {
        let ids = layerIDs.isEmpty ? Set(cells.map(\.layerID)) : layerIDs
        return ids.isEmpty ? [activeLayerID] : ids
    }
}

public struct CanvasFeedback: Equatable, Sendable {
    public var status: String?
    public var clipboard: [CanvasCellCopy] = []
    public var contextCell: PolarMetricGridCell?
    public var hitBoundary = false
    var coalescingKey: String?
    var coalescingID: UUID?
    public init() {}
}

/// A view value may be copied for calculation, but never enters history.
public struct CanvasViewState: Equatable, Sendable {
    public var viewport: MetricCanvasViewport = .instrumentDefault
    public var mirrored = false
    public var anchored = true
    public var canvasSize = CGSize.zero
    public var deferredSize: CGSize?
    public var tool: MetricCanvasTool = .select
    public var handHeld = false
    public var mergeZones = true
    public var showRawScan = false
    public var clickSelectsArea = false
    public init() {}
}

@MainActor public final class CanvasViewport: ObservableObject {
    @Published public private(set) var state = CanvasViewState()
    public var pendingLegacyViewport: ScanPlaneViewport?
    public init() {}
    func update(_ value: CanvasViewState) {
        guard state != value else { return }
        state = value
    }
}

/// The only outbound authoring result. Rejected commands never replace live
/// view/gesture owners; the document owner validates before installing it.
public struct CanvasDocumentCommand: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let before: SpatialInstrumentWorkspace
    public let after: SpatialInstrumentWorkspace
    public let selection: CanvasSelection
    public let coalescingKey: String?
    public init(id: UUID = UUID(), name: String, before: SpatialInstrumentWorkspace,
                after: SpatialInstrumentWorkspace, selection: CanvasSelection, coalescingKey: String? = nil) {
        self.id = id; self.name = name; self.before = before; self.after = after
        self.selection = selection; self.coalescingKey = coalescingKey
    }
}

/// Immutable, narrow input to inspectors. Intent closures run against the
/// current session, never against a stored inspector snapshot.
public struct CanvasInspectorPresentation: Equatable, Sendable {
    public var workspace: SpatialInstrumentWorkspace
    public var selection: CanvasSelection
    public var locked: Bool
    public init(workspace: SpatialInstrumentWorkspace, selection: CanvasSelection, locked: Bool) {
        self.workspace = workspace; self.selection = selection; self.locked = locked
    }
    public var interaction: MetricCanvasInteractionState {
        var result = MetricCanvasInteractionState()
        result.projectWorkspace(workspace)
        result.selection = selection
        result.isPerformanceLocked = locked
        return result
    }
}

/// Document-only input to the layer list, without selection or gestures.
public struct CanvasLayerListPresentation: Equatable, Sendable {
    public let layers: [SpatialInstrumentLayer]
    public let scenes: [SpatialScene]
    fileprivate init(_ workspace: SpatialInstrumentWorkspace) {
        layers = workspace.layers; scenes = workspace.scenes
    }
}

@MainActor public final class CanvasLayerListModel: ObservableObject {
    @Published public private(set) var presentation: CanvasLayerListPresentation
    fileprivate init(_ workspace: SpatialInstrumentWorkspace) { presentation = .init(workspace) }
    fileprivate func update(_ workspace: SpatialInstrumentWorkspace) {
        let next = CanvasLayerListPresentation(workspace)
        if next != presentation { presentation = next }
    }
}

/// Per-row selection output; only affected rows publish on a selection.
@MainActor public final class CanvasLayerSelectionModel: ObservableObject {
    @Published public private(set) var selected: Bool
    @Published public private(set) var active: Bool
    fileprivate init(selected: Bool, active: Bool) { self.selected = selected; self.active = active }
    fileprivate func update(selected: Bool, active: Bool) {
        if self.selected != selected { self.selected = selected }
        if self.active != active { self.active = active }
    }
}

@MainActor public final class CanvasInspectorModel: ObservableObject {
    @Published public private(set) var presentation: CanvasInspectorPresentation
    public let layerList: CanvasLayerListModel
    /// Prepare once per changed inspector input, rather than once for every
    /// label, binding and scene control that reads the same snapshot.
    public private(set) var interaction: MetricCanvasInteractionState
    private var layerSelections: [UUID: CanvasLayerSelectionModel] = [:]
    private static func selectedLayers(_ value: CanvasInspectorPresentation) -> Set<UUID> {
        value.selection.effectiveLayerIDs(activeLayerID: value.workspace.selectedLayerID)
    }
    public func layerSelection(for id: UUID) -> CanvasLayerSelectionModel {
        if let existing = layerSelections[id] { return existing }
        let model = CanvasLayerSelectionModel(selected: Self.selectedLayers(presentation).contains(id),
                                               active: presentation.workspace.selectedLayerID == id)
        layerSelections[id] = model
        return model
    }
    public init(_ value: CanvasInspectorPresentation) {
        layerList = CanvasLayerListModel(value.workspace)
        interaction = CanvasTimingProbe.measure("inspector.prepare") { value.interaction }
        presentation = value
    }
    public func update(_ value: CanvasInspectorPresentation) {
        CanvasTimingProbe.measure("inspector.update") {
            guard value != presentation else { return }
            let selected = Self.selectedLayers(value)
            let changed = Self.selectedLayers(presentation).symmetricDifference(selected)
                .union([presentation.workspace.selectedLayerID, value.workspace.selectedLayerID])
            for id in changed {
                layerSelections[id]?.update(selected: selected.contains(id), active: value.workspace.selectedLayerID == id)
            }
            if value.workspace.layers != presentation.workspace.layers {
                let ids = Set(value.workspace.layers.map(\.id))
                layerSelections = layerSelections.filter { ids.contains($0.key) }
            }
            layerList.update(value.workspace)
            interaction = CanvasTimingProbe.measure("inspector.prepare") { value.interaction }
            presentation = value
        }
    }
}

/// Composition owner for editor UI only. Document history and Runtime are
/// reached solely through onCommand. Pointer movement publishes only here.
@MainActor @dynamicMemberLookup public final class CanvasSession: ObservableObject {
    public let viewportOwner = CanvasViewport()
    public let inspector: CanvasInspectorModel
    public private(set) var workspace: SpatialInstrumentWorkspace
    public private(set) var selection = CanvasSelection()
    public private(set) var feedback = CanvasFeedback()
    public private(set) var gesture = CanvasGestureController()
    public private(set) var isPerformanceLocked = false
    @Published public private(set) var auditionPoint: MetricScanPoint?
    @Published public private(set) var showsInactiveSceneLayers = true
    public func setAuditionPoint(_ point: MetricScanPoint?) {
        guard auditionPoint != point else { return }; auditionPoint = point
    }
    public func setShowsInactiveSceneLayers(_ value: Bool) {
        guard showsInactiveSceneLayers != value else { return }; showsInactiveSceneLayers = value
    }
    public let selectionMaximumRadiusMeters: Double
    public var onCommand: ((CanvasDocumentCommand) -> Bool)?
    public var onPitchOperation: ((SpatialPitchOperation) -> Bool)?
    public var onAuthoringAttempt: (() -> Bool)?
    public var onToolChanged: ((MetricCanvasTool) -> Void)?
    public var onPerformanceLockChanged: ((Bool) -> Void)?
    @discardableResult func authorizeAuthoring() -> Bool {
        let allowed = onAuthoringAttempt?() ?? !isPerformanceLocked
        if !allowed {
            perform { $0.statusMessage = InstrumentAction.performanceLockReason }
        }
        return allowed
    }
    // Weak native-field callbacks are registered only for the inspector's
    // lifetime. Flush before selection/save while bindings still own that cell.
    private var numberEdits: [UUID: () -> Void] = [:]
    private var flushingNumberEdits = false
    public func registerNumberEdit(_ id: UUID, commit: @escaping () -> Void) { numberEdits[id] = commit }
    public func unregisterNumberEdit(_ id: UUID) { numberEdits[id] = nil }
    public func commitNumberEdits() {
        guard !flushingNumberEdits else { return }
        flushingNumberEdits = true
        defer { flushingNumberEdits = false }
        for callback in Array(numberEdits.values) { callback() }
    }
    public var programCountingPreference: ((UUID) -> Bool)?
    public var rememberProgramCounting: ((UUID, Bool) -> Void)?
    public var onSelection: ((UUID) -> Void)?
    public init(state: MetricCanvasInteractionState = .init()) {
        workspace = state.workspace; selection = state.selection; feedback = state.feedback
        gesture = state.gesture; isPerformanceLocked = state.isPerformanceLocked
        selectionMaximumRadiusMeters = state.selectionMaximumRadiusMeters
        viewportOwner.update(state.viewState)
        inspector = .init(.init(workspace: workspace, selection: selection, locked: isPerformanceLocked))
    }
    private var cachedPresentation: MetricCanvasInteractionState?
    public var presentation: MetricCanvasInteractionState {
        if let cachedPresentation { return cachedPresentation }
        return CanvasTimingProbe.measure("field.projection") {
            var result = MetricCanvasInteractionState(selectionMaximumRadiusMeters: selectionMaximumRadiusMeters)
            result.projectWorkspace(workspace)
            result.viewState = viewportOwner.state; result.selection = selection
            result.feedback = feedback; result.gesture = gesture
            result.isPerformanceLocked = isPerformanceLocked
            cachedPresentation = result
            return result
        }
    }
    public var mergeZones: Bool {
        get { viewportOwner.state.mergeZones }
        set { perform { $0.mergeZones = newValue } }
    }
    public var showRawScan: Bool {
        get { viewportOwner.state.showRawScan }
        set { perform { $0.showRawScan = newValue } }
    }
    public subscript<T>(dynamicMember path: KeyPath<MetricCanvasInteractionState, T>) -> T { presentation[keyPath: path] }
    /// The explicit mode boundary is the only writer of the live permission.
    /// Generic presentation snapshots cannot restore an old Edit/Perform mode.
    public func setPerformanceLocked(_ locked: Bool) {
        guard locked != isPerformanceLocked else { return }
        perform({
            $0.setPerformanceLocked(locked)
            if $0.statusMessage == InstrumentAction.performanceLockReason { $0.statusMessage = nil }
        }, changesPerformanceLock: true)
        onPerformanceLockChanged?(locked)
    }
    @discardableResult public func perform<R>(_ intent: (inout MetricCanvasInteractionState) -> R) -> R {
        perform(intent, changesPerformanceLock: false)
    }
    @discardableResult private func perform<R>(_ intent: (inout MetricCanvasInteractionState) -> R,
                                              changesPerformanceLock: Bool) -> R {
        var calculation = CanvasTimingProbe.measure("session.presentation") { presentation }
        let result = CanvasTimingProbe.measure("session.intent") { intent(&calculation) }
        if !changesPerformanceLock { calculation.isPerformanceLocked = isPerformanceLocked }
        guard calculation.command != nil || calculation.workspace != workspace || calculation.selection != selection
            || calculation.viewState != viewportOwner.state || calculation.gesture != gesture
            || calculation.feedback != feedback || calculation.isPerformanceLocked != isPerformanceLocked
        else { return result }
        let inspectionChanged = calculation.command != nil || calculation.selection != selection
            || calculation.isPerformanceLocked != isPerformanceLocked
            || calculation.workspace.selectedLayerID != workspace.selectedLayerID
        let selectedLayerChanged = calculation.workspace.selectedLayerID != workspace.selectedLayerID
        let previousTool: MetricCanvasTool = viewportOwner.state.handHeld ? .pan : viewportOwner.state.tool
        let toolChanged = calculation.effectiveTool != previousTool
        cachedPresentation = nil
        objectWillChange.send()
        viewportOwner.update(calculation.viewState)
        gesture = calculation.gesture; feedback = calculation.feedback
        isPerformanceLocked = calculation.isPerformanceLocked
        if let command = calculation.command {
            let accepted = CanvasTimingProbe.measure("session.onCommand") { onCommand?(command) ?? true }
            if accepted {
                if onCommand == nil { workspace = calculation.workspace }
                selection = calculation.selection
            }
            else { gesture = .init(); feedback.status = "Document edit rejected" }
        } else {
            workspace = calculation.workspace; selection = calculation.selection
            if selectedLayerChanged { CanvasTimingProbe.measure("session.onSelection") { onSelection?(workspace.selectedLayerID) } }
        }
        cachedPresentation = nil
        if toolChanged { onToolChanged?(calculation.effectiveTool) }
        if inspectionChanged { inspector.update(.init(workspace: workspace, selection: selection, locked: isPerformanceLocked)) }
        return result
    }
    public func projectWorkspace(_ value: SpatialInstrumentWorkspace, selection restored: CanvasSelection? = nil) {
        guard value != workspace || (restored != nil && restored != selection) else { return }
        if value != workspace, gesture.phase != .idle { discardGestureForHistory() }
        let selectionDomainChanged = value.grid != workspace.grid || value.layers.count != workspace.layers.count ||
            !zip(value.layers, workspace.layers).allSatisfy { next, old in
                next.id == old.id && next.isVisible == old.isVisible && next.isLocked == old.isLocked && next.polarCells == old.polarCells
            }
        cachedPresentation = nil
        objectWillChange.send()
        workspace = value
        if let restored { selection = restored }
        if selectionDomainChanged || restored != nil {
            CanvasTimingProbe.measure("session.filterSelection") {
                let layers = Dictionary(uniqueKeysWithValues: value.layers.map { ($0.id, $0) })
                selection.layerIDs.formIntersection(layers.keys)
                selection.cells = selection.cells.filter { pair in
                    guard let layer = layers[pair.layerID] else { return false }
                    return layer.isVisible && !layer.isLocked && layer.polarCells.contains(pair.cell)
                }
            }
        }
        // A synchronous willChange subscriber may have read the old value.
        // Retire that read after all projection fields have been installed.
        cachedPresentation = nil
        inspector.update(.init(workspace: workspace, selection: selection, locked: isPerformanceLocked))
    }
    public func cancelGesture() {
        guard gesture.phase != .idle else { return }
        perform { _ = $0.handleKey(.escape) }
    }
    public func discardGestureForHistory() { perform { $0.discardGesture() } }
    public func send(_ input: CanvasGestureController.Input, canvasSize: CGSize) {
        perform { context in
            var controller = context.gesture
            controller.reduce(input, canvasSize: canvasSize, context: &context)
        }
    }
}
