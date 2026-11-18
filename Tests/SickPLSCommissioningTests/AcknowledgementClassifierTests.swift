import XCTest
import SickPLSCore
@testable import SickPLSCommissioning

/// Jede Antwortklasse einzeln — **besonders die, die niemals Erfolg
/// sein darf**.
final class AcknowledgementClassifierTests: XCTestCase {

    func testAcknowledgedRequiresBothTheCommandByteAndTheAcknowledgingStatus() {
        let frame = acknowledgementFrame(status: AcknowledgementClassifier.acknowledgedStatusByte)
        XCTAssertEqual(AcknowledgementClassifier.classify(frame), .acknowledged)
        XCTAssertTrue(AcknowledgementClassifier.classify(frame).isAcknowledged)
    }

    func testRejectedIsItsOwnCaseAndNotAFailure() {
        let frame = acknowledgementFrame(status: AcknowledgementClassifier.rejectedStatusByte)
        XCTAssertEqual(AcknowledgementClassifier.classify(frame), .rejected)
        XCTAssertFalse(AcknowledgementClassifier.classify(frame).isAcknowledged)
    }

    /// Ein Statusbyte, dessen Bedeutung nicht belegt ist, ist **weder**
    /// Zustimmung **noch** Ablehnung. Es wurde real beobachtet.
    func testAnUnknownStatusByteIsNeitherAcknowledgedNorRejected() {
        let frame = acknowledgementFrame(status: 0x02)
        XCTAssertEqual(AcknowledgementClassifier.classify(frame), .unknownStatus(0x02))
        XCTAssertFalse(AcknowledgementClassifier.classify(frame).isAcknowledged)
    }

    /// **Die wichtigste Regel dieses Typs.**
    func testAMissingStatusByteIsNeverAcknowledged() {
        let frame = acknowledgementFrame(status: nil)
        XCTAssertEqual(AcknowledgementClassifier.classify(frame), .missingStatusByte)
        XCTAssertFalse(AcknowledgementClassifier.classify(frame).isAcknowledged)
    }

    func testAnEmptyPayloadIsUndecodableAndNotAcknowledged() {
        let frame = try! Frame.build(address: 0x81, payload: [])
        XCTAssertEqual(AcknowledgementClassifier.classify(frame), .undecodable)
        XCTAssertFalse(AcknowledgementClassifier.classify(frame).isAcknowledged)
    }

    func testAnotherCommandByteIsReportedWithItsValue() {
        let frame = acknowledgementFrame(status: 0x00, commandByte: 0xB1)
        XCTAssertEqual(AcknowledgementClassifier.classify(frame), .unexpectedCommandByte(0xB1))
    }

    /// **Auflage A1 auf Klassifikationsebene:** Ein Messstrom ist ein
    /// eigener Fall — nicht „unerwartetes Kommandobyte" und ganz
    /// sicher kein Erfolg.
    func testAScanProfileBroadcastIsItsOwnCaseAndNeverASuccess() {
        let outcome = AcknowledgementClassifier.classify(scanProfileFrame())
        XCTAssertEqual(outcome, .observedScanProfile)
        XCTAssertFalse(outcome.isAcknowledged)
    }

    /// Der dritte Antwortbyte-Wert wurde real unterschiedlich gesehen
    /// und ist ungedeutet — er darf die Klassifikation nicht verändern.
    func testTheUninterpretedThirdByteDoesNotChangeTheResult() {
        for third: UInt8 in [0x00, 0x04, 0xFF] {
            let frame = acknowledgementFrame(status: 0x00, thirdByte: third)
            XCTAssertEqual(AcknowledgementClassifier.classify(frame), .acknowledged)
        }
    }

    /// `isAcknowledged` ist für **genau einen** Fall wahr.
    func testExactlyOneOutcomeCountsAsAcknowledged() {
        let outcomes: [AcknowledgementOutcome] = [
            .acknowledged, .rejected, .unknownStatus(0x02), .missingStatusByte,
            .unexpectedCommandByte(0xB1), .observedScanProfile, .timeout, .undecodable
        ]
        XCTAssertEqual(outcomes.filter(\.isAcknowledged).count, 1)
    }
}
