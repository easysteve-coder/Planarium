import XCTest
import SickPLSCore
@testable import SickPLSSetupControl

final class HexTelegramInputTests: XCTestCase {
    func testAcceptsACompleteCRCValidFrameAtAddressOne() throws {
        let bytes = try Frame.build(address: 0x01, payload: [0x31]).encoded()
        let text = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        XCTAssertEqual(HexTelegramInput.parse(text), .success(bytes))
    }

    func testAcceptsUniversalButRejectsResponseAddress() throws {
        let universal = try Frame.build(address: 0x00, payload: [0x31]).encoded()
        let response = try Frame.build(address: 0x81, payload: [0xB1]).encoded()
        XCTAssertEqual(HexTelegramInput.parse(hex(universal)), .success(universal))
        XCTAssertEqual(HexTelegramInput.parse(hex(response)), .failure(.wrongTargetAddress(0x81)))
    }

    func testTargetAddressAcceptsHexAndRejectsTheReplyAddress() {
        XCTAssertEqual(TargetAddressInput.parse("01")?.rawValue, 0x01)
        XCTAssertEqual(TargetAddressInput.parse("0x2a")?.rawValue, 0x2A)
        XCTAssertNil(TargetAddressInput.parse("81"))
        XCTAssertNil(TargetAddressInput.parse("xyz"))
    }

    func testRejectsBadCRCAndNonHexInput() throws {
        var damaged = try Frame.build(address: 0x01, payload: [0x31]).encoded()
        damaged[4] ^= 0x01
        XCTAssertEqual(HexTelegramInput.parse(hex(damaged)), .failure(.notACompleteFrame))
        XCTAssertEqual(HexTelegramInput.parse("02 01 nope"), .failure(.invalidToken("nope")))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
