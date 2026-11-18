@testable import PlanariumPresets
import PlanariumDomain
// EffectRackSelection.swift
//
// Die geordnete Rack-Auswahl — **ausschließlich eine
// Wunschkonfiguration**.
//
// ## Was diese Auswahl ist und was nicht
//
// Sie ist eine Liste von Kennungen in einer gewollten Reihenfolge. Sie
// **startet nichts, lädt nichts, instanziiert nichts und verbindet
// nichts**. Eine Auswahl zu ändern darf niemals dazu führen, dass
// fremder Code ausgeführt wird — genau deshalb ist dieser Slice vom
// späteren Hosten getrennt.
//
// ## Noch offen, ausdrücklich
//
// Drittanbieter-Audio-Units sind **fremder Code**. Alles Folgende ist
// **nicht** Teil dieses Vertrags und braucht eine eigene Freigabe:
//
// - die tatsächliche Instanziierung einer Komponente;
// - Parameterautomatisierung;
// - Sandboxing und Fehlerisolation (was passiert, wenn ein Plugin
//   abstürzt, hängt oder den Audio-Thread blockiert?);
// - die kontrollierte Änderung eines **laufenden** Audiographen.
//
// Bis dahin bleibt das Rack eine Liste, die niemand abspielt.

/// Die gewollte Reihenfolge von Effektkomponenten.
///
/// Erzeugt ausschließlich über `build(...)` — validierende Fabrik nach
/// dem Hausmuster, **ohne stille Korrektur**: ein heimlich entferntes
/// Duplikat oder ein abgeschnittener Eintrag wäre eine Auswahl, die
/// jemand so nie getroffen hat.
public struct EffectRackSelection: Equatable, Sendable {
    /// Die Kennungen in der gewollten Reihenfolge.
    public let entries: [AudioUnitIdentity]

    public enum BuildError: Error, Equatable {
        /// Dieselbe Komponente wurde mehrfach ausgewählt.
        case duplicateEntry(AudioUnitIdentity)
    }

    private init(entries: [AudioUnitIdentity]) {
        self.entries = entries
    }

    public static func build(entries: [AudioUnitIdentity]) throws -> EffectRackSelection {
        var seen = Set<AudioUnitIdentity>()
        for entry in entries {
            guard seen.insert(entry).inserted else {
                throw BuildError.duplicateEntry(entry)
            }
        }
        return EffectRackSelection(entries: entries)
    }

    /// Die **neutrale** Auswahl: kein Rack.
    ///
    /// Das ist der Ausgangszustand und bleibt es, bis jemand
    /// ausdrücklich etwas auswählt.
    public static let empty = EffectRackSelection(entries: [])

    /// `true`, wenn nichts ausgewählt ist.
    public var isEmpty: Bool { entries.isEmpty }

    /// Zahl der belegten Rackplätze.
    public var count: Int { entries.count }

}
