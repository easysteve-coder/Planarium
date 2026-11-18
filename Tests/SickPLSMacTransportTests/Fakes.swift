@testable import SickPLSMacTransport

/// Ein vorab festgelegtes Skript von Leseergebnissen -- ersetzt einen
/// echten Dateideskriptor vollständig, damit Tests kein physisches Gerät
/// öffnen (SICK-009-Auftrag).
final class FakeSerialPortFileDescriptor: SerialPortFileDescriptor {
    private var script: [SerialPortReadOutcome]
    private(set) var readCallCount = 0
    private(set) var closeCallCount = 0
    private(set) var requestedTimeouts: [Int32] = []

    init(script: [SerialPortReadOutcome]) {
        self.script = script
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        readCallCount += 1
        requestedTimeouts.append(timeoutMilliseconds)
        guard !script.isEmpty else { return .closed }
        return script.removeFirst()
    }

    func close() {
        closeCallCount += 1
    }
}

/// Liefert immer denselben Fake-Deskriptor und merkt sich, mit welchem
/// Pfad `open(atPath:baudRate:)` aufgerufen wurde -- belegt, dass kein
/// Auto-Scan stattfindet (SICK-009-Auftrag) und keine Baudrate erraten
/// wird (SICK-010-Scope-Änderung).
final class FakeSerialPortOpener: SerialPortOpener {
    private let fileDescriptor: SerialPortFileDescriptor
    private(set) var requestedPaths: [String] = []
    private(set) var requestedBaudRates: [SerialPortBaudRate] = []
    var errorToThrow: Error?

    init(fileDescriptor: SerialPortFileDescriptor) {
        self.fileDescriptor = fileDescriptor
    }

    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> SerialPortFileDescriptor {
        requestedPaths.append(path)
        requestedBaudRates.append(baudRate)
        if let errorToThrow {
            throw errorToThrow
        }
        return fileDescriptor
    }
}

/// Ersetzt `/dev` durch eine feste Liste von Einträgen.
final class FakeDirectoryLister: DirectoryLister {
    private let entries: [String]

    init(entries: [String]) {
        self.entries = entries
    }

    func entryNames(inDirectory path: String) -> [String] {
        entries
    }
}
