import Darwin
import XCTest
@testable import SickPLSMacTransport

final class DarwinBaudRateConfigurationTests: XCTestCase {
    func test500KUsesAStandardPlaceholderBeforeIOSSIOSPEED() {
        var options = termios()

        XCTAssertTrue(DarwinBaudRateConfiguration.prepare(&options, baudRate: .baud500000))
        XCTAssertEqual(cfgetispeed(&options), speed_t(B38400))
        XCTAssertEqual(cfgetospeed(&options), speed_t(B38400))
    }

    func testStandardRateStaysExactInTermios() {
        var options = termios()

        XCTAssertTrue(DarwinBaudRateConfiguration.prepare(&options, baudRate: .baud9600))
        XCTAssertEqual(cfgetispeed(&options), speed_t(9600))
        XCTAssertEqual(cfgetospeed(&options), speed_t(9600))
    }
}
