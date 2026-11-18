import XCTest
@testable import SickPLSSimulationLink
import SickPLSControlCore
import SickPLSCore

final class SimulationLinkTests: XCTestCase {
    func testEncoderUsesScannerAddressAndTrailingByte() throws {
        let bytes = try B0TelegramEncoder.frameBytes(values: [90, 8191], trailingByte: 7)
        XCTAssertEqual(bytes[1], SimulationLinkConstants.scannerSourceAddress)
        XCTAssertEqual(bytes.count, 4 + 3 + 4 + 1 + 2)
    }

    func testEncoderRejectsValuesAboveThirteenBits() {
        XCTAssertThrowsError(try B0TelegramEncoder.frameBytes(values: [8192]))
    }

    func testEmptyAndRoomBackground() {
        var rng = SplitMix64(seed: 1)
        XCTAssertTrue(SimulatedScanner.profileValues(hands: [], configuration: SimulationConfiguration(pointCount: 90), rng: &rng).allSatisfy { $0 == 8191 })
        rng = SplitMix64(seed: 1)
        let values = SimulatedScanner.profileValues(hands: [], configuration: SimulationConfiguration(pointCount: 361, background: .room(widthCm: 200, depthCm: 200)), rng: &rng)
        XCTAssertEqual(values[180], 200); XCTAssertEqual(values.first, 100); XCTAssertEqual(values.last, 100)
        XCTAssertEqual(values[270], 141)
    }

    func testHandBeamAndOcclusion() {
        var rng = SplitMix64(seed: 2)
        let hand = SimulationHand(x: 0, y: 100.5, radiusCm: 4.5)
        let values = SimulatedScanner.profileValues(hands: [hand], configuration: SimulationConfiguration(pointCount: 361, sampling: .singleRay), rng: &rng)
        XCTAssertEqual(values[180], 96)
        XCTAssertLessThan(values[175], 8191); XCTAssertLessThan(values[185], 8191)
        XCTAssertEqual(values[174], 8191); XCTAssertEqual(values[186], 8191)
        rng = SplitMix64(seed: 2)
        let blocked = SimulatedScanner.profileValues(hands: [hand, SimulationHand(x: 0, y: 150, radiusCm: 4)], configuration: SimulationConfiguration(pointCount: 361, sampling: .singleRay), rng: &rng)
        XCTAssertLessThan(blocked[180], 110)
        var ninetyRng = SplitMix64(seed: 2)
        let ninety = SimulatedScanner.profileValues(hands: [hand], configuration: SimulationConfiguration(pointCount: 90, sampling: .singleRay), rng: &ninetyRng)
        XCTAssertLessThan(ninety[44], 8191); XCTAssertLessThan(ninety[45], 8191)
        XCTAssertEqual(ninety[43], 8191); XCTAssertEqual(ninety[46], 8191)
    }

    func testOcclusionAndSideHandAreSpatiallyVisible() {
        var rng = SplitMix64(seed: 4)
        let values = SimulatedScanner.profileValues(hands: [SimulationHand(x: 0, y: 100, radiusCm: 4), SimulationHand(x: 0, y: 150, radiusCm: 4), SimulationHand(x: 40, y: 150, radiusCm: 4)], configuration: SimulationConfiguration(pointCount: 361, sampling: .singleRay), rng: &rng)
        XCTAssertFalse(values.contains { (140...150).contains(Int($0)) })
        XCTAssertTrue(values.contains { $0 < 140 })
    }

    func testTangentAndCenterClamp() {
        var rng = SplitMix64(seed: 5)
        let tangent = SimulationHand(x: 0, y: 100, radiusCm: 4)
        let angle = atan(5.0 / 100.0) * 180.0 / .pi
        let index = Int(((angle + 90.0) / 180.0 * 360.0).rounded())
        let values = SimulatedScanner.profileValues(hands: [tangent], configuration: SimulationConfiguration(pointCount: 361, sampling: .singleRay), rng: &rng)
        XCTAssertEqual(values[index], 8191)
        rng = SplitMix64(seed: 5)
        XCTAssertEqual(SimulatedScanner.profileValues(hands: [SimulationHand(x: 0, y: 0, radiusCm: 4)], configuration: SimulationConfiguration(pointCount: 361, sampling: .singleRay), rng: &rng)[180], 1)
    }

    func testMinimumPerBinSeesNarrowHandBetweenNinetyRays() {
        let angle = -90.0 + 180.0 * 44.5 / 89.0
        let radians = angle * .pi / 180.0
        let hand = SimulationHand(x: sin(radians) * 100, y: cos(radians) * 100, radiusCm: 1)
        var singleRng = SplitMix64(seed: 6)
        let single = SimulatedScanner.profileValues(hands: [hand], configuration: SimulationConfiguration(pointCount: 90, sampling: .singleRay), rng: &singleRng)
        var minimumRng = SplitMix64(seed: 6)
        let minimum = SimulatedScanner.profileValues(hands: [hand], configuration: SimulationConfiguration(pointCount: 90, sampling: .minimumPerBin), rng: &minimumRng)
        XCTAssertEqual(single[44], 8191); XCTAssertEqual(single[45], 8191)
        XCTAssertLessThan(minimum[44], 8191)
    }

    func testNoiseIsSeededAndRangeEndIsUntouched() {
        var a = SplitMix64(seed: 42); var b = SplitMix64(seed: 42)
        let config = SimulationConfiguration(pointCount: 361, noiseEnabled: true)
        let hands = [SimulationHand(x: 0, y: 100, radiusCm: 4)]
        XCTAssertEqual(SimulatedScanner.profileValues(hands: hands, configuration: config, rng: &a), SimulatedScanner.profileValues(hands: hands, configuration: config, rng: &b))
        var c = SplitMix64(seed: 1)
        XCTAssertTrue(SimulatedScanner.profileValues(hands: [], configuration: config, rng: &c).allSatisfy { $0 == 8191 })
        var valuesRng = SplitMix64(seed: 7)
        let baseline = SimulatedScanner.profileValues(hands: hands, configuration: SimulationConfiguration(pointCount: 361), rng: &valuesRng)[180]
        var samplesRng = SplitMix64(seed: 8)
        let samples = (0..<1000).map { _ in Int(SimulatedScanner.profileValues(hands: hands, configuration: config, rng: &samplesRng)[180]) - Int(baseline) }
        XCTAssertTrue(samples.allSatisfy { (-3...3).contains($0) }); XCTAssertGreaterThanOrEqual(Set(samples).count, 5)
        var offRng = SplitMix64(seed: 8)
        XCTAssertEqual(SimulatedScanner.profileValues(hands: hands, configuration: SimulationConfiguration(pointCount: 361), rng: &offRng)[180], baseline)
    }

    func testMappingKeepsAspectAndRoundTrips() {
        let mapping = FieldScreenMapping(fieldWidthCm: 200, fieldDepthCm: 300, viewWidth: 500, viewHeight: 500)
        XCTAssertEqual(mapping.scannerScreenPoint.x, 250, accuracy: 0.001)
        let point = SimulationPoint(x: 30, y: 120)
        XCTAssertEqual(mapping.fieldPoint(for: mapping.screenPoint(for: point)), point)
    }

    func testPaletteIsPlatformNeutral() {
        XCTAssertEqual(PlanariumPalette.amber.alpha, 1)
        XCTAssertEqual(PlanariumPalette.amberBright.red, 1, accuracy: 0.001)
    }

    func testEncodedFramesHaveRequiredLengths() throws {
        XCTAssertEqual(try B0TelegramEncoder.frameBytes(values: Array(repeating: 8191, count: 90)).count, 190)
        XCTAssertEqual(try B0TelegramEncoder.frameBytes(values: Array(repeating: 8191, count: 361)).count, 732)
        for values in [[UInt16](repeating: 123, count: 90), [UInt16](repeating: 456, count: 361)] {
            var parser = StreamParser()
            let frames = parser.feed(try B0TelegramEncoder.frameBytes(values: values))
            let frame = try XCTUnwrap(frames.first)
            guard case let .success(profile) = B0ScanProfile.decode(from: frame.payload) else { XCTFail("B0 decode failed"); return }
            XCTAssertEqual(profile.measurements.map(\.value), values); XCTAssertEqual(profile.trailingBytes.count, 1)
        }
    }

    func testProjectedProfileHasExpectedOrientation() throws {
        var rng = SplitMix64(seed: 3)
        let values = SimulatedScanner.profileValues(hands: [SimulationHand(x: -50, y: 50, radiusCm: 3)], configuration: SimulationConfiguration(pointCount: 361, sampling: .singleRay), rng: &rng)
        let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: values.map { try! B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0) })
        let points = MetricScanProjection().project(profile)
        XCTAssertTrue(points.allSatisfy { $0.point.xMeters < 0 })
    }

    func testRoundTripNearestPointForFiveHandLocationsAndBothPointCounts() throws {
        let hands = [SimulationHand(x: -60, y: 80, radiusCm: 4), SimulationHand(x: -25, y: 140, radiusCm: 4), SimulationHand(x: 0, y: 110, radiusCm: 4), SimulationHand(x: 35, y: 160, radiusCm: 4), SimulationHand(x: 60, y: 90, radiusCm: 4)]
        for count in [90, 361] {
            for hand in hands {
                var rng = SplitMix64(seed: UInt64(count))
                let values = SimulatedScanner.profileValues(hands: [hand], configuration: SimulationConfiguration(pointCount: count, sampling: .singleRay), rng: &rng)
                let measurements = values.map { try! B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0) }
                let profile = try B0ScanProfile.build(partialScanIndex: 0, measurements: measurements)
                let projected = MetricScanProjection().project(profile)
                let targetX = hand.center.x / 100.0, targetY = hand.center.y / 100.0
                let nearest = try XCTUnwrap(projected.min { lhs, rhs in
                    let ld = hypot(lhs.point.xMeters - targetX, lhs.point.yMeters - targetY)
                    let rd = hypot(rhs.point.xMeters - targetX, rhs.point.yMeters - targetY)
                    return ld < rd
                })
                let error = hypot(nearest.point.xMeters - targetX, nearest.point.yMeters - targetY)
                XCTAssertLessThanOrEqual(error, hand.radiusCm / 100.0 + 0.015)
                if abs(targetX) > 0.001 { XCTAssertEqual(nearest.point.xMeters.sign == targetX.sign, true) }
            }
        }
    }
}
