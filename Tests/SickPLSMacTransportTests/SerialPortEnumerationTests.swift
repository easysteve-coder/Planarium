import XCTest
@testable import SickPLSMacTransport

final class SerialPortEnumerationTests: XCTestCase {

    func testAvailablePortPathsFiltersToCuPrefixOnly() {
        // SICK-009-Auftrag: "Portliste darf nur /dev/cu.* lesen" --
        // insbesondere /dev/tty.* (blockiert unter macOS bis DCD anliegt)
        // darf nie zurückkommen.
        let lister = FakeDirectoryLister(entries: [
            "cu.usbserial-A1",
            "tty.usbserial-A1",
            "cu.Bluetooth-Incoming-Port",
            ".",
            "..",
            "null",
        ])

        let paths = SerialPortEnumeration.availablePortPaths(lister: lister)

        XCTAssertEqual(paths, [
            "/dev/cu.Bluetooth-Incoming-Port",
            "/dev/cu.usbserial-A1",
        ])
    }

    func testAvailablePortPathsReturnsEmptyForNoMatches() {
        let lister = FakeDirectoryLister(entries: ["tty.usbserial-A1", "null", "random"])

        XCTAssertEqual(SerialPortEnumeration.availablePortPaths(lister: lister), [])
    }

    func testAvailablePortPathsReturnsEmptyForEmptyDirectory() {
        let lister = FakeDirectoryLister(entries: [])

        XCTAssertEqual(SerialPortEnumeration.availablePortPaths(lister: lister), [])
    }

    func testAvailablePortPathsPrefixesFullDevPath() {
        let lister = FakeDirectoryLister(entries: ["cu.usbserial-A1"])

        XCTAssertEqual(SerialPortEnumeration.availablePortPaths(lister: lister), ["/dev/cu.usbserial-A1"])
    }
}
