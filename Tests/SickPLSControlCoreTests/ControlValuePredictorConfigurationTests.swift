import XCTest
import SickPLSControlCore

final class ControlValuePredictorConfigurationTests: XCTestCase {

    private func assertBuildError(
        _ expected: ControlValuePredictorConfiguration.BuildError,
        alpha: Double = 0.5,
        beta: Double = 0.1,
        horizon: Double = 0.06,
        stale: Double = 0.35,
        outlier: Double = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ControlValuePredictorConfiguration.build(
                alpha: alpha,
                beta: beta,
                predictionHorizonSeconds: horizon,
                staleTimeoutSeconds: stale,
                outlierThreshold: outlier
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ControlValuePredictorConfiguration.BuildError, expected, file: file, line: line)
        }
    }

    // MARK: - Gültige Konfiguration

    func testBuildSucceedsForValidConfiguration() throws {
        let configuration = try ControlValuePredictorConfiguration.build(
            alpha: 0.4, beta: 0.2, predictionHorizonSeconds: 0.05, staleTimeoutSeconds: 0.3, outlierThreshold: 0.25
        )

        XCTAssertEqual(configuration.alpha, 0.4)
        XCTAssertEqual(configuration.beta, 0.2)
        XCTAssertEqual(configuration.predictionHorizonSeconds, 0.05)
        XCTAssertEqual(configuration.staleTimeoutSeconds, 0.3)
        XCTAssertEqual(configuration.outlierThreshold, 0.25)
    }

    func testBuildAcceptsHorizonExactlyEqualToStaleTimeout() throws {
        let configuration = try ControlValuePredictorConfiguration.build(
            alpha: 1.0, beta: 1.0, predictionHorizonSeconds: 0.2, staleTimeoutSeconds: 0.2, outlierThreshold: 0.5
        )

        XCTAssertEqual(configuration.predictionHorizonSeconds, configuration.staleTimeoutSeconds)
    }

    func testBuildAcceptsUpperBoundsOfAlphaAndBeta() throws {
        let configuration = try ControlValuePredictorConfiguration.build(
            alpha: 1.0, beta: 1.0, predictionHorizonSeconds: 0.06, staleTimeoutSeconds: 0.35, outlierThreshold: 0.5
        )

        XCTAssertEqual(configuration.alpha, 1.0)
        XCTAssertEqual(configuration.beta, 1.0)
    }

    // MARK: - Ungültige Konfiguration wird abgelehnt, nie still korrigiert

    func testBuildRejectsAlphaOfZero() {
        assertBuildError(.alphaOutOfRange(0), alpha: 0)
    }

    func testBuildRejectsNegativeAlpha() {
        assertBuildError(.alphaOutOfRange(-0.5), alpha: -0.5)
    }

    func testBuildRejectsAlphaAboveOne() {
        assertBuildError(.alphaOutOfRange(1.5), alpha: 1.5)
    }

    func testBuildRejectsNonFiniteAlpha() {
        XCTAssertThrowsError(
            try ControlValuePredictorConfiguration.build(
                alpha: .infinity, beta: 0.1, predictionHorizonSeconds: 0.06, staleTimeoutSeconds: 0.35, outlierThreshold: 0.5
            )
        )
    }

    func testBuildRejectsBetaOfZero() {
        assertBuildError(.betaOutOfRange(0), beta: 0)
    }

    func testBuildRejectsBetaAboveOne() {
        assertBuildError(.betaOutOfRange(2.0), beta: 2.0)
    }

    func testBuildRejectsNonPositivePredictionHorizon() {
        assertBuildError(.predictionHorizonNotPositive(0), horizon: 0)
    }

    func testBuildRejectsNonPositiveStaleTimeout() {
        // Die Horizont-/Stale-Beziehung wird erst nach beiden
        // Einzelprüfungen ausgewertet, deshalb hier ein Horizont, der
        // für sich gültig ist.
        assertBuildError(.staleTimeoutNotPositive(-1), horizon: 0.06, stale: -1)
    }

    func testBuildRejectsHorizonGreaterThanStaleTimeout() {
        assertBuildError(
            .predictionHorizonExceedsStaleTimeout(horizon: 0.4, staleTimeout: 0.2),
            horizon: 0.4,
            stale: 0.2
        )
    }

    func testBuildRejectsNonPositiveOutlierThreshold() {
        assertBuildError(.outlierThresholdNotPositive(0), outlier: 0)
    }

    // MARK: - Dokumentierter Startwert

    func testStartingPointHorizonLiesInTheMandatedFortyToEightyMillisecondRange() {
        // SICK-008a-Owner-Leitplanke/SICK-015-Auftrag 1.6: Startwert
        // des Horizonts 40–80 ms.
        XCTAssertGreaterThanOrEqual(ControlValuePredictorConfiguration.startingPoint.predictionHorizonSeconds, 0.04)
        XCTAssertLessThanOrEqual(ControlValuePredictorConfiguration.startingPoint.predictionHorizonSeconds, 0.08)
    }

    func testStartingPointStaleTimeoutToleratesTheRealObservedFourHertzSpacing() {
        // Der bei ≈ 4 Hz real beobachtete Abstand echter Profile
        // (≈ 250 ms, SICK-012-Mitschnitt) darf den Ausgang nicht
        // abschalten. Das ist eine Eigenschaft *dieser Konfiguration*,
        // keine Behauptung über eine Profilrate des Geräts.
        XCTAssertGreaterThan(ControlValuePredictorConfiguration.startingPoint.staleTimeoutSeconds, 0.25)
    }

    func testStartingPointSatisfiesItsOwnValidation() throws {
        let rebuilt = try ControlValuePredictorConfiguration.build(
            alpha: ControlValuePredictorConfiguration.startingPoint.alpha,
            beta: ControlValuePredictorConfiguration.startingPoint.beta,
            predictionHorizonSeconds: ControlValuePredictorConfiguration.startingPoint.predictionHorizonSeconds,
            staleTimeoutSeconds: ControlValuePredictorConfiguration.startingPoint.staleTimeoutSeconds,
            outlierThreshold: ControlValuePredictorConfiguration.startingPoint.outlierThreshold
        )

        XCTAssertEqual(rebuilt, ControlValuePredictorConfiguration.startingPoint)
    }
}
