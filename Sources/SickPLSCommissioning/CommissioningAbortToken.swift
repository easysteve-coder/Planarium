import os

/// Eine atomar an genau eine Laufkante gebundene Kennung
/// (SICK-0330a-1-K2).
///
/// Trägt ausschließlich eine interne Generationennummer — von außen
/// vergleichbar (``Equatable``), aber nicht konstruierbar und nicht
/// interpretierbar. Eine Kante wird ausschließlich über
/// ``CommissioningAbortToken/beginRunIfNeeded()`` gewonnen und über
/// ``CommissioningAbortToken/endRun(_:)`` wieder geschlossen.
public struct CommissioningRunEdge: Equatable, Sendable {
    fileprivate let generation: UInt64
}

/// Ein von außen setzbares, threadsicheres Abbruchsignal für einen
/// laufenden ``CommissioningExecutor/perform(_:secret:)`` (SICK-0330a-1),
/// mit einer **atomar an eine einzelne Laufkante gebundenen**
/// Lebensdauer (SICK-0330a-1-K2).
///
/// ## Warum es diesen Typ gibt
///
/// `perform` ist synchron und blockierend; ein zweiter
/// `perform(.abort)` reiht sich hinter dem laufenden Aufruf auf
/// derselben seriellen Warteschlange ein und erreicht ihn nie. Dieses
/// Signal ist der Gegenentwurf: **kein zweiter `perform`-Aufruf**,
/// sondern eine einfache, gesperrte Marke, die ein beliebiger anderer
/// Ausführungskontext jederzeit setzen kann, während `perform` noch in
/// einer Restfrist liest.
///
/// ## Die atomare Laufkante (SICK-0330a-1-K2)
///
/// Eine frühere Fassung löschte eine anstehende Anforderung einmalig bei
/// der späteren Main-Thread-Berichtszustellung
/// (`discardStaleRequest()`). Das deckte nicht jede mögliche
/// Thread-Reihenfolge ab: Eine Anforderung, die **nach** dieser
/// Zustellung, aber **vor** dem nächsten `perform`-Aufruf eintraf, blieb
/// stehen und vergiftete den nächsten, gänzlich anderen Lauf.
///
/// Die Lösung ist eine monoton wachsende **Generation**. Jede Laufkante
/// trägt genau eine Generationennummer:
///
/// - ``beginRunIfNeeded()`` **reserviert** synchron eine Laufkante — für
///   den externen Aufrufer (``CommissioningExecutor/beginRun()``,
///   **vor** dem Einplanen des Hintergrundaufrufs) ebenso wie für
///   `perform` selbst (das dieselbe, bereits reservierte Kante
///   **wiederverwendet**, statt sie ein zweites Mal zu vergeben — eine
///   während der Lücke dazwischen eingegangene Anforderung geht dadurch
///   nicht verloren).
/// - ``endRun(_:)`` **schließt** eine Laufkante atomar genau dort, wo
///   der zugehörige `perform`-Aufruf tatsächlich zurückkehrt — **nicht**
///   erst bei einer späteren Main-Thread-Zustellung. Von diesem Moment
///   an ist keine Laufkante mehr reserviert, bis der nächste Aufruf eine
///   neue, **frische** Generation reserviert.
/// - ``requestAbort()`` betrifft **ausschließlich** die gerade
///   reservierte Generation. Trifft sie ein, während **keine** Laufkante
///   reserviert ist (also in der Lücke zwischen zwei Läufen), ist sie
///   **wirkungslos** — sie kann sich an keine künftige Generation mehr
///   heften, weil die nächste erst mit ``beginRunIfNeeded()`` entsteht,
///   **nachdem** sie schon verpufft ist.
///
/// **Eine frisch erzeugte Instanz beginnt mit „keiner reservierten
/// Kante" — genau wie jede spätere Lücke zwischen zwei Läufen**
/// (SICK-0330a-1-K3). Eine frühere Fassung reservierte von sich aus
/// bereits die Generation `0`, um einen älteren Nachweis zu erfüllen,
/// der ``requestAbort()`` **vor** dem allerersten `perform`-Aufruf rief
/// und erwartete, dass genau dieser erste Aufruf ihn beobachtet. Das war
/// selbst der Fehler: Es entstand eine **Phantomkante**, die noch vor
/// jeder Reservierung existierte — ein beliebig früher `requestAbort()`
/// im echten Leerlauf (nicht zwischen Einplanung und Start) wurde
/// dadurch gespeichert und hätte den ersten tatsächlichen Lauf beendet,
/// obwohl weder ``beginRun()`` noch `perform()` je aufgerufen wurde.
///
/// Der **eigentlich gemeinte** Vor-Start-Fall — eine Anforderung
/// zwischen dem Einplanen und dem tatsächlichen Start von `perform` —
/// verlangt immer einen vorausgehenden ``beginRunIfNeeded()``-Aufruf
/// (extern über ``CommissioningExecutor/beginRun()``, oder implizit
/// durch einen direkten `perform`-Aufruf, der ihn an seinem eigenen
/// Anfang selbst ausführt). Ohne eine solche Reservierung ist
/// ``requestAbort()`` **wirkungslos** — es gibt keine „künftige"
/// Generation, an die sich eine Anforderung heften könnte, weil jede
/// Generation ausschließlich durch ``beginRunIfNeeded()`` selbst
/// entsteht.
///
/// ## Threadvertrag
///
/// Jedes Mitglied ist von jedem Thread aus sicher aufrufbar, beliebig
/// oft. Es gibt keine Warteschlange und keinen Rückruf — nur eine unter
/// **derselben** Sperre gelesene, gesetzte oder verglichene Marke.
///
/// ## Warum `import os` statt Foundation oder Dispatch
///
/// Dieses Ziel ist frameworkfrei (``CommissioningBoundaryTests``,
/// bewusst ohne `Foundation`/`Dispatch`). Ein ungesperrtes `Bool` wäre
/// unter Swifts Speichermodell aber ein echter Data Race, keine
/// Abkürzung — `Mutex`/`Atomic` aus `Synchronization` verlangen
/// mindestens macOS 15 und scheiden damit auf der macOS-12-Grundlage
/// aus. `os_unfair_lock` ist kein Framework, sondern derselbe minimale
/// System-Baustein, mit dem `SickPLSMacTransport`/`SickPLSActiveControl`
/// bereits reale Nebenläufigkeit lösen (`termios`/`poll` über `Darwin`).
public final class CommissioningAbortToken: @unchecked Sendable {
    private var lock = os_unfair_lock_s()

    /// Monoton wachsender Zähler — die zuletzt vergebene Generation.
    private var generation: UInt64 = 0

    /// Die aktuell reservierte Laufkante, oder `nil` in der Lücke
    /// zwischen zwei Läufen — **und, seit SICK-0330a-1-K3, auch vor dem
    /// allerersten Lauf**: Eine frische Instanz reserviert nichts von
    /// sich aus. Siehe Typkommentar.
    private var activeGeneration: UInt64?

    /// Die Generation, für die ein Abbruch angefordert wurde — oder
    /// `nil`, wenn keiner aussteht.
    private var abortedGeneration: UInt64?

    public init() {}

    /// Fordert einen Abbruch der **aktuell reservierten** Laufkante an.
    /// Beliebig oft aufrufbar, von jedem Thread; eine bereits stehende
    /// Anforderung bleibt unverändert.
    ///
    /// **Ist gerade keine Laufkante reserviert** (die Lücke zwischen zwei
    /// tatsächlich beendeten Läufen), ist dieser Aufruf **wirkungslos**
    /// — er heftet sich an keine künftige Generation.
    public func requestAbort() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let active = activeGeneration else { return }
        abortedGeneration = active
    }

    /// Ob für die aktuell reservierte Laufkante gerade eine Anforderung
    /// ansteht. **Ändert nichts** — reine Beobachtung für Diagnose und
    /// Tests; der produktive Weg ist ``consumeIfRequested(for:)``.
    public var isAbortRequested: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let active = activeGeneration else { return false }
        return abortedGeneration == active
    }

    /// Reserviert synchron eine Laufkante — **wiederverwendet** eine
    /// bereits bestehende Reservierung unverändert (inklusive einer
    /// währenddessen eingegangenen Anforderung), statt sie zu ersetzen,
    /// oder reserviert eine **frische**, falls gerade keine besteht.
    ///
    /// Wird sowohl extern aufgerufen (``CommissioningExecutor/beginRun()``,
    /// synchron vor dem Einplanen des Hintergrundaufrufs) als auch intern
    /// von `perform` selbst, an dessen eigenem Beginn — beide Aufrufer
    /// erhalten für ein und denselben Lauf dieselbe Generation.
    @discardableResult
    public func beginRunIfNeeded() -> CommissioningRunEdge {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let active = activeGeneration {
            return CommissioningRunEdge(generation: active)
        }
        generation += 1
        activeGeneration = generation
        abortedGeneration = nil
        return CommissioningRunEdge(generation: generation)
    }

    /// Schließt eine Laufkante **atomar** — vom Aufrufer unmittelbar dort
    /// gerufen, wo der zugehörige `perform`-Aufruf tatsächlich
    /// zurückkehrt, nie erst bei einer späteren Main-Thread-Zustellung.
    ///
    /// Löst die Reservierung und eine dafür noch anstehende Anforderung
    /// **im selben gesperrten Schritt**: Eine Anforderung, die unmittelbar
    /// danach eintrifft, sieht bereits keine reservierte Laufkante mehr
    /// und verpufft wirkungslos (``requestAbort()``); eine Anforderung,
    /// die unmittelbar davor eintraf, wird hier mit gelöscht, egal ob sie
    /// zuvor schon beobachtet (``consumeIfRequested(for:)``) wurde oder
    /// nicht.
    ///
    /// Eine bereits veraltete oder fremde Kante (`edge.generation`
    /// entspricht nicht der aktuell reservierten) ändert nichts.
    public func endRun(_ edge: CommissioningRunEdge) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard activeGeneration == edge.generation else { return }
        activeGeneration = nil
        if abortedGeneration == edge.generation {
            abortedGeneration = nil
        }
    }

    /// Liest, ob für **genau diese** Laufkante ein Abbruch angefordert
    /// wurde, und löscht die Anforderung im selben Schritt — damit kein
    /// zweiter Beobachter sie ein zweites Mal sieht.
    ///
    /// `edge` ist optional, damit ein Aufrufer ohne (noch) gesetzte Kante
    /// (strukturell nicht erreichbar über die produktiven Aufrufer dieses
    /// Ziels, aber defensiv sicher) einfach `false` bekommt, statt
    /// abzustürzen.
    @discardableResult
    public func consumeIfRequested(for edge: CommissioningRunEdge?) -> Bool {
        guard let edge else { return false }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard activeGeneration == edge.generation, abortedGeneration == edge.generation else {
            return false
        }
        abortedGeneration = nil
        return true
    }
}
