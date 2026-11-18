import SickPLSMacTransport

public enum InputFailurePresentation {
    public static func describe(_ error: Error) -> String {
        if let openError = error as? ScanByteStreamOpenError {
            switch openError {
            case .unreachable: return "The simulation is unreachable."
            case .timedOut: return "Opening the simulation timed out."
            case .waitingForLocalNetwork:
                return "Local network access is not yet allowed. Allow it in macOS, then reconnect."
            }
        }
        guard let openError = error as? SerialPortOpenError else {
            return "Unknown error opening the connection."
        }
        switch openError {
        case .openFailed(let errno):
            return "Open failed (errno \(errno))."
        case .configurationFailed(let errno):
            return "Port configuration failed (errno \(errno))."
        case .pathNotAllowed(let path):
            return "Path “\(path)” is not an allowed /dev/cu.* port."
        }
    }
}
