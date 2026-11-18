import XCTest
import SickPLSControlCore
@testable import SickPLSMonitorKit

final class ZoneDraftTests: XCTestCase {

    // MARK: - Aus einer gültigen Zone entsteht ein unveränderter, gültiger Entwurf

    func testInitFromZoneCopiesAllFieldsAndResolvesBackToAnEquivalentZone() throws {
        let zone = try Zone.build(
            indexLowerBound: 0.2, indexUpperBound: 0.6,
            valueLowerBound: 1000, valueUpperBound: 4000,
            role: .pitch
        )

        var draft = ZoneDraft(zone: zone)

        XCTAssertEqual(draft.indexLowerBound, 0.2)
        XCTAssertEqual(draft.indexUpperBound, 0.6)
        XCTAssertEqual(draft.valueLowerBound, 1000)
        XCTAssertEqual(draft.valueUpperBound, 4000)
        XCTAssertEqual(draft.role, .pitch)

        draft.clamp()
        XCTAssertEqual(draft.resolvedZone(), zone)
    }

    // MARK: - Bereichsklammerung

    func testClampRestrictsIndexBoundsToZeroToOne() {
        var draft = ZoneDraft(indexLowerBound: -0.5, indexUpperBound: 1.8, valueLowerBound: 100, valueUpperBound: 200, role: .volume)

        draft.clamp()

        XCTAssertEqual(draft.indexLowerBound, 0.0)
        XCTAssertEqual(draft.indexUpperBound, 1.0)
    }

    func testClampRestrictsValueBoundsToZeroTo8191() {
        var draft = ZoneDraft(indexLowerBound: 0.1, indexUpperBound: 0.2, valueLowerBound: 0, valueUpperBound: 60000, role: .filter)

        draft.clamp()

        XCTAssertEqual(draft.valueUpperBound, Zone.maxRawMeasurementValue)
    }

    // MARK: - Klammerung erzwingt echtes Aufsteigen, nie gleiche oder vertauschte Grenzen

    func testClampNudgesIndexUpperBoundApartWhenBoundsAreEqual() {
        var draft = ZoneDraft(indexLowerBound: 0.5, indexUpperBound: 0.5, valueLowerBound: 100, valueUpperBound: 200, role: .gate)

        draft.clamp()

        XCTAssertLessThan(draft.indexLowerBound, draft.indexUpperBound)
    }

    func testClampNudgesIndexLowerBoundDownWhenUpperBoundIsPinnedAtOne() {
        var draft = ZoneDraft(indexLowerBound: 1.0, indexUpperBound: 1.0, valueLowerBound: 100, valueUpperBound: 200, role: .gate)

        draft.clamp()

        XCTAssertLessThan(draft.indexLowerBound, draft.indexUpperBound)
        XCTAssertEqual(draft.indexUpperBound, 1.0)
    }

    func testClampSwapsEffectOfInvertedIndexBoundsIntoAnAscendingRange() {
        var draft = ZoneDraft(indexLowerBound: 0.8, indexUpperBound: 0.2, valueLowerBound: 100, valueUpperBound: 200, role: .effectSend)

        draft.clamp()

        XCTAssertLessThan(draft.indexLowerBound, draft.indexUpperBound)
    }

    func testClampNudgesValueUpperBoundApartWhenBoundsAreEqual() {
        var draft = ZoneDraft(indexLowerBound: 0.1, indexUpperBound: 0.2, valueLowerBound: 500, valueUpperBound: 500, role: .pitch)

        draft.clamp()

        XCTAssertLessThan(draft.valueLowerBound, draft.valueUpperBound)
    }

    func testClampNudgesValueLowerBoundDownWhenUpperBoundIsPinnedAtMaximum() {
        var draft = ZoneDraft(indexLowerBound: 0.1, indexUpperBound: 0.2, valueLowerBound: Zone.maxRawMeasurementValue, valueUpperBound: Zone.maxRawMeasurementValue, role: .pitch)

        draft.clamp()

        XCTAssertLessThan(draft.valueLowerBound, draft.valueUpperBound)
        XCTAssertEqual(draft.valueUpperBound, Zone.maxRawMeasurementValue)
    }

    // MARK: - Nach clamp() liefert resolvedZone() in jedem Fall eine gültige Zone

    func testResolvedZoneAfterClampIsAlwaysValidForArbitraryOutOfRangeInput() {
        let extremeDrafts: [ZoneDraft] = [
            ZoneDraft(indexLowerBound: -100, indexUpperBound: -50, valueLowerBound: 0, valueUpperBound: 0, role: .pitch),
            ZoneDraft(indexLowerBound: 2, indexUpperBound: 5, valueLowerBound: 60000, valueUpperBound: 60000, role: .volume),
            ZoneDraft(indexLowerBound: 0.5, indexUpperBound: 0.5, valueLowerBound: 100, valueUpperBound: 100, role: .filter),
            ZoneDraft(indexLowerBound: 1, indexUpperBound: 0, valueLowerBound: 8191, valueUpperBound: 0, role: .gate)
        ]

        for var draft in extremeDrafts {
            draft.clamp()
            XCTAssertNotNil(draft.resolvedZone(), "Entwurf \(draft) muss nach clamp() eine gültige Zone ergeben")
        }
    }

    // MARK: - Ohne clamp() kann resolvedZone() scheitern -- Ungültiges gelangt nie unbemerkt ins Modell

    func testResolvedZoneWithoutClampReturnsNilForInvertedBounds() {
        let draft = ZoneDraft(indexLowerBound: 0.8, indexUpperBound: 0.2, valueLowerBound: 100, valueUpperBound: 200, role: .pitch)

        XCTAssertNil(draft.resolvedZone())
    }

    func testResolvedZoneWithoutClampReturnsNilForOutOfRangeIndexBound() {
        let draft = ZoneDraft(indexLowerBound: -0.1, indexUpperBound: 0.5, valueLowerBound: 100, valueUpperBound: 200, role: .pitch)

        XCTAssertNil(draft.resolvedZone())
    }
}
