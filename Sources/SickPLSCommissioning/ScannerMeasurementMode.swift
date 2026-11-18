import SickPLSCore
import SickPLSActiveControl

/// Documented continuous modes; telegram construction stays at the device boundary.
public enum ScannerMeasurementMode: String, CaseIterable, Codable, Sendable {
    case mmk, fullScan
    public var pointCount: Int { self == .mmk ? 90 : 361 }
    public var title: String { self == .mmk ? "MMK 90" : "Full scan 361" }
    public var commandByte: UInt8 { self == .mmk ? 0x20 : 0x24 }
    public func accepts(pointCount: Int) -> Bool { pointCount == self.pointCount }
    public func telegram(address: ConfirmedTargetAddress) -> Frame {
        try! Frame.build(address: address.rawValue, payload: [0x20, commandByte])
    }
    public func matches(_ frame: Frame) -> Bool {
        guard case .success(let profile) = B0ScanProfile.decode(from: frame.payload) else { return false }
        return accepts(pointCount: profile.measurements.count)
    }
}
