import AppKit
import SwiftUI
import XCTest
import PlanariumDomain
import PlanariumRuntime
@testable import SickPLSMonitor

@MainActor final class MIDIEffectEditorTests: XCTestCase {
    func testDocumentChannelEffectEditsUndoRedoAndPerformanceLock() throws {
        let fixture = try MonitorRootFixture(graph: MonitorGraph()), owner = fixture.root.document
        defer { fixture.root.terminate {} }
        let baseline = owner.document.channel
        var channel = baseline; channel.midiEffects = [.init()]
        owner.updateChannel(channel)
        XCTAssertEqual(owner.document.channel.midiEffects, channel.midiEffects)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.channel, baseline)
        XCTAssertTrue(owner.redo()); XCTAssertEqual(owner.document.channel.midiEffects, channel.midiEffects)
        owner.canvas.setPerformanceLocked(true)
        channel.midiEffects[0].bypassed = true; owner.updateChannel(channel)
        XCTAssertFalse(owner.document.channel.midiEffects[0].bypassed)
    }
    func testDelayedReorderBeforeAndAfterChannelDeletionAndPresetReplacement() throws {
        for replacement in [false, true] {
            for replyFirst in [false, true] {
                let fixture = try MonitorRootFixture(graph: MonitorGraph()), owner = fixture.root.document
                let layout = try LayoutWorkspaceFixture(fixture: fixture)
                defer { layout.cleanDefaults(); fixture.root.terminate {} }
                try owner.addChannel()
                var channel = owner.document.channels.last!
                let first = InstrumentMIDIEffect(), second = InstrumentMIDIEffect()
                channel.midiEffects = [first, second]; owner.updateChannel(channel)
                let strip = ChannelStripView(spatialInstrument: owner, audioUnits: layout.view.audioUnits,
                    host: fixture.root.audio, midiOutput: fixture.root.midi,
                    audioDevices: layout.view.audioDevices, stripID: channel.id)
                let reply = strip.midiEffectMoveAction
                if replyFirst {
                    reply(first.id, second.id)
                    XCTAssertEqual(owner.document.channels.last!.midiEffects, [second, first])
                }
                let preset = owner.document
                if replacement { try owner.applyPresetDocument(preset, restoringPluginStates: false) }
                else {
                    try owner.deleteChannel(channel.id)
                    reply(first.id, second.id)
                    XCTAssertFalse(owner.document.channels.contains { $0.id == channel.id })
                    XCTAssertTrue(owner.undo()) // Reuses both channel and slot IDs.
                }
                let before = owner.document
                reply(first.id, second.id)
                XCTAssertEqual(owner.document, before, "Stale reply after replacement=\(replacement), replyFirst=\(replyFirst)")
            }
        }
    }
    func testOfflineEditorsAndSlotsBroadAndNarrow() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SICK_B2A_IMAGES"] ?? NSTemporaryDirectory()).appendingPathComponent("b2a-images")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mode in ChordEffect.Mode.allCases {
            var chord = ChordEffect(); chord.mode = mode
            for width in [380, 640] {
                try render(ChordEffectEditor(effect: .constant(chord)), width: width, height: 560, name: "chord-\(mode.rawValue)-\(width).png", directory: directory)
            }
        }
        let fixture = try MonitorRootFixture(graph: MonitorGraph()), owner = fixture.root.document
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop(); fixture.root.terminate {} }
        var channel = owner.document.channel
        channel.midiEffects = [.init(), .init(bypassed: true)]
        owner.updateChannel(channel)
        for width in [900, 1728] {
            try render(layout.view, width: width, height: 960, name: "workspace-\(width).png", directory: directory)
        }
        for width in [144, 216] {
            try render(MixerView(instrument: owner, audioUnits: layout.view.audioUnits, host: fixture.root.audio,
                midi: fixture.root.midi, devices: layout.view.audioDevices), width: width, height: 920,
                name: "mixer-detail-\(width).png", directory: directory)
        }
        for slots in [[], [InstrumentMIDIEffect()], [InstrumentMIDIEffect(bypassed: true)], (0..<4).map { _ in InstrumentMIDIEffect() }] {
            for width in [72, 120] {
                try render(MIDIEffectSlotsView(slots: slots, add: {}, toggle: { _ in }, open: { _ in }, remove: { _ in }, move: { _, _ in }), width: width, height: 155,
                    name: "slots-\(slots.count)-\(slots.first?.bypassed == true)-\(width).png", directory: directory)
            }
        }
    }
    func testArpeggiatorRoundtripUndoAndOfflineImages() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SICK_B3A_IMAGES"] ?? NSTemporaryDirectory()).appendingPathComponent("b3a-images")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try MonitorRootFixture(graph: MonitorGraph()), owner = fixture.root.document
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop(); fixture.root.terminate {} }
        let baseline = owner.document.channel
        var channel = baseline
        var effect = ArpeggiatorEffect(); effect.octaves = 2; effect.gate = 60
        channel.midiEffects = [.init(), .init(arpeggiator: effect)]
        owner.updateChannel(channel)
        XCTAssertEqual(try JSONDecoder().decode(InstrumentChannel.self, from: JSONEncoder().encode(channel)), channel)
        XCTAssertTrue(owner.undo()); XCTAssertEqual(owner.document.channel, baseline)
        XCTAssertTrue(owner.redo()); XCTAssertEqual(owner.document.channel, channel)
        for velocity in [0, 100] {
            effect.velocity = velocity
            for width in [380, 680] {
                try render(ArpeggiatorEffectEditor(effect: .constant(effect)), width: width, height: 660,
                           name: "arpeggiator-\(velocity)-\(width).png", directory: directory)
            }
        }
        try render(MixerView(instrument: owner, audioUnits: layout.view.audioUnits, host: fixture.root.audio,
            midi: fixture.root.midi, devices: layout.view.audioDevices), width: 216, height: 920,
            name: "strip-chord-arpeggiator.png", directory: directory)
    }
    func testLiveHandDisplayPublishesOnlyToEffectEditorAndNeverToDocumentOrUndo() throws {
        let fixture = try MonitorRootFixture(graph: MonitorGraph()), owner = fixture.root.document
        defer { fixture.root.display.stop(); fixture.root.terminate {} }
        let baseline = owner.document
        let canUndo = owner.canUndo
        let slot = InstrumentMIDIEffect(arpeggiator: .init())
        var strip = baseline.channel; strip.midiEffects = [slot]
        let id = UUID(), cell = PolarDeviceLattice(ring: 100, sector: 180)!
        let target = SpatialRoutingTarget.midiEffectParameter(stripID: strip.id, slotID: slot.id, parameter: .gate)
        let layer = SpatialDocumentLayer(id: id, name: "Hand", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [cell],
            routings: [.init(target: target, program: .constant(1))], cellOverrides: [:])
        var doc = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id), detection: .allStagesOff, revision: .newSession())
        doc.channel = strip
        var state = PlayEngine.step(.init(), .install(try InstrumentCompiler.compile(doc))).0
        let session = UUID(), geometry = ProfileGeometryIdentity(operatingMode: "test", pointCount: 361, startAngleDegrees: -90, endAngleDegrees: 90)
        let frame = ProfileFrame(sessionID: session, sequence: 1, time: 10, measurements: [DeviceTickMeasurement(order: 180, ticks: geometry.tickSpan(at: 180)!, rawCentimeters: 100)!], geometry: geometry)
        state = PlayEngine.step(state, .frame(frame)).0
        XCTAssertFalse(state.arpeggiatorModulation.values.isEmpty)
        var documentPublications = 0, editorPublications = 0
        let a = owner.objectWillChange.sink { documentPublications += 1 }
        let b = owner.arpeggiatorModulationDisplay.objectWillChange.sink { editorPublications += 1 }
        let display = DisplayFrame(arpeggiatorModulation: state.arpeggiatorModulation, selection: state.selection)
        owner.noteDisplay(display); owner.noteDisplay(display)
        XCTAssertEqual(editorPublications, 1); XCTAssertEqual(documentPublications, 0)
        XCTAssertEqual(owner.document, baseline)
        XCTAssertEqual(owner.canUndo, canUndo)
        owner.noteDisplay(.init(selection: .init(activeHandles: [:], candidateDistancesCentimeters: [:])))
        XCTAssertEqual(editorPublications, 2); XCTAssertEqual(documentPublications, 0)
        XCTAssertTrue(owner.arpeggiatorModulationDisplay.value.values.isEmpty)
        withExtendedLifetime([a, b]) {}
    }
    func testHandTargetChoicesAndLiveEditorOfflineWideAndNarrow() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SICK_B3B_IMAGES"] ?? NSTemporaryDirectory()).appendingPathComponent("b3b-images")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try MonitorRootFixture(graph: MonitorGraph()), owner = fixture.root.document
        let layout = try LayoutWorkspaceFixture(fixture: fixture)
        defer { layout.cleanDefaults(); fixture.root.display.stop(); fixture.root.terminate {} }
        var channel = owner.document.channel
        channel.midiEffects = [.init(arpeggiator: .init())]; owner.updateChannel(channel)
        let slot = channel.midiEffects[0]
        let target = SpatialRoutingTarget.midiEffectParameter(stripID: channel.id, slotID: slot.id, parameter: .rate)
        owner.canvas.updateWorkspace { workspace in
            workspace.updateSelectedLayer { layer in
                layer.routings = [.init(target: target, program: .continuous(minimum: 1, maximum: 0, directionDegrees: 90, curve: .linear))]
            }
        }
        let baseline = owner.document
        for width in [380, 680] {
            try render(ArpeggiatorEffectEditor(effect: .constant(.init()), liveValues: [target: 5], stripID: channel.id, slotID: slot.id), width: width, height: 720,
                name: "live-editor-\(width).png", directory: directory)
            let live = Dictionary(uniqueKeysWithValues: ArpeggiatorModulationTarget.allCases.map { parameter -> (SpatialRoutingTarget, Double) in
                let value: Double
                switch parameter { case .rate: value = 5; case .octaves: value = 4; case .gate: value = 100; case .swing: value = 75; case .velocity: value = 127 }
                return (.midiEffectParameter(stripID: channel.id, slotID: slot.id, parameter: parameter), value)
            })
            try render(ArpeggiatorEffectEditor(effect: .constant(.init()), liveValues: live, stripID: channel.id, slotID: slot.id), width: width, height: 860,
                name: "live-editor-all-\(width).png", directory: directory)
            try render(VStack(alignment: .leading) {
                Text("MIDI FX").font(.headline)
                MIDIEffectTargetChoices(channels: [channel], apply: { _ in })
            }.padding(16), width: width, height: 240, name: "inspector-target-choices-\(width).png", directory: directory)
            try render(SpatialLayerInspectorView(editor: owner.canvas, audioUnits: layout.view.audioUnits, midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil),
                width: width, height: 780, name: "inspector-target-\(width).png", directory: directory)
        }
        XCTAssertEqual(owner.document, baseline)
        var missing = channel; missing.midiEffects = []; owner.updateChannel(missing)
        let unavailable = owner.document
        for width in [380, 680] {
            try render(SpatialLayerInspectorView(editor: owner.canvas, audioUnits: layout.view.audioUnits, midiOutput: fixture.root.midi, spatialInstrument: owner, evaluationCounter: nil),
                width: width, height: 780, name: "inspector-unavailable-\(width).png", directory: directory)
        }
        XCTAssertEqual(owner.document, unavailable)
    }
    private func render<V: View>(_ view: V, width: Int, height: Int, name: String, directory: URL) throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark).background(Color(white: 0.18)))
        host.appearance = NSAppearance(named: .darkAqua); host.wantsLayer = true
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}
