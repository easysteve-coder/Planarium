import AppKit
import SwiftUI
import XCTest
import PlanariumDomain
import PlanariumMIDI
import PlanariumPresets
@testable import SickPLSMonitor

@MainActor final class PerformanceSettingsTests: XCTestCase {
    func testOfflinePerformanceSettingsStatesBroadAndNarrow() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SICK_BUEHNE_IMAGES"] ?? NSTemporaryDirectory()).appendingPathComponent("buehne-images")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try MonitorRootFixture(graph: MonitorGraph())
        defer { fixture.root.terminate {} }
        let presetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsPreset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: presetDirectory) }
        let presets = PresetControlModel(store: .init(directory: presetDirectory), documentOwner: fixture.root.document, factoryPresets: .empty)
        let source = SettingsFootswitchSource()
        let defaults = UserDefaults(suiteName: "SettingsFootswitch-\(UUID())")!
        let footswitch = PanicFootswitchModel(defaults: defaults, factory: { _, receive, _ in source.bind(receive); return source }, panic: {})
        defer { footswitch.shutdown() }
        footswitch.selectSource(1)
        for state in ["not-set", "waiting", "ready", "source-missing", "reopen-off", "missing-preset", "corrupt-recovery", "recovered"] {
            if state == "waiting" { footswitch.learn() }
            if state == "ready" {
                source.press(); for _ in 0..<10 { await Task.yield() }
                try? await Task.sleep(nanoseconds: 20_000_000)
                XCTAssertEqual(footswitch.status, "ready")
            }
            if state == "source-missing" { fixture.root.footswitch.selectSource(2) }
            if state == "reopen-off" { presets.reopenLastPreset = false }
            if state == "missing-preset" || state == "corrupt-recovery" || state == "recovered" {
                let url = presetDirectory.appendingPathComponent("Recovery.json"), recovery = PresetRecoveryStore(url: url)
                defaults.set(true, forKey: "reopenLastPreset"); defaults.set("Missing", forKey: "presetLastName")
                presets.configureRecovery(defaults: defaults, store: recovery)
                if state == "corrupt-recovery" {
                    try FileManager.default.createDirectory(at: presetDirectory, withIntermediateDirectories: true)
                    try Data("corrupt".utf8).write(to: url, options: .atomic)
                }
                if state == "recovered" {
                    recovery.write(.init(name: "Recovery", document: fixture.root.document.document)); recovery.flush()
                }
                presets.restoreStartup()
            }
            for width in [340, 620] {
                let view = PerformanceSettingsView(footswitch: state == "source-missing" ? fixture.root.footswitch : footswitch, presets: presets, sources: { [.init(id: 1, name: "Stage Pedal")] })
                try render(view, width: width, name: "\(state)-\(width).png", directory: directory)
            }
        }
        var chord = ChordEffect(); chord.mode = .multi
        for width in [380, 640] { try render(ChordEffectEditor(effect: .constant(chord)), width: width, name: "multi-\(width).png", directory: directory, height: 560) }
    }
    private func render<V: View>(_ view: V, width: Int, name: String, directory: URL, height: Int = 300) throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark).background(Color(white: 0.18)))
        host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}
private final class SettingsFootswitchSource: MIDIClockSource, @unchecked Sendable {
    private let lock = NSLock()
    private var receive: (@Sendable (MIDIClockPacket) -> Void)?
    func bind(_ action: @escaping @Sendable (MIDIClockPacket) -> Void) { lock.lock(); receive = action; lock.unlock() }
    func press() { lock.lock(); let callback = receive; lock.unlock(); callback?(.init(bytes: [0xb0, 64, 127], timestamp: 0, arrival: 0)) }
    func close() {}
}
