// AudioUnitProcessModeRuleTests.swift
//
// SICK-020b: der **projektweite Regressionsschutz** für die
// Prozessmodus-Regel der AU-Instanziierung.
//
// ## Die Regel (aus SICK-020a, verbindlich)
//
// `SystemAudioUnitInstantiation.instantiationOptions` ist `[]` — die
// bewusste Wahl **des Systemstandards**:
//
// - **Der Prozessmodus wird nicht zugesagt.** Laut
//   `AudioToolbox/AudioComponent.h` werden die meisten Komponenten in
//   den aufrufenden Prozess geladen, eine **AUv3** dagegen kann in
//   einen eigenen Extension-Service-Prozess geladen werden, und das ist
//   dort das Standardverhalten.
// - `.loadOutOfProcess` und `.loadInProcess` sind **nur Anfragen** und
//   können auf den Standard zurückfallen.
// - **Aus dem Ladeort folgt keine vollständige Fehlerisolation.**
//
// ## Warum das ein Test ist und kein Kommentar
//
// Der falsche Wortlaut („wir laden im eigenen Prozess") stand nach
// SICK-020 in sechs Dateien und hat SICK-020a überlebt, weil er in
// zusammenfassenden und historischen Abschnitten weiterlief. Ein
// Hinweis „bitte daran denken" hätte denselben Ausgang. Diese Prüfung
// liest die Dateien und schlägt fehl, wenn die Aussage zurückkehrt.
//
// ## Wie geprüft wird
//
// - **Quellen** (`Sources/PlanariumAudio/`, alle `.swift`): harte
//   Sperre, **keine Ausnahme**. Quelltext trägt keine Historie.
// - **Maßgebliche Dokumente**: eine Fundstelle ist nur zulässig, wenn
//   dieselbe Zeile **`SICK-020a`** nennt. Damit bleibt der alte
//   Wortlaut zitierbar — aber nur ausdrücklich als das, was er ist:
//   korrigierte Historie. Genau diese Markierung verlangt der
//   SICK-020b-Auftrag.
// - Zusätzlich eine **positive** Prüfung: die maßgebliche Quelle muss
//   die Regel weiterhin tragen. Sonst ließe sich der Test bestehen,
//   indem man die Begründung einfach löscht.
//
// Handoff-Dateien (`latest_claude.md`/`latest_codex.md`) sind bewusst
// **nicht** dabei: sie sind Rundenprotokolle, die jede Runde
// überschrieben werden, und keine maßgebliche Dokumentation. Der
// dauerhafte Projektstand steht im Checkpoint, der geprüft wird.

import XCTest

final class AudioUnitProcessModeRuleTests: XCTestCase {

    // MARK: - Was verboten ist

    /// Formulierungen, die einen Prozessmodus **zusagen**.
    ///
    /// Bewusst eng gefasst auf genau die Wendungen, mit denen eine
    /// Zusage gemacht wird. Erlaubt bleiben damit die korrekten
    /// Beschreibungen, die es geben muss — etwa Apples Aussage „die
    /// meisten Komponenten werden **in den aufrufenden Prozess**
    /// geladen" oder „auch wo eine Komponente **in einem eigenen
    /// Prozess** läuft, …". Der Test soll die falsche Zusage fangen,
    /// nicht jede Erwähnung des Wortes „Prozess" verbieten.
    private static let forbiddenPhrases = [
        "in unseren prozess",
        "in unserem prozess",
        "in unseren eigenen prozess",
        "in den eigenen prozess",
        "im eigenen prozess"
    ]

    /// Diese Marke macht eine Fundstelle in einem Dokument zulässig:
    /// sie weist die Zeile als korrigierte Historie aus.
    private static let correctionMarker = "SICK-020a"

    /// Begriffe, welche die maßgebliche Quelle weiterhin tragen muss.
    private static let requiredRuleTerms = [
        "Systemstandard",
        "nur Anfragen",
        "AUv3",
        "Fehlerisolation"
    ]

    // MARK: - Pfade

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/SickSynthAudioTests/<diese Datei>
            .deletingLastPathComponent()          // …/Tests/SickSynthAudioTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // Paketwurzel
    }

    private static var audioSourceDirectory: URL {
        repositoryRoot.appendingPathComponent("Sources/PlanariumAudio")
    }

    /// Die maßgeblichen Dokumente. Ein Dokument, das es (noch) nicht
    /// gibt, wird übersprungen statt zu einem Fehlschlag zu führen —
    /// der Test soll die Regel sichern, nicht die Dateiliste einfrieren.
    private static let documentPaths = [
        "ROADMAP.md",
        "README.md",
        "CHANGELOG.md",
        "CLAUDE.md",
        ".agent_handoff/checkpoint.md"
    ]

    private func lines(of url: URL) throws -> [(number: Int, text: String)] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content
            .components(separatedBy: .newlines)
            .enumerated()
            .map { (number: $0.offset + 1, text: $0.element) }
    }

    private func offendingLines(
        in url: URL,
        allowMarkedHistory: Bool
    ) throws -> [String] {
        try lines(of: url).compactMap { line in
            let lowered = line.text.lowercased()
            guard Self.forbiddenPhrases.contains(where: { lowered.contains($0) }) else {
                return nil
            }
            if allowMarkedHistory, line.text.contains(Self.correctionMarker) {
                return nil  // ausdrücklich als korrigierte Historie markiert
            }
            let name = url.lastPathComponent
            return "\(name):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))"
        }
    }

    // MARK: - Die Prüfungen

    /// Im Quelltext gibt es die Prozesszusage nirgends — ohne Ausnahme.
    func testNoAudioSourceFileClaimsAProcessMode() throws {
        let directory = Self.audioSourceDirectory
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let swiftFiles = contents.filter { $0.pathExtension == "swift" }

        XCTAssertFalse(
            swiftFiles.isEmpty,
            "keine Quelldateien unter \(directory.path) gefunden — der Test prüft sonst nichts"
        )

        var offenders: [String] = []
        for file in swiftFiles {
            offenders += try offendingLines(in: file, allowMarkedHistory: false)
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Prozessmodus-Zusage im Quelltext (verboten seit SICK-020a):
            \(offenders.joined(separator: "\n"))

            `options: []` ist der Systemstandard. Wo eine Komponente landet,
            entscheiden Komponententyp und System — das wird nicht zugesagt.
            """
        )
    }

    /// In den maßgeblichen Dokumenten nur noch als markierte Historie.
    func testNoAuthoritativeDocumentClaimsAProcessModeUnlessMarkedAsCorrectedHistory() throws {
        var checkedFiles = 0
        var offenders: [String] = []

        for relativePath in Self.documentPaths {
            let url = Self.repositoryRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            checkedFiles += 1
            offenders += try offendingLines(in: url, allowMarkedHistory: true)
        }

        XCTAssertGreaterThan(checkedFiles, 0, "kein maßgebliches Dokument gefunden")
        XCTAssertTrue(
            offenders.isEmpty,
            """
            Unmarkierte Prozessmodus-Zusage in maßgeblicher Dokumentation
            (verboten seit SICK-020a):
            \(offenders.joined(separator: "\n"))

            Entweder prozessneutral umformulieren, oder — wenn die Zeile
            ausdrücklich den korrigierten alten Wortlaut zitiert — in
            derselben Zeile „\(Self.correctionMarker)" nennen.
            """
        )
    }

    /// Die Regel darf nicht einfach gelöscht werden.
    ///
    /// Ohne diese Prüfung ließe sich der Test bestehen, indem man die
    /// ganze Begründung aus der maßgeblichen Quelle entfernt — die
    /// falsche Zusage wäre dann zwar weg, die richtige Aussage aber
    /// auch.
    ///
    /// **Geprüft wird ausdrücklich nur der Dateikopf** (alles vor dem
    /// ersten `import`), nicht die ganze Datei. Eine Suche über den
    /// gesamten Text wäre wirkungslos: dieselben Begriffe stehen auch
    /// in der Dokumentation der Optionskonstante, sodass eine
    /// verfälschte Begründung im Kopf unbemerkt bliebe. Das ist beim
    /// Gegenprobieren aufgefallen und hier bewusst enger gefasst.
    func testTheAuthoritativeSourceHeaderStillCarriesTheRule() throws {
        let url = Self.audioSourceDirectory
            .appendingPathComponent("SystemPluginSource.swift")
        let content = try String(contentsOf: url, encoding: .utf8)

        guard let importRange = content.range(of: "\nimport ") else {
            return XCTFail("kein `import` gefunden — Dateikopf nicht abgrenzbar")
        }
        let header = String(content[content.startIndex..<importRange.lowerBound])

        for term in Self.requiredRuleTerms {
            XCTAssertTrue(
                header.contains(term),
                "„\(term)\" fehlt im Kopfkommentar von SystemPluginSource.swift — "
                    + "die SICK-020a-Regel muss dort begründet stehen bleiben"
            )
        }
    }

    /// Auch die Optionskonstante selbst muss weiterhin sagen, was `[]`
    /// bedeutet — sie ist die Stelle, die beim Lesen des Codes zuerst
    /// auffällt.
    func testTheOptionsConstantIsDocumentedAsTheSystemDefault() throws {
        let url = Self.audioSourceDirectory
            .appendingPathComponent("SystemPluginSource.swift")
        let content = try String(contentsOf: url, encoding: .utf8)

        guard let declaration = content.range(of: "public static let instantiationOptions") else {
            return XCTFail("`instantiationOptions` nicht gefunden")
        }
        let documentation = String(content[content.startIndex..<declaration.lowerBound].suffix(700))

        XCTAssertTrue(
            documentation.contains("Systemstandard"),
            "die Doku der Optionskonstante muss `[]` als Systemstandard ausweisen"
        )
    }
}
