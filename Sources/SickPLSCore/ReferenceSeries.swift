// Referenzreihen für die reale Scannerabnahme (SICK-034d): Für einzelne,
// ausdrücklich per `--index` benannte Scanindizes sammelt das RX-only-CLI
// die Rohwerte über die Sitzung und gibt am Ende **nur Kennzahlen** aus --
// Anzahl, Minimum, Maximum, Median, Mittelwert, Standardabweichung und
// die Zahl der Nullwerte. Das ist die Streuung, die eine spätere
// Meteranzeige belegen muss (CLAUDE.md: „Keine Meteranzeige ohne
// dokumentierte reale Kalibrierung mit Referenzdistanzen und Streuung").
// Kein Rohwert verlässt einzeln den Prozess; die Reihe selbst bleibt
// intern. Reine Berechnung ohne `print`, damit sie ohne Verbindung
// geprüft werden kann.

/// Die Kennzahlen einer Referenzreihe. Rohwerte tragen keine
/// physikalische Einheit (`b0-scan-profile.md` §1) -- die Umrechnung in
/// Meter ist ausdrücklich **nicht** Teil dieses Typs.
/// Größter zulässiger Referenzindex: das größte real beobachtete Profil
/// hatte 361 Punkte (`b0-scan-profile.md`), Index 360 ist der letzte.
///
/// Einzige Stelle, an der diese Grenze steht. Sie stand bis zum 28.09.2026
/// in drei Kopien über zwei Ziele verteilt — CLI-Argumentprüfung und zweimal
/// im Messmodell. Zwei Grenzen für denselben Index wären eine Einladung zum
/// Abdriften.
public let referenceIndexMaximum = 360

public struct ReferenceSeriesStatistics: Equatable, Sendable {
    public let index: Int
    public let sampleCount: Int
    public let minimum: UInt16
    public let maximum: UInt16
    public let median: Double
    public let mean: Double
    /// Stichproben-Standardabweichung (n − 1); `0` bei einer Stichprobe.
    public let standardDeviation: Double
    public let countAtZero: Int
    public let countAtMaximum: Int
    /// Profile, die den Index nicht enthielten (z. B. 90-Punkt-Profil bei
    /// `--index 180`). Sichtbar, damit eine leere Reihe erklärt ist.
    public let profilesWithoutIndex: Int
}

/// Sammelt den Rohwert eines festen Scanindex aus jedem Profil.
public struct ReferenceIndexSeries: Equatable, Sendable {
    let index: Int
    /// Der Drahtwert ist auf 13 Bit begrenzt. Die Häufigkeitstabelle bleibt
    /// deshalb unabhängig von der Zahl der aufgezeichneten Profile konstant.
    private var histogram: [Int]
    private var sampleCount = 0
    private var sum = 0
    private var sumOfSquares = 0
    private var minimum: UInt16 = B0ScanProfile.measurementValueMaximum
    private var maximum: UInt16 = 0
    public private(set) var profilesWithoutIndex = 0

    public init(index: Int) {
        self.index = index
        histogram = Array(
            repeating: 0,
            count: Int(B0ScanProfile.measurementValueMaximum) + 1
        )
    }

    public mutating func record(_ profile: B0ScanProfile) {
        guard profile.measurements.indices.contains(index) else {
            profilesWithoutIndex += 1
            return
        }
        let value = profile.measurements[index].value
        // Tragende Vorbedingung: ``B0ScanProfile.Measurement`` lässt keinen
        // Wert über 13 Bit zu -- der Parser maskiert mit `hi & 0x1F`, die
        // öffentliche ``Measurement.build(value:fieldFlags:)`` wirft
        // `valueExceedsThirteenBits`. Nur deshalb ist dieser Zugriff ohne
        // eigene Bereichsprüfung sicher. Fällt diese Zusicherung, stürzt
        // diese Zeile ab, statt still falsch zu zählen.
        let integerValue = Int(value)
        histogram[integerValue] += 1
        sampleCount += 1
        sum += integerValue
        sumOfSquares += integerValue * integerValue
        minimum = min(minimum, value)
        maximum = max(maximum, value)
    }

    /// `nil`, solange kein einziger Wert vorliegt.
    public func statistics() -> ReferenceSeriesStatistics? {
        guard sampleCount > 0 else { return nil }
        let count = sampleCount
        let median: Double
        if count % 2 == 0 {
            let lower = value(atSortedOffset: count / 2 - 1)
            let upper = value(atSortedOffset: count / 2)
            median = (Double(lower) + Double(upper)) / 2
        } else {
            median = Double(value(atSortedOffset: count / 2))
        }
        let mean = Double(sum) / Double(count)
        let variance: Double
        if count > 1 {
            let numerator = Double(sumOfSquares) - Double(sum) * mean
            variance = max(0, numerator / Double(count - 1))
        } else {
            variance = 0
        }
        return ReferenceSeriesStatistics(
            index: index,
            sampleCount: count,
            minimum: minimum,
            maximum: maximum,
            median: median,
            mean: mean,
            standardDeviation: variance.squareRoot(),
            countAtZero: histogram[0],
            countAtMaximum: histogram[Int(B0ScanProfile.measurementValueMaximum)],
            profilesWithoutIndex: profilesWithoutIndex
        )
    }

    private func value(atSortedOffset offset: Int) -> UInt16 {
        var remaining = offset
        for (value, frequency) in histogram.enumerated() {
            if remaining < frequency { return UInt16(value) }
            remaining -= frequency
        }
        preconditionFailure("Histogram contains too few values")
    }
}

/// Eine Zeile je Referenzreihe -- Kennzahlen, keine Rohwerte.
public func describe(_ statistics: ReferenceSeriesStatistics) -> String {
    "Reference index \(statistics.index): n=\(statistics.sampleCount) "
        + "min=\(statistics.minimum) max=\(statistics.maximum) "
        + "median=\(statistics.median) "
        + "mean=\(formatted(statistics.mean)) "
        + "sigma=\(formatted(statistics.standardDeviation)) "
        + "countAtZero=\(statistics.countAtZero) "
        + "countAt\(B0ScanProfile.measurementValueMaximum)=\(statistics.countAtMaximum) "
        + "withoutIndex=\(statistics.profilesWithoutIndex)"
}

/// Die Zeile für eine Reihe ohne einen einzigen Wert.
public func describeEmptyReferenceSeries(_ series: ReferenceIndexSeries) -> String {
    "Reference index \(series.index): no values (profiles without this index: \(series.profilesWithoutIndex))"
}

/// Zwei Nachkommastellen, Punkt als Dezimaltrenner -- maschinenlesbar und
/// lokalunabhängig.
private func formatted(_ value: Double) -> String {
    let scaled = (value * 100).rounded()
    let integerPart = Int(scaled) / 100
    let fraction = abs(Int(scaled) % 100)
    return "\(integerPart).\(fraction < 10 ? "0" : "")\(fraction)"
}
