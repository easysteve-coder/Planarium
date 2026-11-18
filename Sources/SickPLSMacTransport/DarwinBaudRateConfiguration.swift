import Darwin

/// Gemeinsame Darwin-Konfiguration für Standard- und Sonderbaudraten.
/// Exakt 500000 Baud wird nach `tcsetattr` mit `IOSSIOSPEED` gesetzt.
public enum DarwinBaudRateConfiguration {
    // _IOW('T', 2, speed_t), definiert in IOKit/serial/ioss.h.
    private static let setArbitrarySpeedRequest: UInt = 0x80045402

    public static func prepare(_ options: inout termios, baudRate: SerialPortBaudRate) -> Bool {
        let termiosRate: speed_t = baudRate == .baud500000 ? speed_t(B38400) : speed_t(baudRate.rawValue)
        return cfsetispeed(&options, termiosRate) == 0
            && cfsetospeed(&options, termiosRate) == 0
    }

    public static func applySpecialRateIfNeeded(
        fileDescriptor: Int32,
        baudRate: SerialPortBaudRate
    ) -> Bool {
        guard baudRate == .baud500000 else { return true }
        var exactRate = baudRate.rawValue
        return withUnsafeMutablePointer(to: &exactRate) { pointer in
            ioctl(fileDescriptor, setArbitrarySpeedRequest, pointer)
        } == 0
    }
}
