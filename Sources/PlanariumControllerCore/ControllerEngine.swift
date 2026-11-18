import Foundation
import PlanariumMusicCore

/// The activation identity a controller gives one played element or sector.
/// A value change (stick travel, trigger pressure) keeps the identity; only a
/// new press, entry or sector change is a new musical entry.
public struct ControllerActivation: LedgerCell, Comparable {
    public let element: ControllerElement
    public let zone: UInt16
    public init(element: ControllerElement, zone: UInt16) { self.element = element; self.zone = zone }
    /// Controller elements are discrete: a Hold owner is never continued by a
    /// neighbouring element, a held chord survives until the next entry.
    public func continuesContact(from previous: ControllerActivation) -> Bool { false }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.element == rhs.element ? lhs.zone < rhs.zone : lhs.element < rhs.element
    }
}

public typealias ControllerRoutingEvaluation = RoutingEvaluation<ControllerActivation>

/// The pure playing engine of one controller source. It owns this source's
/// note ledger only; the scanner keeps its own. Output destinations are data.
public struct ControllerEngine: Sendable {
    public private(set) var layout: CompiledControllerLayout?
    public private(set) var session: UUID?
    public private(set) var lastSequence: UInt64 = 0
    /// Measured state of the device; the on-screen simulation is merged on top.
    public private(set) var measured: ControllerState = .neutral
    public private(set) var simulated: ControllerState = .neutral
    /// Elements whose gate is open after hysteresis.
    public private(set) var activeElements: Set<ControllerElement> = []
    /// Current sector per positional element (after hysteresis), for display and sector assignments.
    public private(set) var sectors: [ControllerElement: (index: Int, count: Int)] = [:]
    private var scaleIndex: [UUID: Int] = [:]
    private var entryCounter: [UUID: UInt64] = [:]
    private var programSent: Set<UUID> = []
    /// Physical shared-note ownership, as the scanner: two pads on one pitch
    /// sound it once, and it ends only with its last owner.
    private var ledger = NoteLedger<ControllerActivation>(coalescesSharedNotes: true)
    private var pendingOffs: [(deadline: Double, command: SpatialOutputCommand)] = []
    private var lastTime: Double = 0
    /// Assignments that stay silent until their element is really released:
    /// after Panic, after an audio release, already held at a new connection,
    /// or new/changed by a layout while held. Nothing plays without a new press.
    private var blocked: Set<UUID> = []
    /// The next device report is the first of a connection (or after an
    /// overload): what it holds is a baseline, not a press.
    private var awaitsFirstReport = false
    /// The same for the on-screen controller after an overload.
    private var awaitsFirstSimulation = false
    /// Every control this source sent, at the destination it was really sent to.
    private var sentControls: [ControlReceipt: UUID] = [:]
    /// Controls whose element is open: on release they return to their rest value.
    private var openControls: [UUID: (receipt: ControlReceipt, rest: Double)] = [:]

    /// One sent control at its resolved destination.
    struct ControlReceipt: Hashable {
        let destination: SpatialOutputDestination
        let target: SpatialRoutingTarget
    }

    public init() {}

    public private(set) var deviceName: String?
    public var isConnected: Bool { session != nil }
    public var state: ControllerState { measured.merging(simulated) }
    /// The earliest scheduled note-off of this source.
    public var nextDeadline: Double? { pendingOffs.map(\.deadline).min() }
    /// Output channels whose controls (sustain, pitch bend …) this source owns.
    /// Another source's loss must not reset them.
    public var ownedControlChannels: [(destination: SpatialOutputDestination, channel: UInt8)] {
        guard let layout else { return [] }
        return layout.playable.compactMap { assignment in
            guard OutputOwnership.outputClass(of: assignment.routing.target) == .controls,
                  let channel = assignment.routing.target.midiChannel,
                  let destination = Self.destination(of: assignment, layout: layout) else { return nil }
            return (destination, channel)
        }
    }
    /// Audio Unit strips whose notes this source owns (their arpeggios belong to it).
    public var ownedNoteStrips: Set<UUID> {
        Set(layout?.ownedTargets[.notes]?.compactMap { key -> UUID? in
            if case .audioUnit(let strip) = key { return strip }
            return nil
        } ?? [])
    }
    public var soundingNoteCount: Int { ledger.soundingNoteCount }
    public var soundingEvents: [MusicEvent] { Self.events(ledger.soundingCommands, layout: layout) }
    /// Assignment ids whose element is currently played (for the colored display).
    public var playingAssignmentIDs: Set<UUID> {
        guard let layout else { return [] }
        return Set(layout.playable.filter { isGateOpen($0) }.map(\.id))
    }

    // MARK: Inputs

    /// A new layout keeps the notes and controls of unchanged assignments. A
    /// removed, changed or newly refused assignment is released at its OLD
    /// target first (notes, holds, toggles, sustain/bend/pressure); only then
    /// the new layout applies. A new or changed assignment whose element is
    /// already held stays silent until released: installing never strikes.
    public mutating func install(_ next: CompiledControllerLayout?, at time: Double) -> [MusicEvent] {
        let old = layout
        func resolved(_ compiled: CompiledControllerLayout?) -> [UUID: (ControllerAssignment, SpatialOutputDestination?)] {
            guard let compiled else { return [:] }
            return Dictionary(compiled.playable.map { ($0.routing.id, ($0, Self.destination(of: $0, layout: compiled))) }, uniquingKeysWith: { a, _ in a })
        }
        let before = resolved(old), after = resolved(next)
        let kept = Set(before.keys.filter { id in after[id].map { $0.0 == before[id]!.0 && $0.1 == before[id]!.1 } ?? false })
        let leaving = Set(before.keys).subtracting(kept)
        var commands = ledger.releaseLatched(routingIDs: leaving)
        commands += ledger.retainToggles { routingID, _ in kept.contains(routingID) }
        // Overlap tails of leaving owners end here; their stale scheduled offs
        // then fail the ledger's generation check and are dropped.
        commands += ledger.retainSupported(by: [], preservingRoutingIDs: kept)
        var events = Self.events(commands, layout: old)
        events += returnControls(of: leaving) + controlResets(routingIDs: leaving)
        layout = next
        scaleIndex = scaleIndex.filter { kept.contains($0.key) }
        programSent = programSent.intersection(kept)
        blocked = blocked.intersection(kept)
        if let next {
            updateGates(next.layout)
            for assignment in next.playable where !kept.contains(assignment.routing.id) && isGateOpen(assignment) {
                blocked.insert(assignment.routing.id)
            }
        }
        return events + evaluate(at: time)
    }

    /// An Audio Unit strip is released (or the audio configuration changed for
    /// all strips): this source's notes and controls there end, its held
    /// elements stay silent until released (no replay of old ownership).
    /// MIDI notes are untouched.
    public mutating func releaseAudio(stripID: UUID?) -> [MusicEvent] {
        func affected(_ destination: SpatialOutputDestination) -> Bool {
            guard case .audioUnit(let strip) = destination else { return false }
            return stripID == nil || strip == stripID
        }
        // Every sounding note counts, overlap tails included: their timer goes
        // only together with the note.
        let destinations = Set(ledger.soundingCommands.compactMap { command -> SpatialOutputDestination? in
            if case let .noteOn(destination, _, _) = command, affected(destination) { return destination }
            return nil
        })
        var commands: [SpatialOutputCommand] = []
        for destination in destinations.sorted(by: { "\($0)" < "\($1)" }) { commands += ledger.release(destination: destination) }
        pendingOffs.removeAll { if case let .scheduleOff(destination, _, _, _, _) = $0.command { return affected(destination) }; return false }
        // Controls there return and reset like on any release of this source.
        let routings = Set(openControls.filter { affected($0.value.receipt.destination) }.keys)
            .union(sentControls.filter { affected($0.key.destination) }.values)
        let controlEvents = returnControls(of: routings) + controlResets(routingIDs: routings)
        for assignment in layout?.playable ?? [] where isGateOpen(assignment) {
            guard let layout, let destination = Self.destination(of: assignment, layout: layout), affected(destination) else { continue }
            blocked.insert(assignment.routing.id)
        }
        return Self.events(commands, layout: layout) + controlEvents
    }

    /// The runtime refused reports (input backlog): this source releases
    /// everything, and what is held stays silent until released, as after
    /// Panic. A refused press is lost; nothing keeps sounding from it.
    /// Reports were refused, so a press may hide in the refused part: the next
    /// device report and the next simulation state are baselines again.
    public mutating func overload() -> [MusicEvent] {
        let released = panic()
        awaitsFirstReport = true; awaitsFirstSimulation = true
        return released
    }

    /// Everything open in the current state stays silent until released.
    private mutating func blockHeld() {
        guard let layout else { return }
        updateGates(layout.layout)
        for assignment in layout.playable where isGateOpen(assignment) { blocked.insert(assignment.routing.id) }
    }

    public mutating func apply(_ event: ControllerInputEvent) -> [MusicEvent] {
        switch event {
        case let .connected(id, name):
            // A new connection starts neutral: what is already held in its
            // first report does not fire until it is released and pressed again.
            let released = release(resetControls: true)
            session = id; lastSequence = 0; measured = .neutral; deviceName = name
            awaitsFirstReport = true
            return released
        case let .state(id, sequence, time, value):
            guard id == session, sequence > lastSequence else { return [] }
            lastSequence = sequence
            measured = value
            if awaitsFirstReport { awaitsFirstReport = false; blockHeld() }
            return evaluate(at: time)
        case let .disconnected(id):
            guard id == session else { return [] }
            session = nil; measured = .neutral; deviceName = nil
            return release(resetControls: true)
        }
    }

    /// The on-screen controller (mouse) plays through the same path.
    public mutating func simulate(_ value: ControllerState, at time: Double) -> [MusicEvent] {
        simulated = value
        if awaitsFirstSimulation { awaitsFirstSimulation = false; blockHeld() }
        return evaluate(at: time)
    }

    /// Time passes without a report: scheduled offs become due.
    public mutating func advance(to time: Double) -> [MusicEvent] {
        lastTime = max(lastTime, time)
        let due = pendingOffs.filter { $0.deadline <= time }
        pendingOffs.removeAll { $0.deadline <= time }
        return Self.events(due.compactMap { ledger.completeScheduledOff($0.command) }, layout: layout)
    }

    /// Panic: everything this source sounds ends; held elements stay silent
    /// until they are released.
    public mutating func panic() -> [MusicEvent] {
        let held = Set(layout?.playable.filter { isGateOpen($0) }.map(\.routing.id) ?? [])
        let released = release(resetControls: true)
        blocked = held
        return released
    }

    /// Stop or preset change: release without blocking.
    public mutating func stop() -> [MusicEvent] { release(resetControls: true) }

    // MARK: Evaluation

    private mutating func evaluate(at time: Double) -> [MusicEvent] {
        lastTime = max(lastTime, time)
        var commands: [SpatialOutputCommand] = []
        let due = pendingOffs.filter { $0.deadline <= time }
        pendingOffs.removeAll { $0.deadline <= time }
        commands += due.compactMap { ledger.completeScheduledOff($0.command) }
        guard let layout else {
            commands += ledger.releaseAll()
            return Self.events(commands, layout: nil)
        }
        updateGates(layout.layout)
        var evaluations: [ControllerRoutingEvaluation] = []
        var programs: [MusicEvent] = []
        var returns: [MusicEvent] = []
        for assignment in layout.playable {
            let routing = assignment.routing
            let open = isGateOpen(assignment)
            if !open { blocked.remove(routing.id) }
            let blocked = self.blocked.contains(routing.id)
            if case .programChange(let selection) = routing.program {
                if open && !blocked && !programSent.contains(routing.id),
                   let destination = Self.destination(of: assignment, layout: layout), let channel = routing.target.midiChannel {
                    programSent.insert(routing.id)
                    programs.append(.programChange(destination: destination, channel: channel, selection: selection))
                } else if !open { programSent.remove(routing.id) }
                continue
            }
            guard !routing.target.isLayerControl, OutputOwnership.outputClass(of: routing.target) != nil else { continue }
            let value = blocked ? Self.inactive(routing.program) : self.value(of: assignment, open: open)
            // Controls follow their element: while open they send, on release
            // they return to the element's rest value once (sustain up, trigger
            // back, stick centred). Other sources' controls are never touched.
            if case .scalar = value, let destination = Self.destination(of: assignment, layout: layout) {
                openControls[routing.id] = (ControlReceipt(destination: destination, target: routing.target), restValue(of: assignment))
            } else if let open = openControls.removeValue(forKey: routing.id) {
                returns.append(Self.controlEvent(open.receipt, routingID: routing.id, value: open.rest))
                if Self.resetValue(open.receipt.target) == open.rest { sentControls[open.receipt] = nil }
            }
            // A toggle is reported only while its element is played, as the scanner
            // reports toggle cells only while occupied: release ends the entry, the
            // latched notes stay with the ledger until the next press.
            if case .notes(let notes, .toggle) = value, notes.isEmpty { continue }
            var evaluation = ControllerRoutingEvaluation(routingID: routing.id, target: routing.target, value: value,
                                                         cell: activation(of: assignment), toggleGuardSeconds: ToggleGuard.defaultSeconds)
            evaluation.midiDestination = Self.destination(of: assignment, layout: layout) ?? .midi
            evaluation.representativeDistanceSquared = Double(layout.playable.firstIndex { $0.id == assignment.id } ?? 0)
            evaluations.append(evaluation)
        }
        commands += ledger.apply(evaluations, profileTime: time)
        var immediate: [SpatialOutputCommand] = []
        for command in commands {
            if case .scheduleOff(_, _, _, _, let delay) = command {
                pendingOffs.append((time + delay / 1_000, command))
            } else { immediate.append(command) }
        }
        for case let .scalar(id, target, _) in immediate {
            if let destination = openControls[id]?.receipt.destination { sentControls[ControlReceipt(destination: destination, target: target)] = id }
        }
        return returns + Self.events(immediate, layout: layout) + programs
    }

    private mutating func updateGates(_ feel: ControllerLayout) {
        let current = state
        var next: Set<ControllerElement> = []
        for element in ControllerElement.allCases {
            let wasOpen = activeElements.contains(element)
            switch element.kind {
            case .button:
                if current.pressed.contains(element) { next.insert(element) }
            case .trigger:
                let value = current.value(element)
                if value >= feel.triggerThreshold || (wasOpen && value >= feel.triggerThreshold / 2) { next.insert(element) }
            case .stick, .surface:
                guard let point = current.position(element) else { sectors[element] = nil; continue }
                let radius = element.kind == .surface ? 0 : (wasOpen ? feel.exitRadius : feel.enterRadius)
                if point.magnitude >= radius && (element.kind == .surface || point.magnitude > 0) { next.insert(element) }
                else { sectors[element] = nil }
            }
        }
        activeElements = next
        // Sector after hysteresis for every sector count in use on an element.
        var counts: [ControllerElement: Set<Int>] = [:]
        for assignment in layout?.playable ?? [] {
            if case let .sector(_, count) = assignment.zone { counts[assignment.element, default: []].insert(count) }
        }
        for (element, set) in counts {
            guard next.contains(element), let point = current.position(element), let count = set.max() else { sectors[element] = nil; continue }
            sectors[element] = (Self.sector(of: point.bearingDegrees, count: count, previous: sectors[element].flatMap { $0.count == count ? $0.index : nil },
                                            hysteresis: feel.sectorHysteresisDegrees), count)
        }
    }

    private func isGateOpen(_ assignment: ControllerAssignment) -> Bool {
        guard activeElements.contains(assignment.element) else { return false }
        switch assignment.zone {
        case .whole: return true
        case let .sector(index, count):
            guard let current = sectors[assignment.element] else { return false }
            if current.count == count { return current.index == index }
            // A coarser division of the same element: derive from the bearing.
            guard let point = state.position(assignment.element) else { return false }
            return Self.sector(of: point.bearingDegrees, count: count, previous: nil, hysteresis: 0) == index
        }
    }

    private func activation(of assignment: ControllerAssignment) -> ControllerActivation {
        switch assignment.zone {
        case .whole: return .init(element: assignment.element, zone: 0)
        case let .sector(index, _): return .init(element: assignment.element, zone: UInt16(index + 1))
        }
    }

    private mutating func value(of assignment: ControllerAssignment, open: Bool) -> SpatialEvaluatedValue {
        let program = assignment.routing.program
        let id = assignment.routing.id
        guard open else {
            scaleIndex[id] = nil
            return Self.inactive(program)
        }
        switch program {
        case .programChange: return .inactive
        case .constant(let value): return .scalar(value)
        case let .singleNote(note, velocity, transition):
            return .notes([.init(number: UInt8(clamping: min(max(note, 0), 127)), velocity: velocity)], transition: transition)
        case let .chord(notes, velocity, transition):
            return .notes(Set(notes.map { SpatialPlayedNote(number: UInt8(clamping: min(max($0, 0), 127)), velocity: velocity) }), transition: transition)
        case let .continuous(minimum, maximum, degrees, curve):
            let fraction = continuousFraction(assignment, programDegrees: degrees)
            let shaped: Double
            switch curve {
            case .linear: shaped = fraction
            case .easeIn: shaped = fraction * fraction
            case .easeOut: shaped = 1 - pow(1 - fraction, 2)
            }
            return .scalar(minimum + (maximum - minimum) * shaped)
        case let .scale(root, low, high, scale, degrees, ascending, transition):
            let notes = Self.allowedNotes(root: root, low: low, high: high, scale: scale)
            guard !notes.isEmpty else { return .notes([], transition: transition) }
            let index = scaleNoteIndex(assignment, count: notes.count, startBearing: SurfaceBearing.fromProgram(degrees), ascending: ascending)
            return .notes([.init(number: UInt8(clamping: notes[index]), velocity: Self.velocity(assignment, state: state))], transition: transition)
        case let .randomScale(root, low, high, scale, seed, transition):
            let notes = Self.allowedNotes(root: root, low: low, high: high, scale: scale)
            guard !notes.isEmpty else { return .notes([], transition: transition) }
            if scaleIndex[id] == nil {
                entryCounter[id, default: 0] &+= 1
                scaleIndex[id] = Int(Self.mix(seed ^ entryCounter[id]!) % UInt64(notes.count))
            }
            return .notes([.init(number: UInt8(clamping: notes[scaleIndex[id]!]), velocity: Self.velocity(assignment, state: state))], transition: transition)
        }
    }

    /// 0…1 for a continuous control: a trigger's travel, a stick's or touch
    /// position projected on the program axis, 1 for a pressed button.
    private func continuousFraction(_ assignment: ControllerAssignment, programDegrees: Double) -> Double {
        switch assignment.element.kind {
        case .button: return 1
        case .trigger: return state.value(assignment.element)
        case .stick, .surface:
            guard let point = state.position(assignment.element) else { return 0 }
            let radians = programDegrees * .pi / 180
            let projection = point.x * cos(radians) + point.y * sin(radians)
            return min(max((projection + 1) / 2, 0), 1)
        }
    }

    /// Scale notes around a stick (clockwise from the start bearing), along a
    /// trigger's travel, or the lowest note for a button. The note changes only
    /// after the position moved clearly into the neighbouring step.
    private mutating func scaleNoteIndex(_ assignment: ControllerAssignment, count: Int, startBearing: Double, ascending: Bool) -> Int {
        let id = assignment.routing.id
        let fraction: Double
        switch assignment.element.kind {
        case .button: fraction = 0
        case .trigger: fraction = state.value(assignment.element)
        case .stick, .surface:
            guard let point = state.position(assignment.element) else { fraction = 0; break }
            let relative = (point.bearingDegrees - startBearing + 720).truncatingRemainder(dividingBy: 360)
            fraction = relative / 360
        }
        let adjusted = ascending ? fraction : 1 - fraction
        let raw = min(Int((adjusted * Double(count)).rounded(.down)), count - 1)
        if let previous = scaleIndex[id], previous != raw {
            // Hysteresis: stay unless the position is a quarter step beyond the border.
            let position = adjusted * Double(count)
            let lower = Double(previous) - 0.25, upper = Double(previous + 1) + 0.25
            if position >= lower && position <= upper { return previous }
        }
        scaleIndex[id] = raw
        return raw
    }

    private mutating func release(resetControls: Bool) -> [MusicEvent] {
        let commands = ledger.releaseAll()
        pendingOffs.removeAll()
        activeElements.removeAll(); sectors.removeAll(); scaleIndex.removeAll(); programSent.removeAll()
        simulated = .neutral
        var events = Self.events(commands, layout: layout)
        if resetControls { events += returnControls(of: nil) + controlResets(routingIDs: nil) }
        return events
    }

    /// Open controls of the given routings (all for nil) return to their rest value.
    private mutating func returnControls(of routingIDs: Set<UUID>?) -> [MusicEvent] {
        var events: [MusicEvent] = []
        for (id, open) in openControls.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where routingIDs?.contains(id) ?? true {
            events.append(Self.controlEvent(open.receipt, routingID: id, value: open.rest))
            openControls[id] = nil
            if Self.resetValue(open.receipt.target) == open.rest { sentControls[open.receipt] = nil }
        }
        return events
    }

    /// Source-local control reset at the destination each control was really
    /// sent to: sustain and modulation to 0, pitch bend to its centre, pressure
    /// to 0. Other controls keep their last value. Only this source's receipts.
    private mutating func controlResets(routingIDs: Set<UUID>?) -> [MusicEvent] {
        var events: [MusicEvent] = []
        for (receipt, id) in sentControls.sorted(by: { "\($0.key)" < "\($1.key)" }) where routingIDs?.contains(id) ?? true {
            sentControls[receipt] = nil
            guard let reset = Self.resetValue(receipt.target) else { continue }
            events.append(Self.controlEvent(receipt, routingID: id, value: reset))
        }
        return events
    }

    static func resetValue(_ target: SpatialRoutingTarget) -> Double? {
        switch target {
        case .midiCC(_, 64), .audioUnitCC(_, 64, _), .midiCC(_, 1), .audioUnitCC(_, 1, _): return 0
        case .midiPitchBend, .audioUnitPitchBend: return 8192.0 / 16383
        case .midiChannelPressure, .audioUnitChannelPressure: return 0
        default: return nil
        }
    }

    static func controlEvent(_ receipt: ControlReceipt, routingID: UUID, value: Double) -> MusicEvent {
        receipt.target.destination == .midi
            ? .midiValue(destination: receipt.destination, target: receipt.target, value: value)
            : .scalar(routingID: routingID, target: receipt.target, value: value)
    }

    /// The value a control returns to when its element is let go: a switched
    /// control (constant) to 0, a continuous one to its value at rest
    /// (trigger up, stick or touch centred, button up).
    private func restValue(of assignment: ControllerAssignment) -> Double {
        switch assignment.routing.program {
        case let .continuous(minimum, maximum, _, curve):
            let fraction: Double = assignment.element.isPositional ? 0.5 : 0
            let shaped: Double
            switch curve {
            case .linear: shaped = fraction
            case .easeIn: shaped = fraction * fraction
            case .easeOut: shaped = 1 - pow(1 - fraction, 2)
            }
            return min(max(minimum + (maximum - minimum) * shaped, 0), 1)
        default: return 0
        }
    }

    // MARK: Helpers

    static func inactive(_ program: SpatialValueProgram) -> SpatialEvaluatedValue {
        switch program {
        case let .singleNote(_, _, transition), let .chord(_, _, transition),
             let .scale(_, _, _, _, _, _, transition), let .randomScale(_, _, _, _, _, transition):
            return .notes([], transition: transition)
        case .constant, .continuous, .programChange: return .inactive
        }
    }

    /// A trigger played as a note uses its travel at entry as velocity; other
    /// elements play the fixed velocity 100. No pressure is invented.
    static func velocity(_ assignment: ControllerAssignment, state: ControllerState) -> UInt8 {
        guard assignment.element.kind == .trigger else { return 100 }
        return UInt8(clamping: max(1, Int((state.value(assignment.element) * 127).rounded())))
    }

    static func allowedNotes(root: Int, low: Int, high: Int, scale: SpatialScale) -> [Int] {
        let lower = min(max(min(low, high), 0), 127), upper = min(max(max(low, high), 0), 127)
        let classes = Set(scale.semitoneOffsets.map { (($0 + root) % 12 + 12) % 12 })
        return Array(lower...upper).filter { classes.contains(($0 % 12 + 12) % 12) }
    }

    static func sector(of bearing: Double, count: Int, previous: Int?, hysteresis: Double) -> Int {
        let width = 360 / Double(count)
        let shifted = (bearing + width / 2).truncatingRemainder(dividingBy: 360)
        let raw = Int(shifted / width) % count
        guard let previous, previous != raw else { return raw }
        // Stay in the previous sector until the bearing is `hysteresis` past its border.
        let centre = Double(previous) * width
        var delta = abs(bearing - centre).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta <= width / 2 + hysteresis ? previous : raw
    }

    static func mix(_ seed: UInt64) -> UInt64 {
        var value = seed &* 0x9E3779B97F4A7C15
        value ^= value >> 30; value &*= 0xBF58476D1CE4E5B9
        value ^= value >> 27; value &*= 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    static func destination(of assignment: ControllerAssignment, layout: CompiledControllerLayout) -> SpatialOutputDestination? {
        let target = assignment.routing.target
        if let strip = target.stripID, target.destination == .audioUnit { return .audioUnit(stripID: strip) }
        guard target.destination == .midi else { return nil }
        if let endpoint = assignment.midiEndpointID, endpoint != layout.sumEndpoint { return .midiEndpoint(uniqueID: endpoint) }
        return .midi
    }

    static func events(_ commands: [SpatialOutputCommand], layout: CompiledControllerLayout?) -> [MusicEvent] {
        commands.compactMap { command in
            switch command {
            case let .noteOn(destination, channel, note): return .noteOn(destination: destination, channel: channel, note: note)
            case let .noteOff(destination, channel, note): return .noteOff(destination: destination, channel: channel, note: note)
            case let .scalar(id, target, value):
                let clamped = min(max(value, 0), 1)
                if target.destination == .midi {
                    let assignment = layout?.playable.first { $0.routing.id == id }
                    let destination = assignment.flatMap { a in layout.flatMap { destination(of: a, layout: $0) } } ?? .midi
                    return .midiValue(destination: destination, target: target, value: clamped)
                }
                return .scalar(routingID: id, target: target, value: clamped)
            case let .boolean(id, target, value):
                if target.destination == .midi {
                    let assignment = layout?.playable.first { $0.routing.id == id }
                    let destination = assignment.flatMap { a in layout.flatMap { destination(of: a, layout: $0) } } ?? .midi
                    return .midiValue(destination: destination, target: target, value: value ? 1 : 0)
                }
                return .boolean(routingID: id, target: target, value: value)
            case let .allNotesOff(destination, channel): return .allNotesOff(destination: destination, channel: channel)
            case .scheduleOff: return nil
            }
        }
    }
}

/// Program angle (mathematical, counter-clockwise from +x) to bearing
/// (clockwise from straight up), the convention of `SurfaceAxis`.
enum SurfaceBearing {
    static func fromProgram(_ degrees: Double) -> Double {
        let bearing = (90 - degrees).truncatingRemainder(dividingBy: 360)
        return bearing < 0 ? bearing + 360 : bearing
    }
}

/// What the stage shows of a controller source: its merged state, the colored
/// assignments now playing and the selected sectors.
public struct ControllerDisplay: Equatable, Sendable {
    public let state: ControllerState
    public let playingAssignmentIDs: Set<UUID>
    public let sectors: [ControllerElement: Int]
    public let deviceName: String?
    public init(state: ControllerState = .neutral, playingAssignmentIDs: Set<UUID> = [], sectors: [ControllerElement: Int] = [:], deviceName: String? = nil) {
        self.state = state; self.playingAssignmentIDs = playingAssignmentIDs; self.sectors = sectors; self.deviceName = deviceName
    }
    public static let idle = ControllerDisplay()
}

extension ControllerEngine {
    public var display: ControllerDisplay {
        .init(state: state, playingAssignmentIDs: playingAssignmentIDs, sectors: sectors.mapValues(\.index), deviceName: deviceName)
    }
}
