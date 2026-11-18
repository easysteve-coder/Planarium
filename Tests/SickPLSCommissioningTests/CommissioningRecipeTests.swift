import XCTest
import SickPLSActiveControl
import SickPLSMacTransport
@testable import SickPLSCommissioning

/// Das Rezept ist **geschlossen** (Auflage A4). Diese Tests belegen, was
/// es bindet — und dass es sich nicht öffnen lässt.
final class CommissioningRecipeTests: XCTestCase {

    func testTheOnlyRecipeBindsTheDocumentedCombination() {
        let recipe = CommissioningRecipe.r26
        XCTAssertEqual(recipe.startingBaudRate, .baud9600)
        XCTAssertEqual(recipe.targetBaudRate, .baud38400)
        let addressOne = ConfirmedTargetAddress(rawValue: 0x01)
        let addressZero = ConfirmedTargetAddress(rawValue: 0x00)
        XCTAssertEqual(recipe.configurationAddress, addressOne)
        XCTAssertEqual(recipe.verificationAddress, addressZero)
        XCTAssertEqual(recipe.settingsModeAddress, addressZero)
    }

    /// **Adresse und Modusbyte sind ein Paar.** Die andere belegte
    /// Login-Variante wird zwar quittiert, führt danach aber in jeder
    /// Beobachtung zur Ablehnung des Baudwechsels — ein Modell mit
    /// freier Auswahl ließe genau das einstellen.
    func testThereIsExactlyOneRecipeAndNoPublicInitialiser() throws {
        let source = try String(
            contentsOf: CommissioningSourcePaths.sources
                .appendingPathComponent("CommissioningRecipe.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("private init("), "Der Initialisierer muss privat bleiben")
        XCTAssertFalse(source.contains("public init("), "Kein öffentlicher Weg zu einer eigenen Kombination")
        // Genau ein vordefiniertes Rezept.
        let recipeCount = source.components(separatedBy: "public static let r26").count - 1
        XCTAssertEqual(recipeCount, 1)
        XCTAssertFalse(
            source.contains("public var configurationAddress: ConfirmedTargetAddress"),
            "Die gekoppelten Werte dürfen nicht schreibbar sein"
        )
    }

    /// Der geschlossene Standardablauf bleibt unverändert auf 9600/38400,
    /// obwohl das manuelle Entwicklungswerkzeug nun auch die real belegte
    /// RS-422-Rate 500000 öffnen kann.
    func testTransportRatesIncludeTheSeparatelyConfirmedRS422Rate() {
        XCTAssertEqual(SerialPortBaudRate.allCases.count, 3)
        XCTAssertEqual(Set(SerialPortBaudRate.allCases), [.baud9600, .baud38400, .baud500000])
        XCTAssertEqual(CommissioningRecipe.r26.startingBaudRate, .baud9600)
        XCTAssertEqual(CommissioningRecipe.r26.targetBaudRate, .baud38400)
    }

    /// **Auflage A2 als Zahl im Typ**, nicht nur als Satz im Kommentar.
    func testLoginRetryMatchesTheWindowsReferenceAndIsStructurallyCapped() {
        XCTAssertEqual(CommissioningRecipe.maximumLoginRetryCount, 2)
        XCTAssertEqual(CommissioningRecipe.r26.loginRetryCount, 2)
        XCTAssertEqual(CommissioningRecipe.r26.maximumLoginAttempts, 3)
        XCTAssertEqual(CommissioningRecipe.r26.loginResponseTimeoutMilliseconds, 2_000)
    }

    func testTheResponseDeadlineIsAnExplicitPositiveTotalBudget() {
        XCTAssertGreaterThan(CommissioningRecipe.r26.responseTimeoutMilliseconds, 0)
    }

    /// **SICK-0330a-0:** Die MMK-Stromfrist ist ein eigener, geschlossener
    /// Rezeptwert -- fest bei 3.000 ms, unabhängig vom übrigen
    /// 2-Sekunden-Fenster.
    func testTheMeasurementStreamDeadlineIsAnExplicitThreeSecondClosedBudget() {
        XCTAssertEqual(CommissioningRecipe.r26.measurementStreamTimeoutMilliseconds, 3_000)
        XCTAssertGreaterThan(CommissioningRecipe.r26.measurementStreamTimeoutMilliseconds, 0)
        XCTAssertNotEqual(
            CommissioningRecipe.r26.measurementStreamTimeoutMilliseconds,
            CommissioningRecipe.r26.responseTimeoutMilliseconds,
            "Eine eigene Frist, kein Alias des allgemeinen Fensters"
        )
    }

    /// **C7/C10-Gegenprobe:** Einstellungsmodus (20 30) muss Universaladresse
    /// 0x00 verwenden. Falls er wieder an die Geräteadresse 0x01 gekoppelt wird,
    /// scheitert diese Assertion und zeigt den Regress an.
    func testSettingsModeAddressIsFixedToUniversalAddressZero() {
        let addressZero = ConfirmedTargetAddress(rawValue: 0x00)
        XCTAssertEqual(
            CommissioningRecipe.r26.settingsModeAddress,
            addressZero,
            "Einstellungsmodus muss auf 0x00 festgelegt bleiben (C7/C10)."
        )
    }

    /// **C7-Gegenprobe:** Verifikationsschritt nach Baudwechsel muss
    /// Universaladresse 0x00 verwenden.
    func testVerificationAddressIsFixedToUniversalAddressZero() {
        let addressZero = ConfirmedTargetAddress(rawValue: 0x00)
        XCTAssertEqual(
            CommissioningRecipe.r26.verificationAddress,
            addressZero,
            "Verifikation muss auf 0x00 festgelegt bleiben (C7)."
        )
    }
}

/// Die Pfade, die mehrere Quelltextprüfungen brauchen.
enum CommissioningSourcePaths {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SickPLSCommissioningTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Paketwurzel

    static let sources = packageRoot.appendingPathComponent("Sources/SickPLSCommissioning")
    static let allSources = packageRoot.appendingPathComponent("Sources")
    static let allTests = packageRoot.appendingPathComponent("Tests")
}
