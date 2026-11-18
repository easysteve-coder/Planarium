import SickPLSCore
import SickPLSControlCore

/// Der **vorzonale** Lernvorgang für eine neue Zone (SICK-032c3a,
/// `.agent_handoff/task-sick-032c3a.md`).
///
/// ## Warum es das gibt
///
/// Der bisherige Anlegeweg (`NewZoneDefaults`) erzeugte sofort eine
/// `Zone` mit erfundenen Grenzen `index 0,25...0,75`/`raw 1000...4000`
/// -- weit am tatsächlichen Arbeitsbereich vorbei (SICK-012:
/// `21...169`). Dieser Typ ersetzt das: Eine neue Zone existiert
/// zunächst **ohne** `Zone` -- nur als Rolle plus der bereits geprüfte
/// ``ZoneLearningAccumulator``-Lebenszyklus (SICK-030c/030c1). Eine
/// `Zone` entsteht erst, wenn ein echter Kandidat **ausdrücklich**
/// übernommen wird (siehe ``ZoneEditorState/applyLearnDraftCandidate()``).
///
/// ## Kein zweiter Lernvertrag
///
/// Dieser Typ **verändert nichts** an `ZoneLearningAccumulator`,
/// `ZoneLearningConfiguration`, `ZoneLearningState`, `ZoneLearningRefusal`,
/// `ZoneLearningCancellation` oder `ZoneLearningFailure` -- er bindet sie
/// nur an eine **Rolle statt an eine Zonen-ID**, weil vor der Übernahme
/// noch keine `EditableZone` existiert, an die sich binden ließe.
/// ``ZoneLearningSession`` (Lernen einer bereits vorhandenen,
/// ausgeschalteten Zone) bleibt unverändert und **unabhängig** neben
/// diesem Typ bestehen -- beide teilen sich denselben Accumulator, aber
/// keine gemeinsame Instanz.
///
/// ## Fokus
///
/// Jeder Entwurf trägt seinen eigenen ``LearnFocusState`` -- ein neuer
/// Entwurf (Anlegen, Neustart) bekommt damit automatisch einen frischen,
/// unverbrauchten Fokuszustand, ohne dass irgendeine Aufrufstelle daran
/// denken müsste, ihn eigens zurückzusetzen.
public struct LearnDraft: Equatable, Sendable {

    /// Die Rolle, die eine übernommene Zone bekäme -- beim Anlegen
    /// festgelegt, unveränderlich über die Lebensdauer des Entwurfs.
    public let role: ZoneRole

    public private(set) var accumulator: ZoneLearningAccumulator

    /// Ob die Ansicht den Ausschnitt für diesen Entwurf schon einmal
    /// automatisch fokussiert hat oder das nicht mehr darf.
    public private(set) var focus: LearnFocusState

    init(role: ZoneRole, configuration: ZoneLearningConfiguration) {
        self.role = role
        self.accumulator = ZoneLearningAccumulator(role: role, configuration: configuration)
        self.focus = .initial
    }

    public var state: ZoneLearningState { accumulator.state }
    public var isCollecting: Bool { accumulator.isCollecting }
    public var candidate: Zone? { accumulator.candidate }

    mutating func ingest(_ profile: B0ScanProfile) { accumulator.ingest(profile) }
    mutating func finish() { accumulator.finish() }
    mutating func cancel(_ reason: ZoneLearningCancellation) { accumulator.cancel(reason) }

    /// Reine Weiterleitung an den Fokuszustand -- siehe ``LearnFocusState``.
    @discardableResult
    mutating func applyFocusInput(_ input: LearnFocusState.Input) -> LearnFocusState.Decision {
        focus.apply(input)
    }
}

/// Warum ein Anlegeversuch abgelehnt wurde.
///
/// Anders als bei ``ZoneLearningArmOutcome``: Ein Entwurf braucht keine
/// bestehende Zone und kennt deshalb weder „unbekannte Zone" noch „Zone
/// eingeschaltet" -- **zwei** Gründe bleiben: der eigene, noch sammelnde
/// Vorgang, und ein sammelnder Vorgang an einer bereits vorhandenen Zone
/// (SICK-032c3a-K1).
public enum LearnDraftStartOutcome: Equatable, Sendable {
    case started
    /// Es läuft bereits ein Entwurf, der noch sammelt. Er bleibt
    /// **unangetastet** -- dasselbe Muster wie
    /// ``ZoneLearningArmOutcome/alreadyLearning(zoneID:)``. Ein bereits
    /// **beendeter** Entwurf (Vorschlag/Verweigerung/Abbruch/Fehlschlag)
    /// wird dagegen stillschweigend durch den neuen ersetzt -- genau das
    /// ist „neu starten".
    case alreadyDrafting
    /// Eine **bereits vorhandene** Zone sammelt gerade
    /// (``ZoneEditorState/armLearn(zoneID:configuration:)``). Höchstens
    /// **ein** Lernvorgang insgesamt läuft zur selben Zeit -- dasselbe
    /// Gegenstück wie ``ZoneLearningArmOutcome/blockedByLearnDraft``. Der
    /// laufende Vorgang bleibt **unangetastet**.
    case blockedByZoneLearning(zoneID: EditableZone.ID)
}

/// Warum das Übernehmen eines Entwurfskandidaten abgelehnt wurde.
public enum LearnDraftApplyOutcome: Equatable, Sendable {
    /// Geschrieben. Die neue, ausgewählte, weiterhin **ausgeschaltete**
    /// `EditableZone` trägt den Wert. Der Entwurf ist danach verbraucht
    /// (``ZoneEditorState/learnDraft`` wird `nil`) -- eine zweite
    /// Übernahme desselben Vorgangs erzeugt deshalb strukturell nichts
    /// mehr, siehe ``notDrafting``.
    case applied(EditableZone.ID, Zone)
    /// Es existiert kein Entwurf (nie angelegt, bereits verworfen, oder
    /// bereits erfolgreich übernommen).
    case notDrafting
    /// Der Entwurf hat (noch) keinen Kandidaten -- ``finish()`` wurde
    /// nicht gerufen, oder das Ergebnis ist eine Verweigerung, ein
    /// Abbruch oder ein Fehlschlag.
    case noCandidate(ZoneLearningState)
}
