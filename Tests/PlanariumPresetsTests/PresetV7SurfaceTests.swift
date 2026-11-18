import XCTest
import PlanariumDomain
@testable import PlanariumPresets

final class PresetV7SurfaceTests: XCTestCase {
    private let target = SpatialRoutingTarget.midiNote(channel: 0)

    private func surfaceDocument() throws -> InstrumentDocument {
        let routing = SpatialRouting(target: target, program: .singleNote(note: 60, velocity: 100, transition: .retrigger))
        let cc = SpatialRouting(target: .midiCC(channel: 0, controller: 74),
                                program: .continuous(minimum: 0.1, maximum: 0.9, directionDegrees: 33.5, curve: .linear))
        let shaped = try SpatialSurface(presentation: .init(name: "Rect", color: .orange),
            form: .shape(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 5, yCm: 100, rotationDegrees: 90, mirrorX: true)), routings: [routing, cc])
        let poly = try SpatialSurface(presentation: .init(name: "Poly", color: .green),
            form: .shape(.polygon(pointsCm: [.init(x: 0, y: 0), .init(x: 30, y: 0), .init(x: 1e-9, y: 12)]), .init(xCm: -40, yCm: 90)),
            routings: [SpatialRouting(target: target, program: .singleNote(note: 62, velocity: 90, transition: .retrigger))])
        let mask = try SpatialSurface(presentation: .init(name: "Mask", color: .blue),
            form: .legacyMask(.init(cells: [PolarDeviceLattice(ring: 50, sector: 180)!, PolarDeviceLattice(ring: 51, sector: 181)!],
                                    cellOverrides: [PolarDeviceLattice(ring: 50, sector: 180)!: [.init(target: target, value: .note(number: 70, velocity: 80))]])))
        let layer = SpatialDocumentLayer(id: UUID(), name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false,
                                         isSoloed: false, cells: [], routings: [], cellOverrides: [:], surfaces: [shaped, poly, mask])
        let spatial = try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
        return InstrumentDocument(spatial: spatial, revision: .init(session: UUID(), counter: 1))
    }

    private func plainDocument() throws -> InstrumentDocument {
        let cell = PolarDeviceLattice(ring: 60, sector: 180)!
        let layer = SpatialDocumentLayer(id: UUID(), name: "Plain", color: .orange, isVisible: true, isActive: true, isLocked: false,
            isSoloed: false, cells: [cell], routings: [SpatialRouting(target: target, program: .singleNote(note: 60, velocity: 100, transition: .retrigger))], cellOverrides: [:])
        return InstrumentDocument(spatial: try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id),
                                  revision: .init(session: UUID(), counter: 1))
    }

    private func readDocument(_ data: Data) throws -> InstrumentDocument {
        switch PresetDocumentReader.read(data) {
        case .success(let reading): return try reading.replacing(try plainDocument())
        case .failure(let error): throw error
        }
    }
    private func failure(_ data: Data) -> PresetDocumentReadError? {
        if case .failure(let error) = PresetDocumentReader.read(data) { return error }; return nil
    }
    private func formatVersion(_ data: Data) throws -> Int {
        try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["formatVersion"] as? Int)
    }
    /// Edit every dictionary that holds `key` (surfaces are nested).
    private func tamper(_ data: Data, key: String, to value: Any) throws -> Data {
        func walk(_ node: Any) -> Any {
            if var dict = node as? [String: Any] {
                for (k, v) in dict { dict[k] = k == key ? value : walk(v) }
                return dict
            }
            if let array = node as? [Any] { return array.map(walk) }
            return node
        }
        return try JSONSerialization.data(withJSONObject: walk(try JSONSerialization.jsonObject(with: data)))
    }

    func testSurfaceDocumentRoundTripsAsVersion7WithOriginalsAndNoCellTruthForShapes() throws {
        let original = try surfaceDocument()
        let data = try PresetDocumentWriter.encode(.init(name: "Surfaces", document: original))
        XCTAssertEqual(try formatVersion(data), 7)
        let back = try readDocument(data)
        XCTAssertEqual(back.spatial.layers, original.spatial.layers)
        for (a, b) in zip(back.spatial.layers[0].surfaces, original.spatial.layers[0].surfaces) {
            XCTAssertEqual(a.cells, b.cells); XCTAssertEqual(a.derivation.digest, b.derivation.digest)
        }
        // Shaped surfaces store the original plus version/count/digest; the cell list is not stored.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("cellDigest") && text.contains("rasterVersion"))
        XCTAssertEqual(try PresetDocumentWriter.encode(.init(name: "Surfaces", document: back)), data)
    }

    func testDocumentsWithoutSurfacesStayVersion6ByteForByte() throws {
        let plain = try plainDocument()
        let data = try PresetDocumentWriter.encode(.init(name: "Plain", document: plain))
        XCTAssertEqual(try formatVersion(data), 6)
        XCTAssertEqual(data, try PresetV6Codec.encode(.init(name: "Plain", document: plain)))
    }

    func testVersion6WriterRefusesSurfacesInsteadOfLosingThem() throws {
        XCTAssertThrowsError(try PresetV6Codec.encode(.init(name: "S", document: try surfaceDocument()))) {
            XCTAssertEqual($0 as? PresetDocumentWriteError, .requiresNewerFormat)
        }
    }

    func testChangedRasterVersionDigestOrSettingsFailAtomically() throws {
        let data = try PresetDocumentWriter.encode(.init(name: "S", document: try surfaceDocument()))
        XCTAssertEqual(failure(try tamper(data, key: "rasterVersion", to: 2)), .surfaceRasterVersionUnsupported(2))
        guard case .some(.surfaceDerivationMismatch) = failure(try tamper(data, key: "cellDigest", to: "0000000000000000")) else {
            return XCTFail("wrong digest accepted")
        }
        guard case .some(.surfaceDerivationMismatch) = failure(try tamper(data, key: "cellCount", to: 1)) else {
            return XCTFail("wrong count accepted")
        }
        XCTAssertNotNil(failure(try tamper(data, key: "widthCm", to: -5)))
    }

    private func maskLayer(_ count: Int) throws -> SpatialDocumentLayer {
        let surfaces = try (0..<count).map { _ in try SpatialSurface(presentation: .init(name: "m", color: .orange),
            form: .legacyMask(.init(cells: [PolarDeviceLattice(ring: 50, sector: 180)!]))) }
        return SpatialDocumentLayer(id: UUID(), name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false,
                                    isSoloed: false, cells: [], routings: [], cellOverrides: [:], surfaces: surfaces)
    }
    private func document(_ layers: [SpatialDocumentLayer]) throws -> InstrumentDocument {
        InstrumentDocument(spatial: try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id),
                           revision: .init(session: UUID(), counter: 1))
    }

    /// The 64-surface limit is per layer on the file path too: 2 × 33 and 64 read back, 65 in one layer do not.
    func testSurfaceLimitIsPerLayerWhenReadingAFile() throws {
        let split = try document([maskLayer(33), maskLayer(33)])
        let splitData = try PresetDocumentWriter.encode(.init(name: "S", document: split))
        XCTAssertEqual(try readDocument(splitData).spatial.layers.map { $0.surfaces.count }, [33, 33])
        let full = try document([maskLayer(64)])
        let fullData = try PresetDocumentWriter.encode(.init(name: "S", document: full))
        XCTAssertEqual(try readDocument(fullData).spatial.layers[0].surfaces.count, 64)
        // One surface more in the same layer, appended to the stored file with a fresh identity.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fullData) as? [String: Any])
        func appendingSurface(_ node: Any) -> Any {
            if var dict = node as? [String: Any] {
                for (key, value) in dict { dict[key] = key == "surfaces" ? appended(value) : appendingSurface(value) }
                return dict
            }
            if let array = node as? [Any] { return array.map(appendingSurface) }
            return node
        }
        func appended(_ value: Any) -> Any {
            guard var surfaces = value as? [[String: Any]], var copy = surfaces.last else { return value }
            copy["id"] = UUID().uuidString
            surfaces.append(copy)
            return surfaces
        }
        json = try XCTUnwrap(appendingSurface(json) as? [String: Any])
        let tooMany = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(failure(tooMany), .budgetExceeded(.surfacesPerLayer))
    }

    func testSurfaceDataInAnOlderContainerIsRefused() throws {
        let data = try PresetDocumentWriter.encode(.init(name: "S", document: try surfaceDocument()))
        let old = try tamper(data, key: "formatVersion", to: 6)
        XCTAssertNotNil(failure(old), "surfaces in a V6 container must not load")
    }
}

final class PresetWriterCallerRuleTests: XCTestCase {
    /// Every real save path writes through the minimal-version writer; only the Kit compiler
    /// (which never produces surfaces) and the writer itself use the V6 codec directly.
    func testNoProductionCallerBypassesTheMinimalVersionWriter() throws {
        let root = "Sources"
        var offenders: [String] = []
        for file in try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: root)) where file.hasSuffix(".swift") {
            if file == "PlanariumPresets/InstrumentPresetV6.swift" || file.hasPrefix("PlanariumPresets/PatchKit/") { continue }
            if try String(contentsOfFile: "\(root)/\(file)").contains("PresetV6Codec.encode(") { offenders.append(file) }
        }
        XCTAssertEqual(offenders, [])
    }
}

/// B1: the colour limit holds on the whole path memory → editor → writer → file → reader.
final class SurfaceValueColourFileTests: XCTestCase {
    private func document(colors: Int) throws -> (InstrumentDocument, SpatialSurface) {
        let s = try SpatialSurface(presentation: .init(name: "C", color: .orange, valueColors: Array(repeating: .green, count: colors)),
            form: .shape(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 0, yCm: 100)),
            routings: [SpatialRouting(target: .midiCC(channel: 0, controller: 74), program: .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .linear))])
        let layer = SpatialDocumentLayer(id: UUID(), name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false,
            isSoloed: false, cells: [], routings: [], cellOverrides: [:], surfaces: [s])
        return (InstrumentDocument(spatial: try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id),
                                   revision: .init(session: UUID(), counter: 1)), s)
    }
    func testSixteenColoursSurviveARealSaveAndLoad() throws {
        let (doc, s) = try document(colors: 16)
        let data = try PresetDocumentWriter.encode(.init(name: "Sixteen", document: doc))
        guard case .success(let reading) = PresetDocumentReader.read(data) else { return XCTFail("16 colours must load") }
        let live = try document(colors: 0).0
        let back = try reading.replacing(live)
        XCTAssertEqual(back.spatial.layers[0].surfaces[0].presentation.valueColors.count, 16)
        XCTAssertEqual(back.spatial.layers[0].surfaces[0].id, s.id)
    }
    func testSeventeenColoursNeverReachAFile() throws {
        let (doc, s) = try document(colors: 16)
        let edit = SurfaceEdit.setPresentation(surfaceID: s.id, .init(name: "C", color: .orange, valueColors: Array(repeating: .green, count: 17)))
        XCTAssertThrowsError(try SurfaceEditor.apply(edit, to: doc))
        XCTAssertThrowsError(try document(colors: 17), "a document with 17 colours cannot be built")
        // The writer, the last gate, also refuses a surface the reader would refuse.
        let big = try SpatialSurface(presentation: .init(name: "C", color: .orange, valueColors: Array(repeating: .green, count: 17)),
            form: .shape(.circle(radiusCm: 10), .init(xCm: 0, yCm: 100)))
        XCTAssertThrowsError(try JSONEncoder().encode(big))
    }
}
