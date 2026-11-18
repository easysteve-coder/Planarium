import XCTest
import PlanariumDomain
import Foundation
@testable import PlanariumPresets

/// SICK-037c: atomare Ablage, gültige Namen, benannte Fehler.
final class PresetFileStoreTests: XCTestCase {
    private var directory: URL!
    private var store: PresetFileStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SickPresetStore-\(UUID().uuidString)", isDirectory: true)
        store = PresetFileStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testNamesAreValidatedBeforeAnyPathIsBuilt() {
        XCTAssertTrue(PresetFileStore.isValidName("Mein Preset_2"))
        for bad in ["", " führend", "a/b", "..", "x\ny", String(repeating: "a", count: 65)] {
            XCTAssertFalse(PresetFileStore.isValidName(bad), bad)
            XCTAssertThrowsError(try store.save(Data(), as: bad)) { XCTAssertEqual($0 as? PresetStoreError, .invalidName(bad)) }
        }
    }

    func testSaveListLoadDelete() throws {
        XCTAssertEqual(try store.list(), [], "kein Verzeichnis, keine Presets, kein Fehler")
        try store.save(Data("b".utf8), as: "Zwei")
        try store.save(Data("a".utf8), as: "Eins")
        XCTAssertEqual(try store.list(), ["Eins", "Zwei"])
        XCTAssertEqual(try store.load("Eins"), Data("a".utf8))
        try store.save(Data("c".utf8), as: "Eins")
        XCTAssertEqual(try store.load("Eins"), Data("c".utf8), "Überschreiben ersetzt vollständig")
        try store.delete("Eins")
        XCTAssertEqual(try store.list(), ["Zwei"])
        XCTAssertThrowsError(try store.load("Eins")) { XCTAssertEqual($0 as? PresetStoreError, .notFound("Eins")) }
        XCTAssertThrowsError(try store.delete("Eins")) { XCTAssertEqual($0 as? PresetStoreError, .notFound("Eins")) }
    }

    /// Fremde Dateien im Verzeichnis erscheinen nicht als Presets.
    func testForeignFilesAreIgnored() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("notes.txt"))
        try store.save(Data(), as: "Echt")
        XCTAssertEqual(try store.list(), ["Echt"])
    }
}
