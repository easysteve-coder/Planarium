import XCTest
import Foundation

final class DomainBoundaryContractTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func testDomainHasOnlyPureDeviceDependencies() throws {
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"))
        XCTAssertTrue(manifest.contains(".target(name: \"PlanariumDomain\", dependencies: [\"PLSDeviceValues\", \"PlanariumControllerCore\", \"PlanariumMusicCore\", \"SickPLSCore\"])"))
        XCTAssertTrue(manifest.contains(".target(name: \"PlanariumMusicCore\"),"), "the music core has no dependency")
        let directory = root.appendingPathComponent("Sources/PlanariumDomain")
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "swift" {
            let text = try String(contentsOf: url)
            XCTAssertFalse(text.contains("import SickPLSControlCore"), url.lastPathComponent)
            XCTAssertFalse(text.contains("ControlValuePredictorConfiguration"), url.lastPathComponent)
            XCTAssertFalse(text.contains("ZoneRole"), url.lastPathComponent)
        }
    }
    /// The sound core (music values, output routing, Audio Unit host, CoreMIDI)
    /// knows no scanner, input source, geometry or document. Every import in
    /// every file below these modules (recursively) must be on its allow list.
    func testSoundModulesImportOnlyAllowedModules() throws {
        let system: Set<String> = ["Foundation", "Dispatch", "Darwin", "Combine", "os"]
        let allowed: [String: Set<String>] = [
            "PlanariumMusicCore": ["Foundation"],
            "PlanariumSoundCore": system.union(["PlanariumMusicCore", "PlanariumHostClockDSP"]),
            "PlanariumAudio": system.union(["PlanariumMusicCore", "PlanariumSoundCore", "PlanariumHostClockDSP", "PlanariumFadeDSP",
                                            "PlanariumObjCCatch", "AVFoundation", "AppKit", "AudioToolbox", "CoreAudio", "CoreAudioKit"]),
            "PlanariumMIDI": system.union(["PlanariumMusicCore", "PlanariumSoundCore", "CoreMIDI"]),
            "PlanariumControllerCore": ["Foundation", "PlanariumMusicCore"],
            "PlanariumControllerInput": ["Foundation", "GameController", "PlanariumControllerCore", "PlanariumMusicCore"],
        ]
        for (module, names) in allowed {
            let directory = root.appendingPathComponent("Sources/\(module)")
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            XCTAssertFalse(files.isEmpty, module)
            for url in files {
                for line in try String(contentsOf: url).split(separator: "\n") {
                    let words = line.split(separator: " ").map(String.init)
                    guard let index = words.firstIndex(of: "import"), index + 1 < words.count,
                          words[..<index].allSatisfy({ $0.hasPrefix("@") || $0 == "public" }) else { continue }
                    let name = words[index + 1].split(separator: ".").first.map(String.init) ?? ""
                    XCTAssertTrue(names.contains(name), "\(module)/\(url.lastPathComponent) imports \(name)")
                }
            }
        }
    }
    func testRetiredPathsHaveNoDeclarations() throws {
        for path in ["PlanariumDomain/V2SpatialRuntime.swift", "SickPLSMonitor/ScanFieldView.swift", "SickPLSMonitor/SpatialCellActiveStatusRow.swift", "SickPLSMonitor/PolarScanView.swift", "SickPLSMonitor/ZoneOverlayView.swift", "SickPLSMonitor/ZoneHandlesView.swift", "SickPLSMonitor/LearnDraftCardView.swift", "SickPLSMonitor/LearnCandidatePreviewView.swift", "SickPLSMonitor/LearnDraftNoticeBarView.swift", "SickPLSMonitor/ZoneLearningSectionView.swift"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/" + path).path), path)
        }
        let pipeline = try String(contentsOf: root.appendingPathComponent("Sources/PlanariumDomain/SpatialDetectionPipeline.swift"))
        XCTAssertFalse(pipeline.contains("profile: B0ScanProfile"))
        let hysteresis = try String(contentsOf: root.appendingPathComponent("Sources/PlanariumDomain/SpatialHysteresis.swift"))
        XCTAssertFalse(hysteresis.contains("SpatialActiveCellSelector"))
        XCTAssertFalse(hysteresis.contains("LegacyPolarHitGeometry"))
        let contour = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitorKit/SpatialRoomContour.swift"))
        XCTAssertFalse(contour.contains("class SpatialRoomContourStore"))
    }
    func testCleanupHasNoUnusedRetireControlOrUnreachableBranchAndMeterContractIsCurrent() throws {
        let midi = try String(contentsOf: root.appendingPathComponent("Sources/PlanariumMIDI/MIDIPortOwner.swift"))
        XCTAssertFalse(midi.contains("forceRetire"))
        let geometry = try String(contentsOf: root.appendingPathComponent("Sources/PlanariumDomain/PolarProfileGeometry.swift"))
        XCTAssertFalse(geometry.contains("Keine physikalische Einheit oder Winkelbehauptung"))
        let pipeline = try String(contentsOf: root.appendingPathComponent("Sources/PlanariumDomain/SpatialDetectionPipeline.swift"))
        XCTAssertEqual(pipeline.components(separatedBy: "if configuration == .allStagesOff").count - 1, 1)
    }
}
