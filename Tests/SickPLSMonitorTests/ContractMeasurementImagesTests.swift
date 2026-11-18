import XCTest
import AppKit
import SwiftUI
import PlanariumApplication
import PlanariumDomain
import PlanariumRuntime
import SickPLSControlCore
import SickPLSCore
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class ContractMeasurementImagesTests: XCTestCase {
    private struct Field: View {
        @ObservedObject var owner: SpatialInstrumentRuntimeModel
        @ObservedObject var display: SpatialActiveCellDisplayModel
        var body: some View {
            CartesianScanFieldView(editor: owner.canvas, profile: display.latestProfile,
                activeCellDisplay: display, spatialInstrument: owner, simulationBadge: AnyView(EmptyView()))
        }
    }
    func testOwnerRun2BothSelectedLayersRenderFromTheSameCompiledSelectionFor90And361() throws {
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for count in [90, 361] {
            let root = try MonitorRootFixture().root
            let owner = root.document
            let firstID = UUID(), secondID = UUID()
            let layers = [(firstID, 100, 100, 60, SpatialLayerColor.blue), (secondID, 261, 130, 67, .green)].map { id, tick, ring, note, color in
                SpatialDocumentLayer(id: id, name: "Object \(note)", color: color, isVisible: true, isActive: true,
                    isLocked: false, isSoloed: false, cells: [PolarDeviceLattice(ring: ring, sector: tick)!],
                    routings: [.init(target: .midiNote(channel: 0), program: .chord(notes: [note], velocity: 100, transition: .retrigger))], cellOverrides: [:])
            }
            try owner.edit { document in
                document.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: firstID)
                document.detection = .ownerDefaults
            }
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { index in
                let value: UInt16 = index == (count == 90 ? 25 : 100) ? 100 : index == (count == 90 ? 65 : 261) ? 130 : 8191
                return try .build(value: value, fieldFlags: 0)
            })
            let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 1,
                measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
            var pipeline = SpatialDetectionPipeline()
            let selection = pipeline.select(frame: frame, instrument: try InstrumentCompiler.compile(owner.document), contour: nil)
            XCTAssertEqual(selection.activeHandles.count, 2)
            let display = SpatialActiveCellDisplayModel()
            display.update(profileFrame: frame, activeCells: try selection.activeHandles.mapValues { try LegacyLatticeMigration.project($0.cell, in: owner.document.editorGrid) })
            for width in [1120, 360] {
                let host = NSHostingView(rootView: Field(owner: owner, display: display).foregroundColor(.white).background(StageTheme.workspace).environment(\.colorScheme, .dark).preferredColorScheme(.dark))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                host.wantsLayer = true; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("bc-two-objects-\(count)-\(width).png"))
            }
        }
    }
    func testDetectionControlsAndOwnValueRenderWideAndNarrowFor90And361() throws {
        let directory = TestImageDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for count in [90, 361] {
            let root = try MonitorRootFixture().root
            let owner = root.document
            let layer = owner.document.spatial.layers[0]
            let cell = PolarDeviceLattice(ring: 51, sector: 180)!
            try owner.edit { $0.spatial = try! .init(latticeVersion: .polarDeviceV2, layers: [
                .init(id: layer.id, name: "Own value", color: .blue, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
                    cells: [cell], routings: [.init(target: .midiNote(channel: 0), program: .constant(60))],
                    cellOverrides: [cell: [.init(target: .midiNote(channel: 0), value: .note(number: 70, velocity: 100))]])], selectedLayerID: layer.id) }
            let display = SpatialActiveCellDisplayModel()
            let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { index in try .build(value: index == count / 2 ? 51 : 8191, fieldFlags: 0) })
            let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 1,
                measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
            display.update(profileFrame: frame, activeCells: [:])
            for (name, method, enabled) in [("off", DetectionTemporalSmoothing.median(window: 7), false), ("mean", .mean(window: 5), true), ("median", .median(window: 7), true), ("exponential", .exponential(alpha: 0.3), true)] {
                var settings = DetectionConfiguration(temporalSmoothing: method, groupingJumpCentimeters: 17, groupingMinimumPoints: 3, representative: .nearestPointWithOffset, representativeOffsetCentimeters: 7)
                settings.setSmoothingEnabled(enabled); owner.updateDetectionConfiguration(settings)
                for width in [1120, 360] {
                    let host = NSHostingView(rootView: Field(owner: owner, display: display).foregroundColor(.white).background(StageTheme.workspace).environment(\.colorScheme, .dark).preferredColorScheme(.dark))
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                    host.wantsLayer = true; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    XCTAssertGreaterThan(png.count, 1000)
                    try png.write(to: directory.appendingPathComponent("bc-detection-\(name)-\(count)-\(width).png"))
                }
            }
        }
    }
}
