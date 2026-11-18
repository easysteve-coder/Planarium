import XCTest
import SickPLSCore
@testable import SickPLSActiveControl

final class IdentityProbeTests: XCTestCase {

    func testRequestFrameUsesRequestCommandByteAsSolePayload() {
        let frame = IdentityProbe.requestFrame(address: .universal)
        XCTAssertEqual(frame.address, 0x00)
        XCTAssertEqual(frame.payload, [0x31])
    }

    func testRequestFrameUsesTheGivenExplicitAddress() {
        let address = ConfirmedTargetAddress(rawValue: 0x01)!
        let frame = IdentityProbe.requestFrame(address: address)
        XCTAssertEqual(frame.address, 0x01)
    }

    func testIsExpectedResponseTrueForB1CommandByte() throws {
        let frame = try Frame.build(address: 0x81, payload: [0xB1, 0x00, 0x01])
        XCTAssertTrue(IdentityProbe.isExpectedResponse(frame))
    }

    func testIsExpectedResponseFalseForOtherCommandByte() throws {
        let frame = try Frame.build(address: 0x81, payload: [0xB0, 0x00])
        XCTAssertFalse(IdentityProbe.isExpectedResponse(frame))
    }

    func testIsExpectedResponseFalseForEmptyPayload() throws {
        let frame = try Frame.build(address: 0x81, payload: [])
        XCTAssertFalse(IdentityProbe.isExpectedResponse(frame))
    }
}
