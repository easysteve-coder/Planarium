import Foundation
import SickPLSControlCore
@testable import PlanariumDomain

/// Spiegelt die Ebenenform eines Dokuments von **vor** dem polaren Cutover.
/// Das Produkt kennt diese Form nicht mehr; sie existiert nur noch, damit Tests
/// echte Altdokumente erzeugen und deren Migration prüfen können.
struct LegacyLayerDocument: Encodable {
    var id: UUID = UUID()
    var name: String
    var color: SpatialLayerColor
    var isVisible: Bool = true
    var isActive: Bool = true
    var isLocked: Bool = false
    var isSoloed: Bool = false
    var cells: Set<MetricGridCell> = []
    var routings: [SpatialRouting] = []
    var cellOverrides: [MetricGridCell: [SpatialCellAction]] = [:]
}

enum LegacyWorkspaceDocument {
    /// Baut ein vollständiges Altdokument um eine einzige alte Ebene.
    /// `coordinateMode` wird mitgeschrieben, weil alte Dokumente ihn haben; mit
    /// `nil` entsteht ein noch älteres Dokument ohne diesen Schlüssel. Das
    /// Dekodieren ignoriert den Wert in beiden Fällen und erzwingt polar.
    static func data(
        layer: LegacyLayerDocument,
        grid: MetricSquareGrid,
        coordinateMode: String? = "cartesian"
    ) throws -> Data {
        let layerJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(layer)
        ) as? [String: Any] ?? [:]
        let gridJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(grid)
        ) as? [String: Any] ?? [:]
        var object: [String: Any] = [
            "grid": gridJSON,
            "layers": [layerJSON],
            "selectedLayerID": layer.id.uuidString
        ]
        if let coordinateMode { object["coordinateMode"] = coordinateMode }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Dekodiert ein Altdokument in den heutigen Arbeitsbereich.
    static func decoded(
        layer: LegacyLayerDocument,
        grid: MetricSquareGrid,
        coordinateMode: String? = "cartesian"
    ) throws -> SpatialInstrumentWorkspace {
        try JSONDecoder().decode(
            SpatialInstrumentWorkspace.self,
            from: try data(layer: layer, grid: grid, coordinateMode: coordinateMode)
        )
    }
}
