import Foundation
import PLSDeviceValues

/// Benannte Ablehnungen an der additiven Legacy-Kompatibilitätsgrenze.
public enum CompatibilityImportError: Error, Equatable, Sendable {
    case budgetExceeded(SpatialDocumentBudget.Kind)
    case notAJSONObject
    case missingFormatVersion
    case malformedFormatVersion
    case unsupportedVersion(Int)
    case malformedSpatialWorkspace(LegacySpatialDocumentError)
    case nonIntegerCentimeterGrid(Double)
}

/// Ein diagnostisch vollständiger Befund der Kompatibilitätsgrenze.
public enum CompatibilityImportFinding: Equatable, Sendable {
    /// Die Quelle enthält keinen räumlichen Bestand. Das ist kein Verlust.
    case noSpatialInventory
    case document(LegacySpatialDocumentFinding)
    case cartesianAddress(
        layerIndex: Int,
        cell: MetricGridCell,
        rasterCentimeters: Int,
        error: LegacyCartesianAddress.AddressError
    )
    case fullyLost(
        layerIndex: Int,
        cell: PolarMetricGridCell,
        rasterCentimeters: Int,
        reason: LegacyLatticeMigration.MigrationResult.LossReason
    )
    case radialPartialLoss(
        layerIndex: Int,
        cell: PolarMetricGridCell,
        rasterCentimeters: Int,
        centimeters: Int
    )
    case edgeGrowth(
        layerIndex: Int,
        rasterCentimeters: Int,
        probeCount: Int,
        cells: [PolarDeviceLattice]
    )
    case dormantOverrides(layerIndex: Int, cells: [PolarMetricGridCell], cartesianCells: [MetricGridCell])
    case droppedOutsideOverride(layerIndex: Int, owner: LegacyOverrideOwner,
                                reason: LegacyLatticeMigration.MigrationResult.LossReason)
}

/// Ruhende Belegungen werden separat gehalten, bis sie ohne Verlust in das
/// neue Dokument übernommen werden können.
public enum SpatialDormantOverrideIssue: Equatable, Sendable {
    case wouldActivate(cell: PolarDeviceLattice, owners: [LegacyOverrideOwner])
    case conflict(cell: PolarDeviceLattice, owners: [LegacyOverrideOwner])
    case unplaceable(owner: LegacyOverrideOwner, reason: LegacyLatticeMigration.MigrationResult.LossReason)
    case unaddressable(cell: MetricGridCell)
}

/// Der vollständige Wert einer erfolgreichen Kompatibilitätslesung.
public struct CompatibilityImport: Equatable, Sendable {
    public struct Layer: Equatable, Sendable {
        public let source: LegacySpatialLayer
        public let sourcePolarCells: Set<PolarMetricGridCell>
        public let cells: Set<PolarDeviceLattice>
        public let edgeGrowthProbeCount: Int
        public let edgeGrowthCells: Set<PolarDeviceLattice>
        public let fullyLost: [PolarMetricGridCell: LegacyLatticeMigration.MigrationResult.LossReason]
        public let radialPartialLossCentimeters: [PolarMetricGridCell: Int]
        public let overrides: [PolarDeviceLattice: [SpatialCellAction]]
        public let overrideConflicts: [PolarDeviceLattice: [LegacyOverrideOwner]]
        public let unplaceableOverrides: [LegacyUnplacedOwner]
        public let dormantOverrides: [PolarDeviceLattice: [SpatialCellAction]]
        public let dormantIssues: [SpatialDormantOverrideIssue]

        fileprivate init(
            source: LegacySpatialLayer,
            sourcePolarCells: Set<PolarMetricGridCell>,
            result: LegacyMaskMigration.Result,
            overrides: [PolarDeviceLattice: [SpatialCellAction]] = [:],
            overrideConflicts: [PolarDeviceLattice: [LegacyOverrideOwner]] = [:],
            unplaceableOverrides: [LegacyUnplacedOwner] = [],
            dormantOverrides: [PolarDeviceLattice: [SpatialCellAction]] = [:],
            dormantIssues: [SpatialDormantOverrideIssue] = []
        ) {
            self.source = source
            self.sourcePolarCells = sourcePolarCells
            self.cells = result.cells
            self.edgeGrowthProbeCount = result.edgeGrowthProbeCount
            self.edgeGrowthCells = result.edgeGrowthCells
            self.fullyLost = result.fullyLost
            self.radialPartialLossCentimeters = result.radialPartialLossCentimeters
            self.overrides = overrides
            self.overrideConflicts = overrideConflicts
            self.unplaceableOverrides = unplaceableOverrides
            self.dormantOverrides = dormantOverrides
            self.dormantIssues = dormantIssues
        }
    }

    /// Nil bedeutet: v3 hatte kein `spatialWorkspace`-Feld.
    public let document: LegacySpatialDocument?
    public let layers: [Layer]
    public let findings: [CompatibilityImportFinding]

    fileprivate init(
        document: LegacySpatialDocument?,
        layers: [Layer],
        findings: [CompatibilityImportFinding]
    ) {
        self.document = document
        self.layers = layers
        self.findings = findings
    }
}

/// Reine Verbindung von Legacy-Leser, Adressierung und Maskenmigration.
public enum CompatibilityImporter {

    public static func read(
        _ data: Data,
        context: String? = nil
    ) -> Result<CompatibilityImport, CompatibilityImportError> {
        read(data, context: context, budget: .production)
    }

    internal static func read(
        _ data: Data,
        context: String?,
        budget: SpatialDocumentBudget
    ) -> Result<CompatibilityImport, CompatibilityImportError> {
        _ = context

        guard data.count <= budget.inputBytes else {
            return .failure(.budgetExceeded(.inputBytes))
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.notAJSONObject)
        }
        guard let root = object as? [String: Any] else {
            return .failure(.notAJSONObject)
        }
        guard root.keys.contains("formatVersion") else {
            return .failure(.missingFormatVersion)
        }
        guard let version = root["formatVersion"] as? Int else {
            return .failure(.malformedFormatVersion)
        }
        guard version == 3 else {
            return .failure(.unsupportedVersion(version))
        }

        // Ein fehlendes Workspace-Feld ist ein gültiger, räumlich leerer
        // v3-Zustand. Ein vorhandenes Feld muss dagegen decodierbar sein.
        guard let workspace = root["spatialWorkspace"] else {
            return .success(CompatibilityImport(
                document: nil,
                layers: [],
                findings: [.noSpatialInventory]
            ))
        }
        guard JSONSerialization.isValidJSONObject(workspace),
              let workspaceData = try? JSONSerialization.data(withJSONObject: workspace)
        else {
            return .failure(.malformedSpatialWorkspace(.malformedDocument(
                reason: "spatialWorkspace is not a JSON object"
            )))
        }

        // Die JSON-Form wird vor dem typisierten Legacy-Leser gezählt. Damit
        // ein vergiftetes Routing hinter der Grenze keinen Decoding-Fehler
        // vor dem eigentlichen Budgetfehler erzeugt, wird weder Routing noch
        // sein Akkordnotenfeld vorher materialisiert.
        if let exceeded = legacyRoutingBudgetExceeded(in: workspace, budget: budget) {
            return .failure(.budgetExceeded(exceeded))
        }

        let reading: LegacySpatialDocumentReading
        do {
            reading = try LegacySpatialDocumentReader.read(from: workspaceData)
        } catch LegacySpatialDocumentError.nonIntegerCentimeterGrid(let size) {
            return .failure(.nonIntegerCentimeterGrid(size))
        } catch let error as LegacySpatialDocumentError {
            return .failure(.malformedSpatialWorkspace(error))
        } catch {
            return .failure(.malformedSpatialWorkspace(.malformedDocument(
                reason: "spatialWorkspace is unreadable"
            )))
        }

        guard let rasterCentimeters = try? LegacyLatticeMigration.centimeterGrid(
            try MetricSquareGrid.build(cellSizeMeters: reading.document.cellSizeMeters)
        ) else {
            return .failure(.malformedSpatialWorkspace(.malformedDocument(
                reason: "Could not build the grid"
            )))
        }

        var findings = reading.findings.map(CompatibilityImportFinding.document)
        var droppedOutsideFindings: [CompatibilityImportFinding] = []
        var importedLayers: [CompatibilityImport.Layer] = []
        var hasSpatialInventory = false
        var budgetCounter = SpatialDocumentBudgetCounter(budget)

        guard reading.document.layers.count <= budget.layers else {
            return .failure(.budgetExceeded(.layers))
        }

        for (layerIndex, layer) in reading.document.layers.enumerated() {
            budgetCounter.beginLayer()
            let hasSourceCells = !layer.cells.isEmpty || !layer.polarCells.isEmpty
            hasSpatialInventory = hasSpatialInventory || hasSourceCells

            let dormantPolar = layer.polarCellOverrides.keys
                .filter { !layer.polarCells.contains($0) }
                .sorted(by: Self.polarCellPrecedes)
            let dormantCartesian = layer.cellOverrides.keys
                .filter { !layer.cells.contains($0) }
                .sorted(by: Self.metricCellPrecedes)
            if !dormantPolar.isEmpty || !dormantCartesian.isEmpty {
                findings.append(.dormantOverrides(
                    layerIndex: layerIndex, cells: dormantPolar,
                    cartesianCells: dormantCartesian
                ))
            }

            var sourcePolarCells = layer.polarCells
            var cartesianAddresses: [MetricGridCell: PolarMetricGridCell] = [:]
            for cell in layer.cells.sorted(by: Self.metricCellPrecedes) {
                do {
                    let address = try LegacyCartesianAddress.polarCell(
                        atCenterOf: cell,
                        in: try MetricSquareGrid.build(cellSizeMeters: reading.document.cellSizeMeters)
                    )
                    cartesianAddresses[cell] = address
                    sourcePolarCells.insert(address)
                } catch let error as LegacyCartesianAddress.AddressError {
                    findings.append(.cartesianAddress(
                        layerIndex: layerIndex,
                        cell: cell,
                        rasterCentimeters: rasterCentimeters,
                        error: error
                    ))
                } catch {
                    findings.append(.cartesianAddress(
                        layerIndex: layerIndex,
                        cell: cell,
                        rasterCentimeters: rasterCentimeters,
                        error: .outsideValueRange(column: cell.column, row: cell.row)
                    ))
                }
            }

            let grid: MetricSquareGrid
            do {
                grid = try MetricSquareGrid.build(cellSizeMeters: reading.document.cellSizeMeters)
            } catch {
                return .failure(.malformedSpatialWorkspace(.malformedDocument(
                    reason: "Could not build the grid"
                )))
            }

            do {
                for cell in sourcePolarCells {
                    let estimate = try LegacyLatticeMigration.estimatedTargetCount(cell, in: grid)
                    try budgetCounter.consumeLayerAddress(count: estimate)
                    try budgetCounter.consume(.addressesPerDocument, count: estimate)
                }
            } catch let error as SpatialDocumentError {
                if case .budgetExceeded(let kind) = error {
                    return .failure(.budgetExceeded(kind))
                }
                return .failure(.malformedSpatialWorkspace(.malformedDocument(
                    reason: "Legacy address budget could not be verified before migration"
                )))
            } catch {
                preconditionFailure("Legacy address budget raised an unknown error")
            }

            let result: LegacyMaskMigration.Result
            do {
                result = try LegacyMaskMigration.migrate(paintedCells: sourcePolarCells, in: grid)
            } catch let error as LegacyLatticeMigration.MigrationError {
                if case .nonIntegerCentimeterGrid(let size) = error {
                    return .failure(.nonIntegerCentimeterGrid(size))
                }
                return .failure(.malformedSpatialWorkspace(.malformedDocument(
                    reason: "Grid migration failed"
                )))
            } catch {
                return .failure(.malformedSpatialWorkspace(.malformedDocument(
                    reason: "Grid migration failed"
                )))
            }

            var owners: [LegacyOverrideOwner] = layer.polarCells
                .sorted(by: Self.polarCellPrecedes)
                .map { cell in
                    LegacyOverrideOwner(origin: .polar(cell), polarAddress: cell,
                                        actions: layer.polarCellOverrides[cell])
                }
            owners.append(contentsOf: layer.cells
                .sorted(by: Self.metricCellPrecedes)
                .compactMap { cell in
                    guard let address = cartesianAddresses[cell] else { return nil }
                    return LegacyOverrideOwner(
                        origin: .cartesian(cell), polarAddress: address,
                        actions: layer.cellOverrides[cell]
                    )
                })
            let overrideResult: LegacyOverrideMigration.OwnedResult
            do {
                overrideResult = try LegacyOverrideMigration.migrate(
                    owners: owners, in: grid, budgetCounter: &budgetCounter
                )
            } catch {
                if let error = error as? SpatialDocumentError,
                   case .budgetExceeded(let kind) = error {
                    return .failure(.budgetExceeded(kind))
                }
                return .failure(.malformedSpatialWorkspace(.malformedDocument(
                    reason: "Cell action migration failed"
                )))
            }

            var unplaceableOverrides: [LegacyUnplacedOwner] = []
            for unplaced in overrideResult.unplacedOwners {
                switch unplaced.reason {
                case .fullyOutsideScannerField:
                    if unplaced.owner.actions != nil {
                        droppedOutsideFindings.append(.droppedOutsideOverride(
                            layerIndex: layerIndex, owner: unplaced.owner, reason: unplaced.reason
                        ))
                    }
                case .noValidDeviceProbe:
                    if unplaced.owner.actions != nil { unplaceableOverrides.append(unplaced) }
                }
            }

            var dormantOwners: [LegacyOverrideOwner] = []
            var dormantIssues: [SpatialDormantOverrideIssue] = []
            var dormantOverrides: [PolarDeviceLattice: [SpatialCellAction]] = [:]
            for cell in dormantPolar {
                dormantOwners.append(LegacyOverrideOwner(
                    origin: .polar(cell), polarAddress: cell,
                    actions: layer.polarCellOverrides[cell]
                ))
            }
            for cell in dormantCartesian {
                do {
                    let address = try LegacyCartesianAddress.polarCell(
                        atCenterOf: cell,
                        in: grid
                    )
                    dormantOwners.append(LegacyOverrideOwner(
                        origin: .cartesian(cell), polarAddress: address,
                        actions: layer.cellOverrides[cell]
                    ))
                } catch {
                    dormantIssues.append(.unaddressable(cell: cell))
                }
            }
            do {
                for cell in Set(dormantOwners.map(\.polarAddress)) {
                    let estimate = try LegacyLatticeMigration.estimatedTargetCount(cell, in: grid)
                    try budgetCounter.consumeLayerAddress(count: estimate)
                    try budgetCounter.consume(.addressesPerDocument, count: estimate)
                }
            } catch let error as SpatialDocumentError {
                if case .budgetExceeded(let kind) = error {
                    return .failure(.budgetExceeded(kind))
                }
                return .failure(.malformedSpatialWorkspace(.malformedDocument(
                    reason: "Legacy address budget for dormant cells could not be verified"
                )))
            } catch {
                preconditionFailure("Legacy address budget for dormant cells raised an unknown error")
            }
            let dormantResult: LegacyOverrideMigration.OwnedResult
            do {
                dormantResult = try LegacyOverrideMigration.migrate(
                    owners: dormantOwners, in: grid, budgetCounter: &budgetCounter
                )
            } catch {
                if let error = error as? SpatialDocumentError,
                   case .budgetExceeded(let kind) = error {
                    return .failure(.budgetExceeded(kind))
                }
                return .failure(.malformedSpatialWorkspace(.malformedDocument(
                    reason: "Dormant cell action migration failed"
                )))
            }
            for (cell, owners) in dormantResult.ownership {
                if result.cells.contains(cell) {
                    dormantIssues.append(.wouldActivate(cell: cell, owners: owners))
                } else if let conflicts = dormantResult.conflicts[cell] {
                    dormantIssues.append(.conflict(cell: cell, owners: conflicts))
                } else if let actions = dormantResult.overrides[cell] {
                    dormantOverrides[cell] = actions
                }
            }
            for unplaced in dormantResult.unplacedOwners {
                switch unplaced.reason {
                case .fullyOutsideScannerField:
                    if unplaced.owner.actions != nil {
                        droppedOutsideFindings.append(.droppedOutsideOverride(
                            layerIndex: layerIndex, owner: unplaced.owner, reason: unplaced.reason
                        ))
                    }
                case .noValidDeviceProbe:
                    dormantIssues.append(.unplaceable(owner: unplaced.owner, reason: unplaced.reason))
                }
            }
            dormantIssues.sort(by: Self.dormantIssuePrecedes)

            var addresses = Set(result.cells)
            addresses.formUnion(overrideResult.overrides.keys)
            addresses.formUnion(dormantOverrides.keys)
            guard addresses.count <= budget.addressesPerLayer else {
                return .failure(.budgetExceeded(.addressesPerLayer))
            }

            for cell in sourcePolarCells.sorted(by: Self.polarCellPrecedes) {
                if let reason = result.fullyLost[cell] {
                    findings.append(.fullyLost(
                        layerIndex: layerIndex,
                        cell: cell,
                        rasterCentimeters: rasterCentimeters,
                        reason: reason
                    ))
                }
                if let centimeters = result.radialPartialLossCentimeters[cell] {
                    findings.append(.radialPartialLoss(
                        layerIndex: layerIndex,
                        cell: cell,
                        rasterCentimeters: rasterCentimeters,
                        centimeters: centimeters
                    ))
                }
            }
            if result.edgeGrowthProbeCount > 0 {
                findings.append(.edgeGrowth(
                    layerIndex: layerIndex,
                    rasterCentimeters: rasterCentimeters,
                    probeCount: result.edgeGrowthProbeCount,
                    cells: result.edgeGrowthCells.sorted(by: Self.latticeCellPrecedes)
                ))
            }
            importedLayers.append(CompatibilityImport.Layer(
                source: layer,
                sourcePolarCells: sourcePolarCells,
                result: result,
                overrides: overrideResult.overrides,
                overrideConflicts: overrideResult.conflicts,
                unplaceableOverrides: unplaceableOverrides.sorted(by: Self.unplacedOwnerPrecedes),
                dormantOverrides: dormantOverrides,
                dormantIssues: dormantIssues
            ))
        }

        if !hasSpatialInventory {
            findings.append(.noSpatialInventory)
        }
        droppedOutsideFindings.sort(by: Self.droppedFindingPrecedes)
        findings.append(contentsOf: droppedOutsideFindings)
        return .success(CompatibilityImport(
            document: reading.document,
            layers: importedLayers,
            findings: findings
        ))
    }

    private static func metricCellPrecedes(_ lhs: MetricGridCell, _ rhs: MetricGridCell) -> Bool {
        lhs.column == rhs.column ? lhs.row < rhs.row : lhs.column < rhs.column
    }

    private static func polarCellPrecedes(_ lhs: PolarMetricGridCell, _ rhs: PolarMetricGridCell) -> Bool {
        lhs.ring == rhs.ring ? lhs.angularIndex < rhs.angularIndex : lhs.ring < rhs.ring
    }

    private static func latticeCellPrecedes(_ lhs: PolarDeviceLattice, _ rhs: PolarDeviceLattice) -> Bool {
        lhs.ring == rhs.ring ? lhs.sector < rhs.sector : lhs.ring < rhs.ring
    }

    private static func dormantIssuePrecedes(_ lhs: SpatialDormantOverrideIssue,
                                             _ rhs: SpatialDormantOverrideIssue) -> Bool {
        func key(_ issue: SpatialDormantOverrideIssue) -> (Int, Int, Int) {
            switch issue {
            case .wouldActivate(let cell, _): return (0, cell.ring, cell.sector)
            case .conflict(let cell, _): return (0, cell.ring, cell.sector)
            case .unplaceable: return (1, 0, 0)
            case .unaddressable(let cell): return (2, cell.column, cell.row)
            }
        }
        let left = key(lhs)
        let right = key(rhs)
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        return left.2 < right.2
    }

    private static func unplacedOwnerPrecedes(_ lhs: LegacyUnplacedOwner,
                                              _ rhs: LegacyUnplacedOwner) -> Bool {
        let left = lhs.owner
        let right = rhs.owner
        switch (left.origin, right.origin) {
        case (.polar(let a), .polar(let b)):
            return a.ring == b.ring ? a.angularIndex < b.angularIndex : a.ring < b.ring
        case (.cartesian(let a), .cartesian(let b)):
            return a.column == b.column ? a.row < b.row : a.column < b.column
        case (.polar, .cartesian): return true
        case (.cartesian, .polar): return false
        }
    }

    private static func droppedFindingPrecedes(_ lhs: CompatibilityImportFinding,
                                               _ rhs: CompatibilityImportFinding) -> Bool {
        guard case .droppedOutsideOverride(let li, let lo, _) = lhs,
              case .droppedOutsideOverride(let ri, let ro, _) = rhs else { return false }
        if li != ri { return li < ri }
        return unplacedOwnerPrecedes(
            LegacyUnplacedOwner(owner: lo, reason: .fullyOutsideScannerField),
            LegacyUnplacedOwner(owner: ro, reason: .fullyOutsideScannerField)
        )
    }
}

private func legacyRoutingBudgetExceeded(in workspace: Any,
                                         budget: SpatialDocumentBudget) -> SpatialDocumentBudget.Kind? {
    guard let object = workspace as? [String: Any],
          let layers = object["layers"] as? [Any] else { return nil }
    var routings = 0
    var notes = 0
    for layer in layers {
        guard let layer = layer as? [String: Any],
              let entries = layer["routings"] as? [Any] else { continue }
        for entry in entries {
            guard routings < budget.routings else { return .routings }
            routings += 1
            guard let routing = entry as? [String: Any],
                  let program = routing["program"] as? [String: Any],
                  let chord = program["chord"] as? [String: Any],
                  let chordNotes = chord["notes"] as? [Any] else { continue }
            guard chordNotes.count <= budget.noteEntries - notes else { return .noteEntries }
            notes += chordNotes.count
        }
    }
    return nil
}
