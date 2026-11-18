import Foundation
import PLSDeviceValues

/// Räumliche, nicht zeitbasierte Ruhezone der Zellwahl.
public struct SpatialHysteresisConfiguration: Equatable, Sendable {
    public let radialMarginCentimeters: UInt16
    public let angularMarginTicks: Int
    public let switchConfirmationProfiles: Int
    public let continuousBacklashCentimeters: UInt16
    /// Production Snap uses compiled equal-content surfaces, in centimeters.
    /// Nil preserves the low-level fine-lattice hysteresis contract.
    public let snapCentimeters: UInt16?

    /// Offene Grenze aus dem Owner-Review: Das kontinuierliche CC-Totband wirkt nur auf
    /// die radiale Distanz. Seitliche CC-Richtungen werden in einem späteren
    /// Owner-Lauf entschieden.

    public init(
        radialMarginCentimeters: UInt16 = 5,
        angularMarginTicks: Int = 2,
        switchConfirmationProfiles: Int = 2,
        continuousBacklashCentimeters: UInt16 = 2,
        snapCentimeters: UInt16? = nil
    ) {
        self.radialMarginCentimeters = min(radialMarginCentimeters, 20)
        self.angularMarginTicks = min(max(angularMarginTicks, 0), 10)
        self.switchConfirmationProfiles = min(max(switchConfirmationProfiles, 1), 4)
        self.continuousBacklashCentimeters = min(continuousBacklashCentimeters, 5)
        self.snapCentimeters = snapCentimeters.map { min($0, 10) }
    }

    public static let disabled = SpatialHysteresisConfiguration(
        radialMarginCentimeters: 0,
        angularMarginTicks: 0,
        switchConfirmationProfiles: 1,
        continuousBacklashCentimeters: 0
    )
}
