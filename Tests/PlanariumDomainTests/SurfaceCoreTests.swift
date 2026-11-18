import XCTest
@testable import PlanariumDomain

final class SurfaceCoreTests: XCTestCase {
    private let note1 = SpatialRoutingTarget.midiNote(channel: 0)

    private func singleNote(_ note: Int) -> SpatialRouting {
        .init(target: note1, program: .singleNote(note: note, velocity: 100, transition: .retrigger))
    }
    private func rect(_ id: UUID = UUID(), name: String = "S", w: Double = 40, h: Double = 20, x: Double = 0, y: Double = 100,
                      rotation: Double = 0, mirror: Bool = false, routings: [SpatialRouting] = []) throws -> SpatialSurface {
        try SpatialSurface(id: id, presentation: .init(name: name, color: .orange), form: .shape(.rectangle(widthCm: w, heightCm: h),
            .init(xCm: x, yCm: y, rotationDegrees: rotation, mirrorX: mirror)), routings: routings)
    }
    private func document(_ layers: [SpatialDocumentLayer]) throws -> InstrumentDocument {
        InstrumentDocument(spatial: try SpatialDocument(latticeVersion: .polarDeviceV2, layers: layers, selectedLayerID: layers[0].id),
                           revision: .init(session: UUID(), counter: 1))
    }
    private func layer(id: UUID = UUID(), surfaces: [SpatialSurface] = [], cells: Set<PolarDeviceLattice> = [],
                       routings: [SpatialRouting] = [], overrides: [PolarDeviceLattice: [SpatialCellAction]] = [:]) -> SpatialDocumentLayer {
        .init(id: id, name: "L", color: .orange, isVisible: true, isActive: true, isLocked: false, isSoloed: false,
              cells: cells, routings: routings, cellOverrides: overrides, surfaces: surfaces)
    }
    private func cell(_ ring: Int, _ tick: Int) -> PolarDeviceLattice { PolarDeviceLattice(ring: ring, sector: tick)! }

    func testRectangleCellsMatchAWorldSpaceOracle() throws {
        let surface = try rect(w: 40, h: 20, x: 10, y: 100, rotation: 25)
        let c = SurfaceTrig.sinCos(degrees: 25)
        var expected = Set<PolarDeviceLattice>()
        for ring in 1...200 { for tick in 0...360 {
            let p = SurfaceGrid.point(ring: ring, tick: tick)
            let dx = p.x - 10, dy = p.y - 100
            let lx = c.cos * dx + c.sin * dy, ly = -c.sin * dx + c.cos * dy
            if lx >= -20 - 1e-9, lx < 20 - 1e-9, ly >= -10 - 1e-9, ly < 10 - 1e-9 { expected.insert(cell(ring, tick)) }
        } }
        let got = Set(surface.cells)
        XCTAssertGreaterThan(got.count, 200)
        // Border handling may differ by a hair on exact edges; the bulk must agree.
        XCTAssertLessThan(got.symmetricDifference(expected).count, got.count / 20)
    }

    func testRotationTurnsCounterClockwiseAndDigestTracksCells() throws {
        let up = try rect(w: 60, h: 8, rotation: 45)
        let pts = up.cells.map { SurfaceGrid.point(ring: $0.ring, tick: $0.sector) }
        XCTAssertGreaterThan(pts.map { $0.x * ($0.y - 100) }.reduce(0, +), 0)
        let down = try rect(w: 60, h: 8, rotation: -45)
        XCTAssertNotEqual(up.derivation.digest, down.derivation.digest)
        XCTAssertEqual(up.derivation.rasterVersion, 1)
        XCTAssertEqual(up.derivation.digest, SurfaceRasterizer.digest(of: up.cells))
        XCTAssertNotEqual(SurfaceRasterizer.digest(of: Array(up.cells.dropLast())), up.derivation.digest)
    }

    func testTwoSurfacesOfOneLayerPlayAsTwoPartitionsOfOneOwner() throws {
        let layerID = UUID(), a = UUID(), b = UUID()
        let left = try rect(a, x: -60, routings: [singleNote(60)]), right = try rect(b, x: 60, routings: [singleNote(64)])
        XCTAssertTrue(Set(left.cells).isDisjoint(with: right.cells))
        let instrument = try InstrumentCompiler.compile(document([layer(id: layerID, surfaces: [left, right])]))
        XCTAssertEqual(Set(instrument.layers.map { $0.id }), [a, b])
        XCTAssertEqual(instrument.ownerLayerID(of: a), layerID)
        XCTAssertEqual(instrument.ownerLayerID(of: b), layerID)
        func notes(_ ids: [UUID: PolarDeviceLattice]) throws -> Set<Int> {
            let active = Dictionary(uniqueKeysWithValues: ids.map { ($0.key, CompiledActiveCell(layerID: $0.key, cell: $0.value, revision: instrument.revision)) })
            return Set(try instrument.evaluate(active: active).flatMap { evaluation -> [Int] in
                if case .notes(let set, _) = evaluation.value { return set.map { Int($0.number) } }
                return []
            })
        }
        XCTAssertEqual(try notes([a: left.cells[0]]), [60])
        XCTAssertEqual(try notes([b: right.cells[0]]), [64])
        XCTAssertEqual(try notes([a: left.cells[0], b: right.cells[0]]), [60, 64])
        XCTAssertEqual(try notes([:]), [])
    }

    func testPromotionCompilesIdenticallyAndKeepsIdentities() throws {
        let layerID = UUID()
        let cells: Set<PolarDeviceLattice> = [cell(50, 180), cell(51, 180), cell(52, 181)]
        let routing = singleNote(60)
        let override = SpatialCellAction(target: note1, value: .note(number: 67, velocity: 90))
        let before = try document([layer(id: layerID, cells: cells, routings: [routing], overrides: [cell(51, 180): [override]])])
        let after = try SurfaceEditor.apply(.promoteLayer(layerID: layerID), to: before)
        XCTAssertTrue(after.spatial.layers[0].isSurfaceBacked)
        XCTAssertEqual(after.spatial.layers[0].surfaces.map(\.id), [layerID])
        XCTAssertEqual(try InstrumentCompiler.compile(before).layers, try InstrumentCompiler.compile(after).layers)
        XCTAssertEqual(after.spatial.layers[0].allRoutings.map(\.id), [routing.id])
    }

    func testRejectedEditChangesNothing() throws {
        let sector = try SpatialSurface(presentation: .init(name: "R", color: .orange),
            form: .shape(.ringSector(fromCm: 40, toCm: 60, fromDegrees: -30, toDegrees: 30), .identity))
        let doc = try document([layer(surfaces: [sector])])
        XCTAssertThrowsError(try SurfaceEditor.apply(.moveSurfaces(ids: [sector.id], dxCm: 5, dyCm: 0), to: doc))
        XCTAssertThrowsError(try SurfaceEditor.apply(.moveSurfaces(ids: [UUID()], dxCm: 5, dyCm: 0), to: doc))
        XCTAssertThrowsError(try SurfaceEditor.apply(.moveSurfaces(ids: [], dxCm: 5, dyCm: 0), to: doc))
        let inf = try rect()
        let doc2 = try document([layer(surfaces: [inf])])
        XCTAssertThrowsError(try SurfaceEditor.apply(.moveSurfaces(ids: [inf.id], dxCm: .infinity, dyCm: 0), to: doc2))
        XCTAssertThrowsError(try SurfaceEditor.apply(.moveSurfaces(ids: [inf.id], dxCm: 5000, dyCm: 0), to: doc2))
        XCTAssertEqual(doc2.spatial.layers[0].surfaces, [inf])
    }

    func testMoveAndRotateRoundTripKeepCellsAndUndoByInverse() throws {
        let s = try rect(x: 0, y: 100, routings: [singleNote(60)])
        let doc = try document([layer(surfaces: [s])])
        let moved = try SurfaceEditor.apply(.moveSurfaces(ids: [s.id], dxCm: 20, dyCm: 10), to: doc)
        XCTAssertNotEqual(moved.spatial.layers[0].surfaces[0].cells, s.cells)
        let back = try SurfaceEditor.apply(.moveSurfaces(ids: [s.id], dxCm: -20, dyCm: -10), to: moved)
        XCTAssertEqual(back.spatial.layers[0].surfaces[0].cells, s.cells)
        let turned = try SurfaceEditor.apply(.rotateSurfaces(ids: [s.id], degrees: 90, aroundXCm: 0, aroundYCm: 100), to: doc)
        let again = try SurfaceEditor.apply(.rotateSurfaces(ids: [s.id], degrees: -90, aroundXCm: 0, aroundYCm: 100), to: turned)
        XCTAssertEqual(again.spatial.layers[0].surfaces[0].cells, s.cells)
    }

    func testPresentationChangeKeepsTheCompiledIndexReusable() throws {
        let s = try rect(routings: [singleNote(60)])
        let doc = try document([layer(surfaces: [s])])
        let renamed = try SurfaceEditor.apply(.setPresentation(surfaceID: s.id, .init(name: "Other", color: .green)), to: doc)
        XCTAssertTrue(InstrumentCompiler.canReuseIndex(from: doc, for: renamed))
        let moved = try SurfaceEditor.apply(.moveSurfaces(ids: [s.id], dxCm: 10, dyCm: 0), to: doc)
        XCTAssertFalse(InstrumentCompiler.canReuseIndex(from: doc, for: moved))
    }

    func testAxisFractionFollowsTheWorldDirectionForEveryPlacement() throws {
        let local = 30.0
        for (rotation, mirror) in [(0.0, false), (35.0, false), (90.0, true), (-120.0, true), (180.0, false)] {
            let routing = SpatialRouting(target: .midiCC(channel: 0, controller: 74),
                program: .continuous(minimum: 0, maximum: 1, directionDegrees: local, curve: .linear))
            let s = try rect(w: 60, h: 30, rotation: rotation, mirror: mirror, routings: [routing])
            let field = try SurfaceValueField(surface: s, routingID: routing.id)
            // Independent world direction: mirror the local vector, then rotate.
            let lx = cos(local * .pi / 180) * (mirror ? -1 : 1), ly = sin(local * .pi / 180)
            let r = rotation * .pi / 180
            let dx = cos(r) * lx - sin(r) * ly, dy = sin(r) * lx + cos(r) * ly
            let projections = s.cells.map { c -> Double in let p = SurfaceGrid.point(ring: c.ring, tick: c.sector); return p.x * dx + p.y * dy }
            let lo = projections.min()!, hi = projections.max()!
            for (c, p) in zip(s.cells, projections).prefix(400) {
                XCTAssertEqual(field.sample(c).fraction, (p - lo) / (hi - lo), accuracy: 1e-6, "rotation \(rotation) mirror \(mirror)")
            }
        }
    }

    func testReverseAxisIsAnInvolutionAndFlipsTheCourse() throws {
        let routing = SpatialRouting(target: .midiCC(channel: 0, controller: 1),
            program: .continuous(minimum: 0, maximum: 1, directionDegrees: 40, curve: .linear))
        let s = try rect(routings: [routing]), doc = try document([layer(surfaces: [s])])
        let once = try SurfaceEditor.apply(.reverseAxis(surfaceID: s.id, routingID: routing.id), to: doc)
        let twice = try SurfaceEditor.apply(.reverseAxis(surfaceID: s.id, routingID: routing.id), to: once)
        XCTAssertEqual(twice.spatial.layers[0].surfaces[0].routings, s.routings)
        let a = try SurfaceValueField(surface: s, routingID: routing.id)
        let b = try SurfaceValueField(surface: once.spatial.layers[0].surfaces[0], routingID: routing.id)
        let c0 = s.cells[0]
        XCTAssertEqual(a.sample(c0).fraction + b.sample(c0).fraction, 1, accuracy: 1e-9)
    }
}
