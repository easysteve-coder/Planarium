import Foundation
import PLSDeviceValues

// Wire form of a surface inside format version 7. Objects are read strictly: an unknown key or an
// unknown `kind` fails the whole read. A shaped surface stores its original shape and placement
// plus `derived` (raster version, cell count, digest) as a check only, never the cells themselves.
// A legacy mask stores its cells and overrides as primary data, in the same ranges as a layer does.

private struct WireKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(_ value: String) { stringValue = value }
}

/// A keyed object that refuses keys outside its list.
private struct StrictObject {
    let container: KeyedDecodingContainer<WireKey>
    let decoder: Decoder
    init(_ decoder: Decoder, allowed: Set<String>) throws {
        self.decoder = decoder
        container = try decoder.container(keyedBy: WireKey.self)
        for key in container.allKeys where !allowed.contains(key.stringValue) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [key], debugDescription: "Unknown surface key"))
        }
    }
    func has(_ key: String) -> Bool { container.contains(WireKey(key)) }
    func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T { try container.decode(type, forKey: WireKey(key)) }
    func decodeIfPresent<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? { try container.decodeIfPresent(type, forKey: WireKey(key)) }
    func nestedUnkeyed(_ key: String) throws -> UnkeyedDecodingContainer { try container.nestedUnkeyedContainer(forKey: WireKey(key)) }
    func superDecoder(_ key: String) throws -> Decoder { try container.superDecoder(forKey: WireKey(key)) }
}

private struct WirePoint: Codable {
    let point: SurfacePoint
    init(_ point: SurfacePoint) { self.point = point }
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        let x = try values.decode(Double.self), y = try values.decode(Double.self)
        guard values.isAtEnd else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A point has two numbers")) }
        point = SurfacePoint(x: x, y: y)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(point.x); try values.encode(point.y)
    }
}

extension SpatialSurface: Encodable {
    private enum Key: String, CodingKey { case id, name, color, valueColors, routings, form, derived }
    private enum FormKey: String, CodingKey {
        case kind, widthCm, heightCm, radiusCm, pointsCm, fromCm, toCm, fromDegrees, toDegrees, transform, cells, cellOverrides
    }
    private enum TransformKey: String, CodingKey { case xCm, yCm, rotationDegrees, mirrorX }
    private enum DerivedKey: String, CodingKey { case rasterVersion, cellCount, cellDigest }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        // A file the reader would refuse is never written.
        guard presentation.valueColors.count <= SurfaceLimits.maximumValueColors else { throw SpatialDocumentError.invalidSurface(surfaceID: id) }
        try values.encode(id, forKey: .id)
        try values.encode(presentation.name, forKey: .name)
        try values.encode(presentation.color, forKey: .color)
        if !presentation.valueColors.isEmpty { try values.encode(presentation.valueColors, forKey: .valueColors) }
        try values.encode(routings, forKey: .routings)
        var form = values.nestedContainer(keyedBy: FormKey.self, forKey: .form)
        func placement(_ transform: SurfaceTransform, in form: inout KeyedEncodingContainer<FormKey>) throws {
            var wire = form.nestedContainer(keyedBy: TransformKey.self, forKey: .transform)
            try wire.encode(transform.xCm, forKey: .xCm); try wire.encode(transform.yCm, forKey: .yCm)
            try wire.encode(transform.rotationDegrees, forKey: .rotationDegrees); try wire.encode(transform.mirrorX, forKey: .mirrorX)
        }
        switch self.form {
        case .shape(.rectangle(let width, let height), let transform):
            try form.encode("rectangle", forKey: .kind); try form.encode(width, forKey: .widthCm); try form.encode(height, forKey: .heightCm)
            try placement(transform, in: &form)
        case .shape(.circle(let radius), let transform):
            try form.encode("circle", forKey: .kind); try form.encode(radius, forKey: .radiusCm)
            try placement(transform, in: &form)
        case .shape(.polygon(let points), let transform):
            try form.encode("polygon", forKey: .kind); try form.encode(points.map(WirePoint.init), forKey: .pointsCm)
            try placement(transform, in: &form)
        case .shape(.ringSector(let from, let to, let fromDegrees, let toDegrees), _):
            try form.encode("ringSector", forKey: .kind)
            try form.encode(from, forKey: .fromCm); try form.encode(to, forKey: .toCm)
            try form.encode(fromDegrees, forKey: .fromDegrees); try form.encode(toDegrees, forKey: .toDegrees)
        case .legacyMask(let mask):
            try form.encode("legacyMask", forKey: .kind)
            try form.encode(SpatialDocumentLayer.ranges(mask.cells), forKey: .cells)
            try form.encode(SpatialDocumentLayer.rangeOverrides(mask.cellOverrides), forKey: .cellOverrides)
        }
        var derived = values.nestedContainer(keyedBy: DerivedKey.self, forKey: .derived)
        try derived.encode(derivation.rasterVersion, forKey: .rasterVersion)
        try derived.encode(derivation.cells.count, forKey: .cellCount)
        try derived.encode(derivation.digestText, forKey: .cellDigest)
    }

    /// Strict read. The cells are derived with the frozen rasteriser of the stored version and must
    /// match the stored count and digest; any difference fails the read, nothing is repaired.
    init(from decoder: Decoder, settings: SurfaceSettings, counter: inout SpatialDocumentBudgetCounter) throws {
        let object = try StrictObject(decoder, allowed: ["id", "name", "color", "valueColors", "routings", "form", "derived"])
        let id = try object.decode(UUID.self, "id")
        let colors = try object.decodeIfPresent([SpatialLayerColor].self, "valueColors") ?? []
        guard colors.count <= SurfaceLimits.maximumValueColors else { throw SpatialDocumentError.invalidSurface(surfaceID: id) }
        let presentation = Presentation(name: try object.decode(String.self, "name"),
                                        color: try object.decode(SpatialLayerColor.self, "color"), valueColors: colors)
        var routingsContainer = try object.nestedUnkeyed("routings")
        let routings = try SpatialDocumentLayer.decodeRoutings(&routingsContainer, counter: &counter)

        let derived = try StrictObject(try object.superDecoder("derived"), allowed: ["rasterVersion", "cellCount", "cellDigest"])
        let claimedVersion = try derived.decode(Int.self, "rasterVersion")
        let claimedCount = try derived.decode(Int.self, "cellCount")
        let claimedDigest = try derived.decode(String.self, "cellDigest")
        guard claimedVersion == SurfaceRasterizer.currentVersion else {
            throw SpatialDocumentError.surfaceRasterVersionUnsupported(claimedVersion)
        }

        let formDecoder = try object.superDecoder("form")
        let kindProbe = try formDecoder.container(keyedBy: WireKey.self)
        let kind = try kindProbe.decode(String.self, forKey: WireKey("kind"))
        func transformObject(_ form: StrictObject) throws -> SurfaceTransform {
            let wire = try StrictObject(try form.superDecoder("transform"), allowed: ["xCm", "yCm", "rotationDegrees", "mirrorX"])
            return SurfaceTransform(xCm: try wire.decode(Double.self, "xCm"), yCm: try wire.decode(Double.self, "yCm"),
                                    rotationDegrees: try wire.decode(Double.self, "rotationDegrees"), mirrorX: try wire.decode(Bool.self, "mirrorX"))
        }
        let form: SurfaceForm
        switch kind {
        case "rectangle":
            let wire = try StrictObject(formDecoder, allowed: ["kind", "widthCm", "heightCm", "transform"])
            form = .shape(.rectangle(widthCm: try wire.decode(Double.self, "widthCm"), heightCm: try wire.decode(Double.self, "heightCm")), try transformObject(wire))
        case "circle":
            let wire = try StrictObject(formDecoder, allowed: ["kind", "radiusCm", "transform"])
            form = .shape(.circle(radiusCm: try wire.decode(Double.self, "radiusCm")), try transformObject(wire))
        case "polygon":
            let wire = try StrictObject(formDecoder, allowed: ["kind", "pointsCm", "transform"])
            let points = try wire.decode([WirePoint].self, "pointsCm").map(\.point)
            guard points.count <= SurfaceLimits.maximumPolygonPoints else { throw SpatialDocumentError.invalidSurface(surfaceID: id) }
            form = .shape(.polygon(pointsCm: points), try transformObject(wire))
        case "ringSector":
            let wire = try StrictObject(formDecoder, allowed: ["kind", "fromCm", "toCm", "fromDegrees", "toDegrees"])
            form = .shape(.ringSector(fromCm: try wire.decode(Double.self, "fromCm"), toCm: try wire.decode(Double.self, "toCm"),
                                      fromDegrees: try wire.decode(Double.self, "fromDegrees"), toDegrees: try wire.decode(Double.self, "toDegrees")), .identity)
        case "legacyMask":
            let wire = try StrictObject(formDecoder, allowed: ["kind", "cells", "cellOverrides"])
            var cellsContainer = try wire.nestedUnkeyed("cells")
            let cells = try SpatialDocumentLayer.decodeCells(&cellsContainer, layerID: id, counter: &counter)
            var overridesContainer = try wire.nestedUnkeyed("cellOverrides")
            let overrides = try SpatialDocumentLayer.decodeOverrides(&overridesContainer, cells: cells, layerID: id, counter: &counter)
            form = .legacyMask(LegacyMask(cells: cells, cellOverrides: overrides))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: formDecoder.codingPath, debugDescription: "Unknown surface kind"))
        }

        let derivation: SurfaceDerivation
        switch form {
        case .shape(let shape, let transform):
            do { derivation = try SurfaceRasterizer.derive(shape: shape, transform: transform, settings: settings) }
            catch SurfaceDerivationError.invalidShape { throw SpatialDocumentError.invalidSurface(surfaceID: id) }
            catch SurfaceDerivationError.invalidPlayArea { throw SpatialDocumentError.invalidSurfaceSettings }
            catch SurfaceDerivationError.rasterLimit { throw SpatialDocumentError.budgetExceeded(.addressesPerLayer) }
            catch let error as SurfaceDerivationError {
                if case .unsupportedRasterVersion(let version) = error { throw SpatialDocumentError.surfaceRasterVersionUnsupported(version) }
                throw SpatialDocumentError.surfaceSettingsMismatch(surfaceID: id)
            }
            try counter.consumeLayerAddress(count: derivation.cells.count)
            try counter.consume(.addressesPerDocument, count: derivation.cells.count)
        case .legacyMask(let mask):
            derivation = SurfaceRasterizer.derive(maskCells: mask.cells)
        }
        guard derivation.cells.count == claimedCount, derivation.digestText == claimedDigest else {
            throw SpatialDocumentError.surfaceDerivationMismatch(surfaceID: id)
        }
        self.init(id: id, presentation: presentation, form: form, routings: routings,
                  settings: form.isLegacyMask ? .standard : settings, derivation: derivation)
    }
}

extension SurfaceForm {
    var isLegacyMask: Bool { if case .legacyMask = self { return true }; return false }
}
