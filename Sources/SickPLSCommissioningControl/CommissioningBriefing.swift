import SickPLSCommissioning
import SickPLSMacTransport

/// Was **vor jeder Handlung** dauerhaft sichtbar sein muss (SICK-032a,
/// Bedienvertrag Punkt 1).
///
/// **Der Text entsteht im Modell, nie erst in der Ansicht** — dieselbe
/// Regel wie bei `PerformanceNotice` (SICK-028) und `PortAccessNotice`
/// (SICK-030a1). Eine Warnung, die in einer SwiftUI-Datei steht, hat kein
/// Testziel und kann unbemerkt verschwinden.
///
/// **Es gibt bewusst keinen Wähler.** Ausgangsrate, Zielrate, Adressen
/// und Telegramme stehen gekoppelt in ``CommissioningRecipe/r26``
/// (Auflage A4); dieser Typ **liest** sie und bietet nichts an, was man
/// verstellen könnte.
public struct CommissioningBriefing: Equatable {

    /// Der ausgewählte Port. Leer, solange keiner gewählt ist.
    public let portPath: String
    /// Die Rate, bei der der Ablauf beginnt.
    public let startingBaudRate: SerialPortBaudRate
    /// Die Rate, die er belegen will.
    public let targetBaudRate: SerialPortBaudRate

    init(portPath: String, recipe: CommissioningRecipe) {
        self.portPath = portPath
        self.startingBaudRate = recipe.startingBaudRate
        self.targetBaudRate = recipe.targetBaudRate
        self.recoveryHint = CommissioningFailure.abortedByOperator.recoveryHint
    }

    /// Der Rückweg-Hinweis — **unverändert aus dem Modell übernommen**,
    /// nicht hier neu formuliert: Es gibt kein belegtes Telegramm zurück
    /// auf die Ausgangsrate, und ein Geräteneustart ist der einzige
    /// bekannte Rückweg.
    public let recoveryHint: String

    /// Die feste Übertragungsform beider Raten (`wire-protocol.md`
    /// Abschnitt 1) — 8 Datenbits, gerade Parität, 1 Stoppbit, keine
    /// Flusssteuerung. Sie ist in ``SerialPortSettings`` gekoppelt und
    /// ebenfalls nicht wählbar.
    public static let frameFormat = "8E1, no flow control"

    /// Was der Vorgang am Gerät tut — in einem Satz, ohne Beschönigung.
    public var effectDescription: String {
        "This operation actively configures the scanner: it logs in and "
            + "switches it from \(startingBaudRate.rawValue) baud to "
            + "\(targetBaudRate.rawValue) baud."
    }

    /// Die vollständige, dauerhaft anzuzeigende Vorabinformation.
    public var lines: [String] {
        [
            portPath.isEmpty ? "Port: none selected" : "Port: \(portPath)",
            "Start: \(startingBaudRate.rawValue) Baud, \(Self.frameFormat)",
            "Target: \(targetBaudRate.rawValue) Baud, \(Self.frameFormat)",
            effectDescription,
            recoveryHint
        ]
    }
}
