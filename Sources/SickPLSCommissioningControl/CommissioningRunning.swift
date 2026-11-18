import SickPLSCommissioning

/// Die **einzige** Grenze, über die dieser Bedienpfad einen
/// Einrichtungsschritt wirklich ausführen lässt (SICK-032a, Auflage E3).
///
/// ## Warum genau ein Mitglied
///
/// Review-Befund **N2** zu SICK-031: `CommissioningExecutor.report`
/// eines **nie gestarteten** Executors ist `isFinal` — bei `.idle` ist
/// `needsPort == false`, also `restingDirective == .stop`. Ein Abschluss
/// aus diesem Wert gäbe den Portbesitz frei, ohne dass je ein Lauf
/// stattfand.
///
/// Der Auftrag verlangt deshalb, den Abschluss **ausschließlich** aus dem
/// Bericht eines tatsächlich gelaufenen `perform` zu speisen. Das ist
/// hier keine Vereinbarung, sondern **strukturell**: Dieses Protokoll
/// kennt `report` nicht. Ein Bedienmodell, das nur diese Grenze sieht,
/// kann den falschen Wert nicht einmal benennen.
///
/// **Wer hier ein Mitglied ergänzt, macht genau diesen Beweis kaputt**
/// — `CommissioningControlBoundaryTests` schlägt dann fehl.
///
/// ## Threadvertrag
///
/// ``perform(_:secret:)`` ist **synchron und blockierend** und wartet bis
/// zur Frist des Reducers. Es gehört deshalb nicht auf den Main Thread;
/// die Serialisierung und der Hintergrund-Thread liegen in
/// ``CommissioningDispatching``. Eine Umsetzung ist **nicht**
/// threadsicher: Zu einem Zeitpunkt läuft höchstens ein Aufruf.
public protocol CommissioningRunning: AnyObject {
    /// Führt genau eine Bedienhandlung aus und liefert den Bericht des
    /// Ruhepunkts, an dem der Ablauf stehen blieb.
    ///
    /// - Parameter secret: Nur für ``CommissioningCommand/switchBaudRate``
    ///   nötig und dort zwingend. Es wird **weitergereicht, nie
    ///   gespeichert** — weder hier noch im Bedienmodell.
    func perform(_ command: CommissioningCommand, secret: InstallationSecret?) -> CommissioningStepReport
}

extension CommissioningExecutor: CommissioningRunning {}

/// Die kooperative Abbruchgrenze eines laufenden ``CommissioningRunning``
/// (SICK-0330a-1).
///
/// ## Warum eine eigene, zweite Grenze
///
/// `perform(_:secret:)` ist synchron und blockierend; ein zweiter
/// `perform(.abort)` reiht sich hinter dem laufenden Aufruf auf
/// derselben seriellen Warteschlange ein und erreicht ihn nie. Ein
/// Abbruchmitglied direkt an ``CommissioningRunning`` zu hängen, würde
/// zudem genau den Beweis kaputt machen, den
/// `CommissioningControlBoundaryTests.testTheRunBoundaryDeclaresExactlyOneMember`
/// führt (Review-Befund N2 zu SICK-031). Diese Grenze steht deshalb
/// **daneben**, nicht **in** `CommissioningRunning`.
///
/// ## Threadvertrag
///
/// ``requestAbort()`` ist **von jedem Thread aus sicher aufrufbar**,
/// auch während ein anderer Ausführungskontext gerade in
/// `perform(_:secret:)` blockiert.
public protocol CommissioningAborting: AnyObject {
    /// Fordert an, dass die **aktuell reservierte Laufkante** (der
    /// laufende oder der gerade eingeplante ``CommissioningRunning/perform(_:secret:)``-Aufruf)
    /// so bald wie kooperativ möglich mit ``CommissioningFailure/abortedByOperator``
    /// endet.
    func requestAbort()

    /// Reserviert **synchron, vor dem Einplanen des zugehörigen
    /// Hintergrundaufrufs** eine atomare Laufkante für den kommenden
    /// `perform`-Aufruf (SICK-0330a-1-K2).
    ///
    /// **Gehört genau hierher, nicht zu ``CommissioningRunning``:** Sie
    /// betrifft ausschließlich die Abbruchlebensdauer, nicht die
    /// Ausführung selbst — dieselbe Trennung, aus der diese Grenze
    /// überhaupt besteht. Ohne einen vorherigen Aufruf hier reserviert
    /// der zugehörige `perform`-Aufruf beim eigenen Beginn selbst eine
    /// Laufkante — dieser Aufruf schließt ausschließlich die Lücke
    /// zwischen dem Einplanen und dem tatsächlichen Start, in der eine
    /// Abbruchanforderung sonst ins Leere liefe.
    func beginRun()
}

extension CommissioningExecutor: CommissioningAborting {}

/// Warum sich kein ausführbarer Lauf herstellen ließ.
///
/// **Trägt nie Bytes, nie einen Payload und nie das Geheimnis** —
/// dieselbe Regel wie im Audit.
///
/// ## Die Datenfreiheit hängt nicht an gutem Willen (SICK-032a1)
///
/// Es gibt genau **zwei** Fälle mit Nutzlast, und beide tragen
/// ausschließlich **unsere eigenen, ausdrücklich geprüften** Werte. Für
/// alles, was von außen kommt — ein fremder ``CommissioningRunProviding``,
/// ein fremder Opener, ein künftiger Transport —, gibt es
/// ``transportUnavailable`` **ohne jedes assoziierte Feld**.
///
/// Das ist der Kern der Korrektur: Vorher übernahm ein Fall die
/// Beschreibung eines beliebigen `Error`. Die realen Adapter erzeugen
/// heute kurze, datenfreie Texte — aber „der heutige Adapter formuliert
/// sparsam" ist keine Zusage. Ein Wert, den es nicht gibt, kann auch
/// nicht durchsickern; deshalb **keine neue Nutzlast ergänzen**, und
/// erst recht keinen `String` aus fremder Hand.
public enum CommissioningRunUnavailableReason: Error, Equatable, Sendable {
    /// Es wurde kein Port ausgewählt.
    case noPortSelected
    /// Der Pfad liegt außerhalb von `/dev/cu.` — dieselbe Grenze wie im
    /// Transport, hier nur früher beantwortet.
    ///
    /// **Die einzige Nutzlast ist der Pfad, den der Bedienende selbst
    /// ausgewählt hat** und der ohnehin dauerhaft in der
    /// ``CommissioningBriefing`` steht. Er stammt aus unserer eigenen,
    /// unmittelbar davor durchgeführten Prüfung, nicht aus einer fremden
    /// Fehlerbeschreibung.
    case pathNotAllowed(String)
    /// Der Port ließ sich nicht vorbereiten — **aus einem Grund, den
    /// diese Grenze bewusst nicht weitergibt**.
    ///
    /// Hierher fällt jeder nicht einzeln geprüfte Fehler: eine andere
    /// Ablehnung der Transportgrenze ebenso wie ein beliebiger Fehler
    /// eines fremden Laufanbieters. Es gibt **keinen** Text, keine
    /// Kennung und keinen Zahlenwert dazu; der Bedienhinweis ist ein
    /// fester Satz.
    case transportUnavailable
}

/// Stellt für einen ausgewählten Port einen ausführbaren Lauf her.
///
/// **Injizierbar, damit die Nachweise ohne Port und ohne Gerät laufen.**
/// Die einzige produktive Umsetzung ist ``SystemCommissioningRunFactory``;
/// sie ist zugleich die **einzige Stelle dieses Ziels, die einen echten
/// Transport erzeugt** — die Oberfläche tut das nie.
///
/// **Der Rückgabetyp garantiert Abbruchfähigkeit strukturell**
/// (SICK-0330a-1-K1, H4): Jeder hergestellte Lauf ist zwingend auch
/// ``CommissioningAborting``. Ein optionaler Cast auf diese Grenze kann
/// deshalb an der produktiven Bedienung gar nicht mehr fehlschlagen —
/// vorher hätte ein hypothetischer, nicht abbrechbarer Lauf den Cast
/// wirkungslos gemacht, während `performStep(_:)` trotzdem einen
/// gestarteten Abbruch gemeldet hätte.
public protocol CommissioningRunProviding {
    func makeRun(portPath: String) throws -> CommissioningRunning & CommissioningAborting
}
