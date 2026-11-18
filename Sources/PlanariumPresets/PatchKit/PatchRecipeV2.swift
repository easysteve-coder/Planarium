import Foundation
import PlanariumDomain

/// Version 2 patch recipe: channels (sound aliases) plus regions — shapes placed on a
/// chosen play area. Play mode is gate only, exactly as in version 1; the output is the
/// same canonical V6 preset. Decoding is strict: unknown fields fail.
public struct PatchRecipeV2: Equatable, Sendable {
    public enum OutsidePolicy: String, Equatable, Sendable { case error, clip }
    public struct Region: Equatable, Sendable {
        public var id: String
        public var label: String?
        public var shape: PatchShape
        public var transform: PatchTransform
        public var notes: [PatchNoteToken]
        public var channel: String
        public var color: String
        public var velocity: Int?
    }
    public var name: String
    public var summary: String
    public var velocity: Int
    public var channels: [PatchRecipe.Channel]
    public var playArea: PatchPlayArea
    public var outsidePolicy: OutsidePolicy
    public var regions: [Region]

    public static func decode(_ data: Data) throws -> PatchRecipeV2 {
        guard !data.isEmpty, data.count <= PatchKitLimits.maximumRecipeBytes else {
            throw PatchKitError("recipe file is empty or larger than \(PatchKitLimits.maximumRecipeBytes / 1024) KiB")
        }
        do { return try JSONDecoder().decode(Wire.self, from: data).recipe }
        catch { throw PatchJSON.describe(error, what: "recipe file") }
    }

    private struct Wire: Decodable {
        let recipe: PatchRecipeV2
        init(from decoder: Decoder) throws {
            let values = try PatchJSON.strictContainer(decoder, allowed:
                ["version", "name", "summary", "mode", "velocity", "channels", "playArea", "outsidePolicy", "regions"],
                hints: ["bands": "bands belong to recipe version 1 — version 2 describes regions with shapes"])
            let version = try values.field(Int.self, "version")
            guard version == PatchKitLimits.recipeVersionTwo else {
                throw PatchKitError("unsupported recipe version \(version) — this decoder reads version \(PatchKitLimits.recipeVersionTwo)")
            }
            if let mode = try values.optionalField(String.self, "mode"), mode != "gate" {
                throw PatchKitError("unsupported mode \"\(mode)\" — the kit knows only \"gate\" (a note sounds while the hand is in the region)")
            }
            let policyText = try values.optionalField(String.self, "outsidePolicy") ?? "error"
            guard let policy = OutsidePolicy(rawValue: policyText) else {
                throw PatchKitError("outsidePolicy \"\(policyText)\" is unknown — use \"error\" (refuse cells outside the play area) or \"clip\" (cut them off and report)")
            }
            recipe = PatchRecipeV2(
                name: try values.field(String.self, "name"),
                summary: try values.optionalField(String.self, "summary") ?? "",
                velocity: try values.optionalField(Int.self, "velocity") ?? PatchKitLimits.defaultVelocity,
                channels: try values.field([PatchRecipe.ChannelWire].self, "channels").map(\.value),
                playArea: try values.field(PlayAreaWire.self, "playArea").value,
                outsidePolicy: policy,
                regions: try values.field([RegionWire].self, "regions").map(\.value))
        }
    }

    private struct PlayAreaWire: Decodable {
        let value: PatchPlayArea
        init(from decoder: Decoder) throws {
            let kind = try decoder.container(keyedBy: PatchKey.self).field(String.self, "type")
            switch kind {
            case "rectangle":
                let values = try PatchJSON.strictContainer(decoder, allowed: ["type", "xMinCm", "xMaxCm", "yMinCm", "yMaxCm"])
                value = .rectangle(xMinCm: try values.field(Double.self, "xMinCm"), xMaxCm: try values.field(Double.self, "xMaxCm"),
                                   yMinCm: try values.field(Double.self, "yMinCm"), yMaxCm: try values.field(Double.self, "yMaxCm"))
            case "sector":
                let values = try PatchJSON.strictContainer(decoder, allowed: ["type", "fromCm", "toCm", "fromDegrees", "toDegrees"])
                value = .sector(fromCm: try values.field(Double.self, "fromCm"), toCm: try values.field(Double.self, "toCm"),
                                fromDegrees: try values.field(Double.self, "fromDegrees"), toDegrees: try values.field(Double.self, "toDegrees"))
            default:
                throw PatchKitError("playArea.type \"\(kind)\" is unknown — use \"rectangle\" or \"sector\"")
            }
        }
    }

    private struct PointWire: Decodable {
        let value: PatchPoint
        init(from decoder: Decoder) throws {
            var list = try decoder.unkeyedContainer()
            guard list.count == 2, let x = try? list.decode(Double.self), let y = try? list.decode(Double.self) else {
                throw PatchKitError("a polygon point must be [x, y] in centimetres, at \(PatchJSON.path(decoder.codingPath))")
            }
            value = PatchPoint(x: x, y: y)
        }
    }

    private struct ShapeWire: Decodable {
        let value: PatchShape
        init(from decoder: Decoder) throws {
            let kind = try decoder.container(keyedBy: PatchKey.self).field(String.self, "type")
            switch kind {
            case "rectangle":
                let values = try PatchJSON.strictContainer(decoder, allowed: ["type", "widthCm", "heightCm"])
                value = .rectangle(widthCm: try values.field(Double.self, "widthCm"), heightCm: try values.field(Double.self, "heightCm"))
            case "circle":
                let values = try PatchJSON.strictContainer(decoder, allowed: ["type", "radiusCm"])
                value = .circle(radiusCm: try values.field(Double.self, "radiusCm"))
            case "polygon":
                let values = try PatchJSON.strictContainer(decoder, allowed: ["type", "pointsCm"])
                value = .polygon(pointsCm: try values.field([PointWire].self, "pointsCm").map(\.value))
            case "sector":
                let values = try PatchJSON.strictContainer(decoder, allowed: ["type", "fromCm", "toCm", "fromDegrees", "toDegrees"])
                value = .ringSector(fromCm: try values.field(Double.self, "fromCm"), toCm: try values.field(Double.self, "toCm"),
                                    fromDegrees: try values.field(Double.self, "fromDegrees"), toDegrees: try values.field(Double.self, "toDegrees"))
            default:
                throw PatchKitError("shape.type \"\(kind)\" is unknown — use \"rectangle\", \"circle\", \"polygon\" or \"sector\"")
            }
        }
    }

    private struct TransformWire: Decodable {
        let value: PatchTransform
        init(from decoder: Decoder) throws {
            let values = try PatchJSON.strictContainer(decoder, allowed: ["xCm", "yCm", "rotationDegrees", "mirrorX"])
            value = PatchTransform(xCm: try values.optionalField(Double.self, "xCm") ?? 0, yCm: try values.optionalField(Double.self, "yCm") ?? 0,
                                   rotationDegrees: try values.optionalField(Double.self, "rotationDegrees") ?? 0,
                                   mirrorX: try values.optionalField(Bool.self, "mirrorX") ?? false)
        }
    }

    private struct RegionWire: Decodable {
        let value: Region
        init(from decoder: Decoder) throws {
            let values = try PatchJSON.strictContainer(decoder, allowed:
                ["id", "label", "shape", "transform", "note", "notes", "channel", "color", "velocity"],
                hints: ["fromCm": "distance bands are version 1 — in version 2 put fromCm/toCm into a \"sector\" shape"])
            let single = try values.optionalField(PatchRecipe.NoteWire.self, "note")
            let several = try values.optionalField([PatchRecipe.NoteWire].self, "notes")
            let id = try values.field(String.self, "id")
            let notes: [PatchNoteToken]
            switch (single, several) {
            case (let one?, nil): notes = [one.value]
            case (nil, let many?): notes = many.map(\.value)
            default: throw PatchKitError("region \"\(id)\" needs exactly one of \"note\" or \"notes\"")
            }
            value = Region(id: id,
                label: try values.optionalField(String.self, "label"),
                shape: try values.field(ShapeWire.self, "shape").value,
                transform: try values.optionalField(TransformWire.self, "transform")?.value ?? .identity,
                notes: notes,
                channel: try values.field(String.self, "channel"),
                color: try values.field(String.self, "color"),
                velocity: try values.optionalField(Int.self, "velocity"))
        }
    }

    /// Everything that can be judged without the sound catalog and without rasterising.
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
        if regions.isEmpty || regions.count > PatchKitLimits.maximumRegions {
            problems.append("regions: need 1–\(PatchKitLimits.maximumRegions), found \(regions.count)")
        }
        let channelIDs = PatchRecipe.channelProblems(channels, into: &problems)
        problems.append(contentsOf: playArea.kitProblems())
        var regionIDs = Set<String>()
        for (index, region) in regions.enumerated() {
            let at = "regions[\(index)] (\(region.id))"
            if !PatchKitText.isHandle(region.id) {
                problems.append("regions[\(index)]: id \"\(region.id)\" must be 1–48 letters, digits, '.', '_' or '-', starting with a letter or digit")
            } else if !regionIDs.insert(region.id).inserted {
                problems.append("\(at): duplicate region id")
            }
            if let label = region.label, !PatchKitText.isPlainText(label, maximum: PatchKitLimits.maximumLabelCharacters) {
                problems.append("\(at): label must be 1–\(PatchKitLimits.maximumLabelCharacters) characters")
            }
            problems.append(contentsOf: region.shape.kitProblems(transform: region.transform).map { "\(at): shape \($0)" })
            if !channelIDs.contains(region.channel) {
                problems.append("\(at): channel \"\(region.channel)\" is not defined in channels")
            }
            if PatchColor.parse(region.color) == nil {
                problems.append("\(at): color \"\(region.color)\" must look like #D4820A (# and six hex digits)")
            }
            if let velocity = region.velocity, !(1...127).contains(velocity) {
                problems.append("\(at): velocity \(velocity) is outside 1–127")
            }
            if region.notes.isEmpty || region.notes.count > PatchKitLimits.maximumNotesPerBand {
                problems.append("\(at): need 1–\(PatchKitLimits.maximumNotesPerBand) notes, found \(region.notes.count)")
            }
            problems.append(contentsOf: PatchRecipe.noteProblems(region.notes, at: at))
        }
        return problems
    }
}

/// A decoded recipe of either version.
public enum PatchKitRecipe: Equatable, Sendable {
    case v1(PatchRecipe)
    case v2(PatchRecipeV2)

    /// Reads `version` first, then decodes with the matching strict reader (versions are never mixed).
    public static func decode(_ data: Data) throws -> PatchKitRecipe {
        struct Peek: Decodable { let version: Int? }
        if let peek = try? JSONDecoder().decode(Peek.self, from: data), peek.version == PatchKitLimits.recipeVersionTwo {
            return .v2(try PatchRecipeV2.decode(data))
        }
        return .v1(try PatchRecipe.decode(data))
    }
}
