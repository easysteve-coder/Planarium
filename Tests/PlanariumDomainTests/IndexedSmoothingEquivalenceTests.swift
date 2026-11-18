import XCTest
import SickPLSCore
@testable import PlanariumDomain

final class IndexedSmoothingEquivalenceTests: XCTestCase {
    func testRecordedSyntheticSequencesAreBitEqualToLegacyHistorySearch() throws {
        for method: DetectionTemporalSmoothing in [.mean(window: 1), .mean(window: 4), .mean(window: 8), .median(window: 4), .median(window: 8), .exponential(alpha: 0.1), .exponential(alpha: 0.5), .exponential(alpha: 0.9)] {
            let configuration = DetectionConfiguration.allStagesOff.replacingTemporalSmoothing(method)
            let layer = SpatialDocumentLayer(id: UUID(), name: "Synthetic", color: .orange, isVisible: true, isActive: true,
                isLocked: false, isSoloed: false, cells: [], routings: [], cellOverrides: [:])
            let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
            let document = InstrumentDocument(spatial: spatial, detection: configuration, revision: .newSession())
            let compiled = try InstrumentCompiler.compile(document)
            var pipeline = SpatialDetectionPipeline(configuration: configuration)
            var history: [[ProjectedScanMeasurement]] = [], exponential: [Int: Double] = [:]
            for sample in 0..<160 {
                let count = sample < 80 ? 90 : 361
                if sample == 64 || sample == 80 { pipeline.reset(); history = []; exponential = [:] }
                let raw = try B0ScanProfile.build(partialScanIndex: 0, measurements: (0..<count).map { order in
                    let value: UInt16 = (order + sample) % 11 == 0 ? 8191 : (order + sample) % 13 == 0 ? 0 : UInt16(50 + (sample * 37 + order * 19) % 700)
                    return try .build(value: value, fieldFlags: UInt8((order + sample) % 8))
                })
                let frame = ProfileFrame(sessionID: UUID(), sequence: UInt64(sample), time: Double(sample),
                    measurements: try FullScanProfileAdapter.measurements(from: raw), geometry: try FullScanProfileAdapter.geometry(from: raw), rawProfile: raw)
                let current = frame.projectedMeasurements.filter { UsableRawDistance.contains($0.distanceCentimeters) }
                history.append(current)
                let window: Int
                switch method { case .mean(let n), .median(let n): window = max(1, n); case .off, .exponential: window = 1 }
                if history.count > max(window, 8) { history.removeFirst(history.count - max(window, 8)) }
                let expected = current.map { point -> ProjectedScanMeasurement in
                    let sameOrder = history.flatMap { $0 }.filter { $0.order == point.order }
                    let value: Double
                    switch method {
                    case .mean(let n): value = sameOrder.suffix(max(1, n)).map { Double($0.distanceCentimeters) }.reduce(0, +) / Double(max(1, sameOrder.suffix(max(1, n)).count))
                    case .median(let n): let sorted = sameOrder.suffix(max(1, n)).map { Double($0.distanceCentimeters) }.sorted(); value = sorted.isEmpty ? Double(point.distanceCentimeters) : sorted[sorted.count / 2]
                    case .exponential(let alpha): value = alpha * Double(point.distanceCentimeters) + (1 - alpha) * (exponential[point.order] ?? Double(point.distanceCentimeters)); exponential[point.order] = value
                    case .off: value = Double(point.distanceCentimeters)
                    }
                    return .init(order: point.order, normalizedIndex: point.normalizedIndex,
                        distanceCentimeters: UInt16(min(max(value.rounded(), 0), Double(UInt16.max))), fieldFlags: point.fieldFlags,
                        point: .init(xMeters: point.point.xMeters * value / max(Double(point.distanceCentimeters), 1), yMeters: point.point.yMeters * value / max(Double(point.distanceCentimeters), 1)))
                }
                _ = pipeline.select(frame: frame, instrument: compiled, contour: nil)
                let actual = pipeline.smooth(current, advanceExponential: false)
                XCTAssertEqual(actual, expected, "method=\(method), sample=\(sample), count=\(count)")
                for (a, b) in zip(actual, expected) {
                    XCTAssertEqual(a.point.xMeters.bitPattern, b.point.xMeters.bitPattern)
                    XCTAssertEqual(a.point.yMeters.bitPattern, b.point.yMeters.bitPattern)
                }
            }
        }
    }
}
