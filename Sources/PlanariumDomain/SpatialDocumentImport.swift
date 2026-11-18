import Foundation
import PLSDeviceValues

public struct SpatialDocumentImport: Equatable, Sendable {
    public let document: SpatialDocument?
    public let findings: [CompatibilityImportFinding]

    public init(document: SpatialDocument?, findings: [CompatibilityImportFinding]) {
        self.document = document
        self.findings = findings
    }
}

public struct SpatialOverrideConflict: Equatable, Sendable {
    public let layerIndex: Int
    public let layerID: UUID
    public let cell: PolarDeviceLattice
    public let owners: [LegacyOverrideOwner]

    public init(
        layerIndex: Int, layerID: UUID, cell: PolarDeviceLattice,
        owners: [LegacyOverrideOwner]
    ) {
        self.layerIndex = layerIndex
        self.layerID = layerID
        self.cell = cell
        self.owners = owners
    }
}

public struct SpatialUnplaceableOverride: Equatable, Sendable {
    public let layerIndex: Int
    public let layerID: UUID
    public let owner: LegacyOverrideOwner
    public let reason: LegacyLatticeMigration.MigrationResult.LossReason

    public init(layerIndex: Int, layerID: UUID, owner: LegacyOverrideOwner,
                reason: LegacyLatticeMigration.MigrationResult.LossReason) {
        self.layerIndex = layerIndex
        self.layerID = layerID
        self.owner = owner
        self.reason = reason
    }
}

public enum SpatialDocumentImportError: Error, Equatable, Sendable {
    case budgetExceeded(SpatialDocumentBudget.Kind)
    case unresolvedDormantOverrides([SpatialDormantOverrideCase])
    case unplaceableOverrides([SpatialUnplaceableOverride])
    case overrideConflicts([SpatialOverrideConflict])
    case invalidDocument(SpatialDocumentError)
}

public struct SpatialDormantOverrideCase: Equatable, Sendable {
    public let layerIndex: Int
    public let layerID: UUID
    public let issue: SpatialDormantOverrideIssue

    public init(layerIndex: Int, layerID: UUID, issue: SpatialDormantOverrideIssue) {
        self.layerIndex = layerIndex
        self.layerID = layerID
        self.issue = issue
    }
}

public enum SpatialDocumentImporter {
    public static func document(
        from source: CompatibilityImport
    ) -> Result<SpatialDocumentImport, SpatialDocumentImportError> {
        document(from: source, budget: .production)
    }

    internal static func document(
        from source: CompatibilityImport,
        budget: SpatialDocumentBudget
    ) -> Result<SpatialDocumentImport, SpatialDocumentImportError> {
        guard let legacyDocument = source.document else {
            return .success(SpatialDocumentImport(document: nil, findings: source.findings))
        }

        var dormantCases: [SpatialDormantOverrideCase] = []
        for (index, layer) in source.layers.enumerated() {
            dormantCases.append(contentsOf: layer.dormantIssues.map {
                SpatialDormantOverrideCase(layerIndex: index, layerID: layer.source.id, issue: $0)
            })
        }
        guard dormantCases.isEmpty else { return .failure(.unresolvedDormantOverrides(dormantCases)) }

        var unplaceable: [SpatialUnplaceableOverride] = []
        for (index, layer) in source.layers.enumerated() {
            unplaceable.append(contentsOf: layer.unplaceableOverrides.map {
                SpatialUnplaceableOverride(layerIndex: index, layerID: layer.source.id,
                                           owner: $0.owner, reason: $0.reason)
            })
        }
        guard unplaceable.isEmpty else { return .failure(.unplaceableOverrides(unplaceable)) }

        var conflicts: [SpatialOverrideConflict] = []
        for (layerIndex, layer) in source.layers.enumerated() {
            for (cell, owners) in layer.overrideConflicts {
                conflicts.append(SpatialOverrideConflict(
                    layerIndex: layerIndex,
                    layerID: layer.source.id,
                    cell: cell,
                    owners: owners
                ))
            }
        }
        conflicts.sort {
            if $0.layerIndex != $1.layerIndex { return $0.layerIndex < $1.layerIndex }
            if $0.cell.ring != $1.cell.ring { return $0.cell.ring < $1.cell.ring }
            return $0.cell.sector < $1.cell.sector
        }
        guard conflicts.isEmpty else { return .failure(.overrideConflicts(conflicts)) }

        guard source.layers.count <= budget.layers else {
            return .failure(.budgetExceeded(.layers))
        }

        var budgetCounter = SpatialDocumentBudgetCounter(budget)
        var layers: [SpatialDocumentLayer] = []
        layers.reserveCapacity(source.layers.count)
        for layer in source.layers {
            do {
                try budgetCounter.consume(.layers)
                budgetCounter.beginLayer()
            } catch let error as SpatialDocumentError {
                if case .budgetExceeded(let kind) = error {
                    return .failure(.budgetExceeded(kind))
                }
                return .failure(.invalidDocument(error))
            } catch {
                preconditionFailure("SpatialDocumentBudgetCounter raised an unknown error")
            }
            var cellOverrides = layer.overrides
            for (cell, actions) in layer.dormantOverrides {
                if cellOverrides[cell] == nil { cellOverrides[cell] = actions }
            }

            do {
                var addresses = Set(layer.cells)
                addresses.formUnion(cellOverrides.keys)
                for _ in addresses {
                    try budgetCounter.consumeLayerAddress()
                    try budgetCounter.consume(.addressesPerDocument)
                }
                for actions in cellOverrides.values {
                    try budgetCounter.consume(.actionAssignments, count: actions.count)
                    try budgetCounter.consume(.noteEntries, count: try checkedSpatialNoteCount(in: actions))
                }
                for routing in layer.source.routings {
                    try budgetCounter.consume(.routings)
                    try countRoutingNotes(routing.program, counter: &budgetCounter)
                }
            } catch let error as SpatialDocumentError {
                if case .budgetExceeded(let kind) = error {
                    return .failure(.budgetExceeded(kind))
                }
                return .failure(.invalidDocument(error))
            } catch {
                preconditionFailure("SpatialDocumentBudgetCounter raised an unknown error")
            }

            layers.append(SpatialDocumentLayer(
                id: layer.source.id,
                name: layer.source.name,
                color: layer.source.color,
                isVisible: layer.source.isVisible,
                isActive: layer.source.isActive,
                isLocked: layer.source.isLocked,
                isSoloed: layer.source.isSoloed,
                cells: layer.cells,
                routings: layer.source.routings,
                cellOverrides: cellOverrides,
                toggleGuardSeconds: layer.source.toggleGuardSeconds, commonNotes: layer.source.commonNotes, midiTarget: layer.source.midiTarget
            ))
        }
        let selected = layers.contains(where: { $0.id == legacyDocument.selectedLayerID })
            ? legacyDocument.selectedLayerID
            : layers.first?.id
        guard let selected else {
            return .failure(.invalidDocument(.emptyLayerStack))
        }
        do {
            let document = try SpatialDocument(
                latticeVersion: .polarDeviceV2,
                layers: layers,
                selectedLayerID: selected
            )
            return .success(SpatialDocumentImport(document: document, findings: source.findings))
        } catch let error as SpatialDocumentError {
            return .failure(.invalidDocument(error))
        } catch {
            preconditionFailure("SpatialDocument raised an unknown error")
        }
    }

}

private func countRoutingNotes(_ program: SpatialValueProgram,
                               counter: inout SpatialDocumentBudgetCounter) throws {
    if case .singleNote = program { try counter.consume(.noteEntries) }
    if case .chord(let notes, _, _) = program {
        try counter.consume(.noteEntries, count: notes.count)
    }
}
