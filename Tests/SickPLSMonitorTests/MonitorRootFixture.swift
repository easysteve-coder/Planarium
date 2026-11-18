import Foundation
import SickPLSMacTransport
import PlanariumApplication
import PlanariumAudio
import PlanariumDomain
import PlanariumMIDI
import PlanariumRuntime
import PlanariumPresets
import AppKit

@MainActor final class MonitorNoMIDI: MIDIConnectionBoundary {
    var onDestinationLost: (@MainActor () -> Void)?
    func destinations() -> [MIDITargetDescription] { [] }
    func open(_ target: InstrumentMIDITarget) -> Result<any MIDISendBoundary, MIDIConnectionError> { .failure(.init("Test destination unavailable")) }
    func close() {}
}
@MainActor final class MonitorNoPlugins: PluginComponentSource {
    func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) { completion(.failure(.init("Test component unavailable"))) }
}
final class EmptyCatalog: AudioUnitComponentSource {
    func effectComponentDescriptions() -> [AudioUnitComponentDescription] { [] }
}
@MainActor struct MonitorRootFixture {
    let root: PlanariumComposition
    init(scanner: any SerialPortOpener = DarwinSerialPortOpener(), components: (any PluginComponentSource)? = nil, graph: MonitorGraph? = nil,
         clock: any RuntimeClock = MonotonicRuntimeClock(), midi: (any MIDIConnectionBoundary)? = nil,
         clockSourceFactory: @escaping MIDIClockSourceFactory = { _, _, _ in nil }, usesProductionGrid: Bool = false,
         surfaceEditor: Bool = false) throws {
        root = try .init(scanner: scanner, midi: midi ?? MonitorNoMIDI(), components: components ?? MonitorNoPlugins(), clock: clock, configuration: .init(offline: true),
                         graph: graph ?? MonitorGraph(), windows: MonitorWindows(), clockSourceFactory: clockSourceFactory,
                         initialWorkspace: usesProductionGrid ? nil : SpatialInstrumentWorkspace(grid: .quarterMeter))
        // Historical geometry fixtures specify 25 cm; production starts at 5 cm.
        // Tests of the production default opt in without injecting a workspace.
        // Inspector tests declare their own origin; a user's per-device app
        // preference must neither alter their fixture nor be written by a test.
        // The historical cell fixtures run in the advanced cell editor; the surface editor is opted into.
        if !surfaceEditor { root.document.surfaceEditor.setMode(.cells) }
        root.document.canvas.programCountingPreference = { _ in true }
        root.document.canvas.rememberProgramCounting = { _, _ in }
    }
}
@MainActor final class MonitorGraph: MixerGraphBoundary {
    func makeChannelGraph() -> any AudioGraphBoundary { MonitorGraph() }
    func setMasterLevel(decibels: Double) {}
    var masterMeter: PeakHolder?
    func installMasterMeter(_ holder: PeakHolder) { masterMeter = holder }
    func removeMasterMeter() { masterMeter = nil }
    func fade(silent: Bool) -> UInt32 { 0 }
    func fadeReached(_ token: UInt32) -> Bool { true }
    func setMuted(_ muted: Bool) {}
    var permitsStart = false
    var starts = 0
    var configurationFailure: PluginLoadError?
    var meter: PeakHolder?
    func installMeter(_ holder: PeakHolder) { meter = holder }
    func removeMeter() { meter = nil }
    func configure(_ configuration: AudioHostConfiguration) throws {
        if let configurationFailure { throw configurationFailure }
    }
    func attach(_ instance: PluginInstance, instrument: Bool) throws {}
    func remove(_ instance: PluginInstance) {}
    @discardableResult func connect(instrument: PluginInstance?, inserts: [PluginInstance]) -> AudioGraphConnectionResult { .init() }
    func setLevel(decibels: Double) {}
    func start() throws { starts += 1; if !permitsStart { XCTFail("Headless tests must not start audio") } }
    func stop() {}
}
@MainActor final class MonitorWindows: PluginWindowFactory {
    func make(title: String, size: NSSize) -> any PluginWindow { fatalError("Headless tests must not open editors") }
}
import XCTest
enum TestImageDirectory {
    static func make() -> URL {
        if let path = ProcessInfo.processInfo.environment["SICK_TEST_ARTIFACT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            // Suite workers own their images even if two tests use the same
            // evidence name. Explicit single-test capture keeps its flat path.
            if ProcessInfo.processInfo.environment["SICK_TEST_ISOLATE_ARTIFACTS"] == "1" {
                return directory.appendingPathComponent("PlanariumImages-\(UUID().uuidString)")
            }
            return directory
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("PlanariumImages-\(UUID().uuidString)")
    }
}
