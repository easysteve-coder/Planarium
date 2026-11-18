/// The single execution order, including the historic whole-ray smoothing
/// path when Core is off. UI module order is deliberately independent.
public enum DetectionStagePlan {
    public enum Operation: Equatable, Sendable {
        case room, time, beams, groups, edge, angularSeparation, core, representative, cells
    }
    private static let wholeRayOrder: [Operation] = [.room, .time, .beams, .groups, .edge, .angularSeparation, .core, .representative, .cells]
    private static let coreOrder: [Operation] = [.room, .beams, .groups, .edge, .angularSeparation, .core, .time, .representative, .cells]
    public static func operations(configuration: DetectionConfiguration) -> [Operation] {
        if configuration.core.coreWidthCentimeters == 0 {
            return wholeRayOrder
        }
        return coreOrder
    }
}
