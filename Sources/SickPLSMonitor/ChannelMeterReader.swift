import Combine
import Foundation
import PlanariumApplication
import PlanariumAudio
import SickPLSMonitorKit

/// One presentation pulse for every visible channel and master meter. Weak
/// entries never keep a disappeared surface alive; audio taps remain independent.
@MainActor final class MeterReadPulse {
    static let shared = MeterReadPulse()
    private final class Entry {
        weak var reader: ChannelMeterReader?
        init(_ reader: ChannelMeterReader) { self.reader = reader }
    }
    private var readers: [ObjectIdentifier: Entry] = [:]
    private let timer = MainRunLoopTimer()
    private(set) var tickCount = 0
    var timerCount: Int { timer.isActive ? 1 : 0 }
    func contains(_ reader: ChannelMeterReader) -> Bool { readers[ObjectIdentifier(reader)] != nil }
    func set(_ reader: ChannelMeterReader, active: Bool) {
        readers = readers.filter { $0.value.reader != nil }
        readers[ObjectIdentifier(reader)] = active ? Entry(reader) : nil
        if readers.isEmpty { timer.remove(); return }
        guard !timer.isActive else { return }
        let value = Timer(timeInterval: ChannelMeterReader.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        value.tolerance = ChannelMeterReader.interval * 0.2
        timer.install(value); RunLoop.main.add(value, forMode: .common)
        RunLoop.main.add(value, forMode: .eventTracking)
    }
    func read() {
        tickCount += 1
        readers = readers.filter { $0.value.reader != nil }
        for entry in readers.values { entry.reader?.read() }
        if readers.isEmpty { timer.remove() }
    }
}

/// Only visible half-dB levels and clip transitions publish. Raw decay, tap
/// counters and clip hold time are private, so silence has no publications.
@MainActor final class ChannelMeterReader: ObservableObject {
    static let interval = 1.0 / 30
    static let decayDecibelsPerSecond = 20.0
    @Published private(set) var peaks = StereoPeaks()
    @Published private(set) var clip = MeterClipState()
    private var envelope = StereoPeaks()
    private var clipHold = MeterClipState()
    private weak var host: AudioHost?
    private var visible = true
    private var lastRead: Double?
    var isTimerActive: Bool { MeterReadPulse.shared.contains(self) }
    private var activity: AnyCancellable?
    private let hostViewer = UUID()
    private let readsMaster: Bool
    init(master: Bool = false) { readsMaster = master }
    private var viewers: Set<UUID> = []
    nonisolated static let directViewer = UUID()
    func start(_ host: AudioHost, viewer: UUID = ChannelMeterReader.directViewer) {
        viewers.insert(viewer)
        if self.host === host, activity != nil { host.setMeterVisible(visible, viewer: hostViewer); return }
        stopReading()
        self.host = host
        activity = host.$isMeterActive.removeDuplicates().sink { [weak self] active in
            MainActor.assumeIsolated { self?.setPolling(active) }
        }
        host.setMeterVisible(visible, viewer: hostViewer)
    }
    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        host?.setMeterVisible(visible && !viewers.isEmpty, viewer: hostViewer)
        setPolling(host?.isMeterActive == true)
    }
    private func setPolling(_ active: Bool) {
        guard visible, active else {
            MeterReadPulse.shared.set(self, active: false); lastRead = nil
            if !active { clear() }
            return
        }
        guard !isTimerActive else { return }
        lastRead = ProcessInfo.processInfo.systemUptime
        MeterReadPulse.shared.set(self, active: true)
    }
    func stop(viewer: UUID = ChannelMeterReader.directViewer) {
        viewers.remove(viewer)
        guard viewers.isEmpty else { return }
        stopReading()
    }
    private func stopReading() {
        host?.setMeterVisible(false, viewer: hostViewer); activity?.cancel(); activity = nil
        MeterReadPulse.shared.set(self, active: false); host = nil; lastRead = nil
        clear()
    }
    private func clear() {
        envelope = .init(); clipHold.reset()
        if peaks != StereoPeaks() { peaks = StereoPeaks() }
        if clip.isClipped { clip.reset() }
    }
    private(set) var readCount = 0
    func read() {
        guard visible else { return }
        readCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, now - (lastRead ?? now)); lastRead = now
        observe((readsMaster ? host?.takeMasterPeaks() : host?.takeMeterPeaks()) ?? StereoPeaks(), elapsed: elapsed)
    }
    static func displayGain(_ gain: Float) -> Float {
        guard gain.isFinite, gain > 0 else { return 0 }
        let db = min(0, (20 * log10(Double(gain)) * 2).rounded() / 2)
        guard db > -60 else { return 0 }
        return Float(pow(10, db / 20))
    }
    func observe(_ sample: StereoPeaks, elapsed: Double) {
        clipHold.advance(elapsed: elapsed)
        clipHold.observe(peak: Double(max(sample.left, sample.right)))
        if clipHold.isClipped != clip.isClipped { clip = clipHold }
        let factor = Float(pow(10, -Self.decayDecibelsPerSecond * max(0, elapsed) / 20))
        envelope = StereoPeaks(left: max(sample.left, envelope.left * factor),
                               right: max(sample.right, envelope.right * factor))
        let next = StereoPeaks(left: Self.displayGain(envelope.left), right: Self.displayGain(envelope.right))
        guard next != peaks else { return }
        peaks = next
    }
    func resetClip() {
        clipHold.reset()
        if clip.isClipped { clip.reset() }
    }
}
