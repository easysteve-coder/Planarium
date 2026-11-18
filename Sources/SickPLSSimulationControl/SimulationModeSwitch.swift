import Foundation
import SickPLSCommissioning

// SIM-P2c-2b: Orchestrierung eines Moduswechsels aus der Simulationsleiste.
//
// Ablauf (alles auf Main, außer dem Lauf selbst):
// Knopf → Lease anfragen (P2a; trennt Simulations-RX kontrolliert) → nach
// echter Freigabe erneut anfragen → Lauf auf eigener Queue (P2c-2a über P2b)
// → Completion an den Koordinator → bei `.released` RX neu verbinden; bei
// `.stillBlocked` genau ein Schließ-Wiederholversuch.

/// Sichtbarer Zustand eines Moduswechsels.
public enum SimulationModeSwitchState: Equatable, Sendable {
    case idle
    /// Simulations-RX wird getrennt; Lease folgt nach der echten Freigabe.
    case awaitingRelease(SimulationMeasurementMode)
    case running(SimulationMeasurementMode)
    /// Lauf beendet und Besitz freigegeben. `result` sagt nur etwas über das
    /// Kommando, nicht über den Profilstrom.
    case finished(SimulationMeasurementMode, SimulationControlJobResult)
    /// Schließen nicht bestätigt; Besitz bleibt gesperrt.
    case blocked(SimulationMeasurementMode)
}

/// Führt Läufe aus, nie auf Main. Completions kommen auf Main zurück.
public protocol SimulationModeRunning: AnyObject {
    func run(lease: SimulationControlLease, completion: @escaping (SimulationControlCompletion) -> Void)
    /// Erneutes Schließen des Transports dieser Lease nach `.closeFailed`.
    func retryClose(lease: SimulationControlLease, completion: @escaping (SimulationControlCompletion) -> Void)
}

/// Produktionsläufer: `NetworkCommissioningTransport` + `SimulationModeRun`
/// auf einer eigenen seriellen Queue.
public final class NetworkSimulationModeRunner: SimulationModeRunning, @unchecked Sendable {
    private final class CompletionBox: @unchecked Sendable {
        let body: (SimulationControlCompletion) -> Void

        init(_ body: @escaping (SimulationControlCompletion) -> Void) {
            self.body = body
        }
    }

    private let queue = DispatchQueue(label: "de.sick.planarium.simulation-mode-runner")
    private var transports: [SimulationControlGeneration: NetworkCommissioningTransport] = [:]
    private var completions: [SimulationControlGeneration: SimulationControlCompletion] = [:]

    public init() {}

    public func run(lease: SimulationControlLease, completion: @escaping (SimulationControlCompletion) -> Void) {
        let completionBox = CompletionBox(completion)
        queue.async { [self] in
            let transport = NetworkCommissioningTransport(
                endpoint: lease.endpoint,
                factory: NWSimulationNetworkConnectionFactory()
            )
            transports[lease.generation] = transport
            let result = SimulationModeRun.execute(
                lease: lease,
                transport: transport,
                nowMilliseconds: { UInt64(ProcessInfo.processInfo.systemUptime * 1_000) }
            )
            completions[lease.generation] = result
            if result.closeStatus == .closed {
                transports[lease.generation] = nil
                completions[lease.generation] = nil
            }
            DispatchQueue.main.async { completionBox.body(result) }
        }
    }

    public func retryClose(lease: SimulationControlLease, completion: @escaping (SimulationControlCompletion) -> Void) {
        let completionBox = CompletionBox(completion)
        queue.async { [self] in
            guard let transport = transports[lease.generation],
                  let previous = completions[lease.generation] else {
                let missing = SimulationControlCompletion(
                    generation: lease.generation,
                    job: lease.job,
                    result: .transportFailed,
                    closeStatus: .closed
                )
                DispatchQueue.main.async { completionBox.body(missing) }
                return
            }
            let closeStatus: SimulationControlCloseStatus
            do {
                try transport.closePort()
                closeStatus = .closed
                transports[lease.generation] = nil
            } catch {
                closeStatus = .closeFailed
            }
            let retry = SimulationControlCompletion(
                generation: previous.generation,
                job: previous.job,
                result: previous.result,
                closeStatus: closeStatus
            )
            completions[lease.generation] = retry
            DispatchQueue.main.async { completionBox.body(retry) }
        }
    }
}
