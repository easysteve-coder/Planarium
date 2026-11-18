import XCTest
import SickPLSMacTransport
import SickPLSActiveControl
@testable import SickPLSDiagnosticCLI

final class ProbeReportingTests: XCTestCase {

    func testPreviewNamesTargetPortAndAllCandidateRates() {
        let text = describeProbePreview(portPath: "/dev/cu.usbserial-A1", targetAddress: .universal, candidates: BaudProbe.candidates)
        XCTAssertTrue(text.contains("/dev/cu.usbserial-A1"))
        XCTAssertTrue(text.contains("9600"))
        XCTAssertTrue(text.contains("38400"))
        XCTAssertTrue(text.contains("universal address"))
    }

    func testPreviewForNonUniversalAddressDoesNotClaimUniversal() {
        let address = ConfirmedTargetAddress(rawValue: 5)!
        let text = describeProbePreview(portPath: "/dev/cu.usbserial-A1", targetAddress: address, candidates: BaudProbe.candidates)
        XCTAssertTrue(text.contains("Target address 5"))
        XCTAssertFalse(text.contains("universal address"))
    }

    func testDescribeIdentifiedOutcome() {
        XCTAssertTrue(describe(IdentityProbeOutcome.identified).contains("identified"))
    }

    func testDescribeTimeoutOutcome() {
        XCTAssertTrue(describe(IdentityProbeOutcome.timeout).contains("timeout"))
    }

    func testDescribeUnexpectedResponseOutcomeNamesCommandByteOnly() {
        let text = describe(IdentityProbeOutcome.unexpectedResponse(commandByte: 0xA0))
        XCTAssertTrue(text.contains("0xA0"))
        XCTAssertFalse(text.contains("identified"))
    }

    func testDescribeAmbiguousOutcome() {
        XCTAssertTrue(describe(IdentityProbeOutcome.ambiguous).contains("ambiguous"))
    }

    func testDescribeAttemptNeverLeaksAnythingBeyondBaudAddressAndOutcome() {
        let attempt = IdentityProbeAttempt(baudRate: .baud9600, targetAddress: 0, outcome: .identified)
        let text = describe(attempt)
        XCTAssertTrue(text.contains("9600"))
        XCTAssertTrue(text.contains("identified"))
    }

    func testDescribeAuditLogReportsIdentifiedBaudRate() {
        let log = IdentityProbeAuditLog(attempts: [
            IdentityProbeAttempt(baudRate: .baud9600, targetAddress: 0, outcome: .timeout),
            IdentityProbeAttempt(baudRate: .baud38400, targetAddress: 0, outcome: .identified),
        ])
        XCTAssertTrue(describe(log).contains("38400"))
    }

    func testDescribeAuditLogReportsNoIdentificationWhenNoneSucceeded() {
        let log = IdentityProbeAuditLog(attempts: [
            IdentityProbeAttempt(baudRate: .baud9600, targetAddress: 0, outcome: .timeout),
            IdentityProbeAttempt(baudRate: .baud38400, targetAddress: 0, outcome: .timeout),
        ])
        XCTAssertFalse(describe(log).contains("9600"))
        XCTAssertFalse(describe(log).contains("38400"))
    }
}
