import Foundation
import PLSDeviceValues

// MARK: - Fehler

public enum LegacySpatialDocumentError: Error, Equatable, Sendable {
    case notAJSONObject
    case emptyLayerStack
    case nonIntegerCentimeterGrid(Double)
    case malformedLayer(index: Int, reason: String)
    /// Strukturfehler oberhalb der Ebenen — etwa fehlendes oder falsch
    /// typisiertes `grid`/`layers`. Eigener Fall, weil `malformedLayer`
    /// sonst eine Ebene benennen müsste, die es gar nicht gibt.
    case malformedDocument(reason: String)
}

// MARK: - Befund

public enum LegacySpatialDocumentFinding: Equatable, Sendable {
    case unknownSelection(UUID?)
}

// MARK: - Werte

public struct LegacySpatialDocument: Equatable, Sendable {
    public let cellSizeMeters: Double
    public let layers: [LegacySpatialLayer]
    public let selectedLayerID: UUID?

    /// Nur ``LegacySpatialDocumentReader`` baut diesen Wert. Öffentlich
    /// baubar wäre er breiter als seine erzwingbare Vorbedingung: ein
    /// leerer Ebenenstapel und ein krummes Zentimeterraster sind
    /// ausdrücklich abgelehnt, ließen sich von außen aber herstellen.
    init(
        cellSizeMeters: Double,
        layers: [LegacySpatialLayer],
        selectedLayerID: UUID?
    ) {
        self.cellSizeMeters = cellSizeMeters
        self.layers = layers
        self.selectedLayerID = selectedLayerID
    }
}

public struct LegacySpatialLayer: Equatable, Sendable {
    public let midiTarget: InstrumentMIDITarget?
    public let id: UUID
    public let name: String
    public let color: SpatialLayerColor
    public let isVisible: Bool
    public let isActive: Bool
    public let isLocked: Bool
    public let isSoloed: Bool
    public let cells: Set<MetricGridCell>
    public let polarCells: Set<PolarMetricGridCell>
    public let routings: [SpatialRouting]
    public let cellOverrides: [MetricGridCell: [SpatialCellAction]]
    public let polarCellOverrides: [PolarMetricGridCell: [SpatialCellAction]]
    public let commonNotes: SpatialCommonNotes
    public let toggleGuardSeconds: Double

    init(
        id: UUID,
        name: String,
        color: SpatialLayerColor,
        isVisible: Bool,
        isActive: Bool,
        isLocked: Bool,
        isSoloed: Bool,
        cells: Set<MetricGridCell>,
        polarCells: Set<PolarMetricGridCell>,
        routings: [SpatialRouting],
        cellOverrides: [MetricGridCell: [SpatialCellAction]],
        polarCellOverrides: [PolarMetricGridCell: [SpatialCellAction]],
        toggleGuardSeconds: Double = 0,
        commonNotes: SpatialCommonNotes = .keep,
        midiTarget: InstrumentMIDITarget? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isVisible = isVisible
        self.isActive = isActive
        self.isLocked = isLocked
        self.isSoloed = isSoloed
        self.cells = cells
        self.polarCells = polarCells
        self.routings = routings
        self.cellOverrides = cellOverrides
        self.polarCellOverrides = polarCellOverrides
        self.commonNotes = commonNotes
        self.toggleGuardSeconds = SpatialInstrumentLayer.normalizedToggleGuard(toggleGuardSeconds)
        self.midiTarget = midiTarget
    }
}

public struct LegacySpatialDocumentReading: Equatable, Sendable {
    public let document: LegacySpatialDocument
    public let findings: [LegacySpatialDocumentFinding]

    init(
        document: LegacySpatialDocument,
        findings: [LegacySpatialDocumentFinding]
    ) {
        self.document = document
        self.findings = findings
    }
}

// MARK: - Reader

public enum LegacySpatialDocumentReader {

    /// Liest ein Altdokument wörtlich. Es wird nichts migriert, nichts
    /// umgerechnet, keine Zelle transformiert.
    public static func read(from data: Data) throws -> LegacySpatialDocumentReading {

        // 1. Top-Level muss ein JSON-Objekt sein.
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LegacySpatialDocumentError.notAJSONObject
        }
        guard let _ = parsed as? [String: Any] else {
            throw LegacySpatialDocumentError.notAJSONObject
        }

        // 2. Struktur über JSONDecoder lesen (Set/Dictionary korrekt).
        let raw: _RawDocument
        do {
            raw = try JSONDecoder().decode(_RawDocument.self, from: data)
        } catch let error as LegacySpatialDocumentError {
            throw error
        } catch {
            throw LegacySpatialDocumentError.malformedDocument(
                reason: "Dokumentstruktur unlesbar"
            )
        }

        // 3. Raster: cellSizeMeters * 100 muss ganzzahlig sein.
        let centimeters = raw.grid.cellSizeMeters * 100
        guard centimeters == centimeters.rounded() else {
            throw LegacySpatialDocumentError.nonIntegerCentimeterGrid(raw.grid.cellSizeMeters)
        }

        // 4. Ebenenstapel darf nicht leer sein.
        guard !raw.layers.isEmpty else {
            throw LegacySpatialDocumentError.emptyLayerStack
        }

        // 5. Öffentliche Werte bauen — alles wörtlich, keine Sortierung.
        let decodedLayers: [LegacySpatialLayer] = raw.layers.map { raw in
            LegacySpatialLayer(
                id: raw.id,
                name: raw.name,
                color: raw.color,
                isVisible: raw.isVisible,
                isActive: raw.isActive,
                isLocked: raw.isLocked,
                isSoloed: raw.isSoloed,
                cells: raw.cells ?? [],
                polarCells: raw.polarCells ?? [],
                routings: raw.routings,
                cellOverrides: raw.cellOverrides ?? [:],
                polarCellOverrides: raw.polarCellOverrides ?? [:],
                toggleGuardSeconds: raw.toggleGuardSeconds ?? 0, commonNotes: raw.commonNotes ?? .keep, midiTarget: raw.midiTarget
            )
        }
        let layers = splitMultiRoutingLayers(decodedLayers)

        // 6. Auswahl: wörtlich erhalten, Befund bei unbekannter UUID.
        var findings: [LegacySpatialDocumentFinding] = []
        if let selID = raw.selectedLayerID {
            if !layers.contains(where: { $0.id == selID }) {
                findings.append(.unknownSelection(selID))
            }
        } else {
            findings.append(.unknownSelection(nil))
        }

        let document = LegacySpatialDocument(
            cellSizeMeters: raw.grid.cellSizeMeters,
            layers: layers,
            selectedLayerID: raw.selectedLayerID
        )
        return LegacySpatialDocumentReading(document: document, findings: findings)
    }
}

private func splitMultiRoutingLayers(
    _ source: [LegacySpatialLayer]
) -> [LegacySpatialLayer] {
    source.flatMap { layer in
        guard layer.routings.count > 1 else { return [layer] }
        return layer.routings.enumerated().map { index, routing in
            LegacySpatialLayer(
                id: index == 0 ? layer.id : UUID(),
                name: index == 0 ? layer.name : "\(layer.name) · \(index + 1)",
                color: layer.color,
                isVisible: layer.isVisible,
                isActive: layer.isActive,
                isLocked: layer.isLocked,
                isSoloed: layer.isSoloed,
                cells: layer.cells,
                polarCells: layer.polarCells,
                routings: [routing],
                cellOverrides: layer.cellOverrides,
                polarCellOverrides: layer.polarCellOverrides,
                toggleGuardSeconds: layer.toggleGuardSeconds, commonNotes: layer.commonNotes, midiTarget: layer.midiTarget
            )
        }
    }
}

// MARK: - Private Decoding-Helfer

private struct _RawDocument: Decodable {
    let grid: _RawGrid
    let layers: [_RawLayer]
    let selectedLayerID: UUID?

    enum CodingKeys: String, CodingKey {
        case grid, layers, selectedLayerID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.grid = try container.decode(_RawGrid.self, forKey: .grid)

        guard container.contains(.layers) else {
            self.layers = []
            self.selectedLayerID = try container.decodeIfPresent(UUID.self, forKey: .selectedLayerID)
            return
        }

        var layersContainer = try container.nestedUnkeyedContainer(forKey: .layers)
        var layers: [_RawLayer] = []
        var index = 0
        while !layersContainer.isAtEnd {
            do {
                let layer = try layersContainer.decode(_RawLayer.self)
                layers.append(layer)
            } catch {
                throw LegacySpatialDocumentError.malformedLayer(
                    index: index,
                    reason: "Required field missing or has incorrect type"
                )
            }
            index += 1
        }
        self.layers = layers

        self.selectedLayerID = try container.decodeIfPresent(UUID.self, forKey: .selectedLayerID)
    }
}

private struct _RawGrid: Decodable {
    let cellSizeMeters: Double
}

private struct _RawLayer: Decodable {
    let id: UUID
    let name: String
    let color: SpatialLayerColor
    let isVisible: Bool
    let isActive: Bool
    let isLocked: Bool
    let isSoloed: Bool
    let cells: Set<MetricGridCell>?
    let polarCells: Set<PolarMetricGridCell>?
    /// Pflichtfeld. `SpatialInstrumentLayer.init(from:)` verlangt es
    /// ebenfalls; ein Altdokument ohne `routings` war nie lesbar. Optional
    /// zu lesen hieße, still ein Dokument anzunehmen, das es nicht gibt.
    let routings: [SpatialRouting]
    let cellOverrides: [MetricGridCell: [SpatialCellAction]]?
    let polarCellOverrides: [PolarMetricGridCell: [SpatialCellAction]]?
    let commonNotes: SpatialCommonNotes?
    let toggleGuardSeconds: Double?
    let midiTarget: InstrumentMIDITarget?
}
