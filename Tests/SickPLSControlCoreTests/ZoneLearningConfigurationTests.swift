import XCTest
import SickPLSControlCore

/// SICK-030c, Fachvertrag Punkt 1: Alle Schwellwerte sind validiert, in
/// Profilanzahlen bzw. Rohwertdifferenzen ausgedrückt, und **nichts**
/// wird still korrigiert.
final class ZoneLearningConfigurationTests: XCTestCase {

    private func build(
        baselineProfileCount: Int = 5,
        minimumPersistenceProfiles: Int = 3,
        minimumClusterPoints: Int = 3,
        maximumIndexGap: Int = 1,
        movementDelta: UInt16 = 40,
        indexPaddingPoints: Int = 1,
        valuePadding: UInt16 = 20,
        backgroundClearance: UInt16 = 30,
        ambiguityToleranceFactor: Double = 1.25
    ) throws -> ZoneLearningConfiguration {
        try ZoneLearningConfiguration.build(
            baselineProfileCount: baselineProfileCount,
            minimumPersistenceProfiles: minimumPersistenceProfiles,
            minimumClusterPoints: minimumClusterPoints,
            maximumIndexGap: maximumIndexGap,
            movementDelta: movementDelta,
            indexPaddingPoints: indexPaddingPoints,
            valuePadding: valuePadding,
            backgroundClearance: backgroundClearance,
            ambiguityToleranceFactor: ambiguityToleranceFactor
        )
    }

    private func assertRejects(
        _ error: ZoneLearningConfiguration.BuildError,
        _ make: () throws -> ZoneLearningConfiguration,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try make(), file: file, line: line) {
            XCTAssertEqual($0 as? ZoneLearningConfiguration.BuildError, error, file: file, line: line)
        }
    }

    // MARK: - Gültige Werte kommen unverändert durch

    func testAValidConfigurationKeepsEveryValueExactly() throws {
        let configuration = try build()

        XCTAssertEqual(configuration.baselineProfileCount, 5)
        XCTAssertEqual(configuration.minimumPersistenceProfiles, 3)
        XCTAssertEqual(configuration.minimumClusterPoints, 3)
        XCTAssertEqual(configuration.maximumIndexGap, 1)
        XCTAssertEqual(configuration.movementDelta, 40)
        XCTAssertEqual(configuration.indexPaddingPoints, 1)
        XCTAssertEqual(configuration.valuePadding, 20)
        XCTAssertEqual(configuration.backgroundClearance, 30)
        XCTAssertEqual(configuration.ambiguityToleranceFactor, 1.25)
    }

    /// Lückenlos benachbart (`0`) und kein Puffer (`0`) sind zulässige
    /// Wahlen, keine Fehler.
    func testZeroIsAllowedWhereItIsMeaningful() throws {
        let configuration = try build(maximumIndexGap: 0, indexPaddingPoints: 0, valuePadding: 0)

        XCTAssertEqual(configuration.maximumIndexGap, 0)
        XCTAssertEqual(configuration.indexPaddingPoints, 0)
        XCTAssertEqual(configuration.valuePadding, 0)
    }

    func testTheDefaultIsAValidConfiguration() {
        let configuration = ZoneLearningConfiguration.default

        XCTAssertGreaterThan(configuration.baselineProfileCount, 0)
        XCTAssertGreaterThan(configuration.minimumPersistenceProfiles, 0)
        XCTAssertGreaterThan(configuration.minimumClusterPoints, 0)
        XCTAssertGreaterThanOrEqual(configuration.maximumIndexGap, 0)
        XCTAssertGreaterThan(configuration.movementDelta, 0)
        XCTAssertGreaterThan(configuration.backgroundClearance, 0)
        XCTAssertGreaterThanOrEqual(configuration.ambiguityToleranceFactor, 1)
    }

    // MARK: - Jede Regel hat ihren eigenen Fehler

    func testEachViolationThrowsItsOwnError() {
        assertRejects(.baselineProfileCountNotPositive(0)) { try build(baselineProfileCount: 0) }
        assertRejects(.baselineProfileCountNotPositive(-2)) { try build(baselineProfileCount: -2) }
        assertRejects(.minimumPersistenceProfilesNotPositive(0)) { try build(minimumPersistenceProfiles: 0) }
        assertRejects(.minimumClusterPointsNotPositive(0)) { try build(minimumClusterPoints: 0) }
        assertRejects(.maximumIndexGapNegative(-1)) { try build(maximumIndexGap: -1) }
        assertRejects(.movementDeltaNotPositive(0)) { try build(movementDelta: 0) }
        assertRejects(.indexPaddingPointsNegative(-1)) { try build(indexPaddingPoints: -1) }
        assertRejects(.backgroundClearanceNotPositive(0)) { try build(backgroundClearance: 0) }
    }

    func testANonFiniteAmbiguityFactorIsRejected() {
        assertRejects(.ambiguityToleranceFactorNotFinite(.infinity)) {
            try build(ambiguityToleranceFactor: .infinity)
        }
        assertRejects(.ambiguityToleranceFactorNotFinite(-.infinity)) {
            try build(ambiguityToleranceFactor: -.infinity)
        }
        // `NaN` gesondert: Der mitgeführte Wert ist sich selbst nicht
        // gleich, ein `XCTAssertEqual` auf den Fehlerwert schlüge also
        // auch im richtigen Fall fehl. Geprüft wird deshalb der **Fall**.
        XCTAssertThrowsError(try build(ambiguityToleranceFactor: .nan)) { error in
            guard case .ambiguityToleranceFactorNotFinite(let value) =
                error as? ZoneLearningConfiguration.BuildError
            else { return XCTFail("Falscher Fehler: \(error)") }
            XCTAssertTrue(value.isNaN)
        }
    }

    /// Kleiner als `1` hieße „ein schwächerer Cluster gilt als gleichauf"
    /// — das ergibt keinen Sinn und wird abgelehnt statt geklammert.
    func testAnAmbiguityFactorBelowOneIsRejected() {
        assertRejects(.ambiguityToleranceFactorBelowOne(0.9)) { try build(ambiguityToleranceFactor: 0.9) }
        XCTAssertNoThrow(try build(ambiguityToleranceFactor: 1.0), "Genau 1 ist zulässig")
    }

    /// Puffer und Sicherheitsabstand zusammen dürfen den Rohwertbereich
    /// nicht überspannen — sonst ließe sich **nie** ein Kandidat bilden,
    /// und der Fehler gehört an den Konstruktor statt in jedes Ergebnis.
    func testPaddingPlusClearanceMustLeaveRoomInTheRawValueRange() {
        assertRejects(.paddingAndClearanceExceedValueRange(padding: 8000, clearance: 200)) {
            try build(valuePadding: 8000, backgroundClearance: 200)
        }
        XCTAssertNoThrow(try build(valuePadding: 4000, backgroundClearance: 4000))
    }
}
