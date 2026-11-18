/// Eine validierte, inklusive Spanne von Geräte-Ticks.
public struct DeviceTickSpan: Equatable, Hashable, Sendable {
    public let lower: Int
    public let upper: Int

    public init?(lower: Int, upper: Int) {
        guard lower >= 0, lower <= upper, upper <= PolarDeviceLattice.maxTick else { return nil }
        self.lower = lower
        self.upper = upper
    }

    public static func point(_ tick: Int) -> DeviceTickSpan? {
        Self(lower: tick, upper: tick)
    }
}

/// Ein Profiltreffer mit seiner Empfangsreihenfolge und der bereits geprüften
/// Rohdistanz. Die Spanne behauptet keine physische Winkelposition.
public struct DeviceTickMeasurement: Equatable, Sendable {
    public let order: Int
    public let ticks: DeviceTickSpan
    public let rawCentimeters: UInt16

    public init?(order: Int, ticks: DeviceTickSpan, rawCentimeters: UInt16) {
        guard order >= 0, UsableRawDistance.contains(rawCentimeters) else { return nil }
        self.order = order
        self.ticks = ticks
        self.rawCentimeters = rawCentimeters
    }

}
