import XCTest
@testable import PlanariumDomain

/// FLÄCHENEDITOR-UI-1, domain entry points the canvas needs: picking a surface by its real form,
/// and a preview of a geometric edit that is the edit's own placement.
final class SurfaceUIFoundationTests: XCTestCase {
    private func cell(_ ring: Int, _ tick: Int) -> PolarDeviceLattice { PolarDeviceLattice(ring: ring, sector: tick)! }
    private func surface(_ shape: SurfaceShape, _ transform: SurfaceTransform = .identity, routings: [SpatialRouting] = []) throws -> SpatialSurface {
        try SpatialSurface(presentation: .init(name: "s", color: .orange), form: .shape(shape, transform), routings: routings)
    }
    private func document(_ surfaces: [SpatialSurface]) throws -> (InstrumentDocument, UUID) {
        let id = UUID()
        let layer = SpatialDocumentLayer(id: id, name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false,
                                         isSoloed: false, cells: [], routings: [], cellOverrides: [:], surfaces: surfaces)
        return (InstrumentDocument(spatial: try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: id),
                                   detection: .allStagesOff, revision: .init(session: UUID(), counter: 1)), id)
    }

    // MARK: Picking

    func testPickingAgreesWithTheRasterisedCellsForEveryShapeKind() throws {
        let concave = SurfaceShape.polygon(pointsCm: [.init(x: -40, y: 60), .init(x: 40, y: 60), .init(x: 40, y: 140),
                                                      .init(x: 10, y: 140), .init(x: 10, y: 100), .init(x: -10, y: 100),
                                                      .init(x: -10, y: 140), .init(x: -40, y: 140)])
        let shapes: [(String, SpatialSurface)] = [
            ("rectangle", try surface(.rectangle(widthCm: 60, heightCm: 30), .init(xCm: 20, yCm: 100, rotationDegrees: 25, mirrorX: true))),
            ("circle", try surface(.circle(radiusCm: 30), .init(xCm: -30, yCm: 90))),
            ("concave polygon", try surface(concave, .init(xCm: 0, yCm: 0, rotationDegrees: 0))),
            ("ring sector", try surface(.ringSector(fromCm: 50, toCm: 120, fromDegrees: -40, toDegrees: 60)))
        ]
        for (name, s) in shapes {
            // Every derived cell lies inside the picked footprint (a cell is one of the raster's own points).
            // A ring sector is bounded by exact radii and bearings: a cell on its edge is probed a quarter
            // centimetre outward and a hundredth of a degree inward, because a free point on the edge can
            // land on either side of the rounding error.
            for c in s.cells.prefix(400) {
                var p = SurfaceGrid.point(ring: c.ring, tick: c.sector)
                if name == "ring sector" {
                    let bearing = min(max(SurfaceGrid.bearing(tick: c.sector), -39.99), 59.99) * .pi / 180, radius = Double(c.ring) + 0.25
                    p = SurfacePoint(x: radius * sin(bearing), y: radius * cos(bearing))
                }
                XCTAssertTrue(s.containsWorldPoint(xCm: p.x, yCm: p.y), "\(name) cell \(c)")
            }
            // Far outside, behind the scanner and non-finite points are never inside.
            XCTAssertFalse(s.containsWorldPoint(xCm: 900, yCm: 900), name)
            XCTAssertFalse(s.containsWorldPoint(xCm: .nan, yCm: 10), name)
            XCTAssertFalse(s.containsWorldPoint(xCm: 0, yCm: -500), name)
        }
        // The notch of the concave polygon is outside although it lies inside the bounding box.
        let notch = shapes[2].1
        XCTAssertFalse(notch.containsWorldPoint(xCm: 0, yCm: 130))
        XCTAssertTrue(notch.containsWorldPoint(xCm: 0, yCm: 80))
    }

    func testPickingAnExactMaskUsesItsCellsAndNotItsBoundingBox() throws {
        let cells: Set<PolarDeviceLattice> = [cell(100, 180), cell(101, 180), cell(150, 300)]
        let mask = try SpatialSurface(presentation: .init(name: "m", color: .blue), form: .legacyMask(LegacyMask(cells: cells)))
        let on = SurfaceGrid.point(ring: 100, tick: 180), far = SurfaceGrid.point(ring: 100, tick: 200)
        XCTAssertTrue(mask.containsWorldPoint(xCm: on.x, yCm: on.y))
        XCTAssertFalse(mask.containsWorldPoint(xCm: far.x, yCm: far.y), "a gap inside the box is not part of the mask")
        let bounds = mask.worldBounds
        XCTAssertTrue(bounds.maxY > bounds.minY && bounds.maxX > bounds.minX)
    }

    // MARK: Placement parity

    private func formAfter(_ edit: SurfaceEdit, in document: InstrumentDocument, id: UUID) throws -> SurfaceForm {
        let next = try SurfaceEditor.apply(edit, to: document)
        return next.spatial.layers.flatMap(\.surfaces).first { $0.id == id }!.form
    }

    func testThePreviewPlacementIsExactlyWhatTheEditProduces() throws {
        let rect = try surface(.rectangle(widthCm: 40, heightCm: 20), .init(xCm: 10, yCm: 100, rotationDegrees: 15))
        let poly = try surface(.polygon(pointsCm: [.init(x: -20, y: -10), .init(x: 20, y: -10), .init(x: 0, y: 20)]), .init(xCm: 0, yCm: 110))
        let sector = try surface(.ringSector(fromCm: 40, toCm: 100, fromDegrees: -30, toDegrees: 50))
        let (doc, _) = try document([rect, poly, sector])
        let edits: [(SpatialSurface, SurfaceEdit)] = [
            (rect, .moveSurfaces(ids: [rect.id], dxCm: 7, dyCm: -3)),
            (rect, .rotateSurfaces(ids: [rect.id, poly.id], degrees: 33, aroundXCm: 5, aroundYCm: 90)),
            (poly, .rotateSurfaces(ids: [rect.id, poly.id], degrees: 33, aroundXCm: 5, aroundYCm: 90)),
            (rect, .mirrorSurfaces(ids: [rect.id], aboutXCm: 12)),
            (rect, .setTransform(id: rect.id, .init(xCm: -4, yCm: 105, rotationDegrees: 90, mirrorX: true))),
            (rect, .resizeSurface(id: rect.id, shape: .rectangle(widthCm: 55, heightCm: 12), transform: .init(xCm: 0, yCm: 100))),
            (poly, .movePolygonPoint(id: poly.id, index: 2, to: .init(x: 5, y: 30))),
            (sector, .resizeSurface(id: sector.id, shape: .ringSector(fromCm: 30, toCm: 130, fromDegrees: -50, toDegrees: 20), transform: .identity)),
            (sector, .mirrorSurfaces(ids: [sector.id], aboutXCm: 0))
        ]
        for (subject, edit) in edits {
            let placement = try XCTUnwrap(try SurfaceEditor.placement(of: subject, after: edit), "\(edit)")
            let form = try formAfter(edit, in: doc, id: subject.id)
            XCTAssertEqual(form, .shape(placement.shape, sector.id == subject.id ? .identity : placement.transform), "\(edit)")
        }
        // An edit that names another surface does not place this one; a non-geometric edit places nothing.
        XCTAssertNil(try SurfaceEditor.placement(of: poly, after: .moveSurfaces(ids: [rect.id], dxCm: 1, dyCm: 1)))
        XCTAssertNil(try SurfaceEditor.placement(of: rect, after: .deleteSurfaces(ids: [rect.id])))
    }

    func testAResizeNeverTurnsAPlacementOfARingSectorIntoIdentity() throws {
        let sector = try surface(.ringSector(fromCm: 40, toCm: 100, fromDegrees: -30, toDegrees: 50))
        let (doc, _) = try document([sector])
        let edit = SurfaceEdit.resizeSurface(id: sector.id, shape: .ringSector(fromCm: 40, toCm: 120, fromDegrees: -30, toDegrees: 50),
                                             transform: .init(xCm: 10, yCm: 0, rotationDegrees: 0, mirrorX: false))
        XCTAssertThrowsError(try SurfaceEditor.apply(edit, to: doc)) {
            XCTAssertEqual($0 as? SurfaceEditError, .ringSectorCannotBePlaced(sector.id))
        }
        for transform in [SurfaceTransform(rotationDegrees: 10), SurfaceTransform(mirrorX: true)] {
            XCTAssertThrowsError(try SurfaceEditor.apply(.resizeSurface(id: sector.id, shape: .ringSector(fromCm: 40, toCm: 120, fromDegrees: -30, toDegrees: 50), transform: transform), to: doc))
        }
        // The identity placement stays accepted: a sector resizes and stays centred on the scanner.
        let resized = try SurfaceEditor.apply(.resizeSurface(id: sector.id, shape: .ringSector(fromCm: 40, toCm: 120, fromDegrees: -30, toDegrees: 50), transform: .identity), to: doc)
        XCTAssertEqual(resized.spatial.layers[0].surfaces[0].form, .shape(.ringSector(fromCm: 40, toCm: 120, fromDegrees: -30, toDegrees: 50), .identity))
    }
}
