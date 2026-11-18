import XCTest
@testable import SickPLSMonitorKit

/// SICK-032c3a, Abschnitt 3 -- der reine Fokus-Reducer, isoliert von
/// ``LearnDraft``, ``ScanFieldFocusArea`` und jeder Ansicht.
final class LearnFocusStateTests: XCTestCase {

    // MARK: - Höchstens einmal (Pflichtnachweis 6)

    func testAFreshStateHasAnAutomaticFocusPending() {
        XCTAssertTrue(LearnFocusState.initial.isAutomaticFocusStillPending)
    }

    func testTheFirstMeasurementFocusesImmediately() {
        var state = LearnFocusState.initial
        XCTAssertEqual(state.apply(.measurementAvailable), .focusNow)
        XCTAssertFalse(state.isAutomaticFocusStillPending)
    }

    func testASecondMeasurementNeverFocusesAgain() {
        var state = LearnFocusState.initial
        state.apply(.measurementAvailable)
        XCTAssertEqual(state.apply(.measurementAvailable), .doNothing)
        XCTAssertEqual(state.apply(.measurementAvailable), .doNothing)
    }

    // MARK: - Manuelle Navigation sperrt dauerhaft

    func testManualNavigationBeforeAnyMeasurementPreventsTheFirstAutomaticFocus() {
        var state = LearnFocusState.initial
        XCTAssertEqual(state.apply(.manualNavigation), .doNothing)
        XCTAssertFalse(state.isAutomaticFocusStillPending)
        XCTAssertEqual(state.apply(.measurementAvailable), .doNothing)
    }

    func testManualNavigationAfterTheAutomaticFocusIsHarmlessAndStaysLocked() {
        var state = LearnFocusState.initial
        state.apply(.measurementAvailable)
        XCTAssertEqual(state.apply(.manualNavigation), .doNothing)
        XCTAssertEqual(state.apply(.measurementAvailable), .doNothing)
    }

    func testRepeatedManualNavigationNeverFocuses() {
        var state = LearnFocusState.initial
        for _ in 0..<5 {
            XCTAssertEqual(state.apply(.manualNavigation), .doNothing)
        }
    }

    // MARK: - Explizites Einpassen wirkt immer, sperrt aber die Automatik

    func testExplicitFitAlwaysFocusesEvenBeforeAnyMeasurement() {
        var state = LearnFocusState.initial
        XCTAssertEqual(state.apply(.explicitFitRequested), .focusNow)
    }

    func testExplicitFitLocksAnyLaterAutomaticFocus() {
        var state = LearnFocusState.initial
        state.apply(.explicitFitRequested)
        XCTAssertFalse(state.isAutomaticFocusStillPending)
        XCTAssertEqual(state.apply(.measurementAvailable), .doNothing)
    }

    func testExplicitFitCanBeRepeatedAndStaysWithoutStartingAContinuousAutomatic() {
        var state = LearnFocusState.initial
        XCTAssertEqual(state.apply(.explicitFitRequested), .focusNow)
        XCTAssertEqual(state.apply(.explicitFitRequested), .focusNow, "Einpassen bleibt jederzeit möglich")
        // Trotzdem keine fortlaufende Automatik: ein Messwert danach
        // fokussiert nicht von selbst.
        XCTAssertEqual(state.apply(.measurementAvailable), .doNothing)
    }

    func testExplicitFitAfterTheAutomaticFocusAlreadyFiredStillFocuses() {
        var state = LearnFocusState.initial
        state.apply(.measurementAvailable)
        XCTAssertEqual(state.apply(.explicitFitRequested), .focusNow)
    }

    // MARK: - Reihenfolgeunabhängigkeit

    func testManualNavigationThenMeasurementNeverFocuses() {
        var state = LearnFocusState.initial
        state.apply(.manualNavigation)
        XCTAssertEqual(state.apply(.measurementAvailable), .doNothing)
    }

    func testMeasurementThenManualNavigationThenAnotherMeasurementNeverFocusesAgain() {
        var state = LearnFocusState.initial
        state.apply(.measurementAvailable)
        state.apply(.manualNavigation)
        XCTAssertEqual(state.apply(.measurementAvailable), .doNothing)
    }

    // MARK: - Reset (neuer Entwurf)

    func testResetRestoresAFreshPendingState() {
        var state = LearnFocusState.initial
        state.apply(.measurementAvailable)
        XCTAssertFalse(state.isAutomaticFocusStillPending)
        state.reset()
        XCTAssertTrue(state.isAutomaticFocusStillPending)
        XCTAssertEqual(state.apply(.measurementAvailable), .focusNow)
    }

    func testResetAfterAManualLockAlsoRestoresPending() {
        var state = LearnFocusState.initial
        state.apply(.manualNavigation)
        state.reset()
        XCTAssertEqual(state.apply(.measurementAvailable), .focusNow)
    }

    // MARK: - Equatable / Sendable als reiner Wert

    func testTwoFreshStatesAreEqual() {
        XCTAssertEqual(LearnFocusState.initial, LearnFocusState.initial)
    }

    func testStatesWithDifferentHistoryAreNotEqual() {
        var consumed = LearnFocusState.initial
        consumed.apply(.measurementAvailable)
        var locked = LearnFocusState.initial
        locked.apply(.manualNavigation)
        XCTAssertNotEqual(consumed, locked, "Beide sperren die Automatik, aus verschiedenen Gründen")
        XCTAssertNotEqual(LearnFocusState.initial, consumed)
    }
}
