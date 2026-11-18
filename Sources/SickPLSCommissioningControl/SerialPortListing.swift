import SickPLSMacTransport

/// Conservative name evidence only: an unknown callout remains a support port.
/// No device is opened or probed to classify it.
public enum ScannerSerialPortKind: Equatable, Sendable {
    case usbSerial, other
    public static func classify(_ path: String) -> Self {
        guard path.hasPrefix("/dev/cu.") else { return .other }
        let name = path.dropFirst("/dev/cu.".count).lowercased()
        return ["usbserial", "usbmodem", "slab_usbtouart", "wchusbserial"].contains { name.hasPrefix($0) }
            ? .usbSerial : .other
    }
}

/// Woher die auswählbaren Portpfade kommen (SICK-032a).
///
/// **Injizierbar, damit die Nachweise ohne echte Geräteliste laufen.**
/// Die produktive Umsetzung fragt ausschließlich
/// ``SerialPortEnumeration`` — also `/dev/cu.*` und **nie** `/dev/tty.*`
/// (SICK-009).
public protocol SerialPortListing {
    func availablePortPaths() -> [String]
}

/// Die produktive Umsetzung. **Sie wählt nichts aus und öffnet nichts.**
public struct SystemSerialPortListing: SerialPortListing {
    public init() {}

    public func availablePortPaths() -> [String] {
        SerialPortEnumeration.availablePortPaths()
    }
}
