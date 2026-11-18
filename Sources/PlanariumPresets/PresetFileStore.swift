import Foundation

/// Fehler der Ablage -- benannt, nie still.
public enum PresetStoreError: Error, Equatable {
    /// Nur Buchstaben, Ziffern, Leerzeichen, `-` und `_`, 1…64 Zeichen.
    case invalidName(String)
    case notFound(String)
    case ioFailed(String)
}

/// Die Preset-Ablage: eine Datei je Preset, **atomar** geschrieben
/// (`Data.write(.atomic)`: erst vollständig in eine Nebendatei, dann
/// umbenannt). Ein abgebrochener Schreibvorgang hinterlässt nie ein
/// halbes Preset.
///
/// Standardort: `~/Library/Application Support/SickPLSMonitor/Presets`.
/// Tests geben ein eigenes Verzeichnis.
public final class PresetFileStore {
    public static let fileExtension = "sickpreset.json"

    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Die Standardablage im Application-Support-Verzeichnis des Nutzers.
    public static func standard(fileManager: FileManager = .default) -> PresetFileStore {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return PresetFileStore(directory: base.appendingPathComponent("SickPLSMonitor/Presets", isDirectory: true), fileManager: fileManager)
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) } && name.trimmingCharacters(in: .whitespaces) == name
    }

    public func url(for name: String) throws -> URL {
        guard Self.isValidName(name) else { throw PresetStoreError.invalidName(name) }
        return directory.appendingPathComponent("\(name).\(Self.fileExtension)")
    }

    /// Alle Presetnamen, alphabetisch.
    public func list() throws -> [String] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        do {
            return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".\(Self.fileExtension)") }
                .map { String($0.lastPathComponent.dropLast(Self.fileExtension.count + 1)) }
                .filter(Self.isValidName)
                .sorted()
        } catch {
            throw PresetStoreError.ioFailed(String(describing: error))
        }
    }

    public func save(_ data: Data, as name: String) throws {
        let target = try url(for: name)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw PresetStoreError.ioFailed(String(describing: error))
        }
    }

    public func load(_ name: String) throws -> Data {
        let source = try url(for: name)
        guard fileManager.fileExists(atPath: source.path) else { throw PresetStoreError.notFound(name) }
        do {
            return try Data(contentsOf: source)
        } catch {
            throw PresetStoreError.ioFailed(String(describing: error))
        }
    }

    public func delete(_ name: String) throws {
        let target = try url(for: name)
        guard fileManager.fileExists(atPath: target.path) else { throw PresetStoreError.notFound(name) }
        do {
            try fileManager.removeItem(at: target)
        } catch {
            throw PresetStoreError.ioFailed(String(describing: error))
        }
    }
}
