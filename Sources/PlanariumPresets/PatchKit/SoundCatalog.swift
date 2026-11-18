import Foundation
import PlanariumDomain

/// A sound alias resolved to the identity and state read from its state file.
/// The state is a property list copied from a real audio-unit capture; the
/// kit never loads a plug-in, so "structurally valid" is not "listened to".
public struct ResolvedSound: Equatable, Sendable {
    public let alias: String
    public let role: SoundCatalog.Role
    public let identity: SpatialAudioUnitIdentity
    public let state: Data
    public var identityText: String { PatchFourCC.describe(identity) }
}

enum PatchFourCC {
    static let instrumentType: UInt32 = 0x6175_6D75 // aumu
    static let effectType: UInt32 = 0x6175_6678 // aufx
    static func text(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> UInt32($0)) }
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) { return String(decoding: bytes, as: UTF8.self) }
        return "0x" + String(value, radix: 16, uppercase: true)
    }
    static func describe(_ identity: SpatialAudioUnitIdentity) -> String {
        "\(text(identity.componentType))/\(text(identity.componentSubType))/\(text(identity.componentManufacturer))"
    }
}

/// Versioned list of reusable sounds. State files live inside the catalog
/// folder and are addressed by relative paths only.
public struct SoundCatalog: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable { case instrument, effect }
    public struct Entry: Equatable, Sendable {
        public var alias: String
        public var role: Role
        public var description: String
        public var state: String
    }
    public let fileURL: URL
    public let entries: [Entry]
    public var directory: URL { fileURL.deletingLastPathComponent() }

    public init(fileURL: URL, entries: [Entry]) { self.fileURL = fileURL; self.entries = entries }

    public func entry(_ alias: String) -> Entry? { entries.first { $0.alias == alias } }

    // MARK: Reading

    public static func load(from url: URL) throws -> SoundCatalog {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw PatchKitError("cannot read sound catalog file \(url.path)") }
        guard !data.isEmpty, data.count <= PatchKitLimits.maximumCatalogBytes else {
            throw PatchKitError("sound catalog is empty or larger than \(PatchKitLimits.maximumCatalogBytes / 1024) KiB")
        }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) }
        catch { throw PatchJSON.describe(error, what: "sound catalog") }
        var problems: [String] = []
        var aliases = Set<String>(), paths = Set<String>()
        guard wire.entries.count <= PatchKitLimits.maximumSounds else {
            throw PatchKitError("sound catalog lists more than \(PatchKitLimits.maximumSounds) sounds")
        }
        for (index, entry) in wire.entries.enumerated() {
            let at = "sounds[\(index)] (\(entry.alias))"
            if !PatchKitText.isHandle(entry.alias) { problems.append("sounds[\(index)]: alias \"\(entry.alias)\" is not a valid alias") }
            else if !aliases.insert(entry.alias).inserted { problems.append("\(at): duplicate alias") }
            if !PatchKitText.isPlainText(entry.description, maximum: PatchKitLimits.maximumDescriptionCharacters, allowEmpty: true) {
                problems.append("\(at): description must be at most \(PatchKitLimits.maximumDescriptionCharacters) characters")
            }
            if let reason = relativePathProblem(entry.state) { problems.append("\(at): state path \(reason)") }
            else if !paths.insert(entry.state).inserted { problems.append("\(at): state file \"\(entry.state)\" is used by another alias") }
        }
        if !problems.isEmpty { throw PatchKitError(problems) }
        return SoundCatalog(fileURL: url, entries: wire.entries)
    }

    /// Relative, forward-slash, no `.`/`..`/empty components: no path escapes.
    static func relativePathProblem(_ path: String) -> String? {
        if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") || path.contains("\\") || path.contains("\0") {
            return "must be a relative path inside the catalog folder"
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return "must not contain empty, '.' or '..' components"
        }
        return nil
    }

    /// Absolute location of a state file, checked to stay inside the catalog folder
    /// even through symbolic links.
    func stateURL(for entry: Entry) throws -> URL {
        let root = PatchFiles.canonicalPath(directory)
        let url = entry.state.split(separator: "/").reduce(directory) { $0.appendingPathComponent(String($1)) }
        guard PatchFiles.canonicalPath(url).hasPrefix(root + "/") else {
            throw PatchKitError("sound \"\(entry.alias)\": state file \"\(entry.state)\" resolves outside the catalog folder")
        }
        return url
    }

    /// Reads and structurally checks the state of one alias. Never loads a plug-in.
    public func resolve(_ alias: String, expecting expected: Role? = nil) throws -> ResolvedSound {
        guard let entry = entry(alias) else {
            let known = entries.map(\.alias).sorted().joined(separator: ", ")
            throw PatchKitError("sound \"\(alias)\" is not in the catalog (known: \(known.isEmpty ? "none" : known)) — add its already captured audio-unit state first: kit import-state --catalog \(fileURL.lastPathComponent) --state <state.plist> --alias \(alias) --role \(expected?.rawValue ?? "instrument|effect"). No default or stand-in sound is ever substituted.")
        }
        let url = try stateURL(for: entry)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PatchKitError("sound \"\(alias)\": state file \"\(entry.state)\" is missing — no default state is substituted")
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw PatchKitError("sound \"\(alias)\": state file \"\(entry.state)\" cannot be read") }
        let identity = try Self.inspect(state: data, alias: alias, role: entry.role)
        return ResolvedSound(alias: alias, role: entry.role, identity: identity, state: data)
    }

    /// Property-list dictionary with integer type/subtype/manufacturer that matches the role.
    static func inspect(state data: Data, alias: String, role: Role) throws -> SpatialAudioUnitIdentity {
        guard !data.isEmpty else { throw PatchKitError("sound \"\(alias)\": state file is empty") }
        guard data.count <= PatchKitLimits.maximumStateBytes else {
            throw PatchKitError("sound \"\(alias)\": state file is larger than \(PatchKitLimits.maximumStateBytes / 1024 / 1024) MiB")
        }
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else {
            throw PatchKitError("sound \"\(alias)\": state file is not a property-list dictionary")
        }
        guard !dictionary.isEmpty else { throw PatchKitError("sound \"\(alias)\": state dictionary is empty (an empty state would load a default sound)") }
        func code(_ key: String) throws -> UInt32 {
            guard let number = dictionary[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number), let value = UInt32(exactly: number.int64Value) else {
                throw PatchKitError("sound \"\(alias)\": state has no usable integer \"\(key)\" — it is not a real audio-unit state")
            }
            return value
        }
        let identity = SpatialAudioUnitIdentity(componentType: try code("type"), componentSubType: try code("subtype"),
                                                componentManufacturer: try code("manufacturer"))
        try requireSoundPayload(dictionary, alias: alias)
        let expected = role == .instrument ? PatchFourCC.instrumentType : PatchFourCC.effectType
        guard identity.componentType == expected else {
            throw PatchKitError("sound \"\(alias)\": declared as \(role.rawValue) but the state identity is \(PatchFourCC.describe(identity)) — instruments are aumu, effects are aufx")
        }
        return identity
    }

    /// v1 supports exactly the two payload shapes measured from real captures: a non-empty
    /// `data` blob (Apple audio units) or a non-empty `jucePluginState` blob (JUCE plug-ins
    /// such as Surge XT). Identity and name fields alone describe a sound, they do not hold
    /// one. Other plug-in parameter layouts are not validated by v1 and are refused here.
    private static func requireSoundPayload(_ dictionary: [String: Any], alias: String) throws {
        var found = false
        for key in ["data", "jucePluginState"] {
            guard let value = dictionary[key] else { continue }
            guard let blob = value as? Data, !blob.isEmpty else {
                throw PatchKitError("sound \"\(alias)\": state field \"\(key)\" is empty or not binary data — it holds no sound payload")
            }
            found = true
        }
        guard found else {
            throw PatchKitError("sound \"\(alias)\": state has no sound payload (v1 supports a non-empty \"data\" or \"jucePluginState\" entry; identity and name alone would load a default sound, and other parameter layouts are not supported yet)")
        }
    }

    /// Canonical locations of every state file the catalog lists, used or not, whether or not the
    /// file exists. Nothing is read. A path that cannot be resolved inside the folder is an error,
    /// so the caller never has to guess whether a write is safe.
    func allStateURLs() throws -> [URL] { try entries.map { try stateURL(for: $0) } }

    /// Every sound with its own verdict; used by `kit sounds`.
    public func inspectAll() -> [(entry: Entry, result: Result<ResolvedSound, PatchKitError>)] {
        entries.map { entry in
            do { return (entry, .success(try resolve(entry.alias))) }
            catch let error as PatchKitError { return (entry, .failure(error)) }
            catch { return (entry, .failure(PatchKitError("unreadable"))) }
        }
    }

    // MARK: Importing

    public struct ImportReceipt: Equatable, Sendable {
        public let alias: String
        public let role: Role
        public let identityText: String
        public let stateBytes: Int
        public let statePath: String
        public let createdCatalog: Bool
    }

    /// Copies an existing state into the catalog folder and registers the alias.
    /// Never overwrites an alias or a state file; the source is only read.
    public static func importState(catalog url: URL, state source: URL, alias: String, role: Role,
                                   description: String) throws -> ImportReceipt {
        var problems: [String] = []
        if !PatchKitText.isHandle(alias) { problems.append("alias \"\(alias)\" must be 1–48 letters, digits, '.', '_' or '-', starting with a letter or digit") }
        if !PatchKitText.isPlainText(description, maximum: PatchKitLimits.maximumDescriptionCharacters, allowEmpty: true) {
            problems.append("description must be at most \(PatchKitLimits.maximumDescriptionCharacters) characters")
        }
        if !problems.isEmpty { throw PatchKitError(problems) }
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: url.path)
        let existing = exists ? try load(from: url) : SoundCatalog(fileURL: url, entries: [])
        guard existing.entry(alias) == nil else {
            throw PatchKitError("alias \"\(alias)\" already exists in the catalog — nothing was changed; choose another alias")
        }
        guard existing.entries.count < PatchKitLimits.maximumSounds else {
            throw PatchKitError("sound catalog already lists \(PatchKitLimits.maximumSounds) sounds")
        }
        let data: Data
        do { data = try Data(contentsOf: source) } catch { throw PatchKitError("cannot read state file \(source.path)") }
        let identity = try inspect(state: data, alias: alias, role: role)
        let entry = Entry(alias: alias, role: role, description: description, state: "states/\(alias).plist")
        let target = try existing.stateURL(for: entry)
        guard !fileManager.fileExists(atPath: target.path) else {
            throw PatchKitError("state file \(entry.state) already exists next to the catalog — nothing was changed; choose another alias")
        }
        if [PatchFiles.canonicalPath(target), PatchFiles.canonicalPath(url)].contains(PatchFiles.canonicalPath(source)) {
            throw PatchKitError("the state file must come from outside the catalog entry it creates")
        }
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PatchFiles.writeNew(data, to: target)
        } catch let error as PatchKitError { throw error }
        catch { throw PatchKitError("cannot write state file \(entry.state) into the catalog folder") }
        let updated = SoundCatalog(fileURL: url, entries: existing.entries + [entry])
        do { try updated.write() }
        catch {
            try? fileManager.removeItem(at: target)
            throw PatchKitError("cannot write the sound catalog \(url.path); the copied state file was removed again")
        }
        return ImportReceipt(alias: alias, role: role, identityText: PatchFourCC.describe(identity), stateBytes: data.count,
                             statePath: entry.state, createdCatalog: !exists)
    }

    func write() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var wire = Wire(entries: entries)
        wire.encodedVersion = PatchKitLimits.catalogVersion
        try PatchFiles.replace(try encoder.encode(wire), at: fileURL)
    }

    // MARK: Wire format

    private struct Wire: Codable {
        var entries: [Entry]
        var encodedVersion = PatchKitLimits.catalogVersion
        init(entries: [Entry]) { self.entries = entries }
        init(from decoder: Decoder) throws {
            let values = try PatchJSON.strictContainer(decoder, allowed: ["version", "sounds"])
            let version = try values.field(Int.self, "version")
            guard version == PatchKitLimits.catalogVersion else {
                throw PatchKitError("unsupported sound catalog version \(version) — this kit reads version \(PatchKitLimits.catalogVersion)")
            }
            entries = try values.field([EntryWire].self, "sounds").map(\.value)
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: PatchKey.self)
            try values.encode(encodedVersion, forKey: PatchKey("version"))
            try values.encode(entries.map(EntryWire.init), forKey: PatchKey("sounds"))
        }
    }
    private struct EntryWire: Codable {
        let value: Entry
        init(_ value: Entry) { self.value = value }
        init(from decoder: Decoder) throws {
            let values = try PatchJSON.strictContainer(decoder, allowed: ["alias", "role", "description", "state"])
            let roleText = try values.field(String.self, "role")
            guard let role = Role(rawValue: roleText) else {
                throw PatchKitError("sound role \"\(roleText)\" at \(PatchJSON.path(decoder.codingPath)) must be \"instrument\" or \"effect\"")
            }
            value = Entry(alias: try values.field(String.self, "alias"), role: role,
                          description: try values.optionalField(String.self, "description") ?? "",
                          state: try values.field(String.self, "state"))
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: PatchKey.self)
            try values.encode(value.alias, forKey: PatchKey("alias"))
            try values.encode(value.role.rawValue, forKey: PatchKey("role"))
            if !value.description.isEmpty { try values.encode(value.description, forKey: PatchKey("description")) }
            try values.encode(value.state, forKey: PatchKey("state"))
        }
    }
}

/// Small file helpers: temporary file in the same folder, then move.
enum PatchFiles {
    /// Absolute path with symbolic links resolved, also for files that do not exist yet:
    /// the deepest existing ancestor is resolved and the remaining names are appended.
    static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    /// Writes a file that must not exist yet; an existing file is never touched.
    static func writeNew(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        try data.write(to: temporary, options: .atomic)
        do { try FileManager.default.moveItem(at: temporary, to: url) }
        catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    /// Replaces (or creates) a file atomically.
    static func replace(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
