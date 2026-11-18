import XCTest
import SickPLSActiveControl
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSSetupControl

final class SetupConsoleModelTests: XCTestCase {

    var model: SetupConsoleModel!
    fileprivate var recordingPort: RecordingSerialPort!

    override func setUp() {
        super.setUp()
        recordingPort = RecordingSerialPort()
        let opener = RecordingPortOpener(port: recordingPort)
        model = SetupConsoleModel(opener: opener)
        model.selectedPort = "/dev/cu.test"
        
        let openExpectation = XCTestExpectation(description: "Port oeffnen")
        opener.onOpen = {
            DispatchQueue.main.async {
                // Die Portöffnung veröffentlicht ihren Modellzustand erst
                // in einem eigenen Main-Queue-Block nach Rückkehr aus dem
                // Opener. Erst dahinter darf der Test mit `send` beginnen.
                DispatchQueue.main.async {
                    openExpectation.fulfill()
                }
            }
        }
        model.openSelectedPort()
        wait(for: [openExpectation], timeout: 0.5)
    }

    override func tearDown() {
        model.closePort()
        model = nil
        recordingPort = nil
        super.tearDown()
    }

    // MARK: - Fixed Address Tests for Settings Mode and Verification

    func testSendSettingsModeWritesFrameToAddressZero() {
        model.targetAddressText = "FF"
        model.password = SetupConsoleModel.defaultPassword
        recordingPort.clearRecordedWrites()

        let expectation = XCTestExpectation(description: "Settings mode schreiben")
        recordingPort.onWrite = {
            DispatchQueue.main.async {
                expectation.fulfill()
            }
        }
        model.sendSettingsMode()
        wait(for: [expectation], timeout: 0.5)

        XCTAssertEqual(recordingPort.recordedWrites.count, 1, "Genau ein Frame sollte geschrieben werden")
        let frameBytes = recordingPort.recordedWrites[0]
        guard case .success(let frame) = Frame.decodeExact(from: frameBytes) else {
            XCTFail("Ungueltiger Frame geschrieben")
            return
        }
        XCTAssertEqual(frame.address, 0x00, "20 30 muss an Adresse 0x00 gehen")
        XCTAssertEqual(frame.payload.first, CommissioningRecipe.r26.configurationCommandByte)
        XCTAssertEqual(frame.payload.dropFirst().first, CommissioningRecipe.r26.settingsModeByte)
        XCTAssertEqual(frame.payload.count, 2 + InstallationSecret.requiredByteCount)
    }

    func testSendVerificationIdentityWritesFrameToAddressZero() {
        model.targetAddressText = "FF"
        recordingPort.clearRecordedWrites()

        let expectation = XCTestExpectation(description: "Verification identity schreiben")
        recordingPort.onWrite = {
            DispatchQueue.main.async {
                expectation.fulfill()
            }
        }
        model.sendVerificationIdentity()
        wait(for: [expectation], timeout: 0.5)

        XCTAssertEqual(recordingPort.recordedWrites.count, 1, "Genau ein Frame sollte geschrieben werden")
        let frameBytes = recordingPort.recordedWrites[0]
        guard case .success(let frame) = Frame.decodeExact(from: frameBytes) else {
            XCTFail("Ungueltiger Frame geschrieben")
            return
        }
        XCTAssertEqual(frame.address, 0x00, "Verifikation 31 muss an Adresse 0x00 gehen")
        XCTAssertEqual(frame.payload.first, 0x31)
        XCTAssertEqual(frame.payload.count, 1)
    }

    func testSendIdentityWritesFrameToConfigurableAddress() {
        model.targetAddressText = "05"
        recordingPort.clearRecordedWrites()

        let expectation = XCTestExpectation(description: "Identity schreiben")
        recordingPort.onWrite = {
            DispatchQueue.main.async {
                expectation.fulfill()
            }
        }
        model.sendIdentity()
        wait(for: [expectation], timeout: 0.5)

        XCTAssertEqual(recordingPort.recordedWrites.count, 1)
        let frameBytes = recordingPort.recordedWrites[0]
        guard case .success(let frame) = Frame.decodeExact(from: frameBytes) else {
            XCTFail("Ungueltiger Frame geschrieben")
            return
        }
        XCTAssertEqual(frame.address, 0x05, "Identitaet muss an konfigurierbare Adresse 0x05 gehen")
        XCTAssertEqual(frame.payload.first, 0x31)
        XCTAssertEqual(frame.payload.count, 1)
    }

    func testSendLoginWritesFrameToConfigurableAddress() {
        model.targetAddressText = "0A"
        model.password = SetupConsoleModel.defaultPassword
        recordingPort.clearRecordedWrites()

        let expectation = XCTestExpectation(description: "Login schreiben")
        recordingPort.onWrite = {
            DispatchQueue.main.async {
                expectation.fulfill()
            }
        }
        model.sendLogin()
        wait(for: [expectation], timeout: 0.5)

        XCTAssertEqual(recordingPort.recordedWrites.count, 1)
        let frameBytes = recordingPort.recordedWrites[0]
        guard case .success(let frame) = Frame.decodeExact(from: frameBytes) else {
            XCTFail("Ungueltiger Frame geschrieben")
            return
        }
        XCTAssertEqual(frame.address, 0x0A, "Login muss an konfigurierbare Adresse 0x0A gehen")
        XCTAssertEqual(frame.payload.first, CommissioningRecipe.r26.configurationCommandByte)
        XCTAssertEqual(frame.payload.dropFirst().first, CommissioningRecipe.r26.loginModeByte)
        XCTAssertEqual(frame.payload.count, 2 + InstallationSecret.requiredByteCount)
    }

    func testSendBaudSwitchWritesFrameToConfigurableAddress() {
        model.targetAddressText = "03"
        model.baudSwitchTarget = .baud38400
        recordingPort.clearRecordedWrites()

        let expectation = XCTestExpectation(description: "Baudwechsel schreiben")
        recordingPort.onWrite = {
            DispatchQueue.main.async {
                expectation.fulfill()
            }
        }
        model.sendBaudSwitch()
        wait(for: [expectation], timeout: 0.5)

        XCTAssertEqual(recordingPort.recordedWrites.count, 1)
        let frameBytes = recordingPort.recordedWrites[0]
        guard case .success(let frame) = Frame.decodeExact(from: frameBytes) else {
            XCTFail("Ungueltiger Frame geschrieben")
            return
        }
        XCTAssertEqual(frame.address, 0x03, "Baudwechsel muss an konfigurierbare Adresse 0x03 gehen")
        XCTAssertEqual(frame.payload, [CommissioningRecipe.r26.configurationCommandByte, CommissioningRecipe.r26.baudSwitchModeByte])
    }

    func testSendMeasurementModeWritesFrameToConfigurableAddress() {
        model.targetAddressText = "02"
        recordingPort.clearRecordedWrites()

        let expectation = XCTestExpectation(description: "MMK schreiben")
        recordingPort.onWrite = {
            DispatchQueue.main.async {
                expectation.fulfill()
            }
        }
        model.sendMeasurementMode()
        wait(for: [expectation], timeout: 0.5)

        XCTAssertEqual(recordingPort.recordedWrites.count, 1)
        let frameBytes = recordingPort.recordedWrites[0]
        guard case .success(let frame) = Frame.decodeExact(from: frameBytes) else {
            XCTFail("Ungueltiger Frame geschrieben")
            return
        }
        XCTAssertEqual(frame.address, 0x02, "MMK muss an konfigurierbare Adresse 0x02 gehen")
        XCTAssertEqual(frame.payload, [CommissioningRecipe.r26.configurationCommandByte, CommissioningRecipe.r26.measurementModeByte])
    }

    func testSendRequestOnlyModeWrites2025() {
        model.targetAddressText = "01"
        model.selectedMeasurementMode = .requestOnly
        recordingPort.clearRecordedWrites()
        let expectation = XCTestExpectation(description: "20 25 schreiben")
        recordingPort.onWrite = { DispatchQueue.main.async { expectation.fulfill() } }

        model.sendMeasurementMode()
        wait(for: [expectation], timeout: 0.5)

        guard case .success(let frame) = Frame.decodeExact(from: recordingPort.recordedWrites[0]) else {
            return XCTFail("Ungueltiger Frame")
        }
        XCTAssertEqual(frame.payload, [0x20, 0x25])
    }

    func testSendCentered90DegreeSubrangeUsesLittleEndianIndices() {
        model.targetAddressText = "01"
        model.selectedMeasurementMode = .centered90Degrees
        recordingPort.clearRecordedWrites()
        let expectation = XCTestExpectation(description: "20 27 schreiben")
        recordingPort.onWrite = { DispatchQueue.main.async { expectation.fulfill() } }

        model.sendMeasurementMode()
        wait(for: [expectation], timeout: 0.5)

        guard case .success(let frame) = Frame.decodeExact(from: recordingPort.recordedWrites[0]) else {
            return XCTFail("Ungueltiger Frame")
        }
        XCTAssertEqual(frame.payload, [0x20, 0x27, 0x5B, 0x00, 0x0F, 0x01])
    }

    func testSend500KBaudSwitchWrites2048() {
        model.targetAddressText = "01"
        model.baudSwitchTarget = .baud500000
        recordingPort.clearRecordedWrites()
        let expectation = XCTestExpectation(description: "20 48 schreiben")
        recordingPort.onWrite = { DispatchQueue.main.async { expectation.fulfill() } }

        model.sendBaudSwitch()
        wait(for: [expectation], timeout: 0.5)

        guard case .success(let frame) = Frame.decodeExact(from: recordingPort.recordedWrites[0]) else {
            return XCTFail("Ungueltiger Frame")
        }
        XCTAssertEqual(frame.payload, [0x20, 0x48])
    }

    // MARK: - Password telegrams have 10 payload bytes

    func testSettingsModeFrameHasTenPayloadBytes() {
        model.targetAddressText = "01"
        model.password = SetupConsoleModel.defaultPassword
        recordingPort.clearRecordedWrites()

        let expectation = XCTestExpectation(description: "Settings mode mit Passwort schreiben")
        recordingPort.onWrite = {
            DispatchQueue.main.async {
                expectation.fulfill()
            }
        }
        model.sendSettingsMode()
        wait(for: [expectation], timeout: 0.5)

        XCTAssertEqual(recordingPort.recordedWrites.count, 1)
        let frameBytes = recordingPort.recordedWrites[0]
        guard case .success(let frame) = Frame.decodeExact(from: frameBytes) else {
            XCTFail("Ungueltiger Frame geschrieben")
            return
        }
        XCTAssertEqual(frame.payload.count, 10, "Settings mode muss 10 Payload-Bytes haben")
    }

    func testLoginFrameHasTenPayloadBytes() {
        model.targetAddressText = "01"
        model.password = SetupConsoleModel.defaultPassword
        recordingPort.clearRecordedWrites()

        let expectation = XCTestExpectation(description: "Login mit Passwort schreiben")
        recordingPort.onWrite = {
            DispatchQueue.main.async {
                expectation.fulfill()
            }
        }
        model.sendLogin()
        wait(for: [expectation], timeout: 0.5)

        XCTAssertEqual(recordingPort.recordedWrites.count, 1)
        let frameBytes = recordingPort.recordedWrites[0]
        guard case .success(let frame) = Frame.decodeExact(from: frameBytes) else {
            XCTFail("Ungueltiger Frame geschrieben")
            return
        }
        XCTAssertEqual(frame.payload.count, 10, "Login muss 10 Payload-Bytes haben")
    }

    // MARK: - Default address is the hardware-confirmed universal address

    func testDefaultTargetAddressIs00() {
        XCTAssertEqual(model.targetAddressText, "00")
    }
}

// MARK: - Recording Fake Port

fileprivate final class RecordingSerialPort: ActiveControlSerialPort {
    private(set) var recordedWrites: [[UInt8]] = []
    var onWrite: (() -> Void)?

    func write(_ bytes: [UInt8]) throws {
        recordedWrites.append(bytes)
        onWrite?()
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        .timeout
    }

    func close() {
    }

    func clearRecordedWrites() {
        recordedWrites.removeAll()
    }
}

fileprivate final class RecordingPortOpener: ActiveControlSerialPortOpener {
    let port: RecordingSerialPort
    var onOpen: (() -> Void)?

    init(port: RecordingSerialPort) {
        self.port = port
    }

    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> ActiveControlSerialPort {
        guard path.hasPrefix("/dev/cu.") else {
            throw SerialPortOpenError.pathNotAllowed(path)
        }
        onOpen?()
        return port
    }
}
