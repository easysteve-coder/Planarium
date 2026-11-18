import XCTest
@testable import PlanariumDomain

/// Fable review 24.10. (FLÄCHENEDITOR-KERN-1), findings B1, B3, B4.
final class SurfaceCoreReviewFixesTests: XCTestCase {
    private let cc = SpatialRouting(id: UUID(uuidString: "00000000-0000-4000-8000-000000000501")!, target: .midiCC(channel: 0, controller: 74),
        program: .continuous(minimum: 0, maximum: 1, directionDegrees: 90, curve: .linear))
    private func layer(_ surfaces: [SpatialSurface], id: UUID = UUID()) -> SpatialDocumentLayer {
        .init(id: id, name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
              cells: [], routings: [], cellOverrides: [:], surfaces: surfaces)
    }
    private func document(_ layers: [SpatialDocumentLayer]) throws -> InstrumentDocument {
        InstrumentDocument(spatial: try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id),
                           detection: .allStagesOff, revision: .init(session: UUID(), counter: 1))
    }
    private func surface(_ shape: SurfaceShape, _ transform: SurfaceTransform, colors: Int = 0) throws -> SpatialSurface {
        try SpatialSurface(presentation: .init(name: "s", color: .orange, valueColors: Array(repeating: .green, count: colors)),
                           form: .shape(shape, transform), routings: [cc])
    }

    // MARK: B1 — one limit for editor, document, writer and reader

    func testTheColourLimitIsOneConstantOf16() {
        XCTAssertEqual(SurfaceLimits.maximumValueColors, 16)
    }

    func testSeventeenColoursAreRefusedEverywhereAMemoryDocumentIsMade() throws {
        let s = try surface(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 0, yCm: 100))
        let doc = try document([layer([s])])
        let tooMany = SpatialSurface.Presentation(name: "s", color: .orange, valueColors: Array(repeating: .green, count: 17))
        let exactly = SpatialSurface.Presentation(name: "s", color: .orange, valueColors: Array(repeating: .green, count: 16))
        // Editor: setPresentation and addSurface.
        XCTAssertThrowsError(try SurfaceEditor.apply(.setPresentation(surfaceID: s.id, tooMany), to: doc)) {
            XCTAssertEqual($0 as? SurfaceEditError, .document(.invalidSurface(surfaceID: s.id)))
        }
        XCTAssertNoThrow(try SurfaceEditor.apply(.setPresentation(surfaceID: s.id, exactly), to: doc))
        let draft = SurfaceDraft(presentation: tooMany, shape: .circle(radiusCm: 10), transform: .init(xCm: 0, yCm: 100))
        XCTAssertThrowsError(try SurfaceEditor.apply(.addSurface(layerID: doc.spatial.layers[0].id, draft), to: doc))
        // A directly built document (no editor).
        let big = try surface(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 0, yCm: 100), colors: 17)
        let bigLayer = layer([big])
        XCTAssertThrowsError(try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [bigLayer], selectedLayerID: bigLayer.id)) {
            XCTAssertEqual($0 as? SpatialDocumentError, .invalidSurface(surfaceID: big.id))
        }
        // Atomic: the refused edit left the document as it was.
        XCTAssertEqual(doc.spatial.layers[0].surfaces[0].presentation.valueColors, [])
    }

    func testTheWireWriterRefusesWhatTheReaderCouldNotRead() throws {
        let big = try surface(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 0, yCm: 100), colors: 17)
        XCTAssertThrowsError(try JSONEncoder().encode(big)) {
            XCTAssertEqual($0 as? SpatialDocumentError, .invalidSurface(surfaceID: big.id))
        }
        let ok = try surface(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 0, yCm: 100), colors: 16)
        XCTAssertNoThrow(try JSONEncoder().encode(ok))
    }

    // MARK: B3 — a partition names the layer that owns it

    func testAPartitionIsMadeForAnExplicitOwner() throws {
        let s = try surface(.circle(radiusCm: 10), .init(xCm: 0, yCm: 100))
        let owner = UUID()
        let partition = s.partition(ownerLayerID: owner)
        XCTAssertEqual(partition.ownerLayerID, owner)
        XCTAssertEqual(partition.id, s.id); XCTAssertEqual(partition.surfaceID, s.id)
        XCTAssertEqual(partition.cells, s.cells)
        // Through a layer, every partition names that layer.
        let layerID = UUID()
        XCTAssertEqual(layer([s], id: layerID).partitions.map(\.ownerLayerID), [layerID])
        // And through the compiler: the compiled instrument knows the owner of a surface partition.
        let doc = try document([layer([s], id: layerID)])
        let compiled = try InstrumentCompiler.compile(doc)
        XCTAssertEqual(compiled.ownerLayerID(of: s.id), layerID)
    }

    // MARK: B4 — a resize keeps the kind of frame

    func testResizeCannotTurnAPlacedShapeIntoARingSectorAndReinterpretItsAxis() throws {
        let s = try surface(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 0, yCm: 100, rotationDegrees: 90))
        let doc = try document([layer([s])])
        XCTAssertEqual(SurfaceAxis.directionDegrees(of: s.materializedRoutings()[0].program), 180)
        XCTAssertThrowsError(try SurfaceEditor.apply(
            .resizeSurface(id: s.id, shape: .ringSector(fromCm: 40, toCm: 60, fromDegrees: -30, toDegrees: 30), transform: .identity), to: doc)) {
            XCTAssertEqual($0 as? SurfaceEditError, .resizeCannotChangeFrame(s.id))
        }
    }

    func testResizeCannotTurnARingSectorIntoAPlacedShape() throws {
        let sector = try surface(.ringSector(fromCm: 40, toCm: 60, fromDegrees: -30, toDegrees: 30), .identity)
        let doc = try document([layer([sector])])
        XCTAssertThrowsError(try SurfaceEditor.apply(
            .resizeSurface(id: sector.id, shape: .rectangle(widthCm: 20, heightCm: 10), transform: .init(xCm: 0, yCm: 100, rotationDegrees: 45)), to: doc)) {
            XCTAssertEqual($0 as? SurfaceEditError, .resizeCannotChangeFrame(sector.id))
        }
    }

    func testResizeInsideOneKindOfFrameKeepsTheLocalAxis() throws {
        let rotated = try surface(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 0, yCm: 100, rotationDegrees: 90, mirrorX: true))
        let sector = try SpatialSurface(presentation: .init(name: "sector", color: .green),
            form: .shape(.ringSector(fromCm: 40, toCm: 60, fromDegrees: -30, toDegrees: 30), .identity),
            routings: [SpatialRouting(target: .midiCC(channel: 0, controller: 75),
                                      program: .continuous(minimum: 0, maximum: 1, directionDegrees: 12, curve: .linear))])
        let doc = try document([layer([rotated]), layer([sector])])
        // Rectangle -> circle and a new size and placement: still a placeable shape; local axis untouched.
        let resized = try SurfaceEditor.apply(.resizeSurface(id: rotated.id, shape: .circle(radiusCm: 12),
                                                             transform: .init(xCm: 3, yCm: 90, rotationDegrees: 90, mirrorX: true)), to: doc)
        let after = resized.spatial.layers[0].surfaces[0]
        XCTAssertEqual(after.routings, rotated.routings, "the authored (local) axis is not rewritten")
        XCTAssertEqual(after.transform, .init(xCm: 3, yCm: 90, rotationDegrees: 90, mirrorX: true))
        XCTAssertEqual(SurfaceAxis.directionDegrees(of: after.materializedRoutings()[0].program),
                       SurfaceAxis.worldDegrees(local: 90, transform: after.transform), "the world axis follows the kept transform")
        // Ring sector -> ring sector (same kind) resizes; its placement stays the scanner centre.
        let wider = try SurfaceEditor.apply(.resizeSurface(id: sector.id, shape: .ringSector(fromCm: 30, toCm: 80, fromDegrees: -50, toDegrees: 50),
                                                           transform: .identity), to: doc)
        let afterSector = wider.spatial.layers[1].surfaces[0]
        XCTAssertEqual(afterSector.form, .shape(.ringSector(fromCm: 30, toCm: 80, fromDegrees: -50, toDegrees: 50), .identity))
        XCTAssertEqual(afterSector.routings, sector.routings)
        XCTAssertEqual(afterSector.materializedRoutings(), sector.materializedRoutings())
    }
}
