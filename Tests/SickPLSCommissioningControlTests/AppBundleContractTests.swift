import Foundation
import XCTest
@testable import SickPLSCommissioningControl

/// Der **Aktivierungsvertrag der App** (SICK-032a2).
///
/// ## Warum das ein Test ist und keine Notiz
///
/// Der Befund war: Die direkt gestartete ausführbare Datei aus
/// `swift build` ist für macOS **keine reguläre App**. Sie lässt sich
/// nicht normal nach vorn holen, Textfelder bekommen keinen
/// Tastaturfokus, und die native Vollbildfunktion fehlt. Entschieden
/// wird das nicht im Programm, sondern anhand des `.app`-Bundles und
/// seiner `Info.plist`.
///
/// Diese Prüfungen halten genau die Eigenschaften fest, an denen das
/// hängt. Sie starten **nichts** und bauen **nichts** — sie lesen das
/// Bündelskript. Der eigentliche Nachweis, dass die gebündelte App
/// wirklich nach vorn kommt und ihr Textfeld den Tastaturfokus bekommt,
/// ist eine **einmalige Handprobe** und im Rücklauf zu SICK-032a2
/// festgehalten; ein Test, der eine Fenster-App startet, wäre auf einem
/// Rechner ohne Anmeldefenster kein Nachweis, sondern ein Zufall.
@MainActor final class AppBundleContractTests: XCTestCase {

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SickPLSCommissioningControlTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Paketwurzel

    private func bundleScript() throws -> String {
        let url = Self.packageRoot.appendingPathComponent("scripts/make-app-bundle.sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Nur die **erzeugte** `Info.plist`, nicht die Kommentare darum
    /// herum.
    ///
    /// Beim Gegenprobieren aufgefallen: Über das ganze Skript gesucht,
    /// stolperte die Prüfung über den eigenen Erklärsatz, warum
    /// `LSUIElement` fehlt (dieselbe Lehre wie beim Kopf-Check in
    /// SICK-020b).
    private func infoPlist() throws -> String {
        let script = try bundleScript()
        guard let start = script.range(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"),
              let end = script.range(of: "</plist>", range: start.upperBound..<script.endIndex) else {
            XCTFail("Der Info.plist-Abschnitt wurde im Skript nicht gefunden")
            return ""
        }
        return String(script[start.lowerBound..<end.upperBound])
    }

    private func appSource(_ name: String) throws -> String {
        let url = Self.packageRoot.appendingPathComponent("Sources/SickPLSMonitor/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func spatialOutputCompositionSource() throws -> String {
        let url = Self.packageRoot.appendingPathComponent(
            "Sources/PlanariumApplication/PlanariumComposition.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// **Es gibt überhaupt einen Endnutzerweg.**
    func testTheBundleScriptExistsAndIsExecutable() throws {
        let path = Self.packageRoot.appendingPathComponent("scripts/make-app-bundle.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "Das Skript muss ausführbar sein")
    }

    /// Die Schlüssel, ohne die macOS das Bundle nicht als App behandelt.
    func testTheInfoPlistDeclaresARegularApplication() throws {
        let script = try infoPlist()
        for key in [
            "<key>CFBundleExecutable</key>",
            "<key>CFBundleIdentifier</key>",
            "<key>CFBundlePackageType</key>",
            "<key>NSPrincipalClass</key>"
        ] {
            XCTAssertTrue(script.contains(key), "\(key) fehlt in der Info.plist")
        }
        XCTAssertTrue(script.contains("<string>APPL</string>"), "Ohne APPL ist es keine Anwendung")
        XCTAssertTrue(script.contains("<string>NSApplication</string>"))
    }

    /// **Der entscheidende Schlüssel ist der, der fehlen muss.**
    ///
    /// Mit `LSUIElement` wäre die App eine Hintergrundanwendung — ohne
    /// Dock-Eintrag, ohne Menüleiste, ohne Tastaturfokus. Das ist genau
    /// der Zustand, den dieser Slice behoben hat.
    func testTheBundleIsNotABackgroundApplication() throws {
        let script = try infoPlist()
        XCTAssertFalse(script.contains("LSUIElement"), "LSUIElement macht die App wieder unfokussierbar")
        XCTAssertFalse(script.contains("LSBackgroundOnly"))
    }

    /// Die macOS-12-Zusage des Projekts steht auch im Bundle.
    func testTheBundleKeepsTheMacOS12Promise() throws {
        let script = try infoPlist()
        XCTAssertTrue(script.contains("<key>LSMinimumSystemVersion</key>"))
        XCTAssertTrue(script.contains("<string>12.0</string>"))
    }

    func testTheBundleCarriesTheGitBuildNumberAndRevision() throws {
        let script = try bundleScript()
        let plist = try infoPlist()
        XCTAssertTrue(script.contains("git -C \"$ROOT\" rev-list --count HEAD"))
        XCTAssertTrue(plist.contains("<string>${BUILD_NUMBER}</string>"), "Buildnummer muss aus Git kommen")
        XCTAssertTrue(plist.contains("<key>PlanariumGitRevision</key>"))
        XCTAssertTrue(plist.contains("<string>${GIT_REVISION}</string>"))
        XCTAssertFalse(plist.contains("<string>1</string>"), "Eine feste Buildnummer würde den Vertrag brechen")
    }

    func testTheBundleDeclaresTheDocumentsUsageAndStableSigningPath() throws {
        let script = try bundleScript()
        let plist = try infoPlist()
        XCTAssertTrue(plist.contains("<key>NSDocumentsFolderUsageDescription</key>"))
        XCTAssertTrue(plist.contains("Loaded audio plug-ins read their presets from the Documents folder."))
        XCTAssertTrue(script.contains("PLANARIUM_SIGN_IDENTITY"))
        XCTAssertTrue(script.contains("Apple Development:"))
        XCTAssertTrue(script.contains("candidate_hash"))
        XCTAssertTrue(script.contains("codesign --force --sign \"$candidate_hash\""),
                      "Automatische Kandidaten müssen per SHA-1-Hash signieren")
        XCTAssertTrue(script.contains("hash = $2"), "security-Ausgabe liefert den SHA-1-Hash als zweite Spalte")
        XCTAssertFalse(script.contains("--options runtime"), "PACE/UAD benötigen Hardened Runtime nicht")
    }

    /// Genau eine Instanz: Mehrere Kopien würden um Scanneranschluss, MIDI
    /// und Audio konkurrieren (Owner 03.10.2026, sechs hängende Instanzen).
    func testTheBundleProhibitsMultipleInstances() throws {
        let script = try infoPlist()
        XCTAssertTrue(script.contains("<key>LSMultipleInstancesProhibited</key>\n    <true/>"))
    }

    /// Die Einstellungen sind über den gewohnten Menübefehl erreichbar.
    func testTheAppDeclaresASettingsScene() throws {
        let app = try appSource("SickPLSMonitorApp.swift")
        XCTAssertTrue(app.contains("Settings {"), "Ohne `Settings`-Scene gibt es keinen Einstellungsbefehl")
        XCTAssertTrue(app.contains("ScannerPasswordSettingsView"))
    }

    /// **Eine Ablage, drei Leser.** Getrennte Ablagen wären mehrere
    /// Wahrheiten über dasselbe Passwort.
    func testTheAppCreatesExactlyOnePasswordStore() throws {
        let app = try appSource("SickPLSMonitorApp.swift")
        let occurrences = app.components(separatedBy: "UserDefaultsScannerPasswordStore()").count - 1
        XCTAssertEqual(occurrences, 1, "Das Passwort gehört in genau eine Ablage")
        XCTAssertTrue(app.contains("passwordStore: passwordStore"))
        XCTAssertTrue(app.contains("ScannerPasswordSettingsModel(store: passwordStore)"))
    }

    /// Die manuelle Einrichtung steht als Support-Werkzeug in den
    /// Einstellungen -- genau einmal, und nicht in der Arbeitsfläche
    /// (SICK-0330b).
    func testTheManualCommissioningLivesInTheSettingsSupportTab() throws {
        let app = try appSource("SickPLSMonitorApp.swift")
        XCTAssertEqual(app.components(separatedBy: "CommissioningControlView(").count - 1, 1)
        XCTAssertTrue(app.contains("\"Support\""))
        XCTAssertEqual(
            app.components(separatedBy: "ContentView(").count - 1,
            1,
            "Die Arbeitsfläche darf nur einmal komponiert werden"
        )
        XCTAssertTrue(app.contains("scannerSetup: models.scannerDevelopment"))
    }

    /// **Die Hilfe** (SICK-039) hängt am Hilfemenü und öffnet genau ein
    /// Fenster über AppKit.
    func testTheAppOffersInAppHelpFromTheHelpMenu() throws {
        let app = try appSource("SickPLSMonitorApp.swift")
        XCTAssertTrue(app.contains("CommandGroup(replacing: .help)"))
        XCTAssertTrue(app.contains("HelpWindowController.shared.show()"))
        let help = try appSource("HelpWindow.swift")
        XCTAssertTrue(help.contains("ForEach(HelpTopics.all)"), "die Hilfe rendert die eine Themenliste")
    }

    /// **Ein Presetmodell** (SICK-037) über die Standardablage; es kennt
    /// Koordinator, Rackmodell, MIDI-Modell und räumliches Instrument -- keinen zweiten Dienst.
    func testTheAppComposesExactlyOnePresetModel() throws {
        let app = try appSource("SickPLSMonitorApp.swift")
        XCTAssertEqual(app.components(separatedBy: "PresetControlModel(").count - 1, 1)
        XCTAssertTrue(app.contains("store: PresetFileStore.standard(), documentOwner: root.document"))
    }

    func testTheAppSharesOneAudioHostWithTheChannel() throws {
        let app = try appSource("SickPLSMonitorApp.swift")
        let composition = try spatialOutputCompositionSource()
        XCTAssertEqual(app.components(separatedBy: "PlanariumComposition(").count - 1, 1)
        XCTAssertEqual(composition.components(separatedBy: "AudioHost(").count - 1, 1)
        XCTAssertEqual(composition.components(separatedBy: "AVAudioGraph()").count - 1, 1)
        XCTAssertTrue(app.contains("AudioOutputDeviceControlModel(host: root.audio, preferences: UserDefaultsAudioOutputPreferences()"))
        XCTAssertTrue(composition.contains("audio: audio, midi: self.midi"))
        XCTAssertTrue(app.contains("ScannerWorkspaceModel(input: root.input)"))
    }

    func testTheAppComposesExactlyOneMIDISink() throws {
        let app = try appSource("SickPLSMonitorApp.swift")
        let composition = try spatialOutputCompositionSource()
        XCTAssertEqual(app.components(separatedBy: "CoreMIDIConnection()").count - 1, 1)
        XCTAssertEqual(composition.components(separatedBy: "MIDIPortOwner(").count - 1, 1)
        XCTAssertTrue(composition.contains("midi.shutdown"))
    }

    func testTheOutputOwnersRebindOnlyFromDesiredResourceChanges() throws {
        let midi = try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/PlanariumMIDI/MIDIPortOwner.swift"))
        let audio = try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/PlanariumAudio/AudioHost.swift"))
        XCTAssertFalse(midi.contains("objectWillChange.sink"))
        // Mixer siblings forward presentation changes only; this callback
        // cannot apply, rebind, retire, or configure an output resource.
        let relays = audio.components(separatedBy: "\n").filter { $0.contains("objectWillChange.sink") }
        XCTAssertEqual(relays.count, 1)
        XCTAssertTrue(relays[0].hasSuffix("{ [weak self] in self?.objectWillChange.send() }"))
        XCTAssertTrue(midi.contains("runtime.retire"))
        XCTAssertTrue(audio.contains("runtime.retire"))
    }

    func testGraphConfigurationKeepsRetireBeforeRebuild() throws {
        let audio = try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/PlanariumAudio/AudioHost.swift"))
        XCTAssertTrue(audio.contains("if instrument != nil { retireInstrument() }"))
        XCTAssertTrue(audio.contains("rebuild(retainedInstrument: old)"))
        XCTAssertTrue(audio.contains("runtime.retire(id: old.id)"))
    }

    func testTheAppObservesSleepWakeAndTerminationOnce() throws {
        let app = try appSource("SickPLSMonitorApp.swift")
        for (notification, call) in [
            ("NSWorkspace.willSleepNotification", "root.sleep()"),
            ("NSWorkspace.didWakeNotification", "root.wake()")
        ] {
            XCTAssertEqual(app.components(separatedBy: notification).count - 1, 1)
            XCTAssertEqual(app.components(separatedBy: call).count - 1, 1)
        }
        XCTAssertEqual(app.components(separatedBy: "AppLifecycleObserver(").count - 1, 1)
        XCTAssertTrue(app.contains("@NSApplicationDelegateAdaptor(TerminationDelegate.self)"))
        XCTAssertTrue(app.contains("applicationShouldTerminate"))
        XCTAssertTrue(app.contains("return .terminateLater"))
        XCTAssertTrue(app.contains("root.terminate(completion)"))
        let composition = try spatialOutputCompositionSource()
        let wake = composition.components(separatedBy: "public func wake()")[1].components(separatedBy: "public func configureAudio")[0]
        XCTAssertFalse(wake.contains("startSpatialAudio"))
    }

    /// **Kein Passwortfeld mitten im Ablauf** (SICK-032a2).
    func testTheCommissioningViewAsksForNoPassword() throws {
        let view = try appSource("CommissioningControlView.swift")
        XCTAssertFalse(view.contains("SecureField"), "Das Passwort wird nicht mehr im Ablauf abgefragt")
        XCTAssertFalse(view.contains("secretText"))
    }

    /// Die Ansicht entscheidet **nicht selbst**, was bestätigt werden
    /// muss — sie fragt das Modell.
    func testTheViewAsksTheModelWhichStepsNeedConfirmation() throws {
        let view = try appSource("CommissioningControlView.swift")
        XCTAssertTrue(view.contains("model.requestStep(command)"))
        XCTAssertTrue(view.contains("model.prepareScanner()"))
    }
}
