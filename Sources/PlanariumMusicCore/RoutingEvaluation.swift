import Foundation

public struct SpatialPlayedNote: Hashable, Sendable {
    public let number: UInt8
    public let velocity: UInt8

    public init(number: UInt8, velocity: UInt8) {
        self.number = min(number, 127)
        self.velocity = min(velocity, 127)
    }
}

public enum SpatialEvaluatedValue: Equatable, Sendable {
    case programChange(SpatialProgramChange)
    case inactive
    case notes(Set<SpatialPlayedNote>, transition: SpatialNoteTransition)
    case scalar(Double)
    case boolean(Bool)
}

/// The identity a source gives one measured activation (a scanner cell, a
/// controller element or zone). The ledger only compares and hashes it; the
/// one geometric question it asks is answered by the source.
public protocol LedgerCell: Hashable, Sendable {
    /// A Hold-until-next owner left at `previous`; does a measured entry at
    /// `self` continue the same contact (a neighbour within one hand width),
    /// so it may be exposed as the next musical entry?
    func continuesContact(from previous: Self) -> Bool
}

/// Toggle debounce bounds shared by every source.
public enum ToggleGuard {
    public static let defaultSeconds = 0.5
    public static func normalized(_ seconds: Double) -> Double {
        seconds.isFinite ? min(2, max(0, seconds)) : 0
    }
}

public struct RoutingEvaluation<Cell: LedgerCell>: Equatable, Sendable {
    /// Measured representative priority; geometry stays outside the ledger.
    public var displayCell: Cell?
    public var representativeDistanceSquared: Double = .infinity
    public var midiDestination: SpatialOutputDestination = .midi
    public let routingID: UUID
    public let target: SpatialRoutingTarget
    public let value: SpatialEvaluatedValue
    /// Toggle entry identity: the compiled anchor of a painted surface,
    /// shared by its fine segments. Hold carries its measured sounding cell.
    public let cell: Cell?
    public let commonNotes: SpatialCommonNotes
    public let toggleGuardSeconds: Double

    public init(routingID: UUID, target: SpatialRoutingTarget, value: SpatialEvaluatedValue, cell: Cell? = nil,
                toggleGuardSeconds: Double = 0, commonNotes: SpatialCommonNotes = .keep) {
        self.routingID = routingID
        self.target = target
        self.value = value
        self.cell = cell
        self.commonNotes = commonNotes
        self.toggleGuardSeconds = ToggleGuard.normalized(toggleGuardSeconds)
    }
}

