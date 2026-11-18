import XCTest
@testable import PlanariumDomain

/// SICK-035b: eine Pitch-Domäne in Halbtönen plus Cent relativ zur
/// Grundnote.
final class PitchDomainTests: XCTestCase {

    func testTheStandardDomainIsA1PlusFiveOctaves() {
        XCTAssertEqual(PitchDomain.standard.rootNote, 33)
        XCTAssertEqual(PitchDomain.standard.spanSemitones, 60)
        XCTAssertEqual(PitchDomain.standard.topNote, 93)
    }

    func testBuildRefusesInvalidDomains() {
        XCTAssertThrowsError(try PitchDomain.build(rootNote: -1, spanSemitones: 12)) {
            XCTAssertEqual($0 as? PitchDomain.BuildError, .rootNoteOutOfRange(-1))
        }
        XCTAssertThrowsError(try PitchDomain.build(rootNote: 60, spanSemitones: 0)) {
            XCTAssertEqual($0 as? PitchDomain.BuildError, .spanNotPositive(0))
        }
        XCTAssertThrowsError(try PitchDomain.build(rootNote: 120, spanSemitones: 12)) {
            XCTAssertEqual($0 as? PitchDomain.BuildError, .spanExceedsNoteRange(rootNote: 120, spanSemitones: 12))
        }
        XCTAssertNoThrow(try PitchDomain.build(rootNote: 115, spanSemitones: 12))
    }

}
