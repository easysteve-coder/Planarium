import Combine
import Foundation
import PlanariumDomain
import PlanariumRuntime

public enum ChannelSlotStatus: Equatable, Sendable {
    case loading, loaded, bypass
    case failed(String)
}

/// Main owns the document-facing graph. Desired values also govern pending
/// load completions and retire acknowledgements; late work cannot reinstall
/// an obsolete channel. Runtime owns only an immutable schedule value.
@MainActor public final class AudioHost: ObservableObject {
    public var onEditorClosed: (() -> Void)?
    @Published public private(set) var status: [ChannelSlot: ChannelSlotStatus] = [:]
    public private(set) var channel = InstrumentChannel()
    @Published public private(set) var channelHosts: [UUID: AudioHost] = [:]
    public private(set) var mixerChannels: [InstrumentChannel] = []
    private var comparisonReference: [InstrumentChannel] = []
    public func setComparisonReference(_ channels: [InstrumentChannel]) {
        comparisonReference = channels
        if let instrument { pinComparisonState(instrument, at: .instrument) }
        for (id, instance) in inserts { pinComparisonState(instance, at: .insert(id)) }
        for child in channelHosts.values { child.setComparisonReference(channels.filter { $0.id == child.channel.id }) }
    }
    private func pinComparisonState(_ instance: PluginInstance, at slot: ChannelSlot) {
        let saved = comparisonReference.first { $0.id == channel.id }
        let plugin: InstrumentPlugin?
        switch slot {
        case .instrument: plugin = saved?.instrument
        case .insert(let id): plugin = saved?.inserts.first { $0.id == id }?.plugin
        }
        instance.pinComparisonState(plugin?.identity == instance.identity ? plugin?.state : nil)
    }
    public private(set) var masterLevelDecibels: Double = 0
    private var childObservations: [UUID: AnyCancellable] = [:]
    private weak var mixerOwner: AudioHost?
    private var retiredHosts: [UUID: AudioHost] = [:]
    private var mixerReconfiguring = false
    private var pendingMixerStateRestore = false
    private var pendingMixerConfiguration: AudioHostConfiguration?
    private var mixerPreparationCompletion: (@MainActor () -> Void)?
    private var boundStripID: UUID?
    private let masterPeaks = PeakHolder()
    public func host(for id: UUID) -> AudioHost? { channel.id == id ? self : channelHosts[id] }
    public func takeMasterPeaks() -> StereoPeaks { masterPeaks.take() }
    public func applyMixer(_ channels: [InstrumentChannel], masterLevelDecibels: Double,
                           restoringPluginStates: Bool = false) throws {
        guard channels.count <= InstrumentDocument.maximumChannels else { throw CompiledInstrumentError.tooManyChannels(channels.count) }
        guard Set(channels.map(\.id)).count == channels.count else { throw CompiledInstrumentError.duplicateChannelID }
        guard !closed else { return }
        guard channels.count <= 1 || graph is any MixerGraphBoundary else { throw PluginLoadError("Audio graph does not support multiple channels") }
        mixerChannels = channels; self.masterLevelDecibels = masterLevelDecibels
        if mixerReconfiguring { pendingMixerStateRestore = pendingMixerStateRestore || restoringPluginStates; return }
        (graph as? any MixerGraphBoundary)?.setMasterLevel(decibels: masterLevelDecibels)
        let rootID = channel.id
        let wanted = Set(channels.filter { $0.id != rootID }.map(\.id))
        for (id, child) in channelHosts where !wanted.contains(id) {
            let retirement = UUID()
            channelHosts[id] = nil; childObservations[id] = nil; retiredHosts[retirement] = child
            child.shutdown { [weak self] in self?.retiredHosts[retirement] = nil }
        }
        let anySolo = channels.contains { $0.soloed }
        for value in channels {
            var effective = value; effective.muted = value.muted || (anySolo && !value.soloed)
            if value.id == rootID { apply(effective, restoringPluginStates: restoringPluginStates); continue }
            let child: AudioHost
            if let existing = channelHosts[value.id] { child = existing }
            else {
                guard let graph = graph as? any MixerGraphBoundary else { throw PluginLoadError("Missing mixer graph") }
                child = try AudioHost(components: components, graph: graph.makeChannelGraph(), runtime: runtime,
                                      windows: windows, configuration: configuration, hostMusicalClock: hostMusicalClock)
                child.onEditorClosed = { [weak self] in self?.onEditorClosed?() }
                child.mixerOwner = self
                child.comparisonReference = comparisonReference
                channelHosts[value.id] = child
                childObservations[value.id] = child.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            }
            child.apply(effective, restoringPluginStates: restoringPluginStates)
            if isRunning && !child.isRunning { try child.start() }
        }
        if !channels.contains(where: { $0.id == rootID }) { apply(.init(id: rootID)) }
    }
    public func snapshotMixer(comparingTo reference: [InstrumentChannel]? = nil) throws -> [InstrumentChannel] {
        try mixerChannels.map { value in
            var value = value
            if let snapshot = try host(for: value.id)?.snapshotChannel(comparingTo: reference?.first { $0.id == value.id }) {
                value.instrument = snapshot.instrument; value.inserts = snapshot.inserts
            }
            return value
        }
    }
    public private(set) var lastSteps: [ChannelChange] = []
    @Published public private(set) var configuration: AudioHostConfiguration
    public private(set) var instrument: PluginInstance?
    public private(set) var inserts: [UUID: PluginInstance] = [:]
    private let components: any PluginComponentSource
    private let graph: any AudioGraphBoundary
    public let hostMusicalClock: HostMusicalClock
    private let runtime: any AudioRuntimeBoundary
    private let windows: any PluginWindowFactory
    private struct Loading { let token: UUID; let identity: SpatialAudioUnitIdentity }
    private var loading: [ChannelSlot: Loading] = [:]
    private struct EditorChoice {
        let token = UUID()
        let identity: SpatialAudioUnitIdentity
        let title: String
        let allowed: @MainActor () -> Bool
    }
    private var editorChoices: [ChannelSlot: EditorChoice] = [:]
    private var editorLeases: [ChannelSlot: UUID] = [:]
    /// Only explicit strip choices call this. Preset/history paths never do.
    public func openEditorWhenLoaded(at slot: ChannelSlot, identity: SpatialAudioUnitIdentity,
                                     title: String, allowed: @escaping @MainActor () -> Bool) {
        guard !closed, wanted(slot)?.identity == identity else { return }
        let choice = EditorChoice(identity: identity, title: title, allowed: allowed)
        editorChoices[slot] = choice; editorLeases[slot] = choice.token
        openChosenEditors()
    }
    private func openChosenEditors() {
        for (slot, choice) in editorChoices {
            guard !closed, choice.allowed(), wanted(slot)?.identity == choice.identity else {
                editorChoices[slot] = nil; editorLeases[slot] = nil; continue
            }
            if case .failed = status[slot] { editorChoices[slot] = nil; editorLeases[slot] = nil; continue }
            guard status[slot] == .loaded, let instance = instance(at: slot),
                  instance.identity == choice.identity else { continue }
            editorChoices[slot] = nil
            instance.openEditor(title: choice.title, allowed: { [weak self, weak instance] in
                guard let self, let instance else { return false }
                return choice.allowed() && self.editorLeases[slot] == choice.token &&
                    self.wanted(slot)?.identity == choice.identity && self.instance(at: slot) === instance
            })
        }
    }
    private var failures: [ChannelSlot: SpatialAudioUnitIdentity] = [:]
    private var retiring = false
    private var retireAcknowledged = false
    private var stateRefreshRetire = false
    private var closed = false
    private var performancePaused = false
    private var instrumentBound = false
    private var selectedInstrumentPlayback: SpatialAudioUnitIdentity?
    private var startAfterRetire = false
    private var stopAfterRetire = false
    private var shutdownCompletions: [@MainActor () -> Void] = []
    private var reconfiguration: AudioHostConfiguration?
    private var resumeAfterReconfigure = false
    private var recoveringConfigurationChange = false
    @Published public private(set) var audioEnabled = false
    @Published public private(set) var isRunning = false {
        didSet { scheduleAvailability?.set(isRunning) }
    }
    private var scheduleAvailability: ScheduleAvailability?
    private var resetInstrumentOnAttach = false
    private var graphReady = true
    private struct InsertEdge: Equatable {
        let documentID: UUID
        let identity: SpatialAudioUnitIdentity
        let instanceID: UUID?
    }
    private var connectedInserts: [InsertEdge] = []
    private var fadeTask: Task<Void, Never>?
    private var fadeGeneration: UInt64 = 0
    private var rewiring = false
    private var canFade: Bool {
        isRunning && !performancePaused && !closed && !retiring && reconfiguration == nil &&
        instrument?.identity == channel.instrument?.identity &&
        !(channel.instrument.map { instrument?.needsStateRefresh($0.state) == true } ?? false)
    }
    private var desiredInserts: [InsertEdge] {
        // Bypass is an AU property, not a topology change.  Keeping a loaded
        // insert in the graph preserves its tail and avoids a host-imposed
        // silent rewire whenever the user presses the insert switch.
        channel.inserts.compactMap {
            guard let instance = inserts[$0.id], instance.identity == $0.plugin.identity else { return nil }
            return InsertEdge(documentID: $0.id, identity: $0.plugin.identity, instanceID: instance.id)
        }
    }
    private let meterPeaks = PeakHolder()
    private var meterVisible = false
    private var meterViewers: Set<UUID> = []
    private static let directMeterViewer = UUID()
    @Published public private(set) var isMeterActive = false
    private var meterSuspended = false
    public func setMeterVisible(_ visible: Bool, viewer: UUID? = nil) {
        let viewer = viewer ?? Self.directMeterViewer
        if visible { meterViewers.insert(viewer) } else { meterViewers.remove(viewer) }
        meterVisible = !meterViewers.isEmpty
        synchronizeMeter()
    }
    /// Sleep/termination remove the tap immediately, even if Q is blocked.
    public func suspendMeter() { meterSuspended = true; removeMeter(); for child in channelHosts.values { child.suspendMeter() } }
    public func takeMeterPeaks() -> StereoPeaks { meterPeaks.take() }
    private func removeMeter() {
        if isMeterActive { graph.removeMeter(); isMeterActive = false }
        (graph as? any MixerGraphBoundary)?.removeMasterMeter()
        _ = meterPeaks.take()
        _ = masterPeaks.take()
    }
    private func synchronizeMeter() {
        guard meterVisible, isRunning, !meterSuspended, !performancePaused, !closed, reconfiguration == nil else {
            removeMeter(); return
        }
        if !isMeterActive {
            do {
                try graph.installMeter(meterPeaks)
                try (graph as? any MixerGraphBoundary)?.installMasterMeter(masterPeaks)
                isMeterActive = true
            }
            catch {
                graph.removeMeter(); (graph as? any MixerGraphBoundary)?.removeMasterMeter()
                graphFailure = "Audio meter: \(errorMessage(error))"
            }
        }
    }
    @Published public private(set) var graphFailure: String?
    @Published public private(set) var configurationNotice: String?
    @Published public private(set) var unavailableDeviceID: UInt32?
    /// Latest playback intent, including a start waiting for Q acknowledgement.
    /// A pending Stop must stay stopped after system sleep/wake.
    public var playbackRequested: Bool {
        !closed && (startAfterRetire || resumeAfterReconfigure || (isRunning && !performancePaused))
    }

    public init(components: any PluginComponentSource, graph: any AudioGraphBoundary,
                runtime: any AudioRuntimeBoundary, windows: any PluginWindowFactory,
                configuration: AudioHostConfiguration = .init(), hostMusicalClock: HostMusicalClock = HostMusicalClock()) throws {
        self.hostMusicalClock = hostMusicalClock
        self.components = components; self.graph = graph; self.runtime = runtime
        self.windows = windows; self.configuration = configuration
        graph.setHostMusicalClock(hostMusicalClock)
        do { try graph.configure(configuration) }
        catch let error as PluginLoadError where error == .graphConstructionTimedOut {
            graphReady = false; graphFailure = error.message; configurationNotice = error.message
            status[.instrument] = .failed(error.message)
        }
        graph.setLevel(decibels: 0)
        graph.observeConfigurationChange { [weak self] in self?.engineConfigurationChanged() }
    }
    /// Explicit start only. Construction/apply do not open an audio device.
    /// During retire this records a request; isRunning is confirmed only
    /// after the asynchronous acknowledgement and successful graph start.
    public func start() throws {
        guard !closed else { return }
        audioEnabled = true
        if retiring { startAfterRetire = true; return }
        guard graphReady else { throw PluginLoadError("Audio configuration unavailable") }
        graph.setMuted(channel.muted)
        do { try graph.start() }
        catch { graphFailure = "Audio start failed"; throw error }
        graphFailure = nil; isRunning = true; performancePaused = false; meterSuspended = false
        if instrument != nil { status[.instrument] = .loaded }
        if let instrument, !instrumentBound { attachInstrument(instrument) }
        synchronizeMeter()
        for child in channelHosts.values { try child.start() }
    }
    public func stop() { stop(preservingPreference: false) }
    /// Sleep and a graph failure suspend playback without changing the user's
    /// persisted on/off choice. Explicit Stop still changes that choice.
    public func suspendPlayback() { stop(preservingPreference: true) }
    private func stop(preservingPreference: Bool) {
        if !preservingPreference { audioEnabled = false }
        for child in channelHosts.values { child.stop(preservingPreference: preservingPreference) }
        selectedInstrumentPlayback = nil
        removeMeter()
        performancePaused = true; startAfterRetire = false; resumeAfterReconfigure = false
        cancelFade()
        reconcile()
        if instrumentBound { retireInstrument() }
        if retiring { stopAfterRetire = true }
        else { graph.stop(); isRunning = false }
    }


    public func apply(_ value: InstrumentChannel, restoringPluginStates: Bool = false) {
        guard !closed else { return }
        // A template may adopt a freshly captured editor state into the
        // document. If it is already live, accept it into the state cache
        // without retiring Q or writing fullState back to the same AU.
        if let plugin = value.instrument, instrument?.identity == plugin.identity,
           restoringPluginStates || plugin.state != channel.instrument?.state {
                instrument?.prepareStateRestore(plugin.state)
        }
        for insert in value.inserts where inserts[insert.id]?.identity == insert.plugin.identity {
            if restoringPluginStates || insert.plugin.state != channel.inserts.first(where: { $0.id == insert.id })?.plugin.state {
                inserts[insert.id]?.prepareStateRestore(insert.plugin.state)
            }
        }
        lastSteps = ChannelDifference.steps(from: channel, to: value)
        let previousChannel = channel
        channel = value
        for slot in editorLeases.keys {
            let previousIdentity: SpatialAudioUnitIdentity?
            switch slot {
            case .instrument: previousIdentity = previousChannel.instrument?.identity
            case .insert(let id): previousIdentity = previousChannel.inserts.first { $0.id == id }?.plugin.identity
            }
            if wanted(slot) == nil || wanted(slot)?.identity != previousIdentity { editorLeases[slot] = nil }
        }
        if restoringPluginStates { cancelPendingChosenEditors() }
        for (slot, choice) in editorChoices where wanted(slot)?.identity != choice.identity { editorChoices[slot] = nil }
        if selectedInstrumentPlayback != channel.instrument?.identity { selectedInstrumentPlayback = nil }
        for change in lastSteps {
            switch change {
            case .instrument: failures[.instrument] = nil
            default: break
            }
        }
        // Failure identity is retained for explicit retry, but a changed
        // identity clears it. No unchanged apply silently reloads failed AUs.
        for (slot, identity) in failures where wanted(slot)?.identity != identity { failures[slot] = nil }
        if lastSteps.contains(where: { if case .level = $0 { return true }; return false }) {
            graph.setLevel(decibels: value.levelDecibels)
        }
        graph.setMuted(value.muted)
        graph.setPan(value.pan)
        if instrument?.identity != value.instrument?.identity ||
            (value.instrument.map { instrument?.needsStateRefresh($0.state) == true } ?? false) { cancelFade() }
        reconcile()
    }
    public func retry(_ slot: ChannelSlot) {
        guard !closed else { return }
        failures[slot] = nil
        reconcile()
    }
    /// Only the explicit document-owner choice uses this request. Presets,
    /// undo and ordinary channel edits continue to load without starting.
    public func playSelectedInstrumentWhenLoaded(_ identity: SpatialAudioUnitIdentity) {
        guard !closed, channel.instrument?.identity == identity else { return }
        stopAfterRetire = false // latest explicit choice supersedes a pending Stop
        selectedInstrumentPlayback = identity
        startSelectedInstrumentIfLoaded()
    }
    private func startSelectedInstrumentIfLoaded() {
        guard let wanted = selectedInstrumentPlayback else { return }
        if case .failed = status[.instrument] { selectedInstrumentPlayback = nil; return }
        guard instrument?.identity == wanted, status[.instrument] == .loaded else { return }
        selectedInstrumentPlayback = nil
        do { try (mixerOwner ?? self).start() } catch { graphFailure = "Audio start failed" }
    }
    public func cancelPendingChosenEditors() {
        editorChoices.removeAll(); editorLeases.removeAll()
        for child in channelHosts.values { child.cancelPendingChosenEditors() }
    }
    /// Strip clicks explicitly resolve a UI-only native bypass override, even
    /// when the persisted flag already has the requested value.
    public func setInsertBypassFromStrip(_ id: UUID, bypassed: Bool) {
        guard !closed, channel.inserts.contains(where: { $0.id == id && $0.bypassed == bypassed }),
              let instance = inserts[id] else { return }
        instance.setBypassFromStrip(bypassed)
        status[.insert(id)] = bypassed ? .bypass : .loaded
    }
    public func instance(at slot: ChannelSlot) -> PluginInstance? {
        switch slot { case .instrument: return instrument; case .insert(let id): return inserts[id] }
    }
    public func snapshotChannel(comparingTo reference: InstrumentChannel? = nil) throws -> InstrumentChannel {
        var value = channel
        if let instrument, value.instrument?.identity == instrument.identity {
            if let saved = reference?.instrument, saved.identity == instrument.identity {
                value.instrument?.state = try instrument.readState(comparingTo: saved.state)
            } else { value.instrument?.state = try instrument.readState() }
        }
        for index in value.inserts.indices {
            if let instance = inserts[value.inserts[index].id] {
                if let saved = reference?.inserts.first(where: { $0.id == value.inserts[index].id && $0.plugin.identity == instance.identity }) {
                    value.inserts[index].plugin.state = try instance.readState(comparingTo: saved.plugin.state)
                } else { value.inserts[index].plugin.state = try instance.readState() }
            }
        }
        return value
    }
    /// Initial template state only, once per live instance. Ordinary host
    /// publications never serialize specified/full AU states on Main.
    public func captureUnspecifiedChannelState() throws -> InstrumentChannel? {
        var value = channel
        let instrumentNeedsCapture = value.instrument?.state.isEmpty == true && instrument?.needsUnspecifiedStateCapture == true
        let insertNeedsCapture = value.inserts.contains { $0.plugin.state.isEmpty && inserts[$0.id]?.needsUnspecifiedStateCapture == true }
        guard instrumentNeedsCapture || insertNeedsCapture else { return nil }
        if let instrument, value.instrument?.identity == instrument.identity,
           value.instrument?.state.isEmpty == true {
            value.instrument?.state = try instrument.captureUnspecifiedState()
        }
        for index in value.inserts.indices where value.inserts[index].plugin.state.isEmpty {
            if let instance = inserts[value.inserts[index].id], instance.identity == value.inserts[index].plugin.identity {
                value.inserts[index].plugin.state = try instance.captureUnspecifiedState()
            }
        }
        return value
    }
    /// The only full graph rebuild. The old instrument remains attached
    /// until Q has solved its notes and acknowledged retire. Instances and
    /// editors survive device/rate changes, only graph resources change.
    public func configure(_ value: AudioHostConfiguration) {
        guard !closed, !graphReady || value != (pendingMixerConfiguration ?? reconfiguration ?? configuration) else { return }
        runtime.releaseForConfigurationChange()
        if !channelHosts.isEmpty || !retiredHosts.isEmpty || mixerReconfiguring {
            resumeAfterReconfigure = playbackRequested || resumeAfterReconfigure
            pendingMixerConfiguration = value
            guard !mixerReconfiguring else { return }
            mixerReconfiguring = true
            let activeChildren = Array(channelHosts.values)
            let removedChildren = Array(retiredHosts.values)
            let children = activeChildren + removedChildren
            var remaining = children.count
            for child in children {
                let ready: @MainActor () -> Void = { [weak self] in
                    remaining -= 1
                    guard remaining == 0, let self, !self.closed, let latest = self.pendingMixerConfiguration else { return }
                    self.requestConfiguration(latest)
                }
                if activeChildren.contains(where: { $0 === child }) { child.prepareMixerRebuild(ready) }
                else { child.shutdown(completion: ready) }
            }
            return
        }
        configurationNotice = nil
        requestConfiguration(value)
    }
    /// Detach at the old render/retire boundary, but keep each AU and editor.
    /// The root may replace its engine only after every sibling is detached.
    private func prepareMixerRebuild(_ completion: @escaping @MainActor () -> Void) {
        removeMeter(); loading.removeAll(); cancelFade()
        resumeAfterReconfigure = playbackRequested
        mixerPreparationCompletion = completion
        if instrument != nil { retireInstrument() }
        else { finishMixerPreparation() }
    }
    private func finishMixerPreparation() {
        if let instrument { graph.remove(instrument) }
        graph.stop(); isRunning = false; graph.close(); graphReady = false
        connectedInserts.removeAll()
        let completion = mixerPreparationCompletion; mixerPreparationCompletion = nil
        completion?()
    }
    private func completeMixerRebuild(_ configuration: AudioHostConfiguration) {
        guard !closed, !graphReady else { return }
        reconfiguration = configuration
        rebuild(retainedInstrument: instrument)
    }
    private func engineConfigurationChanged() {
        // Detaching siblings can itself notify the shared engine. The active
        // barrier already rebuilds it; never replace the latest device intent
        // with the old configuration while that barrier is in progress.
        guard !closed, !mixerReconfiguring else { return }
        let resume = playbackRequested
        isRunning = false
        resetInstrumentOnAttach = true
        for child in channelHosts.values { child.resetInstrumentOnAttach = true }
        resumeAfterReconfigure = resume
        recoveringConfigurationChange = true
        configurationNotice = "Audio output changed; rebuilding"
        if !channelHosts.isEmpty {
            // Force the same all-strip retire barrier even when the requested
            // device value did not change; the native engine did change.
            graphReady = false
            configure(reconfiguration ?? configuration)
        } else { runtime.releaseForConfigurationChange(); requestConfiguration(reconfiguration ?? configuration) }
    }
    private func requestConfiguration(_ value: AudioHostConfiguration) {
        removeMeter()
        reconfiguration = value
        cancelFade()
        resumeAfterReconfigure = (isRunning && !performancePaused) || resumeAfterReconfigure
        if retireAcknowledged, fadeTask == nil { finishRetiredInstrument() }
        else if instrument != nil { retireInstrument() } else if !retiring { rebuild() }
    }
    public func shutdown(completion: @escaping @MainActor () -> Void = {}) {
        let children = Array(channelHosts.values) + Array(retiredHosts.values)
        channelHosts.removeAll(); retiredHosts.removeAll(); childObservations.removeAll()
        var remaining = children.count + 1
        let finished: @MainActor () -> Void = {
            remaining -= 1
            if remaining == 0 { self.graph.close(); completion() }
        }
        for child in children { child.shutdown(completion: finished) }
        shutdownSingle(completion: finished)
    }
    private func shutdownSingle(completion: @escaping @MainActor () -> Void) {
        selectedInstrumentPlayback = nil
        shutdownCompletions.append(completion)
        removeMeter()
        closed = true
        graph.observeConfigurationChange(nil)
        cancelFade()
        channel = .init()
        reconfiguration = nil
        loading.removeAll()
        editorChoices.removeAll(); editorLeases.removeAll()
        reconcile()
    }

    private func wanted(_ slot: ChannelSlot) -> InstrumentPlugin? {
        switch slot {
        case .instrument: return channel.instrument
        case .insert(let id): return channel.inserts.first(where: { $0.id == id })?.plugin
        }
    }
    private func reconcile() {
        if retireAcknowledged, fadeTask == nil { finishRetiredInstrument(); return }
        // A deleted strip owns its entire old chain until retire and silence
        // have both completed. Desired empty inserts must not rewire it early.
        if closed, instrument != nil {
            if !retiring { retireInstrument() }
            return
        }
        // Keep active AU bypass/removal/state untouched until silence is
        // acknowledged. channel remains the sole latest desired document.
        if canFade && !rewiring && desiredInserts != connectedInserts {
            beginFade(); return
        }
        if fadeTask != nil { return }
        for (slot, request) in loading where wanted(slot)?.identity != request.identity { loading[slot] = nil }
        for (id, instance) in inserts where wanted(.insert(id))?.identity != instance.identity || channel.inserts.filter({ $0.id == id }).count != 1 {
            release(instance); inserts[id] = nil; status[.insert(id)] = nil
        }
        let wantedSlots = Set(channel.inserts.map { ChannelSlot.insert($0.id) })
        for slot in status.keys where slot != .instrument && !wantedSlots.contains(slot) { status[slot] = nil }
        for insert in channel.inserts {
            let slot = ChannelSlot.insert(insert.id)
            if let instance = inserts[insert.id] { update(instance, slot: slot, plugin: insert.plugin, bypass: insert.bypassed) }
            else { load(slot, plugin: insert.plugin) }
        }
        if !retiring {
            if let instance = instrument {
                if failures[.instrument] == instance.identity || instance.identity != channel.instrument?.identity || (instrumentBound && boundStripID != channel.id) || reconfiguration != nil || (channel.instrument.map { instance.needsStateRefresh($0.state) } ?? false) { retireInstrument() }
                else if let plugin = channel.instrument { update(instance, slot: .instrument, plugin: plugin, bypass: false) }
            } else if reconfiguration != nil { rebuild() }
            else if let plugin = channel.instrument { load(.instrument, plugin: plugin) }
            else { status[.instrument] = nil }
        }
        connect()
        if closed && !retiring && instrument == nil {
            graph.stop(); isRunning = false
            let callbacks = shutdownCompletions; shutdownCompletions.removeAll()
            callbacks.forEach { $0() }
        }
    }
    private func update(_ instance: PluginInstance, slot: ChannelSlot, plugin: InstrumentPlugin, bypass: Bool) {
        do {
            try instance.applyState(plugin.state)
            if slot != .instrument { instance.applyBypass(bypass) }
            pinComparisonState(instance, at: slot)
            status[slot] = instance.effectiveBypass ? .bypass : .loaded
        } catch { status[slot] = .failed("Plug-in state: \(error)") }
    }
    private func load(_ slot: ChannelSlot, plugin: InstrumentPlugin) {
        guard !closed, graphReady, loading[slot] == nil, failures[slot] != plugin.identity else { return }
        let validType = slot == .instrument ? UInt32(0x61756D75) : UInt32(0x61756678)
        guard plugin.identity.componentType == validType,
              plugin.identity.componentSubType != 0, plugin.identity.componentManufacturer != 0,
              slot == .instrument || channel.inserts.filter({ .insert($0.id) == slot }).count == 1 else {
            failures[slot] = plugin.identity; status[slot] = .failed("Invalid component or duplicate insert ID"); return
        }
        let token = UUID()
        loading[slot] = Loading(token: token, identity: plugin.identity)
        status[slot] = .loading
        components.load(plugin.identity) { [weak self] result in
            guard let self else { return }
            guard self.loading[slot]?.token == token, !self.closed,
                  let current = self.wanted(slot), current.identity == plugin.identity else { return }
            self.loading[slot] = nil
            switch result {
            case .failure(let error):
                self.failures[slot] = plugin.identity; self.status[slot] = .failed(error.message)
            case .success(let unit):
                let instance = PluginInstance(identity: plugin.identity, unit: unit, windows: self.windows)
                instance.onEditorClosed = { [weak self] in self?.onEditorClosed?() }
                do {
                    try instance.applyState(current.state)
                    if case .insert(let id) = slot {
                        instance.applyBypass(self.channel.inserts.first(where: { $0.id == id })?.bypassed ?? false)
                    }
                    try self.graph.attach(instance, instrument: slot == .instrument)
                    if slot == .instrument {
                        self.instrument = instance; self.attachInstrument(instance)
                    } else if case .insert(let id) = slot { self.inserts[id] = instance }
                    self.update(instance, slot: slot, plugin: current,
                                bypass: self.channel.inserts.first(where: { .insert($0.id) == slot })?.bypassed ?? false)
                } catch {
                    self.release(instance)
                    self.failures[slot] = plugin.identity; self.status[slot] = .failed("Plug-in load: \(error)")
                }
            }
            self.connect()
            if let instance = self.instance(at: slot), self.status[slot] == .loaded || self.status[slot] == .bypass {
                instance.observeBypass { [weak self, weak instance] bypassed in
                    guard let self, let instance, self.instance(at: slot) === instance else { return }
                    if self.status[slot] == .loaded || self.status[slot] == .bypass {
                        self.status[slot] = bypassed ? .bypass : .loaded
                    }
                }
            }
            self.startSelectedInstrumentIfLoaded()
            self.openChosenEditors()
        }
    }
    private func attachInstrument(_ instance: PluginInstance) {
        guard !closed, !performancePaused, !retiring, !instrumentBound,
              failures[.instrument] != instance.identity else { return }
        if let schedule = instance.scheduleBoundary() {
            // The runtime lease retains this graph owner until retire, even
            // if the app drops its last reference. shutdown breaks the lease.
            instrumentBound = true
            boundStripID = channel.id
            let availability = ScheduleAvailability()
            availability.set(isRunning)
            scheduleAvailability = availability
            runtime.attach(id: instance.id, stripID: channel.id,
                           schedule: RetainedSchedule(owner: self, schedule: schedule, availability: availability,
                                                      engineRunning: graph.scheduleAvailabilityProbe()),
                           resetOnBind: resetInstrumentOnAttach)
            resetInstrumentOnAttach = false
        }
    }
    private func retireInstrument() {
        guard !retiring, let old = instrument else { return }
        cancelFade()
        stateRefreshRetire = !closed && reconfiguration == nil && old.identity == channel.instrument?.identity
        retiring = true; status[.instrument] = .loading
        let oldEngineRunning = graph.scheduleAvailabilityProbe()
        // Main closes only the planned-On gate immediately. Q still has to
        // send ordinary releases through the existing live boundary before ack.
        scheduleAvailability?.blockPlanning()
        runtime.retire(id: old.id) { [self] in
            if !oldEngineRunning() { resetInstrumentOnAttach = true }
            scheduleAvailability?.set(false)
            scheduleAvailability = nil
            instrumentBound = false
            boundStripID = nil
            // RETIRE: release-after-ack
            retireAcknowledged = true
            if isRunning && !performancePaused &&
                (mixerPreparationCompletion != nil || !(stateRefreshRetire && reconfiguration == nil && failures[.instrument] != old.identity && old.identity == channel.instrument?.identity)) {
                beginFade()
            } else { finishRetiredInstrument() }
        }
    }
    private func finishRetiredInstrument() {
        guard retireAcknowledged, let old = instrument else { return }
        retireAcknowledged = false
        if (closed || performancePaused) && isRunning { graph.stop(); isRunning = false }
        if mixerPreparationCompletion != nil, !closed {
            retiring = false
            finishMixerPreparation()
            return
        }
        if stateRefreshRetire, !closed, reconfiguration == nil, failures[.instrument] != old.identity,
           old.identity == channel.instrument?.identity, let current = channel.instrument {
            // fullState may replace parameter objects/ranges: Q is retired
            // before touching it, then receives a fresh immutable schedule.
            retiring = false
            update(old, slot: .instrument, plugin: current, bypass: false)
            if case .failed = status[.instrument] { failures[.instrument] = old.identity; release(old); instrument = nil }
            reconcile()
        } else if reconfiguration != nil && !closed {
            if !isRunning { graph.stop() }
            graph.remove(old)
            instrument = nil
            retiring = false
            rebuild(retainedInstrument: old)
        } else {
            release(old); instrument = nil; retiring = false
            reconcile()
        }
        finishRetirePlayback()
        if let completion = mixerPreparationCompletion { mixerPreparationCompletion = nil; completion() }
    }
    private func finishRetirePlayback() {
        guard !closed else { return }
        if stopAfterRetire {
            stopAfterRetire = false; graph.stop(); isRunning = false
        }
        if startAfterRetire {
            startAfterRetire = false
            do { try start() } catch { graphFailure = "Audio start failed" }
        } else if performancePaused {
            graph.stop(); isRunning = false
        } else if let instrument { attachInstrument(instrument) }
    }
    private func release(_ instance: PluginInstance) {
        instance.beginRelease()
        graph.remove(instance)
        instance.finishRelease()
    }
    private func connect() {
        guard graphReady else { return }
        if canFade && !rewiring && desiredInserts != connectedInserts { beginFade(); return }
        if fadeTask != nil { return }
        let result = graph.connect(instrument: instrument, inserts: channel.inserts.compactMap { inserts[$0.id] })
        for (id, error) in result.rejected {
            if let (documentID, instance) = inserts.first(where: { $0.value.id == id }) {
                let slot = ChannelSlot.insert(documentID)
                failures[slot] = instance.identity
                status[slot] = .failed(error.message)
                release(instance); inserts[documentID] = nil
            } else if let instance = instrument, instance.id == id {
                failures[.instrument] = instance.identity
                retireInstrument()
                status[.instrument] = .failed(error.message)
            }
        }
        if let failure = result.failure { graphFailure = failure.message; graphReady = false; suspendPlayback() }
        connectedInserts = desiredInserts.filter { $0.instanceID != nil }
    }
    private func beginFade() {
        guard fadeTask == nil else { return }
        let token = graph.fade(silent: true)
        fadeGeneration &+= 1
        let generation = fadeGeneration
        let deadline = DispatchTime.now().uptimeNanoseconds + 80_000_000
        let probe = graph.fadeCompletionProbe(token)
        let wait = Task.detached {
            while !Task.isCancelled {
                if probe() || DispatchTime.now().uptimeNanoseconds >= deadline { return true }
                do { try await Task.sleep(nanoseconds: 5_000_000) }
                catch { return false }
            }
            return false
        }
        fadeTask = Task { @MainActor [weak self] in
            let completed = await withTaskCancellationHandler(operation: { await wait.value }, onCancel: { wait.cancel() })
            // One Main delivery. Cancellation/generation reject obsolete work
            // before touching a stopped, rebuilt or replaced graph.
            guard completed, !Task.isCancelled, let self, generation == self.fadeGeneration else { return }
            self.fadeTask = nil
            self.rewiring = true
            if self.retireAcknowledged { self.finishRetiredInstrument() }
            else { self.reconcile() }
            self.rewiring = false
            self.graph.fade(silent: false)
        }
    }
    private func cancelFade() {
        guard fadeTask != nil else { return }
        // Latest channel/configuration intent is consumed at the pending
        // silent boundary. An active acknowledged retire must still fade.
        if retireAcknowledged && isRunning && !performancePaused { return }
        fadeGeneration &+= 1
        fadeTask?.cancel(); fadeTask = nil
        graph.fade(silent: false)
    }
    private func rebuild(retainedInstrument: PluginInstance? = nil) {
        guard var next = pendingMixerConfiguration ?? reconfiguration else { return }
        pendingMixerConfiguration = nil
        reconfiguration = nil
        loading.removeAll() // completions prepared for the old format are obsolete
        graph.stop(); isRunning = false
        connectedInserts.removeAll()
        let retainedInserts = inserts
        for instance in retainedInserts.values { graph.remove(instance) }
        do {
            do { try graph.configure(next) }
            catch {
                guard recoveringConfigurationChange, next.deviceID != nil else { throw error }
                let unavailable = next.deviceID
                next.deviceID = nil
                try graph.configure(next)
                unavailableDeviceID = unavailable
                configurationNotice = "Selected audio device unavailable; using System Output"
            }
            configuration = next; graphReady = true
            for insert in channel.inserts {
                guard let instance = retainedInserts[insert.id] else { continue }
                do { try graph.attach(instance, instrument: false) }
                catch { release(instance); inserts[insert.id] = nil; failures[.insert(insert.id)] = instance.identity; status[.insert(insert.id)] = .failed("Graph format: \(error)") }
            }
            if let old = retainedInstrument {
                if old.identity == channel.instrument?.identity {
                    do { try graph.attach(old, instrument: true); instrument = old }
                    catch {
                        release(old); instrument = nil; failures[.instrument] = old.identity
                        status[.instrument] = .failed("Instrument graph format: \(error)")
                    }
                } else { release(old) }
            }
            graph.setLevel(decibels: channel.levelDecibels)
            graph.setMuted(channel.muted)
            graph.setPan(channel.pan)
            if mixerOwner == nil {
                (graph as? any MixerGraphBoundary)?.setMasterLevel(decibels: masterLevelDecibels)
            }
            connect()
            if resumeAfterReconfigure && !startAfterRetire {
                do { try graph.start(); isRunning = true; graphFailure = nil }
                catch { graphFailure = "Audio restart failed"; performancePaused = true }
            }
            if let instrument { attachInstrument(instrument) }
        } catch {
            graphReady = false
            graphFailure = "Audio configuration failed: \(errorMessage(error))"
            if let old = retainedInstrument { release(old); instrument = nil }
            for (id, instance) in inserts {
                release(instance); inserts[id] = nil
                status[.insert(id)] = .failed("Audio configuration: \(error)")
            }
            status[.instrument] = .failed("Audio configuration: \(error)")
        }
        resumeAfterReconfigure = false
        recoveringConfigurationChange = false
        if mixerReconfiguring {
            for child in channelHosts.values where mixerChannels.contains(where: { $0.id == child.channel.id }) {
                child.completeMixerRebuild(configuration)
            }
            mixerReconfiguring = false
            let restore = pendingMixerStateRestore; pendingMixerStateRestore = false
            do { try applyMixer(mixerChannels, masterLevelDecibels: masterLevelDecibels, restoringPluginStates: restore) }
            catch { graphFailure = "Mixer rebuild failed" }
        }
        reconcile()
        synchronizeMeter()
    }
    private func errorMessage(_ error: Error) -> String {
        (error as? PluginLoadError)?.message ?? "Audio graph operation failed"
    }
}

/// Immutable Q handoff. The owner reference is a lifetime lease only; no
/// graph/AU/editor object is read from Q. No render callback is implemented.
private final class RetainedSchedule: AUScheduleBoundary, PlannedNoteBoundary, SampleNoteBoundary, @unchecked Sendable {
    private let owner: AudioHost
    private let schedule: any AUScheduleBoundary
    private let availability: ScheduleAvailability
    private let engineRunning: @Sendable () -> Bool
    init(owner: AudioHost, schedule: any AUScheduleBoundary, availability: ScheduleAvailability,
         engineRunning: @escaping @Sendable () -> Bool) {
        self.owner = owner; self.schedule = schedule; self.availability = availability; self.engineRunning = engineRunning
    }
    var planningLead: Double { (schedule as? any PlannedNoteBoundary)?.planningLead ?? 0 }
    func permitsNoteOn(bytes: [UInt8], now: Double) -> Bool {
        (schedule as? any PlannedNoteBoundary)?.permitsNoteOn(bytes: bytes, now: now) ?? true
    }
    func sendPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult {
        guard availability.isPlanningAllowed, availability.isRunning, engineRunning() else { return .unbound }
        return (schedule as? any PlannedNoteBoundary)?.sendPlanned(bytes: bytes, deadline: deadline, now: now) ?? .unbound
    }
    func cancelPlanned(bytes: [UInt8], deadline: Double, now: Double) -> PortSendResult {
        // A stopped engine still owns the AU's queued events. Cleanup must
        // reach that retained instance before a later restart or retirement.
        return (schedule as? any PlannedNoteBoundary)?.cancelPlanned(bytes: bytes, deadline: deadline, now: now) ?? .unbound
    }
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult {
        guard availability.isRunning, engineRunning() else { return .unbound }
        return schedule.scheduleMIDI(bytes: bytes)
    }
    /// The arpeggiator's render-clocked path must survive this production
    /// lease; without forwarding, Q sees no sample boundary and stays silent.
    var sampleNotesAvailable: Bool { (schedule as? any SampleNoteBoundary)?.sampleNotesAvailable == true }
    func enqueueSampleNote(bytes: [UInt8], deadline: Double, immediate: Bool) -> PortSendResult {
        guard availability.isPlanningAllowed, availability.isRunning, engineRunning() else { return .unbound }
        return (schedule as? any SampleNoteBoundary)?.enqueueSampleNote(bytes: bytes, deadline: deadline, immediate: immediate) ?? .unbound
    }
    func invalidateSampleNotes() {
        // Like cancelPlanned: cleanup reaches the retained instance even
        // while the engine is stopped.
        (schedule as? any SampleNoteBoundary)?.invalidateSampleNotes()
    }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult {
        guard availability.isRunning, engineRunning() else { return .unbound }
        return schedule.scheduleParameter(target, normalizedValue: normalizedValue)
    }
}

/// Main publishes availability; Q reads only this scalar, never the engine/AU.
final class ScheduleAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var planningAllowed = true
    var isPlanningAllowed: Bool { lock.lock(); defer { lock.unlock() }; return planningAllowed }
    func blockPlanning() { lock.lock(); planningAllowed = false; lock.unlock() }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func set(_ value: Bool) { lock.lock(); running = value; lock.unlock() }
}
