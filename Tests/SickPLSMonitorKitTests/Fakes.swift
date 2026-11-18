import Foundation
import SickPLSMacTransport

/// Fakes für `SerialPortOpener`/`SerialPortFileDescriptor` -- anders als
/// die gleichnamigen Fakes in `SickPLSMacTransportTests`/
/// `SickPLSActiveControlTests` werden diese hier tatsächlich von einem
/// echten Hintergrund-Thread aus aufgerufen (``ReadLoopWorker``, SICK-012),
/// nicht nur synchron vom Testcode selbst -- deshalb mit `NSLock`
/// abgesichert statt wie dort unsynchronisiert.

final class FakeSerialPortFileDescriptor: SerialPortFileDescriptor {
    private let lock = NSLock()
    private var readScript: [SerialPortReadOutcome]
    private var _closeCallCount = 0
    /// Wie lange ``close()`` braucht, **bevor** der Zähler hochgeht
    /// (SICK-030a, Default `0`: keine Wirkung auf bestehende Tests).
    ///
    /// Damit wird „der Port wird gerade geschlossen" zu einem sichtbaren
    /// Zeitfenster. Ohne dieses Fenster kann kein Test beweisen, dass
    /// die Freigabe **nach** dem Schließen kommt: Die Freigabe läuft über
    /// `DispatchQueue.main.async`, und dieser Umweg dauert länger als ein
    /// sofort zurückkehrendes `close()` -- eine falsche Reihenfolge im
    /// Lesethread wäre beim Eintreffen längst wieder richtig aussortiert.
    private let closeDelaySeconds: TimeInterval

    var closeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _closeCallCount
    }

    init(readScript: [SerialPortReadOutcome], closeDelaySeconds: TimeInterval = 0) {
        self.readScript = readScript
        self.closeDelaySeconds = closeDelaySeconds
    }

    /// Wartet bei einem `.timeout`-Ergebnis tatsächlich `timeoutMilliseconds`,
    /// wie es echte Hardware täte -- ohne diese Pause würde der
    /// Hintergrund-Leseloop ein endliches Skript in Mikrosekunden
    /// durchlaufen und Zwischenzustände (etwa `.connected`, bevor der
    /// erste Timeout kommt) für einen von außen beobachtenden Test praktisch
    /// unsichtbar machen. `.bytes`/`.closed` liefern dagegen sofort, wie es
    /// echte Hardware bei tatsächlich vorliegenden Daten/einem echten
    /// Stromende auch täte.
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        let outcome: SerialPortReadOutcome = {
            lock.lock()
            defer { lock.unlock() }
            guard !readScript.isEmpty else { return .closed }
            return readScript.removeFirst()
        }()
        if outcome == .timeout {
            Thread.sleep(forTimeInterval: TimeInterval(timeoutMilliseconds) / 1000.0)
        }
        return outcome
    }

    func close() {
        if closeDelaySeconds > 0 {
            Thread.sleep(forTimeInterval: closeDelaySeconds)
        }
        lock.lock()
        _closeCallCount += 1
        lock.unlock()
    }
}

final class FakeSerialPortOpener: SerialPortOpener {
    private let lock = NSLock()
    private var portsToReturn: [SerialPortFileDescriptor]
    var errorToThrow: Error?
    private var _requestedPaths: [String] = []
    private var _requestedBaudRates: [SerialPortBaudRate] = []

    var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedPaths
    }

    var requestedBaudRates: [SerialPortBaudRate] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedBaudRates
    }

    init(portsToReturn: [SerialPortFileDescriptor]) {
        self.portsToReturn = portsToReturn
    }

    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> SerialPortFileDescriptor {
        lock.lock()
        _requestedPaths.append(path)
        _requestedBaudRates.append(baudRate)
        let error = errorToThrow
        lock.unlock()

        if let error {
            throw error
        }

        lock.lock()
        defer { lock.unlock() }
        guard !portsToReturn.isEmpty else {
            fatalError("FakeSerialPortOpener: kein weiterer Fake-Port vorbereitet")
        }
        return portsToReturn.removeFirst()
    }
}
