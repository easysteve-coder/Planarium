import Foundation
import XCTest
@testable import SickPLSCommissioningControl

/// Quelltextgrenze für die reine Verbindungspolitik (SICK-0330r,
/// Pflichtnachweis 7).
///
/// Ergänzt die bereits bestehende, modulweite
/// `CommissioningControlBoundaryTests` (die `ConnectionPolicy.swift` als
/// Teil von `Sources/SickPLSCommissioningControl` automatisch mitprüft)
/// um eine **eigens auf diese eine Datei benannte** Prüfung, damit der
/// geforderte Nachweis nicht nur implizit mitläuft, sondern direkt und
/// unübersehbar an der Datei hängt.
final class ConnectionPolicyBoundaryTests: XCTestCase {

    private static let file = "ConnectionPolicy.swift"

    private var source: String {
        get throws {
            let url = ControlSourcePaths.sources.appendingPathComponent(Self.file)
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Kein Port, kein Dateideskriptor, kein Schreiben, keine Uhr, kein
    /// Timer, keine Nebenläufigkeit, kein SwiftUI -- der Reducer ist ein
    /// reiner Wert.
    func testTheReducerTouchesNoPortNoFileDescriptorNoWriteNoTimerNoSwiftUI() throws {
        let code = codeOnly(try source)
        let forbidden = [
            // Dateideskriptor-/Syscall-Ebene.
            "FileDescriptor", "O_RDONLY", "O_RDWR", "O_WRONLY", "O_NONBLOCK",
            "poll(", "read(", "write(", "close(", "open(atPath",
            // Reale Transport-/Serielle Typen -- ein reines
            // Entscheidungsmodell referenziert nie eine echte
            // Portverbindung.
            "SerialPortFileDescriptor", "SerialPortOpener", "ActiveControlSerialPort",
            "DarwinSerialPort", "DarwinActiveControlSerialPort",
            // Uhr/Timer/Nebenläufigkeit -- keine echte
            // Frist-/Uhrimplementierung (Abschnitt "Bewusst nicht
            // enthalten").
            "Timer(", "Timer.scheduled", "asyncAfter", "sleep(", "Date()", "Date(",
            "ProcessInfo", "clock_gettime", "DispatchQueue", "Thread(",
            // Oberfläche -- der Reducer komponiert kein Pixel.
            "SwiftUI", "AVFoundation", "CoreMIDI"
        ]
        for identifier in forbidden {
            XCTAssertFalse(
                code.contains(identifier),
                "\(Self.file) nennt \(identifier) -- außerhalb der Reducer-Grenze"
            )
        }
    }

    /// Abschnitt 4: "Alle produktiven `switch`-Entscheidungen über die
    /// geschlossenen Zustands-, Ereignis- und Ergebnisräume stehen ohne
    /// `default`."
    func testNoSwitchInTheReducerFileUsesDefault() throws {
        let code = codeOnly(try source)
        XCTAssertFalse(
            code.contains("default:") || code.contains("default :"),
            "\(Self.file) enthält ein `default` -- jede Fallunterscheidung muss vollständig sein"
        )
    }

    /// Die Datei importiert ausschließlich, was sie für die geschlossenen
    /// Werttypen tatsächlich braucht -- nichts, das I/O oder Zeit
    /// hereinträgt.
    func testTheReducerFileImportsOnlyValueTypeSources() throws {
        let text = try source
        let allowed: Set<String> = ["SickPLSActiveControl", "SickPLSMacTransport"]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("import ") else { continue }
            let module = trimmed.dropFirst("import ".count).split(separator: " ").first.map(String.init) ?? ""
            XCTAssertTrue(allowed.contains(module), "\(Self.file) importiert \(module)")
        }
    }

    /// SICK-0330r-K1, Pflichtnachweis 5 (H4): Die drei früheren
    /// `String`-Nutzlasten von Portöffnung, Verbindungsverlust und
    /// Portschluss sind ersatzlos entfernt -- ``ConnectionPolicyEvent``
    /// und ``ConnectionPolicyFailure`` lassen sich für diese drei Fälle
    /// nur noch mit der geschlossenen ``ConnectionPolicyIOFailure``
    /// bauen. Diese Grenze sucht ausschließlich im produktiven Quelltext
    /// (Kommentare/Dokumentation entfernt), damit ein erklärender
    /// Kommentar über den alten Zustand die Prüfung nicht auslöst.
    func testTheThreeFormerStringPayloadsAreGoneAndNoRawByteOrPayloadTypeReplacesThem() throws {
        let code = codeOnly(try source)
        let forbiddenSignatures = [
            "portOpenFailed(String", "connectionLost(String", "portCloseFailed(String",
            // Keine rohen Bytes/Fehlercodes/Payloads dürfen an ihre
            // Stelle treten.
            "portOpenFailed(UInt8", "connectionLost(UInt8", "portCloseFailed(UInt8",
            "portOpenFailed(Int", "connectionLost(Int", "portCloseFailed(Int",
            "portOpenFailed(Data", "connectionLost(Data", "portCloseFailed(Data",
            "portOpenFailed([UInt8]", "connectionLost([UInt8]", "portCloseFailed([UInt8]"
        ]
        for signature in forbiddenSignatures {
            XCTAssertFalse(
                code.contains(signature),
                "\(Self.file) trägt \(signature) -- nur ConnectionPolicyIOFailure ist erlaubt"
            )
        }
    }

    /// SICK-0330r-K2, Pflichtnachweis (K2-2): "Eine Quelltextgrenze
    /// verhindert `UInt8`, `commandByte`, Byte-Arrays und `Data` in
    /// `ConnectionPolicyIdentityGap`." Die Prüfung ist auf den
    /// Deklarationsblock des Typs eingegrenzt (produktiver Quelltext
    /// ohne Kommentare), damit ein erklärender Kommentar über den
    /// vorherigen Zustand an anderer Stelle der Datei die Prüfung nicht
    /// auslöst.
    func testConnectionPolicyIdentityGapCarriesNoRawByteOrPayload() throws {
        let code = codeOnly(try source)
        guard let start = code.range(of: "enum ConnectionPolicyIdentityGap"),
              let end = code.range(of: "\n}", range: start.upperBound..<code.endIndex)
        else {
            XCTFail("Konnte den Deklarationsblock von ConnectionPolicyIdentityGap nicht finden")
            return
        }
        let block = String(code[start.lowerBound..<end.upperBound])
        let forbidden = ["UInt8", "commandByte", "[UInt8]", "Data"]
        for identifier in forbidden {
            XCTAssertFalse(
                block.contains(identifier),
                "ConnectionPolicyIdentityGap trägt \(identifier) -- die Identitätslücke muss an der Policy-Grenze datenfrei sein"
            )
        }
    }
}
