import Combine
import AppKit
import Foundation
import CoreGraphics
import PlanariumDomain
import PlanariumRuntime
import PlanariumAudio
import PlanariumMIDI
import SickPLSCore
import SickPLSMonitorKit
import PlanariumPresets

/// Immutable Foundation token. NotificationCenter permits removal on any thread;
/// the wrapper owns that one removal even when the model is deallocated off Main.
private final class AuditionActivationObserver: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// Only capture controls subscribe to acquisition progress, never inspectors.
@MainActor public final class RoomContourCaptureState: ObservableObject {
    @Published public fileprivate(set) var progress: Double = 0
    @Published public fileprivate(set) var isCapturing = false
    @Published public fileprivate(set) var countdownSeconds: Int?
    @Published public fileprivate(set) var notice: String?
    /// Room capture is deliberately fixed: five seconds are 125 profiles at
    /// the scanner's nominal 25 Hz.  Legacy callers may still offer a length,
    /// but it must never alter the acquisition contract.
    @Published public fileprivate(set) var durationSeconds = RoomContourCaptureState.defaultDurationSeconds

    public static let durationChoicesSeconds = [5]
    public static let defaultDurationSeconds = 5
    /// Nominal profile rate of MMK 90 and full scan 361 at 500 kBd.
    public static let nominalProfileRateHertz = 25
    public var targetProfileCount: Int { durationSeconds * Self.nominalProfileRateHertz }
}

/// Fit controls/status subscribe to session evidence without republishing the
/// document owner or any inspector during acquisition.
@MainActor public final class RoomFitState: ObservableObject {
    public fileprivate(set) var fittingContour: SpatialRoomContour?
    @Published public fileprivate(set) var hasContour = false
    @Published public fileprivate(set) var marginCentimeters = 10
    @Published public fileprivate(set) var notice: String?
    @Published public fileprivate(set) var warnings = SpatialRoomFit.Warnings(outsideCells: [], narrowLayerNames: [])
}

/// External telemetry is observed only by the tempo/header and sync settings.
@MainActor public final class ClockDisplayState: ObservableObject {
    @Published public private(set) var value = MIDIClockDisplaySnapshot()
    public func observe(_ snapshot: MIDIClockDisplaySnapshot) {
        guard value != snapshot else { return }
        value = snapshot
    }
}

/// Rejections can recur during performance without invalidating the document.
@MainActor public final class InstrumentNoticeState: ObservableObject {
    @Published public private(set) var text: String?
    fileprivate func set(_ text: String?) {
        guard self.text != text else { return }
        self.text = text
    }
}

/// Only the open effect editor observes live hand values; document views stay quiet.
@MainActor public final class ArpeggiatorModulationDisplay: ObservableObject {
    @Published public private(set) var value = ArpeggiatorModulationState()
    public init() {}
    func update(_ next: ArpeggiatorModulationState) {
        if value != next { value = next }
    }
}

/// Sole document owner. Canvas is a Main-only authoring projection; only a
/// validated, compiled complete document is ever installed on Q.
@MainActor public final class SpatialInstrumentRuntimeModel: ObservableObject {
    @Published public private(set) var document: InstrumentDocument {
        didSet {
            if document.channels != oldValue.channels { presetChangeGeneration &+= 1 }
            onPresetRecoveryChange?()
        }
    }
    public let arpeggiatorModulationDisplay = ArpeggiatorModulationDisplay()
    public private(set) var presetChangeGeneration: UInt64 = 0
    public private(set) var presetPluginChangeGeneration: UInt64 = 0
    public private(set) var compiledInstrument: CompiledInstrument
    public let notices = InstrumentNoticeState()
    public private(set) var notice: String? {
        get { notices.text }
        set { notices.set(newValue) }
    }
    public var showInactiveSceneLayers: Bool {
        get { canvas.showsInactiveSceneLayers }
        set {
            fieldPlan.setShowsInactiveLayers(newValue)
            fieldLabels = fieldPlan.labels(selectedLayerID: canvas.workspace.selectedLayerID)
            canvas.setShowsInactiveSceneLayers(newValue)
        }
    }
    public private(set) var fieldLabels: [SpatialFieldPlan.Label] = []
    public private(set) var fieldPlan = SpatialFieldPlan(workspace: SpatialInstrumentWorkspace())
    public let canvas: CanvasSession
    private var surfaceEditorStorage: SurfaceEditorModel?
    /// The field's surface editor; created on first use and kept for the instrument's life.
    public var surfaceEditor: SurfaceEditorModel {
        if let surfaceEditorStorage { return surfaceEditorStorage }
        let made = SurfaceEditorModel(instrument: self)
        surfaceEditorStorage = made
        return made
    }
    /// Owner allow-list: tempo, mixer values only, scene click, preset load, capture
    /// and fit. Every authoring entry point uses this one permission guard.
    @discardableResult public func authorize(_ action: InstrumentAction) -> Bool {
        guard !canvas.isPerformanceLocked || action.allowedInPerformance else {
            notice = InstrumentAction.performanceLockReason
            return false
        }
        return true
    }
    private func receiveCanvasCommand(_ command: CanvasDocumentCommand) -> Bool {
        guard authorize(.edit) else { return false }
        do {
            var next = try CanvasDocumentProjection.applying(command.after, before: command.before, to: document)
            next.detection = command.after.detectionConfiguration
            let lost = CanvasDocumentProjection.outputLoss(command.after, in: document)
            if lost > 0 {
                pendingOutput = (next, canvas.selection, command.name, document.revision, command.selection != canvas.selection)
                outputChangeLossCount = lost
                return false
            }
            try commit(next, selectionBefore: canvas.selection, name: command.name,
                       coalescingID: command.coalescingKey == nil ? nil : command.id,
                       restoresCanvasSelection: command.selection != canvas.selection)
            return true
        } catch { notice = "Document edit rejected"; return false }
    }
    private func selectCanvasLayer(_ id: UUID) {
        // Active layer belongs to CanvasSession. Mirror it only at document
        // edit/save boundaries, without publishing to unrelated consumers.
        CanvasTimingProbe.measure("runtime.select.labels") { fieldLabels = fieldPlan.labels(selectedLayerID: id) }
    }
    func refreshCanvasPresentation() {
        // In the surface editor the surface-backed layers are drawn from their real forms.
        let drawnBySurfaceEditor: Set<UUID> = surfaceEditorStorage?.mode == .cells ? [] :
            Set(document.spatial.layers.filter(\.isSurfaceBacked).map(\.id))
        fieldPlan = SpatialFieldPlan(workspace: canvas.workspace, excludingLayers: drawnBySurfaceEditor)
        fieldPlan.setShowsInactiveLayers(showInactiveSceneLayers)
        fieldLabels = fieldPlan.labels(selectedLayerID: canvas.workspace.selectedLayerID)
        refreshRoomFitWarnings()
    }
    @Published public private(set) var outputChangeLossCount = 0
    private var pendingOutput: (InstrumentDocument, CanvasSelection, String, SpatialDocumentRevision, Bool)?
    public func cancelOutputChange() { pendingOutput = nil; outputChangeLossCount = 0 }
    public func confirmOutputChange() {
        guard authorize(.edit) else { return }
        guard let pending = pendingOutput else { return }
        cancelOutputChange()
        guard pending.3 == document.revision else { notice = "Output change expired; choose again"; return }
        do { try commit(pending.0, selectionBefore: pending.1, name: pending.2, restoresCanvasSelection: pending.4) }
        catch { notice = "Output change rejected" }
    }
    public var onPresetRecoveryChange: (() -> Void)?
    public var onPresetRecoveryLockChange: (() -> Void)?
    public var onPresetChannelSnapshot: ((InstrumentChannel) -> Void)?
    private var audioObservation: AnyCancellable?
    public let audio: AudioHost
    public let midi: MIDIPortOwner
    public let midiClock: MIDIClockDriver?
    private let tempoClock: any RuntimeClock
    private var tapHistory = TapTempo()
    @Published private var internalClockPlaying = false
    @Published public private(set) var clockDirection: ClockDirection = .off
    public let clockDisplay = ClockDisplayState()
    public var externalClock: MIDIClockDisplaySnapshot { clockDisplay.value }
    @Published public private(set) var clockSourceName = "No source selected"
    public let clockReceiver: MIDIClockReceiver?
    private var clockConfiguration: UInt64 = 0
    private var clockInputSuspended = false
    public private(set) var clockSourceID: Int32?
    public var isReceivingClock: Bool { clockDirection == .receive }
    public var displayedBeatsPerMinute: Double { isReceivingClock ? (externalClock.beatsPerMinute * 10).rounded() / 10 : document.beatsPerMinute }
    public var clockTransportPlaying: Bool { isReceivingClock ? externalClock.isPlaying : internalClockPlaying }
    private let runtime: PerformanceRuntime
    private var sceneGeneration: UInt64 = 0
    private var runtimeSceneProjection: (scene: UUID?, activity: [UUID: Bool])?
    private var minimumSceneRevision: SpatialDocumentRevision?
    private var lastCanvasEditID: UUID?
    private var continuousEditID: UUID?
    /// Kind of edit the open surface series was started with (nil until its first coalescable edit).
    fileprivate var surfaceSeriesKey: String?
    /// Undo and redo history exactly as it stood when the open surface series began, so a cancel
    /// returns the whole history rather than guessing which entries the gesture added or evicted.
    private var surfaceSeriesOrigin: (series: UUID, undo: [History], redo: [History])?
    private struct History {
        let document: InstrumentDocument
        let selection: CanvasSelection
        let name: String
        let restoresRoomContour: Bool
        var restoresCanvasSelection: Bool
    }
    private var undoStack: [History] = []
    private var redoStack: [History] = []
    private var commandSize: CGSize? {
        let size = canvas.viewportOwner.state.canvasSize
        return size.width > 0 && size.height > 0 ? size : nil
    }
    private var pendingLegacyViewport: ScanPlaneViewport? {
        get { canvas.viewportOwner.pendingLegacyViewport }
        set { canvas.viewportOwner.pendingLegacyViewport = newValue }
    }
    private var commandProfile: B0ScanProfile?
    public private(set) var roomContour: SpatialRoomContour?
    private var ownsDrawnContour = false
    private var measuredRoomContour: SpatialRoomContour?
    public private(set) var drawnContourRevision: UInt64 = 0
    public private(set) var drawnContour: SpatialDrawnContour?
    private var contourStrokeBase: SpatialDrawnContour?
    private var contourStrokeStart: MetricScanPoint?
    private var contourStrokePrevious: MetricScanPoint?
    private var contourStrokeStraight = false
    private var contourStrokeErasing = false

    public func beginContourStroke(at point: MetricScanPoint, straight: Bool, erasing: Bool) {
        guard authorize(.edit) else { return }
        ownsDrawnContour = true
        let identity = commandProfile.flatMap { try? FullScanProfileAdapter.geometry(from: $0) }
        let count = identity?.pointCount ?? roomContour?.geometry.pointCount ?? 361
        let geometry = SpatialRoomContour.Geometry(pointCount: count,
            angleResolutionDegrees: 180 / Double(count - 1), startAngleDegrees: -90,
            sourceIdentifier: roomContour?.geometry.sourceIdentifier ?? "scanner:default")
        if drawnContour == nil { drawnContour = .init(geometry: geometry) }
        drawnContour?.resample(to: geometry)
        contourStrokeBase = drawnContour
        contourStrokeStart = point; contourStrokePrevious = point
        contourStrokeStraight = straight; contourStrokeErasing = erasing
        updateContourStroke(to: point)
    }
    public func updateContourStroke(to point: MetricScanPoint) {
        guard authorize(.edit), let previous = contourStrokePrevious, let start = contourStrokeStart else { return }
        if contourStrokeStraight { drawnContour = contourStrokeBase }
        drawnContour?.stroke(from: contourStrokeStraight ? start : previous, to: point, erasing: contourStrokeErasing)
        contourStrokePrevious = point
        publishDrawnContour()
    }
    public func endContourStroke() {
        contourStrokeBase = nil; contourStrokeStart = nil; contourStrokePrevious = nil
    }
    public func clearDrawnContour() {
        guard authorize(.edit) else { return }
        endContourStroke(); drawnContour = nil; publishDrawnContour()
    }
    private func publishDrawnContour() {
        drawnContourRevision &+= 1
        roomContour = drawnContour?.effective(measured: measuredRoomContour) ?? measuredRoomContour
        roomFit.fittingContour = roomContour.map(SpatialRoomFit.fittingContour)
        runtime.roomContour(roomContour)
        if roomContour != nil && !roomContourConfiguration.isEnabled {
            var configuration = document.detection; configuration.roomContour.isEnabled = true
            applyDetectionConfiguration(configuration)
        }
        refreshRoomFitWarnings()
        objectWillChange.send()
    }
    public let roomFit = RoomFitState()
    public var roomFitMarginCentimeters: Int { roomFit.marginCentimeters }
    public var roomFitNotice: String? { roomFit.notice }
    public var roomFitWarnings: SpatialRoomFit.Warnings { roomFit.warnings }
    public var canFitToRoom: Bool { roomContour != nil && !canvas.isDragging }
    public func setRoomFitMargin(centimeters: Int) { roomFit.marginCentimeters = min(50, max(0, centimeters)) }
    public func fitToRoom() {
        guard authorize(.fitRoom) else { return }
        guard canFitToRoom, let contour = roomContour else { return }
        do {
            let result = try SpatialRoomFit.applying(to: document, contour: contour,
                marginCentimeters: Double(roomFitMarginCentimeters))
            if result.document != document {
                try commit(result.document, selectionBefore: canvas.selection, name: "Fit to room", restoresCanvasSelection: true)
                canvas.projectWorkspace(canvas.workspace, selection: .init())
            }
            if abs(result.minimumFactor - 1) < 1e-9 && abs(result.maximumFactor - 1) < 1e-9 {
                roomFit.notice = "Preset already fits the room"
            } else {
                var notice = "Preset fitted to room shape · \(Int((result.minimumFactor * 100).rounded()))–\(Int((result.maximumFactor * 100).rounded()))%"
                if result.mergedCells > 0 { notice += " · \(result.mergedCells) cells merged at 1 cm resolution" }
                roomFit.notice = notice
            }
        } catch SpatialRoomFit.Failure.dormantOverrideCollision {
            roomFit.notice = "Fit limited: a dormant cell override would become active"; return
        } catch SpatialRoomFit.Failure.surfaceLayersCannotBeFitted {
            roomFit.notice = "Surface layers are not changed by fitting; move or resize their shapes instead"; return
        } catch { roomFit.notice = "Fit to room rejected"; return }
        refreshRoomFitWarnings()
    }
    private func refreshRoomFitWarnings() {
        if roomFit.hasContour != (roomContour != nil) { roomFit.hasContour = roomContour != nil }
        let warnings = SpatialRoomFit.warnings(in: canvas.workspace, contour: roomContour,
            toleranceCentimeters: roomContourConfiguration.toleranceCentimeters)
        if warnings != roomFit.warnings { roomFit.warnings = warnings }
    }
    public let contourCapture = RoomContourCaptureState()
    public var roomContourCaptureProgress: Double { contourCapture.progress }
    public var isCapturingRoomContour: Bool { contourCapture.isCapturing }
    public private(set) var roomContourConfiguration = SpatialRoomContourConfiguration()
    public private(set) var roomContourMatches = true
    public private(set) var roomContourFilteredOrders: Set<Int> = []
    public private(set) var latestDetectionObjects: [DetectionObject] = []
    public private(set) var latestDetectionRepresentative: DetectionRepresentative?
    nonisolated let roomCapture: RoomCaptureWorker
    private var captureDeadline: Double?
    private var captureGeneration: UUID?
    private var countdownTicks: [RuntimeCancellation] = []
    deinit {
        countdownTicks.forEach { $0.cancel() }
    }
    public func noteDisplay(_ frame: DisplayFrame) {
        arpeggiatorModulationDisplay.update(frame.arpeggiatorModulation)
        guard authorize(.presentation) else { return }
        // Profile ticks stay transient; room evidence publishes only to fit UI.
        if !ownsDrawnContour, let contour = frame.contour, roomContour != contour {
            measuredRoomContour = contour
            roomContour = contour
            roomFit.fittingContour = SpatialRoomFit.fittingContour(contour)
            refreshRoomFitWarnings()
        }
        if let profile = frame.profile, var drawing = drawnContour {
            let g = profile.geometry
            let target = SpatialRoomContour.Geometry(pointCount: g.pointCount,
                angleResolutionDegrees: (g.endAngleDegrees-g.startAngleDegrees)/Double(g.pointCount-1),
                startAngleDegrees: g.startAngleDegrees, sourceIdentifier: profile.sourceIdentifier)
            if target != drawing.geometry {
                drawing.resample(to: target); drawnContour = drawing; publishDrawnContour()
            }
        }
        roomContourMatches = frame.selection.contourMatches
        roomContourFilteredOrders = frame.selection.filteredOrders
        latestDetectionRepresentative = frame.selection.representative
        latestDetectionObjects = frame.selection.objects
    }
    private func applyRoomCapture(_ update: RoomCaptureWorker.Update, generation: UUID) {
        guard captureGeneration == generation else { return }
        switch update {
        case .progress(let percent):
            captureDeadline = nil; endCountdown()
            contourCapture.notice = nil
            let progress = Double(percent) / 100
            if contourCapture.progress != progress { contourCapture.progress = progress }
        case .failed(let message): cancelRoomContourCapture(reason: message)
        case .completed(let contour):
            captureDeadline = nil; endCountdown()
            measuredRoomContour = contour
            roomContour = drawnContour?.effective(measured: contour) ?? contour
            roomFit.fittingContour = roomContour.map(SpatialRoomFit.fittingContour)
            contourCapture.progress = 1; contourCapture.isCapturing = false
            captureGeneration = nil
            refreshRoomFitWarnings()
            contourCapture.notice = "Room contour captured · wall spread ±\(contour.measuredScatterCentimeters) cm"
            roomContourMatches = true
            runtime.roomContour(roomContour)
            var configuration = document.detection; configuration.roomContour.isEnabled = true
            applyDetectionConfiguration(configuration)
        }
    }
    public func beginRoomContourCapture() {
        guard authorize(.captureRoom) else { return }
        guard !isCapturingRoomContour else { return }
        endCountdown()
        let generation = UUID(), startedAt = tempoClock.now
        captureGeneration = generation; captureDeadline = startedAt + 3
        roomCapture.begin(at: startedAt + 3) { [weak self] update in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.applyRoomCapture(update, generation: generation) }
            }
        }
        contourCapture.isCapturing = true; contourCapture.progress = 0
        contourCapture.countdownSeconds = 3; contourCapture.notice = "Hands out · 3"
        for second in 1...3 {
            countdownTicks.append(tempoClock.schedule(at: startedAt + Double(second), on: .main) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.captureGeneration == generation, let deadline = self.captureDeadline else { return }
                    let remaining = max(0, Int(ceil(deadline - self.tempoClock.now)))
                    self.contourCapture.countdownSeconds = remaining > 0 ? remaining : nil
                    self.contourCapture.notice = remaining > 0 ? "Hands out · \(remaining)" : "Waiting for scanner profiles"
                }
            })
        }
    }
    /// A running capture keeps the length it started with.
    public func setRoomContourCaptureDuration(seconds: Int) {
        guard authorize(.captureRoom) else { return }
        // Old session/UI values are intentionally ignored.  Capture length is
        // no longer an instrument setting, so a persisted old choice cannot
        // make a new room capture unexpectedly shorter or longer.
        guard !contourCapture.isCapturing else { return }
        contourCapture.durationSeconds = RoomContourCaptureState.defaultDurationSeconds
    }
    public func cancelRoomContourCapture() { cancelRoomContourCapture(reason: "Capture cancelled by user") }
    private func endCountdown() {
        countdownTicks.forEach { $0.cancel() }; countdownTicks.removeAll()
        contourCapture.countdownSeconds = nil
    }
    private func cancelRoomContourCapture(reason: String) {
        captureGeneration = nil; captureDeadline = nil; endCountdown()
        roomCapture.cancel(); contourCapture.isCapturing = false; contourCapture.progress = 0
        contourCapture.notice = reason
    }

    public var onWorkspaceChange: ((SpatialInstrumentWorkspace) -> Void)?
    public convenience init(runtime: PerformanceRuntime, audio: AudioHost, midi: MIDIPortOwner,
                initialWorkspace: SpatialInstrumentWorkspace = SpatialInstrumentWorkspace(grid: MetricSquareGrid.CellSize.fiveCentimeter.grid),
                midiClock: MIDIClockDriver? = nil, tempoClock: any RuntimeClock = MonotonicRuntimeClock(),
                clockReceiver: MIDIClockReceiver? = nil) throws {
        try self.init(runtime: runtime, audio: audio, midi: midi, initialWorkspace: initialWorkspace,
                      midiClock: midiClock, tempoClock: tempoClock, clockReceiver: clockReceiver,
                      roomCapture: RoomCaptureWorker())
    }
    init(runtime: PerformanceRuntime, audio: AudioHost, midi: MIDIPortOwner,
                initialWorkspace: SpatialInstrumentWorkspace = SpatialInstrumentWorkspace(grid: MetricSquareGrid.CellSize.fiveCentimeter.grid),
                midiClock: MIDIClockDriver? = nil, tempoClock: any RuntimeClock = MonotonicRuntimeClock(),
                clockReceiver: MIDIClockReceiver? = nil, roomCapture: RoomCaptureWorker) throws {
        self.roomCapture = roomCapture
        self.runtime = runtime; self.audio = audio; self.midi = midi
        self.midiClock = midiClock; self.tempoClock = tempoClock
        self.clockReceiver = clockReceiver
        let workspace = initialWorkspace
        var initial = MetricCanvasInteractionState()
        initial.projectWorkspace(workspace)
        canvas = CanvasSession(state: initial)
        let initialDocument = InstrumentDocument(
            spatial: try Self.compileWorkspace(workspace), detection: workspace.detectionConfiguration,
            revision: .newSession(), editorGrid: workspace.grid,
            channelName: workspace.channelName, channelColor: workspace.channelColor
        )
        document = initialDocument
        audio.hostMusicalClock.updateInternal(tempo: initialDocument.beatsPerMinute, at: tempoClock.now)
        compiledInstrument = try InstrumentCompiler.compile(initialDocument)
        canvas.projectWorkspace(workspace)
        canvas.onCommand = { [weak self] in self?.receiveCanvasCommand($0) ?? false }
        canvas.onPitchOperation = { [weak self] in self?.receivePitchOperation($0) ?? false }
        canvas.onAuthoringAttempt = { [weak self] in self?.authorize(.edit) ?? false }
        canvas.onToolChanged = { [weak self] _ in self?.audition(nil); self?.surfaceEditorStorage?.cancelEverything() }
        canvas.onPerformanceLockChanged = { [weak self] locked in
            self?.audition(nil)
            if locked { self?.surfaceEditorStorage?.cancelEverything() }
            self?.showInactiveSceneLayers = !locked
            self?.onPresetRecoveryLockChange?()
            if locked { self?.audio.cancelPendingChosenEditors() }
            if self?.isCapturingRoomContour == true { self?.cancelRoomContourCapture(reason: "Capture cancelled: performance mode changed") }
            if self?.notice == InstrumentAction.performanceLockReason { self?.notice = nil }
        }
        canvas.programCountingPreference = { [weak self] layerID in
            guard let self else { return true }
            let uid = self.document.spatial.layers.first { $0.id == layerID }?.midiTarget?.uniqueID ?? self.document.midiTarget?.uniqueID ?? 0
            return self.midi.programCountsFromOne(for: uid)
        }
        canvas.rememberProgramCounting = { [weak self] layerID, value in
            guard let self else { return }
            let uid = self.document.spatial.layers.first { $0.id == layerID }?.midiTarget?.uniqueID ?? self.document.midiTarget?.uniqueID ?? 0
            self.midi.rememberProgramCounting(value, for: uid)
        }
        canvas.onSelection = { [weak self] in self?.selectCanvasLayer($0) }
        refreshCanvasPresentation()
        runtime.onSceneChanged = { [weak self] scene in
            Task { @MainActor in self?.applyRuntimeScene(scene) }
        }
        runtime.install(compiledInstrument.stampingScene(generation: sceneGeneration))
        try audio.applyMixer(document.channels, masterLevelDecibels: document.masterLevelDecibels)
        midiClock?.setNoticeHandler { [weak self] message in
            Task { @MainActor in self?.notice = message }
        }
        clockReceiver?.setUpdateHandler { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self, self.isReceivingClock, !self.clockInputSuspended else { return }
                self.clockDisplay.observe(snapshot)
            }
        }
        audio.onEditorClosed = { [weak self] in
            guard let self else { return }
            self.presetChangeGeneration &+= 1
            self.presetPluginChangeGeneration &+= 1
            self.onPresetRecoveryChange?()
        }
        audioObservation = audio.objectWillChange.sink { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for strip in self.document.channels {
                        if let channel = try? self.audio.host(for: strip.id)?.captureUnspecifiedChannelState() {
                            self.onPresetChannelSnapshot?(channel)
                        }
                    }
                }
            }
        }
    }
    public static func compileWorkspace(_ workspace: SpatialInstrumentWorkspace) throws -> SpatialDocument {
        let workspaceJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace))
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 3, "spatialWorkspace": workspaceJSON])
        let compatibility = try CompatibilityImporter.read(data).get()
        guard let spatial = try SpatialDocumentImporter.document(from: compatibility).get().document else {
            throw SpatialDocumentError.emptyLayerStack
        }
        return spatial
    }
    /// Edit-ID of a mixer fader or detection regulator drag. A surface series has its own identity and is
    /// never offered to them: a fader that moves while a nudge burst is open starts steps of its own.
    private var mixerEditID: UUID? { surfaceSeriesOrigin == nil ? continuousEditID : nil }

    /// Gesture boundaries share the document's existing B1 edit-ID history.
    public func beginContinuousEdit() {
        guard authorize(.mixer) else { return }
        // Another input takes over: the surface burst ends here, it is not joined.
        if surfaceSeriesOrigin != nil { endSurfaceEditSeries() }
        guard continuousEditID == nil else { return }
        canvas.finishEditing()
        continuousEditID = UUID()
    }
    /// Ends the drag of a fader or regulator. It cannot end a surface series that began meanwhile:
    /// that one belongs to its own gesture and ends with `endSurfaceEditSeries()`.
    public func endContinuousEdit() {
        guard surfaceSeriesOrigin == nil else { return }
        closeContinuousEdit()
    }
    private func closeContinuousEdit() {
        // Returning a live control to its starting value (including Escape)
        // must not leave an empty undo step. Revisions track publications,
        // so compare content at the current revision.
        if let continuousEditID, lastCanvasEditID == continuousEditID,
           var previous = undoStack.last?.document {
            previous.revision = document.revision
            if previous == document {
                undoStack.removeLast()
                // A surface series that ended where it began never happened: its first edit
                // already dropped the redo branch, so the history from before it returns whole.
                if let origin = surfaceSeriesOrigin, origin.series == continuousEditID {
                    undoStack = origin.undo; redoStack = origin.redo
                }
            }
        }
        continuousEditID = nil; lastCanvasEditID = nil; surfaceSeriesOrigin = nil; surfaceSeriesKey = nil
    }
    public func edit(name: String = "Edit", _ change: (inout InstrumentDocument) -> Void) throws {
        guard authorize(.edit) else { return }
        try edit(name: name, coalescingID: nil, change)
    }
    private func edit(name: String, coalescingID: UUID?, restoresRoomContour: Bool = false, _ change: (inout InstrumentDocument) -> Void) throws {
        var next = document; change(&next); try commit(next, selectionBefore: canvas.selection, name: name, coalescingID: coalescingID, restoresRoomContour: restoresRoomContour)
    }
    private func retainsRuntimeMetadata(_ value: InstrumentDocument) -> Bool {
        value.spatial.layers == document.spatial.layers && value.scenes == document.scenes &&
            zip(value.channels, document.channels).allSatisfy { next, old in next.name == old.name && next.color == old.color }
    }
    private func commit(_ value: InstrumentDocument, selectionBefore: CanvasSelection, name: String, force: Bool = false, restoringPluginStates: Bool = false, coalescingID: UUID? = nil, restoresRoomContour: Bool = false, restoresCanvasSelection: Bool = false, releasingChannels: Set<UUID> = [], historyDocument: InstrumentDocument? = nil) throws {
        guard force || value != document || (restoringPluginStates && !releasingChannels.isEmpty) else {
            for id in releasingChannels { runtime.releaseAudioChannel(id) }; return
        }
        // Any confirmed edit that is not part of an open surface series closes that series first,
        // so a later cancel can never roll back history that edit has since extended.
        if force || (surfaceSeriesOrigin != nil && coalescingID != surfaceSeriesOrigin?.series) { closeContinuousEdit() }
        var next = value; next.detection.roomContour = roomContourConfiguration
        if !force, value.spatial.selectedLayerID == document.spatial.selectedLayerID,
           let spatial = try? next.spatial.selectingLayer(canvas.workspace.selectedLayerID) {
            next.spatial = spatial
        }
        next.revision = try document.revision.advanced()
        let retain = !force && InstrumentCompiler.canReuseIndex(from: document, for: next)
        let mixerOnly = retain && retainsRuntimeMetadata(next)
        let compiled: CompiledInstrument
        if retain {
            try InstrumentCompiler.validateSettings(next)
            compiled = mixerOnly ? compiledInstrument : try InstrumentCompiler.reusingIndex(compiledInstrument, from: document, for: next)
        } else {
            compiled = try CanvasTimingProbe.measure("runtime.compile") { try InstrumentCompiler.compile(next) }
        }
        if coalescingID == nil || coalescingID != lastCanvasEditID || !redoStack.isEmpty {
            undoStack.append(.init(document: historyDocument ?? document, selection: selectionBefore, name: name,
                restoresRoomContour: restoresRoomContour, restoresCanvasSelection: force || restoresCanvasSelection))
        } else if restoresCanvasSelection, !undoStack.isEmpty {
            undoStack[undoStack.count - 1].restoresCanvasSelection = true
        }
        lastCanvasEditID = coalescingID
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        if force { runtime.stop() }
        for id in releasingChannels { runtime.releaseAudioChannel(id) }
        install(next, compiled: compiled, restoringPluginStates: restoringPluginStates, mixerOnly: mixerOnly, replacingScene: force)
    }
    private func install(_ value: InstrumentDocument, compiled: CompiledInstrument, restoringPluginStates: Bool = false, mixerOnly: Bool = false, replacingScene: Bool = false) {
        // Deliberate authoring/Undo of activity is distinct from an old scene
        // mirror accompanying an unrelated edit while Main delivery is held.
        let authoredScene = !mixerOnly && {
            let previous = Dictionary(uniqueKeysWithValues: document.spatial.layers.map { ($0.id, $0) })
            return value.currentSceneID != document.currentSceneID || value.spatial.layers.count != previous.count ||
                value.spatial.layers.contains { layer in
                    guard let old = previous[layer.id] else { return true }
                    return old.isActive != layer.isActive || old.isSoloed != layer.isSoloed
                }
        }()
        let workspaceChanged = value.spatial.layers != document.spatial.layers || value.editorGrid != document.editorGrid ||
            value.scenes != document.scenes || value.currentSceneID != document.currentSceneID || value.detection != document.detection
        let channelMetadataChanged = value.channelName != document.channelName || value.channelColor != document.channelColor
        document = value
        if !mixerOnly { surfaceEditorStorage?.documentDidChange(value) }
        midiClock?.setTempo(value.beatsPerMinute)
        if clockDirection == .off || midiClock == nil { audio.hostMusicalClock.updateInternal(tempo: value.beatsPerMinute, at: tempoClock.now) }
        if replacingScene { audition(nil); tapHistory.reset() }
        compiledInstrument = compiled
        if workspaceChanged || replacingScene {
            canvas.projectWorkspace(CanvasDocumentProjection.workspace(value))
            refreshCanvasPresentation()
        } else if channelMetadataChanged {
            let current = canvas.workspace
            var workspace = SpatialInstrumentWorkspace(grid: current.grid, layers: current.layers,
                channelName: value.channelName, channelColor: value.channelColor,
                detectionConfiguration: current.detectionConfiguration, preserveLayerStructure: true,
                scenes: current.scenes, currentSceneID: current.currentSceneID)
            workspace.selectLayer(current.selectedLayerID)
            canvas.projectWorkspace(workspace)
        }
        if !mixerOnly {
            minimumSceneRevision = value.revision
            runtime.install(compiled.stampingScene(generation: sceneGeneration, replacing: replacingScene || authoredScene))
        }
        do { try audio.applyMixer(value.channels, masterLevelDecibels: value.masterLevelDecibels, restoringPluginStates: restoringPluginStates) }
        catch { notice = "Mixer update rejected" }
        // nil selection is the existing virtual-source choice; a document
        // without MIDI actions needs no open MIDI resource. Zero is reserved
        // for that explicit source, never a fallback for a vanished endpoint.
        if !mixerOnly {
            midi.apply(canvas.workspace.requiresMIDIOutput ? (value.midiTarget ?? .init(uniqueID: 0)) : nil,
                       layerTargets: value.spatial.layers.filter { $0.allRoutings.contains { $0.target.destination == .midi } }.compactMap(\.midiTarget))
        }
        onWorkspaceChange?(canvas.workspace)
    }
    public var canUndo: Bool { !undoStack.isEmpty }
    var historyDepth: Int { undoStack.count }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoMenuTitle: String { "Undo: \(undoStack.last?.name ?? "Edit")" }
    public var redoMenuTitle: String { "Redo: \(redoStack.last?.name ?? "Edit")" }
    @discardableResult public func undo() -> Bool { restore(undo: true) }
    @discardableResult public func redo() -> Bool { restore(undo: false) }
    private func restore(undo: Bool) -> Bool {
        guard authorize(.edit) else { return false }
        closeContinuousEdit()
        canvas.finishEditing()
        guard let previous = undo ? undoStack.last : redoStack.last else { return false }
        do {
            var value = previous.document
            // Undoing an explicit detector edit restores its session control;
            // undoing a preset or musical edit must not replace the room.
            let contourSettings = previous.restoresRoomContour ? value.detection.roomContour : roomContourConfiguration
            value.detection.roomContour = contourSettings
            let selected = canvas.workspace.selectedLayerID
            if value.spatial.layers.contains(where: { $0.id == selected }) {
                value.spatial = try value.spatial.selectingLayer(selected)
            }
            value.revision = try document.revision.advanced()
            let retain = InstrumentCompiler.canReuseIndex(from: document, for: value)
            let mixerOnly = retain && retainsRuntimeMetadata(value)
            let compiled: CompiledInstrument
            if retain {
                try InstrumentCompiler.validateSettings(value)
                compiled = mixerOnly ? compiledInstrument : try InstrumentCompiler.reusingIndex(compiledInstrument, from: document, for: value)
            }
            else { compiled = try CanvasTimingProbe.measure("runtime.compile") { try InstrumentCompiler.compile(value) } }
            roomContourConfiguration = contourSettings
            let current = History(document: document, selection: canvas.selection, name: previous.name,
                restoresRoomContour: previous.restoresRoomContour, restoresCanvasSelection: previous.restoresCanvasSelection)
            if undo { undoStack.removeLast(); redoStack.append(current) }
            else { redoStack.removeLast(); undoStack.append(current) }
            canvas.discardGestureForHistory()
            audio.cancelPendingChosenEditors()
            install(value, compiled: compiled, mixerOnly: mixerOnly)
            if previous.restoresCanvasSelection { canvas.projectWorkspace(canvas.workspace, selection: previous.selection) }
            return true
        } catch { notice = "History restore rejected"; return false }
    }
    public func updateDetectionConfiguration(_ configuration: DetectionConfiguration) {
        guard authorize(.edit) else { return }
        applyDetectionConfiguration(configuration)
    }
    private func applyDetectionConfiguration(_ configuration: DetectionConfiguration) {
        do {
            var candidate = document; candidate.detection = configuration
            try InstrumentCompiler.validateSettings(candidate)
            let previous = roomContourConfiguration
            roomContourConfiguration = configuration.roomContour
            do { try edit(name: "Detection", coalescingID: mixerEditID, restoresRoomContour: true) { $0.detection = configuration } }
            catch { roomContourConfiguration = previous; throw error }
        }
        catch { notice = "Invalid detection configuration" }
    }
    public func updateChannel(_ channel: InstrumentChannel) {
        guard let previous = document.channels.first(where: { $0.id == channel.id }) else {
            _ = authorize(.edit); return
        }
        var authoring = channel
        authoring.levelDecibels = previous.levelDecibels
        authoring.pan = previous.pan; authoring.muted = previous.muted; authoring.soloed = previous.soloed
        guard authorize(authoring == previous ? .mixer : .edit) else { return }
        do { try edit(name: "Channel", coalescingID: channel.name == previous.name ? mixerEditID : nil) { document in
            if let index = document.channels.firstIndex(where: { $0.id == channel.id }) { document.channels[index] = channel }
        } }
        catch { notice = "Invalid channel" }
    }
    public func selectMIDITarget(_ target: InstrumentMIDITarget?) {
        guard authorize(.edit) else { return }
        do { try edit(name: "MIDI destination", coalescingID: nil) { $0.midiTarget = target } }
        catch { notice = "Invalid MIDI destination" }
    }
    /// Explicit instrument choice in the channel strip, distinct from preset
    /// restoration and ordinary channel edits.
    public func selectInstrument(_ identity: SpatialAudioUnitIdentity?, stripID: UUID? = nil, editorTitle: String? = nil) {
        guard authorize(.edit) else { return }
        guard var channel = document.channels.first(where: { $0.id == (stripID ?? document.channel.id) }) else { return }
        channel.instrument = identity.map { InstrumentPlugin(identity: $0) }
        updateChannel(channel)
        if let identity, document.channels.first(where: { $0.id == channel.id })?.instrument?.identity == identity {
            audio.host(for: channel.id)?.playSelectedInstrumentWhenLoaded(identity)
            if let editorTitle {
                audio.host(for: channel.id)?.openEditorWhenLoaded(at: .instrument, identity: identity, title: editorTitle,
                    allowed: { [weak self] in self?.canvas.isPerformanceLocked == false })
            }
        }
    }
    public func addChannel() throws {
        guard authorize(.edit) else { return }
        guard document.channels.count < InstrumentDocument.maximumChannels else { throw CompiledInstrumentError.tooManyChannels(document.channels.count + 1) }
        try edit(name: "Add channel") { $0.channels.append(.init(id: UUID(), name: "Ch \($0.channels.count + 1)")) }
    }
    public func duplicateChannel(_ id: UUID) throws {
        guard authorize(.edit) else { return }
        guard document.channels.count < InstrumentDocument.maximumChannels else { throw CompiledInstrumentError.tooManyChannels(document.channels.count + 1) }
        guard let original = document.channels.first(where: { $0.id == id }) else { return }
        let state = try audio.host(for: id)?.snapshotChannel() ?? original
        var duplicate = original
        duplicate.id = UUID(); duplicate.name = original.name + " copy"
        duplicate.instrument = state.instrument
        duplicate.inserts = state.inserts.map { .init(id: UUID(), plugin: $0.plugin, bypassed: $0.bypassed) }
        try edit(name: "Duplicate channel") { $0.channels.append(duplicate) }
    }
    public func layersUsingChannel(_ id: UUID) -> Int {
        document.spatial.layers.filter { layer in
            layer.allRoutings.contains { $0.target.stripID == id } || layer.allCellActions.contains { $0.target.stripID == id }
        }.count
    }
    public func deleteChannel(_ id: UUID) throws {
        guard authorize(.edit) else { return }
        try edit(name: "Delete channel") { $0.channels.removeAll { $0.id == id } }
    }
    public func updateMasterLevel(_ decibels: Double) {
        guard authorize(.mixer) else { return }
        do { try edit(name: "Master level", coalescingID: mixerEditID) { $0.masterLevelDecibels = decibels } }
        catch { notice = "Invalid master level" }
    }
    public func updateCanvasCommandContext(size: CGSize, profile: B0ScanProfile?) {
        guard authorize(.presentation) else { return }
        if canvas.viewportOwner.state.canvasSize != size { _ = canvas.followCanvasSize(size) }
        commandProfile = profile.flatMap { (try? FullScanProfileAdapter.geometry(from: $0)) == nil ? nil : $0 }
        if let pendingLegacyViewport { applyLegacyPresetViewport(pendingLegacyViewport) }
    }
    public func updateCanvasCommandContext(size: CGSize, profileFrame: ProfileFrame?) {
        guard authorize(.presentation) else { return }
        if canvas.viewportOwner.state.canvasSize != size { _ = canvas.followCanvasSize(size) }
        commandProfile = profileFrame?.geometry.operatingMode == "unsupported" ? nil : profileFrame?.rawProfile
        if let pendingLegacyViewport { applyLegacyPresetViewport(pendingLegacyViewport) }
    }
    private var encodedViewport: ScanPlaneViewport? {
        if let pendingLegacyViewport { return pendingLegacyViewport }
        let value = canvas.viewport
        if value == .instrumentDefault { return .fullField }
        guard let size = commandSize, min(size.width, size.height) > 0 else { return nil }
        let radius = 81.9 // existing canonical maximum scanner extent, in meters
        return try? .build(centerX: value.centerXMeters / radius, centerY: value.centerYMeters / radius,
                           halfExtent: value.metersPerPoint * Double(min(size.width, size.height)) / (2 * radius))
    }
    public var legacyPresetViewport: ScanPlaneViewport { encodedViewport ?? .fullField }
    public func applyLegacyPresetViewport(_ value: ScanPlaneViewport) {
        guard authorize(.presentation) else { return }
        if value == .fullField { pendingLegacyViewport = nil; canvas.resetViewport(); return }
        guard let size = commandSize, min(size.width, size.height) > 0 else { pendingLegacyViewport = value; return }
        let radius = 81.9
        guard let viewport = try? MetricCanvasViewport.build(centerXMeters: value.centerX * radius,
            centerYMeters: value.centerY * radius, metersPerPoint: 2 * value.halfExtent * radius / Double(min(size.width, size.height))) else { return }
        pendingLegacyViewport = nil; canvas.applyPresetViewport(viewport, canvasSize: size)
    }
    public func isEnabled(_ command: MetricCanvasCommand) -> Bool {
        canvas.isEnabled(command, canvasSize: commandSize, profile: commandProfile)
    }
    @discardableResult public func perform(_ command: MetricCanvasCommand) -> Bool {
        canvas.perform(command, canvasSize: commandSize, profile: commandProfile)
    }
    public var auditionPoint: MetricScanPoint? { canvas.auditionPoint }
    private var auditionObserver: AuditionActivationObserver?
    private var auditionNeedsExit = false
    private func clearAuditionPresentation() {
        if auditionPoint != nil { canvas.setAuditionPoint(nil) }
        auditionObserver = nil
    }
    public func audition(_ point: MetricScanPoint?) {
        guard point == nil || (!canvas.isPerformanceLocked && canvas.tool == .audition) else { return }
        if let point, (!point.xMeters.isFinite || !point.yMeters.isFinite || point.yMeters < 0
            || hypot(point.xMeters, point.yMeters) * 100 > Double(UInt16.max)) {
            audition(nil); return
        }
        if point == nil {
            guard auditionPoint != nil || auditionNeedsExit else { return }
            clearAuditionPresentation()
            auditionNeedsExit = false
        } else {
            auditionNeedsExit = true
            if auditionPoint != point { canvas.setAuditionPoint(point) }
            if auditionObserver == nil {
                auditionObserver = AuditionActivationObserver(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                    object: NSApp, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.audition(nil) }
                })
            }
        }
        runtime.audition(point)
    }
    public func panicAll() { clearAuditionPresentation(); stopClockTransport(); runtime.panic() }
    public func setBeatsPerMinute(_ value: Double) {
        guard !isReceivingClock else { return }
        guard authorize(.tempo) else { return }
        // Like mixer values, tempo changes history and Clock without replacing
        // the installed performance state or rebinding the note destination.
        do { try edit(name: "Tempo", coalescingID: nil) { $0.beatsPerMinute = value } }
        catch { notice = "Tempo must be between 30 and 300 BPM" }
    }
    public func tapTempo() {
        guard !isReceivingClock else { return }
        guard authorize(.tempo) else { return }
        if let value = tapHistory.tap(at: tempoClock.now) { setBeatsPerMinute(value) }
    }
    public func startClockTransport() {
        guard !isReceivingClock else { return }
        guard !clockTransportPlaying else { return }
        internalClockPlaying = true; midiClock?.setTempo(document.beatsPerMinute); midiClock?.start()
        if midiClock == nil { audio.hostMusicalClock.updateInternal(tempo: document.beatsPerMinute, at: tempoClock.now, playing: true, reset: true) }
    }
    public func stopClockTransport() {
        internalClockPlaying = false; midiClock?.stop()
        if midiClock == nil { audio.hostMusicalClock.updateInternal(tempo: document.beatsPerMinute, at: tempoClock.now, playing: false) }
    }
    public func configureClock(enabled: Bool, targets: Set<Int32>) {
        configureClock(direction: enabled ? .send : .off, targets: targets, sourceID: nil)
    }
    public func configureClock(direction: ClockDirection, targets: Set<Int32>, sourceID: Int32?, sourceName: String = "No source selected") {
        guard authorize(.edit) else { return }
        let inputChanged = clockDirection != direction || clockSourceID != sourceID
        if inputChanged { audio.hostMusicalClock.configure(direction, documentTempo: document.beatsPerMinute, at: tempoClock.now) }
        if inputChanged { clockReceiver?.disconnect() }
        midiClock?.configure(enabled: direction == .send, targets: targets)
        clockSourceName = sourceName
        guard inputChanged else { return }
        clockConfiguration &+= 1
        let configuration = clockConfiguration
        if clockDirection != direction { internalClockPlaying = false; midiClock?.stop(); tapHistory.reset() }
        clockDirection = direction; clockSourceID = sourceID
        // Close immediately on Off/Send. Receive opens only after the sender
        // has acknowledged flush/Stop/close; stale Main completions cannot reopen it.
        if direction != .receive { clockDisplay.observe(.init()); return }
        clockDisplay.observe(.init())
        let activate: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.clockConfiguration == configuration, !self.clockInputSuspended else { return }
                self.clockReceiver?.configure(sourceID: sourceID)
            }
        }
        if let midiClock { midiClock.acknowledge(activate) } else { activate() }
    }
    public func suspendClockInput() {
        clockConfiguration &+= 1; clockInputSuspended = true; clockReceiver?.suspend()
        var stopped = externalClock; stopped.isPlaying = false; clockDisplay.observe(stopped)
    }
    public func resumeClockInput() {
        clockInputSuspended = false
        clockReceiver?.configure(sourceID: isReceivingClock ? clockSourceID : nil)
        clockReceiver?.resume()
    }
    public func duplicateLayer(_ id: UUID? = nil) {
        guard authorize(.edit) else { return }
        // The cell editor cannot copy a layer of surfaces; the document copies it whole.
        if let layer = document.spatial.layers.first(where: { $0.id == (id ?? canvas.workspace.selectedLayerID) }), layer.isSurfaceBacked {
            canvas.commitNumberEdits()
            do { try commit(try SurfaceEditor.duplicatingLayer(layer.id, in: document), selectionBefore: canvas.selection, name: "Duplicate layer") }
            catch { notice = "Duplicate layer rejected" }
            return
        }
        canvas.updateWorkspace(named: "Duplicate layer") { workspace in
            if let id { workspace.selectLayer(id) }
            _ = workspace.duplicateSelectedLayer()
        }
    }
    public func restorePresetScene(_ id: UUID) { selectScene(id) }
    public func selectScene(_ id: UUID) {
        guard authorize(.scene) else { return }
        audition(nil)
        runtime.selectScene(id)
    }
    /// The measured control path already changed Runtime's active set.  Mirror
    /// it in the document/canvas without committing or reinstalling a snapshot.
    private func applyRuntimeScene(_ scene: RuntimeSceneSnapshot) {
        guard scene.revision.session == document.revision.session, scene.generation >= sceneGeneration,
              minimumSceneRevision.map({ scene.revision.counter >= $0.counter }) ?? true else { return }
        let id = scene.currentSceneID
        // A queued Main callback from the previous preset cannot select a
        // scene that the current document no longer contains.
        guard id == nil || document.scenes.contains(where: { $0.id == id }) else { return }
        sceneGeneration = scene.generation
        guard scene.appliesSceneMembership else { return }
        if auditionPoint != nil { audition(nil) }
        let before = canvas.workspace
        var workspace = canvas.workspace
        workspace.selectScene(id)
        canvas.projectWorkspace(workspace)
        var next = document
        next.currentSceneID = id
        next.scenes = canvas.workspace.scenes
        next.spatial = (try? CanvasDocumentProjection.applying(canvas.workspace, before: before, to: document).spatial) ?? document.spatial
        fieldPlan.updateAudibility(workspace: canvas.workspace)
        fieldLabels = fieldPlan.labels(selectedLayerID: canvas.workspace.selectedLayerID)
        document = next
        runtimeSceneProjection = (id, Dictionary(uniqueKeysWithValues: next.spatial.layers.map { ($0.id, $0.isActive) }))
    }
    public func noteFootswitchPanic() { clearAuditionPresentation(); internalClockPlaying = false }
    public func stopSpatialMode() { audition(nil); stopClockTransport(); runtime.stop() }
    public func startSpatialAudio() {
        guard authorize(.edit) else { return }
        do { try audio.start(); startClockTransport() } catch { notice = "Audio start failed" }
    }
    public func stopSpatialAudio() {
        stopClockTransport()
        runtime.stop()
        runtime.acknowledge { [weak self] in Task { @MainActor in self?.audio.stop() } }
    }
    public var switchConfirmationProfiles: Int { document.detection.cellSelection.confirmationProfiles }
    public func setSwitchConfirmationProfiles(_ count: Int) {
        var configuration = document.detection; configuration.cellSelection.confirmationProfiles = count
        updateDetectionConfiguration(configuration)
    }
}

extension SpatialInstrumentRuntimeModel: PresetDocumentControlling {
    /// Window presence is a cheap, conservative edit signal, including inserts
    /// and instruments on every mixer strip. Never serialize AU state here.
    public var presetHasOpenPluginEditors: Bool {
        ([audio] + Array(audio.channelHosts.values)).contains { host in
            host.instrument?.window != nil || host.inserts.values.contains { $0.window != nil }
        }
    }
    public var presetViewport: PresetViewport { .init(canvas.viewport) }
    public func commitPendingPresetEdits() { canvas.commitNumberEdits() }
    public func snapshotPresetDocument() throws -> InstrumentDocument {
        var value = document
        value.spatial = try value.spatial.selectingLayer(canvas.workspace.selectedLayerID)
        value.channels = try audio.snapshotMixer()
        return value
    }
    public func presetAuthoringDocument(comparingTo reference: InstrumentDocument) throws -> InstrumentDocument {
        var value = document
        guard let projection = runtimeSceneProjection, projection.scene == value.currentSceneID else { return value }
        let activity = Dictionary(uniqueKeysWithValues: value.spatial.layers.map { ($0.id, $0.isActive) })
        if projection.activity == activity {
            let saved = Dictionary(uniqueKeysWithValues: reference.spatial.layers.map { ($0.id, $0.isActive) })
            value.currentSceneID = reference.currentSceneID
            value.spatial = try value.spatial.replacingLayers(
                value.spatial.layers.map { layer in saved[layer.id].map { layer.replacingActivity($0) } ?? layer })
        }
        return value
    }
    public func setPresetComparisonReference(_ value: InstrumentDocument) { audio.setComparisonReference(value.channels) }
    public func snapshotPresetDocument(comparingTo reference: InstrumentDocument) throws -> InstrumentDocument {
        var value = try presetAuthoringDocument(comparingTo: reference)
        value.channels = try audio.snapshotMixer(comparingTo: reference.channels)
        return value
    }
    public func applyPresetDocument(_ value: InstrumentDocument, restoringPluginStates: Bool = true) throws {
        guard authorize(.loadPreset) else { return }
        try commit(value, selectionBefore: canvas.selection, name: "Load Preset", force: true, restoringPluginStates: restoringPluginStates)
        runtimeSceneProjection = nil
        if isCapturingRoomContour { cancelRoomContourCapture(reason: "Capture cancelled: preset changed") }
    }
    public func applyPresetViewport(_ value: PresetViewport) {
        guard authorize(.presentation) else { return }
        guard let viewport = try? value.validated() else { return }
        pendingLegacyViewport = nil
        canvas.applyPresetViewport(viewport, canvasSize: commandSize)
    }
}

extension SpatialInstrumentRuntimeModel {
    /// Uses the same validated commit, history, compiler and release path as
    /// canvas bulk edits. Work on authoritative fine overrides, not their UI projection.
    @discardableResult public func applyPitchOperation(_ operation: SpatialPitchOperation) -> Bool {
        canvas.applyToSelection(operation)
    }
    private func receivePitchOperation(_ operation: SpatialPitchOperation) -> Bool {
        canvas.commitNumberEdits()
        guard authorize(.edit) else { return false }
        let ids = canvas.selection.effectiveLayerIDs(activeLayerID: canvas.workspace.selectedLayerID)
        let skipped = document.spatial.layers.filter { ids.contains($0.id) && $0.isLocked }.count
        let skippedMessage = skipped > 0 ? "\(skipped) locked layers unchanged" : nil
        do {
            let next = try SpatialCellBulkEdit.apply(operation, to: document, selection: canvas.selection,
                activeLayerID: canvas.workspace.selectedLayerID)
            guard next != document else { notice = skippedMessage; return false }
            try commit(next, selectionBefore: canvas.selection, name: operation.title)
            notice = skippedMessage
            return true
        } catch SpatialPitchOperation.Failure.range { notice = "C-1 … G9 exceeded; no notes changed" }
        catch SpatialPitchOperation.Failure.cellsOfASurface { notice = "Cells of a surface cannot be transposed; choose the surface itself, or nothing for the whole layer" }
        catch SpatialPitchOperation.Failure.unknownSurface { notice = "The chosen surface no longer exists; no notes changed" }
        catch { notice = "Pitch edit rejected; no notes changed" }
        return false
    }
}


extension SpatialInstrumentRuntimeModel {
    public func snapshotChannelPreset(_ id: UUID, name: String, includesLevelAndPan: Bool) throws -> ChannelPreset? {
        guard let channel = try audio.snapshotMixer().first(where: { $0.id == id }) else { return nil }
        return ChannelPreset(name: name, channel: channel, includesLevelAndPan: includesLevelAndPan)
    }
    @discardableResult public func loadChannelPreset(_ preset: ChannelPreset, into id: UUID) throws -> Bool {
        guard authorize(.edit), let index = document.channels.firstIndex(where: { $0.id == id }) else { return false }
        _ = try ChannelPresetCodec.encode(preset)
        var before = document
        if let snapshot = try audio.host(for: id)?.snapshotChannel() {
            before.channels[index].instrument = snapshot.instrument
            before.channels[index].inserts = snapshot.inserts
        }
        var next = document
        next.channels[index] = preset.replacing(next.channels[index])
        try commit(next, selectionBefore: canvas.selection, name: "Load channel preset", restoringPluginStates: true, releasingChannels: [id], historyDocument: before)
        return true
    }
    @discardableResult public func importPresetLayers(_ source: InstrumentDocument, ids: Set<UUID>, channelID: UUID?) throws -> Bool {
        guard authorize(.edit) else { return false }
        let selected = source.spatial.layers.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return false }
        let newIDs = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, UUID()) })
        let destinations = document.channels
        let target: @Sendable (SpatialRoutingTarget) -> SpatialRoutingTarget = { target in
            if case let .releaseLayer(id) = target { return .releaseLayer(layerID: newIDs[id] ?? id) }
            guard let old = target.stripID else { return target }
            let name = source.channels.first { $0.id == old }?.name
            let mapped = channelID ?? destinations.first { $0.name == name }?.id ?? SpatialRoutingTarget.missingStripID
            return target.withStripID(mapped)
        }
        let layers = try selected.map { layer -> SpatialDocumentLayer in
            try layer.copying(newLayerID: newIDs[layer.id]!, retargeting: target) { value in
                if case let .releaseLayer(id) = value { return .releaseLayer(layerID: newIDs[id] ?? id) }
                return value
            }.rederivingSurfaces(under: document.spatial.surfaceSettings)
        }
        var next = document
        next.spatial = try next.spatial.replacingLayers(next.spatial.layers + layers, selectedLayerID: layers[0].id)
        try commit(next, selectionBefore: canvas.selection, name: "Import layers")
        return true
    }
}

// MARK: Surface editing

extension SpatialInstrumentRuntimeModel {
    /// The one way a surface edit reaches the document: the same permission guard, pending number
    /// edits, validated commit (revision, compile, undo, install) as every other authoring path.
    /// A rejected edit leaves document, history and runtime untouched; a Note-On never follows from
    /// an edit, because installing a document only ever ends sounds that are no longer carried.
    ///
    /// Undo: every call is its own undo step unless the caller opened a series with
    /// `beginSurfaceEditSeries()`. Inside a series, edits of the same kind (`SurfaceEdit.coalescingKey`)
    /// share one step; an edit of another kind, a no-op edit, `undo`/`redo`, a document replacement
    /// and `endSurfaceEditSeries()` end the series. A rejected edit changes nothing and keeps it open.
    @discardableResult public func applySurfaceEdit(_ edit: SurfaceEdit) -> Bool {
        guard authorize(.edit) else { return false }
        canvas.commitNumberEdits()
        do {
            let next = try SurfaceEditor.apply(edit, to: document)
            guard next != document else { if surfaceSeriesOrigin != nil { endSurfaceEditSeries() }; return true }
            var series: UUID?
            if let key = edit.coalescingKey, surfaceSeriesOrigin != nil, let open = continuousEditID {
                if surfaceSeriesKey == nil { surfaceSeriesKey = key }
                if surfaceSeriesKey == key { series = open } else { endSurfaceEditSeries() }
            }
            try commit(next, selectionBefore: canvas.selection, name: edit.undoName, coalescingID: series)
            return true
        } catch let error as SurfaceEditError {
            notice = error.userMessage
        } catch { notice = "Surface edit rejected" }
        return false
    }

    /// Several surface edits that belong together (a conversion and the surface drawn onto it, the
    /// scaling of a whole selection) as one validated commit and one undo step. They are applied one
    /// after the other to a copy; if any is refused nothing at all changes. It is never part of a series.
    @discardableResult public func applySurfaceEdits(_ edits: [SurfaceEdit], undoName: String) -> Bool {
        guard authorize(.edit) else { return false }
        guard !edits.isEmpty else { return true }
        canvas.commitNumberEdits()
        do {
            var next = document
            for edit in edits { next = try SurfaceEditor.apply(edit, to: next) }
            guard next != document else { return true }
            try commit(next, selectionBefore: canvas.selection, name: undoName)
            return true
        } catch let error as SurfaceEditError {
            notice = error.userMessage
        } catch { notice = "Surface edit rejected" }
        return false
    }

    /// Start of a gesture or nudge burst (drag, key repeat, stepper hold). The caller ends it with
    /// `endSurfaceEditSeries()` or `cancelSurfaceEditSeries()`; nothing ends it by time.
    public func beginSurfaceEditSeries() {
        guard authorize(.edit) else { return }
        endSurfaceEditSeries()
        canvas.finishEditing()
        let series = UUID()
        continuousEditID = series
        surfaceSeriesOrigin = (series, undoStack, redoStack)
    }

    /// Ends the series. A series that ended where it began leaves no undo step.
    public func endSurfaceEditSeries() {
        surfaceSeriesKey = nil
        closeContinuousEdit()
    }

    /// Abandons the gesture: document and history (undo and redo, including the 100-step cap) return
    /// to exactly what they were when the series began, and nothing sounds from the return.
    @discardableResult public func cancelSurfaceEditSeries() -> Bool {
        guard let origin = surfaceSeriesOrigin, origin.series == continuousEditID else { return true }
        // A locked performance refuses before anything is touched: the gesture stays open and can
        // be cancelled once editing is allowed again.
        guard authorize(.edit) else { return false }
        let produced = lastCanvasEditID == origin.series
        let returnedToStart = produced && undoStack.last.map { entry in
            var previous = entry.document; previous.revision = document.revision
            return previous == document
        } == true
        // `restore` ends the series itself, and only after it has been allowed to run.
        if produced, !returnedToStart { guard restore(undo: true) else { return false } }
        else { endSurfaceEditSeries() } // a series that returned to its start has already dropped its step
        undoStack = origin.undo
        redoStack = origin.redo
        return true
    }
}
