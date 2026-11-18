import Foundation
import PlanariumDomain

/// A note as the recipe author wrote it: a name like `Eb4` or a MIDI number.
public enum PatchNoteToken: Equatable, Sendable {
    case number(Int)
    case name(String)

    /// MIDI number, or nil when the spelling is not a defined note.
    public var midi: Int? {
        switch self {
        case .number(let value): return (0...127).contains(value) ? value : nil
        case .name(let text): return PatchNoteName.parse(text)
        }
    }
    var spelling: String {
        switch self { case .number(let value): return String(value); case .name(let text): return "\"\(text)\"" }
    }
}

/// Version 1 patch recipe: channels (sound aliases) and radial bands (notes).
/// Play mode is gate only: a note sounds while the hand is inside the band.
/// Decoding is strict — unknown fields fail instead of being ignored.
public struct PatchRecipe: Equatable, Sendable {
    public struct Channel: Equatable, Sendable {
        public var id: String
        public var name: String?
        public var instrument: String
        public var effects: [String]
        public var levelDb: Double
    }
    public struct Band: Equatable, Sendable {
        public var id: String
        public var label: String?
        public var fromCm: Int
        public var toCm: Int
        public var notes: [PatchNoteToken]
        public var channel: String
        public var color: String
        public var velocity: Int?
    }
    public var name: String
    public var summary: String
    public var velocity: Int
    public var channels: [Channel]
    public var bands: [Band]

    public static func decode(_ data: Data) throws -> PatchRecipe {
        guard !data.isEmpty, data.count <= PatchKitLimits.maximumRecipeBytes else {
            throw PatchKitError("recipe file is empty or larger than \(PatchKitLimits.maximumRecipeBytes / 1024) KiB")
        }
        do { return try JSONDecoder().decode(Wire.self, from: data).recipe }
        catch { throw PatchJSON.describe(error, what: "recipe file") }
    }

    private struct Wire: Decodable {
        let recipe: PatchRecipe
        init(from decoder: Decoder) throws {
            let values = try PatchJSON.strictContainer(decoder, allowed:
                ["version", "name", "summary", "mode", "velocity", "channels", "bands"],
                hints: ["regions": "regions, playArea and outsidePolicy belong to recipe version 2 (\"version\": 2)",
                        "playArea": "regions, playArea and outsidePolicy belong to recipe version 2 (\"version\": 2)",
                        "outsidePolicy": "regions, playArea and outsidePolicy belong to recipe version 2 (\"version\": 2)"])
            let version = try values.field(Int.self, "version")
            guard version == PatchKitLimits.recipeVersion else {
                throw PatchKitError("unsupported recipe version \(version) — this kit reads versions \(PatchKitLimits.recipeVersion) and \(PatchKitLimits.recipeVersionTwo)")
            }
            if let mode = try values.optionalField(String.self, "mode"), mode != "gate" {
                throw PatchKitError("unsupported mode \"\(mode)\" — v1 knows only \"gate\" (a note sounds while the hand is in the band)")
            }
            recipe = PatchRecipe(
                name: try values.field(String.self, "name"),
                summary: try values.optionalField(String.self, "summary") ?? "",
                velocity: try values.optionalField(Int.self, "velocity") ?? PatchKitLimits.defaultVelocity,
                channels: try values.field([ChannelWire].self, "channels").map(\.value),
                bands: try values.field([BandWire].self, "bands").map(\.value))
        }
    }
    struct ChannelWire: Decodable {
        let value: Channel
        init(from decoder: Decoder) throws {
            let values = try PatchJSON.strictContainer(decoder, allowed: ["id", "name", "instrument", "effects", "levelDb"])
            value = Channel(
                id: try values.field(String.self, "id"),
                name: try values.optionalField(String.self, "name"),
                instrument: try values.field(String.self, "instrument"),
                effects: try values.optionalField([String].self, "effects") ?? [],
                levelDb: try values.optionalField(Double.self, "levelDb") ?? PatchKitLimits.defaultLevelDecibels)
        }
    }
    struct NoteWire: Decodable {
        let value: PatchNoteToken
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let number = try? single.decode(Int.self) { value = .number(number) }
            else if let text = try? single.decode(String.self) { value = .name(text) }
            else { throw PatchKitError("a note must be a name like A3, Eb4, C#4 or a whole MIDI number, at \(PatchJSON.path(decoder.codingPath))") }
        }
    }
    private struct BandWire: Decodable {
        let value: Band
        init(from decoder: Decoder) throws {
            let values = try PatchJSON.strictContainer(decoder, allowed:
                ["id", "label", "fromCm", "toCm", "note", "notes", "channel", "color", "velocity"])
            let single = try values.optionalField(NoteWire.self, "note")
            let several = try values.optionalField([NoteWire].self, "notes")
            let id = try values.field(String.self, "id")
            let notes: [PatchNoteToken]
            switch (single, several) {
            case (let one?, nil): notes = [one.value]
            case (nil, let many?): notes = many.map(\.value)
            default: throw PatchKitError("band \"\(id)\" needs exactly one of \"note\" or \"notes\"")
            }
            value = Band(id: id,
                label: try values.optionalField(String.self, "label"),
                fromCm: try values.field(Int.self, "fromCm"),
                toCm: try values.field(Int.self, "toCm"),
                notes: notes,
                channel: try values.field(String.self, "channel"),
                color: try values.field(String.self, "color"),
                velocity: try values.optionalField(Int.self, "velocity"))
        }
    }

    /// Everything that can be judged without the sound catalog.
    func validate() -> [String] {
        var problems: [String] = []
        if !PatchKitText.isPlainText(name, maximum: PatchKitLimits.maximumNameCharacters) {
            problems.append("name must be 1–\(PatchKitLimits.maximumNameCharacters) characters without control characters")
        }
        if !PatchKitText.isPlainText(summary, maximum: InstrumentPresetV6.maximumSummaryCharacters, allowEmpty: true) {
            problems.append("summary must be at most \(InstrumentPresetV6.maximumSummaryCharacters) characters without control characters")
        }
        if !(1...127).contains(velocity) { problems.append("velocity \(velocity) is outside 1–127") }
        if channels.isEmpty || channels.count > PatchKitLimits.maximumChannels {
            problems.append("channels: need 1–\(PatchKitLimits.maximumChannels), found \(channels.count)")
        }
        if bands.isEmpty || bands.count > PatchKitLimits.maximumBands {
            problems.append("bands: need 1–\(PatchKitLimits.maximumBands), found \(bands.count)")
        }
        let channelIDs = Self.channelProblems(channels, into: &problems)
        var bandIDs = Set<String>()
        for (index, band) in bands.enumerated() {
            let at = "bands[\(index)] (\(band.id))"
            if !PatchKitText.isHandle(band.id) {
                problems.append("bands[\(index)]: id \"\(band.id)\" must be 1–48 letters, digits, '.', '_' or '-', starting with a letter or digit")
            } else if !bandIDs.insert(band.id).inserted {
                problems.append("\(at): duplicate band id")
            }
            if let label = band.label, !PatchKitText.isPlainText(label, maximum: PatchKitLimits.maximumLabelCharacters) {
                problems.append("\(at): label must be 1–\(PatchKitLimits.maximumLabelCharacters) characters")
            }
            if band.fromCm < 0 || band.toCm > PatchKitLimits.maximumDistanceCentimeters || band.fromCm >= band.toCm {
                problems.append("\(at): distance \(band.fromCm)–\(band.toCm) cm is invalid — need whole centimetres with 0 <= fromCm < toCm <= \(PatchKitLimits.maximumDistanceCentimeters) (fromCm included, toCm excluded)")
            }
            if !channelIDs.contains(band.channel) {
                problems.append("\(at): channel \"\(band.channel)\" is not defined in channels")
            }
            if PatchColor.parse(band.color) == nil {
                problems.append("\(at): color \"\(band.color)\" must look like #D4820A (# and six hex digits)")
            }
            if let velocity = band.velocity, !(1...127).contains(velocity) {
                problems.append("\(at): velocity \(velocity) is outside 1–127")
            }
            if band.notes.isEmpty || band.notes.count > PatchKitLimits.maximumNotesPerBand {
                problems.append("\(at): need 1–\(PatchKitLimits.maximumNotesPerBand) notes, found \(band.notes.count)")
            }
            problems.append(contentsOf: Self.noteProblems(band.notes, at: at))
        }
        // Same-channel bands must not share a ring: both would trigger the same cell.
        for (leftIndex, left) in bands.enumerated() {
            for right in bands[(leftIndex + 1)...] where left.channel == right.channel
                && left.fromCm < right.toCm && right.fromCm < left.toCm {
                problems.append("bands \"\(left.id)\" (\(left.fromCm)–\(left.toCm) cm) and \"\(right.id)\" (\(right.fromCm)–\(right.toCm) cm) overlap on channel \"\(left.channel)\" — shorten one so that toCm of the nearer band is not above fromCm of the farther band")
            }
        }
        return problems
    }

    /// Channel rules shared by every recipe version; returns the valid channel IDs.
    static func channelProblems(_ channels: [Channel], into problems: inout [String]) -> Set<String> {
        var channelIDs = Set<String>()
        for (index, channel) in channels.enumerated() {
            let at = "channels[\(index)]"
            if !PatchKitText.isHandle(channel.id) {
                problems.append("\(at): id \"\(channel.id)\" must be 1–48 letters, digits, '.', '_' or '-', starting with a letter or digit")
            } else if !channelIDs.insert(channel.id).inserted {
                problems.append("\(at): duplicate channel id \"\(channel.id)\"")
            }
            if let name = channel.name, !PatchKitText.isPlainText(name, maximum: PatchKitLimits.maximumLabelCharacters) {
                problems.append("\(at) (\(channel.id)): name must be 1–\(PatchKitLimits.maximumLabelCharacters) characters")
            }
            if !PatchKitText.isHandle(channel.instrument) {
                problems.append("\(at) (\(channel.id)): instrument alias \"\(channel.instrument)\" is not a valid alias")
            }
            if channel.effects.count > PatchKitLimits.maximumEffectsPerChannel {
                problems.append("\(at) (\(channel.id)): at most \(PatchKitLimits.maximumEffectsPerChannel) effects, found \(channel.effects.count)")
            }
            for effect in channel.effects where !PatchKitText.isHandle(effect) {
                problems.append("\(at) (\(channel.id)): effect alias \"\(effect)\" is not a valid alias")
            }
            if !channel.levelDb.isFinite || !PatchKitLimits.levelDecibelRange.contains(channel.levelDb) {
                problems.append("\(at) (\(channel.id)): levelDb must be a finite number from \(Int(PatchKitLimits.levelDecibelRange.lowerBound)) to \(Int(PatchKitLimits.levelDecibelRange.upperBound))")
            }
        }
        return channelIDs
    }

    /// Note rules shared by every recipe version.
    static func noteProblems(_ notes: [PatchNoteToken], at: String) -> [String] {
        var problems: [String] = []
        var seen = Set<Int>()
        for token in notes {
            guard let midi = token.midi else {
                problems.append("\(at): note \(token.spelling) is not a defined note — use names like A3, Eb4, C#4 (C4 = 60) or a MIDI number 0–127")
                continue
            }
            if !seen.insert(midi).inserted { problems.append("\(at): note \(PatchNoteName.name(for: midi)) is listed twice") }
        }
        return problems
    }
}


enum PatchColor {
    /// `#RRGGBB` as 0…1 channels, rounded to four decimals.
    static func parse(_ text: String) -> SpatialLayerColor? {
        let scalars = Array(text.utf8)
        guard scalars.count == 7, scalars[0] == UInt8(ascii: "#") else { return nil }
        var channels: [Double] = []
        for pair in 0..<3 {
            guard let value = Int(String(decoding: scalars[(1 + pair * 2)..<(3 + pair * 2)], as: UTF8.self), radix: 16),
                  scalars[(1 + pair * 2)..<(3 + pair * 2)].allSatisfy({ $0.isASCIIHexDigit }) else { return nil }
            channels.append((Double(value) / 255 * 10_000).rounded() / 10_000)
        }
        return SpatialLayerColor(red: channels[0], green: channels[1], blue: channels[2], alpha: 1)
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(self)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(self)
    }
}
