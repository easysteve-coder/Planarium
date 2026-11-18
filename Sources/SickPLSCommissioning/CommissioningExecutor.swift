import SickPLSActiveControl
import SickPLSCore
import SickPLSMacTransport

/// Eine ausdrückliche Bedienhandlung des Einrichtungsablaufs (SICK-031).
///
/// **Geschlossen, ohne freie Parameter.** Keine Adresse, keine Baudrate,
/// kein Rezept — die stehen in ``CommissioningRecipe/r26`` und sind seit
/// SICK-030a (Auflage A4) bewusst nicht wählbar. Wer eine andere
/// Kombination braucht, braucht einen Beleg und einen Slice, keinen
/// Regler.
public enum CommissioningCommand: Equatable, Sendable {
    /// Antwortet das Gerät bei der Ausgangsrate?
    case checkStartingRate
    /// Sendet ausschließlich `20 30` an die festgelegte Scanneradresse
    /// und hält danach an.
    case enterSettingsMode
    /// Sendet genau eine adressierte `20 00`-Anmeldung und hält danach an.
    case login
    /// Sendet ausschliesslich die Umschaltung auf 38.400 Baud und hält
    /// nach deren Bestätigung noch auf der 9600-Verbindung an.
    case setTargetBaudRate
    /// Schließt 9600, öffnet 38.400 und belegt die Rate mit B1.
    case connectTargetRate
    /// **Die eine** überwachte Umschaltung. Verlangt das Geheimnis.
    case switchBaudRate
    /// Der experimentelle Messmodus-Schritt, nur nach belegter
    /// Verifikation.
    case requestMeasurementMode
    /// Die harmlose Ratendiagnose nach einem Fehlschlag (SICK-030a3).
    case runRateDiagnostics
    /// Die Sitzung ausdrücklich beenden — der Freigabepunkt.
    case finishSession
    /// Abbruch aus jeder Lage.
    case abort
}

/// Was nach einer Bedienhandlung herauskam (SICK-031).
///
/// **Trägt nie Bytes, nie einen Payload und nie das Geheimnis** —
/// dieselbe Regel wie ``CommissioningAuditEntry``.
public struct CommissioningStepReport: Equatable, Sendable {
    /// Der Zustand, in dem der Ablauf jetzt steht.
    public let phase: CommissioningPhase
    /// Die Anweisung, bei der er zur Ruhe kam: ``CommissioningDirective/hold``
    /// (weiter möglich, Port gehalten) oder ``CommissioningDirective/stop``
    /// (zu Ende, Port darf frei werden).
    public let restingDirective: CommissioningDirective
    /// Das vollständige, redigierte Protokoll des bisherigen Laufs.
    public let audit: CommissioningAudit
    /// **Ausschließlich** durch eine CRC-valide Identitätsantwort am neu
    /// geöffneten Port bei der Zielrate belegt (Auflage A1). Ein
    /// Messstrom, eine Bestätigung oder ein vermuteter Wechsel setzen sie
    /// nie.
    public let verifiedBaudRate: SerialPortBaudRate?
    /// Ein Messstrom wurde unterwegs beobachtet — **reine Information**.
    public let observedScanProfileStream: Bool
    /// Ob der Ablauf den Port laut dem **echten, vom Executor selbst
    /// beobachteten** Verbindungszustand weiter hält (SICK-0330a-1) —
    /// nicht nur laut dem, was der Reducer als Nächstes bräuchte.
    ///
    /// **Der Unterschied ist der ganze Sinn dieses Felds:** Scheitert das
    /// letzte Schließen eines beendeten Laufs, hält der Reducer den Port
    /// für nicht mehr nötig (die Phase ist terminal), aber die reale
    /// Verbindung ist trotzdem noch offen. `isPortHeld` sagt hier die
    /// Wahrheit über den Port, nicht über den Ablauf.
    public let isPortHeld: Bool

    /// Ob dies eine **wahre** Endlage ist: Der Reducer bei
    /// ``CommissioningDirective/stop`` **und** der Port wirklich nicht
    /// mehr (oder nie) offen (SICK-0330a-1).
    ///
    /// **`closePort()` wird nie vor seinem Ergebnis als erfolgreich
    /// verbucht.** Scheitert das Schließen, bleibt dieses Feld `false`
    /// und ``isPortHeld`` `true`, obwohl der Reducer bereits `.stop`
    /// sagt — der Besitz darf **nur** bei `true` freigegeben werden.
    public let isFinal: Bool
}

/// Führt die Direktiven des geprüften ``CommissioningModel`` auf einer
/// ``CommissioningTransport`` aus (SICK-031).
///
/// ## Die eine Aufgabe
///
/// Der Reducer sagt, was zu tun wäre; diese Klasse tut es und liefert das
/// Ergebnis als **typisiertes Ereignis** zurück. Sie hat dafür
/// ausdrücklich **keine eigene Zustandsmaschine, keine zweite
/// Fristberechnung und keine Wiederholung**: Jede Frist steht als
/// absoluter, monotoner Zeitpunkt in der Direktive (seit SICK-030a), und
/// die belegten Login-Wiederholungen entscheidet allein der Reducer
/// (Auflage A2).
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// - **Der Empfangspuffer wird vor jeder Sendung geleert, nie danach.**
///   Danach geleert verwürfe man genau die Antwort, auf die man wartet.
///   ``CommissioningDirective/requiresReceiveBufferFlush`` sagt, welche
///   Direktiven senden; der Executor liest diese Eigenschaft, statt die
///   Fälle ein zweites Mal aufzuzählen.
/// - **Telegramme entstehen ausschließlich über ``CommissioningTelegram``**
///   und damit über den bestehenden `Frame`-Vertrag. Keine
///   abgeschriebenen Rohbytes, keine zweite CRC.
/// - **Das Geheimnis lebt nur für die Dauer eines ``perform(_:secret:)``**
///   und wird danach fallen gelassen. Es wird nirgends gespeichert,
///   geloggt oder beschrieben; das Audit kennt nur die *Handlung*
///   „Login", nie ihren Inhalt.
/// - **Ein Messstrom (`0xB0`) verlängert keine Frist.** Er wird höchstens
///   als ``AcknowledgementOutcome/observedScanProfile`` eingeliefert;
///   danach wird innerhalb der **verbleibenden** Frist weitergelesen.
/// - **`hold` liest und sendet nichts und behält den Port. `stop`
///   schließt idempotent** — auch nach einem vorangegangenen Öffnungs-
///   oder Schließfehler, wo unter Umständen gar nichts offen ist.
/// - **Kein Autostart.** Diese Klasse tut nichts, bis jemand
///   ``perform(_:secret:)`` ruft. Es gibt keinen Timer, keinen
///   Hintergrund-Thread und keine Wiederholungsautomatik.
///
/// ## Threadvertrag
///
/// ``perform(_:secret:)`` ist **synchron und blockierend**: Es kehrt erst
/// am nächsten Ruhepunkt zurück und wartet dazwischen auf echte Antworten
/// bis zur Frist. Es gehört deshalb **nicht** auf den Main Thread einer
/// Oberfläche. Dieser Slice stellt das Modell bereit; die Einbettung in
/// einen Hintergrund-Thread samt Fortschrittsanzeige gehört zur
/// Bedienoberfläche (SICK-032) und ist hier bewusst **nicht** gebaut —
/// ein hier erfundener Thread wäre eine zweite Lebenszyklusstelle.
public final class CommissioningExecutor {

    private let transport: CommissioningTransport
    private let clock: MonotonicClock
    private var model: CommissioningModel
    /// Nur während eines ``perform(_:secret:)`` gesetzt — siehe
    /// Typkommentar.
    private var secretForCurrentCommand: InstallationSecret?
    /// Die für **diesen** `perform`-Aufruf reservierte Laufkante — nur
    /// während seiner Dauer gesetzt, dieselbe Lauflebensdauer wie
    /// ``secretForCurrentCommand`` (SICK-0330a-1-K2).
    private var currentRunEdge: CommissioningRunEdge?
    /// Buchführung über die **eigene** Verbindung — kein zweiter
    /// Zustandsautomat: Sie sagt nur, ob dieser Executor gerade einen
    /// offenen Port hält, und beantwortet nichts über den Ablauf.
    ///
    /// **Die eine Quelle der Wahrheit für ``CommissioningStepReport/isPortHeld``
    /// und ``CommissioningStepReport/isFinal``** (SICK-0330a-1) — sie wird
    /// ausschließlich beim tatsächlichen Ergebnis eines echten
    /// `transport.openPort`/`transport.closePort` verändert, nie vorher.
    private var hasOpenPort = false
    /// Das produktiv nutzbare, threadsichere Abbruchsignal für einen
    /// gerade blockierenden ``perform(_:secret:)`` (SICK-0330a-1).
    ///
    /// **Über die produktive Laufgrenze erreichbar:** `CommissioningExecutor`
    /// ist die einzige reale Umsetzung von `CommissioningRunning`
    /// (SICK-031/032a); wer eine Instanz hält, kann von jedem Thread aus
    /// ``requestAbort()`` rufen, während `perform` noch in einer
    /// Restfrist liest.
    public let abortToken: CommissioningAbortToken

    public init(
        transport: CommissioningTransport,
        recipe: CommissioningRecipe = .r26,
        clock: MonotonicClock = DarwinMonotonicClock(),
        abortToken: CommissioningAbortToken = CommissioningAbortToken()
    ) {
        self.transport = transport
        self.clock = clock
        self.model = CommissioningModel(recipe: recipe)
        self.abortToken = abortToken
    }

    /// Bequeme Abkürzung für ``abortToken``s `requestAbort()` — derselbe
    /// Aufruf, nur ohne dass ein Aufrufer das Token selbst benennen muss.
    public func requestAbort() {
        abortToken.requestAbort()
    }

    /// Reserviert **synchron, vor dem Einplanen des Hintergrundaufrufs**
    /// eine atomare Laufkante für den kommenden `perform`-Aufruf
    /// (SICK-0330a-1-K2, `CommissioningAborting`).
    ///
    /// Muss vom Aufrufer **vor** dem Übergeben an einen seriellen
    /// Hintergrund-Dispatcher gerufen werden (`CommissioningControlModel
    /// .start(...)`) — sonst könnte eine Anforderung in der Lücke
    /// zwischen Einplanen und tatsächlichem Start ins Leere laufen.
    /// `perform` selbst reserviert am eigenen Beginn dieselbe, bereits
    /// bestehende Kante erneut (``CommissioningAbortToken/beginRunIfNeeded()``
    /// ist idempotent) — ein direkter Aufruf ohne vorherigen externen
    /// `beginRun()` reserviert dort seine eigene, frische Kante.
    public func beginRun() {
        abortToken.beginRunIfNeeded()
    }

    /// Der aktuelle Stand, ohne etwas zu tun.
    public var report: CommissioningStepReport {
        makeReport(restingDirective: model.needsPort ? .hold : .stop)
    }

    /// **Schmale Übernahmegrenze für SICK-0330a** — kein neuer TX-Pfad,
    /// keine zweite B1-Probe, kein Login, kein Baudtelegramm, kein
    /// Port-Reopen.
    ///
    /// Der äußere Standardverbindungslauf hat den Port dieses Executors
    /// (``transport``) **selbst** bereits bei 38.400 geöffnet und über
    /// die bereits abgenommene, eigenständige ``ConnectionPolicyModel``-
    /// Politik eine gültige B1-Antwort erhalten — auf **derselben**
    /// Verbindung. Diese Methode öffnet nichts, sendet nichts und liest
    /// nichts; sie trägt lediglich zwei Fakten in diesen Executor ein,
    /// die er sonst nicht kennen könnte: dass sein eigener `transport`
    /// bereits eine offene Verbindung hält (``hasOpenPort``, damit der
    /// nächste reguläre Sendeversuch — etwa
    /// ``CommissioningCommand/requestMeasurementMode`` — nicht fälschlich
    /// an „Port ist nicht offen" scheitert), und dass die Identität bei
    /// der Zielrate bereits belegt ist
    /// (``CommissioningEvent/identityAlreadyConfirmedAtTargetRate``).
    ///
    /// - Precondition (Vertrag des Aufrufers, **nicht** hier erzwungen):
    ///   Diese Methode wird genau einmal, auf einem frisch gebauten,
    ///   noch nie benutzten Executor (`model.phase == .idle`) gerufen,
    ///   dessen `transport` bereits eine offene 38.400-Verbindung mit
    ///   bestätigter B1-Identität hält. Trifft das nicht zu, meldet der
    ///   Reducer selbst sichtbar ``CommissioningFailure/unexpectedEvent``
    ///   (`.idle` ist die einzige zulässige Ausgangsphase) — nie eine
    ///   stille Falschannahme.
    ///
    /// Kein Abbruchfenster: Diese Methode führt keine blockierende
    /// Ein-/Ausgabe aus, deshalb reserviert und schließt sie **keine**
    /// eigene Laufkante — der Aufrufer prüft Abbruch vor jedem eigenen
    /// Teilschritt selbst, genau wie vor jedem anderen Sendeversuch.
    @discardableResult
    package func adoptAlreadyOpenConnectionWithConfirmedIdentity() -> CommissioningStepReport {
        hasOpenPort = true
        let directive = apply(.identityAlreadyConfirmedAtTargetRate)
        return makeReport(restingDirective: directive == .stop ? .stop : .hold)
    }

    /// Führt **eine** Bedienhandlung aus und läuft bis zum nächsten
    /// Ruhepunkt.
    ///
    /// - Parameter secret: Nur für ``CommissioningCommand/switchBaudRate``
    ///   nötig und dort zwingend. Es wird für die Dauer dieses Aufrufs
    ///   gehalten — einschließlich der belegten Login-Wiederholungen
    ///   — und danach fallen gelassen.
    ///
    /// Reserviert und schließt **seine eigene** Laufkante — der normale,
    /// unveränderte Vertrag für einen direkten/manuellen Aufruf
    /// (SICK-0330a-1-K2/K3). ``StandardConnectionRun`` (SICK-0330a-K1,
    /// H2) verwendet diesen Weg für seine delegierten Teilschritte
    /// **nicht** — sonst würde jeder einzelne `perform`-Aufruf die eine,
    /// laufweite Kante vorzeitig schließen und zwischen zwei
    /// Teilschritten eine neue, unabhängige Generation reservieren, in
    /// deren Lücke ein Abbruch wirkungslos verpuffen könnte. Er ruft
    /// stattdessen ``performUsingLoanedEdge(_:secret:edge:)`` mit der
    /// einen Kante, die er selbst vor Beginn seines `connect(portPath:)`-
    /// Aufrufs reserviert hat.
    @discardableResult
    public func perform(
        _ command: CommissioningCommand,
        secret: InstallationSecret? = nil
    ) -> CommissioningStepReport {
        // **Die atomare Laufkante** (SICK-0330a-1-K2): Wurde sie bereits
        // extern, synchron vor dem Einplanen dieses Aufrufs reserviert
        // (``beginRun()``), wird genau diese unverändert weiterverwendet
        // -- inklusive einer währenddessen schon eingegangenen
        // Abbruchanforderung. Ein direkter Aufruf ohne vorherigen
        // externen `beginRun()` (etwa ein Test) reserviert hier seine
        // eigene, frische Kante. **Geschlossen wird sie unmittelbar dort,
        // wo dieser Aufruf zurückkehrt** -- auf jedem Rückkehrpfad, über
        // `defer`, nie erst bei einer späteren Main-Thread-Zustellung.
        let edge = abortToken.beginRunIfNeeded()
        defer { abortToken.endRun(edge) }
        return performBody(command, secret: secret, edge: edge)
    }

    /// **Paketinterne** Ausführung eines einzelnen Befehls auf einer
    /// bereits vom Orchestrator reservierten, **geliehenen** Laufkante
    /// (SICK-0330a-K1, K1-2) — weder reserviert noch schließt dieser
    /// Aufruf sie; das bleibt allein Sache des Aufrufers
    /// (``StandardConnectionRun``), der dieselbe Kante über mehrere
    /// aufeinanderfolgende Befehle (Ausgangsprüfung, Baudwechsel, MMK)
    /// hinweg unverändert weiterreicht.
    ///
    /// **Kein zweiter Abbruchweg, keine Referenzzählung, kein Polling:**
    /// Dieselbe ``CommissioningAbortToken``-Kante wie bei einem direkten
    /// ``perform(_:secret:)``-Aufruf, nur mit von außen bestimmter
    /// Lebensdauer statt einer hier selbst reservierten.
    @discardableResult
    package func performUsingLoanedEdge(
        _ command: CommissioningCommand,
        secret: InstallationSecret? = nil,
        edge: CommissioningRunEdge
    ) -> CommissioningStepReport {
        performBody(command, secret: secret, edge: edge)
    }

    private func performBody(
        _ command: CommissioningCommand,
        secret: InstallationSecret?,
        edge: CommissioningRunEdge
    ) -> CommissioningStepReport {
        secretForCurrentCommand = secret
        defer { secretForCurrentCommand = nil }
        currentRunEdge = edge
        defer { currentRunEdge = nil }

        var directive = beginRespectingAbort(command)
        while true {
            switch directive {
            case .hold:
                // **Nichts tun und halten.** Kein Lesen, kein Senden,
                // kein Schließen -- der nächste Bedienbefehl setzt auf
                // genau dieser Verbindung auf (Auflage A7).
                return makeReport(restingDirective: .hold)
            case .stop:
                // **Schließen, aber nur, was wirklich noch offen ist —
                // und nie vor seinem Ergebnis als erfolgreich verbucht**
                // (SICK-0330a-1). `closeIfStillOpen()` trägt allein die
                // reale `hasOpenPort`-Wahrheit in den folgenden Bericht;
                // ein gescheitertes Schließen macht diesen Bericht
                // sichtbar **nicht final** und hält den Port sichtbar
                // gehalten -- ein späterer, ausdrücklich ausgelöster
                // Aufruf (z. B. eine Wiederholung von `finishSession`)
                // kann es erneut versuchen.
                closeIfStillOpen()
                return makeReport(restingDirective: .stop)
            case .none:
                // Nichts zu tun, aber auch kein Ruhepunkt -- das
                // entsteht nur aus übersprungenem Rauschen außerhalb
                // einer Wartephase. Weiterlaufen gäbe eine Endlosschleife
                // ohne Ereignis, deshalb ist hier der Rückkehrpunkt.
                return makeReport(restingDirective: model.needsPort ? .hold : .stop)
            default:
                // **Vor jeder neuen Gerätewirkung und zwischen zwei
                // Reducer-Direktiven** (SICK-0330a-1): Diese Stelle ist
                // die einzige, an der `execute(_:)` je gerufen wird --
                // ein hier beobachteter Abbruch verhindert also jedes
                // weitere Öffnen, Leeren, Schreiben oder Lesen.
                if abortToken.consumeIfRequested(for: currentRunEdge) {
                    directive = apply(.operatorAborted)
                    continue
                }
                // **Kein automatischer zweiter Schließversuch im selben
                // Aufruf** (SICK-0330a-1-K1, H3): Ist die gerade
                // ausgeführte Direktive selbst `.closePort` gewesen, hat
                // `execute(_:)` den realen Schließversuch **bereits**
                // gemacht -- ob er gelang, trägt `hasOpenPort` schon
                // vollständig. Liefert der Reducer daraufhin `.stop`,
                // würde die reguläre `.stop`-Behandlung oben
                // `closeIfStillOpen()` ein zweites Mal rufen und einen
                // echten Schließfehler im selben `perform` verbergen,
                // sobald der zweite Versuch zufällig gelänge. Dieser
                // Bericht ist bereits vollständig -- kein Verlust: Bei
                // Erfolg ist `hasOpenPort` längst `false`, bei
                // Fehlschlag bleibt es sichtbar `true`, und ein
                // **späterer, ausdrücklich ausgelöster** Aufruf (etwa
                // `finishSession`) versucht es danach idempotent erneut.
                let wasClosingPort: Bool
                if case .closePort = directive { wasClosingPort = true } else { wasClosingPort = false }
                let result = execute(directive)
                if wasClosingPort, case .stop = result {
                    return makeReport(restingDirective: .stop)
                }
                directive = result
            }
        }
    }

    /// Wendet das angeforderte Ereignis an -- **es sei denn, ein Abbruch
    /// steht schon vor dem allerersten Schritt** (Pflichtnachweis 2).
    ///
    /// Dann geht die angeforderte Bedienhandlung gar nicht erst an den
    /// Reducer: Es gibt kein Open, kein Flush, kein Write, kein Read, und
    /// der einzige Reducer-Übergang ist unmittelbar
    /// ``CommissioningEvent/operatorAborted``.
    private func beginRespectingAbort(_ command: CommissioningCommand) -> CommissioningDirective {
        if abortToken.consumeIfRequested(for: currentRunEdge) {
            return apply(.operatorAborted)
        }
        return apply(event(for: command))
    }

    /// Schließt die **wirklich noch offene** Verbindung — und nur die.
    ///
    /// **`closePort()` wird nie vor seinem Ergebnis als erfolgreich
    /// verbucht** (SICK-0330a-1, Pflichtnachweise 6/7): Gelingt es, gilt
    /// der Port ab jetzt als fort (`hasOpenPort = false`); scheitert es,
    /// bleibt `hasOpenPort` unverändert `true` -- ein späterer,
    /// ausdrücklich ausgelöster `perform`-Aufruf versucht es erneut,
    /// idempotent, ohne dass hier ein automatischer Retry entstünde.
    ///
    /// **War nie ein Port offen, wird gar nicht erst versucht**
    /// (Pflichtnachweis 8) -- kein erfundener Schlussfehler an einem
    /// Transport, der ohnehin nichts zu schließen hätte.
    private func closeIfStillOpen() {
        guard hasOpenPort else { return }
        do {
            try transport.closePort()
            hasOpenPort = false
        } catch {
            // Der Port bleibt sichtbar gehalten -- kein stiller
            // Besitzrelease, kein erfundener Erfolg.
        }
    }

    // MARK: - Direktiven ausführen

    private func execute(_ directive: CommissioningDirective) -> CommissioningDirective {
        switch directive {
        case .openPort(let baudRate):
            do {
                try transport.openPort(baudRate: baudRate)
                hasOpenPort = true
                return apply(.portOpened(baudRate))
            } catch {
                return apply(.portOpenFailed(describe(error)))
            }

        case .closePort:
            // **Der Reducer arbeitet auf dieser Verbindung nicht weiter,
            // gleich ob das Schließen gelingt** -- ein Öffnen bei der
            // anderen Rate folgt erst nach dem bestätigten Schließen.
            // **Aber `hasOpenPort` bildet die reale Verbindung ab, nicht
            // die Reducer-Absicht** (SICK-0330a-1): Ein Fehler beim
            // Schließen heißt nicht, dass die Verbindung fort ist -- sie
            // bleibt hier deshalb bis zum tatsächlichen Erfolg als offen
            // gebucht, damit ein danach folgender `.stop` sie über
            // `closeIfStillOpen()` wirklich noch einmal zu schließen
            // versucht.
            do {
                try transport.closePort()
                hasOpenPort = false
                return apply(.portClosed)
            } catch {
                return apply(.portCloseFailed(describe(error)))
            }

        case .sendIdentityProbe(let address, let deadlineMillis):
            guard let target = ConfirmedTargetAddress(rawValue: address) else {
                // Strukturell unerreichbar -- die Adresse kommt aus dem
                // geschlossenen Rezept. Ein `preconditionFailure` wäre
                // hier ein Absturz im Feld statt eines Befunds.
                return apply(.writeFailed("Invalid target address"))
            }
            return send(
                directive,
                frame: CommissioningTelegram.identityRequest(address: target),
                deadlineMillis: deadlineMillis,
                expecting: .identity
            )

        case .sendSettingsMode(let deadlineMillis):
            guard let secret = secretForCurrentCommand else {
                return apply(.writeFailed("No installation secret provided"))
            }
            return send(
                directive,
                frame: CommissioningTelegram.settingsMode(secret: secret, recipe: model.recipe),
                deadlineMillis: deadlineMillis,
                expecting: .acknowledgement
            )

        case .sendLogin(_, let deadlineMillis):
            guard let secret = secretForCurrentCommand else {
                // **Kein Ersatzwert, kein Testgeheimnis, kein leeres
                // Feld** -- ohne übergebenes Geheimnis geht gar nichts
                // hinaus.
                return apply(.writeFailed("No installation secret provided"))
            }
            return send(
                directive,
                frame: CommissioningTelegram.login(secret: secret, recipe: model.recipe),
                deadlineMillis: deadlineMillis,
                expecting: .acknowledgement
            )

        case .sendBaudSwitch(let deadlineMillis):
            return send(
                directive,
                frame: CommissioningTelegram.baudSwitch(recipe: model.recipe),
                deadlineMillis: deadlineMillis,
                expecting: .acknowledgement
            )

        case .sendMeasurementMode(let deadlineMillis):
            return send(
                directive,
                frame: CommissioningTelegram.measurementMode(recipe: model.recipe),
                deadlineMillis: deadlineMillis,
                expecting: .acknowledgement
            )

        case .none, .hold, .stop:
            return directive
        }
    }

    /// Was auf eine Sendung hin erwartet wird.
    private enum ExpectedResponse {
        case identity
        case acknowledgement
    }

    private func send(
        _ directive: CommissioningDirective,
        frame: Frame,
        deadlineMillis: Int64,
        expecting: ExpectedResponse
    ) -> CommissioningDirective {
        // **Vor dem Schreiben, nie danach** -- und die Direktive selbst
        // sagt, dass es nötig ist (SICK-030a2). Die Prüfung steht hier,
        // damit eine künftige Sendedirektive ohne Leerregel gar nicht
        // erst stillschweigend durchliefe.
        //
        // **Sichtbar melden statt abzustürzen** (Lehre aus SICK-007): Ein
        // `preconditionFailure` wäre im Feld ein Absturz statt eines
        // Befunds.
        guard directive.requiresReceiveBufferFlush else {
            return apply(.writeFailed("Send directive without RX flush rule"))
        }

        // **Die Schleife öffnet bei der Ausgangsrate** — und zwar
        // ausschließlich hier, für den allerersten Schritt (SICK-030a2,
        // Regel 5): Der Reducer gibt dafür bewusst **keine**
        // `openPort`-Direktive, weil der Port ab dem ersten Bedienbefehl
        // der Schleife gehört, sobald ihr der Besitz erteilt wurde
        // (SICK-030a1). **Jeder spätere Portwechsel ist eine
        // ausdrückliche Direktive** und läuft nie durch diesen Zweig —
        // deshalb die enge Bedingung auf genau die Ausgangsprüfung. Eine
        // Sendung ohne offenen Port in jeder anderen Phase ist ein
        // sichtbarer Fehler, nie ein stilles Öffnen bei einer geratenen
        // Rate.
        if !hasOpenPort {
            guard case .checkingStartingRate = model.phase else {
                return apply(.writeFailed("The port is not open."))
            }
            do {
                try transport.openPort(baudRate: model.recipe.startingBaudRate)
                hasOpenPort = true
            } catch {
                return apply(.writeFailed(
                    "The port could not be opened at the starting rate: \(describe(error))."
                ))
            }
        }

        transport.flushReceiveBuffer()

        do {
            try transport.write(frame.encoded())
        } catch {
            return apply(.writeFailed(describe(error)))
        }

        return awaitResponse(deadlineMillis: deadlineMillis, expecting: expecting)
    }

    /// Wartet bis zur **absoluten** Frist des Reducers.
    ///
    /// Es gibt hier **keine zweite Fristberechnung**: `deadlineMillis`
    /// stammt unverändert aus der Direktive, und jeder Leseaufruf bekommt
    /// genau die verbleibende Zeit.
    ///
    /// **Fristende ist allein `remaining <= 0`, nie ein einzelner
    /// Leseaufruf** (SICK-031a, Auflage E2). Der Protokollvertrag sagt
    /// zwar, dass `read` bei Stille nicht vor Ablauf zurückkehrt, aber
    /// das ist eine **Erläuterung, keine Voraussetzung**: Der reale
    /// Adapter reicht `port.read(timeoutMilliseconds:)` unverändert
    /// durch, und `DarwinActiveControlSerialPort` klassifiziert
    /// `EINTR`/`EAGAIN`/`EWOULDBLOCK` als `.timeout` — ein von einem
    /// Signal unterbrochenes `poll(2)` kehrt also **sofort** zurück.
    /// Würde das als Fristende gelten, verbrauchte ein einziges Signal
    /// die begrenzten Login-Wiederholungen. Dieselbe Klasse hat
    /// `BaudProbe.probeOnce` seit SICK-011a über die Restfrist-Schleife
    /// gelöst.
    private func awaitResponse(
        deadlineMillis: Int64,
        expecting: ExpectedResponse
    ) -> CommissioningDirective {
        var parser = StreamParser()

        while true {
            // **Vor jedem blockierenden Read** (SICK-0330a-1,
            // Pflichtnachweis 3): Ein hier beobachteter Abbruch verhindert
            // den nächsten Leseaufruf -- ein bereits laufender einzelner
            // Read wird davon nicht berührt, er ist an dieser Stelle noch
            // gar nicht gestartet.
            if abortToken.consumeIfRequested(for: currentRunEdge) {
                return apply(.operatorAborted)
            }

            let remaining = deadlineMillis - clock.nowMilliseconds()
            guard remaining > 0 else {
                return applyDeadline(expecting: expecting, parser: parser)
            }
            let boundedTimeout = Int32(min(remaining, Int64(Int32.max)))

            let readOutcome = transport.read(timeoutMilliseconds: boundedTimeout)

            // **Nach jedem blockierenden Read** (SICK-0330a-1,
            // Pflichtnachweis 3): Ein währenddessen gesetzter Abbruch
            // lässt genau diesen einen Read noch zu Ende gehen -- sein
            // Ergebnis wird aber nicht mehr ausgewertet, und keine
            // weitere Gerätewirkung außer dem späteren Schließen folgt.
            if abortToken.consumeIfRequested(for: currentRunEdge) {
                return apply(.operatorAborted)
            }

            switch readOutcome {
            case .bytes(let bytes):
                // **Derselbe Reducerpfad wie beim finalen Drain**
                // (SICK-0330a-1-K1, H1): `processFrames(_:expecting:)`
                // ist die **eine** Stelle, die einen decodierten Frame in
                // ein Ereignis übersetzt -- hier wie unten in `.closed`.
                if let directive = processFrames(parser.feed(bytes), expecting: expecting) {
                    return directive
                }

            case .timeout:
                // **Zurück in die Restfrist-Schleife, nicht ans
                // Fristende** (SICK-031a, E2). Sie endet von selbst über
                // `remaining <= 0`; ein vorzeitig zurückgekehrter
                // Leseaufruf verkürzt die Frist damit nicht.
                continue

            case .closed:
                // Die Verbindung endete mitten im Warten. Zuerst die
                // Reste auswerten: Eine vollständige Antwort **oder ein
                // durch `finish()` geborgener B0-Frame** kann im Puffer
                // gestanden haben (SICK-0330a-1-K1, H1) -- ein
                // unvollständiger Kandidat davor kann einen dahinter
                // bereits vollständigen Frame bis zum echten
                // Stromende blockiert haben, und genau dafür gibt es
                // `StreamParser.finish()`. Vorher wurde ein B0 hier
                // ungeprüft übersprungen, statt ihn -- wie im
                // Normalpfad -- als möglichen MMK-Erfolg an den Reducer
                // zu geben.
                if let directive = processFrames(parser.finish(), expecting: expecting) {
                    return directive
                }
                // **Keine stille Stille:** Der Abbruch wird als Fehler
                // gemeldet, nicht als Zeitüberschreitung.
                //
                // Dokumentierte Grenze: Das Ereignisvokabular des
                // geprüften Reducers kennt keinen eigenen Fall für „die
                // Verbindung endete beim Lesen"; `writeFailed` ist der
                // einzige, der aus **jeder** Phase sichtbar und korrekt
                // stoppt. Die Meldung benennt den Fall eindeutig. Ein
                // eigener Ereignisfall wäre eine Änderung am
                // abgenommenen Reducervertrag und gehört in einen
                // eigenen Zuschnitt.
                return apply(.writeFailed("The connection ended before a response could be evaluated."))
            }
        }
    }

    /// Übersetzt eine Folge bereits decodierter Frames in Reducer-
    /// Ereignisse und liefert die **erste wirkende** Direktive — oder
    /// `nil`, wenn keiner der Frames etwas entschieden hat (SICK-0330a-1-K1,
    /// H1).
    ///
    /// **Die eine Stelle für `parser.feed(...)` und `parser.finish()`.**
    /// Ein B0-Frame ist in beiden Fällen dasselbe Ereignis
    /// (``AcknowledgementOutcome/observedScanProfile``) an denselben
    /// Reducerpfad — nie ein bedingungsloses `continue`, das eine gerade
    /// erreichte Direktive (etwa
    /// ``CommissioningPhase/measurementStreamConfirmed``) verwürfe. Für
    /// jeden anderen Frame gilt unverändert die `.none`-Regel
    /// (SICK-032a3a): Was den Ablauf nicht entscheidet, liest innerhalb
    /// derselben Frist weiter, egal woher der Frame stammt.
    private func processFrames(
        _ frames: [Frame], expecting: ExpectedResponse
    ) -> CommissioningDirective? {
        if case .awaitingMeasurementStream = model.phase,
           frames.contains(where: { $0.payload.first == AcknowledgementClassifier.scanProfileCommandByte && !model.recipe.measurementMode.matches($0) }) {
            return apply(.measurementPointCountMismatch)
        }
        for frame in frames {
            let directive: CommissioningDirective
            if frame.payload.first == AcknowledgementClassifier.scanProfileCommandByte {
                directive = apply(.acknowledgement(.observedScanProfile))
            } else {
                directive = applyResponse(for: frame, expecting: expecting)
            }
            if case .none = directive { continue }
            return directive
        }
        return nil
    }

    /// Die Frist ist abgelaufen — und was dabei ankam, entscheidet, ob
    /// das eine Zeitüberschreitung oder ein Decodierfehler war.
    ///
    /// **Der Unterschied ist für die Fehlersuche der ganze Punkt:** „es
    /// kam nichts" heißt falsche Rate, falsches Kabel oder schlafendes
    /// Gerät; „es kam etwas, das kein gültiger Frame war" heißt
    /// Rahmen-, Paritäts- oder Prüfsummenproblem.
    ///
    /// **„Unlesbar" gilt nur, wenn im ganzen Wartefenster kein einziger
    /// gültiger Frame decodiert wurde** (SICK-031a, Auflage E1). Kam
    /// auch nur einer, decodiert die Leitung nachweislich sauber, und
    /// die übrigen Bytes sind das **Fragment eines bekannten Stroms**.
    /// Das ist bei 9600 der Regelfall und nicht die Ausnahme: Der
    /// Scanner sendet dort von sich aus B0-Profile (SICK-012), das
    /// Leeren vor der Sendung räumt nur ab, was schon dasteht, und die
    /// ersten Bytes danach sind mit hoher Wahrscheinlichkeit die
    /// Fortsetzung eines **angeschnittenen** B0-Frames —
    /// `StreamParser.drain` zählt jedes Byte vor dem ersten STX als
    /// Rauschen. Ohne diese Regel meldete ein unbeantwortetes Login
    /// `.undecodable` statt `.deadlineReached`, und der Reducer
    /// verweigerte die **eine** belegte Wiederholung (A2), die den
    /// dokumentierten R26-Verlauf überhaupt erst gelingen ließ.
    ///
    /// **Am Reducer und an A2 ändert das nichts** — die Wiederholung
    /// bleibt an `deadlineReached` gebunden; korrigiert wird allein die
    /// Klassifikation dessen, was am Fristende vorlag. Die
    /// Parserdiagnosen bleiben unangetastet und für die Fehlersuche
    /// verfügbar.
    private func applyDeadline(
        expecting: ExpectedResponse,
        parser: StreamParser
    ) -> CommissioningDirective {
        let sawValidFrame = parser.diagnostics.validFrames > 0
        let sawUndecodableBytes =
            parser.diagnostics.discardedCandidates > 0 || parser.diagnostics.skippedNoiseBytes > 0
        guard sawUndecodableBytes, !sawValidFrame else {
            return apply(.deadlineReached)
        }
        switch expecting {
        case .identity:
            // Die Identitätsprobe kennt keine Wiederholung: Der Befund
            // **ist** hier das Ergebnis.
            return apply(.identityOutcome(.ambiguous))
        case .acknowledgement:
            // **Zuerst der Befund, dann das Fristende** (SICK-032a3a).
            // Der Befund sagt nur, *was* im Fenster lag; beendet wird
            // der Versuch ausschließlich durch `.deadlineReached` --
            // das ist die Stelle, an der die begrenzten Wiederholungen
            // hinausgeht, und zwar nach der vollen Frist.
            //
            // Wo ein Ausgang den Ablauf schon entscheidet (Baudwechsel
            // und Messmodus haben keine Wiederholung und stoppen hier),
            // ist genau das das Ergebnis -- dieselbe `.none`-Regel wie
            // oben.
            let directive = apply(.acknowledgement(.undecodable))
            if case .none = directive {} else { return directive }
            return apply(.deadlineReached)
        }
    }

    /// Ein empfangener Frame als Ereignis — je nachdem, worauf gewartet
    /// wird.
    private func applyResponse(
        for frame: Frame,
        expecting: ExpectedResponse
    ) -> CommissioningDirective {
        switch expecting {
        case .identity:
            return apply(.identityOutcome(identityOutcome(for: frame)))
        case .acknowledgement:
            return apply(.acknowledgement(AcknowledgementClassifier.classify(frame)))
        }
    }

    // MARK: - Übersetzungen

    private func identityOutcome(for frame: Frame) -> IdentityProbeOutcome {
        if IdentityProbe.isExpectedResponse(frame) { return .identified }
        return .unexpectedResponse(commandByte: frame.payload.first ?? 0x00)
    }

    private func event(for command: CommissioningCommand) -> CommissioningEvent {
        switch command {
        case .checkStartingRate:
            return .operatorRequestedStartingRateCheck
        case .enterSettingsMode:
            return .operatorRequestedSettingsMode(secretIsAvailable: secretForCurrentCommand != nil)
        case .login:
            return .operatorRequestedLogin(secretIsAvailable: secretForCurrentCommand != nil)
        case .setTargetBaudRate:
            return .operatorRequestedTargetBaudRate
        case .connectTargetRate:
            return .operatorRequestedTargetRateConnection
        case .switchBaudRate:
            // **Der Reducer erfährt nur, *ob* ein Geheimnis vorliegt** --
            // nie den Wert. Ein Reducer, der es hielte, nähme es in jede
            // Kopie mit.
            return .operatorRequestedBaudSwitch(secretIsAvailable: secretForCurrentCommand != nil)
        case .requestMeasurementMode:
            return .operatorRequestedMeasurementMode
        case .runRateDiagnostics:
            return .operatorRequestedDiagnostics
        case .finishSession:
            return .operatorFinishedSession
        case .abort:
            return .operatorAborted
        }
    }

    /// Kurze, **datenfreie** Meldung. Nie ein Payload, nie ein
    /// Geheimnis — dieselbe Regel wie im Audit.
    private func describe(_ error: Error) -> String {
        switch error {
        case let transportError as CommissioningTransportError:
            switch transportError {
            case .portAlreadyOpen:
                return "The port is already open."
            case .portNotOpen:
                return "The port is not open."
            case .pathNotAllowed:
                return "Path outside of /dev/cu."
            case .openFailed(let message):
                return message
            case .writeFailed(let message):
                return message
            }
        default:
            return "System error"
        }
    }

    @discardableResult
    private func apply(_ event: CommissioningEvent) -> CommissioningDirective {
        model.apply(event, atMillis: clock.nowMilliseconds())
    }

    /// **Die reale ``hasOpenPort``-Buchführung ist hier die Wahrheit für
    /// ``CommissioningStepReport/isPortHeld`` und
    /// ``CommissioningStepReport/isFinal``** (SICK-0330a-1) — nicht
    /// `model.needsPort`. An jedem echten Ruhepunkt stimmen beide
    /// überein (der Ablauf öffnet den Port genau dann, wenn der Reducer
    /// ihn braucht); sie fallen ausschließlich dann auseinander, wenn
    /// das letzte Schließen eines beendeten Laufs fehlschlägt -- und
    /// genau dann muss der Bericht die reale Verbindung zeigen, nicht
    /// die Reducer-Absicht.
    private func makeReport(restingDirective: CommissioningDirective) -> CommissioningStepReport {
        CommissioningStepReport(
            phase: model.phase,
            restingDirective: restingDirective,
            audit: model.audit,
            verifiedBaudRate: model.verifiedBaudRate,
            observedScanProfileStream: model.observedScanProfileStream,
            isPortHeld: hasOpenPort,
            isFinal: restingDirective == .stop && !hasOpenPort
        )
    }
}
