import SickPLSActiveControl
import SickPLSMacTransport

/// Die reale ``CommissioningTransport``-Umsetzung über die einzige
/// TX-fähige Portgrenze des Projekts (SICK-031).
///
/// ## Was hier bewusst **nicht** steht
///
/// Kein Ablauf, keine Frist, keine Wiederholung, keine Baudratensuche,
/// keine Klassifikation einer Antwort. Diese Klasse öffnet, schließt,
/// leert, schreibt und liest — mehr nicht. Alles Weitere gehört dem
/// ``CommissioningExecutor`` und dem geprüften ``CommissioningModel``.
///
/// ## Zwei Regeln, die bei künftigen Änderungen zu erhalten sind
///
/// - **Der Pfad wird vor dem ersten Öffnen geprüft** (`/dev/cu.`,
///   dieselbe Grenze wie `SickPLSSerialConnection.open` seit SICK-010 und
///   `BaudProbe` seit SICK-011) — und zwar im Initialisierer, damit ein
///   unzulässiger Pfad gar nicht erst in einen Lauf gelangt.
/// - **Ein zweites Öffnen ohne Schließen wird abgelehnt.** Beim
///   Ratenwechsel der Diagnose (SICK-030a3) liegt zwischen den beiden
///   Proben ein ausdrückliches Schließen; ohne diese Ablehnung könnte
///   eine Umsetzung die alte Verbindung stillschweigend weiterbenutzen
///   und „bei 38400 geprüft" behaupten, während sie noch 9600 spricht.
///
/// **In diesem Slice wird diese Klasse gegen einen Fake-Opener geprüft.
/// Ein echter Port ist nie geöffnet und kein Byte je an Hardware
/// gegangen** — dafür braucht es eine ausdrückliche spätere
/// Bedienaktion.
public final class ActiveControlCommissioningTransport: CommissioningTransport {

    /// Wie oft ``flushReceiveBuffer()`` höchstens nachfasst.
    ///
    /// Eine Obergrenze statt „bis nichts mehr kommt": Ein Scanner, der
    /// gerade einen Messstrom sendet, hört von sich aus nicht auf — ohne
    /// Grenze liefe das Leeren endlos, und zwar ausgerechnet vor dem
    /// Senden.
    public static let flushAttemptLimit = 64

    private let portPath: String
    private let opener: ActiveControlSerialPortOpener
    private var port: ActiveControlSerialPort?

    /// - Throws: ``CommissioningTransportError/pathNotAllowed(_:)``, wenn
    ///   der Pfad nicht mit `/dev/cu.` beginnt.
    public init(portPath: String, opener: ActiveControlSerialPortOpener) throws {
        guard portPath.hasPrefix("/dev/cu.") else {
            throw CommissioningTransportError.pathNotAllowed(portPath)
        }
        self.portPath = portPath
        self.opener = opener
    }

    deinit {
        port?.close()
    }

    /// Ob gerade eine Verbindung offen ist. Nur Beobachtung — der
    /// Executor steuert nach den Direktiven des Reducers, nicht danach.
    public var isPortOpen: Bool { port != nil }

    public func openPort(baudRate: SerialPortBaudRate) throws {
        guard port == nil else { throw CommissioningTransportError.portAlreadyOpen }
        do {
            port = try opener.open(atPath: portPath, baudRate: baudRate)
        } catch {
            throw CommissioningTransportError.openFailed(describe(error))
        }
    }

    public func closePort() throws {
        guard let port else { return }
        self.port = nil
        port.close()
    }

    public func flushReceiveBuffer() {
        guard let port else { return }
        var attempts = 0
        while attempts < Self.flushAttemptLimit {
            attempts += 1
            // Timeout `0`: Es wird **nicht gewartet**, sondern nur
            // abgeräumt, was schon dasteht.
            switch port.read(timeoutMilliseconds: 0) {
            case .bytes(let bytes) where !bytes.isEmpty:
                continue
            case .bytes, .timeout, .closed:
                return
            }
        }
    }

    public func write(_ bytes: [UInt8]) throws {
        guard let port else { throw CommissioningTransportError.portNotOpen }
        do {
            try port.write(bytes)
        } catch {
            throw CommissioningTransportError.writeFailed(describe(error))
        }
    }

    public func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        guard let port else { return .closed }
        return port.read(timeoutMilliseconds: timeoutMilliseconds)
    }

    /// Macht aus einem Fehler eine **kurze, datenfreie** Meldung.
    ///
    /// Bewusst ohne `String(describing:)` über beliebige Werte: Eine
    /// Fremdimplementierung könnte einen Fehler mit Nutzdaten mitführen,
    /// und der stünde dann im Audit. Hier steht nur, **was** schiefging
    /// und — wo vorhanden — der rohe POSIX-Code.
    private func describe(_ error: Error) -> String {
        switch error {
        case let openError as SerialPortOpenError:
            switch openError {
            case .pathNotAllowed:
                return "Path outside /dev/cu."
            case .openFailed(let code):
                return "open(2) errno \(code)"
            case .configurationFailed(let code):
                return "termios errno \(code)"
            }
        case let writeError as ActiveControlWriteError:
            switch writeError {
            case .writeFailed(let code):
                return "write(2) errno \(code)"
            }
        default:
            return "System error"
        }
    }
}
