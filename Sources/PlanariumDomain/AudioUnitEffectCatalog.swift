// AudioUnitEffectCatalog.swift
//
// Die Entdeckung von Audio-Unit-Effekten — **strikt getrennt von jeder
// Instanziierung**.
//
// Auch diese Datei ist framework-frei: die Rohbeschreibungen kommen über
// eine schmale, injizierbare Grenze herein (`AudioUnitComponentSource`),
// deren reale Implementierung als einzige `AVFoundation` anfasst (siehe
// `SystemAudioUnitComponentSource.swift`).
//
// **Was hier passiert:** filtern, entdoppeln, stabil sortieren,
// umwandeln. **Was hier nicht passiert:** laden, instanziieren,
// verbinden, starten. Ein Katalogeintrag ist eine Beschreibung.

/// Eine Rohbeschreibung, wie sie das System liefert.
///
/// Bewusst ein **eigener Wert** statt `AudioComponentDescription` oder
/// `AVAudioUnitComponent`: so kommt kein Apple-Audio-Typ über diese
/// Grenze, und der gesamte Filter-/Sortierweg ist ohne Audiogerät und
/// ohne installierte Drittanbieter-AU prüfbar.
public struct AudioUnitComponentDescription: Equatable {
    public var componentType: UInt32
    public var componentSubType: UInt32
    public var componentManufacturer: UInt32
    public var name: String
    public var manufacturerName: String
    public var isSandboxSafe: Bool

    public init(
        componentType: UInt32,
        componentSubType: UInt32,
        componentManufacturer: UInt32,
        name: String,
        manufacturerName: String,
        isSandboxSafe: Bool
    ) {
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
        self.name = name
        self.manufacturerName = manufacturerName
        self.isSandboxSafe = isSandboxSafe
    }
}

/// Die schmale Grenze zum System.
///
/// **Liefert ausschließlich Metadaten.** Eine Implementierung darf
/// nichts instanziieren, überhaupt nichts laden und keinen Graphen
/// anfassen.
public protocol AudioUnitComponentSource: AnyObject {
    /// Die vorhandenen Effektkomponenten als Rohbeschreibungen.
    ///
    /// Darf eine leere Liste liefern — ein System ohne
    /// Drittanbieter-Effekte ist ein gültiger, normaler Zustand und
    /// kein Fehler.
    func effectComponentDescriptions() -> [AudioUnitComponentDescription]
    func instrumentComponentDescriptions() -> [AudioUnitComponentDescription]
}

public extension AudioUnitComponentSource {
    /// Alte/falsche Quellen bleiben gültig; ohne Instrumentabfrage ist der
    /// Instrumentkatalog schlicht leer.
    func instrumentComponentDescriptions() -> [AudioUnitComponentDescription] { [] }
}

/// Der Katalog: macht aus Rohbeschreibungen eine geordnete,
/// entdoppelte Liste gültiger Effektkandidaten.
///
/// Rein und ohne Zustand — zweimal gefragt, zweimal dasselbe Ergebnis
/// für dieselbe Quelle.
public struct AudioUnitEffectCatalog {
    public static let internalManufacturer: UInt32 = 0x506c6e6d
    public static func isUserComponent(manufacturer: UInt32) -> Bool { manufacturer != internalManufacturer }
    /// Display the manufacturer's registered name verbatim. Apple's legacy
    /// DLS component alone needs spacing for its technical registration name.
    public static func presentationName(_ description: AudioUnitComponentDescription) -> String {
        if description.componentType == 0x61756D75, description.componentSubType == 0x646C7320,
           description.componentManufacturer == 0x6170706C, description.name == "DLSMusicDevice" {
            return "DLS Music Device"
        }
        return description.name
    }
    private let source: AudioUnitComponentSource

    public init(source: AudioUnitComponentSource) {
        self.source = source
    }

    /// Die verfügbaren Effektkandidaten.
    ///
    /// Reihenfolge: nach Herstellername, dann Name, jeweils
    /// gross-/kleinschreibungsunabhängig. Bei **gleichem** Schlüssel
    /// bleibt die Reihenfolge der Quelle erhalten (stabile Sortierung,
    /// siehe unten).
    ///
    /// Aussortiert werden:
    /// - alles, was kein reiner Audioeffekt (`aufx`) ist;
    /// - Einträge ohne eindeutige Identität (Subtyp oder Hersteller `0`);
    /// - **Duplikate** derselben Identität — der erste Eintrag der
    ///   Quelle gewinnt, spätere werden verworfen.
    ///
    /// Ein unbrauchbarer Eintrag lässt den Rest der Liste unberührt: ein
    /// einzelnes kaputtes Plugin darf den Katalog nicht leeren.
    public func availableEffects() -> [AudioUnitEffectCandidate] {
        Self.candidates(from: source.effectComponentDescriptions())
    }

    /// Installierte Music Devices (`aumu`) für den Logic-artigen
    /// Instrument-Slot. Reine Metadatenabfrage, keine Instanziierung.
    public func availableInstruments() -> [AudioUnitInstrumentCandidate] {
        var seen = Set<AudioUnitInstrumentIdentity>()
        return source.instrumentComponentDescriptions().compactMap { description in
            guard Self.isUserComponent(manufacturer: description.componentManufacturer),
                  description.componentType == AudioUnitInstrumentIdentity.componentType,
                  let identity = AudioUnitInstrumentIdentity(
                    componentSubType: description.componentSubType,
                    componentManufacturer: description.componentManufacturer
                  ), seen.insert(identity).inserted else { return nil }
            return AudioUnitInstrumentCandidate(
                identity: identity,
                name: Self.presentationName(description),
                manufacturerName: description.manufacturerName,
                isSandboxSafe: description.isSandboxSafe
            )
        }.sorted {
            ($0.manufacturerName.lowercased(), $0.name.lowercased())
                < ($1.manufacturerName.lowercased(), $1.name.lowercased())
        }
    }

    /// Die reine Umwandlung, ohne Quelle — damit Filterung, Sortierung
    /// und Konvertierung einzeln prüfbar sind.
    public static func candidates(
        from descriptions: [AudioUnitComponentDescription]
    ) -> [AudioUnitEffectCandidate] {
        var seen = Set<AudioUnitIdentity>()
        var accepted: [(index: Int, candidate: AudioUnitEffectCandidate)] = []

        for description in descriptions {
            guard Self.isUserComponent(manufacturer: description.componentManufacturer) else { continue }
            guard
                let identity = try? AudioUnitIdentity.build(
                    componentType: description.componentType,
                    componentSubType: description.componentSubType,
                    componentManufacturer: description.componentManufacturer
                )
            else {
                continue
            }
            guard seen.insert(identity).inserted else {
                continue  // Duplikat: der erste Eintrag gewinnt.
            }
            accepted.append((
                index: accepted.count,
                candidate: AudioUnitEffectCandidate(
                    identity: identity,
                    name: description.name,
                    manufacturerName: description.manufacturerName,
                    isSandboxSafe: description.isSandboxSafe
                )
            ))
        }

        // **Stabile Sortierung von Hand.** `Array.sort` gibt in Swift
        // keine Stabilität zu; bei gleichem Schlüssel wäre die
        // Reihenfolge sonst nicht zugesichert und der Katalog könnte
        // zwischen zwei Aufrufen springen. Der mitgeführte
        // Ursprungsindex entscheidet jeden Gleichstand.
        return accepted
            .sorted { left, right in
                let leftKey = Self.sortKey(left.candidate)
                let rightKey = Self.sortKey(right.candidate)
                if leftKey.manufacturer != rightKey.manufacturer {
                    return leftKey.manufacturer < rightKey.manufacturer
                }
                if leftKey.name != rightKey.name {
                    return leftKey.name < rightKey.name
                }
                return left.index < right.index
            }
            .map(\.candidate)
    }

    private static func sortKey(
        _ candidate: AudioUnitEffectCandidate
    ) -> (manufacturer: String, name: String) {
        (candidate.manufacturerName.lowercased(), candidate.name.lowercased())
    }
}
