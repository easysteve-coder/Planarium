import Foundation

public enum SpatialOutputDestination: Hashable, Sendable {
    case midi
    case midiEndpoint(uniqueID: Int32)
    case audioUnit(stripID: UUID)
    public var stripID: UUID? {
        switch self {
        case .midi, .midiEndpoint: return nil
        case .audioUnit(let id): return id
        }
    }
}

public enum SpatialOutputCommand: Equatable, Sendable {
    case noteOn(destination: SpatialOutputDestination, channel: UInt8, note: SpatialPlayedNote)
    case noteOff(destination: SpatialOutputDestination, channel: UInt8, note: SpatialPlayedNote)
    case scheduleOff(destination: SpatialOutputDestination, channel: UInt8, note: SpatialPlayedNote,
                     generation: UInt64, delayMilliseconds: Double)
    case scalar(routingID: UUID, target: SpatialRoutingTarget, value: Double)
    case boolean(routingID: UUID, target: SpatialRoutingTarget, value: Bool)
    case allNotesOff(destination: SpatialOutputDestination, channel: UInt8)
}

/// Der testbare Besitz- und Übergangszustand des räumlichen Notenwegs.
public struct SpatialNoteLedger: Sendable {
    private struct Held: Hashable, Sendable {
        let destination: SpatialOutputDestination
        let channel: UInt8
        let note: SpatialPlayedNote
    }

    private struct Channel: Hashable {
        let destination: SpatialOutputDestination
        let number: UInt8
    }

    private var notesByRouting: [UUID: Set<Held>] = [:]
    private var generation: [Held: UInt64] = [:]
    private var pendingOverlap: [Held: UInt64] = [:]
    private var overlapRouting: [Held: UUID] = [:]
    private var triggerState: [UUID: Bool] = [:]
    private var holdUntilNextRouting: Set<UUID> = []
    // Consume every measured Hold entry, including losing simultaneous entries.
    // A displaced owner cannot reclaim while the winner remains measured.
    // A measured winner exit exposes an already-entered neighbour as new music.
    private var holdCells: [UUID: PolarDeviceLattice] = [:]
    private var holdEntries: [UUID: SpatialRoutingEvaluation] = [:]
    internal var holdOwnerCountByChannel: [String: Int] {
        var result: [String: Int] = [:]
        for id in holdUntilNextRouting {
            for channel in Set((notesByRouting[id] ?? []).map { Channel(destination: $0.destination, number: $0.channel) }) {
                result["\(channel.destination):\(channel.number)", default: 0] += 1
            }
        }
        return result
    }
    private struct ToggleCell: Hashable, Sendable {
        let routingID: UUID
        let cell: PolarDeviceLattice
    }
    private var toggleDisplayCells: [ToggleCell: PolarDeviceLattice] = [:]
    private var toggled: [ToggleCell: Set<Held>] = [:]
    private var toggleEntries: Set<ToggleCell> = []
    private var lastToggleTime: [ToggleCell: Double] = [:]
    /// Measured entry locks survive loss. Panic must capture them before
    /// releaseAll clears ownership, even when detection has already reset.
    internal var occupiedToggleCells: [(routingID: UUID, cell: PolarDeviceLattice)] {
        toggleEntries.map { ($0.routingID, $0.cell) }
    }
    internal var noteOwners: [(routingID: UUID, destination: SpatialOutputDestination, channel: UInt8, number: UInt8, latched: Bool)] {
        notesByRouting.flatMap { id, notes in notes.map { (id, $0.destination, $0.channel, $0.note.number, holdUntilNextRouting.contains(id)) } }
        + toggled.flatMap { key, notes in notes.map { (key.routingID, $0.destination, $0.channel, $0.note.number, true) } }
    }
    public var latchedCells: [(routingID: UUID, cell: PolarDeviceLattice)] {
        holdCells.compactMap { id, cell in
            (notesByRouting[id]?.isEmpty == false && holdUntilNextRouting.contains(id)) ? (id, cell) : nil
        } + toggled.compactMap { key, notes in notes.isEmpty ? nil : (key.routingID, toggleDisplayCells[key] ?? key.cell) }
    }
    private var owned: Set<Held> {
        Set(notesByRouting.values.flatMap { $0 }).union(toggled.values.flatMap { $0 })
    }

    private let coalescesSharedNotes: Bool

    /// Legacy callers retain their established retrigger policy until P5.
    /// PlayEngine uses physical shared-note ownership, without duplicate Ons.
    public init(coalescesSharedNotes: Bool = false) {
        self.coalescesSharedNotes = coalescesSharedNotes
    }

    public var heldNoteCount: Int { owned.count }

    /// Includes delayed overlap tails; they are owned notes until actually off.
    public var soundingNoteCount: Int {
        owned.union(pendingOverlap.keys).count
    }

    /// Read-only sounding receipts, including overlap tails. Runtime uses
    /// this domain truth to initialize a newly attached port on a REAL profile.
    public var soundingCommands: [SpatialOutputCommand] {
        owned.union(pendingOverlap.keys)
            .sorted(by: heldOrder).map {
                .noteOn(destination: $0.destination, channel: $0.channel, note: $0.note)
            }
    }

    /// Installation only removes unsupported notes. It cannot start new notes.
    public mutating func retainSupported(by evaluations: [SpatialRoutingEvaluation]) -> [SpatialOutputCommand] {
        retainSupported(by: evaluations, preservingRoutingIDs: [])
    }

    internal mutating func retainSupported(by evaluations: [SpatialRoutingEvaluation], preservingRoutingIDs: Set<UUID>) -> [SpatialOutputCommand] {
        var supported: [UUID: Set<Held>] = [:]
        for evaluation in evaluations {
            guard case .notes(let notes, let transition) = evaluation.value, transition != .toggle else { continue }
            let destination: SpatialOutputDestination
            let channel: UInt8
            switch evaluation.target {
            case .midiNote(let c): destination = evaluation.midiDestination; channel = c & 0x0F
            case .audioUnitNote(let c, let id): destination = .audioUnit(stripID: id); channel = c & 0x0F
            default: continue
            }
            supported[evaluation.routingID] = desiredNotes(notes, destination: destination, channel: channel)
        }
        let before = owned.union(pendingOverlap.keys)
        for id in preservingRoutingIDs { supported[id] = notesByRouting[id] ?? [] }
        // Installation retains each owner's own receipts. Shared pitches in
        // another routing must never resurrect a displaced Hold owner.
        let retainingHolds = holdUntilNextRouting.union(evaluations.compactMap { evaluation in
            if case .notes(_, .holdUntilNext) = evaluation.value { return evaluation.routingID }
            return nil
        })
        notesByRouting = supported.reduce(into: [:]) { result, item in
            let receipts = retainingHolds.contains(item.key) ? (notesByRouting[item.key] ?? []) : before
            result[item.key] = item.value.intersection(receipts)
        }
        pendingOverlap = pendingOverlap.filter { item in
            guard let owner = overlapRouting[item.key] else { return false }
            return preservingRoutingIDs.contains(owner)
        }
        overlapRouting = overlapRouting.filter { pendingOverlap[$0.key] != nil }
        let after = owned.union(pendingOverlap.keys)
        generation = generation.filter { after.contains($0.key) }
        triggerState = triggerState.filter { supported[$0.key] != nil }
        holdUntilNextRouting = holdUntilNextRouting.intersection(supported.keys)
        return before.subtracting(after).sorted(by: heldOrder).map {
            .noteOff(destination: $0.destination, channel: $0.channel, note: $0.note)
        }
    }

    internal func ownsScheduledOff(_ command: SpatialOutputCommand) -> Bool {
        guard case let .scheduleOff(destination, channel, note, expected, _) = command else { return false }
        let held = Held(destination: destination, channel: channel, note: note)
        return pendingOverlap[held] == expected && generation[held] == expected
    }

    internal mutating func releaseOverlapTails() -> [SpatialOutputCommand] {
        let tails = Set(pendingOverlap.keys)
        pendingOverlap.removeAll(); overlapRouting.removeAll()
        for tail in tails { generation[tail] = nil }
        return tails.sorted(by: heldOrder).map {
            .noteOff(destination: $0.destination, channel: $0.channel, note: $0.note)
        }
    }

    private func desiredNotes(_ notes: Set<SpatialPlayedNote>, destination: SpatialOutputDestination, channel: UInt8) -> Set<Held> {
        guard coalescesSharedNotes else {
            return Set(notes.map { Held(destination: destination, channel: channel, note: $0) })
        }
        let sounding = owned.union(pendingOverlap.keys)
        var byNumber: [UInt8: SpatialPlayedNote] = [:]
        for note in notes {
            if let previous = byNumber[note.number], previous.velocity >= note.velocity { continue }
            byNumber[note.number] = note
        }
        return Set(byNumber.values.map { note in
            // Velocity belongs to the On, never to physical note identity.
            sounding.first { $0.destination == destination && $0.channel == channel && $0.note.number == note.number }
                ?? Held(destination: destination, channel: channel, note: note)
        })
    }

    private func heldOrder(_ lhs: Held, _ rhs: Held) -> Bool {
        (lhs.destination.stripID?.uuidString ?? "", lhs.channel, lhs.note.number, lhs.note.velocity)
            < (rhs.destination.stripID?.uuidString ?? "", rhs.channel, rhs.note.number, rhs.note.velocity)
    }

    public mutating func apply(_ evaluations: [SpatialRoutingEvaluation], releasingLatchedRoutingIDs: Set<UUID> = [], measuredToggleEntries: [SpatialRoutingEvaluation]? = nil, profileTime: Double? = nil) -> [SpatialOutputCommand] {
        var commands = releaseLatched(routingIDs: releasingLatchedRoutingIDs)
        let entries = Set(evaluations.compactMap { evaluation -> ToggleCell? in
            guard case .notes(_, .toggle) = evaluation.value, let cell = evaluation.cell else { return nil }
            return ToggleCell(routingID: evaluation.routingID, cell: cell)
        })
        var fresh = entries.subtracting(toggleEntries)
        let measured = Set((measuredToggleEntries ?? evaluations).compactMap { evaluation -> ToggleCell? in
            guard case .notes(_, .toggle) = evaluation.value, let cell = evaluation.cell else { return nil }
            return ToggleCell(routingID: evaluation.routingID, cell: cell)
        })
        toggleEntries = toggleEntries.intersection(measured).union(entries)
        let liveIDs = Set(evaluations.map(\.routingID))
        let outgoingHoldIDs = holdUntilNextRouting
        var nextHoldEntries: [UUID: SpatialRoutingEvaluation] = [:]
        var holdWinners: Set<UUID> = []
        var winningChannels: [Channel: SpatialRoutingEvaluation] = [:]
        var freshChannels: Set<Channel> = []
        let measuredHoldIDs = Set(evaluations.compactMap { evaluation -> UUID? in
            if case .notes(let notes, .holdUntilNext) = evaluation.value, !notes.isEmpty { return evaluation.routingID }
            return nil
        })
        // An exposed neighbour is a continuation of the same measured hand,
        // not a later jump back into an already consumed zone. Require a
        // preceding measured owner contact and at most one hand width.
        // releaseTransient preserves that contact across input loss; only a
        // subsequent measured apply replaces it.
        func adjacentExit(_ candidate: SpatialRoutingEvaluation, channel: Channel) -> Bool {
            guard let next = candidate.cell else { return false }
            func point(_ cell: PolarDeviceLattice) -> (Double, Double) {
                let angle = (Double(cell.sector) * 0.5 - 90) * Double.pi / 180
                return (Double(cell.ring) * sin(angle), Double(cell.ring) * cos(angle))
            }
            let n = point(next)
            return outgoingHoldIDs.subtracting(measuredHoldIDs).contains { id in
                guard let old = holdEntries[id]?.cell,
                      (notesByRouting[id] ?? []).contains(where: {
                          $0.destination == channel.destination && $0.channel == channel.number
                      }) else { return false }
                let p = point(old)
                return hypot(n.0 - p.0, n.1 - p.1) <= 10
            }
        }
        // Fresh entries compete by representative distance and document order.
        // On a measured owner exit, a remaining neighbour is exposed as a new
        // musical entry. With no measured neighbour, the held chord survives.
        for evaluation in evaluations {
            guard case .notes(let notes, .holdUntilNext) = evaluation.value, !notes.isEmpty else { continue }
            nextHoldEntries[evaluation.routingID] = evaluation
            let previousEntry = holdEntries[evaluation.routingID]
            let changed = previousEntry?.value != evaluation.value || previousEntry?.target != evaluation.target
                || previousEntry?.midiDestination != evaluation.midiDestination
            guard !releasingLatchedRoutingIDs.contains(evaluation.routingID) else { continue }
            let channel: Channel
            switch evaluation.target {
            case .midiNote(let c): channel = Channel(destination: evaluation.midiDestination, number: c & 0x0F)
            case .audioUnitNote(let c, let id): channel = Channel(destination: .audioUnit(stripID: id), number: c & 0x0F)
            default: continue
            }
            guard changed || adjacentExit(evaluation, channel: channel) else { continue }
            if changed && !freshChannels.contains(channel) {
                freshChannels.insert(channel)
                winningChannels[channel] = evaluation
                continue
            }
            if !changed && freshChannels.contains(channel) { continue }
            if let previous = winningChannels[channel],
               previous.representativeDistanceSquared <= evaluation.representativeDistanceSquared { continue }
            winningChannels[channel] = evaluation
        }
        holdWinners = Set(winningChannels.values.map(\.routingID))
        for winner in winningChannels.values { holdCells[winner.routingID] = winner.cell }
        holdEntries = nextHoldEntries
        let silenced = Set(evaluations.compactMap { evaluation -> Channel? in
            guard coalescesSharedNotes, case .boolean(true) = evaluation.value,
                  !(triggerState[evaluation.routingID] ?? false) else { return nil }
            switch evaluation.target {
            case .midiAllNotesOff(let channel): return Channel(destination: evaluation.midiDestination, number: channel & 0x0F)
            case .audioUnitAllNotesOff(let channel, let id): return Channel(destination: .audioUnit(stripID: id), number: channel & 0x0F)
            default: return nil
            }
        })
        for stale in Set(notesByRouting.keys).subtracting(liveIDs).sorted(by: { $0.uuidString < $1.uuidString }) {
            replace([], routingID: stale, transition: .retrigger, commands: &commands)
            holdUntilNextRouting.remove(stale)
        }

        for evaluation in evaluations {
            switch evaluation.value {
            case .programChange: break // Entry commands belong to PlayEngine, never to the note ledger.
            case .inactive:
                if !holdUntilNextRouting.contains(evaluation.routingID) {
                    replace([], routingID: evaluation.routingID, transition: .retrigger, commands: &commands)
                }
            case let .notes(notes, transition):
                if transition == .toggle {
                    guard let cell = evaluation.cell else { continue }
                    let key = ToggleCell(routingID: evaluation.routingID, cell: cell)
                    guard fresh.remove(key) != nil, !releasingLatchedRoutingIDs.contains(evaluation.routingID) else { continue }
                    // Consume the measured entry even when guarded. Remaining
                    // inside after expiry must never replay a rejected edge.
                    if evaluation.toggleGuardSeconds > 0 {
                        guard let profileTime, profileTime.isFinite else { continue }
                        if let last = lastToggleTime[key], profileTime - last < evaluation.toggleGuardSeconds { continue }
                    }
                    if let previous = toggled.removeValue(forKey: key) {
                        previous.sorted(by: heldOrder).forEach { off($0, commands: &commands) }
                    } else {
                        let destination: SpatialOutputDestination
                        let channel: UInt8
                        switch evaluation.target {
                        case .midiNote(let c): destination = evaluation.midiDestination; channel = c & 0x0F
                        case .audioUnitNote(let c, let id): destination = .audioUnit(stripID: id); channel = c & 0x0F
                        default: continue
                        }
                        guard !silenced.contains(Channel(destination: destination, number: channel)) else { continue }
                        let desired = desiredNotes(notes, destination: destination, channel: channel)
                        let sounding = owned.union(pendingOverlap.keys)
                        toggled[key] = desired
                        toggleDisplayCells[key] = evaluation.displayCell ?? cell
                        if evaluation.commonNotes == .retrigger && coalescesSharedNotes {
                            for note in desired.intersection(sounding).sorted(by: heldOrder) {
                                commands.append(.noteOff(destination: note.destination, channel: note.channel, note: note.note))
                                commands.append(.noteOn(destination: note.destination, channel: note.channel, note: note.note))
                            }
                        }
                        releaseOutgoingHolds(outgoingHoldIDs, for: desired, commands: &commands)
                        desired.sorted(by: heldOrder).forEach { on($0, alreadySounding: coalescesSharedNotes && sounding.contains($0), commands: &commands) }
                    }
                    if let profileTime, profileTime.isFinite { lastToggleTime[key] = profileTime }
                    continue
                }
                if transition == .holdUntilNext && !holdWinners.contains(evaluation.routingID) { continue }
                if case .holdUntilNext = transition { holdUntilNextRouting.insert(evaluation.routingID) }
                else { holdUntilNextRouting.remove(evaluation.routingID) }
                let destination: SpatialOutputDestination
                let channel: UInt8
                switch evaluation.target {
                case .midiNote(let value): destination = evaluation.midiDestination; channel = value & 0x0F
                case .audioUnitNote(let value, let id): destination = .audioUnit(stripID: id); channel = value & 0x0F
                default: continue
                }
                let desired = silenced.contains(Channel(destination: destination, number: channel))
                    ? Set<Held>() : desiredNotes(notes, destination: destination, channel: channel)
                replace(
                    desired,
                    routingID: evaluation.routingID, transition: transition,
                    outgoingHoldIDs: outgoingHoldIDs, commonNotes: evaluation.commonNotes, commands: &commands
                )
            case let .scalar(value):
                commands.append(.scalar(routingID: evaluation.routingID, target: evaluation.target, value: value))
            case let .boolean(value):
                if case .midiAllNotesOff(let channel) = evaluation.target,
                   value && !(triggerState[evaluation.routingID] ?? false) {
                    if coalescesSharedNotes { commands += releaseChannel(destination: evaluation.midiDestination, channel: channel & 0x0F) }
                    commands.append(.allNotesOff(destination: evaluation.midiDestination, channel: channel & 0x0F))
                } else if case .audioUnitAllNotesOff(let channel, let id) = evaluation.target,
                          value && !(triggerState[evaluation.routingID] ?? false) {
                    let destination = SpatialOutputDestination.audioUnit(stripID: id)
                    if coalescesSharedNotes { commands += releaseChannel(destination: destination, channel: channel & 0x0F) }
                    commands.append(.allNotesOff(destination: destination, channel: channel & 0x0F))
                } else if evaluation.target.controllerNumber != nil {
                    commands.append(.boolean(routingID: evaluation.routingID, target: evaluation.target, value: value))
                }
                triggerState[evaluation.routingID] = value
            }
        }
        holdCells = holdCells.filter { notesByRouting[$0.key]?.isEmpty == false }
        toggleDisplayCells = toggleDisplayCells.filter { toggled[$0.key] != nil }
        return commands
    }

    public mutating func releaseAll() -> [SpatialOutputCommand] {
        var commands: [SpatialOutputCommand] = []
        let held = owned
        let pending = Set(pendingOverlap.keys)
        for item in held.union(pending).sorted(by: heldOrder) {
            commands.append(.noteOff(destination: item.destination, channel: item.channel, note: item.note))
        }
        notesByRouting.removeAll()
        generation.removeAll()
        pendingOverlap.removeAll(); overlapRouting.removeAll()
        triggerState.removeAll()
        holdUntilNextRouting.removeAll()
        holdEntries.removeAll()
        holdCells.removeAll()
        toggled.removeAll()
        toggleDisplayCells.removeAll()
        toggleEntries.removeAll()
        lastToggleTime.removeAll()
        return commands
    }

    /// Unintentional loss removes measured gates and overlap tails, while
    /// deliberate latch ownership and entry locks survive until measured exit.
    public mutating func releaseTransient() -> [SpatialOutputCommand] {
        let before = owned.union(pendingOverlap.keys)
        notesByRouting = notesByRouting.filter { holdUntilNextRouting.contains($0.key) }
        pendingOverlap.removeAll(); overlapRouting.removeAll()
        return removedCommands(from: before)
    }

    public mutating func releaseLatched(routingIDs: Set<UUID>) -> [SpatialOutputCommand] {
        guard !routingIDs.isEmpty else { return [] }
        let before = owned.union(pendingOverlap.keys)
        for id in routingIDs.intersection(holdUntilNextRouting) { notesByRouting[id] = nil }
        toggled = toggled.filter { !routingIDs.contains($0.key.routingID) }
        lastToggleTime = lastToggleTime.filter { !routingIDs.contains($0.key.routingID) }
        return removedCommands(from: before)
    }

    /// Editing one painted surface leaves separate loops in the layer intact.
    internal mutating func retainToggleCells(from current: CompiledInstrument?, to replacement: CompiledInstrument) -> [SpatialOutputCommand] {
        let before = owned.union(pendingOverlap.keys)
        func supported(_ key: ToggleCell) -> Bool {
            guard let current, current.revision.session == replacement.revision.session,
                  let old = current.layers.first(where: { $0.routings.contains { $0.id == key.routingID } }),
                  let new = replacement.layers.first(where: { $0.id == old.id }),
                  containsCell(key.cell, in: old.cells), containsCell(key.cell, in: new.cells),
                  let routing = old.routings.first(where: { $0.id == key.routingID }),
                  let newRouting = new.routings.first(where: { $0.id == key.routingID }),
                  routing.target == newRouting.target, routing.program == newRouting.program, old.midiTarget == new.midiTarget else { return false }
            let oldRegion = Set(routing.toggleRegionByCell.filter { $0.value == key.cell }.map(\.key))
            let newRegion = Set(newRouting.toggleRegionByCell.filter { $0.value == key.cell }.map(\.key))
            guard oldRegion == newRegion else { return false }
            let oldHandle = CompiledActiveCell(layerID: old.id, cell: key.cell, revision: current.revision)
            let newHandle = CompiledActiveCell(layerID: new.id, cell: key.cell, revision: replacement.revision)
            let oldValue = try? current.evaluate(active: [old.id: oldHandle], activeLayerIDs: [old.id]).first { $0.routingID == key.routingID }?.value
            let newValue = try? replacement.evaluate(active: [new.id: newHandle], activeLayerIDs: [new.id]).first { $0.routingID == key.routingID }?.value
            guard let oldValue, let newValue else { return false }
            return oldValue == newValue
        }
        toggled = toggled.filter { supported($0.key) }
        toggleEntries = toggleEntries.filter(supported)
        lastToggleTime = lastToggleTime.filter { supported($0.key) }
        return removedCommands(from: before)
    }

    private mutating func removedCommands(from before: Set<Held>) -> [SpatialOutputCommand] {
        let after = owned.union(pendingOverlap.keys)
        generation = generation.filter { after.contains($0.key) }
        return before.subtracting(after).sorted(by: heldOrder).map {
            .noteOff(destination: $0.destination, channel: $0.channel, note: $0.note)
        }
    }

    /// Löst nur eine Ressourcenhälfte; die andere bleibt im Ledger und darf
    /// bei einem AU-Wechsel nicht versehentlich MIDI-Offs erhalten.
    public mutating func release(destination: SpatialOutputDestination) -> [SpatialOutputCommand] {
        var commands: [SpatialOutputCommand] = []
        let held = owned.filter { $0.destination == destination }
        let pending = Set(pendingOverlap.keys).filter { $0.destination == destination }
        for item in held.union(pending).sorted(by: heldOrder) {
            commands.append(.noteOff(destination: item.destination, channel: item.channel, note: item.note))
        }
        for routingID in notesByRouting.keys {
            notesByRouting[routingID]?.subtract(held)
        }
        for key in Array(toggled.keys) { toggled[key]?.subtract(held) }
        toggled = toggled.filter { !$0.value.isEmpty }
        for item in held.union(pending).sorted(by: heldOrder) {
            generation.removeValue(forKey: item)
            pendingOverlap.removeValue(forKey: item); overlapRouting[item] = nil
        }
        return commands
    }

    private mutating func releaseChannel(destination: SpatialOutputDestination, channel: UInt8) -> [SpatialOutputCommand] {
        let affected = owned.union(pendingOverlap.keys)
            .filter { $0.destination == destination && $0.channel == channel }
        for id in Array(notesByRouting.keys) { notesByRouting[id]?.subtract(affected) }
        for key in Array(toggled.keys) { toggled[key]?.subtract(affected) }
        toggled = toggled.filter { !$0.value.isEmpty }
        for item in affected {
            generation.removeValue(forKey: item)
            pendingOverlap.removeValue(forKey: item); overlapRouting[item] = nil
        }
        return affected.sorted(by: heldOrder).map {
            .noteOff(destination: $0.destination, channel: $0.channel, note: $0.note)
        }
    }

    /// Der gemeinsame Ressourcenbesitzer hat die betreffende Hälfte bereits
    /// atomar gelöst. Der Ledger darf sie deshalb nicht ein zweites Mal an
    /// eine inzwischen ungültige Senke senden.
    @_spi(Legacy) public mutating func acknowledgeExternalRelease(destination: SpatialOutputDestination) {
        let held = owned.filter { $0.destination == destination }
        let pending = Set(pendingOverlap.keys).filter { $0.destination == destination }
        for routingID in notesByRouting.keys {
            notesByRouting[routingID]?.subtract(held)
        }
        for key in Array(toggled.keys) { toggled[key]?.subtract(held) }
        toggled = toggled.filter { !$0.value.isEmpty }
        for item in held.union(pending).sorted(by: heldOrder) {
            generation.removeValue(forKey: item)
            pendingOverlap.removeValue(forKey: item); overlapRouting[item] = nil
        }
    }

    /// Prüft einen verzögerten Overlap-Off auf seine Generation.
    public mutating func completeScheduledOff(_ command: SpatialOutputCommand) -> SpatialOutputCommand? {
        guard case let .scheduleOff(destination, channel, note, expected, _) = command else { return nil }
        let held = Held(destination: destination, channel: channel, note: note)
        guard generation[held] == expected, pendingOverlap[held] == expected,
              !owned.contains(held) else { return nil }
        pendingOverlap[held] = nil; overlapRouting[held] = nil
        return .noteOff(destination: destination, channel: channel, note: note)
    }

    private mutating func replace(
        _ desired: Set<Held>, routingID: UUID, transition: SpatialNoteTransition,
        outgoingHoldIDs: Set<UUID> = [],
        commonNotes: SpatialCommonNotes = .keep,
        commands: inout [SpatialOutputCommand]
    ) {
        if transition == .holdUntilNext && desired.isEmpty { return }
        let original = notesByRouting[routingID] ?? []
        // A new Hold entry may have exactly the same pitches as the old owner.
        guard desired != original || transition == .holdUntilNext else { return }
        var previous = original
        let before = owned.union(pendingOverlap.keys)
        if !desired.isEmpty && (transition == .holdUntilNext || !desired.subtracting(previous).isEmpty) {
            // Transfer common pitches before releasing the former owner, so
            // physical ownership emits neither an Off nor a duplicate On.
            if coalescesSharedNotes { notesByRouting[routingID] = desired.union(previous) }
            releaseOutgoingHolds(outgoingHoldIDs.subtracting([routingID]), for: desired, commands: &commands)
        }
        if transition == .holdUntilNext {
            if coalescesSharedNotes {
                notesByRouting[routingID] = desired
                original.subtracting(desired).sorted(by: heldOrder).forEach { off($0, commands: &commands) }
                previous = desired.intersection(before)
            } else {
                releaseOutgoingHolds([routingID], for: desired, commands: &commands)
                previous = []
            }
        }
        if commonNotes == .retrigger && coalescesSharedNotes {
            let shared = desired.intersection(before)
            for note in shared.sorted(by: heldOrder) {
                commands.append(.noteOff(destination: note.destination, channel: note.channel, note: note.note))
                commands.append(.noteOn(destination: note.destination, channel: note.channel, note: note.note))
            }
        }
        let removed = previous.subtracting(desired)
        let added = desired.subtracting(previous)
        let alreadySounding = before
        if coalescesSharedNotes { notesByRouting[routingID] = desired }
        switch transition {
        case .retrigger:
            removed.sorted(by: heldOrder).forEach { off($0, commands: &commands) }
            added.sorted(by: heldOrder).forEach { on($0, alreadySounding: coalescesSharedNotes && alreadySounding.contains($0), commands: &commands) }
        case .legato:
            added.sorted(by: heldOrder).forEach { on($0, alreadySounding: coalescesSharedNotes && alreadySounding.contains($0), commands: &commands) }
            removed.sorted(by: heldOrder).forEach { off($0, commands: &commands) }
        case .overlap(let milliseconds):
            added.sorted(by: heldOrder).forEach { on($0, alreadySounding: coalescesSharedNotes && alreadySounding.contains($0), commands: &commands) }
            removed.sorted(by: heldOrder).forEach { item in
                guard !coalescesSharedNotes || !owned.contains(item) else { return }
                let next = (generation[item] ?? 0) &+ 1
                generation[item] = next
                pendingOverlap[item] = next
                overlapRouting[item] = routingID
                commands.append(.scheduleOff(
                    destination: item.destination, channel: item.channel, note: item.note,
                    generation: next, delayMilliseconds: max(0, milliseconds)
                ))
            }
        case .holdUntilNext:
            desired.sorted(by: heldOrder).forEach {
                on($0, alreadySounding: coalescesSharedNotes && alreadySounding.contains($0), commands: &commands)
            }
        case .toggle:
            preconditionFailure("Toggle ownership requires a measured cell")
        }
        notesByRouting[routingID] = desired
    }

    private mutating func releaseOutgoingHolds(
        _ routingIDs: Set<UUID>, for desired: Set<Held>, commands: inout [SpatialOutputCommand]
    ) {
        let channels = Set(desired.map { Channel(destination: $0.destination, number: $0.channel) })
        var released: Set<Held> = []
        for id in routingIDs {
            let affected = (notesByRouting[id] ?? []).filter {
                channels.contains(Channel(destination: $0.destination, number: $0.channel))
            }
            notesByRouting[id]?.subtract(affected)
            released.formUnion(affected)
        }
        released.sorted(by: heldOrder).forEach { off($0, commands: &commands) }
    }

    private mutating func on(_ note: Held, alreadySounding: Bool = false, commands: inout [SpatialOutputCommand]) {
        generation[note, default: 0] &+= 1
        pendingOverlap[note] = nil; overlapRouting[note] = nil
        guard !alreadySounding else { return }
        commands.append(.noteOn(destination: note.destination, channel: note.channel, note: note.note))
    }

    private mutating func off(_ note: Held, commands: inout [SpatialOutputCommand]) {
        guard !coalescesSharedNotes || !owned.contains(note) else { return }
        generation[note, default: 0] &+= 1
        pendingOverlap[note] = nil; overlapRouting[note] = nil
        commands.append(.noteOff(destination: note.destination, channel: note.channel, note: note.note))
    }
}
