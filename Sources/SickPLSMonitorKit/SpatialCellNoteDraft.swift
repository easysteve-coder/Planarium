import PlanariumDomain
import Foundation

public enum SpatialCellNoteSource: Equatable, Sendable {
    case cellOverride
    case layerValue
}

public struct SpatialCellNoteDraft: Equatable, Sendable {
    public var notes: Set<Int>
    public var velocity: UInt8
    public let source: SpatialCellNoteSource

    public static func current(
        cell: PolarMetricGridCell,
        in state: MetricCanvasInteractionState
    ) -> SpatialCellNoteDraft? {
        let layer = state.workspace.selectedLayer
        guard layer.polarCells.contains(cell),
              let routing = layer.routings.first,
              isNoteTarget(routing.target) else { return nil }

        let source: SpatialCellNoteSource
        let value: SpatialCellValue?
        if let action = (layer.polarCellOverrides[cell] ?? []).first(where: { $0.target == routing.target }) {
            source = .cellOverride
            value = action.value
        } else {
            source = .layerValue
            value = nil
        }

        if let value {
            switch value {
            case .note(let number, let velocity):
                return Self(notes: [number], velocity: velocity, source: source)
            case .chord(let notes, let velocity):
                return Self(notes: Set(notes), velocity: velocity, source: source)
            case .scalar, .boolean, .sceneSwitch, .releaseLayer, .programChange:
                return nil
            }
        }

        guard let evaluated = SpatialInstrumentEvaluator().cellValues(
            layerID: layer.id, cells: [cell], workspace: state.workspace
        )[cell], case .notes(let played, _) = evaluated, !played.isEmpty else {
            return nil
        }
        return Self(
            notes: Set(played.map { Int($0.number) }),
            velocity: played.map(\.velocity).min() ?? 100,
            source: .layerValue
        )
    }

    private static func isNoteTarget(_ target: SpatialRoutingTarget) -> Bool {
        switch target {
        case .midiNote, .audioUnitNote: return true
        case .midiEffectParameter, .audioUnitParameter, .audioUnitAllNotesOff, .sceneSwitch, .releaseLayer, .midiCC, .audioUnitCC, .midiProgramChange, .audioUnitProgramChange, .midiPitchBend, .audioUnitPitchBend,
             .midiChannelPressure, .audioUnitChannelPressure, .midiAllNotesOff, .boolean:
            return false
        }
    }
}

public extension MetricCanvasInteractionState {
    @discardableResult
    mutating func applyCellNotes(
        _ draft: SpatialCellNoteDraft,
        cell: PolarMetricGridCell
    ) -> Bool {
        guard !draft.notes.isEmpty,
              let layer = workspace.layers.first(where: { $0.id == workspace.selectedLayerID }),
              layer.polarCells.contains(cell),
              !layer.isLocked,
              let routing = layer.routings.first,
              Self.isNoteTarget(routing.target) else { return false }

        let value: SpatialCellValue = draft.notes.count == 1
            ? .note(number: draft.notes.first ?? 0, velocity: draft.velocity)
            : .chord(notes: draft.notes.sorted(), velocity: draft.velocity)
        if case .success(.applied) = applyToSelection(.setAction(.init(target: routing.target, value: value))) { return true }
        return false
    }

    private static func isNoteTarget(_ target: SpatialRoutingTarget) -> Bool {
        switch target {
        case .midiNote, .audioUnitNote: return true
        case .midiEffectParameter, .audioUnitParameter, .audioUnitAllNotesOff, .sceneSwitch, .releaseLayer, .midiCC, .audioUnitCC, .midiProgramChange, .audioUnitProgramChange, .midiPitchBend, .audioUnitPitchBend,
             .midiChannelPressure, .audioUnitChannelPressure, .midiAllNotesOff, .boolean:
            return false
        }
    }
}
