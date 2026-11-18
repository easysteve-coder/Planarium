import Combine
import PlanariumInput
import SickPLSMacTransport
import SickPLSCommissioning
import SickPLSCommissioningControl
import SickPLSCore
import SickPLSControlCore
import SickPLSMonitorKit

@MainActor public final class ScannerWorkspaceModel: ObservableObject {

    /// Die eine Scanner-Sitzung.
    ///
    /// Öffentlich, damit die Oberfläche ihren Zustand **lesend**
    /// darstellen kann — **verbunden und getrennt wird seit SICK-030a1
    /// ausschließlich über diesen Koordinator**; ein direkter Aufruf von
    /// `session.connect`/`session.disconnect` im App-Ziel lässt
    /// `PerformanceSessionBoundaryTests` fehlschlagen.
    public let input: InputOwner
    public var session: RXSession { input.session }

    /// Die einzige Wahrheit über Auswahl, Entwurf und historische Zonen.
    @Published public var editorState = ZoneEditorState()

    /// Wie viele Anzeige-/Referenzbatches modellseitig empfangen wurden;
    /// nicht die Zahl der einzeln an Q gelieferten Klangprofile.
    public private(set) var deliveredProfileBatches = 0

    /// Wie viele Anzeige-/Referenzbatches **mehr als ein** gültiges
    /// B0-Profil enthielten. Diese Oberfläche zeigt nur das letzte Profil;
    /// der Klangweg erhält unabhängig davon jedes Profil direkt aus RX.
    /// Das ist kein Zähler verlorener Klangprofile.
    public private(set) var readsWithSeveralProfiles = 0

    /// Steuerpfad-Latenz, bewusst nicht `@Published`: Die Diagnose liest
    /// diese bereits vorhandene Koordinatorbeobachtung höchstens zweimal je
    /// Sekunde, während die Messwerte intern je Profil weiterlaufen.

    /// Die eine Referenzmessung am selben Profilweg wie Klangerzeugung und
    /// Lernen. Vor dem ersten Profil steht die sichere Anzeigevorgabe 180;
    /// sobald die Punktzahl bekannt ist, wird die Mitte des ersten Profils
    /// gewählt (361 -> 180, 180 -> 90, 90 -> 45), sofern der Bedienende
    /// vorher keinen Index ausdrücklich gewählt hat.
    @Published public private(set) var referenceMeasurement: ReferenceMeasurementModel

    private var referenceIndexWasExplicitlySelected = false
    private var referenceProfileSizeWasResolved = false

    private var profileSubscription: AnyCancellable?
    private var portReleaseSubscription: AnyCancellable?
    /// Das zuletzt über die **aktuell verbundene, noch gültige**
    /// Messsitzung empfangene echte Profil -- oder `nil`, solange keine
    /// noch gültige Sitzung eines geliefert hat (SICK-032c3a-K1,
    /// Abnahmeblocker 3).
    ///
    /// **Bewusst getrennt von `session.state.lastProfile`:** Das bleibt
    /// nach einem unerwarteten Stromende für Diagnose/Anzeige bewusst
    /// stehen (SICK-032b2, `DiagnosticsView`). Der Learn-Fokus darf
    /// dieses veraltete Profil aber nicht als aktuell ansehen -- sonst
    /// zeigte ein frisch gestarteter Entwurf noch den relevanten Bereich
    /// einer bereits beendeten Sitzung (Profil empfangen ->
    /// unerwartetes Stromende -> neuer Entwurf, noch bevor die nächste
    /// Sitzung ein Profil geliefert hat). Diese Kopie wird deshalb bei
    /// **jedem** tatsächlichen Verbindungsende (``notePortReleased()`` --
    /// ausdrückliches Trennen, unerwartetes Stromende und gescheitertes
    /// Öffnen gleichermaßen, siehe dessen Kopfkommentar) auf `nil`
    /// gesetzt, unabhängig davon, ob gerade ein Entwurf läuft.
    ///
    /// **SICK-032c3a-K2:** Beim **ausdrücklichen** ``disconnect()`` reicht
    /// das allein nicht -- `notePortReleased()` feuert dort erst nach dem
    /// echten, asynchronen `close(2)` auf dem Lesethread. Dazwischen liegt
    /// ein Zeitfenster, in dem die **logische** Messsitzung für Bedienung
    /// und Learn bereits beendet ist (derselbe Moment, der auch einen
    /// sammelnden Lernvorgang sofort abbricht), der Deskriptor aber noch
    /// offen ist. Ein in diesem Fenster gestarteter neuer Entwurf hätte
    /// sonst weiter das Profil der **bereits beendeten** Sitzung gesehen
    /// -- ein Widerspruch zum K1-Ziel „aktuell verbundene, noch gültige
    /// Messsitzung" (Supervisor-Befund, `review-sick-032c3a-k1.md`).
    /// `disconnect()` invalidiert diese Kopie deshalb **zusätzlich sofort**,
    /// sofern dort eine gehaltene Sitzung beendet wird; `notePortReleased()`
    /// bleibt als idempotenter Auffangweg für jedes andere Verbindungsende
    /// unverändert bestehen.
    ///
    /// **Kein zweites Profilabonnement und keine Kopie im Draft:** Diese
    /// Kopie entsteht ausschließlich in ``receive(_:)``, derselben einen
    /// Zustellung, die auch Klangerzeugung und Lernen speist -- als
    /// `ScanProfileBatch` statt als nacktem Profil, damit die Zustellung
    /// dieselbe Typgrenze wie ``receive(_:)``s Parameter behält.
    private var currentSessionProfileBatch: ScanProfileBatch?

    public convenience init(session: RXSession? = nil) { self.init(input: InputOwner(session: session)) }
    public init(input: InputOwner) {
        self.input = input
        referenceMeasurement = try! ReferenceMeasurementModel(index: 180)
        input.referenceMeasurementLineProvider = { [weak self] in
            guard let self else { return "Reference measurement: not available." }
            return ReferenceMeasurementPresentation.describe(self.referenceMeasurement)
        }
        profileSubscription = session.performanceProfiles.sink { [weak self] batch in self?.receive(batch) }
        portReleaseSubscription = input.$portOwner.removeDuplicates().dropFirst().sink { [weak self] owner in
            if owner == .free { self?.notePortReleased() }
        }
    }
    public var portOwner: SerialPortOwner { input.portOwner }
    public var isAwaitingPortRelease: Bool { input.isAwaitingPortRelease }
    public var verifiedBaudRate: SerialPortBaudRate? { input.verifiedBaudRate }
    public var portAccessNotice: PortAccessNotice? { input.portAccessNotice }
    public var portOwnershipChanges: AnyPublisher<SerialPortOwner, Never> { input.$portOwner.eraseToAnyPublisher() }
    public var measurementSessionStatus: MeasurementSessionStatus { input.measurementSessionStatus }
    public var measurementSessionStatusChanges: AnyPublisher<MeasurementSessionStatus, Never> { input.measurementSessionStatusChanges }
    public var measurementStreamEvidence: MeasurementStreamEvidence { input.measurementStreamEvidence }
    public var referenceMeasurementLine: String { ReferenceMeasurementPresentation.describe(referenceMeasurement) }
    @discardableResult public func connect(portPath: String, baudRate: SerialPortBaudRate) -> MonitorConnectOutcome { input.connect(portPath: portPath, baudRate: baudRate) }
    @discardableResult public func connectDevelopment(portPath: String, baudRate: SerialPortBaudRate) -> MonitorConnectOutcome { input.connectDevelopment(portPath: portPath, baudRate: baudRate) }
    @discardableResult public func connectSimulation(serviceName: String, opener: any ScanByteStreamOpening) -> SimulationConnectOutcome { input.connectSimulation(serviceName: serviceName, opener: opener) }
    public func disconnect() {
        if session.isPortHeld { currentSessionProfileBatch = nil; endLearningBecauseConnectionEnded(); referenceMeasurement.stop() }
        input.disconnect()
    }
    public func requestCommissioningAccess() -> CommissioningAccessOutcome { input.requestCommissioningAccess() }
    public func commissioningRunReadiness(portPath: String) -> CommissioningRunReadiness { input.commissioningRunReadiness(portPath: portPath) }
    public func completeCommissioning(with report: CommissioningStepReport) -> CommissioningCompletionOutcome { input.completeCommissioning(with: report) }
    public func finishCommissioning(verifiedBaudRate: SerialPortBaudRate? = nil) { input.finishCommissioning(verifiedBaudRate: verifiedBaudRate) }
    public func requestSimulationControlAccess(endpoint: SimulationEndpoint, job: SimulationControlJob) -> SimulationControlAccessOutcome { input.requestSimulationControlAccess(endpoint: endpoint, job: job) }
    public func completeSimulationControl(_ completion: SimulationControlCompletion) -> SimulationControlReleaseOutcome { input.completeSimulationControl(completion) }
    /// Nur für Tests: belegt, dass es genau ein, und nach dem Freigeben
    /// kein, Abonnement gibt.
    var hasActiveProfileSubscription: Bool { profileSubscription != nil }

    /// Startet die Referenzmessung; jeder Start beginnt mit einer leeren Reihe.
    public func startReferenceMeasurement() {
        referenceMeasurement.start()
    }

    /// Hält die Referenzmessung an; die bisherige Reihe bleibt sichtbar.
    public func stopReferenceMeasurement() {
        referenceMeasurement.stop()
    }

    /// Wählt einen Index, ohne ungültige Werte stillschweigend zu klemmen.
    public func selectReferenceIndex(_ index: Int) throws {
        try referenceMeasurement.selectIndex(index)
        referenceIndexWasExplicitlySelected = true
    }

    /// Nur für Tests: dasselbe für das Freigabe-Abonnement.
    var hasActivePortReleaseSubscription: Bool { portReleaseSubscription != nil }

    // MARK: - Modellseitige Profilzustellung

    /// Der einzige modellseitige Profilweg für Lernen und Referenzmessung.
    ///
    /// Läuft auf dem Main Thread (die Sitzung stellt dort zu) und
    /// **ohne jede SwiftUI-Beteiligung** — es braucht weder ein Fenster
    /// noch einen Renderdurchlauf.
    private func receive(_ batch: ScanProfileBatch) {
        deliveredProfileBatches += 1
        if batch.didDropEarlierProfiles {
            readsWithSeveralProfiles += 1
        }
        // SICK-032c3a-K1: die aktuelle Sitzung hat jetzt ein Profil --
        // siehe ``currentSessionProfileBatch``s Kopfkommentar.
        currentSessionProfileBatch = batch
        // **Derselbe Batch, kein zweiter Profilweg** (SICK-030c): Ein
        // armierter Lernvorgang bekommt genau dieses Profil, und zwar
        // über das bestehende Profilabonnement. Ein zweites Abonnement oder Timer
        // oder eine SwiftUI-Weiterleitung sind ausgeschlossen; ohne
        // armierten Vorgang ist der Aufruf wirkungslos.
        //
        // Er verändert `zones` nicht, löst also auch keinen Abgleich der
        // Rollenzuordnung im `didSet` aus.
        if editorState.learning?.isCollecting == true || editorState.learnDraft?.isCollecting == true {
            editorState.ingestLearningProfile(batch.profile)
        }
        resolveReferenceIndexIfNeeded(for: batch.profile)
        if referenceMeasurement.isRunning { referenceMeasurement.record(batch.profile) }
    }


    /// Die Profilpunktzahl ist erst hier bekannt. Ein einmal gewählter
    /// Bedienindex bleibt erhalten; andernfalls wird die Profilmitte für
    /// diese Koordinatorinstanz genau einmal aus dem ersten Profil bestimmt.
    private func resolveReferenceIndexIfNeeded(for profile: B0ScanProfile) {
        guard !referenceProfileSizeWasResolved else { return }
        referenceProfileSizeWasResolved = true
        guard !referenceIndexWasExplicitlySelected else { return }
        let midpoint = min(profile.measurements.count / 2, referenceIndexMaximum)
        // Nur ein **echter** Indexwechsel darf die Reihe verwerfen.
        // `ReferenceMeasurementModel.selectIndex` verwirft sie
        // ausdrücklich; bei gleicher Profilgröße wäre das ein Verlust ohne
        // Grund. Bei anderer Profilgröße ist das Verwerfen dagegen richtig:
        // die alte Reihe gehört zu einem anderen Strahl.
        guard midpoint != referenceMeasurement.selectedIndex else { return }
        try? referenceMeasurement.selectIndex(midpoint)
    }

    // MARK: - Weitergereichte Bedienung

    /// Ausdrückliches Verbinden — **nie automatisch**, und es startet
    /// keine Audioausgabe.
    ///
    /// **Erst beanspruchen, dann öffnen** (SICK-030a1): Hält das
    /// Commissioning den Port oder steht ein Schließen noch aus, wird
    /// der Versuch **sichtbar verweigert** und die Sitzung nicht einmal
    /// angefasst.
    ///
    /// Geöffnet wird mit der vom Besitzmodell gelieferten Rate — nach
    /// einer belegten Verifikation ist das die **verifizierte** und
    private func notePortReleased() {
        currentSessionProfileBatch = nil
        endLearningBecauseConnectionEnded()
        referenceMeasurement.stop()
        referenceProfileSizeWasResolved = false
    }
    private func endLearningBecauseConnectionEnded() {
        if editorState.learning?.isCollecting == true {
            editorState.cancelLearn(.disconnected)
        }
        // **SICK-032c3a:** Derselbe Schutz gilt für den vorzonalen
        // Lernentwurf -- er ist von ``learning`` vollständig unabhängig
        // und braucht deshalb einen eigenen Aufruf, keinen gemeinsamen
        // Zustand.
        if editorState.learnDraft?.isCollecting == true {
            editorState.cancelLearnDraft(.disconnected)
        }
    }

    // MARK: - Zonenbedienung (SICK-032c1)
    //
    // **Der produktive Weg jeder Zonenänderung.** Bis hierher konnte die
    // Oberfläche `editorState` über ein SwiftUI-`Binding` selbst
    // verändern; fachlich ging das gut (das `didSet` oben gleicht die
    // Rollenzuordnung ab), aber es war ein **zweiter Weg** neben diesem
    // Modell, und ein Ein/Aus-Schalter, der nur einen lokalen Wert setzt,
    // wäre dort nicht mehr zu unterscheiden gewesen.
    //
    // Seit SICK-032c1 laufen Anlegen, Auswählen, Ein/Aus, Entfernen,
    // Griffe und Kartenfelder ausschließlich über die Methoden unten —
    // `PerformanceSessionBoundaryTests` lässt `swift test` fehlschlagen,
    // sobald im App-Ziel wieder ein direkter `editorState`-Aufruf steht.

    /// Der Anzeigezustand **aller** Zonen, in Editorreihenfolge.
    ///
    /// Die vier Angaben je Zone bleiben getrennt (siehe
    /// ``ZoneInsertStatus``); zusammengelegt würde genau die
    /// Unterscheidung verschwinden, die Auflage **D4** verlangt.
    ///
    /// **Die Live-Angabe ist reine Messung:** Sie entsteht bei jedem
    /// Aufruf frisch aus ``SickPLSMonitorKit/ZoneEditorState/evaluations(against:)``
    /// auf dem **gerade** vorliegenden Profil — kein gespeicherter Wert,
    /// keine Prognose. Die Prognose der Laufzeitbrücke ist ein anderer
    /// Pfad und erreicht diese Anzeige nicht.
    public var zoneInserts: [ZoneInsertStatus] {
        let profile = session.state.lastProfile
        let evaluations = editorState.evaluations(against: profile)
        let hasProfile = profile != nil
        return editorState.zones.map { zone in
            ZoneInsertStatus(
                id: zone.id,
                zone: zone.zone,
                isSelected: zone.id == editorState.selectedZoneID,
                activation: ZoneActivation(isEnabled: zone.isEnabled),
                live: ZoneLiveStatus.of(zone.id, in: evaluations, hasProfile: hasProfile),
                shape: zone.shape
            )
        }
    }

    /// Der Anzeigezustand der ausgewählten Zone — die Grundlage der
    /// Einstellkarte.
    public var selectedZoneInsert: ZoneInsertStatus? {
        guard let id = editorState.selectedZoneID else { return nil }
        return zoneInserts.first { $0.id == id }
    }

    /// Ersetzt alle Zonen (Presetladen, SICK-037). Das `didSet` gleicht
    /// die Rollenzuordnung ab; startet nichts.
    public func loadZones(_ zones: [EditableZone]) {
        editorState.replaceZones(zones)
    }

    /// Der Entwurf der ausgewählten Zone (die vier präzisen Grenzen).
    ///
    /// **Kein zweiter Entwurf:** Die Karte bindet auf diesen Wert und
    /// schreibt über ``updateZoneDraft(_:)``/``commitZoneDraft()``
    /// zurück. Eine eigene Kopie in der Ansicht wäre ein zweiter
    /// Schreiber neben den Griffen im Messfeld (Auflage **D3**).
    public var zoneDraft: ZoneDraft? { editorState.draft }

    /// Legt eine neue Zone mit gewählter Rolle an -- **seit SICK-032c3a
    /// über einen Lernentwurf, nicht mehr sofort**.
    ///
    /// Bis SICK-032c3a erzeugte dieser Aufruf sofort eine `Zone` mit den
    /// erfundenen Grenzen `index 0,25...0,75`/`raw 1000...4000`
    /// (`NewZoneDefaults`) -- weit am tatsächlichen Arbeitsbereich
    /// vorbei (SICK-012: `21...169`). **Dieser produktive Anlegeweg
    /// nimmt keine Zonengrenzen mehr vorweg:** Er delegiert unverändert
    /// an ``startLearnDraft(role:)`` -- die neue Zone existiert danach
    /// zunächst nur als Rolle plus laufender Lernentwurf, bis ein echter
    /// Kandidat ausdrücklich übernommen wird
    /// (``applyLearnDraftCandidate()``).
    ///
    /// Bewusst **derselbe Methodenname und dieselbe App-Bindung**
    /// (`ZoneInsertsView`s „+ Zone"-Knopf) -- die sichtbare
    /// SwiftUI-Komposition des neuen Ablaufs folgt in SICK-032c3b;
    /// bis dahin bleibt der Rückgabewert lediglich weniger nützlich
    /// (kein sofortiges `EditableZone.ID` mehr), löst aber keine
    /// Zonenerzeugung mit erfundenen Werten mehr aus.
    @discardableResult
    public func addZone(role: ZoneRole) -> LearnDraftStartOutcome {
        startLearnDraft(role: role)
    }

    // MARK: - Vorzonales Lernen für eine neue Zone (SICK-032c3a)
    //
    // Fünf Methoden nach demselben Muster wie das bestehende Hand-Learn
    // einer bereits vorhandenen Zone (SICK-032c2) -- sie reichen jeweils
    // genau einen Bedienschritt an ``SickPLSMonitorKit/ZoneEditorState``
    // weiter. Kein zweiter Profileingang: Der Entwurf wird über dieselbe
    // ``receive(_:)``-Zustellung gefüttert wie Lernen und Runtime.

    /// Die letzte Rückmeldung zu einem Bedienschritt des **vorzonalen**
    /// Lernentwurfs (SICK-032c3b) -- ein **eigenes** Feld, getrennt von
    /// ``zoneLearningNotice`` (Lernen einer bereits vorhandenen Zone):
    /// Beide Karten können gleichzeitig sichtbar sein (SICK-032c3a-K1
    /// erlaubt genau eine der beiden zu **sammeln**, nicht, dass nur
    /// eine Karte gezeigt wird), und ihre Rückmeldungen dürfen sich nicht
    /// gegenseitig überschreiben. Verschwindet **nur** durch den
    /// nächsten Bedienschritt an derselben Stelle, nie durch Zeitablauf
    /// -- dieselbe Regel wie ``zoneLearningNotice``.
    @Published public private(set) var learnDraftNotice: ZoneLearningNotice?

    /// Startet einen neuen, **vorzonalen** Lernentwurf für `role` -- oder
    /// startet einen bereits beendeten Entwurf neu.
    @discardableResult
    public func startLearnDraft(role: ZoneRole) -> LearnDraftStartOutcome {
        let outcome = editorState.startLearnDraft(role: role, configuration: learningConfiguration)
        learnDraftNotice = outcome.notice
        return outcome
    }

    /// Beendet das Sammeln des laufenden Entwurfs ausdrücklich und lässt
    /// den Kandidaten rechnen. **Schreibt nichts** -- das tut erst
    /// ``applyLearnDraftCandidate()``.
    public func finishLearnDraft() {
        editorState.finishLearnDraft()
        learnDraftNotice = nil
    }

    /// Bricht den laufenden Entwurf ab. Es entsteht keine Zone.
    public func cancelLearnDraft() {
        editorState.cancelLearnDraft(.operatorCancelled)
        learnDraftNotice = nil
    }

    /// Verwirft ein beendetes Entwurfsergebnis -- Vorschlag, Verweigerung,
    /// Abbruch oder Fehlschlag.
    public func discardLearnDraft() {
        editorState.discardLearnDraft()
        learnDraftNotice = nil
    }

    /// Übernimmt den Vorschlag des laufenden Entwurfs als neue,
    /// ausgewählte, weiterhin **ausgeschaltete** Zone -- der einzige
    /// Übergang eines Entwurfs in die Zonenliste.
    @discardableResult
    public func applyLearnDraftCandidate() -> LearnDraftApplyOutcome {
        let outcome = editorState.applyLearnDraftCandidate()
        learnDraftNotice = outcome.notice
        return outcome
    }

    /// Ergebnis eines **atomar gekoppelten** Fokusversuchs
    /// (SICK-032c3a-K1, Abnahmeblocker 4) -- die einzige sichere
    /// Integrationsgrenze für SICK-032c3b: Entscheidung
    /// (``LearnFocusState``) und tatsächlich berechneter Bereich
    /// (``ScanFieldFocusArea``) laufen hier **nie** auseinander. Ein
    /// roher Aufruf, der den Einmalzustand ohne einen wirklich
    /// anwendbaren Bereich verbraucht oder sperrt, ist über diese Grenze
    /// nicht möglich -- ``resolveLearnDraftFocus(_:within:)`` ist
    /// deshalb der einzige öffentliche Weg, ein ``LearnFocusState/Input``
    /// an den laufenden Entwurf zu melden.
    public enum LearnDraftFocusOutcome: Equatable, Sendable {
        /// Ein Ausschnitt wurde berechnet **und** die Entscheidung sagt
        /// „jetzt anwenden" -- der Aufrufer setzt den Ausschnitt jetzt.
        case focus(ScanFieldFocusArea.Result)
        /// Es gibt gerade nichts, das sich fokussieren ließe (kein
        /// aktuelles Profil, kein brauchbarer Messwert darin, oder das
        /// Fenster ließ sich geometrisch nicht bilden). Der
        /// Einmalzustand bleibt **unverändert** -- bei
        /// ``LearnFocusState/Input/measurementAvailable`` unverbraucht,
        /// bei ``LearnFocusState/Input/explicitFitRequested`` ungesperrt.
        case nothingToFocus(ScanFieldFocusArea.Refusal)
        /// Ein Bereich wäre berechenbar gewesen, die Entscheidung sagt
        /// aber „jetzt nicht" (schon automatisch fokussiert, oder durch
        /// manuelle Navigation gesperrt).
        case doNothing
        /// Es läuft gerade kein Entwurf.
        case noDraft
    }

    /// Wertet ein Fokusereignis der Ansicht **atomar gekoppelt** an den
    /// laufenden Entwurf aus (SICK-032c3a, Abschnitt 3 -- automatischer
    /// Vorschlag, ausdrückliches „Einpassen", manuelle Navigation).
    ///
    /// **Manuelle Navigation sperrt sofort und unbedingt** -- sie braucht
    /// kein Profil und keinen berechenbaren Bereich, um zu sperren
    /// (Auftragstext, SICK-032c3a-K1 Abschnitt 4, letzter Punkt). Für die
    /// beiden anderen Eingaben wird **zuerst** ``learnDraftFocusArea(within:)``
    /// berechnet; nur bei einem tatsächlichen ``ScanFieldFocusArea/Result``
    /// wird ``SickPLSMonitorKit/ZoneEditorState/applyLearnDraftFocusInput(_:)``
    /// überhaupt gerufen -- eine Verweigerung verbraucht und sperrt
    /// nichts. Die tatsächliche **Anwendung** eines Ausschnitts bleibt
    /// Sache der Ansicht (SICK-032c3b); dieser Koordinator liefert nur
    /// den bereits berechneten ``ScanFieldFocusArea/Result``.
    @discardableResult
    public func resolveLearnDraftFocus(
        _ input: LearnFocusState.Input,
        within current: ScanPlaneViewport = .fullField
    ) -> LearnDraftFocusOutcome {
        guard editorState.learnDraft != nil else { return .noDraft }

        if input == .manualNavigation {
            editorState.applyLearnDraftFocusInput(.manualNavigation)
            return .doNothing
        }

        guard let outcome = learnDraftFocusArea(within: current) else { return .noDraft }
        switch outcome {
        case .refused(let refusal):
            return .nothingToFocus(refusal)
        case .focused(let result):
            let decision = editorState.applyLearnDraftFocusInput(input)
            return decision == .focusNow ? .focus(result) : .doNothing
        }
    }

    /// Der relevante Rohwertbereich und die planare Fokusgeometrie für
    /// den laufenden Entwurf, aus dem **zuletzt über die aktuelle
    /// Sitzung empfangenen** echten Profil abgeleitet (SICK-032c3a,
    /// Abschnitt 2; SICK-032c3a-K1, Abnahmeblocker 3). `nil` ohne
    /// laufenden Entwurf.
    ///
    /// **Reine, wiederholt aufrufbare Anzeigeableitung** -- anders als
    /// ``resolveLearnDraftFocus(_:within:)`` verändert dieser Aufruf nie
    /// den ``LearnFocusState`` des Entwurfs; er beantwortet nur „was
    /// wäre der relevante Bereich jetzt", beliebig oft.
    ///
    /// `within` ist ein reiner Werkzeugempfänger (wie bei
    /// ``SickPLSMonitorKit/ScanFieldFit/viewport(fitting:within:)``) --
    /// das Ergebnis ist unabhängig vom aktuell sichtbaren Ausschnitt der
    /// Ansicht.
    public func learnDraftFocusArea(
        within current: ScanPlaneViewport = .fullField
    ) -> ScanFieldFocusArea.Outcome? {
        guard let draft = editorState.learnDraft else { return nil }
        return ScanFieldFocusArea.area(
            forProfile: currentSessionProfileBatch?.profile, candidate: draft.candidate, within: current
        )
    }

    /// Schaltet eine Zone ein oder aus — **der produktive Weg**.
    ///
    /// Es entsteht **kein** neuer Gate-Sonderweg: Eine ausgeschaltete
    /// Zone erreicht die Spielpipeline nicht, der Steuervertrag meldet
    /// für den weiterhin belegten Slot `.inactive`, und der Adapter macht
    /// daraus **genau ein** Gate-Off — beim nächsten echten Profil und
    /// nur, wenn er zuvor selbst ein Gate-On gesetzt hatte (SICK-030b1,
    /// Auflage **A6**). Wiedereinschalten erzeugt **kein** Gate-On; dafür
    /// braucht es einen echten Messwert über der Schwelle. Und es startet
    /// nichts: Diese Methode fasst den Audiodienst nicht an.
    @discardableResult
    public func setZone(_ id: EditableZone.ID, isEnabled: Bool) -> Bool {
        editorState.setZone(id, isEnabled: isEnabled)
    }

    /// Entfernt eine Zone aus dem Editor.
    @discardableResult
    public func removeZone(_ id: EditableZone.ID) -> Bool {
        editorState.removeZone(id)
    }

    /// Wählt eine Zone zum Bearbeiten aus (oder hebt die Auswahl auf).
    ///
    /// Bewusst **nicht** `selectZone` genannt — das ist die
    /// Slot-Zuweisung und etwas ganz anderes.
    public func selectZoneForEditing(_ id: EditableZone.ID?) {
        editorState.select(id)
    }

    /// Wendet einen fertigen Bearbeitungsbefehl der Griffe im Messfeld an.
    @discardableResult
    public func applyZoneGeometry(
        _ command: ZoneGeometryCommand
    ) -> ZoneEditorState.ZoneGeometryApplication {
        editorState.apply(command)
    }

    /// Übernimmt einen Zwischenstand der Kartenfelder — noch **ohne**
    /// Wirkung auf die Zone.
    public func updateZoneDraft(_ draft: ZoneDraft) {
        editorState.updateDraft(draft)
    }

    /// Übernimmt den Entwurf in die **eine** Zonenwahrheit.
    @discardableResult
    public func commitZoneDraft() -> Bool {
        editorState.commitDraft()
    }

    // MARK: - Geführtes Hand-Learn (SICK-032c2)
    //
    // **Ausschließlich der vorhandene Lernpfad.** Diese fünf Methoden
    // reichen jeweils genau einen Bedienschritt an den seit SICK-030c
    // geprüften `ZoneEditorState` weiter. Hier entsteht kein zweiter
    // Profileingang, kein Timer, kein eigener Zähler und keine zweite
    // Auswertung — der Profilstrom bleibt der eine aus ``receive(_:)``.
    //
    // Keine dieser Methoden startet oder stoppt Audio, erzeugt ein Gate,
    // verändert Viewport, Geometrie oder Mapping.

    /// Der Anzeigezustand des Lernbereichs der **ausgewählten** Zone.
    ///
    /// `nil`, solange keine Zone ausgewählt ist — dann gibt es auch keine
    /// Karte, in der der Bereich stünde.
    public var selectedZoneLearning: ZoneLearningPresentation? {
        guard let insert = selectedZoneInsert else { return nil }
        return ZoneLearningPresentation(
            zoneID: insert.id,
            isZoneEnabled: insert.activation.isOn,
            learning: editorState.learning,
            learnDraftIsCollecting: editorState.learnDraft?.isCollecting == true,
            configuration: learningConfiguration
        )
    }

    /// Der **eine** testbare Darstellungsvertrag aus ``learnDraftPresentation``
    /// und ``learnDraftNotice`` (SICK-032c3b-K1, Abnahmeblocker 1) -- er
    /// entscheidet, ob der Hinweis in die Draftkarte oder in einen
    /// Fallback-Host im Messfeld-/Zonenbereich gehört. Die Oberfläche
    /// liest für diese Entscheidung ausschließlich diesen Wert, nie
    /// ``learnDraftNotice`` und ``learnDraftPresentation`` getrennt
    /// nebeneinander.
    public var learnDraftSurface: LearnDraftSurface {
        LearnDraftSurface(presentation: learnDraftPresentation, notice: learnDraftNotice)
    }

    /// Der Anzeigezustand des laufenden vorzonalen Lernentwurfs
    /// (SICK-032c3a), oder `nil` ohne laufenden Entwurf.
    public var learnDraftPresentation: LearnDraftPresentation? {
        guard let draft = editorState.learnDraft else { return nil }
        let block: LearnDraftBlock?
        if let learning = editorState.learning, learning.isCollecting {
            block = .zoneLearningIsCollecting(zoneID: learning.zoneID)
        } else {
            block = nil
        }
        return LearnDraftPresentation(
            role: draft.role,
            state: draft.state,
            configuration: learningConfiguration,
            block: block,
            focusArea: learnDraftFocusArea()
        )
    }

    /// Die letzte Rückmeldung zu einem Lern-Bedienschritt, oder `nil`.
    ///
    /// Verschwindet **nur** durch den nächsten Bedienschritt an derselben
    /// Stelle (dieselbe Regel wie ``portAccessNotice``), nie durch
    /// Zeitablauf.
    @Published public private(set) var zoneLearningNotice: ZoneLearningNotice?

    /// Die feste Lernkonfiguration.
    ///
    /// **Kein neuer einstellbarer Vorgabewert** (SICK-032c2, Grenze): Die
    /// Karte zeigt sie nur lesbar an. Sie liegt hier als eine Stelle,
    /// damit Anzeige und Armierung nachweislich dieselben Zahlen
    /// benutzen.
    private let learningConfiguration = ZoneLearningConfiguration.default

    /// Startet den Lernvorgang auf der **ausgewählten** Zone.
    ///
    /// Armiert wird ausschließlich über ``SickPLSMonitorKit/ZoneEditorState/armLearn(zoneID:configuration:)``;
    /// die Ablehnung einer eingeschalteten Zone (Auflage **D2**) und die
    /// eines bereits laufenden Vorgangs kommen unverändert von dort.
    @discardableResult
    public func startZoneLearning() -> ZoneLearningArmOutcome {
        guard let id = editorState.selectedZoneID else {
            let outcome = ZoneLearningArmOutcome.unknownZone
            zoneLearningNotice = outcome.notice
            return outcome
        }
        let outcome = editorState.armLearn(zoneID: id, configuration: learningConfiguration)
        zoneLearningNotice = outcome.notice
        return outcome
    }

    /// Beendet das Sammeln ausdrücklich und lässt den Vorschlag rechnen.
    ///
    /// **Schreibt nichts** — das tut erst ``applyZoneLearningCandidate()``.
    /// Es gibt bewusst keinen automatischen Abschluss: kein Timeout, keine
    /// Profilobergrenze.
    public func finishZoneLearning() {
        editorState.finishLearn()
        zoneLearningNotice = nil
    }

    /// Bricht einen laufenden Vorgang ab. Die Zone bleibt unverändert.
    public func cancelZoneLearning() {
        editorState.cancelLearn(.operatorCancelled)
        zoneLearningNotice = nil
    }

    /// Verwirft ein beendetes Ergebnis — Vorschlag, Verweigerung,
    /// Abbruch oder Fehlschlag. Die Zone bleibt unverändert.
    public func discardZoneLearning() {
        editorState.discardLearn()
        zoneLearningNotice = nil
    }

    /// Übernimmt den Vorschlag in **dieselbe, weiterhin ausgeschaltete**
    /// Zone.
    ///
    /// Es wird nichts eingeschaltet und kein Spiel-Slot zugewiesen; die
    /// Rolle bleibt die beim Armieren festgelegte. Jede Abweichung ist
    /// eine benannte Ablehnung aus dem Lernvertrag und lässt die Zone
    /// unverändert.
    @discardableResult
    public func applyZoneLearningCandidate() -> ZoneLearningApplyOutcome {
        let outcome = editorState.applyLearnCandidate()
        zoneLearningNotice = outcome.notice
        return outcome
    }
}

extension ScannerWorkspaceModel: @preconcurrency StandardConnectionCoordinating {}
