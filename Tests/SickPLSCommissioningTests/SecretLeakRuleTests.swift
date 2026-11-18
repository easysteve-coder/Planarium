import XCTest
import Foundation

/// **Auflage A5, automatisiert** (SICK-030a, Befund N1 aus
/// `review-sick-030-architecture.md`).
///
/// ## Das Problem
///
/// Die technische Dokumentation unter `SICK Doku/integration/` nennt das
/// Installationsgeheimnis **im Klartext** — als Text und als Bytefolge.
/// Beim Bauen eines Login-Encoders ist die Versuchung groß, es „nur für
/// den einen Test" zu übernehmen. Danach steht es dauerhaft im Repository,
/// in der Historie und in jedem Handoff.
///
/// ## Die Lösung — und warum sie keinen zweiten Fundort erzeugt
///
/// Dieser Test darf den Wert selbst **nicht** enthalten; sonst wäre er
/// der Leck-Fund, den er verhindern soll. Er liest den Suchbegriff
/// deshalb **zur Laufzeit aus der Dokumentation** — aus genau der Zeile,
/// die das Geheimnisfeld beschreibt — und prüft damit `Sources/` und
/// `Tests/`. Kein Quelltext des Projekts enthält den Wert, auch dieser
/// Test nicht; und wenn die Dokumentation morgen einen anderen Wert
/// nennt, sucht der Test von selbst nach dem anderen.
///
/// ## Er darf nicht still zum No-op werden
///
/// Lässt sich der Suchbegriff nicht ermitteln, **schlägt der Test fehl**
/// statt zu überspringen. Das ist die Lehre aus SICK-020b: Eine
/// Schutzregel, die bei fehlender Eingabe wortlos durchwinkt, ist keine.
final class SecretLeakRuleTests: XCTestCase {

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Die Zeile, aus der der Suchbegriff stammt, ist an ihrem
    /// Sachbegriff erkennbar — nicht an einer Zeilennummer.
    private static let documentationMarker = "Passwortfeld"

    private static let documentation = packageRoot
        .appendingPathComponent("SICK Doku/integration/active-sequences.md")

    /// Ermittelt Text- und Byteform des Geheimnisses aus der
    /// Dokumentation.
    private func secretNeedles() throws -> (text: String, bytes: [UInt8]) {
        // Die Herstellerunterlagen liegen nur lokal (nicht versioniert, nicht
        // veröffentlicht); ohne sie gibt es keine Nadel, gegen die geprüft wird.
        guard FileManager.default.fileExists(atPath: Self.documentation.path) else {
            throw XCTSkip("Lokale Herstellerunterlagen fehlen (SICK Doku/integration); Prüfung nur im privaten Arbeitsbaum")
        }
        let document = try String(contentsOf: Self.documentation, encoding: .utf8)
        guard let line = document
            .split(separator: "\n")
            .first(where: { $0.contains(Self.documentationMarker) })
        else {
            XCTFail("Zeile mit „\(Self.documentationMarker)“ nicht gefunden -- die Regel kann nicht prüfen")
            throw CocoaError(.fileReadCorruptFile)
        }

        // In Backticks gefasste Gruppe aus genau acht Hex-Paaren.
        let groups = String(line).components(separatedBy: "`")
        for group in groups {
            let tokens = group.split(separator: " ").map(String.init)
            guard tokens.count == 8 else { continue }
            let bytes = tokens.compactMap { UInt8($0, radix: 16) }
            guard bytes.count == 8 else { continue }
            let text = String(decoding: bytes, as: UTF8.self)
            return (text, bytes)
        }
        XCTFail("Keine Acht-Byte-Gruppe in der Geheimniszeile gefunden -- die Regel kann nicht prüfen")
        throw CocoaError(.fileReadCorruptFile)
    }

    private func swiftAndMarkdownFiles(under directory: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter {
            ["swift", "md", "h", "hpp", "m", "mm", "cpp"].contains($0.pathExtension)
        }
    }

    /// Jede Schreibweise, in der der Wert versehentlich landen könnte.
    ///
    /// ## Warum die Textform **abgegrenzt** gesucht wird
    ///
    /// Die Textform dieses Standardwerts ist zugleich ein ganz
    /// gewöhnlicher Bezeichnerbestandteil des BSD-lizenzierten
    /// CRC-Referenzcodes und taucht deshalb in `SickPLSCore` in
    /// Konstantennamen auf — völlig harmlos und seit SICK-003 dort.
    /// Eine nackte Textsuche wäre damit **dauerhaft rot**, und ein
    /// dauerhaft roter Test wird abgeschaltet, nicht gelesen.
    ///
    /// Gesucht wird die Textform deshalb nur **in Anführungszeichen,
    /// Backticks oder Apostrophen** — also genau dort, wo sie als
    /// *Wert* stünde statt als Namensbestandteil. Alle **Byteformen**
    /// werden dagegen ohne jede Abgrenzung gesucht: Sie haben keine
    /// harmlose Lesart.
    private func leakNeedles(text: String, bytes: [UInt8]) -> [String] {
        let spacedLower = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let packedLower = spacedLower.replacingOccurrences(of: " ", with: "")
        let swiftLiterals = bytes.map { "0x" + String(format: "%02X", $0) }.joined(separator: ", ")
        return [
            spacedLower, spacedLower.uppercased(),
            packedLower, packedLower.uppercased(),
            swiftLiterals,
            "\"\(text)\"", "`\(text)`", "'\(text)'"
        ]
    }

    /// **Der eigentliche Nachweis.**
    func testTheInstallationSecretAppearsNowhereInSourcesOrTests() throws {
        let (text, bytes) = try secretNeedles()
        XCTAssertEqual(bytes.count, 8, "Vorbedingung: acht Bytes")
        let needles = leakNeedles(text: text, bytes: bytes)

        var scanned = 0
        for directory in ["Sources", "Tests"] {
            for file in try swiftAndMarkdownFiles(under: Self.packageRoot.appendingPathComponent(directory)) {
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scanned += 1

                var contentToScan = content
                if file.lastPathComponent == "SetupConsoleModel.swift" {
                    // Owner-Ausnahme: ausschließlich diese eine Deklaration des
                    // veröffentlichten Standardwerts ist zulässig. Der Suchwert
                    // wird dynamisch eingesetzt, damit der Schutztest selbst
                    // keine zweite Klartextkopie enthält. Der restliche Inhalt
                    // derselben Datei wird weiterhin vollständig geprüft.
                    let authorizedDeclaration = "static let defaultPassword = \"" + text + "\""
                    let occurrenceCount = content.components(separatedBy: authorizedDeclaration).count - 1
                    XCTAssertEqual(
                        occurrenceCount,
                        1,
                        "Die Owner-Ausnahme muss genau einmal in SetupConsoleModel.swift vorkommen"
                    )
                    contentToScan = content.replacingOccurrences(
                        of: authorizedDeclaration,
                        with: "static let defaultPassword = \"[owner-approved-standard]\""
                    )
                }

                for needle in needles where !needle.isEmpty {
                    XCTAssertFalse(
                        contentToScan.contains(needle),
                        "Installationsgeheimnis in \(file.lastPathComponent) gefunden -- Auflage A5 verletzt"
                    )
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "Der Scan muss die Quellen wirklich erreicht haben")
    }

    // Owner-Entscheidung 12.10.2026: Der Scanner hat 0 % Sicherheitsrelevanz;
    // der öffentliche Standardwert darf in Projektdokumenten stehen
    // (`AGENTS.md` §1). Die frühere Dokumentenprüfung entfällt deshalb.

    /// Gegenrichtung: Die Regel muss auch **finden** können, was sie
    /// sucht. Ohne diesen Nachweis wäre ein grüner Lauf oben ebenso gut
    /// mit einer kaputten Suche vereinbar.
    ///
    /// Geprüft werden beide Leckformen, die real vorkämen: der Wert als
    /// Zeichenkettenliteral und der Wert als Bytefolge.
    func testTheRuleActuallyDetectsALeak() throws {
        let (text, bytes) = try secretNeedles()
        XCTAssertFalse(text.isEmpty)
        let needles = leakNeedles(text: text, bytes: bytes)

        let asALiteral = "let secret = \"\(text)\""
        let asSwiftBytes = "let secret: [UInt8] = ["
            + bytes.map { "0x" + String(format: "%02X", $0) }.joined(separator: ", ") + "]"
        let asSpacedHex = "// TX: " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")

        for fabricated in [asALiteral, asSwiftBytes, asSpacedHex] {
            XCTAssertTrue(
                needles.contains(where: { fabricated.contains($0) }),
                "Die Suche muss ein echtes Leck erkennen"
            )
        }

        // Und die harmlose Lesart darf sie **nicht** treffen -- sonst
        // wäre der Test dauerhaft rot und damit wertlos.
        let harmless = "/// (`\(text)_MSG_HEADER_LEN`)"
        XCTAssertFalse(
            needles.contains(where: { harmless.contains($0) }),
            "Der Namensbestandteil im CRC-Referenzcode ist kein Leck"
        )
    }


    // MARK: - Private Infrastrukturadressen (28.09.2026)

    /// Adressen der privaten Arbeitsinfrastruktur gehören nicht ins Archiv.
    ///
    /// Anlass: Der Modellserver für den Coder steht in einer unversionierten
    /// Einstellungsdatei. Beim Nachsehen fiel auf, dass der **Rechnername**
    /// über einen Rücklauf in eine Handoffdatei gewandert war -- nicht die
    /// vollständige Adresse, aber auf demselben Weg, auf dem sie gewandert
    /// wäre. Diese Regel schließt den Weg.
    ///
    /// Gesucht werden **Formen**, nicht der konkrete Name, damit der Test
    /// selbst nichts preisgibt: die Tailscale-Domäne und ein konkret
    /// gesetzter Modellendpunkt. Der Platzhalter in
    /// `aider.conf.yml.example` trifft bewusst keine der beiden Formen.
    private static let infrastructureNeedles = [
        ".ts.net",
        "OLLAMA_API_BASE=http"
    ]

    func testNoPrivateInfrastructureAddressAppearsAnywhere() throws {
        var scanned = 0
        var roots = [Self.packageRoot.appendingPathComponent("Sources"),
                     Self.packageRoot.appendingPathComponent("Tests"),
                     Self.packageRoot.appendingPathComponent(".agent_handoff")]
        roots.append(Self.packageRoot.appendingPathComponent("scripts"))

        for root in roots {
            for file in (try? swiftAndMarkdownFiles(under: root)) ?? [] {
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scanned += 1
                // Diese Datei erklärt die Regel und nennt die Formen
                // notwendigerweise selbst.
                if file.lastPathComponent == "SecretLeakRuleTests.swift" { continue }
                for needle in Self.infrastructureNeedles {
                    XCTAssertFalse(
                        content.contains(needle),
                        "Private Infrastrukturadresse in \(file.lastPathComponent) gefunden"
                    )
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "Der Scan muss die Dateien wirklich erreicht haben")
    }

    /// Gegenrichtung: Die Regel muss finden, was sie sucht -- und die
    /// harmlosen Lesarten **nicht** treffen. Ohne beides wäre ein grüner
    /// Lauf oben ebenso gut mit einer kaputten Suche vereinbar.
    func testTheInfrastructureRuleDetectsALeakAndSparesTheHarmless() {
        let fabricatedLeaks = [
            "OLLAMA_API_BASE=https://erfundener-name.example-tailnet.ts.net:8443",
            "  - OLLAMA_API_BASE=http://127.0.0.1:11434"
        ]
        for leak in fabricatedLeaks {
            XCTAssertTrue(
                Self.infrastructureNeedles.contains(where: { leak.contains($0) }),
                "Die Suche muss ein echtes Leck erkennen"
            )
        }

        let harmless = [
            "Der Modellserver läuft über Tailscale.",
            "  - OLLAMA_API_BASE=<lokale Serveradresse -- steht nur in der echten Datei>",
            "Die Adresse steht in der unversionierten .aider.conf.yml."
        ]
        for text in harmless {
            XCTAssertFalse(
                Self.infrastructureNeedles.contains(where: { text.contains($0) }),
                "Die harmlose Lesart darf die Regel nicht treffen"
            )
        }
    }
}
