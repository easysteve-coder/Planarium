import PlanariumInput
import Foundation
import XCTest
import SickPLSControlCore
import SickPLSMonitorKit
@testable import PlanariumScannerUI

/// Die reinen Anzeigewerte der Zonen-Inserts (SICK-032c1) — ohne
/// Koordinator, ohne Sitzung, ohne Ansicht.
@MainActor final class ZoneInsertStatusTests: XCTestCase {

    private func zone(role: ZoneRole = .pitch) throws -> Zone {
        try Zone.build(
            indexLowerBound: 0.25,
            indexUpperBound: 0.75,
            valueLowerBound: 1000,
            valueUpperBound: 4000,
            role: role
        )
    }

    // MARK: - Live heißt Messung

    func testWithoutAProfileTheStatusIsNoProfileEvenWithAStaleEntry() {
        let id = UUID()
        // Ein Eintrag aus einer früheren Auswertung darf nichts
        // vortäuschen: Ohne Profil ist die Antwort `noProfile`.
        let status = ZoneLiveStatus.of(id, in: [id: .controlValue(0.8)], hasProfile: false)
        XCTAssertEqual(status, .noProfile)
    }

    func testAMissingEntryWithAProfileIsNotHitAndNeverNoProfile() {
        let status = ZoneLiveStatus.of(UUID(), in: [:], hasProfile: true)
        XCTAssertEqual(status, .notHit)
    }

    func testAnInactiveEvaluationIsNotHit() {
        let id = UUID()
        XCTAssertEqual(ZoneLiveStatus.of(id, in: [id: .inactive], hasProfile: true), .notHit)
    }

    func testAControlValueIsPassedThroughUnchanged() {
        let id = UUID()
        let status = ZoneLiveStatus.of(id, in: [id: .controlValue(0.7435897435897436)], hasProfile: true)
        XCTAssertEqual(status, .hit(0.7435897435897436))
        XCTAssertTrue(status.isHit)
        XCTAssertEqual(status.label, "hit · 0,744")
    }

    func testTheThreeLiveLabelsAreDistinct() {
        let labels = Set([
            ZoneLiveStatus.noProfile.label,
            ZoneLiveStatus.notHit.label,
            ZoneLiveStatus.hit(0.5).label
        ])
        XCTAssertEqual(labels.count, 3)
    }

    // MARK: - Aktivierung

    func testActivationCarriesOnlyTheSwitch() {
        XCTAssertEqual(ZoneActivation(isEnabled: true), .on)
        XCTAssertEqual(ZoneActivation(isEnabled: false), .off)
        XCTAssertEqual(ZoneActivation.on.label, "On")
        XCTAssertEqual(ZoneActivation.off.label, "Off")
        XCTAssertTrue(ZoneActivation.on.isOn)
        XCTAssertFalse(ZoneActivation.off.isOn)
    }

    // MARK: - Beschriftungen der Karte

    func testTheBoundsLabelNamesAllFourNumbers() throws {
        let status = ZoneInsertStatus(
            id: UUID(), zone: try zone(), isSelected: false,
            activation: .off, live: .noProfile
        )
        XCTAssertEqual(status.boundsLabel, "Index 0,25–0,75 · Value 1000–4000")
    }

    func testEveryRoleHasExactlyOneName() {
        let names = ZoneRole.allCases.map(ZoneRoleNaming.name(of:))
        XCTAssertEqual(Set(names).count, ZoneRole.allCases.count)
        XCTAssertFalse(names.contains(where: \.isEmpty))
    }

    // MARK: - Zahlendarstellung ohne Foundation

    func testTheDecimalTextRoundsAndPadsWithoutFoundation() {
        XCTAssertEqual(DecimalText.fixed(0.7435, places: 3), "0,744")
        XCTAssertEqual(DecimalText.fixed(0, places: 2), "0,00")
        XCTAssertEqual(DecimalText.fixed(1, places: 2), "1,00")
        XCTAssertEqual(DecimalText.fixed(0.005, places: 2), "0,01")
        XCTAssertEqual(DecimalText.fixed(-0.25, places: 2), "-0,25")
        XCTAssertEqual(DecimalText.fixed(12.5, places: 0), "13")
        XCTAssertEqual(DecimalText.fixed(.nan, places: 2), "–")
        XCTAssertEqual(DecimalText.fixed(.infinity, places: 2), "–")
    }
}
