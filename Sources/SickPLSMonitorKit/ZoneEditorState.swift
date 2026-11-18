import CoreGraphics
import struct Foundation.UUID
import SickPLSCore
import SickPLSControlCore

/// Reiner, unveränderlicher Zustandswert des Zoneneditors -- analog zu
/// `ScanSessionState`: kein Threading, kein SwiftUI, jede Methode eine
/// reine Funktion (alter Zustand + Aktion -> neuer Zustand). Hält in
/// ``zones`` ausschließlich bereits über `Zone.build(...)` gültige
/// `Zone`-Werte; der aktuell bearbeitete ``draft`` ist bewusst getrennt
/// und erst nach ``commitDraft()`` wirksam (SICK-014-Auftrag:
/// „ungültige Zwischenwerte dürfen nie in das Modell gelangen").
public struct ZoneEditorState: Equatable, Sendable {
    public private(set) var zones: [EditableZone] = []
    public private(set) var selectedZoneID: EditableZone.ID?
    public private(set) var draft: ZoneDraft?

    /// Der laufende oder zuletzt beendete Lernvorgang (SICK-030c), oder
    /// `nil`, wenn nie einer armiert wurde.
    ///
    /// **Höchstens einer.** Zwei gleichzeitige Vorgänge teilten sich
    /// denselben Profilstrom und wären hinterher nicht auseinanderzuhalten.
    /// Das Ergebnis bleibt nach dem Ende **stehen**, damit die Oberfläche
    /// den Grund einer Verweigerung noch zeigen kann; es verschwindet erst
    /// durch ein neues ``armLearn(zoneID:configuration:)`` oder
    /// ``discardLearn()``.
    ///
    /// **Seit SICK-032c3a-K1 gilt die Exklusivität projektweit, nicht nur
    /// unter sich selbst:** Solange ``learnDraft`` noch sammelt, lehnt
    /// ``armLearn(zoneID:configuration:)`` einen neuen Versuch mit
    /// ``ZoneLearningArmOutcome/blockedByLearnDraft`` ab. Zwei getrennte
    /// **Instanzen** (eine bereits vorhandene Zone, ein vorzonaler
    /// Entwurf) bleiben es weiterhin — nur **sammeln** dürfen sie nie
    /// gleichzeitig, weil beide sich sonst denselben Profilstrom teilten
    /// und ``ingestLearningProfile(_:)`` beide zugleich fortschriebe.
    public private(set) var learning: ZoneLearningSession?

    /// Der laufende oder zuletzt beendete **vorzonale** Lernentwurf für
    /// eine neue Zone (SICK-032c3a), oder `nil`, wenn nie einer angelegt
    /// wurde.
    ///
    /// **Höchstens einer**, dieselbe Begründung wie ``learning``: Zwei
    /// gleichzeitige Entwürfe teilten sich denselben Profilstrom. Ein
    /// beendetes Ergebnis bleibt stehen, bis ``startLearnDraft(role:configuration:)``
    /// (Neustart) oder ``discardLearnDraft()`` es ersetzt.
    ///
    /// **Getrennte Instanzen, aber gemeinsame Sammelexklusivität**
    /// (SICK-032c3a-K1): Ein vorzonaler Entwurf und ein Lernvorgang an
    /// einer bereits vorhandenen Zone teilen sich keine Instanz, dürfen
    /// aber **nie gleichzeitig sammeln** — solange ``learning`` noch
    /// sammelt, lehnt ``startLearnDraft(role:configuration:)`` einen
    /// neuen Versuch mit ``LearnDraftStartOutcome/blockedByZoneLearning(zoneID:)``
    /// ab. Ein bereits **beendetes** Ergebnis des jeweils anderen Pfads
    /// blockiert dagegen nichts — es geht um aktive Sammlung, nicht um
    /// ein bloß sichtbares Endergebnis.
    public private(set) var learnDraft: LearnDraft?

    public init() {}

    public var selectedZone: EditableZone? {
        guard let selectedZoneID else { return nil }
        return zones.first { $0.id == selectedZoneID }
    }

    /// Fügt eine bereits gültige `Zone` hinzu und wählt sie sofort aus
    /// (SICK-014-Auftrag Oberfläche Punkt 2: „Hinzufügen ... wählt der
    /// Nutzer eine Rolle aus" -- der Aufrufer konstruiert die `Zone`
    /// über `Zone.build`, dieser Zustand kennt nur das Ergebnis).
    ///
    /// **Die neue Zone entsteht deaktiviert** (SICK-030b1, Auflage
    /// **D2**): Sie ist sofort sichtbar und wird sofort gegen echte
    /// Profile bewertet, greift aber erst in die Klangerzeugung ein,
    /// wenn jemand sie ausdrücklich einschaltet. Eine frisch gezogene
    /// Zone soll beim Einrichten nichts auslösen — und das spätere
    /// bewegungsbasierte Lernen setzt genau diesen Zustand voraus.
    @discardableResult
    public mutating func addZone(_ zone: Zone) -> EditableZone.ID {
        let editable = EditableZone(zone: zone, isEnabled: false)
        zones.append(editable)
        select(editable.id)
        return editable.id
    }

    /// Schaltet eine Zone ein oder aus (SICK-030b1).
    ///
    /// **Nur dieses eine Merkmal ändert sich.** Die fachlichen Werte in
    /// `Zone` bleiben unangetastet, und eine Slot-Zuweisung bleibt
    /// bestehen — Ausschalten ist ausdrücklich **kein** Abwählen, und
    /// Wiedereinschalten stellt deshalb auch nichts heimlich zurück.
    ///
    /// `false`, wenn es die ID nicht gibt; der Zustand bleibt dann
    /// vollständig unverändert.
    @discardableResult
    public mutating func setZone(_ id: EditableZone.ID, isEnabled: Bool) -> Bool {
        guard let index = zones.firstIndex(where: { $0.id == id }) else { return false }
        let didChange = zones[index].isEnabled != isEnabled
        zones[index].isEnabled = isEnabled
        rederiveDraft()
        // Ein **Wechsel** beendet einen laufenden Lernvorgang dieser Zone
        // (SICK-030c): Einschalten macht sie zu einer spielenden Zone,
        // Ausschalten geschah gerade erst. Derselbe Wert nochmals gesetzt
        // ist keine Änderung und beendet deshalb nichts.
        if didChange { cancelLearn(for: id, reason: .zoneActivationChanged) }
        return true
    }

    /// Löscht eine bestimmte Zone; eine unbekannte ID ist ein No-op.
    ///
    /// War es die ausgewählte, ist danach nichts ausgewählt.
    @discardableResult
    public mutating func removeZone(_ id: EditableZone.ID) -> Bool {
        guard zones.contains(where: { $0.id == id }) else { return false }
        zones.removeAll { $0.id == id }
        if selectedZoneID == id { selectedZoneID = nil }
        rederiveDraft()
        cancelLearn(for: id, reason: .zoneRemoved)
        return true
    }

    /// Löscht die aktuell ausgewählte Zone; ohne Auswahl ein No-op.
    /// Ersetzt **alle** Zonen auf einmal (Presetladen, SICK-037): die
    /// mitgebrachten IDs bleiben erhalten, Auswahl und Entwurf werden
    /// geleert, laufende Lernvorgänge beendet. Erzeugt kein Gate und
    /// kein Audio -- die Zuordnung gleicht der Koordinator ab.
    public mutating func replaceZones(_ newZones: [EditableZone]) {
        cancelLearn(.operatorCancelled)
        cancelLearnDraft(.operatorCancelled)
        zones = newZones
        selectedZoneID = nil
        rederiveDraft()
    }

    public mutating func removeSelectedZone() {
        guard let selectedZoneID else { return }
        removeZone(selectedZoneID)
    }

    /// Wählt eine Zone aus (oder hebt die Auswahl mit `nil` auf) und
    /// setzt ``draft`` auf deren aktuelle Werte zurück -- ein noch
    /// nicht übernommener Entwurf der vorherigen Auswahl geht dabei
    /// bewusst verloren (er war ohnehin nie im Modell, siehe Typkommentar).
    public mutating func select(_ id: EditableZone.ID?) {
        selectedZoneID = id
        rederiveDraft()
    }

    /// Leitet den Entwurf wieder aus der **gespeicherten** Zone ab
    /// (SICK-030b1, Auflage **D3**).
    ///
    /// **Eine Wahrheit, kein Zusammenführen.** `zones[i].zone` ist die
    /// einzige Wahrheit; der Entwurf ist nur der Zwischenstand der
    /// Eingabefelder. Jede **direkte** Änderung an einer Zone —
    /// Einschalten, Ausschalten, Entfernen, künftig Griffe und Lernen —
    /// setzt ihn deshalb neu, statt zwei Stände zu mischen.
    ///
    /// **Ein noch nicht übernommener Eingabewert verfällt dabei**, und
    /// das ist der Zweck: Ein halb getippter Wert neben einer gerade
    /// direkt geänderten Zone wäre ein zweiter Schreiber. Das Feld zeigt
    /// danach den Zonenwert.
    private mutating func rederiveDraft() {
        draft = selectedZone.map { ZoneDraft(zone: $0.zone, shape: $0.shape) }
    }

    /// Ergebnis von ``applyGeometryGesture(_:from:toScreenPoint:in:)``.
    ///
    /// „Unbekannte Zone" steht bewusst **neben** den Ablehnungsgründen
    /// des Reducers, nicht in ihnen: Der Reducer kennt keine Zonenliste
    /// und kann diesen Fall gar nicht erzeugen. Ein gemeinsamer
    /// Fehlertyp hätte dort einen Fall, den es nie gibt.
    public enum ZoneGeometryApplication: Equatable, Sendable {
        /// Geschrieben; der Wert ist die neue, gültige Zone.
        case applied(Zone)
        /// Die ID gehört zu keiner Zone -- nichts wurde geändert.
        case unknownZone
        case rejected(ZoneGeometryRejection)
    }

    /// Wendet einen fertigen Bearbeitungsbefehl des Scanfelds an --
    /// **die Stelle, an der die Bedienung auf die eine Zonenwahrheit
    /// trifft** (SICK-032b3).
    ///
    /// `ScanFieldViewState` entscheidet, **was** eine Geste bedeutet
    /// (welcher Griff, welche Zone, welcher eingefrorene Ausgangsstand);
    /// geschrieben wird ausschließlich hier, über den geprüften
    /// ``ZoneGeometryReducer``. Damit gibt es weiterhin genau einen
    /// Schreibweg, und die Ansicht reicht nur weiter.
    @discardableResult
    public mutating func apply(_ command: ZoneGeometryCommand) -> ZoneGeometryApplication {
        applyGeometryGesture(
            command.gesture,
            from: command.start,
            toScreenPoint: command.location,
            in: command.geometry
        )
    }

    /// Wendet eine laufende Ziehgeste auf **eine** Zone an
    /// (SICK-030b2, Auftragspunkt 4).
    ///
    /// **Eine Wahrheit, live geschrieben** (Auflage **D3**): Das Ergebnis
    /// landet unmittelbar in `zones[i].zone`, und ein offener Entwurf
    /// wird daraus **neu abgeleitet** -- es gibt keinen zweiten Stand,
    /// der später zusammengeführt werden müsste. Ein noch nicht
    /// übernommener Eingabewert verfällt dabei, wie bei jeder anderen
    /// direkten Änderung auch (siehe ``rederiveDraft()``).
    ///
    /// **Der Ausgangszustand kommt aus `start`, nie aus `zones`** -- das
    /// ist der Unterschied zwischen Gesamtverschiebung und
    /// Delta-Akkumulation, siehe ``ZoneGeometryGestureStart``.
    ///
    /// **Was diese Aktion ausdrücklich nicht anfasst:** ``EditableZone``s
    /// `id` und `isEnabled`, die Rolle, die Auswahl, die Rollen-/Slot-
    /// zuordnung und jede andere Zone der Liste. Eine Geste aktiviert
    /// nichts, weist nichts zu und erzeugt kein Gate-Ereignis.
    ///
    /// Jede Ablehnung lässt den Zustand **vollständig** unverändert.
    @discardableResult
    public mutating func applyGeometryGesture(
        _ gesture: ZoneGeometryGesture,
        from start: ZoneGeometryGestureStart,
        toScreenPoint location: CGPoint,
        in geometry: LinearScanFieldGeometry
    ) -> ZoneGeometryApplication {
        guard let index = zones.firstIndex(where: { $0.id == start.zoneID }) else {
            return .unknownZone
        }
        switch ZoneGeometryReducer.apply(gesture, from: start, toScreenPoint: location, in: geometry) {
        case .rejected(let reason):
            return .rejected(reason)
        case .updated(let zone):
            zones[index].zone = zone
            rederiveDraft()
            return .applied(zone)
        }
    }

    /// Ersetzt den Entwurf der ausgewählten Zone -- beliebige, auch
    /// vorübergehend ungültige Zwischenwerte erlaubt; ``zones`` bleibt
    /// dabei unverändert. Ohne Auswahl ein No-op.
    public mutating func updateDraft(_ draft: ZoneDraft) {
        guard selectedZoneID != nil else { return }
        self.draft = draft
    }

    /// Klammert den aktuellen Entwurf (``ZoneDraft/clamp()``) und
    /// übernimmt ihn -- nur wenn danach eine gültige `Zone` entsteht --
    /// in die ausgewählte Zone. `true` bei erfolgreicher Übernahme,
    /// `false` ohne Auswahl/Entwurf.
    @discardableResult
    public mutating func commitDraft() -> Bool {
        guard var draft, let selectedZoneID else { return false }
        draft.clamp()
        self.draft = draft
        guard let zone = draft.resolvedZone(),
              let index = zones.firstIndex(where: { $0.id == selectedZoneID }) else {
            return false
        }
        let didChangeRole = zones[index].zone.role != zone.role
        zones[index].zone = zone
        // Die Form kommt mit (SICK-033e). Für Gate gilt strukturell der
        // Streifen; der Entwurf wird darauf zurückgeführt, damit Karte
        // und Zone dieselbe Form zeigen.
        zones[index].shape = zone.role == .gate ? .strip : draft.shape
        if zone.role == .gate { self.draft?.shape = .strip }
        // Eine **Rollenänderung** beendet einen laufenden Lernvorgang
        // dieser Zone (SICK-030c): Eine für Gate gelernte Fläche ist keine
        // Pitch-Zone. Eine reine Grenzenänderung tut das nicht -- sie ist
        // genau das, was das Lernen gleich überschreiben soll.
        if didChangeRole { cancelLearn(for: selectedZoneID, reason: .zoneRoleChanged) }
        return true
    }

    // MARK: - Bewegungsbasiertes Lernen (SICK-030c)

    /// Armiert einen Lernvorgang auf einer **deaktivierten** Zone.
    ///
    /// **Auflage D2:** Nur `isEnabled == false` ist zulässig. Auf einer
    /// eingeschalteten Zone klänge die Lernbewegung mit, und beim
    /// Übernehmen änderten sich die Grenzen einer spielenden Zone unter
    /// der Hand (die Prognosehistorie würde verworfen, SICK-015a M1; ein
    /// aktives Gate fiele beim nächsten Profil auf `.inactive` -- sicher,
    /// aber hörbar). Die Oberfläche sagt dann „zum Lernen zuerst
    /// deaktivieren".
    ///
    /// Ein laufender Vorgang wird **nicht** verdrängt; das Ergebnis eines
    /// bereits beendeten schon.
    ///
    /// **Seit SICK-032c3a-K1 auch gegen einen sammelnden vorzonalen
    /// Entwurf abgesichert** (``ZoneLearningArmOutcome/blockedByLearnDraft``):
    /// Höchstens ein Lernvorgang insgesamt darf gleichzeitig sammeln,
    /// sonst führe ``ingestLearningProfile(_:)`` dasselbe Profil in zwei
    /// Accumulatoren gleichzeitig fort. Ein bereits **beendeter** Entwurf
    /// blockiert dagegen nichts.
    @discardableResult
    public mutating func armLearn(
        zoneID: EditableZone.ID,
        configuration: ZoneLearningConfiguration = .default
    ) -> ZoneLearningArmOutcome {
        if let learning, learning.isCollecting {
            return .alreadyLearning(zoneID: learning.zoneID)
        }
        if let learnDraft, learnDraft.isCollecting {
            return .blockedByLearnDraft
        }
        guard let zone = zones.first(where: { $0.id == zoneID }) else { return .unknownZone }
        guard !zone.isEnabled else { return .zoneIsEnabled }
        learning = ZoneLearningSession(
            zoneID: zoneID, role: zone.zone.role, configuration: configuration
        )
        return .armed
    }

    /// Reicht **ein** echtes Profil in jeden laufenden Vorgang --
    /// sowohl ``learning`` (eine bereits vorhandene Zone) als auch
    /// ``learnDraft`` (SICK-032c3a, eine neue Zone ohne `Zone`).
    ///
    /// Ohne einen laufenden Vorgang ein No-op. **Dies bleibt der einzige
    /// Profileingang des Lernens** -- gefüttert wird er aus derselben
    /// Zustellung wie die Klangerzeugung, nie aus einem zweiten Strom.
    ///
    /// **Strukturell nie zwei gleichzeitig:** Die beiden `if`s hier sehen
    /// zwar so aus, als könnten sie beide zuschlagen -- das können sie
    /// aber nicht, weil ``armLearn(zoneID:configuration:)`` und
    /// ``startLearnDraft(role:configuration:)`` seit SICK-032c3a-K1
    /// bereits beim **Start** die jeweils andere aktive Sammlung ablehnen
    /// (``ZoneLearningArmOutcome/blockedByLearnDraft``/
    /// ``LearnDraftStartOutcome/blockedByZoneLearning(zoneID:)``).
    /// `learning?.isCollecting == true && learnDraft?.isCollecting == true`
    /// ist deshalb ein Zustand, der in diesem Modul nie entsteht.
    public mutating func ingestLearningProfile(_ profile: B0ScanProfile) {
        if learning?.isCollecting == true { learning?.ingest(profile) }
        if learnDraft?.isCollecting == true { learnDraft?.ingest(profile) }
    }

    /// Beendet das Sammeln und lässt den Kandidaten berechnen.
    ///
    /// **Schreibt nichts** -- das tut erst ``applyLearnCandidate()``.
    public mutating func finishLearn() {
        guard learning?.isCollecting == true else { return }
        learning?.finish()
    }

    /// Bricht einen laufenden Vorgang mit benanntem Grund ab.
    public mutating func cancelLearn(_ reason: ZoneLearningCancellation = .operatorCancelled) {
        guard learning?.isCollecting == true else { return }
        learning?.cancel(reason)
    }

    /// Verwirft den Vorgang samt Ergebnis vollständig.
    public mutating func discardLearn() {
        learning = nil
    }

    /// Schreibt den Kandidaten in die **eine** Zonenwahrheit.
    ///
    /// **Was hier bewusst nicht passiert:** `isEnabled` bleibt, wie es
    /// war. Das Einschalten nach dem Lernen ist ein eigener Handgriff
    /// (Auflage **D2**) -- eine gelernte Zone, die sich selbst
    /// einschaltet, wäre genau die automatische Klangaktion, die
    /// ausgeschlossen ist.
    ///
    /// Geschrieben wird nur an **dieselbe, weiterhin deaktivierte** Zone
    /// mit **unveränderter Rolle**; jede Abweichung ist eine benannte
    /// Ablehnung und lässt den Zustand unverändert. Danach wird der
    /// Entwurf aus der neuen Zone neu abgeleitet (Auflage **D3**).
    @discardableResult
    public mutating func applyLearnCandidate() -> ZoneLearningApplyOutcome {
        guard let learning else { return .notLearning }
        guard let candidate = learning.candidate else { return .noCandidate(learning.state) }
        guard let index = zones.firstIndex(where: { $0.id == learning.zoneID }) else {
            return .targetZoneMissing
        }
        guard !zones[index].isEnabled else { return .targetZoneIsEnabled }
        guard zones[index].zone.role == learning.role else {
            return .targetZoneRoleChanged(expected: learning.role, actual: zones[index].zone.role)
        }
        zones[index].zone = candidate
        rederiveDraft()
        return .applied(candidate)
    }

    /// Bricht einen laufenden Vorgang ab, **wenn** er genau dieser Zone
    /// gilt. Sonst wirkungslos -- eine Änderung an einer fremden Zone
    /// geht das Lernen nichts an.
    private mutating func cancelLearn(for zoneID: EditableZone.ID, reason: ZoneLearningCancellation) {
        guard let learning, learning.zoneID == zoneID, learning.isCollecting else { return }
        self.learning?.cancel(reason)
    }

    // MARK: - Vorzonales Lernen für eine neue Zone (SICK-032c3a)
    //
    // **Der einzige Weg, wie in diesem Zustand ohne erfundene Grenzen
    // eine neue Zone entsteht.** `NewZoneDefaults` (der bisherige
    // Anlegeweg mit den festen Grenzen `1000...4000`) ist damit für den
    // produktiven Anlegeweg abgelöst -- siehe
    // `ScannerWorkspaceModel.addZone(role:)`.

    /// Legt einen neuen, **vorzonalen** Lernentwurf für `role` an --
    /// oder startet einen bereits beendeten Entwurf neu.
    ///
    /// Erzeugt **keine** `EditableZone` und fasst ``zones`` nicht an.
    /// Ein noch **sammelnder** Entwurf wird nicht verdrängt (dasselbe
    /// Muster wie ``armLearn(zoneID:configuration:)``); ein bereits
    /// beendetes Ergebnis dagegen schon -- genau das ist „neu starten",
    /// und der neue Entwurf bekommt einen frischen ``LearnFocusState``.
    ///
    /// **Seit SICK-032c3a-K1 auch gegen eine sammelnde, bereits
    /// vorhandene Zone abgesichert** (``LearnDraftStartOutcome/blockedByZoneLearning(zoneID:)``)
    /// -- dieselbe projektweite Exklusivität wie umgekehrt bei
    /// ``armLearn(zoneID:configuration:)``. Ein bereits **beendeter**
    /// Lernvorgang blockiert nichts.
    @discardableResult
    public mutating func startLearnDraft(
        role: ZoneRole,
        configuration: ZoneLearningConfiguration = .default
    ) -> LearnDraftStartOutcome {
        if let learnDraft, learnDraft.isCollecting {
            return .alreadyDrafting
        }
        if let learning, learning.isCollecting {
            return .blockedByZoneLearning(zoneID: learning.zoneID)
        }
        learnDraft = LearnDraft(role: role, configuration: configuration)
        return .started
    }

    /// Beendet das Sammeln des Entwurfs und lässt den Kandidaten
    /// berechnen. **Schreibt nichts** -- das tut erst
    /// ``applyLearnDraftCandidate()``.
    public mutating func finishLearnDraft() {
        guard learnDraft?.isCollecting == true else { return }
        learnDraft?.finish()
    }

    /// Bricht einen sammelnden Entwurf mit benanntem Grund ab. Ein
    /// bereits gefallenes Ergebnis bleibt **unverändert stehen** --
    /// dieselbe Regel wie bei ``cancelLearn(_:)``.
    public mutating func cancelLearnDraft(_ reason: ZoneLearningCancellation = .operatorCancelled) {
        guard learnDraft?.isCollecting == true else { return }
        learnDraft?.cancel(reason)
    }

    /// Verwirft den Entwurf samt Ergebnis vollständig.
    public mutating func discardLearnDraft() {
        learnDraft = nil
    }

    /// Wertet ein Fokusereignis der Ansicht aus (SICK-032c3a, Abschnitt
    /// 3) und leitet es an den Fokuszustand des laufenden Entwurfs
    /// weiter. Ohne Entwurf wirkungslos und ``LearnFocusState/Decision/doNothing``.
    @discardableResult
    public mutating func applyLearnDraftFocusInput(
        _ input: LearnFocusState.Input
    ) -> LearnFocusState.Decision {
        guard learnDraft != nil else { return .doNothing }
        return learnDraft!.applyFocusInput(input)
    }

    /// Schreibt einen validen Entwurfskandidaten als **neue,
    /// ausgewählte, ausgeschaltete** Zone in die eine Zonenwahrheit --
    /// der **einzige** Übergang eines Entwurfs in ``zones``.
    ///
    /// Übernimmt dieselbe Regel wie ``applyLearnCandidate()``:
    /// Aktiviert nichts, weist keinen Slot zu, erzeugt kein Gate und
    /// startet kein Audio -- das bleiben eigene Handgriffe. Der Entwurf
    /// ist nach einer erfolgreichen Übernahme **verbraucht**
    /// (``learnDraft`` wird `nil`): Eine zweite Übernahme desselben
    /// Vorgangs trifft deshalb strukturell ``LearnDraftApplyOutcome/notDrafting``,
    /// nie eine zweite Zone.
    @discardableResult
    public mutating func applyLearnDraftCandidate() -> LearnDraftApplyOutcome {
        guard let draft = learnDraft else { return .notDrafting }
        guard let candidate = draft.candidate else { return .noCandidate(draft.state) }
        let id = addZone(candidate)
        learnDraft = nil
        return .applied(id, candidate)
    }

    /// Bewertet **jede** Zone unabhängig gegen `profile` -- ein leeres
    /// Ergebnis, solange (noch) kein echtes Profil vorliegt
    /// (SICK-014-Auftrag: „ohne aktuelles B0-Profil ruhig und eindeutig
    /// bleiben", „kein alter oder vorhergesagter Wert"). Reine
    /// Funktion, kein zwischengespeichertes Ergebnis -- ruft bei jedem
    /// Aufruf `Zone.evaluate(against:)` frisch auf `profile` auf, nie
    /// auf einem vorherigen Profil.
    ///
    /// **Auch deaktivierte Zonen werden bewertet** (SICK-030b1). Das ist
    /// Anzeige, keine Klangerzeugung: Wer eine Zone einrichtet, soll
    /// sehen, was sie täte, **bevor** er sie einschaltet. Die Trennung
    /// liegt eine Schicht tiefer — `ThereminRuntime` filtert die
    /// deaktivierten heraus, bevor die Spielpipeline sie sieht.
    public func evaluations(against profile: B0ScanProfile?) -> [EditableZone.ID: ZoneEvaluationResult] {
        guard let profile else { return [:] }
        return Dictionary(uniqueKeysWithValues: zones.map { ($0.id, $0.zone.evaluate(against: profile)) })
    }
}
