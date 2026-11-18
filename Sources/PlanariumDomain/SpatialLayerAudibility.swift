import Foundation

/// One mute/solo rule for compilation, evaluation and editor presentation.
/// Visibility deliberately does not participate in the sound policy.
public enum SpatialLayerAudibility {
    public static func audibleIDs(_ layers: [(id: UUID, isActive: Bool, isSoloed: Bool)]) -> Set<UUID> {
        let hasSolo = layers.contains { $0.isActive && $0.isSoloed }
        return Set(layers.filter { $0.isActive && (!hasSolo || $0.isSoloed) }.map(\.id))
    }
}
