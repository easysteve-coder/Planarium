import XCTest
import PlanariumDomain
@testable import PlanariumPresets

final class MIDIEffectPresetTests: XCTestCase {
    func testHandTargetsRoundtripWithArpeggiator() throws {
        let initialID = UUID()
        let initial = SpatialDocumentLayer(id: initialID, name: "Hands", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])
        var document = InstrumentDocument(spatial: try .init(latticeVersion: .polarDeviceV2, layers: [initial], selectedLayerID: initialID), revision: .newSession())
        let slot = InstrumentMIDIEffect(arpeggiator: .init())
        document.channel.midiEffects = [slot]
        let id = UUID()
        let layer = SpatialDocumentLayer(id: id, name: "Hands", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [],
            routings: ArpeggiatorModulationTarget.allCases.map { .init(target: .midiEffectParameter(stripID: document.channel.id, slotID: slot.id, parameter: $0), program: .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear)) }, cellOverrides: [:])
        document.spatial = try .init(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
        let bytes = try PresetV6Codec.encode(.init(name: "Hands", document: document))
        let decoded = try PresetV6Codec.decode(bytes)
        XCTAssertEqual(decoded.document.spatial.layers[0].routings, layer.routings)
        XCTAssertEqual(try PresetV6Codec.encode(decoded), bytes)
    }
    func testV6AndChannelPresetRoundtripPreserveOrderBypassAndLearnedChords() throws {
        let id = UUID()
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [.init(id: id, name: "Test", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])], selectedLayerID: id)
        var document = InstrumentDocument(spatial: spatial, revision: .newSession())
        var learned = ChordEffect(); learned.mode = .multi; learned.multiNotes = [60: [48, 55], 62: [50, 57]]
        var arp = ArpeggiatorEffect(); arp.direction = .asPlayed; arp.rate = .eighthTriplet
        arp.octaves = 4; arp.gate = 83; arp.swing = 23; arp.velocity = 77; arp.syncToBeat = true
        document.channel.midiEffects = [.init(chord: learned), .init(arpeggiator: arp), .init(bypassed: true)]
        let preset = InstrumentPresetV6(name: "Chord", document: document)
        let bytes = try PresetV6Codec.encode(preset)
        let decoded = try PresetV6Codec.decode(bytes)
        XCTAssertEqual(decoded.document.channel.midiEffects, document.channel.midiEffects)
        XCTAssertEqual(try PresetV6Codec.encode(decoded), bytes)
        let channel = ChannelPreset(name: "Chord", channel: document.channel)
        let channelBytes = try ChannelPresetCodec.encode(channel)
        let restored = try ChannelPresetCodec.decode(channelBytes)
        XCTAssertEqual(restored, channel)
        XCTAssertEqual(restored.replacing(.init(id: UUID())).midiEffects, document.channel.midiEffects)
        document.channel.midiEffects = []
        let old = try PresetV6Codec.encode(.init(name: "Old", document: document))
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("midiEffects"))
        XCTAssertEqual(try PresetV6Codec.decode(old).document.channel.midiEffects, [])
    }
}
