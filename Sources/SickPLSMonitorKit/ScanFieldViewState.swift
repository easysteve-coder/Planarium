import PlanariumDomain
import CoreGraphics
import SickPLSCore
import SickPLSControlCore

/// Das gewählte Bedienwerkzeug des Scanfelds (SICK-032b2).
///
/// **Der Zweck ist die Auflösung des Gestenkonflikts.** Im Scanfeld gibt
/// es genau eine Ziehgeste; was sie bedeutet, entscheidet ausschließlich
/// dieser Wert. Ein geschlossenes Enum ohne Vorgabefall zwingt jede
/// künftige Erweiterung, sich einzureihen, statt eine zweite Bedeutung
/// über dieselbe Geste zu legen.
///
/// Scrollrad und Trackpad-Pinch stehen **nicht** hier drin: Sie laufen
/// über einen anderen Eingabekanal und zoomen deshalb in jedem Werkzeug,
/// ohne mit der Ziehgeste zu konkurrieren.
public enum ScanFieldTool: String, CaseIterable, Equatable, Sendable {
    /// Klicken wählt eine Zone aus; ein echter Zug verschiebt den
    /// sichtbaren Ausschnitt. Damit ist das häufigste Navigieren direkt
    /// möglich, ohne vorher ein Werkzeug umzuschalten.
    case selectZone
    /// Ziehen verschiebt den sichtbaren Ausschnitt.
    case pan
    /// Ziehen zieht einen Rahmen auf, auf den gezoomt wird.
    case rectangle
    /// Ziehen bearbeitet die **ausgewählte** Zone -- ihre Fläche
    /// verschiebt sie, ihre vier Griffe verändern je eine Grenze
    /// (SICK-032b3).
    ///
    /// **Ein eigenes, sichtbares Werkzeug und keine versteckte
    /// Sonderregel** („Treffer auf einem Griff schlägt das Verschieben"):
    /// Wer den Ausschnitt verschieben will, soll das auch dann können,
    /// wenn eine Zone gerade unter dem Zeiger liegt, und wer eine Grenze
    /// anfasst, soll sich nicht auf einen unsichtbaren Vorrang verlassen
    /// müssen. Die Leiste sagt jederzeit, was ein Zug bewirkt.
    case editZone

    /// Beschriftung für die Werkzeugleiste. **Der Text entsteht im
    /// Modell, nicht in der Ansicht** (Regel seit SICK-028) -- sonst
    /// hinge er an einer SwiftUI-Datei ohne Testziel.
    public var label: String {
        switch self {
        case .selectZone: return "Select zones"
        case .pan: return "Pan"
        case .rectangle: return "Rectangle"
        case .editZone: return "Edit zone"
        }
    }

    /// Kurze Erklärung für den Hilfetext der Werkzeugleiste.
    public var explanation: String {
        switch self {
        case .selectZone: return "Click selects a zone; drag pans the view."
        case .pan: return "Drag pans the visible view."
        case .rectangle: return "Drag zooms to the drawn rectangle."
        case .editZone:
            return "Drag on the body moves the selected zone; drag on a handle moves one of its four edges."
        }
    }

    /// Zeichnet dieses Werkzeug die Griffe der ausgewählten Zone?
    ///
    /// Eine Eigenschaft des Werkzeugs, keine Abfrage in der Ansicht: So
    /// kann kein zweites Werkzeug versehentlich Griffe anbieten, die es
    /// gar nicht bedient.
    public var showsZoneHandles: Bool {
        switch self {
        case .selectZone, .pan, .rectangle: return false
        case .editZone: return true
        }
    }
}

/// Ein fertig entschiedener Bearbeitungsbefehl für **eine** Zone
/// (SICK-032b3).
///
/// Er trägt alles, was der geprüfte ``ZoneGeometryReducer`` braucht --
/// und **nichts** darüber hinaus: keine Zonenliste, keine Auswahl, keine
/// Rolle, keine Aktivierung. Angewandt wird er ausschließlich über
/// ``ZoneEditorState/apply(_:)``.
///
/// **Die Geometrie stammt aus dem Ausschnitt bei Gestenbeginn**, nicht
/// aus dem aktuellen. Sonst verschöbe ein Zoom mitten in der Geste (über
/// Scrollrad oder Pinch, die auf einem eigenen Eingabekanal liegen) die
/// Umrechnung unter der laufenden Bewegung -- die Zone spränge, obwohl
/// die Hand ruhig blieb. Dieselbe Entscheidung wie beim Verschieben des
/// Ausschnitts (SICK-032b2) und beim eingefrorenen Ausgangsstand des
/// Reducers (SICK-030b2).
public struct ZoneGeometryCommand: Equatable, Sendable {
    public let gesture: ZoneGeometryGesture
    public let start: ZoneGeometryGestureStart
    public let location: CGPoint
    public let geometry: LinearScanFieldGeometry

    public init(
        gesture: ZoneGeometryGesture,
        start: ZoneGeometryGestureStart,
        location: CGPoint,
        geometry: LinearScanFieldGeometry
    ) {
        self.gesture = gesture
        self.start = start
        self.location = location
        self.geometry = geometry
    }
}

/// Ein sichtbarer Hinweis der Scanfeld-Bedienung (SICK-032b2).
///
/// **Die Texte entstehen im Modell**, damit sie geprüft werden können und
/// nicht in einer SwiftUI-Datei ohne Testziel liegen -- dieselbe Regel
/// wie bei `PerformanceNotice` (SICK-028) und `CommissioningNotice`
/// (SICK-030a1). Ein Hinweis verschwindet ausschließlich durch eine
/// **erfolgreiche** Bedienhandlung, nie durch Zeitablauf.
public enum ScanFieldNotice: Equatable, Sendable {
    case fitNeedsProfile
    case fitFoundNoUsableMeasurement
    case rectangleTooSmall
    case viewGeometryUnusable
    /// Im Werkzeug „Zone bearbeiten" gezogen, ohne dass eine Zone
    /// ausgewählt ist (SICK-032b3).
    case editNeedsSelectedZone
    /// Im Werkzeug „Zone bearbeiten" neben der ausgewählten Zone gezogen.
    case editMissedSelectedZone
    /// Ein ausdrückliches „Einpassen" des Learn-Entwurfs
    /// (SICK-032c3b) fand keinen relevanten Bereich -- **verändert
    /// weder Ausschnitt noch Fokuszustand** (dieselbe Regel wie ein
    /// abgelehntes „Messung einpassen").
    case learnFocusUnavailable(ScanFieldFocusArea.Refusal)

    public var message: String {
        switch self {
        case .fitNeedsProfile:
            return "No profile received yet — nothing to fit."
        case .fitFoundNoUsableMeasurement:
            return "The profile contains no usable measurement. The view is unchanged."
        case .rectangleTooSmall:
            return "The drawn rectangle is too small. The view is unchanged."
        case .viewGeometryUnusable:
            return "The view is too small for a pointer position. The view is unchanged."
        case .editNeedsSelectedZone:
            return "No zone selected. Use the Select zones tool first."
        case .editMissedSelectedZone:
            return "The selected zone is not under the pointer. Drag on its body or one of its four handles."
        case .learnFocusUnavailable(let refusal):
            return refusal.operatorText
        }
    }
}

/// Was eine beendete Ziehgeste bewirkt hat (SICK-032b2).
///
/// Geschlossen und benannt, damit die Ansicht nichts ableiten muss:
/// `switch` ohne `default`.
public enum ScanFieldDragOutcome: Equatable, Sendable {
    /// Der Ausschnitt wurde verschoben oder auf den Rahmen gezoomt.
    case viewportChanged
    /// Im Werkzeug „Zonen wählen": Diese Zone ist jetzt auszuwählen --
    /// `nil` wählt ab, genau wie bisher ein Klick ins Leere.
    ///
    /// **Der Zustand hier wählt nicht selbst aus.** Die Zonenwahl gehört
    /// dem `ZoneEditorState`; dieser Wert ist die Weiterleitung, nicht
    /// die Entscheidung.
    case selectZone(EditableZone.ID?)
    /// Die ausgewählte Zone ist zu verändern -- **der Aufrufer wendet den
    /// Befehl auf seinen ``ZoneEditorState`` an**, dieser Zustand tut es
    /// nicht selbst. Er hält keine Zonen und darf keine halten.
    case editZone(ZoneGeometryCommand)
    /// Nichts passiert -- keine laufende Geste, oder die Eingabe war
    /// unbrauchbar (dann steht der Grund in ``ScanFieldViewState/notice``).
    case nothing
}

/// Der gesamte Bedienzustand des zentralen Scanfelds -- **ein reiner
/// Reducer** (SICK-032b2).
///
/// ## Warum das Modell und nicht die Ansicht
///
/// Dieselbe Bauweise wie `ScanSessionState` und `ZoneEditorState`: Die
/// SwiftUI-Ansicht reicht ausschließlich ihre Größe und rohe Punkte
/// weiter und **entscheidet nichts**. Damit ist jede Bedienhandlung ohne
/// gerenderte Ansicht, ohne Gerät und ohne Scanner prüfbar.
///
/// ## Verbindliche Regeln, bei künftigen Änderungen zu erhalten
///
/// 1. **Der Ausschnitt ist reine Ansicht.** Dieser Zustand verändert
///    **nie** eine ``Zone``, einen Entwurf, ein Learn-Ergebnis, ein
///    Mapping oder die Audiosteuerung. Er liest Zonen ausschließlich für
///    die Trefferprüfung und gibt eine Kennung zurück, die der
///    `ZoneEditorState` dann selbst anwendet.
/// 2. **Der Ausschnitt entsteht ausschließlich über die Werkzeuge von
///    ``ScanPlaneViewport``.** Hier wird keine Grenze selbst gerechnet und
///    keine Gültigkeit selbst entschieden -- sonst gäbe es eine zweite
///    Wahrheit darüber, was ein gültiger Ausschnitt ist.
/// 3. **Eine Ziehgeste rechnet aus der Gesamtverschiebung seit ihrem
///    Beginn**, nie delta-akkumuliert. Dafür hält ``DragSession`` die
///    **Momentaufnahme** des Ausschnitts bei Gestenbeginn -- dieselbe
///    Lehre wie beim `ZoneGeometryReducer` (SICK-030b2): Läse die Geste
///    den laufend veränderten Ausschnitt, wanderte der Inhalt bei jedem
///    Ereignis erneut um dieselbe Strecke.
/// 4. **Jede Ablehnung lässt den Ausschnitt unverändert und wird
///    sichtbar** (``notice``), nie still verschluckt.
public struct ScanFieldViewState: Equatable, Sendable {

    /// Der sichtbare Ausschnitt. Startet auf der Gesamtansicht -- ein
    /// engerer Startwert wäre eine Kalibrierungsvermutung (SICK-032b1);
    /// den passenden Ausschnitt liefert stattdessen ``fitToProfile(_:)``
    /// aus echten Messwerten.
    ///
    /// **Seit SICK-032b2c planar** (``ScanPlaneViewport``): ein
    /// kartesisches Fenster in die kanonische Welt, kein Winkel-/
    /// Entfernungsbereich mehr -- siehe
    /// ``LinearScanFieldGeometry`` und `.agent_handoff/task-sick-032b2c.md`.
    public private(set) var viewport: ScanPlaneViewport = .fullField

    /// Das gewählte Bedienwerkzeug. Vorgabe ist die Zonenauswahl, damit
    /// die bisherige Bedienung ohne Umschalten weiter funktioniert.
    public private(set) var tool: ScanFieldTool = .selectZone

    /// Die laufende Ziehgeste, falls eine läuft.
    public private(set) var drag: DragSession?

    /// Der zuletzt entstandene Hinweis -- siehe ``ScanFieldNotice``.
    public private(set) var notice: ScanFieldNotice?

    public init() {}

    /// Zoomfaktor eines Lupenklicks.
    ///
    /// **Dokumentierter Startwert, keine Gerätewahrheit.** `1,4` ist grob
    /// ein Faktor, bei dem zwei Klicks etwa eine Verdopplung ergeben --
    /// spürbar, ohne dass ein einzelner Klick die Orientierung kostet.
    public static let buttonZoomFactor: Double = 1.4

    /// Ein Klick darf auch mit leicht unruhiger Hand eine Auswahl bleiben.
    /// Erst eine sichtbare Bewegung wird im Auswahlwerkzeug zum Pan.
    public static let directPanMinimumDistance: CGFloat = 4

    // Die Umrechnung Scrollereignis -> Zoomfaktor steht seit
    // SICK-032b2b vollständig in `ScanFieldZoomInput`: Einheit,
    // Richtung, Begrenzung und Kennlinie gehören zusammen und sind dort
    // für sich prüfbar. Hier bleibt bewusst **keine** zweite Kennzahl
    // stehen -- sie wäre eine zweite Wahrheit darüber, wie stark ein
    // Scrollereignis wirkt.

    // MARK: - Laufende Geste

    /// Die Momentaufnahme einer laufenden Ziehgeste.
    ///
    /// Sie trägt den Ausschnitt **bei Gestenbeginn** mit (Regel 3): Alles
    /// wird aus der Gesamtverschiebung seit dem Start gerechnet.
    public struct DragSession: Equatable, Sendable {
        /// Das Werkzeug, mit dem die Geste begonnen hat. Ein Umschalten
        /// mitten in der Geste ändert ihre Bedeutung deshalb nicht.
        public let tool: ScanFieldTool
        public let startPoint: CGPoint
        public internal(set) var currentPoint: CGPoint
        /// Der Ausschnitt bei Gestenbeginn.
        public let startViewport: ScanPlaneViewport
        /// Die Weltposition unter dem Startpunkt -- `nil` bei entarteter
        /// Ansichtsgeometrie. **Seit SICK-032b2c die kanonische Welt**,
        /// nicht mehr die Feldkoordinate: Verschieben ist eine affine
        /// Operation im planaren Ausschnitt.
        let startWorldPoint: CGPoint?
        /// Nur im Werkzeug „Zone bearbeiten" belegt: welche Zone in
        /// welchem Zustand angefasst wurde und was die Geste bedeutet.
        ///
        /// **Beides beim Gestenbeginn eingefroren.** Ändert sich die
        /// Zone währenddessen (weil genau diese Geste sie verändert),
        /// bleibt der Ausgangsstand stehen -- sonst wäre jede Bewegung
        /// ein Delta auf dem bereits bewegten Stand (SICK-030b2).
        let zoneGesture: ZoneGeometryGesture?
        let zoneStart: ZoneGeometryGestureStart?
    }

    /// Der aufgezogene Rahmen in Bildschirmkoordinaten, solange das
    /// Werkzeug „Rahmen" zieht -- ausschließlich zum Zeichnen.
    ///
    /// **Seit SICK-032b2c-K2 auf ``canvasRect`` geklammert** (Auftragspunkt
    /// 4, `.agent_handoff/review-sick-032b2c-k1.md`): Ohne die
    /// Klammerung konnte der sichtbare Rahmen in einen unsichtbaren
    /// Letterbox-Rand hineinwachsen, obwohl der Rechenweg (``endDrag``)
    /// dort längst am Canvasrand stehenblieb -- Zeichnung und Rechnung
    /// liefen auseinander. `geometry(in:).canvasClampedScreenPoint(_:)`
    /// ist **dieselbe** Klammerung, die auch
    /// ``LinearScanFieldGeometry/boundedWorldPoint(forScreenPoint:)``
    /// benutzt.
    public func rubberBandRect(in size: CGSize) -> CGRect? {
        guard let drag, drag.tool == .rectangle else { return nil }
        let geo = geometry(in: size)
        let start = geo.canvasClampedScreenPoint(drag.startPoint)
        let current = geo.canvasClampedScreenPoint(drag.currentPoint)
        return CGRect(
            x: Swift.min(start.x, current.x),
            y: Swift.min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    // MARK: - Werkzeugwahl

    /// Wählt das Bedienwerkzeug. Eine laufende Geste wird dabei
    /// **abgebrochen**: Sonst endete sie mit einer anderen Bedeutung, als
    /// sie begonnen hat.
    public mutating func select(tool newTool: ScanFieldTool) {
        drag = nil
        tool = newTool
        notice = nil
    }

    // MARK: - Ausschnittswerkzeuge

    /// Zurück zur Gesamtansicht.
    ///
    /// **Seit SICK-032c3b mit Rückgabewert:** `true`, wenn der Ausschnitt
    /// dadurch tatsächlich verändert wurde -- die Grundlage für
    /// „manuelle Navigation sperrt, Ablehnung/Wirkungslosigkeit nicht"
    /// (`.agent_handoff/task-sick-032c3b.md`, Abschnitt „Manuelle
    /// Navigation sperrt, Ablehnung nicht"). War der Ausschnitt bereits
    /// die Gesamtansicht, ändert sich nichts, und der Aufrufer meldet
    /// entsprechend **keine** manuelle Navigation.
    @discardableResult
    public mutating func showFullField() -> Bool {
        let changed = viewport != .fullField
        drag = nil
        viewport = .fullField
        notice = nil
        return changed
    }

    /// Übernimmt das Ergebnis einer atomar gekoppelten Fokusentscheidung
    /// des vorzonalen Learn-Entwurfs
    /// (`ScannerWorkspaceModel.resolveLearnDraftFocus(_:within:)`,
    /// SICK-032c3b) -- setzt den Ausschnitt auf **genau** `result.viewport`.
    ///
    /// **Die einzige Stelle, die einen von ``ScanFieldFocusArea``
    /// gelieferten Ausschnitt anwendet.** Es gibt hier keine eigene
    /// Ausschnittsrechnung -- der Bereich kommt bereits fertig berechnet
    /// vom Koordinator.
    public mutating func applyLearnFocusResult(_ result: ScanFieldFocusArea.Result) {
        drag = nil
        viewport = result.viewport
        notice = nil
    }

    /// Übernimmt den Ausschnitt eines geladenen Presets (SICK-037): ein
    /// bereits geprüfter `ScanPlaneViewport`, ohne eigene Rechnung.
    /// Beendet einen laufenden Zug und löscht den Hinweis.
    public mutating func applyPresetViewport(_ presetViewport: ScanPlaneViewport) {
        drag = nil
        viewport = presetViewport
        notice = nil
    }

    /// Ein ausdrückliches „Einpassen" des Learn-Entwurfs fand keinen
    /// anwendbaren Bereich -- der Ausschnitt bleibt **unverändert**, nur
    /// der Grund wird sichtbar (SICK-032c3b).
    public mutating func noteLearnFocusRefusal(_ refusal: ScanFieldFocusArea.Refusal) {
        notice = .learnFocusUnavailable(refusal)
    }

    /// Passt den Ausschnitt an das **tatsächlich empfangene** Profil an
    /// (nur Ansicht) -- die Rechnung steht in ``ScanFieldFit``.
    ///
    /// Gibt das Ergebnis zurück, damit die Ansicht melden kann, wie viele
    /// Messpunkte getragen haben; bei einer Verweigerung bleibt der
    /// Ausschnitt unverändert und der Grund steht in ``notice``.
    @discardableResult
    public mutating func fitToProfile(_ profile: B0ScanProfile?) -> ScanFieldFit.Outcome {
        let outcome = ScanFieldFit.viewport(fitting: profile, within: viewport)
        switch outcome {
        case .fitted(let result):
            drag = nil
            viewport = result.viewport
            notice = nil
        case .refused(.noProfile):
            notice = .fitNeedsProfile
        case .refused(.noUsableMeasurement), .refused(.windowRejected):
            notice = .fitFoundNoUsableMeasurement
        }
        return outcome
    }

    /// Lupe: zoomt um die **Mitte** des sichtbaren Ausschnitts, weil ein
    /// Knopf keine Zeigerposition hat.
    ///
    /// **Seit SICK-032c3b mit Rückgabewert** (siehe ``showFullField()``).
    @discardableResult
    public mutating func zoomAtCenter(byFactor factor: Double) -> Bool {
        apply(viewport.zoomed(byFactor: factor, anchorX: viewport.centerX, anchorY: viewport.centerY))
    }

    /// Zoomt um die Weltposition unter dem Zeiger -- die Grundlage für
    /// Scrollrad und Trackpad-Pinch.
    ///
    /// **Seit SICK-032b2c ohne jeden Sonderfall an der Fächerspitze:**
    /// Ein Zoomanker ist jetzt eine kanonische Weltposition, und die
    /// Spitze ist darin ein ganz gewöhnlicher, wohldefinierter Punkt
    /// (der Ursprung) -- kein erfundener Winkel mehr nötig, weil der
    /// Winkel für den Anker überhaupt nicht mehr gebraucht wird (die
    /// SICK-032b2b-Regel „an der Spitze keinen Winkel erfinden" ist damit
    /// strukturell erfüllt, nicht mehr durch eine Fallunterscheidung).
    ///
    /// **Seit SICK-032b2c-K2 über `boundedWorldPoint(forScreenPoint:)`
    /// statt der ungeklammerten Umkehrung:** Ein Zeiger im unsichtbaren
    /// Letterbox-Rand zoomt dadurch um denselben Anker wie einer genau
    /// am sichtbaren Canvasrand, nicht mehr um einen dort nie gezeigten
    /// Weltpunkt.
    ///
    /// **Seit SICK-032c3b mit Rückgabewert** (siehe ``showFullField()``).
    @discardableResult
    public mutating func zoomAtPointer(byFactor factor: Double, at point: CGPoint, in size: CGSize) -> Bool {
        guard let anchor = geometry(in: size).boundedWorldPoint(forScreenPoint: point) else {
            notice = .viewGeometryUnusable
            return false
        }
        return apply(viewport.zoomed(byFactor: factor, anchorX: Double(anchor.x), anchorY: Double(anchor.y)))
    }

    /// Scrollrad und Trackpad-Scrollen: Ein rohes Systemereignis geht
    /// hinein, ``ScanFieldZoomInput`` macht daraus Einheit, Richtung,
    /// Begrenzung und Faktor.
    ///
    /// **Bewusst kein Eingang für eine bereits fertige Strecke oder
    /// einen fertigen Faktor.** Gäbe es den, könnte eine Aufrufstelle
    /// die Einheiten- und Richtungsnormierung umgehen -- genau das war
    /// der Fehler, den SICK-032b2b behebt.
    ///
    /// **Seit SICK-032c3b mit Rückgabewert** (siehe ``showFullField()``).
    @discardableResult
    public mutating func zoomAtPointer(
        byScrollEvent event: ScanFieldScrollEvent, at point: CGPoint, in size: CGSize
    ) -> Bool {
        guard let factor = ScanFieldZoomInput.zoomFactor(for: event) else {
            notice = .viewGeometryUnusable
            return false
        }
        return zoomAtPointer(byFactor: factor, at: point, in: size)
    }

    /// Trackpad-Pinch: `magnification` ist die relative Änderung des
    /// Systemereignisses -- siehe
    /// ``ScanFieldZoomInput/zoomFactor(forMagnification:)``.
    ///
    /// **Seit SICK-032c3b mit Rückgabewert** (siehe ``showFullField()``).
    @discardableResult
    public mutating func zoomAtPointer(byMagnification magnification: Double, at point: CGPoint, in size: CGSize) -> Bool {
        guard let factor = ScanFieldZoomInput.zoomFactor(forMagnification: magnification) else {
            notice = .viewGeometryUnusable
            return false
        }
        return zoomAtPointer(byFactor: factor, at: point, in: size)
    }

    // MARK: - Ziehgeste

    /// Beginnt eine Ziehgeste mit dem gerade gewählten Werkzeug.
    ///
    /// `zones`/`selectedZoneID` werden **ausschließlich gelesen** und nur
    /// im Werkzeug „Zone bearbeiten" überhaupt angefasst -- dort, um den
    /// Ausgangsstand der angefassten Zone einzufrieren.
    public mutating func beginDrag(
        at point: CGPoint,
        in size: CGSize,
        zones: [EditableZone] = [],
        selectedZoneID: EditableZone.ID? = nil
    ) {
        let geo = geometry(in: size)
        // `boundedWorldPoint` statt der ungeklammerten Umkehrung
        // (SICK-032b2c-K2): ``startWorldPoint`` treibt ausschließlich
        // ``applyPan(of:to:in:)`` an, und ein Pan, der vollständig in
        // einem unsichtbaren Letterbox-Rand beginnt und endet, darf den
        // Ausschnitt nicht bewegen.
        let world = geo.boundedWorldPoint(forScreenPoint: point)

        var zoneGesture: ZoneGeometryGesture?
        var zoneStart: ZoneGeometryGestureStart?
        var startNotice: ScanFieldNotice?

        if tool == .editZone {
            if let selectedZoneID, let editable = zones.first(where: { $0.id == selectedZoneID }) {
                if let gesture = ZoneHandleGeometry.gesture(at: point, for: editable.zone, in: geo) {
                    zoneGesture = gesture
                    zoneStart = ZoneGeometryGestureStart(
                        zoneID: editable.id, zone: editable.zone, location: point
                    )
                } else {
                    startNotice = .editMissedSelectedZone
                }
            } else {
                startNotice = .editNeedsSelectedZone
            }
        }

        drag = DragSession(
            tool: tool,
            startPoint: point,
            currentPoint: point,
            startViewport: viewport,
            startWorldPoint: world,
            zoneGesture: zoneGesture,
            zoneStart: zoneStart
        )
        notice = startNotice
    }

    /// Führt die laufende Geste fort. Beim Verschieben und beim Bearbeiten
    /// wirkt das sofort, beim Rahmen wächst nur die gezeichnete Fläche.
    ///
    /// Der Rückgabewert trägt den Bearbeitungsbefehl **live** heraus --
    /// eine Zonenänderung soll der Hand folgen und nicht erst beim
    /// Loslassen sichtbar werden.
    @discardableResult
    public mutating func updateDrag(to point: CGPoint, in size: CGSize) -> ScanFieldDragOutcome {
        guard var session = drag else { return .nothing }
        session.currentPoint = point
        drag = session

        switch session.tool {
        case .pan:
            applyPan(of: session, to: point, in: size)
            // **Seit SICK-032c3b nur bei tatsächlicher Wirkung** (Auftragstext
            // „geometrisch wirkungslose Navigation sperrt nicht"): Ein Zug
            // ohne Nettoverschiebung seit Gestenbeginn (z. B. ein Klick mit
            // gewähltem Verschieben-Werkzeug) meldet ``.nothing`` statt
            // ``.viewportChanged`` -- verglichen wird gegen
            // ``DragSession/startViewport``, nicht gegen den letzten
            // Zwischenstand, weil genau das die Frage „hat diese Geste seit
            // ihrem Beginn etwas bewegt" beantwortet.
            return viewport != session.startViewport ? .viewportChanged : .nothing
        case .editZone:
            return zoneEditOutcome(of: session, at: point, in: size)
        case .selectZone:
            guard isDirectPan(session, to: point) else { return .nothing }
            applyPan(of: session, to: point, in: size)
            return viewport != session.startViewport ? .viewportChanged : .nothing
        case .rectangle:
            return .nothing
        }
    }

    /// Beendet die laufende Geste.
    ///
    /// `zones` wird **ausschließlich gelesen** und nur im Werkzeug
    /// „Zonen wählen" überhaupt angefasst.
    @discardableResult
    public mutating func endDrag(at point: CGPoint, in size: CGSize, zones: [EditableZone]) -> ScanFieldDragOutcome {
        guard let session = drag else { return .nothing }
        drag = nil

        switch session.tool {
        case .selectZone:
            if isDirectPan(session, to: point) {
                applyPan(of: session, to: point, in: size)
                return viewport != session.startViewport ? .viewportChanged : .nothing
            }
            return .selectZone(zoneID(at: point, in: size, among: zones))

        case .pan:
            applyPan(of: session, to: point, in: size)
            // Dieselbe Wirkungsprüfung wie in ``updateDrag(to:in:)``.
            return viewport != session.startViewport ? .viewportChanged : .nothing

        case .editZone:
            // **Kein Ausschnittswechsel und keine Zonenauswahl** -- das
            // Werkzeug tut genau eine Sache (Auftragspunkt 2).
            return zoneEditOutcome(of: session, at: point, in: size)

        case .rectangle:
            // `boundedWorldPoint` für **beide** Ecken (SICK-032b2c-K2):
            // Eine Ecke jenseits der sichtbaren Canvas entspricht damit
            // exakt derselben Geste mit der Ecke am Canvasrand, statt
            // einen dort nie gezeigten Weltpunkt zu benutzen.
            let geo = LinearScanFieldGeometry(fan: FanScreenGeometry(size: size), viewport: session.startViewport)
            guard let start = geo.boundedWorldPoint(forScreenPoint: session.startPoint),
                  let end = geo.boundedWorldPoint(forScreenPoint: point) else {
                notice = .viewGeometryUnusable
                return .nothing
            }
            let change = session.startViewport.zoomedToRectangle(
                xA: Double(start.x), xB: Double(end.x),
                yA: Double(start.y), yB: Double(end.y)
            )
            switch change {
            case .applied(let next):
                viewport = next
                notice = nil
                return .viewportChanged
            case .rejected(.degenerateRectangle):
                notice = .rectangleTooSmall
                return .nothing
            case .rejected:
                notice = .viewGeometryUnusable
                return .nothing
            }
        }
    }

    /// Bricht eine laufende Geste ab, ohne etwas anzuwenden. Beim
    /// Verschieben bleibt die bereits gelaufene Bewegung stehen -- sie ist
    /// bereits geschehen und wird nicht heimlich zurückgenommen.
    public mutating func cancelDrag() {
        drag = nil
    }

    // MARK: - Trefferprüfung (rein lesend)

    /// Die oberste Zone unter einem Bildschirmpunkt -- **dieselbe
    /// Auswahlregel wie bisher** in der Zonenüberlagerung: Die zuletzt
    /// gezeichnete passende Zone gewinnt, kein Treffer wählt ab.
    ///
    /// Neu ist allein, dass der Weg vom Bildschirm zur Feldkoordinate
    /// durch den **Ausschnitt** führt und **linear** ist. Diese Funktion
    /// verändert nichts: Sie liest Zonen und gibt eine Kennung zurück.
    public func zoneID(at point: CGPoint, in size: CGSize, among zones: [EditableZone]) -> EditableZone.ID? {
        guard let field = geometry(in: size).fieldCoordinate(forScreenPoint: point) else { return nil }
        let rawValue = ZoneEditorGeometry.rawValue(fromRadiusFraction: field.radiusFraction)
        return zones.reversed().first {
            $0.zone.indexRange.contains(field.angleFraction) && $0.zone.valueRange.contains(rawValue)
        }?.id
    }

    /// Die Ansichtsgeometrie zum aktuellen Ausschnitt -- die eine Stelle,
    /// an der Bildschirm und Feld zusammenkommen.
    public func geometry(in size: CGSize) -> LinearScanFieldGeometry {
        LinearScanFieldGeometry(fan: FanScreenGeometry(size: size), viewport: viewport)
    }

    /// Die sichtbaren Griffe der ausgewählten Zone -- leer, solange das
    /// Werkzeug keine anbietet oder keine Zone ausgewählt ist.
    ///
    /// Die Ansicht zeichnet genau das und entscheidet nichts selbst;
    /// dieselbe Rechnung liefert auch den Treffer (``ZoneHandleGeometry``).
    public func visibleHandles(
        in size: CGSize,
        zones: [EditableZone],
        selectedZoneID: EditableZone.ID?
    ) -> [ZoneHandleGeometry.PlacedHandle] {
        guard tool.showsZoneHandles,
              let selectedZoneID,
              let editable = zones.first(where: { $0.id == selectedZoneID }) else { return [] }
        let geo = geometry(in: size)
        guard ZoneHandleGeometry.isVisible(editable.zone, in: geo) else { return [] }
        return ZoneHandleGeometry.placedHandles(for: editable.zone, in: geo).filter(\.isVisible)
    }

    // MARK: - Intern

    private func isDirectPan(_ session: DragSession, to point: CGPoint) -> Bool {
        hypot(point.x - session.startPoint.x, point.y - session.startPoint.y)
            >= Self.directPanMinimumDistance
    }

    /// Übersetzt die laufende Bearbeitungsgeste in einen Befehl.
    ///
    /// Gibt es keinen eingefrorenen Ausgangsstand (danebengegriffen oder
    /// keine Auswahl), passiert **nichts** -- der Grund steht dann schon
    /// seit ``beginDrag(at:in:zones:selectedZoneID:)`` in ``notice`` und
    /// wird hier nicht überschrieben.
    private func zoneEditOutcome(
        of session: DragSession,
        at point: CGPoint,
        in size: CGSize
    ) -> ScanFieldDragOutcome {
        guard let gesture = session.zoneGesture, let start = session.zoneStart else {
            return .nothing
        }
        return .editZone(ZoneGeometryCommand(
            gesture: gesture,
            start: start,
            location: point,
            geometry: LinearScanFieldGeometry(
                fan: FanScreenGeometry(size: size),
                viewport: session.startViewport
            )
        ))
    }

    /// Verschiebt den Ausschnitt **des Gestenbeginns** um die
    /// Gesamtstrecke seit dem Start, damit der Inhalt dem Zeiger folgt.
    ///
    /// Gerechnet wird mit der Geometrie des **Start**-Ausschnitts: Nur so
    /// ist die Umrechnung Bildschirmstrecke -> Feldstrecke während der
    /// ganzen Geste dieselbe, und der Inhalt klebt am Zeiger, statt sich
    /// aufzuschaukeln.
    ///
    /// **Beide Weltpunkte über `boundedWorldPoint` (SICK-032b2c-K2):**
    /// `startWorld` kommt bereits geklammert aus ``beginDrag(at:in:zones:selectedZoneID:)``,
    /// `now` klammert hier ebenso. Bewegt sich der Zeiger vollständig
    /// innerhalb desselben unsichtbaren Letterbox-Rands, liefern beide
    /// Aufrufe **denselben** Canvasrand-Weltpunkt und die Strecke ist
    /// `0` -- ein Pan, der komplett in einem Rand beginnt und endet,
    /// verschiebt nichts. Verlässt der Zeiger die sichtbare Canvas nach
    /// einem Zug von innen, bleibt `now` ab dort auf dem Randwert stehen:
    /// Weitere Bewegung im selben Rand ändert nichts mehr.
    private mutating func applyPan(of session: DragSession, to point: CGPoint, in size: CGSize) {
        guard let startWorld = session.startWorldPoint else {
            notice = .viewGeometryUnusable
            return
        }
        let geo = LinearScanFieldGeometry(fan: FanScreenGeometry(size: size), viewport: session.startViewport)
        guard let now = geo.boundedWorldPoint(forScreenPoint: point) else {
            notice = .viewGeometryUnusable
            return
        }
        apply(session.startViewport.panned(
            byX: Double(startWorld.x) - Double(now.x),
            byY: Double(startWorld.y) - Double(now.y)
        ))
    }

    /// Übernimmt das Ergebnis eines Werkzeugs -- **die einzige Stelle**,
    /// die ``viewport`` aus einem ``ScanPlaneViewportChange`` setzt.
    ///
    /// **Seit SICK-032c3b mit Rückgabewert:** `true`, wenn der Ausschnitt
    /// dadurch tatsächlich einen anderen Wert bekam -- die Grundlage für
    /// ``zoomAtCenter(byFactor:)``/``zoomAtPointer(byFactor:at:in:)``s
    /// eigenen Rückgabewert.
    @discardableResult
    private mutating func apply(_ change: ScanPlaneViewportChange) -> Bool {
        switch change {
        case .applied(let next):
            let changed = next != viewport
            viewport = next
            notice = nil
            return changed
        case .rejected:
            // Die Eingabe war unbrauchbar (nicht endlich oder ein
            // Zoomfaktor <= 0). Der Ausschnitt bleibt, wie er war.
            notice = .viewGeometryUnusable
            return false
        }
    }
}
