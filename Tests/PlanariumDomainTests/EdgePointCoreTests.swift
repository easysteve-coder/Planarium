import XCTest
import SickPLSCore
@testable import PlanariumDomain

final class EdgePointCoreTests: XCTestCase {
    private let session = UUID()
    private func configuration(edge: UInt8 = 0, core: UInt8 = 0, minimum: Int = 1) -> DetectionConfiguration {
        .init(groupingJumpCentimeters: 24, groupingMinimumPoints: minimum, minimumAngleDegrees: 0,
              virtualMMKMode: .raw, edgePoints: edge, coreWidthCentimeters: core)
    }
    private func instrument(_ config: DetectionConfiguration) throws -> CompiledInstrument {
        let id = UUID()
        let layer = SpatialDocumentLayer(id: id, name: "Hand", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
        return try InstrumentCompiler.compile(.init(spatial: spatial, detection: config, revision: .newSession()))
    }
    private func frame(_ distances: [Int: UInt16], sequence: UInt64 = 1) -> ProfileFrame {
        .init(sessionID: session, sequence: sequence, time: Double(sequence) / 25,
              measurements: distances.keys.sorted().compactMap { order in
            .init(order: order, ticks: ProfileGeometryIdentity.fullScan361.tickSpan(at: order)!, rawCentimeters: distances[order]!)
        })
    }
    private func object(_ distances: [Int: UInt16], edge: UInt8 = 0, core: UInt8 = 0, minimum: Int = 1) throws -> DetectionObject {
        var pipeline = SpatialDetectionPipeline()
        return try XCTUnwrap(pipeline.selectForPresentation(frame: frame(distances),
            instrument: instrument(configuration(edge: edge, core: core, minimum: minimum)), contour: nil).objects.first)
    }
    private func hand(mixed: Int, scan: Int) -> [Int: UInt16] {
        var rays = Dictionary(uniqueKeysWithValues: (161...199).map { ($0, UInt16(30)) })
        for side in [-1, 1] {
            for index in 0..<mixed {
                rays[(side == -1 ? 160 : 200) + side * index] = UInt16(38 + index * 8 + (scan * (side + 3) % 7))
            }
        }
        return rays
    }
    func testFartherEdgesTrimBeforeDiscAndRepresentativeAndOffKeepsHistoricalGeometry() throws {
        for count in [1, 2] {
            for scan in 0..<24 {
                let input = hand(mixed: count, scan: scan)
                let off = try object(input)
                let trimmed = try object(input, edge: UInt8(count))
                XCTAssertEqual(trimmed.measuredOrders, Array(161...199))
                XCTAssertEqual(trimmed.discardedEdgeOrders.count, count * 2)
                XCTAssertEqual(trimmed.diameterMeters, 0.099, accuracy: 0.004)
                XCTAssertGreaterThan(off.diameterMeters, trimmed.diameterMeters + 0.02)
                XCTAssertEqual(trimmed.representative.distanceCentimeters, 30, accuracy: 0.001)
                let points = frame(input).projectedMeasurements
                let xs = points.map(\.point.xMeters), ys = points.map(\.point.yMeters)
                XCTAssertEqual(off.diameterMeters, hypot(xs.max()! - xs.min()!, ys.max()! - ys.min()!), accuracy: 1e-12)
            }
        }
    }
    func testDirectionStrictThresholdMinimumPointsAndOneTwoRayFingers() throws {
        XCTAssertEqual(try object([179: 20, 180: 30, 181: 20], edge: 2).measuredOrders, [179, 180, 181], "Nearer finger endpoints must survive")
        XCTAssertEqual(try object([179: 33, 180: 30, 181: 33], edge: 2).measuredOrders, [179, 180, 181], "Exactly 3 cm stays")
        XCTAssertEqual(try object([179: 34, 180: 30, 181: 34], edge: 2).measuredOrders, [180])
        for minimum in [1, 2, 3] {
            let result = try object([178: 48, 179: 40, 180: 30, 181: 40, 182: 48], edge: 2, minimum: minimum)
            XCTAssertGreaterThanOrEqual(result.measuredOrders.count, minimum)
        }
        for input in [[180: UInt16(180)], [180: 180, 181: 184]] {
            let result = try object(input, edge: 2, core: 3)
            XCTAssertFalse(result.coreOrders.isEmpty)
            XCTAssertEqual(result.representative.distanceCentimeters, 180, accuracy: 0.001)
        }
        XCTAssertEqual(try object([180: 180, 181: 180], edge: 2, core: 1, minimum: 2).measuredOrders, [180, 181])
    }
    func testCoreUsesMiddleBearingDespiteOneSidedFartherRubbishAndKeepsWholeDisc() throws {
        var input = Dictionary(uniqueKeysWithValues: (160...192).map { ($0, UInt16(30)) })
        for order in 193...200 { input[order] = UInt16(30 + (order - 192) * 8) }
        let full = try object(input)
        let core = try object(input, core: 3)
        XCTAssertEqual(core.diameterMeters, full.diameterMeters, accuracy: 1e-12)
        XCTAssertEqual(core.center, full.center)
        XCTAssertEqual(core.coreOrders, Array(175...185))
        XCTAssertEqual(core.representative.bearingDegrees, 0, accuracy: 0.51)
        XCTAssertLessThan(abs(core.representative.point.xMeters), 0.015)
        XCTAssertGreaterThan(full.representative.bearingDegrees, 2)
        XCTAssertEqual(core.coreStrip.count, 4)
    }
    func testCoreHasMetricWidthAtNearAndFarDistancesAndEveryRepresentativeUsesIt() throws {
        for raw: UInt16 in [30, 50, 100, 180] {
            let input = Dictionary(uniqueKeysWithValues: (160...200).map { ($0, raw) })
            for mode in DetectionRepresentativeMode.allCases {
                var config = configuration(core: 3); config.representative = mode
                var pipeline = SpatialDetectionPipeline()
                let result = try XCTUnwrap(pipeline.selectForPresentation(frame: frame(input), instrument: instrument(config), contour: nil).objects.first)
                XCTAssertLessThanOrEqual(abs(result.representative.point.xMeters), 0.015 + 1e-12)
                for order in result.coreOrders {
                    XCTAssertLessThanOrEqual(abs(frame(input).projectedMeasurements.first { $0.order == order }!.point.xMeters), 0.015 + 1e-12)
                }
            }
        }
    }
    func testCoreControlsActualCellEntryExitAndReentryAndConfigSwitchResetsSmoothing() throws {
        let id = UUID()
        var input = Dictionary(uniqueKeysWithValues: (160...192).map { ($0, UInt16(30)) })
        for order in 193...200 { input[order] = UInt16(30 + (order - 192) * 8) }
        let layer = SpatialDocumentLayer(id: id, name: "Core cell", color: .blue, isVisible: true,
            isActive: true, isLocked: false, isSoloed: false,
            cells: Set((175...185).compactMap { PolarDeviceLattice(tick: $0, rawCentimeters: 30) }), routings: [], cellOverrides: [:])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
        func compiled(_ core: UInt8) throws -> CompiledInstrument {
            var config = configuration(core: core); config.temporalSmoothing = .mean(window: 4)
            return try InstrumentCompiler.compile(.init(spatial: spatial, detection: config, revision: .newSession()))
        }
        var pipeline = SpatialDetectionPipeline()
        for (index, core) in [UInt8(3), 0, 3].enumerated() {
            let selected = pipeline.select(frame: frame(input, sequence: UInt64(index + 1)), instrument: try compiled(core), contour: nil)
            XCTAssertEqual(selected.activeHandles[id] != nil, core > 0)
        }
        let noHand = pipeline.select(frame: frame([:]), instrument: try compiled(3), contour: nil)
        XCTAssertTrue(noHand.activeHandles.isEmpty)
    }
    func testMetricCoreIsRotationInvariantForLeftAndRightHands() throws {
        let cases: [(UInt16, Int)] = [(30, 5), (50, 3), (100, 1), (180, 0)]
        for center in [90, 180, 270] {
            for (raw, halfCount) in cases {
                let input = Dictionary(uniqueKeysWithValues: ((center - 20)...(center + 20)).map { ($0, raw) })
                let result = try object(input, core: 3)
                XCTAssertEqual(result.coreOrders, Array((center - halfCount)...(center + halfCount)))
                XCTAssertEqual(result.representative.bearingDegrees, Double(center) / 2 - 90, accuracy: 0.001)
            }
        }
    }
    func testNarrowFingerRetainsMeasuredMMKSpanAndCoreNeverExpandsOneTwoRayInput() throws {
        for count in [90, 180, 361] {
            let geometry = ProfileGeometryIdentity(operatingMode: count == 90 ? "segmentMinimum" : "fullScan",
                pointCount: count, startAngleDegrees: -90, endAngleDegrees: 90)
            for rays in [1, 2] {
                let start = count / 2
                let measurements = (start..<(start + rays)).map {
                    DeviceTickMeasurement(order: $0, ticks: geometry.tickSpan(at: $0)!, rawCentimeters: 180)!
                }
                let id = UUID(), span = measurements.last!.ticks
                let cells = Set((span.lower...span.upper).compactMap { PolarDeviceLattice(tick: $0, rawCentimeters: 180) })
                let layer = SpatialDocumentLayer(id: id, name: "Finger", color: .blue, isVisible: true,
                    isActive: true, isLocked: false, isSoloed: false, cells: cells, routings: [], cellOverrides: [:])
                let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id)
                let compiled = try InstrumentCompiler.compile(.init(spatial: spatial, detection: configuration(edge: 2, core: 1), revision: .newSession()))
                let frame = ProfileFrame(sessionID: session, sequence: 1, time: 0, measurements: measurements, geometry: geometry)
                var pipeline = SpatialDetectionPipeline()
                let result = pipeline.selectForPresentation(frame: frame, instrument: compiled, contour: nil)
                XCTAssertNotNil(result.activeHandles[id], "\(count)/\(rays): measured MMK span must survive")
                XCTAssertEqual(result.objects.first?.coreOrders, [start + rays / 2])
            }
        }
    }
    func testCoreCalmsSyntheticMovingSideNoiseAndSmoothingOnlySeesCore() throws {
        for smoothing: DetectionTemporalSmoothing in [.off, .mean(window: 4), .median(window: 4), .exponential(alpha: 0.5)] {
            var config = configuration(core: 3); config.temporalSmoothing = smoothing
            var pipeline = SpatialDetectionPipeline()
            let compiled = try instrument(config)
            var previous: MetricScanPoint?
            for scan in 0..<30 {
                var input = hand(mixed: 2, scan: scan)
                for order in 161...170 { input[order] = UInt16(30 + (scan % 3) * 4) }
                let result = try XCTUnwrap(pipeline.selectForPresentation(frame: frame(input, sequence: UInt64(scan + 1)), instrument: compiled, contour: nil).objects.first)
                XCTAssertEqual(result.representative.distanceCentimeters, 30, accuracy: 0.001)
                if let previous { XCTAssertLessThan(hypot(previous.xMeters - result.representative.point.xMeters, previous.yMeters - result.representative.point.yMeters), 0.004) }
                previous = result.representative.point
            }
        }
    }
    func testNewAndFactoryDefaultsLegacyOmissionAndExplicitRoundTrip() throws {
        XCTAssertEqual(DetectionConfiguration.ownerDefaults.edgePoints, 1)
        XCTAssertEqual(DetectionConfiguration.ownerDefaults.coreWidthCentimeters, 3)
        let old = try JSONDecoder().decode(DetectionConfiguration.self, from: Data("{}".utf8))
        XCTAssertEqual(old.edgePoints, 0); XCTAssertEqual(old.coreWidthCentimeters, 0)
        XCTAssertEqual(old, .legacyDefaults)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertNil(encoded["edgePoints"]); XCTAssertNil(encoded["coreWidthCentimeters"])
        for edge: UInt8 in 0...2 { for core: UInt8 in [0, 1, 3, 10] {
            let value = configuration(edge: edge, core: core)
            XCTAssertEqual(try JSONDecoder().decode(DetectionConfiguration.self, from: JSONEncoder().encode(value)), value)
        }}
    }
    private func nearestObjectForMetrics(_ selection: DeviceLatticeSelection) -> DetectionObject? {
        guard let representative = selection.representative else { return nil }
        return selection.objects.first { $0.representative == representative }
    }
    func testRecordingMetricsFollowNearestMeasuredObjectEvenWhenItsMeanIsPulledFarther() throws {
        var input = Dictionary(uniqueKeysWithValues: (150...170).map { ($0, UInt16(30 + $0 - 150)) })
        for order in 230...235 { input[order] = 35 }
        var pipeline = SpatialDetectionPipeline()
        let selection = pipeline.selectForPresentation(frame: frame(input), instrument: try instrument(configuration()), contour: nil)
        let nearest = try XCTUnwrap(nearestObjectForMetrics(selection))
        XCTAssertEqual(nearest.measuredOrders, Array(150...170))
        XCTAssertGreaterThan(nearest.representative.distanceCentimeters, 35)
        XCTAssertEqual(selection.objects.min { $0.representative.distanceCentimeters < $1.representative.distanceCentimeters }?.representative.distanceCentimeters ?? 0, 35, accuracy: 0.001,
            "Sorting by the pulled representative would silently evaluate the other object")
    }
    func testOptInOwnerRecordingMetrics() throws {
        guard let path = ProcessInfo.processInfo.environment["PLANARIUM_RECORDING"] else {
            throw XCTSkip("Set PLANARIUM_RECORDING to an owner JSON recording")
        }
        let recording = try JSONDecoder().decode(ProfileRecording.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try reportMetrics(recording, label: path)
    }
    func testSyntheticRecordingMetricMatrixAndPortableRoundTrip() throws {
        let scans = (0..<80).map { scan in
            var input = hand(mixed: 2, scan: scan)
            // Deterministic pseudo-random side counts/depths; unlike a
            // symmetric silhouette this must also exercise position jitter.
            for side in [-1, 1] {
                let count = ((scan * (side == -1 ? 17 : 31) + (side == -1 ? 3 : 7)) % 11) % 2 + 1
                let first = side == -1 ? 160 : 200
                input[first] = UInt16(42 + (scan * (side == -1 ? 7 : 13) % 5))
                input[first + side] = count == 2 ? input[first]! + 20 : nil
            }
            return ProfileRecording.Scan(frame(input, sequence: UInt64(scan + 1)))
        }
        let recording = ProfileRecording(capturedAt: Date(timeIntervalSince1970: 0), detection: configuration(), contour: nil, scans: scans)
        let data = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(ProfileRecording.self, from: data)
        XCTAssertEqual(try decoded.scans[7].frame().measurements, try scans[7].frame().measurements)
        if let path = ProcessInfo.processInfo.environment["SICK_TEST_ARTIFACT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("synthetic-hand-recording.json"))
        }
        try reportMetrics(decoded, label: "SYNTHETIC 10 cm hand at 30 cm; alternating 1/2 mixed rays")
    }
    private func reportMetrics(_ recording: ProfileRecording, label: String) throws {
        guard recording.version == 1 else { throw ProfileRecording.RecordingError.unsupportedVersion }
        XCTAssertFalse(recording.scans.isEmpty)
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted(); return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        print("RANDPUNKTE recording=\(label) scans=\(recording.scans.count) threshold_cm=3 (provisional)")
        print("edge\tcore_cm\tdisc_median_cm\tdisc_p95_cm\tdisc_max_cm\tjump_median_cm\tjump_p95_cm\tobjects\tpairs")
        for edge: UInt8 in 0...2 { for core: UInt8 in [0, 2, 3, 5] {
            var config = recording.detection; config.edgePoints = edge; config.coreWidthCentimeters = core
            let compiled = try instrument(config)
            var pipeline = SpatialDetectionPipeline()
            var diameters: [Double] = [], jumps: [Double] = []
            var previous: ProfileFrame?, previousPoint: MetricScanPoint?
            for scan in recording.scans {
                let frame = try scan.frame()
                if previous?.sessionID != frame.sessionID || previous?.geometry != frame.geometry {
                    pipeline.reset(); previousPoint = nil
                }
                let selection = pipeline.select(frame: frame, instrument: compiled, contour: recording.contour)
                let nearest = nearestObjectForMetrics(selection)
                if let nearest {
                    diameters.append(nearest.diameterMeters * 100)
                    if let previousPoint { jumps.append(hypot(nearest.representative.point.xMeters - previousPoint.xMeters, nearest.representative.point.yMeters - previousPoint.yMeters) * 100) }
                }
                previousPoint = nearest?.representative.point; previous = frame
            }
            print("\(edge)\t\(core)\t" + [percentile(diameters, 0.5), percentile(diameters, 0.95), diameters.max() ?? 0,
                percentile(jumps, 0.5), percentile(jumps, 0.95)].map { String(format: "%.4f", $0) }.joined(separator: "\t") + "\t\(diameters.count)\t\(jumps.count)")
        }}
    }
}
