import XCTest
import SickPLSCore
@testable import SickPLSDiagnosticCLI

/// Referenzreihen je Scanindex (SICK-034d): Kennzahlen statt Rohwerte,
/// leere Reihe erklärt, `--index` als Option.
final class ReferenceSeriesTests: XCTestCase {

    private struct LegacyStatistics: Equatable {
        let sampleCount: Int
        let minimum: UInt16
        let maximum: UInt16
        let median: Double
        let mean: Double
        let standardDeviation: Double
        let countAtZero: Int
        let countAtMaximum: Int
    }

    private struct ReproducibleGenerator {
        private var state: UInt64 = 0x9E3779B97F4A7C15

        mutating func next() -> UInt32 {
            state = state &* 2862933555777941757 &+ 3037000493
            return UInt32(truncatingIfNeeded: state >> 16)
        }
    }

    private func profile(values: [UInt16]) throws -> B0ScanProfile {
        var payload: [UInt8] = [B0ScanProfile.commandByte, UInt8(values.count & 0xFF), UInt8((values.count >> 8) & 0x03)]
        for value in values {
            payload.append(UInt8(value & 0xFF))
            payload.append(UInt8((value >> 8) & 0xFF))
        }
        payload.append(0x00)
        return try B0ScanProfile.decode(from: payload).get()
    }

    private func singleValueProfile(_ value: UInt16) throws -> B0ScanProfile {
        try B0ScanProfile.build(
            partialScanIndex: 0,
            measurements: [try B0ScanProfile.Measurement.build(value: value, fieldFlags: 0)]
        )
    }

    private func legacyStatistics(_ values: [UInt16]) -> LegacyStatistics {
        let sorted = values.sorted()
        let count = sorted.count
        let median: Double
        if count % 2 == 0 {
            median = (Double(sorted[count / 2 - 1]) + Double(sorted[count / 2])) / 2
        } else {
            median = Double(sorted[count / 2])
        }
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(count)
        let variance: Double
        if count > 1 {
            variance = values.reduce(0.0) {
                $0 + (Double($1) - mean) * (Double($1) - mean)
            } / Double(count - 1)
        } else {
            variance = 0
        }
        return LegacyStatistics(
            sampleCount: count,
            minimum: sorted[0],
            maximum: sorted[count - 1],
            median: median,
            mean: mean,
            standardDeviation: variance.squareRoot(),
            countAtZero: values.filter { $0 == 0 }.count,
            countAtMaximum: values.filter { $0 == B0ScanProfile.measurementValueMaximum }.count
        )
    }

    private func assertBitEqual(
        _ actual: ReferenceSeriesStatistics,
        _ expected: LegacyStatistics,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.sampleCount, expected.sampleCount, file: file, line: line)
        XCTAssertEqual(actual.minimum, expected.minimum, file: file, line: line)
        XCTAssertEqual(actual.maximum, expected.maximum, file: file, line: line)
        XCTAssertEqual(actual.median, expected.median, file: file, line: line)
        XCTAssertEqual(actual.mean, expected.mean, file: file, line: line)
        // Die alte Rechnung summierte die gerundeten Double-Terme in
        // Eingabereihenfolge; das Histogramm summiert ohne Reihenfolge.
        // Dadurch sind einzelne ULPs verschieden, obwohl die Kennzahl
        // mathematisch identisch ist.
        XCTAssertEqual(
            actual.standardDeviation,
            expected.standardDeviation,
            accuracy: 1e-11,
            file: file,
            line: line
        )
        XCTAssertEqual(actual.countAtZero, expected.countAtZero, file: file, line: line)
        XCTAssertEqual(actual.countAtMaximum, expected.countAtMaximum, file: file, line: line)
    }

    func testStatisticsOverASeriesWithSpread() throws {
        var series = ReferenceIndexSeries(index: 1)
        for value in [100, 102, 98, 100, 8191, 0] as [UInt16] {
            series.record(try profile(values: [7, value, 9]))
        }
        let statistics = try XCTUnwrap(series.statistics())
        XCTAssertEqual(statistics.index, 1)
        XCTAssertEqual(statistics.sampleCount, 6)
        XCTAssertEqual(statistics.minimum, 0)
        XCTAssertEqual(statistics.maximum, 8191)
        XCTAssertEqual(statistics.median, 100)
        XCTAssertEqual(statistics.mean, 1431.8333, accuracy: 0.001)
        XCTAssertEqual(statistics.standardDeviation, 3311.54, accuracy: 0.01)
        XCTAssertEqual(statistics.countAtZero, 1)
        XCTAssertEqual(statistics.countAtMaximum, 1)
        XCTAssertEqual(statistics.profilesWithoutIndex, 0)
    }

    func testAProfileWithoutTheIndexIsCountedNotSampled() throws {
        var series = ReferenceIndexSeries(index: 180)
        series.record(try profile(values: Array(repeating: 50, count: 90)))
        XCTAssertNil(series.statistics())
        XCTAssertEqual(series.profilesWithoutIndex, 1)
        XCTAssertEqual(
            describeEmptyReferenceSeries(series),
            "Reference index 180: no values (profiles without this index: 1)"
        )
    }

    func testASingleSampleHasZeroSpread() throws {
        var series = ReferenceIndexSeries(index: 0)
        series.record(try profile(values: [1234]))
        let statistics = try XCTUnwrap(series.statistics())
        XCTAssertEqual(statistics.standardDeviation, 0)
        XCTAssertEqual(statistics.mean, 1234)
        XCTAssertEqual(statistics.median, 1234)
    }

    func testTheDescriptionCarriesOnlyAggregatesInAFixedFormat() throws {
        var series = ReferenceIndexSeries(index: 45)
        for value in [1500, 1502, 1498, 1500] as [UInt16] {
            series.record(try profile(values: Array(repeating: value, count: 90)))
        }
        let line = describe(try XCTUnwrap(series.statistics()))
        XCTAssertEqual(
            line,
            "Reference index 45: n=4 min=1498 max=1502 median=1500.0 mean=1500.00 sigma=1.63 countAtZero=0 countAt8191=0 withoutIndex=0"
        )
    }

    func testHistogramStatisticsAreBitEqualToTheLegacyCalculation() throws {
        var generator = ReproducibleGenerator()
        var cases: [[UInt16]] = [
            [0],
            [B0ScanProfile.measurementValueMaximum],
            Array(repeating: 1234, count: 10),
            [0, B0ScanProfile.measurementValueMaximum]
        ]
        for caseIndex in 0..<196 {
            let count = caseIndex + 1
            let values = (0..<count).map { _ in
                UInt16(generator.next() % UInt32(B0ScanProfile.measurementValueMaximum + 1))
            }
            cases.append(values)
        }

        for values in cases {
            var series = ReferenceIndexSeries(index: 0)
            for value in values {
                series.record(try singleValueProfile(value))
            }
            let actual = try XCTUnwrap(series.statistics())
            assertBitEqual(actual, legacyStatistics(values))
        }
    }

    func testStatisticsCostUsesFixedWorkAfterRecording() throws {
        let sizes = [500, 1_000, 5_000, 25_000]
        var measuredMilliseconds: [Double] = []
        for size in sizes {
            var series = ReferenceIndexSeries(index: 0)
            let profile = try singleValueProfile(4096)
            for _ in 0..<size {
                series.record(profile)
            }

            let start = DispatchTime.now().uptimeNanoseconds
            var sampleCount = 0
            for _ in 0..<25 {
                sampleCount += try XCTUnwrap(series.statistics()).sampleCount
            }
            let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            measuredMilliseconds.append(elapsedMilliseconds / 25)
            XCTAssertEqual(sampleCount, size * 25)
        }
        for (size, milliseconds) in zip(sizes, measuredMilliseconds) {
            print("STAT-1 statistics n=\(size): \(milliseconds) ms/Aufruf")
        }
    }

    func testHistogramStorageDoesNotGrowWithOneHundredThousandSamples() throws {
        var series = ReferenceIndexSeries(index: 0)
        let profile = try singleValueProfile(8191)
        for _ in 0..<100_000 {
            series.record(profile)
        }

        let children = Array(Mirror(reflecting: series).children)
        let histogram = try XCTUnwrap(
            children.first { $0.label == "histogram" }?.value as? [Int]
        )
        XCTAssertEqual(histogram.count, 8192)
        XCTAssertEqual(histogram.count * MemoryLayout<Int>.stride, 8192 * MemoryLayout<Int>.stride)
        XCTAssertFalse(children.contains { $0.label == "values" })
        XCTAssertEqual(try XCTUnwrap(series.statistics()).sampleCount, 100_000)
    }

    // MARK: - --index

    func testIndexOptionIsRepeatableAndDeduplicated() throws {
        let options = try parseArguments(["--index", "45", "--index", "0", "--index", "45"])
        XCTAssertEqual(options.referenceIndices, [45, 0])
    }

    func testIndexOptionRejectsValuesOutsideTheProfileRange() {
        XCTAssertThrowsError(try parseArguments(["--index", "361"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .invalidIndex("361"))
        }
        XCTAssertThrowsError(try parseArguments(["--index", "-1"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .invalidIndex("-1"))
        }
        XCTAssertThrowsError(try parseArguments(["--index"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .missingValue(option: "--index"))
        }
        XCTAssertEqual(message(for: .invalidIndex("x")), "--index requires a scan index 0–360, got \"x\".")
    }

    func testUsageMentionsTheReferenceOption() {
        XCTAssertTrue(usageText.contains("--index <n>"))
        XCTAssertTrue(usageText.contains("statistics only"))
    }
}
