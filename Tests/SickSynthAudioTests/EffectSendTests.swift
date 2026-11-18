@testable import LegacyPresetTestSupport
import PlanariumDomain
// EffectSendTests.swift
//
// SICK-018: die beiden internen Sends (Delay und Hall).
//
// Alle Prüfungen laufen **ohne Audiogerät** gegen `FakeAudioOutputHost`.
// Geprüft wird, was uns gehört: Parametergrenzen, Neutralzustand,
// Unabhängigkeit der beiden Wege, der unveränderte trockene Pfad und der
// Lebenszyklus der Effektkette. Die eigentliche Delay-/Hall-Verarbeitung
// stammt von `AVAudioUnitDelay`/`AVAudioUnitReverb` und wird hier
// ausdrücklich **nicht** nachgebaut oder nachgemessen.

import XCTest

@testable import PlanariumPresets

final class EffectSendTests: XCTestCase {

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    // MARK: - Hilfen

    private func makeWetEffects(
        delaySend: Float = 0.5,
        reverbSend: Float = 0.4
    ) throws -> EffectParameters {
        try EffectParameters.build(
            delaySend: delaySend,
            delayTimeSeconds: 0.3,
            delayFeedbackPercent: 40,
            reverbSend: reverbSend,
            reverbCharacter: .largeHall
        )
    }

    func testNeutralParametersHaveBothSendsSilent() {
        let neutral = EffectParameters.neutral

        XCTAssertEqual(neutral.delaySend, 0)
        XCTAssertEqual(neutral.reverbSend, 0)
        XCTAssertTrue(neutral.isDry)
        // Die Klangwerte darunter sind sinnvoll vorbelegt -- sie wirken
        // nur nicht, solange die Sends stumm sind.
        XCTAssertTrue(EffectParameters.delayTimeRange.contains(neutral.delayTimeSeconds))
        XCTAssertTrue(EffectParameters.delayFeedbackRange.contains(neutral.delayFeedbackPercent))
    }

    func testValidParametersAreAccepted() throws {
        let parameters = try makeWetEffects()

        XCTAssertEqual(parameters.delaySend, 0.5)
        XCTAssertEqual(parameters.delayTimeSeconds, 0.3)
        XCTAssertEqual(parameters.delayFeedbackPercent, 40)
        XCTAssertEqual(parameters.reverbSend, 0.4)
        XCTAssertEqual(parameters.reverbCharacter, .largeHall)
        XCTAssertFalse(parameters.isDry)
    }

    func testExactRangeBoundariesAreAccepted() {
        XCTAssertNoThrow(
            try EffectParameters.build(
                delaySend: 0,
                delayTimeSeconds: 0.001,
                delayFeedbackPercent: 0,
                reverbSend: 0,
                reverbCharacter: .smallRoom
            )
        )
        XCTAssertNoThrow(
            try EffectParameters.build(
                delaySend: 1,
                delayTimeSeconds: 2.0,
                delayFeedbackPercent: 85,
                reverbSend: 1,
                reverbCharacter: .cathedral
            )
        )
    }

    func testEachRuleHasItsOwnError() {
        func buildError(
            delaySend: Float = 0.5,
            delayTimeSeconds: Float = 0.3,
            delayFeedbackPercent: Float = 40,
            reverbSend: Float = 0.4
        ) -> EffectParameters.BuildError? {
            do {
                _ = try EffectParameters.build(
                    delaySend: delaySend,
                    delayTimeSeconds: delayTimeSeconds,
                    delayFeedbackPercent: delayFeedbackPercent,
                    reverbSend: reverbSend,
                    reverbCharacter: .mediumRoom
                )
                return nil
            } catch let error as EffectParameters.BuildError {
                return error
            } catch {
                return nil
            }
        }

        XCTAssertEqual(buildError(delaySend: -0.1), .delaySendOutOfRange(-0.1))
        XCTAssertEqual(buildError(delaySend: 1.5), .delaySendOutOfRange(1.5))
        XCTAssertEqual(buildError(delayTimeSeconds: 0), .delayTimeOutOfRange(0))
        XCTAssertEqual(buildError(delayTimeSeconds: 2.5), .delayTimeOutOfRange(2.5))
        XCTAssertEqual(buildError(delayFeedbackPercent: -1), .delayFeedbackOutOfRange(-1))
        XCTAssertEqual(buildError(reverbSend: 2), .reverbSendOutOfRange(2))
    }

    func testFeedbackIsCappedWellBelowRunaway() {
        // 85 % ist die bewusste Obergrenze: `AVAudioUnitDelay` ließe bis
        // 100 % zu, und dort klingt die Verzögerung nicht mehr ab.
        XCTAssertEqual(EffectParameters.delayFeedbackRange.upperBound, 85)
        guard case .delayFeedbackOutOfRange(let value)? = buildErrorForFeedback(100) else {
            return XCTFail("100 % Rückkopplung muss abgelehnt werden")
        }
        XCTAssertEqual(value, 100)
    }

    private func buildErrorForFeedback(_ feedback: Float) -> EffectParameters.BuildError? {
        do {
            _ = try EffectParameters.build(
                delaySend: 0.5,
                delayTimeSeconds: 0.3,
                delayFeedbackPercent: feedback,
                reverbSend: 0.4,
                reverbCharacter: .mediumRoom
            )
            return nil
        } catch let error as EffectParameters.BuildError {
            return error
        } catch {
            return nil
        }
    }

    func testNonFiniteValuesAreRejected() {
        for value in [Float.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(
                try EffectParameters.build(
                    delaySend: value,
                    delayTimeSeconds: 0.3,
                    delayFeedbackPercent: 40,
                    reverbSend: 0.4,
                    reverbCharacter: .mediumRoom
                ),
                "delaySend \(value) muss abgelehnt werden"
            )
            XCTAssertThrowsError(
                try EffectParameters.build(
                    delaySend: 0.5,
                    delayTimeSeconds: value,
                    delayFeedbackPercent: 40,
                    reverbSend: 0.4,
                    reverbCharacter: .mediumRoom
                ),
                "delayTimeSeconds \(value) muss abgelehnt werden"
            )
        }
    }

    // MARK: - Die Sends sind unabhängig







    // MARK: - Der trockene Pfad bleibt unberührt

    // MARK: - Lebenszyklus der Effektkette
















}
