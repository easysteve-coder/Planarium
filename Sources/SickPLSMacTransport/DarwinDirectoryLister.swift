import Darwin

/// Reale Darwin/POSIX-Implementierung von ``DirectoryLister`` über
/// `opendir(3)`/`readdir(3)`. Kein Foundation-`FileManager` -- dieses
/// Paket bleibt wie `SickPLSCore` frei von Foundation-Importen, siehe
/// `CLAUDE.md`.
public struct DarwinDirectoryLister: DirectoryLister {
    public init() {}

    public func entryNames(inDirectory path: String) -> [String] {
        guard let directory = opendir(path) else { return [] }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { rawName -> String in
                let cString = rawName.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: cString)
            }
            names.append(name)
        }
        return names
    }
}
