import Darwin
import SickPLSMacTransport

/// Reale Darwin/POSIX-Implementierung von ``ActiveControlSerialPortOpener``
/// über `open(2)` und `termios(4)` -- das **einzige** `O_RDWR` in diesem
/// gesamten Projekt (SICK-011-Auftrag: eigene, TX-fähige Bibliothek statt
/// Erweiterung von `SickPLSMacTransport`, das strukturell `O_RDONLY`
/// bleibt, siehe `DarwinSerialPort.swift` dort).
///
/// Termios-Konfiguration (Baudbits, Rohmodus, Flow-Control) ist bewusst
/// identisch zur RX-only-Implementierung gehalten -- dieselben, in
/// SICK-010 (`review-sick-009.md` Findings N2/N3) korrigierten Schritte,
/// von Anfang an hier übernommen statt denselben Fehler neu zu machen.
///
/// **Ungetestet an echter Hardware**, wie `DarwinSerialPort.swift` in
/// `SickPLSMacTransport` -- SICK-011-Auftrag verbietet ausdrücklich jedes
/// physische Gerät. Nur mit `RawDuplexSyscalls`-Fakes getestet.
public final class DarwinActiveControlSerialPortOpener: ActiveControlSerialPortOpener {
    /// `open(2)`-Flags. `O_RDWR` ist hier -- anders als in
    /// `SickPLSMacTransport` -- die korrekte, bewusste Wahl: Diese
    /// Bibliothek sendet strukturell (``ActiveControlSerialPort/write(_:)``),
    /// ein rein lesender Modus würde das Senden verhindern.
    static let openFlags = O_RDWR | O_NOCTTY | O_NONBLOCK

    public init() {}

    public func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> ActiveControlSerialPort {
        let fileDescriptor = path.withCString { cPath in
            Darwin.open(cPath, Self.openFlags)
        }
        guard fileDescriptor >= 0 else {
            throw SerialPortOpenError.openFailed(errno: errno)
        }

        var options = termios()
        guard tcgetattr(fileDescriptor, &options) == 0 else {
            let capturedErrno = errno
            Darwin.close(fileDescriptor)
            throw SerialPortOpenError.configurationFailed(errno: capturedErrno)
        }

        cfmakeraw(&options)

        guard DarwinBaudRateConfiguration.prepare(&options, baudRate: baudRate) else {
            let capturedErrno = errno
            Darwin.close(fileDescriptor)
            throw SerialPortOpenError.configurationFailed(errno: capturedErrno)
        }

        // 8 Datenbits, gerade Parität, 1 Stopbit, kein Hardware-Flow-Control
        // (SerialPortSettings, `SICK Doku/wire-protocol.md` Abschnitt 1) --
        // identisch zur RX-only-Konfiguration, nur der Zugriffsmodus
        // (O_RDWR statt O_RDONLY) unterscheidet diese Implementierung.
        options.c_cflag |= tcflag_t(CS8)
        options.c_cflag |= tcflag_t(CLOCAL)
        options.c_cflag |= tcflag_t(CREAD)
        options.c_cflag |= tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(PARODD)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        options.c_cflag &= ~tcflag_t(CDTR_IFLOW)
        options.c_cflag &= ~tcflag_t(CDSR_OFLOW)
        options.c_cflag &= ~tcflag_t(CCAR_OFLOW)

        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        options.c_iflag &= ~tcflag_t(INPCK)
        options.c_iflag &= ~tcflag_t(ISTRIP)

        withUnsafeMutableBytes(of: &options.c_cc) { rawControlChars in
            let controlChars = rawControlChars.bindMemory(to: cc_t.self)
            controlChars[Int(VMIN)] = 0
            controlChars[Int(VTIME)] = 0
        }

        guard tcsetattr(fileDescriptor, TCSANOW, &options) == 0 else {
            let capturedErrno = errno
            Darwin.close(fileDescriptor)
            throw SerialPortOpenError.configurationFailed(errno: capturedErrno)
        }


        guard DarwinBaudRateConfiguration.applySpecialRateIfNeeded(
            fileDescriptor: fileDescriptor, baudRate: baudRate
        ) else {
            let capturedErrno = errno
            Darwin.close(fileDescriptor)
            throw SerialPortOpenError.configurationFailed(errno: capturedErrno)
        }

        return DarwinActiveControlSerialPort(fileDescriptor: fileDescriptor, baudRate: baudRate)
    }
}

final class DarwinActiveControlSerialPort: ActiveControlSerialPort {
    private let fileDescriptor: Int32
    private let syscalls: RawDuplexSyscalls
    private let baudRate: SerialPortBaudRate
    private var isClosed = false

    init(
        fileDescriptor: Int32,
        baudRate: SerialPortBaudRate = .baud38400,
        syscalls: RawDuplexSyscalls = DarwinRawDuplexSyscalls()
    ) {
        self.fileDescriptor = fileDescriptor
        self.baudRate = baudRate
        self.syscalls = syscalls
    }

    /// Sicherheitsnetz gegen Deskriptor-Lecks, wie
    /// `DarwinSerialPortFileDescriptor.deinit` in `SickPLSMacTransport`
    /// (SICK-010, Finding M3) -- von Anfang an übernommen.
    deinit {
        markClosed()
    }

    func write(_ bytes: [UInt8]) throws {
        guard !isClosed else {
            throw ActiveControlWriteError.writeFailed(errno: EBADF)
        }
        if baudRate == .baud500000 {
            // Der alte SickPLS-Treiber und der reale Hardwarebeleg verwenden
            // bei 500 kBaud mindestens 55 µs Abstand zwischen Hostbytes.
            for byte in bytes {
                try writeAll([byte])
                Darwin.usleep(55)
            }
            return
        }
        try writeAll(bytes)
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        var remaining = bytes[...]
        while !remaining.isEmpty {
            let result = syscalls.write(fileDescriptor: fileDescriptor, bytes: Array(remaining))
            // `<= 0` statt nur `< 0`: ein `write(2)`, das für einen
            // nicht-leeren Puffer 0 liefert, ist laut POSIX nicht
            // vorgesehen -- defensiv wie einen Fehler behandeln statt in
            // eine Endlosschleife zu laufen.
            guard result.bytesWritten > 0 else {
                throw ActiveControlWriteError.writeFailed(errno: result.capturedErrno)
            }
            remaining = remaining.dropFirst(result.bytesWritten)
        }
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        guard !isClosed else { return .closed }

        let poll = syscalls.poll(fileDescriptor: fileDescriptor, timeoutMilliseconds: timeoutMilliseconds)

        if poll.returnValue < 0 {
            return classify(errno: poll.capturedErrno)
        }
        if poll.returnValue == 0 {
            return .timeout
        }

        let revents = Int32(poll.revents)

        // Dieselbe Reihenfolge wie `DarwinSerialPortFileDescriptor.read`
        // in `SickPLSMacTransport` (SICK-010, Findings M1/M2): POLLIN vor
        // POLLHUP lesen, POLLNVAL gehört zur Stromende-Maske.
        if revents & Int32(POLLIN) != 0 {
            switch syscalls.read(fileDescriptor: fileDescriptor, maxLength: 4096) {
            case .bytes(let bytes):
                return .bytes(bytes)
            case .endOfFile:
                markClosed()
                return .closed
            case .error(let readErrno):
                return classify(errno: readErrno)
            }
        }

        if revents & Int32(POLLHUP | POLLERR | POLLNVAL) != 0 {
            markClosed()
            return .closed
        }

        return .timeout
    }

    func close() {
        markClosed()
    }

    private func classify(errno errorCode: Int32) -> SerialPortReadOutcome {
        switch errorCode {
        case EINTR, EAGAIN, EWOULDBLOCK:
            return .timeout
        default:
            markClosed()
            return .closed
        }
    }

    private func markClosed() {
        guard !isClosed else { return }
        isClosed = true
        syscalls.close(fileDescriptor: fileDescriptor)
    }
}
