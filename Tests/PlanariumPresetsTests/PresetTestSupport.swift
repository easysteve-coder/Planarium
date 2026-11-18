import Foundation
import XCTest
import PlanariumDomain
import PlanariumApplication
import PlanariumAudio
import PlanariumMIDI
import PlanariumRuntime
@testable import PlanariumPresets
@MainActor final class PresetFakeMIDI: MIDIConnectionBoundary {
 var onDestinationLost: (@MainActor () -> Void)?
 func destinations() -> [MIDITargetDescription] { [] }
 func open(_ target: InstrumentMIDITarget) -> Result<any MIDISendBoundary, MIDIConnectionError> { .failure(.init("Test unavailable")) }
 func close() {}
}
@MainActor final class PresetFakeComponents: PluginComponentSource {
 var loads = 0
 func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) { loads += 1; completion(.failure(.init("Test unavailable"))) }
}
@MainActor final class PresetHarness {
 let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlanariumPresetTests-\(UUID().uuidString)")
 let source = PresetFakeComponents()
 let root: PlanariumComposition
 let store: PresetFileStore
 let presets: PresetControlModel
 init() {
  root = try! .init(midi: PresetFakeMIDI(), components: source, configuration: .init(offline: true))
  store = .init(directory: directory)
  presets = .init(store: store, documentOwner: root.document, factoryPresets: .empty)
 }
 func legacyRecord(name: String) -> InstrumentPreset {
  var record = PresetCodecTests.samplePreset(name: name)
  record.spatialWorkspace = root.document.canvas.workspace
  record.instrumentChannel = nil
  record.zones = []
  record.assignment = .init()
  return record
 }
 func removeDirectory() { try? FileManager.default.removeItem(at: directory) }
}
