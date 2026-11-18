// The mailbox's unchecked Sendable conformance covers only its lock and value.
// Every read, write and take of the stored value holds this SAME lock; no
// reference to mutable storage escapes. Consumers receive immutable snapshots.
import Foundation
import PlanariumDomain

public enum InputBacklogStatus: Equatable, Sendable {
    case ready, overloaded, recovered

    public var message: String? {
        switch self {
        case .ready: return nil
        case .overloaded: return "Input is over 2 seconds behind · releasing all notes."
        case .recovered: return "Input caught up · ready for new measurements."
        }
    }
}

public struct DisplayFrame: Equatable, Sendable {
    public let arpeggiatorModulation: ArpeggiatorModulationState
    public let profile: ProfileFrame?
    public let contour: SpatialRoomContour?
    public let selection: DeviceLatticeSelection
    public let soundingNoteOwners: [SoundingNoteOwner]
    public let outputMonitor: [OutputMonitorSnapshot]
    public let heldCells: [CompiledActiveCell]
    public let activeCells: [CompiledActiveCell]
    public let revision: SpatialDocumentRevision?
    public let scene: RuntimeSceneSnapshot?
    public let sessionID: UUID?
    public let processedProfiles: UInt64
    public let discardedProfiles: UInt64
    public let overflowProfiles: UInt64
    public let ports: [OutputPortDisplay]
    /// Final send counts of a binding removed by this command, including
    /// failed Off attempts. This is a receipt, not another live port.
    public let retiredPort: OutputPortDisplay?
    public init(arpeggiatorModulation: ArpeggiatorModulationState = .init(), profile: ProfileFrame? = nil, contour: SpatialRoomContour? = nil,
                selection: DeviceLatticeSelection, revision: SpatialDocumentRevision? = nil, scene: RuntimeSceneSnapshot? = nil,
                sessionID: UUID? = nil, processedProfiles: UInt64 = 0, discardedProfiles: UInt64 = 0, overflowProfiles: UInt64 = 0,
                soundingNoteOwners: [SoundingNoteOwner] = [], outputMonitor: [OutputMonitorSnapshot] = [], heldCells: [CompiledActiveCell] = [], ports: [OutputPortDisplay] = [], retiredPort: OutputPortDisplay? = nil,
                partitionOwners: [UUID: UUID] = [:]) {
        self.arpeggiatorModulation = arpeggiatorModulation
        // The runtime plays partitions; what the presentation shows are the user's layers.
        func owner(_ id: UUID) -> UUID { partitionOwners[id] ?? id }
        self.soundingNoteOwners = partitionOwners.isEmpty ? soundingNoteOwners : soundingNoteOwners.map { $0.reassigningLayerID(owner($0.layerID)) }
        self.outputMonitor = outputMonitor
        self.heldCells = partitionOwners.isEmpty ? heldCells : heldCells.map { $0.reassigningLayerID(owner($0.layerID)) }
        self.profile = profile; self.contour = contour; self.selection = selection; self.revision = revision
        let handles = partitionOwners.isEmpty ? Array(selection.activeHandles.values) : selection.activeHandles.values.map { $0.reassigningLayerID(owner($0.layerID)) }
        activeCells = handles.sorted { a, b in
            withUnsafeBytes(of: a.layerID.uuid) { left in
                withUnsafeBytes(of: b.layerID.uuid) { right in left.lexicographicallyPrecedes(right) }
            }
        }
        self.scene = scene
        self.sessionID = sessionID; self.processedProfiles = processedProfiles; self.discardedProfiles = discardedProfiles
        self.overflowProfiles = overflowProfiles
        self.ports = ports; self.retiredPort = retiredPort
    }
}

public final class DisplayFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: DisplayFrame?
    private var generation: UInt64 = 0
    private var changed: (@Sendable () -> Void)?
    public init() {}
    public func write(_ frame: DisplayFrame) {
        lock.lock()
        latest = frame; generation &+= 1
        let notify = changed
        lock.unlock()
        notify?()
    }
    /// Discrete runtime evidence changed without replacing a frame (e.g. Q is
    /// blocked sending Note-Off). Uses the same pump, with no fabricated scan.
    func notifyEvidenceChanged() {
        lock.lock(); let notify = changed; lock.unlock(); notify?()
    }
    /// One presentation consumer; installation and publication use the same lock.
    public func observeWrites(_ changed: (@Sendable () -> Void)?) {
        lock.lock(); self.changed = changed; lock.unlock()
    }
    public func snapshot() -> (generation: UInt64, frame: DisplayFrame?) {
        lock.lock(); defer { lock.unlock() }
        return (generation, latest)
    }
    public func read() -> DisplayFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
    public func take() -> DisplayFrame? {
        lock.lock()
        defer { lock.unlock() }
        let value = latest
        latest = nil
        return value
    }
}
