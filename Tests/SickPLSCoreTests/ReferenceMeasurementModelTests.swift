import XCTest
import SickPLSCore

final class ReferenceMeasurementModelTests: XCTestCase {
    private func profile(_ values: [UInt16]) throws -> B0ScanProfile {
        let measurements = try values.map {
            try B0ScanProfile.Measurement.build(value: $0, fieldFlags: 0)
        }
        return try B0ScanProfile.build(partialScanIndex: 0, measurements: measurements)
    }

    func testPausedModelDoesNotCollect() throws {
        var model = try ReferenceMeasurementModel(index: 1)
        model.record(try profile([10, 20]))
        XCTAssertNil(model.statistics)
        XCTAssertFalse(model.isRunning)
    }

    func testRunningModelCollectsThreeProfiles() throws {
        var model = try ReferenceMeasurementModel(index: 1)
        model.start()
        for value in [10, 20, 30] {
            model.record(try profile([0, UInt16(value)]))
        }
        XCTAssertEqual(model.statistics?.sampleCount, 3)
    }

    func testIndexChangeDiscardsTheOldSeries() throws {
        var model = try ReferenceMeasurementModel(index: 1)
        model.start()
        model.record(try profile([0, 10]))
        model.record(try profile([0, 20]))
        try model.selectIndex(0)
        model.record(try profile([30]))
        XCTAssertEqual(model.statistics?.sampleCount, 1)
        XCTAssertEqual(model.statistics?.index, 0)
    }

    func testRestartStartsAtZero() throws {
        var model = try ReferenceMeasurementModel(index: 0)
        model.start()
        model.record(try profile([10]))
        model.stop()
        model.start()
        XCTAssertNil(model.statistics)
    }

    func testProfileWithoutSelectedIndexIsCounted() throws {
        var model = try ReferenceMeasurementModel(index: 180)
        model.start()
        model.record(try profile(Array(repeating: 50, count: 90)))
        XCTAssertNil(model.statistics)
        XCTAssertEqual(model.profilesWithoutIndex, 1)
    }

    /// Die **Kante** festnageln, nicht nur weit daneben prüfen.
    ///
    /// `-1` und `361` bleiben auch dann ungültig, wenn die Grenze
    /// versehentlich auf 359 rutscht — gemessen am 28.09.2026: eine solche
    /// Mutation machte nur den CLI-Test rot, keinen einzigen Modelltest.
    /// Erst 360 als **gültiger** Wert pinnt die Grenze wirklich.
    func testTheLastValidIndexIsAccepted() throws {
        var model = try ReferenceMeasurementModel(index: referenceIndexMaximum)
        XCTAssertEqual(model.selectedIndex, 360)
        XCTAssertNoThrow(try model.selectIndex(referenceIndexMaximum))

        // Und der erste ungültige liegt genau daneben.
        XCTAssertThrowsError(try ReferenceMeasurementModel(index: referenceIndexMaximum + 1))
    }

    func testInvalidIndicesAreRejected() {
        XCTAssertThrowsError(try ReferenceMeasurementModel(index: -1))
        XCTAssertThrowsError(try ReferenceMeasurementModel(index: 361))
        var model = try! ReferenceMeasurementModel(index: 0)
        XCTAssertThrowsError(try model.selectIndex(-1))
        XCTAssertThrowsError(try model.selectIndex(361))
    }

    func testModelMatchesReferenceIndexSeries() throws {
        let profiles = try [[100, 0], [101, 8191], [102, 50]].map(profile)
        var model = try ReferenceMeasurementModel(index: 1)
        var direct = ReferenceIndexSeries(index: 1)
        model.start()
        for profile in profiles {
            model.record(profile)
            direct.record(profile)
        }
        XCTAssertEqual(model.statistics, direct.statistics())
        XCTAssertEqual(model.statistics?.median, 50.0)
    }
}
