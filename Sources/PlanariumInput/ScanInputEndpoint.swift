import SickPLSCore
import SickPLSMacTransport

public enum ScanInputEndpoint: Equatable, Sendable {
    case serialPort(path: String, baudRate: SerialPortBaudRate)
    case simulation(serviceName: String)
}

public protocol ScanByteStreamOpening {
    func openStream() throws -> SerialPortFileDescriptor
}

public enum ScanByteStreamOpenError: Error, Equatable, Sendable {
    case unreachable
    case timedOut
    case waitingForLocalNetwork
}
