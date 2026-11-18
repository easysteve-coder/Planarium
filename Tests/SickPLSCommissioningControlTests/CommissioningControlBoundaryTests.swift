import PlanariumInput
import Foundation
import XCTest
@testable import SickPLSCommissioningControl

enum ControlSourcePaths {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SickPLSCommissioningControlTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Paketwurzel

    static let sources = packageRoot.appendingPathComponent("Sources/SickPLSCommissioningControl")
    static let appSources = packageRoot.appendingPathComponent("Sources/SickPLSMonitor")
}

/// Automatische Prüfung der Modulgrenze — nach dem Muster von
/// `CommissioningBoundaryTests` (SICK-030a/031) und
/// `PerformanceSessionBoundaryTests` (SICK-029).
///
/// **Wer hier eine Abhängigkeit, einen Import oder eine Datei ergänzt,
/// muss die Listen unten bewusst mitpflegen, sonst schlägt `swift test`
/// fehl.**
final class CommissioningControlBoundaryTests: XCTestCase {

    private static let allowedImports: Set<String> = [
        "Combine",
        "Dispatch",
        // Seit SICK-032a2: Das Scanner-Passwort ist eine gewöhnliche
        // Einstellung und liegt in `UserDefaults`.
        "Foundation",
        "SickPLSCommissioning",
        "SickPLSMacTransport",
        "SickPLSActiveControl",
        "PlanariumInput",
        // Seit SICK-0330a: `StandardConnectionRun` treibt den passiven
        // Fast Path und die eine B1-Probe selbst (dieselben Bausteine
        // wie `CommissioningExecutor`) und braucht dafür `Frame`/
        // `StreamParser` direkt.
        "SickPLSCore"
    ]

    /// Was in diesem Modul **nirgends** stehen darf.
    ///
    /// - `SwiftUI`: Die Ansicht komponiert nur; hier liegt kein Pixel.
    /// - `AVFoundation`/`CoreMIDI`/`PlanariumPresets`: Dieser Pfad hat mit
    ///   Klang nichts zu tun.
    /// - `RXSession`/`SickPLSMonitorKit`: Der Bedienpfad greift **nie**
    ///   selbst in die Sitzung; Trennen und Freigabe laufen
    ///   ausschließlich über ``CommissioningPortCoordinating``
    ///   (Bedienvertrag 5).
    /// - `Timer`/`DispatchQueue.main.asyncAfter`/`sleep`: **Kein
    ///   Autostart und keine Wiederholungsautomatik.**
    private static let forbiddenIdentifiers = [
        "SwiftUI",
        "AVFoundation",
        "CoreMIDI",
        "PlanariumPresets",
        "SickThereminPerformance",
        "RXSession",
        "SickPLSMonitorKit",
        "Timer(",
        "Timer.scheduled",
        "asyncAfter",
        "sleep(",
        // SICK-032a1: **Keine Beschreibung eines fremden Fehlers.** Ein
        // fremder Laufanbieter, Opener oder künftiger Transport könnte
        // in seiner Beschreibung Port-, Payload- oder Geheimnisdaten
        // tragen; dieses Modul darf sie deshalb gar nicht erst lesen.
        // Wer einen dieser Aufrufe ergänzt, lässt `swift test`
        // fehlschlagen.
        "String(describing:",
        "String(reflecting:",
        "localizedDescription",
        "\\(error",
        // SICK-0330a-1-K1, H4/PN9: **Kein optionaler Cast auf
        // `CommissioningAborting` mehr.** `CommissioningRunProviding
        // .makeRun(portPath:)` liefert seither strukturell
        // `CommissioningRunning & CommissioningAborting` -- jeder Lauf
        // ist damit zwingend abbrechbar, ohne dass eine Stelle das erst
        // per Cast prüfen (und im Fehlerfall einen Abbruch als
        // `.started(.abort)` melden, ohne ihn ausgelöst zu haben) könnte.
        // Ein künftiger Rückfall auf einen Cast lässt `swift test`
        // fehlschlagen.
        "as? CommissioningAborting",
        "as! CommissioningAborting"
    ]

    /// Die **einzige** Datei, die eine reale Hardware-Anbindung
    /// herstellt -- der manuelle Bedienpfad (Bedienvertrag 5).
    private static let hardwareFactoryFile = "SystemCommissioningRunFactory.swift"

    /// Was ausschließlich dort stehen darf.
    private static let hardwareOnlyIdentifiers = [
        "ActiveControlCommissioningTransport",
        "DarwinActiveControlSerialPortOpener"
    ]

    /// Dateien, die einen echten ``CommissioningExecutor`` konstruieren
    /// dürfen -- der manuelle Bedienpfad (`SystemCommissioningRunFactory`)
    /// **und**, seit SICK-0330a, der eigenständige, vollständig
    /// injizierbare Standardverbindungslauf (`StandardConnectionRun`).
    /// **Beide binden ihn an einen injizierten `CommissioningTransport`,
    /// keiner an reale Hardware direkt** -- das bleibt ausschließlich
    /// ``hardwareFactoryFile`` vorbehalten.
    private static let executorConstructionFiles: Set<String> = [
        "SystemCommissioningRunFactory.swift",
        "StandardConnectionRun.swift"
    ]

    private func swiftSources(in directory: URL) throws -> [(name: String, text: String)] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let sources = try files
            .filter { $0.pathExtension == "swift" }
            .map { (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
        XCTAssertFalse(sources.isEmpty, "Quellverzeichnis nicht gefunden: \(directory.path)")
        return sources
    }

    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheModuleImportsNothingBeyondItsDeclaredBoundary() throws {
        for source in try swiftSources(in: ControlSourcePaths.sources) {
            for line in source.text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed.dropFirst("import ".count).split(separator: " ").first.map(String.init) ?? ""
                XCTAssertTrue(
                    Self.allowedImports.contains(module),
                    "\(source.name) importiert \(module) -- nicht in der erlaubten Liste"
                )
            }
        }
    }

    func testTheModuleNamesNoForbiddenIdentifier() throws {
        for source in try swiftSources(in: ControlSourcePaths.sources) {
            let code = codeOnly(source.text)
            for identifier in Self.forbiddenIdentifiers {
                XCTAssertFalse(
                    code.contains(identifier),
                    "\(source.name) nennt \(identifier) -- außerhalb der Modulgrenze"
                )
            }
        }
    }

    /// **Reale Hardware-Anbindung entsteht an genau einer Stelle, ein
    /// echter `CommissioningExecutor` an genau zwei benannten Stellen**
    /// (Bedienvertrag 5, erweitert um SICK-0330a).
    func testOnlyTheFactoryBuildsARealRun() throws {
        var filesConstructingAnExecutor: Set<String> = []
        var filesNamingHardware: Set<String> = []
        for source in try swiftSources(in: ControlSourcePaths.sources) {
            let code = codeOnly(source.text)
            if code.contains("CommissioningExecutor(") {
                filesConstructingAnExecutor.insert(source.name)
                XCTAssertTrue(
                    Self.executorConstructionFiles.contains(source.name),
                    "\(source.name) nennt CommissioningExecutor( -- das ist nur in \(Self.executorConstructionFiles.sorted()) vorgesehen"
                )
            }
            for identifier in Self.hardwareOnlyIdentifiers where code.contains(identifier) {
                filesNamingHardware.insert(source.name)
                XCTAssertEqual(
                    source.name,
                    Self.hardwareFactoryFile,
                    "\(source.name) nennt \(identifier) -- reale Hardware-Anbindung entsteht ausschließlich in \(Self.hardwareFactoryFile)"
                )
            }
        }
        XCTAssertFalse(
            filesConstructingAnExecutor.isEmpty,
            "Die Prüfung liefe ins Leere, wenn gar keine Datei mehr einen Executor herstellt"
        )
        XCTAssertFalse(
            filesNamingHardware.isEmpty,
            "Die Prüfung liefe ins Leere, wenn gar keine Datei mehr reale Hardware nennt"
        )
    }

    /// **Review-Befund N2 strukturell geschlossen** (Bedienvertrag 3).
    ///
    /// `CommissioningExecutor.report` eines nie gestarteten Executors ist
    /// `isFinal` und gäbe den Portbesitz frei, ohne dass je ein Lauf
    /// stattfand. Das Bedienmodell kann den Wert nicht einmal benennen,
    /// weil ``CommissioningRunning`` ihn nicht kennt.
    func testTheModelNeverNamesTheExecutorsOwnReport() throws {
        for source in try swiftSources(in: ControlSourcePaths.sources) {
            let code = codeOnly(source.text)
            XCTAssertFalse(
                code.contains(".report"),
                "\(source.name) nennt `.report` -- der Abschluss kommt ausschließlich aus einem gelaufenen `perform`"
            )
        }
    }

    /// Gegenrichtung: Die eine Grenze darf nicht wachsen.
    ///
    /// Ein zweites Mitglied an ``CommissioningRunning`` — etwa ein
    /// bequemes `report` — machte den Nachweis oben wertlos.
    func testTheRunBoundaryDeclaresExactlyOneMember() throws {
        let text = try String(
            contentsOf: ControlSourcePaths.sources.appendingPathComponent("CommissioningRunning.swift"),
            encoding: .utf8
        )
        let protocolBody = try XCTUnwrap(
            text.range(of: "public protocol CommissioningRunning: AnyObject {").map { range in
                String(text[range.upperBound...].prefix(while: { $0 != "}" }))
            }
        )
        let members = codeOnly(protocolBody)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(members.count, 1, "CommissioningRunning hat \(members.count) Mitglieder: \(members)")
        XCTAssertTrue(members[0].hasPrefix("func perform("), "Unerwartetes Mitglied: \(members[0])")
    }

    /// **Die Ansicht komponiert nur** (Bedienvertrag 5).
    func testTheAppTargetDuplicatesNoCommissioningLogic() throws {
        let forbidden = [
            "CommissioningExecutor",
            "ActiveControlCommissioningTransport",
            "CommissioningModel",
            "CommissioningTelegram",
            "InstallationSecret(",
            "DarwinMonotonicClock",
            "DispatchQueue",
            "requestCommissioningAccess",
            "completeCommissioning",
            "SerialPortEnumeration.availablePortPaths"
        ]
        for source in try swiftSources(in: ControlSourcePaths.appSources) {
            let code = codeOnly(source.text)
            for identifier in forbidden where source.name.contains("Commissioning") {
                XCTAssertFalse(
                    code.contains(identifier),
                    "\(source.name) nennt \(identifier) -- das gehört ins Bedienmodell"
                )
            }
        }
    }

    func testThePackageManifestDeclaresExactlyTheseDependencies() throws {
        let manifest = try String(
            contentsOf: ControlSourcePaths.packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        guard let range = manifest.range(
            of: "name: \"SickPLSCommissioningControl\",\n            dependencies:"
        ) else {
            return XCTFail("Zielbeschreibung im Manifest nicht gefunden")
        }
        let section = String(manifest[range.lowerBound...].components(separatedBy: ".testTarget(")[0])
        for dependency in [
            "SickPLSCommissioning",
            "SickPLSMacTransport",
            "SickPLSActiveControl",
            "PlanariumInput"
        ] {
            XCTAssertTrue(section.contains("\"\(dependency)\""), "\(dependency) fehlt")
        }
        for forbidden in ["PlanariumPresets", "SickThereminPerformance", "SickPLSMonitorKit"] {
            XCTAssertFalse(section.contains("\"\(forbidden)\""), "\(forbidden) gehört nicht in dieses Ziel")
        }
    }

    /// **PN9 (SICK-0330a-1-K1, H4), strukturell statt nur per Konvention:**
    /// `CommissioningRunProviding.makeRun(portPath:)` liefert zwingend
    /// `CommissioningRunning & CommissioningAborting` -- ein Rückfall auf
    /// eine bloße `CommissioningRunning`-Rückgabe (mit optionalem Cast an
    /// der Aufrufstelle) lässt diese Prüfung fehlschlagen.
    func testMakeRunReturnsTheAbortableIntersectionTypeStructurally() throws {
        let text = try String(
            contentsOf: ControlSourcePaths.sources.appendingPathComponent("CommissioningRunning.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            text.contains("func makeRun(portPath: String) throws -> CommissioningRunning & CommissioningAborting"),
            "Die Protokollgrenze garantiert Abbruchfähigkeit nicht mehr strukturell"
        )
    }

    /// **SICK-0330a-K1, K1-5 / Pflichtnachweis 8:** In
    /// `StandardConnectionRun.swift` steht **kein** `default:`.
    ///
    /// Der Lauf schaltet über `ConnectionPolicyDirective`,
    /// `ConnectionPolicyEvent`, `ConnectionPolicyPhase`,
    /// `CommissioningPhase` und `CommissioningFailure` -- lauter
    /// geschlossene Typen aus abgenommenen Verträgen. Ein `default:`
    /// ließe einen neuen Fall dort still verschwinden, statt ihn sichtbar
    /// zu einer Entscheidung zu zwingen. Dieselbe Regel wie
    /// ``ConnectionPolicyBoundaryTests/testNoSwitchInTheReducerFileUsesDefault``.
    func testTheStandardConnectionRunUsesNoDefaultInAnySwitch() throws {
        let text = try String(
            contentsOf: ControlSourcePaths.sources.appendingPathComponent("StandardConnectionRun.swift"),
            encoding: .utf8
        )
        let code = codeOnly(text)
        XCTAssertFalse(
            code.contains("default:") || code.contains("default :"),
            "StandardConnectionRun.swift benutzt `default:` -- jeder Fall gehört sichtbar entschieden"
        )
    }

    /// Dieselbe Regel für die Textgrenze (K1-4): Ein neuer
    /// ``StandardConnectionFailure``-Fall muss sich einen eigenen Satz
    /// geben, statt unter einem Sammeltext zu verschwinden.
    func testTheStandardConnectionPresentationUsesNoDefaultInAnySwitch() throws {
        let text = try String(
            contentsOf: ControlSourcePaths.sources.appendingPathComponent("StandardConnectionPresentation.swift"),
            encoding: .utf8
        )
        let code = codeOnly(text)
        XCTAssertFalse(
            code.contains("default:") || code.contains("default :"),
            "StandardConnectionPresentation.swift benutzt `default:`"
        )
    }

    /// **SICK-0330a-K1, Supervisor-Korrektur H1 / Nachweis 1:** Die
    /// öffentlichen Standardverbindungstypen betten weder
    /// `CommissioningPhase` noch `CommissioningFailure` ein.
    ///
    /// Geprüft wird der **Deklarationsrumpf** jedes Typs, nicht die
    /// Datei: `mapCommissioningPhase`/`mapCommissioningFailure` dürfen
    /// beide Typen selbstverständlich weiterhin *lesen* -- genau das ist
    /// die Abbildung. Verboten ist, sie als Assoziativwert oder Feld zu
    /// **tragen**.
    ///
    /// `CommissioningAudit` bleibt ausdrücklich zulässig (K1-4): Es ist
    /// selbst bereits redigiert und trägt keine Bytes, Payloads oder
    /// Fremdtexte.
    func testThePublicStandardConnectionTypesEmbedNoRawCommissioningValue() throws {
        let text = try String(
            contentsOf: ControlSourcePaths.sources.appendingPathComponent("StandardConnectionRun.swift"),
            encoding: .utf8
        )
        let code = codeOnly(text)
        let declarations = [
            "public enum StandardConnectionPhase",
            "public enum StandardConnectionFailure",
            "public enum StandardConnectionCommissioningStage",
            "public enum StandardConnectionCommissioningOrigin",
            "public enum StandardConnectionSuccessPath",
            "public struct StandardConnectionReport"
        ]
        for declaration in declarations {
            let body = try XCTUnwrap(
                declarationBody(of: declaration, in: code),
                "Deklaration nicht gefunden: \(declaration)"
            )
            for forbidden in ["CommissioningPhase", "CommissioningFailure"] {
                XCTAssertFalse(
                    body.contains(forbidden),
                    "\(declaration) trägt \(forbidden) -- die öffentliche Grenze bleibt datenfrei (K1-4)"
                )
            }
        }
    }

    /// Der Rumpf einer Typdeklaration: von ihrer Zeile bis zur ersten
    /// Zeile, die nur aus `}` besteht.
    private func declarationBody(of declaration: String, in code: String) -> String? {
        let lines = code.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else { return nil }
        guard let end = lines[(start + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "}"
        }) else { return nil }
        return lines[start...end].joined(separator: "\n")
    }

    /// **SICK-0330a-K1, K1-6 / Pflichtnachweis 8:** Die paketinterne
    /// Übernahmegrenze
    /// `CommissioningExecutor.adoptAlreadyOpenConnectionWithConfirmedIdentity()`
    /// wird im **produktiven** Quelltext von genau einer Stelle gerufen
    /// -- dem Standardverbindungslauf, der den offenen Port und die
    /// belegte Identität selbst hergestellt hat.
    ///
    /// Sie behauptet Porthaltung und bestätigte Identität, ohne sie
    /// erzwingen zu können; deshalb ist sie `package` statt `public`
    /// (ein fremdes Modul kann sie gar nicht sehen) **und** hier
    /// zusätzlich auf ihren einen legitimen Aufrufer festgelegt.
    func testTheAdoptionBoundaryIsCalledFromExactlyOneProductionFile() throws {
        var callers: Set<String> = []
        for directory in [
            ControlSourcePaths.sources,
            ControlSourcePaths.appSources,
            ControlSourcePaths.packageRoot.appendingPathComponent("Sources/SickPLSCommissioning"),
            ControlSourcePaths.packageRoot.appendingPathComponent("Sources/PlanariumScannerUI")
        ] {
            for source in try swiftSources(in: directory) {
                let code = codeOnly(source.text)
                guard code.contains(".adoptAlreadyOpenConnectionWithConfirmedIdentity(") else { continue }
                callers.insert(source.name)
            }
        }
        XCTAssertEqual(
            callers, ["StandardConnectionRun.swift"],
            "Die Übernahmegrenze wird von \(callers.sorted()) gerufen -- vorgesehen ist ausschließlich StandardConnectionRun.swift"
        )
    }

    /// Gegenrichtung: Die Grenze bleibt **paketintern**. Würde sie wieder
    /// `public`, könnte ein fremdes Modul einen Executor in einen
    /// Zustand versetzen, für den es die Vorbedingung nie hergestellt hat.
    func testTheAdoptionBoundaryStaysPackageInternal() throws {
        let text = try String(
            contentsOf: ControlSourcePaths.packageRoot
                .appendingPathComponent("Sources/SickPLSCommissioning/CommissioningExecutor.swift"),
            encoding: .utf8
        )
        let code = codeOnly(text)
        XCTAssertTrue(
            code.contains("package func adoptAlreadyOpenConnectionWithConfirmedIdentity()"),
            "Die Übernahmegrenze ist nicht mehr `package`"
        )
        XCTAssertFalse(
            code.contains("public func adoptAlreadyOpenConnectionWithConfirmedIdentity()"),
            "Die Übernahmegrenze ist wieder öffentlich -- K1-6 verlangt paketintern"
        )
    }

    /// Gegenrichtung zur geliehenen Kante (K1-2): Auch sie bleibt
    /// paketintern, und der **manuelle** ``CommissioningExecutor/perform(_:secret:)``
    /// bleibt öffentlich -- sein K2/K3-Kantenvertrag ist unverändert.
    func testTheLoanedEdgeEntryPointStaysPackageInternalAndManualPerformStaysPublic() throws {
        let text = try String(
            contentsOf: ControlSourcePaths.packageRoot
                .appendingPathComponent("Sources/SickPLSCommissioning/CommissioningExecutor.swift"),
            encoding: .utf8
        )
        let code = codeOnly(text)
        XCTAssertTrue(code.contains("package func performUsingLoanedEdge("))
        XCTAssertFalse(code.contains("public func performUsingLoanedEdge("))
        XCTAssertTrue(code.contains("public func perform("))
    }

    // MARK: - SICK-0330b: genau ein Verbindungsweg

    /// **Die Verbindungsleiste ist der einzige Verbindungsweg der App.**
    /// Kein App-File ruft den Koordinator direkt zum Verbinden oder
    /// Trennen, und genau eine Stelle erzeugt das Verbindungsmodell.
    func testTheAppHasExactlyOneConnectionPath() throws {
        var modelConstructions = 0
        for source in try swiftSources(in: ControlSourcePaths.appSources) {
            let code = codeOnly(source.text)
            for forbidden in [
                "coordinator.connect(", "coordinator.disconnect(",
                "StandardConnectionRun(", "releasePortForMeasurement", "run.retryClose(", "run?.retryClose(",
                "SystemStandardConnectionRunFactory(", "finishCommissioning"
            ] where source.name != "SickPLSMonitorApp.swift" || forbidden != "SystemStandardConnectionRunFactory(" {
                XCTAssertFalse(
                    code.contains(forbidden),
                    "\(source.name) nennt \(forbidden) -- Verbinden geht nur über die Leiste"
                )
            }
            modelConstructions += code.components(separatedBy: "StandardConnectionControlModel(").count - 1
        }
        XCTAssertEqual(modelConstructions, 1, "Genau ein Verbindungsmodell in der App")
        let app = try String(
            contentsOf: ControlSourcePaths.appSources.appendingPathComponent("SickPLSMonitorApp.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(
            codeOnly(app).components(separatedBy: "SystemStandardConnectionRunFactory(").count - 1, 1,
            "Genau eine reale Lauffabrik"
        )
    }

    /// **Der Standardlauf wird produktiv von genau einer Stelle
    /// gefahren** -- dem Verbindungsmodell. Die Freigabegrenze
    /// `releasePortForMeasurement()` und der Retry haben keinen zweiten
    /// Aufrufer.
    func testTheStandardRunIsDrivenOnlyByTheConnectionModel() throws {
        var callers: Set<String> = []
        for source in try swiftSources(in: ControlSourcePaths.sources) {
            let code = codeOnly(source.text)
            for call in [".connect(portPath:", ".releasePortForMeasurement()", ".retryClose()"] {
                if code.contains(call) && source.name != "StandardConnectionRun.swift" {
                    callers.insert(source.name)
                }
            }
        }
        XCTAssertEqual(callers, ["StandardConnectionControlModel.swift"])
    }

    /// Ein echter ``StandardConnectionRun`` mit realem Transport entsteht
    /// nur in der Hardware-Fabrikdatei.
    func testOnlyTheHardwareFactoryBuildsAStandardRun() throws {
        for source in try swiftSources(in: ControlSourcePaths.sources) where source.name != Self.hardwareFactoryFile {
            XCTAssertFalse(
                codeOnly(source.text).contains("StandardConnectionRun("),
                "\(source.name) baut einen StandardConnectionRun -- vorgesehen ist nur \(Self.hardwareFactoryFile)"
            )
        }
    }

    /// RX beginnt im Modell ausschließlich aus einem portfreien Bericht:
    /// Die einzige Stelle, die `coordinator.connect(` ruft, steht hinter
    /// der Vorbedingung `!report.isPortHeld`.
    func testTheModelStartsMeasurementOnlyBehindThePortFreePrecondition() throws {
        let text = try String(
            contentsOf: ControlSourcePaths.sources.appendingPathComponent("StandardConnectionControlModel.swift"),
            encoding: .utf8
        )
        let code = codeOnly(text)
        XCTAssertEqual(code.components(separatedBy: "coordinator.connect(").count - 1, 1)
        let start = try XCTUnwrap(code.range(of: "private func startMeasurement(after report: StandardConnectionReport)"))
        let body = String(code[start.upperBound...].prefix(600))
        XCTAssertTrue(body.contains("precondition(!report.isPortHeld"))
        XCTAssertTrue(body.contains("coordinator.connect("))
        XCTAssertTrue(body.contains("finishCommissioning(verifiedBaudRate: Self.measurementBaudRate)"))
    }

    /// Die Textgrenzen der Leiste stehen ohne `default`.
    func testTheBarPresentationAndStateUseNoDefaultInAnySwitch() throws {
        for file in ["ConnectionBarState.swift", "ConnectionBarPresentation.swift", "ConnectionEvidence.swift",
                     "StandardConnectionControlModel.swift"] {
            let text = try String(contentsOf: ControlSourcePaths.sources.appendingPathComponent(file), encoding: .utf8)
            let code = codeOnly(text)
            XCTAssertFalse(code.contains("default:") || code.contains("default :"), "\(file) benutzt `default:`")
        }
    }

    /// **Der RX-Monitor bleibt RX-only.** Geprüft statt behauptet.
    func testTheReadOnlyTransportStillHasNoWritePath() throws {
        let transport = ControlSourcePaths.packageRoot
            .appendingPathComponent("Sources/SickPLSMacTransport")
        for source in try swiftSources(in: transport) {
            let code = codeOnly(source.text)
            for forbidden in ["func write(", "O_RDWR", "O_WRONLY"] {
                XCTAssertFalse(code.contains(forbidden), "\(source.name) nennt \(forbidden)")
            }
        }
    }
}
