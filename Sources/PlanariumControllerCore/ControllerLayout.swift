import Foundation
import PlanariumMusicCore

/// Which part of an element an assignment listens to.
public enum ControllerZone: Codable, Hashable, Sendable {
    /// The whole element: a pressed button, a trigger beyond its threshold, a
    /// stick or touch beyond the rest radius.
    case whole
    /// One of `count` equal sectors of a stick or the touchpad, clockwise from
    /// straight up; sector 0 is centred on up.
    case sector(index: Int, count: Int)

    public var isValid: Bool {
        switch self {
        case .whole: return true
        case let .sector(index, count): return (2...16).contains(count) && (0..<count).contains(index)
        }
    }
}

/// One colored assignment of a controller element to a sound target, in place
/// of a painted layer. The routing (target and value program) is the same type
/// the scanner layers use.
public struct ControllerAssignment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var color: SpatialLayerColor
    public var element: ControllerElement
    public var zone: ControllerZone
    public var routing: SpatialRouting
    /// Explicit CoreMIDI output for MIDI targets; nil uses the sum output.
    public var midiEndpointID: Int32?
    public var isActive: Bool

    public init(id: UUID = UUID(), name: String, color: SpatialLayerColor, element: ControllerElement,
                zone: ControllerZone = .whole, routing: SpatialRouting, midiEndpointID: Int32? = nil, isActive: Bool = true) {
        self.id = id; self.name = name; self.color = color; self.element = element
        self.zone = zone; self.routing = routing; self.midiEndpointID = midiEndpointID; self.isActive = isActive
    }
}

/// The controller part of an instrument: its assignments and playing feel.
public struct ControllerLayout: Codable, Equatable, Sendable {
    public var assignments: [ControllerAssignment]
    /// A stick or touch counts as played beyond this radius…
    public var enterRadius: Double
    /// …and keeps playing until it falls below this one.
    public var exitRadius: Double
    /// A trigger counts as pressed beyond this value and is released below half of it.
    public var triggerThreshold: Double
    /// A sector is left only this many degrees past its border (no flutter).
    public var sectorHysteresisDegrees: Double

    public init(assignments: [ControllerAssignment] = [], enterRadius: Double = 0.4, exitRadius: Double = 0.3,
                triggerThreshold: Double = 0.12, sectorHysteresisDegrees: Double = 8) {
        self.assignments = assignments; self.enterRadius = enterRadius; self.exitRadius = exitRadius
        self.triggerThreshold = triggerThreshold; self.sectorHysteresisDegrees = sectorHysteresisDegrees
    }

    public static let empty = ControllerLayout()

    private enum CodingKeys: String, CodingKey { case assignments, enterRadius, exitRadius, triggerThreshold, sectorHysteresisDegrees }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ControllerLayout()
        self.init(assignments: try values.decodeIfPresent([ControllerAssignment].self, forKey: .assignments) ?? [],
                  enterRadius: try values.decodeIfPresent(Double.self, forKey: .enterRadius) ?? fallback.enterRadius,
                  exitRadius: try values.decodeIfPresent(Double.self, forKey: .exitRadius) ?? fallback.exitRadius,
                  triggerThreshold: try values.decodeIfPresent(Double.self, forKey: .triggerThreshold) ?? fallback.triggerThreshold,
                  sectorHysteresisDegrees: try values.decodeIfPresent(Double.self, forKey: .sectorHysteresisDegrees) ?? fallback.sectorHysteresisDegrees)
    }

    /// Every sound target an assignment claims, for the exclusive ownership check.
    public func claims(source: PlayingSourceID, sumEndpoint: Int32?) -> [(assignmentID: UUID, claim: OutputClaim)] {
        assignments.filter(\.isActive).compactMap { assignment in
            guard let outputClass = OutputOwnership.outputClass(of: assignment.routing.target),
                  let key = OutputOwnership.key(of: assignment.routing.target, midiEndpoint: assignment.midiEndpointID, sumEndpoint: sumEndpoint)
            else { return nil }
            return (assignment.id, OutputClaim(source: source, target: key, outputClass: outputClass))
        }
    }
}

public enum ControllerLayoutError: Error, Equatable, Sendable {
    case invalidZone(assignmentID: UUID)
    case zoneNeedsPositionalElement(assignmentID: UUID)
    case nonFiniteValue(assignmentID: UUID)
    case duplicateRoutingID(UUID)
    case invalidFeel
    /// The program cannot play on this target (e.g. a program change on a
    /// controller target), or the target is not playable from a controller.
    case unsupportedTarget(assignmentID: UUID)
    /// Channel, controller, note or velocity outside the MIDI range.
    case invalidNumber(assignmentID: UUID)
}

/// A validated layout, ready for the engine. Assignments whose target another
/// source owns in the same class are kept out and reported, never silently
/// shared.
public struct CompiledControllerLayout: Equatable, Sendable {
    public let source: PlayingSourceID
    public let layout: ControllerLayout
    public let playable: [ControllerAssignment]
    public let conflicts: [UUID: OutputConflict]
    /// Sound targets this source owns per class, for a source-local release.
    public let ownedTargets: [OutputClass: Set<OutputTargetKey>]
    public let sumEndpoint: Int32?

    /// `established` are the claims of sources that already own their targets
    /// (the scanner instrument); they win every conflict.
    public init(_ layout: ControllerLayout, source: PlayingSourceID, sumEndpoint: Int32?,
                established: [OutputClaim] = []) throws {
        guard layout.exitRadius > 0, layout.enterRadius >= layout.exitRadius, layout.enterRadius < 1,
              layout.triggerThreshold > 0, layout.triggerThreshold < 1,
              (0...45).contains(layout.sectorHysteresisDegrees) else { throw ControllerLayoutError.invalidFeel }
        var routingIDs = Set<UUID>()
        for assignment in layout.assignments {
            guard assignment.zone.isValid else { throw ControllerLayoutError.invalidZone(assignmentID: assignment.id) }
            if case .sector = assignment.zone, !assignment.element.isPositional {
                throw ControllerLayoutError.zoneNeedsPositionalElement(assignmentID: assignment.id)
            }
            guard routingIDs.insert(assignment.routing.id).inserted else {
                throw ControllerLayoutError.duplicateRoutingID(assignment.routing.id)
            }
            guard Self.isFinite(assignment.routing.program) else { throw ControllerLayoutError.nonFiniteValue(assignmentID: assignment.id) }
            guard Self.fits(assignment.routing.program, assignment.routing.target) else {
                throw ControllerLayoutError.unsupportedTarget(assignmentID: assignment.id)
            }
            guard Self.inRange(assignment.routing) else { throw ControllerLayoutError.invalidNumber(assignmentID: assignment.id) }
        }
        let own = layout.claims(source: source, sumEndpoint: sumEndpoint)
        let found = OutputOwnership.conflicts(established + own.map(\.claim))
        var conflicts: [UUID: OutputConflict] = [:]
        for (id, claim) in own {
            if let conflict = found.first(where: { $0.rejected == source && $0.target == claim.target && $0.outputClass == claim.outputClass }) {
                conflicts[id] = conflict
            }
        }
        self.source = source
        self.layout = layout
        self.sumEndpoint = sumEndpoint
        self.conflicts = conflicts
        playable = layout.assignments.filter { $0.isActive && conflicts[$0.id] == nil }
        var owned: [OutputClass: Set<OutputTargetKey>] = [:]
        for (id, claim) in own where conflicts[id] == nil { owned[claim.outputClass, default: []].insert(claim.target) }
        ownedTargets = owned
    }

    /// The message a controller sends is decided by the target class and the
    /// program together; both must name the same kind of message, so the
    /// ownership class of the target is the class of what is really sent.
    static func fits(_ program: SpatialValueProgram, _ target: SpatialRoutingTarget) -> Bool {
        switch program {
        case .singleNote, .chord, .scale, .randomScale:
            switch target { case .midiNote, .audioUnitNote: return true; default: return false }
        case .programChange:
            switch target { case .midiProgramChange, .audioUnitProgramChange: return true; default: return false }
        case .constant, .continuous:
            switch target {
            case .midiCC, .audioUnitCC, .midiPitchBend, .audioUnitPitchBend, .midiChannelPressure, .audioUnitChannelPressure,
                 .audioUnitParameter: return true
            default: return false
            }
        }
    }

    static func inRange(_ routing: SpatialRouting) -> Bool {
        if let channel = routing.target.midiChannel, channel > 15 { return false }
        if let cc = routing.target.controllerNumber, cc > 127 { return false }
        func note(_ value: Int) -> Bool { (0...127).contains(value) }
        func velocity(_ value: UInt8) -> Bool { (1...127).contains(value) }
        switch routing.program {
        case let .singleNote(n, v, _): return note(n) && velocity(v)
        case let .chord(notes, v, _): return !notes.isEmpty && notes.allSatisfy(note) && velocity(v)
        case let .scale(root, low, high, _, _, _, _), let .randomScale(root, low, high, _, _, _):
            return note(root) && note(low) && note(high)
        case .constant, .continuous, .programChange: return true
        }
    }

    private static func isFinite(_ program: SpatialValueProgram) -> Bool {
        switch program {
        case .constant(let value): return value.isFinite
        case let .continuous(minimum, maximum, degrees, _): return minimum.isFinite && maximum.isFinite && degrees.isFinite
        case let .scale(_, _, _, _, degrees, _, _): return degrees.isFinite
        case .randomScale, .chord, .singleNote, .programChange: return true
        }
    }
}
