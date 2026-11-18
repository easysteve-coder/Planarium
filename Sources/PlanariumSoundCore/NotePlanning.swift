import Foundation
import PlanariumMusicCore

/// All times share RuntimeClock's monotonic seconds epoch. A token is issued
/// on Q; callers must retain it rather than manufacture a newer generation.
public struct NotePlanToken: Hashable, Sendable {
    public let owner: UUID
    public let generation: UInt64
    public init(owner: UUID, generation: UInt64) { self.owner = owner; self.generation = generation }
}
public struct PlannedNote: Equatable, Sendable {
    public let deadline: Double
    public let event: MusicEvent
    public let token: NotePlanToken
    package var allowEarly = true
    public init(deadline: Double, event: MusicEvent, token: NotePlanToken) {
        self.deadline = deadline; self.event = event; self.token = token
    }
}
public enum NotePlanResult: Equatable, Sendable { case accepted, stale, full, invalid }

/// The boundary may refuse an early AU send until it has a coherent render
/// anchor. MIDI always advertises zero lead. No fake timing fallback is used.
public protocol PlannedNoteBoundary: Sendable {
    var planningLead: Double { get }
    func permitsNoteOn(bytes: [UInt8], now: Double) -> Bool
    func sendPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult
    /// AU sends an immediate Off plus an Off beyond the handed-over On.
    /// MIDI has no future On in its port and only needs the immediate Off.
    func cancelPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult
}

public extension PlannedNoteBoundary {
    func permitsNoteOn(bytes: [UInt8], now: Double) -> Bool { true }
}

package struct NotePlanBook: Sendable {
    package static let capacity = 256
    package var pending: [PlannedNote] = []
    package var generations: [UUID: UInt64] = [:]
    package var destinations: [UUID: SpatialOutputDestination] = [:]
    package var serial: UInt64 = 0
    package init() { pending.reserveCapacity(Self.capacity) }
    package mutating func begin(_ owner: UUID) -> NotePlanToken {
        serial &+= 1
        generations[owner] = serial
        return .init(owner: owner, generation: serial)
    }
    package func valid(_ token: NotePlanToken) -> Bool { generations[token.owner] == token.generation }
    package mutating func insert(_ note: PlannedNote) -> NotePlanResult {
        guard valid(note.token) else { return .stale }
        guard note.deadline.isFinite, note.deadline >= 0 else { return .invalid }
        let destination: SpatialOutputDestination
        switch note.event {
        case .noteOn(let value, _, _), .noteOff(let value, _, _): destination = value
        default: return .invalid
        }
        guard destinations[note.token.owner].map({ $0 == destination }) ?? true else { return .invalid }
        guard pending.count < Self.capacity else { return .full }
        destinations[note.token.owner] = destination
        pending.append(note)
        pending.sort {
            if $0.deadline != $1.deadline { return $0.deadline < $1.deadline }
            if case .noteOff = $0.event { if case .noteOn = $1.event { return true } }
            return false
        }
        return .accepted
    }
    package mutating func invalidate(_ owner: UUID?) {
        if let owner {
            generations.removeValue(forKey: owner); destinations.removeValue(forKey: owner)
            pending.removeAll { $0.token.owner == owner }
        } else {
            generations.removeAll(keepingCapacity: true); destinations.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
        }
    }
}

/// A value copy from the preallocated render mailbox. Unknown or stale anchors
/// never enable lookahead. Conversion uses the observer's actual block length.
public struct NoteRenderAnchor: Sendable {
    public let seconds: Double
    public let sample: Double
    public let rate: Double
    public let frames: UInt32
    public init(seconds: Double, sample: Double, rate: Double, frames: UInt32) {
        self.seconds = seconds; self.sample = sample; self.rate = rate; self.frames = frames
    }
    public func lead(at now: Double) -> Double {
        guard seconds.isFinite, sample.isFinite, rate.isFinite, rate > 0, frames > 0,
              now.isFinite, now >= seconds, now - seconds <= Double(frames) / rate + 1e-9 else { return 0 }
        return Double(frames) / rate
    }
    public func offset(deadline: Double, now: Double) -> Int64? {
        guard deadline.isFinite, now.isFinite else { return nil }
        if deadline <= now { return 0 }
        let lead = lead(at: now)
        guard lead > 0, deadline - now <= lead else { return nil }
        // Immediate + offset addresses the NEXT render cycle. The observer
        // timestamp denotes the beginning of the already observed block.
        let nextBlockSample = sample + Double(frames)
        let deadlineSample = sample + (deadline - seconds) * rate
        let offset = (deadlineSample - nextBlockSample).rounded()
        guard offset >= 0, offset < Double(frames) else { return nil }
        return Int64(offset)
    }
}

/// A producer on Q submits absolute host deadlines to the per-instrument
/// sample ring. The consumer alone schedules bytes during PreRender.
public protocol SampleNoteBoundary: PlannedNoteBoundary {
    var sampleNotesAvailable: Bool { get }
    func enqueueSampleNote(bytes: [UInt8], deadline: Double, immediate: Bool) -> PortSendResult
    func invalidateSampleNotes()
}

public extension SampleNoteBoundary {
    var sampleNotesAvailable: Bool { true }
}
