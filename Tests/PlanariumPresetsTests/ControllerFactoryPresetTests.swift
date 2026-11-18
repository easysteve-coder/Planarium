import XCTest
import PlanariumDomain
@testable import PlanariumPresets

/// The controller factory preset is built from the blank factory channel by
/// production code and must equal its resource byte for byte. Regenerate with
/// `PLANARIUM_WRITE_FACTORY=1 swift test --filter ControllerFactoryPresetTests`.
final class ControllerFactoryPresetTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PlanariumPresets/Resources")
    }

    private func built() throws -> Data {
        let blank = try PresetV6Codec.decode(XCTUnwrap(FactoryPresetLibrary.standard.data(named: "Factory 00 Blank Channel"))).document
        let document = try FactoryPresetDocument.controllerFirstNotes(from: blank)
        return try PresetDocumentWriter.encode(InstrumentPresetV6(name: FactoryPresetDocument.controllerFirstNotesName, document: document))
    }

    func testResourceIsTheBuiltPresetByteForByte() throws {
        let data = try built()
        let url = resources.appendingPathComponent("\(FactoryPresetDocument.controllerFirstNotesName).sickpreset.json")
        if ProcessInfo.processInfo.environment["PLANARIUM_WRITE_FACTORY"] == "1" { try data.write(to: url) }
        XCTAssertEqual(FactoryPresetLibrary.standard.data(named: FactoryPresetDocument.controllerFirstNotesName), data)
        XCTAssertEqual(try built(), data, "fixed identifiers: the build is reproducible")
    }

    func testPresetPlaysAtOnceOnTheBuiltInInstrumentAndValidates() throws {
        let data = try XCTUnwrap(FactoryPresetLibrary.standard.data(named: FactoryPresetDocument.controllerFirstNotesName))
        let document = try PresetDocumentReader.read(data).get().replacing(FactoryPresetDocument.empty())
        let strip = try XCTUnwrap(document.channels.first)
        XCTAssertEqual(strip.instrument?.identity.componentSubType, 0x646C7320, "Apple DLSMusicDevice, always installed")
        let layout = document.controller
        XCTAssertEqual(Set(layout.assignments.map(\.element)).count, layout.assignments.count, "one assignment per element")
        XCTAssertEqual(layout.assignments.filter { $0.routing.target.midiChannel == 9 }.count, 5, "drums on GM channel 10; L1 is sustain, not crash")
        XCTAssertTrue(layout.assignments.contains { $0.element == .rightStick })
        XCTAssertEqual(layout.assignments.filter { [.dpadUp, .dpadDown, .dpadLeft, .dpadRight].contains($0.element) }.count, 4)
        XCTAssertTrue(layout.assignments.allSatisfy { $0.routing.target.stripID == strip.id })
        let compiled = try InstrumentCompiler.compile(document)
        XCTAssertNoThrow(try CompiledControllerLayout(layout, source: .controller(0), sumEndpoint: nil, established: compiled.outputClaims()))
        let conflicts = try CompiledControllerLayout(layout, source: .controller(0), sumEndpoint: nil, established: compiled.outputClaims()).conflicts
        XCTAssertTrue(conflicts.isEmpty, "nothing of the pad is silenced by the scanner")
    }
}
