import XCTest
import PlanariumDomain
@testable import SickPLSMonitorKit

/// FLÄCHENEDITOR-UI-1, the pure logic behind the field: gestures, handles, picking and the value coding.
final class SurfaceEditorKitTests: XCTestCase {
    private let geometry = MetricCanvasGeometry(size: CGSize(width: 900, height: 700),
                                                viewport: try! MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 0.7, metersPerPoint: 0.0025))
    private var space: SurfaceCanvasSpace { SurfaceCanvasSpace(geometry) }
    private func pt(_ x: Double, _ y: Double) -> CGPoint { space.screen(.init(x: x, y: y)) }
    private func rect(_ w: Double = 60, _ h: Double = 40, _ t: SurfaceTransform = .init(xCm: 0, yCm: 100), routings: [SpatialRouting] = []) throws -> SpatialSurface {
        try SpatialSurface(presentation: .init(name: "r", color: .orange), form: .shape(.rectangle(widthCm: w, heightCm: h), t), routings: routings)
    }
    private func document(_ surfaces: [SpatialSurface], hidden: Bool = false) throws -> SpatialDocument {
        let layer = SpatialDocumentLayer(id: UUID(), name: "L", color: .orange, isVisible: !hidden, isActive: true, isLocked: false,
                                         isSoloed: false, cells: [], routings: [], cellOverrides: [:], surfaces: surfaces)
        return try SpatialDocument(latticeVersion: .polarDeviceV2, layers: [layer], selectedLayerID: layer.id)
    }
    private func gesture(_ kind: SurfaceGesture.Kind, from a: SurfacePoint, to b: SurfacePoint, originals: [SpatialSurface] = [],
                         modifiers: SurfaceModifiers = []) -> SurfaceGesture {
        var g = SurfaceGesture(kind: kind, space: space, startScreen: space.screen(a), start: a, originals: originals, layerID: UUID(), modifiers: modifiers)
        _ = g.update(toScreen: space.screen(b), modifiers: modifiers)
        return g
    }

    // MARK: Drawing

    func testDrawingARectangleCircleAndSectorGivesTidyNumbersAndModifiersChangeThem() throws {
        var r = gesture(.draw(.rectangle), from: .init(x: -30, y: 80), to: .init(x: 30, y: 120)).evaluate()
        XCTAssertEqual(r.drawn?.shape, .rectangle(widthCm: 60, heightCm: 40))
        XCTAssertEqual(r.drawn?.transform.xCm ?? 9, 0, accuracy: 0.11); XCTAssertEqual(r.drawn?.transform.yCm ?? 0, 100, accuracy: 0.11)
        r = gesture(.draw(.rectangle), from: .init(x: -30, y: 80), to: .init(x: 30, y: 120), modifiers: .shift).evaluate()
        guard case .rectangle(let w, let h)? = r.drawn?.shape else { return XCTFail() }
        XCTAssertEqual(w, h, "shift makes a square")
        r = gesture(.draw(.rectangle), from: .init(x: 0, y: 100), to: .init(x: 30, y: 120), modifiers: .option).evaluate()
        XCTAssertEqual(r.drawn?.shape, .rectangle(widthCm: 60, heightCm: 40), "option draws from the middle")
        XCTAssertEqual(r.drawn?.transform.xCm ?? 9, 0, accuracy: 0.11)
        r = gesture(.draw(.circle), from: .init(x: 0, y: 100), to: .init(x: 30, y: 140)).evaluate()
        XCTAssertEqual(r.drawn?.shape, .circle(radiusCm: 50))
        r = gesture(.draw(.ringSector), from: .init(x: -50, y: 100), to: .init(x: 50, y: 70)).evaluate()
        guard case .ringSector(let from, let to, let a, let b)? = r.drawn?.shape else { return XCTFail() }
        XCTAssertEqual(from, from.rounded()); XCTAssertEqual(to, to.rounded())
        XCTAssertLessThan(from, to); XCTAssertLessThan(a, b)
        XCTAssertEqual(r.drawn?.transform, .identity)
        // A sketch that cannot become a shape is named and offers no edit.
        r = gesture(.draw(.circle), from: .init(x: 0, y: 100), to: .init(x: 0, y: 100)).evaluate()
        XCTAssertNotNil(r.problem)
    }

    func testAPolygonDraftNamesItsProblemAndCentresTheShape() {
        var draft = SurfacePolygonDraft()
        for p in [(0.0, 80.0), (40, 120), (40, 80), (0, 120)] { draft.add(.init(x: p.0, y: p.1)) }
        XCTAssertFalse(draft.canClose); XCTAssertNotNil(draft.message)
        XCTAssertTrue(draft.removeLast()); XCTAssertTrue(draft.removeLast())
        draft.add(.init(x: 50, y: 100))
        XCTAssertTrue(draft.canClose)
        let made = draft.shape()
        XCTAssertNotNil(made)
        XCTAssertFalse(draft.add(.init(x: 50, y: 100)), "the same place twice is one corner")
    }

    // MARK: Handles

    func testHandlesAreAtLeastAsBigAsTheCellSelectionHandlesAndStayOnTheCanvas() throws {
        let layout = SurfaceHandleLayout.make(surfaces: [try rect()], axisRoutingID: nil, space: space, lockedReason: nil)
        XCTAssertEqual(layout.size, 16, "a large surface keeps the old 16 pt handles")
        XCTAssertEqual(layout.handles.count, 9, "four corners, four edges, one turning handle")
        for handle in layout.handles { XCTAssertEqual(layout.handle(at: handle.center)?.kind, handle.kind) }
        // Pressing 8 pt beside a corner still grabs it.
        let corner = try XCTUnwrap(layout.handles.first { $0.kind == .rectCorner(sx: 1, sy: 1) })
        XCTAssertEqual(layout.handle(at: CGPoint(x: corner.center.x + 7, y: corner.center.y - 7))?.kind, .rectCorner(sx: 1, sy: 1))
        // At the visible edge the handles stay inside the canvas, and zoomed far out they keep their size.
        let edge = SurfaceHandleLayout.make(surfaces: [try rect(60, 40, .init(xCm: 120, yCm: 60))], axisRoutingID: nil, space: space, lockedReason: nil)
        for handle in edge.handles { XCTAssertTrue(geometry.canvasRect.insetBy(dx: 7, dy: 7).contains(handle.center), "\(handle.kind)") }
        let far = MetricCanvasGeometry(size: CGSize(width: 900, height: 700), viewport: try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 1, metersPerPoint: 0.01))
        let small = SurfaceHandleLayout.make(surfaces: [try rect(30, 20)], axisRoutingID: nil, space: SurfaceCanvasSpace(far), lockedReason: nil)
        XCTAssertGreaterThanOrEqual(small.size, 8)
        XCTAssertGreaterThanOrEqual(small.hitRadius, small.size / 2)
    }

    func testAnExactAreaAndARingSectorDisableWhatTheyCannotDoWithAReason() throws {
        let mask = try SpatialSurface(presentation: .init(name: "m", color: .blue),
                                      form: .legacyMask(LegacyMask(cells: [PolarDeviceLattice(ring: 100, sector: 180)!, PolarDeviceLattice(ring: 101, sector: 180)!])))
        let masked = SurfaceHandleLayout.make(surfaces: [mask], axisRoutingID: nil, space: space, lockedReason: nil)
        XCTAssertFalse(masked.handles.isEmpty)
        XCTAssertTrue(masked.handles.allSatisfy { !$0.isEnabled && $0.disabledReason?.isEmpty == false })
        let sector = try SpatialSurface(presentation: .init(name: "s", color: .blue), form: .shape(.ringSector(fromCm: 50, toCm: 120, fromDegrees: -30, toDegrees: 40), .identity))
        let sectored = SurfaceHandleLayout.make(surfaces: [sector], axisRoutingID: nil, space: space, lockedReason: nil)
        XCTAssertEqual(sectored.handles.count, 8)
        XCTAssertTrue(sectored.handles.allSatisfy(\.isEnabled))
        let locked = SurfaceHandleLayout.make(surfaces: [try rect()], axisRoutingID: nil, space: space, lockedReason: "Layer is locked")
        XCTAssertTrue(locked.handles.allSatisfy { !$0.isEnabled && $0.disabledReason == "Layer is locked" })
        // A scaled selection with a sector or an exact area is refused as a whole.
        let mixed = SurfaceHandleLayout.make(surfaces: [try rect(), sector], axisRoutingID: nil, space: space, lockedReason: nil)
        XCTAssertTrue(mixed.handles.allSatisfy { !$0.isEnabled })
    }

    func testResizingMovesOnlyWhatTheHandleOwnsAndKeepsShapeKinds() throws {
        let surface = try rect(60, 40, .init(xCm: 0, yCm: 100, rotationDegrees: 0))
        // The upper right corner at (30, 120) dragged to (50, 140): the lower left corner stays.
        var r = gesture(.handle(.rectCorner(sx: 1, sy: 1)), from: .init(x: 30, y: 120), to: .init(x: 50, y: 140), originals: [surface]).evaluate()
        XCTAssertEqual(r.placements[surface.id]?.shape, .rectangle(widthCm: 80, heightCm: 60))
        XCTAssertEqual(r.placements[surface.id]?.transform.xCm ?? 0, 10, accuracy: 0.11)
        XCTAssertEqual(r.edits.count, 1)
        // Option keeps the middle.
        r = gesture(.handle(.rectEdge(sx: 1, sy: 0)), from: .init(x: 30, y: 100), to: .init(x: 50, y: 100), originals: [surface], modifiers: .option).evaluate()
        XCTAssertEqual(r.placements[surface.id]?.shape, .rectangle(widthCm: 100, heightCm: 40))
        XCTAssertEqual(r.placements[surface.id]?.transform.xCm ?? 9, 0, accuracy: 0.11)
        // A circle stays a circle.
        let circle = try SpatialSurface(presentation: .init(name: "c", color: .blue), form: .shape(.circle(radiusCm: 20), .init(xCm: 10, yCm: 100)))
        r = gesture(.handle(.circleRadius(index: 0)), from: .init(x: 30, y: 100), to: .init(x: 50, y: 100), originals: [circle]).evaluate()
        XCTAssertEqual(r.placements[circle.id]?.shape, .circle(radiusCm: 40))
        // A polygon corner moves in the polygon's own frame.
        let poly = try SpatialSurface(presentation: .init(name: "p", color: .blue),
                                      form: .shape(.polygon(pointsCm: [.init(x: -20, y: -10), .init(x: 20, y: -10), .init(x: 0, y: 20)]), .init(xCm: 0, yCm: 100)))
        r = gesture(.handle(.polygonPoint(index: 2)), from: .init(x: 0, y: 120), to: .init(x: 5, y: 130), originals: [poly]).evaluate()
        XCTAssertEqual(r.edits, [.movePolygonPoint(id: poly.id, index: 2, to: .init(x: 5, y: 30))])
        // A sector handle changes whole centimetres and half degrees and stays centred.
        let sector = try SpatialSurface(presentation: .init(name: "s", color: .blue), form: .shape(.ringSector(fromCm: 50, toCm: 120, fromDegrees: -30, toDegrees: 40), .identity))
        r = gesture(.handle(.sectorOuter), from: .init(x: 0, y: 120), to: .init(x: 0, y: 150.3), originals: [sector]).evaluate()
        XCTAssertEqual(r.placements[sector.id]?.shape, .ringSector(fromCm: 50, toCm: 150, fromDegrees: -30, toDegrees: 40))
        XCTAssertEqual(r.placements[sector.id]?.transform, .identity)
    }

    func testScalingAndTurningASelectionIsOneEditSetFromTheOriginals() throws {
        let a = try rect(40, 20, .init(xCm: -30, yCm: 100)), b = try rect(40, 20, .init(xCm: 30, yCm: 100))
        let bounds = a.worldBounds.union(b.worldBounds)
        let corner = SurfacePoint(x: bounds.maxX, y: bounds.maxY)
        let r = gesture(.handle(.frameCorner(sx: 1, sy: 1)), from: corner, to: SurfacePoint(x: bounds.minX + (bounds.maxX - bounds.minX) * 2, y: bounds.minY + (bounds.maxY - bounds.minY) * 2), originals: [a, b]).evaluate()
        XCTAssertEqual(r.edits.count, 2)
        XCTAssertEqual(r.undoName, "Scale surfaces")
        XCTAssertEqual(r.placements[a.id]?.shape, .rectangle(widthCm: 80, heightCm: 40))
        let turn = gesture(.rotate(pivot: .init(x: 0, y: 100), startAngle: 90), from: .init(x: 0, y: 140), to: .init(x: -40, y: 100), originals: [a, b]).evaluate()
        XCTAssertEqual(turn.edits, [.rotateSurfaces(ids: [a.id, b.id], degrees: 90, aroundXCm: 0, aroundYCm: 100)])
    }

    func testTheArrowTipTurnsTheAxisOfTheAssignmentAndNamesTheBearing() throws {
        let routing = SpatialRouting(target: .audioUnitNote(channel: 0, stripID: UUID()),
                                     program: .scale(rootMIDINote: 57, lowestMIDINote: 57, highestMIDINote: 69, scale: .minorPentatonic, directionDegrees: 0, ascending: true, transition: .retrigger))
        let surface = try rect(60, 40, .init(xCm: 0, yCm: 100), routings: [routing])
        let r = gesture(.handle(.axisTip(routingID: routing.id)), from: .init(x: 30, y: 100), to: .init(x: 0, y: 160), originals: [surface]).evaluate()
        XCTAssertEqual(r.edits, [.setAxis(surfaceID: surface.id, routingID: routing.id, worldDegrees: 90)])
        XCTAssertEqual(r.arrow?.degrees, 90)
    }

    // MARK: Picking

    func testPickingTakesTheTopmostVisibleSurfaceAndAHiddenLayerIsSkipped() throws {
        let under = try rect(100, 100, .init(xCm: 0, yCm: 100)), over = try rect(40, 40, .init(xCm: 0, yCm: 100))
        let doc = try document([under, over])
        XCTAssertEqual(SurfacePicker.pick(at: .init(x: 0, y: 100), in: doc)?.surfaceID, over.id)
        XCTAssertEqual(SurfacePicker.pick(at: .init(x: 40, y: 100), in: doc)?.surfaceID, under.id)
        XCTAssertNil(SurfacePicker.pick(at: .init(x: 90, y: 100), in: doc))
        XCTAssertNil(SurfacePicker.pick(at: .init(x: 0, y: 100), in: try document([under, over], hidden: true)))
        let hit = SurfacePicker.surfaces(in: SurfaceBounds(minX: -10, maxX: 10, minY: 90, maxY: 110), document: doc)
        XCTAssertEqual(Set(hit.map(\.surfaceID)), [under.id, over.id])
    }

    // MARK: Value coding against the world

    /// Every cell of the surface is asked what it plays; the colour the coding gives at the cell's place along the
    /// arrow has to be the colour of that value on the legend's ramp.
    func testAShiftedSurfaceWithAnInverseCurveColoursEachCellByItsRealValue() throws {
        let routing = SpatialRouting(target: .audioUnitCC(channel: 0, controller: 74, stripID: UUID()),
                                     program: .continuous(minimum: 0, maximum: 1, directionDegrees: 0, curve: .easeIn))
        var surface = try rect(80, 20, .init(xCm: 60, yCm: 110, rotationDegrees: 0), routings: [routing])
        surface = try SpatialSurface(id: surface.id, presentation: .init(name: "cc", color: .orange, valueColors: [.init(red: 0, green: 0, blue: 1), .init(red: 1, green: 0, blue: 0)]),
                                     form: surface.form, routings: [routing])
        let field = try SurfaceValueField(surface: surface, routingID: routing.id)
        let coding = try XCTUnwrap(SurfaceValueCoding(surface: surface, routingID: routing.id))
        XCTAssertEqual(coding.kind, .continuous)
        XCTAssertEqual(coding.legend, "CC74 · 0 → 127 · slow start")
        let arrow = try XCTUnwrap(coding.arrow)
        XCTAssertEqual(arrow.arrowBearingDegrees, 90, accuracy: 0.01, "program direction 0° is a bearing of 90°")
        XCTAssertEqual(arrow.start.x, 20, accuracy: 0.6); XCTAssertEqual(arrow.tip.x, 100, accuracy: 0.6, "the arrow spans the shifted surface")
        var compared = 0
        for cell in surface.cells.prefix(500) {
            guard case .scalar(let value) = field.sample(cell).value else { return XCTFail() }
            let t = field.arrowFraction(cell)
            let nearest = coding.stops.min { abs($0.position - t) < abs($1.position - t) }!
            XCTAssertEqual(nearest.level, value, accuracy: 0.12, "cell at \(t)")
            compared += 1
        }
        XCTAssertGreaterThan(compared, 100)
        // The same surface with the arrow reversed: the colours follow the values, not the geometry.
        let flipped = try SurfaceEditor.apply(.reverseAxis(surfaceID: surface.id, routingID: routing.id), to: try documentWith(surface))
        let after = try XCTUnwrap(flipped.spatial.layers.flatMap(\.surfaces).first)
        let reversed = try XCTUnwrap(SurfaceValueCoding(surface: after, routingID: routing.id))
        XCTAssertEqual(SurfaceAxis.normalized(reversed.arrow?.arrowBearingDegrees ?? 0), SurfaceAxis.normalized(270), accuracy: 0.01)
        XCTAssertEqual(reversed.arrow?.start.x ?? 0, arrow.tip.x, accuracy: 0.6)
        let reversedField = try SurfaceValueField(surface: after, routingID: routing.id)
        for cell in after.cells.prefix(200) {
            guard case .scalar(let value) = reversedField.sample(cell).value else { return XCTFail() }
            let t = reversedField.arrowFraction(cell)
            XCTAssertEqual(reversed.stops.min { abs($0.position - t) < abs($1.position - t) }!.level, value, accuracy: 0.12)
        }
    }
    private func documentWith(_ surface: SpatialSurface) throws -> InstrumentDocument {
        InstrumentDocument(spatial: try document([surface]), detection: .allStagesOff, revision: .init(session: UUID(), counter: 1))
    }

    func testADescendingScaleListsItsNotesWithNamesInTheWorldOrder() throws {
        let routing = SpatialRouting(target: .audioUnitNote(channel: 0, stripID: UUID()),
                                     program: .scale(rootMIDINote: 57, lowestMIDINote: 57, highestMIDINote: 69, scale: .minorPentatonic, directionDegrees: 0, ascending: false, transition: .retrigger))
        let surface = try rect(100, 20, .init(xCm: 0, yCm: 110), routings: [routing])
        let field = try SurfaceValueField(surface: surface, routingID: routing.id)
        let coding = try XCTUnwrap(SurfaceValueCoding(surface: surface, routingID: routing.id))
        XCTAssertEqual(coding.kind, .scale)
        XCTAssertEqual(coding.steps.map(\.name), ["A3", "C4", "D4", "E4", "G4", "A4"])
        XCTAssertTrue(coding.steps.first { $0.name == "A3" }?.isRoot ?? false)
        XCTAssertTrue(coding.legend.hasPrefix("A3 → A4"))
        // The note a cell plays lies inside the band the coding gives it.
        for cell in surface.cells.prefix(400) {
            guard case .notes(let notes, _) = field.sample(cell).value, let note = notes.first else { return XCTFail() }
            let t = field.arrowFraction(cell)
            let step = try XCTUnwrap(coding.steps.first { $0.note == Int(note.number) })
            XCTAssertTrue(t >= step.from - 0.02 && t <= step.to + 0.02, "\(step.name) at \(t)")
        }
    }

    // MARK: B6 – no silent nothing for cells on surfaces

    func testPitchEditsWorkOnTheChosenSurfacesAndRefuseCellsOfASurfaceOutLoud() throws {
        let note = { (n: Int) in SpatialRouting(target: .midiNote(channel: 0), program: .singleNote(note: n, velocity: 100, transition: .retrigger)) }
        let a = try rect(40, 20, .init(xCm: -50, yCm: 100), routings: [note(60)]), b = try rect(40, 20, .init(xCm: 50, yCm: 100), routings: [note(64)])
        let doc = try documentWith(a, b)
        let layerID = doc.spatial.layers[0].id
        var selection = CanvasSelection(); selection.surfaceIDs = [a.id]
        let changed = try SpatialCellBulkEdit.apply(.transpose(12), to: doc, selection: selection, activeLayerID: layerID)
        let surfaces = changed.spatial.layers[0].surfaces
        XCTAssertEqual(surfaces[0].routings[0].program, .singleNote(note: 72, velocity: 100, transition: .retrigger))
        XCTAssertEqual(surfaces[1], b, "the surface that was not chosen is untouched, bit for bit")
        // The whole layer still reaches every surface.
        let whole = try SpatialCellBulkEdit.apply(.transpose(12), to: doc, selection: CanvasSelection(), activeLayerID: layerID)
        XCTAssertEqual(whole.spatial.layers[0].surfaces.map { $0.routings[0].program },
                       [.singleNote(note: 72, velocity: 100, transition: .retrigger), .singleNote(note: 76, velocity: 100, transition: .retrigger)])
        // A coarse cell of a surface layer is no unit: the old path used to do nothing quietly.
        var cells = CanvasSelection(cells: [CanvasCellSelection(layerID: layerID, cell: PolarMetricGridCell(ring: 10, angularIndex: 10))])
        cells.anchor = nil
        XCTAssertThrowsError(try SpatialCellBulkEdit.apply(.transpose(12), to: doc, selection: cells, activeLayerID: layerID)) {
            if case SpatialPitchOperation.Failure.cellsOfASurface = $0 {} else { XCTFail("\($0)") }
        }
        // A vanished surface is named, not skipped.
        selection.surfaceIDs = [UUID()]
        XCTAssertThrowsError(try SpatialCellBulkEdit.apply(.transpose(1), to: doc, selection: selection, activeLayerID: layerID)) {
            if case SpatialPitchOperation.Failure.unknownSurface = $0 {} else { XCTFail("\($0)") }
        }
    }

    // MARK: Grabbing a handle never jumps

    private func grabAt(_ handle: SurfaceHandle, originals: [SpatialSurface], to delta: (Double, Double) = (0, 0)) throws -> SurfaceGesture.Result {
        let world = try XCTUnwrap(space.world(handle.center))
        var g = SurfaceGesture(kind: .handle(handle.kind), space: space, startScreen: handle.center, start: world, originals: originals)
        if delta != (0, 0) { _ = g.update(toScreen: space.screen(.init(x: world.x + delta.0, y: world.y + delta.1)), modifiers: []) }
        return g.evaluate()
    }

    func testPressingAnyEnabledHandleWithoutMovingChangesNothing() throws {
        let note = SpatialRouting(target: .midiNote(channel: 0), program: .singleNote(note: 60, velocity: 100, transition: .retrigger))
        let rotated = try rect(60, 40, .init(xCm: 20, yCm: 100, rotationDegrees: 25), routings: [note])
        let circle = try SpatialSurface(presentation: .init(name: "c", color: .blue), form: .shape(.circle(radiusCm: 20), .init(xCm: -40, yCm: 90)))
        let poly = try SpatialSurface(presentation: .init(name: "p", color: .blue),
                                      form: .shape(.polygon(pointsCm: [.init(x: -20, y: -10), .init(x: 20, y: -10), .init(x: 0, y: 20)]), .init(xCm: 30, yCm: 100)))
        let sector = try SpatialSurface(presentation: .init(name: "s", color: .blue), form: .shape(.ringSector(fromCm: 50, toCm: 120, fromDegrees: -30, toDegrees: 40), .identity))
        let a = try rect(20, 20, .init(xCm: -20, yCm: 70)), b = try rect(20, 20, .init(xCm: 20, yCm: 70))
        var checked = 0
        for selection in [[rotated], [circle], [poly], [sector], [a, b]] {
            let layout = SurfaceHandleLayout.make(surfaces: selection, axisRoutingID: nil, space: space, lockedReason: nil)
            for handle in layout.handles where handle.isEnabled && handle.kind != .rotate {
                let result = try grabAt(handle, originals: selection)
                XCTAssertNil(result.problem, "\(handle.kind)")
                for surface in selection {
                    let placed = try XCTUnwrap(surface.placedShape)
                    guard let now = result.placements[surface.id] else { continue }
                    XCTAssertEqual(now.shape, placed.shape, "\(handle.kind) must start from the original shape")
                    XCTAssertEqual(now.transform.xCm, placed.transform.xCm, accuracy: 0.11, "\(handle.kind)")
                    XCTAssertEqual(now.transform.yCm, placed.transform.yCm, accuracy: 0.11, "\(handle.kind)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 25)
    }

    func testTheFirstMovementOfAHandleFollowsThePointerByItsOwnDistanceOnly() throws {
        // The group's box corner is drawn outside the box; dragging it by 6 cm along the diagonal scales by the pointer's movement.
        let a = try rect(20, 20, .init(xCm: -20, yCm: 70)), b = try rect(20, 20, .init(xCm: 20, yCm: 70))
        let layout = SurfaceHandleLayout.make(surfaces: [a, b], axisRoutingID: nil, space: space, lockedReason: nil)
        let corner = try XCTUnwrap(layout.handles.first { $0.kind == .frameCorner(sx: 1, sy: 1) })
        // Box (-30…30) × (60…80): the opposite corner stays at (-30, 60); the dragged one is at (30, 80), 60 × 20 big.
        let result = try grabAt(corner, originals: [a, b], to: (6, 2))
        let scaledA = try XCTUnwrap(result.placements[a.id]), scaledB = try XCTUnwrap(result.placements[b.id])
        // k follows the projection of the movement on the diagonal (60, 20): (6·60 + 2·20) / 4000 = 0.1 above 1.
        XCTAssertEqual(scaledA.shape, .rectangle(widthCm: 22, heightCm: 22))
        XCTAssertEqual(scaledB.shape, .rectangle(widthCm: 22, heightCm: 22))
        XCTAssertEqual(scaledB.transform.xCm, -30 + 1.1 * 50, accuracy: 0.11)
        // A rectangle corner and a polygon corner behave the same way: they move by what the pointer moved.
        let one = try rect(60, 40, .init(xCm: 0, yCm: 100))
        let handle = try XCTUnwrap(SurfaceHandleLayout.make(surfaces: [one], axisRoutingID: nil, space: space, lockedReason: nil)
            .handles.first { $0.kind == .rectCorner(sx: 1, sy: 1) })
        XCTAssertEqual(try grabAt(handle, originals: [one], to: (5, 3)).placements[one.id]?.shape, .rectangle(widthCm: 65, heightCm: 43))
        let poly = try SpatialSurface(presentation: .init(name: "p", color: .blue),
                                      form: .shape(.polygon(pointsCm: [.init(x: -20, y: -10), .init(x: 20, y: -10), .init(x: 0, y: 20)]), .init(xCm: 0, yCm: 100)))
        let top = try XCTUnwrap(SurfaceHandleLayout.make(surfaces: [poly], axisRoutingID: nil, space: space, lockedReason: nil)
            .handles.first { $0.kind == .polygonPoint(index: 2) })
        XCTAssertEqual(try grabAt(top, originals: [poly], to: (4, 6)).edits, [.movePolygonPoint(id: poly.id, index: 2, to: .init(x: 4, y: 26))])
        // A sector handle stands outside the sector; the radius grows by the movement, not by the distance of the handle.
        let sector = try SpatialSurface(presentation: .init(name: "s", color: .blue), form: .shape(.ringSector(fromCm: 50, toCm: 120, fromDegrees: -30, toDegrees: 40), .identity))
        let outer = try XCTUnwrap(SurfaceHandleLayout.make(surfaces: [sector], axisRoutingID: nil, space: space, lockedReason: nil)
            .handles.first { $0.kind == .sectorOuter })
        let grown = try grabAt(outer, originals: [sector], to: (0, 10))
        guard case .ringSector(_, let to, _, _)? = grown.placements[sector.id]?.shape else { return XCTFail() }
        XCTAssertEqual(to, 130, accuracy: 1.01)
    }

    func testAHandlePushedInFromTheCanvasEdgeStillStartsAtItsTrueCorner() throws {
        // Zoomed in so that the rectangle's corner lies beyond the canvas: the drawn handle is clamped inside it.
        let tight = MetricCanvasGeometry(size: CGSize(width: 300, height: 300),
                                         viewport: try MetricCanvasViewport.build(centerXMeters: 0, centerYMeters: 1.0, metersPerPoint: 0.002))
        let tightSpace = SurfaceCanvasSpace(tight)
        let wide = try rect(120, 40, .init(xCm: 0, yCm: 100))
        let layout = SurfaceHandleLayout.make(surfaces: [wide], axisRoutingID: nil, space: tightSpace, lockedReason: nil)
        let corner = try XCTUnwrap(layout.handles.first { $0.kind == .rectCorner(sx: 1, sy: 1) })
        XCTAssertTrue(tightSpace.canvasRect.contains(corner.center), "clamped inside the canvas")
        let world = try XCTUnwrap(tightSpace.world(corner.center))
        XCTAssertGreaterThan(abs(world.x - 60), 10, "the drawn handle is far from the true corner")
        let g = SurfaceGesture(kind: .handle(corner.kind), space: tightSpace, startScreen: corner.center, start: world, originals: [wide])
        XCTAssertEqual(g.evaluate().placements[wide.id]?.shape, .rectangle(widthCm: 120, heightCm: 40))
    }

    private func documentWith(_ a: SpatialSurface, _ b: SpatialSurface) throws -> InstrumentDocument {
        InstrumentDocument(spatial: try document([a, b]), detection: .allStagesOff, revision: .init(session: UUID(), counter: 1))
    }
}
