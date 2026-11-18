import Foundation
import PlanariumDomain

public struct SpatialSceneChoice: Equatable, Identifiable, Sendable {
    public var id: SpatialSceneSwitchAction { action }
    public let action: SpatialSceneSwitchAction
    public let title: String
    public let isSelected: Bool
}

public enum SpatialScenePresentation {
    public static let outputTitles = ["No output", "AU instrument", "MIDI", "Scene switch", "Release layer"]
    public static func name(_ action: SpatialSceneSwitchAction, scenes: [SpatialScene]) -> String {
        switch action {
        case .next: return "Next"
        case .previous: return "Previous"
        case .scene(let id): return scenes.first { $0.id == id }?.name ?? "missing scene"
        }
    }
    public static func action(cell: PolarMetricGridCell, in state: MetricCanvasInteractionState) -> SpatialSceneSwitchAction? {
        action(cell: cell, layer: state.workspace.selectedLayer)
    }
    public static func action(cell: PolarMetricGridCell, layer: SpatialInstrumentLayer) -> SpatialSceneSwitchAction? {
        guard let target = layer.routings.first?.target,
              case .sceneSwitch(let fallback, _) = target else { return nil }
        for action in layer.polarCellOverrides[cell] ?? [] where action.target == target {
            if case .sceneSwitch(let own) = action.value { return own }
        }
        return fallback
    }
    public static func choices(in state: MetricCanvasInteractionState, layerOnly: Bool = false) -> [SpatialSceneChoice] {
        guard case .sceneSwitch(let fallback, _) = state.workspace.selectedLayer.routings.first?.target else { return [] }
        let actions = layerOnly || state.selectedPolarCells.isEmpty ? [fallback] : state.selectedPolarCells.compactMap { action(cell: $0, in: state) }
        return ([SpatialSceneSwitchAction.next, .previous] + state.workspace.scenes.map { .scene($0.id) }).map { choice in
            .init(action: choice, title: name(choice, scenes: state.workspace.scenes),
                  isSelected: !actions.isEmpty && actions.allSatisfy { $0 == choice })
        }
    }
    public static func selectionTitle(in state: MetricCanvasInteractionState) -> String {
        guard case .sceneSwitch(let fallback, _) = state.workspace.selectedLayer.routings.first?.target else { return "—" }
        let values = state.selectedPolarCells.isEmpty ? [fallback] : state.selectedPolarCells.compactMap { action(cell: $0, in: state) }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return "Mixed" }
        return name(first, scenes: state.workspace.scenes)
    }
}

public enum SpatialReleaseLayerPresentation {
    public static func name(_ id: UUID, workspace: SpatialInstrumentWorkspace) -> String {
        workspace.layers.first { $0.id == id }?.name ?? "missing layer"
    }
    public static func target(cell: PolarMetricGridCell, layer: SpatialInstrumentLayer) -> UUID? {
        guard let target = layer.routings.first?.target, case .releaseLayer(let fallback) = target else { return nil }
        for action in layer.polarCellOverrides[cell] ?? [] where action.target == target {
            if case .releaseLayer(let own) = action.value { return own }
        }
        return fallback
    }
    public static func selectionTitle(in state: MetricCanvasInteractionState) -> String {
        guard case .releaseLayer(let fallback) = state.workspace.selectedLayer.routings.first?.target else { return "—" }
        let ids = state.selectedPolarCells.isEmpty ? [fallback] : state.selectedPolarCells.compactMap { target(cell: $0, layer: state.workspace.selectedLayer) }
        guard let first = ids.first, ids.allSatisfy({ $0 == first }) else { return "Mixed" }
        return name(first, workspace: state.workspace)
    }
}

public extension MetricCanvasInteractionState {
    @discardableResult mutating func setReleaseLayerTarget(_ id: UUID, layerOnly: Bool = false) -> Bool {
        guard !isPerformanceLocked, !workspace.selectedLayer.isLocked,
              let routing = workspace.selectedLayer.routings.first,
              case .releaseLayer = routing.target else { return false }
        if !layerOnly && !selectedPolarCells.isEmpty {
            if case .success(.applied) = applyToSelection(.setAction(.init(target: routing.target, value: .releaseLayer(layerID: id)))) { return true }
            return false
        }
        return setSelectedLayerTarget(.releaseLayer(layerID: id), program: .constant(1))
    }
    @discardableResult mutating func setSceneAction(_ action: SpatialSceneSwitchAction, layerOnly: Bool = false) -> Bool {
        guard !isPerformanceLocked, !workspace.selectedLayer.isLocked,
              let routing = workspace.selectedLayer.routings.first,
              case .sceneSwitch(_, let dwell) = routing.target else { return false }
        if !layerOnly && !selectedPolarCells.isEmpty {
            if case .success(.applied) = applyToSelection(.setAction(.init(target: routing.target, value: .sceneSwitch(action: action)))) { return true }
            return false
        }
        return setSelectedLayerTarget(.sceneSwitch(action: action, dwellSeconds: dwell), program: routing.program)
    }
    @discardableResult mutating func resetSelectedCellsToLayer() -> Bool {
        guard !isPerformanceLocked, let target = workspace.selectedLayer.routings.first?.target else { return false }
        if case .success(.applied) = applyToSelection(.removeActions(target: target)) { return true }
        return false
    }
}
