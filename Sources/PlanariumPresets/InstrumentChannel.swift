import Foundation

public enum InstrumentChannelID: String, Codable, Equatable, Hashable, Sendable { case primary }

public struct InstrumentChannelSettings: Codable, Equatable, Sendable {
    public let id: InstrumentChannelID
    public let pan: Float
    public init(id: InstrumentChannelID, pan: Float) {
        self.id = id; self.pan = min(max(pan, -1), 1)
    }
    public static let primary = InstrumentChannelSettings(id: .primary, pan: 0)
}
