import XCTest
@testable import SickPLSCommissioning
import SickPLSMacTransport

/// Der händische Geräteweg bleibt nach jedem bestätigten Telegramm
/// stehen. Diese Tests verwenden nur den Reducer; kein Port und kein TX.
final class ManualCommissioningModelTests: XCTestCase {

    func testEveryManualStageStopsUntilTheNextOperatorCommand() {
        var model = CommissioningModel(recipe: .r26)

        XCTAssertEqual(
            model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000),
            .sendIdentityProbe(address: 1, deadlineMillis: 3_000)
        )
        XCTAssertEqual(model.apply(.identityOutcome(.identified), atMillis: 1_100), .hold)
        XCTAssertEqual(model.phase, .respondingAtStartingRate)

        XCTAssertEqual(
            model.apply(.operatorRequestedSettingsMode(secretIsAvailable: true), atMillis: 10_000),
            .sendSettingsMode(deadlineMillis: 12_000)
        )
        XCTAssertEqual(model.apply(.acknowledgement(.acknowledged), atMillis: 10_100), .hold)
        XCTAssertEqual(model.phase, .settingsModeEntered)

        XCTAssertEqual(
            model.apply(.operatorRequestedLogin(secretIsAvailable: true), atMillis: 25_000),
            .sendLogin(attempt: 1, deadlineMillis: 27_000)
        )
        XCTAssertEqual(model.apply(.acknowledgement(.acknowledged), atMillis: 25_100), .hold)
        XCTAssertEqual(model.phase, .loggedIn)

        XCTAssertEqual(
            model.apply(.operatorRequestedTargetBaudRate, atMillis: 35_000),
            .sendBaudSwitch(deadlineMillis: 37_000)
        )
        XCTAssertEqual(model.apply(.acknowledgement(.acknowledged), atMillis: 35_100), .hold)
        XCTAssertEqual(model.phase, .baudSwitchAcknowledged)

        XCTAssertEqual(model.apply(.operatorRequestedTargetRateConnection, atMillis: 45_000), .closePort)
        XCTAssertEqual(model.apply(.portClosed, atMillis: 45_100), .openPort(.baud38400))
        XCTAssertEqual(
            model.apply(.portOpened(.baud38400), atMillis: 45_200),
            .sendIdentityProbe(address: 0, deadlineMillis: 47_200)
        )
        XCTAssertEqual(model.apply(.identityOutcome(.identified), atMillis: 45_300), .hold)
        XCTAssertEqual(model.phase, .verified)

        XCTAssertEqual(model.audit.entries.map(\.targetAddress), [1, 0, 1, 1, 0])
        XCTAssertEqual(
            model.audit.entries.map(\.action),
            [
                .identityCheck(.baud9600), .settingsMode, .login,
                .baudSwitchRequest, .verification(.baud38400)
            ]
        )
        XCTAssertEqual(model.audit.entries.map(\.monotonicMillis), [1_000, 10_000, 25_000, 35_000, 45_200])
    }

    func testManualLoginTimeoutNeverRetriesWithoutAnotherClick() {
        var model = Self.settingsModeEntered()

        XCTAssertEqual(
            model.apply(.operatorRequestedLogin(secretIsAvailable: true), atMillis: 100),
            .sendLogin(attempt: 1, deadlineMillis: 2_100)
        )
        XCTAssertEqual(model.apply(.deadlineReached, atMillis: 2_100), .hold)
        XCTAssertEqual(model.phase, .settingsModeEntered)
        XCTAssertEqual(model.audit.entries.filter { $0.action == .login }.count, 1)

        XCTAssertEqual(
            model.apply(.operatorRequestedLogin(secretIsAvailable: true), atMillis: 9_000),
            .sendLogin(attempt: 2, deadlineMillis: 11_000)
        )
        XCTAssertEqual(model.audit.entries.filter { $0.action == .login }.count, 2)
    }

    func testManualSettingsAndBaudAcknowledgementsDoNotChainIO() {
        var model = Self.respondingAtStartingRate()
        model.apply(.operatorRequestedSettingsMode(secretIsAvailable: true), atMillis: 100)
        XCTAssertEqual(model.apply(.acknowledgement(.acknowledged), atMillis: 110), .hold)
        XCTAssertEqual(model.audit.entries.count, 2, "Die Anmeldung darf nicht automatisch folgen")

        model.apply(.operatorRequestedLogin(secretIsAvailable: true), atMillis: 200)
        model.apply(.acknowledgement(.acknowledged), atMillis: 210)
        model.apply(.operatorRequestedTargetBaudRate, atMillis: 300)
        XCTAssertEqual(model.apply(.acknowledgement(.acknowledged), atMillis: 310), .hold)
        XCTAssertEqual(model.phase, .baudSwitchAcknowledged)
        XCTAssertEqual(model.audit.entries.count, 4, "Die Port-Neuöffnung darf nicht automatisch folgen")
    }

    private static func respondingAtStartingRate() -> CommissioningModel {
        var model = CommissioningModel(recipe: .r26)
        model.apply(.operatorRequestedStartingRateCheck, atMillis: 0)
        model.apply(.identityOutcome(.identified), atMillis: 10)
        return model
    }

    private static func settingsModeEntered() -> CommissioningModel {
        var model = respondingAtStartingRate()
        model.apply(.operatorRequestedSettingsMode(secretIsAvailable: true), atMillis: 20)
        model.apply(.acknowledgement(.acknowledged), atMillis: 30)
        return model
    }
}
