import SickPLSActiveControl
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl

// Testgrundlage für `StandardConnectionRun` (SICK-0330a).
//
// **Kein echter Port, kein Gerät, keine Uhr, kein TX/RX, keine PTY.**
// Alles läuft gegen Fakes mit injizierter monotoner Zeit -- dasselbe
// Muster wie `CommissioningTransportTestSupport.swift`
// (`SickPLSCommissioningTests`), hier neu geschrieben, weil Testziele
// keine internen Symbole über Zielgrenzen hinweg teilen.

/// Jede Handlung, die der Lauf an der Transportgrenze vornimmt -- in
/// **Reihenfolge**.
enum StandardConnectionTransportOperation: Equatable {
    case open(SerialPortBaudRate)
    case close
    case flush
    case write([UInt8])
    case read(timeoutMilliseconds: Int32)
}

/// Ein aufzeichnender, skriptbarer Transport für den Standardverbindungslauf.
///
/// **Er modelliert die Grenze, nicht das Gerät**: Was zurückkommt, sagt
/// das Skript; was hinausging, steht im Protokoll.
final class ScriptedStandardConnectionTransport: CommissioningTransport {

    var log: [StandardConnectionTransportOperation] = []
    /// Antworten, in dieser Reihenfolge je Leseaufruf verbraucht. Ist es
    /// leer, läuft die Frist ab.
    var readScript: [SerialPortReadOutcome] = []
    var millisPerScriptedRead: Int64 = 10
    var autoAcknowledgeSettingsMode = true

    var failNextOpen: CommissioningTransportError?
    var failNextClose: CommissioningTransportError?
    var failNextWrite: CommissioningTransportError?
    /// **Bleibt stehen** (anders als `failNextClose`) -- für Nachweise,
    /// dass ein Port bleibt, bis das Schließen wirklich gelingt.
    var alwaysFailClose: CommissioningTransportError?

    private(set) var isOpen = false
    private(set) var openCount = 0
    private(set) var closeCount = 0
    private(set) var writeTimestamps: [Int64] = []
    private(set) var flushCount = 0

    let clock: TestMonotonicClock

    /// Wird als **Erstes** in jedem ``read(timeoutMilliseconds:)``-Aufruf
    /// gerufen -- der deterministische Weg, um „ein Abbruch trifft
    /// während eines laufenden Reads ein" nachzubilden, ohne echte
    /// Nebenläufigkeit zu brauchen.
    var onRead: (() -> Void)?

    init(clock: TestMonotonicClock) {
        self.clock = clock
    }

    func openPort(baudRate: SerialPortBaudRate) throws {
        log.append(.open(baudRate))
        if let failure = failNextOpen {
            failNextOpen = nil
            throw failure
        }
        guard !isOpen else { throw CommissioningTransportError.portAlreadyOpen }
        isOpen = true
        openCount += 1
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
        if isOpen { closeCount += 1 }
        isOpen = false
    }

    func flushReceiveBuffer() {
        log.append(.flush)
        flushCount += 1
    }

    func write(_ bytes: [UInt8]) throws {
        log.append(.write(bytes))
        writeTimestamps.append(clock.nowMilliseconds())
        if let failure = failNextWrite {
            failNextWrite = nil
            throw failure
        }
        guard isOpen else { throw CommissioningTransportError.portNotOpen }
        if autoAcknowledgeSettingsMode,
           bytes.count > 5,
           bytes[1] == CommissioningRecipe.r26.settingsModeAddress.rawValue,
           bytes[4] == 0x20, bytes[5] == 0x30 {
            readScript.insert(.standardFrame(standardAcknowledgementFrame()), at: 0)
        }
    }

    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        onRead?()
        log.append(.read(timeoutMilliseconds: timeoutMilliseconds))
        guard !readScript.isEmpty else {
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

    var portSequence: [StandardConnectionTransportOperation] {
        log.filter { operation in
            switch operation {
            case .open, .close: return true
            case .flush, .write, .read: return false
            }
        }
    }

    var everyWriteIsPrecededByAFlush: Bool {
        for (index, operation) in log.enumerated() {
            guard case .write = operation else { continue }
            guard index > 0, log[index - 1] == .flush else { return false }
        }
        return true
    }
}

// MARK: - Antwortframes

/// Ein autonomer Scanprofil-Broadcast -- ein echter, CRC-valider B0-Frame
/// über den bestehenden Vertrag, nie als abgeschriebene Bytefolge.
func standardScanProfileFrame(pointCount: Int = 90) -> Frame {
    try! Frame.build(
        address: 0x81,
        payload: [0xB0, UInt8(pointCount & 0xFF), UInt8(pointCount >> 8)]
            + Array(repeating: [UInt8(100), UInt8(0)], count: pointCount).flatMap { $0 } + [0]
    )
}

/// Die gültige Identitätsantwort `0xB1`.
func standardIdentityResponseFrame() -> Frame {
    try! Frame.build(address: 0x81, payload: [IdentityProbe.expectedResponseCommandByte, 0x41, 0x42])
}

/// Eine Antwort mit einem anderen Kommandobyte -- eine unerwartete
/// Antwort auf die Identitätsprobe.
func standardUnexpectedResponseFrame(commandByte: UInt8) -> Frame {
    try! Frame.build(address: 0x81, payload: [commandByte, 0x00])
}

/// Eine gültige, positive Bestätigungsantwort (`0xA0`, ACK) -- wie sie im
/// Login-/Baudwechselweg des delegierten Commissioning-Teils vorkommt.
func standardAcknowledgementFrame(status: UInt8 = 0x00) -> Frame {
    try! Frame.build(
        address: 0x81,
        payload: [AcknowledgementClassifier.responseCommandByte, status, 0x00]
    )
}

extension SerialPortReadOutcome {
    static func standardFrame(_ frame: Frame) -> SerialPortReadOutcome {
        .bytes(frame.encoded())
    }
}

// MARK: - Passwort

/// Acht ASCII-Zeichen, frei erfunden -- dasselbe Muster wie
/// `fabricatedSecretText` in `CommissioningControlTestSupport.swift`.
/// **Bewusst kein Roundtrip über beliebige Bytes und `String(decoding:as:)`**:
/// Bytes oberhalb `0x7F` sind als einzelne UTF-8-Bytes ungültig und würden
/// beim Decodieren durch das Ersatzzeichen U+FFFD ersetzt -- die
/// zurückcodierten UTF-8-Bytes hätten dann eine andere Länge als das
/// Original, und `InstallationSecret(text:)` schlüge an der Längenprüfung
/// fehl.
let standardTestSecretText = "TESTWERT"

/// Ein Passwortspeicher, der **jeden Lesezugriff zählt** -- für die
/// Pflichtnachweise „null Passwort-Lesezugriffe" (passiver/B1-Erfolg) und
/// „erst am vorgesehenen Punkt gelesen" (9600-Fallback).
final class TrackingScannerPasswordStore: ScannerPasswordStoring {
    private var value: String
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var forgetCount = 0

    /// Wird **innerhalb** von ``load()`` gerufen -- der deterministische
    /// Haltepunkt für den Nachweis „Abbruch in der Lücke **nach** dem
    /// Passwort-Lesen und **vor** dem Baudwechsel" (SICK-0330a-K1, K1-2).
    /// Das Passwort selbst wird dabei nie durchgereicht.
    var onLoad: (() -> Void)?

    init(initial: String = standardTestSecretText) {
        self.value = initial
    }

    func load() -> String {
        loadCount += 1
        onLoad?()
        return value
    }

    func save(_ password: String) {
        value = password
        saveCount += 1
    }

    func forget() {
        value = ""
        forgetCount += 1
    }
}
