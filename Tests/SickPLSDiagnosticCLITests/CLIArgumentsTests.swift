import XCTest
import SickPLSMacTransport
import SickPLSActiveControl
@testable import SickPLSDiagnosticCLI

final class CLIArgumentsTests: XCTestCase {

    func testNoArgumentsYieldsDefaultOptions() throws {
        let options = try parseArguments([])
        XCTAssertEqual(options, CLIOptions(portPath: nil, listPorts: false, durationSeconds: nil, baudRate: nil))
    }

    // MARK: - --baud (SICK-010-Scope-Änderung: kein Auto-Baud)

    func testBaudOptionAccepts9600() throws {
        let options = try parseArguments(["--baud", "9600"])
        XCTAssertEqual(options.baudRate, .baud9600)
    }

    func testBaudOptionAccepts38400() throws {
        let options = try parseArguments(["--baud", "38400"])
        XCTAssertEqual(options.baudRate, .baud38400)
    }

    func testMissingBaudValueThrowsMissingValue() {
        XCTAssertThrowsError(try parseArguments(["--baud"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .missingValue(option: "--baud"))
        }
    }

    func testNonNumericBaudThrowsInvalidBaudRate() {
        XCTAssertThrowsError(try parseArguments(["--baud", "schnell"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .invalidBaudRate("schnell"))
        }
    }

    func testUnsupportedNumericBaudThrowsInvalidBaudRate() {
        // Kein Auto-Baud, keine beliebigen Zahlen -- nur die beiden
        // dokumentierten, benannten Werte sind zulässig.
        XCTAssertThrowsError(try parseArguments(["--baud", "19200"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .invalidBaudRate("19200"))
        }
    }

    func testMessageForInvalidBaudRateNamesBothAllowedValues() {
        let text = message(for: .invalidBaudRate("19200"))
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("9600"))
        XCTAssertTrue(text!.contains("38400"))
    }

    func testPortOptionSetsPortPath() throws {
        let options = try parseArguments(["--port", "/dev/cu.usbserial-A1"])
        XCTAssertEqual(options.portPath, "/dev/cu.usbserial-A1")
    }

    func testListPortsSetsFlag() throws {
        let options = try parseArguments(["--list-ports"])
        XCTAssertTrue(options.listPorts)
    }

    func testDurationOptionParsesFractionalSeconds() throws {
        let options = try parseArguments(["--duration", "2.5"])
        XCTAssertEqual(options.durationSeconds, 2.5)
    }

    func testCombinedOptionsAreAllApplied() throws {
        let options = try parseArguments([
            "--list-ports", "--port", "/dev/cu.usbserial-A1", "--duration", "10", "--baud", "9600",
        ])
        XCTAssertEqual(
            options,
            CLIOptions(portPath: "/dev/cu.usbserial-A1", listPorts: true, durationSeconds: 10, baudRate: .baud9600)
        )
    }

    func testMissingPortValueThrowsMissingValue() {
        XCTAssertThrowsError(try parseArguments(["--port"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .missingValue(option: "--port"))
        }
    }

    func testMissingDurationValueThrowsMissingValue() {
        XCTAssertThrowsError(try parseArguments(["--duration"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .missingValue(option: "--duration"))
        }
    }

    func testNonNumericDurationThrowsInvalidDuration() {
        XCTAssertThrowsError(try parseArguments(["--duration", "bald"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .invalidDuration("bald"))
        }
    }

    func testUnknownOptionThrowsUnknownOption() {
        XCTAssertThrowsError(try parseArguments(["--frobnicate"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .unknownOption("--frobnicate"))
        }
    }

    func testHelpThrowsHelpRequestedAndTakesPrecedenceOverLaterArguments() {
        XCTAssertThrowsError(try parseArguments(["--help", "--frobnicate"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .helpRequested)
        }
        XCTAssertThrowsError(try parseArguments(["-h"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .helpRequested)
        }
    }

    func testMessageForEachNonHelpErrorIsNonEmpty() {
        XCTAssertNotNil(message(for: .missingValue(option: "--port")))
        XCTAssertNotNil(message(for: .invalidDuration("x")))
        XCTAssertNotNil(message(for: .unknownOption("--x")))
    }

    func testMessageForHelpRequestedIsNil() {
        XCTAssertNil(message(for: .helpRequested))
    }

    // MARK: - --probe-baud/--target-address (SICK-011-Auftrag: sichtbarer Opt-in)

    func testProbeBaudDefaultsToFalse() throws {
        let options = try parseArguments([])
        XCTAssertFalse(options.probeBaud)
    }

    func testProbeBaudFlagSetsOptIn() throws {
        let options = try parseArguments(["--probe-baud"])
        XCTAssertTrue(options.probeBaud)
    }

    func testTargetAddressDefaultsToNilNotToUniversal() throws {
        // Der dokumentierte Default (Universaladresse) wird bewusst erst
        // in main.swift explizit aufgelöst, nicht hier stillschweigend
        // vorbelegt (SICK-011-Auftrag: „keine RX-Adresse ableiten" --
        // allgemeiner: kein stiller Default tief in der Optionsstruktur).
        let options = try parseArguments([])
        XCTAssertNil(options.targetAddress)
    }

    func testTargetAddressOptionParsesValidValue() throws {
        let options = try parseArguments(["--target-address", "5"])
        XCTAssertEqual(options.targetAddress, ConfirmedTargetAddress(rawValue: 5))
    }

    func testTargetAddressOptionAcceptsZero() throws {
        let options = try parseArguments(["--target-address", "0"])
        XCTAssertEqual(options.targetAddress, .universal)
    }

    func testMissingTargetAddressValueThrowsMissingValue() {
        XCTAssertThrowsError(try parseArguments(["--target-address"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .missingValue(option: "--target-address"))
        }
    }

    func testNonNumericTargetAddressThrowsInvalidTargetAddress() {
        XCTAssertThrowsError(try parseArguments(["--target-address", "viel"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .invalidTargetAddress("viel"))
        }
    }

    func testReservedScannerResponseAddressThrowsInvalidTargetAddress() {
        // 0x81 -- strukturell abgelehnt von ConfirmedTargetAddress selbst,
        // muss hier als klarer Parsing-Fehler ankommen, nicht als Absturz.
        XCTAssertThrowsError(try parseArguments(["--target-address", "129"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .invalidTargetAddress("129"))
        }
    }

    func testOutOfRangeTargetAddressThrowsInvalidTargetAddress() {
        XCTAssertThrowsError(try parseArguments(["--target-address", "300"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .invalidTargetAddress("300"))
        }
    }

    func testMessageForInvalidTargetAddressIsNonEmpty() {
        XCTAssertNotNil(message(for: .invalidTargetAddress("129")))
    }
}
