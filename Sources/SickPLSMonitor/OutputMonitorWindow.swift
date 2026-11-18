import AppKit
import Combine
import SwiftUI
import SickPLSMonitorKit
import PlanariumApplication
import PlanariumDomain
import PlanariumRuntime

@MainActor final class OutputMonitorModel: ObservableObject {
    @Published var ports: [OutputMonitorSnapshot] = []
    @Published var owners: [SoundingNoteOwner] = []
    @Published var scene = "Scene · –"
    @Published var tempo = "Clock · Off"
    @Published var paused = false {
        didSet {
            if !paused { frozenEvents = Dictionary(uniqueKeysWithValues: ports.map { ($0.portID, $0.events) }) }
        }
    }
    @Published var frozenEvents: [UUID: [OutputMonitorEvent]] = [:]
    var channelNames: [UUID: String] = [:]
    var sceneNames: [UUID: String] = [:]
    var layers: [SpatialInstrumentLayer] = []
    private(set) var evaluations = 0
    func receive(_ frame: DisplayFrame) {
        let scene = "Scene · " + (frame.scene?.currentSceneID.map { sceneNames[$0] ?? $0.uuidString.prefix(8).description } ?? "–")
        guard ports != frame.outputMonitor || owners != frame.soundingNoteOwners || self.scene != scene else { return }
        self.scene = scene
        evaluations += 1
        ports = frame.outputMonitor; owners = frame.soundingNoteOwners
        if !paused { frozenEvents = Dictionary(uniqueKeysWithValues: ports.map { ($0.portID, $0.events) }) }
    }
    func color(layerID: UUID) -> Color {
        guard let layer = layers.first(where: { $0.id == layerID }) else { return .orange }
        return Color(red: layer.color.red, green: layer.color.green, blue: layer.color.blue)
    }
}

struct OutputMonitorView: View {
    @ObservedObject var model: OutputMonitorModel
    @State private var channel = -1
    @State private var layerID: UUID?
    @State private var zoom: Double
    init(model: OutputMonitorModel, zoom: Double = 1) {
        self.model = model
        _zoom = State(initialValue: zoom)
    }
    private func permits(_ port: OutputMonitorSnapshot, _ ch: Int, _ pitch: Int? = nil) -> Bool {
        guard channel < 0 || ch == channel else { return false }
        guard let layerID else { return true }
        if let pitch {
            return model.owners.contains { $0.layerID == layerID && $0.destination == port.destination && Int($0.channel) == ch && Int($0.number) == pitch }
        }
        return model.layers.first(where: { $0.id == layerID })?.routings.contains { routing in
            guard Int(routing.target.midiChannel ?? 255) == ch else { return false }
            if let strip = routing.target.stripID { return port.destination == .audioUnit(stripID: strip) }
            return port.destination.stripID == nil
        } == true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output Monitor").font(.title2).bold()
                Spacer()
                Picker("Channel", selection: $channel) {
                    Text("All channels").tag(-1)
                    ForEach(0..<16, id: \.self) { Text("Ch \($0 + 1)").tag($0) }
                }.frame(width: 140)
                Picker("Layer", selection: $layerID) {
                    Text("All layers").tag(UUID?.none)
                    ForEach(model.layers) { Text($0.name).tag(Optional($0.id)) }
                }.frame(width: 150)
            }
            HStack {
                Text("Keyboard zoom"); Slider(value: $zoom, in: 0.6...2).frame(width: 160)
                Spacer(); Toggle("Pause events", isOn: $model.paused)
            }.font(.caption)
            Text("\(model.scene)   ·   \(model.tempo)").font(.caption.monospacedDigit()).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.ports.isEmpty { Text("No output ports · open an AU or select a MIDI destination").foregroundColor(.secondary) }
                    ForEach(model.ports, id: \.portID) { port in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(destination(port.destination)).font(.headline)
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal) { keyboard(port).frame(height: 112) }
                                    .onAppear { proxy.scrollTo(60, anchor: .center) }
                            }
                            Text("● Playing   ◇ Held / Toggle · brightness = velocity").font(.caption).foregroundColor(.secondary)
                            controllers(port)
                            HStack {
                                ForEach(0..<16, id: \.self) { ch in
                                    if permits(port, ch), port.programs[ch] != 255 || port.pressures[ch] > 0 || port.bends[ch] != 8192 {
                                        Text("Ch \(ch + 1) · PB \(port.bends[ch]) · Pressure \(port.pressures[ch]) · PC \(port.programs[ch] == 255 ? "–" : String(port.programs[ch]))")
                                            .font(.caption.monospacedDigit())
                                    }
                                }
                            }
                            Text("Events · last 200").font(.caption).bold()
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach((model.frozenEvents[port.portID] ?? []).reversed(), id: \.sequence) { event in
                                    if permits(port, Int(event.status & 15)) {
                                        Text("\(event.sequence)   Ch \(Int(event.status & 15) + 1)   \(eventName(event))")
                                            .font(.system(size: 11, design: .monospaced))
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(12).background(Color.white.opacity(0.035)).cornerRadius(8)
                    }
                }
            }
        }.padding(16).frame(minWidth: 480, minHeight: 340)
            .foregroundColor(.primary).background(StageTheme.workspace).environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    }
    private func keyboard(_ port: OutputMonitorSnapshot) -> some View {
        var marks: [Int: [KeyboardMark]] = [:]
        let owners = Dictionary(grouping: model.owners.filter { $0.destination == port.destination }, by: { Int($0.channel) * 128 + Int($0.number) })
        for pitch in 0..<128 {
            for ch in 0..<16 where permits(port, ch, pitch) && port.notes[ch * 128 + pitch] > 0 {
                let velocity = port.notes[ch * 128 + pitch]
                let matches = owners[ch * 128 + pitch] ?? []
                if matches.isEmpty { marks[pitch, default: []].append(.init(color: .orange, velocity: velocity, held: false)) }
                for owner in matches { marks[pitch, default: []].append(.init(color: model.color(layerID: owner.layerID), velocity: velocity, held: owner.latched)) }
            }
        }
        return InstrumentKeyboard(notes: Array(0..<128), marks: marks)
            .frame(width: 75 * 18 * zoom, height: 88)
    }
    private func controllers(_ port: OutputMonitorSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175))], alignment: .leading) {
            ForEach((0..<2048).filter { port.controllers[$0] != 255 && permits(port, $0 / 128) }, id: \.self) { index in
                let value = port.controllers[index], ch = index / 128, cc = index % 128
                if value != 255 && permits(port, ch) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ch \(ch + 1) · CC \(cc) \(ccName(cc)) · \(value)").font(.caption.monospacedDigit())
                        ProgressView(value: Double(value), total: 127).tint(.orange)
                    }.opacity(port.events.last.map { $0.status == 0xB0 | UInt8(ch) && Int($0.number) == cc } == true ? 1 : 0.6)
                }
            }
        }
    }
    private func ccName(_ cc: Int) -> String { [1: "Mod", 7: "Volume", 11: "Expression", 64: "Sustain"][cc] ?? "" }
    private func destination(_ value: SpatialOutputDestination) -> String {
        switch value { case .midi: return "MIDI · selected port"
        case .midiEndpoint(let uid): return "MIDI · \(uid)"
        case .audioUnit(let id): return "AU channel · " + (model.channelNames[id] ?? id.uuidString.prefix(8).description) }
    }
    private func eventName(_ event: OutputMonitorEvent) -> String {
        let kind: String
        switch event.status & 0xF0 {
        case 0x90: kind = "Note On"; case 0x80: kind = "Note Off"
        case 0xB0: kind = event.number == 123 ? "All Notes Off / PANIC" : "CC"
        case 0xC0: kind = "Program"; case 0xD0: kind = "Pressure"; case 0xE0: kind = "Pitch Bend"
        default: kind = "Output"
        }
        return "\(kind) \(event.number) · \(event.value)"
    }
}

@MainActor final class OutputMonitorWindowController: NSObject, NSWindowDelegate {
    static let shared = OutputMonitorWindowController()
    let model = OutputMonitorModel()
    private var window: NSWindow?
    private weak var display: PerformanceDisplayModel?
    private weak var instrument: SpatialInstrumentRuntimeModel?
    private var subscription: AnyCancellable?
    private var clockSubscription: AnyCancellable?
    func configure(display: PerformanceDisplayModel, instrument: SpatialInstrumentRuntimeModel) {
        self.display = display; self.instrument = instrument
    }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Output Monitor"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: OutputMonitorView(model: model))
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); updateVisibility()
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateVisibility() }
    func windowWillClose(_ notification: Notification) { setVisible(false) }
    private func updateVisibility() { setVisible(window?.isVisible == true && window?.occlusionState.contains(.visible) == true) }
    private func refreshClock() {
        guard let instrument else { return }
        let text = "Tempo \(instrument.displayedBeatsPerMinute) BPM · Clock transport \(instrument.clockTransportPlaying ? "Playing" : "Stopped")"
        if model.tempo != text { model.tempo = text }
    }
    func setVisible(_ visible: Bool) {
        display?.setOutputMonitorVisible(visible)
        guard visible else { subscription = nil; clockSubscription = nil; return }
        guard subscription == nil, let display else { return }
        model.layers = instrument?.canvas.workspace.layers ?? []
        refreshClock()
        if let instrument {
            clockSubscription = instrument.objectWillChange.merge(with: instrument.clockDisplay.objectWillChange)
                .receive(on: RunLoop.main).throttle(for: .milliseconds(34), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] _ in self?.refreshClock() }
        }
        subscription = display.$frame.compactMap { $0 }
            .throttle(for: .milliseconds(34), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] frame in guard let self else { return }
                self.model.layers = self.instrument?.canvas.workspace.layers ?? []
                if let instrument = self.instrument {
                    self.model.channelNames = Dictionary(uniqueKeysWithValues: instrument.document.channels.map { ($0.id, $0.name) })
                    self.model.sceneNames = Dictionary(uniqueKeysWithValues: instrument.document.scenes.map { ($0.id, $0.name) })
                    self.refreshClock()
                }
                self.model.receive(frame) }
    }
}
