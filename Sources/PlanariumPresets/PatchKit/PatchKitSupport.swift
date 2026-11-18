import Foundation
import PlanariumDomain

/// Every problem the Patch Construction Kit found, in plain words. Messages
/// name recipe positions and aliases, never state bytes or plist contents.
public struct PatchKitError: Error, Equatable, CustomStringConvertible, Sendable {
    public let problems: [String]
    public init(_ problems: [String]) { self.problems = problems }
    public init(_ problem: String) { problems = [problem] }
    public var description: String { problems.joined(separator: "\n") }
}

/// Fixed v1 bounds. Recipes and catalogs outside them fail visibly.
public enum PatchKitLimits {
    public static let recipeVersion = 1
    public static let catalogVersion = 1
    /// Version 2 recipes: regions with shapes on a configurable play area. Output is still a V6 preset.
    public static let recipeVersionTwo = 2
    public static let maximumRegions = 64
    public static let maximumPolygonPoints = SurfaceLimits.maximumPolygonPoints
    /// Offline processing limit for version 2 (explicitly not a statement about scanner range).
    public static let offlineRadiusLimitCentimeters = SurfaceLimits.processingRadiusCentimeters
    /// Largest absolute coordinate or size a version 2 recipe may use.
    public static let maximumCoordinateCentimeters = SurfaceLimits.maximumCoordinateCentimeters
    /// Cells assigned to all regions together (before the preset is written).
    public static let maximumCellAssignments = 1_000_000
    /// Grid points looked at while turning shapes into cells.
    public static let maximumCandidateTests = 20_000_000
    /// Instrument play area (ROADMAP instrument contract): rings are centimetres.
    public static let maximumDistanceCentimeters = 200
    public static let maximumChannels = InstrumentDocument.maximumChannels
    public static let maximumEffectsPerChannel = 4
    public static let maximumBands = 64
    public static let maximumNotesPerBand = 12
    public static let defaultVelocity = 80
    public static let defaultLevelDecibels = -9.0
    public static let levelDecibelRange = -60.0...6.0
    public static let maximumRecipeBytes = 256 * 1024
    public static let maximumCatalogBytes = 1024 * 1024
    public static let maximumStateBytes = 8 * 1024 * 1024
    public static let maximumSounds = 256
    public static let maximumNameCharacters = 80
    public static let maximumLabelCharacters = 40
    public static let maximumDescriptionCharacters = 200
}

enum PatchKitText {
    /// Short stable handle used for channels, bands and sound aliases.
    static func isHandle(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard (1...48).contains(scalars.count), let first = scalars.first else { return false }
        func alnum(_ s: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
        }
        return alnum(first) && scalars.allSatisfy { alnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }
    static func isPlainText(_ text: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !text.isEmpty) && text.count <= maximum
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}

/// Note names and MIDI numbers. C4 = 60, range 0...127 (C-1...G9).
public enum PatchNoteName {
    public static func parse(_ text: String) -> Int? {
        var rest = Substring(text)
        guard let letter = rest.first, let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(letter)] else { return nil }
        rest = rest.dropFirst()
        var shift = 0
        if rest.first == "#" { shift = 1; rest = rest.dropFirst() }
        else if rest.first == "b" { shift = -1; rest = rest.dropFirst() }
        guard !rest.isEmpty, rest.count <= 2, let octave = Int(rest), (-1...9).contains(octave),
              rest == Substring(String(octave)) else { return nil }
        let value = (octave + 1) * 12 + base + shift
        return (0...127).contains(value) ? value : nil
    }
    private static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    public static func name(for midi: Int) -> String {
        "\(sharpNames[midi % 12])\(midi / 12 - 1)"
    }
}

/// Deterministic identifiers: the same recipe always yields the same bytes.
enum PatchIdentity {
    static func uuid(_ parts: String...) -> UUID {
        var high: UInt64 = 0xcbf2_9ce4_8422_2325, low: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in ("planarium-patch-kit/1/" + parts.joined(separator: "\u{1F}")).utf8 {
            high = (high ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            low = (low &+ UInt64(byte) &+ 1) &* 0x9e37_79b9_7f4a_7c15
            low ^= low >> 29
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: high >> (8 * UInt64(index)))
            bytes[8 + index] = UInt8(truncatingIfNeeded: low >> (8 * UInt64(index)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// JSON decoding that fails on unknown fields instead of ignoring typos.
struct PatchKey: CodingKey, Equatable {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

enum PatchJSON {
    static func path(_ codingPath: [CodingKey]) -> String {
        var result = ""
        for key in codingPath {
            if let index = key.intValue { result += "[\(index)]" }
            else { result += (result.isEmpty ? "" : ".") + key.stringValue }
        }
        return result.isEmpty ? "the top level" : result
    }
    static func strictContainer(_ decoder: Decoder, allowed: [String], hints: [String: String] = [:]) throws -> KeyedDecodingContainer<PatchKey> {
        let values = try decoder.container(keyedBy: PatchKey.self)
        let unknown = values.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        if let first = unknown.first {
            if let hint = hints[first] { throw PatchKitError("unknown field \"\(first)\" at \(path(decoder.codingPath)) — \(hint)") }
            throw PatchKitError("unknown field \"\(first)\" at \(path(decoder.codingPath)) — allowed here: \(allowed.joined(separator: ", "))")
        }
        return values
    }
    static func describe(_ error: Error, what: String) -> PatchKitError {
        if let error = error as? PatchKitError { return error }
        guard let error = error as? DecodingError else { return PatchKitError("\(what) could not be read") }
        switch error {
        case .keyNotFound(let key, let context):
            return PatchKitError("missing field \"\(key.stringValue)\" at \(path(context.codingPath))")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return PatchKitError("wrong kind of value at \(path(context.codingPath)): \(context.debugDescription)")
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty
                ? PatchKitError("\(what) is not valid JSON")
                : PatchKitError("invalid value at \(path(context.codingPath))")
        @unknown default: return PatchKitError("\(what) could not be read")
        }
    }
}

extension KeyedDecodingContainer where K == PatchKey {
    /// Decodes one named field; any failure names the field's recipe position.
    func field<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        do { return try decode(type, forKey: PatchKey(name)) }
        catch { throw PatchKitError(fieldProblem(error, name)) }
    }
    func optionalField<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        do { return try decodeIfPresent(type, forKey: PatchKey(name)) }
        catch { throw PatchKitError(fieldProblem(error, name)) }
    }
    private func fieldProblem(_ error: Error, _ name: String) -> String {
        if let error = error as? PatchKitError { return error.description }
        let place = PatchJSON.path(codingPath + [PatchKey(name)])
        guard let error = error as? DecodingError else { return "invalid value at \(place)" }
        switch error {
        case .keyNotFound: return "missing field \"\(name)\" at \(PatchJSON.path(codingPath))"
        case .valueNotFound: return "field \"\(name)\" at \(PatchJSON.path(codingPath)) must not be null"
        case .typeMismatch(_, let context): return "wrong kind of value at \(place): \(context.debugDescription)"
        default: return "wrong kind of value at \(place): a whole number, text or list of the documented kind is required"
        }
    }
}

extension PatchKey { init(_ name: String) { self.init(stringValue: name)! } }
