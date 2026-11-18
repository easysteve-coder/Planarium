import PlanariumDomain
import Foundation

/// Ein einzelner, redigierter Empfangsblock. Rohbytes und Dienstadressen
/// bleiben absichtlich außerhalb des Diagnosevertrags.
public struct SimulationReceiveBlockDiagnostic: Equatable, Sendable {
    public let receivedAtMonotonic: Double
    public let byteCount: Int

    public init(receivedAtMonotonic: Double, byteCount: Int) {
        self.receivedAtMonotonic = receivedAtMonotonic
        self.byteCount = byteCount
    }
}

public enum SimulationCloseReasonDiagnostic: Equatable, Sendable {
    case silence(lastReceivedAtMonotonic: Double)
    case complete
    case error(code: String)
    case local(caller: LocalCloseCaller)

    public enum LocalCloseCaller: String, Equatable, Sendable {
        case explicitDisconnect
        case portRelease
        case sessionChange
        case preset
    }
}

public enum MeasurementDiagnosticEntry: Equatable, Sendable {
    case receive(SimulationReceiveBlockDiagnostic)
    case closed(SimulationCloseReasonDiagnostic, at: Double)
}
/// Bounded network diagnostics; musical diagnostics come from DisplayFrame.
public final class MeasurementDiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MeasurementDiagnosticEntry] = []
    public init() {}
    public func recordReceiveBlock(byteCount: Int, at timestamp: Double? = nil) {
        record(.receive(.init(receivedAtMonotonic: timestamp ?? ProcessInfo.processInfo.systemUptime, byteCount: byteCount)))
    }
    public func recordConnectionClosed(_ reason: SimulationCloseReasonDiagnostic, at timestamp: Double? = nil) {
        record(.closed(reason, at: timestamp ?? ProcessInfo.processInfo.systemUptime))
    }
    private func record(_ entry: MeasurementDiagnosticEntry) {
        lock.lock(); defer { lock.unlock() }
        storage.append(entry); if storage.count > 100 { storage.removeFirst(storage.count - 100) }
    }
    public var entries: [MeasurementDiagnosticEntry] { lock.lock(); defer { lock.unlock() }; return storage }
    public func reset() { lock.lock(); storage.removeAll(); lock.unlock() }
}
