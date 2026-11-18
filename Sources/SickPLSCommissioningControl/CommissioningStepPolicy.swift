import SickPLSCommissioning

/// Welcher Bedienschritt in der aktuellen Lage **angeboten** werden darf
/// (SICK-032a, Bedienvertrag Punkt 4).
///
/// ## Das ist ausdrücklich keine zweite Zustandsmaschine
///
/// Der Auftrag verbietet einen zweiten Ablauf, und das ist hier ernst
/// gemeint: Diese Struktur **entscheidet nichts**. Sie leitet aus der
/// Phase eines ``CommissioningStepReport`` ab, welche Schaltfläche
/// sichtbar sein soll — die **Wahrheit bleibt der Reducer**, der jede
/// falsche Handlung unverändert mit `unexpectedEvent` beantwortet. Wäre
/// diese Ableitung falsch, entstünde kein unerlaubter Ablauf, sondern
/// ein sichtbarer Fehler.
///
/// Der Nutzen ist der umgekehrte: Ein Knopf, der in eine Verweigerung
/// führt, ist eine schlechte Bedienung — und bei einem Vorgang, der das
/// Gerät aktiv umkonfiguriert, ist „was darf ich jetzt" die wichtigste
/// Auskunft der Oberfläche.
///
/// ## Woher die Regeln stammen
///
/// Eins zu eins aus den Ruhepunkten von `CommissioningModel`
/// (SICK-030a/a2/a3):
///
/// - Der Handweg schreitet von `respondingAtStartingRate` über
///   `settingsModeEntered`, `loggedIn` und `baudSwitchAcknowledged` fort.
/// - `operatorRequestedMeasurementMode` nur aus `verified`.
/// - `operatorRequestedDiagnostics` nur aus `failed`.
/// - `operatorFinishedSession` von **jedem** Ruhepunkt.
/// - `operatorAborted` aus jeder Lage — aber nicht mehr, wenn schon
///   nichts mehr läuft.
public struct CommissioningStepPolicy {

    public init() {}

    /// Die erlaubten Schritte **vor** dem ersten Lauf: nur die harmlose
    /// Ausgangsprüfung. **Nie** ein Umschalten ohne vorherige Antwort
    /// des Geräts.
    public static let beforeFirstRun: [CommissioningCommand] = [.checkStartingRate]

    /// Ob ein Schritt vor dem Senden **ausdrücklich bestätigt** werden
    /// muss (SICK-032a2).
    ///
    /// ## Die Regel und warum sie so gezogen ist
    ///
    /// Bis SICK-032a brauchte **jeder** Schritt zwei Handgriffe, auch
    /// die harmlose Ausgangsprüfung (Auflage **E3**). Der Owner hat das
    /// für SICK-032a2 gelockert: ein **primärer Ablauf** für die
    /// harmlosen Vorbereitungsschritte, eine Bestätigung nur noch
    /// unmittelbar vor einer Gerätewirkung.
    ///
    /// Bestätigungspflichtig ist deshalb genau das, was das Gerät
    /// **verändert**:
    ///
    /// - ``CommissioningCommand/switchBaudRate`` — der vom Owner
    ///   benannte Fall; nach einem Fehlschlag ist ein Geräteneustart der
    ///   einzige bekannte Rückweg.
    /// - ``CommissioningCommand/requestMeasurementMode`` — ebenfalls ein
    ///   Konfigurationstelegramm an das Gerät, und seine Wirkung ist
    ///   **nicht belegt**. Es ist kein Vorbereitungsschritt und fällt
    ///   damit nicht unter die Lockerung; es ohne Bestätigung auf einen
    ///   Klick zu legen, wäre eine stille Absenkung der Sicherheit.
    ///
    /// Alles andere sendet höchstens die harmlose Identitätsprobe oder
    /// beendet den Vorgang und geht **auf einen Klick**.
    ///
    /// **`switch` ohne `default`** — ein neuer Befehl muss sich hier
    /// bewusst entscheiden.
    public func requiresConfirmation(_ command: CommissioningCommand) -> Bool {
        switch command {
        case .enterSettingsMode, .login, .setTargetBaudRate, .connectTargetRate,
             .switchBaudRate, .requestMeasurementMode:
            return true
        case .checkStartingRate, .runRateDiagnostics, .finishSession, .abort:
            return false
        }
    }

    /// Die erlaubten Schritte zu einem **Bericht** (SICK-0330a-1-K1,
    /// H2/H3).
    ///
    /// **Der bevorzugte Weg, sobald ein Bericht vorliegt:** Hat der
    /// Reducer stoppen wollen (`restingDirective == .stop`), aber der
    /// Anschluss lebt real noch (`isPortHeld`) — unabhängig davon, ob
    /// die fachliche Phase bereits `.sessionFinished`, `.failed(...)`
    /// oder `.diagnosticsFinished` ist —, dann ist das Schließen
    /// gescheitert. In dieser Lage ist **ausschließlich** ein erneuter,
    /// ausdrücklicher Schließversuch sicher: keine Diagnose, kein neuer
    /// TX-Schritt, kein neuer Run. Sonst gilt unverändert die reine
    /// Phasenableitung.
    public func allowedSteps(after report: CommissioningStepReport) -> [CommissioningCommand] {
        guard report.restingDirective == .stop, report.isPortHeld else {
            return allowedSteps(after: report.phase)
        }
        return [.finishSession]
    }

    /// Die erlaubten Schritte zu einer bloßen Phase — **ohne** Wissen
    /// über den realen Portzustand.
    ///
    /// **`switch` ohne `default`** — eine neue Phase muss sich hier
    /// bewusst entscheiden, statt still die Liste einer anderen zu
    /// erben. Dieselbe Haltung wie bei `needsPort` im Reducer.
    public func allowedSteps(after phase: CommissioningPhase) -> [CommissioningCommand] {
        switch phase {
        case .idle:
            return Self.beforeFirstRun

        case .respondingAtStartingRate:
            return [.enterSettingsMode, .finishSession, .abort]

        case .settingsModeEntered:
            return [.login, .finishSession, .abort]

        case .loggedIn:
            return [.setTargetBaudRate, .finishSession, .abort]

        case .baudSwitchAcknowledged:
            return [.connectTargetRate, .finishSession, .abort]

        case .verified:
            return [.requestMeasurementMode, .finishSession, .abort]

        case .measurementStreamConfirmed:
            return [.finishSession, .abort]

        case .failed:
            // Ein Fehlschlag gibt den Port frei, **aber** die Diagnose
            // ist nur von hier aus erlaubt. Der Lauf bleibt deshalb
            // bestehen; vor dem nächsten Schritt braucht es erneut
            // ausdrücklichen Portzugang.
            return [.runRateDiagnostics, .finishSession]

        case .diagnosticsFinished:
            return [.checkStartingRate, .finishSession]

        case .sessionFinished:
            // Endgültig. Kein Schritt, kein stiller Neubeginn.
            return []

        case .checkingStartingRate, .enteringSettingsMode, .enteringSettingsModeManually,
             .loggingIn, .loggingInManually, .requestingBaudSwitch, .requestingBaudSwitchManually,
             .closingPort,
             .openingTargetPort, .verifyingTargetRate, .awaitingMeasurementStream,
             .runningDiagnostics:
            // Zwischenlagen. In einem **Bericht** können sie nicht
            // vorkommen -- `perform` kehrt erst an einem Ruhepunkt
            // zurück --, und falls doch, ist „nichts anbieten" die
            // richtige Antwort.
            return []
        }
    }
}
