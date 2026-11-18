/// Der **eine** testbare Darstellungsvertrag, der entscheidet, **wo**
/// ``ScannerWorkspaceModel/learnDraftNotice`` sichtbar wird
/// (SICK-032c3b-K1, Abnahmeblocker 1, `.agent_handoff/review-sick-032c3b.md`).
///
/// ## Warum es diesen Typ gibt
///
/// ``ScannerWorkspaceModel/learnDraftNotice`` ist absichtlich vom
/// Draft entkoppelt: Er wird unter anderem gesetzt, wenn ein Start durch
/// ein bereits sammelndes zonengebundenes Learn **verweigert** wird --
/// dann existiert nie ein Draft, der einen Hinweis-Host abgeben könnte.
/// Und nach einer erfolgreichen Übernahme (``ScannerWorkspaceModel/applyLearnDraftCandidate()``)
/// verschwindet der Draft, bevor der Erfolgshinweis verblasst. In beiden
/// Lagen hatte der Hinweis bis SICK-032c3b keinen sichtbaren Platz, weil
/// die einzige Stelle, die ihn zeigte (die Draftkarte), an genau der
/// Bedingung hing, die ihn gerade unsichtbar machte.
///
/// Diese Struktur trifft die Host-Entscheidung **einmal, pur, ohne
/// SwiftUI**: Solange ein Draft existiert, gehört der Hinweis in dessen
/// Karte (``cardNotice``); ohne Draft gehört derselbe Hinweis in einen
/// Fallback-Host im Messfeld-/Zonenbereich (``hostedNotice``). Beide
/// berechneten Eigenschaften prüfen dieselbe gespeicherte
/// ``presentation`` und schließen sich damit strukturell aus -- eine
/// Ansicht, die beide anzeigt, kann den Hinweis nie doppelt zeigen, und
/// eine Ansicht, die nur eine liest, zeigt ihn nie an der falschen
/// Stelle.
///
/// `notice` ist bewusst **privat**: Ein Aufrufer, der ihn direkt läse,
/// könnte an ``cardNotice``/``hostedNotice`` vorbei genau die
/// Verwechslung wiederholen, die dieser Typ auflöst.
public struct LearnDraftSurface: Equatable, Sendable {
    /// Der aktuelle Entwurf, oder `nil` ohne laufenden Draft.
    public let presentation: LearnDraftPresentation?

    private let notice: ZoneLearningNotice?

    public init(presentation: LearnDraftPresentation?, notice: ZoneLearningNotice?) {
        self.presentation = presentation
        self.notice = notice
    }

    /// Der Hinweis, **sofern eine Draftkarte existiert** -- dort gehostet.
    /// `nil` ohne Draft, selbst wenn ein Hinweis vorliegt.
    public var cardNotice: ZoneLearningNotice? {
        presentation != nil ? notice : nil
    }

    /// Derselbe Hinweis, **sofern kein Draft existiert** -- muss dann
    /// anderswo sichtbar bleiben (Abnahmeblocker 1). `nil`, solange ein
    /// Draft läuft, selbst wenn ein Hinweis vorliegt.
    public var hostedNotice: ZoneLearningNotice? {
        presentation == nil ? notice : nil
    }
}
