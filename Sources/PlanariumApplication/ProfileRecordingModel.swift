import Combine
import Foundation
import PlanariumDomain
import PlanariumRuntime

/// Main owns only the presentation. Profile copies, deadline, encoding and
/// atomic file I/O belong to a dedicated queue, never Main or the musical Q.
@MainActor public final class ProfileRecordingModel: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var notice = "Record 10 seconds of incoming raw profiles."
    @Published public private(set) var savedURL: URL?
    public let directory: URL
    private let worker: ProfileRecordingWorker
    private var generation: UUID?

    public init(directory: URL? = nil, clock: any RuntimeClock = MonotonicRuntimeClock()) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Planarium/Recordings", isDirectory: true)
        worker = ProfileRecordingWorker(clock: clock)
    }
    public func begin(detection: DetectionConfiguration, contour: SpatialRoomContour?) {
        guard !isRecording else { return }
        let id = UUID(); generation = id; isRecording = true; progress = 0
        notice = "Recording profiles · 10 s"
        worker.begin(directory: directory, detection: detection, contour: contour) { [weak self] update in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                switch update {
                case .progress(let value): self.progress = max(self.progress, value)
                case .saved(let url, let count):
                    self.generation = nil
                    self.isRecording = false; self.progress = 1; self.savedURL = url
                    self.notice = "Recorded \(count) profiles · \(url.lastPathComponent)"
                case .failed(let message):
                    self.generation = nil; self.isRecording = false; self.notice = message
                }
            }
        }
    }
    public func cancel() {
        generation = nil; worker.cancel(); isRecording = false; progress = 0
        notice = "Profile recording cancelled."
    }
    /// Safe to capture in the source's one existing binding. No UI reference
    /// or second profile/port subscription crosses into acquisition.
    nonisolated func receive(_ event: ProfileSourceEvent) { worker.receive(event) }
    nonisolated func acknowledge(_ completion: @escaping @Sendable () -> Void) { worker.acknowledge(completion) }
}

private final class ProfileRecordingWorker: @unchecked Sendable {
    enum Update: Sendable { case progress(Double), saved(URL, Int), failed(String) }
    private let queue = DispatchQueue(label: "de.planarium.profile-recording", qos: .utility)
    private let clock: any RuntimeClock
    private let lock = NSLock()
    private var accepting: UUID? // only field accessed outside queue, under lock
    private var generation: UUID? // queue only
    private var timer: RuntimeCancellation?
    private var scans: [ProfileRecording.Scan] = []
    private var startedAt = 0.0
    private var lastProgress = -1.0
    private var sessionID: UUID?
    private var lastSequence: UInt64?
    private var configuration = DetectionConfiguration.ownerDefaults
    private var contour: SpatialRoomContour?
    private var directory: URL?
    private var capturedAt = Date(timeIntervalSince1970: 0)
    private var report: (@Sendable (Update) -> Void)?
    init(clock: any RuntimeClock) { self.clock = clock }
    func acknowledge(_ completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in queue.async(execute: completion) }
    }
    deinit { timer?.cancel() }
    private func closeIngress(_ id: UUID?) {
        lock.lock(); if accepting == id { accepting = nil }; lock.unlock()
    }
    func begin(directory: URL, detection: DetectionConfiguration, contour: SpatialRoomContour?,
               report: @escaping @Sendable (Update) -> Void) {
        let id = UUID(), requestedAt = clock.now
        lock.lock(); accepting = id
        queue.async { [self] in
            timer?.cancel(); scans.removeAll(keepingCapacity: true)
            generation = id
            sessionID = nil; lastSequence = nil; startedAt = requestedAt; lastProgress = -1
            self.directory = directory; configuration = detection; self.contour = contour
            capturedAt = Date(); self.report = report
            tick(id)
        }
        lock.unlock()
    }
    func receive(_ event: ProfileSourceEvent) {
        lock.lock()
        guard let id = accepting else { lock.unlock(); return }
        let receivedAt = clock.now
        // Value types retain their immutable buffers; conversion is on queue.
        queue.async { [self] in
            guard report != nil, generation == id else { return }
            switch event {
            case .frame(let frame):
                guard receivedAt - startedAt < 10 else { requestFinish(); return }
                if let sessionID, sessionID != frame.sessionID { fail("Recording cancelled: scanner session changed."); return }
                if let lastSequence, frame.sequence <= lastSequence { return }
                sessionID = frame.sessionID; lastSequence = frame.sequence
                scans.append(.init(frame))
            case .ended(let id, _):
                if sessionID == nil || sessionID == id { fail("Recording cancelled: scanner input ended.") }
            case .began(let id):
                if let sessionID, sessionID != id { fail("Recording cancelled: scanner session changed.") }
            }
        }
        lock.unlock()
    }
    func cancel() {
        lock.lock(); accepting = nil
        queue.async { [self] in reset() }
        lock.unlock()
    }
    private func tick(_ id: UUID) {
        guard report != nil, generation == id else { return }
        timer?.cancel(); timer = nil
        let elapsed = max(0, clock.now - startedAt)
        if elapsed >= 10 { requestFinish(); return }
        if elapsed - lastProgress >= 0.1 { lastProgress = elapsed; report?(.progress(elapsed / 10)) }
        timer = clock.schedule(at: clock.now + 0.1, on: queue) { [weak self] in self?.tick(id) }
    }
    private func requestFinish() {
        let id = generation
        closeIngress(id); timer?.cancel(); timer = nil
        // A delayed progress callback can precede profiles already accepted
        // before the deadline. Close ingress, then drain those copies before
        // encoding; a cancelled generation cannot finish a later recording.
        queue.async { [self] in
            guard generation == id, report != nil else { return }
            finish()
        }
    }
    private func finish() {
        closeIngress(generation); timer?.cancel(); timer = nil
        guard !scans.isEmpty, let directory else { fail("No profiles recorded. Check the scanner connection."); return }
        do {
            let recording = ProfileRecording(capturedAt: capturedAt, detection: configuration, contour: contour, scans: scans)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(recording)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let url = directory.appendingPathComponent(formatter.string(from: capturedAt) + "-" + UUID().uuidString + ".json")
            try data.write(to: url, options: .atomic)
            report?(.saved(url, scans.count)); reset()
        } catch { fail("Profile recording could not be saved: \(error.localizedDescription)") }
    }
    private func fail(_ message: String) { report?(.failed(message)); reset() }
    private func reset() {
        closeIngress(generation); timer?.cancel(); timer = nil; report = nil; generation = nil
        scans.removeAll(keepingCapacity: true); sessionID = nil; lastSequence = nil
    }
}

/// Decorates the existing source binding once. Runtime receives every event
/// first; recording cannot replace, delay for I/O, or subscribe to that source.
struct RecordingProfileSource: RuntimeProfileSource {
    let source: any RuntimeProfileSource
    let recorder: ProfileRecordingModel
    let roomCapture: RoomCaptureWorker
    func bind(_ receive: @escaping @Sendable (ProfileSourceEvent) -> Void) {
        source.bind { [recorder, roomCapture] event in receive(event); roomCapture.receive(event); recorder.receive(event) }
    }
}
