import Foundation
import XCTest

/// Der **Aktivierungsvertrag der Setup-App** (SICK-032a2, gleiches Muster
/// wie `AppBundleContractTests` für den Monitor).
///
/// Der Befund war schon einmal dokumentiert und trat erneut auf: Die
/// direkt aus `swift build` gestartete ausführbare Datei ist für macOS
/// **keine reguläre App**. Textfelder — etwa das Zieladressfeld —
/// bekommen keinen Tastaturfokus, und die native Vollbildfunktion fehlt.
/// Entschieden wird das nicht im Programm, sondern anhand des
/// `.app`-Bundles und seiner `Info.plist`.
///
/// Diese Prüfungen halten genau die Eigenschaften fest, an denen das
/// hängt. Sie starten **nichts** und bauen **nichts** — sie lesen das
/// Bündelskript. Der eigentliche Nachweis, dass die gebündelte Setup-App
/// nach vorn kommt und ihr Textfeld den Fokus bekommt, ist eine
/// **Handprobe** am laufenden Bundle.
final class SetupAppBundleContractTests: XCTestCase {

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SickPLSSetupTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Paketwurzel

    private func scriptURL() -> URL {
        Self.packageRoot.appendingPathComponent("scripts/make-setup-app-bundle.sh")
    }

    private func bundleScript() throws -> String {
        try String(contentsOf: scriptURL(), encoding: .utf8)
    }

    /// Nur die **erzeugte** `Info.plist`, nicht die Erklärkommentare
    /// darum herum (dieselbe Lehre wie beim Monitor-Kopf-Check).
    private func infoPlist() throws -> String {
        let script = try bundleScript()
        guard let start = script.range(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"),
              let end = script.range(of: "</plist>", range: start.upperBound..<script.endIndex) else {
            XCTFail("Der Info.plist-Abschnitt wurde im Skript nicht gefunden")
            return ""
        }
        return String(script[start.lowerBound..<end.upperBound])
    }

    /// **Es gibt überhaupt einen Endnutzerweg für die Setup-App.**
    func testTheSetupBundleScriptExistsAndIsExecutable() throws {
        let path = scriptURL().path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "Das Skript muss ausführbar sein")
    }

    /// Die Schlüssel, ohne die macOS das Bundle nicht als App behandelt.
    func testTheInfoPlistDeclaresARegularApplication() throws {
        let plist = try infoPlist()
        for key in [
            "<key>CFBundleExecutable</key>",
            "<key>CFBundleIdentifier</key>",
            "<key>CFBundlePackageType</key>",
            "<key>NSPrincipalClass</key>"
        ] {
            XCTAssertTrue(plist.contains(key), "\(key) fehlt in der Info.plist")
        }
        XCTAssertTrue(plist.contains("<string>APPL</string>"), "Ohne APPL ist es keine Anwendung")
        XCTAssertTrue(plist.contains("<string>NSApplication</string>"))
        XCTAssertTrue(plist.contains("<string>SickPLSSetup</string>"), "Die ausführbare Datei heißt SickPLSSetup")
    }

    /// **Der entscheidende Schlüssel ist der, der fehlen muss.** Mit
    /// `LSUIElement` wäre die App unfokussierbar — genau der Zustand,
    /// der hier behoben wird.
    func testTheBundleIsNotABackgroundApplication() throws {
        let plist = try infoPlist()
        XCTAssertFalse(plist.contains("LSUIElement"), "LSUIElement macht die App wieder unfokussierbar")
        XCTAssertFalse(plist.contains("LSBackgroundOnly"))
    }

    /// Die macOS-12-Zusage des Projekts steht auch im Bundle.
    func testTheBundleKeepsTheMacOS12Promise() throws {
        let plist = try infoPlist()
        XCTAssertTrue(plist.contains("<key>LSMinimumSystemVersion</key>"))
        XCTAssertTrue(plist.contains("<string>12.0</string>"))
    }
}
