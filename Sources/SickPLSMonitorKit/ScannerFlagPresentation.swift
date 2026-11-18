import SickPLSCore

/// Raw three-bit counts, including non-projectable distances. No field
/// semantics and no detection or instrument configuration.
public struct ScannerFlagPresentation: Equatable, Sendable {
    public static let values = Array(UInt8(0)...UInt8(7))
    public let counts: [Int]
    public init(profile: B0ScanProfile?) {
        var counts = Array(repeating: 0, count: 8)
        for measurement in profile?.measurements ?? [] { counts[Int(measurement.fieldFlags)] += 1 }
        self.counts = counts
    }
    public static func label(_ flag: UInt8) -> String { "flag \(flag)" }
    public static func paletteIndex(_ measurement: ProjectedScanMeasurement) -> Int { Int(measurement.fieldFlags) }
}
