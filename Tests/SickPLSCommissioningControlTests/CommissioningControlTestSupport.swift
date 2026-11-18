import PlanariumInput
import Combine
import Foundation
import SickPLSMacTransport
import PlanariumScannerUI
// `@testable`, weil der modulinterne Memberwise-Initialisierer von
// `CommissioningStepReport` gebraucht wird: Die Berichte dieses Ziels
// entstehen produktiv **ausschließlich** in `CommissioningExecutor`
// (dieselbe Haltung wie bei `ScanProfileBatch`, SICK-029a). Daneben steht
// deshalb ein Nachweis mit einem **echten** Executor über einen
// Fake-Transport.
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl

/// **Ein ausgedachter Platzhalter, kein echtes Scanner-Passwort.**
///
/// Acht Zeichen, damit `InstallationSecret(text:)` ihn annimmt. Der reale
/// Wert steht in `SICK Doku/integration/` und darf in **keinem** Artefakt
/// dieses Projekts erscheinen — nicht in Code, Test, Fixture, Kommentar,
/// Testnamen, Handoff oder Log.
let fabricatedSecretText = "TESTWERT"

// MARK: - Portbesitz-Spion

/// Ein Spion für ``CommissioningPortCoordinating``.
///
/// **Bewusst kein echter `ScannerWorkspaceModel`:** Der erzeugte
/// einen `ThereminPerformanceController` und damit eine
/// `ThereminAudioEngine`. Die Nachweise dieses Ziels laufen ohne
/// Audiodienst und ohne Audiogerät.
final class SpyPortCoordinator: CommissioningPortCoordinating {

    private let ownerSubject = CurrentValueSubject<SerialPortOwner, Never>(.free)

    var readiness: CommissioningRunReadiness = .ready
    var accessOutcome: CommissioningAccessOutcome = .granted
    var completionOutcome: CommissioningCompletionOutcome = .released(verifiedBaudRate: nil)
    var isAwaitingPortRelease = false

    private(set) var readinessQueries: [String] = []
    private(set) var accessRequests = 0
    private(set) var completionReports: [CommissioningStepReport] = []
    /// Auf welchem Thread ``completeCommissioning(with:)`` lief — der
    /// Nachweis „Bericht erreicht erst den Main Thread".
    private(set) var completionOnMainThread: [Bool] = []

    var portOwner: SerialPortOwner { ownerSubject.value }
    var portOwnershipChanges: AnyPublisher<SerialPortOwner, Never> {
        ownerSubject.eraseToAnyPublisher()
    }

    /// Setzt den Besitz **wie ein echtes Ereignis** — inklusive Meldung
    /// an die Abonnenten.
    func setOwner(_ owner: SerialPortOwner) {
        ownerSubject.send(owner)
    }

    func commissioningRunReadiness(portPath: String) -> CommissioningRunReadiness {
        readinessQueries.append(portPath)
        return portPath.isEmpty ? .noPortSelected : readiness
    }

    @discardableResult
    func requestCommissioningAccess() -> CommissioningAccessOutcome {
        accessRequests += 1
        if case .granted = accessOutcome {
            setOwner(.commissioning)
        }
        return accessOutcome
    }

    @discardableResult
    func completeCommissioning(with report: CommissioningStepReport) -> CommissioningCompletionOutcome {
        completionReports.append(report)
        completionOnMainThread.append(Thread.isMainThread)
        if case .released = completionOutcome {
            setOwner(.free)
        }
        return completionOutcome
    }
}

// MARK: - Ausführungs-Spion

/// Ein Lauf, der nichts sendet und nur aufschreibt, was verlangt wurde.
///
/// **Strukturell abbrechbar** (SICK-0330a-1-K1/-K2): Zählt lediglich mit,
/// wie oft ``requestAbort()``/``beginRun()`` gerufen wurden — dieser
/// Spion bildet keinen echten Abbruchvertrag nach (dafür steht der
/// **echte** Executor samt echtem `CommissioningAbortToken` über
/// ``RealExecutorProvider``), er belegt nur, dass das Bedienmodell an der
/// richtigen Stelle wirklich ruft.
final class SpyCommissioningRun: CommissioningRunning, CommissioningAborting {

    /// Die Berichte, die nacheinander zurückgegeben werden.
    var scriptedReports: [CommissioningStepReport] = []
    /// Was zurückkommt, wenn das Skript leer ist.
    var fallbackReport = StepReportFactory.hold(phase: .respondingAtStartingRate)

    private let lock = NSLock()
    private var recordedCommands: [CommissioningCommand] = []
    private var recordedSecretPresence: [Bool] = []
    private var recordedMainThread: [Bool] = []
    private var recordedOverlaps = 0
    private var isInsidePerform = false
    private var recordedRequestAbortCount = 0
    private var recordedBeginRunCount = 0

    /// Wird **während** eines `perform` gerufen — für den Nachweis, dass
    /// eine zweite Bedienhandlung in dieser Zeit gesperrt ist.
    var duringPerform: (() -> Void)?

    var commands: [CommissioningCommand] { lock.withLock { recordedCommands } }
    var secretPresence: [Bool] { lock.withLock { recordedSecretPresence } }
    var ranOnMainThread: [Bool] { lock.withLock { recordedMainThread } }
    /// Wie oft sich zwei `perform`-Aufrufe überlappt haben. **Muss
    /// immer 0 sein.**
    var overlaps: Int { lock.withLock { recordedOverlaps } }
    var performCount: Int { lock.withLock { recordedCommands.count } }
    var requestAbortCount: Int { lock.withLock { recordedRequestAbortCount } }
    /// Wie oft ``beginRun()`` gerufen wurde — **muss genau `performCount`**
    /// entsprechen: einmal je Aufruf, synchron vor dessen Einplanung
    /// (SICK-0330a-1-K2).
    var beginRunCount: Int { lock.withLock { recordedBeginRunCount } }

    func perform(_ command: CommissioningCommand, secret: InstallationSecret?) -> CommissioningStepReport {
        lock.withLock {
            if isInsidePerform { recordedOverlaps += 1 }
            isInsidePerform = true
            recordedCommands.append(command)
            recordedSecretPresence.append(secret != nil)
            recordedMainThread.append(Thread.isMainThread)
        }
        duringPerform?()
        let report: CommissioningStepReport = lock.withLock {
            isInsidePerform = false
            if scriptedReports.isEmpty { return fallbackReport }
            return scriptedReports.removeFirst()
        }
        return report
    }

    func requestAbort() {
        lock.withLock { recordedRequestAbortCount += 1 }
    }

    func beginRun() {
        lock.withLock { recordedBeginRunCount += 1 }
    }
}

/// Stellt ``SpyCommissioningRun`` bereit — oder verweigert.
final class SpyRunProvider: CommissioningRunProviding {
    let run = SpyCommissioningRun()
    var failure: CommissioningRunUnavailableReason?
    private(set) var requestedPaths: [String] = []

    func makeRun(portPath: String) throws -> CommissioningRunning & CommissioningAborting {
        requestedPaths.append(portPath)
        if let failure { throw failure }
        return run
    }
}

// MARK: - Ausführungssteuerung

/// Ein Dispatcher, der **nichts** von selbst tut: Beide Seiten werden in
/// Warteschlangen gelegt und vom Test ausdrücklich abgearbeitet.
///
/// Damit sind die Reihenfolgeaussagen deterministisch prüfbar — ohne
/// echten Timer, ohne Wartezeit und ohne Rennen.
final class ManualCommissioningDispatcher: CommissioningDispatching {
    private(set) var backgroundWork: [() -> Void] = []
    private(set) var mainWork: [() -> Void] = []

    func runSerialized(_ work: @escaping () -> Void) {
        backgroundWork.append(work)
    }

    func deliverOnMain(_ work: @escaping () -> Void) {
        mainWork.append(work)
    }

    /// Arbeitet genau einen Hintergrundauftrag ab.
    @discardableResult
    func runNextBackground() -> Bool {
        guard !backgroundWork.isEmpty else { return false }
        backgroundWork.removeFirst()()
        return true
    }

    /// Arbeitet genau eine Hauptzustellung ab.
    @discardableResult
    func deliverNextMain() -> Bool {
        guard !mainWork.isEmpty else { return false }
        mainWork.removeFirst()()
        return true
    }

    /// Hintergrund und danach Zustellung — der gewöhnliche Vollzug.
    func runToCompletion() {
        while runNextBackground() {}
        while deliverNextMain() {}
    }
}

// MARK: - Portliste

final class FakeSerialPortListing: SerialPortListing {
    var paths: [String] = []
    private(set) var queries = 0

    func availablePortPaths() -> [String] {
        queries += 1
        return paths
    }
}

// MARK: - Berichte

/// Baut Berichte für die Nachweise.
///
/// **Ein Bericht ist hier ein Testwert, kein Lauf** — deshalb steht
/// daneben ein Nachweis, der einen **echten** `CommissioningExecutor`
/// über einen Fake-Transport fährt.
enum StepReportFactory {
    static func hold(
        phase: CommissioningPhase,
        verifiedBaudRate: SerialPortBaudRate? = nil,
        observedScanProfileStream: Bool = false,
        audit: CommissioningAudit = CommissioningAudit()
    ) -> CommissioningStepReport {
        CommissioningStepReport(
            phase: phase,
            restingDirective: .hold,
            audit: audit,
            verifiedBaudRate: verifiedBaudRate,
            observedScanProfileStream: observedScanProfileStream,
            isPortHeld: true,
            isFinal: false
        )
    }

    static func final(
        phase: CommissioningPhase,
        verifiedBaudRate: SerialPortBaudRate? = nil,
        observedScanProfileStream: Bool = false,
        audit: CommissioningAudit = CommissioningAudit()
    ) -> CommissioningStepReport {
        CommissioningStepReport(
            phase: phase,
            restingDirective: .stop,
            audit: audit,
            verifiedBaudRate: verifiedBaudRate,
            observedScanProfileStream: observedScanProfileStream,
            isPortHeld: false,
            isFinal: true
        )
    }

    /// Der Reducer wollte stoppen, das Schließen scheiterte real —
    /// **nicht final, Port sichtbar gehalten** (SICK-0330a-1-K1, H2/H3).
    static func closeFailed(
        phase: CommissioningPhase,
        verifiedBaudRate: SerialPortBaudRate? = nil,
        observedScanProfileStream: Bool = false,
        audit: CommissioningAudit = CommissioningAudit()
    ) -> CommissioningStepReport {
        CommissioningStepReport(
            phase: phase,
            restingDirective: .stop,
            audit: audit,
            verifiedBaudRate: verifiedBaudRate,
            observedScanProfileStream: observedScanProfileStream,
            isPortHeld: true,
            isFinal: false
        )
    }
}

// MARK: - Aufbau

/// Eine Einstellungsablage im Speicher (SICK-032a2).
///
/// **Rührt `UserDefaults` nicht an** — ein Test, der die echten
/// Einstellungen des Benutzers beschreibt, hinterlässt eine Spur auf
/// einem fremden Rechner.
final class FakeScannerPasswordStore: ScannerPasswordStoring {
    private var value: String
    private(set) var saveCount = 0
    private(set) var forgetCount = 0

    init(initial: String = "") {
        self.value = initial
    }

    func load() -> String { value }

    func save(_ password: String) {
        value = password
        saveCount += 1
    }

    func forget() {
        value = ""
        forgetCount += 1
    }
}

/// Ein fertig verdrahtetes Bedienmodell samt seiner Spione.
struct ControlHarness {
    let coordinator = SpyPortCoordinator()
    let provider = SpyRunProvider()
    let dispatcher = ManualCommissioningDispatcher()
    let listing = FakeSerialPortListing()
    let passwordStore: FakeScannerPasswordStore
    let model: CommissioningControlModel

    init(portPath: String = "/dev/cu.usbserial-TEST", storedPassword: String = fabricatedSecretText) {
        let store = FakeScannerPasswordStore(initial: storedPassword)
        passwordStore = store
        model = CommissioningControlModel(
            coordinator: coordinator,
            runProvider: provider,
            dispatcher: dispatcher,
            portListing: listing,
            passwordStore: store
        )
        if !portPath.isEmpty {
            model.selectPort(portPath)
        }
    }

    /// Einen Schritt vollständig durchführen — über den Weg, den seine
    /// Art verlangt: ein Klick für die harmlosen, zwei für die, die den
    /// Scanner verändern.
    @discardableResult
    func runStep(_ command: CommissioningCommand) -> CommissioningStepConfirmationOutcome {
        let outcome: CommissioningStepConfirmationOutcome
        if model.requiresConfirmation(command) {
            model.requestStep(command)
            outcome = model.confirmPendingStep()
        } else {
            outcome = model.performStep(command)
        }
        dispatcher.runToCompletion()
        return outcome
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
