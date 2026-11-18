import XCTest
@testable import SickPLSActiveControl

final class ConfirmedTargetAddressTests: XCTestCase {

    func testUniversalIsZero() {
        XCTAssertEqual(ConfirmedTargetAddress.universal.rawValue, 0x00)
    }

    func testInitAcceptsZeroAndEqualsUniversal() {
        XCTAssertEqual(ConfirmedTargetAddress(rawValue: 0x00), .universal)
    }

    func testInitAcceptsArbitraryOtherAddress() {
        XCTAssertEqual(ConfirmedTargetAddress(rawValue: 0x01)?.rawValue, 0x01)
        XCTAssertEqual(ConfirmedTargetAddress(rawValue: 99)?.rawValue, 99)
        XCTAssertEqual(ConfirmedTargetAddress(rawValue: 255)?.rawValue, 255)
    }

    func testInitRejectsKnownScannerResponseAddress() {
        // wire-protocol.md §2: 0x81 ist in jeder realen Beobachtung
        // ausschließlich die Scanner→Host-Antwortadresse -- niemals ein
        // gültiges Sendeziel.
        XCTAssertNil(ConfirmedTargetAddress(rawValue: 0x81))
    }
}
