import PlanariumDomain
import Foundation

public extension SpatialAssignmentDraft {
    static func current(in state: MetricCanvasInteractionState) -> Self {
        let routing = state.workspace.selectedLayer.routings.first
            ?? SpatialRouting(target: .midiNote(channel: 0), program: .constant(0))
        var draft = from(program: routing.program, target: routing.target)
        if draft.kind == .chord, let root = routing.chordRootMIDINote { draft.rootMIDINote = root }
        return draft
    }
}

public struct SpatialPendingAssignment: Equatable, Sendable {
    public var draft: SpatialAssignmentDraft
    public let baseline: SpatialAssignmentDraft

    public init(draft: SpatialAssignmentDraft, baseline: SpatialAssignmentDraft) {
        self.draft = draft
        self.baseline = baseline
    }

    public static func visibleDraft(
        pending: SpatialPendingAssignment?,
        in state: MetricCanvasInteractionState
    ) -> SpatialAssignmentDraft {
        let current = SpatialAssignmentDraft.current(in: state)
        guard let pending, pending.baseline == current else { return current }
        return pending.draft
    }
}

public enum SpatialAssignmentApplyDecision: Equatable {
    case allowed
    case unchanged
    case notAllowed
}

public extension MetricCanvasInteractionState {
    func assignmentApplyDecision(for draft: SpatialAssignmentDraft) -> SpatialAssignmentApplyDecision {
        let layer = workspace.selectedLayer
        guard !layer.isLocked, !layer.routings.isEmpty else { return .notAllowed }
        let current = SpatialAssignmentDraft.current(in: self)
        return current == draft ? .unchanged : .allowed
    }

    @discardableResult
    mutating func applyAssignment(_ draft: SpatialAssignmentDraft) -> Bool {
        guard assignmentApplyDecision(for: draft) == .allowed else { return false }
        let program = SpatialAssignmentDraft.program(from: draft)
        return performEdit(named: "Change assignment") { state in
            state.updateWorkspace { workspace in
                workspace.updateSelectedLayer { layer in
                    guard !layer.routings.isEmpty else { return }
                    layer.routings[0].target = draft.target
                    layer.routings[0].program = program
                    layer.routings[0].chordRootMIDINote = draft.kind == .chord && draft.chordNotes.min() != draft.rootMIDINote ? draft.rootMIDINote : nil
                }
            }
            return true
        }
    }

    @discardableResult
    mutating func rerollAssignmentSeed() -> Bool {
        guard !workspace.selectedLayer.isLocked,
              case .randomScale = workspace.selectedLayer.routings.first?.program else { return false }
        var draft = SpatialAssignmentDraft.current(in: self)
        var seed = UInt64.random(in: UInt64.min...UInt64.max)
        if seed == draft.seed { seed &+= 1 }
        draft.seed = seed
        let program = SpatialAssignmentDraft.program(from: draft)
        return performEdit(named: "Randomize again") { state in
            state.updateWorkspace { workspace in
                workspace.updateSelectedLayer { layer in layer.routings[0].program = program }
            }
            return true
        }
    }

    @discardableResult
    mutating func setAssignmentCCNumber(_ number: UInt8) -> Bool {
        guard !workspace.selectedLayer.isLocked,
              let oldTarget = workspace.selectedLayer.routings.first?.target,
              let oldNumber = oldTarget.controllerNumber,
              oldNumber != number else { return false }
        let newTarget = oldTarget.withControllerNumber(number)
        return performEdit(named: "Change CC number") { state in
            state.updateWorkspace { workspace in
                workspace.updateSelectedLayer { layer in
                    guard !layer.routings.isEmpty else { return }
                    layer.routings[0].target = newTarget
                    for (cell, actions) in layer.polarCellOverrides {
                        layer.polarCellOverrides[cell] = actions.map { action in
                            guard action.target == oldTarget else { return action }
                            var changed = action
                            changed.target = newTarget
                            return changed
                        }
                    }
                }
            }
            return true
        }
    }
}
