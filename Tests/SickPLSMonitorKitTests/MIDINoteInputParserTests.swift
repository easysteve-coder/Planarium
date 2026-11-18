import XCTest
@testable import SickPLSMonitorKit

final class MIDINoteInputParserTests: XCTestCase {
    func testParsesAllEnglishPitchClasses() {
        let namesAndNotes = [
            ("C4", 60), ("C#4", 61), ("D4", 62), ("Eb4", 63),
            ("E4", 64), ("F4", 65), ("F#4", 66), ("G4", 67),
            ("Ab4", 68), ("A4", 69), ("Bb4", 70), ("B4", 71)
        ]
        for (name, note) in namesAndNotes {
            XCTAssertEqual(MIDINoteInputParser.parse(name), note, name)
        }
    }

    func testParsesEnglishNoteNamesAndEnharmonicNames() {
        XCTAssertEqual(MIDINoteInputParser.parse("G4"), 67)
        XCTAssertEqual(MIDINoteInputParser.parse("F#3"), 54)
        XCTAssertEqual(MIDINoteInputParser.parse("Bb2"), 46)
        XCTAssertEqual(MIDINoteInputParser.parse("B♭2"), 46)
        XCTAssertEqual(MIDINoteInputParser.parse("B4"), 71)
        XCTAssertNil(MIDINoteInputParser.parse("H4"))
    }

    func testRejectsOutOfRangeAndNonsense() {
        XCTAssertNil(MIDINoteInputParser.parse("C-2"))
        XCTAssertNil(MIDINoteInputParser.parse("G10"))
        XCTAssertNil(MIDINoteInputParser.parse("H#4"))
        XCTAssertNil(MIDINoteInputParser.parse("C4foo"))
        XCTAssertNil(MIDINoteInputParser.parse("127"))
        XCTAssertNil(MIDINoteInputParser.parse(""))
        XCTAssertNil(MIDINoteInputParser.parse("Fis3"))
    }
}
