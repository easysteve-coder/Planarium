import Foundation
import XCTest
import PlanariumDomain
import PLSDeviceValues
@testable import PlanariumPresets

/// Patch Construction Kit: recipes compile through the production domain types
/// and V6 codec; every refusal below names the recipe position that caused it.
final class PatchKitTests: XCTestCase {
    private var directory: URL!
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var evidence: URL { repo.appendingPathComponent("Tests/PlanariumPresetsTests/Fixtures/EaglePatch") }
    private var examples: URL { repo.appendingPathComponent("PatchKit/examples") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PatchKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    // MARK: Fixtures

    /// Synthetic but structurally real state: dictionary with type/subtype/manufacturer.
    private func state(type: UInt32 = 0x61756D75, subtype: UInt32 = 0x74657374, manufacturer: UInt32 = 0x54455354,
                       extra: [String: Any] = ["name": "Untitled", "version": 0, "data": Data([1, 2, 3, 4])]) throws -> Data {
        var dictionary = extra
        dictionary["type"] = Int(type); dictionary["subtype"] = Int(subtype); dictionary["manufacturer"] = Int(manufacturer)
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }
    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name); try data.write(to: url); return url
    }
    private func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    /// Catalog with a synthetic instrument `test.synth`, plus the real measured Eagle delay.
    private var cachedCatalog: URL?
    private func makeCatalog() throws -> URL {
        if let cachedCatalog { return cachedCatalog }
        let catalog = directory.appendingPathComponent("catalog/sounds.json")
        let synth = try file("synth.plist", try state())
        _ = try SoundCatalog.importState(catalog: catalog, state: synth, alias: "test.synth", role: .instrument, description: "synthetic")
        _ = try SoundCatalog.importState(catalog: catalog, state: evidence.appendingPathComponent("delay-eagle-state.plist"),
                                         alias: "apple.delay.eagle", role: .effect, description: "measured")
        cachedCatalog = catalog
        return catalog
    }
    private func recipe(_ json: String) throws -> PatchRecipe { try PatchRecipe.decode(Data(json.utf8)) }
    private func compile(_ json: String, catalog: URL? = nil) throws -> PatchBuild {
        try PatchCompiler.compile(recipe: try recipe(json), catalog: try SoundCatalog.load(from: try catalog ?? makeCatalog()))
    }
    private func expectFailure(_ json: String, contains needle: String, catalog: URL? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try compile(json, catalog: catalog)
            XCTFail("expected a refusal containing “\(needle)”", file: file, line: line)
        } catch let error as PatchKitError {
            XCTAssertTrue(error.description.contains(needle), "“\(needle)” not in: \(error.description)", file: file, line: line)
        } catch { XCTFail("unexpected error \(error)", file: file, line: line) }
    }
    private func band(_ id: String = "a", from: Int = 40, to: Int = 60, note: String = "\"A3\"", channel: String = "ch",
                      color: String = "#D4820A", extra: String = "") -> String {
        "{\"id\":\"\(id)\",\"fromCm\":\(from),\"toCm\":\(to),\"note\":\(note),\"channel\":\"\(channel)\",\"color\":\"\(color)\"\(extra)}"
    }
    private func recipeJSON(bands: [String]? = nil, channel: String = #"{"id":"ch","instrument":"test.synth"}"#,
                            top: String = "") -> String {
        "{\"version\":1,\"name\":\"T\",\(top)\"channels\":[\(channel)],\"bands\":[\(bands?.joined(separator: ",") ?? band())]}"
    }

    // MARK: Notes

    func testNoteNamesAndMIDINumbers() {
        XCTAssertEqual(PatchNoteName.parse("C4"), 60)
        XCTAssertEqual(PatchNoteName.parse("A3"), 57)
        XCTAssertEqual(PatchNoteName.parse("Eb4"), 63)
        XCTAssertEqual(PatchNoteName.parse("C#4"), 61)
        XCTAssertEqual(PatchNoteName.parse("C-1"), 0)
        XCTAssertEqual(PatchNoteName.parse("G9"), 127)
        XCTAssertEqual(PatchNoteName.parse("Cb4"), 59)
        for bad in ["G#9", "H3", "a3", "A", "A10", "A-2", "A03", "", "C 4", "Ab", "C##4", "E♭4"] {
            XCTAssertNil(PatchNoteName.parse(bad), bad)
        }
        XCTAssertEqual(PatchNoteName.name(for: 63), "D#4")
        XCTAssertEqual(PatchNoteToken.number(127).midi, 127)
        XCTAssertNil(PatchNoteToken.number(128).midi)
        XCTAssertNil(PatchNoteToken.number(-1).midi)
    }

    // MARK: Compilation through the production codec

    func testEagleRecipeMatchesSupervisorVerifiedDraftGeometry() throws {
        // The shipped recipe names surge.organ1; here a synthetic alias stands in
        // for the missing organ state, so geometry/delay can be compared to the draft.
        let json = try String(contentsOf: examples.appendingPathComponent("eagle-blues.recipe.json"))
            .replacingOccurrences(of: "surge.organ1", with: "test.synth")
        let build = try compile(json)
        let draft = try PresetV6Codec.decode(try read(evidence.appendingPathComponent("Eagle Organ - A Blues.geometry-draft.sickpreset.json")))
        let partial = try PresetV6Codec.decode(try read(evidence.appendingPathComponent("Eagle Organ - A Blues.partial.sickpreset.json")))
        let mine = build.preset.document.spatial.layers, theirs = draft.document.spatial.layers
        XCTAssertEqual(mine.count, 7)
        XCTAssertEqual(mine.map(\.name), theirs.map(\.name))
        XCTAssertEqual(mine.map(\.cells), theirs.map(\.cells))
        XCTAssertEqual(mine.map(\.color), theirs.map(\.color))
        XCTAssertEqual(mine.flatMap(\.routings).map(\.program), theirs.flatMap(\.routings).map(\.program))
        XCTAssertEqual(Set(mine.flatMap(\.cells)).count, 7 * 20 * 361, "bands are pairwise disjoint")
        XCTAssertEqual(mine.flatMap(\.routings).map { routing -> Int? in
            if case let .chord(notes, _, _) = routing.program { return notes.first } else { return nil }
        }, [57, 60, 62, 63, 64, 67, 69])
        let delay = build.preset.document.channels[0].inserts
        XCTAssertEqual(delay.count, 1)
        XCTAssertEqual(delay[0].plugin.state, try read(evidence.appendingPathComponent("delay-eagle-state.plist")))
        XCTAssertEqual(delay[0].plugin.state, partial.document.channels[0].inserts[0].plugin.state)
        XCTAssertEqual(delay[0].plugin.identity, partial.document.channels[0].inserts[0].plugin.identity)
        XCTAssertEqual(build.preset.document.channels[0].levelDecibels, -9)
    }

    func testBuildIsDeterministicAndReadByProductionReader() throws {
        let catalog = try makeCatalog()
        let json = try String(contentsOf: examples.appendingPathComponent("chord-ladder.recipe.json"))
            .replacingOccurrences(of: "surge.init", with: "test.synth")
        let first = try compile(json, catalog: catalog), second = try compile(json, catalog: catalog)
        XCTAssertEqual(first.data, second.data)
        _ = try PresetDocumentReader.read(first.data).get()
        let decoded = try PresetV6Codec.decode(first.data)
        XCTAssertEqual(decoded, first.preset)
        XCTAssertNoThrow(try InstrumentCompiler.compile(decoded.document))
        let layers = decoded.document.spatial.layers
        XCTAssertEqual(layers.map(\.name), ["Am", "F", "C", "G"])
        XCTAssertEqual(layers[0].cells, Set((40..<80).flatMap { ring in (0...360).map { PolarDeviceLattice(ring: ring, sector: $0)! } }))
        let strip = decoded.document.channels[0]
        XCTAssertEqual(strip.name, "Pad"); XCTAssertEqual(strip.levelDecibels, -12)
        XCTAssertEqual(strip.id, decoded.document.channels[0].id)
        for (layer, expected) in zip(layers, [([57, 60, 64], 72), ([53, 57, 60], 72), ([60, 64, 67], 72), ([55, 59, 62], 90)]) {
            XCTAssertEqual(layer.routings.count, 1)
            XCTAssertEqual(layer.routings[0].program, .chord(notes: expected.0, velocity: UInt8(expected.1), transition: .legato))
            XCTAssertEqual(layer.routings[0].target, .audioUnitNote(channel: 0, stripID: strip.id))
        }
    }

    func testDefaultsAreConservative() throws {
        let build = try compile(recipeJSON())
        XCTAssertEqual(build.preset.document.channels[0].levelDecibels, -9)
        guard case let .chord(_, velocity, transition) = build.preset.document.spatial.layers[0].routings[0].program else { return XCTFail() }
        XCTAssertEqual(velocity, 80); XCTAssertEqual(transition, .legato)
    }

    func testOneChannelCanCarryManyBandsAndChannelsAreIndependent() throws {
        let catalog = try makeCatalog()
        let json = """
        {"version":1,"name":"Two","channels":[{"id":"a","instrument":"test.synth"},{"id":"b","instrument":"test.synth","effects":["apple.delay.eagle"],"levelDb":-6}],
         "bands":[\(band("x", from: 40, to: 60, channel: "a")),\(band("y", from: 60, to: 80, note: "62", channel: "a")),\(band("z", from: 50, to: 70, note: "\"E4\"", channel: "b"))]}
        """
        let build = try compile(json, catalog: catalog)
        let channels = build.preset.document.channels
        XCTAssertEqual(channels.count, 2); XCTAssertNotEqual(channels[0].id, channels[1].id)
        XCTAssertEqual(channels[1].inserts.count, 1); XCTAssertEqual(channels[0].inserts.count, 0)
        let targets = build.preset.document.spatial.layers.map { $0.routings[0].target }
        XCTAssertEqual(targets, [.audioUnitNote(channel: 0, stripID: channels[0].id), .audioUnitNote(channel: 0, stripID: channels[0].id),
                                 .audioUnitNote(channel: 0, stripID: channels[1].id)])
        XCTAssertTrue(build.plan.notices.contains { $0.contains("\"x\"") == false && $0.contains("\"z\"") && $0.contains("different channels") })
    }

    func testGapsAreReportedNotFilled() throws {
        let build = try compile(recipeJSON(bands: [band("a", from: 40, to: 60), band("b", from: 80, to: 100, note: "\"C4\"")]))
        XCTAssertTrue(build.plan.notices.contains { $0.contains("60–80 cm") && $0.contains("\"a\"") && $0.contains("\"b\"") })
        let covered = Set(build.preset.document.spatial.layers.flatMap(\.cells).map(\.ring))
        XCTAssertFalse(covered.contains(70))
        XCTAssertEqual(build.plan.bands.map(\.cells), [20 * 361, 20 * 361])
    }

    func testAdjacentBandsAreHalfOpen() throws {
        let build = try compile(recipeJSON(bands: [band("a", from: 40, to: 60), band("b", from: 60, to: 80, note: "\"C4\"")]))
        let layers = build.preset.document.spatial.layers
        XCTAssertTrue(layers[0].cells.isDisjoint(with: layers[1].cells))
        XCTAssertEqual(layers[0].cells.map(\.ring).max(), 59); XCTAssertEqual(layers[1].cells.map(\.ring).min(), 60)
    }

    // MARK: Recipe refusals

    func testUnknownFieldsFailVisibly() {
        expectFailure(recipeJSON(top: #""colour":1,"#), contains: "unknown field \"colour\"")
        expectFailure(recipeJSON(bands: [band(extra: #","tolerance":3"#)]), contains: "unknown field \"tolerance\" at bands[0]")
        expectFailure(recipeJSON(channel: #"{"id":"ch","instrument":"test.synth","pan":1}"#), contains: "unknown field \"pan\"")
    }
    func testMissingAndWrongKindsFail() {
        expectFailure(#"{"version":1,"name":"T","channels":[],"bands":[]}"#, contains: "channels: need 1–8")
        expectFailure(#"{"version":1,"channels":[],"bands":[]}"#, contains: "missing field \"name\"")
        expectFailure(recipeJSON(bands: [band(from: 40, to: 60).replacingOccurrences(of: "40", with: "40.5")]), contains: "bands[0].fromCm")
        expectFailure(recipeJSON(bands: [band(note: "60.5")]), contains: "bands[0]")
        expectFailure(recipeJSON(bands: [band(note: "true")]), contains: "bands[0]")
        expectFailure("not json at all", contains: "not valid JSON")
        expectFailure(#"{"version":3,"name":"T","channels":[],"bands":[]}"#, contains: "unsupported recipe version 3")
        expectFailure(recipeJSON(top: #""mode":"arpeggio","#), contains: "unsupported mode")
        expectFailure(recipeJSON(bands: [##"{"id":"a","fromCm":40,"toCm":60,"channel":"ch","color":"#D4820A"}"##]), contains: "exactly one of")
        expectFailure(recipeJSON(bands: [band(extra: #","notes":["A3"]"#)]), contains: "exactly one of")
    }
    func testNotesDistancesColorsAndLevelsAreChecked() {
        expectFailure(recipeJSON(bands: [band(note: "\"G#9\"")]), contains: "not a defined note")
        expectFailure(recipeJSON(bands: [band(note: "128")]), contains: "not a defined note")
        expectFailure(recipeJSON(bands: [band(note: "-1")]), contains: "not a defined note")
        expectFailure(recipeJSON(bands: [band(note: "\"a3\"")]), contains: "not a defined note")
        expectFailure(recipeJSON(bands: [band(from: -5, to: 20)]), contains: "invalid")
        expectFailure(recipeJSON(bands: [band(from: 40, to: 201)]), contains: "<= 200")
        expectFailure(recipeJSON(bands: [band(from: 60, to: 60)]), contains: "fromCm < toCm")
        expectFailure(recipeJSON(bands: [band(color: "D4820A")]), contains: "#D4820A")
        expectFailure(recipeJSON(bands: [band(color: "#D4820G")]), contains: "#D4820A")
        expectFailure(recipeJSON(bands: [band(extra: #","velocity":0"#)]), contains: "velocity 0")
        expectFailure(recipeJSON(top: #""velocity":128,"#), contains: "velocity 128")
        expectFailure(recipeJSON(channel: #"{"id":"ch","instrument":"test.synth","levelDb":7}"#), contains: "levelDb")
        expectFailure(recipeJSON(channel: #"{"id":"ch","instrument":"test.synth","levelDb":1e999}"#), contains: "channels[0].levelDb")
        expectFailure(recipeJSON(bands: [band(note: "[\"A3\"]")]), contains: "bands[0]")
        expectFailure(recipeJSON(bands: [band(extra: ",\"notes\":null").replacingOccurrences(of: "\"note\":\"A3\"", with: "\"n\":1")]), contains: "unknown field")
    }
    func testIdentityAndReferenceErrors() {
        expectFailure(recipeJSON(bands: [band("a"), band("a", from: 60, to: 80)]), contains: "duplicate band id")
        expectFailure(recipeJSON(bands: [band(channel: "nope")]), contains: "channel \"nope\" is not defined")
        expectFailure(recipeJSON(channel: #"{"id":"ch","instrument":"test.synth"},{"id":"ch","instrument":"test.synth"}"#), contains: "duplicate channel id")
        expectFailure(recipeJSON(bands: [band("bad id")]), contains: "must be 1–48")
        expectFailure(recipeJSON(bands: [band(extra: #","notes":["A3"]"#)]), contains: "exactly one")
        expectFailure(recipeJSON(bands: [##"{"id":"a","fromCm":40,"toCm":60,"notes":["A3","A3"],"channel":"ch","color":"#D4820A"}"##]), contains: "listed twice")
        expectFailure(recipeJSON(bands: [##"{"id":"a","fromCm":40,"toCm":60,"notes":[],"channel":"ch","color":"#D4820A"}"##]), contains: "need 1–12 notes")
    }
    func testOverlapOnSameChannelNamesBothBandsButOtherChannelsMayLayer() {
        expectFailure(recipeJSON(bands: [band("a", from: 40, to: 70), band("b", from: 60, to: 80, note: "\"C4\"")]),
                      contains: "bands \"a\" (40–70 cm) and \"b\" (60–80 cm) overlap on channel \"ch\"")
        expectFailure(recipeJSON(bands: [band("a", from: 40, to: 80), band("b", from: 50, to: 60, note: "\"C4\"")]), contains: "overlap")
    }

    // MARK: Sound refusals

    func testMissingOrganAliasFailsWithoutSubstitute() throws {
        let json = try String(contentsOf: examples.appendingPathComponent("eagle-blues.recipe.json"))
        do {
            _ = try compile(json)
            XCTFail("the Eagle recipe must not build without a surge.organ1 state")
        } catch let error as PatchKitError {
            XCTAssertTrue(error.description.contains("\"surge.organ1\" is not in the catalog"), error.description)
            XCTAssertTrue(error.description.contains("No default or stand-in sound"), error.description)
        }
        // even when a demo InitSaw alias exists, organ1 never resolves to it
        let catalog = try makeCatalog()
        _ = try SoundCatalog.importState(catalog: catalog, state: try file("init.plist", try state()), alias: "surge.init", role: .instrument, description: "")
        expectFailure(json, contains: "\"surge.organ1\" is not in the catalog", catalog: catalog)
    }

    func testDamagedAndMismatchedStatesFail() throws {
        func catalog(withState data: Data, role: SoundCatalog.Role = .instrument) throws -> URL {
            let folder = directory.appendingPathComponent("bad-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("states"), withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("states/s.plist"))
            let url = folder.appendingPathComponent("sounds.json")
            try Data("{\"version\":1,\"sounds\":[{\"alias\":\"test.synth\",\"role\":\"\(role.rawValue)\",\"state\":\"states/s.plist\"}]}".utf8).write(to: url)
            return url
        }
        let json = recipeJSON()
        expectFailure(json, contains: "state file is empty", catalog: try catalog(withState: Data()))
        expectFailure(json, contains: "not a property-list dictionary", catalog: try catalog(withState: Data("garbage bytes".utf8)))
        expectFailure(json, contains: "not a property-list dictionary",
                      catalog: try catalog(withState: try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .binary, options: 0)))
        expectFailure(json, contains: "state dictionary is empty",
                      catalog: try catalog(withState: try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)))
        expectFailure(json, contains: "no usable integer \"type\"",
                      catalog: try catalog(withState: try PropertyListSerialization.data(fromPropertyList: ["data": Data([1])], format: .binary, options: 0)))
        expectFailure(json, contains: "no usable integer \"subtype\"",
                      catalog: try catalog(withState: try PropertyListSerialization.data(fromPropertyList: ["type": 1, "subtype": "x", "manufacturer": 3], format: .binary, options: 0)))
        expectFailure(json, contains: "no usable integer \"manufacturer\"",
                      catalog: try catalog(withState: try PropertyListSerialization.data(fromPropertyList: ["type": 1, "subtype": 2, "manufacturer": true], format: .binary, options: 0)))
        // identity contradicts the declared role
        expectFailure(json, contains: "declared as instrument but the state identity is aufx",
                      catalog: try catalog(withState: try state(type: 0x61756678)))
        expectFailure(json, contains: "declared as effect but the state identity is aumu",
                      catalog: try catalog(withState: try state(), role: .effect))
        // a used effect that is registered as an instrument
        let wrongRole = recipeJSON(channel: #"{"id":"ch","instrument":"test.synth","effects":["test.synth"]}"#)
        expectFailure(wrongRole, contains: "is an instrument in the catalog but is used as an effect")
        // state file removed after import
        let good = try makeCatalog()
        try FileManager.default.removeItem(at: good.deletingLastPathComponent().appendingPathComponent("states/test.synth.plist"))
        expectFailure(json, contains: "state file \"states/test.synth.plist\" is missing", catalog: good)
    }

    func testIdentityOnlyAndEmptyPayloadStatesAreRefusedByImportAndResolve() throws {
        let identity: [String: Any] = ["name": "Organ 1", "version": 0]
        let cases: [(String, [String: Any])] = [
            ("metadata only", identity),
            ("empty data", identity.merging(["data": Data()]) { $1 }),
            ("empty juce", identity.merging(["jucePluginState": Data()]) { $1 }),
            ("empty juce beside real data", identity.merging(["data": Data([1]), "jucePluginState": Data()]) { $1 }),
            ("data of wrong kind", identity.merging(["data": "text"]) { $1 }),
        ]
        for (label, extra) in cases {
            let source = try file("p.plist", try state(extra: extra))
            let catalog = directory.appendingPathComponent("payload-\(UUID().uuidString)/sounds.json")
            do {
                _ = try SoundCatalog.importState(catalog: catalog, state: source, alias: "fake.organ", role: .instrument, description: "")
                XCTFail("\(label): import must refuse a state without sound payload")
            } catch let error as PatchKitError {
                XCTAssertTrue(error.description.contains("sound payload"), "\(label): \(error.description)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: catalog.path), "\(label): nothing registered")
            // resolve path: the same checker sees a hand-placed state file
            let folder = catalog.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("states"), withIntermediateDirectories: true)
            try read(source).write(to: folder.appendingPathComponent("states/s.plist"))
            try Data(#"{"version":1,"sounds":[{"alias":"test.synth","role":"instrument","state":"states/s.plist"}]}"#.utf8).write(to: catalog)
            expectFailure(recipeJSON(), contains: "sound payload", catalog: catalog)
        }
        // supported shapes stay valid: Apple "data" and Surge "jucePluginState"
        let juce = try state(extra: ["name": "Untitled", "jucePluginState": Data([9, 9])])
        XCTAssertNoThrow(try SoundCatalog.inspect(state: juce, alias: "x", role: .instrument))
    }

    func testBuildForceNeverOverwritesAnyCatalogStateFileEvenUnused() throws {
        let catalog = try makeCatalog()
        let folder = catalog.deletingLastPathComponent()
        // legal but unusual state name of an alias the recipe does not use
        let unused = folder.appendingPathComponent("states/stored-state.sickpreset.json")
        try state(type: 0x61756678).write(to: unused)
        var wire = try JSONSerialization.jsonObject(with: read(catalog)) as! [String: Any]
        var sounds = wire["sounds"] as! [[String: Any]]
        sounds.append(["alias": "unused.delay", "role": "effect", "state": "states/stored-state.sickpreset.json"])
        wire["sounds"] = sounds
        try JSONSerialization.data(withJSONObject: wire).write(to: catalog)
        let recipeURL = try file("r.json", Data(recipeJSON().utf8))
        let before = try read(unused), catalogBefore = try read(catalog)
        let direct = kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", unused.path, "--force"])
        XCTAssertEqual(direct.code, 1, direct.err); XCTAssertTrue(direct.err.contains("overwrite an input"), direct.err)
        XCTAssertEqual(try read(unused), before)
        // via a symbolic link to it
        let link = directory.appendingPathComponent("alias.sickpreset.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unused)
        XCTAssertEqual(kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", link.path, "--force"]).code, 1)
        XCTAssertEqual(try read(unused), before)
        XCTAssertEqual(try read(catalog), catalogBefore)
        // a missing/defective unused sound still does not block a normal build
        try FileManager.default.removeItem(at: unused)
        let ok = directory.appendingPathComponent("fine.sickpreset.json")
        XCTAssertEqual(kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", ok.path]).code, 0)
        // ...but a not-yet-existing catalog state path is protected as well
        XCTAssertEqual(kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", unused.path]).code, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
    }

    // MARK: Catalog

    func testCatalogRejectsEscapesDuplicatesAndUnknownFields() throws {
        func load(_ text: String) throws { let url = try file("c-\(UUID().uuidString).json", Data(text.utf8)); _ = try SoundCatalog.load(from: url) }
        func entry(_ state: String, alias: String = "x") -> String {
            "{\"version\":1,\"sounds\":[{\"alias\":\"\(alias)\",\"role\":\"effect\",\"state\":\"\(state)\"}]}"
        }
        for bad in ["../x.plist", "/etc/passwd", "~/x.plist", "a/../../x.plist", "a//b.plist", "./x.plist", "a\\\\b.plist", ""] {
            XCTAssertThrowsError(try load(entry(bad)), bad) { XCTAssertTrue("\($0)".contains("state path"), "\($0)") }
        }
        XCTAssertThrowsError(try load(#"{"version":1,"sounds":[{"alias":"x","role":"effect","state":"a.plist"},{"alias":"x","role":"effect","state":"b.plist"}]}"#)) {
            XCTAssertTrue("\($0)".contains("duplicate alias"))
        }
        XCTAssertThrowsError(try load(#"{"version":1,"sounds":[{"alias":"x","role":"effect","state":"a.plist"},{"alias":"y","role":"effect","state":"a.plist"}]}"#))
        XCTAssertThrowsError(try load(#"{"version":1,"sounds":[{"alias":"x","role":"effect","state":"a.plist","volume":1}]}"#)) {
            XCTAssertTrue("\($0)".contains("unknown field \"volume\""))
        }
        XCTAssertThrowsError(try load(#"{"version":1,"sounds":[{"alias":"x","role":"synth","state":"a.plist"}]}"#))
        XCTAssertThrowsError(try load(#"{"version":3,"sounds":[]}"#))
        XCTAssertThrowsError(try load(#"{"sounds":[]}"#))
        XCTAssertThrowsError(try load(entry("a.plist", alias: "no good")))
    }

    func testStateSymlinkCannotEscapeCatalogFolder() throws {
        let outside = try file("outside.plist", try state())
        let folder = directory.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("s.plist"), withDestinationURL: outside)
        let url = folder.appendingPathComponent("sounds.json")
        try Data(#"{"version":1,"sounds":[{"alias":"test.synth","role":"instrument","state":"s.plist"}]}"#.utf8).write(to: url)
        expectFailure(recipeJSON(), contains: "resolves outside the catalog folder", catalog: url)
    }

    func testImportNeverOverwritesAndLeavesNoDebris() throws {
        let catalog = try makeCatalog()
        let folder = catalog.deletingLastPathComponent()
        let catalogBytes = try read(catalog), stateBytes = try read(folder.appendingPathComponent("states/test.synth.plist"))
        let other = try file("other.plist", try state(subtype: 0x6F746872))
        XCTAssertThrowsError(try SoundCatalog.importState(catalog: catalog, state: other, alias: "test.synth", role: .instrument, description: "")) {
            XCTAssertTrue("\($0)".contains("already exists in the catalog"))
        }
        XCTAssertEqual(try read(catalog), catalogBytes)
        XCTAssertEqual(try read(folder.appendingPathComponent("states/test.synth.plist")), stateBytes)
        // stray state file with the new alias' name
        try Data("stray".utf8).write(to: folder.appendingPathComponent("states/new.sound.plist"))
        XCTAssertThrowsError(try SoundCatalog.importState(catalog: catalog, state: other, alias: "new.sound", role: .instrument, description: "")) {
            XCTAssertTrue("\($0)".contains("already exists next to the catalog"))
        }
        XCTAssertEqual(try read(folder.appendingPathComponent("states/new.sound.plist")), Data("stray".utf8))
        XCTAssertEqual(try read(catalog), catalogBytes)
        // damaged and role-contradicting sources create nothing
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("states").path).sorted()
        for (name, data, role) in [("e", Data(), SoundCatalog.Role.instrument), ("g", Data("junk".utf8), .instrument), ("r", try state(), .effect)] {
            XCTAssertThrowsError(try SoundCatalog.importState(catalog: catalog, state: try file("\(name).plist", data), alias: "bad.\(name)", role: role, description: ""))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("states").path).sorted(), before)
        XCTAssertEqual(try read(catalog), catalogBytes)
        // success keeps the source untouched and the stored state byte-identical
        let source = evidence.appendingPathComponent("delay-eagle-state.plist"), sourceBytes = try read(source)
        let receipt = try SoundCatalog.importState(catalog: catalog, state: source, alias: "delay.again", role: .effect, description: "copy")
        XCTAssertEqual(receipt.stateBytes, 183); XCTAssertEqual(receipt.identityText, "aufx/dely/appl")
        XCTAssertEqual(try read(folder.appendingPathComponent("states/delay.again.plist")), sourceBytes)
        XCTAssertEqual(try read(source), sourceBytes)
        let reloaded = try SoundCatalog.load(from: catalog)
        XCTAssertEqual(reloaded.entries.map(\.alias), ["test.synth", "apple.delay.eagle", "delay.again"])
    }

    func testRealMeasuredStatesResolveWithTheirIdentities() throws {
        let catalog = directory.appendingPathComponent("real/sounds.json")
        _ = try SoundCatalog.importState(catalog: catalog, state: evidence.appendingPathComponent("surge-default-state.plist"),
                                         alias: "surge.init", role: .instrument, description: "demo")
        _ = try SoundCatalog.importState(catalog: catalog, state: evidence.appendingPathComponent("delay-eagle-state.plist"),
                                         alias: "apple.delay.eagle", role: .effect, description: "delay")
        let loaded = try SoundCatalog.load(from: catalog)
        XCTAssertEqual(try loaded.resolve("surge.init").identityText, "aumu/SgXT/VmbA")
        XCTAssertEqual(try loaded.resolve("surge.init").state.count, 56_812)
        XCTAssertEqual(try loaded.resolve("apple.delay.eagle").identityText, "aufx/dely/appl")
        XCTAssertEqual(loaded.inspectAll().filter { if case .failure = $0.result { return true } else { return false } }.count, 0)
    }

    // MARK: Command line behavior

    private struct Run { var code: Int32; var out: String; var err: String }
    private func kit(_ arguments: [String]) -> Run {
        var out = "", err = ""
        let code = PatchKitCommand.run(arguments, out: { out += $0 }, err: { err += $0 })
        return Run(code: code, out: out, err: err)
    }

    func testBuildCheckAndOverwriteBehavior() throws {
        let catalog = try makeCatalog()
        let recipeURL = try file("r.json", Data(recipeJSON().utf8))
        let recipeBytes = try read(recipeURL), catalogBytes = try read(catalog)
        let output = directory.appendingPathComponent("out.sickpreset.json")
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let checked = kit(["check", "--recipe", recipeURL.path, "--catalog", catalog.path])
        XCTAssertEqual(checked.code, 0, checked.err); XCTAssertTrue(checked.out.contains("Check passed"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before, "check writes nothing")
        let built = kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", output.path])
        XCTAssertEqual(built.code, 0, built.err)
        let first = try read(output)
        XCTAssertEqual(first, try compile(recipeJSON(), catalog: catalog).data)
        // existing output is kept without --force
        try Data("precious".utf8).write(to: output)
        let refused = kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", output.path])
        XCTAssertEqual(refused.code, 1); XCTAssertTrue(refused.err.contains("--force"))
        XCTAssertEqual(try read(output), Data("precious".utf8))
        let forced = kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", output.path, "--force"])
        XCTAssertEqual(forced.code, 0, forced.err); XCTAssertEqual(try read(output), first)
        // a failing build leaves an existing output untouched, even with --force
        let broken = try file("broken.json", Data(recipeJSON(top: #""oops":1,"#).utf8))
        XCTAssertEqual(kit(["build", "--recipe", broken.path, "--catalog", catalog.path, "--out", output.path, "--force"]).code, 1)
        XCTAssertEqual(try read(output), first)
        // inputs never change and are never valid outputs
        XCTAssertEqual(try read(recipeURL), recipeBytes); XCTAssertEqual(try read(catalog), catalogBytes)
        let asRecipe = directory.appendingPathComponent("same.sickpreset.json")
        let recipeAsOutput = try file("same.sickpreset.json", Data(recipeJSON().utf8))
        let selfWrite = kit(["build", "--recipe", recipeAsOutput.path, "--catalog", catalog.path, "--out", asRecipe.path, "--force"])
        XCTAssertEqual(selfWrite.code, 1); XCTAssertTrue(selfWrite.err.contains("overwrite an input"))
        XCTAssertEqual(try read(recipeAsOutput), Data(recipeJSON().utf8))
        let stateAsOutput = catalog.deletingLastPathComponent().appendingPathComponent("states/test.synth.plist")
        XCTAssertEqual(kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", stateAsOutput.path, "--force"]).code, 1)
        XCTAssertEqual(kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", directory.appendingPathComponent("plain.json").path]).code, 1)
        XCTAssertEqual(kit(["build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", directory.appendingPathComponent("nofolder/x.sickpreset.json").path]).code, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }, [], "no temporary files remain")
    }

    func testUsageErrorsAndSoundsListing() throws {
        let catalog = try makeCatalog()
        XCTAssertEqual(kit([]).code, 2)
        XCTAssertEqual(kit(["frobnicate"]).code, 2)
        XCTAssertEqual(kit(["check", "--recipe"]).code, 2)
        XCTAssertEqual(kit(["check", "--recipe", "a", "--recipe", "b", "--catalog", "c"]).code, 2)
        XCTAssertEqual(kit(["check", "--recipe", "a", "--catalog", "c", "--force"]).code, 2)
        XCTAssertEqual(kit(["build", "--recipe", "a", "--catalog", "c"]).code, 2)
        XCTAssertEqual(kit(["help"]).code, 0)
        XCTAssertEqual(kit(["check", "--recipe", "/nonexistent/r.json", "--catalog", catalog.path]).code, 1)
        let listing = kit(["sounds", "--catalog", catalog.path])
        XCTAssertEqual(listing.code, 0, listing.err)
        XCTAssertTrue(listing.out.contains("test.synth") && listing.out.contains("aumu/test/TEST") && listing.out.contains("aufx/dely/appl") && listing.out.contains("183 B"), listing.out)
        try FileManager.default.removeItem(at: catalog.deletingLastPathComponent().appendingPathComponent("states/test.synth.plist"))
        let degraded = kit(["sounds", "--catalog", catalog.path])
        XCTAssertEqual(degraded.code, 1); XCTAssertTrue(degraded.out.contains("UNUSABLE"))
        let imported = kit(["import-state", "--catalog", catalog.path, "--state", evidence.appendingPathComponent("delay-eagle-state.plist").path,
                            "--alias", "delay.two", "--role", "effect", "--description", "second"])
        XCTAssertEqual(imported.code, 0, imported.err)
        XCTAssertEqual(kit(["import-state", "--catalog", catalog.path, "--state", "x", "--alias", "a", "--role", "synth"]).code, 2)
    }

    func testErrorsAndListingsNeverEchoStateContents() throws {
        let marker = "SECRET-MARKER-9F3A"
        let folder = directory.appendingPathComponent("leak")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("states"), withIntermediateDirectories: true)
        let hostile = try PropertyListSerialization.data(fromPropertyList: ["type": "\(marker)", "note": marker, "data": Data(marker.utf8)], format: .xml, options: 0)
        try hostile.write(to: folder.appendingPathComponent("states/s.plist"))
        let url = folder.appendingPathComponent("sounds.json")
        try Data(#"{"version":1,"sounds":[{"alias":"test.synth","role":"instrument","state":"states/s.plist"}]}"#.utf8).write(to: url)
        let recipeURL = try file("r.json", Data(recipeJSON().utf8))
        for arguments in [["check", "--recipe", recipeURL.path, "--catalog", url.path], ["sounds", "--catalog", url.path],
                          ["import-state", "--catalog", directory.appendingPathComponent("n/sounds.json").path, "--state", folder.appendingPathComponent("states/s.plist").path,
                           "--alias", "x", "--role", "instrument"]] {
            let result = kit(arguments)
            XCTAssertNotEqual(result.code, 0)
            XCTAssertFalse((result.out + result.err).contains(marker), "\(arguments[0]) leaked state content")
            XCTAssertFalse((result.out + result.err).contains(Data(marker.utf8).base64EncodedString()))
        }
        // a recipe typo is quoted back, but never any file content
        let typo = kit(["check", "--recipe", try file("t.json", Data(recipeJSON(top: "\"\(marker)\":1,").utf8)).path, "--catalog", url.path])
        XCTAssertEqual(typo.code, 1)
    }

    func testShippedExamplesBuildAndEagleBluesNeedsRealOrgan() throws {
        let catalog = directory.appendingPathComponent("demo/sounds.json")
        _ = try SoundCatalog.importState(catalog: catalog, state: evidence.appendingPathComponent("delay-eagle-state.plist"), alias: "apple.delay.eagle", role: .effect, description: "")
        _ = try SoundCatalog.importState(catalog: catalog, state: evidence.appendingPathComponent("surge-default-state.plist"), alias: "surge.init", role: .instrument, description: "")
        for name in ["simple-three-bands", "chord-ladder"] {
            let output = directory.appendingPathComponent("\(name).sickpreset.json")
            let result = kit(["build", "--recipe", examples.appendingPathComponent("\(name).recipe.json").path, "--catalog", catalog.path, "--out", output.path])
            XCTAssertEqual(result.code, 0, result.err)
            _ = try PresetDocumentReader.read(try read(output)).get()
        }
        let eagle = kit(["check", "--recipe", examples.appendingPathComponent("eagle-blues.recipe.json").path, "--catalog", catalog.path])
        XCTAssertEqual(eagle.code, 1); XCTAssertTrue(eagle.err.contains("surge.organ1"))
    }

    func testRealToolBinaryExitCodesAndLegacyCommands() throws {
        let tool = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("planarium-preset-tool")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            return XCTFail("planarium-preset-tool is not built next to the test bundle (\(tool.path)); run swift build --build-tests")
        }
        func run(_ arguments: [String], input: Data? = nil) throws -> (Int32, Data, Data) {
            let process = Process(); process.executableURL = tool; process.arguments = arguments
            let out = Pipe(), err = Pipe(), inPipe = Pipe()
            process.standardOutput = out; process.standardError = err; process.standardInput = inPipe
            try process.run()
            if let input { inPipe.fileHandleForWriting.write(input) }
            inPipe.fileHandleForWriting.closeFile()
            let outData = out.fileHandleForReading.readDataToEndOfFile(), errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, outData, errData)
        }
        let catalog = try makeCatalog()
        let recipeURL = try file("r.json", Data(recipeJSON().utf8))
        let output = directory.appendingPathComponent("o.sickpreset.json")
        XCTAssertEqual(try run(["kit", "build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", output.path]).0, 0)
        XCTAssertEqual(try read(output), try compile(recipeJSON(), catalog: catalog).data)
        XCTAssertEqual(try run(["kit", "build", "--recipe", recipeURL.path, "--catalog", catalog.path, "--out", output.path]).0, 1)
        XCTAssertEqual(try run(["kit", "nonsense"]).0, 2)
        // legacy commands keep working: convert reads the new V6 file, cells still prints its legacy pairs
        let converted = try run(["convert"], input: try read(output))
        XCTAssertEqual(converted.0, 0)
        _ = try PresetDocumentReader.read(converted.1).get()
        let cells = try run(["cells", "0.05", "1.0", "1.1", "-10", "10"])
        XCTAssertEqual(cells.0, 0); XCTAssertFalse(cells.1.isEmpty)
        XCTAssertEqual(try run(["frobnicate"]).0, 1)
        let help = try run(["help"])
        XCTAssertTrue(String(decoding: help.1, as: UTF8.self).contains("NOT canonical V6 cells"))
    }
}
