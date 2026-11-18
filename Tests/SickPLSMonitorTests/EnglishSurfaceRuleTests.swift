import Foundation
import XCTest

/// Inventory every Swift source target, including future targets, plus the
/// bundle's usage descriptions. Comments and stable lookup identifiers are
/// developer data; all other literal fragments share the English rule.
final class EnglishSurfaceRuleTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let exceptions: Set<String> = [
        "verbinden", "zonen", "felder", "kanalzug", "loesen", "grenzen", // stable HelpTopic IDs
        "die.face.5", // Apple's SF Symbol identifier
        "Die Rasterweite muss endlich und groesser als null sein.",
        "Ein Workspace braucht mindestens eine Ebene.",
        "RX darf nie bei gehaltenem TX-Port beginnen",
        "execute(_:edge:) wird nur für echte I/O-Direktiven aus drivePolicy(_:edge:) gerufen",
        "Frame.payload darf SickPLSFrameConstants.payloadMaxLength nicht überschreiten; ",
        "dies ist eine interne Invariante, die build(...) und decodePrefix(...) bereits durchsetzen."
    ]
    private func german(_ literal: String) -> Bool {
        let words = #"(?i)\b(?:Referenzmessung|laufend|angehalten|nicht|kein|keine|keins|Wert|Werte|Ein|Aus|Evidenz|Kopieren|Sichern|unbekannt|unbekannter|Verbindung|Fehler|fehlgeschlagen|zulässig|Öffnen|beendet|abgelaufen|freigegeben|Der|Die|Das|und|oder|für|wird|muss|sind|ist|kann|nur|Messwert|getroffen|Ausgang|Ebene|Zelle|Netzwerk|Portkonfiguration|Bestätigung|erreichbar|empfangen|gültig|gesperrt|Messung|Auswahl|Adresse|Kennwort|Baudrate|Zielbaudrate|Messläufe|Diagnose|Systemfehler|bestaetigt|erkannt|Anschluss|gueltig|waehlen|Anforderungsfehler|Antwort|danach|ja|nein|Zellen|bemalen|Ton|zuweisen|Zuweisung|entfernen|Effekt|mittel|ohneIndex)\b"#
        let endings = #"(?i)\b\p{L}*(?:ungen|ung|keit|heit|lich|weise|ausgabe|ieren)\b|\bsch[a-zäöüß]+\b"#
        return literal.range(of: #"[äöüÄÖÜß]"#, options: .regularExpression) != nil
            || literal.range(of: words, options: .regularExpression) != nil
            || literal.range(of: endings, options: .regularExpression) != nil
    }
    private func literalFragments(_ source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"//[^\n]*|/\*[\s\S]*?\*/|\"(?:\\[\s\S]|[^\"\\])*\""#)
        let text = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: text.length)).compactMap {
            let token = text.substring(with: $0.range)
            guard token.hasPrefix("\"") else { return nil }
            return String(token.dropFirst().dropLast()).replacingOccurrences(of: #"\\\([^)]*(?:\)|$)"#, with: "", options: .regularExpression)
        }
    }
    func testAllTargetsAndBundleUsageDescriptionsUseEnglish() throws {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
        var targets = Set<String>()
        var files = 0
        for case let file as URL in walker where file.pathExtension == "swift" {
            files += 1
            targets.insert(file.deletingLastPathComponent().lastPathComponent)
            let source = try String(contentsOf: file)
            for literal in try literalFragments(source) where !exceptions.contains(literal) {
                XCTAssertFalse(german(literal), "English rule: \(file.lastPathComponent): \(literal)")
            }
        }
        XCTAssertGreaterThan(files, 100)
        for required in ["PlanariumAudio", "PlanariumApplication", "PlanariumInput", "PlanariumRuntime", "PlanariumScannerUI", "SickPLSMonitor", "SickPLSMonitorKit", "SickPLSSetup"] { XCTAssertTrue(targets.contains(required), required) }
        let bundle = try String(contentsOf: root.appendingPathComponent("scripts/make-app-bundle.sh"))
        for key in ["NSLocalNetworkUsageDescription", "NSDocumentsFolderUsageDescription", "CFBundleDisplayName"] {
            let after = try XCTUnwrap(bundle.components(separatedBy: "<key>\(key)</key>").last)
            let value = try XCTUnwrap(after.components(separatedBy: "<string>").dropFirst().first?.components(separatedBy: "</string>").first)
            XCTAssertFalse(german(value), key)
        }
    }
    func testGermanWordWithoutUmlautAndWithUmlautAreRejected() throws {
        XCTAssertTrue(german("Kopieren")); XCTAssertTrue(german("Öffnen"))
        XCTAssertTrue(german("Ausgabe")); XCTAssertTrue(german("Spielweise"))
        XCTAssertTrue(german("Verbindung")); XCTAssertTrue(german("Schliessen"))
        XCTAssertEqual(try literalFragments("// Kopieren\nText(\"Kopieren\")"), ["Kopieren"])
        XCTAssertFalse(german("Copy diagnostic report"))
    }
    func testNewDetectionAndMergeControlsAndMeterHaveEnglishHelp() throws {
        let field = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/CartesianScanFieldView.swift"))
        for text in ["Combine touching active cell regions", "Smooth each beam over time", "Number of recent scans used by Mean and Median", "Radial distance that separates objects", "Few-point groups are discarded", "Exponential weight of the newest measurement", "Only applies to Point + offset"] {
            XCTAssertTrue(field.contains(text), text)
        }
        let meter = try String(contentsOf: root.appendingPathComponent("Sources/SickPLSMonitor/HelmutChannelSurface.swift"))
        for text in ["Reset overload indicator.", "Live level after the fader", "Adjust the master output level", "Drag vertically to pan"] { XCTAssertTrue(meter.contains(text), text) }
    }
}
