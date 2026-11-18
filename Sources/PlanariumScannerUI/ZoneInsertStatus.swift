import SickPLSControlCore
import SickPLSMonitorKit
import PlanariumInput

/// Gemeinsame Anzeigenamen der historischen Zonen für Editor und Presetimport.
public enum ZoneRoleNaming {
    /// Der **eine** Anzeigename je Rolle im ganzen Projekt.
    ///
    /// Die Farbgebung bleibt im App-Ziel (sie braucht SwiftUI); der Name
    /// steht hier, damit Insert und Karte
    /// nachweislich dasselbe Wort benutzen.
    public static func name(of role: ZoneRole) -> String {
        switch role {
        case .pitch: return "Pitch"
        case .volume: return "Volume"
        case .filter: return "Filter"
        case .gate: return "Gate"
        case .effectSend: return "EffectSend"
        }
    }
}

/// Feste Dezimaldarstellung **ohne Foundation**.
///
/// Dieses Modul importiert bewusst kein `Foundation` (die Grenzliste in
/// `PerformanceSessionBoundaryTests` lässt es nicht zu), und
/// `String(format:)` käme genau von dort. Gerechnet wird deshalb mit
/// Stdlib-Mitteln: skalieren, `rounded()`, als Ganzzahl formatieren.
/// Deutsches Dezimalkomma, passend zu den übrigen Texten.
enum DecimalText {
    static func fixed(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return "–" }
        guard places > 0 else { return String(Int(value.rounded())) }
        var scale = 1.0
        for _ in 0..<places { scale *= 10 }
        let scaled = (value * scale).rounded()
        let isNegative = scaled < 0
        var digits = String(Int(abs(scaled)))
        while digits.count <= places { digits = "0" + digits }
        let cut = digits.index(digits.endIndex, offsetBy: -places)
        let whole = String(digits[digits.startIndex..<cut])
        let fraction = String(digits[cut...])
        return (isNegative ? "-" : "") + whole + "," + fraction
    }
}

/// Die **eine** Darstellung der vier Zonengrenzen im ganzen Projekt.
///
/// Insert, Einstellkarte und der Lernvorschlag (SICK-032c2) benutzen
/// dieselbe Funktion: Sonst sähe ein gelernter Bereich anders aus als
/// dieselbe Zone eine Zeile darüber, und niemand könnte beides
/// vergleichen.
public enum ZoneBoundsText {
    public static func label(for zone: Zone) -> String {
        "Index " + DecimalText.fixed(zone.indexRange.lowerBound, places: 2)
            + "–" + DecimalText.fixed(zone.indexRange.upperBound, places: 2)
            + " · Value \(zone.valueRange.lowerBound)–\(zone.valueRange.upperBound)"
    }
}

/// Ob eine Zone mitspielt — **eine** der drei getrennten Angaben.
public enum ZoneActivation: Equatable, Sendable {
    case on
    case off

    public init(isEnabled: Bool) {
        self = isEnabled ? .on : .off
    }

    public var isOn: Bool { self == .on }

    public var label: String {
        switch self {
        case .on: return "On"
        case .off: return "Off"
        }
    }
}

/// Was die Zone im **letzten echten B0-Profil** gesehen hat — die
/// zweite der drei getrennten Angaben.
///
/// **Ausschließlich Messung.** Der Wert kommt unverändert aus
/// `Zone.evaluate(against:)` auf dem gerade vorliegenden Profil; es gibt
/// hier keine Prognose, keine Glättung und keinen gespeicherten
/// Vorwert. Ohne Profil ist das Ergebnis ausdrücklich `noProfile` und
/// **nicht** `notHit` — „es wurde nichts gemessen" und „es wurde
/// gemessen und nichts getroffen" sind zwei Lagen.
public enum ZoneLiveStatus: Equatable, Sendable {
    /// Es liegt (noch) kein echtes Profil vor.
    case noProfile
    /// Ein echtes Profil liegt vor, diese Zone sieht darin nichts.
    case notHit
    /// Ein echtes Profil liegt vor, der normierte Steuerwert `0...1`.
    case hit(Double)

    /// Baut den Zustand aus dem Auswertungsergebnis **genau eines**
    /// Profils.
    ///
    /// `hasProfile` entscheidet allein über `noProfile`; ein fehlender
    /// Eintrag bei vorliegendem Profil ist `notHit` (die Zone ist neu
    /// oder wurde nicht bewertet), nie ein alter Wert.
    public static func of(
        _ zoneID: EditableZone.ID,
        in evaluations: [EditableZone.ID: ZoneEvaluationResult],
        hasProfile: Bool
    ) -> ZoneLiveStatus {
        guard hasProfile else { return .noProfile }
        switch evaluations[zoneID] {
        case .controlValue(let value)?:
            return .hit(value)
        case .inactive?, nil:
            return .notHit
        }
    }

    public var isHit: Bool {
        if case .hit = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .noProfile: return "no measurement"
        case .notHit: return "not hit"
        case .hit(let value): return "hit · " + DecimalText.fixed(value, places: 3)
        }
    }
}

/// Der vollständige Anzeigezustand **einer** Zone.
///
/// ## Vier Angaben, die nie zu einer Ampel verschmelzen
///
/// | Frage | Feld |
/// |---|---|
/// | Wofür ist die Zone gedacht? | ``zone`` → `Zone.role` |
/// | Ist sie gerade ausgewählt? | ``isSelected`` |
/// | Spielt sie mit? | ``activation`` |
/// | Bedient sie einen Spiel-Slot? | ``slot`` |
/// | Sieht sie gerade etwas? | ``live`` |
///
/// Auswahl, Aktivierung und Treffer sind **drei verschiedene Dinge**
/// (SICK-032c1, Anforderung 1): Eine ausgewählte Zone kann ausgeschaltet
/// sein, eine eingeschaltete gerade nichts sehen, und eine ausgeschaltete
/// wird trotzdem bewertet — sonst könnte man eine Zone nicht einrichten,
/// **bevor** man sie einschaltet (SICK-030b1).
public struct ZoneInsertStatus: Equatable, Identifiable, Sendable {
    public let id: EditableZone.ID
    public let zone: Zone
    public let isSelected: Bool
    public let activation: ZoneActivation
    public let live: ZoneLiveStatus
    /// Die Feldform (SICK-033e), wie die Karte sie zeigt.
    public let shape: FieldShape

    public init(
        id: EditableZone.ID,
        zone: Zone,
        isSelected: Bool,
        activation: ZoneActivation,
        live: ZoneLiveStatus,
        shape: FieldShape = .strip
    ) {
        self.id = id
        self.zone = zone
        self.isSelected = isSelected
        self.activation = activation
        self.live = live
        self.shape = shape
    }

    /// Der Rollenname der Zone — wofür sie gedacht ist.
    public var roleLabel: String { ZoneRoleNaming.name(of: zone.role) }

    /// Die vier Grenzen, knapp und einheitlich.
    public var boundsLabel: String { ZoneBoundsText.label(for: zone) }

}
