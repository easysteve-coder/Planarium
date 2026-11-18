import Foundation
import PLSDeviceValues
import SickPLSCore

/// Actual measurements, never predicted samples. Time is supplied by Input.
public struct ProfileFrame: Equatable, Sendable {
    public let sessionID: UUID
    public let sequence: UInt64
    public let time: Double
    public let measurements: [DeviceTickMeasurement]
    public let projectedMeasurements: [ProjectedScanMeasurement]
    public let geometry: ProfileGeometryIdentity
    public let rawProfile: B0ScanProfile?
    public let sourceIdentifier: String

    public init(sessionID: UUID, sequence: UInt64, time: Double,
                measurements: [DeviceTickMeasurement],
                geometry: ProfileGeometryIdentity = .fullScan361,
                sourceIdentifier: String = "scanner:default", rawProfile: B0ScanProfile? = nil) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.time = time
        self.measurements = measurements
        projectedMeasurements = geometry.project(measurements, rawProfile: rawProfile)
        self.geometry = geometry
        self.sourceIdentifier = sourceIdentifier
        self.rawProfile = rawProfile
    }
}

public enum InputSessionEndReason: Equatable, Sendable {
    case failure
    case userRequested
}

public enum PlayInput: Sendable {
    case frame(ProfileFrame)
    /// Accepted pointer input enters after detection, on the same evaluation path.
    case audition(MetricScanPoint?, time: Double)
    case install(CompiledInstrument)
    case sessionBegan(UUID)
    case sessionEnded(UUID, reason: InputSessionEndReason = .userRequested)
    case inputLost
    /// Supplied monotonic time; Runtime owns scheduling, Domain owns decisions.
    case timeAdvanced(Double)
    case panic
    case audioConfigurationChanged
    case releaseAudioChannel(UUID)
    case stop
    case sleep
    case wake
    case terminate
    /// A newly compiled document snapshot supplies configuration; there is
    /// no separate mutable configuration owned by the runtime.
    case detectionChanged(CompiledInstrument)
    case roomContour(SpatialRoomContour?)
    /// Physical bindings change outside musical state.
    case portsChanged
    case selectScene(UUID)
}

/// The queue's authoritative scene state. Revision excludes callbacks from a
/// replaced preset even when that preset reuses the same scene identities.
public struct RuntimeSceneSnapshot: Equatable, Sendable {
    public let revision: SpatialDocumentRevision
    public let generation: UInt64
    public let currentSceneID: UUID?
    public let activeLayerIDs: Set<UUID>
    /// Authoring installs acknowledge their generation without overwriting
    /// raw activity/solo bits. A queue selection projects stored membership.
    public let appliesSceneMembership: Bool
}

public struct SoundingNoteOwner: Equatable, Sendable {
    public let layerID: UUID
    public let destination: SpatialOutputDestination
    public let channel: UInt8
    public let number: UInt8
    public let latched: Bool

    /// The same owner reported under another layer identity (a partition shown as its layer).
    public func reassigningLayerID(_ id: UUID) -> SoundingNoteOwner {
        .init(layerID: id, destination: destination, channel: channel, number: number, latched: latched)
    }
}

/// Value state only. The only musical mode is installed versus uninstalled.
public struct PlayState: Sendable {
    public fileprivate(set) var instrument: CompiledInstrument?
    public fileprivate(set) var sessionID: UUID?
    public fileprivate(set) var processedProfileCount: UInt64 = 0
    public fileprivate(set) var selection = DeviceLatticeSelection(
        activeHandles: [:], candidateDistancesCentimeters: [:])
    public fileprivate(set) var roomContour: SpatialRoomContour?
    fileprivate var detection = SpatialDetectionPipeline()
    fileprivate var ledger = SpatialNoteLedger(coalescesSharedNotes: true)
    fileprivate var lastFrame: ProfileFrame?
    fileprivate var auditionPoint: MetricScanPoint?
    fileprivate var auditionDeadline: Double?
    // A scene ends the virtual hand, but queued drags belong to that same press.
    fileprivate var auditionSceneNeedsExit = false
    private static let auditionInterval = 1.0 / 25.0
    fileprivate var measuredSelection = DeviceLatticeSelection(activeHandles: [:], candidateDistancesCentimeters: [:])
    fileprivate var staleWatch = SpatialStaleWatch()
    fileprivate var pendingOffs: [(deadline: Double, command: SpatialOutputCommand)] = []
    fileprivate var panicCells: [UUID: PolarDeviceLattice] = [:]
    fileprivate var measuredPanicSurfaces: [UUID: Set<PolarDeviceLattice>] = [:]
    fileprivate var measuredPanicEntries: [UUID: Set<PolarDeviceLattice>] = [:]
    fileprivate var activeLayerIDs: Set<UUID> = []
    fileprivate var currentSceneID: UUID?
    fileprivate var sceneGeneration: UInt64 = 0
    fileprivate var appliesSceneMembership = false
    fileprivate struct SceneCellKey: Hashable, Sendable {
        let routingID: UUID
        let cell: PolarDeviceLattice
    }
    fileprivate var sceneDwell: [SceneCellKey: (enteredAt: Double, fired: Bool)] = [:]
    fileprivate var releaseEntries: Set<SceneCellKey> = []
    fileprivate var releaseHoldCells: Set<SceneCellKey> = []
    fileprivate var scenePanicCells: [UUID: Set<PolarDeviceLattice>] = [:]
    fileprivate var togglePanicEntries: Set<SceneCellKey> = []
    /// Layers muted by a scene continue only while their already-held measured
    /// cell remains selected. This is the contract's normal Note-Off path.
    fileprivate var sustainingMutedCells: [UUID: PolarDeviceLattice] = [:]
    fileprivate var sceneActivationBlocks: [UUID: PolarDeviceLattice] = [:]
    fileprivate var programEntries: [UUID: PolarDeviceLattice] = [:]

    public fileprivate(set) var arpeggiatorModulation = ArpeggiatorModulationState()

    public init() {}
    public var soundingNoteCount: Int { ledger.soundingNoteCount }
    public var soundingEvents: [MusicEvent] { events(ledger.soundingCommands) }
    public var soundingNoteOwners: [SoundingNoteOwner] {
        guard let instrument else { return [] }
        return ledger.noteOwners.compactMap { receipt in
            guard let layer = instrument.layers.first(where: { $0.routings.contains { $0.id == receipt.routingID } }) else { return nil }
            return .init(layerID: layer.id, destination: receipt.destination, channel: receipt.channel, number: receipt.number, latched: receipt.latched)
        }.sorted { ($0.layerID.uuidString, $0.channel, $0.number) < ($1.layerID.uuidString, $1.channel, $1.number) }
    }
    public var heldCells: [CompiledActiveCell] {
        guard let instrument else { return [] }
        return ledger.latchedCells.compactMap { receipt in
            guard let layer = instrument.layers.first(where: { $0.routings.contains { $0.id == receipt.routingID } }) else { return nil }
            return CompiledActiveCell(layerID: layer.id, cell: receipt.cell, revision: instrument.revision)
        }.sorted { ($0.layerID.uuidString, $0.cell.ring, $0.cell.sector) < ($1.layerID.uuidString, $1.cell.ring, $1.cell.sector) }
    }
    public var displayProfile: ProfileFrame? { lastFrame }
    public var sceneSnapshot: RuntimeSceneSnapshot? {
        instrument.map { .init(revision: $0.revision, generation: sceneGeneration,
                              currentSceneID: currentSceneID, activeLayerIDs: activeLayerIDs,
                              appliesSceneMembership: appliesSceneMembership) }
    }
    public var nextDeadline: Double? {
        let overlap = pendingOffs.map(\.deadline).min()
        let stale = staleWatch.nextDeadline?.nextUp
        return [overlap, stale, auditionPoint == nil ? nil : auditionDeadline].compactMap { $0 }.min()
    }
}

/// One total state transition. No thread, clock, sink, failure mode or barrier.
public enum PlayEngine {
    public static func step(_ state: PlayState, _ input: PlayInput) -> (PlayState, [MusicEvent]) {
        var next = state
        let commands = next.apply(input)
        return (next, commands)
    }
}

private extension PlayState {
    /// Canonical connected content partition, independent of the Snap amount.
    func surface(_ cell: PolarDeviceLattice, layerID: UUID) -> PolarDeviceLattice {
        instrument?.layers.first { $0.id == layerID }?.snapRegionByCell[cell] ?? cell
    }
    func surface(_ handle: CompiledActiveCell) -> PolarDeviceLattice {
        surface(handle.cell, layerID: handle.layerID)
    }

    func surfaceForRouting(_ cell: PolarDeviceLattice, routingID: UUID) -> PolarDeviceLattice {
        guard let layer = instrument?.layers.first(where: { $0.routings.contains { $0.id == routingID } }) else { return cell }
        return surface(cell, layerID: layer.id)
    }

    mutating func apply(_ input: PlayInput) -> [MusicEvent] {
        switch input {
        case .selectScene(let id):
            guard let instrument, let scene = instrument.scenes.first(where: { $0.id == id }) else { return [] }
            let auditionRelease = auditionPoint == nil ? [] : apply(.audition(nil, time: lastFrame?.time ?? 0))
            return auditionRelease + activateScene(scene, instrument: instrument)
        case .install(let replacement), .detectionChanged(let replacement):
            guard instrument?.revision != replacement.revision else { return [] }
            let sameSession = instrument?.revision.session == replacement.revision.session
            if !sameSession {
                auditionPoint = nil
                measuredSelection = .init(activeHandles: [:], candidateDistancesCentimeters: [:])
                arpeggiatorModulation = .init()
            }
            let sameScenes = instrument.map { current in
                current.scenes.count == replacement.scenes.count && zip(current.scenes, replacement.scenes).allSatisfy {
                    $0.0.id == $0.1.id && $0.0.activeLayerIDs == $0.1.activeLayerIDs
                }
            } ?? false
            let unchangedMusic = sameSession && instrument?.layers == replacement.layers &&
                instrument?.detection == replacement.detection &&
                instrument.map { Set($0.channels.map(\.id)) } == Set(replacement.channels.map(\.id)) && sameScenes
            let staleScene = sameSession && currentSceneID != nil && !replacement.replacesScene &&
                replacement.sceneGeneration.map { $0 < sceneGeneration } == true
            let sameSceneConfiguration =
                (instrument?.activeLayerIDs == replacement.activeLayerIDs && instrument?.currentSceneID == replacement.currentSceneID) ||
                (activeLayerIDs == replacement.activeLayerIDs && currentSceneID == replacement.currentSceneID)
            let confirmedScene = unchangedMusic &&
                activeLayerIDs == replacement.activeLayerIDs && currentSceneID == replacement.currentSceneID
            let keepScene = sameSession && !replacement.replacesScene &&
                (staleScene || confirmedScene || replacement.sceneGeneration == nil && unchangedMusic && sameSceneConfiguration)
            let available = Set(replacement.layers.map(\.id))
            let retainedScene = replacement.scenes.first { $0.id == currentSceneID }
            let nextSceneID = keepScene && (currentSceneID == nil || retainedScene != nil) ? currentSceneID : replacement.currentSceneID
            let nextActive = keepScene && (currentSceneID == nil || retainedScene != nil)
                ? (unchangedMusic ? activeLayerIDs : activeLayerIDs.intersection(available))
                : replacement.activeLayerIDs
            let keepTransition = unchangedMusic && keepScene && nextActive == activeLayerIDs && nextSceneID == currentSceneID
            let transferred = selection.activeHandles.compactMapValues { replacement.transferring($0) }
            var nextSelection = DeviceLatticeSelection(activeHandles: transferred,
                candidateDistancesCentimeters: selection.candidateDistancesCentimeters.filter { transferred[$0.key] != nil },
                representative: selection.representative, contourMatches: selection.contourMatches,
                filteredOrders: selection.filteredOrders, objects: selection.objects,
                sceneControlHandles: unchangedMusic ? selection.sceneControlHandles.compactMap { replacement.transferring($0) } : [],
                measuredEntryHandles: unchangedMusic ? selection.measuredEntryHandles.compactMap { replacement.transferring($0) } : [])
            if let current = instrument, current.detection != replacement.detection, let lastFrame {
                // Configuration edits take effect immediately, but their
                // preview must never mutate the live measurement history.
                var preview = detection
                nextSelection = preview.select(frame: lastFrame, instrument: replacement, contour: roomContour, recordingProfile: false)
                detection = preview
            }
            let supported = (try? replacement.evaluate(active: nextSelection.activeHandles)) ?? []
            var released: [SpatialOutputCommand] = []
            if let current = instrument {
                // A document edit is an explicit activity change. Scene
                // transitions use activateScene and keep their own policy.
                // Scene selection changes Runtime's active set without a
                // snapshot reinstall. Compare that effective set, not stale
                // activity bits in the previous compiled document.
                let deactivated = activeLayerIDs.subtracting(nextActive)
                let routings = Set(current.layers.filter { deactivated.contains($0.id) }.flatMap { $0.routings.map(\.id) })
                released += ledger.releaseLatched(routingIDs: routings)
                if current.revision.session != replacement.revision.session {
                    released += ledger.releaseAll()
                    releaseHoldCells.removeAll()
                }
                if current.midiTarget != replacement.midiTarget {
                    released += ledger.release(destination: .midi)
                }
                for channel in current.channels {
                    let next = replacement.channels.first { $0.id == channel.id }
                    if next == nil || next?.instrument?.identity != channel.instrument?.identity
                        || next?.midiEffects != channel.midiEffects {
                        released += ledger.release(destination: .audioUnit(stripID: channel.id))
                    }
                }
            }
            if !unchangedMusic {
                released += ledger.retainToggleCells(from: instrument, to: replacement)
                var preserved = Set<UUID>()
                if let current = instrument, current.revision.session == replacement.revision.session,
                   current.detection == replacement.detection {
                    for layer in current.layers {
                        guard let new = replacement.layers.first(where: { $0.id == layer.id }),
                              layer.cells == new.cells, layer.cellActions == new.cellActions, layer.midiTarget == new.midiTarget else { continue }
                        for routing in layer.routings where new.routings.contains(routing) { preserved.insert(routing.id) }
                    }
                }
                released += ledger.retainSupported(by: supported, preservingRoutingIDs: preserved)
                pendingOffs.removeAll { !ledger.ownsScheduledOff($0.command) }
            }
            if instrument == nil || !sameSession || replacement.replacesScene || nextActive != activeLayerIDs || nextSceneID != currentSceneID {
                arpeggiatorModulation = .init()
                sceneGeneration &+= 1
            }
            arpeggiatorModulation.retain(targetsByRoutingID: Dictionary(uniqueKeysWithValues: replacement.layers.flatMap(\.routings).filter { !replacement.unavailableRoutingIDs.contains($0.id) }.map { ($0.id, $0.target) }))
            instrument = replacement
            // Installation cannot issue a PC. A changed assignment is eligible
            // only on the next confirmed measured profile.
            if !unchangedMusic { programEntries.removeAll() }
            activeLayerIDs = nextActive
            currentSceneID = nextSceneID
            if !keepScene { appliesSceneMembership = false }
            if !keepTransition { sceneDwell.removeAll() }
            releaseEntries = releaseEntries.filter { key in
                replacement.layers.contains { layer in
                    containsCell(key.cell, in: layer.cells) && layer.routings.contains { $0.id == key.routingID && $0.target.isLayerControl }
                }
            }
            releaseHoldCells = releaseHoldCells.filter { key in
                replacement.layers.contains { layer in
                    containsCell(key.cell, in: layer.cells) && layer.routings.contains { $0.id == key.routingID }
                }
            }
            if !keepTransition { scenePanicCells.removeAll() }
            if !unchangedMusic { togglePanicEntries.removeAll() }
            if !keepTransition {
                sustainingMutedCells.removeAll()
                sceneActivationBlocks.removeAll()
            }
            detection.install(replacement)
            selection = nextSelection
            if auditionPoint == nil {
                // Detection edits may have reselected the last real frame.
                // Audition must merge with that accepted result, not an old one.
                measuredSelection = nextSelection
            } else {
                let measured = measuredSelection.activeHandles.compactMapValues { replacement.transferring($0) }
                measuredSelection = .init(activeHandles: measured,
                    candidateDistancesCentimeters: measuredSelection.candidateDistancesCentimeters.filter { measured[$0.key] != nil },
                    representative: measuredSelection.representative, contourMatches: measuredSelection.contourMatches,
                    filteredOrders: measuredSelection.filteredOrders, objects: measuredSelection.objects,
                    sceneControlHandles: measuredSelection.sceneControlHandles.compactMap { replacement.transferring($0) },
                    measuredEntryHandles: measuredSelection.measuredEntryHandles.compactMap { replacement.transferring($0) })
            }
            return events(released)
        case .frame(let frame):
            guard let instrument else { return [] }
            guard frame.time.isFinite, frame.geometry.pointCount > 0,
                  frame.geometry.startAngleDegrees.isFinite, frame.geometry.endAngleDegrees.isFinite,
                  frame.geometry.startAngleDegrees <= frame.geometry.endAngleDegrees else {
                return release(preservingLatches: true)
            }
            // Session identity excludes stale frames, without a musical
            // blocked state. A source may provide frames before began.
            if let sessionID, sessionID != frame.sessionID { return [] }
            processedProfileCount &+= 1
            lastFrame = frame
            staleWatch.noteProfile(at: frame.time)
            var commands: [SpatialOutputCommand] = []
            let due = pendingOffs.filter { $0.deadline <= frame.time }
            pendingOffs.removeAll { $0.deadline <= frame.time }
            for item in due {
                if let off = ledger.completeScheduledOff(item.command) { commands.append(off) }
            }
            selection = detection.select(frame: frame, instrument: instrument, contour: roomContour)
            measuredSelection = selection
            if !measuredPanicSurfaces.isEmpty || !measuredPanicEntries.isEmpty {
                measuredPanicSurfaces = retainingSurfaces(measuredPanicSurfaces,
                    in: surfaceMap(Array(selection.activeHandles.values) + selection.measuredEntryHandles))
                measuredPanicEntries = retainingSurfaces(measuredPanicEntries, in: surfaceMap(selection.measuredEntryHandles))
            }
            mergeAudition(instrument: instrument)
            return evaluateSelection(at: frame.time, instrument: instrument, commands: commands)
        case .audition(let point, let time):
            guard time.isFinite, let instrument else { return [] }
            if let point, (!point.xMeters.isFinite || !point.yMeters.isFinite || point.yMeters < 0
                || hypot(point.xMeters, point.yMeters) * 100 > Double(UInt16.max)) {
                return apply(.audition(nil, time: time))
            }
            if point == nil { auditionSceneNeedsExit = false }
            else if auditionSceneNeedsExit { return [] }
            auditionPoint = point
            auditionDeadline = point == nil ? nil : time + Self.auditionInterval
            selection = measuredSelection
            mergeAudition(instrument: instrument)
            return evaluateSelection(at: time, instrument: instrument, commands: [])
        case .sessionBegan(let id):
            if auditionPoint != nil {
                sessionID = id
                return loseMeasurements(at: lastFrame?.time ?? 0)
            }
            let released = release(preservingLatches: sessionID == nil)
            sessionID = id
            return released
        case .sessionEnded(let id, let reason):
            guard sessionID == nil || sessionID == id else { return [] }
            sessionID = nil
            return reason == .failure ? loseMeasurements(at: lastFrame?.time ?? 0) : release()
        case .timeAdvanced(let time):
            guard time.isFinite else { return [] }
            if staleWatch.check(at: time) { return loseMeasurements(at: time) } // RELEASE: stale
            var completed: [SpatialOutputCommand] = []
            for item in pendingOffs where item.deadline <= time {
                if let off = ledger.completeScheduledOff(item.command) { completed.append(off) }
            }
            pendingOffs.removeAll { $0.deadline <= time }
            if auditionPoint != nil, let deadline = auditionDeadline, deadline <= time, let instrument {
                auditionDeadline = time + Self.auditionInterval
                selection = measuredSelection
                mergeAudition(instrument: instrument)
                return events(completed) + evaluateSelection(at: time, instrument: instrument, commands: [])
            }
            return events(completed)
        case .inputLost:
            return loseMeasurements(at: lastFrame?.time ?? 0) // RELEASE: inputLost
        case .panic:
            arpeggiatorModulation = .init()
            let physicalSurfaces = measuredPanicSurfaces.merging(surfaceMap(Array(measuredSelection.activeHandles.values) + measuredSelection.measuredEntryHandles)) { $0.union($1) }
            let physicalEntries = measuredPanicEntries.merging(surfaceMap(measuredSelection.sceneControlHandles + measuredSelection.measuredEntryHandles)) { $0.union($1) }
            let occupiedToggles = Set(ledger.occupiedToggleCells.map {
                SceneCellKey(routingID: $0.routingID, cell: surfaceForRouting($0.cell, routingID: $0.routingID))
            })
            let blockedToggles = togglePanicEntries.union(occupiedToggles).union(instrument.map {
                toggleKeys(instrument: $0, handles: selection.sceneControlHandles + selection.measuredEntryHandles)
            } ?? [])
            let blocked = panicCells.merging(selection.activeHandles.mapValues { surface($0) }) { _, new in new }
            var blockedControls = scenePanicCells
            for handle in selection.sceneControlHandles { blockedControls[handle.layerID, default: []].insert(surface(handle)) }
            let released = release() + panicEvents() // RELEASE: panic
            panicCells = blocked
            measuredPanicSurfaces = physicalSurfaces
            measuredPanicEntries = physicalEntries
            scenePanicCells = blockedControls
            togglePanicEntries = blockedToggles
            return released
        case .releaseAudioChannel(let id):
            let destination = SpatialOutputDestination.audioUnit(stripID: id)
            let released = ledger.release(destination: destination)
            pendingOffs.removeAll {
                if case .scheduleOff(let target, _, _, _, _) = $0.command { return target == destination }
                return false
            }
            return events(released)
        case .audioConfigurationChanged:
            var destinations = Set((instrument?.channels ?? []).map { SpatialOutputDestination.audioUnit(stripID: $0.id) })
            for case .noteOn(let destination, _, _) in ledger.soundingCommands where destination.stripID != nil {
                destinations.insert(destination)
            }
            let released = destinations.flatMap { ledger.release(destination: $0) }
            pendingOffs.removeAll {
                if case .scheduleOff(let destination, _, _, _, _) = $0.command { return destination.stripID != nil }
                return false
            }
            return events(released) // RELEASE: audio-configuration (MIDI state retained)
        case .stop:
            arpeggiatorModulation = .init()
            return release() // RELEASE: stop
        case .sleep:
            return release() // RELEASE: sleep
        case .wake:
            return release() // RELEASE: wake
        case .terminate:
            arpeggiatorModulation = .init()
            roomContour = nil
            sessionID = nil
            return release() // RELEASE: terminate
        case .portsChanged:
            return []
        case .roomContour(let contour):
            roomContour = contour
            detection.reset()
            return []
        }
    }

    func surfaceMap(_ handles: [CompiledActiveCell]) -> [UUID: Set<PolarDeviceLattice>] {
        handles.reduce(into: [:]) { $0[$1.layerID, default: []].insert(surface($1)) }
    }
    func retainingSurfaces(_ masks: [UUID: Set<PolarDeviceLattice>],
                           in occupied: [UUID: Set<PolarDeviceLattice>]) -> [UUID: Set<PolarDeviceLattice>] {
        masks.reduce(into: [:]) { result, entry in
            let kept = entry.value.intersection(occupied[entry.key] ?? [])
            if !kept.isEmpty { result[entry.key] = kept }
        }
    }

    mutating func mergeAudition(instrument: CompiledInstrument) {
        guard let point = auditionPoint else { return }
        let distance = hypot(point.xMeters, point.yMeters) * 100
        guard distance.isFinite, distance <= Double(UInt16.max) else { return }
        let tick = Int(((atan2(point.xMeters, point.yMeters) * 180 / .pi + 90) * 2).rounded())
        let hits = instrument.hits(tick: tick, raw: Int(distance.rounded())).map { $0.withCandidateDistance(distance, sourceOrder: Int.max) }
        var active = selection.activeHandles, distances = selection.candidateDistancesCentimeters
        // Same one-carrier-per-layer rule: the nearest accepted hand wins.
        for hit in hits where active[hit.layerID] == nil || distance < (distances[hit.layerID] ?? .infinity) {
            active[hit.layerID] = hit; distances[hit.layerID] = distance
        }
        selection = .init(activeHandles: active, candidateDistancesCentimeters: distances,
            representative: selection.representative, contourMatches: selection.contourMatches,
            filteredOrders: selection.filteredOrders, objects: selection.objects,
            sceneControlHandles: selection.sceneControlHandles + hits,
            measuredEntryHandles: selection.measuredEntryHandles + hits,
            confirmationProgress: selection.confirmationProgress, groupingEvidence: selection.groupingEvidence)
    }
    mutating func evaluateSelection(at time: Double, instrument: CompiledInstrument,
                                    commands initial: [SpatialOutputCommand]) -> [MusicEvent] {
        var commands = initial
        if !togglePanicEntries.isEmpty {
            let current = toggleKeys(instrument: instrument, handles: selection.measuredEntryHandles)
            togglePanicEntries = togglePanicEntries.filter { key in
                current.contains(key) || instrument.layers.contains { layer in
                    layer.routings.contains { $0.id == key.routingID } && measuredPanicEntries[layer.id]?.contains(key.cell) == true
                }
            }
        }
        // Unlock only on a fresh accepted hand exit for this layer.
        // Detection and pointer input retain their actual geometric selection.
        panicCells = panicCells.filter { entry in
            measuredPanicSurfaces[entry.key]?.contains(entry.value) == true || selection.activeHandles[entry.key].map { surface($0) } == entry.value
                || selection.measuredEntryHandles.contains { $0.layerID == entry.key && surface($0) == entry.value }
        }
        sceneActivationBlocks = sceneActivationBlocks.filter { entry in selection.activeHandles[entry.key].map { surface($0) } == entry.value }
        let playable = selection.activeHandles.filter {
            panicCells[$0.key] != surface($0.value) && sceneActivationBlocks[$0.key] != surface($0.value)
        }
        sustainingMutedCells = sustainingMutedCells.filter { playable[$0.key]?.cell == $0.value }
        let evaluating = activeLayerIDs.union(sustainingMutedCells.keys)
        var representatives = selection.objects.map { object in
            let rep = object.representative
            let tick = Int(((rep.bearingDegrees + 90) * 2).rounded())
            let raw = Int(rep.distanceCentimeters.rounded())
            return (rep, Set(instrument.hits(tick: tick, raw: raw).map(\.layerID)), object.sourceOrder)
        }
        if let auditionPoint {
            let rep = DetectionRepresentative(point: auditionPoint)
            let containing = Set(playable.values.filter { $0.candidateOrder == Int.max }.map(\.layerID))
            representatives.append((rep, containing, Int.max))
        }
        let values = ((try? instrument.evaluate(active: playable, activeLayerIDs: evaluating)) ?? []).map { value in
            var value = value
            guard let layer = instrument.layers.first(where: { $0.routings.contains { $0.id == value.routingID } }),
                  let handle = playable[layer.id] else { return value }
            if case .notes(_, .holdUntilNext) = value.value {
                value = SpatialRoutingEvaluation(routingID: value.routingID, target: value.target, value: value.value,
                    cell: handle.cell, toggleGuardSeconds: value.toggleGuardSeconds, commonNotes: value.commonNotes)
                value.midiDestination = layer.midiTarget.flatMap {
                    $0.uniqueID == (instrument.midiTarget?.uniqueID ?? 0) ? nil : .midiEndpoint(uniqueID: $0.uniqueID)
                } ?? .midi
                let angle = PolarDeviceLattice.bearingDegrees(forTick: handle.cell.sector) * .pi / 180
                let x = sin(angle) * Double(handle.cell.ring) / 100
                let y = cos(angle) * Double(handle.cell.ring) / 100
                for (rep, containingLayers, sourceOrder) in representatives where sourceOrder == handle.candidateOrder {
                    let contains = containingLayers.contains(layer.id)
                    let d = contains ? 0 : pow(x - rep.point.xMeters, 2) + pow(y - rep.point.yMeters, 2)
                    value.representativeDistanceSquared = min(value.representativeDistanceSquared, d)
                }
            }
            return value
        }
        if instrument.hasArpeggiatorModulation { arpeggiatorModulation.update(values) }
        let sceneEvents = applySceneControls(at: time, instrument: instrument)
        if auditionPoint != nil, !sceneEvents.isEmpty {
            // End the accepted pointer on Q at the scene edge, before any
            // delayed Main projection. Re-evaluate only real carriers.
            auditionPoint = nil
            auditionSceneNeedsExit = true
            selection = measuredSelection
            return events(commands) + sceneEvents + evaluateSelection(at: time, instrument: instrument, commands: [])
        }
        let programEvents = applyProgramChanges(values: values, playable: playable)
        var musicalValues = values.filter {
            guard !$0.target.isLayerControl else { return false }
            if case .notes(_, .toggle) = $0.value { return false }
            return true
        }
        let toggleValues = measuredToggleValues(instrument: instrument, evaluating: evaluating, handles: selection.sceneControlHandles)
        let measuredToggles = measuredToggleValues(instrument: instrument, evaluating: evaluating, handles: selection.measuredEntryHandles)
        let releaseIDs = measuredReleaseLayerIDs(instrument: instrument)
        musicalValues = applyingReleaseHoldBlocks(to: musicalValues, releaseIDs: releaseIDs, instrument: instrument)
        commands += ledger.apply(musicalValues + toggleValues, releasingLatchedRoutingIDs: releaseIDs, measuredToggleEntries: measuredToggles, profileTime: time)
        if selection.isEmpty {
            commands += ledger.releaseOverlapTails()
            pendingOffs.removeAll()
        }
        var immediate: [SpatialOutputCommand] = []
        for command in commands {
            if case .scheduleOff(_, _, _, _, let delay) = command {
                pendingOffs.append((time + delay / 1_000, command))
            } else { immediate.append(command) }
        }
        return events(immediate) + programEvents + sceneEvents
    }

    mutating func loseMeasurements(at time: Double) -> [MusicEvent] {
        guard auditionPoint != nil, let instrument else { return release(preservingLatches: true) }
        auditionDeadline = time + Self.auditionInterval
        lastFrame = nil
        staleWatch.reset()
        detection.reset()
        measuredSelection = .init(activeHandles: [:], candidateDistancesCentimeters: [:])
        selection = measuredSelection
        mergeAudition(instrument: instrument)
        return evaluateSelection(at: time, instrument: instrument, commands: [])
    }

    mutating func release(preservingLatches: Bool = false) -> [MusicEvent] {
        arpeggiatorModulation = .init()
        let commands = preservingLatches ? ledger.releaseTransient() : ledger.releaseAll()
        pendingOffs.removeAll()
        lastFrame = nil
        auditionPoint = nil
        auditionDeadline = nil
        measuredSelection = .init(activeHandles: [:], candidateDistancesCentimeters: [:])
        staleWatch.reset()
        detection.reset()
        selection = .init(activeHandles: [:], candidateDistancesCentimeters: [:])
        if !preservingLatches {
            panicCells.removeAll(); measuredPanicSurfaces.removeAll(); measuredPanicEntries.removeAll()
        }
        sceneDwell.removeAll()
        if !preservingLatches { releaseEntries.removeAll(); releaseHoldCells.removeAll() }
        if !preservingLatches { scenePanicCells.removeAll() }
        if !preservingLatches { togglePanicEntries.removeAll() }
        sustainingMutedCells.removeAll()
        sceneActivationBlocks.removeAll()
        programEntries.removeAll()
        return events(commands)
    }

    mutating func applyProgramChanges(values: [SpatialRoutingEvaluation], playable: [UUID: CompiledActiveCell]) -> [MusicEvent] {
        guard let instrument else { return [] }
        var entries: [UUID: PolarDeviceLattice] = [:]
        var result: [MusicEvent] = []
        for layer in instrument.layers where activeLayerIDs.contains(layer.id) {
            // The same confirmed selection as notes, computed only by .frame.
            // Forecast/display values and timeAdvanced never enter this path.
            guard let handle = playable[layer.id] else { continue }
            for routing in layer.routings {
                guard routing.target.isProgramChange, let channel = routing.target.midiChannel,
                      case .programChange(let selection) = values.first(where: { $0.routingID == routing.id })?.value else { continue }
                entries[routing.id] = handle.cell
                guard programEntries[routing.id] != handle.cell else { continue }
                let destination: SpatialOutputDestination = routing.target.stripID.map { .audioUnit(stripID: $0) } ?? layer.midiTarget.flatMap {
                    $0.uniqueID == (instrument.midiTarget?.uniqueID ?? 0) ? nil : .midiEndpoint(uniqueID: $0.uniqueID)
                } ?? .midi
                result.append(.programChange(destination: destination,
                                             channel: channel, selection: selection))
            }
        }
        programEntries = entries
        return result
    }

    /// A release cell consumes the current held trigger. Dwelling on that
    /// musical cell cannot immediately restart the chord that was released.
    mutating func applyingReleaseHoldBlocks(to values: [SpatialRoutingEvaluation], releaseIDs: Set<UUID>, instrument: CompiledInstrument) -> [SpatialRoutingEvaluation] {
        guard !releaseHoldCells.isEmpty || !releaseIDs.isEmpty else { return values }
        let layersByRouting = Dictionary(uniqueKeysWithValues: instrument.layers.flatMap { layer in
            layer.routings.map { ($0.id, layer.id) }
        })
        releaseHoldCells = releaseHoldCells.filter { key in
            selection.measuredEntryHandles.contains { $0.layerID == layersByRouting[key.routingID] && surface($0) == key.cell }
        }
        return values.map { evaluation in
            guard case .notes(_, .holdUntilNext) = evaluation.value,
                  let layerID = layersByRouting[evaluation.routingID], let handle = selection.activeHandles[layerID] else { return evaluation }
            let key = SceneCellKey(routingID: evaluation.routingID, cell: surface(handle))
            if releaseIDs.contains(evaluation.routingID) { releaseHoldCells.insert(key) }
            guard releaseHoldCells.contains(key) else { return evaluation }
            return .init(routingID: evaluation.routingID, target: evaluation.target, value: .inactive)
        }
    }

    func measuredToggleValues(instrument: CompiledInstrument, evaluating: Set<UUID>, handles: [CompiledActiveCell]) -> [SpatialRoutingEvaluation] {
        let handles = handles.filter {
            evaluating.contains($0.layerID) && scenePanicCells[$0.layerID]?.contains(surface($0)) != true
                && panicCells[$0.layerID] != surface($0) && sceneActivationBlocks[$0.layerID] != surface($0)
        }
        return handles.flatMap { handle in
            ((try? instrument.evaluate(active: [handle.layerID: handle], activeLayerIDs: [handle.layerID])) ?? []).filter {
                if case .notes(_, .toggle) = $0.value, let cell = $0.cell {
                    return !togglePanicEntries.contains(SceneCellKey(routingID: $0.routingID, cell: surfaceForRouting(cell, routingID: $0.routingID)))
                }
                return false
            }
        }
    }

    func toggleKeys(instrument: CompiledInstrument, handles: [CompiledActiveCell]) -> Set<SceneCellKey> {
        Set(handles.flatMap { handle in
            ((try? instrument.evaluate(active: [handle.layerID: handle], activeLayerIDs: [handle.layerID])) ?? [])
                .compactMap { value in value.cell.map { SceneCellKey(routingID: value.routingID, cell: surfaceForRouting($0, routingID: value.routingID)) } }
        })
    }

    mutating func measuredReleaseLayerIDs(instrument: CompiledInstrument) -> Set<UUID> {
        var entries = Set<SceneCellKey>()
        var released = Set<UUID>()
        for layer in instrument.layers where activeLayerIDs.contains(layer.id) {
            for routing in layer.routings {
                guard case .releaseLayer(let fallback) = routing.target else { continue }
                for handle in selection.sceneControlHandles where handle.layerID == layer.id
                    && scenePanicCells[layer.id]?.contains(surface(handle)) != true {
                    let key = SceneCellKey(routingID: routing.id, cell: surface(handle))
                    entries.insert(key)
                    guard !releaseEntries.contains(key) else { continue }
                    var id = fallback
                    if let summary = layer.cellActions.first(where: { $0.cell == handle.cell })?.groups.first(where: { $0.target == routing.target })?.summary,
                       case .releaseLayer(let own) = summary { id = own }
                    // A release target names a layer; every partition of that layer is released.
                    for target in instrument.layers where instrument.ownerLayerID(of: target.id) == id {
                        released.formUnion(target.routings.map(\.id))
                    }
                }
            }
        }
        let measured = Set(instrument.layers.flatMap { layer in
            layer.routings.filter { if case .releaseLayer = $0.target { return true }; return false }.flatMap { routing in
                selection.measuredEntryHandles.filter { $0.layerID == layer.id }.map { SceneCellKey(routingID: routing.id, cell: surface($0)) }
            }
        })
        releaseEntries = releaseEntries.intersection(measured).union(entries)
        return released
    }

    mutating func applySceneControls(at time: Double,
                                     instrument: CompiledInstrument) -> [MusicEvent] {
        // Stable precedence: document layer/routing order, then ring/sector.
        // Each carrier fires immediately once per measured entry; legacy dwell values are ignored.
        for layer in scenePanicCells.keys {
            let measured = Set(selection.measuredEntryHandles.filter { $0.layerID == layer }.map { surface($0) })
                .union(measuredPanicEntries[layer] ?? [])
            scenePanicCells[layer]?.formIntersection(measured)
            if scenePanicCells[layer]?.isEmpty == true { scenePanicCells[layer] = nil }
        }
        let active = instrument.layers.flatMap { layer -> [(SceneCellKey, SpatialSceneSwitchAction, Double)] in
            guard activeLayerIDs.contains(layer.id) else { return [] }
            return layer.routings.flatMap { routing -> [(SceneCellKey, SpatialSceneSwitchAction, Double)] in
                guard case let .sceneSwitch(defaultAction, dwell) = routing.target else { return [] }
                return selection.sceneControlHandles.filter { $0.layerID == layer.id && scenePanicCells[layer.id]?.contains(surface($0)) != true }.sorted {
                    ($0.cell.ring, $0.cell.sector) < ($1.cell.ring, $1.cell.sector)
                }.map { handle in
                    var action = defaultAction
                    if let summary = layer.cellActions.first(where: { $0.cell == handle.cell })?.groups.first(where: { $0.target == routing.target })?.summary,
                       case .sceneSwitch(let ownAction) = summary { action = ownAction }
                    return (SceneCellKey(routingID: routing.id, cell: surface(handle)), action, max(0, dwell))
                }
            }
        }
        let activeIDs = Set(active.map(\.0))
        sceneDwell = sceneDwell.filter { activeIDs.contains($0.key) }
        var events: [MusicEvent] = []
        for (key, action, _) in active {
            let state = sceneDwell[key] ?? (enteredAt: time, fired: false)
            guard !state.fired else {
                sceneDwell[key] = state; continue
            }
            sceneDwell[key] = (state.enteredAt, true)
            guard let destination = scene(for: action, in: instrument) else { continue }
            events += activateScene(destination, instrument: instrument)
        }
        return events
    }

    mutating func activateScene(_ destination: SpatialScene, instrument: CompiledInstrument) -> [MusicEvent] {
        arpeggiatorModulation = .init()
        sceneGeneration &+= 1
        appliesSceneMembership = true
        currentSceneID = destination.id
        let controls = Set(instrument.layers.compactMap { layer in
            layer.routings.contains { $0.target.isLayerControl } ? layer.id : nil
        })
        let previouslyActive = activeLayerIDs
        activeLayerIDs = destination.activeLayerIDs.union(controls)
        for (layerID, handle) in selection.activeHandles where !activeLayerIDs.contains(layerID) {
            sustainingMutedCells[layerID] = handle.cell
        }
        for (layerID, handle) in selection.activeHandles
            where activeLayerIDs.contains(layerID) && !previouslyActive.contains(layerID) {
            sceneActivationBlocks[layerID] = surface(handle)
        }
        return [.sceneChanged(destination.id)]
    }

    func scene(for action: SpatialSceneSwitchAction, in instrument: CompiledInstrument) -> SpatialScene? {
        guard !instrument.scenes.isEmpty else { return nil }
        switch action {
        case .scene(let id): return instrument.scenes.first { $0.id == id }
        case .next, .previous:
            let index = instrument.scenes.firstIndex { $0.id == currentSceneID } ?? 0
            let delta = action == .next ? 1 : -1
            let destination = (index + delta + instrument.scenes.count) % instrument.scenes.count
            return instrument.scenes[destination]
        }
    }

    func events(_ commands: [SpatialOutputCommand]) -> [MusicEvent] {
        commands.compactMap { command in
            switch command {
            case let .noteOn(destination, channel, note):
                return .noteOn(destination: destination, channel: channel, note: note)
            case let .noteOff(destination, channel, note):
                return .noteOff(destination: destination, channel: channel, note: note)
            case let .scalar(id, target, value):
                if let destination = midiDestination(for: id), target.destination == .midi {
                    return .midiValue(destination: destination, target: target, value: min(max(value, 0), 1))
                }
                return .scalar(routingID: id, target: target, value: min(max(value, 0), 1))
            case let .boolean(id, target, value):
                if let destination = midiDestination(for: id), target.destination == .midi {
                    return .midiValue(destination: destination, target: target, value: value ? 1 : 0)
                }
                return .boolean(routingID: id, target: target, value: value)
            case let .allNotesOff(destination, channel):
                return .allNotesOff(destination: destination, channel: channel)
            case .scheduleOff: return nil
            }
        }
    }

    func midiDestination(for routingID: UUID) -> SpatialOutputDestination? {
        guard let target = instrument?.layers.first(where: { $0.routings.contains { $0.id == routingID } })?.midiTarget,
              target.uniqueID != (instrument?.midiTarget?.uniqueID ?? 0) else { return nil }
        return .midiEndpoint(uniqueID: target.uniqueID)
    }

    func panicEvents() -> [MusicEvent] {
        // Router may have either destination bound, even without an installed
        // document. All channels are covered, independently of route metadata.
        [SpatialOutputDestination.midi, .audioUnit(stripID: InstrumentChannel.legacyID)].flatMap { destination in
            (UInt8(0)...UInt8(15)).map { .allNotesOff(destination: destination, channel: $0) }
        }
    }
}
