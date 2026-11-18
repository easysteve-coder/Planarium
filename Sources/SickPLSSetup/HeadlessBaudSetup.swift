import Foundation
import SickPLSActiveControl
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport

/// Synchrone, öffentliche Hülle um `SafeScannerSetupWorkflow` für einen
/// Kopf-losen (GUI-freien) Baudübergang. Adresse ist fest 01, Kennwort der
/// veröffentlichte Standardwert (`SetupConsoleModel.defaultPassword`, nur als
/// Symbol referenziert). Sendet ausschließlich die belegte R26-Sequenz.
public enum HeadlessBaudSetup {
    public enum HeadlessError: Error { case addressInvalid, secretInvalid }

    public static func transition(
        portPath: String,
        targetBaud: SerialPortBaudRate,
        addressByte: UInt8 = 0x01
    ) throws -> (baud: SerialPortBaudRate, evidence: [String]) {
        guard let address = ConfirmedTargetAddress(rawValue: addressByte) else {
            throw HeadlessError.addressInvalid
        }
        guard let secret = InstallationSecret(text: SetupConsoleModel.defaultPassword) else {
            throw HeadlessError.secretInvalid
        }
        let workflow = SafeScannerSetupWorkflow(opener: DarwinActiveControlSerialPortOpener())
        let result = try workflow.transition(
            portPath: portPath,
            targetRate: targetBaud,
            address: address,
            secret: secret,
            preferredRate: .baud9600
        )
        result.port.close()
        return (result.baudRate, result.evidence)
    }

    public static func detectedBaud(portPath: String, addressByte: UInt8 = 0x01) -> SerialPortBaudRate? {
        guard let address = ConfirmedTargetAddress(rawValue: addressByte) else { return nil }
        let workflow = SafeScannerSetupWorkflow(opener: DarwinActiveControlSerialPortOpener())
        return try? workflow.detectBaudRate(portPath: portPath, address: address, preferredRate: nil).0
    }

    public static func probeBaudWithoutLogin(
        portPath: String,
        targetBaud: SerialPortBaudRate,
        addressByte: UInt8 = 0x00
    ) throws -> (accepted: Bool, negative: Bool, verifiedRate: SerialPortBaudRate?, evidence: [String]) {
        guard let address = ConfirmedTargetAddress(rawValue: addressByte) else {
            throw HeadlessError.addressInvalid
        }
        let workflow = SafeScannerSetupWorkflow(opener: DarwinActiveControlSerialPortOpener())
        return try workflow.probeBaudSwitchWithoutLogin(
            portPath: portPath, targetRate: targetBaud, address: address
        )
    }

    public static func sendMode(
        portPath: String,
        modeByte: UInt8,
        addressByte: UInt8 = 0x00
    ) throws -> (accepted: Bool, negative: Bool, profileFollowed: Bool, evidence: [String]) {
        guard let address = ConfirmedTargetAddress(rawValue: addressByte) else {
            throw HeadlessError.addressInvalid
        }
        let workflow = SafeScannerSetupWorkflow(opener: DarwinActiveControlSerialPortOpener())
        return try workflow.sendMeasurementModeWithoutLogin(
            portPath: portPath, modeByte: modeByte, address: address
        )
    }
}
