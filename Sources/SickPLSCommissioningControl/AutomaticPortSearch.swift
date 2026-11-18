import SickPLSCommissioning

/// Sichtbarer Fortschritt der ausdrücklich gestarteten, sequenziellen
/// Portsuche. Der Text entsteht im Modell und nicht in SwiftUI.
public struct AutomaticPortSearchProgress: Equatable, Sendable {
    public let portPath: String
    public let candidateNumber: Int
    public let candidateCount: Int

    public var operatorText: String {
        "Searching for scanner (\(candidateNumber)/\(candidateCount)): \(portPath)"
    }
}

/// Redigiertes Ergebnis eines bereits abgeschlossenen Kandidaten.
public struct AutomaticPortSearchAttempt: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        case ready
        case failed(StandardConnectionFailure)
        case runUnavailable(CommissioningRunUnavailableReason)
    }

    public let portPath: String
    public let result: Result
}
