/// Alle Schwellwerte des bewegungsbasierten Zonenlernens (SICK-030c).
///
/// **Alles ist in Profilanzahlen oder Rohwertdifferenzen ausgedrückt,
/// nichts in Sekunden.** Der Accumulator hat bewusst keine Uhr: Die
/// Profilrate des Geräts ist nicht zugesichert (bei 9600 Baud real ≈ 4 Hz,
/// in der externen Doku bei 38 400 andere Werte, SICK-012/SICK-015), und
/// eine Zeitschwelle hieße bei jeder Rate etwas anderes. Eine
/// Profilzählung heißt immer dasselbe.
///
/// **Die Vorgaben in ``default`` sind dokumentierte Startwerte, keine
/// Gerätewahrheit** — dieselbe Kennzeichnung wie bei
/// ``ControlValuePredictorConfiguration/startingPoint`` und
/// `GatePolicy.standard`. Sie sind an der Größenordnung des einzigen
/// echten Mitschnitts (Rohwerte ≈ 21…169, SICK-012) orientiert und
/// **gehören am realen Gerät gemessen**, sobald es verfügbar ist.
public struct ZoneLearningConfiguration: Equatable, Sendable {

    /// Wie viele vollständige Profile das Grundfenster bilden.
    ///
    /// Ein **Fenster**, nicht ein Frame: Je Index werden Minimum und
    /// Maximum über alle gültigen Werte dieser Profile gebildet. Gegen
    /// einen einzelnen Frame zu vergleichen, machte jedes Rauschen im
    /// Hintergrund zur „Bewegung" (Auflage **D1**, Befund **H1**).
    public let baselineProfileCount: Int

    /// Ab wie vielen Profilen ein veränderter Index als **brauchbar**
    /// gilt.
    ///
    /// Ohne diese Persistenz würde ein einzelner Rauschausschlag zum
    /// Kandidaten; eine Hand steht über mehrere Profile im Strahl.
    public let minimumPersistenceProfiles: Int

    /// Wie viele brauchbare Indizes ein Cluster mindestens umfassen muss.
    public let minimumClusterPoints: Int

    /// Wie viele **fehlende** Indizes zwischen zwei brauchbaren Indizes
    /// höchstens liegen dürfen, damit sie noch zu einem Cluster gehören.
    ///
    /// `0` heißt „lückenlos benachbart". Bei `1` gehören die Indizes 12
    /// und 14 zusammen (ein fehlender dazwischen), 12 und 15 nicht mehr.
    public let maximumIndexGap: Int

    /// Um wie viele Rohwerte ein Messwert die Grundhüllkurve verlassen
    /// muss, um als Bewegung zu zählen.
    ///
    /// Richtungsneutral: `wert < min - delta` **oder** `wert > max + delta`
    /// (Befund **N1** — Learn reagiert auf Veränderung, die Richtung
    /// „Objekt näher als Hintergrund" steckt erst in der Zonenbildung).
    public let movementDelta: UInt16

    /// Wie viele Indexpunkte links und rechts an den Cluster angefügt
    /// werden.
    public let indexPaddingPoints: Int

    /// Wie viele Rohwerte unter dem kleinsten und über dem größten
    /// beobachteten Bewegungswert der Wertebereich zusätzlich umfasst.
    public let valuePadding: UInt16

    /// Sicherheitsabstand zwischen der Wertobergrenze des Kandidaten und
    /// dem **kleinsten gültigen Grundwert** in seinem Indexbereich.
    ///
    /// Das ist die rechnerische Hälfte von Auflage **D1**; die andere
    /// Hälfte ist die Nachbedingung, die den fertigen Kandidaten gegen
    /// **jedes** Grundprofil prüft. Beides zusammen verhindert die Zone,
    /// die ohne Hand dauerhaft aktiv ist — bei einer Gate-Zone ein
    /// Dauer-Gate, bei Pitch/Volume ein Dauerton.
    public let backgroundClearance: UInt16

    /// Ab wann zwei Cluster als **gleichauf** gelten.
    ///
    /// Erreicht der zweitstärkste Cluster mit diesem Faktor multipliziert
    /// den stärksten, wird **verweigert** statt geraten
    /// (``ZoneLearningRefusal/ambiguousCandidates``). `1.0` hieße „nur
    /// exakter Gleichstand ist mehrdeutig"; kleiner als `1` wäre
    /// sinnlos und wird abgelehnt.
    public let ambiguityToleranceFactor: Double

    private init(
        baselineProfileCount: Int,
        minimumPersistenceProfiles: Int,
        minimumClusterPoints: Int,
        maximumIndexGap: Int,
        movementDelta: UInt16,
        indexPaddingPoints: Int,
        valuePadding: UInt16,
        backgroundClearance: UInt16,
        ambiguityToleranceFactor: Double
    ) {
        self.baselineProfileCount = baselineProfileCount
        self.minimumPersistenceProfiles = minimumPersistenceProfiles
        self.minimumClusterPoints = minimumClusterPoints
        self.maximumIndexGap = maximumIndexGap
        self.movementDelta = movementDelta
        self.indexPaddingPoints = indexPaddingPoints
        self.valuePadding = valuePadding
        self.backgroundClearance = backgroundClearance
        self.ambiguityToleranceFactor = ambiguityToleranceFactor
    }

    /// Ein eigener Fall je Regel — **keine stille Korrektur**
    /// (Hausmuster wie `Frame.build`/`Zone.build`/
    /// `ControlValuePredictorConfiguration.build`).
    public enum BuildError: Error, Equatable, Sendable {
        case baselineProfileCountNotPositive(Int)
        case minimumPersistenceProfilesNotPositive(Int)
        case minimumClusterPointsNotPositive(Int)
        case maximumIndexGapNegative(Int)
        case movementDeltaNotPositive(UInt16)
        case indexPaddingPointsNegative(Int)
        case backgroundClearanceNotPositive(UInt16)
        case ambiguityToleranceFactorNotFinite(Double)
        case ambiguityToleranceFactorBelowOne(Double)
        /// Puffer und Sicherheitsabstand zusammen können den ganzen
        /// Rohwertbereich überspannen — dann ließe sich nie ein gültiger
        /// Kandidat bilden, und der Fehler gehört an den Konstruktor,
        /// nicht in jedes einzelne Lernergebnis.
        case paddingAndClearanceExceedValueRange(padding: UInt16, clearance: UInt16)
    }

    /// Validierende Fabrik. Jede Verletzung wirft ihren **eigenen**
    /// Fehler; nichts wird geklammert.
    public static func build(
        baselineProfileCount: Int,
        minimumPersistenceProfiles: Int,
        minimumClusterPoints: Int,
        maximumIndexGap: Int,
        movementDelta: UInt16,
        indexPaddingPoints: Int,
        valuePadding: UInt16,
        backgroundClearance: UInt16,
        ambiguityToleranceFactor: Double
    ) throws -> ZoneLearningConfiguration {
        guard baselineProfileCount > 0 else {
            throw BuildError.baselineProfileCountNotPositive(baselineProfileCount)
        }
        guard minimumPersistenceProfiles > 0 else {
            throw BuildError.minimumPersistenceProfilesNotPositive(minimumPersistenceProfiles)
        }
        guard minimumClusterPoints > 0 else {
            throw BuildError.minimumClusterPointsNotPositive(minimumClusterPoints)
        }
        guard maximumIndexGap >= 0 else {
            throw BuildError.maximumIndexGapNegative(maximumIndexGap)
        }
        guard movementDelta > 0 else {
            throw BuildError.movementDeltaNotPositive(movementDelta)
        }
        guard indexPaddingPoints >= 0 else {
            throw BuildError.indexPaddingPointsNegative(indexPaddingPoints)
        }
        guard backgroundClearance > 0 else {
            throw BuildError.backgroundClearanceNotPositive(backgroundClearance)
        }
        guard ambiguityToleranceFactor.isFinite else {
            throw BuildError.ambiguityToleranceFactorNotFinite(ambiguityToleranceFactor)
        }
        guard ambiguityToleranceFactor >= 1 else {
            throw BuildError.ambiguityToleranceFactorBelowOne(ambiguityToleranceFactor)
        }
        guard Int(valuePadding) + Int(backgroundClearance) < Int(Zone.maxRawMeasurementValue) else {
            throw BuildError.paddingAndClearanceExceedValueRange(
                padding: valuePadding, clearance: backgroundClearance
            )
        }
        return ZoneLearningConfiguration(
            baselineProfileCount: baselineProfileCount,
            minimumPersistenceProfiles: minimumPersistenceProfiles,
            minimumClusterPoints: minimumClusterPoints,
            maximumIndexGap: maximumIndexGap,
            movementDelta: movementDelta,
            indexPaddingPoints: indexPaddingPoints,
            valuePadding: valuePadding,
            backgroundClearance: backgroundClearance,
            ambiguityToleranceFactor: ambiguityToleranceFactor
        )
    }

    /// **Dokumentierter Startwert, keine Gerätewahrheit.**
    ///
    /// - 5 Grundprofile: bei ≈ 4 Hz gut eine Sekunde ruhiger Hintergrund —
    ///   genug für eine Hüllkurve, kurz genug, dass niemand wartet.
    /// - 3 Profile Persistenz und 3 Clusterpunkte: ein einzelner
    ///   Rauschausschlag wird so weder brauchbar noch zum Cluster.
    /// - Lücke 1: eine einzelne Fehlmessung mitten in der Hand zerreißt
    ///   den Cluster nicht.
    /// - Bewegungsdifferenz 40, Puffer 20, Abstand 30: an der
    ///   Größenordnung des einzigen echten Mitschnitts orientiert
    ///   (Rohwerte ≈ 21…169, SICK-012). **Diese drei Zahlen gehören am
    ///   realen Gerät gemessen** — sie sind hier eine begründete
    ///   Ausgangswahl, kein Messergebnis.
    /// - Mehrdeutigkeitsfaktor 1,25: Ein zweiter Cluster mit mindestens
    ///   80 % der Treffer des stärksten lässt die Entscheidung
    ///   verweigern.
    public static let `default` = ZoneLearningConfiguration(
        baselineProfileCount: 5,
        minimumPersistenceProfiles: 3,
        minimumClusterPoints: 3,
        maximumIndexGap: 1,
        movementDelta: 40,
        indexPaddingPoints: 1,
        valuePadding: 20,
        backgroundClearance: 30,
        ambiguityToleranceFactor: 1.25
    )
}
