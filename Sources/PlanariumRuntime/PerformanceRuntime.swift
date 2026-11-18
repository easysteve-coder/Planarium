// Q shell: unchecked Sendable is confined to this owner. Musical state,
// router and deadline handles are touched only on the one serial Q. Ingress
// metadata is touched only under ingressLock. Immutable values cross queues.
// Public calls enqueue. Control acknowledgements and scene callbacks dispatch
// asynchronously to Main; note-producer callbacks explicitly execute on Q.
import Dispatch
import Foundation
import PlanariumDomain

public final class PerformanceRuntime: @unchecked Sendable {
    private enum Command: Sendable {
        case tempoChanged
        case arpeggioDeadline(UInt64)
        case monitorVisible(Bool)
        case play(PlayInput)
        case frame(ProfileFrame)
        case panic(Double)
        case attach(OutputPort)
        case retire(UUID, @Sendable () -> Void)
        case terminate(@Sendable () -> Void)
        case barrier(@Sendable () -> Void)
        case beginPlan(UUID, CompiledActiveCell, @Sendable (NotePlanToken?) -> Void)
        case plan(PlannedNote, @Sendable (NotePlanResult) -> Void)
        case cancelPlans(UUID?)
        case noteDeadline(UInt64)
        case deadline(UInt64)
        case backlog(UUID)
    }
    private let q = DispatchQueue(label: "de.planarium.performance", qos: .userInteractive)
    private let hostClock: HostMusicalClock
    private var tempoWake: DispatchSourceUserDataAdd?
    private var tempoWakeID: UUID?
    private var arpeggios: [UUID: ArpeggioProducer] = [:]
    private var inhibitedArpeggios: Set<UUID> = []
    private var inhibitedInputs: [UUID: [ArpeggioProducer.Input]] = [:]
    private var failedArpeggios: Set<UUID> = []
    private var arpeggioTimer: RuntimeCancellation?
    private var arpeggioGeneration: UInt64 = 0
    private let clock: any RuntimeClock
    private let noteClock: any RuntimeClock
    private var noteTimer: RuntimeCancellation?
    private var noteTimerGeneration: UInt64 = 0
    private var planSources: [UUID: CompiledActiveCell] = [:]
    public let mailbox: DisplayFrameMailbox
    private var state = PlayState()
    private var sleeping = false
    private var router = OutputRouter()
    private let releaseJournal = OutputReleaseJournal()
    /// Runtime publishes scene state on Main after the measured control edge.
    /// It never calls authoring code synchronously from Q.
    public var onSceneChanged: (@Sendable (RuntimeSceneSnapshot) -> Void)? {
        get { ingressLock.lock(); defer { ingressLock.unlock() }; return sceneCallback }
        set { ingressLock.lock(); sceneCallback = newValue; ingressLock.unlock() }
    }
    private var sceneCallback: (@Sendable (RuntimeSceneSnapshot) -> Void)?
    public var unconfirmedNoteOffs: [UnconfirmedNoteOff] { releaseJournal.snapshot() }
    private var timer: RuntimeCancellation?
    private var scheduledDeadline: Double?
    private var timerGeneration: UInt64 = 0

    private let ingressLock = NSLock()
    private var commands: [Command?] = []
    private var commandHead = 0
    private var queuedProfiles = 0
    private var ingressSessionID: UUID?
    private let profileCapacity: Int
    /// PLS streams in both 90- and 361-point modes are measured at 25 Hz.
    public static let profileRateHz: Double = 25
    public static let latencyBudgetSeconds: Double = 2
    private var backlogStatus: InputBacklogStatus = .ready
    public var inputBacklogStatus: InputBacklogStatus {
        ingressLock.lock(); defer { ingressLock.unlock() }
        return backlogStatus
    }
    private var overflows: UInt64 = 0
    private var draining = false
    private var discarded: UInt64 = 0
    private var processed: UInt64 = 0
    private let timings = RuntimeTimingRecorder()
    public var diagnostics: RuntimeDiagnostics {
        ingressLock.lock()
        let counts = (processed, discarded, overflows)
        ingressLock.unlock()
        return timings.snapshot(processed: counts.0, discarded: counts.1, overflow: counts.2)
    }
    public var diagnosticTime: Double { clock.now }

    public init(clock: any RuntimeClock, mailbox: DisplayFrameMailbox, profileCapacity: Int? = nil, noteClock: (any RuntimeClock)? = nil, hostClock: HostMusicalClock = HostMusicalClock()) {
        let budgetCapacity = Int(Self.profileRateHz * Self.latencyBudgetSeconds)
        self.profileCapacity = max(1, min(profileCapacity ?? budgetCapacity, budgetCapacity))
        self.hostClock = hostClock
        self.clock = clock
        self.noteClock = noteClock ?? NotePlanningClock()
        self.mailbox = mailbox
        let wake = DispatchSource.makeUserDataAddSource(queue: q)
        wake.setEventHandler { [weak self] in self?.process(.tempoChanged) }
        wake.activate(); tempoWake = wake
        tempoWakeID = hostClock.addTempoWake(wake)
    }
    deinit {
        if let id = tempoWakeID { hostClock.removeTempoWake(id) }
        tempoWake?.cancel(); timer?.cancel(); noteTimer?.cancel(); arpeggioTimer?.cancel()
    }
    /// The producer callback runs on Q and must never wait for Main.
    public func beginNotePlan(owner: UUID, source: CompiledActiveCell, ready: @escaping @Sendable (NotePlanToken?) -> Void) {
        enqueue(.beginPlan(owner, source, ready))
    }
    /// Completion is a Q-side queue-acceptance result, not a render receipt.
    public func planNote(_ note: PlannedNote, completion: @escaping @Sendable (NotePlanResult) -> Void = { _ in }) {
        enqueue(.plan(note, completion))
    }
    public func cancelNotePlans(owner: UUID? = nil) { enqueue(.cancelPlans(owner)) }
    public func setOutputMonitorVisible(_ visible: Bool) { enqueue(.monitorVisible(visible)) }
    public func frame(_ frame: ProfileFrame) {
        ingressLock.lock()
        guard frame.sessionID == ingressSessionID else {
            discarded &+= 1
            ingressLock.unlock()
            return
        }
        if backlogStatus == .overloaded {
            overflows &+= 1; discarded &+= 1
        } else if queuedProfiles < profileCapacity, clock.now - frame.time <= Self.latencyBudgetSeconds {
            commands.append(.frame(frame)); queuedProfiles += 1
        } else {
            overflows &+= 1
            discarded &+= 1
            beginBacklogLocked(session: frame.sessionID)
        }
        startDrainLocked()
        ingressLock.unlock()
    }
    /// Caller holds ingressLock. Keep every control/lifecycle command in FIFO
    /// order, discard only profiles, and enqueue a single complete release.
    private func beginBacklogLocked(session: UUID, enqueueRelease: Bool = true) {
        guard backlogStatus != .overloaded else { return }
        backlogStatus = .overloaded
        mailbox.notifyEvidenceChanged()
        for index in commandHead..<commands.count {
            if case .frame? = commands[index] {
                commands[index] = nil; discarded &+= 1
            }
        }
        commands = Array(commands[commandHead...].compactMap { $0 })
        commandHead = 0; queuedProfiles = 0
        if enqueueRelease { commands.append(.backlog(session)) }
    }
    public func install(_ instrument: CompiledInstrument) { enqueue(.play(.install(instrument))) }
    public func sessionBegan(_ id: UUID) { enqueue(.play(.sessionBegan(id))) }
    public func sessionEnded(_ id: UUID, reason: InputSessionEndReason = .userRequested) { enqueue(.play(.sessionEnded(id, reason: reason))) }
    public func audition(_ point: MetricScanPoint?) { enqueue(.play(.audition(point, time: clock.now))) }
    public func panic() { enqueue(.panic(clock.now)) }
    public func releaseAudioForConfigurationChange() { enqueue(.play(.audioConfigurationChanged)) }
    public func releaseAudioChannel(_ id: UUID) { enqueue(.play(.releaseAudioChannel(id))) }
    public func stop() { enqueue(.play(.stop)) }
    public func selectScene(_ id: UUID) { enqueue(.play(.selectScene(id))) }
    public func sleep() { enqueue(.play(.sleep)) }
    public func wake() { enqueue(.play(.wake)) }
    public func terminate(ack: @escaping @Sendable () -> Void) { enqueue(.terminate(ack)) }
    public func acknowledge(_ ack: @escaping @Sendable () -> Void) { enqueue(.barrier(ack)) }
    public func attach(_ port: OutputPort) { enqueue(.attach(port)) }
    public func retire(_ id: UUID, ack: @escaping @Sendable () -> Void) { enqueue(.retire(id, ack)) }
    public func detectionChanged(_ instrument: CompiledInstrument) { enqueue(.play(.detectionChanged(instrument))) }
    public func roomContour(_ contour: SpatialRoomContour?) { enqueue(.play(.roomContour(contour))) }

    private func enqueue(_ command: Command) {
        ingressLock.lock()
        switch command {
        case .play(.sessionBegan(let id)): ingressSessionID = id
        case .play(.sessionEnded(let id, _)):
            if ingressSessionID == id { ingressSessionID = nil }
        case .terminate: ingressSessionID = nil
        default: break
        }
        commands.append(command)
        startDrainLocked()
        ingressLock.unlock()
    }
    private func startDrainLocked() {
        guard !draining else { return }
        draining = true
        q.async { self.drainOne() }
    }
    private func drainOne() {
        ingressLock.lock()
        let command = commandHead < commands.count ? commands[commandHead] : nil
        if let command {
            // A consumed attach must release its captured boundary NOW, not
            // retain an AU behind queued commands after retire has acknowledged.
            commands[commandHead] = nil
            commandHead += 1
            if commandHead == commands.count {
                commands.removeAll(keepingCapacity: true)
                commandHead = 0
            } else if commandHead >= 1_024 && commandHead >= commands.count / 2 {
                commands.removeFirst(commandHead)
                commandHead = 0
            }
            if case .frame = command { queuedProfiles -= 1 }
            ingressLock.unlock()
            process(command)
        } else {
            if backlogStatus == .overloaded { backlogStatus = .recovered; mailbox.notifyEvidenceChanged() }
            draining = false
            ingressLock.unlock()
            return
        }
        // One item per dispatch lets the deadline callback enter in order.
        q.async { self.drainOne() }
    }
    private func process(_ command: Command) {
        switch command {
        case .beginPlan(let owner, let source, let ready):
            guard source.revision == state.instrument?.revision, sourceIsActive(source) else { ready(nil); return }
            planSources[owner] = source
            let token = router.beginNotePlan(owner: owner, now: noteClock.now)
            ready(token)
            scheduleNoteDeadline()
        case .plan(let note, let completion):
            completion(router.plan(note, now: noteClock.now))
            scheduleNoteDeadline()
            publish()
        case .cancelPlans(let owner):
            if let owner { planSources.removeValue(forKey: owner) } else { planSources.removeAll(keepingCapacity: true) }
            router.cancelNotePlans(owner: owner, now: noteClock.now)
            scheduleNoteDeadline()
            publish()
        case .noteDeadline(let generation):
            guard generation == noteTimerGeneration else { return }
            noteTimer?.cancel(); noteTimer = nil
            router.advanceNotePlans(now: noteClock.now)
            scheduleNoteDeadline()
            publish()
        case .frame(let frame):
            if !sleeping, state.sessionID == frame.sessionID {
                let began = clock.now
                if began - frame.time > Self.latencyBudgetSeconds {
                    ingressLock.lock()
                    overflows &+= 1; discarded &+= 1
                    beginBacklogLocked(session: frame.sessionID, enqueueRelease: false)
                    ingressLock.unlock()
                    apply(.stop) // RELEASE: backlog-age
                    return
                }
                let count = state.processedProfileCount
                let ended = apply(.frame(frame))
                if state.processedProfileCount > count {
                    timings.record(.init(requestedAt: frame.time, completedAt: ended,
                        queueMilliseconds: max(0, began - frame.time) * 1_000,
                        totalMilliseconds: max(0, ended - frame.time) * 1_000))
                }
            }
            else {
                ingressLock.lock(); discarded &+= 1; ingressLock.unlock()
                apply(.portsChanged)
            }
        case .tempoChanged:
            updateArpeggios()
        case .arpeggioDeadline(let generation):
            guard generation == arpeggioGeneration else { return }
            updateArpeggios()
        case .monitorVisible(let visible):
            router.setMonitorVisible(visible)
            publish()
        case .panic(let requested):
            let began = clock.now
            let ended = apply(.panic)
            timings.record(.init(requestedAt: requested, completedAt: ended,
                queueMilliseconds: max(0, began - requested) * 1_000,
                totalMilliseconds: max(0, ended - requested) * 1_000), panic: true)
        case .play(let input):
            if case .sleep = input { sleeping = true }
            if case .wake = input { sleeping = false }
            apply(input)
        case .attach(let port):
            var port = port; port.terminationJournal = releaseJournal
            router.attach(port)
            apply(.portsChanged)
        case .retire(let id, let ack):
            let receipt = router.retire(id, now: noteClock.now)
            if let strip = receipt?.destination.stripID { cancelArpeggios(stripID: strip) }
            apply(.portsChanged, retiredPort: receipt)
            DispatchQueue.main.async(execute: ack) // RETIRE: ack-after-off
        case .terminate(let ack):
            apply(.terminate)
            DispatchQueue.main.async(execute: ack)
        case .barrier(let ack): DispatchQueue.main.async(execute: ack)
        case .deadline(let generation):
            guard generation == timerGeneration else { return }
            timer?.cancel()
            timer = nil
            scheduledDeadline = nil
            apply(.timeAdvanced(clock.now))
        case .backlog(let session):
            // An obsolete session cannot release a newer session. Overflow
            // deliberately releases Hold/Toggle too; ordinary input loss does not.
            guard state.sessionID == session else { return }
            apply(.stop) // RELEASE: backlog
        }
    }
    @discardableResult private func apply(_ input: PlayInput, retiredPort: OutputPortDisplay? = nil) -> Double {
        switch input {
        case .panic, .stop, .sleep, .wake, .terminate:
            cancelArpeggios(); cancelAllNotePlans()
        case .install(let replacement):
            if replacement.revision != state.instrument?.revision {
                if state.instrument?.revision.session != replacement.revision.session { cancelArpeggios() }
                else {
                    for old in state.instrument?.channels ?? [] {
                        let new = replacement.channels.first { $0.id == old.id }
                        if new?.midiEffects != old.midiEffects || new?.instrument?.identity != old.instrument?.identity || new == nil {
                            cancelArpeggios(stripID: old.id)
                        }
                    }
                }
                cancelAllNotePlans()
            }
        case .audioConfigurationChanged:
            cancelArpeggios(); cancelAudioNotePlans()
        case .releaseAudioChannel(let id):
            cancelArpeggios(stripID: id)
            cancelAudioNotePlans(stripID: id)
        case .sessionEnded(let id, .userRequested):
            if state.sessionID == nil || state.sessionID == id { cancelArpeggios(); cancelAllNotePlans() }
        default: break
        }
        switch input {
        case .stop, .panic, .sleep, .wake, .terminate, .sessionEnded(_, .userRequested): router.resetPrograms()
        case .install(let replacement), .detectionChanged(let replacement):
            let layerTargetChanged = replacement.layers.contains { layer in
                guard let previous = state.instrument?.layers.first(where: { $0.id == layer.id }) else { return false }
                return previous.midiTarget != layer.midiTarget
            }
            if state.instrument?.revision.session != replacement.revision.session || state.instrument?.midiTarget != replacement.midiTarget ||
                layerTargetChanged { cancelAllNotePlans(); router.resetPrograms() }
        default: break
        }
        switch input {
        case .stop, .sleep, .wake, .terminate, .inputLost, .sessionEnded, .sessionBegan:
            router.releaseControllers()
        case .releaseAudioChannel(let id):
            router.releaseControllers(destination: .audioUnit(stripID: id))
        case .install(let replacement), .detectionChanged(let replacement):
            if let old = state.instrument {
                if old.revision.session != replacement.revision.session { router.releaseControllers() }
                else {
                    if old.midiTarget != replacement.midiTarget { router.releaseControllers(destination: .midi) }
                    for layer in old.layers {
                        let next = replacement.layers.first { $0.id == layer.id }
                        guard layer.routings.map(\.target) != next?.routings.map(\.target) || layer.midiTarget != next?.midiTarget else { continue }
                        let midiDestination: SpatialOutputDestination = layer.midiTarget.flatMap {
                            $0.uniqueID == (old.midiTarget?.uniqueID ?? 0) ? nil : .midiEndpoint(uniqueID: $0.uniqueID)
                        } ?? .midi
                        for routing in layer.routings {
                            guard let channel = routing.target.midiChannel else { continue }
                            let destination = routing.target.stripID.map { SpatialOutputDestination.audioUnit(stripID: $0) } ?? midiDestination
                            router.releaseControllers(destination: destination, channel: channel)
                        }
                    }
                    for strip in old.channels where replacement.channels.first(where: { $0.id == strip.id })?.instrument?.identity != strip.instrument?.identity || !replacement.channels.contains(where: { $0.id == strip.id }) {
                        router.releaseControllers(destination: .audioUnit(stripID: strip.id))
                    }
                }
            }
        default: break
        }
        let oldCount = state.processedProfileCount
        let previousScene = state.sceneSnapshot
        let hadProfile = state.displayProfile != nil
        let next = PlayEngine.step(state, input)
        state = next.0
        if hadProfile && state.displayProfile == nil { router.releaseControllers() }
        if previousScene?.generation != state.sceneSnapshot?.generation { cancelArpeggios() }
        if previousScene != state.sceneSnapshot { cancelAllNotePlans() }
        switch input {
        case .install, .detectionChanged:
            let live = Set(state.instrument?.channels.map(\.id) ?? [])
            inhibitedArpeggios.formIntersection(live); failedArpeggios.formIntersection(live)
            inhibitedInputs = inhibitedInputs.filter { live.contains($0.key) }
        default: break
        }
        for (owner, source) in planSources where !sourceIsActive(source) {
            router.cancelNotePlans(owner: owner, now: noteClock.now)
            planSources.removeValue(forKey: owner)
        }
        if let scene = state.sceneSnapshot, scene != previousScene {
            let callback = onSceneChanged
            DispatchQueue.main.async { callback?(scene) }
        }
        if case .audioConfigurationChanged = input {
            router.panic(audioOnly: true, releasing: next.1, now: noteClock.now)
        } else if case .panic = input {
            // Pure engine events describe document ownership. Physical PANIC
            // is sent once per actual binding by its sole port owner.
            // Finish each preceding healthy port (Offs + all 16 channels)
            // before a later misbehaving boundary can block the queue.
            router.panic(releasing: next.1, now: noteClock.now)
        } else {
            router.route(next.1.filter { !isArpeggiatedNote($0) }, sounding: state.soundingEvents.filter { !isArpeggiatedNote($0) },
                         allowOn: state.processedProfileCount != oldCount, now: noteClock.now)
        }
        updateArpeggios()
        let routedAt = clock.now
        scheduleNextDeadline()
        scheduleNoteDeadline()
        publish(retiredPort: retiredPort)
        return routedAt
    }
    private func isArpeggiatedNote(_ event: MusicEvent) -> Bool {
        let destination: SpatialOutputDestination
        switch event {
        case .noteOn(let d, _, _), .noteOff(let d, _, _): destination = d
        default: return false
        }
        guard let id = destination.stripID else { return false }
        return state.instrument?.channels.first { $0.id == id }?.midiEffects.contains { !$0.bypassed && $0.kind == .arpeggiator } == true
    }
    private func cancelArpeggios(stripID: UUID? = nil) {
        router.invalidateSampleNotes(stripID: stripID)
        if let stripID {
            if let producer = arpeggios[stripID] { inhibitedArpeggios.insert(stripID); inhibitedInputs[stripID] = producer.inputs }
            arpeggios.removeValue(forKey: stripID); failedArpeggios.remove(stripID)
        } else {
            for (id, producer) in arpeggios { inhibitedInputs[id] = producer.inputs }
            inhibitedArpeggios.formUnion(arpeggios.keys)
            arpeggios.removeAll(keepingCapacity: true)
            failedArpeggios.removeAll(keepingCapacity: true)
        }
        arpeggioTimer?.cancel(); arpeggioTimer = nil
        arpeggioGeneration &+= 1
    }
    private func updateArpeggios() {
        arpeggioTimer?.cancel(); arpeggioTimer = nil; arpeggioGeneration &+= 1
        let now = noteClock.now
        let snapshot = hostClock.snapshot
        let tempo = max(1, now < snapshot.seconds ? snapshot.previousTempo : snapshot.tempo)
        // The arp keeps the last tempo when external transport stops.
        let beat = snapshot.beat + (now - snapshot.seconds) * tempo / 60
        var nextWake: Double?
        for strip in state.instrument?.channels ?? [] {
            let active = strip.midiEffects.filter { !$0.bypassed }
            guard let stage = active.firstIndex(where: { $0.kind == .arpeggiator }) else { continue }
            guard router.hasSampleBoundary(stripID: strip.id) else { continue }
            let effect = state.arpeggiatorModulation.applying(to: active[stage].arpeggiator, stripID: strip.id, slotID: active[stage].id)
            let inputs: [ArpeggioProducer.Input] = state.soundingEvents.compactMap {
                guard case let .noteOn(.audioUnit(id), channel, note) = $0, id == strip.id else { return nil }
                return .init(channel: channel, note: note)
            }
            var producer = arpeggios[strip.id] ?? .init()
            producer.retime(tempo: tempo, changedAt: snapshot.seconds)
            producer.modulateRate(effect.rate, tempo: tempo, notBefore: now)
            let wasActive = !producer.inputs.isEmpty
            producer.update(inputs, at: now, effect: effect, beat: beat, tempo: tempo)
            if inputs.isEmpty {
                if wasActive { router.invalidateSampleNotes(stripID: strip.id) }
                arpeggios.removeValue(forKey: strip.id)
                failedArpeggios.remove(strip.id)
                inhibitedArpeggios.remove(strip.id)
                inhibitedInputs.removeValue(forKey: strip.id)
                continue
            }
            if let blocked = inhibitedInputs[strip.id],
               blocked.count != inputs.count || !blocked.allSatisfy({ inputs.contains($0) }) {
                inhibitedArpeggios.remove(strip.id); inhibitedInputs.removeValue(forKey: strip.id)
            }
            if failedArpeggios.contains(strip.id) || inhibitedArpeggios.contains(strip.id) { continue }
            if snapshot.seconds > now && snapshot.tempo != snapshot.previousTempo {
                nextWake = min(nextWake ?? .infinity, snapshot.seconds)
            }
            var failed = false
            var overflow = false
            // Capacity is checked by the C producer. This bound also prevents
            // an overdue cursor from monopolizing Q after a long suspension.
            for _ in 0..<256 {
                guard let deadline = producer.next, deadline <= now + 0.05 else { break }
                var candidate = producer
                guard let (input, on, off, immediate) = candidate.step(effect: effect, tempo: tempo) else { break }
                var pitches = [Int(input.note.number)]
                for slot in active.dropFirst(stage + 1) where slot.kind == .chord {
                    pitches = Array(Set(pitches.flatMap { slot.chord.notes(for: $0) })).sorted()
                }
                for pitch in pitches {
                    let result = router.enqueueSampleNote(stripID: strip.id, bytes: [0x90 | input.channel, UInt8(pitch), input.note.velocity], deadline: on, immediate: immediate)
                    if result != .sent { failed = true; overflow = result == .faulted; break }
                }
                if !failed {
                    for pitch in pitches {
                        let result = router.enqueueSampleNote(stripID: strip.id, bytes: [0x80 | input.channel, UInt8(pitch), 0], deadline: off, immediate: false)
                        if result != .sent { failed = true; overflow = result == .faulted; break }
                    }
                }
                if failed { router.invalidateSampleNotes(stripID: strip.id); break }
                producer = candidate
            }
            if failed {
                arpeggios.removeValue(forKey: strip.id)
                if overflow { failedArpeggios.insert(strip.id) }
                else { nextWake = min(nextWake ?? .infinity, now + 0.005) }
            } else {
                arpeggios[strip.id] = producer
                if let deadline = producer.next { nextWake = min(nextWake ?? .infinity, max(now + 0.005, deadline - 0.05)) }
            }
        }
        guard let deadline = nextWake else { return }
        let generation = arpeggioGeneration
        let action: @Sendable () -> Void = { [weak self] in self?.process(.arpeggioDeadline(generation)) }
        if let bounded = noteClock as? NotePlanningClock {
            arpeggioTimer = bounded.trySchedule(at: deadline, on: q, action)
            if arpeggioTimer == nil { cancelArpeggios() }
        } else {
            arpeggioTimer = noteClock.schedule(at: deadline, on: q, action)
        }
    }
    private func cancelAllNotePlans() {
        router.cancelNotePlans(now: noteClock.now)
        planSources.removeAll(keepingCapacity: true)
    }
    private func cancelAudioNotePlans(stripID: UUID? = nil) {
        for owner in router.cancelAudioNotePlans(stripID: stripID, now: noteClock.now) {
            planSources.removeValue(forKey: owner)
        }
    }
    private func sourceIsActive(_ source: CompiledActiveCell) -> Bool {
        if state.selection.activeHandles[source.layerID]?.cell == source.cell,
           state.soundingNoteOwners.contains(where: { $0.layerID == source.layerID && !$0.latched }) { return true }
        return state.heldCells.contains { $0.layerID == source.layerID && $0.cell == source.cell }
    }
    private func scheduleNoteDeadline() {
        noteTimer?.cancel(); noteTimer = nil
        noteTimerGeneration &+= 1
        guard let deadline = router.nextPlannedDeadline else { return }
        let generation = noteTimerGeneration
        let action: @Sendable () -> Void = { [weak self] in
            self?.process(.noteDeadline(generation))
        }
        if let bounded = noteClock as? NotePlanningClock {
            noteTimer = bounded.trySchedule(at: deadline, on: q, action)
            if noteTimer == nil { cancelAllNotePlans() }
        } else {
            noteTimer = noteClock.schedule(at: deadline, on: q, action)
        }
    }
    private func scheduleNextDeadline() {
        guard state.nextDeadline != scheduledDeadline else { return }
        timer?.cancel()
        timer = nil
        scheduledDeadline = state.nextDeadline
        timerGeneration &+= 1
        guard let deadline = scheduledDeadline else { return }
        let generation = timerGeneration
        timer = clock.schedule(at: deadline, on: q) { [weak self] in
            self?.enqueue(.deadline(generation))
        }
    }
    private func publish(retiredPort: OutputPortDisplay? = nil) {
        ingressLock.lock()
        processed = state.processedProfileCount
        let dropped = discarded
        let overflowCount = overflows
        ingressLock.unlock()
        let monitor = router.monitorSnapshots
        mailbox.write(.init(arpeggiatorModulation: state.arpeggiatorModulation, profile: state.displayProfile, contour: state.roomContour, selection: state.selection,
                            revision: state.instrument?.revision, scene: state.sceneSnapshot, sessionID: state.sessionID,
                            processedProfiles: state.processedProfileCount,
                            discardedProfiles: dropped, overflowProfiles: overflowCount, soundingNoteOwners: state.soundingNoteOwners, outputMonitor: monitor, heldCells: state.heldCells, ports: router.display, retiredPort: retiredPort,
                            partitionOwners: state.instrument?.partitionOwner ?? [:]))
    }
}

public enum ProfileSourceEvent: Sendable {
    case began(UUID), frame(ProfileFrame), ended(UUID, reason: InputSessionEndReason = .userRequested)
}
/// P5's InputOwner supplies this boundary. Binding neither opens a device nor
/// waits for Runtime. The source owns its subscription/lifetime, not Runtime.
/// A physical session gets a fresh UUID; identifiers are never reused for
/// a later connection. Profile times share RuntimeClock's monotonic epoch.
public protocol RuntimeProfileSource {
    func bind(_ receive: @escaping @Sendable (ProfileSourceEvent) -> Void)
}
public struct PerformanceComposition: Sendable {
    public let runtime: PerformanceRuntime
    public let mailbox: DisplayFrameMailbox
}
/// The same construction path is used by tests and by the future P5 root.
public enum PerformanceRuntimeFactory {
    public static func make(clock: any RuntimeClock = MonotonicRuntimeClock(),
                            ports: [OutputPort] = [], hostClock: HostMusicalClock = HostMusicalClock(),
                            source: (any RuntimeProfileSource)? = nil) -> PerformanceComposition {
        let mailbox = DisplayFrameMailbox()
        let runtime = PerformanceRuntime(clock: clock, mailbox: mailbox, hostClock: hostClock)
        for port in ports { runtime.attach(port) }
        source?.bind { [weak runtime] event in
            switch event {
            case .began(let id): runtime?.sessionBegan(id)
            case .frame(let frame): runtime?.frame(frame)
            case .ended(let id, let reason): runtime?.sessionEnded(id, reason: reason)
            }
        }
        return .init(runtime: runtime, mailbox: mailbox)
    }
}
