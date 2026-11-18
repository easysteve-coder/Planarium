import SickPLSControlCore
import SickPLSMonitorKit
import PlanariumInput

/// Wie der **vorzonale** Lernentwurf für eine neue Zone benannt wird
/// (SICK-032c3a, `.agent_handoff/task-sick-032c3a.md` Abschnitt 4) --
/// die Integrationsgrenze, aus der SICK-032c3b die sichtbare Darstellung
/// zeichnet.
///
/// ## Bewusst eine Erweiterung, keine Kopie von ``ZoneLearningPresentation``
///
/// Schritt (``SickPLSPerformanceSession/ZoneLearningPhase``),
/// Verweigerungs-/Fehlschlagstexte
/// (``SickPLSControlCore/ZoneLearningRefusal/operatorText``,
/// ``SickPLSControlCore/ZoneLearningFailure/operatorText``), die
/// Grenzendarstellung (``ZoneBoundsText``) und die lesbare
/// Parametererklärung (``SickPLSControlCore/ZoneLearningConfiguration/explanations``)
/// sind unverändert dieselben wie beim Lernen einer bereits vorhandenen
/// Zone -- sie hängen nicht an einer Zonen-ID. **Neu ist ausschließlich**,
/// was ein Entwurf zusätzlich braucht: eine eigene Abbruchformulierung
/// (ein Entwurf hat keine „Zone [die] unverändert" bleibt -- es gibt
/// noch gar keine), einen **anderen** Sperrgrund (Auflage **D2**
/// -- „Zone eingeschaltet" -- betrifft nur eine bereits vorhandene Zone;
/// seit SICK-032c3a-K1 kann aber eine sammelnde, bereits vorhandene Zone
/// einen (Neu-)Start hier sperren) und den relevanten Bereich
/// (``SickPLSMonitorKit/ScanFieldFocusArea``).
public struct LearnDraftPresentation: Equatable, Sendable {
    /// Die Rolle, die eine übernommene Zone bekäme.
    public let role: ZoneRole
    public let phase: ZoneLearningPhase
    public let configuration: ZoneLearningConfiguration
    /// Warum ein (Neu-)Start jetzt nicht ginge, oder `nil`
    /// (SICK-032c3a-K1). Ein bereits **beendeter** Entwurf (Vorschlag/
    /// Verweigerung/Abbruch/Fehlschlag) zeigt sein Ergebnis unabhängig
    /// davon weiter -- ein gesperrter Neustart löscht keine sichtbare
    /// Begründung (dieselbe Haltung wie bei ``ZoneLearningPresentation/block``).
    public let block: LearnDraftBlock?
    /// Der relevante Bereich für die aktuelle Messung (und, sobald
    /// vorhanden, den Kandidaten) -- `nil` ohne echtes Profil oder ohne
    /// brauchbaren Messwert. **Reine Anzeige:** Wird hier nie in Profil,
    /// Kandidat, Zone oder Fachwerte zurückgeschrieben.
    public let focusArea: ScanFieldFocusArea.Outcome?

    /// Leitet die Anzeige aus dem **echten** Entwurfszustand ab.
    public init(
        role: ZoneRole,
        state: ZoneLearningState,
        configuration: ZoneLearningConfiguration = .default,
        block: LearnDraftBlock? = nil,
        focusArea: ScanFieldFocusArea.Outcome?
    ) {
        self.role = role
        self.phase = ZoneLearningPhase(state: state)
        self.configuration = configuration
        self.block = block
        self.focusArea = focusArea
    }

    // MARK: - Überschrift und Anleitung

    public static let sectionTitle = "Learn new zone"

    /// Der Schritt, in dem der Entwurf steht -- in Alltagssprache.
    ///
    /// `switch` ohne `default`: Ein neuer Schritt muss sich hier
    /// entscheiden. ``ZoneLearningPhase/idle`` erscheint hier
    /// strukturell nie (dieser Typ existiert nur, solange ein Entwurf
    /// wirklich läuft), bleibt aber Teil des `switch`, weil
    /// ``ZoneLearningPhase`` selbst dafür keinen zweiten Typ anbietet.
    public var stepTitle: String {
        switch phase {
        case .idle: return "Ready"
        case .waitingForProfiles, .collectingBaseline: return "Keep scan field clear briefly"
        case .collectingMovement: return "Move hand through desired area"
        case .candidate: return "Suggestion"
        case .refused: return "No safe area"
        case .cancelled: return "Cancelled"
        case .failed: return "Measurements don't match"
        }
    }

    public var instruction: String {
        switch phase {
        case .idle:
            return "A click starts learning: first keep the scan field clear briefly, then move "
                + "your hand through the area you want to control."
        case .waitingForProfiles, .collectingBaseline:
            return "The background is being recorded. Please don't reach into the scan field yet."
        case .collectingMovement:
            return "Slowly move your hand through the desired area. Then \""
                + Self.finishTitle + "\"."
        case .candidate:
            return "The suggestion hasn't been applied yet. \"" + Self.applyTitle
                + "\" creates the new, deactivated zone from it, \"" + Self.discardTitle
                + "\" rejects it."
        case .refused(let refusal):
            return refusal.operatorText
        case .cancelled(let reason):
            return Self.draftCancellationText(reason)
        case .failed(let failure):
            return failure.operatorText
        }
    }

    /// **Dieselbe** Abbruchtextübersetzung wie
    /// ``SickPLSControlCore/ZoneLearningCancellation/operatorText``, bis
    /// auf die beiden Gründe, die für einen Entwurf tatsächlich
    /// entstehen können (``startZoneLearning()``-Gegenstück: Abbruch und
    /// Verbindungsverlust) -- diese formulieren nicht von einer bereits
    /// vorhandenen Zone. Die drei übrigen Gründe (entfernt/Rolle
    /// geändert/ein- oder ausgeschaltet) gehören zum Lernen einer
    /// bereits vorhandenen Zone und entstehen für einen Entwurf
    /// strukturell nie -- der `switch` bleibt trotzdem erschöpfend und
    /// fällt für sie auf den geteilten Text zurück.
    private static func draftCancellationText(_ reason: ZoneLearningCancellation) -> String {
        switch reason {
        case .operatorCancelled:
            return "The draft was cancelled. No zone was created."
        case .disconnected:
            return "The scanner connection ended. Without real measurements, learning cannot continue."
        case .zoneRemoved, .zoneRoleChanged, .zoneActivationChanged:
            return reason.operatorText
        }
    }

    public var progressLabel: String? {
        switch phase {
        case .waitingForProfiles:
            return "Waiting for measurements"
        case .collectingBaseline(let seen, let required):
            return "Baseline profile \(seen) of \(required)"
        case .collectingMovement(let seen, let changed, let persistent):
            return "\(seen) profiles · \(changed) measurement points changed · \(persistent) stable"
        case .idle, .candidate, .refused, .cancelled, .failed:
            return nil
        }
    }

    /// Die vier Grenzen des Vorschlags, oder `nil` -- dieselbe
    /// Darstellung wie im Insert und in ``ZoneLearningPresentation``.
    public var candidateBoundsLabel: String? {
        phase.candidateZone.map { ZoneBoundsText.label(for: $0) }
    }

    /// Der relevante Rohwertbereich, knapp dargestellt, oder `nil` ohne
    /// echtes Profil oder ohne brauchbaren Messwert.
    public var focusAreaLabel: String? {
        guard case .focused(let result) = focusArea else { return nil }
        return "Value \(result.valueRange.lowerBound)–\(result.valueRange.upperBound)"
    }

    /// Der Sperrgrund als Satz, oder `nil` -- dieselbe Darstellung wie
    /// ``ZoneLearningPresentation/blockMessage``.
    public var blockMessage: String? { block?.message }

    // MARK: - Was gerade möglich ist

    public static let startTitle = "Learn new zone"
    public static let finishTitle = "Finish collecting"
    public static let cancelTitle = "Cancel"
    public static let applyTitle = "Apply"
    public static let discardTitle = "Discard"

    /// Ein neuer Entwurf lässt sich starten, solange nicht gerade
    /// gesammelt wird -- **kein Sperrgrund wie „Zone eingeschaltet" bei
    /// ``ZoneLearningPresentation/canStart``**: Ein Entwurf hat keine
    /// bereits vorhandene Zone, die eingeschaltet sein könnte (Auflage
    /// **D2** betrifft nur diesen Fall). Seit SICK-032c3a-K1 gibt es aber
    /// ``block``: Solange eine bereits vorhandene Zone sammelt, lehnt
    /// ``SickPLSMonitorKit/ZoneEditorState/startLearnDraft(role:configuration:)``
    /// einen (Neu-)Start ab, und ``canStart`` spiegelt das.
    public var canStart: Bool { !phase.isCollecting && block == nil }
    public var canFinish: Bool { phase.isCollecting }
    public var canCancel: Bool { phase.isCollecting }
    /// Übernehmen setzt nur einen Vorschlag voraus -- ohne Zone gibt es
    /// keine zusätzliche Ein/Aus-Bedingung.
    public var canApply: Bool { phase.candidateZone != nil }
    public var canDiscard: Bool { phase.hasResult }

    public var explanations: [ZoneLearningExplanation] { configuration.explanations }
}

/// Warum ein (Neu-)Start des Entwurfs jetzt nicht ginge (SICK-032c3a-K1).
///
/// Nur **ein** Grund -- anders als bei ``ZoneLearningBlock``: Ein Entwurf
/// hat keine bereits vorhandene Zone, die eingeschaltet sein könnte
/// (Auflage **D2** betrifft nur ``ZoneLearningPresentation``), und er
/// blockiert sich nicht selbst -- solange er noch sammelt, zeigt
/// ``LearnDraftPresentation/canStart`` das bereits über `phase.isCollecting`.
public enum LearnDraftBlock: Equatable, Sendable {
    /// Eine **bereits vorhandene** Zone sammelt gerade
    /// (``SickPLSMonitorKit/ZoneEditorState/armLearn(zoneID:configuration:)``).
    /// Höchstens ein Lernvorgang insgesamt läuft zur selben Zeit --
    /// dasselbe Gegenstück wie ``ZoneLearningBlock/learnDraftIsCollecting``.
    case zoneLearningIsCollecting(zoneID: EditableZone.ID)

    public var message: String {
        switch self {
        case .zoneLearningIsCollecting:
            return "A learning process is running on a zone. Finish or cancel it first."
        }
    }
}

// MARK: - Rückmeldungen zu einem Bedienschritt (SICK-032c3b)
//
// Dasselbe Muster wie ``ZoneLearningArmOutcome/notice``/
// ``ZoneLearningApplyOutcome/notice`` weiter unten in dieser Datei --
// reine Textzuordnung, keine neue Modellentscheidung. Der Koordinator
// veröffentlicht das Ergebnis über ein **eigenes** Feld
// (``PlanariumScannerUI/ScannerWorkspaceModel/learnDraftNotice``),
// damit es nie mit der Rückmeldung des Lernens einer bereits vorhandenen
// Zone zusammenläuft -- beide Karten können gleichzeitig sichtbar sein.

extension LearnDraftStartOutcome {
    /// Jeder Ausgang eines (Neu-)Startversuchs hat **seinen eigenen** Satz.
    public var notice: ZoneLearningNotice {
        switch self {
        case .started:
            return ZoneLearningNotice(
                "Learning draft started — keep the scan field clear briefly.", isSuccess: true
            )
        case .alreadyDrafting:
            return ZoneLearningNotice(
                "A learning draft is already running. Finish, apply, or cancel it first.",
                isSuccess: false
            )
        case .blockedByZoneLearning(let zoneID):
            return ZoneLearningNotice(
                LearnDraftBlock.zoneLearningIsCollecting(zoneID: zoneID).message, isSuccess: false
            )
        }
    }
}

extension LearnDraftApplyOutcome {
    /// Jeder Ausgang einer Übernahme hat **seinen eigenen** Satz.
    ///
    /// Der Erfolgssatz sagt ausdrücklich, was **nicht** passiert ist --
    /// dieselbe Formulierung wie ``ZoneLearningApplyOutcome/notice``:
    /// Die neue Zone bleibt ausgeschaltet und bekommt keinen Spiel-Slot.
    public var notice: ZoneLearningNotice {
        switch self {
        case .applied:
            return ZoneLearningNotice(
                "Zone created — selected and still deactivated. It only plays after being "
                    + "activated.",
                isSuccess: true
            )
        case .notDrafting:
            return ZoneLearningNotice(
                "No learning draft is running that could be applied.", isSuccess: false
            )
        case .noCandidate:
            return ZoneLearningNotice(
                "There's no suggestion to apply yet. Finish collecting first.",
                isSuccess: false
            )
        }
    }
}
