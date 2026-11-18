import XCTest
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSDiagnosticCLI

final class CLIReportingTests: XCTestCase {

    // MARK: - describe(_ baudRate:) (SICK-010-Scope-Änderung)

    func testDescribeBaud9600MarksItAsUnvalidatedOwnerReportedStartValue() {
        let text = describe(SerialPortBaudRate.baud9600)
        XCTAssertTrue(text.contains("9600"))
        XCTAssertTrue(text.contains("not yet validated"))
    }

    func testDescribeBaud38400MarksItAsHistoricalTargetValue() {
        let text = describe(SerialPortBaudRate.baud38400)
        XCTAssertTrue(text.contains("38400"))
        XCTAssertTrue(text.contains("historically"))
    }

    private func measurement(_ value: UInt16, fieldFlags: UInt8 = 0) -> B0ScanProfile.Measurement {
        try! B0ScanProfile.Measurement.build(value: value, fieldFlags: fieldFlags)
    }

    /// Baut eine B0-Payload nach `b0-scan-profile.md` §1 -- mit genau
    /// einem angehängten, uninterpretierten Trailerbyte (SICK-006: die
    /// real erwartete `4+2*N`-Drahtform).
    private func b0Payload(partialScanIndex: UInt8, measurements: [B0ScanProfile.Measurement]) -> [UInt8] {
        let count = measurements.count
        let numLow = UInt8(count & 0xFF)
        let numHigh = UInt8((count >> 8) & 0x03)
        let headerByte2 = numHigh | (partialScanIndex << 3)

        var payload: [UInt8] = [B0ScanProfile.commandByte, numLow, headerByte2]
        for measurement in measurements {
            let raw = UInt16(measurement.fieldFlags) << 13 | measurement.value
            payload.append(UInt8(raw & 0xFF))
            payload.append(UInt8((raw >> 8) & 0xFF))
        }
        payload.append(0x00)
        return payload
    }

    // MARK: - hexByte

    func testHexBytePadsSingleDigitValues() {
        XCTAssertEqual(hexByte(0x02), "0x02")
        XCTAssertEqual(hexByte(0xB0), "0xB0")
        XCTAssertEqual(hexByte(0x00), "0x00")
        XCTAssertEqual(hexByte(0xFF), "0xFF")
    }

    // MARK: - computeStatistics (M5)

    func testEmptyMeasurementsYieldsNilStatistics() {
        XCTAssertNil(computeStatistics(for: []))
    }

    func testSingleMeasurementStatistics() {
        let statistics = computeStatistics(for: [measurement(42)])!
        XCTAssertEqual(statistics.measurementCount, 1)
        XCTAssertEqual(statistics.minimum, 42)
        XCTAssertEqual(statistics.maximum, 42)
        XCTAssertEqual(statistics.median, 42)
        XCTAssertEqual(statistics.countAtZero, 0)
        XCTAssertEqual(statistics.countAtMaximum, 0)
        XCTAssertEqual(statistics.largestNeighborJump, 0)
    }

    func testOddCountMedianIsMiddleValue() {
        let statistics = computeStatistics(for: [measurement(10), measurement(30), measurement(20)])!
        XCTAssertEqual(statistics.median, 20)
        XCTAssertEqual(statistics.minimum, 10)
        XCTAssertEqual(statistics.maximum, 30)
    }

    func testEvenCountMedianIsAverageOfMiddleTwo() {
        let statistics = computeStatistics(for: [measurement(10), measurement(20), measurement(30), measurement(40)])!
        XCTAssertEqual(statistics.median, 25)
    }

    func testEvenCountMedianCanBeHalfInteger() {
        let statistics = computeStatistics(for: [measurement(10), measurement(21)])!
        XCTAssertEqual(statistics.median, 15.5)
    }

    func testCountAtZeroAndCountAtMaximumAreCountedIndependentlyOfOrder() {
        let statistics = computeStatistics(for: [
            measurement(0), measurement(8191), measurement(0), measurement(500), measurement(8191)
        ])!
        XCTAssertEqual(statistics.countAtZero, 2)
        XCTAssertEqual(statistics.countAtMaximum, 2)
        XCTAssertEqual(statistics.measurementCount, 5)
    }

    func testLargestNeighborJumpUsesReceivedOrderNotSortedOrder() {
        // Nachbarn im Sinne der Empfangsreihenfolge: |100-0|=100,
        // |4000-100|=3900, |3990-4000|=10, |8191-3990|=4201 -- der größte
        // Nachbarsprung (4201) ist hier ungleich dem größten Sprung
        // zwischen zwei beliebigen (sortierten) Werten, illustriert aber
        // vor allem: die Reihenfolge der Eingabe zählt, nicht die Sortierung.
        let statistics = computeStatistics(for: [
            measurement(0), measurement(100), measurement(4000), measurement(3990), measurement(8191)
        ])!
        XCTAssertEqual(statistics.largestNeighborJump, 4201)
    }

    func testLargestNeighborJumpHandlesDescendingPairs() {
        let statistics = computeStatistics(for: [measurement(500), measurement(50)])!
        XCTAssertEqual(statistics.largestNeighborJump, 450)
    }

    // MARK: - describe(_ frame:) (N7: keine Rohbytes)

    func testDescribeB0FrameSummaryLineNamesCountsNotIndividualMeasurements() throws {
        // Bei genügend vielen Punkten liegt die Mehrheit der Rohwerte
        // (hier: die mittleren 8 von 10) weder bei min/max noch beim
        // Median -- sie dürfen an keiner Stelle der Ausgabe auftauchen
        // (N7: aggregiert statt roh). min/max/Median selbst können
        // erwartungsgemäß mit realen Punktwerten übereinstimmen (das ist
        // Aggregation, kein Rohdump) und werden hier bewusst nicht
        // gegengeprüft.
        let values: [UInt16] = [50, 60, 70, 80, 90, 100, 110, 120, 130, 999]
        let measurements = values.map { measurement($0) }
        let payload = b0Payload(partialScanIndex: 0, measurements: measurements)

        let frame = try Frame.build(address: 0x00, payload: payload)
        let lines = describe(frame)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("measurements=10"))
        XCTAssertTrue(lines[0].contains("partialScanIndex=0"))
        XCTAssertTrue(lines[0].contains("trailingBytes.count=1"))
        for hiddenValue in [60, 70, 80, 90, 100, 110, 120, 130] {
            XCTAssertFalse(
                lines.contains { $0.contains(String(hiddenValue)) },
                "Einzelmesswert \(hiddenValue) (weder min/max/median) darf nicht in der Ausgabe auftauchen"
            )
        }
    }

    func testDescribeB0FrameWithMeasurementsAppendsStatisticsLine() throws {
        let payload = b0Payload(partialScanIndex: 0, measurements: [measurement(10), measurement(20)])

        let frame = try Frame.build(address: 0x00, payload: payload)
        let lines = describe(frame)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("min=10"))
        XCTAssertTrue(lines[1].contains("max=20"))
    }

    func testDescribeNonB0FrameProducesSingleSummaryLineWithoutPayloadBytes() throws {
        let frame = try Frame.build(address: 0x01, payload: [0xAB, 0xCD, 0xEF])
        let lines = describe(frame)

        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("AB"))
        XCTAssertFalse(lines[0].contains("CD"))
        XCTAssertTrue(lines[0].contains("payload.count=3"))
    }
}
