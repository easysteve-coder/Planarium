import Darwin

/// Ergebnis eines rohen `poll(2)`-Aufrufs, als reine Daten statt als
/// Seiteneffekt -- macht die exakte Entscheidungslogik in
/// ``DarwinSerialPortFileDescriptor`` testbar, ohne einen echten
/// Dateideskriptor zu brauchen (SICK-010-Auftrag, schließt
/// `review-sick-009.md` Findings M1/M2).
struct RawPollResult: Equatable {
    /// Roher `poll(2)`-Rückgabewert: `< 0` Fehler, `0` Timeout, `> 0` bereit.
    let returnValue: Int32
    /// `revents`, nur aussagekräftig wenn `returnValue > 0`.
    let revents: Int16
    /// `errno` unmittelbar nach `poll(2)`, nur gültig wenn `returnValue < 0`.
    let capturedErrno: Int32
}

/// Ergebnis eines rohen `read(2)`-Aufrufs.
enum RawReadResult: Equatable {
    case bytes([UInt8])
    /// `read(2)` liefert `0` -- echtes Stromende.
    case endOfFile
    /// `read(2)` liefert `< 0`; `errno` ist der rohe POSIX-Fehlercode.
    case error(errno: Int32)
}

/// Die rohen Syscalls hinter einem geöffneten Dateideskriptor, injizierbar
/// für Tests. Diese Grenze ist bewusst enger als
/// ``SerialPortFileDescriptor`` (SICK-009): Sie erlaubt, die exakte
/// `poll`/`read`-Reihenfolge und Fehlerklassifikation aus
/// `DarwinSerialPortFileDescriptor` zu testen, ohne reale Syscalls
/// auszuführen oder ein physisches Gerät bzw. ein Pseudo-Terminal zu
/// öffnen.
protocol RawSerialSyscalls {
    func poll(fileDescriptor: Int32, timeoutMilliseconds: Int32) -> RawPollResult
    func read(fileDescriptor: Int32, maxLength: Int) -> RawReadResult
    func close(fileDescriptor: Int32)
}

/// Reale Implementierung über `poll(2)`/`read(2)`/`close(2)`.
struct DarwinRawSerialSyscalls: RawSerialSyscalls {
    func poll(fileDescriptor: Int32, timeoutMilliseconds: Int32) -> RawPollResult {
        var pollDescriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        let returnValue = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
        return RawPollResult(returnValue: returnValue, revents: pollDescriptor.revents, capturedErrno: errno)
    }

    func read(fileDescriptor: Int32, maxLength: Int) -> RawReadResult {
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

    func close(fileDescriptor: Int32) {
        Darwin.close(fileDescriptor)
    }
}
