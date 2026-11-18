import AVFoundation
import SwiftUI
import XCTest
import PlanariumAudio
import PlanariumDomain
import PlanariumRuntime
import PlanariumPresets
@testable import SickPLSMonitor

@MainActor final class ChannelMixerAuthoringTests: XCTestCase {
    func testPresetBarMixerPublicationDoesNotSerializeAUStateAndSaveKeepsEditorChanges() throws {
        let plugins = MixerAuthoringPlugins()
        let fixture = try MonitorRootFixture(components: plugins, graph: MonitorGraph())
        let owner = fixture.root.document
        let identity = SpatialAudioUnitIdentity(componentType: 0x61756D75, componentSubType: 1, componentManufacturer: 2)
        var document = owner.document
        document.channels = [.init(instrument: .init(identity: identity, state: Data([7])))]
        try owner.applyPresetDocument(document)
        let model = PresetControlModel(store: .init(directory: FileManager.default.temporaryDirectory.appendingPathComponent("BuehnePreset-\(UUID().uuidString)")), documentOwner: owner)
        owner.onWorkspaceChange = { [weak model] in model?.noteSpatialWorkspace($0) }
        let unit = try XCTUnwrap(plugins.units.first)
        model.draftName = "Stage"; XCTAssertTrue(model.save())
        let host = NSHostingView(rootView: PresetBarView(model: model, performanceOnly: true))
        host.frame = .init(x: 0, y: 0, width: 380, height: 100)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let reads = unit.reads
        for i in 1...5 {
            var channel = owner.document.channel; channel.levelDecibels = -Double(i)
            owner.updateChannel(channel)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(unit.reads, reads, "Production preset-bar publication must not read fullState")
        XCTAssertTrue(model.presentationIsDirty)
        unit.state = Data([97])
        XCTAssertTrue(model.isDirty, "Explicit load/termination checks still include live editor state")
        XCTAssertTrue(model.save())
        XCTAssertFalse(model.presentationIsDirty)
        let savedReads = unit.reads
        model.noteSpatialWorkspace(owner.canvas.workspace)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(unit.reads, savedReads, "Preset presentation stays cheap after saving live AU state")
        XCTAssertEqual(try owner.snapshotPresetDocument().channel.instrument?.state, Data([97]))
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(5)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }
    func testAudioSetupTimeoutRendersVisibleNoticeWideAndNarrowOffline() throws {
        let graph = MonitorGraph()
        graph.configurationFailure = PluginLoadError("Audio setup timed out. Please try again.")
        let fixture = try MonitorRootFixture(graph: graph)
        defer { fixture.root.terminate {} }
        let devices = AudioOutputDeviceControlModel(host: fixture.root.audio)
        XCTAssertEqual(devices.notice, "Audio setup timed out. Please try again.")
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [250, 380] {
            let host = NSHostingView(rootView: AudioOutputDeviceCardView(model: devices))
            host.frame = .init(x: 0, y: 0, width: width, height: 150)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("audio-timeout-\(width).png"))
        }
    }
    func testMixerChangesDoNotReadFullStateButSavingReadsLiveState() throws {
        let plugins = MixerAuthoringPlugins()
        let fixture = try MonitorRootFixture(components: plugins, graph: MonitorGraph())
        let owner = fixture.root.document
        let instrument = SpatialAudioUnitIdentity(componentType: 0x61756D75, componentSubType: 1, componentManufacturer: 2)
        var document = owner.document
        document.channels = [.init(instrument: .init(identity: instrument, state: Data([7])))]
        try owner.applyPresetDocument(document)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let unit = try XCTUnwrap(plugins.units.first)
        let reads = unit.reads
        for i in 1...5 {
            var channel = owner.document.channel
            channel.levelDecibels = -Double(i); channel.pan = Double(i) / 10
            channel.muted.toggle(); owner.updateChannel(channel)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(unit.reads, reads, "Mixer changes must not serialize fullState")
        unit.state = Data([97])
        XCTAssertEqual(try owner.snapshotPresetDocument().channel.instrument?.state, Data([97]))
        XCTAssertEqual(unit.reads, reads + 1)
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(5)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }
    func testDuplicateCopiesLivePluginStatesAndMixButNeverLayersAndDeleteUndoKeepsID() throws {
        let plugins = MixerAuthoringPlugins(), graph = MonitorGraph()
        let fixture = try MonitorRootFixture(components: plugins, graph: graph)
        let owner = fixture.root.document
        let instrument = SpatialAudioUnitIdentity(componentType: 0x61756D75, componentSubType: 1, componentManufacturer: 2)
        let effect = SpatialAudioUnitIdentity(componentType: 0x61756678, componentSubType: 3, componentManufacturer: 2)
        var document = owner.document
        document.channels = [.init(instrument: .init(identity: instrument, state: Data([7])),
            inserts: [.init(id: UUID(), plugin: .init(identity: effect, state: Data([8])), bypassed: true)],
            levelDecibels: -9, pan: 0.4, muted: true, name: "Pads", color: .orange)]
        try owner.applyPresetDocument(document)
        try XCTUnwrap(plugins.units.first { $0.identity == instrument }).state = Data([97])
        try XCTUnwrap(plugins.units.first { $0.identity == effect }).state = Data([98])
        let original = try XCTUnwrap(fixture.root.audio.instrument)
        let layers = owner.document.spatial
        try owner.duplicateChannel(InstrumentChannel.legacyID)
        let copy = try XCTUnwrap(owner.document.channels.last)
        XCTAssertNotEqual(copy.id, InstrumentChannel.legacyID)
        XCTAssertEqual(copy.instrument?.state, Data([97])); XCTAssertEqual(copy.inserts[0].plugin.state, Data([98]))
        XCTAssertNotEqual(copy.inserts[0].id, document.channel.inserts[0].id)
        XCTAssertTrue(copy.inserts[0].bypassed); XCTAssertTrue(copy.muted)
        XCTAssertEqual(copy.levelDecibels, -9); XCTAssertEqual(copy.pan, 0.4); XCTAssertEqual(copy.color, .orange)
        XCTAssertEqual(owner.document.spatial, layers)
        let child = try XCTUnwrap(fixture.root.audio.host(for: copy.id))
        XCTAssertFalse(try XCTUnwrap(child.instrument) === original)
        XCTAssertEqual(try child.snapshotChannel().instrument?.state, Data([97]))
        try owner.deleteChannel(copy.id)
        XCTAssertEqual(owner.document.channels.count, 1)
        owner.undo()
        XCTAssertEqual(owner.document.channels.last?.id, copy.id)
        XCTAssertEqual(owner.document.spatial, layers)
        while owner.document.channels.count < 8 { try owner.addChannel() }
        XCTAssertThrowsError(try owner.addChannel()) { XCTAssertEqual($0 as? CompiledInstrumentError, .tooManyChannels(9)) }
        XCTAssertThrowsError(try owner.duplicateChannel(copy.id))
        XCTAssertEqual(graph.starts, 0)
        var done = false; fixture.root.terminate { done = true }
        let deadline = Date().addingTimeInterval(10)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        XCTAssertTrue(done)
    }
}
@MainActor private final class MixerAuthoringPlugins: PluginComponentSource {
    var units: [MixerAuthoringUnit] = []
    func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) {
        let unit = MixerAuthoringUnit(identity: identity); units.append(unit); completion(.success(unit))
    }
}
@MainActor private final class MixerAuthoringUnit: PluginUnit {
    let identity: SpatialAudioUnitIdentity
    init(identity: SpatialAudioUnitIdentity) { self.identity = identity }
    var audioNode: AVAudioUnit? { nil }
    var state = Data()
    var reads = 0
    func readState() throws -> Data { reads += 1; return state }
    func setState(_ state: Data) throws { self.state = state }
    func setBypass(_ bypassed: Bool) {}
    func scheduleBoundary(identity: SpatialAudioUnitIdentity) -> any AUScheduleBoundary { MixerAuthoringSchedule() }
    func requestEditor(_ completion: @escaping @MainActor @Sendable (any PluginEditor) -> Void) { XCTFail("No real editor in authoring test") }
}
private struct MixerAuthoringSchedule: AUScheduleBoundary {
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult { .sent }
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult { .sent }
}
