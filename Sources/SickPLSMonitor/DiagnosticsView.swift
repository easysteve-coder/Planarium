import AppKit
import Combine
import SwiftUI
import PlanariumApplication
import PlanariumAudio
import PlanariumInput
import PlanariumMIDI
import PlanariumRuntime

@MainActor final class DiagnosticsReader: ObservableObject {
    @Published private(set) var snapshot: DiagnosticSnapshot?
    @Published private(set) var window: DiagnosticMeasurementWindow?
    @Published private(set) var measuring = false
    private var beginning: DiagnosticSnapshot?
    private let timer = MainRunLoopTimer()
    private var sample: (() -> DiagnosticSnapshot)?
    private var visible = true
    private(set) var readCount = 0
    func start(sample: @escaping () -> DiagnosticSnapshot) {
        self.sample = sample; startTimer()
    }
    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if visible { read(); startTimer() } else { timer.remove() }
    }
    private func startTimer() {
        guard visible, sample != nil, !timer.isActive else { return }
        let value = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        value.tolerance = 0.05
        timer.install(value); RunLoop.main.add(value, forMode: .common)
        RunLoop.main.add(value, forMode: .eventTracking)
    }
    func read() {
        guard visible, let next = sample?() else { return }
        readCount += 1
        // Timestamp and unrounded age change while the displayed numbers do
        // not. Compare exactly the public presentation, retaining full samples
        // for explicit begin/end measurement windows.
        if snapshot?.lines != next.lines || snapshot?.runtime != next.runtime { snapshot = next }
    }
    func beginMeasurement() {
        guard let value = sample?() else { return }
        beginning = value; snapshot = value; window = nil; measuring = true
    }
    func endMeasurement(interrupted: Bool = false) {
        guard let begin = beginning, let end = sample?() else { return }
        snapshot = end; window = .init(begin: begin, end: end, interrupted: interrupted)
        beginning = nil; measuring = false
    }
    func stop() {
        if measuring { endMeasurement(interrupted: true) }
        timer.remove(); sample = nil
    }
}
struct DiagnosticsView: View {
    let input: InputOwner
    let runtime: PerformanceRuntime
    let host: AudioHost
    let midi: MIDIPortOwner
    @Environment(\.presentationVisible) private var presentationVisible
    @State private var expanded = false
    @StateObject private var reader = DiagnosticsReader()
    var body: some View {
        FullRowDisclosure(expanded: $expanded, label: {
            FieldToolbarIconLabel(title: "Diagnostics", symbol: "waveform.path.ecg").help("Diagnostics").accessibilityLabel("Diagnostics")
        }) {
            if expanded {
                DiagnosticsContent(snapshot: reader.snapshot, window: reader.window, measuring: reader.measuring,
                    begin: { reader.beginMeasurement() }, end: { reader.endMeasurement() })
                .onAppear {
                    reader.setVisible(presentationVisible)
                    reader.start { DiagnosticSnapshot.read(input: input, runtime: runtime, host: host, midi: midi) }
                }
                .onChange(of: presentationVisible) { reader.setVisible($0) }
                .onDisappear { reader.stop() }
            }
        }.help("Show input, runtime and output diagnostics. Refreshes only while expanded, at most four times per second.")
    }
}
struct DiagnosticsContent: View {
    let snapshot: DiagnosticSnapshot?
    let window: DiagnosticMeasurementWindow?
    let measuring: Bool
    let begin: () -> Void
    let end: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IconActionButton(measuring ? "Stop measurement window" : "Start measurement window",
                             symbol: measuring ? "stop.fill" : "play.fill", action: measuring ? end : begin)
                .help("Measure counters and runtime timings until stopped. Hiding diagnostics ends the window as interrupted.")
            if let snapshot {
                ForEach(Array(snapshot.lines.enumerated()), id: \.offset) { _, line in Text(line).textSelection(.enabled) }
            } else { Text("Waiting for diagnostic snapshot…") }
            if let window, let snapshot {
                Divider()
                ForEach(Array(window.lines.enumerated()), id: \.offset) { _, line in Text(line).textSelection(.enabled) }
                IconActionButton("Copy diagnostic report", symbol: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DiagnosticReportPresentation.copyText(snapshot, window: window), forType: .string)
                }.help("Copies current numeric diagnostics and the completed measurement window. No raw measurements, device names or paths are included.")
            }
        }.font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
    }
}
