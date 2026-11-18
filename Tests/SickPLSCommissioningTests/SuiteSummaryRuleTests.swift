import XCTest

/// `scripts/suite-summary.sh` ist das Werkzeug, an dem jede Runde ihr
/// Ergebnis misst. Es war bis zum 28.09.2026 selbst ungeprüft und hat
/// einen **gescheiterten Testbau** als grünen Lauf gemeldet: ohne
/// übersetztes Testziel schreibt swift-test keine einzige
/// `Test Case`-Zeile, und die Zählung sah 0 bestanden, 0 rot, 0
/// abgestürzt.
///
/// Diese Regel fährt das Skript gegen feste Protokolle. Sie prüft den
/// Rückgabewert, weil daran die Runden hängen.
final class SuiteSummaryRuleTests: XCTestCase {

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func runAgainstFixture(_ name: String) throws -> (status: Int32, output: String) {
        let root = Self.packageRoot
        let script = root.appendingPathComponent("scripts/suite-summary.sh")
        let fixture = root.appendingPathComponent("Tests/fixtures/suite-summary/\(name).log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), "Skript fehlt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path), "Protokoll \(name) fehlt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--log", fixture.path]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testAGreenLogIsTheOnlySuccess() throws {
        let result = try runAgainstFixture("gruen")
        XCTAssertEqual(result.status, 0, "grün muss 0 liefern:\n\(result.output)")
        XCTAssertTrue(result.output.contains("rot:           0"), result.output)
    }

    func testARedLogFails() throws {
        let result = try runAgainstFixture("rot")
        XCTAssertEqual(result.status, 1, "rot muss 1 liefern:\n\(result.output)")
    }

    func testACrashedLogFailsAlthoughItWritesNoFailedLine() throws {
        let result = try runAgainstFixture("absturz")
        XCTAssertEqual(result.status, 1, "Absturz muss 1 liefern:\n\(result.output)")
        XCTAssertTrue(result.output.contains("rot:           0"), "Der Absturz schreibt keine rote Zeile -- genau darum zählt er eigens:\n\(result.output)")
        XCTAssertFalse(result.output.contains("abgestuerzt:   0"), result.output)
    }

    func testAFailedBuildIsNeverGreen() throws {
        let result = try runAgainstFixture("baufehler")
        XCTAssertEqual(result.status, 1, "Baufehler muss 1 liefern:\n\(result.output)")
        XCTAssertTrue(result.output.contains("bestanden:     0"), result.output)
        XCTAssertTrue(result.output.contains("rot:           0"), result.output)
        XCTAssertTrue(
            result.output.contains("KEIN LAUF") || result.output.contains("BAUFEHLER"),
            "Der Grund muss dastehen, nicht nur der Rückgabewert:\n\(result.output)"
        )
    }
}
