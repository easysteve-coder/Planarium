@testable import SickPLSActiveControl
import SickPLSMacTransport
import Darwin

/// Ein vorab festgelegtes Skript von rohen `poll`/`read`/`write`-
/// Ergebnissen -- ersetzt die tatsächlichen Syscalls vollständig, damit
/// `DarwinActiveControlSerialPort` ohne echten Dateideskriptor oder
/// Pseudo-Terminal getestet werden kann (analog zu
/// `FakeRawSerialSyscalls` in `SickPLSMacTransportTests`, SICK-010).
final class FakeRawDuplexSyscalls: RawDuplexSyscalls {
    private var pollScript: [RawDuplexPollResult]
    private var readScript: [RawDuplexReadResult]
    private var writeScript: [RawDuplexWriteResult]
    private(set) var pollCallCount = 0
    private(set) var readCallCount = 0
    private(set) var writeCallCount = 0
    private(set) var writtenChunks: [[UInt8]] = []
    private(set) var closeCallCount = 0

    init(
        pollScript: [RawDuplexPollResult] = [],
        readScript: [RawDuplexReadResult] = [],
        writeScript: [RawDuplexWriteResult] = []
    ) {
        self.pollScript = pollScript
        self.readScript = readScript
        self.writeScript = writeScript
    }

    func poll(fileDescriptor: Int32, timeoutMilliseconds: Int32) -> RawDuplexPollResult {
        pollCallCount += 1
        guard !pollScript.isEmpty else {
            return RawDuplexPollResult(returnValue: 0, revents: 0, capturedErrno: 0)
        }
        return pollScript.removeFirst()
    }

    func read(fileDescriptor: Int32, maxLength: Int) -> RawDuplexReadResult {
        readCallCount += 1
        guard !readScript.isEmpty else { return .endOfFile }
        return readScript.removeFirst()
    }

    func write(fileDescriptor: Int32, bytes: [UInt8]) -> RawDuplexWriteResult {
        writeCallCount += 1
        writtenChunks.append(bytes)
        guard !writeScript.isEmpty else {
            return RawDuplexWriteResult(bytesWritten: bytes.count, capturedErrno: 0)
        }
        return writeScript.removeFirst()
    }

    func close(fileDescriptor: Int32) {
        closeCallCount += 1
    }
}

/// Ein vorab festgelegtes Skript von Leseergebnissen plus ein
/// Schreibprotokoll -- ersetzt einen echten TX-fähigen Dateideskriptor
/// vollständig, damit Tests kein physisches Gerät öffnen
/// (SICK-011-Auftrag).
final class FakeActiveControlSerialPort: ActiveControlSerialPort {
    private var readScript: [SerialPortReadOutcome]
    private(set) var writeCallCount = 0
    private(set) var writtenChunks: [[UInt8]] = []
    private(set) var closeCallCount = 0
    /// Der `timeoutMilliseconds`-Wert jedes `read`-Aufrufs, in Aufrufreihenfolge --
    /// belegt, dass `BaudProbe` das jeweilige Resttimeout übergibt statt
    /// bei jedem Aufruf erneut das volle Gesamttimeout (SICK-011a).
    private(set) var readTimeoutsRequested: [Int32] = []
    var errorToThrowOnWrite: Error?

    init(readScript: [SerialPortReadOutcome]) {
        self.readScript = readScript
    }

    func write(_ bytes: [UInt8]) throws {
        writeCallCount += 1
        writtenChunks.append(bytes)
        if let errorToThrowOnWrite {
            throw errorToThrowOnWrite
        }
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        readTimeoutsRequested.append(timeoutMilliseconds)
        guard !readScript.isEmpty else { return .closed }
        return readScript.removeFirst()
    }

    func close() {
        closeCallCount += 1
    }
}

/// Ein vorab festgelegtes Skript monotoner Zeitwerte -- ersetzt
/// `DarwinMonotonicClock`, damit die harte Gesamtfrist-Logik in
/// `BaudProbe.probeOnce` ohne reale Sleeps deterministisch getestet
/// werden kann (SICK-011a). Liefert nach Skriptende wiederholt den
/// letzten Wert, statt abzustürzen -- ein Test, der mehr Aufrufe braucht
/// als er skriptet hat, würde sonst mit einem irreführenden Crash statt
/// einer aussagekräftigen Assertion scheitern.
final class FakeMonotonicClock: MonotonicClock {
    private var scriptedMilliseconds: [Int64]
    private var lastReturnedMilliseconds: Int64
    private(set) var callCount = 0

    init(scriptedMilliseconds: [Int64]) {
        precondition(!scriptedMilliseconds.isEmpty, "FakeMonotonicClock braucht mindestens einen Zeitwert")
        self.scriptedMilliseconds = scriptedMilliseconds
        self.lastReturnedMilliseconds = scriptedMilliseconds[0]
    }

    func nowMilliseconds() -> Int64 {
        callCount += 1
        if !scriptedMilliseconds.isEmpty {
            lastReturnedMilliseconds = scriptedMilliseconds.removeFirst()
        }
        return lastReturnedMilliseconds
    }
}

/// Liefert vorab festgelegte Fake-Ports für aufeinanderfolgende
/// `open(atPath:baudRate:)`-Aufrufe (ein Fake je Baudraten-Kandidat) und
/// merkt sich Pfad/Baudrate jedes Aufrufs -- belegt, dass
/// ``BaudProbe/run`` pro Kandidat frisch öffnet und keine Baudrate
/// errät.
final class FakeActiveControlSerialPortOpener: ActiveControlSerialPortOpener {
    private var portsToReturn: [ActiveControlSerialPort]
    private(set) var requestedPaths: [String] = []
    private(set) var requestedBaudRates: [SerialPortBaudRate] = []
    var errorToThrow: Error?

    init(portsToReturn: [ActiveControlSerialPort]) {
        self.portsToReturn = portsToReturn
    }

    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> ActiveControlSerialPort {
        requestedPaths.append(path)
        requestedBaudRates.append(baudRate)
        if let errorToThrow {
            throw errorToThrow
        }
        guard !portsToReturn.isEmpty else {
            fatalError("FakeActiveControlSerialPortOpener: kein weiterer Fake-Port vorbereitet")
        }
        return portsToReturn.removeFirst()
    }
}
