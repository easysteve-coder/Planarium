import struct Foundation.UUID
import SickPLSCore
import SickPLSControlCore

/// Der Lebenszyklus **eines** Lernvorgangs im Zoneneditor (SICK-030c).
///
/// Bindet einen reinen `ZoneLearningAccumulator` an die ID einer
/// bestehenden Zone. **Keine zweite Wahrheit über die Zone:** Hier liegen
/// nur die ID, die beim Armieren festgehaltene Rolle und der
/// Accumulator — Index- und Rohwertgrenzen stehen ausschließlich in
/// `zones[i].zone`.
///
/// Die Rolle wird mitgeführt, **weil ein Kandidat sie braucht** und weil
/// eine Rollenänderung während des Lernens den Vorgang beenden muss: Eine
/// für Gate gelernte Fläche ist keine Pitch-Zone.
public struct ZoneLearningSession: Equatable, Sendable {
    /// Die Zielzone. Bleibt über den ganzen Vorgang dieselbe.
    public let zoneID: EditableZone.ID
    /// Die Rolle der Zielzone **zum Zeitpunkt des Armierens**.
    public let role: ZoneRole
    public private(set) var accumulator: ZoneLearningAccumulator

    init(zoneID: EditableZone.ID, role: ZoneRole, configuration: ZoneLearningConfiguration) {
        self.zoneID = zoneID
        self.role = role
        self.accumulator = ZoneLearningAccumulator(role: role, configuration: configuration)
    }

    public var state: ZoneLearningState { accumulator.state }
    public var isCollecting: Bool { accumulator.isCollecting }
    public var candidate: Zone? { accumulator.candidate }

    mutating func ingest(_ profile: B0ScanProfile) { accumulator.ingest(profile) }
    mutating func finish() { accumulator.finish() }
    mutating func cancel(_ reason: ZoneLearningCancellation) { accumulator.cancel(reason) }
}

/// Warum ein Armierversuch abgelehnt wurde.
///
/// Getrennte Fälle statt eines `Bool`: „die Zone gibt es nicht" und „die
/// Zone läuft gerade mit" verlangen zwei verschiedene Handgriffe, und die
/// Oberfläche soll den richtigen benennen können („zum Lernen zuerst
/// deaktivieren", Auflage **D2**).
public enum ZoneLearningArmOutcome: Equatable, Sendable {
    case armed
    /// Die ID gehört zu keiner Zone.
    case unknownZone
    /// Die Zone ist eingeschaltet. **Learn ist nur auf deaktivierten
    /// Zonen zulässig** (Auflage **D2**): Sonst klänge die Lernbewegung
    /// mit, und beim Übernehmen änderten sich die Grenzen einer
    /// spielenden Zone unter der Hand.
    case zoneIsEnabled
    /// Es läuft bereits ein Vorgang. Er bleibt **unangetastet** —
    /// dasselbe Muster wie ein zweiter `start()` am Audiodienst.
    case alreadyLearning(zoneID: EditableZone.ID)
    /// Ein **vorzonaler** Lernentwurf für eine neue Zone sammelt gerade
    /// (SICK-032c3a-K1). Höchstens **ein** Lernvorgang insgesamt läuft
    /// zur selben Zeit — beide teilten sich sonst denselben Profilstrom.
    /// Der laufende Entwurf bleibt **unangetastet**.
    case blockedByLearnDraft
}

/// Warum das Übernehmen eines Kandidaten abgelehnt wurde.
public enum ZoneLearningApplyOutcome: Equatable, Sendable {
    /// Geschrieben. Der Wert ist die neue Zone; **`isEnabled` hat sich
    /// nicht geändert.**
    case applied(Zone)
    /// Es läuft kein Vorgang.
    case notLearning
    /// Der Vorgang hat (noch) keinen Kandidaten.
    case noCandidate(ZoneLearningState)
    /// Die Zielzone gibt es nicht mehr.
    case targetZoneMissing
    /// Die Zielzone ist inzwischen eingeschaltet. Ein Übernehmen würde
    /// die Grenzen einer spielenden Zone ändern — dieselbe Begründung wie
    /// bei ``ZoneLearningArmOutcome/zoneIsEnabled``.
    case targetZoneIsEnabled
    /// Die Rolle der Zielzone hat sich seit dem Armieren geändert; der
    /// Kandidat trägt die alte.
    case targetZoneRoleChanged(expected: ZoneRole, actual: ZoneRole)
}
