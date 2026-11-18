// StandardConnectionRun.swift
//
// SICK-0330a — der testbare Standardverbindungslauf.
// SICK-0330a-K1 — Batchvorrang, laufweite Abbruchkante, Schlussdominanz,
// geschlossener Bericht, beobachtbarer Fortschritt.
//
// ## Die eine Frage
//
// Kann **ein** testbarer `Verbinden`-Lauf vom ausdrücklich gewählten Port
// bis zum belegten B0-Messstrom gelangen, indem er zuerst rein passiv
// bleibt und nur bei Bedarf genau die bereits abgenommenen
// B1-/Commissioning-Schritte ausführt -- ohne doppelten Portweg, unnötiges
// TX oder Passwort-/Rohdatenleck?
//
// ## Komposition statt Parallelwelt
//
// `ConnectionPolicyModel` (SICK-0330r/K1/K2) bleibt die einzige
// Entscheidung über Fast Path, B1 und die Wahl der aktiven Fortsetzung.
// `CommissioningModel`/`CommissioningExecutor` (SICK-0330a-0/K1,
// SICK-0330a-1/K1/K2/K3) bleiben die einzige Entscheidung und Ausführung
// für Login, Baudwechsel, Verifikation, MMK, Fristen, Login-Wiederholung
// und Commissioning-Audit. Dieser Lauf fügt **kein** zweites
// Telegramm-/CRC-/Login-Wissen hinzu -- er treibt `ConnectionPolicyModel`
// mit einer eigenen, schmalen I/O-Schleife (dieselben Bausteine wie
// `CommissioningExecutor`: `CommissioningTransport`, `StreamParser`,
// `CommissioningTelegram.identityRequest`, `IdentityProbe`,
// `AcknowledgementClassifier`) und übergibt bei Bedarf **denselben**
// bereits offenen Transport an einen neu gebauten `CommissioningExecutor`
// -- über die schmale, **paketinterne** Übernahmegrenze
// `CommissioningExecutor.adoptAlreadyOpenConnectionWithConfirmedIdentity()`
// (SICK-0330a-K1, K1-6) oder über die bestehenden Befehle
// `checkStartingRate`/`switchBaudRate`/`requestMeasurementMode`/
// `finishSession` für den 9600-Fallback.
//
// ## Ein Port, ein Transport, **eine** Laufkante
//
// Pro Lauf gibt es genau einen `CommissioningTransport` (injiziert) und
// genau einen `CommissioningAbortToken`. **Die Kante wird genau einmal
// reserviert -- unmittelbar vor Beginn von `connect(portPath:)` -- und
// genau an dessen Rückkehr atomar geschlossen** (SICK-0330a-K1, K1-2).
// Jeder delegierte `CommissioningExecutor`-Teilschritt läuft über
// `performUsingLoanedEdge(_:secret:edge:)` auf **derselben, geliehenen**
// Kante; er reserviert keine neue und schließt die geliehene nicht. Ohne
// das entstünden zwischen Ausgangsprüfung, Passwort-Lesen, Baudwechsel
// und MMK Lücken, in denen gar keine Generation reserviert ist -- und ein
// dort eintreffender Abbruch verpuffte wirkungslos, obwohl der
// Standardlauf noch läuft.
//
// ## Ein fehlgeschlagener Schluss ist überall dominant
//
// Scheitert irgendein abschließender Portschluss, lautet der öffentliche
// Ausgang `.failed(.portCloseFailed)`, `isPortHeld == true`,
// `isFinal == false` -- unabhängig vom ursprünglichen Anlass (K1-3).
// `retryClose()` führt danach **genau einen** realen Schließversuch aus
// und stützt sich dabei auf die eigene, minimale Buchführung der
// tatsächlich offenen Transportgrenze (``policyHoldsOpenPort`` bzw. die
// `hasOpenPort`-Wahrheit des delegierten Executors) -- **nie** darauf,
// dass `ConnectionPolicyModel` aus einem bereits terminalen
// Fortsetzungszustand noch eine Direktive liefert.
//
// ## Erfolgsgrenze
//
// Ein erfolgreicher Bericht (`phase == .ready(_)`) bedeutet: ein **nach
// Beginn dieses Laufs** empfangener CRC-valider B0-Frame belegt den
// Messstrom, die Verbindung steht bei 38.400 Baud, der Port ist wahr
// gehalten (`isPortHeld == true`, `isFinal == false`) -- **dieser Slice
// schließt einen erfolgreichen Port nicht**. Die spätere Übergabe an RX
// (SICK-0330b) schließt den TX-fähigen Port wirklich, bevor RX beginnt.

import SickPLSActiveControl
import SickPLSCommissioning
import SickPLSCore
import SickPLSMacTransport

// MARK: - Erfolgsweg

/// Welcher der vier möglichen Wege tatsächlich zum Messstrom führte.
public enum StandardConnectionSuccessPath: Equatable, Sendable {
    /// Ein CRC-valider B0-Frame traf innerhalb der passiven
    /// Beobachtungsfrist ein -- kein Flush, kein Write, keine B1-Probe.
    case passiveScanProfile
    /// B0 gewann die Race gegen die B1-Antwort: ein CRC-valider B0-Frame
    /// traf ein, während auf die Antwort der einen B1-Sendung gewartet
    /// wurde -- **an beliebiger Stelle im selben Frame-Batch**
    /// (SICK-0330a-K1, K1-1).
    case scanProfileDuringIdentityProbe
    /// B1 bei 38.400 war belegt; die typisierte aktive Fortsetzung
    /// (``CommissioningEvent/identityAlreadyConfirmedAtTargetRate``) und
    /// genau eine MMK-Anforderung führten zum Messstrom.
    case activeContinuationMeasurementStream
    /// Der vollständige 9600-Fallback (Login, Baudwechsel, Verifikation,
    /// MMK) führte zum Messstrom.
    case commissioningFallbackMeasurementStream

}

/// Über welchen der beiden Wege der delegierte Commissioning-Teil dieses
/// Laufs erreicht wurde -- dieselbe darunterliegende Ausführung
/// (``CommissioningExecutor``) bedient beide.
public enum StandardConnectionCommissioningOrigin: Equatable, Sendable {
    case activeContinuationFromConfirmedIdentity
    case fallbackFromStartingRate
}

/// Wo der **delegierte** Commissioning-Teil dieses Laufs gerade steht --
/// ein eigener, geschlossener und **vollständig datenfreier**
/// Fortschrittstyp (SICK-0330a-K1, Supervisor-Korrektur vom 23.09.2026,
/// H1).
///
/// ## Warum ein eigener Typ statt der eingebetteten `CommissioningPhase`
///
/// Die erste K1-Fassung trug hier die vollständige ``CommissioningPhase``.
/// Deren öffentlicher Fall ``CommissioningPhase/failed(_:)`` kann über
/// ``CommissioningFailure/writeFailed(_:)`` einen **freien
/// Adaptertext** und über ``CommissioningFailure/noDeviceAtStartingRate(_:)``
/// ein **unbekanntes Antwortbyte** führen. Dass der Produktionsweg diese
/// Werte nie erzeugte, schloss die **Typgrenze** nicht: Ein fremder
/// Aufrufer konnte eine öffentliche Standardphase mit einer rohen,
/// textführenden Commissioning-Phase bauen, und ihre Darstellung trug
/// den Text. K1-4 verlangt das Gegenteil, und zwar strukturell.
///
/// Dieser Typ ist deshalb **feldlos**. Jeder Fall benennt einen echten,
/// beobachtbaren Abschnitt; ein Fehlschlag verlässt ihn und erscheint
/// ausschließlich als redigierter ``StandardConnectionFailure``.
public enum StandardConnectionCommissioningStage: Equatable, Hashable, Sendable {
    /// B1 bei 38.400 ist belegt; die typisierte Übernahme der bereits
    /// offenen Verbindung steht unmittelbar bevor. **Der Port gehört zu
    /// diesem Zeitpunkt noch der eigenen Politik-Buchführung** -- ein
    /// hier eintreffender Abbruch schließt ihn selbst (K1-3).
    case adoptingConfirmedIdentity
    /// Die Ausgangsprüfung bei 9600 läuft (bzw. steht unmittelbar bevor).
    case checkingStartingRate
    /// Die Ausgangsprüfung bei 9600 ist bestätigt.
    case respondingAtStartingRate
    /// Der zusammenhängende, blockierende Abschnitt aus Login,
    /// Baudwechsel und anschließender Zielverifikation läuft.
    case loggingInAndSwitchingBaudRate
    /// Die Zielrate 38.400 ist über eine CRC-valide `0xB1`-Identität
    /// belegt (Auflage A1).
    case verifiedAtTargetRate
    /// Die MMK-Anforderung ist hinaus; es wird auf einen **neuen**
    /// CRC-validen B0-Strom innerhalb der festen Stromfrist gewartet
    /// (SICK-0330a-0).
    case awaitingMeasurementStream
    /// Die Ratendiagnose läuft -- dieser Lauf löst sie nie aus; ein
    /// eigener Fall statt eines stillen `default`.
    case runningRateDiagnostics
    /// Die Ratendiagnose ist abgeschlossen -- ebenfalls von diesem Lauf
    /// nie ausgelöst.
    case rateDiagnosticsFinished
    /// Die delegierte Sitzung ist bewusst beendet.
    case sessionFinished
}

// MARK: - Fehler

/// Warum der Lauf ohne Erfolg endet oder gerade steht (SICK-0330a-K1,
/// K1-4).
///
/// **Geschlossen und vollständig datenfrei.** Kein Fall trägt einen
/// rohen ``CommissioningFailure``, ein unbekanntes Kommandobyte, einen
/// freien Fremdfehlertext, einen `Error`, einen Fehlercode, einen Frame
/// oder einen Payload. Die unteren Commissioning-Befunde werden hier
/// **abgebildet, nicht eingebettet** -- fachlich verschiedene Gründe
/// bleiben unterscheidbar, ihre fremde Nutzlast bleibt draußen.
///
/// Die **einzige** Ausnahme ist ``invalidPort(_:)``: Sie trägt den vom
/// Bedienenden selbst ausgewählten Pfad über die bereits abgenommene,
/// geschlossene ``ConnectionPolicyPort/BuildError`` (SICK-0330r-K1, H4)
/// -- das ist seine eigene Eingabe, die ohnehin dauerhaft in der
/// Bedienoberfläche steht, kein Wert aus fremder Hand.
public enum StandardConnectionFailure: Equatable, Sendable {
    /// Der Bedienende hat abgebrochen -- unabhängig davon, ob die eigene
    /// Politik-Schleife oder ein delegierter ``CommissioningExecutor``
    /// gerade lief; beide melden hier denselben, vereinheitlichten Fall.
    case aborted
    /// Start ohne gültigen, ausgewählten Port.
    case invalidPort(ConnectionPolicyPort.BuildError)
    /// Der Port ließ sich nicht öffnen -- im eigenen Fast Path ebenso wie
    /// innerhalb des delegierten 9600-Fallbacks.
    case portOpenFailed
    /// Ein Lesevorgang schlug fehl oder die Verbindung endete beim Lesen.
    case portReadFailed
    /// Eine Sendung schlug fehl -- die eine B1-Probe ebenso wie ein
    /// Telegramm des delegierten Teils.
    case portWriteFailed
    /// Der Port ließ sich nicht schließen -- **dominant gegenüber jedem
    /// anderen Anlass und nicht final** (K1-3): siehe
    /// ``StandardConnectionReport/isFinal``; genau ein ausdrücklicher
    /// ``StandardConnectionRun/retryClose()`` kann real freigeben.
    case portCloseFailed
    /// Das Scanner-Passwort fehlt oder ist unbrauchbar (nicht exakt acht
    /// Bytes) -- gelesen erst nach bestätigter Identität bei 9600, direkt
    /// vor dem Login-/Baudwechsel-Schritt. Es ging kein Login-, Baud-
    /// oder MMK-Telegramm hinaus.
    case missingOrUnusablePassword
    /// Der produktive Verbindungsweg ist auf reine passive Übernahme
    /// gestellt. Vorbereitende TX-Schritte müssen im Support-Bereich
    /// einzeln vom Bedienenden ausgelöst werden.
    case manualPreparationRequired
    /// Ein Ereignis traf ein, das an dieser Stelle nicht vorgesehen ist
    /// -- bei diszipliniertem Aufruf strukturell unerreichbar, aber ein
    /// eigener Fall statt eines stillen Ignorierens.
    case unexpectedEvent

    // MARK: Die abgebildeten Commissioning-Befunde (K1-4)

    /// Ausgangsprüfung bei 9600: **keine** Antwort.
    case startingRateSilent
    /// Ausgangsprüfung bei 9600: eine Antwort mit einem anderen
    /// Kommandobyte -- **welches, bleibt draußen** (zwei verschiedene
    /// unbekannte Bytes ergeben denselben Wert).
    case startingRateUnexpectedResponse
    /// Ausgangsprüfung bei 9600: eine unlesbare Antwort.
    case startingRateAmbiguousResponse
    case settingsModeRejected
    case settingsModeUnanswered
    case settingsModeAmbiguous
    case loginRejected
    case loginUnanswered
    case loginAmbiguous
    case baudSwitchRejected
    case baudSwitchUnanswered
    case baudSwitchAmbiguous
    /// Zielverifikation bei 38.400: **keine** Antwort -- der Wechsel ist
    /// damit nicht belegt (Auflage A1).
    case targetRateSilent
    /// Zielverifikation bei 38.400: eine Antwort mit einem anderen
    /// Kommandobyte -- **welches, bleibt draußen**.
    case targetRateUnexpectedResponse
    /// Zielverifikation bei 38.400: eine unlesbare Antwort.
    case targetRateAmbiguousResponse
    /// Das Gerät hat die MMK-Anforderung abgelehnt.
    case measurementModeRejected
    /// Nach der MMK-Anforderung kam innerhalb der festen Stromfrist kein
    /// neuer, CRC-valider B0-Strom (SICK-0330a-0).
    case measurementStreamAbsent
    case measurementPointCountMismatch
}

// MARK: - Zustand

/// Wo der Standardverbindungslauf gerade steht (SICK-0330a).
///
/// **Jeder `switch` über diesen Typ in diesem Ziel steht ohne `default`**
/// -- ein neuer Fall zwingt jeden Aufrufer zu einer bewussten
/// Entscheidung (K1-5).
public enum StandardConnectionPhase: Equatable, Sendable {
    /// Vor dem Beginn.
    case idle
    /// Der Port ist offen; die feste, im Code benannte Gesamtfrist
    /// (``StandardConnectionRun/passiveObservationTimeoutMilliseconds``)
    /// beobachtet ausschließlich eingehende Frames -- kein Flush, kein
    /// Write, keine B1-Probe, kein Passwortzugriff.
    case observingPassively
    /// Die passive Frist ist ohne B0 abgelaufen; die eine harmlose
    /// B1-Identitätsprobe bei 38.400 ist unterwegs.
    case checkingIdentityAtTargetRate
    /// Der delegierte, bereits abgenommene Commissioning-Teil läuft --
    /// benannt über den eigenen, **datenfreien**
    /// ``StandardConnectionCommissioningStage`` (deckt sowohl die aktive
    /// Fortsetzung aus bereits bestätigtem B1 als auch den vollständigen
    /// 9600-Fallback samt der gemeinsamen MMK-Stromwartephase ab).
    ///
    /// **Weder eine rohe ``CommissioningPhase`` noch ein
    /// ``CommissioningFailure`` kann diesen Fall erreichen** -- auch
    /// nicht konstruiert von außen: Der Assoziativwert kennt beide Typen
    /// gar nicht (K1-4, Supervisor-Korrektur H1).
    case runningCommissioning(StandardConnectionCommissioningStage, origin: StandardConnectionCommissioningOrigin)
    /// Belegt: ein CRC-valider B0-Frame nach Beginn dieses Laufs.
    case ready(StandardConnectionSuccessPath)
    case failed(StandardConnectionFailure)
}

// MARK: - Audit

/// Eine benannte Handlung dieses Laufs -- nie Bytes, nie Payload
/// (SICK-0330a).
public enum StandardConnectionAuditAction: Equatable, Sendable {
    case openPort(SerialPortBaudRate)
    case observeForScanProfile(SerialPortBaudRate)
    case identityProbeAtTargetRate(SerialPortBaudRate)
    case closePort
}

/// Wie eine Handlung ausging -- redigiert, nie das Rohbyte: zwei
/// verschiedene unbekannte Antworten während der B1-Probe ergeben beide
/// ``identityGap(_:)`` mit
/// ``ConnectionPolicyIdentityGap/unexpectedResponse`` -- derselben,
/// bereits datenfreien Kategorie von ``ConnectionPolicyIdentityGap``
/// (SICK-0330r-K2).
public enum StandardConnectionAuditOutcome: Equatable, Sendable {
    case opened
    case scanProfileObserved
    case timedOut
    case identityGap(ConnectionPolicyIdentityGap)
    case identified
    case closed
    case aborted
    case readFailed
    case writeFailed
    case openFailed
    case closeFailed
}

public struct StandardConnectionAuditEntry: Equatable, Sendable {
    public let action: StandardConnectionAuditAction
    public let monotonicMillis: Int64
    public let outcome: StandardConnectionAuditOutcome
}

/// Das geordnete, redigierte Protokoll eines Laufs (SICK-0330a).
///
/// **Enthält nie Rohframes, Payloads, unbekannte Bytes, freie fremde
/// Fehlertexte oder das Passwort.** Das bestehende ``CommissioningAudit``
/// des delegierten Commissioning-Teils wird **typisiert eingebettet**,
/// sobald dieser Lauf ihn tatsächlich einsetzt -- `nil`, solange der
/// passive oder der B1-Pfad genügte.
public struct StandardConnectionAudit: Equatable, Sendable {
    public private(set) var entries: [StandardConnectionAuditEntry] = []
    public internal(set) var commissioning: CommissioningAudit?

    public init() {}

    mutating func record(
        _ action: StandardConnectionAuditAction,
        outcome: StandardConnectionAuditOutcome,
        atMillis: Int64
    ) {
        entries.append(StandardConnectionAuditEntry(action: action, monotonicMillis: atMillis, outcome: outcome))
    }
}

// MARK: - Bericht

/// Der geschlossene Bericht eines ``StandardConnectionRun`` (SICK-0330a).
///
/// **`isPortHeld`/`isFinal` sind wahr ausgewiesen** -- sie spiegeln
/// niemals nur eine Reducer-Absicht, sondern die tatsächlich beobachtete
/// Verbindung, genau wie ``CommissioningStepReport`` es seit
/// SICK-0330a-1 tut.
public struct StandardConnectionReport: Equatable, Sendable {
    public let phase: StandardConnectionPhase
    public let audit: StandardConnectionAudit
    public let isPortHeld: Bool
    public let isFinal: Bool
}

/// Die schmale, injizierbare Fortschrittsgrenze (SICK-0330a-K1, K1-5).
///
/// **Sie startet nichts.** Kein Thread, kein Timer, kein Combine-Modell
/// -- sie wird synchron, auf demselben Thread, aus dem noch laufenden
/// ``StandardConnectionRun/connect(portPath:)`` heraus gerufen.
/// SICK-0330b/0331 kann damit Fortschritt anzeigen, ohne interne Felder
/// oder die Transportgrenze zu lesen.
///
/// - Important: Der Sink darf **keine weitere Gerätewirkung auslösen** --
///   nicht in den Lauf zurückrufen, keinen Port anfassen, nichts senden.
///   Er bekommt einen fertigen, in sich wahren Bericht und nimmt ihn
///   entgegen.
public typealias StandardConnectionProgressHandler = (StandardConnectionReport) -> Void

// MARK: - Der Lauf

/// Ein synchroner, blockierender, vollständig injizierbarer
/// Standardverbindungslauf (SICK-0330a).
///
/// Eine einzige öffentliche Startoperation (``connect(portPath:)``), ein
/// kooperativer Abbruchweg (``requestAbort()``/``beginRun()``, dieselbe
/// Laufkantenmechanik wie ``CommissioningExecutor``), eine schmale
/// Fortschrittsgrenze und ein geschlossener Bericht. **Startet selbst
/// keinen Thread und keinen Timer** -- die spätere Oberfläche dispatcht
/// diesen Lauf (SICK-0330b).
///
/// Eine Instanz bedient **genau einen** Verbindungsversuch für **genau
/// einen** Port; ein zweiter ``connect(portPath:)``-Aufruf auf derselben
/// Instanz ändert nichts und liefert unverändert den zuletzt erreichten
/// Bericht.
public final class StandardConnectionRun {

    /// Die eine, feste, hier benannte Gesamtfrist des passiven Fast Path
    /// (Abschnitt 1) -- **kein UI-Regler**, absolut monoton ab dem
    /// Öffnen des Ports.
    ///
    /// Bewusst kürzer als ``CommissioningRecipe/responseTimeoutMilliseconds``
    /// (2000 ms): Ein Scanner, der bereits einen Messstrom sendet
    /// (SICK-012: real beobachtet bei 9600 **und** bei 38.400), zeigt das
    /// binnen weniger Profile -- ein längeres Warten verzögerte nur den
    /// Fall, in dem tatsächlich eine B1-Probe nötig ist.
    public static let passiveObservationTimeoutMilliseconds: Int64 = 1_500

    private let transport: CommissioningTransport
    private let clock: MonotonicClock
    private let passwordStore: ScannerPasswordStoring
    private let recipe: CommissioningRecipe
    private let onProgress: StandardConnectionProgressHandler?
    private let allowsAutomaticCommissioning: Bool

    /// Geteilt mit jedem später gebauten ``CommissioningExecutor`` --
    /// dieselbe Laufkante, kein zweiter Abbruchweg.
    public let abortToken: CommissioningAbortToken

    private var policy = ConnectionPolicyModel()
    private var audit = StandardConnectionAudit()
    private var executor: CommissioningExecutor?
    private var commissioningOrigin: StandardConnectionCommissioningOrigin?
    private var scanProfileObservedDuringIdentityCheck = false
    private var wrongMeasurementPointCount = false

    /// **Die minimale, geschlossene Buchführung der tatsächlich offenen
    /// Transportgrenze** (K1-3) -- ausschließlich am realen Ergebnis
    /// eines echten `openPort`/`closePort` verändert, nie aus einer
    /// Reducerphase erraten. Sie gilt, solange die eigene Politik-Schleife
    /// den Port hält; sobald ein delegierter ``CommissioningExecutor``
    /// übernimmt, führt **dessen** eigene `hasOpenPort`-Wahrheit die
    /// Verbindung weiter (sichtbar über ``CommissioningStepReport/isPortHeld``).
    private var policyHoldsOpenPort = false

    /// Der Ausgang, den ein **später erfolgreicher** ``retryClose()``
    /// melden soll (K1-3): Ein fehlgeschlagener Schluss ist öffentlich
    /// dominant, aber er löscht den ursprünglichen Anlass nicht -- sobald
    /// der Port wirklich frei ist, zeigt der Bericht wieder ihn.
    private var outcomeBehindACloseFailure: StandardConnectionPhase?

    /// Welche Art Transportfehler zuletzt ``.connectionLost(_:)``
    /// auslöste -- ``ConnectionPolicyIOFailure`` ist bewusst feldlos
    /// (SICK-0330r-K1, H4); diese lokale, orchestratoreigene Zuordnung
    /// gibt dem **eigenen** Bericht die vom Auftrag verlangte
    /// Lese-/Schreib-Unterscheidung, ohne den abgenommenen Reducer
    /// anzufassen.
    private var lastConnectionLostWasWrite = false

    /// Die zuletzt **gemeldete** Phase -- damit die Fortschrittsfolge
    /// echte Übergänge zeigt und nicht denselben Zustand mehrfach.
    private var lastPublishedPhase: StandardConnectionPhase?

    /// Der zuletzt **beobachtete** Bericht des delegierten Teils
    /// (SICK-0330b) -- die einzige Grundlage, auf der
    /// ``releasePortForMeasurement()`` den Erfolg und die reale
    /// Porthaltung des Executors kennt. Nie aus einer Absicht abgeleitet.
    private var lastDelegatedReport: CommissioningStepReport?


    public init(
        transport: CommissioningTransport,
        passwordStore: ScannerPasswordStoring,
        recipe: CommissioningRecipe = .r26,
        measurementMode: ScannerMeasurementMode = .mmk,
        clock: MonotonicClock = DarwinMonotonicClock(),
        abortToken: CommissioningAbortToken = CommissioningAbortToken(),
        allowsAutomaticCommissioning: Bool = true,
        onProgress: StandardConnectionProgressHandler? = nil
    ) {
        self.transport = transport
        self.passwordStore = passwordStore
        self.recipe = recipe.selectingMeasurementMode(measurementMode)
        self.clock = clock
        self.abortToken = abortToken
        self.allowsAutomaticCommissioning = allowsAutomaticCommissioning
        self.onProgress = onProgress
    }

    /// Fordert an, dass die aktuell reservierte Laufkante so bald wie
    /// kooperativ möglich mit ``StandardConnectionFailure/aborted`` endet.
    /// Von jedem Thread aus sicher aufrufbar.
    ///
    /// **Wirkt ausschließlich auf eine bereits reservierte Kante**
    /// (``CommissioningAbortToken``, SICK-0330a-1-K3): zwischen zwei
    /// Läufen -- insbesondere unmittelbar nach der Rückkehr von
    /// ``connect(portPath:)`` -- verpufft die Anforderung wirkungslos und
    /// trifft auch keinen späteren ``retryClose()``.
    public func requestAbort() {
        abortToken.requestAbort()
    }

    /// Reserviert synchron, vor dem Einplanen eines Hintergrundaufrufs,
    /// eine Laufkante für den kommenden ``connect(portPath:)``-Aufruf --
    /// dasselbe Muster wie ``CommissioningExecutor/beginRun()``.
    public func beginRun() {
        abortToken.beginRunIfNeeded()
    }

    // MARK: - Start

    /// Der eine Standardverbindungslauf: vom ausdrücklich gewählten Port
    /// bis zum belegten Messstrom, nur so aktiv wie nötig.
    ///
    /// **Genau eine Laufkante, atomar an der Rückkehr geschlossen**
    /// (K1-2): Jeder Rückkehrpfad -- passiver Erfolg, ungültiger Port,
    /// Policy-Fehler, Abbruch, aktiver Erfolg, delegierter Fehlschlag --
    /// läuft durch dasselbe `defer`.
    @discardableResult
    public func connect(portPath: String) -> StandardConnectionReport {
        guard case .idle = policy.phase, executor == nil else {
            return currentReport()
        }

        let edge = abortToken.beginRunIfNeeded()
        defer { abortToken.endRun(edge) }

        // Pflichtnachweis „vor erster Wirkung": `.openingPort` erwartet
        // strukturell ein tatsächlich hinausgegangenes Öffnen -- ein hier
        // beobachteter Abbruch geht deshalb **nie** an den Reducer,
        // sondern wird direkt gemeldet: nichts wurde je vorgesehen oder
        // geöffnet.
        if abortToken.consumeIfRequested(for: edge) {
            return finish(StandardConnectionReport(
                phase: .failed(.aborted), audit: audit, isPortHeld: false, isFinal: true
            ))
        }

        let directive = policy.apply(.operatorRequestedConnection(portPath: portPath))
        return finish(drivePolicy(directive, edge: edge))
    }

    /// Ein ausdrücklich ausgelöster Schluss-Retry -- der einzige Weg, aus
    /// einem nicht finalen ``StandardConnectionFailure/portCloseFailed``
    /// einen wirklich noch gehaltenen Port real freizugeben (K1-3).
    ///
    /// **Ein eigener, ausdrücklich ausgelöster Lauf mit eigener frischer
    /// Kante** (K1-2) -- eine Abbruchanforderung, die nach der Rückkehr
    /// von ``connect(portPath:)`` einging, ist zu diesem Zeitpunkt längst
    /// verpufft und kann diesen Retry nicht treffen.
    ///
    /// Führt **genau einen** realen Schließversuch aus: Erfolg meldet
    /// portfrei/final (mit dem ursprünglichen Anlass als Ausgang),
    /// erneuter Fehlschlag bleibt porthaltend/nicht final. Wirkungslos
    /// (liefert den zuletzt erreichten Bericht unverändert), solange kein
    /// Port wirklich noch offen ist.
    @discardableResult
    public func retryClose() -> StandardConnectionReport {
        let edge = abortToken.beginRunIfNeeded()
        defer { abortToken.endRun(edge) }

        if let executor {
            let stepOutcome = executor.performUsingLoanedEdge(.finishSession, edge: edge)
            return finish(translateCommissioningReport(
                stepOutcome, origin: commissioningOrigin ?? .fallbackFromStartingRate
            ))
        }
        guard policyHoldsOpenPort else { return currentReport() }
        return finish(retryPolicyOwnedClose())
    }

    /// Schließt den nach einem Erfolg bewusst offen gehaltenen TX-fähigen
    /// Port **wirklich**, bevor RX beginnen darf (SICK-0330b).
    ///
    /// ## Warum ein eigener Weg neben ``retryClose()``
    ///
    /// ``retryClose()`` löst ausschließlich einen zuvor **gescheiterten**
    /// Schluss auf und kehrt zu dem Anlass zurück, der hinter dem
    /// Schließfehler stand. Nach einem Erfolg (`phase == .ready(_)`) gibt
    /// es keinen Schließfehler und keinen hinterlegten Anlass -- der
    /// Erfolgsweg selbst ist der Anlass, und er muss den Schluss
    /// überleben: Der Bericht nach dem Schließen lautet weiterhin
    /// `.ready(path)`, jetzt mit `isPortHeld == false`, `isFinal == true`.
    ///
    /// **Genau ein realer Schließversuch.** Scheitert er, gilt dieselbe
    /// Dominanzregel wie überall (K1-3): öffentlich
    /// ``StandardConnectionFailure/portCloseFailed``, Port gehalten, nicht
    /// final, und der Erfolgsweg bleibt als Ausgang hinterlegt, bis ein
    /// ausdrücklicher ``retryClose()`` wirklich freigibt. Ein Aufruf ohne
    /// erreichten Erfolg oder ohne wirklich offenen Port ändert nichts
    /// und liefert den zuletzt erreichten Bericht.
    ///
    /// Die RX-Sitzung darf **ausschließlich** nach einem Bericht mit
    /// `isPortHeld == false` beginnen; der Aufrufer (das
    /// Verbindungsmodell) prüft genau dieses Feld, nie eine Absicht.
    @discardableResult
    public func releasePortForMeasurement() -> StandardConnectionReport {
        guard case .ready(let path) = currentSuccessPhase() else {
            return currentReport()
        }
        let edge = abortToken.beginRunIfNeeded()
        defer { abortToken.endRun(edge) }

        if let executor, let delegated = lastDelegatedReport {
            guard delegated.isPortHeld else { return currentReport() }
            outcomeBehindACloseFailure = .ready(path)
            let stepOutcome = executor.performUsingLoanedEdge(.finishSession, edge: edge)
            return finish(translateCommissioningReport(
                stepOutcome, origin: commissioningOrigin ?? .fallbackFromStartingRate
            ))
        }
        guard policyHoldsOpenPort else { return currentReport() }
        outcomeBehindACloseFailure = .ready(path)
        let event = performClose()
        return finish(resolveOwnCloseAttempt(event))
    }

    /// Der Erfolgsweg des zuletzt erreichten Zustands, oder `nil`, wenn
    /// der Lauf nicht erfolgreich war -- gleich, ob der Erfolg auf der
    /// eigenen Politik-Schleife oder im delegierten Teil entstand.
    ///
    /// Für den delegierten Teil zählt der **zuletzt beobachtete**
    /// Bericht eines wirklich gelaufenen Befehls, nie eine Absicht.
    private func currentSuccessPhase() -> StandardConnectionPhase? {
        if executor != nil {
            guard let delegated = lastDelegatedReport,
                  case .measurementStreamConfirmed = delegated.phase else { return nil }
            return mapCommissioningPhase(
                .measurementStreamConfirmed, origin: commissioningOrigin ?? .fallbackFromStartingRate
            )
        }
        guard case .ready = policy.phase else { return nil }
        return currentPhase()
    }

    /// Der Schließ-Retry der **eigenen** Politik-Schleife -- getrieben
    /// von ``policyHoldsOpenPort``, nicht von einer Reducer-Direktive
    /// (K1-3).
    ///
    /// Steht der Reducer noch in einer Phase, die ein bestätigtes
    /// Schließen fachlich weiterführt (``ConnectionPolicyPhase/closingPort(_:)``
    /// / ``ConnectionPolicyPhase/closeFailed(_:reason:)`` -- der eigens
    /// dafür gebaute, **nichtterminale** Zustand aus SICK-0330r-K1, H2),
    /// bekommt er das Ergebnis wie gewohnt; steht er terminal (etwa
    /// ``ConnectionPolicyPhase/continuingActively`` nach einem Abbruch in
    /// der Übergabelücke), entscheidet allein die eigene Buchführung.
    private func retryPolicyOwnedClose() -> StandardConnectionReport {
        let event = performClose()
        switch policy.phase {
        case .closingPort, .closeFailed:
            return drivePolicyWithoutIO(policy.apply(event))
        case .idle, .openingPort, .awaitingScanProfile, .ready,
             .checkingIdentityAtTargetRate, .continuingActively,
             .continuingViaCommissioning, .failed:
            return resolveOwnCloseAttempt(event)
        }
    }

    /// Das Ergebnis eines eigenen, ausdrücklichen Schließversuchs in
    /// einem Zustand, den der Reducer nicht mehr fortführt.
    private func resolveOwnCloseAttempt(_ event: ConnectionPolicyEvent) -> StandardConnectionReport {
        switch event {
        case .portClosed:
            let resolved = outcomeBehindACloseFailure ?? .failed(.aborted)
            outcomeBehindACloseFailure = nil
            return StandardConnectionReport(
                phase: resolved, audit: audit, isPortHeld: false, isFinal: true
            )
        case .portCloseFailed, .operatorRequestedConnection, .operatorAborted, .portOpened,
             .portOpenFailed, .validScanProfileObserved, .observationTimedOut,
             .identityOutcome, .connectionLost:
            // Nur `performClose()` erzeugt dieses Ereignis, und es kennt
            // genau zwei Ausgänge. Explizit statt `default`, damit ein
            // neuer `ConnectionPolicyEvent`-Fall hier sichtbar entschieden
            // werden muss (K1-5).
            return StandardConnectionReport(
                phase: .failed(.portCloseFailed), audit: audit, isPortHeld: true, isFinal: false
            )
        }
    }

    // MARK: - Die Politik-getriebene Schleife (Abschnitt 1 und 2)

    private func drivePolicy(
        _ initial: ConnectionPolicyDirective, edge: CommissioningRunEdge
    ) -> StandardConnectionReport {
        var directive = initial
        while true {
            switch directive {
            case .none:
                return currentReport()
            case .openPort, .closePort:
                directive = policy.apply(execute(directive, edge: edge))
            case .observeForScanProfile:
                // **Unmittelbar vor dem blockierenden Abschnitt** (K1-5):
                // Der Port ist zu diesem Zeitpunkt wirklich offen, und
                // `currentReport()` liest das aus der eigenen
                // Buchführung -- nicht aus einer Reducer-Absicht.
                publish(currentReport())
                directive = policy.apply(execute(directive, edge: edge))
            case .sendIdentityProbeAtTargetRate:
                guard allowsAutomaticCommissioning else {
                    return stopForManualPreparation()
                }
                publish(currentReport())
                directive = policy.apply(execute(directive, edge: edge))
            case .requestActiveContinuation(_, let baudRate):
                return beginActiveContinuation(baudRate: baudRate, edge: edge)
            case .requestCommissioningContinuation(_, let gap, let baudRate):
                return beginCommissioningFallback(gap: gap, baudRate: baudRate, edge: edge)
            }
        }
    }

    /// Beendet den rein passiven Produktionslauf vor dem ersten TX.
    /// Der Port wird real geschlossen; ein Schließfehler bleibt wie in
    /// allen anderen Pfaden dominant und explizit wiederholbar.
    private func stopForManualPreparation() -> StandardConnectionReport {
        outcomeBehindACloseFailure = .failed(.manualPreparationRequired)
        switch performClose() {
        case .portClosed:
            outcomeBehindACloseFailure = nil
            return StandardConnectionReport(
                phase: .failed(.manualPreparationRequired), audit: audit,
                isPortHeld: false, isFinal: true
            )
        case .portCloseFailed, .operatorRequestedConnection, .operatorAborted, .portOpened,
             .portOpenFailed, .validScanProfileObserved, .observationTimedOut,
             .identityOutcome, .connectionLost:
            return StandardConnectionReport(
                phase: .failed(.portCloseFailed), audit: audit,
                isPortHeld: true, isFinal: false
            )
        }
    }

    /// Dieselbe Schleife ohne jede weitere echte Wirkung -- für den
    /// Schluss-Retry, der seinen einen realen Schließversuch schon
    /// gemacht hat und nur noch dessen Folgezustand auflösen darf.
    /// **Genau ein realer Schließversuch je `retryClose()`** (K1-3).
    private func drivePolicyWithoutIO(_ directive: ConnectionPolicyDirective) -> StandardConnectionReport {
        switch directive {
        case .none, .openPort, .observeForScanProfile, .sendIdentityProbeAtTargetRate,
             .closePort, .requestActiveContinuation, .requestCommissioningContinuation:
            return currentReport()
        }
    }

    /// Führt genau eine echte Direktive aus und liefert das Ereignis, das
    /// der Reducer als Antwort bekommt.
    ///
    /// **Kein Abbruch-Vorabcheck für `.openPort`/`.closePort`:** beide
    /// sind kurze, nicht unbegrenzt blockierende Aufrufe -- ein hier
    /// beobachteter Abbruch würde, an den Reducer als
    /// ``ConnectionPolicyEvent/operatorAborted`` gereicht, in
    /// `.openingPort` einen Öffnungsversuch voraussetzen, der real nie
    /// stattfand (dieselbe Falle wie eine erfundene, unbestätigte
    /// Direktive). Abbruch **während** dieser beiden Aufrufe wird beim
    /// nächsten Teilabschnitt beobachtet -- spätestens vor dem nächsten
    /// blockierenden Lesevorgang. Für die beiden echten, fristgebundenen
    /// Lesevorgänge (``performObserve``/``performIdentityProbe``) gilt
    /// der volle Vorab- **und** Nachlesecheck, dieselbe Regel wie in
    /// ``CommissioningExecutor``.
    private func execute(
        _ directive: ConnectionPolicyDirective, edge: CommissioningRunEdge
    ) -> ConnectionPolicyEvent {
        switch directive {
        case .openPort(_, let baudRate):
            return performOpen(baudRate: baudRate)
        case .closePort:
            return performClose()
        case .observeForScanProfile(_, let baudRate):
            if abortToken.consumeIfRequested(for: edge) { return .operatorAborted }
            return performObserve(baudRate: baudRate, edge: edge)
        case .sendIdentityProbeAtTargetRate(_, let baudRate):
            if abortToken.consumeIfRequested(for: edge) { return .operatorAborted }
            return performIdentityProbe(baudRate: baudRate, edge: edge)
        case .none, .requestActiveContinuation, .requestCommissioningContinuation:
            preconditionFailure("execute(_:edge:) wird nur für echte I/O-Direktiven aus drivePolicy(_:edge:) gerufen")
        }
    }

    private func performOpen(baudRate: SerialPortBaudRate) -> ConnectionPolicyEvent {
        let atMillis = clock.nowMilliseconds()
        do {
            try transport.openPort(baudRate: baudRate)
            policyHoldsOpenPort = true
            audit.record(.openPort(baudRate), outcome: .opened, atMillis: atMillis)
            return .portOpened
        } catch {
            audit.record(.openPort(baudRate), outcome: .openFailed, atMillis: atMillis)
            return .portOpenFailed(ConnectionPolicyIOFailure())
        }
    }

    /// **Nie vor seinem Ergebnis als erfolgreich verbucht** -- dieselbe
    /// Regel wie ``CommissioningExecutor``s `closeIfStillOpen()`
    /// (SICK-0330a-1): Scheitert das Schließen, bleibt
    /// ``policyHoldsOpenPort`` sichtbar `true`.
    private func performClose() -> ConnectionPolicyEvent {
        let atMillis = clock.nowMilliseconds()
        do {
            try transport.closePort()
            policyHoldsOpenPort = false
            audit.record(.closePort, outcome: .closed, atMillis: atMillis)
            return .portClosed
        } catch {
            audit.record(.closePort, outcome: .closeFailed, atMillis: atMillis)
            return .portCloseFailed(ConnectionPolicyIOFailure())
        }
    }

    /// Der passive Fast Path (Abschnitt 1): kein Flush, kein Write, keine
    /// B1-Probe -- ausschließlich Lesen, bis ein CRC-valider B0-Frame
    /// eintrifft oder die feste Frist abläuft.
    private func performObserve(baudRate: SerialPortBaudRate, edge: CommissioningRunEdge) -> ConnectionPolicyEvent {
        let startedAtMillis = clock.nowMilliseconds()
        let deadlineMillis = startedAtMillis + Self.passiveObservationTimeoutMilliseconds
        var parser = StreamParser()

        while true {
            if abortToken.consumeIfRequested(for: edge) {
                audit.record(.observeForScanProfile(baudRate), outcome: .aborted, atMillis: startedAtMillis)
                return .operatorAborted
            }
            let remaining = deadlineMillis - clock.nowMilliseconds()
            guard remaining > 0 else {
                audit.record(.observeForScanProfile(baudRate), outcome: .timedOut, atMillis: startedAtMillis)
                return .observationTimedOut
            }
            let boundedTimeout = Int32(min(remaining, Int64(Int32.max)))
            let outcome = transport.read(timeoutMilliseconds: boundedTimeout)
            if abortToken.consumeIfRequested(for: edge) {
                audit.record(.observeForScanProfile(baudRate), outcome: .aborted, atMillis: startedAtMillis)
                return .operatorAborted
            }
            switch outcome {
            case .bytes(let bytes):
                if containsScanProfile(parser.feed(bytes)) {
                    audit.record(.observeForScanProfile(baudRate), outcome: .scanProfileObserved, atMillis: startedAtMillis)
                    return .validScanProfileObserved
                }
                if wrongMeasurementPointCount { return .connectionLost(ConnectionPolicyIOFailure()) }
            case .timeout:
                continue
            case .closed:
                if containsScanProfile(parser.finish()) {
                    audit.record(.observeForScanProfile(baudRate), outcome: .scanProfileObserved, atMillis: startedAtMillis)
                    return .validScanProfileObserved
                }
                lastConnectionLostWasWrite = false
                audit.record(.observeForScanProfile(baudRate), outcome: .readFailed, atMillis: startedAtMillis)
                return .connectionLost(ConnectionPolicyIOFailure())
            }
        }
    }

    /// Die eine harmlose B1-Identitätsprobe bei 38.400 (Abschnitt 2):
    /// leeren, senden, bis zur festen Rezeptfrist lesen. Ein CRC-valider
    /// B0-Frame **irgendwo** in einem gelesenen Frame-Batch gewinnt
    /// sofort (K1-1) -- eine gleichzeitig oder später gelesene B1-Antwort
    /// löst dann keine aktive Fortsetzung mehr aus.
    private func performIdentityProbe(baudRate: SerialPortBaudRate, edge: CommissioningRunEdge) -> ConnectionPolicyEvent {
        let startedAtMillis = clock.nowMilliseconds()
        transport.flushReceiveBuffer()
        let frame = CommissioningTelegram.identityRequest(address: recipe.verificationAddress)
        do {
            try transport.write(frame.encoded())
        } catch {
            lastConnectionLostWasWrite = true
            audit.record(.identityProbeAtTargetRate(baudRate), outcome: .writeFailed, atMillis: startedAtMillis)
            return .connectionLost(ConnectionPolicyIOFailure())
        }

        let deadlineMillis = clock.nowMilliseconds() + recipe.responseTimeoutMilliseconds
        var parser = StreamParser()

        while true {
            if abortToken.consumeIfRequested(for: edge) {
                audit.record(.identityProbeAtTargetRate(baudRate), outcome: .aborted, atMillis: startedAtMillis)
                return .operatorAborted
            }
            let remaining = deadlineMillis - clock.nowMilliseconds()
            guard remaining > 0 else {
                // **„Unlesbar" gilt nur, wenn im ganzen Wartefenster kein
                // einziger gültiger Frame decodiert wurde** (SICK-031a,
                // Auflage E1 -- dieselbe, bereits abgenommene Regel wie in
                // `CommissioningExecutor.applyDeadline`/`BaudProbe`, hier
                // wiederverwendet statt neu erfunden): Kamen unbrauchbare
                // Bytes an, ohne dass je ein valider Frame dabei war, ist
                // das eine unauswertbare Antwort (`.ambiguous`), keine
                // echte Stille (`.timeout`).
                let sawUndecodableBytes =
                    parser.diagnostics.discardedCandidates > 0 || parser.diagnostics.skippedNoiseBytes > 0
                let event = ConnectionPolicyEvent.identityOutcome(
                    sawUndecodableBytes && parser.diagnostics.validFrames == 0 ? .ambiguous : .timeout
                )
                recordIdentityOutcome(event, baudRate: baudRate, atMillis: startedAtMillis)
                return event
            }
            let boundedTimeout = Int32(min(remaining, Int64(Int32.max)))
            let outcome = transport.read(timeoutMilliseconds: boundedTimeout)
            if abortToken.consumeIfRequested(for: edge) {
                audit.record(.identityProbeAtTargetRate(baudRate), outcome: .aborted, atMillis: startedAtMillis)
                return .operatorAborted
            }
            switch outcome {
            case .bytes(let bytes):
                if let event = classifyIdentityFrames(parser.feed(bytes)) {
                    recordIdentityOutcome(event, baudRate: baudRate, atMillis: startedAtMillis)
                    return event
                }
            case .timeout:
                continue
            case .closed:
                if let event = classifyIdentityFrames(parser.finish()) {
                    recordIdentityOutcome(event, baudRate: baudRate, atMillis: startedAtMillis)
                    return event
                }
                lastConnectionLostWasWrite = false
                audit.record(.identityProbeAtTargetRate(baudRate), outcome: .readFailed, atMillis: startedAtMillis)
                return .connectionLost(ConnectionPolicyIOFailure())
            }
        }
    }

    /// Schreibt den Ausgang der B1-Probe ins eigene Audit -- **ohne
    /// `default`** (K1-5): Ein neuer ``ConnectionPolicyEvent``-Fall muss
    /// sich hier sichtbar entscheiden, statt still als „Lesefehler" zu
    /// verschwinden.
    private func recordIdentityOutcome(
        _ event: ConnectionPolicyEvent, baudRate: SerialPortBaudRate, atMillis: Int64
    ) {
        let outcome: StandardConnectionAuditOutcome
        switch event {
        case .validScanProfileObserved:
            outcome = .scanProfileObserved
            // B0 gewann während des Wartens auf die B1-Antwort -- das
            // unterscheidet den Erfolgsweg vom passiven Fast Path im
            // späteren Bericht.
            scanProfileObservedDuringIdentityCheck = true
        case .identityOutcome(.identified):
            outcome = .identified
        case .identityOutcome(.timeout):
            outcome = .identityGap(.timeout)
        case .identityOutcome(.unexpectedResponse):
            outcome = .identityGap(.unexpectedResponse)
        case .identityOutcome(.ambiguous):
            outcome = .identityGap(.ambiguous)
        case .connectionLost:
            outcome = .readFailed
        case .operatorRequestedConnection, .operatorAborted, .portOpened, .portOpenFailed,
             .observationTimedOut, .portClosed, .portCloseFailed:
            // Strukturell unerreichbar: ``performIdentityProbe`` erzeugt
            // ausschließlich die oben behandelten Ereignisse -- der
            // Abbruch schreibt sein Audit selbst. Explizit benannt statt
            // in einem `default` gesammelt.
            outcome = .readFailed
        }
        audit.record(.identityProbeAtTargetRate(baudRate), outcome: outcome, atMillis: atMillis)
    }

    /// Klassifiziert bereits CRC-valide Frames **eines** Lesevorgangs für
    /// die B1-Probe (SICK-0330a-K1, K1-1).
    ///
    /// **Zuerst der ganze Batch auf B0, erst dann die Identitätsantwort.**
    /// Die frühere Fassung entschied am **ersten** Frame -- damit gewann
    /// B0 nur, wenn er zufällig vorne stand; bei `[B1, B0]` löste sie die
    /// aktive Fortsetzung samt MMK aus, bei `[unerwartet, B0]` sogar den
    /// vollständigen 9600-Fallback. Beides widerspricht der verbindlichen
    /// Regel: Trifft während des B1-Fensters ein B0 ein, **ist der
    /// Messstrom bereits belegt** und jede weitere Gerätewirkung
    /// unnötig -- Position und weitere Frames sind egal.
    ///
    /// Enthält der Batch kein B0, entscheidet die **erste** für die
    /// Identitätsprobe relevante Antwort: `0xB1` heißt belegt, jeder
    /// andere Frame ist sofort eine unerwartete Antwort -- die
    /// Identitätsprobe kennt (anders als die ACK-Prüfung) kein
    /// „weiterlesen, bis die Frist abläuft".
    private func classifyIdentityFrames(_ frames: [Frame]) -> ConnectionPolicyEvent? {
        if containsScanProfile(frames) {
            return .validScanProfileObserved
        }
        if wrongMeasurementPointCount { return .connectionLost(ConnectionPolicyIOFailure()) }
        guard let first = frames.first else { return nil }
        if IdentityProbe.isExpectedResponse(first) {
            return .identityOutcome(.identified)
        }
        return .identityOutcome(.unexpectedResponse(commandByte: first.payload.first ?? 0x00))
    }

    private func containsScanProfile(_ frames: [Frame]) -> Bool {
        let profiles = frames.filter { $0.payload.first == AcknowledgementClassifier.scanProfileCommandByte }
        wrongMeasurementPointCount = profiles.contains { !recipe.measurementMode.matches($0) }
        return !wrongMeasurementPointCount && profiles.contains { recipe.measurementMode.matches($0) }
    }

    // MARK: - Übergabe an den delegierten Commissioning-Teil

    /// Abschnitt 2, Schritt 3: B1 bei 38.400 ist belegt. Übergibt die
    /// bereits offene Verbindung über die schmale, paketinterne Grenze
    /// ``CommissioningExecutor/adoptAlreadyOpenConnectionWithConfirmedIdentity()``
    /// -- keine zweite B1-Probe, kein Login, kein Baudtelegramm, kein
    /// Port-Reopen, kein Passwortzugriff -- und fordert danach genau
    /// einmal MMK an.
    private func beginActiveContinuation(
        baudRate: SerialPortBaudRate, edge: CommissioningRunEdge
    ) -> StandardConnectionReport {
        // **Der Fortschrittspunkt nach bestätigtem B1 und vor der
        // Übernahme** (K1-5; Supervisor-Korrektur H2/H3). Er ist nicht
        // bloß Anzeige, sondern der einzige Augenblick, in dem der
        // Eigentümerwechsel des Ports von außen beobachtbar ist: Der
        // 38.400-Port ist wahr gehalten, gehört aber noch der eigenen
        // Politik-Buchführung -- **kein** Executor existiert. Genau
        // deshalb schließt ein hier eintreffender Abbruch ihn selbst
        // (``closePolicyPortAfterAbort``), und ein dabei scheiternder
        // Schluss ist öffentlich dominant (K1-3).
        publish(StandardConnectionReport(
            phase: .runningCommissioning(
                .adoptingConfirmedIdentity, origin: .activeContinuationFromConfirmedIdentity
            ),
            audit: audit,
            isPortHeld: policyHoldsOpenPort,
            isFinal: false
        ))

        if abortToken.consumeIfRequested(for: edge) {
            return closePolicyPortAfterAbort()
        }
        let executor = CommissioningExecutor(transport: transport, recipe: recipe, clock: clock, abortToken: abortToken)
        self.executor = executor
        commissioningOrigin = .activeContinuationFromConfirmedIdentity
        // Ab hier führt **die Buchführung des Executors** die Verbindung
        // weiter -- die eigene gibt sie in derselben Zeile ab, damit es
        // nie zwei Wahrheiten über denselben Port gibt (K1-3).
        policyHoldsOpenPort = false

        let adopted = executor.adoptAlreadyOpenConnectionWithConfirmedIdentity()
        guard case .verified = adopted.phase else {
            return translateCommissioningReport(adopted, origin: .activeContinuationFromConfirmedIdentity)
        }
        // Das Ergebnis der Übernahme: die Zielrate ist belegt.
        publish(translateCommissioningReport(adopted, origin: .activeContinuationFromConfirmedIdentity))

        // **Unmittelbar vor dem blockierenden MMK-Abschnitt** (K1-5):
        // Die MMK-Anforderung samt Stromfrist beginnt jetzt, und der Port
        // gehört inzwischen wahr dem Executor.
        publish(StandardConnectionReport(
            phase: .runningCommissioning(
                .awaitingMeasurementStream, origin: .activeContinuationFromConfirmedIdentity
            ),
            audit: audit,
            isPortHeld: adopted.isPortHeld,
            isFinal: false
        ))

        let measurementOutcome = executor.performUsingLoanedEdge(.requestMeasurementMode, edge: edge)
        return translateCommissioningReport(measurementOutcome, origin: .activeContinuationFromConfirmedIdentity)
    }

    /// Abschnitt 3: die 38.400-Verbindung ist bereits wirklich
    /// geschlossen (Vorbedingung des erreichten
    /// ``ConnectionPolicyDirective/requestCommissioningContinuation``).
    /// Der delegierte ``CommissioningExecutor`` führt Ausgangsprüfung,
    /// Login/Baudwechsel (erst nach gelesenem Passwort), Verifikation und
    /// MMK vollständig selbst aus -- **alle auf derselben geliehenen
    /// Laufkante** (K1-2), damit ein Abbruch in jeder Lücke dazwischen
    /// denselben Standardlauf trifft.
    private func beginCommissioningFallback(
        gap: ConnectionPolicyIdentityGap, baudRate: SerialPortBaudRate, edge: CommissioningRunEdge
    ) -> StandardConnectionReport {
        if abortToken.consumeIfRequested(for: edge) {
            return StandardConnectionReport(
                phase: .failed(.aborted), audit: audit, isPortHeld: policyHoldsOpenPort, isFinal: !policyHoldsOpenPort
            )
        }
        let executor = CommissioningExecutor(transport: transport, recipe: recipe, clock: clock, abortToken: abortToken)
        self.executor = executor
        commissioningOrigin = .fallbackFromStartingRate

        // **Unmittelbar vor dem blockierenden Abschnitt** (K1-5): Die
        // Ausgangsprüfung bei 9600 beginnt jetzt, und der 38.400-Port ist
        // zu diesem Zeitpunkt wirklich geschlossen -- `isPortHeld` sagt
        // das.
        publish(StandardConnectionReport(
            phase: .runningCommissioning(.checkingStartingRate, origin: .fallbackFromStartingRate),
            audit: audit, isPortHeld: false, isFinal: false
        ))

        let startingOutcome = executor.performUsingLoanedEdge(.checkStartingRate, edge: edge)
        guard case .respondingAtStartingRate = startingOutcome.phase else {
            return translateCommissioningReport(startingOutcome, origin: .fallbackFromStartingRate)
        }
        // Das Ergebnis der Ausgangsprüfung (K1-5).
        publish(translateCommissioningReport(startingOutcome, origin: .fallbackFromStartingRate))


        // Ein Abbruch **zwischen** Ausgangsprüfung und Passwort-Lesen
        // trifft denselben Lauf -- die geliehene Kante ist durchgehend
        // reserviert (K1-2). Ohne diesen Halt läse der Lauf noch das
        // Passwort und sendete das Login.
        if abortToken.consumeIfRequested(for: edge) {
            return finishAbortedCommissioning(executor, edge: edge)
        }

        // **Erst jetzt**, direkt vor dem zusammenhängenden
        // Login-/Baudwechsel-Schritt, aus dem injizierten Speicher
        // gelesen -- `secret` lebt ausschließlich als lokale Variable
        // dieses einen unmittelbar folgenden Executor-Aufrufs, nie als
        // Eigenschaft dieses Laufs.
        let passwordText = passwordStore.load()
        guard let secret = InstallationSecret(text: passwordText) else {
            let finishOutcome = executor.performUsingLoanedEdge(.finishSession, edge: edge)
            audit.commissioning = finishOutcome.audit
            if finishOutcome.isPortHeld {
                // Auch hier ist ein fehlgeschlagener Schluss dominant
                // (K1-3) -- der Passwortmangel bleibt als Ausgang
                // hinterlegt, bis der Port wirklich frei ist.
                outcomeBehindACloseFailure = .failed(.missingOrUnusablePassword)
                return StandardConnectionReport(
                    phase: .failed(.portCloseFailed), audit: audit, isPortHeld: true, isFinal: false
                )
            }
            return StandardConnectionReport(
                phase: .failed(.missingOrUnusablePassword),
                audit: audit,
                isPortHeld: false,
                isFinal: finishOutcome.isFinal
            )
        }

        // Ein Abbruch **zwischen** Passwort-Lesen und Baudwechsel trifft
        // ebenfalls denselben Lauf und verhindert das Login (K1-2).
        if abortToken.consumeIfRequested(for: edge) {
            return finishAbortedCommissioning(executor, edge: edge)
        }

        // **Unmittelbar vor dem blockierenden Login-/Baudwechsel-/
        // Zielverifikationsabschnitt** (K1-5): Der eine Executor-Befehl
        // `switchBaudRate` sendet das Login (mit höchstens einer
        // belegten Wiederholung), das Baudtelegramm, wechselt den Port
        // real auf 38.400 und verifiziert dort über B1 -- ein einziger,
        // zusammenhängender, blockierender Abschnitt. Der 9600-Port ist
        // zu diesem Zeitpunkt wahr gehalten.
        publish(StandardConnectionReport(
            phase: .runningCommissioning(
                .loggingInAndSwitchingBaudRate, origin: .fallbackFromStartingRate
            ),
            audit: audit,
            isPortHeld: startingOutcome.isPortHeld,
            isFinal: false
        ))

        let switchOutcome = executor.performUsingLoanedEdge(.switchBaudRate, secret: secret, edge: edge)
        guard case .verified = switchOutcome.phase else {
            return translateCommissioningReport(switchOutcome, origin: .fallbackFromStartingRate)
        }
        // Das Ergebnis der Zielverifikation (K1-5).
        publish(translateCommissioningReport(switchOutcome, origin: .fallbackFromStartingRate))

        // Ein Abbruch **zwischen** erfolgreichem Wechsel und MMK trifft
        // denselben Lauf und verhindert die MMK-Sendung (K1-2).
        if abortToken.consumeIfRequested(for: edge) {
            return finishAbortedCommissioning(executor, edge: edge)
        }

        // **Unmittelbar vor dem blockierenden MMK-Abschnitt** (K1-5):
        // Die Anforderung geht jetzt hinaus, und die feste Stromfrist
        // läuft; der Port ist wahr gehalten.
        publish(StandardConnectionReport(
            phase: .runningCommissioning(
                .awaitingMeasurementStream, origin: .fallbackFromStartingRate
            ),
            audit: audit,
            isPortHeld: switchOutcome.isPortHeld,
            isFinal: false
        ))

        let measurementOutcome = executor.performUsingLoanedEdge(.requestMeasurementMode, edge: edge)
        return translateCommissioningReport(measurementOutcome, origin: .fallbackFromStartingRate)
    }

    /// Ein Abbruch, der **zwischen** zwei delegierten Teilschritten
    /// eintraf: Der Executor hält den Port und bringt den Lauf über
    /// seinen eigenen, unveränderten Abbruchweg zu Ende -- kein weiteres
    /// Telegramm, kein Passwortzugriff, ein echter Schließversuch
    /// (K1-2/K1-3).
    private func finishAbortedCommissioning(
        _ executor: CommissioningExecutor, edge: CommissioningRunEdge
    ) -> StandardConnectionReport {
        let abortOutcome = executor.performUsingLoanedEdge(.abort, edge: edge)
        return translateCommissioningReport(
            abortOutcome, origin: commissioningOrigin ?? .fallbackFromStartingRate
        )
    }

    /// Abbruch, der exakt an der Übergabe zur aktiven Fortsetzung eintraf
    /// -- der Port ist unter der eigenen Politik-Buchführung noch echt
    /// offen und wurde noch keinem Executor übergeben; genau dieser eine
    /// Schluss-Versuch schließt ihn wirklich.
    ///
    /// **Scheitert er, ist das dominant** (K1-3): öffentlich
    /// ``StandardConnectionFailure/portCloseFailed``, Port gehalten,
    /// nicht final -- der Abbruch bleibt als Ausgang hinterlegt, bis ein
    /// ausdrücklicher ``retryClose()`` wirklich freigibt.
    private func closePolicyPortAfterAbort() -> StandardConnectionReport {
        let event = performClose()
        outcomeBehindACloseFailure = .failed(.aborted)
        return resolveOwnCloseAttempt(event)
    }

    /// Übersetzt einen echten ``CommissioningStepReport`` in den
    /// vereinheitlichten Bericht dieses Laufs.
    ///
    /// **Ein fehlgeschlagener abschließender Schluss ist dominant**
    /// (K1-3): Erreicht der delegierte Teil seinen `stop`-Vertrag und
    /// hält den Port trotzdem noch, dann **und nur dann**, weil der
    /// reale `closePort()` scheiterte (``CommissioningExecutor`` verbucht
    /// ihn nie vor seinem Ergebnis). Der öffentliche Ausgang lautet dann
    /// ``StandardConnectionFailure/portCloseFailed``, gleich ob der
    /// ursprüngliche Anlass Abbruch, ein Commissioning-Fehler oder ein
    /// Erfolg war -- der ursprüngliche Ausgang bleibt hinterlegt und
    /// kehrt zurück, sobald ein ``retryClose()`` den Port wirklich
    /// freigibt.
    private func translateCommissioningReport(
        _ stepOutcome: CommissioningStepReport, origin: StandardConnectionCommissioningOrigin
    ) -> StandardConnectionReport {
        audit.commissioning = stepOutcome.audit
        lastDelegatedReport = stepOutcome

        if stepOutcome.restingDirective == .stop, stepOutcome.isPortHeld {
            if outcomeBehindACloseFailure == nil {
                outcomeBehindACloseFailure = mapCommissioningPhase(stepOutcome.phase, origin: origin)
            }
            return StandardConnectionReport(
                phase: .failed(.portCloseFailed), audit: audit, isPortHeld: true, isFinal: false
            )
        }

        if let pending = outcomeBehindACloseFailure, !stepOutcome.isPortHeld {
            // Ein zuvor gescheiterter Schluss ist über einen
            // ausdrücklichen ``retryClose()`` wirklich gelungen: Der
            // hinterlegte, ursprüngliche Ausgang gilt wieder -- der
            // Reducer steht inzwischen auf `sessionFinished` und wüsste
            // ihn nicht mehr.
            outcomeBehindACloseFailure = nil
            return StandardConnectionReport(
                phase: pending, audit: audit, isPortHeld: false, isFinal: true
            )
        }

        return StandardConnectionReport(
            phase: mapCommissioningPhase(stepOutcome.phase, origin: origin),
            audit: audit,
            isPortHeld: stepOutcome.isPortHeld,
            isFinal: stepOutcome.isFinal
        )
    }

    /// Die geschlossene, **datenfreie** Abbildung einer
    /// ``CommissioningPhase`` auf die eigene Zustandsmatrix (K1-4).
    private func mapCommissioningPhase(
        _ phase: CommissioningPhase, origin: StandardConnectionCommissioningOrigin
    ) -> StandardConnectionPhase {
        switch phase {
        case .measurementStreamConfirmed:
            return .ready(
                origin == .activeContinuationFromConfirmedIdentity
                    ? .activeContinuationMeasurementStream
                    : .commissioningFallbackMeasurementStream
            )
        case .failed(let failure):
            return .failed(mapCommissioningFailure(failure))
        case .idle, .checkingStartingRate:
            // `.idle` ist der Zustand *vor* der Ausgangsprüfung und liegt
            // fachlich in demselben Abschnitt -- der delegierte Teil steht
            // an seiner Ausgangsprüfung.
            return .runningCommissioning(.checkingStartingRate, origin: origin)
        case .respondingAtStartingRate:
            return .runningCommissioning(.respondingAtStartingRate, origin: origin)
        case .enteringSettingsMode, .enteringSettingsModeManually, .settingsModeEntered,
             .loggingIn, .loggingInManually, .loggedIn,
             .requestingBaudSwitch, .requestingBaudSwitchManually, .baudSwitchAcknowledged,
             .closingPort, .openingTargetPort, .verifyingTargetRate:
            // Login, Baudtelegramm, der reale Portwechsel und die
            // anschließende Zielverifikation sind **ein** zusammenhängender
            // blockierender Abschnitt eines einzigen Executor-Befehls
            // (`switchBaudRate`) -- sie bekommen deshalb einen gemeinsamen,
            // wahren Namen statt vier Zwischenzustände, die von außen nie
            // als Ruhepunkt beobachtbar sind.
            return .runningCommissioning(.loggingInAndSwitchingBaudRate, origin: origin)
        case .verified:
            return .runningCommissioning(.verifiedAtTargetRate, origin: origin)
        case .awaitingMeasurementStream:
            return .runningCommissioning(.awaitingMeasurementStream, origin: origin)
        case .runningDiagnostics:
            return .runningCommissioning(.runningRateDiagnostics, origin: origin)
        case .diagnosticsFinished:
            return .runningCommissioning(.rateDiagnosticsFinished, origin: origin)
        case .sessionFinished:
            return .runningCommissioning(.sessionFinished, origin: origin)
        }
    }

    /// **Abbilden, nicht einbetten** (K1-4): Jeder fachlich verschiedene
    /// Grund behält einen eigenen öffentlichen Fall, aber die fremde
    /// Nutzlast -- unbekanntes Kommandobyte, Adaptertext -- bleibt
    /// draußen. Zwei verschiedene unbekannte Bytes ergeben deshalb
    /// denselben Wert.
    private func mapCommissioningFailure(_ failure: CommissioningFailure) -> StandardConnectionFailure {
        switch failure {
        case .noDeviceAtStartingRate(let outcome):
            switch outcome {
            case .timeout:
                return .startingRateSilent
            case .ambiguous:
                return .startingRateAmbiguousResponse
            case .unexpectedResponse, .identified:
                // `.identified` ist hier strukturell unerreichbar (ein
                // belegtes Gerät ist kein Fehlschlag) -- explizit statt
                // `default`, damit ein neuer `IdentityProbeOutcome`-Fall
                // sichtbar entschieden werden muss.
                return .startingRateUnexpectedResponse
            }
        case .settingsModeRejected:
            return .settingsModeRejected
        case .settingsModeUnanswered:
            return .settingsModeUnanswered
        case .settingsModeAmbiguous:
            return .settingsModeAmbiguous
        case .loginRejected:
            return .loginRejected
        case .loginUnanswered:
            return .loginUnanswered
        case .loginAmbiguous:
            return .loginAmbiguous
        case .baudSwitchRejected:
            return .baudSwitchRejected
        case .baudSwitchUnanswered:
            return .baudSwitchUnanswered
        case .baudSwitchAmbiguous:
            return .baudSwitchAmbiguous
        case .portOpenFailed:
            return .portOpenFailed
        case .portCloseFailed:
            // Über den dominanten Weg oben bereits abgefangen (ein
            // gescheiterter Schluss lässt den Port gehalten); hier
            // defensiv dieselbe Kategorie statt eines Absturzes.
            return .portCloseFailed
        case .verificationFailed(let outcome):
            switch outcome {
            case .timeout:
                return .targetRateSilent
            case .ambiguous:
                return .targetRateAmbiguousResponse
            case .unexpectedResponse, .identified:
                return .targetRateUnexpectedResponse
            }
        case .measurementModeRejected:
            return .measurementModeRejected
        case .measurementStreamAbsent:
            return .measurementStreamAbsent
        case .measurementPointCountMismatch:
            return .measurementPointCountMismatch
        case .writeFailed:
            return .portWriteFailed
        case .abortedByOperator:
            return .aborted
        case .unexpectedEvent:
            return .unexpectedEvent
        }
    }

    // MARK: - Fortschritt und Abschluss

    /// Meldet einen echten Zustandsübergang an die Fortschrittsgrenze --
    /// **denselben Zustand nie zweimal** (K1-5).
    private func publish(_ report: StandardConnectionReport) {
        guard report.phase != lastPublishedPhase else { return }
        lastPublishedPhase = report.phase
        onProgress?(report)
    }

    /// Der Endbericht eines Aufrufs -- **immer** gemeldet, auch wenn die
    /// Phase sich gegenüber dem letzten Fortschritt nicht geändert hat
    /// (zwei nacheinander gescheiterte ``retryClose()``-Versuche sind
    /// zwei echte Endberichte).
    private func finish(_ report: StandardConnectionReport) -> StandardConnectionReport {
        lastPublishedPhase = report.phase
        onProgress?(report)
        return report
    }

    // MARK: - Der aktuelle, politikgetriebene Bericht

    /// **Portfelder aus der eigenen Buchführung, nie aus der
    /// Reducerphase geraten** (K1-3).
    private func currentReport() -> StandardConnectionReport {
        StandardConnectionReport(
            phase: currentPhase(),
            audit: audit,
            isPortHeld: policyHoldsOpenPort,
            isFinal: isCurrentPhaseTerminal && !policyHoldsOpenPort
        )
    }

    /// `.ready` zählt als terminal: Solange der Erfolgsport gehalten
    /// wird, ist der Bericht trotzdem nicht final (`isFinal` verlangt
    /// zusätzlich `!policyHoldsOpenPort`); nach dem wirklichen Schluss
    /// über ``releasePortForMeasurement()`` wird er es (SICK-0330b).
    private var isCurrentPhaseTerminal: Bool {
        switch policy.phase {
        case .failed, .continuingActively, .continuingViaCommissioning, .ready:
            return true
        case .idle, .openingPort, .awaitingScanProfile,
             .checkingIdentityAtTargetRate, .closingPort, .closeFailed:
            return false
        }
    }

    private func currentPhase() -> StandardConnectionPhase {
        switch policy.phase {
        case .idle:
            return .idle
        case .openingPort, .awaitingScanProfile:
            return .observingPassively
        case .checkingIdentityAtTargetRate:
            return .checkingIdentityAtTargetRate
        case .ready:
            return scanProfileObservedDuringIdentityCheck
                ? .ready(.scanProfileDuringIdentityProbe)
                : .ready(.passiveScanProfile)
        case .closingPort:
            // Wird in `drivePolicy(_:edge:)` immer sofort ausgeführt (kein
            // Abbruch-Vorabcheck vor `.closePort`, siehe `execute(_:edge:)`)
            // und erreicht diesen Weg über `.none` nie -- defensiv, kein
            // `default`.
            return .checkingIdentityAtTargetRate
        case .closeFailed:
            return .failed(.portCloseFailed)
        case .continuingActively, .continuingViaCommissioning:
            // Werden in `drivePolicy(_:edge:)` unmittelbar abgefangen und
            // erreichen diesen Weg über `.none` nie -- defensiv, kein
            // `default`.
            return .failed(.unexpectedEvent)
        case .failed(let failure):
            return .failed(mapPolicyFailure(failure))
        }
    }

    private func mapPolicyFailure(_ failure: ConnectionPolicyFailure) -> StandardConnectionFailure {
        switch failure {
        case .startRefused(let reason):
            return .invalidPort(reason)
        case .portOpenFailed:
            return .portOpenFailed
        case .aborted:
            return .aborted
        case .unexpectedEvent:
            return .unexpectedEvent
        case .connectionLost:
            if wrongMeasurementPointCount { return .measurementPointCountMismatch }
            return lastConnectionLostWasWrite ? .portWriteFailed : .portReadFailed
        }
    }
}
