import XCTest
import AppKit
import AVFoundation
import SwiftUI
import PlanariumAudio
import PlanariumDomain
import PlanariumPresets
import PlanariumRuntime
import SickPLSControlCore
@testable import SickPLSMonitor

@MainActor final class OwnerChannelStripTests: XCTestCase {
    func testOutputDeviceStatesRenderWideAndNarrowIncludingPerform() async throws {
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in ["system", "device", "off", "missing", "returned"] {
            let graph = MonitorGraph(); graph.permitsStart = true
            let fixture = try MonitorRootFixture(graph: graph)
            let outputs = OwnerOutputCatalog()
            let model = AudioOutputDeviceControlModel(host: fixture.root.audio, catalog: outputs)
            model.refresh()
            if state != "system" { model.selectDevice(outputs.devices[2]) }
            if state != "off" { model.startAudio() }
            if state == "missing" || state == "returned" {
                let device = outputs.devices.removeLast(); outputs.changed?()
                if state == "returned" { outputs.devices.append(device); outputs.changed?() }
            }
            for _ in 0..<20 { await Task.yield() }
            if state == "missing" { XCTAssertTrue(try XCTUnwrap(model.notice).contains("not found")) }
            if state == "returned" { XCTAssertTrue(model.canRestoreDevice) }
            let catalog = AudioCatalogModel(document: fixture.root.document, source: OwnerCatalog())
            for width: CGFloat in [360, 840] {
                fixture.root.document.canvas.setPerformanceLocked(width == 360)
                let view = ChannelStripView(spatialInstrument: fixture.root.document, audioUnits: catalog,
                    host: fixture.root.audio, midiOutput: fixture.root.midi, audioDevices: model)
                let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).preferredColorScheme(.dark))
                host.frame = .init(x: 0, y: 0, width: width, height: 900)
                host.wantsLayer = true
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    directory.appendingPathComponent("audio-output-\(state)-\(Int(width)).png"))
            }
            model.shutdown()
            await withCheckedContinuation { continuation in fixture.root.terminate { continuation.resume() } }
        }
    }
    func testRenderedSettingsSurfaceInvokesEditorBesidePowerNotTheChoiceMenu() throws {
        var opened = 0, toggled = 0
        let row = StudioInsertRow(title: "Loaded", accessibilityBase: "owner.action", tint: .purple,
            isOn: true, canToggle: true, canOpen: true, toggle: { toggled += 1 }, open: { opened += 1 },
            choices: [.init(id: "empty", title: "None", selected: false, action: {})], controlsAreVisibleForPreview: true)
        let host = NSHostingView(rootView: row)
        let window = NSWindow(contentRect: .init(x: 30, y: 30, width: 92, height: 30), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil); host.layoutSubtreeIfNeeded()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for x in [27.0, 9.0] {
            let point = host.convert(.init(x: x, y: 15), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            let up = try event(.leftMouseUp); NSApp.postEvent(up, atStart: true)
            window.sendEvent(try event(.leftMouseDown)); window.sendEvent(up)
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            XCTAssertEqual(opened, 1)
            XCTAssertEqual(toggled, x == 27 ? 0 : 1)
        }
    }
    func testOwnerRun2SettingsAreBesidePowerAndChoiceArrowsAtRightInRenderedField() throws {
        for width in [72, 92] {
            let row = StudioInsertRow(title: "Loaded", accessibilityBase: "owner.position",
                tint: .purple, isOn: true, canToggle: true, canOpen: true,
                toggle: {}, open: {}, choices: [.init(id: "empty", title: "None", selected: false, action: {})],
                controlsAreVisibleForPreview: true)
            let bitmap = try renderField(row, width: width)
            let settings = try glyphBounds(bitmap, columns: 18..<36)
            let arrows = try glyphBounds(bitmap, columns: (width - 18)..<width)
            XCTAssertEqual(settings.midX, 27, accuracy: 3)
            XCTAssertEqual(arrows.midX, Double(width - 9), accuracy: 3)
            // The chevrons occupy a taller vertical span than the three
            // horizontal settings bars; swapping the actual controls reverses it.
            XCTAssertGreaterThan(arrows.height, settings.height)
            print("Owner field positions width=\(width) settings=\(settings) arrows=\(arrows)")
        }
    }
    // Native UI behavior is covered by CanvasWindowContractTests.
    private func renderField(_ row: StudioInsertRow, width: Int) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: row.environment(\.colorScheme, .dark).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 30)
        host.wantsLayer = true; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 30,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst, bytesPerRow: 0, bitsPerPixel: 0))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
            directory.appendingPathComponent("owner-field-position-\(width).png"))
        return bitmap
    }
    private func glyphBounds(_ bitmap: NSBitmapImageRep, columns: Range<Int>) throws -> CGRect {
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        var points: [CGPoint] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in columns {
                let offset = y * bitmap.bytesPerRow + x * 4
                // Cached pixels are premultiplied; keep antialiased strokes
                // while excluding the purple background and hover dividers.
                if min(bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]) > 150 {
                    points.append(.init(x: x, y: y))
                }
            }
        }
        let first = try XCTUnwrap(points.first, "No glyph in expected image position")
        return points.dropFirst().reduce(CGRect(x: first.x, y: first.y, width: 1, height: 1)) {
            $0.union(CGRect(x: $1.x, y: $1.y, width: 1, height: 1))
        }
    }
    func testRegisteredManufacturerNamesArePreservedAndLegacyDLSNameIsReadable() throws {
        let descriptions = OwnerCatalog()
        let catalog = AudioUnitEffectCatalog(source: descriptions)
        XCTAssertEqual(catalog.availableInstruments().first?.name, "UADx Opal Morphing Synth")
        XCTAssertEqual(catalog.availableEffects().first?.name, "Temperance Lite")
        XCTAssertEqual(AudioUnitEffectCatalog.presentationName(.init(componentType: 0x61756d75, componentSubType: 0x646c7320,
            componentManufacturer: 0x6170706c, name: "DLSMusicDevice", manufacturerName: "Apple", isSandboxSafe: true)), "DLS Music Device")
    }
    func testInstrumentAndInsertFieldsRenderAllStatesWideAndNarrow() async throws {
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in ["empty", "loading", "loaded", "bypassed", "error"] {
            let plugins = OwnerPlugins(fails: state == "error", loading: state == "loading")
            let fixture = try MonitorRootFixture(components: plugins)
            if state != "empty" {
                fixture.root.document.updateChannel(.init(instrument: .init(identity: OwnerCatalog.instrument),
                    inserts: (0..<3).map { _ in .init(id: UUID(), plugin: .init(identity: OwnerCatalog.effect), bypassed: state == "bypassed") }))
            }
            for _ in 0..<100 { await Task.yield() }
            let catalog = AudioCatalogModel(document: fixture.root.document, source: OwnerCatalog())
            for width: CGFloat in [840, 360] {
                let view = ChannelStripView(spatialInstrument: fixture.root.document, audioUnits: catalog,
                    host: fixture.root.audio, midiOutput: fixture.root.midi,
                    audioDevices: AudioOutputDeviceControlModel(host: fixture.root.audio))
                XCTAssertEqual(view.selectedInstrument?.name, state == "empty" ? nil : "UADx Opal Morphing Synth")
                if state != "empty" {
                    XCTAssertFalse(view.instrumentIsOn, "A loaded instrument on a stopped host is off")
                    for index in 0..<3 {
                        XCTAssertEqual(view.slots[index].isOn, state == "loaded")
                        XCTAssertEqual(view.slots[index].canToggle, state == "loaded" || state == "bypassed")
                        XCTAssertEqual(fixture.root.audio.status[.insert(fixture.root.document.document.channel.inserts[index].id)] == .loaded, view.slots[index].isOn)
                    }
                    switch state {
                    case "loading":
                        XCTAssertTrue(view.slots[0].title.hasSuffix(" …"))
                        XCTAssertEqual(view.preparation, .preparing(view.selectedInstrument!.identity))
                    case "error":
                        XCTAssertTrue(view.slots[0].title.hasSuffix(" !"))
                        XCTAssertEqual(view.preparation, .failed(view.selectedInstrument!.identity))
                    default:
                        XCTAssertEqual(view.slots[0].title, "Temperance Lite")
                        XCTAssertEqual(view.preparation, .prepared(view.selectedInstrument!.identity))
                    }
                }
                let field = StudioInsertRow(title: view.slots[0].title, accessibilityBase: "owner.\(state)",
                    tint: .purple, isOn: view.slots[0].isOn, canToggle: view.slots[0].canToggle,
                    canOpen: state == "loaded" || state == "bypassed", toggle: {}, open: {},
                    choices: [.init(id: "empty", title: "None", selected: state == "empty", action: {})],
                    controlsAreVisibleForPreview: true)
                let fieldBitmap = try renderField(field, width: width == 840 ? 108 : 92)
                try XCTUnwrap(fieldBitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("owner-field-\(state)-\(Int(width)).png"))
                let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).preferredColorScheme(.dark))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                host.wantsLayer = true; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: 900,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bitmapFormat: .alphaFirst, bytesPerRow: 0, bitsPerPixel: 0))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("owner-strip-\(state)-\(Int(width)).png"))
            }
            await withCheckedContinuation { continuation in fixture.root.terminate { continuation.resume() } }
        }
    }
}
private final class OwnerCatalog: AudioUnitComponentSource {
    static let instrument = SpatialAudioUnitIdentity(componentType: 0x61756d75, componentSubType: 101, componentManufacturer: 202)
    static let effect = SpatialAudioUnitIdentity(componentType: 0x61756678, componentSubType: 303, componentManufacturer: 404)
    func instrumentComponentDescriptions() -> [AudioUnitComponentDescription] {
        [.init(componentType: Self.instrument.componentType, componentSubType: Self.instrument.componentSubType,
               componentManufacturer: Self.instrument.componentManufacturer, name: "UADx Opal Morphing Synth", manufacturerName: "Universal Audio", isSandboxSafe: true)]
    }
    func effectComponentDescriptions() -> [AudioUnitComponentDescription] {
        [.init(componentType: Self.effect.componentType, componentSubType: Self.effect.componentSubType,
               componentManufacturer: Self.effect.componentManufacturer, name: "Temperance Lite", manufacturerName: "Synthetic manufacturer", isSandboxSafe: true)]
    }
}
@MainActor private final class OwnerPlugins: PluginComponentSource {
    let fails: Bool, loading: Bool
    init(fails: Bool, loading: Bool) { self.fails = fails; self.loading = loading }
    func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        if loading { return }
        completion(fails ? .failure(.init("Synthetic load failure")) : .success(OwnerUnit()))
    }
}
@MainActor private final class OwnerUnit: PluginUnit {
    var audioNode: AVAudioUnit? { nil }
    func readState() throws -> Data { Data() }
    func setState(_ state: Data) throws {}
    func setBypass(_ bypassed: Bool) {}
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary { OwnerSchedule() }
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void) { XCTFail("No real editor in headless test") }
}
private struct OwnerSchedule: AUScheduleBoundary {
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult {
        // A10 shutdown broadcasts CC123 on all channels. It releases notes;
        // loading/rendering must still never start one or send other controls.
        if bytes.count == 3, bytes[0] & 0xf0 == 0xb0, bytes[1] == 123, bytes[2] == 0 { return .sent }
        XCTFail("No audio output in headless test"); return .sent
    }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { XCTFail("No audio output in headless test"); return .sent }
}

@MainActor private final class OwnerOutputCatalog: AudioOutputCatalog {
    var devices: [AudioOutputDevice] = [
        .init(id: 0, name: "Built-in Output", isSystemOutput: true),
        .init(id: 1, name: "Built-in Output", isSystemOutput: false, uid: "builtin"),
        .init(id: 2, name: "AudioBox iTwo", isSystemOutput: false, uid: "audiobox")]
    var changed: (@MainActor @Sendable () -> Void)?
    func outputs() -> [AudioOutputDevice] { devices }
    func rates(for device: AudioOutputDevice) -> [Double] { [48_000] }
    func observe(_ changed: (@MainActor @Sendable () -> Void)?) { self.changed = changed }
}

extension OwnerChannelStripTests {
    func testRundeAInternalFadeCannotBeSelectedOrInstantiatedFromSavedInsert() throws {
        let raw = AudioUnitComponentDescription(componentType: 0x61756678, componentSubType: 0x50666465,
            componentManufacturer: 0x506c6e6d, name: "Planarium: Fade", manufacturerName: "Planarium", isSandboxSafe: true)
        XCTAssertTrue(AudioUnitEffectCatalog.candidates(from: [raw]).isEmpty)
        let source = SystemPluginSource()
        var rejected = false
        source.load(.init(componentType: raw.componentType, componentSubType: raw.componentSubType,
                          componentManufacturer: raw.componentManufacturer)) { result in
            if case .failure = result { rejected = true }
        }
        XCTAssertTrue(rejected)
    }
}

extension OwnerChannelStripTests {
    func testRundeAPerformStripRetainsNamedInstrumentAndTwoInsertStatesOffline() async throws {
        let fixture = try MonitorRootFixture(components: OwnerPlugins(fails: false, loading: false))
        defer { fixture.root.terminate {} }
        let owner = fixture.root.document
        var channel = owner.document.channels[0]
        channel.instrument = .init(identity: OwnerCatalog.instrument)
        channel.inserts = [
            .init(id: UUID(), plugin: .init(identity: OwnerCatalog.effect)),
            .init(id: UUID(), plugin: .init(identity: OwnerCatalog.effect), bypassed: true)
        ]
        owner.updateChannel(channel)
        for _ in 0..<100 { await Task.yield() }
        let catalog = AudioCatalogModel(document: owner, source: OwnerCatalog())
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for perform in [false, true] {
            owner.canvas.setPerformanceLocked(perform)
            for labels in [false, true] {
                let view = ChannelStripView(spatialInstrument: owner, audioUnits: catalog, host: fixture.root.audio,
                    midiOutput: fixture.root.midi, audioDevices: .init(host: fixture.root.audio), compact: perform)
                XCTAssertEqual(view.selectedInstrument?.name, "UADx Opal Morphing Synth")
                XCTAssertEqual(view.slots.prefix(2).map(\.isOn), [true, false])
                let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).environment(\.fieldToolbarLabels, labels))
                for width: CGFloat in [360, 840] {
                    host.frame = .init(x: 0, y: 0, width: width, height: 900)
                    host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 30_000_000)
                    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to:
                        directory.appendingPathComponent("runde-a-strip-\(perform ? "perform" : "edit")-\(labels ? "labels" : "icons")-\(Int(width)).png"))
                }
            }
        }
    }
}

extension OwnerChannelStripTests {
    func testChannelPresetReloadRestoresLivePluginStateAndUndoKeepsUnsavedKnobChanges() async throws {
        let plugins = ChannelPresetStatePlugins(), fixture = try MonitorRootFixture(components: plugins)
        let owner = fixture.root.document
        defer { fixture.root.terminate {} }
        var channel = owner.document.channels[0]
        channel.instrument = .init(identity: OwnerCatalog.instrument, state: Data([1]))
        owner.updateChannel(channel)
        func expectState(_ state: Data) async throws {
            for _ in 0..<500 {
                if plugins.unit.state == state { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(plugins.unit.state, state)
        }
        try await expectState(Data([1]))
        let preset = ChannelPreset(name: "Same state", channel: owner.document.channels[0])
        let revision = owner.document.revision
        plugins.unit.state = Data([9]) // external editor change, absent from the document
        XCTAssertTrue(try owner.loadChannelPreset(preset, into: channel.id))
        try await expectState(Data([1]))
        XCTAssertEqual(owner.document.revision.counter, revision.counter + 1)
        XCTAssertEqual(owner.undoMenuTitle, "Undo: Load channel preset")
        XCTAssertTrue(owner.undo()); try await expectState(Data([9]))
        XCTAssertEqual(owner.document.channels[0].instrument?.state, Data([9]))
        XCTAssertTrue(owner.redo()); try await expectState(Data([1]))
    }
}

@MainActor private final class ChannelPresetStatePlugins: PluginComponentSource {
    let unit = ChannelPresetStateUnit()
    func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) { completion(.success(unit)) }
}
@MainActor private final class ChannelPresetStateUnit: PluginUnit {
    var state = Data()
    var audioNode: AVAudioUnit? { nil }
    func readState() throws -> Data { state }
    func setState(_ state: Data) throws { self.state = state }
    func setBypass(_ bypassed: Bool) {}
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary { OwnerSchedule() }
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void) { XCTFail("No real editor in offline test") }
}
