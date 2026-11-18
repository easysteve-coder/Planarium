import Foundation
import PLSDeviceValues

/// M-1a: Übersetzt eine alte Polaradresse in die Menge der neuen
/// `PolarDeviceLattice`-Zellen, deren zulässige 361-Punkt-Geräteproben
/// unter dem alten Gitter und der alten Adressfunktion in der Altzelle
/// aktiviert hätten.
///
/// **Verfielfachung:** Eine Altzelle wird zu **120** neuen Zellen
/// (Beleg: `(ring: 2, angularIndex: 8)`, `cellSizeMeters == 0.5`).
/// Grund: dieselbe physische Fläche wird radial zehnfach (5-cm-Ringe
/// statt 50-cm-Ringe) und winklig zusätzlich verfeinert (adaptiver
/// Sektor statt fester 22,5°), deshalb 120 statt 10.
///
/// **Exakte Zugehörigkeitsprüfung (M-1a2):** Die Zugehörigkeit einer
/// Geräteprobe zur Altzelle wird in Ganzzahlen entschieden — in
/// Zentimetern für den Radius und in der Form `(180 + tick) · 2^k`
/// für die Peilung. Die alte Adressfunktion
/// (`PolarMetricGridCell(point:grid:)`) wird **nicht** aufgerufen:
/// sie stützt sich auf `sin`, `cos`, `atan2` und `hypot`, deren
/// letztes Bit zwischen Mathematikbibliotheken und Architekturen
/// nicht zugesichert ist. An der Ringgrenze `raw == 150` konnte die
/// alte Funktion um einen Ring daneben liegen; das war nicht
/// reproduzierbar. Ein gespeichertes Dokument darf nicht von der
/// Mathematikbibliothek abhängen.
public enum LegacyLatticeMigration {

    /// Inverse editing projection using the same exact dyadic membership
    /// decision as migration. Device addresses never pass through trig.
    public static func project(_ cell: PolarDeviceLattice, in grid: MetricSquareGrid) throws -> PolarMetricGridCell {
        let centimeters = try centimeterGrid(grid)
        let ring = cell.ring / centimeters
        return .init(ring: ring, angularIndex: (180 + cell.sector) * angularDivisor(forRing: ring) / 180)
    }

    public static func validateEditorGrid(_ grid: MetricSquareGrid) throws {
        _ = try centimeterGrid(grid)
    }

    // MARK: - Fehler

    /// Ablehnungsgründe bei der Migration.
    public enum MigrationError: Error, Equatable, Sendable {
        /// Das Altraster ist kein ganzzahliges Zentimetermaß.
        case nonIntegerCentimeterGrid(Double)
    }

    // MARK: - Ergebnis

    /// Befund der Migration: Zellmenge, optionaler Verlustgrund und
    /// radialer Teilverlust in Zentimetern.
    ///
    /// **Invariante:** `lossReason` ist genau dann vorhanden, wenn
    /// `cells` leer ist. Der Typ kann nicht widersprüchlich gebaut
    /// werden — nur ``LegacyLatticeMigration/migrate(_:in:)`` erzeugt
    /// eine Instanz.
    public struct MigrationResult: Equatable, Sendable {

        /// Verlustgründe; schließen sich gegenseitig aus.
        public enum LossReason: Equatable, Sendable {
            /// Altzelle vollständig außerhalb des Scannerfelds
            /// (winklig ganz unter/oberhalb oder radial ganz außerhalb).
            case fullyOutsideScannerField
            /// Altzelle im oder am Feld, aber ohne zulässige Geräteprobe.
            case noValidDeviceProbe
        }

        /// Die migrierten Zellen (leer, wenn `lossReason` vorhanden).
        public let cells: Set<PolarDeviceLattice>

        /// Verlustgrund; `nil` genau dann, wenn `cells` nicht leer ist.
        public let lossReason: LossReason?

        /// Radialer Teilverlust in Zentimetern.
        /// 0, wenn die Zelle das Feld nicht erreicht (`fullyOutsideScannerField`).
        public let radialPartialLossCentimeters: Int

        fileprivate init(
            cells: Set<PolarDeviceLattice>,
            lossReason: LossReason?,
            radialPartialLossCentimeters: Int
        ) {
            self.cells = cells
            self.lossReason = lossReason
            self.radialPartialLossCentimeters = radialPartialLossCentimeters
        }
    }

    // MARK: - Rastermaß

    /// Ganzzahliges Zentimetermaß des Altrasters.
    ///
    /// Einzige Stelle, an der aus dem Gleitkommamaß eine Ganzzahl wird. Eine
    /// zweite Umrechnung ohne diese Prüfung wäre still falsch: `0.29 * 100`
    /// ist in IEEE `28.999999999999996`, und `Int(...)` schneidet daraus eine
    /// **28**. Die Prüfung lehnt solche Raster vorher ab, deshalb ist die
    /// Umrechnung danach exakt.
    internal static func centimeterGrid(_ grid: MetricSquareGrid) throws -> Int {
        let cellSizeCm = grid.cellSizeMeters * 100
        guard cellSizeCm.isFinite, cellSizeCm > 0, cellSizeCm < Double(Int.max),
              cellSizeCm.truncatingRemainder(dividingBy: 1) == 0
        else {
            throw MigrationError.nonIntegerCentimeterGrid(grid.cellSizeMeters)
        }
        return Int(cellSizeCm)
    }

    // MARK: - Peilungsentscheidung

    /// `2^k` für das kleinste `k ≥ 0` mit
    /// `3·2^k·10^9 ≥ (ring+1)·3_141_592_654`.
    ///
    /// Einzige Stelle, an der dieser Vertragsexponent gerechnet wird. Eine
    /// zweite Kopie könnte abdriften und Feldgrenze und Tickmenge
    /// auseinanderlaufen lassen.
    internal static func angularDivisor(forRing ring: Int) -> Int {
        let piBound = 3_141_592_654
        let scale = 1_000_000_000
        let ringPlusOne = ring + 1
        var k = 0
        while 3 * (1 << k) * scale < ringPlusOne * piBound {
            k += 1
        }
        return 1 << k
    }


    /// Liefert die aufsteigend sortierte Liste aller Ticks `0…360`, die die
    /// exakte dyadische Bedingung
    /// `180·angularIndex ≤ (180+tick)·2^k < 180·(angularIndex+1)`
    /// erfüllen, wobei `k` das kleinste `k ≥ 0` mit
    /// `3·2^k·10^9 ≥ (ring+1)·3_141_592_654` ist.
    ///
    /// Die Funktion kennt kein Rastermaß und hat nichts abzulehnen.
    internal static func bearingTicks(forRing ring: Int, angularIndex: Int) -> [Int] {
        let twoToK = angularDivisor(forRing: ring)

        let bearingLower = 180 * angularIndex
        let bearingUpper = 180 * (angularIndex + 1)

        var ticks: [Int] = []
        for tick in 0...PolarDeviceLattice.maxTick {
            let tickScaled = (180 + tick) * twoToK
            if tickScaled >= bearingLower, tickScaled < bearingUpper {
                ticks.append(tick)
            }
        }
        return ticks
    }

    /// Rejects synthetic legacy addresses before any ring/angle arithmetic.
    /// The extra ring intentionally permits the existing
    /// `fullyOutsideScannerField` loss at the first wholly out-of-range cell.
    internal static func isSafeLegacyAddress(
        _ cell: PolarMetricGridCell,
        cellSizeCentimeters: Int
    ) -> Bool {
        guard cellSizeCentimeters > 0, cell.ring >= 0 else { return false }
        let maximumRing = 8_190 / cellSizeCentimeters + 1
        guard cell.ring <= maximumRing else { return false }
        let divisor = angularDivisor(forRing: cell.ring)
        // Migration's field test accepts indices through 3·divisor; keep one
        // extra divisor as a finite arithmetic envelope for its upper edge.
        return cell.angularIndex >= 0 && cell.angularIndex < divisor * 4
    }

    /// Zählt die möglichen Zieladressen vor der Materialisierung. Für eine
    /// kartesische Zusammenführung ist die Summe eine konservative obere
    /// Schranke, weil mehrere Altzellen dieselbe Zieladresse liefern können.
    internal static func estimatedTargetCount(
        _ legacyCell: PolarMetricGridCell,
        in grid: MetricSquareGrid
    ) throws -> Int {
        let cellSizeCm = try centimeterGrid(grid)
        let ring = legacyCell.ring
        let index = legacyCell.angularIndex
        guard isSafeLegacyAddress(legacyCell, cellSizeCentimeters: cellSizeCm) else {
            return 0
        }
        let twoToK = angularDivisor(forRing: ring)
        let lowerBearing = 180 * index
        let upperBearing = 180 * (index + 1)
        if upperBearing <= 180 * twoToK || lowerBearing > 540 * twoToK {
            return 0
        }
        let inner = ring.multipliedReportingOverflow(by: cellSizeCm)
        let outerRing = (ring + 1).multipliedReportingOverflow(by: cellSizeCm)
        guard !inner.overflow, !outerRing.overflow else { return Int.max }
        let rawLower = max(Int(UsableRawDistance.lowestRawValue), inner.partialValue)
        let rawUpper = min(Int(UsableRawDistance.highestRawValue), outerRing.partialValue - 1)
        guard rawLower <= rawUpper else { return 0 }
        let rawCount = rawUpper - rawLower + 1
        let tickCount = bearingTicks(forRing: ring, angularIndex: index).count
        let count = tickCount.multipliedReportingOverflow(by: rawCount)
        return count.overflow ? Int.max : count.partialValue
    }

    /// Liefert dieselbe Feldgrenze wie `migrate`, ohne Zielzellen zu
    /// materialisieren. Eine Zelle gilt als innen, sobald sie das
    /// Scannerfeld auch nur teilweise erreicht; `noValidDeviceProbe` ist
    /// deshalb weiterhin auswählbar und wird erst bei der Migration gemeldet.
    public static func isInsideScannerField(
        _ legacyCell: PolarMetricGridCell,
        in grid: MetricSquareGrid
    ) throws -> Bool {
        let cellSizeCm = try centimeterGrid(grid)
        return !isFullyOutsideScannerField(legacyCell, cellSizeCentimeters: cellSizeCm)
    }

    private static func isFullyOutsideScannerField(
        _ legacyCell: PolarMetricGridCell,
        cellSizeCentimeters: Int
    ) -> Bool {
        guard isSafeLegacyAddress(legacyCell, cellSizeCentimeters: cellSizeCentimeters) else { return true }
        let divisor = angularDivisor(forRing: legacyCell.ring)
        let lowerBearing = 180 * legacyCell.angularIndex
        let upperBearing = 180 * (legacyCell.angularIndex + 1)
        return upperBearing <= 180 * divisor
            || lowerBearing > 540 * divisor
            || legacyCell.ring * cellSizeCentimeters > 8190
    }

    // MARK: - Migration

    /// Übersetzt die alte Polarzelle `legacyCell` (im Gitter `grid`) in
    /// die Menge aller neuen `PolarDeviceLattice`-Adressen, deren
    /// Geräteproben unter der alten Adressierung in `legacyCell` liegen.
    ///
    /// Die Zugehörigkeit wird exakt in Ganzzahlen geprüft:
    /// - Radius: `ring·cs ≤ raw < (ring+1)·cs` in Zentimetern.
    /// - Peilung: `180·angularIndex ≤ (180+tick)·2^k < 180·(angularIndex+1)`,
    ///   wobei `k` das kleinste `k ≥ 0` mit `3·2^k ≥ (ring+1)·π` ist
    ///   (entschieden über die rationale Schranke `3_141_592_654/10^9`).
    ///
    /// - Parameters:
    ///   - legacyCell: Die alte Polaradresse.
    ///   - grid: Das alte metrische Raster.
    /// - Returns: Ein ``MigrationResult`` mit Zellmenge, optionalem
    ///   Verlustgrund und radialem Teilverlust.
    /// - Throws: ``MigrationError/nonIntegerCentimeterGrid(_:)``, wenn das
    ///   Rastermaß kein ganzzahliges Zentimetermaß ist.
    public static func migrate(
        _ legacyCell: PolarMetricGridCell,
        in grid: MetricSquareGrid
    ) throws -> MigrationResult {

        // B2: Altraster muss ein ganzzahliges Zentimetermaß sein.
        let cellSizeCmInt = try centimeterGrid(grid)

        guard !isFullyOutsideScannerField(legacyCell, cellSizeCentimeters: cellSizeCmInt) else {
            return MigrationResult(
                cells: [], lossReason: .fullyOutsideScannerField,
                radialPartialLossCentimeters: 0
            )
        }

        let ring = legacyCell.ring
        let idx = legacyCell.angularIndex

        // Exakte Radiusgrenzen in Zentimetern (halboffen [inner, outer)).
        let innerCm = ring * cellSizeCmInt
        let outerCm = (ring + 1) * cellSizeCmInt

        // Rohwertbereich einschränken auf brauchbare Werte.
        let rawLower = max(Int(UsableRawDistance.lowestRawValue), innerCm)
        let rawUpper = min(Int(UsableRawDistance.highestRawValue), outerCm - 1)

        // Peilungsentscheidung über die eigenständige Funktion.
        let validTicks = bearingTicks(forRing: ring, angularIndex: idx)

        var cells: Set<PolarDeviceLattice> = []
        if rawLower <= rawUpper {
            for tick in validTicks {
                for rawCm in rawLower...rawUpper {
                    if let lattice = PolarDeviceLattice(tick: tick, rawCentimeters: UInt16(rawCm)) {
                        cells.insert(lattice)
                    }
                }
            }
        }

        // Radialer Teilverlust: nur relevant, wenn die Zelle das Feld erreicht.
        let radialLoss = max(0, (ring + 1) * cellSizeCmInt - 1 - 8190)

        if cells.isEmpty {
            return MigrationResult(
                cells: [],
                lossReason: .noValidDeviceProbe,
                radialPartialLossCentimeters: radialLoss
            )
        }

        return MigrationResult(
            cells: cells,
            lossReason: nil,
            radialPartialLossCentimeters: radialLoss
        )
    }
}
