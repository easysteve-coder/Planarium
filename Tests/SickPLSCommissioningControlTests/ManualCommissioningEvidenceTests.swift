import XCTest
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl

final class ManualCommissioningEvidenceTests: XCTestCase {
    func testExportContainsTimingAddressAndResultButNoPayloadOrSecret() {
        var model = CommissioningModel(recipe: .r26)
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000)
        model.apply(.identityOutcome(.identified), atMillis: 1_050)
        model.apply(.operatorRequestedSettingsMode(secretIsAvailable: true), atMillis: 8_000)
        model.apply(.acknowledgement(.acknowledged), atMillis: 8_100)

        let text = ManualCommissioningEvidenceExport.text(
            portPath: "/dev/cu.usbserial-TEST",
            phase: model.phase,
            entries: model.audit.entries
        )

        XCTAssertTrue(text.contains("+7000 ms"))
        XCTAssertTrue(text.contains("address 1"))
        XCTAssertTrue(text.contains("20 30"))
        XCTAssertTrue(text.contains("confirmed"))
        XCTAssertFalse(text.lowercased().contains("passwort"))
        XCTAssertFalse(text.contains("02 00"), "Der Export darf keine Rohtelegramme enthalten")
    }
}
