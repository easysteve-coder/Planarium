import Foundation

/// Disk work is serialized off Main, so a save/load clear follows every older write.
public final class PresetRecoveryStore: @unchecked Sendable {
    public struct Snapshot: Sendable { public let data: Data; public let modified: Date }
    private let queue = DispatchQueue(label: "Planarium preset recovery", qos: .utility)
    private let url: URL
    public init(url: URL) { self.url = url }
    public static func standard() throws -> PresetRecoveryStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return .init(url: base.appendingPathComponent("SickPLSMonitor/Recovery/Recovery.json"))
    }
    public func read() throws -> Snapshot? {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return .init(data: try Data(contentsOf: url), modified: attributes[.modificationDate] as? Date ?? .distantPast)
        }
    }
    public func write(_ preset: InstrumentPresetV6) {
        queue.async { [url] in
            do {
                let data = try PresetDocumentWriter.encode(preset)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { /* Existing recovery remains intact after an unsuccessful write. */ }
        }
    }
    public func clear() { queue.async { [url] in try? FileManager.default.removeItem(at: url) } }
    public func flush() { queue.sync {} }
}
