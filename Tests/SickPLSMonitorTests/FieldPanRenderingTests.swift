import XCTest
import AppKit
import SwiftUI
import PlanariumApplication
import PlanariumDomain
import PlanariumRuntime
import SickPLSCore
import PlanariumPresets
import SickPLSMonitorKit
@testable import SickPLSMonitor

@MainActor final class FieldPanRenderingTests: XCTestCase {
    private struct Harness: View {
        @ObservedObject var instrument: SpatialInstrumentRuntimeModel
        @ObservedObject var cells: SpatialActiveCellDisplayModel
        var body: some View {
            CartesianScanFieldView(editor: instrument.canvas, profile: cells.latestProfile, activeCellDisplay: cells,
                spatialInstrument: instrument, simulationBadge: AnyView(EmptyView()))
        }
    }
    func testPanZoomProductionViewTiming() throws {
        var presets = try ["Harmony 15 Proximity Pyramid", "Harmonie 10 Tritonus-Bruecke", "Harmony 27 Harmony Codex"].map { name in
            (name, try XCTUnwrap(FactoryPresetLibrary.standard.data(named: name)))
        }
        // Local review evidence only: never copy an owner's preset into the repository.
        if let path = ProcessInfo.processInfo.environment["SICK_FIELD_OWNER_PRESET"] {
            presets.append((URL(fileURLWithPath: path).deletingPathExtension().deletingPathExtension().lastPathComponent,
                            try Data(contentsOf: URL(fileURLWithPath: path))))
        }
        for pointCount in [90,361] {
        for (name, data) in presets {
            let fixture = try MonitorRootFixture()
            let instrument = fixture.root.document
            try instrument.applyPresetDocument(try PresetDocumentReader.read(data).get().replacing(instrument.document))
            let cells = SpatialActiveCellDisplayModel()
            let raw = try B0ScanProfile.build(partialScanIndex: 0,measurements: (0..<pointCount).map {
                try .build(value: abs($0-pointCount/2)<3 ? 100 : 200,fieldFlags: 0)
            })
            let geometry = try FullScanProfileAdapter.geometry(from: raw)
            let frame = ProfileFrame(sessionID: UUID(),sequence: 1,time: 0,measurements: try FullScanProfileAdapter.measurements(from: raw),geometry: geometry,rawProfile: raw)
            let contour = SpatialRoomContour(geometry: .init(pointCount: pointCount,angleResolutionDegrees: 180/Double(pointCount-1),startAngleDegrees: -90,sourceIdentifier: frame.sourceIdentifier),nearestDistancesCentimeters: Array(repeating: 200,count: pointCount),spreadCentimeters: Array(repeating: 0,count: pointCount))
            var config = instrument.document.detection; config.roomContour = .init(isEnabled: true); config.temporalSmoothing = .off
            instrument.updateDetectionConfiguration(config)
            var detector = SpatialDetectionPipeline()
            let selection = detector.select(frame: frame,instrument: try InstrumentCompiler.compile(instrument.document),contour: contour)
            instrument.noteDisplay(.init(profile: frame,contour: contour,selection: selection))
            cells.update(profileFrame: frame,activeCells: [:])
            let prepared = instrument.fieldPlan.identity
            let host = NSHostingView(rootView: Harness(instrument: instrument, cells: cells).preferredColorScheme(.dark))
            host.frame = .init(x: 0, y: 0, width: 900, height: 700)
            host.wantsLayer = true; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let timing = CanvasTimingProbe()
            if ProcessInfo.processInfo.environment["SICK_PAN_COST"] == "1" { CanvasTimingProbe.current = timing }
            defer { CanvasTimingProbe.current = nil }
            var times: [Double] = []
            for i in 0..<40 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = instrument.canvas.panViewport(byScreenX: i % 2 == 0 ? 3 : -3, screenY: 1)
                _ = instrument.canvas.zoom(byFactor: i % 2 == 0 ? 1.01 : 1 / 1.01,
                    atScreenPoint: .init(x: 450, y: 350), canvasSize: host.frame.size)
                XCTAssertEqual(instrument.fieldPlan.identity, prepared, "Pan/zoom must not rebuild region paths")
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
            if ProcessInfo.processInfo.environment["SICK_PAN_COST"] == "1" { print("PAN-COST \(name) \(pointCount) \(timing.milliseconds) counts=\(timing.counts)") }
            XCTAssertLessThan(times.dropFirst(5).reduce(0,+)/35, 8)
            print("Field pan/zoom \(name) rays=\(pointCount): mean=\(times.dropFirst(5).reduce(0,+)/35) max=\(times.dropFirst(5).max()!) ms (state+layout/display; asynchronous Canvas GPU excluded)")
            var done = false; fixture.root.terminate { done = true }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        }
        }
    }
}
