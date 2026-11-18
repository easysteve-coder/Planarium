import Combine
import SickPLSCommissioning
import SickPLSMacTransport
import PlanariumInput

/// Eine kurze, im **Modell** formulierte Rückmeldung der Einrichtung
/// (SICK-032a; Muster wie `PerformanceNotice` aus SICK-028 und
/// `PortAccessNotice` aus SICK-030a1).
///
/// **Trägt nie Bytes, nie einen Payload und nie das Geheimnis.**
public struct CommissioningNotice: Equatable {
    public let message: String
    /// Ob der Hinweis aus einer **Bedienhandlung** stammt oder von
    /// selbst entstand — dieselbe Trennung wie bei `PerformanceNotice`.
    public let isAutomatic: Bool

    init(_ message: String, isAutomatic: Bool = false) {
        self.message = message
        self.isAutomatic = isAutomatic
    }
}

/// Was aus einer **Anforderung** eines Schritts wurde — noch ohne jedes
/// Senden.
public enum CommissioningStepRequestOutcome: Equatable {
    /// Der Schritt wartet jetzt auf die ausdrückliche Bestätigung.
    /// **Es ging nichts hinaus.**
    case awaitingConfirmation(CommissioningCommand)
    case refusedAlreadyRunning
    case refusedNotAllowed(CommissioningCommand)
}

/// Was aus einer **Bestätigung** wurde.
///
/// `started` heißt: Der Lauf wurde an die serialisierte
/// Hintergrundausführung übergeben. Er ist damit **nicht** fertig — das
/// Ergebnis kommt als Bericht auf dem Main Thread zurück.
public enum CommissioningStepConfirmationOutcome: Equatable {
    case started(CommissioningCommand)
    case refusedNoPendingStep
    case refusedAlreadyRunning
    case refusedWithoutPortAccess
    /// Das **Scanner-Passwort aus den Einstellungen** taugt nicht für
    /// das Umschalten (SICK-032a2) — es fehlt oder hat nicht die Form,
    /// die das Gerät erwartet.
    ///
    /// Seit diesem Slice gibt es mitten im Ablauf **keine
    /// Passworteingabe** mehr; der Wert steht in den Einstellungen.
    /// Taugt er nicht, verweist der Hinweis genau dorthin, statt eine
    /// Eingabeaufforderung zu öffnen — und **es geht nichts hinaus**.
    case refusedScannerPassword(ScannerPasswordUsability)
    case refusedRunUnavailable(CommissioningRunUnavailableReason)
}

/// Was aus dem **primären Vorbereitungsablauf** wurde (SICK-032a2).
///
/// Er fasst zusammen, was der Bedienende bis SICK-032a einzeln anklicken
/// musste: Zugang anfordern **und** die harmlose Ausgangsprüfung
/// auslösen.
public enum ScannerPreparationOutcome: Equatable {
    /// Die Ausgangsprüfung läuft. **Es geht nur die harmlose
    /// Identitätsprobe hinaus.**
    case started
    /// Der Monitor wird noch getrennt; danach genügt ein erneuter
    /// Aufruf.
    case awaitingPortRelease
    case refusedAlreadyRunning
    case refusedNoPortSelected
    case refused(SerialPortOwnershipRefusal)
    /// In der aktuellen Lage ist keine Vorbereitung vorgesehen — etwa
    /// nach einem belegten Wechsel.
    case refusedNotAllowed
    case refusedRunUnavailable(CommissioningRunUnavailableReason)
}

/// Der sichtbare Bedienpfad der Scanner-Einrichtung (SICK-032a, Auflage
/// **E3** aus `review-sick-031.md`).
///
/// ## Was dieses Modell ist
///
/// Die schmale Koordinationsschicht zwischen der Ansicht und den bereits
/// abgenommenen Teilen: dem Portbesitz des
/// ``InputOwner`` (SICK-030a1/031) und dem
/// `CommissioningExecutor` (SICK-031). **Es ist keine zweite
/// Zustandsmaschine** — die Wahrheit über den Ablauf ist und bleibt der
/// ``CommissioningStepReport``, den ein tatsächlich gelaufenes `perform`
/// liefert.
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// 1. **Kein Autostart.** Weder das Erzeugen noch das Anzeigen noch ein
///    Portwechsel noch eine Monitorverbindung noch ein Besitzwechsel löst
///    eine Sendung aus. Es gibt **keinen Timer** und keine
///    Wiederholungsautomatik. Jede TX-auslösende Handlung braucht eine
///    ausdrückliche Bedienhandlung — seit SICK-032a2 für die harmlosen
///    Vorbereitungsschritte **einen** Klick (``prepareScanner()`` bzw.
///    ``performStep(_:)``) und für alles, was das Gerät verändert,
///    weiterhin **zwei** (``requestStep(_:)`` und
///    ``confirmPendingStep()``).
/// 2. **Höchstens ein `perform` gleichzeitig.** ``isRunning`` sperrt auf
///    dem Kontroll-Thread, damit eine zweite Handlung gar nicht erst in
///    die Warteschlange gerät; die serielle Warteschlange in
///    ``CommissioningDispatching`` sichert dasselbe auf Systemebene.
/// 3. **Der Bericht erreicht zuerst den Main Thread.** Erst dort wird
///    ``CommissioningPortCoordinating/completeCommissioning(with:)``
///    gerufen. Der Abschluss speist sich **ausschließlich** aus dem
///    Bericht eines gelaufenen `perform`; `CommissioningExecutor.report`
///    ist über ``CommissioningRunning`` strukturell unerreichbar
///    (Review-Befund N2).
/// 4. **Sichtbare Fehler bleiben sichtbar.** Ein `.failed` erscheint nie
///    als Erfolg und nie als stiller Abschluss; ``verifiedBaudRate`` wird
///    **nur** aus dem Bericht übernommen und dort nur durch eine
///    CRC-valide Identitätsantwort bei der Zielrate gesetzt (Auflage A1).
///    Ein beobachteter Messstrom wird getrennt angezeigt und **nie** als
///    Wechselerfolg.
/// 5. **Das Scanner-Passwort ist eine normale Einstellung** (seit
///    SICK-032a2, Owner-Korrektur). Es steht im Klartext in den
///    App-Einstellungen, wird für genau einen `perform` von dort geholt
///    und danach fallen gelassen. Dieses Modell hält es **nicht** und
///    zeigt es nicht an — nicht aus Geheimhaltung, sondern weil die
///    Einrichtung den Wert nicht anzuzeigen hat; sichtbar ist hier nur
///    ``scannerPasswordUsability``.
/// 6. **Bestätigt wird, was das Gerät verändert** (seit SICK-032a2).
///    Die harmlosen Vorbereitungsschritte gehen über ``prepareScanner()``
///    bzw. ``performStep(_:)`` auf **einen** Klick; ``requestStep(_:)``
///    und ``confirmPendingStep()`` bleiben für Umschalten und Messmodus
///    verbindlich. Welcher Schritt wohin gehört, entscheidet
///    ``CommissioningStepPolicy/requiresConfirmation(_:)``, nicht diese
///    Klasse.
///
/// ## Threadvertrag
///
/// **Alle öffentlichen Mitglieder gehören dem Kontroll-Thread** (in der
/// App der Main Thread) — dasselbe wie bei `ThereminPerformanceController`
/// (SICK-027). Der einzige Fremd-Thread ist die serialisierte Ausführung
/// von `perform`, und von dort kommt ausschließlich der Bericht zurück.
public final class CommissioningControlModel: ObservableObject {

    // MARK: - Sichtbarer Zustand

    /// Die dauerhaft anzuzeigende Vorabinformation (Bedienvertrag 1).
    @Published public private(set) var briefing: CommissioningBriefing
    /// Die gefundenen `/dev/cu.*`-Pfade. **Nie automatisch gewählt.**
    @Published public private(set) var availablePorts: [String] = []
    /// Der ausgewählte Pfad. Leer heißt: keiner.
    @Published public private(set) var selectedPortPath = ""
    /// Ob ein Lauf beginnen dürfte — aus dem Koordinator, nie geraten.
    @Published public private(set) var readiness: CommissioningRunReadiness = .noPortSelected
    /// Wer den Port hält.
    @Published public private(set) var portOwner: SerialPortOwner = .free
    /// Ob das tatsächliche Schließen noch aussteht — **die sichtbare
    /// Besitzwartephase**.
    @Published public private(set) var isAwaitingPortRelease = false
    /// Der Schritt, der auf die ausdrückliche Bestätigung wartet.
    /// **Solange er hier steht, ging nichts hinaus.**
    @Published public private(set) var pendingStep: CommissioningCommand?
    /// Ob gerade ein `perform` läuft. Sperrt jede zweite Handlung.
    @Published public private(set) var isRunning = false
    /// Die Phase des letzten Berichts. `nil` heißt: Es lief noch nichts.
    @Published public private(set) var phase: CommissioningPhase?
    /// Die jetzt anbietbaren Schritte.
    @Published public private(set) var allowedSteps: [CommissioningCommand] =
        CommissioningStepPolicy.beforeFirstRun
    /// Das redigierte Protokoll des laufenden Vorgangs.
    @Published public private(set) var auditEntries: [CommissioningAuditEntry] = []
    /// **Nur** aus dem Bericht und dort nur durch eine CRC-valide
    /// Identitätsantwort bei der Zielrate belegt (Auflage A1).
    @Published public private(set) var verifiedBaudRate: SerialPortBaudRate?
    /// Ein Messstrom wurde beobachtet — **reine Information, nie ein
    /// Wechselerfolg**.
    @Published public private(set) var observedScanProfileStream = false
    /// Ob der Ablauf den Port laut letztem Bericht weiter hält.
    @Published public private(set) var isPortHeld = false
    @Published public private(set) var notice: CommissioningNotice?
    /// Wie oft ein Endbericht den Besitz freigegeben hat — macht „genau
    /// einmal freigeben" prüfbar.
    @Published public private(set) var releasedRunCount = 0

    /// Ob das in den Einstellungen hinterlegte Scanner-Passwort für das
    /// Umschalten taugt (SICK-032a2).
    ///
    /// Wird beim Anzeigen nachgelesen, damit eine gerade vorgenommene
    /// Änderung hier sofort ankommt.
    @Published public private(set) var scannerPasswordUsability: ScannerPasswordUsability = .notSet

    /// Ob die Einrichtung den Port gerade besitzt. **Ohne das wird keine
    /// Bestätigung ausgeführt.**
    public var hasPortAccess: Bool { portOwner == .commissioning }

    /// Ob der angeforderte Schritt vor dem Senden bestätigt werden muss.
    public func requiresConfirmation(_ command: CommissioningCommand) -> Bool {
        policy.requiresConfirmation(command)
    }

    /// Vollständiger, aber redigierter Export der manuellen Schritte.
    public func evidenceExportText() -> String {
        ManualCommissioningEvidenceExport.text(
            portPath: selectedPortPath,
            phase: phase,
            entries: auditEntries
        )
    }

    // MARK: - Abhängigkeiten

    private let coordinator: CommissioningPortCoordinating
    private let runProvider: CommissioningRunProviding
    private let dispatcher: CommissioningDispatching
    private let portListing: SerialPortListing
    private let policy = CommissioningStepPolicy()
    private let recipe: CommissioningRecipe
    /// Die Einstellungsablage des Scanner-Passworts (SICK-032a2).
    /// **Nur lesend benutzt** — eingetragen und gelöscht wird es
    /// ausschließlich in ``ScannerPasswordSettingsModel``.
    private let passwordStore: ScannerPasswordStoring

    /// Der laufende Vorgang. Er überlebt einen **Fehlschlag** bewusst:
    /// `runRateDiagnostics` ist nur aus `.failed` erlaubt, und ein neuer
    /// Executor stünde wieder bei `.idle`. Verworfen wird er erst bei
    /// einem wirklich **finalen** Bericht (SICK-0330a-1-K1, H2) — ein
    /// gescheiterter Schließversuch hält ihn trotz `.sessionFinished`
    /// fest, weil nur er den anschließenden expliziten Retry ausführen
    /// kann.
    ///
    /// **Strukturell abbrechbar** (SICK-0330a-1-K1, H4): Der Typ
    /// erzwingt ``CommissioningAborting`` — kein optionaler Cast an der
    /// Stelle, die den Abbruch auslöst.
    private var run: (CommissioningRunning & CommissioningAborting)?
    private var cancellables: Set<AnyCancellable> = []

    public init(
        coordinator: CommissioningPortCoordinating,
        runProvider: CommissioningRunProviding = SystemCommissioningRunFactory(),
        dispatcher: CommissioningDispatching = SerialCommissioningDispatcher(),
        portListing: SerialPortListing = SystemSerialPortListing(),
        passwordStore: ScannerPasswordStoring = UserDefaultsScannerPasswordStore(),
        recipe: CommissioningRecipe = .r26
    ) {
        self.coordinator = coordinator
        self.runProvider = runProvider
        self.dispatcher = dispatcher
        self.portListing = portListing
        self.passwordStore = passwordStore
        self.recipe = recipe
        self.briefing = CommissioningBriefing(portPath: "", recipe: recipe)
        // **Nur beobachten, nie handeln**: Ein Besitzwechsel aktualisiert
        // die Anzeige, damit die Wartephase von selbst endet. Er startet
        // nichts -- das ist ein eigener Nachweis.
        coordinator.portOwnershipChanges
            .sink { [weak self] owner in self?.refreshReadiness(observedPortOwner: owner) }
            .store(in: &cancellables)
        refreshReadiness()
    }

    // MARK: - Port und Bereitschaft

    /// Liest die verfügbaren Pfade neu ein. **Wählt nie von selbst
    /// einen aus** — auch nicht, wenn es genau einen gibt.
    public func refreshPorts() {
        availablePorts = portListing.availablePortPaths()
        refreshReadiness()
    }

    /// Wählt einen Pfad. **Startet nichts** und beansprucht nichts.
    public func selectPort(_ path: String) {
        selectedPortPath = path
        briefing = CommissioningBriefing(portPath: path, recipe: recipe)
        // Ein Portwechsel unter einem wartenden Schritt hinweg wäre eine
        // Falle: bestätigt würde dann etwas anderes als angezeigt.
        pendingStep = nil
        refreshReadiness()
    }

    /// Fragt Bereitschaft und Besitz beim Koordinator nach.
    /// **Führt nichts aus.**
    public func refreshReadiness() {
        refreshReadiness(observedPortOwner: nil)
    }

    /// Aktualisiert die Bereitschaft nach einem Besitzsignal. Der Publisher
    /// liefert den neuen Owner bereits im `willSet` von `@Published`; der
    /// gelieferte Wert ist deshalb maßgeblich, nicht der noch alte Getter.
    private func refreshReadiness(observedPortOwner: SerialPortOwner?) {
        readiness = coordinator.commissioningRunReadiness(portPath: selectedPortPath)
        portOwner = observedPortOwner ?? coordinator.portOwner
        isAwaitingPortRelease = coordinator.isAwaitingPortRelease
        // Ein in den Einstellungen gerade geänderter Wert soll hier ohne
        // Neustart ankommen.
        scannerPasswordUsability = ScannerPasswordSettingsModel.usability(of: passwordStore.load())
    }

    /// Erste Stufe der Bedienung: den Portbesitz anfordern.
    ///
    /// Trennt den Monitor höchstens **kontrolliert** und wartet die echte
    /// Freigabe ab (SICK-030a1). **Sendet nichts** und öffnet nichts;
    /// wer hier Zugang bekommt, hat noch keinen Schritt ausgeführt.
    @discardableResult
    public func requestAccess() -> CommissioningAccessOutcome {
        let outcome = coordinator.requestCommissioningAccess()
        switch outcome {
        case .granted:
            notice = CommissioningNotice("The scanner is now owned by Commissioning. Nothing was sent.")
        case .awaitingMonitorRelease:
            notice = CommissioningNotice(
                "The live display is being disconnected. Commissioning waits until the port is truly free."
            )
        case .refused(let refusal):
            notice = CommissioningNotice(Self.describe(refusal))
        }
        refreshReadiness()
        return outcome
    }

    // MARK: - Zweite Stufe: anfordern und bestätigen

    /// Zweite Stufe, erster Handgriff: einen Schritt **anfordern**.
    ///
    /// **Hier geht nichts hinaus.** Der Schritt wartet danach sichtbar
    /// auf ``confirmPendingStep(secretText:)``.
    @discardableResult
    public func requestStep(_ command: CommissioningCommand) -> CommissioningStepRequestOutcome {
        guard !isRunning else {
            notice = CommissioningNotice("A step is already running. Please wait.")
            return .refusedAlreadyRunning
        }
        guard allowedSteps.contains(command) else {
            notice = CommissioningNotice("This step is not available in the current state.")
            return .refusedNotAllowed(command)
        }
        pendingStep = command
        notice = nil
        return .awaitingConfirmation(command)
    }

    /// Nimmt eine Anforderung zurück. **Nie eine Sendung.**
    public func cancelPendingStep() {
        pendingStep = nil
    }

    /// Zweite Stufe, zweiter Handgriff: den angeforderten Schritt
    /// **ausdrücklich bestätigen** und damit ausführen lassen.
    ///
    /// **Ohne Parameter** (seit SICK-032a2): Das Scanner-Passwort wird
    /// nicht mehr hier eingegeben, sondern einmal in den Einstellungen
    /// hinterlegt und für genau diesen Lauf aus dem Schlüsselbund
    /// geholt. Fehlt es, verweist der Hinweis dorthin — und **es geht
    /// nichts hinaus**.
    @discardableResult
    public func confirmPendingStep() -> CommissioningStepConfirmationOutcome {
        guard let command = pendingStep else { return .refusedNoPendingStep }
        return start(command, clearingPendingStep: true)
    }

    /// Ein harmloser Schritt auf **einen** Klick (SICK-032a2).
    ///
    /// Für alles, was das Gerät nicht verändert: Identitätsprobe,
    /// Ratendiagnose, Beenden, Abbrechen. Ein Schritt, der laut
    /// ``CommissioningStepPolicy/requiresConfirmation(_:)``
    /// bestätigungspflichtig ist, wird hier **abgelehnt** und muss über
    /// ``requestStep(_:)`` gehen — sonst wäre die Bestätigungspflicht
    /// eine Empfehlung statt einer Regel.
    @discardableResult
    public func performStep(_ command: CommissioningCommand) -> CommissioningStepConfirmationOutcome {
        if command == .abort, isRunning, let run {
            // **Der kooperative Weg** (SICK-0330a-1): Ein zweiter
            // `perform(.abort)` würde sich hinter dem laufenden Aufruf
            // auf derselben seriellen Warteschlange einreihen und ihn
            // nie erreichen (Ausgangslage, Punkt 2). Stattdessen wird
            // ausschließlich das Abbruchsignal gesetzt -- der bereits
            // laufende `perform` beobachtet es selbst zwischen zwei
            // Gerätewirkungen und beendet sich damit kooperativ. Es geht
            // **kein zweiter** Lauf hinaus; der Bericht kommt wie immer
            // über den einen dispatchten `perform`-Aufruf und
            // `finishRun(with:)` zurück.
            //
            // **Kein optionaler Cast mehr** (SICK-0330a-1-K1, H4): `run`
            // ist strukturell abbrechbar, also wird hier nie eine
            // Anforderung verschluckt, während trotzdem `.started(.abort)`
            // gemeldet würde.
            run.requestAbort()
            notice = CommissioningNotice(Self.describeRunning(.abort))
            return .started(.abort)
        }
        guard !policy.requiresConfirmation(command) else {
            pendingStep = command
            notice = CommissioningNotice(Self.confirmationRequired)
            return .refusedNoPendingStep
        }
        guard allowedSteps.contains(command) else {
            notice = CommissioningNotice("This is not possible right now.")
            return .refusedNoPendingStep
        }
        return start(command, clearingPendingStep: false)
    }

    /// **Der primäre Ablauf** (SICK-032a2): Scanner vorbereiten.
    ///
    /// Fasst zusammen, was bis SICK-032a zwei bis drei einzelne Klicks
    /// waren — den Port übernehmen und die harmlose Ausgangsprüfung
    /// auslösen. **Es geht dabei ausschließlich die Identitätsprobe
    /// hinaus**; das Gerät wird nicht verändert.
    ///
    /// Hält der Monitor den Port noch, wird er kontrolliert getrennt und
    /// der Aufruf meldet ``ScannerPreparationOutcome/awaitingPortRelease``
    /// — danach genügt ein erneuter Aufruf. **Es wird nichts
    /// nachgeholt und nichts wiederholt**; eine Automatik gibt es hier
    /// so wenig wie überall sonst in diesem Modell.
    @discardableResult
    public func prepareScanner() -> ScannerPreparationOutcome {
        guard !isRunning else {
            notice = CommissioningNotice("Something is already running. Please wait a moment.")
            return .refusedAlreadyRunning
        }
        guard !selectedPortPath.isEmpty else {
            notice = CommissioningNotice("Please select the port the scanner is connected to first.")
            return .refusedNoPortSelected
        }

        // Eine erfolgreich beendete Sitzung ist final und ihr Executor
        // wurde verworfen. Ein erneuter ausdrücklicher Klick auf Schritt
        // 1 beginnt deshalb eine frische Sitzung und ein frisches Audit.
        // Das ist ausschließlich lokaler Bedienzustand: Bis zum späteren
        // `start(.checkStartingRate)` wird weder ein Port geöffnet noch
        // etwas gesendet.
        if case .sessionFinished? = phase, run == nil, !isPortHeld {
            phase = nil
            auditEntries = []
            verifiedBaudRate = nil
            observedScanProfileStream = false
            allowedSteps = CommissioningStepPolicy.beforeFirstRun
            pendingStep = nil
        }

        if !hasPortAccess {
            switch coordinator.requestCommissioningAccess() {
            case .granted:
                break
            case .awaitingMonitorRelease:
                refreshReadiness()
                notice = CommissioningNotice(
                    "The live display is being disconnected. Please tap \"Prepare Scanner\" again shortly."
                )
                return .awaitingPortRelease
            case .refused(let refusal):
                refreshReadiness()
                notice = CommissioningNotice(Self.describe(refusal))
                return .refused(refusal)
            }
            refreshReadiness()
        }

        guard allowedSteps.contains(.checkStartingRate) else {
            notice = CommissioningNotice("The scanner is already prepared.")
            return .refusedNotAllowed
        }

        switch start(.checkStartingRate, clearingPendingStep: true) {
        case .started:
            return .started
        case .refusedAlreadyRunning:
            return .refusedAlreadyRunning
        case .refusedWithoutPortAccess:
            return .refused(.awaitingRelease)
        case .refusedRunUnavailable(let reason):
            return .refusedRunUnavailable(reason)
        case .refusedNoPendingStep, .refusedScannerPassword:
            // Strukturell unerreichbar: Die Ausgangsprüfung ist nicht
            // bestätigungspflichtig und braucht kein Passwort.
            return .refusedNotAllowed
        }
    }

    // MARK: - Der eine Ausführungsweg

    /// **Die einzige Stelle, die einen Lauf startet.**
    ///
    /// Bestätigter Schritt und Ein-Klick-Schritt teilen sich sie
    /// vollständig — sonst gäbe es zwei Wege zum Senden, und nur einer
    /// wäre geprüft.
    private func start(
        _ command: CommissioningCommand,
        clearingPendingStep: Bool
    ) -> CommissioningStepConfirmationOutcome {
        guard !isRunning else {
            notice = CommissioningNotice("A step is already running. Please wait.")
            return .refusedAlreadyRunning
        }
        guard hasPortAccess else {
            notice = CommissioningNotice("Please tap \"Prepare Scanner\" first.")
            return .refusedWithoutPortAccess
        }
        // **Früh und im Modell**, nicht erst in der Fabrik: Ohne Pfad
        // gibt es nichts zu öffnen, und das ist eine Bedienlage, keine
        // Transportstörung. Die Fabrik prüft es unabhängig davon ein
        // zweites Mal -- die Antwort einer Bedienschicht ist keine
        // Zusicherung.
        guard !selectedPortPath.isEmpty else {
            notice = CommissioningNotice(Self.describe(.noPortSelected))
            return .refusedRunUnavailable(.noPortSelected)
        }

        var secret: InstallationSecret?
        if command == .switchBaudRate || command == .enterSettingsMode || command == .login {
            // **Aus den Einstellungen, nicht aus einer Eingabe**
            // (SICK-032a2). Es wird genau hier geholt, genau einmal
            // gereicht und danach fallen gelassen.
            let stored = passwordStore.load()
            let usability = ScannerPasswordSettingsModel.usability(of: stored)
            scannerPasswordUsability = usability
            guard let parsed = InstallationSecret(text: stored) else {
                notice = CommissioningNotice(Self.describe(usability))
                return .refusedScannerPassword(usability)
            }
            secret = parsed
        }

        let activeRun: CommissioningRunning & CommissioningAborting
        if let existing = run {
            activeRun = existing
        } else {
            do {
                activeRun = try runProvider.makeRun(portPath: selectedPortPath)
                run = activeRun
            } catch let reason as CommissioningRunUnavailableReason {
                notice = CommissioningNotice(Self.describe(reason))
                return .refusedRunUnavailable(reason)
            } catch {
                // **Ein fremder Laufanbieter darf hier nichts hinterlassen**
                // (SICK-032a1). Der Fehler wird weder beschrieben noch
                // lokalisiert noch interpoliert: Was in seiner
                // Beschreibung steht, weiß diese Grenze nicht, und ein
                // Wert, der nicht übernommen wird, kann in Rückgabe,
                // Hinweis, Audit oder Debug-Ausgabe nicht auftauchen.
                // Der Bedienfehler bleibt trotzdem sichtbar und
                // typisiert.
                notice = CommissioningNotice(Self.describe(.transportUnavailable))
                return .refusedRunUnavailable(.transportUnavailable)
            }
        }

        if clearingPendingStep {
            pendingStep = nil
        }
        isRunning = true
        notice = CommissioningNotice(Self.describeRunning(command))

        // **Die atomare Laufkante wird hier, synchron, reserviert --
        // bevor der Hintergrundaufruf überhaupt eingeplant wird**
        // (SICK-0330a-1-K2). Eine Abbruchanforderung, die in der Lücke
        // zwischen diesem Aufruf und dem tatsächlichen Start von
        // `activeRun.perform(...)` eintrifft, heftet sich dadurch an
        // dieselbe Laufkante, die `perform` gleich selbst wiederverwendet
        // -- statt spurlos zu verpuffen, weil zu diesem Zeitpunkt noch
        // gar keine Laufkante reserviert war.
        activeRun.beginRun()

        // **Ab hier ist das Passwort nur noch im Aufrufstapel dieses
        // einen Laufs.** Es wird nirgends zwischengespeichert.
        // **`self` bewusst stark**, über beide Stufen: Ein Lauf hält den
        // Port. Würde das Modell währenddessen verschwinden, käme der
        // Bericht nirgends an und der Besitz würde nie freigegeben.
        // Ein Zyklus entsteht nicht — der Block ist flüchtig und wird
        // nach der Ausführung freigegeben.
        dispatcher.runSerialized { [self, dispatcher] in
            let report = activeRun.perform(command, secret: secret)
            dispatcher.deliverOnMain { [self] in
                finishRun(with: report)
            }
        }
        return .started(command)
    }

    // MARK: - Berichtsauswertung (ausschließlich Main Thread)

    /// Nimmt den Bericht **eines tatsächlich gelaufenen `perform`**
    /// entgegen.
    private func finishRun(with report: CommissioningStepReport) {
        // **Kein Aufräumen mehr nötig** (SICK-0330a-1-K2): Die
        // Abbruchlebensdauer ist jetzt atomar an die Laufkante gebunden
        // und wird bereits beim tatsächlichen Rückkehren von `perform`
        // geschlossen (`CommissioningAbortToken.endRun(_:)`, innerhalb
        // von `perform` selbst über `defer`) -- nicht erst hier, bei
        // dieser späteren Main-Thread-Zustellung. Eine Anforderung, die
        // in der Lücke dazwischen eintrifft, findet dort bereits keine
        // reservierte Laufkante mehr vor und verpufft wirkungslos, statt
        // stehen zu bleiben und einen künftigen Aufruf zu vergiften.

        isRunning = false
        phase = report.phase
        auditEntries = report.audit.entries
        observedScanProfileStream = report.observedScanProfileStream
        isPortHeld = report.isPortHeld
        if let verified = report.verifiedBaudRate {
            // Nur übernehmen, nie zurücksetzen: Ein späterer Schritt
            // ohne erneute Verifikation macht eine belegte Rate nicht
            // ungültig.
            verifiedBaudRate = verified
        }

        // **Ein Schließfehler an einem eigentlich zu Ende gegangenen
        // Ablauf ist keine Sackgasse** (SICK-0330a-1-K1, H2/H3): Die
        // Policy leitet das jetzt aus dem **ganzen** Bericht ab, nicht
        // nur aus der Phase — in dieser Lage bleiben Lauf **und** Besitz
        // erhalten, und die Oberfläche bietet ausschließlich den
        // sicheren, ausdrücklichen Schließversuch an.
        allowedSteps = policy.allowedSteps(after: report)

        if report.isFinal {
            let outcome = coordinator.completeCommissioning(with: report)
            if case .released = outcome {
                releasedRunCount += 1
            }
        }
        // **Verworfen wird der Lauf ausschließlich bei einem wirklich
        // finalen Bericht** (SICK-0330a-1-K1, H2) — nie bei
        // `.sessionFinished` allein: Ein gescheitertes Schließen sagt
        // `.sessionFinished`, ohne dass der Port je wirklich frei wurde,
        // und genau diese Instanz braucht der spätere, ausdrücklich
        // ausgelöste Retry.
        if case .sessionFinished = report.phase, report.isFinal {
            run = nil
        }

        notice = CommissioningNotice(Self.describe(report), isAutomatic: true)
        refreshReadiness()
    }

    // MARK: - Texte (im Modell, nicht in der Ansicht)

    /// **Der Hinweis verweist auf die Einstellungen** statt eine
    /// Eingabe zu öffnen (SICK-032a2, Auftragspunkt „fehlt es, direkter
    /// Hinweis auf Einstellungen").
    static func describe(_ usability: ScannerPasswordUsability) -> String {
        switch usability {
        case .notSet:
            return "No scanner password is set. Please add it in Settings — "
                + "then a single tap here is enough. Nothing was sent."
        case .unusable:
            return "The scanner password in Settings does not match what the device expects. "
                + "Nothing was sent."
        case .usable:
            // Strukturell unerreichbar -- ein benutzbarer Wert führt
            // nicht in diesen Zweig. Trotzdem kein geratener Text.
            return "The scanner password could not be used. Nothing was sent."
        }
    }

    static let confirmationRequired =
        "This step modifies the scanner. Please confirm explicitly below."

    /// **Nie „frei" behaupten, wenn der Port real noch offen ist**
    /// (SICK-0330a-1-K1, H2/H3). Knapp, ehrlich, und verweist auf den
    /// einzigen angebotenen Schritt in dieser Lage — den bestehenden
    /// „Fertig"-Schritt (``CommissioningCommand/finishSession``), hier
    /// als erneuter, ausdrücklicher Schließversuch.
    static let closeFailedWhileStoppingText =
        "The process has finished, but closing the port failed — "
            + "it is not free yet. Please tap \"Finish\" again to retry."

    private static func describeRunning(_ command: CommissioningCommand) -> String {
        switch command {
        case .checkStartingRate: return "Preparing the scanner — only checking whether it responds"
        case .enterSettingsMode: return "Requesting settings mode once"
        case .login: return "Sending the authorized customer login once"
        case .setTargetBaudRate: return "Requesting the switch to 38,400 baud once"
        case .connectTargetRate: return "Reopening the port at 38,400 baud and verifying"
        case .switchBaudRate: return "Switching the scanner now"
        case .requestMeasurementMode: return "Requesting measurement mode"
        case .runRateDiagnostics: return "Checking the scanner — only verifying whether it responds"
        case .finishSession: return "Finishing"
        case .abort: return "Aborting"
        }
    }

    private static func describe(_ report: CommissioningStepReport) -> String {
        switch report.phase {
        case .idle:
            return "Nothing executed."
        case .respondingAtStartingRate:
            return "The scanner responds. It is now prepared."
        case .settingsModeEntered:
            return "Settings mode confirmed. The next step awaits your click."
        case .loggedIn:
            return "Authorized customer login confirmed. The next step awaits your click."
        case .baudSwitchAcknowledged:
            return "The scanner confirmed 38,400 baud. The port is still running at 9,600 baud; reconnect it explicitly now."
        case .verified:
            guard let verified = report.verifiedBaudRate else {
                // Strukturell unerreichbar -- `verified` entsteht nur mit
                // belegter Rate. Trotzdem kein geratener Text.
                return "Verified."
            }
            return "Switch confirmed: CRC-valid identity response at \(verified.rawValue) baud."
        case .measurementStreamConfirmed:
            // **Belegt, nicht nur angenommen** (SICK-0330a-0): Dieser
            // Zustand entsteht erst durch einen echten, CRC-validen
            // B0-Frame nach der Anforderung — ACK allein reicht seither
            // nicht mehr aus.
            return "The scanner is continuously sending measurements after the request. "
                + "A new scan stream was observed."
        case .diagnosticsFinished:
            guard !report.isPortHeld else {
                return Self.closeFailedWhileStoppingText
            }
            return "Diagnostics complete. The port is free again."
        case .sessionFinished:
            // **Nie „frei", solange er es real nicht ist**
            // (SICK-0330a-1-K1, H2/H3): `restingDirective == .stop` UND
            // `isPortHeld` heißt, dass das Schließen scheiterte -- der
            // Bericht ist trotz dieser Phase nicht final.
            guard !report.isPortHeld else {
                return Self.closeFailedWhileStoppingText
            }
            return "Done. The port is free again."
        case .failed(let failure):
            // **Ein Fehlschlag bleibt ein Fehlschlag.** Kein
            // Erfolgstext, keine vermutete Zielrate. Seit SICK-032a3
            // sagt er zusätzlich, **was** schiefging -- im ersten realen
            // Lauf stand das ausschließlich im Protokoll.
            //
            // **Ausnahme (SICK-0330a-1-K1, H2/H3):** Ein
            // `.portCloseFailed`, das den Port real noch hält, ist kein
            // abgeschlossener Fehlschlag mit Rückwegempfehlung -- es ist
            // derselbe „Schließen erneut versuchen"-Zustand wie bei den
            // anderen Ruhepunkten, nur zufällig über `.failed` erreicht
            // (der Portwechsel-Schluss der Ratendiagnose meldet sich
            // genauso). Der generische Rückweghinweis (Geräteneustart)
            // wäre hier irreführend: Nichts an diesem Ablauf ist
            // unwiderruflich, nur das Schließen selbst schlug fehl.
            if case .portCloseFailed = failure, report.isPortHeld {
                return Self.closeFailedWhileStoppingText
            }
            return "\(failure.operatorSummary) \(failure.recoveryHint)"
        case .checkingStartingRate, .enteringSettingsMode, .enteringSettingsModeManually,
             .loggingIn, .loggingInManually, .requestingBaudSwitch, .requestingBaudSwitchManually, .closingPort,
             .openingTargetPort, .verifyingTargetRate, .awaitingMeasurementStream,
             .runningDiagnostics:
            return "The process is in an intermediate state."
        }
    }

    private static func describe(_ refusal: SerialPortOwnershipRefusal) -> String {
        switch refusal {
        case .heldByMonitor: return "The live display is still using the port. Please disconnect it first."
        case .heldByCommissioning: return "Commissioning is already using the port."
        case .heldBySimulation: return "The iPhone simulation is still using the port. Please disconnect it first."
        case .heldBySimulationControl: return "The simulation is being switched. One moment."
        case .awaitingRelease: return "The port is being closed. One moment."
        }
    }

    private static func describe(_ reason: CommissioningRunUnavailableReason) -> String {
        switch reason {
        case .noPortSelected:
            return "No port is selected."
        case .pathNotAllowed(let path):
            // Der Pfad ist die eigene, gerade geprüfte Auswahl des
            // Bedienenden und steht ohnehin in der Vorabinformation.
            return "Port \(path) is not allowed for the scanner."
        case .transportUnavailable:
            // **Ein fester Satz ohne jede Fremdnutzlast** (SICK-032a1).
            // Er sagt, was gilt (nichts wurde gesendet) und was zu tun
            // ist — und nennt bewusst keinen Grund, den diese Grenze
            // nicht selbst geprüft hat.
            return "The port could not be opened. Nothing was sent. "
                + "Please check the cable and selection, then try again."
        }
    }
}
