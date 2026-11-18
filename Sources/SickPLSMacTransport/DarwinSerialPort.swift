import Darwin

/// Reale Darwin/POSIX-Implementierung von ``SerialPortOpener`` über
/// `open(2)` und `termios(4)`, konfiguriert nach ``SerialPortSettings``
/// (8E1, kein Flow-Control) und der beim Aufruf explizit übergebenen
/// ``SerialPortBaudRate`` (kein Auto-Baud, siehe dortiger Kopfkommentar
/// zur SICK-010-Scope-Änderung).
///
/// **`O_RDONLY`, verbindlich, ohne `O_RDWR`-Fallback** (SICK-010,
/// schließt `review-sick-009.md` Finding M4): Ein früherer Stand dieses
/// Pakets öffnete `O_RDWR` mit der unbelegten Begründung, viele
/// USB-Seriell-Treiber verweigerten Leitungssteuerung sonst. Der Revisor
/// hat das an einem echten Darwin-TTY widerlegt: `open(O_RDONLY)`,
/// `tcgetattr` **und** `tcsetattr` gelingen, Lesen funktioniert, und ein
/// Schreibversuch wird vom **Kernel** mit `EBADF` abgewiesen. RX-only ist
/// in diesem Projekt eine Sicherheitsgrenze (`AGENTS.md`, `TEAM_RULES.md`
/// §7), keine reine API-Konvention — `O_RDONLY` erzwingt sie deshalb vom
/// Betriebssystem statt sie nur auf Swift-Ebene zu versprechen. Kein
/// automatischer Rückfall auf `O_RDWR`: Ein Adapter, der `O_RDONLY`
/// zurückweist, ist ein Fall für einen expliziten, ausdrücklich
/// freizugebenden Folgeschritt, nicht für eine stillschweigend
/// schwächere Voreinstellung.
///
/// **`termios`-Konfiguration an einem echten Darwin-TTY nachgemessen**
/// (`review-sick-009.md`, Revisor-Review über ein Software-Terminalpaar,
/// kein physisches Gerät): alle zwanzig geprüften Flags korrekt gesetzt.
/// Weiterhin **ungetestet an echter Hardware** (SICK-009-Auftrag: „kein
/// physisches Gerät öffnen") — dasselbe offene Altrisiko wie das CRC
/// (SICK-003, Finding M2) und das B0-Trailerbyte (SICK-006): Nur ein
/// konkreter USB-Seriell-Adapter kann zeigen, ob er dieselben Flags und
/// Fehlercodes liefert wie das PTY im Revisor-Lauf.
public final class DarwinSerialPortOpener: SerialPortOpener {
    /// `open(2)`-Flags, als eigene Konstante statt inline verstreut, damit
    /// ein Test unabhängig vom restlichen Öffnungscode belegen kann, dass
    /// hier ausschließlich `O_RDONLY` verwendet wird (kein `O_RDWR`/`O_WRONLY`).
    static let openFlags = O_RDONLY | O_NOCTTY | O_NONBLOCK

    public init() {}

    public func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> SerialPortFileDescriptor {
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

        // Rohmodus: keine kanonische Zeilenverarbeitung, kein Echo, keine
        // Signalzeichen -- zwingend für ein binäres Telegrammprotokoll.
        cfmakeraw(&options)

        guard DarwinBaudRateConfiguration.prepare(&options, baudRate: baudRate) else {
            // review-sick-009.md Finding N2: Rückgabewerte nicht mehr
            // ignorieren, gleiche Behandlung wie tcgetattr/tcsetattr unten.
            let capturedErrno = errno
            Darwin.close(fileDescriptor)
            throw SerialPortOpenError.configurationFailed(errno: capturedErrno)
        }

        // 8 Datenbits, gerade Parität, 1 Stopbit, kein Hardware-Flow-Control
        // (SerialPortSettings, `SICK Doku/wire-protocol.md` Abschnitt 1).
        options.c_cflag |= tcflag_t(CS8)
        options.c_cflag |= tcflag_t(CLOCAL)
        options.c_cflag |= tcflag_t(CREAD)
        options.c_cflag |= tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(PARODD)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        // review-sick-009.md Finding N3: cfmakeraw() fasst die BSD-eigenen
        // Flow-Control-Bits nicht an -- explizit löschen, falls ein Treiber
        // sie vorbelegt liefert (analog zu CRTSCTS oben).
        options.c_cflag &= ~tcflag_t(CDTR_IFLOW)
        options.c_cflag &= ~tcflag_t(CDSR_OFLOW)
        options.c_cflag &= ~tcflag_t(CCAR_OFLOW)

        // Kein Software-Flow-Control (XON/XOFF). INPCK/ISTRIP bleiben aus:
        // Die Payload ist binär -- ein vom Treiber gestripptes 8. Bit
        // würde Daten zerstören; Paritätsprüfung ist Sache des UART.
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        options.c_iflag &= ~tcflag_t(INPCK)
        options.c_iflag &= ~tcflag_t(ISTRIP)

        // VMIN=0/VTIME=0: read(2) liefert sofort zurück, egal ob Daten
        // anliegen -- das eigentliche Warten mit Timeout übernimmt poll(2)
        // in DarwinSerialPortFileDescriptor.read(timeoutMilliseconds:).
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

        return DarwinSerialPortFileDescriptor(fileDescriptor: fileDescriptor)
    }
}

final class DarwinSerialPortFileDescriptor: SerialPortFileDescriptor {
    private let fileDescriptor: Int32
    private let syscalls: RawSerialSyscalls
    private var isClosed = false

    init(fileDescriptor: Int32, syscalls: RawSerialSyscalls = DarwinRawSerialSyscalls()) {
        self.fileDescriptor = fileDescriptor
        self.syscalls = syscalls
    }

    /// review-sick-009.md Finding M3: ein verworfener, nie explizit
    /// geschlossener Port leckte bisher seinen Dateideskriptor (gemessen:
    /// 20 von 20). `deinit` ist das Sicherheitsnetz für jeden Pfad, der
    /// `close()` nicht selbst aufruft.
    deinit {
        markClosed()
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

        // review-sick-009.md Finding M1: Bei gesetztem POLLIN zuerst lesen
        // und erst danach über das Stromende entscheiden. Ein gleichzeitig
        // gemeldetes POLLHUP (gemessen: tritt am Stromende gemeinsam mit
        // POLLIN auf) darf nicht dazu führen, dass noch im Kernel-Puffer
        // stehende Bytes verworfen werden -- genau der Schwanz des Stroms,
        // für dessen saubere Behandlung StreamParser.finish() gebaut wurde.
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

        // Kein POLLIN: ein reiner Hangup/Fehler-Zustand ohne mehr lesbare
        // Bytes. review-sick-009.md Finding M2: POLLNVAL gehört zur
        // Stromende-Maske, nicht nur POLLHUP/POLLERR -- ein ungültiger
        // Deskriptor darf nicht dauerhaft als Timeout erscheinen.
        if revents & Int32(POLLHUP | POLLERR | POLLNVAL) != 0 {
            markClosed()
            return .closed
        }

        // poll() meldete Bereitschaft (returnValue > 0), aber weder POLLIN
        // noch ein Hangup/Fehler-Flag -- laut poll(2) nicht vorgesehen.
        // Defensiv wie einen Timeout behandeln statt zu raten: weder
        // fälschlich schließen noch endlos blockieren.
        return .timeout
    }

    func close() {
        markClosed()
    }

    /// review-sick-009.md Finding M2: `errno` entscheidet, ob ein
    /// Poll-/Lesefehler ein vorübergehendes „gerade kommt nichts"
    /// (`.timeout`) oder ein echtes Stromende (`.closed`) ist. Eine tote
    /// Verbindung (`EBADF`/`EIO`/`ENXIO`/`ENODEV`) darf nicht auf
    /// unbegrenzte Zeit als Timeout erscheinen, sonst leert `finish()`
    /// nie den Restpuffer und die Sitzung endet nie von selbst
    /// (`SICK Doku/fixtures-and-testing.md` Abschnitt 9: „kein
    /// Datenstrom" ist ein dokumentierter Diagnosefall).
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
