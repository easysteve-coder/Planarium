import Foundation
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport

// SIM-P2c-2a: Moduslauf gegen die iPhone-Simulation.
//
// Ein Lauf: öffnen → Puffer leeren → genau ein Modustelegramm an Adresse 0 →
// lesen bis zur passenden gerahmten Antwort oder fester Frist → **immer**
// schließen. Keine Wiederholung des Kommandos, kein Login, kein frei
// programmierbarer Telegrammsender. Ein ACK heißt „Kommando bestätigt", nicht
// „Modus im Strom verifiziert".

/// Die zwei Modustelegramme. Adresse 0, Payload `20 24` bzw. `20 20`.
public enum SimulationModeTelegram {
    public static func command(for mode: SimulationMeasurementMode) -> [UInt8] {
        let payload: [UInt8]
        switch mode {
        case .fullScan:
            payload = [0x20, 0x24]
        case .minimumPerSegment:
            payload = [0x20, 0x20]
        }
        return try! Frame.build(address: 0x00, payload: payload).encoded()
    }
}

/// Erkennt die Antwort auf **ein** Modustelegramm aus einem Bytestrom.
/// - Frame von Adresse 0x80 mit Payload `A0 00 00` → `.acknowledged`;
/// - Frame von Adresse 0x80 mit Payload `A0 xx …`, xx ≠ 00 → `.rejected`;
/// - ein einzelnes NACK-Byte 0x15 außerhalb eines Frames → `.rejected`;
/// - ein einzelnes ACK-Byte 0x06 allein entscheidet nichts;
/// - andere Frames und Rauschen werden ignoriert.
public struct SimulationModeReplyMatcher {
    private var parser = StreamParser()
    private var decision: SimulationControlJobResult?
    private var frameCandidate: [UInt8] = []
    private var expectedFrameLength: Int?

    public init() {}

    /// `nil`, solange noch keine Entscheidung gefallen ist. Nach einer
    /// Entscheidung bleibt sie stehen.
    public mutating func feed(_ bytes: [UInt8]) -> SimulationControlJobResult? {
        if let decision { return decision }

        for byte in bytes {
            if frameCandidate.isEmpty, byte == 0x15 {
                decision = .rejected
                return decision
            }

            if frameCandidate.isEmpty {
                if byte == SickPLSFrameConstants.startOfText {
                    frameCandidate = [byte]
                }
            } else {
                frameCandidate.append(byte)
                if frameCandidate.count == SickPLSFrameConstants.headerLength {
                    let length = Int(frameCandidate[2]) | (Int(frameCandidate[3]) << 8)
                    guard length <= SickPLSFrameConstants.payloadMaxLength else {
                        frameCandidate.removeAll(keepingCapacity: true)
                        expectedFrameLength = nil
                        continue
                    }
                    expectedFrameLength = SickPLSFrameConstants.headerLength + length + SickPLSFrameConstants.trailerLength
                }
                if let expectedFrameLength, frameCandidate.count >= expectedFrameLength {
                    frameCandidate.removeAll(keepingCapacity: true)
                    self.expectedFrameLength = nil
                }
            }

            for frame in parser.feed([byte]) where frame.address == 0x80 {
                guard frame.payload.count >= 2, frame.payload[0] == 0xA0 else { continue }
                decision = frame.payload[1] == 0x00 ? .acknowledged : .rejected
                return decision
            }
        }
        return decision
    }
}

public struct SimulationModeRunLimits: Equatable, Sendable {
    /// Feste, monotone Frist ab dem Senden.
    public var transactionDeadlineMilliseconds: UInt64
    /// Länge eines einzelnen `read` innerhalb der Frist.
    public var readSliceMilliseconds: Int32

    public init(transactionDeadlineMilliseconds: UInt64 = 1_500, readSliceMilliseconds: Int32 = 50) {
        self.transactionDeadlineMilliseconds = transactionDeadlineMilliseconds
        self.readSliceMilliseconds = readSliceMilliseconds
    }

    public static let standard = SimulationModeRunLimits()
}

public enum SimulationModeRun {
    /// Führt einen Lauf auf dem Arbeitskontext des Aufrufers aus (nie Main).
    /// `nowMilliseconds` ist eine monotone Uhr.
    public static func execute(
        lease: SimulationControlLease,
        transport: CommissioningTransport,
        limits: SimulationModeRunLimits = .standard,
        nowMilliseconds: () -> UInt64
    ) -> SimulationControlCompletion {
        var result: SimulationControlJobResult = .transportFailed
        var closeStatus: SimulationControlCloseStatus = .closed
        var closeStatusAlreadyFailed = false

        do {
            try transport.openPort(baudRate: .baud38400)
            transport.flushReceiveBuffer()

            do {
                try transport.write(SimulationModeTelegram.command(for: mode(from: lease.job)))
                let sentAt = nowMilliseconds()
                var matcher = SimulationModeReplyMatcher()
                var decided = false

                while nowMilliseconds() - sentAt < limits.transactionDeadlineMilliseconds {
                    let elapsed = nowMilliseconds() - sentAt
                    let remaining = limits.transactionDeadlineMilliseconds - elapsed
                    let slice = min(UInt64(max(1, limits.readSliceMilliseconds)), remaining)
                    switch transport.read(timeoutMilliseconds: Int32(slice)) {
                    case .bytes(let bytes):
                        if let reply = matcher.feed(bytes) {
                            result = reply
                            decided = true
                        }
                    case .timeout:
                        break
                    case .closed:
                        result = .transportFailed
                        decided = true
                    }
                    if decided { break }
                }
                if !decided { result = .timedOut }
            } catch {
                result = .transportFailed
            }
        } catch let error {
            result = .transportFailed
            if error is NetworkCommissioningTransportError,
               (error as? NetworkCommissioningTransportError) == .closeTimedOut {
                closeStatusAlreadyFailed = true
            }
        }

        do {
            try transport.closePort()
        } catch {
            closeStatus = .closeFailed
        }
        if closeStatusAlreadyFailed { closeStatus = .closeFailed }

        return SimulationControlCompletion(
            generation: lease.generation,
            job: lease.job,
            result: result,
            closeStatus: closeStatus
        )
    }

    private static func mode(from job: SimulationControlJob) -> SimulationMeasurementMode {
        switch job {
        case .setMeasurementMode(let mode): return mode
        }
    }
}
