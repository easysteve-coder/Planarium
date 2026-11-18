import SickPLSControlCore
import SickPLSMonitorKit
import PlanariumInput

/// Wie der Lernvorgang einer Zone **benannt** wird — die Texte des
/// Bereichs „Bereich mit Hand lernen" in der Einstellkarte (SICK-032c2).
///
/// ## Was dieser Typ ist — und was nicht
///
/// Eine **reine Darstellung** des bereits vorhandenen, geprüften
/// Lernvertrags aus SICK-030c/030c1. Hier entsteht **keine neue
/// Heuristik**: kein eigener Profilzähler, kein eigener Fortschritt, kein
/// zweiter Profileingang, keine Uhr und kein Timeout. Jede Zahl, die hier
/// erscheint, kommt unverändert aus ``SickPLSControlCore/ZoneLearningState``
/// beziehungsweise aus ``SickPLSControlCore/ZoneLearningConfiguration``.
///
/// ## Warum die Texte hier stehen und nicht in der Ansicht
///
/// Dieselbe Regel wie bei `PerformanceNotice` (SICK-028),
/// `PortAccessNotice` (SICK-030a1) und ``ZoneInsertStatus`` (SICK-032c1):
/// Ein `switch`, der erst in einer SwiftUI-Datei entsteht, hat kein
/// Testziel. Genau hier ist das aber die tragende Aussage — „verweigert",
/// „abgebrochen" und „fehlgeschlagen" sind drei verschiedene Lagen mit
/// drei verschiedenen Handgriffen, und niemand darf bloß „Fehler" lesen.

// MARK: - Die Schrittanzeige

/// In welchem Schritt der Lernvorgang **dieser** Zone gerade steht.
///
/// Eine eins-zu-eins-Übersetzung von ``SickPLSControlCore/ZoneLearningState``
/// plus dem Fall ``idle`` für „für diese Zone läuft gerade keiner".
/// Bewusst ein eigener Typ: Die Oberfläche unterscheidet „armiert, aber
/// noch kein Messwert" (`arming`) sichtbar von „Grundprofil läuft" — der
/// Lernvertrag fasst beides nicht zusammen, und die Bedienung darf es
/// auch nicht.
public enum ZoneLearningPhase: Equatable, Sendable {
    /// Für diese Zone läuft und lief kein Vorgang (oder er wurde
    /// verworfen).
    case idle
    /// Armiert, es ist aber noch **kein einziges** echtes Profil
    /// eingetroffen. Genau hier steht ehrlich „Warte auf Messwerte" —
    /// es gibt nichts, woraus sich ein Fortschritt ableiten ließe.
    case waitingForProfiles
    case collectingBaseline(profilesSeen: Int, required: Int)
    case collectingMovement(profilesSeen: Int, changedIndexCount: Int, persistentIndexCount: Int)
    /// Ein geprüfter Vorschlag liegt vor — **noch nirgends geschrieben**.
    case candidate(Zone)
    case refused(ZoneLearningRefusal)
    case cancelled(ZoneLearningCancellation)
    case failed(ZoneLearningFailure)

    /// Übersetzt den Zustand des Lernvertrags. `switch` ohne `default`:
    /// Ein neuer Zustand dort muss sich hier entscheiden.
    public init(state: ZoneLearningState) {
        switch state {
        case .arming:
            self = .waitingForProfiles
        case .collectingBaseline(let seen, let required):
            self = .collectingBaseline(profilesSeen: seen, required: required)
        case .collectingMovement(let seen, let changed, let persistent):
            self = .collectingMovement(
                profilesSeen: seen, changedIndexCount: changed, persistentIndexCount: persistent
            )
        case .candidate(let zone):
            self = .candidate(zone)
        case .refused(let refusal):
            self = .refused(refusal)
        case .cancelled(let reason):
            self = .cancelled(reason)
        case .failed(let failure):
            self = .failed(failure)
        }
    }

    /// Ob noch echte Profile angenommen werden.
    public var isCollecting: Bool {
        switch self {
        case .waitingForProfiles, .collectingBaseline, .collectingMovement:
            return true
        case .idle, .candidate, .refused, .cancelled, .failed:
            return false
        }
    }

    /// Ob ein **beendeter** Vorgang dieser Zone noch ein Ergebnis zeigt,
    /// das sich wegräumen lässt.
    public var hasResult: Bool {
        switch self {
        case .candidate, .refused, .cancelled, .failed:
            return true
        case .idle, .waitingForProfiles, .collectingBaseline, .collectingMovement:
            return false
        }
    }

    /// Der Vorschlag, falls einer vorliegt.
    public var candidateZone: Zone? {
        if case .candidate(let zone) = self { return zone }
        return nil
    }
}

// MARK: - Warum der Start gesperrt ist

/// Warum ein Lernvorgang **jetzt** nicht begonnen werden kann.
///
/// Getrennte Fälle statt eines gesperrten Knopfes ohne Begründung: Beide
/// verlangen einen anderen Handgriff, und beide sind vom Bedienenden in
/// einem Schritt auflösbar.
public enum ZoneLearningBlock: Equatable, Sendable {
    /// Die Zone ist eingeschaltet. **Auflage D2** — auf einer
    /// eingeschalteten Zone klänge die Lernbewegung mit.
    case zoneIsEnabled
    /// An einer **anderen** Zone läuft gerade ein Vorgang. Es gibt
    /// höchstens einen; zwei teilten sich denselben Profilstrom.
    case otherZoneIsLearning
    /// Ein **vorzonaler** Entwurf für eine neue Zone sammelt gerade
    /// (SICK-032c3a-K1) — dieselbe projektweite Exklusivität wie
    /// ``otherZoneIsLearning``, nur mit dem jeweils anderen Pfad als
    /// Ursache.
    case learnDraftIsCollecting

    public var message: String {
        switch self {
        case .zoneIsEnabled:
            return "Disable this zone before learning."
        case .otherZoneIsLearning:
            return "A learning session is running on another zone. Finish or cancel it first."
        case .learnDraftIsCollecting:
            return "A new zone is being learned. Finish, apply, or discard that draft first."
        }
    }
}

// MARK: - Die Texte der drei Endlagen

extension ZoneLearningRefusal {
    /// Warum **kein** Vorschlag entsteht, obwohl der Vorgang sauber
    /// gelaufen ist — und was der Bedienende anders machen kann.
    ///
    /// Eine Verweigerung ist ein **Ergebnis**, kein Fehler: Es wurde
    /// gerechnet und festgestellt, dass die Zone nicht sicher wäre.
    public var operatorText: String {
        switch self {
        case .baselineIncomplete(let seen, let required):
            return "The background was not yet complete (\(seen) of \(required) baseline profiles). "
                + "Keep the scan field clear until the baseline is captured."
        case .insufficientMotion(let largest, let required):
            return "Not enough coherent motion was detected (\(largest) of \(required) points). "
                + "Move your hand more slowly and deliberately through the desired area."
        case .ambiguousCandidates(let strongest, let runnerUp):
            return "Two areas were nearly tied (\(strongest) and \(runnerUp) hits). "
                + "Move only one area and keep everything else still."
        case .backgroundInsideZone:
            return "The background falls within the value range the zone would need. "
                + "Your hand must be closer to the scanner than anything behind it — "
                + "otherwise the zone would stay active even without a hand."
        case .candidateNotBuildable:
            return "No valid area could be formed from the collected values. "
                + "Please repeat the process."
        }
    }
}

extension ZoneLearningCancellation {
    /// Warum der Vorgang **von außen** endete. Die Zone ist in jedem
    /// dieser Fälle unverändert.
    public var operatorText: String {
        switch self {
        case .operatorCancelled:
            return "The learning session was cancelled. The zone is unchanged."
        case .zoneRemoved:
            return "The zone was removed — the learning session has ended."
        case .zoneRoleChanged:
            return "The role of this zone has changed. An area learned for the old role "
                + "no longer fits; please re-learn."
        case .zoneActivationChanged:
            return "The zone was turned on or off. Learning only works on a disabled "
                + "zone; please restart."
        case .disconnected:
            return "The scanner connection ended. Without real measurements, learning cannot continue."
        }
    }
}

extension ZoneLearningFailure {
    /// Warum die **Eingangsdaten** nicht mehr zum Vorgang passten.
    public var operatorText: String {
        switch self {
        case .pointCountChanged(let expected, let received):
            return "The scanner now delivers \(received) measurement points instead of \(expected). "
                + "Points from two measurement types don't mean the same thing — re-learn after the change."
        case .emptyProfile:
            return "A profile arrived with no measurement points at all. Please check the connection and restart."
        }
    }
}

// MARK: - Rückmeldung zu einem Bedienschritt

/// Die Rückmeldung zu **genau einem** Lern-Bedienschritt.
///
/// Sie verschwindet nur dadurch, dass an derselben Stelle der nächste
/// Schritt gemacht wird — nie durch Zeitablauf (dieselbe Regel wie
/// `PerformanceNotice` seit SICK-028).
public struct ZoneLearningNotice: Equatable, Sendable {
    public let message: String
    /// Ob der Schritt gewirkt hat. Trennt „gestartet" von „abgelehnt",
    /// ohne dass die Ansicht den Text lesen müsste.
    public let isSuccess: Bool

    public init(_ message: String, isSuccess: Bool) {
        self.message = message
        self.isSuccess = isSuccess
    }
}

extension ZoneLearningArmOutcome {
    /// Jeder Ausgang eines Armierversuchs hat **seinen eigenen** Satz.
    public var notice: ZoneLearningNotice {
        switch self {
        case .armed:
            return ZoneLearningNotice(
                "Learning started — keep the scan field clear for a moment.", isSuccess: true
            )
        case .unknownZone:
            return ZoneLearningNotice(
                "This zone no longer exists. Please select a zone.", isSuccess: false
            )
        case .zoneIsEnabled:
            return ZoneLearningNotice(ZoneLearningBlock.zoneIsEnabled.message, isSuccess: false)
        case .alreadyLearning:
            return ZoneLearningNotice(
                ZoneLearningBlock.otherZoneIsLearning.message, isSuccess: false
            )
        case .blockedByLearnDraft:
            return ZoneLearningNotice(
                ZoneLearningBlock.learnDraftIsCollecting.message, isSuccess: false
            )
        }
    }
}

extension ZoneLearningApplyOutcome {
    /// Jeder Ausgang einer Übernahme hat **seinen eigenen** Satz.
    ///
    /// Der Erfolgssatz sagt ausdrücklich, was **nicht** passiert ist: Die
    /// Zone bleibt ausgeschaltet (Auflage **D2**) und bekommt keinen
    /// Spiel-Slot — Einschalten und Zuweisen sind eigene Handgriffe.
    public var notice: ZoneLearningNotice {
        switch self {
        case .applied:
            return ZoneLearningNotice(
                "Area applied. The zone stays disabled — it only plays after being "
                    + "enabled.",
                isSuccess: true
            )
        case .notLearning:
            return ZoneLearningNotice(
                "There is no learning result to apply.", isSuccess: false
            )
        case .noCandidate:
            return ZoneLearningNotice(
                "There is no suggestion to apply. Finish collecting first.",
                isSuccess: false
            )
        case .targetZoneMissing:
            return ZoneLearningNotice(
                "The learned zone no longer exists — the suggestion was not applied.",
                isSuccess: false
            )
        case .targetZoneIsEnabled:
            return ZoneLearningNotice(
                "The zone has been enabled in the meantime. Disable it first before applying — otherwise "
                    + "the bounds of a playing zone would change.",
                isSuccess: false
            )
        case .targetZoneRoleChanged(let expected, let actual):
            return ZoneLearningNotice(
                "The role changed from \(ZoneRoleNaming.name(of: expected)) to "
                    + "\(ZoneRoleNaming.name(of: actual)). The suggestion no longer fits; "
                    + "please re-learn.",
                isSuccess: false
            )
        }
    }
}

// MARK: - Die Lernparameter als lesbare Erklärung

/// Eine Zeile der lesbaren Erklärung der Lernparameter.
///
/// **Nur lesbar.** Es entstehen hier keine neuen einstellbaren Vorgaben;
/// die Werte kommen unverändert aus der bestehenden
/// ``SickPLSControlCore/ZoneLearningConfiguration``. Sie stehen in der
/// Karte, damit ein späterer **realer** Fehlschlag deutbar ist, ohne dass
/// jemand Rohdaten ansehen müsste.
public struct ZoneLearningExplanation: Equatable, Sendable, Identifiable {
    /// Stabiler Schlüssel für Listen — kein Index, damit ein Umsortieren
    /// nichts verwechselt.
    public let id: String
    public let title: String
    public let value: String
    public let detail: String

    public init(id: String, title: String, value: String, detail: String) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
    }
}

/// Ein- und Mehrzahl der beiden Einheiten, die in der Erklärung
/// vorkommen.
///
/// Klein, aber nötig: Die Vorgabe `indexPaddingPoints` ist **1**, und
/// „1 Messpunkte je Seite" las sich wie ein Anzeigefehler — beim
/// Bildnachweis real aufgefallen.
enum LearningUnitText {
    static func points(_ count: Int) -> String {
        count == 1 ? "1 measurement point" : "\(count) measurement points"
    }

    static func profiles(_ count: Int) -> String {
        count == 1 ? "1 profile" : "\(count) profiles"
    }
}

extension ZoneLearningConfiguration {
    /// Die vollständige, lesbare Erklärung aller Lernparameter.
    ///
    /// **Keine erfundene physikalische Einheit:** Der Scanner liefert
    /// Rohwerte, deren Umrechnung in Millimeter nirgends belegt ist
    /// (SICK-013) — hier stehen deshalb „Rohwerte", „Messpunkte" und
    /// „Profile" und sonst nichts.
    public var explanations: [ZoneLearningExplanation] {
        [
            ZoneLearningExplanation(
                id: "baseline",
                title: "Baseline profiles",
                value: LearningUnitText.profiles(baselineProfileCount),
                detail: "This many quiet measurements form the background. Keep the "
                    + "scan field clear during this time."
            ),
            ZoneLearningExplanation(
                id: "persistence",
                title: "Repeated motion",
                value: minimumPersistenceProfiles == 1
                    ? "from 1 profile per measurement point"
                    : "from \(minimumPersistenceProfiles) profiles per measurement point",
                detail: "A measurement point only counts once it has changed in this many profiles. "
                    + "A single outlier is not enough."
            ),
            ZoneLearningExplanation(
                id: "cluster",
                title: "Minimum area size",
                value: LearningUnitText.points(minimumClusterPoints) + ", gap up to \(maximumIndexGap)",
                detail: "The motion must cover this many adjacent measurement points. Individual "
                    + "misreadings in between won't break the area."
            ),
            ZoneLearningExplanation(
                id: "movement",
                title: "Motion threshold",
                value: "\(movementDelta) raw values",
                detail: "A measurement point must change by this much relative to the background — "
                    + "closer or farther, direction doesn't matter."
            ),
            ZoneLearningExplanation(
                id: "indexPadding",
                title: "Side padding",
                value: LearningUnitText.points(indexPaddingPoints) + " per side",
                detail: "The found area is extended this far to the left and right."
            ),
            ZoneLearningExplanation(
                id: "valuePadding",
                title: "Depth padding",
                value: "\(valuePadding) raw values",
                detail: "The found value range is extended this far inward and outward."
            ),
            ZoneLearningExplanation(
                id: "clearance",
                title: "Background clearance",
                value: "\(backgroundClearance) raw values",
                detail: "The learned zone stays this far ahead of the background so it doesn't trigger "
                    + "without a hand."
            ),
            ZoneLearningExplanation(
                id: "ambiguity",
                title: "Ambiguity",
                value: "Factor " + DecimalText.fixed(ambiguityToleranceFactor, places: 2),
                detail: "If a second area comes this close to the strongest, no suggestion "
                    + "is made — guessing would be worse than asking."
            )
        ]
    }
}

// MARK: - Der vollständige Anzeigezustand des Lernbereichs

/// Der Anzeigezustand des Bereichs „Bereich mit Hand lernen" **einer**
/// Zone.
///
/// Zusammengesetzt aus drei Quellen, die getrennt bleiben: der Zone und
/// ihrem Ein/Aus-Zustand, dem (höchstens einen) laufenden oder zuletzt
/// beendeten Lernvorgang und der festen Konfiguration.
///
/// **Schritt und Sperrgrund sind zwei Felder, keine Ampel.** Ein
/// beendeter Vorgang darf sein Ergebnis weiter zeigen, auch wenn ein
/// Neustart gerade gesperrt ist — sonst verschwände beim Einschalten der
/// Zone die Begründung, die man gerade lesen will.
public struct ZoneLearningPresentation: Equatable, Sendable {
    /// Die Zone, um die es geht.
    public let zoneID: EditableZone.ID
    /// Ob diese Zone eingeschaltet ist — die Grundlage von Auflage **D2**.
    public let isZoneEnabled: Bool
    public let phase: ZoneLearningPhase
    /// Warum ein Start jetzt nicht ginge, oder `nil`.
    public let block: ZoneLearningBlock?
    public let configuration: ZoneLearningConfiguration

    /// Leitet die Anzeige aus dem **echten** Editorzustand ab.
    ///
    /// `learning` ist der höchstens eine Vorgang des ganzen Editors;
    /// gehört er einer anderen Zone, ist der Schritt hier ``ZoneLearningPhase/idle``
    /// und der Start gesperrt. `learnDraftIsCollecting` kommt seit
    /// SICK-032c3a-K1 hinzu: Ein sammelnder vorzonaler Entwurf sperrt
    /// einen (Neu-)Start hier genauso wie eine andere sammelnde Zone --
    /// dieselbe projektweite Exklusivität, nur die jeweils andere
    /// Ursache.
    public init(
        zoneID: EditableZone.ID,
        isZoneEnabled: Bool,
        learning: ZoneLearningSession?,
        learnDraftIsCollecting: Bool = false,
        configuration: ZoneLearningConfiguration = .default
    ) {
        self.zoneID = zoneID
        self.isZoneEnabled = isZoneEnabled
        self.configuration = configuration

        if let learning, learning.zoneID == zoneID {
            self.phase = ZoneLearningPhase(state: learning.state)
        } else {
            self.phase = .idle
        }

        if isZoneEnabled {
            self.block = .zoneIsEnabled
        } else if let learning, learning.zoneID != zoneID, learning.isCollecting {
            self.block = .otherZoneIsLearning
        } else if learnDraftIsCollecting {
            self.block = .learnDraftIsCollecting
        } else {
            self.block = nil
        }
    }

    /// Setzt Schritt und Sperrgrund unmittelbar — **modulintern und
    /// ausschließlich für Texttests**.
    ///
    /// Die Präsentation hat keine Invariante zu schützen (sie ist eine
    /// reine Ableitung), aber sie hat im Produktionsweg genau **eine**
    /// Entstehungsstelle: den Initialisierer oben, gespeist aus einem
    /// echten ``SickPLSMonitorKit/ZoneLearningSession``. Damit das so
    /// bleibt, ist dieser hier nicht öffentlich — einige Endlagen des
    /// Lernvertrags (etwa `candidateNotBuildable`) sind von außen
    /// strukturell unerreichbar und wären sonst ungeprüft.
    init(
        zoneID: EditableZone.ID,
        isZoneEnabled: Bool,
        phase: ZoneLearningPhase,
        block: ZoneLearningBlock?,
        configuration: ZoneLearningConfiguration
    ) {
        self.zoneID = zoneID
        self.isZoneEnabled = isZoneEnabled
        self.phase = phase
        self.block = block
        self.configuration = configuration
    }

    // MARK: - Überschrift und Anleitung

    /// Der feste Titel des Bereichs.
    public static let sectionTitle = "Learn area by hand"

    /// Der Schritt, in dem der Vorgang steht — in Alltagssprache.
    ///
    /// `switch` ohne `default`: Ein neuer Schritt muss sich hier
    /// entscheiden.
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

    /// Was jetzt zu tun ist. Für die drei Endlagen ist das der jeweils
    /// eigene, handlungsorientierte Satz — **nie** bloß „Fehler".
    public var instruction: String {
        switch phase {
        case .idle:
            return "One click starts learning: first keep the scan field clear briefly, then "
                + "move your hand through the area that should control."
        case .waitingForProfiles, .collectingBaseline:
            return "The background is being captured. Please don't reach into the scan field yet."
        case .collectingMovement:
            return "Move your hand slowly through the desired area. Then \""
                + Self.finishTitle + "\"."
        case .candidate:
            return "The suggestion has not been applied yet. \"" + Self.applyTitle
                + "\" writes it to this zone, \"" + Self.discardTitle + "\" leaves it unchanged."
        case .refused(let refusal):
            return refusal.operatorText
        case .cancelled(let reason):
            return reason.operatorText
        case .failed(let failure):
            return failure.operatorText
        }
    }

    /// Der Fortschritt — **ausschließlich** aus echten Profilen, ohne
    /// Uhr und ohne Hochrechnung.
    ///
    /// `nil`, solange nichts gesammelt wird. Solange noch kein einziges
    /// Profil eingetroffen ist, steht hier ehrlich „Warte auf Messwerte"
    /// statt eines laufenden Balkens; bleiben die Profile später aus,
    /// bleibt der zuletzt **wirklich** erreichte Stand stehen.
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

    /// Die vier Grenzen des Vorschlags, oder `nil`.
    ///
    /// Dieselbe Formatierung wie im Insert — es gibt **eine**
    /// Grenzendarstellung im Projekt.
    public var candidateBoundsLabel: String? {
        phase.candidateZone.map { ZoneBoundsText.label(for: $0) }
    }

    /// Der Sperrgrund als Satz, oder `nil`.
    public var blockMessage: String? { block?.message }

    // MARK: - Was gerade möglich ist

    /// Knopfbeschriftungen — auch sie stehen im Modell, damit die
    /// Anleitungstexte oben sie **wörtlich** zitieren können und beide
    /// nicht auseinanderlaufen.
    public static let startTitle = "Start learning"
    public static let finishTitle = "Finish collecting"
    public static let cancelTitle = "Cancel"
    public static let applyTitle = "Apply"
    public static let discardTitle = "Discard"

    /// Ein Start ist nur ohne Sperrgrund und nur dann möglich, wenn nicht
    /// gerade gesammelt wird.
    public var canStart: Bool { block == nil && !phase.isCollecting }

    public var canFinish: Bool { phase.isCollecting }
    public var canCancel: Bool { phase.isCollecting }

    /// Übernehmen setzt einen Vorschlag **und** eine weiterhin
    /// ausgeschaltete Zone voraus (Auflage **D2**).
    public var canApply: Bool { phase.candidateZone != nil && !isZoneEnabled }

    /// Ein beendetes Ergebnis lässt sich wegräumen — auch eine
    /// Verweigerung, ein Abbruch und ein Fehlschlag.
    public var canDiscard: Bool { phase.hasResult }

    /// Die lesbare Erklärung der Lernparameter.
    public var explanations: [ZoneLearningExplanation] { configuration.explanations }
}
