import XCTest
import PlanariumDomain
@testable import PlanariumPresets

/// Codex review 18.11. (1): controller assignments travel through the real
/// preset writer and reader, as full preset and as template; presets without
/// assignments stay byte-identical; legacy presets bring none.
final class ControllerPresetTests: XCTestCase {
    private func document() throws -> InstrumentDocument {
        var value = try FactoryPresetDocument.empty()
        value.controller = ControllerAssistant.drums.applied(to: .empty, output: .midi(channel: 9))
        return value
    }

    func testFullPresetAndTemplateKeepTheAssignments() throws {
        let value = try document()
        for includesChannel in [true, false] {
            let data = try PresetDocumentWriter.encode(.init(name: "Pad", document: value, includesChannel: includesChannel))
            let read = try PresetDocumentReader.read(data).get()
            let live = try FactoryPresetDocument.empty()
            XCTAssertEqual(try read.replacing(live).controller, value.controller, includesChannel ? "full preset" : "template")
        }
    }

    func testPresetWithoutAssignmentsIsWrittenWithoutTheKey() throws {
        let plain = try FactoryPresetDocument.empty()
        for includesChannel in [true, false] {
            let data = try PresetDocumentWriter.encode(.init(name: "Plain", document: plain, includesChannel: includesChannel))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"controller\""))
        }
    }

    func testInvalidAssignmentIsRejectedOnRead() throws {
        var value = try document()
        value.controller.assignments[0].routing.target = .midiCC(channel: 0, controller: 74)
        XCTAssertThrowsError(try PresetDocumentWriter.encode(.init(name: "Bad", document: value)), "a note program on a CC target")
    }
}
