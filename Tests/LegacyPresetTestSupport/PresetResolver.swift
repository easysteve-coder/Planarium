@testable import PlanariumPresets
import Foundation
import SickPLSControlCore
import SickPLSMonitorKit
import PlanariumDomain

/// Ein Preset, **vollständig in geprüfte Domänenwerte** übersetzt. Erst
/// wenn dieser Wert existiert, wird irgendetwas angewandt -- das ist die
/// Atomarität: kein Teilzustand aus einem halb gültigen Preset.
public struct ResolvedPreset: Equatable, Sendable {
    public let name: String
    public let zones: [EditableZone]
    public let master: MasterLevel
    public let delay: DelayInsert
    public let reverb: ReverbInsert
    public let prediction: ControlValuePredictorConfiguration
    public let rack: EffectRackSelection
    public let bypassed: Set<AudioUnitIdentity>
    public let midi: MIDIOutputConfiguration
    public let viewport: ScanPlaneViewport
    public var spatialWorkspace: SpatialInstrumentWorkspace? = nil
    public let instrumentChannel: InstrumentChannelSettings

    public init(
        name: String, zones: [EditableZone],
        master: MasterLevel, delay: DelayInsert, reverb: ReverbInsert,
        prediction: ControlValuePredictorConfiguration, rack: EffectRackSelection,
        bypassed: Set<AudioUnitIdentity>, midi: MIDIOutputConfiguration,
        viewport: ScanPlaneViewport, spatialWorkspace: SpatialInstrumentWorkspace? = nil,
        instrumentChannel: InstrumentChannelSettings = .primary
    ) {
        self.name = name; self.zones = zones
        self.master = master; self.delay = delay; self.reverb = reverb
        self.prediction = prediction; self.rack = rack; self.bypassed = bypassed
        self.midi = midi; self.viewport = viewport; self.spatialWorkspace = spatialWorkspace
        self.instrumentChannel = instrumentChannel
    }
}

/// Warum ein Preset nicht anwendbar ist. Nennt Abschnitt und Grund.
public enum PresetResolutionError: Error, Equatable {
    case invalidZone(index: Int, reason: String)
    case unknownRole(String)
    case unknownShapeKind(String)
    case invalidShape(index: Int, reason: String)
    /// Die Zuordnung nennt eine Zonen-ID, die im Preset nicht vorkommt,
    /// oder die Zone hat eine andere Rolle.
    case invalidMaster(String)
    case invalidDelay(String)
    case invalidReverb(String)
    case invalidPrediction(String)
    case invalidAudioUnit(index: Int, reason: String)
    case invalidRack(String)
    case invalidMIDI(String)
    case invalidViewport(String)
    case unknownEnumValue(field: String, value: String)
}

/// Die Übersetzung Format → Domäne (und zurück). Reine Funktionen.
public enum PresetResolver {

    // MARK: - Format → Domäne

    public static func resolve(_ preset: InstrumentPreset) throws -> ResolvedPreset {
        let zones = try preset.zones.enumerated().map { index, record -> EditableZone in
            let role = try role(from: record.role)
            let zone: Zone
            do {
                zone = try Zone.build(
                    indexLowerBound: record.indexLowerBound, indexUpperBound: record.indexUpperBound,
                    valueLowerBound: UInt16(clamping: max(record.valueLowerBound, 0)),
                    valueUpperBound: UInt16(clamping: max(record.valueUpperBound, 0)),
                    role: role
                )
            } catch {
                throw PresetResolutionError.invalidZone(index: index, reason: String(describing: error))
            }
            let shape = try shape(from: record.shape, index: index)
            if role == .gate, shape != .strip {
                throw PresetResolutionError.invalidShape(index: index, reason: "Ein Gate ist stets ein Streifen")
            }
            return EditableZone(id: record.id, zone: zone, isEnabled: record.isEnabled, shape: shape)
        }

        let master: MasterLevel
        do { master = try MasterLevel.build(gain: preset.masterGain) } catch {
            throw PresetResolutionError.invalidMaster(String(describing: error))
        }

        let delay: DelayInsert
        do {
            delay = try DelayInsert.build(
                isEnabled: preset.delay.isEnabled, sendLevel: preset.delay.sendLevel,
                timeSeconds: preset.delay.timeSeconds, feedbackPercent: preset.delay.feedbackPercent
            )
        } catch {
            throw PresetResolutionError.invalidDelay(String(describing: error))
        }

        let reverb: ReverbInsert
        do {
            guard let character = ReverbCharacter(rawValue: preset.reverb.character) else {
                throw PresetResolutionError.unknownEnumValue(field: "reverb.character", value: preset.reverb.character)
            }
            reverb = try ReverbInsert.build(isEnabled: preset.reverb.isEnabled, sendLevel: preset.reverb.sendLevel, character: character)
        } catch let error as PresetResolutionError {
            throw error
        } catch {
            throw PresetResolutionError.invalidReverb(String(describing: error))
        }

        let prediction: ControlValuePredictorConfiguration
        do {
            prediction = try ControlValuePredictorConfiguration.build(
                alpha: preset.prediction.alpha, beta: preset.prediction.beta,
                predictionHorizonSeconds: preset.prediction.predictionHorizonSeconds,
                staleTimeoutSeconds: preset.prediction.staleTimeoutSeconds,
                outlierThreshold: preset.prediction.outlierThreshold
            )
        } catch {
            throw PresetResolutionError.invalidPrediction(String(describing: error))
        }

        var identities: [AudioUnitIdentity] = []
        var bypassed: Set<AudioUnitIdentity> = []
        for (index, record) in preset.audioUnits.entries.enumerated() {
            do {
                let identity = try AudioUnitIdentity.build(
                    componentType: record.componentType, componentSubType: record.componentSubType,
                    componentManufacturer: record.componentManufacturer
                )
                identities.append(identity)
                if record.isBypassed { bypassed.insert(identity) }
            } catch {
                throw PresetResolutionError.invalidAudioUnit(index: index, reason: String(describing: error))
            }
        }
        let rack: EffectRackSelection
        do { rack = try EffectRackSelection.build(entries: identities) } catch {
            throw PresetResolutionError.invalidRack(String(describing: error))
        }

        let midi: MIDIOutputConfiguration
        do {
            let domain = try PitchDomain.build(rootNote: preset.midi.rootNote, spanSemitones: preset.midi.spanSemitones)
            midi = try MIDIOutputConfiguration.build(
                channel: preset.midi.channel, bendRangeSemitones: preset.midi.bendRangeSemitones,
                pitchDomain: domain, pitchInverted: preset.midi.pitchInverted,
                volumeController: preset.midi.volumeController, filterController: preset.midi.filterController,
                effectSendController: preset.midi.effectSendController
            )
        } catch {
            throw PresetResolutionError.invalidMIDI(String(describing: error))
        }

        let viewport: ScanPlaneViewport
        do {
            viewport = try ScanPlaneViewport.build(
                centerX: preset.viewport.centerX, centerY: preset.viewport.centerY, halfExtent: preset.viewport.halfExtent
            )
        } catch {
            throw PresetResolutionError.invalidViewport(String(describing: error))
        }

        return ResolvedPreset(
            name: preset.name, zones: zones, master: master, delay: delay, reverb: reverb, prediction: prediction,
            rack: rack, bypassed: bypassed, midi: midi, viewport: viewport,
            spatialWorkspace: preset.spatialWorkspace, instrumentChannel: preset.instrumentChannel ?? .primary
        )
    }

    // MARK: - Domäne → Format

    public static func record(from resolved: ResolvedPreset) -> InstrumentPreset {
        InstrumentPreset(
            name: resolved.name,
            zones: resolved.zones.map { zone in
                InstrumentPreset.ZoneRecord(
                    id: zone.id,
                    indexLowerBound: zone.zone.indexRange.lowerBound, indexUpperBound: zone.zone.indexRange.upperBound,
                    valueLowerBound: Int(zone.zone.valueRange.lowerBound), valueUpperBound: Int(zone.zone.valueRange.upperBound),
                    role: name(of: zone.zone.role), isEnabled: zone.isEnabled, shape: record(from: zone.shape)
                )
            },
            masterGain: resolved.master.gain,
            delay: InstrumentPreset.DelayRecord(
                isEnabled: resolved.delay.isEnabled, sendLevel: resolved.delay.sendLevel,
                timeSeconds: resolved.delay.timeSeconds, feedbackPercent: resolved.delay.feedbackPercent
            ),
            reverb: InstrumentPreset.ReverbRecord(
                isEnabled: resolved.reverb.isEnabled, sendLevel: resolved.reverb.sendLevel, character: resolved.reverb.character.rawValue
            ),
            prediction: InstrumentPreset.PredictionRecord(
                alpha: resolved.prediction.alpha, beta: resolved.prediction.beta,
                predictionHorizonSeconds: resolved.prediction.predictionHorizonSeconds,
                staleTimeoutSeconds: resolved.prediction.staleTimeoutSeconds, outlierThreshold: resolved.prediction.outlierThreshold
            ),
            audioUnits: InstrumentPreset.AudioUnitRackRecord(entries: resolved.rack.entries.map { identity in
                InstrumentPreset.AudioUnitRecord(
                    componentType: identity.componentType, componentSubType: identity.componentSubType,
                    componentManufacturer: identity.componentManufacturer, isBypassed: resolved.bypassed.contains(identity)
                )
            }),
            midi: InstrumentPreset.MIDIRecord(
                channel: resolved.midi.channel, bendRangeSemitones: resolved.midi.bendRangeSemitones,
                rootNote: resolved.midi.pitchDomain.rootNote, spanSemitones: resolved.midi.pitchDomain.spanSemitones,
                pitchInverted: resolved.midi.pitchInverted, volumeController: resolved.midi.volumeController,
                filterController: resolved.midi.filterController, effectSendController: resolved.midi.effectSendController
            ),
            viewport: InstrumentPreset.ViewportRecord(
                centerX: resolved.viewport.centerX, centerY: resolved.viewport.centerY, halfExtent: resolved.viewport.halfExtent
            ),
            spatialWorkspace: resolved.spatialWorkspace, instrumentChannel: resolved.instrumentChannel
        )
    }

    // MARK: - Teilübersetzungen

    static func name(of role: ZoneRole) -> String {
        switch role {
        case .pitch: return "pitch"
        case .volume: return "volume"
        case .filter: return "filter"
        case .gate: return "gate"
        case .effectSend: return "effectSend"
        }
    }

    static func role(from text: String) throws -> ZoneRole {
        for role in ZoneRole.allCases where name(of: role) == text { return role }
        throw PresetResolutionError.unknownRole(text)
    }

    static func record(from shape: FieldShape) -> InstrumentPreset.ShapeRecord {
        switch shape {
        case .strip:
            return .strip
        case .grid(let cells):
            return InstrumentPreset.ShapeRecord(kind: "grid", columns: cells.columns, rows: cells.rows, values: cells.values, range: cells.range)
        case .fan(let cells):
            return InstrumentPreset.ShapeRecord(kind: "fan", values: cells.values, range: cells.range)
        case .key(let cells):
            return InstrumentPreset.ShapeRecord(
                kind: "key", scale: cells.scale.rawValue, octaves: cells.octaves, rootOffset: cells.rootOffset, spanSemitones: cells.spanSemitones
            )
        }
    }

    static func shape(from record: InstrumentPreset.ShapeRecord, index: Int) throws -> FieldShape {
        guard let kind = FieldShapeKind(rawValue: record.kind) else {
            throw PresetResolutionError.unknownShapeKind(record.kind)
        }
        do {
            switch kind {
            case .strip:
                return .strip
            case .grid:
                guard let columns = record.columns, let rows = record.rows, let values = record.values, let range = record.range else {
                    throw PresetResolutionError.invalidShape(index: index, reason: "Raster ohne Spalten/Zeilen/Werte/Bereich")
                }
                return .grid(try GridCells.build(columns: columns, rows: rows, values: values, range: range))
            case .fan:
                guard let values = record.values, let range = record.range else {
                    throw PresetResolutionError.invalidShape(index: index, reason: "Fächer ohne Werte/Bereich")
                }
                return .fan(try FanCells.build(values: values, range: range))
            case .key:
                guard let scaleName = record.scale, let octaves = record.octaves else {
                    throw PresetResolutionError.invalidShape(index: index, reason: "Tonartfeld ohne Tonart/Oktaven")
                }
                guard let scale = MusicalScale(rawValue: scaleName) else {
                    throw PresetResolutionError.unknownEnumValue(field: "shape.scale", value: scaleName)
                }
                return .key(try KeyCells.build(
                    scale: scale, octaves: octaves, rootOffset: record.rootOffset ?? 0,
                    spanSemitones: record.spanSemitones ?? KeyCells.standardSpanSemitones
                ))
            }
        } catch let error as PresetResolutionError {
            throw error
        } catch {
            throw PresetResolutionError.invalidShape(index: index, reason: String(describing: error))
        }
    }

}
