import AppKit
import SwiftUI
import XCTest
import PlanariumDomain
import PlanariumAudio
import PlanariumApplication
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class StudioMaterialsTests: XCTestCase {
    func testNativeEmergencyPressChangesCapAndReleasesWithoutSecondAction() throws {
        let surface = EmergencyFirstMouseView()
        var states: [Bool] = [], actions = 0
        surface.pressed = { states.append($0) }; surface.action = { actions += 1 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        surface.mouseDown(with: event)
        XCTAssertEqual(states, [true]); XCTAssertEqual(actions, 1)
        surface.mouseUp(with: event)
        XCTAssertEqual(states, [true, false]); XCTAssertEqual(actions, 1)
        XCTAssertTrue(surface.acceptsFirstMouse(for: event))
        surface.enabled = false; surface.mouseDown(with: event)
        XCTAssertEqual(actions, 1); XCTAssertEqual(states, [true, false])
    }

    func testTexturesAreCachedPerMaterialAndScale() throws {
        for scale: CGFloat in [1, 2] {
            for metal in [StudioMaterials.Metal.darkMetal, .lightAluminium] {
                let first = try XCTUnwrap(StudioTextureCache.image(metal, scale: scale))
                let count = StudioTextureCache.generations
                for _ in 0..<20 {
                    XCTAssertTrue(first === StudioTextureCache.image(metal, scale: scale))
                }
                XCTAssertEqual(StudioTextureCache.generations, count)
                XCTAssertEqual(first.width, Int(128 * scale))
                XCTAssertEqual(first.height, Int(64 * scale))
            }
        }
    }

    func testAluminiumLabelRolesPassGuardianAtBothGradientEnds() {
        func rgb(_ color: Color) -> [Double] {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            return [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
        }
        for (ink, background) in [(Color.white, HelmutChrome.purple), (.white, HelmutChrome.blue),
            (.white, StudioMaterials.midiBypass), (StudioMaterials.inkOnLight, HelmutChrome.midiFX),
            (.white, StudioMaterials.displayGlass)] {
            XCTAssertGreaterThanOrEqual(LayoutGuardian.contrast(rgb(ink), rgb(background)), 4.5)
        }
        for ink in [StudioMaterials.inkOnLight, StudioMaterials.secondaryInk] {
            for background in [StudioMaterials.aluminiumTop, StudioMaterials.aluminiumBottom, StudioMaterials.aluminiumMinimum] {
                for label in ["SUM", "channel number", "Send A", "Send B", "MIDI FX", "fader scale", "MIDI notice"] {
                    let role = LayoutGuardian.Element(name: label, frame: CGRect(x: 0, y: 0, width: 72, height: 20),
                        container: CGRect(x: 0, y: 0, width: 72, height: 20), control: false,
                        font: Double(StudioMaterials.labelSize), foreground: rgb(ink), background: rgb(background))
                    XCTAssertTrue(LayoutGuardian.violations([role], view: "aluminium").isEmpty, label)
                }
            }
        }
    }

    func testPanicGreenAndTransportStopRedInInactiveOfflineHosting() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let devices = AudioOutputDeviceControlModel(host: fixture.root.audio, startAudio: {})
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".agent_handoff/runs/panik-gruen")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func pixels(_ bitmap: NSBitmapImageRep, green: Bool) -> Int {
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if green ? (c.greenComponent > c.redComponent * 2 && c.greenComponent > c.blueComponent * 1.5 && c.greenComponent > 0.2)
                        : (c.redComponent > c.greenComponent * 2 && c.redComponent > c.blueComponent * 2 && c.redComponent > 0.3) { count += 1 }
                }
            }
            return count
        }
        for width in [72, 144] {
            for pressed in [false, true] {
                let bitmap = try render(SumChannelView(devices: devices, instrument: fixture.root.document,
                    host: fixture.root.audio, midi: fixture.root.midi), width: width, height: 784,
                    name: "sum-\(pressed ? "pressed" : "normal")-\(width)", directory: directory, pressed: pressed)
                XCTAssertGreaterThan(pixels(bitmap, green: true), 100, "Production PANIC must remain green in an inactive host")
                XCTAssertLessThan(pixels(bitmap, green: false), 50, "Production PANIC must no longer be red")
            }
        }
        fixture.root.document.startClockTransport()
        XCTAssertTrue(fixture.root.document.clockTransportPlaying)
        for width in [360, 720] {
            let bitmap = try render(TempoHeaderView(instrument: fixture.root.document), width: width, height: 70,
                name: "transport-playing-\(width)", directory: directory)
            XCTAssertGreaterThan(pixels(bitmap, green: false), 100, "Transport Stop keeps its red cap")
        }
        fixture.root.document.stopClockTransport()
        for color in [StudioPanicCap.panicColors.normal, StudioPanicCap.panicColors.pressed] {
            let c = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            XCTAssertGreaterThanOrEqual(LayoutGuardian.contrast([1, 1, 1],
                [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]), 4.5)
        }
    }

    func testPilotImages() throws {
        let fixture = try MonitorRootFixture()
        defer { fixture.root.terminate {} }
        let devices = AudioOutputDeviceControlModel(host: fixture.root.audio, startAudio: {})
        let phase = ProcessInfo.processInfo.environment["STUDIO_IMAGE_PHASE"] ?? "after"
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".agent_handoff/runs/gestaltung-pilot/\(phase)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let instrument = AudioUnitInstrumentCandidate(identity: try XCTUnwrap(.init(componentSubType: 1, componentManufacturer: 1)),
            name: "AU Instrument", manufacturerName: "Offline", isSandboxSafe: true)
        let effect = try AudioUnitIdentity.build(componentType: AudioUnitIdentity.effectComponentType, componentSubType: 2, componentManufacturer: 1)
        for width in [72, 144] {
            for state in ["normal", "mute", "solo", "bypass", "locked", "error", "compact", "output"] {
                var chord = InstrumentMIDIEffect(); chord.bypassed = state == "bypass"
                let strip = HelmutStripSurface(master: .constant(0.7), selectedEntry: .constant(.audioOutput),
                    audioIsRunning: true, audioSummary: "Offline", midiSummary: "Offline",
                    effectSlots: [.init(id: 1, title: "Insert", isOn: state != "bypass", canToggle: true, target: .audioUnit(effect))],
                    audioUnitEffects: [], audioUnitInstruments: [instrument], selectedAudioUnitInstrument: state == "error" ? nil : instrument,
                    isMuted: state == "mute", isSoloed: state == "solo", toggleMute: {}, toggleSolo: {},
                    instrumentIsOn: state != "bypass", instrumentPreparation: .empty, instrumentCanToggle: true,
                    toggleInstrument: {}, selectAudioUnitInstrument: { _ in }, openAudioUnitInstrument: { _ in },
                    assignEffect: { _, _ in }, toggleEffect: { _ in }, openEffect: { _ in },
                    outputLeftPeak: { 0.3 }, outputRightPeak: { 0.15 }, channelName: .constant("PLANARIUM"),
                    channelColor: .constant(.blue), pan: 0, setPan: { _ in }, midiDestinations: [],
                    selectedMIDIDestinationID: nil, selectMIDIDestination: { _ in }, refreshMIDIDestinations: {},
                    midiNotice: nil, audioDevices: devices, compact: state == "compact", performanceLocked: state == "locked",
                    instrumentUnavailable: state == "error",
                    midiEffectsView: state == "output" ? AnyView(EmptyView()) : AnyView(MIDIEffectSlotsView(slots: [chord], locked: state == "locked",
                        add: {}, toggle: { _ in }, open: { _ in }, remove: { _ in }, move: { _, _ in })))
                try render(strip, width: width, height: 760, name: "strip-\(state)-\(width)", directory: directory)
            }
            for pressed in [false, true] {
                try render(SumChannelView(devices: devices, instrument: fixture.root.document, host: fixture.root.audio, midi: fixture.root.midi),
                    width: width, height: 784, name: "sum-\(pressed ? "pressed" : "normal")-\(width)", directory: directory, pressed: pressed)
            }
            if phase == "after" {
                XCTAssertNotEqual(try Data(contentsOf: directory.appendingPathComponent("sum-normal-\(width).png")),
                    try Data(contentsOf: directory.appendingPathComponent("sum-pressed-\(width).png")),
                    "The production SUM must visibly respond to the native emergency mouse-down")
            }
        }
    }

    @discardableResult private func render<V: View>(_ view: V, width: Int, height: Int, name: String, directory: URL, pressed: Bool = false) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        host.layoutSubtreeIfNeeded()
        func surfaces(_ view: NSView) -> [EmergencyFirstMouseView] {
            (view as? EmergencyFirstMouseView).map { [$0] } ?? view.subviews.flatMap(surfaces)
        }
        if pressed {
            let surface = try XCTUnwrap(surfaces(host).first)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            surface.mouseDown(with: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.04)); host.layoutSubtreeIfNeeded()
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        return bitmap
    }
}
