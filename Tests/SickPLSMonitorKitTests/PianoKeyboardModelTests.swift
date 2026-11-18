import XCTest
@testable import SickPLSMonitorKit

final class PianoKeyboardModelTests: XCTestCase {
    func testOctaveZeroStartsAtC0AndShowsTwoOctaves() {
        let model = PianoKeyboardModel(octave: 0)
        XCTAssertEqual(model.visibleNotes, Array(12...35))
        XCTAssertEqual(model.visibleNotes.filter(PianoKeyboardModel.isBlackKey), [13, 15, 18, 20, 22, 25, 27, 30, 32, 34])
    }

    func testChordLearningCanReachLowestMIDIKeysWithoutChangingInspectorDefault() {
        var model = PianoKeyboardModel(octave: 0, minimumOctave: -1)
        model.shiftOctave(by: -1)
        XCTAssertEqual(model.octave, -1)
        XCTAssertEqual(model.visibleNotes, Array(0...23))
        model.toggle(note: 0); model.toggle(note: 7)
        XCTAssertEqual(model.selectedNotes, [0, 7])
        model.shiftOctave(by: -1); XCTAssertEqual(model.octave, -1)
        XCTAssertEqual(PianoKeyboardModel(octave: -1).octave, 0)
    }

    func testHighestOctaveStopsAt127() {
        let model = PianoKeyboardModel(octave: PianoKeyboardModel.highestOctave)
        XCTAssertEqual(model.visibleNotes.first, 120)
        XCTAssertEqual(model.visibleNotes.last, 127)
        XCTAssertTrue(model.visibleNotes.allSatisfy { (0...127).contains($0) })
    }

    func testOctaveShiftIsClampedAtBothEnds() {
        var model = PianoKeyboardModel(octave: 0)
        model.shiftOctave(by: -1)
        XCTAssertEqual(model.octave, 0)
        model.shiftOctave(by: 100)
        XCTAssertEqual(model.octave, PianoKeyboardModel.highestOctave)
        model.shiftOctave(by: 1)
        XCTAssertEqual(model.octave, PianoKeyboardModel.highestOctave)
    }

    func testTogglingSeveralKeysBuildsAndRemovesAChord() {
        var model = PianoKeyboardModel()
        model.toggle(note: 60); model.toggle(note: 64); model.toggle(note: 67)
        XCTAssertEqual(model.selectedNotes, [60, 64, 67])
        XCTAssertEqual(model.selectedNoteNames, "C4 E4 G4")
        model.toggle(note: 64)
        XCTAssertEqual(model.selectedNotes, [60, 67])
    }

    func testNamesClampToTheMIDIAddressSpace() {
        XCTAssertEqual(PianoKeyboardModel.displayName(for: 0), "C-1")
        XCTAssertEqual(PianoKeyboardModel.displayName(for: 127), "G9")
        XCTAssertEqual(PianoKeyboardModel.displayName(for: 200), "G9")
        XCTAssertEqual(PianoKeyboardModel.displayName(for: -4), "C-1")
    }
}

extension PianoKeyboardModelTests {
    func testSharedGeometryFor88And128KeysAndBlackHitPriority() throws {
        for notes in [Array(21...108), Array(0...127)] {
            let keys = PianoKeyboardLayout.layout(for: notes, width: 1500, height: 100)
            XCTAssertEqual(keys.count, notes.count)
            let whites = keys.filter { !$0.isBlack }
            for pair in zip(whites, whites.dropFirst()) { XCTAssertEqual(pair.0.frame.maxX, pair.1.frame.minX, accuracy: 0.001) }
            for black in keys.filter(\.isBlack) {
                XCTAssertEqual(black.frame.width / whites[0].frame.width, 0.6, accuracy: 0.001)
                XCTAssertEqual(black.frame.height, 62, accuracy: 0.001)
                XCTAssertEqual(PianoKeyboardLayout.hitTest(keys: keys, point: .init(x: black.frame.midX, y: 20)), black.note)
                XCTAssertNotEqual(PianoKeyboardLayout.hitTest(keys: keys, point: .init(x: black.frame.midX, y: 90)), black.note)
            }
            let cs = try XCTUnwrap(keys.first { $0.note == 61 })
            let ds = try XCTUnwrap(keys.first { $0.note == 63 })
            let c = try XCTUnwrap(keys.first { $0.note == 60 })
            let d = try XCTUnwrap(keys.first { $0.note == 62 })
            XCTAssertLessThan(cs.frame.midX, c.frame.maxX)
            XCTAssertGreaterThan(ds.frame.midX, d.frame.maxX)
        }
    }
}
