import Darwin

/// Ergebnis eines rohen `poll(2)`-Aufrufs -- Datentyp statt Seiteneffekt,
/// macht die Poll-dann-Read-Entscheidungslogik testbar. Eigener Typ
/// dieses Pakets (nicht aus `SickPLSMacTransport` importiert, das seine
/// entsprechenden Typen absichtlich intern hält -- SICK-011-Auftrag:
/// „NICHT RX-Transport erweitern", auch nicht durch Wiederverwendung
/// interner Test-Infrastruktur über Modulgrenzen hinweg).
struct RawDuplexPollResult: Equatable {
    /// `< 0` Fehler, `0` Timeout, `> 0` bereit.
    let returnValue: Int32
    /// `revents`, nur aussagekräftig wenn `returnValue > 0`.
    let revents: Int16
    /// `errno` unmittelbar nach `poll(2)`, nur gültig wenn `returnValue < 0`.
    let capturedErrno: Int32
}

/// Ergebnis eines rohen `read(2)`-Aufrufs.
enum RawDuplexReadResult: Equatable {
    case bytes([UInt8])
    /// `read(2)` liefert `0` -- echtes Stromende.
    case endOfFile
    /// `read(2)` liefert `< 0`; `errno` ist der rohe POSIX-Fehlercode.
    case error(errno: Int32)
}

/// Ergebnis eines rohen `write(2)`-Aufrufs.
struct RawDuplexWriteResult: Equatable {
    /// `>= 0`: tatsächlich geschriebene Bytes. `< 0`: Fehler, `errno`
    /// unten ist dann gültig.
    let bytesWritten: Int
    let capturedErrno: Int32
}

/// Die rohen Syscalls hinter einem geöffneten, TX-fähigen
/// Dateideskriptor, injizierbar für Tests -- analog zu
/// `RawSerialSyscalls` in `SickPLSMacTransport` (SICK-010), aber um
/// `write` erweitert, weil dieses Paket (anders als jenes) TX-fähig ist.
protocol RawDuplexSyscalls {
    func poll(fileDescriptor: Int32, timeoutMilliseconds: Int32) -> RawDuplexPollResult
    func read(fileDescriptor: Int32, maxLength: Int) -> RawDuplexReadResult
    func write(fileDescriptor: Int32, bytes: [UInt8]) -> RawDuplexWriteResult
    func close(fileDescriptor: Int32)
}

/// Reale Implementierung über `poll(2)`/`read(2)`/`write(2)`/`close(2)`.
struct DarwinRawDuplexSyscalls: RawDuplexSyscalls {
    func poll(fileDescriptor: Int32, timeoutMilliseconds: Int32) -> RawDuplexPollResult {
        var pollDescriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        let returnValue = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
        return RawDuplexPollResult(returnValue: returnValue, revents: pollDescriptor.revents, capturedErrno: errno)
    }

    func read(fileDescriptor: Int32, maxLength: Int) -> RawDuplexReadResult {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        if bytesRead < 0 {
            return .error(errno: errno)
        }
        if bytesRead == 0 {
            return .endOfFile
        }
        return .bytes(Array(buffer[0..<bytesRead]))
    }

    func write(fileDescriptor: Int32, bytes: [UInt8]) -> RawDuplexWriteResult {
        let bytesWritten = bytes.withUnsafeBytes { rawBuffer -> Int in
            Darwin.write(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        return RawDuplexWriteResult(bytesWritten: bytesWritten, capturedErrno: errno)
    }

    func close(fileDescriptor: Int32) {
        Darwin.close(fileDescriptor)
    }
}
