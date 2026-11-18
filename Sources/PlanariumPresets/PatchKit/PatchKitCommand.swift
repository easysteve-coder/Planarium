import Foundation

/// The `kit` sub-commands of planarium-preset-tool. The tool's main only
/// forwards arguments and prints; all decisions live here so tests can run them.
public enum PatchKitCommand {
    public static let usage = """
    planarium-preset-tool kit — Patch Construction Kit (offline; no plug-in, audio or MIDI is touched)

      kit check  --recipe R.json --catalog C/sounds.json
          Validate the recipe and print the plan as a table. Writes nothing.
      kit build  --recipe R.json --catalog C/sounds.json --out NAME.sickpreset.json [--force]
          Same validation, then write a V6 preset atomically. An existing output file is kept
          unless --force is given. Recipe and catalog are never modified.
      kit preview --recipe R.json --catalog C/sounds.json --out PREVIEW.svg [--force]
          Same validation, then write a static SVG of the cells that really result (play area, scanner,
          axes, cm scale, legend region/note/channel). Offline; no script, image or external reference.
          An existing file is kept unless --force is given; recipe, catalog and states are never touched.
      kit sounds --catalog C/sounds.json
          List the sound aliases with role, plug-in identity and state size.
      kit import-state --catalog C/sounds.json --state STATE.plist --alias NAME --role instrument|effect [--description TEXT]
          Copy an existing audio-unit state property list into the catalog folder (states/NAME.plist)
          and register the alias. Never overwrites an alias or a state file. Captures nothing.

    Recipe version 1 (ring bands) or version 2 (shaped regions on a play area), play mode gate: see
    PatchKit/README.md. A passing check means the structure is valid — it does not mean the sound
    was listened to. Coordinates (version 2): centimetres, scanner at (0, 0), +x right, +y forward;
    bearing -90° left, 0° front, +90° right; rotation counter-clockwise; mirrorX before rotation.
    Exit codes: 0 ok · 1 recipe/catalog/IO problem · 2 wrong command line.
    """

    public static func run(_ arguments: [String], out: (String) -> Void, err: (String) -> Void) -> Int32 {
        guard let command = arguments.first else { err(usage); return 2 }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "help", "--help", "-h": out(usage); return 0
            case "check":
                let options = try Options(rest, values: ["recipe", "catalog"], flags: [])
                _ = try (options.required("recipe"), options.required("catalog"))
                let build = try compile(options)
                out(build.plan.render() + "Check passed: structure only — the sounds were not loaded or listened to.\n")
            case "build":
                let options = try Options(rest, values: ["recipe", "catalog", "out"], flags: ["force"])
                _ = try (options.required("recipe"), options.required("catalog"), options.required("out"))
                let build = try compile(options)
                let output = URL(fileURLWithPath: try options.required("out"))
                try write(build.data, to: output, suffix: ".sickpreset.json", build: build, force: options.flag("force"), options: options)
                out(build.plan.render() + "Wrote \(output.path) (\(build.data.count) bytes). Structure checked only — load it in Planarium to audition.\n")
            case "preview":
                let options = try Options(rest, values: ["recipe", "catalog", "out"], flags: ["force"])
                _ = try (options.required("recipe"), options.required("catalog"), options.required("out"))
                let build = try compile(options)
                let output = URL(fileURLWithPath: try options.required("out"))
                let svg = Data(try PatchPreview.svg(for: build).utf8)
                try write(svg, to: output, suffix: ".svg", build: build, force: options.flag("force"), options: options)
                out(build.plan.render() + "Wrote \(output.path) (\(svg.count) bytes). The picture shows the checked cells only — structure, not sound; no sound was loaded.\n")
            case "sounds":
                let options = try Options(rest, values: ["catalog"], flags: [])
                let catalog = try SoundCatalog.load(from: URL(fileURLWithPath: try options.required("catalog")))
                var broken = 0
                var lines = ["ALIAS".padded(26) + "ROLE".padded(11) + "IDENTITY".padded(22) + "STATE".padded(12) + "DESCRIPTION"]
                for (entry, result) in catalog.inspectAll() {
                    switch result {
                    case .success(let sound):
                        lines.append(entry.alias.padded(26) + entry.role.rawValue.padded(11) + sound.identityText.padded(22)
                            + "\(sound.state.count) B".padded(12) + entry.description)
                    case .failure(let error):
                        broken += 1
                        lines.append(entry.alias.padded(26) + entry.role.rawValue.padded(11) + "UNUSABLE: " + error.problems.joined(separator: "; "))
                    }
                }
                out(lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") + "\n\(catalog.entries.count) sounds, \(broken) unusable. Identity is read from the stored state; nothing was loaded or listened to.\n")
                return broken == 0 ? 0 : 1
            case "import-state":
                let options = try Options(rest, values: ["catalog", "state", "alias", "role", "description"], flags: [])
                guard let role = SoundCatalog.Role(rawValue: try options.required("role")) else {
                    throw UsageError("--role must be instrument or effect")
                }
                let receipt = try SoundCatalog.importState(
                    catalog: URL(fileURLWithPath: try options.required("catalog")),
                    state: URL(fileURLWithPath: try options.required("state")),
                    alias: try options.required("alias"), role: role, description: options.value("description") ?? "")
                out("Imported \(receipt.alias) (\(receipt.role.rawValue), \(receipt.identityText), \(receipt.stateBytes) B) as \(receipt.statePath)"
                    + (receipt.createdCatalog ? " in a new catalog" : "") + ". The state was copied, not loaded or listened to.\n")
            default:
                err("unknown kit command \"\(command)\"\n" + usage); return 2
            }
            return 0
        } catch let error as UsageError {
            err("\(error.message)\n\(usage)"); return 2
        } catch let error as PatchKitError {
            err("kit failed:\n" + error.problems.map { "  - " + $0 }.joined(separator: "\n") + "\n"); return 1
        } catch {
            err("kit failed: unexpected problem\n"); return 1
        }
    }

    private static func compile(_ options: Options) throws -> PatchBuild {
        let recipeURL = URL(fileURLWithPath: try options.required("recipe"))
        guard let data = try? Data(contentsOf: recipeURL) else { throw PatchKitError("cannot read recipe file \(recipeURL.path)") }
        let recipe = try PatchKitRecipe.decode(data)
        return try PatchCompiler.compile(recipe, catalog: try SoundCatalog.load(from: URL(fileURLWithPath: try options.required("catalog"))))
    }

    private static func write(_ data: Data, to output: URL, suffix: String, build: PatchBuild, force: Bool, options: Options) throws {
        guard output.lastPathComponent.hasSuffix(suffix), output.lastPathComponent != suffix else {
            throw PatchKitError("--out must be a file name ending in \(suffix)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PatchKitError("the folder for --out does not exist: \(output.deletingLastPathComponent().path)")
        }
        // The output may never be one of the inputs, even with --force.
        let canonical = PatchFiles.canonicalPath
        // Every state file the catalog lists is protected, not only those this recipe resolved.
        let catalog = try SoundCatalog.load(from: URL(fileURLWithPath: try options.required("catalog")))
        let protected = ([URL(fileURLWithPath: try options.required("recipe")), catalog.fileURL]
            + build.inputStateFiles + (try catalog.allStateURLs())).map(canonical)
        guard !protected.contains(canonical(output)) else {
            throw PatchKitError("--out would overwrite an input file (recipe, catalog or state) — choose another file name")
        }
        let exists = FileManager.default.fileExists(atPath: output.path)
        if exists {
            guard force else { throw PatchKitError("\(output.path) already exists — nothing was written; use --force to replace it") }
            guard !isDirectoryPath(output) else { throw PatchKitError("\(output.path) is a folder") }
        }
        do { if exists { try PatchFiles.replace(data, at: output) } else { try PatchFiles.writeNew(data, to: output) } }
        catch { throw PatchKitError("cannot write \(output.path); an existing output file was left as it was") }
    }

    private static func isDirectoryPath(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    struct UsageError: Error { let message: String; init(_ message: String) { self.message = message } }

    /// `--name value` pairs and bare flags; anything else is a usage error.
    struct Options {
        private var values: [String: String] = [:]
        private var flags: Set<String> = []
        init(_ arguments: [String], values allowed: [String], flags allowedFlags: [String]) throws {
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                guard argument.hasPrefix("--") else { throw UsageError("unexpected argument \"\(argument)\"") }
                let name = String(argument.dropFirst(2))
                if allowedFlags.contains(name) {
                    guard flags.insert(name).inserted else { throw UsageError("--\(name) given twice") }
                    index += 1
                } else if allowed.contains(name) {
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw UsageError("--\(name) needs a value") }
                    guard values.updateValue(arguments[index + 1], forKey: name) == nil else { throw UsageError("--\(name) given twice") }
                    index += 2
                } else { throw UsageError("unknown option --\(name)") }
            }
        }
        func value(_ name: String) -> String? { values[name] }
        func flag(_ name: String) -> Bool { flags.contains(name) }
        func required(_ name: String) throws -> String {
            guard let value = values[name] else { throw UsageError("missing --\(name)") }
            return value
        }
    }
}

private extension String {
    func padded(_ width: Int) -> String { PatchKitText.pad(self, width) }
}
