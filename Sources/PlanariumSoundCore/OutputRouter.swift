import Foundation
import PlanariumMusicCore

public enum PortSendResult: Equatable, Sendable { case sent, unbound, faulted }
/// One channel of one output destination.
public struct OutputChannelKey: Hashable, Sendable {
    public let destination: SpatialOutputDestination
    public let channel: UInt8
    public init(destination: SpatialOutputDestination, channel: UInt8) { self.destination = destination; self.channel = channel & 0x0F }
}
public struct PortSendCounts: Equatable, Sendable {
    public private(set) var sent: UInt64 = 0
    public private(set) var unbound: UInt64 = 0
    public private(set) var faulted: UInt64 = 0
    package mutating func record(_ result: PortSendResult) {
        switch result {
        case .sent: sent &+= 1
        case .unbound: unbound &+= 1
        case .faulted: faulted &+= 1
        }
    }
}
public struct OutputPortDisplay: Equatable, Sendable {
    public let id: UUID
    public let destination: SpatialOutputDestination
    public let result: PortSendResult
    public let counts: PortSendCounts
    public let sentCC: UInt64
    public let sentPC: UInt64
    /// Successfully sent Ons whose release has not succeeded yet.
    public let soundingNotes: Int
}

/// A prepared value. Ownership of its small receipt book transfers to Q.
/// A boundary must send synchronously and must not wait for Main or Q.
public struct OutputPort: Sendable {
    public let id: UUID
    public let destination: SpatialOutputDestination
    private var cachedMonitor: OutputMonitorSnapshot?
    private var monitor = OutputMonitorStorage()
    private let midiUniqueID: Int32?
    private var programs: [UInt8: SpatialProgramChange] = [:]
    private let sender: @Sendable (MusicEvent) -> PortSendResult
    private let plannedBoundary: (any PlannedNoteBoundary)?
    private struct PlannedReceipt: Sendable {
        var tokens: Set<NotePlanToken>
        let event: MusicEvent
        let deadline: Double
        var canceled = false
        var offDeadline: Double?
    }
    private var plannedReceipts: [PortNote: PlannedReceipt] = [:]
    private var deferredReleases: [PortNote: Double] = [:]
    private var notes: [PortNote: SpatialPlayedNote] = [:]
    private var counts = PortSendCounts()
    private var sentCC: UInt64 = 0
    private var sentPC: UInt64 = 0
    private var sustain: Set<UInt8> = []
    private var bend: Set<UInt8> = []
    private var result: PortSendResult = .unbound
    private var pendingResetChannels: [UInt8]
    private var pendingResetPhase = 0
    package var terminationJournal: OutputReleaseJournal?

    public init(id: UUID = UUID(), destination: SpatialOutputDestination, resetOnBind: Bool = false,
                midiUniqueID: Int32? = nil, plannedBoundary: (any PlannedNoteBoundary)? = nil, send: @escaping @Sendable (MusicEvent) -> PortSendResult) {
        self.id = id
        self.destination = destination
        self.midiUniqueID = midiUniqueID
        self.plannedBoundary = plannedBoundary
        sender = send
        pendingResetChannels = resetOnBind ? Array(UInt8(0)...15) : []
    }
    fileprivate func accepts(_ destination: SpatialOutputDestination?) -> Bool {
        destination == self.destination || midiUniqueID.map { destination == .midiEndpoint(uniqueID: $0) } == true
    }
    package mutating func setMonitorVisible(_ visible: Bool) {
        guard visible != monitor.enabled else { return }
        cachedMonitor = nil
        monitor = OutputMonitorStorage()
        monitor.enabled = visible
        if visible {
            // Catch up from actual unreleased send receipts when opening.
            for (key, note) in notes { monitor.record(status: 0x90 | key.channel, number: note.number, value: UInt16(note.velocity)) }
            for (key, receipt) in plannedReceipts {
                if case let .noteOn(_, _, note) = receipt.event { monitor.record(status: 0x90 | key.channel, number: note.number, value: UInt16(note.velocity)) }
            }
        }
    }
    package var monitorSnapshot: OutputMonitorSnapshot? {
        mutating get {
            guard monitor.enabled else { return nil }
            if cachedMonitor?.generation != monitor.generation { cachedMonitor = monitor.snapshot(id: id, destination: destination) }
            return cachedMonitor
        }
    }
    package mutating func resetPrograms() { programs.removeAll() }
    public var display: OutputPortDisplay {
        .init(id: id, destination: destination, result: result, counts: counts, sentCC: sentCC, sentPC: sentPC, soundingNotes: notes.count + plannedReceipts.count)
    }
    @discardableResult public mutating func send(_ event: MusicEvent) -> PortSendResult {
        guard prepareBinding() == .sent else { return result }
        if case .allNotesOff(_, let channel) = event {
            let reset = releaseControllers(channel: channel)
            guard reset == .sent else { return reset }
        }
        // Publish before crossing an external boundary: a blocked On is also
        // conservatively pending until its result is known. Q keeps ownership.
        var pending = notes
        if case let .noteOn(_, channel, note) = event { pending[.init(channel: channel, number: note.number)] = note }
        recordPending(pending)
        result = sender(event)
        counts.record(result)
        guard result == .sent else { recordPending(notes); return result }
        let encoded = MusicEventMIDIEncoding.bytes(event)
        if monitor.enabled, let bytes = encoded, let status = bytes.first {
            let number = bytes.count > 1 ? bytes[1] : 0
            let value = status & 0xF0 == 0xE0 && bytes.count > 2
                ? UInt16(bytes[1]) | UInt16(bytes[2]) << 7 : UInt16(bytes.count > 2 ? bytes[2] : number)
            monitor.record(status: status, number: number, value: value)
        }
        if case .programChange(_, let channel, let selection) = event {
            if monitor.enabled {
                if let value = selection.bankMSB { monitor.record(status: 0xB0 | channel, number: 0, value: UInt16(value)) }
                if let value = selection.bankLSB { monitor.record(status: 0xB0 | channel, number: 32, value: UInt16(value)) }
                monitor.record(status: 0xC0 | channel, number: selection.program, value: UInt16(selection.program))
            }
            sentPC &+= 1
            if selection.bankMSB != nil { sentCC &+= 1 }; if selection.bankLSB != nil { sentCC &+= 1 }
        } else if let bytes = encoded, bytes.first.map({ $0 & 0xF0 == 0xB0 }) == true {
            sentCC &+= 1
        }
        if let bytes = encoded, let status = bytes.first {
            let channel = status & 15
            if status & 0xF0 == 0xB0 && bytes.count == 3 && bytes[1] == 64 {
                if bytes[2] == 0 { sustain.remove(channel) } else { sustain.insert(channel) }
            }
            if status & 0xF0 == 0xE0 && bytes.count == 3 {
                if bytes[1] == 0 && bytes[2] == 64 { bend.remove(channel) } else { bend.insert(channel) }
            }
        }
        switch event {
        case let .noteOn(_, channel, note): notes[.init(channel: channel, number: note.number)] = note
        case let .noteOff(_, channel, note): notes.removeValue(forKey: .init(channel: channel, number: note.number))
        case .allNotesOff(_, let channel): notes = notes.filter { $0.key.channel != channel }
        case .scalar, .boolean, .sceneChanged, .programChange, .midiValue: break
        }
        recordPlannedPending()
        return result
    }
    package var sampleBoundary: (any SampleNoteBoundary)? { plannedBoundary as? any SampleNoteBoundary }
    package var planningLead: Double { max(0, plannedBoundary?.planningLead ?? 0) }
    package var receiptOwners: Set<UUID> { Set(plannedReceipts.values.flatMap { $0.tokens.map(\.owner) }) }
    package func plannedReceiptsForCancellation(valid: [UUID: UInt64]) -> [UUID] {
        plannedReceipts.values.flatMap { receipt in
            receipt.tokens.filter { receipt.canceled || valid[$0.owner] != $0.generation }.map(\.owner)
        }
    }
    package var nextReceiptDeadline: Double? { plannedReceipts.values.compactMap(\.offDeadline).min() }
    package var hasPendingPlanReleases: Bool { plannedReceipts.values.contains { $0.canceled } }
    package mutating func reapPlanned(now: Double) {
        plannedReceipts = plannedReceipts.filter { $0.value.offDeadline.map { $0 > now } ?? true }
        deferredReleases = deferredReleases.filter { $0.value >= now }
        recordPlannedPending()
    }
    package mutating func sendPlanned(_ plan: PlannedNote, now: Double) -> PortSendResult {
        guard let boundary = plannedBoundary, let bytes = MusicEventMIDIEncoding.bytes(plan.event) else { return .unbound }
        let key: PortNote
        let isOn: Bool
        switch plan.event {
        case let .noteOn(_, channel, note): key = .init(channel: channel, number: note.number); isOn = true
        case let .noteOff(_, channel, note): key = .init(channel: channel, number: note.number); isOn = false
        default: return .faulted
        }
        // Never let a generated release cut a directly owned or another
        // owner's note. Equal pitches are coalesced at the effect's ledger.
        if isOn {
            guard notes[key] == nil, (deferredReleases[key] ?? 0) < now,
                  boundary.permitsNoteOn(bytes: bytes, now: now) else { return .faulted }
            if var receipt = plannedReceipts[key] {
                guard !receipt.canceled else { return .faulted }
                if let off = receipt.offDeadline {
                    // A single owner's sequential Off/On can share the same
                    // AU quantum. The already queued Off precedes this On.
                    guard receipt.tokens.count == 1, receipt.tokens.contains(plan.token),
                          off <= plan.deadline else { return .faulted }
                } else {
                    // A later owner cannot keep an earlier future start alive.
                    guard plan.deadline <= now || plan.deadline == receipt.deadline else { return .faulted }
                    receipt.tokens.insert(plan.token)
                    plannedReceipts[key] = receipt
                    return .sent
                }
            }
        } else {
            guard var receipt = plannedReceipts[key], receipt.tokens.contains(plan.token) else { return .sent }
            if receipt.tokens.count > 1 {
                // A shared owner expires at its deadline, not at the AU
                // lookahead handoff. Otherwise another owner's cancellation
                // could release this still-entitled voice prematurely.
                guard plan.deadline <= now else { return .faulted }
                receipt.tokens.remove(plan.token)
                plannedReceipts[key] = receipt
                return .sent
            }
        }
        guard prepareBinding() == .sent else { return result }
        if isOn, case let .noteOn(_, _, note) = plan.event {
            var pending = notes; pending[key] = note
            recordPending(pending) // publish conservatively before external send
        }
        result = boundary.sendPlanned(bytes: bytes, deadline: plan.deadline, now: now)
        counts.record(result)
        if result == .sent {
            if monitor.enabled { monitor.record(status: bytes[0], number: bytes[1], value: UInt16(bytes[2])) }
            if isOn { plannedReceipts[key] = .init(tokens: [plan.token], event: plan.event, deadline: plan.deadline) }
            else if plan.deadline <= now { plannedReceipts.removeValue(forKey: key) }
            else { plannedReceipts[key]?.offDeadline = plan.deadline }
        }
        if !isOn && result != .sent { plannedReceipts[key]?.canceled = true }
        recordPlannedPending()
        return result
    }
    package mutating func cancelPlans(owner: UUID?, now: Double) {
        guard let boundary = plannedBoundary else { return }
        for key in plannedReceipts.keys.sorted() {
            guard var receipt = plannedReceipts[key], owner == nil || receipt.tokens.contains(where: { $0.owner == owner }),
                  case let .noteOn(destination, channel, note) = receipt.event,
                  let bytes = MusicEventMIDIEncoding.bytes(.noteOff(destination: destination, channel: channel, note: note)) else { continue }
            if let owner {
                let survivors = receipt.tokens.filter { $0.owner != owner }
                if !survivors.isEmpty {
                    receipt.tokens = survivors
                    plannedReceipts[key] = receipt
                    continue
                }
            }
            plannedReceipts[key]?.canceled = true
            result = boundary.cancelPlanned(bytes: bytes, deadline: receipt.deadline, now: now)
            counts.record(result)
            if result == .sent {
                plannedReceipts.removeValue(forKey: key)
                if monitor.enabled { monitor.record(status: bytes[0], number: bytes[1], value: UInt16(bytes[2])) }
                // Do not reuse a pitch until its deferred AU Off has passed.
                deferredReleases[key] = max(now, receipt.deadline) + max(planningLead, 0.001)
            }
        }
        recordPlannedPending()
    }
    private func recordPlannedPending() { recordPending(notes) }
    /// Q performs recovery on the new binding before any musical event. A
    /// refused reset remains pending and prevents a later On hiding the failure.
    @discardableResult package mutating func prepareBinding() -> PortSendResult {
        let wasResetting = !pendingResetChannels.isEmpty
        while let channel = pendingResetChannels.first {
            let event: MusicEvent
            switch pendingResetPhase {
            case 0:
                let target: SpatialRoutingTarget = destination.stripID.map { .audioUnitCC(channel: channel, controller: 64, stripID: $0) } ?? .midiCC(channel: channel, controller: 64)
                event = .midiValue(destination: destination, target: target, value: 0)
            case 1:
                let target: SpatialRoutingTarget = destination.stripID.map { .audioUnitPitchBend(channel: channel, stripID: $0) } ?? .midiPitchBend(channel: channel)
                event = .midiValue(destination: destination, target: target, value: 8192.0 / 16383)
            default: event = .allNotesOff(destination: destination, channel: channel)
            }
            result = sender(event)
            counts.record(result)
            guard result == .sent else { return result }
            if monitor.enabled {
                switch pendingResetPhase {
                case 0: monitor.record(status: 0xB0 | channel, number: 64, value: 0)
                case 1: monitor.record(status: 0xE0 | channel, number: 0, value: 8192)
                default: monitor.record(status: 0xB0 | channel, number: 123, value: 0)
                }
            }
            if pendingResetPhase != 1 { sentCC &+= 1 }
            pendingResetPhase += 1
            if pendingResetPhase == 3 { pendingResetChannels.removeFirst(); pendingResetPhase = 0 }
        }
        if wasResetting { recordPending(notes) }
        return .sent
    }
    private func recordPending(_ pending: [PortNote: SpatialPlayedNote]) {
        var pending = pending
        for (key, receipt) in plannedReceipts {
            if case let .noteOn(_, _, note) = receipt.event { pending[key] = note }
        }
        terminationJournal?.record(id: id, notes: pending.keys.sorted().map {
            .init(portID: id, destination: destination, channel: $0.channel, note: $0.number)
        })
    }
    package mutating func route(_ event: MusicEvent, now: Double) {
        switch event {
        case .programChange(_, let channel, let selection):
            if programs[channel]?.hasSameWireSelection(as: selection) == true { return }
            if send(event) == .sent { programs[channel] = selection }
            return
        case let .noteOn(_, channel, note):
            guard (deferredReleases[.init(channel: channel, number: note.number)] ?? 0) < now,
                  plannedBoundary?.permitsNoteOn(bytes: [0x90 | channel, note.number, note.velocity], now: now) != false else { return }
            guard plannedReceipts[.init(channel: channel, number: note.number)] == nil else { return }
            guard notes[.init(channel: channel, number: note.number)] == nil else { return }
        case let .noteOff(_, channel, note):
            guard notes[.init(channel: channel, number: note.number)] != nil else { return }
        case .allNotesOff, .scalar, .boolean, .sceneChanged, .midiValue: break
        }
        send(event)
    }
    fileprivate mutating func reconcile(_ desired: [MusicEvent], allowOn: Bool, attempted: Set<PortNote>, now: Double) {
        var wanted: [PortNote: SpatialPlayedNote] = [:]
        for case let .noteOn(_, channel, note) in desired {
            wanted[.init(channel: channel, number: note.number)] = note
        }
        for key in notes.keys.sorted() where wanted[key] == nil && !attempted.contains(key) {
            send(.noteOff(destination: destination, channel: key.channel, note: notes[key]!))
        }
        guard allowOn else { return }
        for key in wanted.keys.sorted() where notes[key] == nil && plannedReceipts[key] == nil && !attempted.contains(key) {
            guard (deferredReleases[key] ?? 0) < now,
                  plannedBoundary?.permitsNoteOn(bytes: [0x90 | key.channel, key.number, wanted[key]!.velocity], now: now) != false else { continue }
            send(.noteOn(destination: destination, channel: key.channel, note: wanted[key]!))
        }
    }
    @discardableResult package mutating func releaseControllers(channel: UInt8? = nil, sparing spared: Set<UInt8> = []) -> PortSendResult {
        var failure: PortSendResult = .sent
        for ch in sustain.sorted() where (channel == nil || channel == ch) && !spared.contains(ch) {
            let target: SpatialRoutingTarget = destination.stripID.map { .audioUnitCC(channel: ch, controller: 64, stripID: $0) } ?? .midiCC(channel: ch, controller: 64)
            let reset = send(.midiValue(destination: destination, target: target, value: 0))
            if reset != .sent { failure = reset }
        }
        for ch in bend.sorted() where (channel == nil || channel == ch) && !spared.contains(ch) {
            let target: SpatialRoutingTarget = destination.stripID.map { .audioUnitPitchBend(channel: ch, stripID: $0) } ?? .midiPitchBend(channel: ch)
            let reset = send(.midiValue(destination: destination, target: target, value: 8192.0 / 16383))
            if reset != .sent { failure = reset }
        }
        if failure != .sent { result = failure }
        return failure
    }
    package mutating func release() {
        for key in notes.keys.sorted() {
            send(.noteOff(destination: destination, channel: key.channel, note: notes[key]!))
        }
        releaseControllers()
    }
}
private struct PortNote: Hashable, Comparable, Sendable {
    package let channel: UInt8
    package let number: UInt8
    package static func < (a: Self, b: Self) -> Bool { (a.channel, a.number) < (b.channel, b.number) }
}

/// Q-owned value; failures and receipts are isolated per physical port.
public struct OutputRouter: Sendable {
    private var ports: [OutputPort] = []
    private var monitorVisible = false
    private var plans = NotePlanBook()
    private var planTime: Double = 0
    public var monitorSnapshots: [OutputMonitorSnapshot] {
        mutating get {
            guard monitorVisible else { return [] }
            return ports.indices.compactMap { ports[$0].monitorSnapshot }
        }
    }
    public mutating func beginNotePlan(owner: UUID, now: Double) -> NotePlanToken {
        cancelNotePlans(owner: owner, now: now)
        return plans.begin(owner)
    }
    public mutating func plan(_ note: PlannedNote, now: Double? = nil) -> NotePlanResult {
        let result = plans.insert(note)
        // Overflow is fail-closed for this owner, including its sounding
        // receipts. An Off can never be lost behind a full future queue.
        if result == .full { cancelNotePlans(owner: note.token.owner, now: now ?? planTime) }
        return result
    }
    public mutating func cancelNotePlans(owner: UUID? = nil, now: Double) {
        // Barrier order: invalidate first, release boundary receipts second.
        planTime = now
        plans.invalidate(owner)
        for index in plans.pending.indices {
            if case .noteOff = plans.pending[index].event { plans.pending[index].allowEarly = true }
        }
        for index in ports.indices { ports[index].cancelPlans(owner: owner, now: now) }
    }
    @discardableResult package mutating func cancelAudioNotePlans(stripID: UUID? = nil, now: Double) -> Set<UUID> {
        // Empty tokens have no output commitment yet and are invalidated
        // conservatively; registered MIDI/other-strip owners remain intact.
        var owners = Set(plans.generations.keys.filter { owner in
            guard let destination = plans.destinations[owner] else { return true }
            guard let id = destination.stripID else { return false }
            return stripID == nil || stripID == id
        })
        for port in ports where port.destination.stripID != nil && (stripID == nil || port.destination.stripID == stripID) {
            owners.formUnion(port.receiptOwners)
        }
        for owner in owners { cancelNotePlans(owner: owner, now: now) }
        return owners
    }
    package var plannedOwners: [UUID] { Array(plans.generations.keys) }
    public var nextPlannedDeadline: Double? {
        let deadlines = plans.pending.map { plan in
            let lead = plan.allowEarly ? ports.filter { $0.accepts(plan.event.outputDestination) }.map(\.planningLead).min() ?? 0 : 0
            return plan.deadline - lead
        }
        let retry = ports.contains { $0.hasPendingPlanReleases } ? planTime + 0.001 : nil
        return (deadlines + ports.compactMap(\.nextReceiptDeadline) + (retry.map { [$0] } ?? [])).min()
    }
    public mutating func advanceNotePlans(now: Double) {
        planTime = now
        for index in ports.indices {
            ports[index].reapPlanned(now: now)
            let invalidOwners = Set(ports[index].plannedReceiptsForCancellation(valid: plans.generations))
            for owner in invalidOwners { ports[index].cancelPlans(owner: owner, now: now) }
        }
        var remaining: [PlannedNote] = []
        var releasedOwnership = false
        remaining.reserveCapacity(NotePlanBook.capacity)
        for var plan in plans.pending {
            guard plans.valid(plan.token) else { continue }
            let indices = ports.indices.filter { ports[$0].accepts(plan.event.outputDestination) }
            let lead = plan.allowEarly ? indices.map { ports[$0].planningLead }.min() ?? 0 : 0
            guard plan.deadline - lead <= now else { remaining.append(plan); continue }
            // Finite timer jitter is bounded by the stated 1 ms goal.
            if case .noteOn = plan.event, now - plan.deadline > 0.001 { continue }
            var retry = false
            for index in indices {
                let result = ports[index].sendPlanned(plan, now: now)
                if result != .sent && now < plan.deadline { retry = true }
                if case .noteOff = plan.event, result == .sent { releasedOwnership = true }
            }
            if retry { plan.allowEarly = false; remaining.append(plan) }
        }
        if releasedOwnership {
            for index in remaining.indices {
                if case .noteOff = remaining[index].event { remaining[index].allowEarly = true }
            }
        }
        plans.pending = remaining
    }
    public mutating func setMonitorVisible(_ visible: Bool) {
        monitorVisible = visible
        for index in ports.indices { ports[index].setMonitorVisible(visible) }
    }
    public init() {}
    public var display: [OutputPortDisplay] { ports.map(\.display) }
    /// IDs identify one binding for its lifetime. A duplicate attach is ignored;
    /// replacing a binding requires retire + ack, never implicit destruction.
    public mutating func attach(_ port: OutputPort) {
        guard !ports.contains(where: { $0.id == port.id }) else { return }
        var port = port
        port.setMonitorVisible(monitorVisible)
        port.prepareBinding()
        ports.append(port)
    }
    @discardableResult public mutating func retire(_ id: UUID, now: Double = ProcessInfo.processInfo.systemUptime) -> OutputPortDisplay? {
        guard let index = ports.firstIndex(where: { $0.id == id }) else { return nil }
        let owners = Set(plans.generations.keys.filter { owner in
            plans.destinations[owner].map { ports[index].accepts($0) } ?? true
        }).union(ports[index].receiptOwners)
        for owner in owners { cancelNotePlans(owner: owner, now: now) }
        ports[index].sampleBoundary?.invalidateSampleNotes()
        ports[index].cancelPlans(owner: nil, now: now)
        ports[index].release() // RETIRE: release-before-remove
        let receipt = ports[index].display
        ports.remove(at: index)
        return receipt
    }
    public mutating func route(_ events: [MusicEvent], sounding: [MusicEvent], allowOn: Bool, now: Double = ProcessInfo.processInfo.systemUptime) {
        for index in ports.indices {
            var attempted = Set<PortNote>()
            for event in events where ports[index].accepts(event.outputDestination) {
                switch event {
                case let .noteOn(_, channel, note), let .noteOff(_, channel, note):
                    attempted.insert(.init(channel: channel, number: note.number))
                case .allNotesOff, .scalar, .boolean, .sceneChanged, .programChange, .midiValue: break
                }
                ports[index].route(event, now: now)
            }
            let desired = sounding.filter { ports[index].accepts($0.outputDestination) }
            ports[index].reconcile(desired,
                                   allowOn: allowOn, attempted: attempted, now: now)
        }
    }
    package func hasSampleBoundary(stripID: UUID) -> Bool {
        ports.contains { $0.destination == .audioUnit(stripID: stripID) && $0.sampleBoundary?.sampleNotesAvailable == true }
    }
    package mutating func enqueueSampleNote(stripID: UUID, bytes: [UInt8], deadline: Double, immediate: Bool) -> PortSendResult {
        guard let port = ports.first(where: { $0.destination == .audioUnit(stripID: stripID) }),
              let boundary = port.sampleBoundary else { return .unbound }
        return boundary.enqueueSampleNote(bytes: bytes, deadline: deadline, immediate: immediate)
    }
    package func invalidateSampleNotes(stripID: UUID? = nil) {
        for port in ports where stripID == nil || port.destination == .audioUnit(stripID: stripID!) {
            port.sampleBoundary?.invalidateSampleNotes()
        }
    }
    public mutating func releaseControllers(destination: SpatialOutputDestination? = nil, channel: UInt8? = nil) {
        releaseControllers(destination: destination, channel: channel, sparing: [])
    }
    /// Resets sustain and pitch bend like above, except on the channels another
    /// playing source owns as its controls (a source-local release).
    public mutating func releaseControllers(destination: SpatialOutputDestination? = nil, channel: UInt8? = nil,
                                            sparing spared: Set<OutputChannelKey>) {
        for index in ports.indices where destination == nil || ports[index].accepts(destination) {
            let channels = Set(spared.filter { ports[index].accepts($0.destination) }.map(\.channel))
            ports[index].releaseControllers(channel: channel, sparing: channels)
        }
    }
    public mutating func resetPrograms() {
        for index in ports.indices { ports[index].resetPrograms() }
    }
    /// The router owns the actual bindings, including retiring strips and
    /// bindings without a document. PANIC covers every channel of every port.
    public mutating func panic(audioOnly: Bool = false, releasing events: [MusicEvent] = [], now: Double = ProcessInfo.processInfo.systemUptime) {
        if audioOnly { cancelAudioNotePlans(now: now) } else { cancelNotePlans(now: now) }
        for index in ports.indices where !audioOnly || ports[index].destination.stripID != nil {
            ports[index].sampleBoundary?.invalidateSampleNotes()
            if !audioOnly { ports[index].resetPrograms() }
            for event in events where event.outputDestination == ports[index].destination {
                switch event {
                case .scalar, .boolean: ports[index].route(event, now: now)
                default: break // Physical note receipts are released below.
                }
            }
            ports[index].release()
            for channel in UInt8(0)...UInt8(15) {
                ports[index].send(.allNotesOff(destination: ports[index].destination, channel: channel))
            }
        }
    }
}
private extension MusicEvent {
    var outputDestination: SpatialOutputDestination? {
        switch self {
        case .programChange(let destination, _, _), .midiValue(let destination, _, _): return destination
        case .noteOn(let d, _, _), .noteOff(let d, _, _), .allNotesOff(let d, _): return d
        case .scalar(_, let target, _), .boolean(_, let target, _):
            switch target {
            case .audioUnitNote(_, let id), .audioUnitAllNotesOff(_, let id), .audioUnitCC(_, _, let id),
                 .audioUnitProgramChange(_, let id), .audioUnitPitchBend(_, let id), .audioUnitChannelPressure(_, let id): return .audioUnit(stripID: id)
            case .audioUnitParameter(let parameter): return .audioUnit(stripID: parameter.stripID)
            case .midiNote, .midiCC, .midiProgramChange, .midiPitchBend, .midiChannelPressure, .midiAllNotesOff: return .midi
            case .midiEffectParameter, .sceneSwitch, .releaseLayer, .boolean: return nil
            }
        case .sceneChanged: return nil
        }
    }
}

/// Immutable numeric receipt for shutdown diagnostics; channel is zero-based.
public struct UnconfirmedNoteOff: Equatable, Sendable {
    public let portID: UUID
    public let destination: SpatialOutputDestination
    public let channel: UInt8
    public let note: UInt8
    public init(portID: UUID, destination: SpatialOutputDestination, channel: UInt8, note: UInt8) {
        self.portID = portID; self.destination = destination; self.channel = channel; self.note = note
    }
}
/// Only copies receipts under the lock; never calls a destination or waits for Q.
/// Writes originate on Q; the termination deadline can read on Main.
package final class OutputReleaseJournal: @unchecked Sendable {
    package init() {}
    private let lock = NSLock()
    private var ports: [UUID: [UnconfirmedNoteOff]] = [:]
    package func record(id: UUID, notes: [UnconfirmedNoteOff]) {
        lock.lock(); ports[id] = notes; lock.unlock()
    }
    package func snapshot() -> [UnconfirmedNoteOff] {
        lock.lock(); defer { lock.unlock() }
        return ports.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { ports[$0]! }
    }
}
