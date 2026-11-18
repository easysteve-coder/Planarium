/// Ob und wann eine Ansicht den Scanfeld-Ausschnitt **automatisch**
/// fokussieren darf, während eine neue Zone gelernt wird (SICK-032c3a,
/// `.agent_handoff/task-sick-032c3a.md` Abschnitt 3).
///
/// ## Was dieser Typ ist -- und was nicht
///
/// Ein **reiner Entscheidungs-Reducer**, kein Ausschnitt selbst: Er hält
/// keinen ``ScanPlaneViewport``, rechnet keine Geometrie und kennt weder
/// ``LearnDraft`` noch ``ScanFieldFocusArea`` noch `ZoneEditorState`. Er
/// beantwortet ausschließlich eine Frage -- „darf jetzt automatisch
/// fokussiert werden?" -- anhand dreier von außen gemeldeter
/// Ereignisklassen. Die eigentliche Berechnung des Ausschnitts (aus
/// einem Profil, einer Kandidatin) bleibt ``ScanFieldFocusArea``, das
/// Anwenden auf einen konkreten ``ScanPlaneViewport`` bleibt der
/// Ansicht (SICK-032c3b) -- derselbe Schnitt wie zwischen
/// `ZoneGeometryReducer` (entscheidet) und `ZoneEditorState.apply`
/// (schreibt).
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// 1. **Höchstens ein automatischer Fokus je Lebensdauer dieses
///    Zustands.** ``apply(_:)`` liefert ``Decision/focusNow`` für
///    ``Input/measurementAvailable`` **genau einmal** -- danach immer
///    ``Decision/doNothing``, unabhängig davon, wie viele weitere
///    brauchbare Messungen folgen.
/// 2. **Manuelle Navigation sperrt jeden künftigen automatischen
///    Fokus**, auch wenn noch keiner gewirkt hat -- unwiderruflich für
///    die Lebensdauer dieses Zustands. Was als manuelle Navigation
///    zählt, entscheidet **ausdrücklich der Aufrufer** (Zoomknopf,
///    Scrollrad, Pinch, ein **wirksames** Verschieben, Rahmenzoom,
///    „Gesamtansicht") -- bloße Werkzeugwahl und eine
///    abgelehnte/entartete Geste melden **nichts** an diesen Typ, sie
///    sperren also auch nichts.
/// 3. **„Einpassen" wirkt immer, sperrt aber zusätzlich jeden noch
///    ausstehenden automatischen Fokus.** Ein ausdrücklicher
///    Bedienschritt darf nicht dadurch entwertet werden, dass eine
///    später eintreffende Messung ihn sofort wieder überschreibt --
///    „setzt aber keine fortlaufende Automatik in Gang" (Auftragstext).
///    Bereits gewirkte oder bereits gesperrte Automatik bleibt davon
///    unberührt.
/// 4. **Kein Reset außer über** ``reset()``. Die Lebensdauer dieses
///    Zustands folgt der eines ``LearnDraft`` -- ein neuer Entwurf
///    (Anlegen, Neustart) bekommt einen frischen, unverbrauchten
///    Zustand; ein Abbruch oder eine Trennung **verbraucht** den
///    Zustand nicht eigens, weil danach ohnehin keine weiteren
///    Messungen mehr eintreffen, die ``Input/measurementAvailable``
///    auslösen könnten (derselbe `isCollecting`-Schutz wie beim
///    Accumulator).
public struct LearnFocusState: Equatable, Sendable {

    /// Drei sich gegenseitig ausschließende Lagen -- absichtlich kein
    /// `Bool`: „schon automatisch fokussiert" und „durch manuelle
    /// Navigation gesperrt" verlangen unterschiedliche Begründungen,
    /// auch wenn beide dieselbe Wirkung haben (kein weiterer
    /// automatischer Fokus).
    private enum Availability: Equatable, Sendable {
        /// Es wirkte noch nichts, und nichts hat gesperrt.
        case pending
        /// Der automatische Fokus hat bereits genau einmal gewirkt.
        case consumedByAutomaticFocus
        /// Manuelle Navigation (oder ein ausdrückliches „Einpassen" vor
        /// dem ersten automatischen Fokus) hat jede künftige Automatik
        /// ausgeschlossen.
        case lockedByManualNavigation
    }

    private var availability: Availability

    /// Der frische, unverbrauchte Ausgangszustand eines neuen Entwurfs.
    public static let initial = LearnFocusState()

    private init(availability: Availability = .pending) {
        self.availability = availability
    }

    /// Die von außen gemeldeten Ereignisklassen.
    ///
    /// **Absichtlich kein Fall für „Werkzeugwahl" oder „abgelehnte/
    /// entartete Geste":** Diese melden dem Zustand nichts -- der
    /// Aufrufer ruft ``apply(_:)`` für sie schlicht nicht auf, statt
    /// eigens einen wirkungslosen Fall zu übergeben.
    public enum Input: Equatable, Sendable {
        /// Eine echte Messung liegt vor, aus der sich ein relevanter
        /// Bereich ableiten ließe (``ScanFieldFocusArea/hasUsableMeasurement(in:)``).
        case measurementAvailable
        /// Zoomknopf, Scrollrad, Pinch, ein **wirksames** Verschieben,
        /// Rahmenzoom oder „Gesamtansicht".
        case manualNavigation
        /// Der Bedienende hat „Einpassen" ausdrücklich verlangt.
        case explicitFitRequested
    }

    /// Was der Aufrufer jetzt tun soll.
    public enum Decision: Equatable, Sendable {
        /// Jetzt den relevanten Bereich berechnen und den Ausschnitt
        /// darauf setzen.
        case focusNow
        /// Nichts tun -- der Ausschnitt bleibt, wie er ist.
        case doNothing
    }

    /// Wertet **ein** Ereignis aus und liefert die Entscheidung dazu.
    @discardableResult
    public mutating func apply(_ input: Input) -> Decision {
        switch input {
        case .measurementAvailable:
            guard availability == .pending else { return .doNothing }
            availability = .consumedByAutomaticFocus
            return .focusNow
        case .manualNavigation:
            if availability == .pending { availability = .lockedByManualNavigation }
            return .doNothing
        case .explicitFitRequested:
            if availability == .pending { availability = .lockedByManualNavigation }
            return .focusNow
        }
    }

    /// Ob ein automatischer Fokus für diesen Zustand **noch aussteht**
    /// -- weder schon gewirkt noch gesperrt. Reine Beobachtung, keine
    /// Mutation.
    public var isAutomaticFocusStillPending: Bool { availability == .pending }

    /// Setzt auf den frischen Ausgangszustand zurück -- **nur** für
    /// einen wirklich neuen Entwurf (Anlegen, Neustart nach einem
    /// beendeten Vorgang). Kein impliziter Reset an keiner anderen
    /// Stelle.
    public mutating func reset() { self = .initial }
}
