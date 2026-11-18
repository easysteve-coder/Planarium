import Foundation
import PlanariumDomain
import PlanariumPresets
import SickPLSControlCore

// Pure offline geometry/serialization tool: no AudioHost, MIDI or scanner.
let arguments = Array(CommandLine.arguments.dropFirst())
let toolHelp = """
planarium-preset-tool — offline preset tool

  kit …      Patch Construction Kit: musical recipe + sound catalog -> canonical V6 preset (try: kit help)
  cells      LEGACY helper (args: size r0 r1 b0 b1) printing old PolarMetricGridCell [ring,index]
             pairs. These are NOT canonical V6 cells (polarDeviceV2 ring/sector) — use `kit` for new patches.
  convert    stdin preset of any version -> V6 on stdout
  template   stdin preset -> V6 spatial template (no mixer) on stdout
  seed       prints a synthetic legacy parser input for the factory recipe script

"""
if arguments.first == "kit" {
    // Patch Construction Kit: recipes in, canonical V6 presets out (see PatchKit/README.md).
    exit(PatchKitCommand.run(Array(arguments.dropFirst()),
        out: { FileHandle.standardOutput.write(Data($0.utf8)) }, err: { FileHandle.standardError.write(Data($0.utf8)) }))
}
if arguments.first == "help" || arguments.first == "--help" || arguments.first == "-h" {
    FileHandle.standardOutput.write(Data(toolHelp.utf8)); exit(0)
}
do {
    switch arguments.first {
    case "cells":
        guard arguments.count == 6, let size = Double(arguments[1]), let r0 = Double(arguments[2]),
              let r1 = Double(arguments[3]), let b0 = Double(arguments[4]), let b1 = Double(arguments[5]),
              size > 0, [size, r0, r1, b0, b1].allSatisfy(\.isFinite), r0 >= 0, r1 <= 81.9,
              r0 < r1, b0 >= -180, b1 <= 180, b0 < b1 else { throw ToolError.invalidArguments }
        var cells: [[Int]] = []
        var ring = Int(r0 / size)
        while (Double(ring) + 0.5) * size < r1 {
            let radius = (Double(ring) + 0.5) * size
            let step = PolarMetricCellSegment.angularStepDegrees(outerRadiusMeters: Double(ring + 1) * size, radialHeightMeters: size)
            if radius >= r0 {
                var index = Int(floor((b0 + 180) / step))
                while Double(index) * step - 180 + step / 2 < b1 {
                    if Double(index) * step - 180 + step / 2 >= b0 { cells.append([ring, index]) }
                    index += 1
                }
            }
            ring += 1
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: cells))
    case "convert", "template":
        guard arguments.count == 1 else { throw ToolError.invalidArguments }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let reading = try PresetDocumentReader.read(data).get()
        let document = try reading.replacing(FactoryPresetDocument.empty())
        FileHandle.standardOutput.write(try PresetDocumentWriter.encode(.init(name: reading.name, document: document,
            viewport: reading.viewport, includesChannel: arguments.first == "template" ? false : reading.sourceVersion < 5 || reading.includesChannel, summary: reading.summary)))
    case "seed":
        guard arguments.count == 1 else { throw ToolError.invalidArguments }
        // The recipe script supplies only spatial values; old settings are
        // synthetic parser input and never saved as a product preset.
        let preset = InstrumentPreset(name: "Factory", zones: [], masterGain: 1,
            delay: .init(isEnabled: false, sendLevel: 0, timeSeconds: 0.25, feedbackPercent: 0),
            reverb: .init(isEnabled: false, sendLevel: 0, character: "smallRoom"),
            prediction: .init(alpha: 0.5, beta: 0.1, predictionHorizonSeconds: 0.05, staleTimeoutSeconds: 0.5, outlierThreshold: 0.3),
            audioUnits: .init(entries: []), midi: .init(channel: 1, bendRangeSemitones: 12, rootNote: 60, spanSemitones: 24, pitchInverted: false, volumeController: 7, filterController: 74, effectSendController: 91),
            viewport: .init(centerX: 0, centerY: 0, halfExtent: 1),
            spatialWorkspace: SpatialInstrumentWorkspace(layers: [.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Layer", color: .blue)]), instrumentChannel: nil)
        FileHandle.standardOutput.write(try JSONEncoder().encode(preset))
    default: throw ToolError.invalidArguments
    }
} catch {
    FileHandle.standardError.write(Data("Preset tool failed: invalid recipe or document\n".utf8))
    exit(1)
}
enum ToolError: Error { case invalidArguments }
