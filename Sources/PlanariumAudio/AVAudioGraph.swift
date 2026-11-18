import AudioToolbox
import AVFoundation
import Foundation
import PlanariumMusicCore
import PlanariumObjCCatch
@_spi(AudioHost) import PlanariumSoundCore
import PlanariumHostClockDSP

/// Sole native-engine adapter, owned by AudioHost. The persistent converter
/// mixer preserves the instrument's native channel count (DLS is mono), as
/// in AVAudioEngineOutputHost. Connections change only at differing edges.
@MainActor public final class AVAudioGraph: MixerGraphBoundary {
    private var engine: AVAudioEngine
    private let makeEngine: @MainActor () -> AVAudioEngine
    private let selectDevice: @MainActor (AVAudioEngine, UInt32) throws -> Void
    private let converter = AVAudioMixerNode()
    private let channelMixer = AVAudioMixerNode()
    private let channelGain = AVAudioUnitEQ(numberOfBands: 0)
    private weak var parent: AVAudioGraph?
    private final class WeakGraph { weak var value: AVAudioGraph?; init(_ value: AVAudioGraph) { self.value = value } }
    private var branches: [WeakGraph] = []
    private var masterMeterInstalled = false
    private let gain = AVAudioUnitEQ(numberOfBands: 0)
    private var fadeNode: AVAudioUnit?
    private var fadeUnit: PlanariumFade? { fadeNode?.auAudioUnit as? PlanariumFade }
    private var transitionSilent = false
    private var muted = false
    private var nodes: [UUID: AVAudioUnit] = [:]
    private var hostClock = HostMusicalClock()
    private var hostBindings: [UUID: PlanariumHostClockBinding] = [:]
    public func setHostMusicalClock(_ clock: HostMusicalClock) {
        precondition(nodes.isEmpty, "Install host clock before attaching plug-ins")
        hostClock = clock
    }
    private var instrumentIDs: Set<UUID> = []
    private var formats: [UUID: AVAudioFormat] = [:]
    private var format: AVAudioFormat?
    private var configuration: AudioHostConfiguration?
    private var meterInstalled = false
    private var running = false
    private var engineAvailability = ScheduleAvailability()
    private var explicitDeviceAttempted = false
    private var changeHandler: (@MainActor @Sendable () -> Void)?
    private let observation = EngineConfigurationObservation()
    private var observationGeneration: UInt64 = 0
    private var changePending = false
    private struct Edge {
        let source: AVAudioNode
        let destination: AVAudioNode
        let format: AVAudioFormat
        func matches(_ other: Edge) -> Bool {
            source === other.source && destination === other.destination && format == other.format
        }
    }
    private var edges: [ObjectIdentifier: Edge] = [:]
    public convenience init() {
        self.init(makeEngine: { AVAudioEngine() }, selectDevice: { engine, requested in
            guard let output = engine.outputNode.audioUnit else { throw PluginLoadError("No audio output device") }
            var device = requested
            let result = AudioUnitSetProperty(output, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                               &device, UInt32(MemoryLayout<UInt32>.size))
            guard result == noErr else { throw PluginLoadError("Audio device selection failed (\(result))") }
        })
    }
    /// Native construction/device application seams; tests never select a
    /// physical output or start a device engine.
    internal init(makeEngine: @escaping @MainActor () -> AVAudioEngine,
                  selectDevice: @escaping @MainActor (AVAudioEngine, UInt32) throws -> Void) {
        self.makeEngine = makeEngine; self.selectDevice = selectDevice; engine = makeEngine()
    }
    private init(parent: AVAudioGraph) {
        self.parent = parent; engine = parent.engine
        hostClock = parent.hostClock
        engineAvailability = parent.engineAvailability
        makeEngine = parent.makeEngine; selectDevice = parent.selectDevice
    }
    public func makeChannelGraph() -> any AudioGraphBoundary {
        let root = parent ?? self
        let branch = AVAudioGraph(parent: root)
        root.branches.append(WeakGraph(branch))
        return branch
    }
    public func setMasterLevel(decibels: Double) {
        guard decibels.isFinite else { return }
        let root = parent ?? self
        root.gain.globalGain = Float(min(max(decibels, -96), InstrumentChannel.maximumLevelDecibels))
        root.engine.mainMixerNode.outputVolume = decibels < -96 ? 0 : 1
    }
    public func observeConfigurationChange(_ handler: (@MainActor @Sendable () -> Void)?) {
        guard parent == nil else { return }
        removeConfigurationObserver()
        changeHandler = handler
        if handler != nil { installConfigurationObserver() }
    }
    private func removeConfigurationObserver() {
        observationGeneration &+= 1
        changePending = false
        observation.remove()
    }
    private func installConfigurationObserver() {
        guard changeHandler != nil else { return }
        let generation = observationGeneration
        let availability = engineAvailability
        observation.token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { [weak self] _ in
            availability.set(false)
            Task { @MainActor [weak self] in
                guard let self, generation == self.observationGeneration, !self.changePending else { return }
                self.changePending = true
                // A notification may be posted inside an engine operation.
                // Leave that stack before retiring/rebuilding the graph.
                Task { @MainActor [weak self] in
                    guard let self, generation == self.observationGeneration else { return }
                    self.changePending = false
                    self.running = false
                    self.changeHandler?()
                }
            }
        }
    }
    private func catching(_ body: () -> Void) throws {
        do { try PlanariumObjCCatch.perform(body) }
        catch { throw PluginLoadError((error as NSError).localizedDescription) }
    }
    public func configure(_ configuration: AudioHostConfiguration) throws {
        if let parent { engine = parent.engine }
        guard configuration.sampleRate.isFinite, configuration.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: configuration.sampleRate, channels: 2),
              !(configuration.offline && configuration.deviceID != nil) else { throw PluginLoadError("Invalid audio configuration") }
        removeConfigurationObserver()
        stop()
        if let parent { engineAvailability = parent.engineAvailability }
        else { engineAvailability.set(false); engineAvailability = ScheduleAvailability() }
        for edge in edges.values { engine.disconnectNodeOutput(edge.source) }
        edges.removeAll()
        for node in nodes.values { engine.detach(node) }
        hostBindings.removeAll()
        nodes.removeAll(); formats.removeAll(); instrumentIDs.removeAll()
        if parent == nil, gain.engine != nil { engine.detach(gain) }
        if let fadeNode, fadeNode.engine != nil { engine.detach(fadeNode) }
        fadeNode = nil
        if converter.engine != nil { engine.detach(converter) }
        if channelMixer.engine != nil { engine.detach(channelMixer) }
        if channelGain.engine != nil { engine.detach(channelGain) }
        self.format = nil; self.configuration = nil
        if parent == nil, engine.isInManualRenderingMode { engine.disableManualRenderingMode() }
        if parent == nil, configuration.deviceID == nil, explicitDeviceAttempted {
            // A fresh engine has the same system-following output policy as
            // program startup. All old taps, edges and nodes are detached above.
            engine = makeEngine()
            explicitDeviceAttempted = false
        }
        if parent != nil { /* The root owns output format and device selection. */ }
        else if configuration.offline {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        } else if let requested = configuration.deviceID {
            explicitDeviceAttempted = true
            try selectDevice(engine, requested)
        }
        do {
            try catching { engine.attach(converter) }
            try catching { engine.attach(channelMixer) }
            try catching { engine.attach(channelGain) }
            if parent == nil { try catching { engine.attach(gain) }; setMasterLevel(decibels: 0) }
            let fadeNode = try PlanariumFade.makeNode()
            self.fadeNode = fadeNode
            guard let fade = fadeNode.auAudioUnit as? PlanariumFade else { throw PluginLoadError("Invalid fade unit") }
            try fade.inputBusses[0].setFormat(format)
            try fade.outputBusses[0].setFormat(format)
            fade.reset(sampleRate: format.sampleRate, silent: muted)
            try catching { engine.attach(fadeNode) }
        } catch {
            for node in [converter as AVAudioNode, channelMixer, channelGain, parent == nil ? gain : nil, self.fadeNode].compactMap({ $0 }) where node.engine === engine {
                engine.detach(node)
            }
            self.fadeNode = nil; self.format = nil
            throw error
        }
        self.format = format; self.configuration = configuration
        installConfigurationObserver()
    }
    public func attach(_ instance: PluginInstance, instrument: Bool) throws {
        guard let node = instance.unit?.audioNode, let format else { throw PluginLoadError("Missing Audio Unit or format") }
        let au = node.auAudioUnit
        guard au.outputBusses.count > 0 else { throw PluginLoadError("Audio Unit has no output bus") }
        let offered: AVAudioFormat
        if instrument {
            guard let native = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                            channels: au.outputBusses[0].format.channelCount) else { throw PluginLoadError("Invalid instrument format") }
            offered = native
        } else {
            guard au.inputBusses.count > 0 else { throw PluginLoadError("Insert has no input bus") }
            offered = format
        }
        if au.renderResourcesAllocated { au.deallocateRenderResources() }
        let binding = try instance.bindHostClock(hostClock, sampleRate: offered.sampleRate, offline: configuration?.offline == true)
        if !instrument { try au.inputBusses[0].setFormat(offered) }
        try au.outputBusses[0].setFormat(offered)
        do { try catching { engine.attach(node) } }
        catch {
            if node.engine === engine { engine.detach(node) }
            throw error
        }
        nodes[instance.id] = node; formats[instance.id] = offered
        hostBindings[instance.id] = binding
        if instrument { instrumentIDs.insert(instance.id) }
    }
    public func remove(_ instance: PluginInstance) {
        guard let node = nodes.removeValue(forKey: instance.id) else { return }
        for (key, edge) in edges where edge.source === node || edge.destination === node {
            if edge.source.engine === engine { engine.disconnectNodeOutput(edge.source) }; edges[key] = nil
        }
        if node.engine === engine { engine.detach(node) }; formats[instance.id] = nil; instrumentIDs.remove(instance.id)
        hostBindings[instance.id] = nil
    }
    @discardableResult public func connect(instrument: PluginInstance?, inserts: [PluginInstance]) -> AudioGraphConnectionResult {
        var result = AudioGraphConnectionResult()
        guard let format, let fadeNode else { return result }
        var accepted = inserts
        var acceptedInstrument = instrument
        // Each failed local edge removes one candidate. Rebuild the remaining
        // chain in the same call, never publish a half-wired edges dictionary.
        while true {
            var ordered: [Edge] = []
            if let instrument = acceptedInstrument, let node = nodes[instrument.id], let native = formats[instrument.id] {
                ordered.append(Edge(source: node, destination: converter, format: native))
            }
            var source: AVAudioNode = converter
            for instance in accepted {
                guard let node = nodes[instance.id] else { continue }
                ordered.append(Edge(source: source, destination: node, format: format))
                source = node
            }
            ordered.append(Edge(source: source, destination: channelMixer, format: format))
            ordered.append(Edge(source: channelMixer, destination: channelGain, format: format))
            ordered.append(Edge(source: channelGain, destination: fadeNode, format: format))
            ordered.append(Edge(source: fadeNode, destination: engine.mainMixerNode, format: format))
            if parent == nil {
                ordered.append(Edge(source: engine.mainMixerNode, destination: gain, format: format))
                ordered.append(Edge(source: gain, destination: engine.outputNode, format: format))
            }
            let desired = Dictionary(uniqueKeysWithValues: ordered.map { (ObjectIdentifier($0.source), $0) })
            for (key, old) in edges where desired[key].map({ old.matches($0) }) != true {
                if old.source.engine === engine { engine.disconnectNodeOutput(old.source) }
                edges[key] = nil
            }
            var rejectedEdge: Edge?
            var rejection: PluginLoadError?
            for edge in ordered {
                let key = ObjectIdentifier(edge.source)
                guard edges[key].map({ $0.matches(edge) }) != true else { continue }
                do {
                    try catching { engine.connect(edge.source, to: edge.destination, format: edge.format) }
                    edges[key] = edge
                } catch {
                    rejectedEdge = edge
                    rejection = error as? PluginLoadError ?? PluginLoadError("Graph connection failed")
                    break
                }
            }
            // A running engine silently drops a new strip's edge into the
            // main mixer (strip added during playback, Owner 20.10.2026);
            // edges inside a strip are applied with the next render. Verify
            // the master edge, rewire it with the engine stopped, and reject
            // it like a native failure if it still does not exist.
            if rejectedEdge == nil, let master = ordered.first(where: { $0.destination === engine.mainMixerNode }),
               master.source.engine === engine, !isWired(master) {
                let resume = engine.isRunning
                if resume { engine.stop() }
                try? catching { engine.connect(master.source, to: master.destination, format: master.format) }
                if resume {
                    planarium_host_clock_reset_render_epoch(hostClock.storage)
                    do { try catching { engine.prepare() }; try engine.start() }
                    catch { result.failure = error as? PluginLoadError ?? PluginLoadError("Audio restart failed"); return result }
                }
                if !isWired(master) { rejectedEdge = master; rejection = PluginLoadError("Master connection failed") }
            }
            guard let rejectedEdge, let rejection else { return result }
            // Includes the failing source: connect may have changed it before
            // raising. No stale edge survives the failed transaction.
            for edge in ordered where edge.source.engine === engine { engine.disconnectNodeOutput(edge.source) }
            edges.removeAll()
            if let failed = accepted.first(where: { nodes[$0.id] === rejectedEdge.destination }) ??
                accepted.first(where: { nodes[$0.id] === rejectedEdge.source }) {
                result.rejected[failed.id] = rejection
                accepted.removeAll { $0.id == failed.id }
            } else if let failed = acceptedInstrument, nodes[failed.id] === rejectedEdge.source {
                result.rejected[failed.id] = rejection
                acceptedInstrument = nil
            } else {
                result.failure = rejection
                return result
            }
        }
    }
    private func isWired(_ edge: Edge) -> Bool {
        engine.outputConnectionPoints(for: edge.source, outputBus: 0).contains { $0.node === edge.destination }
    }
    public func setPan(_ pan: Double) { channelMixer.pan = Float(min(max(pan, -1), 1)) }
    public func setLevel(decibels: Double) {
        guard decibels.isFinite else { return }
        channelGain.globalGain = Float(min(max(decibels, -96), InstrumentChannel.maximumLevelDecibels))
        channelMixer.outputVolume = decibels < -96 ? 0 : 1
    }
    public func start() throws {
        if !engine.isRunning { planarium_host_clock_reset_render_epoch(hostClock.storage) }
        try catching { engine.prepare() }; try engine.start(); running = true
        engineAvailability.set(true)
    }
    public func stop() {
        removeMeter(); running = false; transitionSilent = false
        let root = parent ?? self
        if !root.running && !root.branches.contains(where: { $0.value?.running == true }) {
            root.removeMasterMeter(); engine.stop()
            engineAvailability.set(false)
        }
        fadeUnit?.reset(sampleRate: configuration?.sampleRate ?? 48_000, silent: muted)
    }
    public func close() {
        stop(); removeConfigurationObserver(); changeHandler = nil
        for edge in edges.values where edge.source.engine === engine { engine.disconnectNodeOutput(edge.source) }
        edges.removeAll()
        for node in nodes.values where node.engine === engine { engine.detach(node) }
        hostBindings.removeAll()
        nodes.removeAll(); formats.removeAll(); instrumentIDs.removeAll()
        for node in [converter as AVAudioNode, channelMixer, channelGain, fadeNode, parent == nil ? gain : nil].compactMap({ $0 }) where node.engine === engine { engine.detach(node) }
        fadeNode = nil; format = nil; configuration = nil
    }
    @discardableResult public func fade(silent: Bool) -> UInt32 {
        transitionSilent = silent
        return fadeUnit?.request(silent: silent || muted) ?? 0
    }
    public func fadeReached(_ token: UInt32) -> Bool { fadeUnit?.reached(token) ?? false }
    public func fadeCompletionProbe(_ token: UInt32) -> @Sendable () -> Bool {
        guard let fadeUnit else { return { false } }
        return fadeUnit.completionProbe(token)
    }
    public func scheduleAvailabilityProbe() -> @Sendable () -> Bool {
        { [engineAvailability] in engineAvailability.isRunning }
    }
    public func setMuted(_ muted: Bool) {
        self.muted = muted
        if running { _ = fadeUnit?.request(silent: muted || transitionSilent) }
        else { fadeUnit?.reset(sampleRate: configuration?.sampleRate ?? 48_000, silent: muted || transitionSilent) }
    }
    public func installMeter(_ holder: PeakHolder) throws {
        guard running, !meterInstalled else { return }
        guard let fadeNode else { return }
        try catching {
            fadeNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in holder.accumulate(buffer) }
        }
        meterInstalled = true
    }
    public func removeMeter() {
        guard meterInstalled else { return }
        fadeNode?.removeTap(onBus: 0)
        meterInstalled = false
    }
    public func installMasterMeter(_ holder: PeakHolder) throws {
        guard parent == nil else { return }
        let root = parent ?? self
        guard !root.masterMeterInstalled else { return }
        try catching { root.gain.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in holder.accumulate(buffer) } }
        root.masterMeterInstalled = true
    }
    public func removeMasterMeter() {
        guard parent == nil else { return }
        let root = parent ?? self
        guard root.masterMeterInstalled else { return }
        root.gain.removeTap(onBus: 0); root.masterMeterInstalled = false
    }
    /// Offline-only evidence, with no output-node start on a real device.
    public func renderOffline(frames: AVAudioFrameCount = 512) throws -> AVAudioPCMBuffer {
        guard configuration?.offline == true, frames <= engine.manualRenderingMaximumFrameCount,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames) else {
            throw PluginLoadError("Offline renderer unavailable")
        }
        switch try engine.renderOffline(frames, to: buffer) {
        case .success: return buffer
        case .insufficientDataFromInputNode: throw PluginLoadError("Offline input exhausted")
        case .cannotDoInCurrentContext: throw PluginLoadError("Offline render busy")
        case .error: throw PluginLoadError("Offline render failed")
        @unknown default: throw PluginLoadError("Unknown offline render result")
        }
    }
}

/// Lifetime cleanup also covers dropping a graph without explicit shutdown.
private final class EngineConfigurationObservation {
    var token: NSObjectProtocol?
    func remove() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
    deinit { remove() }
}
