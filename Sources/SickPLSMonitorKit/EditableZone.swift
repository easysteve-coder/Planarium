import struct Foundation.UUID
import SickPLSControlCore

/// Eine Zone mit stabiler Editor-Identität -- reine Bequemlichkeit für
/// SwiftUI-Listen/Auswahl (`Identifiable`), **keine** Parallelsemantik
/// zu `SickPLSControlCore.Zone`: alle fachlichen Felder und die
/// gesamte Validierung bleiben ausschließlich dort (SICK-014-Auftrag:
/// „`Zone` bleibt der einzige fachliche Zonenvertrag; keine
/// Duplizierung oder Parallelsemantik").
public struct EditableZone: Identifiable, Equatable, Sendable {
    public let id: UUID

    /// Der fachliche Zonenvertrag — Indexbereich, Rohwertbereich,
    /// Rolle. **Die einzige Wahrheit über das, was die Zone ist.**
    public var zone: Zone

    /// Ob die Zone in die **Spielpipeline** geht (SICK-030b1).
    ///
    /// ## Drei Dinge, die bewusst auseinandergehalten werden
    ///
    /// | Frage | Antwort steht in |
    /// |---|---|
    /// | Wofür ist die Zone gedacht? | ``zone`` → `Zone.role` |
    /// | Spielt sie mit? | **dieses Feld** |
    /// | Bedient sie gerade einen Slot? | `ThereminRoleAssignmentState` |
    ///
    /// Die drei sind unabhängig, und genau das macht die späteren
    /// Insert-Karten möglich (Auflage **D4**): Eine Zone kann einem Slot
    /// zugewiesen und trotzdem ausgeschaltet sein, und die Anzeige muss
    /// beides getrennt zeigen können.
    ///
    /// ## Was „deaktiviert" heißt — und was nicht
    ///
    /// - **Nicht:** gelöscht, ungültig, ohne Rolle oder ohne Zuweisung.
    ///   Eine deaktivierte Zone bleibt sichtbar, behält ihre Werte und
    ///   **behält ihre Slot-Zuweisung**; Wiedereinschalten stellt nichts
    ///   heimlich um.
    /// - **Sehr wohl:** Sie erreicht die Spielpipeline nicht. Sie erzeugt
    ///   keinen Steuerwert, kein Gate und keine Prognosehistorie
    ///   (`ThereminRuntime` filtert sie heraus, bevor die
    ///   `ZoneSignalPipeline` sie je sieht).
    /// - Für die **Live-Anzeige** ändert sich nichts: `ZoneEditorState`
    ///   bewertet weiterhin **jede** Zone gegen das echte Profil, damit
    ///   man beim Einrichten sieht, was eine Zone täte, bevor man sie
    ///   einschaltet.
    ///
    /// **Kein Parallelfeld zu `Zone`:** `Zone` beschreibt die Zone,
    /// dieses Feld den Umgang des Editors und der Bedienung mit ihr.
    /// Deshalb steht es hier und nicht dort.
    public var isEnabled: Bool

    /// Die **Feldform** (SICK-033e): Streifen, Raster, Fächer oder
    /// Tonartfeld. Standard ist der Streifen -- bitgleich das bisherige
    /// Verhalten. Für die Rolle `gate` ist die Form **ohne Bedeutung**:
    /// Ein Gate ist stets ein Streifen (siehe ``field``); die Karte
    /// bietet für Gate-Zonen keine Formwahl an.
    public var shape: FieldShape

    /// **Ohne Vorgabewert, mit Absicht.** Ob eine Zone mitspielt, ist
    /// eine Entscheidung und darf an keiner Stelle still geerbt werden —
    /// dieselbe Haltung wie bei den `switch`-Ausdrücken ohne `default`.
    /// Neue Zonen aus dem Editor entstehen **deaktiviert**, siehe
    /// ``ZoneEditorState/addZone(_:)``.
    public init(id: UUID = UUID(), zone: Zone, isEnabled: Bool, shape: FieldShape = .strip) {
        self.id = id
        self.zone = zone
        self.isEnabled = isEnabled
        self.shape = shape
    }

    /// Das auswertbare Feld: Zone plus Form. **Die eine geschlossene
    /// Regel:** Für `gate` gilt immer der Streifen; für alle anderen
    /// Rollen die gewählte Form. Dadurch existiert kein Weg zu einem
    /// diskreten Gate -- ``Field/build(zone:shape:)`` kann hier
    /// strukturell nicht fehlschlagen.
    public var field: Field {
        let effectiveShape: FieldShape
        switch zone.role {
        case .gate: effectiveShape = .strip
        case .pitch, .volume, .filter, .effectSend: effectiveShape = shape
        }
        // Erzwungen konsistent (Gate → Streifen), daher nie `nil`.
        return (try? Field.build(zone: zone, shape: effectiveShape)) ?? Field.strip(zone)
    }
}
