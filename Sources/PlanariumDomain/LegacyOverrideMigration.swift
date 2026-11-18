import Foundation
import PLSDeviceValues

/// M-1b-b3/M-2b2b1: Überträgt Zellaktionen auf das polare Geräteraster.
/// Besitzer behalten ihre Herkunft und ursprüngliche Polaradresse; polar und
/// kartesisch werden gemeinsam, ohne Topologie-Vorrang, geprüft. Aktionen
/// werden mit geordneter Array-Gleichheit verglichen (OVR-DET-1), Besitzer
/// kanonisch als Polar vor Kartesisch sortiert. Die Berechnung ist ganzzahlig.
/// Ein Konflikt ist ein Befund, kein throw; nur ein ungültiges Raster wirft.
/// Jeder Besitzer ohne Zielzelle erscheint in `unplacedOwners` mit seinem
/// belegbaren `LossReason` und darf nie still verworfen werden.
public enum LegacyCellOrigin: Hashable, Sendable {
    case polar(PolarMetricGridCell)
    case cartesian(MetricGridCell)
}

public struct LegacyOverrideOwner: Equatable, Sendable {
    public let origin: LegacyCellOrigin
    public let polarAddress: PolarMetricGridCell
    public let actions: [SpatialCellAction]?

    public init(origin: LegacyCellOrigin, polarAddress: PolarMetricGridCell,
                actions: [SpatialCellAction]?) {
        self.origin = origin
        self.polarAddress = polarAddress
        self.actions = actions
    }
}

public struct LegacyUnplacedOwner: Equatable, Sendable {
    public let owner: LegacyOverrideOwner
    public let reason: LegacyLatticeMigration.MigrationResult.LossReason

    init(owner: LegacyOverrideOwner,
         reason: LegacyLatticeMigration.MigrationResult.LossReason) {
        self.owner = owner
        self.reason = reason
    }
}

/// Überträgt Zellaktionen mit vollständiger Herkunft auf das Geräteraster.
public enum LegacyOverrideMigration {
    /// Legacy-Projektion mit Polarbesitzern; der Initialisierer bleibt intern.
    /// `overrides` und `conflicts` schließen sich je Zielzelle aus.
    public struct Result: Equatable, Sendable {
        public let overrides: [PolarDeviceLattice: [SpatialCellAction]]
        public let conflicts: [PolarDeviceLattice: Set<PolarMetricGridCell>]
        public let cartesianCellsNotMigrated: Int

        fileprivate init(overrides: [PolarDeviceLattice: [SpatialCellAction]],
                        conflicts: [PolarDeviceLattice: Set<PolarMetricGridCell>],
                        cartesianCellsNotMigrated: Int) {
            self.overrides = overrides
            self.conflicts = conflicts
            self.cartesianCellsNotMigrated = cartesianCellsNotMigrated
        }
    }

    /// Herkunftserhaltendes Ergebnis. Pro Zielzelle steht der Wert entweder in
    /// `overrides` oder in `conflicts`, niemals in beiden; kein Besitzer wird
    /// dedupliziert oder durch einen Topologie-Vorrang ersetzt.
    public struct OwnedResult: Equatable, Sendable {
        public let ownership: [PolarDeviceLattice: [LegacyOverrideOwner]]
        public let overrides: [PolarDeviceLattice: [SpatialCellAction]]
        public let conflicts: [PolarDeviceLattice: [LegacyOverrideOwner]]
        public let unplacedOwners: [LegacyUnplacedOwner]

        fileprivate init(ownership: [PolarDeviceLattice: [LegacyOverrideOwner]],
                         overrides: [PolarDeviceLattice: [SpatialCellAction]],
                         conflicts: [PolarDeviceLattice: [LegacyOverrideOwner]],
                         unplacedOwners: [LegacyUnplacedOwner]) {
            self.ownership = ownership
            self.overrides = overrides
            self.conflicts = conflicts
            self.unplacedOwners = unplacedOwners
        }
    }

    /// Der alte Einstiegspunkt bleibt für die bisherigen Polar-Tests erhalten.
    public static func migrate(layer: LegacySpatialLayer,
                               in grid: MetricSquareGrid) throws -> Result {
        var owners: [LegacyOverrideOwner] = []
        for cell in layer.polarCells.sorted(by: polarPrecedes) {
            owners.append(LegacyOverrideOwner(
                origin: .polar(cell), polarAddress: cell,
                actions: layer.polarCellOverrides[cell]
            ))
        }
        let owned = try migrate(owners: owners, in: grid)
        var projected: [PolarDeviceLattice: Set<PolarMetricGridCell>] = [:]
        for (cell, conflicts) in owned.conflicts {
            projected[cell] = Set(conflicts.map(\.polarAddress))
        }
        return Result(overrides: owned.overrides, conflicts: projected,
                      cartesianCellsNotMigrated: layer.cells.count)
    }

    /// Migriert jede benannte Quelle einzeln; gleiche alte Adressen werden nur
    /// hinsichtlich ihrer Gerätezellen gecacht, nicht als Besitzer dedupliziert.
    /// Die Budgetbuchung ist vorab und daher eine obere Schranke: mehrere
    /// Besitzer mit derselben Zielmenge werden konservativ mehrfach gezählt.
    public static func migrate(owners: [LegacyOverrideOwner],
                               in grid: MetricSquareGrid) throws -> OwnedResult {
        var counter = SpatialDocumentBudgetCounter(.production)
        return try migrate(owners: owners, in: grid, budgetCounter: &counter)
    }

    static func migrate(owners: [LegacyOverrideOwner],
                        in grid: MetricSquareGrid,
                        budgetCounter: inout SpatialDocumentBudgetCounter) throws -> OwnedResult {
        var cache: [PolarMetricGridCell: Set<PolarDeviceLattice>] = [:]
        var cacheReasons: [PolarMetricGridCell: LegacyLatticeMigration.MigrationResult.LossReason?] = [:]
        var ownership: [PolarDeviceLattice: [LegacyOverrideOwner]] = [:]
        var unplacedOwners: [LegacyUnplacedOwner] = []
        for owner in owners {
            let cells: Set<PolarDeviceLattice>
            let reason: LegacyLatticeMigration.MigrationResult.LossReason?
            if let cached = cache[owner.polarAddress] {
                cells = cached
                reason = cacheReasons[owner.polarAddress] ?? nil
            } else {
                let migrated = try LegacyLatticeMigration.migrate(owner.polarAddress, in: grid)
                cells = migrated.cells
                cache[owner.polarAddress] = cells
                cacheReasons[owner.polarAddress] = migrated.lossReason
                reason = migrated.lossReason
            }
            if cells.isEmpty {
                guard let reason else {
                    preconditionFailure("Leere Migration ohne LossReason")
                }
                unplacedOwners.append(LegacyUnplacedOwner(owner: owner, reason: reason))
            }
            if let actions = owner.actions {
                let actionAssignments = try checkedProduct(cells.count, actions.count, kind: .actionAssignments)
                try budgetCounter.consume(.actionAssignments, count: actionAssignments)
                let noteEntries = try checkedProduct(cells.count, try checkedSpatialNoteCount(in: actions), kind: .noteEntries)
                try budgetCounter.consume(.noteEntries, count: noteEntries)
            }
            for cell in cells { ownership[cell, default: []].append(owner) }
        }

        var overrides: [PolarDeviceLattice: [SpatialCellAction]] = [:]
        var conflicts: [PolarDeviceLattice: [LegacyOverrideOwner]] = [:]
        for (cell, unsortedOwners) in ownership {
            let sortedOwners = unsortedOwners.sorted(by: ownerPrecedes)
            let actions = sortedOwners.map(\.actions)
            guard let reference = actions.compactMap({ $0 }).first else { continue }
            if actions.allSatisfy({ actionsAreIdentical($0, reference) }) {
                overrides[cell] = reference
            } else {
                conflicts[cell] = sortedOwners
            }
        }
        let orderedOwnership = ownership.mapValues { $0.sorted(by: ownerPrecedes) }
        return OwnedResult(ownership: orderedOwnership, overrides: overrides,
                           conflicts: conflicts, unplacedOwners: unplacedOwners)
    }

    private static func actionsAreIdentical(_ a: [SpatialCellAction]?, _ b: [SpatialCellAction]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a == b
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int,
                                       kind: SpatialDocumentBudget.Kind) throws -> Int {
        guard lhs >= 0, rhs >= 0, lhs == 0 || rhs <= Int.max / lhs else {
            throw SpatialDocumentError.budgetExceeded(kind)
        }
        return lhs * rhs
    }

    private static func polarPrecedes(_ lhs: PolarMetricGridCell, _ rhs: PolarMetricGridCell) -> Bool {
        lhs.ring == rhs.ring ? lhs.angularIndex < rhs.angularIndex : lhs.ring < rhs.ring
    }

    private static func metricPrecedes(_ lhs: MetricGridCell, _ rhs: MetricGridCell) -> Bool {
        lhs.column == rhs.column ? lhs.row < rhs.row : lhs.column < rhs.column
    }

    private static func ownerPrecedes(_ lhs: LegacyOverrideOwner, _ rhs: LegacyOverrideOwner) -> Bool {
        switch (lhs.origin, rhs.origin) {
        case (.polar(let a), .polar(let b)):
            return polarPrecedes(a, b)
        case (.cartesian(let a), .cartesian(let b)):
            return metricPrecedes(a, b)
        case (.polar, .cartesian): return true
        case (.cartesian, .polar): return false
        }
    }
}
