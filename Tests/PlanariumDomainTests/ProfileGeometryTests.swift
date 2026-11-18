import XCTest
import PlanariumDomain
import SickPLSCore
import SickPLSControlCore

final class ProfileGeometryTests: XCTestCase {
    func testMMKRepresentativeRetainsTheWholeMeasuredSpanWithDetectionEnabled() throws {
        for count in [90, 180, 361] {
            for index in [0, count / 2, count - 1] {
                let values = (0..<count).map { try! B0ScanProfile.Measurement.build(value: $0 == index ? 100 : 8191, fieldFlags: 0) }
                let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: values)
                let geometry = try FullScanProfileAdapter.geometry(from: profile)
                let span = try XCTUnwrap(geometry.tickSpan(at: index))
                let layers = (span.lower...span.upper).map { tick in
                    SpatialDocumentLayer(id: UUID(), name: "Span tick \(tick)", color: .blue, isVisible: true,
                        isActive: true, isLocked: false, isSoloed: false,
                        cells: [PolarDeviceLattice(tick: tick, rawCentimeters: 100)!], routings: [], cellOverrides: [:])
                }
                let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id)
                let frame = ProfileFrame(sessionID: UUID(), sequence: 1, time: 0,
                    measurements: try FullScanProfileAdapter.measurements(from: profile), geometry: geometry, rawProfile: profile)
                var configurations = [DetectionConfiguration.allStagesOff]
                for mode in [DetectionRepresentativeMode.nearestPoint, .mean, .median, .nearestPointWithOffset] {
                    for smoothing in [DetectionTemporalSmoothing.off, .mean(window: 3), .median(window: 3), .exponential(alpha: 0.5)] {
                        configurations.append(.init(temporalSmoothing: smoothing, representative: mode,
                            cellSelection: .init(boundaryMarginCentimeters: 2, confirmationProfiles: 2),
                            roomContour: .init(isEnabled: true, toleranceCentimeters: 5)))
                    }
                }
                for configuration in configurations {
                    let document = InstrumentDocument(spatial: spatial, detection: configuration, revision: .newSession())
                    var detection = SpatialDetectionPipeline()
                    XCTAssertEqual(detection.select(frame: frame, instrument: try InstrumentCompiler.compile(document), contour: nil).activeHandles.count,
                        layers.count, "count \(count), sample \(index), config \(configuration)")
                }
            }
        }
    }
    func testEveryProductResolutionPartitionsEveryTickExactlyOnceIncludingEndpoints() throws {
        for count in [90, 180, 361] {
            let profile = try B0ScanProfile.build(partialScanIndex: 0,
                measurements: (0..<count).map { _ in try .build(value: 100, fieldFlags: 3) })
            let geometry = try FullScanProfileAdapter.geometry(from: profile)
            let values = try FullScanProfileAdapter.measurements(from: profile, geometry: geometry)
            XCTAssertEqual(values.count, count)
            XCTAssertEqual(values.map(\.order), Array(0..<count))
            XCTAssertEqual(values.flatMap { Array($0.ticks.lower...$0.ticks.upper) }, Array(0...360))
            let projected = geometry.project(values, rawProfile: profile)
            XCTAssertEqual(projected.map(\.fieldFlags), Array(repeating: 3, count: count))
            let firstUpper = count == 90 ? 2 : count == 180 ? 1 : 0
            XCTAssertEqual(values.first?.ticks, .init(lower: 0, upper: firstUpper))
            XCTAssertEqual(values.last?.ticks, .init(lower: 360 - firstUpper, upper: 360))
            XCTAssertNil(geometry.tickSpan(at: -1)); XCTAssertNil(geometry.tickSpan(at: count))
        }
    }
    func testUnusableMMKValueLeavesOnlyItsOriginalSpanEmptyWithoutRedistribution() throws {
        var values = (0..<90).map { _ in try! B0ScanProfile.Measurement.build(value: 100, fieldFlags: 0) }
        values[44] = try .build(value: 8191, fieldFlags: 0)
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: values)
        let geometry = try FullScanProfileAdapter.geometry(from: profile)
        let adapted = try FullScanProfileAdapter.measurements(from: profile)
        let rejectedSpan = try XCTUnwrap(geometry.tickSpan(at: 44))
        XCTAssertFalse(adapted.contains { $0.order == 44 })
        XCTAssertEqual(adapted.flatMap { Array($0.ticks.lower...$0.ticks.upper) },
                       Array(0...360).filter { !(rejectedSpan.lower...rejectedSpan.upper).contains($0) })
    }
    func testUnknownCountsAndEveryPartialIndexRejectBeforeProjection() throws {
        for count in [0, 1, 89, 91, 179, 181, 360, 362] {
            let profile = try B0ScanProfile.build(partialScanIndex: 0,
                measurements: (0..<count).map { _ in try .build(value: 100, fieldFlags: 0) })
            XCTAssertThrowsError(try FullScanProfileAdapter.geometry(from: profile))
        }
        for partial in UInt8(1)...UInt8(3) {
            let profile = try B0ScanProfile.build(partialScanIndex: partial,
                measurements: (0..<90).map { _ in try .build(value: 100, fieldFlags: 0) })
            XCTAssertThrowsError(try FullScanProfileAdapter.measurements(from: profile))
        }
    }
}
