import PlanariumDomain
// Die **prüfbaren Maße und Tokens des Kanalzugs** (SICK-033a-0,
// SICK-033c) -- ohne SwiftUI, damit sie ohne gerenderte Ansicht geprüft
// werden können und **an genau einer Stelle** stehen. Die SwiftUI-Schicht
// des App-Ziels (`ChannelStripDesignTokens`) liest ausschließlich diese
// Werte; sie legt keine zweite Zahl fest.
//
// ## Referenz
//
// HELMUT R340 ist die Gesamtbild-, R315 die Zeilenreferenz (ROADMAP §4,
// „Channelstrip"). Die Referenzzeile ist **16 pt** hoch. Diese Höhe ist
// eine **Sicht**maßgabe: Die reale Bedienfläche jeder Zeile ist
// ``rowHitHeight`` (22 pt, die macOS-12-Mindesthöhe eines Standard-
// Bedienelements), Fokus- und Tastaturbedienung laufen über die
// Systemwidgets. Die Zahlen sind für macOS 12 neu umgesetzt, **keine**
// Behauptung pixelgenauer Übereinstimmung; der Referenzvergleich mit
// Messwerten ist im Slice-Protokoll dokumentiert.
//
// ## Verbindliche Stripbreite
//
// `END_PRODUCT_ROADMAP.md` verlangt vor SICK-033a eine verbindliche
// Stripbreite und Mindestbedienfläche. Eine Owner-Zahl liegt nicht vor;
// die Werte unten sind der **dokumentierte Startwert** dieses Slices
// (Kennzeichnung wie `GatePolicy.standard`), an genau dieser Stelle
// änderbar.

import Foundation

/// Ein Farbwert ohne Framework: `0...1` je Kanal.
public struct StripColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Relative Leuchtdichte nach WCAG 2.1 (sRGB).
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Kontrastverhältnis nach WCAG 2.1, `1...21`.
    public func contrastRatio(against other: StripColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Die Einträge des Kanalzugs in fester Reihenfolge -- **Ziel,
/// Prozessor oder Ausgang**, nie mehreres zugleich (ROADMAP §3,
/// „Feld- und Insertmodell").
public enum ChannelStripEntry: String, Equatable, Hashable, Sendable, CaseIterable {
    case pitch
    case volume
    case filter
    case gate
    case effectSend
    case synth
    case delay
    case reverb
    case audioUnits
    case audioOutput
    case midiOutput
    case diagnostics

    public enum Kind: Equatable, Sendable {
        /// Ein Kontrollziel: seine Karte zeigt Zuordnung und Deutung.
        case controlTarget
        /// Ein Prozessor: Ein/Aus ist Parameteraktivierung bzw. Bypass.
        case processor
        /// Ein Ausgang: Ein/Aus startet bzw. stoppt ausdrücklich.
        case output
        /// Reine Anzeige.
        case readout
    }

    public var kind: Kind {
        switch self {
        case .pitch, .volume, .filter, .gate, .effectSend: return .controlTarget
        case .synth, .delay, .reverb, .audioUnits: return .processor
        case .audioOutput, .midiOutput: return .output
        case .diagnostics: return .readout
        }
    }

    /// Der Zeilentitel -- kurz, weil die Zeile schmal ist.
    public var title: String {
        switch self {
        case .pitch: return "Pitch"
        case .volume: return "Volume"
        case .filter: return "Filter"
        case .gate: return "Gate"
        case .effectSend: return "Effect send"
        case .synth: return "Synth"
        case .delay: return "Delay"
        case .reverb: return "Hall"
        case .audioUnits: return "Audio Units"
        case .audioOutput: return "Audio"
        case .midiOutput: return "MIDI"
        case .diagnostics: return "Diagnostics"
        }
    }

    /// Der Accessibility-Bezeichner der Zeile.
    public var accessibilityIdentifier: String { "strip.row.\(rawValue)" }
}

/// Die Maße und Farben -- **die eine Stelle**.
public enum ChannelStripLayout {
    /// Der Standard-Innenabstand des rechten Bereichs (SwiftUI `padding()`).
    public static let paneInset = 16.0
    /// Fester 220-pt-Inspector links, 72 pt breiter Strip ganz rechts.
    /// Skala, Fader und Meter teilen sich die verdichtete Kanalzugbreite.
    public static let stripWidth = 72.0
    /// Fader-Zeile innerhalb von `stripWidth` minus 2 × 5 pt Rand:
    /// Faderskala · Fader · Pegelanzeige (dB-Ziffern + zwei Balken).
    /// Owner 07.10.2026: Bei 18 pt Pegelbreite blieb für die Balken nichts.
    public static let faderScaleWidth = 16.0
    public static let faderWidth = 18.0
    public static let meterWidth = 26.0
    public static let meterLabelWidth = 10.0
    public static let meterBarMinimumWidth = 6.0
    public static let faderRowSpacing = 1.0
    public static let inspectorWidth = 220.0
    public static let sidePanelSpacing = 1.0
    /// Sichthöhe einer Zeile: die 16-pt-Referenzzeile (R315).
    public static let rowVisualHeight = 16.0
    /// Reale Bedienfläche einer Zeile: macOS-12-Mindesthöhe.
    public static let rowHitHeight = 22.0
    /// Kleinste quadratische Bedienfläche (Schalter, Plakette).
    public static let minimumHitTarget = 22.0
    /// Abstand zwischen Zeilen.
    public static let rowSpacing = 2.0
    /// Innenabstand einer Zeile und der Karte.
    public static let inset = 8.0
    /// Der Inspector steht neben dem Strip; seine Höhe bleibt fest, damit
    /// ein Eintragswechsel die Arbeitsfläche nicht springen lässt.
    public static let cardHeight = 780.0
    /// Eckenradius von Zeile und Karte.
    public static let cornerRadius = 4.0
    /// Schriftgröße der Zeile (Monospace) und der Mikrotexte.
    public static let rowFontSize = 11.0
    public static let microFontSize = 10.0

    // Farben, von der FIRSTofFIFTH-/HELMUT-Palette abgeleitet: dunkle
    // Paneele, Amber als Auswahl-/Statusfarbe.
    public static let panelBackground = StripColor(red: 0.11, green: 0.11, blue: 0.13)
    public static let rowBackground = StripColor(red: 0.16, green: 0.16, blue: 0.19)
    public static let rowSelectedBackground = StripColor(red: 0.24, green: 0.22, blue: 0.16)
    public static let primaryText = StripColor(red: 0.92, green: 0.92, blue: 0.94)
    public static let secondaryText = StripColor(red: 0.70, green: 0.70, blue: 0.74)
    public static let accent = StripColor(red: 1.0, green: 0.75, blue: 0.2)
    public static let activeIndicator = StripColor(red: 0.35, green: 0.85, blue: 0.45)
    public static let inactiveIndicator = StripColor(red: 0.40, green: 0.40, blue: 0.45)
    public static let warning = StripColor(red: 0.95, green: 0.35, blue: 0.30)

    /// Die feste macOS-12-Referenzszene (SICK-033a-0): ein definierter
    /// Zustand, in dem Bilder aufgenommen und mit der Referenz verglichen
    /// werden. Nur Werte, keine Ansicht.
    public struct ReferenceScene: Equatable, Sendable {
        public let selectedEntry: ChannelStripEntry
        public let enabledEntries: Set<ChannelStripEntry>
        public let activeEntries: Set<ChannelStripEntry>

        public static let standard = ReferenceScene(
            selectedEntry: .gate,
            enabledEntries: [.pitch, .volume, .gate, .synth, .delay, .audioOutput],
            activeEntries: [.pitch, .volume]
        )
    }
}
