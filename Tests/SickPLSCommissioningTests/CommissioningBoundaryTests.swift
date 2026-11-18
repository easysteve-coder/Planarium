import PlanariumInput
import XCTest
import Foundation
@testable import SickPLSCommissioning

/// Automatische Prüfung der Modulgrenze — nach dem Muster von
/// `RuntimeBoundaryTests` (SICK-025) und `PerformanceSessionBoundaryTests`
/// (SICK-029).
///
/// **Wer hier eine Abhängigkeit oder einen Import ergänzt, muss die
/// Listen unten bewusst mitpflegen, sonst schlägt `swift test` fehl.**
final class CommissioningBoundaryTests: XCTestCase {

    /// Genau die Module, die dieses Ziel importieren darf.
    ///
    /// **`Foundation` steht hier bewusst nicht**: Das Ziel ist
    /// frameworkfrei, bis hin zur eigenen Hex-Formatierung in
    /// ``CommissioningRedaction``.
    ///
    /// **`os` seit SICK-0330a-1:** einzig für `os_unfair_lock` in
    /// ``CommissioningAbortToken`` — die einzige macOS-12-taugliche,
    /// framework-freie Sperre (`Synchronization.Mutex`/`Atomic` verlangen
    /// macOS 15; `Dispatch`/`NSLock` sind über `forbiddenIdentifiers`
    /// unverändert verboten). Kein Zugang zu Dateien, Prozessen, Netzwerk
    /// oder Systemzeit -- nur die C-Sperrprimitive.
    private static let allowedImports: Set<String> = [
        "PLSDeviceValues",
        "SickPLSCore",
        "SickPLSMacTransport",
        "SickPLSActiveControl",
        "os"
    ]

    /// Was in diesem Modul **nirgends** stehen darf.
    ///
    /// Frameworks, Oberfläche, Nachbarmodule und jeder Weg an der einen
    /// TX-Grenze vorbei.
    private static let forbiddenIdentifiers = [
        "import Foundation",
        "SwiftUI",
        "AVFoundation",
        "CoreMIDI",
        "Dispatch",
        "RXSession",
        "SickPLSMonitorKit",
        "PlanariumPresets",
        "DarwinActiveControlSerialPort",
        "SickPLSSerialConnection",
        "RawDuplexSyscalls"
    ]

    /// Die **einzigen** Dateien, in denen echte Port-Ein-/Ausgabe stehen
    /// darf (SICK-031).
    ///
    /// Bis SICK-030a3 war I/O im ganzen Modul verboten — das war die
    /// Grenze eines Zuschnitts, nicht der Architektur: Der Reducer
    /// *sagte*, was zu tun wäre, und niemand tat es. SICK-031 baut die
    /// Ausführung, und statt das Verbot fallen zu lassen, wird es
    /// **verschärft**: `open`, `write` und die TX-Portgrenze dürfen nur
    /// noch an genau diesen zwei Stellen vorkommen.
    ///
    /// **Wer hier eine Datei ergänzt, öffnet einen zweiten I/O-Pfad.**
    /// Der Reducer, die Telegramme, das Audit, das Geheimnis und das
    /// Besitzmodell bleiben strukturell I/O-frei.
    private static let ioBoundaryFiles: Set<String> = [
        "ActiveControlCommissioningTransport.swift",
        "CommissioningTransport.swift"
    ]

    /// Was ausschließlich in ``ioBoundaryFiles`` stehen darf.
    ///
    /// `func write(` statt `.write(`: Der Executor **ruft** das Schreiben
    /// über die Protokollgrenze — genau dafür gibt es sie. Verboten ist,
    /// es irgendwo sonst zu **deklarieren** oder einen rohen Port
    /// anzufassen.
    private static let ioOnlyIdentifiers = [
        "ActiveControlSerialPort",
        "func write(",
        "open(atPath"
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
        for source in try swiftSources(in: CommissioningSourcePaths.sources) {
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
        for source in try swiftSources(in: CommissioningSourcePaths.sources) {
            let code = codeOnly(source.text)
            for identifier in Self.forbiddenIdentifiers {
                XCTAssertFalse(
                    code.contains(identifier),
                    "\(source.name) nennt \(identifier) -- außerhalb der Modulgrenze"
                )
            }
        }
    }

    /// **Echte Ein-/Ausgabe steht an genau zwei Stellen** (SICK-031).
    ///
    /// Gegenrichtung zum Verbot oben: Der Reducer, die Telegramme, das
    /// Audit, das Geheimnis und das Besitzmodell dürfen keinen Port
    /// anfassen — auch nicht „nur einmal kurz".
    func testPortInputAndOutputLiveInExactlyTheTwoBoundaryFiles() throws {
        var filesNamingIO: Set<String> = []
        for source in try swiftSources(in: CommissioningSourcePaths.sources) {
            let code = codeOnly(source.text)
            for identifier in Self.ioOnlyIdentifiers where code.contains(identifier) {
                filesNamingIO.insert(source.name)
                XCTAssertTrue(
                    Self.ioBoundaryFiles.contains(source.name),
                    "\(source.name) nennt \(identifier) -- echte Ein-/Ausgabe gehört ausschließlich in \(Self.ioBoundaryFiles.sorted().joined(separator: ", "))"
                )
            }
        }
        XCTAssertFalse(
            filesNamingIO.isEmpty,
            "Die Prüfung liefe ins Leere, wenn gar keine Datei mehr I/O nennt"
        )
    }

    /// Und der **Executor** selbst bleibt frei davon: Er steuert über die
    /// Protokollgrenze, nie an ihr vorbei.
    func testTheExecutorNeverTouchesAPortDirectly() throws {
        let executor = try String(
            contentsOf: CommissioningSourcePaths.sources.appendingPathComponent("CommissioningExecutor.swift"),
            encoding: .utf8
        )
        let code = codeOnly(executor)
        for forbidden in ["ActiveControlSerialPort", "open(atPath", "opener"] {
            XCTAssertFalse(code.contains(forbidden), "Der Executor nennt \(forbidden)")
        }
    }

    func testThePackageManifestDeclaresExactlyTheseDependencies() throws {
        let manifest = try String(
            contentsOf: CommissioningSourcePaths.packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        guard let range = manifest.range(
            of: "name: \"SickPLSCommissioning\",\n            dependencies:"
        ) else {
            return XCTFail("Zielbeschreibung im Manifest nicht gefunden")
        }
        let section = String(manifest[range.lowerBound...].prefix(400))
        for dependency in ["PLSDeviceValues", "SickPLSCore", "SickPLSMacTransport", "SickPLSActiveControl"] {
            XCTAssertTrue(section.contains("\"\(dependency)\""), "\(dependency) fehlt")
        }
        for forbidden in ["SickPLSMonitorKit", "PlanariumPresets", "SickThereminPerformance"] {
            XCTAssertFalse(section.contains("\"\(forbidden)\""), "\(forbidden) gehört nicht in dieses Ziel")
        }
    }

    /// **Der RX-Monitor bleibt RX-only** (harte Grenze des Auftrags).
    /// Dieser Slice hat `SickPLSMacTransport` angefasst? Nein — und das
    /// wird hier geprüft, statt es zu behaupten.
    func testTheReadOnlyTransportStillHasNoWritePath() throws {
        let transport = CommissioningSourcePaths.packageRoot
            .appendingPathComponent("Sources/SickPLSMacTransport")
        for source in try swiftSources(in: transport) {
            let code = codeOnly(source.text)
            for forbidden in ["func write(", "O_RDWR", "O_WRONLY"] {
                XCTAssertFalse(code.contains(forbidden), "\(source.name) nennt \(forbidden)")
            }
        }
    }
}
