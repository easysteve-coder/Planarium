import SickPLSCore
import SickPLSMacTransport

// Alle Funktionen hier sind reine Formatierung/Berechnung -- kein `print`,
// keine Verbindung -- damit sie ohne Verbindung/Prozess getestet werden
// können. **Geben an keiner Stelle rohe Payload-Bytes aus** (SICK-010-
// Auftrag: „CLI ohne Rohbytes"), nur aggregierte Kennzahlen. Die einzige
// je sichtbare Payload-Stelle bleibt das Kommandobyte im Fehlerfall
// `unexpectedCommandByte` -- bewusst so belassen
// (review-sick-009.md Finding N7).

func hexByte(_ value: UInt8) -> String {
    let hex = String(value, radix: 16, uppercase: true)
    return "0x" + (hex.count < 2 ? "0" + hex : hex)
}

/// Aggregierte Kennzahlen über die Messwerte eines B0-Profils --
/// **keine** Rohwerte, nur zusammengefasste Statistik (SICK-010-Auftrag,
/// schließt `review-sick-009.md` Finding M5: das CLI konnte bisher nur
/// zwei der drei Kriterien der RX-only-Validierungscheckliste belegen,
/// „Wertplausibilität" fehlte).
struct ProfileStatistics: Equatable {
    let measurementCount: Int
    let minimum: UInt16
    let maximum: UInt16
    /// Median als `Double`, weil bei gerader Punktzahl der Mittelwert
    /// zweier `UInt16` gebildet wird -- bei ganzzahligen Eingaben immer
    /// exakt `.0` oder `.5`, also ohne Rundungs-/Formatierungsschwierigkeiten
    /// direkt interpolierbar.
    let median: Double
    let countAtZero: Int
    let countAtMaximum: Int
    let largestNeighborJump: UInt16
}

/// Berechnet ``ProfileStatistics`` über die Messwerte in
/// Empfangsreihenfolge (für den „größten Nachbarsprung" wichtig -- das
/// sind Nachbarn im Sinne des Scanindex, nicht sortierte Nachbarn).
/// `nil` bei leerer Messreihe (0-Punkte-Profil).
func computeStatistics(for measurements: [B0ScanProfile.Measurement]) -> ProfileStatistics? {
    guard !measurements.isEmpty else { return nil }

    let values = measurements.map { $0.value }
    let sortedValues = values.sorted()
    let count = sortedValues.count

    let median: Double
    if count % 2 == 0 {
        median = (Double(sortedValues[count / 2 - 1]) + Double(sortedValues[count / 2])) / 2
    } else {
        median = Double(sortedValues[count / 2])
    }

    var largestJump: UInt16 = 0
    for index in 1..<values.count {
        let difference = values[index] > values[index - 1]
            ? values[index] - values[index - 1]
            : values[index - 1] - values[index]
        largestJump = max(largestJump, difference)
    }

    return ProfileStatistics(
        measurementCount: count,
        minimum: sortedValues.first!,
        maximum: sortedValues.last!,
        median: median,
        countAtZero: values.filter { $0 == 0 }.count,
        countAtMaximum: values.filter { $0 == B0ScanProfile.measurementValueMaximum }.count,
        largestNeighborJump: largestJump
    )
}

func describe(_ statistics: ProfileStatistics) -> String {
    "  Values: min=\(statistics.minimum) max=\(statistics.maximum) median=\(statistics.median) "
        + "countAtZero=\(statistics.countAtZero)/\(statistics.measurementCount) "
        + "countAt\(B0ScanProfile.measurementValueMaximum)=\(statistics.countAtMaximum)/\(statistics.measurementCount) "
        + "largestNeighborJump=\(statistics.largestNeighborJump)"
}

/// Beschreibt einen ausgelieferten Frame als eine oder mehrere Zeilen.
/// Bei einem erfolgreich decodierten B0-Profil mit mindestens einem
/// Messpunkt folgt eine zweite Zeile mit ``ProfileStatistics``.
func describe(_ frame: Frame) -> [String] {
    let addressHex = hexByte(frame.address)
    switch B0ScanProfile.decode(from: frame.payload) {
    case .success(let profile):
        var lines = [
            "B0 addr=\(addressHex) measurements=\(profile.measurements.count) "
                + "partialScanIndex=\(profile.partialScanIndex) trailingBytes.count=\(profile.trailingBytes.count)"
        ]
        if let statistics = computeStatistics(for: profile.measurements) {
            lines.append(describe(statistics))
        }
        return lines
    case .failure(let error):
        return ["Frame addr=\(addressHex) payload.count=\(frame.payload.count) (not a B0 profile: \(error))"]
    }
}

/// Kennzeichnet die gewählte Baudrate mit ihrem Evidenzstand -- damit ein
/// Betrachter der CLI-Ausgabe nie annehmen muss, „9600" oder „38400" seien
/// gleichwertig abgesichert (SICK-010-Scope-Änderung, siehe
/// `SerialPortSettings.swift`-Kopfkommentar zu `SerialPortBaudRate`). Rein
/// deskriptiv für eine RX-only-Verbindung bei genau diesem Wert -- kein
/// Hinweis auf einen Wechselmechanismus, den es hier nicht gibt.
func describe(_ baudRate: SerialPortBaudRate) -> String {
    switch baudRate {
    case .baud9600:
        return "\(baudRate.rawValue) 8E1 (RX starting value, reported by owner 2026-09-21, not yet validated on the real port)"
    case .baud38400:
        return "\(baudRate.rawValue) 8E1 (RX target value, historically verified live; no longer the connected scanner starting value since 2026-09-21)"
    case .baud500000:
        return "\(baudRate.rawValue) 8E1 (RS-422, verified live on the real scanner 2026-09-23)"
    }
}

func describe(_ diagnostics: StreamParser.Diagnostics) -> String {
    "Diagnostics: valid=\(diagnostics.validFrames) "
        + "discarded=\(diagnostics.discardedCandidates) "
        + "(oversize=\(diagnostics.discardedCandidatesOversize) "
        + "crc=\(diagnostics.discardedCandidatesChecksumMismatch) "
        + "atFinish=\(diagnostics.discardedCandidatesAtFinish)) "
        + "noise=\(diagnostics.skippedNoiseBytes)"
}

let usageText = """
sick-pls-diag -- RX-only diagnostics for the SICK PLS101-316

Never connects automatically. Nothing happens without --port.

Options (RX-only mode, default):
  --list-ports             list /dev/cu.* paths without connecting
  --port <path>            explicit serial port, e.g. /dev/cu.usbserial-A1
  --baud <9600|38400|500000> required when connecting; no auto-baud
  --duration <seconds>     close the session cleanly after this time
  --index <n>              collect a reference series for scan index n (0–360,
                           repeatable); export statistics only, no raw values
  --help                  show this help

Baud rates (RX only; no rate changes on the device):
  9600   reported starting value; not yet validated on the real port
  38400  historically verified target value
  500000 verified live over RS-422; exact IOSSIOSPEED on macOS, no substitute
Fixed format: 8 data bits, even parity, 1 stop bit, no flow control.
The receive port is O_RDONLY. No raw bytes or captures are printed.

Active opt-in options:
  --probe-baud             active identity probe instead of RX-only
  --target-address <n>     0–255 except 129/0x81; default 0 (universal address)
The active identity probe sends exactly one stateless 0x31 telegram per
candidate (9600, then 38400 baud). Only a CRC-valid 0xB1 reply confirms it.
No login, baud switch or scan-mode switch is implemented here.
Target, candidate rates and effect are shown before sending. Reply payload
is never printed. Ctrl-C closes cleanly, as does --duration.
"""
