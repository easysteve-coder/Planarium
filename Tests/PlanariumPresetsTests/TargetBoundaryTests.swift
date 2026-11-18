import Foundation
import XCTest
import PlanariumDomain
@testable import PlanariumPresets
@testable import LegacyPresetTestSupport

final class TargetBoundaryTests: XCTestCase {
    func testLegacyEncodingsMatchBeforeTargetMove() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let v3 = try JSONDecoder().decode(InstrumentPreset.self, from: Data(FrozenPresetFixtures.polarVersion3.utf8))
        let v4 = try JSONDecoder().decode(InstrumentPresetV4.self, from: Data(FrozenPresetV4Fixtures.record.utf8))
        XCTAssertEqual(v3.spatialWorkspace?.detectionConfiguration.virtualMMKMode, .raw)
        for (name, bytes) in [("v3", try encoder.encode(v3)), ("v4", try encoder.encode(v4))] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/TargetBoundary/\(name).json")
            XCTAssertEqual(bytes, try Data(contentsOf: url), name)
        }
    }

    func testAllProductionTargetsHaveOnlyAllowedManifestDependencies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PlanariumManifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        process.arguments = ["swift", "package", "--scratch-path", scratch.path, "dump-package"]; process.currentDirectoryURL = root
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "swift package dump-package failed")
        let violations = try ManifestBoundaries.violations(in: data)
        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    // JSON uses the same target/type/dependency representation as dump-package.
    // Both byName and target spellings must obey the same boundaries.
    private let allowedFixture = #"""
    {"targets":[
      {"name":"SickPLSCore","type":"regular","dependencies":[]},
      {"name":"PLSDeviceValues","type":"regular","dependencies":[{"target":["SickPLSCore",null]}]},
      {"name":"PlanariumDomain","type":"regular","dependencies":[{"byName":["PLSDeviceValues",null]}]},
      {"name":"PlanariumHostClockDSP","type":"regular","dependencies":[]},
      {"name":"PlanariumRuntime","type":"regular","dependencies":[{"byName":["PlanariumDomain",null]},{"target":["PlanariumHostClockDSP",null]}]},
      {"name":"LegacyPresetTestSupport","type":"regular","path":"Tests/LegacyPresetTestSupport","dependencies":[{"byName":["PlanariumDomain",null]}]},
      {"name":"FixtureTests","type":"test","dependencies":[{"byName":["LegacyPresetTestSupport",null]},{"target":["PlanariumRuntime",null]}]}
    ]}
    """#

    func testManifestFixtureAllowsDeviceValuesRuntimeAndTestOnlySupport() throws {
        XCTAssertEqual(try ManifestBoundaries.violations(in: Data(allowedFixture.utf8)), [])
    }

    func testManifestFixtureRejectsDirectUIEdgeWithNamedBoundary() throws {
        let data = Data(#"""
        {"targets":[
          {"name":"PlanariumDomain","type":"regular","dependencies":[{"target":["PlanariumScannerUI",null]}]},
          {"name":"PlanariumScannerUI","type":"regular","dependencies":[]}
        ]}
        """#.utf8)
        XCTAssertEqual(try ManifestBoundaries.violations(in: data), [
            "PlanariumDomain -> PlanariumScannerUI: direct boundary domain -> scannerUI is forbidden"
        ])
    }

    func testManifestFixtureRejectsTransitiveUIEdgeWithFullPath() throws {
        let data = Data(#"""
        {"targets":[
          {"name":"PlanariumRuntime","type":"regular","dependencies":[{"byName":["PlanariumDomain",null]}]},
          {"name":"PlanariumDomain","type":"regular","dependencies":[{"byName":["PlanariumScannerUI",null]}]},
          {"name":"PlanariumScannerUI","type":"regular","dependencies":[]}
        ]}
        """#.utf8)
        XCTAssertEqual(try ManifestBoundaries.violations(in: data), [
            "PlanariumDomain -> PlanariumScannerUI: direct boundary domain -> scannerUI is forbidden",
            "PlanariumRuntime -> PlanariumDomain -> PlanariumScannerUI: transitive boundary runtime -> scannerUI is forbidden"
        ])
    }

    func testSoundModulesCannotReachScannerOrDomain() throws {
        let data = Data(#"""
        {"targets":[
          {"name":"PlanariumMusicCore","type":"regular","dependencies":[]},
          {"name":"SickPLSCore","type":"regular","dependencies":[]},
          {"name":"PLSDeviceValues","type":"regular","dependencies":[{"target":["SickPLSCore",null]}]},
          {"name":"PlanariumDomain","type":"regular","dependencies":[{"byName":["PLSDeviceValues",null]},{"byName":["PlanariumMusicCore",null]}]},
          {"name":"PlanariumSoundCore","type":"regular","dependencies":[{"byName":["PlanariumMusicCore",null]}]},
          {"name":"PlanariumMIDI","type":"regular","dependencies":[{"byName":["PlanariumSoundCore",null]},{"byName":["PlanariumDomain",null]}]}
        ]}
        """#.utf8)
        XCTAssertEqual(try ManifestBoundaries.violations(in: data), [
            "PlanariumMIDI -> PlanariumDomain -> PLSDeviceValues -> SickPLSCore: transitive boundary midi -> deviceCore is forbidden",
            "PlanariumMIDI -> PlanariumDomain -> PLSDeviceValues: transitive boundary midi -> deviceValues is forbidden",
            "PlanariumMIDI -> PlanariumDomain: direct boundary midi -> domain is forbidden"
        ])
    }

    func testManifestFixtureRejectsUnclassifiedProductionTargetByName() throws {
        let data = Data(#"""
        {"targets":[{"name":"NewProductionTarget","type":"regular","dependencies":[]}]}
        """#.utf8)
        XCTAssertEqual(try ManifestBoundaries.violations(in: data), [
            "NewProductionTarget: unclassified production target (regular); assign exactly one role"
        ])
    }

    func testManifestFixtureRejectsProductionReachingTestOrTestSupport() throws {
        for (name, type) in [("LegacyPresetTestSupport", "regular"), ("FixtureTests", "test")] {
            let data = Data("""
            {"targets":[
              {"name":"PlanariumRuntime","type":"regular","dependencies":[{"byName":["PlanariumDomain",null]}]},
              {"name":"PlanariumDomain","type":"regular","dependencies":[{"byName":["\(name)",null]}]},
              {"name":"\(name)","type":"\(type)","dependencies":[]}
            ]}
            """.utf8)
            XCTAssertEqual(try ManifestBoundaries.violations(in: data), [
                "PlanariumDomain -> \(name): production/test boundary forbids test or test-support dependency",
                "PlanariumRuntime -> PlanariumDomain -> \(name): production/test boundary forbids test or test-support dependency"
            ])
        }
    }

    func testManifestFixtureKeepsRXAndTypedTXBoundaries() throws {
        for name in ["SickPLSMacTransport", "PlanariumInput"] {
            let data = Data("""
            {"targets":[
              {"name":"\(name)","type":"regular","dependencies":[{"target":["SickPLSActiveControl",null]}]},
              {"name":"SickPLSActiveControl","type":"regular","dependencies":[]}
            ]}
            """.utf8)
            let role = name == "PlanariumInput" ? "input" : "rxTransport"
            XCTAssertEqual(try ManifestBoundaries.violations(in: data), [
                "\(name) -> SickPLSActiveControl: direct boundary \(role) -> typedTX is forbidden"
            ])
        }
    }

    func testManifestFixtureExceptionsAreEdgesAndDoNotHideDescendants() throws {
        let data = Data(#"""
        {"targets":[
          {"name":"SickPLSMonitorKit","type":"regular","dependencies":[{"byName":["PlanariumInput",null]}]},
          {"name":"PlanariumInput","type":"regular","dependencies":[{"byName":["PlanariumScannerUI",null]}]},
          {"name":"PlanariumScannerUI","type":"regular","dependencies":[]}
        ]}
        """#.utf8)
        XCTAssertEqual(try ManifestBoundaries.violations(in: data), [
            "PlanariumInput -> PlanariumScannerUI: direct boundary input -> scannerUI is forbidden",
            "SickPLSMonitorKit -> PlanariumInput -> PlanariumScannerUI: transitive boundary presentation -> scannerUI is forbidden"
        ])
    }

    func testManifestFixtureRejectsUnknownDependencyAndUnsupportedEncoding() throws {
        let missing = Data(#"""
        {"targets":[{"name":"PlanariumDomain","type":"regular","dependencies":[{"byName":["MissingTarget",null]}]}]}
        """#.utf8)
        XCTAssertEqual(try ManifestBoundaries.violations(in: missing), [
            "PlanariumDomain -> MissingTarget: unresolved dependency; classify the dependency before allowing it"
        ])
        let product = Data(#"""
        {"targets":[{"name":"PlanariumDomain","type":"regular","dependencies":[{"product":["ExternalUI","Package",null,null]}]}]}
        """#.utf8)
        XCTAssertThrowsError(try ManifestBoundaries.violations(in: product)) { error in
            XCTAssertTrue(String(describing: error).contains("PlanariumDomain: unsupported dependency"))
        }
    }
}

/// Source of truth for package boundaries. Framework imports and file-local
/// RX/TX rules remain supplementary source checks: dump-package has no SDK edges.
private enum ManifestBoundaries {
    private enum Role: String {
        case deviceCore, deviceValues, deviceModel, controlValues, rxTransport, typedTX
        case musicCore, soundCore, controllerCore, controllerInput
        case domain, clockDSP, audioSupport, runtime, commissioning, input, audio, midi, presets
        case presentation, commissioningControl, setupControl, simulationLink, simulationBroadcast, simulationControl
        case application, scannerUI, monitorApp, setupApp, diagnosticCLI, presetTool, benchmark, benchmarkCLI
    }

    private struct Rule {
        let role: Role
        let targets: [String]
        let direct: Set<Role>
        let reachable: Set<Role>
    }

    private static let rules: [Rule] = {
        let core: Set<Role> = [.deviceCore]
        let values = core.union([.deviceValues])
        // Scanner-free music values: depend on nothing, reachable from everyone.
        let music: Set<Role> = [.musicCore]
        // Game controller sources know the music core only; no scanner, no sound host.
        // The instrument document stores the controller assignments, so Domain may reach them.
        let controllerSources = music.union([.controllerCore])
        let domain = values.union(controllerSources).union([.domain])
        // The sound core: output routing, scheduling, clocks. No device, input,
        // geometry or document role is reachable from it, nor from audio/MIDI.
        let sound = music.union([.soundCore, .clockDSP])
        let controllerInput = controllerSources.union([.controllerInput])
        let runtime = domain.union(sound).union(controllerSources).union([.runtime])
        let control = values.union([.controlValues])
        let rx = core.union([.rxTransport])
        let tx = rx.union([.typedTX])
        let commissioning = tx.union(values).union([.commissioning])
        let input = runtime.union(commissioning).union([.input])
        // These ceilings include descendants of the two exact exceptions below;
        // they do not authorize other direct edges or stop traversal at an exception.
        let presentation = input.union(control).union([.presentation])
        let commissioningControl = input.union([.commissioningControl])
        let setup = commissioning.union([.setupControl])
        let audio = sound.union([.audio, .audioSupport])
        let midi = sound.union([.midi])
        let presets = domain.union(control).union([.presets])
        let application = audio.union(midi).union(presets).union(presentation).union(controllerInput).union([.application])
        let scannerUI = presentation.union(commissioningControl).union([.scannerUI])
        let simulation = presentation.union([.simulationControl, .simulationLink])
        let benchmark = presentation.union([.benchmark])
        // Role                 Targets                              Direct edges              Reachability ceiling
        return [
            Rule(role: .deviceCore, targets: ["SickPLSCore"], direct: [], reachable: []),
            Rule(role: .deviceValues, targets: ["PLSDeviceValues"], direct: core, reachable: core),
            Rule(role: .deviceModel, targets: ["SickPLSDeviceModel"], direct: core, reachable: core),
            Rule(role: .controlValues, targets: ["SickPLSControlCore"], direct: values, reachable: values),
            Rule(role: .rxTransport, targets: ["SickPLSMacTransport"], direct: core, reachable: core),
            Rule(role: .typedTX, targets: ["SickPLSActiveControl"], direct: rx, reachable: rx),
            Rule(role: .musicCore, targets: ["PlanariumMusicCore"], direct: [], reachable: []),
            Rule(role: .domain, targets: ["PlanariumDomain"], direct: values.union(controllerSources), reachable: values.union(controllerSources)),
            Rule(role: .clockDSP, targets: ["PlanariumHostClockDSP"], direct: [], reachable: []),
            Rule(role: .audioSupport, targets: ["PlanariumFadeDSP", "PlanariumObjCCatch"], direct: [], reachable: []),
            Rule(role: .soundCore, targets: ["PlanariumSoundCore"], direct: [.musicCore, .clockDSP], reachable: sound),
            Rule(role: .controllerCore, targets: ["PlanariumControllerCore"], direct: [.musicCore], reachable: controllerSources),
            Rule(role: .controllerInput, targets: ["PlanariumControllerInput"], direct: controllerSources, reachable: controllerInput),
            Rule(role: .runtime, targets: ["PlanariumRuntime"], direct: [.domain, .clockDSP, .soundCore, .controllerCore], reachable: runtime),
            Rule(role: .commissioning, targets: ["SickPLSCommissioning"], direct: values.union(tx), reachable: commissioning),
            Rule(role: .input, targets: ["PlanariumInput"], direct: [.domain, .runtime, .commissioning, .deviceCore, .rxTransport], reachable: input),
            Rule(role: .audio, targets: ["PlanariumAudio"], direct: [.musicCore, .soundCore, .clockDSP, .audioSupport], reachable: audio),
            Rule(role: .midi, targets: ["PlanariumMIDI"], direct: [.musicCore, .soundCore], reachable: midi),
            Rule(role: .presets, targets: ["PlanariumPresets"], direct: [.domain, .controlValues], reachable: presets),
            Rule(role: .presentation, targets: ["SickPLSMonitorKit"], direct: [.domain, .controlValues, .deviceCore, .rxTransport], reachable: presentation),
            Rule(role: .commissioningControl, targets: ["SickPLSCommissioningControl"], direct: [.input, .typedTX, .commissioning, .deviceCore, .rxTransport], reachable: commissioningControl),
            Rule(role: .setupControl, targets: ["SickPLSSetupControl"], direct: [.typedTX, .commissioning, .deviceCore, .rxTransport], reachable: setup),
            Rule(role: .simulationLink, targets: ["SickPLSSimulationLink"], direct: core, reachable: core),
            Rule(role: .simulationBroadcast, targets: ["SickPLSSimulationBroadcast"], direct: [.deviceCore, .deviceModel, .simulationLink], reachable: [.deviceCore, .deviceModel, .simulationLink]),
            Rule(role: .simulationControl, targets: ["SickPLSSimulationControl"], direct: [.input, .commissioning, .deviceCore, .rxTransport, .simulationLink], reachable: simulation),
            Rule(role: .application, targets: ["PlanariumApplication"], direct: [.audio, .controllerInput, .domain, .input, .midi, .runtime, .controlValues, .deviceCore, .rxTransport, .presentation, .presets], reachable: application),
            Rule(role: .scannerUI, targets: ["PlanariumScannerUI"], direct: [.input, .commissioning, .commissioningControl, .controlValues, .deviceCore, .rxTransport, .presentation], reachable: scannerUI),
            Rule(role: .monitorApp, targets: ["SickPLSMonitor"], direct: [.application, .audio, .controllerInput, .domain, .input, .midi, .presets, .runtime, .scannerUI, .commissioning, .commissioningControl, .controlValues, .deviceCore, .rxTransport, .presentation, .setupControl, .simulationControl, .simulationLink], reachable: application.union(scannerUI).union(setup).union(simulation)),
            Rule(role: .setupApp, targets: ["SickPLSSetup"], direct: [.typedTX, .commissioning, .deviceCore, .rxTransport, .setupControl], reachable: setup),
            Rule(role: .diagnosticCLI, targets: ["SickPLSDiagnosticCLI"], direct: tx, reachable: tx),
            Rule(role: .presetTool, targets: ["PlanariumPresetTool"], direct: [.domain, .presets, .controlValues], reachable: presets),
            Rule(role: .benchmark, targets: ["SickPolarBenchmark"], direct: [.domain, .controlValues, .deviceCore, .presentation], reachable: benchmark),
            Rule(role: .benchmarkCLI, targets: ["SickPolarBenchmarkCLI"], direct: [.controlValues, .deviceCore, .presentation, .benchmark], reachable: benchmark)
        ]
    }()

    private struct Edge: Hashable {
        let from: String
        let to: String
    }

    private static let exceptions: [Edge: String] = [
        Edge(from: "SickPLSMonitorKit", to: "PlanariumInput"):
            "DomainExports.swift re-exports input session values for existing presentation clients; no dependency migration in this slice.",
        Edge(from: "SickPLSSimulationControl", to: "SickPLSMonitorKit"):
            "NetworkScanByteStream uses MeasurementDiagnosticsRecorder; the simulation selector also consumes presentation values."
    ]
    private static let testSupport: Set<String> = ["LegacyPresetTestSupport"]

    private struct Target {
        let name: String
        let type: String
        let dependencies: [String]
        var isTestOnly: Bool { type == "test" || testSupport.contains(name) }
    }

    private struct InvalidManifest: Error, CustomStringConvertible {
        let description: String
    }

    static func violations(in data: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["targets"] as? [[String: Any]] else {
            throw InvalidManifest(description: "dump-package: missing targets array")
        }
        var graph: [String: Target] = [:]
        for entry in entries {
            guard let name = entry["name"] as? String, let type = entry["type"] as? String,
                  let dependencies = entry["dependencies"] as? [[String: Any]] else {
                throw InvalidManifest(description: "dump-package: malformed target \(entry)")
            }
            let names = try dependencies.map { dependency -> String in
                guard dependency.count == 1,
                      let values = (dependency["byName"] ?? dependency["target"]) as? [Any],
                      let name = values.first as? String else {
                    throw InvalidManifest(description: "\(name): unsupported dependency \(dependency); extend classification explicitly")
                }
                return name
            }
            guard graph[name] == nil else { throw InvalidManifest(description: "\(name): duplicate manifest target") }
            graph[name] = Target(name: name, type: type, dependencies: names.sorted())
        }
        var policy: [String: Rule] = [:]
        for rule in rules {
            guard rule.direct.isSubset(of: rule.reachable) else {
                throw InvalidManifest(description: "\(rule.role.rawValue): direct roles exceed the reachability ceiling")
            }
            for name in rule.targets {
                guard policy[name] == nil, !testSupport.contains(name) else {
                    throw InvalidManifest(description: "\(name): duplicate role classification")
                }
                policy[name] = rule
            }
        }
        for (edge, reason) in exceptions {
            guard !reason.isEmpty, let source = policy[edge.from], let destination = policy[edge.to],
                  source.reachable.contains(destination.role) else {
                throw InvalidManifest(description: "\(edge.from) -> \(edge.to): exception needs a reason and an explicit reachability ceiling")
            }
        }
        var result: Set<String> = []
        for target in graph.values.sorted(by: { $0.name < $1.name }) {
            for name in target.dependencies where graph[name] == nil {
                result.insert("\(target.name) -> \(name): unresolved dependency; classify the dependency before allowing it")
            }
            guard !target.isTestOnly else { continue }
            guard let rule = policy[target.name] else {
                result.insert("\(target.name): unclassified production target (\(target.type)); assign exactly one role")
                continue
            }
            // A deterministic breadth-first traversal reports a shortest path to
            // each dependency. Visited nodes bound diamonds and cycles.
            var paths = [[target.name]], visited: Set<String> = [target.name], index = 0
            while index < paths.count {
                let path = paths[index]; index += 1
                guard let current = path.last.flatMap({ graph[$0] }) else { continue }
                for name in current.dependencies {
                    let next = path + [name]
                    let label = next.joined(separator: " -> ")
                    if path.contains(name) {
                        result.insert("\(label): acyclic target boundary is violated")
                        continue
                    }
                    guard let dependency = graph[name], visited.insert(name).inserted else { continue }
                    paths.append(next)
                    if dependency.isTestOnly {
                        result.insert("\(label): production/test boundary forbids test or test-support dependency")
                        continue
                    }
                    guard let dependencyRule = policy[name] else { continue } // Named by the classification pass.
                    if next.count == 2 {
                        let exception = exceptions[Edge(from: target.name, to: name)]
                        if !rule.direct.contains(dependencyRule.role) && exception == nil {
                            result.insert("\(label): direct boundary \(rule.role.rawValue) -> \(dependencyRule.role.rawValue) is forbidden")
                        }
                    } else if !rule.reachable.contains(dependencyRule.role) {
                        result.insert("\(label): transitive boundary \(rule.role.rawValue) -> \(dependencyRule.role.rawValue) is forbidden")
                    }
                }
            }
        }
        return result.sorted()
    }
}
