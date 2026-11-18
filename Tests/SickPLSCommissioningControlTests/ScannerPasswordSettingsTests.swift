import XCTest
@testable import SickPLSCommissioningControl

/// Das Scanner-Passwort als **gewöhnliche Einstellung** (SICK-032a2).
///
/// Alle Nachweise laufen gegen ``FakeScannerPasswordStore`` — die echten
/// `UserDefaults` des Benutzers werden **nicht** angefasst.
final class ScannerPasswordSettingsTests: XCTestCase {

    // MARK: - Tauglichkeit

    func testAnEmptyEntryIsNotSet() {
        XCTAssertEqual(ScannerPasswordSettingsModel.usability(of: ""), .notSet)
    }

    func testAnEntryOfTheWrongShapeIsUnusable() {
        XCTAssertEqual(ScannerPasswordSettingsModel.usability(of: "ZUKURZ"), .unusable)
        XCTAssertEqual(ScannerPasswordSettingsModel.usability(of: "VIELZULANGERWERT"), .unusable)
    }

    func testAnEntryOfTheExpectedShapeIsUsable() {
        XCTAssertEqual(ScannerPasswordSettingsModel.usability(of: fabricatedSecretText), .usable)
    }

    /// **Eine einzige Vorstellung davon, was gültig ist.** Die
    /// Einstellungsseite prüft nicht selbst, sondern fragt denselben Typ,
    /// den auch der Ablauf benutzt.
    func testUsabilityFollowsTheSameRuleAsTheCommissioningValue() {
        for text in ["", "A", "TESTWERT", "ZUKURZ", "ACHTZEHN123456789"] {
            let expected: ScannerPasswordUsability
            if text.isEmpty {
                expected = .notSet
            } else {
                expected = text.utf8.count == 8 ? .usable : .unusable
            }
            XCTAssertEqual(ScannerPasswordSettingsModel.usability(of: text), expected, "bei \(text.count) Zeichen")
        }
    }

    // MARK: - Ablage

    func testAnEntryIsStoredImmediately() {
        let store = FakeScannerPasswordStore()
        let model = ScannerPasswordSettingsModel(store: store)

        model.password = fabricatedSecretText

        XCTAssertEqual(store.load(), fabricatedSecretText)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(model.usability, .usable)
    }

    /// **Kein Speichern ohne Änderung** — sonst schriebe jede Anzeige
    /// den Wert erneut.
    func testWritingTheSameValueAgainStoresNothing() {
        let store = FakeScannerPasswordStore(initial: fabricatedSecretText)
        let model = ScannerPasswordSettingsModel(store: store)

        model.password = fabricatedSecretText

        XCTAssertEqual(store.saveCount, 0)
    }

    func testAStoredEntryIsShownReadableOnOpening() {
        let store = FakeScannerPasswordStore(initial: fabricatedSecretText)
        let model = ScannerPasswordSettingsModel(store: store)

        // **Standardmäßig lesbar**, ohne zusätzlichen Handgriff.
        XCTAssertEqual(model.password, fabricatedSecretText)
    }

    func testForgettingClearsBothFieldAndStorage() {
        let store = FakeScannerPasswordStore(initial: fabricatedSecretText)
        let model = ScannerPasswordSettingsModel(store: store)

        model.forget()

        XCTAssertEqual(model.password, "")
        XCTAssertEqual(store.load(), "")
        XCTAssertEqual(store.forgetCount, 1)
        XCTAssertEqual(model.usability, .notSet)
    }

    /// Gegenrichtung zum `didSet`: Das Leeren des Feldes darf den
    /// gerade gelöschten Eintrag nicht als leeren Wert zurückschreiben.
    func testForgettingDoesNotWriteAnEmptyValueBack() {
        let store = FakeScannerPasswordStore(initial: fabricatedSecretText)
        let model = ScannerPasswordSettingsModel(store: store)

        model.forget()

        XCTAssertEqual(store.saveCount, 0, "Nach dem Löschen darf nichts geschrieben worden sein")
    }

    func testRefreshPicksUpAChangeMadeElsewhere() {
        let store = FakeScannerPasswordStore()
        let model = ScannerPasswordSettingsModel(store: store)
        store.save(fabricatedSecretText)

        model.refresh()

        XCTAssertEqual(model.password, fabricatedSecretText)
    }

    // MARK: - Hinweistexte

    /// **Die Texte entstehen im Modell**, nicht in der Ansicht (Regel aus
    /// SICK-028/030a1) — und sie nennen den Wert nicht.
    func testTheHintNamesTheSituationButNeverTheValue() {
        let store = FakeScannerPasswordStore()
        let model = ScannerPasswordSettingsModel(store: store)

        XCTAssertFalse(model.hint.isEmpty)
        model.password = "ZUKURZ"
        XCTAssertFalse(model.hint.contains("ZUKURZ"))
        XCTAssertFalse(model.hint.isEmpty)

        model.password = fabricatedSecretText
        XCTAssertFalse(model.hint.contains(fabricatedSecretText))
    }

    // MARK: - Die Einstellung ist keine Sonderbehandlung

    /// Der Wert ist **eine gewöhnliche Einstellung** (Owner-Korrektur zu
    /// SICK-032a2): Er wird im Klartext gehalten und ist ablesbar. Dieser
    /// Test hält die Entscheidung fest, damit niemand versehentlich
    /// wieder eine Maskierung einbaut und dabei die Bedienung bricht.
    func testTheValueIsHeldInPlainTextOnPurpose() {
        let store = FakeScannerPasswordStore(initial: fabricatedSecretText)
        let model = ScannerPasswordSettingsModel(store: store)

        XCTAssertEqual(model.password, fabricatedSecretText)
        XCTAssertEqual(store.load(), fabricatedSecretText)
    }
}
