// AudioUnitIdentity.swift
//
// Der **framework-unabhängige** Wertvertrag für Audio-Unit-Effekte.
//
// Diese Datei importiert bewusst **kein `AVFoundation` und kein
// `AudioToolbox`**. Sie enthält nur Swift-Stdlib-Typen, damit eine
// spätere App- oder SwiftUI-Schicht mit Kandidaten und Rack-Auswahl
// arbeiten kann, ohne je einen Apple-Audio-Typ zu sehen. Dasselbe
// Wertvertrag ohne Foundation- oder Host-Abhängigkeit.
//
// ## Sicherheitsgrenze — bitte beim Weiterbauen erhalten
//
// Ein Audio-Unit-Effekt eines Drittanbieters ist **fremder Code**.
// Nichts in dieser Datei lädt, instanziiert oder startet irgendetwas:
// hier stehen ausschließlich **Kennungen und Metadaten**. Die
// tatsächliche Instanziierung, Parameterautomatisierung,
// Fehlerisolation und die kontrollierte Änderung des laufenden Graphen
// sind ausdrücklich **noch offen** und gehören in einen eigenen,
// separat freizugebenden Folgeslice.

/// Vierbuchstabenkennung, wie sie das Audio-Unit-System verwendet.
///
/// Bewusst als reine Umrechnung zwischen `UInt32` und vier
/// ASCII-Zeichen abgebildet — ohne `FourCharCode` aus `CoreAudioTypes`,
/// damit dieser Vertrag framework-frei bleibt.
public enum FourCharacterCode {
    /// Packt genau vier ASCII-Zeichen in einen `UInt32`.
    /// `nil`, wenn der Text nicht aus genau vier ASCII-Zeichen besteht.
    public static func make(_ text: String) -> UInt32? {
        let bytes = Array(text.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            return nil
        }
        return (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }

    /// Die Textform einer Kennung. Nicht darstellbare Bytes werden als
    /// `?` gezeigt, damit eine Anzeige nie abstürzt oder Rohbytes
    /// durchreicht.
    public static func text(of code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes.map { $0 >= 0x20 && $0 <= 0x7E ? Character(UnicodeScalar($0)) : "?" })
    }
}

/// Die eindeutige Identität einer Audio-Unit-Komponente: Typ, Subtyp
/// und Hersteller.
///
/// Erzeugt wird sie ausschließlich über `build(...)` — eine
/// validierende Fabrik nach dem Hausmuster (`Frame.build`,
/// `Zone.build`, `EffectParameters.build`). **Keine stille Korrektur:**
/// jede Regel hat einen eigenen Fehler.
public struct AudioUnitIdentity: Hashable, Sendable {
    /// Der einzige in diesem Slice zugelassene Komponententyp: `aufx`,
    /// ein reiner Audioeffekt.
    ///
    /// **Bewusst nicht zugelassen ist `aumf`** (Music Effect). Ein
    /// Music Effect erwartet MIDI-Eingaben; MIDI gibt es in diesem
    /// Projekt nicht. Ihn hier anzunehmen würde etwas zusagen, was
    /// nicht eingelöst werden kann.
    public static let effectComponentType: UInt32 = 0x6175_6678  // 'aufx'

    public let componentType: UInt32
    public let componentSubType: UInt32
    public let componentManufacturer: UInt32

    public enum BuildError: Error, Equatable {
        /// Der Komponententyp ist kein reiner Audioeffekt (`aufx`).
        case notAnEffectComponent(UInt32)
        /// Subtyp oder Hersteller ist `0` — damit ist die Komponente
        /// nicht eindeutig benennbar.
        case incompleteIdentity(subType: UInt32, manufacturer: UInt32)
    }

    private init(componentType: UInt32, componentSubType: UInt32, componentManufacturer: UInt32) {
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
    }

    public static func build(
        componentType: UInt32,
        componentSubType: UInt32,
        componentManufacturer: UInt32
    ) throws -> AudioUnitIdentity {
        guard componentType == effectComponentType else {
            throw BuildError.notAnEffectComponent(componentType)
        }
        guard componentSubType != 0, componentManufacturer != 0 else {
            throw BuildError.incompleteIdentity(
                subType: componentSubType,
                manufacturer: componentManufacturer
            )
        }
        return AudioUnitIdentity(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer
        )
    }

    /// Lesbare Form, etwa `aufx/dely/appl`. Nur für Anzeige und
    /// Diagnose.
    public var displayCode: String {
        [componentType, componentSubType, componentManufacturer]
            .map(FourCharacterCode.text(of:))
            .joined(separator: "/")
    }
}

/// Ein entdeckter Effektkandidat: Identität plus die Metadaten, die für
/// eine Auswahl gebraucht werden.
///
/// **Enthält keinen Zugriff auf die Komponente selbst** — kein
/// Handle, keine Instanz, nichts Ladbares. Ein Kandidat ist eine
/// Beschreibung, mehr nicht.
public struct AudioUnitEffectCandidate: Equatable, Hashable {
    public let identity: AudioUnitIdentity

    /// Anzeigename der Komponente, wie das System ihn meldet.
    public let name: String

    /// Herstellername, wie das System ihn meldet.
    public let manufacturerName: String

    /// Meldet das System die Komponente als sandbox-tauglich?
    ///
    /// Reine **Metadaten-Durchreichung**, keine Zusicherung von uns.
    /// Sie wird hier geführt, weil sie für die noch offene Frage der
    /// Fehlerisolation beim späteren Instanziieren wesentlich ist —
    /// ausgewertet wird sie in diesem Slice nicht.
    public let isSandboxSafe: Bool

    public init(
        identity: AudioUnitIdentity,
        name: String,
        manufacturerName: String,
        isSandboxSafe: Bool
    ) {
        self.identity = identity
        self.name = name
        self.manufacturerName = manufacturerName
        self.isSandboxSafe = isSandboxSafe
    }
}

/// Identität eines Audio-Unit-Instruments (`aumu`). Sie bleibt bewusst von
/// der Effektidentität getrennt: Instrumente gehören in den Instrument-Slot,
/// niemals seriell in das Audio-FX-Rack.
public struct AudioUnitInstrumentIdentity: Hashable, Sendable {
    public static let componentType: UInt32 = 0x6175_6D75  // 'aumu'

    public let componentSubType: UInt32
    public let componentManufacturer: UInt32

    public init?(componentSubType: UInt32, componentManufacturer: UInt32) {
        guard componentSubType != 0, componentManufacturer != 0 else { return nil }
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
    }

    public var displayCode: String {
        [Self.componentType, componentSubType, componentManufacturer]
            .map(FourCharacterCode.text(of:))
            .joined(separator: "/")
    }
}

/// Reine Katalogbeschreibung eines AU-Instruments. Auswahl und Darstellung
/// laden noch keinen Fremdcode und behaupten keine fertige MIDI-Verdrahtung.
public struct AudioUnitInstrumentCandidate: Equatable, Hashable {
    public let identity: AudioUnitInstrumentIdentity
    public let name: String
    public let manufacturerName: String
    public let isSandboxSafe: Bool

    public init(identity: AudioUnitInstrumentIdentity, name: String, manufacturerName: String, isSandboxSafe: Bool) {
        self.identity = identity
        self.name = name
        self.manufacturerName = manufacturerName
        self.isSandboxSafe = isSandboxSafe
    }
}
