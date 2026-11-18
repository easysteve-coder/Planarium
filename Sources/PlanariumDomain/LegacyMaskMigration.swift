import Foundation
import PLSDeviceValues

/// M-1b-b2: Vereinigt die Migrationsergebnisse aller bemalten Altzellen
/// einer Ebene und berichtet Maske, Randzuwachs und Verluste getrennt.
///
/// **Wichtige Anmerkung:** Die Vereinigung der Migrationsergebnisse ist
/// eine **empfohlene, noch nicht vom Owner beschlossene** Produktpolitik
/// (Ownerentscheidung vom 28.09.2026: offen). Dieser Code berechnet den
/// Wert für Tests und Berichte; er stellt keine Freigabe dar.
///
/// **Ganzzahlig:** Diese Datei verwendet keine Transzendental- oder
/// Gleitkomma-Konstruktoren. Alle Entscheidungen fallen in Ganzzahlen.
public enum LegacyMaskMigration {

    // MARK: - Ergebnis

    /// Befund der Maskenmigration: Vereinigung, Randzuwachs, Verluste.
    ///
    /// **Invariante:** Der Initialisierer ist nicht öffentlich.
    /// Nur ``LegacyMaskMigration/migrate(paintedCells:in:)`` erzeugt
    /// eine Instanz.
    public struct Result: Equatable, Sendable {

        /// Die Vereinigungsmaske aller migrierten Zellen.
        public let cells: Set<PolarDeviceLattice>

        /// Anzahl der Proben in der Maske, deren Altbesitzer nicht bemalt ist.
        public let edgeGrowthProbeCount: Int

        /// Die Maskenzellen, in denen mindestens eine Randzuwachs-Probe liegt.
        public let edgeGrowthCells: Set<PolarDeviceLattice>

        /// Bemalte Altzellen, deren Migration leer war, mit Verlustgrund.
        public let fullyLost: [PolarMetricGridCell: LegacyLatticeMigration.MigrationResult.LossReason]

        /// Radialer Teilverlust in Zentimetern; nur Einträge > 0.
        public let radialPartialLossCentimeters: [PolarMetricGridCell: Int]

        fileprivate init(
            cells: Set<PolarDeviceLattice>,
            edgeGrowthProbeCount: Int,
            edgeGrowthCells: Set<PolarDeviceLattice>,
            fullyLost: [PolarMetricGridCell: LegacyLatticeMigration.MigrationResult.LossReason],
            radialPartialLossCentimeters: [PolarMetricGridCell: Int]
        ) {
            self.cells = cells
            self.edgeGrowthProbeCount = edgeGrowthProbeCount
            self.edgeGrowthCells = edgeGrowthCells
            self.fullyLost = fullyLost
            self.radialPartialLossCentimeters = radialPartialLossCentimeters
        }
    }

    // MARK: - Migration

    /// Migriert die Menge bemalter Altzellen auf das Geräteraster.
    ///
    /// Die Zielmaske ist die **Vereinigung** der Migrationsergebnisse aller
    /// bemalten Altzellen. Proben in der Maske, deren ganzzahlig bestimmter
    /// Altbesitzer nicht bemalt ist, werden als Randzuwachs gezählt.
    ///
    /// - Parameters:
    ///   - paintedCells: Die bemalten Altzellen der Ebene.
    ///   - grid: Das alte metrische Raster.
    /// - Returns: Ein ``Result`` mit Maske, Randzuwachs und Verlusten.
    /// - Throws: ``LegacyLatticeMigration/MigrationError`` bei ungültigem Raster.
    public static func migrate(
        paintedCells: Set<PolarMetricGridCell>,
        in grid: MetricSquareGrid
    ) throws -> Result {

        guard !paintedCells.isEmpty else {
            return Result(
                cells: [],
                edgeGrowthProbeCount: 0,
                edgeGrowthCells: [],
                fullyLost: [:],
                radialPartialLossCentimeters: [:]
            )
        }

        // 1. Jede bemalte Zelle migrieren und die Vereinigung bilden.
        var union: Set<PolarDeviceLattice> = []
        var fullyLost: [PolarMetricGridCell: LegacyLatticeMigration.MigrationResult.LossReason] = [:]
        var radialPartialLoss: [PolarMetricGridCell: Int] = [:]

        for cell in paintedCells {
            let result = try LegacyLatticeMigration.migrate(cell, in: grid)
            union.formUnion(result.cells)
            if let reason = result.lossReason {
                fullyLost[cell] = reason
            }
            if result.radialPartialLossCentimeters > 0 {
                radialPartialLoss[cell] = result.radialPartialLossCentimeters
            }
        }

        // 2. Randzuwachs: Proben in der Maske mit fremdem Altbesitzer.
        // Dieselbe geprüfte Umrechnung wie die Einzelzellmigration. Eine
        // eigene `Int(grid.cellSizeMeters * 100)` wäre eine zweite,
        // ungeprüfte Wahrheit und läge bei krummen Rastern daneben.
        let cellSizeCm = try LegacyLatticeMigration.centimeterGrid(grid)
        var edgeGrowthProbeCount = 0
        var edgeGrowthCells: Set<PolarDeviceLattice> = []

        for latticeCell in union {
            let rawCm = latticeCell.ring * PolarDeviceLattice.ringQuantumCentimeters
            if isEdgeGrowthProbe(
                tick: latticeCell.sector,
                rawCm: rawCm,
                cellSizeCm: cellSizeCm,
                paintedCells: paintedCells
            ) {
                edgeGrowthProbeCount += 1
                edgeGrowthCells.insert(latticeCell)
            }
        }

        return Result(
            cells: union,
            edgeGrowthProbeCount: edgeGrowthProbeCount,
            edgeGrowthCells: edgeGrowthCells,
            fullyLost: fullyLost,
            radialPartialLossCentimeters: radialPartialLoss
        )
    }

    // MARK: - Private

    /// Prüft ganzzahlig, ob die Probe `(tick, rawCm)` einen Altbesitzer
    /// hat, der nicht in `paintedCells` liegt.
    private static func isEdgeGrowthProbe(
        tick: Int,
        rawCm: Int,
        cellSizeCm: Int,
        paintedCells: Set<PolarMetricGridCell>
    ) -> Bool {
        let ownerRing = rawCm / cellSizeCm
        let twoToK = LegacyLatticeMigration.angularDivisor(forRing: ownerRing)
        let ownerIdx = ((180 + tick) * twoToK) / 180
        let owner = PolarMetricGridCell(ring: ownerRing, angularIndex: ownerIdx)
        return !paintedCells.contains(owner)
    }
}
