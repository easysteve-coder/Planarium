import Foundation
import PLSDeviceValues

private struct SpatialValueCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct SpatialNoteCodingKeys: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension SpatialValueProgram {
    init(from decoder: Decoder, counter: inout SpatialDocumentBudgetCounter) throws {
        let values = try decoder.container(keyedBy: SpatialValueCodingKey.self)
        guard let key = values.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                     debugDescription: "SpatialValueProgram fehlt"))
        }
        switch key.stringValue {
        case "programChange":
            let nested = try values.nestedContainer(keyedBy: SpatialValueCodingKey.self, forKey: key)
            self = .programChange(try nested.decode(SpatialProgramChange.self, forKey: SpatialValueCodingKey(stringValue: "_0")!))
        case "constant":
            let nested = try values.nestedContainer(keyedBy: SpatialValueCodingKey.self, forKey: key)
            self = .constant(try nested.decode(Double.self, forKey: SpatialValueCodingKey(stringValue: "_0")!))
        case "continuous":
            let nested = try values.nestedContainer(keyedBy: SpatialValueCodingKey.self, forKey: key)
            self = .continuous(
                minimum: try nested.decode(Double.self, forKey: SpatialValueCodingKey(stringValue: "minimum")!),
                maximum: try nested.decode(Double.self, forKey: SpatialValueCodingKey(stringValue: "maximum")!),
                directionDegrees: try nested.decode(Double.self, forKey: SpatialValueCodingKey(stringValue: "directionDegrees")!),
                curve: try nested.decode(SpatialValueCurve.self, forKey: SpatialValueCodingKey(stringValue: "curve")!)
            )
        case "scale":
            let nested = try values.nestedContainer(keyedBy: SpatialValueCodingKey.self, forKey: key)
            self = .scale(
                rootMIDINote: try nested.decode(Int.self, forKey: SpatialValueCodingKey(stringValue: "rootMIDINote")!),
                lowestMIDINote: try nested.decode(Int.self, forKey: SpatialValueCodingKey(stringValue: "lowestMIDINote")!),
                highestMIDINote: try nested.decode(Int.self, forKey: SpatialValueCodingKey(stringValue: "highestMIDINote")!),
                scale: try nested.decode(SpatialScale.self, forKey: SpatialValueCodingKey(stringValue: "scale")!),
                directionDegrees: try nested.decode(Double.self, forKey: SpatialValueCodingKey(stringValue: "directionDegrees")!),
                ascending: try nested.decode(Bool.self, forKey: SpatialValueCodingKey(stringValue: "ascending")!),
                transition: try nested.decode(SpatialNoteTransition.self, forKey: SpatialValueCodingKey(stringValue: "transition")!)
            )
        case "randomScale":
            let nested = try values.nestedContainer(keyedBy: SpatialValueCodingKey.self, forKey: key)
            self = .randomScale(
                rootMIDINote: try nested.decode(Int.self, forKey: SpatialValueCodingKey(stringValue: "rootMIDINote")!),
                lowestMIDINote: try nested.decode(Int.self, forKey: SpatialValueCodingKey(stringValue: "lowestMIDINote")!),
                highestMIDINote: try nested.decode(Int.self, forKey: SpatialValueCodingKey(stringValue: "highestMIDINote")!),
                scale: try nested.decode(SpatialScale.self, forKey: SpatialValueCodingKey(stringValue: "scale")!),
                seed: try nested.decode(UInt64.self, forKey: SpatialValueCodingKey(stringValue: "seed")!),
                transition: try nested.decode(SpatialNoteTransition.self, forKey: SpatialValueCodingKey(stringValue: "transition")!)
            )
        case "singleNote":
            try counter.consume(.noteEntries)
            let nested = try values.nestedContainer(keyedBy: SpatialValueCodingKey.self, forKey: key)
            self = .singleNote(
                note: try nested.decode(Int.self, forKey: SpatialValueCodingKey(stringValue: "note")!),
                velocity: try nested.decode(UInt8.self, forKey: SpatialValueCodingKey(stringValue: "velocity")!),
                transition: try nested.decode(SpatialNoteTransition.self, forKey: SpatialValueCodingKey(stringValue: "transition")!)
            )
        case "chord":
            let nested = try values.nestedContainer(keyedBy: SpatialValueCodingKey.self, forKey: key)
            var notesContainer = try nested.nestedUnkeyedContainer(forKey: SpatialValueCodingKey(stringValue: "notes")!)
            var notes: [Int] = []
            while !notesContainer.isAtEnd {
                try counter.consume(.noteEntries)
                notes.append(try notesContainer.decode(Int.self))
            }
            self = .chord(
                notes: notes,
                velocity: try nested.decode(UInt8.self, forKey: SpatialValueCodingKey(stringValue: "velocity")!),
                transition: try nested.decode(SpatialNoteTransition.self, forKey: SpatialValueCodingKey(stringValue: "transition")!)
            )
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                     debugDescription: "Unknown SpatialValueProgram case"))
        }
    }
}

extension SpatialRouting {
    init(from decoder: Decoder, counter: inout SpatialDocumentBudgetCounter) throws {
        let values = try decoder.container(keyedBy: SpatialValueCodingKey.self)
        // Cross-module extension (the type lives in PlanariumMusicCore): delegate to its init.
        let id = try values.decode(UUID.self, forKey: SpatialValueCodingKey(stringValue: "id")!)
        let target = try values.decode(SpatialRoutingTarget.self, forKey: SpatialValueCodingKey(stringValue: "target")!)
        let chordRootMIDINote = try values.decodeIfPresent(Int.self, forKey: SpatialValueCodingKey(stringValue: "chordRootMIDINote")!)
        let program = try SpatialValueProgram(from: values.superDecoder(forKey: SpatialValueCodingKey(stringValue: "program")!), counter: &counter)
        self.init(id: id, target: target, program: program, chordRootMIDINote: chordRootMIDINote)
    }
}

private extension SpatialCellValue {
    init(from decoder: Decoder, counter: inout SpatialDocumentBudgetCounter) throws {
        let values = try decoder.container(keyedBy: SpatialValueCodingKey.self)
        guard let key = values.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "SpatialCellValue fehlt"))
        }
        switch key.stringValue {
        case "programChange":
            let nested = try values.nestedContainer(keyedBy: SpatialValueCodingKey.self, forKey: key)
            self = .programChange(try nested.decode(SpatialProgramChange.self, forKey: SpatialValueCodingKey(stringValue: "_0")!))
        case "scalar":
            // Current synthesized enum encoding nests the unlabeled value;
            // retain the earlier direct-value spelling as an import format.
            if let value = try? values.decode(Double.self, forKey: key) { self = .scalar(value) }
            else {
                let nested = try values.nestedContainer(keyedBy: SpatialValueCodingKey.self, forKey: key)
                self = .scalar(try nested.decode(Double.self, forKey: SpatialValueCodingKey(stringValue: "_0")!))
            }
        case "boolean":
            if let value = try? values.decode(Bool.self, forKey: key) { self = .boolean(value) }
            else {
                let nested = try values.nestedContainer(keyedBy: SpatialValueCodingKey.self, forKey: key)
                self = .boolean(try nested.decode(Bool.self, forKey: SpatialValueCodingKey(stringValue: "_0")!))
            }
        case "sceneSwitch":
            let action = try values.nestedContainer(keyedBy: SpatialNoteCodingKeys.self, forKey: key)
            self = .sceneSwitch(action: try action.decode(SpatialSceneSwitchAction.self, forKey: SpatialNoteCodingKeys(stringValue: "action")!))
        case "releaseLayer":
            let action = try values.nestedContainer(keyedBy: SpatialNoteCodingKeys.self, forKey: key)
            self = .releaseLayer(layerID: try action.decode(UUID.self, forKey: SpatialNoteCodingKeys(stringValue: "layerID")!))
        case "note":
            try counter.consume(.noteEntries)
            let note = try values.nestedContainer(keyedBy: SpatialNoteCodingKeys.self, forKey: key)
            self = .note(number: try note.decode(Int.self, forKey: SpatialNoteCodingKeys(stringValue: "number")!),
                         velocity: try note.decode(UInt8.self, forKey: SpatialNoteCodingKeys(stringValue: "velocity")!))
        case "chord":
            let chord = try values.nestedContainer(keyedBy: SpatialNoteCodingKeys.self, forKey: key)
            var notesContainer = try chord.nestedUnkeyedContainer(forKey: SpatialNoteCodingKeys(stringValue: "notes")!)
            var notes: [Int] = []
            while !notesContainer.isAtEnd {
                try counter.consume(.noteEntries)
                notes.append(try notesContainer.decode(Int.self))
            }
            self = .chord(notes: notes,
                           velocity: try chord.decode(UInt8.self, forKey: SpatialNoteCodingKeys(stringValue: "velocity")!))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown SpatialCellValue case"))
        }
    }
}

extension SpatialCellAction {
    init(from decoder: Decoder, counter: inout SpatialDocumentBudgetCounter) throws {
        let values = try decoder.container(keyedBy: ActionCodingKeys.self)
        let target = try values.decode(SpatialRoutingTarget.self, forKey: .target)
        self.init(target: target, value: try SpatialCellValue(from: values.superDecoder(forKey: .value), counter: &counter))
    }

    private enum ActionCodingKeys: String, CodingKey { case target, value }
}

public struct SpatialDocumentBudget: Equatable, Sendable {
    public let inputBytes: Int
    public let layers: Int
    public let addressesPerLayer: Int
    public let addressesPerDocument: Int
    public let actionAssignments: Int
    public let noteEntries: Int
    public let routings: Int
    /// Surfaces of one layer. Each surface is its own compiled carrier.
    public let surfacesPerLayer: Int
    /// Compiled carriers of the whole document (layers without surfaces count one each).
    public let partitions: Int

    public init(inputBytes: Int, layers: Int, addressesPerLayer: Int,
                addressesPerDocument: Int, actionAssignments: Int, noteEntries: Int,
                routings: Int = 4_096, surfacesPerLayer: Int = 64, partitions: Int = 1_024) {
        self.inputBytes = inputBytes
        self.layers = layers
        self.addressesPerLayer = addressesPerLayer
        self.addressesPerDocument = addressesPerDocument
        self.actionAssignments = actionAssignments
        self.noteEntries = noteEntries
        self.routings = routings
        self.surfacesPerLayer = surfacesPerLayer
        self.partitions = partitions
    }

    public static let production = SpatialDocumentBudget(
        inputBytes: 67_108_864, layers: 256,
        addressesPerLayer: 262_144, addressesPerDocument: 1_048_576,
        actionAssignments: 1_048_576, noteEntries: 1_048_576, routings: 4_096,
        surfacesPerLayer: 64, partitions: 1_024
    )

    public enum Kind: Equatable, Sendable {
        case inputBytes, layers, addressesPerLayer, addressesPerDocument
        case actionAssignments, noteEntries, routings
        case surfacesPerLayer, partitions
    }
}

internal struct SpatialDocumentBudgetCounter {
    let budget: SpatialDocumentBudget
    private var used: [SpatialDocumentBudget.Kind: Int] = [:]
    private var layerAddresses = 0

    init(_ budget: SpatialDocumentBudget) { self.budget = budget }

    mutating func beginLayer() { layerAddresses = 0 }

    /// The surface limit is per layer: each layer's list of surfaces starts a fresh count, while
    /// partitions, cells, routings and assignments keep counting across the document.
    mutating func beginSurfaceList() { used[.surfacesPerLayer] = 0 }

    mutating func consumeLayerAddress() throws {
        try consumeLayerAddress(count: 1)
    }

    mutating func consumeLayerAddress(count: Int) throws {
        guard count >= 0,
              layerAddresses <= budget.addressesPerLayer,
              count <= budget.addressesPerLayer - layerAddresses else {
            throw SpatialDocumentError.budgetExceeded(.addressesPerLayer)
        }
        layerAddresses += count
    }

    mutating func consume(_ kind: SpatialDocumentBudget.Kind) throws {
        try consume(kind, count: 1)
    }

    mutating func consume(_ kind: SpatialDocumentBudget.Kind, count: Int) throws {
        let limit: Int
        switch kind {
        case .inputBytes: limit = budget.inputBytes
        case .layers: limit = budget.layers
        case .addressesPerLayer: limit = budget.addressesPerLayer
        case .addressesPerDocument: limit = budget.addressesPerDocument
        case .actionAssignments: limit = budget.actionAssignments
        case .noteEntries: limit = budget.noteEntries
        case .routings: limit = budget.routings
        case .surfacesPerLayer: limit = budget.surfacesPerLayer
        case .partitions: limit = budget.partitions
        }
        let current = used[kind, default: 0]
        guard count >= 0, current <= limit, count <= limit - current else {
            throw SpatialDocumentError.budgetExceeded(kind)
        }
        used[kind] = current + count
    }
}

internal func checkedSpatialNoteCount(in actions: [SpatialCellAction]) throws -> Int {
    var count = 0
    for action in actions {
        let addition: Int
        switch action.value {
        case .note: addition = 1
        case .chord(let notes, _): addition = notes.count
        case .scalar, .boolean, .sceneSwitch, .releaseLayer, .programChange: continue
        }
        let next = count.addingReportingOverflow(addition)
        guard !next.overflow else {
            throw SpatialDocumentError.budgetExceeded(.noteEntries)
        }
        count = next.partialValue
    }
    return count
}

extension CodingUserInfoKey {
    internal static let spatialDocumentBudget = CodingUserInfoKey(rawValue: "SickPLSMonitorKit.spatialDocumentBudget")!
    /// Set (to `true`) only by the format that can carry editable surfaces. Without it a document
    /// holding surface data refuses to encode, and a `surfaces` key refuses to decode.
    public static let spatialSurfacesAllowed = CodingUserInfoKey(rawValue: "PlanariumDomain.spatialSurfacesAllowed")!
}

private func countNotes(in value: SpatialCellValue, counter: inout SpatialDocumentBudgetCounter) throws {
    switch value {
    case .note: try counter.consume(.noteEntries)
    case .chord(let notes, _):
        for _ in notes { try counter.consume(.noteEntries) }
    case .scalar, .boolean, .sceneSwitch, .releaseLayer, .programChange: break
    }
}

private func countNotes(in program: SpatialValueProgram, counter: inout SpatialDocumentBudgetCounter) throws {
    if case .singleNote = program { try counter.consume(.noteEntries) }
    if case .chord(let notes, _, _) = program {
        try counter.consume(.noteEntries, count: notes.count)
    }
}

public enum SpatialLatticeVersion: String, Codable, Equatable, Sendable {
    case polarDeviceV1
    case polarDeviceV2

    public var tickCount: Int { PolarDeviceLattice.maxTick + 1 }
    public var ringQuantumCentimeters: Int { PolarDeviceLattice.ringQuantumCentimeters }
    public var tickDegrees: Double { 0.5 }
}

public struct SpatialDocumentLayer: Codable, Equatable, Sendable {
    private struct Presentation: Equatable, Sendable {
        var name: String
        var color: SpatialLayerColor
        var isVisible: Bool
        var isLocked: Bool
    }
    private var presentation: Presentation
    public let midiTarget: InstrumentMIDITarget?
    public let id: UUID
    public var name: String { presentation.name }
    public var color: SpatialLayerColor { presentation.color }
    public var isVisible: Bool { presentation.isVisible }
    public private(set) var isActive: Bool
    public var isLocked: Bool { presentation.isLocked }
    public let isSoloed: Bool
    public let commonNotes: SpatialCommonNotes
    public let toggleGuardSeconds: Double
    /// Cells, routings and overrides of a layer without surfaces. A layer with surfaces keeps all
    /// three empty (a layer field never lies): its content is in `surfaces` / `partitions`.
    public private(set) var cells: Set<PolarDeviceLattice>
    public let routings: [SpatialRouting]
    public private(set) var cellOverrides: [PolarDeviceLattice: [SpatialCellAction]]
    /// Editable areas. Empty: the layer is the classic mask above.
    public let surfaces: [SpatialSurface]

    public init(
        id: UUID, name: String, color: SpatialLayerColor,
        isVisible: Bool, isActive: Bool, isLocked: Bool, isSoloed: Bool,
        cells: Set<PolarDeviceLattice>, routings: [SpatialRouting],
        cellOverrides: [PolarDeviceLattice: [SpatialCellAction]],
        toggleGuardSeconds: Double = SpatialInstrumentLayer.defaultToggleGuardSeconds,
        commonNotes: SpatialCommonNotes = .keep,
        midiTarget: InstrumentMIDITarget? = nil,
        surfaces: [SpatialSurface] = []
    ) {
        self.id = id
        self.midiTarget = midiTarget
        self.presentation = .init(name: name, color: color, isVisible: isVisible, isLocked: isLocked)
        self.isActive = isActive
        self.isSoloed = isSoloed
        self.commonNotes = commonNotes
        self.toggleGuardSeconds = SpatialInstrumentLayer.normalizedToggleGuard(toggleGuardSeconds)
        self.cells = cells
        self.routings = routings
        self.cellOverrides = cellOverrides
        self.surfaces = surfaces
    }

    func replacingGeometry(cells: Set<PolarDeviceLattice>, overrides: [PolarDeviceLattice: [SpatialCellAction]]) -> Self {
        var copy = self
        copy.cells = cells
        copy.cellOverrides = overrides
        return copy
    }

    /// Value projection used by saved-content comparison. Copying self keeps
    /// every other musical field, including future additions, intact.
    public func replacingActivity(_ active: Bool) -> Self {
        var copy = self; copy.isActive = active; return copy
    }

    public func renaming(_ name: String) -> Self {
        var copy = self; copy.presentation.name = name; return copy
    }

    /// Same layer with other surfaces (organisation fields untouched).
    public func replacing(surfaces: [SpatialSurface]) -> Self {
        Self(id: id, name: name, color: color, isVisible: isVisible, isActive: isActive, isLocked: isLocked, isSoloed: isSoloed,
             cells: cells, routings: routings, cellOverrides: cellOverrides, toggleGuardSeconds: toggleGuardSeconds,
             commonNotes: commonNotes, midiTarget: midiTarget, surfaces: surfaces)
    }

    /// Normalize only presentation, then use synthesized equality over the
    /// entire value. Future musical stored fields participate automatically.
    internal func hasSameIndexInputs(as other: Self) -> Bool {
        var normalized = self
        normalized.presentation = other.presentation
        guard normalized.surfaces.count == other.surfaces.count else { return false }
        // Surface names and colours are presentation too; everything else decides the index.
        normalized = normalized.replacing(surfaces: zip(normalized.surfaces, other.surfaces).map { next, old in
            next.replacingPresentation(old.presentation)
        })
        return normalized == other
    }

    // MARK: Partitions

    public var isSurfaceBacked: Bool { !surfaces.isEmpty }

    /// Runtime identities of this layer, cheap to ask. A layer without surfaces plays as itself.
    public var partitionIDs: [UUID] { surfaces.isEmpty ? [id] : surfaces.map(\.id) }

    /// Every routing the layer owns, whichever way it is stored.
    public var allRoutings: [SpatialRouting] { surfaces.isEmpty ? routings : surfaces.flatMap(\.routings) }

    /// Every per-cell action the layer owns, whichever way it is stored.
    public var allCellActions: [SpatialCellAction] {
        surfaces.isEmpty ? cellOverrides.values.flatMap { $0 } : surfaces.flatMap { $0.cellOverrides.values.flatMap { $0 } }
    }

    /// The compiled carriers of this layer, in the order they compile. Builds sorted cell arrays:
    /// ask once per compile, not per scan.
    public var partitions: [SpatialRuntimePartition] {
        guard !surfaces.isEmpty else {
            return [.init(id: id, ownerLayerID: id, surfaceID: nil, cells: cells.sorted(by: Self.cellOrder),
                          routings: routings, cellOverrides: cellOverrides)]
        }
        return surfaces.map { $0.partition(ownerLayerID: id) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, isVisible, isActive, isLocked, isSoloed, cells, routings, cellOverrides
        case toggleGuardSeconds, commonNotes, midiTarget, surfaces
    }

    private enum OverrideKeys: String, CodingKey { case cell, range, actions }

    /// Canonical ring intervals, never joined across a ring boundary.
    internal struct CellRange: Codable {
        let ring: Int
        let first: Int
        var last: Int
        init(_ cell: PolarDeviceLattice) { ring = cell.ring; first = cell.sector; last = cell.sector }
        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            ring = try values.decode(Int.self); first = try values.decode(Int.self); last = try values.decode(Int.self)
            guard values.isAtEnd, first <= last,
                  PolarDeviceLattice(ring: ring, sector: first) != nil,
                  PolarDeviceLattice(ring: ring, sector: last) != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid cell range"))
            }
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(ring); try values.encode(first); try values.encode(last)
        }
        var count: Int { last - first + 1 }
        var addresses: [PolarDeviceLattice] { (first...last).map { PolarDeviceLattice(ring: ring, sector: $0)! } }
    }
    internal struct RangeOverride: Encodable {
        var range: CellRange
        let actions: [SpatialCellAction]
    }
    internal static func ranges(_ cells: Set<PolarDeviceLattice>) -> [CellRange] {
        var result: [CellRange] = []
        for cell in cells.sorted(by: cellOrder) {
            if let tail = result.last, tail.ring == cell.ring, tail.last + 1 == cell.sector {
                result[result.count - 1].last = cell.sector
            } else { result.append(CellRange(cell)) }
        }
        return result
    }

    public init(from decoder: Decoder) throws {
        var counter = SpatialDocumentBudgetCounter(.production)
        try self.init(from: decoder, counter: &counter)
    }

    internal init(from decoder: Decoder, counter: inout SpatialDocumentBudgetCounter,
                  surfaceSettings: SurfaceSettings = .standard) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        presentation = .init(name: try container.decode(String.self, forKey: .name),
            color: try container.decode(SpatialLayerColor.self, forKey: .color),
            isVisible: try container.decode(Bool.self, forKey: .isVisible),
            isLocked: try container.decode(Bool.self, forKey: .isLocked))
        isActive = try container.decode(Bool.self, forKey: .isActive)
        isSoloed = try container.decode(Bool.self, forKey: .isSoloed)
        commonNotes = try container.decodeIfPresent(SpatialCommonNotes.self, forKey: .commonNotes) ?? .keep
        toggleGuardSeconds = SpatialInstrumentLayer.normalizedToggleGuard(try container.decodeIfPresent(Double.self, forKey: .toggleGuardSeconds) ?? 0)
        midiTarget = try container.decodeIfPresent(InstrumentMIDITarget.self, forKey: .midiTarget)

        var cellsContainer = try container.nestedUnkeyedContainer(forKey: .cells)
        cells = try Self.decodeCells(&cellsContainer, layerID: id, counter: &counter)
        var routingsContainer = try container.nestedUnkeyedContainer(forKey: .routings)
        routings = try Self.decodeRoutings(&routingsContainer, counter: &counter)
        var overridesContainer = try container.nestedUnkeyedContainer(forKey: .cellOverrides)
        cellOverrides = try Self.decodeOverrides(&overridesContainer, cells: cells, layerID: id, counter: &counter)

        if container.contains(.surfaces) {
            guard decoder.userInfo[.spatialSurfacesAllowed] as? Bool == true else {
                throw SpatialDocumentError.surfacesRequireNewerFormat
            }
            var surfacesContainer = try container.nestedUnkeyedContainer(forKey: .surfaces)
            var decoded: [SpatialSurface] = []
            counter.beginSurfaceList()
            while !surfacesContainer.isAtEnd {
                try counter.consume(.surfacesPerLayer)
                counter.beginLayer()
                decoded.append(try SpatialSurface(from: surfacesContainer.superDecoder(), settings: surfaceSettings, counter: &counter))
            }
            surfaces = decoded
        } else { surfaces = [] }
    }

    internal static func decodeCells(_ cellsContainer: inout UnkeyedDecodingContainer, layerID: UUID,
                                     counter: inout SpatialDocumentBudgetCounter) throws -> Set<PolarDeviceLattice> {
        var decodedCells = Set<PolarDeviceLattice>()
        while !cellsContainer.isAtEnd {
            let entry = try cellsContainer.superDecoder()
            let addresses: [PolarDeviceLattice]
            if (try? entry.unkeyedContainer()) != nil {
                let range = try CellRange(from: entry)
                try counter.consumeLayerAddress(count: range.count)
                try counter.consume(.addressesPerDocument, count: range.count)
                addresses = range.addresses
            } else {
                try counter.consumeLayerAddress(); try counter.consume(.addressesPerDocument)
                addresses = [try PolarDeviceLattice(from: entry)]
            }
            for cell in addresses {
                guard decodedCells.insert(cell).inserted else {
                    throw SpatialDocumentError.duplicateCell(layerID: layerID, cell: cell)
                }
            }
        }
        return decodedCells
    }

    internal static func decodeRoutings(_ routingsContainer: inout UnkeyedDecodingContainer,
                                        counter: inout SpatialDocumentBudgetCounter) throws -> [SpatialRouting] {
        var decodedRoutings: [SpatialRouting] = []
        while !routingsContainer.isAtEnd {
            try counter.consume(.routings)
            decodedRoutings.append(try SpatialRouting(
                from: routingsContainer.superDecoder(), counter: &counter
            ))
        }
        return decodedRoutings
    }

    internal static func decodeOverrides(_ overridesContainer: inout UnkeyedDecodingContainer, cells decodedCells: Set<PolarDeviceLattice>,
                                         layerID: UUID, counter: inout SpatialDocumentBudgetCounter) throws -> [PolarDeviceLattice: [SpatialCellAction]] {
        var decodedOverrides: [PolarDeviceLattice: [SpatialCellAction]] = [:]
        while !overridesContainer.isAtEnd {
            let recordDecoder = try overridesContainer.superDecoder()
            let recordContainer = try recordDecoder.container(keyedBy: OverrideKeys.self)
            let addresses: [PolarDeviceLattice]
            if recordContainer.contains(.range) {
                guard !recordContainer.contains(.cell) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: recordDecoder.codingPath, debugDescription: "Ambiguous override"))
                }
                addresses = try recordContainer.decode(CellRange.self, forKey: .range).addresses
            } else { addresses = [try recordContainer.decode(PolarDeviceLattice.self, forKey: .cell)] }
            for cell in addresses where !decodedCells.contains(cell) {
                try counter.consumeLayerAddress(); try counter.consume(.addressesPerDocument)
            }
            var actionsContainer = try recordContainer.nestedUnkeyedContainer(forKey: .actions)
            var actions: [SpatialCellAction] = []
            while !actionsContainer.isAtEnd {
                try counter.consume(.actionAssignments, count: addresses.count)
                actions.append(try SpatialCellAction(from: actionsContainer.superDecoder(), counter: &counter))
            }
            let notes = try checkedSpatialNoteCount(in: actions)
            if addresses.count > 1 { try counter.consume(.noteEntries, count: notes * (addresses.count - 1)) }
            for cell in addresses {
                guard decodedOverrides[cell] == nil else {
                    throw SpatialDocumentError.duplicateOverrideCell(layerID: layerID, cell: cell)
                }
                decodedOverrides[cell] = actions
            }
        }
        return decodedOverrides
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encode(isSoloed, forKey: .isSoloed)
        if commonNotes != .keep { try container.encode(commonNotes, forKey: .commonNotes) }
        if toggleGuardSeconds > 0 { try container.encode(toggleGuardSeconds, forKey: .toggleGuardSeconds) }
        try container.encodeIfPresent(midiTarget, forKey: .midiTarget)
        try container.encode(Self.ranges(cells), forKey: .cells)
        try container.encode(routings, forKey: .routings)
        try container.encode(Self.rangeOverrides(cellOverrides), forKey: .cellOverrides)
        if !surfaces.isEmpty {
            guard encoder.userInfo[.spatialSurfacesAllowed] as? Bool == true else {
                throw SpatialDocumentError.surfacesRequireNewerFormat
            }
            var list = container.nestedUnkeyedContainer(forKey: .surfaces)
            for surface in surfaces { try list.encode(surface) }
        }
    }

    internal static func rangeOverrides(_ cellOverrides: [PolarDeviceLattice: [SpatialCellAction]]) -> [RangeOverride] {
        var records: [RangeOverride] = []
        for cell in cellOverrides.keys.sorted(by: cellOrder) {
            let actions = cellOverrides[cell]!
            if let tail = records.last, tail.range.ring == cell.ring,
               tail.range.last + 1 == cell.sector, tail.actions == actions {
                records[records.count - 1].range.last = cell.sector
            } else { records.append(.init(range: CellRange(cell), actions: actions)) }
        }
        return records
    }

    internal static func cellOrder(_ lhs: PolarDeviceLattice, _ rhs: PolarDeviceLattice) -> Bool {
        lhs.ring == rhs.ring ? lhs.sector < rhs.sector : lhs.ring < rhs.ring
    }
}

public enum SpatialDocumentError: Error, Equatable, Sendable {
    case budgetExceeded(SpatialDocumentBudget.Kind)
    case unsupportedLatticeVersion(SpatialLatticeVersion)
    case emptyLayerStack
    case duplicateLayerID(UUID)
    case unknownSelection(UUID)
    case duplicateCell(layerID: UUID, cell: PolarDeviceLattice)
    case duplicateOverrideCell(layerID: UUID, cell: PolarDeviceLattice)
    /// A layer with surfaces keeps no cells, routings or overrides of its own.
    case surfaceLayerHasOwnMask(layerID: UUID)
    /// A runtime identity (layer without surfaces, or surface) is used twice.
    case duplicatePartitionID(UUID)
    case duplicateRoutingID(UUID)
    /// The document holds surface data that the format being written or read cannot carry.
    case surfacesRequireNewerFormat
    case invalidSurfaceSettings
    case invalidSurface(surfaceID: UUID)
    case surfaceRasterVersionUnsupported(Int)
    case surfaceDerivationMismatch(surfaceID: UUID)
    case surfaceSettingsMismatch(surfaceID: UUID)
}

public struct SpatialDocument: Codable, Equatable, Sendable {
    public let latticeVersion: SpatialLatticeVersion
    public let layers: [SpatialDocumentLayer]
    public private(set) var selectedLayerID: UUID
    /// Play area and outside policy of the editable surfaces. Masks of layers without surfaces ignore it.
    public private(set) var surfaceSettings: SurfaceSettings = .standard
    /// Load receipts are presentation only, not serialized document content.
    public private(set) var didMigrateScaleToggle = false

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.latticeVersion == rhs.latticeVersion && lhs.layers == rhs.layers && lhs.selectedLayerID == rhs.selectedLayerID
            && lhs.surfaceSettings == rhs.surfaceSettings
    }

    /// True when only a surface-capable format can carry this document without losing data.
    public var requiresSurfaceFormat: Bool {
        !surfaceSettings.isStandard || layers.contains { $0.isSurfaceBacked }
    }

    public func normalizingUnsupportedToggles(preservingLoadNotice: Bool = false) throws -> Self {
        guard layers.contains(where: { layer in
            layer.allRoutings.contains { $0.program != $0.program.replacingUnsupportedToggle }
        }) else {
            var result = self
            result.didMigrateScaleToggle = didMigrateScaleToggle || preservingLoadNotice
            return result
        }
        let normalized = layers.map(Self.normalizedLayer)
        var result = try Self(latticeVersion: latticeVersion, layers: normalized, selectedLayerID: selectedLayerID,
                              surfaceSettings: surfaceSettings)
        result.didMigrateScaleToggle = true
        return result
    }

    private static func normalizedLayer(_ layer: SpatialDocumentLayer) -> SpatialDocumentLayer {
        SpatialDocumentLayer(id: layer.id, name: layer.name, color: layer.color,
            isVisible: layer.isVisible, isActive: layer.isActive, isLocked: layer.isLocked, isSoloed: layer.isSoloed,
            cells: layer.cells, routings: layer.routings.map { routing in
                var next = routing; next.program = routing.program.replacingUnsupportedToggle; return next
            }, cellOverrides: layer.cellOverrides, toggleGuardSeconds: layer.toggleGuardSeconds, commonNotes: layer.commonNotes, midiTarget: layer.midiTarget,
            surfaces: layer.surfaces.map { surface in
                surface.replacing(routings: surface.routings.map { routing in
                    var next = routing; next.program = routing.program.replacingUnsupportedToggle; return next
                })
            })
    }

    public init(
        latticeVersion: SpatialLatticeVersion,
        layers: [SpatialDocumentLayer],
        selectedLayerID: UUID,
        surfaceSettings: SurfaceSettings = .standard
    ) throws {
        guard !layers.isEmpty else { throw SpatialDocumentError.emptyLayerStack }
        var ids = Set<UUID>()
        for layer in layers {
            guard ids.insert(layer.id).inserted else {
                throw SpatialDocumentError.duplicateLayerID(layer.id)
            }
        }
        guard ids.contains(selectedLayerID) else {
            throw SpatialDocumentError.unknownSelection(selectedLayerID)
        }
        var counter = SpatialDocumentBudgetCounter(.production)
        for layer in layers {
            try counter.consume(.layers)
            counter.beginLayer()
            for _ in layer.cells {
                try counter.consumeLayerAddress()
                try counter.consume(.addressesPerDocument)
            }
            for (cell, actions) in layer.cellOverrides {
                if !layer.cells.contains(cell) {
                    try counter.consumeLayerAddress()
                    try counter.consume(.addressesPerDocument)
                }
                for action in actions {
                    try counter.consume(.actionAssignments)
                    try countNotes(in: action.value, counter: &counter)
                }
            }
            for routing in layer.routings {
                try counter.consume(.routings)
                try countNotes(in: routing.program, counter: &counter)
            }
        }
        try Self.validateSurfaces(layers, settings: surfaceSettings, counter: &counter)
        self.latticeVersion = latticeVersion
        self.layers = layers
        self.selectedLayerID = selectedLayerID
        self.surfaceSettings = surfaceSettings
    }

    /// The surface rules, checked before anything is indexed: a layer with surfaces owns no mask,
    /// identities are unique across the whole document, derived cells and assignments count against
    /// the same budgets as painted ones, and every shaped surface was derived under these settings.
    private static func validateSurfaces(_ layers: [SpatialDocumentLayer], settings: SurfaceSettings,
                                         counter: inout SpatialDocumentBudgetCounter) throws {
        guard settings.problems().isEmpty else { throw SpatialDocumentError.invalidSurfaceSettings }
        guard layers.contains(where: \.isSurfaceBacked) else {
            // Partitions of a document without surfaces are its layers, already counted against `layers`.
            return
        }
        var partitionIDs = Set<UUID>(), routingIDs = Set<UUID>()
        let layerIDs = Set(layers.map(\.id))
        for layer in layers {
            try counter.consume(.partitions, count: max(1, layer.surfaces.count))
            // A surface may only carry the ID of its own layer (promotion keeps the identity).
            for surface in layer.surfaces where surface.id != layer.id && layerIDs.contains(surface.id) {
                throw SpatialDocumentError.duplicatePartitionID(surface.id)
            }
            for id in layer.partitionIDs {
                guard partitionIDs.insert(id).inserted else { throw SpatialDocumentError.duplicatePartitionID(id) }
            }
            for routing in layer.allRoutings {
                guard routingIDs.insert(routing.id).inserted else { throw SpatialDocumentError.duplicateRoutingID(routing.id) }
            }
            guard layer.isSurfaceBacked else { continue }
            guard layer.cells.isEmpty, layer.routings.isEmpty, layer.cellOverrides.isEmpty else {
                throw SpatialDocumentError.surfaceLayerHasOwnMask(layerID: layer.id)
            }
            counter.beginSurfaceList()
            try counter.consume(.surfacesPerLayer, count: layer.surfaces.count)
            for surface in layer.surfaces {
                counter.beginLayer()
                guard surface.presentation.valueColors.count <= SurfaceLimits.maximumValueColors else {
                    throw SpatialDocumentError.invalidSurface(surfaceID: surface.id)
                }
                if case .shape(let shape, let transform) = surface.form {
                    guard surface.settings == settings else { throw SpatialDocumentError.surfaceSettingsMismatch(surfaceID: surface.id) }
                    guard shape.problems(transform: transform).isEmpty else { throw SpatialDocumentError.invalidSurface(surfaceID: surface.id) }
                    guard surface.derivation.rasterVersion == SurfaceRasterizer.currentVersion else {
                        throw SpatialDocumentError.surfaceRasterVersionUnsupported(surface.derivation.rasterVersion)
                    }
                }
                try counter.consumeLayerAddress(count: surface.cells.count)
                try counter.consume(.addressesPerDocument, count: surface.cells.count)
                for routing in surface.routings {
                    try counter.consume(.routings)
                    try countNotes(in: routing.program, counter: &counter)
                }
                for (cell, actions) in surface.cellOverrides {
                    if !surface.derivation.cells.contains(cell) {
                        try counter.consumeLayerAddress()
                        try counter.consume(.addressesPerDocument)
                    }
                    for action in actions {
                        try counter.consume(.actionAssignments)
                        try countNotes(in: action.value, counter: &counter)
                    }
                }
            }
        }
    }

    /// Selection changes only a reference to an already validated layer.
    /// Coverage and assignments are unchanged and need no budget traversal.
    public func selectingLayer(_ id: UUID) throws -> Self {
        guard layers.contains(where: { $0.id == id }) else { throw SpatialDocumentError.unknownSelection(id) }
        var result = self
        result.selectedLayerID = id
        return result
    }

    /// The same document with other layers: lattice and surface settings are carried over, so no
    /// caller that rebuilds the layer stack can forget them.
    public func replacingLayers(_ layers: [SpatialDocumentLayer], selectedLayerID: UUID? = nil) throws -> Self {
        try Self(latticeVersion: latticeVersion, layers: layers, selectedLayerID: selectedLayerID ?? self.selectedLayerID,
                 surfaceSettings: surfaceSettings)
    }

    /// Layers that were already derived under `settings` (the caller re-derived them), with those settings.
    public func replacingLayers(_ layers: [SpatialDocumentLayer], selectedLayerID: UUID? = nil, surfaceSettings: SurfaceSettings) throws -> Self {
        try Self(latticeVersion: latticeVersion, layers: layers, selectedLayerID: selectedLayerID ?? self.selectedLayerID,
                 surfaceSettings: surfaceSettings)
    }

    /// New play area / outside policy. Every shaped surface is derived again under it; if any one
    /// cannot be, nothing changes.
    public func replacingSurfaceSettings(_ settings: SurfaceSettings) throws -> Self {
        let rederived = try layers.map { layer -> SpatialDocumentLayer in
            guard layer.isSurfaceBacked else { return layer }
            return layer.replacing(surfaces: try layer.surfaces.map { surface in
                guard !surface.isLegacyMask else { return surface }
                do { return try surface.rederived(under: settings) }
                catch { throw SpatialDocumentError.surfaceSettingsMismatch(surfaceID: surface.id) }
            })
        }
        return try Self(latticeVersion: latticeVersion, layers: rederived, selectedLayerID: selectedLayerID, surfaceSettings: settings)
    }

    // MARK: Runtime identities

    /// Runtime identities of every active layer (the partitions that play).
    public var activeRuntimeIDs: Set<UUID> { Set(layers.filter(\.isActive).flatMap(\.partitionIDs)) }

    /// Layer IDs (scenes, solo, required sets) become the partition IDs they stand for. An ID that
    /// is no layer stays as it is; a layer without surfaces maps to itself.
    public func runtimeIDs(forLayerIDs ids: Set<UUID>) -> Set<UUID> {
        var result = ids
        for layer in layers where ids.contains(layer.id) && layer.isSurfaceBacked {
            result.remove(layer.id)
            result.formUnion(layer.partitionIDs)
        }
        return result
    }

    /// Partition → owning layer, for every partition of a layer with surfaces.
    public var partitionOwners: [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for layer in layers where layer.isSurfaceBacked { for id in layer.partitionIDs { result[id] = layer.id } }
        return result
    }

    private enum CodingKeys: String, CodingKey { case latticeVersion, layers, selectedLayerID, surfaceSettings }

    public init(from decoder: Decoder) throws {
        var counter = SpatialDocumentBudgetCounter(decoder.userInfo[.spatialDocumentBudget] as? SpatialDocumentBudget ?? .production)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let latticeVersion = try container.decode(SpatialLatticeVersion.self, forKey: .latticeVersion)
        guard latticeVersion == .polarDeviceV2 else {
            throw SpatialDocumentError.unsupportedLatticeVersion(latticeVersion)
        }
        var settings = SurfaceSettings.standard
        if container.contains(.surfaceSettings) {
            guard decoder.userInfo[.spatialSurfacesAllowed] as? Bool == true else {
                throw SpatialDocumentError.surfacesRequireNewerFormat
            }
            settings = try container.decode(SurfaceSettingsWire.self, forKey: .surfaceSettings).value
            guard settings.problems().isEmpty else { throw SpatialDocumentError.invalidSurfaceSettings }
        }
        var layersContainer = try container.nestedUnkeyedContainer(forKey: .layers)
        var layers: [SpatialDocumentLayer] = []
        while !layersContainer.isAtEnd {
            try counter.consume(.layers)
            counter.beginLayer()
            layers.append(try SpatialDocumentLayer(from: layersContainer.superDecoder(), counter: &counter, surfaceSettings: settings))
        }
        let selectedLayerID = try container.decode(UUID.self, forKey: .selectedLayerID)
        guard !layers.isEmpty else { throw SpatialDocumentError.emptyLayerStack }
        var ids = Set<UUID>()
        for layer in layers {
            guard ids.insert(layer.id).inserted else {
                throw SpatialDocumentError.duplicateLayerID(layer.id)
            }
        }
        guard ids.contains(selectedLayerID) else {
            throw SpatialDocumentError.unknownSelection(selectedLayerID)
        }
        // Identities and mask ownership of surface layers; the decoder's counter already holds the cells.
        var checked = SpatialDocumentBudgetCounter(decoder.userInfo[.spatialDocumentBudget] as? SpatialDocumentBudget ?? .production)
        try Self.validateSurfaces(layers, settings: settings, counter: &checked)
        // The decoder's counter has already validated every address/action.
        // Normalize only programs, without another traversal of the fine mask.
        let migrated = layers.contains { layer in
            layer.allRoutings.contains { $0.program != $0.program.replacingUnsupportedToggle }
        }
        self.latticeVersion = latticeVersion
        self.layers = migrated ? layers.map(Self.normalizedLayer) : layers
        self.selectedLayerID = selectedLayerID
        self.surfaceSettings = settings
        self.didMigrateScaleToggle = migrated
    }

    public static func decode(_ data: Data) throws -> SpatialDocument {
        guard data.count <= SpatialDocumentBudget.production.inputBytes else {
            throw SpatialDocumentError.budgetExceeded(.inputBytes)
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.spatialDocumentBudget] = SpatialDocumentBudget.production
        return try decoder.decode(SpatialDocument.self, from: data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latticeVersion, forKey: .latticeVersion)
        if !surfaceSettings.isStandard {
            guard encoder.userInfo[.spatialSurfacesAllowed] as? Bool == true else {
                throw SpatialDocumentError.surfacesRequireNewerFormat
            }
            try container.encode(SurfaceSettingsWire(surfaceSettings), forKey: .surfaceSettings)
        }
        try container.encode(layers, forKey: .layers)
        try container.encode(selectedLayerID, forKey: .selectedLayerID)
    }
}

/// Wire form of the surface settings: `playArea` (rectangle | sector) and `outsidePolicy`. Strict.
private struct SurfaceSettingsWire: Codable {
    let value: SurfaceSettings
    init(_ value: SurfaceSettings) { self.value = value }
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        init(_ text: String) { stringValue = text }
    }
    private static func strict(_ decoder: Decoder, _ allowed: Set<String>) throws -> KeyedDecodingContainer<Key> {
        let container = try decoder.container(keyedBy: Key.self)
        for key in container.allKeys where !allowed.contains(key.stringValue) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [key], debugDescription: "Unknown surface settings key"))
        }
        return container
    }
    init(from decoder: Decoder) throws {
        let root = try Self.strict(decoder, ["playArea", "outsidePolicy"])
        let policy = try root.decode(SurfaceOutsidePolicy.self, forKey: Key("outsidePolicy"))
        let areaDecoder = try root.superDecoder(forKey: Key("playArea"))
        let probe = try areaDecoder.container(keyedBy: Key.self)
        let area: SurfacePlayArea
        switch try probe.decode(String.self, forKey: Key("kind")) {
        case "rectangle":
            let wire = try Self.strict(areaDecoder, ["kind", "xMinCm", "xMaxCm", "yMinCm", "yMaxCm"])
            area = .rectangle(xMinCm: try wire.decode(Double.self, forKey: Key("xMinCm")), xMaxCm: try wire.decode(Double.self, forKey: Key("xMaxCm")),
                              yMinCm: try wire.decode(Double.self, forKey: Key("yMinCm")), yMaxCm: try wire.decode(Double.self, forKey: Key("yMaxCm")))
        case "sector":
            let wire = try Self.strict(areaDecoder, ["kind", "fromCm", "toCm", "fromDegrees", "toDegrees"])
            area = .sector(fromCm: try wire.decode(Double.self, forKey: Key("fromCm")), toCm: try wire.decode(Double.self, forKey: Key("toCm")),
                           fromDegrees: try wire.decode(Double.self, forKey: Key("fromDegrees")), toDegrees: try wire.decode(Double.self, forKey: Key("toDegrees")))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: areaDecoder.codingPath, debugDescription: "Unknown play area kind"))
        }
        value = SurfaceSettings(playArea: area, outsidePolicy: policy)
    }
    func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: Key.self)
        try root.encode(value.outsidePolicy, forKey: Key("outsidePolicy"))
        var area = root.nestedContainer(keyedBy: Key.self, forKey: Key("playArea"))
        switch value.playArea {
        case .rectangle(let xMin, let xMax, let yMin, let yMax):
            try area.encode("rectangle", forKey: Key("kind"))
            try area.encode(xMin, forKey: Key("xMinCm")); try area.encode(xMax, forKey: Key("xMaxCm"))
            try area.encode(yMin, forKey: Key("yMinCm")); try area.encode(yMax, forKey: Key("yMaxCm"))
        case .sector(let from, let to, let fromDegrees, let toDegrees):
            try area.encode("sector", forKey: Key("kind"))
            try area.encode(from, forKey: Key("fromCm")); try area.encode(to, forKey: Key("toCm"))
            try area.encode(fromDegrees, forKey: Key("fromDegrees")); try area.encode(toDegrees, forKey: Key("toDegrees"))
        }
    }
}
