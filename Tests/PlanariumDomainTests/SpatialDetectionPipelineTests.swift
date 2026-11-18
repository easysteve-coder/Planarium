import XCTest
import SickPLSCore
import SickPLSControlCore
import SickPLSSimulationLink
@testable import PlanariumDomain

final class SpatialDetectionPipelineTests: XCTestCase {

    func testMarginOverlaySuppressesSharedSnapRegionEdges() throws {
        let a = PolarMetricCellSegment(innerRadiusMeters: 0.5, outerRadiusMeters: 1, startBearingDegrees: -30, endBearingDegrees: 0)
        let b = PolarMetricCellSegment(innerRadiusMeters: 0.5, outerRadiusMeters: 1, startBearingDegrees: 0, endBearingDegrees: 30)
        let cellA = PolarDeviceLattice(tick: 100, rawCentimeters: 70)!
        let cellB = PolarDeviceLattice(tick: 101, rawCentimeters: 70)!
        let id = UUID()
        func compiled(same: Bool) -> CompiledInstrument {
            .init(revision: .newSession(), layers: [.init(id: id, compiledLayerIndex: 0, cells: [cellA, cellB], routings: [], cellActions: [],
                snapRegionByCell: [cellA: cellA, cellB: same ? cellA : cellB],
                snapGeometry: same ? [cellA: [a,b]] : [cellA: [a], cellB: [b]])], columns: Array(repeating: [], count: 361), statistics: .init(compiledLayerCount: 1, indexedAddressCount: 2, maxEntriesPerTick: 1, overrideCellCount: 0, dormantOverrideCells: 0, ineligibleLayerCount: 0, ineligibleOverrideCells: 0, actionGroupCount: 0, routingPlanCount: 0, estimatedIndexBytes: 0))
        }
        do {
            let same = DetectionOverlayPresentation.cellMargins(instrument: compiled(same: true), layerID: id, centimeters: 3)
            let different = DetectionOverlayPresentation.cellMargins(instrument: compiled(same: false), layerID: id, centimeters: 3)
            XCTAssertEqual(same.shapes.count, 6)
            XCTAssertEqual(different.shapes.count, 8)
            XCTAssertFalse(same.shapes.contains { $0.points.count == 2 && $0.points.allSatisfy { abs($0.xMeters) < 0.04 } })
        }
    }

    func testMarginOverlayRemovesSharedArcsAcrossDifferentRingSubdivisions() {
        let inner = PolarMetricCellSegment(innerRadiusMeters: 0.5, outerRadiusMeters: 1, startBearingDegrees: -30, endBearingDegrees: 30)
        let outer = [-30.0, 0.0].map { PolarMetricCellSegment(innerRadiusMeters: 1, outerRadiusMeters: 1.5, startBearingDegrees: $0, endBearingDegrees: $0+30) }
        let overlay = DetectionOverlayPresentation.regionMargins(segments: [inner]+outer, centimeters: 0)
        XCTAssertFalse(overlay.shapes.contains { shape in
            shape.points.count > 2 && shape.points.allSatisfy { abs(hypot($0.xMeters, $0.yMeters)-1) < 1e-9 }
        }, "The complete shared ring arc must disappear even when it meets two shorter arcs")
    }

    func testMarginOverlayInsetsTheRegionRatherThanCollapsingEveryThinRing() {
        let segments = [0.5, 0.55, 0.6, 0.65].map {
            PolarMetricCellSegment(innerRadiusMeters: $0, outerRadiusMeters: $0+0.05, startBearingDegrees: -30, endBearingDegrees: 30)
        }
        let overlay = DetectionOverlayPresentation.regionMargins(segments: segments, centimeters: 3)
        XCTAssertFalse(overlay.shapes.isEmpty, "A 20 cm region survives a 3 cm inset even though each ring is only 5 cm")
        let radii = overlay.shapes.flatMap(\.points).map { hypot($0.xMeters, $0.yMeters) }
        guard let nearest = radii.min(), let farthest = radii.max() else { return }
        XCTAssertEqual(nearest, 0.53, accuracy: 1e-9)
        XCTAssertEqual(farthest, 0.67, accuracy: 1e-9)
    }

    func testContourOverlayTonesUseTheFilterSpanForCoarseAndFineProfiles() {
        var walls: [UInt16?] = []
        for index in 0..<361 {
            if index % 9 == 0 { walls.append(nil) }
            else {
                let distance: Int = 200 + index % 3
                walls.append(UInt16(distance))
            }
        }
        let contour = SpatialRoomContour(geometry: .init(pointCount: 361, angleResolutionDegrees: 0.5, startAngleDegrees: -90, sourceIdentifier: "test"),
            nearestDistancesCentimeters: walls, spreadCentimeters: [])
        for count in [90,361] {
            let source = rays(count, distances: [0: 185, 20: 195, 40: 205])
            let overlay = DetectionOverlayPresentation.contourTolerance(contour: contour, matches: true,
                configuration: .init(isEnabled: true, toleranceCentimeters: 5), measurements: source.values, geometry: source.geometry)
            let step = 180 / Double(count-1)
            for value in source.values {
                XCTAssertEqual(overlay.pointTones[value.order] == .rejected,
                    !contour.filters(distanceCentimeters: value.distanceCentimeters, bearingDegrees: -90 + Double(value.order)*step,
                        spanDegrees: step, toleranceCentimeters: 5))
            }
        }
    }

    func testSnapOverlayIndexesLargeFiniteRadiiWithoutIntegerConversion() {
        let segment = PolarMetricCellSegment(innerRadiusMeters: 1e12, outerRadiusMeters: 1e12+1,
            startBearingDegrees: -10, endBearingDegrees: 10)
        XCTAssertFalse(DetectionOverlayPresentation.regionMargins(segments: [segment], centimeters: 3).shapes.isEmpty)
    }

    private func rays(_ count: Int = 361, distances: [Int: UInt16]) -> (values: [ProjectedScanMeasurement], geometry: ProfileGeometryIdentity) {
        let geometry = ProfileGeometryIdentity(operatingMode: "fullScan", pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
        let values = (0..<count).compactMap { order -> DeviceTickMeasurement? in
            guard let ticks = geometry.tickSpan(at: order) else { return nil }
            return .init(order: order, ticks: ticks, rawCentimeters: distances[order] ?? 300)
        }
        return (geometry.project(values), geometry)
    }

    func testConfirmationTooltipUsesTheDelayComputedByDetectionLogic() {
        let at25Hz = DetectionLatency.confirmationTooltip(profiles: 2, profileRateHertz: 25)
        let at50Hz = DetectionLatency.confirmationTooltip(profiles: 2, profileRateHertz: 50)
        XCTAssertTrue(at25Hz.contains("about 40 ms added delay at 25 Hz"))
        XCTAssertTrue(at50Hz.contains("about 20 ms added delay at 50 Hz"))
        XCTAssertFalse(at25Hz == at50Hz)
    }

    func testD8ConfigurationPersistsAndOldWorkspaceWithoutDetectionDecodesRaw() throws {
        let configured = DetectionConfiguration.ownerDefaults.replacingRepresentative(.median)
        let workspace = SpatialInstrumentWorkspace(grid: .fiveCentimeter, detectionConfiguration: configured)
        XCTAssertEqual(try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: JSONEncoder().encode(workspace)).detectionConfiguration, configured)

        let current = try JSONEncoder().encode(SpatialInstrumentWorkspace(grid: .fiveCentimeter))
        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        oldObject.removeValue(forKey: "detectionConfiguration")
        let old = try JSONSerialization.data(withJSONObject: oldObject)
        XCTAssertEqual(try JSONDecoder().decode(SpatialInstrumentWorkspace.self, from: old).detectionConfiguration, .legacyDefaults)
    }

    func testVirtualMMKFixed2HardMatchesMinimumOfEachTwoDegreeSegment() {
        let source = rays(distances: [0: 210, 1: 130, 2: 180, 3: 160, 4: 240, 5: 120])
        let configuration = DetectionConfiguration(virtualMMKMode: .fixed2, virtualMMKSoftness: 0)
        let result = SpatialDetectionPipeline(configuration: configuration).virtualMMK(source.values, geometry: source.geometry)
        // Four 0.5° rays make one 2° MMK-90-equivalent angular segment.
        XCTAssertEqual(result.prefix(4).map(\.distanceCentimeters), [130, 130, 130, 130])
        XCTAssertEqual(result.dropFirst(4).prefix(4).map(\.distanceCentimeters), [120, 120, 120, 120])
    }

    func testVirtualMMKAdaptiveUsesSeveralNearRaysButKeepsDistantBeamResolution() {
        let near = rays(distances: [180: 50, 181: 60])
        var configuration = DetectionConfiguration(virtualMMKMode: .adaptive, virtualMMKTargetWidthCentimeters: 2, virtualMMKSoftness: 0)
        let nearResult = SpatialDetectionPipeline(configuration: configuration).virtualMMK(near.values, geometry: near.geometry)
        XCTAssertEqual(nearResult[181].distanceCentimeters, 50, "0.5 m target width must include neighbouring rays")

        let far = rays(distances: [180: 180, 181: 80])
        configuration.virtualMMKSoftness = 0
        let farResult = SpatialDetectionPipeline(configuration: configuration).virtualMMK(far.values, geometry: far.geometry)
        XCTAssertEqual(farResult[180].distanceCentimeters, 180, "at 1.8 m the 2 cm window stays within the ray's own 0.5° bearing")
    }

    func testVirtualMMKSoftMinimumDoesNotWashOutTheNearestHand() {
        let source = rays(distances: [178: 220, 179: 220, 180: 55, 181: 220, 182: 220])
        let configuration = DetectionConfiguration(virtualMMKMode: .adaptive, virtualMMKTargetWidthCentimeters: 2, virtualMMKSoftness: 100)
        let result = SpatialDetectionPipeline(configuration: configuration).virtualMMK(source.values, geometry: source.geometry)
        XCTAssertLessThanOrEqual(result[180].distanceCentimeters, 55, "the hand ray itself remains the weighted minimum")
        XCTAssertLessThanOrEqual(result[179].distanceCentimeters, 220, "softness may only pull a neighbouring ray toward the nearer hand")
    }

    func testVirtualMMKConfigurationDefaultsForNewAndLegacyDocuments() throws {
        XCTAssertEqual(DetectionConfiguration.ownerDefaults.virtualMMKMode, .adaptive)
        XCTAssertEqual(DetectionConfiguration.ownerDefaults.virtualMMKTargetWidthCentimeters, 2)
        let legacy = try JSONDecoder().decode(DetectionConfiguration.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.virtualMMKMode, .raw)
        XCTAssertEqual(try JSONDecoder().decode(DetectionConfiguration.self, from: JSONEncoder().encode(DetectionConfiguration.ownerDefaults)), .ownerDefaults)
    }

    func testRawVirtualMMKDoesNotAddKeysToLegacyEncoding() throws {
        let raw = try JSONDecoder().decode(DetectionConfiguration.self, from: Data("{}".utf8))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as? [String: Any])
        XCTAssertNil(encoded["virtualMMKMode"])
        XCTAssertNil(encoded["virtualMMKTargetWidthCentimeters"])
        XCTAssertNil(encoded["virtualMMKSoftness"])
    }

}

extension SpatialDetectionPipelineTests {
    private func rundeEFrame(_ sequence: UInt64 = 1, distance: UInt16? = nil) -> ProfileFrame {
        let values: [UInt16] = [106, 106, 100, 103, 109, 109, 109, 109]
        let geometry = ProfileGeometryIdentity.fullScan361
        let measurements = (0..<8).map { index in
            DeviceTickMeasurement(order: 170+index, ticks: geometry.tickSpan(at: 170+index)!, rawCentimeters: distance ?? values[index])!
        } + (230..<238).map { DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: 140)! }
        return .init(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!, sequence: sequence, time: Double(sequence)/25, measurements: measurements)
    }
    private func rundeEInstrument(_ configuration: DetectionConfiguration) throws -> CompiledInstrument {
        let layer = SpatialDocumentLayer(id: UUID(), name: "Replay", color: .blue, isVisible: true, isActive: true,
            isLocked: false, isSoloed: false, cells: Set((90...160).map { PolarDeviceLattice(ring: $0, sector: 172)! }), routings: [], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        return try InstrumentCompiler.compile(.init(spatial: spatial, detection: configuration, revision: .newSession()))
    }
    private func rundeEPair(_ control: DetectionOverlayControl, change: (inout DetectionConfiguration) -> Void) throws -> (DetectionOverlayPresentation,DetectionOverlayPresentation) {
        var configuration = DetectionConfiguration(temporalSmoothing: .off, groupingJumpCentimeters: 1, groupingMinimumPoints: 1,
            representative: control == .offset ? .nearestPointWithOffset : .mean, representativeOffsetCentimeters: 0,
            minimumAngleDegrees: 0, virtualMMKMode: .adaptive, virtualMMKTargetWidthCentimeters: control == .softness ? 5 : 1, virtualMMKSoftness: 0,
            edgePoints: 0, coreWidthCentimeters: 0)
        let frame = rundeEFrame()
        let a = DetectionOverlayPresentation.measured(control: control, frame: frame, instrument: try rundeEInstrument(configuration), contour: nil)
        change(&configuration)
        let b = DetectionOverlayPresentation.measured(control: control, frame: frame, instrument: try rundeEInstrument(configuration), contour: nil)
        XCTAssertNotEqual(a,b, "The selected regulator must change its own explanation")
        XCTAssertEqual(frame,rundeEFrame(), "The acquisition stays immutable")
        return (a,b)
    }
    func testRundeEMinimumGapUsesTheSameMeasuredPair() throws {
        let (a,b) = try rundeEPair(.minimumGap) { $0.groupingJumpCentimeters = 30 }
        XCTAssertEqual(a.shapes.first?.points.first,b.shapes.first?.points.first)
        XCTAssertEqual(a.shapes.last,b.shapes.last)
        XCTAssertEqual(a.labels.first?.text,"1 cm · Allowed depth step · separate")
        XCTAssertEqual(b.labels.first?.text,"30 cm · Allowed depth step · joined")
        for (overlay,length) in [(a,0.01),(b,0.30)] {
            let p = try XCTUnwrap(overlay.shapes.first?.points.first), q = try XCTUnwrap(overlay.shapes.first?.points.last)
            XCTAssertEqual(hypot(q.xMeters-p.xMeters,q.yMeters-p.yMeters),length,accuracy: 1e-9)
        }
    }
    func testRundeEMinimumPointsKeepsMeasuredBrackets() throws {
        let (a,b) = try rundeEPair(.minimumPoints) { $0.groupingMinimumPoints = 10 }
        XCTAssertEqual(a.shapes,b.shapes)
        XCTAssertEqual(a.labels.map(\.point),b.labels.map(\.point))
        XCTAssertTrue(a.labels.allSatisfy { $0.text.contains("kept") })
        XCTAssertTrue(b.labels.allSatisfy { $0.text.contains("ignored") })
    }
    func testRundeEMinimumAngleUsesMeasuredNearGroupAndRealRejection() throws {
        let (a,b) = try rundeEPair(.minimumAngle) { $0.minimumAngleDegrees = 90 }
        XCTAssertEqual(a.labels.map(\.point),b.labels.map(\.point))
        XCTAssertEqual(a.shapes.first?.points.first,b.shapes.first?.points.first)
        XCTAssertEqual(a.pointTones[230],.kept)
        XCTAssertEqual(b.pointTones[230],.rejected)
        let original = rundeEFrame()
        let equalDepth = ProfileFrame(sessionID: original.sessionID,sequence: original.sequence,time: original.time,
            measurements: original.measurements.map { DeviceTickMeasurement(order: $0.order,ticks: $0.ticks,rawCentimeters: 100)! })
        let config = DetectionConfiguration(minimumAngleDegrees: 90,virtualMMKMode: .raw,edgePoints: 0,coreWidthCentimeters: 0)
        let equal = DetectionOverlayPresentation.measured(control: .minimumAngle,frame: equalDepth,instrument: try rundeEInstrument(config),contour: nil)
        XCTAssertTrue(equal.pointTones.values.allSatisfy { $0 == .kept }, "Equal depth is never shadowed by the angle setting")
    }
    func testRundeETargetWidthKeepsItsMeasuredAnchorAndWeights() throws {
        let (a,b) = try rundeEPair(.targetWidth) { $0.virtualMMKTargetWidthCentimeters = 5 }
        XCTAssertEqual(a.labels.map(\.point),b.labels.map(\.point))
        XCTAssertEqual(a.shapes.map(\.fillOpacity),b.shapes.map(\.fillOpacity))
        XCTAssertNotEqual(a.shapes.map(\.points),b.shapes.map(\.points))
    }
    func testRundeESoftnessKeepsTheWindowWidthAndShowsDetectorValues() throws {
        let (a,b) = try rundeEPair(.softness) { $0.virtualMMKSoftness = 100 }
        XCTAssertEqual(a.labels.map(\.point),b.labels.map(\.point))
        XCTAssertEqual(a.shapes.prefix(25).map(\.points),b.shapes.prefix(25).map(\.points))
        XCTAssertGreaterThan(a.shapes[0].fillOpacity,b.shapes[0].fillOpacity)
        XCTAssertNotEqual(a.shapes.dropFirst(25).map(\.points),b.shapes.dropFirst(25).map(\.points), "The line must use the actual weighted detector values")
    }
    func testRundeERepresentativeMovesOnlyThePlayingPoint() throws {
        let (a,b) = try rundeEPair(.representative) { $0.representative = .nearestPoint }
        XCTAssertEqual(a.shapes.filter { $0.tone == .guide },b.shapes.filter { $0.tone == .guide })
        XCTAssertEqual(a.pointTones,b.pointTones)
        XCTAssertNotEqual(a.labels.map(\.point),b.labels.map(\.point))
    }
    func testRundeEOffsetMovesFromTheSameNearestPoint() throws {
        let (a,b) = try rundeEPair(.offset) { $0.representativeOffsetCentimeters = 10 }
        XCTAssertEqual(a.shapes.filter { $0.tone == .guide },b.shapes.filter { $0.tone == .guide })
        let arrows = b.shapes.filter { $0.lineWidth == 2.5 }
        XCTAssertFalse(arrows.isEmpty)
        for arrow in arrows {
            let p = arrow.points[0], q = arrow.points[1]
            XCTAssertEqual(hypot(q.xMeters-p.xMeters,q.yMeters-p.yMeters),0.1,accuracy: 1e-9)
        }
    }
    func testRundeEConfirmationReadsActualPendingTransitionAndNeverSequenceModulo() throws {
        var configuration = DetectionConfiguration.allStagesOff
        configuration.cellSelection.confirmationProfiles = 4
        let instrument = try rundeEInstrument(configuration)
        var selector = DeviceLatticeSelector()
        let initial = DeviceTickMeasurement(order: 172,ticks: .point(172)!,rawCentimeters: 100)!
        let moved = DeviceTickMeasurement(order: 172,ticks: .point(172)!,rawCentimeters: 130)!
        let hysteresis = SpatialHysteresisConfiguration(radialMarginCentimeters: 0, angularMarginTicks: 0, switchConfirmationProfiles: 4, continuousBacklashCentimeters: 0)
        _ = selector.step(measurements: [initial],instrument: instrument,geometry: .fullScan361,configuration: hysteresis)
        for n in 1...4 {
            let selected = selector.step(measurements: [moved],instrument: instrument,geometry: .fullScan361,configuration: hysteresis)
            XCTAssertEqual(selected.confirmationProgress.first?.observedProfiles,n)
            let frame = rundeEFrame(99)
            let a = DetectionOverlayPresentation.measured(control: .confirmation, frame: frame, instrument: instrument, contour: nil, confirmation: selected.confirmationProgress)
            XCTAssertEqual(a.labels.first?.text,"\(n) / 4 · \(n == 4 ? "ready" : "waiting")")
            var one = configuration; one.cellSelection.confirmationProfiles = 1
            let b = DetectionOverlayPresentation.measured(control: .confirmation, frame: frame, instrument: instrument.previewingDetection(one), contour: nil, confirmation: selected.confirmationProgress)
            XCTAssertEqual(b.labels.first?.text,"1 / 1 · ready")
            XCTAssertEqual(a.labels.first?.point,b.labels.first?.point)
        }
        let stable = selector.step(measurements: [moved],instrument: instrument,geometry: .fullScan361,configuration: hysteresis)
        XCTAssertTrue(stable.confirmationProgress.isEmpty)
        let noChange = DetectionOverlayPresentation.measured(control: .confirmation,frame: rundeEFrame(100),instrument: instrument,contour: nil,confirmation: stable.confirmationProgress)
        XCTAssertEqual(noChange.labels.first?.text,"No cell change")
        for control in [DetectionOverlayControl.minimumGap,.minimumPoints,.minimumAngle,.confirmation,.targetWidth,.softness,.representative,.offset] {
            XCTAssertEqual(DetectionOverlayPresentation.measured(control: control,frame: nil,instrument: instrument,contour: nil).labels.first?.text,"Move your hand into view")
        }
    }
}
