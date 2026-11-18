import Foundation

/// Measured live values in entry order. Owned by the pure engine on Q.
public struct ArpeggiatorModulationState: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var routingID: UUID
        var target: SpatialRoutingTarget
        var value: Double
    }
    private var entries: [Entry] = []
    public init() {}
    public var values: [SpatialRoutingTarget: Double] {
        var result: [SpatialRoutingTarget: Double] = [:]
        for entry in entries { result[entry.target] = entry.value }
        return result
    }
    mutating func update(_ evaluations: [SpatialRoutingEvaluation]) {
        let active = evaluations.filter {
            guard case .midiEffectParameter = $0.target, case .scalar = $0.value else { return false }
            return true
        }
        entries.removeAll { entry in !active.contains { $0.routingID == entry.routingID && $0.target == entry.target } }
        for evaluation in active {
            guard case .scalar(let scalar) = evaluation.value,
                  case .midiEffectParameter(_, _, let parameter) = evaluation.target else { continue }
            let index = entries.firstIndex { $0.routingID == evaluation.routingID }
            var effect = ArpeggiatorEffect()
            let value = parameter.apply(scalar, to: &effect, previous: index.map { entries[$0].value })
            if let index { entries[index].value = value }
            else { entries.append(.init(routingID: evaluation.routingID, target: evaluation.target, value: value)) }
        }
    }
    mutating func retain(routings: [CompiledRoutingPlan]) {
        let targets = Dictionary(uniqueKeysWithValues: routings.map { ($0.id, $0.target) })
        entries.removeAll { targets[$0.routingID] != $0.target }
    }
    public func applying(to editor: ArpeggiatorEffect, stripID: UUID, slotID: UUID) -> ArpeggiatorEffect {
        var result = editor
        for (target, value) in values {
            guard case .midiEffectParameter(let strip, let slot, let parameter) = target,
                  strip == stripID, slot == slotID else { continue }
            switch parameter {
            case .rate: result.rate = ArpeggiatorEffect.Rate.allCases[Int(value)]
            case .octaves: result.octaves = Int(value)
            case .gate: result.gate = value
            case .swing: result.swing = value
            case .velocity: result.velocity = Int(value)
            }
        }
        return result
    }
}
