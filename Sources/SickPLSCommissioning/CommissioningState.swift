import SickPLSActiveControl
import SickPLSMacTransport

/// Warum ein Ablauf gestoppt hat (SICK-030a).
///
/// **Jeder Fall ist ein eigener Befund.** „Das Gerät hat abgelehnt",
/// „es kam nichts" und „es kam etwas Unauswertbares" sind für die
/// Fehlersuche drei verschiedene Lagen; ein gemeinsamer `failed`-Fall
/// hätte sie eingeebnet.
public enum CommissioningFailure: Equatable, Sendable {
    /// Die Ausgangsprüfung fand kein antwortendes Gerät.
    case noDeviceAtStartingRate(IdentityProbeOutcome)
    case settingsModeRejected
    case settingsModeUnanswered
    case settingsModeAmbiguous
    /// Das Login wurde abgelehnt.
    case loginRejected
    /// Das Login blieb auch nach den zwei in der Windows-Konfiguration
    /// vorgesehenen Wiederholungen ohne Antwort.
    case loginUnanswered
    /// Auf das Login kam etwas Unauswertbares.
    case loginAmbiguous
    case baudSwitchRejected
    case baudSwitchUnanswered
    case baudSwitchAmbiguous
    /// Der Port ließ sich bei der angeforderten Rate nicht öffnen.
    case portOpenFailed(String)
    /// Der Port ließ sich nicht schließen — **und auf dieses Schließen
    /// baut ein Wiederöffnen auf** (SICK-030a3).
    ///
    /// Ein eigener Fall, weil „ließ sich nicht schließen" und „ließ sich
    /// nicht öffnen" verschiedene Handgriffe verlangen: Das eine ist ein
    /// hängender Deskriptor, das andere ein belegter oder verschwundener
    /// Port.
    case portCloseFailed(String)
    /// Der Port antwortete bei der Zielrate nicht wie erwartet — **der**
    /// Fall, in dem der Wechsel nicht belegt ist (Auflage A1).
    case verificationFailed(IdentityProbeOutcome)
    /// Das Gerät hat den experimentellen Messmodus-Schritt abgelehnt —
    /// der **einzige** sofortige Fehler dieses Schritts.
    case measurementModeRejected
    /// Innerhalb der festen Stromfrist ist **kein** neuer, CRC-valider
    /// B0-Strom nach der MMK-Anforderung eingetroffen (SICK-0330a-0).
    ///
    /// **Ein einziger, eindeutiger Fehler** statt der früheren
    /// Aufspaltung nach ACK-/Lesbarkeit: Ob dabei ein ACK, eine
    /// unlesbare Antwort oder gar nichts ankam, entscheidet nicht mehr
    /// den Ausgang — nur der beobachtete (oder ausgebliebene)
    /// Messstrom selbst zählt (Auflage A1-analog). Die früheren Fälle
    /// `measurementModeUnanswered`/`measurementModeAmbiguous`, die ACK-
    /// bzw. Lesbarkeit statt der beobachteten Wirkung zum Endurteil
    /// machten, sind ersatzlos entfernt.
    case measurementStreamAbsent
    case measurementPointCountMismatch
    /// Das Schreiben selbst schlug fehl.
    case writeFailed(String)
    /// Der Bedienende hat abgebrochen.
    case abortedByOperator
    /// Ein Ereignis traf in einer Phase ein, in der es keinen Sinn
    /// ergibt. **Ein eigener Fall statt eines stillen `break`**: Ein
    /// Ablauf, der auf Unerwartetes gar nicht reagiert, sieht aus wie
    /// einer, der noch läuft.
    case unexpectedEvent

    /// Der **einzige** bekannte Rückweg (Befund M3).
    ///
    /// Es gibt keinen belegten Telegrammweg zurück auf die
    /// Ausgangsrate; der entsprechende Pfad der Referenz wurde nie real
    /// durchlaufen, und ob die Zielrate einen Neustart überlebt, ist
    /// offen. Deshalb sagt das Modell hier einen Satz — und bietet
    /// **keinen** „Zurück"-Befehl an, für den es keinen Beleg gäbe.
    public var recoveryHint: String {
        "There is no confirmed message to return to the starting rate. "
            + "The only known way back is to restart the device. "
            + "The rate diagnostics only sends the harmless identity probe."
    }

    /// Was **konkret** schiefging, in Alltagssprache (SICK-032a3).
    ///
    /// **Der Anlass war der erste reale Lauf:** Die Oberfläche sagte nur
    /// „fehlgeschlagen" — welcher der siebzehn Befunde es war, stand
    /// ausschließlich im Protokoll. Für die Fehlersuche am Gerät ist
    /// genau das die entscheidende Auskunft.
    ///
    /// **Bewusst ohne jede Nutzlast:** Die `String`-Fälle führen
    /// Adaptertexte, und die bleiben draußen — dieselbe datenfreie
    /// Grenze wie in `SickPLSCommissioningControl` seit SICK-032a1. Wer
    /// den Wortlaut braucht, findet ihn im Protokoll.
    ///
    /// **`switch` ohne `default`** — ein neuer Befund muss sich einen
    /// Satz geben, statt unter „fehlgeschlagen" zu verschwinden.
    public var operatorSummary: String {
        switch self {
        case .noDeviceAtStartingRate:
            return "The scanner did not respond at 9600 baud."
        case .settingsModeRejected:
            return "The scanner rejected the switch to settings mode."
        case .settingsModeUnanswered:
            return "No response was received for the switch to settings mode."
        case .settingsModeAmbiguous:
            return "Only an unreadable response was received for the switch to settings mode."
        case .loginRejected:
            return "The scanner rejected the login. The scanner password is likely incorrect."
        case .loginUnanswered:
            return "No response was received for the login, even on the third attempt."
        case .loginAmbiguous:
            return "Only an unreadable response was received for the login, even on the third attempt."
        case .baudSwitchRejected:
            return "The scanner rejected the baud rate change."
        case .baudSwitchUnanswered:
            return "No response was received for the baud rate change."
        case .baudSwitchAmbiguous:
            return "Only an unreadable response was received for the baud rate change."
        case .portOpenFailed:
            return "The port could not be opened."
        case .portCloseFailed:
            return "The port could not be closed."
        case .verificationFailed:
            return "After the baud rate change, the scanner did not respond at 38400 baud. "
                + "The change is therefore unconfirmed."
        case .measurementModeRejected:
            return "The scanner rejected the continuous measurement mode."
        case .measurementStreamAbsent:
            return "No new scan stream was received within the time limit after requesting continuous measurements."
        case .measurementPointCountMismatch:
            return "The new scan stream has the wrong point count for the selected measurement mode."
        case .writeFailed:
            return "Sending over the port failed."
        case .abortedByOperator:
            return "Aborted."
        case .unexpectedEvent:
            return "The process received a response that is not expected at this point."
        }
    }
}

/// Wo die Ratendiagnose gerade steht (SICK-030a3).
///
/// **Der Grund für diesen Typ:** Bis SICK-030a2 war die Diagnose **ein**
/// Zustand, der die Probe bei der Ausgangsrate und die Probe bei der
/// Zielrate nacheinander sendete — **ohne einen dazwischenliegenden
/// Portwechsel**. Das Modell behauptete damit einen Ratenwechsel, den
/// keine spätere Transportadaption korrekt ausführen könnte: Eine
/// Verbindung, die bei 9600 geöffnet wurde, spricht nicht plötzlich
/// 38400, nur weil das Modell die nächste Probe „bei der Zielrate" nennt.
///
/// Jede Rate wird jetzt auf einer **wirklich so geöffneten** Verbindung
/// geprüft, und die Zwischenschritte sind einzeln benannt, statt in einem
/// Sammelzustand zu verschwinden.
public enum CommissioningDiagnosticsStep: Equatable, Sendable {
    /// Der Port wird bei dieser Rate geöffnet; erwartet wird
    /// ``CommissioningEvent/portOpened(_:)`` **mit genau dieser Rate**.
    case openingPort(SerialPortBaudRate)
    /// Die Probe bei dieser Rate ist unterwegs.
    case probing(SerialPortBaudRate)
    /// Die bei dieser Rate geöffnete Verbindung wird geschlossen, damit
    /// die andere Rate auf einer neuen Verbindung geprüft werden kann.
    case closingPort(SerialPortBaudRate)
}

/// Das Ergebnis der Ratendiagnose nach einem Fehlschlag (Befund M3).
///
/// Sie sendet ausschließlich die harmlose Identitätsprobe — je Rate
/// genau eine, jede auf einer eigens dafür geöffneten Verbindung
/// (SICK-030a3) — und ändert am Gerät nichts.
public struct CommissioningDiagnosticsReport: Equatable, Sendable {
    public let outcomeAtStartingRate: IdentityProbeOutcome?
    public let outcomeAtTargetRate: IdentityProbeOutcome?

    public var respondsAtStartingRate: Bool { outcomeAtStartingRate == .identified }
    public var respondsAtTargetRate: Bool { outcomeAtTargetRate == .identified }
}

/// Die Phasen des Ablaufs (SICK-030a).
///
/// Der alte Standardweg kann den Baudwechsel weiterhin als zusammenhängende,
/// überwachte Transaktion ausführen. Der produktive Support-Weg besitzt
/// zusätzlich benannte Ruhepunkte und verlangt zwischen jeder Gerätewirkung
/// eine neue Bedienhandlung; so lässt sich der dokumentierte Windows-Ablauf
/// ohne automatisch erfundene Folgeaktion nachvollziehen.
public enum CommissioningPhase: Equatable, Sendable {
    /// Vor dem Beginn — und nach einem ausdrücklich beendeten Ablauf
    /// ist es ``sessionFinished``, nicht wieder dieser Zustand.
    ///
    /// **Der Port ist hier nicht in der Hand des Ablaufs.** Ihn bei der
    /// Ausgangsrate zu öffnen, ist Sache der Schleife, sobald ihr der
    /// Portbesitz erteilt wurde (SICK-030a1) — ab dem ersten
    /// Bedienbefehl hält sie ihn dann durchgehend.
    case idle
    case checkingStartingRate
    /// Das Gerät hat bei der Ausgangsrate geantwortet. Bereit für den
    /// überwachten Wechsel.
    ///
    /// **Ruhepunkt mit gehaltenem Port** (SICK-030a2): Die Schleife
    /// wartet auf die Bedienhandlung und lässt die Verbindung dabei
    /// offen, weil das Login auf **derselben** Verbindung folgt.
    case respondingAtStartingRate
    /// Manueller Ruhepunkt nach bestätigtem `20 30` an Adresse 1.
    case settingsModeEntered
    /// Der vorgeschaltete Einstellungsmodus wird aktiviert, bevor der
    /// adressierte Login gesendet wird.
    case enteringSettingsMode
    case enteringSettingsModeManually
    case loggingIn(attempt: Int)
    case loggingInManually
    /// Manueller Ruhepunkt nach bestätigtem `20 00` an Adresse 1.
    case loggedIn
    case requestingBaudSwitch
    case requestingBaudSwitchManually
    /// Das Gerät hat `20 40` noch auf der 9600-Verbindung bestätigt.
    case baudSwitchAcknowledged
    case closingPort
    case openingTargetPort
    case verifyingTargetRate
    /// Der Wechsel ist belegt: Identitätsantwort am neu geöffneten Port
    /// bei der Zielrate.
    ///
    /// **Ruhepunkt mit gehaltenem Port** (SICK-030a2): Der optionale
    /// experimentelle Messmodus setzt auf **dieser** Verbindung auf.
    case verified
    /// Die MMK-Anforderung ist hinaus, die **feste 3-Sekunden-
    /// Stromfrist** läuft (SICK-0330a-0). Ein ACK, eine unbekannte oder
    /// unlesbare Antwort oder zunächst keine Antwort halten diese Phase
    /// unverändert — nur ein CRC-valider B0-Frame **nach** dieser
    /// Anforderung oder das Fristende beenden sie.
    ///
    /// **Die Frist steht bewusst auch hier**, nicht nur in
    /// `pendingDeadlineMillis`: Ein Bericht oder Test kann sie so
    /// direkt am Zustand ablesen.
    case awaitingMeasurementStream(deadlineMillis: Int64)
    /// **Belegt**: Ein CRC-valider B0-Frame traf nach der MMK-
    /// Anforderung ein — das **einzige** Erfolgskriterium dieses
    /// experimentellen Schritts (analog Auflage A1 beim Baudwechsel).
    /// ACK allein erreicht diesen Zustand **nicht mehr**.
    ///
    /// **Ruhepunkt mit gehaltenem Port** (SICK-030a2): Freigegeben wird
    /// erst beim ausdrücklichen Sitzungsabschluss.
    case measurementStreamConfirmed
    /// Die Ratendiagnose läuft — mit ihrem **benannten** Zwischenschritt
    /// (SICK-030a3). Der Port ist in jedem dieser Schritte gehalten,
    /// auch zwischen dem Schließen der einen und dem Öffnen der anderen
    /// Verbindung: Der Ablauf gibt ihn nicht ab, er wechselt die Rate.
    case runningDiagnostics(step: CommissioningDiagnosticsStep, report: CommissioningDiagnosticsReport)
    case diagnosticsFinished(CommissioningDiagnosticsReport)
    case failed(CommissioningFailure)
    /// **Der einzige Freigabepunkt eines erfolgreichen Ablaufs**
    /// (SICK-030a2, Auflage A7): Der Bedienende hat die
    /// Commissioning-Sitzung ausdrücklich beendet.
    ///
    /// Bewusst ein **eigener** Zustand statt einer Rückkehr nach
    /// ``idle``: „nie begonnen" und „bewusst beendet" sind für die
    /// Bedienoberfläche und für das Protokoll zwei verschiedene Lagen.
    case sessionFinished
}

/// Was die spätere I/O-Schleife als Nächstes tun soll (SICK-030a).
///
/// **Der Reducer führt nichts aus.** Er sagt, was zu tun wäre — die
/// Schleife, die es tut, entsteht in SICK-031. Jede sendende Anweisung
/// trägt ihre **absolute monotone Gesamtfrist**, damit die Frist im
/// Modell sichtbar und prüfbar ist und nicht in der Schleife entsteht
/// (dasselbe Muster wie `BaudProbe.probeOnce` seit SICK-011a).
public enum CommissioningDirective: Equatable, Sendable {
    case none
    case sendIdentityProbe(address: UInt8, deadlineMillis: Int64)
    case sendSettingsMode(deadlineMillis: Int64)
    case sendLogin(attempt: Int, deadlineMillis: Int64)
    case sendBaudSwitch(deadlineMillis: Int64)
    case sendMeasurementMode(deadlineMillis: Int64)
    /// Die aktuell offene Verbindung schließen — und **auf das
    /// bestätigte Schließen warten**.
    ///
    /// Sie steht ausschließlich dort, wo danach **wieder geöffnet** wird:
    /// im überwachten Wechsel vor der Zielrate und in der Ratendiagnose
    /// zwischen den beiden Proben (SICK-030a3). Das Schließen am **Ende**
    /// eines Ablaufs steht nicht hier, sondern liegt im ``stop``-Vertrag
    /// — es setzt keine offene Verbindung voraus.
    case closePort
    /// Den Port bei **dieser** Rate öffnen — und auf das bestätigte
    /// ``CommissioningEvent/portOpened(_:)`` mit genau dieser Rate
    /// warten.
    case openPort(SerialPortBaudRate)
    /// **Ruhepunkt mit gehaltenem Port** (SICK-030a2, Auflage A7).
    ///
    /// Die Schleife wartet auf die nächste Bedienhandlung und **hält die
    /// Verbindung dabei offen**. Genau das verlangt die Beleglage
    /// zwischen Identität, Login und Baudwechsel: „Dieselbe Verbindung
    /// offen lassen."
    ///
    /// Vorher meldete der Reducer an diesen Stellen ``stop``, obwohl der
    /// nächste Bedienbefehl ohne ein ``openPort`` sendet — die Schleife
    /// hätte den Widerspruch selbst auflösen müssen, und eine der beiden
    /// Lesarten ergibt ein **Login auf geschlossenem Port**.
    case hold
    /// **Der Ablauf ist zu Ende, der Port darf freigegeben werden.**
    ///
    /// Das ist der ausdrückliche Sitzungsabschluss, ein Abbruch, ein
    /// Fehlschlag oder das Ende der Ratendiagnose — **nie** ein
    /// Zwischenschritt, an dem es weitergehen kann; dafür gibt es
    /// ``hold``.
    ///
    /// **Hier liegt auch das letzte Schließen** (SICK-030a3): Die
    /// Freigabe des Portbesitzes schließt, was noch offen ist, und das
    /// gilt in **beide** Richtungen — nach einer abgeschlossenen
    /// Ratendiagnose ist eine Verbindung offen, nach einem gescheiterten
    /// Öffnungsversuch keine. Ein ausdrückliches ``closePort`` am Ende
    /// setzte ein offenes FD voraus und wäre in der Hälfte der Fälle
    /// falsch.
    case stop
}

extension CommissioningDirective {
    /// **Vor jeder Sendung ist der Empfangspuffer zu leeren**
    /// (SICK-030a2, Befund N1 aus `review-sick-030a.md`).
    ///
    /// Die Beleglage nennt das Leeren des RX-Puffers als festen
    /// Bestandteil **jedes** Sendeschritts — bei der Identität, bei
    /// **beiden** Login-Sendungen, beim Baudwechsel und beim Messmodus.
    /// Ohne diese Eigenschaft müsste die spätere Schleife die Forderung
    /// aus einem Doku-Text erraten; hier steht sie im Vertrag.
    ///
    /// **Bewusst eine berechnete Eigenschaft statt eines Feldes:** Ein
    /// `Bool` am Fall ließe sich beim Bauen einer Direktive auf `false`
    /// setzen, und eine Sendung ohne Leeren wäre dann eine gültige
    /// Direktive. So kann sie es nicht sein. Der `switch` ist
    /// **ausdrücklich ohne `default`** — ein neuer Sendefall zwingt beim
    /// Übersetzen zu einer Entscheidung, statt still `false` zu erben.
    ///
    /// **Dieser Slice führt nichts aus**: Das Leeren selbst macht die
    /// I/O-Schleife in SICK-031.
    public var requiresReceiveBufferFlush: Bool {
        switch self {
        case .sendIdentityProbe, .sendSettingsMode, .sendLogin, .sendBaudSwitch, .sendMeasurementMode:
            return true
        case .none, .closePort, .openPort, .hold, .stop:
            return false
        }
    }

    /// Ob diese Anweisung ein Telegramm hinausschickt.
    ///
    /// Deckungsgleich mit ``requiresReceiveBufferFlush`` — und genau das
    /// prüft ein Test: Es darf keine Sendung ohne Leeren und kein Leeren
    /// ohne Sendung geben.
    public var isSendDirective: Bool {
        switch self {
        case .sendIdentityProbe, .sendSettingsMode, .sendLogin, .sendBaudSwitch, .sendMeasurementMode:
            return true
        case .none, .closePort, .openPort, .hold, .stop:
            return false
        }
    }

    /// Ob die Schleife den Port nach dieser Anweisung **freigeben darf**.
    ///
    /// Nur ``stop``. ``hold`` ist der Gegenfall und der ganze Grund,
    /// warum es ihn gibt.
    public var releasesPort: Bool {
        switch self {
        case .stop:
            return true
        case .none, .sendIdentityProbe, .sendSettingsMode, .sendLogin, .sendBaudSwitch, .sendMeasurementMode,
             .closePort, .openPort, .hold:
            return false
        }
    }
}

/// Die Ereignisse, die von außen hereinkommen (SICK-030a).
public enum CommissioningEvent: Equatable, Sendable {
    /// Bedienhandlung: Ausgangsrate prüfen.
    case operatorRequestedStartingRateCheck
    case operatorRequestedSettingsMode(secretIsAvailable: Bool)
    case operatorRequestedLogin(secretIsAvailable: Bool)
    case operatorRequestedTargetBaudRate
    case operatorRequestedTargetRateConnection
    /// Bedienhandlung: **die eine** überwachte Umschaltung starten.
    case operatorRequestedBaudSwitch(secretIsAvailable: Bool)
    /// Bedienhandlung: experimenteller Messmodus.
    case operatorRequestedMeasurementMode
    /// Bedienhandlung: Ratendiagnose nach einem Fehlschlag.
    case operatorRequestedDiagnostics
    /// Bedienhandlung: **die Commissioning-Sitzung ausdrücklich
    /// beenden** — der einzige Freigabepunkt eines erfolgreichen
    /// Ablaufs (SICK-030a2, Auflage A7).
    ///
    /// Zulässig ausschließlich an einem Ruhepunkt. Mitten in einer
    /// laufenden Sendung gibt es nichts zu „beenden" — dort ist
    /// ``operatorAborted`` der richtige Weg, und ein
    /// Beenden-Ereignis fällt in den regulären
    /// `unexpectedEvent`-Fehler.
    case operatorFinishedSession
    case operatorAborted
    case measurementPointCountMismatch

    /// Die Verbindungspolitik (`SickPLSCommissioningControl.ConnectionPolicy`,
    /// SICK-0330r) hat die B1-Identität bei der Zielrate **bereits**
    /// belegt, bevor dieses Modell angelegt wurde (SICK-0330a-0).
    ///
    /// **Bewusst ohne Nutzlast.** Ein `IdentityProbeOutcome`-Parameter
    /// ließe sich mit `.timeout`/`.ambiguous`/`.unexpectedResponse`
    /// konstruieren und ein B0-Ereignis kennt dieser Fall ohnehin
    /// nicht — ohne jeden Parameter ist dieser Eintritt strukturell
    /// **nie** mit etwas anderem als der belegten B1-Identität zu
    /// verwechseln.
    ///
    /// Zulässig **ausschließlich** an einem frischen Modell
    /// (``CommissioningPhase/idle``): Er sendet keine zweite Probe,
    /// öffnet/schließt keinen Port, fordert kein Login an — er setzt
    /// ausschließlich ``CommissioningModel/verifiedBaudRate`` aufgrund
    /// dieses Belegs und erreicht ``CommissioningPhase/verified``.
    /// Jedes unpassende oder doppelte Auftreten ist ein sichtbarer
    /// `unexpectedEvent`-Fehler — **kein stiller Neustart** eines schon
    /// laufenden oder bereits abgeschlossenen Ablaufs.
    case identityAlreadyConfirmedAtTargetRate

    case identityOutcome(IdentityProbeOutcome)
    case acknowledgement(AcknowledgementOutcome)
    /// Die Gesamtfrist der laufenden Sendung ist abgelaufen.
    case deadlineReached
    /// Der Port ist **wirklich** geschlossen.
    case portClosed
    /// Der Port ist **wirklich** bei dieser Rate geöffnet.
    ///
    /// Die Rate gehört zwingend dazu: Ohne sie könnte die Schleife eine
    /// Verbindung bei irgendeiner Rate melden und das Modell hielte sie
    /// für die angeforderte (SICK-030a3).
    case portOpened(SerialPortBaudRate)
    case portOpenFailed(String)
    /// Das Schließen selbst schlug fehl (SICK-030a3).
    case portCloseFailed(String)
    case writeFailed(String)
}

/// Der reine Wertreducer des Commissioning-Ablaufs (SICK-030a).
///
/// **Kein Port, keine Uhr, kein Thread, keine Fake-I/O** — genau wie
/// `ScanSessionState` (SICK-012) und `ZoneEditorState` (SICK-014):
/// alter Zustand plus Ereignis plus ein vom Aufrufer übergebener
/// monotoner Zeitpunkt ergeben den neuen Zustand und **eine** Anweisung.
/// Damit ist jeder Übergang ohne Hardware prüfbar.
///
/// **Das Geheimnis liegt nicht hier.** Der Reducer weiß nur, *ob* eines
/// vorliegt (`secretIsAvailable`); die Bytes sieht ausschließlich der
/// Encoder in der späteren Schleife. Ein Reducer, der das Geheimnis
/// hielte, wäre ein Wert, der es unbemerkt in jede Kopie mitnähme.
public struct CommissioningModel: Equatable {
    public let recipe: CommissioningRecipe
    public private(set) var phase: CommissioningPhase = .idle
    public private(set) var audit = CommissioningAudit()
    /// Die absolute Frist der laufenden Sendung — `nil`, wenn gerade
    /// nichts aussteht.
    public private(set) var pendingDeadlineMillis: Int64?
    /// Die belegte Rate nach erfolgreicher Verifikation. Der Monitor
    /// verbindet danach mit **diesem** Wert, nicht mit einer
    /// Nutzereingabe (Auflage A3).
    public private(set) var verifiedBaudRate: SerialPortBaudRate?
    /// Ein Messstrom wurde beobachtet.
    ///
    /// **Reine Information, nie ein Erfolgskriterium des Wechsels**
    /// (Auflage A1). Das Gerät stand nach dem einzigen realen Wechsel im
    /// Kommandomodus und sendete gerade **nicht** — ein Ablauf, der
    /// einen Messstrom verlangte, hätte diesen Erfolg als Fehler
    /// gemeldet.
    public private(set) var observedScanProfileStream = false

    /// Ob im **laufenden** Login-Lesefenster etwas ankam, das sich nicht
    /// deuten ließ (SICK-032a3a).
    ///
    /// **Bewusst nicht öffentlich und bewusst fensterlokal.** Sie
    /// entscheidet nichts über den Ablauf — sie beantwortet am
    /// Fristende genau eine Frage: „es kam gar nichts" oder „es kam
    /// etwas Undeutbares". `startLoginAttempt` setzt sie für jeden
    /// Versuch zurück, damit der zweite nicht den Befund des ersten
    /// erbt.
    private var sawUnreadableLoginAnswer = false

    public init(recipe: CommissioningRecipe = .r26) {
        self.recipe = recipe
    }

    /// Ob der Ablauf den Port gerade **hält** (SICK-030a2, Auflage A7).
    ///
    /// **Das ist keine Aussage über „gerade beschäftigt", sondern über
    /// Besitz.** Ein Ruhepunkt mitten im Ablauf — die bestätigte
    /// Ausgangsprüfung, die belegte Verifikation, der bestätigte
    /// Messmodus — hält den Port weiter, obwohl gerade nichts läuft:
    /// Der jeweils nächste Bedienbefehl sendet auf **derselben**
    /// Verbindung und bekommt kein ``CommissioningDirective/openPort``.
    ///
    /// Freigegeben wird nur an einem echten Ende: nie begonnen
    /// (``CommissioningPhase/idle``), ausdrücklich beendet
    /// (``CommissioningPhase/sessionFinished``), gescheitert oder nach
    /// abgeschlossener Ratendiagnose.
    ///
    /// **Die Ratendiagnose hält den Port über den Ratenwechsel hinweg**
    /// (SICK-030a3) — auch zwischen dem bestätigten Schließen der
    /// 9600er-Verbindung und dem Öffnen der 38400er. Sie gibt ihn dort
    /// nicht ab, sie wechselt die Rate; ein zwischenzeitlich freier Port
    /// wäre eine Einladung an den Monitor, ihn zu übernehmen.
    ///
    /// **Der `switch` ist ausdrücklich ohne `default`** — eine neue
    /// Phase muss sich entscheiden, statt still `true` zu erben.
    public var needsPort: Bool {
        switch phase {
        case .idle, .sessionFinished, .failed, .diagnosticsFinished:
            return false
        case .checkingStartingRate, .respondingAtStartingRate, .settingsModeEntered,
             .enteringSettingsMode, .enteringSettingsModeManually, .loggingIn, .loggingInManually,
             .loggedIn, .requestingBaudSwitch, .requestingBaudSwitchManually,
             .baudSwitchAcknowledged, .closingPort, .openingTargetPort,
             .verifyingTargetRate, .verified, .awaitingMeasurementStream,
             .measurementStreamConfirmed, .runningDiagnostics:
            return true
        }
    }

    // MARK: - Der Übergang

    @discardableResult
    public mutating func apply(_ event: CommissioningEvent, atMillis: Int64) -> CommissioningDirective {
        if case .measurementPointCountMismatch = event {
            audit.completeLast(with: .rejected)
            return fail(.measurementPointCountMismatch, atMillis: atMillis)
        }
        // Ein Abbruch ist von jeder Phase aus zulässig und bricht den
        // Ablauf, statt ihn in einem halben Zustand stehen zu lassen.
        if case .operatorAborted = event {
            return fail(.abortedByOperator, atMillis: atMillis)
        }
        // Ein Schreibfehler ist immer ein Stopp: Es ging nichts hinaus,
        // also kann nichts folgen.
        if case .writeFailed(let message) = event {
            audit.completeLast(with: .writeFailed)
            return fail(.writeFailed(message), atMillis: atMillis)
        }

        switch phase {
        case .idle, .respondingAtStartingRate, .settingsModeEntered, .loggedIn,
             .baudSwitchAcknowledged, .verified, .measurementStreamConfirmed,
             .diagnosticsFinished, .failed, .sessionFinished:
            return applyAtRestingPoint(event, atMillis: atMillis)

        case .checkingStartingRate:
            return applyDuringStartingCheck(event, atMillis: atMillis)

        case .enteringSettingsMode:
            return applyDuringSettingsMode(event, atMillis: atMillis)

        case .enteringSettingsModeManually:
            return applyDuringManualSettingsMode(event, atMillis: atMillis)

        case .loggingIn(let attempt):
            return applyDuringLogin(event, attempt: attempt, atMillis: atMillis)

        case .loggingInManually:
            return applyDuringManualLogin(event, atMillis: atMillis)

        case .requestingBaudSwitch:
            return applyDuringBaudSwitch(event, atMillis: atMillis)

        case .requestingBaudSwitchManually:
            return applyDuringManualBaudSwitch(event, atMillis: atMillis)

        case .closingPort:
            switch event {
            case .portClosed:
                phase = .openingTargetPort
                return .openPort(recipe.targetBaudRate)
            case .portCloseFailed(let message):
                // Auf **dieses** Schließen baut das Öffnen bei der
                // Zielrate auf; ohne es gibt es nichts fortzusetzen.
                return fail(.portCloseFailed(message), atMillis: atMillis)
            default:
                return fail(.unexpectedEvent, atMillis: atMillis)
            }

        case .openingTargetPort:
            switch event {
            case .portOpened(let rate) where rate == recipe.targetBaudRate:
                phase = .verifyingTargetRate
                let address = recipe.verificationAddress.rawValue
                let deadline = send(
                    .verification(recipe.targetBaudRate), address: address,
                    timeoutMilliseconds: recipe.responseTimeoutMilliseconds, atMillis: atMillis
                )
                return .sendIdentityProbe(address: address, deadlineMillis: deadline)
            case .portOpenFailed(let message):
                return fail(.portOpenFailed(message), atMillis: atMillis)
            default:
                return fail(.unexpectedEvent, atMillis: atMillis)
            }

        case .verifyingTargetRate:
            return applyDuringVerification(event, atMillis: atMillis)

        case .awaitingMeasurementStream(let deadlineMillis):
            return applyDuringMeasurementStreamWait(event, deadlineMillis: deadlineMillis, atMillis: atMillis)

        case .runningDiagnostics(let step, let report):
            return applyDuringDiagnostics(event, step: step, report: report, atMillis: atMillis)
        }
    }

    // MARK: - Ruhepunkte

    private mutating func applyAtRestingPoint(
        _ event: CommissioningEvent, atMillis: Int64
    ) -> CommissioningDirective {
        switch event {
        case .operatorRequestedStartingRateCheck:
            observedScanProfileStream = false
            phase = .checkingStartingRate
            let address = recipe.configurationAddress.rawValue
            let deadline = send(
                .identityCheck(recipe.startingBaudRate), address: address,
                timeoutMilliseconds: recipe.responseTimeoutMilliseconds, atMillis: atMillis
            )
            return .sendIdentityProbe(address: address, deadlineMillis: deadline)

        case .operatorRequestedSettingsMode(let secretIsAvailable):
            guard case .respondingAtStartingRate = phase, secretIsAvailable else {
                return fail(.unexpectedEvent, atMillis: atMillis)
            }
            phase = .enteringSettingsModeManually
            let deadline = send(
                .settingsMode, address: recipe.settingsModeAddress.rawValue,
                timeoutMilliseconds: recipe.responseTimeoutMilliseconds, atMillis: atMillis
            )
            return .sendSettingsMode(deadlineMillis: deadline)

        case .operatorRequestedLogin(let secretIsAvailable):
            guard case .settingsModeEntered = phase, secretIsAvailable else {
                return fail(.unexpectedEvent, atMillis: atMillis)
            }
            phase = .loggingInManually
            sawUnreadableLoginAnswer = false
            let attempt = audit.attemptCount(of: .login) + 1
            let deadline = send(
                .login, address: recipe.configurationAddress.rawValue,
                timeoutMilliseconds: recipe.loginResponseTimeoutMilliseconds, atMillis: atMillis
            )
            return .sendLogin(attempt: attempt, deadlineMillis: deadline)

        case .operatorRequestedTargetBaudRate:
            guard case .loggedIn = phase else { return fail(.unexpectedEvent, atMillis: atMillis) }
            phase = .requestingBaudSwitchManually
            let deadline = send(
                .baudSwitchRequest, address: recipe.configurationAddress.rawValue,
                timeoutMilliseconds: recipe.responseTimeoutMilliseconds, atMillis: atMillis
            )
            return .sendBaudSwitch(deadlineMillis: deadline)

        case .operatorRequestedTargetRateConnection:
            guard case .baudSwitchAcknowledged = phase else {
                return fail(.unexpectedEvent, atMillis: atMillis)
            }
            phase = .closingPort
            return .closePort

        case .operatorRequestedBaudSwitch(let secretIsAvailable):
            // **Nur** aus der belegten Ausgangslage heraus: Ohne
            // vorherige Antwort bei der Ausgangsrate wüsste niemand, ob
            // das Gerät überhaupt spricht -- und ein Login ins Leere ist
            // der Zustand, den die Beleglage als „bleibt unbeantwortet"
            // kennt.
            guard case .respondingAtStartingRate = phase else {
                return fail(.unexpectedEvent, atMillis: atMillis)
            }
            guard secretIsAvailable else {
                return fail(.unexpectedEvent, atMillis: atMillis)
            }
            // **Kein `openPort` davor, und das ist Absicht** (Auflage
            // A7): Der Port ist seit der Ausgangsprüfung durchgehend
            // gehalten, das Login geht über **dieselbe** Verbindung.
            phase = .enteringSettingsMode
            let deadline = send(
                .settingsMode, address: recipe.settingsModeAddress.rawValue,
                timeoutMilliseconds: recipe.responseTimeoutMilliseconds, atMillis: atMillis
            )
            return .sendSettingsMode(deadlineMillis: deadline)

        case .operatorRequestedMeasurementMode:
            // Erst **nach** belegtem Wechsel -- der Schritt ist
            // experimentell, aber er soll wenigstens auf einem belegten
            // Zustand aufsetzen.
            guard case .verified = phase else { return fail(.unexpectedEvent, atMillis: atMillis) }
            // **Kein `openPort` davor** (Auflage A7): Der bei der
            // Zielrate geöffnete Port ist seit der Verifikation
            // gehalten.
            //
            // **Die feste, eigene 3-Sekunden-Stromfrist** (SICK-0330a-0)
            // -- nicht `recipe.responseTimeoutMilliseconds`, das den
            // übrigen Sendungen gehört.
            let deadline = send(
                recipe.measurementMode == .mmk ? .measurementModeRequest : .fullScanMeasurementModeRequest,
                address: recipe.configurationAddress.rawValue,
                timeoutMilliseconds: recipe.measurementStreamTimeoutMilliseconds,
                atMillis: atMillis
            )
            phase = .awaitingMeasurementStream(deadlineMillis: deadline)
            return .sendMeasurementMode(deadlineMillis: deadline)

        case .identityAlreadyConfirmedAtTargetRate:
            // **Nur an einem frischen Modell** (SICK-0330a-0): Die
            // Verbindungspolitik hat B1 bei der Zielrate bereits belegt
            // -- ein zweiter Beleg oder ein Auftreten mitten in einem
            // schon laufenden oder bereits abgeschlossenen Ablauf ist
            // ein sichtbarer Fehler, **kein** stiller Neustart.
            guard case .idle = phase else { return fail(.unexpectedEvent, atMillis: atMillis) }
            verifiedBaudRate = recipe.targetBaudRate
            phase = .verified
            // **Ruhen, aber halten** (Auflage A7): Der optionale
            // Messmodus setzt auf dieser Verbindung auf -- genau wie
            // nach einer selbst durchgeführten Verifikation.
            return .hold

        case .operatorFinishedSession:
            // **Der einzige Freigabepunkt** (Auflage A7). Er ist von
            // jedem Ruhepunkt aus zulässig -- auch von `idle` und nach
            // einem Fehlschlag, wo er nichts freigibt, was nicht schon
            // frei wäre; eine Bedienoberfläche soll „Sitzung beenden"
            // nicht je nach Vorgeschichte verweigern müssen.
            pendingDeadlineMillis = nil
            phase = .sessionFinished
            return .stop

        case .operatorRequestedDiagnostics:
            // Nur nach einem Fehlschlag sinnvoll -- sonst ist die
            // Ausgangsprüfung der richtige Knopf.
            guard case .failed = phase else { return fail(.unexpectedEvent, atMillis: atMillis) }
            let empty = CommissioningDiagnosticsReport(
                outcomeAtStartingRate: nil, outcomeAtTargetRate: nil
            )
            // **Erst öffnen, dann proben** (SICK-030a3). Ein Fehlschlag
            // hat den Port über den `stop`-Vertrag freigegeben; die
            // Diagnose fängt deshalb mit einer wirklich bei der
            // Ausgangsrate geöffneten Verbindung an, statt auf einer
            // angenommenen zu senden. Den Portbesitz holt sich die
            // Schleife davor über `SerialPortOwnership` (SICK-030a1) --
            // der Reducer sagt nur, was zu tun wäre.
            phase = .runningDiagnostics(step: .openingPort(recipe.startingBaudRate), report: empty)
            return .openPort(recipe.startingBaudRate)

        case .acknowledgement(.observedScanProfile), .identityOutcome:
            // Ein Messstrom oder eine verspätete Antwort an einem
            // Ruhepunkt ist kein Fehler -- nur nichts, worauf zu
            // reagieren wäre.
            if case .acknowledgement(.observedScanProfile) = event { observedScanProfileStream = true }
            return .none

        default:
            return .none
        }
    }

    // MARK: - Laufende Phasen

    private mutating func applyDuringStartingCheck(
        _ event: CommissioningEvent, atMillis: Int64
    ) -> CommissioningDirective {
        switch event {
        case .identityOutcome(.identified):
            audit.completeLast(with: .acknowledged)
            pendingDeadlineMillis = nil
            phase = .respondingAtStartingRate
            // **Ruhen, aber halten** (Auflage A7): Das Login folgt auf
            // derselben Verbindung, es gibt dafür kein `openPort`.
            return .hold
        case .identityOutcome(let other):
            audit.completeLast(with: auditOutcome(for: other))
            return fail(.noDeviceAtStartingRate(other), atMillis: atMillis)
        case .deadlineReached:
            audit.completeLast(with: .timedOut)
            return fail(.noDeviceAtStartingRate(.timeout), atMillis: atMillis)
        case .acknowledgement(.observedScanProfile):
            observedScanProfileStream = true
            return .none
        default:
            return fail(.unexpectedEvent, atMillis: atMillis)
        }
    }

    private mutating func applyDuringSettingsMode(
        _ event: CommissioningEvent, atMillis: Int64
    ) -> CommissioningDirective {
        switch event {
        case .acknowledgement(.acknowledged):
            audit.completeLast(with: .acknowledged)
            pendingDeadlineMillis = nil
            phase = .loggingIn(attempt: 1)
            return startLoginAttempt(1, atMillis: atMillis)
        case .acknowledgement(.rejected):
            audit.completeLast(with: .rejected)
            return fail(.settingsModeRejected, atMillis: atMillis)
        case .acknowledgement(.observedScanProfile):
            observedScanProfileStream = true
            return .none
        case .acknowledgement:
            audit.completeLast(with: .ambiguous)
            return fail(.settingsModeAmbiguous, atMillis: atMillis)
        case .deadlineReached:
            audit.completeLast(with: .timedOut)
            return fail(.settingsModeUnanswered, atMillis: atMillis)
        default:
            return fail(.unexpectedEvent, atMillis: atMillis)
        }
    }

    private mutating func applyDuringManualSettingsMode(
        _ event: CommissioningEvent, atMillis: Int64
    ) -> CommissioningDirective {
        switch event {
        case .acknowledgement(.acknowledged):
            audit.completeLast(with: .acknowledged)
            pendingDeadlineMillis = nil
            phase = .settingsModeEntered
            return .hold
        case .acknowledgement(.rejected):
            audit.completeLast(with: .rejected)
            return fail(.settingsModeRejected, atMillis: atMillis)
        case .acknowledgement(.observedScanProfile):
            observedScanProfileStream = true
            return .none
        case .acknowledgement:
            audit.completeLast(with: .ambiguous)
            pendingDeadlineMillis = nil
            phase = .respondingAtStartingRate
            return .hold
        case .deadlineReached:
            audit.completeLast(with: .timedOut)
            pendingDeadlineMillis = nil
            phase = .respondingAtStartingRate
            return .hold
        default:
            return fail(.unexpectedEvent, atMillis: atMillis)
        }
    }

    private mutating func applyDuringManualLogin(
        _ event: CommissioningEvent, atMillis: Int64
    ) -> CommissioningDirective {
        switch event {
        case .acknowledgement(.observedScanProfile):
            observedScanProfileStream = true
            return .none
        case .acknowledgement(let outcome) where !outcome.concludesLoginAttempt:
            sawUnreadableLoginAnswer = true
            return .none
        case .acknowledgement(.acknowledged):
            audit.completeLast(with: .acknowledged)
            pendingDeadlineMillis = nil
            phase = .loggedIn
            return .hold
        case .acknowledgement(.rejected):
            audit.completeLast(with: .rejected)
            return fail(.loginRejected, atMillis: atMillis)
        case .deadlineReached:
            audit.completeLast(with: sawUnreadableLoginAnswer ? .ambiguous : .timedOut)
            pendingDeadlineMillis = nil
            phase = .settingsModeEntered
            return .hold
        default:
            return fail(.unexpectedEvent, atMillis: atMillis)
        }
    }

    private mutating func applyDuringLogin(
        _ event: CommissioningEvent, attempt: Int, atMillis: Int64
    ) -> CommissioningDirective {
        switch event {
        case .acknowledgement(.observedScanProfile):
            // Bekanntes Rauschen -- überspringen, Frist läuft weiter.
            // Es ist **kein** unlesbarer Befund und darf den Grund des
            // Fensters deshalb nicht verfärben.
            observedScanProfileStream = true
            return .none

        case .acknowledgement(let outcome) where !outcome.concludesLoginAttempt:
            // **Unlesbar beendet den Versuch nicht** (SICK-032a3a).
            //
            // ``AcknowledgementOutcome/concludesLoginAttempt`` ist hier
            // **lasttragend, nicht bloß beschreibend**: Dieser Zweig
            // steht **vor** ``acknowledged``/``rejected``, also
            // entscheidet die Eigenschaft wirklich, was den Versuch
            // beendet. Wer sie ändert, ändert das Verhalten -- und
            // genau das soll sie leisten, statt eine Zusage zu sein,
            // die niemand einlöst.
            //
            // Es wird nur **gemerkt** und **innerhalb derselben Frist
            // weitergelesen**: Ein nacktes `06` darf das Fenster nicht
            // verkürzen, und eine **spätere gültige Antwort in
            // derselben Frist** gehört noch zu *diesem* Telegramm und
            // führt ohne zweite Sendung weiter.
            //
            // SICK-032a3 hat an dieser Stelle sofort wiederholt; das war
            // die Wiederholung zum falschen Zeitpunkt.
            sawUnreadableLoginAnswer = true
            return .none

        case .acknowledgement(.acknowledged):
            audit.completeLast(with: .acknowledged)
            phase = .requestingBaudSwitch
            let deadline = send(
                .baudSwitchRequest, address: recipe.configurationAddress.rawValue,
                timeoutMilliseconds: recipe.responseTimeoutMilliseconds, atMillis: atMillis
            )
            return .sendBaudSwitch(deadlineMillis: deadline)

        case .acknowledgement(.rejected):
            audit.completeLast(with: .rejected)
            return fail(.loginRejected, atMillis: atMillis)

        case .deadlineReached:
            // **Erst hier** ist der Versuch zu Ende -- und erst hier
            // geht die naechste der begrenzten Wiederholungen hinaus:
            // identisch, auf derselben Verbindung, danach nie wieder.
            //
            // Der gemeldete Grund ist der dieses Fensters: „es kam
            // etwas Undeutbares" und „es kam gar nichts" bleiben
            // unterscheidbar.
            let sawUnreadable = sawUnreadableLoginAnswer
            audit.completeLast(with: sawUnreadable ? .ambiguous : .timedOut)
            guard attempt < recipe.maximumLoginAttempts else {
                return fail(sawUnreadable ? .loginAmbiguous : .loginUnanswered, atMillis: atMillis)
            }
            return retryLogin(from: attempt, atMillis: atMillis)

        default:
            return fail(.unexpectedEvent, atMillis: atMillis)
        }
    }

    /// **Die eine identische Wiederholung, an genau einer Stelle.**
    ///
    /// Sie hat **genau einen** Aufrufer: den Fristablauf. Eine zweite
    /// Sendestelle wäre ein zweites Budget, und damit wäre es nicht mehr
    /// „genau eine" Wiederholung (Auflage **A2**) — und sie ginge, wie
    /// in SICK-032a3, womöglich **vor** dem Ende des Lesefensters
    /// hinaus.
    ///
    /// **Dieselbe offene Verbindung:** Es wird kein Port geschlossen und
    /// keiner geöffnet; `needsPort` bleibt für `.loggingIn` wahr, und
    /// die Direktive ist wieder eine reine Sendung.
    private mutating func retryLogin(from attempt: Int, atMillis: Int64) -> CommissioningDirective {
        let nextAttempt = attempt + 1
        phase = .loggingIn(attempt: nextAttempt)
        return startLoginAttempt(nextAttempt, atMillis: atMillis)
    }

    /// Sendet das Login-Telegramm und öffnet **ein frisches Lesefenster**.
    ///
    /// **Die Merkmarke gehört zum Fenster, nicht zum Ablauf** — sonst
    /// erbte der zweite Versuch den Befund des ersten, und das Audit
    /// spräche für ein Fenster, in dem gar nichts ankam, von einer
    /// unlesbaren Antwort.
    private mutating func startLoginAttempt(
        _ attempt: Int, atMillis: Int64
    ) -> CommissioningDirective {
        sawUnreadableLoginAnswer = false
        let deadline = send(
            .login, address: recipe.configurationAddress.rawValue,
            timeoutMilliseconds: recipe.loginResponseTimeoutMilliseconds, atMillis: atMillis
        )
        return .sendLogin(attempt: attempt, deadlineMillis: deadline)
    }

    private mutating func applyDuringBaudSwitch(
        _ event: CommissioningEvent, atMillis: Int64
    ) -> CommissioningDirective {
        switch event {
        case .acknowledgement(.acknowledged):
            // Die Bestätigung kommt **noch bei der alten Rate**; erst
            // danach schließt der Host und öffnet neu.
            audit.completeLast(with: .acknowledged)
            pendingDeadlineMillis = nil
            phase = .closingPort
            return .closePort
        case .acknowledgement(.rejected):
            audit.completeLast(with: .rejected)
            return fail(.baudSwitchRejected, atMillis: atMillis)
        case .acknowledgement(.observedScanProfile):
            observedScanProfileStream = true
            return .none
        case .acknowledgement:
            audit.completeLast(with: .ambiguous)
            return fail(.baudSwitchAmbiguous, atMillis: atMillis)
        case .deadlineReached:
            // **Keine Wiederholung** -- nur das Login hat eine.
            audit.completeLast(with: .timedOut)
            return fail(.baudSwitchUnanswered, atMillis: atMillis)
        default:
            return fail(.unexpectedEvent, atMillis: atMillis)
        }
    }

    private mutating func applyDuringManualBaudSwitch(
        _ event: CommissioningEvent, atMillis: Int64
    ) -> CommissioningDirective {
        switch event {
        case .acknowledgement(.acknowledged):
            audit.completeLast(with: .acknowledged)
            pendingDeadlineMillis = nil
            phase = .baudSwitchAcknowledged
            return .hold
        case .acknowledgement(.rejected):
            audit.completeLast(with: .rejected)
            return fail(.baudSwitchRejected, atMillis: atMillis)
        case .acknowledgement(.observedScanProfile):
            observedScanProfileStream = true
            return .none
        case .acknowledgement:
            audit.completeLast(with: .ambiguous)
            return fail(.baudSwitchAmbiguous, atMillis: atMillis)
        case .deadlineReached:
            audit.completeLast(with: .timedOut)
            return fail(.baudSwitchUnanswered, atMillis: atMillis)
        default:
            return fail(.unexpectedEvent, atMillis: atMillis)
        }
    }

    private mutating func applyDuringVerification(
        _ event: CommissioningEvent, atMillis: Int64
    ) -> CommissioningDirective {
        switch event {
        case .identityOutcome(.identified):
            // **Auflage A1:** Das ist das Erfolgskriterium -- eine
            // CRC-valide Identitätsantwort am neu geöffneten Port. Ein
            // Messstrom ist dafür weder nötig noch hinreichend.
            audit.completeLast(with: .acknowledged)
            pendingDeadlineMillis = nil
            verifiedBaudRate = recipe.targetBaudRate
            phase = .verified
            // **Ruhen, aber halten** (Auflage A7): Der optionale
            // Messmodus setzt auf dieser Verbindung auf.
            return .hold
        case .identityOutcome(let other):
            audit.completeLast(with: auditOutcome(for: other))
            return fail(.verificationFailed(other), atMillis: atMillis)
        case .deadlineReached:
            audit.completeLast(with: .timedOut)
            return fail(.verificationFailed(.timeout), atMillis: atMillis)
        case .acknowledgement(.observedScanProfile):
            observedScanProfileStream = true
            return .none
        default:
            return fail(.unexpectedEvent, atMillis: atMillis)
        }
    }

    /// Die feste 3-Sekunden-Stromfrist nach der MMK-Anforderung
    /// (SICK-0330a-0, verschärft in SICK-0330a-0-K1).
    ///
    /// **Die einzige reale Beobachtung zu diesem Schritt hatte keine
    /// zuverlässig lesbare unmittelbare Quittung, danach aber echten
    /// B0-Strom bei 38400.** Ein Modell, das ACK zum Erfolg oder eine
    /// unlesbare Antwort zum sofortigen Fehler machte, hätte genau
    /// diesen belegten Verlauf als Fehlschlag gemeldet. Deshalb gilt
    /// hier eine andere Regel als beim Login (SICK-032a3a): **Nur zwei
    /// Ausgänge entscheiden etwas.**
    ///
    /// - ``AcknowledgementOutcome/observedScanProfile`` **nach** dieser
    ///   Anforderung und **vor** Fristende ist der **einzige** Erfolg
    ///   (analog Auflage A1) -- ein davor beobachteter Strom kann
    ///   diesen Zustand nicht einmal erreichen, weil die Anforderung
    ///   ihn erst danach betritt.
    /// - ``AcknowledgementOutcome/rejected`` **vor** Fristende ist der
    ///   **einzige** sofortige Fehler -- „nein" heißt nein.
    ///
    /// **Alles Übrige entscheidet den Ausgang nicht, wird aber als
    /// eigene, von der Wirkung getrennte Tatsache im Audit vermerkt**
    /// (K1-1): ACK, eindeutig abgelehnt, oder eine redigierte
    /// „unlesbar"-Kategorie -- nie das Rohbyte. Ein späterer B0 oder
    /// Fristablauf überschreibt diese Tatsache nicht, und sie
    /// verschluckt umgekehrt nie den späteren Stromerfolg.
    ///
    /// **Die absolute Frist entscheidet selbst, nicht nur
    /// beschreibend** (K1-2): Jedes Ereignis, das hier ankommt, wird
    /// zuerst gegen `deadlineMillis` geprüft. Bei oder nach der Frist
    /// erzeugen B0, ACK, NACK oder jede sonstige Antwort **keinen**
    /// Erfolg und **keine** verspätete Ablehnung mehr -- der Lauf endet
    /// eindeutig ``CommissioningFailure/measurementStreamAbsent``. Eine
    /// verfrühte ``CommissioningEvent/deadlineReached`` verkürzt die
    /// Frist dagegen nicht: Sie bleibt ohne Wirkung, solange
    /// `atMillis < deadlineMillis`. Am exakten Grenzwert gilt die Frist
    /// als abgelaufen -- passend zur Executor-Regel `remaining > 0`
    /// (SICK-031a, Auflage E2).
    private mutating func applyDuringMeasurementStreamWait(
        _ event: CommissioningEvent, deadlineMillis: Int64, atMillis: Int64
    ) -> CommissioningDirective {
        switch event {
        case .deadlineReached:
            guard atMillis >= deadlineMillis else {
                // Verfrüht -- die Frist ist real noch nicht abgelaufen.
                // Kein Erfolg, keine neue Direktive, keine neue Frist in
                // derselben Wartephase.
                return .none
            }
            return expireMeasurementStreamWait(atMillis: atMillis)

        case .acknowledgement(let outcome):
            guard atMillis < deadlineMillis else {
                // Die Frist ist bereits abgelaufen, als diese Antwort
                // eintraf -- ihr Inhalt entscheidet nichts mehr, egal ob
                // B0, ACK, NACK oder sonst etwas (Pflichtnachweis 6).
                return expireMeasurementStreamWait(atMillis: atMillis)
            }
            return applyMeasurementStreamAcknowledgement(outcome, atMillis: atMillis)

        default:
            return fail(.unexpectedEvent, atMillis: atMillis)
        }
    }

    /// Die Stromfrist ist real abgelaufen -- gleich, ob durch
    /// ``CommissioningEvent/deadlineReached`` oder durch eine erst bei
    /// oder nach `deadlineMillis` eingetroffene Antwort ausgelöst
    /// (K1-2). Beide Wege enden in derselben, eindeutigen Wirkung.
    private mutating func expireMeasurementStreamWait(atMillis: Int64) -> CommissioningDirective {
        audit.completeLast(with: .timedOut)
        return fail(.measurementStreamAbsent, atMillis: atMillis)
    }

    /// Wertet eine Bestätigungsantwort aus, die **innerhalb** der
    /// Stromfrist eintraf (K1-1).
    ///
    /// **`switch` ohne `default`** -- ein neuer `AcknowledgementOutcome`-
    /// Fall muss sich hier bewusst zwischen entscheidend und
    /// nicht-entscheidend einordnen.
    private mutating func applyMeasurementStreamAcknowledgement(
        _ outcome: AcknowledgementOutcome, atMillis: Int64
    ) -> CommissioningDirective {
        switch outcome {
        case .observedScanProfile:
            observedScanProfileStream = true
            audit.completeLast(with: .observedScanProfileStream)
            pendingDeadlineMillis = nil
            phase = .measurementStreamConfirmed
            // **Ruhen, aber halten** (Auflage A7): Freigegeben wird erst
            // beim ausdrücklichen Sitzungsabschluss.
            return .hold

        case .rejected:
            audit.recordImmediateResponse(.rejected)
            audit.completeLast(with: .rejected)
            return fail(.measurementModeRejected, atMillis: atMillis)

        case .acknowledged:
            // Bestätigt nur den Empfang des Kommandos, nicht seine
            // Wirkung -- die Frist läuft unverändert weiter, aber die
            // Antwort selbst bleibt jetzt als eigene Tatsache sichtbar.
            audit.recordImmediateResponse(.acknowledged)
            return .none

        case .unknownStatus, .missingStatusByte, .unexpectedCommandByte, .undecodable:
            // Redigiert im Audit sichtbar -- nie das Rohbyte
            // (Pflichtnachweis 3). Die Frist bleibt unangetastet.
            audit.recordImmediateResponse(.unreadable)
            return .none

        case .timeout:
            // Innerhalb des Fensters kam nichts Auswertbares -- dieselbe
            // Lage wie „keine unmittelbare Antwort". Nichts zu
            // vermerken: `nil` beschreibt das bereits.
            return .none
        }
    }

    /// Die Ratendiagnose (SICK-030a3).
    ///
    /// **Der ganze Sinn der Zwischenschritte:** Jede Rate wird auf einer
    /// Verbindung geprüft, die **wirklich so geöffnet** wurde. Zwischen
    /// den beiden Proben steht deshalb ein echtes Schließen und ein
    /// echtes Öffnen, jeweils mit bestätigendem Ereignis — nicht ein
    /// Ratenwechsel, den das Modell nur behauptet.
    ///
    /// **Gesendet wird ausschließlich die harmlose Identitätsprobe**, je
    /// Rate genau eine, ohne Wiederholung. Kein Konfigurationstelegramm,
    /// kein Login, kein Rückstellkommando. Und **weder ein Messstrom noch
    /// eine Bestätigung noch ein vermuteter Ratenwechsel** gilt als
    /// Identitätserfolg — dafür gibt es genau ein Ereignis,
    /// ``CommissioningEvent/identityOutcome(_:)`` mit
    /// `IdentityProbeOutcome.identified`.
    private mutating func applyDuringDiagnostics(
        _ event: CommissioningEvent,
        step: CommissioningDiagnosticsStep,
        report: CommissioningDiagnosticsReport,
        atMillis: Int64
    ) -> CommissioningDirective {
        // Bekanntes Rauschen hält die Diagnose in keinem Schritt auf --
        // und belegt in keinem etwas.
        if case .acknowledgement(.observedScanProfile) = event {
            observedScanProfileStream = true
            return .none
        }

        switch step {
        case .openingPort(let rate):
            switch event {
            case .portOpened(let opened) where opened == rate:
                // **Erst jetzt** wird die Probe protokolliert: Vorher gab
                // es keine Verbindung, auf der sie hätte hinausgehen
                // können.
                phase = .runningDiagnostics(step: .probing(rate), report: report)
                let address = recipe.verificationAddress.rawValue
                let deadline = send(
                    .diagnosticProbe(rate), address: address,
                    timeoutMilliseconds: recipe.responseTimeoutMilliseconds, atMillis: atMillis
                )
                return .sendIdentityProbe(address: address, deadlineMillis: deadline)
            case .portOpenFailed(let message):
                return fail(.portOpenFailed(message), atMillis: atMillis)
            default:
                // Eine **falsche** Rate fällt hierher: Der Reducer nimmt
                // eine Verbindung, die er nicht angefordert hat, nicht
                // stillschweigend für die angeforderte.
                return fail(.unexpectedEvent, atMillis: atMillis)
            }

        case .probing(let rate):
            let outcome: IdentityProbeOutcome
            switch event {
            case .identityOutcome(let value): outcome = value
            case .deadlineReached: outcome = .timeout
            default: return fail(.unexpectedEvent, atMillis: atMillis)
            }
            audit.completeLast(with: auditOutcome(for: outcome))
            pendingDeadlineMillis = nil

            guard rate == recipe.startingBaudRate else {
                // Zweite und letzte Rate: **kein** ausdrückliches
                // `closePort` mehr -- das Schließen liegt im
                // `stop`-Vertrag, der auch dann stimmt, wenn gar nichts
                // offen ist.
                phase = .diagnosticsFinished(
                    CommissioningDiagnosticsReport(
                        outcomeAtStartingRate: report.outcomeAtStartingRate,
                        outcomeAtTargetRate: outcome
                    )
                )
                return .stop
            }

            // Erste Rate erledigt und auditiert -- jetzt der **wirkliche**
            // Portwechsel, bevor die zweite Rate überhaupt geprüft wird.
            phase = .runningDiagnostics(
                step: .closingPort(rate),
                report: CommissioningDiagnosticsReport(
                    outcomeAtStartingRate: outcome,
                    outcomeAtTargetRate: report.outcomeAtTargetRate
                )
            )
            return .closePort

        case .closingPort:
            switch event {
            case .portClosed:
                phase = .runningDiagnostics(
                    step: .openingPort(recipe.targetBaudRate), report: report
                )
                return .openPort(recipe.targetBaudRate)
            case .portCloseFailed(let message):
                // Sichtbar beenden statt bei der Zielrate weiterzumachen:
                // Was hier offen bleibt, spricht noch die alte Rate.
                return fail(.portCloseFailed(message), atMillis: atMillis)
            default:
                return fail(.unexpectedEvent, atMillis: atMillis)
            }
        }
    }

    // MARK: - Hilfen

    /// Trägt die Sendung ins Protokoll ein, setzt die **absolute**
    /// monotone Gesamtfrist und gibt sie zurück — die Anweisung baut der
    /// Aufrufer daraus.
    ///
    /// **`timeoutMilliseconds` ist ausdrücklich am Aufrufer** statt
    /// stillschweigend `recipe.responseTimeoutMilliseconds` zu
    /// verwenden: Die MMK-Anforderung braucht seit SICK-0330a-0 eine
    /// eigene, längere Frist (`recipe.measurementStreamTimeoutMilliseconds`).
    /// Ein gemeinsamer Vorgabewert hätte diesen Unterschied stillschweigend
    /// eingeebnet.
    ///
    /// Bewusst kein Closure-Parameter: Eine Closure, die `self`
    /// einfängt, während diese Methode `self` verändert, ist in Swift
    /// ein Exklusivitätsverstoß.
    private mutating func send(
        _ action: CommissioningAction,
        address: UInt8,
        timeoutMilliseconds: Int64,
        atMillis: Int64
    ) -> Int64 {
        let attemptNumber = audit.attemptCount(of: action) + 1
        audit.recordSend(action, attemptNumber: attemptNumber, targetAddress: address, atMillis: atMillis)
        let deadline = atMillis + timeoutMilliseconds
        pendingDeadlineMillis = deadline
        return deadline
    }

    private mutating func fail(
        _ failure: CommissioningFailure, atMillis: Int64
    ) -> CommissioningDirective {
        pendingDeadlineMillis = nil
        phase = .failed(failure)
        return .stop
    }

    private func auditOutcome(for outcome: IdentityProbeOutcome) -> CommissioningAuditOutcome {
        switch outcome {
        case .identified: return .acknowledged
        case .timeout: return .timedOut
        case .unexpectedResponse, .ambiguous: return .ambiguous
        }
    }
}
