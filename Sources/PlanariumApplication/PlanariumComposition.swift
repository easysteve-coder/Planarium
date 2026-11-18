import Combine
import Foundation
import AppKit
import CoreFoundation
import PlanariumDomain
import PlanariumRuntime
import PlanariumInput
import PlanariumAudio
import PlanariumMIDI
import SickPLSMacTransport

/// The sole production construction path, also used by the integration tests.
/// Injected boundaries are source bytes, MIDI destination, AU source and clock.
@MainActor public final class PlanariumComposition {
    public let runtime: PerformanceRuntime
    public let input: InputOwner
    public let audio: AudioHost
    public let midi: MIDIPortOwner
    public let midiClock: MIDIClockDriver
    public let clockReceiver: MIDIClockReceiver
    public let footswitch: PanicFootswitchModel
    public let document: SpatialInstrumentRuntimeModel
    public let display: PerformanceDisplayModel
    public let profileRecording: ProfileRecordingModel
    public let activity: PerformanceActivity
    private var activitySubscriptions: Set<AnyCancellable> = []
    private var suspended = false
    private var resumeAudioAfterSleep = false
    private var sleepGeneration: UInt64 = 0
    private var terminating = false
    private var inputClosed = false
    private var outputsClosed = false
    public private(set) var terminationReport: TerminationReport?
    private var terminationDeadline: RuntimeCancellation?
    private var terminationReleased = false
    private var terminationCompletions: [@MainActor () -> Void] = []
    public init(scanner: any SerialPortOpener = DarwinSerialPortOpener(),
                midi: any MIDIConnectionBoundary, components: any PluginComponentSource,
                clock: any RuntimeClock = MonotonicRuntimeClock(),
                configuration: AudioHostConfiguration = .init(), readTimeoutMilliseconds: Int32 = 200,
                graph: (any AudioGraphBoundary)? = nil, windows: (any PluginWindowFactory)? = nil,
                clockSinkFactory: @escaping MIDIClockSinkFactory = { _ in nil },
                clockSourceFactory: @escaping MIDIClockSourceFactory = { _, _, _ in nil },
                clockSourceChanges: MIDIClockSourceChanges? = nil,
                initialWorkspace: SpatialInstrumentWorkspace? = nil,
                activityBoundary: (any PerformanceActivityBoundary)? = nil,
                footswitchDefaults: UserDefaults? = nil,
                footswitchSourceFactory: @escaping MIDIClockSourceFactory = { _, _, _ in nil }) throws {
        activity = PerformanceActivity(boundary: activityBoundary ?? SystemPerformanceActivity())
        let input = InputOwner(session: RXSession(opener: scanner, readTimeoutMilliseconds: readTimeoutMilliseconds, clock: clock))
        let recording = ProfileRecordingModel(clock: clock)
        profileRecording = recording
        let roomCapture = RoomCaptureWorker()
        let hostClock = HostMusicalClock()
        let core = PerformanceRuntimeFactory.make(clock: clock, hostClock: hostClock, source: RecordingProfileSource(source: input, recorder: recording, roomCapture: roomCapture))
        self.input = input; runtime = core.runtime
        audio = try AudioHost(components: components, graph: graph ?? AVAudioGraph(),
                              runtime: PerformanceAudioPort(runtime: core.runtime), windows: windows ?? AppKitPluginWindows(),
                              configuration: configuration, hostMusicalClock: hostClock)
        self.midi = MIDIPortOwner(runtime: core.runtime, transport: midi)
        midiClock = MIDIClockDriver(clock: clock, factory: clockSinkFactory, hostClock: audio.hostMusicalClock)
        clockReceiver = MIDIClockReceiver(clock: clock, factory: clockSourceFactory, hostClock: audio.hostMusicalClock, sourceChanges: clockSourceChanges)
        document = try SpatialInstrumentRuntimeModel(runtime: core.runtime, audio: audio, midi: self.midi, initialWorkspace: initialWorkspace ?? SpatialInstrumentWorkspace(grid: MetricSquareGrid.CellSize.fiveCentimeter.grid), midiClock: midiClock, tempoClock: clock, clockReceiver: clockReceiver, roomCapture: roomCapture)
        let performance = core.runtime, driver = midiClock, model = document
        footswitch = PanicFootswitchModel(defaults: footswitchDefaults ?? UserDefaults(suiteName: "Planarium.unconfiguredFootswitch.\(UUID())")!,
            factory: footswitchSourceFactory, sourceChanges: clockSourceChanges,
            panic: { performance.panic(); driver.stop() }, notification: { [weak model] in model?.noteFootswitchPanic() })
        display = PerformanceDisplayModel(mailbox: core.mailbox, runtime: core.runtime)
        audio.$isRunning.combineLatest(input.$portOwner).sink { [weak activity] running, owner in
            activity?.update(audio: running, scanner: owner == .monitor || owner == .simulation)
        }.store(in: &activitySubscriptions)
    }
    public func panic() { document.panicAll() }
    public func stop() { document.stopSpatialMode() }
    public func sleep() {
        guard !terminating, !suspended else { return }
        resumeAudioAfterSleep = audio.playbackRequested
        document.audition(nil)
        document.stopClockTransport()
        document.suspendClockInput()
        audio.suspendMeter()
        suspended = true; sleepGeneration &+= 1
        let generation = sleepGeneration
        runtime.sleep()
        runtime.acknowledge { [weak self] in
            Task { @MainActor in
                guard let self, self.suspended, self.sleepGeneration == generation else { return }
                self.audio.suspendPlayback()
            }
        }
    }
    public func wake() {
        guard !terminating, suspended else { return }
        suspended = false; sleepGeneration &+= 1; runtime.wake()
        document.resumeClockInput()
        if resumeAudioAfterSleep && audio.audioEnabled {
            do { try audio.start() } catch { /* Host exposes the failed start. */ }
        }
        resumeAudioAfterSleep = false
    }
    public func configureAudio(_ configuration: AudioHostConfiguration) { audio.configure(configuration) }
    public func terminate(_ completion: @escaping @MainActor () -> Void) {
        terminationCompletions.append(completion)
        guard !terminating else { finishTermination(); return }
        audio.suspendMeter()
        terminating = true
        activity.terminate()
        footswitch.shutdown()
        profileRecording.cancel()
        document.cancelRoomContourCapture()
        document.audition(nil)
        display.stop()
        document.suspendClockInput()
        document.stopClockTransport()
        // Real time, independently of the measurement clock and the blocked Q.
        // Reserve 200 ms for Main delivery within the Owner's 2 s budget.
        let clock = MonotonicRuntimeClock()
        terminationDeadline = clock.schedule(at: clock.now + 1.8, on: .main) { [weak self] in
            MainActor.assumeIsolated { self?.finishTermination(deadlineExpired: true) }
        }
        runtime.panic() // best effort on every bound port, serialized with sends
        input.shutdown { [self] in inputClosed = true; finishTermination() }
        runtime.terminate { [self] in
            Task { @MainActor in
                audio.shutdown { [self] in
                    midi.shutdown { [self] in
                        midiClock.shutdown { [self] in
                            clockReceiver.shutdown { [self] in
                                Task { @MainActor in outputsClosed = true; finishTermination() }
                            }
                        }
                    }
                }
            }
        }
    }
    private func finishTermination(deadlineExpired: Bool = false) {
        guard terminationReleased || deadlineExpired || (inputClosed && outputsClosed) else { return }
        if !terminationReleased {
            terminationReleased = true
            terminationDeadline?.cancel(); terminationDeadline = nil
            let report = TerminationReport(deadlineExpired: deadlineExpired,
                                           unconfirmedNoteOffs: runtime.unconfirmedNoteOffs)
            terminationReport = report
            // Numeric local protocol, also available as a typed diagnostic.
            report.protocolLines.forEach { print($0) }
        }
        let callbacks = terminationCompletions; terminationCompletions.removeAll(); callbacks.forEach { $0() }
    }

}

public struct TerminationReport: Equatable, Sendable {
    public let deadlineExpired: Bool
    public let unconfirmedNoteOffs: [UnconfirmedNoteOff]
    public var protocolLines: [String] {
        ["Planarium termination: deadlineExpired=\(deadlineExpired), panic=queued-for-all-ports, unconfirmed=\(unconfirmedNoteOffs.count)"] +
        unconfirmedNoteOffs.map {
            "Unconfirmed Note-Off: port=\($0.portID.uuidString), destination=\($0.destination), channel=\($0.channel), note=\($0.note)"
        }
    }
}

/// One event-driven Main pump, coalesced by one pending run-loop block. No polling or whole
/// frame comparison. Hiding detaches the mailbox notification; Q keeps working.
@MainActor public final class PerformanceDisplayModel: ObservableObject {
    @Published public private(set) var frame: DisplayFrame?
    @Published public private(set) var inputBacklogStatus: InputBacklogStatus = .ready
    public private(set) var deliveryCount = 0
    public private(set) var pumpPassCount = 0
    private let mailbox: DisplayFrameMailbox
    private let runtime: PerformanceRuntime?
    private let signal = MainPresentationSignal()
    private var requested = false
    private var visible = true
    private var monitorVisible = false
    private var mixerMonitorVisible = false
    private var observationActive = false
    private var observedMonitorVisible = false
    private var generation: UInt64?
    public init(mailbox: DisplayFrameMailbox, runtime: PerformanceRuntime? = nil) {
        self.mailbox = mailbox; self.runtime = runtime
        signal.bind { [weak self] in
            guard let self, (self.requested && self.visible) || (self.visible && self.mixerMonitorVisible) || self.monitorVisible else { return }
            self.pumpPassCount += 1
            self.read()
        }
    }
    public func start() {
        guard !requested else { return }
        requested = true; updateObservation()
    }
    public func stop() { requested = false; updateObservation() }
    public func setOutputMonitorVisible(_ visible: Bool) {
        guard monitorVisible != visible else { return }
        monitorVisible = visible
        updateObservation()
    }
    public func setMixerMonitorVisible(_ visible: Bool) {
        guard mixerMonitorVisible != visible else { return }
        mixerMonitorVisible = visible
        updateObservation()
    }
    public func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible; updateObservation()
    }
    private func updateObservation() {
        let monitorActive = monitorVisible
        let monitorChanged = observedMonitorVisible != monitorActive
        observedMonitorVisible = monitorActive
        let active = (requested && visible) || (visible && mixerMonitorVisible) || monitorActive
        let becameActive = active && !observationActive
        if active != observationActive {
            observationActive = active
            signal.setActive(active)
            if active {
                let signal = signal
                mailbox.observeWrites { signal.request() }
            } else { mailbox.observeWrites(nil) }
        }
        // Observe first. Enabling the monitor publishes one current Q frame;
        // do not precede that frame with an extra stale catch-up presentation.
        if monitorChanged { runtime?.setOutputMonitorVisible(monitorActive) }
        if becameActive && !(monitorChanged && monitorActive && runtime != nil), mailbox.snapshot().frame != nil {
            signal.request()
        }
    }
    public func read() {
        guard visible || monitorVisible else { return }
        if let status = runtime?.inputBacklogStatus, status != inputBacklogStatus { inputBacklogStatus = status }
        let value = mailbox.snapshot()
        guard value.generation != generation, let frame = value.frame else { return }
        generation = value.generation; deliveryCount += 1
        self.frame = frame
    }
    deinit { mailbox.observeWrites(nil); signal.setActive(false) }
}

/// Lock protects pending/active/action. A single pending run-loop block is
/// shared by default and tracking modes; it is consumed exactly once in either
/// mode, also before AppKit installs common-mode membership (offline hosting).
private final class MainPresentationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var active = false
    private var action: (@MainActor @Sendable () -> Void)?
    func bind(_ action: @escaping @MainActor @Sendable () -> Void) {
        lock.lock(); self.action = action; lock.unlock()
    }
    func setActive(_ active: Bool) { lock.lock(); self.active = active; lock.unlock() }
    func request() {
        lock.lock()
        guard active, !pending else { lock.unlock(); return }
        pending = true; lock.unlock()
        RunLoop.main.perform(inModes: [.common, .eventTracking]) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending = false
            let action = self.active ? self.action : nil; self.lock.unlock()
            MainActor.assumeIsolated { action?() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// Main alone installs/removes the timer. The lifetime holder can invalidate
/// its exclusively owned Foundation timer on deinit without accessing a UI
/// model from a nonisolated destructor.
public final class MainRunLoopTimer: @unchecked Sendable {
    private var value: Timer?
    public init() {}
    @MainActor public var isActive: Bool { value != nil }
    @MainActor public func install(_ timer: Timer) { value?.invalidate(); value = timer }
    @MainActor public func remove() { value?.invalidate(); value = nil }
    deinit { value?.invalidate() }
}
