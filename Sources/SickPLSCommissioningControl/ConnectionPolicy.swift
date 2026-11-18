// ConnectionPolicy.swift
//
// SICK-0330r — die reine Verbindungspolitik.
// SICK-0330r-K1 — Abbruch, echte Freigabe und geschlossene Port-/Fehlerwerte.
//
// ## Die eine Frage
//
// Welche **kleinste nötige Gerätewirkung** muss der spätere gemeinsame
// `Verbinden`-Ablauf wählen, um an einem ausdrücklich gewählten Port einen
// echten B0-Messstrom zu erhalten, ohne einen bereits geeigneten Strom
// durch unnötiges TX zu stören?
//
// ## Die Minimalwirkungs-Reihenfolge
//
// 1. Den gewählten Port passiv bei 38.400/8E1 öffnen und -- innerhalb einer
//    vom **späteren Executor** begrenzten Beobachtungsphase -- auf einen
//    CRC-validen B0-Strom warten.
// 2. Trifft ein B0-Profil ein, ist der Scanner betriebsbereit: ``ready``.
//    **Kein TX, keine B1-Probe, kein Commissioning.**
// 3. Bleibt der Strom aus, wird bei 38.400 die harmlose B1-Identitätsprobe
//    gesendet. Ein CRC-valides B0-Profil, das währenddessen eintrifft,
//    gewinnt trotzdem als Betriebsbeleg (Pflichtnachweis 5) -- eine
//    B1-Antwort allein beweist niemals schon Messbereitschaft.
// 4. Valides B1 -> genau **eine** typisierte aktive Fortsetzung, die den
//    bereits bestätigten Baudwechsel überspringt und den Messbetrieb
//    herstellen soll (Port bleibt gehalten). Kein valides B1 (Timeout,
//    unerwartete oder unauswertbare Antwort) -> genau **eine** typisierte
//    Commissioning-Fortsetzung ab 9600, aber **erst nach bestätigtem
//    Schließen** des 38.400er-Ports -- ein Ratenwechsel ist kein stiller
//    Zustandswechsel.
//
// Dieser Kern (Fast Path, B0-/B1-Wahrheit, die drei Identitätslücken,
// sequenzielle Commissioning-Entscheidung) ist seit SICK-0330r geprüft und
// akzeptiert und wurde von SICK-0330r-K1 **nicht** verändert
// (`review-sick-0330r.md`).
//
// ## Was dieser Slice bewusst NICHT ist
//
// Ein reines, deterministisches Entscheidungsmodell -- kein Executor,
// keine echte Frist-/Uhrimplementierung, kein Port, kein Thread, kein
// Combine, keine Closure, keine I/O. Er fordert notwendige aktive
// Folgeschritte nur **typisiert an**, sendet aber selbst kein Byte und
// öffnet keinen Port. Ob im aktiven Fortsetzungspfad ein Login nötig ist
// und wie B0 nach der MMK-Anforderung die Wirkung belegt, entscheidet
// SICK-0330a-0 -- dieser Vertrag nimmt jene aktive Zustandsmaschine
// ausdrücklich nicht vorweg.
//
// ## Warum kein `atMillis`-Parameter (anders als `CommissioningModel`)
//
// `CommissioningModel.apply(_:atMillis:)` berechnet aus einem vom
// Aufrufer gestellten Zeitpunkt selbst absolute Sendefristen. Dieser
// Reducer berechnet **keine einzige Frist** -- die Beobachtungsphase
// (Schritt 1) ist ausdrücklich "vom späteren Executor begrenzt", und die
// B1-Probe löst sich über ein einziges, bereits timeout-bewusstes
// ``IdentityProbeOutcome``-Ereignis auf (dieselbe Abstraktion, die
// `IdentityProbe`/`BaudProbe` seit SICK-011/011a schon liefern). Einen
// Zeitstempel entgegenzunehmen, den er nie benutzt, wäre eine Behauptung,
// die dieser Reducer nicht einlöst.
//
// ## Warum keine Lauf-/Generationskennung
//
// Ein Modellwert beschreibt genau **einen** Lauf; ein neuer Lauf ist ein
// neuer Wert. Innerhalb **eines** Laufs ignoriert jeder terminale
// Zustand -- ``ConnectionPolicyPhase/continuingActively``,
// ``ConnectionPolicyPhase/continuingViaCommissioning(_:)`` und
// ``ConnectionPolicyPhase/failed(_:)`` -- jedes weitere Ereignis
// vollständig (Abschnitt 3, "Terminale Zustände liefern keine weitere
// Wirkung"). Eine doppelte oder verspätete Freigabe kann deshalb keinen
// neuen Ablauf beeinflussen, ohne dass es dafür eine zweite
// Besitzverwaltung bräuchte.
//
// ## SICK-0330r-K1: drei Vertragslücken an der Abbruch-/Freigabegrenze
//
// Der Supervisor-Befund (`review-sick-0330r.md`, H1-H4) betraf
// ausschließlich diese Grenze -- Fast Path, B0-/B1-Wahrheit und die drei
// Identitätslücken sind unverändert:
//
// - **H1 -- Abbruch bleibt bis zur wirklichen Freigabe dominant.** Ein
//   `operatorAborted`, das während ``ConnectionPolicyPhase/closingPort(_:)``
//   mit einer vorgemerkten Commissioning-Fortsetzung eintrifft, verwirft
//   diese Fortsetzung jetzt unwiderruflich (``abortedOutcome(from:)``) --
//   das bereits laufende Schließen wird weiter abgewartet, aber das
//   Ergebnis endet garantiert `.aborted`, nie mit einer aktiven oder
//   Commissioning-Direktive.
// - **H2 -- ein fehlgeschlagener Portschluss ist keine Freigabe.** Die
//   neue, **nichtterminale** Phase ``ConnectionPolicyPhase/closeFailed(_:)``
//   hält den Port sichtbar vorgesehen (`needsPort == true`) und sperrt
//   jede Folgedirektive, bis ein späteres, tatsächlich bestätigtes
//   `portClosed` freigibt -- kein automatischer Retry, kein stiller
//   Zustandssprung nach `failed`.
// - **H3 -- jede wirkende Direktive trägt ihren Port.** Jeder Fall in
//   ``ConnectionPolicyDirective`` außer `.none` trägt jetzt den
//   unveränderlichen ``ConnectionPolicyPort`` als eigenen, nicht vom
//   Modellwert abgeleiteten Wert -- eine Direktive ohne Port ist seither
//   nicht mehr kompilierbar. Wo eine Rate zur Aktion gehört, steht sie
//   ebenfalls als explizite `SerialPortBaudRate` in der Direktive, nie
//   nur implizit im Fallnamen.
// - **H4 -- Fehler sind geschlossene, redigierte Kategorien.** Die drei
//   früheren `String`-Nutzlasten (Portöffnung, Verbindungsverlust,
//   Portschluss) sind durch das gemeinsame, feldlose
//   ``ConnectionPolicyIOFailure`` ersetzt -- kein Pfad, kein Fehlercode,
//   kein Bytewert, kein Geheimnis kann diesen Reducer mehr erreichen.
//   Nutzertexte gehören an eine spätere redigierende Adaptergrenze.
//
// ## SICK-0330r-K2: zwei verbliebene Typgrenzen an der Abbruch-/Freigabe-
// und Identitätsgrenze
//
// Der Supervisor-Befund (`review-sick-0330r-k1.md`, K2-1/K2-2) betraf
// ausschließlich diese beiden Stellen -- Fast Path, B0-/B1-Wahrheit sowie
// H1-H3 sind unverändert:
//
// - **K2-1 -- der Portschlussgrund wird jetzt gebunden statt verworfen.**
//   ``ConnectionPolicyPhase/closeFailed(_:reason:)`` führt seither neben
//   dem ursprünglichen Schließergebnis exakt den
//   ``ConnectionPolicyIOFailure`` mit, den das auslösende
//   `portCloseFailed`-Ereignis geliefert hat -- `applyWhileClosingPort`
//   und `applyWhileCloseFailed` binden ihn jetzt (`let reason`), statt ihn
//   stillschweigend zu verwerfen. Ein wiederholtes `portCloseFailed`
//   ersetzt den gespeicherten Grund durch den zuletzt gemeldeten (jüngste
//   Information gewinnt); da ``ConnectionPolicyIOFailure`` bewusst
//   feldlos ist (H4), ist das beobachtbare Ergebnis davon nicht zu
//   unterscheiden -- die Semantik ist dennoch ausdrücklich festgelegt und
//   getestet, nicht zufällig. Ein `operatorAborted` in `closeFailed`
//   ersetzt weiterhin nur das vorgemerkte Ergebnis (`abortedOutcome`);
//   der gespeicherte Schließgrund bleibt dabei unverändert erhalten, und
//   erst ein späteres bestätigtes `portClosed` löst das Ergebnis auf.
//   Der zuvor deklarierte, aber produktiv unerreichbare Fall
//   `ConnectionPolicyFailure.portCloseFailed` ist ersatzlos entfernt:
//   Ihn fachlich erreichbar zu machen, verlangte eine "gib auf nach N
//   Fehlschlägen"-Entscheidung -- eine Frist- oder Zählgrenze, die dieser
//   Reducer bewusst nie berechnet (siehe Kopfabschnitt "Warum kein
//   `atMillis`-Parameter"). Ein Test, der den Fall nur direkt konstruiert,
//   ohne dass ihn ein echter Übergang je erreicht, belegt keine Semantik.
// - **K2-2 -- die Identitätslücke ist an der Policy-Grenze datenfrei.**
//   ``ConnectionPolicyIdentityGap/unexpectedResponse`` trägt seither kein
//   `commandByte: UInt8` mehr. Das niedrigere
//   `IdentityProbeOutcome.unexpectedResponse(commandByte:)` bleibt
//   unverändert (SICK-011/011a) -- die Policy bildet jeden Bytewert beim
//   Eintritt in `applyWhileCheckingIdentity` auf dieselbe geschlossene
//   Kategorie und damit dieselbe Entscheidung ab, ohne das Byte je zu
//   binden oder weiterzureichen.

import SickPLSActiveControl
import SickPLSMacTransport

/// Ein ausdrücklich gewählter, nicht leerer `/dev/cu.*`-Port für einen
/// Verbindungslauf.
///
/// Erzeugt wird er ausschließlich über ``build(path:)`` -- eine
/// validierende Fabrik nach dem Hausmuster (`Frame.build`, `Zone.build`,
/// `MasterLevel.build`). Ein `ConnectionPolicyEvent` nimmt dagegen bewusst
/// den **rohen** Pfad als `String` entgegen: Ein bereits validierter
/// Werttyp könnte eine Ungültigkeit gar nicht mehr transportieren, und
/// Pflichtnachweis 1 verlangt genau diesen Fall als **benannte
/// Verweigerung** des Modells selbst, nicht als vorgelagerte
/// Typkonstruktion, die dem Reducer nie zu sehen bekäme.
public struct ConnectionPolicyPort: Equatable, Sendable {
    public let path: String

    public enum BuildError: Error, Equatable, Sendable {
        /// Kein Port ausgewählt.
        case empty
        /// Der Pfad liegt außerhalb von `/dev/cu.` -- dieselbe Grenze wie
        /// im Transport (`SickPLSSerialConnection`), in `BaudProbe`, in
        /// `ActiveControlCommissioningTransport` und in
        /// `SystemCommissioningRunFactory`, hier nur für die reine
        /// Politik noch einmal geschlossen formuliert.
        case pathNotAllowed(String)
    }

    private init(path: String) {
        self.path = path
    }

    public static func build(path: String) throws -> ConnectionPolicyPort {
        guard !path.isEmpty else { throw BuildError.empty }
        guard path.hasPrefix("/dev/cu.") else { throw BuildError.pathNotAllowed(path) }
        return ConnectionPolicyPort(path: path)
    }
}

/// Eine redigierte, geschlossene Fehlerkategorie ohne freien Text
/// (SICK-0330r-K1, Abschnitt 4) -- ersetzt die früheren `String`-
/// Nutzlasten von Portöffnung, Verbindungsverlust und Portschluss.
///
/// **Trägt bewusst nichts:** keinen String, Pfad, Fehlercode, Bytewert,
/// keine Payload und kein Geheimnis. Welche der drei Operationen
/// betroffen ist, bleibt durch den jeweiligen `case` in
/// ``ConnectionPolicyEvent`` beziehungsweise ``ConnectionPolicyFailure``
/// selbst unterschieden -- Ereignis und Zustand teilen sich denselben
/// Wert (`portOpenFailed`/`connectionLost`/`portCloseFailed` bleiben drei
/// eigene Fälle). Nutzertexte und technische Detaildiagnose gehören an
/// eine spätere redigierende Adaptergrenze, nicht in diesen Reducer.
public struct ConnectionPolicyIOFailure: Equatable, Sendable {
    public init() {}
}

/// Warum bei 38.400 Baud keine gültige B1-Identität belegt wurde
/// (Abschnitt 2, Schritt 4).
///
/// **Absichtlich kein `IdentityProbeOutcome`-Alias:** `.identified` ist an
/// dieser Stelle strukturell unmöglich -- wer es hier hinschriebe, hätte
/// den erfolgreichen Zweig verfehlt. Ein eigener, dreiwertiger Typ macht
/// diese Unmöglichkeit für den Compiler sichtbar statt sie nur zu
/// behaupten.
///
/// **Seit SICK-0330r-K2 (K2-2) datenfrei:** ``unexpectedResponse`` trägt
/// kein rohes Protokollbyte mehr. Das niedrigere
/// `IdentityProbeOutcome.unexpectedResponse(commandByte:)` darf das Byte
/// weiterhin tragen (SICK-011/011a) -- diese Politik bildet aber jeden
/// Bytewert beim Eintritt auf dieselbe geschlossene Kategorie und
/// dieselbe Entscheidung ab, ohne es je zu binden oder weiterzureichen.
public enum ConnectionPolicyIdentityGap: Equatable, Sendable {
    case timeout
    case unexpectedResponse
    case ambiguous
}

/// Warum der Ablauf ohne Erfolg endet.
///
/// **Jeder Fall ist ein eigener Befund** -- dieselbe Haltung wie
/// `CommissioningFailure` (SICK-030a): "abgelehnt", "abgebrochen" und
/// "unerwartet" sind für die Fehlersuche drei verschiedene Lagen.
public enum ConnectionPolicyFailure: Equatable, Sendable {
    /// Start ohne expliziten gültigen Port (Pflichtnachweis 1).
    case startRefused(ConnectionPolicyPort.BuildError)
    /// Der Port ließ sich nicht öffnen.
    case portOpenFailed(ConnectionPolicyIOFailure)
    /// Der Bedienende hat abgebrochen.
    case aborted
    /// Ein Ereignis traf in einer Phase ein, in der es keinen Sinn
    /// ergibt -- ein eigener Fall statt eines stillen Ignorierens
    /// (Abschnitt 4: kein `switch` mit `default`).
    case unexpectedEvent
    /// Die Verbindung ging verloren -- ob vor oder nach ``ready``
    /// (`ready` ist der belegte, im Pflichtnachweis genannte Fall; die
    /// gleiche Ursache ist an jeder Stelle mit offenem Port genauso
    /// real, deshalb kein künstlich auf "nach ready" verengter Name).
    case connectionLost(ConnectionPolicyIOFailure)
    //
    // Es gibt bewusst **keinen** `portCloseFailed(ConnectionPolicyIOFailure)`-
    // Fall (SICK-0330r-K2, K2-1): Ein fehlgeschlagener Schluss allein ist
    // seit H2 nichtterminal (``ConnectionPolicyPhase/closeFailed(_:reason:)``)
    // und wartet auf ein späteres bestätigtes `portClosed`, das stets das
    // dort bereits vorgemerkte ``ConnectionPolicyClosingOutcome`` auflöst
    // -- nie den Schließfehler selbst. Ihn dennoch als eigenen,
    // erreichbaren Endzustand zu bauen, verlangte eine "gib auf nach N
    // Fehlschlägen"-Entscheidung, die dieser fristlose Reducer nicht
    // treffen darf (siehe Kopfabschnitt).
}

/// Was nach dem **bestätigten** Schließen des Ports erreicht werden soll.
///
/// Getragen von ``ConnectionPolicyPhase/closingPort(_:)`` und (seit
/// SICK-0330r-K1) von ``ConnectionPolicyPhase/closeFailed(_:reason:)`` --
/// der eine Fall, in dem das Schließen letztlich zu einem Fehlschlag
/// führt, und der andere, in dem es die typisierte Commissioning-
/// Fortsetzung erst freigibt.
public enum ConnectionPolicyClosingOutcome: Equatable, Sendable {
    case failure(ConnectionPolicyFailure)
    case commissioningContinuation(ConnectionPolicyIdentityGap)
}

/// Die Phasen der Verbindungspolitik.
///
/// **Der `switch` über diesen Typ steht überall ohne `default`**
/// (Abschnitt 4) -- ein neuer Fall zwingt jeden Aufrufer zu einer
/// bewussten Entscheidung.
public enum ConnectionPolicyPhase: Equatable, Sendable {
    /// Vor dem Beginn. Kein Port vorgesehen, keine Wirkung möglich.
    case idle
    /// Der ausgewählte Port wird geöffnet.
    ///
    /// `windDownTo` ist `nil`, solange der Ablauf regulär läuft. Trifft
    /// **während** des noch ausstehenden Öffnens ein Abbruch oder ein
    /// unerwartetes Ereignis ein, kann das Modell den bereits
    /// hinausgegangenen Öffnungsversuch nicht zurücknehmen -- es merkt
    /// sich stattdessen den Grund und entscheidet erst beim tatsächlichen
    /// Ergebnis (``ConnectionPolicyEvent/portOpened``/
    /// ``ConnectionPolicyEvent/portOpenFailed(_:)``), ob geschlossen
    /// werden muss oder nichts offen ist, das es könnte.
    case openingPort(windDownTo: ConnectionPolicyFailure?)
    /// Der Port ist offen. Eine vom **späteren Executor** begrenzte
    /// Beobachtungsphase wartet auf einen CRC-validen B0-Strom.
    case awaitingScanProfile
    /// Mindestens ein CRC-valides B0-Profil wurde in diesem Lauf
    /// beobachtet -- der Scanner ist betriebsbereit. Der Port bleibt
    /// gehalten; weiterer Messbetrieb ist die erwartete Folge.
    case ready
    /// Die Beobachtungsphase blieb ohne B0. Die harmlose B1-Identitätsprobe
    /// bei 38.400 ist unterwegs.
    case checkingIdentityAtTargetRate
    /// Der Port wird geschlossen, bevor der in `outcome` benannte
    /// Endzustand erreicht wird.
    case closingPort(ConnectionPolicyClosingOutcome)
    /// **Nichtterminal** (SICK-0330r-K1, H2): Ein Schließversuch schlug
    /// fehl. Der Port bleibt sichtbar vorgesehen/gehalten
    /// (`needsPort == true`), und weder eine aktive noch eine
    /// Commissioning-Fortsetzung darf von hier aus starten -- ein
    /// fehlgeschlagener Schluss bestätigt gerade **keine** Freigabe.
    /// Beim Eintritt wird **keine** Direktive automatisch erneut
    /// gesendet (kein stiller Retry, keine Endlosschleife); erst ein
    /// später tatsächlich bestätigtes `portClosed` löst `outcome` regulär
    /// auf, genau wie es das aus ``closingPort(_:)`` heraus täte. Ein
    /// `operatorAborted` verwirft hier weiterhin eine vorgemerkte
    /// Commissioning-Fortsetzung (H1), kann den Port aber nicht
    /// fälschlich als geschlossen markieren.
    ///
    /// **Seit SICK-0330r-K2 (K2-1)** führt dieser Fall zusätzlich den
    /// genauen ``ConnectionPolicyIOFailure`` mit, den das auslösende
    /// `portCloseFailed`-Ereignis geliefert hat -- Ereignis und Zustand
    /// teilen sich seither denselben geschlossenen Wert, statt dass ihn
    /// `applyWhileClosingPort` stillschweigend verwirft. Ein wiederholtes
    /// `portCloseFailed` ersetzt `reason` durch den zuletzt gemeldeten
    /// Grund; `operatorAborted` lässt `reason` unverändert und ersetzt
    /// nur `outcome`.
    case closeFailed(ConnectionPolicyClosingOutcome, reason: ConnectionPolicyIOFailure)
    /// **Terminal**, Port bleibt gehalten. Valide B1-Identität bei
    /// 38.400 ist belegt; die typisierte aktive Fortsetzung (Baudwechsel
    /// überspringen, Messbetrieb herstellen) ist angefordert. Ob dabei
    /// ein Login nötig ist, entscheidet SICK-0330a-0.
    case continuingActively
    /// **Terminal**, Port ist bestätigt geschlossen. Die typisierte
    /// Commissioning-Fortsetzung ab 9600 ist angefordert.
    case continuingViaCommissioning(ConnectionPolicyIdentityGap)
    /// **Terminal.** Kein Port mehr vorgesehen oder offen.
    case failed(ConnectionPolicyFailure)
}

/// Die Ereignisse, die von außen hereinkommen.
///
/// Geschlossen: zehn Fälle, keiner davon ein generisches Rohkommando.
public enum ConnectionPolicyEvent: Equatable, Sendable {
    /// Bedienhandlung: die **eine** ausdrückliche Verbindungsanforderung.
    /// Trägt den rohen Pfad -- siehe ``ConnectionPolicyPort`` dazu, warum
    /// bewusst kein bereits validierter Werttyp.
    case operatorRequestedConnection(portPath: String)
    /// Bedienhandlung: Abbruch.
    case operatorAborted
    /// Der Port ist wirklich geöffnet -- bei der einen Rate, die dieser
    /// Vertrag je anfordert (``ConnectionPolicyModel/targetBaudRate``).
    case portOpened
    /// Der Port ließ sich nicht öffnen.
    case portOpenFailed(ConnectionPolicyIOFailure)
    /// Ein CRC-valides B0-Profil traf ein.
    case validScanProfileObserved
    /// Die vom Executor begrenzte Beobachtungsphase ist ohne B0
    /// verstrichen.
    case observationTimedOut
    /// Die Antwort auf die B1-Identitätsprobe bei 38.400.
    case identityOutcome(IdentityProbeOutcome)
    /// Die zugrundeliegende Verbindung ging unerwartet verloren.
    case connectionLost(ConnectionPolicyIOFailure)
    /// Der Port ist wirklich geschlossen.
    case portClosed
    /// Das Schließen selbst schlug fehl.
    case portCloseFailed(ConnectionPolicyIOFailure)
}

/// Was der spätere Executor als Nächstes tun soll.
///
/// **Der Reducer führt nichts aus** -- derselbe Vertrag wie
/// `CommissioningDirective` seit SICK-030a. Kein Fall trägt eine Frist:
/// Diese Politik berechnet keine einzige Uhrzeit (siehe Kopfkommentar).
///
/// **Seit SICK-0330r-K1 (H3) trägt jeder Fall außer `.none` den**
/// ``ConnectionPolicyPort`` **als eigenen Wert** -- eine wirkende
/// Direktive ohne Port ist seither nicht mehr kompilierbar; eine
/// asynchron übergebene Direktive darf nicht vom gerade aktuellen Port
/// eines anderen, zwischenzeitlich veränderten Objekts abhängen. Wo eine
/// Rate zur Aktion gehört, steht sie ebenfalls explizit als
/// `SerialPortBaudRate` dabei -- keine versteckte Ableitung.
public enum ConnectionPolicyDirective: Equatable, Sendable {
    /// Nichts zu tun -- ein Ereignis wurde vermerkt, ohne dass sich das
    /// nach außen sichtbare Verhalten ändert.
    case none
    /// Den Port öffnen -- immer bei der genannten Rate
    /// (``ConnectionPolicyModel/targetBaudRate``, 38.400).
    case openPort(ConnectionPolicyPort, baudRate: SerialPortBaudRate)
    /// Passiv auf einen CRC-validen B0-Strom warten, begrenzt durch eine
    /// **vom Executor selbst** gesetzte Frist (Abschnitt 2, Schritt 1).
    case observeForScanProfile(ConnectionPolicyPort, baudRate: SerialPortBaudRate)
    /// Die harmlose B1-Identitätsprobe bei 38.400 senden.
    case sendIdentityProbeAtTargetRate(ConnectionPolicyPort, baudRate: SerialPortBaudRate)
    /// Die aktuell offene Verbindung schließen -- und auf das bestätigte
    /// Schließen warten. Schließen selbst ist ratenunabhängig.
    case closePort(ConnectionPolicyPort)
    /// **Die eine** typisierte aktive Fortsetzung: den bereits
    /// bestätigten Baudwechsel überspringen und den Messbetrieb
    /// herstellen. Der Port bleibt gehalten, weiterhin bei 38.400.
    case requestActiveContinuation(ConnectionPolicyPort, baudRate: SerialPortBaudRate)
    /// **Die eine** typisierte Commissioning-Fortsetzung ab 9600 --
    /// ausschließlich nach bestätigtem Schließen des 38.400er-Ports.
    case requestCommissioningContinuation(
        ConnectionPolicyPort, ConnectionPolicyIdentityGap, baudRate: SerialPortBaudRate
    )
}

/// Der reine Wertreducer der Verbindungspolitik (SICK-0330r,
/// SICK-0330r-K1, SICK-0330r-K2).
///
/// **Kein Port, keine Uhr, kein Thread, keine I/O.** Alter Zustand plus
/// Ereignis ergeben den neuen Zustand und **höchstens eine** Anweisung --
/// dasselbe Muster wie `CommissioningModel` (SICK-030a), `ScanSessionState`
/// (SICK-012) und `ZoneEditorState` (SICK-014).
public struct ConnectionPolicyModel: Equatable {
    /// Die einzige Rate, die dieser Vertrag je anfordert. Der Weg ab 9600
    /// gehört zur typisierten Commissioning-Fortsetzung, die dieses
    /// Modell nur **anfordert**, nie selbst betritt.
    public static let targetBaudRate: SerialPortBaudRate = .baud38400

    /// Die Rate, bei der die typisierte Commissioning-Fortsetzung
    /// beginnen soll (Abschnitt 3).
    public static let commissioningContinuationBaudRate: SerialPortBaudRate = .baud9600

    public private(set) var phase: ConnectionPolicyPhase = .idle

    /// Der eine Port dieses Laufs (Pflichtnachweis 8). Wird beim
    /// erfolgreichen Start genau einmal gesetzt und danach nie mehr
    /// verändert -- ein Portwechsel innerhalb eines Laufs ist kein
    /// stiller Zustandswechsel (Abschnitt 4) und deshalb hier
    /// strukturell unmöglich.
    public private(set) var port: ConnectionPolicyPort?

    public init() {}

    /// Ob der Ablauf gerade einen Port hält oder vorsieht.
    ///
    /// **Der `switch` ist ausdrücklich ohne `default`** -- eine neue
    /// Phase muss sich entscheiden, statt still einen Wert zu erben.
    /// ``ConnectionPolicyPhase/closeFailed(_:reason:)`` zählt seit
    /// SICK-0330r-K1 (H2) ausdrücklich zu `true`: Ein fehlgeschlagener
    /// Schluss bestätigt keine Freigabe.
    public var needsPort: Bool {
        switch phase {
        case .idle, .failed, .continuingViaCommissioning:
            return false
        case .openingPort, .awaitingScanProfile, .checkingIdentityAtTargetRate,
             .closingPort, .closeFailed, .ready, .continuingActively:
            return true
        }
    }

    // MARK: - Der Übergang

    @discardableResult
    public mutating func apply(_ event: ConnectionPolicyEvent) -> ConnectionPolicyDirective {
        switch phase {
        case .idle:
            return applyWhileIdle(event)
        case .openingPort(let windDownTo):
            // Vor dem ersten `.openPort` ist `self.port` bereits gesetzt
            // (siehe `applyWhileIdle`); der Fallback greift nur, wenn
            // diese Invariante je verletzt würde.
            guard let port else { return .none }
            return applyWhileOpeningPort(event, windDownTo: windDownTo, port: port)
        case .awaitingScanProfile:
            guard let port else { return .none }
            return applyWhileAwaitingScanProfile(event, port: port)
        case .checkingIdentityAtTargetRate:
            guard let port else { return .none }
            return applyWhileCheckingIdentity(event, port: port)
        case .ready:
            guard let port else { return .none }
            return applyWhileReady(event, port: port)
        case .closingPort(let outcome):
            guard let port else { return .none }
            return applyWhileClosingPort(event, outcome: outcome, port: port)
        case .closeFailed(let outcome, let reason):
            guard let port else { return .none }
            return applyWhileCloseFailed(event, outcome: outcome, reason: reason, port: port)
        case .continuingActively, .continuingViaCommissioning, .failed:
            // Terminale Zustände liefern keine weitere Wirkung
            // (Abschnitt 3) -- eine doppelte oder verspätete Freigabe
            // kann diesen Lauf nicht mehr beeinflussen.
            return .none
        }
    }

    // MARK: - `idle`

    private mutating func applyWhileIdle(_ event: ConnectionPolicyEvent) -> ConnectionPolicyDirective {
        switch event {
        case .operatorRequestedConnection(let portPath):
            do {
                let port = try ConnectionPolicyPort.build(path: portPath)
                self.port = port
                phase = .openingPort(windDownTo: nil)
                return .openPort(port, baudRate: Self.targetBaudRate)
            } catch {
                // Pflichtnachweis 1: benannt verweigert, keine Direktive.
                let reason = (error as? ConnectionPolicyPort.BuildError) ?? .pathNotAllowed(portPath)
                phase = .failed(.startRefused(reason))
                return .none
            }
        case .operatorAborted, .portOpened, .portOpenFailed, .validScanProfileObserved,
             .observationTimedOut, .identityOutcome, .connectionLost, .portClosed, .portCloseFailed:
            // Nichts wurde je vorgesehen -- es gibt nichts zu schließen.
            phase = .failed(.unexpectedEvent)
            return .none
        }
    }

    // MARK: - `openingPort`

    private mutating func applyWhileOpeningPort(
        _ event: ConnectionPolicyEvent, windDownTo: ConnectionPolicyFailure?, port: ConnectionPolicyPort
    ) -> ConnectionPolicyDirective {
        switch event {
        case .portOpened:
            if let windDownTo {
                phase = .closingPort(.failure(windDownTo))
                return .closePort(port)
            }
            phase = .awaitingScanProfile
            return .observeForScanProfile(port, baudRate: Self.targetBaudRate)
        case .portOpenFailed(let reason):
            // Nichts ist offen, egal welcher Grund gerade wartete --
            // der ursprüngliche Grund gewinnt, falls einer vorlag.
            phase = .failed(windDownTo ?? .portOpenFailed(reason))
            return .none
        case .operatorAborted:
            if windDownTo == nil {
                // Der Öffnungsversuch ist bereits unterwegs und lässt
                // sich nicht zurücknehmen -- nur merken und auf das
                // wirkliche Ergebnis warten.
                phase = .openingPort(windDownTo: .aborted)
            }
            return .none
        case .operatorRequestedConnection, .validScanProfileObserved, .observationTimedOut,
             .identityOutcome, .connectionLost, .portClosed, .portCloseFailed:
            if windDownTo == nil {
                phase = .openingPort(windDownTo: .unexpectedEvent)
            }
            return .none
        }
    }

    // MARK: - `awaitingScanProfile`

    private mutating func applyWhileAwaitingScanProfile(
        _ event: ConnectionPolicyEvent, port: ConnectionPolicyPort
    ) -> ConnectionPolicyDirective {
        switch event {
        case .validScanProfileObserved:
            // Pflichtnachweis 2: direkt zu `ready`, kein TX.
            phase = .ready
            return .none
        case .observationTimedOut:
            phase = .checkingIdentityAtTargetRate
            return .sendIdentityProbeAtTargetRate(port, baudRate: Self.targetBaudRate)
        case .operatorAborted:
            return closeForFailure(.aborted, port: port)
        case .connectionLost(let reason):
            return closeForFailure(.connectionLost(reason), port: port)
        case .operatorRequestedConnection, .portOpened, .portOpenFailed, .identityOutcome,
             .portClosed, .portCloseFailed:
            return closeForFailure(.unexpectedEvent, port: port)
        }
    }

    // MARK: - `checkingIdentityAtTargetRate`

    private mutating func applyWhileCheckingIdentity(
        _ event: ConnectionPolicyEvent, port: ConnectionPolicyPort
    ) -> ConnectionPolicyDirective {
        switch event {
        case .validScanProfileObserved:
            // Pflichtnachweis 5: B0 gewinnt als Betriebsbeleg, auch
            // während der Prüfphase. Eine noch ausstehende B1-Antwort
            // wird an `ready` harmlos ignoriert (siehe dort).
            phase = .ready
            return .none
        case .identityOutcome(let outcome):
            switch outcome {
            case .identified:
                // Pflichtnachweis 3: genau die typisierte Fortsetzung,
                // nie ein erneuter Baudwechsel.
                phase = .continuingActively
                return .requestActiveContinuation(port, baudRate: Self.targetBaudRate)
            case .timeout:
                return closeForCommissioning(.timeout, port: port)
            case .unexpectedResponse:
                // K2-2: das rohe Kommandobyte wird nie gebunden -- jeder
                // Bytewert bildet auf dieselbe datenfreie Kategorie ab.
                return closeForCommissioning(.unexpectedResponse, port: port)
            case .ambiguous:
                return closeForCommissioning(.ambiguous, port: port)
            }
        case .operatorAborted:
            return closeForFailure(.aborted, port: port)
        case .connectionLost(let reason):
            return closeForFailure(.connectionLost(reason), port: port)
        case .operatorRequestedConnection, .portOpened, .portOpenFailed, .observationTimedOut,
             .portClosed, .portCloseFailed:
            return closeForFailure(.unexpectedEvent, port: port)
        }
    }

    // MARK: - `ready`

    private mutating func applyWhileReady(
        _ event: ConnectionPolicyEvent, port: ConnectionPolicyPort
    ) -> ConnectionPolicyDirective {
        switch event {
        case .validScanProfileObserved:
            // Weiterer Messbetrieb -- die gewöhnliche, erwartete Folge.
            return .none
        case .identityOutcome, .observationTimedOut:
            // Verspätetes Echo einer durch B0 bereits überholten Probe
            // oder Beobachtungsphase (Pflichtnachweis 5) -- harmlos.
            return .none
        case .operatorAborted:
            return closeForFailure(.aborted, port: port)
        case .connectionLost(let reason):
            return closeForFailure(.connectionLost(reason), port: port)
        case .operatorRequestedConnection, .portOpened, .portOpenFailed, .portClosed, .portCloseFailed:
            return closeForFailure(.unexpectedEvent, port: port)
        }
    }

    // MARK: - `closingPort`

    private mutating func applyWhileClosingPort(
        _ event: ConnectionPolicyEvent, outcome: ConnectionPolicyClosingOutcome, port: ConnectionPolicyPort
    ) -> ConnectionPolicyDirective {
        switch event {
        case .portClosed:
            return resolveConfirmedClose(outcome, port: port)
        case .portCloseFailed(let reason):
            // H2: nichtterminal, `needsPort` bleibt wahr; kein
            // automatischer Retry -- die Direktive ist `.none`, bis ein
            // späteres `portClosed` tatsächlich freigibt. K2-1: der
            // genaue Grund aus dem Ereignis wird jetzt gebunden und
            // mitgeführt, statt verworfen zu werden.
            phase = .closeFailed(outcome, reason: reason)
            return .none
        case .operatorAborted:
            // H1: eine vorgemerkte Commissioning-Fortsetzung wird
            // unwiderruflich verworfen; das bereits laufende Schließen
            // wird weiter abgewartet.
            phase = .closingPort(abortedOutcome(from: outcome))
            return .none
        case .operatorRequestedConnection, .portOpened, .portOpenFailed,
             .validScanProfileObserved, .observationTimedOut, .identityOutcome, .connectionLost:
            // Es wird ausschließlich auf das Ergebnis des Schließens
            // gewartet -- alles andere ist ein wirkungsloses Echo.
            return .none
        }
    }

    // MARK: - `closeFailed` (SICK-0330r-K1, H2)

    private mutating func applyWhileCloseFailed(
        _ event: ConnectionPolicyEvent, outcome: ConnectionPolicyClosingOutcome,
        reason: ConnectionPolicyIOFailure, port: ConnectionPolicyPort
    ) -> ConnectionPolicyDirective {
        switch event {
        case .portClosed:
            // Ein später tatsächlich bestätigtes Schließen löst `outcome`
            // regulär auf -- exakt wie aus `closingPort` heraus. Der
            // zwischenzeitlich gespeicherte Schließgrund wird dabei nicht
            // gebraucht: Er beschreibt einen inzwischen überholten
            // Versuch, nicht den letztlich erreichten Erfolg.
            return resolveConfirmedClose(outcome, port: port)
        case .portCloseFailed(let newReason):
            // K2-1, Pflichtnachweis 3: ein wiederholter Schließfehler
            // bleibt nichtterminal -- kein erneuter automatischer
            // Versuch von hier aus, kein stiller Retry, keine
            // Endlosschleife. Der gespeicherte Grund wird durch den
            // zuletzt gemeldeten ersetzt (jüngste Information gewinnt);
            // da `ConnectionPolicyIOFailure` feldlos ist (H4), ist das
            // beobachtbare Ergebnis davon nicht zu unterscheiden -- die
            // Semantik ist dennoch ausdrücklich festgelegt, nicht
            // zufällig.
            phase = .closeFailed(outcome, reason: newReason)
            return .none
        case .operatorAborted:
            // Verwirft weiterhin eine vorgemerkte Commissioning-
            // Fortsetzung, kann den Port aber nicht fälschlich als
            // geschlossen markieren -- die Phase bleibt `closeFailed`.
            // Der gespeicherte Schließgrund bleibt dabei unverändert
            // erhalten (K2-1, Pflichtnachweis 2).
            phase = .closeFailed(abortedOutcome(from: outcome), reason: reason)
            return .none
        case .operatorRequestedConnection, .portOpened, .portOpenFailed,
             .validScanProfileObserved, .observationTimedOut, .identityOutcome, .connectionLost:
            return .none
        }
    }

    // MARK: - Hilfen

    /// H1: Eine vorgemerkte Commissioning-Fortsetzung wird durch einen
    /// Abbruch unwiderruflich verworfen; ein bereits benannter Fehlschlag
    /// bleibt unverändert (ein zweiter Abbruch ändert daran nichts).
    private func abortedOutcome(from outcome: ConnectionPolicyClosingOutcome) -> ConnectionPolicyClosingOutcome {
        switch outcome {
        case .failure:
            return outcome
        case .commissioningContinuation:
            return .failure(.aborted)
        }
    }

    private mutating func resolveConfirmedClose(
        _ outcome: ConnectionPolicyClosingOutcome, port: ConnectionPolicyPort
    ) -> ConnectionPolicyDirective {
        switch outcome {
        case .failure(let failure):
            phase = .failed(failure)
            return .none
        case .commissioningContinuation(let gap):
            phase = .continuingViaCommissioning(gap)
            return .requestCommissioningContinuation(port, gap, baudRate: Self.commissioningContinuationBaudRate)
        }
    }

    private mutating func closeForFailure(
        _ failure: ConnectionPolicyFailure, port: ConnectionPolicyPort
    ) -> ConnectionPolicyDirective {
        phase = .closingPort(.failure(failure))
        return .closePort(port)
    }

    private mutating func closeForCommissioning(
        _ gap: ConnectionPolicyIdentityGap, port: ConnectionPolicyPort
    ) -> ConnectionPolicyDirective {
        phase = .closingPort(.commissioningContinuation(gap))
        return .closePort(port)
    }
}
