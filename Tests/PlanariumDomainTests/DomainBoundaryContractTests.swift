import XCTest
import Foundation

final class DomainBoundaryContractTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func testDomainHasOnlyPureDeviceDependencies() throws {
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"))
        XCTAssertTrue(manifest.contains(".target(name: \"PlanariumDomain\", dependencies: [\"PLSDeviceValues\", \"SickPLSCore\"])") )
        let directory = root.appendingPathComponent("Sources/PlanariumDomain")
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "swift" {
            let text = try String(contentsOf: url)
            XCTAssertFalse(text.contains("import SickPLSControlCore"), url.lastPathComponent)
            XCTAssertFalse(text.contains("ControlValuePredictorConfiguration"), url.lastPathComponent)
            XCTAssertFalse(text.contains("ZoneRole"), url.lastPathComponent)
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
