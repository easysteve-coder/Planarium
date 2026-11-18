import XCTest
import SickPLSCore
@testable import SickPLSDeviceModel

final class VirtualPLSDeviceTests: XCTestCase {
    // Independent literals: these are redacted synthetic command frames,
    // not produced with Frame.encoded() in the same test.
    private let fullScan = [UInt8](arrayLiteral: 0x02, 0x00, 0x02, 0x00, 0x20, 0x24, 0x34, 0x08)
    private let mmk = [UInt8](arrayLiteral: 0x02, 0x00, 0x02, 0x00, 0x20, 0x20, 0x30, 0x08)
    private let identity = [UInt8](arrayLiteral: 0x02, 0x00, 0x01, 0x00, 0x31, 0x15, 0x12)
    private let status = [UInt8](arrayLiteral: 0x02, 0x00, 0x01, 0x00, 0x32, 0x16, 0x12)
    private let login = [UInt8](arrayLiteral: 0x02, 0x01, 0x0A, 0x00, 0x20, 0x00, 83, 73, 67, 75, 95, 80, 76, 83, 0xFF, 0x6C)

    func testFullScanAcknowledgesAndSetsFullScanMode() {
        let device = VirtualPLSDevice()
        let output = device.receive(bytes: fullScan)
        XCTAssertEqual(device.mode, .fullScan)
        assertFramed(output, equals: [0x02, 0x80, 0x03, 0x00, 0xA0, 0x00, 0x00, 0x06, 0x0A])
    }

    func testMMKAcknowledgesSetsModeAndDoesNotInventProfile() {
        let device = VirtualPLSDevice()
        let output = device.receive(bytes: mmk)
        XCTAssertEqual(device.mode, .minimumPerSegmentRequested)
        assertFramed(output, equals: [0x02, 0x80, 0x03, 0x00, 0xA0, 0x00, 0x00, 0x06, 0x0A])
        XCTAssertThrowsError(try device.profile()) { error in
            XCTAssertEqual(error as? VirtualPLSProfileError, .notSupported(mode: .minimumPerSegmentRequested))
        }
    }

    func testIdentityStatusAndLoginCasesAreSeparated() {
        let device = VirtualPLSDevice()
        assertFramed(device.receive(bytes: identity), equals: [0x02, 0x80, 0x07, 0x00, 0xB1, 0x00, 0x30, 0x37, 0x2E, 0x32, 0x31, 0x70, 0x30])
        assertFramed(device.receive(bytes: status), equals: [0x02, 0x80, 0x06, 0x00, 0xB2, 0x02, 0x20, 0x02, 0x21, 0x00, 0x9A, 0x84])
        assertFramed(device.receive(bytes: login), equals: [0x02, 0x81, 0x03, 0x00, 0xA0, 0x00, 0x00, 0x26, 0x1A])
        XCTAssertTrue(device.isLoggedIn)

        let wrong = [UInt8](arrayLiteral: 0x02, 0x01, 0x0A, 0x00, 0x20, 0x00, 83, 73, 67, 75, 95, 80, 76, 84, 0xF8, 0x6C)
        assertFramed(device.receive(bytes: wrong), equals: [0x02, 0x81, 0x03, 0x00, 0xA0, 0x01, 0x00, 0x24, 0x1B])
        XCTAssertFalse(device.isLoggedIn)
    }

    func testUnknownCommandIsExplicitlyUnsupported() {
        let device = VirtualPLSDevice()
        let unknown = [UInt8](arrayLiteral: 0x02, 0x00, 0x01, 0x00, 0x7F, 0x5B, 0x12)
        XCTAssertEqual(device.receive(bytes: unknown), [.notSupported(command: 0x7F)])
        XCTAssertEqual(device.mode, .idle)
    }

    func testWrongModeByteIsNotAccepted() {
        let device = VirtualPLSDevice()
        let wrongMode = [UInt8](arrayLiteral: 0x02, 0x00, 0x02, 0x00, 0x20, 0x25, 0x35, 0x08)
        XCTAssertEqual(device.receive(bytes: wrongMode), [.notSupported(command: 0x20)])
        XCTAssertEqual(device.mode, .idle)
    }

    func testSingleByteACKAloneIsNotACompleteResponse() {
        let device = VirtualPLSDevice()
        XCTAssertTrue(device.receive(bytes: [DeviceSingleByte.acknowledgement.rawValue]).isEmpty)
        XCTAssertEqual(device.mode, .idle)
    }

    func testFragmentedConcatenatedAndNoisyFramesAreParsed() {
        let device = VirtualPLSDevice()
        var output: [DeviceOutput] = []
        for byte in [UInt8](arrayLiteral: 0x55, 0xAA) + identity + status { output += device.receive(bytes: [byte]) }
        assertFramedOutputs(output, equals: [
            [0x02, 0x80, 0x07, 0x00, 0xB1, 0x00, 0x30, 0x37, 0x2E, 0x32, 0x31, 0x70, 0x30],
            [0x02, 0x80, 0x06, 0x00, 0xB2, 0x02, 0x20, 0x02, 0x21, 0x00, 0x9A, 0x84]
        ])
    }

    func testBadCRCProducesNoDeviceOutput() {
        let device = VirtualPLSDevice()
        var damaged = fullScan
        damaged[damaged.count - 1] ^= 0x01
        XCTAssertTrue(device.receive(bytes: damaged).isEmpty)
        XCTAssertEqual(device.mode, .idle)
    }

    func testVirtualClockAdvancesWithoutWallClockOrIO() {
        let device = VirtualPLSDevice()
        device.advanceClock(by: 125)
        XCTAssertEqual(device.clock.milliseconds, 125)
    }

    private func assertFramed(_ outputs: [DeviceOutput], equals expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        guard outputs.count == 1, case let .framed(frame) = outputs[0] else {
            XCTFail("expected one framed output, got \(outputs)", file: file, line: line)
            return
        }
        XCTAssertEqual(frame.encoded(), expected, file: file, line: line)
    }

    private func assertFramedOutputs(_ outputs: [DeviceOutput], equals expected: [[UInt8]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outputs.count, expected.count, file: file, line: line)
        for (output, bytes) in zip(outputs, expected) {
            guard case let .framed(frame) = output else {
                XCTFail("expected framed output, got \(output)", file: file, line: line)
                continue
            }
            XCTAssertEqual(frame.encoded(), bytes, file: file, line: line)
        }
    }
}
