import Foundation
import SickPLSActiveControl
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSCommissioning

// Testgrundlage für die Transportadaption (SICK-031).
//
// **Kein echter Port, kein Gerät, keine Uhr, kein Byte an Hardware.**
// Alles läuft gegen Fakes mit injizierter monotoner Zeit; PTY- und
// Hardwareproben gibt es hier ausdrücklich nicht.

/// Jede Handlung, die der Executor an der Transportgrenze vornimmt — in
/// **Reihenfolge**.
///
/// Die Reihenfolge ist der eigentliche Prüfgegenstand: „vor dem Senden
/// geleert" ist eine Aussage über sie, keine über einen Zählwert.
enum TransportOperation: Equatable {
    case open(SerialPortBaudRate)
    case close
    case flush
    case write([UInt8])
    case read(timeoutMilliseconds: Int32)
}

/// Eine Uhr, die ausschließlich der Test bewegt.
final class TestMonotonicClock: MonotonicClock {
    private(set) var millis: Int64

    init(startingAt millis: Int64 = 0) {
        self.millis = millis
    }

    func nowMilliseconds() -> Int64 { millis }

    func advance(by delta: Int64) { millis += delta }
}

/// Ein aufzeichnender, skriptbarer Transport.
///
/// **Er modelliert die Grenze, nicht das Gerät**: Was zurückkommt, sagt
/// das Skript; was hinausging, steht im Protokoll.
final class FakeCommissioningTransport: CommissioningTransport {

    /// Jede Handlung in Reihenfolge.
    ///
    /// Schreibbar, damit ein Test das Protokoll vor dem eigentlich
    /// geprüften Abschnitt zurücksetzen kann -- die Vorbereitung ist
    /// sonst nicht vom Prüfgegenstand zu trennen.
    var log: [TransportOperation] = []
    /// Antworten, in dieser Reihenfolge je Leseaufruf verbraucht. Ist es
    /// leer, läuft die Frist ab.
    var readScript: [SerialPortReadOutcome] = []
    /// Wie viel Zeit ein Leseaufruf mit skriptierter Antwort verbraucht.
    var millisPerScriptedRead: Int64 = 10
    /// Bestehende Executor-Tests konzentrieren sich auf die nachfolgende
    /// Login-/Baudlogik. Der neu vorgeschaltete Einstellungsmodus wird
    /// dort standardmäßig wie das reale ACK beantwortet; eigene Tests
    /// können dies abschalten und seine Fehlerfälle skripten.
    var autoAcknowledgeSettingsMode = true

    var failNextOpen: CommissioningTransportError?
    var failNextClose: CommissioningTransportError?
    var failNextWrite: CommissioningTransportError?
    /// **Bleibt stehen, statt sich nach dem ersten Wurf zu löschen**
    /// (anders als `failNextClose`) — für Nachweise, dass ein Port
    /// bleibt, bis das Schließen wirklich gelingt (SICK-0330a-1,
    /// Pflichtnachweis 7).
    var alwaysFailClose: CommissioningTransportError?

    private let portStateLock = NSLock()
    private var openState = false
    private var openCountState = 0
    private var closeCountState = 0

    var isOpen: Bool {
        portStateLock.lock()
        defer { portStateLock.unlock() }
        return openState
    }

    var openCount: Int {
        portStateLock.lock()
        defer { portStateLock.unlock() }
        return openCountState
    }

    var closeCount: Int {
        portStateLock.lock()
        defer { portStateLock.unlock() }
        return closeCountState
    }

    let clock: TestMonotonicClock

    /// Wird als **Erstes** in jedem ``read(timeoutMilliseconds:)``-Aufruf
    /// gerufen — der deterministische Weg, um „ein Abbruch trifft
    /// während eines laufenden Reads ein" nachzubilden, ohne echte
    /// Nebenläufigkeit zu brauchen (SICK-0330a-1, Pflichtnachweise 3/4).
    var onRead: (() -> Void)?

    init(clock: TestMonotonicClock) {
        self.clock = clock
    }

    // MARK: - CommissioningTransport

    func openPort(baudRate: SerialPortBaudRate) throws {
        log.append(.open(baudRate))
        if let failure = failNextOpen {
            failNextOpen = nil
            throw failure
        }
        // **Dieselbe Regel wie im echten Adapter** -- ein zweites Öffnen
        // ohne Schließen ist ein Fehler, keine stille Wiederverwendung.
        portStateLock.lock()
        defer { portStateLock.unlock() }
        guard !openState else { throw CommissioningTransportError.portAlreadyOpen }
        openState = true
        openCountState += 1
    }

    func closePort() throws {
        log.append(.close)
        if let failure = alwaysFailClose {
            throw failure
        }
        if let failure = failNextClose {
            failNextClose = nil
            throw failure
        }
        portStateLock.lock()
        defer { portStateLock.unlock() }
        if openState { closeCountState += 1 }
        openState = false
    }

    func flushReceiveBuffer() {
        log.append(.flush)
    }

    /// Der monotone Zeitpunkt **jeder** Sendung, in Reihenfolge.
    ///
    /// Ohne ihn ließe sich die Kernzusage von SICK-032a3a nicht prüfen:
    /// „zwischen Login 1 und Login 2 liegt mindestens das volle
    /// Lesefenster". Ein Zählwert allein sagt darüber nichts.
    private(set) var writeTimestamps: [Int64] = []

    func write(_ bytes: [UInt8]) throws {
        log.append(.write(bytes))
        writeTimestamps.append(clock.millis)
        if let failure = failNextWrite {
            failNextWrite = nil
            throw failure
        }
        portStateLock.lock()
        let openState = self.openState
        portStateLock.unlock()
        guard openState else { throw CommissioningTransportError.portNotOpen }
        if autoAcknowledgeSettingsMode,
           bytes.count > 5,
           bytes[1] == CommissioningRecipe.r26.settingsModeAddress.rawValue,
           bytes[4] == 0x20, bytes[5] == 0x30 {
            readScript.insert(.frame(acknowledgementFrame(status: 0x00)), at: 0)
        }
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        onRead?()
        log.append(.read(timeoutMilliseconds: timeoutMilliseconds))
        guard !readScript.isEmpty else {
            // Nichts mehr im Skript: Die volle Restfrist verstreicht.
            clock.advance(by: Int64(timeoutMilliseconds))
            return .timeout
        }
        clock.advance(by: millisPerScriptedRead)
        return readScript.removeFirst()
    }

    // MARK: - Auswertungshilfen

    var writtenPayloads: [[UInt8]] {
        log.compactMap { if case .write(let bytes) = $0 { return bytes } else { return nil } }
    }

    var openedRates: [SerialPortBaudRate] {
        log.compactMap { if case .open(let rate) = $0 { return rate } else { return nil } }
    }

    /// Nur Öffnen/Schließen — die Portsequenz ohne Lese-/Schreibrauschen.
    var portSequence: [TransportOperation] {
        log.filter { operation in
            switch operation {
            case .open, .close: return true
            case .flush, .write, .read: return false
            }
        }
    }

    /// Steht **vor** jedem Schreiben ein Leeren, ohne etwas dazwischen?
    var everyWriteIsPrecededByAFlush: Bool {
        for (index, operation) in log.enumerated() {
            guard case .write = operation else { continue }
            guard index > 0, log[index - 1] == .flush else { return false }
        }
        return true
    }
}

// MARK: - Antwortframes

/// Die gültige Identitätsantwort `0xB1` — als **echter** Frame über den
/// bestehenden Vertrag, nie als abgeschriebene Bytefolge.
func identityResponseFrame() -> Frame {
    try! Frame.build(address: 0x81, payload: [IdentityProbe.expectedResponseCommandByte, 0x41, 0x42])
}

/// Eine Antwort mit einem anderen Kommandobyte.
func unexpectedResponseFrame(commandByte: UInt8) -> Frame {
    try! Frame.build(address: 0x81, payload: [commandByte, 0x00])
}

extension SerialPortReadOutcome {
    /// Ein vollständiger Frame in einem Lesevorgang.
    static func frame(_ frame: Frame) -> SerialPortReadOutcome {
        .bytes(frame.encoded())
    }
}

/// Das **Ende** eines B0-Frames ohne dessen Anfang — genau das, was nach
/// dem Leeren des Empfangspuffers als Erstes hereinkommt, wenn der
/// Scanner gerade mitten in einem Profil sendete (SICK-031a, E1).
///
/// Geschnitten wird **hinter dem letzten enthaltenen STX**, damit der
/// Rest garantiert keinen Rahmenanfang mehr trägt und `StreamParser`
/// jedes Byte davon als Rauschen zählt. Ohne diese Schnittstelle hinge
/// der Test daran, ob zufällig ein `0x02` in Payload oder Prüfsumme
/// steht.
func truncatedScanProfileTail() -> [UInt8] {
    let encoded = scanProfileFrame().encoded()
    let lastStart = encoded.lastIndex(of: SickPLSFrameConstants.startOfText) ?? 0
    return Array(encoded[(lastStart + 1)...])
}

/// Ein **genuin unvollständiger** STX-Kandidat, hinter dem ein bereits
/// vollständiger, gültiger B0-Frame steht (SICK-0330a-1-K1, H1).
///
/// **Genuin unvollständig heißt hier:** ein vollständiger, korrekt
/// gelesener Header (STX, Adresse, Längenfeld) erklärt einen deklarierten
/// Längenwert (`100`, weit unter `payloadMaxLength`, damit kein
/// `.payloadLengthExceedsMaximum` entsteht), für den selbst mitsamt dem
/// dahinterliegenden vollständigen B0-Frame **nicht genug Bytes**
/// vorliegen — `Frame.decodePrefix(from:)` liefert deshalb zuverlässig
/// `.incompleteFrame`, unabhängig davon, was danach im Puffer steht.
/// `feed(...)` bricht bei diesem Kandidaten deshalb sofort ab (Batch-
/// Semantik erst bei `finish()`), ohne den vollständigen Frame dahinter
/// je zu betrachten -- der einzige Weg, ihn zu bergen, ist der finale
/// Drain.
///
/// Adresse (`0x00`) und Längenfeld-Bytes (`0x64`, `0x00`) sind bewusst
/// so gewählt, dass keines davon zufällig selbst `SickPLSFrameConstants
/// .startOfText` (`0x02`) trägt -- sonst fände die STX-Suche nach dem
/// Verwerfen des führenden Kandidaten ein falsches, zu frühes STX.
func bytesWithABlockedTrailingB0Frame() -> [UInt8] {
    let incompleteHeaderDeclaringMoreThanIsAvailable: [UInt8] = [
        SickPLSFrameConstants.startOfText, 0x00, 0x64, 0x00
    ]
    return incompleteHeaderDeclaringMoreThanIsAvailable + scanProfileFrame().encoded()
}

// MARK: - Die reale Adapterseite

/// Ein aufzeichnender TX-Port hinter ``ActiveControlCommissioningTransport``.
///
/// **Er ist kein Gerät** — er hält nur fest, was der Adapter täte, und
/// gibt zurück, was der Test vorgibt.
final class SpyActiveControlSerialPort: ActiveControlSerialPort {
    private(set) var writtenPayloads: [[UInt8]] = []
    private(set) var readTimeouts: [Int32] = []
    private(set) var closeCount = 0
    var readScript: [SerialPortReadOutcome] = []
    var writeError: Error?
    /// Optional: Bei Stille verstreicht die **volle** angeforderte Zeit.
    ///
    /// Seit SICK-031a (E2) ist ein `.timeout` für den Executor kein
    /// Fristende mehr, sondern führt zurück in die Restfrist-Schleife.
    /// Ein Spion, der sofort und ohne Zeitverbrauch `.timeout` liefert,
    /// ließe sie deshalb nie enden — dieselbe Zeitbasis mitzuführen ist
    /// hier keine Bequemlichkeit, sondern modelliert die Grenze richtig.
    var clock: TestMonotonicClock?

    func write(_ bytes: [UInt8]) throws {
        if let writeError { throw writeError }
        writtenPayloads.append(bytes)
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        readTimeouts.append(timeoutMilliseconds)
        guard !readScript.isEmpty else {
            clock?.advance(by: Int64(timeoutMilliseconds))
            return .timeout
        }
        return readScript.removeFirst()
    }

    func close() {
        closeCount += 1
    }
}

final class SpyActiveControlSerialPortOpener: ActiveControlSerialPortOpener {
    private(set) var openedPaths: [String] = []
    private(set) var openedRates: [SerialPortBaudRate] = []
    var openError: Error?
    /// Der jeweils zuletzt gelieferte Port.
    private(set) var lastPort: SpyActiveControlSerialPort?
    /// Wie der nächste Port skriptiert sein soll.
    var nextReadScript: [SerialPortReadOutcome] = []
    /// Wird an jeden erzeugten Port durchgereicht (siehe dort).
    var clock: TestMonotonicClock?

    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> ActiveControlSerialPort {
        openedPaths.append(path)
        openedRates.append(baudRate)
        if let openError { throw openError }
        let port = SpyActiveControlSerialPort()
        port.readScript = nextReadScript
        port.clock = clock
        nextReadScript = []
        lastPort = port
        return port
    }
}
