import Foundation
import PlanariumDomain

/// Das **statische** Instrumentpreset (SICK-037): Zonen/Felder,
/// Zuordnung, Gate, Übersetzung, Klang, Master, Inserts, Prognose,
/// AU-Auswahl samt Bypass, MIDI-Einstellungen und Ausschnitt -- als
/// versioniertes, reines Datenformat.
///
/// **Kein Automationszustand** (Owner-Entscheidung 23.09.2026), **kein
/// Passwort, kein Rohtelegramm, kein MIDI-Ziel** (gerätespezifisch) und
/// kein Lebenszyklus: Ein Preset beschreibt Einstellungen, nie, ob etwas
/// läuft.
///
/// Die Felder sind bewusst **schlichte Werte** (Zahlen, Strings, UUIDs)
/// und keine Domänentypen. Dies ist ausschließlich das Altformat v1–v3;
/// PresetDocumentReader importiert seine heute relevanten Werte atomar.
public struct InstrumentPreset: Codable, Equatable {
    /// Die letzte Version dieses Altformats. Ältere Versionen werden über
    /// ``PresetMigrations`` angehoben; neuere werden abgelehnt.
    public static let currentFormatVersion = 3

    public var formatVersion: Int
    public var name: String
    public var zones: [ZoneRecord]
    public var assignment: AssignmentRecord
    public var layers: [LayerStackRecord]
    public var gate: GateRecord
    public var mapping: MappingRecord
    public var timbre: TimbreRecord
    public var masterGain: Float
    public var delay: DelayRecord
    public var reverb: ReverbRecord
    public var prediction: PredictionRecord
    public var audioUnits: AudioUnitRackRecord
    public var midi: MIDIRecord
    public var viewport: ViewportRecord
    public var spatialWorkspace: SpatialInstrumentWorkspace?
    public var instrumentChannel: InstrumentChannelSettings?

    public init(
        formatVersion: Int = InstrumentPreset.currentFormatVersion,
        name: String,
        zones: [ZoneRecord],
        assignment: AssignmentRecord = .init(),
        layers: [LayerStackRecord] = [],
        gate: GateRecord = .init(threshold: 0.5, polarity: "aboveThreshold"),
        mapping: MappingRecord = .init(pitchLowestHz: 55, pitchHighestHz: 1760, pitchPolarity: "normal", filterLowestHz: 200, filterHighestHz: 12000, filterPolarity: "normal", maximumAmplitude: 0.8, volumeCurve: "quadratic", volumePolarity: "normal", effectSendPolarity: "normal"),
        timbre: TimbreRecord = .init(morph: 0, filterResonance: 0, attackSeconds: 0.01, decaySeconds: 0.1, sustainLevel: 0.8, releaseSeconds: 0.1),
        masterGain: Float,
        delay: DelayRecord,
        reverb: ReverbRecord,
        prediction: PredictionRecord,
        audioUnits: AudioUnitRackRecord,
        midi: MIDIRecord,
        viewport: ViewportRecord,
        spatialWorkspace: SpatialInstrumentWorkspace? = nil,
        instrumentChannel: InstrumentChannelSettings? = .primary
    ) {
        self.formatVersion = formatVersion
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
        self.spatialWorkspace = spatialWorkspace
        self.instrumentChannel = instrumentChannel
    }

    public struct ShapeRecord: Codable, Equatable, Sendable {
        /// `strip`, `grid`, `fan`, `key`.
        public var kind: String
        public var columns: Int?
        public var rows: Int?
        public var values: [Int]?
        public var range: Int?
        public var scale: String?
        public var octaves: Int?
        public var rootOffset: Int?
        public var spanSemitones: Int?

        public init(kind: String, columns: Int? = nil, rows: Int? = nil, values: [Int]? = nil, range: Int? = nil,
                    scale: String? = nil, octaves: Int? = nil, rootOffset: Int? = nil, spanSemitones: Int? = nil) {
            self.kind = kind
            self.columns = columns
            self.rows = rows
            self.values = values
            self.range = range
            self.scale = scale
            self.octaves = octaves
            self.rootOffset = rootOffset
            self.spanSemitones = spanSemitones
        }

        public static let strip = ShapeRecord(kind: "strip")
    }

    public struct ZoneRecord: Codable, Equatable {
        public var id: UUID
        public var indexLowerBound: Double
        public var indexUpperBound: Double
        public var valueLowerBound: Int
        public var valueUpperBound: Int
        /// `pitch`, `volume`, `filter`, `gate`, `effectSend`.
        public var role: String
        public var isEnabled: Bool
        public var shape: ShapeRecord

        public init(id: UUID, indexLowerBound: Double, indexUpperBound: Double, valueLowerBound: Int, valueUpperBound: Int,
                    role: String, isEnabled: Bool, shape: ShapeRecord) {
            self.id = id
            self.indexLowerBound = indexLowerBound
            self.indexUpperBound = indexUpperBound
            self.valueLowerBound = valueLowerBound
            self.valueUpperBound = valueUpperBound
            self.role = role
            self.isEnabled = isEnabled
            self.shape = shape
        }
    }

    public struct AssignmentRecord: Codable, Equatable {
        public var pitch: UUID?
        public var volume: UUID?
        public var filter: UUID?
        public var effectSend: UUID?
        public var gate: UUID?

        public init(pitch: UUID? = nil, volume: UUID? = nil, filter: UUID? = nil, effectSend: UUID? = nil, gate: UUID? = nil) {
            self.pitch = pitch
            self.volume = volume
            self.filter = filter
            self.effectSend = effectSend
            self.gate = gate
        }
    }

    public struct LayerStackRecord: Codable, Equatable, Sendable {
        /// `pitch`, `volume`, `filter`, `effectSend`, `gate`.
        public var role: String
        /// `continuous`, `discrete`, `gate`.
        public var targetKind: String
        public var zoneIDs: [UUID]
        /// `firstActive`, `maximum`, `minimum`.
        public var mixRule: String

        public init(role: String, targetKind: String, zoneIDs: [UUID], mixRule: String) {
            self.role = role
            self.targetKind = targetKind
            self.zoneIDs = zoneIDs
            self.mixRule = mixRule
        }
    }

    public struct GateRecord: Codable, Equatable {
        public var threshold: Double
        /// `aboveThreshold` oder `belowThreshold`.
        public var polarity: String

        public init(threshold: Double, polarity: String) {
            self.threshold = threshold
            self.polarity = polarity
        }
    }

    public struct MappingRecord: Codable, Equatable {
        public var pitchLowestHz: Double
        public var pitchHighestHz: Double
        public var pitchPolarity: String
        public var filterLowestHz: Double
        public var filterHighestHz: Double
        public var filterPolarity: String
        public var maximumAmplitude: Double
        public var volumeCurve: String
        public var volumePolarity: String
        public var effectSendPolarity: String

        public init(pitchLowestHz: Double, pitchHighestHz: Double, pitchPolarity: String, filterLowestHz: Double,
                    filterHighestHz: Double, filterPolarity: String, maximumAmplitude: Double, volumeCurve: String,
                    volumePolarity: String, effectSendPolarity: String) {
            self.pitchLowestHz = pitchLowestHz
            self.pitchHighestHz = pitchHighestHz
            self.pitchPolarity = pitchPolarity
            self.filterLowestHz = filterLowestHz
            self.filterHighestHz = filterHighestHz
            self.filterPolarity = filterPolarity
            self.maximumAmplitude = maximumAmplitude
            self.volumeCurve = volumeCurve
            self.volumePolarity = volumePolarity
            self.effectSendPolarity = effectSendPolarity
        }
    }

    public struct TimbreRecord: Codable, Equatable {
        public var morph: Float
        public var filterResonance: Float
        public var attackSeconds: Float
        public var decaySeconds: Float
        public var sustainLevel: Float
        public var releaseSeconds: Float

        public init(morph: Float, filterResonance: Float, attackSeconds: Float, decaySeconds: Float, sustainLevel: Float, releaseSeconds: Float) {
            self.morph = morph
            self.filterResonance = filterResonance
            self.attackSeconds = attackSeconds
            self.decaySeconds = decaySeconds
            self.sustainLevel = sustainLevel
            self.releaseSeconds = releaseSeconds
        }
    }

    public struct DelayRecord: Codable, Equatable {
        public var isEnabled: Bool
        public var sendLevel: Double
        public var timeSeconds: Float
        public var feedbackPercent: Float

        public init(isEnabled: Bool, sendLevel: Double, timeSeconds: Float, feedbackPercent: Float) {
            self.isEnabled = isEnabled
            self.sendLevel = sendLevel
            self.timeSeconds = timeSeconds
            self.feedbackPercent = feedbackPercent
        }
    }

    public struct ReverbRecord: Codable, Equatable {
        public var isEnabled: Bool
        public var sendLevel: Double
        public var character: String

        public init(isEnabled: Bool, sendLevel: Double, character: String) {
            self.isEnabled = isEnabled
            self.sendLevel = sendLevel
            self.character = character
        }
    }

    public struct PredictionRecord: Codable, Equatable {
        public var alpha: Double
        public var beta: Double
        public var predictionHorizonSeconds: Double
        public var staleTimeoutSeconds: Double
        public var outlierThreshold: Double

        public init(alpha: Double, beta: Double, predictionHorizonSeconds: Double, staleTimeoutSeconds: Double, outlierThreshold: Double) {
            self.alpha = alpha
            self.beta = beta
            self.predictionHorizonSeconds = predictionHorizonSeconds
            self.staleTimeoutSeconds = staleTimeoutSeconds
            self.outlierThreshold = outlierThreshold
        }
    }

    public struct AudioUnitRecord: Codable, Equatable {
        public var componentType: UInt32
        public var componentSubType: UInt32
        public var componentManufacturer: UInt32
        public var isBypassed: Bool

        public init(componentType: UInt32, componentSubType: UInt32, componentManufacturer: UInt32, isBypassed: Bool) {
            self.componentType = componentType
            self.componentSubType = componentSubType
            self.componentManufacturer = componentManufacturer
            self.isBypassed = isBypassed
        }
    }

    public struct AudioUnitRackRecord: Codable, Equatable {
        public var entries: [AudioUnitRecord]

        public init(entries: [AudioUnitRecord]) {
            self.entries = entries
        }
    }

    public struct MIDIRecord: Codable, Equatable {
        public var channel: Int
        public var bendRangeSemitones: Int
        public var rootNote: Int
        public var spanSemitones: Int
        public var pitchInverted: Bool
        public var volumeController: Int
        public var filterController: Int
        public var effectSendController: Int

        public init(channel: Int, bendRangeSemitones: Int, rootNote: Int, spanSemitones: Int, pitchInverted: Bool,
                    volumeController: Int, filterController: Int, effectSendController: Int) {
            self.channel = channel
            self.bendRangeSemitones = bendRangeSemitones
            self.rootNote = rootNote
            self.spanSemitones = spanSemitones
            self.pitchInverted = pitchInverted
            self.volumeController = volumeController
            self.filterController = filterController
            self.effectSendController = effectSendController
        }
    }

    public struct ViewportRecord: Codable, Equatable {
        public var centerX: Double
        public var centerY: Double
        public var halfExtent: Double

        public init(centerX: Double, centerY: Double, halfExtent: Double) {
            self.centerX = centerX
            self.centerY = centerY
            self.halfExtent = halfExtent
        }
    }
}

/// Fehler beim Lesen eines Presets -- jeder benannt; ein Preset, das
/// hier scheitert, verändert **nichts**.
public enum PresetFormatError: Error, Equatable {
    case notAJSONObject
    case missingFormatVersion
    /// Version unter der ersten unterstützten.
    case unsupportedVersion(Int)
    /// Version über der aktuellen -- geschrieben von einer neueren App.
    case newerThanSupported(Int)
    /// Eine Migrationsstufe hat kein gültiges Objekt geliefert.
    case migrationProducedInvalidObject(fromVersion: Int)
    case decodingFailed(String)
}

/// Das **Migrationsgerüst** (SICK-037a): Stufen `n → n+1` als reine
/// JSON-Umformungen, in Versionsreihenfolge angewandt. Die
/// Produktionstabelle ist heute leer -- es gibt kein älteres
/// Produktionsformat --, das Gerüst ist trotzdem der eine Weg, auf dem
/// künftige Formate laufen, und wird mit einer synthetischen Stufe
/// geprüft.
public struct PresetMigrations {
    public typealias Step = ([String: Any]) throws -> [String: Any]

    /// Stufe je Ausgangsversion: `steps[1]` hebt Version 1 auf 2.
    public let steps: [Int: Step]
    /// Die erste Version, die überhaupt gelesen wird.
    public let earliestSupportedVersion: Int

    public init(steps: [Int: Step], earliestSupportedVersion: Int) {
        self.steps = steps
        self.earliestSupportedVersion = earliestSupportedVersion
    }

    /// Version 1 kannte je Rolle genau eine Zuweisung. Die Migration
    /// überführt diese verlustfrei in je einen geordneten Ebenenstack.
    public static var production: PresetMigrations {
        PresetMigrations(steps: [1: { object in
            var next = object
            let assignment = object["assignment"] as? [String: Any] ?? [:]
            let zones = object["zones"] as? [[String: Any]] ?? []
            let roles = ["pitch", "volume", "filter", "effectSend", "gate"]
            next["layers"] = roles.map { role -> [String: Any] in
                let id = assignment[role] as? String
                let shapeKind = zones.first { ($0["id"] as? String) == id }
                    .flatMap { $0["shape"] as? [String: Any] }?["kind"] as? String
                let targetKind = role == "gate" ? "gate" : (shapeKind == nil || shapeKind == "strip" ? "continuous" : "discrete")
                return [
                    "role": role,
                    "targetKind": targetKind,
                    "zoneIDs": id.map { [$0] } ?? [],
                    "mixRule": "firstActive"
                ]
            }
            next["formatVersion"] = 2
            return next
        }, 2: { object in
            var next = object
            // Version 2 bleibt vollständig gültig. Das neue räumliche
            // Instrument ist optional und beginnt bei alten Presets leer.
            next["formatVersion"] = 3
            return next
        }], earliestSupportedVersion: 1)
    }
}

/// Interne Normalisierung der Altversionen. Produktdateien schreibt nur v5.
enum PresetCodec {
    public static let formatVersionKey = "formatVersion"

    /// Stabil sortierte, lesbare JSON-Ausgabe.


    /// Liest, migriert falls nötig und decodiert. Ein Fehler an
    /// irgendeiner Stelle ist ein Fehler des Ganzen.


    /// Applies only the numbered JSON migrations up to an explicit target.
    /// The target is explicit so importers can normalize legacy settings to
    /// v3 without coupling that path to the later v4 record.
    internal static func migrate(
        _ json: [String: Any],
        from version: Int,
        migrations: PresetMigrations = .production,
        targetVersion: Int
    ) throws -> [String: Any] {
        guard version >= migrations.earliestSupportedVersion else {
            throw PresetFormatError.unsupportedVersion(version)
        }
        guard version <= targetVersion else {
            throw PresetFormatError.newerThanSupported(version)
        }

        var current = version
        var migrated = json
        while current < targetVersion {
            guard let step = migrations.steps[current] else {
                throw PresetFormatError.unsupportedVersion(version)
            }
            migrated = try step(migrated)
            guard migrated[formatVersionKey] as? Int == current + 1 else {
                throw PresetFormatError.migrationProducedInvalidObject(fromVersion: current)
            }
            current += 1
        }
        return migrated
    }

    internal static func migrate(
        _ json: [String: Any],
        from version: Int,
        migrations: PresetMigrations = .production
    ) throws -> [String: Any] {
        try migrate(json, from: version, migrations: migrations,
                    targetVersion: InstrumentPreset.currentFormatVersion)
    }
}
