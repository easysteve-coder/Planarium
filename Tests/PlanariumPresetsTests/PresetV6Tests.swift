import XCTest
import AVFoundation
import PlanariumDomain
@testable import PlanariumAudio
import PlanariumRuntime
@testable import PlanariumPresets

final class PresetV6Tests: XCTestCase {
    func testEditorGridIsRejectedWhileDecodingDocumentAndBothPresetVersions() throws {
        let document = try FactoryPresetDocument.empty()
        let documentBytes = try JSONEncoder().encode(document)
        for meters in [0.07, 0.005, 0.29, 1e100] {
            var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: documentBytes) as? [String: Any])
            wire["editorGrid"] = ["cellSizeMeters": meters]
            XCTAssertThrowsError(try JSONDecoder().decode(InstrumentDocument.self,
                from: JSONSerialization.data(withJSONObject: wire)))
            for bytes in [try PresetV5Codec.encode(.init(name: "Grid", document: document)),
                          try PresetV6Codec.encode(.init(name: "Grid", document: document))] {
                var preset = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                var nested = try XCTUnwrap(preset["document"] as? [String: Any])
                nested["editorGrid"] = wire["editorGrid"]; preset["document"] = nested
                let invalid = try JSONSerialization.data(withJSONObject: preset)
                if preset["formatVersion"] as? Int == 5 {
                    XCTAssertThrowsError(try JSONDecoder().decode(InstrumentPresetV5.self, from: invalid))
                } else { XCTAssertThrowsError(try JSONDecoder().decode(InstrumentPresetV6.self, from: invalid)) }
                XCTAssertThrowsError(try PresetDocumentReader.read(invalid).get())
            }
        }
        for size in MetricSquareGrid.CellSize.allCases {
            var valid = document; valid.editorGrid = size.grid
            XCTAssertEqual(try JSONDecoder().decode(InstrumentDocument.self, from: JSONEncoder().encode(valid)), valid)
            for bytes in [try PresetV5Codec.encode(.init(name: "Grid", document: valid)),
                          try PresetV6Codec.encode(.init(name: "Grid", document: valid))] {
                XCTAssertEqual(try PresetDocumentReader.read(bytes).get().replacing(valid).editorGrid, size.grid)
            }
        }
    }
    func testSingleNoteAndScaleToggleLoadNoticeThroughPresetReader() throws {
        for program: SpatialValueProgram in [
            .singleNote(note: 61, velocity: 83, transition: .toggle),
            .scale(rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84, scale: .major,
                   directionDegrees: 90, ascending: true, transition: .toggle),
            .randomScale(rootMIDINote: 60, lowestMIDINote: 48, highestMIDINote: 84, scale: .major,
                         seed: 123, transition: .toggle)
        ] {
            var document = try FactoryPresetDocument.empty()
            let layer = SpatialDocumentLayer(id: UUID(), name: "Notes", color: .orange, isVisible: true,
                isActive: true, isLocked: false, isSoloed: false, cells: [],
                routings: [.init(target: .midiNote(channel: 0), program: program)], cellOverrides: [:])
            document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
            let bytes = try PresetV6Codec.encode(.init(name: "Single", document: document))
            let reading = try PresetDocumentReader.read(bytes).get()
            XCTAssertEqual(try reading.replacing(document).spatial.layers[0].routings[0].program, program.replacingUnsupportedToggle)
            XCTAssertEqual(reading.loadNotice != nil, !program.supportsToggle)
            if !program.supportsToggle { XCTAssertEqual(reading.loadNotice, "Scale / Random scale: Toggle changed to Retrigger.") }
            let legacy = try PresetDocumentReader.read(PresetV5Codec.encode(.init(name: "Legacy", document: document))).get()
            XCTAssertEqual(legacy.loadNotice != nil, !program.supportsToggle)
            XCTAssertEqual(try legacy.replacing(document).spatial.layers[0].routings[0].program, program.replacingUnsupportedToggle)
        }
    }
    func testAllAUTargetsRequireConcreteIdsAndAbsentWireIdsStayMissingExceptLegacyDecode() throws {
        let id = UUID()
        let targets: [SpatialRoutingTarget] = [.audioUnitNote(channel: 2, stripID: id), .audioUnitAllNotesOff(channel: 3, stripID: id),
            .audioUnitParameter(.init(component: .init(componentType: 1, componentSubType: 2, componentManufacturer: 3), address: 42,
                                     identifier: "gain", displayName: "Gain", stripID: id))]
        for target in targets {
            let bytes = try JSONEncoder().encode(target)
            XCTAssertEqual(try JSONDecoder().decode(SpatialRoutingTarget.self, from: bytes), target)
            for null in [false, true] {
                var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let key = try XCTUnwrap(root.keys.first)
                var payload = try XCTUnwrap(root[key] as? [String: Any])
                if key == "audioUnitParameter" {
                    var parameter = try XCTUnwrap(payload["_0"] as? [String: Any])
                    parameter["stripID"] = null ? NSNull() : nil; payload["_0"] = parameter
                } else { payload["stripID"] = null ? NSNull() : nil }
                root[key] = payload
                XCTAssertEqual(try JSONDecoder().decode(SpatialRoutingTarget.self, from: JSONSerialization.data(withJSONObject: root)).stripID, LegacyChannelMigration.missingID)
            }
        }
        var document = try v5Document()
        let old = document.spatial.layers[0]
        let layer = SpatialDocumentLayer(id: old.id, name: old.name, color: old.color,
            isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: old.cells,
            routings: targets.map { .init(target: $0, program: .constant(1)) }, cellOverrides: old.cellOverrides)
        document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: old.id)
        let legacy = try PresetV5Codec.decode(PresetV5Codec.encode(.init(name: "Legacy targets", document: document)))
        XCTAssertTrue(legacy.document.spatial.layers[0].routings.allSatisfy { $0.target.stripID == InstrumentChannel.legacyID })
        let modern = try PresetDocumentReader.read(PresetV6Codec.encode(.init(name: "Modern targets", document: document))).get().replacing(document)
        XCTAssertEqual(modern.spatial.layers[0].routings.map(\.target), targets)
    }
    func testAllStripsMasterOpaqueStatesAndSummaryRoundTripAndTemplatePreservesMixer() throws {
        var document = try v5Document()
        let second = UUID()
        var duplicate = document.channel; duplicate.id = second; duplicate.name = "Lead"
        duplicate.inserts = duplicate.inserts.map { .init(id: UUID(), plugin: $0.plugin, bypassed: $0.bypassed) }
        document.channels.append(duplicate); document.masterLevelDecibels = 6
        let data = try PresetV6Codec.encode(.init(name: "Two", document: document, summary: "Pads and lead"))
        let reading = try PresetDocumentReader.read(data).get()
        XCTAssertEqual(reading.sourceVersion, 6); XCTAssertEqual(reading.summary, "Pads and lead")
        XCTAssertEqual(try reading.replacing(FactoryPresetDocument.empty()), document)
        XCTAssertEqual(try PresetV6Codec.encode(.init(name: reading.name, document: reading.replacing(document), summary: reading.summary)), data)
        let template = try PresetDocumentReader.read(PresetV6Codec.encode(.init(name: "Template", document: document, includesChannel: false))).get()
        XCTAssertEqual(try template.replacing(document).channels, document.channels)
        XCTAssertEqual(try template.replacing(document).masterLevelDecibels, 6)
    }
    func testV6SummaryBudgetIsEnforcedByCodecReaderAndDirectCodable() throws {
        var preset = InstrumentPresetV6(name: "Summary", document: try FactoryPresetDocument.empty(), summary: String(repeating: "👩‍🎤", count: 1000))
        let good = try PresetV6Codec.encode(preset)
        XCTAssertEqual(try PresetDocumentReader.read(good).get().summary.count, 1000)
        XCTAssertEqual(try JSONDecoder().decode(InstrumentPresetV6.self, from: good), preset)
        preset.summary += "x"
        XCTAssertThrowsError(try PresetV6Codec.encode(preset)) { XCTAssertEqual($0 as? PresetDocumentReadError, .summaryTooLong) }
        XCTAssertThrowsError(try JSONEncoder().encode(preset))
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        wire["summary"] = preset.summary
        let bad = try JSONSerialization.data(withJSONObject: wire)
        XCTAssertThrowsError(try JSONDecoder().decode(InstrumentPresetV6.self, from: bad))
        XCTAssertThrowsError(try PresetDocumentReader.read(bad).get()) { XCTAssertEqual($0 as? PresetDocumentReadError, .summaryTooLong) }
    }
    func testEveryLegacyAUActionAndOverrideBindsToChOneAndCommandsAreUnchanged() throws {
        let old = try v5Document(), new = try LegacyChannelMigration.applying(to: old)
        XCTAssertEqual(new.channels.count, 1); XCTAssertEqual(new.channel.name, "Ch 1")
        for layer in new.spatial.layers {
            for target in layer.routings.map(\.target) + layer.cellOverrides.values.flatMap({ $0 }).map(\.target) where target.destination == .audioUnit {
                XCTAssertEqual(target.stripID, new.channel.id)
            }
        }
        let before = try InstrumentCompiler.compile(old), after = try InstrumentCompiler.compile(new)
        func canonical(_ commands: [SpatialOutputCommand]) -> [SpatialOutputCommand] {
            commands.map { command in
                switch command {
                case .scalar(let id, let target, let value): return .scalar(routingID: id, target: target.withStripID(new.channel.id), value: value)
                case .boolean(let id, let target, let value): return .boolean(routingID: id, target: target.withStripID(new.channel.id), value: value)
                default: return command
                }
            }
        }
        for cell in old.spatial.layers[0].cells {
            let a = before.hits(tick: cell.sector, raw: cell.ring), b = after.hits(tick: cell.sector, raw: cell.ring)
            var x = SpatialNoteLedger(), y = SpatialNoteLedger()
            XCTAssertEqual(canonical(x.apply(try before.evaluate(active: Dictionary(uniqueKeysWithValues: a.map { ($0.layerID, $0) })))),
                           canonical(y.apply(try after.evaluate(active: Dictionary(uniqueKeysWithValues: b.map { ($0.layerID, $0) })))))
        }
    }
    func testRejectsMalformedMixerAndNineChannelsWithoutMarkerEcho() throws {
        var document = try FactoryPresetDocument.empty()
        document.channels = (0..<9).map { _ in .init(id: UUID()) }
        XCTAssertThrowsError(try PresetV6Codec.encode(.init(name: "Nine", document: document))) { XCTAssertEqual($0 as? CompiledInstrumentError, .tooManyChannels(9)) }
        let bytes = try PresetV6Codec.encode(.init(name: "Valid", document: FactoryPresetDocument.empty()))
        for value in [NSNull(), "INVENTED-KZ-MARKER", [[:]]] as [Any] {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var wire = try XCTUnwrap(root["document"] as? [String: Any]); wire["channels"] = value; root["document"] = wire
            guard case .failure(let error) = PresetDocumentReader.read(try JSONSerialization.data(withJSONObject: root)) else { return XCTFail("Malformed mixer accepted") }
            XCTAssertFalse(String(describing: error).contains("INVENTED-KZ-MARKER"))
        }
    }
    func testV6AbsentTargetIDIsMissingAndReorderOrDeletionNeverRemapsExistingIDs() throws {
        var document = try v5Document()
        document = try LegacyChannelMigration.applying(to: document)
        let second = UUID()
        document.channels.append(.init(id: second, name: "Lead"))
        let bytes = try PresetV6Codec.encode(.init(name: "Two", document: document))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var wire = try XCTUnwrap(root["document"] as? [String: Any])
        var spatial = try XCTUnwrap(wire["spatial"] as? [String: Any])
        var layers = try XCTUnwrap(spatial["layers"] as? [[String: Any]])
        var routes = try XCTUnwrap(layers[0]["routings"] as? [[String: Any]])
        var target = try XCTUnwrap(routes[0]["target"] as? [String: Any])
        var note = try XCTUnwrap(target["audioUnitNote"] as? [String: Any])
        note.removeValue(forKey: "stripID"); target["audioUnitNote"] = note; routes[0]["target"] = target
        layers[0]["routings"] = routes; spatial["layers"] = layers; wire["spatial"] = spatial; root["document"] = wire
        let absent = try PresetDocumentReader.read(JSONSerialization.data(withJSONObject: root)).get().replacing(document)
        XCTAssertEqual(absent.spatial.layers[0].routings[0].target.stripID, LegacyChannelMigration.missingID)
        let compiled = try InstrumentCompiler.compile(absent), layer = absent.spatial.layers[0]
        let cell = try XCTUnwrap(layer.cells.first), hit = try XCTUnwrap(compiled.hits(tick: cell.sector, raw: cell.ring).first { $0.layerID == layer.id })
        XCTAssertEqual(try compiled.evaluate(active: [layer.id: hit]).first { $0.routingID == layer.routings[0].id }?.value, .inactive)
        document.channels.reverse()
        let reordered = try PresetDocumentReader.read(PresetV6Codec.encode(.init(name: "Reordered", document: document))).get().replacing(document)
        XCTAssertEqual(reordered.spatial.layers[0].routings[0].target.stripID, InstrumentChannel.legacyID)
        document.channels.removeAll { $0.id == InstrumentChannel.legacyID }
        let removed = try PresetDocumentReader.read(PresetV6Codec.encode(.init(name: "Removed", document: document))).get().replacing(document)
        XCTAssertEqual(removed.spatial.layers[0].routings[0].target.stripID, InstrumentChannel.legacyID)
        XCTAssertEqual(removed.channels.map(\.id), [second])
    }
    @MainActor func testFrozenV5FactoryRendersBitIdenticalBeforeAndAfterMigration() throws {
        let data = try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/v5-factory-audio.json"))
        let old = try PresetV5Codec.decode(data).document
        var legacy = old
        legacy.channel.instrument = try FactoryPresetDocument.empty().channel.instrument
        let migrated = try PresetDocumentReader.read(PresetV6Codec.encode(.init(name: "Frozen V5 factory",
            document: LegacyChannelMigration.applying(to: legacy)))).get().replacing(legacy)
        let a = try InstrumentCompiler.compile(legacy), b = try InstrumentCompiler.compile(migrated)
        for layer in legacy.spatial.layers where !layer.cells.isEmpty {
            for cell in layer.cells.sorted(by: { ($0.ring, $0.sector) < ($1.ring, $1.sector) }).prefix(8) {
                var beforeLedger = SpatialNoteLedger(), afterLedger = SpatialNoteLedger()
                let beforeHits = a.hits(tick: cell.sector, raw: cell.ring), afterHits = b.hits(tick: cell.sector, raw: cell.ring)
                let beforeCommands = beforeLedger.apply(try a.evaluate(active: Dictionary(uniqueKeysWithValues: beforeHits.map { ($0.layerID, $0) })))
                let afterCommands = afterLedger.apply(try b.evaluate(active: Dictionary(uniqueKeysWithValues: afterHits.map { ($0.layerID, $0) })))
                XCTAssertEqual(beforeCommands, afterCommands, "Frozen V5 factory output commands must be identical")
                XCTAssertEqual(beforeLedger.releaseAll(), afterLedger.releaseAll())
            }
        }
        let before = try render(legacy), after = try render(migrated)
        XCTAssertTrue(before.contains { $0 != 0 }, "The bit oracle must contain sounding audio")
        XCTAssertEqual(before, after)
        print("KANALZÜGE-1 V5→V6 offline: \(before.count) Float bit patterns identical")
    }
    @MainActor private func render(_ document: InstrumentDocument) throws -> [UInt32] {
        let runtime = PerformanceRuntime(clock: MonotonicRuntimeClock(), mailbox: DisplayFrameMailbox())
        let graph = AVAudioGraph()
        let host = try AudioHost(components: SystemPluginSource(), graph: graph,
            runtime: PerformanceAudioPort(runtime: runtime), windows: AppKitPluginWindows(), configuration: .init(offline: true))
        defer {
            var done = false; host.shutdown { done = true }
            let deadline = Date().addingTimeInterval(10)
            while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
            XCTAssertTrue(done)
        }
        try host.applyMixer(document.channels, masterLevelDecibels: document.masterLevelDecibels)
        let deadline = Date().addingTimeInterval(30)
        while host.status[.instrument] == .loading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(host.status[.instrument], .loaded)
        let compiled = try InstrumentCompiler.compile(document)
        let layer = try XCTUnwrap(document.spatial.layers.first { !$0.cells.isEmpty && !$0.routings.isEmpty })
        let cell = try XCTUnwrap(layer.cells.sorted { ($0.ring, $0.sector) < ($1.ring, $1.sector) }.first)
        let hits = compiled.hits(tick: cell.sector, raw: cell.ring)
        var ledger = SpatialNoteLedger()
        let commands = ledger.apply(try compiled.evaluate(active: Dictionary(uniqueKeysWithValues: hits.map { ($0.layerID, $0) })))
        let schedule = try XCTUnwrap(host.instrument?.scheduleBoundary())
        try host.start()
        for case .noteOn(_, let channel, let note) in commands { XCTAssertEqual(schedule.scheduleMIDI(bytes: [0x90 | channel, note.number, note.velocity]), .sent) }
        var bits: [UInt32] = []
        for _ in 0..<32 {
            let buffer = try graph.renderOffline()
            let samples = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<Int(buffer.format.channelCount) {
                bits += UnsafeBufferPointer(start: samples[channel], count: Int(buffer.frameLength)).map(\.bitPattern)
            }
        }
        for case .noteOff(_, let channel, let note) in ledger.releaseAll() { _ = schedule.scheduleMIDI(bytes: [0x80 | channel, note.number, 0]) }
        return bits
    }
}

extension PresetV6Tests {
    func testChannelPresetRoundtripBlobOrderBypassVersionAndOptionalMix() throws {
        let identity = SpatialAudioUnitIdentity(componentType: 0x61756d75, componentSubType: 123, componentManufacturer: 456)
        let plugin = InstrumentPlugin(identity: identity, state: Data([0, 255, 12, 34, 0]))
        let source = InstrumentChannel(instrument: plugin, inserts: [
            .init(id: UUID(), plugin: plugin, bypassed: true), .init(id: UUID(), plugin: plugin)],
            levelDecibels: -9, pan: 0.4, id: UUID(), name: "Source")
        let preset = ChannelPreset(name: "Offline test", channel: source, includesLevelAndPan: false)
        let data = try ChannelPresetCodec.encode(preset)
        XCTAssertEqual(try ChannelPresetCodec.decode(data), preset)
        XCTAssertEqual(try ChannelPresetCodec.encode(ChannelPresetCodec.decode(data)), data)
        let target = InstrumentChannel(levelDecibels: -3, pan: -0.2, muted: true, id: UUID(), name: "Destination")
        let loaded = preset.replacing(target)
        XCTAssertEqual(loaded.id, target.id); XCTAssertEqual(loaded.name, target.name)
        XCTAssertEqual(loaded.levelDecibels, -3); XCTAssertEqual(loaded.pan, -0.2); XCTAssertTrue(loaded.muted)
        XCTAssertEqual(loaded.instrument, plugin); XCTAssertEqual(loaded.inserts, source.inserts)
        var invalid = preset; invalid.formatVersion = 2
        XCTAssertThrowsError(try ChannelPresetCodec.encode(invalid))
        XCTAssertThrowsError(try ChannelPresetCodec.decode(JSONEncoder().encode(invalid)))
    }
}


extension PresetV6Tests {
    func testChannelPresetV1FixtureRetainsPluginBlobsAndOrder() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/channel-preset-v1.json")
        let value = try ChannelPresetCodec.decode(Data(contentsOf: url))
        XCTAssertEqual(value.channel.instrument?.state, Data([9, 10]))
        XCTAssertEqual(value.channel.inserts.map { $0.plugin.state }, [Data([11]), Data([12])])
        XCTAssertEqual(value.channel.inserts.map(\.bypassed), [true, false])
        XCTAssertEqual(try ChannelPresetCodec.decode(ChannelPresetCodec.encode(value)), value)
    }
}

extension PresetV6Tests {
    func testPreparedSendsRoundtripBothPresetFormatsLegacyDefaultAndValidation() throws {
        var document = try FactoryPresetDocument.empty()
        let old = try JSONEncoder().encode(document.channels[0])
        let legacy = try JSONDecoder().decode(InstrumentChannel.self, from: old)
        XCTAssertEqual(legacy.sendALevelDecibels, -120); XCTAssertEqual(legacy.sendBLevelDecibels, -120)
        document.channels[0].sendALevelDecibels = -9.5
        document.channels[0].sendBLevelDecibels = -120
        let full = try PresetV6Codec.decode(PresetV6Codec.encode(.init(name: "Prepared sends", document: document))).document
        XCTAssertEqual(full.channels, document.channels)
        let channel = ChannelPreset(name: "Prepared sends", channel: document.channels[0])
        XCTAssertEqual(try ChannelPresetCodec.decode(ChannelPresetCodec.encode(channel)), channel)
        document.channels[0].sendBLevelDecibels = 7
        XCTAssertThrowsError(try InstrumentCompiler.compile(document))
        document.channels[0].sendBLevelDecibels = -121
        XCTAssertThrowsError(try InstrumentCompiler.compile(document))
    }
}
