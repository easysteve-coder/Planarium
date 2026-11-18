import Foundation
import PlanariumDomain

/// Legacy v4 read record, retained for lossless imports.
public struct InstrumentPresetV4: Equatable, Codable {
    public static let formatVersion = 4

    public var name: String
    public var zones: [InstrumentPreset.ZoneRecord]
    public var assignment: InstrumentPreset.AssignmentRecord
    public var layers: [InstrumentPreset.LayerStackRecord]
    public var gate: InstrumentPreset.GateRecord
    public var mapping: InstrumentPreset.MappingRecord
    public var timbre: InstrumentPreset.TimbreRecord
    public var masterGain: Float
    public var delay: InstrumentPreset.DelayRecord
    public var reverb: InstrumentPreset.ReverbRecord
    public var prediction: InstrumentPreset.PredictionRecord
    public var audioUnits: InstrumentPreset.AudioUnitRackRecord
    public var midi: InstrumentPreset.MIDIRecord
    public var viewport: InstrumentPreset.ViewportRecord
    public var instrumentChannel: InstrumentChannelSettings?
    public var spatialDocument: SpatialDocument?

    public init(
        name: String,
        zones: [InstrumentPreset.ZoneRecord],
        assignment: InstrumentPreset.AssignmentRecord,
        layers: [InstrumentPreset.LayerStackRecord] = [],
        gate: InstrumentPreset.GateRecord,
        mapping: InstrumentPreset.MappingRecord,
        timbre: InstrumentPreset.TimbreRecord,
        masterGain: Float,
        delay: InstrumentPreset.DelayRecord,
        reverb: InstrumentPreset.ReverbRecord,
        prediction: InstrumentPreset.PredictionRecord,
        audioUnits: InstrumentPreset.AudioUnitRackRecord,
        midi: InstrumentPreset.MIDIRecord,
        viewport: InstrumentPreset.ViewportRecord,
        spatialDocument: SpatialDocument? = nil, instrumentChannel: InstrumentChannelSettings? = nil
    ) {
        self.name = name
        self.zones = zones
        self.assignment = assignment
        self.layers = layers
        self.gate = gate
        self.mapping = mapping
        self.timbre = timbre
        self.masterGain = masterGain
        self.delay = delay
        self.reverb = reverb
        self.prediction = prediction
        self.audioUnits = audioUnits
        self.midi = midi
        self.viewport = viewport
        self.spatialDocument = spatialDocument
        self.instrumentChannel = instrumentChannel
    }

    internal init(settingsOf preset: InstrumentPreset, spatialDocument: SpatialDocument?) {
        self.init(
            name: preset.name,
            zones: preset.zones,
            assignment: preset.assignment,
            layers: preset.layers,
            gate: preset.gate,
            mapping: preset.mapping,
            timbre: preset.timbre,
            masterGain: preset.masterGain,
            delay: preset.delay,
            reverb: preset.reverb,
            prediction: preset.prediction,
            audioUnits: preset.audioUnits,
            midi: preset.midi,
            viewport: preset.viewport,
            spatialDocument: spatialDocument, instrumentChannel: preset.instrumentChannel
        )
    }

    public var legacySettings: InstrumentPreset {
        InstrumentPreset(name: name, zones: zones, assignment: assignment, layers: layers,
            gate: gate, mapping: mapping, timbre: timbre, masterGain: masterGain,
            delay: delay, reverb: reverb, prediction: prediction, audioUnits: audioUnits,
            midi: midi, viewport: viewport, instrumentChannel: instrumentChannel)
    }
    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, zones, assignment, layers, gate, mapping,
             timbre, masterGain, delay, reverb, prediction, audioUnits, midi,
             viewport, spatialDocument, spatialWorkspace, instrumentChannel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.spatialWorkspace) {
            throw PresetDocumentReadError.legacySpatialField
        }
        let version = try values.decode(Int.self, forKey: .formatVersion)
        guard version == Self.formatVersion else {
            throw PresetDocumentReadError.unsupportedVersion(version)
        }
        name = try values.decode(String.self, forKey: .name)
        zones = try values.decode([InstrumentPreset.ZoneRecord].self, forKey: .zones)
        assignment = try values.decode(InstrumentPreset.AssignmentRecord.self, forKey: .assignment)
        layers = try values.decode([InstrumentPreset.LayerStackRecord].self, forKey: .layers)
        gate = try values.decode(InstrumentPreset.GateRecord.self, forKey: .gate)
        mapping = try values.decode(InstrumentPreset.MappingRecord.self, forKey: .mapping)
        timbre = try values.decode(InstrumentPreset.TimbreRecord.self, forKey: .timbre)
        masterGain = try values.decode(Float.self, forKey: .masterGain)
        delay = try values.decode(InstrumentPreset.DelayRecord.self, forKey: .delay)
        reverb = try values.decode(InstrumentPreset.ReverbRecord.self, forKey: .reverb)
        prediction = try values.decode(InstrumentPreset.PredictionRecord.self, forKey: .prediction)
        audioUnits = try values.decode(InstrumentPreset.AudioUnitRackRecord.self, forKey: .audioUnits)
        midi = try values.decode(InstrumentPreset.MIDIRecord.self, forKey: .midi)
        viewport = try values.decode(InstrumentPreset.ViewportRecord.self, forKey: .viewport)
        instrumentChannel = try values.decodeIfPresent(InstrumentChannelSettings.self, forKey: .instrumentChannel)
        if values.contains(.spatialDocument) {
            spatialDocument = try values.decode(SpatialDocument.self, forKey: .spatialDocument)
        } else {
            spatialDocument = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.formatVersion, forKey: .formatVersion)
        try values.encode(name, forKey: .name)
        try values.encode(zones, forKey: .zones)
        try values.encode(assignment, forKey: .assignment)
        try values.encode(layers, forKey: .layers)
        try values.encode(gate, forKey: .gate)
        try values.encode(mapping, forKey: .mapping)
        try values.encode(timbre, forKey: .timbre)
        try values.encode(masterGain, forKey: .masterGain)
        try values.encode(delay, forKey: .delay)
        try values.encode(reverb, forKey: .reverb)
        try values.encode(prediction, forKey: .prediction)
        try values.encode(audioUnits, forKey: .audioUnits)
        try values.encode(midi, forKey: .midi)
        try values.encode(viewport, forKey: .viewport)
        try values.encodeIfPresent(instrumentChannel, forKey: .instrumentChannel)
        if let spatialDocument {
            guard spatialDocument.latticeVersion == .polarDeviceV2 else {
                throw PresetDocumentReadError.unsupportedLatticeVersion(spatialDocument.latticeVersion)
            }
            try values.encode(spatialDocument, forKey: .spatialDocument)
        }
    }
}
